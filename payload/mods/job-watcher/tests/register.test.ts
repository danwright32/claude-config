import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

// A stand-in for the session registry: what the watcher records there comes back as a transcript
// line the world collects (an inline plugin cannot reach this file's variables), and the sessions
// it lists are the world's.
const deps: { name: string; register: Register } = {
  name: 'deps',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        sessions: {
          list: async () => {
            const r = await built.process.run(['__sessions'])
            if (r.exitCode !== 0) throw new Error(r.stderr)
            return JSON.parse(r.stdout)
          },
          noteEdit: async () => undefined,
          setExtra: async ({ key, value }: { key: string; value: unknown }) => {
            // The world can refuse a write, so a failing registry can be staged.
            const gate = await built.process.run(['__extra', key, JSON.stringify(value)])
            if (gate.exitCode !== 0) throw new Error(gate.stderr)
            built.ui.log(`EXTRA ${key} ${JSON.stringify(value)}`)
          },
        },
      }
    })
  },
}
const withDeps = { plugins: [deps] }

const MIN = 60_000
const outOf = (id: string) => `/tmp/tasks/${id}.output`
const OUT = outOf('job1')
const startedText = (id: string) => `Command running in background with ID: ${id}. Output is being written to: ${outOf(id)}. You will be notified when it completes.`
const res = (exitCode: number, stdout: string, stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } })
const ok = (stdout: string) => res(0, stdout)

