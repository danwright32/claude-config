// The collision guard's rules, apart from the hooks (claude-config#605).

export type Rec = { sessionId: string; cwd: string; repoRoot: string | null; edits: string[]; transcriptPath: string | null }
export type Verdict = { verdict: 'Proceed' | 'Worktree' | 'Stop'; reason: string }

// The checkout wide git commands the spec watches: each moves or rewrites the whole working tree,
// or stages files the other session left there. Anything else is left alone.
export const watchedGit = (g: { sub: string | undefined; args: string[] }): string | undefined => {
  const { sub, args } = g
  const label = `git ${[sub, ...args].join(' ')}`
  switch (sub) {
    case 'checkout':
      // Putting one file back (checkout <ref> -- <path>) touches only that file.
      return args.includes('--') ? undefined : label
    case 'switch':
      return label
    case 'branch':
      return args.includes('-D') || (args.includes('--delete') && args.includes('--force')) ? label : undefined
    case 'reset':
      return args.includes('--hard') ? label : undefined
    case 'stash':
      return args[0] === 'pop' ? label : undefined
    case 'add':
      return args.some(a => a === '-A' || a === '--all' || a === '.') ? label : undefined
    default:
      return undefined
  }
}

// Other open sessions, never this one: a subagent of this session works as this session.
export const othersEditing = <R extends Rec>(open: R[], selfId: string | null, path: string): R[] =>
  open.filter(r => r.sessionId !== selfId && r.edits.includes(path))

export const othersInRepo = <R extends Rec>(open: R[], selfId: string | null, root: string | null): R[] =>
  root === null ? [] : open.filter(r => r.sessionId !== selfId && r.repoRoot === root)

// The judge answers JSON; anything that is not exactly one of the three verdicts with a reason is
// no verdict, and the guard stops (L42, the spec).
export const parseVerdict = (text: string): Verdict | undefined => {
  const m = /\{[\s\S]*\}/.exec(text)
  if (!m) return undefined
  try {
    const v = JSON.parse(m[0]) as { verdict?: unknown; reason?: unknown }
    if ((v.verdict === 'Proceed' || v.verdict === 'Worktree' || v.verdict === 'Stop') && typeof v.reason === 'string' && v.reason.trim()) {
      return { verdict: v.verdict, reason: v.reason.trim() }
    }
  } catch {
    // Not JSON: no verdict.
  }
  return undefined
}

// The last request typed into a session, read from the tail of its transcript: the newest user row
// that carries text rather than tool results. A tail may begin part way through a line.
export const latestRequest = (tail: string): string | undefined => {
  const lines = tail.split('\n').reverse()
  for (const line of lines) {
    let row: { type?: string; message?: { role?: string; content?: unknown } }
    try {
      row = JSON.parse(line)
    } catch {
      continue
    }
    if (row.type !== 'user' || row.message?.role !== 'user') continue
    const c = row.message.content
    if (typeof c === 'string' && c.trim()) return c.trim().slice(0, 600)
    if (Array.isArray(c)) {
      const text = c
        .filter((b): b is { type: string; text: string } => !!b && (b as { type?: string }).type === 'text')
        .map(b => b.text)
        .join('\n')
        .trim()
      if (text) return text.slice(0, 600)
    }
  }
  return undefined
}
