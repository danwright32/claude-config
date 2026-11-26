#!/usr/bin/env bash
# lib/announce-approval.py: whether Dan approved the exact wording of an announcement
# (claude-config#3666).
#
# Every case builds a session transcript as Claude Code writes one (the picker's input on the
# assistant entry holding its tool_use, his choice in toolUseResult.answers on the user entry
# carrying its tool_result) and asks the library through its own command line, which is how the
# merge gate asks it. The record is kept in a folder of this suite's own (ANNOUNCE_APPROVALS_DIR),
# never under the Mac's real ~/.claude/state, and every repository here is invented.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/announce-approval.py"
ENTRY="$DIR/lib/changelog-entry.js"
pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$LIB" ]; then
  echo "FAIL: there is no lib/announce-approval.py beside this suite at $DIR, so nothing says whether Dan approved an announcement's wording"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
STORE="$WORK/store"
REAL_STORE="${CLAUDE_HOME:-$HOME/.claude}/state/announce-approvals"
real_before="$(ls -la "$REAL_STORE" 2>/dev/null | cksum)"
POST='@here
**Handing a call back**

You can now hand a call back to the queue.

- Press Hand back
- Pick a reason'
# The session each case builds, as Claude Code writes one: lib/announce-approval-fixture.sh, shared
# with the merge gate's suite and the label hook's.
. "$DIR/lib/announce-approval-fixture.sh" 2>/dev/null && declare -F aaf_talk >/dev/null || {
  echo "FAIL: lib/announce-approval-fixture.sh is missing beside this suite, so no session could be built"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
BBEDIT="$AAF_BBEDIT"
talk() { aaf_talk "$@"; }
new_talk() { aaf_new "$1"; }
# hash_file <file>, hash_text <text>: the one hash, asked of the library that owns it.
hash_file() { node "$ENTRY" announcement-hash < "$1" | python3 -c 'import json, sys; print(json.load(sys.stdin)["hash"])'; }
hash_text() { printf '%s' "$1" | node "$ENTRY" announcement-hash | python3 -c 'import json, sys; print(json.load(sys.stdin)["hash"])'; }
# asked <transcript> <repo> <hash> [session]: the library's answer, as "<yes|no>|<why>|<notes>".
# AGENT=1 makes the call a subagent's; STORE_USED names another record folder.
asked() {
  python3 -c 'import json, os, sys
d = {"session_id": sys.argv[2], "transcript_path": sys.argv[1], "hook_event_name": "PreToolUse", "tool_name": "Bash"}
if os.environ.get("AGENT") == "1":
    d["agent_id"] = "a9bba4c0ffee"
print(json.dumps(d))' "$1" "${4:-s1}" \
    | ANNOUNCE_APPROVALS_DIR="${STORE_USED:-$STORE}" python3 -B "$LIB" check --repo "$2" --hash "$3" \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(("yes" if d["approved"] is True else "no") + "|" + d["why"] + "|" + " ".join(d["notes"]), end="")'
}
recorded() { [ -f "${STORE_USED:-$STORE}/record.jsonl" ] && grep -c '"kind": "approved"' "${STORE_USED:-$STORE}/record.jsonl" || echo 0; }
# shown <name>: a wording file in a folder of its own, written, then opened in front of Dan.
# Prints its path; the transcript is $WORK/<name>.jsonl.
shown() { aaf_shown "$WORK/$1" "$WORK/$1.jsonl" "$POST"; }

echo "an announcement's wording is approved only by Dan's own answer, about the file he was shown (#3666)"

# R2, the rule itself: with no picker and nothing on the record, no wording is approved.
T="$WORK/none.jsonl"; new_talk "$T"
r="$(asked "$T" acme/widget "$(hash_text "$POST")")"
check "R2 wording nobody asked Dan about is not approved" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
check "R2 the refusal says how to ask him" "$([[ "$r" == *"has not approved this wording for acme/widget"* ]] && echo ok || echo "$r")"
check "nothing was written to the record for it" "$([ "$(recorded)" = 0 ] && echo ok || echo "$(recorded) lines")"

# Still possible: the file written, opened in front of him, and his Approve.
F="$(shown happy)"; T="$WORK/happy.jsonl"
talk "$T" ask acme/widget "$F"
H="$(hash_file "$F")"
r="$(asked "$T" acme/widget "$H")"
check "R2 still possible: wording he approved after it was opened in front of him is approved" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
check "his approval was written to the record" "$([ "$(recorded)" = 1 ] && echo ok || echo "$(recorded) lines")"
check "the record names the repository and the hash of the file" "$(grep -q "\"hash\": \"$H\"" "$STORE/record.jsonl" && grep -q '"repo": "acme/widget"' "$STORE/record.jsonl" && echo ok || cat "$STORE/record.jsonl")"
# Asked again in the same session, it is not written twice.
asked "$T" acme/widget "$H" >/dev/null
check "the same approval read again is not written again" "$([ "$(recorded)" = 1 ] && echo ok || echo "$(recorded) lines")"
# Still possible: a later session, which holds no picker, merges it on the record alone.
T2="$WORK/later.jsonl"; new_talk "$T2"
r="$(asked "$T2" acme/widget "$H" s2)"
check "R2 still possible: a later session merges wording he approved, on the record alone" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
# The same wording as GitHub returns it (CRLF, a trailing blank line) is the same wording.
crlf="$WORK/crlf.md"
printf '%s\n\n' "$POST" | python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace("\n", "\r\n"))' > "$crlf"
r="$(asked "$T2" acme/widget "$(hash_file "$crlf")" s2)"
check "the approved wording with the line endings GitHub gives is still approved" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
# One changed word is other wording, and so is the same wording in another repository.
r="$(asked "$T2" acme/widget "$(hash_text "${POST/Pick a reason/Pick any reason}")" s2)"
check "R2 an edit to the wording after his approval is not approved" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
r="$(asked "$T2" acme/other "$H" s2)"
check "R2 his approval for one repository approves nothing in another" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
# In the session that asked him, a refusal for other wording says his file differs.
r="$(asked "$T" acme/widget "$(hash_text "${POST/Pick a reason/Pick any reason}")")"
check "the refusal says the wording he approved is not this wording" "$([[ "$r" == "no|"*"is not this wording"* ]] && echo ok || echo "$r")"

