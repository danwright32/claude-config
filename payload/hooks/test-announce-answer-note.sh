#!/usr/bin/env bash
# announce-answer-note.sh: Dan's answer about an announcement's wording is noted on this Mac's record
# when he gives it (claude-config#3742 item 1), so a merge that names no session of its own, the
# merge helper's, finds the approval he gave in the session.
#
# Every case runs the REAL hook on the payload Claude Code hands a PostToolUse hook, against a
# session transcript built as Claude Code has written it by then: the picker put, and not yet his
# answer (lib/announce-approval-fixture.sh says how that order was measured). The record is in a
# folder of this suite's own (ANNOUNCE_APPROVALS_DIR), never this Mac's real one, and every
# repository here is invented.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/announce-answer-note.sh"
LIB="$DIR/lib/announce-approval.py"
ENTRY="$DIR/lib/changelog-entry.js"
pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (${2:0:900})"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no announce-answer-note.sh beside this suite at $DIR, so nothing notes Dan's answer about an announcement when he gives it"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
. "$DIR/lib/announce-approval-fixture.sh" 2>/dev/null && declare -F aaf_talk >/dev/null || {
  echo "FAIL: lib/announce-approval-fixture.sh is missing beside this suite, so no session could be built"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
REAL_STORE="${CLAUDE_HOME:-$HOME/.claude}/state/announce-approvals"
real_before="$(ls -la "$REAL_STORE" 2>/dev/null | cksum)"
STORE="$WORK/store"
POST='@here
**Handing a call back**

You can now hand a call back to the queue.'
hash_file() { node "$ENTRY" announcement-hash < "$1" | python3 -c 'import json, sys; print(json.load(sys.stdin)["hash"])'; }
# hook <payload>: the hook on that payload, as "<exit code>|<standard output>|<standard error>".
hook() {
  local out rc
  out="$(printf '%s' "$1" | ANNOUNCE_APPROVALS_DIR="$STORE" bash "$HOOK" 2>"$WORK/err")"; rc=$?
  printf '%s|%s|%s' "$rc" "$out" "$(cat "$WORK/err")"
}
# run <payload>: the hook on that payload, into HRC (its exit code), HOUT (standard output) and HERR
# (standard error). HOOK_FILE names another copy of the hook, and HOOK_PATH a PATH to run it under,
# with bash taken from there.
run() {
  local file="${HOOK_FILE:-$HOOK}"
  if [ -n "${HOOK_PATH:-}" ]; then
    HOUT="$(printf '%s' "$1" | PATH="$HOOK_PATH" ANNOUNCE_APPROVALS_DIR="$STORE" "$HOOK_PATH/bash" "$file" 2>"$WORK/err")"; HRC=$?
  else
    HOUT="$(printf '%s' "$1" | ANNOUNCE_APPROVALS_DIR="$STORE" bash "$file" 2>"$WORK/err")"; HRC=$?
  fi
  HERR="$(cat "$WORK/err")"
}
# told <standard output>: what the hook said, when its standard output is exactly one JSON object
# saying the same words to the person (systemMessage) and to the session (the additionalContext of
# PostToolUse), which is the one form both are shown (lib/hook-notice.sh). Anything else prints
# NOT-A-NOTICE and what was there.
told() {
  printf '%s' "$1" | python3 -c 'import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except ValueError:
    d = None
m = d.get("systemMessage") if isinstance(d, dict) else None
h = d.get("hookSpecificOutput") if isinstance(d, dict) else None
if (not isinstance(m, str) or not m or not isinstance(h, dict) or h.get("hookEventName") != "PostToolUse"
        or h.get("additionalContext") != m):
    print("NOT-A-NOTICE: " + raw[:600], end="")
else:
    print(m, end="")'
}
kinds() { local n; n="$(grep -c "\"kind\": \"$1\"" "$STORE/record.jsonl" 2>/dev/null)"; printf '%s' "${n:-0}"; }
# helper_asks <hash> <pull request>: the merge gate's claim as lib/merge-when-ready.sh hands it the
# payload, with no transcript and a session id that is no session's: "<yes|no>|<why>".
helper_asks() {
  printf '%s' '{"session_id":"merge-when-ready","cwd":"/","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"gh pr merge 7 --squash"}}' \
    | ANNOUNCE_APPROVALS_DIR="$STORE" python3 -B "$LIB" check --repo acme/widget --hash "$1" --pr "$2" --claim \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(("yes" if d["approved"] is True else "no") + "|" + d["why"], end="")'
}

echo "his answer about an announcement is noted when he gives it (#3742 item 1)"

# The route itself: the file opened in front of him, the picker put, the hook once it is answered,
# and then his answer in the transcript.
F="$(aaf_shown "$WORK/wording" "$WORK/talk.jsonl" "$POST")"; T="$WORK/talk.jsonl"
H="$(hash_file "$F")"
P="$(aaf_talk "$T" put acme/widget "$F")"
r="$(hook "$(aaf_talk "$T" payload "$P" acme/widget "$F")")"
check "the hook notes his answer, says nothing and exits 0" "$([[ "$r" == "0||" ]] && echo ok || echo "$r")"
check "the note names the session, the picker and the hash of the file as it stood" "$(grep '"kind": "answered"' "$STORE/record.jsonl" 2>/dev/null | grep "\"picker\": \"$P\"" | grep '"session": "s1"' | grep -q "\"hash\": \"$H\"" && echo ok || cat "$STORE/record.jsonl" 2>&1)"
check "R2 a note is no approval" "$([ "$(kinds approved)" = 0 ] && [[ "$(helper_asks "$H" 7)" == "no|"* ]] && echo ok || cat "$STORE/record.jsonl")"
aaf_talk "$T" answer "$P" acme/widget "$F"
r="$(helper_asks "$H" 7)"
check "R2 still possible: once his Approve is in the transcript, a merge naming no session is approved on it" "$([[ "$r" == "yes|" ]] && echo ok || echo "$r")"

