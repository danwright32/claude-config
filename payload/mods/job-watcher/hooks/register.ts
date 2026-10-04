import type { EngineInterface, Register } from 'claude-code'
import { assess, isErrorLine, isPollLoop, startedJob } from './jobs.ts'

// Background job watcher (claude-config#611). Every background job is recorded with its process
// group, traced through the output file it writes (never by matching its command text, L1011), into
// the session registry where the status bar counts it; each minute every job is looked at; a poll
// loop that has only ever repeated an error is stopped by itself; and Claude is told, mid turn, about
// any job gone stuck. Claude keeps a job on purpose, with a reason, through the keep_job tool, and a
// kept job is published for the status bar's amber band. Leftover jobs from closed sessions are
// judged at session start without asking Dan (see leftovers below).

// kept: Claude kept the job on purpose, with a reason (Dan, 2026-10-04). The status bar (#610) shows
// a kept job in amber in the band above the prompt as "<name> kept <run time>", the run time from
// startedAt. quiet: kept as quiet by design, so it is never reported for going silent.
type Kept = { name: string; reason: string; quiet: boolean; at: number }
type Job = { id: string; command: string; outputPath: string; pgid: number | null; startedAt: number; kept?: Kept }
type Watch = { lastSize: number; lastGrowth: number; told: boolean; toldUnreadable: boolean; toldUntraced: boolean; toldLookFailed: boolean }

const TICK_MS = 60_000
const KEEP_TOOL = 'keep_job'
const KEEP_CALL = `mcp__job-watcher__${KEEP_TOOL}`
const KEEP_SPEC = {
  name: KEEP_TOOL,
  description:
    'Keep a background job running on purpose, with the reason it must stay up (a dev server Dan is using, a watcher a later step needs). ' +
    'A job that is not kept must be stopped with TaskStop before the turn ends. A kept job shows on the status bar with its run time. ' +
    'Set quiet when the job is expected to print nothing for long stretches, so it is not reported for going silent.',
  inputSchema: {
    type: 'object',
    properties: {
      task_id: { type: 'string', description: 'The background job id the Bash call reported.' },
      name: { type: 'string', description: 'A few words naming the job as Dan reads it on the status bar, like "dev server".' },
      reason: { type: 'string', description: 'Why it must keep running.' },
      quiet: { type: 'boolean', description: 'True when it is quiet by design and should not be reported for printing nothing.' },
    },
    required: ['task_id', 'name', 'reason'],
  },
}
// Everything below belongs to one session, cleared at each session start (lessons review of #634).
const jobs = new Map<string, Job>()
const watch = new Map<string, Watch>()
const notices: string[] = []
let toldUnpublished = false
// One timer, started again by each session start so it looks with that session's engine interface.
let tick: { cancel: () => void } | undefined
const watchOf = (job: Job): Watch => {
  let w = watch.get(job.id)
  if (!w) {
    w = { lastSize: NaN, lastGrowth: job.startedAt, told: false, toldUnreadable: false, toldUntraced: false, toldLookFailed: false }
    watch.set(job.id, w)
  }
  return w
}

const run = async ($: EngineInterface, argv: string[]): Promise<string | undefined> => {
  try {
    const r = await $.process.run(argv, { timeoutMs: 10_000 })
    return r.exitCode === 0 ? r.stdout : undefined
  } catch {
    return undefined
  }
}

const publish = ($: EngineInterface) => $.sessions.setExtra({ key: 'jobs', value: [...jobs.values()] })

// A registry write that fails never breaks what it rides on; Claude is told once, until one lands.
const publishSafely = async ($: EngineInterface) => {
  try {
    await publish($)
    toldUnpublished = false
  } catch (err) {
    if (!toldUnpublished) {
      toldUnpublished = true
      notices.push(`The background job watcher could not record this session's jobs: ${err instanceof Error ? err.message : String(err)}. The status bar and later sessions will not see them.`)
    }
  }
}

// Who holds a job's output file open: the shell running the job, while it runs. lsof exits 1 and
// prints nothing at all when nobody does; any other failure says nothing either way.
type Holder = { pid: number } | 'nobody' | 'unknown'
const holderOf = async ($: EngineInterface, outputPath: string): Promise<Holder> => {
  try {
    const r = await $.process.run(['lsof', '-t', outputPath], { timeoutMs: 10_000 })
    if (r.exitCode === 1 && !r.stdout.trim() && !r.stderr.trim()) return 'nobody'
    if (r.exitCode !== 0) return 'unknown'
    const pid = r.stdout.split('\n').map(s => Number(s.trim())).find(n => Number.isInteger(n) && n > 0)
    return pid === undefined ? 'unknown' : { pid }
  } catch {
    return 'unknown'
  }
}

// The job's process group, from whoever holds its output file open.
const traceGroup = async ($: EngineInterface, outputPath: string): Promise<number | null> => {
  const h = await holderOf($, outputPath)
  if (typeof h !== 'object') return null
  const pgid = Number((await run($, ['ps', '-o', 'pgid=', '-p', String(h.pid)]))?.trim())
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
  await publishSafely($)
}

