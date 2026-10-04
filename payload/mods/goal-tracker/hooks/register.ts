import type { EngineInterface, Register } from 'claude-code'
import { empty, fromTodos, taskCreated, taskUpdated, type Progress, type StepStatus } from './progress.ts'

// Goal tracker (claude-config#612). This holds the part settled by the spec alone: each session's
// task list, its last activity and whether it waits on Dan go into the shared session registry,
// where the /goals pane (and the status bar) will read every open session's. The pane, and the
// notification that names a session waiting on Dan, wait on the design rounds with him.

const ACTIVITY_WRITE_MS = 30_000
let progress: Progress | undefined
let lastWritten = 0

// A registry write that fails never breaks the tool call it rides on; Claude is told once, on
// the next result it reads, until a write lands again.
let toldUnwritten = false
let notice: string | undefined
const publish = async ($: EngineInterface, now: number) => {
  if (!progress) return
  try {
    await $.sessions.setExtra({ key: 'progress', value: progress })
    lastWritten = now
    toldUnwritten = false
  } catch (err) {
    if (!toldUnwritten) {
      toldUnwritten = true
      notice = `The goal tracker could not record this session's progress: ${err instanceof Error ? err.message : String(err)}. Other sessions and the goals pane will not see it.`
    }
  }
}
const withNotice = <R extends { context?: string[] }>(result: R): R => {
  if (!notice) return result
  const said = notice
  notice = undefined
  return { ...result, context: [...(result.context ?? []), said] }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    progress = empty(await $.clock.now())
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const now = await $.clock.now()
    progress ??= empty(now)
    const input = e as unknown as Record<string, unknown>

    if (e.tool === 'AskUserQuestion') {
      const qs = (input.questions as { question?: string }[] | undefined) ?? []
      progress = { ...progress, waiting: { question: qs[0]?.question ?? 'a question', since: now }, lastActivityAt: now }
      await publish($, now)
      try {
        return await next(e)
      } finally {
        const after = await $.clock.now()
        const { waiting: _cleared, ...rest } = progress
        progress = { ...rest, lastActivityAt: after }
        await publish($, after)
      }
    }

    const result = await next(e)
    if (result.deny || result.isError) return result
    const before = progress

    // A subagent keeps its own list, which is not the session's goal; its work still counts as
    // the session being active (lessons review of #634).
    const fromSubagent = Boolean((e as { agentId?: string }).agentId)
    if (fromSubagent) {
      progress = { ...progress, lastActivityAt: now }
    } else if (e.tool === 'TodoWrite') {
      progress = fromTodos(progress, (input.todos as { content: string; status: StepStatus; activeForm: string }[]) ?? [], now)
    } else if (e.tool === 'TaskCreate') {
      const task = (result.result as { task?: { id?: string; subject?: string } } | undefined)?.task
      if (task?.id) progress = taskCreated(progress, { id: task.id, subject: task.subject ?? String(input.subject ?? ''), activeForm: input.activeForm as string | undefined }, now)
    } else if (e.tool === 'TaskUpdate') {
      progress = taskUpdated(progress, input as { taskId: string; status?: StepStatus | 'deleted'; subject?: string; activeForm?: string }, now)
    } else {
      progress = { ...progress, lastActivityAt: now }
    }

    // A change to the list is written at once; plain activity at most every thirty seconds.
    if (progress.steps !== before.steps || now - lastWritten >= ACTIVITY_WRITE_MS) await publish($, now)
    return withNotice(result)
  })
}
