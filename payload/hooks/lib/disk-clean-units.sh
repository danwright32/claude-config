#!/usr/bin/env bash
#
# disk-clean-units.sh: the one copy of how disk-clean reads and writes a size (claude-config#1806).
#
# Moved out of disk-remove.sh (#1805) when disk-clean's scan (payload/skills/disk-clean/scan.sh)
# needed the same two readings, so the figure a scan offers and the figure a removal reports are
# turned into words, and read from Docker, by one function each (L370).
#
#   dcu_human <KiB>        a KiB count as a person reads it: "12 KB", "340 MB", "1.5 GB"; "size
#                          unknown" for anything that is not a number, never 0
#   dcu_docker_kib <size>  a size as Docker prints it (decimal units: 1.2GB, 512kB, 0B) in KiB;
#                          fails, printing nothing, on anything else
#
# Commands: awk and the builtins. bash 3.2 safe. Sourcing defines functions and does nothing else.

dcu_human() { # <KiB>
  local k="${1:-}"
  case "$k" in ''|*[!0-9]*) printf 'size unknown'; return 0 ;; esac
  if [ "$k" -ge 1048576 ]; then awk -v k="$k" 'BEGIN { printf "%.1f GB", k / 1048576 }'
  elif [ "$k" -ge 1024 ]; then printf '%s MB' "$((k / 1024))"
  else printf '%s KB' "$k"; fi
}

dcu_docker_kib() { # <docker size, such as 1.2GB or 512kB> -> KiB; fails, printing nothing, on anything else
  local k
  k="$(awk -v s="$1" 'BEGIN {
    if (!match(s, /^[0-9.]+/)) exit 1
    v = substr(s, 1, RLENGTH); u = substr(s, RLENGTH + 1)
    m = 1
    if (u == "kB" || u == "KB") m = 1000; else if (u == "MB") m = 1000000; else if (u == "GB") m = 1000000000; else if (u == "TB") m = 1000000000000; else if (u != "B") exit 1
    printf "%d", v * m / 1024 }')" || return 1
  [ -n "$k" ] && printf '%s' "$k"
}
