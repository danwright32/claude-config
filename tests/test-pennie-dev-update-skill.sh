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
# One paragraph per line, so a claim is judged inside the paragraph that makes it, never across two
# unrelated ones (L178), and rewrapping cannot hide it (L278).
paras="$(awk 'BEGIN { RS = ""; ORS = "\n" } { gsub(/[[:space:]]+/, " "); print }' "$SKILL")"
has_para(){   # every argument must appear in ONE paragraph, case insensitive
  local p
  p="$(printf '%s\n' "$paras" | grep -i -F -- "$1")" || return 1
  shift
  local n
  for n in "$@"; do p="$(printf '%s\n' "$p" | grep -i -F -- "$n")" || return 1; done
  return 0
}

has_para "no launch mode" && check "the no launch mode paragraph is gone" "the skill still says there is no launch mode" \
  || check "the no launch mode paragraph is gone" ok
has_para "ask for a starting date" && check "a first run no longer asks for a starting date" "the skill still asks for a starting date" \
  || check "a first run no longer asks for a starting date" ok
has_para "first appearance" "no \`lastEnd\`" "in general" && check "a repo with no lastEnd is introduced in general" ok \
  || check "a repo with no lastEnd is introduced in general" "no paragraph names a first appearance, a repo with no lastEnd, and an introduction in general together"
has_para "never" "one by one" && check "the introduction never lists the product's changes one by one" ok \
  || check "the introduction never lists the product's changes one by one" "no paragraph says the first appearance never lists changes one by one"
has_para "what it is" "who uses it" "when to open it" "what it checks" && check "the introduction covers what it is, who uses it, when to open it and what it checks" ok \
  || check "the introduction covers what it is, who uses it, when to open it and what it checks" "no paragraph lists all four"
has_para "\`lastEnd\`" "newest" "merged_at" "changes only" && check "the window then starts after the newest merge, so later runs report changes only" ok \
  || check "the window then starts after the newest merge, so later runs report changes only" "no paragraph sets lastEnd from the newest merged_at at the introduction"
has_para "sonar shouldn't announce specific updates" && check "Dan's decision is quoted with its date" "$(has_para "sonar shouldn't announce specific updates" "2026-09-28" && echo ok || echo 'quoted without its date')" \
  || check "Dan's decision is quoted with its date" "the decision is not quoted"

echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
