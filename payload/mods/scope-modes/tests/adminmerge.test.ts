import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { adminEndpoints, ghApiOf, judgeAdminMerge, pinnedOf, type GhJson } from '../hooks/adminmerge.ts'
import type { ModKitGh } from '../.claude-plugin/types/mod-kit/index.d.ts'
import { readCommands } from './read.ts'
import { linkRepo } from './mod-kit/hooks/repo.ts'

// #2125: an admin merge overnight, allowed only in a repository whose mergeOnly entry opts in
// ("adminMerge": "green-pinned"), only for the PR and head commit the command pins, only as a
// squash, and only when GitHub shows every required check on that commit passed. Commands are read
// by mod-kit's own reader (its byte for byte copy), as the mod reads them; GitHub's answers come from
// a stand in, so each case says what GitHub holds.
const SHA = 'a'.repeat(40)
const OTHER = 'b'.repeat(40)
const gh = (command: string): ModKitGh => {
  const g = readCommands(command)[0]?.gh
  if (!g) throw new Error(`no gh reading for ${command}`)
  return g
}
const PINNED = `gh pr merge 846 --admin --squash --match-head-commit ${SHA}`

const OPTED = { repo: 'o/r', mergeDeploys: false, adminMerge: 'green-pinned' }
const nightWith = (entry: Record<string, unknown>, more: Record<string, unknown> = {}) => ({ mayDeploy: [], mergeOnly: [entry], closed: [], ...more })
const NIGHT = nightWith(OPTED)

type Answers = Record<string, unknown>
const green = (): Answers => ({
  'repos/o/r/pulls/846': { state: 'open', draft: false, merged: false, head: { sha: SHA }, base: { ref: 'main' } },
  'repos/o/r/rules/branches/main?per_page=100': [{ type: 'pull_request' }, { type: 'required_status_checks', parameters: { required_status_checks: [{ context: 'test' }, { context: 'lint' }] } }],
  'repos/o/r/branches/main': { protected: false },
  [`repos/o/r/commits/${SHA}/check-runs?per_page=100`]: {
    total_count: 3,
    check_runs: [
      { name: 'test', status: 'completed', conclusion: 'success' },
      { name: 'lint', status: 'completed', conclusion: 'success' },
      { name: 'preview', status: 'completed', conclusion: 'skipped' },
    ],
  },
  [`repos/o/r/commits/${SHA}/status?per_page=100`]: { state: 'pending', total_count: 0, statuses: [] },
})
const apiOf = (answers: Answers, asked: string[] = []): GhJson => async endpoint => {
  asked.push(endpoint)
  if (!Object.prototype.hasOwnProperty.call(answers, endpoint)) return { why: `HTTP 404: Not Found (${endpoint})` }
  const a = answers[endpoint]
  return a !== null && typeof a === 'object' && 'fails' in (a as Record<string, unknown>) ? { why: String((a as { fails: string }).fails) } : { json: a }
}
// mod-kit's own link reader, as $.modkit.linkRepo answers it.
const linkRepoOf = async (link: string) => linkRepo(link)
const judge = (command: string, answers: Answers = green(), night: unknown = NIGHT, asked: string[] = []) => judgeAdminMerge(night, gh(command), 'o/r', apiOf(answers, asked), linkRepoOf)

