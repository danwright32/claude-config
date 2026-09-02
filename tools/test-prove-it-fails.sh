#!/usr/bin/env bash
# Tests for prove-it-fails.sh, the thing that answers whether a check would notice its own subject
# being broken (claude-config#276).
#
# It exists because the manual version of this ritual gave the wrong answer twice in one session:
# the fix was removed, the section still passed, and without somebody noticing that, a test that
# could only ever pass would have shipped as proof. So the three answers this tool can give have to
# be told apart by anything reading it, and each of them is produced here rather than described.
#
# Every fixture is a TINY repository of its own, built in a throwaway directory, never this one. A
# suite that proved this tool by running the real suites would take six minutes a case and would be
# the thing it is testing (L2, L298).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/prove-it-fails.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.prove-test.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-prove-it-fails: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

git_here(){ git -C "$1" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "${@:2}"; }

# A repository holding one guard and the thing it guards. `check.sh` is the test: it reports a
# failure when the word the guard exists to keep is missing from `subject.txt`. That is the whole
# shape of every case below, with the fixture standing in for a suite and the word for a fix.
mk_repo(){ # mk_repo <dir> [<what check.sh does>]
  mkdir -p "$1"
  printf 'guarded\n' > "$1/subject.txt"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if grep -q guarded "$(dirname "$0")/subject.txt"; then\n'
    printf '  echo "ok: the subject is guarded"; exit 0\n'
    printf 'fi\n'
    printf 'echo "FAIL: the subject is not guarded"; exit 1\n'
  } > "$1/check.sh"
  chmod +x "$1/check.sh"
  git -C "$1" init -q
  git_here "$1" add -A >/dev/null 2>&1
  git_here "$1" commit -qm "the guard and its subject" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# The answer the tool exists to give: the check noticed.
# ---------------------------------------------------------------------------
R1="$TMPROOT/proved"
mk_repo "$R1"
out1="$(bash "$TOOL" --repo "$R1" --run 'bash check.sh' --sed subject.txt 's/guarded/nothing here/' 2>&1)"; rc1=$?
[ "$rc1" -eq 0 ] \
  && check "a check that notices its subject being broken is PROVED" ok \
  || check "a check that notices its subject being broken is PROVED" "exit=$rc1 out=$out1"
case "$out1" in
  *PROVED*) check "and the word PROVED is what it says" ok ;;
  *) check "and the word PROVED is what it says" "out=$out1" ;;
esac
case "$out1" in
  *"the subject is not guarded"*)
    check "and it carries the failure the check actually printed" ok ;;
  *)
    check "and it carries the failure the check actually printed" "out=$out1" ;;
esac
# The point of working on a copy: an interrupted round must not leave the tree modified, which is
# the whole reason the manual version was skipped when the suite was slow (L5).
case "$(cat "$R1/subject.txt")" in
  guarded) check "and the tree it was pointed at is untouched" ok ;;
  *) check "and the tree it was pointed at is untouched" "subject.txt is now: $(cat "$R1/subject.txt")" ;;
esac

# ---------------------------------------------------------------------------
# The answer it was built to stop being missed: the check did NOT notice.
# ---------------------------------------------------------------------------
# A check that always passes is the failure mode this whole repo is organised against, and it is
# indistinguishable from a real one until something breaks its subject underneath it (L1).
R2="$TMPROOT/notproved"
mk_repo "$R2"
printf '#!/usr/bin/env bash\necho "ok: a check that measures nothing"\nexit 0\n' > "$R2/check.sh"
git_here "$R2" commit -qam "a check that cannot fail" >/dev/null 2>&1
out2="$(bash "$TOOL" --repo "$R2" --run 'bash check.sh' --sed subject.txt 's/guarded/nothing here/' 2>&1)"; rc2=$?
[ "$rc2" -eq 1 ] \
  && check "a check that cannot fail is NOT PROVED, with its own exit code" ok \
  || check "a check that cannot fail is NOT PROVED, with its own exit code" "exit=$rc2 out=$out2"
case "$out2" in
  *"NOT PROVED"*) check "and it says so in words as well" ok ;;
  *) check "and it says so in words as well" "out=$out2" ;;
esac

