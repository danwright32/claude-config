// Sleep mode phase 6 (#836): the before bed questions about the queue's issues, the pure part.
//
// Dan's decision 8 (2026-10-06): turning sleep on gathers the open questions across the queue's
// issues and asks them one at a time in Claude Code's own dialog, the ones that unblock the most
// work first, each with "Go to sleep now"; answers are posted on the issue as dated decisions.
//
// Where the questions come from: the night's notes. An overnight session that meets a decision
// only Dan can make writes it with sleep_note as a `question` naming its repository, issue and
// text (the overnight rules tell it to), and the morning report lists it. Those notes are the one
// structured record of a question about an issue; GitHub comments carry no marker a reader could
// rely on. A question stays open until an answer to it has been posted on its issue, which is
// recorded beside the notes (answerKey), so it is asked again each night until then.
//
// register.ts reads the notes, asks GitHub which issues are still open and how urgent, asks Dan,
// posts each answer and writes ~/.claude/state/sleep/unanswered/<generation>, which
// sleep-queue.sh reads to leave every issue whose question went unanswered out of the night's queue.

export const GO_TO_SLEEP = 'Go to sleep now'
export const SKIP_QUESTION = 'Skip this one'
/** The dialog's header: Claude Code keeps it to 12 characters. */
export const BEDTIME_HEADER = 'Before bed'

const REPO = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/
// The dialog carries four choices at most: two a session suggested, then skip and go to sleep.
const SUGGESTED_MAX = 2

/** A question one note asked about one issue. */
export type IssueQuestion = { repo: string; issue: number; text: string; options: string[]; at: number }
/** One question as Dan is asked it: every issue that is waiting on the same words. */
export type OpenQuestion = { repo: string; text: string; issues: number[]; options: string[]; at: number }

/** Whitespace collapsed, so the same words noted on two nights are one question. */
export const sameText = (s: string) => s.split(/\s+/).filter(Boolean).join(' ')

const issueOf = (x: unknown): number | null => {
  const n = typeof x === 'number' ? x : typeof x === 'string' && /^\d+$/.test(x) ? Number(x) : NaN
  return Number.isInteger(n) && n > 0 ? n : null
}

/**
 * The questions about an issue in one night's notes file. A question names an owner/name
 * repository, an issue and its text; every other question (a refused AskUserQuestion, which names
 * only a folder, and a repository closed for the night, which phase 7 asks about itself) has no
 * issue to post an answer on and is left to the morning report. A line that is not JSON is counted.
 */
export const questionsIn = (text: string): { questions: IssueQuestion[]; bad: number } => {
  const questions: IssueQuestion[] = []
  let bad = 0
  for (const raw of text.split('\n')) {
    if (!raw.trim()) continue
    let n: Record<string, unknown>
    try {
      const j = JSON.parse(raw) as unknown
      if (!j || typeof j !== 'object' || Array.isArray(j)) {
        bad++
        continue
      }
      n = j as Record<string, unknown>
    } catch {
      bad++
      continue
    }
    if (n.kind !== 'question' || typeof n.repo !== 'string' || !REPO.test(n.repo)) continue
    const issue = issueOf(n.issue)
    const words = typeof n.text === 'string' ? sameText(n.text) : ''
    if (issue === null || !words) continue
    const options = Array.isArray(n.options) ? n.options.filter((o): o is string => typeof o === 'string' && !!o.trim()) : []
    questions.push({ repo: n.repo, issue, text: words, options, at: typeof n.at === 'number' && Number.isFinite(n.at) ? n.at : 0 })
  }
  return { questions, bad }
}

