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
          // This session's own record names its project, as the registry's does.
          list: async () => ({
            open: [{ v: 1, sessionId: 'me', cwd: '/Users/dan/Apps/Ovation/src', repoRoot: '/Users/dan/Apps/Ovation', startedAt: 0, lastSeen: 0, closedAt: null, transcriptPath: null, edits: [], extra: {} }],
            closed: [],
            unreadable: [],
            selfId: 'me',
          }),
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

// Picker manners (#615), standing in, since a mod's tests cannot import another mod's files. As the
// real mod does, it adds $.pickers, answers every AskUserQuestion in its own tool.call hook without
// ever calling next (more than one question is refused), and holds the open question in its state
// while it waits, writing null once the question ends. Dan's answer comes from the world, which
// sees the session as it stood while the question was open.
const PickerManners = (tier: 'prepend' | 'append'): { name: string; tier: 'prepend' | 'append'; register: Register } => ({
  name: 'picker-manners',
  tier,
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const wait = async ({ id }: { id: string }) => ({ kind: 'answer', answer: (await built.process.run(['__answer', id])).stdout })
      return { ...built, pickers: { wait } } as never
    })
    on('tool.call', { tool: 'AskUserQuestion' }, async ($, e) => {
      const questions = (e.questions ?? []) as unknown as { question: string }[]
      const q = questions[0]
      if (!q || questions.length > 1) return { deny: 'Ask one question per call: Dan answers pickers one at a time.' }
      const id = (e as unknown as { tool_use_id?: string }).tool_use_id ?? 'call-1'
      const open = { plugin: 'picker-manners', key: 'open' } as never
      await $.state.set(open, { id, question: q, chosen: [] } as never)
      try {
        const outcome = await ($ as unknown as { pickers: { wait: (i: { id: string }) => Promise<{ answer: string }> } }).pickers.wait({ id })
        return { result: { questions: e.questions, answers: { [q.question]: outcome.answer } } } as never
      } finally {
        await $.state.set(open, null as never)
      }
    })
  },
})

type Rec = { done: number; total: number; current: string | null; lastActivityAt: number; waiting?: { question: string; kind?: string }; failed?: string; goal?: string; request?: string }