describe('what the command must pin', () => {
  test('a squash, the full head commit and one PR number or link are pinned; anything else is refused before GitHub is asked', () => {
    expect(pinnedOf(gh(PINNED))).toEqual({ pr: 846, sha: SHA })
    expect(pinnedOf(gh(`gh pr merge https://github.com/o/r/pull/846 --admin -s --match-head-commit ${SHA.toUpperCase()} --subject x --body y`))).toEqual({ pr: 846, sha: SHA })
    const refused = (c: string) => {
      const p = pinnedOf(gh(c))
      return 'refuse' in p ? p.refuse : 'pinned'
    }
    expect(refused('gh pr merge 846 --admin --squash')).toBe('admin merge a PR without --match-head-commit naming its full head commit')
    expect(refused('gh pr merge 846 --admin --squash --match-head-commit abc1234')).toBe('admin merge a PR without --match-head-commit naming its full head commit')
    expect(refused(`gh pr merge 846 --admin --match-head-commit ${SHA}`)).toBe('admin merge a PR other than as a squash')
    expect(refused(`gh pr merge 846 --admin --merge --squash --match-head-commit ${SHA}`)).toBe('admin merge a PR with --merge')
    expect(refused(`gh pr merge 846 --admin --rebase --squash --match-head-commit ${SHA}`)).toBe('admin merge a PR with --rebase')
    expect(refused(`gh pr merge 846 --admin --squash --auto --match-head-commit ${SHA}`)).toBe('admin merge a PR with --auto')
    expect(refused(`gh pr merge --admin --squash --match-head-commit ${SHA}`)).toBe('admin merge a PR it does not name by number')
    expect(refused(`gh pr merge some-branch --admin --squash --match-head-commit ${SHA}`)).toBe('admin merge a PR it does not name by number')
    expect(refused(`gh pr merge 846 --admin --squash --match-head-commit ${SHA} --match-head-commit ${OTHER}`)).toBe('admin merge a PR pinned to more than one head commit')
  })
})

describe('the repository must opt in, and its night must let it merge', () => {
  test('refused, and GitHub never asked, without adminMerge on its entry, on mayDeploy, closed, or where a merge is held', async () => {
    const asked: string[] = []
    const off = 'admin merge a PR in o/r, which does not allow admin merges overnight (adminMerge on its mergeOnly entry in mods/sleep-repos.local.json)'
    expect(await judge(PINNED, green(), nightWith({ repo: 'o/r', mergeDeploys: false }), asked)).toBe(off)
    expect(await judge(PINNED, green(), { mayDeploy: ['o/r'], mergeOnly: [], closed: [] }, asked)).toBe(off)
    expect(await judge(PINNED, green(), nightWith({ repo: 'o/r', mergeDeploys: false, adminMerge: 'always' }), asked)).toBe(off)
    expect(await judge(PINNED, green(), nightWith(OPTED, { waitOwners: ['O'] }), asked)).toMatch(/^admin merge a PR in o\/r, and every repository owned by O waits overnight/)
    // null, not undefined, which would take the helper's default night.
    expect(await judge(PINNED, green(), null, asked)).toMatch(/^admin merge a PR in o\/r, and the sleep record carries no merge and deploy lists/)
    expect(await judge(PINNED, green(), nightWith({ repo: 'o/r', mergeDeploys: true, adminMerge: 'green-pinned' }), asked)).toBe('admin merge a PR in o/r, where a merge deploys, so it is never merged overnight')
    expect(await judge(PINNED, green(), nightWith({ repo: 'o/r', mergeDeploys: 'unknown', adminMerge: 'green-pinned' }), asked)).toBe('admin merge a PR in o/r, where whether a merge deploys is not recorded, so it is never merged overnight')
    expect(asked).toEqual([])
  })
})

