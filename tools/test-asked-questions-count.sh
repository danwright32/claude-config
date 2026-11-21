#!/usr/bin/env bash
# Tests for tools/asked-questions-count.ts, the reader of the sizes recorded of each question a mod
# asks Dan through its own dialog (claude-config#3321; Dan, 2026-11-21: "Record, then decide"). The
# records here are made up, in the shape payload/mods/mod-kit/hooks/asked.ts writes them: sizes and
# names, never a question's text, which the records do not hold either.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo "SUITE-UNMEASURED node is not installed, so the reader could not be run"
  exit 0
fi
pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
has(){ case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "wanted: $3 / got: $2" ;; esac; }
lacks(){ case "$2" in *"$3"*) check "$1" "did not want: $3 / got: $2" ;; *) check "$1" ok ;; esac; }
TOOL="$DIR/asked-questions-count.ts"
W="$(mktemp -d "${TMPDIR:-/tmp}/asked-questions-count.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
D="$W/asked"
mkdir -p "$D"

# One record as asked.ts writes it, given in order: when it was asked, the mod, which question,
# its units, its rows, and whether the check would refuse it. These are made up, not measured.
rec(){ printf '{"at":%s,"mod":"%s","which":"%s","units":%s,"rows":%s,"options":2,"longest":9,"header":0,"refused":%s}\n' "$1" "$2" "$3" "$4" "$5" "$6" > "$D/$1-abc$4.json"; }
# 2026-11-21 and 2026-11-22, noon UTC.
A=1795262400000; B=1795348800000
# Twenty of one question, so its 95th percentile is the 19th smallest: units 10 to 200 by tens.
for i in $(seq 1 20); do rec "$((A + i))" scope-modes before-bed "$((i * 10))" "$i" false; done
rec "$((B + 1))" scope-modes leave-branch 300 7 true
rec "$((B + 2))" scope-modes leave-branch 40 2 false
rec "$((B + 3))" keystroke-guard confirm 80 3 false
# Not records: a file of another name, a record that is not JSON, and one whose sizes are not numbers.
printf 'notes\n' > "$D/README.txt"
printf 'not json\n' > "$D/$((B + 4))-bad.json"
printf '{"at":1,"mod":"scope-modes","which":"before-bed","units":"many","rows":2,"options":2,"longest":9,"header":0,"refused":false}\n' > "$D/$((B + 5))-odd.json"

out="$(node "$TOOL" --dir "$D" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "the reader runs and exits 0" ok || check "the reader runs and exits 0" "exit=$code out=$out"
has "it says how many records it read, over which days, and how many it could not read" "$out" "23 questions recorded from 2026-11-21 to 2026-11-22 (2 records could not be read and are left out)."
has "one line a mod's question: count, units longest and at the 95th percentile, rows likewise, how many refused" "$out" "scope-modes before-bed: 20 asked; units longest 200, 95th percentile 190; rows longest 20, 95th percentile 19; the check would refuse 0."
has "a question the check would refuse is counted as refused" "$out" "scope-modes leave-branch: 2 asked; units longest 300, 95th percentile 300; rows longest 7, 95th percentile 7; the check would refuse 1."
has "each mod is counted apart" "$out" "keystroke-guard confirm: 1 asked; units longest 80, 95th percentile 80; rows longest 3, 95th percentile 3; the check would refuse 0."
has "and the whole, so a reading in two weeks is one line" "$out" "In all: 23 asked, the check would refuse 1."
lacks "a file of another name is no record" "$out" "README"

# The lines come in a fixed order (mod, then question), so two readings compare line for line.
first="$(printf '%s\n' "$out" | grep -n 'keystroke-guard confirm' | cut -d: -f1)"
second="$(printf '%s\n' "$out" | grep -n 'scope-modes before-bed' | cut -d: -f1)"
[ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] && check "lines are in the order of mod and question" ok || check "lines are in the order of mod and question" "$out"

# --since leaves out what was asked before the day given.
out="$(node "$TOOL" --dir "$D" --since 2026-11-22 2>&1)"
has "--since counts only what was asked on or after that day" "$out" "3 questions recorded from 2026-11-22 to 2026-11-22"
lacks "and leaves the earlier question out" "$out" "before-bed"

# Each way it can end is its own exit code and says why (L11).
out="$(node "$TOOL" --dir "$W/none" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "a folder not made yet is no question asked, exit 0" ok || check "a folder not made yet is no question asked, exit 0" "exit=$code out=$out"
has "and says the folder is not there, not that nothing was asked" "$out" "No question has been recorded on this Mac: $W/none is not there."
printf 'x\n' > "$W/file"
out="$(node "$TOOL" --dir "$W/file" 2>&1)"; code=$?
[ "$code" -eq 3 ] && check "a folder that cannot be read exits 3" ok || check "a folder that cannot be read exits 3" "exit=$code out=$out"
has "and says nothing was counted" "$out" "could not be read"
out="$(node "$TOOL" --sideways 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "an argument it does not know exits 2" ok || check "an argument it does not know exits 2" "exit=$code"
has "and says which" "$out" '"--sideways" is not understood'
out="$(node "$TOOL" --dir "$D" --since yesterday 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a day not written as a date exits 2" ok || check "a day not written as a date exits 2" "exit=$code"
mkdir -p "$W/empty"
out="$(node "$TOOL" --dir "$W/empty" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "a folder holding no record is counted as none, exit 0" ok || check "a folder holding no record is counted as none, exit 0" "exit=$code"
has "and says none was recorded" "$out" "0 questions recorded"

# With no --dir it reads the folder asked.ts writes to under HOME.
mkdir -p "$W/home/.claude/state/asked-questions"
cp "$D/$((B + 3))-abc80.json" "$W/home/.claude/state/asked-questions/"
out="$(HOME="$W/home" node "$TOOL" 2>&1)"
has "with no --dir it reads the folder asked.ts writes to under HOME" "$out" "keystroke-guard confirm: 1 asked"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
