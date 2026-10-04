import type { EngineInterface, Register } from 'claude-code'
import { assess, isPollLoop, startedJob } from './jobs.ts'

// Background job watcher (claude-config#611). This holds the parts settled by the spec alone:
// every background job is recorded with its process group, traced through the output file it
// writes (never by matching its command text, L1011), into the session registry where the status
// bar will count it; each minute every job is looked at; a poll loop that has only ever repeated
// an error is stopped by itself; and Claude is told, mid turn, about any job gone stuck. What Dan
// sees (the turn end refusal, a kept job on the status bar, the leftover question at the start of
// a session) waits on the design rounds with him.

type Job = { id: string; command: string; outputPath: string; pgid: number | null; startedAt: number }
type Watch = { lastSize: number; lastGrowth: number; told: boolean }

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

const look = async ($: EngineInterface) => {
  const now = await $.clock.now()
  for (const job of [...jobs.values()]) {
    const size = Number((await run($, ['stat', '-f', '%z', job.outputPath]))?.trim())
    // The first look dates what is already there from the job's start: it grew before anyone looked.
    const w = watch.get(job.id) ?? { lastSize: Number.isFinite(size) ? size : 0, lastGrowth: job.startedAt, told: false }
    if (Number.isFinite(size) && size > w.lastSize) {
      w.lastSize = size
      w.lastGrowth = now
      w.told = false
    }
    watch.set(job.id, w)
    const tail = (await run($, ['tail', '-c', '4096', job.outputPath])) ?? ''
    const a = assess({ tail, size: w.lastSize, lastGrowth: w.lastGrowth }, now)
    if (a.state === 'repeating' && isPollLoop(job.command)) {
      // A poll loop that has never once succeeded is stopped by itself (the spec), through Claude
      // Code's own stop for that task id: the traced handle, never a match on its text (L1011).
      await $.tool.call({ tool: 'TaskStop', task_id: job.id })
      jobs.delete(job.id)
      watch.delete(job.id)
      await publish($)
      notices.push(`Background job ${job.id} (${job.command}) was stopped: it is a poll loop that only ever repeated "${a.line}", so it never succeeded.`)
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
      $.clock.every(TICK_MS, () => look($))
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
