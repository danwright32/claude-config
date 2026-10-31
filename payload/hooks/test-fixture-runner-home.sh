#!/usr/bin/env bash
# Tests for lib/fixture-runner-home.sh, the config folder of its own that a suite hands every run of
# run-all-tests.sh it starts against fixture suites (claude-config#1970).
#
# A suite testing the runner starts it against fixtures over and over. With CLAUDE_HOME left alone
# each of those runs bracketed the real ~/.claude, and run on its own (the way builders run one
# suite) nothing enclosed them, so a sync install or a Claude Code settings save landing in a
# fixture run's window failed a case that had nothing to do with it (#1964 traced two). The case
# below is that, reproduced: a suite run DIRECTLY, outside any runner, whose fixture run is inside
# its window while the planted Mac's real settings.json is rewritten from outside. Without the
# folder of its own the fixture run calls that pollution, which is the control; with it, the run
# passes and says nothing about a store it no longer reads.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$DIR/run-all-tests.sh"
LIB="$DIR/lib/fixture-runner-home.sh"

if [ ! -f "$DIR/lib/suite-deadline.sh" ]; then
  echo "FAIL: test-fixture-runner-home: no helper at $DIR/lib/suite-deadline.sh, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
. "$DIR/lib/suite-deadline.sh"
suite_deadline_arm || exit $?
. "$DIR/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing, so this suite's waits have no ceiling."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

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

T="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.fixture-home.XXXXXXXX")" || T=""
case "${T%/}" in
  ''|/|"${HOME%/}") echo "test-fixture-runner-home: refusing to run: throwaway directory came back as '$T'." >&2; exit 2 ;;
esac
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

# ---- 1. The library refuses a folder that is not a throwaway one, and exports nothing ----
# Asked with HOME at a throwaway folder, so a refusal that broke plants its fixture there and never
# in this Mac's real home or config folder: seen to happen when this was first proved to fail (L2).
FAKEHOME="$T/fakehome"
mkdir -p "$FAKEHOME"
for bad in "" "/" "$FAKEHOME" "$FAKEHOME/.claude" "$FAKEHOME/"; do
  got="$(env -u CLAUDE_HOME -u SYNC_CLONE_REGISTRY HOME="$FAKEHOME" bash -c '. "$1" || exit 9; fixture_runner_home "$2" 2>/dev/null; rc=$?; printf "%s|%s|%s" "$rc" "${CLAUDE_HOME-unset}" "${SYNC_CLONE_REGISTRY-unset}"' _ "$LIB" "$bad")"
  [ "$got" = "1|unset|unset" ] \
    && check "#1970 the library refuses '$bad' as a fixture config folder and exports nothing" ok \
    || check "#1970 the library refuses '$bad' as a fixture config folder and exports nothing" "rc|CLAUDE_HOME|SYNC_CLONE_REGISTRY = $got"
done

# ---- 2. What the folder carries: every store the runner reads, with content, and every seam ----
got="$(bash -c '. "$1" || exit 9; fixture_runner_home "$2" || exit 8; for v in CLAUDE_HOME SYNC_CLONE_REGISTRY SYNC_ZSHRC SYNC_WATCH_PID_FILE SYNC_HOLD_FILE; do printf "%s=%s\n" "$v" "${!v-unset}"; done' _ "$LIB" "$T/carry")"; code=$?
[ "$code" -eq 0 ] \
  && check "#1970 the library plants a folder under a throwaway directory" ok \
  || check "#1970 the library plants a folder under a throwaway directory" "exit=$code out=$got"
bad_seams=""
while IFS= read -r line; do
  case "${line#*=}" in "$T/carry/"*) ;; *) bad_seams="$bad_seams $line" ;; esac
done <<< "$got"
[ -z "$bad_seams" ] && [ "$(printf '%s\n' "$got" | grep -c .)" = 5 ] \
  && check "#1970 and it points CLAUDE_HOME and every Mac store seam inside it" ok \
  || check "#1970 and it points CLAUDE_HOME and every Mac store seam inside it" "outside it:$bad_seams (all: $got)"
# The stores are the runner's own list, read from the runner, so a store added to that list and not
# planted here is named on the day it is added (L96). The two globs are checked by their planted files.
missing=""
for store in $(grep -E '^\$\{CLAUDE_HOME:-\$HOME/\.claude\}/[A-Za-z.-]+$|^  _live_stores="\$\{CLAUDE_HOME:-\$HOME/\.claude\}/[A-Za-z.-]+$' "$RUNNER" | sed -E 's|.*\}/||'); do
  case "$store" in LESSONS-INDEX.md) continue ;; esac   # the retired single name: listed so a creation is caught, never planted
  [ -s "$T/carry/claude-home/$store" ] || missing="$missing $store"
