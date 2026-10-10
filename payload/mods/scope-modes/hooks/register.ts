import type { EngineInterface, Register } from 'claude-code'
import type { ScopeModes, ScopeModesHeld, ScopeModesLeftAsIs, ScopeModesOpened, ScopeModesPlace, ScopeModesScope, ScopeModesTarget } from '../types/index.d.ts'
import { heldCard, heldRefusal, heldTool, needsTheMac } from './away.ts'
import { ghWords, helperWords, noBuildRefusal, type Cmd } from './nobuild.ts'
import {
  addAnswer,
  closedSentence,
  isListed,
  judgeNight,
  listedRepos,
  HOLD_MERGES,
  markerText,
  MAY_DEPLOY,
  MERGE_NO_DEPLOY,
  readMarker,
  repoQuestion,
  type Marker,
  needsOf,
  dirsOf,
  type Place,
  nightRepos,
  QUESTION_MS,
  readRepoLists,
  REPO_LIST_FILE,
  repoListPath,
  scriptsOf,
  type ClosedRepo,
  type NightRepos,
  type Scripts,
} from './mergedeploy.ts'
import { NEVER_ASKED, overnightRefusal, primaryFrom, repoFromRemotes, type GithubOf, type Look } from './overnight.ts'
import { wakeCheck } from './wakecheck.ts'
import {
  answerKey,
  askOptions,
  askText,
  BEDTIME_HEADER,
  decisionComment,
  GO_TO_SLEEP,
  groupQuestions,
  orderQuestions,
  priorityRank,
  questionsIn,
  SKIP_QUESTION,
  unansweredText,
  type IssueQuestion,
  type OpenQuestion,
} from './bedtime.ts'
import {
  LIMITS, RESUME, activeMs, blockTold, decideFailure, decideStop, driverPath, freshDriver, heldClaim, overnightRules, progressOf, readDriver, releaseTold, resumeDue, thenNext,
  type ClaimReading, type DriverReading, type DriverRecord, type Note, type Release,
} from './driver.ts'
import { overnightData } from './overnightdata.ts'
import { bootOf, bootSessionOf, etDate, etWhen, isDaytimeEt, nightOf, notesOf, readSleep, sleepDir, untilOf, type Boot, type SleepReading, type SleepRecord } from './sleep.ts'
import { awakeAsk, BBEDIT, morningPrompt, openers, openLater, proposalsIn, SUMMARY_ASK, summariesSaid } from './wake.ts'
import { isDans, scopesAskedOffIn, triggersIn, type Trigger } from './triggers.ts'
import { choiceFor, isLeftClosed, newWork, outstanding, settledByDan, type DeployState, type Reading } from './winddown.ts'

// Scope modes (#616) and away and home (#621), one mod because they share one state: the status
// bar holds ONE list of modes for the band's amber line (no build or winding down, and away, can be
// on at once), and both are switched by Dan's own words read off the same prompt and both judge the
// same Bash calls. Settled with Dan on 2026-10-04 (docs/mods-design.md): the mode leads the amber
// line in the band in bold; coming home is a boxed card in the band; a message from the phone while
// home gets one line at the end of Claude's reply.
//
// Every mode lives in $.state, which a new session starts without: a new session is at home with no
// scope mode, and session.end (exit or /clear) turns them all off, so nothing carries over. Sleep mode
// (#840) is the one exception: it is the whole Mac's, kept in one record on disk (hooks/sleep.ts),
// read afresh at every decision and never held in $.state.

const MOD = 'scope-modes'
const MIN = 60_000
const RUN_MS = 20_000
// The report at the end of a night reads GitHub for each repo worked (each gh call bounded at 15 s and all of them at 60 s
// in the script), so it gets longer than an ordinary run.
const REPORT_FINAL_MS = 90_000
const BOOT_MS = 5_000
const AWAY_TEXT = 'Dan switched every session on this Mac to away.'
const HOME_TEXT = 'Dan switched every session on this Mac to home.'
const PHONE_LINE = "You're on your phone. Reply away to switch every session."
const SCOPE_NAME: Record<ScopeModesScope, string> = { 'NO BUILD': 'No build', 'WINDING DOWN': 'Winding down' }

const scopeRef = { plugin: 'scope-modes', key: 'scope' } as const
const placeRef = { plugin: 'scope-modes', key: 'place' } as const
const heldRef = { plugin: 'scope-modes', key: 'held' } as const
const heldSeqRef = { plugin: 'scope-modes', key: 'heldSeq' } as const
const targetRef = { plugin: 'scope-modes', key: 'target' } as const
const justHomeRef = { plugin: 'scope-modes', key: 'justHome' } as const
const openedRef = { plugin: 'scope-modes', key: 'opened' } as const
const leftOpenRef = { plugin: 'scope-modes', key: 'leftOpen' } as const

// Where the last prompt came from, so the turn it started knows whether Dan wrote it on his phone.
let lastOrigin: string | undefined
let ticking = false
let statusNoted = false
// One finish check at a time: the turn end and the minute's tick share whichever is running.
let checking: Promise<Checked | null> | undefined
// What the finish check found: what is still to do, and the PRs settled by being left as they are
// on Dan's own choice, open (#917) or closed (#1033), said apart from what is outstanding.
type Checked = { left: string[]; kept: ScopeModesLeftAsIs[] }

const msg = (err: unknown) => String((err as Error)?.message ?? err)

const scopeOf = async ($: EngineInterface) => (await $.state.get(scopeRef)).value ?? null
const placeOf = async ($: EngineInterface): Promise<ScopeModesPlace> => (await $.state.get(placeRef)).value ?? 'home'
const heldOf = async ($: EngineInterface) => (await $.state.get(heldRef)).value ?? []

// ---- Sleep mode (#840): the machine wide record ----

// This boot: its start and its session. A session's process lives inside one boot, so once read
// neither is read again (unlike the record, which is read every time): the session cannot change
// within a boot, and the start, which a clock correction moves by seconds, is only ever judged within
// readSleep's tolerance. A failed read is not kept, and is tried again.
let bootTime: number | undefined
let bootSession: string | undefined
const BOOT_OIDS = ['kern.boottime', 'kern.bootsessionuuid'] as const
type BootOid = (typeof BOOT_OIDS)[number]
const bootUnread = (): BootOid[] => BOOT_OIDS.filter(o => (o === 'kern.boottime' ? bootTime : bootSession) === undefined)
const bootNow = (): Boot => ({ time: bootTime ?? null, session: bootSession ?? null })
// Keeps what `sysctl -n <oid>` answered for this boot; a failed read keeps nothing and says why.
const keepBoot = (oid: BootOid, r: { exitCode: number; stdout: string; stderr: string }): string | undefined => {
  if (oid === 'kern.boottime') {
    const b = r.exitCode === 0 ? bootOf(r.stdout) : null
    if (b !== null) bootTime = b
  } else {
    const s = r.exitCode === 0 ? bootSessionOf(r.stdout) : null
    if (s !== null) bootSession = s
  }
  if ((oid === 'kern.boottime' ? bootTime : bootSession) !== undefined) return undefined
  return r.stderr.trim() || `sysctl answered ${JSON.stringify(r.stdout.trim().slice(0, 80))}`
}
// Whether this session has a person at its prompt, from its start: a -p or detached run never works overnight.
let interactive = false
// The last state the band was given, so the minute's tick redraws it only when sleep began or ended.
let shownAsleep: boolean | undefined
// The night this session last asked Dan whether he is up (#837), by its generation: once a night.
let askedUp: string | undefined

const sleepPaths = async ($: EngineInterface) => {
  const home = await $.env.get('HOME')
  if (!home) throw new Error('HOME is not set')
  const dir = sleepDir(home)
  return { home, dir, current: `${dir}/current.json`, ended: `${dir}/ended`, notes: `${dir}/notes`, preparing: `${dir}/preparing` }
}

// This boot, each half read until it answers; `timeWhy` says why the start could not be read.
const thisBoot = async ($: EngineInterface): Promise<{ boot: Boot; timeWhy?: string }> => {
  let timeWhy: string | undefined
  for (const oid of bootUnread()) {
    const why = keepBoot(oid, await run($, ['sysctl', '-n', oid]))
    if (oid === 'kern.boottime') timeWhy = why
  }
  return { boot: bootNow(), ...(timeWhy ? { timeWhy } : {}) }
}

// The one predicate, read live (L83, L175): the record as it stands on disk now, asked of readSleep.
// A failure to read is a reading of its own, never "no record" (L215), and reads as awake.
const sleepNow = async ($: EngineInterface): Promise<SleepReading> => {
  try {
    const p = await sleepPaths($)
    if (!(await $.fs.exists(p.current))) return { state: 'none' }
    let text: string
    try {
      text = await $.fs.read(p.current)
    } catch (err) {
      // Moved aside between the look and the read (a wake elsewhere) is no record, not a broken one.
      if (!(await $.fs.exists(p.current))) return { state: 'none' }
      return { state: 'unreadable', why: `the sleep record could not be read (${msg(err)})` }
    }
    return readSleep(text, await $.clock.now(), (await thisBoot($)).boot)
  } catch (err) {
    return { state: 'unreadable', why: `the sleep record could not be read (${msg(err)})` }
  }
}
const isAsleep = async ($: EngineInterface) => (await sleepNow($)).state === 'asleep'

// Moves the record aside: the one step that ends a sleep, so of two sessions ending it at once
// exactly one move succeeds and only that one acts (assume it runs twice). `gone` is the other
// having won; anything else is a failure, said, with the record left where it was.
type Moved = { to: string; text: string | null } | { gone: true } | { error: string }
const moveAside = async ($: EngineInterface, label: 'woke' | 'limit'): Promise<Moved> => {
  const p = await sleepPaths($)
  await run($, ['mkdir', '-p', p.ended])
  const to = `${p.ended}/${await $.clock.now()}-${label}-${await $.session.id()}.json`
  const mv = await run($, ['mv', p.current, to])
  if (mv.exitCode !== 0) return /No such file/i.test(mv.stderr) ? { gone: true } : { error: mv.stderr.trim() || `mv exited ${mv.exitCode}` }
  const text = await $.fs.read(to).catch(() => null)
  return { to, text }
}

// The command appending one note through the one writer (#835), shared by this mod's own notes and
// the noun's (#841), which runs it through its own engine handle, since the engine refuses handing
// that handle to a helper. `record` is the record the note belongs to: current while asleep, or
// the one just moved aside at the end of a night.
const noteArgv = (home: string, record: string, note: Record<string, unknown>) => [
  'python3',
  `${home}/.claude/hooks/lib/sleep-report.py`,
  'note',
  '--record',
  record,
  '--line',
  JSON.stringify(note),
]
const noteFailure = (r: { exitCode: number; stderr: string }) => r.stderr.trim() || `the note could not be written (exit ${r.exitCode})`
// The night's report (#835) and the notes it is built from are written by one script,
// hooks/lib/sleep-report.py, which every other writer reaches through sleep_note in
// hooks/lib/sleep.sh. The mod hands it the record it means (current, or the one just moved aside),
// so a note written after the record has moved still lands in that night's notes.
const report = async ($: EngineInterface, args: string[], timeoutMs = RUN_MS): Promise<string | null> => {
  const p = await sleepPaths($)
  const r = await run($, ['python3', `${p.home}/.claude/hooks/lib/sleep-report.py`, ...args], timeoutMs)
  return r.exitCode === 0 ? null : r.stderr.trim() || `the report script exited ${r.exitCode}`
}

// One line appended to the night's notes, then the report rendered again best effort.
const sleepNote = async ($: EngineInterface, record: string, note: Record<string, unknown>) => {
  const p = await sleepPaths($)
  const r = await run($, noteArgv(p.home, record, note))
  if (r.exitCode !== 0) throw new Error(noteFailure(r))
}

// At the end of a night (wake or its limit): what this session reads of its own usage, then the
// report once more, with done read from GitHub. Each failure is said, never swallowed.
const finishReport = async ($: EngineInterface, record: string, ending: Record<string, unknown>): Promise<string[]> => {
  const problems: string[] = []
  let usage: Record<string, unknown> | undefined
  try {
    const u = await $.session.usage()
    usage = { ...(u.cost ? { costUsd: u.cost.usd } : {}), rateLimits: u.rateLimits.map(r => ({ kind: r.kind, percentUsed: r.percentUsed, ...(r.resetsAt ? { resetsAt: r.resetsAt } : {}) })) }
  } catch (err) {
    problems.push(`this session's usage could not be read (${msg(err)})`)
  }
  try {
    await sleepNote($, record, { ...ending, at: await $.clock.now(), by: await $.session.id(), ...(usage ? { usage } : {}) })
  } catch (err) {
    problems.push(`the note could not be written (${msg(err)})`)
  }
  try {
    const failed = await report($, ['render', '--record', record, '--final'], REPORT_FINAL_MS)
    if (failed) problems.push(`the report could not be finished (${failed})`)
  } catch (err) {
    problems.push(`the report could not be finished (${msg(err)})`)
  }
  return problems
}

// A question for Dan while he is asleep (#841): never asked, noted for his morning report. Answers
// null once noted, or why it could not be.
const noteQuestion = async ($: EngineInterface, questions: string[]): Promise<string | null> => {
  try {
    await sleepNote($, (await sleepPaths($)).current, { kind: 'question', at: await $.clock.now(), by: await $.session.id(), cwd: await $.session.cwd(), questions })
    return null
  } catch (err) {
    return msg(err)
  }
}
const ASLEEP_SKIP = 'Leave whatever needs his answer as it is, say in your final message what is waiting on him, and carry on with work that does not need him.'
const askedAsleep = (failed: string | null) =>
  `Not asked: Dan is asleep (sleep mode), so no question reaches him tonight. ${
    failed === null ? 'The question is noted for his morning report.' : `It could not be noted for his morning report (${failed}), so put the question in your final message.`
  } ${ASLEEP_SKIP}`
// ---- Sleep mode phase 7 (#843): the night's merge and deploy lists (decided in overnight.ts) ----

const readText = async ($: EngineInterface, path: string): Promise<string | null | { error: string }> => {
  try {
    if (!(await $.fs.exists(path))) return null
    return await $.fs.read(path)
  } catch (err) {
    return { error: msg(err) }
  }
}
const readLists = async ($: EngineInterface, path: string) => {
  const t = await readText($, path)
  if (t !== null && typeof t === 'object') return { why: `${REPO_LIST_FILE} could not be read (${t.error})` }
  return readRepoLists(t)
}

type GhRun = { exitCode: number; stdout: string; stderr: string }
const notFoundOnGitHub = (r: { stderr: string }) => /Could not resolve to a Repository/i.test(r.stderr)
const ghSaid = (r: { stderr: string; exitCode: number }) => r.stderr.trim().split('\n')[0] || `gh exited ${r.exitCode}`

// One gh call as each account gh is logged in to, until one answers: Dan's work repositories are
// visible only to his work account. The active account first, then each other's token, scoped to
// the call (never gh auth switch, which other sessions share) and never printed. `tryNext` says
// which failures are worth asking the next account about; a write passes only GitHub's own not
// found, so a write that may have landed is never sent again as another account (assume it runs twice).
const ghAnyAccount = async ($: EngineInterface, args: string[], tryNext: (r: GhRun) => boolean = () => true): Promise<{ stdout: string } | { failures: GhRun[] }> => {
  const first = await run($, ['gh', ...args])
  if (first.exitCode === 0) return { stdout: first.stdout }
  const failures: GhRun[] = [first]
  if (!tryNext(first)) return { failures }
  const status = await run($, ['gh', 'auth', 'status'])
  for (const a of new Set([...`${status.stdout}\n${status.stderr}`.matchAll(/account (\S+)/g)].map(m => m[1] as string))) {
    const tok = await run($, ['gh', 'auth', 'token', '-u', a])
    if (tok.exitCode !== 0 || !tok.stdout.trim()) continue
    const r = await run($, ['gh', ...args], RUN_MS, { GH_TOKEN: tok.stdout.trim() })
    if (r.exitCode === 0) return { stdout: r.stdout }
    failures.push(r)
    if (!tryNext(r)) break
  }
  return { failures }
}

// Whether GitHub knows a repository under any account gh is logged in to.
const resolves = async ($: EngineInterface, repo: string): Promise<string | null> => {
  const r = await ghAnyAccount($, ['repo', 'view', repo, '--json', 'nameWithOwner'])
  if ('stdout' in r) return null
  // Only gh's own not found answer says GitHub does not know it; anything else (no network, a rate
  // limit, a token gh could not use) is a check that could not be made, said as such (L11).
  const other = r.failures.find(f => !notFoundOnGitHub(f))
  if (other) return `${repo} could not be checked with GitHub (${ghSaid(other)})`
  return `GitHub does not know ${repo} under any account gh is logged in to (${ghSaid(r.failures[0] as GhRun)})`
}

// A marker file (the preparing marker, the answers lock), placed whole: written beside itself
// with its owner, time and nonce, then linked into place, so of two at once exactly one is placed
// and a reader never sees half of one. A marker whose owner is no open session, or older than
// `staleMs`, is taken over by moving it aside in one rename (only one mover wins) and linking ours,
// never removed and made again. Each outcome is its own answer, so each is said as itself (L11).
type Claim =
  | { claimed: Marker; tookOver?: Marker }
  | { held: Marker }
  | { unreadable: string }
  | { failed: string }
