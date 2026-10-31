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

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
