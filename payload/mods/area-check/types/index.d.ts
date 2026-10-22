/**
 * The files this session has judged, each once (decision 2): its project's main working tree and its
 * path inside the checkout, so every worktree of a project shares it, and a subagent's own id after
 * them, since a subagent is judged for itself (decision 8). In $.state so a reload keeps it.
 */
export type AreaCheckJudged = string[]
/** How many times the area check's own work failed this session; the first is said in a dim line. */
export type AreaCheckErrors = number

declare module 'claude-code' {
  interface PluginState {
    'area-check': { judged: AreaCheckJudged; errors: AreaCheckErrors }
  }
}
