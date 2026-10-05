// The background job watcher's rules, apart from the hooks (claude-config#611).

// A job started in the background names itself and its output file ("running in background with ID:
// X. Output is being written to: Y."), and so does a foreground command Claude Code moved there at its
// timeout ("Command did not complete within its 120s timeout and was moved to the background (ID: X).
// Output is being written to: Y.", seen in a session on 2026-10-04; #706). A command's own output can
// quote either text (a cat of a test file, a grep of this mod), so a start is read only where it is
// Claude Code's own: a call that asked for the background, or a result that opens with those words.
const STARTED = /background with ID: (\S+?)\.?\s+Output is being written to: (\S+?)\.?(?:\s|$)/
const MOVED = /^Command did not complete within its \S+ timeout and was moved to the background \(ID: ([^\s)]+)\)\.?\s+Output is being written to: (\S+?)\.?(?:\s|$)/
// The same lines this many times running, at the end of the output, are a job repeating itself.
const REPEAT_MIN = 20
// A pass of up to this many lines, repeated: a loop printing its error and then "retrying" on every
// pass never repeats one line, and is as stuck as one that does (#706).
const CYCLE_MAX = 4
// No new output for this long is a job gone silent (the spec's ten minutes).
const SILENT_MS = 10 * 60_000

export const startedJob = (resultText: string, call: { inBackground: boolean }): { id: string; outputPath: string } | undefined => {
  const m = call.inBackground ? STARTED.exec(resultText) : MOVED.exec(resultText.trimStart())
  return m ? { id: m[1] as string, outputPath: m[2] as string } : undefined
}

// The jobs a notice from Claude Code reports on, by id: "<task-id>X</task-id>" (seen in a session on
// 2026-10-04). Only ever a prompt to look again; the watcher drops a job on its own evidence.
export const notifiedTasks = (text: string): string[] => [...text.matchAll(/<task-id>([^<\s]+)<\/task-id>/g)].map(m => m[1] as string)

// A line that reports a failure. A waiting loop is stopped by itself only when the line it keeps
// repeating is one of these (decided with Dan, 2026-10-04): a loop repeating "waiting" may just be
// patient, and is only reported.
const ERROR_LINE = /\b(error|errors|fail(s|ed|ure)?|fatal|exception|traceback|refused|denied|not found|no matches|no such|cannot|can't|couldn't|unable|unreachable|invalid|timed out)\b|^[a-z]+: \(\d+\)/i
// A count of zero or a negation reports no failure ("0 failed, 3 pending", "no errors yet", "built
// without errors", "errors: 0"), so those phrases are taken out before the line is read; a real
// failure beside one still reads as an error (lessons review of #634).
const NO_FAILURE = /\b0\s+(errors?|fail(s|ed|ures?)?)\b|\b(no|without|zero)\s+(errors?|failures?)\b|\b(errors?|failures?|failed)\s*[:=]\s*0\b/gi
export const isErrorLine = (line: string): boolean => ERROR_LINE.test(line.replace(NO_FAILURE, ' '))

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
/**
 * repeating: `lines` is the pass it keeps printing, in the order it last ran; `line` names it, its
 * first error line when it has one (what decides a poll loop's stop), else its last line.
 */
export type Assessment = { state: 'running' } | { state: 'repeating'; line: string; lines: string[] } | { state: 'silent'; forMs: number }

// The shortest pass the end of the output is made of, over its last REPEAT_MIN lines; none when no
// pass of up to CYCLE_MAX lines fits.
const repeatedPass = (lines: string[]): string[] | undefined => {
  if (lines.length < REPEAT_MIN) return undefined
  const end = lines.slice(-REPEAT_MIN)
  for (let n = 1; n <= CYCLE_MAX; n++) if (end.every((l, i) => i < n || l === end[i - n])) return end.slice(-n)
  return undefined
}

export const assess = (s: Sample, now: number): Assessment => {
  const pass = repeatedPass(s.tail.split('\n').map(l => l.trim()).filter(Boolean))
  if (pass) return { state: 'repeating', line: pass.find(isErrorLine) ?? (pass[pass.length - 1] as string), lines: pass }
  if (!s.quietByDesign && now - s.lastGrowth > SILENT_MS) return { state: 'silent', forMs: now - s.lastGrowth }
  return { state: 'running' }
}

// What a repeating job keeps printing, as a notice quotes it: one line, or a pass's lines in turn.
export const repeated = (a: { lines: string[] }): string => a.lines.map(shortLine).join('" then "')

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

// A job's command as one short line: what names it in every notice Claude reads, a leftover Dan's
// line could not name from a verdict, and the status bar's label for a job nobody kept. The whole
// command never rides on a tool result (lessons review of #634).
// A repeated output line is cut the same way, longer, since it is the evidence a notice names.
const cut = (text: string, max: number): string => {
  const line = text.trim().replace(/\s+/g, ' ')
  return line.length > max ? `${line.slice(0, max - 3)}...` : line
}
export const shortCommand = (command: string): string => cut(command, 40)
export const shortLine = (line: string): string => cut(line, 120)

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
