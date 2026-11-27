#!/usr/bin/env bash
# Tests for tools/steps-phrase-count.ts, the count of the turns the manual steps mod's end of turn
# check would hold for what claude-config#3842 added. It is also the one place the mod's own
# transcript reader (the perl hooks/turn.ts runs) is run for real, on a session record in the
# shape Claude Code writes: the mod's own tests hand turnIn the reader's output and never run it.
#
# The session record here is made up (L155). Its shape is measured (L48): on 2026-11-27, over the
# session records of 30 days on the personal MacBook (Claude Code 2.1.311 to 2.1.332), the record
# of a tool result is a user line carrying the turn's promptId, isSidechain, and for a refused call
# toolDenialKind, permissionDecision and toolUseResult; a call is an assistant line, one content
# block a line. The sentences are the issue's own wordings.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for need in node perl; do
  if ! command -v "$need" >/dev/null 2>&1; then
    echo "SUITE-UNMEASURED $need is not installed, so the count could not be run"
    exit 0
  fi
done
pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
has(){ case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "wanted: $3 / got: $2" ;; esac; }
lacks(){ case "$2" in *"$3"*) check "$1" "must not hold: $3" ;; *) check "$1" ok ;; esac; }
TOOL="$DIR/steps-phrase-count.ts"
W="$(mktemp -d "${TMPDIR:-/tmp}/steps-phrase-count.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/projects/one/s1/subagents" "$W/projects/two" "$W/empty"

