#!/usr/bin/env bash
# Tests for measure-section-time.sh, which takes the sync suite's section time reading together
# with the machine state it was taken under (claude-config#517).
#
# The issue this belongs to exists because two readings taken hours apart on 2026-09-20, 963s and
# 1847s against a 2520s budget, were compared as though they were a measurement. They were not:
# section time is wall clock per section, so it inflates on a busy machine, and another project's
# harness was running during the later one. So the checks below care about the ways a reading lies about the machine it
# was taken on, rather than about arithmetic.
#
# Every seam the tool has is stubbed here, and each stub asserts it was REACHED, because a seam the
# test leaves unset runs for real and the suite then waits for minutes on a real run (L284, L524).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$DIR/measure-section-time.sh"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-section-time.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-measure-section-time: refusing to run: throwaway directory came back as '${TMPROOT}'." >&2
    exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# A stand in for the suite. Prints the SUITE-NOTE line the real one prints, with whatever section
# total the caller asked for, so a reading can be driven to a known number without paying for a run.
mk_suite(){          # $1 = name   $2 = section seconds   $3 = budget it claims   $4 = exit code
  local p="$TMPROOT/$1.sh"
  cat > "$p" <<EOF
#!/usr/bin/env bash
echo "SUITE-NOTE ${2}s of section time against a ${3}s budget"
echo "PASS=1 FAIL=0 (4 shards in 200s; ${2}s of section time against a ${3}s budget; every section counted once)"
exit $4
EOF
  chmod +x "$p"; printf '%s' "$p"
}

# A stand in for the suite whose SHARD COUNT changes between calls, so the refusal below can be
# driven. The suite counts its prelude once per shard, so two totals taken at different shard
# counts are measurements of different things.
mk_shifting_suite(){   # $1 = name, then the shard counts, one per call
  local p="$TMPROOT/$1.sh" log="$TMPROOT/$1.calls" vals="$TMPROOT/$1.shards"
  shift
  printf '%s\n' "$@" > "$vals"
  cat > "$p" <<EOF
#!/usr/bin/env bash
n=\$(wc -l < "$log" 2>/dev/null || echo 0)
n=\$(( n + 1 ))
echo "call" >> "$log"
j=\$(awk -v want="\$n" 'NR == want { print; found = 1 } END { if (!found) print last } { last = \$0 }' "$vals")
echo "SUITE-NOTE 900s of section time against a 2520s budget"
echo "PASS=1 FAIL=0 (\$j shards in 200s; 900s of section time against a 2520s budget; every section counted once)"
exit 0
EOF
  chmod +x "$p"; printf '%s' "$p"
}

# A stand in for the suite SOURCE, so the budget the tool derives can be driven without editing the
# real suite. The two constants are the ones the real file declares.
mk_source(){         # $1 = name   $2 = SUITE_TIMEOUT default   $3 = SUITE_WORK_BUDGET_PCT default
  local p="$TMPROOT/$1-source.sh"
  {
    echo '#!/usr/bin/env bash'
    echo "SUITE_TIMEOUT=\"\${SUITE_TIMEOUT:-$2}\""
    echo "SUITE_WORK_BUDGET_PCT=\"\${SUITE_WORK_BUDGET_PCT:-$3}\""
  } > "$p"
  printf '%s' "$p"
}