# The hash is the file's, never one the session supplies: metadata claiming another wording's hash
# approves only what the file holds.
STORE_USED="$WORK/store-claimed"
F="$(shown claimed)"; T="$WORK/claimed.jsonl"
OTHER="$(hash_text '@here
Something Dan never saw.')"
talk "$T" ask acme/widget "$F" "" "claimedhash:$OTHER"
r="$(asked "$T" acme/widget "$OTHER")"
check "R2 a hash the session wrote into the picker approves nothing" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "the file he was shown is what that picker approved" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"

echo "a picker that is not his answer approves nothing"
for shape in timeout prefilled two error othersource; do
  STORE_USED="$WORK/store-$shape"
  F="$(shown "shape-$shape")"; T="$WORK/shape-$shape.jsonl"
  talk "$T" ask acme/widget "$F" "" "$shape"
  r="$(asked "$T" acme/widget "$(hash_file "$F")")"
  check "R2 a picker that is not his answer ($shape) approves nothing" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
  check "and writes nothing to the record ($shape)" "$([ "$(recorded)" = 0 ] && echo ok || echo "$(recorded) lines")"
done
STORE_USED="$WORK/store-notyet"
F="$(shown notyet)"; T="$WORK/notyet.jsonl"
talk "$T" ask acme/widget "$F" "Not yet"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "R2 his Not yet approves nothing" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
# Another session's picker, in the same transcript file, is not this session's.
STORE_USED="$WORK/store-othersession"
F="$(shown othersession)"; T="$WORK/othersession.jsonl"
talk "$T" ask acme/widget "$F" "" "" s9
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "R2 a picker of another session approves nothing in this one" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
# A later Not yet about the same file takes an earlier Approve back, while neither is on the record.
STORE_USED="$WORK/store-tookback"
F="$(shown tookback)"; T="$WORK/tookback.jsonl"
talk "$T" ask acme/widget "$F"
talk "$T" ask acme/widget "$F" "Not yet"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "a later Not yet about the same file is the last word on it" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
# A picker he could not have read as written (a character the dialog draws as nothing) is not taken.
if command -v node >/dev/null 2>&1; then
  STORE_USED="$WORK/store-unread"
  F="$(shown unread)"; T="$WORK/unread.jsonl"
  talk "$T" ask acme/widget "$F" "" unread
  r="$(asked "$T" acme/widget "$(hash_file "$F")")"
  check "R2 a picker he could not have read as written approves nothing" "$([[ "$r" == "no|"*"would not have reached him as written"* ]] && echo ok || echo "$r")"
