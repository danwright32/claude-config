#!/usr/bin/env bash
# whole-number.sh: the one test of a setting or a reading that must be a number above zero
# (claude-config#1948). Source it; it defines two functions and sets nothing.
#
#   whole_above_zero VALUE        exit 0 when VALUE is digits only and not zero however it is
#                                 written, and print it with its leading zeros cut. Exit 1 printing
#                                 nothing otherwise: empty, anything but digits (a sign, a space, a
#                                 dot, a unit), or zero written as 0, 00, 000.
#   decimal_above_zero VALUE      the same for a number of seconds that may carry a fraction: digits
#                                 with at most one dot and at least one digit, not zero however
#                                 written (0, 00, 0.0, 0.000), printed with its leading zeros cut and
#                                 a leading dot given its 0 (00.5 and .5 become 0.5).
#
# A caller captures the value, and its own answer to a value that fails goes after the ||:
#
#   n="$(whole_above_zero "$raw")" || n=30
#
# never under local, declare or export on the same line, whose own status (0) hides the refusal.
#
# Every caller keeps its own answer to a value that fails, a default or a refusal; these decide only
# whether it failed. About 45 sites used to decide it by hand with a case pattern naming the empty
# string, anything but digits, and a bare 0 (0.0 and 0.00 for the two decimal settings). That
# refuses only a LITERAL zero, so 00 passed as a number above zero: in lib/bounded-run.sh it reached
# perl's alarm, which reads it as 0 and set no bound at all, and a lesson band 00 numbers wide sent
# claude-sync next-lesson walking from band to band for ever (claude-config#1931).
#
# The value comes back with its leading zeros cut because bash arithmetic reads a leading zero as
# octal: a band size of 0500 was 320 numbers wide there, and a budget of 08 an arithmetic error that
# stopped the test runner. Every call captures what it prints, so there is one way to read a number
# everywhere, and test-whole-number.sh fails on a call that does not, as it does on the next hand
# written copy of either check (L613).
#
# They print rather than set a variable the caller names (printf -v "$2", until claude-config#2465):
# a name bound through a variable cannot be read without running the file, so the Slack drafts gate,
# which reads every file a script sources to learn whether it posts, lost track of every variable in
# every script that sourced this one, and could not follow the paths those scripts source next.
#
# A caller whose copy of this file is missing gets "command not found" and status 127, which every
# caller reads as a value that failed. A gate refuses before that, naming the file (#1900).

whole_above_zero() {
  case "${1-}" in ''|*[!0-9]*) return 1 ;; esac
  local v="${1#"${1%%[!0]*}"}"
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

decimal_above_zero() {
  case "${1-}" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac
  case "$1" in *[1-9]*) ;; *) return 1 ;; esac
  local whole="${1%%.*}" frac=""
  case "$1" in *.*) frac="${1#*.}" ;; esac
  whole="${whole#"${whole%%[!0]*}"}"
  [ -n "$whole" ] || whole=0
  if [ -n "$frac" ]; then
    printf '%s.%s' "$whole" "$frac"
  else
    printf '%s' "$whole"
  fi
}
