// The handoff's pure parts (#613): what a handoff names, how old it reads, what changed since it
// was written, and the band row it is drawn as (docs/mods-design.md, "Handoff (#613)").

const MIN = 60_000
const HOUR = 60 * MIN
const DAY = 24 * HOUR

/** Something a handoff names that GitHub can say has changed: an issue or PR number, or a milestone. */
export type Name = { kind: 'number' | 'milestone'; number: number }

/** One named thing as GitHub answered for it, or why it could not be read. */
export type Reading =
  | { kind: 'issue' | 'pr' | 'milestone'; number: number; state: 'open' | 'closed' | 'merged'; updatedAt: string }
  | { kind: 'number' | 'milestone'; number: number; error: string }

/**
 * Every issue or PR number and every milestone the text names, once each, in the order written.
 * A `#` glued to a word (README#mods) or followed by letters (a hex colour) is not a number.
 */
export const namesIn = (text: string): Name[] => {
  const found: Name[] = []
  const seen = new Set<string>()
  const re = /\bmilestone\s+(\d+)\b|(?<![\w#])#(\d+)(?![\w])/gi
  for (const m of text.matchAll(re)) {
    const name: Name = m[1] !== undefined ? { kind: 'milestone', number: Number(m[1]) } : { kind: 'number', number: Number(m[2]) }
    const key = `${name.kind}:${name.number}`
    if (seen.has(key)) continue
    seen.add(key)
    found.push(name)
  }
  return found
}

/** How long ago, as the band says it: "12m ago", "3h ago", "2d ago". */
export const ageOf = (ms: number): string => {
  if (ms < MIN) return 'just now'
  if (ms < HOUR) return `${Math.floor(ms / MIN)}m ago`
  if (ms < DAY) return `${Math.floor(ms / HOUR)}h ago`
  return `${Math.floor(ms / DAY)}d ago`
}

/** gh's issues or milestones API answer for one name, read as a Reading. */
export const readingOf = (name: Name, json: unknown): Reading => {
  const j = (json ?? {}) as { state?: unknown; updated_at?: unknown; pull_request?: { merged_at?: unknown } }
  if ((j.state !== 'open' && j.state !== 'closed') || typeof j.updated_at !== 'string') return { ...name, error: 'gh answered without a state' }
  if (name.kind === 'milestone') return { kind: 'milestone', number: name.number, state: j.state, updatedAt: j.updated_at }
  if (j.pull_request) return { kind: 'pr', number: name.number, state: typeof j.pull_request.merged_at === 'string' ? 'merged' : j.state, updatedAt: j.updated_at }
  return { kind: 'issue', number: name.number, state: j.state, updatedAt: j.updated_at }
}

const label = (r: Reading): string => (r.kind === 'milestone' ? `milestone ${r.number}` : r.kind === 'pr' ? `PR #${r.number}` : `#${r.number}`)

/**
 * The band's line for each thing that closed, merged or changed since the handoff was saved, in the order it
 * names them. A thing that could not be read now is said so: it must never pass as unchanged (L61).
 * A thing with no reading from when it was saved is judged by its state now alone.
 */
export const changesOf = (then: readonly Reading[], now: readonly Reading[]): string[] => {
  const out: string[] = []
  for (const r of now) {
    if ('error' in r) {
      out.push(`${label(r)} could not be checked: ${r.error}`)
      continue
    }
    const before = then.find(t => t.number === r.number && (t.kind === 'milestone') === (r.kind === 'milestone'))
    const was = before && !('error' in before) ? before : undefined
    if (r.state !== 'open' && was?.state !== r.state) out.push(`changed since: ${label(r)} ${r.state}`)
    else if (was && r.updatedAt !== was.updatedAt) out.push(`changed since: ${label(r)} updated`)
  }
  return out
}

/** The folder name a repository's handoff lives under: its root, made safe as one file name. */
export const keyOf = (root: string): string => root.replace(/^\/+/, '').replace(/[^A-Za-z0-9._-]+/g, '_')

/** A band row's parts, as mod-kit's contract spells them. */
export type Part = { text: string; color?: string; bold?: boolean; dim?: boolean; indent?: number } | { button: string; label: string }

/**
 * The band at session start (design rounds, 2026-10-04): the amber lead and the handoff's title on
 * one line, each change on a grey line of its own under it, then Use and Dismiss.
 */
export const bandLines = (input: { age: string; title: string; changes: readonly string[] }): Part[][] => [
  [{ text: `Handoff saved ${input.age}: `, color: 'warning', bold: true }, { text: input.title }],
  ...input.changes.map(c => [{ text: c, dim: true, indent: 3 }]),
  [{ button: 'use', label: 'Use' }, { text: '  ' }, { button: 'dismiss', label: 'Dismiss' }],
]
