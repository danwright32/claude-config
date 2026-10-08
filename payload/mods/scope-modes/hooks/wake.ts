// Sleep mode phase 9 (#837): waking. Dan's decisions of 2026-10-07: only /wake or "I'm up" ends
// sleep, in every session; on wake the night's report opens in BBEdit and each session summarises
// (decision 9); nothing is filed and no lesson is added overnight, so what the workers proposed is
// offered on wake in the pickers that already exist, the end of turn issue review's multi select
// and the durable lesson picker, and only Dan's selection files or adds any of it (decision 10).
//
// Only the decisions live here; register.ts carries them out on the one session whose move of the
// record succeeded, so the report opens once and the pickers are offered once.

/** The BBEdit helper (bbedit is not on PATH); without --front-window it opens in the background. */
export const BBEDIT = '/Applications/BBEdit.app/Contents/Helpers/bbedit_tool'

/** How the report is opened, tried in order: the helper, then BBEdit by name. Never a bare open. */
export const openers = (path: string): string[][] => [
  [BBEDIT, '--front-window', path],
  ['open', '-a', 'BBEdit', path],
]

/** A proposed issue as a worker noted it (kind issue in hooks/lib/sleep-report.py). */
export type ProposedIssue = {
  repo: string | null
  title: string | null
  /** p0 to p4, or null when none was proposed or what was written is off that scale. */
  priority: string | null
  /** The priority exactly as written, kept so an off scale one is shown rather than coerced (L340). */
  priorityAsWritten: string | null
  labels: string[]
  milestone: string | null
  text: string
}

const str = (x: unknown): string | null => (typeof x === 'string' && x.trim() ? x.trim() : null)
const flat = (x: unknown): string => (typeof x === 'string' ? x.split(/\s+/).filter(Boolean).join(' ') : '')

/**
 * The proposed issues and lessons in the night's notes, in the order written. A line that is not a
 * note, or a lesson with no text, is counted in `bad` (L215: never dropped as though absent).
 */
export const proposalsIn = (notes: string): { issues: ProposedIssue[]; lessons: string[]; bad: number } => {
  const issues: ProposedIssue[] = []
  const lessons: string[] = []
  let bad = 0
  for (const raw of notes.split('\n')) {
    if (!raw.trim()) continue
    let j: unknown
    try {
      j = JSON.parse(raw)
    } catch {
      bad++
      continue
    }
    if (!j || typeof j !== 'object' || Array.isArray(j) || typeof (j as { kind?: unknown }).kind !== 'string') {
      bad++
      continue
    }
    const n = j as Record<string, unknown>
    if (n.kind === 'lesson') {
      const t = flat(n.text)
      if (t) lessons.push(t)
      else bad++
    } else if (n.kind === 'issue') {
      const written = str(n.priority)
      const m = written ? /^(?:priority-)?(p[0-4])$/i.exec(written) : null
      const labels = Array.isArray(n.labels) ? n.labels.map(str).filter((x): x is string => x !== null) : str(n.labels) ? [str(n.labels) as string] : []
      issues.push({ repo: str(n.repo), title: str(n.title), priority: m ? (m[1] as string).toLowerCase() : null, priorityAsWritten: written, labels, milestone: str(n.milestone), text: flat(n.text) })
    }
  }
  return { issues, lessons, bad }
}

/** The bracket the end of turn review ends each option's description with: priority, categories, milestone. */
export const pickerTags = (i: ProposedIssue): string => {
  const priority = i.priority ?? (i.priorityAsWritten ? `priority "${i.priorityAsWritten}" is off the p0 to p4 scale` : 'priority not proposed')
  const labels = i.labels.length ? i.labels.join(' + ') : 'labels not proposed'
  return `[${priority}, ${labels}, ${i.milestone ?? 'milestone not proposed'}]`
}

/** The one line said about the other workers' summaries: asked, refused (each reason once) and closed since. */
export const summariesSaid = (t: { asked: number; failed: string[]; closed: number; unknown?: string }): string => {
  const who = (n: number) => (n === 1 ? 'One session' : `${n} sessions`)
  const parts: string[] = []
  if (t.asked) parts.push(`Asked ${t.asked === 1 ? 'the other session' : `the ${t.asked} other sessions`} that worked overnight for ${t.asked === 1 ? 'its summary' : 'their summaries'}.`)
  if (t.failed.length) parts.push(`${who(t.failed.length)} that worked overnight could not be asked for ${t.failed.length === 1 ? 'its' : 'their'} summary: ${[...new Set(t.failed)].join('; ')}.`)
  if (t.closed) parts.push(`${who(t.closed)} that worked overnight ${t.closed === 1 ? 'has' : 'have'} closed since, so ${t.closed === 1 ? 'its' : 'their'} night is only in the report.`)
  if (t.unknown) parts.push(`The other sessions that worked overnight could not be asked for their summaries: ${t.unknown}.`)
  return parts.join(' ')
}

