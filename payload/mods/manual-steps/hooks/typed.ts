// #3652: a slash command Dan has to type himself, handed over in a reply. On 2026-11-25 a session
// told Dan his next move was to start `/plan-council`, with the brief in a code block near the end of
// a long reply, while the card it pinned that turn held two other steps. He did those, the card
// closed, and the command was forgotten. The prose check (waiting.ts) knew no phrase for "start
// `/plan-council`", and any unfinished step on the card answered it in any case. So a command handed
// over is recognised here, and it is answered only by an unfinished step that names it.
//
// Only a command HANDED to Dan counts: one named, explained, offered as an option or run by Claude
// passes. Measured over this Mac's session records of the 30 days to 2026-11-25 (docs/mods-design.md
// "Manual steps").

import type { StepsCard } from '../types/index.d.ts'
import { dansNow, LEAD, quotedOnLine, sentenceStart } from './waiting.ts'

// A slash command's name: lower case letters, digits and hyphens, with a plugin's prefix allowed
// ("/superpowers:brainstorming"). It ends at white space, a closing mark or the end, or at a full stop
// or colon that ends a sentence; never at another slash or a dot inside a word, which is a path or a
// file ("/tmp/build.log", "/usr/bin/true").
const NAME = String.raw`/[a-z][a-z0-9-]*(?::[a-z0-9][a-z0-9-]*)?`
const ENDS = String.raw`(?![\w/-]|[.:][\w/])`

// A fenced code block whose first line is a slash command: a command laid out to be copied.
const FENCED = new RegExp(String.raw`^[ \t]*\`\`\`[\w-]*[ \t]*\n[ \t]*(${NAME})${ENDS}`, 'gm')

// What marks a command written in a reply: a code span, bold, or quotes, or nothing.
const MARK = String.raw`(?:\*\*|\`|"|“)?`
// An imperative to Dan that leads its sentence or line: "Type `/reload-plugins`", "Next, run
// `/sync-config`", "1. Start **/plan-lite**".
const VERBS = String.raw`(?:type|run|start|paste|enter|use|invoke|launch|kick off)`
const OBJECT = String.raw`\s+(?:the\s+)?(?:command\s+)?${MARK}(${NAME})${ENDS}`
// A sentence's start, or the words after a label's colon on its line ("**One thing only you can
// do:** type `/reload-plugins`", "To plan it: type `/plan-lite`").
// A clause led by "so" after a comma counts too ("the old copy is still loaded, so run ...").
const START = String.raw`(?:${LEAD}|(?<=:(?:\*\*)?[ \t]+)|(?<=[,;][ \t]+)(?=so\s))`
// Words that may come before the imperative without making it anything else.
const PREAMBLE = String.raw`(?:(?:please|so|and|now|next|then|first|finally|also|when convenient|when you (?:can|get a moment|have a moment|are ready|'re ready|are back|'re back)),?\s+)*`
const IMPERATIVE = new RegExp(String.raw`${START}${PREAMBLE}${VERBS}${OBJECT}`, 'gim')
// "To clear the goal, type `/goal clear`".
const TO_DO = new RegExp(String.raw`${LEAD}to [^,:.!?\n*]{1,60}[,:](?:\*\*)?\s+(?:please\s+)?${VERBS}${OBJECT}`, 'gim')
// Said of Dan inside a sentence: "until you run `/reload-plugins`", "needs you to type", "remember
// to type". Never "you can" or "you could", which offer it.
const YOURS = new RegExp(String.raw`\b(?:until you|till you|you(?:'ll| will)? need to|you have to|needs? you to|remember to)\s+${VERBS}${OBJECT}`, 'gi')
// Naming the next move as Dan's: "Your next move is to start `/plan-council`", "Your next step is
// `/plan-council`".
const NEXT_MOVE = new RegExp(String.raw`\byour (?:next|only|last) (?:move|step|thing to do)\b[^.!?\n]{0,40}?\bis\s+(?:to\s+${VERBS}\s+)?(?:the\s+)?(?:command\s+)?${MARK}(${NAME})${ENDS}`, 'gi')
// Said as an offer or a condition, so a choice Dan may never take, not a step: "if you want",
// "you could", "whenever you like", "if the scope grows", "later".
const OFFER = /\b(?:if|unless|in case|whenever|could|might|would you|want me|shall I|should I|prefer|at some point|later|some time|sometime|optionally|alternatively)\b/i

// The sentence holding `at`, from its start to its end.
const sentenceAt = (plain: string, at: number): string => {
  const start = sentenceStart(plain.slice(0, at))
  const rest = plain.slice(at)
  const end = rest.search(/[.!?](?=\s|$)|\n/)
  return plain.slice(start, end < 0 ? plain.length : at + end + 1)
}

/** Whether the command at `at` in `plain` is said to Dan to type now, not named, offered or Claude's. */
const handedOver = (plain: string, at: number): boolean => {
  if (quotedOnLine(plain.slice(0, at)) || !dansNow(plain, at)) return false
  const sentence = sentenceAt(plain, at)
  return !OFFER.test(sentence) && !/\?\s*$/.test(sentence)
}

// The line before a fenced block, blank lines passed over, that introduces it ("with this brief:").
const leadIn = (plain: string, at: number): { text: string; at: number } => {
  const before = plain.slice(0, at).replace(/\s+$/, '')
  const start = before.lastIndexOf('\n') + 1
  return { text: before.slice(start), at: start }
}

/** The slash commands `text` hands Dan to type, each once, in the order first handed over. */
export const typedCommands = (text: string): string[] => {
  const plain = text.replace(/’/g, "'")
  const found: { at: number; command: string }[] = []
  for (const rx of [IMPERATIVE, NEXT_MOVE, TO_DO, YOURS]) {
    for (const m of plain.matchAll(rx)) {
      const at = m.index ?? 0
      if (handedOver(plain, at)) found.push({ at, command: m[1] as string })
    }
  }
  for (const m of plain.matchAll(FENCED)) {
    const at = m.index ?? 0
    // Judged by the line that introduces it: a block shown as something Claude ran, or offered, is not.
    const lead = leadIn(plain, at)
    const said = lead.text.trim()
    if (said && (quotedOnLine(said) || !dansNow(said, said.length) || OFFER.test(said) || /\?\s*$/.test(said))) continue
    found.push({ at, command: m[1] as string })
  }
  found.sort((a, b) => a.at - b.at)
  return [...new Set(found.map(f => f.command))]
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