# A stand in for the ambient CPU reader. Prints the values given to it, one per call, and repeats
# the last one for ever after. Records every call, so a test can prove the seam was reached rather
# than assuming it (L284).
mk_ambient(){        # $1 = name, then the readings
  local p="$TMPROOT/$1-ambient.sh" log="$TMPROOT/$1-ambient.log" vals="$TMPROOT/$1-ambient.vals"
  local mark="$TMPROOT/$1-ambient.mark"
  shift
  printf '%s\n' "$@" > "$vals"
  cat > "$p" <<EOF
#!/usr/bin/env bash
n=\$(wc -l < "$log" 2>/dev/null || echo 0)
n=\$(( n + 1 ))
echo "call" >> "$log"
# A marker once this has been called twenty times, so a stub suite can wait on the condition the
# test actually needs (enough samples taken) instead of on a fixed time, which would be an
# assertion about how busy the machine is (L290).
[ "\$n" -ge 20 ] && : > "$mark"
awk -v want="\$n" 'NR == want { print; found = 1 } END { if (!found) print last } { last = \$0 }' "$vals"
EOF
  chmod +x "$p"; printf '%s' "$p"
}
ambient_calls(){ if [ -f "$TMPROOT/$1-ambient.log" ]; then wc -l < "$TMPROOT/$1-ambient.log" | tr -d ' '; else echo 0; fi; }

# A stand in for sleep that records rather than waits.
SLEEPLOG="$TMPROOT/slept"
SLEEPER="$TMPROOT/sleeper.sh"
cat > "$SLEEPER" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SLEEPLOG"
EOF
chmod +x "$SLEEPER"

SRC_OK="$(mk_source ok 3600 70)"          # the real file's own numbers: budget 2520

# Every run below sets all four seams. The defaults are the real suite, the real ps and the real
# sleep, and a test that leaves one unset pays for a real suite run (L143).
# `env` rather than a plain assignment prefix: the knobs each test varies arrive here as ARGUMENTS,
# and a leading VAR=value in a function's arguments is a command name, not an assignment.
run_m(){ env MEASURE_SUITE_SOURCE="$SRC_OK" MEASURE_SLEEP_CMD="$SLEEPER" "$@"; }

# --- the ordinary reading: three runs, a total, and the budget it is judged against.
S_OK="$(mk_suite ok 900 2520 0)"
A_OK="$(mk_ambient ok 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40)"
o1="$(run_m MEASURE_RUNS=3 MEASURE_SUITE_CMD="bash $S_OK" MEASURE_AMBIENT_CMD="$A_OK" bash "$M" 2>&1)"; c1=$?
[ "$c1" -eq 0 ] && check "three readings measure cleanly" ok \
                || check "three readings measure cleanly" "exit=$c1 out=$o1"
grep -q '900' <<< "$o1" \
  && check "it reports the section time it read" ok || check "it reports the section time it read" "out=$o1"
grep -q '2520' <<< "$o1" \
  && check "and the budget it was judged against" ok || check "and the budget it was judged against" "out=$o1"
grep -qE '3 reading' <<< "$o1" \
  && check "and says how many readings it is speaking from" ok \
  || check "and says how many readings it is speaking from" "out=$o1"
[ "$(ambient_calls ok)" -gt 0 ] \
  && check "the ambient reader seam was actually reached" ok \
  || check "the ambient reader seam was actually reached" "calls=$(ambient_calls ok)"
[ -s "$SLEEPLOG" ] \
  && check "the sleep seam was actually reached" ok || check "the sleep seam was actually reached" "log empty"

# --- what else was running is part of the reading, not something to filter out afterwards (L356).
grep -qi 'ambient' <<< "$o1" \
  && check "the machine state is reported beside the number" ok \
  || check "the machine state is reported beside the number" "out=$o1"
grep -q '40' <<< "$o1" \
  && check "and it is the measured figure, not a label" ok \
  || check "and it is the measured figure, not a label" "out=$o1"

# --- ONE reading cannot be told from noise, and the tool has to say so rather than let a single
#     number be quoted as a measurement (L395, L656). This is the defect the issue was filed about.
o2="$(run_m MEASURE_RUNS=1 MEASURE_SUITE_CMD="bash $S_OK" MEASURE_AMBIENT_CMD="$A_OK" bash "$M" 2>&1)"
grep -qi 'one reading' <<< "$o2" \
  && check "a single reading is labelled as not a measurement" ok \
  || check "a single reading is labelled as not a measurement" "out=$o2"

