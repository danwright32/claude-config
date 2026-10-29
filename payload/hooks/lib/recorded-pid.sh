#!/usr/bin/env bash
#
# recorded-pid.sh: whether a process id written down moments ago is still that process when its
# command line cannot vouch for it. Sourced, never run.
#
# A site that records a process id and later asks whether it is still the same process reads its
# command line, because an id is reused once its process has gone (L1011). That reading is wrong in
# a process's first instants. On Linux a process inside execve shows an EMPTY command line, which
# macOS never does, and on both systems a child between fork and exec shows its parent's. PR #1897
# found the scanners gate reading that instant as "the run I recorded is gone" and starting a second
# copy, only on Linux CI, and fixed it there by trusting a running process recorded within the last
# minute. The rule moved here so every site that checks a recorded id by its command line applies
# the same one rather than a copy of it (claude-config#1909, L370).
#
# An id seen running moments ago cannot have been handed to another process since, so it counts as
# itself whatever its command line reads. A setting, not a measurement: the instant is microseconds,
# and a minute is far past it and far short of the time any system takes to reuse an id.
#
# It only ever says "this is the process you recorded". Stopping one is still each caller's own, by
# the traced id or its process group, never by matching command text (L1011, L321).
#
#   recorded_pid_young <pid> <epoch seconds it was recorded at>
#     0 when the pid is running and was recorded under RECORDED_PID_YOUNG seconds ago. 1 otherwise,
#     an unreadable pid or time, and a time in the future, included.
RECORDED_PID_YOUNG=60
recorded_pid_young(){   # $1 = pid  $2 = when it was recorded, in epoch seconds
  local age
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  # kill -0 0 signals the caller's own process group and succeeds, so 0 would read as running.
  [ "$1" -gt 0 ] 2>/dev/null || return 1
  case "${2:-}" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  age=$(( $(date +%s) - $2 ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$RECORDED_PID_YOUNG" ]
}
