#!/usr/bin/env bash
#
# merge-in-line.sh <owner/name> <pr>: whether a merge-when-ready.sh run on this Mac is still in the
# repository's line to merge that pull request (claude-config#2403). Prints "running" when a ticket for
# it names a run that is alive, by the line's own rule (merge-turn.sh's turn_alive: dead only when the
# system says the pid is not running, or runs with another start time), and "gone" otherwise. Exits 0
# with either answer, and 2, printing how it is used, when either argument is missing or malformed, so
# a caller can tell an answer from a failure to ask (L98).
#
# WHY. is-it-live asks GitHub about a merge the helper makes in the background for WAIT_MS, 24 hours
# (a setting, not measured), and since claude-config#2351 a helper behind a long line that keeps moving has no fixed longest, so
# it can still be running past that window. Rather than let go of a merge whose helper may yet make
# it, is-it-live asks this, and goes on waiting while the answer is "running".
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

turn_open "$1"
for n in $(turn_tickets); do
  f="$TURN_REPO_DIR/$n"
  [ "$(turn_field "$f" pr)" = "$2" ] || continue
  if turn_alive "$(turn_field "$f" pid)" "$(turn_field "$f" start)"; then
    echo running
    exit 0
  fi
done
echo gone