# --- a run that emitted no total measured NOTHING, and nothing must never be read as a figure of
#     zero, which clears every budget there is (L90, L98).
S_SILENT="$TMPROOT/silent.sh"
printf '#!/usr/bin/env bash\necho "PASS=1 FAIL=0"\nexit 0\n' > "$S_SILENT"; chmod +x "$S_SILENT"
A_S="$(mk_ambient silent 40)"
o3="$(run_m MEASURE_RUNS=2 MEASURE_SUITE_CMD="bash $S_SILENT" MEASURE_AMBIENT_CMD="$A_S" bash "$M" 2>&1)"; c3=$?
[ "$c3" -ne 0 ] && check "a run with no total is refused, not counted as zero" ok \
                || check "a run with no total is refused, not counted as zero" "exit=$c3 out=$o3"
grep -qE '0s of section time|budget.*\b0\b' <<< "$o3" \
  && check "and it never prints a total of zero" "printed a zero total: $o3" \
  || check "and it never prints a total of zero" ok

# --- a run that FAILED partway still ran everything before the failure, so its section total is a
#     fragment and must not be recorded as a reading of the suite (L480).
S_FAIL="$(mk_suite failed 300 2520 1)"
A_F="$(mk_ambient failed 40)"
o4="$(run_m MEASURE_RUNS=2 MEASURE_SUITE_CMD="bash $S_FAIL" MEASURE_AMBIENT_CMD="$A_F" bash "$M" 2>&1)"; c4=$?
[ "$c4" -ne 0 ] && check "a reading from a failed run is refused" ok \
                || check "a reading from a failed run is refused" "exit=$c4 out=$o4"
grep -qi 'fail' <<< "$o4" \
  && check "and it says the run failed rather than reporting the fragment" ok \
  || check "and it says the run failed rather than reporting the fragment" "out=$o4"

# --- the budget is DERIVED from the suite's own two constants, never written out again here, or the
#     day one of them moves this tool goes on judging against the superseded number (L41, L428).
SRC_OTHER="$(mk_source other 1800 50)"    # 1800 * 50% = 900
S_900="$(mk_suite b900 400 900 0)"
A_B="$(mk_ambient budget 40)"
o5="$(MEASURE_SUITE_SOURCE="$SRC_OTHER" MEASURE_SLEEP_CMD="$SLEEPER" MEASURE_RUNS=2 \
      MEASURE_SUITE_CMD="bash $S_900" MEASURE_AMBIENT_CMD="$A_B" bash "$M" 2>&1)"; c5=$?
[ "$c5" -eq 0 ] && grep -q '900' <<< "$o5" \
  && check "the budget follows the suite's own constants" ok \
  || check "the budget follows the suite's own constants" "exit=$c5 out=$o5"
grep -q '2520' <<< "$o5" \
  && check "and no copy of the old budget survives in it" "still printed 2520: $o5" \
  || check "and no copy of the old budget survives in it" ok

# --- two readings of one thing, the budget this tool derived and the budget the suite itself
#     printed, must agree. When they disagree neither is trustworthy and the reading is refused.
S_DISAGREE="$(mk_suite disagree 900 1111 0)"
A_D="$(mk_ambient disagree 40)"
o6="$(run_m MEASURE_RUNS=2 MEASURE_SUITE_CMD="bash $S_DISAGREE" MEASURE_AMBIENT_CMD="$A_D" bash "$M" 2>&1)"; c6=$?
[ "$c6" -ne 0 ] && check "a suite judging itself against a different budget is refused" ok \
                || check "a suite judging itself against a different budget is refused" "exit=$c6 out=$o6"

# --- the quiet bar is derived from what is UNUSUAL for THIS machine. A machine whose floor is high
#     must still be measurable, or always-present load refuses every measurement for ever (L364).
A_HIGH="$(mk_ambient high 400 400 400 400 400 400 400 400 400 400 400 400 400 400 400 400)"
o7="$(run_m MEASURE_RUNS=1 MEASURE_WAIT_SECONDS=600 MEASURE_SUITE_CMD="bash $S_OK" \
      MEASURE_AMBIENT_CMD="$A_HIGH" bash "$M" 2>&1)"; c7=$?
