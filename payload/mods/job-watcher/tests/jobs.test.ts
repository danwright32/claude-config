import { describe, expect, test } from 'claude-code/testing'
import { assess, isErrorLine, isPollLoop, startedJob } from '../hooks/jobs.ts'

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
})
