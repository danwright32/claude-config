import type { EngineInterface, Register } from 'claude-code'
import { firstWords, permissionFor, projectOf, rowsOf, type StateWord } from './goals.ts'
import { empty, fromTodos, isStepStatus, taskCreated, taskUpdated, type Progress, type StepStatus } from './progress.ts'

// Goal tracker (claude-config#612). Each session's task list, its goal text, its last activity and
// whether it waits on Dan go into the shared session registry, where the /goals pane (below)
// reads every open session's. A session waiting on Dan, for a question or a permission, sends one
// macOS notification naming the project, and an idle prompt with nothing being asked sends "What's
// next?": these replace the two settings hooks that notified before (Dan, 2026-10-04, pickers).

const ACTIVITY_WRITE_MS = 30_000
let progress: Progress | undefined
// When a write was last tried. Never yet: the first activity of a session is written at once.
let lastTried = Number.NEGATIVE_INFINITY

// A registry write that fails never breaks the tool call it rides on; Claude is told once, on
// the next result it reads, until a write lands again.
let toldUnwritten = false
let notice: string | undefined
let toldNoClock = false
const publish = async ($: EngineInterface, now: number) => {
  if (!progress) return
  // The throttle counts attempts, so a failing registry is not retried on every tool call.
  lastTried = now
  try {
    await $.sessions.setExtra({ key: 'progress', value: progress })
    toldUnwritten = false
  } catch (err) {
    if (!toldUnwritten) {
      toldUnwritten = true
      notice = `The goal tracker could not record this session's progress: ${err instanceof Error ? err.message : String(err)}. Other sessions and the goals pane will not see it.`
    }
  }
}
const unknownStatus = (status: unknown) =>
  `The goal tracker did not record that step change: status ${JSON.stringify(status)} is not one of pending, in_progress, completed or deleted, so the session's progress is as it was.`
const withNotice = <R extends { context?: readonly string[] }>(result: R): R => {
  if (!notice) return result
  const said = notice
  notice = undefined
  return { ...result, context: [...(result.context ?? []), said] }
}

// Notifications (Dan, 2026-10-04): one per waiting moment, naming the project. A question: "<project>
// is waiting on you", the question. A permission: "<project> needs a permission", what it is for,
// with the sound the settings hook it replaces made. "What's next?" only for an idle prompt with
// nothing being asked. One that cannot be sent is said once a session, in one dim line (the guards'
// note style), its reason also in the debug log; it never holds up or breaks what it rides on.
let startCwd = ''
let project: string | undefined
let toldNoNotify = false
const baseName = (path: string) => path.replace(/\/+$/, '').split('/').pop() || path
// This session's project, from its own registry record (the one place its repository is worked out).
const projectName = async ($: EngineInterface): Promise<string> => {
  if (project) return project
  try {
    const l = await $.sessions.list()
    const self = [...l.open, ...l.closed].find(r => r.sessionId === l.selfId)
    if (self) return (project = projectOf(self))
  } catch {
    // The folder it started in names it instead.
  }
  return baseName(startCwd) || 'Claude Code'
}
const notify = async ($: EngineInterface, title: string, message: string, sound?: string) => {
  let why: string | undefined
  try {
    const r = await $.process.run(['terminal-notifier', '-title', title, '-message', message, ...(sound ? ['-sound', sound] : [])], { timeoutMs: 10_000 })
    if (r.exitCode !== 0) why = r.stderr.trim() || `terminal-notifier exited ${r.exitCode}`
  } catch (err) {
    why = err instanceof Error ? err.message : String(err)
  }
  if (why === undefined) return
  $.ui.log(`goal-tracker: could not send the notification "${title}": ${why}`, { to: 'debug' })
  if (!toldNoNotify) {
    toldNoNotify = true
    $.ui.log(`The goal tracker could not send a notification: ${why}.`)
  }
}
// Sent beside the call it announces, never awaited by it: a notifier that hangs never holds up a question.
const notifySoon = ($: EngineInterface, title: () => Promise<string>, message: string, sound?: string) => {
  void title()
    .then(t => notify($, t, message, sound))
    .catch(err => $.ui.log(`goal-tracker: could not send a notification: ${err instanceof Error ? err.message : String(err)}`, { to: 'debug' }))
}
// A clock that cannot be read stamps a goal or a request with the last activity's time instead.
const nowOr = ($: EngineInterface): Promise<number> => $.clock.now().catch(() => progress?.lastActivityAt ?? 0)