const readMarkerAt = async ($: EngineInterface, path: string): Promise<Marker | { unreadable: string } | null> => {
  const t = await readText($, path)
  if (t === null) return null
  if (typeof t === 'object') return { unreadable: t.error }
  return readMarker(t)
}
const ownerGone = async ($: EngineInterface, m: Marker, now: number, staleMs: number): Promise<boolean> => {
  if (now - m.at > staleMs) return true
  try {
    const list = await $.sessions.list()
    // A registry that cannot read every record may be missing the owner: never read as gone (L215).
    if (list.unreadable.length) return false
    return !list.open.some(o => o.sessionId === m.owner)
  } catch {
    return false
  }
}
const claimMarker = async ($: EngineInterface, path: string, staleMs: number): Promise<Claim> => {
  const mine: Marker = { owner: await $.session.id(), at: await $.clock.now(), nonce: Math.random().toString(36).slice(2, 10) }
  const tmp = `${path}.${mine.nonce}.tmp`
  try {
    await $.fs.write(tmp, markerText(mine))
  } catch (err) {
    return { failed: msg(err) }
  }
  let tookOver: Marker | undefined
  try {
    for (let attempt = 0; attempt < 3; attempt++) {
      const ln = await run($, ['ln', tmp, path])
      if (ln.exitCode === 0) return { claimed: mine, ...(tookOver ? { tookOver } : {}) }
      if (!/File exists/i.test(ln.stderr)) return { failed: ln.stderr.trim() || `ln exited ${ln.exitCode}` }
      const held = await readMarkerAt($, path)
      if (held === null) continue
      if ('unreadable' in held) return held
      if (!(await ownerGone($, held, mine.at, staleMs))) return { held }
      const aside = `${path}.taken-${mine.nonce}`
      const mv = await run($, ['mv', path, aside])
      if (mv.exitCode !== 0) {
        if (/No such file/i.test(mv.stderr)) continue
        return { failed: mv.stderr.trim() || `mv exited ${mv.exitCode}` }
      }
      // What was moved must be the marker judged stale; one placed meanwhile is put back.
      const moved = await readMarkerAt($, aside)
      if (moved && !('unreadable' in moved) && moved.nonce !== held.nonce) {
        await run($, ['mv', '-n', aside, path])
        return { held: moved }
      }
      await run($, ['rm', '-f', aside])
      tookOver = held
    }
    return { failed: `${path} kept changing while it was taken` }
  } finally {
    await run($, ['rm', '-f', tmp])
  }
}
// Removes a marker only while it is still this claim's own.
const releaseMarker = async ($: EngineInterface, path: string, mine: Marker) => {
  const now = await readMarkerAt($, path)
  if (now && !('unreadable' in now) && now.nonce === mine.nonce) await run($, ['rm', '-f', path])
}

// How long a writer of the answers waits on another before giving up, and when a lock is stale.
const LOCK_WAIT_MS = 30_000
const LOCK_STALE_MS = 10 * MIN

// A bedtime answer written into the shared file under the answers lock, so a late answer and
// another never read the same file and write over each other; whole beside it and moved into place,
// so a reader never sees half a file. The sync carries it to the other Mac, so each repository is
// asked once.
const recordAnswer = async ($: EngineInterface, path: string, repo: string, answer: string): Promise<string | null> => {
  const lock = `${sleepDir((await $.env.get('HOME')) ?? '')}/repos.lock`
  await run($, ['mkdir', '-p', sleepDir((await $.env.get('HOME')) ?? '')])
  const waitUntil = (await $.clock.now()) + LOCK_WAIT_MS
  let claim: Claim
  for (;;) {
    claim = await claimMarker($, lock, LOCK_STALE_MS)
    if (!('held' in claim) || (await $.clock.now()) >= waitUntil) break
    await $.clock.sleep(1_000)
  }
  if ('held' in claim) return `the lists are being written by session ${claim.held.owner} (since ${etWhen(claim.held.at)})`
  if ('unreadable' in claim) return `the answers lock cannot be read (${claim.unreadable})`
  if ('failed' in claim) return `the answers lock could not be taken (${claim.failed})`
  try {
    const t = await readText($, path)
    if (t !== null && typeof t === 'object') return `${REPO_LIST_FILE} could not be read (${t.error})`
    const added = addAnswer(t, repo, answer)
    if ('why' in added) return added.why
    // Written in the sleep folder, which nothing syncs, and moved over: a half written or left over
    // copy never sits in mods/, which the sync mirrors both ways. Both are under ~/.claude, one disk.
    const tmp = `${sleepDir((await $.env.get('HOME')) ?? '')}/.sleep-repos-${claim.claimed.nonce}.tmp`
    try {
      await $.fs.write(tmp, added.text)
    } catch (err) {
      return `it could not be written (${msg(err)})`
    }
    const mv = await run($, ['mv', tmp, path])
    if (mv.exitCode === 0) return null
    await run($, ['rm', '-f', tmp])
    return `it could not be put in place (${mv.stderr.trim() || `mv exited ${mv.exitCode}`})`
  } finally {
    await releaseMarker($, lock, claim.claimed)
  }
}

// The before bed round (#843, #836): every question at /sleep, the repositories' and the issues',
// shares one QUESTION_MS from the first, so /sleep never waits on Dan longer than that in all; and
// once Dan picks "Go to sleep now" on any of them, nothing more is asked.
type Round = { until: number; slept: boolean }

// One bedtime question, waiting `waitMs`, what is left of the round. An answer given after the
// wait is handed to `late`, for the nights after this one; tonight it counts as unanswered.
type Asked = { answer: string } | { unanswered: true } | { failed: string }
const askOne = async ($: EngineInterface, question: string, options: string[], header: string, waitMs: number, late: (a: string) => Promise<void>): Promise<Asked> => {
  let isLate = false
  const asking: Promise<Asked> = $.ui.ask(question, { options, header }).then(
    async (a: string) => {
      if (isLate && a !== GO_TO_SLEEP) await late(a).catch(err => $.ui.toast(`A late answer to "${question}" was not kept: ${msg(err)}`))
      return { answer: a }
    },
    // Dismissed, or the dialog could not be shown: never read as a question left unanswered (L11).
    (err: unknown) => ({ failed: msg(err) }),
  )
  const first = await Promise.race([asking, $.clock.sleep(waitMs).then((): Asked => ({ unanswered: true }))])
  if ('unanswered' in first) isLate = true
  return first
}

// The question about a repository on neither list. A late answer still goes into the shared file;
// one that cannot be saved is never dropped (L11): it is noted for the morning report as a question
// still to answer, and said in the session when even that fails.
const askRepo = ($: EngineInterface, repo: string, path: string, waitMs: number) =>
  askOne($, repoQuestion(repo), [MERGE_NO_DEPLOY, HOLD_MERGES, MAY_DEPLOY, GO_TO_SLEEP], 'Overnight', waitMs, async a => {
    const failed = await recordAnswer($, path, repo, a).catch(err => msg(err))
    if (!failed) return
    const question = `Your answer about ${repo} ("${a}") was not saved: ${failed}. Choose again at the next /sleep.`
    try {
      await sleepNote($, (await sleepPaths($)).current, { kind: 'question', at: await $.clock.now(), by: await $.session.id(), repo, questions: [question] })
    } catch (err) {
      $.ui.toast(`${question} It could not be noted for the morning report either (${msg(err)}).`)
    }
  })

// One remote's GitHub repository, read by mod-kit's one reader (#951): every folder's remotes here
// and the session's own origin are read by it, never by a pattern of this mod's.
const githubOf = ($: EngineInterface): GithubOf => async remote => (await $.modkit.repo({ remote })).github

// The one GitHub repository a folder's remotes name, lower case (repoFromRemotes): null for none,
// more than one, or a folder git cannot read; `unread` when mod-kit's reader fails, kept apart so a
// caller that must not drop a folder can say so (#979 review).
const folderRepoRead = async ($: EngineInterface, dir: string): Promise<{ repo: string | null } | { unread: string }> => {
  const r = await run($, ['git', '-C', dir, 'remote', '-v'])
  if (r.exitCode !== 0) return { repo: null }
  try {
    return { repo: await repoFromRemotes(r.stdout, githubOf($)) }
  } catch (err) {
    return { unread: `the GitHub repository of ${dir} could not be read (${msg(err)})` }
  }
}
// The same for the callers that take any reading they cannot use as untold: the overnight rules
// refuse a write whose repository cannot be resolved, and no build leaves the folder's untold.
const folderRepo = async ($: EngineInterface, dir: string): Promise<string | null> => {
  const f = await folderRepoRead($, dir)
  return 'repo' in f ? f.repo : null
}

// The repositories the overnight workers are in, from each one's folder. A folder mod-kit's reader
// cannot read is never dropped, which would leave its repository unasked at bedtime: it is said.
const workerRepos = async ($: EngineInterface, roots: string[]): Promise<string[] | { unread: string }> => {
  const out = new Map<string, string>()
  for (const root of roots) {
    const f = await folderRepoRead($, root)
    if ('unread' in f) return f
    const slug = f.repo
    if (slug && !out.has(slug.toLowerCase())) out.set(slug.toLowerCase(), slug)
  }
  return [...out.values()]
}

// The night's lists for the sleep record, settled at bedtime: the shared file as read, a question
// for each worker's repository on neither list when there is someone to ask, and every entry
// checked with GitHub. Whatever has no answer is closed for the night (L42).
const settleNight = async ($: EngineInterface, home: string, repos: string[], round: Round): Promise<NightRepos> => {
  const path = repoListPath(home)
  let read = await readLists($, path)
  const closed: ClosedRepo[] = []
  for (const repo of repos) {
    if (!('lists' in read)) break
    if (isListed(read.lists, repo)) continue
    if (!interactive) {
      closed.push({ repo, why: `${repo} is on neither list in ${REPO_LIST_FILE}, and nobody was at this session to ask` })
      continue
    }
    if (round.slept) {
      closed.push({ repo, why: `${repo} was not asked: Dan chose to go to sleep first` })
      continue
    }
    const left = round.until - (await $.clock.now())
    if (left <= 0) {
      closed.push({ repo, why: `${repo} was not asked: the 10 minutes for bedtime questions ran out` })
      continue
    }
    const asked = await askRepo($, repo, path, left)
    if ('unanswered' in asked) {
      closed.push({ repo, why: `the question about ${repo} was not answered in 10 minutes` })
      continue
    }
    if ('failed' in asked) {
      closed.push({ repo, why: `the question about ${repo} was dismissed or could not be asked (${asked.failed})` })
      continue
    }
    if (asked.answer === GO_TO_SLEEP) {
      round.slept = true
      closed.push({ repo, why: `Dan chose to go to sleep before answering about ${repo}` })
      continue
    }
    const failed = await recordAnswer($, path, repo, asked.answer)
    if (failed) {
      closed.push({ repo, why: `the answer about ${repo} was not saved: ${failed}` })
      continue
    }
    read = await readLists($, path)
  }
  if ('lists' in read)
    for (const repo of listedRepos(read.lists)) {
      if (closed.some(c => c.repo.toLowerCase() === repo.toLowerCase())) continue
      const why = await resolves($, repo)
      if (why) closed.push({ repo, why })
    }
  return nightRepos(read, closed)
}

// ---- Sleep mode phase 6 (#836): the before bed questions about the queue's issues ----
// Which questions, in what order, and what is posted are bedtime.ts's; here they are read, asked,
// posted and written down.

type Left = { repo: string; issue: number; text: string }
type IssueRound = {
  /** Every issue whose question went unanswered tonight, for sleep-queue.sh to leave out. */
  left: Left[]
  /** Notes for the morning report, written once the record is in place. */
  notes: Record<string, unknown>[]
  /** What /sleep says about them; empty when there were none. */
  said: string
}

// Where an issue's answered question is recorded: one file per repository, issue and words, so a
// question is never asked again once its answer is on the issue.
const answeredPath = (dir: string, repo: string, issue: number, text: string) => `${dir}/answered/${answerKey(repo, issue, text)}.json`

const andList = (xs: string[]) => (xs.length <= 1 ? xs.join('') : `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`)
const plural = (n: number, one: string) => `${n} ${one}${n === 1 ? '' : 's'}`

// A file written whole beside its place and moved over it, so a reader never sees half of it.
const writeWhole = async ($: EngineInterface, path: string, text: string): Promise<string | null> => {
  const dir = path.slice(0, path.lastIndexOf('/'))
  const mk = await run($, ['mkdir', '-p', dir])
  if (mk.exitCode !== 0) return mk.stderr.trim() || `mkdir exited ${mk.exitCode}`
  const tmp = `${dir}/.${path.slice(dir.length + 1)}.${Math.random().toString(36).slice(2, 10)}.tmp`
  try {
    await $.fs.write(tmp, text)
  } catch (err) {
    return msg(err)
  }
  const mv = await run($, ['mv', tmp, path])
  if (mv.exitCode === 0) return null
  await run($, ['rm', '-f', tmp])
  return mv.stderr.trim() || `mv exited ${mv.exitCode}`
}

// The answer posted on one issue as Dan's dated decision, then recorded as answered. Null when it
// is on the issue; else why not. A record that cannot be kept after the post is said apart, since
// the decision is on the issue and only a second asking follows.
const postAnswer = async ($: EngineInterface, dir: string, repo: string, issue: number, text: string, answer: string): Promise<{ posted: true; unkept?: string } | { failed: string }> => {
  const body = decisionComment(text, answer, etDate(await $.clock.now()))
  const r = await ghAnyAccount($, ['issue', 'comment', String(issue), '--repo', repo, '--body', body], notFoundOnGitHub)
  if (!('stdout' in r)) return { failed: ghSaid(r.failures.find(f => !notFoundOnGitHub(f)) ?? (r.failures[0] as GhRun)) }
  const kept = await writeWhole($, answeredPath(dir, repo, issue, text), `${JSON.stringify({ repo, issue, text, answer, at: await $.clock.now(), comment: r.stdout.trim() })}\n`)
  return kept ? { posted: true, unkept: kept } : { posted: true }
}

// The questions earlier nights noted about the workers' repositories, still open: not yet answered
// on their issue, and their issue not closed. Each failure to read is said, never read as no
// questions (L215).
const openQuestions = async ($: EngineInterface, dir: string, repos: string[]): Promise<{ questions: OpenQuestion[]; rank: Map<string, number>; problems: string[] }> => {
  const problems: string[] = []
  const notesDir = `${dir}/notes`
  const ls = await run($, ['ls', '-1', notesDir])
  if (ls.exitCode !== 0) {
    if (/No such file/i.test(ls.stderr)) return { questions: [], rank: new Map(), problems }
    return { questions: [], rank: new Map(), problems: [`Questions from earlier nights could not be read (${ls.stderr.trim() || `ls exited ${ls.exitCode}`}), so none were asked.`] }
  }
  const wanted = new Set(repos.map(r => r.toLowerCase()))
  const found: IssueQuestion[] = []
  let bad = 0
  const unread: string[] = []
  for (const name of ls.stdout.split('\n').filter(n => n.endsWith('.jsonl'))) {
    let text: string
    try {
      text = await $.fs.read(`${notesDir}/${name}`)
    } catch (err) {
      unread.push(`${name} (${msg(err)})`)
      continue
    }
    const r = questionsIn(text)
    bad += r.bad
    found.push(...r.questions.filter(q => wanted.has(q.repo.toLowerCase())))
  }
  if (unread.length) problems.push(`Earlier notes could not be read (${unread.join('; ')}), so a question in them may not have been asked.`)
  if (bad) problems.push(`${plural(bad, 'line')} of earlier notes could not be read, so a question in ${bad === 1 ? 'it' : 'them'} may not have been asked.`)
  const open: IssueQuestion[] = []
  for (const q of found) if (!(await $.fs.exists(answeredPath(dir, q.repo, q.issue, q.text)))) open.push(q)
  // Each issue read once: a closed one is no longer in any queue. One that cannot be read is still
  // asked about, ranked last, since dropping its question would hide it (L215).
  const rank = new Map<string, number>()
  const closed = new Set<string>()
  for (const k of new Set(open.map(q => `${q.repo.toLowerCase()}#${q.issue}`))) {
    const q = open.find(x => `${x.repo.toLowerCase()}#${x.issue}` === k) as IssueQuestion
    const r = await ghAnyAccount($, ['issue', 'view', String(q.issue), '--repo', q.repo, '--json', 'state,labels'])
    if (!('stdout' in r)) {
      rank.set(k, 5)
      continue
    }
    try {
      const j = JSON.parse(r.stdout) as { state?: unknown; labels?: unknown }
      if (String(j.state).toUpperCase() === 'CLOSED') closed.add(k)
      rank.set(k, priorityRank(j.labels))
    } catch {
      rank.set(k, 5)
    }
  }
  const questions = groupQuestions(open.filter(q => !closed.has(`${q.repo.toLowerCase()}#${q.issue}`)))
  return { questions, rank, problems }
}

// The before bed questions about the queue's issues, after the repositories' (decided in #836: a
// repository's answer is kept for every night and covers all its issues, while an issue's covers
// one), sharing their round. Every issue a question was left on goes into the night's unanswered
// list; each answer is posted on its issue as Dan's dated decision.
const askIssues = async ($: EngineInterface, dir: string, repos: string[], round: Round): Promise<IssueRound> => {
  const { questions, rank, problems } = await openQuestions($, dir, repos)
  const ordered = orderQuestions(questions, (repo, n) => rank.get(`${repo.toLowerCase()}#${n}`) ?? 5)
  const left: Left[] = []
  const notes: Record<string, unknown>[] = []
  const posted: string[] = []
  let answered = 0
  const dismissed: string[] = []
  const unposted: string[] = []
  const leave = (q: OpenQuestion, issues = q.issues) => left.push(...issues.map(issue => ({ repo: q.repo, issue, text: q.text })))
  for (const q of ordered) {
    const waitMs = round.until - (await $.clock.now())
    if (!interactive || round.slept || waitMs <= 0) {
      leave(q)
      continue
    }
    const asked = await askOne($, askText(q), askOptions(q), BEDTIME_HEADER, waitMs, async a => {
      // Answered after the wait: posted for the nights after; tonight its issues stay out.
      if (a === SKIP_QUESTION) return
      for (const issue of q.issues) {
        const p = await postAnswer($, dir, q.repo, issue, q.text, a)
        if ('failed' in p) $.ui.toast(`Your late answer on ${q.repo}#${issue} ("${a}") could not be posted (${p.failed}); it is asked again next time.`)
      }
    })
    if ('unanswered' in asked || ('answer' in asked && asked.answer === SKIP_QUESTION)) {
      leave(q)
      continue
    }
    if ('failed' in asked) {
      dismissed.push(`The question on ${q.repo}#${q.issues.join(' and #')} was dismissed or could not be shown (${asked.failed}).`)
      leave(q)
      continue
    }
    if (asked.answer === GO_TO_SLEEP) {
      round.slept = true
      leave(q)
      continue
    }
    let landed = false
    for (const issue of q.issues) {
      const p = await postAnswer($, dir, q.repo, issue, q.text, asked.answer)
      if ('failed' in p) {
        const why = `Your answer on ${q.repo}#${issue} ("${asked.answer}") could not be posted (${p.failed}), so the issue is skipped tonight and the question is asked again next time.`
        unposted.push(why)
        notes.push({ kind: 'finding', repo: q.repo, issue, text: why })
        leave(q, [issue])
        continue
      }
      posted.push(`${q.repo}#${issue}`)
      landed = true
      if (p.unkept) unposted.push(`Your answer on ${q.repo}#${issue} is posted, but the record that it was could not be kept (${p.unkept}), so it may be asked again.`)
    }
    if (landed) answered++
  }
  // The questions left are noted for the morning report as the same words, so they are asked again.
  for (const l of left) notes.push({ kind: 'question', repo: l.repo, issue: l.issue, text: l.text })
  const skipped = [...new Set(left.map(l => `${l.repo}#${l.issue}`))]
  const leftQuestions = new Set(left.map(l => `${l.repo.toLowerCase()}\n${l.text}`)).size
  let said = ''
  if (answered) said += ` Before bed: ${plural(answered, 'question')} answered and posted on ${andList([...new Set(posted)])}.`
  if (skipped.length) said += ` ${plural(leftQuestions, 'question')} left for the morning, so tonight the queue skips ${andList(skipped)}.`
  for (const s of [...dismissed, ...unposted, ...problems]) said += ` ${s}`
  return { left, notes, said }
}

