#!/usr/bin/env bash
# Tests for lib/agent-lock.sh, the reading of whether a worktree lock was left by a Claude agent
# that is no longer running (claude-config#1282). check-stale-worktrees.sh is tested end to end in
# test-check-stale-worktrees.sh; this suite pins the verdicts themselves, including the edges no
# worktree fixture reaches: a reason that only looks like an agent's, what ps says on each stream,
# and a boot time that cannot be read.
#
# A fake ps answers from a table and the boot time is injected, so nothing here depends on this
# machine's own processes (L411), apart from the boot time reader, which is checked for giving a
# number on any machine that has one.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/agent-lock.sh"
TMP="$(mktemp -d)"
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi }
verdict(){ agent_lock_verdict "$1" | cut -f1; }

# The fake ps: the start on stdout and exit 0 for a pid in the table, nothing and exit 1 for one
# that is not, and whatever PS_SAY / PS_RC ask for otherwise.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/ps" <<'STUB'
#!/usr/bin/env bash
pid=""; while [ $# -gt 0 ]; do [ "$1" = -p ] && { pid="$2"; shift; }; shift; done
printf '%s\n' "$pid" >>"$PS_CALLS"
if [ -n "${PS_RC:-}" ]; then [ -n "${PS_SAY:-}" ] && echo "$PS_SAY" >&2; exit "$PS_RC"; fi
line="$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' "$PS_TABLE")"
[ -n "$line" ] || exit 1
printf '%s   \n' "$line"
STUB
chmod +x "$TMP/bin/ps"
export AGENT_LOCK_PS="$TMP/bin/ps" PS_CALLS="$TMP/calls" PS_TABLE="$TMP/table"
export AGENT_LOCK_BOOT_EPOCH=1791590400   # Sat Oct 10 00:00:00 2026 UTC
printf '7\tThu Oct 15 12:00:00 2026\n8\tFri Oct 16 08:30:00 2026\n' >"$PS_TABLE"
: >"$PS_CALLS"

# --- which reasons are a Claude agent's ------------------------------------
check_eq "a reason that is not an agent's is other" other "$(verdict "kept on an external disk")"
check_eq "an empty reason is other" other "$(verdict "")"
check_eq "an agent's reason with a start time but no pid is other" other "$(verdict "claude agent agent-x (start Thu Oct 15 12:00:00 2026)")"
check_eq "an agent's reason with a pid that is not a number is other" other "$(verdict "claude agent agent-x (pid seven start Thu Oct 15 12:00:00 2026)")"
check_eq "an agent's reason with words after it is other" other "$(verdict "claude agent agent-x (pid 7 start Thu Oct 15 12:00:00 2026) and more")"
check_eq "ps is never asked about a lock that is not an agent's" "" "$(cat "$PS_CALLS")"

# --- the verdicts ----------------------------------------------------------
check_eq "a running pid that started when the lock says is live" live "$(verdict "claude agent agent-x (pid 7 start Thu Oct 15 12:00:00 2026)")"
check_eq "the padding ps puts on its start time does not stop the match" live "$(verdict "claude agent agent-x (pid 7 start Thu  Oct 15   12:00:00 2026)")"
check_eq "a pid nothing has is dead" dead "$(verdict "claude agent agent-x (pid 9 start Thu Oct 15 12:00:00 2026)")"
check_eq "a running pid that started at another time is reused" reused "$(verdict "claude agent agent-x (pid 8 start Thu Oct 15 12:00:00 2026)")"
check_eq "and says when the process holding it now started" \
  "pid 8 is now a different process, started Fri Oct 16 08:30:00 2026" "$(agent_lock_verdict "claude agent agent-x (pid 8 start Thu Oct 15 12:00:00 2026)" | cut -f2)"
: >"$PS_CALLS"
check_eq "an agent that started before the boot is preboot, even with its pid running" preboot "$(verdict "claude agent agent-x (pid 7 start Mon Oct  5 12:00:00 2026)")"
check_eq "and ps is not asked" "" "$(cat "$PS_CALLS")"

# --- the older format, with no start time ----------------------------------
# A lock written as "claude agent <name> (pid <pid>)" records nothing to tell its agent from a
# process that has reused the pid since, so a running pid keeps it. A pid nothing has is gone
# whatever started it.
check_eq "an older lock whose pid nothing has is dead" dead "$(verdict "claude agent agent-x (pid 9)")"
check_eq "an older lock whose pid is running cannot be told from a reuse, so it is nostart" nostart "$(verdict "claude agent agent-x (pid 7)")"
check_eq "and says the pid is running with no start time to compare" \
  "pid 7, which is running, and records no start time to tell its agent from a process that reused the pid" \
  "$(agent_lock_verdict "claude agent agent-x (pid 7)" | cut -f2)"
check_eq "an older lock with ps unreadable is unreadable" unreadable "$(PS_RC=2 PS_SAY="ps: no access" verdict "claude agent agent-x (pid 9)")"
check_eq "an older lock is never preboot, having no start to place before the boot" dead "$(AGENT_LOCK_BOOT_EPOCH=9999999999 verdict "claude agent agent-x (pid 9)")"

# --- what cannot be read is said, never guessed ----------------------------
check_eq "ps failing is unreadable" unreadable "$(PS_RC=2 PS_SAY="ps: no access" verdict "claude agent agent-x (pid 7 start Thu Oct 15 12:00:00 2026)")"
check_eq "and carries what ps said" "pid 7, and ps said: ps: no access" \
  "$(PS_RC=2 PS_SAY="ps: no access" agent_lock_verdict "claude agent agent-x (pid 7 start Thu Oct 15 12:00:00 2026)" | cut -f2)"
check_eq "exit 1 WITH words is not the answer 'no such process'" unreadable "$(PS_RC=1 PS_SAY="ps: something else" verdict "claude agent agent-x (pid 9 start Thu Oct 15 12:00:00 2026)")"
check_eq "a ps that is not there is unreadable" unreadable "$(AGENT_LOCK_PS="$TMP/no-such-ps" verdict "claude agent agent-x (pid 9 start Thu Oct 15 12:00:00 2026)")"
check_eq "with the boot time unknown, an old start is not called preboot, it goes to ps" reused "$(AGENT_LOCK_BOOT_EPOCH=unknown verdict "claude agent agent-x (pid 7 start Mon Oct  5 12:00:00 2026)")"
check_eq "a start time that cannot be parsed is not preboot either" dead "$(verdict "claude agent agent-x (pid 9 start sometime last week)")"

# --- the boot time reader --------------------------------------------------
check_eq "an injected boot time that is not a number reads as unknown" 1 "$(AGENT_LOCK_BOOT_EPOCH=soon agent_lock_boot_epoch >/dev/null; echo $?)"
real="$(unset AGENT_LOCK_BOOT_EPOCH; agent_lock_boot_epoch)"; rc=$?
if [ "$rc" -eq 0 ]; then
  check_eq "the real boot time is a number in the past" yes "$([ "$real" -gt 0 ] && [ "$real" -le "$(date +%s)" ] && echo yes || echo no)"
else
  echo "UNMEASURED: neither sysctl kern.boottime nor /proc/stat gives a boot time here"
fi

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
