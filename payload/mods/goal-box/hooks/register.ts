import type { EngineInterface, Register } from 'claude-code'
import { cutOwn, watchesOnly } from './mod-kit/hold.ts'
import type { ModKitGoal } from '../.claude-plugin/types/mod-kit/index.d.ts'
import type { GoalBoxShown } from '../types/index.d.ts'
import { DESCRIPTION, MOD, NAME, SCHEMA, TOOL, askDoneText, askText, boxText, cardOf, cardedSince, decide, linkedIn, mergeFactsOf, mergeHolds, readInput, waitKey, type Confirmed, type Holds, type Linked } from './box.ts'
import { askAnyAccount, type GhRun } from './mod-kit/ghaccounts.ts'
import { askPr } from './mod-kit/prmerged.ts'
import { errorText, missingOf } from './mod-kit/skew.ts'
import { HOLD_MAX_MS, whileHeld } from './mod-kit/held.ts'
import { transcriptPlaces } from './mod-kit/projects.ts'
import { toolArgs } from './mod-kit/toolargs.ts'
import { BOX_KINDS, INFLIGHT_KINDS, inflightHolds, type InflightFacts, type Reading } from './mod-kit/inflight.ts'
import { CLOSE_HEADING, CLOSE_TITLE, NO_BOX, PROCESS_LIST, PROCESS_LOOK, PROCESS_TIMEOUT_MS, QUIET_MS, closeStep, leftBehindBy, leftBehindReason, processHolds } from './close.ts'

// The Goal accomplished box (claude-config#1563). Two ways a session's work ends, one box for both:
//
// 1. A /goal met. Claude Code's own check of the goal runs as a Stop hook, and writes its verdict
//    into the transcript as a goal_status record. Measured on 2.1.310 on 2026-10-24 with a probe mod
//    in a headless session: a verdict of not met is the Stop chain's own block, and the record of a
//    verdict of met lands AFTER the Stop chain has returned and before turn.complete. So
//    turn.complete finds it, read through mod-kit's one goal reader, and sends the session one
//    prompt to show the box, once per met goal. This path uses no classic hook; the close this
//    session card (#3770, below) records the stop's lists at classic.Stop, which runs only while
//    the managed settings file keeps Claude Code's security default out of first place (#875, #876).
// 2. No /goal: the session's own judgement that the work Dan asked for is finished. A judgement can
//    only be the model's, so it calls this mod's tool (a rule in a prompt alone is a hope, L27), and
//    the tool enforces what can be read: no box while an agent the session started is running, a
//    merge or a deploy is not confirmed (is it live's own record, with a background merge it still
//    calls waiting asked of GitHub again here, #1818), or a pull request the session
//    touched is still open (GitHub, asked as each account), and at most one box per request (a
//    second needs a new message from Dan, mod-kit's one reader of his own words). What reminds the
//    session to call it is the last step of both end of turn reviews (hooks/review/
//    session-reflection.md, #1749, and issue-review.md, #2523). A reflection folded into the issue
//    review once dropped its line (#2523), so a prompt is not the whole reminder (L27): at a turn end
//    where work measurably shipped (an is it live card made since Dan's last message), nothing is in
//    flight and no box was shown, this mod asks the session itself, once per message of Dan's.
//
// The box is the tool's result: drawn as mod-kit's card, its heading in the success colour, and as
// text led by the goal wherever the card is not drawn (#2512).

const interactiveRef = { plugin: 'goal-box', key: 'interactive' } as const
const promptsRef = { plugin: 'goal-box', key: 'prompts' } as const
const shownRef = { plugin: 'goal-box', key: 'shown' } as const
const askedRef = { plugin: 'goal-box', key: 'asked' } as const
const requestAtRef = { plugin: 'goal-box', key: 'requestAt' } as const
const askedDoneRef = { plugin: 'goal-box', key: 'askedDone' } as const
// #3770, the close this session card's own record.
const closeSeqRef = { plugin: 'goal-box', key: 'closeSeq' } as const
const closeStopRef = { plugin: 'goal-box', key: 'closeStop' } as const
const closeAnswerRef = { plugin: 'goal-box', key: 'closeAnswer' } as const
const closedRef = { plugin: 'goal-box', key: 'closed' } as const
const leftBehindRef = { plugin: 'goal-box', key: 'leftBehind' } as const
// What the card reads of the mods beside it; each may not be loaded.
const stepsCardRef = { plugin: 'manual-steps', key: 'card' } as const
const compactQueuedRef = { plugin: 'status-bar', key: 'compactQueued' } as const
const compactFollowUpRef = { plugin: 'status-bar', key: 'compactFollowUp' } as const
const modkitHoldsRef = { plugin: 'mod-kit', key: 'holds' } as const
// The folder the session started in, where Claude Code files its transcript (#2898), kept as
// scope-modes keeps its own: set at every session start, which fires again at each fresh load of the
// mod (#1703), so a reload sets it again.
let startCwd: string | null = null
// is it live's own record of this session's merges, read here; it may not be loaded at all.
const owedRef = { plugin: 'is-it-live', key: 'owed' } as const
const verdictsRef = { plugin: 'is-it-live', key: 'verdicts' } as const