fi
# Metadata naming no absolute file, or no owner/name, names nothing to approve.
STORE_USED="$WORK/store-meta"
F="$(shown meta)"; T="$WORK/meta.jsonl"
talk "$T" ask acme/widget "announcement.md"
talk "$T" ask "widget" "$F"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "a picker naming no absolute file, or no owner/name, approves nothing" "$([[ "$r" == "no|"*"does not name the repository as owner/name and the wording file by its absolute path"* ]] && echo ok || echo "$r")"

echo "the wording was opened in front of him, and is what he answered about"
# Never opened.
STORE_USED="$WORK/store-unopened"
mkdir -p "$WORK/unopened"; F="$WORK/unopened/announcement.md"; T="$WORK/unopened.jsonl"
printf '%s\n' "$POST" > "$F"; new_talk "$T"; talk "$T" write "$F"
talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "R2 wording never opened in front of him is not approved" "$([[ "$r" == "no|"*"was not opened in front of him"* ]] && echo ok || echo "$r")"
# Opened without the front window flag (it opens in the background and he sees nothing), an open
# that failed, an open of another file, and an open with a second command in the same call.
k=0
for opened in "$BBEDIT @F@" "cat @F@" "$BBEDIT --front-window @F@.other" "$BBEDIT --front-window @F@ && printf x >> @F@" "$BBEDIT --front-window @F@ > /dev/null"; do
  k=$((k + 1)); STORE_USED="$WORK/store-open$k"
  mkdir -p "$WORK/open$k"; F="$WORK/open$k/announcement.md"; T="$WORK/open$k.jsonl"
  printf '%s\n' "$POST" > "$F"; new_talk "$T"; talk "$T" write "$F"
  talk "$T" bash "${opened//@F@/$F}"
  talk "$T" ask acme/widget "$F"
  r="$(asked "$T" acme/widget "$(hash_file "$F")")"
  check "R2 '${opened//@F@/<file>}' is not the file opened in front of him" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
done
STORE_USED="$WORK/store-openfailed"
mkdir -p "$WORK/openfailed"; F="$WORK/openfailed/announcement.md"; T="$WORK/openfailed.jsonl"
printf '%s\n' "$POST" > "$F"; new_talk "$T"; talk "$T" write "$F"
talk "$T" bash "$BBEDIT --front-window $F" error
talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "R2 an open that failed did not put the file in front of him" "$([[ "$r" == "no|"*"was not opened in front of him"* ]] && echo ok || echo "$r")"
# The fallback CLAUDE.md names, and the helper through rtk, each put it in front.
k=0
for opened in "open -a BBEdit @F@" "rtk $BBEDIT --front-window @F@" "$BBEDIT @F@ --front-window"; do
  k=$((k + 1)); STORE_USED="$WORK/store-front$k"
  mkdir -p "$WORK/front$k"; F="$WORK/front$k/announcement.md"; T="$WORK/front$k.jsonl"
  printf '%s\n' "$POST" > "$F"; new_talk "$T"; talk "$T" write "$F"
  talk "$T" bash "${opened//@F@/$F}"
  talk "$T" ask acme/widget "$F"
  r="$(asked "$T" acme/widget "$(hash_file "$F")")"
  check "still possible: '${opened//@F@/<file>}' opens it in front of him" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
done
# The session touching the file after the open and before his answer: an Edit, a Write, a command
# naming it, an agent sent its name. What he had in front of him may not be what is in it.
for touch in edit write bash agent; do
  STORE_USED="$WORK/store-touch-$touch"
  F="$(shown "touch-$touch")"; T="$WORK/touch-$touch.jsonl"
  case "$touch" in
    edit|write) talk "$T" "$touch" "$F" ;;
    bash) talk "$T" bash "cd $WORK/touch-bash && printf 'more\n' >> announcement.md" ;;
    agent) talk "$T" agent "tidy $F for me" ;;
  esac
  talk "$T" ask acme/widget "$F"
  r="$(asked "$T" acme/widget "$(hash_file "$F")")"
  check "R2 the file touched after it was opened ($touch) is not what he approved" "$([[ "$r" == "no|"*"after the file was opened for him and before he answered"* ]] && echo ok || echo "$r")"