# ---------------------------------------------------------------------------
# The refusals. Each is a case where answering at all would be a lie.
# ---------------------------------------------------------------------------
# A patch that matched nothing leaves the check passing for the reason it always did, which reads
# exactly like a check that does not discriminate (L100, L98). Refusing is the only honest answer,
# and this is the case that produced two wrong answers by hand on 2026-09-02.
R3="$TMPROOT/nomatch"
mk_repo "$R3"
out3="$(bash "$TOOL" --repo "$R3" --run 'bash check.sh' --sed subject.txt 's/nothing-like-this/x/' 2>&1)"; rc3=$?
[ "$rc3" -eq 2 ] \
  && check "a patch that matches nothing is REFUSED rather than answered" ok \
  || check "a patch that matches nothing is REFUSED rather than answered" "exit=$rc3 out=$out3"
case "$out3" in
  *"changed nothing in subject.txt"*)
    check "and the refusal names the file it changed nothing in" ok ;;
  *)
    check "and the refusal names the file it changed nothing in" "out=$out3" ;;
esac

# A check that was ALREADY failing cannot prove anything by failing again, and its red is
# indistinguishable from the red this tool produces (L159, L11). This is the half the manual ritual
# skipped, because the person had just watched it pass.
R4="$TMPROOT/alreadyred"
mk_repo "$R4"
printf 'nothing here\n' > "$R4/subject.txt"
git_here "$R4" commit -qam "the subject without its guard" >/dev/null 2>&1
out4="$(bash "$TOOL" --repo "$R4" --run 'bash check.sh' --sed check.sh 's/exit 0/exit 0/' 2>&1)"; rc4=$?
[ "$rc4" -eq 2 ] \
  && check "a check that already fails is REFUSED before anything is changed" ok \
  || check "a check that already fails is REFUSED before anything is changed" "exit=$rc4 out=$out4"
case "$out4" in
  *"ALREADY FAILS"*) check "and it says the baseline was red, not that the change was noticed" ok ;;
  *) check "and it says the baseline was red, not that the change was noticed" "out=$out4" ;;
esac

# Nothing to break is not a proof either: with no patch the tool would run the check twice and
# report that it passes, which is the answer it exists to refuse to give.
out5="$(bash "$TOOL" --repo "$R1" --run 'bash check.sh' 2>&1)"; rc5=$?
[ "$rc5" -eq 2 ] \
  && check "no patch at all is refused rather than run" ok \
  || check "no patch at all is refused rather than run" "exit=$rc5 out=$out5"

# ---------------------------------------------------------------------------
# --revert, which is how a fix that is not committed yet gets removed.
# ---------------------------------------------------------------------------
R6="$TMPROOT/revert"
mk_repo "$R6"
# The committed state has the guard REMOVED, and the working copy is the fix: exactly the shape of
# a session where the test is written, the fix is made, and neither is committed.
printf 'nothing here\n' > "$R6/subject.txt"
git_here "$R6" commit -qam "before the fix" >/dev/null 2>&1
printf 'guarded\n' > "$R6/subject.txt"
out6="$(bash "$TOOL" --repo "$R6" --run 'bash check.sh' --revert subject.txt 2>&1)"; rc6=$?
[ "$rc6" -eq 0 ] \
  && check "reverting the file the fix is in proves the check notices" ok \
  || check "reverting the file the fix is in proves the check notices" "exit=$rc6 out=$out6"
case "$(cat "$R6/subject.txt")" in
  guarded) check "and the working copy still holds the fix afterwards" ok ;;
  *) check "and the working copy still holds the fix afterwards" "subject.txt is now: $(cat "$R6/subject.txt")" ;;
esac

# A revert that restored nothing is the same lie as a patch that matched nothing: the file was
# already what HEAD holds, so the check ran against the state it was going to run against anyway.
R7="$TMPROOT/revert-noop"
mk_repo "$R7"
out7="$(bash "$TOOL" --repo "$R7" --run 'bash check.sh' --revert subject.txt 2>&1)"; rc7=$?
[ "$rc7" -eq 2 ] \
  && check "reverting a file that already matches HEAD is refused" ok \
  || check "reverting a file that already matches HEAD is refused" "exit=$rc7 out=$out7"
case "$out7" in
  *"already exactly what HEAD holds"*)
    check "and it says the revert removed nothing" ok ;;
  *)
    check "and it says the revert removed nothing" "out=$out7" ;;
esac

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