const msg = (err: unknown) => (err instanceof Error ? err.message : String(err))
const debug = ($: EngineInterface, text: string) => void $.ui.log(`${MOD}: ${text}`, { to: 'debug' })

// What a session id looks like; anything else never goes into a path.
const SESSION_ID = /^[A-Za-z0-9-]+$/

/**
 * This session's transcript where Claude Code keeps it by the session's id (#2898), in the folder
 * the session started in or the one it is in now, or every place it is not and every check that
 * failed. Read first, as scope-modes reads its own (#1678): the registry lists a live session as
 * ended once a session end it outlived closed its record (a resume keeping its id, before the look
 * that reopens it; any other reason, for good), and never looks a closed record's transcript up.
 */
const atIdsPath = async ($: EngineInterface): Promise<{ path: string } | { missed: string[]; failed: string[] }> => {
  const missed: string[] = []
  const failed: string[] = []
  let id: string, home: string | undefined, here: string | null
  try {
    id = await $.session.id()
    home = await $.env.get('HOME')
    here = await $.session.cwd()
  } catch (err) {
    return { missed, failed: [`this session's id or folder could not be read (${errorText(err, MOD)})`] }
  }
  if (!home) return { missed, failed: ['HOME is not set'] }
  if (!SESSION_ID.test(id)) return { missed, failed: [`this session's id is not one (${JSON.stringify(id)})`] }
  const projects = `${home}/.claude/projects`
  for (const dir of new Set([startCwd, here].filter((d): d is string => typeof d === 'string' && !!d))) {
    let places: string[]
    try {
      places = await transcriptPlaces(d => $.fs.list(d), projects, dir, id)
    } catch (err) {
      failed.push(`the folders under ${projects} could not be listed (${errorText(err, MOD)})`)
      continue
    }
    for (const p of places) {
      try {
        if (await $.fs.exists(p)) return { path: p }
        missed.push(p)
      } catch (err) {
        failed.push(`whether it is at ${p} could not be checked (${errorText(err, MOD)})`)
      }
    }
  }
  return { missed, failed }
}

/** This session's transcript, from its own record in the session registry, or why it is not there. */
const inRegistry = async ($: EngineInterface): Promise<{ path: string } | { why: string }> => {
  try {
    const list = await $.sessions.list()
    if (!list.selfId) return { why: 'the session registry has no record of this session' }
    const me = list.open.find(r => r.sessionId === list.selfId)
    const ended = list.closed.find(r => r.sessionId === list.selfId)
    const named = me?.transcriptPath ?? ended?.transcriptPath
    if (named) return { path: named }
    if (me) return { why: me.transcriptUnread ?? "the session registry's search for it found nothing" }
    if (ended) return { why: 'the session registry counts this session as ended, so it did not look its transcript up' }
    return { why: 'the session registry has no record of this session' }
  } catch (err) {
    return { why: `the session registry could not be read (${errorText(err, MOD)})` }
  }
}

/**
 * This session's transcript, or why it is not known: at its id's path first, else the registry's.
 * The why names where it is not and how the registry holds the session (#2898), so a transcript
 * that cannot be found is never read as a /goal that is open.
 */
const transcriptNow = async ($: EngineInterface): Promise<{ path: string } | { why: string }> => {
  const own = await atIdsPath($)
  if ('path' in own) return own
  const reg = await inRegistry($)
  if ('path' in reg) return reg
  const notAt = own.missed.length ? [`it is not at ${own.missed.join(' or ')}, where Claude Code keeps it by this session's id`] : []
  return { why: [...notAt, ...own.failed, reg.why].join('; ') }
}

