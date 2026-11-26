#!/usr/bin/env bash
# Tests for lib/disk-writers.py, the reading of which programs are writing to the disk (claude-config#3589).
#
# The disk-full skill's own suite runs the reading as the skill writes it, on one good set of
# readings and on a Mac's live process table. This suite runs every other path the script has: the
# options it refuses, each bucket of programs it could not read and the line that says so, and a
# readings file it cannot use, which must end in one line saying what is wrong and exit 2, never a
# traceback and never a report built from half of it. It lives beside the script so the hooks'
# coverage check, which reads only the test-*.sh installed beside the hooks, sees it named.
#
# Nothing here reads this Mac's process table or disk: every run is handed its readings through
# DISK_WRITERS_SAMPLES, so it answers the same on any machine.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/lib/disk-writers.py"
. "$DIR/lib/test_bad_byte_locale.sh"
BAD_BYTE_LOCALE="$(bad_byte_locale)"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/disk-writers.XXXXXXXX")" || TMP=""
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "test-disk-writers: refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

check "the script is there to run" "$([ -f "$SCRIPT" ] && echo ok || echo "no $SCRIPT")"

# run <readings file> [options...]: sets out and rc. Run in the locale the bad bytes suite uses, so
# a name holding a byte that is not UTF-8 meets the same decoder it would on a Mac.
run() {
  local f="$1"; shift
  out="$(LC_ALL="$BAD_BYTE_LOCALE" DISK_WRITERS_SAMPLES="$f" DISK_WRITERS_PATH=/fixture python3 "$SCRIPT" "$@" 2>&1)"; rc=$?
}
no_trace() { case "$1" in (*Traceback*) return 1 ;; (*) return 0 ;; esac; }

# One good set of readings, with every bucket of unread program filled.
GOOD="$TMP/good.json"
printf '%s\n' '{"seconds": 10, "free": [60000000000, 59000000000], "total": 300, "read": 3,' \
  ' "unread": {"root": 160, "other": 95, "gone": 7, "refused": 2},' \
  ' "rows": [{"pid": 41, "name": "Photo Editor", "start": 1764000000, "lifetime": 88000000000, "window": 900000000},' \
  '          {"pid": 42, "name": "quiet", "start": null, "lifetime": 1000, "window": 0},' \
  '          {"pid": 43, "name": "sync client", "start": 1763000000, "lifetime": 30000000000, "window": 5000000}]}' > "$GOOD"

# ---- 1. each bucket of programs not read gets its own line, and only when it holds any ----
run "$GOOD"
check "a full set of readings is reported, exit 0" "$([ "$rc" -eq 0 ] && no_trace "$out" && echo ok || echo "exit $rc, said: $out")"
check "programs running as this user that refused the read are counted as unknown, not zero" \
  "$(grep -qxF '2 running as this user refused the read too: their writes are unknown, not zero.' <<< "$out" && echo ok || echo "said: $out")"
check "programs that ended while being read are counted and said to be left out" \
  "$(grep -qxF '7 ended while being read and are left out.' <<< "$out" && echo ok || echo "said: $out")"
check "a program whose start is not known says so rather than a date" \
  "$(grep -qF 'since start unknown' <<< "$out" && echo ok || echo "said: $out")"
QUIET="$TMP/quiet.json"
sed -e 's/"gone": 7, "refused": 2/"gone": 0/' "$GOOD" > "$QUIET"
run "$QUIET"
check "and neither line is printed when nothing refused and nothing ended" \
  "$([ "$rc" -eq 0 ] && ! grep -qE 'refused the read|ended while being read' <<< "$out" && echo ok || echo "exit $rc, said: $out")"

# ---- 2. the options it refuses ----
run "$GOOD" --top 0
check "--top below 1 is refused, exit 2, naming the option" \
  "$([ "$rc" -eq 2 ] && grep -qF -- '--top must be 1 or more' <<< "$out" && echo ok || echo "exit $rc, said: $out")"
