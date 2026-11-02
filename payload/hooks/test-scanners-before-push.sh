#!/usr/bin/env bash
# Tests for scanners-before-push.sh, which runs this repo's whole tree scanners before a push
# rather than leaving CI as the first place they speak (claude-config#518).
#
# The gap it closes was measured on 2026-09-20: two defects went to main in one evening and the
# build went red twice, an undated measured number in a new comment and six pipelines ending in a
# consumer that leaves early. Neither is visible to a gate that reads the DIFF, because both were
# caught by guards that read every tracked file in the repository. The pre push test gate asks a
# model whether each change carries a test and runs no suite at all.
#
# The checks below care about the two ways a gate like this is worse than useless. It must not
# report a clean run when it found nothing to run (L98), and it must not block a push over
# anything other than a scanner that actually ran and actually failed, because a gate that fails
# closed on a machine that cannot ask the question stops work for no reason (L42 cuts the other
# way here: this protects a build, not a person).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$DIR/scanners-before-push.sh"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-scanner-gate.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-scanners-before-push: refusing to run: throwaway directory came back as '${TMPROOT}'." >&2
    exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# Every run of the gate in this suite keeps its record of passed scans in the throwaway, never in
# the real ~/.claude/state/scanners-passed, where a test's pass would be trusted by a later real
# push (claude-config#789, L2). Exported once, here, so no case can forget it; the guard at the end
# checks no fixture's record reached the real folder anyway.
export SCANNERS_STATE_DIR="$TMPROOT/scanners-state"

# A repository shaped like this one: the marker the hook keys on, plus whatever scanners the test
# wants. Everything happens in a throwaway git repo, never against the real one (L2).
mkrepo(){            # $1 = name  -> prints the repo path
  local r="$TMPROOT/$1"
  mkdir -p "$r/payload/hooks" "$r/tests"
  git -C "$r" init -q
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  printf '#!/usr/bin/env bash\necho runner\n' > "$r/payload/hooks/run-all-tests.sh"
  chmod +x "$r/payload/hooks/run-all-tests.sh"
  printf '%s' "$r"
}

# A scanner suite: one that reads the repository's own tracked files, which is the property that
# makes it invisible to a gate reading the diff.
add_scanner(){       # $1 = repo  $2 = name  $3 = exit code
  cat > "$1/payload/hooks/test-$2.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
echo "scanner $2 ran"
exit $3
EOF
  chmod +x "$1/payload/hooks/test-$2.sh"
}

# A suite that reads only what it was given, so it is NOT a scanner and must not be run here.
add_plain(){         # $1 = repo  $2 = name
  printf '#!/usr/bin/env bash\necho "plain %s ran"\nexit 0\n' "$2" > "$1/payload/hooks/test-$2.sh"
  chmod +x "$1/payload/hooks/test-$2.sh"
}

commit_all(){ git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -q -m "fixture" >/dev/null 2>&1; }

# The hook reads a Claude Code PreToolUse payload on stdin.
#
# The exit code comes back as this function's OWN status, never through a variable: every call
# below is inside a command substitution, which is a subshell, so a variable set in here never
# reaches the caller and every exit code read that way was the previous one (measured: three
# checks passed against a stale 0).
#
# EVERY CALL HAS A DEADLINE OF ITS OWN (claude-config#1889). The gate starts and stops processes
# of its own, and on 2026-10-29 one of them outlived its kill on Linux CI, so a gate call waited out
# the gate's whole 150 second budget instead of about one second. Nothing failed: each call was
# merely slow, the suite ran into its 1200 second wall clock, and the flake recheck then ate the
# rest of the 40 minute CI job, so the only thing anybody saw was a cancelled job naming no test
# (L240, L313). So the gate runs in a process group of its own (lib/bounded-run.sh) and is killed,
# with everything it started, at FIRE_DEADLINE seconds. That call then exits 124, which every
# check on its exit code names, and it is written to FIRE_DEADLINE_LOG, which a check at the end
# names by fixture and command, so a hang fails by name rather than eating the job.
#
# 60 seconds, a setting rather than a measurement: well clear of a call that takes about a second
# on a quiet machine, and well inside the gate's own budget of 150, so a call that waits out that
# budget is caught here first.
. "$DIR/lib/bounded-run.sh" || {
  echo "FAIL: $(basename "$0"): lib/bounded-run.sh is missing, so the gate calls cannot be bounded. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
FIRE_DEADLINE="${SCANNERS_TEST_FIRE_DEADLINE:-60}"
# shellcheck source=lib/whole-number.sh
. "$DIR/lib/whole-number.sh"
if ! whole_above_zero "$FIRE_DEADLINE" FIRE_DEADLINE; then
  echo "test-scanners-before-push: SCANNERS_TEST_FIRE_DEADLINE='$FIRE_DEADLINE' is not a whole number of seconds above zero. Refusing to run the gate calls unbounded." >&2
  exit 2
fi
FIRE_DEADLINE_LOG="$TMPROOT/fire-deadlines"
fire(){              # $1 = repo  $2 = the command  -> prints the hook's output, exits with its code
  local payload
  payload="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$2" "$1")"
  bounded_run "$FIRE_DEADLINE" bash "$H" <<< "$payload"
  printf '%s' "$BOUNDED_OUT"
  if [ "$BOUNDED_RC" -eq 124 ]; then
    printf '%s: %s\n' "$(basename "$1")" "$2" >> "$FIRE_DEADLINE_LOG"
    printf '\nFIRE-DEADLINE: the gate did not return within %s seconds, so it and everything it started were killed\n' "$FIRE_DEADLINE"
  fi
  return "$BOUNDED_RC"
}

# --- a repository with a passing scanner: the push goes through, and the gate says what it ran,
#     because a gate nobody can see the coverage of is one nobody can trust (L400, L557).
R1="$(mkrepo pass)"; add_scanner "$R1" alpha 0; add_plain "$R1" beta; commit_all "$R1"
o1="$(fire "$R1" "git push")"; c1=$?
[ "$c1" -eq 0 ] && check "a passing scanner lets the push through" ok \
                || check "a passing scanner lets the push through" "exit=$c1 out=$o1"

# --- a failing scanner blocks it, and says which one.
R2="$(mkrepo block)"; add_scanner "$R2" alpha 0; add_scanner "$R2" gamma 1; commit_all "$R2"
o2="$(fire "$R2" "git push")"; c2=$?
[ "$c2" -eq 2 ] && check "a failing scanner blocks the push" ok \
                || check "a failing scanner blocks the push" "exit=$c2 out=$o2"
grep -q 'gamma' <<< "$o2" \
  && check "and names the scanner that failed" ok || check "and names the scanner that failed" "out=$o2"
grep -q 'alpha' <<< "$o2" \
  && check "and does not accuse the one that passed" "it named alpha too: $o2" \
  || check "and does not accuse the one that passed" ok

# --- a suite that reads only its own fixtures is not a scanner and must not be run, or this gate
#     becomes the whole suite and costs what the whole suite costs.
grep -q 'plain beta ran' <<< "$o1" \
  && check "a suite that scans nothing is left alone" "it ran beta: $o1" \
  || check "a suite that scans nothing is left alone" ok

# --- a repository with the marker and NO scanners has measured nothing. It must say so rather
#     than pass silently, because reading nothing and reading everything green look identical
#     otherwise (L98).
R3="$(mkrepo empty)"; add_plain "$R3" beta; commit_all "$R3"
o3="$(fire "$R3" "git push")"; c3=$?
[ "$c3" -eq 0 ] && check "no scanners does not block the push" ok \
                || check "no scanners does not block the push" "exit=$c3 out=$o3"
grep -qiE 'no scanner|found none|nothing to scan' <<< "$o3" \
  && check "but it says it found none rather than reporting a clean run" ok \
  || check "but it says it found none rather than reporting a clean run" "out=$o3"
# ...and says it where the person sees it: Claude Code discards a PreToolUse hook's stderr on exit 0,
# so the notice is the systemMessage on stdout (claude-config#1906). stdout alone is read here.
. "$DIR/lib/hook-notice.sh"
fire_stdout(){       # $1 = repo  $2 = the command  [$3 = env assignment]  -> sets FS_OUT and FS_RC
  local payload
  payload="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$2" "$1")"
  bounded_run "$FIRE_DEADLINE" env ${3:+"$3"} bash -c 'bash "$0" 2>/dev/null' "$H" <<< "$payload"
  FS_OUT="$BOUNDED_OUT"; FS_RC="$BOUNDED_RC"
}
fire_stdout "$R3" "git push"
why="$(hook_notice_verdict "$FS_OUT" 'found no scanner')"
[ "$FS_RC" -eq 0 ] && [ -z "$why" ] && check "#1906 and says so as a systemMessage" ok \
  || check "#1906 and says so as a systemMessage" "exit=$FS_RC $why"
# A passing push says what it covered (L400), which only reaches the person as a systemMessage. $R1
# already passed above and the gate remembers it, so this push is the one that says every scan had
# already passed on this tree: the coverage line of a remembered pass.
fire_stdout "$R1" "git push"
why="$(hook_notice_verdict "$FS_OUT" 'nothing was scanned for this push. All [0-9]+ whole tree scan\(s\) had already passed')"
[ "$FS_RC" -eq 0 ] && [ -z "$why" ] && check "#1906 a push whose scans already passed says so, as a systemMessage" ok \
  || check "#1906 a push whose scans already passed says so, as a systemMessage" "exit=$FS_RC $why"
# A push started underneath the gate is not gated again, and says so the same way.
fire_stdout "$R3" "git push" SCANNERS_GATE_RUNNING=1
why="$(hook_notice_verdict "$FS_OUT" 'not gated again')"
[ "$FS_RC" -eq 0 ] && [ -z "$why" ] && check "#1906 a nested push says it was not gated, as a systemMessage" ok \
  || check "#1906 a nested push says it was not gated, as a systemMessage" "exit=$FS_RC $why"

# --- a repository that is not this one is left entirely alone, with nothing to say about it.
R4="$TMPROOT/notours"; mkdir -p "$R4"; git -C "$R4" init -q
git -C "$R4" config user.email t@t; git -C "$R4" config user.name t
printf 'x\n' > "$R4/file"; commit_all "$R4"
o4="$(fire "$R4" "git push")"; c4=$?
[ "$c4" -eq 0 ] && [ -z "$o4" ] \
  && check "a repository without the marker is not touched" ok \
  || check "a repository without the marker is not touched" "exit=$c4 out=$o4"

# --- anything that is not a push is none of this hook's business.
o5="$(fire "$R2" "git status")"; c5=$?
[ "$c5" -eq 0 ] && [ -z "$o5" ] \
  && check "a command that is not a push is ignored" ok \
  || check "a command that is not a push is ignored" "exit=$c5 out=$o5"

# --- a scanner that never RAN because another suite run held its lock is not a failing scanner
#     (claude-config#642). Twice on 2026-10-04 the gate blocked with "a scanner that reads the
#     WHOLE repository fails" and an empty detail, when tests/test-claude-sync.sh had refused to
#     start; alone a minute later it passed 71/0. The gate now waits for the lock, holding its
#     place, to a named deadline (L1012), and if the lock is still held it says THAT (L11).
#     The fixture prints the suite's own refusal line and exits 5, as the suite does. The sleep is
#     injected, so no test waits for real (L524).
add_locked_scanner(){   # $1 = repo  $2 = name  $3 = refusals before it runs  $4 = exit code once it runs
  cat > "$1/payload/hooks/test-$2.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
n="\$(cat "$TMPROOT/$2.tries" 2>/dev/null || echo 0)"; n=\$((n + 1)); echo "\$n" > "$TMPROOT/$2.tries"
if [ "\$n" -le $3 ]; then
  echo "test suite: another run is already going: a suite run, process 4242 on here, started 30s ago. Refusing rather than queueing behind it." >&2
  exit 5
fi
echo "scanner $2 ran"
[ $4 -eq 0 ] || echo "FAIL: scanner $2 found something"
exit $4
EOF
  chmod +x "$1/payload/hooks/test-$2.sh"
}
LOCKSTATE="$TMPROOT/lockstate"
lockfire(){ SCANNERS_STATE_DIR="$LOCKSTATE" SCANNERS_SLEEP=true SCANNERS_LOCK_WAIT_SECONDS=6 SCANNERS_LOCK_POLL_SECONDS=2 fire "$@"; }

R30="$(mkrepo lockheld)"; add_scanner "$R30" alpha 0; add_locked_scanner "$R30" sigma 99 0; commit_all "$R30"
o30="$(lockfire "$R30" "git push")"; c30=$?
[ "$c30" -eq 2 ] && check "a scanner whose lock is held to the deadline still blocks the push" ok \
  || check "a scanner whose lock is held to the deadline still blocks the push" "exit=$c30 out=$o30"
grep -q 'another test run' <<< "$o30" \
  && check "and says another test run held the lock" ok || check "and says another test run held the lock" "out=$o30"
grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o30" \
  && check "and never reports it as a failing scanner" "out=$o30" || check "and never reports it as a failing scanner" ok
grep -q 'sigma' <<< "$o30" \
  && check "and names the scanner that could not run" ok || check "and names the scanner that could not run" "out=$o30"
grep -q '6s' <<< "$o30" \
  && check "and names how long it waited" ok || check "and names how long it waited" "out=$o30"
[ "$(cat "$TMPROOT/sigma.tries" 2>/dev/null)" = "4" ] \
  && check "and it tried once, then once per poll until the deadline" ok \
  || check "and it tried once, then once per poll until the deadline" "tries=$(cat "$TMPROOT/sigma.tries" 2>/dev/null)"

R31="$(mkrepo lockfreed)"; add_scanner "$R31" alpha 0; add_locked_scanner "$R31" tau 1 0; commit_all "$R31"
o31="$(lockfire "$R31" "git push")"; c31=$?
[ "$c31" -eq 0 ] && check "a scanner whose lock frees inside the deadline runs and the push goes through" ok \
  || check "a scanner whose lock frees inside the deadline runs and the push goes through" "exit=$c31 out=$o31"

R32="$(mkrepo lockthenfail)"; add_locked_scanner "$R32" upsilon 1 1; commit_all "$R32"
o32="$(lockfire "$R32" "git push")"; c32=$?
[ "$c32" -eq 2 ] && grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o32" && grep -q 'upsilon found something' <<< "$o32" \
  && check "a scanner that waits for the lock and then FAILS is reported as failing, with its detail" ok \
  || check "a scanner that waits for the lock and then FAILS is reported as failing, with its detail" "exit=$c32 out=$o32"

