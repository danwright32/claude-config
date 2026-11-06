import type { ModKitGh } from '../.claude-plugin/types/mod-kit/index.d.ts'
import { ADMIN_MERGE, policyOf } from './mergedeploy.ts'

// Sleep mode (#2125): the one admin merge allowed overnight. In a repository whose main branch needs
// an approval only Dan can give, every merge is by admin, and an admin merge skips no check as long
// as it lands only the commit GitHub shows green. So `gh pr merge --admin` is allowed overnight only
// when all of these hold, and refused everywhere else, as before:
//
// - the repository's mergeOnly entry in mods/sleep-repos.local.json says "adminMerge": "green-pinned",
//   as settled at bedtime, and phase 7 lets it merge tonight (not closed, not waiting, a merge there
//   does not deploy);
// - the command is a squash, names one PR by number or link, and pins its full head commit with
//   exactly one --match-head-commit, carrying no other flag than a subject, a body and the repository;
// - GitHub shows that PR open, not a draft, its head still the pinned commit, and on that commit every
//   check its base branch requires (rulesets and classic protection both) passed, with no other check
//   failing or still running.
//
// Whatever cannot be read or verified is refused (L42, L98): GitHub not answering, an answer of the
// wrong shape, a list GitHub cut short, and a base branch that requires no check at all.
// --match-head-commit makes GitHub itself refuse the merge if the head moves after these reads.
//
// Pure: GitHub is asked through `api`, which register.ts runs as `gh api <endpoint>`.

/** One GitHub REST read: its parsed JSON, or why it could not be had. */
export type GhJson = (endpoint: string) => Promise<{ json: unknown } | { why: string }>

/** The repository a github.com link names, as owner/name, or null: mod-kit's link reader, $.modkit.linkRepo. */
export type LinkRepo = (link: string) => Promise<string | null>

/** What running a program answered, as register.ts's `run` gives it. */
export type Ran = { exitCode: number; stdout: string; stderr: string; isStdoutTruncated: boolean }

/** GitHub read as `gh api <endpoint>`, through `run`; a failure, a cut answer or one not JSON is why. */
export const ghApiOf = (run: (argv: string[]) => Promise<Ran>): GhJson => async endpoint => {
  const r = await run(['gh', 'api', endpoint])
  if (r.exitCode !== 0) return { why: r.stderr.trim().split('\n').pop() || `gh api exited ${r.exitCode}` }
  if (r.isStdoutTruncated) return { why: 'its answer was cut short' }
  try {
    return { json: JSON.parse(r.stdout) as unknown }
  } catch {
    return { why: 'its answer was not JSON' }
  }
}

const SHA = /^[0-9a-f]{40}$/i
const NUMBER = /^[1-9]\d{0,9}$/
// A PR link: the number is read here, the repository it names only by mod-kit's link reader
// (#961), handed in to judgeAdminMerge as `linkRepo`.
const LINKED = 'https://github.com/'
const PULL = /\/pull\/([1-9]\d{0,9})\/?$/
// The flags an admin merge may carry: the merge itself, its pin, its message, and the repository.
const ALLOWED = new Set(['--admin', '-s', '--squash', '--match-head-commit', '-t', '--subject', '-b', '--body', '-F', '--body-file', '-R', '--repo'])
// A check that did not fail: green for a check nothing requires. A required one must be a success.
const NOT_FAILED = new Set(['success', 'neutral', 'skipped'])

type Pinned = { pr: number; sha: string; link?: string }

const pinned = (g: ModKitGh): Pinned | { refuse: string } => {
  const other = g.flags.find(f => !ALLOWED.has(f.name))
  if (other) return { refuse: `admin merge a PR with ${other.name}` }
  const pins = g.flags.filter(f => f.name === '--match-head-commit')
  if (pins.length > 1) return { refuse: 'admin merge a PR pinned to more than one head commit' }
  const sha = pins[0]?.value
  if (typeof sha !== 'string' || !SHA.test(sha)) return { refuse: 'admin merge a PR without --match-head-commit naming its full head commit' }
  if (!g.flags.some(f => f.name === '-s' || f.name === '--squash')) return { refuse: 'admin merge a PR other than as a squash' }
  const only = g.positionals.length === 1 ? (g.positionals[0] ?? '') : ''
  const pull = only.startsWith(LINKED) ? PULL.exec(only) : null
  if (pull) return { pr: Number(pull[1]), sha: sha.toLowerCase(), link: only }
  if (NUMBER.test(only)) return { pr: Number(only), sha: sha.toLowerCase() }
  return { refuse: 'admin merge a PR it does not name by number' }
}

