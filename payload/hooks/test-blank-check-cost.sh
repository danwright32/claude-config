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
named_big="$(grep -c 'skills/demo/SKILL.md' "$BIGOUT" 2>/dev/null || echo 0)"
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
# shellcheck source=/dev/null
. "$SPOOL"
SPOOLDIR="$TMPROOT/spool-project"; mkdir -p "$SPOOLDIR"
git -C "$SPOOLDIR" init -q 2>/dev/null

LONG="$(seq 1 4000 | tr '\n' ' ')"   # 4,000 whitespace matches, built without a shell loop

note_long() { CLAUDE_ISSUE_SPOOL_DIR="$TMPROOT/spool" issue_spool_note "$SPOOLDIR" "$LONG" tester; }
run_by "$DEADLINE" "$TMPROOT/note.out" note_long
rc_note=$?
[ "$rc_note" -ne 124 ] \
  && check "a long finding is spooled inside $DEADLINE seconds" ok \
  || check "a long finding is spooled inside $DEADLINE seconds" "it was still running at the deadline"

# A finding that really is blank is still refused, so the speed above is not the check being gone.
CLAUDE_ISSUE_SPOOL_DIR="$TMPROOT/spool" issue_spool_note "$SPOOLDIR" "$(printf ' \n\t ')" tester >/dev/null 2>&1
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
REPO="$(cd "$DIR/../.." && pwd)"
if [ -d "$REPO/.git" ]; then
  offenders="$(git -C "$REPO" ls-files -z \
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

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