/** One question per repository and words, carrying every issue waiting on it and the oldest time it was noted. */
export const groupQuestions = (qs: IssueQuestion[]): OpenQuestion[] => {
  const out = new Map<string, OpenQuestion>()
  // Oldest first, so the spelling of the repository and the suggested choices are the first noted.
  for (const q of [...qs].sort((a, b) => a.at - b.at)) {
    const k = `${q.repo.toLowerCase()}\n${sameText(q.text)}`
    const had = out.get(k)
    if (!had) {
      out.set(k, { repo: q.repo, text: sameText(q.text), issues: [q.issue], options: [...q.options], at: q.at })
      continue
    }
    if (!had.issues.includes(q.issue)) had.issues.push(q.issue)
    if (!had.options.length && q.options.length) had.options = [...q.options]
  }
  for (const q of out.values()) q.issues.sort((a, b) => a - b)
  // First noted first, which orderQuestions keeps as its last tie break.
  return [...out.values()].sort((a, b) => a.at - b.at)
}

/** An issue's priority label as a rank, p0 first; no priority label ranks after p4. */
export const priorityRank = (labels: unknown): number => {
  const names = Array.isArray(labels) ? labels.map(l => (l && typeof l === 'object' ? (l as { name?: unknown }).name : l)) : []
  for (let p = 0; p <= 4; p++) if (names.includes(`priority-p${p}`)) return p
  return 5
}

/**
 * The questions that unblock the most work first. An issue is workable tonight only once every
 * question on it is answered, so: a question more issues are waiting on; then the one whose issue
 * has the fewest questions left (one answer frees it soonest); then the more urgent issue; then the
 * question noted first.
 */
export const orderQuestions = (qs: OpenQuestion[], rank: (repo: string, issue: number) => number): OpenQuestion[] => {
  const waiting = new Map<string, number>()
  const key = (repo: string, n: number) => `${repo.toLowerCase()}#${n}`
  for (const q of qs) for (const n of q.issues) waiting.set(key(q.repo, n), (waiting.get(key(q.repo, n)) ?? 0) + 1)
  const fewest = (q: OpenQuestion) => Math.min(...q.issues.map(n => waiting.get(key(q.repo, n)) ?? 1))
  const best = (q: OpenQuestion) => Math.min(...q.issues.map(n => rank(q.repo, n)))
  return [...qs].sort((a, b) => b.issues.length - a.issues.length || fewest(a) - fewest(b) || best(a) - best(b) || a.at - b.at)
}

/** The question as the dialog shows it: its issues first, so Dan knows what it is about. */
export const askText = (q: OpenQuestion) => `${q.repo}#${q.issues.join(' and #')}: ${q.text}`

/** Up to two choices the session suggested, then skip and go to sleep; anything else Dan types. */
export const askOptions = (q: OpenQuestion) => [
  ...[...new Set(q.options)].filter(o => o !== GO_TO_SLEEP && o !== SKIP_QUESTION).slice(0, SUGGESTED_MAX),
  SKIP_QUESTION,
  GO_TO_SLEEP,
]

/** The decision as posted on the issue: dated in ET, the question quoted, the answer as given (L249). */
export const decisionComment = (question: string, answer: string, date: string) =>
  [`**Decision from Dan, ${date} (ET)**, answered before bed as sleep mode started.`, '', ...question.split('\n').map(l => `> ${l}`), '', `Answer: ${answer}`].join('\n')

// FNV-1a over the text, twice with different offsets: a file name that stands for the key.
const fnv = (s: string, seed: number) => {
  let h = seed >>> 0
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return h.toString(16).padStart(8, '0')
}

/** Names the record that a question's answer was posted on one issue: repository, issue and words. */
export const answerKey = (repo: string, issue: number, text: string) => {
  const k = `${repo.toLowerCase()}#${issue}\n${sameText(text)}`
  return fnv(k, 0x811c9dc5) + fnv(k, 0x050c5d1f)
}

/** The night's unanswered list as sleep-queue.sh reads it: one owner/repo#N a line, each once. */
export const unansweredText = (left: { repo: string; issue: number }[]) => {
  const lines = [...new Set(left.map(l => `${l.repo.toLowerCase()}#${l.issue}`))].sort((a, b) => a.localeCompare(b, 'en', { numeric: true }))
  return lines.length ? `${lines.join('\n')}\n` : ''
}
