#!/usr/bin/env bash
# whole-number.sh: the one test of a setting or a reading that must be a number above zero
# (claude-config#1948). Source it; it defines two functions and sets nothing.
#
#   whole_above_zero VALUE NAME     exit 0 when VALUE is digits only and not zero however it is
#                                   written, and sets NAME to it with its leading zeros cut. Exit 1
#                                   otherwise: empty, anything but digits (a sign, a space, a dot, a
#                                   unit), or zero written as 0, 00, 000. NAME is then left as it was.
#   decimal_above_zero VALUE NAME   the same for a number of seconds that may carry a fraction:
#                                   digits with at most one dot and at least one digit, not zero
#                                   however written (0, 00, 0.0, 0.000), handed back with its leading
#                                   zeros cut and a leading dot given its 0 (00.5 and .5 become 0.5).
#
# Both print nothing, and exit 2 without setting anything when NAME is not a variable name.
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
# stopped the test runner. Every call names the variable to hand it back in, so there is one way to
# read a number everywhere, and test-whole-number.sh fails on a call that does not, as it does on the
# next hand written copy of either check (L613).
#
# A caller whose copy of this file is missing gets "command not found" and status 127, which every
# caller reads as a value that failed. A gate refuses before that, naming the file (#1900).

# Their own variables carry a prefix no caller uses: printf -v writes the nearest variable of that
# name, and a local here named like the caller's would take the value instead.
whole_above_zero() {
  case "${2-}" in ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*|_wn_*) return 2 ;; esac
  case "${1-}" in ''|*[!0-9]*) return 1 ;; esac
  local _wn_v="${1#"${1%%[!0]*}"}"
  [ -n "$_wn_v" ] || return 1
  printf -v "$2" '%s' "$_wn_v"
}

decimal_above_zero() {
  case "${2-}" in ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*|_wn_*) return 2 ;; esac
  case "${1-}" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac
  case "$1" in *[1-9]*) ;; *) return 1 ;; esac
  local _wn_whole="${1%%.*}" _wn_frac=""
  case "$1" in *.*) _wn_frac="${1#*.}" ;; esac
  _wn_whole="${_wn_whole#"${_wn_whole%%[!0]*}"}"
  [ -n "$_wn_whole" ] || _wn_whole=0
  if [ -n "$_wn_frac" ]; then
    printf -v "$2" '%s.%s' "$_wn_whole" "$_wn_frac"
  else
    printf -v "$2" '%s' "$_wn_whole"
  fi
}
