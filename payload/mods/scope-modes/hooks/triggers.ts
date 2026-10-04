import type { PromptOrigin } from 'claude-code'

export type Trigger = { kind: 'scope'; scope: 'NO BUILD' | 'WINDING DOWN' } | { kind: 'build' } | { kind: 'place'; place: 'away' | 'home' }

// Dan's own phrases for each mode, from the specs (#616, #621) and the chats they were mined from.
// Apostrophes may be straight or curly; read-only may be one word or two. Only phrasings aimed at
// Claude count, never the words in passing ("make this column read only", "the project is winding
// down"): decided with Dan, 2026-10-04, after a review found the bare words fired on ordinary prose.
const APOS = "['’]"
const PHRASES: { re: RegExp; trigger: Trigger }[] = [
  { re: /\bpause after (?:this|the|that) (?:issue|one|pr)\b/i, trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
  { re: /\bwind (?:it )?down (?:now|after (?:this|the|that))\b/i, trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
  { re: new RegExp(`\\b(?:let${APOS}?s|time to|please|start) wind(?:ing)? (?:it )?down\\b`, 'i'), trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
  { re: /^\s*(?:ok,? )?wind (?:it )?down[.!]?\s*$/i, trigger: { kind: 'scope', scope: 'WINDING DOWN' } },
  { re: /\bno coding yet\b/i, trigger: { kind: 'scope', scope: 'NO BUILD' } },
  { re: /\b(?:stay|keep it|keep things|be|work) read[ -]only\b/i, trigger: { kind: 'scope', scope: 'NO BUILD' } },
  { re: /\bread[ -]only (?:for now|mode|until)\b/i, trigger: { kind: 'scope', scope: 'NO BUILD' } },
  { re: new RegExp(`\\bjust file,? (?:it,? )?don${APOS}?t build\\b`, 'i'), trigger: { kind: 'scope', scope: 'NO BUILD' } },
  { re: new RegExp(`\\bdon${APOS}?t start (?:git|coding|building) yet\\b`, 'i'), trigger: { kind: 'scope', scope: 'NO BUILD' } },
  { re: /\bgo ahead and build\b/i, trigger: { kind: 'build' } },
  { re: new RegExp(`\\b(?:i${APOS}?m )?stepping away\\b`, 'i'), trigger: { kind: 'place', place: 'away' } },
  { re: /^\s*away[.!]?\s*$/i, trigger: { kind: 'place', place: 'away' } },
  { re: new RegExp(`\\b(?:i${APOS}?m )?back at (?:my|the) (?:computer|desk|mac)\\b`, 'i'), trigger: { kind: 'place', place: 'home' } },
]

/** The modes a message from Dan turns on or off, in the order he wrote them. */
export const triggersIn = (text: string): Trigger[] =>
  PHRASES.map(p => ({ at: text.search(p.re), trigger: p.trigger }))
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
