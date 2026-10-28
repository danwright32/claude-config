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
#   DCU_AWK_LIB            the same reading as an awk function, dcu_h(<KiB>), for a caller turning
#                          thousands of sizes into words in one awk pass (the review page, #1807);
#                          dcu_human is a call to it, so the two can never disagree
#   dcu_docker_kib <size>  a size as Docker prints it (decimal units: 1.2GB, 512kB, 0B) in KiB;
#                          fails, printing nothing, on anything else
#
# Commands: awk and the builtins. bash 3.2 safe. Sourcing defines functions and does nothing else.

DCU_AWK_LIB='
function dcu_h(k,    b, n) {
  if (k !~ /^[0-9]+$/) return "size unknown"
  b = k * 1024
  if (b >= 1000000000) return sprintf("%.1f GB", b / 1000000000)
  if (b >= 1000000) return sprintf("%d MB", int(b / 1000000 + 0.5))
  n = int(b / 1000 + 0.5); if (n < 1 && b > 0) n = 1
  return sprintf("%d KB", n)
}
'

dcu_human() { # <KiB>
  awk -v k="${1:-}" "$DCU_AWK_LIB"'BEGIN { printf "%s", dcu_h(k) }'
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