// The /goals pane (claude-config#612, docs/mods-design.md "Goals pane", settled 2026-10-04): every
// open session on this Mac, in any project, two lines each. Project and goal on top; beneath, the
// state word in its own colour and one dim sentence. A live pane: it follows the sessions as they
// move and closes itself when Dan next sends a message.

const PANE = 'goals'
// Other sessions write their records on their own schedule, so the pane reads the registry again
// on this cadence while it is open.
const FOLLOW_MS = 5_000

// On the state word only (colour round): waiting on you and stalled amber, failed red, working blue,
// done green, as the engine's theme names them. A deliberate exception to standing rule 1.
const COLOUR: Record<StateWord, string> = {
  'waiting on you': 'warning',
  failed: 'error',
  stalled: 'warning',
  working: 'suggestion',
  done: 'success',
}

let isOpen = false
let follow: { cancel: () => void } | undefined
const stopFollowing = () => {
  follow?.cancel()
  follow = undefined
  isOpen = false
}

const open = async ($: EngineInterface): Promise<string | undefined> => {
  const r = await $.ui.open({ id: PANE, title: 'Goals' })
  isOpen = true
  follow?.cancel()
  follow = $.clock.every(FOLLOW_MS, () => $.ui.invalidate('ui.render'))
  return r.isPlaced ? undefined : `The goals pane is open but not shown: ${r.reason}.`
}

// The module has one session.start and one prompt.submit hook (in register below), which call these.
const paneStart = async ($: EngineInterface) => {
  stopFollowing()
  await $.command.register({ name: 'goals', description: "Every open session's goal and progress" })
}

// Closed by Dan's next message (picker): a slash command, /goals itself included, is not one.
const paneOnPrompt = async ($: EngineInterface, e: { text: string; origin: { kind: string } }) => {
  const isPerson = e.origin.kind === 'composer' || e.origin.kind === 'bridge'
  if (isOpen && isPerson && !e.text.trim().startsWith('/')) {
    stopFollowing()
    await $.ui.close({ id: PANE })
  }
}

// Failed, decided with Dan (2026-10-04, after the review of #634): three tool calls in a row failed
// or refused, nothing succeeding between; the next success clears it.
const FAIL_STREAK = 3
let streak = 0
// The failure is recorded as its first line, cut to a short length: the registry is shared with
// every session on this Mac, so a tool's whole output never goes into it (L657, lessons review).
const FAILED_MAX = 200
const oneLine = (text: string): string => {
  const first = text.split('\n').map(l => l.trim()).find(Boolean) ?? 'it failed'
  return first.length > FAILED_MAX ? `${first.slice(0, FAILED_MAX - 3)}...` : first
}
const failureOf = (r: { deny?: unknown; isError?: boolean; text?: unknown }): string | undefined =>
  r.deny ? oneLine(String(r.deny)) : r.isError ? oneLine(String(r.text ?? 'it failed')) : undefined
const counted = (p: Progress, why: string | undefined): Progress => {
  if (why === undefined) {
    streak = 0
    const { failed: _cleared, ...rest } = p
    return rest
  }
  streak += 1
  return streak >= FAIL_STREAK ? { ...p, failed: why } : p
}

