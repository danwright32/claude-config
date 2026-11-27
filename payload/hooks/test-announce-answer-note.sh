#!/usr/bin/env bash
# announce-answer-note.sh: every picker Dan answers in a main session is noted on this Mac's record
# by its ids alone, in silence (claude-config#3742 item 1, #3789), so a merge that names no session
# of its own, the merge helper's, finds the approval he gave in the session, and an ordinary picker
# costs him nothing to read.
#
# Every case runs the REAL hook on the payload Claude Code hands a PostToolUse hook, against a
# session transcript built in one of the two orders measured (lib/announce-approval-fixture.sh says
# how): the picker's line already there and not yet his answer, or neither there yet. The record is
# in a folder of this suite's own (ANNOUNCE_APPROVALS_DIR), never this Mac's real one, every
# repository here is invented, and no line of any transcript here is copied from a real one.
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
# line_of <kind> <picker>: the record's line of that kind for that picker.
line_of() { grep "\"kind\": \"$1\"" "$STORE/record.jsonl" 2>/dev/null | grep "\"picker\": \"$2\""; }
# has <kind> <picker> <needle>...: whether the record holds a line of that kind for that picker, and
# it holds every needle. The line is read into a variable and matched there, never piped into a
# quiet grep, which under pipefail can report a failure that never happened (test-pipefail-shortcircuit.sh).
has() {
  local line needle kind="$1" picker="$2"; shift 2
  line="$(line_of "$kind" "$picker")"
  [ -n "$line" ] || return 1
  for needle in "$@"; do [[ "$line" == *"$needle"* ]] || return 1; done
}
# ids_only <picker> <transcript> <held>: ok when the record's one note of that picker names the
# session, its transcript and the picker, says whether the transcript held the picker's line when
# the hook ran (true, false or null), and names nothing else: no source, repository, file or hash.
ids_only() {
  line_of answered "$1" | python3 -c 'import json, sys
lines = [json.loads(l) for l in sys.stdin if l.strip()]
want = {"kind": "answered", "session": "s1", "transcript": sys.argv[2], "picker": sys.argv[1], "held": json.loads(sys.argv[3])}
if len(lines) != 1:
    print("%d notes of %s" % (len(lines), sys.argv[1]), end="")
elif {k: v for k, v in lines[0].items() if k != "at"} != want or not lines[0].get("at"):
    print("the note is " + json.dumps(lines[0]), end="")
else:
    print("ok", end="")' "$@"
}
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
check "#3789 the note says the transcript held the picker's line when the hook ran" "$(has answered "$P" '"held": true' && echo ok || cat "$STORE/record.jsonl" 2>&1)"
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