# The lines of a session record. $1 is the prompt's id on each.
prompt(){ printf '{"parentUuid":null,"isSidechain":false,"promptId":"%s","type":"user","message":{"role":"user","content":"do the work"},"uuid":"u"}\n' "$1"; }
said(){ printf '{"parentUuid":"u","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$2"; }
# A call of a tool: $2 is the tool, $3 is true when a subagent made it inside the main record.
called(){ printf '{"parentUuid":"u","isSidechain":%s,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"%s","input":{}}]}}\n' "${3:-false}" "$2"; }
result(){ printf '{"parentUuid":"u","isSidechain":false,"promptId":"%s","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"%s"}]},"toolUseResult":{"stdout":"ok"}}\n' "$1" "${2:-ok}"; }
# A refused call: $2 is the kind Claude Code records, $3 extra keys.
refused(){ printf '{"parentUuid":"u","isSidechain":%s,"promptId":"%s","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Destructive or Unwanted Actions]."}]},"toolDenialKind":"%s","permissionDecision":{"decision":"reject","reasonType":"classifier","reasonCode":"classifier:auto-mode","source":"config"},"toolUseResult":"Error: Permission for this action was denied by the Claude Code auto mode classifier."}\n' "${3:-false}" "$1" "$2"; }
STEPS=mcp__manual-steps__steps
{
  # 1: a new phrase alone, nothing pinned: newly read, and the most it would newly hold.
  prompt p1; said p1 'That closes every point except the one only you can do: set Status to Done at (link).'
  # 2: a call the permission check refused, and a reply that names no phrase: held for the refusal.
  prompt p2; called p2 Bash; refused p2 automode-blocked; said p2 'I checked the deploy and it is live.'
  # 3: refused, then the step pinned: answered.
  prompt p3; called p3 Bash; refused p3 automode-blocked; called p3 "$STEPS"; result p3 Pinned; said p3 'It is on the card.'
  # 4: no verdict, a hook refusal and a prompt Dan declined: none is counted.
  prompt p4; refused p4 automode-unavailable; refused p4 permission-rule; refused p4 user-rejected; said p4 'Carrying on.'
  # 5: refused, and the one line: not held.
  prompt p5; refused p5 automode-blocked; said p5 'Nothing from the refusal is yours to do.'
  # 6: a new phrase beside one the check already read: said, not newly read.
  prompt p6; said p6 'The deploy is waiting on you: run the migration command. It is the one only you can do.'
  # 7: a new phrase in a turn that pinned a step: newly read, held by nothing new.
  prompt p7; called p7 "$STEPS"; result p7 Pinned; said p7 'One step left for you, and it is on the card.'
  # 8: the kind only quoted inside a tool result, where a record holds it escaped: not a refusal.
  prompt p8; result p8 '{\"toolDenialKind\":\"automode-blocked\"}'; said p8 'I read the record.'
  # 9: a refused call and a new phrase in one turn: each counted, and counted as both.
  prompt p9; refused p9 automode-blocked; said p9 'One step left for you. The to do list row is still on Waiting.'
  # 10: a subagent refused inside the main record: not this conversation's.
  prompt p10; refused p10 automode-blocked true; said p10 'The agent stopped.'
  # 11: the three wordings of the issue the check does not read (said in no turn of the personal
  # MacBook's 30 days, 2026-11-27): no phrase, so the turn is counted and nothing in it is.
  prompt p11; said p11 'Still yours: Status needs setting to Done. The row still needs you to set it, because my update was refused by the permission check.'
  # 12: refused, then a subagent pinned a step of its own inside the main record: not answered, so
  # held (review of pull request 3854; the reader marks whose call it was, and this runs the reader).
  prompt p12; called p12 Bash; refused p12 automode-blocked; called p12 "$STEPS" true; said p12 'The agent finished.'
} > "$W/projects/one/s1.jsonl"
# A subagent's own record, in its folder: never read.
{ prompt q1; refused q1 automode-blocked; said q1 'The row still needs you to set Status to Done.'; } > "$W/projects/one/s1/subagents/a.jsonl"
# The same session's record under a second project folder, as Claude Code keeps one when a session
# changes folder, holding less of turn 2 (its prompt and a first message, from before the call was
# refused): the turn is counted once, as the record holding more of it has it.
{ prompt p2; said p2 'Starting.'; } > "$W/projects/two/s1.jsonl"
# A record last written before the days asked for: not read.
{ prompt o1; refused o1 automode-blocked; said o1 'The row still needs you to set Status to Done.'; } > "$W/projects/two/old.jsonl"
touch -t 202001010000 "$W/projects/two/old.jsonl"
before="$(find "$W" -type f | sort | xargs cksum)"

out="$(node "$TOOL" --projects "$W/projects" --where 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "the count runs, exit 0" ok || check "the count runs, exit 0" "exit=$code: $out"
has "two records read, the old one and the subagent's passed over" "$out" "2 session records last written in 30 days read"
has "twelve turns, the one kept in both records counted once" "$out" "; 12 turns of the main conversation, 1 more kept in a second record and counted once."
has "the one only you can do: said in 2, newly read in 1, would newly hold 1" "$out" 'phrase "the one only you can do": said in 2; newly read in 1; would newly hold at most 1.'
has "step left for you: said in 2, one of them in a turn that pinned a step, so it would newly hold 1" "$out" 'phrase "step left for you": said in 2; newly read in 2; would newly hold at most 1.'
has "--where names the turn a phrase alone would hold" "$out" "  s1.jsonl turn 1"
lacks "a wording the check does not read is not counted: Still yours" "$out" "Still yours"
lacks "nor needs you to set" "$out" "needs you to set"
lacks "nor because my update was refused" "$out" "because my"
has "the refused call: 5 turns, 1 answered by a pin, 1 by the line, 3 held, 1 of them with a new phrase too" "$out" "a call the permission check refused: in 5 turns; answered by a steps tool call after it in 1; answered in words in 1; would be held once each: 3, of which 0 the check had already held for another reason and 1 a new phrase would hold too."
has "--where names the record and the turn" "$out" "  s1.jsonl turn 2"
has "--where names the turn held for both" "$out" "  s1.jsonl turn 9"
has "--where names the turn a subagent's pin did not answer" "$out" "  s1.jsonl turn 12"
lacks "no word of what was said is printed" "$out" "Waiting"
lacks "nor of the reply" "$out" "deploy"
after="$(find "$W" -type f | sort | xargs cksum)"
[ "$before" = "$after" ] && check "it writes no file and changes none" ok || check "it writes no file and changes none" "the folder changed"

# The days asked for decide which records are read.
out="$(node "$TOOL" --projects "$W/projects" --days 9999 2>&1)"
has "a longer window reads the older record too" "$out" "3 session records last written in 9999 days read"
has "and its refused call" "$out" "a call the permission check refused: in 6 turns"

out="$(node "$TOOL" --projects "$W/empty" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "a folder holding no session record is counted as none, exit 0" ok || check "a folder holding no session record is counted as none, exit 0" "exit=$code"
has "and says it read none" "$out" "0 session records last written in 30 days read"
has "a phrase said nowhere counts zero" "$out" 'phrase "the one only you can do": said in 0; newly read in 0; would newly hold at most 0.'
out="$(node "$TOOL" --projects "$W/missing" 2>&1)"; code=$?
[ "$code" -eq 3 ] && check "a folder that cannot be read exits 3" ok || check "a folder that cannot be read exits 3" "exit=$code"
has "and says nothing was counted" "$out" "so nothing was counted"
out="$(node "$TOOL" --days nine 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "an argument it does not understand exits 2" ok || check "an argument it does not understand exits 2" "exit=$code"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
