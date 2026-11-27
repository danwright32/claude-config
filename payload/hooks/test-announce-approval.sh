#!/usr/bin/env bash
# lib/announce-approval.py: whether Dan approved the exact wording of an announcement
# (claude-config#3666).
#
# Every case builds a session transcript as Claude Code writes one (the picker's input on the
# assistant entry holding its tool_use, his choice in toolUseResult.answers on the user entry
# carrying its tool_result) and asks the library as a hook asks it: in process for a question that
# claims nothing, which is how the label hook asks, and through its command line with --claim, which
# is how the merge gate asks. The command line without --claim reads the record only
# (claude-config#3703), and has cases of its own. The record is kept in a folder of this suite's own (ANNOUNCE_APPROVALS_DIR),
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
# A second temporary folder, which plays this Mac's real record in the cases about the check that
# ends this suite: a stand in, so those cases never write the real one.
STAND="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" "$STAND" 2>/dev/null; rm -rf "$WORK" "$STAND"' EXIT
STORE="$WORK/store"
REAL_STORE="${CLAUDE_HOME:-$HOME/.claude}/state/announce-approvals"
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
# This Mac's real record as it stood before any case ran, and what a line of this suite's names: a
# path under its temporary folder, or a repository of the owner every repository here is under. The
# last check holds the suite to it (aaf_record_untouched, which has cases of its own there).
OWN_MARKS=("path:$WORK" "repo:acme/")
real_before="$(aaf_record_mark "$REAL_STORE")"
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
    | ANNOUNCE_APPROVALS_DIR="${STORE_USED:-$STORE}" aaf_hook_check "$LIB" "$2" "$3" \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(("yes" if d["approved"] is True else "no") + "|" + d["why"] + "|" + " ".join(d["notes"]), end="")'
}
# recorded: how many approvals the record holds. A record may hold other lines and no approval (a
# picker that came back any other way gets a line of its own since #3742), which counts as 0.
recorded() { local n; n="$(grep -c '"kind": "approved"' "${STORE_USED:-$STORE}/record.jsonl" 2>/dev/null)"; printf '%s' "${n:-0}"; }
# shown <name>: a wording file in a folder of its own, written, then opened in front of Dan.
# Prints its path; the transcript is $WORK/<name>.jsonl.
shown() { aaf_shown "$WORK/$1" "$WORK/$1.jsonl" "$POST"; }

echo "an announcement's wording is approved only by Dan's own answer, about the file he was shown (#3666)"

# R2, the rule itself: with no picker and nothing on the record, no wording is approved.
T="$WORK/none.jsonl"; new_talk "$T"
r="$(asked "$T" acme/widget "$(hash_text "$POST")")"
check "R2 wording nobody asked Dan about is not approved" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
check "R2 the refusal names the repository and that he has not approved this wording" "$([[ "$r" == *"has not approved this wording for acme/widget"* ]] && echo ok || echo "$r")"
# How to ask him is its own field of the answer, which each hook prints after the reason.
how="$(printf '{"session_id": "s1", "transcript_path": "%s"}' "$T" | ANNOUNCE_APPROVALS_DIR="$STORE" python3 -B "$LIB" check --repo acme/widget --hash "$(hash_text "$POST")" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["how"], end="")')"
check "R2 the refusal says how to ask him: the open in BBEdit, the picker, its options and its metadata" "$([[ "$how" == *"--front-window"* && "$how" == *"AskUserQuestion"* && "$how" == *"Approve the wording"* && "$how" == *"Not yet"* && "$how" == *'"source": "changelog-announce"'* ]] && echo ok || echo "$how")"
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
  check "and writes no approval to the record ($shape)" "$([ "$(recorded)" = 0 ] && echo ok || echo "$(recorded) lines")"
done
# The refusal says why (#3742, low 15). The session can see an Approve in its own transcript, so a
# bare "Dan has not approved this wording" sent it to ask again the same way.
for each in "timeout|closed by its own timeout" "prefilled|already filled in" "two|did not ask one question" "error|came back in error"; do
  shape="${each%%|*}"
  STORE_USED="$WORK/store-why-$shape"
  F="$(shown "why-$shape")"; T="$WORK/why-$shape.jsonl"
  talk "$T" ask acme/widget "$F" "" "$shape"
  r="$(asked "$T" acme/widget "$(hash_file "$F")")"
  check "an Approve that is not his answer ($shape) is refused with the reason it does not count" "$([[ "$r" == "no|"*"his Approve for $F does not count"*"${each#*|}"* ]] && echo ok || echo "$r")"
done
# A picker of another source is not about an announcement, and draws no such sentence.
STORE_USED="$WORK/store-why-othersource"
F="$(shown why-othersource)"; T="$WORK/why-othersource.jsonl"
talk "$T" ask acme/widget "$F" "" othersource
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "a picker of another source draws no sentence about an Approve" "$([[ "$r" == "no|"* && "$r" != *"does not count"* ]] && echo ok || echo "$r")"
# Still possible: asked again and answered by him, the earlier one is not held against the file.
STORE_USED="$WORK/store-why-again"
F="$(shown why-again)"; T="$WORK/why-again.jsonl"
talk "$T" ask acme/widget "$F" "" timeout
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "still possible: asked again after a picker that timed out, his own Approve counts" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
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
# Wording he approved for a repository under another name (a fork, an old name) is still refused,
# and the refusal says that is what was found, where it said he never approved it (#3742, low 16).
STORE_USED="$WORK/store-otherrepo"
F="$(shown otherrepo)"; T="$WORK/otherrepo.jsonl"
talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget-old "$(hash_file "$F")")"
check "R2 wording he approved for another repository is not approved for this one" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
check "and the refusal says the same wording is approved for the other repository" "$([[ "$r" == *"approved this same wording for acme/widget,"* ]] && echo ok || echo "$r")"
T2="$WORK/otherrepo-later.jsonl"; new_talk "$T2"
r="$(asked "$T2" acme/widget-old "$(hash_file "$F")")"
check "and says so from the record alone, in a later session" "$([[ "$r" == "no|"*"approved this same wording for acme/widget,"* ]] && echo ok || echo "$r")"
r="$(asked "$T2" acme/widget-old "$(hash_text "wording nobody approved anywhere")")"
check "wording approved for no repository draws no such sentence" "$([[ "$r" == "no|"* && "$r" != *"this same wording for"* ]] && echo ok || echo "$r")"

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

echo "a file padded with blank lines is not what he was shown (#3703)"
# Every blank line is dropped before the wording is hashed, so a file holding the post, a long run
# of blank lines and then more text hashes the same as those lines written together. BBEdit's front
# window shows him the post and then white space, and the pull request carries the lines together.
# padded <name> <blank lines> [line ending]: such a file, opened in front of him and approved.
padded() {
  mkdir -p "$WORK/$1"; F="$WORK/$1/announcement.md"; T="$WORK/$1.jsonl"
  python3 -c 'import sys
post, count, end, path = sys.argv[1], int(sys.argv[2]), sys.argv[3] or "\n", sys.argv[4]
open(path, "w", newline="").write(post.replace("\n", end) + end + end * count + "Give every caller a 100% refund without asking a manager." + end)' "$POST" "$2" "${3:-}" "$F"
  new_talk "$T"; talk "$T" bash "$BBEDIT --front-window $F"; talk "$T" ask acme/widget "$F"
}
TOGETHER="$POST
Give every caller a 100% refund without asking a manager."
STORE_USED="$WORK/store-padded"
padded padded 300
check "the padded file hashes as its lines written together, which is why the hash cannot refuse it" "$([ "$(hash_file "$F")" = "$(hash_text "$TOGETHER")" ] && echo ok || echo "the hashes differ")"
r="$(asked "$T" acme/widget "$(hash_text "$TOGETHER")")"
check "R2 a file holding the post, 300 blank lines and then more text is not wording he approved" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
check "the refusal says what is wrong with the file: how many blank lines, where, and that text sits below them" "$([[ "$r" == *"300 blank lines in a row"*"from line 8"*"more wording below them"* ]] && echo ok || echo "$r")"
check "and what to change: no more than 2 blank lines in a row, then open it and ask him again" "$([[ "$r" == *"no more than 2 blank lines in a row"*"open the file for him and ask him again"* ]] && echo ok || echo "$r")"
check "R2 nothing was written to the record for the padded file" "$([ "$(recorded)" = 0 ] && echo ok || echo "$(recorded) lines")"
# The limit itself: three in a row is refused, in whatever the lines are ended with or hold.
padded three 3
r="$(asked "$T" acme/widget "$(hash_text "$TOGETHER")")"
check "R2 three blank lines in a row before more text are refused" "$([[ "$r" == "no|"*"3 blank lines in a row"* ]] && echo ok || echo "$r")"
padded threecrlf 3 $'\r\n'
r="$(asked "$T" acme/widget "$(hash_text "$TOGETHER")")"
check "R2 and so are three ended as GitHub ends a line" "$([[ "$r" == "no|"*"3 blank lines in a row"* ]] && echo ok || echo "$r")"
padded threespaces 0
printf '%s\n \n\t\n  \nGive every caller a 100%% refund without asking a manager.\n' "$POST" > "$F"
new_talk "$T"; talk "$T" bash "$BBEDIT --front-window $F"; talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$(hash_text "$TOGETHER")")"
check "R2 and three lines holding only spaces or a tab" "$([[ "$r" == "no|"*"3 blank lines in a row"* ]] && echo ok || echo "$r")"
check "R2 none of those wrote to the record" "$([ "$(recorded)" = 0 ] && echo ok || echo "$(recorded) lines")"
# Still possible: two blank lines in a row, and blank lines after the last line, which hide nothing.
padded two 2
r="$(asked "$T" acme/widget "$(hash_text "$TOGETHER")")"
check "still possible: wording with two blank lines in a row is approved" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
STORE_USED="$WORK/store-trailing"
mkdir -p "$WORK/trailing"; F="$WORK/trailing/announcement.md"; T="$WORK/trailing.jsonl"
printf '%s\n\n\n\n\n\n' "$POST" > "$F"
new_talk "$T"; talk "$T" bash "$BBEDIT --front-window $F"; talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$(hash_text "$POST")")"
check "still possible: blank lines after the last line of wording do not stand in the way" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
# A hash answer that does not say how long the longest run is cannot clear the file (L98). Driven
# with a node in front of the real one that takes the count out of that one answer, as a
# lib/changelog-entry.js older than this library would give it, and passes every other call through.
NOCOUNT="$WORK/node-without-the-count"; mkdir -p "$NOCOUNT"
REAL_NODE="$(command -v node)"
cat > "$NOCOUNT/node" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" announcement-hash "*)
    "$REAL_NODE" "$@" | "$REAL_NODE" -e 'let raw = ""; process.stdin.on("data", function (d) { raw += d; }); process.stdin.on("end", function () { const a = JSON.parse(raw); delete a.blankRun; delete a.blankRunAt; process.stdout.write(JSON.stringify(a) + "\n"); });' ;;
  *) exec "$REAL_NODE" "$@" ;;
esac
SH
chmod +x "$NOCOUNT/node"
STORE_USED="$WORK/store-nocount"
F="$(shown nocount)"; T="$WORK/nocount.jsonl"
talk "$T" ask acme/widget "$F"
H="$(hash_file "$F")"
r="$(REAL_NODE="$REAL_NODE" PATH="$NOCOUNT:$PATH" asked "$T" acme/widget "$H")"
check "a hash answer that does not count the blank lines approves nothing, and says so" "$([[ "$r" == "no|"*"did not say how many blank lines"* ]] && echo ok || echo "$r")"
r="$(asked "$T" acme/widget "$H")"
check "and the same file is approved once the answer counts them, so it was the missing count that refused it" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"

