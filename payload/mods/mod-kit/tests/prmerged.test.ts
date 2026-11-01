import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { askPr, failureOf, VIEW_FIELDS, type PrAnswer } from '../hooks/prmerged.ts'
import type { GhRun } from '../hooks/ghaccounts.ts'
import { linkRepo } from '../hooks/repo.ts'

// Whether GitHub says a pull request merged (#1991): the one check is it live's turn end and the goal
// box both make, asked as each account, by the repository where one was read, and counting a merge
// GitHub confirms whatever its time, only for that number in that repository.
const ran = (exitCode: number, stdout = '', stderr = ''): GhRun => ({ exitCode, stdout, stderr })
type Call = { argv: string[]; cwd?: string; token?: string }
const REPO = 'acme-hq/booking'
const STATUS = '  Logged in to github.com account dan-personal (keyring)\n  Logged in to github.com account acme-dan (keyring)\n'
const answer = (more: Record<string, unknown> = {}) => ran(0, JSON.stringify({ number: 4284, state: 'MERGED', mergedAt: '2026-10-31T12:00:00Z', url: `https://github.com/${REPO}/pull/4284`, ...more }))
const ask = async (view: (c: Call) => GhRun, o: { pr: number; repo?: string; cwd?: string } = { pr: 4284, repo: REPO, cwd: '/gone/worktree' }) => {
  const calls: Call[] = []
  const run = async (argv: string[], init: { cwd?: string; env?: Record<string, string> }) => {
    const c: Call = { argv, ...(init.cwd ? { cwd: init.cwd } : {}), ...(init.env?.GH_TOKEN ? { token: init.env.GH_TOKEN } : {}) }
    calls.push(c)
    if (argv[1] === 'auth' && argv[2] === 'status') return ran(0, '', STATUS)
    if (argv[1] === 'auth') return argv[4] === 'acme-dan' ? ran(0, 'tok-acme\n') : ran(1, '', 'no oauth token found')
    return view(c)
  }
  const got: PrAnswer = await askPr({ run, linkRepo: async link => linkRepo(link) }, o)
  return { got, views: calls.filter(c => c.argv[1] === 'pr') }
}

test('a merge GitHub confirms is asked by its repository, never in the folder, with every field it reads', async () => {
  const { got, views } = await ask(() => answer())
  expect(got).toEqual({ kind: 'merged', repo: REPO, url: `https://github.com/${REPO}/pull/4284`, at: Date.parse('2026-10-31T12:00:00Z') })
  expect(views).toEqual([{ argv: ['gh', 'pr', 'view', '4284', '--repo', REPO, '--json', VIEW_FIELDS] }])
})

test('a repository only another account can see is asked again as each account', async () => {
  const { got, views } = await ask(c => (c.token === 'tok-acme' ? answer() : ran(1, '', `GraphQL: Could not resolve to a Repository with the name '${REPO}'.`)))
  expect(got.kind).toBe('merged')
  expect(views.map(v => v.token ?? 'active')).toEqual(['active', 'tok-acme'])
})

test('with no repository read, it is asked in the folder, and named by the link GitHub gives', async () => {
  const { got, views } = await ask(() => answer(), { pr: 4284, cwd: '/repo' })
  expect(got).toMatchObject({ kind: 'merged', repo: REPO })
  expect(views[0]).toEqual({ argv: ['gh', 'pr', 'view', '4284', '--json', VIEW_FIELDS], cwd: '/repo' })
})

test('a merge long before the question is still that merge: its time is never compared with anything', async () => {
  const { got } = await ask(() => answer({ mergedAt: '2020-01-01T00:00:00Z' }))
  expect(got).toMatchObject({ kind: 'merged', at: Date.parse('2020-01-01T00:00:00Z') })
})

test('open, closed and a number that is no pull request are each their own answer', async () => {
  expect((await ask(() => answer({ state: 'OPEN', mergedAt: null }))).got).toEqual({ kind: 'open', repo: REPO })
  expect((await ask(() => answer({ state: 'CLOSED', mergedAt: null }))).got).toEqual({ kind: 'closed', repo: REPO })
  // The repository answered that the number is no pull request: no other account is asked.
  const notAPr = await ask(() => ran(1, '', 'GraphQL: Could not resolve to a PullRequest with the number of 4284. (repository.pullRequest)'))
  expect(notAPr.got).toEqual({ kind: 'not a pr' })
  expect(notAPr.views).toHaveLength(1)
})

test('no other answer proves anything, and each says why', async () => {
  const cases: [string, GhRun, RegExp][] = [
    ['a call that failed for every account', ran(1, '', 'error connecting to api.github.com'), /could not be asked: error connecting to api\.github\.com/],
    ['an answer about another pull request', answer({ number: 4285 }), /answered for #4285/],
    ['a link naming another number', answer({ url: `https://github.com/${REPO}/pull/4285` }), /pull\/4285/],
    ['a link naming another repository', answer({ url: 'https://github.com/acme-hq/other/pull/4284' }), /answered for acme-hq\/other#4284/],
    ['a link naming no repository', answer({ url: 'https://example.com/acme/pull/4284' }), /names no repository/],
    ['a merge with no time', answer({ mergedAt: null }), /no time/],
    ['a state it does not know', answer({ state: 'DRAFT' }), /state "DRAFT"/],
    ['an answer that is not JSON', ran(0, 'MERGED'), /could not be read/],
  ]
  for (const [what, g, why] of cases) {
    const { got } = await ask(() => g)
    expect({ what, kind: got.kind, why: 'why' in got && why.test(got.why) }).toEqual({ what, kind: 'unproven', why: true })
  }
})

test('a runner or link reader that throws is said, never thrown on', async () => {
  const thrown = await askPr({ run: async () => { throw new Error('spawn gh ENOENT') }, linkRepo: async () => null }, { pr: 4284, repo: REPO })
  expect(thrown).toEqual({ kind: 'unproven', why: 'GitHub could not be asked: spawn gh ENOENT' })
  const unread = await askPr({ run: async () => answer(), linkRepo: async () => { throw new Error('mod-kit has no linkRepo') }, describe: () => 'said by the caller' }, { pr: 4284, repo: REPO })
  expect(unread).toEqual({ kind: 'unproven', why: `GitHub's link https://github.com/${REPO}/pull/4284 could not be read (said by the caller)` })
})

// #2000: is it live's other reads made as each account say why none answered the same way.
test("why no account answered: the first line from an account that could see the repository, else the first, and never a throw on none", () => {
  const hidden = ran(1, '', `GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)`)
  const refused = ran(1, '', 'HTTP 502: Bad Gateway\nmore detail')
  expect(failureOf([hidden, refused])).toBe('HTTP 502: Bad Gateway')
  expect(failureOf([hidden])).toBe(`GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)`)
  expect(failureOf([ran(4, '', '')])).toBe('gh exited 4')
  expect(failureOf([])).toBe('gh gave no answer')
})