done
for glob in 'LESSONS-INDEX-*.md' 'LESSONS-CORE-*.md'; do
  grep -qF "\"\${CLAUDE_HOME:-\$HOME/.claude}\"/$glob" "$RUNNER" || { missing="$missing (the runner no longer reads $glob)"; continue; }
  ls "$T/carry/claude-home/"$glob >/dev/null 2>&1 || missing="$missing $glob"
done
[ -z "$missing" ] \
  && check "#1970 the folder carries, with content, every store the runner reads from CLAUDE_HOME" ok \
  || check "#1970 the folder carries, with content, every store the runner reads from CLAUDE_HOME" "missing:$missing"
grep -q 'settings.json' <<< "$(ls "$T/carry/claude-home")" \
  && command -v jq >/dev/null 2>&1 \
  && [ "$(jq -r 'type' "$T/carry/claude-home/settings.json" 2>/dev/null)" = object ] \
  && check "#1970 and its settings.json is a JSON object, as a real Mac's is" ok \
  || check "#1970 and its settings.json is a JSON object, as a real Mac's is" "$(cat "$T/carry/claude-home/settings.json" 2>/dev/null)"

# ---- 3. A suite run on its own, while the real store changes underneath ----
# The planted Mac: a home with a config folder holding what a real one does, and nothing pointing
# anywhere else. The suite under test starts the runner against one fixture suite, exactly as
# test-run-all-tests.sh does, and is itself run DIRECTLY: no runner above it, no run id, no seams,
# HOME at the planted Mac and CLAUDE_HOME unset, which is what a builder running one suite has.
RH="$T/realhome"
mkdir -p "$RH/.claude" "$T/fx" "$T/suite" "$T/spool"
printf 'the real rules\n' > "$RH/.claude/CLAUDE.md"
real_settings='{
  "model": "opus",
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "bash /real/hooks/stop.sh"}]}]
  }
}'
# The fixture suite: it says when it is inside the run, waits for the outside writer, and records the
# config folder and register it was handed.
{
  printf '#!/usr/bin/env bash\n'
  printf '. "%s"\n' "$DIR/lib/hang-wait.sh"
  printf 'printf "%%s\\n%%s\\n" "${CLAUDE_HOME-unset}" "${SYNC_CLONE_REGISTRY-unset}" > "%s"\n' "$T/fx.seen"
  printf ': > "%s"\n' "$T/go"
  printf 'if hang_wait %q; then printf "SUITE-RESULT passed=1 failed=0\\n"; else printf "the outside writer never wrote\\nSUITE-RESULT passed=0 failed=1\\n"; exit 1; fi\n' "[ -f \"$T/done\" ]"
} > "$T/fx/test-waiter.sh"
chmod +x "$T/fx/test-waiter.sh"
# The suite under test: with "own" it hands its fixture runs a folder of their own through the
# library, as test-run-all-tests.sh does; with "real" it leaves CLAUDE_HOME alone, as it did before.
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "${1:-}" = own ]; then . "%s" || exit 3; fixture_runner_home "%s" || exit 3; fi\n' "$LIB" "$T/suite-scratch"
  printf 'HOOK_TESTS_ROOT="%s" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 bash "%s" "%s" > "%s" 2>&1\n' "$T/fx" "$RUNNER" "$T/fx" "$T/fx.out"
} > "$T/suite/test-starts-the-runner.sh"
chmod +x "$T/suite/test-starts-the-runner.sh"

run_directly(){ # run_directly <own|real> -> the suite's exit code; the fixture run's output is in fx.out
  printf '%s\n' "$real_settings" > "$RH/.claude/settings.json"
  rm -f "$T/go" "$T/done" "$T/fx.out" "$T/fx.seen"
  # The outside writer: a child of THIS file, a descendant of neither the suite nor its runner, timed
  # by the fixture's signal rather than a clock, so it lands inside the fixture run's window however
  # loaded the Mac is (L290). It rewrites the hooks block, the shape of a sync install, which no rule
  # in the runner excuses without a sync record, and this Mac's register names no clone.
  (
    hang_wait '[ -f "$T/go" ]' || exit 0
    printf '{\n  "model": "opus",\n  "hooks": {}\n}\n' > "$RH/.claude/settings.json"
    : > "$T/done"
  ) &
  local writer=$! rc
  env -u CLAUDE_HOME -u CLAUDE_SUITE_RUN_ID -u HOOK_TESTS_RUNNING \
    -u HOOK_TESTS_LIVE_BRACKETED -u HOOK_TESTS_LIVE_BRACKETED_RUN \
    -u SYNC_CLONE_REGISTRY -u SYNC_ZSHRC -u SYNC_WATCH_PID_FILE -u SYNC_HOLD_FILE \
    -u HOOK_TESTS_DEADLINE -u HOOK_TESTS_DEADLINE_RESERVE -u HOOK_TESTS_JOB_STARTED -u HOOK_TESTS_NOW \
    -u GITHUB_ACTIONS -u GITHUB_WORKFLOW_REF -u GITHUB_JOB \
    HOME="$RH" CLAUDE_ISSUE_SPOOL_DIR="$T/spool" HOOK_TESTS_FLAKY_OUTPUT="$T/flaky" \
    bash "$T/suite/test-starts-the-runner.sh" "$1" > /dev/null 2>&1
  rc=$?
  kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
  return "$rc"
}

