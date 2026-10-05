#!/usr/bin/env bash
# The pennie-dev-update skill's first appearance of a product (claude-config#588).
#
# On 2026-09-28 the skill asked Dan for a starting date for Sonar's first run and was about to list
# its merged PRs one by one. Dan answered: "sonar shouldn't announce specific updates. this would
# be the announcement of sonar in general." So a repo with no lastEnd is introduced in general, and
# its window then starts after its newest merge, so later runs report changes only. The skill is
# prose Claude follows, so what is held here is that the prose says so, and that the paragraphs
# contradicting Dan's decision (no launch mode, ask for a starting date) are gone (L252: a reversed
# decision deletes the text defending it).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
SKILL="$DIR/../payload/skills/pennie-dev-update/SKILL.md"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
if [ ! -f "$SKILL" ]; then
  echo "FAIL: the skill is not at $SKILL, so nothing was checked."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
# The claims are held to the "### First appearance" section of the skill, never anywhere in the
# file, and each one as the exact sentence that makes it, case and all, inside ONE paragraph of that
# section with its whitespace collapsed (so rewrapping cannot hide it, L278). #790 found the first
# version matched loose words case insensitively anywhere in a paragraph, so a rewording that
# dropped the claim, or unrelated text holding the words, passed (L178, L135). A rewording now
# fails here and the sentence below is updated with it: the wording is the behaviour Claude follows.
section="$(awk '/^### First appearance$/ { f = 1; next } f && /^(#|---)/ { exit } f' "$SKILL")"
paras="$(printf '%s\n' "$section" | awk 'BEGIN { RS = ""; ORS = "\n" } { gsub(/[[:space:]]+/, " "); print }')"
claim(){   # $1 = what it holds  $2 = the exact sentence, inside one paragraph of the section
  if [ -z "$section" ]; then check "$1" "the skill has no '### First appearance' section"; return; fi
  if printf '%s\n' "$paras" | grep -q -F -- "$2"; then check "$1" ok; else check "$1" "the section does not say: $2"; fi
}
gone(){   # $1 = what it holds  $2 = a phrase that must appear nowhere in the skill, in any case
  if grep -q -i -F -- "$2" "$SKILL"; then check "$1" "the skill still says: $2"; else check "$1" ok; fi
}

gone "the no launch mode paragraph is gone" "no launch mode"
gone "a first run no longer asks for a starting date" "ask for a starting date"
claim "a repo with no lastEnd is introduced in general" \
  'A repo with no `lastEnd` at all is a product appearing for the first time, and it is introduced in general.'
claim "the introduction never lists the product's merged PRs one by one" \
  "the product's merged PRs are never listed one by one."
claim "Dan's decision is quoted with its date" \
  "Dan decided this on 2026-09-28, when the skill asked him for a starting date for Sonar: \"sonar shouldn't announce specific updates. this would be the announcement of sonar in general.\""
claim "the introduction covers what it is, who uses it, when to open it, what it checks and how to share a result" \
  "what it is, who uses it, when to open it, what it checks, and how to share a result"
claim "the window then starts after the newest merge in production, so later runs report changes only" \
  'set that repo'"'"'s `lastEnd` to the `merged_at` of its newest merged PR that reached production (section 4), so the next run reports changes only'

# The checks above can fail: the same claims against a section that does not make them.
section_real="$section"; paras_real="$paras"
section="An unrelated paragraph mentioning lastEnd, newest, merged_at and changes only, in general, never one by one."
paras="$section"
before_fail=$fail
claim "(control) a section without the claim" 'A repo with no `lastEnd` at all is a product appearing for the first time, and it is introduced in general.' >/dev/null
if [ "$fail" -eq $((before_fail + 1)) ]; then fail=$before_fail; check "the claim check fails on loose words that make no claim" ok
else check "the claim check fails on loose words that make no claim" "it passed text that makes no claim"; fi
section="$section_real"; paras="$paras_real"

echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