[ "$c7" -eq 0 ] \
  && check "a machine with a high but steady floor is still measurable" ok \
  || check "a machine with a high but steady floor is still measurable" "exit=$c7 out=$o7"
grep -q '400' <<< "$o7" \
  && check "and the floor it calibrated against is stated" ok \
  || check "and the floor it calibrated against is stated" "out=$o7"

# --- a machine that never settles reports UNMEASURED and refuses, rather than taking the reading
#     anyway and letting it be quoted as an idle one (L411).
A_BUSY="$(mk_ambient busy 40 40 40 40 40 40 900 900 900 900 900 900 900 900 900 900 900 900 900 900 900 900 900 900 900 900 900 900 900 900)"
o8="$(run_m MEASURE_RUNS=1 MEASURE_WAIT_SECONDS=60 MEASURE_SUITE_CMD="bash $S_OK" \
      MEASURE_AMBIENT_CMD="$A_BUSY" bash "$M" 2>&1)"; c8=$?
[ "$c8" -ne 0 ] && check "a machine that never settles is reported unmeasured" ok \
                || check "a machine that never settles is reported unmeasured" "exit=$c8 out=$o8"
grep -qi 'unmeasured\|never settled\|not quiet' <<< "$o8" \
  && check "and it says so in those terms" ok || check "and it says so in those terms" "out=$o8"

# --- the wait is bounded by a COUNT as well as by the clock, because with a fast reader the clock
#     is never reached and the loop does unbounded work (L704). The stub sleep never waits, so a
#     tool bounded only by MEASURE_WAIT_SECONDS would spin here until this suite's own deadline.
grep -qE 'sample' <<< "$o8" \
  && check "the bounded wait names how it was bounded" ok \
  || check "the bounded wait names how it was bounded" "out=$o8"

# --- a reading taken under a load this tool STARTED is not an idle reading, and the arm it belongs
#     to is recorded from what was actually done, never from what was asked for.
A_L="$(mk_ambient loaded 40)"
o9="$(run_m MEASURE_RUNS=1 MEASURE_LOAD_PROCS=2 MEASURE_SUITE_CMD="bash $S_OK" \
      MEASURE_AMBIENT_CMD="$A_L" bash "$M" 2>&1)"; c9=$?
[ "$c9" -eq 0 ] && check "a loaded arm measures cleanly" ok \
                || check "a loaded arm measures cleanly" "exit=$c9 out=$o9"
grep -qi 'loaded' <<< "$o9" \
  && check "and the reading is labelled loaded, not idle" ok \
  || check "and the reading is labelled loaded, not idle" "out=$o9"
grep -qiE 'idle' <<< "$o9" \
  && check "and it does not also call itself idle" "claimed idle too: $o9" \
  || check "and it does not also call itself idle" ok
grep -q '2' <<< "$o9" \
  && check "and it says how many load processes it started" ok \
  || check "and it says how many load processes it started" "out=$o9"

# --- whatever it started is stopped with it, and the check is against the pids it created rather
#     than a name match over the whole machine (L444, L473).
pgrep -f 'measure-section-time-load' >/dev/null 2>&1 \
  && check "the load it started is gone when it ends" "load processes survived" \
  || check "the load it started is gone when it ends" ok

# --- an ambient reader that cannot answer has measured NOTHING, and nothing is not a quiet
#     machine. This is the direction that matters: a reader returning an empty collection when its
#     source fails is indistinguishable from a correct read of an idle machine, and it would make
#     the machine look quiet exactly when it is busiest (L215, L98). Measured on the real Mac on
#     2026-09-20: a ps snapshot taken under load came back totalling 7.9% of one core, two seconds
#     either side of readings of 830%.
A_NONE="$(mk_ambient none "" "" "" "" "" "" "" "" "" "")"
o12="$(run_m MEASURE_RUNS=1 MEASURE_SUITE_CMD="bash $S_OK" MEASURE_AMBIENT_CMD="$A_NONE" bash "$M" 2>&1)"; c12=$?
[ "$c12" -ne 0 ] && check "an ambient reader that answers nothing is refused" ok \
                 || check "an ambient reader that answers nothing is refused" "exit=$c12 out=$o12"
