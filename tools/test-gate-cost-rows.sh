#!/usr/bin/env bash
# Tests for tools/gate-cost-rows.py: one row per drafts gate cost case per run, read from saved log
# text (claude-config#3170). Since 2026-11-21 every run of test-slack-drafts-only-gate.sh prints, for
# each cost case, the gate's processor seconds for each reading, the yardstick each reading was
# divided by, and every yardstick sample, so that timing the yardstick the way the gate is timed can
# be judged from a few days of CI runs (Dan's decision of 2026-11-21, "Measure more first"). The
# tool reads the three shapes those figures are printed in, and its check subcommand is what the
# drafts gate suite uses to hold the printed figures to the verdict.
#
# Every fixture line here is invented, its arithmetic worked by hand: eleven yardstick samples, three
# readings each divided by the least of the samples taken by then (the first 7, 9 and 11).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/gate-cost-rows.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
has(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:2000}"; fi; }

# The body every record shares, with yardstick samples whose least of the first 7 is 0.0832 and of
# the first 9 and 11 is 0.0829: 2.560 / 0.0832 is 30.8, 2.541 / 0.0829 is 30.7, 2.600 / 0.0829 is 31.4.
Y='0.0850, 0.0832, 0.0841, 0.0839, 0.0845, 0.0836, 0.0844, 0.0829, 0.0851, 0.0838, 0.0833'
BODY="2.54 s of processor time, unit 0.083 s, ceiling 36.0, samples 30.8, 30.7, 31.4; seconds per reading 2.560, 2.541, 2.600; yardstick per reading 0.0832 from 7, 0.0829 from 9, 0.0829 from 11; yardstick 11 samples $Y; yardstick least 0.0829, median 0.0839, greatest 0.0851"
GOOD="one-lesson nfig/claude-sync lesson L174: 30.7 ($BODY)"
ROW="$(printf 'one-lesson\t36.0\t30.7\t30.8, 30.7, 31.4\t2.560, 2.541, 2.600\t0.083\t0.0832, 0.0829, 0.0829\t11\t0.0829\t0.0839\t0.0851\tno')"

# 1. A line as the suite prints it, prefixed "cost measured (#2918): ".
printf 'noise before\ncost measured (#2918): %s\nnoise after\n' "$GOOD" > "$WORK/local.txt"
out="$(python3 -B "$TOOL" rows "$WORK/local.txt" 2>&1)"; rc=$?
check "rows exits 0 on a file holding a cost line" "$([ "$rc" = 0 ] && echo ok || echo "exit $rc: $out")"
has "the header names every column" "$(printf 'run\tcase\tlimit\tleast\treadings in units\treadings in seconds\tyardstick used\tyardstick per reading\tyardstick samples\tyardstick least\tyardstick median\tyardstick greatest\tstep clock')" "$out"
has "a cost measured line becomes one row with every figure" "$(printf 'local.txt\t%s' "$ROW")" "$out"
n="$(printf '%s\n' "$out" | grep -c '^local.txt' || true)"
check "and only one row" "$([ "$n" = 1 ] && echo ok || echo "$n rows")"

# 2. A passing CI run: only the notes run-all-tests prints, the suite-cold note and the one note
# carrying every other case, whose entries are separated by " | ". One of them read on the step clock.
SC="suite-cold LINE: 60.4 (5.62 s of processor time, unit 0.093 s, ceiling 77.0, samples 60.4; seconds per reading 5.620; yardstick per reading 0.0930 from 7; yardstick 7 samples 0.0931, 0.0930, 0.0950, 0.0940, 0.0933, 0.0960, 0.0944; yardstick least 0.0930, median 0.0940, greatest 0.0960)"
cold_body="${SC#*: 60.4 (}"; cold_body="${cold_body%)}"
STEP="short-budget 1.9 (0.19 s of processor time, unit 0.100 s, ceiling 36.0, samples 1.9; the gate's 11 s ran out on this machine, after 0.3 s at 0.100 s a unit, so those were read on the step clock; seconds per reading 0.190; yardstick per reading 0.1000 from 9; yardstick 9 samples 0.1000, 0.1010, 0.1020, 0.1030, 0.1040, 0.1050, 0.1060, 0.1070, 0.1080; yardstick least 0.1000, median 0.1040, greatest 0.1080)"
{
  printf '  ok    payload/hooks/test-slack-drafts-only-gate.sh   900 passed   540s\n'
  printf '          note: drafts gate on Linux, bash tests/test-claude-sync.sh from an empty cache: at 60.4 (%s) (#3167)\n' "$cold_body"
  printf '          note: drafts gate costs on Linux, in units of the yardstick, each case read from an empty cache unless named warm: one-lesson 30.7 (%s) | %s (#3170)\n' "$BODY" "$STEP"
} > "$WORK/ci.txt"
out="$(python3 -B "$TOOL" rows "$WORK/ci.txt" 2>&1)"
n="$(printf '%s\n' "$out" | grep -c '^ci.txt' || true)"
check "a CI log's two notes give a row for each of their three cases" "$([ "$n" = 3 ] && echo ok || echo "$n rows: $out")"
has "the suite-cold note gives its row" "$(printf 'ci.txt\tsuite-cold\t77.0\t60.4\t60.4\t5.620\t0.093\t0.0930\t7\t0.0930\t0.0940\t0.0960\tno')" "$out"
has "an entry of the costs note gives its row" "$(printf 'ci.txt\t%s' "$ROW")" "$out"
has "a reading taken on the step clock says so" "$(printf 'ci.txt\tshort-budget\t36.0\t1.9\t1.9\t0.190\t0.100\t0.1000\t9\t0.1000\t0.1040\t0.1080\tyes')" "$out"