/** The goal mod-kit reads in this session's transcript; never throws, so a failure holds the box. */
const goalNow = async ($: EngineInterface): Promise<ModKitGoal> => {
  const t = await transcriptNow($)
  if ('why' in t) return { state: 'unreadable', why: t.why }
  const transcript = t.path
  try {
    return await $.modkit.goal({ transcript })
  } catch (err) {
    return { state: 'unreadable', why: errorText(err, MOD) }
  }
}

// Every pull request record in the transcript, one line per pull request: the time each was written
// blanked so the same pull request's records are one line, then sorted unique. grep exits 1 for none.
const PR_LINKS = 'set -o pipefail; grep -F -e "$1" -- "$2" | sed -E \'s/"timestamp":"[^"]*"/"timestamp":""/\' | sort -u'
const PR_MARK = '"type":"pr-link"'

const linkedNow = async ($: EngineInterface): Promise<Linked[] | { why: string }> => {
  const t = await transcriptNow($)
  if ('why' in t) return t
  const transcript = t.path
  try {
    const r = await $.process.run(['bash', '-c', PR_LINKS, 'prlinks', PR_MARK, transcript], { timeoutMs: 10_000 })
    if (r.exitCode === 1 && !r.stderr.trim()) return []
    if (r.exitCode !== 0) return { why: r.stderr.trim() || `grep exited ${r.exitCode}` }
    return linkedIn(r.stdout)
  } catch (err) {
    return { why: msg(err) }
  }
}

const ghLine = (r: GhRun) => r.stderr.trim().split('\n')[0] || `gh exited ${r.exitCode}`
const notFound = (r: GhRun) => /Could not resolve to a Repository/i.test(r.stderr)

/** The pull requests this session touched that GitHub says are still open, or why it could not say. */
const openHolds = async ($: EngineInterface): Promise<Holds> => {
  const linked = await linkedNow($)
  if (!Array.isArray(linked)) return [`the pull requests this session touched could not be read (${linked.why}), so whether one is still open is not known`]
  const byRepo = new Map<string, number[]>()
  for (const l of linked) byRepo.set(l.repo, [...(byRepo.get(l.repo) ?? []), l.pr])
  const gh = (argv: string[], env?: Record<string, string>, stdin?: string) =>
    $.process.run(argv, { timeoutMs: 20_000, ...(env ? { env } : {}), ...(stdin !== undefined ? { stdin } : {}) })
  const out: Holds = []
  for (const [repo, prs] of byRepo) {
    const named = prs.map(n => `#${n}`).join(', ')
    let open: number[]
    try {
      // As each account gh is logged in to: Dan's work repositories are visible only to his work account.
      const r = await askAnyAccount(gh, ['pr', 'list', '--repo', repo, '--state', 'open', '--json', 'number', '--limit', '1000'], notFound)
      if (!('stdout' in r)) {
        out.push(`could not ask GitHub whether ${repo}'s pull requests ${named} are still open (${ghLine(r.failures.find(f => !notFound(f)) ?? (r.failures[0] as GhRun))})`)
        continue
      }
      const list = JSON.parse(r.stdout) as unknown
      if (!Array.isArray(list)) throw new Error('gh answered something that is not a list')
      open = list.map(x => (x as { number?: unknown }).number).filter((n): n is number => typeof n === 'number')
    } catch (err) {
      out.push(`could not ask GitHub whether ${repo}'s pull requests ${named} are still open (${msg(err)})`)
      continue
    }
    for (const n of prs) if (open.includes(n)) out.push(`${repo}#${n} is still open: merge it, or close it if it is not part of this work`)
  }
  return out
}

/** The session's agents as Claude Code lists them, or why they could not be listed. */
const agentsNow = async ($: EngineInterface): Promise<Reading<unknown>> => {
  try {
    return { value: await $.agent.list() }
  } catch (err) {
    return { unread: msg(err) }
  }
}

/**
 * What holds the box (#1563, #1818): the box's kinds in mod-kit's one list of what is in flight
 * (hooks/mod-kit/inflight.ts, #3770), so the agents it counts are the ones every other reader
 * counts: the session's own still working, never one a plugin started.
 */
