#!/bin/bash
# headless-dom.sh <Chrome arguments...>: runs headless Chrome as given (its --dump-dom included) and
# prints the page it dumped, then ends Chrome, with a deadline that fails by name (#801, L110).
#
# Measured on Daniels-MacBook-Pro-2, 2026-10-05, Chrome 154: a --dump-dom run prints the whole page
# at once and then sits in its own teardown. Run plain, it printed the page and was ended by its own
# "Teardown watchdog expired" after 10 s (exit 2); given its own profile, it printed the page and was
# still running 40 s later. test-make-switcher.sh runs Chrome 18 times, so it paid 10 s or more on
# each and, run beside other suites, waited out its whole 1,200 s wall clock with nothing printed
# after the PICKER line. So the page is read as soon as it is complete (its closing </html>), and
# Chrome and every helper it started are ended then, never waited for.
#
# Each run gets a fresh profile folder of its own, so two suites running Chrome at once never meet
# on one profile's lock.
#
#   HEADLESS_DOM_CHROME    the Chrome binary to run (required)
#   HEADLESS_DOM_DEADLINE  seconds to wait for a complete page, default 60; past it this prints why
#                          on stderr and exits 124, with nothing on stdout
#
# Exit 0 with the page; 124 when no complete page came within the deadline; Chrome's own exit code
# when it ended without one, or 1 when that code was 0. Nothing is printed on stdout unless the page
# is complete.
set -u
REAL="${HEADLESS_DOM_CHROME:?headless-dom.sh: set HEADLESS_DOM_CHROME to the Chrome binary}"
LIMIT="${HEADLESS_DOM_DEADLINE:-60}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_TREE="$HERE/../../hooks/lib/kill-tree.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/headless-dom.XXXXXX")" || { echo "headless-dom.sh: could not make a scratch folder" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

"$REAL" --user-data-dir="$work/profile" --no-first-run --no-default-browser-check "$@" > "$work/out" 2> "$work/err" &
pid=$!
start=$SECONDS
state=running
while :; do
  if grep -q '</html>' "$work/out" 2>/dev/null; then state=complete; break; fi
  if ! kill -0 "$pid" 2>/dev/null; then state=ended; break; fi
  if [ $((SECONDS - start)) -ge "$LIMIT" ]; then state=late; break; fi
  sleep 0.1
done

rc=0
if [ "$state" = ended ]; then
  wait "$pid"; rc=$?
  # It may have finished the page in the same instant it exited.
  grep -q '</html>' "$work/out" 2>/dev/null && rc=0
else
  # Stopped first, so it cannot start another helper while its tree is walked (kill-tree.sh).
  kill -STOP "$pid" 2>/dev/null
  if [ -f "$KILL_TREE" ]; then bash "$KILL_TREE" "$pid"; else pkill -KILL -P "$pid" 2>/dev/null; fi
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
fi

if [ "$state" = late ]; then
  echo "headless-dom.sh: Chrome gave no complete page within ${LIMIT}s (HEADLESS_DOM_DEADLINE) and was ended. Its last words: $(tail -n 3 "$work/err" | tr '\n' ' ')" >&2
  exit 124
fi
# Ended on its own without a whole page: a failure whatever its exit status, because handing back
# half a page with a clean status reads as success to every caller (claude-config#677).
if [ "$state" = ended ] && ! grep -q '</html>' "$work/out" 2>/dev/null; then
  echo "headless-dom.sh: Chrome ended without a complete page (exit $rc). Its last words: $(tail -n 3 "$work/err" | tr '\n' ' ')" >&2
  [ "$rc" -ne 0 ] && exit "$rc"
  exit 1
fi
cat "$work/out"
exit "$rc"
