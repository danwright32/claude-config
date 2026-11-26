#!/usr/bin/env bash
# Note Dan's answer about an announcement's wording when he gives it (claude-config#3742).
#
# PostToolUse on AskUserQuestion. When the picker just answered is the one that asks him to approve
# an announcement's wording (its metadata names the source changelog-announce), this asks
# lib/announce-approval.py to note it on this Mac's record: which session and picker, and the hash
# of the wording file as it stood then. That library says what a note is and what it is not. The
# picker that asks whether a feature is announced to agents at all (source announce-discovery,
# claude-config#3669) is noted the same way, with the feature it names in place of a file.
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
# EVERY PICKER IS ASKED ABOUT, AND NONE IS LEFT IN SILENCE. What this hook is handed has never been
# printed. The question tool's own schema has the dialog write his answers into the call's input,
# and whether the metadata naming the source is still in the hook's copy of it is not known. So no
# test of that copy's text decides whether a picker is this one: the library is asked about every
# picker (they are rare), and it reads the picker from the session's transcript, by the id this hook
# was handed, where it stands as the session sent it. An ordinary picker costs one python3 start and
# says nothing. One that neither copy says the source of (the transcript does not hold it and the
# hook's copy carries no metadata) may be an announcement's in a form nobody has seen, so the hook
# says that what it asked could not be told, and what to do if it was one.
#
# It never blocks: the picker is already answered. Whatever it has to say goes through
# lib/hook-notice.sh as one JSON object on exit 0, with the same words for Dan (systemMessage) and
# for the session (the additionalContext of PostToolUse), because a missing note is what sends a
# merge through the helper back to "ask him" for wording he approved, and both of them can act on
# it. The words are on standard error too, for the debug log.
#
# Seam, for the tests: ANNOUNCE_APPROVALS_DIR (read by lib/announce-approval.py) names another record.

set -uo pipefail

payload="$(cat)"

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130). Found
# before anything else, which lets test-lib-self-locate.sh see it found on any input.
case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE="$(cd "${HERE:-/}" && pwd)"

. "$HERE/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

# How a failure below, one that stops the library being asked at all, is worded. The hook's own copy
# of the picker decides only this, never whether the picker is noted: a copy naming the source is an
# announcement's picker whose note was not taken, and any other is one nobody could tell.
case "$payload" in
  *changelog-announce*) SAYS="Dan's answer about an announcement's wording was not noted on this Mac's record" ;;
  *announce-discovery*) SAYS="Dan's answer about whether a feature is announced to agents was not noted on this Mac's record" ;;
  *) SAYS="Whether the picker Dan just answered asked him about an announcement's wording could not be told, so if it did, his answer was not noted on this Mac's record" ;;
esac
THEN="A merge of the announcement's pull request through lib/merge-when-ready.sh will not find his approval until a hook reads this session's transcript, which a command putting the label on does: \`gh pr edit <number> --add-label changelog/announce\`, run in this session. He does not need to be asked again."
# The other picker this hook notes asks whether a feature is announced at all (claude-config#3669).
# What a missing note of it costs, and what reads his answer in, are its own: chosen by what is being
# said, so a picker the library read from the transcript is spoken of as what it was.
THEN_FEATURE="A session that names no transcript of its own (a merge through lib/merge-when-ready.sh) will not find his answer until a hook reads this session's transcript, which a Bash call that runs create-milestone.sh by name does, and so does a merge typed in this session. He does not need to be asked again."
say() {  # one notice, then the hook is done: hook_allow_notice leaves
  local then="$THEN"
  case "$1" in
    *"whether a feature is announced"*) then="$THEN_FEATURE" ;;
  esac
  hook_allow_notice "ANNOUNCE ANSWER: $1 $then" PostToolUse
}

# The shared reader cleans the payload before python3 parses it (claude-config#1944), and holds the
# one question of whether a reader is installed (ps_reader_missing). A library that will not load is
# said, naming the file (#1900).
# shellcheck source=lib/push-scope.sh
. "$HERE/lib/push-scope.sh" 2>/dev/null \
  || say "$SAYS: announce-answer-note.sh could not load $HERE/lib/push-scope.sh, which cleans this hook's input before it is read. Reinstall the hooks with claude-sync pull."
if ps_reader_missing python3; then
  say "$SAYS: python3 is not on PATH, and lib/announce-approval.py, which reads the picker and keeps that record, runs under it."
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

# The library read the picker and it is not one of this source put to him: nothing to note or say.
[ "$rc" -eq 0 ] && [ -z "$why" ] && exit 0

if [ "$rc" -ne 0 ] || [ "$why" = unread ] || [ -z "$why" ]; then
  say "$SAYS: lib/announce-approval.py gave no answer that could be read (rc=$rc). $(tr '\n' ' ' <"$err" 2>/dev/null | cut -c1-600)"
fi
say "$why."
