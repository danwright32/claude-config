import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

// A stand-in for the session registry: what the tracker records there comes back as a transcript
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
          setExtra: async ({ key, value }: { key: string; value: unknown }) => {
            // The world can refuse a write, so a failing registry can be staged.
            const gate = await built.process.run(['__extra', key])
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

type Rec = { done: number; total: number; current: string | null; lastActivityAt: number; waiting?: { question: string }; failed?: string }

// failExtraFrom: registry writes fail from this one on (1 is the first). taskWithoutId: a
// TaskCreate answers with no task id.
type WorldOpts = { duringAsk?: (w: { progress: Rec[] }) => void; registryFails?: boolean; failExtraFrom?: number; askThrows?: boolean; askRefused?: boolean; taskWithoutId?: boolean }
const world = (on: On, opts: WorldOpts = {}) => {
  const w = { progress: [] as Rec[], attempts: 0 }
  let writes = 0
  on('process.run', ($, e) => {
    const isWrite = e.argv[0] === '__extra'
    if (isWrite) writes += 1
    if (isWrite) w.attempts += 1
    const fails = isWrite && (opts.registryFails || (opts.failExtraFrom !== undefined && writes >= opts.failExtraFrom))
    return {
      value: fails
        ? { exitCode: 1, stdout: '', stderr: 'registry write failed', isStdoutTruncated: false, isStderrTruncated: false }
        : { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    }
  })
  on('ui.log', ($, e) => {
    if (e.text.startsWith('EXTRA progress ')) w.progress.push(JSON.parse(e.text.slice('EXTRA progress '.length)))
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', ($, e) => {
    if (e.tool === 'AskUserQuestion') opts.duringAsk?.(w)
    if (e.tool === 'AskUserQuestion' && opts.askThrows) throw new Error('the question could not be shown')
    if (e.tool === 'AskUserQuestion' && opts.askRefused) return { deny: 'the question was refused' } as never
    if (e.tool === 'Bash' && String((e as unknown as { command?: string }).command).startsWith('bigfail')) return { result: 'exit 1', text: 'Exit code 1\n' + 'x'.repeat(5000) + '\nsecret=abc', isError: true } as never
    if (e.tool === 'Bash' && String((e as unknown as { command?: string }).command).startsWith('fail')) return { result: 'exit 1', text: 'Exit code 1', isError: true } as never
    if (e.tool === 'TaskCreate' && opts.taskWithoutId) return { result: { task: {} }, text: 'created' } as never
    if (e.tool === 'TaskCreate') {
      const subject = (e as unknown as { subject: string }).subject
      return { result: { task: { id: String(w.progress.length + 1), subject } }, text: 'created' } as never
    }
    return { result: 'ran', text: 'ran' } as never
  })
  return w
}
const last = (w: { progress: Rec[] }) => w.progress[w.progress.length - 1]
const start = ($: { session: { start: (e: never) => Promise<unknown> } }) => $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)

test('a to-do list is recorded with its progress and the step under way', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call({
    tool: 'TodoWrite',
    todos: [
      { content: 'Read', status: 'completed', activeForm: 'Reading' },
      { content: 'Build', status: 'in_progress', activeForm: 'Building' },
    ],
  } as never)
  expect(last(w)).toMatchObject({ done: 1, total: 2, current: 'Building' })
})

test('the task tools are followed through their ids', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'TaskCreate', subject: 'Read', description: 'x', activeForm: 'Reading' } as never)
  await $.tool.call({ tool: 'TaskUpdate', taskId: '1', status: 'in_progress' } as never)
  expect(last(w)).toMatchObject({ total: 1, current: 'Reading' })
  await $.tool.call({ tool: 'TaskUpdate', taskId: '1', status: 'completed' } as never)
  expect(last(w)).toMatchObject({ done: 1, total: 1 })
})

test('any tool call counts as activity, written at most every thirty seconds', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'TodoWrite', todos: [{ content: 'Build', status: 'in_progress', activeForm: 'Building' }] } as never)
  const before = w.progress.length
  await clock.advance(10_000)
  await $.tool.call({ tool: 'Bash', command: 'ls' } as never)
  expect(w.progress.length).toBe(before)
  await clock.advance(MIN)
  await $.tool.call({ tool: 'Bash', command: 'ls' } as never)
  expect(last(w)?.lastActivityAt).toBe(70_000)
})

test('a question to Dan marks the session waiting while it is open, and clears after', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  let during: Rec | undefined
  const w = world(on, { duringAsk: x => (during = x.progress[x.progress.length - 1]) })
  await start($)
  await $.tool.call({ tool: 'AskUserQuestion', questions: [{ question: 'Which colour?', header: 'Colour', options: [], multiSelect: false }] } as never)
  expect(during?.waiting?.question).toBe('Which colour?')
  expect(last(w)?.waiting).toBeUndefined()
})