// One background job on the Mac beneath the watcher, writing to its own output file; the test sets
// its output. gone: its process group has no processes left. stop: how Claude Code answers a
// TaskStop. holder: who holds its output file open (held, the job; none, nobody; error, lsof
// fails). killed: what kill does to its group (ok ends it, survives leaves it running, fails).
type Job = {
  tail: string
  size: number
  mtime?: number
  unreadable?: boolean
  gone?: boolean
  stop?: 'ok' | 'refused' | 'throws'
  holder?: 'held' | 'none' | 'error'
  kill?: 'ok' | 'survives' | 'fails'
  /** Its process group; 501, 502, ... by its place when not given. */
  pgid?: number
  failExtraOf?: string
}
// The rest of the world: failExtra makes every registry write fail; sessions is what the registry
// lists; verdict answers each model call ('none' for no answer, 'throws' to reject the call).
type World = {
  failExtra?: boolean
  sessions?: { open?: unknown[]; closed?: unknown[]; unreadable?: string[] } | 'throws'
  verdict?: (model: string, prompt: string) => string | 'none' | 'throws'
}
const world = (on: On, jobOrJobs: Job | Job[], o: World = {}) => {
  const list = Array.isArray(jobOrJobs) ? jobOrJobs : [jobOrJobs]
  const w = {
    reached: [] as { tool: string; input: Record<string, unknown> }[],
    extra: [] as unknown[],
    logs: [] as string[],
    toasts: [] as string[],
    kills: [] as string[][],
    asked: [] as { model: string; prompt: string }[],
    tools: [] as unknown[],
  }
  let started = 0
  const byPath = (p: string | undefined) => list.findIndex((_, i) => outOf(`job${i + 1}`) === p)
  const groupOf = (i: number) => list[i]?.pgid ?? 501 + i
  const byGroup = (g: number) => list.findIndex((_, i) => groupOf(i) === g)
  on('process.run', ($, e) => {
    const [cmd, ...args] = e.argv
    if (cmd === '__sessions') {
      if (o.sessions === 'throws') return res(1, '', 'the sessions folder could not be read')
      return ok(JSON.stringify({ open: o.sessions?.open ?? [], closed: o.sessions?.closed ?? [], unreadable: o.sessions?.unreadable ?? [], selfId: 'me' }))
    }
    if (cmd === '__extra') {
      const failing = o.failExtra || list.some(j => j.failExtraOf !== undefined && args[1] === j.failExtraOf)
      return failing ? res(1, '', 'registry write failed') : ok('')
    }
    if (cmd === 'lsof') {
      const i = byPath(args[args.length - 1])
      const j = list[i]
      if (!j || j.holder === 'none' || j.gone) return res(1, '')
      if (j.holder === 'error') return res(1, '', 'lsof: status error on file: Operation not permitted')
      return ok(`${groupOf(i)}\n`)
    }
    if (cmd === 'ps' && args.includes('pgid=')) return ok(`${args[args.length - 1]}\n`)
    if (cmd === 'ps' && args.includes('-g')) {
      const j = list[byGroup(Number(args[args.indexOf('-g') + 1]))]
      return !j || j.gone ? res(1, '') : ok('501\n')
    }
    if (cmd === '/bin/kill') {
      w.kills.push(args)
      const i = byGroup(-Number(args[args.length - 1]))
      const j = list[i]
      if (!j || j.kill === 'fails') return res(1, '', 'kill: Operation not permitted')
      if (j.kill !== 'survives') j.gone = true
      return ok('')
    }
    const j = list[byPath(args[args.length - 1])]
    if ((cmd === 'stat' || cmd === 'tail') && (!j || j.unreadable)) return res(1, '', `${cmd}: Permission denied`)
    if (cmd === 'stat' && j) return ok(args.includes('%z %m') ? `${j.size} ${j.mtime ?? 0}\n` : `${j.size}\n`)
    if (cmd === 'tail' && j) return ok(j.tail)
    return res(1, '', 'unexpected')
  })
  on('model.complete', ($, e) => {
    const req = e as unknown as { model: string; prompt: string }
    w.asked.push({ model: req.model, prompt: req.prompt })
    const v = o.verdict?.(req.model, req.prompt) ?? 'none'
    if (v === 'none') return { value: { isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage: {} } } as never
    if (v === 'throws') throw new Error('the model is blocked')
    return { value: { isAnswered: true, text: v, usage: {} } } as never
  })
  on('tool.register', ($, e) => {
    w.tools.push(e)
    return { value: undefined } as never
  })
  on('ui.log', ($, e) => {
    if (e.text.startsWith('EXTRA jobs ')) w.extra.push(JSON.parse(e.text.slice('EXTRA jobs '.length)))
    else w.logs.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', ($, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', ($, e) => {
    const input = e as unknown as Record<string, unknown>
    w.reached.push({ tool: e.tool, input })
    if (e.tool === 'Bash' && input.run_in_background) {
      started += 1
      const text = startedText(`job${started}`)
      return { result: text, text } as never
    }
    const j = list[Number(String(input.task_id ?? '').replace('job', '')) - 1]
    if (e.tool === 'TaskStop' && j?.stop === 'refused') return { deny: `no task ${String(input.task_id)} is running` } as never
    if (e.tool === 'TaskStop' && j?.stop === 'throws') throw new Error('stop failed')
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

test('an output file that cannot be read is reported as unreadable, never as a silent job, and only once', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { tail: '', size: 0, unreadable: true })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  await clock.advance(11 * MIN)
  expect(w.reached.filter(r => r.tool === 'TaskStop')).toEqual([])
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toContain('job1')
  expect(contextOf(next)).toMatch(/could not read its output file/)
  expect(contextOf(next)).not.toMatch(/no new output/)
  await clock.advance(5 * MIN)
  const later = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(later)).toBe('')
})

// Lessons review of #634, the code-only findings.
const LOOP = 'until curl -sf http://x?y; do sleep 3; done'
const REPEATING = Array.from({ length: 30 }, () => 'zsh: no matches found: http://x?y').join('\n') + '\n'

test('a job that has finished leaves the record and is never reported silent', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const job: Job = { tail: 'done\n', size: 5 }
  const w = world(on, job)
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run build', run_in_background: true } as never)
  job.gone = true
  await clock.advance(11 * MIN)
  expect(w.extra[w.extra.length - 1]).toEqual([])
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toBe('')
})

test('a stop Claude Code refuses keeps the job, and Claude is told the stop failed', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { tail: REPEATING, size: 9000, stop: 'refused' })
  await start($)
  await $.tool.call({ tool: 'Bash', command: LOOP, run_in_background: true } as never)
  await clock.advance(MIN + 1)
  expect((w.extra[w.extra.length - 1] as unknown[]).length).toBe(1)
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toContain('could not be stopped')
  expect(contextOf(next)).toContain('no task job1 is running')
  expect(contextOf(next)).not.toContain('was stopped')
})

