import { describe, expect, test } from 'claude-code/testing'
import { branchesTouched, choiceFor, filesWritten, newWork, outstanding, porcelainFiles, settledByBranchChoice, settledByDan, whoseFiles, type LeftBranch, type LeftClosed, type LeftOpen, type Reading } from '../hooks/winddown.ts'
import { ghArgs } from './mod-kit/hooks/gh.ts'

const gitOf = (words: string[]) => (words[0] === 'git' ? { sub: words[1], args: words.slice(2) } : undefined)
// Each command with its gh reading, by mod-kit's own reader (its byte for byte copy), as the mod reads it (#961).
const bash = (...lines: string[][]) => newWork({ tool: 'Bash', input: {}, commands: lines.map(words => ({ words, git: gitOf(words), gh: ghArgs(words) })), issues: [616] })
const tool = (name: string, input: Record<string, unknown>, issues = [616]) => newWork({ tool: name, input, commands: [], issues })

describe('newWork: starting new work is denied while winding down', () => {
  test('the next-issue skill', () => {
    expect(tool('Skill', { skill: 'next-issue' })?.what).toBe('start the next issue')
    expect(tool('Skill', { skill: 'user:next-issue' })?.what).toBe('start the next issue')
    expect(tool('Skill', { skill: 'db-apply' })).toBeUndefined()
  })
  test('new branches, by git, by gh issue develop and by a new worktree', () => {
    expect(bash(['git', 'checkout', '-b', 'issue-700'])?.what).toBe('start a new branch')
    expect(bash(['git', 'switch', '-c', 'issue-700'])?.what).toBe('start a new branch')
    expect(bash(['git', 'branch', 'issue-700'])?.what).toBe('start a new branch')
    expect(bash(['git', 'worktree', 'add', '-b', 'x', '../x'])?.what).toBe('start a new branch')
    expect(bash(['gh', 'issue', 'develop', '700'])?.what).toBe('start a new branch')
    // #961: read past gh's global flags by mod-kit's gh reader, so a flag first hides nothing.
    expect(bash(['gh', '-R', 'o/x', 'issue', 'develop', '700'])?.what).toBe('start a new branch')
    expect(bash(['gh', '--repo=o/x', 'issue', 'develop', '700'])?.what).toBe('start a new branch')
    expect(bash(['gh', '-R', 'o/x', 'issue', 'view', '700'])).toBeUndefined()
    // A flag before the subcommand gh's reader cannot place could hide one, so it is refused.
    expect(bash(['gh', '--frob', 'x', 'issue', 'develop', '700'])?.what).toBe('run a gh command whose flags cannot be read')
    expect(tool('EnterWorktree', {})?.what).toBe('start a new branch')
  })
  test('agent dispatch for another issue, but not for this one', () => {
    expect(tool('Agent', { prompt: 'Build issue #700 in the worktree' })?.what).toBe('dispatch an agent for issue #700')
    expect(tool('Agent', { prompt: 'Fix the failing check on #616' })).toBeUndefined()
    expect(tool('Agent', { prompt: 'Read the CI log and say why it failed' })).toBeUndefined()
  })
  test('asking Dan is never new work: a question goes through, so nothing is parked waiting on him (#856)', () => {
    expect(tool('AskUserQuestion', { questions: [{ question: 'Merge PR #700?' }] })).toBeUndefined()
  })
  test('fixing what blocks THIS issue is allowed: edits, commits, pushes, merging', () => {
    expect(tool('Edit', { file_path: '/repo/app.ts' })).toBeUndefined()
    expect(bash(['git', 'commit', '-m', 'fix the check'], ['git', 'push'])).toBeUndefined()
    expect(bash(['gh', 'pr', 'merge', '12', '--squash'])).toBeUndefined()
    expect(bash(['git', 'checkout', 'main'], ['git', 'branch', '-D', 'scope-modes-616'])).toBeUndefined()
  })
})

