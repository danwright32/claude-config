// picker-check-count.ts: how many pickers this Mac's session records hold, per guard that records
// Dan's answer to one, and how many of those the shared check of text a person approves in a
// picker (payload/mods/mod-kit/hooks/shown.ts, askFault) would have refused, by which rule
// (claude-config#3321). Judged by the mods' own code, never a copy beside it (L107): the check is
// mod-kit's, and each guard's pickers are told apart by the guard's own reader of its source.
//
//   node tools/picker-check-count.ts [--projects <folder>] [--where]
//
// --projects is the folder Claude Code keeps session records in, one folder a project, each
// holding one .jsonl file a session (default ~/.claude/projects). --where adds, under each guard,
// one line a refused picker: the record's file name, the line the picker was sent on, what was at
// fault and the rule, and never a word of the picker's text, which is private (L155).
//
// What is counted. A picker is an AskUserQuestion call of the main conversation (a subagent's
// records nothing in any guard) that reached the dialog: its result is no error. It is answered
// when the result carries an answer and did not close by itself while Dan was away. The call is
// judged as the dialog got it: with the questions the result hands back when it hands any, since a
// guard may word the question and the answers itself, and the record keeps the call as Claude sent it.
//
// What the count cannot see, said in the output too: sleep mode records an answer only for a
// number this session offered, which lives in memory, so every picker in the shape it reads is
// counted (an upper bound); and a record older than Claude Code keeps is gone.
//
// Exit codes, each distinct (L11): 0 counted, 2 bad arguments, 3 the folder could not be read.
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { askFault } from '../payload/mods/mod-kit/hooks/shown.ts'
import { guardAsks } from '../payload/mods/mod-kit/hooks/designquestions.ts'
import { bareIssuesIn, issueRefsIn } from '../payload/mods/mod-kit/hooks/openquestions.ts'
import { LESSON_SOURCE, saveIdOf } from '../payload/mods/ask-before-saving/hooks/rules.ts'
import { ASK_SOURCE } from '../payload/mods/area-check/hooks/rules.ts'

type Ask = Record<string, unknown>
type Guard = { name: string; reads: string; mine: (ask: Ask) => boolean }

const sourceOf = (ask: Ask): unknown => (ask.metadata as { source?: unknown } | undefined)?.source
const questionsOf = (ask: Ask): { question?: unknown; options?: unknown }[] => (Array.isArray(ask.questions) ? ask.questions : [])
const sourced = (ask: Ask, prefix: string): boolean => typeof sourceOf(ask) === 'string' && (sourceOf(ask) as string).startsWith(`${prefix}:`)

// The sources of the two database pickers, as payload/hooks/lib/db-apply-approval.py reads them
// (SOURCE and TRUST_SOURCE there; tools/test-picker-check-count.sh holds these two to that file).
export const DB_APPLY_SOURCE = 'db-apply'
export const DB_TRUST_SOURCE = 'db-test-project'

/** Each guard that records Dan's answer to a picker, and how its picker is told from any other. */
export const GUARDS: Guard[] = [
  { name: 'lesson picker (ask before saving)', reads: `metadata source ${LESSON_SOURCE}`, mine: a => sourceOf(a) === LESSON_SOURCE },
  { name: 'memory save picker (ask before saving)', reads: "the mod's own reader of its source", mine: a => saveIdOf(sourceOf(a)) !== undefined },
  { name: 'area check restructure question', reads: `metadata source ${ASK_SOURCE}:<call>`, mine: a => sourced(a, ASK_SOURCE) },
  { name: 'design round guard', reads: "the guard's own reader of its source", mine: a => guardAsks(sourceOf(a)) },
  {
    name: 'sleep mode morning pickers',
    reads: 'a question starting 3.<n> or an answer starting 1.<n> (an upper bound)',
    mine: a => questionsOf(a).some(q => /^\s*3\.\d+\b/.test(String(q?.question ?? '')) || (Array.isArray(q?.options) ? (q.options as { label?: unknown }[]) : []).some(o => /^1\.\d+\b/.test(String(o?.label ?? '')))),
  },
  {
    name: 'picker manners (answer written to an issue)',
    reads: 'a first question naming an issue, and no design round guard source',
    mine: a => {
      const q = String(questionsOf(a)[0]?.question ?? '')
      return !guardAsks(sourceOf(a)) && q !== '' && (issueRefsIn(q, null).length > 0 || bareIssuesIn(q).length > 0)
    },
  },
  { name: 'database apply approval (hook)', reads: `metadata source ${DB_APPLY_SOURCE}`, mine: a => sourceOf(a) === DB_APPLY_SOURCE },
  { name: 'database test project approval (hook)', reads: `metadata source ${DB_TRUST_SOURCE}`, mine: a => sourceOf(a) === DB_TRUST_SOURCE },
  { name: 'Slack alert guard (retired in #3169)', reads: 'metadata source slack-alert-guard:<hold>', mine: a => sourced(a, 'slack-alert-guard') },
]

/** The rule a fault was found by, from the check's own words for it. */
export const ruleOf = (fault: string): string =>
  /is U\+[0-9A-F]{4,6}, /.test(fault)
    ? 'a character he cannot see'
    : /UTF-16 code units/.test(fault)
      ? 'longer than the dialog shows whole'
      : /it holds /.test(fault)
        ? 'markup a surface hides'
        : /are both blank/.test(fault)
          ? 'a run of blank lines'
          : /it takes \d+ rows/.test(fault)
            ? 'more rows than the limit'
            : 'another rule'

