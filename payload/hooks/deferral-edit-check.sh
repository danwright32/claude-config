#!/usr/bin/env bash
#
# deferral-edit-check.sh
# Claude Code PostToolUse(Edit|Write|MultiEdit) hook.
#
# The moment a comment or a doc line that puts work off is WRITTEN, ask for the issue number,
# while the session that wrote it is still there to file one (claude-config#430). The push hook
# beside this, check-deferrals.sh, is the backstop for whatever slips past; this is the half that
# reaches the model at the right moment, with the line still on its screen.
#
# THE RULE lives in ONE detector, lib/deferrals.py, shared with the push hook, and the phrase list
# in lib/deferral-phrases.txt. This file decides nothing about what a deferral is. It hands the
# whole tool payload to the detector's --edit-payload mode, which reads the new text
# (tool_input.new_string for Edit, tool_input.content for Write, each edit's new_string for
# MultiEdit) and locates it inside the file just written, so the two lines either side that can
# carry the issue number are the REAL neighbours in the file rather than the fragment alone.
#
# Never fires on the phrase list, on the guard's own files or on the config repo's test suites,
# whose fixtures are made of the phrases; that exemption is the detector's (is_exempt), so both
# hooks agree on it (L41).
#
# The measurement behind the phrase list (Slate main, 2026-09-18, 1,681 files) is recorded in the
# header of check-deferrals.sh, once, rather than copied here.
#
# On a finding: exit 2 with the finding on stderr and what to do, which PostToolUse feeds back to
# the model. Fails QUIET (exit 0, nothing said) on a payload it cannot read, because this runs on
# every edit in every project and has nothing to say about a tool call it cannot see.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="$HOOK_DIR/lib/deferrals.py"
[ -f "$DETECTOR" ] || exit 0

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

findings="$(printf '%s' "$payload" | python3 "$DETECTOR" --edit-payload 2>/dev/null)" || exit 0
[ -n "$findings" ] || exit 0

fragment=0
case "$findings" in *":new text line "*) fragment=1 ;; esac

{
  echo "DEFERRAL WITHOUT AN ISSUE: the text just written puts work off and names no issue."
  printf '%s\n' "$findings" | awk 'NR <= 10'
  if [ "$fragment" -eq 1 ]; then
    echo "(The new text was not found where the tool said it wrote it, so the line numbers count"
    echo "from the start of the text just written and its neighbours in the file were not read.)"
  fi
  echo ""
  echo "Before moving on: file the issue for this work (gh issue create, with its milestone,"
  echo "priority and category) and put its number beside the line, as #NNNN on the line or"
  echo "within two lines of it. If the line is not a deferral, reword it so it does not read as"
  echo "one. A deferral with no issue is one nothing will ever schedule (L65). The push gate"
  echo "check-deferrals.sh refuses the same line at push time."
} >&2
exit 2