// failExtraFrom: registry writes fail from this one on (1 is the first). taskWithoutId: a
// TaskCreate answers with no task id.
// notifyFails: terminal-notifier exits 1. permissionDenied: the permission prompt is answered no.
// permissionThrows: the call the prompt belongs to throws once it is answered.
type WorldOpts = {
  duringAsk?: (w: { progress: Rec[] }) => void
  registryFails?: boolean
  failExtraFrom?: number
  askThrows?: boolean
  askRefused?: boolean
  taskWithoutId?: boolean
  notifyFails?: boolean
  permissionDenied?: boolean
  permissionThrows?: boolean
}
const world = (on: On, opts: WorldOpts = {}) => {
  const w = { progress: [] as Rec[], attempts: 0, notified: [] as string[][], logs: [] as string[], duringPermission: undefined as Rec | undefined, answer: undefined as (() => void) | undefined, lint: undefined as (() => void) | undefined, duringPicker: undefined as Rec | undefined }
  let writes = 0
  on('process.run', ($, e) => {
    // Dan answering the question picker manners shows: "Yes".
    if (e.argv[0] === '__answer') {
      w.duringPicker = w.progress[w.progress.length - 1]
      return { value: { exitCode: 0, stdout: 'Yes', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    if (e.argv[0] === 'terminal-notifier') {
      w.notified.push(e.argv.slice(1))
      if (opts.notifyFails) return { value: { exitCode: 1, stdout: '', stderr: 'terminal-notifier: no permission to notify', isStdoutTruncated: false, isStderrTruncated: false } }
    }
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
    else if (e.to !== 'debug') w.logs.push(e.text)
    return { value: undefined }
  })
  on('classic.PermissionRequest', () => ({}) as never)
  on('classic.Notification', () => ({}) as never)
  on('prompt.submit', ($, e) => ({ text: e.text }) as never)
  on('command.run', () => ({ text: '' }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', async ($, e) => {
    if (e.tool === 'AskUserQuestion') opts.duringAsk?.(w)
    if (e.tool === 'AskUserQuestion' && opts.askThrows) throw new Error('the question could not be shown')
    if (e.tool === 'AskUserQuestion' && opts.askRefused) return { deny: 'the question was refused' } as never
    if (e.tool === 'Bash' && String((e as unknown as { command?: string }).command).startsWith('bigfail')) return { result: 'exit 1', text: 'Exit code 1\n' + 'x'.repeat(5000) + '\nsecret=abc', isError: true } as never
    if (e.tool === 'Bash' && String((e as unknown as { command?: string }).command).startsWith('fail')) return { result: 'exit 1', text: 'Exit code 1', isError: true } as never
    // A call Claude Code asks Dan to allow first: the permission prompt is raised inside the call.
    // The test raises the prompt while the call waits on this gate, as Claude Code does.
    if (e.tool === 'Bash' && (e as unknown as { command?: string }).command === 'npm test') {
      await new Promise<void>(r => (w.answer = r))
      w.duringPermission = w.progress[w.progress.length - 1]
      if (opts.permissionDenied) return { deny: 'The user did not allow this.' } as never
      if (opts.permissionThrows) throw new Error('the test suite could not be started')
    }
    // A Bash call running beside it, with no description either, until the test lets it finish.
    if (e.tool === 'Bash' && (e as unknown as { command?: string }).command === 'npm run lint') await new Promise<void>(r => (w.lint = r))
    if (e.tool === 'ProposeGoal') return { result: { condition: (e as unknown as { condition: string }).condition, askUser: false }, text: 'set' } as never
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

// Lessons review of 327a767: a second note never overwrites one still waiting to be said.
test('a refused status and a failed registry write on one call are both said', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  world(on, { failExtraFrom: 3 })
  await start($)
  await $.tool.call({ tool: 'TaskCreate', subject: 'Read', description: 'x', activeForm: 'Reading' } as never)
  await $.tool.call({ tool: 'TaskUpdate', taskId: '1', status: 'completed' } as never)
  // Past the activity throttle, so this call's own write is tried, and fails.
  await clock.advance(MIN)
  const r = await $.tool.call({ tool: 'TaskUpdate', taskId: '1', status: 'finished' } as never)
  expect(contextText(r)).toContain('"finished"')
  expect(contextText(r)).toContain('could not record')
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

// Notifications (Dan, 2026-10-04, pickers): one per waiting moment, naming the project. They replace
// the two settings hooks that notified before, so the mod sends all three.
const ask = (question: string) => ({ tool: 'AskUserQuestion', questions: [{ question, header: 'Format', options: [], multiSelect: false }] }) as never
const idle = ($: { classic: { Notification: (e: never) => Promise<unknown> } }) =>
  $.classic.Notification({ hook_event_name: 'Notification', session_id: 'me', transcript_path: '/t', cwd: '/repo', message: 'Claude is waiting for your input', notification_type: 'idle_prompt' } as never)

test('a question to Dan sends one notification naming the project, with the question', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call(ask('Which date format for the CSV?'))
  expect(w.notified).toEqual([['-title', 'Ovation is waiting on you', '-message', 'Which date format for the CSV?']])
})

// A Bash call that Claude Code stops to ask Dan about: the prompt is raised while the call waits.
type Raiser = { tool: { call: (e: never) => Promise<unknown> }; classic: { PermissionRequest: (e: never) => Promise<unknown> } }
const withPermission = async ($: Raiser, w: { answer: (() => void) | undefined }) => {
  const call = $.tool.call({ tool: 'Bash', command: 'npm test', description: 'Run the test suite' } as never)
  for (let i = 0; i < 50 && !w.answer; i++) await Promise.resolve()
  await $.classic.PermissionRequest({ hook_event_name: 'PermissionRequest', session_id: 'me', transcript_path: '/t', cwd: '/repo', tool_name: 'Bash', tool_input: { command: 'npm test', description: 'Run the test suite' } } as never)
  w.answer?.()
  return call
}

test('a permission prompt marks the session waiting on Dan, notifies with what it is for, and clears once answered', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await withPermission($, w)
  expect(w.duringPermission?.waiting).toMatchObject({ question: 'Run the test suite', kind: 'permission' })
  expect(w.notified).toEqual([['-title', 'Ovation needs a permission', '-message', 'Run the test suite', '-sound', 'Glass']])
  expect(last(w)?.waiting).toBeUndefined()
})

// Lessons review of 8c094ae: another call returning while a permission is still open (a parallel
// call, a subagent's) leaves the session waiting on Dan.
test('another call returning while a permission is open leaves the session waiting', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  const call = $.tool.call({ tool: 'Bash', command: 'npm test', description: 'Run the test suite' } as never)
  for (let i = 0; i < 50 && !w.answer; i++) await Promise.resolve()
  await $.classic.PermissionRequest({ hook_event_name: 'PermissionRequest', session_id: 'me', transcript_path: '/t', cwd: '/repo', tool_name: 'Bash', tool_input: { command: 'npm test', description: 'Run the test suite' } } as never)
  await $.tool.call(bash('ls'))
  expect(last(w)?.waiting).toMatchObject({ kind: 'permission' })
  w.answer?.()
  await call
  expect(last(w)?.waiting).toBeUndefined()
})

// #694 item 1: the prompt belongs to the call it was raised inside, held by that call's id, never
// matched by tool and "what for" text, which for any Bash call with no description is just "a Bash
// command". prompted starts the call Claude Code stops to ask about and raises its prompt (with
// promptInput, as the prompt names it) while the call waits; the call comes back wrapped, since it
// only settles once the test answers.
const raise = ($: Raiser, input: Record<string, unknown>) =>
  $.classic.PermissionRequest({ hook_event_name: 'PermissionRequest', session_id: 'me', transcript_path: '/t', cwd: '/repo', tool_name: 'Bash', tool_input: input } as never)
const prompted = async ($: Raiser, w: { answer: (() => void) | undefined }, input: Record<string, unknown>, promptInput = input) => {
  const call = $.tool.call({ tool: 'Bash', ...input } as never)
  for (let i = 0; i < 50 && !w.answer; i++) await Promise.resolve()
  await raise($, promptInput)
  return { call }
}
const running = async ($: Raiser, w: { lint: (() => void) | undefined }) => {
  const call = $.tool.call(bash('npm run lint'))
  for (let i = 0; i < 50 && !w.lint; i++) await Promise.resolve()
  return { call }
}

test('a parallel Bash call with no description returning while a permission is open leaves the session waiting', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  const lint = await running($ as never, w)
  const { call } = await prompted($ as never, w, { command: 'npm test' })
  expect(last(w)?.waiting).toMatchObject({ kind: 'permission', question: 'a Bash command' })
  w.lint?.()
  await lint.call
  expect(last(w)?.waiting).toMatchObject({ kind: 'permission', question: 'a Bash command' })
  w.answer?.()
  await call
  expect(last(w)?.waiting).toBeUndefined()
})

test("the prompt's own call returning clears it while another Bash call with no description runs on", withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  const lint = await running($ as never, w)
  const { call } = await prompted($ as never, w, { command: 'npm test' })
  w.answer?.()
  await call
  expect(last(w)?.waiting).toBeUndefined()
  w.lint?.()
  await lint.call
})

// A hook beneath the tracker may rewrite a call, so a prompt can name an input no running call has:
// it then belongs to one of the calls of its tool running when it was raised, and stays until each
// has returned, never cleared early by the first.
test('a prompt whose input matches no running call waits for every call of its tool that was running', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  const lint = await running($ as never, w)
  const { call } = await prompted($ as never, w, { command: 'npm test' }, { command: 'npm test --ci' })
  w.lint?.()
  await lint.call
  expect(last(w)?.waiting).toMatchObject({ kind: 'permission' })
  w.answer?.()
  await call
  expect(last(w)?.waiting).toBeUndefined()
})

// A call that rejects (an interrupt while the prompt is open does) has ended, so its prompt has too.
test('a permission whose call rejects once answered still clears waiting', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { permissionThrows: true })
  await start($)
  const { call } = await prompted($ as never, w, { command: 'npm test' })
  expect(last(w)?.waiting).toMatchObject({ kind: 'permission' })
  w.answer?.()
  const outcome = await call.then(
    () => 'settled',
    () => 'rejected',
  )
  expect(outcome).toBe('rejected')
  expect(last(w)?.waiting).toBeUndefined()
})

