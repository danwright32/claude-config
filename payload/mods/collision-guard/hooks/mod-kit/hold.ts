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
// Measured on a quiet Mac (2026-11-02, #2039): every catch started with 999 to 1,000 ms of the 1,000
// ms the engine gives it, and used 0 to 2 ms of it, including a rerun over a 97 KB command at load 78
// to 118. The engine counts none of a catch's $ calls, so no reserve check before the rerun is kept
// here: it could never fire, and a wall clock race would refuse calls the rerun lets through. A
// synchronous overrun cannot be preempted by any timer.
//
// Each guard keeps a copy at hooks/mod-kit/hold.ts, byte for byte, which
// tools/check-mod-shared-parts.sh holds to this one, and the same tool fails a registration catch
// that does not go through neverThrows.

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
