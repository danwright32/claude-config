#!/usr/bin/env bash
# The goal box and manual steps agree on a held steps card in two places (claude-config#3817).
#
# 1. The words for a held card. When the close this session card is due and the steps card is one
#    carried from an earlier session that the session has not checked, manual steps answers the goal
#    box's pin with "not shown" and one reason, CARRIED_HELD in
#    payload/mods/manual-steps/hooks/register.tsx. The goal box reads that reason to know the card is
#    held, and only then asks the session to check its carried steps. A mod cannot read another
#    mod's files, so the goal box says the words again (CARRIED_HELD in
#    payload/mods/goal-box/hooks/close.ts). Reworded on one side alone, the goal box would stop
#    asking and say nothing, which is the fault #3817 was.
# 2. What the session is told to keep. The close card can follow only when the steps the session
#    pins stay the earlier session's, and manual steps knows a pinned step as the kept one by its
#    title and its link or location (keyOf in pinnedBy, payload/mods/manual-steps/hooks/card.ts). A
#    step it does not know becomes this session's own and holds the close card until Dan has done
#    it. So the goal box's message (CHECK_CARRIED) tells the session to keep each title and link or
#    place. Were manual steps to match by anything else, or the message to drop the instruction, the
#    session would do as told and the card would stay back with nothing said (review of pull
#    request 3870).
#
# This suite holds both together. It fails when the two reasons differ, when either can no longer
# be read as a plain literal, when manual steps no longer gives that constant as the reason on a
# held card, when manual steps no longer matches a pinned step by its title and its link or
# location, or when the message no longer tells the session to keep them. Seen to fail on fixtures
# (L1).
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

# $1 = the goal box's close.ts, $2 = manual steps' register.tsx, $3 = manual steps' card.ts
# -> prints "ok" or why not, one line.
judge() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import re, sys
close, steps, card = (open(p).read() for p in sys.argv[1:4])
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
told = re.findall(r"^export const CHECK_CARRIED =\n  '([^'\\\n]+)'$", close, re.M)
if len(told) != 1:
    print(f"the goal box's CHECK_CARRIED is a plain literal {len(told)} times in close.ts, not once, so it cannot be read"); sys.exit()
# The line that opens pinnedBy and the key on the line after it: another function in that file
# builds the same key for another purpose, and must not answer for this one.
if not re.search(r"^export const pinnedBy = [^\n]*\{\n  const keyOf = \(s: StepsStep\) => `\$\{s\.title\}\\n\$\{s\.url \?\? s\.location\}`$", card, re.M):
    print('manual steps no longer knows a pinned step as the kept one by its title and its link or location, which is what the goal box tells the session to keep'); sys.exit()
if 'Keep each title and link or place as it is' not in told[0]:
    print("the goal box's message no longer tells the session to keep each title and link or place, which is how manual steps knows a pinned step as the kept one"); sys.exit()
print('ok')
PY
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
REASON='the steps carried from an earlier session are held until Claude checks them again'
ANSWER="  if (how === 'held') return { value: { isShown: false, reason: CARRIED_HELD } }"
TOLD="export const CHECK_CARRIED =
  'CARRIED STEPS. Check each, then pin them again. Keep each title and link or place as it is, or the close card stays back.'"
# Single quoted: the backtick, the dollar signs and the backslash are the line's own characters.
BY_BOTH='  const keyOf = (s: StepsStep) => `${s.title}\n${s.url ?? s.location}`'
OPENS='export const pinnedBy = (card: StepsCard, prior: StepsCard | null | undefined, session: string | undefined): StepsCard => {'
KEYOF="$OPENS
$BY_BOTH"
fixture() {   # $1 = name, $2 = the goal box's lines, $3 = manual steps' register lines, $4 = manual steps' card line
  printf '%s\n' "$2" > "$tmp/$1.close.ts"
  printf '%s\n' "$3" > "$tmp/$1.register.tsx"
  printf '%s\n' "$4" > "$tmp/$1.card.ts"
}
fixture same "export const CARRIED_HELD = '$REASON'
$TOLD" "const CARRIED_HELD = '$REASON'
$ANSWER" "$KEYOF"
fixture reworded "export const CARRIED_HELD = '$REASON'
$TOLD" "const CARRIED_HELD = 'the carried steps wait for a check'
$ANSWER" "$KEYOF"
fixture computed "export const CARRIED_HELD = held()
$TOLD" "const CARRIED_HELD = '$REASON'
$ANSWER" "$KEYOF"
fixture renamed "export const CARRIED_HELD = '$REASON'
$TOLD" "const HELD_FOR_CHECK = '$REASON'
  if (how === 'held') return { value: { isShown: false, reason: HELD_FOR_CHECK } }" "$KEYOF"
