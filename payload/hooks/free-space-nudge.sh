#!/usr/bin/env bash
#
# free-space-nudge.sh: put check-free-space.sh on a real event (claude-config#363).
#
# A check nothing invokes fires only when somebody types the command, which for this one is the
# occasion it adds nothing: a person typing it already suspects the disk. Built is not wired (L3).
# The failure it exists to catch is silent by nature, and on 2026-09-10 the first sign of a full
# disk inside Claude Code was an unrelated hook failing on a temp file it could not create.
#
# So it runs on UserPromptSubmit, the same shape project-list-nudge.sh and rule-files-changed.sh
# use for the same reason (L175): there is no event inside the program for "the disk filled up",
# so a prompt is the thing to hang it on.
#
# The verdict comes from check-free-space.sh rather than being worked out again here, so there is
# one implementation of the question and no second one to drift beside it (L107). This file decides
# only WHEN to speak.
#
# ONE notice per distinct answer per session, and "distinct" is the verdict plus how much is left,
# rounded down to the nearest 5 GB. That is deliberate on both sides. A notice on every prompt is
# the noise the warning exists to escape, and would teach a reader to skip it (L36). But a disk
# that goes on falling is not the same answer as one that has stopped, and going quiet about it
# would leave the most urgent case saying least (L152). So it is quiet while nothing changes, and
# speaks again for every further 5 GB lost. A new session hears it too: that session has been told
# nothing and loaded nothing.
#
# It NEVER blocks the prompt. A UserPromptSubmit hook exiting non-zero stops the turn, and a
# filling disk is something to mention, not a reason to refuse to work (L54). Every path exits 0.
#
# Environment:
#   FREE_SPACE_*                 passed straight through to the check, which owns all of them
#   FREE_SPACE_NUDGE_STATE_DIR   where the per session record is kept (default TMPDIR). A
#                                DIRECTORY, so two sessions at once each get their own and neither
#                                is told about the other's answer.
set -uo pipefail

input="$(cat 2>/dev/null || true)"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-free-space.sh"
[ -f "$CHECK" ] || exit 0

# The answer, and its exit code, which is what separates the four outcomes. Judged by the CODE and
# never by a line of the output (L184).
answer="$(bash "$CHECK" 2>&1)"; verdict=$?

# 0 is measured, and there is room. Nothing to say.
[ "$verdict" -eq 0 ] && exit 0

session="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print(d.get("session_id") or d.get("transcript_path") or "")
' 2>/dev/null || true)"
[ -n "$session" ] || session="no-session"
session="$(printf '%s' "$session" | tr -c 'A-Za-z0-9' '_')"

STATE_DIR="${FREE_SPACE_NUDGE_STATE_DIR:-${TMPDIR:-/tmp}/claude-free-space-nudge}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/$session"

# What counts as the same answer. The GB figure is taken from the check's own sentence rather than
# measured again here, so the two cannot disagree about what was reported (L70). A verdict carrying
# no figure (the check could not measure) keys on the verdict alone, which is right: there is one
# such answer and repeating it every prompt would say nothing new.
# Pure shell rather than a pipeline into `head`. A short circuiting consumer kills its producer,
# and under pipefail that is a failure that never happened, which this repo tracks as a hazard of
# its own (L183). There is nothing to pipe here anyway: the figure is the word before the phrase.
gb=""
case "$answer" in
  *" GB free on "*)
    gb="${answer%% GB free on *}"
    gb="${gb##* }"
    ;;
esac
case "$gb" in ''|*[!0-9]*) key="$verdict" ;; *) key="$verdict-$((gb / 5))" ;; esac

if [ -f "$STATE" ] && [ "$(cat "$STATE" 2>/dev/null || true)" = "$key" ]; then
  exit 0
fi
printf '%s' "$key" > "$STATE" 2>/dev/null || true

# The remedy is named, and it is a skill rather than a sequence written out here, because the
# sequence is long, it has to be ready before the disk is full, and a message is not where it can
# live (L111: name an action that changes the state they are stuck in).
echo "$answer"
# Xcode's build caches whose project folder is gone (claude-config#1369): the one leak that is
# measured rather than suspected, since every agent worktree starts a cache of its own and nothing
# removes it. Which folders those are is decided by derived-data-sweep.sh, the one copy of the orphan
# rule (L370). Asked only here, once the notice is going to be said, never on every prompt.
#
# CLEARED ON ITS OWN, by Dan's decision on #1369 (2026-10-20, L9): when this warning fires it starts
# the sweep, which deletes only orphans nothing has written to in the last hour or is building with,
# and keeps every cache whose project is still on disk, on a volume that is not mounted, or that no
# info.plist attributes. It never deletes in this hook's own time: `--start` takes the sweep's lock
# and hands the work to a detached process in a session of its own, so the hook returns at once and
# its 10 second timeout can neither wait on the deletion nor kill it (L235, L240). A warning while a
# sweep runs starts no second one. What the last sweep did, freed, failed or died partway, is read
# back with `--last` the next time this speaks (L13, L98).
#
# FREE_SPACE_DERIVED_DATA_AUTO_DELETE=0 turns the deletion off for one Mac; this then falls back to
# the count and the commands (`--summary`). Any value but 0 or 1 is said and treated as off, so a
# switch nobody can read never deletes (L50). Off is said every time this speaks, so it is never a
# suppression nobody can find (L523).
#
# The whole Xcode step is bounded, by FREE_SPACE_DERIVED_DATA_SECONDS (default 6), shared by its
# calls rather than given to each, and 0 turns the step off. The count reads each folder's info.plist and forks a reader per folder, and a
# hook killed at its 10 second timeout would lose the free space warning with it (both are settings,
# not measurements). The call runs in a process group of its own and the WHOLE group is killed when
# the bound runs out: killing only the sweep left its children (du, the plist reader) holding this
# capture open until they finished, which the suite caught as a 1 second bound taking 5 (L235,
# L321). A call stopped by it says so rather than saying nothing (L98).
SWEEP="${FREE_SPACE_DERIVED_DATA_SWEEP:-$DIR/derived-data-sweep.sh}"
SWEEP_SECONDS="${FREE_SPACE_DERIVED_DATA_SECONDS:-6}"
case "$SWEEP_SECONDS" in ''|*[!0-9]*) SWEEP_SECONDS=6 ;; esac
AUTO_DELETE="${FREE_SPACE_DERIVED_DATA_AUTO_DELETE-1}"
LIST_CMD="bash ~/.claude/hooks/derived-data-sweep.sh"