/** The PR and head commit an admin merge pins, or why its shape is refused before GitHub is asked. */
export const pinnedOf = (g: ModKitGh): { pr: number; sha: string } | { refuse: string } => {
  const p = pinned(g)
  return 'refuse' in p ? p : { pr: p.pr, sha: p.sha }
}

/** What GitHub is asked, in order: the PR, its base branch's rules and protection, the commit's checks and statuses. */
export const adminEndpoints = (repo: string, pr: number, sha: string, base: string): string[] => {
  const b = encodeURIComponent(base)
  return [
    `repos/${repo}/pulls/${pr}`,
    `repos/${repo}/rules/branches/${b}?per_page=100`,
    `repos/${repo}/branches/${b}`,
    `repos/${repo}/commits/${sha}/check-runs?per_page=100`,
    `repos/${repo}/commits/${sha}/status?per_page=100`,
  ]
}

const record = (v: unknown): Record<string, unknown> | null => (v !== null && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null)
const strings = (v: unknown): string[] | null => (Array.isArray(v) && v.every(s => typeof s === 'string') ? (v as string[]) : null)

// The contexts a ruleset requires, or null when the answer cannot be read in full.
const rulesetChecks = (json: unknown): string[] | null => {
  if (!Array.isArray(json) || json.length >= 100) return null
  const out: string[] = []
  for (const rule of json) {
    const r = record(rule)
    if (!r || typeof r.type !== 'string') return null
    if (r.type !== 'required_status_checks') continue
    const list = record(r.parameters)?.required_status_checks
    if (!Array.isArray(list)) return null
    for (const c of list) {
      const context = record(c)?.context
      if (typeof context !== 'string') return null
      out.push(context)
    }
  }
  return out
}

// The contexts classic branch protection requires, or null when it cannot be read.
const protectionChecks = (json: unknown): string[] | null => {
  const b = record(json)
  if (!b || typeof b.protected !== 'boolean') return null
  if (!b.protected) return []
  const p = record(b.protection)
  if (!p) return null
  if (p.enabled === false || p.required_status_checks === undefined) return []
  const rsc = record(p.required_status_checks)
  if (!rsc) return null
  const contexts = rsc.contexts === undefined ? [] : strings(rsc.contexts)
  if (!contexts) return null
  const out = [...contexts]
  if (rsc.checks !== undefined) {
    if (!Array.isArray(rsc.checks)) return null
    for (const c of rsc.checks) {
      const context = record(c)?.context
      if (typeof context !== 'string') return null
      out.push(context)
    }
  }
  return out
}

// One report on the commit: its name, and the state it is in, 'success' when it passed.
type Report = { name: string; state: string }

const runReports = (json: unknown): Report[] | { short: true } | null => {
  const o = record(json)
  if (!o || typeof o.total_count !== 'number' || !Array.isArray(o.check_runs)) return null
  const out: Report[] = []
  for (const run of o.check_runs) {
    const r = record(run)
    if (!r || typeof r.name !== 'string' || typeof r.status !== 'string') return null
    if (r.status !== 'completed') out.push({ name: r.name, state: r.status })
    else if (typeof r.conclusion === 'string') out.push({ name: r.name, state: r.conclusion })
    else return null
  }
  return o.total_count > out.length ? { short: true } : out
}

const statusReports = (json: unknown): Report[] | { short: true } | null => {
  const o = record(json)
  if (!o || typeof o.total_count !== 'number' || !Array.isArray(o.statuses)) return null
  const out: Report[] = []
  for (const s of o.statuses) {
    const r = record(s)
    if (!r || typeof r.context !== 'string' || typeof r.state !== 'string') return null
    out.push({ name: r.context, state: r.state })
  }
  return o.total_count > out.length ? { short: true } : out
}

/**
 * Why an admin merge is refused tonight in `repo` (the repository the overnight write rule resolved
 * it to), or undefined when it may run. `night` is the sleep record's lists, as settled at bedtime.
 */