type Picker = { file: string; line: number; ask: Ask; answered: boolean }

/** Every picker of the main conversation in one session record that reached the dialog. */
export const pickersIn = (file: string, text: string): Picker[] => {
  const sent = new Map<string, { ask: Ask; line: number }>()
  const out: Picker[] = []
  text.split('\n').forEach((raw, k) => {
    if (!raw.includes('AskUserQuestion') && !(sent.size && raw.includes('tool_result'))) return
    let e: Record<string, unknown>
    try {
      e = JSON.parse(raw) as Record<string, unknown>
    } catch {
      return
    }
    if (typeof e !== 'object' || e === null || e.isSidechain === true) return
    const content = (e.message as { content?: unknown } | undefined)?.content
    if (!Array.isArray(content)) return
    for (const item of content as Record<string, unknown>[]) {
      if (typeof item !== 'object' || item === null) continue
      if (item.type === 'tool_use' && item.name === 'AskUserQuestion' && typeof item.id === 'string' && typeof item.input === 'object' && item.input !== null) {
        sent.set(item.id, { ask: item.input as Ask, line: k + 1 })
      } else if (item.type === 'tool_result' && typeof item.tool_use_id === 'string') {
        const was = sent.get(item.tool_use_id)
        if (!was) continue
        sent.delete(item.tool_use_id)
        const result = e.toolUseResult
        if (item.is_error || typeof result !== 'object' || result === null) continue
        const r = result as { questions?: unknown; answers?: unknown; afkTimeoutMs?: unknown }
        const answers = r.answers && typeof r.answers === 'object' ? Object.values(r.answers as Record<string, unknown>) : []
        const answered = r.afkTimeoutMs === undefined && answers.some(a => (typeof a === 'string' && a.trim() !== '') || (Array.isArray(a) && a.length > 0))
        // As the dialog got it: the questions the result hands back, when it hands any.
        const ask = Array.isArray(r.questions) && r.questions.length ? { ...was.ask, questions: r.questions } : was.ask
        out.push({ file, line: was.line, ask, answered })
      }
    }
  })
  return out
}

type Row = { asked: number; answered: number; refused: number; refusedAnswered: number; rules: Map<string, number>; where: string[] }

/** The count: for each guard, its pickers, those answered, and those the shared check refuses. */
export const count = (pickers: readonly Picker[]): { rows: Map<string, Row>; all: number; unguarded: number } => {
  const rows = new Map<string, Row>(GUARDS.map(g => [g.name, { asked: 0, answered: 0, refused: 0, refusedAnswered: 0, rules: new Map(), where: [] }]))
  let unguarded = 0
  for (const p of pickers) {
    const mine = GUARDS.filter(g => g.mine(p.ask))
    if (!mine.length) unguarded++
    if (!mine.length) continue
    const bad = askFault(p.ask)
    for (const g of mine) {
      const row = rows.get(g.name) as Row
      row.asked++
      if (p.answered) row.answered++
      if (bad === undefined) continue
      row.refused++
      if (p.answered) row.refusedAnswered++
      const rule = ruleOf(bad.fault)
      row.rules.set(rule, (row.rules.get(rule) ?? 0) + 1)
      row.where.push(`${p.file} line ${p.line}: ${bad.what}, ${rule}${p.answered ? '' : ' (not answered)'}`)
    }
  }
  return { rows, all: pickers.length, unguarded }
}

const main = (): number => {
  const args = process.argv.slice(2)
  let projects = join(homedir(), '.claude', 'projects')
  let where = false
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--where') where = true
    else if (args[i] === '--projects' && args[i + 1] !== undefined) projects = args[++i] as string
    else {
      console.error(`picker-check-count: "${args[i]}" is not understood. Usage: node tools/picker-check-count.ts [--projects <folder>] [--where]`)
      return 2
    }
  }
  const pickers: Picker[] = []
  let files = 0
  let unread = 0
  try {
    for (const project of readdirSync(projects)) {
      const dir = join(projects, project)
      if (!statSync(dir).isDirectory()) continue
      for (const name of readdirSync(dir)) {
        if (!name.endsWith('.jsonl')) continue
        files++
        try {
          pickers.push(...pickersIn(name, readFileSync(join(dir, name), 'utf8')))
        } catch {
          unread++
        }
      }
    }
  } catch (err) {
    console.error(`picker-check-count: ${projects} could not be read (${err instanceof Error ? err.message : String(err)}), so nothing was counted.`)
    return 3
  }
  const { rows, all, unguarded } = count(pickers)
  console.log(`picker-check-count: ${files} session records read in ${projects}${unread ? `, ${unread} more could not be read` : ''}; ${all} pickers of the main conversation reached the dialog, ${unguarded} of them read by no guard below.`)
  console.log('A picker can be counted under more than one guard. Refused is what the shared check (mod-kit hooks/shown.ts, askFault) refuses of the call as the dialog got it.')
  for (const g of GUARDS) {
    const r = rows.get(g.name) as Row
    const rules = [...r.rules].map(([rule, n]) => `${n} ${rule}`).join('; ')
    console.log(`${g.name}: ${r.asked} reached the dialog, ${r.answered} answered; refused ${r.refused}, of the answered ${r.refusedAnswered}${rules ? ` (by rule, of all refused: ${rules})` : ''}. Told by ${g.reads}.`)
    if (where) for (const w of r.where) console.log(`  ${w}`)
  }
  return 0
}

if (process.argv[1] !== undefined && import.meta.url.endsWith(process.argv[1].replace(/^.*\//, ''))) process.exit(main())
