import type { EngineInterface, Register } from 'claude-code'
import { assess, isErrorLine, isPollLoop, startedJob } from './jobs.ts'

// Background job watcher (claude-config#611). This holds the parts settled by the spec alone:
// every background job is recorded with its process group, traced through the output file it
// writes (never by matching its command text, L1011), into the session registry where the status
// bar will count it; each minute every job is looked at; a poll loop that has only ever repeated
// an error is stopped by itself; and Claude is told, mid turn, about any job gone stuck. What Dan
// sees (the turn end refusal, a kept job on the status bar, the leftover question at the start of
// a session) waits on the design rounds with him.

type Job = { id: string; command: string; outputPath: string; pgid: number | null; startedAt: number }
type Watch = { lastSize: number; lastGrowth: number; told: boolean; toldUnreadable: boolean }

const TICK_MS = 60_000
const jobs = new Map<string, Job>()
const watch = new Map<string, Watch>()
const notices: string[] = []
let ticking = false

const run = async ($: EngineInterface, argv: string[]): Promise<string | undefined> => {
  try {
    const r = await $.process.run(argv, { timeoutMs: 10_000 })
    return r.exitCode === 0 ? r.stdout : undefined
  } catch {
    return undefined
  }
}

const publish = ($: EngineInterface) => $.sessions.setExtra({ key: 'jobs', value: [...jobs.values()] })

// The job's process group, from whoever holds its output file open: the shell running the job.
const traceGroup = async ($: EngineInterface, outputPath: string): Promise<number | null> => {
  const pid = (await run($, ['lsof', '-t', outputPath]))?.split('\n').map(s => Number(s.trim())).find(n => Number.isInteger(n) && n > 0)
  if (pid === undefined) return null
  const pgid = Number((await run($, ['ps', '-o', 'pgid=', '-p', String(pid)]))?.trim())
  return Number.isInteger(pgid) && pgid > 0 ? pgid : null
}

// Whether the job's process group has ended: macOS ps exits 1 and prints nothing at all for a group
// with no processes left (measured 2026-10-04). Anything else, an error or no traced group, is
// unknown, never ended, so a job is only ever dropped on that evidence.
const hasEnded = async ($: EngineInterface, pgid: number | null): Promise<boolean> => {
  if (pgid === null) return false
  try {
    const r = await $.process.run(['ps', '-g', String(pgid), '-o', 'pid='], { timeoutMs: 10_000 })
    return r.exitCode === 1 && !r.stdout.trim() && !r.stderr.trim()
  } catch {
    return false
  }
}

// Claude Code's own stop for that task id: the traced handle, never a match on its text (L1011).
// Why it did not stop, or undefined when it did; a refusal and a throw are both said (L12).
const stop = async ($: EngineInterface, id: string): Promise<string | undefined> => {
  try {
    const r = await $.tool.call({ tool: 'TaskStop', task_id: id } as never)
    if (r.deny) return String(r.deny)
    if (r.isError) return String(r.text ?? 'it reported an error')
    return undefined
  } catch (err) {
    return err instanceof Error ? err.message : String(err)
  }
}

const forget = async ($: EngineInterface, id: string) => {
  jobs.delete(id)
  watch.delete(id)
  await publish($)
}

// One look at every job. A look that fails part way is said to Claude once, never lost in the
// timer (lessons review of #634).
let toldLookFailed = false
const lookSafely = async ($: EngineInterface) => {
  try {
    await look($)
    toldLookFailed = false
  } catch (err) {
    if (!toldLookFailed) {
      toldLookFailed = true
      notices.push(`The background job watcher could not check its jobs: ${err instanceof Error ? err.message : String(err)}. Jobs may be stuck without a word from it.`)
    }
  }
}

const look = async ($: EngineInterface) => {
  const now = await $.clock.now()
  for (const job of [...jobs.values()]) {
    // A job that finished is Claude Code's to report; the watcher just stops watching it.
    if (await hasEnded($, job.pgid)) {
      await forget($, job.id)
      continue
    }
    const statOut = await run($, ['stat', '-f', '%z', job.outputPath])
    const size = statOut === undefined ? NaN : Number(statOut.trim())
    const tail = await run($, ['tail', '-c', '4096', job.outputPath])
    // The first look dates what is already there from the job's start: it grew before anyone looked.
    const w = watch.get(job.id) ?? { lastSize: Number.isFinite(size) ? size : 0, lastGrowth: job.startedAt, told: false, toldUnreadable: false }
    watch.set(job.id, w)
    // An output file that cannot be read says nothing about the job, so it is never judged silent:
    // Claude is told it could not be read, once, until it can be again.
    if (!Number.isFinite(size) || tail === undefined) {
      if (!w.toldUnreadable) {
        w.toldUnreadable = true
        notices.push(`Background job ${job.id} (${job.command}): could not read its output file ${job.outputPath}, so whether it is stuck is unknown.`)
      }
      continue
    }
    w.toldUnreadable = false
    // Any change counts, a shrink too: a truncated or rotated file is still the job writing.
    if (size !== w.lastSize) {
      w.lastSize = size
      w.lastGrowth = now
      w.told = false
    }
    const a = assess({ tail, size: w.lastSize, lastGrowth: w.lastGrowth }, now)
    if (a.state === 'repeating' && isPollLoop(job.command) && isErrorLine(a.line)) {
      // A poll loop that only ever repeated an error never succeeded, and is stopped by itself.
      const why = await stop($, job.id)
      if (why === undefined) {
        await forget($, job.id)
        notices.push(`Background job ${job.id} (${job.command}) was stopped: it is a poll loop that only ever repeated "${a.line}", so it never succeeded.`)
      } else if (!w.told) {
        w.told = true
        notices.push(`Background job ${job.id} (${job.command}) is a poll loop that only ever repeated "${a.line}", but it could not be stopped: ${why}. Stop it with TaskStop.`)
      }
    } else if (a.state !== 'running' && !w.told) {
      w.told = true
      const what = a.state === 'repeating' ? `keeps repeating "${a.line}"` : `has had no new output for ${Math.round(a.forMs / 60_000)} minutes`
      notices.push(`Background job ${job.id} (${job.command}) ${what}. Stop it with TaskStop, or keep it if that is expected.`)
    }
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    if (!ticking) {
      ticking = true
      $.clock.every(TICK_MS, () => lookSafely($))
    }
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const input = e as unknown as Record<string, unknown>
    const result = await next(e)
    if (e.tool === 'Bash' && input.run_in_background && !result.deny && !result.isError) {
      const started = startedJob(String(result.text ?? ''))
      if (started) {
        jobs.set(started.id, {
          id: started.id,
          command: String(input.command ?? ''),
          outputPath: started.outputPath,
          pgid: await traceGroup($, started.outputPath),
          startedAt: await $.clock.now(),
        })
        await publish($)
      }
    }
    // What Claude should know about its jobs rides on the next tool result it reads.
    if (notices.length && !result.deny && !result.isError) {
      const said = notices.splice(0)
      return { ...result, context: [...(result.context ?? []), ...said] }
    }
    return result
  })
}
