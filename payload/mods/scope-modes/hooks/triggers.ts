import type { PromptOrigin } from 'claude-code'

export type Trigger = { kind: 'scope'; scope: 'NO BUILD' | 'WINDING DOWN' } | { kind: 'build' } | { kind: 'place'; place: 'away' | 'home' }

// Dan's own phrases for each mode, from the specs (#616, #621) and the chats they were mined from.
// Apostrophes may be straight or curly; read-only may be one word or two. Only phrasings aimed at
// Claude count, never the words in passing ("make this column read only", "the project is winding
// down"): decided with Dan in a picker on 2026-10-04, recorded in PR #686, after a review found the
// bare words fired on ordinary prose. A question asks rather than instructs, so it never counts.
// The milestone audit (#702) found the away, home, no coding and build phrases still matched
// anywhere ("the user is stepping away from the form" switched every session to away), so every
// phrase now starts an instruction of its own: the message, a sentence, a line or a clause after a
// comma, semicolon or colon, led by nothing but the words Dan opens one with.
const APOS = "['’]"
// The words that lead a request to Claude ("ok", "can you", "let's", "you can"), and nothing else.
const LEAD = `(?:^\\s*|[.!?;:,]\\s+|\\n\\s*)(?:(?:ok(?:ay)?|so|and|then|now|please|pls|just|right|heads up|thanks|can you|could you|would you|you can|let${APOS}?s)[,!.]?\\s+)*`
const ME = `(?:i${APOS}?m\\s+|i am\\s+)?`
const own = (phrase: string) => new RegExp(`${LEAD}${phrase}`, 'i')
const PHRASES: { re: RegExp; trigger: Trigger }[] = [
  { re: own('pause after (?:this|the|that) (?:issue|one|pr)\\b'), trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
  { re: own('wind (?:it )?down (?:now|after (?:this|the|that))\\b'), trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
  // Ends the sentence or names when, so "let's wind down the Redis instance" stays prose.
  { re: new RegExp(`\\b(?:let${APOS}?s|time to|please|start) wind(?:ing)? (?:it )?down(?=\\s*(?:[.!,;]|$|now\\b|for (?:today|tonight|the (?:day|night))\\b|after\\b))`, 'i'), trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
  { re: /^\s*(?:ok,? )?wind (?:it )?down[.!]?\s*$/i, trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
  { re: own('no coding yet\\b'), trigger: { kind: 'scope', scope: 'NO BUILD' } },
  // A read only instruction is a sentence of its own ("Stay read only.", "Stay read only until I
  // say."), so "the database is in read only mode" or "keep it read only in the form" is prose.
  { re: /(?:^|[.!?]\s+)(?:ok,?\s+|please\s+)?(?:(?:stay|keep it|keep things)\s+read[ -]only(?:\s+(?:for now|until\b[^.!?]*))?|read[ -]only\s+(?:for now|mode|until\b[^.!?]*)),?(?:\s+please)?\s*(?:[.!]|$)/i, trigger: { kind: 'scope', scope: 'NO BUILD' } },
  { re: own(`just file,? (?:it,? )?don${APOS}?t build\\b`), trigger: { kind: 'scope', scope: 'NO BUILD' } },
  { re: own(`don${APOS}?t start (?:git|coding|building) yet\\b`), trigger: { kind: 'scope', scope: 'NO BUILD' } },
  { re: own('go ahead and build\\b'), trigger: { kind: 'build' } },
  { re: own(`${ME}stepping away\\b`), trigger: { kind: 'place', place: 'away' } },
  { re: /^\s*away[.!]?\s*$/i, trigger: { kind: 'place', place: 'away' } },
  { re: own(`${ME}back at (?:my|the) (?:computer|desk|mac)\\b`), trigger: { kind: 'place', place: 'home' } },
]

// Where the first match of `re` in `text` stands, skipping any inside a question: a match whose
// sentence ends in a question mark asks rather than instructs.
const instructionAt = (text: string, re: RegExp): number => {
  for (const m of text.matchAll(new RegExp(re.source, re.flags.includes('g') ? re.flags : `${re.flags}g`))) {
    const after = text.slice((m.index ?? 0) + m[0].length)
    const end = /[.!?\n]/.exec(after)
    if (end?.[0] !== '?') return m.index ?? 0
  }
  return -1
}

/** The modes a message from Dan turns on or off, in the order he wrote them. */
export const triggersIn = (text: string): Trigger[] =>
  PHRASES.map(p => ({ at: instructionAt(text, p.re), trigger: p.trigger }))
    .filter(m => m.at >= 0)
    .sort((a, b) => a.at - b.at)
    .map(m => m.trigger)
    // Two phrasings of one mode in a message switch it once.
    .filter((t, i, all) => all.findIndex(o => JSON.stringify(o) === JSON.stringify(t)) === i)

/**
 * Whether a prompt is Dan's own words: his Enter at the terminal, or his phone through Remote
 * Control. Nothing else may change a mode (a peer session, a plugin, a notification), so a message
 * from elsewhere saying "go ahead and build" cannot lift no build.
 */
export const isDans = (origin: PromptOrigin): boolean => origin.kind === 'composer' || origin.kind === 'bridge'
