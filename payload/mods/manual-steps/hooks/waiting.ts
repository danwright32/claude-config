// #863: whether Claude's own final message hands Dan a step in prose ("the one thing still waiting
// on you is the migration command from my earlier message"), which he may never see once it scrolls
// away. Read from what Claude wrote, never from Dan's message. Narrow on purpose: measured on every
// turn final message of the last 30 days on this Mac before it shipped (docs/mods-design.md
// "Manual steps"), so a phrase is added only with a measurement behind it (L172, L36).

// Each says a step is Dan's to do. "waiting on you" never matches "waiting on your", and a step is
// one he runs, pastes, applies, clicks or approves, never a merge or a review Claude does itself.
const PHRASES: readonly RegExp[] = [
  /\bwaiting on you\b/gi,
  /\bonce you(?:'ve| have)? (?:run|ran|apply|applied|paste|pasted|click|clicked|approve|approved)\b/gi,
  /\byou(?:'ll| will)? need to (?:run|paste|apply|click|approve)\b/gi,
  /\bneeds? you to (?:run|paste|apply|click|approve|enter|sign in|log in)\b/gi,
  /\byour (?:manual )?step\b/gi,
]

// The phrase said the other way round: "nothing else is waiting on you", "this is no longer
// waiting on you". Only a negation attached to the phrase counts, in the same clause and within
// its last few words, so "the deploy did not finish, so it's waiting on you" still fires.
const NEGATED = /\b(?:nothing|not|no longer|none|no one|never)\b|n't\b/i
const NEGATION_WORDS = 5
// The phrase quoted as the name of a thing ("is waiting on you", the notification), not said to Dan.
const QUOTED = /["“'‘`](?:(?:is|are|still|now)\s+)*$/i
// Where the clause holding the phrase starts.
const BOUNDARY = /[.!?;:,\n][^.!?;:,\n]*$/

/** The phrase in `text` saying a step waits on Dan, as written; null when there is none. */
export const waitingPhrase = (text: string): string | null => {
  // A curly apostrophe is one character, as the straight one is, so positions stay the same.
  const plain = text.replace(/’/g, "'")
  let best: { at: number; phrase: string } | null = null
  for (const rx of PHRASES) {
    for (const m of plain.matchAll(rx)) {
      const at = m.index ?? 0
      const before = plain.slice(0, at)
      if (QUOTED.test(before)) continue
      const clause = before.slice((BOUNDARY.exec(before)?.index ?? -1) + 1)
      if (NEGATED.test(clause.trim().split(/\s+/).slice(-NEGATION_WORDS).join(' '))) continue
      if (!best || at < best.at) best = { at, phrase: text.slice(at, at + m[0].length) }
      break
    }
  }
  return best?.phrase ?? null
}