// #694 item 2: a question settling clears only its own mark; a permission still open stands.
test('a question asked and answered while a permission is open leaves the permission mark', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  let during: Rec | undefined
  const w = world(on, { duringAsk: x => (during = x.progress[x.progress.length - 1]) })
  await start($)
  const { call } = await prompted($ as never, w, { command: 'npm test', description: 'Run the test suite' })
  await clock.advance(1_000)
  await $.tool.call(ask('Which colour?'))
  expect(during?.waiting).toMatchObject({ kind: 'question', question: 'Which colour?' })
  expect(last(w)?.waiting).toMatchObject({ kind: 'permission', question: 'Run the test suite' })
  w.answer?.()
  await call
  expect(last(w)?.waiting).toBeUndefined()
})

test('a permission Dan refuses still clears waiting', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { permissionDenied: true })
  await start($)
  await withPermission($, w)
  expect(w.duringPermission?.waiting).toMatchObject({ kind: 'permission' })
  expect(last(w)?.waiting).toBeUndefined()
})

test("an idle prompt with nothing being asked says What's next?", withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await idle($)
  expect(w.notified).toEqual([['-title', 'Claude Code', '-message', "What's next?"]])
})

test("an idle prompt while a question is open sends nothing more: the question's notification stands", withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  let during: Promise<unknown> | undefined
  const w = world(on, { duringAsk: () => (during = idle($)) })
  await start($)
  await $.tool.call(ask('Ship it?'))
  await during
  expect(w.notified.map(n => n[1])).toEqual(['Ovation is waiting on you'])
})

