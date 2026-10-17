#!/usr/bin/env bash
#
# load-average.sh: how busy this machine is, read ONE way (claude-config#1083).
#
# A failure that only happens under load reads exactly like a real one unless the figure is written
# beside it (L356). On 2026-10-10 and 11 a pull's hook suite reported 32 of 94 suites failing and
# tools/check-mods.sh reported mods as "the file did not load", on a Mac carrying several suite runs,
# a backup and iCloud; a rerun minutes later passed everything, and nothing in any of those messages
# said the machine had been loaded. Three callers want the figure (the runner, check-mods and the
# section timer), so it is read here and nowhere else (L370).
#
# Sourced, never executed.
#
#   LOAD_AVERAGE_CMD     a command printing the one minute load average, so a test sets the figure
#                        rather than measuring whatever this Mac is doing (L290)
#   LOAD_AVERAGE_CORES   how many cores to judge it against, for the same reason

# The one minute load average, or NOTHING when it cannot be read. Nothing, never a zero: a zero is
# the most reassuring figure available and would read as an idle machine (L90). The command can be
# passed as the first argument, which is how measure-section-time.sh hands its own seam through.
load_average_one_minute(){   # [command] -> the figure, or nothing
  local v cmd="${1:-${LOAD_AVERAGE_CMD:-}}"
  if [ -n "$cmd" ]; then
    # Unquoted on purpose: a seam may carry its arguments, as the section timer's always has.
    v="$($cmd 2>/dev/null)"
  elif [ -r /proc/loadavg ]; then
    v="$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)"
  else
    v="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{ print $1 + 0 }')"
  fi
  case "$v" in ''|*[!0-9.]*) return 0 ;; esac
  printf '%s' "$v"
}

# How many cores the figure is judged against, or nothing.
load_average_cores(){   # -> a whole number, or nothing
  local c="${LOAD_AVERAGE_CORES:-}"
  [ -n "$c" ] || c="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
  case "$c" in ''|*[!0-9]*|0) return 0 ;; esac
  printf '%s' "$c"
}

# Whether the machine was busier than it has cores: exits 0 only when the figure, less any load the
# caller names as its own, is more than the cores. The one place that is decided (claude-config#1259),
# for the sentence below and for the sync suite's budgets, which report a run on such a machine as
# unmeasured rather than failing it. Anything it cannot read is NOT busy, never a zero: busy excuses
# a failure, so an unreadable figure must not be what excuses one (L90).
load_average_busy(){   # load cores [own load] -> exit 0 when busy
  local l="${1-}" c="${2-}" o="${3:-0}"
  case "$l" in ''|*[!0-9.]*) return 1 ;; esac
  case "$c" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$o" in *[!0-9.]*) return 1 ;; esac
  awk -v l="$l" -v c="$c" -v o="$o" 'BEGIN { exit !(l - o > c + 0) }'
}

# The sentence a failure carries. It claims only what was measured (L11): the figure, the cores, and
# whether the one exceeded the other. It never says the load CAUSED the failure, because nothing here
# measured that; it says what to do to find out.
load_average_note(){   # [load] [cores] -> one sentence, always
  local l="${1-$(load_average_one_minute)}" c="${2-$(load_average_cores)}"
  if [ -z "$l" ]; then
    printf 'load average could not be read, so whether the machine was busy is unknown'
    return 0
  fi
  if [ -z "$c" ]; then
    printf 'load average %s (the core count could not be read, so it is not judged against one)' "$l"
    return 0
  fi
  if load_average_busy "$l" "$c"; then
    printf 'load average %s on %s cores, more than this machine has cores, so a timing or load sensitive check may have measured the machine: run it again alone before treating it as broken' "$l" "$c"
  else
    printf 'load average %s on %s cores' "$l" "$c"
  fi
}
