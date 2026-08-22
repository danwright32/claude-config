#!/usr/bin/env bash
# Every suite in this repo has to end with ONE machine readable score line (claude-config#126).
#
# Before this, thirty six suites printed their totals five different ways: `passed: 8, failed: 0`,
# `12 passed, 0 failed`, `passed: 14   failed: 0`, `passed 15, failed 0` and `PASS=815 FAIL=0`.
# run-all-tests.sh had to guess which line was the score, and it got that wrong twice on the day
# #120 was built: it printed `ok: #105 even though every check inside it passed` in the column
# where a verdict belongs, and once that was fixed it read `PASS=805 FAIL=0` as 805 failures. Both
# were caught, and both came from a reader trying to recognise a value every suite already knows
# exactly (L107: the number must come from the producer's own predicate, not from a query written
# beside it).
#
# So there is one line, and it is for machines: `SUITE-RESULT passed=<n> failed=<n>`. The
# human readable line stays exactly as it was, because it is the one a person reads. The suites are
# found from the files rather than from a list, or a suite added later is exempt from the very
# check meant to keep it honest (L96).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SUITE_RESULT_ROOT:-$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# Assembled from pieces, never written whole, so this file is not itself an occurrence of the thing
# it is looking for and cannot answer its own question (the trick check-style-guide.sh needs).
MARK="SUITE""-RESULT"
PATTERN="^${MARK} passed=[0-9]\{1,\} failed=[0-9]\{1,\}$"

# No repository here is not a failure of this suite's subject, it is a place this suite cannot be
# asked (claude-config#155). Said in the one agreed shape the runner reads exactly, so it is
# reported as NOT RUN rather than as broken code, and never as a pass: the runner refuses the same
# claim wherever a repository IS present, so this cannot become a way to opt out of being run.
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-suite-result-line: no repo above $DIR, so there were no suites to read. Refusing rather than reporting them all correct." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to find every suite in it, and there is none above $DIR"
  exit 2
fi

# ---------------------------------------------------------------------------
# The pattern has to be able to tell a good line from a bad one before the real tree is asked, or a
# pattern that matched everything would report every suite as correct (L1, L98).
# ---------------------------------------------------------------------------
printf '%s passed=3 failed=0\n' "$MARK" | grep -q "$PATTERN" \
  && check "the pattern accepts a well formed result line" ok \
  || check "the pattern accepts a well formed result line" "it rejected one"
for bad in "$MARK passed=3" "$MARK passed=three failed=0" "  $MARK passed=3 failed=0" "passed: 3, failed: 0"; do
  printf '%s\n' "$bad" | grep -q "$PATTERN" \
    && check "and rejects: $bad" "it accepted it" \
    || check "and rejects: $bad" ok
done

# ---------------------------------------------------------------------------
# Every suite in the repo. Read from git, so an untracked scratch copy is not counted.
# ---------------------------------------------------------------------------
missing=""
seen=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "${rel##*/}" in test-*.sh) ;; *) continue ;; esac
  f="$ROOT/$rel"
  [ -f "$f" ] || continue
  seen=$((seen + 1))
  # The SOURCE is checked for the statement that emits the line, not for the line itself: the file
  # holds a printf with format specifiers in it, and the line only exists once the suite has run.
  # This is the cheap early warning. The real enforcement is in run-all-tests.sh, which runs every
  # suite anyway and reports any that produced no result line, because a check on source text can
  # be satisfied by a printf that never executes (L103).
  grep -qF "$MARK passed=" "$f" || missing="$missing  $rel
"
done <<EOF
$(git -C "$ROOT" ls-files 2>/dev/null || true)
EOF

[ "$seen" -ge 10 ] \
  && check "it found the repo's suites to check ($seen of them)" ok \
  || check "it found the repo's suites to check ($seen of them)" "only $seen, so this proves almost nothing"

case "$missing" in
  *[![:space:]]*)
    check "every suite carries the statement that prints a result line" "these do not:
$missing  Add it beside the human readable summary, as the last thing the suite prints." ;;
  *) check "every suite carries the statement that prints a result line" ok ;;
esac

# And the runner has to CARE when one is missing, or the line is decoration: a suite that stopped
# printing it would be read by the tolerant fallback and nothing would say so (L98).
RUNNER="$DIR/run-all-tests.sh"
grep -qF "$MARK" "$RUNNER" \
  && check "the runner reads the result line" ok \
  || check "the runner reads the result line" "run-all-tests.sh does not mention it"

echo "test-suite-result-line: $seen suite(s) checked."
echo "passed: $pass, failed: $fail"
printf '%s passed=%s failed=%s\n' "$MARK" "$pass" "$fail"
[ "$fail" -eq 0 ]