// What a Bash call would merge, deploy or push to a default branch tonight that the night's lists
// refuse, with the branch and package scripts read only when the call needs them.
const mergeDeployRefusal = async ($: EngineInterface, night: unknown, commands: Cmd[]) => {
  // A call with nothing to refuse even judged at its strictest (no folder, branch or scripts known)
  // is most calls, and needs nothing read.
  // A push or a gh call is never let through on that pass: which branch is the default is only
  // known once the folder is read (`develop` is neither main nor master).
  if (!needsOf(commands).branch && !judgeNight(night, commands, commands.map(() => null))) return undefined
  const needs = needsOf(commands)
  const dirs = dirsOf(commands, await $.session.cwd(), (await $.env.get('HOME')) ?? '')
  // What each folder a command runs in says: its origin, branches and package scripts, read once.
  const read = new Map<string, Place>()
  const placeAt = async (dir: string): Promise<Place> => {
    const known = read.get(dir)
    if (known) return known
    // The folder's repository as phase 3 reads it (repoFromRemotes): none, or more than one, is untold.
    const own = (await folderRepo($, dir)) ?? undefined
    let defaultBranch: Place['defaultBranch'] = null
    let currentBranch: string | null = null
    if (needs.branch) {
      // Read by mod-kit's one reader of where a checkout stands (#980). A folder in no checkout has
      // neither branch. One whose branch it cannot give (a detached head among them) gives no
      // default either, so that is said rather than taken as main or master (L42).
      const b = await $.modkit.branch({ path: dir }).catch((err: unknown) => ({ unreadable: msg(err) }))
      if (b && 'unreadable' in b) defaultBranch = { unreadable: b.unreadable }
      else if (b) {
        defaultBranch = b.defaultBranch
        currentBranch = b.branch
      }
    }
    let scripts: Scripts = null
    if (needs.scripts) {
      const t = await readText($, `${dir.replace(/\/+$/, '')}/package.json`)
      const bodies = t !== null && typeof t === 'object' ? { unreadable: t.error } : scriptsOf(t)
      if (bodies === null || 'unreadable' in bodies) scripts = bodies as Scripts
      else {
        // Each body read by mod-kit's one reader, as a command line is (L613).
        const parsed: Record<string, Cmd[]> = {}
        for (const [k, body] of Object.entries(bodies)) parsed[k] = await readCommands($, body as string)
        scripts = parsed
      }
    }
    const place: Place = { defaultBranch, currentBranch, scripts, own }
    read.set(dir, place)
    return place
  }
  const places: (Place | null)[] = []
  for (const d of dirs) places.push(d === null ? null : await placeAt(d))
  return judgeNight(night, commands, places)
}

// A repository closed for the night, as the report's question for Dan (#835 renders questions):
// which list it belongs on, and why tonight it neither merges nor deploys. Without a repository
// (the lists file could not be read) the question is about the file itself.
const closedNote = (repo: string | undefined, why: string, at: number, by: string) => ({
  kind: 'question',
  at,
  by,
  ...(repo ? { repo } : {}),
  questions: [repo ? `${repoQuestion(repo)} Tonight it neither merges nor deploys: ${why}.` : `Merging and deploying were off for every repository tonight: ${why}. Fix ${REPO_LIST_FILE}.`],
})

// A repository first met after sleep began (on neither list, never asked at bedtime) is noted once a
// night per session, so the morning report asks which list it belongs on (#843).
const firstMet = new Set<string>()
const noteFirstMet = async ($: EngineInterface, record: SleepRecord, over: { repo?: string; why: string }) => {
  if (!over.repo || !over.why.startsWith(`${over.repo} is on neither list`)) return
  const k = `${record.generation}:${over.repo.toLowerCase()}`
  if (firstMet.has(k)) return
  firstMet.add(k)
  try {
    await sleepNote($, (await sleepPaths($)).current, closedNote(over.repo, over.why, await $.clock.now(), await $.session.id()))
  } catch (err) {
    firstMet.delete(k)
    $.ui.toast(`Sleep mode could not note that ${over.repo} is on neither list: ${msg(err)}`)
  }
}

const notify = async ($: EngineInterface, message: string): Promise<string | null> => {
  const r = await run($, ['terminal-notifier', '-title', 'Sleep mode', '-message', message])
  return r.exitCode === 0 ? null : r.stderr.trim() || `terminal-notifier exited ${r.exitCode}`
}

const parseRecord = (text: string | null): SleepRecord | null => {
  try {
    const j = JSON.parse(text ?? '') as SleepRecord
    return j && typeof j === 'object' ? j : null
  } catch {
    return null
  }
}

// The wake check (#834): what really happened since sleep began, read from GitHub and the disk,
// each hit and each read that failed written to the night's notes (`outward` and `unmeasured`, which
// the report puts at its top), and said in one sentence for the wake reply or the notification.
// Empty when the night was quiet and every read was made.
const overnightCheck = async ($: EngineInterface, record: SleepRecord | null, recordPath: string): Promise<string> => {
  if (!record || typeof record.since !== 'number') return ''
  const home = (await $.env.get('HOME')) ?? ''
  // Every repository the night's notes name is read, so a private one the events feed leaves out
  // is still checked (#834 review). No notes file is no repositories; one that cannot be read is said.
  const repos: string[] = []
  const unread: string[] = []
  if (typeof record.generation === 'string') {
    const notes = notesOf(home, record.generation)
    try {
      if (await $.fs.exists(notes))
        for (const line of (await $.fs.read(notes)).split('\n')) {
          try {
            const repo = (JSON.parse(line) as { repo?: unknown }).repo
            if (typeof repo === 'string' && /^[\w.-]+\/[\w.-]+$/.test(repo)) repos.push(repo)
          } catch {
            // A line that is not JSON names no repository; the report says it could not read it.
          }
        }
    } catch (err) {
      unread.push(`the repositories the night's notes name were not read (${msg(err)})`)
    }
  }
  let found
  try {
    found = await wakeCheck((argv, timeoutMs) => run($, argv, timeoutMs), { since: record.since, home, repos, github: githubOf($) })
  } catch (err) {
    found = { hits: [], unmeasured: [`the overnight check failed (${msg(err)})`] }
  }
  found.unmeasured.unshift(...unread)
  const at = await $.clock.now()
  const by = await $.session.id()
  try {
    for (const text of found.hits) await sleepNote($, recordPath, { kind: 'outward', at, by, text })
    for (const text of found.unmeasured) await sleepNote($, recordPath, { kind: 'unmeasured', at, by, text })
  } catch (err) {
    $.ui.toast(`The overnight check could not write its notes: ${msg(err)}`)
  }
  const parts: string[] = []
  if (found.hits.length) parts.push(`The overnight check found ${found.hits.length === 1 ? 'one thing' : `${found.hits.length} things`} to look at: ${found.hits.join('; ')}.`)
  if (found.unmeasured.length) parts.push(`Not checked: ${found.unmeasured.join('; ')}.`)
  return parts.join(' ')
}

// What the overnight rules ask of the disk (#834): the one GitHub repository a folder's remotes
// name, and whether a folder is a primary checkout. A read that fails is null, which refuses.
const lookOf = ($: EngineInterface): Look => ({
  repoOf: dir => folderRepo($, dir),
  isPrimary: async dir => {
    const r = await run($, ['git', '-C', dir, 'rev-parse', '--path-format=absolute', '--git-dir', '--git-common-dir'])
    return r.exitCode === 0 ? primaryFrom(r.stdout) : null
  },
})

// Why a call is on Dan's overnight list (#834), from the call as a tool call or a permission
// request carries it, or undefined when it is not.
const overnightWhy = async ($: EngineInterface, tool: string, input: Record<string, unknown>): Promise<string | undefined> => {
  const raw = tool === 'Bash' ? String(input.command ?? '') : ''
  const cwd = await $.session.cwd()
  const home = (await $.env.get('HOME')) ?? ''
  // GH_REPO as gh reads it, through mod-kit's one reader (#961); a reader that fails is a repository
  // that cannot be read, which refuses every write naming none itself (L42).
  const spelling = (await $.env.get('GH_REPO')) || undefined
  const ghRepo = spelling === undefined ? undefined : await $.modkit.ghRepo({ spelling }).catch(() => null)
  return overnightRefusal(
    { tool, input, raw, commands: raw ? await readCommands($, raw) : [], writes: raw ? await readWrites($, raw) : NO_WRITES, cwd, home, ...(ghRepo !== undefined ? { ghRepo } : {}) },
    lookOf($),
  )
}
const overnightDeny = (what: string) =>
  `Refused: sleep mode is on and Dan bans this while he sleeps, so this did not ${what}. Do not look for another way to do it; it waits for the morning. Carry on with work that does not need it, or skip this issue.`

// Puts every session back where Dan was before sleep (#840: wake restores placeBefore).
const restorePlace = async ($: EngineInterface, record: SleepRecord | null): Promise<string | null> => {
  const place = record?.placeBefore
  if (place !== 'home' && place !== 'away') return null
  await setPlace($, place)
  return placeSentence(place, await tellOthers($, place))
}

// A record past its noon or from another boot no longer holds (L523). The first session to see it
// moves it aside, notes why and notifies Dan once; one that loses the move does nothing. A record
// that is no longer the one judged (a new sleep began meanwhile) is put back, never ended.
const endIfOver = async ($: EngineInterface, reading: SleepReading) => {
  if (reading.state !== 'expired' && reading.state !== 'other-boot') return
  const reason = reading.state === 'expired' ? 'it was past noon ET' : 'the Mac restarted'
  const moved = await moveAside($, 'limit')
  if ('gone' in moved) return
  if ('error' in moved) {
    $.ui.toast(`Sleep mode is over (${reason}), but its record could not be moved aside: ${moved.error}`)
    return
  }
  const record = parseRecord(moved.text)
  if (record?.generation !== reading.record.generation) {
    const p = await sleepPaths($)
    await run($, ['mv', '-n', moved.to, p.current])
    return
  }
  await releaseAwake($, (await sleepPaths($)).dir)
  const now = await $.clock.now()
  // Every session is put back first: the overnight check reads GitHub, which may be slow (#834 review).
  await restorePlace($, record)
  await showModes($)
  await showHeld($)
  // The overnight check's notes go in before the report is finished, so they are at its top (#834).
  const checked = await overnightCheck($, record, moved.to)
  const problems = await finishReport($, moved.to, { kind: 'limit', reason })
  if (problems.length) $.ui.toast(`Sleep mode ended by itself (${reason}), but ${problems.join('; ')}.`)
  const failed = await notify($, `Sleep mode ended by itself at ${etWhen(now)}: ${reason}.${checked ? ` ${checked}` : ''}`)
  if (failed) $.ui.toast(`Sleep mode ended by itself (${reason}), but the notification could not be sent: ${failed}`)
}

// Enrols the sessions that work overnight: this one, and every other open session that said at its
// start it has a person at its prompt. A -p or detached run, or a session that has not said (its
// scope modes is older, or it has not started a turn yet), is not enrolled, and is counted.
// Each worker's repository folder comes back too (`roots`), for the night's merge and deploy lists (#843).
const enrol = async ($: EngineInterface, self: string): Promise<{ workers: string[]; roots: string[]; others: number; left: number; unknown?: string }> => {
  const workers = interactive ? [self] : []
  const roots: string[] = []
  let list
  try {
    list = await $.sessions.list()
  } catch (err) {
    return { workers, roots, others: 0, left: 0, unknown: `the session registry could not be read (${msg(err)})` }
  }
  let left = 0
  for (const o of list.open) {
    if (o.sessionId === self) continue
    const said = (o.extra?.[MOD] as { isInteractive?: unknown } | undefined)?.isInteractive
    if (said === true) {
      workers.push(o.sessionId)
      if (o.repoRoot) roots.push(o.repoRoot)
    } else left++
  }
  const unknown = list.unreadable.length ? `the session registry could not read ${list.unreadable.join(', ')}` : undefined
  return { workers, roots, others: workers.filter(w => w !== self).length, left, ...(unknown ? { unknown } : {}) }
}

// Tells the session registry whether this session has a person at its prompt, for enrolment.
const announce = async ($: EngineInterface) => {
  try {
    await $.sessions.setExtra({ key: MOD, value: { isInteractive: interactive } })
  } catch (err) {
    $.ui.log(`scope-modes: could not tell the session registry whether this session is interactive: ${msg(err)}`, { to: 'debug' })
  }
}
let announced = false

// How old a preparing marker may be before it is taken as left by a session that died: a chosen
// limit, well past the before bed questions' ten minutes each.
const PREPARING_STALE_MS = 2 * 60 * MIN

const startedWhere = (r: SleepRecord) => `it started at ${etWhen(r.since)} in ${r.startedBy?.cwd ?? 'a session that left no folder'}, and ends at ${etWhen(r.until)}`