// Lessons review of #634: a subagent keeps its own to-do list, which is not the session's goal.
test("a subagent's to-do list leaves the session's progress alone", withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'TodoWrite', todos: [{ content: 'Build', status: 'in_progress', activeForm: 'Building' }] } as never)
  await $.tool.call({
    tool: 'TodoWrite',
    agentId: 'sub1',
    todos: [
      { content: 'Search', status: 'completed', activeForm: 'Searching' },
      { content: 'Report', status: 'completed', activeForm: 'Reporting' },
    ],
  } as never)
  expect(last(w)).toMatchObject({ done: 0, total: 1, current: 'Building' })
})

test('a registry that cannot be written never breaks the tool call, and Claude is told once', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { registryFails: true })
  await start($)
  const r = (await $.tool.call({ tool: 'TodoWrite', todos: [{ content: 'Build', status: 'in_progress', activeForm: 'Building' }] } as never)) as { text?: string; context?: string[] }
  expect(r.text).toBe('ran')
  expect((r.context ?? []).join('\n')).toContain("The goal tracker could not record this session's progress")
  const again = (await $.tool.call({ tool: 'TodoWrite', todos: [{ content: 'Build', status: 'completed', activeForm: 'Building' }] } as never)) as { context?: string[] }
  expect(again.context ?? []).toEqual([])
  expect(w.progress).toEqual([])
})

test('a question that throws still clears waiting', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { askThrows: true })
  await start($)
  await $.tool.call({ tool: 'AskUserQuestion', questions: [{ question: 'Which colour?', header: 'Colour', options: [], multiSelect: false }] } as never).catch(() => undefined)
  expect(last(w)?.waiting).toBeUndefined()
})

// Decided with Dan (2026-10-04, after the review of #634): failed means three tool calls in a row
// failed or were refused, with nothing succeeding between; the next success clears it.
const bash = (command: string) => ({ tool: 'Bash', command }) as never

test('three failed calls in a row mark the session failed, naming the last failure', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call(bash('fail 1'))
  await $.tool.call(bash('fail 2'))
  expect(last(w)?.failed).toBeUndefined()
  await $.tool.call(bash('fail 3'))
  expect(last(w)?.failed).toBe('Exit code 1')
})

test('a success clears failed, and a success between failures restarts the count', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  for (const c of ['fail 1', 'fail 2', 'fail 3']) await $.tool.call(bash(c))
  await $.tool.call(bash('ls'))
  expect(last(w)?.failed).toBeUndefined()
  for (const c of ['fail 4', 'fail 5', 'ls', 'fail 6']) await $.tool.call(bash(c))
  expect(last(w)?.failed).toBeUndefined()
})

test('a refused question counts toward failed, and still clears waiting', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { askRefused: true })
  await start($)
  await $.tool.call(bash('fail 1'))
  await $.tool.call(bash('fail 2'))
  await $.tool.call({ tool: 'AskUserQuestion', questions: [{ question: 'Which colour?', header: 'Colour', options: [], multiSelect: false }] } as never)
  expect(last(w)?.waiting).toBeUndefined()
  expect(last(w)?.failed).toBe('the question was refused')
})

// Lessons review of #634, the second round of code-only findings.
// The engine itself keeps a call's result or error when a hook fails after next (its "kept"), so
// what a throwing clock could lose is the tracker's own work: waiting must still be cleared.
test('a clock that throws after a question still clears waiting', withDeps, async ($, on) => {
  let afterAsk = false
  on('clock.now', () => {
    if (afterAsk) throw new Error('clock broke')
    return { value: 0 } as never
  })
  const w = world(on, { duringAsk: () => (afterAsk = true) })
  await start($)
  const r = (await $.tool.call({ tool: 'AskUserQuestion', questions: [{ question: 'Which colour?', header: 'Colour', options: [], multiSelect: false }] } as never)) as { text?: string }
  expect(r.text).toBe('ran')
  expect(w.progress.length).toBe(2)
  expect(last(w)?.waiting).toBeUndefined()
})

test('a clock that throws after a question that threw still clears waiting and keeps the error', withDeps, async ($, on) => {
  let afterAsk = false
  on('clock.now', () => {
    if (afterAsk) throw new Error('clock broke')
    return { value: 0 } as never
  })
  const w = world(on, { askThrows: true, duringAsk: () => (afterAsk = true) })
  await start($)
  const err = await $.tool.call({ tool: 'AskUserQuestion', questions: [{ question: 'Which colour?', header: 'Colour', options: [], multiSelect: false }] } as never).then(
    () => 'no error',
    (e: unknown) => (e instanceof Error ? e.message : String(e)),
  )
  expect(err).not.toBe('no error')
  expect(err).not.toContain('clock broke')
  expect(w.progress.length).toBe(2)
  expect(last(w)?.waiting).toBeUndefined()
})

