// Picker manners' pure parts (#615): what is refused before Claude Code's own dialog asks
// (docs/mods-design.md, "Picker manners (#615)").
import { bareIssuesIn, issueRefsIn } from './mod-kit/openquestions.ts'
import { guardAsks, guardIgnores } from './mod-kit/designquestions.ts'

/**
 * The issues a question names, as a log line says them, without asking GitHub or the session's
 * repository: owner/name#N as written, and a bare #N as issue #N.
 */
export const issuesNamedIn = (question: string): string[] => [...issueRefsIn(question, null).map(x => `${x.repo}#${x.issue}`), ...bareIssuesIn(question).map(n => `issue #${n}`)]

/**
 * Whether Dan's answer to a picker is one this mod writes onto an issue's Open questions (#1279):
 * its first question names an issue, and it is neither the design round guard's own picker, which
 * the guard records (#2261), nor a question in the guard's words asked without its source, which
 * is written nowhere (#2253). The one rule the hook refuses by (#3321) and the count of past
 * pickers reads (tools/picker-check-count.ts), so that number is this code's own (L107).
 */
export const writtenOnIssue = (question: string, source: unknown): boolean => question !== '' && !guardAsks(source) && !guardIgnores(question, source) && issuesNamedIn(question).length > 0

/**
 * The refusal of a picker Dan could not read as written whose answer would be written onto an
 * issue (#3321; Dan, 2026-11-21: "Refuse outright"), in words that say what to change. `unread` is
 * what mod-kit's askFault found.
 */
export const unreadRefusal = (unread: { what: string; fault: string }, question: string): string => {
  const where = `${issuesNamedIn(question).map(x => `${x}'s`).join(', ')} Open questions`
  const how = /UTF-16 code units|rows in a window/.test(unread.fault)
    ? 'Ask it again shorter: put the background in your message above the picker, and ask one decision at a time.'
    : 'Ask it again in plain words without what is at fault.'
  return `${unread.what} would not reach Dan as written: ${unread.fault}. His answer to a question naming an issue is written onto ${where} as settled by him, and it covers only words he could read whole, so nothing was asked and nothing is recorded. ${how}`
}

/** Why a question is not asked, or undefined when it is. Read by Claude as the call's refusal. */
export const refusal = (questions: readonly unknown[], ctx: { quiet: boolean; source: string | undefined }): string | undefined => {
  if (questions.length !== 1) return 'Ask one question per call: Dan answers pickers one at a time.'
  if (ctx.quiet && ctx.source === 'next-issue') return 'Dan turned off next issue pickers for this session (/pickers on brings them back). Give the suggestions as a plain list instead.'
  return undefined
}

/** Dan asking for next issue offers to stop for the session (the spec's two phrases). */
export const asksQuiet = (text: string): boolean => /\bno next issue\b|\bjust give me the list\b/i.test(text)
