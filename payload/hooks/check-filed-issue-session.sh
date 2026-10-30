#!/usr/bin/env bash
# PostToolUse(Bash): after a `gh issue create`, read the filed issue's body from GitHub and add the
# line naming this session where it is missing (claude-config#1272). The issue field gate
# (require-issue-fields.sh) judges a body before the command runs and passes one it cannot read; this
# reads what was actually filed. The rules and the messages live in filed_issue_session.py; this is
# only the wrapper.
#
# Never blocks: the issue already exists. A crash is said, never silent, since a check that stopped
# running would look exactly like one finding every issue fine (L98).

set -uo pipefail

payload="$(cat)"
# The cheap test first: almost no Bash command files an issue, and python costs every one that runs.
case "$payload" in *issue*create*) ;; *) exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A crash is said as a systemMessage. The hooks documentation: "Claude never sees stderr from a hook
# that exits 0", and a PostToolUse hook's systemMessage is not among those it discards, so that is
# the channel that reaches Dan (#1906).
# shellcheck source=lib/hook-notice.sh
. "$HERE/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
out="$(printf '%s' "$payload" | GATE_DIR="$HERE" python3 "$HERE/filed_issue_session.py" 2>"$err")"
rc=$?
if [ "$rc" -ne 0 ]; then
  hook_allow_notice "FILED ISSUE CHECK DID NOT RUN: check-filed-issue-session.sh failed (rc=$rc), so whether the issue just filed names this session was not read back from GitHub. $(tr '\n' ' ' <"$err" 2>/dev/null)"
fi
printf '%s' "$out"
exit 0
