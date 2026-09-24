#!/usr/bin/env bash
# Tests for tools/lesson-citations.py, the counter claude-config#563 ranks the lessons core by.
#
# The 2026-09-24 ranking counted lesson numbers written into code, commits and pull request bodies
# (84 percent of this Mac's pairs), so it measured annotation habit rather than use. This counter
# reads only Claude's PROSE: assistant text blocks, never tool inputs (Write and Edit content,
# heredocs, commit and PR bodies all live there), never thinking, never a subagent, never a
# claude-config session, never the session doing the recording. Each exclusion has a fixture that
# would be counted without it (L159).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/lesson-citations.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (must not contain '$2')"; fi; }
row(){ printf '%s\n' "$1" | awk -F '\t' -v k="$2" '$1 == k'; }

P="$WORK/projects"
mk(){ # mk <project dir> <session> <json records...>: one transcript
  mkdir -p "$P/$1"
  local f="$P/$1/$2.jsonl"; shift 2
  : > "$f"
  for r in "$@"; do printf '%s\n' "$r" >> "$f"; done
}
text(){ printf '{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"%s"}]}}' "$1"; }
tool(){ printf '{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}' "$1"; }
think(){ printf '{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"thinking","thinking":"%s"}]}}' "$1"; }
side(){ printf '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"%s"}]}}' "$1"; }
user(){ printf '{"type":"user","message":{"content":"%s"}}' "$1"; }

# Session A (Slate): prose cites L1 twice and L2 once; a commit in a tool call cites L3; thinking
# cites L4; a sidechain cites L5; the user message cites L6; a #L7 line anchor; code fence cites L8.
mk "-Users-x-Slate" sessA \
  "$(text 'This repeats L1: a guard never seen to fail. And L1 again, plus L2.')" \
  "$(tool 'git commit -m \"fix (L3)\"')" \
  "$(think 'maybe L4 applies')" \
  "$(side 'the subagent says L5')" \
  "$(user 'please check L6')" \
  "$(text 'See file.sh#L7 for the line.')" \
  "$(text 'Before ```\nexport const x = 1 // L8\n``` after')"
# Session D: dismissals. A sentence saying a lesson does NOT apply, usually a reply to the push time
# lessons advisory, is not a use of it; measured 2026-09-24, the advisory's own picks (L5, L7, L9,
# L290, L524) topped the prose ranking that way. The same session applies L12 for real.
mk "-Users-x-Ovation" sessD \
  "$(text 'The advisory flags L21, L22 and L23, which do not apply: the rm is the test temp dir.')" \
  "$(text 'L24 does not apply here; the sleep is a condition poll.')" \
  "$(text 'Showing success only after the write commits, per L12.')"
# Session B (Overture): prose cites L1 once.
mk "-Users-x-Overture" sessB "$(text 'Per L1 the test must fail first.')"
# A claude-config session: cites L2, excluded.
mk "-Users-x-Non-icloudDocuments-Apps-claude-config" sessC "$(text 'L2 matters here')"
# A subagent transcript on disk: excluded.
mk "-Users-x-Slate/sessA/subagents" agent1 "$(text 'agent cites L9')"
# The recording session itself: excluded by id.
mk "-Users-x-Slate" sessREC "$(text 'while recording, L10 and L1')"

LEDGER="$WORK/citations.tsv"
# Dated from the clock, never a literal, so the rows stay inside the window as real time passes (L130).
now_s="$(date +%s)"
printf '%s\tpr\tSlate\tabc\t2\tL1,L11\n%s\tpush\tSlate\tdef\t1\tL11\n' "$((now_s - 86400))" "$((now_s - 3600))" > "$LEDGER"
# And one row older than the window, which must not count.
printf '%s\tpr\tSlate\told\t1\tL11\n' "$((now_s - 90 * 86400))" >> "$LEDGER"

out="$(python3 "$TOOL" --projects "$P" --days 60 --exclude-session sessREC --ledger "$LEDGER" 2>&1)"; rc=$?
check "the run succeeds" "END" "$out"
[ "$rc" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: exit $rc"; }
check "L1: two sessions of prose, three mentions, one review" $'L1\t2\t3\t1' "$(row "$out" L1)"
check "L2: one session of prose (the claude-config session is not counted)" $'L2\t1\t1\t0' "$(row "$out" L2)"
check_not "a lesson number in a tool call is not prose" "L3	" "$out"
check_not "thinking is not prose" "L4	" "$out"
check_not "a sidechain record is a subagent" "L5	" "$out"
check_not "the user's own words are not Claude's" "L6	" "$out"
check_not "a #L7 line anchor is not a lesson" "L7	" "$out"
check_not "a number inside a code fence is code" "L8	" "$out"
check_not "a subagent transcript is not counted" "L9	" "$out"
check_not "the recording session is not counted" "L10	" "$out"
check_not "a lesson dismissed as not applying is not counted" "L21	" "$out"
check_not "nor one dismissed in a sentence of its own" "L24	" "$out"
check "a lesson applied in the same session is counted" $'L12\t1\t1\t0' "$(row "$out" L12)"
check "the header says how many dismissals were set aside" "DISMISSED 4" "$out"
check "a lesson cited only by reviews still appears" $'L11\t0\t0\t2' "$(row "$out" L11)"
check "the header says what was read and what was excluded" "EXCLUDED" "$out"

# A ledger that exists but cannot be read says so, never "yes" beside zero review citations (L11).
mkdir -p "$WORK/ledger-dir"
out="$(python3 "$TOOL" --projects "$P" --days 60 --exclude-session sessREC --ledger "$WORK/ledger-dir" 2>&1)"
check "an unreadable ledger is named as unreadable" "LEDGER unreadable" "$out"
out="$(python3 "$TOOL" --projects "$P" --days 60 --exclude-session sessREC --ledger "$WORK/absent.tsv" 2>&1)"
check "an absent ledger is named as absent" "LEDGER absent" "$out"

# Nothing readable is a refusal, never an empty table (L98).
out="$(python3 "$TOOL" --projects "$WORK/nothing" --days 60 --ledger "$LEDGER" 2>&1)"; rc=$?
check "no transcript read says so" "NOTHING READ" "$out"
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: nothing read must not exit 0"; }

# Precision sampling: --sample prints each prose sentence for the lessons named, for a person to judge.
out="$(python3 "$TOOL" --projects "$P" --days 60 --exclude-session sessREC --ledger "$LEDGER" --sample L2 2>&1)"
check "a sample shows the sentence that cited the lesson" "plus L2" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
