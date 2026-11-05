#!/usr/bin/env bash
#
# test-suite-isolation.sh: a suite started on its own writes into throwaway records exactly as one
# the runner starts does, and tools/suite-home-writes.sh fails a suite that writes under ~/.claude
# (claude-config#2156).
#
# What is proved, in order:
#   1. suite_deadline_arm, which every suite calls, points every seam lib/suite-isolation.sh lists
#      at one throwaway folder when nothing set it, never under HOME, and leaves one a caller set.
#   2. The runner takes the same list from the same file and sets none of those seams by hand, so
#      the two places that start suites cannot drift apart (L613).
#   3. The check names a file a suite leaves under ~/.claude, a store beside it too, and passes a
#      suite whose writes the seams catch, and that pass is the arming's doing: the same suite with
#      no arming is failed (L1). It measures a suite started on its own even from inside a run that
#      exported the seams, and it never writes under the HOME it was started with.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$DIR/../payload/hooks"
LIB="$HOOKS/lib/suite-isolation.sh"
CHECK="$DIR/suite-home-writes.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.suiteiso.XXXXXXXX")" || W=""
case "${W%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$W'" >&2; exit 2 ;; esac
trap 'rm -rf "$W"' EXIT
# Everything below makes its throwaway folders in here, the check's HOMEs and the arming's own
# folders alike, so they go with this run and can be counted.
mkdir -p "$W/tmp"
export TMPDIR="$W/tmp"

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
says(){ case "$3" in *"$2"*) ok ;; *) bad "$1 (wanted [$2] in: ${3:0:600})" ;; esac; }
lacks(){ case "$3" in *"$2"*) bad "$1 (did not want [$2] in: ${3:0:600})" ;; *) ok ;; esac; }
eq(){ if [ "$2" = "$3" ]; then ok; else bad "$1 (wanted '$2', got '$3')"; fi; }