test('a registry write that fails after a question is said on that question result', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { failExtraFrom: 2 })
  await start($)
  const r = (await $.tool.call({ tool: 'AskUserQuestion', questions: [{ question: 'Which colour?', header: 'Colour', options: [], multiSelect: false }] } as never)) as { context?: string[] }
  expect((r.context ?? []).join('\n')).toContain("The goal tracker could not record this session's progress")
  void w
})

test('a TaskCreate whose result carries no task id still counts as activity', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { taskWithoutId: true })
  await start($)
  await $.tool.call({ tool: 'TodoWrite', todos: [{ content: 'Build', status: 'in_progress', activeForm: 'Building' }] } as never)
  await clock.advance(MIN)
  await $.tool.call({ tool: 'TaskCreate', subject: 'Read', description: 'x', activeForm: 'Reading' } as never)
  expect(last(w)?.lastActivityAt).toBe(MIN)
})

test('a new session start in the same process writes its first activity at once', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'TodoWrite', todos: [{ content: 'Build', status: 'in_progress', activeForm: 'Building' }] } as never)
  await clock.advance(10_000)
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'ls' } as never)
  expect(last(w)).toMatchObject({ total: 0, lastActivityAt: 10_000 })
})

test('a registry that still cannot be written is said again after a new session start', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  world(on, { registryFails: true })
  await start($)
  await $.tool.call({ tool: 'TodoWrite', todos: [{ content: 'Build', status: 'in_progress', activeForm: 'Building' }] } as never)
  await start($)
  const r = (await $.tool.call({ tool: 'TodoWrite', todos: [{ content: 'Build', status: 'completed', activeForm: 'Building' }] } as never)) as { context?: string[] }
  expect((r.context ?? []).join('\n')).toContain("The goal tracker could not record this session's progress")
})

test('while the registry fails, plain activity still tries a write at most every thirty seconds', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { registryFails: true })
  await start($)
  await $.tool.call({ tool: 'TodoWrite', todos: [{ content: 'Build', status: 'in_progress', activeForm: 'Building' }] } as never)
  const first = w.attempts
  for (let i = 0; i < 3; i++) {
    await clock.advance(5_000)
    await $.tool.call({ tool: 'Bash', command: 'ls' } as never)
  }
  expect(w.attempts).toBe(first)
  await clock.advance(20_000)
  await $.tool.call({ tool: 'Bash', command: 'ls' } as never)
  expect(w.attempts).toBe(first + 1)
})

// Lessons review of c4ae14f.
test('a clock that cannot be read never breaks a tool call, and Claude is told once', withDeps, async ($, on) => {
  let broken = false
  on('clock.now', () => {
    if (broken) throw new Error('clock broke')
    return { value: 0 } as never
  })
  world(on)
  await start($)
  broken = true
  const r = (await $.tool.call({ tool: 'Bash', command: 'ls' } as never)) as { text?: string; context?: string[] }
  expect(r.text).toBe('ran')
  expect((r.context ?? []).join('\n')).toContain('The goal tracker could not read the clock')
  const again = (await $.tool.call({ tool: 'Bash', command: 'ls' } as never)) as { context?: string[] }
  expect((again.context ?? []).join('\n')).not.toContain('could not read the clock')
})

test('a failure is recorded as one short line, never the whole tool output', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  for (let i = 0; i < 3; i++) await $.tool.call(bash('bigfail'))
  const failed = last(w)?.failed ?? ''
  expect(failed.startsWith('Exit code 1')).toBe(true)
  expect(failed.length).toBeLessThanOrEqual(200)
  expect(failed).not.toContain('\n')
  expect(failed).not.toContain('secret')
})

// Lessons review of #634: a step's status is the caller's input, never trusted. One outside pending,
// in_progress, completed (and deleted, for a task) is not stored, since it would break the done
// count, and Claude is told on that result.
const contextText = (r: unknown) => ((r as { context?: string[] }).context ?? []).join('\n')
test('a task update with a status the tracker does not know is not stored, and Claude is told', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'TaskCreate', subject: 'Read', description: 'x', activeForm: 'Reading' } as never)
  await $.tool.call({ tool: 'TaskUpdate', taskId: '1', status: 'completed' } as never)
  const r = await $.tool.call({ tool: 'TaskUpdate', taskId: '1', status: 'finished' } as never)
  expect(last(w)).toMatchObject({ done: 1, total: 1 })
  expect(contextText(r)).toContain('"finished"')
  const again = await $.tool.call(bash('ls'))
  expect(contextText(again)).not.toContain('"finished"')
})

test('a to-do list carrying a status the tracker does not know is not stored, and Claude is told', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'TodoWrite', todos: [{ content: 'Read', status: 'completed', activeForm: 'Reading' }] } as never)
  const r = await $.tool.call({
    tool: 'TodoWrite',
    todos: [
      { content: 'Read', status: 'done', activeForm: 'Reading' },
      { content: 'Build', status: 'pending', activeForm: 'Building' },
    ],
  } as never)
  expect(last(w)).toMatchObject({ done: 1, total: 1 })
  expect(contextText(r)).toContain('"done"')
})
