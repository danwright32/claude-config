#!/usr/bin/env bash
#
# disk-clean-units.sh: the one copy of how disk-clean reads and writes a size (claude-config#1806).
#
# Moved out of disk-remove.sh (#1805) when disk-clean's scan (payload/skills/disk-clean/scan.sh)
# needed the same two readings, so the figure a scan offers and the figure a removal reports are
# turned into words, and read from Docker, by one function each (L370).
#
#   dcu_human <KiB>        a KiB count as a person reads it, in DECIMAL units as Finder and the
#                          settled review page write them (#1807: 1 GB is a billion bytes): "12 KB",
#                          "340 MB", "1.6 GB"; "size unknown" for anything that is not a number,
#                          never 0 KB for a size that has bytes
#   dcu_human_to <var> <KiB>  the same, into a variable, with no process started: for a caller
#                          sizing every item (disk-remove.sh's measure)
#   DCU_AWK_LIB            the same rule as an awk function, dcu_h(<KiB>), for a caller turning
#                          thousands of sizes into words in one awk pass (the review page, #1807).
#                          The rule is integer arithmetic in all three languages that draw sizes
#                          (this shell, awk, and the review page's own script), never a float
#                          format, which rounds a half differently in each; the review page suite
#                          runs all three over the same values and fails on any difference
#   dcu_docker_kib <size>  a size as Docker prints it (decimal units: 1.2GB, 512kB, 0B) in KiB;
#                          fails, printing nothing, on anything else
#
# Commands: awk (dcu_docker_kib only) and the builtins. bash 3.2 safe. Sourcing defines functions and does nothing else.

DCU_AWK_LIB='
function dcu_h(k,    b, n) {
  if (k !~ /^[0-9]+$/) return "size unknown"
  b = k * 1024
  if (b >= 1000000000) { n = int((b * 10 + 500000000) / 1000000000); return sprintf("%d.%d GB", int(n / 10), n % 10) }
  if (b >= 1000000) return sprintf("%d MB", int((b + 500000) / 1000000))
  n = int((b + 500) / 1000); if (n < 1 && b > 0) n = 1
  return sprintf("%d KB", n)
}
'

# The same rule in shell arithmetic, so a caller sizing every item spends no process on it.
# dcu_human_to sets the variable it is named rather than printing (bash 3.2's printf -v).
dcu_human_to() { # <variable> <KiB>
  local k="${2:-}" b n
  case "$k" in ''|*[!0-9]*) printf -v "$1" '%s' 'size unknown'; return 0 ;; esac
  b=$((k * 1024))
  if [ "$b" -ge 1000000000 ]; then n=$(( (b * 10 + 500000000) / 1000000000 )); printf -v "$1" '%d.%d GB' $((n / 10)) $((n % 10))
  elif [ "$b" -ge 1000000 ]; then printf -v "$1" '%d MB' $(( (b + 500000) / 1000000 ))
  else n=$(( (b + 500) / 1000 )); [ "$n" -lt 1 ] && [ "$b" -gt 0 ] && n=1; printf -v "$1" '%d KB' "$n"; fi
}
dcu_human() { # <KiB>
  local w
  dcu_human_to w "${1:-}"
  printf '%s' "$w"
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
