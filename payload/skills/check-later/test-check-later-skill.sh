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
# #1487, Dan's decision of 2026-10-22 (picker answer "Keep the exact time"): a wait that ends on a
# weekend or in the evening keeps the exact time it ends, said in so many words, never moved to the
# next working morning.
check "a weekend or evening end keeps the exact time" \
  "$(grep -qi 'weekend or in the evening keeps the exact ET time' "$SKILL" && echo ok || echo "no weekend and evening rule")"
check "it is never moved to the next working morning" \
  "$(grep -qi 'never moved to the next working morning' "$SKILL" && echo ok || echo "no rule against moving it")"
# #1487: the Description has a length limit, read back after writing, and what does not fit goes into
# a comment on the issue the row names.
check "the description has a length limit" \
  "$(grep -qi 'at most 600 characters' "$SKILL" && echo ok || echo "no length limit")"
check "what runs long moves into a comment on the issue" \
  "$(grep -qi 'moves into a comment on the issue' "$SKILL" && echo ok || echo "no rule for where the rest goes")"
check "the read back measures the length too" \
  "$(grep -qi 'and at most 600 characters' "$SKILL" && echo ok || echo "no length check on read back")"
# #1609, Dan 2026-10-23: the Description a cold session runs must tell it to close the loop on its
# own row, naming the row by its record id (never a text match, which can find nothing or the wrong
# row), moving Status to In progress when it reports and to Done only once every approved follow on
# is finished. Read from inside step 4 and step 7, so a phrase elsewhere in the file cannot pass it,
# and each joined into one line, so where the markdown happens to wrap cannot fail it.
step4="$(awk '/^### 4\. /{on=1; next} /^### /{on=0} on' "$SKILL" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
step7="$(awk '/^### 7\. /{on=1; next} /^### /{on=0} on' "$SKILL" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
list_section="$(awk '/^## The list/{on=1; next} /^## /{on=0} on' "$SKILL" 2>/dev/null)"
check "step 4 is there to read" "$([ -n "$step4" ] && echo ok || echo "no ### 4. section")"
check "step 7 is there to read" "$([ -n "$step7" ] && echo ok || echo "no ### 7. section")"
check "the Description template has a closing part for the row" \
  "$(grep -qi 'Close the row' <<< "$step4" && echo ok || echo "no closing part in step 4")"
check "the closing part sets the row with slack_update_list_record" \
  "$(grep -qF 'slack_update_list_record' <<< "$step4" && echo ok || echo "no slack_update_list_record in step 4")"
check "the closing part moves Status to In progress on reporting" \
  "$(grep -qF 'Status to `In progress`' <<< "$step4" && echo ok || echo "no In progress step")"
check "the closing part moves Status to Done" \
  "$(grep -qF 'to `Done`' <<< "$step4" && echo ok || echo "no Done step")"
check "Done waits for every follow on Dan approved" \
  "$(grep -qi 'once every follow on I approved is finished' <<< "$step4" && echo ok || echo "no rule holding Done for approved follow ons")"
check "the closing part names the row by its record id" \
  "$(grep -qi 'record id' <<< "$step4" && echo ok || echo "no record id in step 4")"
check "a long draft keeps the closing part whole" \
  "$(grep -qi 'keeps parts 1, 5, 6 and 7 whole' <<< "$step4" && echo ok || echo "closing part not kept whole on overflow")"
check "step 7 writes the record id back into the Description" \
  "$(grep -qi 'record id' <<< "$step7" && grep -qF 'slack_update_list_record' <<< "$step7" && echo ok || echo "no write back of the record id")"
check "the read back confirms the Description names its own record id" \
  "$(grep -qi 'names its own record id' <<< "$step7" && echo ok || echo "no read back of the record id")"
check "the schema check confirms the Status options the row moves through" \
  "$(grep -qF '`In progress`' <<< "$list_section" && grep -qF '`Done`' <<< "$list_section" && echo ok || echo "The list section names no In progress and Done options")"
check "the skill holds no long dash" \
  "$(perl -CSD -ne '$f = 1 if /[\x{2013}\x{2014}]/; END { exit($f ? 1 : 0) }' "$SKILL" && echo ok || echo "found one")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
