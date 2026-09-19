#!/usr/bin/env bash
# A suite started DIRECTLY bounds its own wall clock, and takes its children with it when it is
# stopped (claude-config#444).
#
# The runner has never had a deadline of its own, and a suite typed straight into a shell has no
# runner at all. On 2026-09-18 a pile of 559 suite processes ran for seven hours at zero CPU on a Mac
# that six agents were working on, and nothing on the machine said so. Reproduced here the same day:
# test-run-all-tests.sh stopped by a signal to its own pid (what a deadline in a caller sends) left
# its runner and three fixture suites looping `sleep 3600` for ever, because the suite never killed
# its own children and the fixtures never ended on their own.
#
# lib/suite-deadline.sh is the one place that answers both halves, so these checks drive it through
# small suites built here, with the deadline's clock INJECTED rather than waited out (L524).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/suite-deadline.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$LIB" ]; then
  echo "FAIL: there is no helper at $LIB, so no suite can bound its own wall clock"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.deadline-test.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-suite-deadline: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
ALL_PIDS=""
cleanup(){
  # Everything this suite started, whatever happened. A test about leaked processes that leaks its
  # own is the defect it is testing.
  [ -n "$ALL_PIDS" ] && kill -9 $ALL_PIDS 2>/dev/null
  rm -rf "$TMPROOT"
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

alive(){ kill -0 "$1" 2>/dev/null; }
# Waits on the CONDITION, in tenths, with a ceiling generous enough for a loaded Mac. The ceiling is
# what makes a broken helper fail rather than hang this suite; it is never what a pass waits for.
wait_gone(){   # wait_gone <pid> [tenths]
  local n=0
  while [ "$n" -lt "${2:-300}" ]; do
    alive "$1" || return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
wait_file(){   # wait_file <path> [tenths]
  local n=0
  while [ "$n" -lt "${2:-300}" ]; do
    [ -s "$1" ] && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

# A child that blocks for as long as THIS suite is alive and no longer, so nothing here can outlive
# a run of it however the run ends. That bound is the fix this issue is about, applied to its own
# fixtures.
HOLDER="$TMPROOT/holder.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo $$ > "$1"\n'
  printf 'while kill -0 %s 2>/dev/null; do sleep 1 & wait "$!" || true; done\n' "$$"
} > "$HOLDER"

# mk_armed <file> <body>: a suite that arms the helper and then runs <body>.
mk_armed(){
  {
    printf '#!/usr/bin/env bash\n'
    printf 'trap %s EXIT\n' "'echo exit-trap-ran > \"$TMPROOT/\$(basename \"\$0\").exit\"'"
    printf '. "%s"\n' "$LIB"
    printf 'suite_deadline_arm 60 || exit $?\n'
    printf '%s\n' "$2"
    printf 'echo finished\n'
  } > "$1"
}

now="$(date +%s)"

# ---------------------------------------------------------------------------
# A suite blocked on a child that never ends is stopped at its deadline.
# ---------------------------------------------------------------------------
# Blocked the way the real pile was: a command substitution waiting on a child. Bash defers a
# trapped signal until the foreground command returns, so a handler alone could never fire here,
# and the deadline has to reach the child to get the suite moving again.
mk_armed "$TMPROOT/overrun.sh" "out=\"\$(bash '$HOLDER' '$TMPROOT/overrun.child')\""
SUITE_WALL_STARTED=$(( now - 1000 )) SUITE_WALL_POLL=0.05 SUITE_WALL_PIDFILE="$TMPROOT/overrun.wd" \
  bash "$TMPROOT/overrun.sh" > "$TMPROOT/overrun.out" 2>&1 &
ov=$!
ALL_PIDS="$ALL_PIDS $ov"
wait_file "$TMPROOT/overrun.child" && ov_child="$(cat "$TMPROOT/overrun.child")" || ov_child=""
ALL_PIDS="$ALL_PIDS $ov_child"
if wait_gone "$ov"; then
  wait "$ov"; ov_rc=$?
  check "#444 a suite past its own deadline is stopped" ok
else
  ov_rc="still running"
  check "#444 a suite past its own deadline is stopped" "it was still running after 30s"
fi
[ "$ov_rc" = 124 ] \
  && check "#444 and it exits 124, the status a deadline means" ok \
  || check "#444 and it exits 124, the status a deadline means" "exit=$ov_rc out=$(cat "$TMPROOT/overrun.out")"
case "$(cat "$TMPROOT/overrun.out")" in
  *"FAIL: overrun.sh ran past its own wall clock of 60s"*)
    check "#444 and it says so, naming the suite and the limit" ok ;;
  *) check "#444 and it says so, naming the suite and the limit" "out=$(cat "$TMPROOT/overrun.out")" ;;