# A run that only REFUSED on the lock scanned nothing, so its seconds are not the scanner's time
# (claude-config#2033). They were written over the scanner's last duration all the same, so on
# 2026-11-01 a refusal for time quoted "its last run took 2s" for a scan that takes 12 to 18. sigma
# above refused on every try, so nothing may be recorded for it, while alpha, which scanned, is.
_slot_of(){ printf 'payload/hooks/test-%s.sh\n\n' "$1" | shasum -a 256 | awk '{ print substr($1, 1, 20) }'; }
_sigma_last="$(ls "$LOCKSTATE"/runs/*/"$(_slot_of sigma)-last" 2>/dev/null)"
_alpha_last="$(ls "$LOCKSTATE"/runs/*/"$(_slot_of alpha)-last" 2>/dev/null)"
[ -z "$_sigma_last" ] \
  && check "#2033 a run that only refused on the lock records no duration for its scanner" ok \
  || check "#2033 a run that only refused on the lock records no duration for its scanner" "recorded $(cat "$_sigma_last" 2>/dev/null)s in $_sigma_last"
[ -n "$_alpha_last" ] \
  && check "#2033 and a run that scanned still records one" ok \
  || check "#2033 and a run that scanned still records one" "nothing under $LOCKSTATE/runs"

# THE BUDGET RUNNING OUT WHILE A SCANNER WAITS ITS TURN ON THE LOCK is a lock refusal, said as one
# (claude-config#2033, L11). On 2026-11-01 seven pushes were refused as "did not finish in 150
# seconds" over a run started again for the lock 1 or 2 seconds earlier, which read as a scanner too
# slow for the budget and sent the fix after the budget. Here a refusal takes 3 seconds on every try
# after the first, so the budget of 2 runs out while a retry is in flight, as it did under load.
add_slow_locked_scanner(){   # $1 = repo  $2 = name: refuses at once, then after 3 seconds, for ever
  cat > "$1/payload/hooks/test-$2.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
n="\$(cat "$TMPROOT/$2.tries" 2>/dev/null || echo 0)"; n=\$((n + 1)); echo "\$n" > "$TMPROOT/$2.tries"
[ "\$n" -le 1 ] || sleep 3
echo "test suite: another run is already going: a suite run, process 4242 on here, started 30s ago. Refusing rather than queueing behind it." >&2
exit 5
EOF
  chmod +x "$1/payload/hooks/test-$2.sh"
}
R2033="$(mkrepo lockbudget)"; add_scanner "$R2033" alpha 0; add_slow_locked_scanner "$R2033" phi; commit_all "$R2033"
o2033="$(SCANNERS_STATE_DIR="$TMPROOT/lockbudget-state" SCANNERS_SLEEP=true SCANNERS_LOCK_WAIT_SECONDS=60 SCANNERS_LOCK_POLL_SECONDS=2 SCANNERS_BUDGET_SECONDS=2 fire "$R2033" "git push")"; c2033=$?
[ "$c2033" -eq 2 ] \
  && check "#2033 a scanner still waiting its turn on the lock when the budget runs out blocks the push" ok \
  || check "#2033 a scanner still waiting its turn on the lock when the budget runs out blocks the push" "exit=$c2033 out=$o2033"
grep -q 'another test run' <<< "$o2033" && grep -q 'phi' <<< "$o2033" \
  && check "#2033 and says another test run held the lock, naming the scanner" ok \
  || check "#2033 and says another test run held the lock, naming the scanner" "out=$o2033"
grep -q 'did not finish in' <<< "$o2033" \
  && check "#2033 and never calls it a scanner that did not finish in the budget" "out=$o2033" \
  || check "#2033 and never calls it a scanner that did not finish in the budget" ok
grep -q 'process 4242' <<< "$o2033" \
  && check "#2033 and names the run holding the lock, from the refusal before the retry" ok \
  || check "#2033 and names the run holding the lock, from the refusal before the retry" "out=$o2033"

# --- a scanner that RAN but could not read what it judges measured nothing, which is a fault in
#     this gate's run and not a finding about the push (claude-config#1146). On 2026-10-13 the
#     secret scan, run here, could not copy the tree it scans (a file listed and gone before tar
#     reached it), and the gate blocked with "a scanner that reads the WHOLE repository fails" over
#     "(0 files)". Such a scanner now prints SUITE-UNMEASURED with its reason and exits 3; the push
#     is still held, since nothing was checked, but the block says what happened, with the reason.
add_unmeasured_scanner(){   # $1 = repo  $2 = name  $3 = also print a FAIL line (1) or not (0)
  cat > "$1/payload/hooks/test-$2.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
echo "scanner $2 ran"
[ $3 -eq 0 ] || echo "FAIL: scanner $2 found something"
echo "SUITE-UNMEASURED scanner $2 could not copy the tree: tar: payload/gone.txt: Cannot stat"
exit 3
EOF
  chmod +x "$1/payload/hooks/test-$2.sh"
}
R33="$(mkrepo unmeasured)"; add_scanner "$R33" alpha 0; add_unmeasured_scanner "$R33" omega 0; commit_all "$R33"
o33="$(fire "$R33" "git push")"; c33=$?
[ "$c33" -eq 2 ] && check "#1146 a scanner that could not read the tree still holds the push" ok \
  || check "#1146 a scanner that could not read the tree still holds the push" "exit=$c33 out=$o33"
grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o33" \
  && check "#1146 and never reports it as a failing scanner" "out=$o33" || check "#1146 and never reports it as a failing scanner" ok
grep -q 'measured nothing' <<< "$o33" && grep -q "fault in this gate's own run" <<< "$o33" \
  && check "#1146 and says it measured nothing, as a fault in the gate's own run" ok \
  || check "#1146 and says it measured nothing, as a fault in the gate's own run" "out=$o33"
grep -q 'omega could not copy the tree: tar: payload/gone.txt: Cannot stat' <<< "$o33" \
  && check "#1146 and gives the scanner's own reason" ok || check "#1146 and gives the scanner's own reason" "out=$o33"
grep -q 'alpha' <<< "$o33" \
  && check "#1146 and does not name the scanner that passed" "out=$o33" || check "#1146 and does not name the scanner that passed" ok
# Beside a scanner that really failed, each is reported as what it is, and a scanner printing a
# FAIL line is judged by it even if it also said it could not measure something.
R34="$(mkrepo unmeasuredandfail)"; add_scanner "$R34" gamma 1; add_unmeasured_scanner "$R34" omega 0; add_unmeasured_scanner "$R34" psi 1; commit_all "$R34"
o34="$(fire "$R34" "git push")"; c34=$?
[ "$c34" -eq 2 ] && grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o34" \
  && check "#1146 a real failure beside an unmeasured scanner is still reported as failing" ok \
  || check "#1146 a real failure beside an unmeasured scanner is still reported as failing" "exit=$c34 out=$o34"
fail_part="$(sed -n '/WHOLE repository fails/,/measured nothing/p' <<< "$o34")"
grep -q 'gamma' <<< "$fail_part" && grep -q 'psi found something' <<< "$fail_part" && ! grep -q 'omega' <<< "$fail_part" \
  && check "#1146 and the failing part names the failures, a FAIL line outranking SUITE-UNMEASURED" ok \
  || check "#1146 and the failing part names the failures, a FAIL line outranking SUITE-UNMEASURED" "out=$o34"
grep -q 'omega could not copy the tree' <<< "$o34" && grep -q 'measured nothing' <<< "$o34" \
  && check "#1146 and the unmeasured one is named apart, with its reason" ok \
  || check "#1146 and the unmeasured one is named apart, with its reason" "out=$o34"

# --- a scanner STOPPED AT ITS DEADLINE on a machine busier than its cores measured nothing either
#     (claude-config#1333). Since #1330, lib/suite-deadline.sh says so in its own agreed line,
#     SUITE-DEADLINE-UNMEASURED, and exits 124 with no FAIL line. This gate matched only
#     SUITE-UNMEASURED, so such a scanner blocked the push under "exited 124 with no FAIL line" and
#     the tail of its output, a failure heading for a run that judged nothing (L11, L683). The push
#     is still held, since nothing was scanned; what changes is that the block says why. The lines
#     below are the ones the library prints, with figures of the 2026-10-18 run (load about 30 on 12).
add_deadline_scanner(){   # $1 = repo  $2 = name  $3 = also print a FAIL line first (1) or not (0)
  cat > "$1/payload/hooks/test-$2.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
echo "scanner $2 ran"
[ $3 -eq 0 ] || echo "FAIL: scanner $2 found something"
echo "STOPPED, UNMEASURED: test-$2.sh ran past its own wall clock of 600s and was stopped, at a load average of 30.12 on 12 cores (1 of it this suite's own share), more than the machine has cores beyond that share (claude-config#1330)."
echo "  Run it again on its own on a quieter machine to judge it."
echo "SUITE-DEADLINE-UNMEASURED stopped at its 600s wall clock at a load average of 30.12 on 12 cores, more than the machine has cores beyond its own share of 1"
exit 124
EOF
  chmod +x "$1/payload/hooks/test-$2.sh"
}
R37="$(mkrepo deadlineunmeasured)"; add_scanner "$R37" alpha 0; add_deadline_scanner "$R37" chi 0; commit_all "$R37"
o37="$(fire "$R37" "git push")"; c37=$?
[ "$c37" -eq 2 ] && check "#1333 a scanner stopped at its deadline under load still holds the push" ok \
  || check "#1333 a scanner stopped at its deadline under load still holds the push" "exit=$c37 out=$o37"
if grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o37" || grep -q 'exited 124' <<< "$o37"; then
  check "#1333 and is never reported as a failing scanner that exited 124" "out=$o37"
else
  check "#1333 and is never reported as a failing scanner that exited 124" ok
fi
grep -q 'measured nothing' <<< "$o37" && grep -q "fault in this gate's own run" <<< "$o37" \
  && check "#1333 and says it measured nothing, in the gate's own words" ok \
  || check "#1333 and says it measured nothing, in the gate's own words" "out=$o37"
grep -q '^stopped at its 600s wall clock at a load average of 30.12 on 12 cores, more than the machine has cores beyond its own share of 1$' <<< "$o37" \
  && check "#1333 and gives the reason whole, without the marker" ok \
  || check "#1333 and gives the reason whole, without the marker" "out=$o37"
# The gate's own sentence, never the scanner's, whose tail also says "quieter machine".
grep -q 'retry the push when the machine is quieter' <<< "$o37" \
  && check "#1333 and says to retry on a quieter machine, the remedy for load" ok \
  || check "#1333 and says to retry on a quieter machine, the remedy for load" "out=$o37"
grep -q 'retry the push when the machine is quieter' <<< "$o33" \
  && check "#1333 and a scanner that could not read the tree is not told the machine was busy" "out=$o33" \
  || check "#1333 and a scanner that could not read the tree is not told the machine was busy" ok
# The same, end to end through the REAL library rather than lines copied from it (L48): a scanner
# that arms lib/suite-deadline.sh, starts past its deadline (SUITE_WALL_STARTED, the library's own
# seam, L524) and blocks on a child, on a load SET through lib/load-average.sh's seams to the
# 2026-10-18 figures rather than read off whatever this Mac is doing (L290).
printf '#!/bin/sh\necho 30.5\n' > "$TMPROOT/load-busy"; chmod +x "$TMPROOT/load-busy"
R39="$(mkrepo deadlinereal)"
cat > "$R39/payload/hooks/test-psi.sh" <<EOF
#!/usr/bin/env bash
. "$DIR/lib/suite-deadline.sh" || exit 1
suite_deadline_arm 60 || exit \$?
git ls-files '*.sh' >/dev/null
out="\$(sleep 30)"
echo "FAIL: scanner psi was never stopped"
EOF
chmod +x "$R39/payload/hooks/test-psi.sh"; commit_all "$R39"
o39="$(unset HOOK_TESTS_SLOTS
  export LOAD_AVERAGE_CMD="$TMPROOT/load-busy" LOAD_AVERAGE_CORES=12 \
    SUITE_WALL_STARTED=$(( $(date +%s) - 1000 )) SUITE_WALL_POLL=0.05
  fire "$R39" "git push")"; c39=$?
[ "$c39" -eq 2 ] && grep -q 'measured nothing' <<< "$o39" && grep -q '^stopped at its 60s wall clock at a load average of 30.5 on 12 cores' <<< "$o39" \
  && ! grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o39" \
  && check "#1333 a scanner the real library stopped under load is held as measuring nothing, with its reason" ok \
  || check "#1333 a scanner the real library stopped under load is held as measuring nothing, with its reason" "exit=$c39 out=$o39"

# --- each scanner is told its share of the machine, as run-all-tests.sh tells every suite
#     (claude-config#1333). The gate runs its scanners side by side and used to hand them no
#     HOOK_TESTS_SLOTS, so lib/suite-deadline.sh took a scanner's share as 1 and counted the
#     scanners this same push started beside it as load from elsewhere, which could excuse a stop as
#     a busy machine. Nothing bounds the gate's runs by a budget, so the share is every run in
#     flight at once. First what each one is handed: a scanner that records it.
add_slot_scanner(){   # $1 = repo  $2 = name
  cat > "$1/payload/hooks/test-$2.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
printf '%s' "\${HOOK_TESTS_SLOTS:-unset}" > "$TMPROOT/slots-$2"
exit 0
EOF
  chmod +x "$1/payload/hooks/test-$2.sh"
}
R40="$(mkrepo slots)"; add_slot_scanner "$R40" s1; add_slot_scanner "$R40" s2; add_slot_scanner "$R40" s3; commit_all "$R40"
o40="$(unset HOOK_TESTS_SLOTS; fire "$R40" "git push")"; c40=$?
[ "$c40" -eq 0 ] && [ "$(cat "$TMPROOT/slots-s1" "$TMPROOT/slots-s2" "$TMPROOT/slots-s3" 2>/dev/null)" = "333" ] \
  && check "#1333 each of three scanners run at once is handed a share of 3" ok \
  || check "#1333 each of three scanners run at once is handed a share of 3" "exit=$c40 handed=$(cat "$TMPROOT"/slots-s* 2>/dev/null) out=$o40"
# Then what the share decides, through the real library: a load of 15 on 12 cores is busy for a
# suite whose own share is 1 (15 less 1 is more than 12) and not busy for one of four scanners run
# at once (15 less 4 is not). So the stop beside three siblings is the FAIL it is, and the push is
# held either way.
printf '#!/bin/sh\necho 15\n' > "$TMPROOT/load-fifteen"; chmod +x "$TMPROOT/load-fifteen"
R41="$(mkrepo deadlinesiblings)"; cp "$R39/payload/hooks/test-psi.sh" "$R41/payload/hooks/test-psi.sh"
add_slot_scanner "$R41" t1; add_slot_scanner "$R41" t2; add_slot_scanner "$R41" t3; commit_all "$R41"
o41="$(unset HOOK_TESTS_SLOTS
  export LOAD_AVERAGE_CMD="$TMPROOT/load-fifteen" LOAD_AVERAGE_CORES=12 \
    SUITE_WALL_STARTED=$(( $(date +%s) - 1000 )) SUITE_WALL_POLL=0.05
  fire "$R41" "git push")"; c41=$?
[ "$c41" -eq 2 ] && grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o41" && grep -q 'ran past its own wall clock of 60s' <<< "$o41" \
  && ! grep -q 'measured nothing' <<< "$o41" \
  && check "#1333 a stop whose load is the push's own scanners is a FAIL, not excused as a busy machine" ok \
  || check "#1333 a stop whose load is the push's own scanners is a FAIL, not excused as a busy machine" "exit=$c41 out=$o41"