grep -qi 'unmeasured' <<< "$o12" \
  && check "and the refusal says the machine state is unknown" ok \
  || check "and the refusal says the machine state is unknown" "out=$o12"

# --- an unreadable sample during the WAIT must not be taken for a quiet one either.
A_NONE2="$(mk_ambient none2 40 40 40 40 40 40 "" "" "" "" "" "" "" "" "" "" "" "" "" "")"
o13="$(run_m MEASURE_RUNS=1 MEASURE_WAIT_SECONDS=60 MEASURE_WAIT_MAX_SAMPLES=8 \
       MEASURE_SUITE_CMD="bash $S_OK" MEASURE_AMBIENT_CMD="$A_NONE2" bash "$M" 2>&1)"; c13=$?
[ "$c13" -ne 0 ] && check "a wait that only ever reads nothing does not call it quiet" ok \
                 || check "a wait that only ever reads nothing does not call it quiet" "exit=$c13 out=$o13"

# --- samples that could not be read during a RUN are counted and reported, because an ambient
#     figure averaged over two readable samples out of twenty is not the same claim as one
#     averaged over twenty, and only the count can tell them apart.
A_HALF="$(mk_ambient half 40 40 40 40 40 40 "" 40 "" 40 "" 40 "" 40 "" 40)"
o14="$(run_m MEASURE_RUNS=1 MEASURE_SUITE_CMD="bash $S_OK" MEASURE_AMBIENT_CMD="$A_HALF" bash "$M" 2>&1)"
grep -qiE 'unreadable|could not be read' <<< "$o14" \
  && check "unreadable samples are counted, not silently dropped" ok \
  || check "unreadable samples are counted, not silently dropped" "out=$o14"

# --- an unreadable sample must not be averaged in as a ZERO. Counting it both ways leaves the
#     word "unreadable" in the report while the ambient figure is pulled toward nothing, so the
#     reading looks like it was taken on a quiet machine. The stub suite below lives long enough
#     for the loop to take many samples, and the stub reader answers nothing for most of them.
A_DILUTE="$(mk_ambient dilute 40 40 40 40 40 40 400 "" 400 "" 400 "" 400 "")"
S_SLOW="$TMPROOT/slow.sh"
cat > "$S_SLOW" <<EOF
#!/usr/bin/env bash
# Stays alive until the sampler has taken enough readings, which is the condition this test needs,
# rather than for a fixed time, which would assert about the machine's load instead (L290). Bounded
# by a count as well, because a loop bounded only by a condition never reached does not end (L704).
_n=0
while [ ! -e "$TMPROOT/dilute-ambient.mark" ] && [ "\$_n" -lt 500000 ]; do _n=\$(( _n + 1 )); done
echo "SUITE-NOTE 900s of section time against a 2520s budget"
exit 0
EOF
chmod +x "$S_SLOW"
o15="$(run_m MEASURE_RUNS=1 MEASURE_SUITE_CMD="bash $S_SLOW" MEASURE_AMBIENT_CMD="$A_DILUTE" bash "$M" 2>&1)"
grep -q 'mean 400%' <<< "$o15" \
  && check "unreadable samples do not dilute the ambient figure toward zero" ok \
  || check "unreadable samples do not dilute the ambient figure toward zero" "out=$o15"

