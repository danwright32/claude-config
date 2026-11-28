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
// A folder at the root of a disk is never a command, whatever is said of it ("Your next step is to
// use `/tmp`"). A closed set, unlike the names of commands or of a project's own folders.
const SYSTEM_FOLDER = /^\/(?:tmp|etc|usr|var|bin|sbin|opt|private|proc|mnt|srv)$/

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
// A clause after a comma counts too when "so" or "then" leads it ("the old copy is still loaded, so
// run ...", "Close the other tab, then type ...").
const START = String.raw`(?:${LEAD}|(?<=:(?:\*\*)?[ \t]+)|(?<=[,;][ \t]+)(?=(?:so|then|and then)\s))`
// Words that may come before the imperative without making it anything else: a filler, a moment
// that is Dan's to choose, or the steps before it ("After those two, start `/plan-council`"). "When
// you are back" is matched here so that one rule, AWAY, decides it.
const WHEN_YOU = String.raw`when you(?: can| get a moment| have a moment| are ready|'re ready| are back|'re back| are done|'re done)`
const AFTER_THOSE = String.raw`after (?:that|this|those|these|both)(?: (?:two|three|four|steps?))?|once (?:that|this|those|these|both) (?:is|are) done`
const PREAMBLE = String.raw`(?:(?:please|so|and|now|next|then|first|finally|also|just|go ahead and|when convenient|${WHEN_YOU}|${AFTER_THOSE}),?\s+)*`
const IMPERATIVE = new RegExp(String.raw`${START}${PREAMBLE}${VERBS}${OBJECT}`, 'gim')
// "To clear the goal, type `/goal clear`".
const TO_DO = new RegExp(String.raw`${LEAD}to [^,:.!?\n*]{1,60}[,:](?:\*\*)?\s+(?:please\s+)?${VERBS}${OBJECT}`, 'gim')
const THEN_VERB = String.raw`\s+(?:(?:now|next|then|still|just|first|also)\s+)?${VERBS}${OBJECT}`
// Said of Dan inside a sentence, wherever it sits: "until you run `/reload-plugins`", "needs you to
// type", "remember to type". Never "you can" or "you could", which offer it.
const YOURS = new RegExp(String.raw`\b(?:until you|till you|you(?:'ll| will)? need to|needs? you to|remember to)${THEN_VERB}`, 'gi')
// "You should", "you must" and "you have to" are also how a reply suggests or reports ("big enough
// that you should start", "the README says you should run"), so they count only where "you" leads
// its sentence or its clause: "You should now run", "; you have to type", ", so you'll have to run",
// "and you should now run".
const CLAUSE = String.raw`(?:${LEAD}|(?<=:(?:\*\*)?[ \t]+)|(?<=[,;][ \t]+)|(?<=[ \t])(?=(?:and|but|so)\s))`
const LEAD_IN = String.raw`(?:(?:so|and|but|then|now|next|first|also|(?:that|which|this|it) means),?\s+)*`
const YOU_OUGHT = new RegExp(String.raw`${CLAUSE}${LEAD_IN}you(?:(?:'ll| will)? have to| should| must)${THEN_VERB}`, 'gim')
// Naming the next move as Dan's: "Your next move is to start `/plan-council`", "Your next step is
// `/plan-council`", "Your next move: `/plan-council`". After "to", the verbs above, "begin" and
// "use": here "use" is said of the next step, where leading a sentence it names a skill or a folder.
const NEXT_MOVE = new RegExp(String.raw`\byour (?:next|only|last) (?:move|step|thing to do)\b[^.!?\n]{0,40}?(?:\bis|:(?:\*\*)?)\s+(?:to\s+(?:${VERBS}|begin|use)\s+)?(?:the\s+)?(?:command\s+)?${MARK}(${NAME})${ENDS}`, 'gi')
// A label saying the move is Dan's, then what to do with a command marked as one ("Next is yours:
// paste the brief below into `/plan-council`"), or the command alone ("The next step is yours:
// `/plan-council`"). A choice laid out after the label describes the commands and hands none over
// ("The call is yours: `/plan-lite` is lighter and `/plan-council` goes deeper").
const DESCRIBED = String.raw`(?:\*\*|\`){0,2}\s+(?:is|are|or|and|runs?|goes|does|would|will|if)\b`
const IS_YOURS = new RegExp(String.raw`\b(?:is|are)\s+yours:(?:\*\*)?\s+(?:${PREAMBLE}(?:${VERBS}|begin)\b[^.!?\n]{0,60}?)?(?:\*\*|\`){1,2}(${NAME})${ENDS}(?!${DESCRIBED})`, 'gi')
// Sent somewhere to type it: "Open a new session and run `/plan-council` there".
const CHAINED = new RegExp(String.raw`${LEAD}(?:open|start|begin)\s+(?:a|another|the)\s+(?:(?:new|fresh|second|other|next)\s+)?(?:session|terminal|window|tab|chat|conversation)\b[^.!?\n]{0,40}?\b(?:and|then)\s+(?:then\s+)?${VERBS}${OBJECT}`, 'gim')