# The control, so the case above is the share at work and not a load the library never excuses:
# the same scanner alone, at the same load, is UNMEASURED.
R42="$(mkrepo deadlinealone)"; cp "$R39/payload/hooks/test-psi.sh" "$R42/payload/hooks/test-psi.sh"; commit_all "$R42"
o42="$(unset HOOK_TESTS_SLOTS
  export LOAD_AVERAGE_CMD="$TMPROOT/load-fifteen" LOAD_AVERAGE_CORES=12 \
    SUITE_WALL_STARTED=$(( $(date +%s) - 1000 )) SUITE_WALL_POLL=0.05
  fire "$R42" "git push")"; c42=$?
[ "$c42" -eq 2 ] && grep -q 'measured nothing' <<< "$o42" && grep -q 'load average of 15 on 12 cores' <<< "$o42" \
  && check "#1333 and the same stop alone at the same load is held as UNMEASURED" ok \
  || check "#1333 and the same stop alone at the same load is held as UNMEASURED" "exit=$c42 out=$o42"
# A FAIL line printed before the stop outranks the deadline line, as it does SUITE-UNMEASURED: a
# scanner that found something is judged by what it found.
R38="$(mkrepo deadlineafterfail)"; add_deadline_scanner "$R38" phi 1; commit_all "$R38"
o38="$(fire "$R38" "git push")"; c38=$?
[ "$c38" -eq 2 ] && grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o38" && grep -q 'phi found something' <<< "$o38" \
  && check "#1333 a FAIL printed before the deadline stop is still reported as failing" ok \
  || check "#1333 a FAIL printed before the deadline stop is still reported as failing" "exit=$c38 out=$o38"
# The gate's OWN listing of the uncommitted files is the same kind of read: when it fails, the count
# is unknown, never zero, and with the uncommitted files unread there is no key a pass can be
# remembered on, or a later push would skip a scan over files nobody had read (#1146, L90). Run from
# a copy of the gate whose repo-files.sh refuses the listings of what is not committed, the count's
# and, since #1910, the key's, and nothing else.
FAKEHOOKS="$TMPROOT/fakehooks"; mkdir -p "$FAKEHOOKS/lib"
cp "$H" "$FAKEHOOKS/scanners-before-push.sh"; cp "$DIR/lib/push-scope.sh" "$DIR/lib/whole-number.sh" "$DIR/lib/work-names-messages.sh" "$DIR/lib/work-names.py" "$DIR/lib/dev-update-registry.js" "$FAKEHOOKS/lib/"
cat > "$FAKEHOOKS/lib/repo-files.sh" <<EOF
#!/usr/bin/env bash
case "\$1" in --uncommitted|--changed) echo "repo-files: git could not list the files under \$2 that are not committed." >&2; exit 1 ;; esac
exec bash "$DIR/lib/repo-files.sh" "\$@"
EOF
R36="$(mkrepo uncommittedunread)"; add_scanner "$R36" alpha 0; commit_all "$R36"
UNREAD_STATE="$TMPROOT/unread-state"
o36="$(H="$FAKEHOOKS/scanners-before-push.sh" SCANNERS_STATE_DIR="$UNREAD_STATE" fire "$R36" "git push")"; c36=$?
[ "$c36" -eq 0 ] && grep -q 'reading an unknown number of uncommitted file(s)' <<< "$o36" \
  && check "#1146 an uncommitted listing that fails is counted as unknown, never as zero" ok \
  || check "#1146 an uncommitted listing that fails is counted as unknown, never as zero" "exit=$c36 out=$o36"
[ -z "$(ls -A "$UNREAD_STATE" 2>/dev/null)" ] \
  && check "#1146 and no pass is remembered while the uncommitted files went unread" ok \
  || check "#1146 and no pass is remembered while the uncommitted files went unread" "it wrote: $(cat "$UNREAD_STATE"/* 2>/dev/null)"

# A scanner that fails with no FAIL line and neither unmeasured line (SUITE-UNMEASURED, or
# SUITE-DEADLINE-UNMEASURED since #1333) is a failure, and its detail is the end of what it printed, never an empty one: the block over #642 had nothing under the name.
R35="$(mkrepo nofailline)"
printf '#!/usr/bin/env bash\ngit ls-files >/dev/null\necho "kappa broke: tar: x: Cannot stat" >&2\nexit 1\n' > "$R35/payload/hooks/test-kappa.sh"
commit_all "$R35"
o35="$(fire "$R35" "git push")"; c35=$?
[ "$c35" -eq 2 ] && grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o35" && grep -q 'kappa broke: tar: x: Cannot stat' <<< "$o35" \
  && check "#1146 a scanner failing with no FAIL line shows the end of what it printed" ok \
  || check "#1146 a scanner failing with no FAIL line shows the end of what it printed" "exit=$c35 out=$o35"

# --- the override, which exists for the same one time reason as every other gate here.
o6="$(fire "$R2" "SKIP_SCANNERS_CHECK=1 git push")"; c6=$?
[ "$c6" -eq 0 ] \
  && check "the override lets a blocked push through" ok \
  || check "the override lets a blocked push through" "exit=$c6 out=$o6"
grep -qi 'SKIP_SCANNERS_CHECK' <<< "$o2" \
  && check "and the block names the override" ok || check "and the block names the override" "out=$o2"

# --- a scanner that is TRACKED but only just written is still run: a gate that enumerates from
#     what git tracked at some earlier moment cannot see the file being added, which is the file
#     most likely to be wrong (L456).
R5="$(mkrepo fresh)"; add_scanner "$R5" delta 1; commit_all "$R5"
o7="$(fire "$R5" "git push")"; c7=$?
[ "$c7" -eq 2 ] && grep -q 'delta' <<< "$o7" \
  && check "a newly committed scanner is run like any other" ok \
  || check "a newly committed scanner is run like any other" "exit=$c7 out=$o7"

# --- a scanner that has NOT been committed is run too (claude-config#522). The gate used to pick its
#     subjects from what git tracks, so a scanner just written was not run until the push after the
#     one that added it, and a file just written was not read by the scanners that did run (L456).
R7="$(mkrepo uncommitted)"; add_scanner "$R7" alpha 0; commit_all "$R7"
add_scanner "$R7" epsilon 1
o9="$(fire "$R7" "git push")"; c9=$?
[ "$c9" -eq 2 ] && grep -q 'epsilon' <<< "$o9" \
  && check "a scanner not yet committed is run like any other" ok \
  || check "a scanner not yet committed is run like any other" "exit=$c9 out=$o9"

# --- a scanner that lists the repository through lib/repo-files.sh, the one way scanners here do
#     it now, is recognised as a scanner. Keyed only on the git command, the gate would stop seeing
#     every suite that was converted.
R8="$(mkrepo lister)"
printf '#!/usr/bin/env bash\nbash "$LIB/repo-files.sh" . >/dev/null\necho "scanner zeta ran"\nexit 1\n' > "$R8/payload/hooks/test-zeta.sh"
commit_all "$R8"
o10="$(fire "$R8" "git push")"; c10=$?
[ "$c10" -eq 2 ] && grep -q 'zeta' <<< "$o10" \
  && check "a scanner that lists through repo-files.sh is recognised" ok \
  || check "a scanner that lists through repo-files.sh is recognised" "exit=$c10 out=$o10"

# --- and it says how many uncommitted files it read, because none and some are different
#     situations that a bare pass line would make look the same.
grep -q '0 uncommitted' <<< "$o1" \
  && check "a clean tree's pass line says no uncommitted file was read" ok \
  || check "a clean tree's pass line says no uncommitted file was read" "out=$o1"
R9="$(mkrepo counted)"; add_scanner "$R9" alpha 0; commit_all "$R9"
printf 'x\n' > "$R9/draft.sh"; printf 'x\n' > "$R9/draft2.sh"
o11="$(fire "$R9" "git push")"; c11=$?
[ "$c11" -eq 0 ] && grep -q '2 uncommitted' <<< "$o11" \
  && check "and says how many it read when there are some" ok \
  || check "and says how many it read when there are some" "exit=$c11 out=$o11"
grep -q '2 uncommitted' <<< "$o9" \
  && check "and a block says it too, so a draft can be told from committed work" "out=$o9" \
  || { grep -q '1 uncommitted' <<< "$o9" \
       && check "and a block says it too, so a draft can be told from committed work" ok \
       || check "and a block says it too, so a draft can be told from committed work" "out=$o9"; }

# --- a scanner whose COMMENT mentions this gate is still one of its subjects. Only a suite whose
#     code names the gate drives it; a mention in prose used to drop the scanner silently.
R11="$(mkrepo mentions)"
printf '#!/usr/bin/env bash\n# written after %s went in\ngit ls-files >/dev/null\necho "scanner theta ran"\nexit 1\n' "$(basename "$H")" > "$R11/payload/hooks/test-theta.sh"
commit_all "$R11"
o12="$(fire "$R11" "git push")"; c12=$?
[ "$c12" -eq 2 ] && grep -q 'theta' <<< "$o12" \
  && check "a scanner that only mentions this gate in a comment is still run" ok \
  || check "a scanner that only mentions this gate in a comment is still run" "exit=$c12 out=$o12"

# --- listing the selection runs NONE of it. It used to be read after every scanner had already
#     run, so asking what the gate covers cost exactly what the gate costs (L102).
R10="$(mkrepo listonly)"
printf '#!/usr/bin/env bash\ngit ls-files >/dev/null\n: > "%s/ran"\nexit 0\n' "$R10" > "$R10/payload/hooks/test-eta.sh"
commit_all "$R10"
_l="$(printf '{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"%s"}' "$R10" | SCANNERS_LIST=1 bash "$H" 2>&1)"
[ ! -e "$R10/ran" ] && grep -q '^SUITE payload/hooks/test-eta.sh$' <<< "$_l" \
  && check "listing the selection names it without running it" ok \
  || check "listing the selection names it without running it" "ran=$( [ -e "$R10/ran" ] && echo yes || echo no) out=$_l"

# --- the scanners run AT ONCE, not one after another. Five suites that share nothing are five
#     lots of wall clock a push waits through for no reason (L302). Measured on this Mac
#     2026-09-21: 27 seconds in sequence, of which 21 was those five, against 13 run at once.
#
#     Proved by RENDEZVOUS rather than by a stopwatch: each of the two fixture scanners raises its
#     own marker and then waits for the other's. Run at once they both see it and pass; run one
#     after another the first waits out its bound and fails, so the gate blocks. A timing
#     assertion here would be a claim about how busy the machine is (L290).
#
#     Each waits on the CONDITION, the other's marker, polled every twentieth of a second, under a
#     ceiling of 120 seconds by the clock (claude-config#1462). That is far above any start delay
#     seen: the old spin, which lasted from 3 seconds to a little over 5 (measured below), never
#     once ran out in over 4,000 runs at load averages up to 192 on 12 cores (#1454). A pair run in
#     sequence therefore costs the whole ceiling before it fails, which is the price of never
#     failing a pair that did run at once.
add_rendezvous_scanner(){   # $1 = repo  $2 = rendezvous folder  $3 = me  $4 = the other
                            # $5 = seconds before it starts  $6 = the ceiling on its wait, seconds
  cat > "$1/payload/hooks/test-$3.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
sleep $5
: > "$2/$3"
deadline=\$(( SECONDS + $6 ))
while [ ! -e "$2/$4" ]; do
  if [ "\$SECONDS" -ge "\$deadline" ]; then
    echo "FAIL: $3 waited its whole ceiling of $6 seconds and $4 never started, so they ran one after another"
    exit 1
  fi
  sleep 0.05
done
exit 0
EOF
  chmod +x "$1/payload/hooks/test-$3.sh"
}
rendezvous_repo(){          # $1 = name  $2 = seconds beta starts late  -> prints the repo path
  local r rv; r="$(mkrepo "$1")"; rv="$TMPROOT/rendezvous-$1"; mkdir -p "$rv"
  add_rendezvous_scanner "$r" "$rv" alpha beta 0 120
  add_rendezvous_scanner "$r" "$rv" beta alpha "$2" 120
  commit_all "$r"; printf '%s' "$r"
}
R6="$(rendezvous_repo concurrent 0)"
o8="$(fire "$R6" "git push")"; c8=$?
[ "$c8" -eq 0 ] \
  && check "the scanners run at once rather than in sequence" ok \
  || check "the scanners run at once rather than in sequence" "exit=$c8 out=$o8"

# --- and each waits for the OTHER TO START, not for a fixed stretch of its own (claude-config#1462).
#     The wait was once 400000 turns of a loop, which is a clock in disguise (L290), and how long it
#     lasted moved with the machine. Measured on this Mac 2026-10-21, load 5 to 10 on 12 cores: 3.0
#     seconds bare (five runs, 2.89 to 3.04), 3.75 when the file it looks for sits in a folder under
#     TMPDIR as here, 4.3 under the gate, and longer than 5 inside a run of this suite, where a peer
#     STAGED 5 seconds late still passed against it. No real run ever started a peer that late, but
#     one that did would have failed the check with both running at once. Here beta starts 10
#     seconds late, twice the longest spin seen, and the pair must still pass; against the old spin
#     it failed.
R6L="$(rendezvous_repo latepeer 10)"
o8l="$(fire "$R6L" "git push")"; c8l=$?
[ "$c8l" -eq 0 ] \
  && check "a scanner waits for a peer that starts later than a fixed spin would last" ok \
  || check "a scanner waits for a peer that starts later than a fixed spin would last" "exit=$c8l out=$o8l"

# --- the wait has a CEILING, and reaching it says which ceiling it was. A peer that never starts
#     is the serial case R6 exists to catch, so it must end in a FAIL naming the bound, never a
#     wait without end. The ceiling is handed in, so this costs no real wait (L524).
R6C="$(mkrepo nopeer)"; mkdir -p "$TMPROOT/rendezvous-nopeer"
add_rendezvous_scanner "$R6C" "$TMPROOT/rendezvous-nopeer" alpha beta 0 0
commit_all "$R6C"
o8c="$(fire "$R6C" "git push")"; c8c=$?
[ "$c8c" -eq 2 ] && grep -q 'alpha waited its whole ceiling of 0 seconds and beta never started' <<< "$o8c" \
  && check "a peer that never starts fails at the ceiling, and names it" ok \
  || check "a peer that never starts fails at the ceiling, and names it" "exit=$c8c out=$o8c"

