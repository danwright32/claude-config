#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans skills/ agents/
# Plans and build issues carry a "Must always be true" list, and each rule names what keeps it true
# (claude-config#3457).
#
# A test checks the cases somebody thought of. A rule such as "a customer is never charged twice for
# one purchase" can be checked against every case a tool can generate, but only when it was written
# down before the build, and no plan, interview or build issue had a place for one. Three things are
# held here:
#   the reader   skills/milestone/must-hold.sh reads the list by one rule, names every fault in it,
#                and never reports a file with no list, or half a list, as a sound one
#   the home     skills/milestone/MUST-ALWAYS-BE-TRUE.md states the list's rules, and its own worked
#                example passes the reader, since an example is copied more faithfully than the
#                rule beside it (L562)
#   one home     the five skills that produce or consume the list point at that file and none of
#                them spells the list's lines out again
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
SKILLS="$DIR/../payload/skills"
AGENTS="$DIR/../payload/agents"
HOME_FILE="$SKILLS/milestone/MUST-ALWAYS-BE-TRUE.md"
READER="$SKILLS/milestone/must-hold.sh"
POINTER='~/.claude/skills/milestone/MUST-ALWAYS-BE-TRUE.md'
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------------------------
# The reader
# ---------------------------------------------------------------------------------------------
fixture(){   # $1 = file name; the body arrives on stdin
  cat > "$TMP/$1"
}
runs(){   # $1 = name  $2 = wanted exit  $3 = text the output must hold ("" for none)  rest = arguments
  local name="$1" want="$2" needle="$3" out rc
  shift 3
  if [ ! -f "$READER" ]; then check "$name" "there is no reader at $READER"; return; fi
  out="$(bash "$READER" "$@" 2>&1)"; rc=$?
  if [ "$rc" != "$want" ]; then check "$name" "exit $rc, wanted $want: $out"; return; fi
  case "$out" in *"$needle"*) check "$name" ok ;; *) check "$name" "exit $rc as wanted, but the output does not hold '$needle': $out" ;; esac
}

fixture good.md <<'EOF'
## Why

Something.

## Must always be true

- R1. A customer is never charged twice for one purchase.
  - Still possible: A customer can pay for a purchase.
  - Kept true by: database constraint `payments_one_per_purchase`
- R2. A refund is never larger than the payment it refunds.
  - Still possible: A customer can be refunded in full.
  - Kept true by: nothing yet, phase 2 adds a property test

Not covered: a charge made outside the app.

## Open questions

None
EOF
runs "a well formed list passes" 0 "2 rules" check "$TMP/good.md"

fixture no-holder.md <<'EOF'
## Must always be true

- R1. A customer is never charged twice for one purchase.
  - Still possible: A customer can pay for a purchase.

Not covered: a charge made outside the app.
EOF
runs "a rule that names nothing keeping it true is a fault" 1 "R1 has no 'Kept true by:' line" check "$TMP/no-holder.md"

fixture no-possible.md <<'EOF'
## Must always be true

- R1. A customer is never charged twice for one purchase.
  - Kept true by: nothing yet

Not covered: a charge made outside the app.
EOF
runs "a rule with nothing still possible beside it is a fault" 1 "R1 has no 'Still possible:' line" check "$TMP/no-possible.md"

fixture loose-holder.md <<'EOF'
## Must always be true

- R1. A customer is never charged twice for one purchase.
  - Still possible: A customer can pay for a purchase.
  - Kept true by: careful ordering in the payment code

Not covered: a charge made outside the app.
EOF
runs "a holder that is no kind of check is a fault" 1 "R1 is kept true by no known kind" check "$TMP/loose-holder.md"

fixture unnamed-holder.md <<'EOF'
## Must always be true

- R1. A customer is never charged twice for one purchase.
  - Still possible: A customer can pay for a purchase.
  - Kept true by: test

Not covered: a charge made outside the app.
EOF
runs "a kind with no name after it is a fault" 1 "R1 is kept true by no known kind" check "$TMP/unnamed-holder.md"

fixture no-not-covered.md <<'EOF'
## Must always be true

- R1. A customer is never charged twice for one purchase.
  - Still possible: A customer can pay for a purchase.
  - Kept true by: nothing yet