// Lessons review of 4cb9221: a question starting with a dash is the question, never an option.
test('a question that starts with a dash reaches the notification as text, not as an option', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call(ask('-remove the old build?'))
  const args = w.notified[0] ?? []
  const message = args[args.indexOf('-message') + 1] ?? ''
  expect(message.startsWith('-')).toBe(false)
  expect(message).toContain('-remove the old build?')
})

test('a notification that cannot be sent is said once in a dim line, and never breaks the question', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { notifyFails: true })
  await start($)
  const r = (await $.tool.call(ask('One?'))) as { deny?: unknown; result?: unknown }
  await $.tool.call(ask('Two?'))
  expect(r.deny).toBeUndefined()
  expect(w.notified.length).toBe(2)
  const said = w.logs.filter(l => l.includes('could not send a notification'))
  expect(said.length).toBe(1)
  expect(said[0]).toContain('no permission to notify')
})

// #694 item 6: hooks on one event nest by tier and then by load order, outermost first, and a hook
// that answers without calling next keeps every hook beneath it from seeing the call. Picker manners
// answers every AskUserQuestion that way, so wherever it sits above the tracker the tracker's own
// tool.call hook never sees the question. Both orders are loaded here: picker manners in the tier
// above the tracker's (prepend), and in the tier beneath it (append).
const ORDERS = [
  ['above', 'prepend'],
  ['beneath', 'append'],
] as const
const shipIt = { tool: 'AskUserQuestion', tool_use_id: 'q1', questions: [{ question: 'Ship it?', header: 'Ship', options: [], multiSelect: false }] } as never

