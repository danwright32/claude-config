import { describe, expect, test } from 'claude-code/testing'
import { assess, isErrorLine, isPollLoop, leftoverLine, parseVerdict, runFor, shortCommand, shortLine, startedJob } from '../hooks/jobs.ts'

const MIN = 60_000

describe('a background job, from what starting it said', () => {
  test('its id and output file are read from the tool result', () => {
    const text = 'Command running in background with ID: btv0drbh3. Output is being written to: /private/tmp/x/tasks/btv0drbh3.output. You will be notified when it completes.'
    expect(startedJob(text)).toEqual({ id: 'btv0drbh3', outputPath: '/private/tmp/x/tasks/btv0drbh3.output' })
  })
  test('a result that did not start one is not a job', () => {
    expect(startedJob('ok')).toBeUndefined()
  })
})

describe('a poll loop', () => {
  test('until or while, with a sleep, is a poll loop', () => {
    expect(isPollLoop('until curl -sf http://x/health; do sleep 3; done')).toBe(true)
    expect(isPollLoop('while ! gh pr checks 9 | grep -q pass; do sleep 30; done')).toBe(true)
  })
  test('anything else is not', () => {
    expect(isPollLoop('npm run dev')).toBe(false)
    expect(isPollLoop('for f in *.ts; do echo $f; done')).toBe(false)
  })
})

describe('is it stuck', () => {
  const lines = (n: number, s: string) => Array.from({ length: n }, () => s).join('\n') + '\n'
  test('fresh output is running', () => {
    expect(assess({ tail: 'built 1\nbuilt 2\n', size: 20, lastGrowth: 10 * MIN }, 11 * MIN)).toEqual({ state: 'running' })
  })
  test('the same error line over and over is stuck repeating (2026-09-22: 183KB of one curl error)', () => {
    expect(assess({ tail: lines(30, 'zsh: no matches found: http://x?y'), size: 9000, lastGrowth: 11 * MIN }, 11 * MIN)).toEqual({
      state: 'repeating',
      line: 'zsh: no matches found: http://x?y',
    })
  })
  test('a few repeats are not yet stuck', () => {
    expect(assess({ tail: lines(3, 'waiting'), size: 30, lastGrowth: 10 * MIN }, 10 * MIN).state).toBe('running')
  })
  test('no new output for ten minutes is stuck silent, measured from the last growth', () => {
    expect(assess({ tail: 'listening on 3000\n', size: 18, lastGrowth: 0 }, 10 * MIN + 1)).toEqual({ state: 'silent', forMs: 10 * MIN + 1 })
    expect(assess({ tail: 'listening on 3000\n', size: 18, lastGrowth: 0 }, 10 * MIN - 1).state).toBe('running')
  })
  test('a job kept as quiet by design is never silent', () => {
    expect(assess({ tail: 'listening on 3000\n', size: 18, lastGrowth: 0, quietByDesign: true }, 60 * MIN).state).toBe('running')
  })
  test('blank lines do not count as a repeating error', () => {
    expect(assess({ tail: lines(40, ''), size: 40, lastGrowth: 5 * MIN }, 5 * MIN).state).toBe('running')
  })
})

// Decided with Dan (2026-10-04, after the review of #634): a waiting loop is stopped by itself only
// when the line it repeats reads as an error.
describe('an error line', () => {
  test('lines that report a failure read as errors', () => {
    for (const line of [
      'zsh: no matches found: http://x?y',
      'curl: (7) Failed to connect to localhost port 3000 after 0 ms: Couldn\'t connect to server',
      'Error: connect ECONNREFUSED 127.0.0.1:5432',
      'fatal: not a git repository',
      'Permission denied',
      'ls: x: No such file or directory',
    ]) expect(isErrorLine(line)).toBe(true)
  })
  test('a patient waiting line does not', () => {
    for (const line of ['waiting for deploy', 'checks still pending', 'Waiting for server to start...', '.', 'retrying in 3s']) expect(isErrorLine(line)).toBe(false)
  })
  // Lessons review of #634: a count of zero or a negation reports no failure.
  test('a count of zero or a negation of failure does not', () => {
    for (const line of ['0 failed, 3 pending', 'no errors yet', 'built without errors', 'errors: 0', 'Tests: 0 failures, 12 passed', 'no failures so far']) expect(isErrorLine(line)).toBe(false)
  })
  test('a real failure beside a zero count still does', () => {
    for (const line of ['0 passed, 2 failed', 'Error: connect ECONNREFUSED 127.0.0.1:5432 (no errors before this)']) expect(isErrorLine(line)).toBe(true)
  })
})

