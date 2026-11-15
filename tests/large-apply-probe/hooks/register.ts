// A stand-in hook for tests/test-large-git-apply-engine.sh (#2948). Never installed: it lives outside
// payload. On a Bash call it reads for SPIN_MS of real time, as a guard reading a large patch slowly
// would, in the way LARGE_APPLY_PROBE says:
//   - whole: in one stretch with no pause, as the design round guard's name reader did on a patch
//     holding a font inlined as base64 (#2948). The hooks worker then answers no heartbeat, and the
//     suite must see it lost and the engine name this mod.
//   - pieces: in stretches of PIECE_MS with a pause between them, the pause the design round guard's
//     reading in pieces takes (register.ts pauseTurn: a call to $.clock.now(), which crosses to the
//     engine and back), so the suite sees that pause keep the worker answering through a reading
//     longer than the heartbeat.
//   - anything else, or unset: nothing at all.
import type { Register } from 'claude-code'

const SPIN_MS = 7_000
const PIECE_MS = 50

const spin = (ms: number) => {
  const end = Date.now() + ms
  while (Date.now() < end) {
    // a reading that holds the worker
  }
}

export const register: Register = on => {
  on('tool.check', { tool: 'Bash' }, async ($, e, next) => {
    const mode = await $.env.get('LARGE_APPLY_PROBE')
    if (mode === 'whole') spin(SPIN_MS)
    if (mode === 'pieces')
      for (let done = 0; done < SPIN_MS; done += PIECE_MS) {
        spin(PIECE_MS)
        await $.clock.now()
      }
    return next(e)
  })
}
