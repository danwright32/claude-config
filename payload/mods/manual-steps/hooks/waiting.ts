// #863: whether Claude hands Dan a step in prose ("the one thing still waiting on you is the
// migration command from my earlier message"), which he may never see once it scrolls away. Read
// from what Claude wrote, never from Dan's message: since #1608 every message of the turn, not only
// the last. Narrow on purpose: each phrase was measured on the turns of the 30 days before it shipped
// on this Mac (docs/mods-design.md "Manual steps"), so a phrase is added only with a measurement
// behind it (L172, L36).

// Where a sentence, or a numbered or bulleted line, begins, so an imperative is one said to Dan
// ("Click **Deploy**", "2. Choose **Carnegie Hall**"), not the word inside a sentence about code.
const LEAD = String.raw`(?<=^|[.!?]["')\]*_]*\s+|^\s*(?:\d+[.)]\s*|[-*]\s+)?(?:\*\*)?)`

// Each says a step is Dan's to do. "waiting on you" never matches "waiting on your", and a step is
// one he runs, pastes, applies, clicks or approves, never a merge or a review Claude does itself.
export const PHRASES: readonly RegExp[] = [
  // #863's five.
  /\bwaiting on you\b/gi,
  /\bonce you(?:'ve| have)? (?:run|ran|apply|applied|paste|pasted|click|clicked|approve|approved)\b/gi,
  /\byou(?:'ll| will)? need to (?:run|paste|apply|click|approve)\b/gi,
  /\bneeds? you to (?:run|paste|apply|click|approve|enter|sign in|log in)\b/gi,
  /\byour (?:manual )?step\b/gi,
  // #1608: "One thing is still yours to do", "installing is yours to run". Never "yours to decide",
  // "to make" or "to pick", which hand Dan a decision, not a step.
  /\byours to (?:do|run|apply|paste|click|approve|check|finish|install)\b/gi,
  // "The one step left is yours", "one check is still yours"; a step described ("while the open
  // step is yours") is not one left.
  /\b(?:step|check) (?:left is|is still|still open is) yours\b/gi,
  // "Tell me when it's done", said to Dan as a sentence of its own; "the watcher will tell me when"
  // is Claude's own wait, and "tell me when you'd like" a preference.
  new RegExp(`${LEAD}tell me (?:when|once)\\b(?! you(?:'d| would) like| you want| you're (?:ready|not))`, 'gim'),
  // "The only thing still open is the Settings swap I described above."
  /\bstill open\b[^.!?\n]{0,100}\b(?:described|listed|gave|given) (?:above|earlier)\b/gi,
  // An imperative click on a named thing: "Click **Deploy**", "press "Save"", "click the ×".
  new RegExp(`${LEAD}(?:click|press|tap|select|choose)(?=(?: on)?(?: the)? (?:\\*\\*|"|\u201c|\`|\u00d7))`, 'gim'),
  // Something to type or paste, named in code or bold: "Type `/goal clear`", "Paste it with the `!`".
  // Never the type check, which leads a sentence about the compiler.
  new RegExp(`${LEAD}(?:type|paste)\\b(?![ -]?check)(?=[^.!?\\n]{0,60}(?:\`|\\*\\*))`, 'gim'),
  // A place in an app's settings, leading the sentence: "In Settings, Venues, Carnegie Hall, ...".
  new RegExp(`${LEAD}in (?:System )?Settings(?=\\s*(?:,|>|\u203a|\u2192))`, 'gim'),
  // "Go to the **Venues** tab and select **Carnegie Hall**."
  /\bgo to\b[^.!?\n]{1,100}\b(?:and|then) (?:click|tap|press|select|choose|type|paste|turn (?:on|off)|toggle)\b/gi,
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
export const waitingPhrase = (text: string): string | null => phraseIn(text, PHRASES)

/** The earliest of `phrases` in `text` not negated or quoted, as written; null when there is none. */
export const phraseIn = (text: string, phrases: readonly RegExp[]): string | null => {
  // A curly apostrophe is one character, as the straight one is, so positions stay the same.
  const plain = text.replace(/’/g, "'")
  let best: { at: number; phrase: string } | null = null
  for (const rx of phrases) {
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
