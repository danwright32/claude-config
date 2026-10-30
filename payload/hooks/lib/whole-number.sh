#!/usr/bin/env bash
# whole-number.sh: the one test of a setting or a reading that must be a whole number above zero
# (claude-config#1948). Source it; it defines one function and sets nothing.
#
#   whole_above_zero VALUE   exit 0 when VALUE is digits only and not zero however it is written,
#                            exit 1 otherwise: empty, anything but digits (a sign, a space, a dot, a
#                            unit), or zero written as 0, 00, 000. It prints nothing.
#
# Every caller keeps its own answer to a value that fails, a default or a refusal; this decides only
# whether it failed. About 45 sites used to decide it by hand with a case pattern naming the empty
# string, anything but digits, and a bare 0. That refuses only a LITERAL 0, so 00 passed as a number
# above zero: in lib/bounded-run.sh it reached perl's alarm, which reads it as 0 and set no bound at
# all, and a lesson band 00 numbers wide sent claude-sync next-lesson walking from band to band for
# ever (claude-config#1931). test-whole-number.sh fails on the next hand written copy (L613).
#
# A value with leading zeros that is not zero (05) passes, and is handed back to the caller as it
# was written, as before: test and sleep read it as decimal. Bash arithmetic reads a leading zero as
# octal, so a caller doing arithmetic on a value that may carry one cuts the zeros itself.
#
# A caller whose copy of this file is missing gets "whole_above_zero: command not found" on standard
# error and status 127, which every caller reads as a value that failed: its default or its refusal,
# never a value nobody checked.

whole_above_zero() {
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
    *[!0]*) return 0 ;;
  esac
  return 1
}