export const judgeAdminMerge = async (night: unknown, g: ModKitGh, repo: string, api: GhJson, linkRepo: LinkRepo): Promise<string | undefined> => {
  const policy = policyOf(night, repo)
  const what = `admin merge a PR in ${repo}`
  if (policy.kind === 'closed') return `${what}, and ${policy.why}, so tonight it neither merges nor deploys`
  const off = `${what}, which does not allow admin merges overnight (adminMerge on its mergeOnly entry in mods/sleep-repos.local.json)`
  if (policy.kind !== 'merge-only') return off
  if (policy.mergeDeploys === true) return `${what}, where a merge deploys, so it is never merged overnight`
  if (policy.mergeDeploys !== false) return `${what}, where whether a merge deploys is not recorded, so it is never merged overnight`
  if (policy.adminMerge !== ADMIN_MERGE) return off

  const p = pinned(g)
  if ('refuse' in p) return p.refuse
  // A link names its own repository, which must be the one judged (the write rule reads it too),
  // and must be exactly that repository's link to the PR, nothing more under it.
  if (p.link !== undefined) {
    const linked = await linkRepo(p.link).catch(() => null)
    const exact = linked !== null && [`${LINKED}${linked}/pull/${p.pr}`, `${LINKED}${linked}/pull/${p.pr}/`].includes(p.link)
    if (!exact) return 'admin merge a PR it does not name by number'
    if (linked.toLowerCase() !== repo.toLowerCase()) return `admin merge PR #${p.pr} through a link to ${linked} from a checkout of ${repo}`
  }

  const pr = `admin merge PR #${p.pr} in ${repo}`
  const ask = async (endpoint: string): Promise<{ json: unknown } | { refuse: string }> => {
    const a = await api(endpoint)
    return 'why' in a ? { refuse: `${pr}, which GitHub could not be asked about (${a.why})` } : a
  }

  const head = await ask(`repos/${repo}/pulls/${p.pr}`)
  if ('refuse' in head) return head.refuse
  const o = record(head.json)
  const sha = record(o?.head)?.sha
  const base = record(o?.base)?.ref
  if (!o || typeof o.state !== 'string' || typeof sha !== 'string' || typeof base !== 'string' || !base) return `${pr}, whose answer from GitHub could not be read`
  if (o.state !== 'open' || o.merged === true) return `${pr}, which is not open`
  if (o.draft === true) return `${pr}, which is a draft`
  if (sha.toLowerCase() !== p.sha) return `${pr}, whose head is now ${sha.toLowerCase().slice(0, 12)}, not the pinned ${p.sha.slice(0, 12)}`

  const [, rulesAt, branchAt, runsAt, statusAt] = adminEndpoints(repo, p.pr, p.sha, base) as [string, string, string, string, string]
  const rules = await ask(rulesAt)
  if ('refuse' in rules) return rules.refuse
  const fromRules = rulesetChecks(rules.json)
  if (!fromRules) return `${pr}, whose base branch ${base}'s rules could not be read`
  const branch = await ask(branchAt)
  if ('refuse' in branch) return branch.refuse
  const fromProtection = protectionChecks(branch.json)
  if (!fromProtection) return `${pr}, whose base branch ${base}'s protection could not be read`
  const required = [...new Set([...fromRules, ...fromProtection])]
  if (!required.length) return `${pr}, whose base branch ${base} requires no check, so there is nothing to hold an admin merge to`

  const runs = await ask(runsAt)
  if ('refuse' in runs) return runs.refuse
  const statuses = await ask(statusAt)
  if ('refuse' in statuses) return statuses.refuse
  const r = runReports(runs.json)
  const s = statusReports(statuses.json)
  if (!r || !s) return `${pr}, whose head commit's checks could not be read`
  if ('short' in r || 'short' in s) return `${pr}, whose head commit's checks GitHub did not list in full`
  const reports = [...r, ...s]

  for (const name of required) {
    const mine = reports.filter(x => x.name === name)
    if (!mine.length) return `${pr}, whose required check ${name} has not reported on its head commit`
    const bad = mine.find(x => x.state !== 'success')
    if (bad) return `${pr}, whose required check ${name} is ${bad.state} on its head commit`
  }
  const other = reports.find(x => !required.includes(x.name) && !NOT_FAILED.has(x.state))
  if (other) return `${pr}, whose check ${other.name} is ${other.state} on its head commit`
  return undefined
}
