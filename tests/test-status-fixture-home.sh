#!/usr/bin/env bash
# `claude-sync status` against a fixture CLAUDE_HOME reads no real clone record and no real launch
# agent (claude-config#1453).
#
# status reads two things that belong to the machine rather than to the config it is pointed at:
# the launch agents (which jobs run, and which clone each one runs from) and the register of clones,
# and from every clone those two name it reads that clone's hook suite record, which can name
# suites by file. A suite running status against its own throwaway CLAUDE_HOME therefore reported
# on whatever the Mac it ran on happened to hold: a stale failure in the scheduled clone, or a suite
# named in that clone's record, landed in the fixture's output and decided checks that had nothing
# to do with it (the same fault #1445 met in the process table, L2, L463).
#
# Both reads now follow the rule rtk_sync_bin already follows: the seam (SYNC_LAUNCHAGENTS,
# SYNC_CLONE_REGISTRY) when one is named, and otherwise the real location ONLY when CLAUDE_HOME is
# this user's own ~/.claude. A fixture home with no seam reads neither.
#
# The proof plants a "real" machine: a throwaway HOME holding a launch agent that names one clone
# and a register naming another, each with a hook suite record a fixture must never repeat. The
# control runs status AS that home's own config and must read both, so the plant is shown to be
# visible before its absence is taken to mean anything (L1, L98).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-sync"
. "$HERE/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){   # $1 = name  $2.. = a command that succeeds when the check holds
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
has(){ grep -qF -- "$2" <<< "$1"; }
lacks(){ ! grep -qF -- "$2" <<< "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/status-fixture-home.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# other_sync_clones compares directories by pwd -P, so every path a check looks for is the resolved
# one (macOS reaches the temp directory through /var, which is a link to /private/var).
WORK="$(cd "$WORK" && pwd -P)"

# Everything else status reads from the machine, pointed inside WORK, so the only machine state
# this suite leaves real is the one it plants.
export SYNC_PS_FIXTURE="$WORK/ps-none"; : > "$SYNC_PS_FIXTURE"
export SYNC_SCRATCH_ROOT="$WORK/scratch-root"; mkdir -p "$SYNC_SCRATCH_ROOT"
export SYNC_MANAGED_SETTINGS="$WORK/managed-settings.json"
printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"
export SYNC_CLAUDE_BIN="$WORK/no-such-claude"
export SYNC_GH="$WORK/no-such-gh"
export SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1
# Every path here sits under the temp directory, and a registered clone under it is dropped as
# disposable (claude-config#295), so the planted register would be read as empty for that reason
# rather than for the one under test (L322).
export SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here"

# ---- the planted "real" machine ----
FAKEHOME="$WORK/home"
AGENTS="$FAKEHOME/Library/LaunchAgents"
REGISTER="$FAKEHOME/.claude-sync-clones"
mkdir -p "$AGENTS" "$FAKEHOME/.claude"
now="$(date +%s)"

# The clone a launch agent runs from, holding a FAILED record.
AGENT_CLONE="$WORK/scheduled-clone"
mkdir -p "$AGENT_CLONE"
: > "$AGENT_CLONE/claude-sync"
printf 'outcome=failed\tat=%s\texit=1\tran=9\tnotrun=0\tseconds=5\tnotrun_names=\n' "$now" > "$AGENT_CLONE/.hook-tests"
cat > "$AGENTS/com.claudesync.timer.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.claudesync.timer</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$AGENT_CLONE/claude-sync</string><string>pull</string></array>
  <key>StartInterval</key><integer>3600</integer>
</dict></plist>
PL

# A clone only the register names, holding a PASSED record that names a suite which could not run.
REG_CLONE="$WORK/registered-clone"
mkdir -p "$REG_CLONE"
: > "$REG_CLONE/claude-sync"
printf 'outcome=passed\tat=%s\texit=0\tran=9\tnotrun=1\tseconds=5\tnotrun_names=test-planted-real-suite.sh\n' "$now" > "$REG_CLONE/.hook-tests"
printf '%s\n' "$REG_CLONE" > "$REGISTER"

REPO="$WORK/repo"; mkdir -p "$REPO/payload"
FIXHOME="$WORK/fixture-home"; mkdir -p "$FIXHOME"

status_as(){   # $1 = CLAUDE_HOME, any further arguments are extra environment
  local home="$1"; shift
  env -u SYNC_LAUNCHAGENTS -u SYNC_CLONE_REGISTRY HOME="$FAKEHOME" CLAUDE_HOME="$home" SYNC_REPO="$REPO" "$@" bash "$SCRIPT" status 2>&1
}

# ---- 1. control: status run AS the planted home's own config reads both ----
own="$(status_as "$FAKEHOME/.claude")"
check "control: the launch agent's clone and its failed record are read" has "$own" "recorded by another clone on this Mac, $AGENT_CLONE"
check "control: the registered clone and the suite its record names are read" has "$own" "test-planted-real-suite.sh"
check "control: the launch agent itself is reported" has "$own" "receive timer: every"

# ---- 2. a fixture home with no seam reads neither ----
fix="$(status_as "$FIXHOME")"
check "fixture: no clone a real launch agent names" lacks "$fix" "$AGENT_CLONE"
check "fixture: no clone the real register names" lacks "$fix" "$REG_CLONE"
check "fixture: no suite named by a real clone's record" lacks "$fix" "test-planted-real-suite.sh"
check "fixture: no real launch agent reported" lacks "$fix" "receive timer: every"
# Not read is said as not read. Reporting the agents as absent would be a statement about this Mac
# made without looking at it (L11).
check "fixture: says the launch agents were not read, rather than that none is installed" lacks "$fix" "neither launch agent is installed"
check "fixture: names the seam that reads them" has "$fix" "SYNC_LAUNCHAGENTS"

# ---- 3. the seams still read what they name under a fixture home ----
seam="$(status_as "$FIXHOME" SYNC_LAUNCHAGENTS="$AGENTS" SYNC_CLONE_REGISTRY="$REGISTER")"
check "seam: SYNC_LAUNCHAGENTS names the agents a fixture reads" has "$seam" "recorded by another clone on this Mac, $AGENT_CLONE"
check "seam: SYNC_CLONE_REGISTRY names the register a fixture reads" has "$seam" "test-planted-real-suite.sh"
check "seam: the named launch agent is reported" has "$seam" "receive timer: every"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
