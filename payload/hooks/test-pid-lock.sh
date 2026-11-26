#!/usr/bin/env bash
# Tests for lib/pid-lock.sh: the lock several processes take in turn, and the one reading of a pid
# that every lock, claim and watcher check here shares (claude-config#3601).
#
# kill -0 exits 1 for a process this shell may not signal exactly as for one that has gone, and
# the lock helpers read that 1 alone, so a LIVE holder they could not signal read as dead and its
# lock was taken: another account's process, or any process at all under a sandbox that refuses
# signals. Measured on 2026-11-26 on the personal MacBook (one sample each, the Mac otherwise
# idle): under sandbox-exec with signals denied, kill -0 of this shell's own running child and of
# pid 1 both said "Operation not permitted" and exited 1, ps was refused (exit 126), and kill -0 of
# a pid nobody holds still said "No such process". So "gone" is said only on those words, and every
# other failure is "could not tell", which never takes a lock.
#
# Every lock here is a throwaway file in this suite's own folder. No wait is real: each take is
# asked with a deadline of 0 seconds, which is one look and an answer (L524), and asked twice, as
# the rerun claim asks, because a takeover of a holder that has gone spends the first look. Each
# take runs in a subshell, so what it leaves set is its own; its pid file is this suite's.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/pid-lock.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
want(){ if [ "$2" = "$3" ]; then check "$1" ok; else check "$1" "wanted '$2', got '$3'"; fi; }

[ -f "$LIB" ] || { echo "FAIL: no lib at $LIB"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
# shellcheck source=lib/pid-lock.sh
. "$LIB"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pid-lock.XXXXXXXX")" && pwd -P)"
LIVE=""
trap 'for _p in $LIVE; do kill -9 "$_p" 2>/dev/null; done; rm -rf "$FIX"' EXIT

# A pid that has certainly gone: a child that ended and was reaped.
perl -e 'exit 0' & DEAD=$!; wait "$DEAD"
# A process this shell may signal, which is running for the whole suite and is bounded by its own
# sleep. Started by a subshell that ends at once, so it is never this script's child.
( sleep 120 </dev/null >/dev/null 2>&1 & printf '%s\n' "$!" > "$FIX/live.pid" ) </dev/null >/dev/null 2>&1
ALIVE="$(cat "$FIX/live.pid")"; LIVE="$LIVE $ALIVE"
NOSIGNAL='(version 1)(allow default)(deny signal)'

state_of(){ local rc=0; pid_running "$1" 2>/dev/null || rc=$?; printf %s "$rc"; }
take(){ # take <lock> -> "<rc> <what the lock holds> <PID_LOCK_UNREAD>"
  local rc=0
  take_pid_lock "$1" 0 2>/dev/null || take_pid_lock "$1" 0 2>/dev/null || rc=$?
  printf "%s %s %s" "$rc" "$(cat "$1" 2>/dev/null)" "${PID_LOCK_UNREAD:-}"
}

echo "pid lock: the three answers of one reading"
want "a running process this shell may signal is running" 0 "$(state_of "$ALIVE")"
want "a pid that has gone is gone" 1 "$(state_of "$DEAD")"
if kill -0 1 2>/dev/null; then
  echo "SUITE-PART-UNMEASURED a process this shell may not signal: this account may signal pid 1, so none could be found"
else
  want "a running process this shell may not signal is could not tell, never gone" 2 "$(state_of 1)"
fi

echo "pid lock: a holder that could not be read keeps its lock"
if kill -0 1 2>/dev/null; then
  echo "SUITE-PART-UNMEASURED a lock held by a process this shell may not signal: this account may signal pid 1"
