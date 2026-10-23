import type { EngineInterface, Register } from 'claude-code'
import type { ModKitWrites } from '../.claude-plugin/types/mod-kit/index.d.ts'
import type {
  ScopeModes,
  ScopeModesCleanup,
  ScopeModesHeld,
  ScopeModesLeftAsIs,
  ScopeModesLeftBranch,
  ScopeModesOpened,
  ScopeModesPlace,
  ScopeModesScope,
  ScopeModesTarget,
} from '../types/index.d.ts'
import { awayAllows, heldCard, heldRefusal, heldTool, isTestBuild, needsTheMac, typedTarget, type TestBuildFs } from './away.ts'
import { EDITORS, ghWords, noBuildRefusal, type Cmd } from './nobuild.ts'
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
  goalAnswer,
  goalOptions,
  goalIssues,
  goalQuestion,
  groupQuestions,
  sameText as oneSpaced,
  orderQuestions,
  priorityRank,
  questionsIn,
  SKIP_QUESTION,
  unansweredText,
  type IssueQuestion,
  type OpenQuestion,
} from './bedtime.ts'
import {
  LIMITS, REST_RESUME, RESUME, SLEEP_START, activeMs, blockTold, decideFailure, decideStop, driverPath, freshDriver, heldClaim, overnightRules, progressOf, readDriver, releaseTold, resumeDue, startPrompt, thenNext,
  type ClaimReading, type DriverReading, type DriverRecord, type Note, type Release,
} from './driver.ts'
import { overnightData } from './overnightdata.ts'
import { errorText, missingOf, skewNews } from './mod-kit/skew.ts'
import { openQuestionsIn, withQuestion } from './mod-kit/openquestions.ts'
import { askAnyAccount } from './mod-kit/ghaccounts.ts'
import { answeredLook, failedLook, nextWaitMs, pollLib, takeLook, type Poll } from './mod-kit/ghpoll.ts'
import { bootOf, bootSessionOf, endSaid, etDate, etWhen, goalOf, isDaytimeEt, nightOf, notesOf, readSleep, sleepDir, untilOf, type Boot, type SleepReading, type SleepRecord } from './sleep.ts'
import {
  awakeAsk,
  BBEDIT,
  keyFile,
  LESSONS_KEY,
  MORNING_UNANSWERED,
  morningPrompt,
  openers,
  openLater,
  othersSaid,
  proposalsIn,
  repoKey,
  UNATTRIBUTED,
  type FiledProposal,
  type NightQuestion,
  type ProposedIssue,
} from './wake.ts'
import { claimEntry, closeMatchIn, declinedEntry, declinedIn, filedEntry, issueLinkIn, judgeProposal, proposalPath, type ProposalState } from './proposals.ts'
import { ENDED_SAID, MORNING_HEADING, morningStep, pickerAnswered, reviewsIn, stalePending, withDone, withPending, type MorningReview } from './morning.ts'
import { alreadyPut, ASLEEP_DELIVERY, deliveryOf, heldAsleep, heldUntilWake, type HeldDelivery, type HeldMerge, type PutMorning } from './nightheld.ts'
import { reportBase, reportTitle } from './reportname.ts'
import { scopesAskedOffIn, triggersIn, type Trigger } from './triggers.ts'
import { acknowledge, ackOff, ackOffSaid, ackOn, ackOnSaid, MODE_DEF } from './modes.ts'
import {
  branchChoiceFor,
  branchesTouched,
  choiceFor,
  CLEANUP_TOOL,
  filesSaid,
  filesWritten,
  isLeftClosed,
  LEAVE_BRANCH_TOOL,
  NEW_WORK,
  newBranchOf,
  newWork,
  outstanding,
  patchedPaths,
  porcelainFiles,
  settledByBranchChoice,
  settledByDan,
  stashTaken,
  whoseFiles,
  type DeployState,
  type Reading,
} from './winddown.ts'

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
const branchesRef = { plugin: 'scope-modes', key: 'branches' } as const
const leftBranchRef = { plugin: 'scope-modes', key: 'leftBranch' } as const
const cleanupRef = { plugin: 'scope-modes', key: 'cleanup' } as const
const writtenRef = { plugin: 'scope-modes', key: 'written' } as const
const wakeHeldRef = { plugin: 'scope-modes', key: 'wakeHeld' } as const
const nightSeenRef = { plugin: 'scope-modes', key: 'nightSeen' } as const
const morningPutRef = { plugin: 'scope-modes', key: 'morningPut' } as const
const morningUnansweredRef = { plugin: 'scope-modes', key: 'morningUnanswered' } as const

// Where the last prompt came from, so the turn it started knows whether Dan wrote it on his phone.
let lastOrigin: string | undefined
let ticking = false
let statusNoted = false
// One finish check at a time: the turn end and the minute's tick share whichever is running, except
// that a turn end, which asks GitHub afresh (#1037), never takes a minute's check that may not have.
let checking: Promise<Checked | null> | undefined
let checkingFresh = false
// What the finish check found: what is still to do, the PRs settled by being left as they are on
// Dan's own choice, open (#917) or closed (#1033), and the branches he chose to leave as they are
// (#1074), each said apart from what is outstanding, and the uncommitted files this session did not
// write (#1108), said once it finishes.
type Checked = { left: string[]; kept: ScopeModesLeftAsIs[]; keptBranches: ScopeModesLeftBranch[]; notMine?: string[] }

// An error as words, a member another mod's loaded copy lacks said as the one sentence naming the
// skew and its remedy (#1281, mod-kit's hooks/skew.ts, of which hooks/mod-kit/skew.ts is the copy).
const msg = (err: unknown) => errorText(err, MOD)
// A skew this load of the mod met in the overnight check (#1281): every call is refused while it
// lasts, and the driver reads it at the next Stop. Kept in the module, so a reload, which is what
// can mend it, starts it over.
let skewMet: string | null = null
// What a skew costs the notes winding down reads, said with it once (#1281 lessons review).
const NOTES_LOST = 'Until then scope modes cannot note the branches this session makes or the PRs it opens, so winding down may not finish them.'
// What isTestBuild asks of the Mac (#1269), for a tool call; the noun reads the same in place, since
// the engine refuses handing `built` to a helper. A home that cannot be read is unknown, which
// isTestBuild reads as any folder in /Users.
const testBuildFs = async ($: EngineInterface): Promise<TestBuildFs> => {
  let home: string | undefined
  try {
    home = await $.env.get('HOME')
  } catch {
    home = undefined
  }
  return { home, treeOf: path => $.modkit.workingTree({ path }) }
}

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
// The one helper, mod-kit's hooks/ghaccounts.ts, copied here (#1279 lessons review).
const ghAnyAccount = ($: EngineInterface, args: string[], tryNext: (r: GhRun) => boolean = () => true, stdin?: string): Promise<{ stdout: string } | { failures: GhRun[] }> =>
  askAnyAccount((argv, env, input) => run($, argv, RUN_MS, env, input), args, tryNext, stdin)

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

// A lock in the sleep folder taken for a writer of a shared file, waiting on another writer up to
// LOCK_WAIT_MS: the answers lock, and the morning reviews' (#1107).
const takeLock = async ($: EngineInterface, lock: string): Promise<Claim> => {
  await run($, ['mkdir', '-p', lock.slice(0, lock.lastIndexOf('/'))])
  const waitUntil = (await $.clock.now()) + LOCK_WAIT_MS
  for (;;) {
    const claim = await claimMarker($, lock, LOCK_STALE_MS)
    if (!('held' in claim) || (await $.clock.now()) >= waitUntil) return claim
    await $.clock.sleep(1_000)
  }
}