describe('GitHub must show the pinned commit green', () => {
  test('allowed when the PR is open on the pinned commit and every required check on it passed', async () => {
    const asked: string[] = []
    expect(await judge(PINNED, green(), NIGHT, asked)).toBeUndefined()
    expect(asked).toEqual(adminEndpoints('o/r', 846, SHA, 'main'))
  })
  test('required checks from classic branch protection count as well as rulesets, a status context included', async () => {
    const a = green()
    a['repos/o/r/branches/main'] = { protected: true, protection: { enabled: true, required_status_checks: { contexts: ['ci/build'], checks: [{ context: 'ci/build' }] } } }
    a[`repos/o/r/commits/${SHA}/status?per_page=100`] = { state: 'pending', total_count: 1, statuses: [{ context: 'ci/build', state: 'pending' }] }
    expect(await judge(PINNED, a)).toBe('admin merge PR #846 in o/r, whose required check ci/build is pending on its head commit')
    a[`repos/o/r/commits/${SHA}/status?per_page=100`] = { state: 'success', total_count: 1, statuses: [{ context: 'ci/build', state: 'success' }] }
    expect(await judge(PINNED, a)).toBeUndefined()
    a['repos/o/r/branches/main'] = { protected: true }
    expect(await judge(PINNED, a)).toBe("admin merge PR #846 in o/r, whose base branch main's protection could not be read")
  })
  test('a required check that failed, is still running, or never reported refuses', async () => {
    const runs = (r: unknown[]) => ({ ...green(), [`repos/o/r/commits/${SHA}/check-runs?per_page=100`]: { total_count: r.length, check_runs: r } })
    const lint = { name: 'lint', status: 'completed', conclusion: 'success' }
    expect(await judge(PINNED, runs([{ name: 'test', status: 'completed', conclusion: 'failure' }, lint]))).toBe('admin merge PR #846 in o/r, whose required check test is failure on its head commit')
    expect(await judge(PINNED, runs([{ name: 'test', status: 'in_progress', conclusion: null }, lint]))).toBe('admin merge PR #846 in o/r, whose required check test is in_progress on its head commit')
    expect(await judge(PINNED, runs([lint]))).toBe('admin merge PR #846 in o/r, whose required check test has not reported on its head commit')
    // A required check skipped is not green.
    expect(await judge(PINNED, runs([{ name: 'test', status: 'completed', conclusion: 'skipped' }, lint]))).toBe('admin merge PR #846 in o/r, whose required check test is skipped on its head commit')
    // Two runs of one required name: both must pass.
    expect(await judge(PINNED, runs([{ name: 'test', status: 'completed', conclusion: 'success' }, { name: 'test', status: 'completed', conclusion: 'failure' }, lint]))).toBe('admin merge PR #846 in o/r, whose required check test is failure on its head commit')
  })
  test('any other check failing or still running refuses too: the PR is not green', async () => {
    const a = green()
    const key = `repos/o/r/commits/${SHA}/check-runs?per_page=100`
    a[key] = { total_count: 3, check_runs: [...(a[key] as { check_runs: unknown[] }).check_runs.slice(0, 2), { name: 'e2e', status: 'completed', conclusion: 'timed_out' }] }
    expect(await judge(PINNED, a)).toBe('admin merge PR #846 in o/r, whose check e2e is timed_out on its head commit')
    a[key] = { total_count: 3, check_runs: [...(a[key] as { check_runs: unknown[] }).check_runs.slice(0, 2), { name: 'e2e', status: 'queued', conclusion: null }] }
    expect(await judge(PINNED, a)).toBe('admin merge PR #846 in o/r, whose check e2e is queued on its head commit')
    const b = green()
    b[`repos/o/r/commits/${SHA}/status?per_page=100`] = { state: 'failure', total_count: 1, statuses: [{ context: 'deploy/preview', state: 'error' }] }
    expect(await judge(PINNED, b)).toBe('admin merge PR #846 in o/r, whose check deploy/preview is error on its head commit')
  })
  test('the PR moved, closed, drafted, or not on the pinned commit refuses', async () => {
    const pr = (p: Record<string, unknown>) => ({ ...green(), 'repos/o/r/pulls/846': { state: 'open', draft: false, merged: false, head: { sha: SHA }, base: { ref: 'main' }, ...p } })
    expect(await judge(PINNED, pr({ head: { sha: OTHER } }))).toBe(`admin merge PR #846 in o/r, whose head is now ${OTHER.slice(0, 12)}, not the pinned ${SHA.slice(0, 12)}`)
    expect(await judge(PINNED, pr({ state: 'closed' }))).toBe('admin merge PR #846 in o/r, which is not open')
    expect(await judge(PINNED, pr({ draft: true }))).toBe('admin merge PR #846 in o/r, which is a draft')
    expect(await judge(PINNED, pr({ base: {} }))).toBe('admin merge PR #846 in o/r, whose answer from GitHub could not be read')
  })
  test('nothing required, a list GitHub cut short, or GitHub not answering refuses: what cannot be verified is refused', async () => {
    const none = { ...green(), 'repos/o/r/rules/branches/main?per_page=100': [{ type: 'pull_request' }] }
    expect(await judge(PINNED, none)).toBe('admin merge PR #846 in o/r, whose base branch main requires no check, so there is nothing to hold an admin merge to')
    const cut = { ...green(), [`repos/o/r/commits/${SHA}/check-runs?per_page=100`]: { total_count: 140, check_runs: [{ name: 'test', status: 'completed', conclusion: 'success' }, { name: 'lint', status: 'completed', conclusion: 'success' }] } }
    expect(await judge(PINNED, cut)).toBe("admin merge PR #846 in o/r, whose head commit's checks GitHub did not list in full")
    const down = { ...green(), 'repos/o/r/pulls/846': { fails: 'error connecting to api.github.com' } }
    expect(await judge(PINNED, down)).toBe('admin merge PR #846 in o/r, which GitHub could not be asked about (error connecting to api.github.com)')
    const rules = { ...green(), 'repos/o/r/rules/branches/main?per_page=100': { message: 'odd' } }
    expect(await judge(PINNED, rules)).toBe("admin merge PR #846 in o/r, whose base branch main's rules could not be read")
    const statuses = { ...green(), [`repos/o/r/commits/${SHA}/status?per_page=100`]: { state: 'success', total_count: 120, statuses: [] } }
    expect(await judge(PINNED, statuses)).toBe("admin merge PR #846 in o/r, whose head commit's checks GitHub did not list in full")
    const odd = { ...green(), [`repos/o/r/commits/${SHA}/check-runs?per_page=100`]: { total_count: 1, check_runs: [{ name: 'test', status: 'completed' }] } }
    expect(await judge(PINNED, odd)).toBe("admin merge PR #846 in o/r, whose head commit's checks could not be read")
  })
  test('a link to another repository is refused, though the write rule reads the link too', async () => {
    expect(await judge(`gh pr merge https://github.com/x/y/pull/846 --admin --squash --match-head-commit ${SHA}`)).toBe('admin merge PR #846 through a link to x/y from a checkout of o/r')
    expect(await judge(`gh pr merge https://github.com/O/R/pull/846 --admin --squash --match-head-commit ${SHA}`)).toBeUndefined()
  })
  test('a link is read only through the link reader handed in, and refuses when it cannot be read exactly', async () => {
    const cmd = (link: string) => gh(`gh pr merge ${link} --admin --squash --match-head-commit ${SHA}`)
    const refused = 'admin merge a PR it does not name by number'
    expect(await judgeAdminMerge(NIGHT, cmd('https://github.com/o/r/extra/pull/846'), 'o/r', apiOf(green()), linkRepoOf)).toBe(refused)
    expect(await judgeAdminMerge(NIGHT, cmd('https://github.com/o/r/pull/846'), 'o/r', apiOf(green()), async () => null)).toBe(refused)
    expect(await judgeAdminMerge(NIGHT, cmd('https://github.com/o/r/pull/846'), 'o/r', apiOf(green()), async () => { throw new Error('reader down') })).toBe(refused)
    const asked: string[] = []
    expect(await judgeAdminMerge(NIGHT, cmd('https://github.com/o/r/pull/846'), 'o/r', apiOf(green(), asked), async () => 'x/y')).toBe(refused)
    expect(asked).toEqual([])
  })
})

