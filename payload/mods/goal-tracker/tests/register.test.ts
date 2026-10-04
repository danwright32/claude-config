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
          setExtra: async ({ key, value }: { key: string; value: unknown }) => built.ui.log(`EXTRA ${key} ${JSON.stringify(value)}`),
        },
      }
    })
  },
}
const withDeps = { plugins: [deps] }
const MIN = 60_000

type Rec = { done: number; total: number; current: string | null; lastActivityAt: number; waiting?: { question: string } }

const world = (on: On, opts: { duringAsk?: (w: { progress: Rec[] }) => void } = {}) => {
  const w = { progress: [] as Rec[] }
  on('ui.log', ($, e) => {
    if (e.text.startsWith('EXTRA progress ')) w.progress.push(JSON.parse(e.text.slice('EXTRA progress '.length)))
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', ($, e) => {
    if (e.tool === 'AskUserQuestion') opts.duringAsk?.(w)
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