# --- the busiest processes are the three biggest, in order, and not everything above a threshold.
#     Measured on the real Mac on 2026-09-20 this printed eleven names in the order ps returned
#     them, which is a list nobody can read at the moment they most want it.
TOPFIX="$TMPROOT/ps-fixture"
# DELIBERATELY out of order, and with the two that must be left out sitting first and last. A
# fixture already in the order the code is supposed to produce is satisfied by code that does no
# ordering at all (L48, L159).
cat > "$TOPFIX" <<'EOF'
641 13.4 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
541 69.4 /Library/Backblaze.bzpkg/bztransmit
89888 638.5 /Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic
88377 92.0 /Applications/Xcode.app/Contents/Developer/xctest
408 8.0 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
EOF
_top="$(bash "$M" --top 0 < "$TOPFIX" 2>&1)"
[ "$(printf '%s' "$_top" | tr ' ' '\n' | grep -c .)" -le 3 ] \
  && check "the busiest line names at most three processes" ok \
  || check "the busiest line names at most three processes" "got=$_top"
case "$_top" in
  *Lightroom*xctest*bztransmit*) check "and names them biggest first" ok ;;
  *) check "and names them biggest first" "got=$_top" ;;
esac
case "$_top" in
  *Terminal*|*WindowServer*) check "and leaves out the ones below them" "got=$_top" ;;
  *) check "and leaves out the ones below them" ok ;;
esac

# --- the credibility test the DEFAULT reader applies to its own ps snapshot, driven directly,
#     because a cut short snapshot cannot be produced on demand from a real machine.
#
#     There WAS a second rule here, refusing a snapshot whose total contradicted the kernel's load
#     average. It is gone rather than adjusted, because it was wrong rather than badly tuned
#     (L252, L430). Measured on this Mac on 2026-09-20 at load 90: the load average counts
#     processes blocked on disk, which use no CPU at all, so a machine with four backup and
#     indexing daemons reading the disk sits at load 90 with a perfectly honest ps total of a few
#     hundred percent. The rule refused every one of six calibration samples and the tool measured
#     nothing, which is the failure it existed to prevent, pointed the other way. The load average
#     is now RECORDED beside each reading instead, where it says something ambient CPU cannot: that
#     the machine was under I/O pressure.
cred(){ bash "$M" --credible "$1" 2>&1; }
[ "$(cred 1034)" = "credible" ] \
  && check "an ordinary snapshot is credible" ok \
  || check "an ordinary snapshot is credible" "got=$(cred 1034)"
[ "$(cred 3)" = "credible" ] \
  && check "and a snapshot holding almost no processes is refused" "it was accepted" \
  || check "and a snapshot holding almost no processes is refused" ok

# --- the load average is recorded beside the reading, because ambient CPU cannot see a machine
#     that is busy waiting on its disk, and that is the state this one was in when it was written.
A_LA="$(mk_ambient loadavg 40)"
LA="$TMPROOT/loadavg.sh"
printf '#!/usr/bin/env bash\necho 7.5\n' > "$LA"; chmod +x "$LA"
o19="$(run_m MEASURE_RUNS=1 MEASURE_SUITE_CMD="bash $S_OK" MEASURE_AMBIENT_CMD="$A_LA" \
       MEASURE_LOADAVG_CMD="$LA" bash "$M" 2>&1)"
grep -q '7.5' <<< "$o19" \
  && check "the load average is recorded beside the reading" ok \
  || check "the load average is recorded beside the reading" "out=$o19"
grep -qi 'load' <<< "$o19" \
  && check "and it is named as a load average, not a bare number" ok \
  || check "and it is named as a load average, not a bare number" "out=$o19"

