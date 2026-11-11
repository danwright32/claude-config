import { repoFromRemotes, type GithubOf } from './overnight.ts'
import { etWhen } from './sleep.ts'
import { errorText } from './mod-kit/skew.ts'

// Sleep mode phase 3 (#834): the wake check. The overnight rules (overnight.ts) judge the words of a
// call, and a text match always has a way around it, so at wake the real state since sleep began is
// read: issues created, milestones touched, LESSONS.md changed (on GitHub and the installed copy),
// and deploy runs. Every hit goes at the top of the night's report; a read that fails is said as not
// checked, never as nothing found (L460, L11).
//
// Which repositories: every one the gh login had an event in since sleep began (read page by page,
// as far back as GitHub keeps them, its newest 300, and any window before that said, #1160), every
// one an issue was created in, and the config repository (the live sync clone's). A milestone made in a
// repository with no other event that night is not seen; the events API carries none for it.
// GitHub is read as the account gh is logged in as, so another account's work is not read.

export type Ran = { exitCode: number; stdout: string; stderr: string }
/** Runs a command; `timeoutMs` is the most it may take, when the caller bounds it. */
export type Runner = (argv: string[], timeoutMs?: number) => Promise<Ran>
/** The whole check's deadline, and the most one GitHub read may take. */
export const WAKE_CHECK_MS = 30_000
const READ_MS = 20_000
/** GitHub keeps a user's newest 300 events: three pages of 100 (page 4 answers HTTP 422). */
const EVENTS_PER_PAGE = 100
const EVENT_PAGES = 3
/**
 * `checked` is one line saying how many repositories were read and what was left out as healthy
 * (#2766): it is written every time the check runs, so a quiet night reads differently from a check
 * that never ran or stopped looking (Dan's alert rule: silence must still mean healthy).
 */
export type WakeFindings = { hits: string[]; unmeasured: string[]; checked: string }
/** How a finished run ended, in the words the report uses; every conclusion but these is said as GitHub names it. */
const ENDED: Record<string, string> = { success: 'passed', failure: 'failed', cancelled: 'cancelled', timed_out: 'timed out', skipped: 'skipped' }
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`
/** The time now in ms: the engine's clock (`$.clock.now`), never Date.now, which no test can move. */
export type Clock = () => number | Promise<number>

const SLUG = /^[\w.-]+\/[\w.-]+$/
// The note kinds that say a session worked an issue or pull request tonight, in the schema
// sleep-report.py documents: a claim, its release, done, parked and failed. A question names an
// issue Dan was asked about, which no session changed, so it explains nothing (#2393).
const WORKED = new Set(['claim', 'released', 'done', 'parked', 'failed'])
/**
 * The issues and pull requests one line of the night's notes says a session worked, each as
 * owner/name#n lowercased: the same record the sleep report checks against GitHub at wake (#2393).
 */
export const workedOn = (note: unknown): string[] => {
  if (!note || typeof note !== 'object') return []
  const n = note as { kind?: unknown; repo?: unknown; issue?: unknown; pr?: unknown }
  if (typeof n.kind !== 'string' || !WORKED.has(n.kind) || typeof n.repo !== 'string' || !SLUG.test(n.repo)) return []
  const repo = n.repo.toLowerCase()
  return [n.issue, n.pr].filter((x): x is number => Number.isInteger(x)).map(x => `${repo}#${x}`)
}
/** GitHub's issue events for a repository: three pages of 100, newest first, as far back as read. */
const ISSUE_EVENT_PAGES = 3
/**
 * How long after the newest issue event a milestone's updated_at may still be that event's own
 * change: measured 2026-11-07, an issue added at 14:31:51 moved its milestone to 14:31:52. A later
 * time is a change to the milestone itself, which no issue event records.
 */
const SAME_CHANGE_MS = 60_000
/** What each issue event that moves a milestone did, as the report says it. */
const MOVES: Record<string, string> = { closed: 'closed', reopened: 'reopened', milestoned: 'added to it', demilestoned: 'removed from it' }

const iso = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z')
const firstLine = (s: string) => s.trim().split('\n')[0]?.trim() ?? ''
const at = (s: unknown) => (typeof s === 'string' ? Date.parse(s) : Number.NaN)