esac
case "$(cat "$TMPROOT/overrun.out")" in
  *finished*) check "#444 and nothing after the blocked step ran" "out=$(cat "$TMPROOT/overrun.out")" ;;
  *) check "#444 and nothing after the blocked step ran" ok ;;
esac
if [ -n "$ov_child" ] && wait_gone "$ov_child" 50; then
  check "#444 and the child it was blocked on went with it" ok
else
  check "#444 and the child it was blocked on went with it" "child pid '${ov_child:-never started}' is still running"
fi
[ -s "$TMPROOT/overrun.sh.exit" ] \
  && check "#444 and the suite's own EXIT cleanup still ran" ok \
  || check "#444 and the suite's own EXIT cleanup still ran" "no marker from its EXIT trap"
ov_wd="$(cat "$TMPROOT/overrun.wd" 2>/dev/null || true)"
case "$ov_wd" in
  ''|*[!0-9]*) check "#444 the watchdog recorded itself" "pidfile held '$ov_wd'" ;;
  *) ALL_PIDS="$ALL_PIDS $ov_wd"
     wait_gone "$ov_wd" 50 \
       && check "#444 and the watchdog is gone once it has fired" ok \
       || check "#444 and the watchdog is gone once it has fired" "pid $ov_wd is still running" ;;
esac

# ---------------------------------------------------------------------------
# The control: a suite that finishes inside its deadline is not touched, and leaves nothing behind.
# ---------------------------------------------------------------------------
# Without this, a helper that stopped every suite at once would pass every check above (L159).
mk_armed "$TMPROOT/quick.sh" ": nothing to wait for"
q_start="$(date +%s)"
q_out="$(SUITE_WALL_POLL=0.05 SUITE_WALL_PIDFILE="$TMPROOT/quick.wd" bash "$TMPROOT/quick.sh" 2>&1)"; q_rc=$?
q_took=$(( $(date +%s) - q_start ))
[ "$q_rc" -eq 0 ] && [ "$q_out" = finished ] \
  && check "#444 a suite inside its deadline runs to the end untouched" ok \
  || check "#444 a suite inside its deadline runs to the end untouched" "exit=$q_rc out=$q_out"
# Captured through a command substitution on purpose. The watchdog outlives the suite by up to one
# poll, and a watchdog still holding the suite's output would keep every caller that captures it
# waiting (L235). Judged against the deadline it was given, not a guessed number: a capture held
# open by the watchdog would last until the deadline itself.
[ "$q_took" -lt 30 ] \
  && check "#444 and a caller capturing its output is not held open by the watchdog" ok \
  || check "#444 and a caller capturing its output is not held open by the watchdog" "the capture took ${q_took}s"
# Waited for rather than read at once: the watchdog is started in the background, and a suite with
# nothing to do can be gone before it has written its pidfile. Seen once on the Linux runner.
wait_file "$TMPROOT/quick.wd" || true
q_wd="$(cat "$TMPROOT/quick.wd" 2>/dev/null || true)"
case "$q_wd" in
  ''|*[!0-9]*) check "#444 the quick suite armed a watchdog at all" "pidfile held '$q_wd'" ;;
  *) ALL_PIDS="$ALL_PIDS $q_wd"
     wait_gone "$q_wd" 100 \
       && check "#444 and its watchdog leaves once the suite has gone" ok \
       || check "#444 and its watchdog leaves once the suite has gone" "pid $q_wd is still running" ;;
esac


# ---------------------------------------------------------------------------
# A suite stopped from OUTSIDE takes its children with it.
# ---------------------------------------------------------------------------
# This is the half that was reproduced: a signal to the suite's own pid, which is what a caller with
# a deadline sends, ended the suite and left everything it had started running for ever.
#
# stop_and_check <name> <signal> <body> <status the signal means>
stop_and_check(){
  local name="$1" sig="$2" body="$3" want="$4" pid child rc n=0
  mk_armed "$TMPROOT/$name.sh" "$body"
  SUITE_WALL_POLL=0.05 SUITE_WALL_PIDFILE="$TMPROOT/$name.wd" \
    bash "$TMPROOT/$name.sh" > "$TMPROOT/$name.out" 2>&1 &
  pid=$!
  ALL_PIDS="$ALL_PIDS $pid"
  wait_file "$TMPROOT/$name.child" && child="$(cat "$TMPROOT/$name.child")" || child=""
  ALL_PIDS="$ALL_PIDS $child"
  # Stopped only once the watchdog has SEEN the child, which it records beside its pidfile. Stopping
  # sooner would test the gap the helper states it has, a child started within the last poll.
  while [ "$n" -lt 300 ]; do
    awk -F'\t' -v p="$child" '$1 == p { f = 1 } END { exit !f }' "$TMPROOT/$name.wd.seen" 2>/dev/null && break
    sleep 0.1; n=$((n + 1))
  done
  kill -"$sig" "$pid" 2>/dev/null
  if wait_gone "$pid"; then wait "$pid"; rc=$?; else rc="still running"; fi
  [ "$rc" = "$want" ] \
    && check "#444 a suite sent $sig ($name) stops with the status $sig means" ok \
    || check "#444 a suite sent $sig ($name) stops with the status $sig means" "exit=$rc out=$(cat "$TMPROOT/$name.out")"
  if [ -n "$child" ] && wait_gone "$child" 100; then
    check "#444 and the child it had started ($name) is gone too" ok
  else
    check "#444 and the child it had started ($name) is gone too" "child pid '${child:-never started}' is still running"
  fi
}
# TERM between two commands, which is where the reproduced pile was stopped: the suite ends, its
# EXIT trap runs, and the child it had started in the background is orphaned.
stop_and_check between TERM \
  "bash '$HOLDER' '$TMPROOT/between.child' & while :; do sleep 0.2; done" 143
