#!/usr/bin/env bash
# The goal box and manual steps agree on a held steps card in three places (claude-config#3817).
#
# 1. Why the card is held, as a value. When the close this session card is due and the steps card
#    is held, manual steps answers the goal box's pin with "not shown", a value (`held`) and a
#    reason. The value is HELD_UNCHECKED for steps carried from an earlier session that nobody has
#    checked, and HELD_AWAY for a card this session pinned while Dan was away
#    (payload/mods/manual-steps/hooks/register.tsx). The goal box asks the session to check its
#    carried steps only for the first, and decides by the value alone, never by the reason's words
#    (heldKind in payload/mods/goal-box/hooks/close.ts). A mod cannot read another mod's files, so
#    the goal box says the two values again. Were one side's value to change alone, the goal box
#    would read the answer as neither and ask nothing, which is the fault #3817 was. Were the two
#    values to become one, a session that had already checked would be asked at every request.
# 2. The reasons' words. The goal box writes manual steps' reason into its reasons file from its
#    own copy (CARRIED_HELD and AWAY_HELD in close.ts), so each copy must be manual steps' sentence.
# 3. What the session is told to keep. The close card can follow only when the steps the session
#    pins stay the earlier session's, and manual steps knows a pinned step as the kept one by its
#    title and its link or location (keyOf in pinnedBy, payload/mods/manual-steps/hooks/card.ts). A
#    step it does not know becomes this session's own and holds the close card until Dan has done
#    it. So the goal box's message (CHECK_CARRIED) tells the session to keep each title and link or
#    place. Were manual steps to match by anything else, or the message to drop the instruction, the
#    session would do as told and the card would stay back with nothing said.
#
# This suite holds all three together. It fails when a value or a reason differs between the two
# mods, when one can no longer be read as a plain literal, when the two values or the two reasons
# are the same, when manual steps no longer gives each value with its own reason on a held card,
# when the goal box compares a reason's words or no longer reads the value through heldKind, when
# manual steps no longer matches a pinned step by its title and its link or location, or when the
# message no longer tells the session to keep them. Seen to fail on fixtures (L1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0
fail=0