// Said as an offer or a condition, so a choice Dan may never take, not a step: "if you want",
// "you could", "whenever you like", "if the scope grows", "later".
const OFFER = /\b(?:if|unless|in case|whenever|could|might|would you|want me|shall I|should I|prefer|at some point|later|some time|sometime|optionally|alternatively)\b/i
// Handed over for a time Dan is away from the keyboard, so no step he can take now: "for the
// morning", "when you are back", "when you wake", "tomorrow". Never a moment that is his to choose
// today ("when you are ready", "when you get a moment", "at your convenience").
const AWAY_WORDS = String.raw`(?:\b(?:for|in|until|till|by) (?:the )?morning\b|\btomorrow\b(?!')|\b(?:when|once|after) you(?:'re| are| get| come) back\b|\bwhen you (?:return|wake)\b)`
const AWAY = new RegExp(AWAY_WORDS, 'i')
// Where the words after a command turn to why it is typed, which is not when: "to load the guard I
// merged in the morning", "so the next session loads it".
const REASON = /\s(?:to|so|since|because|which|that)\s/i
// Offered beside another way to the same end: "Run `/compact`, or start a fresh session". Never
// "or" with what happens otherwise ("or the new guard stays unloaded").
const ANOTHER = String.raw`or,?\s+(?:else\s+|just\s+|simply\s+)?(?:start|open|begin|use|carry on|continue|keep|leave|skip|wait)\b`
const OTHER_WAY = new RegExp(String.raw`,?\s+${ANOTHER}`, 'i')
// `when` is the part of `clause` that can say when to type it, where that is not all of it.
const offered = (clause: string, when: string = clause): boolean => OFFER.test(clause) || AWAY.test(when) || OTHER_WAY.test(clause)
// The sentence right after, on the same line, doing either: "Or open a new session.", "and it can
// wait for the morning", "I have put that down for the morning". Unless it opens with "or" it must
// speak of the command ("it", "that", "this"): one that puts something else off says nothing of it.
const PUT_OFF_NEXT = new RegExp(String.raw`^[ \t]+(?:${ANOTHER}|[^.!?\n]*?\b(?:it|that|this)\b[^.!?\n]{0,40}?(?:\bcan wait\b|${AWAY_WORDS}))`, 'i')
// A standing rule, not a step now: "Run `/no-ai-tells` on anything other people will read". Never
// "every" or "any" alone, which a hand over says too ("in every open session"), nor "anything else"
// ("before anything else" says first, now).
const STANDING = /\b(?:anything(?!\s+else\b)|always|every time|each time|any time|anytime|(?:after|before) (?:each|every))\b/i
// Said of a web address, where a slash leads a route: "Start `/login` and watch the redirect". Told
// by what the sentence says of it, never by the name, since `/login` is a command too. A web word
// that names something built for web addresses says nothing of the command ("the new URL guard").
const WEB = /\b(?:endpoints?|routes?|urls?|redirects?|domains?|localhost|https?)\b(?!\s+(?:guards?|checks?|checkers?|tests?|rules?|hooks?|gates?|scanners?|parsers?|fix(?:es)?|bugs?|handlers?|matchers?|filters?)\b)/i
// Shown as a wording, not said to Dan: "(an example the check holds)".
const EXAMPLE = /\b(?:examples?|for instance)\b|\be\.g\./i
// Said of what Dan already did: "You typed this a minute ago:".
const PAST = /\byou(?:'ve| have)?\s+(?:(?:already|just)\s+)?(?:typed|ran|pasted|started|entered|sent)\b/i
// A label or a line that speaks to Dan, whatever else it says: "One thing I need from you:".
const ADDRESSED = /\b(?:you|your|yours)\b/i
// A label saying the session will do the work ("After you approve the plan I will do two things:"),
// which makes what follows its own whatever the label says of Dan. Not when what it will do is need
// or ask something of him ("One thing I will need from you:", "I need two things:").
const OWN_WORK = /\b(?:I|we)(?:'ll| will|'m going to| am going to|'re going to| are going to)\b/i
const NEEDS = /\b(?:I|we)(?:'ll| will)?\s+(?:still\s+)?(?:need|ask)\b/i
const speaksToDan = (label: string): boolean => ADDRESSED.test(label) && !(OWN_WORK.test(label) && !NEEDS.test(label))
// The command named as a skill, which the session runs: "run the `/db-apply` skill".
const A_SKILL = /^(?:\*\*|`|"|”){0,2}\s+skill\b/i
// Where the sentence goes on to another thing, whose "if" is not the command's: "Type
// `/reload-plugins`, then tell me if the card shows the new text".
const GOES_ON = /;|,?\s+(?:and\s+)?then\b/
// A numbered or bulleted line, and a line that is nothing but "Plan:", which heads the session's own.
const ITEM = /^[ \t]*(?:\d+[.)]|[-*])\s/
const PLAN_LABEL = /^\W*(?:(?:my|the|our)\s+)?plan\W*$/i

// Each fenced code block of `plain`, from its opening fence to the end of its closing one, and where
// a fence that is never closed opens (-1 when every fence closes). Where such a block ends cannot be
// known, so it is not among the blocks.
const fences = (plain: string): { closed: [number, number][]; unclosed: number } => {
  const closed: [number, number][] = []
  let open = -1
  let at = 0
  for (const line of plain.split('\n')) {
    if (/^[ \t]*(?:```|~~~)/.test(line)) {
      if (open < 0) open = at
      else {
        closed.push([open, at + line.length])
        open = -1
      }
    }
    at += line.length + 1
  }
  return { closed, unclosed: open }
}

