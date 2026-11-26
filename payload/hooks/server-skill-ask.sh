#!/usr/bin/env bash
#
# server-skill-ask.sh
# Claude Code PreToolUse(Skill) hook: ask Dan before a skill shipped by an MCP server loads
# (claude-config#3615).
#
# An MCP server can ship skills beside its tools. In auto mode, the default here, such a skill
# loads with no prompt: Claude Code's documentation says "The classifier decides whether the skill
# loads, without reading it", and "Skills can direct Claude to run code. Servers can change skills
# at any time." Dan accepted on 2026-11-25, in the article review picker, "Ask before a server's
# skill loads".
#
# WHAT IS ASKED ABOUT (permissionDecision "ask", which puts the call in front of Dan, in auto mode
# too) is lib/server-skills.py's rule, written there in full: a Skill call whose skill carries a
# server's name form (<server>:<skill>, claude_ai_<name>:<skill>, plugin_<plugin>_<server>:<skill>,
# mcp__<server>__<skill>) and is not found on this Mac as an installed plugin's skill or a
# directory's own. The question names the skill and the server, and says its text is the server's
# and can change at any time. Dan's own skills, bundled ones, ones synced from claude.ai and an
# installed plugin's pass in silence.
#
# A SKILL DAN TYPES is never seen here: Claude Code's documentation says a typed /name "bypasses
# PreToolUse", so this hook runs only when Claude calls the Skill tool, and never asks Dan about a
# command he typed himself.
#
# WHY A HOOK AND NOT A permissions.ask RULE, which is what the issue's text names. The sync carries
# no ask rule to either Mac. The one permission setting it shares is permissions.deny, for a fixed
# list of rules (claude-config#3686). An ask rule in settings.shared.json makes the pull refuse
# that whole file, saying such a rule stays each Mac's own (read in claude-sync on 2026-11-26), and
# one in settings.hooks.json is dropped without a word (measured 2026-11-26 for claude-config#3618,
# before the deny rules were shared). Carrying an ask rule means a new entry on the sync's list of
# shared settings, which is Dan's to sign off. A hook already reaches both Macs, and needs no list
# of server names.
#
# WHILE DAN IS ASLEEP the call is refused, with the reason, and never asked about; and when whether
# he is asleep cannot be told it is refused too. That rule is lib/ask-awake.sh's.
#
# FAIL CLOSED. What cannot be read is stopped, never passed: a Skill call naming no skill, a
# payload that does not parse and names the Skill tool or no tool whole, and, with python3 or
# lib/server-skills.py missing, every Skill call the screen below does not pass. The registration
# carries onFailure block, so a crash or a timeout stops the call.
#
# THE SCREEN. It runs on every Skill call, so it leaves before python3 starts for the ordinary one:
# a payload naming the Skill tool once and one skill once, whose name is plain letters, digits,
# dot, underscore and hyphen, does not start mcp__, and whose text holds no mcp__ anywhere. No
# server's skill has such a name by the documentation. A payload naming one other tool leaves too.
#
# An empty payload is passed in silence (#1922's decision). Every path leaves with status 0: a
# refusal is a decision in the JSON, never a failing exit.
#
# NOT ESTABLISHED: no server skill has ever loaded on either Mac, so the name forms are the
# documentation's (read 2026-11-26) and no real payload for one has been seen.

set -uo pipefail

payload="$(cat 2>/dev/null || true)"
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"

[ -n "$payload" ] || exit 0

# The payload is matched under LC_ALL=C too, so a byte that is not UTF-8 hides no word after it
# (claude-config#1885).
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }
# plain_name <name>: letters, digits, dot, underscore and hyphen only, read as bytes so no letter
# of another alphabet counts as one of these.
plain_name() { local LC_ALL=C; [[ $1 =~ ^[A-Za-z0-9_.-]+$ ]]; }

# The screen. Anything it does not pass goes to python3, which reads the payload whole.
tool=""
named=""
case "$payload" in
  *'"tool_name"'*'"tool_name"'*) ;;   # two such keys: which is the call's is python3's to say
  *)
    if payload_match "$payload" '"tool_name"[[:space:]]*:[[:space:]]*"([^"\]*)"'; then tool="${BASH_REMATCH[1]}"; fi ;;
esac
if [ -n "$tool" ] && [ "$tool" != "Skill" ]; then exit 0; fi
if [ "$tool" = "Skill" ]; then
  shopt -s nocasematch
  case "$payload" in *mcp__*) has_server_word=1 ;; *) has_server_word=0 ;; esac
  shopt -u nocasematch
  case "$payload" in
    *'"skill"'*'"skill"'*) ;;
    *)
      if [ "$has_server_word" -eq 0 ] && payload_match "$payload" '"skill"[[:space:]]*:[[:space:]]*"([^"\]*)"'; then
        named="${BASH_REMATCH[1]}"
        if plain_name "$named"; then exit 0; fi
      fi ;;
  esac
fi

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

WHY="Dan decided on 2026-11-25 that a skill shipped by an MCP server waits for his yes before it loads (claude-config#3615)"

# decide <kind of call> <what it is>: the question while Dan is awake, a refusal while he is
# asleep or when that cannot be told, which is lib/ask-awake.sh's rule.
decide() {
  # shellcheck source=lib/ask-awake.sh
  if . "$HOOK_DIR/lib/ask-awake.sh" 2>/dev/null; then
    ask_awake_or_refuse server-skill-ask.sh "$1" "$2 $WHY"
  else
    hook_deny_json "server-skill-ask.sh refused $1: $2 $WHY, and whether Dan is asleep could not be told, so it could not be asked about either: at night sleep mode answers such a question itself. lib/ask-awake.sh is missing beside this hook. A pull of the shared config puts it back, then send the call again."
  fi
  exit 0
}

# The classifier is python3. Without it, or without the library that holds the rule, no name can be
# read against the rule, so every call the screen did not pass is stopped, naming what is missing.
shown="${named:-a skill this hook could not name}"
shown="${shown:0:200}"
if ps_reader_missing python3; then
  decide "this Skill call" "$shown could not be read against the rule, because python3 is not on PATH and it is what tells a server's skill from one kept on this Mac. Install python3."
fi
if [ ! -r "$HOOK_DIR/lib/server-skills.py" ]; then
  decide "this Skill call" "$shown could not be read against the rule, because lib/server-skills.py is missing beside this hook and it holds the rule."
fi

# -S: the classifier uses the standard library only, and the site module is time on every start.
US=$'\x1f'
out="$(printf '%s' "$payload" | python3 -I -B -S "$HOOK_DIR/lib/server-skills.py" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ]; then
  case "$out" in
    '') exit 0 ;;
    "ask$US"*"$US"*)
      rest="${out#ask$US}"
      decide "${rest%%"$US"*}" "${rest#*"$US"}" ;;
  esac
fi
# python3 itself failed, or printed something that is no verdict: fail closed, since nothing read
# the call.
decide "this Skill call" "$shown could not be read against the rule, because lib/server-skills.py failed (python3 left with status $rc)."
