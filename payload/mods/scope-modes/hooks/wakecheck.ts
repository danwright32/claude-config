import { repoFromRemotes } from './overnight.ts'
import { etWhen } from './sleep.ts'

// Sleep mode phase 3 (#834): the wake check. The overnight rules (overnight.ts) judge the words of a
// call, and a text match always has a way around it, so at wake the real state since sleep began is
// read: issues created, milestones touched, LESSONS.md changed (on GitHub and the installed copy),
// and deploy runs. Every hit goes at the top of the night's report; a read that fails is said as not
// checked, never as nothing found (L460, L11).
//
// Which repositories: every one the gh login had an event in since sleep began, every one an issue
// was created in, and the config repository (the live sync clone's). A milestone made in a
// repository with no other event that night is not seen; the events API carries none for it.
// GitHub is read as the account gh is logged in as, so another account's work is not read.

export type Ran = { exitCode: number; stdout: string; stderr: string }
/** Runs a command; `timeoutMs` is the most it may take, when the caller bounds it. */
export type Runner = (argv: string[], timeoutMs?: number) => Promise<Ran>
/** The whole check's deadline, and the most one GitHub read may take. */
export const WAKE_CHECK_MS = 30_000
const READ_MS = 20_000
export type WakeFindings = { hits: string[]; unmeasured: string[] }

const iso = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z')
const firstLine = (s: string) => s.trim().split('\n')[0]?.trim() ?? ''
const at = (s: unknown) => (typeof s === 'string' ? Date.parse(s) : Number.NaN)

/**
 * What GitHub and the disk say happened since `since` (ms), read through `run`. `repos` are the
 * repositories the night's notes name, each read whatever the events feed shows (#834 review: a
 * private repository the feed leaves out is still read).
 */
export const wakeCheck = async (
  runAny: Runner,
  o: { since: number; home: string; repos?: string[]; now?: () => number; budgetMs?: number },
): Promise<WakeFindings> => {
  const hits: string[] = []
  const unmeasured: string[] = []
  // GitHub's reads together keep to one deadline (L110): wake and its reply wait on them, and then
  // on the report's own final render, which has its own 90 s, so this check takes 30 s at most.
  // Each read is given only the time left (never more than 20 s), a read past the deadline is not
  // made, and that is said once; the local reads (git, stat) always run.
  const now = o.now ?? Date.now
  const budget = o.budgetMs ?? WAKE_CHECK_MS
  const started = now()
  let over = false
  const SKIPPED = -2
  const run = async (argv: string[]): Promise<Ran> => {
    if (argv[0] !== 'gh') return runAny(argv)
    const left = budget - (now() - started)
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
    const tool =`${argv[0]} ${argv[1]}${argv[0] === 'gh' && argv[1] === 'search' ? ` ${argv[2]}` : argv[0] === 'gh' && argv[1] === 'run' ? ` ${argv[2]}` : ''}`
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
    const events = await json<Ev[]>(['gh', 'api', `users/${me}/events?per_page=100`], 'the repositories worked overnight')
    if (events) {
      // An event of unknown time still names a repository to read: reading one more costs nothing.
      const recent = events.filter(e => when(e.created_at) !== 'before')
      if (events.length >= 100 && recent.length === events.length) unmeasured.push('more than 100 GitHub events since sleep began, so only the newest 100 were read for the repositories to check')
      for (const e of recent) {
        addRepo(e.repo?.name)
        const i = e.payload?.issue
        if (e.type !== 'IssuesEvent' || e.payload?.action !== 'opened' || !e.repo?.name || typeof i?.number !== 'number') continue
        if (when(e.created_at) === 'unknown') unmeasured.push(`when issue ${e.repo.name.toLowerCase()}#${i.number} was opened ${NO_TIME}`)
        else issue(e.repo.name, i.number, i.title ?? '')
      }
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
  const config = remotes.exitCode === 0 ? repoFromRemotes(remotes.stdout) : null
  const lessonHits: string[] = []
  if (!config) unmeasured.push(`LESSONS.md on GitHub was not checked: the config repository could not be read from ~/claude-config-sync (${firstLine(remotes.stderr) || 'no one GitHub remote'})`)
  else {
    addRepo(config)
    if (me) {
      type Commit = { sha?: string; commit?: { message?: string } }
      const commits = await json<Commit[]>(['gh', 'api', `repos/${config}/commits?path=payload/LESSONS.md&since=${since}`], 'LESSONS.md changes on GitHub')
      for (const c of commits ?? []) lessonHits.push(`LESSONS.md changed overnight on GitHub: ${(c.sha ?? '').slice(0, 7)} "${firstLine(c.commit?.message ?? '')}"`)
    }
  }
  const st = await run(['stat', '-f', '%m', `${o.home}/.claude/LESSONS.md`])
  const mtime = Number(st.stdout.trim()) * 1000
  if (st.exitCode !== 0 || !Number.isFinite(mtime) || mtime <= 0) unmeasured.push(`the installed LESSONS.md was not checked (stat: ${firstLine(st.stderr) || 'no time printed'})`)
  else if (mtime >= o.since) lessonHits.push(`The installed LESSONS.md changed overnight, at ${etWhen(mtime)}`)

  // Milestones touched and deploy runs, in each repository.
  const deployHits: string[] = []
  if (me) {
    for (const repo of repos) {
      type Ms = { title?: string; updated_at?: string; created_at?: string }
      const ms = await json<Ms[]>(['gh', 'api', `repos/${repo}/milestones?state=all&per_page=100`], `milestones in ${repo}`)
      // One page, sorted by due date: a full one may leave out the milestone touched (L24).
      if (ms && ms.length >= 100) unmeasured.push(`${repo} holds 100 or more milestones, so only the first 100 were read`)
      for (const m of ms ?? []) {
        // GitHub moves updated_at on every change, creation included, so it alone says.
        const w = when(m.updated_at)
        if (w === 'overnight') hits.push(`Milestone touched overnight: ${repo} "${m.title ?? ''}"`)
        else if (w === 'unknown') unmeasured.push(`when milestone "${m.title ?? ''}" in ${repo} was last touched ${NO_TIME}`)
      }
    }
    for (const repo of repos) {
      type RunRow = { workflowName?: string; event?: string; createdAt?: string; url?: string }
      const runs = await json<RunRow[]>(['gh', 'run', 'list', '-R', repo, '--json', 'workflowName,event,createdAt,url', '--limit', '100'], `deploy runs in ${repo}`)
      // Newest first: a full page whose oldest run is still overnight may leave runs out (L24).
      if (runs && runs.length >= 100 && when(runs[runs.length - 1]?.createdAt) !== 'before') unmeasured.push(`more than 100 runs in ${repo} since sleep began, so only the newest 100 were read`)
      for (const r of runs ?? []) {
        if (!/deploy|release|publish/i.test(r.workflowName ?? '') && r.event !== 'workflow_dispatch') continue
        const w = when(r.createdAt)
        if (w === 'overnight') deployHits.push(`Deploy run overnight: ${repo} ${r.workflowName ?? ''} (${r.url ?? ''})`)
        else if (w === 'unknown') unmeasured.push(`when the ${r.workflowName ?? ''} run in ${repo} ran ${NO_TIME}`)
      }
    }
  }
  return { hits: [...hits, ...lessonHits, ...deployHits], unmeasured }
}
