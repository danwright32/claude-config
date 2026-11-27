#!/usr/bin/env bash
# The goal box knows a held steps card by manual steps' own words for it (claude-config#3817).
#
# When the close this session card is due and the steps card is one carried from an earlier
# session that the session has not checked, manual steps answers the goal box's pin with "not
# shown" and one reason, CARRIED_HELD in payload/mods/manual-steps/hooks/register.tsx. The goal box
# reads that reason to know the card is held, and only then asks the session to check its carried
# steps. A mod cannot read another mod's files, so the goal box says the words again
# (CARRIED_HELD in payload/mods/goal-box/hooks/close.ts); this suite is what holds the two
# together. It fails when the two differ, when either can no longer be read as a plain literal, or
# when manual steps no longer gives that constant as the reason on a held card: reworded on one
# side alone, the goal box would stop asking and say nothing, which is the fault #3817 was. Seen to
# fail on fixtures (L1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0
fail=0

# $1 = the goal box's close.ts, $2 = manual steps' register.tsx -> prints "ok" or why not, one line.
judge() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys
close, steps = open(sys.argv[1]).read(), open(sys.argv[2]).read()
literal = r"const CARRIED_HELD = '([^'\\\n]+)'$"
ours = re.findall(r'^export ' + literal, close, re.M)
theirs = re.findall(r'^' + literal, steps, re.M)
if len(ours) != 1:
    print(f"the goal box's CARRIED_HELD is a plain literal {len(ours)} times in close.ts, not once, so it cannot be read"); sys.exit()
if len(theirs) != 1:
    print(f"manual steps' CARRIED_HELD is a plain literal {len(theirs)} times in register.tsx, not once, so it cannot be read"); sys.exit()
if ours[0] != theirs[0]:
    print(f'the goal box reads a held card as "{ours[0]}", and manual steps says "{theirs[0]}"'); sys.exit()
if not re.search(r"isShown: false, reason: CARRIED_HELD\b", steps):
    print('manual steps no longer answers a step added to a held card with CARRIED_HELD as its reason'); sys.exit()
print('ok')
PY
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
REASON='the steps carried from an earlier session are held until Claude checks them again'
ANSWER="  if (how === 'held') return { value: { isShown: false, reason: CARRIED_HELD } }"
fixture() {   # $1 = name, $2 = the goal box's line, $3 = manual steps' lines
  printf '%s\n' "$2" > "$tmp/$1.close.ts"
  printf '%s\n' "$3" > "$tmp/$1.register.tsx"
}
fixture same "export const CARRIED_HELD = '$REASON'" "const CARRIED_HELD = '$REASON'
$ANSWER"
fixture reworded "export const CARRIED_HELD = '$REASON'" "const CARRIED_HELD = 'the carried steps wait for a check'
$ANSWER"
fixture computed "export const CARRIED_HELD = held()" "const CARRIED_HELD = '$REASON'
$ANSWER"
fixture renamed "export const CARRIED_HELD = '$REASON'" "const HELD_FOR_CHECK = '$REASON'
  if (how === 'held') return { value: { isShown: false, reason: HELD_FOR_CHECK } }"
fixture unused "export const CARRIED_HELD = '$REASON'" "const CARRIED_HELD = '$REASON'
  if (how === 'held') return { value: { isShown: false, reason: 'held' } }"
check() {   # $1 = fixture, $2 = expected pattern, $3 = what it shows
  got="$(judge "$tmp/$1.close.ts" "$tmp/$1.register.tsx")"
  if [[ "$got" =~ $2 ]]; then
    pass=$((pass + 1)); echo "PASS: $3"
  else
    fail=$((fail + 1)); echo "FAIL: $3 (got: $got)"
  fi
}
check same '^ok$' 'the same words on both sides pass'
check reworded 'and manual steps says' 'words changed in manual steps alone fail, naming both'
check computed "the goal box's CARRIED_HELD is a plain literal 0 times" 'a goal box reason that is not a plain literal fails as unreadable'
check renamed "manual steps' CARRIED_HELD is a plain literal 0 times" 'a manual steps constant under another name fails as unreadable'
check unused 'no longer answers a step added to a held card' 'a held card answered with other words fails'

got="$(judge "$ROOT/payload/mods/goal-box/hooks/close.ts" "$ROOT/payload/mods/manual-steps/hooks/register.tsx")"
if [ "$got" = ok ]; then
  pass=$((pass + 1)); echo "PASS: the goal box reads a held steps card by the words manual steps answers with"
else
  fail=$((fail + 1)); echo "FAIL: $got"
fi

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
