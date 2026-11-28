// #3652: a slash command Dan has to type himself, handed over in a reply. On 2026-11-25 a session
// told Dan his next move was to start `/plan-council`, with the brief in a code block near the end of
// a long reply, while the card it pinned that turn held two other steps. He did those, the card
// closed, and the command was forgotten. The prose check (waiting.ts) knew no phrase for "start
// `/plan-council`", and any unfinished step on the card answered it in any case. So a command handed
// over is recognised here, and it is answered only by an unfinished step that names it.
//
// Only a command HANDED to Dan counts: one named, explained, offered as an option or run by Claude
// passes. Measured over this Mac's session records of the 30 days to 2026-11-25, and again on
// 2026-11-27 after the review of pull request 3677, whose two lists of wordings (hand overs that
// passed, and replies held that handed nothing over) tests/typed.test.ts holds together
// (docs/mods-design.md "Manual steps").

import type { StepsCard } from '../types/index.d.ts'
import { dansNow, LATER, LEAD, NOT_DANS, quotedOnLine, sentenceStart } from './waiting.ts'

// A slash command's name: lower case letters, digits, hyphens and underscores (a connector's command,
// "/mcp__github__review"), with a plugin's prefix allowed ("/superpowers:brainstorming"). It ends at
// white space, a closing mark or the end, or at a full stop or colon that ends a sentence; never at
// another slash or a dot inside a word, which is a path or a file ("/tmp/build.log", "/usr/bin/true").
const NAME = String.raw`/[a-z][a-z0-9_-]*(?::[a-z0-9][a-z0-9_-]*)?`
const ENDS = String.raw`(?![\w/-]|[.:][\w/])`

// A fenced code block whose first line is a slash command: a command laid out to be copied.
const FENCED = new RegExp(String.raw`^[ \t]*\`\`\`[\w-]*[ \t]*\n[ \t]*(${NAME})${ENDS}`, 'gm')

// What marks a command written in a reply: a code span, bold, or quotes, two of them together
// ("**`/compact`**"), or nothing.
const MARK = String.raw`(?:\*\*|\`|"|“){0,2}`
// An imperative to Dan that leads its sentence or line: "Type `/reload-plugins`", "Next, run
// `/sync-config`", "1. Start **/plan-lite**". Not "use" or "enter": they name a skill, a folder or
// a web address ("use the `/db-apply` skill", "Use `/tmp`", "Enter `/admin` after the domain"),
// which is what the review of pull request 3677 found them holding.
const VERBS = String.raw`(?:type|run|start|paste|invoke|launch|kick off)`
const OBJECT = String.raw`\s+(?:the\s+)?(?:command\s+)?${MARK}(${NAME})${ENDS}`
// A sentence's start, or the words after a label's colon on its line ("**One thing only you can
// do:** type `/reload-plugins`", "To plan it: type `/plan-lite`").
// A clause led by "so" after a comma counts too ("the old copy is still loaded, so run ...").
const START = String.raw`(?:${LEAD}|(?<=:(?:\*\*)?[ \t]+)|(?<=[,;][ \t]+)(?=so\s))`
// Words that may come before the imperative without making it anything else: a filler, a moment
// that is Dan's to choose, or the steps before it ("After those two, start `/plan-council`").
const WHEN_YOU = String.raw`when you(?: can| get a moment| have a moment| are ready|'re ready| are back|'re back| are done|'re done)`
const AFTER_THOSE = String.raw`after (?:that|this|those|these|both)(?: (?:two|three|four|steps?))?|once (?:that|this|those|these|both) (?:is|are) done`
const PREAMBLE = String.raw`(?:(?:please|so|and|now|next|then|first|finally|also|just|when convenient|${WHEN_YOU}|${AFTER_THOSE}),?\s+)*`
const IMPERATIVE = new RegExp(String.raw`${START}${PREAMBLE}${VERBS}${OBJECT}`, 'gim')
// "To clear the goal, type `/goal clear`".
const TO_DO = new RegExp(String.raw`${LEAD}to [^,:.!?\n*]{1,60}[,:](?:\*\*)?\s+(?:please\s+)?${VERBS}${OBJECT}`, 'gim')
// Said of Dan inside a sentence: "until you run `/reload-plugins`", "needs you to type", "you should
// now run", "remember to type". Never "you can" or "you could", which offer it.
const YOURS = new RegExp(String.raw`\b(?:until you|till you|you(?:'ll| will)? need to|you have to|you (?:should|must)|needs? you to|remember to)\s+(?:(?:now|next|then|still|just|first|also)\s+)?${VERBS}${OBJECT}`, 'gi')
// Naming the next move as Dan's: "Your next move is to start `/plan-council`", "Your next step is
// `/plan-council`", "Your next move: `/plan-council`". After "to", the verbs above and "begin", which
// is said of a command and never of a folder or an address. Not "use", here as anywhere: "Your next
// step is to use `/tmp`" names a folder (second review of pull request 3677), so "Your next step is
// to use `/plan-council`" is missed, a hand over said in a wording no turn of the count used.
const NEXT_MOVE = new RegExp(String.raw`\byour (?:next|only|last) (?:move|step|thing to do)\b[^.!?\n]{0,40}?(?:\bis|:(?:\*\*)?)\s+(?:to\s+(?:${VERBS}|begin)\s+)?(?:the\s+)?(?:command\s+)?${MARK}(${NAME})${ENDS}`, 'gi')
// A label saying the move is Dan's, then what to do with a command marked as one: "Next is yours:
// paste the brief below into `/plan-council`", "The next move is yours: start planning with
// `/plan-council`".
const IS_YOURS = new RegExp(String.raw`\b(?:is|are)\s+yours:(?:\*\*)?\s+[^.!?\n]{0,60}?(?:\*\*|\`){1,2}(${NAME})${ENDS}`, 'gi')
// Sent somewhere to type it: "Open a new session and run `/plan-council` there".
const CHAINED = new RegExp(String.raw`${LEAD}(?:open|start|begin)\s+(?:a|another|the)\s+(?:(?:new|fresh|second|other|next)\s+)?(?:session|terminal|window|tab|chat|conversation)\b[^.!?\n]{0,40}?\b(?:and|then)\s+(?:then\s+)?${VERBS}${OBJECT}`, 'gim')

