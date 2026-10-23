import { expect, test } from 'claude-code/testing'
import { branchAt, isDefaultBranch, issuesOfBranch, mainOf, readBranch, type Run } from '../hooks/branch.ts'

// Where a checkout stands (#978), read once by the kit for every mod: its main working tree, branch,
// default branch and the issues the branch names. Each git read is the test's.

const ok = (stdout: string) => ({ exitCode: 0, stdout, stderr: '' })
const failed = (stderr: string) => ({ exitCode: 128, stdout: '', stderr })

// A git that answers each of the three reads as the test says; every other command is a failure of the test.
// `rebasing` is the branch a rebase in progress names in its notes, as git keeps them under the
// checkout's git folder (rebase-merge for an interactive or merge rebase, rebase-apply for the rest).
const gitSays = (says: { branch?: ReturnType<typeof ok>; worktrees?: ReturnType<typeof ok>; head?: ReturnType<typeof ok> | 'throws'; rebasing?: { kind: 'rebase-merge' | 'rebase-apply'; headName: string; inWorktree?: boolean } }): { run: Run; asked: string[] } => {
  const asked: string[] = []
  const run: Run = async argv => {
    asked.push(argv.join(' '))
    if (argv[0] === 'cat') {
      // A worktree's notes sit under the main checkout's git folder, named by an absolute path.
      const want = says.rebasing ? (says.rebasing.inWorktree ? `/main/.git/worktrees/r/${says.rebasing.kind}/head-name` : `/r/.git/${says.rebasing.kind}/head-name`) : ''
      return argv[1] === want ? ok(`${(says.rebasing as { headName: string }).headName}\n`) : { exitCode: 1, stdout: '', stderr: `cat: ${argv[1]}: No such file or directory` }
    }
    const sub = argv.slice(3).join(' ')
    if (argv[0] !== 'git' || argv[1] !== '-C') throw new Error(`not a git read in the checkout: ${argv.join(' ')}`)
    if (sub === 'branch --show-current') return says.branch ?? ok('978-design-round-guard\n')
    if (sub === 'worktree list --porcelain') return says.worktrees ?? ok('worktree /Users/x/Apps/slate\nHEAD abc\nbranch refs/heads/main\n\nworktree /Users/x/Apps/slate/.claude/worktrees/a1\nHEAD def\nbranch refs/heads/978-design-round-guard\n')
    if (sub === 'rev-parse --git-path rebase-merge/head-name --git-path rebase-apply/head-name')
      return says.rebasing?.inWorktree ? ok('/main/.git/worktrees/r/rebase-merge/head-name\n/main/.git/worktrees/r/rebase-apply/head-name\n') : ok('.git/rebase-merge/head-name\n.git/rebase-apply/head-name\n')
    if (sub === 'symbolic-ref --short refs/remotes/origin/HEAD') {
      if (says.head === 'throws') throw new Error('git could not be started')
      return says.head ?? ok('origin/main\n')
    }
    throw new Error(`unexpected git read: ${sub}`)
  }
  return { run, asked }
}

// #985 review, three times: the walk for a checkout answers undefined for none, and a null from it
// must read the same way, never reach git as `git -C null`.
test('a walk that finds no checkout, as undefined or as null, answers null and asks git nothing', async () => {
  for (const none of [undefined, null]) {
    const g = gitSays({})
    expect(await branchAt('/tmp/backup/page.tsx', async () => none, g.run)).toBe(null)
    expect(g.asked).toEqual([])
  }
  const g = gitSays({})
  expect(await branchAt('/r/app/page.tsx', async () => '/r', g.run)).toMatchObject({ root: '/r', branch: '978-design-round-guard' })
  expect(g.asked.length).toBe(3)
})

test('the issues a branch names: each part of it that is 2 to 6 digits, with at most one letter after', () => {
  expect(issuesOfBranch('978-design-round-guard')).toEqual([978])
  expect(issuesOfBranch('fix/issue-41-and-52')).toEqual([41, 52])
  expect(issuesOfBranch('fix/1282-stale-agent-locks')).toEqual([1282])
  expect(issuesOfBranch('feat/1279-ask-before-sleep')).toEqual([1279])
  expect(issuesOfBranch('issue-1282')).toEqual([1282])
  expect(issuesOfBranch('sleep/1015')).toEqual([1015])
  expect(issuesOfBranch('fix_1282.stale')).toEqual([1282])
  // A part of an issue split across branches, as 961a to 961d were for #961.
  expect(issuesOfBranch('961a-mod-kit-gh-reader')).toEqual([961])
  expect(issuesOfBranch('polish-header')).toEqual([])
  expect(issuesOfBranch('v2-header')).toEqual([])
  expect(issuesOfBranch('claude/issue-1234567')).toEqual([])
  // #1306: digits inside a word are not an issue. An agent worktree's random hex id named #7831, #26
  // and #84, and Dan's answers were kept under them for every later agent whose id held them too.
  expect(issuesOfBranch('worktree-agent-ad4e7831d26de84f8')).toEqual([])
  expect(issuesOfBranch('worktree-agent-a2551c61a359a761d')).toEqual([])
  expect(issuesOfBranch('fix/ab12cd-x')).toEqual([])
  expect(issuesOfBranch('fix/12ab-x')).toEqual([])
})

