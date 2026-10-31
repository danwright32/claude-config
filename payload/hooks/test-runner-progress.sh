#!/usr/bin/env bash
# Tests for the line run-all-tests.sh prints as each suite finishes (claude-config#1979).
#
# The runner printed its header and then nothing until every suite had finished, because it sorts
# the results before printing them: about 15 minutes on a quiet Mac. Run in the background, as
# builders do several times a session, the job watcher reported it as "no new output for 11
# minutes" while it was healthy, and nobody reading the output could tell a working run from a hung
# one (the class of #1583). So each suite's finish now prints one line, and the sorted report at the
# end is unchanged.
#
# The new line lands in front of every reader of the runner's output, so the second half of this
# file runs it past each of them (L683), found by what they parse rather than by who calls the
# runner: claude-sync's pull and recheck (tests/test-claude-sync.sh, the #188 section, reads a real
# run's output end to end), the runner's own reading of a suite's output when that output carries a
# nested run, the CI workflow's step that reads the run's log, the FAIL readers of the scanners gate
# and tools/prove-it-fails.sh, the job watcher (which calls a job stuck when its last lines repeat),
# and this repository's own suites, which anchor on `^run-all-tests: `.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$DIR/run-all-tests.sh"

if [ ! -f "$DIR/lib/suite-deadline.sh" ]; then
  echo "FAIL: test-runner-progress: no helper at $DIR/lib/suite-deadline.sh, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
. "$DIR/lib/suite-deadline.sh"
suite_deadline_arm || exit $?
. "$DIR/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing, so this suite's waits have no ceiling."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.runner-progress.XXXXXXXX")" || T=""
case "${T%/}" in
  ''|/|"${HOME%/}") echo "test-runner-progress: refusing to run: throwaway directory came back as '$T'." >&2; exit 2 ;;
esac
trap 'rm -rf "$T"' EXIT

# The agreed result line, assembled at run time so this file is not itself an occurrence of it.
MARK="SUITE""-RESULT"
# The prefix every progress line starts with. Typed here rather than read from the runner, so a
# change to it in the runner fails this file and is decided on purpose, against the readers below.
PREFIX='run-all-tests progress: '

# No fixture run inherits the deadline, the live store hand over or the spool of the run this suite
# is part of; every live store seam points into the throwaway directory (test-live-settings-edit.sh
# does the same), so a fixture run brackets nothing real.
unset HOOK_TESTS_DEADLINE HOOK_TESTS_DEADLINE_RESERVE HOOK_TESTS_JOB_STARTED HOOK_TESTS_NOW GITHUB_ACTIONS GITHUB_WORKFLOW_REF GITHUB_JOB
unset HOOK_TESTS_LIVE_BRACKETED HOOK_TESTS_LIVE_BRACKETED_RUN
mkdir -p "$T/cfg" "$T/spool"
printf '%s\n' "$T/no-such-clone" > "$T/registry"
fixture_run(){ # fixture_run <suites dir>: the runner over that directory, two suites at once
  env -u CI \
    CLAUDE_HOME="$T/cfg" \
    SYNC_CLONE_REGISTRY="$T/registry" \
    SYNC_ZSHRC="$T/zshrc" \
    SYNC_WATCH_PID_FILE="$T/watch.pid" \
    SYNC_HOLD_FILE="$T/hold" \
    CLAUDE_ISSUE_SPOOL_DIR="$T/spool" \
    HOOK_TESTS_FLAKY_OUTPUT="$T/flaky" \
    HOOK_TESTS_ROOT="$T" HOOK_TESTS_TIMINGS= HOOK_TESTS_JOBS=2 HOOK_TESTS_FLAKE_RECHECK=0 \
    bash "$RUNNER" "$1" 2>&1
}
mk_result_suite(){ # mk_result_suite <dir> <name> <passed> <failed> <exit>
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    [ "$4" -eq 0 ] || printf 'echo "FAIL: a check in %s"\n' "$2"
    printf 'printf %s\\\\n "%s passed=%s failed=%s"\n' "'%s'" "$MARK" "$3" "$4"
    printf 'exit %s\n' "$5"
  } > "$1/test-$2.sh"
  chmod +x "$1/test-$2.sh"
}

