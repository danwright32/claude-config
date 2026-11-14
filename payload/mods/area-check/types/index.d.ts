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
  /** For a command whose files cannot be named, `repo`: the repository's structural issues it may fold into (#2706). */
  shown: { n: number; how: 'path' | 'suffix' | 'basename' | 'folder' | 'repo'; structural: string[]; priority: string | null }[]
  issues: { state: 'read' | 'truncated' } | { state: 'unread'; why: string }
  growth: { net: number; size: number | null; fixes: number; rank: number | null; crosses: boolean } | { unread: string }
  /** A Bash command whose file cannot be named before it runs (#2142): `rel` holds its word, `key` the command's claim. */
  unread?: { why: string; key: string }
  /** The branch and merge base the edit was held on (#1510); absent in entries held before them. */
  branch?: string | null
  mergeBase?: string | null
  /** A command reaching a whole folder, held once for it (#2920): the other held files there, and the folder as the command names it. */
  more?: AreaCheckHeld
  under?: string
}[]

declare module 'claude-code' {
  interface PluginState {
    'area-check': { judged: AreaCheckJudged; errors: AreaCheckErrors; held: AreaCheckHeld }
  }
}
