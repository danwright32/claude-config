#!/usr/bin/env bash
# Tests for suite-pile-notice.sh, the per prompt notice that this repo's test suites have piled up
# on this Mac (claude-config#466).
#
# On 2026-09-18 559 suite processes ran for up to seven hours at zero CPU, and PR #462 taught
# `claude-sync status` to say so. Nobody runs status while a pile is slowing every session, so the
# delivery was still missing.
#
# What has to be proven is as much the QUIET as the speaking: this runs on every prompt in every
# project, so a notice on every prompt is the noise that teaches a person to skip it (L36), and a
# notice that fires on a busy but healthy afternoon is worse. Every loud case is followed by the
# prompt after it, in the same fixture, and the silent cases run where the loud ones can fire (L159).
#
# The predicate is NOT copied here, and not stubbed. The hook and `claude-sync status` both call
# hooks/lib/suite-pile.sh, and the last section runs the real status against the same fixtures and
# asserts the two agree, so this suite fails the day they stop agreeing (L41, L52).
#
# The process table and the clock are INJECTED on every run (SYNC_PS_FIXTURE and
# CLAUDE_SUITE_PILE_NOW). Nothing here reads the real process table, because what happens to be
# running on this Mac is not a fixture anybody chose (L2).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/suite-pile-notice.sh"
REPO="$(cd "$DIR/../.." && pwd)"
# The installed copy of these hooks has no claude-sync beside it, and the agreement checks drive the
# real one, so there it reports NOT RUN in the shape the runner reads (the rule
# test-sync-stuck-notice.sh follows).
if [ ! -f "$REPO/claude-sync" ] || [ ! -d "$REPO/payload" ]; then
  echo "test-suite-pile-notice: $REPO is not a checkout of this repo (no claude-sync and payload/ in it), so the status this suite compares against is not there." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $REPO is not one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
says() { # says <description> <text> <substring>
  case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3' (said: ${2:0:300})" ;; esac
}
never_says() { # never_says <description> <text> <substring>
  case "$2" in *"$3"*) check "$1" "it said '$3' (said: ${2:0:300})" ;; *) check "$1" ok ;; esac
}
silent() { # silent <description> <text>
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then check "$1" ok; else check "$1" "it said: ${2:0:300}"; fi
}

[ -f "$HOOK" ] || { echo "FAIL: no hook at $HOOK"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.pilenotice.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/state" "$WORK/home/.claude" "$WORK/repo"

# The limits are READ from the library that ships them, never written here as literals at their
# edge, so the day a default moves these fixtures still mean what they say (L401). Asserted where
# they are read, because a pattern that stopped matching would make every fixture read as young.
LIB="$DIR/lib/suite-pile.sh"
MAXAGE="$(sed -n 's/^SYNC_SUITE_MAX_AGE="\${SYNC_SUITE_MAX_AGE:-\([0-9][0-9]*\)}"$/\1/p' "$LIB" 2>/dev/null)"
MAXROOTS="$(sed -n 's/^SYNC_SUITE_MAX_ROOTS="\${SYNC_SUITE_MAX_ROOTS:-\([0-9][0-9]*\)}"$/\1/p' "$LIB" 2>/dev/null)"
REARM="$(sed -n 's/^SYNC_SUITE_PILE_REARM="\${SYNC_SUITE_PILE_REARM:-\([0-9][0-9]*\)}"$/\1/p' "$HOOK" 2>/dev/null)"
case "$MAXAGE$MAXROOTS$REARM" in
  ''|*[!0-9]*) check "the shipped limits can be read from the library and the hook" "read '$MAXAGE' '$MAXROOTS' '$REARM'"
               MAXAGE=3600; MAXROOTS=8; REARM=600 ;;
  *) check "the shipped limits can be read from the library and the hook" ok ;;
esac

et() { printf '%02d:%02d:%02d' $(( $1 / 3600 )) $(( $1 % 3600 / 60 )) $(( $1 % 60 )); }
OLD="$(et $(( MAXAGE * 2 )))"
YOUNG="00:00:04"
WT="/opt/fixture/Apps/claude-config/.claude/worktrees/agent-1/payload/hooks"
FX="/var/folders/T/claude-sync-work.runner-test.AAAA/dir-killed"