# ---- 1. The output grows while suites are still running ----
# Two suites at once. One finishes straight away; the other passes only if the runner's own output
# gains the first one's progress line while it is itself still running, and it also notes whether the
# sorted report had begun by then. Its wait is on that condition, under the one ceiling only a hang
# reaches (lib/hang-wait.sh), never a fixed time (L290). Before #1979 the line never came, so the
# waiting suite reached the ceiling and failed.
G="$T/grow"; GLOG="$T/grow.log"; GSEEN="$T/grow.seen"
mk_result_suite "$G" first 1 0 0
{
  printf '#!/usr/bin/env bash\n'
  printf '. "%s"\n' "$DIR/lib/hang-wait.sh"
  printf 'if hang_wait %q; then\n' "grep -q '^${PREFIX}.*test-first\\.sh exited 0\$' \"$GLOG\""
  printf '  if grep -q -E "^ +(ok|FAIL) " "%s"; then echo report-begun > "%s"; else echo report-not-begun > "%s"; fi\n' "$GLOG" "$GSEEN" "$GSEEN"
  printf '  printf %s\\\\n "%s passed=1 failed=0"\n' "'%s'" "$MARK"
  printf 'else\n'
  printf '  echo "FAIL: no progress line for test-first.sh reached the runner output while this suite was still running"\n'
  printf '  printf %s\\\\n "%s passed=0 failed=1"\n' "'%s'" "$MARK"
  printf '  exit 1\n'
  printf 'fi\n'
} > "$G/test-waits.sh"
chmod +x "$G/test-waits.sh"
fixture_run "$G" > "$GLOG"; gcode=$?
gout="$(cat "$GLOG")"
printf '%s\n' "$gout" | grep -q -E '^ +ok +test-waits\.sh' \
  && check "#1979 the runner's output gains a line while another suite is still running" ok \
  || check "#1979 the runner's output gains a line while another suite is still running" "exit=$gcode out=$gout"
[ "$(cat "$GSEEN" 2>/dev/null)" = report-not-begun ] \
  && check "#1979 and that line arrives before the sorted report has begun" ok \
  || check "#1979 and that line arrives before the sorted report has begun" "seen='$(cat "$GSEEN" 2>/dev/null)' out=$gout"
[ "$gcode" -eq 0 ] \
  && check "#1979 and the run still passes" ok \
  || check "#1979 and the run still passes" "exit=$gcode out=$gout"

# ---- 2. What each line says ----
glines="$(printf '%s\n' "$gout" | grep -F "$PREFIX" || true)"
[ "$(printf '%s\n' "$glines" | grep -c .)" -eq 2 ] \
  && check "#1979 one progress line per suite" ok \
  || check "#1979 one progress line per suite" "lines=$glines"
# The count of suites done, of how many, the time since the run began, the suite and its exit status.
shape='^run-all-tests progress: [0-9]+ of [0-9]+ suite\(s\) finished, (([0-9]+h )?[0-9]+m )?[0-9]+[sm] in, test-[a-z]+\.sh exited [0-9]+$'
[ -z "$(printf '%s\n' "$glines" | grep -v -E "$shape")" ] \
  && check "#1979 each line carries the count, the time since the run began, the suite and its exit status" ok \
  || check "#1979 each line carries the count, the time since the run began, the suite and its exit status" "lines=$glines"
printf '%s\n' "$glines" | grep -q -E '^run-all-tests progress: 1 of 2 suite\(s\) finished, .* test-first\.sh exited 0$' \
  && printf '%s\n' "$glines" | grep -q -E '^run-all-tests progress: 2 of 2 suite\(s\) finished, .* test-waits\.sh exited 0$' \
  && check "#1979 the count goes up by one per suite, in the order they finished" ok \
  || check "#1979 the count goes up by one per suite, in the order they finished" "lines=$glines"
# The job watcher calls a job stuck when the end of its output is the same line, or the same short
# pass of lines, over and over (mods/job-watcher/hooks/jobs.ts). A count that rises on every line
# keeps any two of them apart, so a long run reads as working rather than as repeating itself.
[ "$(printf '%s\n' "$glines" | sort -u | grep -c .)" -eq "$(printf '%s\n' "$glines" | grep -c .)" ] \
  && check "#1979 no two progress lines are the same, so the job watcher cannot read them as repeating" ok \
  || check "#1979 no two progress lines are the same, so the job watcher cannot read them as repeating" "lines=$glines"

