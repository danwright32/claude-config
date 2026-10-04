import type { EngineInterface, Register } from 'claude-code'
import { empty, fromTodos, taskCreated, taskUpdated, type Progress, type StepStatus } from './progress.ts'

// Goal tracker (claude-config#612). This holds the part settled by the spec alone: each session's
// task list, its last activity and whether it waits on Dan go into the shared session registry,
// where the /goals pane (and the status bar) will read every open session's. The pane, and the
// notification that names a session waiting on Dan, wait on the design rounds with him.

const ACTIVITY_WRITE_MS = 30_000
let progress: Progress | undefined
// Never written yet: the first activity of a session is written at once.
let lastWritten = Number.NEGATIVE_INFINITY

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
const withNotice = <R extends { context?: readonly string[] }>(result: R): R => {
  if (!notice) return result
  const said = notice
  notice = undefined
  return { ...result, context: [...(result.context ?? []), said] }
}

// Failed, decided with Dan (2026-10-04, after the review of #634): three tool calls in a row failed
// or refused, nothing succeeding between; the next success clears it.
const FAIL_STREAK = 3
let streak = 0
const failureOf = (r: { deny?: unknown; isError?: boolean; text?: unknown }): string | undefined =>
  r.deny ? String(r.deny) : r.isError ? String(r.text ?? 'it failed') : undefined
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
    lastWritten = Number.NEGATIVE_INFINITY
    streak = 0
    notice = undefined
    toldUnwritten = false
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const now = await $.clock.now()
    progress ??= empty(now)
    const input = e as unknown as Record<string, unknown>
    // A subagent keeps its own list, which is not the session's goal; its work still counts as
    // the session being active, and its failures are its own (lessons review of #634).
    const fromSubagent = Boolean((e as { agentId?: string }).agentId)

    if (e.tool === 'AskUserQuestion' && !fromSubagent) {
      const qs = (input.questions as { question?: string }[] | undefined) ?? []
      progress = { ...progress, waiting: { question: qs[0]?.question ?? 'a question', since: now }, lastActivityAt: now }
      await publish($, now)
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
    const before = progress
    const why = failureOf(result)

    if (fromSubagent || why !== undefined) {
      progress = { ...(fromSubagent ? progress : counted(progress, why)), lastActivityAt: now }
    } else {
      progress = counted(progress, undefined)
      if (e.tool === 'TodoWrite') {
        progress = fromTodos(progress, (input.todos as { content: string; status: StepStatus; activeForm: string }[]) ?? [], now)
      } else if (e.tool === 'TaskCreate') {
        const task = (result.result as { task?: { id?: string; subject?: string } } | undefined)?.task
        // A result with no task id cannot be followed, but the call is still activity.
        progress = task?.id
          ? taskCreated(progress, { id: task.id, subject: task.subject ?? String(input.subject ?? ''), activeForm: input.activeForm as string | undefined }, now)
          : { ...progress, lastActivityAt: now }
      } else if (e.tool === 'TaskUpdate') {
        progress = taskUpdated(progress, input as { taskId: string; status?: StepStatus | 'deleted'; subject?: string; activeForm?: string }, now)
      } else {
        progress = { ...progress, lastActivityAt: now }
      }
    }

    // A change to the list or to failed is written at once; plain activity at most every thirty seconds.
    if (progress.steps !== before.steps || progress.failed !== before.failed || now - lastWritten >= ACTIVITY_WRITE_MS) await publish($, now)
    return withNotice(result)
  })
}
