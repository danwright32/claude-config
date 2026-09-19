#!/usr/bin/env bash
# Tests for check-root-guard.sh, which refuses a suite that derives the repository root by counting
# directories upwards without confirming what it landed on (claude-config#503).
#
# `"$DIR/../.."` is the repository root when a file runs from payload/hooks and the HOME DIRECTORY
# when the same file runs from the installed copy in ~/.claude/hooks. Nine files here derive a root
# that way and every one of them checks the result before using it, so the convention is right and
# was enforced by nothing.
#
# It has now cost the same thing twice. On 2026-09-11 an unguarded one made `claude-sync recheck`
# exceed its thirty minute ceiling and report the whole config unverified; the guard was added to
# those suites and written up in their comments. On 2026-09-19 test-shell-syntax.sh shipped without
# it and the first pull that installed it spent twenty two minutes walking every file under ~. A
# convention followed by habit and enforced by nothing is the shape this repo keeps paying for
# (L30 fix the class, L96 a hand written registry exempts whatever is missing from it, L668).
#
# WHAT IT MATCHES, and why it is narrow. Measured over this tree on 2026-09-19: eighteen lines hold
# `../..`, and only nine of them are root derivations. Five are prose comments (two of them in the
# files this issue is about, describing the very trap), and two are `../../..` used as a PATH
# TRAVERSAL ATTACK STRING in a fixture that proves a hook cannot be steered by one. A rule matching
# `../..` anywhere would refuse seven correct things, which is the over match that reads exactly
# like the guard working (L104). So it matches the derivation SHAPE: an assignment whose value
# comes from a `cd <something>/../.. && pwd` substitution, outside a comment.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-root-guard.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.rootguard.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-check-root-guard: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

mk() { mkdir -p "$TMPROOT/tree"; printf '%s\n' "$2" > "$TMPROOT/tree/$1"; }
clear_tree() { rm -rf "$TMPROOT/tree"; mkdir -p "$TMPROOT/tree"; }

# ---------------------------------------------------------------------------
# THE FAULT, watched failing first (L1). This is the exact line that shipped in #500.
# ---------------------------------------------------------------------------
clear_tree
mk test-careless.sh '#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
find "$ROOT" -type f -print'
out_bad="$(bash "$CHECK" "$TMPROOT/tree" 2>&1)"; code_bad=$?
[ "$code_bad" -ne 0 ] \
  && check "a root derived upwards with no guard is refused" ok \
  || check "a root derived upwards with no guard is refused" "exit=$code_bad out=$out_bad"
grep -q 'test-careless.sh' <<< "$out_bad" \
  && check "and the file is named" ok \
  || check "and the file is named" "out=$out_bad"
grep -qE 'test-careless\.sh:3' <<< "$out_bad" \
  && check "and the line it is on" ok \
  || check "and the line it is on" "out=$out_bad"
grep -qi 'home directory' <<< "$out_bad" \
  && check "and it says what the wrong answer actually is" ok \
  || check "and it says what the wrong answer actually is" "out=$out_bad"

# ---------------------------------------------------------------------------
# THE TWO GUARD SHAPES THIS REPO ACTUALLY USES, both of which must pass. They are read out of the
# real files rather than invented here, because a fixture shaped to satisfy the rule proves only
# that the rule agrees with itself (L48, L52).
# ---------------------------------------------------------------------------
clear_tree
mk test-guarded-notrun.sh '#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
if [ ! -f "$REPO/claude-sync" ] || [ ! -d "$REPO/payload" ]; then
  printf "SUITE-NOT-RUN %s\n" "needs the repository above it"
  exit 2
fi
find "$REPO" -type f -print'
out_g1="$(bash "$CHECK" "$TMPROOT/tree" 2>&1)"; code_g1=$?
[ "$code_g1" -eq 0 ] \
  && check "the SUITE-NOT-RUN guard shape passes" ok \
  || check "the SUITE-NOT-RUN guard shape passes" "exit=$code_g1 out=$out_g1"

