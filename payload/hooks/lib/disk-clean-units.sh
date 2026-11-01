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
#   DCU_AWK_TALLY          the one copy of how offerable items add up to a total (#1866), as awk
#                          functions: dcu_tally(<key>, <bytes>, <size>) counts one offerable item
#                          under <key>, and dcu_tally_line(<key>) prints "<items> <unsized> <KiB>
#                          <partial>" for it. Used by the scan's closing summary and the low space
#                          warning's scan_note (check-free-space.sh), which read different layouts
#                          of the same record, so each passes its own fields
#   dcu_total_kind <items> <unsized> <partial>
#                          how a total of those is worded: "unknown" when no item's size was read
#                          (never 0), "lower" when one had none or was read only in part (the total
#                          is "at least"), "exact" otherwise, including when there was nothing to
#                          total; "unknown" for a tally that is not numbers
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

# UNREAD IS NEVER 0 (L90, L11). An offerable item with no bytes adds no KiB and is counted as
# unsized; one whose bytes were read but not in full (its size is anything but measured, reported,
# or empty in a record from before sizes were recorded: partial, denied, unread) makes the total a
# lower bound. <bytes> is in bytes, as the record carries it.
DCU_AWK_TALLY='
function dcu_tally(key, bytes, size) {
  dcu_tn[key]++
  if (bytes == "") dcu_tu[key]++
  else { dcu_tb[key] += bytes; if (size != "measured" && size != "reported" && size != "") dcu_tp[key] = 1 }
}
function dcu_tally_line(key) {
  return sprintf("%d %d %.0f %d", dcu_tn[key], dcu_tu[key], dcu_tb[key] / 1024, dcu_tp[key])
}
'
dcu_total_kind() { # <items> <unsized> <partial> -> unknown | lower | exact
  local a
  for a in "${1:-}" "${2:-}" "${3:-}"; do case "$a" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac; done
  if [ "$1" -gt 0 ] && [ "$2" -eq "$1" ]; then printf 'unknown'
  elif [ "$2" -gt 0 ] || [ "$3" -ne 0 ]; then printf 'lower'
  else printf 'exact'; fi
}

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