test('a stop that throws keeps the job and is said the same way', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { tail: REPEATING, size: 9000, stop: 'throws' })
  await start($)
  await $.tool.call({ tool: 'Bash', command: LOOP, run_in_background: true } as never)
  await clock.advance(MIN + 1)
  expect((w.extra[w.extra.length - 1] as unknown[]).length).toBe(1)
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toContain('could not be stopped')
})

// The registry write that forgets an ended job fails: said to Claude as a record that could not be
// written, never lost in the timer.
test('a look that fails part way is said to Claude, not lost', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const job: Job = { tail: 'done\n', size: 5, failExtraOf: '[]' }
  world(on, job)
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run build', run_in_background: true } as never)
  job.gone = true
  await clock.advance(MIN + 1)
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toContain("The background job watcher could not record this session's jobs: registry write failed")
})

test('an output file that shrank (truncated or rotated) counts as new output', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const job: Job = { tail: 'line\n', size: 100 }
  world(on, job)
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  await clock.advance(MIN + 1)
  job.size = 10
  await clock.advance(5 * MIN)
  await clock.advance(5 * MIN)
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toBe('')
})

test('a waiting loop repeating a line that is not an error is reported, never stopped', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { tail: Array.from({ length: 30 }, () => 'waiting for deploy').join('\n') + '\n', size: 600 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'until gh run view 9 --exit-status; do echo waiting for deploy; sleep 3; done', run_in_background: true } as never)
  await clock.advance(MIN + 1)
  expect(w.reached.filter(r => r.tool === 'TaskStop')).toEqual([])
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toContain('keeps repeating "waiting for deploy"')
})

// Lessons review of #634, the second round of code-only findings.
test('a stopped poll loop is said even when the registry write after it fails', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  world(on, { tail: REPEATING, size: 9000, failExtraOf: '[]' })
  await start($)
  await $.tool.call({ tool: 'Bash', command: LOOP, run_in_background: true } as never)
  await clock.advance(MIN + 1)
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toContain('was stopped')
})

test('a new session start in the same process forgets the last one jobs and keeps one timer', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { tail: 'listening on 3000\n', size: 18 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  await start($)
  await clock.advance(11 * MIN)
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toBe('')
  // One look a minute, not two: each look reads the output file once.
  void w
})

test('a job whose process group could not be traced is seen to end when nothing holds its output file', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const job: Job = { tail: 'done\n', size: 5, holder: 'error' }
  const w = world(on, job)
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run build', run_in_background: true } as never)
  expect((w.extra[w.extra.length - 1] as { pgid: unknown }[])[0]?.pgid).toBe(null)
  job.holder = 'none'
  await clock.advance(MIN + 1)
  expect(w.extra[w.extra.length - 1]).toEqual([])
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toBe('')
})

test('a job that still cannot be traced is said to Claude once as ended state unknown', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  world(on, { tail: 'building\n', size: 9, holder: 'error' })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run build', run_in_background: true } as never)
  await clock.advance(MIN + 1)
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toContain('whether it has ended is unknown')
  await clock.advance(MIN)
  const later = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(later)).not.toContain('whether it has ended is unknown')
})

test('a job that could not be traced at first is traced on a later look', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const job: Job = { tail: 'building\n', size: 9, holder: 'error' }
  const w = world(on, job)
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run build', run_in_background: true } as never)
  job.holder = 'held'
  await clock.advance(MIN + 1)
  expect((w.extra[w.extra.length - 1] as { pgid: unknown }[])[0]?.pgid).toBe(501)
})

test('a registry that cannot be written never breaks the Bash call that started a job, and Claude is told', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  world(on, { tail: '', size: 0 }, { failExtra: true })
  await start($)
  const r = (await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)) as { text?: string; context?: string[] }
  expect(r.text).toContain('background with ID: job1')
  expect(contextOf(r)).toContain('could not record')
})

test('a job whose look throws does not stop the look at the jobs after it', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const first: Job = { tail: 'done\n', size: 5 }
  const second: Job = { tail: 'listening on 3000\n', size: 18 }
  world(on, [first, second], {})
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run build', run_in_background: true } as never)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  await clock.advance(10 * MIN)
  // On the look that finds the second job silent, the first has ended and the registry write that
  // forgets it fails.
  first.gone = true
  first.failExtraOf = JSON.stringify([{ id: 'job2', command: 'npm run dev', outputPath: outOf('job2'), pgid: 502, startedAt: 0 }])
  await clock.advance(MIN + 1)
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toContain('job2 (npm run dev) has had no new output')
})

