#!/usr/bin/env bash
# lib/loose-reader.py makes the copy of the hooks every #2235 case runs against to see the case fail
# on the reading it defends (L1). A copy that undid nothing would read exactly as the real hooks do,
# so every "the loose copy lets it through" case would fail and every refusal would look unproved, or,
# in a suite that checked the exit code alone, a copy would stand in for one it is not. So this suite
# sees each variant undo its reading, and sees the tool refuse, leaving no copy, when there is nothing
# to undo (claude-config#2235).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOSE="$DIR/lib/loose-reader.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loose-reader.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
same() { if [[ "$3" == "$2" ]]; then check "$1" ok; else check "$1" "expected [$2], got [$3]"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-loose-reader: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

# read_with <hooks folder> <probe>: what that folder's reader says to one probe of a #2235 reading.
read_with() {
  python3 -B -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("sw", os.path.join(sys.argv[1], "lib", "shell-words.py"))
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
probe = sys.argv[2]
if probe == "redirects":
    print(sw.past_redirects("2>/dev/null git push"))
elif probe == "rejoin":
    print(sw.rejoin(["2>", "/dev/null", "gh", "issue", "create"]))
elif probe == "glue":
    print(" ".join(sw.shell_tokens("2>/dev/null gh issue create")))
' "$1" "$2" 2>&1
}

echo "the real reader reads each probe the #2235 way, the control for the copies below"
same "past_redirects passes the redirection over" "git push" "$(read_with "$DIR" redirects)"
same "rejoin writes the operator bare" "2> /dev/null gh issue create" "$(read_with "$DIR" rejoin)"
same "shell_tokens keeps the descriptor with its operator" "2> /dev/null gh issue create" "$(read_with "$DIR" glue)"

echo "each variant undoes its own reading, and only that one"
want_redirects="2>/dev/null git push"
want_rejoin="'2>' /dev/null gh issue create"
want_glue="2 > /dev/null gh issue create"
for variant in redirects rejoin glue; do
  out="$(python3 -B "$LOOSE" "$DIR" "$WORK/$variant" "$variant" 2>&1)"; rc=$?
  same "$variant: the copy is made" "0|" "$rc|$out"
  want="want_$variant"
  same "$variant: its reading is undone" "${!want}" "$(read_with "$WORK/$variant" "$variant")"
  for other in redirects rejoin glue; do
    [ "$other" = "$variant" ] && continue
    same "$variant: the $other reading is left as it is" "$(read_with "$DIR" "$other")" "$(read_with "$WORK/$variant" "$other")"
  done
  # Only the reader differs, so a gate in the copy is the real gate reading the old way.
  diffs="$(diff -rq -x __pycache__ "$DIR" "$WORK/$variant" 2>&1)"
  same "$variant: the reader is the one file that differs" "Files $DIR/lib/shell-words.py and $WORK/$variant/lib/shell-words.py differ" "$diffs"
done

echo "a copy made over an old one replaces it"
mkdir -p "$WORK/stale"; : > "$WORK/stale/left-over"
python3 -B "$LOOSE" "$DIR" "$WORK/stale" redirects >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$WORK/stale/left-over" ] && [ -f "$WORK/stale/lib/shell-words.py" ]; then check "the old copy is gone and the new one is there" ok
else check "the old copy is gone and the new one is there" "exit $rc, $(ls "$WORK/stale" 2>&1 | tr '\n' ' ')"; fi

echo "a reader with nothing to undo is refused, and leaves no copy"
# A hooks folder whose reader holds none of the three readings, as the reader would after a change
# that moved one of them.
mkdir -p "$WORK/moved/lib"
printf 'def past_redirects(s, cwd=""):\n    return s.lstrip()\n' > "$WORK/moved/lib/shell-words.py"
for variant in redirects rejoin glue; do
  out="$(python3 -B "$LOOSE" "$WORK/moved" "$WORK/moved-$variant" "$variant" 2>&1)"; rc=$?
  same "$variant: exit 1" "1" "$rc"
  case "$out" in *"the $variant reading was not found"*) check "$variant: and names the variant" ok ;;
    *) check "$variant: and names the variant" "said: $out" ;; esac
  if [ -e "$WORK/moved-$variant" ]; then check "$variant: and leaves no copy to run" "$WORK/moved-$variant is there"
  else check "$variant: and leaves no copy to run" ok; fi
done

echo "a bad call is refused as one"
python3 -B "$LOOSE" "$DIR" "$WORK/bad" sideways >/dev/null 2>&1; same "an unknown variant exits 64" "64" "$?"
python3 -B "$LOOSE" "$DIR" "$WORK/bad" >/dev/null 2>&1; same "a missing variant exits 64" "64" "$?"
if [ -e "$WORK/bad" ]; then check "and neither makes a copy" "$WORK/bad is there"; else check "and neither makes a copy" ok; fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
