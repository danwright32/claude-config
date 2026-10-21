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
fire(){              # $1 = repo  $2 = the command  -> prints the hook's output, exits with its code
  local out rc
  out="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$2" "$1" | bash "$H" 2>&1)"
  rc=$?
  printf '%s' "$out"
  return "$rc"
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
# a copy of the gate whose repo-files.sh refuses the uncommitted listing and nothing else.
FAKEHOOKS="$TMPROOT/fakehooks"; mkdir -p "$FAKEHOOKS/lib"
cp "$H" "$FAKEHOOKS/scanners-before-push.sh"; cp "$DIR/lib/push-scope.sh" "$FAKEHOOKS/lib/push-scope.sh"
cat > "$FAKEHOOKS/lib/repo-files.sh" <<EOF
#!/usr/bin/env bash
[ "\$1" = --uncommitted ] && { echo "repo-files: git could not list the uncommitted files under \$2." >&2; exit 1; }
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

# --- a scanner whose INPUTS have not changed since it passed is not run again (claude-config#531).
#     Measured 2026-09-21: the scanners are 15.3 of the 20.1 seconds a push waits, and they re-read
#     the whole repository on every push even when nothing they read has changed, which is most
#     pushes. Proved by a scanner that APPENDS a line every time it actually runs, so a skip is a
#     line that did not appear rather than a message that says one did not (L1).
SKIPSTATE="$TMPROOT/skip-state"
fire_skip(){ # $1 = repo  $2 = command
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$2" "$1" \
    | SCANNERS_STATE_DIR="$SKIPSTATE" bash "$H" 2>&1
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

# --- the selection against THIS repository, read rather than assumed. Fixtures can only confirm
#     the rule as written; what matters is which real suites it picks, and above all that it never
#     picks the four minute suite as a whole (measured 2026-09-21: the selection below runs in 27
#     seconds, where running that suite whole would be 268).
REAL="$(cd "$DIR/../.." && pwd)"
if [ -f "$REAL/payload/hooks/run-all-tests.sh" ]; then
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
  grep -q '^SECTION .*#145' <<< "$_sel" \
    && check "and the section that scans comments for undated numbers is selected" ok \
    || check "and the section that scans comments for undated numbers is selected" "got=$_sel"
  grep -q "^SUITE .*$(basename "$H")$" <<< "$_sel" \
    && check "and the suite that drives this gate is not one of its own subjects" "it selected itself: $_sel" \
    || check "and the suite that drives this gate is not one of its own subjects" ok
  grep -q '^SUITE tests/test-claude-sync.sh$' <<< "$_sel" \
    && check "and the four minute suite is never selected whole" "it would run whole: $_sel" \
    || check "and the four minute suite is never selected whole" ok
else
  # The INSTALLED copy of these hooks sits in ~/.claude, where there is no repository and never
  # will be, so there is no selection to read and that is not a fault. Said out loud rather than
  # skipped in silence, because a suite that quietly checks less is how coverage disappears (L98).
  echo "  (no repository at $REAL, so the selection against a real tree was not checked here; it is checked where this repo is)"
fi

# --- no fixture reached the REAL pass cache (claude-config#789). The gate keys its record of passed
#     scans by the repository's origin, or its path when it has none, as the fixtures do, so a
#     fixture's record in the real folder would be a test result a later real push trusts (L2).
#     Judged by each fixture's OWN key, never by whether the folder changed, because other
#     sessions' real pushes write there during this run (L375).
#
#     The guard derives each fixture's record name itself, so it is first CALIBRATED against the
#     gate: one passing run into a private folder must leave a record under exactly that name, or
#     the guard below would look for names the gate never writes and pass whatever leaked (L1).
fx_key(){ printf '%s' "$(cd "$1" && pwd -P)" | shasum -a 256 | awk '{print $1}'; }
RK="$(mkrepo keyprobe)"; add_scanner "$RK" alpha 0; commit_all "$RK"
PROBE_STATE="$TMPROOT/probe-state"
SCANNERS_STATE_DIR="$PROBE_STATE" fire "$RK" "git push" >/dev/null
[ -f "$PROBE_STATE/$(fx_key "$RK").txt" ] && check "the leak guard names records the way the gate writes them" ok \
  || check "the leak guard names records the way the gate writes them" "gate wrote: $(ls "$PROBE_STATE" 2>/dev/null | tr '\n' ' ')"
# ...and the FOLDER: run with no SCANNERS_STATE_DIR under a fake home, and the record must land
# where the guard below looks, relative to that home, or a change to the gate's default would
# leave the guard watching a folder nothing writes.
FAKEHOME="$TMPROOT/fakehome"; mkdir -p "$FAKEHOME"
RK2="$(mkrepo keyprobe2)"; add_scanner "$RK2" alpha 0; commit_all "$RK2"
( unset SCANNERS_STATE_DIR; HOME="$FAKEHOME" fire "$RK2" "git push" >/dev/null )
state_rel=".claude/state/scanners-passed"
[ -f "$FAKEHOME/$state_rel/$(fx_key "$RK2").txt" ] && check "the leak guard watches the folder the gate writes to by default" ok \
  || check "the leak guard watches the folder the gate writes to by default" "gate wrote: $(cd "$FAKEHOME" && find . -type f | tr '\n' ' ')"
REAL_STATE="$HOME/$state_rel"
_leaked=""
for _fx in "$TMPROOT"/*/; do
  [ -e "$_fx/.git" ] || continue
  _fx_key="$(fx_key "$_fx")"
  [ -e "$REAL_STATE/$_fx_key.txt" ] && { _leaked="$_leaked $(basename "$_fx")"; rm -f "$REAL_STATE/$_fx_key.txt"; }
done
[ -z "$_leaked" ] && check "no fixture wrote a pass record into the real state folder" ok \
  || check "no fixture wrote a pass record into the real state folder" "these did, and were removed:$_leaked"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
