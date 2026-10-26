#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/
# No suite hand rolls a wall clock wait (claude-config#1679).
#
# A wait on a condition needs a ceiling, or a broken fixture hangs the suite instead of failing it,
# and that ceiling must be one only a hang reaches: a `sleep 0.1` loop of a few hundred ticks, or a
# `$SECONDS` plus a few seconds, is reached by a loaded Mac with nothing broken (L290). #1577, #1620
# and #1679 moved every such wait onto lib/hang-wait.sh; this fails the next one on the day it lands
# (L613), with no list of suites excused from it. A wait whose PASSING case runs to its end (a window
# in which a fault would show) is a different thing: it calls window_wait, captures its status in the
# same statement (`; NAME=$?`) and asserts that status is 1, or the scan reports it (#1721).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/lib/hand-rolled-wait.py"
# The checkout this copy is the payload of, found by the one shared test (lib/checkout-root.sh,
# claude-config#1567): a repository above that is not this one is no checkout.
ROOT="${HAND_ROLLED_WAIT_ROOT:-$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-hand-rolled-wait: $DIR/.. is not the payload of a claude-config checkout, so there were no files of this repository to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read its files, and $DIR/.. is not the payload of a claude-config checkout"
  exit 2
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/hand-rolled-wait.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-hand-rolled-wait: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# The scan has to see every spelling of one, and none of the things that are not one, before the
# tree is asked (L1). The loop words are ASSEMBLED, so this file holds no wait for the scan to find.
# ---------------------------------------------------------------------------
_W='whi''le'; _U='unt''il'; _F='fo''r'; _S='sle''ep'; _WW='window''_wait'
mkdir -p "$TMPROOT/payload/hooks"
{
  printf '#!/usr/bin/env bash\n'
  # Five that are: a tick count on one line, a tick count over several, the clock two ways, and a
  # for loop over seq.
  printf 'n=0; %s [ ! -e "$f" ] && [ "$n" -lt 300 ]; do %s 0.1; n=$((n + 1)); done\n' "$_W" "$_S"
  printf 'ticks=0\n%s [ "$ticks" -lt "$(( $2 * 10 ))" ]; do\n  [ -e "$f" ] && break\n  %s 0.1; ticks=$((ticks + 1))\ndone\n' "$_W" "$_S"
  printf 't0=$SECONDS; %s [ -e "$f" ] || [ $((SECONDS - t0)) -ge 5 ]; do %s 0.1; done\n' "$_U" "$_S"
  printf 'end=$(( $(date +%%s) + 20 )); %s [ "$(date +%%s)" -lt "$end" ]; do [ -e "$f" ] && break; %s 1; done\n' "$_W" "$_S"
  printf '%s _ in $(seq 1 200); do [ -s "$f" ] && break; %s 0.05; done\n' "$_F" "$_S"
  # And nine that are not.
  printf 'hang_wait "[ -e %s ]"\n' "'\$f'"
  printf '%s 2 "[ -e %s ]"; ww=$?; [ "$ww" = 1 ] || echo FAIL\n' "$_WW" "'\$f'"
  printf 't0=$SECONDS; %s [ ! -e "$h" ] && [ $((SECONDS - t0)) -lt "${FAKE_HANG_S:-300}" ]; do %s 0.1; done\n' "$_W" "$_S"
  printf '%s [ ! -e "$f" ]; do %s 0.1; done\n' "$_U" "$_S"
  printf '%s [ "$(calls)" -lt 3 ]; do %s 0.1; done\n' "$_W" "$_S"
  printf 'i=0; %s [ "$i" -lt 300 ]; do own_review "$i"; i=$((i + 1)); done\n' "$_W"
  printf '  # %s [ "$n" -lt 5 ]; do %s 1; n=$((n + 1)); done   <- a comment about one\n' "$_W" "$_S"
  printf "RETRY='attempt=0\n%s [ \"\$attempt\" -lt 3 ]; do\n  %s 1; attempt=\$(( attempt + 1 ))\ndone'\n" "$_W" "$_S"
  # A retry over a written list, perl's sleep, and a python stand in's clock: waits by other names.
  printf '%s a in 1 2 3; do try && break; %s 1; done\n' "$_F" "$_S"
  printf '%s _ in 1 2 3 4 5; do [ -s "$f" ] && break; perl -e %s; done\n' "$_F" "'select(undef,undef,undef,0.1)'"
  printf '%s _ in $(seq 1 200); do printf .; %s 0.1; done\n' "$_F" "$_S"
  printf "python3 - <<'PY'\nimport os, time\nt0 = time.time()\n"
  printf '%s not os.path.exists(p) and time.time() - t0 < 60:\n    time.%s(0.05)\n' "$_W" "$_S"
  printf '%s _ in range(200):\n    time.%s(0.1)\nPY\n' "$_F" "$_S"
  # And a stand in written by printf, its loop after a newline escape (found in test-merge-target.sh).
  printf '%s\n' "printf '#!/bin/bash\\nk=0\\n${_W} [ -d \"\$1\" ] && [ \"\$k\" -lt 50 ]; do ${_S} 0.1; k=\$((k + 1)); done\\n' > stub"
} > "$TMPROOT/payload/hooks/test-probe.sh"
# The same text in a file that is not a suite is not judged.
cp "$TMPROOT/payload/hooks/test-probe.sh" "$TMPROOT/payload/hooks/probe-helper.sh"
probe="$(printf 'payload/hooks/test-probe.sh\npayload/hooks/probe-helper.sh\n' | python3 "$SCAN" --root "$TMPROOT")"; probe_rc=$?
probe_lines="$(printf '%s\n' "$probe" | awk -F: 'NF { printf "%s ", $2 }')"
[ "$probe_rc" = 1 ] && [ "$probe_lines" = "2 4 8 9 10 22 23 28 33 " ] \
  && check "the scan sees every spelling of a hand rolled wait, and none of what is not one" ok \
  || check "the scan sees every spelling of a hand rolled wait, and none of what is not one" "exit $probe_rc, lines '$probe_lines' where 2 4 8 9 10 22 23 28 33 were wanted:
