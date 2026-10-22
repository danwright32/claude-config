#!/usr/bin/env bash
# claude-sync run against a fixture CLAUDE_HOME writes, loads, restarts and removes nothing on the
# real Mac (claude-config#1470), and appends nothing to its sync log (claude-config#1486).
#
# #1453 gave the READS of the launch agents and the clone register one rule: the seam when one is
# named, the real location only when CLAUDE_HOME is this user's own ~/.claude, and nothing for any
# other home. The WRITES kept their old defaults, so a fixture run that forgot SYNC_LAUNCHAGENTS,
# SYNC_NO_LAUNCHCTL or SYNC_CLONE_REGISTRY rewrote the real launch agents, loaded them into the
# real launchd, restarted the real watch daemon, retired real agents, appended to the real clone
# register or removed a line from it. Every one of those now follows the same rule, and launchctl,
# which only ever acts on THIS Mac's launchd whatever plist it is handed, runs only for this user's
# own config.
#
# The proof plants a "real" Mac in a throwaway HOME: launch agents (the two current ones and the
# two retired ones install-autosync removes), a clone register and a shell rc, with a stub launchctl
# first on PATH that records every call. Each write path runs under a fixture home and must leave
# the plant exactly as it was and call no launchctl, saying so. Then the same paths run AS that
# home's own config and must change it, so the plant is shown to be reachable before its staying
# untouched is taken to mean anything (L1, L98).
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
same(){ [ "$1" = "$2" ]; }
differs(){ [ "$1" != "$2" ]; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fixture-home-writes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

# ---- the stub launchctl, proved to be the one that runs before anything can reach the real one ----
# Everything below that is ABOUT launchctl would otherwise unload and load the planted plists into
# this Mac's real launchd, whose labels are the real agents' labels. So the suite refuses to run at
# all unless the stub is what the name resolves to.
STUBS="$WORK/bin"; mkdir -p "$STUBS"
LCLOG="$WORK/launchctl.log"; : > "$LCLOG"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$LCLOG" > "$STUBS/launchctl"
chmod +x "$STUBS/launchctl"
RUNPATH="$STUBS:$PATH"
if [ "$(PATH="$RUNPATH" command -v launchctl)" != "$STUBS/launchctl" ]; then
  echo "FAIL: the stub launchctl is not the one on PATH, so this suite would reach the real launchd. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# Everything else these commands read or write about the machine, inside WORK.
export SYNC_PS_FIXTURE="$WORK/ps-none"; : > "$SYNC_PS_FIXTURE"
export SYNC_SCRATCH_ROOT="$WORK/scratch-root"; mkdir -p "$SYNC_SCRATCH_ROOT"
export SYNC_MANAGED_SETTINGS="$WORK/managed-settings.json"
printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"
export SYNC_CLAUDE_BIN="$WORK/no-such-claude"
export SYNC_GH="$WORK/no-such-gh"
export SYNC_RTK_BIN="$WORK/no-such-rtk"
export SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1
export SYNC_LOG_FILE="$WORK/sync-log"
# Every path here is under the temp directory, and a clone there is never registered (#295), so the
# register would be left alone for that reason rather than the one under test (L322).
export SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here"
FSWATCH="$WORK/fswatch"; printf '#!/bin/bash\ntrue\n' > "$FSWATCH"; chmod +x "$FSWATCH"

# ---- the planted "real" Mac ----
FAKEHOME="$WORK/home"
AGENTS="$FAKEHOME/Library/LaunchAgents"
REGISTER="$FAKEHOME/.claude-sync-clones"
ZSHRC="$FAKEHOME/.zshrc"
HOLD="$FAKEHOME/.claude-sync-hold"
PIDFILE="$FAKEHOME/.claude-sync-watch.pid"
SYNCLOG="$FAKEHOME/.claude-sync.log"
PLANTED_CLONE="$WORK/planted-clone"
# Planted afresh before every scenario, so each one is judged on its own: a write one scenario let
# through must never be what fails the next (L203).
replant(){
  rm -rf "$FAKEHOME"
  mkdir -p "$AGENTS" "$FAKEHOME/.claude"
  local label
  for label in com.claudesync.timer com.claudesync.watch com.claudesync.pull com.claudesync.auto; do
    printf 'planted %s\n' "$label" > "$AGENTS/$label.plist"
  done
  printf '%s\n%s\n' "$PLANTED_CLONE" "$WORK/another-planted-clone" > "$REGISTER"
  printf 'export PLANTED=1\n' > "$ZSHRC"
  # The watcher's two markers (claude-config#1470, the coordinator's extension): a hold still in
  # force for a day, and a pid file naming a watcher that has gone, which a watcher replaces.
  printf '%s %s planted-host a planted hold\n' "$(( $(date +%s) + 86400 ))" "$(date +%s)" > "$HOLD"
  printf '999999\n' > "$PIDFILE"
  # The sync log (claude-config#1486): what the scheduled and watch jobs have written so far, which
  # a fixture run must neither append to nor rewrite.
  printf '2026-10-01 09:00:00 claude-sync: a planted line from the real watcher\n' > "$SYNCLOG"
  : > "$LCLOG"
  BEFORE="$(plant)"
}

plant(){   # every file of the planted Mac, with its checksum
  (cd "$FAKEHOME" && find . -type f ! -path './.claude/*' | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(cksum < "$f")"
  done)
}
calls(){ cat "$LCLOG"; }
replant
BEFORE="$(plant)"

FIXHOME="$WORK/fixture-claude"; mkdir -p "$FIXHOME"
# The clone these commands take the lock in. Left to default it is the checkout holding this suite,
# which every locked command would then write into, and which register_this_clone would record. It
# holds no claude-sync, so nothing records it; the pulls name clones of their own.
NOREPO="$WORK/no-repo"; mkdir -p "$NOREPO"
run_as(){   # $1 = CLAUDE_HOME  $2 = command  then extra environment as NAME=value, then -- and args
  local home="$1" cmd="$2"; shift 2
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env -u SYNC_LAUNCHAGENTS -u SYNC_NO_LAUNCHCTL -u SYNC_CLONE_REGISTRY -u SYNC_ZSHRC \
    -u SYNC_HOLD_FILE -u SYNC_WATCH_PID_FILE -u SYNC_LOG_FILE \
    HOME="$FAKEHOME" PATH="$RUNPATH" CLAUDE_HOME="$home" SYNC_REPO="$NOREPO" SYNC_FSWATCH="$FSWATCH" ${extra[@]+"${extra[@]}"} \
    bash "$SCRIPT" "$cmd" "$@" 2>&1
}

# ---- a pull that changes claude-sync itself, which is what restarts the watch daemon ----
# Three clones taken before the change, one per scenario, so each pull receives it.
BARE="$WORK/remote.git"; git init -q --bare -b main "$BARE"
SEED="$WORK/seed"; git clone -q "$BARE" "$SEED" 2>/dev/null
cp "$SCRIPT" "$SEED/claude-sync"
mkdir -p "$SEED/payload/hooks/lib"
cp "$HERE/../payload/hooks/lib/unmanaged-skills.sh" "$SEED/payload/hooks/lib/unmanaged-skills.sh"
printf '#!/bin/sh\n' > "$SEED/payload/hooks/dummy.sh"
git -C "$SEED" add -A
git -C "$SEED" -c user.name=t -c user.email=t@e commit -q -m seed
git -C "$SEED" push -q -u origin main 2>/dev/null
for c in pull-fixture pull-seam pull-own; do git clone -q "$BARE" "$WORK/$c" 2>/dev/null; done
printf '# a harmless comment appended\n' >> "$SEED/claude-sync"
git -C "$SEED" -c user.name=t -c user.email=t@e commit -q -am "edit script"
git -C "$SEED" push -q 2>/dev/null

# ==== 1. a fixture home with no seam writes, loads, restarts and removes nothing ====
out="$(run_as "$FIXHOME" install-schedule)"
check "install-schedule, fixture: the real launch agents are untouched" same "$(plant)" "$BEFORE"
check "install-schedule, fixture: no launchctl call" same "$(calls)" ""
check "install-schedule, fixture: says it was not installed" has "$out" "not this user's own ~/.claude"
check "install-schedule, fixture: names the seam that would take it" has "$out" "SYNC_LAUNCHAGENTS"
check "install-schedule, fixture: does not claim an install" lacks "$out" "Installed monthly auto-pull"

replant
out="$(run_as "$FIXHOME" install-autosync)"
check "install-autosync, fixture: the real launch agents, register and shell rc are untouched" same "$(plant)" "$BEFORE"
check "install-autosync, fixture: no launchctl call" same "$(calls)" ""
check "install-autosync, fixture: says nothing was installed" has "$out" "not this user's own ~/.claude"
check "install-autosync, fixture: names the seam that would take it" has "$out" "SYNC_LAUNCHAGENTS"
check "install-autosync, fixture: does not claim the receive timer" lacks "$out" "Installed receive-timer"
check "install-autosync, fixture: names the seam for the shell rc" has "$out" "SYNC_ZSHRC"

# With no fswatch the watcher's plist is REMOVED, which is the other way it reached the real folder.
replant
out="$(run_as "$FIXHOME" install-autosync SYNC_FSWATCH="$WORK/no-such-fswatch")"
check "install-autosync without fswatch, fixture: the real watch agent is not removed" same "$(plant)" "$BEFORE"
check "install-autosync without fswatch, fixture: no launchctl call" same "$(calls)" ""

replant
out="$(run_as "$FIXHOME" forget-clone -- "$PLANTED_CLONE")"
check "forget-clone, fixture: the real register is untouched" same "$(plant)" "$BEFORE"
check "forget-clone, fixture: says the register was not this run's" has "$out" "not this user's own ~/.claude"
check "forget-clone, fixture: names the seam that would take it" has "$out" "SYNC_CLONE_REGISTRY"
check "forget-clone, fixture: does not claim a removal" lacks "$out" "Removed $PLANTED_CLONE"

replant
out="$(run_as "$FIXHOME" pull SYNC_REPO="$WORK/pull-fixture")"
check "pull, fixture: the script change was received" has "$out" "watch daemon"
check "pull, fixture: the real watch daemon is not restarted" same "$(calls)" ""
check "pull, fixture: says why it was left alone" has "$out" "not this user's own ~/.claude"
check "pull, fixture: this clone is not added to the real register" same "$(plant)" "$BEFORE"

# The watcher's markers: hold writes one, release removes one, and watch claims the pid file,
# replacing one whose watcher has gone, then removes it on the way out.
replant
out="$(run_as "$FIXHOME" hold -- 5 a fixture hold)"
check "hold, fixture: the real hold marker is untouched" same "$(plant)" "$BEFORE"
check "hold, fixture: says no hold was taken, and why" has "$out" "not this user's own ~/.claude"
check "hold, fixture: names the seam that would take it" has "$out" "SYNC_HOLD_FILE"
replant
out="$(run_as "$FIXHOME" release)"
check "release, fixture: the real hold marker is not removed" same "$(plant)" "$BEFORE"
check "release, fixture: says nothing was released, and why" has "$out" "not this user's own ~/.claude"
check "release, fixture: does not claim a release" lacks "$out" "Watcher hold released"
replant
out="$(run_as "$FIXHOME" watch SYNC_WATCH_SEND=true)"
check "watch, fixture: the real pid file is untouched" same "$(plant)" "$BEFORE"
check "watch, fixture: says it is recorded nowhere, and why" has "$out" "not this user's own ~/.claude"
check "watch, fixture: names the seam that would record it" has "$out" "SYNC_WATCH_PID_FILE"
replant
SEAMHOLD="$WORK/seam-hold"; rm -f "$SEAMHOLD"
out="$(run_as "$FIXHOME" hold SYNC_HOLD_FILE="$SEAMHOLD" -- 5 a seam hold)"
check "hold, seam: written where SYNC_HOLD_FILE names" grep -q 'a seam hold' "$SEAMHOLD"
check "hold, seam: the real Mac is untouched" same "$(plant)" "$BEFORE"

# ==== 1b. the sync log: a fixture home with no SYNC_LOG_FILE writes nothing to the real one ====
# (claude-config#1486.) Every line claude-sync appends itself goes through sync_log_line, and two of
# its callers are reachable without a working clone: notify while the Mac is asleep, which logs what
# it would have shown (any command that dies off a terminal reaches it), and a push whose
# settings.json cannot be read, which logs that the hooks block was held back. Each runs under a
# fixture home that is asleep, so both callers fire, and the planted log must stay byte for byte as
# it was. A home of its own, so the unreadable settings.json reaches no other scenario.
SLEEPLIB="$HERE/../payload/hooks/lib/sleep.sh"
BOOT="$(bash -c '. "$1" && sleep_boot_of "$(sysctl -n kern.boottime 2>/dev/null)"' _ "$SLEEPLIB")"
[ -n "$BOOT" ] || BOOT=1   # no sysctl (Linux CI): sleep.sh skips the boot check, so any boot will do
asleep(){   # $1 = a CLAUDE_HOME, which is then asleep for the next hour
  local now_ms; now_ms="$(( $(date +%s) * 1000 ))"
  mkdir -p "$1/state/sleep"
  printf '{"v":1,"generation":"g-1486","since":%s,"until":%s,"night":"2026-10-22","bootTime":%s,"report":"%s/r.md","startedBy":{"sessionId":"s0","cwd":"/"},"workers":[],"placeBefore":"home"}\n' \
    "$((now_ms - 60000))" "$((now_ms + 3600000))" "$BOOT" "$WORK" > "$1/state/sleep/current.json"
}
LOGHOME="$WORK/fixture-log-claude"; mkdir -p "$LOGHOME"; asleep "$LOGHOME"
printf '{ not json\n' > "$LOGHOME/settings.json"
# Something to publish that the secret scan refuses, so a push logs twice: the held back block,
# then the scan's death, which while asleep is logged rather than shown. The key is built here, so
# this file holds none for any scanner to find.
mkdir -p "$LOGHOME/agents"
printf '# a fixture agent\nkey: AKIA%s\n' "$(printf '%016d' 0)" > "$LOGHOME/agents/fixture-agent.md"
LOGBARE="$WORK/log-remote.git"; git init -q --bare "$LOGBARE"
for c in log-fixture log-seam log-own; do git clone -q "$LOGBARE" "$WORK/$c" 2>/dev/null; done
NOTIFYING=(SYNC_NO_NOTIFY=0 SYNC_NOTIFIER="$WORK/no-such-notifier")
LOGNOTE="writes nothing to the sync log"

# The seam first, which also proves both callers really log from such a run: without that, the
# planted log staying put below could mean only that nothing was ever logged (L98).
SEAMLOG="$WORK/seam-sync-log"; : > "$SEAMLOG"
out="$(run_as "$LOGHOME" no-such-command-1486 "${NOTIFYING[@]}" SYNC_LOG_FILE="$SEAMLOG")"
check "a death while asleep, seam: logged where SYNC_LOG_FILE names" grep -q 'not shown, Dan is asleep: .*no-such-command-1486' "$SEAMLOG"
PUSHSEAMLOG="$WORK/seam-sync-log-push"; : > "$PUSHSEAMLOG"
out="$(run_as "$LOGHOME" push "${NOTIFYING[@]}" SYNC_REPO="$WORK/log-seam" SYNC_LOG_FILE="$PUSHSEAMLOG")"
check "a held back hooks block, seam: logged where SYNC_LOG_FILE names" grep -q 'hooks block was NOT published' "$PUSHSEAMLOG"
check "the seam runs say nothing about an unwritten log" lacks "$out" "$LOGNOTE"

replant
out="$(run_as "$LOGHOME" no-such-command-1486 "${NOTIFYING[@]}")"
check "a death while asleep, fixture: the real sync log is untouched" same "$(plant)" "$BEFORE"
check "a death while asleep, fixture: says the line went nowhere, and why" has "$out" "$LOGNOTE"
check "a death while asleep, fixture: names the seam that would keep it" has "$out" "SYNC_LOG_FILE"
check "a death while asleep, fixture: and the reason is the home" has "$out" "not this user's own ~/.claude"

replant
out="$(run_as "$LOGHOME" push "${NOTIFYING[@]}" SYNC_REPO="$WORK/log-fixture")"
check "a held back hooks block, fixture: the push did hold it back" has "$out" "hooks block was NOT published"
check "a held back hooks block, fixture: the real sync log is untouched" same "$(plant)" "$BEFORE"
check "a held back hooks block, fixture: says the line went nowhere" has "$out" "$LOGNOTE"
# Said ONCE however many lines the run would have logged, so it reads as a fact about the run
# rather than a second copy of every line. This push logs two (the block, then its death while
# asleep), counted in the seam log above, so one note is the claim and not the only possibility.
check "the push under the seam logged more than one line, so the count below means something" \
  test "$(grep -c ' claude-sync: ' "$PUSHSEAMLOG")" -ge 2
[ "$(grep -c ' claude-sync: ' "$PUSHSEAMLOG")" -ge 2 ] || printf '  the seam push logged:\n%s\n  the fixture push said:\n%s\n' "$(cat "$PUSHSEAMLOG")" "$out"
check "a held back hooks block, fixture: says it once" same "$(grep -cF "$LOGNOTE" <<< "$out")" 1

# ==== 2. the seams still take the writes under a fixture home, and launchctl still never runs ====
replant
SEAMAGENTS="$WORK/seam-agents"
out="$(run_as "$FIXHOME" install-autosync SYNC_LAUNCHAGENTS="$SEAMAGENTS" SYNC_ZSHRC="$WORK/seam-zshrc")"
check "install-autosync, seam: the timer is written where SYNC_LAUNCHAGENTS names" grep -q 'com.claudesync.timer' "$SEAMAGENTS/com.claudesync.timer.plist"
check "install-autosync, seam: the watcher is written there too" grep -q 'com.claudesync.watch' "$SEAMAGENTS/com.claudesync.watch.plist"
check "install-autosync, seam: the alias goes to SYNC_ZSHRC" grep -q 'alias claudesync=' "$WORK/seam-zshrc"
check "install-autosync, seam: the real Mac is untouched" same "$(plant)" "$BEFORE"
check "install-autosync, seam: a fixture plist is never loaded into the real launchd" same "$(calls)" ""
check "install-autosync, seam: says launchctl was not run" has "$out" "not this user's own ~/.claude"

replant
out="$(run_as "$FIXHOME" install-schedule SYNC_LAUNCHAGENTS="$SEAMAGENTS")"
check "install-schedule, seam: written where SYNC_LAUNCHAGENTS names" grep -q 'com.claudesync.pull' "$SEAMAGENTS/com.claudesync.pull.plist"
check "install-schedule, seam: never loaded into the real launchd" same "$(calls)" ""

replant
SEAMREG="$WORK/seam-register"; printf '%s\n' "$PLANTED_CLONE" > "$SEAMREG"
out="$(run_as "$FIXHOME" forget-clone SYNC_CLONE_REGISTRY="$SEAMREG" -- "$PLANTED_CLONE")"
check "forget-clone, seam: removes the entry from SYNC_CLONE_REGISTRY" same "$(cat "$SEAMREG")" ""
check "forget-clone, seam: the real register is untouched" same "$(plant)" "$BEFORE"

replant
# Its own agents folder holding only a watcher, as an installed one would: the one install-autosync
# wrote above names this checkout's claude-sync, and a pull reading it would go and fetch in it.
PULLAGENTS="$WORK/seam-agents-pull"; mkdir -p "$PULLAGENTS"; : > "$PULLAGENTS/com.claudesync.watch.plist"
out="$(run_as "$FIXHOME" pull SYNC_REPO="$WORK/pull-seam" SYNC_LAUNCHAGENTS="$PULLAGENTS" SYNC_CLONE_REGISTRY="$SEAMREG")"
check "pull, seam: the watch daemon a fixture names is still not restarted for real" same "$(calls)" ""
check "pull, seam: says why" has "$out" "not this user's own ~/.claude"
check "pull, seam: the clone is recorded in SYNC_CLONE_REGISTRY" grep -qxF "$WORK/pull-seam" "$SEAMREG"
check "pull, seam: the real Mac is untouched" same "$(plant)" "$BEFORE"

# ==== 3. control: the same commands AS the planted home's own config do reach it ====
replant
OWN="$FAKEHOME/.claude"
# Under the runner a pull refuses to apply into HOME/.claude at all (CLAUDE_SUITE_RUN_ID), since
# there it would be the real config. Here HOME is the planted throwaway inside WORK, so that one
# refusal is lifted for this one call; without it the control pull dies before the restart and
# proves nothing (seen in the full run).
case "$OWN" in "$WORK"/*) ;; *) echo "FAIL: the control home is not inside WORK. Refusing to run it."; exit 1 ;; esac
out="$(run_as "$OWN" pull SYNC_REPO="$WORK/pull-own" CLAUDE_SUITE_RUN_ID=)"
check "control pull: restarts the watch daemon" grep -q 'kickstart -k gui/.*/com.claudesync.watch' "$LCLOG"
grep -q 'kickstart' "$LCLOG" || printf '  the control pull said:\n%s\n  launchctl saw:\n%s\n' "$out" "$(calls)"
check "control pull: records this clone in the register" grep -qxF "$WORK/pull-own" "$REGISTER"

: > "$LCLOG"
out="$(run_as "$OWN" install-schedule)"
check "control install-schedule: rewrites the real agent" grep -q '<string>com.claudesync.pull</string>' "$AGENTS/com.claudesync.pull.plist"
check "control install-schedule: loads it" grep -q "^load $AGENTS/com.claudesync.pull.plist" "$LCLOG"

: > "$LCLOG"
out="$(run_as "$OWN" install-autosync)"
check "control install-autosync: writes the real timer" grep -q '<string>com.claudesync.timer</string>' "$AGENTS/com.claudesync.timer.plist"
check "control install-autosync: retires the old monthly pull" test ! -e "$AGENTS/com.claudesync.pull.plist"
check "control install-autosync: retires the old auto agent" test ! -e "$AGENTS/com.claudesync.auto.plist"
check "control install-autosync: loads the timer" grep -q "^load $AGENTS/com.claudesync.timer.plist" "$LCLOG"
check "control install-autosync: installs the alias in the real shell rc" grep -q 'alias claudesync=' "$ZSHRC"

: > "$LCLOG"
out="$(run_as "$OWN" install-autosync SYNC_NO_LAUNCHCTL=1)"
check "control with SYNC_NO_LAUNCHCTL=1: still no launchctl call" same "$(calls)" ""

out="$(run_as "$OWN" forget-clone -- "$PLANTED_CLONE")"
check "control forget-clone: removes the entry from the real register" lacks "$(cat "$REGISTER")" "$PLANTED_CLONE"
check "control forget-clone: says so" has "$out" "Removed $PLANTED_CLONE"

out="$(run_as "$OWN" watch SYNC_WATCH_SEND=true)"
check "control watch: replaces the real pid file whose watcher has gone" lacks "$(cat "$PIDFILE" 2>/dev/null)" "999999"
out="$(run_as "$OWN" hold -- 5 a control hold)"
check "control hold: writes the real hold marker" grep -q 'a control hold' "$HOLD"
out="$(run_as "$OWN" release)"
check "control release: removes the real hold marker" test ! -e "$HOLD"

# The sync log, appended to exactly as before for this user's own config, its earlier lines kept.
replant
asleep "$OWN"; printf '{ not json\n' > "$OWN/settings.json"
out="$(run_as "$OWN" no-such-command-1486 "${NOTIFYING[@]}")"
check "control death while asleep: appended to the real sync log" grep -q 'not shown, Dan is asleep: .*no-such-command-1486' "$SYNCLOG"
check "control death while asleep: the real log's earlier lines are kept" grep -q 'a planted line from the real watcher' "$SYNCLOG"
check "control death while asleep: says nothing about an unwritten log" lacks "$out" "$LOGNOTE"
out="$(run_as "$OWN" push "${NOTIFYING[@]}" SYNC_REPO="$WORK/log-own" CLAUDE_SUITE_RUN_ID=)"
check "control push: the held back hooks block is appended to the real sync log" grep -q 'hooks block was NOT published' "$SYNCLOG"
check "control push: still the first line first" same "$(head -1 "$SYNCLOG")" "2026-10-01 09:00:00 claude-sync: a planted line from the real watcher"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