# A costs note holding one case has no " | " in it, and its record's own "; yardstick 9 samples"
# must not be read as the start of a second, older style entry.
printf '          note: drafts gate costs on Linux, every case but suite-cold, in units of the yardstick and how each was read: %s (#3170)\n' "$STEP" > "$WORK/one.txt"
out="$(python3 -B "$TOOL" rows "$WORK/one.txt" 2>&1)"
has "a costs note with one case gives that case whole" "$(printf 'one.txt\tshort-budget\t36.0\t1.9\t1.9\t0.190\t0.100\t0.1000\t9\t0.1000\t0.1040\t0.1080\tyes')" "$out"

# 3. One run's file holding both shapes (a red run's kept output prints the cost lines and the notes):
# each case once, from the cost lines, never twice.
cat "$WORK/local.txt" "$WORK/ci.txt" > "$WORK/both.txt"
printf 'cost measured (#2918): %s\n' "$SC" >> "$WORK/both.txt"
out="$(python3 -B "$TOOL" rows "$WORK/both.txt" 2>&1)"
n="$(printf '%s\n' "$out" | grep -c '^both.txt' || true)"
check "a file holding cost lines and notes gives each case once, from the cost lines" "$([ "$n" = 2 ] && echo ok || echo "$n rows: $out")"

# 4. A line from before 2026-11-21, without the new figures: still a row, the missing figures as "-".
printf 'cost measured (#2918): three-lessons LINE: 55.0 (4.40 s of processor time, unit 0.080 s, ceiling 66.0, samples 55.0)\n' > "$WORK/old.txt"
out="$(python3 -B "$TOOL" rows "$WORK/old.txt" 2>&1)"
has "an older line gives a row with what it holds and a dash for the rest" "$(printf 'old.txt\tthree-lessons\t66.0\t55.0\t55.0\t-\t0.080\t-\t-\t-\t-\t-\tno')" "$out"
# And the older costs note, whose entries were "<case> <least> (<readings>)" separated by "; ".
printf '          note: drafts gate costs on Linux from an empty cache, in units of the yardstick, the least and then every reading: one-lesson 30.1 (30.1, 30.4, 31.0); suite-warm 1.9 (1.9) (#3170)\n' > "$WORK/oldnote.txt"
out="$(python3 -B "$TOOL" rows "$WORK/oldnote.txt" 2>&1)"
has "the older costs note gives a row per case" "$(printf 'oldnote.txt\tone-lesson\t-\t30.1\t30.1, 30.4, 31.0\t-')" "$out"
has "including its last case" "$(printf 'oldnote.txt\tsuite-warm\t-\t1.9\t1.9\t-')" "$out"

# 5. Two files, two runs: each row names its own.
out="$(python3 -B "$TOOL" rows "$WORK/local.txt" "$WORK/old.txt" 2>&1)"
has "rows from the first file name it" "$(printf 'local.txt\tone-lesson')" "$out"
has "rows from the second file name it" "$(printf 'old.txt\tthree-lessons')" "$out"

# 6. A file with no cost line at all is said, and fails, rather than printing an empty table (L98).
printf 'nothing here\n' > "$WORK/empty.txt"
out="$(python3 -B "$TOOL" rows "$WORK/empty.txt" 2>&1)"; rc=$?
check "a file with no cost line exits 1" "$([ "$rc" = 1 ] && echo ok || echo "exit $rc")"
has "and names the file" "empty.txt holds no drafts gate cost line" "$out"
out="$(python3 -B "$TOOL" rows "$WORK/missing.txt" 2>&1)"; rc=$?
check "a file that is not there exits 1, never a row" "$([ "$rc" = 1 ] && echo ok || echo "exit $rc: $out")"

