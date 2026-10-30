#!/usr/bin/env bash
# Block `gh issue create` unless the issue carries a milestone, a priority level and
# at least one category label. Also block gh issue edit and comment, and gh pr create, edit
# and comment, when their --body-file is one the gate cannot read (claude-config#1435).
#
# The rules, the messages and the per-rule overrides all live in issue_field_gate.py.
# This is only the wrapper: read the payload, run the gate, and make a crash visible.
#
# It replaced three separate hooks that shared everything except their rule, which
# also meant three Python processes on every Bash command Claude ran, not just the
# ones filing issues.
#
# A command it cannot read is refused when its text names a command the gate judges, saying
# which quote never closes and where, and passes untouched when it names none
# (claude-config#1485). A --body-file it cannot read in a command it did parse is refused
# (claude-config#1416).
#
# Deliberate overrides, each waiving ONE rule and only for the command it prefixes:
#   SKIP_MILESTONE_CHECK=1 / SKIP_PRIORITY_CHECK=1 / SKIP_CATEGORY_CHECK=1 /
#   SKIP_OPEN_QUESTIONS_CHECK=1 / SKIP_BODY_FILE_CHECK=1 / SKIP_SESSION_LINE_CHECK=1

set -uo pipefail

payload="$(cat)"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hook-notice.sh
. "$HERE/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

# The shared reader, which cleans the payload before the gate's python3 parses it: a lone surrogate
# escape there raised when the command was written back out (claude-config#1944). A payload nothing
# can parse used to pass in silence (the python3 half returns 0 on one), so it is judged by its raw
# text, as a missing library is in the other gates (#1922). Without the library this gate runs as it
# did before, its own python3 reading the payload as it came, and a broken gate still says so below
# (#1906): the library is an addition to this gate, never a new way for it to stop.
if . "$HERE/lib/push-scope.sh" 2>/dev/null; then
  payload="$(ps_clean_payload "$payload")"
  # One naming none of them goes on to the python3 half, exactly as before.
  if ! ps_parse_payload "$payload" raw >/dev/null; then
    case "$payload" in
      *"issue create"*|*"issue edit"*|*"issue comment"*|*"pr create"*|*"pr edit"*|*"pr comment"*)
        ps_unparsed_refuse "$payload" require-issue-fields.sh - \
          "a gh issue create missing its milestone, priority or category, or a gh command posting a body from a file that is not there" \
          '*issue create*' '*issue edit*' '*issue comment*' '*pr create*' '*pr edit*' '*pr comment*' ;;
    esac
  fi
fi

# A crash here must not block work, but it must not be invisible either: a silent
# failure would leave the gate switched off with everything looking normal. So the notice goes
# out as a systemMessage, since Claude Code discards a PreToolUse hook's stderr on exit 0 (#1906).
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
out="$(printf '%s' "$payload" | GATE_DIR="$HERE" python3 "$HERE/issue_field_gate.py" 2>"$err")"
rc=$?

if [ "$rc" -ne 0 ]; then
  hook_allow_notice "ISSUE FIELD GATE DID NOT RUN: require-issue-fields.sh failed (rc=$rc). This issue may be filed without a milestone, a priority or a category. $(tr '\n' ' ' <"$err" 2>/dev/null)"
fi

printf '%s' "$out"
exit 0