// /sleep (#840). The record, its workers, the night's merge and deploy lists (#843) and the before
// bed questions on the queue's issues (#836) here: paging (phase 2, #841) and the overnight driver
// (phase 8, #844) build on this record.
const startSleep = async ($: EngineInterface): Promise<string> => {
  // This boot first: without it no record can be judged, and one that is sound must never be
  // called broken for it (L11), nor a new one written that could not be told from an old boot's.
  // The session is kept beside the start when it can be read; without it the record is judged by
  // its start alone, within readSleep's tolerance.
  const b = await thisBoot($)
  const startedBoot = b.boot.time
  if (startedBoot === null) return `Sleep mode did not start: this boot's start could not be read (${b.timeWhy ?? 'sysctl gave no reason'}).`
  let reading = await sleepNow($)
  if (reading.state === 'asleep') return `Sleep mode is already on: ${startedWhere(reading.record)}. Nothing changed.`
  if (reading.state === 'unreadable') {
    const p = await sleepPaths($).catch(() => null)
    if (p && (await $.fs.exists(p.current))) return `A sleep record is already there but cannot be read (${reading.why}). Nothing changed; /wake clears it.`
  }
  if (reading.state === 'expired' || reading.state === 'other-boot') {
    await endIfOver($, reading)
    reading = await sleepNow($)
    if (reading.state === 'asleep') return `Sleep mode is already on: ${startedWhere(reading.record)}. Nothing changed.`
  }
  const p = await sleepPaths($)
  // On battery a night of work drains the Mac, so sleep does not start; unknown power is said, never guessed (#844).
  const power = await powerRefusal($)
  if (power) return `Sleep mode did not start: ${power}.`
  const now = await $.clock.now()
  const self = await $.session.id()
  const night = nightOf(now)
  // The before bed questions hold a preparing marker while they ask, so a second /sleep waits on
  // them: placed whole with its owner and time, and a marker left by a session that died (its owner
  // gone from the registry, or older than PREPARING_STALE_MS, L523) is taken over in one rename.
  // /wake clears any.
  await run($, ['mkdir', '-p', p.dir])
  const claim = await claimMarker($, p.preparing, PREPARING_STALE_MS)
  if ('held' in claim) return `Sleep mode is already being prepared in session ${claim.held.owner} since ${etWhen(claim.held.at)}. Nothing changed; if that session has gone, /wake clears it.`
  if ('unreadable' in claim) return `A preparing marker is there but cannot be read (${claim.unreadable}). Nothing changed; /wake clears it.`
  if ('failed' in claim) return `Sleep mode did not start: its preparing marker could not be written (${claim.failed}).`
  const tookOver = claim.tookOver ? ` A sleep left half prepared by session ${claim.tookOver.owner} since ${etWhen(claim.tookOver.at)} was taken over.` : ''
  // Another /sleep may have placed its record between the read above and this claim: read it again,
  // so the bedtime questions are never asked for a night that has already begun.
  const again = await sleepNow($)
  if (again.state === 'asleep') {
    await releaseMarker($, p.preparing, claim.claimed)
    return `Sleep mode is already on: ${startedWhere(again.record)}. Nothing changed.`
  }
  // Everything from here until the record is in place is under the marker, so a second /sleep never
  // asks the questions again in between, and it is released however this ends.
  let e: Awaited<ReturnType<typeof enrol>>
  let repos: NightRepos
  let issues: IssueRound
  let startedIn: string
  let placeBefore: ScopeModesPlace
  const generation = `${now}-${self}`
  try {
    e = await enrol($, self)
    // This session's own checkout, found by mod-kit's walk from its folder, as the session registry
    // gives every other worker's (rev-parse --show-toplevel from its folder). Never
    // $.session.repo().root, which is the project's main working tree even from a linked worktree
    // (measured on Claude Code 2.1.295, #996). In no checkout there is no repository to ask about; a
    // walk that fails is said, never read as none, which would leave this repository unasked.
    let ownRoot: string | undefined
    try {
      ownRoot = e.workers.includes(self) ? ((await $.modkit.workingTree({ path: await $.session.cwd() })) ?? undefined) : undefined
    } catch (err) {
      await releaseMarker($, p.preparing, claim.claimed)
      return `Sleep mode did not start: this session's checkout could not be read (${msg(err)}).`
    }
    const worked = await workerRepos($, [...(ownRoot ? [ownRoot] : []), ...e.roots])
    if (!Array.isArray(worked)) {
      await releaseMarker($, p.preparing, claim.claimed)
      return `Sleep mode did not start: ${worked.unread}.`
    }
    // The before bed questions, one round of QUESTION_MS for them all. The repositories' first
    // (#843): an answer there is kept for every night after and covers every issue in it, while an
    // issue's answer covers one issue. Then the open questions on the queue's issues (#836).
    const round: Round = { until: (await $.clock.now()) + QUESTION_MS, slept: false }
    // The night's merge and deploy lists (#843), settled before the record exists: the shared file,
    // a question for each worker's repository on neither list, every entry checked with GitHub.
    repos = await settleNight($, p.home, worked, round)
    issues = await askIssues($, p.dir, worked, round)
    // Read before the list is written, so nothing between the list and the record can throw and
    // leave a list for a night that never began.
    startedIn = await $.session.cwd()
    placeBefore = await placeOf($)
    // The issues whose question went unanswered, in the list sleep-queue.sh leaves out of tonight's
    // queue, in place before the record: a worker never reads a queue without it. Unwritten, sleep
    // does not start, since the queue would then work issues still waiting on Dan (L42).
    const unlisted = await writeWhole($, `${p.dir}/unanswered/${generation}`, unansweredText(issues.left))
    if (unlisted) {
      await releaseMarker($, p.preparing, claim.claimed)
      return `Sleep mode did not start: the list of issues whose before bed question went unanswered could not be written (${unlisted}).`
    }
  } catch (err) {
    await releaseMarker($, p.preparing, claim.claimed)
    throw err
  }
  const record: SleepRecord = {
    v: 1,
    generation,
    since: now,
    until: untilOf(night),
    night,
    bootTime: startedBoot,
    ...(b.boot.session !== null ? { bootSession: b.boot.session } : {}),
    // Named as Dan asked (decision 4, 2026-10-06): "Sleep report <night>.md", the night's ET date.
    report: `${p.home}/Downloads/Sleep report ${night}.md`,
    startedBy: { sessionId: self, cwd: startedIn },
    workers: e.workers,
    placeBefore,
    repos,
  }
  // Written whole beside it, read back, then linked into place: a link fails when a record is
  // already there, so of two /sleep at once exactly one record is placed and never half of one.
  // Its own name per attempt, so two attempts in one millisecond never share it, nor one's cleanup the other's file.
  const tmp = `${p.dir}/.current-${record.generation}-${Math.random().toString(36).slice(2, 10)}.tmp`
  const text = JSON.stringify(record)
  // This night's unanswered list (#836) is only for a record that is placed; one that is not
  // leaves nothing behind, unless the record there is this very night's.
  let placed = false
  try {
    await run($, ['mkdir', '-p', p.dir])
    await $.fs.write(tmp, text)
    if ((await $.fs.read(tmp)) !== text) return 'Sleep mode did not start: the record did not read back as written.'
    const ln = await run($, ['ln', tmp, p.current])
    if (ln.exitCode !== 0) {
      const there = await sleepNow($)
      if (there.state === 'asleep') {
        placed = there.record.generation === generation
        return `Sleep mode is already on: ${startedWhere(there.record)}. Nothing changed.`
      }
      return `Sleep mode did not start: the record could not be put in place (${ln.stderr.trim() || `ln exited ${ln.exitCode}`}).`
    }
    placed = true
  } catch (err) {
    return `Sleep mode did not start: ${msg(err)}.`
  } finally {
    await run($, ['rm', '-f', tmp])
    if (!placed) await run($, ['rm', '-f', `${p.dir}/unanswered/${generation}`])
    await releaseMarker($, p.preparing, claim.claimed)
  }
  await showModes($)
  await showHeld($)
  // Each repository closed for the night is noted, so the morning report lists it with the question
  // still to answer (#843); a note that cannot be written is said.
  const closedAll = [...repos.closed, ...(repos.listWhy ? [{ repo: undefined, why: repos.listWhy }] : [])]
  const noteFailed: string[] = []
  for (const c of closedAll) {
    try {
      await sleepNote($, p.current, closedNote(c.repo, c.why, now, self))
    } catch (err) {
      noteFailed.push(msg(err))
    }
  }
  let unnoted = noteFailed.length
    ? ` The morning report may miss ${noteFailed.length} of these ${closedAll.length}: ${[...new Set(noteFailed)].join('; ')}.`
    : ''
  // The before bed questions left, and answers that could not be posted, for the morning report (#836).
  const issueNoteFailed: string[] = []
  for (const n of issues.notes) {
    try {
      await sleepNote($, p.current, { ...n, at: now, by: self })
    } catch (err) {
      issueNoteFailed.push(msg(err))
    }
  }
  if (issueNoteFailed.length)
    unnoted += ` The morning report may miss ${issueNoteFailed.length} of the ${issues.notes.length} notes about before bed questions: ${[...new Set(issueNoteFailed)].join('; ')}.`
  const awake = await holdAwake($, p.dir, record.until, now)
  const others = e.others ? ` and ${e.others} other${e.others === 1 ? '' : 's'}` : ''
  const enrolled = e.workers.includes(self) ? `this session${others}` : e.others ? `${e.others} other session${e.others === 1 ? '' : 's'}` : 'no session'
  let s = `Sleep mode is on until ${etWhen(record.until)}. Enrolled to work overnight: ${enrolled}.`
  if (e.left) s += ` Not enrolled: ${e.left} session${e.left === 1 ? '' : 's'} that ${e.left === 1 ? 'is' : 'are'} not interactive or ${e.left === 1 ? 'has' : 'have'} not said.`
  if (e.unknown) s += ` Other sessions may be missing: ${e.unknown}.`
  s += closedSentence(repos) + issues.said + unnoted + tookOver
  // The report exists from the first minute, header first, so a night that ends badly still has one (#835, L10).
  const started = await report($, ['start', '--record', p.current, '--by', self])
  s += started ? ` The night's report could not be started: ${started}.` : ` The night's report is at ${record.report}.`
  if (awake) s += ` The Mac may sleep tonight: ${awake}.`
  return s
}

// Phase 9 (#837): the night's report opened on the Mac, by the one session that woke it, once the
// final render is done. Away, or woken from the phone, nothing opens on the Mac: it waits in the held
// card. Said in the same reply as the wake, so Dan reads that focus moved.
const openReport = async ($: EngineInterface, path: string, fromPhone: boolean): Promise<string> => {
  if (fromPhone || (await placeOf($)) === 'away') {
    const later = openLater(path)
    await hold($, later.label, later.prompt)
    await showHeld($)
    return fromPhone
      ? 'You woke it from your phone, so it was not opened on the Mac: opening it waits in the held card for when you are at the Mac.'
      : 'You are away, so it was not opened on the Mac: opening it waits in the held card for when you are back.'
  }
  let there: boolean
  try {
    there = await $.fs.exists(path)
  } catch (err) {
    return `It was not opened: whether it is there could not be read (${msg(err)}).`
  }
  // The helper opens a missing file as a new empty window and says it worked, so a report that is not there is said instead.
  if (!there) return 'It was not opened: there is no file there.'
  const why: string[] = []
  for (const argv of openers(path)) {
    const r = await run($, argv)
    if (r.exitCode === 0) return 'Focus moved to BBEdit, where it is open.'
    why.push(`${argv[0] === BBEDIT ? 'bbedit_tool' : 'open -a BBEdit'}: ${r.stderr.trim() || `exit ${r.exitCode}`}`)
  }
  return `It could not be opened in BBEdit (${why.join('; ')}).`
}

// Phase 9 (#837): each other session that worked overnight is asked for its own summary. One that
// has closed since is said, never counted as asked, and one the registry could not read is not
// called closed (L215).
const askSummaries = async ($: EngineInterface, record: SleepRecord | null, self: string): Promise<string> => {
  const others = (Array.isArray(record?.workers) ? record.workers : []).filter((w): w is string => typeof w === 'string' && w !== self)
  if (!others.length) return ''
  const told = { asked: 0, failed: [] as string[], closed: 0 }
  // The record is already moved aside: anything that throws here is said in the reply, never
  // allowed to take the wake's reply with it (lessons review of 7de29c2).
  try {
    const list = await $.sessions.list()
    const open = new Set(list.open.map(o => o.sessionId))
    for (const id of others) {
      if (!open.has(id)) {
        if (list.unreadable.length) told.failed.push(`whether it is still open is not known (the session registry could not read ${list.unreadable.join(', ')})`)
        else told.closed++
        continue
      }
      // mod-kit tries a refused send once more, so a refusal here is the second.
      const sent = await $.session.send({ to: { sessionId: id }, text: SUMMARY_ASK })
      if (sent.isDelivered) told.asked++
      else told.failed.push(sent.reason)
    }
  } catch (err) {
    return summariesSaid({ ...told, unknown: msg(err) })
  }
  return summariesSaid(told)
}

// Phase 9 (#837): what the waking session is asked to do, from the night's notes: its own summary,
// then the proposed issues and lessons in the pickers that already exist. A read that fails is said
// in the prompt, never read as a night with nothing proposed (L215).
const morningFor = async ($: EngineInterface, record: SleepRecord | null, self: string): Promise<string> => {
  const worker = Array.isArray(record?.workers) && record.workers.includes(self)
  if (typeof record?.generation !== 'string') return morningPrompt({ worker, issues: [], lessons: [], unread: 'the sleep record names no generation' })
  try {
    const path = notesOf((await sleepPaths($)).home, record.generation)
    if (!(await $.fs.exists(path))) return morningPrompt({ worker, issues: [], lessons: [] })
    return morningPrompt({ worker, ...proposalsIn(await $.fs.read(path)) })
  } catch (err) {
    return morningPrompt({ worker, issues: [], lessons: [], unread: msg(err) })
  }
}

// /wake and "I'm up" (#840): the record is moved aside, and only the session whose move succeeds
// acts. Phase 9 (#837): that session alone opens the report, asks the other workers for their
// summaries, and comes back with the morning prompt (its summary and the pickers) for its caller to
// start: a turn of its own after /wake, the turn already starting after "I'm up".
type Woke = { said: string; morning: string | null }
const wake = async ($: EngineInterface, fromPhone = false): Promise<Woke | null> => {
  const said = (s: string): Woke => ({ said: s, morning: null })
  const reading = await sleepNow($)
  if (reading.state === 'none') {
    // A preparing marker with no sleep behind it is one a session left when it died mid question.
    const p = await sleepPaths($)
    if (!(await $.fs.exists(p.preparing))) return null
    const rm = await run($, ['rm', '-f', p.preparing])
    return said(rm.exitCode === 0 ? 'Sleep mode was not on. A sleep left half prepared was cleared, so /sleep can start again.' : `Sleep mode was not on, and a sleep left half prepared could not be cleared (${rm.stderr.trim() || `rm exited ${rm.exitCode}`}).`)
  }
  // Read before the record moves, so a read that fails leaves sleep exactly as it was.
  const self = await $.session.id()
  const moved = await moveAside($, 'woke')
  if ('gone' in moved) return said('Sleep mode was already woken by another session.')
  if ('error' in moved) return said(`Sleep mode could not be turned off (${moved.error}). It is still on.`)
  const record = parseRecord(moved.text)
  await releaseAwake($, (await sleepPaths($)).dir)
  await showModes($)
  await showHeld($)
  if (reading.state === 'unreadable') return said(`Sleep mode is off. Its record could not be read (${reading.why}), so where each session delivers is left as it is.`)
  const placed = await restorePlace($, record)
  // The overnight check's notes go in before the report is finished, so they are at its top (#834).
  const checked = await overnightCheck($, record, moved.to)
  let s = `Sleep mode is off.${record?.since ? ` It began at ${etWhen(record.since)}.` : ''}${placed ? ` ${placed}` : ''}${checked ? ` ${checked}` : ''}`
  // The report once more, checked against GitHub, by the one session that woke it (#835).
  if (record?.report) {
    const problems = await finishReport($, moved.to, { kind: 'woke' })
    s += problems.length ? ` The night's report at ${record.report} is not complete: ${problems.join('; ')}.` : ` The night's report is at ${record.report}.`
    s += ` ${await openReport($, record.report, fromPhone)}`
  } else {
    // Read as sound a moment ago, unreadable once moved: said, never a silent missing report.
    s += ` The night's report was not finished: the record moved aside to ${moved.to} could not be read${record ? ' for where its report is' : ''}.`
  }
  const asked = await askSummaries($, record, self)
  if (asked) s += ` ${asked}`
  return { said: s, morning: await morningFor($, record, self) }
}

// The band's amber line, through the status bar: asleep first, then the scope, then away. Asleep
// is read live, and while it holds away is not said again: asleep keeps every session quiet as away.
const showModes = async ($: EngineInterface) => {
  const scope = await scopeOf($)
  const asleep = await isAsleep($)
  shownAsleep = asleep
  const modes = [...(asleep ? ['ASLEEP' as const] : []), ...(scope ? [scope] : []), ...(!asleep && (await placeOf($)) === 'away' ? ['AWAY' as const] : [])]
  try {
    await $.statusbar.setModes({ modes })
  } catch (err) {
    // The mode still holds; only its label is missing. Said once, never silently (fail loud).
    if (!statusNoted) {
      statusNoted = true
      $.ui.toast(`The mode is on but cannot show in the band: ${msg(err)}`)
    }
  }
}

// The held card shows only at home, where Dan can press it, and never while the Mac sleeps (#840):
// nobody is at it, and what was held waits for wake.
const showHeld = async ($: EngineInterface) => {
  const card = (await placeOf($)) === 'home' && !(await isAsleep($)) ? heldCard(await heldOf($)) : undefined
  try {
    if (card) await $.modkit.bandRow(card)
    else await $.modkit.clearBandRow({ mod: MOD, id: 'held' })
  } catch (err) {
    $.ui.toast(`What was held while you were away cannot show in the band: ${msg(err)}`)
  }
}

const hold = async ($: EngineInterface, label: string, prompt: string) => {
  const held = await heldOf($)
  if (held.some(h => h.prompt === prompt)) return
  const seq = ((await $.state.get(heldSeqRef)).value ?? 0) + 1
  await $.state.set(heldSeqRef, seq)
  await $.state.set(heldRef, [...held, { id: String(seq), label, prompt }])
}

// Every simple command a Bash call runs, through mod-kit's one reader (#712): each with what a |
// feeds it (#724), the program it runs and what that program can do, a shell's script read as the
// commands it runs (its -c, a heredoc, a here-string, or what echo, printf or cat pipes in), and
// what a find -exec runs read as a command of its own, so this mod keeps no reader of its own
// (L613). Each is given its git reading, and its gh readings (#961): the words it runs gh with and
// the merge helper's arguments, each read once here by mod-kit's one reader of gh's arguments.
const readCommands = async ($: EngineInterface, raw: string): Promise<Cmd[]> => {
  const out: Cmd[] = []
  for (const c of await $.modkit.pipeline({ command: raw })) {
    const g = await $.modkit.git({ words: c.words })
    const cmd: Cmd = g ? { ...c, git: { sub: g.sub, args: g.args, ...(g.dir !== undefined ? { dir: g.dir } : {}) } } : { ...c }
    const ghAt = ghWords(c.words)
    const gh = ghAt ? await $.modkit.gh({ words: ghAt }) : undefined
    if (gh) cmd.gh = gh
    const helperAt = helperWords(c.words)
    const helper = helperAt ? await $.modkit.gh({ words: helperAt }) : undefined
    if (helper) cmd.mergeHelper = helper
    out.push(cmd)
  }
  return out
}

// The files a Bash call changes, from mod-kit's one write reader (#712), in the folder the session
// works in and its home.
const readWrites = async ($: EngineInterface, raw: string) =>
  $.modkit.writes({ command: raw, cwd: await $.session.cwd(), home: (await $.env.get('HOME')) ?? '' })
const NO_WRITES = { files: [], changes: [], unnamed: [] }

const run = async ($: EngineInterface, argv: string[], timeoutMs = RUN_MS, env?: Record<string, string>) => {
  try {
    return await $.process.run(argv, { timeoutMs, ...(env ? { env } : {}) })
  } catch (err) {
    return { exitCode: -1, stdout: '', stderr: msg(err), isStdoutTruncated: false, isStderrTruncated: false }
  }
}

// ---- Sleep mode phase 8 (#844): the overnight driver ----
// Every decision is driver.ts's, from recorded state; here it is read for, then carried out. The
// counter is written before anything it allowed is done (assume it runs twice), and a counter that
// cannot be written stops the session rather than block on a count it did not keep.

type Enrolled = { record: SleepRecord; self: string; home: string; dir: string; current: string; now: number }

// Driven only while the Mac sleeps and the record names this session a worker (#840, H4).
// `seen` is a reading this minute already took, so the tick reads the record once (L91).
const enrolledNow = async ($: EngineInterface, seen?: SleepReading): Promise<Enrolled | null> => {
  const reading = seen ?? (await sleepNow($))
  if (reading.state !== 'asleep') return null
  const self = await $.session.id()
  if (!Array.isArray(reading.record.workers) || !reading.record.workers.includes(self)) return null
  const p = await sleepPaths($)
  return { record: reading.record, self, home: p.home, dir: p.dir, current: p.current, now: await $.clock.now() }
}

const queueScript = (home: string) => `${home}/.claude/hooks/lib/sleep-queue.sh`

const loadDriver = async ($: EngineInterface, en: Enrolled): Promise<DriverReading> => {
  const path = driverPath(en.dir, en.record.generation, en.self)
  try {
    if (!(await $.fs.exists(path))) return { state: 'none' }
    return readDriver(await $.fs.read(path), en.record.generation, en.self)
  } catch (err) {
    return { state: 'unreadable', why: `the driver's counter could not be read (${msg(err)})` }
  }
}

// null once written and read back whole; otherwise why not.
const saveDriver = async ($: EngineInterface, en: Enrolled, d: DriverRecord): Promise<string | null> => {
  const path = driverPath(en.dir, en.record.generation, en.self)
  const text = JSON.stringify(d)
  try {
    await run($, ['mkdir', '-p', path.slice(0, path.lastIndexOf('/'))])
    await $.fs.write(path, text)
    return (await $.fs.read(path)) === text ? null : 'it did not read back as written'
  } catch (err) {
    return msg(err)
  }
}

// The session's repository: its root, and owner/name from its origin, lower case as the queue keeps it.
// The root is the project's main working tree, which $.session.repo() gives even for a session in a
// linked worktree (measured on Claude Code 2.1.295, #996): the folder the overnight rules name to
// sleep-queue.sh, which claims by repository and makes each claim's worktree beside the primary
// checkout. The origin is read by mod-kit's one reader (#951); a reading that fails leaves the root known.
const repoOf = async ($: EngineInterface): Promise<{ root: string | null; slug: string | null }> => {
  let r: Awaited<ReturnType<EngineInterface['session']['repo']>>
  try {
    r = await $.session.repo()
  } catch {
    return { root: null, slug: null }
  }
  if (!r) return { root: null, slug: null }
  try {
    return { root: r.root, slug: (await $.modkit.repo({ root: r.root, remote: r.remote })).github?.toLowerCase() ?? null }
  } catch {
    return { root: r.root, slug: null }
  }
}

