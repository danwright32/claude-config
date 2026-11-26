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
    | ANNOUNCE_APPROVALS_DIR="${STORE_USED:-$STORE}" aaf_hook_check "$LIB" "$2" "$3" \
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

# What is not noted, each said in its own words or, for a picker that is not this one, not at all.
STORE_USED="$WORK/store-noted-not"
F="$(shown not-noted)"; T="$WORK/not-noted.jsonl"
P="$(talk "$T" put acme/widget "$F")"
r="$(note "$T" payload "$P" acme/widget "$F" "" "" "" a9bba4c0ffee)"
check "a subagent's picker is not noted, and that is said" "$([[ "$r" == "no|"*"subagent"* ]] && [ "$(kinds answered)" = 0 ] && echo ok || echo "$r")"
P2="$(talk "$T" put acme/widget "$F" othersource)"
r="$(note "$T" payload "$P2" acme/widget "$F" "" othersource)"
check "a picker of another source is not noted, and nothing is said" "$([[ "$r" == "no|" ]] && [ "$(kinds answered)" = 0 ] && echo ok || echo "$r")"
P2="$(talk "$T" put acme/widget "$F" prefilled)"
r="$(note "$T" payload "$P2" acme/widget "$F" "" prefilled)"
check "a picker the session sent with its answer filled in was never put to him, and is not noted" "$([[ "$r" == "no|" ]] && [ "$(kinds answered)" = 0 ] && echo ok || echo "$r")"
P2="$(talk "$T" put "not a repository" "$F")"
r="$(note "$T" payload "$P2" "not a repository" "$F")"
check "a picker whose metadata names no repository is not noted, and that is said" "$([[ "$r" == "no|"*"does not name the repository"* ]] && echo ok || echo "$r")"
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
# A picker neither copy says the source of may be this one, in a form nobody has printed. It is
# never left in silence: the answer says that what it asked could not be told, and why.
r="$(AAF_PAYLOAD_FORM=nometadata note "$T" payload toolu_absent2 acme/widget "$F")"
check "one the transcript does not hold and the payload does not name the source of is not noted, and that is said" "$([[ "$r" == "no|"*"could not be told"*"does not hold the picker toolu_absent2"*"carries no metadata"* ]] && [ "$(kinds answered)" = 1 ] && echo ok || echo "$r")"
r="$(AAF_PAYLOAD_FORM=nometadata note "$WORK/no-such-talk.jsonl" payload toolu_absent3 acme/widget "$F")"
check "and so is one whose transcript cannot be read" "$([[ "$r" == "no|"*"could not be told"*"could not be read"* ]] && echo ok || echo "$r")"
r="$(AAF_PAYLOAD_FORM=nometadata note "$T" payload toolu_absent4 acme/widget "$F" "" "" "" a9bba4c0ffee)"
check "a subagent's picker is never noted whatever it asked, so one that cannot be told draws no line" "$([[ "$r" == "no|" ]] && echo ok || echo "$r")"
# An ordinary picker, which the transcript holds and which names no source, is no business of this.
P2="$(talk "$T" put acme/widget "$F" plain)"
r="$(note "$T" payload "$P2" acme/widget "$F" "" plain)"
check "a picker the transcript holds with no metadata is not this one, and nothing is said" "$([[ "$r" == "no|" ]] && [ "$(kinds answered)" = 1 ] && echo ok || echo "$r")"
STORE_USED="$WORK/store-noted-not"
r="$(printf 'not json' | ANNOUNCE_APPROVALS_DIR="$STORE_USED" python3 -B "$LIB" answered 2>&1)"
check "a payload nothing can read is not noted, and that is said" "$([[ "$r" == *'"noted": false'*"could not be told"*"was not a JSON object"* ]] && echo ok || echo "$r")"
# A wording file that cannot be hashed is noted with why, and that reason is the refusal's.
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
check "a note the record cannot take is said, naming the record" "$([[ "$r" == "no|"*"was not noted"*"$STORE_USED/record.jsonl"* ]] && echo ok || echo "$r")"

unset STORE_USED

echo "the open of the file is the session's last tool call before the picker (#3742 item 2)"
# Two wording files open at once: the second is the window in front when he answers about the
# first, and the picker shows him neither file's name. So an open counts only when nothing else of
# the session's ran between it and the picker.
# The two are named apart: a command naming a file's own name already voids its open (above).
STORE_USED="$WORK/store-two"
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
check "and nothing was written to the record for any of them" "$([ "$(recorded)" = 0 ] && echo ok || echo "$(recorded) lines")"
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
check "how to ask says the picker is the very next call after the open" "$(printf '{"session_id": "s1", "transcript_path": "%s"}' "$T" | ANNOUNCE_APPROVALS_DIR="$STORE" python3 -B "$LIB" check --repo acme/none --hash "$H" | grep -q "very next tool call" && echo ok || echo "the how to ask text does not say so")"

echo "the record is this suite's own"
check "no case wrote to this Mac's real record" "$([ "$(ls -la "$REAL_STORE" 2>/dev/null | cksum)" = "$real_before" ] && echo ok || echo "$REAL_STORE changed during the run")"

echo "  $pass passed, $fail failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
