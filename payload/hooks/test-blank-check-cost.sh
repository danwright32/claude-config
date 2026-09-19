#!/usr/bin/env bash
# Tests that nothing decides whether a captured string is blank by substituting every whitespace
# character out of it (claude-config#117).
#
# `${s//[[:space:]]/}` builds a whole new string, and under the bash macOS ships (3.2) the cost is
# superlinear in the NUMBER OF MATCHES: measured on this Mac on 2026-08-21, at 1,536 matches it
# took 11.5 seconds and at 3,072 it took 82, while `case "$s" in *[![:space:]]*)` answered both in
# 3 milliseconds.
# It hung tools/measure-sync-gaps.sh for minutes on the real repo while every one of that tool's
# tests passed, because a fixture has almost no matches by construction and a size-dependent path
# always takes the small branch under test (L101).
#
# So the checks below are built the only way that can catch it: with an input holding thousands of
# matches, which is what these sites see when something is WRONG. check-home-paths builds its list
# from grep hits, so a tree with many violations is exactly the tree that makes the guard slow, and
# the harvest spool takes model output of unbounded length. The class guard at the bottom then
# covers the sites no fixture here drives, because a defect fixed at one site and left at ten
# others is the instance, not the class (L30).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-home-paths.sh"
SPOOL="$DIR/lib/issue-spool.sh"

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

TMPROOT="$(mktemp -d)"
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-blank-check-cost: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# A deadline rather than a stopwatch. Timing a run that is going to take four minutes means WAITING
# four minutes for the failure, on every suite run, on every machine; killing it at the deadline
# reports the same fact in seconds. The command is judged by whether it finished, never by a line
# of its output (L184).
# There is exactly ONE run per scenario, and the assertions about what it SAID read the file it
# wrote. Running it a second time without a deadline to inspect its output would hang for as long
# as the defect takes, which on the fixture below is minutes, so the deadline would report the
# right answer and the suite would still never finish.
DEADLINE=20
run_by() { # run_by <seconds> <output file> <command...>  -> its exit, or 124 if it ran out of time
  local secs="$1" outfile="$2"; shift 2
  : > "$outfile"
  "$@" > "$outfile" 2>&1 &
  local pid=$! ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$((secs * 10))" ]; then
      # The command may have spawned children of its own, and killing only the one this shell
      # knows about leaves them running for the rest of the suite. pkill by parent covers the
      # generation below, which is as deep as anything here goes.
      pkill -9 -P "$pid" 2>/dev/null
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

# Assembled at runtime for the same reason test-check-home-paths.sh does it: written whole, this
# file would itself carry a machine path and the guard it is testing would fail on its own test.
BADHOME="/Users""/someone-elses-mac"

# ---------------------------------------------------------------------------
# The guard that gets slower the more it has to report.
#
# 120 violating lines, each padded with 100 spaces: about 12,000 whitespace matches. Those are
# sizes this fixture chooses and not measured, so they carry no date. While the
# per-line work inside the scanner (which spawns greps and is nothing to do with the blank test)
# stays at 120 lines. Sizing it by MATCHES rather than by lines is the point: a threshold measured
# while a co-varying component moves too attaches itself to the wrong variable (L209).
# ---------------------------------------------------------------------------
BIG="$TMPROOT/many-violations"
mkdir -p "$BIG/hooks" "$BIG/skills/demo" "$BIG/agents" "$BIG/commands"
printf '# rules\n' > "$BIG/CLAUDE.md"
PAD="$(printf '%100s' '')"
: > "$BIG/skills/demo/SKILL.md"
for i in $(seq 1 120); do
  printf 'bash %s/.claude/skills/x/healthcheck.sh%s# %s\n' "$BADHOME" "$PAD" "$i" >> "$BIG/skills/demo/SKILL.md"
done

BIGOUT="$TMPROOT/many-violations.out"
run_by "$DEADLINE" "$BIGOUT" bash "$CHECK" "$BIG"
rc_big=$?
[ "$rc_big" -ne 124 ] \
  && check "a tree with many violations is reported inside $DEADLINE seconds" ok \
  || check "a tree with many violations is reported inside $DEADLINE seconds" "it was still running at the deadline"

# And it must still be REPORTING them. A blank test that answers fast by answering wrong would pass
# the deadline above and say the tree is clean, which is the reassuring reading of the pair (L98).
[ "$rc_big" -eq 1 ] \
  && check "and it still fails on them rather than reporting a clean tree" ok \
  || check "and it still fails on them rather than reporting a clean tree" "exit=$rc_big"
# `grep -c` prints 0 AND fails when it counts nothing, so `|| echo 0` runs too and the value is
# two lines, which errors every numeric test on it (claude-config#172).
named_big="$(grep -c 'skills/demo/SKILL.md' "$BIGOUT" 2>/dev/null || true)"
case "$named_big" in ''|*[!0-9]*) named_big=0 ;; esac
[ "${named_big:-0}" -ge 120 ] \
  && check "and every one of the 120 lines is named" ok \
  || check "and every one of the 120 lines is named" "named $named_big"

