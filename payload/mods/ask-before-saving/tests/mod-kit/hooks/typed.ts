// A typed answer to a mod's question (#1138, #1145). When Dan types in a question's dialog instead
// of choosing one of its answers, a guard records nothing, and he must hear that, not only Claude:
// Dan, 2026-10-13, on the design round guard's question, asked that a typed answer not be silently
// ignored, and that it be said and asked again. The design round guard and ask before saving both
// say it through `$.modkit.typedAnswer`, so the wording is one (L613). Pure: the toast itself is
// shown where the member is answered, since `$.ui` is spelled only at its call site.

/** What a mod tells about a typed answer: whose question it was, his words, what stays as it was, and how to ask again. */
export type TypedAnswer = { guard: string; typed: string; still: string; again: string }

/** Why an input cannot be said, naming each part missing, or undefined when it can. */
export const typedMissing = (t: Partial<TypedAnswer> | undefined): string | undefined => {
  const missing = (['guard', 'typed', 'still', 'again'] as const).filter(k => typeof t?.[k] !== 'string' || !(t[k] as string).trim())
  return missing.length ? `$.modkit.typedAnswer needs ${missing.join(', ')} as words` : undefined
}

/** The toast Dan sees. */
export const typedToast = (guard: string): string =>
  `${guard}: your typed answer was not recorded, because only choosing one of the answers counts. Choose one when Claude asks again.`

/** What Claude is told, in the dialog's own result. */
export const typedAnswerText = (t: TypedAnswer): string =>
  `Dan typed "${t.typed}" instead of choosing an answer, so it was not recorded, and ${t.still}. ` +
  `Tell him in one line that his typed answer was not recorded, because only choosing one of the answers counts; answer what he said if it asks something; then ${t.again}.`

/** What Claude is told when the toast could not be shown: its line is then the only place Dan learns it. */
export const typedUnshown = (t: TypedAnswer, why: string): string =>
  `${typedAnswerText(t)} The toast that tells him could not be shown (${why}), so your line is the only place he learns it.`
