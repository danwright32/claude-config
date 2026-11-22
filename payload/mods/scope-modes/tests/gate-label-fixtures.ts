// The one committed fixture set both sides of one question are held to (#3439, L58): which label a
// project's merge gate requires on a pull request. The gate answers it (requiredLabels in
// payload/hooks/lib/changelog-entry.js, tested in changelog-entry.test.js beside it, which reads this
// file), and sleep mode reads that answer (gateAnswerOf in hooks/requiredlabel.ts, tested in
// tests/requiredlabel.test.ts). Each case is a registry as the gate's own reader hands it over
// (null: it could not be read), the repository asked about, the day, and the answer both must agree
// on: `state`, and for a gated repository every label the gate takes with whether the gate accepts
// it on a pull request whose description carries no Changelog sentence.
//
// Everything after the `=` below, to the `]` that closes it at the start of a line, is plain JSON,
// which is what lets the node suite read it too: keep it JSON (double quotes, no trailing commas,
// no comments inside), or that suite fails.
export const GATE_LABEL_FIXTURES = [
  { "name": "a gated repository, its start date passed", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "required", "labels": [{ "label": "changelog/visible", "needsSentence": true }, { "label": "changelog/technical", "needsSentence": false }, { "label": "changelog/none", "needsSentence": false }] } },
  { "name": "the same repository spelled in another case", "registry": { "repos": [{ "name": "Board", "repo": "Acme/Board", "changelogFrom": "2026-09-01" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "required", "labels": [{ "label": "changelog/visible", "needsSentence": true }, { "label": "changelog/technical", "needsSentence": false }, { "label": "changelog/none", "needsSentence": false }] } },
  { "name": "on the start date itself", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "2026-11-21" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "required", "labels": [{ "label": "changelog/visible", "needsSentence": true }, { "label": "changelog/technical", "needsSentence": false }, { "label": "changelog/none", "needsSentence": false }] } },
  { "name": "a repository the registry does not list", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01" }] }, "repo": "acme/other", "today": "2026-11-21", "answer": { "state": "not-required", "labels": [] } },
  { "name": "a registry that gates nothing on purpose", "registry": { "repos": [] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "not-required", "labels": [] } },
  { "name": "a start date that has not arrived", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "2026-12-01" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "not-required", "labels": [] } },
  { "name": "listed with no start date, an unfinished setup", "registry": { "repos": [{ "name": "Board", "repo": "acme/board" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "unknown", "labels": [] } },
  { "name": "a start date that is not a date", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "December" }] }, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "unknown", "labels": [] } },
  { "name": "a registry that could not be read", "registry": null, "repo": "acme/board", "today": "2026-11-21", "answer": { "state": "unknown", "labels": [] } },
  { "name": "no repository named", "registry": { "repos": [{ "name": "Board", "repo": "acme/board", "changelogFrom": "2026-09-01" }] }, "repo": "", "today": "2026-11-21", "answer": { "state": "unknown", "labels": [] } }
]