const merged: Reading = {
  branch: 'scope-modes-616',
  isDefault: false,
  pr: { number: 12, state: 'MERGED', issues: [{ number: 616, state: 'CLOSED' }] },
  branchHere: false,
  branchOnGitHub: false,
  worktreeOnBranch: false,
  deploy: { state: 'live' },
  dirty: [],
}

describe('outstanding: finished means merged, live, cleaned and closed', () => {
  test('all of it done is nothing outstanding', () => {
    expect(outstanding(merged)).toEqual([])
  })
  test('each step not yet done is named', () => {
    expect(outstanding({ ...merged, pr: { number: 12, state: 'OPEN', issues: [{ number: 616, state: 'OPEN' }] } })).toEqual(['PR #12 is not merged yet'])
    expect(outstanding({ ...merged, branchHere: true, branchOnGitHub: true, worktreeOnBranch: true })).toEqual([
      'the branch scope-modes-616 still exists here',
      'the branch scope-modes-616 still exists on GitHub',
      'a worktree is still on scope-modes-616',
    ])
    expect(outstanding({ ...merged, pr: { number: 12, state: 'MERGED', issues: [{ number: 616, state: 'OPEN' }] } })).toEqual(['issue #616 is still open'])
  })
  test("the deploy is judged by is it live's card (#687): only Live or no deploy step recorded finish it", () => {
    expect(outstanding({ ...merged, deploy: { state: 'no-deploy' } })).toEqual([])
    expect(outstanding({ ...merged, deploy: { state: 'deploying' } })).toEqual(['the deploy is still running (is it live says Merged, deploying)'])
    expect(outstanding({ ...merged, deploy: { state: 'unconfirmed' } })).toEqual(['is it live could not confirm the deploy live: find out why, and make the card again once it is'])
  })
  test('a merged PR with no card yet is not finished, and says what to do', () => {
    expect(outstanding({ ...merged, deploy: null })).toEqual(['PR #12 has no is it live card yet: check the deploy and make the card (mcp__is-it-live__card)'])
  })
  test('an absent is it live is unmeasured, never live, and a failed read is said apart from it (L11)', () => {
    expect(outstanding({ ...merged, deploy: { unmeasured: 'the is it live mod is not loaded' } })).toEqual(['the deploy is unmeasured: the is it live mod is not loaded'])
    expect(outstanding({ ...merged, deploy: { unreadable: 'is-it-live: boom' } })).toEqual(['the deploy verdict could not be read (is-it-live: boom)'])
  })
  test('a card state wind down does not know is never read as finished (L42)', () => {
    expect(outstanding({ ...merged, deploy: { state: 'rolled-back' as never } })).toEqual(['is it live answered a state wind down does not know (rolled-back)'])
    expect(outstanding({ ...merged, deploy: { state: 'constructor' as never } })).toEqual(['is it live answered a state wind down does not know (constructor)'])
  })
  test('the deploy is not judged before the merge: an open PR names only the merge', () => {
    expect(outstanding({ ...merged, pr: { number: 12, state: 'OPEN', issues: [] }, deploy: null })).toEqual(['PR #12 is not merged yet'])
  })
  test('no PR yet on a working branch', () => {
    expect(outstanding({ ...merged, pr: null })).toEqual(['there is no PR for scope-modes-616 yet'])
  })
  test('a PR closed without merging needs Dan, and names the one way his answer is recorded (#1033)', () => {
    expect(outstanding({ ...merged, pr: { number: 12, state: 'CLOSED', issues: [] } })).toEqual(['PR #12 was closed without merging: ask Dan whether to leave it closed (mcp__scope-modes__leave_pr_open)'])
  })
  test('on the default branch with no PR and nothing uncommitted, there is nothing to finish', () => {
    expect(outstanding({ ...merged, branch: 'main', isDefault: true, pr: null, deploy: null })).toEqual([])
    expect(outstanding({ ...merged, branch: 'main', isDefault: true, pr: null, deploy: null, dirty: ['app.ts'] })).toEqual([UNCOMMITTED('app.ts')])
  })
  test('a reading that failed is never read as done (L215)', () => {
    expect(outstanding({ ...merged, pr: { unreadable: 'gh: HTTP 502' } })).toEqual(['the PR could not be read (gh: HTTP 502)'])
    expect(outstanding({ ...merged, branchOnGitHub: { unreadable: 'could not reach origin' } })).toEqual(['whether scope-modes-616 is gone from GitHub could not be read (could not reach origin)'])
  })
})

