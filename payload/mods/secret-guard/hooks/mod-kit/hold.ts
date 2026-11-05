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
