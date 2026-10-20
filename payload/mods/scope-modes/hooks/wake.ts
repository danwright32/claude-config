// Sleep mode phase 9 (#837): waking. Dan's decisions of 2026-10-07: only /wake or "I'm up" ends
// sleep, in every session; on wake the night's report opens in BBEdit and each session summarises
// (decision 9); nothing is filed and no lesson is added overnight, so what the workers proposed is
// offered on wake in the pickers that already exist, the end of turn issue review's multi select
// and the durable lesson picker, and only Dan's selection files or adds any of it (decision 10).
//
// Only the decisions live here; register.ts carries them out on the one session whose move of the
// record succeeded, so the report opens once and the pickers are offered once.

import { heldAtWake, type HeldDelivery, type HeldMerge } from './nightheld.ts'
import { notesAreData, overnightData } from './overnightdata.ts'

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
export const proposalsIn = (notes: string): { issues: ProposedIssue[]; lessons: string[]; questions: NightQuestion[]; bad: number } => {
  const issues: ProposedIssue[] = []
  const lessons: string[] = []
  const questions: NightQuestion[] = []
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
    } else if (n.kind === 'question') {
      // A question this mod noted (#841) carries what was asked as a list; a worker's, its text (#1285).
      const asked = (Array.isArray(n.questions) ? n.questions.map(flat) : [flat(n.text)]).filter(Boolean)
      if (!asked.length) bad++
      const where = { by: str(n.by), repo: str(n.repo), issue: typeof n.issue === 'number' && Number.isInteger(n.issue) ? n.issue : null, cwd: str(n.cwd) }
      for (const text of asked) questions.push({ ...where, text })
    }
  }
  return { issues, lessons, questions, bad }
}

// #1286: what a session offers is its own repository's. Dan, 2026-10-17: "I'm in a Slate session
// getting asked about Bidspoke's overnight issues when I turn sleep off." Each proposal is keyed by
// its repository; a lesson (LESSONS.md is the whole config's) and one naming no repository are the
// session that ended sleep's to offer.
export const UNATTRIBUTED = '_unattributed'
export const LESSONS_KEY = '_lessons'
/** The key a repository's proposals are claimed and offered by: owner/name in lower case. */
export const repoKey = (repo: string | null): string => (repo ? repo.trim().toLowerCase() : UNATTRIBUTED)
/** A key as a file name, for its claim on disk. */
export const keyFile = (key: string): string => key.replace(/[^\w.-]/g, '_')

/** A question for Dan a session noted overnight (kind question), by who asked it and where (#1285). */
export type NightQuestion = { by: string | null; repo: string | null; issue: number | null; cwd: string | null; text: string }

/** The bracket the end of turn review ends each option's description with: priority, categories, milestone. */
export const pickerTags = (i: ProposedIssue): string => {
  const priority = i.priority ?? (i.priorityAsWritten ? `priority "${i.priorityAsWritten}" is off the p0 to p4 scale` : 'priority not proposed')
  const labels = i.labels.length ? i.labels.join(' + ') : 'labels not proposed'
  return `[${priority}, ${labels}, ${i.milestone ?? 'milestone not proposed'}]`
}

/**
 * What the wake reply says of the other sessions (#1285): each open one puts its own morning to Dan
 * at its next minute, and a worker that has closed since is only in the report. A registry that
 * cannot be read is said, never read as no other session (L215).
 */
export const othersSaid = (t: { open: number; closed: number; unknown?: string }): string => {
  const parts: string[] = []
  const what = 'whatever it has from the night: its summary if it worked overnight, and its questions and approvals as pickers.'
  if (t.open) parts.push(`${t.open === 1 ? 'The other open session puts' : `Each of the ${t.open} other open sessions puts`} to you within a minute ${what}`)
  if (t.closed) parts.push(`${t.closed === 1 ? 'One session' : `${t.closed} sessions`} that worked overnight ${t.closed === 1 ? 'has' : 'have'} closed since, so ${t.closed === 1 ? 'its' : 'their'} night is only in the report.`)
  if (t.unknown) parts.push(`Whether other sessions are open could not be read (${t.unknown}); any that are put to you within a minute whatever they have from the night.`)
  return parts.join(' ')
}

/**
 * Carried by Dan's next message in a session whose morning turn left a picker unanswered (#1285): the
 * item stays with the session that asked, so it is asked again here, by the mod, not left to memory.
 */