// #917: a PR Dan himself chose to leave open is settled, recorded from his own answer against the
// PR's head, so a new push asks again. Nobody's decision keeps #856's default: not merged yet.
describe('a PR Dan chose to leave open (#917)', () => {
  const choice: LeftOpen = { repo: 'o/r', number: 12, head: 'aaa1111', why: "awaiting Denys's review" }
  const open = (head?: string): Reading => ({ ...merged, pr: { number: 12, state: 'OPEN', head, issues: [{ number: 616, state: 'OPEN' }] }, deploy: null })
  test('left open by Dan at the head it has now is settled, its open issue and branch included', () => {
    const r = { ...open('aaa1111'), choice }
    expect(outstanding(r)).toEqual([])
    expect(settledByDan(r)).toBe(true)
  })
  test('nobody decided: still not merged yet (#856)', () => {
    expect(outstanding(open('aaa1111'))).toEqual(['PR #12 is not merged yet'])
    expect(settledByDan(open('aaa1111'))).toBe(false)
  })
  test('pushed to since Dan chose: asked again, never carried over to the new commits', () => {
    const r = { ...open('bbb2222'), choice }
    expect(outstanding(r)).toEqual(['PR #12 has new commits since Dan chose to leave it open: merge it, or ask him again (mcp__scope-modes__leave_pr_open)'])
    expect(settledByDan(r)).toBe(false)
  })
  test('a head GitHub did not give cannot be matched to his choice, and says so (L11)', () => {
    const r = { ...open(undefined), choice }
    expect(outstanding(r)).toEqual(["PR #12's latest commit could not be read, so Dan's choice to leave it open cannot be matched to it"])
    expect(settledByDan(r)).toBe(false)
  })
  test('a choice about a PR since merged or closed changes nothing about finishing it', () => {
    const done = { number: 12, state: 'MERGED' as const, head: 'aaa1111', issues: [{ number: 616, state: 'CLOSED' as const }] }
    expect(outstanding({ ...merged, pr: done, choice })).toEqual([])
    expect(settledByDan({ ...merged, pr: done, choice })).toBe(false)
    expect(outstanding({ ...merged, pr: done, deploy: null, choice })).toEqual(['PR #12 has no is it live card yet: check the deploy and make the card (mcp__is-it-live__card)'])
    expect(outstanding({ ...merged, pr: { number: 12, state: 'CLOSED', head: 'aaa1111', issues: [] }, choice })).toEqual(['PR #12 was closed without merging: ask Dan whether to leave it closed (mcp__scope-modes__leave_pr_open)'])
  })
  test('found by repository and number: the same number in another repository is another PR', () => {
    const all: LeftOpen[] = [choice, { ...choice, repo: 'o/other', number: 31 }]
    expect(choiceFor(all, 'O/R', 12)).toEqual(choice)
    expect(choiceFor(all, 'o/other', 12)).toBeUndefined()
    expect(choiceFor(all, 'o/r', 31)).toBeUndefined()
    expect(choiceFor([], 'o/r', 12)).toBeUndefined()
  })
})

