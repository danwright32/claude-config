#!/usr/bin/env bash
# claude-sync's daily removal of leftovers (claude-config#3235): the launch agent that runs the two
# keep rules Dan set on 2026-11-18 (lib/keep_rules.py), the record of each run, and how a failed or
# missed run reaches him. He chose "By itself, with a log": a clean run says nothing anywhere, a
# failed run posts a notification, and a missed or failed run is said by `claude-sync stuck`, which
# the per prompt sync-stuck-notice.sh puts in front of him.
#
# Everything runs as a planted Mac: HOME is a throwaway inside WORK, CLAUDE_HOME its own ~/.claude,
# launchctl a stub that keeps its own table, and the notifier a stub that writes what it was asked
# to post. Ages are written into the records, never waited for.
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
check(){ local name="$1"; shift; if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi; }
has(){ grep -qF -- "$2" <<< "$1"; }
lacks(){ ! grep -qF -- "$2" <<< "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sync-leftovers.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"
case "$WORK" in /*) ;; *) echo "FAIL: WORK is not an absolute path. Refusing to run."; exit 1 ;; esac

REAL_AGENTS="$HOME/Library/LaunchAgents"
real_agents(){ local f; for f in "$REAL_AGENTS"/com.claudesync.*.plist; do [ -f "$f" ] && printf '%s %s\n' "$f" "$(cksum < "$f")"; done; true; }
REAL_BEFORE="$(real_agents)"

STUBS="$WORK/bin"; mkdir -p "$STUBS"
LOADED="$WORK/loaded"; NOTIFIED="$WORK/notified"
cat > "$STUBS/launchctl" <<STUB
#!/bin/bash
touch "$LOADED"
case "\$1" in
  load)   l="\$(basename "\$2" .plist)"; grep -qxF "\$l" "$LOADED" || printf '%s\n' "\$l" >> "$LOADED" ;;
  unload) grep -vxF "\$(basename "\$2" .plist)" "$LOADED" > "$LOADED.tmp"; mv "$LOADED.tmp" "$LOADED" ;;
  list)   printf 'PID\tStatus\tLabel\n'; while IFS= read -r l; do printf -- '-\t0\t%s\n' "\$l"; done < "$LOADED" ;;
esac
exit 0
STUB
cat > "$STUBS/notifier" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$NOTIFIED"
STUB
chmod +x "$STUBS/launchctl" "$STUBS/notifier"
RUNPATH="$STUBS:$PATH"
if [ "$(PATH="$RUNPATH" command -v launchctl)" != "$STUBS/launchctl" ]; then
  echo "FAIL: the stub launchctl is not the one on PATH, so this suite would reach the real launchd. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
FSWATCH="$WORK/fswatch"; printf '#!/bin/bash\ntrue\n' > "$FSWATCH"; chmod +x "$FSWATCH"

export SYNC_PS_FIXTURE="$WORK/ps-none"; : > "$SYNC_PS_FIXTURE"
export SYNC_SCRATCH_ROOT="$WORK/scratch-root"; mkdir -p "$SYNC_SCRATCH_ROOT"
export SYNC_MANAGED_SETTINGS="$WORK/managed-settings.json"
printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"
export SYNC_CLAUDE_BIN="$WORK/no-such-claude" SYNC_GH="$WORK/no-such-gh" SYNC_RTK_BIN="$WORK/no-such-rtk"
export SYNC_NO_HOOK_TESTS=1
export SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e

FAKEHOME=""; OWN=""; AGENTS=""; CLONE=""
plant(){
  FAKEHOME="$WORK/$1"; OWN="$FAKEHOME/.claude"; AGENTS="$FAKEHOME/Library/LaunchAgents"
  mkdir -p "$OWN/state/sessions" "$AGENTS"
  local bare="$WORK/$1-remote.git"; git init -q --bare -b main "$bare"
  CLONE="$WORK/$1-clone"; git clone -q "$bare" "$CLONE" 2>/dev/null
  git -C "$CLONE" checkout -q -b main 2>/dev/null
  printf 'seed\n' > "$CLONE/README"; git -C "$CLONE" add README
  git -C "$CLONE" commit -q -m seed; git -C "$CLONE" push -q -u origin main 2>/dev/null
  : > "$LOADED"; : > "$NOTIFIED"
}
run(){   # $1 = command, then its arguments
  local cmd="$1"; shift
  env -u SYNC_LAUNCHAGENTS -u SYNC_NO_LAUNCHCTL -u SYNC_CLONE_REGISTRY -u SYNC_ZSHRC -u SYNC_HOLD_FILE \
    -u SYNC_WATCH_PID_FILE -u SYNC_LOG_FILE -u SYNC_RETIRED_FILE \
    HOME="$FAKEHOME" PATH="$RUNPATH" CLAUDE_HOME="$OWN" SYNC_REPO="$CLONE" SYNC_FSWATCH="$FSWATCH" \
    SYNC_NO_NOTIFY=0 SYNC_NOTIFIER="$STUBS/notifier" CLAUDE_SUITE_RUN_ID= bash "$SCRIPT" "$cmd" "$@" 2>&1
}
rec(){ mkdir -p "$OWN/state/keep-rules"; printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" > "$OWN/state/keep-rules/last-run"; }
NOW="$(date +%s)"
LEFT="com.claudesync.leftovers"

# ==== 1. install-autosync writes the daily agent beside the two sync agents ====
plant mac-a
out="$(run status)"
check "not installed: status says so and names the installer" has "$out" "removal of leftovers: not installed"
out="$(run install-autosync)"
check "install-autosync: writes the leftovers agent" test -f "$AGENTS/$LEFT.plist"
check "install-autosync: the agent runs remove-leftovers" grep -q '<string>remove-leftovers</string>' "$AGENTS/$LEFT.plist"
check "install-autosync: once a day" grep -q '<key>StartInterval</key><integer>86400</integer>' "$AGENTS/$LEFT.plist"
check "install-autosync: loads it" grep -qxF "$LEFT" "$LOADED"
check "install-autosync: says it installed it" has "$out" "Installed the daily removal of leftovers"

# ==== 2. a missing agent where the sync agents are installed is said by stuck ====
rm -f "$AGENTS/$LEFT.plist"
out="$(run stuck)"
check "stuck: a Mac with the sync agents but no leftovers agent is told" has "$out" "leftovers-not-installed	"
check "stuck: and told how to install it" has "$out" "claude-sync install-autosync"
out="$(run install-autosync)"

# ==== 3. a clean run posts nothing and records ok ====
out="$(run remove-leftovers)"; rc=$?
check "clean run: exits 0" test "$rc" -eq 0
check "clean run: posts no notification" test ! -s "$NOTIFIED"
check "clean run: records ok" grep -q '	ok	0	0	-$' "$OWN/state/keep-rules/last-run"
out="$(run stuck)"
check "clean run: stuck says nothing about leftovers" lacks "$out" "leftovers"
out="$(run status)"
check "clean run: status says when it last ran and what it removed" has "$out" "removal of leftovers: installed, last ran"

# ==== 4. a failed run posts once, records failed, and stuck says it ====
mkdir -p "$OWN/state/session-notes/-p/22222222-2222-4222-8222-222222222222"
printf 'note\n' > "$OWN/state/session-notes/-p/22222222-2222-4222-8222-222222222222/handoff.md"
rm -rf "$OWN/state/sessions"
out="$(run remove-leftovers)"; rc=$?
check "failed run: exits 1" test "$rc" -eq 1
check "failed run: posts one notification" test "$(wc -l < "$NOTIFIED" | tr -d ' ')" = 1
check "failed run: the notification says what failed and where the log is" grep -q 'session registry.*removed.log' "$NOTIFIED"
check "failed run: records failed" grep -q '	failed	' "$OWN/state/keep-rules/last-run"
out="$(run stuck)"
check "failed run: stuck says it" has "$out" "leftovers-failed	"
check "failed run: a written note was left alone" test -f "$OWN/state/session-notes/-p/22222222-2222-4222-8222-222222222222/handoff.md"
mkdir -p "$OWN/state/sessions"

# ==== 5. a missed run is noticed ====
rec "$(( NOW - 3 * 86400 ))" ok 0 0 -
out="$(run stuck)"
check "missed: a last run three days old is overdue" has "$out" "leftovers-overdue	"
rec "$(( NOW - 3600 ))" ok 0 0 -
out="$(run stuck)"
check "missed: an hour old is not" lacks "$out" "leftovers-overdue"
rm -f "$OWN/state/keep-rules/last-run"
python3 -c 'import os,sys; t=float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$AGENTS/$LEFT.plist" "$(( NOW - 3 * 86400 ))"
out="$(run stuck)"
check "missed: installed three days ago and never run is overdue" has "$out" "never finished a run"
printf 'garbage\n' > "$OWN/state/keep-rules/last-run"
out="$(run stuck)"
check "missed: an unreadable record is said, not read as fine" has "$out" "leftovers-unreadable	"

# ==== 6. switched off on this Mac ====
rec "$(( NOW - 3 * 86400 ))" ok 0 0 -
: > "$NOTIFIED"
touch "$OWN/state/keep-rules/off"
out="$(run remove-leftovers)"; rc=$?
check "off: exits 0 and says it is off" test "$rc" -eq 0
check "off: says so" has "$out" "switched off on this Mac"
check "off: posts nothing" test ! -s "$NOTIFIED"
out="$(run stuck)"
check "off: stuck says nothing about leftovers" lacks "$out" "leftovers"
out="$(run status)"
check "off: status says it is switched off and how to switch it back on" has "$out" "switched off on this Mac"
rm -f "$OWN/state/keep-rules/off"

# ==== 7. the dry run writes nothing ====
plant mac-b
out="$(run leftovers)"; rc=$?
check "leftovers: exits 0" test "$rc" -eq 0
check "leftovers: prints the would-remove report" has "$out" "WOULD REMOVE:"
check "leftovers: writes no state" test ! -e "$OWN/state/keep-rules"

check "the real launch agents on this Mac were not touched" test "$REAL_BEFORE" = "$(real_agents)"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
