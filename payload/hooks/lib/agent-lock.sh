# agent-lock.sh: whether a git worktree's lock was left by a Claude agent that is no longer
# running (claude-config#1282). Sourced, never run.
#
# Claude Code locks the worktree of an agent it starts, with the reason
#   claude agent <name> (pid <pid> start <that process's start time>)
# and lifts it when the agent finishes. An agent that never finishes (the Mac going down, a crash)
# leaves the lock behind, and git refuses to remove a locked worktree, so a lock outliving its agent
# keeps that worktree for ever: on 2026-10-17 five merged ones, each locked for pid 95065, a
# process that died when the Mac went down the evening before.
#
# agent_lock_verdict <lock reason> prints one line, "<verdict><TAB><detail>":
#   other       not a Claude agent's lock, so nothing here can say whose it is or whether it is done
#   live        that pid is running and started when the lock says, so its agent is still there
#   dead        no process has that pid
#   reused      a process has that pid but its start time does not match the lock's
#   preboot     the lock says its agent started before this machine last booted, which no process
#               survives, so ps is not even asked
#   nostart     an older lock, "claude agent <name> (pid <pid>)", whose pid is running: with no
#               start time recorded, a process that reused the pid cannot be ruled out
#   unreadable  whether it is running could not be read, so nothing is claimed either way (L10)
# Only dead and preboot say the lock is stale, because each is certain: no process has the pid, or
# no process survives a boot. A pid alone proves nothing (pids are reused), so the start time is what
# names a LIVE agent, but a start time that does not match is not proof the agent is gone: it is a
# comparison of two strings, and a format or time zone the lock was written in that this reader does
# not expect makes a live agent read as reused. So reused keeps the lock, the harmless direction
# (L648), as the brief for #1282 asked, and so does nostart, for the same reason. The older format
# has no start time to place before the boot, so it is never preboot; only a pid nothing has frees it.
#
# THE START TIME IN THE REASON WAS UTC when measured on 2026-10-17: a lock reading "start Sat Oct 17
# 14:06:12 2026" was held by a process ps gave as started 10:06:12 local time (EDT) and 14:06:12
# under TZ=UTC. Nothing promises it stays UTC, so it is read both ways: a match either way is the
# same process, and it is before the boot only when it is before it read either way. Every doubt
# lands on keeping the lock, the harmless direction (L648).
#
# Environment, for a fixture, so no test depends on this machine's own processes (L411):
#   AGENT_LOCK_PS          the ps to run (default ps)
#   AGENT_LOCK_BOOT_EPOCH  when this machine booted, in epoch seconds; set to anything that is not
#                          a number, it reads as unknown (default: sysctl kern.boottime, or the
#                          btime line of /proc/stat)

agent_lock_norm(){ printf '%s' "$1" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }

agent_lock_is_num(){ case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

agent_lock_boot_epoch(){
  local s
  if [ "${AGENT_LOCK_BOOT_EPOCH+set}" = set ]; then
    s="$AGENT_LOCK_BOOT_EPOCH"
  else
    # "{ sec = 1792202381, usec = 67623 } Fri Oct 16 21:59:41 2026". Anchored on the brace, since
    # a bare "sec = " also matches inside "usec = ".
    s="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*[{] sec = \([0-9][0-9]*\).*/\1/p')"
    [ -n "$s" ] || s="$(awk '$1 == "btime" { print $2; exit }' /proc/stat 2>/dev/null)"
  fi
  agent_lock_is_num "$s" || return 1
  printf '%s\n' "$s"
}

agent_lock_epoch(){ # <start time as ctime prints it> <UTC|local>: epoch seconds, or nothing
  local e
  if [ "$2" = UTC ]; then
    e="$(TZ=UTC date -j -f '%a %b %d %T %Y' "$1" +%s 2>/dev/null || TZ=UTC date -d "$1" +%s 2>/dev/null)"
  else
    e="$(date -j -f '%a %b %d %T %Y' "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null)"
  fi
  agent_lock_is_num "$e" && printf '%s\n' "$e"
}

agent_lock_ps_start(){ # <pid> <UTC|local>: prints its start time and returns 0 when running, 1
  # when no process has that pid, 2 when that could not be read (what ps said is printed instead).
  # ps exits 1 printing nothing for a pid nothing has (measured on macOS 2026-10-17); anything
  # else, words on either stream included, is not that answer.
  local out rc ps="${AGENT_LOCK_PS:-ps}"
  if [ "$2" = UTC ]; then out="$(TZ=UTC "$ps" -o lstart= -p "$1" 2>&1)"; rc=$?
  else out="$("$ps" -o lstart= -p "$1" 2>&1)"; rc=$?; fi
  out="$(agent_lock_norm "$out")"
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  if [ "$rc" -eq 1 ] && [ -z "$out" ]; then return 1; fi
  printf '%s\n' "${out:-$ps exited $rc and said nothing}"
  return 2
}

agent_lock_verdict(){ # <lock reason>
  local re='^claude agent [^ ]+ \(pid ([0-9]+) start ([^)]+)\)$'
  local old='^claude agent [^ ]+ \(pid ([0-9]+)\)$'
  local pid start boot eu el now first='' rc tz
  if [[ "$1" =~ $old ]]; then
    # The older format records no start time, so only a pid nothing has can be called gone.
    pid="${BASH_REMATCH[1]}"
    now="$(agent_lock_ps_start "$pid" UTC)"; rc=$?
    case "$rc" in
      0) printf 'nostart\tpid %s, which is running, and records no start time to tell its agent from a process that reused the pid\n' "$pid" ;;
      1) printf 'dead\tpid %s is no longer running\n' "$pid" ;;
      *) printf 'unreadable\tpid %s, and ps said: %s\n' "$pid" "$now" ;;
    esac
    return 0
  fi
  if ! [[ "$1" =~ $re ]]; then printf 'other\t\n'; return 0; fi
  pid="${BASH_REMATCH[1]}"; start="$(agent_lock_norm "${BASH_REMATCH[2]}")"
  if boot="$(agent_lock_boot_epoch)"; then
    eu="$(agent_lock_epoch "$start" UTC)"; el="$(agent_lock_epoch "$start" local)"
    if [ -n "$eu" ] && [ -n "$el" ] && [ "$eu" -lt "$boot" ] && [ "$el" -lt "$boot" ]; then
      printf 'preboot\tpid %s started %s, before this machine last booted\n' "$pid" "$start"
      return 0
    fi
  fi
  for tz in UTC local; do
    now="$(agent_lock_ps_start "$pid" "$tz")"; rc=$?
    case "$rc" in
      0) if [ "$now" = "$start" ]; then printf 'live\tpid %s, started %s\n' "$pid" "$start"; return 0; fi
         [ -n "$first" ] || first="$now" ;;
      1) printf 'dead\tpid %s is no longer running\n' "$pid"; return 0 ;;
      *) printf 'unreadable\tpid %s, and ps said: %s\n' "$pid" "$now"; return 0 ;;
    esac
  done
  printf 'reused\tpid %s is now a different process, started %s\n' "$pid" "$first"
}
