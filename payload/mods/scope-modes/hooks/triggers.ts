import type { PromptOrigin } from 'claude-code'

type Scope = 'NO BUILD' | 'WINDING DOWN'
export type Trigger = { kind: 'scope'; scope: Scope } | { kind: 'build' } | { kind: 'off'; scope: Scope } | { kind: 'place'; place: 'away' | 'home' }

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
const LEADS = `(?:(?:ok(?:ay)?|so|and|then|now|please|pls|just|right|heads up|thanks|can you|could you|would you|you can|let${APOS}?s)[,!.]?\\s+)*`
const LEAD = `(?:^\\s*|[.!?;:,]\\s+|\\n\\s*)${LEADS}`
// A sentence of its own, never a clause after a comma: for a phrase that reads as prose there too
// ("once the sprint ends, time to wind down").
const SENTENCE = `(?:^\\s*|[.!?]\\s+|\\n\\s*)${LEADS}`
const ME = `(?:i${APOS}?m\\s+|i am\\s+)?`
const own = (phrase: string, start = LEAD) => new RegExp(`${start}${phrase}`, 'i')
// Ends the sentence or names when, so "let's wind down the Redis instance" stays prose.
const WIND_END = `wind(?:ing)? (?:it )?down(?=\\s*(?:[.!,;]|$|now\\b|for (?:today|tonight|the (?:day|night))\\b|after\\b))`
// Each scope mode's own name as Dan says it, and turning that one mode off by it (#805: "stop
// winding down mode. run load 1" on 2026-10-05 matched nothing, so winding down stayed on). The
// name must end the clause or be followed by "mode", so "stop winding down the cluster" is prose.
const NAME: Record<Scope, string> = { 'WINDING DOWN': 'wind(?:ing)?[ -]?down', 'NO BUILD': '(?:no[ -]?build|read[ -]only)' }
const NAME_END = '(?:\\s+mode\\b)?(?=\\s*(?:[.!,;:]|$|now\\b|please\\b|for (?:now|today|tonight)\\b))'
const offPhrases = (scope: Scope): { re: RegExp; trigger: Trigger }[] => [
  { re: own(`(?:stop|end|exit|quit|cancel|turn off|switch off|done with) (?:the )?${NAME[scope]}${NAME_END}`), trigger: { kind: 'off', scope } },
  { re: own(`(?:turn|switch|take) (?:the )?${NAME[scope]}(?: mode)? off\\b`), trigger: { kind: 'off', scope } },
]
const PHRASES: { re: RegExp; trigger: Trigger }[] = [
  ...offPhrases('WINDING DOWN'),
  ...offPhrases('NO BUILD'),
  { re: own('pause after (?:this|the|that) (?:issue|one|pr)\\b'), trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
  { re: own('wind (?:it )?down (?:now|after (?:this|the|that))\\b'), trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
  { re: own(`(?:let${APOS}?s|please|start) ${WIND_END}`), trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
  { re: own(`time to ${WIND_END}`, SENTENCE), trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
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

// Saying a mode should end, bound to its name: "<name> (mode) is done/over/off", or "no more/out
// of/done with/stop <name>" ending its clause as the triggers require (so "stop winding down the
// cluster" is prose, third lessons review of #820). An end word elsewhere in the sentence ("the
// project is winding down, we're done with the sprint", second review) or the name merely called a
// mode ("the database is in read only mode", fourth review) is not.
const askedOff = (name: string) =>
  new RegExp(
    `\\b${name}(?:\\s+mode)?\\s+(?:is\\s+|are\\s+|${APOS}s\\s+)?(?:now\\s+)?(?:done|over|off|finished|ended)\\b` +
      // Verb first, it opens its clause like an instruction, as the off triggers do (fifth review);
      // "finish" and "enough" are left out, since "finish winding down" asks to complete it.
      `|${LEAD}(?:get\\s+|we${APOS}?re\\s+|i${APOS}?m\\s+)?(?:no more|out of|done with|end|stop|exit|quit|cancel)\\s+(?:the\\s+)?${name}${NAME_END}`,
    'i',
  )

/**
 * The scope modes a message asks to end in words the triggers do not read: a sentence, not a
 * question, naming the mode and saying it should end ("winding down is done for today"). What lets the mod tell Claude the mode is still on, rather than leave Claude to
 * act as though it were off (#805). The name in passing ("use a read only connection", "there's no
 * build step") is not one, as the triggers refuse it too (lessons review of #820).
 */
export const scopesAskedOffIn = (text: string): Scope[] => {
  const out: Scope[] = []
  for (const m of text.matchAll(/[^.!?\n]+[.!?\n]?/g)) {
    const sentence = m[0]
    if (sentence.trim().endsWith('?')) continue
    for (const s of Object.keys(NAME) as Scope[]) if (askedOff(NAME[s]).test(sentence) && !out.includes(s)) out.push(s)
  }
  return out
}

/**
 * Whether a prompt is Dan's own words: his Enter at the terminal, or his phone through Remote
 * Control. Nothing else may change a mode (a peer session, a plugin, a notification), so a message
 * from elsewhere saying "go ahead and build" cannot lift no build.
 */
export const isDans = (origin: PromptOrigin): boolean => origin.kind === 'composer' || origin.kind === 'bridge'