// #1033: a PR closed without merging (ovation#711, closed when its stacked base branch was deleted,
// its work merged as #716) is settled by Dan's own answer to leave it closed, recorded by repository
// and number. It carries no head: a closed PR merges nothing until reopened, and reopened it is open,
// which his answer about a closed PR never covers.
describe('a PR Dan chose to leave closed (#1033)', () => {
  const choice: LeftClosed = { repo: 'o/r', number: 12, closed: true, why: 'its work merged as #716' }
  const closed = (head?: string): Reading => ({ ...merged, pr: { number: 12, state: 'CLOSED', head, issues: [{ number: 616, state: 'OPEN' }] }, deploy: null })
  test('left closed by Dan is settled, whatever its head, its open issue and branch included', () => {
    for (const head of ['aaa1111', 'bbb2222', undefined]) {
      expect(outstanding({ ...closed(head), choice })).toEqual([])
      expect(settledByDan({ ...closed(head), choice })).toBe(true)
    }
  })
  test('nobody decided: outstanding, naming the tool that records his answer', () => {
    expect(outstanding(closed('aaa1111'))).toEqual(['PR #12 was closed without merging: ask Dan whether to leave it closed (mcp__scope-modes__leave_pr_open)'])
    expect(settledByDan(closed('aaa1111'))).toBe(false)
  })
  test('reopened since he answered: an open PR, outstanding until merged, his answer never carried over', () => {
    const reopened: Reading = { ...merged, pr: { number: 12, state: 'OPEN', head: 'aaa1111', issues: [] }, deploy: null, choice }
    expect(outstanding(reopened)).toEqual(['PR #12 is not merged yet'])
    expect(settledByDan(reopened)).toBe(false)
  })
  test('merged after all: finished as any merged PR is', () => {
    const done = { number: 12, state: 'MERGED' as const, issues: [{ number: 616, state: 'CLOSED' as const }] }
    expect(outstanding({ ...merged, pr: done, choice })).toEqual([])
    expect(outstanding({ ...merged, pr: done, deploy: null, choice })).toEqual(['PR #12 has no is it live card yet: check the deploy and make the card (mcp__is-it-live__card)'])
    expect(settledByDan({ ...merged, pr: done, choice })).toBe(false)
  })
  test('one answer per PR, found by repository and number: his answer about one closed PR settles no other', () => {
    const open: LeftOpen = { repo: 'o/r', number: 31, head: 'ccc3333', why: 'awaiting review' }
    const all = [choice, open]
    expect(choiceFor(all, 'O/R', 12)).toEqual(choice)
    expect(choiceFor(all, 'o/other', 12)).toBeUndefined()
    expect(choiceFor(all, 'o/r', 13)).toBeUndefined()
    const other: Reading = { ...merged, pr: { number: 13, state: 'CLOSED', issues: [] }, deploy: null, choice: choiceFor(all, 'o/r', 13) }
    expect(outstanding(other)).toEqual(['PR #13 was closed without merging: ask Dan whether to leave it closed (mcp__scope-modes__leave_pr_open)'])
  })
})

// The finish check names the two ways out of uncommitted work while winding down: a cleanup branch
// Dan agrees to (#1051), or his answer to leave it as it is (#1074).
function UNCOMMITTED(files: string) {
  return `there are uncommitted changes (${files}): commit them on a branch Dan agrees to (mcp__scope-modes__open_cleanup_branch), or ask him whether to leave them (mcp__scope-modes__leave_branch)`
}

describe('uncommitted changes, by the files git status names (#1051)', () => {
  test('each line of git status --porcelain is one file, renamed and quoted ones included', () => {
    expect(porcelainFiles(' M tests/section-time-readings.tsv\n?? notes/new.md\nR  old.ts -> new.ts\n M "with space.ts"\n')).toEqual([
      'tests/section-time-readings.tsv',
      'notes/new.md',
      'new.ts',
      'with space.ts',
    ])
    expect(porcelainFiles('')).toEqual([])
  })
  test("a name git quoted is read back as the name itself: its octal bytes and escapes undone (#1108 lessons review)", () => {
    // git writes a name with a byte past ASCII as octal escapes of its UTF-8, quoted (core.quotePath).
    expect(porcelainFiles('?? "caf\\303\\251.ts"\n M "a\\"b.ts"\n M "tab\\there.ts"\n M "back\\\\slash.ts"\nR  "old\\303\\251.ts" -> "new\\303\\251.ts"\n')).toEqual([
      'café.ts',
      'a"b.ts',
      'tab\there.ts',
      'back\\slash.ts',
      'newé.ts',
    ])
    // A character git left raw (core.quotePath off), outside the BMP, in a name quoted for its quote.
    expect(porcelainFiles('?? "\u{1F600}\\"x.ts"\n')).toEqual(['\u{1F600}"x.ts'])
    // So a file this session wrote under that name is its own.
    expect(whoseFiles(porcelainFiles('?? "caf\\303\\251.ts"\n'), '/repo', ['/repo/café.ts'])).toEqual({ own: ['café.ts'], others: [] })
  })
  test('the finish check names the files, at most five, then how many more', () => {
    const r: Reading = { ...merged, branch: 'main', isDefault: true, pr: null, deploy: null }
    expect(outstanding({ ...r, dirty: ['a', 'b', 'c', 'd', 'e', 'f', 'g'] })).toEqual([UNCOMMITTED('a, b, c, d, e and 2 more')])
    expect(outstanding({ ...r, dirty: { unreadable: 'fatal: bad index' } })).toEqual(['whether anything is uncommitted could not be read (fatal: bad index)'])
  })
})