echo "the command line a session can run reads the record and writes no approval (#3703)"
# The review's first finding, as it was run: a file shaped like a transcript, holding a picker
# nobody was shown, and the library's check command handed a payload naming it. The library read
# the picker from whatever file its standard input named and wrote his approval to the record.
STORE_USED="$WORK/store-forged"
F="$(shown forged)"; T="$WORK/forged.jsonl"
talk "$T" ask acme/widget "$F"
H="$(hash_file "$F")"
forged_payload() { printf '{"session_id": "s1", "transcript_path": "%s"}' "${1:-$T}"; }
answer() { python3 -c 'import json, sys
d = json.load(sys.stdin)
print(("yes" if d["approved"] is True else "no") + "|" + str(d.get("state")) + "|" + d["why"], end="")'; }
r="$(forged_payload | ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B "$LIB" check --repo acme/widget --hash "$H" | answer)"
check "R2 the check command a session can run takes no picker from the transcript its input names" "$([[ "$r" == "no|unapproved|"* ]] && echo ok || echo "$r")"
check "R2 and writes nothing to the record" "$([ "$(recorded)" = 0 ] && [ ! -e "$STORE_USED/record.jsonl" ] && echo ok || cat "$STORE_USED/record.jsonl")"
check "its answer says it read the record only, and what reads a picker" "$([[ "$r" == *"no approval on this Mac's record"*"reads the record only"*"hook"* && "$r" != *"none in this session"* ]] && echo ok || echo "$r")"
r="$(forged_payload | ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B "$LIB" check --repo acme/widget --hash "$H" --pr 7 | answer)"
check "R2 nor does it with a pull request named" "$([[ "$r" == "no|unapproved|"* ]] && [ "$(recorded)" = 0 ] && echo ok || echo "$r")"
# The same transcript, asked about by a hook, is his approval: so it was the form of the question
# that refused it above, not the session it describes. And once a hook has written it, the command
# line reads it from the record.
r="$(asked "$T" acme/widget "$H")"
check "still possible: a hook asking about that session counts his picker and writes it" "$([[ "$r" == "yes||" ]] && [ "$(recorded)" = 1 ] && echo ok || echo "$r")"
r="$(ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B "$LIB" check --repo acme/widget --hash "$H" --pr 7 < /dev/null | answer)"
check "still possible: the command line says wording on the record is approved" "$([[ "$r" == "yes|approved|" ]] && echo ok || echo "$r")"
check "and reading it added nothing to the record" "$([ "$(grep -c '"kind"' "$STORE_USED/record.jsonl")" = 1 ] && echo ok || cat "$STORE_USED/record.jsonl")"

# The label hook refuses a session's command that runs this library under python in a form that
# writes. It keeps no list of the other programs that could run the file by its own path, because
# the file cannot be run that way: it carries no interpreter line, so the shell reads it and python
# never does (measured 2026-11-25 with a file of the same shape, directly and behind env and nohup).
# That rests on the first two bytes of the file, so they are held here.
check "the library carries no interpreter line, so it cannot be run by its own path" "$([ "$(head -c 2 "$LIB")" != '#!' ] && [ -s "$LIB" ] && echo ok || echo "it begins with an interpreter line")"

echo "a picker counts only from a transcript kept where Claude Code keeps them (#3703)"
# The merge gate's own question (check with --claim) has to write, so its command line cannot be
# read only. What it reads a picker from is held instead: a session transcript under the projects
# folder beside the record's own state folder, which is where Claude Code keeps them. These cases run
# with the record where a Mac keeps it, under a home of the suite's own (CLAUDE_HOME), and never
# with ANNOUNCE_APPROVALS_DIR, which names a test's record and lets a transcript be anywhere.
HOMEISH="$WORK/home/.claude"
HOME_RECORD="$HOMEISH/state/announce-approvals/record.jsonl"
at_home() { ( unset ANNOUNCE_APPROVALS_DIR; export CLAUDE_HOME="$HOMEISH"; "$@" ); }
F="$(shown outside)"; T="$WORK/outside.jsonl"
talk "$T" ask acme/widget "$F"
H="$(hash_file "$F")"
r="$(forged_payload | at_home python3 -B "$LIB" check --repo acme/widget --hash "$H" --pr 7 --claim | answer)"
check "R2 the merge gate's question takes no picker from a transcript kept anywhere else" "$([[ "$r" == "no|unapproved|"* ]] && echo ok || echo "$r")"
check "R2 and writes neither an approval nor a use for it" "$([ ! -e "$HOME_RECORD" ] && echo ok || cat "$HOME_RECORD")"
check "the refusal names the transcript, and the folder a session's transcript is kept in" "$([[ "$r" == *"$T"*"is not a session transcript under $HOMEISH/projects"* ]] && echo ok || echo "$r")"
r="$(forged_payload | at_home aaf_hook_check "$LIB" acme/widget "$H" 7 | answer)"
check "R2 nor does the label hook's question" "$([[ "$r" == "no|unapproved|"*"is not a session transcript under"* ]] && [ ! -e "$HOME_RECORD" ] && echo ok || echo "$r")"
# Under that folder, but not a transcript: a note a session may write there, and a link out of it.
mkdir -p "$HOMEISH/projects/-tmp-repo/memory"
cp "$T" "$HOMEISH/projects/-tmp-repo/memory/note.md"
r="$(forged_payload "$HOMEISH/projects/-tmp-repo/memory/note.md" | at_home python3 -B "$LIB" check --repo acme/widget --hash "$H" --pr 7 --claim | answer)"
check "R2 a file under that folder that is no transcript (.jsonl) is not read as one" "$([[ "$r" == "no|unapproved|"*"is not a session transcript under"* ]] && [ ! -e "$HOME_RECORD" ] && echo ok || echo "$r")"
ln -s "$T" "$HOMEISH/projects/-tmp-repo/linked.jsonl"
r="$(forged_payload "$HOMEISH/projects/-tmp-repo/linked.jsonl" | at_home python3 -B "$LIB" check --repo acme/widget --hash "$H" --pr 7 --claim | answer)"
check "R2 a link under that folder to a transcript kept elsewhere is not read as one" "$([[ "$r" == "no|unapproved|"*"is not a session transcript under"* ]] && [ ! -e "$HOME_RECORD" ] && echo ok || echo "$r")"
# Still possible: the same transcript where Claude Code keeps a session's, asked about by the gate.
cp "$T" "$HOMEISH/projects/-tmp-repo/s1.jsonl"
r="$(forged_payload "$HOMEISH/projects/-tmp-repo/s1.jsonl" | at_home python3 -B "$LIB" check --repo acme/widget --hash "$H" --pr 7 --claim | answer)"
check "still possible: his picker in a session's own transcript is his approval at the merge" "$([[ "$r" == "yes|approved|" ]] && echo ok || echo "$r")"
check "and it is written to the record with the pull request's claim" "$([ "$(grep -c '"kind": "approved"' "$HOME_RECORD" 2>/dev/null)" = 1 ] && [ "$(grep -c '"claim": true' "$HOME_RECORD")" = 1 ] && echo ok || cat "$HOME_RECORD" 2>&1)"
# Which folder that is, for each record a call can name. A record named by ANNOUNCE_APPROVALS_DIR is
# a test's and takes a transcript from anywhere, unless what it names is this user's own record,
# however it is spelled or linked: then the variable has changed nothing, and neither has CLAUDE_HOME.
# The user's own folder is read from the account database, which the call's environment cannot
# move; here it is set in process, since the real one must not be written.
OWN="$WORK/own/.claude"
mkdir -p "$OWN/state/announce-approvals" "$WORK/elsewhere" "$WORK/hardlinked"
printf '' > "$OWN/state/announce-approvals/record.jsonl"
ln -s "$OWN/state/announce-approvals" "$WORK/linked-record"
ln "$OWN/state/announce-approvals/record.jsonl" "$WORK/hardlinked/record.jsonl"
root_for() {  # <ANNOUNCE_APPROVALS_DIR, or ""> <CLAUDE_HOME, or "">: the folder transcripts must be under, or None
  python3 -B -c 'import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("announce_approval", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
lib._own_claude = lambda: sys.argv[2]
for name, value in (("ANNOUNCE_APPROVALS_DIR", sys.argv[3]), ("CLAUDE_HOME", sys.argv[4])):
    os.environ.pop(name, None)
    if value:
        os.environ[name] = value
print(lib.transcripts_dir(), end="")' "$LIB" "$OWN" "$1" "$2"
}
check "a test's record takes a transcript from anywhere" "$([ "$(root_for "$WORK/elsewhere" "")" = None ] && echo ok || root_for "$WORK/elsewhere" "")"
check "a record under CLAUDE_HOME takes one from the projects folder beside it" "$([ "$(root_for "" "$WORK/elsewhere")" = "$WORK/elsewhere/projects" ] && echo ok || root_for "" "$WORK/elsewhere")"
for named in "$OWN/state/announce-approvals" "$OWN/STATE/Announce-Approvals/" "$WORK/linked-record" "$WORK/hardlinked"; do
  check "R2 the user's own record, named by the variable as $named, still takes one only from the user's own projects folder" "$([ "$(root_for "$named" "$WORK/elsewhere")" = "$OWN/projects" ] && echo ok || root_for "$named" "$WORK/elsewhere")"
done

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
# A merge tried again while GitHub still gives no issues adds no second unread line, and once the
# issues can be read the line naming them is added, once.
used --repo acme/widget --hash "$H" --pr 8 --unread 'gh gave no answer again' >/dev/null
check "a pull request whose issues stay unread is marked unread once" "$([ "$(grep -c '"pr": 8' "$STORE_USED/record.jsonl")" = 1 ] && echo ok || grep '"pr": 8' "$STORE_USED/record.jsonl")"
used --repo acme/widget --hash "$H" --pr 8 --closes '[{"issue": 14, "milestone": null}]' >/dev/null
used --repo acme/widget --hash "$H" --pr 8 --unread 'gh gave no answer a third time' >/dev/null
check "and once they can be read, the line naming them is added, and nothing after it" "$([ "$(grep -c '"pr": 8' "$STORE_USED/record.jsonl")" = 2 ] && grep '"pr": 8' "$STORE_USED/record.jsonl" | tail -n 1 | grep -q '"issue": 14' && echo ok || grep '"pr": 8' "$STORE_USED/record.jsonl")"
# A used line grants nothing: wording marked used and never approved is still not approved.
T="$WORK/usedonly.jsonl"; new_talk "$T"
r="$(asked "$T" acme/widget "$H")"
check "R2 a used line approves nothing" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
r="$(used --repo acme/widget --hash nothex --pr 9)"
check "a used line naming no hash is refused, and said" "$([[ "$r" == *'"written": false'* ]] && echo ok || echo "$r")"

echo "one approval covers one pull request (Dan, 2026-11-25: \"One approval, one pull request\")"
# for_pr <transcript> <repo> <hash> <pull request number, or ""> [claim] [session]: the library's
# answer for one pull request, as "<yes|no>|<state>|<why>|<how>|<notes>". With claim it is the merge
# gate's question, which records the pull request as using the approval when it is let through.
for_pr() {
  python3 -c 'import json, os, sys
d = {"session_id": sys.argv[2], "transcript_path": sys.argv[1], "hook_event_name": "PreToolUse", "tool_name": "Bash"}
if os.environ.get("AGENT") == "1":
    d["agent_id"] = "a9bba4c0ffee"
print(json.dumps(d))' "$1" "${6:-s1}" \
    | if [ -n "${5:-}" ]; then ANNOUNCE_APPROVALS_DIR="${STORE_USED:-$STORE}" python3 -B "$LIB" check --repo "$2" --hash "$3" ${4:+--pr "$4"} --claim
      else ANNOUNCE_APPROVALS_DIR="${STORE_USED:-$STORE}" aaf_hook_check "$LIB" "$2" "$3" "${4:-}"; fi \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(("yes" if d["approved"] is True else "no") + "|" + str(d.get("state")) + "|" + d["why"] + "|" + d["how"] + "|" + " ".join(d["notes"]), end="")'
}
# approval_line <picker>: one approval of POST for acme/widget on the record, as a hook run writes it.
approval_line() { mkdir -p "$STORE_USED"; printf '{"kind": "approved", "repo": "acme/widget", "hash": "%s", "session": "s0", "picker": "%s", "at": "2026-11-25T00:00:00Z"}\n' "$H" "$1" >> "$STORE_USED/record.jsonl"; }
used_lines() { grep -c "\"kind\": \"used\".*\"pr\": $1[,}]" "$STORE_USED/record.jsonl" 2>/dev/null || true; }
STORE_USED="$WORK/store-one"
T="$WORK/one.jsonl"; new_talk "$T"
approval_line toolu_a
# An approval nobody has used covers whichever pull request asks, and a question that claims nothing
# (the label hook's) writes nothing.
r="$(for_pr "$T" acme/widget "$H" 12)"
check "an approval nobody has used covers a pull request that asks about it" "$([[ "$r" == "yes|approved|"* ]] && echo ok || echo "$r")"
check "and asking without claiming records no use" "$([ "$(grep -c '"kind": "used"' "$STORE_USED/record.jsonl")" = 0 ] && echo ok || cat "$STORE_USED/record.jsonl")"
r="$(for_pr "$T" acme/widget "$H" "")"
check "nor does a command naming no pull request, while an approval is unused" "$([[ "$r" == "yes|approved|"* ]] && echo ok || echo "$r")"
# The merge gate's question: pull request 7 uses the approval, and is recorded as using it.
r="$(for_pr "$T" acme/widget "$H" 7 claim)"
check "one pull request uses the approval at the merge" "$([[ "$r" == "yes|approved|"* ]] && echo ok || echo "$r")"
check "and is recorded as the one that used it, its issues not read yet" "$([ "$(used_lines 7)" = 1 ] && grep '"pr": 7' "$STORE_USED/record.jsonl" | grep -q '"closes": null' && echo ok || cat "$STORE_USED/record.jsonl")"
# The same pull request again: a merge that failed is tried again without asking him.
r="$(for_pr "$T" acme/widget "$H" 7 claim)"
check "the same pull request may try its merge again" "$([[ "$r" == "yes|approved|"* ]] && echo ok || echo "$r")"
check "and is not recorded a second time" "$([ "$(used_lines 7)" = 1 ] && echo ok || cat "$STORE_USED/record.jsonl")"
used --repo acme/widget --hash "$H" --pr 7 --closes '[{"issue": 12, "milestone": "Hand back"}]' >/dev/null
check "the line naming the issues it closes is added after the claim" "$([ "$(used_lines 7)" = 2 ] && grep '"pr": 7' "$STORE_USED/record.jsonl" | tail -n 1 | grep -q '"issue": 12' && echo ok || cat "$STORE_USED/record.jsonl")"
r="$(for_pr "$T" acme/widget "$H" 7 claim)"
check "and the same pull request still goes through after it" "$([[ "$r" == "yes|approved|"* ]] && [ "$(used_lines 7)" = 2 ] && echo ok || echo "$r")"
# A different pull request carrying the same wording asks him again.
r="$(for_pr "$T" acme/widget "$H" 8 claim)"
check "R2 a different pull request with the same wording is refused at the merge" "$([[ "$r" == "no|used|"* ]] && echo ok || echo "$r")"
check "the refusal names the pull request that used the approval, and that one covers one" "$([[ "$r" == *"pull request 7"* && "$r" == *"one approval covers one pull request"* ]] && echo ok || echo "$r")"
check "and says how to ask him again" "$([[ "$r" == *"AskUserQuestion"* && "$r" == *"Approve the wording"* ]] && echo ok || echo "$r")"
check "a refused pull request is not recorded as using anything" "$([ "$(used_lines 8)" = 0 ] && echo ok || cat "$STORE_USED/record.jsonl")"
r="$(for_pr "$T" acme/widget "$H" 8)"
check "and is refused before the merge too, where the label hook asks" "$([[ "$r" == "no|used|"* ]] && echo ok || echo "$r")"
r="$(for_pr "$T" acme/widget "$H" 7)"
check "the pull request that used it is still approved there" "$([[ "$r" == "yes|approved|"* ]] && echo ok || echo "$r")"
r="$(for_pr "$T" acme/widget "$H" "")"
check "a command naming no pull request is refused once the approval is used, saying it names none" "$([[ "$r" == "no|used|"*"names no pull request"* ]] && echo ok || echo "$r")"
# The same approval written to the record twice (two hook runs at once) is one approval.
approval_line toolu_a
r="$(for_pr "$T" acme/widget "$H" 8 claim)"
check "one approval on the record twice is still one approval" "$([[ "$r" == "no|used|"* ]] && echo ok || echo "$r")"
# A second approval of the same wording lets a second pull request through.
approval_line toolu_b
r="$(for_pr "$T" acme/widget "$H" 8 claim)"
check "a second approval of the same wording lets a second pull request through" "$([[ "$r" == "yes|approved|"* ]] && [ "$(used_lines 8)" = 1 ] && echo ok || echo "$r")"
r="$(for_pr "$T" acme/widget "$H" 9 claim)"
check "and a third is refused, naming both that used them" "$([[ "$r" == "no|used|"*"pull requests 7 and 8"* ]] && echo ok || echo "$r")"
r="$(for_pr "$T" acme/widget "$H" 7 claim)"
check "the first still goes through" "$([[ "$r" == "yes|approved|"* ]] && echo ok || echo "$r")"
# A use recorded with no approval behind it covers nothing: the first uses, as many as there are
# approvals, are the ones covered, so a used line never approves by itself.
STORE_USED="$WORK/store-one-forged"
approval_line toolu_a
used --repo acme/widget --hash "$H" --pr 7 >/dev/null
used --repo acme/widget --hash "$H" --pr 8 >/dev/null
r="$(for_pr "$T" acme/widget "$H" 8 claim)"
check "R2 a use recorded beyond the approvals there are covers nothing" "$([[ "$r" == "no|used|"* ]] && echo ok || echo "$r")"
r="$(for_pr "$T" acme/widget "$H" 7 claim)"
check "and takes nothing from the pull request that used the approval first" "$([[ "$r" == "yes|approved|"* ]] && echo ok || echo "$r")"
STORE_USED="$WORK/store-one-usedonly"
mkdir -p "$STORE_USED"
used --repo acme/widget --hash "$H" --pr 7 >/dev/null
r="$(for_pr "$T" acme/widget "$H" 7 claim)"
check "R2 a pull request recorded as using wording nobody approved is not approved" "$([[ "$r" == "no|unapproved|"*"has not approved this wording"* ]] && echo ok || echo "$r")"
# In the session that asked him: his picker is one approval, kept with the picker it came from, and
# asking him again about the same file in the same session is a second one.
STORE_USED="$WORK/store-one-session"
F="$(shown onesession)"; T="$WORK/onesession.jsonl"
talk "$T" ask acme/widget "$F"
HF="$(hash_file "$F")"
r="$(for_pr "$T" acme/widget "$HF" 30 claim)"
check "his picker in this session covers the pull request merged on it" "$([[ "$r" == "yes|approved|"* ]] && echo ok || echo "$r")"
check "the approval is kept with the session and the picker it came from" "$(grep '"kind": "approved"' "$STORE_USED/record.jsonl" | grep '"session": "s1"' | grep -q '"picker": "toolu_ask' && echo ok || cat "$STORE_USED/record.jsonl")"
r="$(for_pr "$T" acme/widget "$HF" 31 claim)"
check "the same picker read again is no second approval" "$([[ "$r" == "no|used|"*"pull request 30"* ]] && [ "$(recorded)" = 1 ] && echo ok || echo "$r")"
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/widget "$F"
r="$(for_pr "$T" acme/widget "$HF" 31 claim)"
check "asked again in the same session, his second approval covers the second pull request" "$([[ "$r" == "yes|approved|"* ]] && [ "$(recorded)" = 2 ] && echo ok || echo "$r")"
# A subagent's merge uses the approval too: the use is recorded whoever makes the call.
STORE_USED="$WORK/store-one-agent"
F="$(shown oneagent)"; T="$WORK/oneagent.jsonl"
talk "$T" ask acme/widget "$F"
HF="$(hash_file "$F")"
r="$(AGENT=1 for_pr "$T" acme/widget "$HF" 40 claim)"
check "a subagent's merge on his picker is recorded as the use of it" "$([[ "$r" == "yes|approved|"* ]] && [ "$(used_lines 40)" = 1 ] && ! grep -q '"kind": "approved"' "$STORE_USED/record.jsonl" && echo ok || echo "$r")"
r="$(for_pr "$T" acme/widget "$HF" 41 claim)"
check "so the main session's merge of another pull request on the same picker is refused" "$([[ "$r" == "no|used|"*"pull request 40"* ]] && echo ok || echo "$r")"
# A subagent's call writes the use and no approval. A later session's retry of that same pull
# request is refused, and used to be told he never approved the wording (#3742, low 13).
STORE_USED="$WORK/store-agent-only"
F="$(shown agentonly)"; T="$WORK/agentonly.jsonl"
talk "$T" ask acme/widget "$F"
HF="$(hash_file "$F")"
r="$(AGENT=1 for_pr "$T" acme/widget "$HF" 40 claim)"
check "control: the subagent's merge is let through and writes the use alone" "$([[ "$r" == "yes|approved|"* ]] && [ "$(used_lines 40)" = 1 ] && [ "$(recorded)" = 0 ] && echo ok || echo "$r")"
T0="$WORK/agentonly-later.jsonl"; new_talk "$T0"
r="$(for_pr "$T0" acme/widget "$HF" 40 claim)"
check "a later retry of the pull request a subagent merged is still refused" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
check "and the refusal says the record holds its use and no approval behind it" "$([[ "$r" == *"pull request 40 as let through on this wording"*"holds no approval"* ]] && echo ok || echo "$r")"
r="$(for_pr "$T0" acme/widget "$HF" 41 claim)"
check "a different pull request there is told he has not approved it, with no word of a use of its own" "$([[ "$r" == "no|"*"has not approved this wording"* && "$r" != *"pull request 41 as let through"* ]] && echo ok || echo "$r")"

# One answer of his is one approval, whatever session id its lines are found under (#3742, low 12).
# A resumed or forked session may carry the same picker under a new session id, and an approval
# was keyed by session and picker, so the one answer counted twice and covered a second pull request.
STORE_USED="$WORK/store-fork"
F="$(shown fork)"; T="$WORK/fork.jsonl"
talk "$T" ask acme/widget "$F"
HF="$(hash_file "$F")"
r="$(for_pr "$T" acme/widget "$HF" 50 claim)"
check "control: his picker covers the first pull request" "$([[ "$r" == "yes|approved|"* ]] && echo ok || echo "$r")"
T2="$WORK/fork-resumed.jsonl"
sed 's/"sessionId": "s1"/"sessionId": "s2"/' "$T" > "$T2"
check "control: the copy holds the same picker under another session id" "$(grep -q '"sessionId": "s2"' "$T2" && ! grep -q '"sessionId": "s1"' "$T2" && echo ok || echo "the copy was not rewritten")"
r="$(for_pr "$T2" acme/widget "$HF" 51 claim s2)"
check "R2 the same picker under a resumed session's id is no second approval" "$([[ "$r" == "no|used|"*"pull request 50"* ]] && echo ok || echo "$r")"
r="$(for_pr "$T2" acme/widget "$HF" 50 claim s2)"
check "R2 still possible: the pull request that used it may try again from the resumed session" "$([[ "$r" == "yes|approved|"* ]] && echo ok || echo "$r")"

echo "two pull requests reaching the merge at once on one approval"
# Each claim holds the record while it decides and writes (the pause widens the moment between the
# two, so the case does not depend on luck): exactly one is let through, whichever came first.
STORE_USED="$WORK/store-race"
T="$WORK/race.jsonl"; new_talk "$T"
approval_line toolu_a
for n in 21 22 23 24; do
  ( ANNOUNCE_APPROVAL_CLAIM_PAUSE=0.4 for_pr "$T" acme/widget "$H" "$n" claim > "$WORK/race-$n.out" 2>&1 ) &
done
wait
won="$(cat "$WORK"/race-2?.out | grep -o 'yes|approved' | wc -l | tr -d ' ')"
lost="$(cat "$WORK"/race-2?.out | grep -o 'no|used' | wc -l | tr -d ' ')"
check "of four claims at once on one approval exactly one wins" "$([ "$won" = 1 ] && [ "$lost" = 3 ] && echo ok || echo "won=$won lost=$lost: $(cat "$WORK"/race-2?.out | cut -c1-120)")"
check "and exactly one pull request is recorded as using it" "$([ "$(grep -c '"kind": "used"' "$STORE_USED/record.jsonl")" = 1 ] && echo ok || cat "$STORE_USED/record.jsonl")"
winner="$(grep -l 'yes|approved' "$WORK"/race-2?.out | sed 's/.*race-\([0-9]*\)\.out/\1/')"
check "the one recorded is the one that was let through" "$([ -n "$winner" ] && [ "$(used_lines "$winner")" = 1 ] && echo ok || echo "winner=$winner: $(cat "$STORE_USED/record.jsonl")")"

echo "a use that cannot be recorded refuses the merge (Dan, 2026-11-25: \"Refuse the merge\")"
# The record's folder cannot be made: his picker in this session still counts for a question that
# claims nothing (above, "who may write the record"), but the merge is refused, since the next pull
# request with the same wording could not be told from this one.
STORE_USED="$WORK/store-noclaim/inner"
printf 'not a folder\n' > "$WORK/store-noclaim"
F="$(shown noclaim)"; T="$WORK/noclaim.jsonl"
talk "$T" ask acme/widget "$F"
HF="$(hash_file "$F")"
r="$(for_pr "$T" acme/widget "$HF" 50 claim)"
check "R2 a merge whose use of the approval cannot be recorded is refused" "$([[ "$r" == "no|unrecorded|"* ]] && echo ok || echo "$r")"
check "the refusal says what could not be written and where" "$([[ "$r" == *"could not be written"* && "$r" == *"$STORE_USED/record.jsonl"* ]] && echo ok || echo "$r")"
check "and that the remedy is the folder, not asking him again" "$([[ "$r" == *"run the same merge again"* && "$r" != *"AskUserQuestion"* ]] && echo ok || echo "$r")"
r="$(for_pr "$T" acme/widget "$HF" 50)"
check "the same picker still counts for a question that claims nothing" "$([[ "$r" == "yes|approved|"*"could not be saved"* ]] && echo ok || echo "$r")"
# The record holds his approval and can be read, and can no longer be written.
STORE_USED="$WORK/store-readonly"
T="$WORK/readonly.jsonl"; new_talk "$T"
approval_line toolu_a
chmod 400 "$STORE_USED/record.jsonl"; chmod 500 "$STORE_USED"
r="$(for_pr "$T" acme/widget "$H" 51 claim)"
chmod 700 "$STORE_USED"; chmod 600 "$STORE_USED/record.jsonl"
check "R2 a record that reads and cannot be written refuses the merge, naming it" "$([[ "$r" == "no|unrecorded|"*"$STORE_USED/record.jsonl, could not be written"* ]] && echo ok || echo "$r")"
check "and nothing was recorded for it" "$([ "$(grep -c '"kind": "used"' "$STORE_USED/record.jsonl")" = 0 ] && echo ok || cat "$STORE_USED/record.jsonl")"
r="$(for_pr "$T" acme/widget "$H" 51 claim)"
check "still possible: the same merge goes through once the record can be written" "$([[ "$r" == "yes|approved|"* ]] && [ "$(used_lines 51)" = 1 ] && echo ok || echo "$r")"
# Wording nobody approved is refused as that, whatever the record's folder can take.
STORE_USED="$WORK/store-noclaim/inner"
T="$WORK/noclaim-none.jsonl"; new_talk "$T"
r="$(for_pr "$T" acme/widget "$H" 52 claim)"
check "wording nobody approved is refused as not approved, not as a record that cannot be written" "$([[ "$r" == "no|unapproved|"*"has not approved this wording"* ]] && echo ok || echo "$r")"
# The merge gate always names the pull request; a claim naming none records nothing and is refused.
STORE_USED="$WORK/store-nopr"
approval_line toolu_a
r="$(for_pr "$T" acme/widget "$H" "" claim)"
check "a claim naming no pull request is refused, and records nothing" "$([[ "$r" == "no|unrecorded|"*"no pull request number"* ]] && [ "$(grep -c '"kind": "used"' "$STORE_USED/record.jsonl")" = 0 ] && echo ok || echo "$r")"

echo "his answer is noted when he gives it, and read back from the session's transcript by whoever asks next (#3742 item 1)"
# announce-answer-note.sh runs once a picker is answered and asks the library to note it. A hook that
# runs then finds the picker in the transcript and not yet his answer (the fixture's `payload` says
# how that was measured), so each case is: the picker put, the note, his answer written.
# note <transcript> <picker id> <repo> <file> [answer] [shape] [session] [agent id]: "<yes|no>|<why>".
note() {
  aaf_talk "$@" 2>/dev/null | ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B "$LIB" answered 2>/dev/null \
    | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    d = {"noted": False, "why": "the library gave no answer to `answered`"}
print(("yes" if d["noted"] is True else "no") + "|" + d["why"], end="")'
}
# helper_asks <repo> <hash> <pull request>: the merge gate's claim as lib/merge-when-ready.sh hands it
# the payload: no transcript, and a session id that is no session's. "<yes|no>|<state>|<why>".
helper_asks() {
  printf '%s' '{"session_id":"merge-when-ready","cwd":"/","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"gh pr merge 7 --squash"}}' \
    | ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B "$LIB" check --repo "$1" --hash "$2" --pr "$3" --claim \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(("yes" if d["approved"] is True else "no") + "|" + str(d.get("state")) + "|" + d["why"], end="")'
}
kinds() { local n; n="$(grep -c "\"kind\": \"$1\"" "$STORE_USED/record.jsonl" 2>/dev/null)"; printf '%s' "${n:-0}"; }
STORE_USED="$WORK/store-noted"
F="$(shown noted)"; T="$WORK/noted.jsonl"
HN="$(hash_file "$F")"
P="$(talk "$T" put acme/widget "$F")"
r="$(note "$T" payload "$P" acme/widget "$F")"
check "his answer is noted once the picker is answered, before the transcript holds it" "$([[ "$r" == "yes|" ]] && echo ok || echo "$r")"
check "the note is on the record, naming the session, the picker and the hash of the file" "$(grep '"kind": "answered"' "$STORE_USED/record.jsonl" 2>/dev/null | grep "\"picker\": \"$P\"" | grep '"session": "s1"' | grep -q "\"hash\": \"$HN\"" && echo ok || cat "$STORE_USED/record.jsonl" 2>&1)"
check "a note is no approval: nothing says he approved yet" "$([ "$(kinds approved)" = 0 ] && echo ok || cat "$STORE_USED/record.jsonl")"
r="$(helper_asks acme/widget "$HN" 60)"
check "R2 a note whose answer the transcript does not hold approves nothing" "$([[ "$r" == "no|unapproved|"* ]] && echo ok || echo "$r")"
talk "$T" answer "$P" acme/widget "$F"
r="$(helper_asks acme/widget "$HN" 60)"
check "R2 still possible: the merge helper, which names no session, merges on an approval that was only ever in the session" "$([[ "$r" == "yes|approved|" ]] && echo ok || echo "$r")"
check "and his approval is on the record, as the session and the picker it came from" "$(grep '"kind": "approved"' "$STORE_USED/record.jsonl" 2>/dev/null | grep "\"picker\": \"$P\"" | grep -q '"session": "s1"' && echo ok || cat "$STORE_USED/record.jsonl" 2>&1)"
r="$(helper_asks acme/widget "$HN" 60)"
check "the same merge tried again is approved, and his approval is not written twice" "$([[ "$r" == "yes|approved|" ]] && [ "$(kinds approved)" = 1 ] && echo ok || echo "$r $(kinds approved) lines")"
r="$(note "$T" payload "$P" acme/widget "$F")"
check "a second note of the same picker adds nothing" "$([[ "$r" == "yes|" ]] && [ "$(kinds answered)" = 1 ] && echo ok || echo "$r $(kinds answered) notes")"

# The file touched after he answered and before anything read his answer back: the hash was taken
# when he answered, so his approval of that wording stands, and what the file holds now is not it.
STORE_USED="$WORK/store-noted-touched"
F="$(shown touched)"; T="$WORK/touched.jsonl"
HT="$(hash_file "$F")"
P="$(talk "$T" put acme/widget "$F")"
note "$T" payload "$P" acme/widget "$F" >/dev/null
talk "$T" answer "$P" acme/widget "$F"
printf 'A line nobody showed him.\n' >> "$F"
r="$(helper_asks acme/widget "$HT" 61)"
check "R2 still possible: wording he approved is approved though the file was written after his answer" "$([[ "$r" == "yes|approved|" ]] && echo ok || echo "$r")"
r="$(helper_asks acme/widget "$(hash_file "$F")" 62)"
check "R2 what the file holds after a later write is not wording he approved" "$([[ "$r" == "no|unapproved|"* ]] && echo ok || echo "$r")"

