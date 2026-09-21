#!/usr/bin/env bash
# Tests for lib/repo-files.sh, the one way a whole tree scanner here lists the files it reads
# (claude-config#522).
#
# Every scanner used to ask `git ls-files`, which lists what is TRACKED, so a file written and not
# yet committed was exempt from the checks that exist to catch exactly that file, the one most
# likely to be wrong (L456). Measured 2026-09-20: scanners-before-push.sh was written with two
# short circuiting pipelines, the pipefail ratchet passed while it was untracked, and failed the
# moment it was committed.
#
# The second half is the guard that keeps it the ONE way (L613): a suite that enumerates its own
# repository with a bare `git ls-files` is refused, so the next scanner cannot quietly reopen the
# blind spot this closes.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RF="$DIR/lib/repo-files.sh"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-repo-files.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-repo-files: refusing to run: throwaway directory came back as '${TMPROOT}'." >&2
    exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# One fixture repository holding every state a file can be in, each named for its state.
R="$TMPROOT/repo"
mkdir -p "$R/sub" "$R/nested"
git -C "$R" init -q
git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'ignored.sh\n' > "$R/.gitignore"
for f in committed.sh sub/committed-deep.sh gone.sh committed.md; do printf 'x\n' > "$R/$f"; done
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c commit.gpgsign=false commit -q -m seed >/dev/null 2>&1
rm -f "$R/gone.sh"                                   # tracked, deleted from the tree
printf 'x\n' > "$R/staged.sh"; git -C "$R" add staged.sh
printf 'x\n' > "$R/untracked.sh"
printf 'x\n' > "$R/sub/untracked-deep.sh"
printf 'x\n' > "$R/ignored.sh"
git -C "$R/nested" init -q                           # a nested checkout, which is somebody else's
printf 'x\n' > "$R/nested/inner.sh"

all="$(bash "$RF" "$R" 2>&1)"; rc=$?
has(){ case "
$2
" in *"
$1
"*) return 0 ;; esac; return 1; }
[ "$rc" -eq 0 ] && check "it lists a repository's files" ok || check "it lists a repository's files" "rc=$rc out=$all"
for want in committed.sh sub/committed-deep.sh committed.md staged.sh untracked.sh sub/untracked-deep.sh; do
  has "$want" "$all" && check "it lists $want" ok || check "it lists $want" "got: $all"
done
for not in gone.sh ignored.sh nested/inner.sh nested/ nested; do
  has "$not" "$all" && check "it leaves out $not" "got: $all" || check "it leaves out $not" ok
done
[ "$(printf '%s\n' "$all" | sort | uniq -d | grep -c . || true)" -eq 0 ] \
  && check "and names each file once" ok || check "and names each file once" "got: $all"

# A pathspec narrows it, the way every scanner here asks for one kind of file.
sh_only="$(bash "$RF" "$R" '*.sh' 2>&1)"
has committed.md "$sh_only" && check "a pathspec narrows the list" "got: $sh_only" \
  || { has untracked.sh "$sh_only" && check "a pathspec narrows the list" ok || check "a pathspec narrows the list" "got: $sh_only"; }

# Only the uncommitted ones, which is what a gate says it included.
unc="$(bash "$RF" --uncommitted "$R" 2>&1)"
[ "$(printf '%s\n' "$unc" | sort | tr '\n' ' ')" = "staged.sh sub/untracked-deep.sh untracked.sh " ] \
  && check "--uncommitted lists exactly the staged and untracked files" ok \
  || check "--uncommitted lists exactly the staged and untracked files" "got: $unc"

# Not a repository is a refusal that says so, never an empty list that reads as a clean tree (L98).
mkdir -p "$TMPROOT/plain"
out="$(bash "$RF" "$TMPROOT/plain" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && case "$out" in *"not a git"*) true ;; *) false ;; esac \
  && check "a directory that is not a repository is refused by name" ok \
  || check "a directory that is not a repository is refused by name" "rc=$rc out=$out"

# ---------------------------------------------------------------------------
# THE GUARD: no suite enumerates its own repository with a bare `git ls-files` (L613).
#
# What counts as enumerating its OWN repository: `git -C` on one of the names these suites give
# their own root, or `cd` into one and then listing. A listing of a FIXTURE repository is
# something else and is left alone, as is `--error-unmatch` (asking about one named file) and
# `--others` (already reading what is not committed). A site that genuinely means TRACKED files
# only says so on the line, with a reason that begins with a word: `# tracked-only: <why>` (L675).
# ---------------------------------------------------------------------------
GUARD_PAT='(git +-C +"\$\{?(ROOT|REPO|root|_sc_root)\}?"|cd +"\$\{?(ROOT|REPO|root)\}?" *&& *git) +ls-files'
guard_scan(){        # $1 = directory to read -> offending lines as <file>:<line>: text
  local d="$1" f
  for f in "$d"/test-*.sh "$d"/../../tests/test-*.sh; do
    [ -f "$f" ] || continue
    grep -nE "$GUARD_PAT" "$f" 2>/dev/null \
      | grep -vE -- '--error-unmatch|--others|# tracked-only: [A-Za-z]' \
      | sed "s|^|${f#"$d"/}:|"
  done
  return 0
}
# Seen to fire first, on a planted copy, so the clean result below is a measurement (L1).
# The planted lines are ASSEMBLED, never written out, or this file would report itself (L245).
mkdir -p "$TMPROOT/plant"
LSF="ls-""files"
bare='x="$(git -C "$ROOT" '"$LSF"')"'
printf '%s\n' "$bare" > "$TMPROOT/plant/test-planted.sh"
printf '%s\n' 'y="$(git -C "$ROOT" '"$LSF"' --error-unmatch f)"' 'z="$(git -C "$FIX" '"$LSF"')"' \
  'w="$(git -C "$ROOT" '"$LSF"') # tracked-only: a reason' > "$TMPROOT/plant/test-allowed.sh"
planted="$(guard_scan "$TMPROOT/plant")"
[ "$(printf '%s\n' "$planted" | grep -c . || true)" -eq 1 ] && has "test-planted.sh:1:$bare" "$planted" \
  && check "the guard catches a bare listing of a suite's own root, and only that" ok \
  || check "the guard catches a bare listing of a suite's own root, and only that" "got: $planted"
real="$(guard_scan "$DIR")"
case "$real" in
  *[![:space:]]*) check "no suite here lists its own repository with a bare git ls-files" "these do, and are blind to uncommitted files:
$real
  List through lib/repo-files.sh, or say why the site means tracked only with # tracked-only: <reason>." ;;
  *) check "no suite here lists its own repository with a bare git ls-files" ok ;;
esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
