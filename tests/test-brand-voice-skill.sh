#!/usr/bin/env bash
# The dan-wright-brand-voice skill states each email rule once (claude-config#682).
#
# SKILL.md carried a summary of the email rules beside references/email-and-alt-text.md, and the
# summary drifted from the reference's dated rulings: it recommended closing with "Happy to answer
# any questions", which Dan retired on 2026-07-31, and listed four opener shapes when two of them
# were retired the same day. The reference's own example openers also said bare "New York", which
# the same file bans. The dated ruling wins, and SKILL.md now points at the reference rather than
# restating it, so what is held here is that the retired text is gone (L252: a reversed decision
# deletes the text defending it) and that SKILL.md sends email work to the reference.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
SKILLDIR="$DIR/../payload/skills/dan-wright-brand-voice"
SKILL="$SKILLDIR/SKILL.md"
EMAIL="$SKILLDIR/references/email-and-alt-text.md"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
for f in "$SKILL" "$EMAIL"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: $f is missing, so nothing was checked."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done

gone(){   # $1 = what it holds  $2 = a phrase that must appear nowhere in SKILL.md, in any case
  if grep -q -i -F -- "$2" "$SKILL"; then check "$1" "SKILL.md still says: $2"; else check "$1" ok; fi
}
gone "SKILL.md no longer recommends the close Dan retired" "Happy to answer"
gone "SKILL.md no longer offers the retired credential-first opener" "credential-first"
gone "SKILL.md no longer offers the retired observation-first opener" "observation-first"

# SKILL.md must send email work to the reference, inside its Emails section (never anywhere in the
# file, where the Format Guides list alone would answer it, L135).
emails="$(awk '/^### Emails/ { f = 1; next } f && /^#/ { exit } f' "$SKILL")"
case "$emails" in
  *"references/email-and-alt-text.md"*) check "the Emails section points at the email reference" ok ;;
  "") check "the Emails section points at the email reference" "SKILL.md has no '### Emails' section" ;;
  *) check "the Emails section points at the email reference" "the section never names references/email-and-alt-text.md" ;;
esac

# Bare "New York" (not followed by " City") in Dan's own words. The text that DISCUSSES the ban has
# to name it, so those exact phrases are stripped first and anything left is a violation (L361). A
# new mention of the ban that is not listed here fails, which is the safe direction.
bare_new_york(){   # stdin = text; prints each line still holding a bare "New York"
  sed -e 's/never bare "New York"//g' \
      -e 's/"In New York" on its own//g' \
      -e 's/the New York Something//g' \
      -e 's/performing arts organizations in New York"//g' \
    | grep -n -E 'New York($|[^ ]| [^C]| C[^i])'
}
for f in "$SKILL" "$EMAIL"; do
  hits="$(bare_new_york < "$f")"
  if [ -z "$hits" ]; then check "no bare New York in $(basename "$f")" ok
  else check "no bare New York in $(basename "$f")" "$hits"; fi
done

# Control: the bare New York check must fire on the example openers as they used to read.
old='("My name is Dan, I'"'"'m an arts photographer here in New York", "I'"'"'m Dan Wright, a performing arts photographer based in New York")'
if [ -n "$(printf '%s\n' "$old" | bare_new_york)" ]; then check "the bare New York check fires on the old example openers" ok
else check "the bare New York check fires on the old example openers" "it passed them"; fi
# Control: and stay silent on the ban's own wording and on New York City.
okline='### Always "New York City" or "NYC", never bare "New York". "In New York" on its own is wrong, and the New York Something is untouched.'
if [ -z "$(printf '%s\n' "$okline" | bare_new_york)" ]; then check "the bare New York check passes the ban's own wording" ok
else check "the bare New York check passes the ban's own wording" "it flagged it"; fi

echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