EOF
runs "a list with no Not covered line is a fault" 1 "no 'Not covered:' line" check "$TMP/no-not-covered.md"

fixture twice.md <<'EOF'
## Must always be true

- R1. A customer is never charged twice for one purchase.
  - Still possible: A customer can pay for a purchase.
  - Kept true by: nothing yet
- R1. A refund is never larger than the payment it refunds.
  - Still possible: A customer can be refunded in full.
  - Kept true by: nothing yet

Not covered: a charge made outside the app.
EOF
runs "a number used for two rules is a fault" 1 "R1 is used for more than one rule" check "$TMP/twice.md"

fixture stray.md <<'EOF'
## Must always be true

- R1. A customer is never charged twice for one purchase,
  whatever the retry does.
  - Still possible: A customer can pay for a purchase.
  - Kept true by: nothing yet

Not covered: a charge made outside the app.
EOF
runs "a line that is no part of the list is named, never dropped" 1 "line 4 is not part of the list" check "$TMP/stray.md"

fixture none.md <<'EOF'
## Must always be true

None: this phase only rewords two labels, so it stores and sends nothing.
EOF
runs "a feature with no such rule says None and why" 0 "none, with a reason" check "$TMP/none.md"

fixture bare-none.md <<'EOF'
## Must always be true

None
EOF
runs "None with no reason is a fault" 1 "None needs its reason" check "$TMP/bare-none.md"

fixture empty.md <<'EOF'
## Must always be true

## Open questions

None
EOF
runs "a heading with nothing under it is a fault" 1 "the section is empty" check "$TMP/empty.md"

fixture absent.md <<'EOF'
## Why

The rules must always be true, as the plan says.

## Open questions

None
EOF
runs "a body with no list is reported as having none, never as sound" 3 "no 'Must always be true' section" check "$TMP/absent.md"

fixture fenced.md <<'EOF'
## Why

The format is:

```
## Must always be true

None: an example inside a code block.
```
EOF
runs "a heading inside a fenced code block is not the list" 3 "no 'Must always be true' section" check "$TMP/fenced.md"

runs "a file that is not there is refused, not read as empty" 2 "cannot read" check "$TMP/not-there.md"
runs "an unknown command prints the usage" 2 "usage:" frobnicate "$TMP/good.md"

# A pull request repeats the list, and every rule something keeps true says what was seen to fail.
fixture built.md <<'EOF'
## Must always be true

- R1. A customer is never charged twice for one purchase.
  - Still possible: A customer can pay for a purchase.
  - Kept true by: database constraint `payments_one_per_purchase`
  - Seen to fail: not ok 14 a second payment for one purchase is refused
- R2. A refund is never larger than the payment it refunds.
  - Still possible: A customer can be refunded in full.
  - Kept true by: nothing yet, no phase of this plan builds it

Not covered: a charge made outside the app.
EOF
runs "a built list with every holder seen to fail passes" 0 "2 rules" check --built "$TMP/built.md"
runs "a built list is refused while a holder was never seen to fail" 1 "R1 has no 'Seen to fail:' line" check --built "$TMP/good.md"

# One line per rule, tab separated, for whatever reads the rules next (a model check, #3471).
if [ -f "$READER" ]; then
  listed="$(bash "$READER" list "$TMP/good.md" 2>&1)"; rc=$?
  want="$(printf 'R1\tA customer is never charged twice for one purchase.\tA customer can pay for a purchase.\tdatabase constraint\t`payments_one_per_purchase`\nR2\tA refund is never larger than the payment it refunds.\tA customer can be refunded in full.\tnothing yet\tphase 2 adds a property test')"
  if [ "$rc" = 0 ] && [ "$listed" = "$want" ]; then check "list prints one tab separated line per rule" ok
  else check "list prints one tab separated line per rule" "exit $rc: $listed"; fi
  listed="$(bash "$READER" list "$TMP/no-holder.md" 2>/dev/null)"; rc=$?
  if [ "$rc" = 1 ] && [ -z "$listed" ]; then check "list prints no rules from a list with a fault" ok
  else check "list prints no rules from a list with a fault" "exit $rc, printed: $listed"; fi
else
  check "list prints one tab separated line per rule" "there is no reader at $READER"
  check "list prints no rules from a list with a fault" "there is no reader at $READER"