describe('a cleanup branch Dan agreed to is the one branch winding down lets start (#1051)', () => {
  const words = (...lines: string[][]) => lines.map(w => ({ words: w, git: gitOf(w), gh: ghArgs(w) }))
  const begin = (cleanBranches: string[], ...lines: string[][]) => newWork({ tool: 'Bash', input: {}, commands: words(...lines), issues: [616], cleanBranches })
  test('a branch he agreed to starts, by checkout or switch, which carry the uncommitted changes onto it', () => {
    expect(begin(['chore/readings'], ['git', 'switch', '-c', 'chore/readings'])).toBeUndefined()
    expect(begin(['chore/readings'], ['git', 'checkout', '-b', 'chore/readings'])).toBeUndefined()
  })
  test('any other branch is still new work, and the refusal names it', () => {
    expect(begin(['chore/readings'], ['git', 'checkout', '-b', 'feature-x'])).toEqual({ what: 'start a new branch', branch: 'feature-x' })
    expect(begin([], ['git', 'switch', '-c', 'chore/readings'])).toEqual({ what: 'start a new branch', branch: 'chore/readings' })
    // One allowed start never carries another one with it.
    expect(begin(['chore/readings'], ['git', 'switch', '-c', 'chore/readings'], ['git', 'switch', '-c', 'feature-x'])?.branch).toBe('feature-x')
  })
  test('a branch made without moving onto it, or in a new worktree, leaves the changes behind, so is never the cleanup', () => {
    expect(begin(['chore/readings'], ['git', 'branch', 'chore/readings'])?.what).toBe('start a new branch')
    expect(begin(['chore/readings'], ['git', 'worktree', 'add', '-b', 'chore/readings', '../x'])?.what).toBe('start a new branch')
  })
})

describe('the branches a session made its own: created, committed to or pushed (#1074)', () => {
  const touched = (...lines: string[][]) => branchesTouched(lines.map(w => ({ words: w, git: gitOf(w) })))
  test("a branch it created, by any of git's ways", () => {
    expect(touched(['git', 'checkout', '-b', 'a'], ['git', 'switch', '-c', 'b'], ['git', 'branch', 'c'], ['git', 'worktree', 'add', '-b', 'd', '../d'])).toEqual({ named: ['a', 'b', 'c', 'd'], current: false })
  })
  test('a branch it pushed by name, the destination of a refspec included; a deletion or a tag is none', () => {
    expect(touched(['git', 'push', '-u', 'origin', 'fix-700'])).toEqual({ named: ['fix-700'], current: false })
    expect(touched(['git', 'push', 'origin', '+HEAD:refs/heads/fix-701'])).toEqual({ named: ['fix-701'], current: false })
    expect(touched(['git', 'push', '-o', 'ci.skip', 'origin', 'local:fix-702'])).toEqual({ named: ['fix-702'], current: false })
    expect(touched(['git', 'push', 'origin', '--delete', 'old'])).toEqual({ named: [], current: false })
    expect(touched(['git', 'push', 'origin', ':old'])).toEqual({ named: [], current: false })
    expect(touched(['git', 'push', 'origin', 'refs/tags/v1.2'])).toEqual({ named: [], current: false })
    expect(touched(['git', 'push', '--tags'])).toEqual({ named: [], current: false })
  })
  test('a commit, or a push naming no branch, is of the branch checked out where it ran', () => {
    expect(touched(['git', 'commit', '-m', 'fix'])).toEqual({ named: [], current: true })
    expect(touched(['git', 'push'])).toEqual({ named: [], current: true })
    expect(touched(['git', 'push', '-u', 'origin', 'HEAD'])).toEqual({ named: [], current: true })
  })
  test('reading branches touches nothing else', () => {
    expect(touched(['git', 'checkout', 'main'], ['git', 'status'], ['git', 'branch', '-D', 'old'], ['git', 'branch', '--list', 'x'])).toEqual({ named: [], current: false })
  })
})