# 7. check: the verdict reading is the gate's seconds over the least yardstick sample taken by then,
# and nothing printed beside it. Each doctored record breaks one link and must be refused (L1).
printf '%s\n' "$GOOD" > "$WORK/good.log"
out="$(python3 -B "$TOOL" check "$WORK/good.log" 2>&1)"; rc=$?
check "check passes a record whose figures agree with its verdict" "$([ "$rc" = 0 ] && [ "$out" = ok ] && echo ok || echo "exit $rc: $out")"
printf '%s\n' "$STEP" | sed 's/^short-budget /short-budget LINE: /' > "$WORK/step.log"
out="$(python3 -B "$TOOL" check "$WORK/step.log" 2>&1)"
check "check passes a reading taken on the step clock, 9 samples before its first reading" "$([ "$out" = ok ] && echo ok || echo "$out")"
# The median put where the least was: what using a printed only figure for the verdict looks like.
printf '%s\n' "$GOOD" | sed 's/0\.0829 from 11/0.0839 from 11/; s/samples 30\.8, 30\.7, 31\.4/samples 30.8, 30.7, 31.0/' > "$WORK/median.log"
out="$(python3 -B "$TOOL" check "$WORK/median.log" 2>&1)"; rc=$?
check "check refuses a reading divided by the median rather than the least sample" "$([ "$rc" = 1 ] && echo ok || echo "exit $rc: $out")"
has "and says which reading" "reading 3 was divided by 0.0839, but the least of the first 11 yardstick samples is 0.0829" "$out"
printf '%s\n' "$GOOD" | sed 's/samples 30\.8, 30\.7, 31\.4/samples 30.8, 29.0, 31.4/; s/: 30\.7 (/: 29.0 (/' > "$WORK/ratio.log"
out="$(python3 -B "$TOOL" check "$WORK/ratio.log" 2>&1)"
has "check refuses a reading that is not its seconds over its yardstick" "reading 2 is 29.0 units, but 2.541 s over 0.0829 s is 30.7" "$out"
printf '%s\n' "$GOOD" | sed 's/: 30\.7 (/: 31.4 (/' > "$WORK/least.log"
out="$(python3 -B "$TOOL" check "$WORK/least.log" 2>&1)"
has "check refuses a judged reading that is not the least of the readings" "judged at 31.4, but the least reading is 30.7" "$out"
printf '%s\n' "$GOOD" | sed 's/from 7, /from 5, /' > "$WORK/count.log"
out="$(python3 -B "$TOOL" check "$WORK/count.log" 2>&1)"
has "check refuses a sample schedule other than 5 before and 2 after each judgement" "the first reading was divided by the least of 5 samples, not of 7 (or 9 where the seconds ran out)" "$out"
printf 'one-lesson LINE: 30.1 (2.50 s of processor time, unit 0.083 s, ceiling 36.0, samples 30.1)\n' > "$WORK/bare.log"
out="$(python3 -B "$TOOL" check "$WORK/bare.log" 2>&1)"; rc=$?
check "check refuses a record without the per reading figures" "$([ "$rc" = 1 ] && echo ok || echo "exit $rc: $out")"
has "and names what is missing" "one-lesson: no seconds per reading" "$out"
# Two readings printed alike, 30.7 each, with different seconds and yardsticks: the judged figures
# are those of either one, so the second one's must be accepted. 2.541 / 0.0829 and 2.551 / 0.0832
# both print 30.7, and the record's 2.54 s is the second's, never the first's.
printf '%s\n' "$GOOD" | sed 's/seconds per reading 2\.560, 2\.541, 2\.600; yardstick per reading 0\.0832 from 7, 0\.0829 from 9/seconds per reading 2.551, 2.541, 2.600; yardstick per reading 0.0832 from 7, 0.0829 from 9/; s/samples 30\.8, 30\.7, 31\.4/samples 30.7, 30.7, 31.4/' > "$WORK/tie.log"
out="$(python3 -B "$TOOL" check "$WORK/tie.log" 2>&1)"
check "check accepts the judged figures of either of two readings that print alike" "$([ "$out" = ok ] && echo ok || echo "$out")"
: > "$WORK/none.log"
out="$(python3 -B "$TOOL" check "$WORK/none.log" 2>&1)"; rc=$?
check "check on a log holding no record fails rather than passing nothing" "$([ "$rc" = 1 ] && echo ok || echo "exit $rc: $out")"

# 8. It reads files and calls nothing: only these modules, so no network library can creep in.
imports="$(python3 -B -c 'import ast, sys
names = set()
for n in ast.walk(ast.parse(open(sys.argv[1]).read())):
    if isinstance(n, ast.Import):
        names.update(a.name.split(".")[0] for a in n.names)
    elif isinstance(n, ast.ImportFrom):
        names.add((n.module or "").split(".")[0])
    elif isinstance(n, ast.Call) and getattr(n.func, "id", "") == "__import__":
        names.add("__import__")
print(" ".join(sorted(names)))' "$TOOL" 2>&1)"
check "the tool imports only os, re, statistics and sys" "$([ "$imports" = "os re statistics sys" ] && echo ok || echo "it imports: $imports")"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