# What he answered is read from the transcript and never from what the hook was handed: a note made
# with a payload saying Approve, for a picker he answered Not yet, approves nothing.
STORE_USED="$WORK/store-noted-notyet"
F="$(shown notyet-noted)"; T="$WORK/notyet-noted.jsonl"
HY="$(hash_file "$F")"
P="$(talk "$T" put acme/widget "$F")"
r="$(note "$T" payload "$P" acme/widget "$F" "Approve the wording")"
talk "$T" answer "$P" acme/widget "$F" "Not yet"
check "the made up note is taken, since a note says nothing about his answer" "$([[ "$r" == "yes|" ]] && echo ok || echo "$r")"
r="$(helper_asks acme/widget "$HY" 63)"
check "R2 a note handed an Approve he never gave approves nothing: his Not yet is read from the transcript" "$([[ "$r" == "no|unapproved|"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r")"
# The same for a picker that closed by its own timeout.
P="$(talk "$T" put acme/widget "$F")"
note "$T" payload "$P" acme/widget "$F" >/dev/null
talk "$T" answer "$P" acme/widget "$F" "Approve the wording" timeout
r="$(helper_asks acme/widget "$HY" 63)"
check "R2 a noted picker that closed by its own timeout approves nothing" "$([[ "$r" == "no|unapproved|"* ]] && echo ok || echo "$r")"

# A note made later, by a run of the hook that is not Claude Code's, after the session rewrote the
# file: the hash noted is of the rewrite, and the file's change time says it came after his answer.
STORE_USED="$WORK/store-noted-late"
F="$(shown late)"; T="$WORK/late.jsonl"
P="$(talk "$T" put acme/widget "$F")"
talk "$T" answer "$P" acme/widget "$F"
printf '@here\nWording he never saw.\n' > "$F"
HL="$(hash_file "$F")"
r="$(note "$T" payload "$P" acme/widget "$F")"
r="$(helper_asks acme/widget "$HL" 64)"
check "R2 a note taken after the file was rewritten approves nothing" "$([[ "$r" == "no|unapproved|"* ]] && echo ok || echo "$r")"
check "and the refusal says the file had changed after he answered" "$([[ "$r" == *"had changed after he answered"* ]] && echo ok || echo "$r")"

# The file was never opened in front of him: a note does not stand in for that.
STORE_USED="$WORK/store-noted-unshown"
mkdir -p "$WORK/unshown-noted"; F="$WORK/unshown-noted/announcement.md"; printf '%s\n' "$POST" > "$F"
T="$WORK/unshown-noted.jsonl"; new_talk "$T"
P="$(talk "$T" put acme/widget "$F")"
note "$T" payload "$P" acme/widget "$F" >/dev/null
talk "$T" answer "$P" acme/widget "$F"
r="$(helper_asks acme/widget "$(hash_file "$F")" 65)"
check "R2 a noted Approve of a file never opened in front of him approves nothing, and says so" "$([[ "$r" == "no|unapproved|"*"was not opened in front of him"* ]] && echo ok || echo "$r")"

# EVERY main session picker is noted, by its ids alone (#3789): the session, its transcript and the
# picker, and whether the transcript held the picker's line when the hook ran. What it asked is told
# later, from the transcript, by whoever reads the note. Only a picker the hook can already tell is
# an announcement's, with a repository and a file, is noted with the file's hash beside its ids.
# bare <picker> <held>: ok when the record's one note of that picker carries its ids and nothing else.
bare() {
  grep '"kind": "answered"' "$STORE_USED/record.jsonl" 2>/dev/null | grep "\"picker\": \"$1\"" | python3 -c 'import json, sys
lines = [json.loads(l) for l in sys.stdin if l.strip()]
keys = sorted(lines[0]) if len(lines) == 1 else []
if len(lines) != 1:
    print("%d notes of %s" % (len(lines), sys.argv[1]), end="")
elif keys != ["at", "held", "kind", "picker", "session", "transcript"] or lines[0]["held"] is not json.loads(sys.argv[2]):
    print("the note is " + json.dumps(lines[0]), end="")
else:
    print("ok", end="")' "$@"
}
# settled_as <picker> <needle>: whether the record holds a settled line for that picker saying that.
# Read into a variable and matched there, never piped into a quiet grep (test-pipefail-shortcircuit.sh).
settled_as() {
  local line
  line="$(grep '"kind": "settled"' "$STORE_USED/record.jsonl" 2>/dev/null | grep "\"picker\": \"$1\"")"
  [[ -n "$line" && "$line" == *"$2"* ]]
}
STORE_USED="$WORK/store-noted-not"
F="$(shown not-noted)"; T="$WORK/not-noted.jsonl"
P="$(talk "$T" put acme/widget "$F")"
r="$(note "$T" payload "$P" acme/widget "$F" "" "" "" a9bba4c0ffee)"
check "#3789 a subagent's picker is not noted, and nothing is said" "$([[ "$r" == "no|" ]] && [ "$(kinds answered)" = 0 ] && [ ! -e "$STORE_USED/record.jsonl" ] && echo ok || echo "$r")"
P2="$(talk "$T" put acme/widget "$F" othersource)"
r="$(note "$T" payload "$P2" acme/widget "$F" "" othersource)"
check "#3789 a picker of another source is noted by its ids alone, and nothing is said" "$([[ "$r" == "yes|" ]] && bare "$P2" true || echo "$r")"
P3="$(talk "$T" put acme/widget "$F" prefilled)"
r="$(note "$T" payload "$P3" acme/widget "$F" "" prefilled)"
check "#3789 a picker the session sent with its answer filled in is noted by its ids alone: no hash is taken for it" "$([[ "$r" == "yes|" ]] && bare "$P3" true || echo "$r")"
P4="$(talk "$T" put "not a repository" "$F")"
r="$(note "$T" payload "$P4" "not a repository" "$F")"
check "#3789 a picker whose metadata names no repository is noted by its ids alone, and nothing is said" "$([[ "$r" == "yes|" ]] && bare "$P4" true || echo "$r")"
talk "$T" answer "$P2" acme/widget "$F" "Approve the wording" othersource
talk "$T" answer "$P3" acme/widget "$F" "Approve the wording" prefilled
talk "$T" answer "$P4" "not a repository" "$F"
r="$(helper_asks acme/widget "$(hash_file "$F")" 69)"
check "R2 #3789 none of those notes approves anything" "$([[ "$r" == "no|unapproved|"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r")"
check "#3789 the picker of another source is settled as no picker of this record's" "$(settled_as "$P2" 'no picker of a source' && echo ok || cat "$STORE_USED/record.jsonl")"
check "#3789 the refusal still says why his Approve in a picker naming no repository does not count" "$([[ "$r" == *"does not name the repository"* ]] && echo ok || echo "$r")"
# A noted picker of this source that can never count (sent with its answer filled in, or naming no
# repository and file) is settled too, once it has been said: left unjudged, its session would be
# read back on every later call, and the reason said in refusals about other repositories.
check "#3789 a noted picker sent with its answer filled in is settled as never put to him" "$(settled_as "$P3" 'never put to him' && echo ok || cat "$STORE_USED/record.jsonl")"
check "#3789 a noted picker naming no repository is settled as one that can approve nothing" "$(settled_as "$P4" 'does not name the repository' && [ "$(kinds settled)" = 3 ] && echo ok || cat "$STORE_USED/record.jsonl")"
r="$(helper_asks acme/widget "$(hash_file "$F")" 69)"
check "#3789 and none of them is read back or said again" "$([[ "$r" == "no|unapproved|"* && "$r" != *"does not name the repository"* ]] && [ "$(kinds settled)" = 3 ] && echo ok || echo "$r")"
# The picker is read from the transcript, by the id the hook was handed, and not from the hook's own
# copy of its input: no real payload has been printed, and the dialog may hand the hook an input
# holding his answers and without the metadata. Such a payload is noted all the same.
STORE_USED="$WORK/store-noted-form"
F="$(shown form-noted)"; T="$WORK/form-noted.jsonl"
P="$(talk "$T" put acme/widget "$F")"
r="$(AAF_PAYLOAD_FORM="answers nometadata" note "$T" payload "$P" acme/widget "$F")"
check "a payload whose input holds his answers and no metadata is noted, from the transcript's picker" "$([[ "$r" == "yes|" ]] && [ "$(kinds answered)" = 1 ] && echo ok || echo "$r")"
talk "$T" answer "$P" acme/widget "$F"
r="$(helper_asks acme/widget "$(hash_file "$F")" 67)"
check "R2 still possible: and his approval is found through it" "$([[ "$r" == "yes|approved|" ]] && echo ok || echo "$r")"
# A picker the transcript does not hold (yet, or at all) is noted from the hook's own copy of its
# input when that names the source, and approves nothing until the transcript holds his answer.
STORE_USED="$WORK/store-noted-absent"
F="$(shown absent-noted)"; T="$WORK/absent-noted.jsonl"
r="$(note "$T" payload toolu_absent1 acme/widget "$F")"
check "a picker the transcript does not hold is noted from the payload's own input" "$([[ "$r" == "yes|" ]] && [ "$(kinds answered)" = 1 ] && echo ok || echo "$r")"
r="$(helper_asks acme/widget "$(hash_file "$F")" 68)"
check "R2 and approves nothing, since the transcript holds no answer of his to it" "$([[ "$r" == "no|unapproved|"* ]] && echo ok || echo "$r")"
# A picker neither copy says the source of (#3789, as measured on the installed hook: the transcript
# did not hold the picker's line yet, and the hook's copy carried no metadata). It is noted by its
# ids alone and nothing is said: what it asked is told later, from the transcript.
STORE_USED="$WORK/store-noted-idsonly"
F="$(shown late-noted)"; T="$WORK/late-noted.jsonl"
HLATE="$(hash_file "$F")"
r="$(AAF_PAYLOAD_FORM=nometadata note "$T" payload toolu_absent2 acme/widget "$F")"
check "#3789 one the transcript does not hold and the payload does not name the source of is noted by its ids alone, and nothing is said" "$([[ "$r" == "yes|" ]] && bare toolu_absent2 false || echo "$r")"
r="$(helper_asks acme/widget "$HLATE" 70)"
check "R2 #3789 a note that names no source approves nothing, and is not settled while the transcript does not hold its picker" "$([[ "$r" == "no|unapproved|"* ]] && [ "$(kinds approved)" = 0 ] && [ "$(kinds settled)" = 0 ] && echo ok || echo "$r $(cat "$STORE_USED/record.jsonl")")"
talk "$T" late toolu_absent2 acme/widget "$F"
r="$(helper_asks acme/widget "$HLATE" 70)"
check "R2 #3789 nor once the transcript holds the picker and not yet his answer" "$([[ "$r" == "no|unapproved|"* ]] && [ "$(kinds approved)" = 0 ] && [ "$(kinds settled)" = 0 ] && echo ok || echo "$r")"
talk "$T" answer toolu_absent2 acme/widget "$F"
r="$(helper_asks acme/widget "$HLATE" 70)"
check "R2 still possible #3789: his Approve in a picker noted by its ids alone is found by a merge naming no session" "$([[ "$r" == "yes|approved|" ]] && echo ok || echo "$r")"
check "#3789 and written to the record once, as the session and the picker it came from" "$(line="$(grep '"kind": "approved"' "$STORE_USED/record.jsonl" 2>/dev/null | grep '"picker": "toolu_absent2"')"; [[ "$line" == *'"session": "s1"'* && "$line" == *"\"hash\": \"$HLATE\""* ]] && [ "$(kinds approved)" = 1 ] && echo ok || cat "$STORE_USED/record.jsonl" 2>&1)"
# A note that holds no hash never carries the wording past a later write to the file: it is judged
# as a picker with no note is, by the file as it stands, unchanged since his answer.
STORE_USED="$WORK/store-noted-late-changed"
F="$(shown late-changed)"; T="$WORK/late-changed.jsonl"
HBEFORE="$(hash_file "$F")"
AAF_PAYLOAD_FORM=nometadata note "$T" payload toolu_absent5 acme/widget "$F" >/dev/null
talk "$T" late toolu_absent5 acme/widget "$F"
talk "$T" answer toolu_absent5 acme/widget "$F"
printf 'A line nobody showed him.\n' >> "$F"
r="$(helper_asks acme/widget "$(hash_file "$F")" 71)"
check "R2 #3789 with no hash noted, a file changed after his answer is not wording he approved" "$([[ "$r" == "no|unapproved|"*"has changed since he answered"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r")"
check "#3789 and the refusal says to ask him again" "$([[ "$r" == *"ask him again"* ]] && echo ok || echo "$r")"
r="$(helper_asks acme/widget "$HBEFORE" 71)"
check "R2 #3789 and what the file held before the write is not approved either: nothing noted it" "$([[ "$r" == "no|unapproved|"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r")"
# A note that names a source the hook was only handed, for a picker the transcript shows is an
# ordinary one, is no approval and is not taken as one.
STORE_USED="$WORK/store-noted-claimed"
F="$(shown claimed)"; T="$WORK/claimed.jsonl"
r="$(note "$T" payload toolu_claimed1 acme/widget "$F")"
talk "$T" late toolu_claimed1 acme/widget "$F" plain
talk "$T" answer toolu_claimed1 acme/widget "$F" "Approve the wording" plain
r="$(helper_asks acme/widget "$(hash_file "$F")" 72)"
check "R2 #3789 a note handed a source the transcript's picker does not name approves nothing, and is settled" "$([[ "$r" == "no|unapproved|"* ]] && [ "$(kinds approved)" = 0 ] && settled_as toolu_claimed1 'no picker of a source' && echo ok || echo "$r $(cat "$STORE_USED/record.jsonl")")"
# A transcript that is not there when the hook runs: noted all the same, and settled by the first
# question that finds it gone, since what its picker asked can never be read.
STORE_USED="$WORK/store-noted-gone"
F="$(shown gone)"
r="$(AAF_PAYLOAD_FORM=nometadata note "$WORK/no-such-talk.jsonl" payload toolu_absent3 acme/widget "$F")"
check "#3789 a picker whose transcript cannot be read is noted by its ids alone, saying so" "$([[ "$r" == "yes|" ]] && bare toolu_absent3 null || echo "$r")"
r="$(helper_asks acme/widget "$(hash_file "$F")" 73)"
check "R2 #3789 it approves nothing, and is settled as one whose transcript is gone" "$([[ "$r" == "no|unapproved|"* ]] && settled_as toolu_absent3 'transcript is gone' && echo ok || echo "$r $(cat "$STORE_USED/record.jsonl")")"
r="$(helper_asks acme/widget "$(hash_file "$F")" 73)"
check "#3789 and is not looked for again" "$([[ "$r" == "no|unapproved|"* && "$r" != *"could not be read back"* ]] && [ "$(kinds settled)" = 1 ] && echo ok || echo "$r")"
# The same for a note that names its repository and file, taken while the transcript was there: once
# the transcript is gone the picker can never be read, so it is settled and said once (review of
# #3669, low 6). It was read back, and said as "could not be read back", on every call for ever.
STORE_USED="$WORK/store-noted-gone-named"
F="$(shown gone-named)"; T="$WORK/gone-named.jsonl"
P="$(talk "$T" put acme/widget "$F")"
r="$(note "$T" payload "$P" acme/widget "$F")"
rm -f "$T"
r2="$(helper_asks acme/widget "$(hash_file "$F")" 74)"
check "R2 #3669 E a note naming its repository whose transcript is gone approves nothing, is said once and settled" "$([[ "$r" == "yes|" && "$r2" == "no|unapproved|"*"gone-named.jsonl, can never be read"* && "$r2" != *"could not be read back"* ]] && settled_as "$P" 'transcript is gone' && echo ok || echo "$r / $r2 $(cat "$STORE_USED/record.jsonl")")"
r2="$(helper_asks acme/widget "$(hash_file "$F")" 74)"
check "#3669 E and is neither read nor said again" "$([[ "$r2" == "no|unapproved|"* && "$r2" != *"can never be read"* && "$r2" != *"could not be read back"* ]] && [ "$(kinds settled)" = 1 ] && echo ok || echo "$r2")"
STORE_USED="$WORK/store-noted-absent"
F="$(shown absent-noted-2)"; T="$WORK/absent-noted-2.jsonl"
r="$(AAF_PAYLOAD_FORM=nometadata note "$T" payload toolu_absent4 acme/widget "$F" "" "" "" a9bba4c0ffee)"
check "a subagent's picker is never noted whatever it asked" "$([[ "$r" == "no|" ]] && [ "$(kinds answered)" = 1 ] && echo ok || echo "$r")"
# An ordinary picker, which the transcript holds and which names no source.
P2="$(talk "$T" put acme/widget "$F" plain)"
r="$(note "$T" payload "$P2" acme/widget "$F" "" plain)"
check "#3789 a picker the transcript holds with no metadata is noted by its ids alone, and nothing is said" "$([[ "$r" == "yes|" ]] && bare "$P2" true || echo "$r")"
STORE_USED="$WORK/store-noted-not"
r="$(printf 'not json' | ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B "$LIB" answered 2>&1)"
check "#3789 a payload nothing can read is not noted, and that is said" "$([[ "$r" == *'"noted": false'*"could not be noted"*"was not a JSON object"* ]] && echo ok || echo "$r")"
r="$(note "$T" payload "" acme/widget "$F")"
check "#3789 a payload naming no picker is not noted, and that is said" "$([[ "$r" == "no|"*"could not be noted"*"was not told the session, its transcript and the picker's id"* ]] && echo ok || echo "$r")"

# ONE PASS over a session's transcript judges every picker of it the record notes and nothing has
# judged (#3789): three ordinary pickers and an approval cost the reads one picker costs.
STORE_USED="$WORK/store-noted-many"
F="$(shown many)"; T="$WORK/many.jsonl"
HMANY="$(hash_file "$F")"
for n in 1 2 3; do
  PM="$(talk "$T" put acme/widget "$F" plain)"
  note "$T" payload "$PM" acme/widget "$F" "" plain >/dev/null
  talk "$T" answer "$PM" acme/widget "$F" "A" plain
