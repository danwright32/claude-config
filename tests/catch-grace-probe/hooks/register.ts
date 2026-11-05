// A stand-in guard for tests/test-catch-grace.sh (#2039). Never installed: it lives outside payload.
//
// Its hook always fails the way a guard's hook fails under load (the hooks worker missing a heartbeat),
// so the engine runs its catch with the 1,000 ms grace it gives every catch. The catch then uses up its
// own time until less than CATCH_RESERVE_MS is left, and its slow part is a wait the engine does not
// count as a $ call, so it runs past the grace. Measured (2026-11-05): the engine cuts such a catch at
// the grace and the call RUNS, unguarded. A command of "bare" takes the slow part straight; "checked"
// takes it through withinGrace, which must hold the call instead.
//
// hold.ts is not committed here: the suite copies payload/mods/mod-kit/hooks/hold.ts in beside this
// file in a temporary copy, so the helper under test is always the real one (a hooks module cannot
// import a file outside its own folder).
import type { Register } from 'claude-code'
import { CATCH_RESERVE_MS, neverThrows, withinGrace } from './hold.ts'

const OUT_OF_TIME = 'Blocked: the guard could not check this call (it ran out of time).'

export const register: Register = on => {
  on('tool.call', { tool: 'Bash' }, async () => {
    throw new Error('no answer to a heartbeat within 5000ms: the hooks worker is wedged')
  }).catch(async ($, e, next) => {
    while (next.budget.remainingMs >= CATCH_RESERVE_MS) {
      // the catch's own work, until the grace is nearly spent: a condition, not a fixed time
    }
    const slow = async () => {
      await new Promise<void>(resolve => setTimeout(resolve, 2_000))
      return { deny: 'Blocked: judged after the grace.' }
    }
    const work = () =>
      String((e as { command?: string }).command) === 'checked' ? withinGrace(next.budget, slow, () => ({ deny: OUT_OF_TIME })) : slow()
    return neverThrows(work, () => ({ deny: OUT_OF_TIME }), { deny: OUT_OF_TIME })
  })
}
