#!/usr/bin/env bash
# Tests for the four questions every hook about a config CHECKOUT asks (claude-config#367).
#
# payload-revert-warning.sh worked these out for itself, and payload-write-gate.sh needs the same
# four. Two copies of "is a hold in force" would be two answers to one question, each reading as
# correct on its own, which is the shape this repo keeps finding (L370). Both hooks have their own
# suites and drive these through a hook payload; this one drives the contract directly, because a
# shared helper's callers each exercise the cases THEY care about and nothing exercises the rest.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/sync-clone.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
yes(){ if "$@"; then check "$DESC" ok; else check "$DESC" "it answered no"; fi; }
no(){  if "$@"; then check "$DESC" "it answered yes"; else check "$DESC" ok; fi; }
want(){ if [ "$2" = "$3" ]; then check "$1" ok; else check "$1" "wanted '$2', got '$3'"; fi; }

[ -f "$LIB" ] || { echo "FAIL: no lib at $LIB"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/sync-clone.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"; [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; true' EXIT

export SYNC_HOLD_FILE="$FIX/hold"
export SYNC_WATCH_PID_FILE="$FIX/watch.pid"
# shellcheck source=lib/sync-clone.sh
. "$LIB"

echo "sync clone: where a clone of the tool starts"

mkdir -p "$FIX/clone/payload/hooks" "$FIX/notaclone/payload" "$FIX/bare" "$FIX/x/a/b/payload"
: > "$FIX/clone/claude-sync"
: > "$FIX/x/a/b/claude-sync"
want "a subdirectory resolves to the clone root" "$FIX/clone" "$(sc_clone_root_of "$FIX/clone/payload/hooks" || true)"
want "the root itself resolves to itself" "$FIX/clone" "$(sc_clone_root_of "$FIX/clone" || true)"
# BOTH have to be there. A directory holding only one of them is some other project, and treating
# it as a clone would make every guard built on this fire in the wrong repository.
want "a payload with no claude-sync beside it is not a clone" "" "$(sc_clone_root_of "$FIX/notaclone/payload" || true)"
want "a directory that is neither is not a clone" "" "$(sc_clone_root_of "$FIX/bare" || true)"
want "a directory that is not there answers nothing" "" "$(sc_clone_root_of "$FIX/no/such/dir" || true)"

echo "sync clone: which clone a live watcher runs from"

# The boundary is the point: without it a watcher at /x/a/b/claude-sync answers for a clone at
# /a/b, and every guard built on this goes quiet on the checkout it exists for.
DESC="a watcher command line matches its own clone"
yes sc_is_this_clone "$FIX/x/a/b" "$FIX/x/a/b/claude-sync watch"
DESC="and does not match a clone whose path is a suffix of it"
no sc_is_this_clone "/a/b" "$FIX/x/a/b/claude-sync watch"
DESC="and matches when the path is not the first argument"
yes sc_is_this_clone "$FIX/clone" "/bin/bash $FIX/clone/claude-sync watch"
DESC="and does not match a different clone"
no sc_is_this_clone "$FIX/clone" "$FIX/x/a/b/claude-sync watch"

echo "sync clone: whether a watcher is actually alive"

DESC="with no pid file there is no watcher"
no sc_watcher_cmd
# A REAL process with a real command line: a stub would only confirm this suite's own assumption
# about what ps returns (L52).
bash -c 'exec -a "'"$FIX"'/clone/claude-sync watch" sleep 120' &
WPID=$!
for _ in $(seq 1 200); do
  case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in *claude-sync*watch*) break ;; esac
done
printf '%s\n' "$WPID" > "$SYNC_WATCH_PID_FILE"
case "$(sc_watcher_cmd || true)" in
  *claude-sync*watch*) check "a live watcher is found, with its command line" ok ;;
  *) check "a live watcher is found, with its command line" "got '$(sc_watcher_cmd || true)'" ;;
esac
# A stale pid is reused by the system constantly, and a number alone cannot tell a live watcher
# from whatever inherited it (L237).
printf '%s\n' "999999" > "$SYNC_WATCH_PID_FILE"
DESC="a dead pid is not a live watcher"
no sc_watcher_cmd
# A live pid whose process is something else entirely: the pid file alone would say yes.
printf '%s\n' "$$" > "$SYNC_WATCH_PID_FILE"
DESC="a live pid that is not a watcher is not a watcher"
no sc_watcher_cmd
printf 'not a number\n' > "$SYNC_WATCH_PID_FILE"
DESC="a pid file holding no number is not a watcher"
no sc_watcher_cmd

echo "sync clone: whether a hold is in force"

rm -f "$SYNC_HOLD_FILE"
DESC="no marker is no hold"
no sc_hold_live
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$SYNC_HOLD_FILE"
DESC="a marker in the future is a hold"
yes sc_hold_live
printf '%s\n' "$(( $(date +%s) - 1 ))" > "$SYNC_HOLD_FILE"
DESC="a marker in the past is not"
no sc_hold_live
# An unreadable marker is NOT a hold. Reading one as a hold would silence every guard built on this
# for as long as the bad file sits there, and that is the direction that loses a day of work (L42).
printf 'soon\n' > "$SYNC_HOLD_FILE"
DESC="a marker nothing can read is not a hold"
no sc_hold_live
: > "$SYNC_HOLD_FILE"
DESC="an empty marker is not a hold"
no sc_hold_live
# And it never clears the marker: that is a decision somebody made, and claude-sync owns reporting
# and removing it (L5).
printf 'soon\n' > "$SYNC_HOLD_FILE"
sc_hold_live || true
check "and reading it leaves it exactly where it was" \
  "$([ -f "$SYNC_HOLD_FILE" ] && [ "$(cat "$SYNC_HOLD_FILE")" = "soon" ] && echo ok || echo 'the marker was changed or removed')"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
