#!/usr/bin/env bash
# Tests for lib/home-token.sh, the one statement of the home placeholder and its substitution, read
# by claude-sync (installing and sending) and by payload-write-gate.sh (asking whether a checkout's
# file already matches what is installed), so the two cannot drift apart (claude-config#1211, L370).
# The substitution is literal on both sides: a home path is data, never a pattern.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
if ! . "$DIR/lib/home-token.sh"; then
  echo "FAIL: lib/home-token.sh could not be loaded"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
FIX="$(mktemp -d "${TMPDIR:-/tmp}/home-token.XXXXXXXX")"
trap 'rm -rf "$FIX"' EXIT

# Built from pieces here too, or installing this suite would rewrite it into this Mac's home path.
T="__CLAUDE""_HOME__"
[ "$HOME_TOKEN" = "$T" ] && check "the placeholder is the one the payload has always carried" ok || check "the placeholder is the one the payload has always carried" "it is '$HOME_TOKEN'"

eq(){ # eq <description> <expected> <actual file>
  if printf '%s' "$2" | cmp -s - "$3"; then check "$1" ok; else check "$1" "got: $(od -c "$3" | tr '\n' ' ')"; fi
}
printf 'run %s/a.sh and %s/b.sh\n' "$T" "$T" | home_detok "/h/x/.cfg" > "$FIX/o"
eq "expansion replaces every placeholder with the home given" $'run /h/x/.cfg/a.sh and /h/x/.cfg/b.sh\n' "$FIX/o"
# The characters sed reads as its delimiter, its whole match and its escape, in the home path.
odd='/h/a|b&c\d/.cfg'
printf 'run %s/a.sh\n' "$T" | home_detok "$odd" > "$FIX/o"
eq "a home path holding | & and \\ is put in literally" "run $odd/a.sh"$'\n' "$FIX/o"
printf 'run %s/a.sh\n' "$odd" | home_tok "$odd" > "$FIX/o"
eq "and taken back out literally" "run $T/a.sh"$'\n' "$FIX/o"
# A home path is not a pattern: its dot must not match any character.
printf 'see /h/xacfg/q\n' | home_tok "/h/x.cfg" > "$FIX/o"
eq "a path that only matches the home as a pattern is left alone" $'see /h/xacfg/q\n' "$FIX/o"
printf 'no final newline %s' "$T" | home_detok "/h" > "$FIX/o"
eq "a file with no final newline keeps none" 'no final newline /h' "$FIX/o"
printf 'nothing to change\n' | home_detok "/h" > "$FIX/o"
eq "text without the placeholder passes through unchanged" $'nothing to change\n' "$FIX/o"
printf '\377\376 %s \200\n' "$T" | home_detok "/h" > "$FIX/o"
eq "bytes that are not valid text pass through" $'\377\376 /h \200\n' "$FIX/o"
# claude-sync carries its own copy, being one whole script: it must be this one, byte for byte.
# Only a checkout has claude-sync above its hooks; the installed copy under the config root does not,
# so there the comparison is said to be not made, never counted as a pass (L411).
REPO="$(cd "$DIR/../.." && pwd)"
SYNC="$REPO/claude-sync"
if [ ! -f "$SYNC" ] || [ ! -d "$REPO/payload" ]; then
  echo "test-home-token: $REPO is not a checkout of this repo, so claude-sync's copy of the swap was NOT compared here; a checkout's run compares it."
else
  mine="$(grep -F 'perl -pe' "$DIR/lib/home-token.sh")"
  theirs="$(grep -F 'perl -pe' "$SYNC")"
  [ -n "$mine" ] && [ "$mine" = "$theirs" ] && check "claude-sync's copy of the swap is this library's, byte for byte" ok || check "claude-sync's copy of the swap is this library's, byte for byte" "library: '$mine' claude-sync: '$theirs'"
  grep -qx "TOKEN=\"$T\"" "$SYNC" && check "and its placeholder is the same" ok || check "and its placeholder is the same" "claude-sync has no line TOKEN=\"$T\""
fi
# A failure to run must not read as an empty, matching result.
if ( PATH=/nonexistent; home_detok "/h" < /dev/null ) 2>/dev/null; then check "a substitution that could not run fails rather than printing nothing" "it succeeded"; else check "a substitution that could not run fails rather than printing nothing" ok; fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
