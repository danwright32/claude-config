// A guard's catch that can never throw (#2039, #2026).
//
// A guard registers its hook with `.catch(($, e, next) => ...)`, and the engine runs that catch when
// the hook itself failed (a throw, or Claude Code's hooks worker missing a heartbeat under load). The
// catch is the guard's last word on the call. If the catch throws as well, nothing of the guard's is
// left to answer, and the call is not held by it: the guard has failed open. So every guard's catch
// goes through this one function, which tries the work (most often the hook judged once more), then a
// fallback (a refusal naming the failure), then a last answer built before anything could fail, and
// never throws.
//
// The engine gives a catch 1,000 ms of its own time (`next.budget`; none of its $ calls count). A
// catch that runs past it is cut, and the call it was guarding RUNS: measured 2026-11-02 with a catch
// awaiting a timer, and again 2026-11-05 end to end (tests/test-catch-grace.sh). A catch that judges
// the call once more (ask-before-saving's, #2026) does the hook's whole judgement in that grace, so it
// starts the rerun through withinGrace, which holds the call when less than CATCH_RESERVE_MS is left.
// Measured unloaded (2026-11-04, 68 samples) and at load 78 to 118 (2026-11-02): every catch started
// with 999 to 1,000 ms left and used 0 to 2 ms, a 97 KB command included, so the check holds a call
// only when the catch started late or its own work was slow, never on an ordinary day. A synchronous
// overrun cannot be preempted by any timer; the check can only refuse before the slow part starts.
//
// Each guard keeps a copy at hooks/mod-kit/hold.ts, byte for byte, which
// tools/check-mod-shared-parts.sh holds to this one. The same tool fails a registration catch that
// does not go through neverThrows, and one that reruns its hook without withinGrace.

/**
 * How much of a catch's 1,000 ms grace must be left for its slow part to start: half of it, against
 * the 0 to 2 ms of its own time a catch was measured to use (#2039).
 */
export const CATCH_RESERVE_MS = 500

/**
 * Run `work` only while at least `reserveMs` of `budget` is left; otherwise answer `outOfTime`, and
 * the work never starts. `budget` is the catch's `next.budget`, whose `remainingMs` counts the catch's
 * own time and none of its $ calls; a test hands in its own (L524). A budget that reads as no number
 * holds the call too, since how much is left cannot be known.
 */
export const withinGrace = <R>(
  budget: { readonly remainingMs: number },
  work: () => R | Promise<R>,
  outOfTime: () => R | Promise<R>,
  reserveMs: number = CATCH_RESERVE_MS,
): R | Promise<R> => (budget.remainingMs >= reserveMs ? work() : outOfTime())

/**
 * Run `work`; if it throws or rejects, run `fallback`; if that throws or rejects too, answer `last`.
 * Never throws. `last` is a value, built by the caller before the hook ran, so nothing can fail in it.
 */
export const neverThrows = async <R>(work: () => R | Promise<R>, fallback: () => R | Promise<R>, last: R): Promise<R> => {
  try {
    return await work()
  } catch {
    try {
      return await fallback()
    } catch {
      return last
    }
  }
}