# A suite that fails says its exit status, and the sorted report below is as it always was: every
# progress line comes before the first verdict line, and the closing line keeps its shape.
F="$T/fails"
mk_result_suite "$F" bad 0 1 1
mk_result_suite "$F" good 1 0 0
fout="$(fixture_run "$F")"; fcode=$?
flines="$(printf '%s\n' "$fout" | grep -F "$PREFIX" || true)"
printf '%s\n' "$flines" | grep -q -E 'test-bad\.sh exited 1$' \
  && check "#1979 a failing suite's progress line gives its exit status" ok \
  || check "#1979 a failing suite's progress line gives its exit status" "out=$fout"
last_progress="$(printf '%s\n' "$fout" | grep -n -F "$PREFIX" | tail -1 | sed 's/:.*//')"
first_verdict="$(printf '%s\n' "$fout" | grep -n -E '^ +(ok|FAIL) +test-' | head -1 | sed 's/:.*//')"
{ [ -n "$last_progress" ] && [ -n "$first_verdict" ] && [ "$last_progress" -lt "$first_verdict" ]; } \
  && check "#1979 every progress line comes before the sorted report" ok \
  || check "#1979 every progress line comes before the sorted report" "last progress at '$last_progress', first verdict at '$first_verdict': $fout"
[ "$fcode" -ne 0 ] && printf '%s\n' "$fout" | tail -1 | grep -q -E '^1 of 2 SUITES FAILED: test-bad\.sh$' \
  && check "#1979 and the report still ends with its own verdict line, failing the run" ok \
  || check "#1979 and the report still ends with its own verdict line, failing the run" "exit=$fcode out=$fout"
printf '%s\n' "$gout" | tail -1 | grep -q -E '^ALL 2 SUITES PASSED$' \
  && check "#1979 and a passing run still ends with ALL N SUITES PASSED" ok \
  || check "#1979 and a passing run still ends with ALL N SUITES PASSED" "out=$gout"

# ---- 3. Every reader of the runner's output reads past the new lines (L683) ----
# The lines judged are the ones the runner really printed, a failing suite's among them, never a
# copy typed here (L48).
all_lines="$(printf '%s\n%s\n' "$glines" "$flines" | grep . || true)"
[ "$(printf '%s\n' "$all_lines" | grep -c .)" -ge 4 ] \
  && check "#1979 (control) the readers below are handed real progress lines" ok \
  || check "#1979 (control) the readers below are handed real progress lines" "lines=$all_lines"

# This repository's own readers anchor on `^run-all-tests: ` and something after it: the suite
# stopped at its wall clock (test-run-all-tests.sh), the launch order, the CI log's launch order
# line. The progress line shares no prefix with them, so none of those patterns can reach it.
[ -z "$(printf '%s\n' "$all_lines" | grep -E '^run-all-tests: ' || true)" ] \
  && check "#1979 no progress line starts with the runner's own 'run-all-tests: ' prefix" ok \
  || check "#1979 no progress line starts with the runner's own 'run-all-tests: ' prefix" "lines=$all_lines"
# The report's own verdict lines, read by test-run-all-tests.sh and by people, start with
# whitespace then ok, FAIL, NOT RUN or UNMEASURED; the summary lines start with ALL, a count, or NO.
# And a suite's own markers, read out of its output by the runner and the scanners gate, start SUITE-.
[ -z "$(printf '%s\n' "$all_lines" | grep -E '^[[:space:]]|^ALL |^[0-9]|^NO |^SUITE-|SUITES|SUITE\(S\)' || true)" ] \
  && check "#1979 no progress line has the shape of a verdict or summary line" ok \
  || check "#1979 no progress line has the shape of a verdict or summary line" "lines=$all_lines"

# The runner reading a SUITE's output that carries a nested run's progress lines, which is what a
# suite running the runner and printing what it said looks like (test-run-all-tests.sh does, on a
# failure). With the result line, the suite reads exactly as that line says; without it, the score
# guessed from prose is the suite's own tally, printed before the progress lines, so a progress line
# that read as a tally would have taken its place (the guess keeps the last such line).
N="$T/nested"; mkdir -p "$N"
printf '%s\n' "$all_lines" > "$T/nested.lines"
{
  printf '#!/usr/bin/env bash\n'
  printf 'cat "%s"\n' "$T/nested.lines"
  printf 'printf %s\\\\n "%s passed=1 failed=0"\n' "'%s'" "$MARK"
} > "$N/test-carries.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "passed: 3, failed: 0"\n'
  printf 'cat "%s"\n' "$T/nested.lines"
} > "$N/test-guessed.sh"
chmod +x "$N/test-carries.sh" "$N/test-guessed.sh"
nout="$(fixture_run "$N")"; ncode=$?
printf '%s\n' "$nout" | grep -q -E '^ +ok +test-carries\.sh +1 passed, 0 failed' \
  && check "#1979 a suite whose output carries progress lines reads as its result line says" ok \
  || check "#1979 a suite whose output carries progress lines reads as its result line says" "out=$nout"
