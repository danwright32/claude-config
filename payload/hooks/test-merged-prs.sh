#!/usr/bin/env bash
# Tests for lib/merged-prs.sh, the one reading of whether a branch's work landed that
# check-stale-worktrees.sh and claude-sync share (claude-config#1198, #1199).
#
# A fake gh stands in for GitHub (L2), and the repository is real, because containment is a git
# question and only a real history can answer it.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/merged-prs.sh"
TMP="$(mktemp -d)"
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi }

G(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
R="$TMP/repo"; mkdir -p "$R"; G -C "$R" init -q -b main
c(){ printf '%s\n' "$1" >>"$R/f.txt"; G -C "$R" add f.txt; G -C "$R" commit -qm "$1"; G -C "$R" rev-parse HEAD; }
c base >/dev/null
G -C "$R" switch -q -c fix/1-feature
early="$(c early)"
last="$(c last)"
after="$(c after-the-merge)"
G -C "$R" switch -q main
GONE="1111111111111111111111111111111111111111"

# --- the gh call -----------------------------------------------------------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
[ -n "${GH_FAIL:-}" ] && { echo "gh: simulated failure" >&2; exit 1; }
cat "$GH_OUT"
STUB
chmod +x "$TMP/bin/gh"
export GH_CALLS="$TMP/calls" GH_OUT="$TMP/out"
printf 'fix/1-feature\t%s\t7\n' "$last" >"$GH_OUT"

: >"$GH_CALLS"
list="$(merged_prs "$TMP/bin/gh" 400 --repo o/r)"; rc=$?
check_eq "a readable list exits 0" 0 "$rc"
check_eq "and is passed on line for line" "$(cat "$GH_OUT")" "$list"
check_eq "asking for merged PRs, at the limit given, of the repository given" 1 \
  "$(grep -c -- '--state merged --limit 400 --repo o/r' "$GH_CALLS")"

GH_FAIL=1 merged_prs "$TMP/bin/gh" 400 >/dev/null; rc=$?
check_eq "a failed call is a failure, never an empty list (L98)" 1 "$rc"
: >"$GH_OUT"
out="$(merged_prs "$TMP/bin/gh" 400)"; rc=$?
check_eq "nothing merged yet is a success" 0 "$rc"
check_eq "with nothing printed" "" "$out"

# --- the verdicts ----------------------------------------------------------
L="$(printf 'fix/1-feature\t%s\t7\n' "$last")"
check_eq "HEAD at the PR's last commit has landed" "landed	7" "$(pr_landing "$R" fix/1-feature "$last" "$L")"
check_eq "HEAD at an earlier commit the PR also merged has landed" "landed	7" "$(pr_landing "$R" fix/1-feature "$early" "$L")"
check_eq "HEAD with a commit the PR never held is newer" "newer	7" "$(pr_landing "$R" fix/1-feature "$after" "$L")"
check_eq "a PR merged at a commit this repository lacks is unconfirmed" "unconfirmed	7" \
  "$(pr_landing "$R" fix/1-feature "$last" "$(printf 'fix/1-feature\t%s\t7\n' "$GONE")")"
check_eq "a branch no merged PR names is unmerged" "unmerged	" "$(pr_landing "$R" fix/2-other "$last" "$L")"
check_eq "an empty list leaves every branch unmerged" "unmerged	" "$(pr_landing "$R" fix/1-feature "$last" "")"
check_eq "a branch whose name is only a prefix of a merged one is unmerged" "unmerged	" \
  "$(pr_landing "$R" fix/1 "$last" "$L")"
# A branch name reused by a later PR: an older PR merged at a commit this HEAD went past, a newer
# one at the HEAD itself. Either holding it is enough, whichever order they are listed in.
two="$(printf 'fix/1-feature\t%s\t9\nfix/1-feature\t%s\t7\n' "$early" "$after")"
check_eq "of two merged PRs of one branch, the one holding HEAD decides" "landed	7" \
  "$(pr_landing "$R" fix/1-feature "$after" "$two")"

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