# KILL while blocked on the child, which no handler of the suite's own could ever answer.
stop_and_check blocked KILL "out=\"\$(bash '$HOLDER' '$TMPROOT/blocked.child')\"" 137


# ---------------------------------------------------------------------------
# What the limit may be.
# ---------------------------------------------------------------------------
# A value that is not a whole number is REFUSED rather than guessed at: it decides whether a suite
# is killed, and an unreadable one must not land on either side quietly (L50).
mk_armed "$TMPROOT/badlimit.sh" ": nothing"
bl_out="$(SUITE_WALL_TIMEOUT=soon bash "$TMPROOT/badlimit.sh" 2>&1)"; bl_rc=$?
[ "$bl_rc" -ne 0 ] \
  && check "#444 a limit that is not a whole number is refused" ok \
  || check "#444 a limit that is not a whole number is refused" "exit=$bl_rc out=$bl_out"
case "$bl_out" in
  *"SUITE_WALL_TIMEOUT='soon'"*) check "#444 and the refusal names the value" ok ;;
  *) check "#444 and the refusal names the value" "out=$bl_out" ;;
esac
# 0 is off, and off means no watchdog at all rather than one that never fires.
off_out="$(SUITE_WALL_TIMEOUT=0 SUITE_WALL_PIDFILE="$TMPROOT/off.wd" bash "$TMPROOT/quick.sh" 2>&1)"; off_rc=$?
[ "$off_rc" -eq 0 ] && [ ! -e "$TMPROOT/off.wd" ] \
  && check "#444 a limit of 0 turns the deadline off and starts no watchdog" ok \
  || check "#444 a limit of 0 turns the deadline off and starts no watchdog" "exit=$off_rc out=$off_out pidfile=$(cat "$TMPROOT/off.wd" 2>/dev/null)"

# The seams describe ONE run. A suite started by an armed suite must not read the injected start or
# pidfile as its own (L169), or every nested suite would inherit a deadline that has already passed.
mk_armed "$TMPROOT/parent.sh" "env | grep -E '^SUITE_WALL_(STARTED|PIDFILE)=' || echo clean"
pe_out="$(SUITE_WALL_STARTED=$(( now - 5 )) SUITE_WALL_PIDFILE="$TMPROOT/parent.wd" bash "$TMPROOT/parent.sh" 2>&1)"
case "$pe_out" in
  clean*) check "#444 the injected start and pidfile are not passed on to what the suite runs" ok ;;
  *) check "#444 the injected start and pidfile are not passed on to what the suite runs" "out=$pe_out" ;;
esac

# ---------------------------------------------------------------------------
# A suite that names no limit takes the one shared default (claude-config#465).
# ---------------------------------------------------------------------------
# Read from the helper rather than written here as a literal, so the day the default moves this
# still means what it says (L401).
SHARED_DEFAULT="$(sed -n 's/^SUITE_WALL_DEFAULT=\([0-9][0-9]*\)$/\1/p' "$LIB")"
case "$SHARED_DEFAULT" in
  ''|*[!0-9]*) check "#465 the helper declares one shared default limit" "read '$SHARED_DEFAULT' from $LIB" ;;
  *) check "#465 the helper declares one shared default limit" ok ;;
esac
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -u\n'
  printf '. "%s"\n' "$LIB"
  printf 'suite_deadline_arm || exit $?\n'
  printf 'out="$(bash %q %q)"\n' "$HOLDER" "$TMPROOT/default.child"
  printf 'echo finished\n'
} > "$TMPROOT/default.sh"
# Started past the shared default, so a suite that silently took some other limit (or none, which
# is what an unset argument under `set -u` used to give) either runs on or names a different one.
SUITE_WALL_STARTED=$(( now - ${SHARED_DEFAULT:-0} - 5 )) SUITE_WALL_POLL=0.05 \
  bash "$TMPROOT/default.sh" > "$TMPROOT/default.out" 2>&1 &
