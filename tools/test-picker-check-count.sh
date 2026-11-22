#!/usr/bin/env bash
# Tests for tools/picker-check-count.ts, the count of how many past pickers the shared check of
# text a person approves in a picker would have refused, per guard (claude-config#3321). The
# session records here are made up, in the shape Claude Code writes: no real picker's text is in
# this file (L155). A character the check refuses is written as its escape, never as itself.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "SUITE-UNMEASURED node is not installed, so the count could not be run"
  exit 0
fi
pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
has(){ case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "wanted: $3 / got: $2" ;; esac; }
TOOL="$DIR/picker-check-count.ts"
W="$(mktemp -d "${TMPDIR:-/tmp}/picker-check-count.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/projects/one" "$W/projects/two"
# A zero width space as JSON writes it, a backslash, a u and its code point, put together here from
# two pieces so that this file holds neither the character nor its escape whole (an editor can
# strip the one unseen, and a tool can turn the other into it).
ZW="$(printf '%s%s' '\u' '200b')"

# One picker as a session record keeps it: the call on an assistant line, its result on a user
# line. $1 id, $2 the call's input, $3 the result (toolUseResult), $4 extra keys of the result
# item, $5 extra keys of both lines.
picker(){
  printf '{"type":"assistant"%s,"message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"%s","input":%s}]}}\n' "${5:-}" "$1" "$2"
  printf '{"type":"user"%s,"message":{"content":[{"type":"tool_result","tool_use_id":"%s"%s}]},"toolUseResult":%s}\n' "${5:-}" "$1" "${4:-}" "$3"
}
q(){ printf '{"questions":[{"question":"%s","header":"H","multiSelect":false,"options":[{"label":"Yes","description":"d"},{"label":"No","description":"d"}]}],"metadata":{"source":"%s"}}' "$1" "$2"; }
answered(){ printf '{"questions":[{"question":"%s","header":"H","multiSelect":false,"options":[{"label":"Yes","description":"d"}]}],"answers":{"%s":"Yes"}}' "$1" "$1"; }
{
  # The design round guard: one he could read, one holding a placeholder in angle brackets.
  picker t1 "$(q 'Skip design rounds for this issue?' 'design-round-guard:t9')" "$(answered 'The heading moves. Skip design rounds for this issue?')"
  picker t2 "$(q 'Skip design rounds for this issue?' 'design-round-guard:t8')" "$(answered 'The heading on <page> moves. Skip design rounds for this issue?')"
  # The lesson picker, clean; and one holding a zero width space that closed while he was away.
  picker t3 "$(q 'Add this lesson? A rule in plain words.' 'durable-lesson')" "$(answered 'Add this lesson? A rule in plain words.')"
  picker t4 "$(q "Add this lesson? A rule${ZW} in plain words." 'durable-lesson')" '{"questions":[],"answers":{},"afkTimeoutMs":60000}'
  # Read by no guard: an ordinary question, faulty or not.
  picker t5 "$(q 'Which <thing> first?' 'none')" "$(answered 'Which <thing> first?')"
  # Never counted: a subagent's picker, one whose result is an error, and a call with no result.
  picker t6 "$(q 'Add this lesson? <x>' 'durable-lesson')" "$(answered 'Add this lesson? <x>')" '' ',"isSidechain":true'
  picker t7 "$(q 'Add this lesson? <x>' 'durable-lesson')" '"The user rejected the question"' ',"is_error":true'
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"t8","input":%s}]}}\n' "$(q 'Add this lesson? <x>' 'durable-lesson')"
  printf 'not json at all AskUserQuestion\n'
} > "$W/projects/one/s1.jsonl"
{
  # The two database pickers, and a morning picker in the shape sleep mode reads, too long to show whole.
  picker u1 "$(q 'Apply this migration?' 'db-apply')" "$(answered 'Apply this migration?')"
  picker u2 "$(q 'Trust this line?' 'db-test-project')" "$(answered 'Trust this line?')"
  long="3.1 $(printf 'word %.0s' $(seq 1 400))"
  picker u3 "$(q "$long" 'none')" "$(answered "$long")"
  # Written onto an issue by picker manners: a first question naming one.
  picker u4 "$(q 'For o/r#7, keep the flag?' 'none')" "$(answered 'For o/r#7, keep the flag?')"
} > "$W/projects/two/s2.jsonl"
printf 'not a session record\n' > "$W/projects/two/notes.txt"

out="$(node "$TOOL" --projects "$W/projects" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "the count runs and exits 0" ok || check "the count runs and exits 0" "exit=$code out=$out"
has "it says how many records it read, how many pickers reached the dialog and how many no guard reads" "$out" "2 session records read in $W/projects; 9 pickers of the main conversation reached the dialog, 1 of them read by no guard below."
has "the design round guard's pickers are judged as the dialog got them, the guard's own wording, not as Claude sent them" "$out" "design round guard: 2 reached the dialog, 2 answered; refused 1, of the answered 1 (by rule, of all refused: 1 markup a surface hides)."
has "a picker that closed while he was away reached the dialog and is not answered; a subagent's, an error and an unanswered call are not counted" "$out" "lesson picker (ask before saving): 2 reached the dialog, 1 answered; refused 1, of the answered 0 (by rule, of all refused: 1 a character he cannot see)."
has "the database apply picker is counted by its source" "$out" "database apply approval (hook): 1 reached the dialog, 1 answered; refused 0, of the answered 0."
has "the database test project picker is counted by its source" "$out" "database test project approval (hook): 1 reached the dialog, 1 answered; refused 0, of the answered 0."
has "a morning picker too long for the dialog is refused by length" "$out" "sleep mode morning pickers: 1 reached the dialog, 1 answered; refused 1, of the answered 1 (by rule, of all refused: 1 longer than the dialog shows whole)."
has "a question naming an issue is counted for picker manners" "$out" "picker manners (answer written to an issue): 1 reached the dialog, 1 answered; refused 0, of the answered 0."
has "a guard with no picker on record says so as a zero, never by its absence" "$out" "area check restructure question: 0 reached the dialog, 0 answered; refused 0, of the answered 0."
case "$out" in *page*|*'plain words'*|*migration*) check "no word of a picker's text is printed" "$out" ;; *) check "no word of a picker's text is printed" ok ;; esac