bounded_sweep() {   # bounded_sweep <seconds> <args...> -> sets SWEEP_OUT and SWEEP_RC (124 when the bound ran out)
  local seconds="$1"; shift
  SWEEP_RC=0
  SWEEP_OUT="$(perl -e '
    my $t = shift @ARGV;
    my $pid = fork();
    exit 127 unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
    local $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid($pid, 0); exit 124; };
    alarm $t;
    waitpid($pid, 0);
    alarm 0;
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);' "$seconds" bash "$SWEEP" "$@" 2>&1)" || SWEEP_RC=$?
}

summary() {
  bounded_sweep "$SWEEP_SECONDS" --summary
  if [ "$SWEEP_RC" -eq 124 ]; then
    echo "Counting Xcode build caches whose project folder is gone did not finish within ${SWEEP_SECONDS}s, so how many there are is not known here. To list them: $LIST_CMD"
  elif [ -n "$SWEEP_OUT" ]; then
    printf '%s\n' "$SWEEP_OUT"
  fi
}

# 0 turns the step off. perl's `alarm 0` would cancel the bound instead, leaving it unbounded.
if [ -f "$SWEEP" ] && [ "$SWEEP_SECONDS" -gt 0 ]; then
  case "$AUTO_DELETE" in
    1)
      # ONE budget for the whole step, never one per call: two calls each given the full bound would
      # add up to twice it, 12 seconds at the default, past the hook's 10 second timeout. --start gets
      # only what --last left, and none left means it is not tried, which is said.
      step_start="$(date +%s)"
      bounded_sweep "$SWEEP_SECONDS" --last
      if [ "$SWEEP_RC" -eq 124 ]; then
        echo "Reading what the last automatic sweep of Xcode build caches did did not answer within ${SWEEP_SECONDS}s, so it is not known here. To see it: $LIST_CMD --last"
      elif [ -n "$SWEEP_OUT" ]; then
        printf '%s\n' "$SWEEP_OUT"
      fi
      left=$(( SWEEP_SECONDS - ($(date +%s) - step_start) ))
      if [ "$left" -gt 0 ]; then
        bounded_sweep "$left" --start
      else
        SWEEP_RC=-1
      fi
      case "$SWEEP_RC" in
        -1) echo "Reading the last sweep's record used all ${SWEEP_SECONDS}s this warning allows, so no time was left to start a new sweep of Xcode build caches; the next warning tries again. To list them: $LIST_CMD" ;;
        0)
          echo "Started clearing Xcode build caches whose project folder is gone, in the background. It deletes only those nothing has written to in the last hour or is building with, and keeps any whose project is still on disk or on a drive that is not mounted. The next warning says what it freed, and so does: $LIST_CMD --last"
          echo "To stop this deleting on its own on this Mac, set FREE_SPACE_DERIVED_DATA_AUTO_DELETE=0 (the README's section on Xcode build caches says where)." ;;
        75) echo "A sweep of Xcode build caches whose project folder is gone is already running, so this warning did not start another. The next warning says what it freed." ;;
        3) ;;   # no DerivedData on this Mac: nothing to sweep and nothing to say
        124) echo "Starting the automatic sweep of Xcode build caches did not answer within ${SWEEP_SECONDS}s, so whether it started is not known. To see: $LIST_CMD --last" ;;
        *) echo "The automatic sweep of Xcode build caches could not be started (it exited $SWEEP_RC)${SWEEP_OUT:+: $SWEEP_OUT}. To list them: $LIST_CMD" ;;
      esac ;;
    0)
      echo "Automatic deletion of orphaned Xcode build caches is off on this Mac (FREE_SPACE_DERIVED_DATA_AUTO_DELETE=0)."
      summary ;;
    *)
      echo "FREE_SPACE_DERIVED_DATA_AUTO_DELETE is set to '$AUTO_DELETE', which is neither 0 nor 1, so automatic deletion of orphaned Xcode build caches is off on this Mac."
      summary ;;
  esac
fi
echo "What to do about it is the disk-full skill, which holds the measured triage sequence. It takes readings before it names anything, because a static size cannot say what is filling the disk."
exit 0
