#!/usr/bin/env bash
# The manual steps mod's transcript reader (the perl payload/mods/manual-steps/hooks/turn.ts runs),
# run for real on session records in the shape Claude Code writes, for what claude-config#3860
# added: a refusal in a record too long to keep whole, a refusal further back than the window, the
# reader saying it stopped before the turn's first record, and a steps tool call's result. The
# mod's own tests hand turnIn the reader's output and never run it.
#
# Every record here is made up. Its shape is measured (2026-11-28, the main conversations' records
# of 30 days on the personal MacBook): a tool result is a user line carrying the turn's promptId
# and one tool_result block with its call's tool_use_id, and is_error when the call failed or was
# refused; a refused call's line also carries toolDenialKind at its top level; a call is an
# assistant line, one block a line, the block carrying its id before its name.
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
    echo "SUITE-UNMEASURED $need is not installed, so the reader could not be run"
    exit 0
  fi
done
pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
has(){ case " $2 " in *" $3 "*) check "$1" ok ;; *) check "$1" "wanted: $3 / got: $2" ;; esac; }
W="$(mktemp -d "${TMPDIR:-/tmp}/turn-reader-far.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT

# Runs the mod's own reader on a record and prints what turnIn makes of it, one word per answer.
cat > "$W/read.ts" <<EOF
import { spawnSync } from 'node:child_process'
import { turnIn, turnReadArgv } from '$DIR/../payload/mods/manual-steps/hooks/turn.ts'
const [path, ...limits] = process.argv.slice(2)
const [cmd, ...argv] = turnReadArgv(path as string, ...limits.map(Number))
const r = spawnSync(cmd as string, argv, { encoding: 'utf8', maxBuffer: 2 ** 31 - 1 })
const t = turnIn(r.stdout)
console.log(\`status=\${r.status} refused=\${t.refused} unasked=\${t.refusedUnasked} met=\${t.refusedMet} cut=\${t.isCutShort} ours=\${t.isOurs} prompt=\${t.promptId} texts=\${t.texts.length} pinned=\${t.isPinned} outkb=\${Math.ceil(r.stdout.length / 1024)} \${r.stderr.trim()}\`)
EOF
# read_turn <record> [window bytes] [bytes back past the window] [the reader's own milliseconds]
read_turn(){ node "$W/read.ts" "$@" 2>/dev/null; }

STEPS=mcp__manual-steps__steps
prompt(){ printf '{"parentUuid":null,"isSidechain":false,"promptId":"%s","type":"user","message":{"role":"user","content":"do the work"},"uuid":"u"}\n' "$1"; }
said(){ printf '{"parentUuid":"u","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$2"; }
# A call of a tool: $1 the tool, $2 the call's id.
called(){ printf '{"parentUuid":"u","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"%s","input":{},"caller":{"type":"direct"}}]}}\n' "$2" "$1"; }
# A tool result: $1 the prompt, $2 the call's id, $3 how many bytes it holds.
result(){ printf '{"parentUuid":"u","isSidechain":false,"promptId":"%s","type":"user","message":{"role":"user","content":[{"tool_use_id":"%s","type":"tool_result","content":"%s"}]},"toolUseResult":{"stdout":"ok"}}\n' "$1" "$2" "$(perl -e 'print "x" x $ARGV[0]' "${3:-2}")"; }
# A call that failed: its result says so.
failed(){ printf '{"parentUuid":"u","isSidechain":false,"promptId":"%s","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"The step names no place.","is_error":true,"tool_use_id":"%s"}]},"toolUseResult":"Error: The step names no place."}\n' "$1" "$2"; }
feedback(){ printf '{"parentUuid":"u","isSidechain":false,"promptId":"%s","type":"user","message":{"role":"user","content":"Stop hook feedback:\\nThe permission check refused a call of yours in this turn. A refusal is final."}}\n' "$1"; }
# A refused call's record: $1 the prompt, $2 the kind, $3 true when a subagent's, $4 words put in
# its result (so a record can be made long, or hold what a careless reader would trip on), $5 a
# nested value put before the kind.
refused(){ printf '{"parentUuid":"u","isSidechain":%s,"promptId":"%s","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Permission for this action was denied.%s","is_error":true,"tool_use_id":"r1"}]},"uuid":"u-%s","toolUseResult":"Error: denied",%s"toolDenialKind":"%s","permissionDecision":{"decision":"reject","reasonType":"classifier"}}\n' "${3:-false}" "$1" "${4:-}" "$1" "${5:-}" "$2"; }
LONG="$(perl -e 'print "y" x 70000')"

# ---- A refusal in a record too long to keep whole ----
{ prompt p0; said p0 'An earlier turn.'; prompt p1; called Bash c1; refused p1 automode-blocked false "$LONG"; said p1 'The row is still yours.'; } > "$W/long.jsonl"
out="$(read_turn "$W/long.jsonl")"
has "a refusal in a record of over 65,536 bytes is counted" "$out" "refused=1"
has "and its record is not printed whole" "$out" "outkb=1"

# The same words nested inside a record of another kind, and what a scan of its strings could trip on.
NESTED='"serverClassifierContext":{"toolDenialKind":"automode-blocked","seen":[{"toolDenialKind":"automode-blocked"}]},'
{ prompt p1; refused p1 permission-rule false "$LONG" "$NESTED"; said p1 'Carrying on.'; } > "$W/nested.jsonl"
has "a long record of another kind that holds the kind nested inside it is not a refusal" "$(read_turn "$W/nested.jsonl")" "refused=0"
TRICKY="$LONG"' a quote \" a backslash \\\\ a bracket }]{[ and a key \"toolDenialKind\":\"permission-rule\" \\'
{ prompt p1; refused p1 automode-blocked false "$TRICKY" '"nested":{"a":[1,{"b":"}"}],"n":5,"t":true},"count":3,'; said p1 'x'; } > "$W/tricky.jsonl"
has "a long refusal whose strings hold quotes, backslashes and brackets is still counted" "$(read_turn "$W/tricky.jsonl")" "refused=1"
{ prompt p1; refused p1 automode-blocked true "$LONG"; said p1 'x'; } > "$W/agent.jsonl"
has "a subagent's long refusal is not the main conversation's" "$(read_turn "$W/agent.jsonl")" "refused=0"

# ---- A refusal further back than the window ----
# The window here is 3,000 bytes, so a turn of about 20 KB starts well before it.
far_turn(){ prompt p0; refused p0 automode-blocked; said p0 'An earlier turn, with a refusal of its own.'; prompt p1; called Bash c1; refused p1 automode-blocked; for n in 1 2 3 4 5 6 7 8; do called Bash "c$n"; result p1 "c$n" 2400; done; said p1 'The row is still yours.'; }
far_turn > "$W/far.jsonl"
out="$(read_turn "$W/far.jsonl" 3000 1000000 5000)"
has "a refusal further back than the window is counted" "$out" "refused=1"
has "the turn was read to its first record" "$out" "cut=false"
has "the refusal of the turn before, further back still, is not this turn's" "$out" "met=1"
has "what Claude wrote before the window is not printed" "$out" "texts=1"

# The reader stopped by its limit on bytes, then by its limit on time: it says it stopped.
out="$(read_turn "$W/far.jsonl" 3000 5000 5000)"
has "stopped by its limit on bytes before the turn's first record, the reader says it stopped" "$out" "cut=true"
has "and what it never read is not counted" "$out" "refused=0"
out="$(read_turn "$W/far.jsonl" 3000 1000000 0)"
has "stopped by its limit on time, the reader says it stopped" "$out" "cut=true"
has "and still answers with what the window held" "$out" "status=0"
# A turn that fits the window is never walked back from, whatever the limits.
has "a turn whose first record is inside the window is not cut short" "$(read_turn "$W/far.jsonl" 100000 0 0)" "cut=false"

# The walk ends at the turn's first record: a long turn before it is not walked through, so the
# limit is not reached and nothing is said to be unread.
{ prompt p0; for n in 1 2 3 4 5 6 7 8; do called Bash "b$n"; result p0 "b$n" 2400; done; said p0 'earlier'; prompt p1; refused p1 automode-blocked; called Bash c1; result p1 c1 2400; called Bash c2; result p1 c2 2400; said p1 'x'; } > "$W/after-long.jsonl"
out="$(read_turn "$W/after-long.jsonl" 3000 8000 5000)"
has "a turn that follows a long one is read to its own first record" "$out" "refused=1"
has "and the walk stops there, inside its limit" "$out" "cut=false"

# A turn with nothing before it: the walk ends at the record's first byte.
{ prompt p1; refused p1 automode-blocked; for n in 1 2 3 4; do called Bash "c$n"; result p1 "c$n" 2400; done; said p1 'x'; } > "$W/whole.jsonl"
out="$(read_turn "$W/whole.jsonl" 3000 1000000 5000)"
has "a turn that starts the record is read to the record's first byte" "$out" "refused=1"
has "and is not cut short" "$out" "cut=false"

# The record the window's first byte lands inside is read whole by the walk, once.
{ prompt p1; refused p1 automode-blocked; } > "$W/straddle.jsonl"
head_bytes="$(wc -c < "$W/straddle.jsonl" | tr -d ' ')"
{ called Bash c1; result p1 c1 1500; said p1 'x'; } >> "$W/straddle.jsonl"
all_bytes="$(wc -c < "$W/straddle.jsonl" | tr -d ' ')"
out="$(read_turn "$W/straddle.jsonl" "$((all_bytes - head_bytes + 200))" 1000000 5000)"
has "a refusal the window's first byte lands inside is counted, once" "$out" "refused=1"

# What the walk back reads besides refusals: this mod's own hold, and a step pinned.
{ prompt p0; said p0 'earlier'; prompt p1; refused p1 automode-blocked; feedback p1; said p1 'Nothing from the refusal is yours to do.'; for n in 1 2 3 4; do called Bash "c$n"; result p1 "c$n" 2400; done; said p1 'x'; } > "$W/held.jsonl"
out="$(read_turn "$W/held.jsonl" 3000 1000000 5000)"
has "this mod's own hold further back than the window is seen" "$out" "ours=true"
has "and the refusal before it has been asked about" "$out" "unasked=0"
{ prompt p0; said p0 'earlier'; prompt p1; refused p1 automode-blocked; called "$STEPS" s1; result p1 s1 6; for n in 1 2 3 4; do called Bash "c$n"; result p1 "c$n" 2400; done; said p1 'x'; } > "$W/pinned.jsonl"
has "a step pinned further back than the window answers the refusal before it" "$(read_turn "$W/pinned.jsonl" 3000 1000000 5000)" "refused=0"

# ---- At the sizes the mod runs with: a refusal 5 MB back ----
{ prompt p0; said p0 'earlier'; prompt p1; called Bash c0; refused p1 automode-blocked; for n in 1 2 3 4 5; do called Bash "c$n"; result p1 "c$n" 1048576; done; said p1 'The row is still yours.'; } > "$W/five.jsonl"
out="$(read_turn "$W/five.jsonl")"
has "with the mod's own limits, a refusal 5 MB back is counted" "$out" "refused=1"
has "and the turn was read to its first record" "$out" "cut=false"

# ---- A steps tool call's result ----
{ prompt p1; refused p1 automode-blocked; called "$STEPS" s1; failed p1 s1; said p1 'It is on the card.'; } > "$W/failed.jsonl"
out="$(read_turn "$W/failed.jsonl")"
has "a steps tool call whose result is an error does not answer the refusal before it" "$out" "refused=1"
has "and pinned nothing" "$out" "pinned=false"
{ prompt p1; refused p1 automode-blocked; called "$STEPS" s1; result p1 s1 6; said p1 'It is on the card.'; } > "$W/worked.jsonl"
out="$(read_turn "$W/worked.jsonl")"
has "a steps tool call that worked answers it" "$out" "refused=0"
has "and pinned a step" "$out" "pinned=true"
{ prompt p1; refused p1 automode-blocked; called "$STEPS" s1; result p1 s1 6; called Bash c2; failed p1 c2; said p1 'x'; } > "$W/other.jsonl"
has "another call's failure is not the steps tool call's" "$(read_turn "$W/other.jsonl")" "refused=0"

# ---- A transcript that is not there ----
# Said with the bare path first, which is how the mod tells it from a read that failed part way.
has "a transcript that is not there is named by its bare path" "$(read_turn "$W/none.jsonl")" "outkb=0 $W/none.jsonl: No such file or directory"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