// The registration catch itself (#3655).
//
// Claude Code cuts a hook at 10 s of its own time (its `next` and `$` calls are not counted), and a
// tool.call or tool.check hook with no catch is then skipped, so the call it was judging RUNS: 6 of 6
// headless runs on 2026-11-25, Claude Code 2.1.332, where a catch that refuses held in 9 of 9. A hook
// that throws is skipped the same way. So no mod writes that catch by hand, and none leaves it out:
// every hook a mod registers at tool.call or tool.check ends in one of the four below, and
// tests/test-mod-guard-catch.sh fails any that does not.
//
//   on('tool.call', ...).catch(($, e, next) => cutCall(MOD, e, next))   a hook that can refuse or ask
//   on('tool.check', ...).catch(($, e, next) => cutCheck(MOD, next))     the same at the permission check
//   on('tool.call', { tool: OWN }, ...).catch(($, e, next) => cutOwn(MOD, next))   it answers the mod's own tool
//   on('tool.call', ...).catch(watchesOnly)   a hook that never refuses: it only watches the call
//
// Each of the first three refuses, in words that name the mod, say why (out of time, or that it
// failed), that the call was refused and that it can be sent again. A guard whose catch does more
// (judges the call once more, or refuses in its own words) hands that in as `own`, and it is run
// inside neverThrows here, so a mod's own catch code can still never be the reason a call ran.
// The handler is written out at the registration because Claude Code's validator takes only a
// function literal there, or the name of a function (read 2026-11-25, 2.1.332).
//
// A mod's hooks on one event fail as ONE (read in the test engine the same day, 12 cases): whichever
// of them failed, the engine asks their catches in the order they were registered, the first that
// answers anything is the answer, and `next.called` says whether the call beneath the mod ran. So a
// first hook's refusing catch answers for every later hook of the mod on that call, and one that
// judges only some calls says which with `mine`: for any other call it answers nothing and the next
// catch is asked. watchesOnly answers nothing for the same reason.
//
// A hook that computes without yielding is stopped by the hooks worker's heartbeat at about 6 s.
// With no catch its mod is then UNLOADED and the call runs (3 of 3 runs, same day); with one of
// these the mod stays loaded and the call does not run (6 of 6: refused at tool.call, failed as an
// error at tool.check, where the engine no longer asks the catch).

/** Why a hook failed, as the engine hands it to a catch on `next.error`. */
export type Cut = { readonly kind?: string; readonly message?: string } | undefined

/** What every catch's `next` carries: whether the hook had called it, and why the hook failed. */
export type Caught = { readonly called: boolean; readonly error?: Cut }

/** What a guard's catch does of its own, each part optional, none of it able to make the catch throw. */
export type Own<A> = {
  /** Tried first: the guard's own judgement of the failed call (a rerun starts through withinGrace). */
  readonly work?: () => A | Promise<A>
  /** The guard's own refusal, in its own words, where `work` is absent or failed. */
  readonly held?: () => A | Promise<A>
  /** The answer when both failed: a value built before the hook ran. */
  readonly last?: A
  /**
   * For a tool.call hook that judges the call's RESULT: what it answers when it was cut after the
   * call ran, in place of the bare replay (the result with a note that it went unjudged, say). Where
   * this fails too, the replay stands.
   */
  readonly after?: () => A | Promise<A>
  /**
   * Whether the failed call is one this hook judges, for a hook that passes the rest straight on.
   * Where it is not, this catch answers nothing and the mod's next catch is asked. Where this throws,
   * the call is taken as the hook's own, so it is refused rather than handed on.
   */
  readonly mine?: () => boolean
}

// The hooks worker missing a heartbeat reaches a catch as a throw whose words say so (#2727), and
// a hook that timed out as kind 'timeout'. Either way the guard ran out of time.
const OUT_OF_TIME = /\bno answer to a heartbeat within \d+ ?ms\b|\btimed out after \d+ ?m?s\b/i

/**
 * Why the hook could not answer, by the failure's kind only: never throws, and never the error's own
 * words, which can quote the very input the guard could not read, a secret included (lessons review
 * of #1298). The words themselves are in the debug log, where Claude Code puts every failed hook.
 */
export const cutWhy = (cut: Cut): string =>
  cut?.kind === 'timeout' || (typeof cut?.message === 'string' && OUT_OF_TIME.test(cut.message)) ? 'it ran out of time' : 'it failed'

/** What Claude reads when a guard was cut before it judged a call. `mod` is the guard as it names itself. */
export const cutRefusal = (mod: string, cut: Cut): string =>
  `Blocked: ${mod} could not check this call (${cutWhy(cut)}), so the call was refused and did not run. This is not a judgement of what the call does: send the same call again. If it keeps happening, tell Dan.`