const boxHolds = async ($: EngineInterface): Promise<Holds> =>
  inflightHolds({ agents: await agentsNow($), merges: { value: await mergeHoldsNow($) }, prs: { value: await openHolds($) } }, BOX_KINDS).map(h => h.text)

/**
 * A background merge, asked of GitHub by the box itself (#1818): is it live asks again only at a turn
 * end, so its record can still say waiting after `gh pr view` says MERGED. Asked through mod-kit's
 * one check of whether a pull request merged (hooks/mod-kit/prmerged.ts, #1991), the one is it live's
 * turn end asks through too: as each account, by the repository is it live read (else in the folder
 * the helper ran in), confirmed only when GitHub says MERGED for that number with a link naming that
 * repository.
 */
const confirmMerge = ($: EngineInterface, o: { pr: number; repo?: string; cwd?: string }): Promise<Confirmed[string]> =>
  askPr(
    {
      run: async (argv, init) => {
        const r = await $.process.run(argv, { timeoutMs: 20_000, ...init })
        return { exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr }
      },
      linkRepo: async link => $.modkit.linkRepo({ link }),
      describe: err => errorText(err, MOD),
    },
    o,
  )

const mergeHoldsNow = async ($: EngineInterface): Promise<Holds> => {
  const facts = mergeFactsOf((await $.state.get(owedRef)).value as unknown, (await $.state.get(verdictsRef)).value as unknown)
  if ('why' in facts) return [`is it live's record of this session's merges could not be read (${facts.why}), so whether a merge or deploy is settled is not known`]
  const confirmed: Confirmed = {}
  for (const o of facts.owed) {
    if (o.how !== 'waiting' || waitKey(o) in confirmed) continue
    confirmed[waitKey(o)] = await confirmMerge($, o)
  }
  return mergeHolds(facts, confirmed)
}

/**
 * Records the box as shown unless a box with this key, or any box since Dan's last message, already
 * was: read, judged and written with the version read, again on a miss, so two calls at once show one.
 */
const claim = async ($: EngineInterface, entry: GoalBoxShown): Promise<boolean> => {
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(shownRef)
    const list = held.value ?? []
    const last = list[list.length - 1]
    if (list.some(s => s.key === entry.key) || (entry.kind === 'request' && last !== undefined && entry.prompts <= last.prompts)) return false
    if ((await $.state.set(shownRef, [...list, entry], { ifVersion: held.version })).isSet) return true
  }
  return false
}

/** Marks a met goal as asked about; false when it already was, or its box already shown. */
const markAsked = async ($: EngineInterface, id: string): Promise<boolean> => {
  if (((await $.state.get(shownRef)).value ?? []).some(s => s.key === `goal:${id}`)) return false
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(askedRef)
    const list = held.value ?? []
    if (list.includes(id)) return false
    if ((await $.state.set(askedRef, [...list, id], { ifVersion: held.version })).isSet) return true
  }
  return false
}

/** Takes a met goal off the asked list, so the next turn end asks for its box again (L368). */
const unmarkAsked = async ($: EngineInterface, id: string): Promise<void> => {
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(askedRef)
    const list = held.value ?? []
    if (!list.includes(id)) return
    if ((await $.state.set(askedRef, list.filter(x => x !== id), { ifVersion: held.version })).isSet) return
  }
}

/**
 * Sends the session one prompt of its own, holding back mod-kit's reload of goal-box until it is sent
 * (#2132: the prompt waits until the session is idle, and a reload in that time would drop it), for
 * at most mod-kit's hour. Why it did not enter (thrown, or dropped by a hook beneath), or undefined.
 */
const sendHeld = async ($: EngineInterface, id: string, what: string, text: string): Promise<string | undefined> => {
  try {
    const held = {
      mod: MOD,
      id,
      what,
      ms: HOLD_MAX_MS,
      hold: (input: { mod: string; id: string; what: string; ms: number }) => $.modkit.hold(input),
      release: (input: { mod: string; id: string }) => $.modkit.release(input),
      log: (line: string) => $.ui.log(line, { to: 'debug' }),
    }
    const sent = await whileHeld(held, () => $.prompt.submit({ text }))
    if (sent.drop !== undefined) return sent.drop || 'the prompt was dropped'
    return undefined
  } catch (err) {
    return msg(err)
  }
}

/**
 * #2523: with no /goal, asks the session once per message of Dan's whether the work is finished, when
 * an is it live card was made since that message, no box was shown for it, and nothing holds the box.
 * Claimed before it is sent, so two turn ends at once ask once, and released when it did not enter,
 * so a passing failure is asked again at the next turn end (L368).
 */