// Leftover jobs from closed sessions (Dan, 2026-10-04): a model's verdict on each, and the one dim
// line Dan sees afterwards.
describe('a verdict on a leftover job', () => {
  test('JSON with stop and a name is a verdict, wherever it sits in the reply', () => {
    expect(parseVerdict('{"stop": true, "name": "curl loop repeating connection refused"}')).toEqual({ stop: true, name: 'curl loop repeating connection refused' })
    expect(parseVerdict('Here you go:\n{"stop": false, "name": "dev server", "reason": "still serving"}\n')).toEqual({ stop: false, name: 'dev server' })
  })
  test('anything else is no verdict, never a guess', () => {
    for (const text of ['', 'stop it', '{"stop": "yes", "name": "x"}', '{"stop": true}', '{"stop": true, "name": "  "}', '{not json}']) expect(parseVerdict(text)).toBeUndefined()
  })
  test('the first verdict is found when the reply holds a second object or a stray brace', () => {
    expect(parseVerdict('{"stop": true, "name": "curl loop"} and also {"note": 1}')).toEqual({ stop: true, name: 'curl loop' })
    expect(parseVerdict('{"stop": false, "name": "dev server"}\n} trailing')).toEqual({ stop: false, name: 'dev server' })
    expect(parseVerdict('Thinking {about it}. {"stop": true, "name": "loop {x}"}')).toEqual({ stop: true, name: 'loop {x}' })
  })
  test('a long name is cut to fit one line', () => {
    expect((parseVerdict(`{"stop": true, "name": "${'x'.repeat(200)}"}`)?.name ?? '').length).toBeLessThanOrEqual(60)
  })
})

describe('how long a job has run', () => {
  test('minutes under an hour, hours and minutes after', () => {
    expect(runFor(30_000)).toBe('0m')
    expect(runFor(14 * MIN)).toBe('14m')
    expect(runFor(134 * MIN)).toBe('2h 14m')
  })
})

describe('the line Dan sees after leftovers are judged', () => {
  test('stopped and left, the settled example word for word', () => {
    expect(
      leftoverLine(
        [
          { kind: 'stopped', name: 'curl loop repeating connection refused', session: 'a' },
          { kind: 'left', name: 'dev server', session: 'a' },
        ],
        [],
      ),
    ).toBe('Stopped 1 leftover job from a closed session (curl loop repeating connection refused); left 1 running (dev server).')
  })
  // Shortened to the bare fact by Dan (2026-10-04, picker), the job named in brackets.
  test('a job that could not be judged, or stopped, says so in its own words', () => {
    expect(
      leftoverLine(
        [
          { kind: 'unjudged', name: 'npm run dev', session: 'a' },
          { kind: 'stopFailed', name: 'curl loop', why: 'kill: Operation not permitted', session: 'b' },
        ],
        [],
      ),
    ).toBe('1 leftover job not judged, left running (npm run dev); 1 leftover job could not be stopped (curl loop).')
  })
  test('the shortened lines alone, word for word', () => {
    expect(leftoverLine([{ kind: 'unjudged', name: 'dev server', session: 'a' }], [])).toBe('1 leftover job not judged, left running (dev server).')
    expect(leftoverLine([{ kind: 'stopFailed', name: 'curl loop', why: 'kill: Operation not permitted', session: 'a' }], [])).toBe('1 leftover job could not be stopped (curl loop).')
  })
  test('several of a kind are counted and named together', () => {
    expect(
      leftoverLine(
        [
          { kind: 'left', name: 'dev server', session: 'a' },
          { kind: 'left', name: 'test watcher', session: 'a' },
        ],
        [],
      ),
    ).toBe('Left 2 leftover jobs from a closed session running (dev server, test watcher).')
  })
  test('session records that could not be read are said, so their jobs are not taken as none', () => {
    expect(leftoverLine([], ['abc.json'])).toBe('Session records unreadable; leftover jobs not checked.')
    expect(leftoverLine([{ kind: 'stopped', name: 'curl loop', session: 'a' }], ['abc.json', 'def.json'])).toBe(
      'Stopped 1 leftover job from a closed session (curl loop); session records unreadable; leftover jobs not checked.',
    )
  })
  test('nothing judged and nothing unreadable is no line at all', () => {
    expect(leftoverLine([], [])).toBeUndefined()
  })
})

describe('a job named in a notice', () => {
  test('a short command is kept whole, on one line', () => {
    expect(shortCommand('  npm run\n dev  ')).toBe('npm run dev')
  })
  test('a long command is cut to forty characters, ending in dots', () => {
    const cut = shortCommand(`until curl -sf http://x/${'a'.repeat(200)}; do sleep 3; done`)
    expect(cut.length).toBe(40)
    expect(cut.endsWith('...')).toBe(true)
    expect(cut.startsWith('until curl -sf')).toBe(true)
  })
  test('a long repeated line is cut to one hundred and twenty characters', () => {
    expect(shortLine(`error: ${'b'.repeat(500)}`).length).toBe(120)
  })
})