# --- the FLOOR on how many scanners the selection holds (claude-config#530). The set is derived,
#     which is right, and it can shrink to nothing without a word: on 2026-09-21 a conversion moved
#     the scanners off the text the installed gate keyed on, it silently stopped selecting two of
#     them, and two defects both of them catch went to main. A smaller number reads exactly like a
#     healthy one (L98, L182).
R12="$(mkrepo floorshort)"; add_scanner "$R12" alpha 0; commit_all "$R12"
mkdir -p "$R12/.claude"; printf '3\n' > "$R12/.claude/scanners-floor.txt"
git -C "$R12" add -A >/dev/null 2>&1; git -C "$R12" commit -q -m floor >/dev/null 2>&1
o13="$(fire "$R12" "git push")"; c13=$?
[ "$c13" -eq 2 ] \
  && check "a selection below the recorded floor blocks the push" ok \
  || check "a selection below the recorded floor blocks the push" "exit=$c13 out=$o13"
case "$o13" in
  *"1"*"3"*) check "and says what it found against what it expects" ok ;;
  *) check "and says what it found against what it expects" "out=$o13" ;;
esac
case "$o13" in
  *scanners-floor.txt*) check "and names the file to lower when a scanner is deliberately removed" ok ;;
  *) check "and names the file to lower when a scanner is deliberately removed" "out=$o13" ;;
esac

# A selection that MEETS its floor runs as usual, and the pass line says the floor was met, so the
# number is visible rather than only checked.
R13="$(mkrepo floorok)"; add_scanner "$R13" alpha 0; add_scanner "$R13" beta2 0; commit_all "$R13"
mkdir -p "$R13/.claude"; printf '2\n' > "$R13/.claude/scanners-floor.txt"
git -C "$R13" add -A >/dev/null 2>&1; git -C "$R13" commit -q -m floor >/dev/null 2>&1
o14="$(fire "$R13" "git push")"; c14=$?
[ "$c14" -eq 0 ] && check "a selection that meets its floor lets the push through" ok \
  || check "a selection that meets its floor lets the push through" "exit=$c14 out=$o14"
case "$o14" in *"floor"*) check "and the pass line says the floor was met" ok ;;
  *) check "and the pass line says the floor was met" "out=$o14" ;; esac

# A repository with no floor recorded is not blocked, and is told what to record, because a gate
# that refuses a repo for lacking a file it never had stops work for no reason (L42).
R14="$(mkrepo floornone)"; add_scanner "$R14" alpha 0; commit_all "$R14"
o15="$(fire "$R14" "git push")"; c15=$?
[ "$c15" -eq 0 ] && check "no recorded floor does not block the push" ok \
  || check "no recorded floor does not block the push" "exit=$c15 out=$o15"
case "$o15" in *"no floor"*|*"not recorded"*) check "but it says no floor is recorded, and how to record one" ok ;;
  *) check "but it says no floor is recorded, and how to record one" "out=$o15" ;; esac

# The floor file carries a line saying what the number is for, because a bare number in a file
# nobody can read is one somebody lowers without knowing what it measured.
R16="$(mkrepo floorcomment)"; add_scanner "$R16" alpha 0; add_scanner "$R16" beta2 0; commit_all "$R16"
mkdir -p "$R16/.claude"; printf '# how many whole tree scanners this repo expects\n2\n' > "$R16/.claude/scanners-floor.txt"
git -C "$R16" add -A >/dev/null 2>&1; git -C "$R16" commit -q -m floor >/dev/null 2>&1
o17="$(fire "$R16" "git push")"; c17=$?
[ "$c17" -eq 0 ] && case "$o17" in *"floor of 2"*) true ;; *) false ;; esac \
  && check "a floor file may explain itself in a comment line" ok \
  || check "a floor file may explain itself in a comment line" "exit=$c17 out=$o17"

# A floor that is not a number is a refusal to judge rather than a silent zero, which would exempt
# the repository from the check it recorded (L257).
R15="$(mkrepo floorjunk)"; add_scanner "$R15" alpha 0; commit_all "$R15"
mkdir -p "$R15/.claude"; printf 'lots\n' > "$R15/.claude/scanners-floor.txt"
git -C "$R15" add -A >/dev/null 2>&1; git -C "$R15" commit -q -m floor >/dev/null 2>&1
o16="$(fire "$R15" "git push")"; c16=$?
case "$o16" in *"not a number"*) check "a floor that is not a number is said, not read as zero" ok ;;
  *) check "a floor that is not a number is said, not read as zero" "exit=$c16 out=$o16" ;; esac

# --- A floor that NAMES its suites (claude-config#1744). A count can say only that fewer were
#     selected, so on 2026-10-25 the floor recorded 6 while 21 were selected, 15 free to leave (L98,
#     L182). Recorded as the suites' paths, a suite that stops being selected is named.
R17="$(mkrepo floornames)"; add_scanner "$R17" alpha 0; add_scanner "$R17" beta2 0; commit_all "$R17"
mkdir -p "$R17/.claude"
printf '# the whole tree scanners this repo expects\npayload/hooks/test-alpha.sh\npayload/hooks/test-beta2.sh\n' > "$R17/.claude/scanners-floor.txt"
git -C "$R17" add -A >/dev/null 2>&1; git -C "$R17" commit -q -m floor >/dev/null 2>&1
o18="$(fire "$R17" "git push")"; c18=$?
[ "$c18" -eq 0 ] && case "$o18" in *"floor of 2"*) true ;; *) false ;; esac \
  && check "#1744 a floor naming every suite it selects lets the push through, saying the floor was met" ok \
  || check "#1744 a floor naming every suite it selects lets the push through, saying the floor was met" "exit=$c18 out=$o18"
# Adding a scanner never fails a push.
add_scanner "$R17" gamma3 0; commit_all "$R17"
o19="$(fire "$R17" "git push")"; c19=$?
[ "$c19" -eq 0 ] \
  && check "#1744 a scanner the floor does not name yet does not block the push" ok \
  || check "#1744 a scanner the floor does not name yet does not block the push" "exit=$c19 out=$o19"
# A named suite that stops reading the repository's files drops out of the selection: blocked, by name.
printf '#!/usr/bin/env bash\nexit 0\n' > "$R17/payload/hooks/test-beta2.sh"; commit_all "$R17"
o20="$(fire "$R17" "git push")"; c20=$?
[ "$c20" -eq 2 ] && grep -q 'payload/hooks/test-beta2.sh' <<< "$o20" && ! grep -q 'no longer selected.*test-alpha' <<< "$o20" \
  && check "#1744 a named suite that is no longer selected blocks the push, naming it" ok \
  || check "#1744 a named suite that is no longer selected blocks the push, naming it" "exit=$c20 out=$o20"
case "$o20" in
  *"scanners-floor.txt"*) check "#1744 and says to take it out of the floor if it was removed on purpose" ok ;;
  *) check "#1744 and says to take it out of the floor if it was removed on purpose" "out=$o20" ;;
esac

# --- a scanner whose INPUTS have not changed since it passed is not run again (claude-config#531).
#     Measured 2026-09-21: the scanners are 15.3 of the 20.1 seconds a push waits, and they re-read
#     the whole repository on every push even when nothing they read has changed, which is most
#     pushes. Proved by a scanner that APPENDS a line every time it actually runs, so a skip is a
#     line that did not appear rather than a message that says one did not (L1).
SKIPSTATE="$TMPROOT/skip-state"
fire_skip(){ # $1 = repo  $2 = command
  SCANNERS_STATE_DIR="$SKIPSTATE" fire "$1" "$2"
}
R17="$(mkrepo unchanged)"
RAN="$TMPROOT/unchanged-ran"
cat > "$R17/payload/hooks/test-iota.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
echo ran >> "$RAN"
exit 0
EOF
chmod +x "$R17/payload/hooks/test-iota.sh"
commit_all "$R17"
o18="$(fire_skip "$R17" "git push")"
o19="$(fire_skip "$R17" "git push")"
[ "$(grep -c . "$RAN" 2>/dev/null || echo 0)" = "1" ] \
  && check "a scanner is not run again when nothing it reads has changed" ok \
  || check "a scanner is not run again when nothing it reads has changed" "it ran $(grep -c . "$RAN" 2>/dev/null || echo 0) time(s)"
case "$o19" in
  *skip*|*"already passed"*) check "and the gate says so rather than reporting a scan it did not make" ok ;;
  *) check "and the gate says so rather than reporting a scan it did not make" "out=$o19" ;;
esac

# When EVERY scanner is skipped, nothing was scanned at this moment, and the line must say that
# rather than "0 scans passed", which reads as a clean run over nothing (L98).
case "$o19" in
  *"nothing was scanned"*|*"scanned nothing"*) check "a push where every scanner was skipped says nothing was scanned now" ok ;;
  *) check "a push where every scanner was skipped says nothing was scanned now" "out=$o19" ;;
esac

# A COMMIT changes what the scanners read, so they run again.
printf 'x\n' > "$R17/newfile.sh"; commit_all "$R17"
o20="$(fire_skip "$R17" "git push")"
[ "$(grep -c . "$RAN" 2>/dev/null || echo 0)" = "2" ] \
  && check "a commit makes it run again" ok \
  || check "a commit makes it run again" "it ran $(grep -c . "$RAN" 2>/dev/null || echo 0) time(s)"

# So does a file that is written and NOT committed, which is the file most likely to be wrong and
# the one the scanners were taught to read in #522.
printf 'y\n' > "$R17/draft.sh"
o21="$(fire_skip "$R17" "git push")"
[ "$(grep -c . "$RAN" 2>/dev/null || echo 0)" = "3" ] \
  && check "an uncommitted file makes it run again" ok \
  || check "an uncommitted file makes it run again" "it ran $(grep -c . "$RAN" 2>/dev/null || echo 0) time(s)"

# A scanner that FAILED is never skipped: only a pass is worth remembering, or a failure would be
# skipped past on the very next push (L98).
R18="$(mkrepo failsagain)"
FRAN="$TMPROOT/fails-ran"
cat > "$R18/payload/hooks/test-kappa.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
echo ran >> "$FRAN"
echo "FAIL: kappa says no"
exit 1
EOF
chmod +x "$R18/payload/hooks/test-kappa.sh"
commit_all "$R18"
o22="$(fire_skip "$R18" "git push")"
o23="$(fire_skip "$R18" "git push")"
[ "$(grep -c . "$FRAN" 2>/dev/null || echo 0)" = "2" ] \
  && check "a scanner that failed is run again on the next push" ok \
  || check "a scanner that failed is run again on the next push" "it ran $(grep -c . "$FRAN" 2>/dev/null || echo 0) time(s)"
case "$o23" in *kappa*) check "and still blocks the push" ok ;;
  *) check "and still blocks the push" "out=$o23" ;; esac

# --- the line PR #1732 took to CI holds the push here (claude-config#1734). A checkout carrying the
#     real home path check and its suite, plus a fixture quoting a refusal whose hook path names
#     THIS machine's own config directory: the shape that reads as fine on the Mac that wrote it
#     (L177). The path is assembled from the running home, so this file names no machine. The same
#     checkout without that line is the control, so a block can only be the line.
R1734="$(mkrepo homepath1734)"
: > "$R1734/claude-sync"
cp "$DIR/check-home-paths.sh" "$DIR/test-check-home-paths.sh" "$R1734/payload/hooks/"
cp -R "$DIR/lib" "$R1734/payload/hooks/lib"
# A suite run earlier leaves lib/__pycache__ behind, ignored by the real repository but committed by
# this one, which the home path check skips: a file listed and never read fails it (PR #1741's CI, 2026-10-25).
find "$R1734/payload/hooks/lib" -name __pycache__ -type d -prune -exec rm -rf {} +
printf '#!/usr/bin/env bash\necho quoted\n' > "$R1734/payload/hooks/quoted-refusal.sh"
commit_all "$R1734"
o1734c="$(fire "$R1734" "git push")"; c1734c=$?
# Passing because the home path check RAN and passed, never because nothing was selected (L98).
[ "$c1734c" -eq 0 ] && grep -q '1 whole tree scan(s) passed' <<< "$o1734c" \
  && check "#1734 control: the checkout without the line runs the home path check and pushes" ok \
  || check "#1734 control: the checkout without the line runs the home path check and pushes" "exit=$c1734c out=$o1734c"
printf 'hook error: [%s/.claude/hooks/handback-claims-gate.sh]: REFUSED (handback-claims-gate.sh): your report contradicts your own commands.\n' \
  "$HOME" >> "$R1734/payload/hooks/quoted-refusal.sh"
commit_all "$R1734"
o1734="$(fire "$R1734" "git push")"; c1734=$?
[ "$c1734" -eq 2 ] && grep -q 'test-check-home-paths' <<< "$o1734" \
  && check "#1734 a fixture naming this machine's own home blocks the push, named by the home path check" ok \
  || check "#1734 a fixture naming this machine's own home blocks the push, named by the home path check" "exit=$c1734 out=$o1734"