echo "an ordinary picker is silent, noted by its ids alone, and settled by the hook that next reads the transcript (#3789)"
STORE="$WORK/store-other"
# An ordinary picker: the transcript holds it, and it names no source.
F="$(aaf_shown "$WORK/wording-other" "$WORK/talk-other.jsonl" "$POST")"; T="$WORK/talk-other.jsonl"
P="$(aaf_talk "$T" put acme/widget "$F" plain)"
r="$(hook "$(aaf_talk "$T" payload "$P" acme/widget "$F" "" plain)")"
check "#3789 an ordinary picker is silent: exit 0, and nothing on standard output or standard error" "$([[ "$r" == "0||" ]] && echo ok || echo "$r")"
check "#3789 and is noted by its ids alone" "$(ids_only "$P" "$T" true)"
# He answered it with the approving words, and it approves nothing: it is no picker of this source.
aaf_talk "$T" answer "$P" acme/widget "$F" "Approve the wording" plain
r="$(helper_asks "$(hash_file "$F")" 7)"
check "R2 #3789 a note of an ordinary picker approves nothing, whatever he answered it" "$([[ "$r" == "no|"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r $(cat "$STORE/record.jsonl")")"
check "#3789 and the hook that read the transcript settled it as no picker of this source" "$(has settled "$P" 'no picker of a source' && echo ok || cat "$STORE/record.jsonl")"
# Settled, it is never read again: with the transcript gone, the next question does not look for it.
mv "$T" "$T.away"
r="$(helper_asks "$(hash_file "$F")" 7)"
check "#3789 a settled picker is not read back again" "$([[ "$r" == "no|"* && "$r" != *"could not be read back"* ]] && [ "$(kinds settled)" = 1 ] && echo ok || echo "$r $(kinds settled) settled")"
mv "$T.away" "$T"
# A picker that only mentions the source's name, in its question, and is of another source.
P="$(aaf_talk "$T" put acme/widget "$F" othersource)"
r="$(hook "$(aaf_talk "$T" payload "$P" acme/widget "$F" "" othersource | python3 -c 'import json, sys
d = json.load(sys.stdin)
d["tool_input"]["questions"][0]["question"] += " (not a changelog-announce picker)"
print(json.dumps(d), end="")')")"
check "#3789 a picker of another source that names this one in its words is silent, and noted by its ids alone" "$([[ "$r" == "0||" ]] && ids_only "$P" "$T" true || echo "$r")"
aaf_talk "$T" answer "$P" acme/widget "$F" "Approve the wording" othersource
r="$(helper_asks "$(hash_file "$F")" 7)"
check "R2 #3789 and approves nothing, and is settled" "$([[ "$r" == "no|"* ]] && [ "$(kinds approved)" = 0 ] && has settled "$P" 'no picker of a source' && echo ok || echo "$r $(cat "$STORE/record.jsonl")")"

echo "the picker's line is not in the transcript when the hook runs, and is there later (#3789, as measured)"
# Measured on the installed hook, 2026-11-26: no line of the transcript held the picker's id when
# the hook ran, and the hook's copy of the picker carried no metadata. The transcript read afterwards
# held the picker, as the session sent it. So the hook cannot tell what such a picker asked, and
# notes it by its ids; the hook that next reads the transcript judges it.
STORE="$WORK/store-late"
F="$(aaf_shown "$WORK/wording-late" "$WORK/talk-late.jsonl" "$POST")"; T="$WORK/talk-late.jsonl"
H="$(hash_file "$F")"
r="$(hook "$(AAF_PAYLOAD_FORM="answers nometadata" aaf_talk "$T" payload toolu_late1 acme/widget "$F")")"
check "#3789 a picker the transcript does not hold yet, whose copy carries no metadata, is silent" "$([[ "$r" == "0||" ]] && echo ok || echo "$r")"
check "#3789 and is noted by its ids alone, saying the transcript did not hold its line" "$(ids_only toolu_late1 "$T" false)"
check "R2 #3789 the note approves nothing while the transcript holds no answer of his" "$([[ "$(helper_asks "$H" 7)" == "no|"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || cat "$STORE/record.jsonl")"
aaf_talk "$T" late toolu_late1 acme/widget "$F"
aaf_talk "$T" answer toolu_late1 acme/widget "$F"
r="$(helper_asks "$H" 7)"
check "R2 still possible #3789: once the transcript holds the picker and his Approve, a merge naming no session is approved on it" "$([[ "$r" == "yes|" ]] && echo ok || echo "$r")"
check "#3789 and his approval is on the record, as the picker it came from" "$(has approved toolu_late1 "\"hash\": \"$H\"" && echo ok || cat "$STORE/record.jsonl")"
# The same, with the file changed after he answered: no hash was noted when he answered, so the
# wording he answered about cannot be told from the file, and his Approve does not count.
STORE="$WORK/store-late-changed"
F="$(aaf_shown "$WORK/wording-late-changed" "$WORK/talk-late-changed.jsonl" "$POST")"; T="$WORK/talk-late-changed.jsonl"
H="$(hash_file "$F")"
hook "$(AAF_PAYLOAD_FORM="answers nometadata" aaf_talk "$T" payload toolu_late2 acme/widget "$F")" >/dev/null
aaf_talk "$T" late toolu_late2 acme/widget "$F"
aaf_talk "$T" answer toolu_late2 acme/widget "$F"
printf 'A line nobody showed him.\n' >> "$F"
r="$(helper_asks "$(hash_file "$F")" 7)"
check "R2 #3789 what the file holds after a write that followed his answer is not approved" "$([[ "$r" == "no|"*"has changed since he answered"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r")"
check "#3789 and the refusal says to ask him again" "$([[ "$r" == *"ask him again"* ]] && echo ok || echo "$r")"
r="$(helper_asks "$H" 7)"
check "R2 #3789 nor is what it held before, which nothing noted: his Approve does not count" "$([[ "$r" == "no|"*"has changed since he answered"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r")"
# Words typed beside his Approve: read from the transcript when the picker is judged.
STORE="$WORK/store-late-typed"
F="$(aaf_shown "$WORK/wording-late-typed" "$WORK/talk-late-typed.jsonl" "$POST")"; T="$WORK/talk-late-typed.jsonl"
H="$(hash_file "$F")"
r="$(hook "$(AAF_PAYLOAD_FORM="answers nometadata" aaf_talk "$T" payload toolu_late3 acme/widget "$F" "" "typed:approve, but fix line 2")")"
aaf_talk "$T" late toolu_late3 acme/widget "$F"
aaf_talk "$T" answer toolu_late3 acme/widget "$F" "" "typed:approve, but fix line 2"
check "#3789 an Approve with words typed beside it is silent and noted by its ids alone" "$([[ "$r" == "0||" ]] && ids_only toolu_late3 "$T" false || echo "$r")"
r="$(helper_asks "$H" 7)"
check "R2 #3789 and approves nothing: the refusal gives his words" "$([[ "$r" == "no|"*"approves nothing"*"approve, but fix line 2"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r")"
check "#3789 and it is on the record as an answer of his that is no approval" "$(has withdrawn toolu_late3 "\"hash\": \"$H\"" && echo ok || cat "$STORE/record.jsonl")"