// The weekly reading, null when there is none (never a zero standing in for it, L706).
const usageNow = async ($: EngineInterface): Promise<{ weekly: number | null; usage: Record<string, unknown> | null }> => {
  try {
    const u = await $.session.usage()
    const w = u.rateLimits.find(r => r.kind === 'seven_day')
    return {
      weekly: w && Number.isFinite(w.percentUsed) ? w.percentUsed : null,
      usage: { ...(u.cost ? { costUsd: u.cost.usd } : {}), rateLimits: u.rateLimits.map(r => ({ kind: r.kind, percentUsed: r.percentUsed, ...(r.resetsAt ? { resetsAt: r.resetsAt } : {}) })) },
    }
  } catch {
    return { weekly: null, usage: null }
  }
}

// Tonight's notes as written, '' before the first, null when they cannot be read.
const notesNow = async ($: EngineInterface, en: Enrolled): Promise<string | null> => {
  const path = `${en.dir}/notes/${en.record.generation.replace(/[^\w.-]/g, '_')}.jsonl`
  try {
    return (await $.fs.exists(path)) ? await $.fs.read(path) : ''
  } catch {
    return null
  }
}

const claimNow = async ($: EngineInterface, en: Enrolled): Promise<ClaimReading> => {
  const r = await run($, ['bash', queueScript(en.home), 'claims'])
  if (r.exitCode !== 0) return { state: 'unknown', why: (r.stdout + r.stderr).trim().split('\n')[0]?.replace(/^refused\t-\t/, '') || `sleep-queue.sh claims exited ${r.exitCode}` }
  return heldClaim(r.stdout, en.self)
}

// The tip of the sleep/ branch of the issue this session holds: a new commit there is progress.
// Only its own: another worker's commits on its own branch are not this session's (#844). Nothing
// held reads as no branch; null when unreadable.
const refsNow = async ($: EngineInterface, root: string | null, claim: ClaimReading): Promise<string | null> => {
  if (!root || claim.state !== 'held') return ''
  const r = await run($, ['git', '-C', root, 'for-each-ref', '--format=%(objectname)', `refs/heads/sleep/${claim.claim.issue}`])
  return r.exitCode === 0 ? r.stdout : null
}

// Ends a claim through the queue, which writes the matching note (#905): null when ended, else why not.
const endClaim = async ($: EngineInterface, en: Enrolled, root: string | null, rel: Release): Promise<string | null> => {
  if (!root) return 'this session is not in a repository, so the queue cannot name the claim'
  // Marked as the driver's, so the queue's note of this end is never read back as the session's progress.
  let r
  try {
    r = await $.process.run(['bash', queueScript(en.home), 'release', root, String(rel.issue), en.self, rel.state, rel.why], { timeoutMs: RUN_MS, env: { SLEEP_NOTE_BY_DRIVER: '1' } })
  } catch (err) {
    return `sleep-queue.sh release could not be run (${msg(err)})`
  }
  if (r.exitCode === 0 && r.stdout.startsWith('released')) return null
  return (r.stdout + r.stderr).trim().split('\n')[0] || `sleep-queue.sh release exited ${r.exitCode}`
}

// Every note the driver writes is marked as its own, so it is never read back as the session's progress.
const writeNotes = async ($: EngineInterface, en: Enrolled, notes: Note[], extra: Record<string, unknown> = {}) => {
  for (const n of notes) {
    try {
      await sleepNote($, en.current, { ...n, ...(n.kind === 'heartbeat' ? extra : {}), driver: true, at: en.now, by: en.self })
    } catch (err) {
      $.ui.log(`scope-modes: the overnight driver's ${n.kind} note could not be written: ${msg(err)}`, { to: 'debug' })
    }
  }
}

// One at a time in this session: a Stop, an API error and the minute's tick each read the counter,
// decide and write it back, so two interleaved would lose one's count (assume it runs twice).
let driverChain: Promise<unknown> = Promise.resolve()
const oneAtATime = <T>(fn: () => Promise<T>): Promise<T> => {
  const p = driverChain.then(fn, fn)
  driverChain = p.catch(() => undefined)
  return p
}

// The nights this session was let stop, kept here too, so a stop whose counter could not be
// written is still a stop: the next Stop never blocks on the older count it would read back.
const stoppedHere = new Set<string>()
const stopKey = (en: Enrolled) => `${en.record.generation}/${en.self}`
// A park the watchdog made but could not record on disk, said at the next Stop all the same.
const parkedHere = new Map<string, string>()

// One Stop of an enrolled session: a block keeping it working, or null to let it stop.
const driveStop = ($: EngineInterface): Promise<{ block: string } | null | 'not-driven'> =>
  oneAtATime(async () => {
    const en = await enrolledNow($)
    if (!en) return 'not-driven' as const
    if (stoppedHere.has(stopKey(en))) return null
    const where = await repoOf($)
    if (!where.root) {
      // The queue claims by repository, so a session in none has nothing to claim: it stops, said.
      stoppedHere.add(stopKey(en))
      await writeNotes($, en, [{ kind: 'stopped', text: 'this session is in no repository, so it has nothing to claim tonight' }])
      return null
    }
    let driver = await loadDriver($, en)
    const unsavedPark = parkedHere.get(stopKey(en))
    if (unsavedPark && driver.state !== 'unreadable') {
      const base = driver.state === 'ok' ? driver.record : freshDriver(en.record.generation, en.self, en.now)
      driver = { state: 'ok', record: { ...base, parked: base.parked ? `${thenNext(base.parked)}${unsavedPark}` : unsavedPark } }
    }
    parkedHere.delete(stopKey(en))
    const notesText = await notesNow($, en)
    const claim = await claimNow($, en)
    const u = await usageNow($)
    const fingerprint = progressOf(notesText, en.self, await refsNow($, where.root, claim))
    const d = decideStop({
      now: en.now, self: en.self, generation: en.record.generation, repo: where.slug, driver, fingerprint, notesText,
      weekly: u.weekly, claim, rules: overnightRules(en.self, where.root),
    })
    if (d.kind === 'stop') stoppedHere.add(stopKey(en))
    if (d.record) {
      const unsaved = await saveDriver($, en, d.record)
      if (unsaved && d.kind === 'block') {
        stoppedHere.add(stopKey(en))
        const why = `the driver's counter could not be written (${unsaved}), so it stopped rather than block on a count it did not keep`
        // The claim in hand is ended too, never left held by a session that has stopped.
        const ended = claim.state === 'held' ? await endClaim($, en, where.root, { issue: claim.claim.issue, state: 'failed', why }) : null
        await writeNotes($, en, [{ kind: 'stopped', ...(where.slug ? { repo: where.slug } : {}), text: ended ? `${why}; the claim on #${claim.state === 'held' ? claim.claim.issue : ''} could not be ended: ${ended}` : why }])
        return null
      }
    }
    const ended = d.release ? await endClaim($, en, where.root, d.release) : null
    const notes = ended && d.release ? [...d.notes, { kind: 'finding', repo: where.slug, issue: d.release.issue, text: `the claim on #${d.release.issue} could not be ended as ${d.release.state}: ${ended}` }] : d.notes
    await writeNotes($, en, notes, u.usage ? { usage: u.usage } : {})
    // Said from what the queue answered, never before it (#925); its answer reaches the block only as data (#922).
    if (d.kind === 'block') return { block: blockTold(d, ended, { root: where.root, self: en.self }) }
    $.ui.log(`scope-modes: the overnight driver let this session stop: ${d.why}`, { to: 'debug' })
    return null
  })

// A turn that ended on an API error: wait it out, or stop, as driver.ts decides.
const driveFailure = ($: EngineInterface, error: string, message: string): Promise<void> =>
  oneAtATime(async () => {
    const en = await enrolledNow($)
    if (!en || stoppedHere.has(stopKey(en))) return
    const where = await repoOf($)
    const u = await usageNow($)
    const driver = await loadDriver($, en)
    const claim = await claimNow($, en)
    const d = decideFailure({ now: en.now, self: en.self, generation: en.record.generation, repo: where.slug, driver, error, message, weekly: u.weekly, claim })
    if (d.kind === 'stop') stoppedHere.add(stopKey(en))
    if (d.record) {
      const unsaved = await saveDriver($, en, d.record)
      if (unsaved) {
        // A wait that was not recorded would never be resumed: said, and the session stops, ending
        // the claim in hand as the decision would have, or as failed, never leaving it held.
        stoppedHere.add(stopKey(en))
        const why = `after the ${error} error the driver's counter could not be written (${unsaved}), so no retry was set`
        const rel: Release | undefined = d.kind === 'stop' && d.release ? d.release : claim.state === 'held' ? { issue: claim.claim.issue, state: 'failed', why } : undefined
        const ended = rel ? await endClaim($, en, where.root, rel) : null
        await writeNotes($, en, [{ kind: 'stopped', ...(where.slug ? { repo: where.slug } : {}), text: ended && rel ? `${why}; the claim on #${rel.issue} could not be ended: ${ended}` : why }])
        return
      }
    }
    const ended = d.kind === 'stop' && d.release ? await endClaim($, en, where.root, d.release) : null
    const extra: Note[] = ended && d.kind === 'stop' && d.release ? [{ kind: 'finding', repo: where.slug, issue: d.release.issue, text: `the claim on #${d.release.issue} could not be ended as ${d.release.state}: ${ended}` }] : []
    await writeNotes($, en, [...d.notes, ...extra])
  })

// Each minute: start a session again once its wait is over, and park a claim held past its active
// time even mid turn (the watchdog), said at the next Stop. The session is started again outside
// the one at a time queue, so the turn it starts can reach its own Stop.
const driverTick = async ($: EngineInterface, seen: SleepReading) => {
  const resume = await oneAtATime(async (): Promise<boolean> => {
    const en = await enrolledNow($, seen)
    if (!en || stoppedHere.has(stopKey(en))) return false
    const r = await loadDriver($, en)
    if (r.state !== 'ok') return false
    const d = { ...r.record }
    if (resumeDue(d, en.now)) {
      // Cleared and saved first, so a second tick never starts it twice.
      d.resumeAt = null
      return (await saveDriver($, en, d)) === null
    }
    if (d.stopped || d.resumeAt !== null) return false
    const c = await claimNow($, en)
    if (c.state !== 'held' || c.claim.since === null) return false
    const active = activeMs(d.waits, c.claim.since, en.now)
    if (active < LIMITS.stuckMs) return false
    const where = await repoOf($)
    const why = `${Math.round(active / MIN)} minutes of active work on it, past the ${LIMITS.stuckMs / MIN / 60} hours an issue gets`
    const rel: Release = { issue: c.claim.issue, state: 'parked', why }
    d.parked = releaseTold('watchdog', rel, await endClaim($, en, where.root, rel), { root: where.root, self: en.self })
    if (await saveDriver($, en, d)) parkedHere.set(stopKey(en), d.parked)
    return false
  })
  if (!resume) return
  try {
    await $.prompt.submit({ text: RESUME })
  } catch (err) {
    // Not started: due again at the next minute.
    await oneAtATime(async () => {
      const en = await enrolledNow($)
      if (!en) return
      const r = await loadDriver($, en)
      if (r.state === 'ok') await saveDriver($, en, { ...r.record, resumeAt: en.now })
    })
    $.ui.log(`scope-modes: the overnight driver could not start the session again: ${msg(err)}`, { to: 'debug' })
  }
}

// ---- Power for the night (#844) ----
// /sleep refuses on battery, and holds `caffeinate -i` (no idle sleep) until the record's end, so the
// Mac never sleeps under the work. The hold ends by itself at `until`, and is let go at wake.

const caffeinatePid = (dir: string) => `${dir}/caffeinate.pid`

// null when on mains power; otherwise why sleep mode must not start.
const powerRefusal = async ($: EngineInterface): Promise<string | null> => {
  const r = await run($, ['pmset', '-g', 'batt'])
  if (r.exitCode !== 0) return `whether this Mac is on battery could not be read (${r.stderr.trim() || `pmset exited ${r.exitCode}`})`
  if (/'Battery Power'/.test(r.stdout)) return 'this Mac is on battery power, and a night of work would drain it. Plug it in and run /sleep again'
  if (!/'AC Power'/.test(r.stdout)) return `pmset did not say what this Mac is drawing power from (${r.stdout.trim().split('\n')[0]?.slice(0, 120) ?? ''})`
  return null
}

// Starts the hold; null when held, else why not (said in /sleep's answer).
const holdAwake = async ($: EngineInterface, dir: string, untilMs: number, now: number): Promise<string | null> => {
  const secs = Math.max(60, Math.ceil((untilMs - now) / 1000))
  const r = await run($, ['sh', '-c', 'caffeinate -i -t "$1" </dev/null >/dev/null 2>&1 & echo $!', 'sh', String(secs)])
  const pid = r.stdout.trim()
  if (r.exitCode !== 0 || !/^\d+$/.test(pid)) return `caffeinate could not be started (${r.stderr.trim() || `exit ${r.exitCode}`})`
  try {
    // Its number and its time, so wake stops only this hold, never a caffeinate that took the number later.
    await $.fs.write(caffeinatePid(dir), `${pid} ${secs}`)
  } catch (err) {
    return `caffeinate is holding the Mac awake until the night ends, but its process number could not be kept, so wake will not let it go early (${msg(err)})`
  }
  return null
}

// Lets the hold go: only the process recorded, and only while it is still that hold (L1011, L444).
const releaseAwake = async ($: EngineInterface, dir: string) => {
  const file = caffeinatePid(dir)
  try {
    if (!(await $.fs.exists(file))) return
    const [pid, secs] = (await $.fs.read(file)).trim().split(' ')
    if (pid && /^\d+$/.test(pid) && secs && /^\d+$/.test(secs)) {
      // Only while that number is still the very hold /sleep started: the same command, the same time.
      const ps = await run($, ['ps', '-p', pid, '-o', 'args='])
      if (ps.exitCode === 0 && ps.stdout.trim() === `caffeinate -i -t ${secs}`) await run($, ['kill', pid])
    }
    await run($, ['rm', '-f', file])
  } catch (err) {
    $.ui.log(`scope-modes: the night's caffeinate hold could not be let go: ${msg(err)}`, { to: 'debug' })
  }
}

// mod-kit's words for a checkout on no branch. Its branch reader holds a detached head unreadable,
// since a reader deciding what an edit may do must not guess; winding down asks something else,
// what to finish, and a detached head has no branch to finish (as it had before #980). The tests
// read with a byte for byte copy of mod-kit's reader, so a change to these words fails them.
const DETACHED = 'a detached head names no branch'

// What winding down finishes: the branch this session is on, read when it turns on, by mod-kit's one
// reader of where a checkout stands (#980). Not in a repository is an answer (nothing to finish); a
// read that fails is not, and is said (L11).
type TargetRead = ScopeModesTarget | null | { unreadable: string }
const readTarget = async ($: EngineInterface): Promise<TargetRead> => {
  let b
  try {
    b = await $.modkit.branch({ path: await $.session.cwd() })
  } catch (err) {
    return { unreadable: msg(err) }
  }
  if (!b) return null
  // The checkout winding down reads (gh's folder, the branch and worktree lists, uncommitted work)
  // is the session's own, mod-kit's `root`, a linked worktree's own folder included (#996): the
  // uncommitted work it must finish is there. The branch and worktree lists and gh's repository are
  // the same from any worktree of the project. Not $.session.repo().root, which is the main working
  // tree even from a linked worktree (measured on Claude Code 2.1.295), whose changes are another
  // session's.
  if ('unreadable' in b && b.unreadable !== DETACHED) return { unreadable: b.unreadable }
  const kept = await keptPlace($)
  if ('unreadable' in b) return { root: b.root, branch: '', isDefault: true, issues: [], pr: null, ...kept }
  return { root: b.root, branch: b.branch, isDefault: b.isDefault, issues: b.issues, pr: null, ...kept }
}

// The main working tree, as $.session.repo() names it even from a linked worktree, or undefined
// when it names none or cannot be read.
const mainTree = async ($: EngineInterface): Promise<string | undefined> => {
  try {
    return (await $.session.repo())?.root ?? undefined
  } catch {
    return undefined
  }
}
// Where the finish check reads once the session's own folder is gone (#1059): the main working tree
// and the repository's name, kept with the target when winding down turns on, since a session whose
// folder was removed may no longer be able to say either.
const keptPlace = async ($: EngineInterface): Promise<{ main?: string; repo?: string }> => {
  const main = await mainTree($)
  const repo = await sessionSlug($)
  return { ...(main ? { main } : {}), ...(repo ? { repo } : {}) }
}
// Whether a folder is there. A look that throws counts it there, so the read goes ahead as it did
// before #1059 and a failure is said by the read itself.
const isThere = async ($: EngineInterface, path: string): Promise<boolean> => {
  try {
    return await $.fs.exists(path)
  } catch {
    return true
  }
}

type PrJson = { number?: number; state?: string; url?: string; headRefName?: string; headRefOid?: string; closingIssuesReferences?: { number?: number }[] }

type IsItLiveNoun = { verdict: (q: { repo: string; pr: number }) => Promise<{ state: DeployState } | null> }

// The deploy as is it live's card for this PR says (#687), never Claude's word. The repository is
// the one GitHub's own link for the PR names. An absent mod is unmeasured, never live; a read that
// throws (a withheld noun, a state that cannot be read) is said as unreadable.
const readDeploy = async ($: EngineInterface, pr: { number: number; url?: string }): Promise<Reading['deploy']> => {
  // Read by mod-kit's one reader of a github.com link (#961), as is it live keys its cards.
  let repo: string | null
  try {
    repo = pr.url ? await $.modkit.linkRepo({ link: pr.url }) : null
  } catch (err) {
    return { unreadable: `GitHub's link for PR #${pr.number} could not be read (${msg(err)})` }
  }
  if (!repo) return { unreadable: `GitHub gave no link for PR #${pr.number}` }
  try {
    const v = await ($ as unknown as { isItLive: IsItLiveNoun }).isItLive.verdict({ repo, pr: pr.number })
    return v ? { state: v.state } : null
  } catch (err) {
    // A noun of $ may only be spelled at its call site (the engine refuses `in $` or reading
    // $.isItLive as a value), so absence is told by the call: a missing noun is a TypeError from
    // reading .verdict off undefined, while whatever the noun itself throws reaches here wrapped as
    // the engine's HooksError (measured in the tests). Either way it is never live.
    if (err instanceof TypeError) return { unmeasured: 'the is it live mod is not loaded' }
    return { unreadable: msg(err) }
  }
}

