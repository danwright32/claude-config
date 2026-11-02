#!/usr/bin/env bash
# The shared process-tree kill, asked directly (claude-config#173).
#
# lib/kill-tree.sh arrived in #169 and was exercised only through its two callers. That is how its
# first real flaw survived: it printed what it killed to stdout, and since callers pass their OWN
# pid, capturing that output meant a subshell inside the tree being killed, which died before it
# could be read. It was found by hand, piping it into `sed` and watching the `sed` die.
#
# This is the code that decides which processes get killed during cleanup. Being wrong in the
# permissive direction kills something it should not, and being wrong in the other leaves a run's
# children holding the machine, which is the state #163 and #165 exist to end. Both directions are
# checked here rather than inferred from whether a caller happened to work.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

# Every wait on a condition gives up at the one ceiling only a hang reaches (lib/hang-wait.sh,
# claude-config#1679).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing, so this suite's waits have no ceiling."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$DIR/lib/kill-tree.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$TREE" ]; then
  echo "test-kill-tree: no helper at $TREE, so there was nothing to test." >&2
  printf 'SUITE-NOT-RUN %s\n' "the helper it tests is not present at $TREE"
  exit 2
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.killtree.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-kill-tree: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
cleanup(){
  # Everything this suite started, whatever happened. A test about leaked processes that leaks its
  # own is the defect it is testing.
  [ -n "${ALL_PIDS:-}" ] && kill -9 $ALL_PIDS 2>/dev/null
  rm -rf "$TMPROOT"
  return 0
}
ALL_PIDS=""
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

alive(){ kill -0 "$1" 2>/dev/null; }
# Waits for a condition rather than sleeping a guessed amount: a fixed sleep is a check on what
# else the machine is running (L224).
wait_gone(){   # wait_gone <pid>: 0 once it is gone, 1 at the hang ceiling (#1679)
  hang_wait "! alive $1"
}

# ---------------------------------------------------------------------------
# It reaches a GRANDCHILD, not just the children it can see directly.
# ---------------------------------------------------------------------------
# The whole reason a walk exists rather than one `pkill -P`. A cleanup that reaches one level down
# leaves the process that is actually holding something, which is what #171's negative control
# breaks on purpose.
victim="$TMPROOT/victim.sh"
mkfifo "$TMPROOT/hold" 2>/dev/null
{
  printf '#!/usr/bin/env bash\n'
  printf 'bash -c "sleep 300 & echo \\$! > \\"$1\\"/gc.pid; sleep 300" &\n'
  printf 'echo $! > "$1/child.pid"\n'
  printf 'echo $$ > "$1/self.pid"\n'
  # Blocked on a FIFO, not on a child, and deaf to the death of its children. Waiting on a `sleep`
  # makes this exit of its own accord the moment that sleep is killed, and even on a FIFO the read
  # is interrupted by the child dying and returns, ending the script. Either way "the root is still
  # alive" would be measuring the fixture rather than the helper, and both read as a real failure
  # before this was pinned down (L48).
  printf "trap '' CHLD\n"
  printf 'while :; do read -r _ < "$1/hold" 2>/dev/null && break; done\n'
} > "$victim"
# The root is this suite's own child, kept so the walk can be asked about it, and safe to keep
# (L1035, #2040): it is blocked on the FIFO with SIGCHLD ignored, so it ends only when this suite
# kills it below, and it is reaped on the same line, before another check is printed. A walk that
# wrongly took it would end it while this suite waits on the walk, which prints nothing.
bash "$victim" "$TMPROOT" &
v_root=$!
ALL_PIDS="$ALL_PIDS $v_root"
hang_wait '[ -s "$TMPROOT/child.pid" ] && [ -s "$TMPROOT/gc.pid" ]' 0.2
v_child="$(cat "$TMPROOT/child.pid" 2>/dev/null || true)"
v_gc="$(cat "$TMPROOT/gc.pid" 2>/dev/null || true)"
case "$v_child$v_gc" in ''|*[!0-9]*) v_child=""; v_gc="" ;; esac
ALL_PIDS="$ALL_PIDS $v_child $v_gc"
# The fixture is asserted to be real BEFORE anything acts on it. A tree that never got going
# satisfies every "it is gone" check below while proving nothing (L159).
if [ -n "$v_child" ] && [ -n "$v_gc" ] && alive "$v_child" && alive "$v_gc"; then
  check "the fixture really built a child and a grandchild" ok
else
  check "the fixture really built a child and a grandchild" "child='$v_child' gc='$v_gc' within the hang ceiling, ${HANG_S}s"
fi
bash "$TREE" "$v_root" "$TMPROOT/report" >/dev/null 2>&1
wait_gone "$v_gc"
alive "$v_gc" \
  && check "a grandchild is reached, not just the direct children" "pid $v_gc is still running" \
  || check "a grandchild is reached, not just the direct children" ok