// Keeping a job (Dan, 2026-10-04): Claude keeps a job with a reason, from inside a turn, through
// the watcher's own tool. A kept job is published for the status bar's amber band, can be marked
// quiet by design, and passing an hour raises no toast.
const KEEP = 'mcp__job-watcher__keep_job'
const keep = (input: Record<string, unknown>) => ({ tool: KEEP, ...input }) as never
type Rec = { id: string; kept?: { name: string; reason: string; quiet: boolean; at: number } }
const lastRecs = (w: { extra: unknown[] }) => w.extra[w.extra.length - 1] as Rec[]

test('the keep tool is registered at session start', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { tail: '', size: 0 })
  await start($)
  expect(w.tools.map(t => (t as { name: string }).name)).toEqual(['keep_job'])
})

test('a job kept with a reason is published as kept, with the name the band shows', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { tail: 'listening on 3000\n', size: 18 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  await clock.advance(5 * MIN)
  const r = (await $.tool.call(keep({ task_id: 'job1', name: 'dev server', reason: 'Dan is clicking through the site' }))) as { result?: unknown; deny?: string }
  expect(r.deny).toBeUndefined()
  expect(String(r.result)).toContain('Kept job1')
  expect(lastRecs(w)[0]?.kept).toEqual({ name: 'dev server', reason: 'Dan is clicking through the site', quiet: false, at: 5 * MIN })
})

test('keeping a job that is not running is refused, naming the jobs that are', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  world(on, { tail: '', size: 0 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  const r = (await $.tool.call(keep({ task_id: 'job9', name: 'x', reason: 'y' }))) as { deny?: string; text?: string }
  expect(r.deny ?? r.text).toContain('job9')
  expect(r.deny ?? r.text).toContain('job1')
})

test('keeping a job without a reason or a name is refused', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { tail: '', size: 0 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  const noReason = (await $.tool.call(keep({ task_id: 'job1', name: 'dev server', reason: '  ' }))) as { deny?: string; text?: string }
  expect(noReason.deny ?? noReason.text).toMatch(/reason/)
  const noName = (await $.tool.call(keep({ task_id: 'job1', reason: 'needed' }))) as { deny?: string; text?: string }
  expect(noName.deny ?? noName.text).toMatch(/name/)
  expect(lastRecs(w)[0]?.kept).toBeUndefined()
})

test('a job kept as quiet by design is never reported silent', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  world(on, { tail: 'listening on 3000\n', size: 18 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  await $.tool.call(keep({ task_id: 'job1', name: 'dev server', reason: 'serves the preview', quiet: true }))
  await clock.advance(30 * MIN)
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toBe('')
})

test('a job kept without quiet is still reported silent', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  world(on, { tail: 'listening on 3000\n', size: 18 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  await $.tool.call(keep({ task_id: 'job1', name: 'dev server', reason: 'serves the preview' }))
  await clock.advance(11 * MIN)
  const next = await $.tool.call({ tool: 'Bash', command: 'git status' } as never)
  expect(contextOf(next)).toMatch(/no new output/)
})

test('a kept job passing an hour raises no toast', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { tail: 'listening on 3000\n', size: 18 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  await $.tool.call(keep({ task_id: 'job1', name: 'dev server', reason: 'serves the preview', quiet: true }))
  await clock.advance(61 * MIN)
  expect(w.toasts).toEqual([])
})

test('a keep whose registry write fails still keeps the job, and Claude is told the band cannot show it', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const job: Job = { tail: '', size: 0 }
  world(on, job)
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true } as never)
  job.failExtraOf = JSON.stringify([{ id: 'job1', command: 'npm run dev', outputPath: OUT, pgid: 501, startedAt: 0, kept: { name: 'dev server', reason: 'needed', quiet: false, at: 0 } }])
  const r = (await $.tool.call(keep({ task_id: 'job1', name: 'dev server', reason: 'needed' }))) as { result?: unknown; deny?: string; context?: string[] }
  expect(r.deny).toBeUndefined()
  expect(String(r.result)).toContain('Kept job1')
  expect(contextOf(r)).toContain('could not record')
})

