#!/usr/bin/env bash
# Tests for lib/sleep.sh (claude-config#840): the shell's reader of the machine wide sleep record
# must answer exactly what the scope modes mod's readSleep answers, on the one committed fixture set
# both are held to (mods/scope-modes/tests/sleep-fixtures.ts, L26). The mod's own suite holds
# readSleep to the same states, so a reader that drifts fails here or there.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/sleep.sh"
FIXTURES="$DIR/../mods/scope-modes/tests/sleep-fixtures.ts"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '${3:0:300}')"; fi; }

if ! . "$LIB"; then
  echo "FAIL: $LIB could not be sourced"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# The fixtures, read from the same file the mod's test imports: everything after the `=` is JSON.
# Each case becomes a line: its name, the record file (absent for no record), now, this boot's start,
# this boot's session (`none` for either when it could not be read), state.
cases="$WORK/cases.tsv"
if ! sed -n '/^export const SLEEP_FIXTURES = /,$p' "$FIXTURES" | sed '1s/^export const SLEEP_FIXTURES = //' |
  python3 -c '
import json, os, sys
work = sys.argv[1]
for i, f in enumerate(json.load(sys.stdin)):
    path = os.path.join(work, "rec%d.json" % i)
    if f["text"] is not None:
        with open(path, "w") as fh:
            fh.write(f["text"])
    boot = "none" if f["boot"] is None else str(f["boot"])
    session = "none" if f.get("session") is None else f["session"]
    print("\t".join([f["name"], path, str(f["now"]), boot, session, f["state"]]))
' "$WORK" > "$cases"; then
  echo "FAIL: the fixture set in $FIXTURES could not be read as JSON"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$((fail + 1))"
  exit 1
fi
n="$(wc -l < "$cases" | tr -d ' ')"
check_eq "the fixture set is not empty" "yes" "$([ "$n" -ge 10 ] && echo yes || echo "no, $n")"

while IFS=$'\t' read -r name path now boot session want; do
  check_eq "fixture: $name" "$want" "$(sleep_state "$path" "$now" "$boot" "$session")"
  if [ "$want" = asleep ]; then
    sleep_active "$path" "$now" "$boot" "$session"; check_eq "sleep_active says yes: $name" 0 "$?"
  else
    sleep_active "$path" "$now" "$boot" "$session"; check_eq "sleep_active says no: $name" 1 "$?"
  fi
done < "$cases"

# This boot as sysctl prints it, read by the shell exactly as the mod's bootOf reads it, on the same
# committed cases (BOOT_FIXTURES, before SLEEP_FIXTURES in the same file).
boots="$WORK/boots.tsv"
if ! sed -n '/^export const BOOT_FIXTURES = /,/^]/p' "$FIXTURES" | sed '1s/^export const BOOT_FIXTURES = //' |
  python3 -c '
import json, sys
for f in json.load(sys.stdin):
    print("\t".join([f["name"], json.dumps(f["text"]), "" if f["boot"] is None else str(f["boot"])]))
' > "$boots" || [ ! -s "$boots" ]; then
  check_eq "the boot fixtures in $FIXTURES read as JSON" yes no
else
  while IFS=$'\t' read -r name text want; do
    check_eq "boot fixture: $name" "$want" "$(sleep_boot_of "$(python3 -c 'import json,sys; sys.stdout.write(json.loads(sys.argv[1]))' "$text")")"
  done < "$boots"
fi

# This boot's session as sysctl prints it, read by the shell as the mod's bootSessionOf reads it, on
# the same committed cases (SESSION_FIXTURES).
sessions="$WORK/sessions.tsv"
if ! sed -n '/^export const SESSION_FIXTURES = /,/^]/p' "$FIXTURES" | sed '1s/^export const SESSION_FIXTURES = //' |
  python3 -c '
import json, sys
for f in json.load(sys.stdin):
    print("\t".join([f["name"], json.dumps(f["text"]), "" if f["session"] is None else f["session"]]))
' > "$sessions" || [ ! -s "$sessions" ]; then
  check_eq "the session fixtures in $FIXTURES read as JSON" yes no
else
  while IFS=$'\t' read -r name text want; do
    check_eq "session fixture: $name" "$want" "$(sleep_boot_session_of "$(python3 -c 'import json,sys; sys.stdout.write(json.loads(sys.argv[1]))' "$text")")"
  done < "$sessions"
