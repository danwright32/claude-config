#!/usr/bin/env bash
# Note Dan's answer about an announcement's wording when he gives it (claude-config#3742).
#
# PostToolUse on AskUserQuestion. When the picker just answered is the one that asks him to approve
# an announcement's wording (its metadata names the source changelog-announce), this asks
# lib/announce-approval.py to note it on this Mac's record: which session and picker, and the hash
# of the wording file as it stood then. That library says what a note is and what it is not.
#
# WHY IT EXISTS. An approval used to reach the record only when a later hook read the session's
# transcript: the label hook, on a command putting the label on, or the merge gate, on a typed
# merge. The merge helper (lib/merge-when-ready.sh) hands the gates a payload naming no transcript,
# so on any flow where neither followed his answer the merge was refused, told to ask him, and
# asking him again changed nothing. With the note on the record, whoever asks next reads his answer
# back from the transcript of the session that asked him, the helper included.
#
# WHAT IT DOES NOT DO. It does not read his answer. When this hook runs, the transcript holds the
# picker and not yet what he answered: Claude Code writes a call's result to the transcript after
# that call's PostToolUse hooks have run (measured 2026-11-26: a session's transcript, read at the
# moment a PostToolUse hook of its own call ran, ended at that call's tool_use). The answer is in
# the payload this hook is handed, and it is deliberately not taken from there: a payload is
# whatever the caller hands over, so a run of this hook by hand could say anything. A note therefore
# approves nothing. His answer is read from the transcript when a hook next asks the library, and a
# note of a picker he answered Not yet, or never answered, stays a note.
#
# It never blocks: the picker is already answered. When the note could not be taken it says so on
# standard error and exits 2, which Claude Code shows the session, because a missing note is what
# sends a merge through the helper back to "ask him" for wording he approved. A picker that is not
# this one leaves at the first test, before anything is loaded.
#
# Seam, for the tests: ANNOUNCE_APPROVALS_DIR (read by lib/announce-approval.py) names another record.

set -uo pipefail

payload="$(cat)"

# Every picker reaches this hook. Only one whose input names the source is noted.
case "$payload" in
  *changelog-announce*) ;;
  *) exit 0 ;;
esac

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE="$(cd "${HERE:-/}" && pwd)"

SAYS="Dan's answer about an announcement's wording was not noted on this Mac's record"
THEN="A merge of that pull request through lib/merge-when-ready.sh will not find his approval until a hook reads this session's transcript, which a command putting the label on does: \`gh pr edit <number> --add-label changelog/announce\`, run in this session. He does not need to be asked again."

# The shared reader cleans the payload before python3 parses it (claude-config#1944), and holds the
# one question of whether a reader is installed (ps_reader_missing). Past the test above this is a
# picker about an announcement, so a library that will not load is said, naming the file (#1900).
# shellcheck source=lib/push-scope.sh
. "$HERE/lib/push-scope.sh" 2>/dev/null || {
  echo "ANNOUNCE ANSWER: $SAYS: announce-answer-note.sh could not load $HERE/lib/push-scope.sh, which cleans this hook's input before it is read. Reinstall the hooks with claude-sync pull. $THEN" >&2
  exit 2
}
if ps_reader_missing python3; then
  echo "ANNOUNCE ANSWER: $SAYS: python3 is not on PATH, and lib/announce-approval.py, which keeps that record, runs under it. $THEN" >&2
  exit 2
fi
payload="$(ps_clean_payload "$payload")"

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
out="$(printf '%s' "$payload" | python3 -B "$HERE/lib/announce-approval.py" answered 2>"$err")"
rc=$?

# The library's answer is one JSON object. Read without jq, which this hook has no other use for:
# "noted": true is the clean run, and anything else carries why.
case "$out" in
  *'"noted": true'*) exit 0 ;;
esac
why="$(printf '%s' "$out" | python3 -c 'import json, sys
sys.stdout.reconfigure(errors="replace")
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except ValueError:
    d = None
print(d.get("why", "") if isinstance(d, dict) and d.get("noted") is False else "unread", end="")' 2>/dev/null)"

# Not a picker of this source put to him after all (the word was somewhere else in the call).
[ "$rc" -eq 0 ] && [ -z "$why" ] && exit 0

if [ "$rc" -ne 0 ] || [ "$why" = unread ] || [ -z "$why" ]; then
  echo "ANNOUNCE ANSWER: $SAYS: lib/announce-approval.py gave no answer that could be read (rc=$rc). $(tr '\n' ' ' <"$err" 2>/dev/null | cut -c1-600) $THEN" >&2
  exit 2
fi
echo "ANNOUNCE ANSWER: $why. $THEN" >&2
exit 2
