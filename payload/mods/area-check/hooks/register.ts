import type { EngineInterface, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { askAnyAccount, type GhRun } from './mod-kit/ghaccounts.ts'
import { errorText } from './mod-kit/skew.ts'
import {
  DEADLINE_MS,
  GROWTH_DAYS,
  ISSUE_LIMIT,
  ISSUES_TTL_MS,
  RULE_VERSION,
  UNREAD_TTL_MS,
  editedPath,
  fileKind,
  goalIssues,
  issuesNaming,
  issuesRead,
  judge,
  parseLineCounts,
  parseNumstat,
  rank,
  rankingKey,
  sizeCandidates,
  toCached,
  type CachedIssue,
  type Ranked,
} from './rules.ts'

// The area check (claude-config#1506), phase 1 (#1508): OBSERVE ONLY. Dan, 2026-10-22: sessions
// build in fragile areas without noticing that the area already has open structural issues, or is
// growing fast with nothing filed against it. Settled with him in /plan-lite the same day: ship it
// observing for a week first, and turn the hold on from what that week measured (#1509, L56, L172,
// L65). So this mod refuses nothing. For the first Edit, Write, MultiEdit or NotebookEdit a session
// makes to each existing source or test file (decisions 2 and 3), it works out the facts the hold
// would show (the open issues naming the file, its rough growth) and writes one record to a log
// outside ~/.claude, would_hold or quiet. The edit itself goes on at once: the facts are worked out
// off its path, under one deadline below 75% of a hook's 10 second budget (L743), so the week also
// measures whether the hold could have answered in time.
//
// The log, one JSON record a line, this Mac only (decision 10): ~/.claude-area-check/log.jsonl. A
// `loaded` record per session start, so a week with none reads as the mod never loading rather than
// as nothing firing (L90); then `judged` per file, or `unjudged` with why. Its own failures go to a
// separate file, errors.jsonl, by a different write than the one that failed (L561), and the first
// each session is one dim line; the edit is never affected.

const MOD = 'area-check'
const judgedRef = { plugin: 'area-check', key: 'judged' } as const
const errorsRef = { plugin: 'area-check', key: 'errors' } as const
const DIR = '.claude-area-check'
const LOG = 'log.jsonl'
const ERRORS = 'errors.jsonl'
const LATE = `not read within ${DEADLINE_MS / 1000} seconds`
const APPEND_MS = 5_000

class Late extends Error {}
type Deadline = { at: number }

const msg = (err: unknown) => errorText(err, MOD)
const firstLine = (s: string) => s.trim().split('\n')[0] ?? ''

const homeOf = async ($: EngineInterface) => (await $.env.get('HOME')) ?? ''

// One record appended to a file in ~/.claude-area-check. Appended, never read and written whole, so
// two sessions writing at once cannot lose each other's lines (assume it runs twice).
const append = async ($: EngineInterface, file: string, record: Record<string, unknown>) => {
  const home = await homeOf($)
  if (!home) throw new Error('HOME is not set, so the log has nowhere to go')
  const dir = `${home}/${DIR}`
  const r = await $.process.run(['/bin/sh', '-c', 'mkdir -p "$1" && cat >> "$2"', MOD, dir, `${dir}/${file}`], {
    stdin: JSON.stringify(record) + '\n',
    timeoutMs: APPEND_MS,
  })
  if (r.exitCode !== 0) throw new Error(`the log could not be written: ${firstLine(r.stderr) || `exit ${r.exitCode}`}`)
}

const left = async ($: EngineInterface, d: Deadline) => d.at - (await $.clock.now())

// A read raced against the deadline: past it, the read is LATE, whatever it would have said.
const within = async <T>($: EngineInterface, d: Deadline, work: Promise<T>): Promise<T> => {
  const ms = await left($, d)
  if (ms <= 0) throw new Late()
  let timer: { cancel: () => void } | undefined
  const late = new Promise<never>((_, reject) => {
    timer = $.clock.after(ms, () => reject(new Late()))
  })
  try {
    return await Promise.race([work, late])
  } finally {
    timer?.cancel()
  }
}

// A command run inside what is left of the deadline.
const runIn = async ($: EngineInterface, d: Deadline, argv: string[], init: { env?: Record<string, string>; stdin?: string } = {}): Promise<GhRun> => {
  const ms = await left($, d)
  if (ms <= 0) throw new Late()
  const r = await $.process.run(argv, { timeoutMs: ms, ...(init.env ? { env: init.env } : {}), ...(init.stdin !== undefined ? { stdin: init.stdin } : {}) })
  return { exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr }
}

// ---- Issues: one unfiltered list per repository (L1014), cached for an hour (decision 12) ----

type IssuesFacts = { at: number; state: 'read' | 'truncated'; count: number; issues: CachedIssue[] } | { at: number; state: 'unread'; why: string }
const issuesKey = (repo: string) => `issues:${repo}`
const fresh = (c: IssuesFacts | undefined, now: number): c is IssuesFacts =>
  !!c && typeof c.at === 'number' && now - c.at < (c.state === 'unread' ? UNREAD_TTL_MS : ISSUES_TTL_MS)
const inflight = new Map<string, Promise<IssuesFacts>>()

// The shared path reader (hooks/lib/match-open-issues.py --paths), the one the end of turn review's
// duplicate matcher reads paths with (L655, L370), beside the mods folder this mod is in.
const extractorOf = ($: EngineInterface) => `${$.plugin.root.replace(/\/+[^/]+\/+[^/]+\/*$/, '')}/hooks/lib/match-open-issues.py`

const notFound = (r: GhRun) => /Could not resolve to a Repository/i.test(r.stderr)
const failureOf = (failures: GhRun[]) => {
  const f = failures.find(x => !notFound(x)) ?? failures[0]
  return f ? firstLine(f.stderr) || `gh exited ${f.exitCode}` : 'gh answered nothing'
}

const readIssues = async ($: EngineInterface, repo: string, d: Deadline): Promise<IssuesFacts> => {
  const at = await $.clock.now()
  let facts: IssuesFacts
  try {
    // As each account gh is logged in to, through mod-kit's one helper (decision 12): Dan's work
    // repositories are visible only to his work account.
    const r = await askAnyAccount((argv, env, stdin) => runIn($, d, argv, { ...(env ? { env } : {}), ...(stdin !== undefined ? { stdin } : {}) }), [
      'issue', 'list', '--repo', repo, '--state', 'open', '--limit', String(ISSUE_LIMIT), '--json', 'number,title,body,labels',
    ])
    if (!('stdout' in r)) facts = { at, state: 'unread', why: failureOf(r.failures) }
    else {
      const read = issuesRead(r.stdout)
      if (read.state === 'unread') facts = { at, ...read }
      else {
        const rows = read.rows.map(({ number, title, body }) => ({ number, title, body }))
        const p = await runIn($, d, ['python3', extractorOf($), '--paths'], { stdin: JSON.stringify(rows) })
        let refs: Record<string, string[]> | null = null
        if (p.exitCode === 0) {
          try {
            const parsed = JSON.parse(p.stdout) as unknown
            if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) refs = parsed as Record<string, string[]>
          } catch {
            refs = null
          }
        }
        if (p.exitCode !== 0) facts = { at, state: 'unread', why: `the path reader failed: ${firstLine(p.stderr) || `exit ${p.exitCode}`}` }
        else if (!refs) facts = { at, state: 'unread', why: 'the path reader answered with something that is not a list of paths' }
        // An issue naming no path can never match, so only the count keeps it (the store holds 4 MiB).
        else facts = { at, state: read.state, count: read.rows.length, issues: toCached(read.rows, refs).filter(i => i.refs.length) }
      }
    }
  } catch (err) {
    facts = { at, state: 'unread', why: err instanceof Late ? LATE : `gh could not be run: ${msg(err)}` }
  }
  await $.store.set(issuesKey(repo), facts)
  return facts
}