// #1475: a Bidspoke builder on connections-pr10-form-2338, step 10 of #2338's plan, was refused
// every screen edit because the design round guard read pr10 as #10. A step of a plan, a date or a
// version is never an issue, however it is joined to the rest of the name.
test('a plan step, a date or a version in a branch name is never read as an issue', () => {
  expect(issuesOfBranch('connections-pr10-form-2338')).toEqual([2338])
  expect(issuesOfBranch('connections-pr-10-form-2338')).toEqual([2338])
  for (const step of ['phase', 'step', 'stage', 'part', 'slice', 'wave', 'batch', 'round', 'pass', 'milestone', 'p', 'v', 'version']) {
    expect(issuesOfBranch(`${step}10-form-2338`)).toEqual([2338])
    expect(issuesOfBranch(`${step}-10-form-2338`)).toEqual([2338])
  }
  // Real names (claude-config, overture and postroll branches, 2026-10-22).
  expect(issuesOfBranch('faster-pr-testing-milestone-60')).toEqual([])
  expect(issuesOfBranch('record-milestone-61-decisions')).toEqual([])
  expect(issuesOfBranch('guard-costs/2026-09-03')).toEqual([])
  expect(issuesOfBranch('suite-count/2026-10-03')).toEqual([])
  expect(issuesOfBranch('dependabot/npm_and_yarn/tsx-4.23.12')).toEqual([])
  expect(issuesOfBranch('dependabot/npm_and_yarn/types/node-26.2.0')).toEqual([])
  expect(issuesOfBranch('dependabot/npm_and_yarn/vitest-4.1.11')).toEqual([])
  expect(issuesOfBranch('fix/1185-bypassed-routes-2-1-299')).toEqual([1185])
})

test('an issue a step word stands beside, glued to an i, or among several is still read', () => {
  // A step word before a number of three digits or more: each of these is the issue it names.
  expect(issuesOfBranch('faster-pr-989-daily-guard-sweep')).toEqual([989])
  expect(issuesOfBranch('reprep-listing-phase-1880')).toEqual([1880])
  expect(issuesOfBranch('downbeat-export-minimum-version-3193')).toEqual([3193])
  expect(issuesOfBranch('lint-each-body-once-per-pass-3498')).toEqual([3498])
  expect(issuesOfBranch('fix-docs-batch-2502-2532-2312-1820')).toEqual([2502, 2532, 2312, 1820])
  // overture names an issue i2968; a plan's slice i2 is one digit and stays none.
  expect(issuesOfBranch('i2968-dismissed-followup-render')).toEqual([2968])
  expect(issuesOfBranch('issue1475-x')).toEqual([1475])
  expect(issuesOfBranch('m80-4357-slice-i2-resolver')).toEqual([4357])
  expect(issuesOfBranch('i1-qb-parse')).toEqual([])
  expect(issuesOfBranch('fix/1015-1057-1085-mod-guards')).toEqual([1015, 1057, 1085])
  expect(issuesOfBranch('2232-2193-suite-stats')).toEqual([2232, 2193])
  expect(issuesOfBranch('m80-4356-phase2-parts45')).toEqual([4356])
  expect(issuesOfBranch('probe-4106-phase0c-rows')).toEqual([4106])
  expect(issuesOfBranch('collapse-4030-phase-2')).toEqual([4030])
  expect(issuesOfBranch('fix-99-phase5-backlog')).toEqual([99])
  expect(issuesOfBranch('ci-p0-594-595-597-689')).toEqual([594, 595, 597, 689])
  expect(issuesOfBranch('fix_1282.stale')).toEqual([1282])
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

// #1210: a rebase in progress leaves the head detached, and the design round guard then refused an
// edit for "a detached head names no branch" though the worktree's branch named its issue. git
// records the branch being rebased, so that is the branch, for either kind of rebase.
test('a rebase in progress reads as the branch being rebased, for either kind of rebase', async () => {
  for (const kind of ['rebase-merge', 'rebase-apply'] as const) {
    const g = gitSays({ branch: ok('\n'), rebasing: { kind, headName: 'refs/heads/fix/1205-shared-login-follower' } })
    expect(await readBranch('/r', g.run)).toMatchObject({ root: '/r', branch: 'fix/1205-shared-login-follower', isDefault: false, issues: [1205] })
  }
})

// In a worktree git names the notes by an absolute path under the main checkout (measured on a real
// conflicted rebase), which is the case #1210 was found in.
test('a rebase in progress in a worktree reads as its branch, from notes named by an absolute path', async () => {
  for (const kind of ['rebase-merge', 'rebase-apply'] as const) {
    const g = gitSays({ branch: ok('\n'), rebasing: { kind, headName: 'refs/heads/fix/1205-shared-login-follower', inWorktree: true } })
    expect(await readBranch('/r', g.run)).toMatchObject({ branch: 'fix/1205-shared-login-follower', issues: [1205] })
  }
})

test('a detached head with no rebase in progress, or notes naming no branch, is still unreadable', async () => {
  expect(await readBranch('/r', gitSays({ branch: ok('\n') }).run)).toMatchObject({ unreadable: 'a detached head names no branch' })
  expect(await readBranch('/r', gitSays({ branch: ok('\n'), rebasing: { kind: 'rebase-merge', headName: 'detached HEAD' } }).run)).toMatchObject({ unreadable: 'a detached head names no branch' })
})
