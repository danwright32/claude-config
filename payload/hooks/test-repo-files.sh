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
for f in committed.sh sub/committed-deep.sh gone.sh committed.md edited.sh; do printf 'x\n' > "$R/$f"; done
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c commit.gpgsign=false commit -q -m seed >/dev/null 2>&1
rm -f "$R/gone.sh"                                   # tracked, deleted from the tree
printf 'y\n' > "$R/edited.sh"                        # tracked, edited and not committed
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
for want in committed.sh sub/committed-deep.sh committed.md edited.sh staged.sh untracked.sh sub/untracked-deep.sh; do
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

# Every path whose contents on disk may differ from the commit, which is what a key over what the
# scanners read is built from (claude-config#1910). The scanners read a tracked file from disk, so
# one edited and not committed changes what they read as much as a new file does, and so does one
# deleted, which they no longer read. Ignored files and a nested checkout are not read, so not listed.
chg="$(bash "$RF" --changed "$R" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$chg" | sort | tr '\n' ' ')" = "edited.sh gone.sh staged.sh sub/untracked-deep.sh untracked.sh " ] \
  && check "#1910 --changed lists exactly the edited, deleted, staged and untracked files" ok \
  || check "#1910 --changed lists exactly the edited, deleted, staged and untracked files" "rc=$rc got: $chg"
# A name git would quote, non-ASCII or holding a double quote, is listed as it is on disk. Quoted,
# it named no file there, so it read as deleted and an edit to it never changed the key.
Q="$TMPROOT/quoted"; mkdir -p "$Q"; git -C "$Q" init -q
git -C "$Q" config user.email t@t; git -C "$Q" config user.name t
printf 'x\n' > "$Q/caf$(printf '\303\251').sh"; printf 'x\n' > "$Q/say\"hi\".sh"
git -C "$Q" add -A >/dev/null 2>&1; git -C "$Q" -c commit.gpgsign=false commit -q -m seed >/dev/null 2>&1
printf 'y\n' > "$Q/caf$(printf '\303\251').sh"; printf 'y\n' > "$Q/say\"hi\".sh"; printf 'x\n' > "$Q/new$(printf '\303\251').sh"
chg="$(bash "$RF" --changed "$Q" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && has "caf$(printf '\303\251').sh" "$chg" && has "say\"hi\".sh" "$chg" && has "new$(printf '\303\251').sh" "$chg" \
  && check "#1910 --changed lists a name git would quote as it is on disk" ok \
  || check "#1910 --changed lists a name git would quote as it is on disk" "rc=$rc got: $chg"
# A clean checkout has nothing that differs, which is an empty list and a success, never a refusal.
C="$TMPROOT/clean"; mkdir -p "$C"; git -C "$C" init -q
git -C "$C" config user.email t@t; git -C "$C" config user.name t
printf 'x\n' > "$C/a.sh"; git -C "$C" add -A >/dev/null 2>&1; git -C "$C" -c commit.gpgsign=false commit -q -m seed >/dev/null 2>&1
chg="$(bash "$RF" --changed "$C" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$chg" ] && check "#1910 --changed on a clean checkout is an empty list and a success" ok \
  || check "#1910 --changed on a clean checkout is an empty list and a success" "rc=$rc got: $chg"
# A checkout with no commit has nothing to differ FROM, so it is refused, never listed as clean (L98).
N="$TMPROOT/nocommit"; mkdir -p "$N"; git -C "$N" init -q; printf 'x\n' > "$N/a.sh"
out="$(bash "$RF" --changed "$N" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && check "#1910 --changed with no commit to compare against is refused" ok \
  || check "#1910 --changed with no commit to compare against is refused" "rc=$rc out=$out"

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