# The clean tree still passes, so the check above is not measuring a scanner that stopped scanning.
CLEAN="$TMPROOT/clean"
mkdir -p "$CLEAN/hooks" "$CLEAN/skills/demo" "$CLEAN/agents" "$CLEAN/commands"
printf '# rules\n' > "$CLEAN/CLAUDE.md"
printf 'bash ~/.claude/skills/x/healthcheck.sh\n' > "$CLEAN/skills/demo/SKILL.md"
out_clean="$(bash "$CHECK" "$CLEAN" 2>&1)"; code_clean=$?
[ "$code_clean" -eq 0 ] \
  && check "a clean tree still passes" ok \
  || check "a clean tree still passes" "exit=$code_clean out=$out_clean"

# ---------------------------------------------------------------------------
# The spool's own blank test, whose input is model output of unbounded length.
# ---------------------------------------------------------------------------
# EXPORTED BEFORE SOURCING. The library now resolves its location on every write,
# so setting this afterwards would work anyway, but a test that depends on that
# to stay out of the real spool is one library change away from writing into it
# again. This suite wrote a fake finding into Dan's live spool on every run for
# as long as it existed, 120 of them on one machine (L2).
export CLAUDE_ISSUE_SPOOL_DIR="$TMPROOT/spool"
# shellcheck source=/dev/null
. "$SPOOL"
SPOOLDIR="$TMPROOT/spool-project"; mkdir -p "$SPOOLDIR"
git -C "$SPOOLDIR" init -q 2>/dev/null

LONG="$(seq 1 4000 | tr '\n' ' ')"   # 4,000 whitespace matches, built without a shell loop

note_long() { issue_spool_note "$SPOOLDIR" "$LONG" tester; }
run_by "$DEADLINE" "$TMPROOT/note.out" note_long
rc_note=$?
[ "$rc_note" -ne 124 ] \
  && check "a long finding is spooled inside $DEADLINE seconds" ok \
  || check "a long finding is spooled inside $DEADLINE seconds" "it was still running at the deadline"

# A finding that really is blank is still refused, so the speed above is not the check being gone.
issue_spool_note "$SPOOLDIR" "$(printf ' \n\t ')" tester >/dev/null 2>&1
[ "$?" -eq 2 ] \
  && check "an all-whitespace finding is still refused" ok \
  || check "an all-whitespace finding is still refused" "it was accepted"

# ---------------------------------------------------------------------------
# The class. Every site is found from the files rather than from a list kept here, because a list
# only ever checks what somebody remembered to add to it and a new site is then exempt from the
# very check meant to catch it (L96).
#
# Comment-only lines are skipped deliberately: tools/measure-sync-gaps.sh explains the defect by
# quoting it, and a guard that cannot tell the line describing a thing from the line committing it
# fails on its own documentation (the same trick check-style-guide.sh needs).
# ---------------------------------------------------------------------------
REPO="$(cd "$DIR/../.." && pwd -P)"
# Asked of git rather than of the filesystem (claude-config#402). This read `[ -d "$REPO/.git" ]`,
# and in a git worktree `.git` is a FILE, so every run from a worktree took the branch below and
# read only payload/hooks: claude-sync was never scanned and a violation CI caught passed locally.
# The top level has to BE this file's repo, not merely some repository above an installed copy,
# so it is compared with the directory rather than taken as present.
REPO_TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_TOP" ] && REPO_TOP="$(cd "$REPO_TOP" 2>/dev/null && pwd -P || true)"
if [ -n "$REPO_TOP" ] && [ "$REPO_TOP" = "$REPO" ]; then
  # Grepped FROM the repository. ls-files prints paths relative to it, and grep resolved them against
  # whatever directory the suite was started in, so run from anywhere but the root every file was
  # missing, the error went to /dev/null, and the guard reported a clean tree it had never read
  # (L98). Found by the worktree fixture below, whose control run passed when it had to fail.
  offenders="$(cd "$REPO" && git ls-files -z \
      | xargs -0 grep -nE '\[ *-[nz] *"?\$\{[A-Za-z_][A-Za-z_0-9]*//' 2>/dev/null \
      | grep -vE ':[0-9]+: *#' || true)"
