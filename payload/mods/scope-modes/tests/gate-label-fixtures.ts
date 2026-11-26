// The one committed fixture set both sides of one question are held to (#3439, L58): which label a
// project's merge gate requires on a pull request. The gate answers it (requiredLabels in
// payload/hooks/lib/changelog-entry.js, tested in changelog-entry.test.js beside it, which reads this
// file), and sleep mode reads that answer (gateAnswerOf in hooks/requiredlabel.ts, tested in
// tests/requiredlabel.test.ts). Each case is a registry as the gate's own reader hands it over
// (null: it could not be read), the repository asked about, the day, and the answer both must agree
// on: `state`, and for a gated repository every label the gate takes with whether the gate accepts
// it on a pull request whose description carries no Changelog sentence.
//
// Since the announce label (#3665) the gate is asked two ways, and a case says which with `flags`.
// A case carrying "--needs-dan" is asked as sleep mode asks today: the caller says it understands a
// label's `needsDan`, so it is handed every label in use in that repository, each also saying
// whether it needs the post for agents (`needsAnnouncement`) and whether its wording is Dan's to
// approve (`needsDan`). A case with no flags is a session still running the mod as it was before:
// it gets the answer it always got, in the shape it always had, and never sees the announce label.
// The gate's suite holds the gate to both. The mod's suite holds its reader to the first, and to
// refusing the second, since an answer that does not say whether a label needs Dan is not one it
// asked for.
//
// The FIRST case stays a gated repository as the mod is answered about it: tests/register.test.tsx
// reads it by position, as the answer its whole session is given. The named exports under the list
// are how every other reader picks a case.
//
// Everything after the `=` below, to the `]` that closes it at the start of a line, is plain JSON,
// which is what lets the node suite read it too: keep it JSON (double quotes, no trailing commas,
// no comments inside), or that suite fails.
export const GATE_LABEL_FIXTURES = [
  {"name": "a caller that understands needsDan, where the repository names an announcements channel", "flags": ["--needs-dan"], "registry": {"repos": [{"name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01", "announceChannel": "C0000TEST01"}]}, "repo": "acme/board", "today": "2026-11-21", "answer": {"state": "required", "labels": [{"label": "changelog/visible", "needsSentence": true, "needsAnnouncement": false, "needsDan": false}, {"label": "changelog/technical", "needsSentence": false, "needsAnnouncement": false, "needsDan": false}, {"label": "changelog/none", "needsSentence": false, "needsAnnouncement": false, "needsDan": false}, {"label": "changelog/announce", "needsSentence": true, "needsAnnouncement": true, "needsDan": true}]}},
  { "name": "a gated repository, its start date passed", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "required", "labels": [{ "label": "changelog/visible", "needsSentence": true }, { "label": "changelog/technical", "needsSentence": false }, { "label": "changelog/none", "needsSentence": false }] } },
  { "name": "the same repository spelled in another case", "registry": { "repos": [{ "name": "Board", "repo": "Acme/Board", "changelogFrom": "2026-09-01" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "required", "labels": [{ "label": "changelog/visible", "needsSentence": true }, { "label": "changelog/technical", "needsSentence": false }, { "label": "changelog/none", "needsSentence": false }] } },
  { "name": "on the start date itself", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "2026-11-21" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "required", "labels": [{ "label": "changelog/visible", "needsSentence": true }, { "label": "changelog/technical", "needsSentence": false }, { "label": "changelog/none", "needsSentence": false }] } },
  { "name": "a repository the registry does not list", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01" }] }, "repo": "acme/other", "today": "2026-11-21", "answer": { "state": "not-required", "labels": [] } },
  { "name": "a registry that gates nothing on purpose", "registry": { "repos": [] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "not-required", "labels": [] } },
  { "name": "a start date that has not arrived", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "2026-12-01" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "not-required", "labels": [] } },
  { "name": "listed with no start date, an unfinished setup", "registry": { "repos": [{ "name": "Board", "repo": "acme/board" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "unknown", "labels": [] } },
  { "name": "a start date that is not a date", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "December" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "unknown", "labels": [] } },
  { "name": "a registry that could not be read", "registry": null, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "unknown", "labels": [] } },
  { "name": "no repository named", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01" }] }, "repo": "", "today": "2026-11-21", "answer": { "state": "unknown", "labels": [] } },
  {"name": "a caller that understands needsDan, where the repository names no announcements channel", "flags": ["--needs-dan"], "registry": {"repos": [{"name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01"}]}, "repo": "acme/board", "today": "2026-11-21", "answer": {"state": "required", "labels": [{"label": "changelog/visible", "needsSentence": true, "needsAnnouncement": false, "needsDan": false}, {"label": "changelog/technical", "needsSentence": false, "needsAnnouncement": false, "needsDan": false}, {"label": "changelog/none", "needsSentence": false, "needsAnnouncement": false, "needsDan": false}]}},
  {"name": "a caller that does not say it understands needsDan, where the repository names an announcements channel", "registry": {"repos": [{"name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01", "announceChannel": "C0000TEST01"}]}, "repo": "acme/board", "today": "2026-11-21", "answer": {"state": "required", "labels": [{"label": "changelog/visible", "needsSentence": true}, {"label": "changelog/technical", "needsSentence": false}, {"label": "changelog/none", "needsSentence": false}]}},
  {"name": "an announcements channel that is not a channel id, asked by a caller that understands needsDan", "flags": ["--needs-dan"], "registry": {"repos": [{"name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01", "announceChannel": "#announcements"}]}, "repo": "acme/board", "today": "2026-11-21", "answer": {"state": "unknown", "labels": []}},
  {"name": "an announcements channel that is not a channel id, asked by a caller that does not", "registry": {"repos": [{"name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01", "announceChannel": "#announcements"}]}, "repo": "acme/board", "today": "2026-11-21", "answer": {"state": "unknown", "labels": []}},
  {"name": "a caller that understands needsDan, about a repository the registry does not list", "flags": ["--needs-dan"], "registry": {"repos": [{"name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01", "announceChannel": "C0000TEST01"}]}, "repo": "acme/other", "today": "2026-11-21", "answer": {"state": "not-required", "labels": []}},
  {"name": "a caller that understands needsDan, with a registry that could not be read", "flags": ["--needs-dan"], "registry": null, "repo": "acme/board", "today": "2026-11-21", "answer": {"state": "unknown", "labels": []}}
]

type GateLabelCase = { name: string; flags?: readonly string[]; registry: unknown; repo: string; today: string; answer: { state: string; labels: readonly Record<string, unknown>[] } }
const CASES: readonly GateLabelCase[] = GATE_LABEL_FIXTURES
/** The cases asked the way sleep mode asks: passing the flag that says it understands `needsDan`. */
export const ASKED_BY_THE_MOD: readonly GateLabelCase[] = CASES.filter(c => (c.flags ?? []).includes('--needs-dan'))
/** The cases asked with no flag, as a session running the mod as it was before #3665 asks. */
export const ASKED_WITHOUT_THE_FLAG: readonly GateLabelCase[] = CASES.filter(c => !(c.flags ?? []).length)
const named = (name: string): GateLabelCase => {
  const found = ASKED_BY_THE_MOD.find(c => c.name === name)
  if (!found || found.answer.state !== 'required') throw new Error(`the shared fixtures no longer hold the case "${name}" as a gated repository`)
  return found
}
/** A gated repository naming no announcements channel, as sleep mode is answered about it: three labels. */
export const GATED = named('a caller that understands needsDan, where the repository names no announcements channel')
/** A gated repository naming an announcements channel, as sleep mode is answered about it: the announce label too. The first case, by the rule above. */
export const GATED_AND_ANNOUNCING = named('a caller that understands needsDan, where the repository names an announcements channel')
