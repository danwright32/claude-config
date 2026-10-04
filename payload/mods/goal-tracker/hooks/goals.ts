import { FAIL_STREAK, stateOf, type Progress, type State } from './progress.ts'

// The /goals pane's rows, apart from the drawing (claude-config#612, docs/mods-design.md "Goals
// pane"): every open session on this Mac, two lines each. Project and goal on top; beneath, the
// state word and one dim sentence: steps, elapsed time and one detail (the question, the failure,
// how long quiet, or the step under way). Ordered waiting on you, failed, stalled, working, done.

export type Row = {
  sessionId: string
  project: string
  /** The /goal condition, else the first request; undefined when neither is known yet. */
  goal: string | undefined
  /** The state word as Dan reads it. */
  state: StateWord
  /** What follows the state word on the second line, starting with its comma. */
  sentence: string
}
export type StateWord = 'waiting on you' | 'failed' | 'stalled' | 'working' | 'done'

const WORDS: Record<State, StateWord> = { waiting: 'waiting on you', failed: 'failed', stalled: 'stalled', working: 'working', done: 'done' }
// The settled order (design round): what needs Dan first, what is finished last.
const ORDER: StateWord[] = ['waiting on you', 'failed', 'stalled', 'working', 'done']
const GOAL_MAX = 80

const cut = (text: string, max: number): string => {
  const line = text.trim().replace(/\s+/g, ' ')
  return line.length > max ? `${line.slice(0, max - 3)}...` : line
}

// How long, as the job watcher and the status bar write it: "14m", "1h 12m".
export const duration = (ms: number): string => {
  const mins = Math.max(0, Math.floor(ms / 60_000))
  return mins < 60 ? `${mins}m` : `${Math.floor(mins / 60)}h ${mins % 60}m`
}

export const baseName = (path: string): string => path.replace(/\/+$/, '').split('/').pop() || path

export const projectOf = (r: { repoRoot: string | null; cwd: string }): string => baseName(r.repoRoot ?? r.cwd)

// The session's first request cut to a few words (Dan, 2026-10-04: no model call).
const FIRST_WORDS = 6
export const firstWords = (text: string): string => {
  const words = text.trim().split(/\s+/).filter(Boolean)
  return words.length > FIRST_WORDS ? `${words.slice(0, FIRST_WORDS).join(' ')}...` : words.join(' ')
}

// What a permission prompt is for, as the notification body and the pane's detail say it.
export const permissionFor = (tool: string, input: unknown): string => {
  const i = (input && typeof input === 'object' ? input : {}) as Record<string, unknown>
  if (typeof i.description === 'string' && i.description.trim()) return cut(i.description, 120)
  if (typeof i.command === 'string' && i.command.trim()) return cut(`${tool}: ${i.command}`, 120)
  const file = [i.file_path, i.notebook_path, i.path].find((x): x is string => typeof x === 'string' && x.trim() !== '')
  if (file) return cut(`${tool} ${baseName(file)}`, 120)
  return cut(tool, 120)
}

// A record another session wrote is read, never trusted: one not shaped as progress is left out.
const isProgress = (x: unknown): x is Progress => {
  const p = x as Partial<Progress> | null
  return !!p && typeof p === 'object' && typeof p.done === 'number' && typeof p.total === 'number' && typeof p.startedAt === 'number' && typeof p.lastStepAt === 'number' && typeof p.lastActivityAt === 'number'
}

const detailOf = (p: Progress, state: State, now: number): string | undefined => {
  if (state === 'waiting' && p.waiting) return p.waiting.kind === 'permission' ? `needs a permission: ${p.waiting.question}` : `"${p.waiting.question}"`
  if (state === 'failed') return `${p.failed} (${FAIL_STREAK} failed calls in a row)`
  if (state === 'stalled') return `nothing for ${duration(now - Math.max(p.lastStepAt, p.lastActivityAt))}`
  if (state === 'working') return p.current ?? undefined
  return undefined
}

type Listed = { sessionId: string; cwd: string; repoRoot: string | null; extra: Record<string, unknown> }

export const rowsOf = (records: Listed[], now: number): Row[] => {
  const rows: (Row & { startedAt: number })[] = []
  for (const r of records) {
    const p = r.extra?.progress
    if (!isProgress(p)) continue
    const state = stateOf(p, now)
    const steps = p.total > 0 ? `, ${p.done} of ${p.total} steps` : ''
    const detail = detailOf(p, state, now)
    const goal = p.goal ?? p.request
    rows.push({
      sessionId: r.sessionId,
      project: projectOf(r),
      goal: goal ? cut(goal, GOAL_MAX) : undefined,
      state: WORDS[state],
      sentence: `${steps}, ${duration(now - p.startedAt)}${detail ? `. ${detail}` : ''}`,
      startedAt: p.startedAt,
    })
  }
  rows.sort((a, b) => ORDER.indexOf(a.state) - ORDER.indexOf(b.state) || a.startedAt - b.startedAt)
  return rows.map(({ startedAt: _s, ...row }) => row)
}
