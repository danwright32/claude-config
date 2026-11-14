#!/usr/bin/env bash
# The shared keeper of a failure's whole output, asked directly (claude-config#1788, L297).
#
# lib/kept-output.sh is used by tools/check-mods.sh (each refused or failed mod) and by
# run-all-tests.sh (each suite marked FLAKY), and both callers' suites drive it. But one of those
# lives in tests/, which is not installed under ~/.claude/hooks, so the installed coverage check
# would see a hook with no suite, as it did for lib/load-average.sh. And the edges belong here: what
# is pruned, what never is, and that a failure to keep is said rather than swallowed.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/kept-output.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$LIB" ]; then
  echo "FAIL: no keeper at $LIB"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
. "$LIB"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.kept-output.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-kept-output: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

count_logs(){ find "$1" -name '*.log' -type f 2>/dev/null | wc -l | tr -d ' '; }

# 1. The whole input is kept, in a folder created on demand, and its path is handed back.
D1="$TMPROOT/one/deeper"
body="$(printf 'line %s\n' 1 2 3 4 5 6 7 8 9 10)"
if kept_output_save "$D1" "some-mod-plugin-test" <<< "$body"; then
  case "$KEPT_OUTPUT_PATH" in
    "$D1"/*-some-mod-plugin-test.*.log) check "the kept file is named by the time and the label, in the folder" ok ;;
    *) check "the kept file is named by the time and the label, in the folder" "path=$KEPT_OUTPUT_PATH" ;;
  esac
  [ "$(cat "$KEPT_OUTPUT_PATH")" = "$body" ] && check "and it holds the whole input" ok \
    || check "and it holds the whole input" "$(cat "$KEPT_OUTPUT_PATH" 2>&1)"
else
  check "a writable folder keeps the output" "why=$KEPT_OUTPUT_WHY"
fi

# 2. A label cannot reach outside the folder: anything but letters, digits, dot, underscore and
#    hyphen becomes an underscore.
D2="$TMPROOT/two"
kept_output_save "$D2" "../../escape me/now" <<< "x"
case "$KEPT_OUTPUT_PATH" in
  "$D2"/*-.._.._escape_me_now.*.log) check "a label with slashes and spaces stays inside the folder" ok ;;
  *) check "a label with slashes and spaces stays inside the folder" "path=$KEPT_OUTPUT_PATH" ;;
esac
[ "$(find "$TMPROOT" -maxdepth 1 -name '*escape*' | wc -l | tr -d ' ')" = 0 ] \
  && check "and nothing was written beside the folder" ok || check "and nothing was written beside the folder" "$(ls "$TMPROOT")"

# 3. Pruning keeps the newest KEPT_OUTPUT_KEEP by the time in the name, not by modification time,
#    and leaves any file it did not write alone.
D3="$TMPROOT/three"; mkdir -p "$D3"
for i in 1 2 3 4 5; do printf 'old\n' > "$D3/2020010${i}T000000Z-seeded.AAAAA${i}.log"; done
# The oldest by name is the newest by mtime, so a prune by mtime would keep the wrong one.
touch "$D3/20200101T000000Z-seeded.AAAAA1.log"
printf 'mine\n' > "$D3/notes.log"
printf 'mine\n' > "$D3/notes.txt"
KEPT_OUTPUT_KEEP=3 kept_output_save "$D3" "new" <<< "new"
new3="$KEPT_OUTPUT_PATH"
[ "$(count_logs "$D3")" = 4 ] && check "pruning leaves the newest 3 named copies (plus a .log it did not write)" ok \
  || check "pruning leaves the newest 3 named copies (plus a .log it did not write)" "$(ls "$D3")"
{ [ -f "$new3" ] && [ -f "$D3/20200105T000000Z-seeded.AAAAA5.log" ] && [ -f "$D3/20200104T000000Z-seeded.AAAAA4.log" ]; } \
  && check "the newest by the time in the name stay" ok || check "the newest by the time in the name stay" "$(ls "$D3")"
[ ! -e "$D3/20200101T000000Z-seeded.AAAAA1.log" ] && check "the oldest by name goes, whatever its modification time" ok \
  || check "the oldest by name goes, whatever its modification time" "$(ls "$D3")"
{ [ -f "$D3/notes.log" ] && [ -f "$D3/notes.txt" ]; } && check "files not named by the keeper are left alone" ok \
  || check "files not named by the keeper are left alone" "$(ls "$D3")"

# 4. The copy just written is never pruned, even when a clock behind the seeded ones makes it the
#    oldest by name.
D4="$TMPROOT/four"; mkdir -p "$D4"
for i in 1 2 3; do printf 'future\n' > "$D4/2099010${i}T000000Z-seeded.BBBBB${i}.log"; done
KEPT_OUTPUT_KEEP=2 kept_output_save "$D4" "now" <<< "now"
[ -f "$KEPT_OUTPUT_PATH" ] && check "the copy just written survives its own prune" ok \
  || check "the copy just written survives its own prune" "$(ls "$D4")"

# 5. Failures are said, never swallowed, and return non-zero with nothing named.
if kept_output_save "/dev/null/kept" "x" <<< "x"; then
  check "a folder that cannot be created is a failure" "it returned 0, path=$KEPT_OUTPUT_PATH"
else
  [ -z "$KEPT_OUTPUT_PATH" ] && case "$KEPT_OUTPUT_WHY" in *"could not create /dev/null/kept"*) true ;; *) false ;; esac \
    && check "a folder that cannot be created is a failure, with why and no path" ok \
    || check "a folder that cannot be created is a failure, with why and no path" "path=$KEPT_OUTPUT_PATH why=$KEPT_OUTPUT_WHY"
fi
if KEPT_OUTPUT_KEEP=0 kept_output_save "$TMPROOT/five" "x" <<< "x"; then
  check "a keep of 0 is refused" "it returned 0"
else
  case "$KEPT_OUTPUT_WHY" in *"whole number above 0"*) check "a keep of 0 is refused, saying why" ok ;; *) check "a keep of 0 is refused, saying why" "why=$KEPT_OUTPUT_WHY" ;; esac
fi
# 00 is zero too (claude-config#1948): only a literal 0 was refused, so 00 passed as a count.
if KEPT_OUTPUT_KEEP=00 kept_output_save "$TMPROOT/five" "x" <<< "x"; then
  check "a keep of 00 is refused, as zero" "it returned 0"
else
  case "$KEPT_OUTPUT_WHY" in *"whole number above 0"*) check "a keep of 00 is refused, as zero" ok ;; *) check "a keep of 00 is refused, as zero" "why=$KEPT_OUTPUT_WHY" ;; esac
fi
if KEPT_OUTPUT_KEEP=lots kept_output_save "$TMPROOT/five" "x" <<< "x"; then
  check "a keep that is not a number is refused" "it returned 0"
else
  check "a keep that is not a number is refused" ok
fi
[ ! -e "$TMPROOT/five" ] && check "and a refused keep writes nothing" ok || check "and a refused keep writes nothing" "$(ls -R "$TMPROOT/five")"
if kept_output_save "" "x" <<< "x"; then
  check "no folder named is a failure" "it returned 0"
else
  check "no folder named is a failure" ok
fi

# 6. Kept by age per label, not a global count (claude-config#2895, L202). The newest 20 overall was
#    about ten days of flakes, so the one log an issue named was gone before anyone opened it, while
#    a suite that flakes every day filled the folder. With KEPT_OUTPUT_MAX_DAYS set, a copy stays
#    while it is younger than that many days, OR while it is among the newest KEPT_OUTPUT_PER_LABEL
#    of its own label, however old. The clock is injected, so the test never depends on today.
#    Now is 2026-11-13 12:00 UTC (1794571200); 30 days back is 2026-10-14 12:00.
D6="$TMPROOT/six"; mkdir -p "$D6"
# 25 recent copies of a suite that flakes every day: more than the old cap of 20 on their own.
for d in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
  printf 'busy\n' > "$D6/202611${d}T000000Z-test-busy.sh.Bz${d}xx.log"
done
# The busy suite's older copies, beyond 30 days and beyond its newest 3.
for d in 01 02 03 04; do printf 'busy old\n' > "$D6/202609${d}T000000Z-test-busy.sh.Bo${d}xx.log"; done
# A suite that flaked once, 45 days ago: the log an issue cites. It is its suite's newest copy.
printf 'rare\n' > "$D6/20260929T190147Z-test-rare.sh.Rare01.log"
# The rare suite's own older copies, 3 of them, so only the newest 2 of its label (per label 2) stay.
for d in 01 02 03; do printf 'rare old\n' > "$D6/202608${d}T000000Z-test-rare.sh.Ro${d}xx.log"; done
KEPT_OUTPUT_NOW_EPOCH=1794571200 KEPT_OUTPUT_MAX_DAYS=30 KEPT_OUTPUT_PER_LABEL=2 KEPT_OUTPUT_MAX_KB=1024 \
  kept_output_save "$D6" "test-new.sh" <<< "new"
new6="$KEPT_OUTPUT_PATH"
[ -f "$D6/20260929T190147Z-test-rare.sh.Rare01.log" ] \
  && check "#2895 a rare suite's only recent log survives a folder past the old cap of 20" ok \
  || check "#2895 a rare suite's only recent log survives a folder past the old cap of 20" "$(ls "$D6")"
[ "$(find "$D6" -name '2026111*-test-busy.sh.*.log' -o -name '2026110*-test-busy.sh.*.log' -o -name '2026112*-test-busy.sh.*.log' | wc -l | tr -d ' ')" = 25 ] \
  && check "#2895 every copy younger than 30 days stays, all 25 of the busy suite" ok \
  || check "#2895 every copy younger than 30 days stays, all 25 of the busy suite" "$(ls "$D6")"
[ "$(find "$D6" -name '202609*-test-busy.sh.*.log' | wc -l | tr -d ' ')" = 0 ] \
  && check "#2895 the busy suite's copies past 30 days and past its newest 2 go" ok \
  || check "#2895 the busy suite's copies past 30 days and past its newest 2 go" "$(ls "$D6")"
{ [ -f "$D6/20260803T000000Z-test-rare.sh.Ro03xx.log" ] && [ ! -e "$D6/20260802T000000Z-test-rare.sh.Ro02xx.log" ] \
  && [ ! -e "$D6/20260801T000000Z-test-rare.sh.Ro01xx.log" ]; } \
  && check "#2895 an old suite keeps its newest 2 copies and the oldest uncited ones go" ok \
  || check "#2895 an old suite keeps its newest 2 copies and the oldest uncited ones go" "$(ls "$D6")"
[ -f "$new6" ] && check "#2895 and the copy just written stays" ok || check "#2895 and the copy just written stays" "$(ls "$D6")"

# 7. The folder's total size is bounded whatever the ages, so keeping by age cannot fill the disk.
#    Over KEPT_OUTPUT_MAX_KB, the oldest go first, and the copy just written never does.
D7="$TMPROOT/seven"; mkdir -p "$D7"
blob="$(head -c 3000 /dev/zero | tr '\0' 'x')"
for d in 01 02 03 04 05 06 07 08 09 10; do printf '%s\n' "$blob" > "$D7/202611${d}T000000Z-test-big${d}.sh.Gz${d}xx.log"; done
KEPT_OUTPUT_NOW_EPOCH=1794571200 KEPT_OUTPUT_MAX_DAYS=30 KEPT_OUTPUT_PER_LABEL=3 KEPT_OUTPUT_MAX_KB=10 \
  kept_output_save "$D7" "test-new.sh" <<< "$blob"
new7="$KEPT_OUTPUT_PATH"
total7="$(cat "$D7"/*.log 2>/dev/null | wc -c | tr -d ' ')"
[ "$total7" -le 10240 ] && check "#2895 the folder is held under its size cap" ok \
  || check "#2895 the folder is held under its size cap" "$total7 bytes: $(ls "$D7")"
{ [ -f "$new7" ] && [ -f "$D7/20261110T000000Z-test-big10.sh.Gz10xx.log" ] && [ ! -e "$D7/20261101T000000Z-test-big01.sh.Gz01xx.log" ]; } \
  && check "#2895 the size cap removes the oldest first and keeps the copy just written" ok \
  || check "#2895 the size cap removes the oldest first and keeps the copy just written" "$(ls "$D7")"

# 8. A clock that cannot be turned into a date keeps everything by age (the harmless side) and still
#    holds the size cap; a policy setting that is not a whole number above zero is refused unwritten.
D8="$TMPROOT/eight"; mkdir -p "$D8"
printf 'x\n' > "$D8/20200101T000000Z-test-a.sh.Aa01xx.log"
printf 'x\n' > "$D8/20200102T000000Z-test-a.sh.Aa02xx.log"
KEPT_OUTPUT_NOW_EPOCH=notanumber KEPT_OUTPUT_MAX_DAYS=30 KEPT_OUTPUT_PER_LABEL=1 KEPT_OUTPUT_MAX_KB=1024 \
  kept_output_save "$D8" "test-a.sh" <<< "x"
[ -f "$D8/20200101T000000Z-test-a.sh.Aa01xx.log" ] \
  && check "#2895 a clock that cannot be read deletes nothing by age" ok \
  || check "#2895 a clock that cannot be read deletes nothing by age" "$(ls "$D8")"
for bad in 0 00 x ""; do
  if KEPT_OUTPUT_MAX_DAYS=30 KEPT_OUTPUT_PER_LABEL="$bad" KEPT_OUTPUT_MAX_KB=1024 kept_output_save "$TMPROOT/nine" "x" <<< "x"; then
    check "#2895 a per label count of '$bad' is refused" "it returned 0"
  else
    case "$KEPT_OUTPUT_WHY" in *KEPT_OUTPUT_PER_LABEL*) check "#2895 a per label count of '$bad' is refused, saying why" ok ;;
      *) check "#2895 a per label count of '$bad' is refused, saying why" "why=$KEPT_OUTPUT_WHY" ;; esac
  fi
done
if KEPT_OUTPUT_MAX_DAYS=30 KEPT_OUTPUT_PER_LABEL=3 KEPT_OUTPUT_MAX_KB=lots kept_output_save "$TMPROOT/nine" "x" <<< "x"; then
  check "#2895 a size cap that is not a number is refused" "it returned 0"
else
  case "$KEPT_OUTPUT_WHY" in *KEPT_OUTPUT_MAX_KB*) check "#2895 a size cap that is not a number is refused, saying why" ok ;;
    *) check "#2895 a size cap that is not a number is refused, saying why" "why=$KEPT_OUTPUT_WHY" ;; esac
fi
if KEPT_OUTPUT_MAX_DAYS=00 KEPT_OUTPUT_PER_LABEL=3 KEPT_OUTPUT_MAX_KB=1024 kept_output_save "$TMPROOT/nine" "x" <<< "x"; then
  check "#2895 an age of 00 days is refused" "it returned 0"
else
  case "$KEPT_OUTPUT_WHY" in *KEPT_OUTPUT_MAX_DAYS*) check "#2895 an age of 00 days is refused, saying why" ok ;;
    *) check "#2895 an age of 00 days is refused, saying why" "why=$KEPT_OUTPUT_WHY" ;; esac
fi
[ ! -e "$TMPROOT/nine" ] && check "#2895 and a refused policy writes nothing" ok || check "#2895 and a refused policy writes nothing" "$(ls -R "$TMPROOT/nine")"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