$probe"
clean="$(printf 'payload/hooks/probe-helper.sh\n' | python3 "$SCAN" --root "$TMPROOT")"; clean_rc=$?
[ "$clean_rc" = 0 ] && [ -z "$clean" ] \
  && check "and finding nothing, it says nothing and exits 0" ok \
  || check "and finding nothing, it says nothing and exits 0" "exit $clean_rc: $clean"

# ---------------------------------------------------------------------------
# window_wait is for a window the PASSING case runs out, so its length is the caller's and short
# (claude-config#1721). Called to wait for something the passing case DOES meet, it is the short
# wall clock ceiling this scan exists to stop (L290). So it is accepted only where the suite asserts
# the window ran out: its status captured in the same statement and compared with 1 somewhere in
# the file. A constant condition (true, false) waits on nothing and is the helper's own test.
# ---------------------------------------------------------------------------
{
  printf '#!/usr/bin/env bash\n'
  # Five misuses: the status thrown away, failing when it runs out, passing when it is met, a
  # capture compared only with 0, and a capture never compared at all.
  printf '%s 2 "[ -e %s ]"\n' "$_WW" "'\$f'"
  printf '%s 2 "[ -e %s ]" || echo FAIL never came\n' "$_WW" "'\$f'"
  printf 'if %s 5 "[ -s %s ]"; then echo ok; fi\n' "$_WW" "'\$f'"
  printf '%s 2 "[ -e %s ]"; seen=$?; [ "$seen" = 0 ] && echo ok\n' "$_WW" "'\$f'"
  printf '%s 3 "[ -e %s ]"; unread=$?\n' "$_WW" "'\$f'"
  # And four that are not: a capture compared with 1 on a later line, one written for another shell
  # with its dollar escaped, and the helper's own tests on a constant condition.
  printf '%s 2 "[ -e %s ]"; held=$?\n[ "$held" -eq 1 ] && echo ran out\n' "$_WW" "'\$f'"
  printf 'bash -c "%s 2 c; w2=\\$?; [ \\"\\$w2\\" = 1 ]"\n' "$_WW"
  printf 'bash -c ". lib; %s 1 false 0.05; echo \\$?"\n' "$_WW"
  printf '%s 1 true\n' "$_WW"
} > "$TMPROOT/payload/hooks/test-window-probe.sh"
wprobe="$(printf 'payload/hooks/test-window-probe.sh\n' | python3 "$SCAN" --root "$TMPROOT")"; wprobe_rc=$?
wprobe_lines="$(printf '%s\n' "$wprobe" | awk -F: 'NF { printf "%s ", $2 }')"
[ "$wprobe_rc" = 1 ] && [ "$wprobe_lines" = "2 3 4 5 6 " ] \
  && check "#1721 window_wait is accepted only where the suite asserts the window ran out" ok \
  || check "#1721 window_wait is accepted only where the suite asserts the window ran out" "exit $wprobe_rc, lines '$wprobe_lines' where 2 3 4 5 6 were wanted:
$wprobe"