fi

# ---------------------------------------------------------------------------------------------
# The home
# ---------------------------------------------------------------------------------------------
if [ ! -f "$HOME_FILE" ]; then
  check "the list's rules have a home" "there is no $HOME_FILE"
else
  check "the list's rules have a home" ok
  # Its worked example is the indented block that starts with the list's own heading.
  awk '/^    ## Must always be true[ \t]*$/ { f = 1 } f && /^[^ \t]/ { exit } f { sub(/^    /, ""); print }' "$HOME_FILE" > "$TMP/example.md"
  if [ ! -s "$TMP/example.md" ]; then
    check "the home shows a worked example" "no indented block starting with '## Must always be true'"
  else
    check "the home shows a worked example" ok
    runs "the worked example obeys the rules it sits beside" 0 "rules" check "$TMP/example.md"
    example_list="$(bash "$READER" list "$TMP/example.md" 2>/dev/null)"
    case "$example_list" in *"	nothing yet	"*) check "the example shows a rule nothing keeps true yet" ok ;; *) check "the example shows a rule nothing keeps true yet" "no rule in it says nothing yet" ;; esac
    named="$(printf '%s\n' "$example_list" | awk -F '\t' '$4 != "" && $4 != "nothing yet"' | wc -l | tr -d ' ')"
    if [ "$named" -ge 1 ]; then check "the example shows a rule with a named holder" ok; else check "the example shows a rule with a named holder" "every rule in it says nothing yet"; fi
  fi
  home_text="$(tr '\n' ' ' < "$HOME_FILE" | tr -s ' ')"
  for kind in 'database constraint' 'type' 'test' 'property test' 'model check' 'guard' 'nothing yet'; do
    case "$home_text" in *"\`$kind\`"*) check "the home names the kind: $kind" ok ;; *) check "the home names the kind: $kind" "it never writes \`$kind\`" ;; esac
  done
  says(){   # $1 = what it holds  $2 = the exact words
    case "$home_text" in *"$2"*) check "$1" ok ;; *) check "$1" "the home does not say: $2" ;; esac
  }
  says "a rule is one sentence in the user's words" "One sentence, in the words a user of the feature would use"
  says "a holder is proved by taking it out" "take it out, or break the rule where the holder is itself a test, watch the rule's check fail, and put it back"
  says "Dan reviews the rules and what they leave out" "Dan reads the rules and this line, and that is his review"
  says "a missing list is never read as a considered one" 'None: <why>'
  says "the home names the reader" 'bash ~/.claude/skills/milestone/must-hold.sh check'
  # It loads whenever a plan is drafted, so it stays short.
  size="$(wc -c < "$HOME_FILE" | tr -d ' ')"
  if [ "$size" -le 6000 ]; then check "the home is at most 6000 bytes" ok; else check "the home is at most 6000 bytes" "it is $size"; fi
fi
if [ -x "$READER" ]; then check "the reader is there and executable" ok; else check "the reader is there and executable" "$READER missing or not executable"; fi

# ---------------------------------------------------------------------------------------------
# One home
# ---------------------------------------------------------------------------------------------
# The two lines only the list has. A skill or agent that writes either one out is a second copy of
# the format, which then drifts from the home.
copies="$(grep -r -l -E 'Still possible:|Kept true by:' "$SKILLS" "$AGENTS" --include='*.md' 2>/dev/null | grep -v -F "$HOME_FILE" || true)"
if [ ! -f "$HOME_FILE" ]; then check "the list's lines are spelled in the home only" "there is no home"
elif ! grep -q -F 'Kept true by:' "$HOME_FILE"; then check "the list's lines are spelled in the home only" "the home itself never spells them"
elif [ -z "$copies" ]; then check "the list's lines are spelled in the home only" ok
else check "the list's lines are spelled in the home only" "also spelled in: $(printf '%s' "$copies" | tr '\n' ' ')"; fi