// Where the paragraph holding `at` ends: the next blank line, or the end.
const paragraphEnd = (plain: string, at: number): number => {
  const gap = plain.slice(at).search(/\n[ \t]*\n/)
  return gap < 0 ? plain.length : at + gap
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
  // A line saying what the session needs heads Dan's list ("I need two things:").
  const intro = introOf(plain, at)
  if (intro && !speaksToDan(intro) && ((NOT_DANS.test(intro) && !NEEDS.test(intro)) || PLAN_LABEL.test(intro) || EXAMPLE.test(intro))) return false
  const [from, to] = sentenceSpan(plain, at, end)
  const sentence = plain.slice(from, to)
  if (/\?\s*$/.test(sentence)) return false
  if (PUT_OFF_NEXT.test(plain.slice(to))) return false
  // Called an example in its own sentence, or in the aside in brackets right after it on its line.
  const aside = /^[ \t]*\(([^)\n]*)\)/.exec(plain.slice(to))?.[1] ?? ''
  if (EXAMPLE.test(sentence) || EXAMPLE.test(aside)) return false
  // Judged on the command's own clause: an aside in brackets and what follows "then" are other things.
  const after = plain.slice(end, to).replace(/\([^)\n]*\)/g, ' ')
  const goesOn = after.search(GOES_ON)
  const rest = goesOn < 0 ? after : after.slice(0, goesOn)
  const clause = plain.slice(from, end) + rest
  // When to type it is said in a label before the words that hand it over, in those words, or after
  // the command before its reason. A time in the telling around them is when something else happened
  // ("The guard I merged in the morning needs you to type ...").
  const led = plain.slice(from, at)
  const label = led.slice(0, ([...led.matchAll(/:(?:\*\*)?(?=\s)/g)].at(-1)?.index ?? -1) + 1)
  const reason = rest.search(REASON)
  const when = label + plain.slice(at, end) + (reason < 0 ? rest : rest.slice(0, reason))
  return !offered(clause, when) && !STANDING.test(clause) && !WEB.test(clause)
}