echo "a long session's transcript is read inside the hook's time (#3789, the size control)"
# The transcript the hook was measured against on 2026-11-26 was 18.8 MB and about 9,400 lines. One that size,
# built here, with the picker put at its end: the hook finds the picker and notes it with its hash,
# and the question that reads the transcript back finds his answer, each well inside the 15 seconds
# Claude Code gives the hook. So a reader too slow for a long transcript is not why the installed
# hook found nothing.
STORE="$WORK/store-long"
T="$WORK/talk-long.jsonl"; mkdir -p "$WORK/wording-long"; F="$WORK/wording-long/announcement.md"
printf '%s\n' "$POST" > "$F"
aaf_new "$T"
aaf_bulk "$T" 10000 2000
aaf_talk "$T" write "$F"
aaf_talk "$T" bash "$AAF_BBEDIT --front-window $F"
long_bytes="$(wc -c < "$T" | tr -d ' ')"; long_lines="$(wc -l < "$T" | tr -d ' ')"
check "the long transcript is the measured size: about 20 MB and 10,000 lines" "$([ "$long_bytes" -ge 18000000 ] && [ "$long_lines" -ge 10000 ] && echo ok || echo "$long_bytes bytes, $long_lines lines")"
H="$(hash_file "$F")"
P="$(aaf_talk "$T" put acme/widget "$F")"
PAYLOAD_LONG="$(AAF_PAYLOAD_FORM="answers nometadata" aaf_talk "$T" payload "$P" acme/widget "$F")"
began="$(python3 -c 'import time; print(time.monotonic())')"
r="$(hook "$PAYLOAD_LONG")"
took="$(python3 -c 'import sys, time; print("%.2f" % (time.monotonic() - float(sys.argv[1])))' "$began")"
check "#3789 the hook finds the picker in a 20 MB transcript and notes it with the file's hash, in silence ($took s)" "$([[ "$r" == "0||" ]] && has answered "$P" '"held": true' "\"hash\": \"$H\"" && echo ok || echo "$r $(cat "$STORE/record.jsonl" 2>&1)")"
check "#3789 inside the hook's 15 seconds, with room ($took s)" "$(python3 -c 'import sys; print("ok" if float(sys.argv[1]) < 8 else "the hook took " + sys.argv[1] + " seconds", end="")' "$took")"
hook_took="$took"
aaf_talk "$T" answer "$P" acme/widget "$F"
began="$(python3 -c 'import time; print(time.monotonic())')"
r="$(helper_asks "$H" 7)"
took="$(python3 -c 'import sys, time; print("%.2f" % (time.monotonic() - float(sys.argv[1])))' "$began")"
check "#3789 and the question that reads it back finds his answer there ($took s)" "$([[ "$r" == "yes|" ]] && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 8 else 1)' "$took" && echo ok || echo "$r after $took s")"
# The one pass itself, in process, with no start of bash, python3 or node in it: the number the
# library's NOTED_SESSIONS comment quotes.
pass_took="$(python3 -B -c 'import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("announce_approval", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
began = time.monotonic()
found = lib._asked(sys.argv[2], "s1", {sys.argv[3]}, set())
print("%.3f|%d" % (time.monotonic() - began, len(found)), end="")' "$LIB" "$T" "$P" 2>&1)"
check "#3789 one pass over the 20 MB transcript finds the picker (${pass_took%%|*} s)" "$([[ "$pass_took" == *"|1" ]] && echo ok || echo "$pass_took")"
printf '  measured on %s bytes, %s lines: the hook %s s, the read back %s s, one pass alone %s s\n' "$long_bytes" "$long_lines" "$hook_took" "$took" "${pass_took%%|*}"

