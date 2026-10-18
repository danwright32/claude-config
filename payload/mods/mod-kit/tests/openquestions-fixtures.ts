// The one committed set of cases every reader of an issue's Open questions section is held to on
// fenced code blocks (#1320, L26): mod-kit's openQuestionsIn (hooks/openquestions.ts, tests/
// openquestions.test.ts) and the filing gate's has_open_questions (payload/hooks/issue_field_gate.py,
// payload/hooks/test-require-issue-fields.sh), which is Python and cannot share the TypeScript, so
// both read these. Each case is a body exactly as GitHub holds it, whether a section is found, and
// the open items mod-kit reads (the gate asks only whether the section is there).
//
// The rule both follow (CommonMark's, as GitHub renders it): a line of three or more backticks or
// tildes, after any indentation, opens a fenced block, unless a backtick line has another backtick
// after its fence (that is inline code); a line of the same character, at least as long, with
// nothing but spaces after it, closes it; a block never closed runs to the end of the body. A line
// inside, the fences included, is code: never the heading, never a heading that ends the section,
// never an item.
//
// Everything after the `=` below, to the `]` that closes it at the start of a line, is plain JSON,
// which is what lets the shell suite read it too: keep it JSON (double quotes, no trailing commas,
// no comments inside), or that suite fails.
export const FENCE_FIXTURES = [
  { "name": "a fenced block under the heading holds no items and ends nothing", "body": "B\n\n## Open questions\n\n- [ ] Real?\n\n```\n- [ ] not a question\n## Notes\n```\n- [ ] Also real?\n\n## Notes\n- not one either", "found": true, "open": ["Real?", "Also real?"] },
  { "name": "a fenced example of the heading elsewhere is not the section", "body": "B\n\n```md\n## Open questions\n- [ ] Keep it?\n```\n", "found": false, "open": [] },
  { "name": "a fenced example first, the real section after", "body": "B\n\n```\n## Open questions\n- [ ] example\n```\n\n## Open questions\n\nNone", "found": true, "open": [] },
  { "name": "a tilde fence", "body": "B\n\n~~~\n## Open questions\n- [ ] Keep it?\n~~~\n", "found": false, "open": [] },
  { "name": "a longer fence holding a shorter one", "body": "B\n\n````\n```\n## Open questions\n```\n- [ ] inside?\n````\n\n## Open questions\n- [ ] After?", "found": true, "open": ["After?"] },
  { "name": "a fence never closed runs to the end", "body": "B\n\n```\n## Open questions\n- [ ] Keep it?", "found": false, "open": [] },
  { "name": "a closing fence with words after it closes nothing", "body": "B\n\n```\n``` still code\n## Open questions\n```\n", "found": false, "open": [] },
  { "name": "a backtick line with a backtick after its fence is inline code, not a fence", "body": "```inline``` text\n\n## Open questions\n- [ ] Keep it?", "found": true, "open": ["Keep it?"] },
  { "name": "a tilde fence is not closed by backticks", "body": "B\n\n~~~\n```\n## Open questions\n~~~\n\n## Open questions\n- [ ] After?", "found": true, "open": ["After?"] },
  { "name": "an indented fence in a list item", "body": "- item\n\n    ```\n    ## Open questions\n    - [ ] Keep it?\n    ```\n", "found": false, "open": [] },
  { "name": "line endings GitHub saved as CRLF", "body": "B\r\n\r\n```\r\n## Open questions\r\n```\r\n", "found": false, "open": [] },
  { "name": "a fenced session line does not end the section", "body": "B\n\n## Open questions\n\n```\nClaude-Session: https://claude.ai/code/session_x\n```\n- [ ] Still open?", "found": true, "open": ["Still open?"] }
]