const askIfDone = async ($: EngineInterface): Promise<void> => {
  const since = (await $.state.get(requestAtRef)).value
  if (since === undefined) return
  const prompts = (await $.state.get(promptsRef)).value ?? 0
  const asked = await $.state.get(askedDoneRef)
  if (asked.value !== undefined && asked.value >= prompts) return
  const facts = mergeFactsOf((await $.state.get(owedRef)).value as unknown, (await $.state.get(verdictsRef)).value as unknown)
  if ('why' in facts) {
    debug($, `is it live's record could not be read (${facts.why}), so whether work shipped since Dan's last message is not known and the session was not asked about the box`)
    return
  }
  if (!cardedSince(facts.verdicts, since)) return
  if (((await $.state.get(shownRef)).value ?? []).some(s => s.prompts >= prompts)) return
  const holds = await boxHolds($)
  if (holds.length) return
  if (!(await $.state.set(askedDoneRef, prompts, { ifVersion: asked.version })).isSet) return
  const failed = await sendHeld($, 'ask-done', 'the prompt asking whether the work is finished', askDoneText())
  if (failed === undefined) return
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(askedDoneRef)
    if (held.value !== prompts) break
    if ((await $.state.set(askedDoneRef, asked.value ?? -1, { ifVersion: held.version })).isSet) break
  }
  $.ui.log(`Work shipped since Dan's last message, but the session could not be asked whether the work is finished (${failed}); it is asked again at the next turn end.`)
}

// ---- The close this session card (#3770) ----
// At the main conversation's turn end, once interactive, a quiet period of QUIET_MS starts on the
// engine's clock. Any turn start or message of any origin since (closeSeq moved) ends it unread. At
// its end every reading is taken afresh: the box shown for Dan's latest request, then everything in
// mod-kit's one list of what is in flight (hooks/mod-kit/inflight.ts), every kind, plus the two
// readings of a process a command left behind, which can only withhold (close.ts). All clear pins the
// card once per request of Dan's through manual steps' noun; any reason is written to
// ~/.claude/state/close-session/<session id>.json, the newest replacing the one before.

/** Counts a turn start or a message, so a quiet period armed before it ends with nothing done. */
const bumpSeq = async ($: EngineInterface): Promise<void> => {
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(closeSeqRef)
    if ((await $.state.set(closeSeqRef, (held.value ?? 0) + 1, { ifVersion: held.version })).isSet) return
  }
}

// Manual steps' noun, as its contract has it; the engine needs it called in place each time.
type NounCall = (input: unknown) => Promise<unknown>
type WithSteps = { manualSteps: { add: NounCall; withdraw: NounCall } }

/** The reasons, or none and pinned, written where a later session can read why; a failure is logged. */
const writeReasons = async ($: EngineInterface, pinned: boolean, reasons: string[]): Promise<void> => {
  try {
    const home = await $.env.get('HOME')
    const id = await $.session.id()
    if (!home || !SESSION_ID.test(id)) throw new Error('HOME or the session id could not be read')
    await $.fs.write(`${home}/.claude/state/close-session/${id}.json`, `${JSON.stringify({ at: await $.clock.now(), pinned, reasons }, null, 2)}\n`)
  } catch (err) {
    debug($, `why the close this session card is or is not up could not be written (${errorText(err, MOD)})`)
  }
}

/** Reading A: any process carrying this session's id; only ever a reason to withhold. */
const processesNow = async ($: EngineInterface): Promise<string[]> => {
  try {
    const listed = await $.process.run(PROCESS_LIST, { timeoutMs: PROCESS_TIMEOUT_MS })
    if (listed.exitCode !== 0) return []
    const r = await $.process.run(['python3', '-I', '-c', PROCESS_LOOK, await $.session.id()], { timeoutMs: PROCESS_TIMEOUT_MS, stdin: listed.stdout })
    return processHolds(r)
  } catch (err) {
    debug($, `the look for a process carrying this session's id could not run (${errorText(err, MOD)}), so it says nothing either way`)
    return []
  }
}

const readingOf = async <T,>(read: () => Promise<T>): Promise<Reading<T>> => {
  try {
    return { value: await read() }
  } catch (err) {
    return { unread: errorText(err, MOD) }
  }
}

