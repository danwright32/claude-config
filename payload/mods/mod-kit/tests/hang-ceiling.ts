// The test every mod's tests are written with (claude-config#1577): Claude Code's own `test`, with
// the time a test may run set where only a HANG reaches it. A mod's tests use a byte for byte copy of
// this file under their tests/mod-kit/tests, and mod-kit's own tests import it beside them;
// tools/check-mod-shared-parts.sh fails a test file that takes `test` from 'claude-code/testing'
// itself, naming the copy to use.
//
// THIS IS A CEILING FOR HANGS, NOT A JUDGEMENT OF SPEED. The runner gives every test 5,000 ms unless
// it is told otherwise, and has no file wide or global setting (only `timeoutMs` on each test).
// Nothing in these tests judges real time: they run on the test clock (`mock.clock`), so the 5,000 ms
// was the only real time limit any of them had, a fixed number, and it measured the machine (L290).
// On 2026-10-23 at 16:24 ET, twenty copies of mod-kit's tests at once beside 96 busy loops and 60
// process launching loops (load average 220 to 346 on 12 cores) failed 20 of 20, with 490 tests
// "timed out after 5000 ms" and nothing broken; the slowest of those tests takes about 450 ms on a
// quiet Mac. Account-room's tests failed the same way in #1541, which set two minutes for that one
// file, and Dan kept it (2026-10-23). This is that two minutes, for every mod, held here once.
//
// A test that never finishes still fails, two minutes in, naming itself. A test that is merely slow
// is not this file's business: a cost worth guarding is guarded by counting what it does (L224), and
// a time that matters is set on the test clock, never measured against the wall.
import { test as kitTest, type TestBody, type TestOptions } from 'claude-code/testing'

export const HANG_MS = 120_000

export function test(name: string, body: TestBody): void
export function test(name: string, options: TestOptions, body: TestBody): void
export function test(name: string, first: TestBody | TestOptions, body?: TestBody): void {
  if (typeof first === 'function') return kitTest(name, { timeoutMs: HANG_MS }, first)
  if (body === undefined) throw new Error(`test '${name}' was given options and no body`)
  return kitTest(name, { timeoutMs: HANG_MS, ...first }, body)
}
