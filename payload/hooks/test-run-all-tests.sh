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
  printf '%s' "$out_par" | grep -q "test-$n.sh" \
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
printf '%s' "$out_pf" | grep -q 'test-quick.sh' \
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
case "$(cat "$TSTORE/$t_slow_rec" 2>/dev/null)" in
  ''|*[!0-9]*) check "#144 and what it records is a whole number of seconds" "the record for test-slowpoke.sh reads '$(cat "$TSTORE/$t_slow_rec" 2>/dev/null)'" ;;
  *) check "#144 and what it records is a whole number of seconds" ok ;;
esac

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
# And the other half of the same fact. Without it, a runner that handed EVERY suite the largest
# share would satisfy the check above (L178).
[ "$(slots_seen "$TR/suites" bigfile)" != 4 ] \
  && check "#144 and the largest file no longer takes the largest share" ok \
  || check "#144 and the largest file no longer takes the largest share" "bigfile=$(slots_seen "$TR/suites" bigfile) out=$out_t2"
# Said out loud. Which of the two orders a run used decides where the minutes went, and a run that
# silently fell back to size reads exactly like one that ordered by measurement (L11).
case "$out_t2" in
  *"measured wall clock for 4 of 4"*) check "#144 the run says how many suites it had a measurement for" ok ;;
  *) check "#144 the run says how many suites it had a measurement for" "out=$out_t2" ;;
esac

# A record nobody can read is not a measurement, so it falls back to size rather than being
# guessed at as a number. It must not fail the run either: the store is a cache, and a corrupt
# cache entry is not a broken test suite.
printf 'not-a-number\n' > "$TSTORE/$t_slow_rec"
rm -f "$TR/suites"/*.slots
out_t3="$(HOOK_TESTS_ROOT="$TR" HOOK_TESTS_TIMINGS="$TSTORE" HOOK_TESTS_BUDGET=8 HOOK_TESTS_JOBS=4 bash "$RUNNER" "$TR/suites" 2>&1)"; code_t3=$?
[ "$code_t3" -eq 0 ] && [ "$(slots_seen "$TR/suites" bigfile)" = 4 ] \
  && check "#144 a record that is not a number falls back to size, and does not fail the run" ok \
  || check "#144 a record that is not a number falls back to size, and does not fail the run" "exit=$code_t3 bigfile=$(slots_seen "$TR/suites" bigfile) out=$out_t3"

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
printf '%s' "$vanish_line" | grep -qi 'not measured' \
  && check "#150 and its line says outright that nothing measured it" ok \
  || check "#150 and its line says outright that nothing measured it" "its line reads: $vanish_line"
# The control for that pair: the suite beside it in the same run WAS measured, so "not measured" is
# a fact about the one that vanished and not about a runner that measures nothing (L159).
d_survivor="$(dur_of "$out_dk" survivor)"
case "$d_survivor" in
  ''|*[!0-9]*) check "#150 the suite beside it in the same run was measured" "test-survivor.sh line: $(printf '%s\n' "$out_dk" | grep -E 'test-survivor\.sh')" ;;
  *) check "#150 the suite beside it in the same run was measured" ok ;;
esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