else
  # Installed under the config directory, where the repo is not present. The payload's own hooks
  # are still here and are still worth checking; saying WHICH tree was read keeps a narrower run
  # from reading as the full one (L11).
  offenders="$(grep -rnE '\[ *-[nz] *"?\$\{[A-Za-z_][A-Za-z_0-9]*//' "$DIR" 2>/dev/null \
      | grep -vE ':[0-9]+: *#' || true)"
  echo "test-blank-check-cost: no repo above $DIR, so the class guard read only $DIR."
fi
case "$offenders" in
  *[![:space:]]*)
    check "nothing tests blankness by substituting whitespace away" "still doing it:
$offenders" ;;
  *)
    check "nothing tests blankness by substituting whitespace away" ok ;;
esac

# The guard has to have been able to see one. A pattern that matches nothing is indistinguishable
# from a clean tree, and this one is scoped narrowly enough to be worth proving (L1, L98).
# Assembled at runtime, never written whole: spelled out, this line is itself an occurrence and the
# guard above would fail on its own positive control. The guard cannot tell the line demonstrating
# the pattern from the line committing it, which is the guard working correctly, and the answer is
# to leave no literal for it to find (the same trick check-style-guide.sh needs for the characters
# it bans).
PLANT="$TMPROOT/planted.sh"
SS='//'
printf '%s\n' 'x=""' "[ -n \"\${x${SS}[[:space:]]/}\" ] && echo hi" > "$PLANT"
grep -nE '\[ *-[nz] *"?\$\{[A-Za-z_][A-Za-z_0-9]*//' "$PLANT" >/dev/null 2>&1 \
  && check "and the pattern it looks for does match a planted one" ok \
  || check "and the pattern it looks for does match a planted one" "it matched nothing"

# ---------------------------------------------------------------------------
# The class guard reads the WHOLE repository when run from a worktree (claude-config#402).
#
# The repo used to be recognised by a `.git` DIRECTORY above this file. In a git worktree `.git` is
# a FILE pointing at the real one, so the test was false there, the guard fell through to the
# installed branch, and it read only payload/hooks. claude-sync was never scanned, so a local run
# from a worktree passed a violation CI then caught (PR #393). Agents work in worktrees by default,
# which made the narrower run the ordinary one.
#
# Driven end to end: a throwaway repository holding a copy of this suite and a violation planted in
# claude-sync, and a worktree of it. The same copy is run from both. The run from the main checkout
# is the CONTROL: it has to fail, or a worktree run that passes would say nothing about worktrees
# (L159). Nested runs skip this block, or each would build the fixture again.
# ---------------------------------------------------------------------------
if [ -z "${BLANK_CHECK_NESTED:-}" ] && command -v git >/dev/null 2>&1; then
  WT_MAIN="$TMPROOT/wt-main"
  WT_TREE="$TMPROOT/wt-linked"
  mkdir -p "$WT_MAIN/payload/hooks/lib"
  cp "${BASH_SOURCE[0]}" "$WT_MAIN/payload/hooks/test-blank-check-cost.sh"
  cp "$CHECK" "$WT_MAIN/payload/hooks/check-home-paths.sh"
  cp "$SPOOL" "$WT_MAIN/payload/hooks/lib/issue-spool.sh"
  # The copy of this suite arms its own deadline like every suite does (claude-config#465), and it
  # refuses to run without the helper, so the fixture carries the helper as well as the file.
  cp "$DIR/lib/suite-deadline.sh" "$WT_MAIN/payload/hooks/lib/suite-deadline.sh"
  cp "$DIR/lib/kill-tree.sh" "$WT_MAIN/payload/hooks/lib/kill-tree.sh"
  # Assembled, for the reason the planted file above is: written whole it is an occurrence here.
  printf '%s\n' '#!/usr/bin/env bash' 'y=""' "[ -z \"\${y${SS}[[:space:]]/}\" ] && echo blank" > "$WT_MAIN/claude-sync"
  git init -q "$WT_MAIN" 2>/dev/null
  git -C "$WT_MAIN" config user.email t@e 2>/dev/null
  git -C "$WT_MAIN" config user.name t 2>/dev/null
  git -C "$WT_MAIN" add . >/dev/null 2>&1
  git -C "$WT_MAIN" -c commit.gpgsign=false commit -q -m seed >/dev/null 2>&1
  git -C "$WT_MAIN" worktree add -q --detach "$WT_TREE" >/dev/null 2>&1

  # The fixture has to BE a worktree, or everything below measures an ordinary checkout.
  [ -f "$WT_TREE/.git" ] && [ -f "$WT_TREE/claude-sync" ] \
    && check "the worktree fixture really is a worktree, with .git a file" ok \
    || check "the worktree fixture really is a worktree, with .git a file" "no linked worktree at $WT_TREE"

  wt_main_out="$(BLANK_CHECK_NESTED=1 bash "$WT_MAIN/payload/hooks/test-blank-check-cost.sh" 2>&1)"; wt_main_rc=$?
  case "$wt_main_rc:$wt_main_out" in
    0:*) check "run from the main checkout, the guard finds the violation in claude-sync" "it passed" ;;
    *claude-sync*) check "run from the main checkout, the guard finds the violation in claude-sync" ok ;;
    *) check "run from the main checkout, the guard finds the violation in claude-sync" "it failed without naming claude-sync: $wt_main_out" ;;
  esac

  wt_tree_out="$(BLANK_CHECK_NESTED=1 bash "$WT_TREE/payload/hooks/test-blank-check-cost.sh" 2>&1)"; wt_tree_rc=$?
  case "$wt_tree_rc:$wt_tree_out" in
    0:*) check "run from a worktree, the guard still reads claude-sync and finds it" "it passed, having read: $wt_tree_out" ;;
    *claude-sync*) check "run from a worktree, the guard still reads claude-sync and finds it" ok ;;
    *) check "run from a worktree, the guard still reads claude-sync and finds it" "it failed without naming claude-sync: $wt_tree_out" ;;
  esac
  case "$wt_tree_out" in
    *"no repo above"*) check "and it does not call a worktree an installed copy" "it said: $wt_tree_out" ;;
    *) check "and it does not call a worktree an installed copy" ok ;;
  esac