done
talk "$T" bash "$BBEDIT --front-window $F"
AAF_PAYLOAD_FORM=nometadata note "$T" payload toolu_many4 acme/widget "$F" >/dev/null
talk "$T" late toolu_many4 acme/widget "$F"
talk "$T" answer toolu_many4 acme/widget "$F"
# opens <transcript> <hash>: how many times one question opens that transcript, counted in process.
opens() {
  ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B -c 'import builtins, importlib.util, sys
spec = importlib.util.spec_from_file_location("announce_approval", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
real, seen = builtins.open, []
def counting(path, *a, **k):
    if path == sys.argv[2]:
        seen.append(path)
    return real(path, *a, **k)
builtins.open = counting
d = lib.check("acme/widget", sys.argv[3], {"session_id": "merge-when-ready"}, 74)
builtins.open = real
print(("yes" if d["approved"] is True else "no") + "|" + str(len(seen)), end="")' "$LIB" "$1" "$2"
}
STORE_ONE="$WORK/store-noted-one"; mkdir -p "$STORE_ONE"
grep '"picker": "toolu_many4"' "$STORE_USED/record.jsonl" > "$STORE_ONE/record.jsonl"
many="$(opens "$T" "$HMANY")"
one="$(STORE_USED="$STORE_ONE" opens "$T" "$HMANY")"
check "R2 still possible #3789: the approval among a session's ordinary pickers is found" "$([[ "$many" == "yes|"* && "$one" == "yes|"* ]] && echo ok || echo "four notes: $many, one note: $one")"
check "#3789 four noted pickers of one session cost the transcript reads one costs" "$([ "${many#*|}" = "${one#*|}" ] && [ "${one#*|}" -ge 1 ] && echo ok || echo "four notes: $many, one note: $one")"
check "#3789 and each ordinary one is settled in that pass" "$([ "$(kinds settled)" = 3 ] && echo ok || cat "$STORE_USED/record.jsonl")"
check "#3789 a settled ordinary picker takes no approval back" "$([[ "$(helper_asks acme/widget "$HMANY" 74)" == "yes|approved|" ]] && echo ok || helper_asks acme/widget "$HMANY" 74)"

# The sessions read back are the ones whose NEWEST unjudged note is newest (#3789). Every picker is
# noted now, so a session's first note is its first picker of any kind, long before the approval.
STORE_USED="$WORK/store-noted-order"
F="$(shown order)"; T="$WORK/order.jsonl"
HORDER="$(hash_file "$F")"
PO="$(talk "$T" put acme/widget "$F" plain)"
note "$T" payload "$PO" acme/widget "$F" "" plain >/dev/null
for n in 1 2 3 4 5 6; do
  aaf_new "$WORK/order-other-$n.jsonl"
  PX="$(talk "$WORK/order-other-$n.jsonl" put acme/widget "$F" "" "other$n")"
  note "$WORK/order-other-$n.jsonl" payload "$PX" acme/widget "$F" "" "" "other$n" >/dev/null
done
talk "$T" bash "$BBEDIT --front-window $F"
AAF_PAYLOAD_FORM=nometadata note "$T" payload toolu_order1 acme/widget "$F" >/dev/null
talk "$T" late toolu_order1 acme/widget "$F"
talk "$T" answer toolu_order1 acme/widget "$F"
r="$(helper_asks acme/widget "$HORDER" 75)"
check "R2 still possible #3789: a session whose first note is older than six other sessions' is read back for its newest" "$([[ "$r" == "yes|approved|" ]] && echo ok || echo "$r")"
# HOW MANY SESSIONS ONE CALL READS BACK (Dan, 2026-11-26, by picker: "Raise it to 50 (Recommended)").
# Eight other sessions each hold a newer note than the session that holds his Approve, and none of
# the eight can be judged (its picker is put and not answered), so reading them again settles
# nothing. At five sessions a call his approval was never reached, and he was asked again.
STORE_USED="$WORK/store-noted-fifty"
F="$(shown fifty)"; T="$WORK/fifty.jsonl"
HFIFTY="$(hash_file "$F")"
AAF_PAYLOAD_FORM=nometadata note "$T" payload toolu_fifty1 acme/widget "$F" >/dev/null
talk "$T" late toolu_fifty1 acme/widget "$F"
talk "$T" answer toolu_fifty1 acme/widget "$F"
for n in 1 2 3 4 5 6 7 8; do
  aaf_new "$WORK/fifty-other-$n.jsonl"
  PX="$(talk "$WORK/fifty-other-$n.jsonl" put acme/widget "$F" "" "fifty$n")"
  note "$WORK/fifty-other-$n.jsonl" payload "$PX" acme/widget "$F" "" "" "fifty$n" >/dev/null
done
# asks_with <hash> [sessions one call reads back] [late]: a hook naming no session asks, without a
# claim and in process, with that many sessions read back in place of the library's own number, and
# with `late` the call's time already run out when the first noted session comes up: "<yes|no>|<why>".
asks_with() {
  ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B -c 'import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("announce_approval", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
if sys.argv[3]:
    lib.NOTED_SESSIONS = int(sys.argv[3])
if sys.argv[4] == "late":
    lib._clock = lambda: time.monotonic() + 10 ** 6
d = lib.check("acme/widget", sys.argv[2], {"session_id": "merge-when-ready"}, 76)
print(("yes" if d["approved"] is True else "no") + "|" + d["why"], end="")' "$LIB" "$1" "${2:-}" "${3:-}"
}
# The two ways a call stops short of a noted session are read first, while nothing is on the record
# for his approval yet. Each says how many sessions it left unread, and why: a call that stopped
# short never reads as one that looked and found no approval.
r="$(asks_with "$HFIFTY" 5)"
check "R2 #3669 with five sessions read back, his Approve behind eight newer notes is not reached, and the refusal says four sessions were left unread" "$([[ "$r" == "no|"*"4 sessions holding a picker the record notes were left unread, because one call reads back 5"*"an answer of his there is not known to this call"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r")"
r="$(asks_with "$HFIFTY" "" late)"
check "R2 #3669 a call whose time ran out before any noted session was read approves nothing, and says all nine were left unread" "$([[ "$r" == "no|"*"9 sessions holding a picker the record notes were left unread, because the 12 seconds one call has ran out"*"an answer of his there is not known to this call"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r")"
r="$(helper_asks acme/widget "$HFIFTY" 76)"
check "R2 still possible #3669: his Approve is found by a merge naming no session when eight other sessions hold a newer unjudged note" "$([[ "$r" == "yes|approved|" ]] && echo ok || echo "$r")"
check "#3669 the number of sessions one call reads back is the one Dan chose" "$([[ "$(python3 -B -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("announce_approval", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
print(lib.NOTED_SESSIONS, end="")' "$LIB")" == 50 ]] && echo ok || echo "it is not 50")"
# A wording file that cannot be hashed is noted with why, and that reason is the refusal's.
STORE_USED="$WORK/store-noted-nofile"
mkdir -p "$WORK/nofile"; aaf_new "$WORK/nofile.jsonl"; T="$WORK/nofile.jsonl"
talk "$T" bash "$BBEDIT --front-window $WORK/nofile/announcement.md"
P="$(talk "$T" put acme/widget "$WORK/nofile/announcement.md")"
r="$(note "$T" payload "$P" acme/widget "$WORK/nofile/announcement.md")"
talk "$T" answer "$P" acme/widget "$WORK/nofile/announcement.md"
check "an answer about a file that is not there is noted with why" "$([[ "$r" == "yes|" ]] && grep '"kind": "answered"' "$STORE_USED/record.jsonl" | grep -q 'could not be read' && echo ok || echo "$r: $(cat "$STORE_USED/record.jsonl" 2>&1)")"
r="$(helper_asks acme/widget "$H" 66)"
check "and approves nothing, in those words" "$([[ "$r" == "no|unapproved|"*"could not be read"* ]] && echo ok || echo "$r")"
# The record cannot take the note: said, so the hook can say it to the session.
STORE_USED="$WORK/store-noted-unwritable/inner"
printf 'not a folder\n' > "$WORK/store-noted-unwritable"
F="$(shown unwritable-noted)"; T="$WORK/unwritable-noted.jsonl"
P="$(talk "$T" put acme/widget "$F")"
r="$(note "$T" payload "$P" acme/widget "$F")"
check "#3789 a note the record cannot take is said, naming the record" "$([[ "$r" == "no|"*"could not be noted"*"$STORE_USED/record.jsonl"* ]] && echo ok || echo "$r")"
P="$(talk "$T" put acme/widget "$F" plain)"
r="$(note "$T" payload "$P" acme/widget "$F" "" plain)"
check "#3789 and so is an ordinary picker's" "$([[ "$r" == "no|"*"could not be noted"*"$STORE_USED/record.jsonl"* ]] && echo ok || echo "$r")"

unset STORE_USED

echo "the open of the file is the session's last tool call before the picker (#3742 item 2)"
# Two wording files open at once: the second is the window in front when he answers about the
# first, and the picker shows him neither file's name. So an open counts only when nothing else of
# the session's ran between it and the picker.
# The two are named apart: a command naming a file's own name already voids its open (above).
STORE_USED="$WORK/store-two-files"
mkdir -p "$WORK/two-a" "$WORK/two-b"
FA="$WORK/two-a/post-a.md"; FB="$WORK/two-b/post-b.md"
printf '%s\n' "$POST" > "$FA"; printf '%s\nA second post.\n' "$POST" > "$FB"
T="$WORK/two.jsonl"; new_talk "$T"
talk "$T" bash "$BBEDIT --front-window $FA"
talk "$T" bash "$BBEDIT --front-window $FB"
talk "$T" ask acme/two "$FA"
r="$(asked "$T" acme/two "$(hash_file "$FA")")"
check "R2 his Approve for a file opened before another file was opened is not approved" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
check "the refusal says another call came between the open and the picker, names it, and says what to do" "$([[ "$r" == *"made another tool call (Bash)"* && "$r" == *"last tool call before the picker"* && "$r" == *"open the file again"* ]] && echo ok || echo "$r")"
# The second file's open is not the last call before ITS picker either: the first picker came between.
talk "$T" ask acme/two "$FB"
r="$(asked "$T" acme/two "$(hash_file "$FB")")"
check "R2 nor is the second file's, asked about after the first picker" "$([[ "$r" == "no|"*"made another tool call (AskUserQuestion)"* ]] && echo ok || echo "$r")"
# Any call counts, one that names neither file included.
F="$(shown between)"; T="$WORK/between.jsonl"
talk "$T" bash "ls /tmp"
talk "$T" ask acme/two "$F"
r="$(asked "$T" acme/two "$(hash_file "$F")")"
check "R2 a call that names no wording file, between the open and the picker, voids the open too" "$([[ "$r" == "no|"*"made another tool call (Bash)"* ]] && echo ok || echo "$r")"
check "and nothing was written to the record for any of them" "$([ ! -e "$STORE_USED/record.jsonl" ] && echo ok || cut -c1-700 "$STORE_USED/record.jsonl")"
# Still possible: each file opened and asked about in turn, and a file opened again after other work.
T="$WORK/two-turns.jsonl"; new_talk "$T"
talk "$T" bash "$BBEDIT --front-window $FA"
talk "$T" ask acme/two "$FA"
talk "$T" bash "$BBEDIT --front-window $FB"
talk "$T" ask acme/two "$FB"
r="$(asked "$T" acme/two "$(hash_file "$FA")")"
check "R2 still possible: two files each opened and then asked about, the first" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
r="$(asked "$T" acme/two "$(hash_file "$FB")")"
check "R2 still possible: and the second" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
F="$(shown reopened-two)"; T="$WORK/reopened-two.jsonl"
talk "$T" bash "ls /tmp"
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/two-reopened "$F"
r="$(asked "$T" acme/two-reopened "$(hash_file "$F")")"
check "R2 still possible: a file opened again after other work, and asked about next, is approved" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
# $how is the library's own how to ask text, read from its answer at the top of this suite.
check "how to ask says the picker is the very next call after the open" "$([[ "$how" == *"very next tool call"* ]] && echo ok || echo "the how to ask text does not say so: $how")"

echo "his last answer on a wording decides, on the record as in the session (#3742 item 3)"
# He approves and the approval is recorded. Asked again about the same unchanged file, he answers
# Not yet. The recorded approval used to stand, and the merge went through on it.
STORE_USED="$WORK/store-withdrawn"
F="$(shown withdrawn)"; T="$WORK/withdrawn.jsonl"
talk "$T" ask acme/widget "$F"
H3="$(hash_file "$F")"
r="$(asked "$T" acme/widget "$H3")"
check "his approval is recorded" "$([[ "$r" == "yes||" ]] && [ "$(recorded)" = 1 ] && echo ok || echo "$r")"
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/widget "$F" "Not yet"
r="$(asked "$T" acme/widget "$H3")"
check "R2 a later Not yet about the same unchanged file takes the recorded approval back" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
check "the refusal says he approved it and then answered otherwise, which took it back" "$([[ "$r" == *"took that approval back"* && "$r" == *"Not yet"* ]] && echo ok || echo "$r")"
check "the withdrawal is on the record, naming the wording" "$(grep '"kind": "withdrawn"' "$STORE_USED/record.jsonl" 2>/dev/null | grep -q "\"hash\": \"$H3\"" && echo ok || cat "$STORE_USED/record.jsonl")"
asked "$T" acme/widget "$H3" >/dev/null
check "and is written once however often it is read" "$([ "$(kinds withdrawn)" = 1 ] && echo ok || echo "$(kinds withdrawn) lines")"
# A later session with no picker of its own, the merge helper, and the command line that only reads
# are each answered from the record alone.
T2="$WORK/withdrawn-later.jsonl"; new_talk "$T2"
r="$(asked "$T2" acme/widget "$H3" s2)"
check "R2 a later session is refused on the record alone" "$([[ "$r" == "no|"*"took that approval back"* ]] && echo ok || echo "$r")"
r="$(helper_asks acme/widget "$H3" 71)"
check "R2 and so is a merge that names no session" "$([[ "$r" == "no|unapproved|"*"took that approval back"* ]] && echo ok || echo "$r")"
r="$(ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B "$LIB" check --repo acme/widget --hash "$H3")"
check "the command line that only reads says the same" "$([[ "$r" == *'"approved": false'* && "$r" == *"took that approval back"* ]] && echo ok || echo "$r")"
# Still possible: he approves it again, and that later answer is the one that decides.
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$H3")"
check "R2 still possible: approved again afterwards, the wording is approved" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
r="$(asked "$T2" acme/widget "$H3" s2)"
check "R2 still possible: and a later session merges it on the record" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
# A subagent's call counts his Not yet for that call and writes nothing, as with his Approve.
STORE_USED="$WORK/store-withdrawn-agent"
F="$(shown withdrawn-agent)"; T="$WORK/withdrawn-agent.jsonl"
talk "$T" ask acme/widget "$F"
asked "$T" acme/widget "$H3" >/dev/null
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/widget "$F" "Not yet"
r="$(AGENT=1 asked "$T" acme/widget "$H3")"
check "R2 a subagent's call is refused on his Not yet too" "$([[ "$r" == "no|"*"took that approval back"* ]] && echo ok || echo "$r")"
check "and writes nothing to the record" "$([ "$(kinds withdrawn)" = 0 ] && echo ok || echo "$(kinds withdrawn) lines")"
# It is the wording he answered about that decides, whichever file held it.
STORE_USED="$WORK/store-withdrawn-wording"
F="$(shown wd-one)"; T="$WORK/wd-one.jsonl"
talk "$T" ask acme/widget "$F"
asked "$T" acme/widget "$H3" >/dev/null
F2="$(shown wd-two)"; T2="$WORK/wd-two.jsonl"
talk "$T2" ask acme/widget "$F2" "Not yet"
r="$(asked "$T2" acme/widget "$H3")"
check "R2 his Not yet about the same wording in another file takes the approval back" "$([[ "$r" == "no|"*"took that approval back"* ]] && echo ok || echo "$r")"
# Other wording is another matter.
STORE_USED="$WORK/store-withdrawn-other"
F="$(shown wo-one)"; T="$WORK/wo-one.jsonl"
talk "$T" ask acme/widget "$F"
asked "$T" acme/widget "$H3" >/dev/null
mkdir -p "$WORK/wo-two"; FO="$WORK/wo-two/other-post.md"
printf '%s\nAnother line.\n' "$POST" > "$FO"
talk "$T" bash "$BBEDIT --front-window $FO"
talk "$T" ask acme/widget "$FO" "Not yet"
r="$(asked "$T" acme/widget "$H3")"
check "still possible: his Not yet about other wording takes nothing back" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
# With no note of his answer and the file changed since, the wording he declined cannot be hashed.
# The withdrawal then names the file, and takes back his earlier approvals of that file.
STORE_USED="$WORK/store-withdrawn-changed"
F="$(shown wc)"; T="$WORK/wc.jsonl"
talk "$T" ask acme/widget "$F"
asked "$T" acme/widget "$H3" >/dev/null
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/widget "$F" "Not yet"
printf '%s\n- Changed after his Not yet\n' "$POST" > "$F"
r="$(asked "$T" acme/widget "$H3")"
check "R2 a Not yet whose wording can no longer be hashed takes back his approvals of that file" "$([[ "$r" == "no|"*"took that approval back"* ]] && echo ok || echo "$r")"
# A picker that closed on its own timeout is no answer of his. It takes nothing back from the
# record, and is settled there so it is not read again.
STORE_USED="$WORK/store-withdrawn-timeout"
F="$(shown wt)"; T="$WORK/wt.jsonl"
talk "$T" ask acme/widget "$F"
asked "$T" acme/widget "$H3" >/dev/null
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/widget "$F" "" timeout
r="$(asked "$T" acme/widget "$H3")"
check "a picker closed by its own timeout takes nothing back from the record" "$([[ "$r" == "yes||" ]] && [ "$(kinds withdrawn)" = 0 ] && echo ok || echo "$r")"
asked "$T" acme/widget "$H3" >/dev/null
check "and is settled on the record, once" "$([ "$(kinds settled)" = 1 ] && echo ok || echo "$(kinds settled) lines")"
# A noted answer of Not yet, in a session the asker is not in, is read back from that session's
# transcript: the hash is the note's, taken when he answered, whatever the file holds now.
STORE_USED="$WORK/store-withdrawn-noted"
F="$(shown wn)"; T="$WORK/wn.jsonl"
talk "$T" ask acme/widget "$F"
asked "$T" acme/widget "$H3" >/dev/null
T2="$WORK/wn-two.jsonl"; new_talk "$T2"
talk "$T2" bash "$BBEDIT --front-window $F"
P="$(talk "$T2" put acme/widget "$F" "" s7)"
r="$(note "$T2" payload "$P" acme/widget "$F" "" "" s7)"
talk "$T2" answer "$P" acme/widget "$F" "Not yet" "" s7
printf '%s\n- Changed after his Not yet\n' "$POST" > "$F"
r="$(helper_asks acme/widget "$H3" 72)"
check "R2 a noted Not yet in another session takes the approval back for a merge naming no session" "$([[ "$r" == "no|unapproved|"*"took that approval back"* ]] && echo ok || echo "$r")"
check "by the hash noted when he answered" "$(grep '"kind": "withdrawn"' "$STORE_USED/record.jsonl" 2>/dev/null | grep "\"picker\": \"$P\"" | grep -q "\"hash\": \"$H3\"" && echo ok || cat "$STORE_USED/record.jsonl")"
helper_asks acme/widget "$H3" 72 >/dev/null
check "and that session's note is settled: it is not read back a second time" "$([ "$(kinds withdrawn)" = 1 ] && echo ok || echo "$(kinds withdrawn) lines")"

echo "the picker's question tells him to save the file before he answers (#3742 item 7)"
# An edit he makes in the window and does not save is not in the file, so it is not in the wording
# that is hashed. Nothing here can ask BBEdit whether the window holds unsaved changes, so the
# question he is shown must tell him to save, and one that does not approves nothing.
STORE_USED="$WORK/store-nosave"
F="$(shown nosave)"; T="$WORK/nosave.jsonl"
talk "$T" ask acme/widget "$F" "" nosave
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "R2 his Approve in a picker whose question does not tell him to save the file approves nothing" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
check "the refusal says what the question must say, in the words to use" "$([[ "$r" == *"did not tell him to save the file"* && "$r" == *"Save the file before you answer."* ]] && echo ok || echo "$r")"
check "and no approval is written for it" "$([ "$(recorded)" = 0 ] && echo ok || echo "$(recorded) lines")"
# Still possible: asked again with the sentence in the question.
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$(hash_file "$F")")"
check "R2 still possible: asked again with the sentence, his Approve counts" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
check "how to ask gives the sentence the question must hold" "$([[ "$how" == *"Save the file before you answer."* ]] && echo ok || echo "the how to ask text does not hold it: $how")"

echo "an Approve with words typed beside it approves nothing (#3742 low 20)"
# The picker lets him type words beside the option he chooses, and hands them back beside his answer
# (the fixture's `typed` shape says where). "approve, but fix line 2" used to count as his approval
# of the wording as it stood, and what he typed was read by nothing.
STORE_USED="$WORK/store-typed"
F="$(shown typed)"; T="$WORK/typed.jsonl"
HT="$(hash_file "$F")"
talk "$T" ask acme/widget "$F" "" "typed:approve, but fix line 2"
r="$(asked "$T" acme/widget "$HT")"
check "R2 his Approve with words typed beside it approves nothing" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
check "the refusal gives what he typed in his own words, says it approves nothing, and to fix the wording and ask again" "$([[ "$r" == *"approve, but fix line 2"* && "$r" == *"approves nothing"* && "$r" == *"fix the wording"* && "$r" == *"ask him again"* ]] && echo ok || echo "$r")"
check "and no approval is written for it" "$([ "$(recorded)" = 0 ] && echo ok || echo "$(recorded) lines")"
check "the record holds it as an answer of his that was no approval, naming the wording" "$(grep '"kind": "withdrawn"' "$STORE_USED/record.jsonl" 2>/dev/null | grep -q "\"hash\": \"$HT\"" && echo ok || cat "$STORE_USED/record.jsonl" 2>&1)"
T2="$WORK/typed-later.jsonl"; new_talk "$T2"
r="$(asked "$T2" acme/widget "$HT" s2)"
check "R2 a later session is refused on the record too" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
r="$(helper_asks acme/widget "$HT" 81)"
check "R2 and so is a merge that names no session" "$([[ "$r" == "no|unapproved|"* ]] && echo ok || echo "$r")"
# Still possible: the wording fixed and asked again, he approves and types nothing.
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$HT")"
check "R2 still possible: asked again, his Approve with nothing typed beside it counts" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
# He approved, and the approval is on the record. Asked again about the same unchanged file, he
# chooses Approve and types a change he wants: that is his last answer on the wording.
STORE_USED="$WORK/store-typed-back"
F="$(shown typed-back)"; T="$WORK/typed-back.jsonl"
talk "$T" ask acme/widget "$F"
r="$(asked "$T" acme/widget "$HT")"
check "his approval is recorded before he is asked again" "$([[ "$r" == "yes||" ]] && [ "$(recorded)" = 1 ] && echo ok || echo "$r")"
talk "$T" bash "$BBEDIT --front-window $F"
talk "$T" ask acme/widget "$F" "" "typed:the second line reads wrong"
r="$(asked "$T" acme/widget "$HT")"
check "R2 a later Approve with words typed beside it takes the recorded approval back" "$([[ "$r" == "no|"*"took that approval back"* ]] && echo ok || echo "$r")"
check "and the refusal still gives what he typed" "$([[ "$r" == *"the second line reads wrong"* ]] && echo ok || echo "$r")"
T2="$WORK/typed-back-later.jsonl"; new_talk "$T2"
r="$(asked "$T2" acme/widget "$HT" s2)"
check "R2 a later session is refused on the record alone" "$([[ "$r" == "no|"*"took that approval back"* ]] && echo ok || echo "$r")"
# A subagent's call is refused the same way, and writes nothing, as with his Not yet.
STORE_USED="$WORK/store-typed-agent"
F="$(shown typed-agent)"; T="$WORK/typed-agent.jsonl"
talk "$T" ask acme/widget "$F" "" "typed:approve, but fix line 2"
r="$(AGENT=1 asked "$T" acme/widget "$HT")"
check "R2 a subagent's call is refused on his Approve with words typed beside it" "$([[ "$r" == "no|"*"approve, but fix line 2"* ]] && echo ok || echo "$r")"
check "and writes nothing to the record" "$([ "$(kinds withdrawn)" = 0 ] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$(kinds withdrawn) withdrawn, $(kinds approved) approved")"
# His answer noted when he gave it, in a session the asker is not in, is read back from that
# session's transcript with what he typed beside it.
STORE_USED="$WORK/store-typed-noted"
F="$(shown typed-noted)"; T="$WORK/typed-noted.jsonl"
P="$(talk "$T" put acme/widget "$F")"
r="$(note "$T" payload "$P" acme/widget "$F")"
talk "$T" answer "$P" acme/widget "$F" "" "typed:approve, but fix line 2"
r="$(helper_asks acme/widget "$HT" 82)"
check "R2 a noted Approve with words typed beside it approves no merge that names no session" "$([[ "$r" == "no|unapproved|"* ]] && [ "$(kinds approved)" = 0 ] && echo ok || echo "$r")"
check "and that merge's refusal gives what he typed" "$([[ "$r" == *"approve, but fix line 2"* ]] && echo ok || echo "$r")"
# Still possible: what the dialog hands back beside an answer when he typed nothing. An annotation
# holding only the chosen option's preview is none of his words, and neither is one of white space.
STORE_USED="$WORK/store-typed-preview"
F="$(shown typed-preview)"; T="$WORK/typed-preview.jsonl"
talk "$T" ask acme/widget "$F" "" preview
r="$(asked "$T" acme/widget "$HT")"
check "R2 still possible: an annotation holding only the option's preview is no words of his, and his Approve counts" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
STORE_USED="$WORK/store-typed-blank"
F="$(shown typed-blank)"; T="$WORK/typed-blank.jsonl"
talk "$T" ask acme/widget "$F" "" "typed:   "
r="$(asked "$T" acme/widget "$HT")"
check "R2 still possible: white space typed beside his Approve is nothing typed, and it counts" "$([[ "$r" == "yes||" ]] && echo ok || echo "$r")"
# What came back beside his answer in a form nobody has seen is taken as words of his, never as
# nothing typed, and the refusal says it could not be read.
STORE_USED="$WORK/store-typed-form"
F="$(shown typed-form)"; T="$WORK/typed-form.jsonl"
talk "$T" ask acme/widget "$F" "" typedform
r="$(asked "$T" acme/widget "$HT")"
check "R2 words beside his Approve in a form that cannot be read approve nothing, and the refusal says so" "$([[ "$r" == "no|"*"could not be read"* ]] && [ "$(recorded)" = 0 ] && echo ok || echo "$r")"
# The same for something under a key that is neither his notes nor the option's preview: only those
# two keys are known, so any other one holding a value is a form nobody has seen (lessons review of
# claude-config#3742). It was read as nothing typed, since only the notes key was looked at.
STORE_USED="$WORK/store-typed-key"
F="$(shown typed-key)"; T="$WORK/typed-key.jsonl"
talk "$T" ask acme/widget "$F" "" typedkey
r="$(asked "$T" acme/widget "$HT")"
check "R2 something beside his Approve under a key nobody has seen approves nothing, and the refusal says so" "$([[ "$r" == "no|"*"could not be read"* ]] && [ "$(recorded)" = 0 ] && echo ok || echo "$r")"
# What he typed is given whole up to a length, and a longer run is cut and says so.
STORE_USED="$WORK/store-typed-long"
F="$(shown typed-long)"; T="$WORK/typed-long.jsonl"
talk "$T" ask acme/widget "$F" "" "typed:start of it $(printf 'word %.0s' $(seq 1 200)) the very end"
r="$(asked "$T" acme/widget "$HT")"
check "a long run of his words is cut in the refusal, which says where the rest is" "$([[ "$r" == "no|"*"start of it"*"cut here"* && "$r" != *"the very end"* ]] && echo ok || echo "$r")"
# An answer he typed in place of choosing an option was never an Approve, and stays as it was: it
# approves nothing, and the refusal does not call it an Approve of his.
STORE_USED="$WORK/store-typed-own"
F="$(shown typed-own)"; T="$WORK/typed-own.jsonl"
talk "$T" ask acme/widget "$F" "fix line 2 first"
r="$(asked "$T" acme/widget "$HT")"
check "words of his own in place of an option approve nothing, as before" "$([[ "$r" == "no|"* && "$r" != *"his Approve for"* ]] && echo ok || echo "$r")"