# ---------------------------------------------------------------------------
# A BARE FIXED SLEEP (claude-config#1743): a suite pausing a fixed time and then acting as though
# what it waited for has happened asserts about the machine's load, as a short ceiling does (L290).
# Fourteen such lines in seven suites escaped the loop rules above. A sleep is reported when it is a
# statement of the suite's own that runs in the foreground and then carries on: not a poll tick in
# the body of a while or until loop (or a for over ticks), which the loop rules judge; not a holder
# put in the background (`&`) or made the process itself (`exec`); and not the body of a stand in
# the suite writes through a heredoc, where it is how long the fake takes, never a wait of the
# suite's. No list of excused files or lines.
# ---------------------------------------------------------------------------
{
  printf '#!/usr/bin/env bash\n'
  # Six that are: alone, between two commands, after &&, in an if, quoted, and in the body of a for
  # loop over cases, which iterates cases rather than ticks.
  printf '%s 1\n' "$_S"
  printf 'kill "$p"; %s 2; check gone\n' "$_S"
  printf 'kill "$p" && %s 0.5\n' "$_S"
  printf 'if [ -n "$slow" ]; then %s 1; fi\n' "$_S"
  printf '%s "2"\n' "$_S"
  printf '%s mode in running stopped; do\n  start "$mode"\n  %s 2\n  check "$mode"\ndone\n' "$_F" "$_S"
  # And ten that are not: a poll tick in a while loop over several lines and on one, a holder in
  # the background, one made the process, a stand in's own duration in a heredoc, a comment, a for
  # loop over ticks that paces output, a wait on the condition itself, a duration named where it is
  # set, and a tick in a loop written inside a quoted fixture.
  printf '%s [ ! -e "$f" ]; do\n  %s 0.1\ndone\n' "$_W" "$_S"
  printf '%s ! kill -0 "$p"; do %s 0.1; done\n' "$_U" "$_S"
  printf '%s 300 &\n' "$_S"
  printf '(cd "$wt" && exec %s 120) &\n' "$_S"
  printf "cat > stub <<'EOF'\n#!/bin/bash\n%s 1.2\nexec real \"\$@\"\nEOF\n" "$_S"
  printf '# %s 1 here would be a guess\n' "$_S"
  printf '%s i in $(seq 1 5); do\n  printf .\n  %s 0.1\ndone\n' "$_F" "$_S"
  printf 'hang_wait %s\n' "'[ -e \"\$f\" ]'"
  printf '%s "$POLL"\n' "$_S"
  printf "mon '%s true; do git push && break; %s 30; done'\n" "$_W" "$_S"
} > "$TMPROOT/payload/hooks/test-bare-probe.sh"
bprobe="$(printf 'payload/hooks/test-bare-probe.sh\n' | python3 "$SCAN" --root "$TMPROOT")"; bprobe_rc=$?
bprobe_lines="$(printf '%s\n' "$bprobe" | awk -F: 'NF { printf "%s ", $2 }')"
[ "$bprobe_rc" = 1 ] && [ "$bprobe_lines" = "2 3 4 5 6 9 " ] \
  && check "#1743 a bare fixed sleep is reported, and a tick, a holder or a stand in's own duration is not" ok \
  || check "#1743 a bare fixed sleep is reported, and a tick, a holder or a stand in's own duration is not" "exit $bprobe_rc, lines '$bprobe_lines' where 2 3 4 5 6 9 were wanted:
$bprobe"
# The finding says what to do instead, so the next author is not left to guess.
case "$bprobe" in
  *"fixed sleep"*hang_wait*window_wait*) check "#1743 and the finding names the two ways on" ok ;;
  *) check "#1743 and the finding names the two ways on" "it said: $bprobe" ;;
esac

# ---------------------------------------------------------------------------
# The real tree: none at all, anywhere.
# ---------------------------------------------------------------------------
FILES="$(bash "$DIR/lib/repo-files.sh" "$ROOT" 2>/dev/null || true)"
# A listing that came back empty read nothing, and the check below would pass over it (L98).
suites_n="$(printf '%s\n' "$FILES" | grep -c -E '(^|/)test-[^/]*\.sh$')"
[ "$suites_n" -gt 0 ] \
  && check "the suites to judge were listed" ok \
  || check "the suites to judge were listed" "lib/repo-files.sh gave no suite for $ROOT, so nothing below was read"
found="$(printf '%s\n' "$FILES" | python3 "$SCAN" --root "$ROOT")"; found_rc=$?
[ "$found_rc" = 0 ] && [ -z "$found" ] \
  && check "no suite hand rolls a wall clock wait" ok \
  || check "no suite hand rolls a wall clock wait" "exit $found_rc; these do, and a loaded Mac reaches their ceilings with nothing broken:
$found
  Wait with hang_wait from hooks/lib/hang-wait.sh (a stand in running as its own process bounds its
  clock by \${FAKE_HANG_S:-300}), or with window_wait where the passing case is meant to run the window out."

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
