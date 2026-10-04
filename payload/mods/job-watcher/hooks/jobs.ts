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
