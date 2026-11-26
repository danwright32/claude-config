#!/usr/bin/env bash
# PostToolUse(Bash): record each hand rerun of a workflow run, `gh run rerun`, in the issue spool
# (claude-config#3613), so the end of turn review can count a job that keeps failing and then passing
# on a rerun. The rules live in rerun_record.py; this is only the wrapper.
#
# Posts nothing and alerts nobody. A command it cannot read records nothing and says nothing. A
# record it could not WRITE is said, on stderr and as a systemMessage, since a recorder that stopped
# writing would look exactly like one with no reruns to record (L98).

set -uo pipefail

payload="$(cat)"
# The cheap test first, in bash, before anything is sourced or started: this runs after every Bash
# call and almost none is a rerun. The payload's text holds the command, so a payload without the
# word cannot hold a rerun. Every imprecision here runs the Python half rather than skipping it.
case "$payload" in *rerun*) ;; *) exit 0 ;; esac

case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE="$(cd "${HERE:-/}" && pwd)"
# Cleaned by the shared reader when it loads, as check-filed-issue-session.sh does (#1944).
. "$HERE/lib/push-scope.sh" 2>/dev/null && payload="$(ps_clean_payload "$payload")"
# shellcheck source=lib/hook-notice.sh
. "$HERE/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
printf '%s' "$payload" | GATE_DIR="$HERE" python3 "$HERE/rerun_record.py" 2>"$err"
rc=$?
if [ "$rc" -eq 3 ]; then
  hook_allow_notice "HAND RERUN NOT RECORDED: $(tr '\n' ' ' <"$err" 2>/dev/null)"
elif [ "$rc" -ne 0 ]; then
  hook_allow_notice "RERUN RECORDER DID NOT RUN: rerun-record.sh failed (rc=$rc), so a gh run rerun in this command may not be recorded. $(tr '\n' ' ' <"$err" 2>/dev/null)"
fi
exit 0
