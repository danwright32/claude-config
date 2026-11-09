#!/usr/bin/env bash
#
# merge-in-line.sh <owner/name> <pr>: whether a merge-when-ready.sh run on this Mac is still in the
# repository's line to merge that pull request (claude-config#2403). Prints "running" when a ticket for
# it names a run that is alive, by the line's own rule (merge-turn.sh's turn_alive: dead only when the
# system says the pid is not running, or runs with another start time), and "gone" otherwise. Exits 0
# with either answer, and 2 when it could not ask (an argument missing or malformed, or a line that is
# there but cannot be read, or a ticket in it that cannot be), saying why, so a caller can tell an
# answer from a failure to ask (L98). is-it-live takes anything but the two answers as not knowing,
# never as "gone" (#2466).
#
# WHY. is-it-live asks GitHub about a merge the helper makes in the background for WAIT_MS, 24 hours
# (a setting, not measured), and since claude-config#2351 a helper behind a long line that keeps moving has no fixed longest, so
# it can still be running past that window. Rather than let go of a merge whose helper may yet make
# it, is-it-live asks this, and lets the merge go only on "gone": it goes on waiting on "running" and
# on anything that is no answer (#2466).
#
# It only READS the line (L206): unlike turn_look, it never removes a ticket whose run has gone, so
# asking can never pass anybody over or change who holds the turn.

lib="${BASH_SOURCE[0]%/*}"; [ "$lib" != "${BASH_SOURCE[0]}" ] || lib=.
usage(){ printf 'usage: merge-in-line.sh <owner/name> <pull request number>\n' >&2; exit 2; }
[ "$#" -eq 2 ] || usage
case "$1" in */*) ;; *) usage ;; esac
case "$2" in ''|*[!0-9]*) usage ;; esac
# shellcheck source=merge-turn.sh
. "$lib/merge-turn.sh" || { printf 'merge-in-line.sh: could not load %s/merge-turn.sh\n' "$lib" >&2; exit 2; }

unread(){ printf 'merge-in-line.sh: could not read the line at %s (%s)\n' "$TURN_REPO_DIR" "$1" >&2; exit 2; }
turn_open "$1" || unread "turn_open failed"
# No folder at all is an empty line, so "gone"; one that is there but cannot be listed, or sits under
# something that is not a folder, is no answer, since nothing was read to say nobody is in it (L98).
if [ -e "$TURN_REPO_DIR" ]; then
  [ -d "$TURN_REPO_DIR" ] && [ -r "$TURN_REPO_DIR" ] && [ -x "$TURN_REPO_DIR" ] || unread "not a folder this can list"
else
  up="$TURN_REPO_DIR"
  while [ -n "$up" ] && [ ! -e "$up" ]; do up="${up%/*}"; done
  [ -z "$up" ] || [ -d "$up" ] || unread "$up is not a folder"
fi
for n in $(turn_tickets); do
  f="$TURN_REPO_DIR/$n"
  # A ticket that cannot be read may be this pull request's, alive, so it is no answer (#2466): skipped,
  # it would turn into "gone" for a run still in line. One removed since the listing has left the line.
  [ ! -e "$f" ] || [ -r "$f" ] || unread "ticket $n cannot be read"
  [ "$(turn_field "$f" pr)" = "$2" ] || continue
  if turn_alive "$(turn_field "$f" pid)" "$(turn_field "$f" start)"; then
    echo running
    exit 0
  fi
done
echo gone
