#!/usr/bin/env bash
# Note every picker Dan answers in a main session, so his answer about an announcement's wording
# can be found later (claude-config#3742, #3789).
#
# PostToolUse on AskUserQuestion. It asks lib/announce-approval.py to note the picker on this Mac's
# record by its ids alone: the session, its transcript and the picker. That library says what a note
# is and what it is not.
#
# WHY IT EXISTS. An approval used to reach the record only when a later hook read the session's
# transcript: the label hook, on a command putting the label on, or the merge gate, on a typed
# merge. The merge helper (lib/merge-when-ready.sh) hands the gates a payload naming no transcript,
# so on any flow where neither followed his answer the merge was refused, told to ask him, and
# asking him again changed nothing. With the note on the record, whoever asks next reads the noted
# picker back from the transcript of the session that asked him, the helper included.
#
# WHY EVERY PICKER, AND WHY IN SILENCE (claude-config#3789). This hook cannot tell what a picker
# asked. Measured on the installed hook, 2026-11-26: for two pickers, one sent with metadata naming
# a source, no line of the session's transcript held the picker's id when the hook ran, and the
# hook's own copy of the picker carried no metadata. Read afterwards, the transcript held both. As
# first built (#3780) the hook noted only a picker it could tell was an announcement's and said a
# notice for one it could not tell, so it noted none and spoke after every picker. So it tells
# nothing: every picker is noted the same way and nothing is said. The hook that next reads the
# transcript (the label hook, the merge gate) judges each noted picker there, an announcement's by
# the rules the library holds and any other settled as none of its business, once. The picker that
# asks whether a feature is announced to agents at all (claude-config#3669) is the library's second
# source: it is noted here like any other, by its ids alone, and judged there by its own rules.
#
# WHAT IT DOES NOT DO. It does not read his answer, and a note approves nothing. The answer is in
# the payload this hook is handed, and it is deliberately not taken from there: a payload is
# whatever the caller hands over, so a run of this hook by hand could say anything. His answer is
# read from the transcript when a hook next asks the library.
#
# A SUBAGENT'S PICKER writes nothing and says nothing, on every path below.
#
# IT SPEAKS ONLY WHEN THE NOTE COULD NOT BE WRITTEN: the record cannot be reached or appended to,
# the hook was not handed the session, its transcript and the picker's id, or the library could not
# be asked at all. That is the one case where an approval of his would be lost, and the hook still
# cannot tell whether the picker was an announcement's, so the notice says what to do if it was and
# that nothing is lost if it was not. It never blocks: the picker is already answered. The notice
# goes through lib/hook-notice.sh as one JSON object on exit 0, with the same words for Dan
# (systemMessage) and for the session (the additionalContext of PostToolUse), and on standard error
# too, for the debug log.
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

SAYS="The picker Dan just answered could not be noted on this Mac's record"
# Two pickers are read back from a note (the library's NOTED_SOURCES): the one that asks him to
# approve an announcement's wording, and the one that asks whether a feature is announced to agents
# at all (claude-config#3669). The hook cannot tell which this was, so the one notice says what
# reads his answer in for each.
THEN="That matters only if the picker asked him one of two things. If it asked him to approve an announcement's wording: a merge of that pull request through lib/merge-when-ready.sh will not find his approval until a hook reads this session's transcript, which a command putting the label on does: \`gh pr edit <number> --add-label changelog/announce\`, run in this session. If it asked him whether a feature is announced to agents: a session that names no transcript of its own (a merge through lib/merge-when-ready.sh) will not find his answer until a hook reads this session's transcript, which a Bash call that runs create-milestone.sh by name does, and so does a merge typed in this session. Either way he does not need to be asked again. If the picker asked him anything else, nothing is lost and there is nothing to do."
# say <why>: the notice, for a failure that stops the library being asked at all. Nothing is parsed
# on these paths, so a subagent's picker is told by the one key only a subagent's payload carries,
# as a JSON key and never as text inside a question (where its quotes are escaped).
say() {
  case "$payload" in *'"agent_id":'*|*'"agent_id" :'*) exit 0 ;; esac
  hook_allow_notice "ANNOUNCE ANSWER: $1 $THEN" PostToolUse
}

# The shared reader cleans the payload before python3 parses it (claude-config#1944), and holds the
# one question of whether a reader is installed (ps_reader_missing). A library that will not load is
# said, naming the file (#1900).
# shellcheck source=lib/push-scope.sh
. "$HERE/lib/push-scope.sh" 2>/dev/null \
  || say "$SAYS: announce-answer-note.sh could not load $HERE/lib/push-scope.sh, which cleans this hook's input before it is read. Reinstall the hooks with claude-sync pull."
if ps_reader_missing python3; then
  say "$SAYS: python3 is not on PATH, and lib/announce-approval.py, which keeps that record, runs under it."
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

# The library noted nothing and lost nothing by it (a subagent's picker, or no picker): nothing to say.
[ "$rc" -eq 0 ] && [ -z "$why" ] && exit 0

if [ "$rc" -ne 0 ] || [ "$why" = unread ] || [ -z "$why" ]; then
  say "$SAYS: lib/announce-approval.py gave no answer that could be read (rc=$rc). $(tr '\n' ' ' <"$err" 2>/dev/null | cut -c1-600)"
fi
# The library's own words for a note that could not be written. It answers a subagent's picker
# before this, so these are never a subagent's.
hook_allow_notice "ANNOUNCE ANSWER: $why. $THEN" PostToolUse