/** Every reason the card may not go up now, or 'already' when it went up for this request once. */
const closeReasons = async ($: EngineInterface, seq: number): Promise<string[] | 'already'> => {
  const prompts = (await $.state.get(promptsRef)).value ?? 0
  const closed = (await $.state.get(closedRef)).value
  if (closed !== undefined && closed.prompts >= prompts) return 'already'
  const shown = (await $.state.get(shownRef)).value ?? []
  if (!shown.some(s => s.prompts >= prompts)) return [NO_BOX]
  const stop = (await $.state.get(closeStopRef)).value
  const answer = (await $.state.get(closeAnswerRef)).value
  const noStop = "this turn's stop was not recorded"
  const facts: InflightFacts = {
    agents: await agentsNow($),
    tasks: stop?.seq === seq ? { value: stop.tasks } : { unread: noStop },
    crons: stop?.seq === seq ? { value: stop.crons } : { unread: noStop },
    jobs: await readingOf(() => ($ as unknown as { jobs: { list: () => Promise<unknown> } }).jobs.list()),
    merges: { value: await mergeHoldsNow($) },
    prs: { value: await openHolds($) },
    goal: { value: await goalNow($) },
    // Another mod's state, read as unknown (L50: the shared list holds each to its shape).
    steps: await readingOf(async () => ({ card: (await $.state.get(stepsCardRef as never)).value as unknown, ignore: CLOSE_TITLE })),
    compact: await readingOf(async () => ({ queued: (await $.state.get(compactQueuedRef as never)).value as unknown, followUp: (await $.state.get(compactFollowUpRef as never)).value as unknown })),
    prompts: await readingOf(async () => ({ holds: (await $.state.get(modkitHoldsRef)).value, now: await $.clock.now() })),
    answer: answer?.seq === seq ? { value: answer.text } : { unread: "this turn's answer was not recorded" },
  }
  const left = (await $.state.get(leftBehindRef)).value
  return [...inflightHolds(facts, INFLIGHT_KINDS).map(h => h.text), ...(left ? [leftBehindReason(left)] : []), ...(await processesNow($))]
}

/** At the end of a quiet period armed under `seq`: pins the card when nothing holds it, or says why not. */
const closeCheck = async ($: EngineInterface, seq: number): Promise<void> => {
  if ((await $.state.get(closeSeqRef)).value !== seq) return
  const reasons = await closeReasons($, seq)
  if (reasons === 'already') return
  // A turn that began while the readings were taken makes them stale.
  if ((await $.state.get(closeSeqRef)).value !== seq) return
  if (reasons.length) return writeReasons($, false, reasons)
  const prompts = (await $.state.get(promptsRef)).value ?? 0
  const folder = (startCwd ?? (await $.session.cwd().catch(() => ''))).split('/').filter(Boolean).pop() ?? ''
  let why: string
  try {
    const r = (await ($ as unknown as WithSteps).manualSteps.add({ heading: CLOSE_HEADING, step: closeStep(folder) })) as { isShown?: unknown; reason?: unknown } | null | undefined
    if (r?.isShown === true) {
      await cardShown($, prompts)
      // A turn that began while the pin was out finds no card to take down, so this takes it down.
      if ((await $.state.get(closeSeqRef)).value !== seq) await withdrawClose($)
      return
    }
    why = `the card could not be shown (${typeof r?.reason === 'string' && r.reason ? r.reason : 'its answer did not say it was shown'})`
  } catch (err) {
    why = `the card could not be pinned (${errorText(err, MOD)})`
  }
  await writeReasons($, false, [why])
}

/**
 * The one place this request's card is claimed, and only once the pin came back shown. Every other
 * outcome (not shown, refused, threw, an answer that says nothing, no answer yet) claims nothing, so a
 * later quiet end under the same request tries again. Three lessons reviews found the claim taken
 * before the outcome was known, each keeping it for one outcome without a card (#3770). Two checks
 * pinning at once is harmless: manual steps' add keeps one unfinished step per title.
 */
const cardShown = async ($: EngineInterface, prompts: number): Promise<void> => {
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(closedRef)
    // A later request's card already holds the claim: this one is not to take it back.
    if (held.value !== undefined && held.value.prompts > prompts) break
    if ((await $.state.set(closedRef, { prompts, pinned: true }, { ifVersion: held.version })).isSet) break
  }
  await writeReasons($, true, [])
}

