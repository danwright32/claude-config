// #863: whether Claude hands Dan a step in prose ("the one thing still waiting on you is the
// migration command from my earlier message"), which he may never see once it scrolls away. Read
// from what Claude wrote, never from Dan's message: since #1608 every message of the turn, not only
// the last. Narrow on purpose: each phrase was measured on the turns of the 30 days before it shipped
// on this Mac (docs/mods-design.md "Manual steps"), so a phrase is added only with a measurement
// behind it (L172, L36).

import { ACTION } from './page.ts'

// Where a sentence, or a numbered or bulleted line, begins, so an imperative is one said to Dan
// ("Click **Deploy**", "2. Choose **Carnegie Hall**"), not the word inside a sentence about code.
const LEAD = String.raw`(?<=^|[.!?]["')\]*_]*\s+|^\s*(?:\d+[.)]\s*|[-*]\s+)?(?:\*\*)?)`

// #1613: read over whole turns, "waiting on you" was said of a decision, a question, a card, a kind
// of thing ("replies waiting on you") or this check itself as often as of a step: of the 43 turns of
// the 30 days to 2026-10-24 it fired in, 16 handed Dan a step and 27 did not. So it counts only where
// it hands something over and what it hands over is a step (docs/mods-design.md "Manual steps").
const WAITING = /\bwaiting on you\b/gi