. "$LIB" || { echo "FAIL: lib/suite-isolation.sh is missing"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
VARS="$(suite_isolation_vars)"
unsets=(-u CLAUDE_HOME -u HOOK_TESTS_RUNNING)
for v in $VARS; do unsets+=(-u "$v"); done
NV="$(printf '%s\n' "$VARS" | wc -l | tr -d ' ')"
# Read from the library rather than typed here; at least the seven the runner exported before
# #2156 and the claude binary, so a list emptied by mistake cannot pass every case below.
case "
$VARS
" in *"
WRAPPED_REFUSAL_LEDGER_DIR
"*) has_wrapped=1 ;; *) has_wrapped=0 ;; esac
if [ "$NV" -ge 8 ] && [ "$has_wrapped" = 1 ]; then ok
else bad "the library lists the seams and the claude binary (got $NV: $VARS)"; fi

# ---- 1. arming isolates a suite started on its own ----
# What a suite sees after arming, with nothing around it: each variable's value, one per line.
mkdir -p "$W/home1"
armed="$(env "${unsets[@]}" HOME="$W/home1" SUITE_WALL_TIMEOUT=0 bash -c '
  . "$1/lib/suite-deadline.sh" || exit 9
  suite_deadline_arm || exit 8
  for v in $2; do printf "%s=%s\n" "$v" "${!v:-}"; done' _ "$HOOKS" "$VARS")"
eq "arming on its own sets a value for every listed variable" "$NV" "$(printf '%s\n' "$armed" | grep -c '=.')"
lacks "no seam armed on its own points under HOME" "$W/home1" "$armed"
iso="$(printf '%s\n' "$armed" | sed -n 's/^CLAUDE_ISSUE_SPOOL_DIR=\(.*\)\/issue-spool$/\1/p')"
says "the seams sit in one throwaway folder the scratch sweep reclaims" "$W/tmp/claude-sync-suite-work.isolated." "$iso"
eq "every seam sits in that same folder" "$((NV - 1))" "$(printf '%s\n' "$armed" | grep -c -F "=$iso/")"
eq "the claude binary is one that does not exist" "SYNC_CLAUDE_BIN=$SUITE_ISOLATION_NO_CLAUDE" "$(printf '%s\n' "$armed" | grep '^SYNC_CLAUDE_BIN=')"

# A seam the suite or the runner already set wins, and a fully set environment makes no folder.
kept="$(env "${unsets[@]}" HOME="$W/home1" SUITE_WALL_TIMEOUT=0 WRAPPED_REFUSAL_LEDGER_DIR="$W/mine" bash -c '
  . "$1/lib/suite-deadline.sh" || exit 9
  suite_deadline_arm || exit 8
  printf "%s\n%s\n" "$WRAPPED_REFUSAL_LEDGER_DIR" "$CLAUDE_ISSUE_SPOOL_DIR"' _ "$HOOKS")"
eq "a seam already set is left as it was" "$W/mine" "$(printf '%s\n' "$kept" | sed -n 1p)"
says "and the rest are still filled in" "claude-sync-suite-work.isolated." "$(printf '%s\n' "$kept" | sed -n 2p)"
# Set every variable in this test's own environment, so a fresh arming has nothing to fill.
full=(); for v in $VARS; do full+=("$v=$W/set-$v"); done
mkdir -p "$W/tmp-full"
none="$(env "${unsets[@]}" "${full[@]}" HOME="$W/home1" TMPDIR="$W/tmp-full" SUITE_WALL_TIMEOUT=0 bash -c '
  . "$1/lib/suite-deadline.sh" || exit 9
  suite_deadline_arm || exit 8
  ls "$TMPDIR"' _ "$HOOKS")"
eq "with every seam already set, arming makes no folder" "" "$none"

# The library refuses to point the seams at nothing, the root or HOME.
r="$(HOME="$W/home1" bash -c '. "$1"; suite_isolate "$HOME" every' _ "$LIB" 2>&1)"; rc=$?
eq "suite_isolate refuses HOME as the throwaway folder" 2 "$rc"
says "naming it" "refusing to point the seams" "$r"
r="$(bash -c '. "$1"; suite_isolate "" unset' _ "$LIB" 2>&1)"; rc=$?
eq "suite_isolate refuses an empty folder" 2 "$rc"
r="$(bash -c '. "$1"; suite_isolate "$2" sometimes' _ "$LIB" "$W/x" 2>&1)"; rc=$?
eq "suite_isolate refuses a mode it does not know" 2 "$rc"
# "every" replaces what was inherited, which is what the runner needs.
r="$(WRAPPED_REFUSAL_LEDGER_DIR=/elsewhere bash -c '. "$1"; suite_isolate "$2" every; printf %s "$WRAPPED_REFUSAL_LEDGER_DIR"' _ "$LIB" "$W/run")"
eq "every replaces an inherited seam" "$W/run/wrapped-refusals" "$r"

# ---- 2. the runner reads the same list ----
RUNNER="$HOOKS/run-all-tests.sh"
if grep -Eq '^[[:space:]]*suite_isolate "\$WORK" every' "$RUNNER"; then ok
else bad "run-all-tests.sh points the seams at its throwaway folder through suite_isolate \"\$WORK\" every"; fi
# A standalone assignment is what sets a seam for every suite after it. A prefix assignment
# (VAR=value command ...) reaches that one command only, which is how the runner's own spool canary
# points a single note at its canary folder, so it is not a second home for the list.
hand=""
for v in $VARS; do
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?$v=(\"[^\"]*\"|[^[:space:]\"]*)[[:space:]]*(;.*)?\$" "$RUNNER" && hand="$hand $v"
done
eq "run-all-tests.sh sets none of the listed seams by hand, so the list has one home" "" "$hand"
# The same scan finds every seam the runner used to set by hand, so its empty answer above is a
# measurement and not a pattern that matches nothing (L100).
old_hand=""
printf '%s\n' 'CLAUDE_ISSUE_SPOOL_DIR="$WORK/issue-spool"' 'export SYNC_CLAUDE_BIN="/nonexistent/x"' \
  '  PUSH_GATE_LEDGER_DIR="$WORK/push-gates"' 'SYNC_LOG_FILE=$WORK/sync-log; export SYNC_LOG_FILE' > "$W/old-runner.sh"
for v in CLAUDE_ISSUE_SPOOL_DIR SYNC_CLAUDE_BIN PUSH_GATE_LEDGER_DIR SYNC_LOG_FILE; do
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?$v=(\"[^\"]*\"|[^[:space:]\"]*)[[:space:]]*(;.*)?\$" "$W/old-runner.sh" && old_hand="$old_hand $v"
done
eq "the by hand scan finds each form a seam used to be set in" " CLAUDE_ISSUE_SPOOL_DIR SYNC_CLAUDE_BIN PUSH_GATE_LEDGER_DIR SYNC_LOG_FILE" "$old_hand"

# ---- 3. the check ----
# Fixture suites, each a few lines. One that arms and then writes the two ways a hook does when no
# seam is set: the wrapped command record by its default (check-wrapped-commands.sh's own line) and
# a spool note through the real library. One that does the same without arming. One that writes a
# file under ~/.claude that no seam covers, and one that writes beside it.
arm_lines(){ printf '. "%s/lib/suite-deadline.sh" || exit 9\nsuite_deadline_arm || exit 8\n' "$HOOKS"; }
writes(){
  printf 'd="${WRAPPED_REFUSAL_LEDGER_DIR:-$HOME/.claude/state/wrapped-commands}"; mkdir -p "$d"; printf "x\\n" >> "$d/refusals.tsv"\n'
  printf '. "%s/lib/issue-spool.sh" && issue_spool_note "%s" "a fixture finding" fixture >/dev/null 2>&1\n' "$HOOKS" "$W"
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
}
{ printf '#!/usr/bin/env bash\n'; arm_lines; writes; } > "$W/test-armed.sh"
{ printf '#!/usr/bin/env bash\n'; writes; } > "$W/test-unarmed.sh"
{ printf '#!/usr/bin/env bash\n'; arm_lines; printf 'mkdir -p "$HOME/.claude/state/stray" && printf x > "$HOME/.claude/state/stray/record"\n'; } > "$W/test-stray.sh"
{ printf '#!/usr/bin/env bash\n'; arm_lines; printf 'mkdir -p "$HOME/.claude-issue-spool" && printf x > "$HOME/.claude-issue-spool/by-hand.jsonl"\nexit 3\n'; } > "$W/test-beside.sh"
# One that stops before it writes anything, the way a suite refusing to run or crashing at its top
# does, and one that runs to the end writing nothing (#2208).
{ printf '#!/usr/bin/env bash\n'; arm_lines; printf 'echo "refusing to run" >&2\nexit 4\n'; } > "$W/test-crashed.sh"
{ printf '#!/usr/bin/env bash\n'; arm_lines; printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'; } > "$W/test-quiet.sh"

# The HOME the check itself is started with stands in for the real one, and must stay empty.
mkdir -p "$W/realhome"
out="$(HOME="$W/realhome" bash "$CHECK" "$W/test-armed.sh" 2>&1)"; rc=$?
eq "a suite whose writes the seams catch is passed" 0 "$rc"
says "and said to be clean, with its exit status" "clean $W/test-armed.sh: run on its own it left nothing under ~/.claude (the suite exited 0)" "$out"

out="$(HOME="$W/realhome" bash "$CHECK" "$W/test-unarmed.sh" 2>&1)"; rc=$?
eq "the same writes with no arming are failed, so the pass above is the arming's doing (L1)" 1 "$rc"
says "naming the wrapped command record" "~/.claude/state/wrapped-commands/refusals.tsv" "$out"
says "and the spool beside ~/.claude" "~/.claude-issue-spool/" "$out"

# From inside a run that already exported every seam (as the runner does), the check still measures
# the suite on its own: the inherited seams are cleared, so the unarmed suite is still caught. The
# runner's run id is cleared too: inherited, it made the spool refuse its real folder, so the
# spool write went unseen whenever this suite ran inside a full run.
out="$(env "${full[@]}" HOOK_TESTS_RUNNING=1 CLAUDE_SUITE_RUN_ID=inherited HOME="$W/realhome" bash "$CHECK" "$W/test-unarmed.sh" 2>&1)"; rc=$?
eq "inherited seams do not hide a suite's writes from the check" 1 "$rc"
says "it still names the record" "refusals.tsv" "$out"
says "and an inherited run id does not hide the spool write" "~/.claude-issue-spool/" "$out"
for v in $VARS; do
  [ "$v" = SYNC_CLAUDE_BIN ] && continue
  [ -e "$W/set-$v" ] && bad "the check let a suite write into an inherited seam ($v)"
done

out="$(HOME="$W/realhome" bash "$CHECK" "$W/test-stray.sh" 2>&1)"; rc=$?
eq "a file under ~/.claude no seam covers fails the suite" 1 "$rc"
says "named by its path" "WRITES-HOME $W/test-stray.sh: run on its own it left 1 file(s) under ~/.claude" "$out"
says "with the path itself" "~/.claude/state/stray/record" "$out"

out="$(HOME="$W/realhome" bash "$CHECK" "$W/test-beside.sh" 2>&1)"; rc=$?
eq "a store beside ~/.claude written by hand fails too" 1 "$rc"
says "giving the suite's own exit status" "(the suite exited 3)" "$out"
lacks "a suite that wrote and then failed keeps its WRITES-HOME verdict" "NOT-MEASURED" "$out"

# A suite that exited non zero having written nothing was never measured: it may have stopped
# before reaching any write, so nothing it left is a finding, and the check must not say clean or
# exit 0 (L98, L11, #2208).
out="$(HOME="$W/realhome" bash "$CHECK" "$W/test-crashed.sh" 2>&1)"; rc=$?
eq "a suite that failed having written nothing means the check could not measure it (2)" 2 "$rc"
says "and says not measured, naming the suite's exit status" "NOT-MEASURED $W/test-crashed.sh: it exited 4 having left nothing under ~/.claude" "$out"
lacks "and never calls it clean" "clean $W/test-crashed.sh" "$out"
# Beside a suite that wrote, the run still exits 2, because one suite was not measured at all.
out="$(HOME="$W/realhome" bash "$CHECK" "$W/test-stray.sh" "$W/test-crashed.sh" 2>&1)"; rc=$?
eq "a not measured suite beside one that wrote still exits 2" 2 "$rc"
says "naming the one that wrote" "WRITES-HOME $W/test-stray.sh" "$out"
says "and the one that was not measured" "NOT-MEASURED $W/test-crashed.sh" "$out"
# A suite that exits 0 having written nothing is still clean.
out="$(HOME="$W/realhome" bash "$CHECK" "$W/test-quiet.sh" 2>&1)"; rc=$?
eq "a suite that passed having written nothing is clean (0)" 0 "$rc"
says "and said to be clean" "clean $W/test-quiet.sh: run on its own it left nothing under ~/.claude (the suite exited 0)" "$out"

out="$(HOME="$W/realhome" bash "$CHECK" "$W/test-armed.sh" "$W/no-such-suite.sh" 2>&1)"; rc=$?
eq "a suite that is not a file means the check could not run (2), never clean" 2 "$rc"
says "and says so" "is not a file, so nothing was checked" "$out"
out="$(HOME="$W/realhome" bash "$CHECK" 2>&1)"; rc=$?
eq "no suite named is a usage error" 2 "$rc"

eq "the check never wrote under the HOME it was started with" "" "$(find "$W/realhome" -mindepth 1 2>/dev/null)"
left="$(find "$W/tmp" -maxdepth 1 -name 'claude-sync-suite-work.home.*' 2>/dev/null)"
eq "and removed every throwaway HOME it made" "" "$left"

# ---- 4. the refusals ----
# Arming refuses (2) rather than running a suite against the real records when the list is missing:
# a copy of suite-deadline.sh in a lib folder without suite-isolation.sh beside it.
python3 "$HOOKS/lib/install-hook-libs.py" "$HOOKS/lib" "$W/nolib/lib" suite-deadline.sh >/dev/null \
  || bad "#2204 suite-deadline.sh could not be installed with what it sources"
rm -f "$W/nolib/lib/suite-isolation.sh"   # the copy without the list, on purpose
r="$(env "${unsets[@]}" HOME="$W/home1" SUITE_WALL_TIMEOUT=0 bash -c '
  . "$1/lib/suite-deadline.sh" || exit 9
  suite_deadline_arm; rc=$?
  printf "rc=%s spool=%s\n" "$rc" "${CLAUDE_ISSUE_SPOOL_DIR:-}"' _ "$W/nolib" 2>&1)"
says "arming with no lib/suite-isolation.sh refuses (2)" "rc=2 spool=" "$r"
says "and says the suite would write into the real records" "lib/suite-isolation.sh is missing" "$r"
lacks "and points no seam anywhere" "spool=/" "$r"

# Arming refuses when no throwaway folder can be made: TMPDIR names a folder that does not exist.
r="$(env "${unsets[@]}" HOME="$W/home1" TMPDIR="$W/no-such-tmp" SUITE_WALL_TIMEOUT=0 bash -c '
  . "$1/lib/suite-deadline.sh" || exit 9
  suite_deadline_arm; rc=$?
  printf "rc=%s spool=%s\n" "$rc" "${CLAUDE_ISSUE_SPOOL_DIR:-}"' _ "$HOOKS" 2>&1)"
says "arming with no throwaway folder refuses (2)" "rc=2 spool=" "$r"
says "naming why" "no throwaway folder could be made" "$r"
lacks "and points no seam anywhere" "spool=/" "$r"

# The check exits 2, never clean, when it cannot make a throwaway HOME for a suite.
out="$(HOME="$W/realhome" TMPDIR="$W/no-such-tmp" bash "$CHECK" "$W/test-armed.sh" 2>&1)"; rc=$?
eq "the check with no throwaway HOME could not run (2)" 2 "$rc"
says "and says the suite was not run" "was not run" "$out"
lacks "and never calls it clean" "clean $W/test-armed.sh" "$out"

# The check exits 2 when the library naming the seams to clear is missing: a copy of it with no
# payload/hooks/lib beside it.
mkdir -p "$W/nocheck/tools"
cp "$CHECK" "$W/nocheck/tools/"
out="$(HOME="$W/realhome" bash "$W/nocheck/tools/suite-home-writes.sh" "$W/test-armed.sh" 2>&1)"; rc=$?
eq "the check with no lib/suite-isolation.sh could not run (2)" 2 "$rc"
says "and says the seams to clear are unknown" "the seams to clear are unknown" "$out"
eq "the refusals never wrote under the HOME they were started with" "" "$(find "$W/realhome" -mindepth 1 2>/dev/null)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