// Leftover jobs at session start (Dan, 2026-10-04): jobs still alive whose session has closed are
// judged by Haiku, then Sonnet when Haiku gives no usable verdict, with no question to Dan; neither
// able, the job is left running. Stopped by the traced process group, never by command text
// (L1011). Dan sees one dim line afterwards.
const HAIKU = 'claude-haiku-4-5-20251001'
const SONNET = 'claude-sonnet-5-5'
const CURL = 'until curl -sf http://localhost:3000/health; do sleep 3; done'
const REFUSED = Array.from({ length: 30 }, () => 'curl: (7) Failed to connect to localhost port 3000: Connection refused').join('\n') + '\n'
const closedRec = (id: string, jobs: unknown[]) => ({ v: 1, sessionId: id, cwd: '/repo', repoRoot: '/repo', startedAt: 0, lastSeen: 0, closedAt: 1000, transcriptPath: null, edits: [], extra: { jobs } })
const leftover = (i: number, command: string, over: Record<string, unknown> = {}) => ({ id: `old${i}`, command, outputPath: outOf(`job${i}`), pgid: 500 + i, startedAt: 0, ...over })
const STOP = (name: string) => JSON.stringify({ stop: true, name, reason: 'it never succeeded' })
const KEEP_IT = (name: string) => JSON.stringify({ stop: false, name, reason: 'it is serving' })
const judged = async (clock: { advance: (ms: number) => Promise<void> }) => clock.advance(10_000)

const about = (prompt: string, command: string) => prompt.includes(command)

test('a leftover poll loop is stopped by its process group and a dev server left, in one dim line, with no question', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 3 * 60 * MIN })
  const w = world(on, [{ tail: REFUSED, size: 9000, mtime: 3 * 60 * 60 }, { tail: 'listening on 3000\n', size: 18, mtime: 0 }], {
    sessions: { closed: [closedRec('old', [leftover(1, CURL), leftover(2, 'npm run dev')])] },
    verdict: (model, prompt) => (about(prompt, CURL) ? STOP('curl loop repeating connection refused') : KEEP_IT('dev server')),
  })
  await start($)
  await judged(clock)
  expect(w.kills).toEqual([['-TERM', '-501']])
  expect(w.asked.map(a => a.model)).toEqual([HAIKU, HAIKU])
  expect(w.reached.filter(r => r.tool === 'AskUserQuestion')).toEqual([])
  expect(w.logs).toEqual(['Stopped 1 leftover job from a closed session (curl loop repeating connection refused); left 1 running (dev server).'])
})

test('the judge is told the command, the run time, the output tail and that it repeats', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 134 * MIN })
  const w = world(on, { tail: REFUSED, size: 9000, mtime: 134 * 60 }, {
    sessions: { closed: [closedRec('old', [leftover(1, CURL)])] },
    verdict: () => STOP('curl loop'),
  })
  await start($)
  await judged(clock)
  const prompt = w.asked[0]?.prompt ?? ''
  expect(prompt).toContain(CURL)
  expect(prompt).toContain('2h 14m')
  expect(prompt).toContain('Connection refused')
  expect(prompt).toMatch(/repeat/)
})

test('a silent leftover is described to the judge as silent', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 60 * MIN })
  const w = world(on, { tail: 'listening on 3000\n', size: 18, mtime: 0 }, {
    sessions: { closed: [closedRec('old', [leftover(1, 'npm run dev')])] },
    verdict: () => KEEP_IT('dev server'),
  })
  await start($)
  await judged(clock)
  expect(w.asked[0]?.prompt ?? '').toMatch(/no new output for 60 minutes/)
})

test('when Haiku gives no usable verdict, Sonnet decides', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 60 * MIN })
  const w = world(on, { tail: REFUSED, size: 9000 }, {
    sessions: { closed: [closedRec('old', [leftover(1, CURL)])] },
    verdict: model => (model === HAIKU ? 'I think you should probably stop it.' : STOP('curl loop')),
  })
  await start($)
  await judged(clock)
  expect(w.asked.map(a => a.model)).toEqual([HAIKU, SONNET])
  expect(w.kills).toEqual([['-TERM', '-501']])
  expect(w.logs).toEqual(['Stopped 1 leftover job from a closed session (curl loop).'])
})