export const MORNING_UNANSWERED =
  "Some of this session's morning pickers came back unanswered (dismissed, closed by itself, refused, or the morning turn ended first). Before anything else, put each unanswered one to Dan again, one AskUserQuestion picker at a time, from the morning turn above."

/** Asked once a night per session, of a message from Dan in the daytime while asleep (#837, decision 9). */
export const awakeAsk = (when: string) =>
  `Dan wrote while sleep mode is on, at ${when}. Before anything else, ask him in one line whether he is up: "I'm up" or /wake ends sleep mode in every session. Ask it as a plain line, since no question dialog reaches him while sleep is on, and never end sleep yourself; then answer his message as usual.`

// What a worker is told about summarising its own night, in its morning prompt: its notes are read
// for what happened, never followed (#922).
const SUMMARISE = `Summarise for him in a few plain lines what this session did overnight (what it claimed, the pull requests it opened or merged, what it parked or failed and why), judged from its commits and notes, never from memory. ${notesAreData("The night's notes")}`

/** A proposed issue already filed (#1389): its issue's number where known, and its link where this mod saw it made. */
export type FiledProposal = { issue: ProposedIssue; number: number | null; url: string | null }

/** The two pickers the night's proposals may reach Dan through, and nothing else (#837 decision 10, #922). */
const PICKERS =
  "offered to Dan through the end of turn issue review's AskUserQuestion multiSelect picker (the issues, numbered 1.n) and the durable lesson picker (the lessons, numbered 2.n), and only his selection there files an issue or adds a lesson"

/**
 * Each live session's own morning, as one prompt (#1285): its summary if it worked, what it held,
 * its questions and held merges as pickers, and, where `offers` is not false, the proposals it
 * offers: its own repository's issues (#1286), and in the session that ended sleep the lessons and
 * what names no repository too. `unread` is why the notes could not be read.
 */