// One look at every job, each in its own failure boundary (L73): a job whose look throws is said to
// Claude once, and the jobs after it are still looked at (lessons review of #634).
const lookSafely = async ($: EngineInterface) => {
  let now: number
  try {
    now = await $.clock.now()
  } catch (err) {
    notices.push(`The background job watcher could not check its jobs: ${err instanceof Error ? err.message : String(err)}. Jobs may be stuck without a word from it.`)
    return
  }
  for (const job of [...jobs.values()]) {
    const w = watchOf(job)
    try {
      await look($, job, w, now)
      w.toldLookFailed = false
    } catch (err) {
      if (!w.toldLookFailed) {
        w.toldLookFailed = true
        notices.push(`The background job watcher could not check its jobs: background job ${job.id} (${job.command}): ${err instanceof Error ? err.message : String(err)}. It may be stuck without a word from the watcher.`)
      }
    }
  }
}

// Whether a job has ended. A traced job by its process group; an untraced one is traced again, and
// is ended once nothing holds its output file open. Unknown is never ended: Claude is told once
// that whether it has ended is unknown, never left silent (lessons review of #634).
const ended = async ($: EngineInterface, job: Job, w: Watch): Promise<boolean> => {
  if (job.pgid !== null) return hasEnded($, job.pgid)
  const h = await holderOf($, job.outputPath)
  if (h === 'nobody') return true
  if (typeof h === 'object') {
    const pgid = await traceGroup($, job.outputPath)
    if (pgid !== null) {
      jobs.set(job.id, { ...job, pgid })
      await publishSafely($)
      return false
    }
  }
  if (!w.toldUntraced) {
    w.toldUntraced = true
    notices.push(`Background job ${job.id} (${job.command}) could not be traced to its process, so whether it has ended is unknown. Stop it with TaskStop if it is no longer needed.`)
  }
  return false
}

const look = async ($: EngineInterface, job: Job, w: Watch, now: number) => {
  // A job that finished is Claude Code's to report; the watcher just stops watching it.
  if (await ended($, job, w)) {
    await forget($, job.id)
    return
  }
  const statOut = await run($, ['stat', '-f', '%z', job.outputPath])
  const size = statOut === undefined ? NaN : Number(statOut.trim())
  const tail = await run($, ['tail', '-c', '4096', job.outputPath])
  // The first look dates what is already there from the job's start: it grew before anyone looked.
  if (Number.isNaN(w.lastSize) && Number.isFinite(size)) w.lastSize = size
  // An output file that cannot be read says nothing about the job, so it is never judged silent:
  // Claude is told it could not be read, once, until it can be again.
  if (!Number.isFinite(size) || tail === undefined) {
    if (!w.toldUnreadable) {
      w.toldUnreadable = true
      notices.push(`Background job ${job.id} (${job.command}): could not read its output file ${job.outputPath}, so whether it is stuck is unknown.`)
    }
    return
  }
  w.toldUnreadable = false
  // Any change counts, a shrink too: a truncated or rotated file is still the job writing.
  if (size !== w.lastSize) {
    w.lastSize = size
    w.lastGrowth = now
    w.told = false
  }
  const a = assess({ tail, size: w.lastSize, lastGrowth: w.lastGrowth, quietByDesign: job.kept?.quiet === true }, now)
  if (a.state === 'repeating' && isPollLoop(job.command) && isErrorLine(a.line)) {
    // A poll loop that only ever repeated an error never succeeded, and is stopped by itself.
    const why = await stop($, job.id)
    if (why === undefined) {
      // Said before the registry write, so a write that fails cannot lose it (lessons review of #634).
      notices.push(`Background job ${job.id} (${job.command}) was stopped: it is a poll loop that only ever repeated "${a.line}", so it never succeeded.`)
      await forget($, job.id)
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

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    jobs.clear()
    watch.clear()
    notices.length = 0
    toldUnpublished = false
    tick?.cancel()
    tick = $.clock.every(TICK_MS, () => lookSafely($))
    await $.tool.register(KEEP_SPEC)
    return next(e)
  })

  // Claude keeps a job from inside a turn. A refusal names what is wrong and the jobs it could mean.
  on('tool.call', { tool: KEEP_CALL }, async ($, e) => {
    const input = e as unknown as Record<string, unknown>
    const id = String(input.task_id ?? '').trim()
    const name = String(input.name ?? '').trim()
    const reason = String(input.reason ?? '').trim()
    const job = jobs.get(id)
    if (!job) {
      const running = [...jobs.keys()]
      return { deny: `No running background job ${id || '(no task_id given)'} is known to the watcher. ${running.length ? `Running: ${running.join(', ')}.` : 'None is running.'}` }
    }
    if (!name) return { deny: `Give the job a name: a few words Dan reads on the status bar, like "dev server".` }
    if (!reason) return { deny: `Give a reason why ${id} must keep running.` }
    const kept: Kept = { name, reason, quiet: input.quiet === true, at: await $.clock.now() }
    jobs.set(id, { ...job, kept })
    await publishSafely($)
    const said = notices.splice(0)
    const quietly = kept.quiet ? ' It is quiet by design, so it will not be reported for printing nothing.' : ''
    return { result: `Kept ${id} (${name}): ${reason}. It shows on the status bar as kept, with its run time.${quietly}`, ...(said.length ? { context: said } : {}) }
  })

  on('tool.call', async ($, e, next) => {
    if (e.tool === KEEP_CALL) return next(e)
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
        await publishSafely($)
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
