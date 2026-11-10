#!/usr/bin/env bash
# claude-sync retire takes a Mac out of the sync (claude-config#2545).
#
# A Mac being cleared for trade in kept com.claudesync.watch and com.claudesync.timer running, so
# every file deleted from its ~/.claude by hand was sent on as a change to the shared config and
# removed from every other Mac. retire is the inverse of install-autosync: it records the Mac as
# retired, unloads and removes both agents, and reads launchd back to confirm neither is loaded.
#
# Everything runs as a planted Mac: HOME is a throwaway inside WORK and CLAUDE_HOME is its own
# ~/.claude, so claude-sync treats it as the user's own config and calls launchctl, which here is a
# stub that keeps its own table of loaded jobs. The suite refuses to run unless the stub is what the
# name resolves to, and checks at the end that the real agents on this Mac were not touched.
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sync-retire.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

# ---- the real agents on this Mac, read (never changed) so the end of the suite can compare ----
REAL_AGENTS="$HOME/Library/LaunchAgents"
real_agents(){ local f; for f in "$REAL_AGENTS"/com.claudesync.*.plist; do [ -f "$f" ] && printf '%s %s\n' "$f" "$(cksum < "$f")"; done; true; }
REAL_BEFORE="$(real_agents)"

# ---- the stub launchctl: it logs every call and keeps a table of what is loaded ----
# STUCK makes unload and remove do nothing while still exiting 0, which is what a job launchd will
# not let go of looks like from an exit code. LISTFAIL makes list itself fail.
STUBS="$WORK/bin"; mkdir -p "$STUBS"
LCLOG="$WORK/launchctl.log"; LOADED="$WORK/loaded"; STUCK="$WORK/stuck"; LISTFAIL="$WORK/listfail"
cat > "$STUBS/launchctl" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$LCLOG"
touch "$LOADED"
drop(){ grep -vxF "\$1" "$LOADED" > "$LOADED.tmp"; mv "$LOADED.tmp" "$LOADED"; }
case "\$1" in
  load)   l="\$(basename "\$2" .plist)"; grep -qxF "\$l" "$LOADED" || printf '%s\n' "\$l" >> "$LOADED" ;;
  unload) [ -f "$STUCK" ] || drop "\$(basename "\$2" .plist)" ;;
  remove) [ -f "$STUCK" ] || drop "\$2" ;;
  bootout) [ -f "$STUCK" ] || drop "\${2##*/}" ;;
  list)
    [ -f "$LISTFAIL" ] && { echo "Could not talk to launchd" >&2; exit 5; }
    printf 'PID\tStatus\tLabel\n'
    printf -- '-\t0\tcom.apple.something.else\n'
    while IFS= read -r l; do printf -- '-\t0\t%s\n' "\$l"; done < "$LOADED" ;;
esac
exit 0
STUB
chmod +x "$STUBS/launchctl"
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
export SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1
export SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e

