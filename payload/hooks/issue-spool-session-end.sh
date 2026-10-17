#!/bin/bash
# issue-spool-session-end.sh: a SessionEnd hook that stamps the ending session as ended in the issue
# spool (claude-config#1291), so the findings its agents left are released to the next review in that
# project now, while they are current, rather than a week from now.
#
# A session that has ended never runs another review, so before this its findings sat unjudged for
# the whole week ownership lasts (#326), then arrived at once, many out of date. Measured on Bidspoke
# on 2026-10-17: 135 of 233 pending records belonged to a session whose transcript had not been
# written for 16 hours.
#
# The stamp is one empty file, `<spool root>/ended/<session id>`. The readers also release a session
# whose transcript has been idle past a few hours, which covers a session that ended without this
# hook running (a crash, a killed terminal), and keep the week as the last backstop.
#
# It reads the hook payload on stdin. It never blocks anything (SessionEnd cannot), and it always
# exits 0, but a stamp it could not write is said on stderr, which Claude Code records in its debug
# log, rather than passed over in silence.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cat 2>/dev/null)"
sid="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
s = d.get("session_id") if isinstance(d, dict) else None
print(s if isinstance(s, str) else "")' 2>/dev/null)"
if [ -z "$sid" ]; then
  echo "issue-spool-session-end: the SessionEnd payload carried no session_id, so no session was marked ended; its findings are released when its transcript goes idle instead." >&2
  exit 0
fi
if ! out="$(bash "$HERE/lib/issue-spool.sh" mark-ended "$sid" 2>&1)"; then
  echo "issue-spool-session-end: could not mark session $sid ended: $out" >&2
fi
exit 0