# His Not yet is noted the same way and approves nothing: what he answered is read from the
# transcript, and the payload here even says Approve.
STORE="$WORK/store-notyet"
F="$(aaf_shown "$WORK/wording-notyet" "$WORK/talk-notyet.jsonl" "$POST")"; T="$WORK/talk-notyet.jsonl"
P="$(aaf_talk "$T" put acme/widget "$F")"
r="$(hook "$(aaf_talk "$T" payload "$P" acme/widget "$F" "Approve the wording")")"
aaf_talk "$T" answer "$P" acme/widget "$F" "Not yet"
check "a payload saying Approve is noted like any other" "$([[ "$r" == "0||" ]] && [ "$(kinds answered)" = 1 ] && echo ok || echo "$r")"
r="$(helper_asks "$(hash_file "$F")" 7)"
check "R2 and approves nothing when the transcript says he answered Not yet" "$([[ "$r" == "no|"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r")"

# The form of the hook's own copy of the picker has never been printed: the question tool's schema
# has the dialog write his answers into the input, and what else it changes there is not known. So
# the picker is read from the transcript, by the id the hook was handed, and one whose copy holds
# his answers and no metadata is noted like any other.
STORE="$WORK/store-form"
F="$(aaf_shown "$WORK/wording-form" "$WORK/talk-form.jsonl" "$POST")"; T="$WORK/talk-form.jsonl"
P="$(aaf_talk "$T" put acme/widget "$F")"
r="$(hook "$(AAF_PAYLOAD_FORM="answers nometadata" aaf_talk "$T" payload "$P" acme/widget "$F")")"
check "a payload whose copy of the picker holds his answers and no metadata is noted, and nothing is said" "$([[ "$r" == "0||" ]] && [ "$(kinds answered)" = 1 ] && echo ok || echo "$r")"
aaf_talk "$T" answer "$P" acme/widget "$F"
r="$(helper_asks "$(hash_file "$F")" 7)"
check "R2 still possible: and a merge naming no session is approved on it" "$([[ "$r" == "yes|" ]] && echo ok || echo "$r")"