alive "$v_root" \
  && check "and the process it was asked about is left alive" ok \
  || check "and the process it was asked about is left alive" "pid $v_root was killed, but only its DESCENDANTS were asked for"
kill -9 "$v_root" 2>/dev/null; wait "$v_root" 2>/dev/null
rm -f "$TMPROOT/hold"

# ---------------------------------------------------------------------------
# It never kills the process that called it.
# ---------------------------------------------------------------------------
# Two callers pass their OWN pid, so the walk finds the command that is doing the walking. Killing
# it means the cleanup dies half way through, having killed some of what it was asked to.
selftest="$TMPROOT/selftest.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'sleep 300 &\n'
  printf 'echo $! > "$2/own-child.pid"\n'
  printf 'bash "$1" $$ "" >/dev/null 2>&1\n'
  printf 'echo survived > "$2/survived"\n'
} > "$selftest"
bash "$selftest" "$TREE" "$TMPROOT"
s_child="$(cat "$TMPROOT/own-child.pid" 2>/dev/null || true)"
case "$s_child" in ''|*[!0-9]*) s_child="" ;; esac
ALL_PIDS="$ALL_PIDS $s_child"
[ -f "$TMPROOT/survived" ] \
  && check "a caller that asks about its own tree lives to see it finish" ok \
  || check "a caller that asks about its own tree lives to see it finish" "it did not reach the line after the call"
# WAITED for, not sampled once. The walk signals the child and returns; the kernel reaps it a
# moment later, so a single reading taken the instant the call returns is a reading of how busy the
# machine is. It failed on the CI runner on 2026-08-30 and the failure message printed alive=no,
# because the message re-read the state after the child had finished dying: a check whose own
# evidence contradicts it (L11, L290). Every other check in this file already uses wait_gone.
[ -n "$s_child" ] && wait_gone "$s_child"
if [ -n "$s_child" ] && ! alive "$s_child"; then
  check "and its own child was killed all the same" ok
else
  check "and its own child was killed all the same" "child='$s_child' alive=$(alive "${s_child:-1}" && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# A number that has been recycled since the list was taken is LEFT ALONE.
# ---------------------------------------------------------------------------
# The safety property. Process ids are reused, so a walk that kills whatever holds a number now
# rather than what held it then kills somebody's unrelated work (L157). Checked by asking it about
# a process whose children are not the ones being watched: the bystander is nobody's child of that
# parent, so it must survive.
# Both are this suite's own children, kept so they can be named, and safe to keep (L1035, #2040):
# they sleep far longer than this case takes, so they end only when killed below, and are reaped on
# the same line, before the next check is printed.
sleep 300 &
bystander=$!
ALL_PIDS="$ALL_PIDS $bystander"
sleep 300 &
other_parent=$!
ALL_PIDS="$ALL_PIDS $other_parent"
bash "$TREE" "$other_parent" "" >/dev/null 2>&1
# A window the passing case runs out (#1743): a wrong kill would show as the bystander gone.
window_wait 1 '! alive "$bystander"'; kt_spared=$?
[ "$kt_spared" = 1 ] && alive "$bystander" \
  && check "a process that is not a child of the named one is left alone" ok \
  || check "a process that is not a child of the named one is left alone" "pid $bystander was killed"
kill -9 "$bystander" "$other_parent" 2>/dev/null; wait "$bystander" "$other_parent" 2>/dev/null

# ---------------------------------------------------------------------------
# A process that is still running cannot replace what was just killed (#174).
# ---------------------------------------------------------------------------
# This is the fault that made a run hang for ever on 2026-08-22. A process stalled in
# `sleep 3600 & wait` had its sleep killed, its wait returned at once, and it started a new one
# before the walk had finished. Killing the parent then left the replacement as an orphan holding
# open the pipe its output was read through, so the reader never saw end of file.
respawn="$TMPROOT/respawn.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo $$ > "$1/respawn.pid"\n'
  printf 'while :; do sleep 300 & echo $! >> "$1/spawned"; wait "$!" || true; done\n'
} > "$respawn"
# This suite's own child, kept so it can be stopped and walked, and safe to keep (L1035, #2040): it
# loops until killed, and it is reaped straight after the kill below, before anything is printed.
bash "$respawn" "$TMPROOT" &
r_root=$!
ALL_PIDS="$ALL_PIDS $r_root"
hang_wait '[ -s "$TMPROOT/spawned" ]' 0.2
r_first="$(head -1 "$TMPROOT/spawned" 2>/dev/null || true)"
case "$r_first" in ''|*[!0-9]*) r_first="" ;; esac
[ -n "$r_first" ] && alive "$r_first" \
  && check "the respawning fixture really has a child to replace" ok \
  || check "the respawning fixture really has a child to replace" "first='$r_first' within the hang ceiling, ${HANG_S}s"
