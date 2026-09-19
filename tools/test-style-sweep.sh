#!/usr/bin/env bash
# Tests for style-sweep.sh, which reports the dashes and emoji ALREADY in the payload
# (claude-config#247).
#
# The push gate only ever sees new lines, so settled text is never inspected: the session
# reflection instruction carried 17 em dashes while telling Claude never to use one, and it
# survived untouched inside a hook until moving it made every line new.
#
# What matters about a report like this is that its three quiet answers stay apart: nothing found,
# nothing read, and found but deliberately not counted. The first two look identical from the
# outside unless something makes them differ (L98), and the third has to be SAID or the count reads
# as a payload with no violations in it (L11).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$DIR/style-sweep.sh"

pass=0
fail=0
check() { # check <description> <result>
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.sweep-test.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-style-sweep: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# An em dash written as an escape and assembled here, so this file holds no literal one and the
# push gate has nothing to catch. The gate cannot tell a line that BANS the character from a line
# that uses it, and that is the gate being right.
EM="$(printf '\xe2\x80\x94')"
EMOJI_ROCKET="$(printf '\xf0\x9f\x9a\x80')"

P="$TMPROOT/payload"
mkdir -p "$P/skills/ours" "$P/hooks"

# --- a dash in settled text is reported, and the file and line are named ---
printf 'A sentence %s with a dash in it.\n' "$EM" > "$P/skills/ours/SKILL.md"
out="$(bash "$SWEEP" "$P" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] \
  && check "a dash in the payload exits 1" ok \
  || check "a dash in the payload exits 1" "exit=$rc out=$out"
case "$out" in
  *"skills/ours/SKILL.md"*) check "and the file is named" ok ;;
  *) check "and the file is named" "out=$out" ;;
esac
case "$out" in
  *dash*) check "and the kind of violation is named" ok ;;
  *) check "and the kind of violation is named" "out=$out" ;;
esac

# --- an emoji is reported too, and separately from a dash ---
printf 'A line with a rocket %s in it.\n' "$EMOJI_ROCKET" > "$P/skills/ours/SKILL.md"
out_e="$(bash "$SWEEP" "$P" 2>&1)"; rc_e=$?
[ "$rc_e" -eq 1 ] \
  && check "an emoji in the payload exits 1" ok \
  || check "an emoji in the payload exits 1" "exit=$rc_e out=$out_e"
case "$out_e" in
  *emoji*) check "and it is reported as an emoji, not as a dash" ok ;;
  *) check "and it is reported as an emoji, not as a dash" "out=$out_e" ;;
esac

# An ARROW is not an emoji, and the first version of this sweep said it was: it reported 60
# legitimate "input -> output" lines across the payload, which is a report nobody can act on and the
# fastest way to teach somebody to ignore the whole thing (L36). The definition is copied from the
# gate, so the two cannot drift into disagreeing about what they are for.
printf 'A line with an arrow %s in it.\n' "$(printf '\xe2\x86\x92')" > "$P/skills/ours/SKILL.md"
out_a="$(bash "$SWEEP" "$P" 2>&1)"; rc_a=$?
[ "$rc_a" -eq 0 ] \
  && check "an arrow is not reported, because the push gate does not refuse one" ok \
  || check "an arrow is not reported, because the push gate does not refuse one" "exit=$rc_a out=$out_a"

# --- clean is clean ---
printf 'A sentence with nothing wrong in it.\n' > "$P/skills/ours/SKILL.md"
out_c="$(bash "$SWEEP" "$P" 2>&1)"; rc_c=$?
[ "$rc_c" -eq 0 ] \
  && check "a clean payload exits 0" ok \
  || check "a clean payload exits 0" "exit=$rc_c out=$out_c"

# --- reading NOTHING is its own answer, never a clean one (L98) ---
EMPTY="$TMPROOT/empty-payload"; mkdir -p "$EMPTY"
out_n="$(bash "$SWEEP" "$EMPTY" 2>&1)"; rc_n=$?
[ "$rc_n" -eq 2 ] \
  && check "a payload with no text files in it exits 2, not 0" ok \
  || check "a payload with no text files in it exits 2, not 0" "exit=$rc_n out=$out_n"
case "$out_n" in
  *"Refusing to report a clean sweep of nothing"*)
    check "and it says it read nothing rather than that it found nothing" ok ;;
  *)
    check "and it says it read nothing rather than that it found nothing" "out=$out_n" ;;
esac

# --- what is NOT counted is said, with its reason ---
# A skill carrying a license is somebody else's work, and its violations are real ones this repo
# cannot fix. Dropping them silently would make the count read as a payload with none left in it.
mkdir -p "$P/skills/theirs"
printf 'name: theirs\nlicense: MIT\n' > "$P/skills/theirs/SKILL.md"
printf 'A sentence %s with a dash in it.\n' "$EM" >> "$P/skills/theirs/SKILL.md"
out_l="$(bash "$SWEEP" "$P" 2>&1)"; rc_l=$?
[ "$rc_l" -eq 0 ] \
  && check "a licensed skill's dashes do not fail the sweep" ok \
  || check "a licensed skill's dashes do not fail the sweep" "exit=$rc_l out=$out_l"
case "$out_l" in
  *"carrying its own license"*"theirs"*)
    check "and they are counted and named rather than dropped in silence" ok ;;
  *)
    check "and they are counted and named rather than dropped in silence" "out=$out_l" ;;
esac
case "$out_l" in
  *"1 line(s) in theirs"*)
    check "and the count is the real number, not a mention that some exist" ok ;;
  *)
    check "and the count is the real number, not a mention that some exist" "out=$out_l" ;;
esac

# The gate itself has to NAME the characters it refuses, which is the gate working. Its exemption is
# printed with the reason, so a reader can tell it from an oversight.
printf 'dash_re = re.compile("[%s]")\n' "$EM" > "$P/hooks/check-style-guide.sh"
out_g="$(bash "$SWEEP" "$P" 2>&1)"; rc_g=$?
[ "$rc_g" -eq 0 ] \
  && check "the gate naming the characters it refuses is not a violation" ok \
  || check "the gate naming the characters it refuses is not a violation" "exit=$rc_g out=$out_g"
case "$out_g" in
  *"it is the gate that refuses these characters"*"check-style-guide.sh"*)
    check "and its exemption is printed with the reason for it" ok ;;
  *)
    check "and its exemption is printed with the reason for it" "out=$out_g" ;;
esac

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