for (const [where, tier] of ORDERS) {
  test(`a question picker manners answers is marked and notified once, with picker manners ${where} the tracker`, { plugins: [deps, PickerManners(tier)] }, async ($, on) => {
    mock.clock(on, { now: 0 })
    const w = world(on)
    await start($)
    const r = (await $.tool.call(shipIt)) as { result?: { answers?: Record<string, string> } }
    // Picker manners answered it, never the engine's own picker beneath.
    expect(r.result?.answers).toEqual({ 'Ship it?': 'Yes' })
    expect(w.duringPicker?.waiting).toMatchObject({ question: 'Ship it?', kind: 'question' })
    expect(w.notified).toEqual([['-title', 'Ovation is waiting on you', '-message', 'Ship it?']])
    expect(last(w)?.waiting).toBeUndefined()
  })
}

// Above the tracker, the question's end is seen only as picker manners' null: it takes off the
// question's mark alone, and a permission prompt still open stands (#694 item 2 on this path too).
test('a question picker manners holds open above the tracker leaves an open permission mark when it ends', { plugins: [deps, PickerManners('prepend')] }, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  const { call } = await prompted($ as never, w, { command: 'npm test', description: 'Run the test suite' })
  await clock.advance(1_000)
  await $.tool.call(shipIt)
  expect(w.duringPicker?.waiting).toMatchObject({ kind: 'question', question: 'Ship it?' })
  expect(last(w)?.waiting).toMatchObject({ kind: 'permission', question: 'Run the test suite' })
  w.answer?.()
  await call
  expect(last(w)?.waiting).toBeUndefined()
})

// Another mod's value is read, never trusted: an open question that cannot be read marks nothing.
const Garbled: { name: string; tier: 'prepend'; register: Register } = {
  name: 'picker-manners',
  tier: 'prepend',
  register: on => {
    on('tool.call', { tool: 'AskUserQuestion' }, async ($, e) => {
      const open = { plugin: 'picker-manners', key: 'open' } as never
      await $.state.set(open, { id: 7, question: 'Ship it?' } as never)
      await $.state.set(open, null as never)
      return { result: { questions: e.questions, answers: {} } } as never
    })
  },
}
test('an open question picker manners writes in a shape that cannot be read marks and notifies nothing', { plugins: [deps, Garbled] }, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call(shipIt)
  expect(w.notified).toEqual([])
  expect(w.progress.filter(p => p.waiting !== undefined)).toEqual([])
})

// The goal text (Dan, 2026-10-04, picker): the /goal condition when one is set, otherwise the
// session's first request cut to a few words. No model call.
const prompt = ($: { prompt: { submit: (e: never) => Promise<unknown> } }, text: string) => $.prompt.submit({ text, origin: { kind: 'composer' }, wait: false } as never)
const goalCommand = ($: { command: { run: (e: never) => Promise<unknown> } }, args: string) =>
  $.command.run({ command: 'goal', args, origin: { kind: 'composer' }, presentation: { mode: 'main', columns: 120 } } as never)

test('the first request is recorded cut to a few words, and later ones do not replace it', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await prompt($, '/goals')
  await prompt($, 'Please look at why the Gmail send keeps failing on large attachments')
  await prompt($, 'and also the drafts')
  expect(last(w)?.request).toBe('Please look at why the Gmail...')
})

test('a /goal condition is recorded, and /goal clear removes it', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await goalCommand($, 'all tests in test/auth pass')
  expect(last(w)?.goal).toBe('all tests in test/auth pass')
  await goalCommand($, 'clear')
  expect(last(w)?.goal).toBeUndefined()
})

test('a goal Claude proposes and that is set is recorded', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'ProposeGoal', condition: 'the export writes a CSV', ask_user: false } as never)
  expect(last(w)?.goal).toBe('the export writes a CSV')
})

// Lessons review of f0a8ff9: a permission mark whose call is never matched as it returns is cleared
// by Dan's next message at the latest, never left waiting for ever.
test("a permission mark left over is cleared by Dan's next message", withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await $.classic.PermissionRequest({ hook_event_name: 'PermissionRequest', session_id: 'me', transcript_path: '/t', cwd: '/repo', tool_name: 'WebFetch', tool_input: { url: 'https://example.com' } } as never)
  expect(last(w)?.waiting).toMatchObject({ kind: 'permission' })
  await prompt($, 'carry on')
  expect(last(w)?.waiting).toBeUndefined()
})