# The control first: left on the real folder, the suite is failed by somebody else's write. Without
# this, a pass below could come from a writer that never landed in the window, or from a runner that
# brackets nothing at all (L246, L1).
run_directly real; code_real=$?
out_real="$(cat "$T/fx.out" 2>/dev/null)"
[ -f "$T/done" ] && printf '%s\n' "$out_real" | grep -E '^ +ok +test-waiter\.sh' > /dev/null \
  && check "#1970 (control) the outside writer rewrote the real settings.json inside the fixture run" ok \
  || check "#1970 (control) the outside writer rewrote the real settings.json inside the fixture run" "exit=$code_real out=$out_real"
case "$out_real" in
  *"SUITES CHANGED A LIVE STORE"*"$RH/.claude/settings.json"*)
    [ "$code_real" -ne 0 ] \
      && check "#1970 (control) a fixture run left on the real folder calls that write pollution" ok \
      || check "#1970 (control) a fixture run left on the real folder calls that write pollution" "exit=$code_real out=$out_real" ;;
  *) check "#1970 (control) a fixture run left on the real folder calls that write pollution" "exit=$code_real out=$out_real" ;;
esac

run_directly own; code_own=$?
out_own="$(cat "$T/fx.out" 2>/dev/null)"
seen_home="$(sed -n 1p "$T/fx.seen" 2>/dev/null)"
seen_reg="$(sed -n 2p "$T/fx.seen" 2>/dev/null)"
[ -f "$T/done" ] && grep -q '"hooks": {}' "$RH/.claude/settings.json" \
  && printf '%s\n' "$out_own" | grep -E '^ +ok +test-waiter\.sh' > /dev/null \
  && check "#1970 (control) the same write landed inside the fixture run handed a folder of its own" ok \
  || check "#1970 (control) the same write landed inside the fixture run handed a folder of its own" "exit=$code_own out=$out_own"
[ "$code_own" -eq 0 ] \
  && check "#1970 a suite run on its own is not failed by the real store changing under its fixture run" ok \
  || check "#1970 a suite run on its own is not failed by the real store changing under its fixture run" "exit=$code_own out=$out_own"
case "$out_own" in
  *"live-store-pollution"*|*"SUITES CHANGED A LIVE STORE"*|*"$RH/.claude"*)
    check "#1970 and the fixture run says nothing about the real folder" "out=$out_own" ;;
  *) check "#1970 and the fixture run says nothing about the real folder" ok ;;
esac
case "$seen_home|$seen_reg" in
  "$T/suite-scratch/claude-home|$T/suite-scratch/mac/claude-sync-clones") check "#1970 and the fixture suite was handed the throwaway folder and register" ok ;;
  *) check "#1970 and the fixture suite was handed the throwaway folder and register" "handed CLAUDE_HOME=$seen_home SYNC_CLONE_REGISTRY=$seen_reg" ;;
esac

# ---- 4. The folder of its own is still guarded ----
# Moving the bracket is not removing it: a fixture suite that rewrites a store in the throwaway
# folder still fails its run, naming the store, so the folder is a real home to the runner and not
# one it skips. Without this the pass above could be a runner that brackets nothing (L2).
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "a whole file a suite wrote\\n" > "$CLAUDE_HOME/CLAUDE.md"\n'
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
} > "$T/fx/test-waiter.sh"
run_directly own; code_w=$?
out_w="$(cat "$T/fx.out" 2>/dev/null)"
case "$out_w" in
  *"SUITES CHANGED A LIVE STORE"*"$T/suite-scratch/claude-home/CLAUDE.md"*)
    [ "$code_w" -ne 0 ] \
      && check "#1970 a fixture suite writing the throwaway folder's rules still fails its run" ok \
      || check "#1970 a fixture suite writing the throwaway folder's rules still fails its run" "exit=$code_w out=$out_w" ;;
  *) check "#1970 a fixture suite writing the throwaway folder's rules still fails its run" "exit=$code_w out=$out_w" ;;
esac
[ "$(cat "$RH/.claude/CLAUDE.md")" = "the real rules" ] \
  && check "#1970 and the real folder's rules were never touched" ok \
  || check "#1970 and the real folder's rules were never touched" "they now read: $(cat "$RH/.claude/CLAUDE.md")"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
