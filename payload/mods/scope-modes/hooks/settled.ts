// #3018: an overnight question is offered to Dan only while it is still open. On 2026-11-15 a session
// was told to put four leftover questions to him: two were one build order note, recorded once by
// repository and once by folder, that said itself it was not a question; two he had answered the
// morning after in the session that asked them, their pull request merged and the decision recorded
// by then. The notes held nothing saying any of that, and nothing looked.
//
// So a question is left out when it is no question (no choices, and its words say so), when it was
// noted twice (offered once), when its answer is on record in the sleep state's answered folder, the
// one the before bed round keeps its answers in (bedtime.ts answerKey), or when every issue and pull
// request it names is closed or merged. A lookup that fails never leaves one out: it is offered,
// saying the check could not be made (L11). Only the decisions live here; register.ts reads GitHub
// and the answered folder, and writes an answer there when Dan gives one in a morning picker.

import { answerKey, sameText } from './bedtime.ts'
import { repoKey, type NightQuestion } from './wake.ts'

// Words a note uses to say it asks nothing. Read only for a note with no choices to pick from, since
// a question with answers to pick is a question whatever else it says.
const SAYS_NO_QUESTION =
  /\b(?:not (?:really )?a question|no (?:answer|reply|decision|action) (?:is )?(?:needed|required|wanted)|nothing to (?:answer|decide)|nothing (?:is )?needed from (?:you|dan)|for (?:your )?information only|fyi)\b/i

/** A note that carries no choices and says itself it is not a question. */
export const notAQuestion = (q: { text: string; options?: readonly string[] }): boolean => (q.options?.length ?? 0) < 2 && SAYS_NO_QUESTION.test(q.text)

// Two notes are one question when their words match and nothing they name differs: a repository or
// issue only one of them gives is no difference (the same note written by repository and by folder).
const same = (a: string | null, b: string | null, key: (x: string) => string) => a === null || b === null || key(a) === key(b)

/**
 * Each question once, in the order first noted. A second noting of the same words, about no other
 * repository or issue, adds what the first lacked (its repository, issue, folder or choices).
 */
export const distinctQuestions = <Q extends NightQuestion>(qs: readonly Q[]): Q[] => {
  const out: Q[] = []
  for (const q of qs) {
    const words = sameText(q.text)
    const k = out.findIndex(o => sameText(o.text) === words && same(o.repo, q.repo, repoKey) && (o.issue === null || q.issue === null || o.issue === q.issue))
    if (k === -1) {
      out.push({ ...q, text: words })
      continue
    }
    const o = out[k] as Q
    out[k] = {
      ...o,
      repo: o.repo ?? q.repo,
      issue: o.issue ?? q.issue,
      cwd: o.cwd ?? q.cwd,
      ...(!o.options?.length && q.options?.length ? { options: q.options } : {}),
    }
  }
  return out
}

/** An issue or pull request a question names. */
export type Named = { repo: string; number: number }

// owner/name#N, or #N standing alone (never glued to a word, as in a short name like ledger#52,
// whose owner cannot be told).
const REF = /(?:\b([A-Za-z0-9][\w.-]*\/[\w.-]+)|(?<![\w/.-]))#(\d+)\b/g
// A web address in a question's words, its closing punctuation left off. Which repository it names is
// mod-kit's one link reader's to say ($.modkit.linkRepo), so register.ts asks it (#961).
const ADDRESS = /https?:\/\/[^\s<>"')\]]+/g
const trimmed = (link: string) => link.replace(/[.,;:!?]+$/, '')

/** The web addresses a question's words carry, each once, for register.ts to read with mod-kit's link reader. */
export const linksIn = (text: string): string[] => [...new Set([...text.matchAll(ADDRESS)].map(m => trimmed(m[0])))]

/** The issue or pull request number an address ends on (`/issues/N` or `/pull/N`), or null. */
export const linkNumber = (link: string): number | null => {
  const m = /\/(?:issues|pull)\/(\d+)(?:[/?#]|$)/.exec(link)
  return m ? Number(m[1]) : null
}

/**
 * The issues and pull requests a question names: its own issue, each item its links name (`links`,
 * read by register.ts with mod-kit's link reader), and each number in its words, read in the
 * repository written with it or else in `repo` (the question's, resolved from its folder when it
 * named none). A bare number with no repository to read it in names nothing.
 */
export const namedItems = (q: NightQuestion, repo: string | null, links: readonly Named[] = []): Named[] => {
  const out: Named[] = []
  const add = (r: string | null | undefined, n: number) => {
    if (!r || !Number.isInteger(n) || n <= 0) return
    if (!out.some(o => repoKey(o.repo) === repoKey(r) && o.number === n)) out.push({ repo: r, number: n })
  }
  if (q.issue !== null) add(q.repo ?? repo, q.issue)
  for (const l of links) add(l.repo, l.number)
  for (const m of q.text.replace(ADDRESS, ' ').matchAll(REF)) add(m[1] ?? repo, Number(m[2]))
  return out
}

/** What GitHub says of one named item: open, closed (a merged pull request too), or why it could not tell. */
export type ItemState = { state: 'open' } | { state: 'closed' } | { state: 'unchecked'; why: string }

const andList = (xs: string[]) => (xs.length <= 1 ? xs.join('') : `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`)

/**
 * Whether a question is settled by what it names: only when it names something and every item is
 * closed or merged. One still open keeps it. One that could not be checked, with none open, keeps it
 * too, with the sentence its offer carries saying so.
 */
export const judgeNamed = (named: readonly { item: Named; state: ItemState }[]): { settled: true } | { settled: false; unchecked?: string } => {
  if (!named.length || named.some(n => n.state.state === 'open')) return { settled: false }
  const unchecked = named.filter(n => n.state.state === 'unchecked')
  if (!unchecked.length) return { settled: true }
  const items = unchecked.map(n => `${n.item.repo}#${n.item.number}`)
  const whys = [...new Set(unchecked.map(n => (n.state.state === 'unchecked' ? n.state.why : '')))]
  return { settled: false, unchecked: `whether ${andList(items)} ${items.length === 1 ? 'is' : 'are'} still open could not be checked with GitHub: ${whys.join('; ')}` }
}

/**
 * The name a question's answer is kept under in the answered folder: the before bed round's key
 * (repository, issue and words), so an answer either records is read by both. A question about no
 * issue keys on issue 0, and one in no repository on the key for none.
 */
export const settledKey = (repo: string | null, q: { issue: number | null; text: string }): string => answerKey(repoKey(repo), q.issue ?? 0, q.text)

/**
 * The questions Dan answered in a morning picker, by the number the offer gave each (3.n): a picker
 * whose question begins with a number this session offered, and that came back with an answer. A
 * picker with no answer answers nothing, and is put to him again (#1285).
 */
export const answeredIn = (questions: unknown, answers: unknown, offered: ReadonlySet<string>): { n: string; answer: string }[] => {
  if (!Array.isArray(questions) || !answers || typeof answers !== 'object') return []
  const out: { n: string; answer: string }[] = []
  for (const q of questions as { question?: unknown }[]) {
    const asked = String(q?.question ?? '')
    const n = /^\s*(3\.\d+)\b/.exec(asked)?.[1]
    if (!n || !offered.has(n) || out.some(o => o.n === n)) continue
    const given = (answers as Record<string, unknown>)[asked]
    const picked = (Array.isArray(given) ? given.map(String) : typeof given === 'string' ? [given] : []).map(s => s.trim()).filter(Boolean)
    if (picked.length) out.push({ n, answer: picked.join(', ') })
  }
  return out
}
