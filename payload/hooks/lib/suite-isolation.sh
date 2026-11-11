#!/usr/bin/env bash
#
# suite-isolation.sh: the throwaway records every suite writes into instead of this Mac's real ones,
# in ONE list, for the runner and for a suite started on its own alike (claude-config#2156).
#
# Each record a hook or library keeps under ~/.claude (or beside it) has a seam, a variable naming
# where it goes instead. run-all-tests.sh used to export every one itself, so a suite got throwaway
# records only when the runner started it, and a suite typed straight into a shell, which is how
# builders run one before a full run, wrote into the real ones: 123 "eval, reader-lib-missing" rows
# from test-gates-fail-closed.sh reached the real record of wrapped command refusals that way
# (#2126). Fixing that one suite (#2155) leaves the next one, so the list lives here and both places
# that start suites read it: the runner, which points every seam at its own throwaway folder
# whatever was inherited, and suite_deadline_arm (lib/suite-deadline.sh), which every suite calls
# near its top and which fills in any seam nothing has set yet. A suite that names its own still
# wins, as it always did under the runner.
#
# Adding a record that has a seam is one line in suite_isolation_seams below and one in
# suite_isolate's case, which refuses a listed seam it has no line for. A record with no seam
# at all is not covered by anything here, and tools/suite-home-writes.sh is how one is found: it
# runs a suite on its own under a throwaway HOME and names every file the suite left under that
# HOME's .claude.
#
# Sourced, never run. Defines functions only, so sourcing it touches nothing.

# The claude binary claude-sync is told to use under any suite: one that does not exist, so a suite
# that forgot its own stub can never start the real Claude Code (L2, #828).
SUITE_ISOLATION_NO_CLAUDE="/nonexistent/run-all-tests/no-claude-for-suites"

# Points claude-sync's claude binary at nothing, whatever was inherited. The runner calls this on
# its own near its top, before its throwaway folder exists, and suite_isolate calls it too, so the
# value is set in exactly one place.
suite_isolation_no_claude(){
  SYNC_CLAUDE_BIN="$SUITE_ISOLATION_NO_CLAUDE"
  export SYNC_CLAUDE_BIN
}

# Turns Python's bytecode cache off for everything a suite runs, whatever was inherited
# (claude-config#2751). A program importing a module with it on leaves __pycache__ beside the
# module, and a part's suites run side by side, so one suite's import from lib/ failed
# test-work-names.sh's #2444 check on a pull request that touched neither: three writers found one
# at a time (#2444, #2600, #2751). Called by the runner near its top and by every suite arming its
# deadline, so the next importer nobody has found is covered the day it lands. `python3 -I` and `-E`
# drop it, which is why test-lib-bytecode-importers.sh still asks for -B on the command itself, and
# a suite whose check is ABOUT bytecode unsets it after arming so the check can still see a writer.
suite_isolation_no_bytecode(){
  PYTHONDONTWRITEBYTECODE=1
  export PYTHONDONTWRITEBYTECODE
}

# One seam per line: the variable, then where it points inside the throwaway folder.
suite_isolation_seams(){
  printf '%s\n' \
    'CLAUDE_ISSUE_SPOOL_DIR issue-spool' \
    'PUSH_GATE_LEDGER_DIR push-gates' \
    'WRAPPED_REFUSAL_LEDGER_DIR wrapped-refusals' \
    'MT_SIGNIN_LEDGER_DIR gh-signin' \
    'MWR_PHASE_DIR merge-phases' \
    'SYNC_LOG_FILE sync-log' \
    'CLAUDE_SLEEP_RECORD sleep-record/current.json'
}

# Every variable this file sets, one per line: the seams, then the claude binary.
suite_isolation_vars(){
  suite_isolation_seams | while read -r var _; do printf '%s\n' "$var"; done
  printf '%s\n' SYNC_CLAUDE_BIN
}

# 0 when every variable is already set to something, so a caller can skip making a folder at all.
suite_isolation_complete(){
  local var
  for var in $(suite_isolation_vars); do
    [ -n "${!var:-}" ] || return 1
  done
  return 0
}

# suite_isolate <throwaway folder> <every|unset>
# Exports each seam at its place in the folder. "every" replaces whatever was inherited, which is
# what the runner does; "unset" leaves alone any seam already set, which is what a suite arming its
# own deadline does, so a value the runner or the suite itself chose wins. Refuses (2) a folder that
# is empty, the root or HOME, so no seam can ever be pointed at the real records by a bad argument.
suite_isolate(){
  local dir="${1:-}" mode="${2:-}" var rel seams
  case "${dir%/}" in
    ''|/|"${HOME%/}") echo "suite-isolation: refusing to point the seams at '$dir'." >&2; return 2 ;;
  esac
  case "$mode" in
    every|unset) ;;
    *) echo "suite-isolation: mode '$mode' is neither every nor unset." >&2; return 2 ;;
  esac
  # Read into a variable first, never through a process substitution: bash 3.2 can drop what the
  # caller prints next when a child its shell never waits for exits (#1984, #2040).
  seams="$(suite_isolation_seams)"
  # Each seam is set by its own name, written out, never printf -v "$var": a name bound through a
  # variable cannot be read without running this file, so the Slack drafts gate lost track of every
  # variable in every suite once it sourced this (claude-config#2465). Where each one points stays
  # in the list above; a seam listed there with no line here is refused, never skipped.
  local at
  while read -r var rel; do
    [ "$mode" = unset ] && [ -n "${!var:-}" ] && continue
    at="${dir%/}/$rel"
    case "$var" in
      CLAUDE_ISSUE_SPOOL_DIR) export CLAUDE_ISSUE_SPOOL_DIR="$at" ;;
      PUSH_GATE_LEDGER_DIR) export PUSH_GATE_LEDGER_DIR="$at" ;;
      WRAPPED_REFUSAL_LEDGER_DIR) export WRAPPED_REFUSAL_LEDGER_DIR="$at" ;;
      MT_SIGNIN_LEDGER_DIR) export MT_SIGNIN_LEDGER_DIR="$at" ;;
      MWR_PHASE_DIR) export MWR_PHASE_DIR="$at" ;;
      SYNC_LOG_FILE) export SYNC_LOG_FILE="$at" ;;
      CLAUDE_SLEEP_RECORD) export CLAUDE_SLEEP_RECORD="$at" ;;
      *) echo "suite-isolation: the seam $var is listed but suite_isolate has no line setting it." >&2; return 2 ;;
    esac
  done <<< "$seams"
  if [ "$mode" = every ] || [ -z "${SYNC_CLAUDE_BIN:-}" ]; then
    suite_isolation_no_claude
  fi
  return 0
}
