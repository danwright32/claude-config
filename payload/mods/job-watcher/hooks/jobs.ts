// The background job watcher's rules, apart from the hooks (claude-config#611).

const STARTED = /background with ID: (\S+?)\.?\s+Output is being written to: (\S+?)\.?(?:\s|$)/
// The same line this many times running, at the end of the output, is a job repeating an error.
const REPEAT_MIN = 20
// No new output for this long is a job gone silent (the spec's ten minutes).
const SILENT_MS = 10 * 60_000

export const startedJob = (resultText: string): { id: string; outputPath: string } | undefined => {
  const m = STARTED.exec(resultText)
  return m ? { id: m[1] as string, outputPath: m[2] as string } : undefined
}

// A line that reports a failure. A waiting loop is stopped by itself only when the line it keeps
// repeating is one of these (decided with Dan, 2026-10-04): a loop repeating "waiting" may just be
// patient, and is only reported.
const ERROR_LINE = /\b(error|errors|fail(s|ed|ure)?|fatal|exception|traceback|refused|denied|not found|no matches|no such|cannot|can't|couldn't|unable|unreachable|invalid|timed out)\b|^[a-z]+: \(\d+\)/i
export const isErrorLine = (line: string): boolean => ERROR_LINE.test(line)

// A loop that waits for something by trying again after a sleep: the 2026-09-22 loop was one.
export const isPollLoop = (command: string): boolean => /\b(until|while)\b[\s\S]*\bdo\b[\s\S]*\bsleep\b/.test(command)

export type Sample = {
  /** The end of the job's output file. */
  tail: string
  size: number
  /** When the output file last grew. */
  lastGrowth: number
  /** Kept by Claude with a reason and marked as quiet by design: never silent. */
  quietByDesign?: boolean
}
export type Assessment = { state: 'running' } | { state: 'repeating'; line: string } | { state: 'silent'; forMs: number }

export const assess = (s: Sample, now: number): Assessment => {
  const lines = s.tail.split('\n').map(l => l.trim()).filter(Boolean)
  const last = lines[lines.length - 1]
  if (last !== undefined && lines.length >= REPEAT_MIN && lines.slice(-REPEAT_MIN).every(l => l === last)) {
    return { state: 'repeating', line: last }
  }
  if (!s.quietByDesign && now - s.lastGrowth > SILENT_MS) return { state: 'silent', forMs: now - s.lastGrowth }
  return { state: 'running' }
}

// Leftover jobs from closed sessions (Dan, 2026-10-04): a model judges each, and Dan sees one dim
// line naming what was stopped and what was left.

export type Verdict = { stop: boolean; name: string }
const NAME_MAX = 60

// Each balanced {...} span of a reply, in order, braces inside JSON strings not counted.
const objectsIn = function* (text: string): Generator<string> {
  for (let start = text.indexOf('{'); start !== -1; start = text.indexOf('{', start + 1)) {
    let depth = 0
    let inString = false
    for (let i = start; i < text.length; i++) {
      const c = text[i]
      if (inString) {
        if (c === '\\') i++
        else if (c === '"') inString = false
      } else if (c === '"') inString = true
      else if (c === '{') depth++
      else if (c === '}' && --depth === 0) {
        yield text.slice(start, i + 1)
        break
      }
    }
  }
}

// A model's verdict: the first JSON object in the reply with a boolean stop and a name. Anything
// else is no verdict, so the next model is asked rather than a guess made from prose. A second
// object or a stray brace after it never hides it (lessons review of #634).
export const parseVerdict = (text: string): Verdict | undefined => {
  for (const candidate of objectsIn(text)) {
    try {
      const v = JSON.parse(candidate) as { stop?: unknown; name?: unknown }
      const name = typeof v.name === 'string' ? v.name.trim().replace(/\s+/g, ' ') : ''
      if (typeof v.stop !== 'boolean' || !name) continue
      return { stop: v.stop, name: name.length > NAME_MAX ? `${name.slice(0, NAME_MAX - 3)}...` : name }
    } catch {
      // Not JSON: the next candidate is tried.
    }
  }
  return undefined
}

// How long a job has run, as the status bar writes it: "14m", "2h 14m".
export const runFor = (ms: number): string => {
  const mins = Math.max(0, Math.floor(ms / 60_000))
  return mins < 60 ? `${mins}m` : `${Math.floor(mins / 60)}h ${mins % 60}m`
}

export type Outcome = { kind: 'stopped' | 'left' | 'unjudged' | 'stopFailed'; name: string; why?: string; session: string }

const plural = (n: number, one: string, many: string) => (n === 1 ? one : many)

// The one line Dan sees, or undefined when there is nothing to say. Each kind of outcome has words
// of its own (L11): a job left on a verdict, a job left because nothing could judge it, and a stop
// that failed are three different things. The settled line is "Stopped 1 leftover job from a
// closed session (...); left 1 running (...)"; the other three are the bare fact (Dan, 2026-10-04).
export const leftoverLine = (outcomes: Outcome[], unreadable: string[]): string | undefined => {
  const sessions = new Set(outcomes.map(o => o.session)).size
  const parts: string[] = []
  const lead = (n: number) => `${n} leftover ${plural(n, 'job', 'jobs')} from ${plural(sessions, 'a closed session', 'closed sessions')}`
  const jobs = (n: number) => `${n} leftover ${plural(n, 'job', 'jobs')}`
  const add = (kind: Outcome['kind'], first: (n: number, names: string) => string, later: (n: number, names: string) => string) => {
    const of = outcomes.filter(o => o.kind === kind)
    if (!of.length) return
    const names = of.map(o => o.name).join(', ')
    parts.push(parts.length ? later(of.length, names) : first(of.length, names))
  }
  add('stopped', (n, x) => `Stopped ${lead(n)} (${x})`, (n, x) => `stopped ${n} (${x})`)
  add('left', (n, x) => `Left ${lead(n)} running (${x})`, (n, x) => `left ${n} running (${x})`)
  const notJudged = (n: number, x: string) => `${jobs(n)} not judged, left running (${x})`
  add('unjudged', notJudged, notJudged)
  const notStopped = (n: number, x: string) => `${jobs(n)} could not be stopped (${x})`
  add('stopFailed', notStopped, notStopped)
  if (unreadable.length) parts.push(`${parts.length ? 's' : 'S'}ession records unreadable; leftover jobs not checked`)
  return parts.length ? `${parts.join('; ')}.` : undefined
}