# One whole run of the runner, young, beside another project's old suite: a busy afternoon.
{
  printf '  900     1 %s /bin/bash %s/run-all-tests.sh\n' "$YOUNG" "$WT"
  printf '  901   900 %s bash %s/test-run-all-tests.sh\n' "$YOUNG" "$WT"
  printf '  902   901 %s bash %s/run-all-tests.sh %s\n' "$YOUNG" "$WT" "$FX"
  printf '  903   902 %s bash %s/test-one.sh\n' "$YOUNG" "$FX"
  printf '  905     1 %s bash /opt/fixture/.overture-verify-worktree/scripts/test-all.sh\n' "$OLD"
} > "$WORK/healthy"
# The shape found on 2026-09-18: a root past the age limit with what it waits on, and one young
# suite beside it that must never be named for killing.
{
  printf '  700     1 %s bash %s/test-run-all-tests.sh\n' "$OLD" "$WT"
  printf '  701   700 %s bash %s/run-all-tests.sh %s\n' "$OLD" "$WT" "$FX"
  printf '  702   701 %s bash %s/test-one.sh\n' "$OLD" "$FX"
  printf '  703     1 %s bash %s/test-kill-tree.sh\n' "$YOUNG" "$WT"
} > "$WORK/old"
# Breadth before age: one more independent start than the limit, and exactly the limit.
: > "$WORK/wide"; : > "$WORK/edge"
i=1
while [ "$i" -le $(( MAXROOTS + 1 )) ]; do
  printf '  %d     1 %s bash %s/test-%d.sh\n' $(( 600 + i )) "$YOUNG" "$WT" "$i" >> "$WORK/wide"
  [ "$i" -le "$MAXROOTS" ] && printf '  %d     1 %s bash %s/test-%d.sh\n' $(( 600 + i )) "$YOUNG" "$WT" "$i" >> "$WORK/edge"
  i=$(( i + 1 ))
done
printf '  710     1 1-02:03:04 bash %s/test-run-all-tests.sh\n' "$WT" > "$WORK/days"
: > "$WORK/empty"

NOW=1800000000
prompt() { # prompt <session> <table file> [now]  -> runs the hook as a UserPromptSubmit would
  printf '{"session_id":"%s","transcript_path":"/x/%s.jsonl","cwd":".","prompt":"carry on"}' "$1" "$1" \
    | HOME="$WORK/home" CLAUDE_HOME="$WORK/home/.claude" SYNC_PS_FIXTURE="$2" \
      CLAUDE_SUITE_PILE_STATE_DIR="$WORK/state" CLAUDE_SUITE_PILE_NOW="${3:-$NOW}" \
      bash "$HOOK" 2>/dev/null
}

echo "suite pile notice: a healthy table says nothing"
out="$(prompt calm "$WORK/healthy")"
silent "one young run of the runner, and another project's old suite, are not a pile" "$out"
out="$(prompt calm "$WORK/edge")"
silent "exactly the limit of independent suites is not a pile" "$out"
out="$(prompt calm "$WORK/empty")"
silent "nothing running says nothing" "$out"

echo "suite pile notice: an old pile is said once per stretch, per session"
out="$(prompt s1 "$WORK/old")"
says "a suite older than any suite may run is said" "$out" "piled up"
says "with the count past the limit, in the words status uses" "$out" "3 of them older than ${MAXAGE}s"
says "and it names the command that stops them" "$out" "kill -9"
kills="$(printf '%s\n' "$out" | grep -oE 'kill -9( [0-9]+)+' | tr ' ' '\n' | grep -xE '[0-9]+' | sort | tr '\n' ' ')"
if [ "$kills" = "700 701 702 " ]; then check "naming exactly the three past the limit, never the young one" ok
else check "naming exactly the three past the limit, never the young one" "named: '$kills'"; fi
says "and points at status for the whole list" "$out" "claude-sync status"
out="$(prompt s1 "$WORK/old" $(( NOW + 60 )))"
silent "the next prompt in the same session is quiet" "$out"
out="$(prompt s1 "$WORK/old" $(( NOW + 7200 )))"
silent "and so is one two hours later, the pile never having gone" "$out"
out="$(prompt s2 "$WORK/old" $(( NOW + 7200 )))"
says "a different session is told once too" "$out" "piled up"

echo "suite pile notice: a pile that flickers is one stretch, and one that stays gone ends it"
T=$(( NOW + 10000 ))
out="$(prompt s3 "$WORK/wide" "$T")"
says "more independent suites than one run keeps going is said" "$out" "$(( MAXROOTS + 1 )) started independently"
never_says "and names nothing to kill, since none is past the age limit" "$out" "kill -9"
out="$(prompt s3 "$WORK/edge" $(( T + 60 )))"
silent "dropping to the limit says nothing" "$out"
out="$(prompt s3 "$WORK/wide" $(( T + 120 )))"
silent "and coming back within the quiet window is the same stretch" "$out"
out="$(prompt s3 "$WORK/edge" $(( T + 200 )))"
silent "healthy again says nothing" "$out"
out="$(prompt s3 "$WORK/edge" $(( T + 200 + REARM )))"
silent "and healthy for the whole quiet window still says nothing" "$out"
out="$(prompt s3 "$WORK/wide" $(( T + 260 + REARM )))"
says "so a pile after that is a new stretch, and is said" "$out" "piled up"

echo "suite pile notice: an age written in days is read as days"
out="$(prompt d1 "$WORK/days")"
says "a suite a day old is said" "$out" "1-02:03:04"

echo "suite pile notice: a kill line too long for a notice is left to status, never cut short"
# Fifty one old suites under one root. A partial kill line would read as the whole of it.
printf '  800     1 %s bash %s/test-run-all-tests.sh\n' "$OLD" "$WT" > "$WORK/big"
i=1
while [ "$i" -le 50 ]; do
  printf '  %d   800 %s bash %s/test-one.sh\n' $(( 800 + i )) "$OLD" "$FX" >> "$WORK/big"
  i=$(( i + 1 ))
