// Sleep mode phase 6 (#836): the before bed questions about the queue's issues, the pure part.
//
// Dan's decision 8 (2026-10-06): turning sleep on gathers the open questions across the queue's
// issues and asks them one at a time in Claude Code's own dialog, the ones that unblock the most
// work first, each with "Go to sleep now" (worded GO_TO_SLEEP since #1771); answers are posted on the
// issue as dated decisions. Each offers its answers to pick (#1771, answerChoices below).
//
// Where the questions come from: the night's notes, and since #1279 the Open questions section of
// each issue a worker's goal names. An overnight session that meets a decision only Dan can make
// writes it with sleep_note as a `question` naming its repository, issue, text and options (the overnight
// rules tell it to), and the morning report lists it. Every issue's body also carries an Open
// questions section (the filing gate refuses one without it, and picker manners adds a question
// Dan is asked about an issue), whose open items are asked beside the notes, each once, and checked
// off there when answered (`inSection`). GitHub comments carry no marker a reader could rely on. A
// question stays open until an answer to it has been posted on its issue, which is recorded beside
// the notes (answerKey), so it is asked again each night until then.
//
// register.ts reads the notes, asks GitHub which issues are still open and how urgent, asks Dan,
// posts each answer and writes ~/.claude/state/sleep/unanswered/<generation>, which
// sleep-queue.sh reads to leave every issue whose question went unanswered out of the night's queue.

import { GO_TO_SLEEP, leavesUnanswered, SKIP_QUESTION } from './mod-kit/openquestions.ts'

// The two ways of leaving a question unanswered, each saying what it does (#1771): skip leaves this
// one and goes on to the next; going to sleep asks nothing more. Named in mod-kit's Open questions
// module (#1774), since picker manners sees this same dialog and must never record either as Dan's
// answer; shown from here.
export { GO_TO_SLEEP, SKIP_QUESTION }
/** The dialog's header: Claude Code keeps it to 12 characters. */
export const BEDTIME_HEADER = 'Before bed'

const REPO = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/
// The dialog carries four choices at most: the question's answers, then skip and go to sleep.
const DIALOG_MAX = 4

// A question its asker can answer yes or no to (#1771): its question sentence, the one its question
// mark ends, read after any lead in ("Slot shape: ...", "It merged. Run it now?"), neither offers
// alternatives (an "or") nor asks which, what, who, when, where, why or how in its first words.
// Measured on 2026-10-26 over all 42 Open questions items in claude-config's issues, open and
// answered: 17 read as yes or no, each rightly (13 the design rounds question picker manners
// writes, "Skip design rounds for this issue?"), and none of the other 25, every one of which offers
// alternatives or asks which, how or when.
const WH = /^(?:\S+\s+){0,2}?(?:what|which|who|whom|whose|when|where|why|how)\b/i
export const isYesNo = (text: string): boolean => {
  const end = text.indexOf('?')
  if (end < 0) return false
  const sentence = (text.slice(0, end).split(/[.!:;]\s+/).pop() ?? '').trim()
  return !!sentence && !/\bor\b/i.test(sentence) && !WH.test(sentence)
}

/**
 * The answers a question is offered with (#1771): the ones its asker gave, each once, when there are
 * at least two; else Yes and No for a yes or no question; else none, and Dan types his answer.
 */
export const answerChoices = (text: string, given: readonly string[]): string[] => {
  const own = [...new Set(given.map(sameText).filter(o => o && !leavesUnanswered(o)))]
  if (own.length >= 2) return own
  return isYesNo(text) ? ['Yes', 'No'] : []
}

/**
 * A question one note asked about one issue, or one open item in the issue's Open questions section
 * (#1279), which `inSection` marks, so its answer is checked off there too.
 */
export type IssueQuestion = { repo: string; issue: number; text: string; options: string[]; at: number; inSection?: number[] }
/** One question as Dan is asked it: every issue that is waiting on the same words, and those whose section holds it. */
export type OpenQuestion = { repo: string; text: string; issues: number[]; options: string[]; at: number; inSection?: number[] }

/**
 * The issues a goal names (#1279), so their Open questions are asked before the night: `#N` in the
 * worker's repository, or `owner/name#N` anywhere. A goal naming a milestone names no issue here.
 */