# ---- a planted Mac: its own home, its own ~/.claude, a clone of a shared repo ----
FAKEHOME=""; OWN=""; AGENTS=""; CLONE=""; BARE=""; RECORD=""
plant(){   # $1 = a name for this Mac
  FAKEHOME="$WORK/$1"; OWN="$FAKEHOME/.claude"; AGENTS="$FAKEHOME/Library/LaunchAgents"
  RECORD="$FAKEHOME/.claude-sync-retired"
  mkdir -p "$OWN/agents" "$AGENTS"
  printf '# kept\n' > "$OWN/agents/kept.md"
  printf '# to be cleared\n' > "$OWN/agents/cleared.md"
  BARE="$WORK/$1-remote.git"; git init -q --bare -b main "$BARE"
  CLONE="$WORK/$1-clone"; git clone -q "$BARE" "$CLONE" 2>/dev/null
  git -C "$CLONE" checkout -q -b main 2>/dev/null
  printf 'seed\n' > "$CLONE/README"; git -C "$CLONE" add README
  git -C "$CLONE" commit -q -m seed; git -C "$CLONE" push -q -u origin main 2>/dev/null
  rm -f "$STUCK" "$LISTFAIL"; : > "$LCLOG"; : > "$LOADED"
}
case "$WORK" in /*) ;; *) echo "FAIL: WORK is not an absolute path. Refusing to run."; exit 1 ;; esac
run(){   # $1 = command, then NAME=value pairs, then -- and the command's arguments
  local cmd="$1"; shift
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env -u SYNC_LAUNCHAGENTS -u SYNC_NO_LAUNCHCTL -u SYNC_CLONE_REGISTRY -u SYNC_ZSHRC -u SYNC_HOLD_FILE \
    -u SYNC_WATCH_PID_FILE -u SYNC_LOG_FILE -u SYNC_RETIRED_FILE \
    HOME="$FAKEHOME" PATH="$RUNPATH" CLAUDE_HOME="$OWN" SYNC_REPO="$CLONE" SYNC_FSWATCH="$FSWATCH" \
    CLAUDE_SUITE_RUN_ID= ${extra[@]+"${extra[@]}"} bash "$SCRIPT" "$cmd" "$@" 2>&1
}
tree_of(){ (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
remote_head(){ git -C "$BARE" rev-parse main 2>/dev/null; }
loaded(){ LC_ALL=C sort "$LOADED" | paste -sd ' ' -; }

# ==== 1. the controls: install-autosync loads both agents, and a push from this Mac does reach the shared repo ====
plant mac-a
out="$(run install-autosync)"
check "control: install-autosync wrote both agents" test -f "$AGENTS/com.claudesync.timer.plist" -a -f "$AGENTS/com.claudesync.watch.plist"
check "control: install-autosync loaded both agents" same "$(loaded)" "com.claudesync.timer com.claudesync.watch"
before_push="$(remote_head)"
out="$(run push)"; rc=$?
check "control: a push before retiring reaches the shared repo" test "$(remote_head)" != "$before_push"
check "control: the file clearing will delete was sent" git -C "$BARE" cat-file -e "main:payload/agents/cleared.md"
[ "$rc" -eq 0 ] || printf '  the control push exited %s and said:\n%s\n' "$rc" "$out"

# ==== 2. without --yes, retire changes nothing and says what it would do ====
: > "$LCLOG"
OWN_BEFORE="$(tree_of "$OWN")"; HEAD_BEFORE="$(remote_head)"
out="$(run retire)"; rc=$?
check "preview: exits 2, so nothing reads it as done" same "$rc" 2
check "preview: says nothing was changed" has "$out" "Nothing was changed"
check "preview: names the confirming flag" has "$out" "claude-sync retire --yes"
check "preview: names both agents it would remove" has "$out" "com.claudesync.timer, com.claudesync.watch"
check "preview: writes no retired record" test ! -e "$RECORD"
check "preview: both agents are still installed" test -f "$AGENTS/com.claudesync.timer.plist" -a -f "$AGENTS/com.claudesync.watch.plist"
check "preview: both agents are still loaded" same "$(loaded)" "com.claudesync.timer com.claudesync.watch"
check "preview: unloads nothing" lacks "$(cat "$LCLOG")" "unload"

# ==== 3. retire --yes: recorded, unloaded, removed, confirmed from launchd, and nothing else touched ====
: > "$LCLOG"
out="$(run retire -- --yes)"; rc=$?
check "retire: exits 0" same "$rc" 0
[ "$rc" -eq 0 ] || printf '  retire said:\n%s\n' "$out"
check "retire: writes the retired record outside ~/.claude" test -f "$RECORD"
check "retire: unloads the timer" grep -q "^unload $AGENTS/com.claudesync.timer.plist" "$LCLOG"
check "retire: unloads the watcher" grep -q "^unload $AGENTS/com.claudesync.watch.plist" "$LCLOG"
check "retire: removes both plists" test ! -e "$AGENTS/com.claudesync.timer.plist" -a ! -e "$AGENTS/com.claudesync.watch.plist"
check "retire: neither agent is loaded afterwards" same "$(loaded)" ""
check "retire: reads launchd back rather than trusting unload" grep -q '^list$' "$LCLOG"
check "retire: says it confirmed neither is loaded" has "$out" "launchctl list shows neither com.claudesync.timer nor com.claudesync.watch loaded"
check "retire: says what it removed" has "$out" "Unloaded and removed: com.claudesync.timer, com.claudesync.watch"
check "retire: says what it left" has "$out" "Left alone:"
check "retire: names the way back" has "$out" "rm $RECORD"
check "retire: ~/.claude is untouched" same "$(tree_of "$OWN")" "$OWN_BEFORE"
check "retire: the shared repo is untouched" same "$(remote_head)" "$HEAD_BEFORE"
check "retire: every launchctl call named the planted Mac's own agents" same "$(grep -c "$WORK" "$LCLOG")" "$(grep -c -e '^unload' -e '^load' "$LCLOG")"
RECORD_SUM="$(cksum < "$RECORD")"

# ==== 4. after retiring, every send is refused and the shared repo does not move ====
rm -f "$OWN/agents/cleared.md"   # what clearing the Mac does
for c in push send sync pull; do
  out="$(run "$c")"; rc=$?
  check "$c after retire: refused" test "$rc" -ne 0
  check "$c after retire: says the Mac is retired" has "$out" "this Mac was retired from the sync"
  check "$c after retire: the shared repo did not move" same "$(remote_head)" "$HEAD_BEFORE"
done
check "after retire: the deletion never reached the shared repo" git -C "$BARE" cat-file -e "main:payload/agents/cleared.md"
out="$(run watch)"; rc=$?
check "watch after retire: refused" test "$rc" -ne 0
check "watch after retire: says the Mac is retired" has "$out" "this Mac was retired from the sync"
: > "$LCLOG"
out="$(run install-autosync)"; rc=$?
check "install-autosync after retire: refused" test "$rc" -ne 0
check "install-autosync after retire: writes no agent" test ! -e "$AGENTS/com.claudesync.timer.plist" -a ! -e "$AGENTS/com.claudesync.watch.plist"
check "install-autosync after retire: loads nothing" same "$(cat "$LCLOG")" ""
check "install-autosync after retire: names the way back" has "$out" "rm $RECORD"
out="$(run install-schedule)"; rc=$?
check "install-schedule after retire: refused" test "$rc" -ne 0

# ==== 5. retire twice: safe, says so, keeps the first record ====
out="$(run retire -- --yes)"; rc=$?
check "retire twice: exits 0" same "$rc" 0
check "retire twice: says it was already retired" has "$out" "already recorded as retired"
check "retire twice: says there was nothing to remove" has "$out" "no launch agent was installed or loaded"
check "retire twice: the first record is kept" same "$(cksum < "$RECORD")" "$RECORD_SUM"
check "retire twice: still confirms from launchd" has "$out" "launchctl list shows neither"

# ==== 6. an agent launchd will not let go of is reported, never claimed gone ====
plant mac-stuck
run install-autosync >/dev/null
touch "$STUCK"
out="$(run retire -- --yes)"; rc=$?
check "stuck agent: exits non zero" test "$rc" -ne 0
check "stuck agent: says it is still loaded" has "$out" "NOT confirmed"
check "stuck agent: names the label" has "$out" "com.claudesync.watch"
check "stuck agent: makes no claim that neither is loaded" lacks "$out" "launchctl list shows neither"
check "stuck agent: the record is still written, so its runs refuse" test -f "$RECORD"

# ==== 7. launchd cannot be read: said, and not passed ====
plant mac-unreadable
run install-autosync >/dev/null
touch "$LISTFAIL"
out="$(run retire -- --yes)"; rc=$?
check "unreadable launchd: exits non zero" test "$rc" -ne 0
check "unreadable launchd: says it could not read" has "$out" "could not be read"
check "unreadable launchd: makes no claim that neither is loaded" lacks "$out" "launchctl list shows neither"

# ==== 8. a fixture home is refused whole: it is not this Mac's to retire ====
plant mac-fixture
FIXHOME="$WORK/fixture-claude"; mkdir -p "$FIXHOME"
out="$(env -u SYNC_LAUNCHAGENTS -u SYNC_RETIRED_FILE HOME="$FAKEHOME" PATH="$RUNPATH" CLAUDE_HOME="$FIXHOME" SYNC_REPO="$CLONE" bash "$SCRIPT" retire --yes 2>&1)"; rc=$?
check "fixture home: refused" test "$rc" -ne 0
check "fixture home: says why" has "$out" "not this user's own ~/.claude"
check "fixture home: no launchctl call" same "$(cat "$LCLOG")" ""
check "fixture home: no record written" test ! -e "$RECORD"

# ==== 9. the real agents on this Mac were never touched ====
check "the real agents on this Mac are byte for byte as they were" same "$(real_agents)" "$REAL_BEFORE"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