echo "a picker that is not this one is not noted, and nothing is said"
STORE="$WORK/store-other"
# An ordinary picker: the transcript holds it, and it names no source.
F="$(aaf_shown "$WORK/wording-other" "$WORK/talk-other.jsonl" "$POST")"; T="$WORK/talk-other.jsonl"
P="$(aaf_talk "$T" put acme/widget "$F" plain)"
r="$(hook "$(aaf_talk "$T" payload "$P" acme/widget "$F" "" plain)")"
check "an ordinary picker is not noted, and nothing is said" "$([[ "$r" == "0||" ]] && [ "$(kinds answered)" = 0 ] && echo ok || echo "$r")"
# A picker that only mentions the source's name, in its question, and is of another source.
P="$(aaf_talk "$T" put acme/widget "$F" othersource)"
r="$(hook "$(aaf_talk "$T" payload "$P" acme/widget "$F" "" othersource | python3 -c 'import json, sys
d = json.load(sys.stdin)
d["tool_input"]["questions"][0]["question"] += " (not a changelog-announce picker)"
print(json.dumps(d), end="")')")"
check "a picker of another source that names this one in its words is not noted, and nothing is said" "$([[ "$r" == "0||" ]] && [ "$(kinds answered)" = 0 ] && echo ok || echo "$r")"

echo "a picker nothing says the source of is never left in silence"
# It may be this one in a form nobody has printed. So the hook says, to Dan and to the session both,
# that what the picker asked could not be told, and what to do if it was an announcement.
STORE="$WORK/store-untold"
F="$(aaf_shown "$WORK/wording-untold" "$WORK/talk-untold.jsonl" "$POST")"; T="$WORK/talk-untold.jsonl"
run "$(AAF_PAYLOAD_FORM="answers nometadata" aaf_talk "$T" payload toolu_nowhere1 acme/widget "$F")"
m="$(told "$HOUT")"
check "a picker the transcript does not hold, whose copy carries no metadata, is said to Dan and the session" "$([[ "$HRC" == 0 && "$m" == "ANNOUNCE ANSWER: "*"could not be told"*"does not hold the picker toolu_nowhere1"* ]] && echo ok || echo "$HRC|$m|$HERR")"
check "with the command that reads his answer into the record, and that he is not asked again" "$([[ "$m" == *"--add-label changelog/announce"* && "$m" == *"does not need to be asked again"* ]] && echo ok || echo "$m")"
check "and nothing is noted for it" "$([ "$(kinds answered)" = 0 ] && echo ok || cat "$STORE/record.jsonl")"
run 'not a payload at all'
m="$(told "$HOUT")"
check "input that is no payload is said too" "$([[ "$HRC" == 0 && "$m" == *"could not be told"*"was not a JSON object"* ]] && echo ok || echo "$HRC|$m|$HERR")"
# With no python3 on PATH nothing can read the picker, whatever it asked.
NOPY="$WORK/nopy"; mkdir -p "$NOPY"
for tool in bash cat mktemp rm tr cut; do ln -s "$(command -v "$tool")" "$NOPY/$tool"; done
other='{"session_id":"s1","transcript_path":"/nowhere/talk.jsonl","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_x","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"A"},{"label":"B"}]}]},"tool_response":{"answers":{"Which one?":"A"}}}'
HOOK_PATH="$NOPY" run "$other"
m="$(told "$HOUT")"
check "with python3 missing, a picker whose copy names no source is said as one that could not be told" "$([[ "$HRC" == 0 && "$m" == *"could not be told"*"python3 is not on PATH"* && "$m" != *"about an announcement's wording was not noted"* ]] && echo ok || echo "$HRC|$m|$HERR")"

echo "a note that could not be taken is said to Dan and the session, with what to do"
STORE="$WORK/store-said"
F="$(aaf_shown "$WORK/wording-said" "$WORK/talk-said.jsonl" "$POST")"; T="$WORK/talk-said.jsonl"
P="$(aaf_talk "$T" put acme/widget "$F")"
PAYLOAD="$(aaf_talk "$T" payload "$P" acme/widget "$F")"
HOOK_PATH="$NOPY" run "$PAYLOAD"
m="$(told "$HOUT")"
check "with python3 missing it says the answer was not noted and why, and exits 0 with its notice" "$([[ "$HRC" == 0 && "$m" == *"was not noted"* && "$m" == *"python3 is not on PATH"* && "$m" != *"could not be told"* ]] && echo ok || echo "$HRC|$m|$HERR")"
check "and names the command that reads his answer into the record, and that he is not asked again" "$([[ "$m" == *"--add-label changelog/announce"* && "$m" == *"does not need to be asked again"* ]] && echo ok || echo "$m")"
check "the same words are on standard error, for the debug log" "$([[ "$HERR" == *"was not noted"*"python3 is not on PATH"* ]] && echo ok || echo "$HERR")"
# The record's folder cannot be made.
printf 'not a folder\n' > "$WORK/blocked"
STORE="$WORK/blocked/inner"
run "$PAYLOAD"
m="$(told "$HOUT")"
check "a record that cannot take the note is said, naming it" "$([[ "$HRC" == 0 && "$m" == *"was not noted"*"$STORE/record.jsonl"* ]] && echo ok || echo "$HRC|$m|$HERR")"
STORE="$WORK/store-said"
# A subagent's picker.
run "$(aaf_talk "$T" payload "$P" acme/widget "$F" "" "" "" a9bba4c0ffee)"
m="$(told "$HOUT")"
check "a subagent's picker is not noted, and that is said" "$([[ "$HRC" == 0 && "$m" == *"subagent"* ]] && [ "$(kinds answered)" = 0 ] && echo ok || echo "$HRC|$m|$HERR")"
# The library broken or gone: a hook that could not ask is not one that noted.
BROKEN="$WORK/broken"; mkdir -p "$BROKEN/lib"
cp "$HOOK" "$BROKEN/announce-answer-note.sh"
HOOK_FILE="$BROKEN/announce-answer-note.sh" run "$PAYLOAD"
check "with nothing beside it, it still says the answer was not noted, as JSON that holds a notice" "$([[ "$HRC" == 0 && "$HERR" == *"was not noted"* && "$HOUT" == '{"systemMessage": "'*"was not noted"*'"}' ]] && echo ok || echo "$HRC|$HOUT|$HERR")"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$BROKEN/lib" hook-notice.sh >/dev/null 2>&1
HOOK_FILE="$BROKEN/announce-answer-note.sh" run "$PAYLOAD"
m="$(told "$HOUT")"
check "with the shared payload reader missing it says so, naming the file" "$([[ "$HRC" == 0 && "$m" == *"was not noted"* && "$m" == *"could not load $BROKEN/lib/push-scope.sh"* ]] && echo ok || echo "$HRC|$m|$HERR")"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$BROKEN/lib" push-scope.sh >/dev/null 2>&1
printf 'import sys\nsys.stderr.write("the library broke\\n")\nsys.exit(3)\n' > "$BROKEN/lib/announce-approval.py"
HOOK_FILE="$BROKEN/announce-answer-note.sh" run "$PAYLOAD"
m="$(told "$HOUT")"
check "a library that fails is said, with what it printed" "$([[ "$HRC" == 0 && "$m" == *"was not noted"* && "$m" == *"gave no answer that could be read (rc=3)"* && "$m" == *"the library broke"* ]] && echo ok || echo "$HRC|$m|$HERR")"
rm -f "$BROKEN/lib/announce-approval.py"
HOOK_FILE="$BROKEN/announce-answer-note.sh" run "$PAYLOAD"
m="$(told "$HOUT")"
check "a library that is not there is said" "$([[ "$HRC" == 0 && "$m" == *"was not noted"* ]] && echo ok || echo "$HRC|$m|$HERR")"

echo "the hook is registered where Claude Code runs it"
# Built is not wired (L3): the hooks block beside this suite must run it after a picker is answered.
# Which file that is, in the checkout and installed, is lib/settings-file.sh's to say.
. "$DIR/lib/settings-file.sh" 2>/dev/null || hook_settings_file() { return 1; }
if SETTINGS="$(hook_settings_file "$DIR/..")"; then
  wired="$(python3 -c 'import json, sys
hooks = json.load(open(sys.argv[1], encoding="utf-8")).get("hooks", {})
found = [g.get("matcher") for g in hooks.get("PostToolUse", []) for h in g.get("hooks", [])
         if str(h.get("command", "")).endswith("/hooks/announce-answer-note.sh")]
print(found)' "$SETTINGS" 2>&1)"
  check "settings.hooks.json runs it on PostToolUse for AskUserQuestion, and nowhere else" "$([[ "$wired" == "['AskUserQuestion']" ]] && echo ok || echo "$wired")"
else
  check "the hooks block beside this suite can be found, so the registration can be read" "lib/settings-file.sh found no settings file in $DIR/.."
fi

echo "the record is this suite's own"
check "no case wrote to this Mac's real record" "$([ "$(ls -la "$REAL_STORE" 2>/dev/null | cksum)" = "$real_before" ] && echo ok || echo "$REAL_STORE changed during the run")"

echo "  $pass passed, $fail failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