# $1 = the goal box's close.ts, $2 = manual steps' register.tsx, $3 = manual steps' card.ts,
# $4 = the goal box's register.ts -> prints "ok" or why not, one line.
judge() {
  python3 -I - "$1" "$2" "$3" "$4" <<'PY'
import re, sys
close, steps, card, reads = (open(p).read() for p in sys.argv[1:5])
said = {}
for name in ('HELD_UNCHECKED', 'HELD_AWAY', 'CARRIED_HELD', 'AWAY_HELD'):
    literal = r"const " + name + r" = '([^'\\\n]+)'$"
    ours = re.findall(r'^export ' + literal, close, re.M)
    theirs = re.findall(r'^' + literal, steps, re.M)
    if len(ours) != 1:
        print(f"the goal box's {name} is a plain literal {len(ours)} times in close.ts, not once, so it cannot be read"); sys.exit()
    if len(theirs) != 1:
        print(f"manual steps' {name} is a plain literal {len(theirs)} times in register.tsx, not once, so it cannot be read"); sys.exit()
    if ours[0] != theirs[0]:
        print(f'the goal box has {name} as "{ours[0]}", and manual steps says "{theirs[0]}"'); sys.exit()
    said[name] = theirs[0]
if said['HELD_UNCHECKED'] == said['HELD_AWAY']:
    print(f'the two answers for a held card carry the same value, "{said["HELD_AWAY"]}", so a card held because Dan is away cannot be told from carried steps nobody has checked'); sys.exit()
if said['CARRIED_HELD'] == said['AWAY_HELD']:
    print('the two answers for a held card say the same words, so the reasons file would give one reason for both'); sys.exit()
if not re.search(r"isShown: false, held: HELD_UNCHECKED, reason: CARRIED_HELD\b", steps):
    print('manual steps no longer answers a step added to carried steps nobody has checked with HELD_UNCHECKED and CARRIED_HELD'); sys.exit()
if not re.search(r"isShown: false, held: HELD_AWAY, reason: AWAY_HELD\b", steps):
    print('manual steps no longer answers a step added to a card held while Dan is away with HELD_AWAY and AWAY_HELD'); sys.exit()
words = r"(?:CARRIED_HELD|AWAY_HELD)\b"
by_words = r"[!=]==?\s*" + words + r"|\b(?:CARRIED_HELD|AWAY_HELD)\s*[!=]==?|\b(?:includes|startsWith|endsWith|indexOf|match|test)\(\s*" + words
if re.search(by_words, close) or re.search(by_words, reads):
    print("the goal box compares a held card's reason by its words, where only the value may decide"); sys.exit()
if not re.search(r"\bheldKind\(", reads):
    print("the goal box's register.ts no longer reads why the steps card is held through heldKind"); sys.exit()
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
AWAY_REASON='the steps this session pinned while Dan was away are held until they are pinned again once he is home'
ANSWER="  if (how === HELD_UNCHECKED) return { value: { isShown: false, held: HELD_UNCHECKED, reason: CARRIED_HELD } }"
AWAY_ANSWER="  if (how === HELD_AWAY) return { value: { isShown: false, held: HELD_AWAY, reason: AWAY_HELD } }"
TOLD="export const CHECK_CARRIED =
  'CARRIED STEPS. Check each, then pin them again. Keep each title and link or place as it is, or the close card stays back.'"
READS='    held = heldKind(r)'
# Single quoted: the backtick, the dollar signs and the backslash are the line's own characters.
BY_BOTH='  const keyOf = (s: StepsStep) => `${s.title}\n${s.url ?? s.location}`'
OPENS='export const pinnedBy = (card: StepsCard, prior: StepsCard | null | undefined, session: string | undefined): StepsCard => {'
KEYOF="$OPENS
$BY_BOTH"
# The goal box's close.ts. $1 to $4 = its lines for CARRIED_HELD, AWAY_HELD, HELD_UNCHECKED and
# HELD_AWAY, $5 = the message's lines; an empty one is the line both mods agree on.
goal() {
  printf '%s\n' "${1:-export const CARRIED_HELD = '$REASON'}" "${2:-export const AWAY_HELD = '$AWAY_REASON'}" "${3:-export const HELD_UNCHECKED = 'unchecked'}" "${4:-export const HELD_AWAY = 'away'}" "${5:-$TOLD}"
}
# Manual steps' register.tsx. $1 to $4 = the same four lines, $5 and $6 = its answer for carried
# steps nobody has checked and for a card held while Dan is away.
steps() {
  printf '%s\n' "${1:-const CARRIED_HELD = '$REASON'}" "${2:-const AWAY_HELD = '$AWAY_REASON'}" "${3:-const HELD_UNCHECKED = 'unchecked'}" "${4:-const HELD_AWAY = 'away'}" "${5:-$ANSWER}" "${6:-$AWAY_ANSWER}"
}
fixture() {   # $1 = name, $2 = the goal box's close.ts, $3 = manual steps' register.tsx, $4 = manual steps' card.ts, $5 = the goal box's register.ts
  printf '%s\n' "$2" > "$tmp/$1.close.ts"
  printf '%s\n' "$3" > "$tmp/$1.register.tsx"
  printf '%s\n' "$4" > "$tmp/$1.card.ts"
  printf '%s\n' "${5:-$READS}" > "$tmp/$1.reads.ts"
}
fixture same "$(goal)" "$(steps)" "$KEYOF"
fixture reworded "$(goal)" "$(steps "const CARRIED_HELD = 'the carried steps wait for a check'")" "$KEYOF"
fixture awayreworded "$(goal)" "$(steps '' "const AWAY_HELD = 'the card waits for Dan'")" "$KEYOF"
fixture computed "$(goal 'export const CARRIED_HELD = held()')" "$(steps)" "$KEYOF"
fixture renamed "$(goal)" "$(steps "const HELD_FOR_CHECK = '$REASON'" '' '' '' "  if (how === HELD_UNCHECKED) return { value: { isShown: false, held: HELD_UNCHECKED, reason: HELD_FOR_CHECK } }")" "$KEYOF"
fixture unused "$(goal)" "$(steps '' '' '' '' "  if (how === HELD_UNCHECKED) return { value: { isShown: false, held: HELD_UNCHECKED, reason: 'held' } }")" "$KEYOF"
# The away case answered as the unchecked one is: one answer for both.
fixture awayunanswered "$(goal)" "$(steps '' '' '' '' '' "  if (how === HELD_AWAY) return { value: { isShown: false, held: HELD_UNCHECKED, reason: CARRIED_HELD } }")" "$KEYOF"
fixture samevalue "$(goal '' '' '' "export const HELD_AWAY = 'unchecked'")" "$(steps '' '' '' "const HELD_AWAY = 'unchecked'")" "$KEYOF"
fixture samewords "$(goal '' "export const AWAY_HELD = '$REASON'")" "$(steps '' "const AWAY_HELD = '$REASON'")" "$KEYOF"
fixture valuediffers "$(goal '' '' '' "export const HELD_AWAY = 'gone'")" "$(steps)" "$KEYOF"
fixture valuecomputed "$(goal '' '' 'export const HELD_UNCHECKED = kind()')" "$(steps)" "$KEYOF"
fixture bywords "$(goal)" "$(steps)" "$KEYOF" "$READS
    isHeld = r?.isShown === false && r.reason === CARRIED_HELD"
fixture unread "$(goal)" "$(steps)" "$KEYOF" "    held = r?.held"
fixture rekeyed "$(goal)" "$(steps)" "$OPENS
  const keyOf = (s: StepsStep) => s.title"
# The same key built in another function, as card.ts has it for a finished step, with pinnedBy's
# own key changed: the other one must not answer for it.
fixture elsewhere "$(goal)" "$(steps)" "export const keepFinished = (card: StepsCard, prior: StepsCard | null | undefined): StepsCard => {
$BY_BOTH
$OPENS
  const keyOf = (s: StepsStep) => s.title"
fixture untold "$(goal '' '' '' '' "export const CHECK_CARRIED =
  'CARRIED STEPS. Check each, then pin them again.'")" "$(steps)" "$KEYOF"
fixture built "$(goal '' '' '' '' 'export const CHECK_CARRIED = told()')" "$(steps)" "$KEYOF"
check() {   # $1 = fixture, $2 = expected pattern, $3 = what it shows
  got="$(judge "$tmp/$1.close.ts" "$tmp/$1.register.tsx" "$tmp/$1.card.ts" "$tmp/$1.reads.ts")"
  if [[ "$got" =~ $2 ]]; then
    pass=$((pass + 1)); echo "PASS: $3"
  else
    fail=$((fail + 1)); echo "FAIL: $3 (got: $got)"
  fi
}
check same '^ok$' 'the same values and words on both sides, read by the value, and a message that says what manual steps matches by, pass'
check reworded 'the goal box has CARRIED_HELD as .*, and manual steps says' 'words changed in manual steps alone fail, naming both'
check awayreworded 'the goal box has AWAY_HELD as .*, and manual steps says' 'the away words changed in manual steps alone fail, naming both'
check computed "the goal box's CARRIED_HELD is a plain literal 0 times" 'a goal box reason that is not a plain literal fails as unreadable'
check renamed "manual steps' CARRIED_HELD is a plain literal 0 times" 'a manual steps constant under another name fails as unreadable'
check unused 'no longer answers a step added to carried steps nobody has checked' 'unchecked carried steps answered with other words fail'
check awayunanswered 'no longer answers a step added to a card held while Dan is away' 'a card held while Dan is away answered as unchecked carried steps fails'
check samevalue 'carry the same value' 'one value for both held answers fails, though both mods agree on it'
check samewords 'say the same words' 'one sentence for both held answers fails, though both mods agree on it'
check valuediffers 'the goal box has HELD_AWAY as "gone", and manual steps says "away"' 'a value changed in the goal box alone fails, naming both'
check valuecomputed "the goal box's HELD_UNCHECKED is a plain literal 0 times" 'a goal box value that is not a plain literal fails as unreadable'
check bywords "compares a held card's reason by its words" 'a goal box that decides by the words of the reason fails'
check unread 'no longer reads why the steps card is held through heldKind' 'a goal box that reads the value some other way fails'
check rekeyed 'no longer knows a pinned step as the kept one by its title and its link or location' 'manual steps matching a pinned step by its title alone fails'
check elsewhere 'no longer knows a pinned step as the kept one by its title and its link or location' 'the same key in another function does not answer for the one that decides whose step it is'
check untold 'no longer tells the session to keep each title and link or place' 'a message that does not say to keep the titles and links fails'
check built "the goal box's CHECK_CARRIED is a plain literal 0 times" 'a message that is not a plain literal fails as unreadable'

got="$(judge "$ROOT/payload/mods/goal-box/hooks/close.ts" "$ROOT/payload/mods/manual-steps/hooks/register.tsx" "$ROOT/payload/mods/manual-steps/hooks/card.ts" "$ROOT/payload/mods/goal-box/hooks/register.ts")"
if [ "$got" = ok ]; then
  pass=$((pass + 1)); echo "PASS: the goal box reads why a steps card is held by the value manual steps answers with, writes manual steps' own words for each, and tells the session to keep what manual steps matches a pinned step by"
else
  fail=$((fail + 1)); echo "FAIL: $got"
fi

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