clear_tree
mk test-guarded-inline.sh '#!/usr/bin/env bash
HOOK="$0"
REPO_ROOT="$(cd "$(dirname "$HOOK")/../.." && pwd)"
SYNC_TOOL="$REPO_ROOT/claude-sync"
if [ ! -f "$SYNC_TOOL" ] || [ ! -d "$REPO_ROOT/payload" ]; then
  echo "NOTE: not a checkout of this repo"
else
  find "$REPO_ROOT" -type f -print
fi'
out_g2="$(bash "$CHECK" "$TMPROOT/tree" 2>&1)"; code_g2=$?
[ "$code_g2" -eq 0 ] \
  && check "the inline claude-sync and payload check passes too" ok \
  || check "the inline claude-sync and payload check passes too" "exit=$code_g2 out=$out_g2"

# ---------------------------------------------------------------------------
# WHAT IT MUST PRESERVE. Each of these is a real shape measured in this tree, and a rule matching
# `../..` anywhere refuses all of them (L104).
# ---------------------------------------------------------------------------
clear_tree
mk test-attack-string.sh '#!/usr/bin/env bash
# A hook must not be steerable by an identifier carrying path separators.
ESCAPE="$TMPDIR/escaped"
trav_id="../../..$ESCAPE"
run_the_hook "$trav_id"
[ ! -e "$ESCAPE" ] && echo ok'
mk test-prose.sh '#!/usr/bin/env bash
# WHERE THIS IS RUNNING. `$DIR/../..` is the repo in one and the HOME DIRECTORY in the other, so a
# suite that assumes the first walks all of $HOME in the second. That is why the guard below exists.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "$DIR"'
mk test-one-level.sh '#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(cd "$DIR/.." && pwd)"
echo "$CONFIG"'
mk test-sibling-glob.sh '#!/usr/bin/env bash
d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in "$d"/test-*.sh "$d"/../../tests/test-*.sh; do
  [ -f "$f" ] && echo "$f"
done'
out_keep="$(bash "$CHECK" "$TMPROOT/tree" 2>&1)"; code_keep=$?
[ "$code_keep" -eq 0 ] \
  && check "an attack string, a prose comment, one level up and a sibling glob are all left alone" ok \
  || check "an attack string, a prose comment, one level up and a sibling glob are all left alone" "exit=$code_keep out=$out_keep"

# THE GUARD MUST BE ABOUT THIS DERIVATION, not merely somewhere in the file. The first version
# asked whether the file mentioned claude-sync and payload ANYWHERE, which every suite in this
# repository does, so an unguarded derivation appended to a real suite was waved straight through.
# A guard matched over a WHOLE FILE is satisfied by any occurrence of the words (L135), and the
# fixtures above hid it because a fixture written by the same hand does not mention them. Found by
# reintroducing the #500 line into test-hook-coverage.sh and watching the scan stay green.
clear_tree
mk test-talks-about-it.sh '#!/usr/bin/env bash
# This suite is about claude-sync and the payload it installs, so both words appear in it.
ROOT="$(cd "$DIR/../.." && pwd)"
find "$ROOT" -type f -print'
out_talk="$(bash "$CHECK" "$TMPROOT/tree" 2>&1)"; code_talk=$?
[ "$code_talk" -ne 0 ] \
  && check "a file that merely MENTIONS claude-sync and payload is not thereby guarded" ok \
  || check "a file that merely MENTIONS claude-sync and payload is not thereby guarded" "exit=$code_talk out=$out_talk"

# The positive control in the SAME shape, or the check above is satisfied by a rule that refuses
# everything (L159): the same file, with the guard actually applied to the derived name.
clear_tree
mk test-really-guarded.sh '#!/usr/bin/env bash
# This suite is about claude-sync and the payload it installs.
ROOT="$(cd "$DIR/../.." && pwd)"
[ -f "$ROOT/claude-sync" ] && [ -d "$ROOT/payload" ] || exit 2
find "$ROOT" -type f -print'
out_really="$(bash "$CHECK" "$TMPROOT/tree" 2>&1)"; code_really=$?
[ "$code_really" -eq 0 ] \
  && check "and the same file WITH the guard on that name passes" ok \
  || check "and the same file WITH the guard on that name passes" "exit=$code_really out=$out_really"