echo "a notice is said only when the note itself could not be written (#3789)"
# That is the one case where an approval would be lost: the hook cannot tell what the picker asked,
# so it says what to do if it was an announcement's, and that nothing is lost if it was not.
NOPY="$WORK/nopy"; mkdir -p "$NOPY"
for tool in bash cat mktemp rm tr cut; do ln -s "$(command -v "$tool")" "$NOPY/$tool"; done
STORE="$WORK/store-untold"
run 'not a payload at all'
m="$(told "$HOUT")"
check "#3789 input that is no payload is said: the hook was handed no picker to note" "$([[ "$HRC" == 0 && "$m" == "ANNOUNCE ANSWER: "*"could not be noted"*"was not a JSON object"* ]] && echo ok || echo "$HRC|$m|$HERR")"
other='{"session_id":"s1","transcript_path":"/nowhere/talk.jsonl","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_x","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"A"},{"label":"B"}]}]},"tool_response":{"answers":{"Which one?":"A"}}}'
run "$(printf '%s' "$other" | python3 -c 'import json, sys
d = json.load(sys.stdin)
del d["tool_use_id"]
print(json.dumps(d), end="")')"
m="$(told "$HOUT")"
check "#3789 a payload naming no picker id is said, with what the hook was not told" "$([[ "$HRC" == 0 && "$m" == *"could not be noted"*"was not told the session, its transcript and the picker's id"* ]] && [ "$(kinds answered)" = 0 ] && echo ok || echo "$HRC|$m|$HERR")"
# With no python3 on PATH nothing can write the note, whatever the picker asked.
HOOK_PATH="$NOPY" run "$other"
m="$(told "$HOUT")"
check "#3789 with python3 missing, the picker is said as one that could not be noted" "$([[ "$HRC" == 0 && "$m" == *"could not be noted"*"python3 is not on PATH"* ]] && echo ok || echo "$HRC|$m|$HERR")"
check "#3789 the notice says what to do if it asked about an announcement, and that nothing is lost if it did not" "$([[ "$m" == *"only if"*"--add-label changelog/announce"*"does not need to be asked again"*"nothing is lost"* ]] && echo ok || echo "$m")"

