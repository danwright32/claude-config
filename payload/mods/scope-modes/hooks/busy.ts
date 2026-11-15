// #2511: the background work an overnight worker started that is still working, read at its Stop.
//
// On 2026-11-08 a worker held a claim its builder subagent was working in a worktree of its own.
// Each turn the worker ended to wait for the builder's report was blocked, three such turns read as
// no progress, and the circuit breaker failed the claim minutes before the builder finished. The
// driver (driver.ts, decideStop) now lets a worker rest while this reading names work, and judges
// it as before when it names none.
//
// A subagent counts while Claude Code lists it as running and the job watcher has not judged it
// quiet past twenty minutes (hung, #759); a job counts while this conversation kept it and the
// watcher has not measured it stalled. Anything that cannot be read (the agent list, or the job
// watcher not loaded or failing, so working cannot be told from hung) counts as no work, logged, so
// the breaker still trips as it did before.
//
// #2897: a Monitor counts while Claude Code lists it as running in the stop's own list of the
// session's work in flight (background_tasks), by its type 'monitor' (the Stop hook's schema in
// 2.1.325 documents 'shell', 'subagent', 'monitor' and 'workflow'). The job watcher keeps no record
// of a Monitor, so that list is the only reading. A finished one is left out of the list or listed
// with another status, and a list that is missing or not a list counts none, logged, as above. A
// Monitor that never ends cannot rest the night away: a rest counts against the night's cap, and
// the claim's active time still runs toward its stuck limit (driver.ts).

import type { EngineInterface } from 'claude-code'
import { busyWords } from './driver.ts'
import { errorText } from './mod-kit/skew.ts'

type JobsNoun = { list: () => Promise<unknown>; agents: () => Promise<unknown> }

// A function declaration, since the engine follows $ past an import only into one; the job
// watcher's noun is called in place each time, as it requires, never held in a variable.
export async function busyNow($: EngineInterface, backgroundTasks?: unknown): Promise<string | null> {
  let subagents = 0
  try {
    const listed: unknown = await $.agent.list()
    if (!Array.isArray(listed)) throw new Error('the agent list is not a list')
    const running = listed.filter(a => (a as { status?: unknown } | null)?.status === 'running').length
    if (running > 0) {
      // The watcher reads the same list, so the running agents it did not judge quiet are working.
      const quiet: unknown = await ($ as unknown as { jobs: JobsNoun }).jobs.agents()
      if (!Array.isArray(quiet)) throw new Error("the job watcher's quiet agents are not a list")
      subagents = Math.max(0, running - quiet.length)
    }
  } catch (err) {
    $.ui.log(`scope-modes: the overnight driver could not tell whether this session's subagents are still working, so it counts none: ${errorText(err, 'scope-modes')}`, { to: 'debug' })
  }
  let kept = 0
  try {
    const list: unknown = await ($ as unknown as { jobs: JobsNoun }).jobs.list()
    if (!Array.isArray(list)) throw new Error("the job watcher's jobs are not a list")
    kept = list.filter(j => {
      const x = (j ?? {}) as { kept?: unknown; stuck?: unknown; owner?: unknown }
      return x.kept === true && x.stuck !== true && x.owner === null
    }).length
  } catch (err) {
    $.ui.log(`scope-modes: the overnight driver could not read this session's kept jobs, so it counts none: ${errorText(err, 'scope-modes')}`, { to: 'debug' })
  }
  const monitors = runningMonitors(backgroundTasks)
  if (monitors === undefined) $.ui.log("scope-modes: the overnight driver could not read the stop's list of work in flight, so it counts no Monitor", { to: 'debug' })
  return busyWords(subagents, kept, monitors ?? 0)
}

/** How many Monitors the stop's background_tasks lists as running (#2897), or undefined when that list is not a list. */
export const runningMonitors = (raw: unknown): number | undefined => {
  if (!Array.isArray(raw)) return undefined
  return raw.filter(t => {
    const e = (typeof t === 'object' && t !== null ? t : {}) as { type?: unknown; status?: unknown }
    return e.type === 'monitor' && e.status === 'running'
  }).length
}