const issuesFor = async ($: EngineInterface, repo: string, d: Deadline): Promise<IssuesFacts> => {
  const now = await $.clock.now()
  const cached = (await $.store.get(issuesKey(repo))) as IssuesFacts | undefined
  if (fresh(cached, now)) return cached
  let p = inflight.get(repo)
  if (!p) {
    p = readIssues($, repo, d).finally(() => inflight.delete(repo))
    inflight.set(repo, p)
  }
  try {
    return await within($, d, p)
  } catch (err) {
    if (!(err instanceof Late)) throw err
    const late: IssuesFacts = { at: now, state: 'unread', why: LATE }
    await $.store.set(issuesKey(repo), late)
    return late
  }
}

// ---- Growth: from origin's default branch, keyed on its head, the day and the rule version ----

type RankFacts = { key: string; sha: string; ranked: Ranked; tracked: string[] } | { unread: string; sha: string | null }
const rankings = new Map<string, Promise<RankFacts>>()
const RANKINGS_KEPT = 8

const gitIn = async ($: EngineInterface, d: Deadline, root: string, args: string[], okCodes: number[] = [0]) => {
  const r = await runIn($, d, ['git', '-C', root, ...args])
  if (!okCodes.includes(r.exitCode)) throw new Error(`git ${args[0]} failed: ${firstLine(r.stderr) || `exit ${r.exitCode}`}`)
  return r.stdout
}