run "$GOOD" --seconds 0
check "--seconds of 0 is refused, exit 2, naming the option" \
  "$([ "$rc" -eq 2 ] && grep -qF -- '--seconds must be above 0' <<< "$out" && echo ok || echo "exit $rc, said: $out")"
run "$GOOD" --seconds 121
check "--seconds above 120 is refused, exit 2" \
  "$([ "$rc" -eq 2 ] && grep -qF -- '--seconds must be above 0 and at most 120' <<< "$out" && echo ok || echo "exit $rc, said: $out")"
run "$GOOD" --top 1
w_first="$(grep -A2 'Written in those' <<< "$out")"
check "--top 1 lists only the highest writer in the window" \
  "$([ "$rc" -eq 0 ] && grep -qF 'Photo Editor' <<< "$w_first" && ! grep -qF 'sync client' <<< "$w_first" && echo ok || echo "exit $rc, said: $out")"

# ---- 3. a readings file it cannot use ends in one line and exit 2, never a traceback ----
# shape <name> <file> <what the message must contain>
shape() {
  run "$2"
  check "$1: exit 2 with one line saying what is wrong, no traceback" \
    "$([ "$rc" -eq 2 ] && no_trace "$out" && grep -qF "$3" <<< "$out" && echo ok || echo "exit $rc, said: $out")"
}
shape "a readings file that is not there" "$TMP/missing.json" 'could not read the readings in DISK_WRITERS_SAMPLES'
printf '{"seconds": 10,\n' > "$TMP/cut.json"
shape "a readings file that is not JSON" "$TMP/cut.json" 'could not read the readings in DISK_WRITERS_SAMPLES'
printf '[1, 2, 3]\n' > "$TMP/list.json"
shape "readings whose top level is a list, not an object" "$TMP/list.json" 'not in the shape this reads'
for key in unread free total rows seconds; do
  python3 -c 'import json, sys; s = json.load(open(sys.argv[1], encoding="utf-8")); del s[sys.argv[2]]; json.dump(s, open(sys.argv[3], "w", encoding="utf-8"))' \
    "$GOOD" "$key" "$TMP/no-$key.json"
  shape "readings with no $key" "$TMP/no-$key.json" "no \"$key\""
done
python3 -c 'import json, sys; s = json.load(open(sys.argv[1], encoding="utf-8")); del s["unread"]["root"]; json.dump(s, open(sys.argv[2], "w", encoding="utf-8"))' \
  "$GOOD" "$TMP/no-root.json"
shape "readings whose unread count has no root" "$TMP/no-root.json" 'no "root"'
python3 -c 'import json, sys; s = json.load(open(sys.argv[1], encoding="utf-8")); del s["rows"][0]["window"]; json.dump(s, open(sys.argv[2], "w", encoding="utf-8"))' \
  "$GOOD" "$TMP/no-window.json"
shape "readings with a row that has no window" "$TMP/no-window.json" 'no "window"'
python3 -c 'import json, sys; s = json.load(open(sys.argv[1], encoding="utf-8")); s["free"] = [1]; json.dump(s, open(sys.argv[2], "w", encoding="utf-8"))' \
  "$GOOD" "$TMP/one-free.json"
shape "readings with one free space reading, not two" "$TMP/one-free.json" '"free"'
python3 -c 'import json, sys; s = json.load(open(sys.argv[1], encoding="utf-8")); s["rows"][0]["pid"] = "41"; json.dump(s, open(sys.argv[2], "w", encoding="utf-8"))' \
  "$GOOD" "$TMP/text-pid.json"