STORE="$WORK/store-said"
F="$(aaf_shown "$WORK/wording-said" "$WORK/talk-said.jsonl" "$POST")"; T="$WORK/talk-said.jsonl"
P="$(aaf_talk "$T" put acme/widget "$F")"
PAYLOAD="$(aaf_talk "$T" payload "$P" acme/widget "$F")"
HOOK_PATH="$NOPY" run "$PAYLOAD"
m="$(told "$HOUT")"
check "with python3 missing an announcement's picker is said the same way, and exits 0 with its notice" "$([[ "$HRC" == 0 && "$m" == *"could not be noted"* && "$m" == *"python3 is not on PATH"* ]] && echo ok || echo "$HRC|$m|$HERR")"
check "the same words are on standard error, for the debug log" "$([[ "$HERR" == *"could not be noted"*"python3 is not on PATH"* ]] && echo ok || echo "$HERR")"
# The record's folder cannot be made: the one case the hook itself meets where an approval would be lost.
printf 'not a folder\n' > "$WORK/blocked"
STORE="$WORK/blocked/inner"
run "$PAYLOAD"
m="$(told "$HOUT")"
check "#3789 a record that cannot take the note is said to Dan and the session, naming it" "$([[ "$HRC" == 0 && "$m" == "ANNOUNCE ANSWER: "*"could not be noted"*"$STORE/record.jsonl"* ]] && echo ok || echo "$HRC|$m|$HERR")"
check "#3789 with the command that reads his answer into the record, and that he is not asked again" "$([[ "$m" == *"only if"*"--add-label changelog/announce"*"does not need to be asked again"*"nothing is lost"* ]] && echo ok || echo "$m")"
PLAIN="$(aaf_talk "$T" put acme/widget "$F" plain)"
run "$(aaf_talk "$T" payload "$PLAIN" acme/widget "$F" "" plain)"
m="$(told "$HOUT")"
check "#3789 and so is an ordinary picker's, since the hook cannot leave a note for whoever would judge it" "$([[ "$HRC" == 0 && "$m" == *"could not be noted"*"$STORE/record.jsonl"* ]] && echo ok || echo "$HRC|$m|$HERR")"
# The record is there and cannot be appended to. A file made read only still takes a write from
# root, so a run as root cannot make this state, and says so in place of a result (L411).
STORE="$WORK/store-readonly"; mkdir -p "$STORE"; printf '' > "$STORE/record.jsonl"; chmod a-w "$STORE/record.jsonl" "$STORE"
if [ "$(id -u)" = 0 ]; then
  echo "SUITE-PART-UNMEASURED #3789 the notice for a record that cannot be appended to, because this run is root's, which a read only record still takes a line from"
else
  run "$PAYLOAD"
  m="$(told "$HOUT")"
  check "#3789 a record that cannot be appended to is said, naming it" "$([[ "$HRC" == 0 && "$m" == *"could not be noted"*"$STORE/record.jsonl"* ]] && [ ! -s "$STORE/record.jsonl" ] && echo ok || echo "$HRC|$m|$HERR")"
fi
chmod u+w "$STORE" "$STORE/record.jsonl"

echo "a subagent's picker writes nothing and says nothing (#3789)"
STORE="$WORK/store-said"
run "$(aaf_talk "$T" payload "$P" acme/widget "$F" "" "" "" a9bba4c0ffee)"
check "#3789 a subagent's approval picker is not noted, and nothing is said" "$([[ "$HRC|$HOUT|$HERR" == "0||" ]] && [ "$(kinds answered)" = 0 ] && echo ok || echo "$HRC|$HOUT|$HERR")"
run "$(AAF_PAYLOAD_FORM="answers nometadata" aaf_talk "$T" payload toolu_subagent1 acme/widget "$F" "" plain "" a9bba4c0ffee)"
check "#3789 nor is a subagent's ordinary picker" "$([[ "$HRC|$HOUT|$HERR" == "0||" ]] && [ "$(kinds answered)" = 0 ] && [ ! -e "$STORE/record.jsonl" ] && echo ok || echo "$HRC|$HOUT|$HERR")"
STORE="$WORK/blocked/inner"
run "$(aaf_talk "$T" payload "$P" acme/widget "$F" "" "" "" a9bba4c0ffee)"
check "#3789 with a record that could take no note, a subagent's picker still says nothing" "$([[ "$HRC|$HOUT|$HERR" == "0||" ]] && echo ok || echo "$HRC|$HOUT|$HERR")"
HOOK_PATH="$NOPY" run "$(aaf_talk "$T" payload "$P" acme/widget "$F" "" "" "" a9bba4c0ffee)"
check "#3789 and with python3 missing too" "$([[ "$HRC|$HOUT|$HERR" == "0||" ]] && echo ok || echo "$HRC|$HOUT|$HERR")"
STORE="$WORK/store-said"

