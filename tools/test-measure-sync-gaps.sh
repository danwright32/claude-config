#!/usr/bin/env bash
# Tests for measure-sync-gaps.sh, which re-derives the number behind SYNC_MAC_RETIRE_AFTER
# (claude-config#113).
#
# The point of the script is that the figure justifying a 60 day window stopped being re-derivable:
# it was measured once, written into three files, and left. So the checks below care most about the
# two ways a re-derivation lies. A repo with no sync history must FAIL rather than report a longest
# gap of zero, because zero reads as "this Mac never goes away" which is the most reassuring answer
# it could give (L98). And the window must be anchored to the data rather than to the wall clock, or
# the same fixture measures differently tomorrow (L130).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$DIR/measure-sync-gaps.sh"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-measure-test.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-measure-sync-gaps: refusing to run: throwaway directory came back as '${TMPROOT}'." >&2
    exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

DAY=86400
BASE=1700000000     # a fixed epoch, so the fixture means the same thing on every run

mkrepo(){            # $1 = name, then "offsetDays:host" pairs -> prints the repo path
  local r="$TMPROOT/$1"; shift
  mkdir -p "$r"; git -C "$r" init -q
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  local spec off host ts
  for spec in "$@"; do
    off="${spec%%:*}"; host="${spec#*:}"
    ts=$(( BASE + off * DAY ))
    echo "$spec" > "$r/f"
    GIT_AUTHOR_DATE="@$ts +0000" GIT_COMMITTER_DATE="@$ts +0000" \
      git -C "$r" commit -q --allow-empty -m "sync from $host"
  done
  printf '%s' "$r"
}

# --- the ordinary case: one Mac, a known longest gap of 7 days.
R1="$(mkrepo one 0:macA 1:macA 8:macA 9:macA)"
o1="$(bash "$M" "$R1" 2>&1)"; c1=$?
[ "$c1" -eq 0 ] && check "a repo with sync history measures cleanly" ok \
                || check "a repo with sync history measures cleanly" "exit=$c1 out=$o1"
printf '%s' "$o1" | grep -q 'macA' \
  && check "it names the Mac it measured" ok || check "it names the Mac it measured" "out=$o1"
printf '%s' "$o1" | grep -qE 'longest gap 7\.0+ days' \
  && check "it reports the real longest gap, not the average" ok \
  || check "it reports the real longest gap, not the average" "out=$o1"

# --- the ratio against the configured window is the thing the design record actually claims.
o2="$(SYNC_MAC_RETIRE_AFTER=$((70 * DAY)) bash "$M" "$R1" 2>&1)"
printf '%s' "$o2" | grep -qE '10(\.0)?x' \
  && check "it states the window as a multiple of the longest real gap" ok \
  || check "it states the window as a multiple of the longest real gap" "out=$o2"

# --- two Macs are measured separately, because the window has to cover the worst of them.
R2="$(mkrepo two 0:macA 1:macA 0:macB 20:macB)"
o3="$(bash "$M" "$R2" 2>&1)"
printf '%s' "$o3" | grep -q 'macB' && printf '%s' "$o3" | grep -q 'macA' \
  && check "each Mac is measured on its own" ok || check "each Mac is measured on its own" "out=$o3"
printf '%s' "$o3" | grep -qE 'longest gap 20\.0+ days' \
  && check "and the worst of them is the one the ratio uses" ok \
  || check "and the worst of them is the one the ratio uses" "out=$o3"

# --- no sync history at all. This is the one that matters: reporting a longest gap of zero would
#     read as "no Mac ever goes away", which is the most reassuring answer available (L98).
R3="$(mkrepo none)"
git -C "$R3" commit -q --allow-empty -m "an ordinary commit, not a sync"
o4="$(bash "$M" "$R3" 2>&1)"; c4=$?
[ "$c4" -ne 0 ] && check "a repo with no sync history is refused, not reported as zero" ok \
                || check "a repo with no sync history is refused, not reported as zero" "exit=$c4 out=$o4"
printf '%s' "$o4" | grep -qi 'no sync' \
  && check "and it says what it could not find" ok || check "and it says what it could not find" "out=$o4"

# --- a single sync from a Mac has no GAP to measure, and that is not a gap of zero either.
R4="$(mkrepo single 0:macA)"
o5="$(bash "$M" "$R4" 2>&1)"
printf '%s' "$o5" | grep -qi 'only one' \
  && check "one sync alone is reported as no gap to measure" ok \
  || check "one sync alone is reported as no gap to measure" "out=$o5"

# --- the window is anchored to the newest commit, not to today, or this fixture would measure
#     differently every day it is run (L130).
o6="$(MEASURE_WINDOW_DAYS=5 bash "$M" "$R1" 2>&1)"
printf '%s' "$o6" | grep -qE 'longest gap 1\.0+ days' \
  && check "a narrower window measures only what falls inside it" ok \
  || check "a narrower window measures only what falls inside it" "out=$o6"
printf '%s' "$o6" | grep -q 'anchored' \
  && check "and it says the window is anchored to the newest sync" ok \
  || check "and it says the window is anchored to the newest sync" "out=$o6"

# --- pointed at something that is not a repo.
o7="$(bash "$M" "$TMPROOT/not-a-repo" 2>&1)"; c7=$?
[ "$c7" -ne 0 ] && check "a path that is not a git repo is refused" ok \
                || check "a path that is not a git repo is refused" "exit=$c7 out=$o7"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