test('when Haiku fails with an error, Sonnet decides', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 60 * MIN })
  const w = world(on, { tail: REFUSED, size: 9000 }, {
    sessions: { closed: [closedRec('old', [leftover(1, CURL)])] },
    verdict: model => (model === HAIKU ? 'none' : KEEP_IT('curl loop')),
  })
  await start($)
  await judged(clock)
  expect(w.asked.map(a => a.model)).toEqual([HAIKU, SONNET])
  expect(w.kills).toEqual([])
  expect(w.logs).toEqual(['Left 1 leftover job from a closed session running (curl loop).'])
})

test('when neither model can judge, the job is left running and the line says so', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 60 * MIN })
  const w = world(on, { tail: REFUSED, size: 9000 }, {
    sessions: { closed: [closedRec('old', [leftover(1, CURL)])] },
    verdict: model => (model === HAIKU ? 'none' : 'throws'),
  })
  await start($)
  await judged(clock)
  expect(w.asked.map(a => a.model)).toEqual([HAIKU, SONNET])
  expect(w.kills).toEqual([])
  // The command names it, cut to keep the line to one line.
  expect(w.logs).toEqual(['Could not judge 1 leftover job from a closed session and left it running to be judged next session (until curl -sf http://localhost:3000/...).'])
})

test('a stop that fails is said, and the job is not counted as stopped', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 60 * MIN })
  const w = world(on, { tail: REFUSED, size: 9000, kill: 'fails' }, {
    sessions: { closed: [closedRec('old', [leftover(1, CURL)])] },
    verdict: () => STOP('curl loop'),
  })
  await start($)
  await judged(clock)
  expect(w.logs).toEqual(['Could not stop 1 leftover job from a closed session (curl loop: kill: Operation not permitted).'])
})

test('a group still running after the stop is said as not stopped', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 60 * MIN })
  const w = world(on, { tail: REFUSED, size: 9000, kill: 'survives' }, {
    sessions: { closed: [closedRec('old', [leftover(1, CURL)])] },
    verdict: () => STOP('curl loop'),
  })
  await start($)
  await judged(clock)
  expect(w.logs).toEqual(['Could not stop 1 leftover job from a closed session (curl loop: it was still running after the stop signal).'])
})

test('jobs of open sessions and of this session are never judged', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 60 * MIN })
  const open = { ...closedRec('busy', [leftover(1, CURL)]), closedAt: null }
  const mine = closedRec('me', [leftover(2, CURL)])
  const w = world(on, [{ tail: REFUSED, size: 9000 }, { tail: REFUSED, size: 9000 }], {
    sessions: { open: [open], closed: [mine] },
    verdict: () => STOP('curl loop'),
  })
  await start($)
  await judged(clock)
  expect(w.asked).toEqual([])
  expect(w.kills).toEqual([])
  expect(w.logs).toEqual([])
})

test('a leftover that has already ended is not judged and not mentioned', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 60 * MIN })
  const w = world(on, { tail: REFUSED, size: 9000, holder: 'none', gone: true }, {
    sessions: { closed: [closedRec('old', [leftover(1, CURL)])] },
    verdict: () => STOP('curl loop'),
  })
  await start($)
  await judged(clock)
  expect(w.asked).toEqual([])
  expect(w.logs).toEqual([])
})

test('an output file now held by a different process group is never stopped (L1011)', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 60 * MIN })
  const w = world(on, { tail: REFUSED, size: 9000, pgid: 777 }, {
    sessions: { closed: [closedRec('old', [leftover(1, CURL)])] },
    verdict: () => STOP('curl loop'),
  })
  await start($)
  await judged(clock)
  expect(w.kills).toEqual([])
  expect(w.asked).toEqual([])
})

test('a registry that cannot be listed is said in one dim line, never taken as no leftovers', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 60 * MIN })
  const w = world(on, { tail: '', size: 0 }, { sessions: 'throws' })
  await start($)
  await judged(clock)
  expect(w.logs.length).toBe(1)
  expect(w.logs[0]).toContain('leftover jobs from closed sessions were not checked')
})
