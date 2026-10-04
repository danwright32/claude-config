import { describe, expect, test } from 'claude-code/testing'
import { empty, fromTodos, stateOf, taskCreated, taskUpdated } from '../hooks/progress.ts'

const MIN = 60_000

describe('a task list, whichever tool keeps it', () => {
  test('the to-do list is read whole: steps, done, and the step under way', () => {
    const p = fromTodos(
      empty(0),
      [
        { content: 'Read the issue', status: 'completed', activeForm: 'Reading the issue' },
        { content: 'Write the test', status: 'in_progress', activeForm: 'Writing the test' },
        { content: 'Ship it', status: 'pending', activeForm: 'Shipping it' },
      ],
      5 * MIN,
    )
    expect(p.steps.map(s => s.status)).toEqual(['completed', 'in_progress', 'pending'])
    expect({ done: p.done, total: p.total, current: p.current }).toEqual({ done: 1, total: 3, current: 'Writing the test' })
    expect(p.lastStepAt).toBe(5 * MIN)
  })
  test('the task tools build it one task at a time', () => {
    let p = taskCreated(empty(0), { id: '1', subject: 'Read the issue', activeForm: 'Reading the issue' }, MIN)
    p = taskCreated(p, { id: '2', subject: 'Write the test' }, MIN)
    p = taskUpdated(p, { taskId: '1', status: 'in_progress' }, 2 * MIN)
    expect(p.current).toBe('Reading the issue')
    p = taskUpdated(p, { taskId: '1', status: 'completed' }, 3 * MIN)
    expect({ done: p.done, total: p.total, lastStepAt: p.lastStepAt }).toEqual({ done: 1, total: 2, lastStepAt: 3 * MIN })
    p = taskUpdated(p, { taskId: '2', status: 'deleted' }, 4 * MIN)
    expect(p.total).toBe(1)
  })
  test('a step finished again does not count twice', () => {
    let p = taskCreated(empty(0), { id: '1', subject: 'x' }, 0)
    p = taskUpdated(p, { taskId: '1', status: 'completed' }, MIN)
    p = taskUpdated(p, { taskId: '1', status: 'completed' }, 2 * MIN)
    expect(p.done).toBe(1)
    expect(p.lastStepAt).toBe(MIN)
  })
})

describe('the four states (Dan, progress rule: never a bare spinner)', () => {
  const base = { ...empty(0), steps: [{ id: '1', subject: 'x', status: 'in_progress' as const }], total: 1, lastStepAt: 0, lastActivityAt: 0 }
  test('working while a step or a tool ran in the last ten minutes', () => {
    expect(stateOf({ ...base, lastActivityAt: 9 * MIN }, 10 * MIN)).toBe('working')
  })
  test('stalled when no step finished and no tool ran for ten minutes', () => {
    expect(stateOf(base, 10 * MIN + 1)).toBe('stalled')
  })
  test('done when every step is', () => {
    expect(stateOf({ ...base, steps: [{ id: '1', subject: 'x', status: 'completed' }], done: 1 }, 60 * MIN)).toBe('done')
  })
  test('failed when the session said so', () => {
    expect(stateOf({ ...base, failed: 'the build broke' }, MIN)).toBe('failed')
  })
  test('waiting on Dan outranks stalled: a question unanswered is not a stall', () => {
    expect(stateOf({ ...base, waiting: { question: 'Which colour?', since: 0 } }, 60 * MIN)).toBe('waiting')
  })
})
