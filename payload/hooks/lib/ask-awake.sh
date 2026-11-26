#!/usr/bin/env bash
#
# lib/ask-awake.sh
# One answer for every hook that puts a call in front of Dan: ask while he is awake, refuse while he
# is asleep, and refuse when it cannot tell which (claude-config#3618, #3615).
#
# A question is not put to Dan at night, and an ask alone would not hold then: sleep mode answers an
# enrolled session's own permission prompt yes for anything it does not list
# (mods/scope-modes/hooks/overnight.ts, read 2026-11-26), so a question asked at night can be
# answered with nobody there. Whether Dan is asleep is lib/sleep.sh's answer, which it reads with
# python3. With either gone nothing here can tell, and a question is the wrong answer to that, so
# the call is refused, saying which is missing.
#
# Its callers are connector-change-ask.sh and server-skill-ask.sh. The rule lives here once, so
# changing what a hook does when it cannot tell night from day is one edit, not one per hook (L613).
#
#   ask_awake_or_refuse <hook's name> <kind of call> <what it is, and why it waits>
#       prints one PreToolUse decision and returns 0: "ask" while Dan is awake, "deny" while he is
#       asleep or when that could not be told. The caller defines hook_ask_json and hook_deny_json
#       first (lib/hook-notice.sh, or its own plain stand ins when that library is missing), and
#       ps_reader_missing when lib/push-scope.sh is loaded.
#
# The sleep record is read only here, when there is something to ask, so a call that passes costs
# nothing more.

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130), set
# plainly so that what it loads beside itself can be worked out by reading it.
case "${BASH_SOURCE[0]}" in */*) ASK_AWAKE_DIR="${BASH_SOURCE[0]%/*}" ;; *) ASK_AWAKE_DIR=. ;; esac
ASK_AWAKE_DIR="$(cd "${ASK_AWAKE_DIR:-/}" && pwd)"

ask_awake_or_refuse() {
  local hook="$1" kind="$2" what="$3" asleep=0 untold="" nopy=1
  if declare -F ps_reader_missing >/dev/null 2>&1; then
    ps_reader_missing python3 || nopy=0
  elif command -v python3 >/dev/null 2>&1; then
    nopy=0
  fi
  # shellcheck source=sleep.sh
  if [ "$nopy" -eq 1 ]; then
    untold="python3 is not on PATH, and lib/sleep.sh reads the sleep record with it. Install python3"
  elif . "$ASK_AWAKE_DIR/sleep.sh" 2>/dev/null; then
    sleep_active && asleep=1
  else
    untold="lib/sleep.sh is missing beside this hook. A pull of the shared config puts it back"
  fi
  if [ -n "$untold" ]; then
    hook_deny_json "$hook refused $kind: $what, and whether Dan is asleep could not be told, so it could not be asked about either: at night sleep mode answers such a question itself. $untold, then send the call again."
  elif [ "$asleep" -eq 1 ]; then
    hook_deny_json "$hook refused $kind because Dan is asleep (sleep mode is on): $what, and nothing is asked at night. Do not send it again tonight or reach the same end another way: note it for the morning and go on with work that does not need it."
  else
    hook_ask_json "$hook asks before $kind: $what."
  fi
  return 0
}