else
  # Pid 1 is running on every machine and belongs to another account: a live holder this shell may
  # not signal. Before #3601 its lock was taken.
  printf '1\n' > "$FIX/other.lock"
  want "a lock whose live holder may not be signalled is not taken, and the take says whose it could not read" \
    "1 1 1" "$(take "$FIX/other.lock")"
  [ ! -e "$FIX/other.lock.break" ] && check "and no break lock is left behind" ok || check "and no break lock is left behind" "it is there"
  # The takeover is the second place the same reading was made, asked of it alone.
  printf '1\n' > "$FIX/other.lock"
  ( break_stale_pid_lock "$FIX/other.lock" 1 ) 2>/dev/null
  want "a takeover asked of a holder that may not be signalled removes nothing" 1 "$(cat "$FIX/other.lock" 2>/dev/null)"
  # The words a caller appends to its refusal, naming the probe and saying it is not the same as gone.
  said="$(PID_LOCK_UNREAD=1; pid_lock_unread_sentence 2>/dev/null)"
  case "$said" in
    *"process 1"*"kill -0 1"*"not the same as"*) check "and the sentence a refusal carries names the process, the probe, and that it is not gone" ok ;;
    *) check "and the sentence a refusal carries names the process, the probe, and that it is not gone" "got '$said'" ;;
  esac
fi
# The real thing rather than a stand in, where this Mac has it: a sandbox that refuses every signal,
# where even this account's own live holder cannot be signalled.
printf '%s\n' "$ALIVE" > "$FIX/sandboxed.lock"
printf '%s\n' "$DEAD" > "$FIX/sandboxed-dead.lock"
if [ "$(sandbox-exec -p "$NOSIGNAL" /bin/bash -c 'kill -0 "$1" 2>/dev/null && echo signalled || echo refused' _ "$ALIVE" 2>/dev/null)" = refused ]; then
  got="$(sandbox-exec -p "$NOSIGNAL" /bin/bash -c '. "$1"; rc=0; take_pid_lock "$2" 0 || take_pid_lock "$2" 0 || rc=$?; printf "%s %s" "$rc" "$(cat "$2" 2>/dev/null)"' _ "$LIB" "$FIX/sandboxed.lock" 2>/dev/null)"
  want "under a sandbox that refuses signals, a live holder's lock is not taken" "1 $ALIVE" "$got"
  # The recovery the safe side keeps: a holder that HAS gone is still said to be gone there, so its
  # lock is still taken over.
  got="$(sandbox-exec -p "$NOSIGNAL" /bin/bash -c '. "$1"; rc=0; take_pid_lock "$2" 0 || take_pid_lock "$2" 0 || rc=$?; printf "%s" "$rc"' _ "$LIB" "$FIX/sandboxed-dead.lock" 2>/dev/null)"
  want "and under the same sandbox a holder that has gone still has its lock taken over" 0 "$got"
else
  echo "SUITE-PART-UNMEASURED a lock under a sandbox that refuses signals: sandbox-exec is not here, or could not start, or did not refuse the signal"
fi

echo "pid lock: what is settled stays settled"
printf '%s\n' "$DEAD" > "$FIX/dead.lock"
want "a lock whose holder has gone is taken over, with nothing said of an unread holder" "0 $$ " "$(take "$FIX/dead.lock")"
printf '%s\n' "$ALIVE" > "$FIX/alive.lock"
want "a lock whose holder is running is left alone, with nothing said of an unread holder" "1 $ALIVE " "$(take "$FIX/alive.lock")"
printf '\n' > "$FIX/empty.lock"
want "a lock with no pid in it is never broken on a guess" "1  " "$(take "$FIX/empty.lock")"

echo "pid lock: one reading of a pid, in one place (L370)"
# claude-sync and lib/sync-clone.sh each had their own copy of the three answer reading (#3601 item
# 6). Both now take it from here.
# The checkout this copy sits in (lib/checkout-root.sh, #1567); the installed copy is in none.
PL_CHECKOUT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -n "$PL_CHECKOUT" ] && [ -f "$PL_CHECKOUT/claude-sync" ]; then
  n="$(cat "$PL_CHECKOUT/claude-sync" "$DIR/lib/sync-clone.sh" | grep -c -E '^(pid_running|process_read|sc_pid_running)\(\)')"
  want "neither claude-sync nor lib/sync-clone.sh defines a pid reading of its own" 0 "$n"
else
  echo "SUITE-PART-UNMEASURED whether claude-sync keeps a pid reading of its own: this copy of the hooks is in no checkout of the repository"
fi
grep -q -E '^pid_running\(\)' "$LIB" && grep -q -E '^process_read\(\)' "$LIB" \
  && check "and lib/pid-lock.sh holds the one reading" ok || check "and lib/pid-lock.sh holds the one reading" "it does not define pid_running and process_read"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
