#!/usr/bin/env bash
#
# measure-sync-gaps.sh: re-derive the number behind SYNC_MAC_RETIRE_AFTER (claude-config#113).
#
# DESIGN.md justifies a 60 day retire window with "the other Mac's longest real gap between syncs
# was 6.8 days, so roughly 9x". That figure was measured once, written into three files, and left.
# The number itself was checked continuously by the suite; the measurement it came from was checked
# on the day it was written and never again, which is exactly how the suite's own deadline drifted
# from a documented 7x to a real 3x without anything noticing (claude-config#112, L210).
#
# The deadline could be made self-measuring, because a run can time itself. This one cannot: it is a
# fact about the repo's real history, and the test suite is structurally forbidden from touching the
# real repo (L2). So the next best thing is that re-deriving it costs one command instead of an
# afternoon of archaeology. Run it, read the ratio, update the row and the date.
#
# Usage: measure-sync-gaps.sh [repo-path]        (default: the repo this script lives in)
#   MEASURE_WINDOW_DAYS     how far back to look (default 60, matching the documented window)
#   SYNC_MAC_RETIRE_AFTER   the window being justified, in seconds (default 5184000, 60 days)
#
# Exit 0 = measured. Exit 1 = there is no sync history to measure, which is a REFUSAL and not a
# longest gap of zero: zero would read as "no Mac ever goes away", the most reassuring answer this
# could possibly give, and it is indistinguishable from a repo nobody has ever synced (L98).
# Exit 2 = it was not pointed at a git repository.
set -uo pipefail

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WINDOW_DAYS="${MEASURE_WINDOW_DAYS:-60}"
RETIRE="${SYNC_MAC_RETIRE_AFTER:-5184000}"
case "$WINDOW_DAYS" in ''|*[!0-9]*) echo "measure-sync-gaps: MEASURE_WINDOW_DAYS='$WINDOW_DAYS' is not a whole number of days." >&2; exit 2 ;; esac
case "$RETIRE" in ''|*[!0-9]*) echo "measure-sync-gaps: SYNC_MAC_RETIRE_AFTER='$RETIRE' is not a whole number of seconds." >&2; exit 2 ;; esac

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "measure-sync-gaps: $REPO is not a git repository, so there is no sync history to read." >&2
  exit 2
}

# Author date and subject for every commit a sync wrote. The subject is the only record of WHICH Mac
# sent it, so a repo whose sync commits were ever reworded measures as empty, and that is why an
# empty answer refuses rather than reporting a zero.
_log="$(git -C "$REPO" log --format='%at %s' 2>/dev/null | grep -i 'sync from ' || true)"
# `case` rather than `${_log//[[:space:]]/}`. That substitution walks and reallocates the whole
# string, and the bash macOS ships takes MINUTES over the real repo's 34KB of sync history while
# finishing instantly on a four commit fixture. A path whose cost depends on the SIZE of its input
# always takes the small branch under test, so no fixture here could have caught it (L101).
case "$_log" in
  *[![:space:]]*) ;;
  *)
    echo "measure-sync-gaps: found no sync commits in $REPO, so there is nothing to measure. Refusing to report a longest gap of zero, which would read as no Mac ever going away." >&2
    exit 1 ;;
esac

# The window is anchored to the NEWEST sync rather than to the clock. Anchored to the clock, the same
# history measures differently tomorrow, and a fixture built to hold a known answer stops holding it
# (L130). It also means a repo that stopped syncing months ago still reports what its last 60 active
# days looked like, rather than reporting nothing at all.
printf '%s\n' "$_log" | awk -v win="$WINDOW_DAYS" -v retire="$RETIRE" '
  {
    ts = $1 + 0
    # The name is printed as the commit RECORDED it, never lowercased: this is the string a person
    # matches against what their Macs are actually called, and a normalised form is a value nobody
    # wrote. Grouping is by that same recorded string, so a Mac renamed mid history shows as two
    # rows, which is the honest answer rather than a silent merge.
    host = $0
    sub(/^[0-9]+[[:space:]]+/, "", host)
    sub(/.*[Ss][Yy][Nn][Cc] [Ff][Rr][Oo][Mm][[:space:]]+/, "", host)
    gsub(/[[:space:]]+$/, "", host)
    n++; T[n] = ts; H[n] = host
    if (ts > newest) newest = ts
  }
  END {
    cutoff = newest - (win * 86400)
    for (i = 1; i <= n; i++) {
      if (T[i] < cutoff) continue
      c = ++cnt[H[i]]
      seen[H[i]] = 1
      # git log is newest first, so this fills in descending order; the gap maths below does not
      # care about direction, only about the distance between adjacent syncs.
      last = prev[H[i]]
      if (c > 1) {
        d = last - T[i]; if (d < 0) d = -d
        if (d > worst[H[i]]) worst[H[i]] = d
        if (d > overall) overall = d
      }
      prev[H[i]] = T[i]
      total++
    }
    printf "measure-sync-gaps: %d sync commits in the last %d days, anchored to the newest sync rather than to today\n", total, win
    hosts = 0
    for (h in seen) {
      hosts++
      if (cnt[h] < 2)
        printf "  %s: %d sync in the window, so there is only one and no gap to measure\n", h, cnt[h]
      else
        printf "  %s: %d syncs, longest gap %.2f days\n", h, cnt[h], worst[h] / 86400
    }
    if (overall > 0) {
      printf "measure-sync-gaps: the longest gap any Mac showed is %.2f days. SYNC_MAC_RETIRE_AFTER is %.1f days, which is %.1fx it.\n", overall / 86400, retire / 86400, (retire / overall)
    } else {
      printf "measure-sync-gaps: no Mac in this window has two syncs, so no gap could be measured and the window below is justified by nothing here.\n"
    }
  }
'
