#!/usr/bin/env bash
# Tests for the scan that finds an absence assertion nothing can satisfy (claude-config#371).
#
# A `! grep -q 'NEEDLE'` assertion is satisfied by ABSENCE, so a needle that can never match is
# indistinguishable from the behaviour being correct (L159, L100). On 2026-09-11 a fixture's sample
# text was reworded and two assertions were left matching the old wording: the positive one failed
# honestly, and the negative one passed while searching for a string that existed nowhere in the
# run.
#
# Driven against fixtures FIRST, so every outcome the scan can report is produced rather than
# merely reachable (L151), and against the real tree at the end, because a scan proven only over
# files this suite wrote says nothing about the one anybody runs (L52).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/scan-absence-needles.py"
# WHERE THIS IS RUNNING. Two copies of these hooks exist: the repo's payload/hooks, which sits
# beside a claude-sync and a payload/, and the INSTALLED copy under the config root, which does
# not. `$DIR/../..` is the repo in the first and the HOME DIRECTORY in the second, so a suite that
# assumes the first walks all of $HOME in the second. Measured 2026-09-11: that is what made
# `claude-sync recheck` exceed its 30 minute ceiling and report the whole config unverified.
#
# Said in the one agreed shape the runner reads, so it is reported as NOT RUN rather than as broken
# code, and never as a pass: this suite is about the repo, and the installed copy is not one.
REPO="$(cd "$DIR/../.." && pwd)"
if [ ! -f "$REPO/claude-sync" ] || [ ! -d "$REPO/payload" ]; then
  echo "test-scan-absence-needles: $REPO is not a checkout of this repo (no claude-sync and payload/ in it), so there was nothing here to scan." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $REPO is not one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
says(){ case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3'" ;; esac; }
silentabout(){ case "$2" in *"$3"*) check "$1" "it named '$3'" ;; *) check "$1" ok ;; esac; }

