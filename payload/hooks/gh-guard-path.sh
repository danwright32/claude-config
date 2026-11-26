#!/usr/bin/env bash
# SessionStart: put the work names guard on gh (hooks/bin/gh) first on this session's PATH
# (claude-config#2183).
#
# Claude Code hands a SessionStart hook CLAUDE_ENV_FILE and sources that file before every Bash
# command the session runs, its subagents' included (measured 2026-11-03 on 2.1.318: a folder
# exported first there is what a python subprocess's "gh" resolves to). So every gh a script runs
# reaches the guard, which judges the text it sends with the publish gate's rule.
#
# check-work-names-publish.sh reads this same line back from the session's env file to know the
# guard is in front; where it is not, it tells the session once that gh writes inside scripts are not
# checked. So this writes the line only when the guard is there to run, and says so when it cannot.

set -uo pipefail

cat >/dev/null 2>&1 || true

case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE="$(cd "${HERE:-/}" && pwd -P)"
BIN="$HERE/bin"

if [ ! -x "$BIN/gh" ]; then
  echo "Work names guard: $BIN/gh is missing or not executable, so the guard on gh is not on PATH this session, and gh writes made inside scripts are not checked for work names until it is reinstalled with claude-sync pull and a new session starts."
  exit 0
fi
if [ -z "${CLAUDE_ENV_FILE:-}" ]; then
  echo "Work names guard: this session was given no CLAUDE_ENV_FILE, so the guard on gh is not on PATH, and gh writes made inside scripts are not checked for work names this session."
  exit 0
fi

line="export PATH=\"$BIN:\$PATH\""
# The hook runs at every SessionStart of one session (a start, a resume, a clear, a compaction)
# against the same env file, so the line goes in only when the file does not already hold it, whole,
# as check-work-names-publish.sh matches it (claude-config#3619). grep exits 0 only on a match: a
# file it cannot read (exit 2) gets the line as before, so the check never leaves a session without
# it. A line naming another guard folder is a different line, so the newer one goes in after it, to
# be first on PATH, and the older one stays.
grep -q -x -F -e "$line" -- "$CLAUDE_ENV_FILE" 2>/dev/null && exit 0
if ! printf '%s\n' "$line" >> "$CLAUDE_ENV_FILE"; then
  echo "Work names guard: could not write to this session's env file, so the guard on gh is not on PATH, and gh writes made inside scripts are not checked for work names this session."
fi
exit 0