const ranking = async ($: EngineInterface, d: Deadline, root: string, defaultBranch: string | null, repo: string): Promise<RankFacts> => {
  if (!defaultBranch) return { unread: 'origin names no default branch', sha: null }
  const rev = `origin/${defaultBranch}`
  let sha: string | null = null
  try {
    sha = (await gitIn($, d, root, ['rev-parse', '--verify', `${rev}^{commit}`])).trim()
    const key = rankingKey(repo, sha, await $.clock.now())
    let p = rankings.get(key)
    if (!p) {
      const head = sha
      p = (async (): Promise<RankFacts> => {
        const [log, tree] = await Promise.all([
          gitIn($, d, root, ['log', rev, `--since=${GROWTH_DAYS}.days`, '--numstat', '-M', '--format=%x1e%s']),
          gitIn($, d, root, ['ls-tree', '-r', '--name-only', rev]),
        ])
        const growth = parseNumstat(log)
        const cands = sizeCandidates(growth)
        const sizes = cands.length ? parseLineCounts(await gitIn($, d, root, ['grep', '-c', '', rev, '--', ...cands], [0, 1]), rev) : {}
        return { key, sha: head, ranked: rank(growth, sizes), tracked: tree.split('\n').filter(Boolean) }
      })()
      rankings.set(key, p)
      while (rankings.size > RANKINGS_KEPT) rankings.delete(rankings.keys().next().value as string)
      // A failed ranking is not kept, so the next edit tries again.
      p.catch(() => rankings.delete(key))
    }
    return await within($, d, p)
  } catch (err) {
    return { unread: err instanceof Late ? LATE : msg(err), sha }
  }
}

// ---- The session's own issues: its branch's and its /goal's (decision 5) ----

type GoalFacts = { state: string; issues: number[] }
const goalOf = async ($: EngineInterface, d: Deadline): Promise<GoalFacts> => {
  try {
    return await within($, d, (async () => {
      const list = await $.sessions.list()
      const me = [...list.open, ...list.closed].find(r => r.sessionId === list.selfId)
      if (!me?.transcriptPath) return { state: "unread: this session's transcript was not found", issues: [] }
      const g = await $.modkit.goal({ transcript: me.transcriptPath })
      if (g.state === 'set') return { state: 'set', issues: goalIssues(g.condition) }
      if (g.state === 'none') return { state: 'none', issues: [] }
      return { state: `unread: ${g.why}`, issues: [] }
    })())
  } catch (err) {
    return { state: `unread: ${err instanceof Late ? LATE : msg(err)}`, issues: [] }
  }
}

// ---- Once per file per session (decision 2), a subagent judged for itself (decision 8) ----

const claim = async ($: EngineInterface, key: string): Promise<boolean> => {
  for (let i = 0; i < 5; i++) {
    const s = await $.state.get(judgedRef)
    const list = s.value ?? []
    if (list.includes(key)) return false
    if ((await $.state.set(judgedRef, [...list, key], { ifVersion: s.version })).isSet) return true
  }
  return false
}

const relTo = (path: string, root: string) => (path.startsWith(root + '/') ? path.slice(root.length + 1) : path)