/**
 * What GitHub and the disk say happened since `since` (ms), read through `run`. `repos` are the
 * repositories the night's notes name, each read whatever the events feed shows (#834 review: a
 * private repository the feed leaves out is still read). `github` reads a remote's address, the
 * live sync clone's among them, as mod-kit's one reader does (#951). `mtimeOf` dates a file (ms),
 * rejecting with the reason when it cannot (#2016). `worked` are the issues and pull requests the
 * night's notes say its sessions worked (workedOn), which explain a milestone they moved (#2393).
 */
export const wakeCheck = async (
  runAny: Runner,
  o: { since: number; home: string; github: GithubOf; repos?: string[]; worked?: string[]; now: Clock; budgetMs?: number; mtimeOf: (path: string) => Promise<number> },
): Promise<WakeFindings> => {
  const hits: string[] = []
  const unmeasured: string[] = []
  // GitHub's reads together keep to one deadline (L110): wake and its reply wait on them, and then
  // on the report's own final render, which has its own 90 s, so this check takes 30 s at most.
  // Each read is given only the time left (never more than 20 s), a read past the deadline is not
  // made, and that is said once; the local reads (git, the file stat) always run.
  // Timed on the clock the caller passes, the engine's in the hooks, so a test that moves the
  // engine's clock moves this deadline and never waits for real (#1147, L524).
  const { now } = o
  const budget = o.budgetMs ?? WAKE_CHECK_MS
  const started = await now()
  let over = false
  const SKIPPED = -2
  const run = async (argv: string[]): Promise<Ran> => {
    if (argv[0] !== 'gh') return runAny(argv)
    const left = budget - ((await now()) - started)
    if (left <= 0) {
      if (!over) unmeasured.push(`the overnight check stopped at its ${Math.round(budget / 1000)} s limit, so the rest of GitHub was not read`)
      over = true
      return { exitCode: SKIPPED, stdout: '', stderr: '' }
    }
    return runAny(argv, Math.min(READ_MS, left))
  }
  const since = iso(o.since)
  // A time GitHub did not give, or gave unreadable, is unknown: said as not checked, never compared
  // away as before sleep nor counted as overnight (L50).
  const when = (s: unknown): 'overnight' | 'before' | 'unknown' => {
    const t = at(s)
    return Number.isNaN(t) ? 'unknown' : t >= o.since ? 'overnight' : 'before'
  }
  const NO_TIME = 'is unknown (GitHub gave no time)'
  // One read, its JSON parsed; a failure is said under `what`, and the answer is null.
  const json = async <T>(argv: string[], what: string): Promise<T | null> => {
    const r = await run(argv)
    if (r.exitCode === SKIPPED) return null
    const tool = `${argv[0]} ${argv[1]}${argv[0] === 'gh' && argv[1] === 'search' ? ` ${argv[2]}` : argv[0] === 'gh' && argv[1] === 'run' ? ` ${argv[2]}` : ''}`
    if (r.exitCode !== 0) {
      unmeasured.push(`${what} were not checked (${tool}: ${firstLine(r.stderr) || `exit ${r.exitCode}`})`)
      return null
    }
    try {
      return JSON.parse(r.stdout) as T
    } catch {
      unmeasured.push(`${what} were not checked (${tool}: the answer was not JSON)`)
      return null
    }
  }

  const repos: string[] = []
  const addRepo = (r: string | undefined) => {
    if (r && !repos.includes(r.toLowerCase())) repos.push(r.toLowerCase())
  }
  for (const r of o.repos ?? []) addRepo(r)
  const issueKeys = new Set<string>()
  const issue = (repo: string, n: number, title: string) => {
    const key = `${repo.toLowerCase()}#${n}`
    if (issueKeys.has(key)) return
    issueKeys.add(key)
    hits.push(`Issue created overnight: ${key} "${title}"`)
  }

  const login = await run(['gh', 'api', 'user', '--jq', '.login'])
  const me = login.exitCode === 0 ? login.stdout.trim() : ''
  if (!me) unmeasured.push(`GitHub was not checked at all: the gh login could not be read (${firstLine(login.stderr) || 'no login printed'})`)
  else {
    type Ev = { type?: string; created_at?: string; repo?: { name?: string }; payload?: { action?: string; issue?: { number?: number; title?: string } } }
    // Page by page back to the moment sleep began (#1160): one page of 100 left a busy night's
    // earlier repositories unread. GitHub keeps a user's newest 300 events, so page 4 is never asked
    // for (it answers HTTP 422, measured 2026-10-13); each page goes through `run`, so the pages
    // keep to the check's one deadline. A window not read is said by its two ends: sleep's start
    // and the oldest event read, never as a count.
    const events: Ev[] = []
    let oldest: number | null = null
    const unread = (why: string) => {
      const span = oldest === null ? `since ${etWhen(o.since)}` : `from ${etWhen(o.since)} to ${etWhen(oldest)}`
      unmeasured.push(`the GitHub events ${span} were not read for the repositories to check (${why})`)
    }
    for (let p = 1; p <= EVENT_PAGES; p++) {
      const r = await run(['gh', 'api', `users/${me}/events?per_page=${EVENTS_PER_PAGE}&page=${p}`])
      if (r.exitCode === SKIPPED) {
        unread(`page ${p}: the check stopped at its ${Math.round(budget / 1000)} s limit`)
        break
      }
      if (r.exitCode !== 0) {
        unread(`page ${p}: ${firstLine(r.stderr) || `exit ${r.exitCode}`}`)
        break
      }
      let page: Ev[] | null = null
      try {
        const got: unknown = JSON.parse(r.stdout)
        if (Array.isArray(got)) page = got as Ev[]
      } catch {
        // said just below, as for an answer that is JSON but not a list
      }
      if (!page) {
        unread(`page ${p}: the answer was not JSON`)
        break
      }
      events.push(...page)
      for (const e of page) {
        const t = at(e.created_at)
        if (!Number.isNaN(t) && (oldest === null || t < oldest)) oldest = t
      }
      // A page that is not full is the last there is; one reaching back past sleep's start is the last needed.
      if (page.length < EVENTS_PER_PAGE || page.some(e => when(e.created_at) === 'before')) break
      if (p === EVENT_PAGES) unread(`GitHub gives only the newest ${EVENT_PAGES * EVENTS_PER_PAGE} of a user's events`)
    }
    // An event of unknown time still names a repository to read: reading one more costs nothing.
    const recent = events.filter(e => when(e.created_at) !== 'before')
    for (const e of recent) {
      addRepo(e.repo?.name)
      const i = e.payload?.issue
      if (e.type !== 'IssuesEvent' || e.payload?.action !== 'opened' || !e.repo?.name || typeof i?.number !== 'number') continue
      if (when(e.created_at) === 'unknown') unmeasured.push(`when issue ${e.repo.name.toLowerCase()}#${i.number} was opened ${NO_TIME}`)
      else issue(e.repo.name, i.number, i.title ?? '')
    }
    // The search index can lag, and the events can too, so both are read (L1014).
    type Found = { repository?: { nameWithOwner?: string }; number?: number; title?: string }
    const found = await json<Found[]>(['gh', 'search', 'issues', '--author', '@me', '--created', `>=${since}`, '--json', 'repository,number,title,url', '--limit', '100'], 'issues created overnight')
    for (const f of found ?? []) {
      const repo = f.repository?.nameWithOwner
      if (!repo || typeof f.number !== 'number') continue
      addRepo(repo)
      issue(repo, f.number, f.title ?? '')
    }
  }

  // LESSONS.md, on GitHub through the live sync clone's repository, and the installed copy.
  const remotes = await run(['git', '-C', `${o.home}/claude-config-sync`, 'remote', '-v'])
  let config: string | null = null
  let unread = firstLine(remotes.stderr)
  if (remotes.exitCode === 0) {
    try {
      config = await repoFromRemotes(remotes.stdout, o.github)
    } catch (err) {
      unread = `its remotes could not be read: ${firstLine(errorText(err, 'scope-modes'))}`
    }
  }
  const lessonHits: string[] = []
  if (!config) unmeasured.push(`LESSONS.md on GitHub was not checked: the config repository could not be read from ~/claude-config-sync (${unread || 'no one GitHub remote'})`)
  else {
    addRepo(config)
    if (me) {
      type Commit = { sha?: string; commit?: { message?: string } }
      const commits = await json<Commit[]>(['gh', 'api', `repos/${config}/commits?path=payload/LESSONS.md&since=${since}`], 'LESSONS.md changes on GitHub')
      for (const c of commits ?? []) lessonHits.push(`LESSONS.md changed overnight on GitHub: ${(c.sha ?? '').slice(0, 7)} "${firstLine(c.commit?.message ?? '')}"`)
    }
  }
  // Dated by the caller's file stat, $.fs.stat in the hooks (#2016), never a stat process: BSD's
  // stat -f, which this ran, is file system status to GNU stat on Linux and printed no time there.
  let mtime = Number.NaN
  let unreadMtime = 'no time was given'
  try {
    mtime = await o.mtimeOf(`${o.home}/.claude/LESSONS.md`)
  } catch (err) {
    unreadMtime = firstLine(errorText(err, 'scope-modes')) || 'the read failed'
  }
  if (!Number.isFinite(mtime) || mtime <= 0) unmeasured.push(`the installed LESSONS.md was not checked (its last change could not be read: ${unreadMtime})`)
  else if (mtime >= o.since) lessonHits.push(`The installed LESSONS.md changed overnight, at ${etWhen(mtime)}`)

  // #2393: updated_at says only that a milestone changed, so the night's own merges and filings
  // were put to Dan every morning. The repository's issue events for the night say what changed;
  // one the night's notes account for (an issue or pull request a session worked, or an issue
  // created overnight, already its own line above) is left out, and only the rest is reported, by
  // name. A change no issue event records is the milestone itself. What cannot be read is said as
  // not checked, never as explained (L460).
  const worked = new Set((o.worked ?? []).map(k => k.toLowerCase()))
  // #2766: a change made from one of Dan's own accounts (other sessions of his, filing and closing
  // issues) is counted and left out; one by anybody else is still listed. His accounts are every one
  // gh is logged in to on this Mac, read once and only when a change would otherwise be listed; when
  // that cannot be read only the gh login is his, so more is listed, never less.
  const ownAccounts = new Set(me ? [me.toLowerCase()] : [])
  let accountsRead = false
  const own = async (login: string | undefined): Promise<boolean> => {
    if (!login) return false
    if (!ownAccounts.has(login.toLowerCase()) && !accountsRead) {
      accountsRead = true
      const r = await run(['gh', 'auth', 'status', '--json', 'hosts'])
      try {
        const hosts = r.exitCode === 0 ? (JSON.parse(r.stdout) as { hosts?: Record<string, { login?: unknown }[]> }).hosts : undefined
        for (const a of hosts?.['github.com'] ?? []) if (typeof a?.login === 'string') ownAccounts.add(a.login.toLowerCase())
      } catch {
        // Not JSON: only the gh login is his, as when the read fails.
      }
    }
    return ownAccounts.has(login.toLowerCase())
  }
  let ownChanges = 0
  const milestonesExplained = async (repo: string, touched: { number?: number; title?: string; updated_at?: string }[]) => {
    type IssueEv = {
      event?: string
      created_at?: string
      actor?: { login?: string } | null
      milestone?: { title?: string } | null
      issue?: { number?: number; milestone?: { number?: number; title?: string } | null } | null
    }
    // Newest first, page by page back to sleep's start, as the user's events are read above.
    const events: IssueEv[] = []
    let oldest: number | null = null
    let gap: string | null = null
    for (let p = 1; p <= ISSUE_EVENT_PAGES; p++) {
      const r = await run(['gh', 'api', `repos/${repo}/issues/events?per_page=${EVENTS_PER_PAGE}&page=${p}`])
      if (r.exitCode === SKIPPED) {
        gap = `page ${p}: the check stopped at its ${Math.round(budget / 1000)} s limit`
        break
      }
      if (r.exitCode !== 0) {
        gap = `page ${p}: ${firstLine(r.stderr) || `exit ${r.exitCode}`}`
        break
      }
      let page: IssueEv[] | null = null
      try {
        const got: unknown = JSON.parse(r.stdout)
        if (Array.isArray(got)) page = got as IssueEv[]
      } catch {
        // said just below, as for an answer that is JSON but not a list
      }
      if (!page) {
        gap = `page ${p}: the answer was not JSON`
        break
      }
      events.push(...page)
      for (const e of page) {
        const t = at(e.created_at)
        if (!Number.isNaN(t) && (oldest === null || t < oldest)) oldest = t
      }
      if (page.length < EVENTS_PER_PAGE || page.some(e => when(e.created_at) === 'before')) break
      if (p === ISSUE_EVENT_PAGES) gap = `GitHub was asked for only the newest ${ISSUE_EVENT_PAGES * EVENTS_PER_PAGE}`
    }
    const gapText = gap === null ? '' : oldest === null ? `its issue events could not be read: ${gap}` : `its issue events from ${etWhen(o.since)} to ${etWhen(oldest)} were not read: ${gap}`
    // The pull requests that closed the night's closed issues, read once, only when a close is not
    // already accounted for: a session's notes may name its pull request and not the issue it closes.
    type Closers = { map: Map<number, string[]>; full: boolean; why: string | null }
    let closers: Closers | null = null
    const closersOf = async (): Promise<Closers> => {
      if (closers) return closers
      const r = await run(['gh', 'issue', 'list', '-R', repo, '--state', 'closed', '--search', `closed:>=${since}`, '--json', 'number,closedByPullRequestsReferences', '--limit', '100'])
      const failed = (why: string): Closers => (closers = { map: new Map(), full: false, why })
      if (r.exitCode === SKIPPED) return failed(`the check stopped at its ${Math.round(budget / 1000)} s limit`)
      if (r.exitCode !== 0) return failed(firstLine(r.stderr) || `exit ${r.exitCode}`)
      let list: unknown
      try {
        list = JSON.parse(r.stdout)
      } catch {
        return failed('the answer was not JSON')
      }
      if (!Array.isArray(list)) return failed('the answer was not JSON')
      type Ref = { number?: unknown; repository?: { nameWithOwner?: unknown; name?: unknown; owner?: { login?: unknown } | null } | null }
      // A reference naming no repository is in this one; one whose repository cannot be read ties nothing.
      const key = (x: Ref): string | null => {
        if (!Number.isInteger(x?.number)) return null
        const rp = x.repository
        if (rp == null) return `${repo}#${x.number}`
        const slug = typeof rp.nameWithOwner === 'string' ? rp.nameWithOwner : typeof rp.owner?.login === 'string' && typeof rp.name === 'string' ? `${rp.owner.login}/${rp.name}` : ''
        return SLUG.test(slug) ? `${slug.toLowerCase()}#${x.number}` : null
      }
      const map = new Map<number, string[]>()
      for (const i of list as { number?: unknown; closedByPullRequestsReferences?: unknown }[]) {
        if (!Number.isInteger(i?.number)) continue
        const refs = Array.isArray(i.closedByPullRequestsReferences) ? (i.closedByPullRequestsReferences as Ref[]) : []
        map.set(i.number as number, refs.map(key).filter((k): k is string => k !== null))
      }
      return (closers = { map, full: list.length >= 100, why: null })
    }
    for (const m of touched) {
      const title = m.title ?? ''
      const mine = (e: IssueEv) => {
        if (e.event === 'milestoned' || e.event === 'demilestoned') return typeof m.title === 'string' && e.milestone?.title === m.title
        if (e.event !== 'closed' && e.event !== 'reopened') return false
        const im = e.issue?.milestone
        if (!im) return false
        return typeof im.number === 'number' && typeof m.number === 'number' ? im.number === m.number : typeof m.title === 'string' && im.title === m.title
      }
      const unexplained: string[] = []
      const undecided: string[] = []
      let latest = Number.NEGATIVE_INFINITY
      // Oldest first, so the changes read in the order they happened.
      for (const e of events.filter(mine).filter(e => when(e.created_at) !== 'before').reverse()) {
        const t = at(e.created_at)
        if (!Number.isNaN(t)) latest = Math.max(latest, t)
        const n = e.issue?.number
        const what = `#${typeof n === 'number' ? n : '?'} ${MOVES[e.event ?? ''] ?? e.event}`
        if (typeof n === 'number' && (worked.has(`${repo}#${n}`) || issueKeys.has(`${repo}#${n}`))) continue
        if (!Number.isNaN(t) && (await own(e.actor?.login ?? undefined))) {
          ownChanges++
          continue
        }
        if (e.event === 'closed' && typeof n === 'number') {
          const c = await closersOf()
          if (c.why !== null) {
            undecided.push(`the pull requests that closed its issues could not be read: ${c.why}`)
            continue
          }
          if (c.map.get(n)?.some(k => worked.has(k))) continue
          if (!c.map.has(n) && c.full) {
            undecided.push(`GitHub returned the most closed issues asked for (100), so what closed #${n} was not read`)
            continue
          }
        }
        if (Number.isNaN(t)) {
          undecided.push(`GitHub gave no time for ${what}`)
          continue
        }
        unexplained.push(`${what} by ${e.actor?.login || 'someone GitHub did not name'}`)
      }
      // The milestone's own last change, later than any issue event in it, is the milestone itself;
      // one inside a window not read cannot be told apart, and the gap says so.
      const moved = at(m.updated_at)
      if ((gap === null || (oldest !== null && moved >= oldest)) && moved > latest + SAME_CHANGE_MS)
        unexplained.push(`the milestone itself, at ${etWhen(moved)} (no issue event in it explains that)`)
      // Every reason something was not read is said, and a named change never hides one: else the
      // report names one change and reads as though the milestone was read whole (lessons review).
      const whyNot = [...new Set(undecided), ...(gap === null ? [] : [gapText])]
      if (unexplained.length) hits.push(`Milestone touched overnight: ${repo} "${title}", by changes nothing the night recorded accounts for: ${unexplained.join('; ')}`)
      if (whyNot.length)
        unmeasured.push(
          unexplained.length
            ? `other changes to milestone "${title}" in ${repo} were not checked (${whyNot.join('; ')})`
            : `whether milestone "${title}" in ${repo} was changed only by the night's own work was not checked (${whyNot.join('; ')})`,
        )
    }
  }

  // Milestones touched and deploy runs, in each repository.
  const deployHits: string[] = []
  // What the runs left out as healthy (#2766), said in the one line the check always writes.
  const left = { passed: 0, skipped: 0, running: 0, deploys: 0 }
  if (me) {
    for (const repo of repos) {
      type Ms = { number?: number; title?: string; updated_at?: string; created_at?: string }
      const ms = await json<Ms[]>(['gh', 'api', `repos/${repo}/milestones?state=all&per_page=100`], `milestones in ${repo}`)
      // One page, sorted by due date: a full one may leave out the milestone touched (L24).
      if (ms && ms.length >= 100) unmeasured.push(`${repo} holds 100 or more milestones, so only the first 100 were read`)
      const touched: Ms[] = []
      for (const m of ms ?? []) {
        // GitHub moves updated_at on every change, creation included, so it says that one happened.
        const w = when(m.updated_at)
        if (w === 'overnight') touched.push(m)
        else if (w === 'unknown') unmeasured.push(`when milestone "${m.title ?? ''}" in ${repo} was last touched ${NO_TIME}`)
      }
      if (touched.length) await milestonesExplained(repo, touched)
    }
    for (const repo of repos) {
      // #2766: read through the REST API, which says who started each run and how it ended, created
      // since sleep began. A run started by a schedule, or dispatched by a cron (a bot started it),
      // that passed, was skipped or is still running needs nobody, so it is counted, never listed;
      // one that failed, was cancelled or timed out is listed. A deploy that passed for a merge the
      // night's notes account for is counted too; every other deploy or dispatch is listed, as before.
      type Actor = { login?: string; type?: string } | null
      type RunRow = { name?: string; event?: string; status?: string; conclusion?: string | null; created_at?: string; html_url?: string; head_sha?: string; triggering_actor?: Actor; actor?: Actor }
      const page = await json<{ total_count?: number; workflow_runs?: RunRow[] }>(['gh', 'api', `repos/${repo}/actions/runs?per_page=100&created=>=${since}`], `deploy runs in ${repo}`)
      const runs = Array.isArray(page?.workflow_runs) ? page.workflow_runs : page ? null : []
      if (runs === null) {
        unmeasured.push(`deploy runs in ${repo} were not checked (gh api: the answer held no list of runs)`)
        continue
      }
      // Newest first: more runs since sleep than were read leaves the oldest out (L24), and what is
      // left out is said by its two ends, as the events are (#1160).
      const total = typeof page?.total_count === 'number' ? page.total_count : runs.length
      if (total > runs.length) {
        const times = runs.map(r => at(r.created_at)).filter(t => !Number.isNaN(t))
        const span = times.length ? `from ${etWhen(o.since)} to ${etWhen(Math.min(...times))}` : `since ${etWhen(o.since)}`
        unmeasured.push(`the runs in ${repo} ${span} were not read for deploys (only the newest ${runs.length} of ${total} were asked for)`)
      }
      for (const r of runs) {
        const name = r.name ?? ''
        const starter = r.triggering_actor ?? r.actor
        const cron = r.event === 'schedule' || ((r.event === 'workflow_dispatch' || r.event === 'repository_dispatch') && (starter?.type === 'Bot' || /\[bot\]$/i.test(starter?.login ?? '')))
        if (!/deploy|release|publish/i.test(name) && r.event !== 'workflow_dispatch' && !cron) continue
        const w = when(r.created_at)
        if (w === 'unknown') {
          unmeasured.push(`when the ${name} run in ${repo} ran ${NO_TIME}`)
          continue
        }
        if (w !== 'overnight') continue
        const done = r.status === undefined || r.status === 'completed'
        const conclusion = typeof r.conclusion === 'string' ? r.conclusion : ''
        if (cron) {
          if (!done) left.running++
          else if (conclusion === 'success') left.passed++
          else if (conclusion === 'skipped') left.skipped++
          if (!done || conclusion === 'success' || conclusion === 'skipped') continue
        }
        const outcome = !done ? ', still running' : conclusion ? `, ${ENDED[conclusion] ?? conclusion.replace(/_/g, ' ')}` : ''
        let why = ''
        if (!cron && done && conclusion === 'success' && typeof r.head_sha === 'string' && /^[0-9a-f]{7,40}$/i.test(r.head_sha)) {
          // The pull requests whose merge commit started it: one the night's notes name accounts for it.
          const p = await run(['gh', 'api', `repos/${repo}/commits/${r.head_sha}/pulls`])
          let prs: unknown = null
          if (p.exitCode === 0)
            try {
              prs = JSON.parse(p.stdout)
            } catch {
              // said below, as a list that could not be read
            }
          if (Array.isArray(prs)) {
            if (prs.some(x => Number.isInteger(x?.number) && worked.has(`${repo}#${x.number}`))) {
              left.deploys++
              continue
            }
          } else if (p.exitCode !== SKIPPED) why = `; which merge started it could not be read (${p.exitCode !== 0 ? firstLine(p.stderr) || `exit ${p.exitCode}` : 'the answer was not JSON'})`
        }
        deployHits.push(`${cron ? 'Scheduled' : 'Deploy'} run overnight: ${repo} ${name}${outcome} (${r.html_url ?? ''})${why}`)
      }
    }
  }
  // One line, every time the check runs (#2766): what it read and what it left out as healthy.
  const counted = [
    left.passed ? `${plural(left.passed, 'scheduled run', 'scheduled runs')} passed` : '',
    left.skipped ? `${plural(left.skipped, 'scheduled run', 'scheduled runs')} skipped` : '',
    left.running ? `${plural(left.running, 'scheduled run', 'scheduled runs')} still running` : '',
    left.deploys ? `${plural(left.deploys, 'deploy run of a merge', 'deploy runs of merges')} the night accounts for passed` : '',
    ownChanges ? `${plural(ownChanges, 'milestone change', 'milestone changes')} made from your own accounts` : '',
  ].filter(Boolean)
  const read = me ? repos.length : 0
  const checked = `The overnight check read ${read ? plural(read, 'repository', 'repositories') : 'no repositories'} on GitHub${counted.length ? `; left out as healthy: ${counted.join(', ')}.` : ' and left nothing out.'}`
  return { hits: [...hits, ...lessonHits, ...deployHits], unmeasured, checked }
}