// The PR a reading found, and the issues it closes, which the caller keeps for later checks; its
// link, when GitHub gave one, is what tells it apart from a PR this session opened (#856).
type Found = { number: number; closes: number[]; url?: string }
const PR_FIELDS = 'number,state,url,closingIssuesReferences,headRefName,headRefOid'

// What the finish check reads for one PR: the branch's own (found by its head) or one named by
// number, in `repo` when given (a PR this session opened, read in the repository its link names).
// The branch cleaned is the PR's own head where the target names no branch. A PR in another
// repository than the session's (`elsewhere`) has its branch on GitHub checked there, while its
// local branch and worktree live in a checkout this session cannot see, so they are said to be
// unreadable rather than read as gone from this one (lessons review of #714).
//
// The session's folder can be gone: winding down's own cleanup removes a worktree (#1059). A process
// started in a folder that is not there fails naming the command (posix_spawn 'gh'), never the
// folder, so a finished session was refused for ever, told gh could not start. Gone, the folder is
// wind down's own end state: GitHub is read by the repository's name from a folder that is there,
// the branch and worktree lists from the main working tree, and the uncommitted work went with it.
const readWind = async ($: EngineInterface, t: ScopeModesTarget, repo?: string, elsewhere = false): Promise<{ reading: Reading; found?: Found }> => {
  const r: Reading = { branch: t.branch, isDefault: t.isDefault, pr: null, branchHere: false, branchOnGitHub: false, worktreeOnBranch: false, deploy: null, dirty: false }
  const gone = !(await isThere($, t.root))
  // Gone, the main working tree, where one is there, holds the branch and worktree lists.
  let main: string | undefined
  if (gone) for (const m of [t.main, await mainTree($)]) if (!main && m && m !== t.root && (await isThere($, m))) main = m
  const slug = repo ?? (gone ? (t.repo ?? (await sessionSlug($))) : undefined)
  const goneSaid = `the session's directory ${t.root} no longer exists`
  // Where a process starts: the session's folder while it is there; gone, a folder that is.
  const cwd = gone ? (main ?? (await $.env.get('HOME')) ?? undefined) : t.root
  const where = slug ? ['--repo', slug] : []
  let prUrl: string | undefined
  let found: Found | undefined
  // A start that fails in a folder gone since it was looked for is said as that folder (#1059).
  const startFailed = async (err: unknown) => {
    const missing = cwd && !(await isThere($, cwd)) ? (cwd === t.root ? goneSaid : `the folder ${cwd} no longer exists`) : undefined
    return { exitCode: -1, stdout: '', stderr: missing ?? msg(err), isStdoutTruncated: false, isStderrTruncated: false }
  }
  const gh = async (args: string[]) => $.process.run(['gh', ...args], { timeoutMs: RUN_MS, ...(cwd ? { cwd } : {}) }).catch(startFailed)
  // git reads the session's folder while it is there, and the main working tree once it is gone.
  const git = async (args: string[]) =>
    gone ? $.process.run(['git', ...(main ? ['-C', main] : []), ...args], { timeoutMs: RUN_MS, ...(cwd ? { cwd } : {}) }).catch(startFailed) : run($, ['git', '-C', t.root, ...args])
  if (gone && !slug && (t.branch || t.pr)) return { reading: { ...r, pr: { unreadable: `${goneSaid}, and no repository is named to read its PR in` } } }
  if (t.branch || t.pr) {
    const res = t.pr
      ? await gh(['pr', 'view', String(t.pr), ...where, '--json', PR_FIELDS])
      : await gh(['pr', 'list', '--head', t.branch, ...where, '--state', 'all', '--limit', '1', '--json', PR_FIELDS])
    if (res.exitCode !== 0) return { reading: { ...r, pr: { unreadable: res.stderr.trim() || `gh exited ${res.exitCode}` } } }
    let pr: PrJson | undefined
    try {
      const j = JSON.parse(res.stdout) as PrJson | PrJson[]
      pr = Array.isArray(j) ? j[0] : j
    } catch {
      return { reading: { ...r, pr: { unreadable: 'gh answered something that is not JSON' } } }
    }
    if (pr && typeof pr.number === 'number') {
      if (!r.branch && typeof pr.headRefName === 'string') r.branch = pr.headRefName
      const state = pr.state === 'MERGED' || pr.state === 'CLOSED' ? pr.state : 'OPEN'
      const issues: { number: number; state: 'OPEN' | 'CLOSED' }[] = []
      for (const ref of pr.closingIssuesReferences ?? []) {
        if (typeof ref.number !== 'number') continue
        const v = await gh(['issue', 'view', String(ref.number), ...where, '--json', 'state'])
        if (v.exitCode !== 0) return { reading: { ...r, pr: { unreadable: `issue #${ref.number}: ${v.stderr.trim()}` } } }
        const s = (JSON.parse(v.stdout) as { state?: string }).state
        issues.push({ number: ref.number, state: s === 'CLOSED' ? 'CLOSED' : 'OPEN' })
      }
      r.pr = { number: pr.number, state, ...(typeof pr.headRefOid === 'string' && pr.headRefOid ? { head: pr.headRefOid } : {}), issues }
      prUrl = typeof pr.url === 'string' ? pr.url : undefined
      found = { number: pr.number, closes: issues.map(i => i.number), url: prUrl }
    }
  }
  // The deploy and the cleanup are read only once the PR is merged, so an open PR costs one gh call a check.
  if (r.pr && !('unreadable' in r.pr) && r.pr.state === 'MERGED') {
    r.deploy = await readDeploy($, { number: r.pr.number, url: prUrl })
    if (!r.branch) {
      // Every branch would match an empty name, so a PR GitHub gives no branch for is said.
      const none = { unreadable: `GitHub named no branch for PR #${r.pr.number}` }
      return { reading: { ...r, branchHere: none, branchOnGitHub: none, worktreeOnBranch: none }, found }
    }
    // ls-remote --exit-code answers 2 when no such branch, and anything else nonzero is a failed read.
    // Gone with no checkout left to name origin, GitHub is asked by the repository's name.
    const url = (elsewhere || (gone && !main)) && slug ? `https://github.com/${slug}.git` : 'origin'
    const remote = await git(['ls-remote', '--exit-code', '--heads', url, r.branch])
    r.branchOnGitHub = remote.exitCode === 0 ? true : remote.exitCode === 2 ? false : { unreadable: remote.stderr.trim() || 'could not reach origin' }
    if (elsewhere) {
      const unseen = { unreadable: `PR #${r.pr.number} is in ${repo ?? 'another repository'}, whose checkout this session cannot see` }
      return { reading: { ...r, branchHere: unseen, worktreeOnBranch: unseen }, found }
    }
    if (gone && !main) {
      // The main working tree kept when winding down turned on is gone too: no checkout of the
      // project is left to hold the branch or a worktree on it. With none kept, nothing says so.
      const lists: boolean | { unreadable: string } = t.main ? false : { unreadable: `${goneSaid}, and no other checkout of its repository is known to read it in` }
      return { reading: { ...r, branchHere: lists, worktreeOnBranch: lists }, found }
    }
    const here = await git(['branch', '--list', r.branch])
    r.branchHere = here.exitCode === 0 ? here.stdout.trim() !== '' : { unreadable: here.stderr.trim() }
    const wt = await git(['worktree', 'list', '--porcelain'])
    r.worktreeOnBranch = wt.exitCode === 0 ? wt.stdout.split('\n').includes(`branch refs/heads/${r.branch}`) : { unreadable: wt.stderr.trim() }
  }
  // Gone, the folder took its uncommitted work with it: nothing is left there to commit.
  if (t.isDefault && r.pr === null && !gone) {
    const st = await run($, ['git', '-C', t.root, 'status', '--porcelain'])
    r.dirty = st.exitCode === 0 ? st.stdout.trim() !== '' : { unreadable: st.stderr.trim() }
  }
  return { reading: r, found }
}

const openedOf = async ($: EngineInterface) => (await $.state.get(openedRef)).value ?? []
// owner/name of the session folder's origin, in the case written, read by mod-kit's one reader
// (#951); undefined when it names none or cannot be read.
const sessionSlug = async ($: EngineInterface): Promise<string | undefined> => {
  try {
    const r = await $.session.repo()
    return (r ? (await $.modkit.repo({ root: r.root, remote: r.remote })).github : null) ?? undefined
  } catch {
    return undefined
  }
}
const sameList = (a: readonly number[] | undefined, b: readonly number[]) => (a ?? []).join(',') === b.join(',')

// The target with the PR a reading found for its branch, kept so later checks and the agent rule
// know it, and so turning winding down on again never loses it (#702).
const keepFound = async ($: EngineInterface, t: ScopeModesTarget, found: Found | undefined): Promise<ScopeModesTarget> => {
  if (!found || (t.pr === found.number && sameList(t.closes, found.closes))) return t
  const kept = { ...t, pr: found.number, closes: found.closes }
  await $.state.set(targetRef, kept)
  return kept
}

const leftOpenOf = async ($: EngineInterface) => (await $.state.get(leftOpenRef)).value ?? []
// owner/name a PR's link names, read by mod-kit's one reader of a github.com link (#961), or
// undefined for no link or none it names.
const repoOfLink = async ($: EngineInterface, url: string | undefined): Promise<string | undefined> => (url ? ((await $.modkit.linkRepo({ link: url })) ?? undefined) : undefined)
// How a PR left as it is on Dan's choice is listed: by number, repository and the reason he was asked
// about, those left open and those left closed (#1033) each in a sentence of its own.
const keptLine = (d: ScopeModesLeftAsIs) => `PR #${d.number} in ${d.repo} (${d.why})`
const keptSaid = (kept: readonly ScopeModesLeftAsIs[], whose: string): string => {
  const open = kept.filter(d => !isLeftClosed(d)).map(keptLine)
  const closed = kept.filter(isLeftClosed).map(keptLine)
  return `${open.length ? ` Left open by ${whose} choice: ${open.join('; ')}.` : ''}${closed.length ? ` Left closed by ${whose} choice: ${closed.join('; ')}.` : ''}`
}

// What is still to do and what Dan chose to leave open, or null when winding down is not on.
const check = ($: EngineInterface): Promise<Checked | null> => {
  if (checking) return checking
  checking = (async (): Promise<Checked | null> => {
    if ((await scopeOf($)) !== 'WINDING DOWN') return null
    let t = (await $.state.get(targetRef)).value ?? null
    if (t && 'unreadable' in t) {
      const again = await readTarget($)
      await $.state.set(targetRef, again)
      if (again && 'unreadable' in again) return { left: [`what this session is working on could not be read (${again.unreadable})`], kept: [] }
      t = again
    }
    // Outside a repository there is no PR, branch or deploy to finish.
    if (!t) return { left: [], kept: [] }
    // A check that throws must refuse the turn end: a Stop hook that fails is skipped, which would
    // let the turn end unfinished (L42).
    try {
      // On its default branch with no PR, the session may have moved onto a branch since winding
      // down turned on (#702): follow it there.
      if (t.isDefault && t.pr === null) {
        const now = await readTarget($)
        if (now && !('unreadable' in now) && now.branch !== t.branch) {
          t = now
          await $.state.set(targetRef, t)
        }
      }
      const { reading, found } = await readWind($, t)
      t = await keepFound($, t, found)
      // A PR is left as it is only on Dan's own answer to leave_pr_open, recorded against its
      // repository and number: open at its head (#917), or closed without merging (#1033). With none
      // recorded, #856's default holds and it is outstanding.
      const choices = await leftOpenOf($)
      const kept: ScopeModesLeftAsIs[] = []
      const toDo = (r: Reading, repo: string | undefined) => {
        const pr = r.pr
        const d = repo && pr && !('unreadable' in pr) ? choiceFor(choices, repo, pr.number) : undefined
        const withChoice = d ? { ...r, choice: d } : r
        if (d && settledByDan(withChoice)) kept.push(d)
        return outstanding(withChoice)
      }
      const left = toDo(reading, (await repoOfLink($, found?.url)) ?? (choices.length ? await sessionSlug($) : undefined))
      // Winding down finalizes everything the session has open, so every PR this session opened is
      // outstanding until merged, whether or not the session's own branch has a PR (#856: a session
      // whose branch PR was finished parked three PRs it had opened "waiting on you"). An agent's in a
      // worktree the session is not in is included (#702). Only PRs this session's own gh pr create
      // printed are here (noteOpened), so another session's PRs never hold it. The branch's own PR,
      // read above, is matched by its link and not read twice.
      const opened = await openedOf($)
      // The session's own repository, to tell a PR opened here from one opened in another; a
      // remote that cannot be read counts every PR as elsewhere, so nothing is read as cleaned.
      const own = opened.length ? await sessionSlug($) : undefined
      const ownLink = found?.url?.toLowerCase()
      for (const o of opened) {
        const elsewhere = !own || own.toLowerCase() !== o.repo.toLowerCase()
        // The branch's own PR by its link, or, where GitHub gave none, by its number in this repository.
        const isBranchPr = ownLink ? ownLink === `https://github.com/${o.repo}/pull/${o.number}`.toLowerCase() : !!found && !elsewhere && found.number === o.number
        if (isBranchPr) continue
        const one = await readWind($, { root: t.root, branch: '', isDefault: false, issues: [], pr: o.number, ...(t.main ? { main: t.main } : {}) }, o.repo, elsewhere)
        if (one.found && !sameList(o.closes, one.found.closes)) {
          const closes = one.found.closes
          await $.state.set(openedRef, (await openedOf($)).map(x => (x.repo === o.repo && x.number === o.number ? { ...x, closes } : x)))
        }
        left.push(...toDo(one.reading, o.repo))
      }
      // One unreadable GitHub answers every read the same way, said once.
      return { left: [...new Set(left)], kept }
    } catch (err) {
      return { left: [`the finish check failed (${msg(err)})`], kept: [] }
    }
  })().finally(() => {
    checking = undefined
  })
  return checking
}

const finish = async ($: EngineInterface, kept: readonly ScopeModesLeftAsIs[]) => {
  await $.state.set(scopeRef, null)
  await $.state.set(targetRef, null)
  await showModes($)
  $.ui.toast(`Wind down finished: safe to close this session.${keptSaid(kept, 'your')}`)
}

// leave_pr_open (#917, #1033): asks Dan whether a PR stays as it is rather than being merged, in the
// state GitHub gives for it when asked: an open PR left open, or a PR closed without merging left
// closed. Only his own "Leave it open" or "Leave it closed" is recorded, one answer per PR by its
// repository and number. Left open is recorded against the head commit read before he was asked, so
// a push after his answer is asked about again; left closed carries no head, since a closed PR
// merges nothing until it is reopened, and reopened it is open, which that answer never covers. Any
// other answer withdraws an earlier choice: with none, winding down waits on the PR until it is
// merged (#856). Nothing is asked while Dan is asleep (#841), nor about a PR that cannot be read or
// is merged, and then nothing is recorded. One table row per state, so both are asked and recorded
// by the one function below.
type AsIs = {
  /** His answer that leaves the PR as it is: the only one recorded. */
  keep: string
  /** The other choice offered, and what Claude is told it means. */
  other: string
  otherSaid: (pr: string) => string
  question: (pr: string, why: string) => string
  /** What is recorded from his keep answer, given the head commit read before he was asked. */
  record: (repo: string, number: number, why: string, head: string) => ScopeModesLeftAsIs
  keptSaid: (pr: string, head: string) => string
  /** What the PR would stay as, in the words of the answer ("open", "closed"). */
  as: string
  /** Whether a head commit is needed to record his answer: only an open PR is pushed to. */
  needsHead: boolean
}
const AS_IS: Record<'OPEN' | 'CLOSED', AsIs> = {
  OPEN: {
    keep: 'Leave it open',
    other: 'Merge it',
    otherSaid: pr => `Dan said merge it: winding down waits on ${pr} until it is merged.`,
    question: (pr, why) => `Leave ${pr} open (${why})? Winding down stops waiting on it until it is pushed to again.`,
    record: (repo, number, why, head) => ({ repo, number, head, why }),
    keptSaid: (pr, head) => `Dan chose to leave ${pr} open at ${head.slice(0, 7)}: winding down counts it settled until it is pushed to again.`,
    as: 'open',
    needsHead: true,
  },
  CLOSED: {
    keep: 'Leave it closed',
    other: 'Reopen it',
    otherSaid: pr => `Dan said reopen it: winding down waits on ${pr} until it is reopened and merged.`,
    question: (pr, why) => `Leave ${pr} closed without merging (${why})? Winding down stops waiting on it unless it is reopened.`,
    record: (repo, number, why) => ({ repo, number, closed: true, why }),
    keptSaid: pr => `Dan chose to leave ${pr} closed: winding down counts it settled unless it is reopened.`,
    as: 'closed',
    needsHead: false,
  },
}
const leavePrOpen = async ($: EngineInterface, input: Record<string, unknown>): Promise<string> => {
  const number = Number(input.pr)
  if (!Number.isInteger(number) || number <= 0) return `"${String(input.pr ?? '')}" is not a PR number, so Dan was not asked and nothing was recorded.`
  const named = String(input.repo ?? '').trim()
  if (named && !/^[\w.-]+\/[\w.-]+$/.test(named)) return `"${named}" is not a repository (owner/name), so Dan was not asked and nothing was recorded.`
  const repo = named || (await sessionSlug($))
  if (!repo) return "This session's repository could not be read, so name the PR's repository (owner/name). Dan was not asked and nothing was recorded."
  // Dan decides from the reason, so a PR is never put to him without one.
  const why = String(input.why ?? '').trim().replace(/[.?]+$/, '')
  if (!why) return `Say why PR #${number} would be left as it is (open for a reviewer, say, or closed because its work merged in another PR), so Dan can decide. He was not asked and nothing was recorded.`
  const pr = `PR #${number} in ${repo}`
  const unread = (reason: string) => `${pr} could not be read (${reason}), so Dan was not asked and nothing was recorded: winding down still waits on it.`
  const res = await $.process.run(['gh', 'pr', 'view', String(number), '--repo', repo, '--json', 'number,state,url,headRefOid'], { timeoutMs: RUN_MS }).catch(err => ({ exitCode: -1, stdout: '', stderr: msg(err) }))
  if (res.exitCode !== 0) return unread(res.stderr.trim() || `gh exited ${res.exitCode}`)
  let read: PrJson
  try {
    read = JSON.parse(res.stdout) as PrJson
  } catch {
    return unread('GitHub answered something that is not JSON')
  }
  // Asked about the PR as GitHub has it now: a merged PR, or a state it does not know, has nothing to leave.
  const asIs = read.state === 'OPEN' || read.state === 'CLOSED' ? AS_IS[read.state] : undefined
  if (!asIs) return `${pr} is ${String(read.state ?? 'in a state GitHub did not give')}, so there is nothing to leave as it is. Nothing was asked.`
  const head = typeof read.headRefOid === 'string' ? read.headRefOid : ''
  if (asIs.needsHead && !head) return unread('GitHub gave no head commit')
  const question = asIs.question(pr, why)
  const sleeping = await sleepNow($)
  if (sleeping.state === 'asleep') {
    const failed = await noteQuestion($, [question])
    return `Dan is asleep (sleep mode), so he was not asked and nothing was recorded: winding down still waits on ${pr}. ${
      failed === null ? 'The question is noted for his morning report.' : `It could not be noted for his morning report (${failed}), so put it in your final message.`
    }`
  }
  let answer: string
  try {
    answer = await $.ui.ask(question, [asIs.keep, asIs.other])
  } catch (err) {
    return `Dan was not asked (${msg(err)}), so nothing was recorded: winding down still waits on ${pr}.`
  }
  // One answer per PR: a new one, open or closed, replaces whatever he said about it before.
  const others = (await leftOpenOf($)).filter(d => !(d.number === number && d.repo.toLowerCase() === repo.toLowerCase()))
  if (answer === asIs.keep) {
    await $.state.set(leftOpenRef, [...others, asIs.record(repo, number, why, head)])
    return asIs.keptSaid(pr, head)
  }
  // Only his keep answer leaves it as it is: the other choice or anything typed withdraws an earlier one.
  await $.state.set(leftOpenRef, others)
  if (answer === asIs.other) return asIs.otherSaid(pr)
  return `Dan did not choose to leave ${pr} ${asIs.as}, so winding down still waits on it. He wrote: ${answer}`
}

