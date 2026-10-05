/** One session's record, one file per session under ~/.claude/state/sessions (this Mac only). */
export type SessionsRecord = {
  v: 1
  sessionId: string
  cwd: string
  /** The git repository the session works in, its top folder; null outside one. */
  repoRoot: string | null
  startedAt: number
  lastSeen: number
  /** When the session ended cleanly; null while it runs. A crash leaves it null and lastSeen ages. */
  closedAt: number | null
  /** Where its transcript is, so its latest request is read from there rather than copied. */
  transcriptPath: string | null
  /** Files this session has edited inside its repository (or its folder outside one), newest last: by the edit tools, or named by a shell command (#654); scratch such as /tmp is left out (#674). */
  edits: string[]
  /** What other mods keep about the session (background jobs, task progress), by key. */
  extra: Record<string, unknown>
}

export type SessionsList = {
  /** Sessions still running: not closed, and seen within the last five minutes. */
  open: SessionsRecord[]
  /** Sessions that ended cleanly or went quiet for longer than that. */
  closed: SessionsRecord[]
  /** Records that could not be read, by file name. Never read as no session (L215). */
  unreadable: string[]
  /** This session's own id, so a reader can leave itself out. */
  selfId: string | null
}

export type Sessions = {
  list: () => Promise<SessionsList>
  /** One input each: the engine calls a noun's method with a single object. */
  noteEdit: (input: { path: string }) => Promise<void>
  setExtra: (input: { key: string; value: unknown }) => Promise<void>
}

declare module 'claude-code' {
  interface EngineInterface {
    sessions: Sessions
  }
}