echo "whether a feature is announced to agents is Dan's own answer in a picker (#3669)"
# decided <transcript> <repo> <feature> [milestone] [session]: what a hook is told Dan last answered,
# as "<answer>|<said>|<why>|<notes>". AGENT=1 makes the call a subagent's.
decided() {
  python3 -c 'import json, os, sys
d = {"session_id": sys.argv[2], "transcript_path": sys.argv[1], "hook_event_name": "PreToolUse", "tool_name": "Bash"}
if os.environ.get("AGENT") == "1":
    d["agent_id"] = "a9bba4c0ffee"
print(json.dumps(d))' "$1" "${5:-s1}" \
    | ANNOUNCE_APPROVALS_DIR="${STORE_USED:-$STORE}" aaf_hook_decision "$LIB" "$2" "$3" "${4:-}" \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(d["answer"] + "|" + d["said"] + "|" + d["why"] + " " + d["how"] + "|" + " ".join(d["notes"]), end="")'
}
# on_record <repo> <feature>: the record's own answer, by the command line a session can run, as
# "<answer>|<said>|<day>|<why>". Its standard input is a payload naming $T, which it must not read.
on_record() {
  printf '{"session_id": "s1", "transcript_path": "%s"}' "$T" \
    | ANNOUNCE_APPROVALS_DIR="${STORE_USED:-$STORE}" python3 -B "$LIB" decision --repo "$1" --feature "$2" \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(d["answer"] + "|" + d["said"] + "|" + d["day"] + "|" + d["why"], end="")'
}
lines_of() { local n; n="$(grep -c "\"kind\": \"$1\"" "${STORE_USED:-$STORE}/record.jsonl" 2>/dev/null)"; printf '%s' "${n:-0}"; }
TODAY_ET="$(TZ=America/New_York date +%F)"

STORE_USED="$WORK/store-d-none"
T="$WORK/d-none.jsonl"; new_talk "$T"
r="$(decided "$T" acme/widget "Hand back")"
check "R9 a feature nobody asked Dan about has no answer of his" "$([[ "$r" == "none||"* ]] && echo ok || echo "$r")"
check "and the answer says how to ask him: one picker, its two options, the test and its metadata" "$([[ "$r" == *"AskUserQuestion"* && "$r" == *'`Announce it`'* && "$r" == *'`Not announcing`'* && "$r" == *"agents must or can act differently"* && "$r" == *'"source": "announce-discovery"'* ]] && echo ok || echo "$r")"

STORE_USED="$WORK/store-d-yes"
T="$WORK/d-yes.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back"
check "nothing is on the record until a hook asks" "$([[ "$(on_record acme/widget "Hand back")" == "none|"* ]] && echo ok || on_record acme/widget "Hand back")"
r="$(decided "$T" acme/widget "Hand back")"
check "his Announce it, in a picker naming the feature and stating the test, is a yes" "$([[ "$r" == "yes|Announce it|"* ]] && echo ok || echo "$r")"
check "and the hook that read it wrote it to the record" "$([ "$(lines_of decided)" = 1 ] && echo ok || echo "$(lines_of decided) lines")"
check "which the command line a session can run then reads, with the day he answered in ET" "$([[ "$(on_record acme/widget "Hand back")" == "yes|Announce it|$TODAY_ET|" ]] && echo ok || on_record acme/widget "Hand back")"
check "the feature is matched whatever its letter case and spacing" "$([[ "$(on_record ACME/Widget "hand  back")" == "yes|"* ]] && echo ok || on_record ACME/Widget "hand  back")"
check "another feature of that repository has no answer" "$([[ "$(on_record acme/widget "Hand over")" == "none|"* ]] && echo ok || on_record acme/widget "Hand over")"
check "and neither has that feature in another repository" "$([[ "$(on_record acme/other "Hand back")" == "none|"* ]] && echo ok || on_record acme/other "Hand back")"
r="$(decided "$T" acme/widget "Hand back")"
check "asked again, the same picker is one line on the record" "$([[ "$r" == "yes|"* && "$(lines_of decided)" = 1 ]] && echo ok || echo "$r $(lines_of decided) lines")"
# His last answer decides.
talk "$T" decide acme/widget "Hand back" "Not announcing"
r="$(decided "$T" acme/widget "Hand back")"
check "R9 his later Not announcing is a no: his last answer decides" "$([[ "$r" == "no|Not announcing|"* ]] && echo ok || echo "$r")"
talk "$T" decide acme/widget "Hand back" "Announce it"
check "and a yes after that is a yes again" "$([[ "$(decided "$T" acme/widget "Hand back")" == "yes|"* ]] && echo ok || decided "$T" acme/widget "Hand back")"

# The ways a picker is not his answer: nothing is decided, and the record-only command agrees.
for shape in timeout error prefilled two; do
  STORE_USED="$WORK/store-d-$shape"
  T="$WORK/d-$shape.jsonl"; new_talk "$T"
  talk "$T" decide acme/widget "Hand back" "Not announcing" "$shape"
  r="$(decided "$T" acme/widget "Hand back")"
  check "R9 a Not announcing that is not his answer ($shape) declines nothing" "$([[ "$r" == "none|"* && "$(on_record acme/widget "Hand back")" == "none|"* ]] && echo ok || echo "$r")"
done
# An earlier yes stands when a later picker was no answer of his.
STORE_USED="$WORK/store-d-stands"
T="$WORK/d-stands.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back"
talk "$T" decide acme/widget "Hand back" "Not announcing" timeout
check "R9 a picker closed by its own timeout takes no earlier yes back" "$([[ "$(decided "$T" acme/widget "Hand back")" == "yes|"* ]] && echo ok || decided "$T" acme/widget "Hand back")"
# An answer of his that is neither option alone decides nothing, and takes an earlier answer back.
STORE_USED="$WORK/store-d-typed"
T="$WORK/d-typed.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing"
talk "$T" decide acme/widget "Hand back" "Not announcing" "typed:but tell the managers"
r="$(decided "$T" acme/widget "Hand back")"
check "R9 a Not announcing with words typed beside it declines nothing" "$([[ "$r" == "none|"* && "$r" == *"typed words beside"* ]] && echo ok || echo "$r")"
check "and the record says his last answer decided nothing" "$([[ "$(on_record acme/widget "Hand back")" == "none|"*"decides nothing"* ]] && echo ok || on_record acme/widget "Hand back")"
check "and his words are not written to the record" "$(grep -q "tell the managers" "$STORE_USED/record.jsonl" && echo "his words are on the record" || echo ok)"
STORE_USED="$WORK/store-d-own"
T="$WORK/d-own.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "only the second half"
check "words of his own in place of an option decide nothing" "$([[ "$(decided "$T" acme/widget "Hand back")" == "none|"*"words of his own"* ]] && echo ok || decided "$T" acme/widget "Hand back")"
# What the question must hold: the feature the metadata names, and the test.
STORE_USED="$WORK/store-d-notest"
T="$WORK/d-notest.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" notest
r="$(decided "$T" acme/widget "Hand back")"
check "R9 a picker whose question does not state the test decides nothing, and the answer gives the words" "$([[ "$r" == "none|"* && "$r" == *"did not state the test"* && "$r" == *"agents must or can act differently"* ]] && echo ok || echo "$r")"
STORE_USED="$WORK/store-d-nofeature"
T="$WORK/d-nofeature.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" nofeature
r="$(decided "$T" acme/widget "Hand back")"
check "R9 a picker whose question does not name the feature its metadata names decides nothing" "$([[ "$r" == "none|"* && "$r" == *"did not name the feature"* ]] && echo ok || echo "$r")"
# The name must stand in the question as a name of its own: between quotation marks or with no
# letter or digit against either end. As a run of letters inside a longer name it named another
# feature, and his answer about that one was recorded about this one (review of #3669, low 8).
STORE_USED="$WORK/store-d-within"
T="$WORK/d-within.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand" "Not announcing" within
r="$(decided "$T" acme/widget "Hand")"
check "R9 #3669 F a question that holds the feature's name only inside a longer name decides nothing about it" "$([[ "$r" == "none|"* && "$r" == *"did not name the feature"* ]] && [ "$(grep -c '"answer": "other"' "$STORE_USED/record.jsonl" 2>/dev/null)" = 1 ] && echo ok || echo "$r")"
STORE_USED="$WORK/store-d-unquoted"
T="$WORK/d-unquoted.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" unquoted
check "still possible #3669 F: the name with no quotation marks, standing as words of its own, is the feature named" "$([[ "$(decided "$T" acme/widget "Hand back")" == "no|Not announcing|"* ]] && echo ok || decided "$T" acme/widget "Hand back")"
STORE_USED="$WORK/store-d-edges"
T="$WORK/d-edges.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back (v2)" "Announce it"
check "still possible #3669 F: a name that ends in a mark, between quotation marks, is the feature named" "$([[ "$(decided "$T" acme/widget "Hand back (v2)")" == "yes|Announce it|"* ]] && echo ok || decided "$T" acme/widget "Hand back (v2)")"
# And the question must have offered him both options: with two ways to decline, or one option
# swapped for another, his choice was not between announcing and not announcing.
STORE_USED="$WORK/store-d-twono"
T="$WORK/d-twono.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" twono
r="$(decided "$T" acme/widget "Hand back")"
check "R9 #3669 F a picker whose two options both decline is no decline of his, and the answer says both options must be offered" "$([[ "$r" == "none|"* && "$r" == *'did not offer both `Announce it` and `Not announcing`'* ]] && [ "$(grep -c '"answer": "other"' "$STORE_USED/record.jsonl" 2>/dev/null)" = 1 ] && echo ok || echo "$r")"
STORE_USED="$WORK/store-d-otherlabel"
T="$WORK/d-otherlabel.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Announce it" otherlabel
r="$(decided "$T" acme/widget "Hand back")"
check "R9 #3669 F nor is his Announce it a yes where the other option was not Not announcing" "$([[ "$r" == "none|"* && "$r" == *"did not offer both"* ]] && echo ok || echo "$r")"
STORE_USED="$WORK/store-d-unread"
T="$WORK/d-unread.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" unread
r="$(decided "$T" acme/widget "Hand back")"
check "R9 a picker he could not read as written decides nothing" "$([[ "$r" == "none|"* && "$r" == *"would not have reached him as written"* ]] && echo ok || echo "$r")"
STORE_USED="$WORK/store-d-nometa"
T="$WORK/d-nometa.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" nometa
r="$(decided "$T" acme/widget "Hand back")"
check "a picker whose metadata names no feature decides nothing, and the answer says so" "$([[ "$r" == "none|"* && "$r" == *"does not name"* ]] && echo ok || echo "$r")"

# A subagent's call counts his picker for that call and writes nothing.
STORE_USED="$WORK/store-d-agent"
T="$WORK/d-agent.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back"
r="$(AGENT=1 decided "$T" acme/widget "Hand back")"
check "a subagent's call counts his answer for that call" "$([[ "$r" == "yes|"* ]] && echo ok || echo "$r")"
check "and writes nothing to the record" "$([ "$(lines_of decided)" = 0 ] && echo ok || echo "$(lines_of decided) lines")"

# The command line a session can run reads the record only: a transcript handed to it is not read.
STORE_USED="$WORK/store-d-recordonly"
T="$WORK/d-recordonly.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back"
r="$(on_record acme/widget "Hand back")"
check "R9 the record-only command takes no answer from a transcript handed to it" "$([[ "$r" == "none|"* && ! -e "$STORE_USED/record.jsonl" ]] && echo ok || echo "$r")"
check "and says a hook reads his answer into the record" "$([[ "$r" == *"reads the record only"* ]] && echo ok || echo "$r")"

# This picker is noted as every picker is (#3789): by its ids alone, whatever the hook could tell of
# it, and read back from its session's transcript by a caller that names no session (the merge
# helper). The discovery picker has its own judge, and each judge leaves the other's pickers alone.
# helper_decides <repo> <feature> [milestone]: what a hook naming no session and no transcript is
# told Dan last answered, as "<answer>|<why>".
helper_decides() {
  printf '{"session_id": "merge-when-ready", "hook_event_name": "PreToolUse", "tool_name": "Bash"}' \
    | ANNOUNCE_APPROVALS_DIR="$STORE_USED" aaf_hook_decision "$LIB" "$1" "$2" "${3:-}" \
    | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["answer"] + "|" + d["why"], end="")'
}
# decided_as <picker> <answer>: whether the record holds one decided line for that picker with that answer.
decided_as() {
  local lines
  lines="$(grep '"kind": "decided"' "$STORE_USED/record.jsonl" 2>/dev/null | grep "\"picker\": \"$1\"")"
  [[ -n "$lines" && "$lines" != *$'\n'* && "$lines" == *"\"answer\": \"$2\""* ]]
}
# The picker's line is not in the transcript when its hook runs, and the hook's copy carries no
# metadata (the form measured on the installed hook, #3789).
STORE_USED="$WORK/store-d-noted"
T="$WORK/d-noted.jsonl"; new_talk "$T"
r="$(AAF_PAYLOAD_FORM=nometadata note "$T" decide-payload toolu_dlate1 acme/widget "Hand back" "Not announcing" "" "" "" 28)"
check "#3669 a discovery picker the transcript does not hold yet is noted by its ids alone, and nothing is said" "$([[ "$r" == "yes|" ]] && bare toolu_dlate1 false || echo "$r")"
check "a note is not his answer" "$([[ "$(on_record acme/widget "Hand back")" == "none|"* ]] && echo ok || on_record acme/widget "Hand back")"
r="$(helper_decides acme/widget "Hand back" 28)"
check "R9 #3669 a note by its ids alone declines nothing, and is not settled while the transcript does not hold its picker" "$([[ "$r" == "none|"* ]] && [ "$(kinds decided)" = 0 ] && [ "$(kinds settled)" = 0 ] && echo ok || echo "$r $(cat "$STORE_USED/record.jsonl")")"
talk "$T" decide-late toolu_dlate1 acme/widget "Hand back" "" "" 28
r="$(helper_decides acme/widget "Hand back" 28)"
check "R9 #3669 nor once the transcript holds the picker and not yet his answer" "$([[ "$r" == "none|"* ]] && [ "$(kinds decided)" = 0 ] && [ "$(kinds settled)" = 0 ] && echo ok || echo "$r")"
talk "$T" decide-answer toolu_dlate1 acme/widget "Hand back" "Not announcing" "" "" 28
r="$(helper_decides acme/widget "Hand back" 28)"
check "R9 still possible #3669: a call naming no session reads his Not announcing, in a picker noted by its ids alone, back from the session that asked" "$([[ "$r" == "no|"* ]] && echo ok || echo "$r")"
check "#3669 and the picker gets its decided line, once, as the session and the picker it came from" "$(decided_as toolu_dlate1 no && [[ "$(grep '"kind": "decided"' "$STORE_USED/record.jsonl")" == *'"session": "s1"'* ]] && echo ok || cat "$STORE_USED/record.jsonl" 2>&1)"
r="$(helper_decides acme/widget "Hand back" 28)"
check "#3669 asked again, his answer is read from the record and the picker is not judged twice" "$([[ "$r" == "no|"* ]] && [ "$(kinds decided)" = 1 ] && [ "$(kinds settled)" = 0 ] && echo ok || echo "$r $(kinds decided) decided, $(kinds settled) settled")"
# A picker the transcript already holds when its hook runs is noted the same way: nothing the hook
# can tell of a discovery picker is written beside its ids.
STORE_USED="$WORK/store-d-noted-held"
T="$WORK/d-noted-held.jsonl"; new_talk "$T"
id="$(talk "$T" decide-put acme/widget "Hand back")"
r="$(note "$T" decide-payload "$id" acme/widget "Hand back" "Announce it")"
check "#3669 a discovery picker the transcript holds is noted by its ids alone too: no feature, no source and no answer" "$([[ "$r" == "yes|" ]] && bare "$id" true || echo "$r")"
talk "$T" decide-answer "$id" acme/widget "Hand back" "Announce it"
check "R9 still possible #3669: and his Announce it is read back through that note" "$([[ "$(helper_decides acme/widget "Hand back")" == "yes|"* ]] && decided_as "$id" yes && echo ok || helper_decides acme/widget "Hand back")"
r="$(note "$T" decide-payload toolu_dagent acme/widget "Hand back" "Not announcing" "" "" a9bba4c0ffee)"
check "#3669 a subagent's discovery picker is not noted, and nothing is said" "$([[ "$r" == "no|" ]] && [ "$(kinds answered)" = 1 ] && echo ok || echo "$r $(kinds answered) notes")"

# TWO JUDGES, EACH LEAVING THE OTHER'S PICKERS. One session holds his approval of a wording and his
# answer about a feature, both noted by their ids alone. Whichever judge reads the session first
# gives its own picker its line and gives the other's nothing, so the other judge still finds it.
# two_judges <name>: that session, built; sets F, T and HTWO.
two_judges() {
  F="$(shown "$1")"; T="$WORK/$1.jsonl"
  HTWO="$(hash_file "$F")"
  AAF_PAYLOAD_FORM=nometadata note "$T" payload toolu_twoa acme/widget "$F" >/dev/null
  talk "$T" late toolu_twoa acme/widget "$F"
  talk "$T" answer toolu_twoa acme/widget "$F"
  AAF_PAYLOAD_FORM=nometadata note "$T" decide-payload toolu_twod acme/widget "Hand back" >/dev/null
  talk "$T" decide-late toolu_twod acme/widget "Hand back"
  talk "$T" decide-answer toolu_twod acme/widget "Hand back"
}
STORE_USED="$WORK/store-d-two-approval-first"
two_judges two-approval-first
r="$(helper_asks acme/widget "$HTWO" 80)"
check "R2 still possible #3669: his Approve beside a noted discovery picker is found by a merge naming no session" "$([[ "$r" == "yes|approved|" ]] && echo ok || echo "$r")"
check "#3669 the approval judge gives the discovery picker no line: it is not settled as no picker of a source this record reads" "$([ "$(kinds settled)" = 0 ] && [ "$(kinds decided)" = 0 ] && echo ok || cat "$STORE_USED/record.jsonl")"
r="$(helper_decides acme/widget "Hand back")"
check "R9 still possible #3669: so his Announce it is still read, by its own judge, after the approval judge read that session" "$([[ "$r" == "yes|"* ]] && decided_as toolu_twod yes && echo ok || echo "$r $(cat "$STORE_USED/record.jsonl")")"
check "#3669 and the approval it stood beside still stands" "$([[ "$(helper_asks acme/widget "$HTWO" 80)" == "yes|approved|" ]] && [ "$(kinds approved)" = 1 ] && [ "$(kinds settled)" = 0 ] && echo ok || helper_asks acme/widget "$HTWO" 80)"
STORE_USED="$WORK/store-d-two-discovery-first"
two_judges two-discovery-first
r="$(helper_decides acme/widget "Hand back")"
check "R9 still possible #3669: his Announce it beside a noted approval picker is read by a call naming no session" "$([[ "$r" == "yes|"* ]] && decided_as toolu_twod yes && echo ok || echo "$r")"
check "#3669 the discovery judge gives the approval picker no line: it is neither settled nor approved there" "$([ "$(kinds settled)" = 0 ] && [ "$(kinds approved)" = 0 ] && [ "$(kinds withdrawn)" = 0 ] && echo ok || cat "$STORE_USED/record.jsonl")"
r="$(helper_asks acme/widget "$HTWO" 81)"
check "R2 still possible #3669: so his Approve is still found, by its own judge, after the discovery judge read that session" "$([[ "$r" == "yes|approved|" ]] && [ "$(kinds approved)" = 1 ] && echo ok || echo "$r $(cat "$STORE_USED/record.jsonl")")"
# A session whose pickers both judges have given a line is read back by neither again.
for n in 1 2; do helper_decides acme/widget "Hand back" >/dev/null; helper_asks acme/widget "$HTWO" 81 >/dev/null; done
check "#3669 and once each picker has its line, neither judge writes another" "$([ "$(kinds approved)" = 1 ] && [ "$(kinds decided)" = 1 ] && [ "$(kinds settled)" = 0 ] && echo ok || cat "$STORE_USED/record.jsonl")"

