#!/usr/bin/env bash
# Tests for the one rule a count based ratchet applies, in BOTH languages (claude-config#377).
#
# Three guards recorded how many known problems each file still has and each re-implemented the
# same reading, comparing and complaining. Each read as correct on its own, which is the condition
# L370 names: a change to how a ratchet reports lands in one copy and the others go on answering
# the old question with no symptom.
#
# There are two implementations rather than one, because two callers are shell and two are python
# and neither language can call the other's reader without paying a process per run. That is the
# shape L26 is about, and its remedy is what this suite is: ONE committed fixture, read by both,
# compared case by case. Twins tested separately agree on the day they are written and nowhere
# after it.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SH="$DIR/lib/ratchet.sh"
LIB_PY="$DIR/lib/ratchet.py"
CASES="$DIR/lib/ratchet-cases.tsv"
# Exported once, because every python call below imports the twin from it.
export LIBDIR="$DIR/lib"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

for f in "$LIB_SH" "$LIB_PY" "$CASES"; do
  [ -f "$f" ] || { echo "FAIL: no $f"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
done
# shellcheck source=lib/ratchet.sh
. "$LIB_SH" || { echo "FAIL: cannot source $LIB_SH"; exit 1; }

echo "ratchet: both readers agree, case by case, on one committed fixture"

cases=0
while IFS=$'\t' read -r name baseline measured want; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -n "$want" ] || continue
  cases=$((cases + 1))
  b="$(printf '%b' "${baseline//\\n/\\n}")"
  m="$(printf '%b' "${measured//\\n/\\n}")"

  got_sh="$(ratchet_verdict "$b" "$m" | sed -n 's/^VERDICT //p')"
  got_py="$(B="$b" M="$m" python3 -c '
import os, sys
sys.path.insert(0, os.environ["LIBDIR"])
import ratchet
g, s = ratchet.verdict(ratchet.read_baseline(os.environ["B"]), ratchet.read_baseline(os.environ["M"]))
print(ratchet.label(g, s))
' 2>&1)"

  [ "$got_sh" = "$want" ] \
    && check "shell: $name" ok \
    || check "shell: $name" "wanted '$want', got '$got_sh'"
  [ "$got_py" = "$want" ] \
    && check "python: $name" ok \
    || check "python: $name" "wanted '$want', got '$got_py'"
  # The point of the fixture: not that each is right against its own idea, but that the two give
  # the SAME answer to the same question (L26, L58).
  [ "$got_sh" = "$got_py" ] \
    && check "and the two agree: $name" ok \
    || check "and the two agree: $name" "shell said '$got_sh', python said '$got_py'"
done < "$CASES"

# A fixture that yielded nothing passes every assertion above at once and reads exactly like two
# readers that agree on everything (L98).
[ "$cases" -ge 10 ] \
  && check "the fixture holds enough cases to prove anything ($cases)" ok \
  || check "the fixture holds enough cases to prove anything ($cases)" "only $cases"

# And every verdict the rule can give is PRODUCED by the fixture, not merely reachable (L151).
for w in ok grown stale both; do
  if grep -qE "	$w\$" "$CASES"; then check "the fixture produces the '$w' verdict" ok
  else check "the fixture produces the '$w' verdict" "no case asks for it"; fi
done

echo "ratchet: the detail, not only the verdict"

out="$(ratchet_verdict "a.sh: 1
b.sh: 5" "a.sh: 3
b.sh: 2")"
case "$out" in *"GROWN a.sh 1 3"*) check "shell names the path, what was recorded and what is there now" ok ;;
  *) check "shell names the path, what was recorded and what is there now" "said: $out" ;; esac
case "$out" in *"STALE b.sh 5 2"*) check "and the stale one the same way" ok ;;
  *) check "and the stale one the same way" "said: $out" ;; esac
pyout="$(LIBDIR="$DIR/lib" python3 -c '
import os, sys
sys.path.insert(0, os.environ["LIBDIR"])
import ratchet
g, s = ratchet.verdict(ratchet.read_baseline("a.sh: 1\nb.sh: 5"), ratchet.read_baseline("a.sh: 3\nb.sh: 2"))
print(g, s)
')"
case "$pyout" in *"('a.sh', 1, 3)"*) check "python names the same three numbers" ok ;;
  *) check "python names the same three numbers" "said: $pyout" ;; esac