# --- the selection against THIS repository, read rather than assumed. Fixtures can only confirm
#     the rule as written; what matters is which real suites it picks, and above all that it never
#     picks the four minute suite as a whole (measured 2026-09-21: the selection below runs in 27
#     seconds, where running that suite whole would be 268).
# Found by the one shared test, lib/checkout-root.sh (claude-config#1663): empty outside a checkout.
REAL="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -n "$REAL" ] && [ -f "$REAL/payload/hooks/run-all-tests.sh" ]; then
  _sel="$(printf '{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"%s"}' "$REAL" \
          | SCANNERS_LIST=1 bash "$H" 2>&1)"
  [ "$(grep -c '^SUITE ' <<< "$_sel")" -ge 5 ] \
    && check "the real repo's standalone scanners are all selected" ok \
    || check "the real repo's standalone scanners are all selected" "got=$_sel"
  for _want in test-pipefail-shortcircuit.sh test-repo-files.sh; do
    grep -q "^SUITE payload/hooks/$_want\$" <<< "$_sel" \
      && check "and $_want is among them" ok \
      || check "and $_want is among them" "got=$_sel"
  done
  # The secret scan over every file a push publishes is a scanner by the same rule, and it is the
  # one check that stands between a credential anywhere in the tree and GitHub (claude-config#1128).
  # Nothing in this gate names it, so this is what says it is still picked.
  grep -q '^SUITE tests/test-payload-secret-scan\.sh$' <<< "$_sel" \
    && check "and the whole tree secret scan is among them" ok \
    || check "and the whole tree secret scan is among them" "got=$_sel"
  # The home path check reads every synced file, and on 2026-10-25 only CI ran it, so a fixture
  # naming one machine's home cost PR #1732 a whole CI round (claude-config#1734).
  grep -q '^SUITE payload/hooks/test-check-home-paths\.sh$' <<< "$_sel" \
    && check "#1734 and the home path check is among them" ok \
    || check "#1734 and the home path check is among them" "got=$_sel"
  # The recorded floor names exactly the suites selected here, so it can never again sit far below
  # the selection (claude-config#1744: on 2026-10-25 it recorded 6 while 21 were selected). A scanner added is
  # named in the same change; one removed on purpose is taken out.
  _real_sel="$(awk '{ print $2 }' <<< "$_sel" | sort -u)"
  _real_floor="$(awk '/^[[:space:]]*#/ { next } NF { print $1 }' "$REAL/.claude/scanners-floor.txt" 2>/dev/null | sort -u)"
  _real_n="$(grep -c . <<< "$_real_sel")"
  [ "$_real_n" -ge 21 ] && [ "$_real_sel" = "$_real_floor" ] \
    && check "#1744 the repository's floor names exactly the $_real_n suites the gate selects" ok \
    || check "#1744 the repository's floor names exactly the $_real_n suites the gate selects" "selected and not named: $(comm -23 <(printf '%s\n' "$_real_sel") <(printf '%s\n' "$_real_floor") | tr '\n' ' ')/ named and not selected: $(comm -13 <(printf '%s\n' "$_real_sel") <(printf '%s\n' "$_real_floor") | tr '\n' ' ')"
  # NO SCANNER WAITS ON ANOTHER SUITE RUN'S LOCK (claude-config#2033). Every refusal for time this
  # gate gave on 2026-11-01 after #1997, seven of them at load averages of 21 to 95, named one run
  # still going: the sync suite's section scanning comments for undated numbers, running for 1 or 2
  # seconds. That suite takes a machine wide lock, which every full run holds for minutes, and
  # builders run one just before they push, so the section refused on the lock and was started
  # again every few seconds until the budget ran out. The scan now lives in a suite of its own that
  # takes no lock, so it still runs before every push and nothing in the gate's path can be held up
  # by another run. A suite takes that lock when its code makes the lock's directory. Its code is
  # read into a variable and matched with case, never piped into grep -q, which leaves on its first
  # hit and under pipefail reports the match as a failure (L183).
  _lockers=""
  while IFS= read -r _ln; do
    _sf="$(awk '{ print $2 }' <<< "$_ln")"
    [ -n "$_sf" ] || continue
    _code="$(grep -v '^[[:space:]]*#' "$REAL/$_sf" 2>/dev/null)"
    case "$_code" in *'mkdir "$SUITE_LOCK"'*) _lockers="$_lockers $_ln;" ;; esac
  done <<< "$_sel"
  [ -z "$_lockers" ] \
    && check "#2033 no scanner the gate selects belongs to a suite that takes the machine wide suite lock" ok \
    || check "#2033 no scanner the gate selects belongs to a suite that takes the machine wide suite lock" "these wait on any full run:$_lockers"
  grep -q '^SUITE tests/test-undated-measurements\.sh$' <<< "$_sel" \
    && check "#2033 and the scan for undated numbers in comments and documents is selected as a suite of its own" ok \
    || check "#2033 and the scan for undated numbers in comments and documents is selected as a suite of its own" "got=$_sel"
  grep -q "^SUITE .*$(basename "$H")$" <<< "$_sel" \
    && check "and the suite that drives this gate is not one of its own subjects" "it selected itself: $_sel" \
    || check "and the suite that drives this gate is not one of its own subjects" ok
  grep -q '^SUITE tests/test-claude-sync.sh$' <<< "$_sel" \
    && check "and the four minute suite is never selected whole" "it would run whole: $_sel" \
    || check "and the four minute suite is never selected whole" ok
  # The runner's own suite is the slowest whole suite there is: it starts the runner on dozens of
  # fixture trees, and on 2026-10-31 this gate recorded 510 seconds for it against a budget of 150,
  # so every push was refused once and waited for it (claude-config#1997). Only a few of its checks
  # read this repository's files, and those live in a scanner of their own, which IS selected, so
  # they still run before every push while the fixture runs do not.
  grep -q '^SUITE payload/hooks/test-run-all-tests\.sh$' <<< "$_sel" \
    && check "#1997 and the runner's own suite is never selected whole" "it would run whole, about 500 seconds against the budget: $_sel" \
    || check "#1997 and the runner's own suite is never selected whole" ok
  grep -q '^SUITE payload/hooks/test-run-all-tests-real-tree\.sh$' <<< "$_sel" \
    && check "#1997 and the runner suite's checks over this repository's files are selected" ok \
    || check "#1997 and the runner suite's checks over this repository's files are selected" "got=$_sel"
else
  # The INSTALLED copy of these hooks sits in ~/.claude, where there is no repository and never
  # will be, so there is no selection to read and that is not a fault. Said out loud rather than
  # skipped in silence, because a suite that quietly checks less is how coverage disappears (L98).
  echo "  (no repository at $REAL, so the selection against a real tree was not checked here; it is checked where this repo is)"
fi

# --- scanners that do not finish inside the gate's own budget REFUSE the push (claude-config#1881).
#     On 2026-10-28 this gate was killed at its declared 180 second timeout on three of three cold
#     readings at a load average of about 145. Claude Code's hooks documentation says a PreToolUse
#     hook killed at its timeout "doesn't block the tool call", and a headless probe the same day
#     confirmed it: a hook that slept past a 3 second timeout and would then have refused let a
#     `touch` through. So a push under load went out with nothing scanned. The gate now enforces a
#     budget of its own below the declared timeout, and refuses when its scanners have not finished
#     inside it.
#
#     A SCANNER STILL RUNNING AT THE BUDGET IS LEFT RUNNING, ON ITS OWN (claude-config#1881 follow
#     up). #1889 killed it, and the whole repository suite, test-run-all-tests.sh, took about 410
#     seconds in CI and 444 on a busy Mac on 2026-10-29, so it could never finish inside 150: every push that
#     needed it was refused, and each retry started it again from nothing. Three of three pushes by
#     one builder were refused that way on 2026-10-29. So the gate now leaves such a run going in a
#     process group of its own, writing to a file, refuses saying so, and a later push of the SAME
#     tree and uncommitted files counts its verdict rather than running it again.
#
#     The budget is injected (SCANNERS_BUDGET_SECONDS), so these cases wait 2 seconds rather than
#     150. A held scanner records its process id and each run it makes, so "still running", "not
#     run twice" and "stopped" are checked on the processes and the runs rather than believed from
#     the gate's message (L1). It holds while its hold file exists, for at most 60 seconds, so a
#     case can release it rather than sleep, and a leaked one ends on its own (L290).
add_held_scanner(){   # $1 = repo  $2 = name  $3 = the hold file  $4 = exit code once released
  cat > "$1/payload/hooks/test-$2.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
echo ran >> "$TMPROOT/$2.runs"
echo "scanner $2 started"
echo \$\$ > "$TMPROOT/$2.pid"
n=0
while [ -e "$3" ] && [ "\$n" -lt 600 ]; do sleep 0.1; n=\$((n+1)); done
echo "scanner $2 finished"
exit ${4:-0}
EOF
  chmod +x "$1/payload/hooks/test-$2.sh"
}
# The runs a held scanner has made, counted from its own record.
held_runs(){ grep -c . "$TMPROOT/$1.runs" 2>/dev/null || true; }
# Waits until the held scanner's recorded process has gone, with the shared ceiling only a hang
# reaches (lib/hang-wait.sh), never a short one a loaded Mac would. 0 when it has gone.
. "$DIR/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing, so the waits on a released scanner cannot be bounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
held_gone(){   # $1 = name
  local p
  p="$(cat "$TMPROOT/$1.pid" 2>/dev/null)"
  [ -n "$p" ] || return 1
  hang_wait "! kill -0 $p 2>/dev/null"
}
# Every held scanner this suite started, ended whatever state a failed case left it in, so none
# outlives the suite (L235). Called at the end and from the exit trap.
HELD_PIDS="$TMPROOT/held-pids"
note_held(){ cat "$TMPROOT/$1.pid" >> "$HELD_PIDS" 2>/dev/null; }
reap_held(){
  local p
  [ -f "$HELD_PIDS" ] || return 0
  for p in $(cat "$HELD_PIDS" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  return 0
}
trap 'reap_held; rm -rf "$TMPROOT"' EXIT
BUDGETSTATE="$TMPROOT/budget-state"
budgetfire(){ SCANNERS_STATE_DIR="$BUDGETSTATE" SCANNERS_BUDGET_SECONDS=2 fire "$@"; }

R1881="$(mkrepo outoftime)"; HOLD1881="$TMPROOT/hold-1881"; : > "$HOLD1881"
add_scanner "$R1881" alpha 0; add_held_scanner "$R1881" omega "$HOLD1881" 0; commit_all "$R1881"
_t0="$(date +%s)"
o1881="$(budgetfire "$R1881" "git push")"; c1881=$?
_took=$(( $(date +%s) - _t0 ))
note_held omega
[ "$c1881" -eq 2 ] && check "#1881 a scanner still running when the gate's budget runs out blocks the push" ok \
  || check "#1881 a scanner still running when the gate's budget runs out blocks the push" "exit=$c1881 out=$o1881"
grep -q 'did not finish in 2 seconds' <<< "$o1881" \
  && check "#1881 and says the scanners ran out of time, with the budget" ok \
  || check "#1881 and says the scanners ran out of time, with the budget" "out=$o1881"
grep -q 'test-omega.sh' <<< "$o1881" && ! grep -q 'payload/hooks/test-alpha.sh' <<< "$o1881" \
  && check "#1881 and names the scanner that did not finish, not the one that passed" ok \
  || check "#1881 and names the scanner that did not finish, not the one that passed" "out=$o1881"
grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o1881" \
  && check "#1881 and does not call a scanner that never finished a failing one" "out=$o1881" \
  || check "#1881 and does not call a scanner that never finished a failing one" ok
grep -q 'still running in the background' <<< "$o1881" && grep -q 'push again once' <<< "$o1881" \
  && check "#1881 and says the scanner is still running in the background, and to push again once it finishes" ok \
  || check "#1881 and says the scanner is still running in the background, and to push again once it finishes" "out=$o1881"
# The file it names is where the scanner's own output went, read rather than believed (L1).
_outfile="$(awk '/output: / { sub(/^.*output: /, ""); print; exit }' <<< "$o1881")"
[ -n "$_outfile" ] && grep -q '^scanner omega started$' "$_outfile" 2>/dev/null \
  && check "#1881 and names the file the running scanner writes its output to" ok \
  || check "#1881 and names the file the running scanner writes its output to" "file=${_outfile:-none named} out=$o1881"
# The gate's whole output is read through a pipe, here a command substitution, which returns only
# when every process holding that pipe has closed it. The held scanner is still running and would
# hold it for up to 60 seconds, so returning in a few proves the left running scanner holds none of
# the hook's output (L235). 15 is a number set here, not measured.
[ "$_took" -lt 15 ] && check "#1881 and returns at its budget, the running scanner holding none of its output" ok \
  || check "#1881 and returns at its budget, the running scanner holding none of its output" "took ${_took}s"
_slowpid="$(cat "$TMPROOT/omega.pid" 2>/dev/null)"
_slowpg="$(ps -o pgid= -p "$_slowpid" 2>/dev/null | tr -d ' ')"
_mypg="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
if [ -z "$_slowpid" ]; then
  check "#1881 and the scanner it left is still running, in a process group of its own" "the held scanner never recorded its process id"
elif kill -0 "$_slowpid" 2>/dev/null && [ -n "$_slowpg" ] && [ "$_slowpg" != "$_mypg" ]; then
  check "#1881 and the scanner it left is still running, in a process group of its own" ok
else
  check "#1881 and the scanner it left is still running, in a process group of its own" "pid=$_slowpid alive=$(kill -0 "$_slowpid" 2>/dev/null && echo yes || echo no) its group=${_slowpg:-none} this suite's=$_mypg"
fi

# A second push while it is still running is refused again, and does NOT start a second copy.
o1881r="$(budgetfire "$R1881" "git push")"; c1881r=$?
[ "$c1881r" -eq 2 ] && grep -q 'still running in the background' <<< "$o1881r" \
  && check "#1881 a push while the scanner still runs is refused again" ok \
  || check "#1881 a push while the scanner still runs is refused again" "exit=$c1881r out=$o1881r"
[ "$(held_runs omega)" = "1" ] && check "#1881 and does not start a second copy of the running scanner" ok \
  || check "#1881 and does not start a second copy of the running scanner" "omega runs=$(held_runs omega)"

# Once it has finished and passed, a push of the same tree counts that pass and goes through,
# without running it again. Counted by the runs the scanner records, not by the gate's words (L1).
rm -f "$HOLD1881"
held_gone omega || check "#1881 the held scanner finished once released" "it is still running"
o1881b="$(budgetfire "$R1881" "git push")"; c1881b=$?
[ "$c1881b" -eq 0 ] && check "#1881 a push after the scanner finished and passed in the background goes through" ok \
  || check "#1881 a push after the scanner finished and passed in the background goes through" "exit=$c1881b out=$o1881b"
[ "$(held_runs omega)" = "1" ] && grep -q '1 more were skipped' <<< "$o1881b" \
  && check "#1881 and counts the background pass rather than running it again, and skips the one that passed in time" ok \
  || check "#1881 and counts the background pass rather than running it again, and skips the one that passed in time" "omega runs=$(held_runs omega) out=$o1881b"
# And the pass it counted is remembered like any other, so the next push skips both.
o1881b2="$(budgetfire "$R1881" "git push")"; c1881b2=$?
[ "$c1881b2" -eq 0 ] && grep -q 'All 2 whole tree scan(s) had already passed' <<< "$o1881b2" && [ "$(held_runs omega)" = "1" ] \
  && check "#1881 and the background pass is remembered for the push after" ok \
  || check "#1881 and the background pass is remembered for the push after" "exit=$c1881b2 omega runs=$(held_runs omega) out=$o1881b2"

# Two pushes of the same tree AT ONCE, assume it runs twice: each looks for a run, and only one may
# start one. Both are refused, since the scanner is held, and it has run once.
R1881k="$(mkrepo bgtwice)"; HOLD1881k="$TMPROOT/hold-1881k"; : > "$HOLD1881k"
add_held_scanner "$R1881k" kappa "$HOLD1881k" 0; commit_all "$R1881k"
( budgetfire "$R1881k" "git push" > "$TMPROOT/twice-1.out"; echo $? > "$TMPROOT/twice-1.rc" ) &
_tw1=$!
( budgetfire "$R1881k" "git push" > "$TMPROOT/twice-2.out"; echo $? > "$TMPROOT/twice-2.rc" ) &
_tw2=$!
wait "$_tw1" "$_tw2"
note_held kappa
# On a failure each push's own account of kappa is shown, so a second copy names the path that
# started it (no key, stopped, or left running) rather than only a count (L177).
[ "$(cat "$TMPROOT/twice-1.rc" 2>/dev/null)" = "2" ] && [ "$(cat "$TMPROOT/twice-2.rc" 2>/dev/null)" = "2" ] && [ "$(held_runs kappa)" = "1" ] \
  && check "#1881 two pushes of one tree at once start the scanner once" ok \
  || check "#1881 two pushes of one tree at once start the scanner once" "exits=$(cat "$TMPROOT/twice-1.rc" "$TMPROOT/twice-2.rc" 2>/dev/null | tr '\n' ',') kappa runs=$(held_runs kappa); push 1: $(grep -m1 -e 'test-kappa' -e 'were stopped' -e 'still running' "$TMPROOT/twice-1.out" 2>/dev/null); push 2: $(grep -m1 -e 'test-kappa' -e 'were stopped' -e 'still running' "$TMPROOT/twice-2.out" 2>/dev/null)"
rm -f "$HOLD1881k"

# A run seen in the instant its process is still becoming the run: on Linux a process inside execve
# shows an EMPTY command line for that instant, and the check that a recorded pid is really this
# run reads the command line. The first push started a run and published its pid; a second push
# looking in that instant judged it gone and started a second copy, which is how the case above
# failed on Linux CI on 2026-10-29 (run 40877048627) while passing on this Mac. A stand in for ps
# that shows no command line plays that instant on any system, so the second push is made to look
# in it every time. A run started moments ago is never a recycled process id, so it must be adopted.
FAKEPS="$TMPROOT/fakeps"; mkdir -p "$FAKEPS"
_realps="$(command -v ps)"
cat > "$FAKEPS/ps" <<EOF
#!/usr/bin/env bash
case " \$* " in *" command= "*) exit 0 ;; esac
exec "$_realps" "\$@"
EOF
chmod +x "$FAKEPS/ps"
R1881x="$(mkrepo bgexec)"; HOLD1881x="$TMPROOT/hold-1881x"; : > "$HOLD1881x"
add_held_scanner "$R1881x" chi "$HOLD1881x" 0; commit_all "$R1881x"
budgetfire "$R1881x" "git push" >/dev/null
note_held chi
o1881x="$(PATH="$FAKEPS:$PATH" budgetfire "$R1881x" "git push")"; c1881x=$?
note_held chi
[ "$c1881x" -eq 2 ] && [ "$(held_runs chi)" = "1" ] && grep -q 'still running in the background' <<< "$o1881x" \
  && check "#1881 a run whose command line cannot be read yet, started moments ago, is adopted rather than started twice" ok \
  || check "#1881 a run whose command line cannot be read yet, started moments ago, is adopted rather than started twice" "exit=$c1881x chi runs=$(held_runs chi) out=$o1881x"
