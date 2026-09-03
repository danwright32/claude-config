#!/usr/bin/env bash
# The warning that the payload is being edited in a checkout the daemon will revert
# (claude-config#279).
#
# On 2026-09-03 most of a day's work was made in the development checkout and pushed, and at 11:03
# the watch daemon on the SAME Mac mirrored its ~/.claude up over payload/ and reverted 84 files in
# one commit, deleting lib/match-open-issues.py outright, because a file that exists only in the
# repo is one the mirror has never heard of and it runs with --delete. Nothing warned before it and
# the tests passed afterwards, because they were reverted alongside the code they covered. It was
# found by an unrelated ratchet days later. The rule was written into DESIGN.md, which is a rule in
# prose and therefore a hope (L27).
#
# Every case here drives the real hook. The watcher is a REAL process with a real command line
# rather than a stub of `ps`, because what the hook has to get right is reading a live process
# (L52), and the two ways that goes wrong, a pid that is dead and a pid the system has handed to
# something else, are both cases here (L237).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/payload-revert-warning.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "test-payload-revert-warning: there is no payload-revert-warning.sh beside this suite at $DIR, so nothing could be run." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs payload-revert-warning.sh beside it, and $DIR does not hold one"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/payload-revert-warning.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"; [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; true' EXIT

# Two clones of the tool: the development checkout, and the one the daemon runs from. Each is a
# directory holding a claude-sync and a payload/, which is what makes it a clone of this tool.
mkdir -p "$FIX/dev/payload/hooks" "$FIX/src/payload/hooks" "$FIX/state" "$FIX/elsewhere"
: > "$FIX/dev/claude-sync"
: > "$FIX/src/claude-sync"

HOLD="$FIX/hold"
PIDF="$FIX/watch.pid"

# A REAL process whose command line is the one the daemon has. `exec -a` puts the script path and
# the subcommand into argv, so `ps -o command=` reads exactly what it reads for the live daemon,
# and it is a single process, so killing the pid leaves nothing behind (L321).
bash -c 'exec -a "'"$FIX"'/src/claude-sync watch" sleep 300' &
WPID=$!
# Wait for the process to be readable rather than sleeping a fixed time, so the suite is not timing
# the machine's load (L290).
for _ in $(seq 1 200); do
  case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in *claude-sync*watch*) break ;; esac
done
case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in
  *claude-sync*watch*) ;;
  *)
    echo "test-payload-revert-warning: the fixture watcher process never showed a claude-sync watch command line, so the hook could not be asked anything." >&2
    printf 'SUITE-NOT-RUN %s\n' "the fixture watcher process could not be started with a readable command line"
    echo "passed: $pass, failed: $fail"
    printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
    exit 2 ;;
esac
printf '%s\n' "$WPID" > "$PIDF"