# An ordinary picker the discovery judge reads is settled once, in the words the approval judge
# uses, and neither judge reads it back again.
STORE_USED="$WORK/store-d-ordinary"
F="$(shown d-ordinary)"; T="$WORK/d-ordinary.jsonl"
PO="$(talk "$T" put acme/widget "$F" plain)"
note "$T" payload "$PO" acme/widget "$F" "" plain >/dev/null
talk "$T" answer "$PO" acme/widget "$F" "Announce it" plain
r="$(helper_decides acme/widget "Hand back")"
check "R9 #3669 an ordinary picker answered with the option's words decides nothing" "$([[ "$r" == "none|"* ]] && [ "$(kinds decided)" = 0 ] && echo ok || echo "$r")"
check "#3669 and the discovery judge settles it as no picker of a source this record reads, naming both sources" "$(settled_as "$PO" 'no picker of a source this record reads (changelog-announce, announce-discovery)' && [ "$(kinds settled)" = 1 ] && echo ok || cat "$STORE_USED/record.jsonl" 2>&1)"
helper_decides acme/widget "Hand back" >/dev/null
helper_asks acme/widget "$(hash_file "$F")" 82 >/dev/null
check "#3669 it is settled once: neither judge settles it again" "$([ "$(kinds settled)" = 1 ] && echo ok || cat "$STORE_USED/record.jsonl")"

# A noted discovery picker that can never count is settled once it has been read and said, the way
# a noted approval picker that can never count is (#3789): left with no outcome, its session would
# be read back on every later call.
STORE_USED="$WORK/store-d-never"
T="$WORK/d-never.jsonl"; new_talk "$T"
PN="$(talk "$T" decide-put acme/widget "Hand over" prefilled)"
r="$(note "$T" decide-payload "$PN" acme/widget "Hand over" "Not announcing" prefilled)"
check "#3669 a discovery picker sent with its answer filled in is noted by its ids alone, as every picker is" "$([[ "$r" == "yes|" ]] && bare "$PN" true || echo "$r")"
talk "$T" decide-answer "$PN" acme/widget "Hand over" "Not announcing" prefilled
r="$(helper_decides acme/widget "Hand over")"
check "R9 #3669 a noted Not announcing the session filled in itself declines nothing, and the answer says why" "$([[ "$r" == "none|"*"never put to him"* ]] && [ "$(kinds decided)" = 0 ] && echo ok || echo "$r")"
check "#3669 and it is settled as never put to him" "$(settled_as "$PN" 'never put to him' && [ "$(kinds settled)" = 1 ] && echo ok || cat "$STORE_USED/record.jsonl" 2>&1)"
r="$(helper_decides acme/widget "Hand over")"
check "#3669 and is not read back or said again" "$([[ "$r" == "none|"* && "$r" != *"never put to him"* ]] && [ "$(kinds settled)" = 1 ] && echo ok || echo "$r")"
PN2="$(talk "$T" decide-put acme/widget "Hand over" nometa)"
note "$T" decide-payload "$PN2" acme/widget "Hand over" "Not announcing" nometa >/dev/null
talk "$T" decide-answer "$PN2" acme/widget "Hand over" "Not announcing" nometa
r="$(helper_decides acme/widget "Hand over")"
check "R9 #3669 a noted picker whose metadata names no feature declines nothing, and is settled once" "$([[ "$r" == "none|"* ]] && settled_as "$PN2" 'does not name the feature' && [ "$(kinds settled)" = 2 ] && [[ "$(helper_decides acme/widget "Hand over")" == "none|"* ]] && [ "$(kinds settled)" = 2 ] && echo ok || echo "$r $(cat "$STORE_USED/record.jsonl")")"

# A note by its ids alone whose session's transcript is gone is settled by the discovery judge too,
# since what its picker asked can never be read.
STORE_USED="$WORK/store-d-gone"
r="$(AAF_PAYLOAD_FORM=nometadata note "$WORK/no-such-d-talk.jsonl" decide-payload toolu_dgone acme/widget "Hand back")"
check "#3669 a discovery picker whose transcript cannot be read is noted by its ids alone, saying so" "$([[ "$r" == "yes|" ]] && bare toolu_dgone null || echo "$r")"
r="$(helper_decides acme/widget "Hand back")"
check "R9 #3669 it decides nothing, and is settled as one whose transcript is gone" "$([[ "$r" == "none|"* ]] && settled_as toolu_dgone 'transcript is gone' && echo ok || echo "$r $(cat "$STORE_USED/record.jsonl")")"
r="$(helper_decides acme/widget "Hand back")"
check "#3669 and is not looked for again" "$([[ "$r" == "none|"* && "$r" != *"could not be read back"* ]] && [ "$(kinds settled)" = 1 ] && echo ok || echo "$r")"

# The sessions the discovery judge reads back are the ones whose NEWEST unjudged note is newest, as
# for the approval judge (#3789): every picker is noted, so a session's first note is its first
# picker of any kind, long before the one about announcing.
STORE_USED="$WORK/store-d-order"
T="$WORK/d-order.jsonl"; new_talk "$T"
F="$(shown d-order-file)"
PO="$(talk "$T" put acme/widget "$F" plain)"
note "$T" payload "$PO" acme/widget "$F" "" plain >/dev/null
for n in 1 2 3 4 5 6; do
  aaf_new "$WORK/d-order-other-$n.jsonl"
  PX="$(talk "$WORK/d-order-other-$n.jsonl" put acme/widget "$F" plain "dother$n")"
  note "$WORK/d-order-other-$n.jsonl" payload "$PX" acme/widget "$F" "" plain "dother$n" >/dev/null
done
AAF_PAYLOAD_FORM=nometadata note "$T" decide-payload toolu_dorder acme/widget "Hand back" >/dev/null
talk "$T" decide-late toolu_dorder acme/widget "Hand back"
talk "$T" decide-answer toolu_dorder acme/widget "Hand back"
r="$(helper_decides acme/widget "Hand back")"
check "R9 still possible #3669: a session whose first note is older than six other sessions' is read back for its newest" "$([[ "$r" == "yes|"* ]] && decided_as toolu_dorder yes && echo ok || echo "$r")"

# A milestone's own question: only a picker naming that milestone's number answers it.
STORE_USED="$WORK/store-d-milestone"
T="$WORK/d-milestone.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing"
check "R9 a Not announcing that names no milestone does not answer the milestone's question" "$([[ "$(decided "$T" acme/widget "Hand back" 28)" == "none|"* ]] && echo ok || decided "$T" acme/widget "Hand back" 28)"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 29
check "R9 nor does one naming another milestone" "$([[ "$(decided "$T" acme/widget "Hand back" 28)" == "none|"* ]] && echo ok || decided "$T" acme/widget "Hand back" 28)"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
check "still possible: one naming that milestone does" "$([[ "$(decided "$T" acme/widget "Hand back" 28)" == "no|"* ]] && echo ok || decided "$T" acme/widget "Hand back" 28)"

echo "the line a milestone's description carries, written and read by one function (#3669)"
# milestone_line <store> <answer> <feature> [description] [title]: the helper's question, as "<ok>|<line>|<description>|<why>",
# on one line: each line break in it is written as the two characters \n, so a case that fails prints
# nothing at the margin (test-fail-margin.sh). The milestone's title is the feature's name unless a
# fifth argument gives another, and a fifth argument of one hyphen asks with no title at all.
milestone_line() {
  local d="$WORK/description.txt" title=(--title "${5-$3}"); printf '%s' "${4:-}" > "$d"
  [ "${5-}" != "-" ] || title=()
  ANNOUNCE_APPROVALS_DIR="$1" python3 -B "$LIB" milestone-line --repo acme/widget --feature "$3" ${title[@]+"${title[@]}"} --answer "$2" --description-file "$d" </dev/null \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
out = ("yes" if d["ok"] is True else "no") + "|" + d["line"] + "|" + d["description"] + "|" + d["why"] + (" " + d["how"] if d["how"] else "")
print(out.replace("\n", "\\n"), end="")'
}
YES_LINE="Announce to agents: yes (Dan answered \"Announce it\" on $TODAY_ET)"
NO_LINE="Announce to agents: no (Dan answered \"Not announcing\" on $TODAY_ET)"
r="$(milestone_line "$WORK/store-d-none" unasked "Hand back" "Rework the hand back.")"
check "unasked needs nothing and writes that he was not asked yet" "$([[ "$r" == 'yes|Announce to agents: not asked yet|Rework the hand back.\n\nAnnounce to agents: not asked yet|' ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-none" yes "Hand back" "")"
check "R9 a yes the record does not hold is refused, saying how to ask him" "$([[ "$r" == "no|||"*"holds no answer"*"AskUserQuestion"* ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-none" no "Hand back" "")"
check "R9 and so is a no the record does not hold" "$([[ "$r" == "no|||"*"holds no answer"* ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-yes" yes "Hand back" "Rework the hand back.")"
check "a yes the record holds is written quoting his answer and its date" "$([[ "$r" == "yes|$YES_LINE|Rework the hand back."'\n\n'"$YES_LINE|" ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-yes" no "Hand back" "")"
check "R9 a no where his last answer was Announce it is refused, quoting him" "$([[ "$r" == "no|||"*'`Announce it`'* ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-yes" unasked "Hand back" "")"
check "R9 unasked is refused where the record holds his answer about that feature" "$([[ "$r" == "no|||"*'"announce": "yes"'* ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-typed" no "Hand back" "")"
check "R9 a no where his last answer decided nothing is refused" "$([[ "$r" == "no|||"*"decides nothing"* ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-yes" yes "Hand back" $'Rework.\n\nAnnounce to agents: not asked yet\n\nMore.')"
check "the line replaces one the description already carries, where it stood" "$([[ "$r" == "yes|$YES_LINE|Rework."'\n\n'"$YES_LINE"'\n\nMore.|' ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-none" unasked "Hand over" "Rework."$'\n\n'"$NO_LINE")"
check "unasked never replaces an answer the description already carries" "$([[ "$r" == "yes|$NO_LINE|Rework."'\n\n'"$NO_LINE|" ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-none" maybe "Hand back" "")"
check "any other value is refused, naming the three" "$([[ "$r" == "no|||"*'"yes", "no" or "unasked"'* ]] && echo ok || echo "$r")"
# What could not be read is never an answer (#3669, the lessons review of d50de0862): with the
# record unreadable the helper used to be handed the line saying he was not asked yet, and filed a
# milestone carrying it, where the record may hold his yes. Every value is refused in the record's
# own unread words, with no line and no description for the helper to file.
mkdir -p "$WORK/store-d-junk/record.jsonl"
r="$(milestone_line "$WORK/store-d-junk" unasked "Hand back" "Rework the hand back.")"
check "R9 #3669 unread: unasked is refused while the record cannot be read, and no line says he was not asked yet" "$([[ "$r" == "no|||"*"store-d-junk/record.jsonl, could not be read (IsADirectoryError)"*'"Hand back" in acme/widget'* && "$r" != *"not asked yet"* ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-junk" unasked "Hand over" "Rework."$'\n\n'"$NO_LINE")"
check "R9 #3669 unread: nor is an answer the description already carries handed back as one the record was asked about" "$([[ "$r" == "no|||"*"could not be read (IsADirectoryError)"* ]] && echo ok || echo "$r")"
for value in yes no; do
  r="$(milestone_line "$WORK/store-d-junk" "$value" "Hand back" "")"
  check "R9 #3669 unread: a $value is refused in the same words, never as a record that holds no answer" "$([[ "$r" == "no|||"*"could not be read (IsADirectoryError)"* && "$r" != *"holds no answer"* ]] && echo ok || echo "$r")"
done
r="$(milestone_line "$WORK/store-d-junk" maybe "Hand back" "")"
check "#3669 unread: a value that is none of the three is still refused as that, with no record read" "$([[ "$r" == "no|||"*'"yes", "no" or "unasked"'* && "$r" != *"could not be read"* ]] && echo ok || echo "$r")"
# One name only (Dan, by picker, 2026-11-26: "One name only (Recommended)"; second review of #3669,
# high 2 and medium 3). His answer about a feature counts for a milestone only when the picker named
# the feature exactly as the milestone is titled, letter case and spacing aside. The helper used to
# take a second name from the plan (announce_feature) and write his answer about THAT name onto the
# milestone, while the merge gate looks his answers up by the title: so his yes under the picker's
# name was lost with the line (N1a), and an old decline naming the milestone outlived a newer yes
# under the picker's name (N1b). The library now takes the milestone's title and writes no line for
# a feature that is not the title, so neither can be set up through it.
ONE_NAME='is not an answer about the milestone "Hand back"; ask him again, naming the feature as the milestone is titled'
STORE_USED="$WORK/store-i-rework"
T="$WORK/i-rework.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back rework" "Announce it"
check "#3669 I (the fixture) his Announce it about the picker's own name is on the record" "$([[ "$(decided "$T" acme/widget "Hand back rework")" == "yes|Announce it|"* ]] && echo ok || echo no)"
r="$(milestone_line "$STORE_USED" yes "Hand back rework" "The plan." "Hand back")"
check "R9 #3669 I N1a: his yes about another name than the milestone's title writes no line onto that milestone" "$([[ "$r" == "no|||"*'his answer about "Hand back rework" '"$ONE_NAME"* ]] && echo ok || echo "$r")"
check "R9 #3669 I and the refusal says how to ask him, naming the feature as the milestone is titled" "$([[ "$r" == *"AskUserQuestion"*'"feature": "Hand back"'* && "$r" != *'"feature": "Hand back rework"'* ]] && echo ok || echo "$r")"
STORE_USED="$WORK/store-i-phase"
T="$WORK/i-phase.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
talk "$T" decide acme/widget "Hand back phase two" "Announce it"
check "#3669 I (the fixture) his newer Announce it about the picker's own name is on the record" "$([[ "$(decided "$T" acme/widget "Hand back phase two")" == "yes|Announce it|"* ]] && echo ok || echo no)"
r="$(milestone_line "$STORE_USED" yes "Hand back phase two" "The plan." "Hand back")"
check "R9 #3669 I N1b: a newer yes about another name writes no yes onto a milestone his decline names" "$([[ "$r" == "no|||"*'his answer about "Hand back phase two" '"$ONE_NAME"* ]] && echo ok || echo "$r")"
r="$(milestone_line "$STORE_USED" unasked "Hand back phase two" "The plan." "Hand back")"
check "R9 #3669 I unasked is refused the same way for a feature that is not the title" "$([[ "$r" == "no|||"*"$ONE_NAME"* && "$r" != *"not asked yet"* ]] && echo ok || echo "$r")"
r="$(milestone_line "$STORE_USED" no "Hand back phase two" "The plan." "Hand back")"
check "R9 #3669 I and so is a no" "$([[ "$r" == "no|||"*"$ONE_NAME"* ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-yes" yes "Hand back" "The plan." "-")"
check "R9 #3669 I a question that gives no title is refused, saying the title is what his answer is looked up by" "$([[ "$r" == "no|||"*"names no milestone title"* ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-yes" yes "Hand back" "The plan." "   ")"
check "R9 #3669 I and so is a title of nothing but spaces" "$([[ "$r" == "no|||"*"names no milestone title"* ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-yes" yes "hand   BACK" "The plan." "Hand back")"
check "still possible #3669 I: the title in another letter case and spacing is the same name, and his yes is written" "$([[ "$r" == "yes|$YES_LINE|The plan."'\n\n'"$YES_LINE|" ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-yes" yes "Hand back" "The plan." "Hand back")"
check "still possible #3669 I: his yes about the milestone's own title is written, as before" "$([[ "$r" == "yes|$YES_LINE|The plan."'\n\n'"$YES_LINE|" ]] && echo ok || echo "$r")"
r="$(milestone_line "$WORK/store-d-yes" maybe "Hand back phase two" "" "Hand back")"
check "#3669 I a value that is none of the three is still refused as that, whatever the two names are" "$([[ "$r" == "no|||"*'"yes", "no" or "unasked"'* && "$r" != *"is not an answer about"* ]] && echo ok || echo "$r")"
# The helper writes the description it is handed back into the milestone, so one read short or not
# at all is refused in its own words, never cut or taken as empty. The library reads 2097152 bytes
# (WORDING_BYTES * 8) of a file at most.
# line_for_file <file>: the helper's question about the description in that file, as
# "<ok>|<how long the description handed back is>|<why>".
line_for_file() {
  ANNOUNCE_APPROVALS_DIR="$WORK/store-d-none" python3 -B "$LIB" milestone-line --repo acme/widget --feature "Hand back" --title "Hand back" --answer unasked --description-file "$1" </dev/null \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(("yes" if d["ok"] is True else "no") + "|" + str(len(d["description"])) + "|" + d["why"], end="")'
}
head -c 2097152 /dev/zero | tr '\0' 'a' > "$WORK/description-whole.txt"
head -c 2097153 /dev/zero | tr '\0' 'a' > "$WORK/description-long.txt"
r="$(line_for_file "$WORK/description-whole.txt")"
check "a description as long as the library reads is taken whole, with the line after it" "$([[ "$r" == "yes|2097187|" ]] && echo ok || echo "${r:0:300}")"
r="$(line_for_file "$WORK/description-long.txt")"
check "one a byte longer is refused, never cut and handed back short" "$([[ "$r" == "no|0|"*"larger than 2048 KB"* ]] && echo ok || echo "${r:0:300}")"
r="$(line_for_file "$WORK/no-such-description.txt")"
check "a description file that cannot be opened is refused, never taken as an empty description" "$([[ "$r" == "no|0|"*"could not be opened"* ]] && echo ok || echo "${r:0:300}")"

echo "the pull request that finishes a feature Dan said yes to announcing (#3669)"
# finishes <store> <GitHub's answer> [transcript]: the merge gate's question about pull request 7, as
# "<state>|<why> <how>". With a transcript it is asked as a hook asks, in session s1. UNMERGED is the
# pull requests the gate names when it asks again, GitHub having said they have not merged.
finishes() {
  local a="$WORK/answer.json"; printf '%s' "$2" > "$a"
  if [ -n "${3:-}" ]; then
    printf '{"session_id": "s1", "transcript_path": "%s"}' "$3" | ANNOUNCE_APPROVALS_DIR="$1" python3 -B "$LIB" finishes --repo acme/widget --pr 7 --answer-file "$a" --hook ${UNMERGED:+--unmerged "$UNMERGED"} ${SPENT:+--spent "$SPENT"}
  else
    ANNOUNCE_APPROVALS_DIR="$1" python3 -B "$LIB" finishes --repo acme/widget --pr 7 --answer-file "$a" ${UNMERGED:+--unmerged "$UNMERGED"} </dev/null
  fi | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(d["state"] + "|" + d["why"] + " " + d["how"], end="")'
}
# closing <description> <open issues> <closed by this pull request>: GitHub's answer for a pull request
# closing those issues of milestone 28, "Hand back", which has those issues open.
closing() {
  python3 -c 'import json, sys
desc, still, closes = sys.argv[1], [int(n) for n in sys.argv[2].split()], [int(n) for n in sys.argv[3].split()]
m = {"number": 28, "title": "Hand back", "description": desc, "issues": {"totalCount": len(still), "nodes": [{"number": n} for n in still]}}
nodes = [{"number": n, "repository": {"nameWithOwner": "acme/widget"}, "milestone": m} for n in closes]
print(json.dumps({"data": {"repository": {"pullRequest": {"closingIssuesReferences": {"totalCount": len(nodes), "nodes": nodes}}}}}), end="")' "$@"
}
SAYS_YES="Rework the hand back.