df=$!
ALL_PIDS="$ALL_PIDS $df"
wait_file "$TMPROOT/default.child" && ALL_PIDS="$ALL_PIDS $(cat "$TMPROOT/default.child")"
if wait_gone "$df"; then wait "$df"; df_rc=$?; else df_rc="still running"; fi
case "$df_rc:$(cat "$TMPROOT/default.out")" in
  "124:"*"wall clock of ${SHARED_DEFAULT}s"*) check "#465 a suite arming with no limit is held to the shared default" ok ;;
  *) check "#465 a suite arming with no limit is held to the shared default" "exit=$df_rc out=$(cat "$TMPROOT/default.out")" ;;
esac

# ---------------------------------------------------------------------------
# Every suite arms it, and one that does not fails here (claude-config#465).
# ---------------------------------------------------------------------------
# #444 armed only the suite it reproduced, so the other suites went on having no wall clock when
# run directly, and nothing required one: a behaviour each suite must opt into is a convention
# until something fails on the one that does not (L621, L613).
#
# A suite arms when it SOURCES the helper and CALLS suite_deadline_arm, each on a line of its own
# that is code rather than a comment, so a suite that only talks about the deadline, as this file
# does in its fixtures' text, does not answer for one that has it (L135, L178).
arms_deadline(){   # arms_deadline <suite file> -> 0 when it sources the helper and arms it
  grep -Eq '^[[:space:]]*(\.|source)[[:space:]]+[^#]*suite-deadline\.sh' "$1" 2>/dev/null || return 1
  grep -Eq '^[[:space:]]*suite_deadline_arm([[:space:]]|$)' "$1" 2>/dev/null || return 1
  return 0
}
# Seen to fail before it is trusted (L1): each way of not arming is refused, and the real shape
# passes. Without the pass, a predicate refusing everything would satisfy the refusals.
printf '#!/usr/bin/env bash\necho no deadline here\n' > "$TMPROOT/probe-none.sh"
printf '#!/usr/bin/env bash\n# . lib/suite-deadline.sh\n# suite_deadline_arm\n' > "$TMPROOT/probe-comment.sh"
printf '#!/usr/bin/env bash\n. "$DIR/lib/suite-deadline.sh" || exit 1\n' > "$TMPROOT/probe-sourced-only.sh"
printf '#!/usr/bin/env bash\nsuite_deadline_arm || exit $?\n' > "$TMPROOT/probe-armed-only.sh"
printf '#!/usr/bin/env bash\n. "$DIR/lib/suite-deadline.sh" || exit 1\nsuite_deadline_arm || exit $?\n' > "$TMPROOT/probe-armed.sh"
probe_bad=""
for p in none comment sourced-only armed-only; do
  arms_deadline "$TMPROOT/probe-$p.sh" && probe_bad="$probe_bad $p"
done
[ -z "$probe_bad" ] \
  && check "#465 the scan refuses a suite that does not arm, or only mentions it, or does half" ok \
  || check "#465 the scan refuses a suite that does not arm, or only mentions it, or does half" "it accepted:$probe_bad"
arms_deadline "$TMPROOT/probe-armed.sh" \
  && check "#465 and accepts one that sources the helper and arms it" ok \
  || check "#465 and accepts one that sources the helper and arms it" "it refused the armed probe"

# The suites are the ones the RUNNER runs, asked of the runner itself, so the scan and the runner
# cannot disagree about what a suite is (L41, L247).
scan_dirs="$(HOOK_TESTS_LIST_ONLY=1 bash "$DIR/run-all-tests.sh" 2>/dev/null)"
scanned=0
unarmed=""
while IFS= read -r d; do
  [ -n "$d" ] || continue
  for s in "$d"/test-*.sh; do
    [ -f "$s" ] || continue
    scanned=$((scanned + 1))
    arms_deadline "$s" || unarmed="$unarmed  $s
"
  done
done <<EOF
$scan_dirs
EOF
# Read as a count before it is read as a verdict: a scan that found nothing to scan passes every
# suite it never looked at (L98, L288).
[ "$scanned" -gt 0 ] \
  && check "#465 the scan read the suites the runner runs ($scanned of them)" ok \
  || check "#465 the scan read the suites the runner runs ($scanned of them)" "the runner listed: ${scan_dirs:-nothing}"
if [ -z "$unarmed" ]; then
  check "#465 every suite arms its own deadline" ok
else
  check "#465 every suite arms its own deadline" "these do not source lib/suite-deadline.sh and call suite_deadline_arm, so run directly they have no wall clock and nothing stops what they start:
$unarmed"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
