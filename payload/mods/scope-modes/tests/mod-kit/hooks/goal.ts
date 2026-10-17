// The goal a session has set with Claude Code's own /goal, read from its transcript: the one reader
// of it (#1252, moved here from scope-modes' bedtime.ts, where #1242 wrote it), so sleep mode and the
// goal tracker cannot read one transcript two ways (L83).
//
// Claude Code keeps no goal a mod can ask for, but writes it into the session's transcript as a
// goal_status attachment: `sentinel: true, met: false` with the condition when /goal sets it (and
// again after each compaction), `sentinel: true, met: true` when the goal ends, and, each time it
// judges the condition, a record without the sentinel whose `met: true` is the goal cleared as met.
// Measured on every transcript on this Mac on 2026-10-16 (Claude Code 2.1.272 to 2.1.300): 95 set
// and 45 ended sentinels, every /goal with a condition preceded by a set one. 12 of the ended ones
// came with /goal clear and 33 without it (a goal Dan paused in his own words), and after every one
// of the 45 the condition was never judged again until a goal was set anew: the goal had stopped.
// So the newest such record says whether a goal is set now, and its condition what it is. The
// command's own "Goal set:" line is not that record: it stays the last word on a goal that ended
// without /goal clear (31 of 70 transcripts measured), as do the /goal command's own arguments.

/** What the shell finds a transcript's goal records by: every one carries it, written this way. */
export const GOAL_MARK = '"type":"goal_status"'

export type GoalReading = { state: 'set'; condition: string } | { state: 'none' }

/**
 * The goal set now, from the transcript lines GOAL_MARK found, oldest first. Only a whole record of
 * Claude Code's own counts: the mark inside text a tool printed, or a line cut short, is not one.
 */
export const goalIn = (lines: string): GoalReading => {
  let last: { met: boolean; condition: string } | null = null
  for (const raw of lines.split('\n')) {
    if (!raw.trim()) continue
    let o: unknown
    try {
      o = JSON.parse(raw)
    } catch {
      continue
    }
    const r = o as { type?: unknown; attachment?: { type?: unknown; met?: unknown; condition?: unknown } } | null
    const a = r && typeof r === 'object' && r.type === 'attachment' ? r.attachment : undefined
    if (!a || a.type !== 'goal_status') continue
    // A record this reader cannot read says no goal rather than one nobody can see the words of.
    last = typeof a.met === 'boolean' && typeof a.condition === 'string' ? { met: a.met, condition: a.condition.trim() } : { met: true, condition: '' }
  }
  return last && !last.met && last.condition ? { state: 'set', condition: last.condition } : { state: 'none' }
}

// What the shell runs to find a transcript's goal records: the newest 50 lines holding the mark,
// so a goal judged a thousand times is still a small answer. grep exits 1 when there are none. The
// mark and the file are its arguments, never part of its text.
const GOAL_READ = 'set -o pipefail; grep -F -e "$1" -- "$2" | tail -n 50'

export type GoalRun = (argv: string[]) => Promise<{ exitCode: number; stdout: string; stderr: string }>
/** The goal a session's transcript says is set now, or why it could not be read (never read as none). */
export type GoalAt = GoalReading | { state: 'unreadable'; why: string }

/** The goal set now in the transcript at this path, its records found by the shell `run` starts. */
export const goalAt = async (transcript: string, run: GoalRun): Promise<GoalAt> => {
  if (!transcript) return { state: 'unreadable', why: 'no transcript was given' }
  let r: Awaited<ReturnType<GoalRun>>
  try {
    r = await run(['bash', '-c', GOAL_READ, 'goal', GOAL_MARK, transcript])
  } catch (err) {
    return { state: 'unreadable', why: err instanceof Error ? err.message : String(err) }
  }
  if (r.exitCode === 1 && !r.stderr.trim()) return { state: 'none' }
  if (r.exitCode !== 0) return { state: 'unreadable', why: r.stderr.trim() || `grep exited ${r.exitCode}` }
  return goalIn(r.stdout)
}