done
# Opened again after that write, it is in front of him again.
STORE_USED="$WORK/store-reopened"
F="$(shown reopened)"; T="$WORK/reopened.jsonl"
talk "$T" edit "$F"
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "still possible: opened again after the session's last write, it is approved" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
# Dan editing the file himself before he answers leaves no call in the transcript: the hash is of
# the file as he left it.
STORE_USED="$WORK/store-danedit"
F="$(shown danedit)"; T="$WORK/danedit.jsonl"
printf '%s\n- And tell your manager\n' "$POST" > "$F"
talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "still possible: his own edit before answering is the wording approved" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
r="$(asked "$T" acme/widget "$(hash_text "$POST")")"
check "and the wording before his edit is not" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
# Changed after he answered, by anything at all: the file no longer holds what he approved.
STORE_USED="$WORK/store-after"
F="$(shown after)"; T="$WORK/after.jsonl"
talk "$T" ask acme/widget "$F"
printf '%s\n- Slipped in afterwards\n' "$POST" > "$F"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "R2 a file changed after his answer is not the wording he approved" "$([[ "$r" == "no|"*"has changed since he answered"* ]] && echo ok || echo "$r")"
check "and nothing was written to the record for it" "$([ "$(recorded)" = 0 ] && echo ok || echo "$(recorded) lines")"
# An empty file is no wording.
STORE_USED="$WORK/store-empty"
mkdir -p "$WORK/empty"; F="$WORK/empty/announcement.md"; T="$WORK/empty.jsonl"
printf '\n\n' > "$F"; new_talk "$T"; talk "$T" bash "$BBEDIT --front-window $F"; talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$(hash_text "$POST")")"
check "a file holding no wording approves nothing" "$([[ "$r" == "no|"*"holds no wording"* ]] && echo ok || echo "$r")"

echo "who may write the record"
# A subagent's call counts his picker for that call and writes nothing.
STORE_USED="$WORK/store-agent"
F="$(shown agent)"; T="$WORK/agent.jsonl"
talk "$T" ask acme/widget "$F"
r="$(AGENT=1 asked "$T" acme/widget "$(hash_file "$F")")"
check "a subagent's call counts his picker for that call" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
check "R2 a subagent's call writes nothing to the record" "$([ "$(recorded)" = 0 ] && [ ! -e "$STORE_USED/record.jsonl" ] && echo ok || echo "$(recorded) lines")"
# A record that cannot be written: the main session's call still counts his picker, and says so.
STORE_USED="$WORK/store-blocked/inner"
printf 'not a folder\n' > "$WORK/store-blocked"
F="$(shown blocked)"; T="$WORK/blocked.jsonl"
talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "a record that cannot be written still counts his picker for the call, and says the save failed" "$([[ "$r" == "yes||"*"could not be saved"*"will ask him again"* ]] && echo ok || echo "$r")"
# A line that is not JSON, or approves another repository, approves nothing here.
STORE_USED="$WORK/store-junk"; mkdir -p "$STORE_USED"
H="$(hash_text "$POST")"
printf 'approved acme/widget %s\n{"kind": "approved", "repo": "acme/other", "hash": "%s"}\n{"kind": "used", "repo": "acme/widget", "hash": "%s", "pr": 7}\n' "$H" "$H" "$H" > "$STORE_USED/record.jsonl"
T="$WORK/junk.jsonl"; new_talk "$T"
r="$(asked "$T" acme/widget "$H")"
check "a record line that is not an approval of this repository's wording approves nothing" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
# A hash that is no hash, and a repository that is no owner/name, are refused before anything is read.
r="$(asked "$T" acme/widget "")"
check "no hash is no wording to look up" "$([[ "$r" == "no|"*"gave no hash"* ]] && echo ok || echo "$r")"
r="$(asked "$T" "widget" "$H")"
check "a repository that is no owner/name is refused" "$([[ "$r" == "no|"*"owner/name"* ]] && echo ok || echo "$r")"