// Where the phrase hands something over: leading its line or sentence ("**Still waiting on you:**",
// "Waiting on you: run ..."), said of a thing ("the deploy is waiting on you", "which leaves it
// waiting on you"; never "something is" or "what is", talk of the state in general), or naming the thing
// ("the one thing still waiting on you is ..."; never "things waiting on you go amber"). Everywhere
// else it describes a kind of thing: "replies waiting on you", "what's waiting on you".
const LEADS = /(?:^|[.!?]["')\]*_]*\s+|\n)\s*(?:\d+[.)]\s*|[-*]\s+)?(?:\*\*)?(?:(?:still|also|and|now)\s+)?$/i
const ADVERBS = String.raw`(?:(?:still|now|also|only|all)\s+)*`
const SAID_OF = new RegExp(String.raw`(?<!\b(?:something|anything|someone|anyone|what|whatever)\s+)\b(?:is|are|it|it's|that's|they're)\s+${ADVERBS}$`, 'i')
const THING = new RegExp(String.raw`\bthings?\s+${ADVERBS}$`, 'i')
const THING_NAMED = /^\s*(?:\*\*)?\s*(?:is\b|are\b|[:,.(]|$)/i

// What makes it a step: one of these, from the start of the phrase's sentence to the end of its
// paragraph (or of the list a heading ending in a colon introduces), before any of DECISION.
const STEP = /\b(?:run|running|apply|paste|click|choose|press|tap|tick|type|try|use|install|reinstall|relaunch|restart|quit|open|fill in|sign in|log in|export|send|check|checks|test|tests|command|commands|steps|password|look at|confirm|set|approve|allow|enter|select|toggle|turn (?:on|off)|update|sync)\b/i
// A decision, a question or an OK waits on Dan too, but is answered in the conversation, not on a card.
const DECISION = /\b(?:decision|decisions|decide|decided|answer|question|questions|reply|your OK|go-ahead|sign-off|sign off|choice|whether)\b/i
// How far past the phrase a step may be named.
const REACH = 500

// Inside a quotation opened earlier on its line: quoted, not said to Dan ("a sentence like "it's
// waiting on you" never fires"). The quote right before the phrase is QUOTED's, below. #1613 for
// "waiting on you", #1680 for #863's other four.
const quotedOnLine = (before: string): boolean => {
  const line = before.slice(before.lastIndexOf('\n') + 1)
  const count = (rx: RegExp) => (line.match(rx) ?? []).length
  return count(/"/g) % 2 === 1 || count(/“/g) > count(/”/g)
}

/** Whether "waiting on you" at `at` to `end` in `plain` hands Dan a step (#1613). */
const handsOverAStep = (plain: string, at: number, end: number): boolean => {
  const before = plain.slice(0, at)
  const after = plain.slice(end)
  if (!LEADS.test(before) && !SAID_OF.test(before) && !(THING.test(before) && THING_NAMED.test(after))) return false
  if (quotedOnLine(before)) return false
  // Said of the steps card, which already shows Dan the step ("the card is the only thing still
  // waiting on you"); a heading's colon ends the sentence, so a list under it is not this sentence.
  const sentenceEnd = after.search(/[.!?:\n]/)
  const sentence = plain.slice(Math.max(before.search(/[^.!?:\n]*$/), 0), sentenceEnd < 0 ? plain.length : end + sentenceEnd)
  if (/\bcard\b/i.test(sentence)) return false
  const lineEnd = after.indexOf('\n')
  const restOfLine = lineEnd < 0 ? after : after.slice(0, lineEnd)
  const from = lineEnd >= 0 && /:\s*(?:\*\*)?\s*$/.test(restOfLine) ? lineEnd + (after.slice(lineEnd).match(/^\s*/)?.[0].length ?? 0) : 0
  const paragraphEnd = after.slice(from).search(/\n\s*\n/)
  const until = Math.min(paragraphEnd < 0 ? after.length : from + paragraphEnd, REACH)
  const said = plain.slice(Math.max(before.search(/[^.!?\n]*$/), 0), end + until)
  const step = said.search(STEP)
  const decision = said.search(DECISION)
  return step >= 0 && (decision < 0 || step < decision)
}

// #1680: "once you ..." was said of an approval that is a decision ("once you approve the plan",
// "once you approve a lesson in the picker") and of the card's own button ("drops it once you click
// Done") in 3 of the 7 turns of the 30 days to 2026-10-25 it fired in. Neither is a step to pin: the
// first is answered in the conversation, the second is the card itself.
const ONCE_YOU = /\bonce you(?:'ve| have)? (?:run|ran|apply|applied|paste|pasted|click|clicked|approve|approved)\b/gi
// What an approval is of when it is a decision, within the next few words of its sentence.
const APPROVED_DECISION = /^\s+(?:(?:the|this|that|a|an|your|my|its)\s+)?(?:[\w-]+\s+){0,2}?(?:plan|plans|proposal|lesson|lessons|picker|idea|ideas|design|approach|option|options|direction|wording|spec)\b/i
// The steps card's own Done button, clicked to mark a step done.
const CLICK_DONE = /^\s+(?:on\s+)?(?:the\s+)?(?:\*\*|["\u201c`])?Done\b/
const onceYouIsAStep = (plain: string, at: number, end: number): boolean => {
  if (quotedOnLine(plain.slice(0, at))) return false
  const verb = plain.slice(at, end).split(/\s+/).at(-1) ?? ''
  const after = plain.slice(end)
  if (/^approved?$/i.test(verb) && APPROVED_DECISION.test(after)) return false
  if (/^click(?:ed)?$/i.test(verb) && CLICK_DONE.test(after)) return false
  return true
}

// #1680: "you need to" was said of a later, conditional need ("I'll tell you before you need to
// click Allow", about a sign in still to come), which is no step yet; and #863's phrases were quoted
// in talk about this check. A need introduced by before, when, if, until or after is not one now.
const YOU_NEED_TO = /\byou(?:'ll| will)? need to (?:run|paste|apply|click|approve)\b/gi
const LATER_NEED = /\b(?:before|when|whenever|if|until|after|in case)\s+$/i
const youNeedToIsAStep = (plain: string, at: number): boolean =>
  !quotedOnLine(plain.slice(0, at)) && !LATER_NEED.test(plain.slice(0, at))
const NEEDS_YOU_TO = /\bneeds? you to (?:run|paste|apply|click|approve|enter|sign in|log in)\b/gi
const YOUR_STEP = /\byour (?:manual )?step\b/gi
const notQuoted = (plain: string, at: number): boolean => !quotedOnLine(plain.slice(0, at))

// #1811: numbered steps handed to Dan, a numbered line that begins with something a person does at a
// screen, counted only where the message holds two or more. Measured on 2026-10-27 over the 19,420
// messages Claude wrote in this Mac's transcripts: 20 held two or more such lines, and every one of
// the 20 was steps for Dan. "add", "update" and "run" are left out, since they lead Claude's own plans.
const NUMBERED = new RegExp(String.raw`^[ \t]*(?:\d+[.)]|step \d+[.:])[ \t]+(?:\*\*)?${ACTION}\b`, 'gim')
const numberedTwice = (plain: string): boolean => (plain.match(NUMBERED) ?? []).length >= 2

// #1955: a file edit handed to Dan that names no command, page or terminal ("Put allow or forbid in
// the third column and save, then tell me."), told by how it closes: asking to be told, or saving.
// Measured over the 15,216 messages Claude wrote in this Mac's transcripts of the 30 days to
// 2026-10-30 (docs/mods-design.md "Manual steps"). An imperative to edit, mark, put or write leading a
// sentence fired 3 times, all false (Claude's own plan, "Write the file less often"), and "save"
// alone 3, all false (Claude's own bullet, a Save button), so neither is here.
// "Tell me it's done", a sentence of its own: 1 fired, a step.
const TELL_ME_DONE = new RegExp(`${LEAD}tell me (?:it's|it is|that it's|that it is|that's) (?:done|saved|finished|in place|filled in)\\b`, 'gim')
// ", then tell me" after an instruction: 4 fired, all steps, none caught before.
const THEN_TELL_ME = /,? then tell me\b/gi
// "Save the file", "Save your changes", leading a sentence: none fired in the 30 days.
const SAVE_FILE = new RegExp(`${LEAD}save (?:the|this|that|your) (?:file|sheet|document|changes|edits)\\b`, 'gim')
// The save key handed over: "Press **Cmd+S**", "save with Cmd+S", "(Cmd+S)": 5 fired, all steps.
// Case kept and the plus required: without them "(commands, git and writes)" fired 3 times.
const CMD_S = /(?:\b[Pp]ress(?:ing)?\s+|\b[Ww]ith\s+|\()(?:\*\*)?(?:(?:Cmd|Command|CMD)\s*[+-]\s*|⌘\s*)S\b/g
// Said of what Claude, or something else, will do or did ("The watcher will wait, then tell me",
// "I saved it with Cmd+S"), or of a later, conditional press ("when you press Cmd+S"): no step now.
const NOT_DANS = /(?:\b(?:I|I've|I'd|I'm|We|we|We've|we've)\b|(?<!\byou )\b(?:will|would|should)\b|(?<!\byou)'ll\b)/
const LATER = /\b(?:before|when|whenever|if|until|after|once|in case)\s+(?:you\s+)?$/i
const dansNow = (plain: string, at: number): boolean => {
  const before = plain.slice(0, at)
  const sentence = before.slice(before.search(/[^.!?\n]*$/))
  return !quotedOnLine(before) && !NOT_DANS.test(sentence) && !LATER.test(sentence)
}

// What a phrase must also be, beyond being there, to count.
const ALSO: ReadonlyMap<RegExp, (plain: string, at: number, end: number) => boolean> = new Map([
  [WAITING, handsOverAStep],
  [ONCE_YOU, onceYouIsAStep],
  [YOU_NEED_TO, youNeedToIsAStep],
  [NEEDS_YOU_TO, notQuoted],
  [YOUR_STEP, notQuoted],
  [NUMBERED, numberedTwice],
  [THEN_TELL_ME, dansNow],
  [CMD_S, dansNow],
])

// Each says a step is Dan's to do. "waiting on you" never matches "waiting on your", and a step is
// one he runs, pastes, applies, clicks or approves, never a merge or a review Claude does itself.
export const PHRASES: readonly RegExp[] = [
  // #863's five.
  WAITING,
  ONCE_YOU,
  YOU_NEED_TO,
  NEEDS_YOU_TO,
  YOUR_STEP,
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
  // #1811: two or more numbered steps that each begin with an action at a screen.
  NUMBERED,
  // #1955: a file edit handed over, told by how it closes.
  TELL_ME_DONE,
  THEN_TELL_ME,
  SAVE_FILE,
  CMD_S,
]

// #1811: Claude saying plainly that none of the steps it handed over are Dan's to do now, which
// answers both this mod's refusals (a step left in prose and a page of steps), since an acknowledgement
// must be read by every rule that asks for it (L330). The refusals ask for "None of these steps are
// yours to do now."; a few plain variants of it count too, and none quoted. Anchored on "yours to do
// now" led by "none of" or "nothing", so a sentence that hands a step over never reads as one.
const NONE_NOW = /\b(?:none of (?:these|those|the|its|them|this page's|the page's)(?: (?:steps?|edits?|changes?|items?|checks?))?(?: on (?:the|this|that) page)?|nothing(?: here| on (?:the|this|that) page)?) (?:is|are) (?:still )?yours to do now\b/gi

/** Whether any of `texts`, Claude's messages of the turn, says none of the steps are Dan's to do now. */
export const saysNoneNow = (texts: readonly string[]): boolean =>
  texts.some(text => {
    const plain = text.replace(/’/g, "'")
    return [...plain.matchAll(NONE_NOW)].some(m => !quotedOnLine(plain.slice(0, m.index ?? 0)))
  })

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
      if (!(ALSO.get(rx)?.(plain, at, at + m[0].length) ?? true)) continue
      if (!best || at < best.at) best = { at, phrase: text.slice(at, at + m[0].length) }
      break
    }
  }
  return best?.phrase ?? null
}
