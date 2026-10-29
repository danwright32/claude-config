#!/usr/bin/env bash
#
# hold-record.sh: the ONE reading of the watcher hold record (claude-config#1886).
#
# Sourced, never executed, by claude-sync and by lib/sync-clone.sh. claude-sync takes, lifts and
# reports holds; the hooks behind sync-clone.sh refuse a payload write unless the writing session
# holds the watcher. Both have to agree on whose hold a line is, so the record is parsed here and
# nowhere else: a second parser would be a second answer to "is this my hold", each reading as
# correct on its own (L370).
#
# Defines functions only, and sets NO variable. claude-sync decides where the record lives before
# it sources anything (a fixture home has none at all, claude-config#1470), and sync-clone.sh sets
# its own default. A default set here would point claude-sync's fixture runs back at this Mac's
# real record.
#
# The record, one line per hold (claude-config#1863):
#
#   <ends, epoch> <taken, epoch> <host> session=<id> <why ...>
#
# A line from before #1863 has no session field (<ends> <taken> <host> <why ...>), and is read as a
# hold by "unknown": a hold from a terminal, which is anyone's to lift and covers any session.

# A session id as the record holds it: the id itself when it is the shape of one, else "unknown".
# The record is split on spaces, so anything else would not survive being written into it.
hold_record_session(){   # $1 = a session id, or nothing
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) printf 'unknown' ;;
    *) printf '%s' "$1" ;;
  esac
}

# The short name status shows for a session, and the one `release --other` takes.
hold_record_short(){   # $1 = a session id
  printf '%s' "${1:0:8}"
}

# Every line of the record as a row: state, ends, taken, host, owner, why, separated by the unit
# separator (octal 037) rather than a tab, because `read` folds a run of tabs into one and a row
# with empty fields would shift. State is live, expired, or unreadable. Read only: a line that
# cannot be read is reported as such and left for claude-sync to clear in its own words (L5).
hold_record_rows(){   # $1 = the record  $2 = now, epoch seconds
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0
  awk -v now="$2" 'BEGIN { OFS = "\037" }
    {
      if ($1 !~ /^[0-9]+$/) { print "unreadable", "", "", "", "", ""; next }
      ends = $1 + 0; taken = $2; host = $3
      if ($4 ~ /^session=/) { owner = substr($4, 9); first = 5 } else { owner = "unknown"; first = 4 }
      if (owner == "") owner = "unknown"
      if (taken !~ /^[0-9]+$/) taken = ends
      why = ""
      for (i = first; i <= NF; i++) why = why (why == "" ? "" : " ") $i
      gsub(/\037/, " ", why)
      print ((ends > now + 0) ? "live" : "expired"), ends, taken, host, owner, why
    }' "$1" 2>/dev/null || true
}
