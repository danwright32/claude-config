// #1287: one sleep report per session with news. Dan, 2026-10-17: "One file per session. Even if
// multiple sessions are working on the same project." Named night first, then the project, then the
// session: "2026-10-16 Bidspoke Fix the parser sleep report.md", the session's title where it has
// one, else the first 8 characters of its id, and " (2)" for a second sleep the same night. The name
// is fixed when the file is first written, and the morning page that session publishes gets it too.
// Only the naming lives here; register.ts chooses and records each session's file.

// A slash, a colon, a backslash or a control character, which would make a folder or a broken name.
const UNSAFE = /[/\\:\u0000-\u001f\u007f]/g
const clean = (s: string) => s.replace(UNSAFE, ' ').replace(/\s+/g, ' ').trim()
const TITLE_CHARS = 60

/** The session's title as a report names it: auto naming's "(project) " prefix dropped, or null. */
export const reportTitle = (raw: string | null): string | null => {
  const t = clean((raw ?? '').replace(/^\s*\([^)]*\)\s*/, ''))
  return t || null
}

/** A report's name without .md: night, project, the session's title or id, "sleep report", and (n) past the first. */
export const reportBase = (o: { night: string; project: string; title: string | null; sessionId: string; n?: number }): string => {
  let who = clean(o.title ?? '') || clean(o.sessionId).slice(0, 8)
  if (who.length > TITLE_CHARS) who = who.slice(0, TITLE_CHARS).replace(/\s+\S*$/, '').trim() || who.slice(0, TITLE_CHARS)
  const project = clean(o.project).slice(0, 40).trim()
  return `${clean(o.night)} ${project ? `${project} ` : ''}${who} sleep report${o.n && o.n > 1 ? ` (${o.n})` : ''}`
}
