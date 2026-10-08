import { expect, test } from 'claude-code/testing'
import { isDefaultBranch, issuesOfBranch, mainOf, readBranch, type Run } from '../hooks/branch.ts'

// Where a checkout stands (#978), read once by the kit for every mod: its main working tree, branch,
// default branch and the issues the branch names. Each git read is the test's.

const ok = (stdout: string) => ({ exitCode: 0, stdout, stderr: '' })
const failed = (stderr: string) => ({ exitCode: 128, stdout: '', stderr })

// A git that answers each of the three reads as the test says; every other command is a failure of the test.
const gitSays = (says: { branch?: ReturnType<typeof ok>; worktrees?: ReturnType<typeof ok>; head?: ReturnType<typeof ok> | 'throws' }): { run: Run; asked: string[] } => {
  const asked: string[] = []
  const run: Run = async argv => {
    asked.push(argv.join(' '))
    const sub = argv.slice(3).join(' ')
    if (argv[0] !== 'git' || argv[1] !== '-C') throw new Error(`not a git read in the checkout: ${argv.join(' ')}`)
    if (sub === 'branch --show-current') return says.branch ?? ok('978-design-round-guard\n')
    if (sub === 'worktree list --porcelain') return says.worktrees ?? ok('worktree /Users/x/Apps/slate\nHEAD abc\nbranch refs/heads/main\n\nworktree /Users/x/Apps/slate/.claude/worktrees/a1\nHEAD def\nbranch refs/heads/978-design-round-guard\n')
    if (sub === 'symbolic-ref --short refs/remotes/origin/HEAD') {
      if (says.head === 'throws') throw new Error('git could not be started')
      return says.head ?? ok('origin/main\n')
    }
    throw new Error(`unexpected git read: ${sub}`)
  }
  return { run, asked }
}

test('the issues a branch names: every run of 2 to 6 digits on its own', () => {
  expect(issuesOfBranch('978-design-round-guard')).toEqual([978])
  expect(issuesOfBranch('fix/issue-41-and-52')).toEqual([41, 52])
  expect(issuesOfBranch('polish-header')).toEqual([])
  expect(issuesOfBranch('v2-header')).toEqual([])
  expect(issuesOfBranch('claude/issue-1234567')).toEqual([])
})

test('the main working tree is the first git lists', () => {
  expect(mainOf('worktree /a/b\nHEAD x\n\nworktree /a/b/.claude/worktrees/c\n')).toBe('/a/b')
  expect(mainOf('worktree /Users/x/Documents/Documents - Dan’s MacBook Pro/Bidspoke\nHEAD x\n')).toBe('/Users/x/Documents/Documents - Dan’s MacBook Pro/Bidspoke')
  expect(mainOf('')).toBe(null)
})

test('the default branch is the one origin/HEAD names, else main or master', () => {
  expect(isDefaultBranch('main', 'main')).toBe(true)
  expect(isDefaultBranch('trunk', 'trunk')).toBe(true)
  expect(isDefaultBranch('main', 'trunk')).toBe(false)
  expect(isDefaultBranch('master', null)).toBe(true)
  expect(isDefaultBranch('978-x', null)).toBe(false)
})

test('a worktree on an issue branch: its project, branch, default and issues, from three reads at once', async () => {
  const g = gitSays({})
  expect(await readBranch('/Users/x/Apps/slate/.claude/worktrees/a1', g.run)).toEqual({
    root: '/Users/x/Apps/slate/.claude/worktrees/a1',
    main: '/Users/x/Apps/slate',
    branch: '978-design-round-guard',
    defaultBranch: 'main',
    isDefault: false,
    issues: [978],
  })
  expect(g.asked.length).toBe(3)
})

test('the default branch with origin/HEAD unset, or unreadable, falls back to main and master', async () => {
  const unset = await readBranch('/r', gitSays({ branch: ok('master\n'), head: failed('fatal: ref refs/remotes/origin/HEAD is not a symbolic ref') }).run)
  expect(unset).toMatchObject({ branch: 'master', defaultBranch: null, isDefault: true, issues: [] })
  const broken = await readBranch('/r', gitSays({ branch: ok('main\n'), head: 'throws' }).run)
  expect(broken).toMatchObject({ branch: 'main', defaultBranch: null, isDefault: true })
})

test('a branch git cannot read, a detached head, or no main working tree is unreadable, saying which', async () => {
  expect(await readBranch('/r', gitSays({ branch: failed('fatal: not a git repository') }).run)).toEqual({ root: '/r', main: '/Users/x/Apps/slate', unreadable: 'git could not read the branch: fatal: not a git repository' })
  expect(await readBranch('/r', gitSays({ branch: ok('\n') }).run)).toEqual({ root: '/r', main: '/Users/x/Apps/slate', unreadable: 'a detached head names no branch' })
  expect(await readBranch('/r', gitSays({ worktrees: failed('fatal: bad config') }).run)).toEqual({ root: '/r', main: null, unreadable: 'git could not list its worktrees: fatal: bad config' })
  expect(await readBranch('/r', gitSays({ worktrees: ok('') }).run)).toEqual({ root: '/r', main: null, unreadable: 'git named no main working tree' })
  // A git that cannot be started at all is unreadable too, never an empty branch.
  const dead: Run = async () => {
    throw new Error('spawn git ENOENT')
  }
  expect(await readBranch('/r', dead)).toEqual({ root: '/r', main: null, unreadable: 'git could not list its worktrees: spawn git ENOENT' })
})
