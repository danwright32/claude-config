#!/usr/bin/env bash
# Tests for tools/tag-lessons.py: when each lesson can act (claude-config#563), which decides whether
# the PR lessons review can stand in for it. A lesson only a diff can show is `diff`; one that acts
# while planning is `design`; one that acts while diagnosing, measuring or operating is `operate`.
# Anything no PR review can see stays in the core whatever its rank, so a lesson with no tag, two
# tags, or a tag outside the three is a REFUSAL, never a default (L517, L113).
#
# A fake claude stands in for the model, so nothing reaches the network (L2).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/tag-lessons.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1200}"; fi; }
check_rc(){ if [ "$3" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected exit $2, got $3)"; fi; }

IDX="$WORK/idx"; mkdir -p "$IDX"
printf '# Lessons index: A\n\n- L1. A test is only real once seen to fail.\n- L2. State the data volume before writing a query.\n' > "$IDX/LESSONS-INDEX-a.md"
printf '# Lessons index: B\n\n- L3. Judge a command by its exit code.\n' > "$IDX/LESSONS-INDEX-b.md"

BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'EOS'
#!/usr/bin/env bash
printf '%s\x1e' "$@" > "$FAKE_LOG/args"
n=$(( $(cat "$FAKE_LOG/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_LOG/n"
case "${FAKE_MODE:-good}" in
  good) printf 'L1\tdiff\nL2\tdesign\nL3\toperate\n' ;;
  missing_then_good) if [ "$n" -eq 1 ]; then printf 'L1\tdiff\nL3\toperate\n'; else printf 'L2\tdesign\n'; fi ;;
  never) printf 'L1\tdiff\n' ;;
  bad) printf 'L1\tdiff\nL2\tmaybe\nL3\toperate\n' ;;
  twice) printf 'L1\tdiff\nL1\tdesign\nL2\tdesign\nL3\toperate\n' ;;
esac
EOS
chmod +x "$BIN/claude"
export FAKE_LOG="$WORK/log"
run(){ rm -rf "$FAKE_LOG"; mkdir -p "$FAKE_LOG"; PATH="$BIN:$PATH" python3 "$TOOL" --index-dir "$IDX" --batch 50 "$@" 2>&1; }

out="$(FAKE_MODE=good run)"; rc=$?
check_rc "every lesson tagged once is a success" 0 "$rc"
check "L1 is diff" $'L1\tdiff' "$out"
check "L2 is design" $'L2\tdesign' "$out"
check "L3 is operate" $'L3\toperate' "$out"
check "the reviewer runs with hooks off" "disableAllHooks" "$(tr '\036' '\n' < "$FAKE_LOG/args")"
check "the prompt carries the lesson lines themselves" "State the data volume" "$(tr '\036' '\n' < "$FAKE_LOG/args")"

out="$(FAKE_MODE=missing_then_good run)"; rc=$?
check_rc "a lesson missing from the first answer is asked again" 0 "$rc"
check "and then tagged" $'L2\tdesign' "$out"

out="$(FAKE_MODE=never run)"; rc=$?
check_rc "a lesson never tagged is a refusal" 1 "$rc"
check "naming it" "UNTAGGED L2" "$out"

out="$(FAKE_MODE=bad run)"; rc=$?
check_rc "a tag outside the three is a refusal" 1 "$rc"
check "naming the bad answer" "maybe" "$out"

out="$(FAKE_MODE=twice run)"; rc=$?
check_rc "a lesson given two different tags is a refusal" 1 "$rc"
check "naming it" "CONFLICT L1" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
