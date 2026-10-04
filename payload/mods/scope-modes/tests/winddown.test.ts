import { describe, expect, test } from 'claude-code/testing'
import { issuesOfBranch, newWork, outstanding, type Reading } from '../hooks/winddown.ts'

const gitOf = (words: string[]) => (words[0] === 'git' ? { sub: words[1], args: words.slice(2) } : undefined)
const bash = (...lines: string[][]) => newWork({ tool: 'Bash', input: {}, commands: lines.map(words => ({ words, git: gitOf(words) })), issues: [616] })
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
    expect(tool('EnterWorktree', {})?.what).toBe('start a new branch')
  })
  test('agent dispatch for another issue, but not for this one', () => {
    expect(tool('Agent', { prompt: 'Build issue #700 in the worktree' })?.what).toBe('dispatch an agent for issue #700')
    expect(tool('Agent', { prompt: 'Fix the failing check on #616' })).toBeUndefined()
    expect(tool('Agent', { prompt: 'Read the CI log and say why it failed' })).toBeUndefined()
  })
  test('fixing what blocks THIS issue is allowed: edits, commits, pushes, merging', () => {
    expect(tool('Edit', { file_path: '/repo/app.ts' })).toBeUndefined()
    expect(bash(['git', 'commit', '-m', 'fix the check'], ['git', 'push'])).toBeUndefined()
    expect(bash(['gh', 'pr', 'merge', '12', '--squash'])).toBeUndefined()
    expect(bash(['git', 'checkout', 'main'], ['git', 'branch', '-D', 'scope-modes-616'])).toBeUndefined()
  })
})

describe('issuesOfBranch', () => {
  test('the issue numbers a branch name carries', () => {
    expect(issuesOfBranch('scope-modes-616-621')).toEqual([616, 621])
    expect(issuesOfBranch('feat/620-addon-notes')).toEqual([620])
    expect(issuesOfBranch('main')).toEqual([])
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
  test('a PR closed without merging needs Dan', () => {
    expect(outstanding({ ...merged, pr: { number: 12, state: 'CLOSED', issues: [] } })).toEqual(['PR #12 was closed without merging; ask Dan what to do'])
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