export const goalIssues = (goal: string, repo: string | null): { repo: string; issue: number }[] => {
  const out: { repo: string; issue: number }[] = []
  for (const m of goal.matchAll(/(?:\b([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+))?#(\d+)\b/g)) {
    // A number named as a pull request is not an issue (lessons review): it has no section to read.
    // "PR #31", "PRs #31 and #32", "pull requests #3, #4": every number in such a list. The words
    // only save a read: one they miss ("PR #31 (and also #32)") is read through gh, whose link names
    // a pull, and register.ts's openQuestions skips it there, so no pull is ever asked from.
    if (/\b(?:PRs?|pull requests?|pulls?)(?:\s*(?:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?#\d+\s*(?:,|and)?)*\s*$/i.test(goal.slice(0, m.index))) continue
    const r = m[1] ?? repo
    const n = Number(m[2])
    if (!r || !REPO.test(r) || !Number.isInteger(n) || n <= 0) continue
    if (!out.some(x => x.repo.toLowerCase() === r.toLowerCase() && x.issue === n)) out.push({ repo: r, issue: n })
  }
  return out
}

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
    const given = Array.isArray(n.options) ? n.options.filter((o): o is string => typeof o === 'string' && !!o.trim()) : []
    questions.push({ repo: n.repo, issue, text: words, options: answerChoices(words, given), at: typeof n.at === 'number' && Number.isFinite(n.at) ? n.at : 0 })
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
      out.set(k, { repo: q.repo, text: sameText(q.text), issues: [q.issue], options: [...q.options], at: q.at, ...(q.inSection ? { inSection: [...q.inSection] } : {}) })
      continue
    }
    if (!had.issues.includes(q.issue)) had.issues.push(q.issue)
    for (const n of q.inSection ?? []) if (!(had.inSection ??= []).includes(n)) had.inSection.push(n)
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

// The question's own answers, each once, leaving out skip and go to sleep, and how many of them the
// dialog shows: every place but going to sleep's (#1792).
const answersOf = (q: OpenQuestion) => [...new Set(q.options)].filter(o => !leavesUnanswered(o))
const ANSWERS_SHOWN = DIALOG_MAX - 1

/**
 * The question as the dialog shows it: its issues first, so Dan knows what it is about; and any
 * answers past the ones the dialog shows named after it, to be typed (#1792), so none is hidden.
 */
export const askText = (q: OpenQuestion) => {
  const more = answersOf(q).slice(ANSWERS_SHOWN)
  return `${q.repo}#${q.issues.join(' and #')}: ${q.text}${more.length ? ` (Or type one of: ${more.join(' / ')})` : ''}`
}

/**
 * The question's answers first, then skip and go to sleep; anything else Dan types. A question with
 * three answers or more shows three and no skip (#1792): until then it kept skip and showed two, so
 * a third choice was hidden on every question but the last, and nothing said so; a question's
 * choices are what it asks, while skip only puts it off, which going to sleep also does. On the
 * `last` question skip is left off too (#1771), since there nothing follows and it does what going
 * to sleep does; unless the question has no answers, as the dialog shows two choices at least and
 * pads fewer with Yes and No, which would post as his decision.
 */
export const askOptions = (q: OpenQuestion, last = false) => {
  const answers = answersOf(q)
  if (answers.length >= ANSWERS_SHOWN) return [...answers.slice(0, ANSWERS_SHOWN), GO_TO_SLEEP]
  return [...answers, ...(last && answers.length ? [] : [SKIP_QUESTION]), GO_TO_SLEEP]
}

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

// ---- Each worker's goal (#1242) ----
// Dan's decision of 2026-10-16: sleep mode works only toward the goal a session has set with Claude
// Code's own /goal, which may name a milestone, issues, or a task with no issue at all. A worker
// with none is asked for one before bed; left without one, it does no work that night. Its goal is
// read from its transcript by mod-kit's one reader of a /goal ($.modkit.goal, #1252, where how it
// was measured is written), which the goal tracker reads too.

export const NO_GOAL = 'No work for it tonight'

/** The before bed question for a worker with no goal set: who it is, and what having none means. */
export const goalQuestion = (who: string) =>
  `${who.charAt(0).toUpperCase()}${who.slice(1)} has no /goal set, so it does no work tonight unless you give it one. What should it work toward: a milestone, issues, or a task, in your words?`

/**
 * The before bed question for a worker whose /goal could not be read (#1636): never "has no /goal
 * set", which it may well have, but why it could not be read, so an answer is never taken as proof
 * there was none. `why` is a clause about the worker ("its transcript was not found").
 */
export const goalUnreadQuestion = (who: string, why: string) =>
  `The /goal of ${who} could not be read, because ${why}. It may have one set, but it does no work tonight unless you give it one here. What should it work toward: a milestone, issues, or a task, in your words?`

/** No work for it, or go to sleep; anything Dan types is the goal. */
export const goalOptions = () => [NO_GOAL, GO_TO_SLEEP]

/** What an answer to the goal question gives the worker. */
export const goalAnswer = (a: string): { goal: string | null; slept?: true } => {
  if (a === GO_TO_SLEEP) return { goal: null, slept: true }
  const t = a.trim()
  return { goal: t && t !== NO_GOAL ? t : null }
}

/** The night's unanswered list as sleep-queue.sh reads it: one owner/repo#N a line, each once. */
export const unansweredText = (left: { repo: string; issue: number }[]) => {
  const lines = [...new Set(left.map(l => `${l.repo.toLowerCase()}#${l.issue}`))].sort((a, b) => a.localeCompare(b, 'en', { numeric: true }))
  return lines.length ? `${lines.join('\n')}\n` : ''
}