printf '%s\n' "$nout" | grep -q -E '^ +ok +test-guessed\.sh +passed: 3, failed: 0' \
  && check "#1979 and a score guessed from prose is the suite's tally, not a progress line" ok \
  || check "#1979 and a score guessed from prose is the suite's tally, not a progress line" "out=$nout"
case "$nout" in
  *"PARTS UNMEASURED"*|*"command not found"*)
    check "#1979 and no progress line reads as a part unmeasured or a missing command" "out=$nout" ;;
  *) check "#1979 and no progress line reads as a part unmeasured or a missing command" ok ;;
esac
[ "$ncode" -eq 0 ] \
  && check "#1979 and that run passes" ok \
  || check "#1979 and that run passes" "exit=$ncode out=$nout"

# Readers that live outside payload/, read from the checkout where there is one. Each pattern is
# taken from the reader's own source, so a reader that changes what it matches is judged as it now
# is (L96).
CHECKOUT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null)" || CHECKOUT=""
if [ -n "$CHECKOUT" ] && [ -f "$CHECKOUT/.github/workflows/tests.yml" ] && [ -f "$CHECKOUT/tools/prove-it-fails.sh" ]; then
  WF="$CHECKOUT/.github/workflows/tests.yml"
  # The CI step that reads the run's log: its grep -m1 patterns, and the slots it reads with sed.
  wf_greps="$(grep -o "grep -m1 '[^']*'" "$WF" | sed "s/^grep -m1 '//; s/'\$//")"
  [ -n "$wf_greps" ] && grep -q 'slot(s) each' "$WF" \
    && check "#1979 the CI step's log patterns were read" ok \
    || check "#1979 the CI step's log patterns were read" "no grep -m1 pattern or slot(s) reader in $WF"
  wf_hit=""
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    printf '%s\n' "$all_lines" | grep -q -- "$pat" && wf_hit="$wf_hit [$pat]"
  done <<WFPATTERNS
$wf_greps
slot(s) each
WFPATTERNS
  [ -z "$wf_hit" ] \
    && check "#1979 no progress line matches what the CI step reads from the run's log" ok \
    || check "#1979 no progress line matches what the CI step reads from the run's log" "matched:$wf_hit"
  # tools/prove-it-fails.sh counts a run's FAIL lines, case blind.
  pif="$(grep -o "grep -icE '[^']*'" "$CHECKOUT/tools/prove-it-fails.sh" | head -1 | sed "s/^grep -icE '//; s/'\$//")"
  if [ -n "$pif" ]; then
    [ "$(printf '%s\n' "$all_lines" | grep -icE -- "$pif" || true)" = 0 ] \
      && check "#1979 tools/prove-it-fails.sh counts no progress line as a FAIL" ok \
      || check "#1979 tools/prove-it-fails.sh counts no progress line as a FAIL" "pattern $pif matched in: $all_lines"
  else
    check "#1979 tools/prove-it-fails.sh's FAIL pattern was read" "no grep -icE pattern in $CHECKOUT/tools/prove-it-fails.sh"
  fi
else
  echo "SUITE-PART-UNMEASURED the CI workflow's and tools/prove-it-fails.sh's readers, because this copy is not in a claude-config checkout, so neither is beside it"
fi
# The scanners gate, installed beside this file, keeps a scanner's FAIL lines with an awk pattern.
# The one naming FAIL, since the gate has other awk patterns (its comment readers come first).
sbp="$(grep -o "awk '/[^/]*FAIL[^/]*/" "$DIR/scanners-before-push.sh" | head -1 | sed "s#^awk '/##; s#/\$##")"
if [ -n "$sbp" ]; then
  [ -z "$(printf '%s\n' "$all_lines" | awk "/$sbp/" )" ] \
    && check "#1979 the scanners gate keeps no progress line as a FAIL line" ok \
    || check "#1979 the scanners gate keeps no progress line as a FAIL line" "pattern $sbp matched in: $all_lines"
else
  check "#1979 the scanners gate's FAIL pattern was read" "no awk pattern in $DIR/scanners-before-push.sh"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