/**
 * Takes the card down at a new turn, as withdrawn: a session working again is not one to close. Marked
 * down only once the withdraw has answered, so a withdraw that failed is tried again at the next turn.
 */
const withdrawClose = async ($: EngineInterface): Promise<void> => {
  const held = await $.state.get(closedRef)
  if (!held.value?.pinned) return
  try {
    await ($ as unknown as WithSteps).manualSteps.withdraw({ title: CLOSE_TITLE })
  } catch (err) {
    debug($, `the close this session card could not be taken down (${errorText(err, MOD)}); it is tried again at the next turn`)
    return
  }
  await $.state.set(closedRef, { ...held.value, pinned: false }, { ifVersion: held.version })
}

/** Reading B: a main conversation Bash call, not run in the background, that may leave a process behind. */
const noteLeftBehind = async ($: EngineInterface, command: string): Promise<void> => {
  if ((await $.state.get(leftBehindRef)).value) return
  let read: unknown
  try {
    read = await $.modkit.pipeline({ command })
  } catch (err) {
    read = [{ words: [], unread: `mod-kit's reader failed: ${errorText(err, MOD)}` }]
  }
  const what = leftBehindBy(read)
  if (what) await $.state.set(leftBehindRef, what)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.state.set(interactiveRef, e.isInteractive === true)
    if (typeof e.cwd === 'string' && e.cwd) startCwd = e.cwd
    // Only where somebody is at the prompt to see it; offered in full, not behind a search, so the
    // session knows when to call it.
    if (e.isInteractive) await $.tool.register({ name: NAME, description: DESCRIPTION, inputSchema: SCHEMA, isDeferred: false })
    return next(e)
  })

  // Dan asking for something: what lets a second box be shown in one session.
  on('prompt.submit', async ($, e, next) => {
    const r = await next(e)
    if (r.drop !== undefined) return r
    // #3770: a message of any origin ends a quiet period armed before it.
    await bumpSeq($)
    let isDans = false
    try {
      isDans = await $.modkit.isDans({ origin: e.origin })
    } catch (err) {
      debug($, `could not ask mod-kit whether a message was Dan's own words (${errorText(err, MOD)}), so it was not counted as a new request`)
    }
    if (isDans) {
      await $.state.set(requestAtRef, await $.clock.now())
      for (let i = 0; i < 10; i++) {
        const held = await $.state.get(promptsRef)
        if ((await $.state.set(promptsRef, (held.value ?? 0) + 1, { ifVersion: held.version })).isSet) break
      }
    }
    return r
  })

  // Answered here and never passed down, so the guards beneath (the secret guard) are asked through
  // mod-kit's screen first (#707).
  on('tool.call', { tool: TOOL }, async ($, e) => {
    const refused = await $.modkit.screen(e)
    if (refused) return refused
    if (e.agentId !== undefined) return { deny: 'No box: only the main conversation shows the Goal accomplished box, once the work Dan asked for is finished.' }
    const x = e as unknown as Record<string, unknown>
    const toolUseId = x.tool_use_id
    const input = readInput(toolArgs(x))
    if ('refusal' in input) return { deny: `No box: ${input.refusal}.` }
    const goal = await goalNow($)
    const holds = await boxHolds($)
    const shown = (await $.state.get(shownRef)).value ?? []
    const prompts = (await $.state.get(promptsRef)).value ?? 0
    const d = decide({ goal, input, shown, prompts, holds })
    if ('refuse' in d) return { deny: `No box yet: ${d.refuse.join('; ')}.` }
    const entry: GoalBoxShown = { key: d.show.key, kind: d.show.kind, at: await $.clock.now(), prompts }
    if (!(await claim($, entry))) return { deny: 'No box yet: the box was already shown for this request; it shows again only once Dan has asked for something new.' }
    const text = boxText(d.show.goal, input.shipped)
    try {
      await $.modkit.card(cardOf(String(toolUseId), d.show.goal, input.shipped))
    } catch (err) {
      // The text below is the box where the card is not drawn: still shown, never lost.
      debug($, `the card could not be drawn (${errorText(err, MOD)}), so the box is shown as text`)
    }
    return { result: text, text, context: ['The Goal accomplished box is shown to Dan above. Do not repeat it in your reply.'] }
  }).catch(($, e, next) => cutOwn('the goal box', next))

  // #3770: a turn of the main conversation starting, of any origin, takes the close card down and
  // ends any quiet period. Only the main loop raises turn.start (a later build names a subagent's).
  on('turn.start', async ($, e, next) => {
    const r = await next(e)
    if ('agentId' in e && e.agentId !== undefined) return r
    await bumpSeq($)
    await withdrawClose($)
    return r
  })

  // #3770: what Claude Code lists as in flight, and the wake ups it has scheduled, as the main
  // conversation's stop carries them: no other event names them. Recorded under this turn's count,
  // passing the chain's answer on untouched. Without the managed setting that lets a mod see a classic
  // event (README, #875) it never runs, and the card is withheld as unread. While Dan is asleep (scope
  // modes' one sleep predicate, its noun's isAsleep) it records nothing, so the stop's lists read as
  // unread and no close card is pinned; one can go up after he wakes, once a turn ends and every
  // reading holds. Scope modes not loaded is awake, as the other mods read it; a predicate that fails
  // any other way records nothing either, which also only withholds the card.
  on('classic.Stop', async ($, e, next) => {
    const r = await next(e)
    let asleep: boolean
    try {
      asleep = (await ($ as unknown as { scopeModes: { isAsleep: () => Promise<boolean> } }).scopeModes.isAsleep()) === true
    } catch (err) {
      if (missingOf(err)?.noun !== 'scopeModes') return r
      asleep = false
    }
    if (asleep) return r
    const x = e as { background_tasks?: unknown; session_crons?: unknown }
    await $.state.set(closeStopRef, { seq: (await $.state.get(closeSeqRef)).value ?? 0, tasks: x.background_tasks, crons: x.session_crons })
    return r
  }).catch(watchesOnly)

  // #3770, reading B: a main conversation Bash call that ran (not one run in the background, which
  // the job watcher records, and not one a guard refused) is read for what may leave a process behind.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined || (r as { deny?: unknown }).deny !== undefined) return r
    const args = toolArgs(e as unknown as Record<string, unknown>)
    if (args.run_in_background === true || typeof args.command !== 'string') return r
    await noteLeftBehind($, args.command)
    return r
  }).catch(watchesOnly)

  // The met record lands after the Stop hooks, so once the turn has ended the session is sent one
  // prompt of its own to show the box. The main loop's own end only, never an interrupt.
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined || e.reason !== 'answer') return r
    if ((await $.state.get(interactiveRef)).value !== true) return r
    // #3770: the quiet period before the close card, armed under this turn's count.
    const seq = (await $.state.get(closeSeqRef)).value ?? 0
    await $.state.set(closeAnswerRef, { seq, text: e.answer })
    $.clock.after(QUIET_MS, () => void closeCheck($, seq).catch(err => debug($, `the close this session card could not be judged (${errorText(err, MOD)})`)))
    const goal = await goalNow($)
    if (goal.state !== 'none') return r
    if (!goal.met) {
      await askIfDone($)
      return r
    }
    // Claimed first, so two turn ends at once send one prompt; released again when the prompt did not
    // enter (thrown, or dropped by a hook beneath), so a passing failure never loses the box (L368).
    if (!(await markAsked($, goal.met.id))) return r
    let failed: string | undefined
    try {
      // #2132: the prompt waits until the session is idle, and mod-kit's reload of goal-box in that
      // time would drop it, so the reload is held back until it is sent, for at most mod-kit's hour.
      const condition = goal.met.condition
      const held = {
        mod: MOD,
        id: 'ask',
        what: 'the prompt asking for the Goal accomplished box',
        ms: HOLD_MAX_MS,
        hold: (input: { mod: string; id: string; what: string; ms: number }) => $.modkit.hold(input),
        release: (input: { mod: string; id: string }) => $.modkit.release(input),
        log: (line: string) => $.ui.log(line, { to: 'debug' }),
      }
      const sent = await whileHeld(held, () => $.prompt.submit({ text: askText(condition) }))
      if (sent.drop !== undefined) failed = sent.drop || 'the prompt was dropped'
    } catch (err) {
      failed = msg(err)
    }
    if (failed !== undefined) {
      await unmarkAsked($, goal.met.id)
      $.ui.log(`The goal "${goal.met.condition}" was met, but the Goal accomplished box could not be asked for (${failed}); it is asked again at the next turn end.`)
    }
    return r
  })
}