done
out="$(prompt big1 "$WORK/big")"
says "a pile of fifty one is said" "$out" "51 of them older than"
says "and sends the reader to status for the whole kill line" "$out" "kill -9 line for all 51"
case "$out" in
  *"kill -9 "[0-9]*) check "and names no partial list of pids" "it did: ${out:0:300}" ;;
  *) check "and names no partial list of pids" ok ;;
esac

echo "suite pile notice: anything it cannot read is silent, never a guess and never a block"
out="$(prompt u1 "$WORK/no-such-table")"; rc=$?
silent "an unreadable process table says nothing" "$out"
[ "$rc" -eq 0 ] && check "and the hook exits 0, so the prompt goes ahead" ok || check "and the hook exits 0, so the prompt goes ahead" "exit $rc"
out="$(prompt u1 "$WORK/old")"
says "and the next readable table is judged as a first sight" "$out" "piled up"
# A session that cannot be told apart from the next one cannot be told once.
out="$(printf '{"cwd":"."}' | SYNC_PS_FIXTURE="$WORK/old" CLAUDE_SUITE_PILE_STATE_DIR="$WORK/state" \
  CLAUDE_SUITE_PILE_NOW="$NOW" bash "$HOOK" 2>/dev/null)"; rc=$?
silent "a payload with no session says nothing on the prompt" "$out"
[ "$rc" -eq 0 ] && check "and exits 0" ok || check "and exits 0" "exit $rc"
# A record that cannot be written means it cannot stay quiet next time, so it does not speak now:
# once too few, never once per prompt (L36).
: > "$WORK/state-is-a-file"
out="$(printf '{"session_id":"w1"}' | SYNC_PS_FIXTURE="$WORK/old" CLAUDE_SUITE_PILE_STATE_DIR="$WORK/state-is-a-file" \
  CLAUDE_SUITE_PILE_NOW="$NOW" bash "$HOOK" 2>/dev/null)"; rc=$?
silent "a state directory that cannot be written says nothing" "$out"
[ "$rc" -eq 0 ] && check "and exits 0" ok || check "and exits 0" "exit $rc"
# An unreadable limit is not guessed at, and not said on every prompt either.
out="$(printf '{"session_id":"b1"}' | SYNC_PS_FIXTURE="$WORK/old" CLAUDE_SUITE_PILE_STATE_DIR="$WORK/state" \
  CLAUDE_SUITE_PILE_NOW="$NOW" SYNC_SUITE_MAX_AGE=soon bash "$HOOK" 2>/dev/null)"; rc=$?
silent "an unreadable age limit says nothing" "$out"
[ "$rc" -eq 0 ] && check "and exits 0" ok || check "and exits 0" "exit $rc"
# A copy of the hook with no library beside it.
mkdir -p "$WORK/bare"; cp "$HOOK" "$WORK/bare/"
out="$(printf '{"session_id":"l1"}' | SYNC_PS_FIXTURE="$WORK/old" CLAUDE_SUITE_PILE_STATE_DIR="$WORK/state" \
  CLAUDE_SUITE_PILE_NOW="$NOW" bash "$WORK/bare/suite-pile-notice.sh" 2>/dev/null)"; rc=$?
silent "a hook whose library is missing says nothing" "$out"
[ "$rc" -eq 0 ] && check "and exits 0" ok || check "and exits 0" "exit $rc"

echo "suite pile notice: status and the notice agree on every fixture"
# The real claude-sync, against the same tables. Status speaks exactly when the notice does, and
# names exactly the same pids for killing.
status_of() { SYNC_PS_FIXTURE="$1" CLAUDE_HOME="$WORK/home/.claude" SYNC_REPO="$WORK/repo" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$REPO/claude-sync" status 2>&1; }
pids_of() { printf '%s\n' "$1" | grep -oE 'kill -9( [0-9]+)+' | tr ' ' '\n' | grep -xE '[0-9]+' | sort | tr '\n' ' '; }
n=0
for f in healthy old wide edge days empty; do
  st="$(status_of "$WORK/$f")"
  no="$(prompt "agree-$f" "$WORK/$f")"
  case "$st" in *"test suites left running"*) st_says=1 ;; *) st_says=0 ;; esac
  if [ -z "$(printf '%s' "$no" | tr -d '[:space:]')" ]; then no_says=0; else no_says=1; fi
  if [ "$st_says" = "$no_says" ]; then check "status and the notice agree whether '$f' is a pile" ok
  else check "status and the notice agree whether '$f' is a pile" "status $st_says, notice $no_says"; fi
  if [ "$(pids_of "$st")" = "$(pids_of "$no")" ]; then check "and on what to kill in '$f'" ok
  else check "and on what to kill in '$f'" "status '$(pids_of "$st")', notice '$(pids_of "$no")'"; fi
  [ "$st_says" = 1 ] && n=$(( n + 1 ))
done
# Both halves seen, or agreement could be two silences (L159).
[ "$n" -eq 3 ] && check "three of the fixtures are piles to status, so agreement was tested both ways" ok \
  || check "three of the fixtures are piles to status, so agreement was tested both ways" "$n were"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
