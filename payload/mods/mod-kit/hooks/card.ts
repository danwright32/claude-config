import type { ModKitBlocked, ModKitCard, ModKitRun } from '../types/index.d.ts'

// The boxed card a tool result row is drawn as (#663): the blocked card's shape, settled with Dan
// in the guard rounds, opened to any mod's own tool result. Plain data, since only plain data
// crosses between mods: a title of runs, so a leading state word can carry its colour, then lines.

const runRefusal = (r: unknown, where: string): string | undefined => {
  if (!r || typeof r !== 'object' || Array.isArray(r)) return `${where} must be a run, { text, color?, bold?, dim? }`
  const { text, color, bold, dim } = r as Record<string, unknown>
  if (typeof text !== 'string') return `${where} needs its text as a string`
  if (color !== undefined && (typeof color !== 'string' || !color)) return `${where}: a colour must be a theme key or a colour name`
  if (bold !== undefined && typeof bold !== 'boolean') return `${where}: bold must be true or false`
  if (dim !== undefined && typeof dim !== 'boolean') return `${where}: dim must be true or false`
  return undefined
}

/** Why this card cannot be drawn, or undefined when it can. Refused at the call, never drawn as something else. */
export const cardRefusal = (card: ModKitCard): string | undefined => {
  if (!card || typeof card !== 'object') return 'a card must be { toolUseId, title, lines }'
  if (typeof card.toolUseId !== 'string' || !card.toolUseId) return "a card needs the tool use id of the result it is drawn for (the tool.call's tool_use_id)"
  if (!Array.isArray(card.title) || card.title.length === 0) return 'a card needs a title of one or more runs'
  for (const [i, r] of card.title.entries()) {
    const why = runRefusal(r, `title run ${i + 1}`)
    if (why) return why
  }
  if (!Array.isArray(card.lines)) return 'a card needs its lines as a list, each a list of runs'
  for (const [n, l] of card.lines.entries()) {
    if (!Array.isArray(l)) return `line ${n + 1} must be a list of runs`
    for (const [i, r] of l.entries()) {
      const why = runRefusal(r, `line ${n + 1}, run ${i + 1}`)
      if (why) return why
    }
  }
  return undefined
}

/** The blocked card as one use of the card: "Blocked by <guard>", the reason, then the safe way and any note, dim. */
export const blockedCard = (b: ModKitBlocked): ModKitCard => {
  const dim = (text: string | undefined): ModKitRun[][] => (text ? [[{ text, dim: true }]] : [])
  return {
    toolUseId: b.toolUseId,
    title: [{ text: `Blocked by ${b.guard}` }],
    lines: [[{ text: b.reason }], ...dim(b.safeWay), ...dim(b.note)],
  }
}