# What a caller killing a FOREIGN tree has to do, and what the watchdog does: stop the root so it
# cannot fork, then walk, then kill it.
kill -STOP "$r_root" 2>/dev/null
bash "$TREE" "$r_root" "" >/dev/null 2>&1
kill -9 "$r_root" 2>/dev/null; wait "$r_root" 2>/dev/null
# Waited on the condition the passing case meets, every child it spawned gone (#1743), never a fixed
# two seconds that a loaded Mac can outlast with a killed child not yet reaped (L290).
r_none_alive(){ local p; while IFS= read -r p; do case "$p" in ''|*[!0-9]*) continue ;; esac; alive "$p" && return 1; done < "$TMPROOT/spawned"; return 0; }
hang_wait r_none_alive 0.1
r_left=""
while IFS= read -r p; do
  case "$p" in ''|*[!0-9]*) continue ;; esac
  alive "$p" && r_left="$r_left $p"
done < "$TMPROOT/spawned"
ALL_PIDS="$ALL_PIDS $(tr '\n' ' ' < "$TMPROOT/spawned" 2>/dev/null)"
case "$r_left" in
  "") check "nothing it spawned survives the walk" ok ;;
  *)  check "nothing it spawned survives the walk" "still running:$r_left" ;;
esac

# And the pause is WHAT MAKES that true, rather than something that merely happened to be there
# while it worked. Asserted both ways round on the property itself: a running process replaces a
# killed child, a stopped one cannot. Without this the check above passes on a version that does no
# pausing at all, which is the gap #171 was filed about and this suite reproduced an hour later.
#
# The property is measured directly rather than by racing the walk. At this scale the race does not
# reproduce (measured: ten runs, both the in-line and the out-of-process walk, all clean), so a
# control built on winning or losing it would assert nothing and would read as if it had.
pair="$TMPROOT/pair.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'while :; do sleep 300 & echo $! >> "$1"; wait "$!" || true; done\n'
} > "$pair"
spawn_count(){ local n; n="$(grep -c . "$1" 2>/dev/null || true)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac; printf '%s' "$n"; }
for mode in running stopped; do
  list="$TMPROOT/spawn-$mode"
  : > "$list"
  # This suite's own child, kept so it can be stopped, and safe to keep (L1035, #2040): it loops
  # until killed, and it is reaped straight after the kill below, before either check is printed.
  bash "$pair" "$list" &
  p_root=$!
  ALL_PIDS="$ALL_PIDS $p_root"
  hang_wait '[ "$(spawn_count "$list")" -ge 1 ]' 0.2
  before="$(spawn_count "$list")"
  [ "$mode" = stopped ] && kill -STOP "$p_root" 2>/dev/null
  current="$(tail -1 "$list" 2>/dev/null || true)"
  case "$current" in ''|*[!0-9]*) current="" ;; esac
  [ -n "$current" ] && kill -9 "$current" 2>/dev/null
  # Never a fixed two seconds (#1743, L290). A running root replaces the child, which is waited for
  # as the condition it is; a stopped one must not, which is a window the passing case runs out.
  p_held=1
  if [ "$mode" = running ]; then
    hang_wait '[ "$(spawn_count "$list")" -gt "$before" ]' 0.1
  else
    window_wait 2 '[ "$(spawn_count "$list")" -gt "$before" ]'; p_held=$?
  fi
  after="$(spawn_count "$list")"
  kill -CONT "$p_root" 2>/dev/null
  kill -9 "$p_root" 2>/dev/null; wait "$p_root" 2>/dev/null
  while IFS= read -r p; do kill -9 "$p" 2>/dev/null; done < "$list"
  if [ "$mode" = running ]; then
    [ "$after" -gt "$before" ] \
      && check "a RUNNING process replaces a child that is killed under it ($before then $after)" ok \
      || check "a RUNNING process replaces a child that is killed under it" "count stayed at $after, so this fixture cannot show the difference"
  else
    [ "$p_held" = 1 ] && [ "$after" -eq "$before" ] \
      && check "and a STOPPED one cannot, which is what the pause buys ($before then $after)" ok \
      || check "and a STOPPED one cannot, which is what the pause buys" "count went $before to $after while stopped"
  fi
done

# ---------------------------------------------------------------------------
# It refuses an argument it cannot use, rather than guessing.
# ---------------------------------------------------------------------------
# This runs `kill -9` on numbers it is handed. A value it cannot read must never land on the
# permissive side of that (L50).
bash "$TREE" notapid >/dev/null 2>&1; rc_bad=$?
[ "$rc_bad" -ne 0 ] \
  && check "a process id that is not a number is refused" ok \
  || check "a process id that is not a number is refused" "it exited $rc_bad"
bash "$TREE" >/dev/null 2>&1; rc_none=$?
[ "$rc_none" -ne 0 ] \
  && check "and so is no argument at all" ok \
  || check "and so is no argument at all" "it exited $rc_none"
msg_bad="$(bash "$TREE" notapid 2>&1)"
case "$msg_bad" in
  *notapid*) check "and the refusal names the value it could not read" ok ;;
  *) check "and the refusal names the value it could not read" "said: $msg_bad" ;;
esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
