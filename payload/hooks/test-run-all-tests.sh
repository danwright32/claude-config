#!/usr/bin/env bash
# Tests for run-all-tests.sh, the thing that decides whether "all the tests passed" is true
# (claude-config#120).
#
# It discovered suites from disk rather than from a list, which was the right idea, but it looked
# in ONE directory: the one it lives in. Three suites live outside it and were run only because
# four hand-written steps in the CI workflow named them, and a fourth, payload/skills/milestone,
# was named by nothing at all and had never run anywhere. 233 checks, written down 2026-08-21, found by
# asking the repo
# rather than by reading the workflow. A suite nobody runs is indistinguishable from one that
# passes (L98), and a boundary drawn at one directory is the same hand-maintained list the runner's
# own header says it exists to avoid (L96).
#
# So the checks below care about two things: that a suite in a directory the runner does not live
# in is actually RUN, and that every way of reading nothing stays a failure rather than a quiet
# pass.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$DIR/run-all-tests.sh"

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

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.runner-test.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-run-all-tests: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# EVERY launch below reads a throwaway spool, not Dan's real one. 65 of the 69 launches in this
# file named no spool, so they bracketed the live one, and the cost of a launch was then set by how
# many files that happened to hold: 157 on this Mac on 2026-09-03, and the bracket forked once per
# file. That is a suite whose duration is a measurement of somebody else's machine (L224, L364),
# and it is a suite reading live data on every case (L2). The four cases that are ABOUT the spool
# bracket still name their own, which overrides this.
export CLAUDE_ISSUE_SPOOL_DIR="$TMPROOT/spool-default"
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"

# NOTHING below runs the runner without either naming a directory or pointing HOOK_TESTS_ROOT at a
# fixture. This file is itself a `test-*.sh` in a directory the runner reads, so a bare invocation
# would discover this suite and run it, from inside itself, for as long as the machine held out.
mk_suite() { # mk_suite <dir> <name> <exit code>
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\necho "passed: 1, failed: %s"\nexit %s\n' \
    "$( [ "$3" -eq 0 ] && echo 0 || echo 1 )" "$3" > "$1/test-$2.sh"
  chmod +x "$1/test-$2.sh"
}
mk_chatty_suite() { # mk_chatty_suite <dir> <name> <tally line>   -- a suite that talks first
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "%s"\n' "$3"
    printf 'echo "  ok: a check whose wording mentions a thing that passed"\n'
    printf 'echo "  ok: and another about something that failed"\n'
    printf 'exit 0\n'
  } > "$1/test-$2.sh"
  chmod +x "$1/test-$2.sh"
}

# A suite that says it cannot run HERE rather than reporting a score (claude-config#155).
mk_notrun_suite() { # mk_notrun_suite <dir> <name> <reason>
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "%s: %s"\n' "test-$2" "$3"
    printf 'printf %s\\\\n "SUITE-NOT-RUN %s"\n' "'%s'" "$3"
    printf 'exit 2\n'
  } > "$1/test-$2.sh"
  chmod +x "$1/test-$2.sh"
}

# ---------------------------------------------------------------------------
# Several directories, named outright.
# ---------------------------------------------------------------------------
A="$TMPROOT/dir-a"; B="$TMPROOT/dir-b"
mk_suite "$A" alpha 0
mk_suite "$B" beta 0
out_two="$(bash "$RUNNER" "$A" "$B" 2>&1)"; code_two=$?
[ "$code_two" -eq 0 ] \
  && check "two directories of passing suites pass" ok \
  || check "two directories of passing suites pass" "exit=$code_two out=$out_two"
printf '%s' "$out_two" | grep -q 'test-alpha.sh' && printf '%s' "$out_two" | grep -q 'test-beta.sh' \
  && check "and every suite in both is named in the report" ok \
  || check "and every suite in both is named in the report" "out=$out_two"

# A failure in the SECOND directory has to fail the run. The first directory being green is what
# the old single-directory reading amounted to, so this is the shape that used to pass.
mk_suite "$B" gamma 1
out_bad="$(bash "$RUNNER" "$A" "$B" 2>&1)"; code_bad=$?
[ "$code_bad" -ne 0 ] \
  && check "a failing suite outside the first directory fails the run" ok \
  || check "a failing suite outside the first directory fails the run" "exit=$code_bad out=$out_bad"
grep -q 'test-gamma.sh' <<< "$out_bad" \
  && check "and the failure names which suite it was" ok \
  || check "and the failure names which suite it was" "out=$out_bad"
rm -f "$B/test-gamma.sh"

# ---------------------------------------------------------------------------
# The score column has to hold the suite's own TALLY, and not merely the last line that happened
# to contain the word "passed". The sync suite prints hundreds of per-check lines and its verdict
# was reported as `ok: #105 even though every check inside it passed`, which is a line about
# something else standing where the verdict goes (L11). Every suite in this repo writes its total
# differently, so all four spellings are fed through.
# ---------------------------------------------------------------------------
T="$TMPROOT/dir-tally"
mk_chatty_suite "$T" equals   'PASS=805 FAIL=0'
mk_chatty_suite "$T" colons   'passed: 8, failed: 0'
mk_chatty_suite "$T" reversed '12 passed, 0 failed'
mk_chatty_suite "$T" spaced   'passed 15, failed 0'
out_tally="$(bash "$RUNNER" "$T" 2>&1)"
for want in 'PASS=805 FAIL=0' 'passed: 8, failed: 0' '12 passed, 0 failed' 'passed 15, failed 0'; do
  grep -qF "$want" <<< "$out_tally" \
    && check "the score column shows the tally '$want'" ok \
    || check "the score column shows the tally '$want'" "out=$out_tally"
done
grep -q 'wording mentions' <<< "$out_tally" \
  && check "and not a chattier line from further down" "it printed a per-check line instead" \
  || check "and not a chattier line from further down" ok

# The tally is not decoration: a suite that exits 0 while its own count says otherwise is caught by
# it, and that is the only thing reading it. Both spellings, because the two forms are read in a
# fixed order and the fallback is the half that is easy to leave broken (L151).
for spelling in 'PASS=1 FAIL=3' '1 passed, 3 failed'; do
  L="$TMPROOT/dir-liar-$(printf '%s' "$spelling" | tr -c 'a-zA-Z0-9' '-')"
  mk_chatty_suite "$L" liar "$spelling"
  out_liar="$(bash "$RUNNER" "$L" 2>&1)"; code_liar=$?
  [ "$code_liar" -ne 0 ] \
    && check "a suite exiting 0 while reporting '$spelling' is still a failure" ok \
    || check "a suite exiting 0 while reporting '$spelling' is still a failure" "exit=$code_liar out=$out_liar"
done
# And the control: the same shape reporting ZERO failures must still pass, or the check above is
# satisfied by a runner that calls everything a failure.
Z="$TMPROOT/dir-zero"; mk_chatty_suite "$Z" honest 'PASS=1 FAIL=0'
bash "$RUNNER" "$Z" >/dev/null 2>&1 \
  && check "and the same shape reporting no failures still passes" ok \
  || check "and the same shape reporting no failures still passes" "it was called a failure"

# ---------------------------------------------------------------------------
# The agreed result line. Every suite in this repo prints `SUITE-RESULT passed=<n> failed=<n>` as
# the last thing it says, and the runner reads that EXACTLY rather than recognising a score in
# prose (claude-config#126). The marker is assembled at runtime so this file is not itself an
# occurrence of it.
# ---------------------------------------------------------------------------
MARK="SUITE""-RESULT"
mk_result_suite() { # mk_result_suite <dir> <name> <passed> <failed> <exit>
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "  ok: a line that mentions something that passed"\n'
    printf 'echo "  ok: and something else that failed"\n'
    printf 'echo "PASS=999 FAIL=42"\n'
    printf 'printf %s\\\\n "%s passed=%s failed=%s"\n' "'%s'" "$MARK" "$3" "$4"
    printf 'exit %s\n' "$5"
  } > "$1/test-$2.sh"
  chmod +x "$1/test-$2.sh"
}

R="$TMPROOT/dir-resultline"
mk_result_suite "$R" clean 12 0 0
out_r="$(bash "$RUNNER" "$R" 2>&1)"; code_r=$?
[ "$code_r" -eq 0 ] \
  && check "a suite whose result line says no failures passes" ok \
  || check "a suite whose result line says no failures passes" "exit=$code_r out=$out_r"
grep -q '12 passed, 0 failed' <<< "$out_r" \
  && check "and its score is shown in one uniform shape" ok \
  || check "and its score is shown in one uniform shape" "out=$out_r"
# The fixture deliberately also prints `PASS=999 FAIL=42` and two chatty lines. The result line
# has to win, or the runner is still recognising a score rather than reading one.
grep -q '999' <<< "$out_r" \
  && check "and a misleading prose tally on the same run is ignored" "it read 999" \
  || check "and a misleading prose tally on the same run is ignored" ok
grep -qi 'NO RESULT LINE' <<< "$out_r" \
  && check "and nothing is reported as having been guessed" "it said it guessed" \
  || check "and nothing is reported as having been guessed" ok

# A suite that exits 0 while its own result line reports failures is still a failure. The line is
# the authority on the count, and the exit code is the authority on the run; either one saying
# something went wrong is enough.
R2="$TMPROOT/dir-resultliar"
mk_result_suite "$R2" liar 3 2 0
out_r2="$(bash "$RUNNER" "$R2" 2>&1)"; code_r2=$?
[ "$code_r2" -ne 0 ] \
  && check "a suite exiting 0 while its result line reports failures is caught" ok \
  || check "a suite exiting 0 while its result line reports failures is caught" "exit=$code_r2 out=$out_r2"

# A suite with NO result line is still run and still judged, and the runner SAYS it had to guess.
# A reader that quietly falls back is how two scoring defects survived, so drift back to guessing
# has to be visible rather than comfortable.
R3="$TMPROOT/dir-noresult"
mk_chatty_suite "$R3" oldstyle 'passed: 5, failed: 0'
out_r3="$(bash "$RUNNER" "$R3" 2>&1)"; code_r3=$?
[ "$code_r3" -eq 0 ] \
  && check "a suite with no result line still runs and still passes" ok \
  || check "a suite with no result line still runs and still passes" "exit=$code_r3 out=$out_r3"
grep -qi 'NO RESULT LINE' <<< "$out_r3" \
  && check "and the runner says out loud that it guessed" ok \
  || check "and the runner says out loud that it guessed" "out=$out_r3"
grep -q 'test-oldstyle.sh' <<< "$out_r3" \
  && check "and names which suite it guessed for" ok \
  || check "and names which suite it guessed for" "out=$out_r3"

# ---------------------------------------------------------------------------
# Running several suites at once (claude-config#125). The suites are independent and each writes a
# self contained verdict, so the only things that can go wrong are ordering and bookkeeping: a
# report whose lines arrive in whatever order the machine finished them is not comparable between
# runs, and a failure that lands while another suite is still going must still fail the run.
#
# The fixtures below finish in a deliberately different order from the one they must be REPORTED
# in, so a runner that simply prints as results arrive cannot pass.
# ---------------------------------------------------------------------------
mk_slow_suite() { # mk_slow_suite <dir> <name> <sleep seconds> <failed count> <exit>
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    # Each one records when it STARTED and when it FINISHED. The check below asks whether their
    # intervals OVERLAP, which is a fact about what happened rather than a duration, so a loaded
    # machine cannot turn it into a false failure. Comparing wall clock did exactly that: with the
    # whole repo running side by side, three sleeps of 3, 1 and 0 seconds took 4 seconds together,
    # written down 2026-08-21, and the check called that "no better than sequential" when they had
    # in fact all overlapped.
    printf 'date +%%s > "$(dirname "$0")/%s.start"\n' "$2"
    printf 'sleep %s\n' "$3"
    printf 'date +%%s > "$(dirname "$0")/%s.end"\n' "$2"
    printf 'printf %s\\\\n "%s passed=1 failed=%s"\n' "'%s'" "$MARK" "$4"
    printf 'exit %s\n' "$5"
  } > "$1/test-$2.sh"
  chmod +x "$1/test-$2.sh"
}
overlaps() { # overlaps <dir> <nameA> <nameB>  -> true when the two ran at the same time
  local as ae bs be
  as="$(cat "$1/$2.start" 2>/dev/null)"; ae="$(cat "$1/$2.end" 2>/dev/null)"
  bs="$(cat "$1/$3.start" 2>/dev/null)"; be="$(cat "$1/$3.end" 2>/dev/null)"
  case "$as$ae$bs$be" in ''|*[!0-9]*) return 1 ;; esac
  [ "$as" -le "$be" ] && [ "$bs" -le "$ae" ]
}

P="$TMPROOT/dir-parallel"
mk_slow_suite "$P" aaa 3 0 0     # first alphabetically, finishes LAST
mk_slow_suite "$P" bbb 1 0 0
mk_slow_suite "$P" ccc 0 0 0     # last alphabetically, finishes FIRST

par_start="$(date +%s)"
out_par="$(HOOK_TESTS_JOBS=4 bash "$RUNNER" "$P" 2>&1)"; code_par=$?
par_elapsed=$(( $(date +%s) - par_start ))

[ "$code_par" -eq 0 ] \
  && check "three suites run at once all pass" ok \
  || check "three suites run at once all pass" "exit=$code_par out=$out_par"
for n in aaa bbb ccc; do
  grep -q "test-$n.sh" <<< "$out_par" \
    && check "and test-$n.sh was run and reported" ok \
    || check "and test-$n.sh was run and reported" "out=$out_par"
done
# The order on the page is the order they were FOUND, not the order they finished. Without this a
# report cannot be compared against the last one, and a suite that moved is indistinguishable from
# a suite that got slower.
# Read off the RESULT LINES alone, not off the whole page. Since #150 the run also ends with the
# slowest suites named, which is deliberately in duration order, so a match over everything counts
# each suite twice and the two orders are read as one (L135).
order="$(printf '%s\n' "$out_par" | grep -E '^ +(ok|FAIL) +test-' | grep -oE 'test-(aaa|bbb|ccc)\.sh' | tr '\n' ' ')"
[ "$order" = "test-aaa.sh test-bbb.sh test-ccc.sh " ] \
  && check "and they are reported in a stable order, not in the order they finished" ok \
  || check "and they are reported in a stable order, not in the order they finished" "order was: $order"
# The control for the fixture: the sleeps really do make them finish in the opposite order, so the
# ordering check is not satisfied by three suites that all finished instantly (L159).
[ "$par_elapsed" -ge 3 ] \
  && check "the fixture really did stagger their finishing times" ok \
  || check "the fixture really did stagger their finishing times" "the whole run took ${par_elapsed}s, so nothing was staggered"
# And they really did run AT THE SAME TIME. Asked as an overlap of the intervals they recorded for
# themselves, never as a wall clock comparison: this suite runs alongside every other one in the
# repo, so an absolute duration measures the machine's load rather than the runner (L102, L209).
overlaps "$P" aaa ccc \
  && check "and they ran at the same time rather than one after another" ok \
  || check "and they ran at the same time rather than one after another" "aaa ran $(cat "$P/aaa.start" 2>/dev/null) to $(cat "$P/aaa.end" 2>/dev/null), ccc ran $(cat "$P/ccc.start" 2>/dev/null) to $(cat "$P/ccc.end" 2>/dev/null)"
