import type { GoalBoxPicker } from '../types/index.d.ts'

// What counts as Dan asking for something, beyond a message he types (claude-config#3843). Pure, so
// every rule is tested without a session.
//
// On 2026-11-27 a session finished a monthly sync and showed the box, then Dan picked a fix in one
// picker and three follow ups in the end of turn review's picker. All four finished with no box:
// the box was once per message he typed, and a picker answer is no message. His answer on the
// issue, the same day: an answer he gives in a picker is a new request only when the session then
// does work. An answer that only confirms a step changes nothing by itself and earns no box. No list
// of picker kinds: any picker of the main conversation he answered, followed by work.
//
// "Work" is not a list kept here. The end of turn review hooks (session-reflection.sh,
// feature-issue-review.sh) already decide whether a turn changed something, by hooks/turn-worked.py,
// whose is_mutating reads a tool's name: an edit, a write, a command, an agent, or a connected tool
// that acts and does not only read. The mod asks that function, from that file, by running WORK_TEST
// below. A second list of tools here would drift from that one (L370), and
// tests/test-goal-box-work-test.sh holds the two together: the command against the real file, and
// the review hooks still naming that file. Beyond the test, the call must be the main conversation's
// and must have run: one a guard refused changed nothing. The box's own tool never counts.

/** The Python that asks the review's own test about one tool name: the file by path, then the name. */
export const WORK_TEST = `
import importlib.util, sys
spec = importlib.util.spec_from_file_location('turn_worked', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print('yes' if module.is_mutating(sys.argv[2]) else 'no')
`

/** How long one run of the test may take: it imports one file and prints a word. */
export const WORK_TEST_MS = 10_000

/**
 * The command: the review's test where the sync installs it, asked about one tool. -B because Python
 * importing a file by path otherwise leaves a compiled copy in a __pycache__ folder beside it, and a
 * question should write nothing into the hooks folder (tests/test-goal-box-work-test.sh measures it).
 */
export const workTestArgv = (home: string, tool: string): string[] => ['python3', '-I', '-B', '-c', WORK_TEST, `${home.replace(/\/+$/, '')}/.claude/hooks/turn-worked.py`, tool]

/** Whether the tool can change something by the review's test, or why that could not be read. */
export type WorkRead = { changes: boolean } | { unread: string }

/** The run's answer, held to yes or no: anything else is unread, never taken for no (L10). */
export const workRead = (r: { exitCode: number; stdout: string; stderr: string }): WorkRead => {
  const said = r.stdout.trim()
  if (r.exitCode === 0 && said === 'yes') return { changes: true }
  if (r.exitCode === 0 && said === 'no') return { changes: false }
  if (r.exitCode !== 0) return { unread: r.stderr.trim().split('\n').pop() || `python3 exited ${r.exitCode}` }
  return { unread: `it answered ${JSON.stringify(said.slice(0, 80))}, neither yes nor no` }
}

/**
 * Whether an AskUserQuestion call came back with an answer of Dan's, as Claude Code's dialog hands
 * it to a tool.call hook: a result holding `answers` with at least one that is not empty. A picker he
 * dismissed (a refusal), one that failed, one that closed by itself while he was away
 * (`afkTimeoutMs`), and any result not in that shape are no answer.
 */
export const answered = (r: unknown): boolean => {
  const o = r as { deny?: unknown; isError?: unknown; result?: unknown } | null | undefined
  if (!o || typeof o !== 'object' || o.deny !== undefined || o.isError === true) return false
  const out = o.result as { answers?: unknown; afkTimeoutMs?: unknown } | null | undefined
  if (!out || typeof out !== 'object' || out.afkTimeoutMs !== undefined) return false
  const answers = out.answers
  if (!answers || typeof answers !== 'object' || Array.isArray(answers)) return false
  return Object.values(answers).some(a => (typeof a === 'string' ? a.trim() !== '' : Array.isArray(a) && a.some(x => typeof x === 'string' && x.trim() !== '')))
}

/**
 * Why a second box for one request is refused, by what is known of a picker answer since (L11: each
 * cause its own words). Every form says when a later call is right.
 */
export const alreadyShownText = (picker: GoalBoxPicker | null | undefined): string => {
  const again = 'it shows again once Dan has asked for something new: a message he types, or work you do after an answer he gives in a picker'
  if (!picker) return `No box yet: the box was already shown for this request; ${again}.`
  if (picker.unread !== undefined)
    return `No box yet: the box was already shown for this request. Dan has answered a picker since, and whether anything has been changed since his answer could not be read (${picker.unread}), so it is not known whether there is new work to show a box for. Call again after the next tool call that changes something.`
  return `No box yet: the box was already shown for this request. Dan has answered a picker since, and nothing has been changed since his answer; an answer alone is not a new request. If his answer asked for work, do it, then call this tool again.`
}