out="$(node "$TOOL" --projects "$W/projects" --where 2>&1)"
has "--where names the record and the line of each refused picker, and what was at fault" "$out" "  s1.jsonl line 3: The question, markup a surface hides"
has "--where says when a refused picker was not answered" "$out" "  s1.jsonl line 7: The question, a character he cannot see (not answered)"
case "$out" in *page*|*'plain words'*) check "--where prints no word of a picker's text either" "$out" ;; *) check "--where prints no word of a picker's text either" ok ;; esac

# A record is read a piece at a time (a megabyte), never whole: some are hundreds of megabytes and
# the count runs on a Mac short of memory. A line longer than a piece, a picker that starts in one
# piece and ends in the next, a character of several bytes across the join, and a last line with
# no newline are each read as written.
mkdir -p "$W/big/p"
python3 - "$W/big/p/s3.jsonl" "$ZW" <<'PY'
import json, sys
path, zw = sys.argv[1], json.loads('"' + sys.argv[2] + '"')
def picker(uid, question, source):
    ask = {"questions": [{"question": question, "header": "H", "multiSelect": False, "options": [{"label": "Yes", "description": "d"}]}], "metadata": {"source": source}}
    return [json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "AskUserQuestion", "id": uid, "input": ask}]}}),
            json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": uid}]}, "toolUseResult": {"questions": ask["questions"], "answers": {question: "Yes"}}})]
piece = 1 << 20
lines = [json.dumps({"type": "user", "message": {"content": "x" * (piece + 500)}})]
lines += picker("b1", "Add this lesson? A rule in plain words.", "durable-lesson")
# Filler sized so the next picker's first line straddles the end of a piece, the join falling
# inside a run of two byte characters written as themselves.
used = sum(len(l.encode()) + 1 for l in lines)
pad = piece - (used % piece) - 400
lines.append(json.dumps({"type": "user", "message": {"content": "y" * max(pad - 60, 1)}}))
wide = json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "AskUserQuestion", "id": "b2", "input": {
    "questions": [{"question": "Add this lesson? " + chr(0xe9) * 600 + zw, "header": "H", "multiSelect": False, "options": [{"label": "Yes", "description": "d"}]}],
    "metadata": {"source": "durable-lesson"}}}]}}, ensure_ascii=False)
lines.append(wide)
lines.append(json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "b2"}]}, "toolUseResult": {"questions": [], "answers": {"q": "Yes"}}}))
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
start = sum(len(l.encode()) + 1 for l in lines[:4])
assert start // piece != (start + len(wide.encode())) // piece, "the fixture's picker does not cross a piece"
PY
[ $? -eq 0 ] && check "the fixture holds a picker that crosses the join of two pieces" ok || check "the fixture holds a picker that crosses the join of two pieces" "it could not be built so"
out="$(node "$TOOL" --projects "$W/big" --where 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "a record larger than one piece is counted, exit 0" ok || check "a record larger than one piece is counted, exit 0" "exit=$code out=${out:0:300}"
has "pickers after a line longer than a piece, and across the join of two pieces, are both read" "$out" "lesson picker (ask before saving): 2 reached the dialog, 2 answered; refused 1, of the answered 1 (by rule, of all refused: 1 a character he cannot see)."
has "and the refused one is named by its own line" "$out" "  s3.jsonl line 5: The question, a character he cannot see"

# The two database sources are the ones the hook reads, which a python file holds and this cannot import.
for pair in "DB_APPLY_SOURCE:SOURCE" "DB_TRUST_SOURCE:TRUST_SOURCE"; do
  mine="$(sed -n "s/^export const ${pair%%:*} = '\\(.*\\)'\$/\\1/p" "$TOOL")"
  theirs="$(sed -n "s/^${pair##*:} = \"\\(.*\\)\"\$/\\1/p" "$DIR/../payload/hooks/lib/db-apply-approval.py")"
  [ -n "$mine" ] && [ "$mine" = "$theirs" ] && check "${pair%%:*} is the source db-apply-approval.py reads" ok || check "${pair%%:*} is the source db-apply-approval.py reads" "mine=$mine theirs=$theirs"
done

# Each failure is its own exit code and says why.
out="$(node "$TOOL" --projects "$W/none" 2>&1)"; code=$?
[ "$code" -eq 3 ] && check "a folder that cannot be read exits 3" ok || check "a folder that cannot be read exits 3" "exit=$code"
has "and says nothing was counted" "$out" "could not be read"
out="$(node "$TOOL" --sideways 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "an argument it does not know exits 2" ok || check "an argument it does not know exits 2" "exit=$code"
has "and says which" "$out" '"--sideways" is not understood'
mkdir -p "$W/empty"
out="$(node "$TOOL" --projects "$W/empty" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "a folder holding no session record is counted as none, exit 0" ok || check "a folder holding no session record is counted as none, exit 0" "exit=$code"
has "and says it read none" "$out" "0 session records read"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