fi

# The real defaults: the record under $HOME, now from the clock and this boot from sysctl. The boot
# the record is written with is read here by the mod's rule (bootOf's pattern, in python), never by
# the shell's own reader, so a shell that misreads sysctl cannot agree with itself (L70).
mkdir -p "$WORK/home/.claude/state/sleep"
check_eq "no record under HOME is none" none "$(HOME="$WORK/home" sleep_state)"
real_boot="$(sysctl -n kern.boottime 2>/dev/null | python3 -c 'import re, sys; m = re.search(r"\bsec\s*=\s*(\d+)", sys.stdin.read()); print(m.group(1) if m else "")')"
if [ -n "$real_boot" ]; then
  printf '{"v":1,"until":%s000,"bootTime":%s}' "$(( $(date +%s) + 3600 ))" "$real_boot" > "$WORK/home/.claude/state/sleep/current.json"
  check_eq "a record of this boot, ending in an hour, is asleep with every default read live" asleep "$(HOME="$WORK/home" sleep_state)"
  printf '{"v":1,"until":%s000,"bootTime":%s}' "$(( $(date +%s) - 1 ))" "$real_boot" > "$WORK/home/.claude/state/sleep/current.json"
  check_eq "one that ended a second ago is expired" expired "$(HOME="$WORK/home" sleep_state)"
else
  echo "UNMEASURED: this machine has no sysctl kern.boottime, so the live boot read is not exercised here"
fi
# The night of 2026-10-08, read live: the record's bootTime 2 seconds off what sysctl now says, as a
# clock correction left it, with this boot's own session, must still be asleep; the same start with
# another boot's session must not. The session is read here by plain python, never by the shell's
# sleep_boot_session_of (L70).
real_session="$(sysctl -n kern.bootsessionuuid 2>/dev/null | python3 -c 'import sys; print(sys.stdin.readline().strip().upper())')"
if [ -n "$real_boot" ] && [ -n "$real_session" ]; then
  printf '{"v":1,"until":%s000,"bootTime":%s,"bootSession":"%s"}' "$(( $(date +%s) + 3600 ))" "$(( real_boot + 2 ))" "$real_session" > "$WORK/home/.claude/state/sleep/current.json"
  check_eq "this boot's session with a start moved 2 seconds, every default read live, is asleep" asleep "$(HOME="$WORK/home" sleep_state)"
  printf '{"v":1,"until":%s000,"bootTime":%s,"bootSession":"00000000-0000-0000-0000-000000000000"}' "$(( $(date +%s) + 3600 ))" "$real_boot" > "$WORK/home/.claude/state/sleep/current.json"
  check_eq "another boot's session with this start, read live, is another boot" other-boot "$(HOME="$WORK/home" sleep_state)"
else
  echo "UNMEASURED: this machine has no sysctl kern.bootsessionuuid, so the live session read is not exercised here"
fi

# With no python3 the record cannot be read, which is said by name and reads as awake (L490).
nopy="$WORK/nopy"; mkdir -p "$nopy"
for t in bash sed sysctl date cat; do p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$nopy/$t"; done
if PATH="$nopy" command -v python3 >/dev/null 2>&1; then
  echo "FAIL: the bare PATH still reaches python3, so the no python3 case proves nothing"; fail=$((fail + 1))
else
  printf '{"v":1,"until":9999999999999,"bootTime":1}' > "$WORK/p.json"
  out="$(PATH="$nopy" bash -c '. "$1"; sleep_state "$2" 1 1; sleep_why "$2" 1 1' _ "$LIB" "$WORK/p.json")"
  check_eq "no python3 reads as unreadable, naming python3" "unreadable
python3 is not installed, so the sleep record cannot be read" "$out"
fi

# Why a record reads as it does, for the caller that reports it.
printf '{"v":1,' > "$WORK/bad.json"
check_eq "a broken record says why, asked in a subshell as every caller asks" "the sleep record is not JSON" "$(sleep_why "$WORK/bad.json" 1 1)"
check_eq "an asleep record has no why" "" "$(sleep_why "$WORK/rec0.json" 1791360000000 1759800000)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