// Said as an offer or a condition, so a choice Dan may never take, not a step: "if you want",
// "you could", "whenever you like", "if the scope grows", "later".
const OFFER = /\b(?:if|unless|in case|whenever|could|might|would you|want me|shall I|should I|prefer|at some point|later|some time|sometime|optionally|alternatively)\b/i
// A standing rule, not a step now: "Run `/no-ai-tells` on anything other people will read". Never
// "every" or "any" alone, which a hand over says too ("in every open session").
const STANDING = /\b(?:anything|always|every time|each time|any time|anytime|(?:after|before) (?:each|every))\b/i
// Said of a web address, where a slash leads a route: "Start `/login` and watch the redirect". Told
// by what the sentence says of it, never by the name, since `/login` is a command too.
const WEB = /\b(?:endpoints?|routes?|urls?|redirects?|domains?|localhost|https?)\b/i
// Shown as a wording, not said to Dan: "(an example the check holds)".
const EXAMPLE = /\b(?:examples?|for instance)\b|\be\.g\./i
// Said of what Dan already did: "You typed this a minute ago:".
const PAST = /\byou(?:'ve| have)?\s+(?:(?:already|just)\s+)?(?:typed|ran|pasted|started|entered|sent)\b/i
// A label or a line that speaks to Dan, whatever else it says: "One thing I need from you:".
const ADDRESSED = /\b(?:you|your|yours)\b/i
// The command named as a skill, which the session runs: "run the `/db-apply` skill".
const A_SKILL = /^(?:\*\*|`|"|”){0,2}\s+skill\b/i
// Where the sentence goes on to another thing, whose "if" is not the command's: "Type
// `/reload-plugins`, then tell me if the card shows the new text".
const GOES_ON = /;|,?\s+(?:and\s+)?then\b/
// A numbered or bulleted line, and a line that is nothing but "Plan:", which heads the session's own.
const ITEM = /^[ \t]*(?:\d+[.)]|[-*])\s/
const PLAN_LABEL = /^\W*(?:(?:my|the|our)\s+)?plan\W*$/i

// Each fenced code block of `plain`, from its opening fence to the end of its closing one.
const fences = (plain: string): [number, number][] => {
  const found: [number, number][] = []
  let open = -1
  let at = 0
  for (const line of plain.split('\n')) {
    if (/^[ \t]*(?:```|~~~)/.test(line)) {
      if (open < 0) open = at
      else {
        found.push([open, at + line.length])
        open = -1
      }
    }
    at += line.length + 1
  }
  if (open >= 0) found.push([open, plain.length])
  return found
}