Announce to agents: yes (Dan answered \"Announce it\" on 2026-11-20)"
EMPTY="$WORK/store-f-empty"
r="$(finishes "$EMPTY" "$(closing "$SAYS_YES" "12" "12")")"
check "R9 a pull request closing the last open issue of a milestone that says yes is owed an announcement" "$([[ "$r" == "owed|"* ]] && echo ok || echo "$r")"
check "the refusal names the milestone and both ways on: the label with approved wording, or his answer in a picker" "$([[ "$r" == *'"Hand back"'* && "$r" == *"changelog/announce"* && "$r" == *'`Not announcing`'* && "$r" == *'"milestone": 28'* && "$r" == *'"feature": "Hand back"'* ]] && echo ok || echo "$r")"
check "still possible: one that leaves an issue of it open is not" "$([[ "$(finishes "$EMPTY" "$(closing "$SAYS_YES" "12 13" "12")")" == "clear|"* ]] && echo ok || echo no)"
check "still possible: one that closes nothing is not" "$([[ "$(finishes "$EMPTY" "$(closing "$SAYS_YES" "12" "")")" == "clear|"* ]] && echo ok || echo no)"
check "R9 one closing the two last open issues is" "$([[ "$(finishes "$EMPTY" "$(closing "$SAYS_YES" "12 13" "13 12")")" == "owed|"* ]] && echo ok || echo no)"
check "R9 one closing an issue of a milestone with none left open is" "$([[ "$(finishes "$EMPTY" "$(closing "$SAYS_YES" "" "12")")" == "owed|"* ]] && echo ok || echo no)"
for said in "Rework.

Announce to agents: no (Dan answered \"Not announcing\" on 2026-11-20)" "Rework.

Announce to agents: not asked yet" "Rework the hand back." ""; do
  check "still possible: a milestone that does not say yes finishes under any label [${said##*$'\n'}]" "$([[ "$(finishes "$EMPTY" "$(closing "$said" "12" "12")")" == "clear|"* ]] && echo ok || echo no)"
done
# An announcement the gate let through for that milestone.
ANNOUNCED="$WORK/store-f-announced"; mkdir -p "$ANNOUNCED"
printf '{"kind": "used", "repo": "acme/widget", "hash": "%064d", "pr": 5, "closes": [{"issue": 11, "repo": "acme/widget", "milestone": "Hand back", "milestone_number": 28}], "at": "2026-11-21T00:00:00Z"}\n' 0 > "$ANNOUNCED/record.jsonl"
check "still possible: once an announcement merged for that milestone, its last issue closes under any label" "$([[ "$(finishes "$ANNOUNCED" "$(closing "$SAYS_YES" "12" "12")")" == "clear|"* ]] && echo ok || echo no)"
OTHERM="$WORK/store-f-otherm"; mkdir -p "$OTHERM"
printf '{"kind": "used", "repo": "acme/widget", "hash": "%064d", "pr": 5, "closes": [{"issue": 11, "repo": "acme/widget", "milestone": "Hand over", "milestone_number": 29}], "at": "2026-11-21T00:00:00Z"}\n' 0 > "$OTHERM/record.jsonl"
check "R9 an announcement merged for another milestone does not cover this one" "$([[ "$(finishes "$OTHERM" "$(closing "$SAYS_YES" "12" "12")")" == "owed|"* ]] && echo ok || echo no)"
# A `used` line says the gate let a pull request through, never that GitHub merged it. The gate asks
# GitHub, and asks this again naming the ones that have not merged: their lines cover nothing.
r="$(UNMERGED=5 finishes "$ANNOUNCED" "$(closing "$SAYS_YES" "12" "12")")"
check "R9 an announcement let through that GitHub says has not merged covers nothing" "$([[ "$r" == "owed|"* ]] && echo ok || echo "$r")"
check "R9 and the refusal names that pull request and says it did not merge as an announcement, which is true of one that merged without the label too" "$([[ "$r" == *"holds pull request 5 as let through"*"GitHub says it did not merge as an announcement (it has not merged, or it merged without the changelog/announce label)"* ]] && echo ok || echo "$r")"
check "still possible: naming a pull request the record does not hold for that milestone takes nothing away" "$([[ "$(UNMERGED=6 finishes "$ANNOUNCED" "$(closing "$SAYS_YES" "12" "12")")" == "clear|"* ]] && echo ok || echo no)"
check "R9 what is no number among them is passed over, and the number beside it still counts" "$([[ "$(UNMERGED=x,5 finishes "$ANNOUNCED" "$(closing "$SAYS_YES" "12" "12")")" == "owed|"* ]] && echo ok || echo no)"
TWICE="$WORK/store-f-twice"; mkdir -p "$TWICE"
printf '{"kind": "used", "repo": "acme/widget", "hash": "%064d", "pr": 5, "closes": [{"issue": 11, "repo": "acme/widget", "milestone": "Hand back", "milestone_number": 28}], "at": "2026-11-21T00:00:00Z"}\n{"kind": "used", "repo": "acme/widget", "hash": "%064d", "pr": 6, "closes": [{"issue": 10, "repo": "acme/widget", "milestone": "Hand back", "milestone_number": 28}], "at": "2026-11-22T00:00:00Z"}\n' 0 1 > "$TWICE/record.jsonl"
check "still possible: of two let through, one that merged covers the milestone" "$([[ "$(UNMERGED=5 finishes "$TWICE" "$(closing "$SAYS_YES" "12" "12")")" == "clear|"* ]] && echo ok || echo no)"
r="$(UNMERGED=5,6 finishes "$TWICE" "$(closing "$SAYS_YES" "12" "12")")"
check "R9 two let through and neither merged covers nothing, and the refusal names both" "$([[ "$r" == "owed|"*"pull requests 5 and 6 as let through"*"GitHub says none of them merged as an announcement (each has not merged, or merged without the changelog/announce label), so nothing was announced"* ]] && echo ok || echo "$r")"
# His answer at the merge: only a Not announcing naming this milestone clears it.
check "still possible: his Not announcing, naming the milestone, lets it finish under any label" "$([[ "$(finishes "$WORK/store-d-milestone" "$(closing "$SAYS_YES" "12" "12")")" == "clear|"* ]] && echo ok || echo no)"
check "R9 a Not announcing that names no milestone does not" "$([[ "$(finishes "$WORK/store-d-typed" "$(closing "$SAYS_YES" "12" "12")")" == "owed|"* ]] && echo ok || echo no)"
STORE_USED="$WORK/store-f-still"
T="$WORK/f-still.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
talk "$T" decide acme/widget "Hand back" "Announce it" "" "" 28
r="$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")" "$T")"
check "R9 his later Announce it takes the decline back, and the refusal says what he answered" "$([[ "$r" == "owed|"*'`Announce it`'* ]] && echo ok || echo "$r")"
STORE_USED="$WORK/store-f-hook"
T="$WORK/f-hook.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
check "the record-only question does not read his picker" "$([[ "$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")")" == "owed|"* ]] && echo ok || echo no)"
check "still possible: asked as a hook asks, his Not announcing in this session clears it" "$([[ "$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")" "$T")" == "clear|"* ]] && echo ok || echo no)"
# His decline naming the milestone clears it only while it is also his LAST answer about that feature
# in any picker (review of #3669, high 1). A picker at feature discovery names no milestone, so a
# newer Announce it there never took the decline back, and the decline cleared every later merge
# finishing that milestone.
STORE_USED="$WORK/store-f-newer"
T="$WORK/f-newer.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
talk "$T" decide acme/widget "Hand back" "Announce it"
r="$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")" "$T")"
check "R9 #3669 A his newer Announce it in a picker naming no milestone takes the decline back: owed" "$([[ "$r" == "owed|"* ]] && echo ok || echo "$r")"
check "R9 #3669 A and the refusal says his decline is not his last answer about it, and what he answered after it" "$([[ "$r" == *'his `Not announcing` in a picker naming that milestone is not his last answer about announcing it: after it he answered `Announce it`'* && "$r" != *"no answer of his declining it"* ]] && echo ok || echo "$r")"
check "R9 #3669 A the question that reads the record only gives the same answer once both are on the record" "$([[ "$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")")" == "owed|"*"is not his last answer about announcing it"* ]] && echo ok || echo no)"
STORE_USED="$WORK/store-f-newer-words"
T="$WORK/f-newer-words.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
talk "$T" decide acme/widget "Hand back" "Announce it" "typed:only for the new agents"
r="$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")" "$T")"
check "R9 #3669 A a newer answer about it that decides nothing takes the decline back too: owed, saying it decides nothing" "$([[ "$r" == "owed|"*"is not his last answer about announcing it: his last answer about it decides nothing"* ]] && echo ok || echo "$r")"
STORE_USED="$WORK/store-f-newer-no"
T="$WORK/f-newer-no.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
talk "$T" decide acme/widget "Hand back" "Not announcing"
r="$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")" "$T")"
check "R9 #3669 A a newer Not announcing naming no milestone is his last answer and clears no merge: owed, saying so" "$([[ "$r" == "owed|"*'after it he answered `Not announcing`'*"in a picker that does not name this milestone"* ]] && echo ok || echo "$r")"
STORE_USED="$WORK/store-f-older"
T="$WORK/f-older.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Announce it"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
check "still possible #3669 A: his Announce it at discovery and then his Not announcing naming the milestone clears it" "$([[ "$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")" "$T")" == "clear|"* ]] && echo ok || echo no)"
STORE_USED="$WORK/store-f-newer-other"
T="$WORK/f-newer-other.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
talk "$T" decide acme/widget "Hand over" "Announce it"
check "still possible #3669 A: a newer Announce it about another feature leaves his decline standing" "$([[ "$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")" "$T")" == "clear|"* ]] && echo ok || echo no)"
# One name only (#3669 I, above): his yes about another name than the milestone's title was never
# written onto the milestone, so the gate, which looks his answers up by the title, has nothing to
# lose: the milestone is exactly as his decline naming it left it.
check "still possible #3669 I: a milestone his decline names stays cleared beside his newer yes about another name, no line saying yes" "$([[ "$(finishes "$WORK/store-i-phase" "$(closing "The plan." "12" "12")")" == "clear|"* ]] && echo ok || echo no)"
# An announcement let through covers a milestone only when it was let through AFTER his last yes
# about the milestone's title (second review of #3669, high 1). A milestone is reused for a
# feature's next phase, discovery asks again, and his newer Announce it is owed an announcement of
# its own: the one let through for the phase before it is older than that yes and covers nothing.
# With no yes of his on the record at all, a line let through covers as it always did.
STORE_USED="$WORK/store-h-older"; mkdir -p "$STORE_USED"
printf '{"kind": "used", "repo": "acme/widget", "hash": "%064d", "pr": 5, "closes": [{"issue": 11, "repo": "acme/widget", "milestone": "Hand back", "milestone_number": 28}], "at": "2026-11-21T00:00:00Z"}\n' 0 > "$STORE_USED/record.jsonl"
check "still possible #3669 H: with no yes of his on the record, an announcement let through covers the milestone whose line says yes" "$([[ "$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")")" == "clear|"* ]] && echo ok || echo no)"
T="$WORK/h-older.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Announce it"
r="$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")" "$T")"
check "R9 #3669 H an announcement let through before his newest Announce it covers nothing: owed" "$([[ "$r" == "owed|"* ]] && echo ok || echo "$r")"
check "R9 #3669 H and the refusal names that pull request and says its announcement is older than his last yes, with the day of each" "$([[ "$r" == *"holds pull request 5 as let through with an announcement for that milestone on 2026-11-20, which is older than his last "'`Announce it`'" about announcing it, of $TODAY_ET"* && "$r" != *"holds no announcement let through"* && "$r" != *"GitHub says"* ]] && echo ok || echo "$r")"
check "R9 #3669 H the question that reads the record only gives the same answer once his yes is on it" "$([[ "$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")")" == "owed|"*"which is older than his last"* ]] && echo ok || echo no)"
check "R9 #3669 H and so it does with the milestone's line removed, the yes being the record's" "$([[ "$(finishes "$STORE_USED" "$(closing "Rework the hand back." "12" "12")")" == "owed|"*"whose description does not say"*"which is older than his last"* ]] && echo ok || echo no)"
# The same yes, and then an announcement let through after it: that one covers the milestone. The
# library stamps a line let through in whole seconds, so the case waits one out.
sleep 1
used --repo acme/widget --hash "$(printf '%064d' 1)" --pr 6 --closes '[{"issue": 10, "repo": "acme/widget", "milestone": "Hand back", "milestone_number": 28}]' >/dev/null
check "still possible #3669 H: an announcement let through after his last Announce it covers the milestone" "$([[ "$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")")" == "clear|"* ]] && echo ok || echo no)"
r="$(UNMERGED=6 finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")")"
check "R9 #3669 H when GitHub says the newer one did not merge as an announcement, the older one still covers nothing, and the refusal says both" "$([[ "$r" == "owed|"*"holds pull request 5 as let through with an announcement for that milestone on 2026-11-20, which is older than his last"*"It also holds pull request 6 as let through with an announcement for that milestone, and GitHub says it did not merge as an announcement"* ]] && echo ok || echo "$r")"
check "still possible #3669 H: naming the older one as not merged takes nothing from the newer one" "$([[ "$(UNMERGED=5 finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")")" == "clear|"* ]] && echo ok || echo no)"
# A later answer of his that is no yes does not make the announcement older than a yes: his last yes
# is still the one it was let through after.
talk "$T" decide acme/widget "Hand back" "Not announcing"
check "still possible #3669 H: a later answer that is no yes leaves an announcement let through after his last yes covering it" "$([[ "$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")" "$T")" == "clear|"* ]] && echo ok || echo no)"
# A line let through that does not say when is not known to be after his yes, so it covers nothing.
STORE_USED="$WORK/store-h-undated"; mkdir -p "$STORE_USED"
printf '{"kind": "used", "repo": "acme/widget", "hash": "%064d", "pr": 5, "closes": [{"issue": 11, "repo": "acme/widget", "milestone": "Hand back", "milestone_number": 28}]}\n' 0 > "$STORE_USED/record.jsonl"
check "still possible #3669 H: with no yes on the record, a line let through that does not say when covers as before" "$([[ "$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")")" == "clear|"* ]] && echo ok || echo no)"
T="$WORK/h-undated.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Announce it"
r="$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")" "$T")"
check "R9 #3669 H a line let through that does not say when is not known to be after his yes, and covers nothing" "$([[ "$r" == "owed|"*"holds pull request 5 as let through with an announcement for that milestone, which does not say when, so it is not known to be newer than his last "'`Announce it`'* ]] && echo ok || echo "$r")"
# The milestone's line is text on GitHub that any command or a hand in its page can drop or alter,
# and the helper writes it from his answer about whatever feature the plan names. The record is the
# guarded store. So a milestone says yes when its line does OR the record holds yes as his last
# yes or no about its title, whatever the line says (review of #3669, medium 4 and 5).
SAYS_NO="Rework the hand back.

