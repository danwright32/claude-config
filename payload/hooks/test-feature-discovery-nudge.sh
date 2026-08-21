#!/usr/bin/env bash
# Tests for feature-discovery-nudge.sh (claude-config#124).
#
# It injects one standing instruction into every prompt, and its whole design is that it does NOT
# try to detect a feature request: the instruction is conditional and the model self filters. So
# there is little behaviour to check and exactly one way it fails, which is by printing nothing, or
# printing something that is no longer an instruction, on every prompt for as long as nobody looks.
# Nothing would report that.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$DIR/feature-discovery-nudge.sh"
N="$DIR/tdd-nudge.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

out="$(printf '{"prompt":"add a saved views feature"}' | bash "$H" 2>/dev/null)"; code=$?
[ "$code" -eq 0 ] \
  && check "it exits cleanly" ok || check "it exits cleanly" "exit=$code"
[ -n "$out" ] \
  && check "it prints something, which is the only thing it does" ok \
  || check "it prints something, which is the only thing it does" "it printed nothing"
printf '%s' "$out" | grep -qi 'feature-discovery' \
  && check "and what it prints names the skill it is pointing at" ok \
  || check "and what it prints names the skill it is pointing at" "out=$out"
printf '%s' "$out" | grep -qi 'no-op\|no op' \
  && check "and says when it does not apply, which is what stops it firing on everything" ok \
  || check "and says when it does not apply, which is what stops it firing on everything" "out=$out"

# The point of its design: it does NOT look at the prompt. A version that started grepping for
# keywords would be a different hook, and the tell is that a prompt about nothing in particular
# gets the same text.
out_other="$(printf '{"prompt":"what time is it"}' | bash "$H" 2>/dev/null)"
[ "$out_other" = "$out" ] \
  && check "the same text goes out whatever the prompt says" ok \
  || check "the same text goes out whatever the prompt says" "it varied by prompt"
out_empty="$(printf '' | bash "$H" 2>/dev/null)"; code_empty=$?
[ "$out_empty" = "$out" ] && [ "$code_empty" -eq 0 ] \
  && check "and with no payload at all, so it cannot be broken by a payload change" ok \
  || check "and with no payload at all, so it cannot be broken by a payload change" "out=$out_empty exit=$code_empty"

# The skill it names has to exist, or the instruction sends the session after nothing (L111: a
# message telling somebody how to recover must name something that is actually there).
SKILLDIR="$DIR/../skills/feature-discovery"
[ -f "$SKILLDIR/SKILL.md" ] \
  && check "the skill it points at is really in the payload" ok \
  || check "the skill it points at is really in the payload" "no SKILL.md at $SKILLDIR"

# It is deliberately the same shape as tdd-nudge.sh. Checked because the two are meant to stay one
# pattern, and a divergence is the kind that is only noticed when one of them stops working.
if [ -f "$N" ]; then
  out_tdd="$(printf '' | bash "$N" 2>/dev/null)"
  [ -n "$out_tdd" ] && [ "$out_tdd" != "$out" ] \
    && check "its sibling nudge still works the same way and says something different" ok \
    || check "its sibling nudge still works the same way and says something different" "tdd-nudge said: [$out_tdd]"
else
  check "its sibling nudge still works the same way and says something different" "tdd-nudge.sh is gone"
fi

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
