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
# It reads the hook payload on stdin. It never blocks anything (SessionEnd cannot), and a stamp it
# could not write is said, never passed over in silence (claude-config#1906, #1949).
#
# HOW IT IS SAID. The hooks documentation: SessionEnd "discards their JSON output fields, such as
# systemMessage", "Claude never sees stderr from a hook that exits 0", and exit 2 on SessionEnd
# "Shows stderr to user only", with "no decision control" to block anything. So the notice goes to
# stderr with exit 2, as the documentation directs. But SessionEnd stderr has NOT been seen to
# reach the person. On 2026-10-30 a /clear with the spool root made read only (chmod 500) printed
# no issue-spool-session-end line; the stamp goes into the ended/ folder, which stayed writable,
# and both test sessions were stamped ended (18:10 and 18:11 ET), so the hook succeeded and had
# nothing to print. That check could not fail, so whether exit 2 stderr shows at /clear is still
# unseen; making ended/ read only is the check that can. So the failure is ALSO left in a marker
# file (lib/spool-end-marker.sh: in the spool, or in TMPDIR when the spool is what cannot be
# written), and the next prompt in any session says it once, through sync-stuck-notice.sh's
# systemMessage, a channel seen to reach the person that same day.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Without either library the notice still goes to stderr; it just cannot be left for later.
. "$HERE/lib/hook-notice.sh" 2>/dev/null || hook_defer_notice() { return 1; }
. "$HERE/lib/spool-end-marker.sh" 2>/dev/null || { SEM_SPOOL_FILE=""; SEM_TMP_FILE=""; }
say() {   # $1 = the notice
  local when
  when="$(TZ=America/New_York date '+%Y-%m-%d %H:%M' 2>/dev/null) ET"
  printf '%s\n' "$1" >&2
  if ! hook_defer_notice "At $when, $1" "$SEM_SPOOL_FILE" "$SEM_TMP_FILE"; then
    printf '%s\n' "issue-spool-session-end: this could not be left for the next prompt to say either: neither ${SEM_SPOOL_FILE:-the spool marker} nor ${SEM_TMP_FILE:-the TMPDIR marker} could be written, or a library it needs is missing beside this hook." >&2
  fi
  exit 2
}
payload="$(cat 2>/dev/null)"
# Cleaned by the shared reader when it loads: a lone surrogate escape anywhere in the payload
# (an emoji cut in half is enough) makes jq read none of it (claude-config#1944). Without the
# library the payload is read as it came, as before.
case "${BASH_SOURCE[0]}" in */*) _ps_dir="${BASH_SOURCE[0]%/*}" ;; *) _ps_dir=. ;; esac
. "$_ps_dir/lib/push-scope.sh" 2>/dev/null && payload="$(ps_clean_payload "$payload")"
sid="$(printf '%s' "$payload" | python3 -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception:
    sys.exit(0)
s = d.get("session_id") if isinstance(d, dict) else None
print(s if isinstance(s, str) else "")' 2>/dev/null)"
if [ -z "$sid" ]; then
  say "issue-spool-session-end: the SessionEnd payload carried no session_id, so no session was marked ended; its findings are released when its transcript goes idle instead."
fi
if ! out="$(bash "$HERE/lib/issue-spool.sh" mark-ended "$sid" 2>&1)"; then
  say "issue-spool-session-end: could not mark session $sid ended: $out"
fi
exit 0
