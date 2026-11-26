#!/usr/bin/env bash
#
# connector-change-ask.sh
# Claude Code PreToolUse(mcp__.*) hook: ask Dan before a connector tool deletes something or changes
# a live setting in Regal, Better Stack or Cal (claude-config#3618).
#
# Database writes stop for Dan (db-write-ask.sh) and Slack messages are saved as drafts. For these
# three connectors a delete, or a change to something live, was decided by auto mode's check alone:
# in the 30 days to 2026-11-25 it let 7 writes to Regal and Better Stack through with nobody asked,
# by the issue's count. Dan chose that day "Ask before live deletes and changes", and for the rest
# of those connectors' writes "Keep it to deletes (Recommended)".
#
# WHAT IS ASKED ABOUT (permissionDecision "ask", which puts the call in front of Dan, in auto mode
# too) is lib/connector-changes.py's rule, written there in full: on a server whose name holds
# regal, betterstack or the word cal, a tool whose own name holds delet, remov, cancel, reset or
# paus, and on Regal also update-journey, update-campaign, save-agent-live and
# update-routing-rule-set. The question names the connector, the tool, what it does by its name,
# and what it was called with. Every other tool of those servers, and every other server, is
# passed in silence: reads, creates and ordinary updates stay with auto mode's check.
#
# WHY A HOOK AND NOT A permissions.ask RULE, which is what the issue's text names. The sync carries
# no permission rule to either Mac: a rule in settings.shared.json makes the pull refuse that whole
# file, and one in settings.hooks.json is dropped without a word (measured 2026-11-26). Carrying one
# means a new entry on the sync's list of shared settings, which is Dan's to sign off. A hook
# already reaches both Macs, asks the same question, can match a server by a part of its name, and
# its matching can be run by handing it a call, which a rule's cannot.
#
# WHILE DAN IS ASLEEP (lib/sleep.sh's sleep_active) the call is refused, with the reason, and never
# asked about (permissionDecision "deny"). A question is not put to Dan at night, and an ask alone
# would not hold: sleep mode refuses a claude.ai connector's write tools outright, but answers a
# session's own permission prompt yes for any other server (mods/scope-modes/hooks/overnight.ts
# lists only mcp__claude_ai_ and mcp__posthog__, read 2026-11-26), which is where a plugin's server,
# Better Stack's on the work MacBook, sits. Awake, nothing differs.
#
# FAIL CLOSED. What cannot be read is stopped, never passed: asked about while Dan is awake and
# refused while he is asleep. That is a name on one of these servers with no tool after it; a
# payload that is not a tool call whose text names a tool the rule asks about, or holds no tool
# name whole and names one of the three connectors (a name cut short cannot be judged by its
# verb); and, with lib/connector-changes.py missing or failing, every call to a server whose name
# holds regal, better or cal, a read included, naming what is missing. Without lib/sleep.sh, or
# without python3 (which reads both the rule and the sleep record), whether Dan is asleep cannot
# be told, and every such call is refused and never asked about, saying which is missing: a
# question would be the one answer sleep mode can say yes to at night. The registration carries
# onFailure block, so a crash or a timeout stops the call.
#
# THE SCREEN. It runs on every MCP call, so it leaves before python3 starts unless the tool's name
# holds regal, better or cal in any case, which every name the rule can ask about holds.
#
# A payload naming no such tool is passed in silence, as is an empty one (#1922's decision). Every
# path leaves with status 0: a refusal is a decision in the JSON, never a failing exit.

set -uo pipefail

payload="$(cat 2>/dev/null || true)"
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"

# The payload is matched under LC_ALL=C too, so a byte that is not UTF-8 hides no word after it
# (claude-config#1885).
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }

case "$payload" in *mcp__*) ;; *) exit 0 ;; esac
# The tool the call names, when the payload names one that is an MCP tool. Otherwise the whole text
# is screened, so a payload this cannot read is never passed on the strength of a field it guessed.
tool=""
if payload_match "$payload" '"tool_name"[[:space:]]*:[[:space:]]*"(mcp__[^"\]*)"'; then tool="${BASH_REMATCH[1]}"; fi
# A text holding that key twice (a call whose input has a tool_name of its own) does not say which
# is the call's: the first found may be the input's, so the whole text is screened and python3,
# which reads the top level one, decides.
case "$payload" in *'"tool_name"'*'"tool_name"'*) tool="" ;; esac
seen="${tool:-$payload}"
shopt -s nocasematch
case "$seen" in *regal*|*better*|*cal*) screened=1 ;; *) screened=0 ;; esac
shopt -u nocasematch
[ "$screened" = 1 ] || exit 0

