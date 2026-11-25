#!/usr/bin/env bash
# A ps that cannot run is not read as no watcher running (claude-config#3584).
#
# claude-sync confirms what the process named in the watcher's pid file IS before it refuses a
# second watcher, and read that with `ps -o command=`, the failure discarded. A ps that could not
# run gave the same empty answer as a process that is something else, so a second watch daemon
# started beside a live one. ps fails for real under the no network wrapper (#3482) and in any
# sandbox that refuses setuid programs. Read in the code on 2026-11-24 and reproduced by this suite
# before the fix.
#
# This suite holds:
#   1. A second watcher does not start beside a process it could not read, with a ps that exits
#      non zero and with none on PATH, and says which command failed, that this is not the same as
#      none running, and what to remove once that process is seen to be something else.
#   2. What is settled stays settled: a live watcher is still refused as one, and a record naming
#      a process that has gone, zero, or a running process ps says is something else refuses nothing.
#   3. A process the shell may not signal is asked of ps, and is unread, never absent, when ps
#      cannot say what it is. So is a record that is there and cannot be read.
#   4. A running watcher whose record names a process it cannot read sends nothing, says so, does
#      not step down, and sends again once its own record is back.
#   5. status names "could not be read" as the likely cause of mods lagging, never "installed but
#      not running", which nothing measured.
#
# The claim on a hook suite rerun had the same fault and is covered where its other cases are,
# tests/test-hook-suite-rerun.sh, and retire's line about a watcher in tests/test-sync-retire.sh.
#
# Everything is a fixture: CLAUDE_HOME and SYNC_REPO are throwaways, fswatch and the send are stand
# ins, and every seam that could reach the Mac's own files is pointed into WORK. No test waits on a
# duration: each wait ends on the condition it is waiting for, with a bound only as a guard against
# a run that never gets there (L290).
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
check(){   # $1 = name  $2 = a command string that succeeds when the check holds  [$3 = output to show]
  if eval "$2"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1"
    [ -n "${3:-}" ] && printf '%s\n' "$3" | sed -n '1,25p' | sed 's/^/    /'
  fi
  return 0
}
# Every pattern on ONE line of the output, so two halves of different sentences cannot pass it.
line_has(){   # $1 = output  $2.. = fixed strings
  local cur="$1" p
  [ -n "$cur" ] || return 1
  shift
  for p in "$@"; do cur="$(printf '%s\n' "$cur" | grep -F -- "$p")" || return 1; done
  [ -n "$cur" ]
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sync-ps-cannot-tell.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
LIVE_PIDS=""
trap 'for _p in $LIVE_PIDS; do kill -9 "$_p" 2>/dev/null; done; rm -rf "$WORK"' EXIT

export SYNC_SCRATCH_ROOT="$WORK/scratch-root"; mkdir -p "$SYNC_SCRATCH_ROOT"
export SYNC_MANAGED_SETTINGS="$WORK/managed-settings.json"
printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"
export SYNC_CLAUDE_BIN="$WORK/no-such-claude" SYNC_GH="$WORK/no-such-gh" SYNC_RTK_BIN="$WORK/no-such-rtk"
export SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here"
export SYNC_LOG_FILE="$WORK/sync.log"
export SYNC_CLONE_REGISTRY="$WORK/clone-registry"; : > "$SYNC_CLONE_REGISTRY"
export SYNC_ZSHRC="$WORK/zshrc" SYNC_HOLD_FILE="$WORK/hold" SYNC_RETIRED_FILE="$WORK/retired"
# The process table status reports strays from, so it never reads what this Mac is running.
export SYNC_PS_FIXTURE="$WORK/ps-none"; : > "$SYNC_PS_FIXTURE"
# This suite starts one copy of claude-sync as the watcher many times in a few minutes, which is what
# a copy that keeps ending as soon as it starts looks like (#1594), and a later start would park.
export SYNC_WATCH_LOOP_MAX=100000
# No timer wake: every wake here is an event the stand in fswatch wrote.
export SYNC_WATCH_POLL=0
export SYNC_NO_HOOK_TESTS=1 SYNC_NO_SEND_TESTS=1 SYNC_NO_NOTIFY=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e

# ---- the two ways ps cannot answer ----
# A stand in that exits non zero, as ps does when it is refused.
mkdir -p "$WORK/badps"
printf '#!/bin/sh\necho "ps: operation not permitted" >&2\nexit 1\n' > "$WORK/badps/ps"; chmod +x "$WORK/badps/ps"
BADPS="$WORK/badps:$PATH"
# And a PATH that reaches everything this one does except ps: each folder holding a ps is stood in
# for by a folder of links to everything else in it.
no_ps_path(){ # no_ps_path <where to build it> -> the PATH
  local d out="" n=0 IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    if [ -e "$d/ps" ]; then
      n=$((n + 1)); mkdir -p "$1/$n"
      ln -s "$d"/* "$1/$n/" 2>/dev/null || true
      rm -f "$1/$n/ps"
      d="$1/$n"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}
NOPS="$(no_ps_path "$WORK/nops")"

# A process whose command line really does look like a watcher, and one that is something else. Each
# is the sleep itself, so killing it leaves nothing behind, and its own sleep bounds it besides.
start_watcher_like(){ bash -c 'exec -a "claude-sync watch" sleep 120' >/dev/null 2>&1 < /dev/null & LAST_PID=$!; LIVE_PIDS="$LIVE_PIDS $LAST_PID"; }
start_something_else(){ sleep 120 >/dev/null 2>&1 < /dev/null & LAST_PID=$!; LIVE_PIDS="$LIVE_PIDS $LAST_PID"; }
end_process(){ kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null; return 0; }
# Bounded waits on a condition: a file gaining its Nth line, and a file gaining a line with a string.
wait_lines(){ # wait_lines <file> <count>
  local n=0
  while [ "$n" -lt 300 ]; do
    [ "$(grep -c . "$1" 2>/dev/null)" -ge "$2" ] 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
wait_said(){ # wait_said <file> <fixed string>
  local n=0
  while [ "$n" -lt 300 ]; do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

WH="$WORK/home"; mkdir -p "$WH/hooks"; echo '{"hooks":{}}' > "$WH/settings.json"
WR="$WORK/repo"; git init -q -b main "$WR"
git -C "$WR" commit -q --allow-empty -m base
WPID="$WORK/watch.pid"; HITS="$WORK/hits"
printf '#!/usr/bin/env bash\necho one\n' > "$WORK/fswatch-once"; chmod +x "$WORK/fswatch-once"
# A start that goes ahead makes one send, which lands in $HITS, so a refusal is read from what was
# done and not only from what was said.
start_under(){ # start_under <PATH to start under> <the pid the record names> -> what the second watcher said
  printf '%s\n' "$2" > "$WPID"; : > "$HITS"
  PATH="$1" CLAUDE_HOME="$WH" SYNC_REPO="$WR" SYNC_FSWATCH="$WORK/fswatch-once" SYNC_WATCH_PID_FILE="$WPID" \
    SYNC_WATCH_SEND="printf 'x\n' >> '$HITS'" bash "$SCRIPT" watch 2>&1 || true
}

# ---- 1. a second watcher does not start beside a process it could not read ----
start_watcher_like; W_PID="$LAST_PID"
# The stand ins' own premise, asserted rather than assumed (L159).
check "(fixture) the stand in ps fails for a process that is running" \
  "! PATH=\"\$BADPS\" ps -o command= -p $W_PID >/dev/null 2>&1"
check "(fixture) the PATH with ps taken out reaches no ps, and still reaches bash and git" \
  "! PATH=\"\$NOPS\" command -v ps >/dev/null 2>&1 && PATH=\"\$NOPS\" command -v bash >/dev/null 2>&1 && PATH=\"\$NOPS\" command -v git >/dev/null 2>&1" "$NOPS"
check "(fixture) the real ps says the stand in watcher is one" \
  "case \"\$(ps -o command= -p $W_PID 2>/dev/null)\" in *claude-sync*watch*) true ;; *) false ;; esac" "$(ps -o command= -p "$W_PID" 2>&1)"
out_a="$(start_under "$BADPS" "$W_PID")"
check "a second watcher whose ps fails does not start beside a process it could not read" \
  "[ ! -s '$HITS' ] && line_has \"\$out_a\" 'could not be read' 'Nothing was started'" "$out_a"
check "and it names the command that failed and how it ended" \
  "line_has \"\$out_a\" 'could not be read' \"ps -o command= -p $W_PID\" 'exited 1'" "$out_a"
check "and says that is not the same as none running, and what to remove once that process is seen to be something else" \
  "line_has \"\$out_a\" 'not the same as none running' \"rm $WPID\"" "$out_a"
check "and it leaves the record naming that process" "[ \"\$(head -1 '$WPID' 2>/dev/null)\" = '$W_PID' ]" "$(cat "$WPID" 2>&1)"
out_b="$(start_under "$NOPS" "$W_PID")"
check "with no ps on PATH at all it does not start either, and says that is why" \
  "[ ! -s '$HITS' ] && line_has \"\$out_b\" 'could not be read' 'Nothing was started' 'no ps is on'" "$out_b"
check "and a missing ps is told from one that failed" "! line_has \"\$out_b\" 'could not be read' 'without saying what it is'" "$out_b"
check "and that start left the record alone too" "[ \"\$(head -1 '$WPID' 2>/dev/null)\" = '$W_PID' ]" "$(cat "$WPID" 2>&1)"

# ---- 2. what is settled stays settled, with ps or without it (L248) ----
out_c="$(start_under "$PATH" "$W_PID")"
check "(control) with ps answering, that same process is the live watcher it is" \
  "[ ! -s '$HITS' ] && line_has \"\$out_c\" 'already running' \"process $W_PID\"" "$out_c"
end_process "$W_PID"
out_d="$(start_under "$BADPS" "$W_PID")"
check "(control) a record left by a watcher that has gone refuses nothing when ps cannot run" \
  "[ -s '$HITS' ] && ! line_has \"\$out_d\" 'Nothing was started'" "$out_d"
out_z="$(start_under "$BADPS" 0)"
check "(control) nor does a record holding zero, which names no process" \
  "[ -s '$HITS' ] && ! line_has \"\$out_z\" 'Nothing was started'" "$out_z"
# A running process that is something else: a pid reused since the watcher that wrote it ended.
start_something_else; O_PID="$LAST_PID"
out_e="$(start_under "$PATH" "$O_PID")"
check "(control) a record naming a running process that ps says is something else refuses nothing" \
  "[ -s '$HITS' ] && ! line_has \"\$out_e\" 'Nothing was started'" "$out_e"
out_f="$(start_under "$BADPS" "$O_PID")"
check "and that same process is not started beside when ps cannot say what it is" \
  "[ ! -s '$HITS' ] && line_has \"\$out_f\" 'could not be read' 'Nothing was started' \"ps -o command= -p $O_PID\"" "$out_f"
end_process "$O_PID"

# ---- 3. a process the shell may not signal ----
# kill -0 exits 1 for a process it may not signal exactly as for one that has gone, and only its
# words tell the two apart. Pid 1 is running on every machine and belongs to another account.
if kill -0 1 2>/dev/null; then
  echo "SUITE-PART-UNMEASURED a watcher record naming a process this shell may not signal: this account may signal pid 1, so none could be found"
else
  out_g="$(start_under "$BADPS" 1)"
  check "a process the shell may not signal is unread, never absent, when ps cannot say what it is" \
    "[ ! -s '$HITS' ] && line_has \"\$out_g\" 'could not be read' 'kill -0' 'ps -o command= -p 1 '" "$out_g"
  check "without saying it is running, which nothing measured" "! line_has \"\$out_g\" 'could not be read' 'which is running'" "$out_g"
  out_h="$(start_under "$PATH" 1)"
  check "(control) and it is no watcher once ps says what it is" \
    "[ -s '$HITS' ] && ! line_has \"\$out_h\" 'Nothing was started'" "$out_h"
fi

# A record that is there and cannot be read is the same discarded failure one step earlier: it was
# read as holding no pid, and replaced.
start_watcher_like; S_PID="$LAST_PID"
SEALED="$WORK/sealed.pid"; printf '%s\n' "$S_PID" > "$SEALED"; chmod 000 "$SEALED"
if [ -r "$SEALED" ]; then
  echo "SUITE-PART-UNMEASURED a watcher record that cannot be read: this account reads a file with no permissions, so one could not be made"
else
  : > "$HITS"
  out_s="$(CLAUDE_HOME="$WH" SYNC_REPO="$WR" SYNC_FSWATCH="$WORK/fswatch-once" SYNC_WATCH_PID_FILE="$SEALED" \
    SYNC_WATCH_SEND="printf 'x\n' >> '$HITS'" bash "$SCRIPT" watch 2>&1 || true)"
  check "a record that is there and cannot be read is unread, never absent: nothing starts, and the file is named" \
    "[ ! -s '$HITS' ] && line_has \"\$out_s\" 'could not be read' 'Nothing was started' \"$SEALED is there and cannot be read\"" "$out_s"
  chmod 600 "$SEALED"
  check "and it is not replaced" "[ \"\$(head -1 '$SEALED' 2>/dev/null)\" = '$S_PID' ]" "$(cat "$SEALED" 2>&1)"
fi
chmod 600 "$SEALED" 2>/dev/null
end_process "$S_PID"

# ---- 4. a running watcher whose record names a process it cannot read ----
# The loop asks before every send whether another watcher has replaced it. A stand in fswatch
# writes an event each time the test lets it, so each answer is read from one event.
LGO2="$WORK/loop-go2"; LGO3="$WORK/loop-go3"; LEND="$WORK/loop-end"; LOUT="$WORK/loop.out"
cat > "$WORK/fswatch-steps" <<FSEOF
#!/usr/bin/env bash
trap '' PIPE
until_file(){ n=0; while [ ! -e "\$1" ] && [ \$n -lt 300 ]; do sleep 0.1; n=\$((n + 1)); done; }
echo one
until_file "$LGO2"; echo two
until_file "$LGO3"; echo three
until_file "$LEND"
FSEOF
chmod +x "$WORK/fswatch-steps"
rm -f "$WPID"; : > "$HITS"
PATH="$BADPS" CLAUDE_HOME="$WH" SYNC_REPO="$WR" SYNC_FSWATCH="$WORK/fswatch-steps" SYNC_WATCH_PID_FILE="$WPID" \
  SYNC_WATCH_SEND="printf 'x\n' >> '$HITS'" bash "$SCRIPT" watch > "$LOUT" 2>&1 &
L_ROOT=$!; LIVE_PIDS="$LIVE_PIDS $L_ROOT"
wait_lines "$HITS" 1
check "(fixture) a watcher whose own record names it sends, whatever ps does" \
  "[ \"\$(grep -c . '$HITS')\" = 1 ] && [ \"\$(head -1 '$WPID' 2>/dev/null)\" = '$L_ROOT' ]" "$(cat "$LOUT" 2>&1)"
start_something_else; L_OTHER="$LAST_PID"
printf '%s\n' "$L_OTHER" > "$WPID"
touch "$LGO2"
wait_said "$LOUT" 'could not be read'
check "a watcher whose record names a process it cannot read sends nothing for that change" \
  "[ \"\$(grep -c . '$HITS')\" = 1 ]" "$(cat "$LOUT" 2>&1)"
check "and says so, with the command that failed and how it ended" \
  "line_has \"\$(cat '$LOUT')\" 'NOT sent' 'could not be read' \"ps -o command= -p $L_OTHER\" 'exited 1'" "$(cat "$LOUT" 2>&1)"
check "and does not step down, which only another live watcher is a reason for" \
  "kill -0 $L_ROOT 2>/dev/null && ! grep -q 'stepped down' '$LOUT'" "$(cat "$LOUT" 2>&1)"
printf '%s\n' "$L_ROOT" > "$WPID"
touch "$LGO3"
wait_lines "$HITS" 2
check "and sends again once its own record is back" "[ \"\$(grep -c . '$HITS')\" = 2 ]" "$(cat "$LOUT" 2>&1)"
touch "$LEND"
wait "$L_ROOT" 2>/dev/null
end_process "$L_OTHER"

# ---- 5. status: the likely cause of mods lagging is what was measured ----
# status names an installed watcher that is not running as a likely cause of this Mac's mods lagging
# the shared repo. A watcher it could not read was said to be not running.
MB="$WORK/lag-bare.git"; git init -q --bare -b main "$MB"
MS="$WORK/lag-sender"; git clone -q "$MB" "$MS" 2>/dev/null
lag_commit(){ # lag_commit <how many seconds ago it landed> <message>; commits and pushes what is staged
  local at=$(( $(date +%s) - $1 ))
  GIT_AUTHOR_DATE="@$at" GIT_COMMITTER_DATE="@$at" git -C "$MS" commit -q -m "$2"
  git -C "$MS" push -q origin HEAD:main 2>/dev/null
}
mkdir -p "$MS/payload/mods/kit-mod/.claude-plugin" "$MS/payload/mods/kit-mod/hooks"
printf '{ "name": "kit-mod" }\n' > "$MS/payload/mods/kit-mod/.claude-plugin/plugin.json"
printf 'export const v = 1\n' > "$MS/payload/mods/kit-mod/hooks/branch.ts"
printf '# rules\n' > "$MS/payload/CLAUDE.md"
git -C "$MS" add -A; lag_commit 864000 "mods v1"
MR="$WORK/lag-repo"; git clone -q "$MB" "$MR" 2>/dev/null
MH="$WORK/lag-home"; mkdir -p "$MH"; echo '{"hooks":{}}' > "$MH/settings.json"
MAG="$WORK/lag-agents"; mkdir -p "$MAG"
MPID="$WORK/lag-watch.pid"
lag_run(){ # lag_run <command> [env assignments...] -> its output
  local cmd="$1"; shift
  env CLAUDE_HOME="$MH" SYNC_REPO="$MR" SYNC_LAUNCHAGENTS="$MAG" SYNC_WATCH_PID_FILE="$MPID" "$@" bash "$SCRIPT" "$cmd" 2>&1 || true
}
lag_run pull >/dev/null
printf 'export const v = 2\n' > "$MS/payload/mods/kit-mod/hooks/branch.ts"
git -C "$MS" add -A; lag_commit 172800 "kit-mod v2"
printf '<plist><string>%s</string></plist>\n' "$SCRIPT" > "$MAG/com.claudesync.watch.plist"
printf '<plist><string>%s</string></plist>\n' "$SCRIPT" > "$MAG/com.claudesync.timer.plist"
st_none="$(lag_run status)"
check "(control) with no watcher recorded, status names an installed watcher that is not running as a likely cause" \
  "line_has \"\$st_none\" 'likely cause' 'watcher is installed but not running'" "$st_none"
start_watcher_like; M_PID="$LAST_PID"
printf '%s\n' "$M_PID" > "$MPID"
st_live="$(lag_run status)"
check "(control) with a live watcher and ps answering, the watcher is not named as a cause at all" \
  "line_has \"\$st_live\" 'mods behind the shared repo' 'kit-mod' && ! line_has \"\$st_live\" 'likely cause' 'watcher'" "$st_live"
st_bad="$(lag_run status PATH="$BADPS")"
check "with ps failing, status says whether the watcher is running could not be read, and why" \
  "line_has \"\$st_bad\" 'likely cause' 'could not be read' \"ps -o command= -p $M_PID\" 'exited 1'" "$st_bad"
check "and does not say it is not running, which nothing measured" \
  "! line_has \"\$st_bad\" 'likely cause' 'installed but not running'" "$st_bad"
end_process "$M_PID"

# ---- where the writes landed (L322): the fixture, and nothing of this Mac's ----
check "the record of each watcher start this suite caused is inside the fixture clone" \
  "[ -s '$WR/.watch-starts' ] && [ ! -e '$HERE/../.watch-starts' ]"

echo ""
echo "PASS=$pass FAIL=$fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