echo "a merged announcement's wording is marked used"
STORE_USED="$WORK/store-used"
used() { ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B "$LIB" used "$@"; }
r="$(used --repo Acme/Widget --hash "$H" --pr 7 --closes '[{"issue": 12, "milestone": "Hand back"}, {"issue": 13, "milestone": null}]')"
check "the used line is written" "$([[ "$r" == *'"written": true'* ]] && echo ok || echo "$r")"
listed="$(ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B "$LIB" list)"
check "it names the pull request, and each issue it closes with its milestone" "$(printf '%s' "$listed" | python3 -c 'import json, sys
e = json.load(sys.stdin)["entries"]
ok = len(e) == 1 and e[0]["kind"] == "used" and e[0]["repo"] == "acme/widget" and e[0]["pr"] == 7 and e[0]["closes"] == [{"issue": 12, "milestone": "Hand back"}, {"issue": 13, "milestone": None}]
print("ok" if ok else json.dumps(e))')"
used --repo acme/widget --hash "$H" --pr 7 --closes '[{"issue": 12, "milestone": "Hand back"}]' >/dev/null
check "the same pull request and wording are marked once" "$([ "$(grep -c '"kind": "used"' "$STORE_USED/record.jsonl")" = 1 ] && echo ok || cat "$STORE_USED/record.jsonl")"
# Issues that could not be read are kept as unread with why, never as an empty list.
r="$(used --repo acme/widget --hash "$H" --pr 8 --unread 'gh gave no answer')"
check "issues that could not be read are recorded as unread, with why" "$(grep -q '"closes": null' "$STORE_USED/record.jsonl" && grep -q '"unread": "gh gave no answer"' "$STORE_USED/record.jsonl" && echo ok || cat "$STORE_USED/record.jsonl")"
# A used line grants nothing: wording marked used and never approved is still not approved.
T="$WORK/usedonly.jsonl"; new_talk "$T"
r="$(asked "$T" acme/widget "$H")"
check "R2 a used line approves nothing" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
r="$(used --repo acme/widget --hash nothex --pr 9)"
check "a used line naming no hash is refused, and said" "$([[ "$r" == *'"written": false'* ]] && echo ok || echo "$r")"

echo "whether Dan has approved any announcement for a repository"
# any <transcript> <repo> [session]: the library's answer, as "<yes|no>|<why>|<notes>".
any() {
  python3 -c 'import json, os, sys
d = {"session_id": sys.argv[2], "transcript_path": sys.argv[1], "hook_event_name": "PreToolUse", "tool_name": "Bash"}
if os.environ.get("AGENT") == "1":
    d["agent_id"] = "a9bba4c0ffee"
print(json.dumps(d))' "$1" "${3:-s1}" \
    | ANNOUNCE_APPROVALS_DIR="${STORE_USED:-$STORE}" python3 -B "$LIB" repo --repo "$2" \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(("yes" if d["approved"] is True else "no") + "|" + d["why"] + "|" + " ".join(d["notes"]), end="")'
}
STORE_USED="$WORK/store-any"
T="$WORK/any-none.jsonl"; new_talk "$T"
r="$(any "$T" acme/widget)"
check "a repository he has approved nothing for has no approval" "$([[ "$r" == "no|"*"has approved no announcement for acme/widget"* ]] && echo ok || echo "$r")"
r="$(any "$T" widget)"
check "a repository that is no owner/name has no approval, and says so" "$([[ "$r" == "no|"*"owner/name"* ]] && echo ok || echo "$r")"
# His Approve in this session counts, and is kept, as it is for a wording.
F="$(shown anyrepo)"; T="$WORK/anyrepo.jsonl"
r="$(any "$T" acme/widget)"
check "wording opened in front of him and not yet approved is no approval for its repository" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
talk "$T" ask acme/widget "$F"
r="$(AGENT=1 any "$T" acme/widget)"
check "a subagent's call counts his picker for the repository" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
check "and writes nothing to the record" "$([ "$(recorded)" = 0 ] && echo ok || echo "$(recorded) lines")"
r="$(any "$T" acme/widget)"
check "his approval of any wording there is an approval for the repository" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
check "and it is written to the record" "$([ "$(recorded)" = 1 ] && echo ok || echo "$(recorded) lines")"
T2="$WORK/any-later.jsonl"; new_talk "$T2"
r="$(any "$T2" Acme/Widget s2)"
check "a later session finds it on the record, in any letter case" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
r="$(any "$T2" acme/other s2)"
check "his approval for one repository is none for another" "$([[ "$r" == "no|"*"has approved no announcement for acme/other"* ]] && echo ok || echo "$r")"
# A used line, and an Approve that does not count, are no approval for the repository.
STORE_USED="$WORK/store-any-used"
used --repo acme/widget --hash "$H" --pr 7 >/dev/null
r="$(any "$T2" acme/widget s2)"
check "a used line is no approval for its repository" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
F="$(shown anytouched)"; T="$WORK/anytouched.jsonl"
talk "$T" edit "$F"
talk "$T" ask acme/widget "$F"
r="$(any "$T" acme/widget)"
check "an Approve of his that does not count is no approval for the repository, and says why" "$([[ "$r" == "no|"*"does not count"* ]] && echo ok || echo "$r")"
unset STORE_USED

echo "the record is this suite's own"
check "no case wrote to this Mac's real record" "$([ "$(ls -la "$REAL_STORE" 2>/dev/null | cksum)" = "$real_before" ] && echo ok || echo "$REAL_STORE changed during the run")"

echo "  $pass passed, $fail failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