echo "a hook that could not ask the library is not one that noted"
BROKEN="$WORK/broken"; mkdir -p "$BROKEN/lib"
cp "$HOOK" "$BROKEN/announce-answer-note.sh"
HOOK_FILE="$BROKEN/announce-answer-note.sh" run "$PAYLOAD"
check "with nothing beside it, it still says the picker could not be noted, as JSON that holds a notice" "$([[ "$HRC" == 0 && "$HERR" == *"could not be noted"* && "$HOUT" == '{"systemMessage": "'*"could not be noted"*'"}' ]] && echo ok || echo "$HRC|$HOUT|$HERR")"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$BROKEN/lib" hook-notice.sh >/dev/null 2>&1
HOOK_FILE="$BROKEN/announce-answer-note.sh" run "$PAYLOAD"
m="$(told "$HOUT")"
check "with the shared payload reader missing it says so, naming the file" "$([[ "$HRC" == 0 && "$m" == *"could not be noted"* && "$m" == *"could not load $BROKEN/lib/push-scope.sh"* ]] && echo ok || echo "$HRC|$m|$HERR")"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$BROKEN/lib" push-scope.sh >/dev/null 2>&1
printf 'import sys\nsys.stderr.write("the library broke\\n")\nsys.exit(3)\n' > "$BROKEN/lib/announce-approval.py"
HOOK_FILE="$BROKEN/announce-answer-note.sh" run "$PAYLOAD"
m="$(told "$HOUT")"
check "a library that fails is said, with what it printed" "$([[ "$HRC" == 0 && "$m" == *"could not be noted"* && "$m" == *"gave no answer that could be read (rc=3)"* && "$m" == *"the library broke"* ]] && echo ok || echo "$HRC|$m|$HERR")"
rm -f "$BROKEN/lib/announce-approval.py"
HOOK_FILE="$BROKEN/announce-answer-note.sh" run "$PAYLOAD"
m="$(told "$HOUT")"
check "a library that is not there is said" "$([[ "$HRC" == 0 && "$m" == *"could not be noted"* ]] && echo ok || echo "$HRC|$m|$HERR")"

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

