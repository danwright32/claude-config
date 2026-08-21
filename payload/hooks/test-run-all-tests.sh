#!/usr/bin/env bash
# Tests for run-all-tests.sh, the thing that decides whether "all the tests passed" is true
# (claude-config#120).
#
# It discovered suites from disk rather than from a list, which was the right idea, but it looked
# in ONE directory: the one it lives in. Three suites live outside it and were run only because
# four hand-written steps in the CI workflow named them, and a fourth, payload/skills/milestone,
# was named by nothing at all and had never run anywhere. 233 checks, discovered by asking the repo
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
printf '%s' "$out_bad" | grep -q 'test-gamma.sh' \
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
  printf '%s' "$out_tally" | grep -qF "$want" \
    && check "the score column shows the tally '$want'" ok \
    || check "the score column shows the tally '$want'" "out=$out_tally"
done
printf '%s' "$out_tally" | grep -q 'wording mentions' \
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
printf '%s' "$out_r" | grep -q '12 passed, 0 failed' \
  && check "and its score is shown in one uniform shape" ok \
  || check "and its score is shown in one uniform shape" "out=$out_r"
# The fixture deliberately also prints `PASS=999 FAIL=42` and two chatty lines. The result line
# has to win, or the runner is still recognising a score rather than reading one.
printf '%s' "$out_r" | grep -q '999' \
  && check "and a misleading prose tally on the same run is ignored" "it read 999" \
  || check "and a misleading prose tally on the same run is ignored" ok
printf '%s' "$out_r" | grep -qi 'NO RESULT LINE' \
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
printf '%s' "$out_r3" | grep -qi 'NO RESULT LINE' \
  && check "and the runner says out loud that it guessed" ok \
  || check "and the runner says out loud that it guessed" "out=$out_r3"
printf '%s' "$out_r3" | grep -q 'test-oldstyle.sh' \
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
    printf 'sleep %s\n' "$3"
    printf 'printf %s\\\\n "%s passed=1 failed=%s"\n' "'%s'" "$MARK" "$4"
    printf 'exit %s\n' "$5"
  } > "$1/test-$2.sh"
  chmod +x "$1/test-$2.sh"
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
  printf '%s' "$out_par" | grep -q "test-$n.sh" \
    && check "and test-$n.sh was run and reported" ok \
    || check "and test-$n.sh was run and reported" "out=$out_par"
done
# The order on the page is the order they were FOUND, not the order they finished. Without this a
# report cannot be compared against the last one, and a suite that moved is indistinguishable from
# a suite that got slower.
order="$(printf '%s\n' "$out_par" | grep -oE 'test-(aaa|bbb|ccc)\.sh' | tr '\n' ' ')"
[ "$order" = "test-aaa.sh test-bbb.sh test-ccc.sh " ] \
  && check "and they are reported in a stable order, not in the order they finished" ok \
  || check "and they are reported in a stable order, not in the order they finished" "order was: $order"
# The control for the fixture: the sleeps really do make them finish in the opposite order, so the
# check above is not satisfied by three suites that all finished instantly (L159).
[ "$par_elapsed" -ge 3 ] \
  && check "the fixture really did stagger their finishing times" ok \
  || check "the fixture really did stagger their finishing times" "the whole run took ${par_elapsed}s, so nothing was staggered"
# And they really did overlap: run one at a time these take at least 4 seconds together.
[ "$par_elapsed" -lt 4 ] \
  && check "and they ran at the same time rather than one after another" ok \
  || check "and they ran at the same time rather than one after another" "${par_elapsed}s, which is no better than sequential"

# A failure among them still fails the run and is still named, even though it finishes first.
PF="$TMPROOT/dir-parallel-fail"
mk_slow_suite "$PF" slow 2 0 0
mk_slow_suite "$PF" quick 0 2 1
out_pf="$(HOOK_TESTS_JOBS=4 bash "$RUNNER" "$PF" 2>&1)"; code_pf=$?
[ "$code_pf" -ne 0 ] \
  && check "a suite that fails while another is still running fails the run" ok \
  || check "a suite that fails while another is still running fails the run" "exit=$code_pf out=$out_pf"
printf '%s' "$out_pf" | grep -q 'test-quick.sh' \
  && check "and is named" ok || check "and is named" "out=$out_pf"

# One at a time is the escape hatch, and it has to keep working: it is what somebody reaches for
# when a suite only fails alongside others.
out_seq="$(HOOK_TESTS_JOBS=1 bash "$RUNNER" "$P" 2>&1)"; code_seq=$?
[ "$code_seq" -eq 0 ] \
  && check "one at a time still works" ok || check "one at a time still works" "exit=$code_seq out=$out_seq"
seq_order="$(printf '%s\n' "$out_seq" | grep -oE 'test-(aaa|bbb|ccc)\.sh' | tr '\n' ' ')"
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
printf '%s' "$out_empty" | grep -q "$EMPTY" \
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
printf '%s' "$out_disc" | grep -q 'test-faraway.sh' \
  && check "a suite three directories away from the runner is run" ok \
  || check "a suite three directories away from the runner is run" "out=$out_disc"
printf '%s' "$out_disc" | grep -q 'test-middle.sh' && printf '%s' "$out_disc" | grep -q 'test-near.sh' \
  && check "and so is every other one in the repo" ok \
  || check "and so is every other one in the repo" "out=$out_disc"
printf '%s' "$out_disc" | grep -q 'helper.sh' \
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
    printf '%s\n' "$out_list" | grep -qx "$REAL/$d" \
      && check "the real repo's $d is one of the directories it would read" ok \
      || check "the real repo's $d is one of the directories it would read" "out=$out_list"
  done
  # And it must be listing, not refusing. A refusal prints nothing on stdout, which every check
  # above would report as a missing directory rather than as the runner declining to answer.
  [ "$(printf '%s\n' "$out_list" | grep -c .)" -ge 4 ] \
    && check "the listing answered rather than refusing" ok \
    || check "the listing answered rather than refusing" "it printed $(printf '%s\n' "$out_list" | grep -c .) line(s)"
else
  check "the real repo could be found" "git rev-parse found no toplevel above $DIR"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