# A THIRD GUARD SHAPE, and the strongest of them, found by running this scan against the real tree
# rather than by thinking about it: test-blank-check-cost.sh asks GIT whether the derived path is
# genuinely this repository's top level and compares the two, then narrows its scan when it is not.
# That is stronger than looking for marker files and the first version of this scan refused it,
# which is the over match that reads as the guard working (L104). Taken from the real file, because
# a shape invented here would only prove the rule agrees with itself (L48, L52).
clear_tree
mk test-git-guarded.sh '#!/usr/bin/env bash
REPO="$(cd "$DIR/../.." && pwd -P)"
REPO_TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$REPO_TOP" ] && [ "$REPO_TOP" = "$REPO" ]; then
  offenders="$(cd "$REPO" && git ls-files)"
else
  offenders="$(grep -rn x "$DIR")"
fi'
out_git="$(bash "$CHECK" "$TMPROOT/tree" 2>&1)"; code_git=$?
[ "$code_git" -eq 0 ] \
  && check "resolving the root through git and comparing it counts as guarded" ok \
  || check "resolving the root through git and comparing it counts as guarded" "exit=$code_git out=$out_git"

# ---------------------------------------------------------------------------
# A SCAN THAT EXAMINED NOTHING reports success exactly like one that examined everything and found
# it sound (L98). So it says how many derivations it looked at, and refuses a tree with no shell
# file in it at all.
# ---------------------------------------------------------------------------
clear_tree
mk test-guarded-notrun.sh '#!/usr/bin/env bash
REPO="$(cd "$DIR/../.." && pwd)"
[ -f "$REPO/claude-sync" ] && [ -d "$REPO/payload" ] || { printf "SUITE-NOT-RUN x\n"; exit 2; }'
out_n="$(bash "$CHECK" "$TMPROOT/tree" 2>&1)"
grep -qE '[0-9]+' <<< "$out_n" \
  && check "a clean sweep says how many derivations it examined" ok \
  || check "a clean sweep says how many derivations it examined" "out=$out_n"

mkdir -p "$TMPROOT/empty"
out_e="$(bash "$CHECK" "$TMPROOT/empty" 2>&1)"; code_e=$?
[ "$code_e" -ne 0 ] \
  && check "a tree holding no shell file is refused, not passed" ok \
  || check "a tree holding no shell file is refused, not passed" "exit=$code_e out=$out_e"
out_gone="$(bash "$CHECK" "$TMPROOT/not-there" 2>&1)"; code_gone=$?
[ "$code_gone" -ne 0 ] \
  && check "a root that is not there is refused" ok \
  || check "a root that is not there is refused" "exit=$code_gone out=$out_gone"

# ---------------------------------------------------------------------------
# The real repository, last, located by GIT rather than by counting upwards, which is the whole
# point of this check (L411 for the installed copy, which has no repository to scan).
# ---------------------------------------------------------------------------
ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then
  echo "note: this copy is not inside a git checkout, so the real tree is reported UNMEASURED rather than passed."
  check "the real tree could not be measured from this copy" ok
else
  out_real="$(bash "$CHECK" "$ROOT" 2>&1)"; code_real=$?
  [ "$code_real" -eq 0 ] \
    && check "every root derivation in this repository is guarded" ok \
    || check "every root derivation in this repository is guarded" "exit=$code_real out=$out_real"
  # And that it FOUND them. Nine were measured on 2026-09-19, so a run reporting none has stopped
  # looking at the thing it exists to watch and would still be green (L98, L182).
  real_n="${out_real#*guard: }"; real_n="${real_n%% *}"
  case "$real_n" in ''|*[!0-9]*) real_n=0 ;; esac
  [ "$real_n" -ge 5 ] \
    && check "and it actually examined the derivations rather than finding none" ok \
    || check "and it actually examined the derivations rather than finding none" "it examined only $real_n: $out_real"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
