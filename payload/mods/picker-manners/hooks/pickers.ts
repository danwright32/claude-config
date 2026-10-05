// Picker manners' pure parts (#615): what is refused before Claude Code's own dialog asks
// (docs/mods-design.md, "Picker manners (#615)").

/** Why a question is not asked, or undefined when it is. Read by Claude as the call's refusal. */
export const refusal = (questions: readonly unknown[], ctx: { quiet: boolean; source: string | undefined }): string | undefined => {
  if (questions.length !== 1) return 'Ask one question per call: Dan answers pickers one at a time.'
  if (ctx.quiet && ctx.source === 'next-issue') return 'Dan turned off next issue pickers for this session (/pickers on brings them back). Give the suggestions as a plain list instead.'
  return undefined
}

/** Dan asking for next issue offers to stop for the session (the spec's two phrases). */
export const asksQuiet = (text: string): boolean => /\bno next issue\b|\bjust give me the list\b/i.test(text)