# The control for THAT: one at a time, they must NOT overlap, or the check above is satisfied by an
# overlap test that always says yes (L159).
rm -f "$P"/*.start "$P"/*.end
HOOK_TESTS_JOBS=1 bash "$RUNNER" "$P" >/dev/null 2>&1
overlaps "$P" aaa ccc \
  && check "and one at a time they do not overlap, so the test can tell the difference" "they overlapped anyway" \
  || check "and one at a time they do not overlap, so the test can tell the difference" ok

# A failure among them still fails the run and is still named, even though it finishes first.
PF="$TMPROOT/dir-parallel-fail"
mk_slow_suite "$PF" slow 2 0 0
mk_slow_suite "$PF" quick 0 2 1
out_pf="$(HOOK_TESTS_JOBS=4 bash "$RUNNER" "$PF" 2>&1)"; code_pf=$?
[ "$code_pf" -ne 0 ] \
  && check "a suite that fails while another is still running fails the run" ok \
  || check "a suite that fails while another is still running fails the run" "exit=$code_pf out=$out_pf"
grep -q 'test-quick.sh' <<< "$out_pf" \
  && check "and is named" ok || check "and is named" "out=$out_pf"

# One at a time is the escape hatch, and it has to keep working: it is what somebody reaches for
# when a suite only fails alongside others.
out_seq="$(HOOK_TESTS_JOBS=1 bash "$RUNNER" "$P" 2>&1)"; code_seq=$?
[ "$code_seq" -eq 0 ] \
  && check "one at a time still works" ok || check "one at a time still works" "exit=$code_seq out=$out_seq"
seq_order="$(printf '%s\n' "$out_seq" | grep -E '^ +(ok|FAIL) +test-' | grep -oE 'test-(aaa|bbb|ccc)\.sh' | tr '\n' ' ')"
[ "$seq_order" = "$order" ] \
  && check "and reports in the same order as a parallel run" ok \
  || check "and reports in the same order as a parallel run" "sequential: $seq_order  parallel: $order"

# A job count nobody can read must be refused, not guessed at: it decides how much runs at once,
# and guessing could mean either no parallelism at all or a fork bomb (L50).
for bad in 0 -2 lots ''; do
  out_bad_jobs="$(HOOK_TESTS_JOBS="$bad" bash "$RUNNER" "$P" 2>&1)"; code_bad_jobs=$?
  [ "$code_bad_jobs" -ne 0 ] \
    && check "a job count of '$bad' is refused rather than guessed at" ok \
    || check "a job count of '$bad' is refused rather than guessed at" "it ran anyway"
done

# ---------------------------------------------------------------------------
# A directory it was told to read that holds no suite at all. This is the one that has to stay a
# failure: reading nothing and reading everything green look identical otherwise (L98), and now
# that several directories are read, one of them going empty is a real way to lose coverage.
# ---------------------------------------------------------------------------
EMPTY="$TMPROOT/dir-empty"; mkdir -p "$EMPTY"
out_empty="$(bash "$RUNNER" "$A" "$EMPTY" 2>&1)"; code_empty=$?
[ "$code_empty" -ne 0 ] \
  && check "a directory holding no suite is a failure, not a quiet pass" ok \
  || check "a directory holding no suite is a failure, not a quiet pass" "exit=$code_empty out=$out_empty"
grep -q "$EMPTY" <<< "$out_empty" \
  && check "and it says which directory was empty" ok \
  || check "and it says which directory was empty" "out=$out_empty"

out_missing="$(bash "$RUNNER" "$TMPROOT/not-here" 2>&1)"; code_missing=$?
[ "$code_missing" -ne 0 ] \
  && check "a directory that does not exist is a failure too" ok \
  || check "a directory that does not exist is a failure too" "exit=$code_missing"

# ---------------------------------------------------------------------------
# Discovery: with nothing named, every directory in the repo holding a suite is read, not just the
# one the runner lives in. The fixture puts one WHERE THE RUNNER IS and one three levels away, and
# the far one is the whole point.
# ---------------------------------------------------------------------------
REPO="$TMPROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
mk_suite "$REPO/payload/hooks" near 0
mk_suite "$REPO/payload/skills/thing" faraway 0
mk_suite "$REPO/tests" middle 0
printf 'not a suite\n' > "$REPO/payload/hooks/helper.sh"
git -C "$REPO" add -A >/dev/null 2>&1
out_disc="$(HOOK_TESTS_ROOT="$REPO" bash "$RUNNER" 2>&1)"; code_disc=$?
[ "$code_disc" -eq 0 ] \
  && check "discovery over a repo passes when every suite passes" ok \
  || check "discovery over a repo passes when every suite passes" "exit=$code_disc out=$out_disc"
grep -q 'test-faraway.sh' <<< "$out_disc" \
  && check "a suite three directories away from the runner is run" ok \
  || check "a suite three directories away from the runner is run" "out=$out_disc"
printf '%s' "$out_disc" | grep -q 'test-middle.sh' && printf '%s' "$out_disc" | grep -q 'test-near.sh' \
  && check "and so is every other one in the repo" ok \
  || check "and so is every other one in the repo" "out=$out_disc"
grep -q 'helper.sh' <<< "$out_disc" \
  && check "a script that is not a suite is not run" "it ran helper.sh" \
  || check "a script that is not a suite is not run" ok

# The count is said out loud, both halves. A run that read four directories and one that read one
# are different facts, and neither can be told from the other by "everything passed" (L11).
printf '%s' "$out_disc" | grep -qE '3 (suite|director)' \
  && check "it says how much it read" ok \
  || check "it says how much it read" "out=$out_disc"

# A failing suite in the far directory still fails the discovered run, or the discovery is
# decoration: it would have found the suite and not cared what it said.
mk_suite "$REPO/payload/skills/thing" broken 1
git -C "$REPO" add -A >/dev/null 2>&1
out_disc_bad="$(HOOK_TESTS_ROOT="$REPO" bash "$RUNNER" 2>&1)"; code_disc_bad=$?
[ "$code_disc_bad" -ne 0 ] \
  && check "and a failure in a discovered directory fails the run" ok \
  || check "and a failure in a discovered directory fails the run" "exit=$code_disc_bad out=$out_disc_bad"

# ---------------------------------------------------------------------------
# A repo with no suites at all, and a root that is not a repo. Both are ways of discovering
# nothing, and both must refuse rather than report a clean run.
# ---------------------------------------------------------------------------
BARE="$TMPROOT/bare"; mkdir -p "$BARE"; git -C "$BARE" init -q
printf 'x\n' > "$BARE/readme.md"; git -C "$BARE" add -A >/dev/null 2>&1
out_bare="$(HOOK_TESTS_ROOT="$BARE" bash "$RUNNER" 2>&1)"; code_bare=$?
[ "$code_bare" -ne 0 ] \
  && check "a repo holding no suite at all is refused" ok \
  || check "a repo holding no suite at all is refused" "exit=$code_bare out=$out_bare"

# ---------------------------------------------------------------------------
# The real repo this file lives in, last, by which point the runner has been watched failing six
# ways. It is asked only WHICH directories it would read, never run, because running it from here
# would run this suite from inside itself.
# ---------------------------------------------------------------------------
REAL="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$REAL" ]; then
  out_list="$(HOOK_TESTS_LIST_ONLY=1 bash "$RUNNER" 2>/dev/null)"
  for d in payload/hooks tests tools payload/skills/milestone; do
    # An anchored whole-line match against the absolute path, not a substring search. `tests`
    # appears inside the runner's own name, so a substring check is answered by the refusal
    # message ABOUT the runner just as readily as by a directory it listed, and it passed that
    # way while its three neighbours failed (L156).
    grep -qx "$REAL/$d" <<< "$out_list" \
      && check "the real repo's $d is one of the directories it would read" ok \
      || check "the real repo's $d is one of the directories it would read" "out=$out_list"
  done
  # And it must be listing, not refusing. A refusal prints nothing on stdout, which every check
  # above would report as a missing directory rather than as the runner declining to answer.
  [ "$(printf '%s\n' "$out_list" | grep -c .)" -ge 4 ] \
    && check "the listing answered rather than refusing" ok \
    || check "the listing answered rather than refusing" "it printed $(printf '%s\n' "$out_list" | grep -c .) line(s)"
else
  # No repository above this file, which is what a deployed copy under the config directory looks
  # like. The four checks above cannot be asked here, and this branch used to REFUSE, which is one
  # of the three failures that made the documented command report red on a tree where nothing was
  # wrong (claude-config#155). What is true here is asserted instead, so the branch still checks
  # something rather than only explaining why it cannot (L98).
  out_list="$(HOOK_TESTS_LIST_ONLY=1 bash "$RUNNER" 2>/dev/null)"
  n_list="$(printf '%s\n' "$out_list" | grep -c . || true)"
  [ "${n_list:-0}" = 1 ] && [ "$out_list" = "$DIR" ] \
    && check "with no repo above it, the runner reads only its own directory" ok \
    || check "with no repo above it, the runner reads only its own directory" "it would read: $out_list"
fi

# ---------------------------------------------------------------------------
# A deployed copy, reproduced rather than reasoned about (claude-config#155).
# ---------------------------------------------------------------------------
# The branch above only runs where there is no repository, which is never true from the checkout,
# so on its own it is a branch nothing exercises: every outcome a contract names has to be
# PRODUCED by a test, not merely be reachable (L151). So a copy of the runner and two suites is
# put somewhere with no repository above it, and run exactly as the documented command runs it.
DEP="$TMPROOT/deployed"
mkdir -p "$DEP"
cp "$RUNNER" "$DEP/run-all-tests.sh"
mk_suite "$DEP" plain 0
mk_notrun_suite "$DEP" auditsrepo "needs the repository, and there is none here"
# HOOK_TESTS_RUNNING is unset for this one call. It is set whenever this suite is itself being run
# by the runner, and a bare invocation from inside a run is refused outright because that is how
# the runner recurses into itself without end. Here it cannot: this directory holds two fixture
# suites and neither invokes a runner. Unsetting it is also what the real case looks like, since
# the documented command is typed into a fresh shell.
out_dep="$(cd "$DEP" && env -u HOOK_TESTS_RUNNING bash "$DEP/run-all-tests.sh" 2>&1)"; code_dep=$?
[ "$code_dep" -eq 0 ] \
  && check "#155 a deployed copy with no repo above it does not report red" ok \
  || check "#155 a deployed copy with no repo above it does not report red" "exit=$code_dep out=$out_dep"
# The control for the fixture (L159): it really is a place with no repository, or the check above
# is passing because it quietly found one and ran normally.
case "$out_dep" in
  *"no repo above"*) check "#155 the fixture really is a copy with no repo above it" ok ;;
  *) check "#155 the fixture really is a copy with no repo above it" "out=$out_dep" ;;
esac
printf '%s\n' "$out_dep" | grep -E '^ +NOT RUN +test-auditsrepo\.sh' > /dev/null \
  && check "#155 and the repo-auditing suite there is reported as NOT RUN" ok \
  || check "#155 and the repo-auditing suite there is reported as NOT RUN" "out=$out_dep"
printf '%s\n' "$out_dep" | grep -E '^ +ok +test-plain\.sh' > /dev/null \
  && check "#155 while the suite beside it is still run and still reported" ok \
  || check "#155 while the suite beside it is still run and still reported" "out=$out_dep"

# ---------------------------------------------------------------------------
# How much of the machine a run may take is ONE number (claude-config#136).
#
# The runner starts up to HOOK_TESTS_JOBS suites at once, and one of those suites splits itself
# into shards of its own. Nothing related the two, so a four core runner could be running a dozen
# heavy processes, each spawning git and python. It never failed outright, which is the problem:
# oversubscription makes timing sensitive checks intermittently wrong rather than red, and the
# suite's own deadline guard was measured firing at 1192s against a normal 200 on a loaded Mac,
# written down 2026-08-21.
#
# So the runner now holds a budget and derives BOTH halves from it: how many suites run at once,
# and how many slots each of them may take. Their product is the budget rather than the product of
# two numbers nobody compared. The budget is pinned in every check below rather than read off this
# machine, because the arithmetic is what is being tested and a machine's core count would decide
# the answer (L504).
# ---------------------------------------------------------------------------
# The grant is written to a FILE rather than printed. A passing suite's own output is not shown by
# the runner at all, so a fixture that only echoed would be checked against a report that never
# carries it, and every check below would fail for a reason unrelated to the grant.
mk_slot_suite() { # mk_slot_suite <dir> <name>   -- a suite that records the grant it was handed
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "${HOOK_TESTS_SLOTS:-<unset>}" > "$(dirname "$0")/%s.slots"\n' "$2"
    printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
  } > "$1/test-$2.sh"
  chmod +x "$1/test-$2.sh"
}
slots_seen() { # slots_seen <dir> <name>   -- what that suite was handed, or nothing
  cat "$1/$2.slots" 2>/dev/null
}

S2="$TMPROOT/slots-two"
mk_slot_suite "$S2" one
mk_slot_suite "$S2" two
out_sl="$(HOOK_TESTS_BUDGET=8 bash "$RUNNER" "$S2" 2>&1)"; code_sl=$?
[ "$code_sl" -eq 0 ] \
  && check "a run with a budget of 8 and two suites passes" ok \
  || check "a run with a budget of 8 and two suites passes" "exit=$code_sl out=$out_sl"
# Two suites, so two run at once, so each may take four of the eight. The grant has to REACH the
# suite: a budget the runner works out and keeps to itself changes nothing about what starts (L3).
[ "$(slots_seen "$S2" one)" = 4 ] && [ "$(slots_seen "$S2" two)" = 4 ] \
  && check "and both suites were handed four slots each" ok \
  || check "and both suites were handed four slots each" "one=$(slots_seen "$S2" one) two=$(slots_seen "$S2" two)"
# Said out loud, on one line, with the product spelled out. The number that matters is what will
# be in flight, and it was previously the product of two numbers printed nowhere (L182).
case "$out_sl" in
  *"at most 8 process(es) at once, against a budget of 8"*) check "and the run says how many processes that adds up to" ok ;;
  *) check "and the run says how many processes that adds up to" "out=$out_sl" ;;
esac

# One suite takes the whole budget, because nothing else is running beside it. This is what keeps
# `run-all-tests.sh tests/` fast: the long suite still shards as wide as the machine allows.
S1="$TMPROOT/slots-one"
mk_slot_suite "$S1" only
out_s1="$(HOOK_TESTS_BUDGET=6 bash "$RUNNER" "$S1" 2>&1)"
[ "$(slots_seen "$S1" only)" = 6 ] \
  && check "a single suite is handed the whole budget" ok \
  || check "a single suite is handed the whole budget" "it was handed '$(slots_seen "$S1" only)', out=$out_s1"

# The long pole (claude-config#139). The budget used to divide itself equally between the suites
# running at once, so the one suite taking most of the wall clock got no more of the machine than a
# suite finishing in a second: measured on this Mac on 2026-08-21, 124 seconds against 88 the old
# oversubscribed way. The suites are launched longest first, so the first launch is the one worth spending on, and
# it is granted the largest share the budget allows while still leaving every other suite that can
# run alongside it a slot of its own.
#
# Never more than half the budget while anything else has to run, which is the other half of the
# rule: a grant is fixed for the life of the suite, so handing one suite most of the machine would
# leave a second long suite crawling on the remainder for the whole run, which is the same defect
# one level down.
#
# Asserted on the FIRST launch only. Which grant a later suite receives depends on which share came
# free first, and asserting on that would be asserting on the machine's mood.
SLP="$TMPROOT/slots-long-pole"
mk_slot_suite "$SLP" biggest
for n in two three four five; do mk_slot_suite "$SLP" "$n"; done
# Longest first is judged by file size, so the one that must launch first is made the largest.
printf '# %s\n' "$(head -c 400 /dev/zero | tr '\0' 'x')" >> "$SLP/test-biggest.sh"
out_lp="$(HOOK_TESTS_BUDGET=8 HOOK_TESTS_JOBS=4 bash "$RUNNER" "$SLP" 2>&1)"
[ "$(slots_seen "$SLP" biggest)" = 4 ] \
  && check "the suite launched first is granted half the budget, not an equal share" ok \
  || check "the suite launched first is granted half the budget, not an equal share" "it was handed '$(slots_seen "$SLP" biggest)', out=$out_lp"
# Every other suite still gets a real grant. A share that starves the rest to pay for the first one
# would be the same idle budget, moved.
# `sort -n | awk NR==1` rather than `head -1`, which leaves on its first line and can kill its own
# producer under pipefail (#132, L183).
lp_min="$(cat "$SLP"/*.slots 2>/dev/null | sort -n | awk 'NR==1')"
lp_n="$(cat "$SLP"/*.slots 2>/dev/null | grep -c .)"
[ "$lp_n" -eq 5 ] && [ -n "$lp_min" ] && [ "$lp_min" -ge 1 ] \
  && check "and every other suite is still granted at least one slot" ok \
  || check "and every other suite is still granted at least one slot" "5 expected, $lp_n recorded, smallest '$lp_min'"
# And the whole point of the budget: what is in flight still adds up to it and no more.
case "$out_lp" in
  *"at most 8 process(es) at once, against a budget of 8"*)
    check "and the shares still add up to the budget, not past it" ok ;;
  *) check "and the shares still add up to the budget, not past it" "out=$out_lp" ;;
esac

# And the other end: as many suites at once as the budget, so one slot each and no more in flight
# than before. The grant can never be zero, or a suite reading it would be told to start nothing.
S4="$TMPROOT/slots-four"
for n in one two three four; do mk_slot_suite "$S4" "$n"; done
out_s4="$(HOOK_TESTS_BUDGET=4 HOOK_TESTS_JOBS=4 bash "$RUNNER" "$S4" 2>&1)"
[ "$(cat "$S4"/*.slots 2>/dev/null | sort -u)" = 1 ] && [ "$(cat "$S4"/*.slots 2>/dev/null | grep -c .)" -eq 4 ] \
  && check "four suites against a budget of four get one slot each" ok \
  || check "four suites against a budget of four get one slot each" "they were handed: $(cat "$S4"/*.slots 2>/dev/null | tr '\n' ' ')"
# The floor, proven rather than assumed: more suites at once than the budget still grants 1, never
# 0. Integer division is where a floor like this goes missing.
rm -f "$S4"/*.slots
out_s0="$(HOOK_TESTS_BUDGET=2 HOOK_TESTS_JOBS=4 bash "$RUNNER" "$S4" 2>&1)"
[ "$(cat "$S4"/*.slots 2>/dev/null | sort -u)" = 1 ] && [ "$(cat "$S4"/*.slots 2>/dev/null | grep -c .)" -eq 4 ] \
  && check "and a budget smaller than the suites at once still grants one slot, not none" ok \
  || check "and a budget smaller than the suites at once still grants one slot, not none" "they were handed: $(cat "$S4"/*.slots 2>/dev/null | tr '\n' ' ')"

# The configuration CI actually runs, pinned here rather than only described in the workflow. Two
# cores and a budget of four, with the job count left at its default: two suites at once and two
# slots each, so the sync suite still shards and #137's coverage check still runs somewhere other
# than the machine of whoever wrote it (L88, L98). Nothing else in this suite covers this shape,
# and a change to the shares could quietly take CI back to one process per suite.
out_ci="$(HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$S2" 2>&1)"
case "$out_ci" in
  *"up to 2 suite(s) at once, 2 slot(s) each, so at most 4 process(es) at once, against a budget of 4"*)
    check "the budget CI sets still buys two suites at once with two slots each" ok ;;
  *) check "the budget CI sets still buys two suites at once with two slots each" "out=$out_ci" ;;
esac

# A small machine is where the arithmetic goes wrong quietly. The CI runner has two cores, and
# half of two is one, which would have run the 38 suites counted on 2026-08-21 strictly one after
# another while holding two slots for whichever one of them can use them. So the count of suites at once has a floor of two,
# capped by the budget itself, and the share follows from it. The numbers are asserted through the
# line the runner prints, which is the same line a person reads to see what is happening.
out_sm="$(HOOK_TESTS_BUDGET=2 bash "$RUNNER" "$S2" 2>&1)"
case "$out_sm" in
  *"up to 2 suite(s) at once, 1 slot(s) each, so at most 2 process(es) at once, against a budget of 2"*)
    check "a two core machine still runs two suites at once, one slot each" ok ;;
  *) check "a two core machine still runs two suites at once, one slot each" "out=$out_sm" ;;
esac
# And the floor never exceeds the budget: one core is one process, not two.
out_sm1="$(HOOK_TESTS_BUDGET=1 bash "$RUNNER" "$S2" 2>&1)"
case "$out_sm1" in
  *"up to 1 suite(s) at once, 1 slot(s) each, so at most 1 process(es) at once, against a budget of 1"*)
    check "a one core machine runs one suite at a time, one slot" ok ;;
  *) check "a one core machine runs one suite at a time, one slot" "out=$out_sm1" ;;
esac

# A budget nobody can read decides how many processes start, so it is refused rather than guessed
# at, exactly as HOOK_TESTS_JOBS already is (L50).
for bad in two 1.5 -3 0; do
  out_bb="$(HOOK_TESTS_BUDGET="$bad" bash "$RUNNER" "$S2" 2>&1)"; code_bb=$?
  case "$out_bb" in
    *"HOOK_TESTS_BUDGET='$bad'"*) named=1 ;;
    *) named=0 ;;
  esac
  [ "$code_bb" -ne 0 ] && [ "$named" -eq 1 ] \
    && check "a budget of '$bad' is refused, and named in the refusal" ok \
    || check "a budget of '$bad' is refused, and named in the refusal" "exit=$code_bb out=$out_bb"
done
# The control: a well formed budget is NOT refused, or every check above is satisfied by a runner
# that refuses everything (L159).
out_bg="$(HOOK_TESTS_BUDGET=8 bash "$RUNNER" "$S2" 2>&1)"
case "$out_bg" in
  *"HOOK_TESTS_BUDGET="*) check "the control: a well formed budget is not refused" "it refused 8: $out_bg" ;;
  *) check "the control: a well formed budget is not refused" ok ;;
esac

# ---------------------------------------------------------------------------
# The launch order follows MEASURED wall clock, not file size (claude-config#144).
# ---------------------------------------------------------------------------
# Lane 1 carries the largest share of the budget, and lane 1 is whatever launches first, so the
# launch order decides which suite the machine is spent on. It was decided by file SIZE, and the
# comment beside it said what that costs: bytes are not seconds. It was right only because the
# largest file happened to be the slowest suite, and the day that stopped being true the big share
# would go to a suite that cannot use it while the slow one ran on one slot, with nothing anywhere
# reporting a problem. The run would simply be slower, which is the symptom #139 existed to remove.
#
# So each run RECORDS what every suite actually cost, and the next run orders by that. The record
# is written by the run itself, never by hand: a hand written list of the slow ones is the thing
# the runner exists not to have (L96).
#
# Four suites against four lanes, deliberately. With five, the last one launches into whichever
# lane frees first, which can be lane 1 again, and then two suites report the largest share and
# the check cannot tell the order it was written to prove from the machine's mood.
TR="$TMPROOT/timed"
TSTORE="$TMPROOT/timed-store"
mkdir -p "$TR/suites" "$TSTORE"
for n in bigfile slowpoke three four; do mk_slot_suite "$TR/suites" "$n"; done
# The largest FILE is a suite that will turn out to be fast. That is the whole defect in one line.
printf '# %s\n' "$(head -c 400 /dev/zero | tr '\0' 'x')" >> "$TR/suites/test-bigfile.sh"

# First run: nothing has ever been measured, so the order falls back to size and the big file
# leads. This is also the control for every check below (L159): the store starts empty, so a run
# that wrote nothing and a run that read nothing would look alike without it.
out_t1="$(HOOK_TESTS_ROOT="$TR" HOOK_TESTS_TIMINGS="$TSTORE" HOOK_TESTS_BUDGET=8 HOOK_TESTS_JOBS=4 bash "$RUNNER" "$TR/suites" 2>&1)"; code_t1=$?
[ "$code_t1" -eq 0 ] \
  && check "#144 a first run, with nothing ever measured, passes" ok \
  || check "#144 a first run, with nothing ever measured, passes" "exit=$code_t1 out=$out_t1"
[ "$(slots_seen "$TR/suites" bigfile)" = 4 ] \
  && check "#144 and with no record to read, the largest file still leads" ok \
  || check "#144 and with no record to read, the largest file still leads" "bigfile=$(slots_seen "$TR/suites" bigfile) out=$out_t1"
# The run has to WRITE what it measured, or the next run has nothing to order by (L3, L46).
t_recs="$(ls "$TSTORE" 2>/dev/null | grep -c 'test-.*\.sh$' || true)"
[ "${t_recs:-0}" -eq 4 ] \
  && check "#144 the run records a wall clock for every suite it ran" ok \
  || check "#144 the run records a wall clock for every suite it ran" "$t_recs record(s) in $TSTORE: $(ls "$TSTORE" 2>/dev/null | tr '\n' ' ')"
# `awk NR==1` rather than `head -1`, which leaves on its first line and can kill its own producer
# under pipefail (#132, L183).
t_slow_rec="$(ls "$TSTORE" 2>/dev/null | grep 'test-slowpoke\.sh$' | awk 'NR==1')"
# The record is `<seconds>` or `<seconds> <checks>` since #219 put a second perishable number about
# the same suite beside the first. Read the FIELD rather than the whole line, and pin the shape of
# the whole record too, so a third field cannot be added without this saying so (L317).
t_slow_line="$(cat "$TSTORE/$t_slow_rec" 2>/dev/null)"
case "$(printf '%s\n' "$t_slow_line" | awk 'NR == 1 { print $1 }')" in
  ''|*[!0-9]*) check "#144 and what it records is a whole number of seconds" "the record for test-slowpoke.sh reads '$t_slow_line'" ;;
  *) check "#144 and what it records is a whole number of seconds" ok ;;
esac
# Matched with `case` on a variable rather than `printf | grep -q`, which leaves on its first
# match and can be killed by its own producer under pipefail (#132, L183). The shape is pinned in
# three parts: it begins and ends with a digit, and taking the digits out leaves at most one
# single space, so a third field cannot be added without this saying so (L317).
t_shape_ok=1
case "$t_slow_line" in [0-9]*) ;; *) t_shape_ok=0 ;; esac
case "$t_slow_line" in *[0-9]) ;; *) t_shape_ok=0 ;; esac
case "$(printf '%s' "$t_slow_line" | tr -d '0-9')" in ''|' ') ;; *) t_shape_ok=0 ;; esac
[ "$t_shape_ok" -eq 1 ] \
  && check "#219 and the record is that field, or that field and a check count, and nothing else" ok \
  || check "#219 and the record is that field, or that field and a check count, and nothing else" "the record reads '$t_slow_line'"

# Now the measurement disagrees with the file size, which is the case the issue is about. The
# record is EDITED rather than fabricated from nothing, so the check runs against the same key the
# runner itself wrote and cannot pass by agreeing with a scheme only this file believes in.
printf '99\n' > "$TSTORE/$t_slow_rec"
rm -f "$TR/suites"/*.slots
out_t2="$(HOOK_TESTS_ROOT="$TR" HOOK_TESTS_TIMINGS="$TSTORE" HOOK_TESTS_BUDGET=8 HOOK_TESTS_JOBS=4 bash "$RUNNER" "$TR/suites" 2>&1)"; code_t2=$?
[ "$code_t2" -eq 0 ] \
  && check "#144 a run with a measured record passes" ok \
  || check "#144 a run with a measured record passes" "exit=$code_t2 out=$out_t2"
[ "$(slots_seen "$TR/suites" slowpoke)" = 4 ] \
  && check "#144 the suite measured slowest leads, though its file is small" ok \
  || check "#144 the suite measured slowest leads, though its file is small" "slowpoke=$(slots_seen "$TR/suites" slowpoke) out=$out_t2"
# And the other half of the same fact, read off the announced order rather than off a lane
# (claude-config#209). Without it, a runner that launched everything in one fixed order would
# satisfy the check above (L178). It used to assert that bigfile did NOT come out holding lane 1's
# share, which is true only while lane 1 is still occupied when the second suite launches: these
# fixtures finish in milliseconds, so a runner that paused between two launches would recycle lane
# 1 to bigfile and this would fail with nothing wrong (L290).
order_t2="$(printf '%s\n' "$out_t2" | sed -n 's/^run-all-tests: launch order: //p' | tail -1)"
case "$order_t2" in
  "test-slowpoke.sh "*)
    check "#144 and the largest file no longer leads" ok ;;
  *)
    check "#144 and the largest file no longer leads" "launch order was '$order_t2'" ;;
esac
# Said out loud. Which of the two orders a run used decides where the minutes went, and a run that
# silently fell back to size reads exactly like one that ordered by measurement (L11).
case "$out_t2" in
  *"measured wall clock for 4 of 4"*) check "#144 the run says how many suites it had a measurement for" ok ;;
  *) check "#144 the run says how many suites it had a measurement for" "out=$out_t2" ;;
esac

# A record nobody can read is not a measurement, so it falls back to size rather than being
# guessed at as a number. It must not fail the run either: the store is a cache, and a corrupt
# cache entry is not a broken test suite.
#
# What is read here is the DECISION and the ORDER IT PRODUCED, never the lane a suite was handed
# (claude-config#209). This check used to assert that bigfile came out of the run holding lane 1's
# share, and a lane is two removes from the rule under test: the launch order decides it, and the
# launch order among the three suites that DO have a record is decided by whatever those fixtures
# happened to measure on the previous run. Three suites that all measure 0s are separated by file
# size and bigfile leads; one of them measuring 1s on a loaded two core runner puts it in front,
# and the check reads bigfile=2 and fails. That is the machine's mood, not the runner's rule. It
# happened once in 233 CI runs, on 2026-08-27 (run 33119513948), and cost a full re-run of
# everything to learn nothing at all (L293, L294).
#
# The runner now says both things before a single suite launches, so neither can be perturbed by
# load: how many suites it had a measurement for, and the order it is about to launch them in.
printf 'not-a-number\n' > "$TSTORE/$t_slow_rec"
rm -f "$TR/suites"/*.slots
out_t3="$(HOOK_TESTS_ROOT="$TR" HOOK_TESTS_TIMINGS="$TSTORE" HOOK_TESTS_BUDGET=8 HOOK_TESTS_JOBS=4 bash "$RUNNER" "$TR/suites" 2>&1)"; code_t3=$?
[ "$code_t3" -eq 0 ] \
  && check "#144 a record that is not a number does not fail the run" ok \
  || check "#144 a record that is not a number does not fail the run" "exit=$code_t3 out=$out_t3"
# The decision. Three of the four records are readable numbers this run wrote itself; the fourth
# was made unreadable above, so the run must count three. Its pair is the check a few lines up,
# where every record is readable and the same sentence reads 4 of 4: without that one, a runner
# that had given up on the store entirely would satisfy this (L159, L178).
case "$out_t3" in
  *"measured wall clock for 3 of 4 suite(s)"*)
    check "#209 an unreadable record is counted as unmeasured, not guessed at as a number" ok ;;
  *)
    check "#209 an unreadable record is counted as unmeasured, not guessed at as a number" "out=$out_t3" ;;
esac
# And what that decision DID: the suite whose record cannot be read is ordered by size, so it goes
# behind the three that were measured. bigfile is the largest file in the fixture and slowpoke is
# the one with the broken record, so slowpoke is last no matter what the other three measured.
order_t3="$(printf '%s\n' "$out_t3" | sed -n 's/^run-all-tests: launch order: //p' | tail -1)"
case "$order_t3" in
  *"test-slowpoke.sh")
    check "#209 and the suite it could not measure is launched last, behind the three it could" ok ;;
  *)
    check "#209 and the suite it could not measure is launched last, behind the three it could" "launch order was '$order_t3'" ;;
esac

# A suite OUTSIDE the repo gets no record at all. The key is the suite's path within the repo, so
# a suite that has no such path has no stable identity to key one on, and this is also what keeps
# every fixture in this file structurally unable to write into the real store (L2). Nothing here
# sets HOOK_TESTS_ROOT, so the root is the real repo and these suites are nowhere under it.
TOUT="$TMPROOT/outside-store"
mkdir -p "$TOUT"
out_t4="$(HOOK_TESTS_TIMINGS="$TOUT" HOOK_TESTS_BUDGET=8 bash "$RUNNER" "$TR/suites" 2>&1)"; code_t4=$?
t_out_n="$(ls "$TOUT" 2>/dev/null | grep -c . || true)"
[ "$code_t4" -eq 0 ] && [ "${t_out_n:-0}" -eq 0 ] \
  && check "#144 a suite outside the repo is recorded nowhere" ok \
  || check "#144 a suite outside the repo is recorded nowhere" "exit=$code_t4, $t_out_n record(s): $(ls "$TOUT" 2>/dev/null | tr '\n' ' ')"

# And the store can be switched off outright, which is what a run that must leave no trace needs.
TOFF="$TMPROOT/off-store"
mkdir -p "$TOFF"
out_t5="$(HOOK_TESTS_ROOT="$TR" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=8 bash "$RUNNER" "$TR/suites" 2>&1)"; code_t5=$?
[ "$code_t5" -eq 0 ] \
  && check "#144 an empty HOOK_TESTS_TIMINGS turns the record off and the run still passes" ok \
  || check "#144 an empty HOOK_TESTS_TIMINGS turns the record off and the run still passes" "exit=$code_t5 out=$out_t5"

# ---------------------------------------------------------------------------
# Each suite's measured duration reaches the report (claude-config#150).
# ---------------------------------------------------------------------------
# #144 made every run measure what each suite cost and write it down, and the next run orders the
# launches by it. Nothing said that number to a PERSON: the report printed a pass and fail count
# per suite and no duration at all, so "the full run got slower" named no suite anybody could act
# on. That is the same gap #107 closed one level down, inside the sync suite, by giving every
# section its own duration and ending the run with the slowest ones named.
#
# The number comes from the run's OWN measurement rather than from the timing store. Both hold the
# same figure by the time the report is printed, and the measurement is the one that survives the
# store being switched off, unwritable, or absent for a suite that lives outside the repo.
D="$TMPROOT/dir-durations"
mk_slow_suite "$D" longone 3 0 0
mk_slow_suite "$D" quick 0 0 0
out_dur="$(HOOK_TESTS_JOBS=1 bash "$RUNNER" "$D" 2>&1)"; code_dur=$?
[ "$code_dur" -eq 0 ] \
  && check "#150 a run whose suites are timed passes" ok \
  || check "#150 a run whose suites are timed passes" "exit=$code_dur out=$out_dur"
# The duration is read off the slow suite's OWN line, so a figure printed against the wrong suite
# cannot pass (L135: a match over the whole page is answered by any part of it).
dur_of() { # dur_of <output> <suite name> -> the seconds on that suite's result line, or nothing
  printf '%s\n' "$1" | grep -E "^ +(ok|FAIL) +test-$2\.sh " | tail -1 \
    | grep -oE '\(([0-9]+)s\)' | grep -oE '[0-9]+'
}
d_long="$(dur_of "$out_dur" longone)"
d_quick="$(dur_of "$out_dur" quick)"
case "$d_long" in
  ''|*[!0-9]*) check "#150 a suite's own result line carries the seconds it took" "test-longone.sh line: $(printf '%s\n' "$out_dur" | grep -E 'test-longone\.sh')" ;;
  *) [ "$d_long" -ge 3 ] \
       && check "#150 a suite's own result line carries the seconds it took" ok \
       || check "#150 a suite's own result line carries the seconds it took" "it slept 3s and reported ${d_long}s" ;;
esac
# And the control (L159, L178). Without it, a runner printing one constant against every suite, or
# printing the whole run's duration on each line, would satisfy the check above.
case "$d_quick" in
  ''|*[!0-9]*) check "#150 and a suite that took no time reports its own smaller figure" "test-quick.sh line: $(printf '%s\n' "$out_dur" | grep -E 'test-quick\.sh')" ;;
  *) [ "$d_quick" -lt "${d_long:-0}" ] \
       && check "#150 and a suite that took no time reports its own smaller figure" ok \
       || check "#150 and a suite that took no time reports its own smaller figure" "longone=${d_long}s quick=${d_quick}s, so the figure is not per suite" ;;
esac
# The run ends with the slowest named, which is what somebody reads when a run got slower. Same
# shape as #107's profile one level down.
#
# Written to a file and grepped from the file, rather than piped into a quiet grep, which leaves on
# its first match and can kill its own producer under pipefail (claude-config#132, #153, L183).
printf '%s\n' "$out_dur" > "$TMPROOT/durations.out"
grep -qi 'slowest suites' "$TMPROOT/durations.out" \
  && check "#150 the run ends with a profile of the slowest suites" ok \
  || check "#150 the run ends with a profile of the slowest suites" "out=$out_dur"
sed -n '/[Ss]lowest suites/,$p' "$TMPROOT/durations.out" > "$TMPROOT/durations.profile"
grep -qE '^ +[0-9]+s +test-longone\.sh' "$TMPROOT/durations.profile" \
  && check "#150 and the slowest suite is the one that slept longest" ok \
  || check "#150 and the slowest suite is the one that slept longest" "profile was: $(tr '\n' '|' < "$TMPROOT/durations.profile")"

# The measurement, not the store. With the record switched off entirely, nothing is written and
# nothing is read back, and the durations must still be there: a report fed from the store would go
# blank here and a run would read as one where everything was instant (L90, L98).
out_dur_off="$(HOOK_TESTS_JOBS=1 HOOK_TESTS_TIMINGS= bash "$RUNNER" "$D" 2>&1)"; code_dur_off=$?
d_long_off="$(dur_of "$out_dur_off" longone)"
case "$d_long_off" in
  ''|*[!0-9]*) check "#150 the durations survive the timing store being switched off" "exit=$code_dur_off, test-longone.sh line: $(printf '%s\n' "$out_dur_off" | grep -E 'test-longone\.sh')" ;;
  *) [ "$d_long_off" -ge 3 ] \
       && check "#150 the durations survive the timing store being switched off" ok \
       || check "#150 the durations survive the timing store being switched off" "it reported ${d_long_off}s with the store off" ;;
esac

# A suite that left NO measurement must say so, never read as 0s. A suite killed before it could
# write one is exactly that case, and zero is the most reassuring figure available: it reads as a
# suite that cost nothing rather than as one nobody measured (L11, L90).
DK="$TMPROOT/dir-duration-killed"
mkdir -p "$DK"
mk_slow_suite "$DK" survivor 1 0 0
# It kills the subshell that is timing it, which is its own parent, so neither the duration nor the
# exit status is ever written. Built by killing rather than by planting a missing file, because the
# runner's throwaway directory is its own and nothing here can reach into it.
printf '#!/usr/bin/env bash\nkill -9 "$PPID"\nsleep 30\n' > "$DK/test-vanish.sh"
chmod +x "$DK/test-vanish.sh"
out_dk="$(HOOK_TESTS_JOBS=2 bash "$RUNNER" "$DK" 2>&1)"; code_dk=$?
[ "$code_dk" -ne 0 ] \
  && check "#150 a suite that vanished still fails the run" ok \
  || check "#150 a suite that vanished still fails the run" "exit=$code_dk out=$out_dk"
vanish_line="$(printf '%s\n' "$out_dk" | grep -E '^ +(ok|FAIL) +test-vanish\.sh ' | tail -1)"
printf '%s' "$vanish_line" | grep -qE '\(0s\)' \
  && check "#150 and it is not reported as having taken no time" "its line reads: $vanish_line" \
  || check "#150 and it is not reported as having taken no time" ok
grep -qi 'not measured' <<< "$vanish_line" \
  && check "#150 and its line says outright that nothing measured it" ok \
  || check "#150 and its line says outright that nothing measured it" "its line reads: $vanish_line"
# The control for that pair: the suite beside it in the same run WAS measured, so "not measured" is
# a fact about the one that vanished and not about a runner that measures nothing (L159).
d_survivor="$(dur_of "$out_dk" survivor)"
case "$d_survivor" in
  ''|*[!0-9]*) check "#150 the suite beside it in the same run was measured" "test-survivor.sh line: $(printf '%s\n' "$out_dk" | grep -E 'test-survivor\.sh')" ;;
  *) check "#150 the suite beside it in the same run was measured" ok ;;
esac

# ---------------------------------------------------------------------------
# A suite that CANNOT run here is not a suite that failed (claude-config#155).
# ---------------------------------------------------------------------------
# `bash ~/.claude/hooks/run-all-tests.sh` is the command CLAUDE.md tells people to run, and it
# reported "3 of 32 SUITES FAILED" on 2026-08-22. All three fail for one reason: they audit the
# REPOSITORY, and a deployed copy under the config directory has no repository above it. The same
# tree passes 38 of 38 from the checkout. Repeated fake failures are how a real one gets skimmed
# past (L36), and this one was on the documented command.
#
# So a suite may say `SUITE-NOT-RUN <reason>` instead of a result line, and that is reported as its
# own outcome, never folded into either ok or FAIL. A suite that did not run must never read as one
# that passed (L98), and it must not read as broken code either (L11).
NR_DIR="$TMPROOT/dir-notrun"
mk_suite "$NR_DIR" ran 0
mk_notrun_suite "$NR_DIR" needsrepo "needs the repo, and this is a deployed copy"
# HOOK_TESTS_ROOT names somewhere that is NOT a git work tree, which is what the deployed hooks
# directory looks like to the runner: it has no repository above it.
NOREPO="$TMPROOT/not-a-repo"; mkdir -p "$NOREPO"
out_nr="$(HOOK_TESTS_ROOT="$NOREPO" bash "$RUNNER" "$NR_DIR" 2>&1)"; code_nr=$?
[ "$code_nr" -eq 0 ] \
  && check "#155 a suite that could not run here does not fail the run" ok \
  || check "#155 a suite that could not run here does not fail the run" "exit=$code_nr out=$out_nr"
printf '%s\n' "$out_nr" | grep -E '^ +NOT RUN +test-needsrepo\.sh' > /dev/null \
  && check "#155 and it is reported as its own outcome, not as ok and not as FAIL" ok \
  || check "#155 and it is reported as its own outcome, not as ok and not as FAIL" "out=$out_nr"
# The reason, or the reader is told a suite did not run and not why (L11).
case "$out_nr" in
  *"needs the repo, and this is a deployed copy"*) check "#155 and the reason it gave is printed" ok ;;
  *) check "#155 and the reason it gave is printed" "out=$out_nr" ;;
esac
# The suite beside it still ran and is still reported, so this is not a runner that gave up.
printf '%s\n' "$out_nr" | grep -E '^ +ok +test-ran\.sh' > /dev/null \
  && check "#155 the suite beside it still ran and is still reported" ok \
  || check "#155 the suite beside it still ran and is still reported" "out=$out_nr"
# And the verdict must not claim everything passed, because everything did not run (L98).
# Matched with `case` rather than a piped quiet grep, which leaves on its first match and can kill
# its own producer under pipefail (claude-config#132, #153, L183). The glob is exact enough to tell
# the two verdicts apart: "ALL 30 SUITES THAT COULD RUN PASSED" does not contain " SUITES PASSED".
case "$out_nr" in
  *"ALL "*" SUITES PASSED"*) check "#155 the verdict does not read as a run where everything passed" "it said ALL SUITES PASSED while one did not run: $out_nr" ;;
  *) check "#155 the verdict does not read as a run where everything passed" ok ;;
esac
case "$out_nr" in
  *"COULD NOT RUN"*) check "#155 the verdict says how many could not run here" ok ;;
  *) check "#155 the verdict says how many could not run here" "out=$out_nr" ;;
esac

# The guard, and the half that stops this becoming a way for any suite to excuse itself. The
# claim is "there is no repository here", and the RUNNER knows that answer independently. Where a
# repository IS present, the same line is a broken suite and must fail the run: without this, a
# suite could opt out of being run anywhere at all and the runner would agree with it (L70, the
# two sides of this comparison come from different places on purpose).
# A repository is named OUTRIGHT rather than relied on from the surroundings. This suite runs both
# from the checkout and from the deployed copy, and in the second there is no repository at all, so
# a check meaning "where a repo IS present" has to bring one (L134).
WITHREPO="$TMPROOT/with-repo"; mkdir -p "$WITHREPO"; git -C "$WITHREPO" init -q
out_nr_repo="$(HOOK_TESTS_ROOT="$WITHREPO" bash "$RUNNER" "$NR_DIR" 2>&1)"; code_nr_repo=$?
[ "$code_nr_repo" -ne 0 ] \
  && check "#155 the same claim where a repo IS present fails the run" ok \
  || check "#155 the same claim where a repo IS present fails the run" "exit=$code_nr_repo out=$out_nr_repo"
case "$out_nr_repo" in
  *test-needsrepo.sh*) check "#155 and it names the suite that claimed it" ok ;;
  *) check "#155 and it names the suite that claimed it" "out=$out_nr_repo" ;;
esac

# ---- and before giving up on it, the CHECKOUT is tried (claude-config#237) ----
# Every pull ended with "3 SUITE(S) COULD NOT RUN HERE" and told the operator to run them from the
# checkout. The checkout is on the SAME Mac, so the pull was announcing a gap it could close
# itself, on every single run, which is how a line stops being read (L36). It also meant a hook
# change could ship having been checked by 46 of 49 suites with nobody noticing which three sat
# out (measured 2026-09-02).
#
# The checkout is NAMED by the caller, never guessed here. claude-sync passes its own SYNC_REPO,
# which is the one directory that certainly holds the payload these hooks came from.
CO_ROOT="$TMPROOT/checkout"; mkdir -p "$CO_ROOT/payload/hooks"
# The copy in the checkout is the SAME suite, and it passes there because a repository is above it.
mk_suite "$CO_ROOT/payload/hooks" needsrepo 0
out_co="$(HOOK_TESTS_ROOT="$NOREPO" RUN_ALL_TESTS_CHECKOUT="$CO_ROOT" bash "$RUNNER" "$NR_DIR" 2>&1)"; code_co=$?
case "$out_co" in
  *"passed from the checkout"*) check "#237 a suite that cannot run here is re-run from the checkout" ok ;;
  *) check "#237 a suite that cannot run here is re-run from the checkout" "out=$out_co" ;;
esac
[ "$code_co" -eq 0 ] \
  && check "#237 and a run whose skipped suites all passed there is green" ok \
  || check "#237 and a run whose skipped suites all passed there is green" "exit=$code_co out=$out_co"
case "$out_co" in
  *"COULD NOT RUN"*) check "#237 and nothing is left reported as unverified" "it still said COULD NOT RUN: $out_co" ;;
  *) check "#237 and nothing is left reported as unverified" ok ;;
esac

# A suite that FAILS from the checkout fails the run. Re-running it is not a way to excuse it: the
# whole point is that its verdict is now real rather than absent (L98).
CO_BAD="$TMPROOT/checkout-bad"; mkdir -p "$CO_BAD/payload/hooks"
mk_suite "$CO_BAD/payload/hooks" needsrepo 1
out_cob="$(HOOK_TESTS_ROOT="$NOREPO" RUN_ALL_TESTS_CHECKOUT="$CO_BAD" bash "$RUNNER" "$NR_DIR" 2>&1)"; code_cob=$?
[ "$code_cob" -ne 0 ] \
  && check "#237 a suite that fails from the checkout fails the run" ok \
  || check "#237 a suite that fails from the checkout fails the run" "exit=$code_cob out=$out_cob"
case "$out_cob" in
  *"failed from the checkout"*) check "#237 and it says where that verdict came from" ok ;;
  *) check "#237 and it says where that verdict came from" "out=$out_cob" ;;
esac

# A checkout that cannot answer either is its own outcome, distinct from having no checkout at
# all: a re-run that changed nothing must not read like one that was never attempted (L11).
CO_NR="$TMPROOT/checkout-notrun"; mkdir -p "$CO_NR/payload/hooks"
mk_notrun_suite "$CO_NR/payload/hooks" needsrepo "no repository there either"
out_conr="$(HOOK_TESTS_ROOT="$NOREPO" RUN_ALL_TESTS_CHECKOUT="$CO_NR" bash "$RUNNER" "$NR_DIR" 2>&1)"
case "$out_conr" in
  *"no repository there either"*) check "#237 a checkout that cannot answer either says so" ok ;;
  *) check "#237 a checkout that cannot answer either says so" "out=$out_conr" ;;
esac

# The control. With no checkout named, the run behaves exactly as it did before, or this would be
# a change nobody could turn off and the NOT RUN path would be dead code (L29).
case "$out_nr" in
  *"COULD NOT RUN"*) check "#237 with no checkout named, the old NOT RUN path still runs" ok ;;
  *) check "#237 with no checkout named, the old NOT RUN path still runs" "out=$out_nr" ;;
esac

# ---- and the re-run says WHICH copy it verified (claude-config#274) ----
# The re-run above closes the gap, and in doing so it makes one report mean two different things.
# Every other suite in a pull's run is checking what the pull just installed. A re-run suite is
# checking the CHECKOUT's copy of the same file, and the line read as an ordinary pass either way.
# The gap is normally nil, since the pull installed from that checkout moments earlier, and it is
# exactly non nil in the case that matters: a local edit nobody has sent, or a checkout behind what
# is deployed (L11).
#
# The checkout also holds .last-applied, which the pull writes with the commit whose payload is on
# this Mac, so the runner can say whether the two agree rather than assume they do.
co_git_fixture(){ # co_git_fixture <dir> <exit code for the suite>   -> a checkout that is a repo
  mkdir -p "$1/payload/hooks"
  mk_suite "$1/payload/hooks" needsrepo "$2"
  git -C "$1" init -q
  git -C "$1" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false \
      add -A >/dev/null 2>&1
  git -C "$1" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false \
      commit -qm "the payload this Mac is running" >/dev/null 2>&1
  git -C "$1" rev-parse HEAD 2>/dev/null
}
CO_SAME="$TMPROOT/checkout-same"
co_head="$(co_git_fixture "$CO_SAME" 0)"
printf '%s\n' "$co_head" > "$CO_SAME/.last-applied"
out_pv="$(HOOK_TESTS_ROOT="$NOREPO" RUN_ALL_TESTS_CHECKOUT="$CO_SAME" bash "$RUNNER" "$NR_DIR" 2>&1)"; code_pv=$?
[ "$code_pv" -eq 0 ] \
  && check "#274 a re-run from a checkout that matches what was applied still passes" ok \
  || check "#274 a re-run from a checkout that matches what was applied still passes" "exit=$code_pv out=$out_pv"
case "$out_pv" in
  *"$CO_SAME"*)
    check "#274 and the line names the checkout it verified" ok ;;
  *)
    check "#274 and the line names the checkout it verified" "out=$out_pv" ;;
esac
case "$out_pv" in
  *"not the copy installed here"*)
    check "#274 and says that copy is not the installed one" ok ;;
  *)
    check "#274 and says that copy is not the installed one" "out=$out_pv" ;;
esac
case "$out_pv" in
  *"which is what the pull applied"*)
    check "#274 and says the two agree when they do" ok ;;
  *)
    check "#274 and says the two agree when they do" "out=$out_pv" ;;
esac

# The case the line exists for: a checkout that is not what was applied. The verdict is still real,
# and it is a verdict about a different revision, so it is reported as one rather than as coverage
# of what is installed.
CO_DRIFT="$TMPROOT/checkout-drift"
co_git_fixture "$CO_DRIFT" 0 > /dev/null
printf '%s\n' "0000000000000000000000000000000000000000" > "$CO_DRIFT/.last-applied"
out_dv="$(HOOK_TESTS_ROOT="$NOREPO" RUN_ALL_TESTS_CHECKOUT="$CO_DRIFT" bash "$RUNNER" "$NR_DIR" 2>&1)"
case "$out_dv" in
  *"is NOT what the pull applied"*)
    check "#274 a checkout ahead of or behind what was applied says so" ok ;;
  *)
    check "#274 a checkout ahead of or behind what was applied says so" "out=$out_dv" ;;
esac
case "$out_dv" in
  *0000000*)
    check "#274 and names the commit that was applied, so the two can be compared" ok ;;
  *)
    check "#274 and names the commit that was applied, so the two can be compared" "out=$out_dv" ;;
esac

# An uncommitted edit is the same defect arriving by the other route, and the one a person is most
# likely to hit: the suite that passed is the one on the screen, not the one anybody else can get.
CO_DIRTY="$TMPROOT/checkout-dirty"
co_head_d="$(co_git_fixture "$CO_DIRTY" 0)"
printf '%s\n' "$co_head_d" > "$CO_DIRTY/.last-applied"
printf '\n# an edit that has not been committed\n' >> "$CO_DIRTY/payload/hooks/test-needsrepo.sh"
out_uv="$(HOOK_TESTS_ROOT="$NOREPO" RUN_ALL_TESTS_CHECKOUT="$CO_DIRTY" bash "$RUNNER" "$NR_DIR" 2>&1)"
case "$out_uv" in
  *"uncommitted"*)
    check "#274 a checkout with an uncommitted edit says the verdict is about that edit" ok ;;
  *)
    check "#274 a checkout with an uncommitted edit says the verdict is about that edit" "out=$out_uv" ;;
esac

# A checkout that is not a repository at all cannot be compared, and saying nothing would leave the
# reader with the same unmarked pass this issue is about. It says it could not read the revision.
case "$out_co" in
  *"could not be read"*)
    check "#274 a checkout whose revision cannot be read says so rather than staying quiet" ok ;;
  *)
    check "#274 a checkout whose revision cannot be read says so rather than staying quiet" "out=$out_co" ;;
esac

# And a FAILING re-run carries the same provenance. The verdict a person acts on hardest is the red
# one, and "it failed" over an unnamed copy sends them to the wrong file.
case "$out_cob" in
  *"$CO_BAD"*)
    check "#274 a failing re-run names the checkout its verdict came from" ok ;;
  *)
    check "#274 a failing re-run names the checkout its verdict came from" "out=$out_cob" ;;
esac

# A run where nothing could not run keeps the wording it had, so an ordinary green run reads
# exactly as it did before (L103: a guard that asserts a rendering fails the first refinement of
# it, and this is the rendering everybody reads).
OK_DIR="$TMPROOT/dir-notrun-clean"
mk_suite "$OK_DIR" onlyone 0
out_nr_clean="$(bash "$RUNNER" "$OK_DIR" 2>&1)"
case "$out_nr_clean" in
  *"ALL "*" SUITES PASSED"*) check "#155 a run with nothing skipped still says ALL SUITES PASSED" ok ;;
  *) check "#155 a run with nothing skipped still says ALL SUITES PASSED" "out=$out_nr_clean" ;;
esac

# ---------------------------------------------------------------------------
# A runner killed from outside takes the suites it started with it (claude-config#165).
# ---------------------------------------------------------------------------
# The runner installs a cleanup on EXIT, which covers a run that ENDS. It did not cover one killed
# from OUTSIDE, which is how a run in development actually stops: a harness timeout, a Ctrl-C, a
# terminal closing. It launches as many suites at once as its own budget allows, so what was left
# behind was every one of them, each still holding whatever lock its own suite takes and all of them
# competing for the machine. That is the same gap claude-config#163 closed one level down, and the runner is the
# thing a person actually interrupts.
mk_hanging_suite() { # mk_hanging_suite <dir> <name>
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo $$ > "$(dirname "$0")/%s.pid"\n' "$2"
    # Blocked on a child it is WAITING for, not sitting in a foreground sleep. Bash defers a
    # trapped signal until the foreground command finishes, so a suite stalled inside a long sleep
    # could not run any handler of its own, and the durable child is what makes an orphan
    # observable after the parent has gone.
    printf 'while :; do sleep 3600 & wait "$!" || true; done\n'
  } > "$1/test-$2.sh"
  chmod +x "$1/test-$2.sh"
}
# SEVERAL of them, not one (claude-config#171). Running many at once is the runner's whole shape,
# and leaving all of them behind is what made this worth closing. With a single suite in flight, a
# cleanup that reaped only the most recently launched child, or stopped at the first one it found,
# would pass every check here (L101: a fixture is minimal by construction, so the mode that
# actually ships is the one never exercised). The negative control at the end of this block is what
# proves the difference is visible.
K="$TMPROOT/dir-killed"
for k_n in one two three; do mk_hanging_suite "$K" "$k_n"; done

# Runs the interrupt and leaves the surviving pids in k_left. Taken as a function because the
# negative control below has to do the identical thing against a deliberately broken copy of the
# runner, and two spellings of "do the identical thing" is how a control ends up proving something
# else (L107).
k_left=""; k_started=""
run_and_interrupt() { # run_and_interrupt <runner path>
  local r="$1" w=0 n p
  rm -f "$K"/*.pid
  HOOK_KILL_TREE="${HOOK_KILL_TREE:-}" bash "$r" "$K" > "$TMPROOT/killed.out" 2>&1 &
  k_runner=$!
  # Each suite names its own pid, so what is checked afterwards is what the runner really started
  # rather than whatever the process table happens to hold. Waited for, never assumed: a fixture
  # that never got going satisfies every assertion after it while proving nothing (L159).
  while [ "$w" -lt 60 ]; do
    k_started=""
    for n in one two three; do
      p="$(cat "$K/$n.pid" 2>/dev/null || true)"
      case "$p" in ''|*[!0-9]*) continue ;; esac
      kill -0 "$p" 2>/dev/null && k_started="$k_started $p"
    done
    [ "$(printf '%s' "$k_started" | wc -w | tr -d ' ')" -ge 2 ] && break
    sleep 1; w=$((w + 1))
  done
  k_kids=""
  for p in $k_started; do k_kids="$k_kids $(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')"; done
  kill -TERM "$k_runner" 2>/dev/null || true
  local g=0
  while [ "$g" -lt 30 ] && kill -0 "$k_runner" 2>/dev/null; do sleep 1; g=$((g + 1)); done
  sleep 1
  k_runner_left=""
  kill -0 "$k_runner" 2>/dev/null && k_runner_left="$k_runner"
  k_left=""
  for p in $k_started $k_kids; do kill -0 "$p" 2>/dev/null && k_left="$k_left $p"; done
  for p in $k_started $k_kids; do kill -9 "$p" 2>/dev/null || true; done
  kill -9 "$k_runner" 2>/dev/null
  wait "$k_runner" 2>/dev/null || true
}

run_and_interrupt "$RUNNER"
k_n_started="$(printf '%s' "$k_started" | wc -w | tr -d ' ')"
[ "${k_n_started:-0}" -ge 2 ] \
  && check "#171 the runner really had several suites going at once ($k_n_started)" ok \
  || check "#171 the runner really had several suites going at once" "only $k_n_started started, so one suite could satisfy the rest"
case "$(printf '%s' "$k_kids" | tr -d ' ')" in
  ?*) check "#165 and those suites had children of their own to leave behind" ok ;;
  *)  check "#165 and those suites had children of their own to leave behind" "no children found" ;;
esac
case "$k_runner_left" in
  "") check "#165 the interrupted runner itself is gone" ok ;;
  *)  check "#165 the interrupted runner itself is gone" "pid $k_runner_left is still running" ;;
esac
case "$k_left" in
  "") check "#165 an interrupted runner takes every suite and child with it" ok ;;
  *)  check "#165 an interrupted runner takes every suite and child with it" "still running:$k_left" ;;
esac

# The negative control. A cleanup that stops after the first child it finds leaves the rest behind,
# and with one suite in flight that is indistinguishable from a correct one. Run against a COPY
# with exactly that defect, so the difference between the two is measured rather than argued
# (L1: a guard is only real once it has been watched failing).
# The negative control. A cleanup that reaches only the runner's DIRECT children leaves each
# suite's own children behind, and with one suite in flight that is indistinguishable from a
# correct one. Run against a copy of the shared helper with exactly that defect, pointed at through
# the seam, so the difference between the two is measured rather than argued (L1).
REALTREE="$(dirname "$RUNNER")/lib/kill-tree.sh"
BROKEN="$TMPROOT/kill-tree-no-recursion.sh"
sed '/^    kill_tree "\$c"$/d' "$REALTREE" > "$BROKEN"
if [ ! -f "$REALTREE" ]; then
  check "#171 the negative control really is a different implementation" "no helper at $REALTREE to break"
elif cmp -s "$BROKEN" "$REALTREE"; then
  check "#171 the negative control really is a different implementation" "the edit matched nothing, so this control tests the same code twice"
else
  check "#171 the negative control really is a different implementation" ok
  HOOK_KILL_TREE="$BROKEN" run_and_interrupt "$RUNNER"
  case "$k_left" in
    "") check "#171 and a cleanup that misses grandchildren WOULD be caught" "it left nothing behind, so these checks cannot tell the two apart" ;;
    *)  check "#171 and a cleanup that misses grandchildren WOULD be caught" ok ;;
  esac
fi

# ---------------------------------------------------------------------------
# A suite that finishes early with FEWER checks is SAID to have (claude-config#219).
# ---------------------------------------------------------------------------
# The runner reads each suite's `SUITE-RESULT passed=N failed=M` line exactly, and a suite that
# dies leaves none, which it catches. What it could not catch is a suite that finishes honestly
# and EARLY: a fixture glob that matches nothing, a loop over an empty list, a case table that
# lost a row. That suite reports `12 passed, 0 failed` and reads as green, and the only thing
# wrong with it is a number nobody is comparing against anything (L288).
#
# So the store that already holds what each suite COST also holds how many checks it ran, and a
# suite reporting fewer than last time says so where the verdict is read. Not a failure: counts
# legitimately fall when tests are deleted. Visible, so the fall is a decision rather than a
# discovery (L11).
CK="$TMPROOT/checks"
CKSTORE="$TMPROOT/checks-store"
mkdir -p "$CK/suites" "$CKSTORE"
mk_counting_suite() { # mk_counting_suite <dir> <name> <how many checks it reports>
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "SUITE-RESULT passed=%%s failed=0\\n" "%s"\n' "$3"
  } > "$1/test-$2.sh"
  chmod +x "$1/test-$2.sh"
}
mk_counting_suite "$CK/suites" steady 40
mk_counting_suite "$CK/suites" shrinker 30

# The first run has nothing to compare against. It must say so: a run that compared nothing and a
# run in which nothing dropped print the same silence otherwise, and the silence is the whole
# signal here (L98).
out_c1="$(HOOK_TESTS_ROOT="$CK" HOOK_TESTS_TIMINGS="$CKSTORE" HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$CK/suites" 2>&1)"; code_c1=$?
[ "$code_c1" -eq 0 ] \
  && check "#219 a first run, with no counts to compare against, passes" ok \
  || check "#219 a first run, with no counts to compare against, passes" "exit=$code_c1 out=$out_c1"
case "$out_c1" in
  *"check counts compared against the last run for 0 of 2 suite(s)"*)
    check "#219 and it says it had no stored count for any of them" ok ;;
  *)
    check "#219 and it says it had no stored count for any of them" "out=$out_c1" ;;
esac
case "$out_c1" in
  *"fewer checks"*)
    check "#219 and a suite with no stored count is not reported as having dropped everything" "out=$out_c1" ;;
  *)
    check "#219 and a suite with no stored count is not reported as having dropped everything" ok ;;
esac

# Now one of them shrinks and the other holds. The run that just finished wrote both counts, so
# what this compares against is what the runner itself recorded, not a number this file invented
# (L48).
mk_counting_suite "$CK/suites" shrinker 12
out_c2="$(HOOK_TESTS_ROOT="$CK" HOOK_TESTS_TIMINGS="$CKSTORE" HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$CK/suites" 2>&1)"; code_c2=$?
[ "$code_c2" -eq 0 ] \
  && check "#219 a drop is reported, not failed: counts legitimately fall when tests are deleted" ok \
  || check "#219 a drop is reported, not failed: counts legitimately fall when tests are deleted" "exit=$code_c2 out=$out_c2"
case "$out_c2" in
  *"check counts compared against the last run for 2 of 2 suite(s)"*)
    check "#219 and the second run says it had a count for both" ok ;;
  *)
    check "#219 and the second run says it had a count for both" "out=$out_c2" ;;
esac
# BOTH numbers, on the line, because "fewer checks" alone sends the reader to run the suite again
# to find out how many fewer (L11, L80).
c2_drop="$(printf '%s\n' "$out_c2" | grep -F 'fewer checks' | tr -s ' ')"
c2_ok=1
case "$c2_drop" in *shrinker*) ;; *) c2_ok=0 ;; esac
case "$c2_drop" in *12*) ;; *) c2_ok=0 ;; esac
case "$c2_drop" in *30*) ;; *) c2_ok=0 ;; esac
[ "$c2_ok" -eq 1 ] \
  && check "#219 the shrinking suite's line names it and both counts" ok \
  || check "#219 the shrinking suite's line names it and both counts" "the drop line was '$c2_drop'"
# And the suite that did NOT shrink says nothing, or the line is noise on every run and stops
# being read (L36).
[ "$(printf '%s\n' "$out_c2" | grep -cF 'fewer checks' | tr -d ' ')" = 1 ] \
  && check "#219 and the suite whose count held is not mentioned" ok \
  || check "#219 and the suite whose count held is not mentioned" "$(printf '%s\n' "$out_c2" | grep -F 'fewer checks')"

# A count that GROWS is not a drop. Without this, a runner reporting every change would satisfy
# the checks above (L178, L159).
mk_counting_suite "$CK/suites" shrinker 99
out_c3="$(HOOK_TESTS_ROOT="$CK" HOOK_TESTS_TIMINGS="$CKSTORE" HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$CK/suites" 2>&1)"; code_c3=$?
[ "$code_c3" -eq 0 ] && [ "$(printf '%s\n' "$out_c3" | grep -cF 'fewer checks' | tr -d ' ')" = 0 ] \
  && check "#219 a count that grew is not reported as a drop" ok \
  || check "#219 a count that grew is not reported as a drop" "exit=$code_c3 out=$out_c3"

# The store switched off compares nothing, and says so rather than reading as a run in which
# nothing dropped, exactly as the timing half of the same store already does.
out_c4="$(HOOK_TESTS_ROOT="$CK" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$CK/suites" 2>&1)"; code_c4=$?
[ "$code_c4" -eq 0 ] \
  && check "#219 an empty HOOK_TESTS_TIMINGS turns the comparison off and the run still passes" ok \
  || check "#219 an empty HOOK_TESTS_TIMINGS turns the comparison off and the run still passes" "exit=$code_c4 out=$out_c4"
case "$out_c4" in
  *"check counts compared against the last run for 0 of 2 suite(s)"*)
    check "#219 and a run with the store off says it compared nothing" ok ;;
  *)
    check "#219 and a run with the store off says it compared nothing" "out=$out_c4" ;;
esac

# The count lives BESIDE the duration in one record, so nothing that reads the duration may be
# disturbed by it. A record holding seconds alone is what every store on disk contains the first
# time this ships, and it must still order the launches (L255, L267).
CKOLD="$TMPROOT/checks-old-store"
mkdir -p "$CKOLD"
ck_key="$(ls "$CKSTORE" 2>/dev/null | grep 'test-shrinker\.sh$' | awk 'NR==1')"
printf '77\n' > "$CKOLD/$ck_key"
out_c5="$(HOOK_TESTS_ROOT="$CK" HOOK_TESTS_TIMINGS="$CKOLD" HOOK_TESTS_BUDGET=4 HOOK_TESTS_JOBS=2 bash "$RUNNER" "$CK/suites" 2>&1)"; code_c5=$?
order_c5="$(printf '%s\n' "$out_c5" | sed -n 's/^run-all-tests: launch order: //p' | tail -1)"
c5_ok=0
case "$order_c5" in "test-shrinker.sh "*) c5_ok=1 ;; esac
[ "$code_c5" -eq 0 ] && [ "$c5_ok" -eq 1 ] \
  && check "#219 a record written before counts existed still orders the launches by its seconds" ok \
  || check "#219 a record written before counts existed still orders the launches by its seconds" "exit=$code_c5 launch order was '$order_c5'"
case "$out_c5" in
  *"check counts compared against the last run for 0 of 2 suite(s)"*)
    check "#219 and it carries no count, so nothing is compared against it" ok ;;
  *)
    check "#219 and it carries no count, so nothing is compared against it" "out=$out_c5" ;;
esac

# ---------------------------------------------------------------------------
# A timing that measured a REFUSAL is not a measurement (claude-config#229).
# ---------------------------------------------------------------------------
# The store held 0 for tests/test-claude-sync.sh, which is the slowest suite in this repo by a
# factor of four and was measured at 231 seconds in the same session. The launch order that record
# produced put it 41st of 44, so the slowest suite ran last on the smallest share of the budget
# with everything else already finished, while this runner reported "launch order from measured
# wall clock for 44 of 44 suite(s)". The run is simply slower, which is the symptom #139 existed to
# remove, and nothing in the output reads as wrong.
#
# A suite that exits at once leaves a real measurement of zero, and the runner recorded what a
# suite COST without asking whether it did anything. The sync suite exits in well under a second
# when it refuses its own lock, so a moment of overlap between two runs governs every run
# afterwards until a clean one happens to overwrite it (L330).
#
# What tells the two apart is already in front of the runner: a suite that did its work prints its
# own SUITE-RESULT line, and one that refused, died or could not run here does not.
RF="$TMPROOT/refusal"
RFSTORE="$TMPROOT/refusal-store"
mkdir -p "$RF/suites" "$RFSTORE"
mk_counting_suite "$RF/suites" honest 12
# A suite that refuses at once, exactly as the sync suite does when it meets its own lock: no
# result line, non-zero, instantly.
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "another run is already going. Refusing rather than queueing behind it." >&2\n'
  printf 'exit 2\n'
} > "$RF/suites/test-refuser.sh"
chmod +x "$RF/suites/test-refuser.sh"

out_rf="$(HOOK_TESTS_ROOT="$RF" HOOK_TESTS_TIMINGS="$RFSTORE" HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$RF/suites" 2>&1)"; code_rf=$?
[ "$code_rf" -ne 0 ] \
  && check "#229 a suite that refused still fails the run" ok \
  || check "#229 a suite that refused still fails the run" "exit=$code_rf out=$out_rf"
rf_key="$(ls "$RFSTORE" 2>/dev/null | grep 'test-refuser\.sh$' | awk 'NR==1')"
[ -z "$rf_key" ] \
  && check "#229 and no timing is recorded for it, because it measured a refusal" ok \
  || check "#229 and no timing is recorded for it, because it measured a refusal" "it recorded '$(cat "$RFSTORE/$rf_key" 2>/dev/null)' under $rf_key"
# The control, and the whole of what makes the check above mean anything: the suite that DID its
# work in the same run is recorded. Without it a runner that stopped recording altogether would
# pass (L159, L1).
rf_ok_key="$(ls "$RFSTORE" 2>/dev/null | grep 'test-honest\.sh$' | awk 'NR==1')"
[ -n "$rf_ok_key" ] \
  && check "#229 and the suite that did its work in the same run IS recorded" ok \
  || check "#229 and the suite that did its work in the same run IS recorded" "$(ls "$RFSTORE" 2>/dev/null | tr '\n' ' ')"

# A record that already exists is LEFT ALONE by a run that refused, rather than overwritten with
# the refusal's zero. That is the case that actually bit on 2026-08-30: the store held a good
# record, measured at 231 seconds in that same session, and one overlapping run replaced it.
printf '231 900\n' > "$RFSTORE/$(ls "$RFSTORE" | grep 'test-honest' | awk 'NR==1')" 2>/dev/null || true
RFK="$(printf '%s' "suites/test-refuser.sh" | sed 's/%/%25/g; s#/#%2F#g')"
printf '231 900\n' > "$RFSTORE/$RFK"
HOOK_TESTS_ROOT="$RF" HOOK_TESTS_TIMINGS="$RFSTORE" HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$RF/suites" >/dev/null 2>&1
[ "$(awk 'NR==1{print $1}' "$RFSTORE/$RFK" 2>/dev/null)" = 231 ] \
  && check "#229 a good record survives a run in which that suite refused" ok \
  || check "#229 a good record survives a run in which that suite refused" "it now reads '$(cat "$RFSTORE/$RFK" 2>/dev/null)'"

# And the run SAYS when the suite it launched first is not the one that took longest, which is the
# single line that would have made the original defect visible without reading the cache by hand
# (L11). The refuser has no record so it is launched last by size among the unmeasured, and the
# honest suite leads; the fixture below is the other way round.
LEAD="$TMPROOT/lead"
LEADSTORE="$TMPROOT/lead-store"
mkdir -p "$LEAD/suites" "$LEADSTORE"
mk_slot_suite "$LEAD/suites" quick
{
  printf '#!/usr/bin/env bash\n'
  printf 'sleep 2\n'
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
} > "$LEAD/suites/test-slowest.sh"
chmod +x "$LEAD/suites/test-slowest.sh"
# A record that makes the FAST suite lead, which is exactly the shape a poisoned store produces.
printf '99\n' > "$LEADSTORE/$(printf '%s' "suites/test-quick.sh" | sed 's/%/%25/g; s#/#%2F#g')"
printf '0\n'  > "$LEADSTORE/$(printf '%s' "suites/test-slowest.sh" | sed 's/%/%25/g; s#/#%2F#g')"
out_lead="$(HOOK_TESTS_ROOT="$LEAD" HOOK_TESTS_TIMINGS="$LEADSTORE" HOOK_TESTS_BUDGET=4 HOOK_TESTS_JOBS=2 bash "$RUNNER" "$LEAD/suites" 2>&1)"
case "$out_lead" in
  *"launched first is not the one that took longest"*)
    check "#229 the run says when the suite it launched first was not the slowest" ok ;;
  *)
    check "#229 the run says when the suite it launched first was not the slowest" "out=$out_lead" ;;
esac
# The control: a run whose order was right says nothing, or the line is on every run and stops
# being read (L36, L159). The store now holds what the run above measured, so this one leads with
# the suite that really is slowest.
out_lead2="$(HOOK_TESTS_ROOT="$LEAD" HOOK_TESTS_TIMINGS="$LEADSTORE" HOOK_TESTS_BUDGET=4 HOOK_TESTS_JOBS=2 bash "$RUNNER" "$LEAD/suites" 2>&1)"
case "$out_lead2" in
  *"launched first is not the one that took longest"*)
    check "#229 and a run that led with the slowest suite says nothing" "out=$out_lead2" ;;
  *)
    check "#229 and a run that led with the slowest suite says nothing" ok ;;
esac

# ---------------------------------------------------------------------------
# A spool write is ATTRIBUTED before the run is failed for it (claude-config#230).
# ---------------------------------------------------------------------------
# The runner brackets every run with a listing and a byte count of the live issue spool, and
# reports ANY change as a suite violating L2. That is the right shape for the defect it was built
# for, a suite that sources lib/issue-spool.sh before setting CLAUDE_ISSUE_SPOOL_DIR. But the spool
# is a machine wide store with other legitimate writers, and this Mac routinely runs several Claude
# sessions at once: measured 2026-08-30, a run in which all 44 suites passed was failed by 1,180
# bytes a session working in a completely different repository had written while it ran.
#
# Every record carries the working directory it came from, so the added lines are read and judged
# one at a time. This is the same shape as #159, where a global watchdog count was made specific by
# tagging so it could only ever include the run's own.
SPOOL="$TMPROOT/live-spool"
SP="$TMPROOT/spooltest"
mkdir -p "$SPOOL" "$SP/suites"
sp_record(){   # sp_record <cwd> -> one spool line
  printf '{"ts":"2026-08-30T12:00:00Z","status":"found","agent":"","session":"s","cwd":"%s","findings":["x"]}\n' "$1"
}
# A suite that writes into the live spool from ELSEWHERE, standing in for another session's
# harvest firing mid-run. It is a suite only so that something writes while the runner is watching.
mk_spool_writer(){   # mk_spool_writer <name> <cwd to record>
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf %s >> "%s/other.jsonl"\n' "'$(sp_record "$2")'" "$SPOOL"
    printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
  } > "$SP/suites/test-$1.sh"
  chmod +x "$SP/suites/test-$1.sh"
}

# Another project's session. The run must PASS, and must say the spool grew without blaming itself.
# A path outside this repo and outside any temp directory, which is what makes it somebody else's.
# Not under /Users: check-home-paths refuses a line naming one machine's home directory, and it is
# right to, because such a line is wrong on every other Mac (measured, it caught this).
mk_spool_writer elsewhere "/opt/another-project/checkout"
out_sp="$(CLAUDE_ISSUE_SPOOL_DIR="$SPOOL" HOOK_TESTS_ROOT="$SP" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$SP/suites" 2>&1)"; code_sp=$?
[ "$code_sp" -eq 0 ] \
  && check "#230 a spool write from another project does not fail the run" ok \
  || check "#230 a spool write from another project does not fail the run" "exit=$code_sp out=$out_sp"
case "$out_sp" in
  *"from work in other directories"*)
    check "#230 and the run says the spool grew and that it was not its doing" ok ;;
  *)
    check "#230 and the run says the spool grew and that it was not its doing" "out=$out_sp" ;;
esac
case "$out_sp" in
  *"SUITES WROTE INTO THE LIVE SPOOL"*)
    check "#230 and it does not accuse a suite of writing it" "out=$out_sp" ;;
  *)
    check "#230 and it does not accuse a suite of writing it" ok ;;
esac

# The half that must still work, and the reason none of this may be loosened: a suite writing from
# inside the repo under test is the real violation and still fails the run (L1, L159).
rm -f "$SPOOL"/*.jsonl "$SP/suites"/test-elsewhere.sh
mk_spool_writer inside "$SP/a/b"
out_sp2="$(CLAUDE_ISSUE_SPOOL_DIR="$SPOOL" HOOK_TESTS_ROOT="$SP" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$SP/suites" 2>&1)"; code_sp2=$?
[ "$code_sp2" -ne 0 ] \
  && check "#230 a suite writing from inside the repo still fails the run" ok \
  || check "#230 a suite writing from inside the repo still fails the run" "exit=$code_sp2 out=$out_sp2"
case "$out_sp2" in
  *"SUITES WROTE INTO THE LIVE SPOOL"*)
    check "#230 and it is named as the L2 violation it is" ok ;;
  *)
    check "#230 and it is named as the L2 violation it is" "out=$out_sp2" ;;
esac
case "$out_sp2" in
  *"$SP/a/b"*)
    check "#230 and the directory the record came from is printed" ok ;;
  *)
    check "#230 and the directory the record came from is printed" "out=$out_sp2" ;;
esac

# A record with no working directory at all cannot be attributed, and an unattributable change must
# not read as a clean one (L98, L11).
rm -f "$SPOOL"/*.jsonl "$SP/suites"/test-inside.sh
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf %s >> "%s/other.jsonl"\n' "'{\"ts\":\"2026-08-30T12:00:00Z\",\"status\":\"found\"}'" "$SPOOL"
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
} > "$SP/suites/test-anon.sh"
chmod +x "$SP/suites/test-anon.sh"
out_sp3="$(CLAUDE_ISSUE_SPOOL_DIR="$SPOOL" HOOK_TESTS_ROOT="$SP" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$SP/suites" 2>&1)"; code_sp3=$?
[ "$code_sp3" -ne 0 ] \
  && check "#230 a record that cannot be attributed fails the run" ok \
  || check "#230 a record that cannot be attributed fails the run" "exit=$code_sp3 out=$out_sp3"
case "$out_sp3" in
  *"could not be attributed"*)
    check "#230 and it says so, rather than asserting a suite wrote it" ok ;;
  *)
    check "#230 and it says so, rather than asserting a suite wrote it" "out=$out_sp3" ;;
esac

# The sizes are read for EVERY file in one `wc` rather than one per file, because the real spool
# holds 157 of them and forking per file was 414ms of a 600ms launch (claude-config#239). What has
# to survive that is reading the size of EACH file: only the bytes a run ADDED are judged, and a
# reader that lost the per file sizes would treat every existing record as new.
#
# So the fixture puts a record that would be blamed on a suite into a file NOTHING touches, and has
# the run append to a DIFFERENT file from elsewhere. Read correctly the run passes, because the only
# added bytes came from elsewhere. Read without the sizes the untouched file is re-read from the
# start and its record fails the run. Two files, because one cannot tell the two readings apart.
rm -f "$SPOOL"/*.jsonl "$SP/suites"/test-quiet.sh "$SP/suites"/test-anon.sh
printf '%s\n' "$(sp_record "$SP/a/b")" > "$SPOOL/untouched.jsonl"
mk_spool_writer beside "/opt/another-project/checkout"
out_sp5="$(CLAUDE_ISSUE_SPOOL_DIR="$SPOOL" HOOK_TESTS_ROOT="$SP" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$SP/suites" 2>&1)"; code_sp5=$?
[ "$code_sp5" -eq 0 ] \
  && check "#239 only the bytes this run added are judged, across several spool files" ok \
  || check "#239 only the bytes this run added are judged, across several spool files" "exit=$code_sp5 out=$out_sp5"
case "$out_sp5" in
  *"SUITES WROTE INTO THE LIVE SPOOL"*)
    check "#239 and a record nothing touched is not blamed on this run" "out=$out_sp5" ;;
  *)
    check "#239 and a record nothing touched is not blamed on this run" ok ;;
esac
# The positive control, from the same fixture: the run DID grow a file, so this is not a case where
# the bracket had nothing to look at (L159, L100).
case "$out_sp5" in
  *"from work in other directories"*)
    check "#239 and the file that did grow was seen" ok ;;
  *)
    check "#239 and the file that did grow was seen" "out=$out_sp5" ;;
esac
rm -f "$SPOOL"/*.jsonl "$SP/suites"/test-beside.sh

# And the control for all of it: a run that touched the spool not at all says nothing about it.
rm -f "$SPOOL"/*.jsonl "$SP/suites"/test-anon.sh
mk_counting_suite "$SP/suites" quiet 3
out_sp4="$(CLAUDE_ISSUE_SPOOL_DIR="$SPOOL" HOOK_TESTS_ROOT="$SP" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$SP/suites" 2>&1)"; code_sp4=$?
case "$out_sp4" in
  *"LIVE SPOOL"*|*"other directories"*)
    check "#230 a run that wrote nothing to the spool says nothing about it" "out=$out_sp4" ;;
  *)
    [ "$code_sp4" -eq 0 ] \
      && check "#230 a run that wrote nothing to the spool says nothing about it" ok \
      || check "#230 a run that wrote nothing to the spool says nothing about it" "exit=$code_sp4" ;;
esac

# ---------------------------------------------------------------------------
# What each suite said about dividing its OWN work reaches the log (claude-config#232).
# ---------------------------------------------------------------------------
# A passing suite's output is printed NOWHERE, so a suite that went back to counting its sections
# instead of using what it measured would simply be slower, on every run, with nothing anywhere
# saying so. That is the silent regression the whole timings milestone existed to remove, one level
# up (L3, L98). The suites report it in a line a machine can read and the runner echoes it.
DV="$TMPROOT/divisions"; mkdir -p "$DV/suites"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "SUITE-DIVISION measured=7 total=9 by=section-time"\n'
  printf 'echo "SUITE-DIVISION measured=7 total=9 by=section-time"\n'
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
} > "$DV/suites/test-divider.sh"
chmod +x "$DV/suites/test-divider.sh"
mk_counting_suite "$DV/suites" quietone 2
out_dv="$(HOOK_TESTS_ROOT="$DV" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$DV/suites" 2>&1)"; code_dv=$?
[ "$code_dv" -eq 0 ] \
  && check "#232 a suite reporting its own division still passes" ok \
  || check "#232 a suite reporting its own division still passes" "exit=$code_dv out=$out_dv"
case "$out_dv" in
  *"how each suite divided its own work"*"test-divider.sh: SUITE-DIVISION measured=7 total=9"*)
    check "#232 and the runner echoes what it said, naming the suite" ok ;;
  *)
    check "#232 and the runner echoes what it said, naming the suite" "out=$out_dv" ;;
esac
# Each shard of a sharded suite prints its own copy, so the same line arrives several times and the
# echo would say it several times. Deduplicated, or the log grows with the shard count and says
# nothing more.
_dv_n="$(printf '%s\n' "$out_dv" | grep -c 'test-divider.sh: SUITE-DIVISION' || true)"
[ "${_dv_n:-0}" -eq 1 ] \
  && check "#232 and it says it once however many times the suite said it" ok \
  || check "#232 and it says it once however many times the suite said it" "it appeared ${_dv_n:-0} times"
# The control: a run where nothing divides anything says nothing about division, or the line is
# printed on every run and stops being read (L36, L159).
rm -f "$DV/suites/test-divider.sh"
out_dv2="$(HOOK_TESTS_ROOT="$DV" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 bash "$RUNNER" "$DV/suites" 2>&1)"
case "$out_dv2" in
  *"how each suite divided its own work"*)
    check "#232 a run where nothing reported a division says nothing about it" "out=$out_dv2" ;;
  *)
    check "#232 a run where nothing reported a division says nothing about it" ok ;;
esac

# ---------------------------------------------------------------------------
# WHO wrote is answered by a marker the suites carry, not by where the record came from
# (claude-config#275).
# ---------------------------------------------------------------------------
# The attribution above splits on the record's own working directory: inside this repo means a
# suite, elsewhere means another session. That split cannot see the normal case on this machine,
# which is a second Claude session working in THIS repo. Measured 2026-09-02, a run was failed by
# two HARVEST FAILED records the real SubagentStop hook wrote for another session, cwd this repo,
# and no suite in the tree can write there because they all set CLAUDE_ISSUE_SPOOL_DIR first.
#
# So the runner stamps every write a suite makes: it exports a run id, and the spool library puts
# it in the record. A record carrying one was written under a test run and is the L2 violation this
# exists to catch. A record carrying none was not, whatever directory it names. That is positive
# identification rather than a second heuristic on top of the first (L70).
#
# TMPDIR is pointed away from the fixture on purpose, so a record naming a fixture path is judged
# by the rule under test rather than by the throwaway-directory branch above it.
SP2="$TMPROOT/spool275"
SPOOL2="$TMPROOT/live-spool-275"
mkdir -p "$SPOOL2" "$SP2/suites" "$SP2/nottmp"
sp2_run(){ # sp2_run [extra env assignments...]   -> one runner run over the #275 fixtures
  env TMPDIR="$SP2/nottmp" CLAUDE_ISSUE_SPOOL_DIR="$SPOOL2" HOOK_TESTS_ROOT="$SP2" \
      HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 "$@" bash "$RUNNER" "$SP2/suites" 2>&1
}
# Another session, working in this repo: a record naming a path inside the root, with no marker.
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf %s >> "%s/other.jsonl"\n' \
    "'{\"ts\":\"2026-09-02T12:00:00Z\",\"status\":\"error\",\"agent\":\"subagent\",\"cwd\":\"$SP2/a/b\",\"error\":\"no transcript\"}'" "$SPOOL2"
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
} > "$SP2/suites/test-othersession.sh"
chmod +x "$SP2/suites/test-othersession.sh"
out_m1="$(sp2_run)"; code_m1=$?
[ "$code_m1" -eq 0 ] \
  && check "#275 an unmarked record from inside this repo does not fail the run" ok \
  || check "#275 an unmarked record from inside this repo does not fail the run" "exit=$code_m1 out=$out_m1"
case "$out_m1" in
  *"from work in other directories"*)
    check "#275 and the run says the spool grew without blaming itself" ok ;;
  *)
    check "#275 and the run says the spool grew without blaming itself" "out=$out_m1" ;;
esac

# The half that must still fire, and the reason the loosening above is safe: a suite that writes
# through the spool library, which is what the defect actually looks like, carries the marker and
# still fails the run. This one goes through the REAL library rather than a hand written record, so
# it is the stamping itself that is under test and not a fixture's imitation of it (L52).
rm -f "$SPOOL2"/*.jsonl "$SP2/suites"/test-othersession.sh
{
  printf '#!/usr/bin/env bash\n'
  printf '. "%s/lib/issue-spool.sh"\n' "$DIR"
  printf 'issue_spool_note "$PWD" "a finding no suite may leave in the live spool" suite-fixture >/dev/null 2>&1\n'
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
} > "$SP2/suites/test-libwriter.sh"
chmod +x "$SP2/suites/test-libwriter.sh"
out_m2="$(sp2_run)"; code_m2=$?
[ "$code_m2" -ne 0 ] \
  && check "#275 a suite writing through the library still fails the run" ok \
  || check "#275 a suite writing through the library still fails the run" "exit=$code_m2 out=$out_m2"
case "$out_m2" in
  *"SUITES WROTE INTO THE LIVE SPOOL"*)
    check "#275 and it is named as the L2 violation it is" ok ;;
  *)
    check "#275 and it is named as the L2 violation it is" "out=$out_m2" ;;
esac
case "$out_m2" in
  *"written under this test run"*)
    check "#275 and the record is attributed to the run that stamped it" ok ;;
  *)
    check "#275 and the record is attributed to the run that stamped it" "out=$out_m2" ;;
esac

# The marker is only evidence while the stamping works, and a stamping that has quietly stopped
# makes every write read as somebody else's, which is the guard going blind while passing (L345).
# So the runner proves the mechanism on a throwaway spool before it trusts an absence, and says so
# and falls back to judging by directory when it cannot. The seam points the proof at a library
# that does not stamp.
rm -f "$SPOOL2"/*.jsonl "$SP2/suites"/test-libwriter.sh
STUBLIB="$SP2/stub-issue-spool.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'issue_spool_note(){ printf %s >> "$CLAUDE_ISSUE_SPOOL_DIR/stub.jsonl"; }\n' \
    "'{\"ts\":\"2026-09-02T12:00:00Z\",\"status\":\"found\",\"cwd\":\"/nowhere\",\"findings\":[\"x\"]}\\n'"
} > "$STUBLIB"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf %s >> "%s/other.jsonl"\n' \
    "'{\"ts\":\"2026-09-02T12:00:00Z\",\"status\":\"error\",\"agent\":\"subagent\",\"cwd\":\"$SP2/a/b\",\"error\":\"no transcript\"}'" "$SPOOL2"
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
} > "$SP2/suites/test-othersession.sh"
chmod +x "$SP2/suites/test-othersession.sh"
out_m3="$(sp2_run HOOK_SPOOL_LIB="$STUBLIB")"; code_m3=$?
case "$out_m3" in
  *"could not be proved"*)
    check "#275 a marker that cannot be proved is announced rather than trusted" ok ;;
  *)
    check "#275 a marker that cannot be proved is announced rather than trusted" "out=$out_m3" ;;
esac
[ "$code_m3" -ne 0 ] \
  && check "#275 and attribution falls back to the directory, which fails closed" ok \
  || check "#275 and attribution falls back to the directory, which fails closed" "exit=$code_m3 out=$out_m3"

# The control: with the real library the proof passes, so the fallback line is NOT printed. Without
# this, a runner that could never prove the marker would satisfy every check above (L159).
out_m4="$(sp2_run)"
case "$out_m4" in
  *"could not be proved"*)
    check "#275 and a run whose marker works says nothing about proving it" "out=$out_m4" ;;
  *)
    check "#275 and a run whose marker works says nothing about proving it" ok ;;
esac

# ---------------------------------------------------------------------------
# The other LIVE STORES are bracketed too, and the list has to cover every seam a suite can
# write through (claude-config#216, claude-config#272).
# ---------------------------------------------------------------------------
# The spool bracket above covers the store the first incident happened in. The same mistake reaches
# the rule files, the settings, the clone registry, the shell rc, and the two markers the watcher
# keeps in the real home. Nothing here had a test at all, so the list was a claim: the guard's own
# contract says a store on it is compared and an absent one is recorded as absent, and neither half
# had ever been seen to fire (L1, L151).
#
# The watcher marker is the one with teeth. A stale ~/.claude-sync-watch.pid makes the live daemon
# refuse to start, so a suite that runs `claude-sync watch` without pointing the seam at its own
# throwaway path stops config reaching the other Mac, silently, from a green run.
LS="$TMPROOT/livestores"
mkdir -p "$LS/claude-home" "$LS/suites" "$LS/spool"
printf 'the live rules\n' > "$LS/claude-home/CLAUDE.md"
printf 'a clone registry\n' > "$LS/registry"
printf 'a shell rc\n' > "$LS/zshrc"
# Every seam the runner reads, pointed at the fixture, so the "live" stores under test are these
# and the real ones are untouched. The runner is asked about the fixture's home, not Dan's.
ls_run(){ # ls_run   -> runs the fixture suites with every live-store seam pointed at $LS
  CLAUDE_HOME="$LS/claude-home" \
  SYNC_CLONE_REGISTRY="$LS/registry" \
  SYNC_ZSHRC="$LS/zshrc" \
  SYNC_WATCH_PID_FILE="$LS/watch.pid" \
  SYNC_HOLD_FILE="$LS/hold" \
  CLAUDE_ISSUE_SPOOL_DIR="$LS/spool" \
  HOOK_TESTS_ROOT="$LS" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 \
  bash "$RUNNER" "$LS/suites" 2>&1
}
# It REWRITES the store rather than appending to it, which is what a suite bound to the real path
# does: an apply installs whole files. An append is a different shape with different writers behind
# it, and it has its own fixture below (claude-config#277).
mk_store_writer(){ # mk_store_writer <name> <path it writes> <what it writes>
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf %s > "%s"\n' "'$3'" "$2"
    printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
  } > "$LS/suites/test-$1.sh"
  chmod +x "$LS/suites/test-$1.sh"
}
mk_store_appender(){ # mk_store_appender <name> <path it adds to> <what it adds>
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf %s >> "%s"\n' "'$3\n'" "$2"
    printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
  } > "$LS/suites/test-$1.sh"
  chmod +x "$LS/suites/test-$1.sh"
}

# The positive control FIRST, because everything below is a claim that this bracket notices a
# write, and a green on a new store would otherwise be satisfied by a fixture that never reached
# the guard (L246, L159).
mk_store_writer rules "$LS/claude-home/CLAUDE.md" 'a line no suite may add'
out_ls1="$(ls_run)"; code_ls1=$?
[ "$code_ls1" -ne 0 ] \
  && check "#216 a suite that changes a live rule file fails the run" ok \
  || check "#216 a suite that changes a live rule file fails the run" "exit=$code_ls1 out=$out_ls1"
case "$out_ls1" in
  *"SUITES CHANGED A LIVE STORE"*"$LS/claude-home/CLAUDE.md"*)
    check "#216 and the store that changed is named" ok ;;
  *)
    check "#216 and the store that changed is named" "out=$out_ls1" ;;
esac

# The watcher marker. A suite CREATES it rather than editing it, which is what running
# `claude-sync watch` against the real home actually does, and is the case a list that skipped
# absent paths could not see at all (L214).
rm -f "$LS/suites"/test-rules.sh
printf 'the live rules\n' > "$LS/claude-home/CLAUDE.md"
# It writes its OWN pid, which is what a suite that started a watcher and stopped it leaves behind,
# and which is certainly dead by the time the run is judged. A number picked out of the air would
# be a fixture whose meaning depends on what else the machine happens to be running (L224).
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$$" > "%s"\n' "$LS/watch.pid"
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
} > "$LS/suites/test-watchpid.sh"
chmod +x "$LS/suites/test-watchpid.sh"
out_ls2="$(ls_run)"; code_ls2=$?
[ "$code_ls2" -ne 0 ] \
  && check "#272 a suite that writes the watcher pid marker fails the run" ok \
  || check "#272 a suite that writes the watcher pid marker fails the run" "exit=$code_ls2 out=$out_ls2"
case "$out_ls2" in
  *"$LS/watch.pid"*)
    check "#272 and the marker it created is named, not just counted" ok ;;
  *)
    check "#272 and the marker it created is named, not just counted" "out=$out_ls2" ;;
esac

# The hold marker, the other store added in the same commit and left off the same list. A stale
# hold silences the automatic send rather than stopping it, so it fails quieter than the pid file.
rm -f "$LS/suites"/test-watchpid.sh "$LS/watch.pid"
mk_store_writer hold "$LS/hold" '99999999 1 a-mac a suite took a hold'
out_ls3="$(ls_run)"; code_ls3=$?
[ "$code_ls3" -ne 0 ] \
  && check "#272 a suite that writes the watcher hold marker fails the run" ok \
  || check "#272 a suite that writes the watcher hold marker fails the run" "exit=$code_ls3 out=$out_ls3"
case "$out_ls3" in
  *"$LS/hold"*)
    check "#272 and the hold marker is named too" ok ;;
  *)
    check "#272 and the hold marker is named too" "out=$out_ls3" ;;
esac

# The watcher marker has a legitimate writer that is NOT a suite, and the comparison has to know
# it. launchd keeps the live daemon alive and it restarts on its own: 562 restarts were recorded in
# the sync log by 2026-09-02, and one of them landed inside the very run that added this store to
# the list, which failed a green run of 49 suites. A guard that cries wolf is one nobody reads
# (L36), and the price of each cry is a full re-run (L293).
#
# So the marker is judged rather than compared. It names a pid: a watcher a SUITE started is a
# descendant of the run, and one the run started and stopped leaves a pid that is dead. Anything
# else alive on this machine is somebody else's. This fixture writes the pid of the process running
# THIS file, which is alive and is an ancestor of the run rather than a descendant, so it stands in
# for the daemon without needing one.
rm -f "$LS/suites"/test-hold.sh "$LS/hold"
mk_store_writer daemonpid "$LS/watch.pid" "$$"
out_ls5="$(ls_run)"; code_ls5=$?
[ "$code_ls5" -eq 0 ] \
  && check "#272 a watcher marker owned by something outside the run does not fail it" ok \
  || check "#272 a watcher marker owned by something outside the run does not fail it" "exit=$code_ls5 out=$out_ls5"
case "$out_ls5" in
  *"not because of these tests"*)
    check "#272 and the change is reported rather than passed over in silence" ok ;;
  *)
    check "#272 and the change is reported rather than passed over in silence" "out=$out_ls5" ;;
esac

# The rule files have a legitimate writer too, and it is the sync itself (claude-config#277). The
# watch daemon pulls whatever the other Mac recorded and applies it into the live config, which is
# the daemon doing its job, and on 2026-09-02 a run of 44 suites was failed by LESSONS.md growing by
# 1,177 bytes while it ran. The guard's own comment stated the assumption it rested on, that nothing
# else legitimately writes these during a run, and it was false for three stores in one day (L375).
#
# Attributed from evidence the sync writes itself: each clone rewrites .last-applied on every apply,
# so its mtime says WHEN. The fixture touches that file from inside the run, which is the only way
# to land it in a window the runner computes from its own start (L130).
rm -f "$LS/suites"/test-hold.sh "$LS/suites"/test-daemonpid.sh "$LS/hold" "$LS/watch.pid"
mkdir -p "$LS/clone"
printf 'a commit\n' > "$LS/clone/.last-applied"
printf '%s\n' "$LS/clone" > "$LS/registry"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "a whole file the sync installed\\n" > "%s"\n' "$LS/claude-home/CLAUDE.md"
  printf 'printf "a newer commit\\n" > "%s"\n' "$LS/clone/.last-applied"
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
} > "$LS/suites/test-syncapply.sh"
chmod +x "$LS/suites/test-syncapply.sh"
out_ls6="$(ls_run)"; code_ls6=$?
[ "$code_ls6" -eq 0 ] \
  && check "#277 a rule file the sync applied during the run does not fail it" ok \
  || check "#277 a rule file the sync applied during the run does not fail it" "exit=$code_ls6 out=$out_ls6"
case "$out_ls6" in
  *"applied config into this Mac while these ran"*)
    check "#277 and the run says the sync did it, naming the clone" ok ;;
  *)
    check "#277 and the run says the sync did it, naming the clone" "out=$out_ls6" ;;
esac

# The control, and the half that must never loosen: the same store changing with no apply behind it
# is still the L2 violation the bracket exists to catch. Same fixture, minus the touch (L159).
rm -f "$LS/suites"/test-syncapply.sh
printf 'the live rules\n' > "$LS/claude-home/CLAUDE.md"
# The apply is pinned into the PAST rather than merely left alone. Both ends of this comparison are
# whole seconds off the same clock, and the run above touched that file a moment ago, so leaving it
# would put the two inside one second of each other and the control would pass for the reason it is
# meant to catch (L130, L134).
touch -t 202001010000 "$LS/clone/.last-applied"
mk_store_writer rulesagain "$LS/claude-home/CLAUDE.md" 'a line no suite may add'
out_ls7="$(ls_run)"; code_ls7=$?
[ "$code_ls7" -ne 0 ] \
  && check "#277 the same change with no apply behind it still fails the run" ok \
  || check "#277 the same change with no apply behind it still fails the run" "exit=$code_ls7 out=$out_ls7"

# Lines ADDED to a rule file, with none removed, is what the other writers of these stores do:
# another Claude session recording a lesson inserts it into the section it belongs in, and that
# failed two green runs on 2026-09-02 with the message saying a suite had written it. A checksum
# cannot tell the two apart, so the SHAPE is read from a copy taken before the run.
rm -f "$LS/suites"/test-rulesagain.sh
printf 'the live rules\nand a second line\n' > "$LS/claude-home/CLAUDE.md"
touch -t 202001010000 "$LS/clone/.last-applied"
mk_store_appender lessonlike "$LS/claude-home/CLAUDE.md" 'a lesson another session recorded'
out_ls8="$(ls_run)"; code_ls8=$?
[ "$code_ls8" -eq 0 ] \
  && check "#277 a rule file that only gained lines does not fail the run" ok \
  || check "#277 a rule file that only gained lines does not fail the run" "exit=$code_ls8 out=$out_ls8"
case "$out_ls8" in
  *"none were removed or changed"*)
    check "#277 and it says what shape of change it saw" ok ;;
  *)
    check "#277 and it says what shape of change it saw" "out=$out_ls8" ;;
esac

# The control that keeps the teeth: a line REMOVED from the same file, with no apply behind it, is
# the destructive shape and still fails the run. Same fixture, one line taken out instead of added.
rm -f "$LS/suites"/test-lessonlike.sh
printf 'the live rules\nand a second line\n' > "$LS/claude-home/CLAUDE.md"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "the live rules\\n" > "%s"\n' "$LS/claude-home/CLAUDE.md"
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
} > "$LS/suites/test-linetaker.sh"
chmod +x "$LS/suites/test-linetaker.sh"
out_ls9="$(ls_run)"; code_ls9=$?
[ "$code_ls9" -ne 0 ] \
  && check "#277 a rule file that LOST a line still fails the run" ok \
  || check "#277 a rule file that LOST a line still fails the run" "exit=$code_ls9 out=$out_ls9"

# And the control: a run that touched none of them says nothing about any of them. Without this a
# guard that failed every run would pass every check above (L159).
rm -f "$LS/suites"/test-linetaker.sh "$LS/hold" "$LS/watch.pid"
printf 'the live rules\n' > "$LS/claude-home/CLAUDE.md"
mk_counting_suite "$LS/suites" storequiet 3
out_ls4="$(ls_run)"; code_ls4=$?
case "$out_ls4" in
  *"CHANGED A LIVE STORE"*)
    check "#216 a run that touched no live store says nothing about them" "out=$out_ls4" ;;
  *)
    [ "$code_ls4" -eq 0 ] \
      && check "#216 a run that touched no live store says nothing about them" ok \
      || check "#216 a run that touched no live store says nothing about them" "exit=$code_ls4 out=$out_ls4" ;;
esac

# ---------------------------------------------------------------------------
# A failing suite's WHOLE diagnosis reaches the reader (claude-config#253).
#
# The runner printed the failing suite name and then the FAIL lines, but only the FIRST line of
# each. Every FAIL message in test-pipefail-shortcircuit.sh is multi line: the first line states the
# rule that was broken, and the lines under it name the files, the counts and the remedy. On the red
# run of b94b29a both messages ended mid sentence, on an open parenthesis, and diagnosing it meant
# checking out the failing commit in a worktree and running the suite by hand to read a message the
# runner had already been handed. That is L148: the reason exists, and the only surface carrying it
# dies with the run.
FD="$TMPROOT/faildetail"
mkdir -p "$FD"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "FAIL: the baseline has been lowered as sites were converted (these are stale:"\n'
  printf 'echo "  payload/hooks/block-red-merge.sh: 1 recorded, 0 now"\n'
  printf 'echo "  Lower the recorded number, so what is left keeps meaning something."\n'
  printf 'echo "SUITE-RESULT passed=0 failed=1"\n'
  printf 'exit 1\n'
} > "$FD/test-detail.sh"
chmod +x "$FD/test-detail.sh"
out_fd="$(HOOK_TESTS_TIMINGS= HOOK_TESTS_FLAKE_RECHECK=0 bash "$RUNNER" "$FD" 2>&1)"
case "$out_fd" in
  *"1 recorded, 0 now"*)
    check "#253 a multi line FAIL carries the line naming the file and the count" ok ;;
  *)
    check "#253 a multi line FAIL carries the line naming the file and the count" "out=$out_fd" ;;
esac
case "$out_fd" in
  *"Lower the recorded number"*)
    check "#253 and it carries the remedy under it" ok ;;
  *)
    check "#253 and it carries the remedy under it" "out=$out_fd" ;;
esac
# The control: an UNINDENTED line after the FAIL belongs to the suite's ordinary chatter, not to
# the message, and carrying it would turn every failing suite's whole output into the detail block.
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "FAIL: the rule that was broken"\n'
  printf 'echo "  the indented reason"\n'
  printf 'echo "an unrelated line at the margin"\n'
  printf 'echo "SUITE-RESULT passed=0 failed=1"\n'
  printf 'exit 1\n'
} > "$FD/test-detail.sh"
out_fd2="$(HOOK_TESTS_TIMINGS= HOOK_TESTS_FLAKE_RECHECK=0 bash "$RUNNER" "$FD" 2>&1)"
case "$out_fd2" in
  *"the indented reason"*) check "#253 the indented continuation is carried" ok ;;
  *) check "#253 the indented continuation is carried" "out=$out_fd2" ;;
esac
case "$out_fd2" in
  *"an unrelated line at the margin"*)
    check "#253 and a line back at the margin is not swept in" "out=$out_fd2" ;;
  *)
    check "#253 and a line back at the margin is not swept in" ok ;;
esac

# ---------------------------------------------------------------------------
# A suite that passes only on a second run is COUNTED as a flake (claude-config#245).
#
# Three suites failed three separate full runs on 2026-08-31 on three different assertions, and
# passed cleanly every time they were run on their own. A suite that fails at random teaches
# everyone to re-run rather than read, so a real regression there arrives looking exactly like the
# noise. L293 is the rule: a flake is a speed cost priced at a full re-run, and a RETRY HIDES THE
# PRICE, so count flakes on every run and put the count where a reviewer looks.
#
# So the re-run does not rescue the suite. It stays failed, and the run stays red; what the re-run
# buys is the word FLAKY next to it, which is the thing a reviewer needs and could not otherwise
# get without reproducing it by hand.
FL="$TMPROOT/flaky"
mkdir -p "$FL"
MARKER="$TMPROOT/flaky-marker"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ -e "%s" ]; then echo "SUITE-RESULT passed=1 failed=0"; exit 0; fi\n' "$MARKER"
  printf 'touch "%s"\n' "$MARKER"
  printf 'echo "FAIL: it failed the first time only"\n'
  printf 'echo "SUITE-RESULT passed=0 failed=1"\n'
  printf 'exit 1\n'
} > "$FL/test-flaky.sh"
chmod +x "$FL/test-flaky.sh"
rm -f "$MARKER"
out_fl="$(HOOK_TESTS_TIMINGS= HOOK_TESTS_FLAKE_RECHECK=1 bash "$RUNNER" "$FL" 2>&1)"; code_fl=$?
case "$out_fl" in
  *FLAKY*) check "#245 a suite that passes on a second run is named FLAKY" ok ;;
  *) check "#245 a suite that passes on a second run is named FLAKY" "out=$out_fl" ;;
esac
[ "$code_fl" -ne 0 ]   && check "#245 and the run is still red, because a retry must not hide the price" ok   || check "#245 and the run is still red, because a retry must not hide the price" "exit=$code_fl"
case "$out_fl" in
  *"test-flaky.sh"*) check "#245 and the flake is named, not just counted" ok ;;
  *) check "#245 and the flake is named, not just counted" "out=$out_fl" ;;
esac

# A recheck that HANGS is a third outcome, and it has its own words (L11). A suite that fails and
# then hangs on the second run is not a flake and is not a clean failure, and without a deadline it
# would hold the whole run open on a suite that had already misbehaved once (L110).
#
# Driven through the injected poll rather than by waiting the real deadline out, so this costs a
# fraction of a second instead of a minute (L524).
HG="$TMPROOT/hangs"
mkdir -p "$HG"
HG_MARKER="$TMPROOT/hang-marker"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ -e "%s" ]; then while :; do sleep 3600 & wait "$!" || true; done; fi\n' "$HG_MARKER"
  printf 'touch "%s"\n' "$HG_MARKER"
  printf 'echo "FAIL: it failed, and it will hang if run again"\n'
  printf 'echo "SUITE-RESULT passed=0 failed=1"\n'
  printf 'exit 1\n'
} > "$HG/test-hangs.sh"
chmod +x "$HG/test-hangs.sh"
rm -f "$HG_MARKER"
out_hg="$(HOOK_TESTS_TIMINGS= HOOK_TESTS_FLAKE_RECHECK=1 HOOK_TESTS_FLAKE_RECHECK_MAX=2 \
  HOOK_TESTS_FLAKE_RECHECK_POLL=0.05 bash "$RUNNER" "$HG" 2>&1)"; code_hg=$?
case "$out_hg" in
  *"recheck timed out"*) check "#245 a recheck that hangs is named as timed out" ok ;;
  *) check "#245 a recheck that hangs is named as timed out" "out=$out_hg" ;;
esac
case "$out_hg" in
  *FLAKY*) check "#245 and a hung recheck is not counted as a flake" "out=$out_hg" ;;
  *) check "#245 and a hung recheck is not counted as a flake" ok ;;
esac
[ "$code_hg" -ne 0 ] \
  && check "#245 and the run is still red after a hung recheck" ok \
  || check "#245 and the run is still red after a hung recheck" "exit=$code_hg"
rm -f "$HG_MARKER"

# The control: a suite that fails BOTH times is a failure, not a flake. Without this the word
# FLAKY would attach to every red suite and stop meaning anything (L159).
mk_suite "$FL" solid 1
rm -f "$MARKER" "$FL/test-flaky.sh"
out_fl2="$(HOOK_TESTS_TIMINGS= HOOK_TESTS_FLAKE_RECHECK=1 bash "$RUNNER" "$FL" 2>&1)"; code_fl2=$?
case "$out_fl2" in
  *FLAKY*) check "#245 a suite that fails twice is not called a flake" "out=$out_fl2" ;;
  *) [ "$code_fl2" -ne 0 ]        && check "#245 a suite that fails twice is not called a flake" ok        || check "#245 a suite that fails twice is not called a flake" "exit=$code_fl2" ;;
esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
