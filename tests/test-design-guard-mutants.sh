#!/bin/bash
# The design round guard's settled page hold tests, each seen failing against a broken COPY of the
# guard (#1588, L1).
#
# PR #1584 (#1524) let a settled design page under docs/design through unasked while it is exactly as
# make-settled.py sealed it, and tested that an edited page is held and that a sealed page outside
# docs/design is held. Neither was seen failing: the second passed before the code existed, since
# nothing passed then, and the safety classifier refused, correctly, a mutation run against the real
# guard file. So each is run here against a copy of the repository that tools/prove-it-fails.sh makes
# and breaks, never the tree being worked in:
#   - a guard whose rules.ts isDesignRecord takes every path for docs/design, so a sealed page passes
#     anywhere: the outside docs/design test must fail;
#   - a guard whose register.ts settledRecord passes without asking the seal check: the edited page
#     test must fail;
#   - and, as the control that proves the harness can say NOT PROVED, a copy whose only change is the
#     words of a comment: neither test may fail.
# Each named test is first seen passing on the tree as it is, so a test renamed or no longer run
# reads as a failure here rather than as nothing to prove.
#
# Needs Claude Code's `claude plugin test`; without a claude command (CI's Linux runner) the suite
# says UNMEASURED and why (L411).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}

MOD=payload/mods/design-round-guard
EDITED='#1524: the same path with an edited frame is held, by any tool, and the refusal says why'
OUTSIDE='#1524: a file carrying the blocks and the seal but not under docs/design is held, the check never asked'

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
if [ -z "$CLAUDE_BIN" ]; then
  echo "SUITE-PART-UNMEASURED the design round guard's settled page hold tests against broken copies: there is no claude command on PATH to run claude plugin test with"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 0
fi
export CLAUDE_BIN

# Both tests run and pass on the tree as it is.
real="$("$CLAUDE_BIN" plugin test "$ROOT/$MOD" 2>&1)"
for name in "$EDITED" "$OUTSIDE"; do
  if printf '%s\n' "$real" | grep -qF "(pass) $name"; then check "the guard's suite runs and passes: $name" ok
  else check "the guard's suite runs and passes: $name" "no (pass) line for it; the suite said: $(printf '%s\n' "$real" | tail -3 | tr '\n' ' ')"; fi
done

# Runs the guard's suite in the broken copy and fails only where the named test FAILED, so a suite
# that did not run the test at all reads as NOT PROVED, never as proof. The output is held whole
# before it is read: prove-it-fails runs with pipefail, under which the suite's own failing exit
# would decide a pipe into grep.
fails_on(){ # <test name> -> the --run command for prove-it-fails
  printf 'out="$("$CLAUDE_BIN" plugin test %s 2>&1)"; ! grep -qF %q <<<"$out"' "$MOD" "(fail) $1"
}

# mutant <label> <test name> <expected PROVED or NOT PROVED> <file> <sed expression>
mutant(){
  local label="$1" name="$2" want="$3" file="$4" expr="$5" out rc
  out="$(bash "$ROOT/tools/prove-it-fails.sh" --repo "$ROOT" --no-baseline --run "$(fails_on "$name")" --sed "$file" "$expr" 2>&1)"; rc=$?
  case "$want" in
    PROVED) [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^PROVED' && { check "$label" ok; return; } ;;
    'NOT PROVED') [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^NOT PROVED' && { check "$label" ok; return; } ;;
  esac
  check "$label" "wanted $want, prove-it-fails exited $rc: $(printf '%s\n' "$out" | tail -4 | tr '\n' ' ')"
}

mutant "a sealed page outside docs/design is held: fails against a guard passing a sealed page anywhere" "$OUTSIDE" PROVED \
  "$MOD/hooks/rules.ts" 's#^export const isDesignRecord = (rel: string): boolean => .*$#export const isDesignRecord = (rel: string): boolean => rel.length > 0#'
mutant "an edited settled page is held: fails against a guard skipping the seal check" "$EDITED" PROVED \
  "$MOD/hooks/register.ts" 's#^  const file = relTo(t.path, tree)$#  return true#'
mutant "the control: a comment's words changed, the outside docs/design test still passes" "$OUTSIDE" 'NOT PROVED' \
  "$MOD/hooks/rules.ts" "s#check of a settled design's seal (\#1524)#check of the seal a settled design carries (\#1524)#"
mutant "the control: a comment's words changed, the edited page test still passes" "$EDITED" 'NOT PROVED' \
  "$MOD/hooks/rules.ts" "s#check of a settled design's seal (\#1524)#check of the seal a settled design carries (\#1524)#"

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
