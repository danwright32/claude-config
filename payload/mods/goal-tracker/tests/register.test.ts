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

const world = (on: On, opts: { duringAsk?: (w: { progress: Rec[] }) => void; registryFails?: boolean; askThrows?: boolean; askRefused?: boolean } = {}) => {
  const w = { progress: [] as Rec[] }
  on('process.run', ($, e) => ({
    value: opts.registryFails && e.argv[0] === '__extra'
      ? { exitCode: 1, stdout: '', stderr: 'registry write failed', isStdoutTruncated: false, isStderrTruncated: false }
      : { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  }))
  on('ui.log', ($, e) => {
    if (e.text.startsWith('EXTRA progress ')) w.progress.push(JSON.parse(e.text.slice('EXTRA progress '.length)))
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', ($, e) => {
    if (e.tool === 'AskUserQuestion') opts.duringAsk?.(w)
    if (e.tool === 'AskUserQuestion' && opts.askThrows) throw new Error('the question could not be shown')
    if (e.tool === 'AskUserQuestion' && opts.askRefused) return { deny: 'the question was refused' } as never
    if (e.tool === 'Bash' && String((e as unknown as { command?: string }).command).startsWith('fail')) return { result: 'exit 1', text: 'Exit code 1', isError: true } as never
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