shape "readings with a pid written as text" "$TMP/text-pid.json" '"pid"'
# json.load reads NaN and Infinity as numbers, and a start far past any date as one too; each must
# be refused here, never reach round() or localtime() in the report and end in a traceback there.
sed -e 's/"seconds": 10,/"seconds": NaN,/' "$GOOD" > "$TMP/nan-seconds.json"
shape "readings whose seconds is NaN" "$TMP/nan-seconds.json" '"seconds"'
sed -e 's/"free": \[60000000000, 59000000000\]/"free": [Infinity, 59000000000]/' "$GOOD" > "$TMP/inf-free.json"
shape "readings whose free space is Infinity" "$TMP/inf-free.json" '"free"'
sed -e 's/"lifetime": 88000000000/"lifetime": -Infinity/' "$GOOD" > "$TMP/inf-lifetime.json"
shape "readings with a lifetime of minus Infinity" "$TMP/inf-lifetime.json" '"lifetime"'
sed -e 's/"start": 1764000000, "lifetime": 88000000000/"start": 1e20, "lifetime": 88000000000/' "$GOOD" > "$TMP/far-start.json"
shape "readings with a start far past any date" "$TMP/far-start.json" '"start"'

# ---- 4. a live reading it cannot make ends in one line and exit 2, never a report of nothing ----
# Free space is read before the process table, so a volume that is not there fails on any machine.
out="$(env -u DISK_WRITERS_SAMPLES DISK_WRITERS_PATH="$TMP/no-such-volume" python3 "$SCRIPT" --seconds 1 2>&1)"; rc=$?
check "a volume whose free space cannot be read: exit 2 naming it, no traceback" \
  "$([ "$rc" -eq 2 ] && no_trace "$out" && grep -qF "could not read free space on $TMP/no-such-volume" <<< "$out" && echo ok || echo "exit $rc, said: $out")"
# The process table: the script is loaded with its reader replaced by one that fails as libproc does
# where it is missing (OSError), and its own main() is run, so the handler under test is the shipped one.
out="$(env -u DISK_WRITERS_SAMPLES DISK_WRITERS_PATH="$TMP" python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("disk_writers", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def refuse(self):
    raise OSError("libproc is not here")
m.Proc.__init__ = refuse
sys.argv = ["disk-writers.py", "--seconds", "1"]
sys.exit(m.main())
' "$SCRIPT" 2>&1)"; rc=$?
check "a process table that cannot be read: exit 2 naming it, no traceback" \
  "$([ "$rc" -eq 2 ] && no_trace "$out" && grep -qF 'could not read the process table: libproc is not here' <<< "$out" && echo ok || echo "exit $rc, said: $out")"

# ---- 5. a name that cannot be printed as it stands is printed replaced, never a traceback ----
# A lone surrogate, which json.loads makes of an escape such as \ud800, cannot be written to a
# UTF-8 stdout; a byte that is not UTF-8 cannot be decoded from the file. Either one in a single
# program's name must not cost the whole report.
sed -e 's/"name": "Photo Editor"/"name": "Photo \\ud800 Editor"/' "$GOOD" > "$TMP/surrogate.json"
run "$TMP/surrogate.json"
check "a name holding a lone surrogate is printed with it replaced, exit 0" \
  "$([ "$rc" -eq 0 ] && no_trace "$out" && grep -qF 'Editor' <<< "$out" && echo ok || echo "exit $rc, said: $out")"
# Only where a python3 file read of such a byte really fails under the helper's locale does this case
# measure anything; elsewhere it says UNMEASURED rather than passing with or without the fix.
if bad_byte_measured python-file "#3589 a readings file whose program name holds a byte that is not UTF-8"; then
  sed -e "s/\"name\": \"Photo Editor\"/\"name\": \"Photo $(printf '\377') Editor\"/" "$GOOD" > "$TMP/byte.json"
  run "$TMP/byte.json"
  check "a name holding a byte that is not UTF-8 is printed with it replaced, exit 0" \
    "$([ "$rc" -eq 0 ] && no_trace "$out" && grep -qF 'Editor' <<< "$out" && echo ok || echo "exit $rc, said: $out")"
fi

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
