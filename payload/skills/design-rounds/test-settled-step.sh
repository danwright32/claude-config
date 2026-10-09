#!/usr/bin/env bash
# The design rounds skill's last step and the design round guard mod must agree (claude-config#978).
#
# The guard holds every look changing edit until Dan answers Settled to "Is this design settled?",
# which it recognises by the question's metadata source. That question is asked only because this
# skill says to ask it, so the words the skill tells Claude to send are read here against the
# constants the guard itself reads them by (payload/mods/design-round-guard/hooks/rules.ts), never
# against a copy typed into this test (L638). A skill that drifted from the guard would leave every
# design round unable to settle anything, and every screen edit held.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$DIR/SKILL.md"
RULES="$DIR/../../mods/design-round-guard/hooks/rules.ts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

# One string constant of the guard's, as rules.ts declares it.
constant() { sed -n "s/^export const $1 = '\\(.*\\)'\$/\\1/p" "$RULES"; }

if [[ ! -f "$RULES" ]]; then
  bad "the guard's rules are not at $RULES, so the skill cannot be checked against them"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 1
fi

names=(SETTLED_SOURCE SETTLED_QUESTION HEADER SETTLED_YES SETTLED_NO)
declare -a values=()
for n in "${names[@]}"; do
  v="$(constant "$n")"
  if [[ -z "$v" ]]; then bad "rules.ts declares no string constant $n"; else ok; fi
  values+=("$v")
done
source_v="${values[0]}"; question_v="${values[1]}"; header_v="${values[2]}"; yes_v="${values[3]}"; no_v="${values[4]}"

# The call the skill tells Claude to make: its JSON block under the last step's heading.
block_of() { awk '/^## The last step: is this design settled\?/{s=1} s&&/^```json/{b=1;next} b&&/^```/{exit} b{print}' "$1"; }

# Whether a skill text asks the guard's question in the guard's words. Prints what it lacks.
lacks() {
  local block
  block="$(block_of "$1")"
  [[ -z "$block" ]] && { echo "no json block under the last step's heading"; return; }
  [[ "$block" == *"\"source\": \"$source_v\""* ]] || echo "metadata source $source_v"
  [[ "$block" == *"\"question\": \"$question_v\""* ]] || echo "the question $question_v"
  [[ "$block" == *"\"header\": \"$header_v\""* ]] || echo "the header $header_v"
  [[ "$block" == *"\"label\": \"$yes_v\""* ]] || echo "the answer $yes_v"
  [[ "$block" == *"\"label\": \"$no_v\""* ]] || echo "the answer $no_v"
  [[ "$block" == *'"multiSelect": false'* ]] || echo "one choice only"
  # The block must be the JSON Claude sends, so it has to parse.
  printf '%s\n' "$block" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null || echo "JSON that parses"
}

missing="$(lacks "$SKILL")"
if [[ -z "$missing" ]]; then ok; else bad "SKILL.md's last step does not ask the guard's question in its words; it lacks: $(echo "$missing" | paste -sd';' -)"; fi

# The skill says what records the settlement, and what never does.
grep -q 'Only Dan.s own choice of Settled records it' "$SKILL" && ok || bad "SKILL.md does not say only Dan's choice of Settled records it"
grep -q '"issue": <the issue number>' "$SKILL" && ok || bad "SKILL.md does not show naming the issue in the metadata"
# The skill reaches every project, so a literal number there is one project's issue, and the worked
# example is what gets copied (L562): it names the issue by a placeholder, never a number (#987 review).
grep -q -E '"issue": [0-9]' "$SKILL" && bad "SKILL.md shows a literal issue number in the metadata, which every project would copy" || ok

# #1010: Settled was recorded for the session's folder (Slate) while the refused edit was on another
# project. The worked call names the refused call, and the skill says how to name a project when no
# call waits, never leaving it to the session's folder.
# The worked call names the project by a path, which holds whether or not a refused edit waits (a
# "call" there would be copied into rounds with no refusal, and refused: lessons review of #1010).
grep -q '"path": "<a folder or file in the project' <<< "$(block_of "$SKILL")" && ok || bad "SKILL.md's closing call does not name the project by a path in its metadata"
grep -q '"call": "<the id the refusal named>"' "$SKILL" && ok || bad "SKILL.md does not show naming the refused call when one waits"
grep -q '"call"' <<< "$(block_of "$SKILL")" && bad "SKILL.md's worked closing call carries a \"call\", which a round with no refused edit would copy" || ok

# #1010: a round with nothing to render (a data only prop change) had no exit but a switcher. The
# skill gives one, by the guard's own third answer, read from rules.ts (L638).
not_look="$(constant NOT_LOOK)"
skip_source="$(constant SKIP_SOURCE)"
exit_section="$(awk '/^## When there is nothing to render/{s=1;print;next} s&&/^## /{exit} s{print}' "$SKILL")"
if [[ -z "$not_look" || -z "$skip_source" ]]; then bad "rules.ts declares no NOT_LOOK or SKIP_SOURCE constant"
elif [[ -z "$exit_section" ]]; then bad "SKILL.md has no section for a round with nothing to render"
else
  [[ "$exit_section" == *"$not_look"* ]] && ok || bad "the nothing to render section does not name the guard's answer $not_look"
  [[ "$exit_section" == *"\"source\": \"$skip_source:"* ]] && ok || bad "the nothing to render section does not show the guard's own question's source"
  [[ "$exit_section" == *"no switcher"* ]] && ok || bad "the nothing to render section does not say no switcher is built"
fi

# The check is seen to fail: a skill whose source drifted from the guard's is caught.
sed "s/\"source\": \"$source_v\"/\"source\": \"design-done\"/" "$SKILL" > "$TMP/drifted.md"
drift="$(lacks "$TMP/drifted.md")"
[[ "$drift" == *"metadata source $source_v"* ]] && ok || bad "a skill with a drifted source was not caught (got: $drift)"
# And one whose step was removed altogether.
awk '/^## The last step/{skip=1} /^## The deliverable/{skip=0} !skip' "$SKILL" > "$TMP/removed.md"
gone="$(lacks "$TMP/removed.md")"
[[ "$gone" == *"no json block"* ]] && ok || bad "a skill without the last step was not caught (got: $gone)"

echo
echo "passed: $pass, failed: $fail"
# The runner parses this exact shape, so nothing else goes on this line.
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