// Where the sentence holding the words from `at` to `end` starts and ends.
const sentenceSpan = (plain: string, at: number, end: number): [number, number] => {
  const rest = plain.slice(end)
  const stop = rest.search(/[.!?](?=\s|$)|\n/)
  return [sentenceStart(plain.slice(0, at)), stop < 0 ? plain.length : end + stop + 1]
}

// The line that introduces the list holding `at`: the nearest line above its items that is not one
// of them, when it ends in a colon. Empty when `at` is not in a list, or nothing introduces it.
const introOf = (plain: string, at: number): string => {
  const lines = plain.slice(0, at).split('\n')
  if (!ITEM.test(lines.pop() ?? '')) return ''
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i] as string
    if (ITEM.test(line) || !line.trim() || /^[ \t]+\S/.test(line)) continue
    return /:\s*(?:\*\*)?\s*$/.test(line) ? line : ''
  }
  return ''
}

/** Whether the words from `at` to `end`, already found to be said to Dan, hand him the command now. */
const handedOver = (plain: string, at: number, end: number, blocks: readonly [number, number][]): boolean => {
  // File text shown in a code block, and a block quote, are shown to Dan, not said to him.
  if (blocks.some(([from, to]) => at >= from && at < to)) return false
  if (/^[ \t]*>/.test(plain.slice(plain.lastIndexOf('\n', at - 1) + 1, at))) return false
  if (A_SKILL.test(plain.slice(end))) return false
  // A list the line above it says is the session's own, or examples: "Plan:", "What I will do next:".
  const intro = introOf(plain, at)
  if (intro && !ADDRESSED.test(intro) && (NOT_DANS.test(intro) || PLAN_LABEL.test(intro) || EXAMPLE.test(intro))) return false
  const [from, to] = sentenceSpan(plain, at, end)
  const sentence = plain.slice(from, to)
  if (/\?\s*$/.test(sentence)) return false
  // Called an example in its own sentence, or in the aside in brackets right after it on its line.
  const aside = /^[ \t]*\(([^)\n]*)\)/.exec(plain.slice(to))?.[1] ?? ''
  if (EXAMPLE.test(sentence) || EXAMPLE.test(aside)) return false
  // Judged on the command's own clause: an aside in brackets and what follows "then" are other things.
  const after = plain.slice(end, to).replace(/\([^)\n]*\)/g, ' ')
  const goesOn = after.search(GOES_ON)
  const clause = plain.slice(from, end) + (goesOn < 0 ? after : after.slice(0, goesOn))
  return !OFFER.test(clause) && !STANDING.test(clause) && !WEB.test(clause)
}

// What comes before `at` in its sentence: a label, or the clause before "so".
const ledBy = (plain: string, at: number): string => {
  const before = plain.slice(0, at)
  return before.slice(sentenceStart(before))
}

// An imperative is said to whoever reads it. After "so" it is Dan's whatever the clause before it
// says ("I merged the fix, so run ..."); after a label it is Dan's when the label speaks to him
// ("One thing I need from you:"), and the session's own when the label speaks only of itself.
const imperativeIsDans = (plain: string, at: number, said: string): boolean => {
  if (quotedOnLine(plain.slice(0, at))) return false
  const led = ledBy(plain, at)
  if (/^so\s/i.test(said) || ADDRESSED.test(led)) return true
  return !NOT_DANS.test(led) && !LATER.test(led)
}
// "You" names Dan, so what the sentence said before it does not make the command Claude's ("The old
// copy will stay loaded until you run ..."); "remember to" names nobody, so there it still can. A
// later, conditional need is no step now ("I'll tell you when you need to run ...").
const yoursIsDans = (plain: string, at: number, said: string): boolean => {
  if (quotedOnLine(plain.slice(0, at))) return false
  const led = ledBy(plain, at)
  return !LATER.test(led) && !(/^remember/i.test(said) && NOT_DANS.test(led))
}

// Each pattern with what makes its match one said to Dan.
const SAID_TO_DAN: readonly [RegExp, (plain: string, at: number, said: string) => boolean][] = [
  [IMPERATIVE, imperativeIsDans],
  [NEXT_MOVE, dansNow],
  [TO_DO, dansNow],
  [YOURS, yoursIsDans],
  [IS_YOURS, dansNow],
  [CHAINED, dansNow],
]