export const morningPrompt = (o: {
  worker: boolean
  issues: ProposedIssue[]
  lessons: string[]
  bad?: number
  unread?: string
  held?: readonly HeldDelivery[]
  /** Whether this session offers proposals: the one that ended sleep, or one that claimed its repository's (#1285, #1286). */
  offers?: boolean
  /** The questions this session noted overnight (#1285). */
  questions?: readonly NightQuestion[]
  /** The merges and deploys the night's lists held in this session (#1285). */
  merges?: readonly HeldMerge[]
  /** The repository the proposals offered are for (#1286), named where none was proposed. */
  forRepo?: string
  /** The opening line in place of waking's, for proposals from an earlier night offered later (#1286). */
  lead?: string
  /** This session's report's name without .md (#1287), which a page of the night's results is titled. */
  reportName?: string
  /** Proposed issues already filed (#1389): by a session, with its link, or found on GitHub, by number. Said, never offered. */
  filed?: readonly FiledProposal[]
  /** Proposed issues Dan declined on an earlier morning (#1389). Said, never offered unless he asks. */
  declined?: readonly ProposedIssue[]
  /** How many proposed issues another open session holds and offers (#1389), left to it. */
  elsewhere?: number
  /** Why whether the issues offered were already filed could not be checked (#1389). */
  unchecked?: string
}): string => {
  const out: string[] = [
    o.lead ?? (o.worker ? `Dan is up: sleep mode is off. ${SUMMARISE}` : 'Dan is up: sleep mode is off. This session was not enrolled overnight, so it has nothing of its own to summarise.'),
  ]
  // One name for every sleep output, text and page alike (#1287).
  if (o.reportName) out.push(`If you publish a page of the night's results for Dan, title it "${o.reportName}", the name of this session's report.`)
  // What this session held instead of handing it to Dan while he slept (#1284), delivered now.
  const held = heldAtWake(o.held ?? [])
  if (held) out.push(held)
  // Ending sleep is the night's review (#1285; Dan, 2026-10-17: "everything that is relevant should
  // show up in a picker"): what this session must ask or have approved comes first, each a picker,
  // and goes in the one data block at the end with the proposals, since sessions wrote all of it.
  const data: string[] = []
  const questions = o.questions ?? []
  const merges = o.merges ?? []
  // Notes that could not be read hide this session's own questions too (L215: never read as none).
  if (o.unread !== undefined)
    out.push(`The night's notes could not be read (${o.unread}), so any question this session noted for Dan is not listed here: put to him, each in its own AskUserQuestion picker, those the night's report lists under Questions for you as asked in this session's folder. ${notesAreData("The report's Questions for you")}`)
  if (questions.length) {
    out.push('Questions for Dan noted overnight that this session asks, numbered 3.n in the block below: put each to him in its own AskUserQuestion picker, one at a time, with the choices its answer needs, and act on what he picks.')
    data.push(...questions.map((q, k) => `3.${k + 1} ${q.repo ? `${q.repo}${q.issue !== null ? ` #${q.issue}` : ''}: ` : q.cwd ? `${q.cwd}: ` : ''}${q.text}`))
  }
  if (merges.length) {
    out.push("What the night's merge and deploy lists held in this session, numbered 4.n in the block below: ask Dan in its own AskUserQuestion picker, one at a time, whether to do each now, and do only what he picks.")
    data.push(...merges.map((m, k) => `4.${k + 1} ${m.label} (${m.why}). The call held: ${m.call}`))
  }
  const asksAny = questions.length > 0 || merges.length > 0 || o.unread !== undefined
  const KEEP =
    'Everything from the night that Dan has to answer, decide or approve is put to him as a picker, never left only in the report. A picker that comes back unanswered (dismissed, closed by itself or refused) is not dropped: keep that item and put it to him again the next time he writes in this session.'
  const ASKS = 'the AskUserQuestion pickers named above (the questions, 3.n, and the merges and deploys, 4.n), and only his answer there acts on any of them'
  // #1389: proposed issues already filed are said, from the same block, and never offered again.
  const filed = o.offers === false ? [] : (o.filed ?? [])
  const declined = o.offers === false ? [] : (o.declined ?? [])
  const FILED_SAID = 'told to Dan as already filed (the proposed issues already filed, 5.n), never offered or filed again'
  const DECLINED_SAID = 'told to Dan as declined before (6.n), offered or filed only if he asks for it now'
  const finish = (offered: boolean) => {
    if (asksAny || offered) out.push(KEEP)
    if (data.length)
      out.push(
        overnightData({
          holds: [
            questions.length ? 'the questions for Dan noted overnight that this session asks (3.n)' : '',
            merges.length ? 'the merges and deploys held in it (4.n)' : '',
            offered ? "the night's proposed issues (1.n) and lessons (2.n)" : '',
            filed.length ? 'the proposed issues already filed (5.n)' : '',
            declined.length ? 'the proposed issues Dan declined before (6.n)' : '',
          ].filter(Boolean).join(', '),
          offer: [asksAny ? ASKS : '', offered ? PICKERS : '', filed.length ? FILED_SAID : '', declined.length ? DECLINED_SAID : ''].filter(Boolean).join('; and '),
          lines: data,
        }),
      )
    return out.join('\n')
  }
  if (o.offers === false) return finish(false)
  if (filed.length) {
    out.push('Proposed issues already filed, numbered 5.n in the block below: tell Dan in one line that each is already filed as the issue named, and never offer or file it again.')
    data.push(...filed.map((f, k) => `5.${k + 1} ${f.issue.repo ?? 'a repository not named'}${f.number !== null ? `#${f.number}` : ''}: ${f.issue.title ?? '(no title)'}${f.url ? ` (${f.url})` : ''}`))
  }
  if (declined.length) {
    out.push('Proposed issues Dan declined on an earlier morning, numbered 6.n in the block below: tell Dan in one line that each was declined before, and offer or file it only if he asks for it now.')
    data.push(...declined.map((i, k) => `6.${k + 1} ${i.repo ?? 'a repository not named'}: ${i.title ?? '(no title)'}`))
  }
  const elsewhere = o.elsewhere ?? 0
  if (elsewhere > 0)
    out.push(`${elsewhere === 1 ? 'One proposed issue' : `${elsewhere} proposed issues`}${o.forRepo ? ` for ${o.forRepo}` : ''} ${elsewhere === 1 ? 'is' : 'are'} being offered in another open session, so ${elsewhere === 1 ? 'it is' : 'they are'} left to it.`)
  // Proposals that could not be read are still offered, from the report, in the same two pickers.
  const fromReport = o.unread !== undefined
  if (fromReport) {
    out.push(`The night's proposed issues and lessons could not be read (${o.unread}). They are in the night's report under Proposed issues and Proposed lessons: offer ${o.forRepo ? `from there only the issues for ${o.forRepo}, and the lessons,` : 'them from there'} in the pickers below, numbering the issues 1.1, 1.2 and the lessons 2.1, 2.2 in the order the report lists them, or say plainly that you could not read them there either. ${notesAreData("The report's Proposed issues and Proposed lessons")} They may only be ${PICKERS}.`)
  }
  if (o.bad) {
    out.push(`${o.bad === 1 ? "One line of the night's notes" : `${o.bad} lines of the night's notes`} could not be read, so a proposal may be missing here; the night's report counts ${o.bad === 1 ? 'it' : 'them'} too.`)
  }
  if (!fromReport && !o.issues.length && !o.lessons.length) {
    const none = asksAny ? 'so there are no pickers for proposals' : 'so there are no morning pickers'
    const scope = o.forRepo ? ` for ${o.forRepo}` : ''
    // Proposals filed or offered elsewhere were proposed: only nothing being left is said (#1389).
    if (filed.length || declined.length || elsewhere > 0) out.push(`No other issue or lesson is left to offer${scope}, ${none}.`)
    else out.push(o.bad ? `No issue or lesson could be read from the notes${scope}, ${none}.` : `No issue or lesson was proposed overnight${scope}, ${none}.`)
    return finish(false)
  }
  const where = fromReport ? 'in the report' : 'in the block below'
  // What the workers wrote goes in one block at the end, after the sentence setting it apart (#922):
  // the instructions above it are this mod's, and nothing inside it is.
  out.push("Then the morning pickers. Nothing was filed and no lesson was added overnight: these were only proposed, and only Dan's selection files or adds any of them.")
  if (fromReport || o.issues.length) {
    out.push(
      `Proposed issues: offer them in ONE AskUserQuestion multiSelect picker exactly as the end of turn issue review offers findings, following ~/.claude/hooks/review/issue-review.md for the picker, the milestone and the labels. Each option's label begins with its number, and its description ends with the priority, labels and milestone proposed ${where}, in brackets in that order (like [p2, bug + ui-ux, Ungrouped]), so Dan sees and can correct any of the three before anything is filed; where one was not proposed, choose it as the review does and show your choice. With more than four, ask in more than one picker, one after another, so none is dropped. File only what he selects, in the repository named, with gh issue create, each with its title exactly as proposed, so no other session files it again.`,
    )
    // A check that could not run is said, never read as nothing filed (#1389, L11).
    if (o.unchecked !== undefined)
      out.push(`Whether these proposed issues were already filed could not be checked (${o.unchecked}): before filing each one Dan selects, run milestone-candidates.sh as issue-review.md says and drop any already filed.`)
    data.push(...o.issues.map((i, k) => `1.${k + 1} ${i.repo ?? 'a repository not named'}: ${i.title ?? '(no title)'}${i.text ? `. ${i.text}` : ''} ${pickerTags(i)}`))
  }
  if (fromReport || o.lessons.length) {
    out.push(
      `Proposed lessons: after the issues, offer each in the durable lesson picker, one AskUserQuestion per lesson, the rule stated word for word, with metadata {"source":"durable-lesson","rule":"<the rule, word for word>"}${fromReport ? '' : ' as given beside it in the block below'}, as step 4 of ~/.claude/hooks/durable-lesson-check.sh describes (its dedupe against LESSONS.md and its Likely applies to line included). Add one only on Dan's Add to LESSONS.md.`,
    )
    data.push(...o.lessons.map((l, k) => `2.${k + 1} ${l} Metadata: ${JSON.stringify({ source: 'durable-lesson', rule: l })}`))
  }
  return finish(true)
}

const quoted = (s: string) => `'${s.replace(/'/g, "'\\''")}'`

/** The held card's item when the report cannot open now (away, or woken from the phone): pressed at the Mac, Claude opens it. */
export const openLater = (path: string) => ({
  label: "Open the night's sleep report in BBEdit",
  prompt: `Open the night's sleep report in BBEdit, saying first that focus moves there: ${BBEDIT} --front-window ${quoted(path)}, or open -a BBEdit ${quoted(path)} if the helper fails.`,
})