case "$pyout" in *"('b.sh', 5, 2)"*) check "and the same for the stale one" ok ;;
  *) check "and the same for the stale one" "said: $pyout" ;; esac

echo "ratchet: a line it cannot read is skipped, never guessed at"

# A baseline is edited by hand, and a half written line read as a zero would silently forgive every
# finding in that file (L50). Both readers drop it, and both therefore report the file as GROWN
# rather than as recorded at zero, which is the loud direction.
out="$(ratchet_verdict "a.sh: not-a-number" "a.sh: 2" | sed -n 's/^VERDICT //p')"
[ "$out" = "grown" ] && check "shell: a count that is not a number is not a recorded zero" ok \
                     || check "shell: a count that is not a number is not a recorded zero" "got '$out'"
out="$(LIBDIR="$DIR/lib" python3 -c '
import os, sys
sys.path.insert(0, os.environ["LIBDIR"])
import ratchet
g, s = ratchet.verdict(ratchet.read_baseline("a.sh: not-a-number"), ratchet.read_baseline("a.sh: 2"))
print(ratchet.label(g, s))
')"
[ "$out" = "grown" ] && check "python: the same" ok || check "python: the same" "got '$out'"

echo "ratchet: there is no fourth copy"

# Consolidation is the component PLUS the guard, in one change: converting the sites in front of
# you and leaving the next hand rolled copy unreported is how the count got to three (L613).
# WHERE THIS IS RUNNING. Two copies of these hooks exist: the repo's payload/hooks, which sits
# beside a claude-sync and a payload/, and the INSTALLED copy under the config root, which does
# not. `$DIR/../..` is the repo in the first and the HOME DIRECTORY in the second, so a suite that
# assumes the first walks all of $HOME in the second. Measured 2026-09-11: that is what made
# `claude-sync recheck` exceed its 30 minute ceiling and report the whole config unverified.
#
# Said in the one agreed shape the runner reads, so it is reported as NOT RUN rather than as broken
# code, and never as a pass: this suite is about the repo, and the installed copy is not one.
REPO="$(cd "$DIR/../.." && pwd)"
if [ ! -f "$REPO/claude-sync" ] || [ ! -d "$REPO/payload" ]; then
  echo "test-ratchet: $REPO is not a checkout of this repo (no claude-sync and payload/ in it), so there was nothing here to scan." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $REPO is not one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi
for consumer in payload/hooks/test-pipefail-shortcircuit.sh payload/hooks/scan-absence-needles.py payload/hooks/scan-subshell-globals.py; do
  if grep -q 'ratchet' "$REPO/$consumer" 2>/dev/null; then
    check "$consumer reads the shared rule" ok
  else
    check "$consumer reads the shared rule" "it does not mention it"
  fi
done
# And none of them holds a second comparison of its own. The shapes are the ones the three actually
# had: a bash arithmetic test of a measured count against a recorded one, and a python list
# comprehension over `base.get(...)`.
stray="$(grep -nE '\-gt "?\$want|\-lt "?\$want' "$REPO/payload/hooks/test-pipefail-shortcircuit.sh" || true)"
[ -z "$stray" ] && check "the shell consumer holds no second comparison" ok \
                || check "the shell consumer holds no second comparison" "$stray"
stray="$(grep -nE 'c > base\.get|base\[r\] > now\.get' "$REPO/payload/hooks/scan-absence-needles.py" "$REPO/payload/hooks/scan-subshell-globals.py" || true)"
[ -z "$stray" ] && check "neither python consumer holds one either" ok \
                || check "neither python consumer holds one either" "$stray"
# uncovered-hooks.txt is deliberately NOT a consumer: it records a SET of names with no counts, so
# "has this grown" is not the question it asks, and making one reader answer both would be sharing
# a name rather than a rule (L263, L542). Asserted, so the exemption is a decision rather than an
# omission somebody has to rediscover (L129).
if grep -qE '^[^#]*[0-9]' "$REPO/payload/hooks/uncovered-hooks.txt" 2>/dev/null; then
  check "the hook coverage baseline still records names, not counts" "it has gained numbers, so it may now be the same question after all"
else
  check "the hook coverage baseline still records names, not counts" ok
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
