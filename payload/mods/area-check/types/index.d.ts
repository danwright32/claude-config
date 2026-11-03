/**
 * The files this session has judged, each once (decision 2): its project's main working tree and its
 * path inside the checkout, so every worktree of a project shares it, and a subagent's own id after
 * them, since a subagent is judged for itself (decision 8). In $.state so a reload keeps it.
 */
export type AreaCheckJudged = string[]
/** How many times the area check's own work failed this session; the first is said in a dim line. */
export type AreaCheckErrors = number

/**
 * The edits held this session, each waiting on a decision under its call id (#1509). The shape of
 * `Held` in hooks/rules.ts, written out here because a mod's contract may import nothing; the type
 * check of register.ts's $.state writes against it keeps the two the same.
 */
export type AreaCheckHeld = {
  id: string
  tool: string
  repo: string
  main: string
  rel: string
  agent: string | null
  at: number
  why: ('issues' | 'growth')[]
  shown: { n: number; how: 'path' | 'suffix' | 'basename' | 'folder'; structural: string[]; priority: string | null }[]
  issues: { state: 'read' | 'truncated' } | { state: 'unread'; why: string }
  growth: { net: number; size: number | null; fixes: number; rank: number | null; crosses: boolean } | { unread: string }
  branch?: string | null
  mergeBase?: string | null
}[]

declare module 'claude-code' {
  interface PluginState {
    'area-check': { judged: AreaCheckJudged; errors: AreaCheckErrors; held: AreaCheckHeld }
  }
}