const setScope = async ($: EngineInterface, scope: ScopeModesScope | null) => {
  const was = await scopeOf($)
  await $.state.set(scopeRef, scope)
  // Turning winding down on again keeps what it found, its PR included (#702): reading the target
  // afresh dropped a PR once the session had left its branch. An unreadable target is read again
  // at the next check.
  if (scope !== 'WINDING DOWN') await $.state.set(targetRef, null)
  else if (was !== 'WINDING DOWN') await $.state.set(targetRef, await readTarget($))
  await showModes($)
}

// The PR a `gh pr create` opened, from the link gh prints, noted for winding down whatever mode is
// on, from the session or any of its agents (#702). A note that cannot be made is said, since
// winding down would then not know to finish that PR.
const noteOpened = async ($: EngineInterface, raw: string, result: { text?: string }) => {
  try {
    // The last pull request link gh printed, its repository read by mod-kit's one reader of a
    // github.com link (#961).
    const links = [...String(result.text ?? '').matchAll(/https?:\/\/\S+?\/pull\/(\d+)/gi)]
    if (!links.length) return
    // Read as the judge reads it, so `bash -lc 'gh pr create'` is seen too (lessons review of #714),
    // and gh past its global flags (`gh -R o/r pr create`, #961).
    const cmds = await readCommands($, raw)
    if (!cmds.some(c => c.gh?.sub === 'pr' && c.gh.act === 'create')) return
    let found: { repo: string; number: number } | undefined
    for (const l of links) {
      const r = await $.modkit.linkRepo({ link: l[0] })
      if (r) found = { repo: r, number: Number(l[1]) }
    }
    if (!found) return
    const { repo, number } = found
    const opened = await openedOf($)
    if (opened.some(o => o.repo.toLowerCase() === repo.toLowerCase() && o.number === number)) return
    await $.state.set(openedRef, [...opened, { repo, number }])
  } catch (err) {
    $.ui.toast(`Scope modes could not note the PR this call opened (${msg(err)}), so winding down will not know to finish it.`)
  }
}

// The issue numbers an agent may be sent about while winding down: the branch's, its PR and the
// issues it closes, and every PR this session opened with the issues each closes (#702).
const ownNumbers = (t: TargetRead, opened: readonly ScopeModesOpened[]): number[] => [
  ...(t && 'issues' in t ? [...t.issues, ...(t.pr ? [t.pr] : []), ...(t.closes ?? [])] : []),
  ...opened.flatMap(o => [o.number, ...(o.closes ?? [])]),
]

type Told = { told: number; failed: string[]; unknown?: string }
const tellOthers = async ($: EngineInterface, place: ScopeModesPlace): Promise<Told> => {
  let list
  try {
    list = await $.sessions.list()
  } catch (err) {
    return { told: 0, failed: [], unknown: `the session registry could not be read (${msg(err)})` }
  }
  const out: Told = { told: 0, failed: [] }
  // A registry answer of the wrong shape is said as the others not told, never thrown past the
  // caller: at wake that would lose the reply after the record had moved (#837 lessons review).
  try {
    // A record that cannot be read may be a live session: said, never read as no session (L215).
    if (list.unreadable.length) out.unknown = `the session registry could not read ${list.unreadable.join(', ')}`
    for (const o of list.open) {
      if (o.sessionId === list.selfId) continue
      // mod-kit tries a refused send once more (its hooks/send.ts), so a refusal here is the second.
      const sent = await $.session.send({ to: { sessionId: o.sessionId }, text: place === 'away' ? AWAY_TEXT : HOME_TEXT })
      if (!sent.isDelivered) out.failed.push(sent.reason)
      else out.told++
    }
  } catch (err) {
    // Added to what was already said, never over it: an unreadable record may be a live session (L215).
    out.unknown = [out.unknown, `the session registry's answer could not be read (${msg(err)})`].filter(Boolean).join('; ')
  }
  return out
}

const setPlace = async ($: EngineInterface, place: ScopeModesPlace) => {
  await $.state.set(placeRef, place)
  await $.state.set(justHomeRef, place === 'home')
  await showModes($)
  await showHeld($)
}

const placeSentence = (place: ScopeModesPlace, t: Told) => {
  const name = place === 'away' ? 'Away' : 'Home'
  let s = `${name} is on in this session${t.told ? ` and ${t.told} other${t.told === 1 ? '' : 's'}` : ''}.`
  if (t.failed.length) s += ` ${t.failed.length} could not be told: ${[...new Set(t.failed)].join('; ')}.`
  if (t.unknown) s += ` The other sessions could not be told: ${t.unknown}.`
  return s
}

// What the modes on make of one tool call: the refusal to answer it with, or undefined to let it run.
type Judged = { tool: string; input: Record<string, unknown>; toolUseId: string; scope: ScopeModesScope | null; away: boolean; asleep: boolean }
const judge = async ($: EngineInterface, j: Judged): Promise<{ deny: string } | undefined> => {
  const { tool, input, toolUseId, scope, away, asleep } = j
  const raw = tool === 'Bash' ? String(input.command ?? '') : ''
  const commands = raw ? await readCommands($, raw) : []

  if (scope === 'NO BUILD') {
    const writes = raw ? await readWrites($, raw) : NO_WRITES
    const r = noBuildRefusal({ tool, input, commands, writes })
    if (r) {
      await $.modkit.blocked({ toolUseId, guard: 'No build', reason: `No build is on, so this would not ${r.what}.`, safeWay: 'Claude asks you: Switch to build?' })
      return {
        deny: `Blocked: no build is on, so this did not ${r.what}.${r.hint ? ` ${r.hint}` : ''} Ask Dan one question by calling mcp__scope-modes__switch_to_build, naming what you would change; carry on with what no build allows until he says yes.`,
      }
    }
  }
  if (scope === 'WINDING DOWN') {
    let t = (await $.state.get(targetRef)).value ?? null
    const opened = await openedOf($)
    let r = newWork({ tool, input, commands, issues: ownNumbers(t, opened) })
    // An agent named after this branch's PR or an issue it closes is this issue's work, so a PR not
    // looked up yet is looked up before the agent is refused (#702).
    if (r && (tool === 'Agent' || tool === 'Task') && t && 'issues' in t && !t.isDefault && t.pr === null) {
      t = await keepFound($, t, (await readWind($, t)).found)
      r = newWork({ tool, input, commands, issues: ownNumbers(t, opened) })
    }
    if (r) {
      await $.modkit.blocked({ toolUseId, guard: 'Winding down', reason: `Winding down, so this would not ${r.what}.`, safeWay: 'Claude finishes this issue and files anything else.' })
      return { deny: `Blocked: winding down, so this did not ${r.what}. Finish this issue; file anything new as an issue instead of working on it.` }
    }
  }
  if (away) {
    // A Bash call by what its commands do on the Mac; another tool by what it opens (#702).
    const label = raw ? needsTheMac({ raw, commands }) : heldTool(tool, input)
    if (label) {
      const { tool: _t, tool_use_id: _id, agentId: _a, consent: _c, ...args } = input
      await hold($, label, `Do it now. What was held: ${raw || `${tool} ${JSON.stringify(args)}`}`)
      const held = heldRefusal(label)
      await $.modkit.blocked({ toolUseId, ...held.card })
      return { deny: held.deny }
    }
  }
  // Asleep (#834): what Dan bans while he sleeps is refused in every session, whatever the
  // permission step beneath would say, since a session's own prompts are approved overnight.
  if (asleep) {
    const what = await overnightWhy($, tool, input)
    if (what) {
      await $.modkit.blocked({ toolUseId, guard: 'Sleep mode', reason: `Dan is asleep, so this would not ${what}.`, safeWay: 'Claude leaves it for the morning and carries on.' })
      return { deny: overnightDeny(what) }
    }
  }
  return undefined
}

// What winding down means, said the same way in its note, its command's context and the Stop
// reason (#856): a session read "start nothing new" as permission to park a PR needing Dan.
// #917: the one way a PR stays open, and only on Dan's own answer, never Claude's reading of one.
const FINALIZE_ALL =
  "Winding down finalizes everything this session has open: every PR it opened is merged, never left open waiting on Dan. A PR stays open only on Dan's own answer to mcp__scope-modes__leave_pr_open, asked when he may want it left (for a reviewer outside this session, say), and a push after he answers asks again. A PR closed without merging is settled only on his answer to the same tool, which then asks whether to leave it closed (its work merged in another PR, say)."
const ASK_THEN_MERGE = 'When a decision or sign off is needed, ask Dan right then with an AskUserQuestion picker, one question at a time, and merge once he answers; never end the turn waiting on him.'

const SCOPE_NOTE: Record<ScopeModesScope, string> = {
  'NO BUILD': 'No build is on: read, research, run tests and checks, write scratchpad notes and do GitHub issue, milestone and label work. No edits outside the scratchpad, commits, branches, PRs, deploys or data changes.',
  'WINDING DOWN':
    `Winding down is on. ${FINALIZE_ALL} Finish this issue and every other PR this session opened (merged, deploy live, worktree and branch cleaned, issues closed) and start nothing new. ${ASK_THEN_MERGE} Fix only what blocks a merge or deploy; file anything else. After each merge, check the deploy and make the is it live card (mcp__is-it-live__card): winding down finishes only once that card says Live or no deploy step recorded.`,
}
const AWAY_NOTE =
  'Dan is away from the Mac. Deliver results as a private claude.ai page he can read on his phone (the Artifact tool). Open nothing on the Mac and take no focus: anything that needs him at the Mac is held for when he is back.'
// What Claude is told on each prompt while the Mac sleeps: only what phase 1 does (L703).
const sleepPromptNote = (r: SleepRecord, self: string) =>
  `Sleep mode is on until ${etWhen(r.until)}. ${r.workers?.includes(self) ? `This session is enrolled to work overnight. ${WORKER_NOTE}` : 'This session is not one of the overnight workers.'} Dan is asleep, so deliver as when he is away: ${AWAY_NOTE}`
// What phase 3 (#834) does for a worker, and only that (L703).
const WORKER_NOTE =
  "Its permission prompts are approved by themselves, except a question for Dan, the plan approval and what Dan bans while he sleeps, which are refused with the reason. A refusal, by that list or by the auto mode classifier, is final: never look for another way to do it; skip that issue."
const HOME_NOTE = 'Dan is back at the Mac: deliver results as CLAUDE.md says (HTML in Chrome, drafts in BBEdit, images and PDFs in Preview).'

