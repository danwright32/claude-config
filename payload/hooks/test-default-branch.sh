#!/usr/bin/env bash
# test-default-branch.sh: lib/default-branch.sh, which branch a checkout's work merges into.
# Read by the stale worktree sweep and both shipped tools (#2309), so a wrong answer here judges
# every detached worktree against the wrong branch.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/default-branch.sh"

pass=0; fail=0
check_eq(){ # check_eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
G(){ git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# The remote's own HEAD wins over whatever the checkout is on.
R="$TMP/repo"; mkdir -p "$R"; G -C "$R" init -q -b trunk
printf 'x\n' >"$R/f"; G -C "$R" add f; G -C "$R" commit -qm base
G init -q --bare "$TMP/remote.git"; G -C "$R" remote add origin "$TMP/remote.git"
G -C "$R" push -q origin trunk >/dev/null 2>&1
G -C "$R" branch release; G -C "$R" push -q origin release >/dev/null 2>&1
G -C "$R" remote set-head origin release >/dev/null 2>&1
out="$(default_branch "$R")"; rc=$?
check_eq "the remote's HEAD names the default branch" "origin/release" "$out"
check_eq "and it is a ref here, so it succeeds" 0 "$rc"

# With no remote HEAD it falls back to the checkout's own branch on origin.
G -C "$R" remote set-head origin --delete >/dev/null 2>&1
out="$(default_branch "$R")"; rc=$?
check_eq "with no remote HEAD the checkout's branch on origin is used" "origin/trunk" "$out"
check_eq "and it exists, so it succeeds" 0 "$rc"

# A name that is not a ref here fails, printing the name it tried, so no caller judges against it.
N="$TMP/noremote"; mkdir -p "$N"; G -C "$N" init -q -b trunk
printf 'x\n' >"$N/f"; G -C "$N" add f; G -C "$N" commit -qm base
out="$(default_branch "$N")"; rc=$?
check_eq "with no remote at all it names what it tried" "origin/trunk" "$out"
check_eq "and fails, since that is no ref here" 1 "$rc"

echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