/** The same for a mod's own tool, whose hook IS the call: part of it may have been done by the cut. */
export const ownRefusal = (mod: string, cut: Cut): string =>
  `Blocked: ${mod} could not finish answering this call to its own tool (${cutWhy(cut)}), so the call was refused. What it had done by then stands, so check before sending the call again. If it keeps happening, tell Dan.`

type Deny = { deny: string }
type Denied = { decision: 'deny'; reason: string }

// One body for the three: `work`, then the refusal, then `last`, never a throw.
const answer = <A, B>(own: Own<A>, refusal: () => B, last: A | B): Promise<A | B> => {
  const held = (): A | B | Promise<A | B> => (own.held ? own.held() : refusal())
  return neverThrows<A | B>(() => (own.work ? own.work() : held()), held, last)
}

// Whether the catch leaves the failed call to the mod's next catch: only where `mine` says, without
// throwing, that the call is not this hook's.
const handsOn = <A>(own: Own<A>): boolean => {
  if (!own.mine) return false
  try {
    return own.mine() === false
  } catch {
    return false
  }
}

// A result judging hook cut after the call ran: its own answer about the result, else the replay.
const replayed = async <E, N extends (e: E) => unknown, A>(e: E, next: N, after: () => A | Promise<A>): Promise<A | Awaited<ReturnType<N>>> => {
  try {
    return await after()
  } catch {
    return (await next(e)) as Awaited<ReturnType<N>>
  }
}

/**
 * What the catch of a tool.call hook that can refuse or ask answers. A hook cut after it passed the
 * call on replays what the call settled to (it already ran, so a refusal saying it did not would be
 * false); one cut before that refuses.
 */
export const cutCall = <E, N extends ((e: E) => unknown) & Caught, A = Deny>(mod: string, e: E, next: N, own: Own<A> = {}): ReturnType<N> | Promise<A | Deny | Awaited<ReturnType<N>>> | undefined =>
  handsOn(own)
    ? undefined
    : next.called
      ? own.after
        ? replayed(e, next, own.after)
        : (next(e) as ReturnType<N>)
      : answer<A, Deny>(own, () => ({ deny: cutRefusal(mod, next.error) }), own.last ?? { deny: cutRefusal(mod, undefined) })

/**
 * What the catch of a tool.check hook that can refuse or ask answers. Nothing has run at the check,
 * and its `next` only reads the verdict beneath, so the cut hook's call is refused either way.
 */
export const cutCheck = <A = Denied>(mod: string, next: Caught, own: Own<A> = {}): Promise<A | Denied> | undefined =>
  handsOn(own) ? undefined : answer<A, Denied>(own, () => ({ decision: 'deny', reason: cutRefusal(mod, next.error) }), own.last ?? { decision: 'deny', reason: cutRefusal(mod, undefined) })

/**
 * What the catch of a tool.call hook that answers the mod's own tool answers. Such a hook passes
 * nothing on, and a call no hook answers fails beneath it, so this adds no refusal: it says in the
 * mod's name what happened, and that part of the work may stand.
 */
export const cutOwn = <A = Deny>(mod: string, next: Caught, own: Own<A> = {}): Promise<A | Deny> | undefined =>
  handsOn(own) ? undefined : answer<A, Deny>(own, () => ({ deny: ownRefusal(mod, next.error) }), own.last ?? { deny: ownRefusal(mod, undefined) })

/**
 * The catch of a tool.call or tool.check hook that never refuses or asks: it only watches the call,
 * or adds to what the call answered. It answers nothing, which the engine reads as the hook absent,
 * exactly as a hook with no catch is read, so the call goes on as it would have. Writing it is the
 * mod saying so on the registration, where tests/test-mod-guard-catch.sh reads it and fails a hook
 * so declared whose own lines answer a refusal.
 */
export const watchesOnly = (): undefined => undefined