[ -f "$SCAN" ] || { echo "FAIL: no scan at $SCAN"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/scan-absence.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT

RC=0; OUT=""
run(){ OUT="$(python3 "$SCAN" --root "$FIX" --baseline "$FIX/baseline.txt" 2>&1)"; RC=$?; }

echo "scan absence needles: the fault it was written for"

# The incident, in miniature: a fixture reworded, a negative assertion left behind. The needle it
# searches for exists nowhere in the file, so it can never match and asserts nothing.
cat > "$FIX/test-drifted.sh" <<'EOF'
out="$(printf 'this entry publishes normally\n')"
check "the positive twin"      "grep -q 'publishes normally' <<< \"$out\""
check "the absence assertion"  "! grep -q 'is NOT published' <<< \"$out\""
EOF
printf '# empty\n' > "$FIX/baseline.txt"
run
check "a needle that appears nowhere else is reported" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC")"
says "and the finding names the file and the line" "$OUT" "test-drifted.sh:3"
says "and quotes the needle, so it can be found" "$OUT" "is NOT published"

echo "scan absence needles: and nothing it should leave alone"

# A needle the fixture DOES contain is the ordinary, correct case: the assertion is about text the
# run really can produce. A scan that fired on those would report every suite in the repo (L104).
cat > "$FIX/test-drifted.sh" <<'EOF'
out="$(printf 'this entry publishes normally\n')"
check "the positive twin"      "grep -q 'publishes normally' <<< \"$out\""
check "the absence assertion"  "! grep -q 'publishes normally' <<< \"$out2\""
EOF
run
check "a needle the file does contain is not reported" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# A needle built at RUN TIME is a different question and this one does not answer it. Guessing
# what it will hold would be a finding about the scanner rather than about the assertion.
cat > "$FIX/test-drifted.sh" <<'EOF'
check "a constructed needle" "! grep -q \"$wanted\" <<< \"$out\""
check "another"              "! grep -q \"${prefix}-suffix\" <<< \"$out\""
EOF
run
check "a needle built at run time is not judged" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
silentabout "and is not named in the report either" "$OUT" "suffix"

# An ANCHORED pattern can never appear mid line in the file that writes it, so judging it whole
# would report every anchored assertion in the repo. It is judged on its literal runs.
cat > "$FIX/test-drifted.sh" <<'EOF'
printf 'skills: one file differs\n' > "$out"
check "the absence assertion" "! grep -qE '^skills: .*differs' \"$out\""
EOF
run
check "an anchored pattern is judged on its literal parts, not whole" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

echo "scan absence needles: the baseline is a ratchet in both directions"

cat > "$FIX/test-drifted.sh" <<'EOF'
check "the absence assertion" "! grep -q 'a string written nowhere else at all' <<< \"$out\""
EOF
printf 'test-drifted.sh: 1\n' > "$FIX/baseline.txt"
run
check "a finding the baseline already records does not fail the scan" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
printf 'test-drifted.sh: 2\n' > "$FIX/baseline.txt"
run
check "a baseline claiming more than the file has is refused" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC")"
says "and says the number is stale" "$OUT" "stale"

# A run that scanned NOTHING passes every comparison at once and reads exactly like a clean tree
# (L98), so it refuses instead.
# A file this cannot OPEN is not a file with nothing in it. Returning "nothing judged, no
# findings" would make an unreadable file indistinguishable from a clean one, and the count it
# feeds is the whole verdict (L10, L11, L215).
UNREAD="$FIX/unreadable"; mkdir -p "$UNREAD"
printf 'echo hi\n' > "$UNREAD/test-x.sh"
chmod 000 "$UNREAD/test-x.sh"
printf '# empty\n' > "$UNREAD/baseline.txt"
OUT="$(python3 "$SCAN" --root "$UNREAD" --baseline "$UNREAD/baseline.txt" 2>&1)"; RC=$?
chmod 644 "$UNREAD"/*.sh 2>/dev/null || true
check "a file it cannot read is a finding, not a clean result" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and it says the file could not be read" "$OUT" "could not be read"

EMPTY="$FIX/empty"; mkdir -p "$EMPTY"
OUT="$(python3 "$SCAN" --root "$EMPTY" --baseline "$FIX/baseline.txt" 2>&1)"; RC=$?
check "a run that found no suites refuses rather than passing" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC")"
# And a missing baseline is not an empty one: with nothing to compare against, nothing was verified.
OUT="$(python3 "$SCAN" --root "$FIX" --baseline "$FIX/no-such-baseline.txt" 2>&1)"; RC=$?
check "a missing baseline refuses rather than treating every finding as new" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC")"

echo "scan absence needles: and the real tree it ships to guard"

OUT="$(cd "$REPO" && python3 "$SCAN" --root . 2>&1)"; RC=$?
check "the real tree agrees with its own baseline" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
# A scan that judged nothing would agree with any baseline at all (L98).
_judged="$(printf '%s\n' "$OUT" | sed -n 's/^scan-absence-needles: \([0-9]*\) absence assertion.*/\1/p')"
check "and it really judged the repo's assertions, rather than none" "$([ "${_judged:-0}" -gt 50 ] && echo ok || echo "judged ${_judged:-0}")"
# One tree, one verdict, whichever folder of it --root names (claude-config#443). Findings were
# keyed relative to --root while the baseline is written relative to the checkout, so the sibling
# scan went red on `--root payload` over a tree `--root .` passed. This one shared the keying.
OUT="$(cd "$REPO" && python3 "$SCAN" --root payload 2>&1)"; RC=$?
check "the real tree scanned as payload/ alone agrees with the baseline" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
# The entry for tests/, which that scan never read, is said to be not judged rather than stale.
case "$OUT" in
  *"not judged: tests/test-claude-sync.sh"*) check "and it names the entry it did not judge" ok ;;
  *) check "and it names the entry it did not judge" "did not say it: $OUT" ;;
esac

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
