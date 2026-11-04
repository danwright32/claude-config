#!/usr/bin/env bash
# Refuse a gh pr or issue create, edit, comment or review, or a gh api write to issues, pulls or
# comments, whose text names a work organisation or repository, when the repository it posts to is
# public (claude-config#2105).
#
# The rule, the names and the message live in work_names_publish_gate.py. This is only the wrapper:
# skip every command that does not name gh, run the gate, and refuse when the gate itself fails,
# since a privacy gate that did not run is not one that found nothing (L98).
#
# No override: the remedy is always open, rewrite the text.

set -uo pipefail

payload="$(cat)"

# The test the session link gate uses (no-session-link-in-comments.sh, claude-config#1880): gh as a
# word, read from the "command" key on, so a home folder's "wright" never runs the gate. Every
# imprecision runs the gate rather than skipping it.
GH_WORD='(^|[^A-Za-z0-9_]|\\[A-Za-z]|\\u[0-9A-Fa-f]{4})gh([^A-Za-z0-9_]|$)'
may_post() {
  local LC_ALL=C
  local text="$1"
  case "$1" in *'"command"'*) text="${1#*\"command\"}" ;; esac
  [[ "$text" =~ $GH_WORD ]]
}
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE="$(cd "${HERE:-/}" && pwd)"

# A gh a running script makes is judged by the guard on gh (bin/gh), which gh-guard-path.sh puts
# first on the session's PATH at its start (claude-config#2183). A session already running when that
# shipped has no guard in front, and this hook cannot see those writes. It is not refused anything
# more for it: refusing such scripts would stop merge-when-ready.sh, and so every merge on both Macs,
# until each session restarted. It is told so, once, on its first command. The test is a stamp per
# session, so every later command pays one file test; the session's env file is read only before it.
notice=""
sid=""
[[ "$payload" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9-]+)\" ]] && sid="${BASH_REMATCH[1]}"
notice_dir="${WN_SCRIPTS_NOTICE_DIR:-${CLAUDE_HOME:-$HOME/.claude}/state/work-names-scripts-notice}"
if [ -n "$sid" ] && [ ! -e "$notice_dir/$sid" ]; then
  env_dir="${WN_SESSION_ENV_DIR:-$HERE/../session-env}"
  here_p="$(cd "$HERE" && pwd -P)"
  if [ -x "$HERE/bin/gh" ] && grep -q -x -F -e "export PATH=\"$HERE/bin:\$PATH\"" -e "export PATH=\"$here_p/bin:\$PATH\"" "$env_dir/$sid"/*.sh 2>/dev/null; then
    mkdir -p "$notice_dir" 2>/dev/null && : > "$notice_dir/$sid" 2>/dev/null
  else
    notice="Work names check: this session started without the guard on gh in front of its PATH, so gh writes made inside scripts, and through a gh alias it cannot read, are not checked for work organisation or repository names in this session. gh commands typed directly are still checked. Start a new session to have them checked."
  fi
fi
say_notice() {   # the notice, once: stamped, then said as this hook's last word, letting the call through
  mkdir -p "$notice_dir" 2>/dev/null && : > "$notice_dir/$sid" 2>/dev/null
  # shellcheck source=lib/hook-notice.sh
  . "$HERE/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
    printf '%s\n' "$1" >&2
    printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
  hook_allow_notice "$notice" PreToolUse
}

if ! may_post "$payload"; then
  [ -n "$notice" ] && say_notice
  exit 0
fi

# The shared reader cleans the payload before python3 parses it: a lone surrogate escape there raised
# when the text was written back out (claude-config#1944). It loads only past the gh test above, so
# the commonest call never pays for it. Past that test this may be a post, so a library that will not
# load is refused, naming the file (#1900).
# shellcheck source=lib/push-scope.sh
. "$HERE/lib/push-scope.sh" 2>/dev/null || {
  echo "WORK NAME IN PUBLIC TEXT: check-work-names-publish.sh could not load $HERE/lib/push-scope.sh, which cleans this hook's input before it is read, so whether this gh command posts a work organisation or repository name to a public repository could not be checked. Reinstall the hooks with claude-sync pull." >&2
  exit 2
}
payload="$(ps_clean_payload "$payload")"

if ! command -v python3 >/dev/null 2>&1; then
  echo "WORK NAME IN PUBLIC TEXT: python3 is not on PATH, so check-work-names-publish.sh could not tell whether this gh command posts a work organisation or repository name to a public repository. A gate that did not run is not one that found nothing." >&2
  exit 2
fi

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
out="$(printf '%s' "$payload" | GATE_DIR="$HERE" python3 "$HERE/work_names_publish_gate.py" 2>"$err")"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "WORK NAME IN PUBLIC TEXT: check-work-names-publish.sh failed (rc=$rc), so whether this gh command posts a work organisation or repository name to a public repository could not be checked. A gate that did not run is not one that found nothing. $(tr '\n' ' ' <"$err" 2>/dev/null | cut -c1-600)" >&2
  exit 2
fi

# A refusal is said alone, so the notice waits for the next command rather than being lost.
[ -z "$out" ] && [ -n "$notice" ] && say_notice
printf '%s' "$out"
exit 0