// A bedtime answer written into the shared file under the answers lock, so a late answer and
// another never read the same file and write over each other; whole beside it and moved into place,
// so a reader never sees half a file. The sync carries it to the other Mac, so each repository is
// asked once.
const recordAnswer = async ($: EngineInterface, path: string, repo: string, answer: string): Promise<string | null> => {
  const lock = `${sleepDir((await $.env.get('HOME')) ?? '')}/repos.lock`
  const claim = await takeLock($, lock)
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

// The repository each overnight worker is in, from its folder, by session; null for none. A folder
// mod-kit's reader cannot read is never dropped, which would leave its repository unasked at
// bedtime: it is said.
const workerRepos = async ($: EngineInterface, seats: Seat[]): Promise<Map<string, string | null> | { unread: string }> => {
  const out = new Map<string, string | null>()
  for (const s of seats) {
    if (!s.root) {
      out.set(s.id, null)
      continue
    }
    const f = await folderRepoRead($, s.root)
    if ('unread' in f) return f
    out.set(s.id, f.repo)
  }
  return out
}

// The repositories worked tonight, each once: only the workers with a goal work (#1242).
const reposWorked = (bySeat: Map<string, string | null>, goals: Record<string, string>) => {
  const out = new Map<string, string>()
  for (const [id, slug] of bySeat) if (slug && Object.hasOwn(goals, id) && !out.has(slug.toLowerCase())) out.set(slug.toLowerCase(), slug)
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

// ---- Each worker's goal (#1242) ----
// Dan, 2026-10-16: "it should just work with the built in /goal ... If there's no goal set, prompt me
// to set one and then only work the goal. No random issues." Each worker's goal is read from its
// transcript by mod-kit's one reader of a /goal ($.modkit.goal, #1252, which the goal tracker reads
// too), and a worker with none is asked for one first among the before bed questions, sharing their
// ten minutes: what Dan types is its goal. Left without one, it does no work tonight, and /sleep and
// the morning report say so. A reader that fails is said, as no goal, and so is a mod-kit loaded
// before it had the reader: asked inside the promise, the TypeError thrown at the call is caught too.
type GoalRead = { goal: string } | { none: string }
const readGoal = async ($: EngineInterface, seat: Seat, who: string): Promise<GoalRead> => {
  if (!seat.transcript) return { none: `${who}'s transcript was not found` }
  const transcript = seat.transcript
  const g = await Promise.resolve()
    .then(() => $.modkit.goal({ transcript }))
    .catch(err => ({ state: 'unreadable' as const, why: msg(err) }))
  if (g.state === 'unreadable') return { none: `${who}'s /goal could not be read (${g.why})` }
  return g.state === 'set' ? { goal: g.condition } : { none: `${who} has no /goal set` }
}

// Who a goal question is about, as Dan knows the session: its repository and what he asked of it.
const seatName = (seat: Seat, self: string, repo: string | null) =>
  seat.id === self ? 'this session' : `${repo ? `the session in ${repo}` : 'another session'}${seat.request ? ` ("${seat.request}")` : ''}`

// `names` is how /sleep names each worker that has a goal, for telling it to start.
type GoalRound = { goals: Record<string, string>; names: Record<string, string>; said: string }
const settleGoals = async ($: EngineInterface, seats: Seat[], repos: Map<string, string | null>, self: string, round: Round): Promise<GoalRound> => {
  const goals: Record<string, string> = {}
  const names: Record<string, string> = {}
  const set: string[] = []
  const without: string[] = []
  const unread: string[] = []
  for (const seat of seats) {
    const who = seatName(seat, self, repos.get(seat.id) ?? null)
    const read = await readGoal($, seat, who)
    if ('goal' in read) {
      goals[seat.id] = read.goal
      names[seat.id] = who
      set.push(`${who}, "${read.goal}"`)
      continue
    }
    // A goal set but unreadable is said apart, so Dan is not left wondering why he was asked.
    if (!/ has no \/goal set$/.test(read.none)) unread.push(read.none)
    const left = round.until - (await $.clock.now())
    let why: string | null = null
    if (!interactive) why = 'nobody was at this session to ask'
    else if (round.slept) why = 'not asked: you chose to go to sleep first'
    else if (left <= 0) why = 'not asked: the 10 minutes for bedtime questions ran out'
    if (why) {
      without.push(`${who} (${why})`)
      continue
    }
    const asked = await askOne($, goalQuestion(who), goalOptions(), BEDTIME_HEADER, left, async a => {
      // Answered after the wait: the night has begun without it, so it is said, never kept silently.
      if (goalAnswer(a).goal !== null) $.ui.toast(`Your goal for ${who} came after the 10 minutes, so it does no work tonight. Set it there with /goal before the next /sleep.`)
    })
    if ('unanswered' in asked) {
      without.push(`${who} (not answered in 10 minutes)`)
      continue
    }
    if ('failed' in asked) {
      without.push(`${who} (the question was dismissed or could not be shown: ${asked.failed})`)
      continue
    }
    const a = goalAnswer(asked.answer)
    if (a.slept) {
      round.slept = true
      without.push(`${who} (you chose to go to sleep first)`)
      continue
    }
    if (a.goal === null) {
      without.push(`${who} (you chose no work for it)`)
      continue
    }
    goals[seat.id] = a.goal
    names[seat.id] = who
    set.push(`${who}, "${a.goal}"`)
  }
  let said = ''
  if (set.length) said += ` Tonight's goals: ${set.join('; ')}.`
  if (without.length) said += ` No goal, so no work tonight: ${without.join('; ')}.`
  if (unread.length) said += ` Read as no goal because ${andList(unread)}.`
  return { goals, names, said }
}

// ---- Sleep mode phase 6 (#836): the before bed questions about the queue's issues ----
// Which questions, in what order, and what is posted are bedtime.ts's; here they are read, asked,
// posted and written down.

type Left = { repo: string; issue: number; text: string; why: string }
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

// An answered question checked off in its issue's Open questions section (#1279): the body read and
// written whole through gh, the item marked with the answer and its date. Null once it is; else why.
const checkOff = async ($: EngineInterface, repo: string, issue: number, text: string, answer: string): Promise<string | null> => {
  const r = await ghAnyAccount($, ['issue', 'view', String(issue), '--repo', repo, '--json', 'body'])
  if (!('stdout' in r)) return ghSaid(r.failures.find(f => !notFoundOnGitHub(f)) ?? (r.failures[0] as GhRun))
  let body: string
  try {
    const j = JSON.parse(r.stdout) as { body?: unknown }
    body = typeof j.body === 'string' ? j.body : ''
  } catch {
    return "GitHub's answer was not JSON"
  }
  const next = withQuestion(body, text, { answer, date: etDate(await $.clock.now()) })
  if (next === body) return null
  const w = await ghAnyAccount($, ['issue', 'edit', String(issue), '--repo', repo, '--body-file', '-'], notFoundOnGitHub, next)
  return 'stdout' in w ? null : ghSaid(w.failures.find(f => !notFoundOnGitHub(f)) ?? (w.failures[0] as GhRun))
}

// The questions earlier nights noted about the workers' repositories, and the open items in the Open
// questions section of each goal's issues (#1279), still open: not yet answered on their issue, and
// their issue not closed. Each failure to read is said, never read as no questions (L215).
type GoalIssue = { repo: string; issue: number }
const openQuestions = async ($: EngineInterface, dir: string, repos: string[], goalIssueList: GoalIssue[] = []): Promise<{ questions: OpenQuestion[]; rank: Map<string, number>; problems: string[] }> => {
  const problems: string[] = []
  const found: IssueQuestion[] = []
  const notesDir = `${dir}/notes`
  const ls = await run($, ['ls', '-1', notesDir])
  if (ls.exitCode !== 0 && !/No such file/i.test(ls.stderr)) problems.push(`Questions from earlier nights could not be read (${ls.stderr.trim() || `ls exited ${ls.exitCode}`}), so none were asked.`)
  const wanted = new Set(repos.map(r => r.toLowerCase()))
  let bad = 0
  const unread: string[] = []
  for (const name of ls.exitCode === 0 ? ls.stdout.split('\n').filter(n => n.endsWith('.jsonl')) : []) {
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
  // Each goal issue's section, read once (#1279). Its state and labels come with it, kept for the
  // reading of every issue below.
  const viewed = new Map<string, string>()
  for (const g of goalIssueList) {
    const k = `${g.repo.toLowerCase()}#${g.issue}`
    const r = await ghAnyAccount($, ['issue', 'view', String(g.issue), '--repo', g.repo, '--json', 'state,labels,body,url'])
    if (!('stdout' in r)) {
      problems.push(`The Open questions of ${g.repo}#${g.issue} could not be read (${ghSaid(r.failures.find(f => !notFoundOnGitHub(f)) ?? (r.failures[0] as GhRun))}), so none of them was asked.`)
      continue
    }
    let body: string
    try {
      const j = JSON.parse(r.stdout) as { state?: unknown; body?: unknown; url?: unknown }
      // A pull request's number reads as an issue in gh issue view: it has no section to ask.
      if (String(j.state).toUpperCase() === 'CLOSED' || /\/pull\/\d+/.test(String(j.url ?? ''))) continue
      body = typeof j.body === 'string' ? j.body : ''
    } catch {
      problems.push(`The Open questions of ${g.repo}#${g.issue} could not be read (GitHub's answer was not JSON), so none of them was asked.`)
      continue
    }
    viewed.set(k, r.stdout)
    const section = openQuestionsIn(body)
    if (!section.found) {
      problems.push(`${g.repo}#${g.issue} has no Open questions section, so nothing in it was asked.`)
      continue
    }
    for (const text of section.open) found.push({ repo: g.repo, issue: g.issue, text: oneSpaced(text), options: [], at: 0, inSection: [g.issue] })
  }
  const open: IssueQuestion[] = []
  for (const q of found) {
    const path = answeredPath(dir, q.repo, q.issue, q.text)
    if (!(await $.fs.exists(path))) {
      open.push(q)
      continue
    }
    // Answered on the issue, yet still open in its section: an earlier check off failed. Its answer
    // is on record, so it is checked off now rather than asked again or passed over (lessons review).
    if (!q.inSection?.length) continue
    let answer: string
    try {
      const rec = JSON.parse(await $.fs.read(path)) as { answer?: unknown }
      if (typeof rec.answer !== 'string') throw new Error('it holds no answer')
      answer = rec.answer
    } catch (err) {
      problems.push(`${q.repo}#${q.issue}'s Open questions still shows "${q.text}" open, though it was answered, and the record of the answer could not be read (${msg(err)}); it is not asked again.`)
      continue
    }
    const off = await checkOff($, q.repo, q.issue, q.text, answer)
    if (off) problems.push(`Your answer on ${q.repo}#${q.issue}, "${q.text}" ("${answer}"), is posted but its Open questions still shows it open, and checking it off failed again (${off}); it is not asked again.`)
  }
  // Each issue read once: a closed one is no longer in any queue. One that cannot be read is still
  // asked about, ranked last, since dropping its question would hide it (L215).
  const rank = new Map<string, number>()
  const closed = new Set<string>()
  for (const k of new Set(open.map(q => `${q.repo.toLowerCase()}#${q.issue}`))) {
    const q = open.find(x => `${x.repo.toLowerCase()}#${x.issue}` === k) as IssueQuestion
    const seen = viewed.get(k)
    const r = seen !== undefined ? { stdout: seen } : await ghAnyAccount($, ['issue', 'view', String(q.issue), '--repo', q.repo, '--json', 'state,labels'])
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
const askIssues = async ($: EngineInterface, dir: string, repos: string[], round: Round, goalIssueList: GoalIssue[] = []): Promise<IssueRound> => {
  const { questions, rank, problems } = await openQuestions($, dir, repos, goalIssueList)
  const ordered = orderQuestions(questions, (repo, n) => rank.get(`${repo.toLowerCase()}#${n}`) ?? 5)
  const left: Left[] = []
  const notes: Record<string, unknown>[] = []
  const posted: string[] = []
  let answered = 0
  const unposted: string[] = []
  // Every question left is said with why it was not asked or answered (#1279): on 2026-10-16 two
  // were left as "2 questions left for the morning" with no reason, and nothing could tell which
  // way they went.
  const leftSaid: string[] = []
  const leave = (q: OpenQuestion, why: string, issues = q.issues) => {
    left.push(...issues.map(issue => ({ repo: q.repo, issue, text: q.text, why })))
    leftSaid.push(`${issues.map(issue => `${q.repo}#${issue}`).join(' and ')}, "${q.text}" (${why})`)
  }
  for (const q of ordered) {
    const waitMs = round.until - (await $.clock.now())
    if (!interactive || round.slept || waitMs <= 0) {
      leave(q, !interactive ? 'not asked: nobody was at this session to ask' : round.slept ? 'not asked: you chose to go to sleep first' : 'not asked: the 10 minutes for bedtime questions ran out')
      continue
    }
    const asked = await askOne($, askText(q), askOptions(q), BEDTIME_HEADER, waitMs, async a => {
      // Answered after the wait: posted for the nights after; tonight its issues stay out.
      if (a === SKIP_QUESTION) return
      for (const issue of q.issues) {
        const p = await postAnswer($, dir, q.repo, issue, q.text, a)
        if ('failed' in p) {
          $.ui.toast(`Your late answer on ${q.repo}#${issue} ("${a}") could not be posted (${p.failed}); it is asked again next time.`)
          continue
        }
        // Checked off in its issue's Open questions too, as an answer in time is (lessons review).
        const off = q.inSection?.includes(issue) ? await checkOff($, q.repo, issue, q.text, a) : null
        if (off) $.ui.toast(`Your late answer on ${q.repo}#${issue} is posted, but it could not be checked off in its Open questions (${off}), so the issue still shows it open until /sleep next reads that issue and checks it off.`)
      }
    })
    if ('unanswered' in asked) {
      leave(q, 'not answered in the 10 minutes')
      continue
    }
    if ('failed' in asked) {
      leave(q, `the question was dismissed or could not be shown: ${asked.failed}`)
      continue
    }
    if (asked.answer === SKIP_QUESTION) {
      leave(q, 'you skipped it')
      continue
    }
    if (asked.answer === GO_TO_SLEEP) {
      round.slept = true
      leave(q, 'you chose to go to sleep')
      continue
    }
    let landed = false
    for (const issue of q.issues) {
      const p = await postAnswer($, dir, q.repo, issue, q.text, asked.answer)
      if ('failed' in p) {
        const why = `Your answer on ${q.repo}#${issue} ("${asked.answer}") could not be posted (${p.failed}), so the issue is skipped tonight and the question is asked again next time.`
        unposted.push(why)
        notes.push({ kind: 'finding', repo: q.repo, issue, text: why })
        leave(q, 'its answer could not be posted', [issue])
        continue
      }
      posted.push(`${q.repo}#${issue}`)
      landed = true
      // Checked off in the issue's Open questions too, when it was asked from there (#1279). Read
      // afresh and written whole, so an item already checked off by another /sleep stays as it is.
      if (q.inSection?.includes(issue)) {
        const off = await checkOff($, q.repo, issue, q.text, asked.answer)
        if (off) unposted.push(`Your answer on ${q.repo}#${issue} is posted, but it could not be checked off in its Open questions (${off}), so the issue still shows it open; it is not asked again, and /sleep checks it off when it next reads that issue.`)
      }
      if (p.unkept) unposted.push(`Your answer on ${q.repo}#${issue} is posted, but the record that it was could not be kept (${p.unkept}), so it may be asked again.`)
    }
    if (landed) answered++
  }
  // The questions left are noted for the morning report as the same words, so they are asked again.
  for (const l of left) notes.push({ kind: 'question', repo: l.repo, issue: l.issue, text: l.text, why: l.why })
  let said = ''
  if (answered) said += ` Before bed: ${plural(answered, 'question')} answered and posted on ${andList([...new Set(posted)])}.`
  if (leftSaid.length) said += ` Left for the morning, so tonight the queue skips them: ${leftSaid.join('; ')}.`
  for (const s of [...unposted, ...problems]) said += ` ${s}`
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
    found = await wakeCheck((argv, timeoutMs) => run($, argv, timeoutMs), { since: record.since, home, repos, github: githubOf($), now: () => $.clock.now() })
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
    { tool, input, raw, commands: raw ? await readCommands($, raw) : [], writes: raw ? await readWrites($, raw) : NO_WRITES, cwd, home, ...(ghRepo !== undefined ? { ghRepo } : {}), read: text => readCommands($, text) },
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
  // The session that ended the night offers its proposals in its morning, as a waking one does (#1285).
  try {
    await setNight($, endedNight(record, await $.session.id()))
  } catch (err) {
    $.ui.log(`scope-modes: the night that ended by itself could not be noted for this session's morning (${msg(err)}), so its proposals are only in the report`, { to: 'debug' })
  }
  // Ending by itself is the review too (#1283): the reminder comes off here, and everywhere at each minute.
  try {
    await endedAtWake($, record)
  } catch (err) {
    $.ui.log(`scope-modes: the reminder to end sleep mode could not be taken off at the noon end (${msg(err)}); each session's minute takes it off`, { to: 'debug' })
  }
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
// Each worker comes back as a seat too: its repository folder, for the night's merge and deploy
// lists (#843), and what the bedtime questions need of it (#1242): where its transcript is, for its
// /goal, and its request, so Dan can tell which session a question is about. This session's folder
// is filled in by /sleep from its own checkout.
type Seat = { id: string; root: string | null; transcript: string | null; request: string | null }
const requestOf = (r: { extra?: Record<string, unknown> }) => {
  const q = (r.extra?.progress as { request?: unknown } | undefined)?.request
  return typeof q === 'string' && q.trim() ? q.trim() : null
}
const enrol = async ($: EngineInterface, self: string): Promise<{ workers: string[]; seats: Seat[]; others: number; left: number; unknown?: string }> => {
  const workers = interactive ? [self] : []
  const seats: Seat[] = interactive ? [{ id: self, root: null, transcript: null, request: null }] : []
  let list
  try {
    list = await $.sessions.list()
  } catch (err) {
    return { workers, seats, others: 0, left: 0, unknown: `the session registry could not be read (${msg(err)})` }
  }
  let left = 0
  for (const o of list.open) {
    if (o.sessionId === self) {
      const mine = seats.find(s => s.id === self)
      if (mine) mine.transcript = o.transcriptPath ?? null
      continue
    }
    const said = (o.extra?.[MOD] as { isInteractive?: unknown } | undefined)?.isInteractive
    if (said === true) {
      workers.push(o.sessionId)
      seats.push({ id: o.sessionId, root: o.repoRoot ?? null, transcript: o.transcriptPath ?? null, request: requestOf(o) })
    } else left++
  }
  const unknown = list.unreadable.length ? `the session registry could not read ${list.unreadable.join(', ')}` : undefined
  return { workers, seats, others: workers.filter(w => w !== self).length, left, ...(unknown ? { unknown } : {}) }
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

const startedWhere = async ($: EngineInterface, r: SleepRecord) => `it started at ${etWhen(r.since)} in ${r.startedBy?.cwd ?? 'a session that left no folder'}, and ends at ${endSaid(r.until, await $.clock.now())}`

// /sleep (#840). The record, its workers, the night's merge and deploy lists (#843) and the before
// bed questions on the queue's issues (#836) here: paging (phase 2, #841) and the overnight driver
// (phase 8, #844) build on this record.
// `began` is set once this call placed the record, so the command acknowledges only a sleep it started (#1086).
const startSleep = async ($: EngineInterface, began: { is: boolean } = { is: false }): Promise<string> => {
  // This boot first: without it no record can be judged, and one that is sound must never be
  // called broken for it (L11), nor a new one written that could not be told from an old boot's.
  // The session is kept beside the start when it can be read; without it the record is judged by
  // its start alone, within readSleep's tolerance.
  const b = await thisBoot($)
  const startedBoot = b.boot.time
  if (startedBoot === null) return `Sleep mode did not start: this boot's start could not be read (${b.timeWhy ?? 'sysctl gave no reason'}).`
  let reading = await sleepNow($)
  if (reading.state === 'asleep') return `Sleep mode is already on: ${await startedWhere($, reading.record)}. Nothing changed.`
  if (reading.state === 'unreadable') {
    const p = await sleepPaths($).catch(() => null)
    if (p && (await $.fs.exists(p.current))) return `A sleep record is already there but cannot be read (${reading.why}). Nothing changed; /wake clears it.`
  }
  if (reading.state === 'expired' || reading.state === 'other-boot') {
    await endIfOver($, reading)
    reading = await sleepNow($)
    if (reading.state === 'asleep') return `Sleep mode is already on: ${await startedWhere($, reading.record)}. Nothing changed.`
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
    return `Sleep mode is already on: ${await startedWhere($, again.record)}. Nothing changed.`
  }
  // Everything from here until the record is in place is under the marker, so a second /sleep never
  // asks the questions again in between, and it is released however this ends.
  let e: Awaited<ReturnType<typeof enrol>>
  let repos: NightRepos
  let issues: IssueRound
  let goals: GoalRound
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
    const mine = e.seats.find(s => s.id === self)
    if (mine) mine.root = ownRoot ?? null
    const bySeat = await workerRepos($, e.seats)
    if (!(bySeat instanceof Map)) {
      await releaseMarker($, p.preparing, claim.claimed)
      return `Sleep mode did not start: ${bySeat.unread}.`
    }
    // The before bed questions, one round of QUESTION_MS for them all. Each worker's goal first
    // (#1242), since a worker with none does no work and nothing else about it needs asking. Then the
    // repositories' (#843): an answer there is kept for every night after and covers every issue in
    // it, while an issue's answer covers one issue. Then the open questions on the queue's issues (#836).
    const round: Round = { until: (await $.clock.now()) + QUESTION_MS, slept: false }
    goals = await settleGoals($, e.seats, bySeat, self, round)
    const worked = reposWorked(bySeat, goals.goals)
    // The night's merge and deploy lists (#843), settled before the record exists: the shared file,
    // a question for each worker's repository on neither list, every entry checked with GitHub.
    repos = await settleNight($, p.home, worked, round)
    // The issues each worker's goal names, whose Open questions are asked too (#1279).
    const goalIssueList = Object.entries(goals.goals).flatMap(([id, g]) => goalIssues(g, bySeat.get(id) ?? null))
    issues = await askIssues($, p.dir, worked, round, goalIssueList)
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
  let ownReportPath: string
  try {
    ownReportPath = await chooseReport($, night, generation)
  } catch (err) {
    // The night never began, so its unanswered list goes with it (lessons review).
    await run($, ['rm', '-f', `${p.dir}/unanswered/${generation}`])
    await releaseMarker($, p.preparing, claim.claimed)
    return `Sleep mode did not start: its report could not be named (${msg(err)}).`
  }
  const record: SleepRecord = {
    v: 1,
    generation,
    since: now,
    until: untilOf(night),
    night,
    bootTime: startedBoot,
    ...(b.boot.session !== null ? { bootSession: b.boot.session } : {}),
    // One report per session with news (#1287, superseding decision 4 of 2026-10-06): this
    // session's own, named by night, project and session; every other session names its own.
    report: ownReportPath,
    reportsPerSession: true,
    startedBy: { sessionId: self, cwd: startedIn },
    workers: e.workers,
    goals: goals.goals,
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
        return `Sleep mode is already on: ${await startedWhere($, there.record)}. Nothing changed.`
      }
      return `Sleep mode did not start: the record could not be put in place (${ln.stderr.trim() || `ln exited ${ln.exitCode}`}).`
    }
    placed = true
    began.is = true
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
  // Every other worker with a goal is told to start (#1242): one idle at its prompt has no turn to
  // end, so the driver would never reach it. Its own scope modes starts the turn, once the record it
  // reads to know it is a worker is in place. One that cannot be told is said and noted.
  const told: string[] = []
  const untold: string[] = []
  const unnotedStarts: string[] = []
  for (const id of Object.keys(goals.goals)) {
    if (id === self) continue
    const who = goals.names[id] ?? 'another session'
    let why: string | null
    try {
      // mod-kit tries a refused send once more, so a refusal here is the second.
      const sent = await $.session.send({ to: { sessionId: id }, text: SLEEP_START })
      why = sent.isDelivered ? null : sent.reason
    } catch (err) {
      why = msg(err)
    }
    if (why === null) {
      told.push(who)
      continue
    }
    untold.push(`${who} (${why})`)
    try {
      await sleepNote($, p.current, { kind: 'finding', at: now, by: self, text: `${who} could not be told to start at bedtime (${why}), so it may have done no work tonight` })
    } catch (err) {
      unnotedStarts.push(msg(err))
    }
  }
  let startSaid = told.length ? ` Told to start now: ${told.join('; ')}.` : ''
  if (untold.length) startSaid += ` Could not be told to start, so it may do no work tonight: ${untold.join('; ')}.`
  if (unnotedStarts.length) startSaid += ` The morning report may not say so: ${[...new Set(unnotedStarts)].join('; ')}.`
  const awake = await holdAwake($, p.dir, record.until, now)
  const others = e.others ? ` and ${e.others} other${e.others === 1 ? '' : 's'}` : ''
  const enrolled = e.workers.includes(self) ? `this session${others}` : e.others ? `${e.others} other session${e.others === 1 ? '' : 's'}` : 'no session'
  let s = `Sleep mode is on until ${endSaid(record.until, now)}. Enrolled to work overnight: ${enrolled}.`
  if (e.left) s += ` Not enrolled: ${e.left} session${e.left === 1 ? '' : 's'} that ${e.left === 1 ? 'is' : 'are'} not interactive or ${e.left === 1 ? 'has' : 'have'} not said.`
  if (e.unknown) s += ` Other sessions may be missing: ${e.unknown}.`
  s += goals.said + startSaid + closedSentence(repos) + issues.said + unnoted + tookOver
  // This session's report, when it works tonight (#1287), is named before the start renders it, so
  // it exists from the first minute, header first, and a night that ends badly still has one (#835, L10).
  const works = e.workers.includes(self)
  const named = works ? await recordReport($, generation, record.report) : null
  if (works && !named) reportNamed.add(generation)
  const started = await report($, ['start', '--record', p.current, '--by', self])
  const problem = named ? `its name could not be recorded (${named}), so it is tried again at the next minute` : started
  // Said as recorded, read back, since whichever namer is first keeps the name (lessons review).
  const recorded = works && !problem ? ((await ownReport($, generation).catch(() => null)) ?? record.report) : record.report
  s += problem ? ` The night's report could not be started: ${problem}.` : works ? ` The night's report is at ${recorded}.` : ''
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

// Phase 9 (#837), changed by #1285: no session is sent a summary request any more, since each puts
// its own morning to Dan at its next minute. The wake reply says how many others are open and which
// workers have closed since, whose night is then only in the report. A registry that cannot be read
// is said, never read as no other session (L215), and never takes the wake's reply with it.
const othersAtWake = async ($: EngineInterface, record: SleepRecord | null, self: string): Promise<string> => {
  const workers = (Array.isArray(record?.workers) ? record.workers : []).filter((w): w is string => typeof w === 'string' && w !== self)
  try {
    const list = await $.sessions.list()
    const ids = new Set(list.open.map(o => o.sessionId))
    const unknown = list.unreadable.length ? `the session registry could not read ${list.unreadable.join(', ')}` : undefined
    // One the registry could not read may be open, so none is called closed then.
    const closed = unknown ? 0 : workers.filter(w => !ids.has(w)).length
    return othersSaid({ open: list.open.filter(o => o.sessionId !== self).length, closed, ...(unknown ? { unknown } : {}) })
  } catch (err) {
    return othersSaid({ open: 0, closed: 0, unknown: `the session registry's answer could not be read (${msg(err)})` })
  }
}

/**
 * The night a session's morning is about: its generation (null when not known), whether it worked,
 * and `offers`, whether it ended sleep and so also offers the lessons and what names no repository
 * (every session offers its own repository's proposals once claimed, #1286).
 */
type Night = { generation: string | null; worker: boolean; offers: boolean; unread?: string }
// The night as the session that ended it notes it, by a wake or its noon end alike: one naming no
// generation is said as unread, never read as a night with nothing in it (lessons review).
const endedNight = (record: SleepRecord | null, self: string): Night => ({
  generation: typeof record?.generation === 'string' ? record.generation : null,
  worker: Array.isArray(record?.workers) && record.workers.includes(self),
  offers: true,
  ...(typeof record?.generation === 'string' ? {} : { unread: 'the sleep record names no generation' }),
})
type HeldItem = HeldDelivery & { why?: string }

// Phase 9 (#837), every session since #1285: a session's own morning, from the night's notes: its
// summary if it worked, what it held, the questions it noted and the merges the night held in it,
// each a picker, and its own repository's proposed issues once claimed (#1286), with the lessons and
// what names no repository in the session that ended sleep. A read that
// fails is said in the prompt, never read as a night with nothing proposed (L215). `anything` is
// whether there is anything to put to Dan at all, so a session with nothing of its own starts no turn.
const morningOf = async ($: EngineInterface, night: Night, self: string, held: readonly HeldItem[]): Promise<{ prompt: string; anything: boolean }> => {
  const deliveries = held.filter(h => h.why === undefined)
  const merges = held.filter((h): h is HeldMerge => h.why !== undefined)
  let read: ReturnType<typeof proposalsIn> | { unread: string }
  if (night.unread !== undefined) read = { unread: night.unread }
  else if (night.generation === null) read = { issues: [], lessons: [], questions: [], bad: 0 }
  else {
    try {
      const path = notesOf((await sleepPaths($)).home, night.generation)
      read = (await $.fs.exists(path)) ? proposalsIn(await $.fs.read(path)) : { issues: [], lessons: [], questions: [], bad: 0 }
    } catch (err) {
      read = { unread: msg(err) }
    }
  }
  // A page of the night's results is named as this session's report is (#1287); a report that cannot
  // be found only leaves the page's name to Claude, so a failed read is logged, not said.
  let reportName: string | undefined
  if (night.generation !== null) {
    const own = await ownReport($, night.generation).catch((err: unknown) => {
      $.ui.log(`scope-modes: where this session's report is could not be read (${msg(err)})`, { to: 'debug' })
      return null
    })
    if (own) reportName = (own.split('/').pop() ?? own).replace(/\.md$/, '')
  }
  if ('unread' in read) {
    // Notes that cannot be read send the session that ended sleep to the report, for its own
    // repository's proposals and the lessons only (lessons review of #1315).
    const p = { issues: [], lessons: [], unread: read.unread }
    const own = night.offers ? (await repoOf($)).slug : null
    return { prompt: morningPrompt({ worker: night.worker, offers: night.offers, held: deliveries, merges, questions: [], ...p, ...(own ? { forRepo: own } : {}), ...(reportName ? { reportName } : {}) }), anything: true }
  }
  // What this session offers is its own repository's (#1286): the proposed issues and the questions
  // no open session will ask (one naming no session, or one whose session has closed), each keyed by
  // repository, and, in the session that ended sleep, the lessons and what names no repository. Each
  // key is claimed for the night first, so no two sessions offer one; a key another session holds,
  // or whose claim cannot be written, is left (and the latter logged), never offered twice.
  const mine = (await repoOf($)).slug
  const keys = new Set<string>([...(mine ? [mine] : []), ...(night.offers ? [UNATTRIBUTED, LESSONS_KEY] : [])])
  let open: Set<string> | null = null
  if (read.questions.some(q => q.by !== null && q.by !== self)) {
    try {
      open = new Set((await $.sessions.list()).open.map(o => o.sessionId))
    } catch (err) {
      $.ui.log(`scope-modes: which sessions are open could not be read (${msg(err)}), so questions from other sessions are left to them`, { to: 'debug' })
    }
  }
  const orphans: { q: NightQuestion; key: string }[] = []
  for (const q of read.questions) {
    if (q.by === self || !(q.by === null || (open !== null && !open.has(q.by)))) continue
    orphans.push({ q, key: repoKey(q.repo ?? (q.cwd ? await folderRepo($, q.cwd) : null)) })
  }
  const has = (key: string) => (key === LESSONS_KEY ? read.lessons.length > 0 : read.issues.some(i => repoKey(i.repo) === key) || orphans.some(o => o.key === key))
  const claimed = new Set<string>()
  if (night.generation !== null) for (const key of keys) if (has(key) && (await claimOffer($, night.generation, key))) claimed.add(key)
  // Each claimed issue is sorted before it is offered (#1389): one already filed is said, one another
  // open session claimed is left to it, and the rest are claimed one by one for this session.
  const sorted = await sortProposals(
    $,
    read.issues.filter(i => claimed.has(repoKey(i.repo))),
    (night.generation !== null ? nightStart(night.generation) : null) ?? (await $.clock.now()) - BACKLOG_MS,
  )
  const issues = sorted.offer
  const lessons = claimed.has(LESSONS_KEY) ? read.lessons : []
  const questions = [...read.questions.filter(q => q.by === self), ...orphans.filter(o => claimed.has(o.key)).map(o => o.q)]
  // "Nothing proposed" is said only where nothing was: proposals another session claimed are its to
  // offer, and this session says nothing of them (lessons review).
  const offers = issues.length > 0 || lessons.length > 0 || sorted.filed.length > 0 || sorted.declined.length > 0 || sorted.elsewhere > 0 || (night.offers && ![...keys].some(has))
  return {
    prompt: morningPrompt({
      worker: night.worker,
      offers,
      held: deliveries,
      merges,
      questions,
      issues,
      lessons,
      bad: read.bad,
      ...(sorted.filed.length ? { filed: sorted.filed } : {}),
      ...(sorted.declined.length ? { declined: sorted.declined } : {}),
      ...(sorted.elsewhere ? { elsewhere: sorted.elsewhere } : {}),
      ...(sorted.unchecked !== undefined ? { unchecked: sorted.unchecked } : {}),
      ...(mine ? { forRepo: mine } : {}),
      ...(reportName ? { reportName } : {}),
    }),
    anything: night.worker || offers || held.length > 0 || questions.length > 0,
  }
}

// One key of a night's proposals claimed for this session (#1286), by linking a file into place, so
// of two sessions claiming at once exactly one wins (assume it runs twice). True once claimed here;
// false when another holds it, or when the claim could not be written, which is logged: offering
// nothing is the safe side, since the proposals stay in the report and unclaimed for a later session.
// `fresh` takes only a new claim: the backlog's, which must never offer again what this session's own
// morning already offered (lessons review).
const claimOffer = async ($: EngineInterface, generation: string, key: string, fresh = false): Promise<boolean> => {
  const dir = `${(await sleepPaths($)).dir}/offered/${generation.replace(/[^\w.-]/g, '_')}`
  const linked = await linkInto($, dir, keyFile(key), await $.session.id())
  if (linked === 'linked') return true
  // This session's own earlier claim (a morning that did not go in, asked again) is still its own.
  if (linked === 'taken') return !fresh && (await $.fs.read(`${dir}/${keyFile(key)}`).catch(() => '')) === (await $.session.id())
  $.ui.log(`scope-modes: the night's proposals for ${key} could not be claimed (${linked.error}), so they are left in the report for a later session`, { to: 'debug' })
  return false
}

// One file written whole beside its name, then linked into place: `ln` refuses when the name is
// there, so of two sessions writing one name exactly one succeeds (assume it runs twice). The one
// way this mod claims anything in the shared sleep state: a night's proposals by repository
// (#1286), and each proposal before it is offered and filed (#1389). `taken` is the name already
// there; anything else that stops the link is said, never read as a lost race (L11).
const linkInto = async ($: EngineInterface, dir: string, name: string, text: string): Promise<'linked' | 'taken' | { error: string }> => {
  const tmp = `${dir}/.${name}.${Math.random().toString(36).slice(2, 10)}.tmp`
  try {
    await run($, ['mkdir', '-p', dir])
    await $.fs.write(tmp, text)
    const ln = await run($, ['ln', tmp, `${dir}/${name}`])
    if (ln.exitCode === 0) return 'linked'
    if (/File exists/i.test(ln.stderr)) return 'taken'
    return { error: ln.stderr.trim() || `ln exited ${ln.exitCode}` }
  } catch (err) {
    return { error: msg(err) }
  } finally {
    await run($, ['rm', '-f', tmp])
  }
}

// ---- #1389: each overnight proposal offered once and filed once (hooks/proposals.ts decides) ----

// A proposal's entries by number. An absent folder is no entries; one that cannot be listed throws.
const proposalEntries = async ($: EngineInterface, dir: string): Promise<Record<string, string>> => {
  if (!(await $.fs.exists(dir))) return {}
  const ls = await run($, ['ls', dir])
  if (ls.exitCode !== 0) throw new Error(ls.stderr.trim() || `ls exited ${ls.exitCode}`)
  const out: Record<string, string> = {}
  for (const name of ls.stdout.split('\n').map(s => s.trim()).filter(s => /^\d+$/.test(s))) out[name] = await $.fs.read(`${dir}/${name}`)
  return out
}

// The sessions open now, or null when the registry cannot be read: then only a claim's age frees it.
const openSessions = async ($: EngineInterface): Promise<Set<string> | null> => {
  try {
    return new Set((await $.sessions.list()).open.map(o => o.sessionId))
  } catch (err) {
    $.ui.log(`scope-modes: which sessions are open could not be read (${msg(err)}), so another session's claim on a proposal holds until it is a day old`, { to: 'debug' })
    return null
  }
}

// One entry added at the next free number, judged again after a lost race, so two writers never
// share a number. Returns the state the proposal was in when the entry went in, or why it did not.
const addEntry = async (
  $: EngineInterface,
  dir: string,
  open: Set<string> | null,
  entry: (now: number, self: string) => string,
  stopAt: (s: ProposalState) => boolean,
): Promise<{ added: true; before: ProposalState } | { added: false; state: ProposalState } | { error: string }> => {
  const self = await $.session.id()
  for (let attempt = 0; attempt < 5; attempt++) {
    let state: ProposalState
    try {
      state = judgeProposal(await proposalEntries($, dir), self, open, await $.clock.now())
    } catch (err) {
      return { error: msg(err) }
    }
    if (stopAt(state)) return { added: false, state }
    const next = 'next' in state ? state.next : 1
    const linked = await linkInto($, dir, String(next), entry(await $.clock.now(), self))
    if (linked === 'linked') return { added: true, before: state }
    if (linked !== 'taken') return linked
  }
  return { error: 'another session kept writing to this proposal first' }
}

const MILESTONE_CANDIDATES = (home: string) => `${home}/.claude/skills/milestone/milestone-candidates.sh`
const DAY_MS = 24 * 60 * MIN

// Whether GitHub already holds a proposal, by the end of turn review's own duplicate check
// (milestone-candidates.sh, its CLOSE-MATCH, never a second matcher here: L370), over the issues open
// now and those closed since the day before the night it came from: it can only have been filed
// after it was proposed, so nothing closed earlier can be its filing, and the day before covers a
// night that began on the previous date in UTC.
const filedOnGitHub = async ($: EngineInterface, repo: string, title: string, since: number): Promise<{ number: number } | null | { error: string }> => {
  const home = (await sleepPaths($)).home
  const r = await run($, ['bash', MILESTONE_CANDIDATES(home), repo, '--like', title, '--closed-since', new Date(since - DAY_MS).toISOString().slice(0, 10)], 90_000)
  if (r.exitCode === 1) return null
  if (r.exitCode !== 0) return { error: (r.stderr.trim() || r.stdout.trim()).split('\n')[0] || `milestone-candidates.sh exited ${r.exitCode}` }
  const m = closeMatchIn(r.stdout)
  return m ? { number: m.number } : null
}

type SortedProposals = { offer: ProposedIssue[]; filed: FiledProposal[]; declined: ProposedIssue[]; elsewhere: number; unchecked?: string }

// The proposed issues a session is about to offer, sorted before it offers any (#1389): those filed
// already (recorded here, or found on GitHub by a close match) are said and never offered; those Dan
// declined on an earlier morning are said as declined; those another open session claimed are left
// to it; each of the rest is claimed for this session, so no second session offers it. `since` is
// when the oldest of their nights began. A check or claim that cannot be made still offers the
// proposal (losing it is the worse failure), says a check that failed, and logs a claim that failed:
// filing claims it again. What is offered is remembered by its number, so a picker Dan answers
// records the ones he left as declined.
const sortProposals = async ($: EngineInterface, issues: readonly ProposedIssue[], since: number): Promise<SortedProposals> => {
  const out: SortedProposals = { offer: [], filed: [], declined: [], elsewhere: 0 }
  if (!issues.length) return out
  const sleep = (await sleepPaths($)).dir
  const open = await openSessions($)
  // One proposal written twice (by two nights, or twice in one) is one proposal.
  const seen = new Set<string>()
  type Sorted = { issue: ProposedIssue; dir: string | null; to: 'offer' | 'elsewhere' | 'declined'; why?: string } | { issue: ProposedIssue; filed: FiledProposal }
  const each = await Promise.all(
    issues.map(async (issue): Promise<Sorted | null> => {
      const dir = proposalPath(sleep, issue.repo, issue.title)
      if (dir === null) return { issue, dir, to: 'offer' }
      if (seen.has(dir)) return null
      seen.add(dir)
      const self = await $.session.id()
      let state: ProposalState
      try {
        state = judgeProposal(await proposalEntries($, dir), self, open, await $.clock.now())
      } catch (err) {
        $.ui.log(`scope-modes: whether "${issue.title}" was already offered or filed could not be read (${msg(err)}), so it is offered`, { to: 'debug' })
        return { issue, dir, to: 'offer' }
      }
      const settled = (s: ProposalState): Sorted | null =>
        s.state === 'filed' ? { issue, filed: { issue, number: s.number, url: s.url } } : s.state === 'declined' ? { issue, dir, to: 'declined' } : s.state === 'held' ? { issue, dir, to: 'elsewhere' } : null
      const now = settled(state)
      if (now) return now
      if (state.state === 'mine') return { issue, dir, to: 'offer' }
      let why: string | undefined
      if (issue.repo && issue.title) {
        const found = await filedOnGitHub($, repoKey(issue.repo), issue.title, since)
        if (found && 'error' in found) why = found.error
        // A close match only resembles, and milestone-candidates.sh rules on nothing (lessons review):
        // it is shown with its number, for Dan to correct, and never recorded as filed, so a wrong
        // one hides nothing for good and never refuses a filing he asks for. A later night proposing
        // it again is checked again.
        else if (found) return { issue, filed: { issue, number: found.number, url: null } }
      }
      const r = await addEntry($, dir, open, (at, by) => claimEntry(by, at), s => s.state !== 'free')
      if ('error' in r) $.ui.log(`scope-modes: "${issue.title}" could not be claimed before it is offered (${r.error}); filing claims it again`, { to: 'debug' })
      else if (!r.added) {
        const raced = settled(r.state)
        if (raced) return raced
      }
      return { issue, dir, to: 'offer', ...(why !== undefined ? { why } : {}) }
    }),
  )
  const numbered = new Map<string, string>()
  for (const e of each) {
    if (e === null) continue
    if ('filed' in e) out.filed.push(e.filed)
    else if (e.to === 'elsewhere') out.elsewhere++
    else if (e.to === 'declined') out.declined.push(e.issue)
    else {
      out.offer.push(e.issue)
      if (e.dir !== null) numbered.set(`1.${out.offer.length}`, e.dir)
      if (e.why !== undefined && out.unchecked === undefined) out.unchecked = e.why
    }
  }
  rememberOffered(numbered)
  return out
}

// The proposed issues this session offered, by the number its prompt gave each (1.n), so the picker
// Dan answers records the ones he left unselected as declined (#1389). Every offer numbers from 1.1,
// so a second offer in the same session (the backlog's beside the morning's) can give a number to a
// different proposal while the first picker still waits: such a number is dropped for the rest of
// the session, since an answer cannot say which was meant, and a wrong decline would hide a
// proposal for good where a missed one only offers it again. Held in memory: a reload before he
// answers loses it, and those proposals are then neither declined nor lost (their claims expire,
// and a later morning offers them again).
let offeredByNumber = new Map<string, string>()
const ambiguousNumbers = new Set<string>()
const rememberOffered = (numbered: ReadonlyMap<string, string>) => {
  for (const [n, dir] of numbered) {
    if (ambiguousNumbers.has(n)) continue
    const had = offeredByNumber.get(n)
    if (had !== undefined && had !== dir) {
      ambiguousNumbers.add(n)
      offeredByNumber.delete(n)
    } else offeredByNumber.set(n, dir)
  }
}

// Each proposal Dan left unselected in a picker he answered, recorded declined for good.
const noteDeclined = async ($: EngineInterface, input: Record<string, unknown>, result: { result?: unknown }) => {
  if (!offeredByNumber.size) return
  const answers = (result.result as { answers?: unknown } | undefined)?.answers
  for (const n of declinedIn(input.questions, answers, new Set(offeredByNumber.keys()))) {
    const dir = offeredByNumber.get(n) as string
    const r = await addEntry($, dir, null, (at, by) => declinedEntry(by, at), s => s.state === 'filed' || s.state === 'declined')
    if ('error' in r) $.ui.log(`scope-modes: a proposal Dan declined (${n}) could not be recorded as declined (${r.error}), so a later morning may offer it again`, { to: 'debug' })
  }
}

// When the night a generation names began (its leading time), or null for one named by no time.
const nightStart = (generation: string): number | null => {
  const at = Number(/^(\d+)-/.exec(generation)?.[1])
  return Number.isFinite(at) ? at : null
}

// Before a `gh issue create` whose title is an overnight proposal's (#1389): filed already, or held
// by another open session, it is refused, saying where it is; otherwise this session claims it, so
// a second session filing it at the same moment is refused, and `dir` is where it is recorded filed
// once gh says it was made. A call that names no proposal, or cannot be read, is left alone.
const proposalFiling = async ($: EngineInterface, raw: string): Promise<{ dir: string } | { deny: string } | null> => {
  let cmds: Cmd[]
  try {
    cmds = await readCommands($, raw)
  } catch (err) {
    $.ui.log(`scope-modes: a gh issue create could not be read for an overnight proposal (${msg(err)}), so it runs unclaimed`, { to: 'debug' })
    return null
  }
  const gh = cmds.find(c => c.gh?.sub === 'issue' && c.gh.act === 'create')?.gh
  if (!gh || gh.unreadable) return null
  const title = gh.flags.filter(f => f.name === '--title' || f.name === '-t').pop()?.value
  if (typeof title !== 'string') return null
  const repo = gh.named === undefined ? ((await $.env.get('GH_REPO')) || (await repoOf($)).slug) : gh.named
  if (!repo) return null
  const dir = proposalPath((await sleepPaths($)).dir, repo, title)
  if (dir === null || !(await $.fs.exists(dir))) return null
  const r = await addEntry($, dir, await openSessions($), (now, by) => claimEntry(by, now), s => s.state !== 'free')
  if ('error' in r) {
    $.ui.log(`scope-modes: the overnight proposal "${title}" could not be claimed before filing (${r.error}), so it is filed unclaimed`, { to: 'debug' })
    return { dir }
  }
  if (r.added) return { dir }
  const s = r.state
  if (s.state === 'filed')
    return { deny: `Not filed: this overnight proposal is already filed as ${s.url ?? `${repo}#${s.number ?? '?'}`}. Tell Dan in one line, and do not file it again.` }
  if (s.state === 'held')
    return { deny: 'Not filed: another open session is offering this overnight proposal, so it is filed from there if Dan picks it there, never twice. Tell Dan in one line.' }
  return { dir }
}

// Once gh made the issue, the proposal is recorded filed, with its link, so no session offers or
// files it again. One that cannot be recorded is logged: the next morning's duplicate check against
// GitHub still finds it.
const noteProposalFiled = async ($: EngineInterface, dir: string, result: { text?: string }) => {
  const made = issueLinkIn(String(result.text ?? ''))
  // A link mod-kit's one link reader does not read as a repository's is no issue made (L613).
  if (!made || !(await $.modkit.linkRepo({ link: made.url }).catch(() => null))) return
  const r = await addEntry($, dir, null, (now, by) => filedEntry(by, now, { url: made.url, number: made.number }), s => s.state === 'filed')
  if ('error' in r) $.ui.log(`scope-modes: ${made.url} was filed from an overnight proposal but could not be recorded (${r.error}); a later morning's check against GitHub still finds it`, { to: 'debug' })
}

// How far back a session started later looks for its repository's proposals no session offered
// (#1286): the nights the record of the morning reviews keeps, a chosen limit.
const BACKLOG_MS = 14 * 24 * 60 * MIN
// Once a session, while awake: its repository's proposals from an earlier night that no session in
// it was open to offer, claimed and offered in a turn of their own. A night still asleep is skipped,
// and a notes file named by no time is left alone.
let backlogChecked = false
const offerBacklog = async ($: EngineInterface, reading: SleepReading) => {
  if (backlogChecked || reading.state === 'asleep' || reading.state === 'unreadable') return
  backlogChecked = true
  const mine = (await repoOf($)).slug
  if (!mine) return
  const p = await sleepPaths($)
  const ls = await run($, ['ls', p.notes])
  if (ls.exitCode !== 0) return
  const now = await $.clock.now()
  const claimedIssues: ProposedIssue[] = []
  const questions: NightQuestion[] = []
  // When the oldest night offered here began, for the duplicate check's closed issues (#1389).
  let since = now
  let bad = 0
  // A question is offered here only when its own session is no longer open to ask it (lessons review).
  let open: Set<string> | null = null
  try {
    open = new Set((await $.sessions.list()).open.map(o => o.sessionId))
  } catch (err) {
    $.ui.log(`scope-modes: which sessions are open could not be read (${msg(err)}), so earlier nights' questions are left to them`, { to: 'debug' })
  }
  for (const name of ls.stdout.split('\n').map(s => s.trim()).filter(s => s.endsWith('.jsonl'))) {
    const generation = name.slice(0, -'.jsonl'.length)
    const at = Number(/^(\d+)-/.exec(generation)?.[1])
    if (!Number.isFinite(at) || now - at > BACKLOG_MS) continue
    let notes: string
    try {
      notes = await $.fs.read(`${p.notes}/${name}`)
    } catch (err) {
      $.ui.log(`scope-modes: an earlier night's notes could not be read (${msg(err)}), so any proposal for ${mine} in them waits in its report`, { to: 'debug' })
      continue
    }
    const read = proposalsIn(notes)
    // Lines that could not be read may hide one of this repository's, so they are counted and said
    // with what is offered, and logged where nothing is (lessons review).
    if (read.bad) {
      bad += read.bad
      $.ui.log(`scope-modes: ${read.bad} line(s) of an earlier night's notes could not be read, so a proposal for ${mine} may be missing; that night's report counts them`, { to: 'debug' })
    }
    const mineHere = read.issues.filter(i => repoKey(i.repo) === mine)
    const asksHere: NightQuestion[] = []
    for (const q of read.questions) {
      if (!(q.by === null || (open !== null && !open.has(q.by)))) continue
      if (repoKey(q.repo ?? (q.cwd ? await folderRepo($, q.cwd) : null)) === mine) asksHere.push(q)
    }
    if ((mineHere.length || asksHere.length) && (await claimOffer($, generation, mine, true))) {
      claimedIssues.push(...mineHere)
      questions.push(...asksHere)
      if (mineHere.length) since = Math.min(since, at)
    }
  }
  // A proposal filed since its night, by a session or by hand, is said as filed and never offered
  // again (#1389: on 2026-10-20 four were offered here that had been filed eleven days before).
  const sorted = await sortProposals($, claimedIssues, since)
  const issues = sorted.offer
  if (!issues.length && !questions.length && !sorted.filed.length && !sorted.declined.length) return
  const lead =
    issues.length || questions.length
      ? `Proposals and questions for ${mine} from an earlier night were never put to Dan, since no session in it was open when that night ended: offer them now.`
      : `Proposals for ${mine} from an earlier night, which no session in it was open to offer, turn out to be filed or declined already.`
  try {
    await $.prompt.submit({
      text: morningPrompt({
        worker: false,
        offers: issues.length > 0 || sorted.filed.length > 0 || sorted.declined.length > 0,
        issues,
        lessons: [],
        questions,
        lead,
        forRepo: mine,
        ...(sorted.filed.length ? { filed: sorted.filed } : {}),
        ...(sorted.declined.length ? { declined: sorted.declined } : {}),
        ...(sorted.elsewhere ? { elsewhere: sorted.elsewhere } : {}),
        ...(sorted.unchecked !== undefined ? { unchecked: sorted.unchecked } : {}),
        ...(bad ? { bad } : {}),
      }),
    })
  } catch (err) {
    $.ui.log(`scope-modes: ${mine}'s proposals from an earlier night were claimed but could not be offered (${msg(err)}); they are in that night's report`, { to: 'debug' })
  }
}

// ---- What a session held while asleep (#1284): its decisions are in hooks/nightheld.ts ----

const wakeHeldOf = async ($: EngineInterface): Promise<HeldDelivery[]> => (await $.state.get(wakeHeldRef)).value ?? []
// What the waking session's own morning turn carries, while it has not gone in, so the minute does
// not put the morning to Dan too and only what it carried is cleared once it does; with the night's
// generation, so the morning is recorded as put by the night it was about (#1383).
let morningInFlight: { generation: string | null; held: HeldItem[] } | null = null
// One asking at a time: a minute's prompt that has not gone in yet is not asked again beside it.
let askingMorning = false
// This session's morning turn, its pickers counted while it runs (#1285): one left unanswered, or a
// turn that ended other than by answering, has the unanswered ones asked again with Dan's next
// message here, by this mod (lessons review: a rule only in the prompt is a hope, L27).
let morningPickers: { turnId?: string; answered: number; unanswered: number; asks: boolean } | undefined
// Kept in $.state too, so a reload between the morning turn and his next message still asks again
// (lessons review); undefined until read from there.
let morningLeftUnanswered: boolean | undefined
// `prompt` is the morning's text: only one that asks something can leave a picker unanswered.
const watchMorningPickers = (prompt: string) => {
  morningPickers = { answered: 0, unanswered: 0, asks: prompt.includes('AskUserQuestion') }
}
const leftUnanswered = async ($: EngineInterface): Promise<boolean> => {
  if (morningLeftUnanswered === undefined) morningLeftUnanswered = (await $.state.get(morningUnansweredRef)).value ?? false
  return morningLeftUnanswered
}
const setLeftUnanswered = async ($: EngineInterface, v: boolean) => {
  morningLeftUnanswered = v
  await $.state.set({ plugin: 'scope-modes', key: 'morningUnanswered' }, v)
}
// The list as this session holds it, in memory, read from $.state once (a reload keeps it there),
// then changed here and written whole: two calls held at once (parallel calls, a subagent beside the
// main loop) each saw the same list through their own hook's $.state, and the second write dropped
// the first (lessons review, reproduced with three at once).
let heldNow: HeldItem[] | undefined
let heldLoaded = false
// One read, shared by calls that arrive together before it answers. A read that fails is not kept,
// so the next call reads again; what was held meanwhile stays in memory and is merged in once a
// read answers, never written over a list that could not be read (lessons review).
let heldLoad: Promise<HeldItem[]> | undefined
const loadHeld = async ($: EngineInterface) => {
  if (heldLoaded) return
  try {
    const loaded = await (heldLoad ??= wakeHeldOf($))
    if (heldLoaded) return
    heldNow = [...loaded, ...without(heldNow ?? [], loaded)]
    heldLoaded = true
  } catch (err) {
    heldLoad = undefined
    throw err
  }
}
// The list as far as it is known: one that could not be read is what this session held since.
const heldList = async ($: EngineInterface): Promise<HeldItem[]> => {
  try {
    await loadHeld($)
  } catch (err) {
    $.ui.log(`scope-modes: what this session held overnight could not be read from its state (${msg(err)}), so only what it held since is known`, { to: 'debug' })
  }
  return heldNow ?? []
}
const changeHeld = async ($: EngineInterface, fn: (held: HeldItem[]) => HeldItem[]): Promise<void> => {
  let unread: unknown
  try {
    await loadHeld($)
  } catch (err) {
    unread = err
  }
  // Changed from the list as it stands after the read, never from a copy taken before another change.
  heldNow = fn(heldNow ?? [])
  if (unread !== undefined) throw unread
  // The reference written at the call: the engine's reader of state references refused this write
  // through the const, though it reads the others (measured on this branch, #1284).
  await $.state.set({ plugin: 'scope-modes', key: 'wakeHeld' }, heldNow)
}
const without = (held: HeldItem[], gone: readonly HeldItem[]) => held.filter(x => !gone.some(g => g.call === x.call))
// Kept once each, in the order held: the same call held twice is delivered once.
const keepForWake = ($: EngineInterface, h: HeldItem) =>
  changeHeld($, held => (held.some(x => x.call === h.call) ? held : [...held, { label: h.label, call: h.call, ...(h.why !== undefined ? { why: h.why } : {}) }]))

// The night this session last saw asleep (#1285), in memory and in $.state for a reload: written by
// this session alone (its minute, its wake, its noon end), so it needs no merging.
let nightSeen: Night | null | undefined
const nightNow = async ($: EngineInterface): Promise<Night | null> => {
  if (nightSeen === undefined) nightSeen = (await $.state.get(nightSeenRef)).value ?? null
  return nightSeen
}
const setNight = async ($: EngineInterface, n: Night | null) => {
  nightSeen = n
  // Whole, `unread` included, so a reload never turns notes that could not be read into none (lessons review).
  await $.state.set({ plugin: 'scope-modes', key: 'nightSeen' }, n ? { generation: n.generation, worker: n.worker, offers: n.offers, ...(n.unread !== undefined ? { unread: n.unread } : {}) } : null)
}
// The last morning this session put to Dan (#1383), in memory and in $.state for a reload, as the
// night is. Memory is set first, so no write that fails undoes it in this copy of the mod.
let morningPut: PutMorning | null | undefined
const putNow = async ($: EngineInterface): Promise<PutMorning | null> => {
  if (morningPut === undefined) morningPut = (await $.state.get(morningPutRef)).value ?? null
  return morningPut
}
// A morning that went in: recorded as put, and the night and what it carried done, each written on
// its own, so one write that fails never keeps another from being done (lessons review). The record
// of it as put is its own write (L561), so a reload reading a night whose clearing failed still
// finds it put (#1383). Resolves to the first failure, and whether that record was written.
const markMorning = async ($: EngineInterface, put: PutMorning, carried: readonly HeldItem[]): Promise<{ failed: unknown; recorded: boolean } | null> => {
  morningPut = put
  const failed: unknown[] = []
  let recorded = true
  await $.state.set({ plugin: 'scope-modes', key: 'morningPut' }, put).catch(err => {
    recorded = false
    failed.push(err)
  })
  await setNight($, null).catch(err => failed.push(err))
  await changeHeld($, held => without(held, carried)).catch(err => failed.push(err))
  return failed.length ? { failed: failed[0], recorded } : null
}
// A mark that fails is said to Dan, once a morning, never only to the debug log (#1383). This copy of
// the mod does not put that morning again, since what it put is kept in memory; only one with fresh
// memory (a reload) could, and only when the record of it as put could not be written either.
let markSaid: string | undefined
const markMorningOrSay = async ($: EngineInterface, put: PutMorning, carried: readonly HeldItem[]) => {
  const r = await markMorning($, put, carried)
  if (!r) return
  $.ui.log(`scope-modes: this session's morning went in, but could not be marked done (${msg(r.failed)})${r.recorded ? '' : ', nor recorded as put, so a reload may put it to Dan again'}`, { to: 'debug' })
  const key = JSON.stringify(put)
  if (markSaid === key) return
  markSaid = key
  try {
    await $.ui.toast(`The morning summary went in, but this session could not record it as done (${msg(r.failed)}). It is not put to you again${r.recorded ? '' : ', unless this session reloads its mods, which may put it once more'}.`)
  } catch (err) {
    $.ui.log(`scope-modes: a morning that could not be marked done could not be said to Dan either (${msg(err)})`, { to: 'debug' })
  }
}
// The waking session's morning turn went in (or did not): recorded as put, and the night and what
// it carried done, or kept for the minute. Memory is what this session reads, so a state write that
// fails after it went in still marks them done here, and is said (#1383).
const morningDone = async ($: EngineInterface, entered: boolean) => {
  const inFlight = morningInFlight
  if (!inFlight) return
  try {
    if (entered) await markMorningOrSay($, { generation: inFlight.generation, calls: inFlight.held.map(h => h.call) }, inFlight.held)
  } finally {
    morningInFlight = null
  }
}
// Each minute, in every session (#1285): asleep, the night is remembered; once the record is gone
// (moved aside by a wake or its noon end, in any session), this session puts its own morning to Dan
// in a turn of its own, unless it has nothing to put. Only no record is a wake: one that cannot be
// read may still be asleep, and a new night replaces the one remembered, keeping what was held for
// its own morning. A prompt that does not go in keeps it all, put to Dan again at the next minute.
const morningAtMinute = async ($: EngineInterface, reading: SleepReading) => {
  if (morningInFlight || askingMorning) return
  // Taken before the first wait, so two minutes overlapping never both ask (lessons review of #1284).
  askingMorning = true
  try {
    const self = await $.session.id()
    if (reading.state === 'asleep') {
      const g = reading.record.generation
      const seen = await nightNow($)
      if (typeof g === 'string' && seen?.generation !== g) await setNight($, { generation: g, worker: Array.isArray(reading.record.workers) && reading.record.workers.includes(self), offers: false })
      return
    }
    if (reading.state !== 'none') return
    const seen = await nightNow($)
    const held = [...(await heldList($))]
    if (!seen && !held.length) return
    // A morning this session already put (#1383): its night, or what it carried, left in $.state by a
    // mark that failed and read by a copy of the mod with fresh memory. Never put again; only the
    // mark is tried again.
    const put = await putNow($)
    if (put && alreadyPut(put, seen, held)) {
      $.ui.log(`scope-modes: this session's morning${put.generation ? ` for ${put.generation}` : ''} was already put to Dan, so it is not put again; what it left unmarked is marked now`, { to: 'debug' })
      await markMorningOrSay($, put, held)
      return
    }
    const m = await morningOf($, seen ?? { generation: null, worker: false, offers: false }, self, held)
    if (!m.anything) {
      await setNight($, null)
      return
    }
    watchMorningPickers(m.prompt)
    try {
      await $.prompt.submit({ text: m.prompt })
    } catch (err) {
      morningPickers = undefined
      $.ui.log(`scope-modes: this session's morning could not be put to Dan (${msg(err)}), so it is tried again at the next minute`, { to: 'debug' })
      return
    }
    await markMorningOrSay($, { generation: seen?.generation ?? null, calls: held.map(h => h.call) }, held)
  } finally {
    askingMorning = false
  }
}

// ---- One report per session with news (#1287): its name is decided in hooks/reportname.ts ----

// This session's title, as its own transcript records it: the last `custom-title` line (what /rename
// and auto naming set), else the last `ai-title`. Read from the transcript rather than the classic
// hooks that carry `session_title`, which Claude Code's security default sends past a mod (#875),
// so no bypass entry is needed. Null when there is none yet, or it cannot be read, which is logged.
const TITLE_LINE = /"(customTitle|aiTitle)":"((?:\\.|[^"\\])*)"/g
const titleNow = async ($: EngineInterface): Promise<string | null> => {
  let path: string | null = null
  try {
    const self = await $.session.id()
    path = (await $.sessions.list()).open.find(o => o.sessionId === self)?.transcriptPath ?? null
  } catch (err) {
    $.ui.log(`scope-modes: this session's title could not be looked up (${msg(err)}), so its report is named by its id`, { to: 'debug' })
    return null
  }
  if (!path) return null
  const r = await run($, ['grep', '-o', '-E', '"(customTitle|aiTitle)":"([^"\\\\]|\\\\.)*"', path])
  // grep exits 1 when nothing matches: no title yet, which is no failure.
  if (r.exitCode !== 0) {
    if (r.exitCode !== 1) $.ui.log(`scope-modes: this session's title could not be read (${r.stderr.trim() || `grep exited ${r.exitCode}`}), so its report is named by its id`, { to: 'debug' })
    return null
  }
  let custom: string | null = null
  let ai: string | null = null
  for (const m of r.stdout.matchAll(TITLE_LINE)) {
    let v: unknown
    try {
      v = JSON.parse(`"${m[2]}"`)
    } catch {
      continue
    }
    if (typeof v !== 'string') continue
    if (m[1] === 'customTitle') custom = v
    else ai = v
  }
  return custom ?? ai
}
const reportsDirOf = async ($: EngineInterface, generation: string) => `${(await sleepPaths($)).dir}/reports/${generation.replace(/[^\w.-]/g, '_')}`
// This session's report on a night, as recorded, or null when it has none.
const ownReport = async ($: EngineInterface, generation: string): Promise<string | null> => {
  const f = `${await reportsDirOf($, generation)}/${await $.session.id()}.path`
  if (!(await $.fs.exists(f))) return null
  return (await $.fs.read(f)).trim() || null
}
// The paths every other session holds tonight.
const othersReports = async ($: EngineInterface, generation: string, self: string): Promise<Set<string>> => {
  const dir = await reportsDirOf($, generation)
  const ls = await run($, ['ls', dir])
  const out = new Set<string>()
  if (ls.exitCode !== 0) return out
  for (const name of ls.stdout.split('\n').map(s => s.trim())) {
    if (!name.endsWith('.path') || name === `${self}.path`) continue
    out.add((await $.fs.read(`${dir}/${name}`)).trim())
  }
  return out
}
// The project a report is named by: its checkout's folder, as Dan names his projects, else the session's.
const projectName = async ($: EngineInterface): Promise<string> => {
  let root: string | null = null
  try {
    root = (await $.session.repo())?.root ?? null
  } catch {
    root = null
  }
  const dir = (root ?? (await $.session.cwd())).replace(/\/+$/, '')
  return dir.split('/').pop() || dir
}
// This session's report for a night: the first name neither on the disk (an earlier sleep's, the
// same night) nor held by another session tonight.
const chooseReport = async ($: EngineInterface, night: string, generation: string): Promise<string> => {
  const home = (await sleepPaths($)).home
  const self = await $.session.id()
  const taken = await othersReports($, generation, self)
  const project = await projectName($)
  const title = reportTitle(await titleNow($))
  for (let n = 1; n <= 50; n++) {
    const path = `${home}/Downloads/${reportBase({ night, project, title, sessionId: self, n })}.md`
    if (!taken.has(path) && !(await $.fs.exists(path))) return path
  }
  throw new Error('fifty names for it were all taken')
}
// Records where this session's report goes, so the render writes it from then on: linked into place,
// so whichever of this session and the report script (which names a report for a session with news
// that has not named its own) is first keeps the name, fixed from then on. Null once recorded, by
// either; otherwise why not.
const recordReport = async ($: EngineInterface, generation: string, path: string): Promise<string | null> => {
  const dir = await reportsDirOf($, generation)
  const self = await $.session.id()
  const tmp = `${dir}/.${self}.${Math.random().toString(36).slice(2, 10)}.tmp`
  try {
    const mk = await run($, ['mkdir', '-p', dir])
    if (mk.exitCode !== 0) return mk.stderr.trim() || `mkdir exited ${mk.exitCode}`
    await $.fs.write(tmp, path)
    const ln = await run($, ['ln', tmp, `${dir}/${self}.path`])
    if (ln.exitCode === 0 || /File exists/i.test(ln.stderr)) return null
    return ln.stderr.trim() || `ln exited ${ln.exitCode}`
  } catch (err) {
    return msg(err)
  } finally {
    await run($, ['rm', '-f', tmp])
  }
}

// The nights whose report this session has named, or found named: once each.
const reportNamed = new Set<string>()
// Each minute while asleep on a per session night: a session with news, a worker or one that noted
// something, names its report once and renders it, so it exists from that minute. A failure is
// logged and tried again at the next minute.
const reportMinute = async ($: EngineInterface, reading: SleepReading) => {
  if (reading.state !== 'asleep' || reading.record.reportsPerSession !== true) return
  const { generation, night } = reading.record
  if (typeof generation !== 'string' || typeof night !== 'string' || reportNamed.has(generation)) return
  if (await ownReport($, generation)) {
    reportNamed.add(generation)
    return
  }
  const self = await $.session.id()
  const worker = Array.isArray(reading.record.workers) && reading.record.workers.includes(self)
  if (!worker) {
    const p = await sleepPaths($)
    const path = notesOf(p.home, generation)
    const notes = (await $.fs.exists(path)) ? await $.fs.read(path) : ''
    const mine = notes.split('\n').some(l => {
      try {
        return (JSON.parse(l) as { by?: unknown }).by === self
      } catch {
        return false
      }
    })
    if (!mine) return
  }
  const failed = await recordReport($, generation, await chooseReport($, night, generation))
  if (failed) {
    $.ui.log(`scope-modes: this session's sleep report could not be named (${failed}); tried again at the next minute`, { to: 'debug' })
    return
  }
  reportNamed.add(generation)
  const unrendered = await report($, ['render', '--record', (await sleepPaths($)).current])
  if (unrendered) $.ui.log(`scope-modes: this session's sleep report was named but could not be rendered yet (${unrendered})`, { to: 'debug' })
}

// ---- The morning reminder (#1107): its decisions are in hooks/morning.ts ----

/** The manual steps mod's noun, as its contract has it; it may not be loaded at all. */
type ManualStepsNoun = {
  add: (input: { heading: string; step: ReturnType<typeof morningStep> }) => Promise<{ isShown: boolean; reason?: string }>
  finish: (input: { title: string }) => Promise<{ isFinished: boolean }>
}
// The noun is called in place (the engine refuses one bound or passed), so its absence (the mod not
// loaded) arrives as a TypeError naming the noun call itself, read by the one reader (#1281); any
// other failure is said and tried again, a manual steps whose loaded copy lacks the member among
// them (the skew's own sentence), since its card may still hold the step (lessons review).
const isAbsentNoun = (err: unknown) => {
  const m = missingOf(err)
  return m?.kind === 'noun' && m.noun === 'manualSteps'
}
const STEP_SAID = 'The reminder to end sleep mode'

// The nights whose step this session has pinned on its card (#1283), and taken off, or tried to: once each.
const pinnedHere = new Set<string>()
const takenOff = new Set<string>()

const reviewsPath = async ($: EngineInterface) => `${(await sleepPaths($)).dir}/morning-review.json`
const readReviews = async ($: EngineInterface): Promise<MorningReview[] | { unreadable: string }> => {
  const path = await reviewsPath($)
  if (!(await $.fs.exists(path))) return []
  return reviewsIn(await $.fs.read(path))
}
// Changed and written whole. A file that cannot be read is never written over (lessons review): it
// is moved aside, kept for whoever reads it, and a new one started, which is logged; a move that
// fails refuses the change. Changed under its own lock, since /sleep in one session and a wake in
// another can change it at once, and the later write would drop the other's night (lessons review).
const changeReviews = async ($: EngineInterface, fn: (all: MorningReview[]) => MorningReview[]): Promise<string | null> => {
  let claim: Claim
  let lock: string
  try {
    lock = `${(await sleepPaths($)).dir}/morning-review.lock`
    claim = await takeLock($, lock)
  } catch (err) {
    return msg(err)
  }
  if ('held' in claim) return `session ${claim.held.owner} has been changing the record of the morning reviews since ${etWhen(claim.held.at)}`
  if ('unreadable' in claim) return `the lock on the record of the morning reviews cannot be read (${claim.unreadable})`
  if ('failed' in claim) return `the lock on the record of the morning reviews could not be taken (${claim.failed})`
  try {
    const path = await reviewsPath($)
    const all = await readReviews($)
    if (!Array.isArray(all)) {
      const aside = `${path}.unreadable-${await $.clock.now()}`
      const mv = await run($, ['mv', path, aside])
      if (mv.exitCode !== 0) return `the record of the morning reviews could not be read (${all.unreadable}) nor moved aside (${mv.stderr.trim() || `mv exited ${mv.exitCode}`})`
      $.ui.log(`scope-modes: the record of the morning reviews could not be read (${all.unreadable}), so it was moved to ${aside} and a new one started`, { to: 'debug' })
    }
    return await writeWhole($, path, JSON.stringify(fn(Array.isArray(all) ? all : [])))
  } catch (err) {
    return msg(err)
  } finally {
    await releaseMarker($, lock, claim.claimed)
  }
}

// The step on this session's card, once a night; the noun's throw is the caller's to read.
const pinStep = async ($: EngineInterface, night: { generation: string; night: string }) => {
  const shown = await ($ as unknown as { manualSteps: ManualStepsNoun }).manualSteps.add({ heading: MORNING_HEADING, step: morningStep(night.night) })
  pinnedHere.add(night.generation)
  return shown
}

// /sleep that began a night pins the step (#1107), in a session with somebody at its prompt, once the
// night is noted as waiting on it, so the step never stands where nothing could take it off. Every
// other live session pins it at its next minute (#1283, reminderMinute).
const pinMorning = async ($: EngineInterface): Promise<string> => {
  if (!interactive) return ''
  const r = await sleepNow($)
  if (r.state !== 'asleep' || typeof r.record.generation !== 'string' || typeof r.record.night !== 'string') return ''
  const night = { generation: r.record.generation, night: r.record.night }
  const failed = await changeReviews($, all => withPending(all, night))
  if (failed) return ` ${STEP_SAID} was not pinned: the night could not be noted as waiting on it (${failed}).`
  try {
    const shown = await pinStep($, night)
    // Shown, the card says it (L605); only a step that is not is said here.
    return shown.isShown ? '' : ` ${STEP_SAID} is kept on the manual steps card but not shown now: ${shown.reason ?? 'no reason given'}.`
  } catch (err) {
    if (isAbsentNoun(err)) pinnedHere.add(night.generation)
    return ` ${STEP_SAID} could not be pinned: ${isAbsentNoun(err) ? 'the manual steps mod is not loaded' : msg(err)}.`
  }
}

// The step off this session's card, by its night's title; the mod not loaded holds no card. Anything
// else is said by the caller, and the night is tried again at the next minute (lessons review): it is
// marked done here only once the call answered.
const takeOff = async ($: EngineInterface, r: { generation: string; night: string }): Promise<string | undefined> => {
  try {
    await ($ as unknown as { manualSteps: ManualStepsNoun }).manualSteps.finish({ title: morningStep(r.night).title })
  } catch (err) {
    if (!isAbsentNoun(err)) return msg(err)
  }
  takenOff.add(r.generation)
  return undefined
}

// At the end of a night, by the session that ended it, by a wake or its noon end (#1283): ending sleep
// is the review, so the night is noted ended on disk for every session's card, taken off this one's,
// and said, never gated on pickers answered. A night that pinned no step says nothing of one.
const endedAtWake = async ($: EngineInterface, record: SleepRecord | null): Promise<string> => {
  if (typeof record?.generation !== 'string') return ''
  let all: MorningReview[] | { unreadable: string }
  try {
    all = await readReviews($)
  } catch (err) {
    all = { unreadable: msg(err) }
  }
  if (!Array.isArray(all)) {
    $.ui.log(`scope-modes: the record of the morning reviews could not be read (${all.unreadable}), so the reminder is left to each session's minute`, { to: 'debug' })
    return ''
  }
  const r = all.find(x => x.generation === record.generation)
  if (!r || r.done) return ''
  const at = await $.clock.now()
  const failed = await changeReviews($, a => withDone(a, r, { at, how: 'sleep-ended' }))
  const off = await takeOff($, r)
  return `${ENDED_SAID}${failed ? ` The other sessions could not be told (${failed}), so each takes it off at its next minute once the night reads ended.` : ''}${off ? ` It could not be taken off this session's card (${off}).` : ''}`
}

// Each minute, in every session (#1283). Asleep, the night's step is pinned on this session's card
// once, the night noted as waiting first so something always takes it off. Every pending night but
// the one asleep now has ended, however it ended (a session that died mid wake included), so it is
// noted ended; a sleep record that cannot be read may still be asleep, so then nothing is. And a
// night ended anywhere has its step taken off here. A record of the nights that cannot be read
// changes nothing on a guess (L215).
const reminderMinute = async ($: EngineInterface, reading: SleepReading) => {
  let all = await readReviews($)
  if (!Array.isArray(all)) {
    $.ui.log(`scope-modes: the record of the morning reviews could not be read (${all.unreadable})`, { to: 'debug' })
    return
  }
  const asleep = reading.state === 'asleep' && typeof reading.record.generation === 'string' ? { generation: reading.record.generation, night: reading.record.night } : null
  // A record asleep that names no generation cannot say which night is current, so it closes nothing either (lessons review).
  if (reading.state !== 'unreadable' && !(reading.state === 'asleep' && !asleep)) {
    const stale = stalePending(all, asleep?.generation ?? null)
    if (stale.length) {
      const at = await $.clock.now()
      const close = (a: MorningReview[]) => stale.reduce((x, r) => withDone(x, r, { at, how: 'sleep-ended' }), a)
      const failed = await changeReviews($, close)
      if (failed) $.ui.log(`scope-modes: nights that have ended could not be noted ended (${failed}), so they are tried again at the next minute`, { to: 'debug' })
      else all = close(all)
    }
  }
  if (interactive && asleep && typeof asleep.night === 'string' && !pinnedHere.has(asleep.generation)) {
    const night = { generation: asleep.generation, night: asleep.night }
    const known = all.find(x => x.generation === night.generation)
    const failed = known ? null : await changeReviews($, a => withPending(a, night))
    if (failed) $.ui.log(`scope-modes: the reminder to end sleep mode was not pinned here: the night could not be noted as waiting on it (${failed}); tried again at the next minute`, { to: 'debug' })
    else if (!known?.done) {
      try {
        const shown = await pinStep($, night)
        if (!shown.isShown) $.ui.log(`scope-modes: the reminder to end sleep mode is kept on this session's card but not shown now: ${shown.reason ?? 'no reason given'}`, { to: 'debug' })
      } catch (err) {
        // The mod not loaded holds no card, so there is nothing to pin; anything else is tried again.
        if (isAbsentNoun(err)) pinnedHere.add(night.generation)
        else $.ui.log(`scope-modes: the reminder to end sleep mode could not be pinned here (${msg(err)}); tried again at the next minute`, { to: 'debug' })
      }
    }
  }
  for (const r of all) {
    if (!r.done || takenOff.has(r.generation)) continue
    const off = await takeOff($, r)
    if (off) $.ui.log(`scope-modes: the reminder to end sleep mode could not be taken off this session's card (${off})`, { to: 'debug' })
  }
}

// /wake and "I'm up" (#840): the record is moved aside, and only the session whose move succeeds
// acts. Phase 9 (#837): that session alone opens the report, asks the other workers for their
// summaries, and comes back with the morning prompt (its summary and the pickers) for its caller to
// start: a turn of its own after /wake, the turn already starting after "I'm up".
// `off` is whether this call turned sleep mode off, so only that is acknowledged as a switch (#1086).
type Woke = { said: string; morning: string | null; off: boolean }
const wake = async ($: EngineInterface, fromPhone = false): Promise<Woke | null> => {
  const said = (s: string): Woke => ({ said: s, morning: null, off: false })
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
  if (reading.state === 'unreadable') return { ...said(`Sleep mode is off. Its record could not be read (${reading.why}), so where each session delivers is left as it is.`), off: true }
  const placed = await restorePlace($, record)
  // The overnight check's notes go in before the report is finished, so they are at its top (#834).
  const checked = await overnightCheck($, record, moved.to)
  let s = `Sleep mode is off.${record?.since ? ` It began at ${etWhen(record.since)}.` : ''}${placed ? ` ${placed}` : ''}${checked ? ` ${checked}` : ''}`
  // The report once more, checked against GitHub, by the one session that woke it (#835).
  if (record?.report) {
    const problems = await finishReport($, moved.to, { kind: 'woke' })
    // A per session night (#1287) opens this session's own report; an older record its one report.
    let own: string | null | { unread: string } = record.report
    if (record.reportsPerSession === true && typeof record.generation === 'string') {
      const g = record.generation
      own = await ownReport($, g).catch((err: unknown) => ({ unread: msg(err) }))
    }
    if (own !== null && typeof own === 'object') {
      s += ` Where this session's report is could not be read (${own.unread}); each session's report is in Downloads, named by night, project and session.`
    } else if (own) {
      s += problems.length ? ` The night's report at ${own} is not complete: ${problems.join('; ')}.` : ` The night's report is at ${own}.`
      s += ` ${await openReport($, own, fromPhone)}`
    } else {
      s += ' This session noted nothing overnight, so it has no report of its own; each session with news has one in Downloads, named by night, project and session.'
      if (problems.length) s += ` The night's reports are not complete: ${problems.join('; ')}.`
    }
  } else {
    // Read as sound a moment ago, unreadable once moved: said, never a silent missing report.
    s += ` The night's report was not finished: the record moved aside to ${moved.to} could not be read${record ? ' for where its report is' : ''}.`
  }
  const others = await othersAtWake($, record, self)
  if (others) s += ` ${others}`
  // This session's own morning (#1285), the night's proposals with it since it ended sleep, and what
  // it held overnight (#1284), kept until that turn has gone in and meanwhile out of the minute's
  // own asking. Noted as offering first, so a turn that never goes in leaves the minute to offer them.
  const night = endedNight(record, self)
  const held = [...(await heldList($))]
  morningInFlight = { generation: night.generation, held }
  try {
    await setNight($, night)
    const morning = await morningOf($, night, self, held)
    // The reminder (#1107): ending sleep is the review, so it comes off now in every session (#1283).
    const cleared = await endedAtWake($, record)
    if (cleared) s += ` ${cleared}`
    return { said: s, morning: morning.prompt, off: true }
  } catch (err) {
    // No morning turn will carry it, so the minute puts it to Dan instead (lessons review of #1284).
    morningInFlight = null
    throw err
  }
}

// The band's amber line, through the status bar: asleep first, then the scope, then away. Asleep
// is read live, and while it holds away is not said again: asleep holds what away holds on the Mac,
// and every result until wake besides (#1284).
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
// (L613). Each is given its git reading, and its gh readings (#961): the words it runs gh with, read
// by mod-kit's one reader of gh's arguments, and the merge helper, which mod-kit alone finds and
// reads as the gh pr merge it runs (#1251). Every command is asked, since only mod-kit can say which
// runs the helper; a reading mod-kit cannot give throws, and every check judging a call refuses it
// (or leaves its permission prompt for Dan) on a throw, so no merge is judged unread (L42, #961).
const readCommands = async ($: EngineInterface, raw: string): Promise<Cmd[]> => {
  const out: Cmd[] = []
  for (const c of await $.modkit.pipeline({ command: raw })) {
    const g = await $.modkit.git({ words: c.words })
    const cmd: Cmd = g ? { ...c, git: { sub: g.sub, args: g.args, ...(g.dir !== undefined ? { dir: g.dir } : {}) } } : { ...c }
    const ghAt = ghWords(c.words)
    const gh = ghAt ? await $.modkit.gh({ words: ghAt }) : undefined
    if (gh) cmd.gh = gh
    const helper = await $.modkit.mergeHelper(c)
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

const run = async ($: EngineInterface, argv: string[], timeoutMs = RUN_MS, env?: Record<string, string>, stdin?: string) => {
  try {
    return await $.process.run(argv, { timeoutMs, ...(env ? { env } : {}), ...(stdin !== undefined ? { stdin } : {}) })
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

// The work on the issue this session holds, as the queue reads it (`sleep-queue.sh work`): the tip
// of its sleep/ branch and the commits made in its reserved worktree, so a commit there is progress
// whoever made it, a subagent on a branch of its own included (#1119). Only its own claim: another
// worker's commits on its own claim are not this session's (#844). Nothing held reads as no work;
// null when unreadable.
const refsNow = async ($: EngineInterface, root: string | null, claim: ClaimReading, home: string): Promise<string | null> => {
  if (!root || claim.state !== 'held') return ''
  const r = await run($, ['bash', queueScript(home), 'work', root, String(claim.claim.issue)])
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
    const fingerprint = progressOf(notesText, en.self, await refsNow($, where.root, claim, en.home))
    // What this session works toward tonight, as /sleep recorded it (#1242); with none it stops.
    const goal = goalOf(en.record, en.self)
    const d = decideStop({
      now: en.now, self: en.self, generation: en.record.generation, repo: where.slug, driver, fingerprint, notesText,
      weekly: u.weekly, claim, goal, rules: goal === null ? '' : overnightRules(en.self, where.root, goal), skew: skewMet,
    })
    if (d.kind === 'stop') stoppedHere.add(stopKey(en))
    // A rest is for the skew met so far: one met after it, in the turn it starts, is met anew (#1281).
    if (d.kind === 'rest') skewMet = null
    if (d.record) {
      const unsaved = await saveDriver($, en, d.record)
      // A rest that was not recorded would never be resumed, so it is a stop like a block's (#1281).
      if (unsaved && (d.kind === 'block' || d.kind === 'rest')) {
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
    if (d.kind === 'rest') {
      // #1281: this mod's own manifest touched, so it loads again once the session is idle, against
      // the mod-kit loaded by then (measured on 2.1.302: a touch alone reloads a mod, at idle). The
      // time alone changes, so the sync carries nothing. A touch that fails leaves only mod-kit's own
      // pass to load it again, said in the night's notes.
      const touched = await run($, ['touch', '-c', `${$.plugin.root}/.claude-plugin/plugin.json`])
      if (touched.exitCode !== 0) await writeNotes($, en, [{ kind: 'finding', ...(where.slug ? { repo: where.slug } : {}), text: `this session's own manifest could not be touched to load its mods again (${touched.stderr.trim() || `touch exited ${touched.exitCode}`})` }])
      $.ui.log(`scope-modes: the overnight driver let this session rest: ${d.why}`, { to: 'debug' })
      return null
    }
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
  // The words it is started again with: after an API error's wait, or after a rest (#1281).
  const resume = await oneAtATime(async (): Promise<string | null> => {
    const en = await enrolledNow($, seen)
    if (!en || stoppedHere.has(stopKey(en))) return null
    const r = await loadDriver($, en)
    if (r.state !== 'ok') return null
    const d = { ...r.record }
    if (resumeDue(d, en.now)) {
      // Cleared and saved first, so a second tick never starts it twice.
      d.resumeAt = null
      return (await saveDriver($, en, d)) === null ? (d.restDue ? REST_RESUME : RESUME) : null
    }
    if (d.stopped || d.resumeAt !== null) return null
    const c = await claimNow($, en)
    if (c.state !== 'held' || c.claim.since === null) return null
    const active = activeMs(d.waits, c.claim.since, en.now)
    if (active < LIMITS.stuckMs) return null
    const where = await repoOf($)
    const why = `${Math.round(active / MIN)} minutes of active work on it, past the ${LIMITS.stuckMs / MIN / 60} hours an issue gets`
    const rel: Release = { issue: c.claim.issue, state: 'parked', why }
    d.parked = releaseTold('watchdog', rel, await endClaim($, en, where.root, rel), { root: where.root, self: en.self })
    if (await saveDriver($, en, d)) parkedHere.set(stopKey(en), d.parked)
    return null
  })
  if (!resume) return
  try {
    await $.prompt.submit({ text: resume })
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
    // the engine's HooksError (measured in the tests). Either way it is never live. A loaded is it
    // live whose copy lacks verdict is said as the skew it is (#1281).
    const missing = missingOf(err)
    if (missing?.kind === 'noun') return { unmeasured: 'the is it live mod is not loaded' }
    if (missing) return { unmeasured: msg(err) }
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
//
// How often GitHub is asked (#1037): each read spends the GraphQL allowance every gh command on the
// Mac shares (#1014), and the minute's check read every PR the session opened, plus one issue view
// per closing issue of each. So only what can still change is asked again: a merged PR read by its
// number never changes, so it is read once; a closing issue decides nothing until its PR merges, so
// it is read only then,
// and once closed is not read again while winding down stays on. A PR's reading is kept with when it
// was asked: a turn end (`fresh`) always asks again, while the minute's check asks again only once
// `wait` has passed, which starts at a minute and doubles, up to ten, each time the answer has not
// moved (an unchanged PR is waiting on its checks or on Dan). An answer that moved starts it at a
// minute again, and a read that failed keeps nothing, so the next minute asks again.
type PrSeen = { pr: PrJson | null; issues: Map<number, 'OPEN' | 'CLOSED'>; askedAt: number; wait: number }
const prSeen = new Map<string, PrSeen>()
const IDLE_MAX_MS = 10 * MIN
const closesOf = (pr: PrJson | null) => (pr?.closingIssuesReferences ?? []).map(x => x.number).filter((n): n is number => typeof n === 'number')
// Nothing about it can change: merged, with every issue it closes closed. Only a PR read by its
// number: a lookup by branch asks which PR a branch has, which a new PR on that name changes.
const allSettled = (s: PrSeen, byNumber: boolean) => byNumber && s.pr?.state === 'MERGED' && closesOf(s.pr).every(n => s.issues.get(n) === 'CLOSED')
const seenSaid = (s: Pick<PrSeen, 'pr' | 'issues'>) => JSON.stringify([s.pr?.number, s.pr?.state, s.pr?.headRefOid, closesOf(s.pr), [...s.issues]])

// THE ONE POLLING POLICY (#1482, hooks/lib/gh-poll.sh, reached through mod-kit's ghpoll.ts). On
// 2026-10-22 GitHub's burst limit refused every session on the account for about 40 minutes while one
// session's loops polled at once, and this minute's check is one such loop. So each read first takes
// a look from the session's shared budget, a failed read's error is handed back (a rate limit answer
// pauses every loop in the session), and the wait above is the library's: doubled while the PR has
// not moved, a minute again once it has, within winding down's own ceiling of ten minutes. A look the
// policy holds keeps the minute's last reading, never a turn end's, which only GitHub's answer now
// can finish (#1037). A policy that cannot be asked never stops the read: it is said once in the
// debug log, and the wait falls back to a minute.
let pollNoted = false
const pollOf = async ($: EngineInterface): Promise<Poll | undefined> => {
  const home = await $.env.get('HOME')
  return home ? { run: (argv, env) => $.process.run(argv, env ? { env } : {}), lib: pollLib(home), session: await $.session.id() } : undefined
}
const pollFailed = ($: EngineInterface, err: unknown) => {
  if (pollNoted) return
  pollNoted = true
  $.ui.log(`scope-modes: the polling policy (gh-poll.sh) could not be asked, so winding down reads its PRs without it: ${msg(err)}`, { to: 'debug' })
}
/** Why the policy holds this look, or undefined when the look is taken. */
const heldLook = async ($: EngineInterface, poll: Poll | undefined, now: number): Promise<string | undefined> => {
  if (!poll) return undefined
  try {
    const t = await takeLook(poll, now)
    if (t.take) return undefined
    const secs = Math.ceil(t.waitMs / 1000)
    return t.why === 'pause'
      ? `GitHub is not being asked: this session's looks are paused for its rate limit (${t.said || 'it refused a read'}), for ${secs}s more`
      : `GitHub is not being asked: this session's loops have used their looks for this minute, so for ${secs}s more`
  } catch (err) {
    pollFailed($, err)
    return undefined
  }
}

/** The files uncommitted in a checkout, by git status (#1051), or why they could not be read. */
const uncommittedIn = async ($: EngineInterface, root: string): Promise<string[] | { unreadable: string }> => {
  const st = await run($, ['git', '-C', root, 'status', '--porcelain', '--untracked-files=all'])
  return st.exitCode === 0 ? porcelainFiles(st.stdout) : { unreadable: st.stderr.trim() || `git status exited ${st.exitCode}` }
}

// The files this session or its agents wrote (#1108), noted after each call that ran (noteWritten).
const writtenOf = async ($: EngineInterface) => (await $.state.get(writtenRef)).value ?? []
/**
 * The files uncommitted in a checkout split into this session's own, which it or its agents wrote, and
 * the rest (#1108): in a shared checkout the rest is another session's work, or a job's, never this
 * session's to finish. Every reader of uncommitted work while winding down asks this one.
 */
const uncommittedOwn = async ($: EngineInterface, root: string): Promise<{ own: string[]; others: string[] } | { unreadable: string }> => {
  const all = await uncommittedIn($, root)
  return Array.isArray(all) ? whoseFiles(all, root, await writtenOf($)) : all
}

type WindOpts = { repo?: string; elsewhere?: boolean; fresh?: boolean; inherited?: boolean }
const readWind = async ($: EngineInterface, t: ScopeModesTarget, o: WindOpts = {}): Promise<{ reading: Reading; found?: Found }> => {
  const { repo, elsewhere = false, fresh = false, inherited = false } = o
  const r: Reading = { branch: t.branch, isDefault: t.isDefault, pr: null, branchHere: false, branchOnGitHub: false, worktreeOnBranch: false, deploy: null, dirty: [], ...(inherited ? { inherited } : {}) }
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
  // A branch that is not the session's (#1074) has no PR of the session's to read, and the default
  // branch is not a PR's branch, so neither is looked up on GitHub (#1037); a PR already found is.
  const readsPr = !!t.pr || (!inherited && !t.isDefault && !!t.branch)
  if (gone && !slug && readsPr) return { reading: { ...r, pr: { unreadable: `${goneSaid}, and no repository is named to read its PR in` } } }
  if (readsPr) {
    const now = await $.clock.now()
    const key = `${(slug ?? '').toLowerCase()}|${t.pr ? `#${t.pr}` : `@${t.branch}`}`
    const seen = prSeen.get(key)
    let pr: PrJson | null
    let issues: Map<number, 'OPEN' | 'CLOSED'>
    const poll = seen && (allSettled(seen, !!t.pr) || (!fresh && now < seen.askedAt + seen.wait)) ? undefined : await pollOf($)
    const held = poll ? await heldLook($, poll, now) : undefined
    // A held look keeps the minute's last reading; a turn end's, or one with none, says why it has none.
    if (held !== undefined && (fresh || !seen)) return { reading: { ...r, pr: { unreadable: held } } }
    if (seen && (held !== undefined || allSettled(seen, !!t.pr) || (!fresh && now < seen.askedAt + seen.wait))) {
      pr = seen.pr
      issues = seen.issues
    } else {
      if (t.pr && seen?.pr?.state === 'MERGED') pr = seen.pr
      else {
        const res = t.pr
          ? await gh(['pr', 'view', String(t.pr), ...where, '--json', PR_FIELDS])
          : await gh(['pr', 'list', '--head', t.branch, ...where, '--state', 'all', '--limit', '1', '--json', PR_FIELDS])
        if (res.exitCode !== 0) {
          if (poll) await failedLook(poll, now, res.stderr).catch(err => pollFailed($, err))
          return { reading: { ...r, pr: { unreadable: res.stderr.trim() || `gh exited ${res.exitCode}` } } }
        }
        try {
          const j = JSON.parse(res.stdout) as PrJson | PrJson[]
          const one = Array.isArray(j) ? j[0] : j
          pr = one && typeof one.number === 'number' ? one : null
        } catch {
          return { reading: { ...r, pr: { unreadable: 'gh answered something that is not JSON' } } }
        }
      }
      issues = new Map(seen?.issues)
      // Its issues decide nothing until it has merged (outstanding reads them only then).
      if (pr?.state === 'MERGED')
        for (const n of closesOf(pr)) {
          if (issues.get(n) === 'CLOSED') continue
          const v = await gh(['issue', 'view', String(n), ...where, '--json', 'state'])
          if (v.exitCode !== 0) {
            if (poll) await failedLook(poll, now, v.stderr).catch(err => pollFailed($, err))
            return { reading: { ...r, pr: { unreadable: `issue #${n}: ${v.stderr.trim()}` } } }
          }
          const s = (JSON.parse(v.stdout) as { state?: string }).state
          issues.set(n, s === 'CLOSED' ? 'CLOSED' : 'OPEN')
        }
      const moved = !seen || seenSaid(seen) !== seenSaid({ pr, issues })
      let wait = MIN
      if (poll) {
        try {
          wait = await nextWaitMs(poll, seen?.wait ?? MIN, moved, { baseMs: MIN, maxMs: IDLE_MAX_MS })
          await answeredLook(poll)
        } catch (err) {
          wait = MIN
          pollFailed($, err)
        }
      }
      prSeen.set(key, { pr, issues, askedAt: now, wait })
    }
    if (pr) {
      if (!r.branch && typeof pr.headRefName === 'string') r.branch = pr.headRefName
      const state = pr.state === 'MERGED' || pr.state === 'CLOSED' ? pr.state : 'OPEN'
      const closes = closesOf(pr)
      r.pr = {
        number: pr.number as number,
        state,
        ...(typeof pr.headRefOid === 'string' && pr.headRefOid ? { head: pr.headRefOid } : {}),
        issues: state === 'MERGED' ? closes.map(n => ({ number: n, state: issues.get(n) === 'CLOSED' ? ('CLOSED' as const) : ('OPEN' as const) })) : [],
      }
      prUrl = typeof pr.url === 'string' ? pr.url : undefined
      found = { number: pr.number as number, closes, url: prUrl }
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
  // Only what this session wrote is its unfinished work; the rest is kept to be said once (#1108).
  if ((t.isDefault || inherited) && r.pr === null && !gone) {
    const split = await uncommittedOwn($, t.root)
    if ('unreadable' in split) r.dirty = split
    else {
      r.dirty = split.own
      if (split.others.length) r.notMine = split.others
    }
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

// The branches this session made its own (#1074): created, committed to or pushed.
const branchesOf = async ($: EngineInterface) => (await $.state.get(branchesRef)).value ?? []
const leftBranchOf = async ($: EngineInterface) => (await $.state.get(leftBranchRef)).value ?? []
const cleanupOf = async ($: EngineInterface) => (await $.state.get(cleanupRef)).value ?? []
// A branch the checkout is on that this session neither created, committed to nor pushed (#1074): its
// checkout sitting on it says nothing about whose it is, so it has nothing of the session's to finish.
const inheritedBranch = (t: ScopeModesTarget, mine: readonly string[]) => !t.isDefault && !!t.branch && t.pr === null && !mine.includes(t.branch)

// What is still to do and what Dan chose to leave as it is, or null when winding down is not on.
// `fresh` asks GitHub again about everything that can still change (a turn end); the minute's check
// asks only once a PR's wait has passed (#1037).
const check = ($: EngineInterface, fresh = false): Promise<Checked | null> => {
  if (checking && (checkingFresh || !fresh)) return checking
  // A turn end waits for a minute's check under way, then asks afresh.
  if (checking) return checking.then(() => check($, true))
  checkingFresh = fresh
  checking = (async (): Promise<Checked | null> => {
    if ((await scopeOf($)) !== 'WINDING DOWN') return null
    let t = (await $.state.get(targetRef)).value ?? null
    if (t && 'unreadable' in t) {
      const again = await readTarget($)
      await $.state.set(targetRef, again)
      if (again && 'unreadable' in again) return { left: [`what this session is working on could not be read (${again.unreadable})`], kept: [], keptBranches: [] }
      t = again
    }
    // Outside a repository there is no PR, branch or deploy to finish.
    if (!t) return { left: [], kept: [], keptBranches: [] }
    // A check that throws must refuse the turn end: a Stop hook that fails is skipped, which would
    // let the turn end unfinished (L42).
    try {
      const mine = await branchesOf($)
      // On its default branch, or a branch that is not its own (#1074), with no PR, the session may
      // have moved onto a branch since winding down turned on (#702): follow it there.
      if ((t.isDefault || inheritedBranch(t, mine)) && t.pr === null) {
        const now = await readTarget($)
        if (now && !('unreadable' in now) && now.branch !== t.branch) {
          t = now
          await $.state.set(targetRef, t)
        }
      }
      const { reading, found } = await readWind($, t, { fresh, inherited: inheritedBranch(t, mine) })
      t = await keepFound($, t, found)
      // A PR is left as it is only on Dan's own answer to leave_pr_open, recorded against its
      // repository and number: open at its head (#917), or closed without merging (#1033). With none
      // recorded, #856's default holds and it is outstanding. A branch is left as it is only on his
      // answer to leave_branch, by repository and name (#1074).
      const choices = await leftOpenOf($)
      const branchChoices = await leftBranchOf($)
      const kept: ScopeModesLeftAsIs[] = []
      const keptBranches: ScopeModesLeftBranch[] = []
      const toDo = (r: Reading, repo: string | undefined) => {
        const pr = r.pr
        const d = repo && pr && !('unreadable' in pr) ? choiceFor(choices, repo, pr.number) : undefined
        const b = repo && r.branch ? branchChoiceFor(branchChoices, repo, r.branch) : undefined
        const withChoice: Reading = { ...r, ...(d ? { choice: d } : {}), ...(b ? { branchLeft: b } : {}) }
        if (d && settledByDan(withChoice)) kept.push(d)
        // Said as kept by his choice only where his answer settled something (lessons review).
        if (b && settledByBranchChoice(withChoice) && !keptBranches.includes(b)) keptBranches.push(b)
        return outstanding(withChoice)
      }
      const left = toDo(reading, (await repoOfLink($, found?.url)) ?? (choices.length || branchChoices.length ? await sessionSlug($) : undefined))
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
        const one = await readWind($, { root: t.root, branch: '', isDefault: false, issues: [], pr: o.number, ...(t.main ? { main: t.main } : {}) }, { repo: o.repo, elsewhere, fresh })
        if (one.found && !sameList(o.closes, one.found.closes)) {
          const closes = one.found.closes
          await $.state.set(openedRef, (await openedOf($)).map(x => (x.repo === o.repo && x.number === o.number ? { ...x, closes } : x)))
        }
        left.push(...toDo(one.reading, o.repo))
      }
      // One unreadable GitHub answers every read the same way, said once.
      return { left: [...new Set(left)], kept, keptBranches, ...(reading.notMine ? { notMine: reading.notMine } : {}) }
    } catch (err) {
      return { left: [`the finish check failed (${msg(err)})`], kept: [], keptBranches: [] }
    }
  })().finally(() => {
    checking = undefined
    checkingFresh = false
  })
  return checking
}

// How the branches Dan chose to leave as they are (#1074) are listed, apart from the PRs.
const keptBranchesSaid = (kept: readonly ScopeModesLeftBranch[], whose: string): string =>
  kept.length ? ` Left as it is by ${whose} choice: ${kept.map(b => `the branch ${b.branch} in ${b.repo} (${b.why})`).join('; ')}.` : ''

const finish = async ($: EngineInterface, c: Checked) => {
  await $.state.set(scopeRef, null)
  await $.state.set(targetRef, null)
  await showModes($)
  // Files this session did not write never held it (#1108), and are said here, the once.
  const notMine = c.notMine?.length ? ` Left uncommitted, since this session did not write them: ${filesSaid(c.notMine)}.` : ''
  $.ui.toast(`Wind down finished: safe to close this session.${keptSaid(c.kept, 'your')}${keptBranchesSaid(c.keptBranches, 'your')}${notMine}`)
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
  const asleep = await askedWhileAsleep($, await sleepNow($), question, `winding down still waits on ${pr}`)
  if (asleep) return asleep
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

// A name git takes for a branch, as far as these tools need: never an option, nor a path climbing out.
const isBranchName = (s: string) => /^[\w][\w./-]*$/.test(s) && !s.includes('..') && !s.endsWith('/') && !s.endsWith('.lock')
// A question for Dan while he sleeps is noted for his morning report, never asked (#841). Each caller
// reads the sleep predicate itself and hands it in, so the route that asks names it where
// tests/test-sleep-silence.sh reads it.
const askedWhileAsleep = async ($: EngineInterface, sleeping: SleepReading, question: string, still: string): Promise<string | null> => {
  if (sleeping.state !== 'asleep') return null
  const failed = await noteQuestion($, [question])
  return `Dan is asleep (sleep mode), so he was not asked and nothing was recorded: ${still}. ${
    failed === null ? 'The question is noted for his morning report.' : `It could not be noted for his morning report (${failed}), so put it in your final message.`
  }`
}

// leave_branch (#1074): asks Dan whether a branch stays as it is rather than being cleaned up. On
// 2026-10-11 he answered "leave it as is" twice about a branch a shared checkout sat on, and nothing
// could record it, so every stop was refused again. Only his "Leave it as it is" is recorded, by the
// branch's repository and name: winding down then stops waiting for the branch to be deleted here or
// a worktree on it to go, and, when this session's checkout is on it, for the files uncommitted there
// as he answered (named in the question, so a change to any other file asks again). The branch on
// GitHub is not covered: it holds no checkout, so deleting it moves nobody's work. Any other answer
// withdraws an earlier one. Nothing is asked while Dan is asleep (#841).
const leaveBranch = async ($: EngineInterface, input: Record<string, unknown>): Promise<string> => {
  const branch = String(input.branch ?? '').trim()
  if (!isBranchName(branch)) return `"${branch}" is not a branch name git takes, so Dan was not asked and nothing was recorded.`
  const named = String(input.repo ?? '').trim()
  if (named && !/^[\w.-]+\/[\w.-]+$/.test(named)) return `"${named}" is not a repository (owner/name), so Dan was not asked and nothing was recorded.`
  const repo = named || (await sessionSlug($))
  if (!repo) return "This session's repository could not be read, so name the branch's repository (owner/name). Dan was not asked and nothing was recorded."
  const why = String(input.why ?? '').trim().replace(/[.?]+$/, '')
  if (!why) return `Say why the branch ${branch} would be left as it is (another session stands on it, say), so Dan can decide. He was not asked and nothing was recorded.`
  // The files his answer leaves uncommitted: this session's checkout's, when it is on that branch, and
  // only the ones this session wrote, which alone wind down waits on (#1108).
  let files: string[] = []
  let at
  try {
    at = await $.modkit.branch({ path: await $.session.cwd() })
  } catch (err) {
    return `Where this session's checkout stands could not be read (${msg(err)}), so Dan was not asked and nothing was recorded.`
  }
  if (at && !('unreadable' in at) && at.branch === branch && (!named || named.toLowerCase() === (await sessionSlug($))?.toLowerCase())) {
    const now = await uncommittedOwn($, at.root)
    if ('unreadable' in now) return `Whether anything is uncommitted in ${at.root} could not be read (${now.unreadable}), so Dan was not asked and nothing was recorded.`
    files = now.own
  }
  const question = `Leave the branch ${branch} in ${repo} as it is (${why})? Winding down stops waiting for it to be deleted here or for a worktree on it to go${
    files.length ? `, and for ${files.join(', ')} to be committed. A change to any other file asks again.` : '.'
  }`
  const asleep = await askedWhileAsleep($, await sleepNow($), question, `winding down still waits on the branch ${branch}`)
  if (asleep) return asleep
  let answer: string
  try {
    answer = await $.ui.ask(question, ['Leave it as it is', 'Clean it up'])
  } catch (err) {
    return `Dan was not asked (${msg(err)}), so nothing was recorded: winding down still waits on the branch ${branch}.`
  }
  // One answer per branch: a new one replaces whatever he said about it before.
  const others = (await leftBranchOf($)).filter(d => !(d.branch === branch && d.repo.toLowerCase() === repo.toLowerCase()))
  if (answer === 'Leave it as it is') {
    await $.state.set(leftBranchRef, [...others, { repo, branch, files, why }])
    return `Dan chose to leave the branch ${branch} in ${repo} as it is: winding down counts it settled${files.length ? `, with ${filesSaid(files)} uncommitted` : ''}.`
  }
  await $.state.set(leftBranchRef, others)
  if (answer === 'Clean it up') return `Dan said clean it up: winding down waits for the branch ${branch} to be deleted here and any worktree on it to go.`
  return `Dan did not choose to leave the branch ${branch} as it is, so winding down still waits on it. He wrote: ${answer}`
}

// open_cleanup_branch (#1051): while winding down, a new branch is new work, yet uncommitted changes
// are unfinished, so work that finishing itself needs committed (a reading a monthly job appended to a
// committed record, on 2026-10-09) had no way through but Dan turning winding down off. He is asked,
// with the files git status names in this session's checkout that this session wrote (#1108) and the
// reason; only his "Open it" is recorded, and lets that one branch start by checkout or switch (which
// carry the changes onto it), once, while nothing else this session wrote is uncommitted. Any other
// branch is still refused.
const openCleanupBranch = async ($: EngineInterface, input: Record<string, unknown>): Promise<string> => {
  if ((await scopeOf($)) !== 'WINDING DOWN') return "Winding down is not on, so no branch needs Dan's answer: make it as usual. He was not asked."
  const branch = String(input.branch ?? '').trim()
  if (!isBranchName(branch)) return `"${branch}" is not a branch name git takes, so Dan was not asked.`
  const why = String(input.why ?? '').trim().replace(/[.?]+$/, '')
  if (!why) return `Say why the branch ${branch} is needed (what the uncommitted change is), so Dan can decide. He was not asked.`
  const t = (await $.state.get(targetRef)).value ?? null
  if (!t) return 'This session is in no repository, so there is no branch to open. Dan was not asked.'
  if ('unreadable' in t) return `What this session is working on could not be read (${t.unreadable}), so Dan was not asked.`
  // Only the files this session wrote, which alone the finish check lists (#1108): in a shared
  // checkout the rest is another session's, never this branch's to carry.
  const split = await uncommittedOwn($, t.root)
  if ('unreadable' in split) return `Whether anything is uncommitted in ${t.root} could not be read (${split.unreadable}), so Dan was not asked.`
  const files = split.own
  if (!files.length && split.others.length)
    return `Nothing this session wrote is uncommitted in ${t.root} (${filesSaid(split.others)} ${split.others.length === 1 ? 'is' : 'are'} not its own), so there is no cleanup for a branch to commit. Dan was not asked.`
  if (!files.length) return `Nothing is uncommitted in ${t.root}, so there is no cleanup for a branch to commit. Dan was not asked.`
  // Every file is named: what Dan agrees to is exactly what the branch may carry (L64).
  const question = `Open the branch ${branch} to commit ${files.join(', ')} (${why})? Winding down lets it start for these files only, and finishes it like any other PR.`
  const asleep = await askedWhileAsleep($, await sleepNow($), question, `winding down still refuses the branch ${branch}`)
  if (asleep) return asleep
  let answer: string
  try {
    answer = await $.ui.ask(question, ['Open it', 'Do not'])
  } catch (err) {
    return `Dan was not asked (${msg(err)}), so nothing was recorded: winding down still refuses the branch ${branch}.`
  }
  const others = (await cleanupOf($)).filter(c => c.branch !== branch)
  if (answer === 'Open it') {
    await $.state.set(cleanupRef, [...others, { root: t.root, branch, files, why }])
    return `Dan agreed: make the branch ${branch} now, with git switch -c ${branch} in ${t.root}, commit only ${filesSaid(files)} on it, and open its PR. Winding down lets it start once, while nothing else is uncommitted.`
  }
  await $.state.set(cleanupRef, others)
  return `Dan did not agree to the branch ${branch}, so winding down still refuses it.${answer === 'Do not' ? '' : ` He wrote: ${answer}`}`
}

// Answers the scope mode that was on, which the acknowledgement of the switch names (#1055).
const setScope = async ($: EngineInterface, scope: ScopeModesScope | null): Promise<ScopeModesScope | null> => {
  const was = await scopeOf($)
  await $.state.set(scopeRef, scope)
  // Turning winding down on again keeps what it found, its PR included (#702): reading the target
  // afresh dropped a PR once the session had left its branch. An unreadable target is read again
  // at the next check.
  if (scope !== 'WINDING DOWN') await $.state.set(targetRef, null)
  else if (was !== 'WINDING DOWN') {
    await $.state.set(targetRef, await readTarget($))
    // Each time it turns on, GitHub is read afresh: nothing kept from an earlier wind down (#1037).
    prSeen.clear()
  }
  await showModes($)
  return was
}

// Adds to one of the lists noted after each call what it does not hold yet, read and written with
// ifVersion and again on a miss: the session's calls and its agents' finish at once, and a plain read
// then set lets the later write drop the other's entries (lessons review of #1108). The engine wants
// each state reference spelled where it is read or written, so the caller hands both in.
type ListIo<T> = { get: () => Promise<{ value?: T[] | null; version: number }>; set: (list: T[], ifVersion: number) => Promise<{ isSet: boolean }> }
const addToList = async <T,>(io: ListIo<T>, items: readonly T[], same: (a: T, b: T) => boolean) => {
  for (let attempt = 0; attempt < 10; attempt++) {
    const held = await io.get()
    const now = held.value ?? []
    const fresh = items.filter((x, i) => !now.some(n => same(n, x)) && items.findIndex(y => same(y, x)) === i)
    if (!fresh.length) return
    if ((await io.set([...now, ...fresh], held.version)).isSet) return
  }
  throw new Error('the list changed under every one of 10 attempts to add to it')
}
const sameText = (a: string, b: string) => a === b

// The branches a Bash call made this session's own (#1074), whatever mode is on, from the session or
// any of its agents: one it created or pushed by name, and for a commit or a push naming none, the
// branch checked out where it ran. That is known only for the session's own call with no `cd` before
// it (an agent works in a folder of its own), in its folder or the absolute one `git -C` names. A
// note that cannot be made is said, since winding down would then not finish that branch.
const noteBranches = async ($: EngineInterface, raw: string, agentId: unknown) => {
  try {
    const cmds = await readCommands($, raw)
    const { named, current } = branchesTouched(cmds)
    const add = [...named]
    const moved = cmds.some(c => c.words[0] === 'cd' || c.words[0] === 'pushd')
    if (current && agentId === undefined && !moved) {
      const dir = cmds.find(c => c.git?.dir !== undefined)?.git?.dir
      const path = dir === undefined ? await $.session.cwd() : dir.startsWith('/') ? dir : undefined
      const at = path ? await $.modkit.branch({ path }) : null
      if (at && 'unreadable' in at && at.unreadable !== DETACHED) throw new Error(at.unreadable)
      if (at && !('unreadable' in at) && at.branch) add.push(at.branch)
    }
    await addToList({ get: () => $.state.get(branchesRef), set: (l, v) => $.state.set(branchesRef, l, { ifVersion: v }) }, add, sameText)
  } catch (err) {
    // A skew is said once, never on every call that notes a branch (#1281), with what it costs
    // until then, since every later note is dropped too (lessons review).
    if (missingOf(err)?.kind === 'member') {
      const news = skewNews(err, MOD)
      if (news) $.ui.toast(`${news} ${NOTES_LOST}`)
      return
    }
    $.ui.toast(`Scope modes could not note which branch this call made the session's own (${msg(err)}), so winding down may not finish it.`)
  }
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
    await addToList<ScopeModesOpened>(
      { get: () => $.state.get(openedRef), set: (l, v) => $.state.set(openedRef, l, { ifVersion: v }) },
      [found],
      (a, b) => a.repo.toLowerCase() === b.repo.toLowerCase() && a.number === b.number,
    )
  } catch (err) {
    if (missingOf(err)?.kind === 'member') {
      const news = skewNews(err, MOD)
      if (news) $.ui.toast(`${news} ${NOTES_LOST}`)
      return
    }
    $.ui.toast(`Scope modes could not note the PR this call opened (${msg(err)}), so winding down will not know to finish it.`)
  }
}

// The files a call that ran wrote (#1108), noted whatever mode is on, from the session or any of its
// agents, so winding down later counts only those as this session's uncommitted work: an editing
// tool's file, and what mod-kit's one write reader names for a Bash call. A note that cannot be made
// is said, since winding down would then let that file go uncommitted: once a session, since it runs
// after every Bash call, read only ones included, so a reader that stays broken would otherwise toast
// on each (lessons review); later ones go to the debug log.
let writeNoteSaid = false
let patchSaid = false
const noteWritten =async ($: EngineInterface, tool: string, input: Record<string, unknown>, raw: string, stashed: readonly string[] = []) => {
  try {
    const writes = raw ? await readWrites($, raw) : NO_WRITES
    // A patch that cannot be read is said on its own, never losing the files the call wrote by every
    // other route (#1123 lessons review).
    let patched: string[] = []
    try {
      patched = await patchedFiles($, writes)
    } catch (err) {
      // Reading the patch file and finding the checkout it applies in can each fail; the cause in
      // brackets says which, and the sentence claims only that the files could not be told.
      const said = `Scope modes could not tell which files the patch this call applied changed (${msg(err)}), so winding down may not count them as this session's.`
      if (patchSaid) $.ui.log(`scope-modes: ${said}`, { to: 'debug' })
      else $.ui.toast(`${said} Later failures go to the debug log.`)
      patchSaid = true
    }
    const files = [...filesWritten({ tool, input, writes }), ...patched, ...stashed]
    await addToList({ get: () => $.state.get(writtenRef), set: (l, v) => $.state.set(writtenRef, l, { ifVersion: v }) }, files, sameText)
  } catch (err) {
    const said = `Scope modes could not note which files this call wrote (${msg(err)}), so winding down may not count them as this session's.`
    if (writeNoteSaid) $.ui.log(`scope-modes: ${said}`, { to: 'debug' })
    else $.ui.toast(`${said} Later failures go to the debug log.`)
    writeNoteSaid = true
  }
}

// The checkout a git command in a call works in (#1123): its -C folder, else the session's. A folder
// spelled with a variable cannot be followed, so it names none, and neither does a folder in no
// checkout. A cd earlier in the call is not followed: knowingly loose, since a stash and a patch's
// paths both belong to the whole checkout, so only a cd into another checkout reads the wrong one.
const gitCheckout = async ($: EngineInterface, dir: string | undefined): Promise<string | null> => {
  if (dir !== undefined && /[$`]/.test(dir)) return null
  const cwd = await $.session.cwd()
  return $.modkit.workingTree({ path: dir === undefined ? cwd : dir.startsWith('/') ? dir : `${cwd}/${dir}` })
}

// The files a patch git applies in a call changes (#1123), read from each patch file the write
// reader names, as paths in the checkout git applies it in.
const patchedFiles = async ($: EngineInterface, writes: ModKitWrites): Promise<string[]> => {
  const out: string[] = []
  for (const u of writes.unnamed) {
    if (u.what !== 'a patch') continue
    const g = await $.modkit.git({ words: u.words })
    if (g?.sub !== 'apply' && g?.sub !== 'am') continue
    const root = await gitCheckout($, g.dir)
    if (!root) continue
    for (const f of u.inputs) if (await $.fs.exists(f)) for (const p of patchedPaths(g.args, await $.fs.read(f))) out.push(`${root}/${p}`)
  }
  return out
}

// The files the stash a call's git stash pop or apply takes back holds (#1123), read before the call
// runs, since a pop drops it. One that cannot be read is said, as a note that cannot be made is, and
// the call runs all the same.
let stashSaid = false
const stashedFiles = async ($: EngineInterface, raw: string): Promise<string[]> => {
  if (!/\bstash\b/.test(raw)) return []
  const out: string[] = []
  try {
    for (const c of await readCommands($, raw)) {
      const ref = c.git?.sub === 'stash' ? stashTaken(c.git.args) : undefined
      if (!ref) continue
      const root = await gitCheckout($, c.git?.dir)
      if (!root) continue
      // -z: one name per NUL, never quoted, so a name with a space or an accent is read as it is.
      const r = await run($, ['git', '-C', root, 'stash', 'show', '--include-untracked', '--name-only', '-z', ref])
      if (r.exitCode !== 0) throw new Error(r.stderr.trim() || `git stash show exited ${r.exitCode}`)
      for (const f of r.stdout.split(/[\0\n]/)) if (f) out.push(`${root}/${f}`)
    }
  } catch (err) {
    const said = `Scope modes could not read which files the stash this call takes holds (${msg(err)}), so winding down may not count them as this session's.`
    if (stashSaid) $.ui.log(`scope-modes: ${said}`, { to: 'debug' })
    else $.ui.toast(`${said} Later failures go to the debug log.`)
    stashSaid = true
  }
  return out
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

// What the modes on make of one tool call: the refusal to answer it with, or undefined to let it run,
// or the cleanup answers (#1051) it runs on, which are used up once it has run (useCleanups).
type Judged = { tool: string; input: Record<string, unknown>; toolUseId: string; scope: ScopeModesScope | null; away: boolean; asleep: boolean }
type Verdict = { deny: string } | { cleanups: ScopeModesCleanup[] } | undefined
const judge = async ($: EngineInterface, j: Judged): Promise<Verdict> => {
  const { tool, input, toolUseId, scope, away, asleep } = j
  let cleanupsLet: ScopeModesCleanup[] = []
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
    // The cleanup branches Dan agreed to for this checkout (#1051), and of those, the ones whose files
    // cover everything this session wrote that is uncommitted now (#1108: another session's files
    // beside them are not this branch's to carry): read only for a call that starts a branch it moves onto.
    const root = t && 'root' in t ? t.root : undefined
    const agreed = root ? (await cleanupOf($)).filter(c => c.root === root) : []
    let now: string[] | { unreadable: string } | undefined
    if (root && agreed.length && commands.some(c => newBranchOf(c)?.moves)) {
      const split = await uncommittedOwn($, root)
      now = 'unreadable' in split ? split : split.own
    }
    // Nothing uncommitted is no cleanup to carry, so an answer left over covers nothing (lessons review).
    const covered = Array.isArray(now) && now.length ? agreed.filter(c => (now as string[]).every(f => c.files.includes(f))) : []
    const cleanBranches = covered.map(c => c.branch)
    let r = newWork({ tool, input, commands, issues: ownNumbers(t, opened), cleanBranches })
    // An agent named after this branch's PR or an issue it closes is this issue's work, so a PR not
    // looked up yet is looked up before the agent is refused (#702). A branch that is not the
    // session's (#1074) has no PR of its own to look up.
    if (r && (tool === 'Agent' || tool === 'Task') && t && 'issues' in t && !t.isDefault && t.pr === null && !inheritedBranch(t, await branchesOf($))) {
      t = await keepFound($, t, (await readWind($, t)).found)
      r = newWork({ tool, input, commands, issues: ownNumbers(t, opened), cleanBranches })
    }
    if (r) {
      // A branch Dan agreed to that is refused says why his answer did not cover it.
      const asked = r.branch ? agreed.find(c => c.branch === r?.branch) : undefined
      let why = ''
      if (asked && now && !Array.isArray(now)) why = ` Dan agreed to ${asked.branch}, but what is uncommitted could not be read (${now.unreadable}).`
      else if (asked && Array.isArray(now) && !now.length) why = ` Dan agreed to ${asked.branch} to commit ${filesSaid(asked.files)}, and nothing is uncommitted now.`
      else if (asked && Array.isArray(now)) {
        const beyond = now.filter(f => !asked.files.includes(f))
        why = ` Dan agreed to ${asked.branch} for ${filesSaid(asked.files)} only, and ${filesSaid(beyond)} ${beyond.length === 1 ? 'is' : 'are'} uncommitted too.`
      } else if (asked) why = ` Dan agreed to ${asked.branch} only by git checkout -b or git switch -c, which carry the uncommitted changes onto it.`
      else if (r.what === NEW_WORK.branch) why = ` If the branch is only to commit uncommitted changes winding down lists, ask Dan first with ${CLEANUP_TOOL}.`
      await $.modkit.blocked({ toolUseId, guard: 'Winding down', reason: `Winding down, so this would not ${r.what}.`, safeWay: 'Claude finishes this issue and files anything else.' })
      return { deny: `Blocked: winding down, so this did not ${r.what}.${why} Finish this issue; file anything new as an issue instead of working on it.` }
    }
    // The cleanup answers this call starts a branch on, used up once it has run (useCleanups).
    const used = covered.filter(c => commands.some(cmd => newBranchOf(cmd)?.name === c.branch))
    if (used.length) cleanupsLet = used
  }
  if (away) {
    // A Bash call by what its commands do on the Mac; another tool by what it opens (#702). Typing
    // or clicking into a test build runs (#1269), so the app the call types into is looked up first.
    const target = raw ? typedTarget(raw, commands) : undefined
    const testBuild = target !== undefined && (await isTestBuild(target, await testBuildFs($)))
    const label = raw ? needsTheMac({ raw, commands, testBuild }) : heldTool(tool, input)
    if (label) {
      const { tool: _t, tool_use_id: _id, agentId: _a, consent: _c, ...args } = input
      await hold($, label, `Do it now. What was held: ${raw || `${tool} ${JSON.stringify(args)}`}`)
      // Asleep, nothing is handed to Dan in its place (#1284): away's refusal says to publish a page.
      const held = asleep ? heldAsleep(label) : heldRefusal(label)
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
  return cleanupsLet.length ? { cleanups: cleanupsLet } : undefined
}

// Dan's cleanup answer (#1051) is used up, and that said, only once the checkout is on its branch
// after the call ran, read from the checkout itself: a call refused beneath this mod, or a switch
// that failed, leaves his answer to be used. A read that fails leaves it too, and is logged.
const useCleanups = async ($: EngineInterface, cleanups: readonly ScopeModesCleanup[]) => {
  for (const c of cleanups) {
    let at
    try {
      at = await $.modkit.branch({ path: c.root })
    } catch (err) {
      $.ui.log(`scope-modes: whether the cleanup branch ${c.branch} started could not be read (${msg(err)}), so Dan's answer is kept`, { to: 'debug' })
      continue
    }
    if (!at || 'unreadable' in at || at.branch !== c.branch) continue
    await $.state.set(cleanupRef, (await cleanupOf($)).filter(x => !(x.root === c.root && x.branch === c.branch)))
    $.ui.toast(`Winding down let the branch ${c.branch} start, for the cleanup Dan agreed to (${filesSaid(c.files)}).`)
  }
}

// What winding down means, said the same way in its note, its command's context and the Stop
// reason (#856): a session read "start nothing new" as permission to park a PR needing Dan.
// #917: the one way a PR stays open, and only on Dan's own answer, never Claude's reading of one.
const FINALIZE_ALL = `Winding down finalizes everything this session has open: every PR it opened is merged, never left open waiting on Dan. A PR stays open only on Dan's own answer to mcp__scope-modes__leave_pr_open, asked when he may want it left (for a reviewer outside this session, say), and a push after he answers asks again. A PR closed without merging is settled only on his answer to the same tool, which then asks whether to leave it closed (its work merged in another PR, say). A branch, a worktree on it or uncommitted work stays as it is only on his answer to ${LEAVE_BRANCH_TOOL}, and a new branch to commit uncommitted work starts only on his answer to ${CLEANUP_TOOL}.`
const ASK_THEN_MERGE = 'When a decision or sign off is needed, ask Dan right then with an AskUserQuestion picker, one question at a time, and merge once he answers; never end the turn waiting on him.'

// Each mode's note opens with its one definition (hooks/modes.ts), the same words the
// acknowledgement of turning it on says to Dan (#1055).
const SCOPE_NOTE: Record<ScopeModesScope, string> = {
  'NO BUILD': `No build is on: ${MODE_DEF['NO BUILD'].will}. Do not ${MODE_DEF['NO BUILD'].willNot}.`,
  'WINDING DOWN':
    `Winding down is on: ${MODE_DEF['WINDING DOWN'].will}. Do not ${MODE_DEF['WINDING DOWN'].willNot}: winding down refuses to ${MODE_DEF['WINDING DOWN'].refuses}. ${FINALIZE_ALL} ${ASK_THEN_MERGE} Fix only what blocks a merge or deploy; file anything else. After each merge, check the deploy and make the is it live card (mcp__is-it-live__card): winding down finishes only once that card says Live or no deploy step recorded.`,
}
const AWAY_NOTE = `Dan is away from the Mac: ${MODE_DEF.away.will} (the Artifact tool). Do not ${MODE_DEF.away.willNot}.`
// What Claude is told on each prompt while the Mac sleeps: only what phase 1 does (L703).
const sleepPromptNote = (r: SleepRecord, self: string, now: number) =>
  `Sleep mode is on until ${endSaid(r.until, now)}. ${r.workers?.includes(self) ? `This session is enrolled to work overnight. ${WORKER_NOTE}` : 'This session is not one of the overnight workers.'} ${ASLEEP_DELIVERY}`
// What phase 3 (#834) does for a worker, and only that (L703).
const WORKER_NOTE =
  "Its permission prompts are approved by themselves, except a question for Dan, the plan approval and what Dan bans while he sleeps, which are refused with the reason. A refusal, by that list or by the auto mode classifier, is final: never look for another way to do it; skip that issue."
const HOME_NOTE = `Dan is back at the Mac: ${MODE_DEF.home.will}.`

// Whether a prompt is Dan's own words, asked of mod-kit's one reader (#1135). One that cannot answer
// (a mod-kit loaded before it had the reader, which a reload can leave, standing rule 5) reads the
// prompt as not his, the side that changes nothing here, said once in the transcript; the prompt
// itself always goes on (L73).
let toldNoReader = false
const dansWords = async ($: EngineInterface, origin: { readonly kind?: string } | undefined): Promise<boolean> => {
  try {
    return await $.modkit.isDans({ origin })
  } catch (err) {
    if (!toldNoReader) {
      toldNoReader = true
      $.ui.log(`Scope modes could not ask mod-kit whether your message was your own words (${err instanceof Error ? err.message : String(err)}), so it read it as not yours. A new session loads mod-kit again.`)
    }
    return false
  }
}

export const register: Register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    // Asleep (#840) holds what away holds on the Mac, whatever a session's own place. The engine refuses
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
      hold: async ({ label, prompt, action }) => {
        if (((await built.state.get(placeRef)).value ?? 'home') !== 'away' && !(await nounSeesAsleep())) return { isHeld: false }
        // What a guard names that runs while away or asleep (#1269): it goes ahead asking nobody.
        // The engine refuses handing `built` to a helper, so its file system is read in place here.
        if (action) {
          let home: string | undefined
          try {
            home = await built.env.get('HOME')
          } catch {
            home = undefined
          }
          if (await awayAllows(action, { home, treeOf: path => built.modkit.workingTree({ path }) })) return { isHeld: false, isAway: true }
        }
        const held = (await built.state.get(heldRef)).value ?? []
        if (!held.some(h => h.prompt === prompt)) {
          const seq = ((await built.state.get(heldSeqRef)).value ?? 0) + 1
          await built.state.set(heldSeqRef, seq)
          await built.state.set(heldRef, [...held, { id: String(seq), label, prompt }])
        }
        // Asleep, the refusal never tells Claude to publish a page in its place (#1284).
        return { isHeld: true, ...((await nounSeesAsleep()) ? heldAsleep(label) : heldRefusal(label)) }
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
      ['away', 'Away: every session publishes pages for the phone and holds what needs you at the Mac.'],
      ['home', 'Home: every session delivers on the Mac again.'],
      ['sleep', 'Sleep: the whole Mac goes quiet until noon ET; interactive sessions are enrolled to work overnight.'],
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
    await $.tool.register({
      name: 'leave_branch',
      description:
        "Ask Dan whether a branch stays as it is rather than being cleaned up while winding down: kept here, a worktree on it kept, and, when this session's checkout is on it, the files this session wrote that are uncommitted there left uncommitted. For when another session stands on it, or he has said to leave it. Only his \"Leave it as it is\" is recorded; a change to any other uncommitted file asks again, and the branch on GitHub is still deleted once its PR merges. Never call this to end a turn sooner.",
      inputSchema: {
        type: 'object',
        properties: {
          branch: { type: 'string', description: 'The branch name' },
          repo: { type: 'string', description: "The branch's repository as owner/name; this session's own when left out" },
          why: { type: 'string', description: 'Why it would be left as it is, as a short phrase ("another session stands on it")' },
        },
        required: ['branch', 'why'],
      },
    })
    await $.tool.register({
      name: 'open_cleanup_branch',
      description:
        "While winding down, ask Dan to let one new branch start whose only purpose is to commit the uncommitted changes the finish check lists (a reading a job appended to a committed file, say). The files are the ones git status names that this session wrote, named to him. Only his \"Open it\" is recorded, and it lets that branch start once, by git switch -c or git checkout -b, while nothing else this session wrote is uncommitted. Never for new work.",
      inputSchema: {
        type: 'object',
        properties: {
          branch: { type: 'string', description: 'The branch to start' },
          why: { type: 'string', description: 'What the uncommitted change is and why finishing needs it committed, as a short phrase' },
        },
        required: ['branch', 'why'],
      },
    })
    if (!ticking) {
      ticking = true
      // Winding down ends itself once it is live, watched each minute rather than only at turn end.
      $.clock.every(MIN, async () => {
        try {
          // A kept reading may be minutes old (#1037), so one that looks finished is read afresh
          // before winding down ends: only GitHub's answer now finishes it (lessons review).
          const kept = await check($)
          const c = kept && kept.left.length === 0 ? await check($, true) : kept
          if (c && c.left.length === 0) await finish($, c)
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
        // The night remembered while asleep, and this session's own morning put to Dan once it is
        // over (#1285), with what it held overnight (#1284).
        try {
          await morningAtMinute($, seen)
        } catch (err) {
          $.ui.log(`scope-modes: the minute's check for this session's morning failed: ${msg(err)}`, { to: 'debug' })
        }
        // Asleep, this session's own report named once it has news (#1287).
        try {
          await reportMinute($, seen)
        } catch (err) {
          $.ui.log(`scope-modes: the minute's check for this session's sleep report failed: ${msg(err)}`, { to: 'debug' })
        }
        // Once a session, awake: its repository's proposals no session was open to offer (#1286).
        try {
          await offerBacklog($, seen)
        } catch (err) {
          $.ui.log(`scope-modes: the check for earlier nights' proposals failed: ${msg(err)}`, { to: 'debug' })
        }
        // The reminder to end sleep mode (#1107, #1283): pinned here while asleep, and taken off once
        // the night has ended, wherever and however it ended.
        try {
          await reminderMinute($, seen)
        } catch (err) {
          $.ui.log(`scope-modes: the morning reminder's minute failed: ${msg(err)}`, { to: 'debug' })
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
  // Each switch tells Claude to open its reply with what the mode now does (#1055).
  on('command.run', { command: 'nobuild' }, async $ => {
    const was = await setScope($, 'NO BUILD')
    return { text: 'No build is on.', context: [`Dan turned on no build. ${ackOn('NO BUILD', { replaced: was })}`, SCOPE_NOTE['NO BUILD']] }
  })
  on('command.run', { command: 'winddown' }, async $ => {
    const was = await setScope($, 'WINDING DOWN')
    return { text: 'Winding down is on.', context: [`Dan turned on winding down. ${ackOn('WINDING DOWN', { replaced: was })}`, SCOPE_NOTE['WINDING DOWN']] }
  })
  on('command.run', { command: 'build' }, async $ => {
    const scope = await scopeOf($)
    if (!scope) return { text: 'No scope mode was on.' }
    await setScope($, null)
    return { text: `${SCOPE_NAME[scope]} is off.`, context: [`Dan turned ${SCOPE_NAME[scope].toLowerCase()} off: build as usual. ${ackOff(scope)}`] }
  })
  // Sleep and waking are acknowledged as every other switch is (#1086), and only when they switched.
  on('command.run', { command: 'sleep' }, async $ => {
    const began = { is: false }
    const text = await startSleep($, began)
    // The morning reminder (#1107), only for a night this call began.
    return began.is ? { text: `${text}${await pinMorning($)}`, context: [ackOn('sleep')] } : { text }
  })
  on('command.run', { command: 'wake' }, async ($, e) => {
    const woke = await wake($, e.origin.kind === 'bridge')
    if (!woke) return { text: 'Sleep mode was not on.' }
    // The morning turn starts once the command is done: from inside command.run the prompt would
    // wait on the turn this hook holds (as /handoff found).
    const morning = woke.morning
    // This session's morning (#1285) and what it held overnight (#1284) ride in it: done once it goes
    // in, else kept for the minute. Whether it went in is told apart from marking it done, so a mark
    // that fails is never said as a morning turn that could not start (lessons review of #1284).
    if (morning)
      $.clock.after(0, () => {
        watchMorningPickers(morning)
        void $.prompt
          .submit({ text: morning })
          .then(
            () => morningDone($, true),
            async err => {
              morningPickers = undefined
              await morningDone($, false)
              $.ui.toast(`Sleep mode is off, but the morning summary and pickers could not start: ${msg(err)}. They are tried again within a minute.`)
            },
          )
          // A mark that fails is said by morningDone itself (#1383); this is anything else that threw.
          .catch(err => $.ui.log(`scope-modes: /wake's morning turn could not be settled (${msg(err)})`, { to: 'debug' }))
      })
    return woke.off ? { text: woke.said, context: [ackOn('wake')] } : { text: woke.said }
  })
  on('command.run', { command: 'away' }, async $ => {
    await setPlace($, 'away')
    const said = placeSentence('away', await tellOthers($, 'away'))
    return { text: said, context: [ackOn('away', { first: said })] }
  })
  on('command.run', { command: 'home' }, async $ => {
    await setPlace($, 'home')
    const said = placeSentence('home', await tellOthers($, 'home'))
    return { text: said, context: [ackOn('home', { first: said })] }
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
    // Only Dan's own words switch a mode, as mod-kit's one reader says (#1135): what he types, at the
    // Mac or from his phone. Nothing else may (a peer session, a plugin, a handoff's opening prompt, a
    // notification), so a message from elsewhere saying "go ahead and build" cannot lift no build.
    const isDans = await dansWords($, e.origin)
    // Whether this turn is the morning one, carrying what this session held overnight (#1284).
    let carriesMorning = false
    if (isDans) {
      const triggers = triggersIn(e.text) as Trigger[]
      // What each switch says it now does (#1055), opened with once for them all, so a message that
      // switches two modes never gives Claude two competing openings.
      const acks: string[] = []
      let wokeHere = false
      for (const t of triggers) {
        if (t.kind === 'scope') {
          const was = await setScope($, t.scope)
          notes.push(`${SCOPE_NAME[t.scope]} just turned on from Dan's message.`)
          acks.push(ackOnSaid(t.scope, { replaced: was }))
        } else if (t.kind === 'build') {
          const was = await scopeOf($)
          if (was) {
            await setScope($, null)
            notes.push(`${SCOPE_NAME[was]} just turned off from Dan's message.`)
            acks.push(ackOffSaid(was))
          }
        } else if (t.kind === 'off') {
          // Off by name turns off only the mode it names.
          if ((await scopeOf($)) === t.scope) {
            await setScope($, null)
            notes.push(`${SCOPE_NAME[t.scope]} just turned off from Dan's message.`)
            acks.push(ackOffSaid(t.scope))
          }
        } else if (t.kind === 'wake') {
          const woke = await wake($, e.origin.kind === 'bridge')
          // What waking found quotes titles of issues, milestones and commits made overnight, so it
          // reaches this turn only as data (#922).
          wokeHere ||= !!woke
          if (woke)
            notes.push(
              `Dan's message woke sleep mode. Say so in one line first, saying what the block below says.\n${overnightData({ holds: 'what waking sleep mode did and found, which can quote titles of issues, milestones and commits made overnight', offer: 'said to Dan in that one line; it is offered to him through no picker', lines: [woke.said] })}`,
            )
          // This turn is the morning one (#837): its summary and pickers ride along.
          if (woke?.morning) {
            notes.push(woke.morning)
            carriesMorning = true
            watchMorningPickers(woke.morning)
          }
          // Waking is acknowledged as any other switch is (#1086), right after waking's own line.
          if (woke?.off) acks.push(ackOnSaid('wake'))
        } else {
          await setPlace($, t.place)
          const told = await tellOthers($, t.place)
          notes.push(`Dan's message switched every session to ${t.place}.`)
          acks.push(ackOnSaid(t.place, { first: placeSentence(t.place, told) }))
        }
      }
      // Every note so far is a switch the message made; the still on note below switches nothing.
      const switched = notes.length
      // Waking opens the reply with its own line, so a switch is acknowledged right after it.
      if (acks.length) notes.push(acknowledge(acks, wokeHere ? { after: 'the line saying what waking did' } : {}))
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
    // A morning picker left unanswered is asked again with his next message here (#1285), counted
    // as asked once the prompt carrying it went in.
    const askAgain = isDans && (await leftUnanswered($))
    if (askAgain) notes.push(MORNING_UNANSWERED)
    const scope = await scopeOf($)
    if (scope) notes.push(SCOPE_NOTE[scope])
    let asking: string | undefined
    const sleeping = await sleepNow($)
    if (sleeping.state === 'asleep') {
      notes.push(sleepPromptNote(sleeping.record, await $.session.id(), await $.clock.now()))
      // A worker names its report as its first prompt asleep goes in (#1287), before any note it
      // writes, so its own name by its title is the one kept, not the report script's by its id.
      try {
        await reportMinute($, sleeping)
      } catch (err) {
        $.ui.log(`scope-modes: this session's sleep report could not be named on this prompt (${msg(err)}); tried again at the next minute`, { to: 'debug' })
      }
      // Only /wake or "I'm up" ends sleep (#837, decision 9): Dan writing in the daytime is asked
      // whether he is up, once a night in each session, and sleep goes on until he says so. It counts
      // as asked only once the prompt carrying it went in (below), so a prompt that failed asks again.
      if (isDans && askedUp !== sleeping.record.generation) {
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
    let entered: Awaited<ReturnType<typeof next>>
    try {
      entered = await next(notes.length ? { ...e, context: [...(e.context ?? []), ...notes] } : e)
    } catch (err) {
      // "I'm up" carried this session's morning (#1285) and what it held (#1284): a turn that did not
      // go in keeps them for the minute. Only this turn's own morning settles it, never another
      // prompt (lessons review of #1284).
      if (carriesMorning) {
        // No morning turn started, so no picker is watched for it (lessons review).
        morningPickers = undefined
        await morningDone($, false)
      }
      throw err
    }
    // The prompt is in, so nothing is thrown past a turn that started; a mark that fails is said by
    // morningDone itself (#1383).
    if (carriesMorning)
      await morningDone($, true).catch(err => $.ui.log(`scope-modes: this session's morning went in, but could not be settled (${msg(err)})`, { to: 'debug' }))
    if (asking !== undefined) askedUp = asking
    if (askAgain) await setLeftUnanswered($, false)
    return entered
  })

  // The first main turn after a morning prompt is the morning one (#1285): /wake's own prompt, the
  // turn "I'm up" started, or the one the minute submitted. Only the main loop raises turn.start.
  on('turn.start', async ($, e, next) => {
    const r = await next(e)
    if (morningPickers && morningPickers.turnId === undefined) morningPickers.turnId = e.turnId
    return r
  })

  // A message from the phone while home: one line at the end of the reply (picker, 2026-10-04).
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    // This session's morning turn (#1285): a picker unanswered, or a turn ended other than by
    // answering while it had pickers to ask, leaves them to be asked again with his next message.
    const mp = morningPickers
    if (mp && e.agentId === undefined && mp.turnId === e.turnId) {
      morningPickers = undefined
      // Only a morning that asked something can leave a picker unanswered (lessons review).
      if (mp.asks && (mp.unanswered > 0 || e.reason !== 'answer')) await setLeftUnanswered($, true)
    }
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
    // /sleep telling this session to start the night's work (#1242). Started only when the record
    // names it a worker with a goal, read here, so a forged start can do no more than /sleep would;
    // the turn is started once this delivery is done, as the driver starts one after a wait.
    if (origin.plugin === MOD && e.text === SLEEP_START) {
      const en = await enrolledNow($)
      if (!en) return { consumed: 'scope-modes: a start for the night arrived, but this session is not a worker tonight' }
      const goal = goalOf(en.record, en.self)
      if (goal === null) return { consumed: 'scope-modes: a start for the night arrived, but this session has no goal tonight' }
      const where = await repoOf($)
      const text = startPrompt(en.self, where.root ?? (await $.session.cwd()), goal)
      $.clock.after(0, () => void $.prompt.submit({ text }).catch(err => $.ui.log(`scope-modes: the night's work could not be started: ${msg(err)}`)))
      return { consumed: "scope-modes: started the night's work toward this session's goal" }
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
        // His yes is a switch like any other, acknowledged with what no build no longer stops (#1055).
        const text = `Dan said yes: no build is off. ${ackOff('NO BUILD')}`
        return { result: text, text }
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

    // Dan's answers about a branch (#1074, #1051), asked after mod-kit's screen as leave_pr_open is.
    if (tool === 'mcp__scope-modes__leave_branch' || tool === 'mcp__scope-modes__open_cleanup_branch') {
      const refused = await $.modkit.screen(e)
      if (refused) return refused
      const text = tool === 'mcp__scope-modes__leave_branch' ? await leaveBranch($, input) : await openCleanupBranch($, input)
      return { result: text, text }
    }

    // A call that may open a PR, or make a branch the session's own (#1074), is watched whatever mode
    // is on, so winding down later knows what this session opened and touched. The words are a cheap
    // first look; the reader decides.
    const raw = tool === 'Bash' ? String(input.command ?? '') : ''
    const mayOpen = /\bgh\b/.test(raw) && /\bpr\b/.test(raw) && /\bcreate\b/.test(raw)
    const mayBranch = /\bgit\b/.test(raw) && /\b(checkout|switch|branch|worktree|push|commit)\b/.test(raw)
    const mayWrite = tool === 'Bash' || EDITORS.has(tool)
    // A picker in this session's own morning turn (#1285), counted answered or not, so one left
    // unanswered is asked again; a refused one never reached Dan and counts neither way.
    const ownMorningPicker = tool === 'AskUserQuestion' && input.agentId === undefined && morningPickers?.turnId !== undefined ? morningPickers : undefined
    // An overnight proposal being filed (#1389), claimed for this session first: where it is
    // recorded filed once gh made it. The words are a cheap first look; the reader decides.
    let filing: { dir: string } | null = null
    const go = async (cleanups: readonly ScopeModesCleanup[] = []) => {
      // A stash a pop takes back is gone once it runs, so what it holds is read first (#1123).
      const stashed = raw ? await stashedFiles($, raw) : []
      let r: Awaited<ReturnType<typeof next>>
      try {
        r = await next(e)
      } catch (err) {
        if (ownMorningPicker) ownMorningPicker.unanswered++
        throw err
      }
      const answered = ownMorningPicker ? pickerAnswered(r) : undefined
      if (ownMorningPicker && answered !== undefined) ownMorningPicker[answered ? 'answered' : 'unanswered']++
      if (mayOpen && !r.deny) await noteOpened($, raw, r)
      if (filing && !r.deny) await noteProposalFiled($, filing.dir, r)
      // A morning picker of proposals Dan answered: what he left is declined (#1389).
      if (tool === 'AskUserQuestion' && !r.deny && pickerAnswered(r) === true) await noteDeclined($, input, r)
      if (mayBranch && !r.deny) await noteBranches($, raw, input.agentId)
      // A call refused here or beneath never ran, so it wrote nothing (#1108).
      if (mayWrite && !r.deny) await noteWritten($, tool, input, raw, stashed)
      if (cleanups.length && !r.deny) await useCleanups($, cleanups)
      return r
    }

    const scope = await scopeOf($)
    // Asleep (#840), read live at each call, holds what away holds on the Mac, and every result until wake (#1284).
    const sleeping = await sleepNow($)
    // Asleep, a merge, a deploy or a push to a default branch is judged against the night's lists
    // (#843), first, before any other mode's route or early return, so nothing reaches a merge
    // unjudged. A check that throws refuses, as below (L42).
    if (sleeping.state === 'asleep' && raw) {
      let over: Awaited<ReturnType<typeof mergeDeployRefusal>>
      try {
        over = await mergeDeployRefusal($, sleeping.record.repos, await readCommands($, raw))
      } catch (err) {
        // #1281: a member mod-kit's loaded copy lacks is no merge found, and no one call's fault:
        // every call is refused alike (fail closed, none can be told from one that merges), Dan is
        // told once, and Claude is told to end the turn, at whose Stop the driver lets the session
        // rest so its mods can load again.
        const news = skewNews(err, MOD)
        if (news) $.ui.toast(news)
        over = missingOf(err)?.kind === 'member'
          ? { deny: `Blocked overnight: ${msg(err)} So no call can be checked for a merge or deploy, and none runs. End this turn now so this session can load its mods again; do not try this call another way.`, what: 'run a call the check could not judge', why: msg(err) }
          : { deny: `Blocked overnight: the merge and deploy check of this call failed (${msg(err)}), so it did not run. Leave it for the morning and note it.`, what: 'run a call the check could not judge', why: msg(err) }
        if (missingOf(err)?.kind === 'member') skewMet = msg(err)
      }
      if (over) {
        await noteFirstMet($, sleeping.record, over)
        // Kept for this session's morning, where Dan is asked whether to do it now (#1285).
        try {
          await keepForWake($, { label: over.what, call: raw, why: over.why })
        } catch (err) {
          $.ui.log(`scope-modes: a merge held overnight could not be written to this session's state (${msg(err)}); it is kept in memory for the morning`, { to: 'debug' })
        }
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
    // And hands him nothing (#1284): a page published or opened for him, or a Claude doc, in any
    // session and from any of its agents, is held, kept in this session and asked for when sleep
    // mode ends, so every session reports at the same moment.
    if (sleeping.state === 'asleep') {
      const label = deliveryOf(tool, input)
      if (label) {
        const { tool: _t, tool_use_id: _id, agentId: _a, consent: _c, ...args } = input
        // Refused whatever the write does: a hook that throws is skipped, and the publish would run
        // (L42). The list is changed in memory before it is written, so a failed write keeps it for
        // this session's morning, losing it only to a reload (lessons review).
        try {
          await keepForWake($, { label, call: `${tool} ${JSON.stringify(args)}` })
        } catch (err) {
          $.ui.log(`scope-modes: a delivery held overnight could not be written to this session's state (${msg(err)}); it is kept in memory for the morning`, { to: 'debug' })
        }
        const held = heldUntilWake(label)
        await $.modkit.blocked({ toolUseId, ...held.card })
        return { deny: held.deny }
      }
    }
    // Whatever mode is on (#1389): an overnight proposal another session filed or is offering is
    // refused here, so two sessions never file one twice.
    if (/\bgh\b/.test(raw) && /\bissue\b/.test(raw) && /\bcreate\b/.test(raw)) {
      const f = await proposalFiling($, raw)
      if (f && 'deny' in f) {
        await $.modkit.blocked({ toolUseId, guard: 'Overnight proposal', reason: f.deny, safeWay: 'Claude tells Dan where it is instead of filing it again.' })
        return { deny: f.deny }
      }
      filing = f
    }
    const asleep = sleeping.state === 'asleep'
    const away = (await placeOf($)) === 'away' || asleep
    if (!scope && !away) return go()

    // A judge that throws refuses the call rather than letting it through: a tool call hook that
    // fails is skipped, which would run the very thing the mode is on to stop (L42). A TaskStop is
    // the one exception (#1495, below).
    let verdict: Verdict
    try {
      verdict = await judge($, { tool, input, toolUseId, scope, away, asleep })
    } catch (err) {
      const news = skewNews(err, MOD)
      if (news) $.ui.toast(news)
      // Asleep, a skew met here stalls the night as one met in the merge check does, so the driver
      // reads it at the next Stop too (lessons review).
      if (asleep && missingOf(err)?.kind === 'member') skewMet = msg(err)
      const modes = [...(scope ? [SCOPE_NAME[scope].toLowerCase()] : []), ...(asleep ? ['sleep mode'] : away ? ['away'] : [])].join(' and ')
      // #1495, Dan's decision 2026-10-22 (picker answer "Let stops through on a check error"):
      // stopping a job can never break a mode, so refusing a TaskStop whose check errored only kept
      // a job running, the job watcher's own stop of a dead poll loop among them. Only the error is
      // narrowed, and only for TaskStop: a mode's own refusal of it, and every other tool's check
      // error, still refuse.
      if (tool === 'TaskStop') {
        $.ui.log(`scope-modes: ${modes} could not check a TaskStop (${msg(err)}), so it was let through: a stop cannot break a mode (#1495)`, { to: 'debug' })
        verdict = undefined
      } else verdict = { deny: `Blocked: ${modes} is on and its check of this call failed (${msg(err)}), so the call did not run. Try it again; if it fails the same way, tell Dan.` }
    }
    if (verdict && 'deny' in verdict) return verdict
    return go(verdict?.cleanups ?? [])
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
    // An enrolled session while the Mac sleeps is the overnight driver's (#844): kept working, or let
    // go with a note. Either way its answer ends the Stop chain (#1242): Claude Code's own /goal hook
    // sits beneath and blocks every Stop until its condition holds, so a stop passed on to it was
    // blocked again (measured on 2.1.301: 9 more blocks a turn, every turn, past the circuit
    // breaker), and the night's limits held only while a goal happened to be met. The settings Stop
    // hooks beneath stand down while asleep, so ending the chain here takes nothing from the night.
    const driven = await driveStop($)
    if (driven !== 'not-driven') return driven ?? {}
    // A turn end asks GitHub afresh about everything that can still change (#1037).
    const c = await check($, true)
    if (c === null) return next(e)
    if (c.left.length === 0) {
      await finish($, c)
      return next(e)
    }
    // A PR Dan chose to leave open (#917) or closed (#1033), and a branch he chose to leave as it is
    // (#1074), are said apart, never as outstanding.
    const kept = `${keptSaid(c.kept, "Dan's")}${keptBranchesSaid(c.keptBranches, "Dan's")}`
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
    await $.state.set(branchesRef, [] as string[])
    await $.state.set(leftBranchRef, [] as ScopeModesLeftBranch[])
    await $.state.set(cleanupRef, [] as ScopeModesCleanup[])
    await $.state.set(writtenRef, [] as string[])
    writeNoteSaid = false
    // What was held overnight, the night seen and the morning put are this session's (#1284, #1285, #1383), so a new session starts with none.
    heldNow = []
    heldLoaded = true
    morningInFlight = null
    nightSeen = null
    morningPut = null
    markSaid = undefined
    morningPickers = undefined
    morningLeftUnanswered = false
    await $.state.set(wakeHeldRef, [] as HeldDelivery[])
    await $.state.set(nightSeenRef, null)
    await $.state.set(morningPutRef, null)
    await $.state.set(morningUnansweredRef, false)
    prSeen.clear()
    await $.state.set(placeRef, 'home')
    await $.state.set(justHomeRef, false)
    await $.state.set(heldRef, [] as ScopeModesHeld[])
    lastOrigin = undefined
    await showModes($)
    await showHeld($)
    return next(e)
  })
}