# --- the shard count is part of what a reading MEANS, because the suite runs its prelude once in
#     each shard and counts every one of them in the total. Two readings taken at different shard
#     counts are two different quantities, and comparing them is the mistake the issue is about.
S_SILENT_OK="$TMPROOT/noshards.sh"
printf '#!/usr/bin/env bash\necho "SUITE-NOTE 900s of section time against a 2520s budget"\nexit 0\n' > "$S_SILENT_OK"
chmod +x "$S_SILENT_OK"
S_SH="$(mk_shifting_suite steady 4 4 4)"
A_SH="$(mk_ambient shards 40)"
o16="$(run_m MEASURE_RUNS=3 MEASURE_SUITE_CMD="bash $S_SH" MEASURE_AMBIENT_CMD="$A_SH" bash "$M" 2>&1)"; c16=$?
[ "$c16" -eq 0 ] && check "a steady shard count measures cleanly" ok \
                 || check "a steady shard count measures cleanly" "exit=$c16 out=$o16"
grep -qE '4 shards' <<< "$o16" \
  && check "and the reading says how many shards produced it" ok \
  || check "and the reading says how many shards produced it" "out=$o16"

S_SH2="$(mk_shifting_suite shifting 4 2 4)"
A_SH2="$(mk_ambient shards2 40)"
o17="$(run_m MEASURE_RUNS=3 MEASURE_SUITE_CMD="bash $S_SH2" MEASURE_AMBIENT_CMD="$A_SH2" bash "$M" 2>&1)"; c17=$?
[ "$c17" -ne 0 ] && check "an arm whose shard count changed is refused" ok \
                 || check "an arm whose shard count changed is refused" "exit=$c17 out=$o17"
grep -qi 'shard' <<< "$o17" \
  && check "and the refusal names what changed" ok \
  || check "and the refusal names what changed" "out=$o17"

# --- a run in a single process prints no shard headline at all, and that is not a disagreement.
o18="$(run_m MEASURE_RUNS=2 MEASURE_SUITE_CMD="bash $S_SILENT_OK" MEASURE_AMBIENT_CMD="$A_SH" bash "$M" 2>&1)"; c18=$?
[ "$c18" -eq 0 ] && check "a run that names no shard count is still a reading" ok \
                 || check "a run that names no shard count is still a reading" "exit=$c18 out=$o18"

# --- knobs that decide what runs are refused rather than guessed at.
o10="$(run_m MEASURE_RUNS=zero MEASURE_SUITE_CMD="bash $S_OK" MEASURE_AMBIENT_CMD="$A_OK" bash "$M" 2>&1)"; c10=$?
[ "$c10" -eq 2 ] && check "a run count that is not a number is refused" ok \
                 || check "a run count that is not a number is refused" "exit=$c10 out=$o10"
o11="$(MEASURE_SUITE_SOURCE="$TMPROOT/not-there.sh" MEASURE_SLEEP_CMD="$SLEEPER" \
       MEASURE_SUITE_CMD="bash $S_OK" MEASURE_AMBIENT_CMD="$A_OK" bash "$M" 2>&1)"; c11=$?
[ "$c11" -eq 2 ] && check "a missing suite source is refused, not defaulted" ok \
                 || check "a missing suite source is refused, not defaulted" "exit=$c11 out=$o11"

# --- the record file, which is what makes the premise re-measurable later rather than a dated
#     sentence somebody has to trust (L316).
REC="$TMPROOT/readings.tsv"
A_R="$(mk_ambient rec 40)"
run_m MEASURE_RUNS=2 MEASURE_RECORD="$REC" MEASURE_SUITE_CMD="bash $S_OK" \
      MEASURE_AMBIENT_CMD="$A_R" bash "$M" >/dev/null 2>&1
[ -s "$REC" ] && check "readings are appended to the record when one is asked for" ok \
              || check "readings are appended to the record when one is asked for" "no record at $REC"
[ "$(grep -c . "$REC" 2>/dev/null || echo 0)" -ge 2 ] \
  && check "one row per run, not one per invocation" ok \
  || check "one row per run, not one per invocation" "rows=$(grep -c . "$REC" 2>/dev/null || echo 0)"
head -1 "$REC" 2>/dev/null | grep -q '	' \
  && check "and the record is tab separated so it can be read back" ok \
  || check "and the record is tab separated so it can be read back" "row=$(head -1 "$REC" 2>/dev/null)"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
