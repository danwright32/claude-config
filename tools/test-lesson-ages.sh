#!/usr/bin/env bash
# Tests for tools/lesson-ages.py: how old each lesson is, for the per day rate the lessons core is
# ranked by (claude-config#563). Age is from the FIRST appearance of the lesson's rule text, under any
# number, because a renumber (two Macs minting the same number, #199) would otherwise make an old
# lesson look new and give it a rate it never earned (L576). Each renumber is listed for a spot check.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/lesson-ages.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1200}"; fi; }

R="$WORK/repo"; mkdir -p "$R/payload"; git init -q "$R"
commit(){ # commit <date> <message>
  git -C "$R" add -A
  GIT_AUTHOR_DATE="$1T12:00:00" GIT_COMMITTER_DATE="$1T12:00:00" git -C "$R" -c user.name=t -c user.email=t@t commit -q -m "$2"
}
printf -- '- **L1. A test is only real once seen to fail.** Evidence.\n' > "$R/payload/LESSONS.md"
commit 2026-08-01 one
printf -- '- **L1. A test is only real once seen to fail.** Evidence.\n- **L2. Never destroy good state first.** More.\n' > "$R/payload/LESSONS.md"
commit 2026-08-10 two
# L2 renumbered to L5 on the 20th, same rule text: its age must stay from the 10th.
printf -- '- **L1. A test is only real once seen to fail.** Evidence.\n- **L5. Never destroy good state first.** More.\n' > "$R/payload/LESSONS.md"
commit 2026-08-20 renumber
# L6 wraps its rule over two lines, as almost every real entry does.
printf -- '- **L1. A test is only real once seen to fail.** Evidence.\n- **L5. Never destroy good state first.** More.\n- **L6. A long rule that wraps\n  onto a second line.** Evidence.\n' > "$R/payload/LESSONS.md"
commit 2026-09-01 wrap

# L7 arrives IN a merge commit, the way a sync's conflict resolution adds an entry, and `git log -p`
# shows no diff for a merge unless asked. Measured on the real file 2026-09-24: L187 came in that way
# and went undated.
git -C "$R" checkout -q -b side
printf 'side\n' > "$R/side.txt"; commit 2026-09-05 side
git -C "$R" checkout -q -
printf 'other\n' > "$R/other.txt"; commit 2026-09-06 main-moves
git -C "$R" -c user.name=t -c user.email=t@t merge -q --no-ff --no-commit side
printf -- '- **L7. Added while resolving a merge.** Evidence.\n' >> "$R/payload/LESSONS.md"
git -C "$R" add -A
GIT_AUTHOR_DATE=2026-09-07T12:00:00 GIT_COMMITTER_DATE=2026-09-07T12:00:00 git -C "$R" -c user.name=t -c user.email=t@t commit -q -m merge
out="$(python3 "$TOOL" --repo "$R" --today 2026-09-24 2>&1)"; rc=$?
check "L1 is dated from its first commit" $'L1\t2026-08-01\t54' "$out"
check "a renumbered lesson keeps the age of its rule text" $'L5\t2026-08-10\t45' "$out"
check "a wrapped rule is dated too" $'L6\t2026-09-01\t23' "$out"
check "a lesson added in a merge commit is dated" $'L7\t2026-09-07' "$out"
check "the renumber is listed for a spot check" "RENUMBERED L5 first seen as L2" "$out"
[ "$rc" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: exit $rc"; }

out="$(python3 "$TOOL" --repo "$WORK/none" --today 2026-09-24 2>&1)"; rc=$?
check "a repository without the lessons history is refused" "NO HISTORY" "$out"
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: no history must not exit 0"; }

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
