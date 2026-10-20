#!/usr/bin/env bash
# test-sleep-claim-notes.sh must pass however late each of its reads of the clock lands
# (claude-config#1391).
#
# That suite pins the night's clock (SLEEP_NOW_MS, SLEEP_REPORT_NOW_MS) to one reading, NOW, and the
# report counts an issue as closed tonight only up to NOW. Its fixture then read the clock a SECOND
# time to stamp issue 21's closedAt. Whenever the second ticked between the two reads, closedAt was
# a second past the night's end, #21 dropped out of Done, and "the done claim shows under Done"
# failed. Load is what widens the gap between two reads, so it failed only in full runs on a busy
# machine (load 27 to 47 on 12 cores, 2026-10-20) and passed when run again alone, which is how the
# runner came to call it FLAKY. Measured before the fix: 9 of 96 runs failed with 24 copies at once,
# every one on that check and nothing else.
#
# So this runs that suite against a clock that moves a whole second on EVERY read: the worst a
# loaded machine can do to it, made certain rather than left to chance (L290). Any check that leans
# on two reads agreeing fails here every time.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$DIR/test-sleep-claim-notes.sh"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

REAL_DATE="$(command -v date)"
if [ -z "$REAL_DATE" ]; then
  echo "FAIL: no date on PATH, so the moving clock has nothing to stand in front of"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
mkdir -p "$WORK/bin"
# Each read is the real time plus one second for every read before it, logged so the suite can be
# shown to have reached it. GNU date (CI) takes the time as -d @<seconds>, BSD date (macOS) as -r.
# Only a read of NOW is moved: a call with anything but -u and a +format (parsing a date, reading a
# file's time) is passed through untouched, since adding -r or -d to it would change its meaning.
cat > "$WORK/bin/date" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in -u|+*) ;; *) exec "$REAL_DATE" "\$@" ;; esac
done
n=\$(wc -l < "$WORK/reads" 2>/dev/null | tr -d ' ')
[ -n "\$n" ] || n=0
echo "\$*" >> "$WORK/reads"
t=\$(( \$("$REAL_DATE" +%s) + n ))
if "$REAL_DATE" --version >/dev/null 2>&1; then exec "$REAL_DATE" -d "@\$t" "\$@"; fi
exec "$REAL_DATE" -r "\$t" "\$@"
EOF
chmod +x "$WORK/bin/date"

# The inner suite's own deadline is turned off and handed its start, so the watchdog's reads of the
# clock neither move it nor land in the log: every read logged is the fixture's own. This suite's
# deadline still bounds the run, and stops whatever it started.
out="$(PATH="$WORK/bin:$PATH" SUITE_WALL_TIMEOUT=0 SUITE_WALL_STARTED="$("$REAL_DATE" +%s)" bash "$SUITE" 2>&1)"; rc=$?

if [ -s "$WORK/reads" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: the suite never read the moving clock, so nothing here was measured (it no longer calls date from PATH?)"
fi
result="$(printf '%s\n' "$out" | grep -E '^SUITE-RESULT ' | tail -1)"
if [ "$rc" -eq 0 ] && [[ "$result" =~ ^SUITE-RESULT\ passed=([0-9]+)\ failed=0$ ]] && [ "${BASH_REMATCH[1]}" -gt 0 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: test-sleep-claim-notes.sh fails when each read of the clock lands a second after the last (exit $rc, '$result'), so it fails at random on a loaded machine. Its reads were:"
  sed 's/^/    date /' "$WORK/reads" 2>/dev/null
  printf '%s\n' "$out" | grep -E '^FAIL' | cut -c1-400
fi

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
