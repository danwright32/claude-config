import { describe, expect, test } from 'claude-code/testing'
import { choiceFor, newWork, outstanding, settledByDan, type LeftClosed, type LeftOpen, type Reading } from '../hooks/winddown.ts'
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
  dirty: false,
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
    expect(outstanding({ ...merged, branch: 'main', isDefault: true, pr: null, deploy: null, dirty: true })).toEqual(['there are uncommitted changes'])
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