Announce to agents: no (Dan answered \"Not announcing\" on 2026-11-20)"
STORE_USED="$WORK/store-f-record-yes"
T="$WORK/f-record-yes.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Old thing" "Not announcing"
talk "$T" decide acme/widget "Hand back" "Announce it"
r="$(finishes "$STORE_USED" "$(closing "Rework the hand back." "12" "12")" "$T")"
check "R9 #3669 C a milestone whose line was removed is owed when his last answer about its title is yes, read by the hook that asks" "$([[ "$r" == "owed|"* ]] && echo ok || echo "$r")"
check "R9 #3669 C and the refusal says the yes is the record's and that the description does not say so" "$([[ "$r" == *"whose description does not say Dan said yes to announcing it to agents, while this Mac's record holds his "'`Announce it`'*"as his last yes or no about announcing it"* && "$r" != *"whose description says Dan said yes"* ]] && echo ok || echo "$r")"
r="$(finishes "$STORE_USED" "$(closing "Rework the hand back." "12" "12")")"
check "R9 #3669 C the same of the record alone, once his answer is on it" "$([[ "$r" == "owed|"*"whose description does not say"* ]] && echo ok || echo "$r")"
r="$(finishes "$STORE_USED" "$(closing "$SAYS_NO" "12" "12")")"
check "R9 #3669 C a line saying no, written from his decline about another feature, does not hide the record's yes about this one" "$([[ "$r" == "owed|"*"whose description does not say"* ]] && echo ok || echo "$r")"
r="$(finishes "$STORE_USED" "$(closing "Rework.

Announce to agents: not asked yet" "12" "12")")"
check "R9 #3669 C nor does a line saying he was not asked" "$([[ "$r" == "owed|"* ]] && echo ok || echo "$r")"
check "still possible #3669 C: a milestone of another title, whose line does not say yes, finishes under any label beside that record" "$([[ "$(finishes "$STORE_USED" "$(closing "$SAYS_NO" "12" "12" | sed 's/Hand back/Old thing/')")" == "clear|"* ]] && echo ok || echo no)"
check "R9 #3669 C a line saying yes with nothing on the record is owed, as before" "$([[ "$(finishes "$EMPTY" "$(closing "$SAYS_YES" "12" "12")")" == "owed|"*"whose description says Dan said yes"* ]] && echo ok || echo no)"
# His decline naming the milestone, after that yes, is his last answer about it: clear, line or no line.
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
check "still possible #3669 C: his later Not announcing naming the milestone clears it, whatever the line says" "$([[ "$(finishes "$STORE_USED" "$(closing "Rework the hand back." "12" "12")" "$T")" == "clear|"* && "$(finishes "$STORE_USED" "$(closing "$SAYS_YES" "12" "12")")" == "clear|"* ]] && echo ok || echo no)"
# An answer after his yes that decides nothing does not take the yes off the record.
STORE_USED="$WORK/store-f-record-yes-words"
T="$WORK/f-record-yes-words.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Announce it"
talk "$T" decide acme/widget "Hand back" "Not announcing" "typed:maybe, ask me later"
r="$(finishes "$STORE_USED" "$(closing "Rework the hand back." "12" "12")" "$T")"
check "R9 #3669 C a later answer that decides nothing leaves his yes standing: owed with the line removed" "$([[ "$r" == "owed|"* ]] && echo ok || echo "$r")"
# A record that cannot be read cannot say he gave no yes, so a finishing merge is unread whatever the line says.
mkdir -p "$WORK/store-f-junk-c/record.jsonl"
check "R9 #3669 C with the record unreadable, a milestone whose line does not say yes is unread, never clear" "$([[ "$(finishes "$WORK/store-f-junk-c" "$(closing "Rework the hand back." "12" "12")")" == "unread|"* ]] && echo ok || echo no)"
# A decline clears the merge only when the call that leans on it read every noted session (decided by
# the main session on the stricter side, 2026-11-26). A newer Announce it of his, in a session the
# call left unread, would be his last answer, so a decline with sessions left unread is unread,
# never clear. An announcement let through for the milestone does not depend on his last answer, and
# clears as before.
# finishes_short <store> <GitHub's answer> <transcript> [sessions one call reads back] [late]: the same
# question asked as a hook asks in session s1, in process, with that many sessions read back in place
# of the library's own number, and with `late` the call's time already run out when the first noted
# session comes up: "<state>|<the pull requests given back as announced>|<why> <how>". NO_NODE=1 has
# the call find no node, so the check of whether he could read a picker cannot run.
finishes_short() {
  ANNOUNCE_APPROVALS_DIR="$1" python3 -B -c 'import importlib.util, json, os, shutil, sys, time
spec = importlib.util.spec_from_file_location("announce_approval", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
if os.environ.get("NO_NODE") == "1":
    # The check of whether he could read a picker runs under node: with none found it cannot run.
    shutil.which = lambda *a, **k: None
if sys.argv[4]:
    lib.NOTED_SESSIONS = int(sys.argv[4])
if sys.argv[5] == "late":
    lib._clock = lambda: time.monotonic() + 10 ** 6
d = lib.finishes("acme/widget", 7, json.loads(sys.argv[2]), {"session_id": "s1", "transcript_path": sys.argv[3]},
                 [int(n) for n in sys.argv[6].split(",") if n])
print(d["state"] + "|" + ",".join(str(n) for n in d["announced"]) + "|" + d["why"] + " " + d["how"], end="")' "$LIB" "$2" "$3" "${4:-}" "${5:-}" "${UNMERGED:-}"
}
STORE_USED="$WORK/store-f-behind"
T="$WORK/f-behind.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
# Two other sessions each hold a noted picker nothing can judge (put and not answered), so each is
# read back on every call and neither is ever settled.
F="$(shown behind)"
for n in 1 2; do
  aaf_new "$WORK/f-behind-other-$n.jsonl"
  PX="$(talk "$WORK/f-behind-other-$n.jsonl" put acme/widget "$F" "" "behind$n")"
  note "$WORK/f-behind-other-$n.jsonl" payload "$PX" acme/widget "$F" "" "" "behind$n" >/dev/null
done
BEHIND2="$PX"
YES12="$(closing "$SAYS_YES" "12" "12")"
r="$(finishes_short "$STORE_USED" "$YES12" "$T")"
check "still possible: his Not announcing clears it when the call read every noted session" "$([[ "$r" == "clear||"* ]] && [ "$(kinds decided)" = 1 ] && echo ok || echo "$r")"
r="$(finishes_short "$STORE_USED" "$YES12" "$T" 1)"
check "R9 #3669 his Not announcing does not clear it when the call read back one of two noted sessions: unread, naming the milestone and the session left unread" "$([[ "$r" == "unread||"*'`Not announcing`'*'"Hand back" (number 28)'*"1 session holding a picker the record notes was left unread, because one call reads back 1"*"an answer of his there is not known to this call"* ]] && echo ok || echo "$r")"
r="$(finishes_short "$STORE_USED" "$YES12" "$T" "" late)"
check "R9 #3669 nor when the call's time ran out before any noted session was read: unread, saying both were left unread" "$([[ "$r" == "unread||"*'`Not announcing`'*"2 sessions holding a picker the record notes were left unread, because the 12 seconds one call has ran out"* ]] && echo ok || echo "$r")"
check "still possible: the question that reads the record only reads no session, and his Not announcing on the record clears it" "$([[ "$(finishes "$STORE_USED" "$YES12")" == "clear|"* ]] && echo ok || echo no)"
# A second milestone the same pull request finishes, with no answer of his: owed, which no override
# clears, stands in front of unread, which the override lets through.
BOTH="$(python3 -c 'import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
refs = a["data"]["repository"]["pullRequest"]["closingIssuesReferences"]
refs["nodes"] += b["data"]["repository"]["pullRequest"]["closingIssuesReferences"]["nodes"]
refs["totalCount"] = len(refs["nodes"])
print(json.dumps(a), end="")' "$YES12" "$(closing "$SAYS_YES" "14" "14" | sed -e 's/"number": 28/"number": 29/' -e 's/Hand back/Hand over/')")"
r="$(finishes_short "$STORE_USED" "$BOTH" "$T" "" late)"
check "R9 #3669 a second milestone it finishes with no answer of his is owed, never unread, and the left unread sentence is still said" "$([[ "$r" == "owed||"*'"Hand over" (number 29)'*"2 sessions holding a picker the record notes were left unread"* ]] && echo ok || echo "$r")"
# An announcement let through for the milestone, beside his decline and the sessions left unread.
printf '{"kind": "used", "repo": "acme/widget", "hash": "%064d", "pr": 5, "closes": [{"issue": 11, "repo": "acme/widget", "milestone": "Hand back", "milestone_number": 28}], "at": "2026-11-21T00:00:00Z"}\n' 0 >> "$STORE_USED/record.jsonl"
r="$(finishes_short "$STORE_USED" "$YES12" "$T" "" late)"
check "still possible #3669: an announcement let through for the milestone clears it with sessions left unread, and is given back for the gate to ask GitHub about" "$([[ "$r" == "clear|5|"* ]] && echo ok || echo "$r")"
r="$(UNMERGED=5 finishes_short "$STORE_USED" "$YES12" "$T" "" late)"
check "R9 #3669 and once GitHub says that one has not merged, his decline with sessions left unread is unread again" "$([[ "$r" == "unread||"*"2 sessions holding a picker the record notes were left unread"* ]] && echo ok || echo "$r")"
r="$(UNMERGED=5 finishes_short "$STORE_USED" "$YES12" "$T")"
check "still possible #3669: with every noted session read, his decline clears it whatever was let through" "$([[ "$r" == "clear||"* ]] && echo ok || echo "$r")"
# Left unread is also what the call TRIED and could not read (the lessons review of this branch, and
# review low 10): a noted session whose transcript is there and cannot be read, and a newer answer of
# his whose check (could he read the picker as written) could not run, which gets no line. Either
# may hold his newer Announce it, so his decline does not clear the merge on that call.
STORE_USED="$WORK/store-f-tried"
T="$WORK/f-tried.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
F="$(shown tried)"
aaf_new "$WORK/f-tried-other.jsonl"
PX="$(talk "$WORK/f-tried-other.jsonl" put acme/widget "$F" "" "tried1")"
note "$WORK/f-tried-other.jsonl" payload "$PX" acme/widget "$F" "" "" "tried1" >/dev/null
r="$(finishes_short "$STORE_USED" "$YES12" "$T")"
check "still possible #3669 D: with the noted session read, his decline clears it (the control for the next case)" "$([[ "$r" == "clear||"* ]] && echo ok || echo "$r")"
# That session's transcript is there and cannot be read: a folder stands where the file was.
rm -f "$WORK/f-tried-other.jsonl"; mkdir "$WORK/f-tried-other.jsonl"
r="$(finishes_short "$STORE_USED" "$YES12" "$T")"
check "R9 #3669 D his decline does not clear it when a noted session's transcript could not be read: unread, naming the milestone and that session" "$([[ "$r" == "unread||"*'`Not announcing`'*'"Hand back" (number 28)'*"f-tried-other.jsonl, could not be read back"* ]] && echo ok || echo "$r")"
r="$(finishes_short "$STORE_USED" "$BOTH" "$T")"
check "R9 #3669 D and a second milestone with no answer of his is owed in front of it, the sentence still said" "$([[ "$r" == "owed||"*'"Hand over" (number 29)'*"could not be read back"* ]] && echo ok || echo "$r")"
check "still possible #3669 D: the question that reads the record only tries no session, and his decline on the record clears it" "$([[ "$(finishes "$STORE_USED" "$YES12")" == "clear|"* ]] && echo ok || echo no)"
# This session's own transcript, where the record notes a picker nothing has judged, is the same.
STORE_USED="$WORK/store-f-tried-own"
T="$WORK/f-tried-own.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
r="$(finishes_short "$STORE_USED" "$YES12" "$T")"
F="$(shown triedown)"
PX="$(talk "$T" put acme/widget "$F")"
note "$T" payload "$PX" acme/widget "$F" >/dev/null
rm -f "$T"; mkdir "$T"
r2="$(finishes_short "$STORE_USED" "$YES12" "$T")"
check "R9 #3669 D nor when this session holds a noted picker and its own transcript could not be read" "$([[ "$r" == "clear||"* && "$r2" == "unread||"*'`Not announcing`'*"this session's transcript could not be read"* ]] && echo ok || echo "$r / $r2")"
# A newer answer about the feature, in a picker whose check could not run: it gets no line and is
# read again, and until it is his decline is not known to be his last answer.
STORE_USED="$WORK/store-f-unchecked"
T="$WORK/f-unchecked.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
r="$(finishes_short "$STORE_USED" "$YES12" "$T")"
check "still possible #3669 D: his decline, read into the record, clears it (the control for the next case)" "$([[ "$r" == "clear||"* ]] && [ "$(kinds decided)" = 1 ] && echo ok || echo "$r")"
talk "$T" decide acme/widget "Hand back" "Announce it"
r="$(NO_NODE=1 finishes_short "$STORE_USED" "$YES12" "$T")"
check "R9 #3669 D his decline does not clear it while a newer answer about that feature could not be checked: unread, saying which answer" "$([[ "$r" == "unread||"*'`Not announcing`'*'whether Dan could read the picker he answered `Announce it` in could not be checked'* ]] && [ "$(kinds decided)" = 1 ] && echo ok || echo "$r")"
r="$(NO_NODE=1 finishes_short "$STORE_USED" "$BOTH" "$T")"
check "R9 #3669 D and a second milestone with no answer of his is owed in front of that too" "$([[ "$r" == "owed||"*'"Hand over" (number 29)'* ]] && echo ok || echo "$r")"
r="$(finishes_short "$STORE_USED" "$YES12" "$T")"
check "R9 #3669 D once the check runs, that newer answer is his last and the milestone is owed" "$([[ "$r" == "owed||"*"is not his last answer about announcing it"* ]] && [ "$(kinds decided)" = 2 ] && echo ok || echo "$r")"
STORE_USED="$WORK/store-f-unchecked-other"
T="$WORK/f-unchecked-other.jsonl"; new_talk "$T"
talk "$T" decide acme/widget "Hand back" "Not announcing" "" "" 28
r="$(finishes_short "$STORE_USED" "$YES12" "$T")"
talk "$T" decide acme/widget "Hand over" "Announce it"
r="$(NO_NODE=1 finishes_short "$STORE_USED" "$YES12" "$T")"
check "still possible #3669 D: an answer about another feature that could not be checked leaves his decline about this one standing" "$([[ "$r" == "clear||"* ]] && echo ok || echo "$r")"
# A noted session whose transcript is gone, its note naming a repository, can never be read. It was
# tried on every call for ever, and said each time as "could not be read back" (review of #3669, low
# 6). It is settled by the call that finds it gone, as a note by its ids alone already was, and said
# once: on that call his decline does not clear, because what he answered there is not known, and
# on every later call it does.
STORE_USED="$WORK/store-f-behind"; T="$WORK/f-behind.jsonl"
rm -f "$WORK/f-behind-other-2.jsonl"
settled_before="$(kinds settled)"
r="$(UNMERGED=5 finishes_short "$STORE_USED" "$YES12" "$T")"
check "R9 #3669 E the call that finds a repository's noted session gone settles its note and says so, and his decline does not clear on that call" "$([[ "$r" == "unread||"*'`Not announcing`'*"f-behind-other-2.jsonl, can never be read"* && "$r" != *"could not be read back"* ]] && settled_as "$BEHIND2" 'transcript is gone' && [ "$(kinds settled)" = "$((settled_before + 1))" ] && echo ok || echo "$r")"
r="$(UNMERGED=5 finishes_short "$STORE_USED" "$YES12" "$T")"
check "still possible #3669 E: it is said once and read no more, and his decline clears the next call" "$([[ "$r" == "clear||"* ]] && [ "$(kinds settled)" = "$((settled_before + 1))" ] && echo ok || echo "$r")"
# The gate asks twice when GitHub says a pull request let through did not merge as an announcement,
# and each question read the noted sessions back with a whole call's time of its own (review of
# #3669, low 10; the time is the library's CHECK_SECONDS, a setting and not a measurement). The two
# now share one: the first answer says what it spent (`spent`), the gate hands that to the second
# (--spent), and the second reads back only in what is left. SPENT is that flag here.
printf '%s' "$YES12" > "$WORK/answer-g.json"
r="$(printf '{"session_id": "s1", "transcript_path": "%s"}' "$T" | ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B "$LIB" finishes --repo acme/widget --pr 7 --answer-file "$WORK/answer-g.json" --hook | python3 -c 'import json, sys
d = json.load(sys.stdin)
s = d.get("spent")
print(d["state"] + "|" + ("a number" if isinstance(s, (int, float)) and not isinstance(s, bool) and 0 <= s < 12 else repr(s)), end="")')"
check "#3669 G the answer says how much of the time for reading sessions back the question spent" "$([[ "$r" == "clear|a number" ]] && echo ok || echo "$r")"
r="$(UNMERGED=5 SPENT=0.5 finishes "$STORE_USED" "$YES12" "$T")"
check "still possible #3669 G: a second question with time left reads the noted session back, and his decline clears it" "$([[ "$r" == "clear|"* ]] && echo ok || echo "$r")"
r="$(UNMERGED=5 SPENT=12 finishes "$STORE_USED" "$YES12" "$T")"
check "R9 #3669 G a second question whose first spent all 12 seconds reads no session back: his decline is unread, saying the shared time ran out" "$([[ "$r" == "unread|"*'`Not announcing`'*"1 session holding a picker the record notes was left unread, because the 12 seconds this merge's two questions share ran out"* ]] && echo ok || echo "$r")"
for odd in unknown -3 nan inf; do
  r="$(UNMERGED=5 SPENT="$odd" finishes "$STORE_USED" "$YES12" "$T")"
  check "R9 #3669 G what the first question spent, handed over as no count of seconds, is read as no time left [$odd]" "$([[ "$r" == "unread|"*"left unread, because the 12 seconds this merge's two questions share ran out"* ]] && echo ok || echo "$r")"
done
# What GitHub does not answer is never read as "not the last".
for bad in '' '{}' '{"data":{"repository":{"pullRequest":null}}}' \
  '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"totalCount":60,"nodes":[]}}}}}' \
  '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"totalCount":1,"nodes":[{"number":12,"repository":{"nameWithOwner":"acme/widget"},"milestone":{"number":28,"title":"Hand back","description":"Announce to agents: yes"}}]}}}}}' \
  '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[]}}}}}'; do
  r="$(finishes "$EMPTY" "$bad")"
  check "R9 an answer of GitHub's that cannot be read is unread, never clear [${bad:0:60}]" "$([[ "$r" == "unread|"* ]] && echo ok || echo "$r")"
done
# finishes_file <file>: the same question with GitHub's answer in that file, as "<state>|<why>".
finishes_file() {
  ANNOUNCE_APPROVALS_DIR="$EMPTY" python3 -B "$LIB" finishes --repo acme/widget --pr 7 --answer-file "$1" </dev/null | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(d["state"] + "|" + d["why"], end="")'
}
r="$(finishes_file "$WORK/description-long.txt")"
check "R9 an answer longer than the library reads is unread, saying so, never cut and judged short" "$([[ "$r" == "unread|"*"larger than 2048 KB"* ]] && echo ok || echo "${r:0:300}")"
r="$(finishes_file "$WORK/no-such-answer.json")"
check "R9 an answer file that cannot be opened is unread, saying so" "$([[ "$r" == "unread|"*"could not be opened"* ]] && echo ok || echo "${r:0:300}")"
check "an issue in another repository is not this repository's milestone" "$([[ "$(finishes "$EMPTY" "$(closing "$SAYS_YES" "12" "12" | sed 's#acme/widget#acme/other#')")" == "clear|"* ]] && echo ok || echo no)"
JUNK="$WORK/store-f-junk"; mkdir -p "$JUNK/record.jsonl"
check "R9 a record that cannot be read is unread, never clear" "$([[ "$(finishes "$JUNK" "$(closing "$SAYS_YES" "12" "12")")" == "unread|"* ]] && echo ok || echo no)"

echo "the record is this suite's own"
# aaf_record_untouched (lib/announce-approval-fixture.sh, which says what it can and cannot see) is
# the check that ends this suite, the merge gate's, the label hook's and the answer note hook's:
# every line this Mac's record gained while the suite ran must be one the suite could not have
# written. Until #3669 each compared a listing of the record's folder before and after. Since the
# installed hook notes every picker any session has answered (#3795), that failed whenever one was
# answered while a suite ran, nine times on 2026-11-26 with every other case green: a before and
# after comparison of shared state blames whatever it brackets (L375). The cases here run on the
# stand in, whose lines are invented; this Mac's own record is read only by the last check below.
ZEROS="$(printf '%064d' 0)"
OTHER_SESSION="3f0c9d52-7a41-4e86-b5d0-9c1e2a7f6b38"
OTHER_PICKER="toolu_01Qx7RmT4vKc2ZbN9sWdLh5E"
# What another session's hook writes when a picker of its own is answered: its ids, and its
# transcript under the projects folder.
OTHERS_NOTE="{\"at\": \"2026-11-27T03:10:56Z\", \"held\": false, \"kind\": \"answered\", \"picker\": \"$OTHER_PICKER\", \"session\": \"$OTHER_SESSION\", \"transcript\": \"$HOME/.claude/projects/invented-project/$OTHER_SESSION.jsonl\"}"
# And a merge another session makes through the helper, whose session id is no session's.
OTHERS_MERGE="{\"at\": \"2026-11-27T03:11:02Z\", \"claim\": true, \"closes\": null, \"hash\": \"$ZEROS\", \"kind\": \"used\", \"pr\": 41, \"repo\": \"someone/thing\", \"session\": \"merge-when-ready\"}"
OLD_ONE="{\"answered\": \"2026-11-20T15:00:00.000Z\", \"at\": \"2026-11-20T15:00:04Z\", \"file\": \"$HOME/notes/post.md\", \"hash\": \"$ZEROS\", \"kind\": \"approved\", \"picker\": \"toolu_01Aa1Bb2Cc3Dd4Ee5Ff6Gg7H\", \"repo\": \"someone/thing\", \"session\": \"$OTHER_SESSION\"}"
OLD_TWO="{\"at\": \"2026-11-21T09:30:00Z\", \"held\": true, \"kind\": \"answered\", \"picker\": \"toolu_01Zz9Yy8Xx7Ww6Vv5Uu4Tt3S\", \"session\": \"$OTHER_SESSION\", \"transcript\": \"$HOME/.claude/projects/invented-project/$OTHER_SESSION.jsonl\"}"
# stand_holds <line>...: the stand in holding exactly those lines, each written as the library
# appends one (a blank line in front of it).
stand_holds() {
  rm -rf "$STAND/record.jsonl"; mkdir -p "$STAND"; : > "$STAND/record.jsonl"
  local l; for l in "$@"; do printf '\n%s\n' "$l" >> "$STAND/record.jsonl"; done
}
# stand_gains <line>...: the check's answer when the stand in, which held its two old lines as the
# run began, gains those lines during it.
stand_gains() {
  stand_holds "$OLD_ONE" "$OLD_TWO"
  local l mark; mark="$(aaf_record_mark "$STAND")"
  for l in ${1+"$@"}; do printf '\n%s\n' "$l" >> "$STAND/record.jsonl"; done
  aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}"
}
check "#3669 real record: a record that gained nothing while the suite ran is untouched" "$(stand_gains)"
check "#3669 real record: another session's note of a picker answered while the suite ran is not this suite's" "$(stand_gains "$OTHERS_NOTE")"
check "#3669 real record: nor is a merge another session made then, through the helper, in a repository of its own" "$(stand_gains "$OTHERS_NOTE" "$OTHERS_MERGE")"
r="$(stand_gains "$OTHERS_NOTE" "{\"held\": false, \"kind\": \"answered\", \"picker\": \"$OTHER_PICKER\", \"session\": \"$OTHER_SESSION\", \"transcript\": \"$WORK/talk.jsonl\"}")"
check "#3669 real record: a line naming a path under this suite's temporary folder is one the suite could have written" "$([[ "$r" == "the record gained 2 lines while the suite ran, and 1 of them could be this suite's own: gained line 2 (kind answered) names a path under the suite's temporary folder" ]] && echo ok || echo "$r")"
r="$(stand_gains "{\"claim\": true, \"closes\": null, \"hash\": \"$ZEROS\", \"kind\": \"used\", \"pr\": 7, \"repo\": \"acme/widget\"}")"
check "#3669 real record: so is a line naming a fixture repository and no path" "$([[ "$r" == "the record gained 1 line while the suite ran, and 1 of them could be this suite's own: gained line 1 (kind used) names the fixture repository acme/widget" ]] && echo ok || echo "$r")"
r="$(stand_gains "{\"closes\": [{\"issue\": 12, \"milestone\": \"Hand back\", \"repo\": \"Acme/Other\"}], \"hash\": \"$ZEROS\", \"kind\": \"used\", \"pr\": 9, \"repo\": \"someone/thing\"}")"
check "#3669 real record: a fixture repository counts in any letter case, wherever the line names it" "$([[ "$r" == *"gained line 1 (kind used) names the fixture repository Acme/Other" ]] && echo ok || echo "$r")"
r="$(stand_gains "{\"kind\": \"settled\", \"picker\": \"toolu_ask1764212345678901234\", \"session\": \"$OTHER_SESSION\"}")"
check "#3669 real record: so is a line naming nothing but a picker id shaped as the fixture's are" "$([[ "$r" == *"gained line 1 (kind settled) names a picker id shaped as the fixture's are" ]] && echo ok || echo "$r")"
r="$(stand_gains "not a line the library writes, and naming $WORK/talk.jsonl")"
check "#3669 real record: a gained line that is no JSON is searched as text" "$([[ "$r" == *"gained line 1 (no kind) names a path under the suite's temporary folder" ]] && echo ok || echo "$r")"
# Lines the record lost, or a line changed in place, fail as they did before the check read lines.
stand_holds "$OLD_ONE" "$OLD_TWO"; mark="$(aaf_record_mark "$STAND")"
stand_holds "$OLD_TWO" "$OTHERS_NOTE"
r="$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
check "#3669 real record: a line the record lost fails, though it holds as many lines as before" "$([[ "$r" == *"a line the record held before the suite ran is gone or was changed in place"* ]] && echo ok || echo "$r")"
stand_holds "$OLD_ONE"
r="$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
check "#3669 real record: and so does a record left holding fewer lines" "$([[ "$r" == *"a line the record held before the suite ran is gone or was changed in place"* ]] && echo ok || echo "$r")"
stand_holds "${OLD_ONE/someone/somebody}" "$OLD_TWO" "$OTHERS_NOTE"
r="$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
check "#3669 real record: a line changed in place fails" "$([[ "$r" == *"a line the record held before the suite ran is gone or was changed in place"* ]] && echo ok || echo "$r")"
rm -rf "$STAND/record.jsonl"
r="$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
check "#3669 real record: a record that is gone altogether fails" "$([[ "$r" == *"a line the record held before the suite ran is gone or was changed in place"* ]] && echo ok || echo "$r")"
# What cannot be read proves nothing, before the run or after it, and is said as that.
mkdir -p "$STAND/record.jsonl"
r="$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
check "#3669 real record: a record that cannot be read after the run is not untouched, in those words" "$([[ "$r" == *"could not be read after the suite ran"* ]] && echo ok || echo "$r")"
mark="$(aaf_record_mark "$STAND")"
stand_holds "$OLD_ONE" "$OLD_TWO"
r="$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
check "#3669 real record: nor is one that could not be read before it" "$([[ "$r" == *"could not be read before the suite ran"* ]] && echo ok || echo "$r")"
r="$(aaf_record_untouched "$STAND" "" "${OWN_MARKS[@]}")"
check "#3669 real record: a mark that was never taken proves nothing" "$([[ "$r" == *"no mark of the record was taken before the suite ran"* ]] && echo ok || echo "$r")"
mark="$(aaf_record_mark "$STAND")"
r="$(aaf_record_untouched "$STAND" "$mark")"
check "#3669 real record: a check told nothing of the suite's own proves nothing" "$([[ "$r" == *"names nothing of the suite's own"* ]] && echo ok || echo "$r")"
r="$(aaf_record_untouched "$STAND" "$mark" "path:" "repo:acme/")"
check "#3669 real record: nor does one whose folder is no folder, which every line would name" "$([[ "$r" == *"names nothing of the suite's own"* ]] && echo ok || echo "$r")"
# A Mac with no record yet, and one whose first line arrives while the suite runs.
rm -rf "$STAND"; mark="$(aaf_record_mark "$STAND")"
check "#3669 real record: no record before and none after is untouched" "$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
stand_holds "$OTHERS_NOTE"
check "#3669 real record: a record another session began while the suite ran is not this suite's" "$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
# A line the record held as the run began is not this run's, whatever it names.
stand_holds "{\"kind\": \"used\", \"pr\": 7, \"repo\": \"acme/widget\"}"; mark="$(aaf_record_mark "$STAND")"
printf '\n%s\n' "$OTHERS_NOTE" >> "$STAND/record.jsonl"
check "#3669 real record: a line the record held before the suite ran is not held against this run" "$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
# And the suites still catch a case that writes the record: this suite's own writes, each through
# the library as its cases make them, pointed at the stand in and never at the real record.
rm -rf "$STAND"; mkdir -p "$STAND"; STORE_USED="$STAND"
mark="$(aaf_record_mark "$STAND")"
F="$(shown standin)"; T="$WORK/standin.jsonl"; HS="$(hash_file "$F")"
talk "$T" ask acme/widget "$F"
asked "$T" acme/widget "$HS" >/dev/null
r="$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
check "#3669 real record: an approval a case of this suite wrote into the stand in is caught" "$([ "$(kinds approved)" = 1 ] && [[ "$r" == *"could be this suite's own: gained line 1 (kind approved) names a path under the suite's temporary folder and the fixture repository acme/widget and a picker id shaped as the fixture's are" ]] && echo ok || echo "$r")"
check "#3669 real record: by its folder alone" "$([[ "$(aaf_record_untouched "$STAND" "$mark" "path:$WORK")" == *"(kind approved) names a path under the suite's temporary folder"* ]] && echo ok || echo no)"
check "#3669 real record: and by its repository alone" "$([[ "$(aaf_record_untouched "$STAND" "$mark" "repo:acme/widget")" == *"(kind approved) names the fixture repository acme/widget"* ]] && echo ok || echo no)"
mark="$(aaf_record_mark "$STAND")"
used --repo acme/widget --hash "$HS" --pr 7 >/dev/null
r="$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
check "#3669 real record: a use a case wrote there, which names no path, is caught by its repository" "$([ "$(kinds used)" = 1 ] && [[ "$r" == *"gained line 1 (kind used) names the fixture repository acme/widget" ]] && echo ok || echo "$r")"
mark="$(aaf_record_mark "$STAND")"
P="$(talk "$T" put acme/widget "$F" plain)"
note "$T" payload "$P" acme/widget "$F" "" plain >/dev/null
r="$(aaf_record_untouched "$STAND" "$mark" "${OWN_MARKS[@]}")"
check "#3669 real record: a note by ids alone a case wrote there, which names no repository, is caught by its transcript's path" "$([ "$(kinds answered)" = 1 ] && [[ "$r" == *"gained line 1 (kind answered) names a path under the suite's temporary folder and a picker id shaped as the fixture's are" ]] && echo ok || echo "$r")"

check "no case wrote to this Mac's real record" "$(aaf_record_untouched "$REAL_STORE" "$real_before" "${OWN_MARKS[@]}")"

echo "  $pass passed, $fail failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