/** Asked once a night per session, of a message from Dan in the daytime while asleep (#837, decision 9). */
export const awakeAsk = (when: string) =>
  `Dan wrote while sleep mode is on, at ${when}. Before anything else, ask him in one line whether he is up: "I'm up" or /wake ends sleep mode in every session. Ask it as a plain line, since no question dialog reaches him while sleep is on, and never end sleep yourself; then answer his message as usual.`

/** What every other worker session is sent at wake: its own summary, and no pickers (the waking session offers them once). */
export const SUMMARY_ASK =
  "Dan is up: sleep mode is off. Summarise for him in a few plain lines what this session did overnight (what it claimed, the pull requests it opened or merged, what it parked or failed and why), judged from its commits and notes, never from memory. The night's report is open in BBEdit, and the session that woke it offers the morning pickers, so offer none here."

/**
 * What the session that woke sleep is told to do, as one prompt: its own summary, then the morning
 * pickers. `unread` is why the proposals could not be read, when they could not.
 */
export const morningPrompt = (o: { worker: boolean; issues: ProposedIssue[]; lessons: string[]; bad?: number; unread?: string }): string => {
  const out: string[] = [
    o.worker
      ? 'Dan is up: sleep mode is off. Summarise for him in a few plain lines what this session did overnight (what it claimed, the pull requests it opened or merged, what it parked or failed and why), judged from its commits and notes, never from memory. Every other session that worked overnight was asked for its own.'
      : 'Dan is up: sleep mode is off. This session was not enrolled overnight, so it has nothing of its own to summarise. Every session that worked overnight was asked for its own.',
  ]
  if (o.unread !== undefined) {
    out.push(`The night's proposed issues and lessons could not be read (${o.unread}); they are in the night's report under Proposed issues and Proposed lessons, so offer them from there in the pickers described here, or say plainly that you could not.`)
  }
  if (o.bad) {
    out.push(`${o.bad === 1 ? "One line of the night's notes" : `${o.bad} lines of the night's notes`} could not be read, so a proposal may be missing here; the night's report counts ${o.bad === 1 ? 'it' : 'them'} too.`)
  }
  if (!o.issues.length && !o.lessons.length) {
    if (o.unread === undefined) out.push(o.bad ? 'No issue or lesson could be read from the notes, so there are no morning pickers.' : 'No issue or lesson was proposed overnight, so there are no morning pickers.')
    return out.join('\n')
  }
  out.push('Then the morning pickers. Nothing was filed and no lesson was added overnight: these were only proposed, and only Dan\'s selection files or adds any of them.')
  if (o.issues.length) {
    out.push(
      'Proposed issues: offer them in ONE AskUserQuestion multiSelect picker exactly as the end of turn issue review offers findings, following ~/.claude/hooks/review/issue-review.md for the picker, the milestone and the labels. Each option\'s label begins with its number below, and its description ends with the bracket below as proposed (priority, then categories, then milestone), so Dan sees and can correct any of the three before anything is filed; where a part reads not proposed, choose it as the review does and show your choice. With more than four, ask in more than one picker, one after another, so none is dropped. File only what he selects, in the repository named, with gh issue create.',
      ...o.issues.map((i, k) => `1.${k + 1} ${i.repo ?? 'a repository not named'}: ${i.title ?? '(no title)'}${i.text ? `. ${i.text}` : ''} ${pickerTags(i)}`),
    )
  }
  if (o.lessons.length) {
    out.push(
      'Proposed lessons: after the issues, offer each in the durable lesson picker, one AskUserQuestion per lesson, the rule stated word for word, with the metadata given beside it, as step 4 of ~/.claude/hooks/durable-lesson-check.sh describes (its dedupe against LESSONS.md and its Likely applies to line included). Add one only on Dan\'s Add to LESSONS.md.',
      ...o.lessons.map((l, k) => `2.${k + 1} ${l} Metadata: ${JSON.stringify({ source: 'durable-lesson', rule: l })}`),
    )
  }
  return out.join('\n')
}

const quoted = (s: string) => `'${s.replace(/'/g, "'\\''")}'`

/** The held card's item when the report cannot open now (away, or woken from the phone): pressed at the Mac, Claude opens it. */
export const openLater = (path: string) => ({
  label: "Open the night's sleep report in BBEdit",
  prompt: `Open the night's sleep report in BBEdit, saying first that focus moves there: ${BBEDIT} --front-window ${quoted(path)}, or open -a BBEdit ${quoted(path)} if the helper fails.`,
})