rm -f "$HOLD1881x"

# The other direction: a run folder from long ago whose recorded process id now belongs to a
# stranger is NOT that run. It is neither adopted nor stopped: a new run is started and the
# stranger is left alone (L1011).
R1881y="$(mkrepo bgstranger)"; HOLD1881y="$TMPROOT/hold-1881y"; : > "$HOLD1881y"
add_held_scanner "$R1881y" upsilon "$HOLD1881y" 0; commit_all "$R1881y"
o1881y="$(budgetfire "$R1881y" "git push")"
note_held upsilon
_ydir="$(awk '/output: / { sub(/^.*output: /, ""); sub(/\/out$/, ""); print; exit }' <<< "$o1881y")"
# The run's whole process group, so the process that records its exit code dies with the scanner
# and cannot write one after the folder is set up below.
_yleader="$(cat "$_ydir/pid" 2>/dev/null)"
[ -n "$_yleader" ] && kill -9 -- "-$_yleader" 2>/dev/null
held_gone upsilon
hang_wait "! kill -0 ${_yleader:-0} 2>/dev/null"
# A stranger in a process group of its own, as a recycled id that is a group leader would be.
# Started by a subshell that ends at once and writes nowhere, its pid recorded, so it is never this
# suite's child: its thirty seconds running out while a check was printing would cut the line short
# on bash 3.2 (L1035, #2040). It is nobody's here, which is what a stranger is.
( perl -e 'setpgrp(0, 0); exec "sleep", "30"' </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$TMPROOT/stranger.pid" ) </dev/null >/dev/null 2>&1
_stranger="$(cat "$TMPROOT/stranger.pid" 2>/dev/null)"
printf '%s' "$_stranger" > "$_ydir/pid"
rm -f "$_ydir/rc"
printf '%s\n' "$(( $(date +%s) - 3600 ))" > "$_ydir/started"
o1881y2="$(budgetfire "$R1881y" "git push")"; c1881y2=$?
note_held upsilon
if [ -z "$_ydir" ]; then
  check "#1881 an old run folder whose process id now belongs to a stranger is not adopted, and the stranger is left alone" "the first push named no output file: $o1881y"
elif kill -0 "$_stranger" 2>/dev/null && [ "$(held_runs upsilon)" = "2" ] && [ "$c1881y2" -eq 2 ]; then
  check "#1881 an old run folder whose process id now belongs to a stranger is not adopted, and the stranger is left alone" ok
else
  check "#1881 an old run folder whose process id now belongs to a stranger is not adopted, and the stranger is left alone" "stranger alive=$(kill -0 "$_stranger" 2>/dev/null && echo yes || echo no) upsilon runs=$(held_runs upsilon) exit=$c1881y2"
fi
kill -9 "$_stranger" 2>/dev/null
rm -f "$HOLD1881y"

# --- the lock itself, lib/pid-lock.sh, which this gate and claude-sync share (PR #1897). Each
#     check runs it in a process of its own, so its pid file is that process's. A lock left by a
#     holder that has died is taken over; one whose holder is alive is not, and the wait gives up at
#     its deadline rather than going ahead.
PLDIR="$TMPROOT/pidlock"; mkdir -p "$PLDIR"
perl -e 'exit 0' & _deadpid=$!; wait "$_deadpid"
printf '%s\n' "$_deadpid" > "$PLDIR/dead.lock"
bash -c '. "$1/lib/pid-lock.sh" && take_pid_lock "$2" 3' _ "$DIR" "$PLDIR/dead.lock"; _plrc=$?
[ "$_plrc" -eq 0 ] && [ "$(cat "$PLDIR/dead.lock" 2>/dev/null)" != "$_deadpid" ] && [ ! -e "$PLDIR/dead.lock.break" ] \
  && check "#1897 pid-lock.sh takes over a lock whose holder has died" ok \
  || check "#1897 pid-lock.sh takes over a lock whose holder has died" "rc=$_plrc lock holds $(cat "$PLDIR/dead.lock" 2>/dev/null)"
printf '%s\n' "$$" > "$PLDIR/live.lock"
_t0="$(date +%s)"
bash -c '. "$1/lib/pid-lock.sh" && take_pid_lock "$2" 1' _ "$DIR" "$PLDIR/live.lock"; _plrc=$?
_took=$(( $(date +%s) - _t0 ))
[ "$_plrc" -eq 1 ] && [ "$(cat "$PLDIR/live.lock" 2>/dev/null)" = "$$" ] && [ "$_took" -lt 15 ] \
  && check "#1897 pid-lock.sh leaves a live holder's lock alone and gives up at its deadline" ok \
  || check "#1897 pid-lock.sh leaves a live holder's lock alone and gives up at its deadline" "rc=$_plrc took ${_took}s lock holds $(cat "$PLDIR/live.lock" 2>/dev/null)"

# A run left in the background that FAILS is reported as a failure by the next push, from its own
# result, and is not run again to find that out. The push after that runs it afresh, because only a
# pass is ever remembered.
R1881f="$(mkrepo bgfail)"; HOLD1881f="$TMPROOT/hold-1881f"; : > "$HOLD1881f"
add_held_scanner "$R1881f" sigma "$HOLD1881f" 1; commit_all "$R1881f"
o1881f="$(budgetfire "$R1881f" "git push")"; c1881f=$?
note_held sigma
rm -f "$HOLD1881f"
held_gone sigma || check "#1881 the failing held scanner finished once released" "it is still running"
o1881f2="$(budgetfire "$R1881f" "git push")"; c1881f2=$?
[ "$c1881f" -eq 2 ] && [ "$c1881f2" -eq 2 ] && grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o1881f2" \
  && grep -q 'test-sigma.sh' <<< "$o1881f2" && grep -q 'scanner sigma finished' <<< "$o1881f2" && [ "$(held_runs sigma)" = "1" ] \
  && check "#1881 a scanner that failed in the background is reported as failing, from its own run" ok \
  || check "#1881 a scanner that failed in the background is reported as failing, from its own run" "exits=$c1881f,$c1881f2 sigma runs=$(held_runs sigma) out=$o1881f2"
o1881f3="$(budgetfire "$R1881f" "git push")"; c1881f3=$?
[ "$c1881f3" -eq 2 ] && [ "$(held_runs sigma)" = "2" ] \
  && check "#1881 and the push after that runs it afresh, since a failure is never remembered" ok \
  || check "#1881 and the push after that runs it afresh, since a failure is never remembered" "exit=$c1881f3 sigma runs=$(held_runs sigma) out=$o1881f3"

# A pass made in the background and read by a push in which ANOTHER scanner failed is not
# remembered, by the gate's standing rule that a blocked push lets no sibling be skipped (#1146),
# so the push after that runs it again. Pinned here so that rule is a decision, not a side effect.
R1881s="$(mkrepo bgsibling)"; HOLD1881s="$TMPROOT/hold-1881s"; : > "$HOLD1881s"
add_scanner "$R1881s" gamma 1; add_held_scanner "$R1881s" rho "$HOLD1881s" 0; commit_all "$R1881s"
budgetfire "$R1881s" "git push" >/dev/null
note_held rho
rm -f "$HOLD1881s"
held_gone rho || check "#1881 the sibling case's held scanner finished once released" "it is still running"
o1881s2="$(budgetfire "$R1881s" "git push")"; c1881s2=$?
_rho_after_read="$(held_runs rho)"
o1881s3="$(budgetfire "$R1881s" "git push")"; c1881s3=$?
[ "$c1881s2" -eq 2 ] && [ "$c1881s3" -eq 2 ] && [ "$_rho_after_read" = "1" ] && [ "$(held_runs rho)" = "2" ] \
  && check "#1881 a background pass read beside a failing scanner is not remembered, so the next push runs it again" ok \
  || check "#1881 a background pass read beside a failing scanner is not remembered, so the next push runs it again" "exits=$c1881s2,$c1881s3 rho runs=$_rho_after_read then $(held_runs rho)"

# A run left in the background for a tree the checkout has since moved past is stopped, and a new
# one started for the tree now being pushed: its verdict would be about files this push does not
# carry.
R1881t="$(mkrepo bgtree)"; HOLD1881t="$TMPROOT/hold-1881t"; : > "$HOLD1881t"
add_held_scanner "$R1881t" tau "$HOLD1881t" 0; commit_all "$R1881t"
o1881t="$(budgetfire "$R1881t" "git push")"; c1881t=$?
note_held tau
_taupid1="$(cat "$TMPROOT/tau.pid" 2>/dev/null)"
echo "a change" > "$R1881t/changed.txt"; commit_all "$R1881t"
o1881t2="$(budgetfire "$R1881t" "git push")"; c1881t2=$?
note_held tau
_taupid2="$(cat "$TMPROOT/tau.pid" 2>/dev/null)"
if [ -n "$_taupid1" ] && kill -0 "$_taupid1" 2>/dev/null; then
  check "#1881 a changed tree stops the run left for the old one" "the old run $_taupid1 is still alive"
else
  check "#1881 a changed tree stops the run left for the old one" ok
fi
[ "$c1881t2" -eq 2 ] && [ "$(held_runs tau)" = "2" ] && [ -n "$_taupid2" ] && [ "$_taupid2" != "$_taupid1" ] \
  && kill -0 "$_taupid2" 2>/dev/null && grep -q 'still running in the background' <<< "$o1881t2" \
  && check "#1881 and starts one for the new tree, refusing until it finishes" ok \
  || check "#1881 and starts one for the new tree, refusing until it finishes" "exit=$c1881t2 tau runs=$(held_runs tau) pids=$_taupid1,$_taupid2 out=$o1881t2"
rm -f "$HOLD1881t"

# A scanner that finished and FAILED inside the budget is still reported as failing, with the one
# that ran out of time named beside it, since a finding outranks a missing verdict.
R1881c="$(mkrepo outoftimefail)"; HOLD1881c="$TMPROOT/hold-1881c"; : > "$HOLD1881c"
add_scanner "$R1881c" gamma 1; add_held_scanner "$R1881c" psi "$HOLD1881c" 0; commit_all "$R1881c"
o1881c="$(budgetfire "$R1881c" "git push")"; c1881c=$?
note_held psi; rm -f "$HOLD1881c"
[ "$c1881c" -eq 2 ] && grep -q 'a scanner that reads the WHOLE repository fails' <<< "$o1881c" \
  && grep -q 'test-gamma.sh' <<< "$o1881c" && grep -q 'test-psi.sh' <<< "$o1881c" \
  && grep -q 'did not finish in 2 seconds' <<< "$o1881c" \
  && check "#1881 a failure inside the budget is reported as one, with the scanner that ran out of time named too" ok \
  || check "#1881 a failure inside the budget is reported as one, with the scanner that ran out of time named too" "exit=$c1881c out=$o1881c"

# The same budget with scanners that are fast lets the push through: the budget is not a refusal
# of every push (the control for the cases above).
R1881d="$(mkrepo intime)"; add_scanner "$R1881d" alpha 0; add_scanner "$R1881d" beta 0; commit_all "$R1881d"
o1881d="$(budgetfire "$R1881d" "git push")"; c1881d=$?
[ "$c1881d" -eq 0 ] && check "#1881 fast scanners inside the same budget let the push through" ok \
  || check "#1881 fast scanners inside the same budget let the push through" "exit=$c1881d out=$o1881d"

# A budget that is not a whole number of seconds is refused as unreadable and the default used,
# never read as zero, which would refuse every push, or as no budget, which would be the defect.
R1881e="$(mkrepo badbudget)"; add_scanner "$R1881e" alpha 0; commit_all "$R1881e"
o1881e="$(SCANNERS_STATE_DIR="$BUDGETSTATE" SCANNERS_BUDGET_SECONDS=soon fire "$R1881e" "git push")"; c1881e=$?
[ "$c1881e" -eq 0 ] && check "#1881 an unreadable budget falls back to the default rather than refusing every push" ok \
  || check "#1881 an unreadable budget falls back to the default rather than refusing every push" "exit=$c1881e out=$o1881e"

# The default budget must sit below the timeout the registration declares, or Claude Code kills the
# gate first and the push goes through unscanned, which is the defect. Both numbers are read from
# their files, so moving either one without the other fails here. The registration also asks Claude
# Code to BLOCK the call if the gate is killed anyway (onFailure, measured working on 2.1.312 the
# same day), so a gate that overruns its own budget still cannot let a push through.
_reg=""
. "$DIR/lib/settings-file.sh" 2>/dev/null && _reg="$(hook_settings_file "$DIR/..")"
if [ -n "$_reg" ] && command -v jq >/dev/null 2>&1; then
  _declared="$(jq -r '[.hooks.PreToolUse[].hooks[] | select(.command | endswith("/scanners-before-push.sh"))][0].timeout // empty' "$_reg")"
  _onfail="$(jq -r '[.hooks.PreToolUse[].hooks[] | select(.command | endswith("/scanners-before-push.sh"))][0].onFailure // empty' "$_reg")"
  _default="$(sed -n 's/^_sc_budget_default=\([0-9][0-9]*\)$/\1/p' "$H")"
  if [ -n "$_declared" ] && [ -n "$_default" ] && [ "$_default" -lt "$_declared" ]; then
    check "#1881 the default budget sits below the declared hook timeout" ok
  else
    check "#1881 the default budget sits below the declared hook timeout" "budget=${_default:-unread} timeout=${_declared:-unread}"
  fi
  [ "$_onfail" = "block" ] && check "#1881 the registration blocks the push if the gate is killed anyway" ok \
    || check "#1881 the registration blocks the push if the gate is killed anyway" "onFailure=${_onfail:-absent}"
else
  # No hooks block beside this copy of the hooks, or no jq to read it, so this is said out loud rather
  # than skipped in silence (L98).
  echo "  (no readable hooks block beside this suite, or no jq, so the budget against the declared timeout was not checked here)"
fi

# --- the gate's watchdog is gone when its scanners finish, even when it could not act on a plain
#     kill (claude-config#1889). The watchdog is started in the background and, on a push whose
#     scanners finish in time, stopped straight after. A plain kill sent before the background job
#     has finished starting is caught by the handler the gate's EXIT trap installs, and is lost when
#     the job becomes perl (L240). Measured 2026-10-29 with a bare loop of that shape: 1 in 40
#     starts under the Mac's bash 3.2 and 2 in 80 under bash 5.3 outlived the kill. On Linux CI two
#     runs of this suite were cancelled with a gate and its watchdog both still alive and all of
#     that gate's scanners gone, which is the state this race leaves: the gate waits for the
#     watchdog to sleep out the whole budget, so the push takes its full budget and still passes.
#
#     A race cannot be hit on demand, so the case below makes the plain kill fail EVERY time: the
#     gate runs with the termination signal ignored, which its watchdog inherits. Only a kill that
#     cannot be caught or ignored ends it, so the gate must return in about a second rather than at
#     its budget, and a gate that relies on the plain kill is stopped by the call deadline instead.
R1889="$(mkrepo watchdogkill)"; add_scanner "$R1889" alpha 0; commit_all "$R1889"
_t0="$(date +%s)"
o1889="$( trap '' TERM
          SCANNERS_STATE_DIR="$TMPROOT/watchdog-state" SCANNERS_BUDGET_SECONDS=100 FIRE_DEADLINE=20 \
            fire "$R1889" "git push")"; c1889=$?