fixture unused "export const CARRIED_HELD = '$REASON'
$TOLD" "const CARRIED_HELD = '$REASON'
  if (how === 'held') return { value: { isShown: false, reason: 'held' } }" "$KEYOF"
fixture rekeyed "export const CARRIED_HELD = '$REASON'
$TOLD" "const CARRIED_HELD = '$REASON'
$ANSWER" "$OPENS
  const keyOf = (s: StepsStep) => s.title"
# The same key built in another function, as card.ts has it for a finished step, with pinnedBy's
# own key changed: the other one must not answer for it.
fixture elsewhere "export const CARRIED_HELD = '$REASON'
$TOLD" "const CARRIED_HELD = '$REASON'
$ANSWER" "export const keepFinished = (card: StepsCard, prior: StepsCard | null | undefined): StepsCard => {
$BY_BOTH
$OPENS
  const keyOf = (s: StepsStep) => s.title"
fixture untold "export const CARRIED_HELD = '$REASON'
export const CHECK_CARRIED =
  'CARRIED STEPS. Check each, then pin them again.'" "const CARRIED_HELD = '$REASON'
$ANSWER" "$KEYOF"
fixture built "export const CARRIED_HELD = '$REASON'
export const CHECK_CARRIED = told()" "const CARRIED_HELD = '$REASON'
$ANSWER" "$KEYOF"
check() {   # $1 = fixture, $2 = expected pattern, $3 = what it shows
  got="$(judge "$tmp/$1.close.ts" "$tmp/$1.register.tsx" "$tmp/$1.card.ts")"
  if [[ "$got" =~ $2 ]]; then
    pass=$((pass + 1)); echo "PASS: $3"
  else
    fail=$((fail + 1)); echo "FAIL: $3 (got: $got)"
  fi
}
check same '^ok$' 'the same words on both sides, and a message that says what manual steps matches by, pass'
check reworded 'and manual steps says' 'words changed in manual steps alone fail, naming both'
check computed "the goal box's CARRIED_HELD is a plain literal 0 times" 'a goal box reason that is not a plain literal fails as unreadable'
check renamed "manual steps' CARRIED_HELD is a plain literal 0 times" 'a manual steps constant under another name fails as unreadable'
check unused 'no longer answers a step added to a held card' 'a held card answered with other words fails'
check rekeyed 'no longer knows a pinned step as the kept one by its title and its link or location' 'manual steps matching a pinned step by its title alone fails'
check elsewhere 'no longer knows a pinned step as the kept one by its title and its link or location' 'the same key in another function does not answer for the one that decides whose step it is'
check untold 'no longer tells the session to keep each title and link or place' 'a message that does not say to keep the titles and links fails'
check built "the goal box's CHECK_CARRIED is a plain literal 0 times" 'a message that is not a plain literal fails as unreadable'

got="$(judge "$ROOT/payload/mods/goal-box/hooks/close.ts" "$ROOT/payload/mods/manual-steps/hooks/register.tsx" "$ROOT/payload/mods/manual-steps/hooks/card.ts")"
if [ "$got" = ok ]; then
  pass=$((pass + 1)); echo "PASS: the goal box reads a held steps card by the words manual steps answers with, and tells the session to keep what manual steps matches a pinned step by"
else
  fail=$((fail + 1)); echo "FAIL: $got"
fi

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