const look = async ($: EngineInterface, path: string, agent: string | null, refusedBeneath: boolean) => {
  const started = await $.clock.now()
  const d: Deadline = { at: started + DEADLINE_MS }
  const session = await $.session.id()
  const at = new Date(started).toISOString()
  const b = await $.modkit.branch({ path })
  if (!b) return
  if ('unreadable' in b) {
    const rel = relTo(path, b.root)
    if (!fileKind(rel) || !(await claim($, [b.main ?? b.root, rel, agent ?? ''].join('\n')))) return
    await append($, LOG, { v: 1, kind: 'unjudged', at, session, agent, path: rel, why: b.unreadable })
    return
  }
  const rel = relTo(path, b.root)
  const kind = fileKind(rel)
  if (!kind) return
  if (!(await claim($, [b.main, rel, agent ?? ''].join('\n')))) return
  const remote = await runIn($, d, ['git', '-C', b.root, 'remote', 'get-url', 'origin'])
    .then(r => (r.exitCode === 0 ? r.stdout.trim() || null : null))
    .catch(() => null)
  const repo = (await $.modkit.repo({ root: b.main, remote })).github
  // Every checkout with a GitHub remote (decision 9); any other is said, never judged as quiet.
  if (!repo) {
    await append($, LOG, { v: 1, kind: 'unjudged', at, session, agent, path: rel, why: remote ? 'its origin is not on GitHub' : 'it has no origin remote' })
    return
  }
  const [issues, ranked, goal, mergeBase] = await Promise.all([
    issuesFor($, repo, d),
    ranking($, d, b.root, b.defaultBranch, repo),
    goalOf($, d),
    b.defaultBranch
      ? gitIn($, d, b.root, ['merge-base', 'HEAD', `origin/${b.defaultBranch}`]).then(s => s.trim() || null).catch(() => null)
      : Promise.resolve(null),
  ])
  const tracked = 'tracked' in ranked ? ranked.tracked : []
  const matches = issues.state === 'unread' ? [] : issuesNaming(rel, issues.issues, tracked)
  const own = [...new Set([...b.issues, ...goal.issues])]
  const crosses = 'ranked' in ranked && ranked.ranked.top.includes(rel)
  const j = judge({ matches, own, crosses })
  const growth = 'ranked' in ranked
    ? { ...(ranked.ranked.facts[rel] ?? { net: 0, size: null, fixes: 0, rank: null }), crosses }
    : { unread: ranked.unread }
  await append($, LOG, {
    v: 1,
    kind: 'judged',
    at,
    session,
    agent,
    repo,
    path: rel,
    fileKind: kind,
    refusedBeneath,
    branch: b.branch,
    mergeBase,
    head: ranked.sha,
    decision: j.decision,
    why: j.why,
    shown: j.shown,
    excluded: j.excluded,
    own,
    goal: goal.state,
    matches,
    issues: issues.state === 'unread'
      ? { state: 'unread', why: issues.why, ageMs: started - issues.at }
      : { state: issues.state, count: issues.count, ageMs: started - issues.at },
    growth,
    rule: RULE_VERSION,
    ms: (await $.clock.now()) - started,
  })
}

// Its own failure: counted, kept in the error file, said once a session; the edit is never touched.
// Every step is caught on its own, so a failure here can never reach the call (L561, L95).
const failed = async ($: EngineInterface, path: string, err: unknown) => {
  const error = msg(err)
  let n = 1
  try {
    n = ((await $.state.get(errorsRef)).value ?? 0) + 1
    await $.state.set(errorsRef, n)
  } catch {
    // The count is a convenience; the error file below is the record.
  }
  try {
    await append($, ERRORS, { v: 1, kind: 'error', at: new Date(await $.clock.now()).toISOString(), session: await $.session.id(), path, error })
  } catch (again) {
    $.ui.log(`${MOD}: an error could not be kept in ~/${DIR}/${ERRORS} (${msg(again)}); it was: ${error}`, { to: 'debug' })
  }
  if (n !== 1) return
  try {
    const cwd = await $.session.cwd()
    $.ui.log(`The area check could not look at ${relTo(path, cwd)} (${error}). It only observes for now, so nothing was held; the error is kept in ~/${DIR}/${ERRORS}.`)
  } catch {
    // Nothing more can be said.
  }
}

// Off the call's path: the edit goes on at once, and whatever this does is caught.
const later = ($: EngineInterface, path: string, work: () => Promise<unknown>) =>
  $.clock.after(0, () => void work().catch(err => failed($, path, err)))

// The session's own repository, read before its first edit needs it (decision 12).
const warm = async ($: EngineInterface) => {
  const here = await $.session.repo()
  if (!here) return
  const b = await $.modkit.branch({ path: here.root })
  if (!b || 'unreadable' in b) return
  const repo = (await $.modkit.repo({ root: here.root, remote: here.remote })).github
  if (!repo) return
  const d: Deadline = { at: (await $.clock.now()) + DEADLINE_MS }
  await Promise.all([issuesFor($, repo, d), ranking($, d, b.root, b.defaultBranch, repo)])
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const r = await next(e)
    later($, e.cwd, async () => {
      await append($, LOG, { v: 1, kind: 'loaded', at: new Date(await $.clock.now()).toISOString(), session: await $.session.id(), cwd: e.cwd, rule: RULE_VERSION })
      await warm($)
    })
    return r
  })

  // Every tool call: only an edit tool's, to a file already there, is looked at, after it has been
  // let through. Nothing here can refuse or change the call.
  on('tool.call', async ($, e, next) => {
    const raw = e as unknown as Record<string, unknown>
    const path = editedPath(e.tool, raw)
    if (!path) return next(e)
    // Whether the file was there is asked before the call runs, since a Write makes it.
    let existed = false
    try {
      existed = await $.fs.exists(path)
    } catch (err) {
      later($, path, () => Promise.reject(err))
    }
    const r = await next(e)
    // The attempt is what the hold would meet, so an edit a guard beneath refused is judged too, and
    // the record says so.
    if (existed) later($, path, () => look($, path, e.agentId ?? null, r.deny !== undefined))
    return r
  })
}
