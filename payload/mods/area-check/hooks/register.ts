import type { EngineInterface, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { askAnyAccount, type GhRun } from './mod-kit/ghaccounts.ts'
import { errorText, missingOf } from './mod-kit/skew.ts'
import { neverThrows } from './mod-kit/hold.ts'
import type { ModKitCommand, ModKitGh } from '../.claude-plugin/types/mod-kit/index.d.ts'
import {
  MARKS,
  READ_SCRIPT,
  ROTATE_BYTES,
  ROTATE_SCRIPT,
  SETTLE_MINUTES,
  bodyUnreadableRefusal,
  bodyUnresolvedRefusal,
  branchNeedle,
  checkFailedRefusal,
  inRepo,
  mayActOnPr,
  logUnreadableRefusal,
  malformedDim,
  missingFrom,
  missingRefusal,
  noBodyRefusal,
  onBranch,
  readOf,
  repoNeedle,
  rotationStamp,
  type LogRead,
} from './prline.ts'
import {
  DEADLINE_MS,
  FOLDER_JUDGE_MAX,
  GROWTH_DAYS,
  ISSUE_LIMIT,
  ISSUES_TTL_MS,
  RULE_VERSION,
  barFor,
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
  ASK_SOURCE,
  DECIDE_TOOL,
  DECISIONS,
  answerStands,
  couldHold,
  repoIssues,
  decideProblem,
  heldCall,
  holdCard,
  holdRefusal,
  heldUnder,
  shellKey,
  shellTargets,
  scriptProgram,
  scriptWrite,
  trapTexts,
  unreadPart,
  questionKey,
  legacyQuestionKey,
  restructureQuestion,
  sleepNotes,
  sweepKeys,
  type CachedIssue,
  type Decision,
  type Held,
  type Question,
  type Ranked,
  type ShellRun,
  type ShellTarget,
} from './rules.ts'
import { currentText } from './mod-kit/inputs.ts'

// The area check (claude-config#1506), phase 2 (#1509): the HOLD. Dan, 2026-10-22: sessions build
// in fragile areas without noticing that the area already has open structural issues, or is growing
// fast with nothing filed against it. Phase 1 (#1508) observed for a week; its log set the bar. Now the
// first Edit, Write, MultiEdit or NotebookEdit a session makes to each existing source or test file
// (decisions 2 and 3), or a Bash command writing one (#2142, read by mod-kit's $.modkit.writes), is held when an open structural issue at p0 to p2 names the file (Dan's choice,
// 2026-11-02) or the file crosses the growth bar, and the session decides with the decide tool:
// proceed with a reason, fold a shown issue in, or restructure, which asks Dan (decision 7). The main
// session is held at tool.check, beneath the settings hooks; a subagent at tool.call, for itself
// (decision 8). The facts are read on the call's path under one deadline below 75% of a hook's 10
// second budget (L743); a read past it is UNREAD, and only growth can then hold.
//
// The log, one JSON record a line, this Mac only (decision 10): ~/.claude-area-check/log.jsonl. A
// `loaded` record per session start, so a week with none reads as the mod never loading rather than
// as nothing firing (L90); then `judged` per file, or `unjudged` with why. Its own failures go to a
// separate file, errors.jsonl, by a different write than the one that failed (L561), and the first
// each session is one dim line; a failure of the check lets the edit through, and says so.

const MOD = 'area-check'
const judgedRef = { plugin: 'area-check', key: 'judged' } as const
const errorsRef = { plugin: 'area-check', key: 'errors' } as const
const heldRef = { plugin: 'area-check', key: 'held' } as const
const DIR = '.claude-area-check'
const LOG = 'log.jsonl'
const ERRORS = 'errors.jsonl'
const LATE = `not read within ${DEADLINE_MS / 1000} seconds`
const APPEND_MS = 5_000

class Late extends Error {}
type Deadline = { at: number }

const msg = (err: unknown) => errorText(err, MOD)
// The decide tool's refusal when it failed, naming why; HELD is the same refusal built once here, for
// when even naming the failure throws, so the catch never throws (#2039).
const undecided = (why: string) => ({ deny: `The area check could not take the decision (${why}); the edit stays held. Try again.` })
const HELD = undecided('unknown failure')
// The pull request check's catch (#2173): a command that could be a gh pr create, edit or merge is
// held naming why; any other is left to run, the hook absent, as it was before. PR_HELD is built once
// here for when even that throws.
const PR_HELD = checkFailedRefusal('unknown failure')
const prCaught = (e: unknown, error: unknown): { deny: string } | undefined => {
  const command = (e as Record<string, unknown>).command
  return typeof command === 'string' && !mayActOnPr(command) ? undefined : { deny: checkFailedRefusal(msg(error)) }
}
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

// ---- A read several edits share ----
//
// The issue list and the growth ranking are each read once however many edits want them at once. A
// shared read runs under the deadline of the edit (or the session start's warm) that started it, so
// it can fail for that one's lack of time while an edit that joined it still has some: by running out
// (Late), by a command killed at its timeout, or by anything else. Lessons reviews of 5a4148a, 42547b6
// and adb5a9e found that one cause at a time; it is one rule, kept here once: an edit that JOINED a
// read which then failed, for whatever reason, starts it again, once, under its own deadline. An edit
// that started the read itself is not retried, so in a real outage the edit that started a read pays
// for one, and an edit that joined it for one more of its own, never further.
const shared = async <T>(
  $: EngineInterface,
  d: Deadline,
  map: Map<string, Promise<T>>,
  key: string,
  start: (d: Deadline) => Promise<T>,
  failed: (r: T) => boolean,
  keep: boolean,
): Promise<T> => {
  const begin = () => {
    const p = start(d)
    map.set(key, p)
    const drop = () => {
      if (map.get(key) === p) map.delete(key)
    }
    // A failed read is never kept, so the next edit reads again; a good one only where `keep` says.
    p.then(r => (!keep || failed(r) ? drop() : undefined), drop)
    return p
  }
  const had = map.get(key)
  const settle = (p: Promise<T>) => within($, d, p).then(r => ({ r }), (err: unknown) => ({ err }))
  let o: { r: T } | { err: unknown } = await settle(had ?? begin())
  if (had && ('err' in o || failed(o.r)) && (await left($, d)) > 0) o = await settle(begin())
  if ('err' in o) throw o.err
  return o.r
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
  try {
    // What a read finds replaces whatever the cache held, a late read another edit left included.
    return await shared($, d, inflight, repo, own => readIssues($, repo, own), r => r.state === 'unread', false)
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
    const head = sha
    const key = rankingKey(repo, head, await $.clock.now())
    const make = async (own: Deadline): Promise<RankFacts> => {
      const [log, tree] = await Promise.all([
        gitIn($, own, root, ['log', rev, `--since=${GROWTH_DAYS}.days`, '--numstat', '-M', '--format=%x1e%s']),
        gitIn($, own, root, ['ls-tree', '-r', '--name-only', rev]),
      ])
      const growth = parseNumstat(log)
      const bar = barFor(repo)
      const cands = sizeCandidates(growth, bar)
      const sizes = cands.length ? parseLineCounts(await gitIn($, own, root, ['grep', '-c', '', rev, '--', ...cands], [0, 1]), rev) : {}
      return { key, sha: head, ranked: rank(growth, sizes, bar), tracked: tree.split('\n').filter(Boolean) }
    }
    const r = await shared($, d, rankings, key, make, () => false, true)
    while (rankings.size > RANKINGS_KEPT) rankings.delete(rankings.keys().next().value as string)
    return r
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
//
// A file is claimed once the session (or a subagent, under its own id) is done with it: a quiet edit
// whose issues AND growth were both read, or a held edit once it is decided. A held edit is never
// claimed by being held, so sending it again before deciding is held again; a quiet edit with a read
// that failed passes unclaimed, so the next edit tries again (decision 12).

const keyOf = (main: string, rel: string, agent: string | null) => [main, rel, agent ?? ''].join('\n')

const isClaimed = async ($: EngineInterface, key: string) => ((await $.state.get(judgedRef)).value ?? []).includes(key)

const claim = async ($: EngineInterface, key: string): Promise<boolean> => {
  for (let i = 0; i < 5; i++) {
    const s = await $.state.get(judgedRef)
    const list = s.value ?? []
    if (list.includes(key)) return false
    if ((await $.state.set(judgedRef, [...list, key], { ifVersion: s.version })).isSet) return true
  }
  return false
}

// ---- The held edits, each under its call id, in this session's $.state (#1509) ----

const HELD_MAX = 50

const heldOf = async ($: EngineInterface, id: string): Promise<Held | undefined> => ((await $.state.get(heldRef)).value ?? []).find(h => h.id === id)

const updateHeld = async ($: EngineInterface, change: (list: Held[]) => Held[]) => {
  for (let i = 0; i < 5; i++) {
    const s = await $.state.get(heldRef)
    if ((await $.state.set(heldRef, change(s.value ?? []), { ifVersion: s.version })).isSet) return
  }
  throw new Error('the list of held edits could not be written: another write kept changing it')
}

const relTo = (path: string, root: string) => (path.startsWith(root + '/') ? path.slice(root.length + 1) : path)

// The error file's record of one failure, which never throws; a debug line where it cannot be kept.
const keepError = async ($: EngineInterface, path: string, error: string) => {
  try {
    await append($, ERRORS, { v: 1, kind: 'error', at: new Date(await $.clock.now()).toISOString(), session: await $.session.id(), path, error })
  } catch (again) {
    $.ui.log(`${MOD}: an error could not be kept in ~/${DIR}/${ERRORS} (${msg(again)}); it was: ${error}`, { to: 'debug' })
  }
}

// Its own failure: counted, kept in the error file, said once a session. Every step is caught on its
// own, so a failure here can never reach the call (L561, L95). `kept` says what it means for the edit.
const failed = async ($: EngineInterface, path: string, err: unknown, kept: 'unchecked' | 'unlogged' | 'shell' | 'command' | 'rotation' = 'unchecked') => {
  const error = msg(err)
  let n = 1
  try {
    n = ((await $.state.get(errorsRef)).value ?? 0) + 1
    await $.state.set(errorsRef, n)
  } catch {
    // The count is a convenience; the error file below is the record.
  }
  await keepError($, path, error)
  if (n !== 1) return
  try {
    const rel = relTo(path, await $.session.cwd())
    $.ui.log(
      kept === 'rotation'
        ? `The area check could not rotate its log (${error}); nothing was lost, and the error is kept in ~/${DIR}/${ERRORS}.`
        : kept === 'shell'
        ? `The area check could not read what a shell command writes (${error}), so it went ahead unchecked; the error is kept in ~/${DIR}/${ERRORS}.`
        : kept === 'command'
        ? `The area check could not check the pull request command (${error}), so it went ahead unchecked; the error is kept in ~/${DIR}/${ERRORS}.`
        : kept === 'unchecked'
          ? `The area check could not look at ${rel} (${error}), so the edit went ahead unchecked; the error is kept in ~/${DIR}/${ERRORS}.`
          : `The area check could not write its log for ${rel} (${error}); what it decided stands, and the error is kept in ~/${DIR}/${ERRORS}.`,
    )
  } catch {
    // Nothing more can be said.
  }
}

// A log record whose write failing is an error of its own: whatever the record was about stands.
const logged = async ($: EngineInterface, path: string, record: Record<string, unknown>) => {
  try {
    await append($, LOG, record)
  } catch (err) {
    await failed($, path, err, 'unlogged')
  }
}

// Off the call's path: whatever this does is caught.
const later = ($: EngineInterface, path: string, work: () => Promise<unknown>) =>
  $.clock.after(0, () => void work().catch(err => failed($, path, err)))

// ---- Judging one edit ----

const PASS = { pass: true } as const
type Verdict = typeof PASS | { held: Held }
// The two answers of Dan's that release the file; Fold in leaves it for the session to fold.
const RELEASING: readonly string[] = ['Restructure first', 'Proceed anyway']

const judgeEdit = async ($: EngineInterface, tool: string, id: string, path: string, agent: string | null): Promise<Verdict> => {
  const started = await $.clock.now()
  const d: Deadline = { at: started + DEADLINE_MS }
  const session = await $.session.id()
  const at = new Date(started).toISOString()
  const b = await $.modkit.branch({ path })
  if (!b) return PASS
  if ('unreadable' in b) {
    const rel = relTo(path, b.root)
    if (fileKind(rel) && (await claim($, keyOf(b.main ?? b.root, rel, agent)))) await logged($, path, { v: 1, kind: 'unjudged', at, session, agent, path: rel, why: b.unreadable })
    return PASS
  }
  const rel = relTo(path, b.root)
  const kind = fileKind(rel)
  if (!kind) return PASS
  const key = keyOf(b.main, rel, agent)
  if (await isClaimed($, key)) return PASS
  const remote = await runIn($, d, ['git', '-C', b.root, 'remote', 'get-url', 'origin'])
    .then(r => (r.exitCode === 0 ? r.stdout.trim() || null : null))
    .catch(() => null)
  const repo = (await $.modkit.repo({ root: b.main, remote })).github
  // Every checkout with a GitHub remote (decision 9); any other is said, never judged as quiet.
  if (!repo) {
    if (await claim($, key)) await logged($, path, { v: 1, kind: 'unjudged', at, session, agent, path: rel, why: remote ? 'its origin is not on GitHub' : 'it has no origin remote' })
    return PASS
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
  const bar = barFor(repo)
  const matches = issues.state === 'unread' ? [] : issuesNaming(rel, issues.issues, tracked, bar.folderMax)
  const own = [...new Set([...b.issues, ...goal.issues])]
  const crosses = 'ranked' in ranked && ranked.ranked.top.includes(rel)
  const j = judge({ matches, own, crosses, bar })
  const growth: Held['growth'] = 'ranked' in ranked
    ? { ...(ranked.ranked.facts[rel] ?? { net: 0, size: null, fixes: 0, rank: null }), crosses }
    : { unread: ranked.unread }
  const record = async (extra: Record<string, unknown>) =>
    logged($, path, {
      v: 2,
      kind: 'judged',
      at,
      session,
      agent,
      repo,
      path: rel,
      fileKind: kind,
      branch: b.branch,
      mergeBase,
      head: ranked.sha,
      ...extra,
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
      bar: bar.set,
      ms: (await $.clock.now()) - started,
    })

  if (j.decision === 'quiet') {
    const read = issues.state !== 'unread' && 'ranked' in ranked
    // Another edit claiming it meanwhile has logged it already.
    if (read && !(await claim($, key))) return PASS
    await record({ decision: 'quiet' })
    return PASS
  }
  // Dan's answer about this file, for these issues, within its week (L330): applied, never asked again.
  const q = await answeredQuestion($, repo, rel)
  if (answerStands(q, j.shown, started) && RELEASING.includes(q.answer)) {
    await claim($, key)
    await record({ decision: 'held', applied: q.answer })
    return PASS
  }
  const h: Held = {
    id,
    tool,
    repo,
    main: b.main,
    rel,
    agent,
    at: started,
    why: j.why,
    shown: matches.filter(m => j.shown.includes(m.n)),
    issues: issues.state === 'unread' ? { state: 'unread', why: issues.why } : { state: issues.state },
    growth,
    branch: b.branch,
    mergeBase,
  }
  await updateHeld($, list => [...list.filter(x => x.id !== id), h].slice(-HELD_MAX))
  await record({ decision: 'held' })
  return { held: h }
}

// The grey card under the call's id; a card that cannot be drawn leaves the refusal Claude reads.
const card = async ($: EngineInterface, toolUseId: string, c: { reason: string; safeWay?: string; note?: string }, guard = GUARD) => {
  try {
    await $.modkit.blocked({ toolUseId, guard, ...c })
  } catch (err) {
    $.ui.log(`${MOD}: the card for ${toolUseId} could not be drawn (${msg(err)})`, { to: 'debug' })
  }
}

// One edit's verdict as the call meets it: refused with the facts and how to decide, or let through.
// Its own failure lets the edit through, said (fail loud about the check, never about the edit).
const gate = async ($: EngineInterface, tool: string, id: string, path: string, agent: string | null): Promise<{ deny: string } | typeof PASS> => {
  try {
    if (!(await $.fs.exists(path))) return PASS
    const v = await judgeEdit($, tool, id, path, agent)
    if ('pass' in v) return PASS
    await card($, id, holdCard(v.held))
    return { deny: holdRefusal(v.held) }
  } catch (err) {
    await failed($, path, err)
    return PASS
  }
}

// ---- A shell command's writes (#2142) ----
//
// A file a command names is judged as its first edit would be, under the same claim, so whichever
// tool writes it next is let through once decided. A write whose file cannot be named before the
// command runs is judged by the checkout it lands in (the session's, where the reader names no
// folder): it passes where there is no checkout on GitHub or nothing there could hold a file, and is
// otherwise held, claimed by its command once decided, so only that unchanged command then runs.

const judgeUnread = async ($: EngineInterface, id: string, t: Extract<ShellTarget, { unread: string }>, command: string, agent: string | null): Promise<Verdict> => {
  const started = await $.clock.now()
  const d: Deadline = { at: started + DEADLINE_MS }
  const key = `${await shellKey(command)}\n${agent ?? ''}`
  if (await isClaimed($, key)) return PASS
  const where = t.folder ?? (await $.session.cwd())
  const b = await $.modkit.branch({ path: where })
  if (!b || 'unreadable' in b) return PASS
  const remote = await runIn($, d, ['git', '-C', b.root, 'remote', 'get-url', 'origin'])
    .then(r => (r.exitCode === 0 ? r.stdout.trim() || null : null))
    .catch(() => null)
  const repo = (await $.modkit.repo({ root: b.main, remote })).github
  if (!repo) return PASS
  const [issues, ranked, goal] = await Promise.all([issuesFor($, repo, d), ranking($, d, b.root, b.defaultBranch, repo), goalOf($, d)])
  const own = [...new Set([...b.issues, ...goal.issues])]
  // An issue list that could not be read leaves growth alone to decide, as it does for an edit.
  const holds = couldHold({ issues: issues.state === 'unread' ? [] : issues.issues, own, top: 'ranked' in ranked ? ranked.ranked.top : [], bar: barFor(repo) })
  const record = async (decision: 'held' | 'passed') =>
    logged($, where, { v: 1, kind: 'unread', at: new Date(started).toISOString(), session: await $.session.id(), agent, repo, word: t.word, why: t.unread, decision })
  if (!holds) {
    await record('passed')
    return PASS
  }
  const h: Held = {
    id,
    tool: 'Bash',
    repo,
    main: b.main,
    rel: t.word,
    agent,
    at: started,
    why: [],
    // The open structural issues it may be folded into (#2706), the session's own among them.
    shown: issues.state === 'unread' ? [] : repoIssues(issues.issues),
    issues: issues.state === 'unread' ? { state: 'unread', why: issues.why } : { state: issues.state },
    growth: { unread: 'no file is named, so no growth is read' },
    unread: { why: t.unread, key },
  }
  await updateHeld($, list => [...list.filter(x => x.id !== id), h].slice(-HELD_MAX))
  await record('held')
  return { held: h }
}

// A write reaching a whole folder (#2142 lessons review) reaches every file under it: the files there
// the area check could hold, from the same tracked list and issues an edit is judged by, or why they
// cannot be listed. A folder in no checkout, or in one not on GitHub, holds nothing to judge. `max`
// bounds how many of them are judged one by one, for a write marked `tree` (#2373) and a folder found
// on the disk (#2321) alike: past it the files are not listed for judging, and the command is held
// whole (FOLDER_JUDGE_MAX).
const underTree = async ($: EngineInterface, path: string, max: number): Promise<{ paths: string[] } | { unread: string }> => {
  const d: Deadline = { at: (await $.clock.now()) + DEADLINE_MS }
  const b = await $.modkit.branch({ path })
  if (!b || 'unreadable' in b) return { paths: [] }
  const remote = await runIn($, d, ['git', '-C', b.root, 'remote', 'get-url', 'origin'])
    .then(r => (r.exitCode === 0 ? r.stdout.trim() || null : null))
    .catch(() => null)
  const repo = (await $.modkit.repo({ root: b.main, remote })).github
  if (!repo) return { paths: [] }
  const [issues, ranked] = await Promise.all([issuesFor($, repo, d), ranking($, d, b.root, b.defaultBranch, repo)])
  if (!('tracked' in ranked)) return { unread: `the files under it cannot be listed (${ranked.unread})` }
  const rel = path === b.root ? '' : relTo(path, b.root)
  const held = heldUnder(rel, { tracked: ranked.tracked, top: ranked.ranked.top, issues: issues.state === 'unread' ? [] : issues.issues })
  if (held.length > max) return { unread: `${held.length} files under it could be held, more than the ${max} the area check judges one by one (among them ${held.slice(0, 3).join(', ')})` }
  // With its open issues unread (#2636), which of the files under it the area check would hold cannot
  // be checked: judged one by one they were held on growth alone, one hold per file, each naming a
  // file the command may never touch, and a proceed claimed only that file. Said once instead, and
  // decided for the command as a whole.
  if (held.length && issues.state === 'unread') return { unread: `its open issues could not be read (${issues.why}), so which of the files under it the area check would hold cannot be checked (among them ${held.slice(0, 3).join(', ')})` }
  return { paths: held.map(r => `${b.root}/${r}`) }
}

// A path without its `.` segments or a trailing slash (`src/.` is src), so it is matched as git lists it.
const plain = (path: string) => path.replace(/\/\.(?=\/|$)/g, '').replace(/(.)\/+$/, '$1')

// Whether a path a command names is a folder (#2321): mod-kit names a folder handed to a script, or a
// copy's folder destination, by its path as it would a file, so only the disk can say. Nothing there
// is no folder; a path that exists but whose look is refused cannot be told apart, said with why. The
// existence check is half of that look, so it is inside the same catch (#2407 lessons review). A
// folder comes back as `dir`, where the path really lands (stat's realPath, its own spelling where
// none is given): a link to a folder holds the files git lists under the folder it leads to, never
// under the link's own spelling.
const folderAt = async ($: EngineInterface, path: string): Promise<false | { dir: string } | { unread: string }> => {
  try {
    if (!(await $.fs.exists(path))) return false
    const s = await $.fs.stat(path, { resolve: true })
    return s.kind === 'dir' ? { dir: plain(s.realPath ?? path) } : false
  } catch (err) {
    return { unread: msg(err) }
  }
}

type Unread = Extract<ShellTarget, { unread: string }>

// Whether a script handed a folder can write there (#2407): its file read as mod-kit reads every file
// a command names (currentText, which never opens a device or a fifo), fed to its interpreter as the
// program it runs (scriptProgram), and read by mod-kit's one reader of what a command writes, run from
// the folder the session is in (programWrites). `writes: null` only when every step answered and the script writes
// nothing the area check could judge; anything that cannot be read, or any write, is why it may write
// there, so the folder is judged as before (fail closed).
const scriptWritesIn = async ($: EngineInterface, run: ShellRun): Promise<{ writes: string | null }> => {
  if (!run.path) return { writes: `${run.what} is named by no path that can be read` }
  const cur = await currentText({ exists: p => $.fs.exists(p), stat: (p, o) => $.fs.stat(p, o), read: p => $.fs.read(p) }, run.path)
  if (!('text' in cur)) return { writes: 'unreadable' in cur ? `the script cannot be read: ${cur.unreadable}` : 'the script is not there' }
  const [cwd, home] = await Promise.all([$.session.cwd(), homeOf($)])
  return { writes: await programWrites($, run, cur.text, { cwd, home }, 0) }
}

// How many traps deep a script's text is read (a trap whose text sets a trap, and so on); one set
// deeper than that is not read, so the script is held.
const TRAPS_DEEP = 3

// Why a script's text may write, or null: the text fed to its interpreter and read by mod-kit's one
// reader, then the text of each trap it sets read the same way (#2619), since the reader gives a
// trap's text as a word, never as the commands it runs, and a write in one was read as no write.
const programWrites = async ($: EngineInterface, run: ShellRun, text: string, at: { cwd: string; home: string }, depth: number): Promise<string | null> => {
  const prog = scriptProgram(run, text)
  if ('unread' in prog) return prog.unread
  const read = { command: prog.command, cwd: at.cwd, home: at.home }
  const commands = await $.modkit.pipeline(read)
  const unread = unreadPart(commands, prog.delimiter, text)
  if (unread) return unread
  const wrote = scriptWrite(await $.modkit.writes(read), at.home)
  if (wrote) return wrote
  // A trap's text has no #! line, so it is fed to the interpreter the script's own text was.
  const sameInterpreter: ShellRun = { what: `a ${prog.name} script file`, path: run.path }
  for (const trap of trapTexts(commands)) {
    const inTrap = depth < TRAPS_DEEP ? await programWrites($, sameInterpreter, trap, at, depth + 1) : 'it is set by more traps than are read'
    if (inTrap) return `its trap runs ${trap}: ${inTrap}`
  }
  return null
}

// Whether every script a folder was handed to is read as writing nothing there (#2426 lessons review):
// the first that may write, or whose reading throws, answers no.
const allOnlyRead = async ($: EngineInterface, runs: readonly ShellRun[]): Promise<boolean> => {
  for (const r of runs) {
    try {
      if ((await scriptWritesIn($, r)).writes !== null) return false
    } catch {
      return false
    }
  }
  return true
}

// A path a command writes, judged as its first edit would be; then, for a write marked `tree` or a
// path the disk says is a folder (#2321), each file under it the area check could hold, which refuses
// the command naming that file. A folder whose files cannot be listed, too many of them to judge one
// by one, or a path that may be a folder but cannot be read, comes back as a write that cannot be
// named, held as one (fail closed: one decision lets it through, where letting it pass would let a
// write into a held file go unasked). A judging that throws passes, said, as gate's own does.
const gatePath = async ($: EngineInterface, id: string, t: Extract<ShellTarget, { path: string }>, agent: string | null): Promise<{ deny: string } | typeof PASS | Unread> => {
  const v = await gate($, 'Bash', id, t.path, agent)
  if ('deny' in v) return v
  let at = plain(t.path)
  if (!t.tree) {
    let kind: Awaited<ReturnType<typeof folderAt>>
    try {
      kind = await folderAt($, at)
    } catch (err) {
      await failed($, t.path, err)
      return PASS
    }
    if (kind === false) return PASS
    if ('unread' in kind) return { word: t.word, unread: `${t.word} may be a folder whose files it writes, and what it is cannot be read (${kind.unread})`, folder: at }
    at = kind.dir
    // A folder handed only to scripts whose text writes nothing is only read (#2407): every one of them
    // is read, and any one that may write there, or cannot be read, judges the folder as before (#2426
    // lessons review). Each pass is logged, so a reading that lets everything through shows in the log
    // rather than as quiet.
    if (t.runs?.length && (await allOnlyRead($, t.runs))) {
      for (const r of t.runs) await logged($, at, { v: 1, kind: 'script-reads', at: new Date(await $.clock.now()).toISOString(), session: await $.session.id(), agent, word: t.word, script: r.path, decision: 'passed' })
      return PASS
    }
  }
  let under: Awaited<ReturnType<typeof underTree>>
  try {
    under = await underTree($, at, FOLDER_JUDGE_MAX)
  } catch (err) {
    await failed($, t.path, err)
    return PASS
  }
  if ('unread' in under) return { word: t.word, unread: `${t.word} reaches every file under it, and ${under.unread}`, folder: t.path }
  for (const p of under.paths) {
    const w = await gate($, 'Bash', id, p, agent)
    if ('deny' in w) return w
  }
  return PASS
}

// A command's verdict: the first file it writes that is held refuses it. The reader failing lets the
// command through, said; a target whose judging fails is passed, said, and the rest are still judged.
const gateShell = async ($: EngineInterface, id: string, command: string, agent: string | null): Promise<{ deny: string } | typeof PASS> => {
  let cwd = ''
  let targets: ShellTarget[]
  try {
    cwd = await $.session.cwd()
    const home = await homeOf($)
    targets = shellTargets(await $.modkit.writes({ command, cwd, home }), home)
  } catch (err) {
    await failed($, cwd, err, 'shell')
    return PASS
  }
  for (const target of targets) {
    let t: Unread
    if ('path' in target) {
      const r = await gatePath($, id, target, agent)
      if ('deny' in r) return r
      if ('pass' in r) continue
      t = r
    } else t = target
    try {
      const v = await judgeUnread($, id, t, command, agent)
      if ('pass' in v) continue
      await card($, id, holdCard(v.held))
      return { deny: holdRefusal(v.held) }
    } catch (err) {
      await failed($, t.folder ?? cwd, err)
    }
  }
  return PASS
}

// ---- Deciding (decision 7) ----

const GUARD = 'Area check'
const HEADER = 'Area check'

const DECIDE_DESCRIPTION =
  'Decide a first edit or command the area check held, under the held call\'s id: "proceed" with a "reason" saying why the change does not add to the structural problem, "fold" with the "issue" (one of those shown) whose fix is folded into this work, or "restructure" to have Dan decide whether to restructure the file first. Then send the held call again, unchanged.'
const DECIDE_SCHEMA = {
  type: 'object',
  properties: {
    call: { type: 'string', description: 'The held call\'s id, as the hold gave it.' },
    decision: { type: 'string', enum: [...DECISIONS] },
    reason: { type: 'string', description: 'For proceed: why this change does not add to the structural problem, as a sentence.' },
    issue: { type: 'number', description: 'For fold: the issue number whose structural fix is folded in.' },
  },
  required: ['call', 'decision'],
}

// Worded for whoever reads it (#2136): the session or agent whose call was held sends it again
// itself; the main session, recording Dan's answer for a subagent's call, passes it to that agent.
const again = (h: Held, by: string | null) => {
  const held = h.tool === 'Bash' ? 'Bash command' : `${h.tool} to ${h.rel}`
  if (h.agent === null) return `Send the ${held} again, unchanged.`
  if (by === h.agent) return `Send the ${held} again yourself, unchanged.`
  return `The held ${held} was a subagent's: tell that agent, or a new one, to send it again, unchanged.`
}

// A decision taken: the file claimed for whoever was held, the held entry gone, the decision logged.
const release = async ($: EngineInterface, h: Held, decided: { decision: Decision; reason?: string; issue?: number; by?: 'dan' }) => {
  // A write whose file cannot be named is claimed by its command, so only that command runs unjudged.
  await claim($, h.unread ? h.unread.key : keyOf(h.main, h.rel, h.agent))
  await updateHeld($, list => list.filter(x => x.id !== h.id))
  // Version 3 (#1510): the branch and merge base, which the pull request line is matched by (L1010).
  await logged($, `${h.main}/${h.rel}`, {
    v: 3,
    kind: 'decided',
    at: new Date(await $.clock.now()).toISOString(),
    session: await $.session.id(),
    agent: h.agent,
    repo: h.repo,
    branch: h.branch ?? null,
    mergeBase: h.mergeBase ?? null,
    path: h.rel,
    call: h.id,
    ...decided,
  })
}

// A restructure question still waiting on Dan for this held call is settled by any decision.
// Under its own key and the key it had before #2246, since a question asked then may still wait.
const settleQuestion = async ($: EngineInterface, h: Held) => {
  for (const k of [await questionKey(h.repo, h.rel), legacyQuestionKey(h.repo, h.rel)]) {
    if (k === undefined) continue
    const q = (await $.store.get(k)) as Question | undefined
    if (q?.state === 'pending' && q.call === h.id) await $.store.delete(k)
  }
}

// The question about a file: under its own key, or, for an answer given before #2246, the key it had then.
const answeredQuestion = async ($: EngineInterface, repo: string, rel: string): Promise<Question | undefined> => {
  const q = (await $.store.get(await questionKey(repo, rel))) as Question | undefined
  if (q !== undefined) return q
  const old = legacyQuestionKey(repo, rel)
  return old === undefined ? undefined : ((await $.store.get(old)) as Question | undefined)
}

// Scope modes, called in place as the engine needs (skew.ts). Not loaded is home: awake, and away
// from nothing; any other failure is the decision's own failure, said to Claude.
type ScopeModes = {
  isAsleep: () => Promise<boolean>
  sleepNote: (note: { kind: string } & Record<string, unknown>) => Promise<{ isNoted: boolean }>
  hold: (input: { label: string; prompt: string }) => Promise<{ isHeld: false; isAway?: true } | { isHeld: true; card: { guard: string; reason: string; safeWay: string }; deny: string }>
}
const scopeAbsent = (err: unknown) => missingOf(err)?.noun === 'scopeModes'
const isAsleep = async ($: EngineInterface) => {
  try {
    return (await ($ as unknown as { scopeModes: ScopeModes }).scopeModes.isAsleep()) === true
  } catch (err) {
    if (scopeAbsent(err)) return false
    throw err
  }
}
const sleepNote = async ($: EngineInterface, note: { kind: string } & Record<string, unknown>) =>
  (await ($ as unknown as { scopeModes: ScopeModes }).scopeModes.sleepNote(note)).isNoted === true
const holdAway = async ($: EngineInterface, label: string, prompt: string) => {
  try {
    const r = await ($ as unknown as { scopeModes: ScopeModes }).scopeModes.hold({ label, prompt })
    return r?.isHeld === true ? r : null
  } catch (err) {
    if (scopeAbsent(err)) return null
    throw err
  }
}

const asking = (h: Held) => `call AskUserQuestion with one question and metadata {"source": "${ASK_SOURCE}:${h.id}"}; the area check words the question and its answers`

const restructure = async ($: EngineInterface, h: Held, decideId: string) => {
  const k = await questionKey(h.repo, h.rel)
  const pending: Question = { state: 'pending', at: await $.clock.now(), issues: h.shown.map(m => m.n), session: await $.session.id(), call: h.id, agent: h.agent }
  // A subagent never asks Dan (decision 8): the main session is told at its next prompt.
  if (h.agent !== null) {
    await $.store.set(k, pending)
    return { result: `The question is handed to the main session, which asks Dan whether to restructure ${h.rel} first. Stop and report to the main session that ${h.rel} waits on his answer, and do not edit it meanwhile.` }
  }
  if (await isAsleep($)) {
    let noted = true
    for (const note of sleepNotes(h)) noted = (await sleepNote($, note)) && noted
    if (noted) {
      await $.store.set(k, pending)
      return { result: `Dan is asleep, so the question whether to restructure ${h.rel} first is noted for his morning report, and the file stays held. Go on with work that does not edit it.` }
    }
  }
  const away = await holdAway($, `whether to restructure ${h.rel} before this work`, `Ask Dan whether to restructure ${h.rel} first: call ${DECIDE_TOOL} with {"call": "${h.id}", "decision": "restructure"} again.`)
  if (away) {
    await $.store.set(k, pending)
    await card($, decideId, away.card, away.card.guard)
    return { deny: away.deny }
  }
  await $.store.set(k, pending)
  return { result: `Ask Dan now: ${asking(h)}. ${h.rel} stays held until he answers.` }
}

// The questions this session's subagents (or the session itself) left waiting on Dan, each still held.
const waitingLines = async ($: EngineInterface): Promise<string[]> => {
  const session = await $.session.id()
  const lines: string[] = []
  for (const k of await $.store.keys()) {
    if (!k.startsWith('question:')) continue
    const q = (await $.store.get(k)) as Question | undefined
    if (q?.state !== 'pending' || q.session !== session) continue
    const h = await heldOf($, q.call)
    if (!h) continue
    const whose = h.agent === null ? 'this session\'s' : `subagent ${h.agent}'s`
    lines.push(`The area check holds ${whose} ${heldCall(h)}, in ${h.repo}, until Dan decides whether to restructure it first: ${asking(h)}.`)
  }
  return lines
}

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

// ---- The area check line in a pull request (#1510) ----
//
// gh pr create, gh pr edit given a description, and gh pr merge (by itself or through the merge
// helper, --auto included) are refused while the description lacks a line for a file decided on the
// branch they act on, with the lines to paste (prline.ts holds the rules and the words). The log
// and its rotated decision files are read by READ_SCRIPT, once per repository and branch in a Bash
// call (#2143); a log that cannot be read refuses, never reads as no decisions. A check that cannot be made for want of a fact the command does not depend on
// (no checkout, no GitHub repository, GitHub not answering for a merge) lets the command through.

type PrCall = { g: ModKitGh; c: ModKitCommand; folder: string | null; viaHelper: boolean }
type PrVerdict = { deny: string } | { dim: string } | null

const PR_ACTS: readonly string[] = ['create', 'edit', 'merge']
const BODY_TEXT: readonly string[] = ['--body', '-b']
const BODY_FILE: readonly string[] = ['--body-file', '-F']
const HEAD: readonly string[] = ['--head', '-H']

const flagOf = (g: ModKitGh, names: readonly string[]) => [...g.flags].reverse().find(f => names.includes(f.name))

const prCallsIn = async ($: EngineInterface, command: string, cwd: string, home: string): Promise<PrCall[]> => {
  const commands = await $.modkit.pipeline({ command, cwd, home })
  const moves = commands.some(c => ['cd', 'pushd', 'popd'].includes(c.words[0] ?? ''))
  const calls: PrCall[] = []
  for (const c of commands) {
    const helper = await $.modkit.mergeHelper(c)
    const g = helper ?? (await $.modkit.gh({ words: c.words }))
    if (!g || g.unreadable || g.sub !== 'pr' || !PR_ACTS.includes(g.act)) continue
    if (g.act === 'merge' && g.flags.some(f => f.name === '--disable-auto')) continue
    calls.push({ g, c, folder: 'folder' in c ? (c.folder ?? null) : moves ? null : cwd, viaHelper: !!helper })
  }
  return calls
}

// One repository's decision lines in this Mac's log and its rotated files, those naming `branch`
// (none when it is null, for the count alone), with how many name the repository (prline.ts).
const readLog = async ($: EngineInterface, d: Deadline, repo: string, branch: string | null): Promise<LogRead> => {
  const home = await homeOf($)
  if (!home) throw new Error('HOME is not set, so the log cannot be found')
  const ms = await left($, d)
  if (ms <= 0) return { why: LATE }
  const r = await $.process.run(['/bin/sh', '-c', READ_SCRIPT, MOD, `${home}/${DIR}`, repoNeedle(repo), branch === null ? '' : branchNeedle(branch), ...MARKS], { timeoutMs: ms })
  if (r.isStdoutTruncated) return { why: 'its decisions were more than could be read whole' }
  if (r.exitCode !== 0) return { why: firstLine(r.stderr) || `its read exited ${r.exitCode}` }
  return readOf(r.stdout)
}

// The log rotated and any rotated log settled, at session start (prline.ts). Its failure loses
// nothing: the log stays where it was and is read as before.
const ROTATE_MS = 30_000
const rotate = async ($: EngineInterface) => {
  const home = await homeOf($)
  if (!home) throw new Error('HOME is not set, so the log cannot be found')
  const stamp = rotationStamp(await $.clock.now(), await $.session.id())
  const r = await $.process.run(['/bin/sh', '-c', ROTATE_SCRIPT, MOD, `${home}/${DIR}`, stamp, String(ROTATE_BYTES), String(SETTLE_MINUTES), ...MARKS], { timeoutMs: ROTATE_MS })
  if (r.exitCode !== 0) throw new Error(firstLine(r.stderr) || `the rotation exited ${r.exitCode}`)
}

const prNumber = (s: string): string | null => /^#?(\d+)$/.exec(s)?.[1] ?? /\/pull\/(\d+)/.exec(s)?.[1] ?? null

// One pull request as GitHub gives it, as each account gh is logged in to.
const prView = async ($: EngineInterface, d: Deadline, selector: string, repo: string, fields: string): Promise<Record<string, unknown> | { why: string }> => {
  try {
    const r = await askAnyAccount((argv, env) => runIn($, d, argv, env ? { env } : {}), ['pr', 'view', prNumber(selector) ?? selector, '-R', repo, '--json', fields])
    if (!('stdout' in r)) return { why: failureOf(r.failures) }
    const v: unknown = JSON.parse(r.stdout)
    if (typeof v !== 'object' || v === null || typeof (v as Record<string, unknown>).headRefName !== 'string') return { why: 'GitHub gave no branch for it' }
    return v as Record<string, unknown>
  } catch (err) {
    return { why: err instanceof Late ? LATE : msg(err) }
  }
}

// The text a --body gives. A word holding a command substitution keeps only its typed form in the
// words gh reads (`$(cat <<'EOF'\n)`), so its text is the one mod-kit's command reader derives for
// that word (#2141), with the flag the word also spells taken off; a word the reader marks
// unresolved is unknown, never a description without lines (#2166). The word is found as the last
// one ending in the flag's value, either after a flag word or a flag word itself (`--body=`, `-b`).
const bodyText = (c: ModKitCommand, value: string): { body: string } | { unresolved: string } => {
  const typed = value.includes('$(') || value.includes('`')
  for (let i = c.words.length - 1; i > 0; i--) {
    const w = c.words[i] as string
    if (!w.endsWith(value)) continue
    const own = w !== value
    if (own ? !w.startsWith('-') : !(c.words[i - 1] as string).startsWith('-')) continue
    const d = c.derived?.[i] ?? null
    if (d === null) return { body: value }
    if ('unresolved' in d) return { unresolved: d.unresolved }
    const flag = w.slice(0, w.length - value.length)
    return d.text.startsWith(flag) ? { body: d.text.slice(flag.length) } : { unresolved: 'its flag could not be told from its text' }
  }
  return typed ? { unresolved: 'the command reader could not place the word it came from' } : { body: value }
}

// The description a gh pr create or edit gives, or why it cannot be read.
const bodyOf = async ($: EngineInterface, call: PrCall, folder: string, home: string): Promise<{ body: string } | { file: string; why: string } | { unresolved: string }> => {
  const text = flagOf(call.g, BODY_TEXT)
  const file = flagOf(call.g, BODY_FILE)
  const last = [...call.g.flags].reverse().find(f => BODY_TEXT.includes(f.name) || BODY_FILE.includes(f.name))
  if (last === text && text) return text.value === true ? { body: '' } : bodyText(call.c, text.value)
  const name = file?.value === true || file === undefined ? '' : file.value
  if (name === '-') {
    const fed = (call.c.heredocs ?? []).filter(h => (h.fd === undefined || h.fd === 0) && !h.replaced)
    const h = fed[fed.length - 1]
    if (h) return { body: h.body }
    return { file: 'standard input', why: call.c.pipedFrom ? `piped from ${call.c.pipedFrom.join(' ')}` : 'nothing feeds it' }
  }
  const abs = name.startsWith('/') ? name : name.startsWith('~/') ? `${home}/${name.slice(2)}` : `${folder}/${name}`
  try {
    return { body: await $.fs.read(abs) }
  } catch (err) {
    return { file: abs, why: msg(err) }
  }
}

const checkPr = async ($: EngineInterface, d: Deadline, call: PrCall, log: (repo: string, branch: string | null) => Promise<LogRead>): Promise<PrVerdict> => {
  const { g } = call
  const hasBody = g.flags.some(f => BODY_TEXT.includes(f.name) || BODY_FILE.includes(f.name))
  if (g.act === 'edit' && !hasBody) return null
  if (!call.folder) return null
  const b = await $.modkit.branch({ path: call.folder })
  if (!b || 'unreadable' in b) return null
  if (g.named === null) return null
  const remote = await runIn($, d, ['git', '-C', b.root, 'remote', 'get-url', 'origin'])
    .then(r => (r.exitCode === 0 ? r.stdout.trim() || null : null))
    .catch(() => null)
  const own = (await $.modkit.repo({ root: b.main, remote })).github
  const repo = g.named ?? own
  if (!repo) return null
  const verb = call.viaHelper ? 'merge through merge-when-ready.sh' : `gh pr ${g.act}`
  const selector = g.positionals[0]
  // The branch is known here for a create and an edit naming a branch or none; a merge and an edit
  // by number ask GitHub, and only once the log holds a decision in the repository at all.
  const fromGitHub = g.act === 'merge' || (g.act === 'edit' && selector !== undefined && prNumber(selector) !== null)
  let branch: string | null = b.branch
  let github: Record<string, unknown> | null = null
  if (g.act === 'create') {
    const head = flagOf(g, HEAD)
    if (head && head.value !== true) branch = head.value.replace(/^[^:]*:/, '')
  } else if (g.act === 'edit' && selector !== undefined && !fromGitHub) branch = selector
  if (fromGitHub) {
    const count = await log(repo, null)
    if ('why' in count) return { deny: logUnreadableRefusal(verb, count.why) }
    if (count.count === 0) return null
    if (g.act === 'edit') {
      const v = await prView($, d, selector as string, repo, 'headRefName')
      if ('why' in v) return { dim: `The area check could not read the branch of pull request ${selector} (${v.why}), so it let gh pr edit through unchecked.` }
      branch = v.headRefName as string
    } else {
      const v = await prView($, d, selector ?? b.branch ?? '', repo, 'body,headRefName')
      if ('why' in v) return { dim: `The area check could not read pull request ${selector ?? b.branch} on GitHub (${v.why}), so it let the ${verb} through unchecked.` }
      github = v
      branch = v.headRefName as string
    }
  }
  if (!branch) return null
  const read = await log(repo, branch)
  if ('why' in read) return { deny: logUnreadableRefusal(verb, read.why) }
  const here = inRepo(read.decisions, repo)
  if (here.length === 0) return null
  const mergeBase =
    own && repo.toLowerCase() === own.toLowerCase() && b.defaultBranch
      ? await gitIn($, d, b.root, ['merge-base', branch === b.branch ? 'HEAD' : branch, `origin/${b.defaultBranch}`]).then(s => s.trim() || null).catch(() => null)
      : null
  const { files, loose } = onBranch(here, { repo, branch, mergeBase })
  if (files.length === 0) return null
  const r = { verb, branch, loose, malformed: read.malformed }
  if (github) {
    const missing = missingFrom(files, typeof github.body === 'string' ? github.body : '')
    return missing.length ? { deny: missingRefusal({ ...r, files: missing, where: 'github', ...(selector ? { selector } : {}) }) } : null
  }
  if (!hasBody) return { deny: noBodyRefusal({ ...r, files }) }
  const body = await bodyOf($, call, call.folder, await homeOf($))
  if ('unresolved' in body) return { deny: bodyUnresolvedRefusal({ ...r, files }, body.unresolved) }
  if ('why' in body) return { deny: bodyUnreadableRefusal(verb, body.file, body.why) }
  const missing = missingFrom(files, body.body)
  return missing.length ? { deny: missingRefusal({ ...r, files: missing, where: 'command' }) } : null
}

// The ids of subagent calls judged at tool.call and now running, so tool.check does not judge them again.
const fromAgent = new Set<string>()

type AskInput = { questions?: unknown; metadata?: { source?: unknown }; agentId?: string }
type AskResult = { answers?: Record<string, unknown>; questions?: { question?: unknown }[]; afkTimeoutMs?: unknown }

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const r = await next(e)
    // Offered at every start, a headless one included: subagents decide with it too.
    await $.tool.register({ name: 'decide', description: DECIDE_DESCRIPTION, inputSchema: DECIDE_SCHEMA, isDeferred: false })
    later($, e.cwd, async () => {
      await append($, LOG, { v: 1, kind: 'loaded', at: new Date(await $.clock.now()).toISOString(), session: await $.session.id(), cwd: e.cwd, rule: RULE_VERSION })
      // The log rotated once it is over its bound (#2143), its failure kept apart so the rest still runs.
      try {
        await rotate($)
      } catch (err) {
        await failed($, e.cwd, err, 'rotation')
      }
      // Issue lists no edit has read for a week, and answers past their week (#1509).
      const now = await $.clock.now()
      const entries: [string, unknown][] = []
      for (const k of await $.store.keys()) entries.push([k, await $.store.get(k)])
      for (const k of sweepKeys(entries, now)) await $.store.delete(k)
      await warm($)
    })
    return r
  })

  // A subagent's edit, judged where its loop is known, before it runs: held for itself (decision 8).
  // One it lets through is not judged again beneath.
  on('tool.call', async ($, e, next) => {
    if (e.agentId === undefined) return next(e)
    const raw = e as unknown as Record<string, unknown>
    const path = editedPath(e.tool, raw)
    const command = e.tool === 'Bash' && typeof raw.command === 'string' ? raw.command : null
    const id = typeof raw.tool_use_id === 'string' ? raw.tool_use_id : ''
    // A call with no id names nothing a decision could be taken under, so it is passed untouched.
    if ((!path && command === null) || !id) return next(e)
    const v = path ? await gate($, e.tool, id, path, e.agentId) : await gateShell($, id, command as string, e.agentId)
    if ('deny' in v) return v
    fromAgent.add(id)
    try {
      return await next(e)
    } finally {
      fromAgent.delete(id)
    }
  })

  // A pull request command, the main session's or a subagent's (#1510): refused while its
  // description lacks an area check line for a file decided on its branch. Its own failure holds a
  // command that could be one, with why, kept in the error file, as every guard's failure holds its
  // call (#2148, #2173): the check at merge time is no backstop, since a merge is the last check there
  // is, it runs the same code, and only on this Mac. A command whose words hold no gh pr create, edit
  // or merge cannot be one it refuses, so it goes ahead with one dim line, as before. Should the hook
  // fail before its own catch, the registration catch answers the same way through neverThrows.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const command = (e as unknown as Record<string, unknown>).command
    if (typeof command !== 'string' || !/\bgh\b|merge-when-ready/.test(command)) return next(e)
    const cwd = await $.session.cwd()
    // Each repository and branch is read once per Bash call, and the lines any read could not read
    // are said once, together.
    const malformed = new Set<string>()
    try {
      const d: Deadline = { at: (await $.clock.now()) + DEADLINE_MS }
      const reads = new Map<string, Promise<LogRead>>()
      const log = (repo: string, branch: string | null) => {
        const key = `${repo.toLowerCase()}\n${branch ?? ''}`
        let read = reads.get(key)
        if (!read) {
          read = readLog($, d, repo, branch).then(r => {
            if (!('why' in r)) for (const l of r.malformed) malformed.add(l)
            return r
          })
          reads.set(key, read)
        }
        return read
      }
      for (const call of await prCallsIn($, command, cwd, await homeOf($))) {
        const v = await checkPr($, d, call, log)
        if (v && 'deny' in v) return { deny: v.deny }
        if (v) $.ui.log(v.dim)
      }
      if (malformed.size) $.ui.log(malformedDim([...malformed]))
    } catch (err) {
      const why = err instanceof Late ? LATE : msg(err)
      if (mayActOnPr(command)) {
        await keepError($, cwd, why)
        return { deny: checkFailedRefusal(why) }
      }
      await failed($, cwd, new Error(why), 'command')
    }
    return next(e)
  }).catch(($, e, next) => next.called ? next(e) : neverThrows(() => prCaught(e, next.error), () => ({ deny: PR_HELD }), { deny: PR_HELD }))

  // The main session's edit, judged beneath every mod's tool.call hook, after the settings hooks: an
  // edit one of them refuses is refused in its words, and never held, judged or claimed. A query
  // asked with no call id ($.tool.check) runs nothing and is passed untouched.
  on('tool.check', async ($, e, next) => {
    const x = e as unknown as Record<string, unknown>
    const id = typeof x.tool_use_id === 'string' ? x.tool_use_id : ''
    if (!id || x.agentId !== undefined || fromAgent.has(id)) return next(e)
    const input = (e.input ?? {}) as Record<string, unknown>
    const path = editedPath(e.tool, input)
    const command = e.tool === 'Bash' && typeof input.command === 'string' ? input.command : null
    if (!path && command === null) return next(e)
    const decided = await next(e)
    if (decided.decision === 'deny') return decided
    const v = path ? await gate($, e.tool, id, path, null) : await gateShell($, id, command as string, null)
    return 'deny' in v ? { decision: 'deny', reason: v.deny } : decided
  })

  // The decision, under the held call's id, by the session or agent it was held for. Answered here
  // and never passed down, so the guards beneath are asked through mod-kit's screen first (#707).
  on('tool.call', { tool: DECIDE_TOOL }, async ($, e) => {
    const refused = await $.modkit.screen(e)
    if (refused) return refused
    const { tool: _t, tool_use_id: decideId, agentId, consent: _c, ...input } = e as unknown as Record<string, unknown>
    const agent = typeof agentId === 'string' ? agentId : null
    const call = String(input.call ?? '')
    const h = await heldOf($, call)
    // Only a held call, and only its own: no file can be cleared ahead of its edit.
    if (!h || h.agent !== agent) return { deny: `No edit of yours is held under ${call}: it was decided already, or never held. Send the edit, and if it is held you are told how to decide.` }
    const problem = decideProblem(input, h)
    if (problem !== undefined) return { deny: problem }
    if (input.decision === 'restructure') return restructure($, h, String(decideId ?? ''))
    await settleQuestion($, h)
    if (input.decision === 'fold') {
      await release($, h, { decision: 'fold', issue: input.issue as number })
      return { result: `Recorded: the structural fix for #${String(input.issue)} is folded into this work. ${again(h, agent)}` }
    }
    await release($, h, { decision: 'proceed', reason: input.reason as string })
    return { result: `Recorded: this work goes ahead on ${h.rel}. ${again(h, agent)}` }
  }).catch(($, e, next) => neverThrows(() => undecided(msg(next.error)), () => HELD, HELD))

  // Dan's restructure question, asked in Claude Code's own dialog: the hook words the question and
  // its answers, and reads his choice from the dialog's own result, the one place it comes from him.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const ask = e as unknown as AskInput
    const source = ask.metadata?.source
    if (typeof source !== 'string' || !source.startsWith(`${ASK_SOURCE}:`)) return next(e)
    if (e.agentId !== undefined) return { deny: 'Only the main session asks Dan about restructuring. Stop and report to the main session that this waits on him.' }
    const id = source.slice(ASK_SOURCE.length + 1)
    const h = await heldOf($, id)
    if (!h) return { deny: `No edit is held under ${id}: it was decided already, or the session ended. Send the edit again, and if it is held you are told how to decide.` }
    const q = restructureQuestion(h)
    const r = await next({ ...e, questions: [{ question: q.question, header: HEADER, options: q.options, multiSelect: false }] } as typeof e)
    if (r.deny !== undefined || r.isError) return r
    const say = (text: string) => ({ ...r, context: [...(r.context ?? []), text] })
    const out = (r.result ?? {}) as AskResult
    if (out.afkTimeoutMs !== undefined) return say(`Dan did not answer: the dialog closed by itself while he was away, so nothing is recorded and ${h.rel} stays held. Ask him again when he is back.`)
    const shown = typeof out.questions?.[0]?.question === 'string' ? (out.questions[0].question as string) : q.question
    const chosen = out.answers?.[shown] ?? out.answers?.[q.question]
    if (typeof chosen !== 'string' || !chosen.trim()) return say(`Dan gave no answer, so nothing is recorded and ${h.rel} stays held. Ask him again, or leave it.`)
    if (!q.options.some(o => o.label === chosen)) {
      const parts = { still: `${h.rel} stays held`, again: `ask him again: ${asking(h)}` }
      try {
        return say(await $.modkit.typedAnswer({ guard: GUARD, typed: chosen, ...parts }))
      } catch (err) {
        return say(`Dan typed "${chosen}" instead of choosing, so nothing is recorded, and ${parts.still}; mod-kit could not tell him so (${msg(err)}). Tell him that in one line, answer what he said, then ${parts.again}.`)
      }
    }
    const k = await questionKey(h.repo, h.rel)
    // A question asked before #2246 waits under its old key: Dan has now answered it.
    await settleQuestion($, h)
    if (chosen === 'Fold in') {
      await $.store.delete(k)
      const who = h.agent === null ? 'Call' : `Tell subagent ${h.agent} to call`
      return say(`Dan chose Fold in. ${who} ${DECIDE_TOOL} with {"call": "${h.id}", "decision": "fold", "issue": <one of ${h.shown.map(m => `#${m.n}`).join(', ')}>} to record it. ${again(h, null)}`)
    }
    await $.store.set(k, { state: 'answered', answer: chosen, at: await $.clock.now(), issues: h.shown.map(m => m.n) } satisfies Question)
    if (chosen === 'Restructure first') {
      await release($, h, { decision: 'restructure', by: 'dan' })
      return say(`Dan chose Restructure first: do the structural fix on ${h.rel} before this work; the file is released for it. ${again(h, null)}`)
    }
    await release($, h, { decision: 'proceed', by: 'dan' })
    return say(`Dan chose Proceed anyway: this work goes ahead on ${h.rel}. ${again(h, null)}`)
  })

  // The questions waiting on Dan, said beside each prompt of the main session until he answers.
  on('prompt.submit', async ($, e, next) => {
    const r = await next(e)
    if (r.drop !== undefined) return r
    try {
      const lines = await waitingLines($)
      return lines.length ? { ...r, context: [...(r.context ?? []), ...lines] } : r
    } catch (err) {
      $.ui.log(`${MOD}: the questions waiting on Dan could not be read (${msg(err)})`, { to: 'debug' })
      return r
    }
  })
}