echo "the picker that asks whether a feature is announced is noted as every picker is: by its ids alone, in silence (#3669, #3789)"
# helper_decides <feature>: what a hook naming no session and no transcript (the merge helper's
# payload) is told Dan last answered about announcing that feature of acme/widget: "<answer>".
helper_decides() {
  printf '{"session_id": "merge-when-ready", "hook_event_name": "PreToolUse", "tool_name": "Bash"}' \
    | ANNOUNCE_APPROVALS_DIR="$STORE" aaf_hook_decision "$LIB" acme/widget "$1" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["answer"], end="")'
}
STORE="$WORK/store-deciding"
T="$WORK/deciding.jsonl"; aaf_new "$T"
# The form measured on the installed hook: the transcript does not hold the picker's line yet, and
# the hook's own copy carries no metadata.
run "$(AAF_PAYLOAD_FORM=nometadata aaf_talk "$T" decide-payload toolu_dlate1 acme/widget "Hand back" "Not announcing")"
check "#3669 a discovery picker the transcript does not hold yet is silent" "$([[ "$HRC|$HOUT|$HERR" == "0||" ]] && echo ok || echo "$HRC|$HOUT|$HERR")"
check "#3669 and is noted by its ids alone, saying the transcript did not hold its line" "$(ids_only toolu_dlate1 "$T" false)"
check "R9 #3669 the note is not his answer: nothing is decided by it" "$([[ "$(helper_decides "Hand back")" == none ]] && [ "$(kinds decided)" = 0 ] && echo ok || helper_decides "Hand back")"
aaf_talk "$T" decide-late toolu_dlate1 acme/widget "Hand back"
aaf_talk "$T" decide-answer toolu_dlate1 acme/widget "Hand back" "Not announcing"
check "R9 still possible #3669: once the transcript holds the picker and his Not announcing, a call naming no session reads it through the hook's note" "$([[ "$(helper_decides "Hand back")" == no ]] && has decided toolu_dlate1 '"answer": "no"' '"session": "s1"' && echo ok || echo "$(helper_decides "Hand back") $(cat "$STORE/record.jsonl")")"
# A picker the transcript already holds, handed to the hook with its metadata: still by its ids
# alone. Nothing the hook can tell of this picker (its source, the feature, his answer) is written.
id="$(aaf_talk "$T" decide-put acme/widget "Hand over")"
run "$(aaf_talk "$T" decide-payload "$id" acme/widget "Hand over" "Announce it")"
check "#3669 a discovery picker the transcript holds is silent, and noted by its ids alone" "$([[ "$HRC|$HOUT|$HERR" == "0||" ]] && ids_only "$id" "$T" true || echo "$HRC|$HOUT|$HERR")"
run "$(aaf_talk "$T" decide-payload toolu_dagent acme/widget "Hand over" "Not announcing" "" "" a9bba4c0ffee)"
check "#3669 a subagent's discovery picker is not noted, and nothing is said" "$([[ "$HRC|$HOUT|$HERR" == "0||" ]] && [ "$(kinds answered)" = 2 ] && echo ok || echo "$HRC|$HOUT|$HERR $(kinds answered) notes")"
# A note that cannot be written is the hook's one notice. The hook cannot tell which picker it was,
# so the notice says what reads his answer in for each kind it may have been.
# The record's folder is under a FILE, which nothing can make a folder in, whoever runs the suite.
STORE="$WORK/store-deciding-blocked/inner"
: > "$WORK/store-deciding-blocked"
id="$(aaf_talk "$T" decide-put acme/widget "Hand off")"
run "$(aaf_talk "$T" decide-payload "$id" acme/widget "Hand off" "Not announcing")"
said="$(told "$HOUT")"
check "#3669 a note of it that cannot be written is said, to Dan and the session, naming the record" "$([[ "$HRC" == 0 && "$said" == "ANNOUNCE ANSWER: "*"could not be noted"*"$STORE/record.jsonl"* ]] && echo ok || echo "rc=$HRC $said")"
check "#3669 the notice says what reads his answer about a feature into the record: a Bash call that runs create-milestone.sh, or a merge typed in that session" "$([[ "$said" == *"whether a feature is announced to agents"*"create-milestone.sh"*"merge typed in this session"* ]] && echo ok || echo "$said")"
check "#3669 and still what reads his approval of a wording in, that he is not asked again, and that nothing is lost for any other picker" "$([[ "$said" == *"only if"*"--add-label changelog/announce"*"does not need to be asked again"*"nothing is lost"* ]] && echo ok || echo "$said")"
check "#3669 it is the hook's one notice: one JSON object on one line" "$([[ "$said" != NOT-A-NOTICE* && "$(printf '%s' "$HOUT" | grep -c .)" == 1 ]] && echo ok || echo "$HOUT")"
run "$(aaf_talk "$T" decide-payload "$id" acme/widget "Hand off" "Not announcing" "" "" a9bba4c0ffee)"
check "#3669 with a record that could take no note, a subagent's discovery picker still says nothing" "$([[ "$HRC|$HOUT|$HERR" == "0||" ]] && echo ok || echo "$HRC|$HOUT|$HERR")"
STORE="$WORK/store"

echo "the record is this suite's own"
check "no case wrote to this Mac's real record" "$([ "$(ls -la "$REAL_STORE" 2>/dev/null | cksum)" = "$real_before" ] && echo ok || echo "$REAL_STORE changed during the run")"

echo "  $pass passed, $fail failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
