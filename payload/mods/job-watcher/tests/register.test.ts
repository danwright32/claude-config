import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

// A stand-in for the session registry: what the watcher records there comes back as a transcript
// line the world collects (an inline plugin cannot reach this file's variables).
const deps: { name: string; register: Register } = {
  name: 'deps',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        sessions: {
          list: async () => ({ open: [], closed: [], unreadable: [], selfId: 'me' }),
          noteEdit: async () => undefined,
          setExtra: async ({ key, value }: { key: string; value: unknown }) => built.ui.log(`EXTRA ${key} ${JSON.stringify(value)}`),
        },
      }
    })
  },
}
const withDeps = { plugins: [deps] }

const MIN = 60_000
const OUT = '/tmp/tasks/job1.output'
const STARTED = `Command running in background with ID: job1. Output is being written to: ${OUT}. You will be notified when it completes.`
const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })

// The Mac beneath the watcher: one background job writing to OUT, whose output the test sets.
const world = (on: On, job: { tail: string; size: number }) => {
  const w = { reached: [] as { tool: string; input: Record<string, unknown> }[], extra: [] as unknown[], contexts: [] as string[] }
  on('process.run', ($, e) => {
    const [cmd, ...args] = e.argv
    if (cmd === 'lsof') return ok('501\n')
    if (cmd === 'ps' && args.includes('pgid=')) return ok('501\n')
    if (cmd === 'ps' && args.includes('-g')) return ok('501\n')
    if (cmd === 'stat') return ok(`${job.size}\n`)
    if (cmd === 'tail') return ok(job.tail)
    return { value: { exitCode: 1, stdout: '', stderr: 'unexpected', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.log', ($, e) => {
    if (e.text.startsWith('EXTRA jobs ')) w.extra.push(JSON.parse(e.text.slice('EXTRA jobs '.length)))
    return { value: undefined }
  })
  on('ui.toast', () => ({ value: undefined }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', ($, e) => {
    const input = e as unknown as Record<string, unknown>
    w.reached.push({ tool: e.tool, input })
    if (e.tool === 'Bash' && input.run_in_background) return { result: STARTED, text: STARTED } as never
    return { result: 'ran', text: 'ran' } as never
  })
  return w
}

const start = ($: { session: { start: (e: never) => Promise<unknown> } }) => $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
const contextOf = (r: unknown) => ((r as { context?: string[] }).context ?? []).join('\n')

test('a background job is recorded with its process group, traced through its output file', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { tail: 'starting\n', size: 9 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  expect(w.extra[w.extra.length - 1]).toEqual([{ id: 'job1', command: 'npm run dev', outputPath: OUT, pgid: 501, startedAt: 0 }])
})

test('a poll loop that only ever repeats an error is stopped by itself, and Claude is told', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const loop = 'until curl -sf http://x?y; do sleep 3; done'
  const w = world(on, { tail: Array.from({ length: 30 }, () => 'zsh: no matches found: http://x?y').join('\n') + '\n', size: 9000 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: loop, run_in_background: true } as never)
  await clock.advance(MIN + 1)
  const stops = w.reached.filter(r => r.tool === 'TaskStop')
  expect(stops.map(s => s.input.task_id)).toEqual(['job1'])
  expect(w.extra[w.extra.length - 1]).toEqual([])
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toContain('job1')
  expect(contextOf(next)).toContain('zsh: no matches found')
})

test('a job gone silent for ten minutes is not stopped, but Claude is told', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { tail: 'listening on 3000\n', size: 18 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  await clock.advance(11 * MIN)
  expect(w.reached.filter(r => r.tool === 'TaskStop')).toEqual([])
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toContain('job1')
  expect(contextOf(next)).toMatch(/no new output/)
})

test('a healthy job says nothing', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const job = { tail: 'built 1\n', size: 8 }
  const w = world(on, job)
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run build:watch', run_in_background: true } as never)
  job.tail = 'built 1\nbuilt 2\n'
  job.size = 16
  await clock.advance(MIN + 1)
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toBe('')
  void w
})