// What comes before `at` in its sentence: a label, or the clause before "so".
const ledBy = (plain: string, at: number): string => {
  const before = plain.slice(0, at)
  return before.slice(sentenceStart(before))
}

// An imperative is said to whoever reads it. After "so" it is Dan's whatever the clause before it
// says ("I merged the fix, so run ..."); after a label it is Dan's when the label speaks to him
// ("One thing I need from you:"), and the session's own when the label speaks of its own work.
const imperativeIsDans = (plain: string, at: number, said: string): boolean => {
  if (quotedOnLine(plain.slice(0, at))) return false
  const led = ledBy(plain, at)
  if (/^so\s/i.test(said) || speaksToDan(led)) return true
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
  [YOU_OUGHT, yoursIsDans],
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
  const { closed, unclosed } = fences(plain)
  // What a block hides is file text. A fence never closed hides nothing: the words after it may be
  // the reply going on.
  const hides: readonly [number, number][] = closed
  const found: Handed[] = []
  for (const [rx, isDans] of SAID_TO_DAN) {
    for (const m of plain.matchAll(rx)) {
      const at = m.index ?? 0
      const end = at + m[0].length
      if (!isDans(plain, at, m[0]) || !handedOver(plain, at, end, hides)) continue
      const [from, to] = sentenceSpan(plain, at, end)
      found.push({ at, from, to, command: m[1] as string })
    }
  }
  for (const m of plain.matchAll(FENCED)) {
    const at = m.index ?? 0
    // Only a block's opening fence: a closing one followed by a line that starts with a command is
    // not one. A block never closed is taken to end with its paragraph.
    const to = closed.find(([from]) => from === at)?.[1] ?? (at === unclosed ? paragraphEnd(plain, at) : -1)
    if (to < 0) continue
    // Judged by the sentence that introduces it: a block shown as something Claude ran, offered,
    // already typed, a web address or an example is not handed over. Only that sentence: one before
    // it on the line speaks of something else ("You ran the first half. Paste the second:").
    const { said, from } = leadIn(plain, at)
    const line = said.trim()
    const sentence = line.slice(sentenceStart(line))
    if (line && (!dansNow(line, line.length) || /^>/.test(line) || /\?\s*$/.test(line) || offered(sentence) || [PAST, WEB, EXAMPLE].some(rx => rx.test(sentence)))) continue
    found.push({ at, from, to, command: m[1] as string })
  }
  return found.filter(f => LOWER.test(f.command) && !SYSTEM_FOLDER.test(f.command)).sort((a, b) => a.at - b.at)
}

// A curly apostrophe is one character, as the straight one is, so positions stay the same.
const straight = (text: string): string => text.replace(/’/g, "'")

/** The slash commands `text` hands Dan to type, each once, in the order first handed over. */
export const typedCommands = (text: string): string[] => [...new Set(handed(straight(text)).map(f => f.command))]

// The sentence right after a hand over asking to be told that same command is done: "Tell me when
// it is done", "Tell me once it's loaded", "Tell me when you have run it". Its "it" can only be the
// command just handed over, so it is that step, not another (second review of pull request 3677). So
// is the command named by what it is or starts: "the command", or the panel a planning command
// starts ("Tell me when the panel has finished"). A report back on anything else ("when you have
// clicked **Approve**", "when the deploy has finished") is another step, and a word of the
// command's own name is no sign of it ("the code" after `/code-review`).
const STARTS: Readonly<Record<string, string>> = { '/plan-council': 'panel', '/plan-lite': 'panel' }
const reportsBack = (command: string): RegExp => {
  const named = ['command', STARTS[command] ?? ''].filter(Boolean).join('|')
  return new RegExp(String.raw`^\s+(?:please\s+)?tell me\s+(?:(?:when|once)\s+(?:it|that|this|the\s+(?:${named}))\b|(?:when|once)\s+you(?:'ve| have)\s+(?:done|run|typed|finished)\s+(?:it|that|this)\b|(?:that\s+)?(?:it's|it is|that's|that it's|that it is)\s+(?:done|finished|loaded|in place)\b)[^.!?\n]*(?:[.!?](?=\s|$))?`, 'i')
}

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
    kept = Math.max(kept, f.to + (reportsBack(f.command).exec(plain.slice(f.to))?.[0].length ?? 0))
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
