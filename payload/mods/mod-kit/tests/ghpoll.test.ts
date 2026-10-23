import { expect, test } from 'claude-code/testing'
import { answeredLook, failedLook, nextWaitMs, pollLib, takeLook, type PollRun } from '../hooks/ghpoll.ts'

// The mods' way onto the one polling policy, hooks/lib/gh-poll.sh (#1482): a mod cannot source a
// shell library, so it runs it as a command and reads its one line. These answers are the lines
// hooks/test-gh-poll.sh section 5 holds the command to, so the two sides are tested against the same
// contract. The session is passed as CLAUDE_CODE_SESSION_ID, the key every Bash call of the session
// carries, so a mod's reads and the session's merge helpers share one budget.
type Call = { argv: string[]; env?: Record<string, string> }
const runner = (answer: (argv: string[]) => { exitCode: number; stdout: string; stderr?: string }) => {
  const calls: Call[] = []
  const run: PollRun = async (argv, env) => {
    calls.push({ argv, ...(env ? { env } : {}) })
    const a = answer(argv)
    return { exitCode: a.exitCode, stdout: a.stdout, stderr: a.stderr ?? '' }
  }
  return { run, calls }
}
const LIB = pollLib('/Users/x')

test('the library is the installed hooks copy under the home folder', () => {
  expect(LIB).toBe('/Users/x/.claude/hooks/lib/gh-poll.sh')
})

test('a look is taken, asked in seconds as the session', async () => {
  const r = runner(() => ({ exitCode: 0, stdout: 'ok\n' }))
  expect(await takeLook({ run: r.run, lib: LIB, session: 's1' }, 1_000_500)).toEqual({ take: true })
  expect(r.calls).toEqual([{ argv: ['bash', LIB, 'take', '1000'], env: { CLAUDE_CODE_SESSION_ID: 's1' } }])
})

test('a look held by a pause or the cap says which, for how long and why', async () => {
  const p = (out: string) => ({ run: runner(() => ({ exitCode: 0, stdout: out })).run, lib: LIB, session: 's1' })
  expect(await takeLook(p('wait\tpause\t75\tGitHub said to wait 75s (Retry-After)\n'), 0)).toEqual({ take: false, why: 'pause', waitMs: 75_000, said: 'GitHub said to wait 75s (Retry-After)' })
  expect(await takeLook(p('wait\tcap\t58\t\n'), 0)).toEqual({ take: false, why: 'cap', waitMs: 58_000, said: '' })
})

test('an answer it cannot read, or a library that failed, throws rather than reading as a yes', async () => {
  const bad = { run: runner(() => ({ exitCode: 0, stdout: 'maybe\n' })).run, lib: LIB, session: 's1' }
  await expect(takeLook(bad, 0)).rejects.toThrow(/maybe/)
  const gone = { run: runner(() => ({ exitCode: 127, stdout: '', stderr: 'bash: no such file' })).run, lib: LIB, session: 's1' }
  await expect(takeLook(gone, 0)).rejects.toThrow(/no such file/)
})

test("a failed read is handed over: a rate limit pauses, anything else does not", async () => {
  const r = runner(argv => ({ exitCode: 0, stdout: argv[4]?.includes('rate limit') ? 'paused\t60\ta burst limit\n' : 'other\n' }))
  const p = { run: r.run, lib: LIB, session: 's1' }
  expect(await failedLook(p, 2_000_000, 'gh: API rate limit exceeded (HTTP 403)')).toEqual({ paused: true, waitMs: 60_000, said: 'a burst limit' })
  expect(await failedLook(p, 2_000_000, 'gh: Not Found (HTTP 404)')).toEqual({ paused: false })
  expect(r.calls[0]?.argv).toEqual(['bash', LIB, 'failed', '2000', 'gh: API rate limit exceeded (HTTP 403)'])
})

test('the next wait comes from the library, in milliseconds, and an answer is recorded', async () => {
  const r = runner(argv => ({ exitCode: 0, stdout: argv[2] === 'next' ? (argv[4] === '1' ? '60\n' : '120\n') : 'ok\n' }))
  const p = { run: r.run, lib: LIB, session: 's1' }
  expect(await nextWaitMs(p, 60_000, false)).toBe(120_000)
  expect(await nextWaitMs(p, 180_000, true)).toBe(60_000)
  expect(r.calls.slice(0, 2).map(c => c.argv.slice(2))).toEqual([['next', '60', '0'], ['next', '180', '1']])
  await answeredLook(p)
  expect(r.calls[2]?.argv.slice(2)).toEqual(['answered'])
})

test("a caller's own base and ceiling are passed in seconds (scope modes keeps ten minutes)", async () => {
  const r = runner(() => ({ exitCode: 0, stdout: '600\n' }))
  expect(await nextWaitMs({ run: r.run, lib: LIB, session: 's1' }, 480_000, false, { baseMs: 60_000, maxMs: 600_000 })).toBe(600_000)
  expect(r.calls[0]?.argv.slice(2)).toEqual(['next', '480', '0', '60', '600'])
})