// The line before a fenced block, blank lines passed over, that introduces it ("with this brief:"),
// and where that line starts.
const leadIn = (plain: string, at: number): { said: string; from: number } => {
  const before = plain.slice(0, at).replace(/\s+$/, '')
  const from = before.lastIndexOf('\n') + 1
  return { said: before.slice(from), from }
}

// The patterns run without case so "Type" and "type" both lead, which lets their NAME match upper
// case too; a name is held to lower case here, so a folder ("Run `/Applications`") is never a command.
const LOWER = new RegExp(`^${NAME}$`)

// A command handed over: where it is named, and the words that hand it over (its sentence, or its
// code block with the line that introduces it).
type Handed = { at: number; from: number; to: number; command: string }

const handed = (plain: string): Handed[] => {
  const blocks = fences(plain)
  const found: Handed[] = []
  for (const [rx, isDans] of SAID_TO_DAN) {
    for (const m of plain.matchAll(rx)) {
      const at = m.index ?? 0
      const end = at + m[0].length
      if (!isDans(plain, at, m[0]) || !handedOver(plain, at, end, blocks)) continue
      const [from, to] = sentenceSpan(plain, at, end)
      found.push({ at, from, to, command: m[1] as string })
    }
  }
  for (const m of plain.matchAll(FENCED)) {
    const at = m.index ?? 0
    // Only a block's opening fence: a closing one followed by a line that starts with a command is not one.
    const block = blocks.find(([from]) => from === at)
    if (!block) continue
    // Judged by the line that introduces it: a block shown as something Claude ran, offered, already
    // typed, a web address or an example is not handed over.
    const { said, from } = leadIn(plain, at)
    const line = said.trim()
    if (line && (!dansNow(line, line.length) || /^>/.test(line) || /\?\s*$/.test(line) || [OFFER, PAST, WEB, EXAMPLE].some(rx => rx.test(line)))) continue
    found.push({ at, from, to: block[1], command: m[1] as string })
  }
  return found.filter(f => LOWER.test(f.command)).sort((a, b) => a.at - b.at)
}

// A curly apostrophe is one character, as the straight one is, so positions stay the same.
const straight = (text: string): string => text.replace(/’/g, "'")

/** The slash commands `text` hands Dan to type, each once, in the order first handed over. */
export const typedCommands = (text: string): string[] => [...new Set(handed(straight(text)).map(f => f.command))]

// The sentence right after a hand over asking to be told that same command is done: "Tell me when
// it is done", "Tell me once it's loaded", "Tell me when you have run it". Its "it" can only be the
// command just handed over, so it is that step, not another (second review of pull request 3677). A
// report back on anything else ("when you have clicked **Approve**") is another step.
const REPORTS_BACK = /^\s+(?:please\s+)?tell me\s+(?:(?:when|once)\s+(?:it|that|this)\b|(?:when|once)\s+you(?:'ve| have)\s+(?:done|run|typed|finished)\s+(?:it|that|this)\b|(?:that\s+)?(?:it's|it is|that's|that it's|that it is)\s+(?:done|finished|loaded|in place)\b)[^.!?\n]*(?:[.!?](?=\s|$))?/i

/**
 * `text` without the words that hand over any of `commands`, so what is left can be asked whether
 * it hands Dan another step: one step gets one ask (review of pull request 3677). The words that hand
 * a command over are its sentence, or its code block and the line that introduces it, with the
 * sentence after them when that only asks to be told the command is done.
 */
export const apartFromTyped = (text: string, commands: readonly string[]): string => {
  const plain = straight(text)
  let left = ''
  let kept = 0
  // In order, each span taken once: a sentence and the code block it introduces overlap.
  for (const f of handed(plain).filter(f => commands.includes(f.command)).sort((a, b) => a.from - b.from)) {
    if (f.from > kept) left += plain.slice(kept, f.from)
    kept = Math.max(kept, f.to + (REPORTS_BACK.exec(plain.slice(f.to))?.[0].length ?? 0))
  }
  return left + plain.slice(kept)
}

const escaped = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/** Whether an unfinished step of `card` names `command`, in its title, value, actions or location. */
export const onCard = (card: StepsCard | null, command: string): boolean => {
  if (!card) return false
  const rx = new RegExp(`(?<![\\w/])${escaped(command)}${ENDS}`)
  return card.steps.some(s => {
    if (s.finished) return false
    const clicks = Array.isArray(s.clicks) ? s.clicks : s.clicks ? [s.clicks] : []
    return [s.title, s.value ?? '', s.location ?? '', ...clicks].some(t => rx.test(t))
  })
}
