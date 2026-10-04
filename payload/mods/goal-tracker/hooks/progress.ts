// The goal tracker's rules, apart from the hooks (claude-config#612): one session's task list,
// whichever tool keeps it, and which of Dan's states it is in. Never a bare spinner (Dan's
// progress rule): working, stalled, failed, done, or waiting on him.

export type StepStatus = 'pending' | 'in_progress' | 'completed'
const STEP_STATUSES: readonly string[] = ['pending', 'in_progress', 'completed'] satisfies StepStatus[]
// A status comes from the tool call's input, never trusted: one outside these would break the done
// count (lessons review of #634).
export const isStepStatus = (x: unknown): x is StepStatus => typeof x === 'string' && STEP_STATUSES.includes(x)
export type Step = { id: string; subject: string; activeForm?: string; status: StepStatus }
export type Progress = {
  steps: Step[]
  done: number
  total: number
  /** The step under way, as Claude Code's spinner names it. */
  current: string | null
  startedAt: number
  /** When a step last finished. */
  lastStepAt: number
  /** When anything last happened: a step, or any tool call. */
  lastActivityAt: number
  /**
   * Set while the session waits on Dan: a question (its text), or a permission prompt (what the
   * permission is for, in `question`).
   */
  waiting?: { question: string; since: number; kind?: 'question' | 'permission' }
  failed?: string
  /** The /goal condition, while one is set (Dan, 2026-10-04: the pane's goal text). */
  goal?: string
  /** The session's first request, cut to a few words: the goal text when no /goal is set. */
  request?: string
}
export type State = 'working' | 'stalled' | 'failed' | 'done' | 'waiting'

const STALL_MS = 10 * 60_000
// Failed, decided with Dan (2026-10-04): this many tool calls in a row failed or refused. The one
// number the rule and the pane's sentence both read.
export const FAIL_STREAK = 3

export const empty = (now: number): Progress => ({ steps: [], done: 0, total: 0, current: null, startedAt: now, lastStepAt: now, lastActivityAt: now })

const summed = (p: Progress, steps: Step[], now: number): Progress => {
  const done = steps.filter(s => s.status === 'completed').length
  const under = steps.find(s => s.status === 'in_progress')
  return {
    ...p,
    steps,
    done,
    total: steps.length,
    current: under ? (under.activeForm ?? under.subject) : null,
    // A step finished when it is completed now and was not before, by its id and subject: a count
    // is held still by a finished step dropped in the same write (lessons review of #634).
    lastStepAt: steps.some(s => s.status === 'completed' && !p.steps.some(b => b.status === 'completed' && b.id === s.id && b.subject === s.subject)) ? now : p.lastStepAt,
    lastActivityAt: now,
  }
}

// The to-do list is written whole each time and carries no ids, so a step is known by its text,
// which survives a rewrite that drops or reorders others; a position does not (lessons review of
// #634). A text written twice is told apart by which copy it is. The task tools keep their own ids.
export const fromTodos = (p: Progress, todos: { content: string; status: StepStatus; activeForm: string }[], now: number): Progress => {
  const seen = new Map<string, number>()
  return summed(
    p,
    todos.map(t => {
      const n = (seen.get(t.content) ?? 0) + 1
      seen.set(t.content, n)
      return { id: n === 1 ? `todo:${t.content}` : `todo:${t.content}#${n}`, subject: t.content, activeForm: t.activeForm, status: t.status }
    }),
    now,
  )
}

// The task tools build it one task at a time.
export const taskCreated = (p: Progress, t: { id: string; subject: string; activeForm?: string }, now: number): Progress =>
  summed(p, [...p.steps, { id: t.id, subject: t.subject, activeForm: t.activeForm, status: 'pending' }], now)

export const taskUpdated = (
  p: Progress,
  u: { taskId: string; status?: StepStatus | 'deleted'; subject?: string; activeForm?: string },
  now: number,
): Progress => {
  const status = u.status
  if (status === 'deleted') return summed(p, p.steps.filter(s => s.id !== u.taskId), now)
  return summed(
    p,
    p.steps.map(s =>
      s.id === u.taskId
        ? { ...s, status: status ?? s.status, subject: u.subject ?? s.subject, activeForm: u.activeForm ?? s.activeForm }
        : s,
    ),
    now,
  )
}

export const stateOf = (p: Progress, now: number): State => {
  if (p.waiting) return 'waiting'
  if (p.failed) return 'failed'
  if (p.total > 0 && p.done === p.total) return 'done'
  return now - Math.max(p.lastStepAt, p.lastActivityAt) > STALL_MS ? 'stalled' : 'working'
}
