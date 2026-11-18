#!/usr/bin/env bash
# The feature-discovery skill offers a system diagram once the feature is understood (claude-config#787).
#
# A discovery session about a feature with several connected parts handed off to planning with
# no picture of how the parts fit. The skill now offers, never forces, a simple diagram of the
# parts and the data passing between them, shown as a published artifact because Dan cannot see a
# file card delivered into the chat, and skips the offer for a feature with one moving part. The
# skill is prose Claude follows, so what is held here is that the prose says each of those things,
# inside its own section, placed after shared understanding and before building starts.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
SKILL="$DIR/../payload/skills/feature-discovery/SKILL.md"
HEADING='### Offer a picture of the parts'
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
if [ ! -f "$SKILL" ]; then
  echo "FAIL: the skill is not at $SKILL, so nothing was checked."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# The section sits inside "## After shared understanding", so it is reached once the picture is
# shared and before the hand off to planning, never during the interview or after building starts.
line_of(){   # $1 = an exact line; prints the number of its first occurrence, nothing when absent
  awk -v want="$1" '$0 == want { print NR; exit }' "$SKILL"
}
after_line="$(line_of '## After shared understanding')"
pic_line="$(line_of "$HEADING")"
build_line="$(line_of '## When you start building')"
if [ -z "$pic_line" ]; then
  check "the skill has a '$HEADING' section" "it has none"
elif [ -z "$after_line" ] || [ -z "$build_line" ]; then
  check "the section sits between shared understanding and building" "a bounding heading is missing"
elif [ "$after_line" -lt "$pic_line" ] && [ "$pic_line" -lt "$build_line" ]; then
  check "the section sits between shared understanding and building" ok
else
  check "the section sits between shared understanding and building" "it is at line $pic_line, outside $after_line to $build_line"
fi

# Each claim is the exact sentence that makes it, inside ONE paragraph of the section with its
# whitespace collapsed, so rewrapping cannot hide it (L278) and loose words elsewhere cannot pass
# it (L178, L135). A rewording fails here and the sentence below is updated with it.
section="$(awk -v h="$HEADING" '$0 == h { f = 1; next } f && /^(#|---)/ { exit } f' "$SKILL")"
paras="$(printf '%s\n' "$section" | awk 'BEGIN { RS = ""; ORS = "\n" } { gsub(/[[:space:]]+/, " "); print }')"
claim(){   # $1 = what it holds  $2 = the exact sentence, inside one paragraph of the section
  if [ -z "$section" ]; then check "$1" "the skill has no '$HEADING' section"; return; fi
  local p
  while IFS= read -r p; do
    case "$p" in *"$2"*) check "$1" ok; return ;; esac
  done <<< "$paras"
  check "$1" "the section does not say: $2"
}

claim "the offer covers the parts and the data between them" \
  "offer Dan a simple diagram of those parts and the data passing between them"
claim "it is offered, never forced" \
  "Ask with an AskUserQuestion picker, and draw it only when Dan says yes."
claim "a feature with one moving part gets no offer" \
  "Skip the offer when the feature has one moving part."
claim "the diagram is shown as a published artifact" \
  "Show it as a published artifact with the Artifact tool, loading the artifact-diagramming skill first"
claim "never only as a file card" \
  "never only as a file or a file card in the chat, which Dan cannot see."

# The checks above can fail: the same claims against a section that does not make them.
section_real="$section"; paras_real="$paras"
section="An unrelated paragraph mentioning a diagram, a picker, an artifact, one moving part and a file card."
paras="$section"
before_fail=$fail
claim "(control) a section without the claim" "Skip the offer when the feature has one moving part." >/dev/null
if [ "$fail" -eq $((before_fail + 1)) ]; then fail=$before_fail; check "the claim check fails on loose words that make no claim" ok
else check "the claim check fails on loose words that make no claim" "it passed text that makes no claim"; fi
section="$section_real"; paras="$paras_real"

echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