fi

# The CLASS of #402, across the repository rather than this one file (L30). A search on the day it
# was fixed found the same directory test in claude-sync's report on other clones, which called a
# registered worktree gone, and in match-open-issues.py, which refused a worktree as ambiguous. Both
# now test for existence. A path that CONTINUES past `.git` (`.git/rebase-merge`) is a different
# question and is not matched: the pattern requires `.git` to end the quoted path.
# Only readable where the repository is, for the reason the blank test above says so.
GITDIR_PAT='(\[ *(! *)?-d|test +(! +)?-d|isdir\()[^]]{0,80}[/"'"'"']\.git["'"'"')]'
if [ -n "$REPO_TOP" ] && [ "$REPO_TOP" = "$REPO" ]; then
  gitdir_offenders="$(cd "$REPO" && git ls-files -z \
      | xargs -0 grep -nE "$GITDIR_PAT" 2>/dev/null \
      | grep -vE ':[0-9]+: *#' || true)"
  case "$gitdir_offenders" in
    *[![:space:]]*)
      check "nothing recognises a checkout by a .git DIRECTORY, which a worktree does not have" "still doing it:
$gitdir_offenders
  Test with -e (or os.path.exists), or ask git rev-parse --show-toplevel." ;;
    *) check "nothing recognises a checkout by a .git DIRECTORY, which a worktree does not have" ok ;;
  esac
fi
# Seen to match the shapes it names, and NOT a path continuing past .git, before its silence counts.
# Assembled, never written whole, or this file would be its own offender.
GD='-''d'
# The NEGATED forms are planted too: the claude-sync site read `[ ! -d "$d/.git" ]`, and the first
# version of this pattern allowed nothing between the bracket and the flag, so it passed with that
# site put back. Found by tools/prove-it-fails.sh, not by reading.
printf '%s\n' "[ $GD \"\$R/.git\" ]" "os.path.is""dir(os.path.join(p, \".git\"))" \
  "if [ ! $GD \"\$d/.git\" ]; then" "test ! $GD \"\$R/.git\" || exit 0" > "$TMPROOT/gitdir-hit.txt"
printf '%s\n' "[ $GD \"\$R/.git/rebase-merge\" ]" "[ -e \"\$R/.git\" ]" > "$TMPROOT/gitdir-miss.txt"
gd_hits="$(grep -cE "$GITDIR_PAT" "$TMPROOT/gitdir-hit.txt" 2>/dev/null || true)"
gd_miss="$(grep -cE "$GITDIR_PAT" "$TMPROOT/gitdir-miss.txt" 2>/dev/null || true)"
[ "$gd_hits" = 4 ] && [ "$gd_miss" = 0 ] \
  && check "and that pattern matches a planted directory test and not its neighbours" ok \
  || check "and that pattern matches a planted directory test and not its neighbours" "matched $gd_hits of 4 planted, and $gd_miss of 2 it must leave"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