section_of(){   # $1 = file  $2 = an exact heading line; prints that section, up to the next heading of its level or above
  awk -v h="$2" '
    BEGIN { n = h; sub(/[^#].*$/, "", n); depth = length(n) }
    $0 == h { f = 1; next }
    f && /^#+ / { m = $0; sub(/[^#].*$/, "", m); if (length(m) <= depth) exit }
    f' "$1"
}
points(){   # $1 = what it holds  $2 = file under skills/ or agents/  $3 = the heading whose section must point home  $4 = words that section must also hold
  local f="$SKILLS/$2" text
  if [ ! -f "$f" ]; then check "$1" "there is no $f"; return; fi
  text="$(section_of "$f" "$3" | tr '\n' ' ' | tr -s ' ')"
  if [ -z "$text" ]; then check "$1" "$2 has no section '$3'"; return; fi
  case "$text" in *"$POINTER"*) ;; *) check "$1" "the section '$3' of $2 does not name $POINTER"; return ;; esac
  case "$text" in *"$4"*) check "$1" ok ;; *) check "$1" "the section '$3' of $2 does not say: $4" ;; esac
}
points "the feature interview ends with the list" feature-discovery/SKILL.md \
  '### Write down what must always be true' 'ask Dan to approve it'
points "plan-lite frames with the list" plan-lite/SKILL.md \
  '### 1. Frame by grilling  (user)' 'End the grilling with the feature'"'"'s `Must always be true` list'
points "plan-council frames with the list" plan-council/SKILL.md \
  '## 1. Frame the problem  (user)' 'put the approved list into the panel'"'"'s `constraints`'
points "a milestone's issues carry the list" milestone/SKILL.md \
  '### 2. Build the plan JSON' 'Each phase'"'"'s `body` carries a `## Must always be true` section'
points "a builder's brief carries the list" orchestrate/SKILL.md \
  '## 3. Briefs' 'When the issue has no such list, say so in the brief'

# The plans show Dan the list, and file it with each phase.
holds(){   # $1 = what it holds  $2 = file under skills/  $3 = heading  $4 = exact words in that section
  local f="$SKILLS/$2" text
  text="$(section_of "$f" "$3" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
  case "$text" in *"$4"*) check "$1" ok ;; *) check "$1" "the section '$3' of $2 does not say: $4" ;; esac
}
holds "plan-lite's draft says which phase builds each holder" plan-lite/SKILL.md '### 2. Draft (grounded)' 'which phase builds what keeps it true'
holds "plan-lite's red team attacks the list" plan-lite/SKILL.md '### 3. Independent red-team + lessons audit (Agent tool)' 'attack the `Must always be true` list too'
holds "plan-lite presents the list" plan-lite/SKILL.md '### 5. Present  (user)' 'Show the `Must always be true` list with its `Not covered` line'
holds "plan-lite files the list with each phase" plan-lite/SKILL.md '### 6. Offer a tracking milestone  (user)' 'the rules that phase must keep true'
holds "plan-council records the list" plan-council/SKILL.md '## 3. Record to GitHub (the audit surface)' 'the `Must always be true` list'
holds "plan-council presents the list" plan-council/SKILL.md '## 4. Present + decide  (user)' 'Show the `Must always be true` list with its `Not covered` line'
holds "plan-council files the list with each phase" plan-council/SKILL.md '## 5. Offer a tracking milestone  (user)' 'the rules that phase must keep true'
redteam="$(tr '\n' ' ' < "$AGENTS/plan-redteam.md" | tr -s ' ')"
case "$redteam" in *'attack the `Must always be true` list too'*) check "the red team role attacks the list" ok ;; *) check "the red team role attacks the list" "plan-redteam.md does not say: attack the \`Must always be true\` list too" ;; esac

# The checks above can fail: a section that mentions the list in loose words points nowhere.
mkdir -p "$TMP/skills/loose"
printf '%s\n' '## 3. Briefs' '' 'A brief may mention what must always be true, and a milestone file, in passing.' > "$TMP/skills/loose/SKILL.md"
SKILLS_REAL="$SKILLS"; SKILLS="$TMP/skills"; before_fail=$fail
points "(control) loose words" loose/SKILL.md '## 3. Briefs' 'say so in the brief' >/dev/null
if [ "$fail" -eq $((before_fail + 1)) ]; then fail=$before_fail; check "the pointer check fails on loose words that point nowhere" ok
else check "the pointer check fails on loose words that point nowhere" "it passed a section that names no home"; fi
SKILLS="$SKILLS_REAL"

echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