describe("a branch that is not this session's, and Dan's answer to leave a branch as it is (#1074)", () => {
  const inherited: Reading = { ...merged, branch: 'fix/2210-corrected-number-wins', isDefault: false, inherited: true, pr: null, deploy: null, branchHere: true, worktreeOnBranch: true }
  test('a branch the checkout already sat on has nothing of this session to finish: no PR, no cleanup', () => {
    expect(outstanding(inherited)).toEqual([])
  })
  test('uncommitted changes there are still counted, as on the default branch', () => {
    expect(outstanding({ ...inherited, dirty: ['notes.md'] })).toEqual([UNCOMMITTED('notes.md')])
  })
  const left: LeftBranch = { repo: 'o/r', branch: 'scope-modes-616', files: [], why: 'another session stands on it' }
  test('his answer settles the branch here and a worktree on it, never the branch on GitHub', () => {
    expect(outstanding({ ...merged, branchHere: true, worktreeOnBranch: true, branchLeft: left })).toEqual([])
    expect(outstanding({ ...merged, branchHere: true, branchOnGitHub: true, branchLeft: left })).toEqual(['the branch scope-modes-616 still exists on GitHub'])
  })
  test('his answer is said as what kept a branch only where it settled something (lessons review)', () => {
    expect(settledByBranchChoice({ ...merged, branchHere: true, branchLeft: left })).toBe(true)
    // The branch went anyway: his answer kept nothing, so nothing is said of it.
    expect(settledByBranchChoice({ ...merged, branchLeft: left })).toBe(false)
    // A file changed since he answered: what is outstanding is the same with or without it.
    expect(settledByBranchChoice({ ...inherited, branch: left.branch, branchHere: false, worktreeOnBranch: false, dirty: ['new.ts'], branchLeft: left })).toBe(false)
    expect(settledByBranchChoice({ ...merged, branchHere: true })).toBe(false)
  })
  test('it settles the uncommitted files he was asked about, and a file changed since asks again', () => {
    const asked: Reading = { ...inherited, branch: left.branch, branchLeft: { ...left, files: ['notes.md'] } }
    expect(outstanding({ ...asked, dirty: ['notes.md'] })).toEqual([])
    expect(outstanding({ ...asked, dirty: ['notes.md', 'new.ts'] })).toEqual([UNCOMMITTED('new.ts')])
  })
})

