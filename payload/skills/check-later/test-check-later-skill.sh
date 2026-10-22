#!/usr/bin/env bash
# Tests for the check-later skill's instructions.
#
# The skill writes rows to a Slack list by column KEY, so a key that drifts from the list's schema
# writes nothing or the wrong column; it must only ever run when Dan types it; and the list's
# Reminder Saved box is Dan's own record that he set the reminder, so the skill must never tick it.
# Nothing here reaches Slack. CHECK_LATER_SKILL points the suite at another copy, which is how a
# broken copy is shown to fail.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${CHECK_LATER_SKILL:-$DIR/SKILL.md}"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

check "the skill is there to read" "$([ -f "$SKILL" ] && echo ok || echo "no $SKILL")"
front="$(awk 'NR==1 && $0=="---" {on=1; next} on && $0=="---" {exit} on {print}' "$SKILL" 2>/dev/null)"

check "its name is check-later" "$(grep -qx 'name: check-later' <<< "$front" && echo ok || echo "frontmatter: $front")"
check "it runs only when Dan types it" \
  "$(grep -qx 'disable-model-invocation: true' <<< "$front" && echo ok || echo "no disable-model-invocation: true")"
check "its trigger is /check-later" "$(grep -qx 'trigger: /check-later' <<< "$front" && echo ok || echo "no trigger line")"

# The list and every column key the skill writes, as read from the list's schema on 2026-10-22.
for want in F0CB5JMEM2P '`name`' '`people`' Col07QBFU85SB Col0CAWEL5RFH Col0CBFHLQX44 Col0CBDTLART3; do
  check "the skill names $want" "$(grep -qF "$want" "$SKILL" && echo ok || echo "missing")"
done

check "it never ticks Reminder Saved itself" \
  "$(grep -qi 'never set it to true' "$SKILL" && echo ok || echo "no rule keeping Reminder Saved for Dan")"
check "it pins the reminder card" "$(grep -qF 'mcp__manual-steps__steps' "$SKILL" && echo ok || echo "no card tool")"
check "the description is one line" "$(grep -qi 'ONE line with no line breaks' "$SKILL" && echo ok || echo "no one line rule")"
check "it reads the list back after writing" "$(grep -qi 'read the list back' "$SKILL" && echo ok || echo "no read back")"
check "it shows Dan each draft before writing" \
  "$(grep -qi 'Nothing is written before Dan picks' "$SKILL" && echo ok || echo "no approval before write")"
check "it counts a wait from going live, not the merge" \
  "$(grep -qi 'A merge time is not a live time' "$SKILL" && echo ok || echo "no live time rule")"
check "the skill holds no long dash" \
  "$(perl -CSD -ne '$f = 1 if /[\x{2013}\x{2014}]/; END { exit($f ? 1 : 0) }' "$SKILL" && echo ok || echo "found one")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
