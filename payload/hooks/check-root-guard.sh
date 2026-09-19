#!/usr/bin/env bash
#
# check-root-guard.sh: refuse a file that derives the repository root by counting directories
# upwards without confirming what it landed on (claude-config#503).
#
# `"$DIR/../.."` is the repository root when a file runs from payload/hooks, and the HOME DIRECTORY
# when the same file runs from the installed copy in ~/.claude/hooks. Both copies exist at once and
# only one of them is ever exercised while writing, so the wrong answer is invisible until the file
# is installed.
#
# IT HAS COST THE SAME THING TWICE. On 2026-09-11 an unguarded derivation made `claude-sync
# recheck` exceed its thirty minute ceiling and report the whole config unverified. The guard was
# added to the suites that had it and written up in their comments, and nothing enforced it, so on
# 2026-09-19 test-shell-syntax.sh shipped without one and the first pull that installed it spent
# twenty two minutes walking every file under ~. A convention followed by habit and enforced by
# nothing is what this repo keeps paying for (L30, L96), and the wrong answer here is not merely
# wrong, it is unbounded.
#
# WHAT COUNTS AS GUARDED, taken from what the nine existing derivations actually do rather than
# invented: the file either emits SUITE-NOT-RUN, which is the agreed way a suite says it is not in
# a checkout, or it tests the derived root for `claude-sync` and `payload`. Either proves the
# author asked the question.
#
# WHAT IT MATCHES, and why it is narrow. Measured over this tree on 2026-09-19: eighteen lines hold
# `../..` and only nine are root derivations. Five are prose comments, two of them in the files
# describing this very trap, and two are `../../..` used as a PATH TRAVERSAL ATTACK STRING in a
# fixture proving a hook cannot be steered by one. Matching `../..` anywhere would refuse seven
# correct things, which is the over match that reads exactly like a guard working (L104). So this
# matches the derivation SHAPE: an assignment whose value comes from a `cd <something>/../.. && pwd`
# substitution, outside a comment.
#
# Run:  bash ~/.claude/hooks/check-root-guard.sh [ROOT]
#
# Exit 0 = every upward root derivation found is guarded, and it says how many it examined.
# Exit 1 = at least one is not. Each is named with its file and line.
# Exit 2 = nothing could be examined: ROOT is not a directory, or holds no shell file at all.
#          Refusing rather than passing, because a scan that read nothing reports success exactly
#          like one that read everything and found it sound (L98).

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || ROOT=""
  [ -n "$ROOT" ] || ROOT="$(cd "$DIR/.." && pwd)"
fi
if [ ! -d "$ROOT" ]; then
  echo "check-root-guard: '$ROOT' is not a directory, so nothing could be examined. Refusing rather than falling back to somewhere else, which looks exactly like having run on the one you named (L320)." >&2
  exit 2
fi

# The derivation shape, outside a comment. A leading `#` is what separates the five prose mentions
# in this tree from the nine real derivations.
DERIVE_RE='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*\$\(cd .*/\.\./\.\.".*pwd'

files=0
found=0
bad=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  files=$((files + 1))
  hits="$(grep -nE "$DERIVE_RE" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [ -n "$hits" ] || continue
  # THE GUARD HAS TO BE ABOUT THIS DERIVATION. Asking whether the file mentions claude-sync and
  # payload anywhere exempts every suite in this repository, because they all talk about both: an
  # unguarded derivation appended to test-hook-coverage.sh was waved straight through by that
  # version, and the fixtures did not show it because a fixture written by the same hand does not
  # mention those words (L135). So the NAME the derivation assigned has to appear in a check for
  # one of the two markers. SUITE-NOT-RUN still counts on its own: it is a token that exists for
  # exactly this and a file printing it has asked the question.
  #
  # Per derivation rather than per file, because a file may hold more than one.
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    found=$((found + 1))
    var="${h#*:}"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%%=*}"
    guarded=0
    grep -q 'SUITE-NOT-RUN' "$f" 2>/dev/null && guarded=1
    if [ "$guarded" -eq 0 ] && [ -n "$var" ]; then
      grep -qE "\\\$\{?$var\}?/(claude-sync|payload)" "$f" 2>/dev/null && guarded=1
    fi
    # The third shape, and the strongest: resolve the derived path through git and compare it with
    # what was derived. test-blank-check-cost.sh does this, and the first version of this scan
    # refused it, which is how the over match was found (L104). Keyed on the same NAME, so it is a
    # guard on THIS derivation rather than a phrase sitting somewhere in the file.
    if [ "$guarded" -eq 0 ] && [ -n "$var" ]; then
      if grep -q "rev-parse --show-toplevel" "$f" 2>/dev/null && grep -q "\$$var" "$f" 2>/dev/null; then
        guarded=1
      fi
    fi
    [ "$guarded" -eq 1 ] && continue
    bad="$bad  ${f#$ROOT/}:${h%%:*}  (derives $var, and nothing checks it)
"
  done <<EOF
$hits
EOF
done <<EOF
$(find "$ROOT" \( -name .git -o -name node_modules -o -name worktrees \) -prune -o -type f -name '*.sh' -print 2>/dev/null)
EOF

if [ "$files" -eq 0 ]; then
  echo "check-root-guard: found no shell file at all under '$ROOT', so nothing was examined. Refusing rather than reporting a clean sweep of nothing (L98)." >&2
  exit 2
fi

case "$bad" in
  *[![:space:]]*)
    echo "check-root-guard: these derive a root by counting directories upwards and never check what they landed on:" >&2
    printf '%s' "$bad" >&2
    echo "That expression is the repository root from payload/hooks and the HOME DIRECTORY from the installed copy in the config folder, so the file works while you write it and walks everything you own once it ships. Guard it: emit SUITE-NOT-RUN when the result holds no claude-sync and payload, or test for them before using it. Two of these have already cost half an hour each (claude-config#503)." >&2
    exit 1 ;;
esac

echo "check-root-guard: $found upward root derivation(s) examined across $files shell file(s) under '$ROOT', every one of them guarded."
exit 0
