#!/usr/bin/env bash
# lib/this-mac.sh: which Mac a hook is on, read one way everywhere (claude-config#2561).
#
# Four hooks used to read `hostname` themselves and did not agree: two cut at the first dot and two
# only a trailing .local, so a name with several dots, as a network can hand out, was the work
# MacBook to one hook and an unknown Mac to the next. Every hook asks this instead, and
# lib/hand-rolled-hostname.py fails a suite on the next one that reads it by hand (L613).
#
#   this_mac_name           this Mac's short name
#   this_mac_name <name>    the short name of <name>, judged instead of this Mac's (each caller's
#                           override for its suite); an empty one stands for a name that cannot be
#                           read
#
# The short name is everything before the first dot, so Dans-MacBook-Pro, Dans-MacBook-Pro.local and
# Dans-MacBook-Pro.lan.example.com are one Mac. It is the form `hostname -s` gives, which claude-sync
# records, and the one CLAUDE.md names the Macs by. Printed with a newline and exit 0; nothing and
# exit 1 when no name can be read (hostname failing or answering nothing), which every caller says
# out loud rather than guessing (L11).

this_mac_name() {
  local h
  if [ "$#" -gt 0 ]; then
    h="$1"
  else
    h="$(hostname 2>/dev/null)" || h=""
  fi
  h="${h%%.*}"
  [ -n "$h" ] || return 1
  printf '%s\n' "$h"
}