describe('GitHub read through gh api', () => {
  const ran = (r: Partial<{ exitCode: number; stdout: string; stderr: string; isStdoutTruncated: boolean }>) => async (argv: string[]) => {
    expect(argv).toEqual(['gh', 'api', 'repos/o/r/pulls/1'])
    return { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, ...r }
  }
  test('its JSON, or why not: gh failing, an answer cut short, an answer that is not JSON', async () => {
    expect(await ghApiOf(ran({ stdout: '{"a":1}' }))('repos/o/r/pulls/1')).toEqual({ json: { a: 1 } })
    expect(await ghApiOf(ran({ exitCode: 1, stderr: 'warn\ngh: Not Found (HTTP 404)\n' }))('repos/o/r/pulls/1')).toEqual({ why: 'gh: Not Found (HTTP 404)' })
    expect(await ghApiOf(ran({ exitCode: -1 }))('repos/o/r/pulls/1')).toEqual({ why: 'gh api exited -1' })
    expect(await ghApiOf(ran({ stdout: '{"a":', isStdoutTruncated: true }))('repos/o/r/pulls/1')).toEqual({ why: 'its answer was cut short' })
    expect(await ghApiOf(ran({ stdout: 'not json' }))('repos/o/r/pulls/1')).toEqual({ why: 'its answer was not JSON' })
  })
})