# Every word this hook prints is built by lib/hook-notice.sh, valid whatever the call holds (#1906).
# Without the library it still decides, keeping only characters that need no escaping.
# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || {  # the library is missing
  plain_decision() { printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "%s", "permissionDecisionReason": "%s (lib/hook-notice.sh is missing beside this hook)"}}\n' "$1" "${2//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; }
  hook_ask_json() { plain_decision ask "$1"; }
  hook_deny_json() { plain_decision deny "$1"; }
}

# Cleaned by the shared reader before python3 parses it (claude-config#1944). Without the library
# the payload is read as it came, and python3 is looked for directly.
if . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null; then
  payload="$(ps_clean_payload "$payload")"
else
  ps_reader_missing() { ! command -v "$1" >/dev/null 2>&1; }
fi
[ -n "$payload" ] || exit 0

WHY="Dan decided on 2026-11-25 that a connector tool that deletes or changes something live waits for his yes (claude-config#3618)"

# decide <kind of call> <what it is and does>: the question while Dan is awake, a refusal while he
# is asleep. The sleep record is read only here, when there is something to ask, so a call that
# passes costs nothing more.
decide() {
  local asleep=0 untold=""
  # Whether Dan is asleep is lib/sleep.sh's answer, which it reads with python3. With either gone
  # nothing here can tell, and a question is the wrong answer to that: at night sleep mode says yes
  # to it for any server that is not a claude.ai connector. So the call is refused, saying which.
  # shellcheck source=lib/sleep.sh
  if ps_reader_missing python3; then
    untold="python3 is not on PATH, and lib/sleep.sh reads the sleep record with it. Install python3"
  elif . "$HOOK_DIR/lib/sleep.sh" 2>/dev/null; then
    sleep_active && asleep=1
  else
    untold="lib/sleep.sh is missing beside this hook. A pull of the shared config puts it back"
  fi
  if [ -n "$untold" ]; then
    hook_deny_json "connector-change-ask.sh refused $1: $2 $WHY, and whether Dan is asleep could not be told, so it could not be asked about either: at night sleep mode answers such a question itself. $untold, then send the call again."
  elif [ "$asleep" -eq 1 ]; then
    hook_deny_json "connector-change-ask.sh refused $1 because Dan is asleep (sleep mode is on): $2 $WHY, and nothing is asked at night. Do not send it again tonight or reach the same end another way: note it for the morning and go on with work that does not need it."
  else
    hook_ask_json "connector-change-ask.sh asks before $1: $2 $WHY."
  fi
  exit 0
}

# The classifier is python3. Without it no name can be read against the rule, so every call the
# screen let through is stopped, a read included, naming what is missing: refused, since decide
# cannot read the sleep record without python3 either. Without the library that holds the rule it
# is asked about, or refused while Dan is asleep.
named="${tool:-a tool this hook could not name}"
if ps_reader_missing python3; then
  decide "this call" "$named could not be read against the rule, because python3 is not on PATH and it is what tells which Regal, Better Stack and Cal tools delete or change something live. Install python3."
fi
if [ ! -r "$HOOK_DIR/lib/connector-changes.py" ]; then
  decide "this call" "$named could not be read against the rule, because lib/connector-changes.py is missing beside this hook and it holds the rule."
fi

# -S: the classifier uses the standard library only, and the site module is time on every start.
US=$'\x1f'
out="$(printf '%s' "$payload" | python3 -I -B -S "$HOOK_DIR/lib/connector-changes.py" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ]; then
  case "$out" in
    '') exit 0 ;;
    "ask$US"*"$US"*)
      rest="${out#ask$US}"
      decide "${rest%%"$US"*}" "${rest#*"$US"}" ;;
  esac
fi
# python3 itself failed, or printed something that is no verdict: fail closed for everything the
# screen let through, since nothing read it.
decide "this call" "$named could not be read against the rule, because lib/connector-changes.py failed (python3 left with status $rc)."