export const register: Register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    // Asleep (#840) keeps every session quiet as away, whatever its own place. The engine refuses
    // handing `built` to a helper, so the record is read here with its own calls, through the same
    // readSleep every other decision asks; a read that fails is awake, as readSleep's unreadable is.
    const nounReading = async (): Promise<{ home: string; reading: SleepReading } | null> => {
      try {
        const home = await built.env.get('HOME')
        if (!home) return null
        const current = `${sleepDir(home)}/current.json`
        if (!(await built.fs.exists(current))) return { home, reading: { state: 'none' } }
        const text = await built.fs.read(current)
        // Under Claude Code's 10 s cut off for a noun call (#744); sysctl answers in milliseconds.
        for (const oid of bootUnread()) keepBoot(oid, await built.process.run(['sysctl', '-n', oid], { timeoutMs: BOOT_MS }))
        return { home, reading: readSleep(text, await built.clock.now(), bootNow()) }
      } catch {
        return null
      }
    }
    const nounSeesAsleep = async (): Promise<boolean> => (await nounReading())?.reading.state === 'asleep'
    const scopeModes: ScopeModes = {
      isAway: async () => ((await built.state.get(placeRef)).value ?? 'home') === 'away' || (await nounSeesAsleep()),
      hold: async ({ label, prompt }) => {
        if (((await built.state.get(placeRef)).value ?? 'home') !== 'away' && !(await nounSeesAsleep())) return { isHeld: false }
        const held = (await built.state.get(heldRef)).value ?? []
        if (!held.some(h => h.prompt === prompt)) {
          const seq = ((await built.state.get(heldSeqRef)).value ?? 0) + 1
          await built.state.set(heldSeqRef, seq)
          await built.state.set(heldRef, [...held, { id: String(seq), label, prompt }])
        }
        return { isHeld: true, ...heldRefusal(label) }
      },
      isAsleep: nounSeesAsleep,
      sleepNote: async note => {
        const seen = await nounReading()
        if (seen?.reading.state !== 'asleep') return { isNoted: false }
        const line = { ...note, at: await built.clock.now(), by: await built.session.id() }
        // Under Claude Code's 10 s cut off for a noun call (#744); one appended line takes milliseconds.
        const r = await built.process.run(noteArgv(seen.home, `${sleepDir(seen.home)}/current.json`, line), { timeoutMs: BOOT_MS })
        if (r.exitCode !== 0) throw new Error(noteFailure(r))
        return { isNoted: true }
      },
    }
    return { ...built, scopeModes }
  })

  on('session.start', async ($, e, next) => {
    for (const [name, description] of [
      ['nobuild', 'No build: read, research and file only, until /build.'],
      ['winddown', 'Wind down: finish this issue, start nothing new, then stop.'],
      ['build', 'Turn no build or winding down off.'],
      ['away', "Away: every session publishes pages for the phone and opens nothing on the Mac."],
      ['home', 'Home: every session delivers on the Mac again.'],
      ['sleep', 'Sleep: the whole Mac goes quiet until noon ET tomorrow; interactive sessions are enrolled to work overnight.'],
      ['wake', 'Wake: sleep mode off, every session back where it was.'],
    ] as const)
      await $.command.register({ name, description, immediate: true })
    interactive = e.isInteractive === true
    await $.tool.register({
      name: 'switch_to_build',
      description:
        'While no build is on, ask Dan whether to switch to build. Name the change you would make. Only his yes turns no build off; call it once after a no build refusal, never again for the same change after a no.',
      inputSchema: { type: 'object', properties: { change: { type: 'string', description: 'What you would change, as a short phrase ("edit app.ts to fix the date parse")' } }, required: ['change'] },
    })
    await $.tool.register({
      name: 'leave_pr_open',
      description:
        "Ask Dan whether a PR stays as it is rather than being merged, the question following the PR's state on GitHub: an open PR left open, for when he may want it left (a reviewer outside this session, say), or a PR closed without merging left closed (its work merged in another PR, say). Only his \"Leave it open\" (recorded against the PR's current head, and settled until it is pushed to again) or \"Leave it closed\" (settled unless it is reopened) is recorded. Every other PR is merged; never call this to end a turn sooner.",
      inputSchema: {
        type: 'object',
        properties: {
          pr: { type: 'number', description: 'The PR number' },
          repo: { type: 'string', description: "The PR's repository as owner/name; this session's own when left out" },
          why: { type: 'string', description: 'Why it would be left as it is, as a short phrase ("awaiting Denys\'s review", "its work merged as #716")' },
        },
        required: ['pr', 'why'],
      },
    })
    if (!ticking) {
      ticking = true
      // Winding down ends itself once it is live, watched each minute rather than only at turn end.
      $.clock.every(MIN, async () => {
        try {
          const c = await check($)
          if (c && c.left.length === 0) await finish($, c.kept)
        } catch (err) {
          $.ui.log(`scope-modes: the wind down check failed: ${msg(err)}`, { to: 'debug' })
        }
        // Sleep's record read each minute too: the first session to find it over ends it, and the
        // band follows it on and off whichever session started or ended it (#840).
        let seen: SleepReading = { state: 'none' }
        try {
          const reading = await sleepNow($)
          seen = reading
          await endIfOver($, reading)
          if ((reading.state === 'asleep') !== shownAsleep) {
            await showModes($)
            await showHeld($)
          }
        } catch (err) {
          $.ui.log(`scope-modes: the sleep check failed: ${msg(err)}`, { to: 'debug' })
        }
        // The overnight driver's minute (#844): a wait that is over, and a claim held too long.
        try {
          if (seen.state === 'asleep') await driverTick($, seen)
        } catch (err) {
          $.ui.log(`scope-modes: the overnight driver's minute failed: ${msg(err)}`, { to: 'debug' })
        }
      })
    }
    const started = await next(e)
    await announce($)
    // The band shows ASLEEP from the start in a session opened while the Mac sleeps.
    if (await isAsleep($)) await showModes($)
    return started
  })

  // The commands, which say which mode turned on, and confirm the off.
  on('command.run', { command: 'nobuild' }, async $ => {
    await setScope($, 'NO BUILD')
    return { text: 'No build is on.', context: [`Dan turned on no build. ${SCOPE_NOTE['NO BUILD']}`] }
  })
  on('command.run', { command: 'winddown' }, async $ => {
    await setScope($, 'WINDING DOWN')
    return { text: 'Winding down is on.', context: [`Dan turned on winding down. ${SCOPE_NOTE['WINDING DOWN']}`] }
  })
  on('command.run', { command: 'build' }, async $ => {
    const scope = await scopeOf($)
    if (!scope) return { text: 'No scope mode was on.' }
    await setScope($, null)
    return { text: `${SCOPE_NAME[scope]} is off.`, context: [`Dan turned ${SCOPE_NAME[scope].toLowerCase()} off: build as usual.`] }
  })
  on('command.run', { command: 'sleep' }, async $ => ({ text: await startSleep($) }))
  on('command.run', { command: 'wake' }, async ($, e) => {
    const woke = await wake($, e.origin.kind === 'bridge')
    if (!woke) return { text: 'Sleep mode was not on.' }
    // The morning turn starts once the command is done: from inside command.run the prompt would
    // wait on the turn this hook holds (as /handoff found).
    const morning = woke.morning
    if (morning) $.clock.after(0, () => void $.prompt.submit({ text: morning }).catch(err => $.ui.toast(`Sleep mode is off, but the morning summary and pickers could not start: ${msg(err)}`)))
    return { text: woke.said }
  })
  on('command.run', { command: 'away' }, async $ => {
    await setPlace($, 'away')
    return { text: placeSentence('away', await tellOthers($, 'away')) }
  })
  on('command.run', { command: 'home' }, async $ => {
    await setPlace($, 'home')
    return { text: placeSentence('home', await tellOthers($, 'home')) }
  })

  // Dan's own words switch modes; every prompt carries what is on, so Claude never guesses. A
  // message typed while a turn runs fires here too, at Enter, with that turn's id, as the engine's
  // types document it (PromptSubmitInput.turnId), and is read the same way (#805). That delivery is
  // the engine's documented behaviour, not yet seen live: the tests stand in for the engine, so the
  // debug log line below records each mid turn message from Dan and how many modes it switched.
  on('prompt.submit', async ($, e, next) => {
    lastOrigin = e.origin.kind
    // Said again once a turn has run, since the registry may not have had this session's record at start.
    if (!announced) {
      announced = true
      await announce($)
    }
    const notes: string[] = []
    if (isDans(e.origin)) {
      const triggers = triggersIn(e.text) as Trigger[]
      for (const t of triggers) {
        if (t.kind === 'scope') {
          await setScope($, t.scope)
          notes.push(`${SCOPE_NAME[t.scope]} just turned on from Dan's message. Say so in one line first.`)
        } else if (t.kind === 'build') {
          const was = await scopeOf($)
          if (was) {
            await setScope($, null)
            notes.push(`${SCOPE_NAME[was]} just turned off from Dan's message. Say so in one line first.`)
          }
        } else if (t.kind === 'off') {
          // Off by name turns off only the mode it names.
          if ((await scopeOf($)) === t.scope) {
            await setScope($, null)
            notes.push(`${SCOPE_NAME[t.scope]} just turned off from Dan's message. Say so in one line first.`)
          }
        } else if (t.kind === 'wake') {
          const woke = await wake($, e.origin.kind === 'bridge')
          // What waking found quotes titles of issues, milestones and commits made overnight, so it
          // reaches this turn only as data (#922).
          if (woke)
            notes.push(
              `Dan's message woke sleep mode. Say so in one line first, saying what the block below says.\n${overnightData({ holds: 'what waking sleep mode did and found, which can quote titles of issues, milestones and commits made overnight', offer: 'said to Dan in that one line; it is offered to him through no picker', lines: [woke.said] })}`,
            )
          // This turn is the morning one (#837): its summary and pickers ride along.
          if (woke?.morning) notes.push(woke.morning)
        } else {
          await setPlace($, t.place)
          const told = await tellOthers($, t.place)
          notes.push(`Dan's message switched every session to ${t.place}. Say so in one line first: "${placeSentence(t.place, told)}"`)
        }
      }
      // Every note so far is a switch the message made; the still on note below switches nothing.
      const switched = notes.length
      // A message asking to end the mode still on, in words that did not switch it, is said rather than
      // left for Claude to read as switched: the hook would go on enforcing a mode Claude thinks is off.
      const stillOn = await scopeOf($)
      const askedOff = stillOn && !triggers.some(t => t.kind !== 'place') && scopesAskedOffIn(e.text).includes(stillOn)
      if (stillOn && askedOff) {
        const name = SCOPE_NAME[stillOn].toLowerCase()
        notes.push(`Dan's message names ${name}, but not in words that switch it, so ${name} is still on. If he meant to turn it off, say in one line first that ${name} is still on and /build turns it off; never act as though it were off.`)
      }
      if (e.turnId !== undefined)
        $.ui.log(`scope-modes: a message from Dan sent mid turn reached the mod: switched ${switched}, still on note ${askedOff ? 'added' : 'not added'}`, { to: 'debug' })
    }
    const scope = await scopeOf($)
    if (scope) notes.push(SCOPE_NOTE[scope])
    let asking: string | undefined
    const sleeping = await sleepNow($)
    if (sleeping.state === 'asleep') {
      notes.push(sleepPromptNote(sleeping.record, await $.session.id()))
      // Only /wake or "I'm up" ends sleep (#837, decision 9): Dan writing in the daytime is asked
      // whether he is up, once a night in each session, and sleep goes on until he says so. It counts
      // as asked only once the prompt carrying it went in (below), so a prompt that failed asks again.
      if (isDans(e.origin) && askedUp !== sleeping.record.generation) {
        const now = await $.clock.now()
        if (isDaytimeEt(now)) {
          asking = sleeping.record.generation
          notes.push(awakeAsk(etWhen(now)))
        }
      }
    } else if ((await placeOf($)) === 'away') notes.push(AWAY_NOTE)
    else if ((await $.state.get(justHomeRef)).value) {
      notes.push(HOME_NOTE)
      await $.state.set(justHomeRef, false)
    }
    const entered = await next(notes.length ? { ...e, context: [...(e.context ?? []), ...notes] } : e)
    if (asking !== undefined) askedUp = asking
    return entered
  })

  // A message from the phone while home: one line at the end of the reply (picker, 2026-10-04).
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined || e.reason !== 'answer') return r
    if (lastOrigin === 'bridge' && (await placeOf($)) === 'home') return { ...r, text: PHONE_LINE }
    return r
  })

  // The switch arriving from another session's scope modes: applied, and taken, so it never reaches
  // the model as a message. The plugin field is the sender's claim; the worst a forged one can do
  // is switch where this session delivers, which the band then shows.
  on('session.receive', async ($, e, next) => {
    const origin = e.origin as { plugin?: string }
    if (origin.plugin === MOD && (e.text === AWAY_TEXT || e.text === HOME_TEXT)) {
      await setPlace($, e.text === AWAY_TEXT ? 'away' : 'home')
      return { consumed: `scope-modes: switched to ${e.text === AWAY_TEXT ? 'away' : 'home'} from another session` }
    }
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const input = e as unknown as Record<string, unknown>
    const tool = String(e.tool)
    const toolUseId = String(input.tool_use_id ?? '')

    if (tool === 'mcp__scope-modes__switch_to_build') {
      // Answered here and never passed down, so the guards beneath (the secret guard) are asked
      // through mod-kit's screen before the change is shown to Dan in the question (#707).
      const refused = await $.modkit.screen(e)
      if (refused) return refused
      if ((await scopeOf($)) !== 'NO BUILD') return { result: 'No build is not on.', text: 'No build is not on.' }
      const change = String(input.change ?? '').trim().replace(/[.?]+$/, '') || 'make a change'
      const question = `Claude wants to ${change}. Switch to build?`
      // Dan is asked nothing while asleep (#841): the request waits for his morning report.
      const sleeping = await sleepNow($)
      if (sleeping.state === 'asleep') {
        const failed = await noteQuestion($, [question])
        const text = `Dan is asleep (sleep mode), so he was not asked: no build stays on. ${
          failed === null ? 'The request is noted for his morning report.' : `It could not be noted for his morning report (${failed}), so put it in your final message.`
        }`
        return { result: text, text }
      }
      let answer: string
      try {
        answer = await $.ui.ask(question, ['Yes', 'No'])
      } catch (err) {
        const text = `Dan was not asked (${msg(err)}): no build stays on.`
        return { result: text, text }
      }
      if (answer === 'Yes') {
        await setScope($, null)
        await $.ui.toast('No build is off.')
        return { result: 'Dan said yes: no build is off.', text: 'Dan said yes: no build is off.' }
      }
      const text = `Dan said no: no build stays on.${answer !== 'No' ? ` He wrote: ${answer}` : ''}`
      return { result: text, text }
    }

    if (tool === 'mcp__scope-modes__leave_pr_open') {
      // Answered here, after mod-kit's screen, as switch_to_build is (#707): the reason is shown to Dan.
      const refused = await $.modkit.screen(e)
      if (refused) return refused
      const text = await leavePrOpen($, input)
      return { result: text, text }
    }

    // A call that may open a PR is watched whatever mode is on, so winding down later knows what this
    // session opened. The words are a cheap first look; the reader decides.
    const raw = tool === 'Bash' ? String(input.command ?? '') : ''
    const mayOpen = /\bgh\b/.test(raw) && /\bpr\b/.test(raw) && /\bcreate\b/.test(raw)
    const go = async () => {
      const r = await next(e)
      if (mayOpen && !r.deny) await noteOpened($, raw, r)
      return r
    }

    const scope = await scopeOf($)
    // Asleep (#840), read live at each call, keeps every session quiet as away.
    const sleeping = await sleepNow($)
    // Asleep, a merge, a deploy or a push to a default branch is judged against the night's lists
    // (#843), first, before any other mode's route or early return, so nothing reaches a merge
    // unjudged. A check that throws refuses, as below (L42).
    if (sleeping.state === 'asleep' && raw) {
      let over: Awaited<ReturnType<typeof mergeDeployRefusal>>
      try {
        over = await mergeDeployRefusal($, sleeping.record.repos, await readCommands($, raw))
      } catch (err) {
        over = { deny: `Blocked overnight: the merge and deploy check of this call failed (${msg(err)}), so it did not run. Leave it for the morning and note it.`, what: 'run a call the check could not judge', why: msg(err) }
      }
      if (over) {
        await noteFirstMet($, sleeping.record, over)
        await $.modkit.blocked({ toolUseId, guard: 'Asleep', reason: `Asleep, so this would not ${over.what}: ${over.why}.`, safeWay: 'Claude leaves it for the morning report.' })
        return { deny: over.deny }
      }
    }

    // And asks Dan nothing (#841): a question is noted for his morning report and Claude skips it,
    // in every session, a worker or not. A question any other mod or hook leads Claude to ask
    // arrives here too, so this is the one place a question to Dan is stopped overnight.
    if (tool === 'AskUserQuestion' && sleeping.state === 'asleep') {
      const qs = Array.isArray(input.questions) ? (input.questions as { question?: unknown }[]).map(q => String(q?.question ?? '')) : []
      const failed = await noteQuestion($, qs)
      await $.modkit.blocked({ toolUseId, guard: 'Asleep', reason: 'Dan is asleep, so this question waits for his morning report.', safeWay: 'Claude carries on with work that does not need him.' })
      return { deny: askedAsleep(failed) }
    }
    const asleep = sleeping.state === 'asleep'
    const away = (await placeOf($)) === 'away' || asleep
    if (!scope && !away) return go()

    // A judge that throws refuses the call rather than letting it through: a tool call hook that
    // fails is skipped, which would run the very thing the mode is on to stop (L42).
    let refused: { deny: string } | undefined
    try {
      refused = await judge($, { tool, input, toolUseId, scope, away, asleep })
    } catch (err) {
      const modes = [...(scope ? [SCOPE_NAME[scope].toLowerCase()] : []), ...(asleep ? ['sleep mode'] : away ? ['away'] : [])].join(' and ')
      refused = { deny: `Blocked: ${modes} is on and its check of this call failed (${msg(err)}), so the call did not run. Try it again; if it fails the same way, tell Dan.` }
    }
    return refused ?? go()
  })

  // A held row's button: asks Claude to do that one thing, now that Dan is here and chose it. Pressed
  // by a click or by /press (#939): mod-kit raises both as modkit.press.
  on('modkit.press', ($, e, next) => {
    const prefix = `${MOD}:held-`
    if (!e.element.startsWith(prefix)) return next(e)
    const id = e.element.slice(prefix.length)
    // Taken at once and done just after: a noun's call is cut off at 10 s (#744).
    $.clock.after(0, () => {
      void (async () => {
        const held = await heldOf($)
        const item = held.find(h => h.id === id)
        if (!item) return
        await $.state.set(heldRef, held.filter(h => h.id !== id))
        await showHeld($)
        await $.prompt.submit({ text: `Dan is back and picked this from what was held while he was away: ${item.label}. ${item.prompt}` })
      })().catch(err => $.ui.toast(`That held row did not finish: ${msg(err)}`))
    })
    return { value: { isAnswered: true } }
  })

  // Sleep mode phase 3 (#834, Dan's decision 7): overnight, Claude Code's own permission prompts in
  // an enrolled session are approved, while Dan's own checks stay on (the settings hooks and every
  // mod's tool.call refusal run before this step, and a decision beneath is never overridden). Never
  // approved: a question, the plan approval, and what Dan bans while he sleeps (overnight.ts). The
  // record is read live, and one that cannot be read is awake: no approval (L42). A session that is
  // not a worker is only kept quiet, so its prompts wait for Dan as always.
  on('classic.PermissionRequest', async ($, e, next) => {
    // Any throw in deciding whether this session is an asleep worker reads as awake: no approval.
    let worker = false
    try {
      const reading = await sleepNow($)
      worker = reading.state === 'asleep' && (reading.record.workers?.includes(await $.session.id()) ?? false)
    } catch (err) {
      // Said, never silent: a session that waits on Dan overnight leaves the reason in its log.
      $.ui.log(`scope-modes: whether this session is an overnight worker could not be read (${msg(err)}), so this prompt was not approved`, { to: 'debug' })
      worker = false
    }
    if (!worker) return next(e)
    const tool = String(e.tool_name)
    if (NEVER_ASKED.has(tool))
      return { decision: { behavior: 'deny', message: `Refused: Dan is asleep, so ${tool === 'ExitPlanMode' ? 'no plan is approved' : 'nothing is asked'} overnight. Leave the question on the issue for the morning and skip this issue.` } }
    // A call that cannot be judged is never approved: it is left to the prompt, as when Dan is
    // awake, and one `unmeasured` note says so in the morning report (#834 review of edeb682).
    const leave = async (text: string) => {
      try {
        await sleepNote($, (await sleepPaths($)).current, { kind: 'unmeasured', at: await $.clock.now(), by: await $.session.id(), tool, text })
      } catch (err) {
        $.ui.log(`scope-modes: ${text}, and the note could not be written (${msg(err)})`, { to: 'debug' })
      }
      return next(e)
    }
    const input = (e.tool_input ?? {}) as Record<string, unknown>
    if (tool === 'Bash' && !String(input.command ?? '').trim()) return leave('a Bash permission prompt with no command was left for Dan')
    let what: string | undefined
    try {
      what = await overnightWhy($, tool, input)
    } catch (err) {
      return leave(`a permission prompt for ${tool} could not be judged overnight (${msg(err)}), so it was left for Dan`)
    }
    if (what) return { decision: { behavior: 'deny', message: overnightDeny(what) } }
    const beneath = await next(e)
    if (beneath.decision) return beneath
    return { ...beneath, decision: { behavior: 'allow' } }
  })

  // A refusal by the auto mode classifier while asleep (#834) is final: a `failed` note naming the
  // reason, and never a retry, whatever beneath asked for.
  on('classic.PermissionDenied', async ($, e, next) => {
    const reading = await sleepNow($)
    if (reading.state !== 'asleep') return next(e)
    try {
      await sleepNote($, (await sleepPaths($)).current, {
        kind: 'failed',
        at: await $.clock.now(),
        by: await $.session.id(),
        cwd: await $.session.cwd(),
        tool: e.tool_name,
        text: `the auto mode classifier refused ${e.tool_name}: ${e.reason}`,
      })
    } catch (err) {
      $.ui.toast(`Sleep mode: a refused call could not be noted for the report (${msg(err)})`)
    }
    const { retry: _retry, ...rest } = await next(e)
    return rest
  })

  // Winding down refuses the turn end until finished; Claude keeps watching CI and the deploy.
  on('classic.Stop', async ($, e, next) => {
    // An enrolled session while the Mac sleeps is the overnight driver's (#844): kept working, or let go with a note.
    const driven = await driveStop($)
    if (driven !== 'not-driven') return driven ?? next(e)
    const c = await check($)
    if (c === null) return next(e)
    if (c.left.length === 0) {
      await finish($, c.kept)
      return next(e)
    }
    // A PR Dan chose to leave open (#917) or closed (#1033) is said apart, never as outstanding.
    const kept = keptSaid(c.kept, "Dan's")
    return {
      block: `Winding down is not finished: ${c.left.join('; ')}.${kept} ${FINALIZE_ALL} Keep watching CI and the deploy, fix only what blocks a merge or deploy, and file anything else. ${ASK_THEN_MERGE}`,
    }
  })

  // A turn that ended on an API error, while an enrolled session works overnight: waited out or stopped (#844).
  on('classic.StopFailure', async ($, e, next) => {
    // Only while asleep: awake, a failed turn is Dan's to see, and nothing here acts or notes.
    if (!(await isAsleep($))) return next(e)
    try {
      await driveFailure($, String(e.error), e.last_assistant_message ?? '')
    } catch (err) {
      $.ui.log(`scope-modes: the overnight driver could not handle the ${e.error} error: ${msg(err)}`, { to: 'debug' })
    }
    return next(e)
  })

  // Off automatically at session end, never carried into a new session.
  on('session.end', async ($, e, next) => {
    await $.state.set(scopeRef, null)
    await $.state.set(targetRef, null)
    await $.state.set(openedRef, [] as ScopeModesOpened[])
    await $.state.set(leftOpenRef, [] as ScopeModesLeftAsIs[])
    await $.state.set(placeRef, 'home')
    await $.state.set(justHomeRef, false)
    await $.state.set(heldRef, [] as ScopeModesHeld[])
    lastOrigin = undefined
    await showModes($)
    await showHeld($)
    return next(e)
  })
}