_took=$(( $(date +%s) - _t0 ))
# Well under the call deadline of 20, which is itself well under the budget of 100: a gate that
# waited for its watchdog is cut off at 20 and exits 124.
[ "$c1889" -eq 0 ] && [ "$_took" -lt 15 ] \
  && check "#1889 the gate stops its watchdog with a kill that cannot be lost, and returns at once" ok \
  || check "#1889 the gate stops its watchdog with a kill that cannot be lost, and returns at once" "exit=$c1889 took ${_took}s out=$o1889"

# --- the call deadline itself, seen to fire (L1). A stand in for the gate ignores the termination
#     signal and waits on a child of its own, which is the shape of a hang the deadline exists for.
#     It must come back at the deadline with exit 124 and the line that names it, and leave
#     neither the stand in nor its child running. Its record goes to a log of its own, so the
#     check at the end, which reads the real log, is not tripped by this deliberate hang.
HANGHOOKS="$TMPROOT/hanghooks"; mkdir -p "$HANGHOOKS"
cat > "$HANGHOOKS/scanners-before-push.sh" <<EOF
#!/usr/bin/env bash
trap '' TERM
echo \$\$ > "$TMPROOT/hang.pid"
sleep 30 &
echo \$! > "$TMPROOT/hang-child.pid"
wait
EOF
chmod +x "$HANGHOOKS/scanners-before-push.sh"
_t0="$(date +%s)"
oHang="$(H="$HANGHOOKS/scanners-before-push.sh" FIRE_DEADLINE=2 FIRE_DEADLINE_LOG="$TMPROOT/selftest-deadlines" \
         fire "$R1889" "git push")"; cHang=$?
_took=$(( $(date +%s) - _t0 ))
[ "$cHang" -eq 124 ] && grep -q 'FIRE-DEADLINE: the gate did not return within 2 seconds' <<< "$oHang" && [ "$_took" -lt 15 ] \
  && check "#1889 a gate call that hangs is stopped at its own deadline and says so" ok \
  || check "#1889 a gate call that hangs is stopped at its own deadline and says so" "exit=$cHang took ${_took}s out=$oHang"
grep -q '^watchdogkill: git push$' "$TMPROOT/selftest-deadlines" 2>/dev/null \
  && check "#1889 and the call is recorded by fixture and command, for the check at the end" ok \
  || check "#1889 and the call is recorded by fixture and command, for the check at the end" "log=$(cat "$TMPROOT/selftest-deadlines" 2>/dev/null)"
_hangpid="$(cat "$TMPROOT/hang.pid" 2>/dev/null)"; _hangchild="$(cat "$TMPROOT/hang-child.pid" 2>/dev/null)"
if [ -z "$_hangpid" ] || [ -z "$_hangchild" ]; then
  check "#1889 and nothing the hung call started is still running" "the stand in never recorded its process ids"
elif kill -0 "$_hangpid" 2>/dev/null || kill -0 "$_hangchild" 2>/dev/null; then
  check "#1889 and nothing the hung call started is still running" "still alive: stand in $_hangpid or its child $_hangchild"
  kill -9 "$_hangpid" "$_hangchild" 2>/dev/null
else
  check "#1889 and nothing the hung call started is still running" ok
fi

# How the gate names a repository in its state folder: its origin, or its path when it has none. The
# fixtures below that are given an origin are given their own path as one, so this names them too.
fx_key(){ printf '%s' "$(cd "$1" && pwd -P)" | shasum -a 256 | awk '{print $1}'; }

# --- the record of passes is kept PER TREE and MERGED, never rewritten whole (claude-config#1910).
#     It was one file per repository origin, rewritten on every push, so two worktrees of one
#     repository pushing in turn erased each other's passes and each ran again scans that had
#     already passed on its own tree. Worktrees share their origin, so each fixture here is given
#     one, and its second checkout is a real `git worktree` of it. Counted by the runs a scanner
#     records, never by the gate's words (L1).
TREESTATE="$TMPROOT/tree-state"
treefire(){ SCANNERS_STATE_DIR="$TREESTATE" fire "$@"; }
add_counting_scanner(){  # $1 = repo  $2 = name  $3 = the file each run appends a line to
  cat > "$1/payload/hooks/test-$2.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
echo ran >> "$3"
exit 0
EOF
  chmod +x "$1/payload/hooks/test-$2.sh"
}
counted(){ grep -c . "$1" 2>/dev/null || true; }
# Two worktrees on DIFFERENT trees, pushing in turn: each keeps its own passes.
R1910="$(mkrepo pertree)"; RAN1910="$TMPROOT/pertree-ran"
add_counting_scanner "$R1910" lambda "$RAN1910"; commit_all "$R1910"
git -C "$R1910" remote add origin "$(cd "$R1910" && pwd -P)"
W1910="$TMPROOT/pertree-wt"
git -C "$R1910" worktree add -q -b other "$W1910" >/dev/null 2>&1
echo "other" > "$W1910/other.txt"; commit_all "$W1910"
treefire "$R1910" "git push" >/dev/null
treefire "$W1910" "git push" >/dev/null
o1910="$(treefire "$R1910" "git push")"; c1910=$?
o1910w="$(treefire "$W1910" "git push")"; c1910w=$?
[ "$c1910" -eq 0 ] && [ "$c1910w" -eq 0 ] && [ "$(counted "$RAN1910")" = "2" ] \
  && grep -q 'had already passed' <<< "$o1910" && grep -q 'had already passed' <<< "$o1910w" \
  && check "#1910 two worktrees pushing different trees in turn keep each other's passes" ok \
  || check "#1910 two worktrees pushing different trees in turn keep each other's passes" "exits=$c1910,$c1910w lambda runs=$(counted "$RAN1910") out=$o1910"
# Two checkouts of the SAME tree with different uncommitted files share the tree's record, so the
# second's pass must be merged into it, not written over the first's.
R1910m="$(mkrepo pertreemerge)"; RAN1910m="$TMPROOT/pertreemerge-ran"
add_counting_scanner "$R1910m" mu "$RAN1910m"; commit_all "$R1910m"
git -C "$R1910m" remote add origin "$(cd "$R1910m" && pwd -P)"
W1910m="$TMPROOT/pertreemerge-wt"
git -C "$R1910m" worktree add -q --detach "$W1910m" HEAD >/dev/null 2>&1
echo "a" > "$R1910m/draft-a.txt"; echo "b" > "$W1910m/draft-b.txt"
treefire "$R1910m" "git push" >/dev/null
treefire "$W1910m" "git push" >/dev/null
o1910m="$(treefire "$R1910m" "git push")"; c1910m=$?
[ "$c1910m" -eq 0 ] && [ "$(counted "$RAN1910m")" = "2" ] && grep -q 'had already passed' <<< "$o1910m" \
  && check "#1910 a pass on one tree is merged into its record, beside another checkout's pass on it" ok \
  || check "#1910 a pass on one tree is merged into its record, beside another checkout's pass on it" "exit=$c1910m mu runs=$(counted "$RAN1910m") record: $(cat "$TREESTATE/$(fx_key "$R1910m")"/*.txt 2>/dev/null | tr '\n' ';')"
# The merge is made under the record's lock, so a writer at the same moment cannot lose a pass
# (L5). Seen here by holding that lock with a live process, this suite's own: the gate must not
# write the record past it, and must say the pass was not remembered rather than claim it was. It
# waits out the deadline the gate sets on that lock, not a measurement, which is the only wait here.
R1910l="$(mkrepo recordlock)"; RAN1910l="$TMPROOT/recordlock-ran"
add_counting_scanner "$R1910l" nu "$RAN1910l"; commit_all "$R1910l"
LOCK1910="$TMPROOT/recordlock-state"
_rec1910="$LOCK1910/$(fx_key "$R1910l")"; mkdir -p "$_rec1910"
printf '%s\n' "$$" > "$_rec1910/pidlock"
# Said where the person sees it (#1931): this push goes through, so the line is part of the
# systemMessage, and stdout alone is read. On stderr, which Claude Code discards on exit 0, it reached
# nobody.
fire_stdout "$R1910l" "git push" "SCANNERS_STATE_DIR=$LOCK1910"
why1910l="$(hook_notice_verdict "$FS_OUT" 'The scanners that passed were not remembered, because another push held its lock')"
[ "$FS_RC" -eq 0 ] && [ -z "$(cat "$_rec1910"/*.txt 2>/dev/null)" ] && [ -z "$why1910l" ] \
  && check "#1910 the record is written only under its lock, and a pass that could not be written is said, as a systemMessage (#1931)" ok \
  || check "#1910 the record is written only under its lock, and a pass that could not be written is said, as a systemMessage (#1931)" "exit=$FS_RC record: $(cat "$_rec1910"/*.txt 2>/dev/null | tr '\n' ';') $why1910l"
rm -f "$_rec1910/pidlock"
# Once the lock is free the pass is written, and the push after that skips it.
SCANNERS_STATE_DIR="$LOCK1910" fire "$R1910l" "git push" >/dev/null
o1910l3="$(SCANNERS_STATE_DIR="$LOCK1910" fire "$R1910l" "git push")"; c1910l3=$?
[ "$c1910l3" -eq 0 ] && [ "$(counted "$RAN1910l")" = "2" ] && grep -q 'had already passed' <<< "$o1910l3" \
  && check "#1910 and once the lock is free the pass is remembered" ok \
  || check "#1910 and once the lock is free the pass is remembered" "exit=$c1910l3 nu runs=$(counted "$RAN1910l") out=$o1910l3"
# Records do not pile up: one for a tree nobody has pushed in a day is removed by the next write,
# and so is the one file per repository the gate kept before, which nothing reads any more. The age
# is set on the file rather than waited for (L290).
_old1910="$TREESTATE/$(fx_key "$R1910")/0000000000000000000000000000000000000000.txt"
printf 'old line\n' > "$_old1910"; touch -t 202001010000 "$_old1910"
printf 'old layout\n' > "$TREESTATE/$(fx_key "$R1910").txt"
echo "again" > "$W1910/again.txt"; commit_all "$W1910"
treefire "$W1910" "git push" >/dev/null
[ ! -e "$_old1910" ] && [ ! -e "$TREESTATE/$(fx_key "$R1910").txt" ] \
  && [ -s "$TREESTATE/$(fx_key "$R1910")/$(git -C "$R1910" rev-parse 'HEAD^{tree}').txt" ] \
  && check "#1910 a record left a day ago, and the old single record, are removed; a recent one is kept" ok \
  || check "#1910 a record left a day ago, and the old single record, are removed; a recent one is kept" "left: $(ls "$TREESTATE" "$TREESTATE/$(fx_key "$R1910")" 2>/dev/null | tr '\n' ' ')"

# --- the key covers every file the scanners read, a TRACKED file edited and not committed included
#     (claude-config#1910). It was the commit tree plus the staged and untracked files only, while
#     the scanners read tracked files from disk, so a pass reached before such an edit let the next
#     push skip scanning the edited file. Each step is judged by the runs the scanner records.
R1910e="$(mkrepo trackededit)"; RAN1910e="$TMPROOT/trackededit-ran"
add_counting_scanner "$R1910e" xi "$RAN1910e"; printf 'one\n' > "$R1910e/tracked.sh"; commit_all "$R1910e"
treefire "$R1910e" "git push" >/dev/null
treefire "$R1910e" "git push" >/dev/null
_xi_control="$(counted "$RAN1910e")"
printf 'two\n' > "$R1910e/tracked.sh"
o1910e="$(treefire "$R1910e" "git push")"; c1910e=$?
_xi_edited="$(counted "$RAN1910e")"
treefire "$R1910e" "git push" >/dev/null
_xi_again="$(counted "$RAN1910e")"
[ "$_xi_control" = "1" ] && [ "$c1910e" -eq 0 ] && [ "$_xi_edited" = "2" ] && [ "$_xi_again" = "2" ] \
  && check "#1910 a tracked file edited after a pass makes the next push scan again, and that pass is then kept" ok \
  || check "#1910 a tracked file edited after a pass makes the next push scan again, and that pass is then kept" "xi runs: unchanged=$_xi_control edited=$_xi_edited again=$_xi_again exit=$c1910e out=$o1910e"
# Put back as it was committed, it is exactly what passed first, so nothing runs; deleted, it is not,
# since the scanners no longer read it.
printf 'one\n' > "$R1910e/tracked.sh"
treefire "$R1910e" "git push" >/dev/null
_xi_back="$(counted "$RAN1910e")"
rm -f "$R1910e/tracked.sh"
treefire "$R1910e" "git push" >/dev/null
[ "$_xi_back" = "2" ] && [ "$(counted "$RAN1910e")" = "3" ] \
  && check "#1910 the key follows what is on disk: put back it skips, deleted it scans" ok \
  || check "#1910 the key follows what is on disk: put back it skips, deleted it scans" "xi runs: put back=$_xi_back deleted=$(counted "$RAN1910e")"

