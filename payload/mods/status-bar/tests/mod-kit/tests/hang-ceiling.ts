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
// On 2026-10-23 at 16:39 ET, twenty copies of mod-kit's tests at once beside 96 busy loops and 60
// process launching loops (load average 80 to 413 on 12 cores) failed 20 of 20, with 754 tests
// "timed out after 5000 ms" and nothing broken; the slowest of them takes 450 to 500 ms on a quiet
// Mac. Taking `test` from here, twenty copies in the same window at 16:43 ET (load 303 to 369)
// passed 20 of 20, the slowest test at 11,910 ms. Account-room's tests failed the same way in #1541, which set two minutes
// for that one file, and Dan kept it (2026-10-23). This is that two minutes, for every mod, held once.
//
// A test that never finishes still fails, two minutes in, naming itself. A test that is merely slow
// is not this file's business: a cost worth guarding is guarded by counting what it does (L224), and
// a time that matters is set on the test clock, never measured against the wall.
import { test as kitTest, type TestBody, type TestOptions } from 'claude-code/testing'

export const HANG_MS = 120_000

// WHAT A TEST HOLDS ENDS WITH IT (claude-config#1778). A stand-in that never answers (a call that
// hangs, a question nobody answers, a wait that never comes) is not stopped when its test ends: the
// engine cuts the hook off about five seconds of real time later (measured: 5,138 and 5,141 ms after
// the call began, in tests that ran 200 ms), and whatever the mod does after that answer then runs
// in whichever test is running by then, with that test's state and clock. Which test that is depends
// on how busy the Mac is, so the file fails at random under load: on 2026-10-26 the job watcher's git
// commit left hanging by one test finished inside a later one and stamped its agent alive, so that
// test's quiet agent was never said (1 run in 3 at load 30 to 130). So a stand-in that never answers
// comes from never(), and every test taken from here ends each one as it ends (with the answer
// given, or refused as never having come) and waits for every call handed to awaitAtEnd() to finish,
// the condition itself rather than a time (L290), before the next test starts.
// tools/check-mod-shared-parts.sh fails a mod test that hand rolls a promise that never settles.
// Tests in one file run one at a time, so what is held belongs to the test running now.
const held = new Set<() => void>()
const awaited = new Set<Promise<unknown>>()

// Held until its test ends: then answered with ended(), or, with none, refused as never having come.
export const never = <T>(ended?: () => T): Promise<T> =>
  new Promise<T>((resolve, reject) => {
    held.add(() => (ended ? resolve(ended()) : reject(new Error('its test ended, so it never came'))))
  })

// A call a test leaves waiting on something never() holds, waited on once its test has ended what it
// held, so the mod's work after the answer finishes inside the test that started it.
export const awaitAtEnd = <T>(call: Promise<T>): Promise<T> => {
  awaited.add(call)
  return call
}

// What every test's end does; a test may call it sooner to see it happen.
export const endHeld = async (): Promise<void> => {
  const ends = [...held]
  held.clear()
  for (const end of ends) end()
  const calls = [...awaited]
  awaited.clear()
  await Promise.allSettled(calls)
}

const endingHeld = (body: TestBody): TestBody => async ($, on) => {
  try {
    return await body($, on)
  } finally {
    await endHeld()
  }
}

export function test(name: string, body: TestBody): void
export function test(name: string, options: TestOptions, body: TestBody): void
export function test(name: string, first: TestBody | TestOptions, body?: TestBody): void {
  if (typeof first === 'function') return kitTest(name, { timeoutMs: HANG_MS }, endingHeld(first))
  if (body === undefined) throw new Error(`test '${name}' was given options and no body`)
  return kitTest(name, { timeoutMs: HANG_MS, ...first }, endingHeld(body))
}