export const register: Register = on => {
  // Everything the module keeps belongs to one session: a later start in the same process begins
  // again rather than reading the last one's (lessons review of #634).
  on('session.start', async ($, e, next) => {
    progress = empty(await $.clock.now())
    lastTried = Number.NEGATIVE_INFINITY
    streak = 0
    notice = undefined
    toldUnwritten = false
    toldNoClock = false
    toldNoNotify = false
    startCwd = e.cwd
    project = undefined
    await paneStart($)
    return next(e)
  })

  on('command.run', { command: 'goals' }, async $ => {
    const said = await open($)
    return said ? { text: said } : {}
  })

  on('ui.close', { id: PANE }, async ($, e, next) => {
    stopFollowing()
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    let list
    try {
      list = await $.sessions.list()
    } catch (err) {
      // A registry that cannot be read is said, never drawn as no sessions (L10).
      return (
        <Box flexDirection="column">
          <Text dimColor>
            {`Session records could not be read: ${err instanceof Error ? err.message : String(err)}.`}
          </Text>
        </Box>
      )
    }
    const rows = rowsOf(list.open, await $.clock.now())
    const unreadable = list.unreadable.length
    return (
      <Box flexDirection="column">
        {rows.length === 0 ? <Text dimColor>No open session has recorded its progress.</Text> : null}
        {rows.map((r, i) => (
          <Box key={`session-${r.sessionId}`} flexDirection="column" marginTop={i ? 1 : 0}>
            <Text>{r.goal ? `${r.project}  ${r.goal}` : r.project}</Text>
            <Text>
              {'  '}
              <Text color={COLOUR[r.state]}>
                {r.state}
              </Text>
              <Text dimColor>
                {r.sentence}
              </Text>
            </Text>
          </Box>
        ))}
        {unreadable ? (
          <Box marginTop={rows.length ? 1 : 0}>
            <Text dimColor>
              {`${unreadable} session ${unreadable === 1 ? 'record' : 'records'} could not be read.`}
            </Text>
          </Box>
        ) : null}
      </Box>
    )
  })

  // The goal text (Dan, 2026-10-04, picker): the /goal condition while one is set, else the first
  // request cut to a few words. No model call.
  on('command.run', { command: 'goal' }, async ($, e, next) => {
    const result = await next(e)
    const args = e.args.trim()
    if (!args || !progress) return result
    if (args === 'clear') {
      const { goal: _cleared, ...rest } = progress
      progress = rest
    } else progress = { ...progress, goal: args }
    await publish($, await nowOr($))
    return result
  })

  // Dan's first message is the goal text until a /goal is set; a slash command is not a request.
  on('prompt.submit', async ($, e, next) => {
    await paneOnPrompt($, e)
    const result = await next(e)
    const isPerson = e.origin.kind === 'composer' || e.origin.kind === 'bridge'
    const text = e.text.trim()
    if (isPerson && progress && progress.request === undefined && text && !text.startsWith('/')) {
      progress = { ...progress, request: firstWords(text) }
      await publish($, await nowOr($))
    }
    return result
  })

  // A permission prompt is the session waiting on Dan, as a question is (spec item 4): marked for the
  // pane until the call it belongs to returns, and notified.
  on('classic.PermissionRequest', async ($, e, next) => {
    const what = permissionFor(e.tool_name, e.tool_input)
    if (progress) {
      const now = await nowOr($)
      progress = { ...progress, waiting: { question: what, since: now, kind: 'permission' } }
      await publish($, now)
    }
    notifySoon($, async () => `${await projectName($)} needs a permission`, what, 'Glass')
    return next(e)
  })

  // "What's next?" only while nothing is being asked: an open question or permission sent its own.
  on('classic.Notification', async ($, e, next) => {
    if (e.notification_type === 'idle_prompt' && !progress?.waiting) notifySoon($, async () => 'Claude Code', "What's next?")
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    // A clock that cannot be read leaves this call untracked, never broken; Claude is told once,
    // until the clock reads again (lessons review of c4ae14f).
    let now: number
    try {
      now = await $.clock.now()
      toldNoClock = false
    } catch (err) {
      if (!toldNoClock) {
        toldNoClock = true
        notice = `The goal tracker could not read the clock (${err instanceof Error ? err.message : String(err)}), so this session's progress is not being recorded.`
      }
      return withNotice(await next(e))
    }
    progress ??= empty(now)
    const input = e as unknown as Record<string, unknown>
    // A subagent keeps its own list, which is not the session's goal; its work still counts as
    // the session being active, and its failures are its own (lessons review of #634).
    const fromSubagent = Boolean((e as { agentId?: string }).agentId)

    if (e.tool === 'AskUserQuestion' && !fromSubagent) {
      const qs = (input.questions as { question?: string }[] | undefined) ?? []
      const question = qs[0]?.question ?? 'a question'
      progress = { ...progress, waiting: { question, since: now, kind: 'question' }, lastActivityAt: now }
      await publish($, now)
      notifySoon($, async () => `${await projectName($)} is waiting on you`, question)
      // A question that throws or is refused counts toward failed, as any call does. What follows
      // the question can never throw over its result or error, and a notice its write raises rides
      // on this result (lessons review of #634).
      const settle = async (why: string | undefined) => {
        let after = now
        try {
          after = await $.clock.now()
        } catch {
          // The time the question was asked stands in for a clock that cannot be read.
        }
        const { waiting: _cleared, ...rest } = progress ?? empty(now)
        progress = { ...counted(rest, why), lastActivityAt: after }
        await publish($, after)
      }
      let result
      try {
        result = await next(e)
      } catch (err) {
        await settle(err instanceof Error ? err.message : String(err))
        throw err
      }
      await settle(failureOf(result))
      return withNotice(result)
    }

    const result = await next(e)
    const waitingBefore = progress.waiting
    // A permission asked inside this call has been answered, either way, once it returns.
    if (progress.waiting?.kind === 'permission') {
      const { waiting: _answered, ...rest } = progress
      progress = rest
    }
    const before = progress
    const why = failureOf(result)

    if (fromSubagent || why !== undefined) {
      progress = { ...(fromSubagent ? progress : counted(progress, why)), lastActivityAt: now }
    } else {
      progress = counted(progress, undefined)
      if (e.tool === 'TodoWrite') {
        const todos = Array.isArray(input.todos) ? (input.todos as { content: string; status: unknown; activeForm: string }[]) : []
        const odd = todos.find(t => !isStepStatus(t?.status))
        // A list carrying a status the tracker cannot count is not stored at all, and Claude is told.
        if (odd) {
          notice = unknownStatus(odd.status)
          progress = { ...progress, lastActivityAt: now }
        } else progress = fromTodos(progress, todos as { content: string; status: StepStatus; activeForm: string }[], now)
      } else if (e.tool === 'ProposeGoal' && typeof input.condition === 'string' && input.condition.trim()) {
        // A goal Claude proposed is the goal once the call succeeds (set, or approved by Dan).
        progress = { ...progress, goal: input.condition.trim(), lastActivityAt: now }
      } else if (e.tool === 'TaskCreate') {
        const task = (result.result as { task?: { id?: string; subject?: string } } | undefined)?.task
        // A result with no task id cannot be followed, but the call is still activity.
        progress = task?.id
          ? taskCreated(progress, { id: task.id, subject: task.subject ?? String(input.subject ?? ''), activeForm: input.activeForm as string | undefined }, now)
          : { ...progress, lastActivityAt: now }
      } else if (e.tool === 'TaskUpdate') {
        const status = input.status
        // An update carrying a status the tracker cannot count is not stored at all, and Claude is told.
        if (status !== undefined && status !== 'deleted' && !isStepStatus(status)) {
          notice = unknownStatus(status)
          progress = { ...progress, lastActivityAt: now }
        } else progress = taskUpdated(progress, input as { taskId: string; status?: StepStatus | 'deleted'; subject?: string; activeForm?: string }, now)
      } else {
        progress = { ...progress, lastActivityAt: now }
      }
    }

    // A change to the list or to failed is written at once; plain activity at most every thirty seconds.
    if (progress.steps !== before.steps || progress.failed !== before.failed || progress.goal !== before.goal || progress.waiting !== waitingBefore || now - lastTried >= ACTIVITY_WRITE_MS) await publish($, now)
    return withNotice(result)
  })
}