# --- when a run cannot be left running, a scanner still running at the budget is STOPPED, and the
#     refusal says why, in words naming the cause (claude-config#1910, L11). With no key, left
#     running, its verdict could never be matched to what a later push carries, so it would be load with no
#     reader; stopped without a word, the slow scanner is refused on every retry and nobody is told
#     a retry cannot help. Each cause is played by a copy of the gate missing exactly one thing it
#     needs, and every library it loads is copied in otherwise: a copy missing a second one, as
#     happened when #1928 added lib/recorded-pid.sh to what the gate loads, names that cause instead.
#     So each case also checks that the refusal names none of the OTHER causes.
nokey_hooks(){   # $1 = folder  $2 = the one thing missing: listing (the listings of what is not committed fail), pidlock or recorded (that lock library is absent), or state (nothing; the state folder is made bad by the caller)
  mkdir -p "$1/lib"
  cp "$H" "$1/scanners-before-push.sh"
  cp "$DIR/lib/push-scope.sh" "$DIR/lib/load-average.sh" "$DIR/lib/whole-number.sh" "$DIR/lib/work-names-messages.sh" "$DIR/lib/work-names.py" "$DIR/lib/dev-update-registry.js" "$1/lib/"
  [ "$2" = pidlock ] || cp "$DIR/lib/pid-lock.sh" "$1/lib/"
  [ "$2" = recorded ] || cp "$DIR/lib/recorded-pid.sh" "$1/lib/"
  if [ "$2" = listing ]; then
    cat > "$1/lib/repo-files.sh" <<EOF
#!/usr/bin/env bash
case "\$1" in --uncommitted|--changed) echo "repo-files: git could not list the files under \$2 that are not committed." >&2; exit 1 ;; esac
exec bash "$DIR/lib/repo-files.sh" "\$@"
EOF
  else
    cp "$DIR/lib/repo-files.sh" "$1/lib/"
  fi
}
# What the refusal says for each cause, and so must not say for any other.
NOKEY_MARKS="repo-files.sh --changed
lib/pid-lock.sh could not be loaded
lib/recorded-pid.sh could not be loaded
could not be made"
nokey_case(){    # $1 = name  $2 = cause  $3 = what the refusal must name  [$4 = a state folder, whose runs folder it must name too]
  local hooks="$TMPROOT/nokey-$1-hooks" repo hold out rc pid mark others=""
  nokey_hooks "$hooks" "$2"
  repo="$(mkrepo "nokey$1")"; hold="$TMPROOT/hold-nokey-$1"; : > "$hold"
  add_held_scanner "$repo" "nk$1" "$hold" 0; commit_all "$repo"
  out="$(H="$hooks/scanners-before-push.sh" SCANNERS_STATE_DIR="${4:-$TMPROOT/nokey-$1-state}" SCANNERS_BUDGET_SECONDS=2 \
         fire "$repo" "git push")"; rc=$?
  note_held "nk$1"
  pid="$(cat "$TMPROOT/nk$1.pid" 2>/dev/null)"
  while IFS= read -r mark; do
    case "$3" in *"$mark"*) continue ;; esac
    grep -q -F "$mark" <<< "$out" && others="$others [$mark]"
  done <<< "$NOKEY_MARKS"
  if [ "$rc" -eq 2 ] && [ -n "$pid" ] && hang_wait "! kill -0 $pid 2>/dev/null" \
     && grep -q 'stopped rather than left running' <<< "$out" && grep -q -F "$3" <<< "$out" \
     && grep -q 'a retry stops them' <<< "$out" && [ -z "$others" ] \
     && { [ -z "${4:-}" ] || grep -q -F "$4/runs/" <<< "$out"; }; then
    check "#1910 when a run cannot be left running ($2), it is stopped at the budget and the refusal says why, naming $3 and no other cause" ok
  else
    check "#1910 when a run cannot be left running ($2), it is stopped at the budget and the refusal says why, naming $3 and no other cause" "exit=$rc pid=${pid:-none} other causes named:${others:- none} out=$out"
  fi
  rm -f "$hold"
}
nokey_case listing listing 'repo-files.sh --changed'
nokey_case pidlock pidlock 'lib/pid-lock.sh could not be loaded'
nokey_case recorded recorded 'lib/recorded-pid.sh could not be loaded'
# The state folder is a path under a FILE, so it can never be made. The message names the runs
# folder inside it and says it could not be made.
: > "$TMPROOT/nokey-notafolder"
nokey_case state state 'could not be made' "$TMPROOT/nokey-notafolder/state"

# --- the messages of the commits a push adds name no work organisation (claude-config#1995). This
#     repository squash merges with the commit messages as the body, so a message naming one lands
#     in main without ever being a file the whole tree scan reads. The gate runs the same scanner,
#     lib/work-names.py, over the messages of exactly the commits the push adds: never one already
#     on the remote's default branch or already pushed to the branch's upstream. The organisation is
#     an invented one, handed to the scanner by hash; the registry reader is a stub, so what this
#     Mac's own registry holds cannot decide a case.
WN_HASH="$(printf '%s' "acme-hq" | shasum -a 256 | cut -d' ' -f1)"
WN_READER="$TMPROOT/wn-registry-missing.js"
printf 'console.log(JSON.stringify({state: "missing", file: "/nowhere/repos.local.json"}))\n' > "$WN_READER"
WN_BROKEN="$TMPROOT/wn-registry-broken.js"
printf 'console.log("not json")\n' > "$WN_BROKEN"
wn_fire(){           # $1 = repo  $2 = command  [$3 = registry reader] -> output, the gate's exit code
  ( export WORK_NAMES_EXTRA_HASHES="$WN_HASH" WORK_NAMES_REGISTRY_READER="${3:-$WN_READER}"; fire "$1" "$2" )
}
wn_commit(){ git -C "$1" commit -q --allow-empty -m "$2" >/dev/null 2>&1; }
# A repository with a remote whose main holds one commit naming the organisation, already published,
# and a branch cut from it with no upstream yet.
WNB="$TMPROOT/wn-remote.git"; git init -q --bare "$WNB"
RW="$(mkrepo wnames)"; add_scanner "$RW" alpha 0; commit_all "$RW"
wn_commit "$RW" "Old history

quoted Acme-HQ/widget#1 before the scan existed"
git -C "$RW" branch -M main; git -C "$RW" remote add origin "$WNB"
git -C "$RW" push -q origin main >/dev/null 2>&1; git -C "$RW" fetch -q origin >/dev/null 2>&1
git -C "$RW" checkout -q -b feature
wn_commit "$RW" "Add the reader

refs widget#3"
out="$(wn_fire "$RW" "git push -u origin feature")"; rc=$?
[ "$rc" -eq 0 ] && check "#1995 (control) a branch whose new commits are clean is let through, the published one naming it is not judged" ok \
  || check "#1995 (control) a branch whose new commits are clean is let through, the published one naming it is not judged" "exit=$rc out=$out"
wn_commit "$RW" "Quote the refusal

it named acme-hq/widget#4 in the fixture"
named="$(git -C "$RW" rev-parse --short HEAD)"
out="$(wn_fire "$RW" "git push -u origin feature")"; rc=$?
[ "$rc" -eq 2 ] && grep -q -F "commit $named:3: a work organisation name" <<< "$out" \
  && check "#1995 a new commit whose message names a work organisation stops the push, naming the commit and line" ok \
  || check "#1995 a new commit whose message names a work organisation stops the push, naming the commit and line" "exit=$rc out=$out"
grep -q -F "write name#123, never owner/name#123" <<< "$out" \
  && check "#1995 and the refusal carries the file check's own remedy" ok \
  || check "#1995 and the refusal carries the file check's own remedy" "out=$out"
grep -q -F "git reset --soft" <<< "$out" \
  && check "#1995 and says how to reword a commit nobody has pushed" ok \
  || check "#1995 and says how to reword a commit nobody has pushed" "out=$out"
grep -q -i "acme-hq" <<< "$out" \
  && check "#1995 and never repeats the name" "out=$out" \
  || check "#1995 and never repeats the name" ok
grep -q "scanner alpha ran" <<< "$out" \
  && check "#1995 a refusal over a message comes before any scanner suite is spent" "out=$out" \
  || check "#1995 a refusal over a message comes before any scanner suite is spent" ok
# Once that commit is on the branch's upstream it has been pushed, and is not this gate's business.
git -C "$RW" push -q -u origin feature >/dev/null 2>&1
wn_commit "$RW" "Follow up

refs widget#5"
out="$(wn_fire "$RW" "git push")"; rc=$?
[ "$rc" -eq 0 ] && check "#1995 a commit already on the upstream is not judged again, only what the push adds" ok \
  || check "#1995 a commit already on the upstream is not judged again, only what the push adds" "exit=$rc out=$out"
# A repository with no remote at all: nothing is published, so every commit is one the push adds.
RN="$(mkrepo wnames-noremote)"; add_scanner "$RN" alpha 0; commit_all "$RN"
wn_commit "$RN" "First

from ACME-HQ/widget#6"
out="$(wn_fire "$RN" "git push")"; rc=$?
[ "$rc" -eq 2 ] && grep -q -F "commit $(git -C "$RN" rev-parse --short HEAD):3:" <<< "$out" \
  && check "#1995 with no remote to compare against, every commit is judged, never none" ok \
  || check "#1995 with no remote to compare against, every commit is judged, never none" "exit=$rc out=$out"
# A command that commits before it pushes: the message it is about to write is not in git yet, so it
# cannot be read, and that is said, never passed.
RC2="$(mkrepo wnames-chain)"; add_scanner "$RC2" alpha 0; commit_all "$RC2"
out="$(wn_fire "$RC2" "git commit -q --allow-empty -m next && git push")"; rc=$?
[ "$rc" -eq 2 ] && grep -q -F "not written yet" <<< "$out" \
  && check "#1995 a push chained after its commit is refused, saying the message could not be read yet" ok \
  || check "#1995 a push chained after its commit is refused, saying the message could not be read yet" "exit=$rc out=$out"
# A scanner that cannot judge (here, a registry it cannot read) is no clean push.
out="$(wn_fire "$RC2" "git push" "$WN_BROKEN")"; rc=$?
[ "$rc" -eq 2 ] && grep -q -F "could not judge" <<< "$out" \
  && check "#1995 messages the scanner could not judge stop the push, saying so" ok \
  || check "#1995 messages the scanner could not judge stop the push, saying so" "exit=$rc out=$out"
# A copy of the gate without the library that reads the messages is no push with clean messages.
WN_NOLIB="$TMPROOT/wn-nolib-hooks"; mkdir -p "$WN_NOLIB/lib"
cp "$H" "$WN_NOLIB/scanners-before-push.sh"; cp "$DIR/lib/push-scope.sh" "$DIR/lib/whole-number.sh" "$WN_NOLIB/lib/"
out="$(H="$WN_NOLIB/scanners-before-push.sh" wn_fire "$RC2" "git push")"; rc=$?
[ "$rc" -eq 2 ] && grep -q -F "wn-nolib-hooks/lib/work-names-messages.sh, which reads the messages" <<< "$out" \
  && check "#1995 a gate that cannot load the message reader refuses the push, naming the file" ok \
  || check "#1995 a gate that cannot load the message reader refuses the push, naming the file" "exit=$rc out=$out"

# --- no fixture reached the REAL pass cache (claude-config#789). The gate keys its record of passed
#     scans by the repository's origin, or its path when it has none, as the fixtures do, so a
#     fixture's record in the real folder would be a test result a later real push trusts (L2).
#     Judged by each fixture's OWN key, never by whether the folder changed, because other
#     sessions' real pushes write there during this run (L375).
#
#     The guard derives each fixture's record name itself, so it is first CALIBRATED against the
#     gate: one passing run into a private folder must leave a record under exactly that name, or
#     the guard below would look for names the gate never writes and pass whatever leaked (L1).
#     Since #1910 a repository's record is a folder, one file per tree.
RK="$(mkrepo keyprobe)"; add_scanner "$RK" alpha 0; commit_all "$RK"
PROBE_STATE="$TMPROOT/probe-state"
SCANNERS_STATE_DIR="$PROBE_STATE" fire "$RK" "git push" >/dev/null
[ -f "$PROBE_STATE/$(fx_key "$RK")/$(git -C "$RK" rev-parse 'HEAD^{tree}').txt" ] && check "the leak guard names records the way the gate writes them" ok \
  || check "the leak guard names records the way the gate writes them" "gate wrote: $(cd "$PROBE_STATE" 2>/dev/null && find . -type f | tr '\n' ' ')"
# ...and the FOLDER: run with no SCANNERS_STATE_DIR under a fake home, and the record must land
# where the guard below looks, relative to that home, or a change to the gate's default would
# leave the guard watching a folder nothing writes.
FAKEHOME="$TMPROOT/fakehome"; mkdir -p "$FAKEHOME"
RK2="$(mkrepo keyprobe2)"; add_scanner "$RK2" alpha 0; commit_all "$RK2"
( unset SCANNERS_STATE_DIR; HOME="$FAKEHOME" fire "$RK2" "git push" >/dev/null )
state_rel=".claude/state/scanners-passed"
[ -f "$FAKEHOME/$state_rel/$(fx_key "$RK2")/$(git -C "$RK2" rev-parse 'HEAD^{tree}').txt" ] && check "the leak guard watches the folder the gate writes to by default" ok \
  || check "the leak guard watches the folder the gate writes to by default" "gate wrote: $(cd "$FAKEHOME" && find . -type f | tr '\n' ' ')"
REAL_STATE="$HOME/$state_rel"
_leaked=""
for _fx in "$TMPROOT"/*/; do
  [ -e "$_fx/.git" ] || continue
  _fx_key="$(fx_key "$_fx")"
  # The folder a record is kept in since #1910, and the single file it was before, both looked for.
  [ -e "$REAL_STATE/$_fx_key.txt" ] && { _leaked="$_leaked $(basename "$_fx")"; rm -f "$REAL_STATE/$_fx_key.txt"; }
  [ -d "$REAL_STATE/$_fx_key" ] && { _leaked="$_leaked $(basename "$_fx")"; rm -rf "${REAL_STATE:?}/${_fx_key:?}"; }
done
[ -z "$_leaked" ] && check "no fixture wrote a pass record into the real state folder" ok \
  || check "no fixture wrote a pass record into the real state folder" "these did, and were removed:$_leaked"

# --- no gate call ran into its call deadline (claude-config#1889). Each one that did has already
#     failed its own exit code check; this names them together, by fixture and command, so a gate
#     that has started to hang is one line to read rather than a scatter of exit=124.
[ ! -s "$FIRE_DEADLINE_LOG" ] && check "no gate call ran past its ${FIRE_DEADLINE} second call deadline" ok \
  || check "no gate call ran past its ${FIRE_DEADLINE} second call deadline" "these were stopped there: $(tr '\n' ';' < "$FIRE_DEADLINE_LOG")"

reap_held
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
