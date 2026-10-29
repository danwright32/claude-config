import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { branchesTouched, choiceFor, closingComments, filesWritten, issueRefs, neverMergeSaid, prLinks, prRefs, quoteOf, newWork, outstanding, patchedPaths, porcelainFiles, settledByBranchChoice, settledByDan, stashTaken, statedNextStep, whatIsLeft, whoseFiles, type LeftBranch, type LeftClosed, type IssueLeft, type LeftOpen, type Reading } from '../hooks/winddown.ts'
import { ghArgs } from './mod-kit/hooks/gh.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'

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
    expect(outstanding({ ...merged, pr: { number: 12, state: 'MERGED', issues: [{ number: 616, state: 'OPEN' }] } })).toEqual([
      'issue #616 is still open: finish what is left on it now (read the issue for what that is)',
    ])
  })
  // #1812: an issue the session worked that is still open is finished, its owed verification
  // included, and what is left is named from the PR's stated next step or the issue's last comment.
  test('an open issue names what is left on it, from the PR body first and the last comment after (#1812)', () => {
    const open = (left?: IssueLeft) =>
      outstanding({ ...merged, pr: { number: 12, state: 'MERGED', issues: [{ number: 1765, state: 'OPEN', ...(left ? { left } : {}) }] } })
    expect(open({ from: 'pr', quote: 'the live check in a fresh session is still owed' })).toEqual([
      'issue #1765 is still open: finish what is left on it now, which PR #12 names as its next step ("the live check in a fresh session is still owed")',
    ])
    expect(open({ from: 'comment', quote: 'Root cause found; the fix needs a live check' })).toEqual([
      'issue #1765 is still open: finish what is left on it now, as its last comment says ("Root cause found; the fix needs a live check")',
    ])
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
  test('a PR closed without merging is reopened and finished, as Dan would rather merge it (#1767)', () => {
    expect(outstanding({ ...merged, pr: { number: 12, state: 'CLOSED', issues: [] } })).toEqual([REOPEN(12)])
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

describe('the issues a merged PR worked, and what is left on each (#1812)', () => {
  test('Refs, Ref and References name an issue the PR worked without closing it; a closing keyword, Part of or another repository does not', () => {
    expect(issueRefs('Refs #1765', 'o/r')).toEqual([1765])
    expect(issueRefs('Ref: #10, #11 and #12\n\nReferences o/r#13.', 'o/r')).toEqual([10, 11, 12, 13])
    // Part of names an epic as often as the issue worked, and an epic would hold winding down until it closed.
    expect(issueRefs('Part of #14', 'o/r')).toEqual([])
    expect(issueRefs('refs O/R#15', 'o/r')).toEqual([15])
    expect(issueRefs('Closes #1765\nFixes #3', 'o/r')).toEqual([])
    expect(issueRefs('Refs other/repo#9, and see #8', 'o/r')).toEqual([])
    // A repository it cannot place names only the bare numbers.
    expect(issueRefs('Refs #4 and o/r#5', undefined)).toEqual([4])
    expect(issueRefs('Bumps the prefs #4 file', 'o/r')).toEqual([])
  })
  test("the PR body's stated next step, preferring the line naming the issue, a heading taking the line under it", () => {
    expect(statedNextStep('Fixes the hang.\n\nRefs #1765: the live check in a fresh session is still owed after merge.', 1765)).toBe(
      'Refs #1765: the live check in a fresh session is still owed after merge.',
    )
    expect(statedNextStep('Body.\n\n## Next step\n\n- Run the live check in a fresh headless session.\n', 1765)).toBe('Run the live check in a fresh headless session.')
    expect(statedNextStep('Next step: measure the queue.\nNext step for #7: the live check.', 7)).toBe('Next step for #7: the live check.')
    expect(statedNextStep('Fixes the hang. Refs #1765', 1765)).toBeUndefined()
    // A next step naming only another issue is that issue's, never this one's.
    expect(statedNextStep('Refs #7, #8\n\nNext step for #7: the live check.', 8)).toBeUndefined()
  })
  test('what is left: the next step the PR states, else the last comment, else nothing', () => {
    expect(whatIsLeft('Refs #5. Next step: the live check.', 5, 'An old note')).toEqual({ from: 'pr', quote: 'Refs #5. Next step: the live check.' })
    expect(whatIsLeft('Refs #5', 5, 'Root cause found.\n\nThe fix needs a live check.')).toEqual({ from: 'comment', quote: 'Root cause found. The fix needs a live check.' })
    expect(whatIsLeft('Refs #5', 5, '  ')).toBeUndefined()
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
    expect(outstanding({ ...merged, pr: { number: 12, state: 'CLOSED', head: 'aaa1111', issues: [] }, choice })).toEqual([REOPEN(12)])
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
  test('nobody decided, and nothing recorded says it will never merge: reopened and finished (#1767)', () => {
    expect(outstanding(closed('aaa1111'))).toEqual([REOPEN(12)])
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
    expect(outstanding(other)).toEqual([REOPEN(13)])
  })
})

// #1767: on 2026-10-26 winding down asked Dan whether to leave #1716 closed, and he answered "finish
// and merge it ... I'd always prefer to merge it unless we're never going to merge it". So a PR this
// session opened that was closed without merging is reopened and finished, and Dan is asked about
// leaving it closed only on a recorded reason it will never merge: a closing comment, or his own
// earlier answer, naming the PR that superseded it. The comments below are measured from
// danwright32/claude-config's closed unmerged PRs (#1595, #1627, #1644) and #1716's own closing comment.
function REOPEN(n: number) {
  return `PR #${n} was closed without merging: reopen it (gh pr reopen ${n}) and finish it, as Dan would rather merge it. Ask him whether to leave it closed (mcp__scope-modes__leave_pr_open) only when he said earlier that another PR superseded it, passing his words as dan_said`
}
describe('a PR closed without merging is finished unless a recorded reason says it will never merge (#1767)', () => {
  const closedAt = '2026-10-23T18:26:34Z'
  // #1595's three comments: a lessons review, a conflict note naming #1590 39 minutes before it
  // closed, and the closing comment naming the PR that replaced it.
  const pr1595 = {
    number: 1595,
    closedAt,
    comments: [
      { body: '## Lessons review at 856eb73\n\nTwo minor findings, both answered in 02d8daa.', createdAt: '2026-10-23T17:04:30Z' },
      { body: '## Not merged yet: conflicts with main\n\nmerge-when-ready stopped when GitHub could not update this branch with main: #1590 merged first', createdAt: '2026-10-23T17:47:10Z' },
      { body: "Replaced by #1606, opened from the rebased branch design-guard-script-args-1586-v2 on Dan's choice (2026-10-23) rather than force pushing this branch.", createdAt: '2026-10-23T18:26:33Z' },
    ],
  }
  test('the closing comment is the one posted with the close or after it, never discussion from before', () => {
    expect(closingComments(pr1595).map(c => c.refs)).toEqual([[{ number: 1606 }]])
    // A comment posted after the close still says why it closed.
    const later = { ...pr1595, comments: [...pr1595.comments, { body: 'Superseded by o/other#9.', createdAt: '2026-10-24T09:00:00Z' }] }
    expect(closingComments(later).map(c => c.refs)).toEqual([[{ repo: 'o/other', number: 9 }], [{ number: 1606 }]])
    // With no close time given, every comment is read, newest first, so nothing is missed.
    expect(closingComments({ number: 1595, comments: pr1595.comments }).map(c => c.refs)).toEqual([[{ number: 1606 }], [{ number: 1590 }], []])
    expect(closingComments({ number: 1595, closedAt })).toEqual([])
  })
  test('what a comment names: #N and owner/name#N, never the PR itself, an HTML entity, a heading or a link (mod-kit reads links)', () => {
    expect(prRefs('Replaced by #1645, which merged and closed #1604.', { number: 1644 })).toEqual([{ number: 1645 }, { number: 1604 }])
    expect(prRefs('see https://github.com/o/r/pull/716#issuecomment-1 and o/x#3', { number: 711 })).toEqual([{ repo: 'o/x', number: 3 }])
    expect(prRefs('o/r#711 is this one, o/other#711 is not', { repo: 'o/r', number: 711 })).toEqual([{ repo: 'o/other', number: 711 }])
    expect(prRefs('this is #711 again, &#35;12 and ## Heading 2', { number: 711 })).toEqual([])
    expect(prRefs('#716 #716', { number: 711 })).toEqual([{ number: 716 }])
  })
  // #1777: measured on 2026-10-26 across danwright32's closed unmerged PRs (read only gh calls): 9 in
  // claude-config, 8 with comments, and 59 in ovation, overture, PostRoll, downbeat and backstage, 53
  // with comments. Every comment saying why a PR closed was posted 0 to 2 seconds before the close or
  // after it; the nearest discussion before a close came 477 seconds before (#1627's lessons review),
  // then 524 (#964's). Ten minutes took in both, so the window is two minutes.
  test('the window is two minutes before the close, set from the measured closes (#1777)', () => {
    const closedAt = '2026-10-23T23:46:34Z'
    const at = (secsBefore: number) => new Date(Date.parse(closedAt) - secsBefore * 1000).toISOString()
    // A comment naming a PR, posted when #1627's were: its lessons review 477 seconds before it
    // closed, #964's 524 before, its closing comment with the close; then each edge of the window.
    const pr = (secsBefore: number) => ({ number: 1627, closedAt, comments: [{ body: 'Names #5.', createdAt: at(secsBefore) }] })
    expect(closingComments(pr(477))).toEqual([])
    expect(closingComments(pr(524))).toEqual([])
    expect(closingComments(pr(121))).toEqual([])
    expect(closingComments(pr(120)).map(c => c.refs)).toEqual([[{ number: 5 }]])
    expect(closingComments(pr(2)).map(c => c.refs)).toEqual([[{ number: 5 }]])
    expect(closingComments(pr(0)).map(c => c.refs)).toEqual([[{ number: 5 }]])
    // ovation#711's reason was posted almost seven hours after it closed, and is still read.
    expect(closingComments(pr(-24827)).map(c => c.refs)).toEqual([[{ number: 5 }]])
  })
  test("a PR named only by a github.com link is read once mod-kit's link reader has named its repository (#1777)", () => {
    const text = 'Superseded by https://github.com/o/r/pull/716, and see #12.'
    expect(prLinks(text)).toEqual([{ link: 'https://github.com/o/r/pull/716', number: 716 }])
    const linked = new Map<string, string | null>([['https://github.com/o/r/pull/716', 'o/r']])
    expect(prRefs(text, { repo: 'o/r', number: 711 }, linked)).toEqual([{ repo: 'o/r', number: 716 }, { number: 12 }])
    // In the order the text names them.
    expect(prRefs('#12, then https://github.com/o/r/pull/716', { number: 711 }, linked)).toEqual([{ number: 12 }, { repo: 'o/r', number: 716 }])
    // Unread by mod-kit, or a link it says names no GitHub repository, names nothing.
    expect(prRefs(text, { repo: 'o/r', number: 711 })).toEqual([{ number: 12 }])
    expect(prRefs('see https://example.com/o/r/pull/716', { number: 711 }, new Map([['https://example.com/o/r/pull/716', null]]))).toEqual([])
    // The PR's own link is never why it closed, and one PR linked twice is named once.
    const own = new Map<string, string | null>([['https://github.com/o/r/pull/711', 'o/r']])
    expect(prRefs('this is https://github.com/o/r/pull/711', { repo: 'o/r', number: 711 }, own)).toEqual([])
    expect(prRefs('https://github.com/o/r/pull/716 and https://github.com/o/r/pull/716/files', { number: 711 }, linked)).toEqual([{ repo: 'o/r', number: 716 }])
    // A closing comment naming its PR by link alone.
    const pr711 = { number: 711, repo: 'o/r', closedAt: '2026-10-09T15:00:00Z', comments: [{ body: 'Superseded by https://github.com/o/r/pull/716', createdAt: '2026-10-09T21:53:47Z' }] }
    expect(closingComments(pr711, linked).map(c => c.refs)).toEqual([[{ repo: 'o/r', number: 716 }]])
    expect(closingComments(pr711).map(c => c.refs)).toEqual([[]])
  })
  test("#1716's closing comment names only an issue, so the caller asks GitHub which numbers are PRs", () => {
    const pr1716 = {
      number: 1716,
      closedAt: '2026-10-25T22:43:43Z',
      comments: [{ body: "Closed unmerged by Dan's choice on 2026-10-25: three review rounds each found another English phrasing that let a stood-by denial read as withdrawn, so #1702 is now fixed by changing the refusal message.", createdAt: '2026-10-25T22:43:42Z' }],
    }
    expect(closingComments(pr1716).map(c => c.refs)).toEqual([[{ number: 1702 }]])
  })
  test('a quote is one line, cut at 200 characters', () => {
    expect(quoteOf('Replaced by #1629,\n\nopened  from the rebased branch.')).toBe('Replaced by #1629, opened from the rebased branch.')
    const long = quoteOf(`Replaced by #1. ${'x'.repeat(300)}`)
    expect(long.length).toBe(200)
    expect(long.endsWith('...')).toBe(true)
  })
  test('with a recorded reason, Dan is asked, the reason quoted; without one, it is reopened and finished', () => {
    const closed: Reading = { ...merged, pr: { number: 1595, state: 'CLOSED', issues: [] }, deploy: null }
    expect(outstanding(closed)).toEqual([REOPEN(1595)])
    const neverMerge = { from: 'comment' as const, pr: { number: 1606 }, quote: 'Replaced by #1606.' }
    expect(outstanding({ ...closed, pr: { number: 1595, state: 'CLOSED', issues: [], neverMerge } })).toEqual([
      'PR #1595 was closed without merging, and its closing comment names PR #1606 ("Replaced by #1606."): ask Dan whether to leave it closed (mcp__scope-modes__leave_pr_open)',
    ])
    expect(neverMergeSaid(neverMerge, true)).toBe('its closing comment names PR #1606 ("Replaced by #1606.")')
    const dan = { from: 'dan' as const, pr: { repo: 'o/x', number: 3 }, quote: 'leave it, o/x#3 replaced it' }
    expect(neverMergeSaid(dan)).toBe('Dan named PR o/x#3 earlier ("leave it, o/x#3 replaced it")')
    expect(neverMergeSaid(dan, true)).toBe('you named PR o/x#3 earlier ("leave it, o/x#3 replaced it")')
    // His answer to leave it closed settles it either way.
    const choice: LeftClosed = { repo: 'o/r', number: 1595, closed: true, why: 'its closing comment names PR #1606' }
    expect(outstanding({ ...closed, pr: { number: 1595, state: 'CLOSED', issues: [], neverMerge }, choice })).toEqual([])
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
  // #1123: changes git itself made (mv, rm, a checkout of a path, a restore) were never counted, so a
  // session could finish with that work uncommitted and the finish toast named it as another's.
  test('what git itself changed, as the write reader names it, is the session\'s too, a folder with all under it', () => {
    const writes = {
      ...none,
      byGit: [
        { word: 'new.ts', path: '/repo/new.ts', does: 'write' as const, tree: true as const },
        { word: 'old.ts', path: '/repo/old.ts', does: 'remove' as const },
        { word: ':/docs', does: 'write' as const },
      ],
    }
    expect(filesWritten({ tool: 'Bash', input: {}, writes })).toEqual(['/repo/new.ts', '/repo/new.ts/', '/repo/old.ts'])
  })
  test('a patch git applies names the files it changes: both sides of each diff, its strip and folder honoured', () => {
    const patch = [
      'diff --git a/src/app.ts b/src/app.ts',
      'index 1..2 100644',
      '--- a/src/app.ts',
      '+++ b/src/app.ts',
      '@@ -1 +1 @@',
      '-a',
      '+b',
      'diff --git a/old name.md b/docs/new name.md',
      'similarity index 90%',
      'rename from old name.md',
      'rename to docs/new name.md',
      'diff --git a/gone.ts b/gone.ts',
      'deleted file mode 100644',
      '--- a/gone.ts',
      '+++ /dev/null',
    ].join('\n')
    expect(patchedPaths([], patch)).toEqual(['src/app.ts', 'old name.md', 'docs/new name.md', 'gone.ts'])
    expect(patchedPaths(['-p2'], '--- a/x/y.ts\t2026-01-01\n+++ b/x/y.ts\t2026-01-02\n')).toEqual(['y.ts'])
    expect(patchedPaths(['--directory=sub', '-p', '0'], '--- y.ts\n+++ y.ts\n')).toEqual(['sub/y.ts'])
    expect(patchedPaths([], 'not a patch')).toEqual([])
    // A removed line reading "-- x" inside a hunk is no header.
    expect(patchedPaths([], '--- a/k.ts\n+++ b/k.ts\n@@ -1,2 +1 @@\n--- a/not/a/path\n-x\n')).toEqual(['k.ts'])
  })
  test('a stash pop or apply names the stash it takes, the newest by default; any other stash command none', () => {
    expect(stashTaken(['pop'])).toBe('stash@{0}')
    expect(stashTaken(['apply', '--index', 'stash@{2}'])).toBe('stash@{2}')
    expect(stashTaken(['pop', '-q', '1'])).toBe('1')
    expect(stashTaken(['push', '-m', 'x'])).toBeUndefined()
    expect(stashTaken(['list'])).toBeUndefined()
    expect(stashTaken([])).toBeUndefined()
  })
  // #1664: a file handed to a script as its argument counts as written, as every other gate has
  // counted it since #1592, so winding down never lets it go uncommitted unmentioned. A pattern the
  // reader can only place in a folder names no file, since that folder may hold another session's.
  test("a file handed to a script as its argument is this session's, as mod-kit's write reader gives it in runs (#1664)", () => {
    const writes = { ...none, runs: commandWrites('python3 tool.py src/a.ts "src/*.md"', '/repo', '/Users/x').runs }
    expect(writes.runs?.length).toBe(1)
    expect(filesWritten({ tool: 'Bash', input: {}, writes })).toEqual(['/repo/src/a.ts'])
    expect(whoseFiles(['src/a.ts', 'src/theirs.md', 'tool.py'], '/repo', filesWritten({ tool: 'Bash', input: {}, writes }))).toEqual({ own: ['src/a.ts'], others: ['src/theirs.md', 'tool.py'] })
    // A script run by its own name, handed a file under home.
    const direct = { ...none, runs: commandWrites('./fix.sh ~/notes/today.md', '/repo', '/Users/x').runs }
    expect(filesWritten({ tool: 'Bash', input: {}, writes: direct })).toEqual(['/Users/x/notes/today.md'])
    // Since #1682 the reader gives a `python -m` module and an `npx` tool the same way, so their
    // arguments count too.
    const module = { ...none, runs: commandWrites('python3 -m tool src/a.ts', '/repo', '/Users/x').runs }
    expect(module.runs?.length).toBe(1)
    expect(filesWritten({ tool: 'Bash', input: {}, writes: module })).toEqual(['/repo/src/a.ts'])
    // Through --write: without it prettier prints the file and changes nothing (#1827).
    const npx = { ...none, runs: commandWrites('npx prettier --write src/b.ts', '/repo', '/Users/x').runs }
    expect(npx.runs?.length).toBe(1)
    expect(filesWritten({ tool: 'Bash', input: {}, writes: npx })).toContain('/repo/src/b.ts')
  })
  test("a git mv into an existing folder claims the moved file, never another session's file beside it (#1123 lessons review)", () => {
    const writes = { ...none, byGit: commandWrites('git mv a.ts lib', '/repo', '/Users/x').byGit }
    expect(whoseFiles(['lib/a.ts', 'lib/theirs.ts'], '/repo', filesWritten({ tool: 'Bash', input: {}, writes }))).toEqual({ own: ['lib/a.ts'], others: ['lib/theirs.ts'] })
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
