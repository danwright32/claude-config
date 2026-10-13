#!/bin/bash
# Tests for tools/check-mod-skill-contracts.sh (claude-config#1057): a mod and the skill it enforces
# state one contract version, raised together. Each disagreement it exists to catch is built as a
# fixture and seen to fail (L1); then the real payload is checked, and must have at least one pair,
# so a stamp removed from both sides cannot pass as nothing to check (L98).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
CHECK="$ROOT/tools/check-mod-skill-contracts.sh"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-mod-skill-contracts.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A payload with one mod and one skill: $2 the mod's CONTRACT (empty for none), $3 the skill's stamp
# number (empty for none), $4 the number the skill's example carries.
payload(){   # $1 = folder  $2 $3 $4 as above
  mkdir -p "$1/mods/guard/hooks" "$1/skills/steps"
  if [ -n "$2" ]; then printf 'export const CONTRACT = %s\n' "$2" > "$1/mods/guard/hooks/rules.ts"; else printf 'export const X = 1\n' > "$1/mods/guard/hooks/rules.ts"; fi
  { printf -- '---\nname: steps\n---\n'
    [ -n "$3" ] && printf '<!-- guard contract: %s -->\n' "$3"
    printf '```json\n{ "metadata": { "source": "x", "contract": %s } }\n```\n' "$4"
  } > "$1/skills/steps/SKILL.md"
}
run(){ out="$(bash "$CHECK" "$1" 2>&1)"; code=$?; }

payload "$TMP/agree" 2 2 2
run "$TMP/agree"
[ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '1 mod and skill contract pairs checked' && check "agreeing stamps pass, counted" ok || check "agreeing stamps pass, counted" "exit $code: $out"

payload "$TMP/mod-old" 1 2 2
run "$TMP/mod-old"
[ "$code" -eq 1 ] && printf '%s' "$out" | grep -q "guard's CONTRACT is 1: raise both together" && check "a mod behind its skill fails, naming both numbers" ok || check "a mod behind its skill fails, naming both numbers" "exit $code: $out"

payload "$TMP/example-old" 2 2 1
run "$TMP/example-old"
[ "$code" -eq 1 ] && printf '%s' "$out" | grep -q 'shows "contract": 1 in an example' && check "an example left at the old number fails" ok || check "an example left at the old number fails" "exit $code: $out"

payload "$TMP/unstamped" 2 "" 2
run "$TMP/unstamped"
[ "$code" -eq 1 ] && printf '%s' "$out" | grep -q 'guard declares a CONTRACT, and no skill' && check "a mod's contract no skill states fails" ok || check "a mod's contract no skill states fails" "exit $code: $out"

payload "$TMP/no-mod-contract" "" 2 2
run "$TMP/no-mod-contract"
[ "$code" -eq 1 ] && printf '%s' "$out" | grep -q 'guard declares no CONTRACT' && check "a stamp naming a mod with no contract fails" ok || check "a stamp naming a mod with no contract fails" "exit $code: $out"

payload "$TMP/twice" 2 2 2
printf 'export const CONTRACT = 3\n' > "$TMP/twice/mods/guard/hooks/register.ts"
run "$TMP/twice"
[ "$code" -eq 1 ] && printf '%s' "$out" | grep -q 'declares CONTRACT more than once' && check "a contract declared twice fails" ok || check "a contract declared twice fails" "exit $code: $out"

run "$TMP/absent"
[ "$code" -eq 2 ] && check "a missing payload is its own exit code" ok || check "a missing payload is its own exit code" "exit $code: $out"

# The real payload: the design round guard and the design rounds skill agree, and there is a pair.
run "$ROOT/payload"
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q -E '^check-mod-skill-contracts: [1-9][0-9]* mod and skill contract pairs checked'; then
  check "the payload's mods and skills agree" ok
else
  check "the payload's mods and skills agree" "exit $code: $out"
fi

[ -x "$CHECK" ] && check "tools/check-mod-skill-contracts.sh is executable" ok || check "tools/check-mod-skill-contracts.sh is executable" "not executable"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