// #1108: in a shared primary checkout, another session's untracked files blocked every stop of this
// one. Only the files this session (or one of its agents) wrote are its unfinished work.
describe('whose uncommitted files they are (#1108)', () => {
  const none = { files: [], changes: [], unnamed: [] }
  test('Edit, Write, MultiEdit and NotebookEdit write the file they name, its path made plain', () => {
    expect(filesWritten({ tool: 'Edit', input: { file_path: '/repo/app.ts' }, writes: none })).toEqual(['/repo/app.ts'])
    expect(filesWritten({ tool: 'Write', input: { file_path: '/repo/./src/../notes.md' }, writes: none })).toEqual(['/repo/notes.md'])
    expect(filesWritten({ tool: 'MultiEdit', input: { file_path: '/repo/a.ts' }, writes: none })).toEqual(['/repo/a.ts'])
    expect(filesWritten({ tool: 'NotebookEdit', input: { notebook_path: '/repo/n.ipynb' }, writes: none })).toEqual(['/repo/n.ipynb'])
    // A relative path names no file the session can be sure of, and a reading tool writes nothing.
    expect(filesWritten({ tool: 'Edit', input: { file_path: 'app.ts' }, writes: none })).toEqual([])
    expect(filesWritten({ tool: 'Read', input: { file_path: '/repo/app.ts' }, writes: none })).toEqual([])
  })
  test("a Bash call writes what mod-kit's write reader names: its files, its other changes, and a program's named targets", () => {
    const writes = {
      files: [{ word: 'out.txt', path: '/repo/out.txt' }, { word: '$X' }, { word: 'dir', path: '/repo/dir', sources: ['/repo/x.ts'], mayBeFolder: true as const }],
      changes: [
        { word: 'old.ts', path: '/repo/old.ts', does: 'remove' as const },
        { word: 'build', path: '/repo/build', does: 'remove' as const, tree: true as const },
        { word: 'made', path: '/repo/made', does: 'folder' as const },
      ],
      unnamed: [
        { what: 'an inline python3 script', words: [], inputs: [], targets: ['/repo/gen.ts'] },
        { what: 'a patch', words: [], inputs: ['/repo/p.diff'] },
      ],
    }
    // A copy onto dir lands as dir or as dir/x.ts, never as all of dir, which may hold another
    // session's files; a made folder writes no file (lessons review).
    expect(filesWritten({ tool: 'Bash', input: {}, writes })).toEqual(['/repo/out.txt', '/repo/dir', '/repo/dir/x.ts', '/repo/dir/x.ts/', '/repo/old.ts', '/repo/build', '/repo/build/', '/repo/gen.ts'])
    expect(whoseFiles(['dir/x.ts', 'dir/theirs.md', 'made/theirs.md'], '/repo', filesWritten({ tool: 'Bash', input: {}, writes }))).toEqual({ own: ['dir/x.ts'], others: ['dir/theirs.md', 'made/theirs.md'] })
  })
  test('the uncommitted files are split into the ones this session wrote and the rest', () => {
    const written = ['/repo/app.ts', '/repo/build/', '/elsewhere/x.ts']
    expect(whoseFiles(['app.ts', 'build/out.js', 'notes.md', 'x.ts'], '/repo', written)).toEqual({ own: ['app.ts', 'build/out.js'], others: ['notes.md', 'x.ts'] })
    // A folder's own name is not under it: build.ts is not in build/.
    expect(whoseFiles(['build.ts'], '/repo', written)).toEqual({ own: [], others: ['build.ts'] })
    expect(whoseFiles(['app.ts'], '/repo/', written)).toEqual({ own: ['app.ts'], others: [] })
    expect(whoseFiles([], '/repo', written)).toEqual({ own: [], others: [] })
  })
  test("a file written under another spelling of its path is still the session's: case, and /private before /var, /tmp or /etc (lessons review)", () => {
    expect(whoseFiles(['App.ts'], '/Users/x/Repo', ['/users/x/repo/app.ts'])).toEqual({ own: ['App.ts'], others: [] })
    expect(whoseFiles(['a.ts'], '/private/var/folders/r', ['/var/folders/r/a.ts'])).toEqual({ own: ['a.ts'], others: [] })
    expect(whoseFiles(['a.ts'], '/tmp/r', ['/private/tmp/r/a.ts'])).toEqual({ own: ['a.ts'], others: [] })
    expect(whoseFiles(['b/c.ts'], '/private/tmp/r', ['/tmp/r/b/'])).toEqual({ own: ['b/c.ts'], others: [] })
    // Only those three links: /private elsewhere is a folder of its own.
    expect(whoseFiles(['a.ts'], '/private/stuff', ['/stuff/a.ts'])).toEqual({ own: [], others: ['a.ts'] })
  })
})