run(){ # run <session> <cwd> [pid-file] -> the hook's stdout
  local sess="$1" cwd="$2" pidf="${3:-$PIDF}"
  printf '{"session_id":"%s","cwd":"%s"}' "$sess" "$cwd" \
    | env SYNC_WATCH_PID_FILE="$pidf" SYNC_HOLD_FILE="$HOLD" \
          CLAUDE_PAYLOAD_WARN_STATE_DIR="$FIX/state" bash "$HOOK" 2>/dev/null
}
fresh(){ rm -f "$FIX/state"/* 2>/dev/null; }

# ---------------------------------------------------------------------------
# It speaks, on the FIRST prompt, which is the whole point: before the day's work rather than after
# it. This is deliberately unlike rule-files-changed.sh, which re-seeds quietly on a first prompt
# because its subject is a CHANGE. Here the condition itself is the report.
fresh
out1="$(run s1 "$FIX/dev")"
case "$out1" in
  *"$FIX/dev"*) check "#279 the development checkout is named" ok ;;
  *)            check "#279 the development checkout is named" "out=$out1" ;;
esac
case "$out1" in
  *"claude-sync hold"*) check "#279 and the notice names the hold command" ok ;;
  *)                    check "#279 and the notice names the hold command" "out=$out1" ;;
esac
case "$out1" in
  *"$FIX/src"*) check "#279 and the clone the daemon runs from is named" ok ;;
  *)            check "#279 and the clone the daemon runs from is named" "out=$out1" ;;
esac
# The half a hold does not solve: a hold expires, and if ~/.claude was never made to match, the
# next send reverts the work anyway. A notice that stops at the hold teaches half the remedy (L111).
case "$out1" in
  *".claude"*) check "#279 and it says the config directory must be made to match afterwards" ok ;;
  *)           check "#279 and it says the config directory must be made to match afterwards" "out=$out1" ;;
esac

# ONE notice per state, not one per prompt: the noise it exists to prevent (the sibling rule).
out2="$(run s1 "$FIX/dev")"
[ -z "$out2" ] \
  && check "#279 a second prompt in the same state is quiet" ok \
  || check "#279 a second prompt in the same state is quiet" "out=$out2"

# A DIFFERENT session gets its own notice: two sessions open at once must each be told (the state
# is keyed on the session, as the sibling's is).
out3="$(run s2 "$FIX/dev")"
[ -n "$out3" ] \
  && check "#279 a second session is told as well" ok \
  || check "#279 a second session is told as well" "it said nothing"

# ---------------------------------------------------------------------------
# A hold is the remedy, so it must silence it, and its EXPIRY must bring it back. A hold that runs
# out while a session is still editing is the same loss with a delay on it.
fresh
printf '%s %s host held for a reason\n' "$(( $(date +%s) + 3600 ))" "$(date +%s)" > "$HOLD"
out4="$(run s1 "$FIX/dev")"
[ -z "$out4" ] \
  && check "#279 a live hold silences it" ok \
  || check "#279 a live hold silences it" "out=$out4"

printf '%s %s host held for a reason\n' "$(( $(date +%s) - 60 ))" "$(( $(date +%s) - 3660 ))" > "$HOLD"
out5="$(run s1 "$FIX/dev")"
[ -n "$out5" ] \
  && check "#279 and it speaks again once that hold has expired" ok \
  || check "#279 and it speaks again once that hold has expired" "it stayed quiet"

# Reading the marker must not CLEAR it. claude-sync's own hold_remaining deletes an expired or
# unreadable marker, which is right for the tool and wrong for a hook: a hook that removes a
# decision somebody made destroys state it does not own (L5).
[ -f "$HOLD" ] \
  && check "#279 and reading an expired hold does not delete the marker" ok \
  || check "#279 and reading an expired hold does not delete the marker" "the hook removed $HOLD"

printf 'not a number at all\n' > "$HOLD"
fresh
out6="$(run s1 "$FIX/dev")"
[ -f "$HOLD" ] \
  && check "#279 and an unreadable hold marker is left where it is" ok \
  || check "#279 and an unreadable hold marker is left where it is" "the hook removed $HOLD"
# An unreadable marker is not a hold: obeying it would stop the notice for as long as the bad file
# sits there, which is the direction that loses work (L11, fail closed).
[ -n "$out6" ] \
  && check "#279 and an unreadable hold marker does not pass for a hold" ok \
  || check "#279 and an unreadable hold marker does not pass for a hold" "it stayed quiet"
rm -f "$HOLD"

# ---------------------------------------------------------------------------
# Every reason there is nothing to warn about, each of which must be silent.
fresh
out7="$(run s1 "$FIX/src")"
[ -z "$out7" ] \
  && check "#279 editing the clone the daemon runs from is not warned about" ok \
  || check "#279 editing the clone the daemon runs from is not warned about" "out=$out7"

fresh
out8="$(run s1 "$FIX/elsewhere")"
[ -z "$out8" ] \
  && check "#279 a directory that is not a clone of this tool is not warned about" ok \
  || check "#279 a directory that is not a clone of this tool is not warned about" "out=$out8"

fresh
out9="$(run s1 "$FIX/dev" "$FIX/nosuchpidfile")"
[ -z "$out9" ] \
  && check "#279 with no watcher there is nothing to revert the work" ok \
  || check "#279 with no watcher there is nothing to revert the work" "out=$out9"

# A pid that is DEAD, and a pid the system has handed to something else. Both read as a live
# watcher to anything that trusts the number in the file (L237, L70).
fresh
printf '%s\n' "999999" > "$FIX/deadpid"
out10="$(run s1 "$FIX/dev" "$FIX/deadpid")"
[ -z "$out10" ] \
  && check "#279 a stale pid is not a live watcher" ok \
  || check "#279 a stale pid is not a live watcher" "out=$out10"

fresh
printf '%s\n' "$$" > "$FIX/otherpid"
out11="$(run s1 "$FIX/dev" "$FIX/otherpid")"
[ -z "$out11" ] \
  && check "#279 a live pid that is not a claude-sync watcher is not one either" ok \
  || check "#279 a live pid that is not a claude-sync watcher is not one either" "out=$out11"

# The control for all six silences above: with the fixture back in its warning state the hook still
# speaks, so a silence above is the condition under test rather than a hook that says nothing at
# all (L159).
fresh
out12="$(run s1 "$FIX/dev")"
[ -n "$out12" ] \
  && check "#279 and the fixture still warns once the reason for silence is removed" ok \
  || check "#279 and the fixture still warns once the reason for silence is removed" "it stayed quiet"

# A subdirectory of the checkout is the same checkout: a session is rarely sitting at the root.
fresh
out13="$(run s1 "$FIX/dev/payload/hooks")"
[ -n "$out13" ] \
  && check "#279 a subdirectory of the checkout is the same checkout" ok \
  || check "#279 a subdirectory of the checkout is the same checkout" "it stayed quiet"

# ---------------------------------------------------------------------------
# No session id means a first prompt cannot be told from a later one. Said on stderr and passed
# over, rather than reported as a clean answer (L98), matching the sibling hook exactly.
fresh
err14="$(printf '{"cwd":"%s"}' "$FIX/dev" \
  | env SYNC_WATCH_PID_FILE="$PIDF" SYNC_HOLD_FILE="$HOLD" \
        CLAUDE_PAYLOAD_WARN_STATE_DIR="$FIX/state" bash "$HOOK" 2>&1 >/dev/null)"
case "$err14" in
  *session*) check "#279 a payload with no session says so rather than reporting silence" ok ;;
  *)         check "#279 a payload with no session says so rather than reporting silence" "err=$err14" ;;
esac

# ---------------------------------------------------------------------------
# And the wiring, in the same suite, because a check nothing invokes is the defect this closes
# (L3, L27). Same two places as the sibling: the shipped settings in the checkout, the installed
# ones on a deployed Mac.
SETTINGS_DIR="${PAYLOAD_REVERT_SETTINGS_DIR:-$DIR/..}"
SETTINGS=""
SETTINGS_KIND=""
if [ -f "$SETTINGS_DIR/settings.hooks.json" ]; then
  SETTINGS="$SETTINGS_DIR/settings.hooks.json"; SETTINGS_KIND="the settings the sync ships"
elif [ -f "$SETTINGS_DIR/settings.json" ]; then
  SETTINGS="$SETTINGS_DIR/settings.json"; SETTINGS_KIND="the settings installed on this Mac"
fi
if [ -z "$SETTINGS" ]; then
  echo "test-payload-revert-warning: neither settings.hooks.json nor settings.json is in $SETTINGS_DIR, so nothing there states which hooks are registered and the wiring could not be checked." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the settings file that registers the hook, and $SETTINGS_DIR holds neither settings.hooks.json nor settings.json"
else
  grep -F 'payload-revert-warning.sh' "$SETTINGS" > /dev/null \
    && check "the hook is named in $SETTINGS_KIND" ok \
    || check "the hook is named in $SETTINGS_KIND" "$(basename "$SETTINGS") does not mention payload-revert-warning.sh"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
