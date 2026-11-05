#!/usr/bin/env bash
#
# slack-drafts-only-gate.sh
# Claude Code PreToolUse(Bash|mcp__.*slack.*|mcp__.*Slack.*) hook: refuse every Slack send or schedule,
# so a session can only save drafts (claude-config#2302). The tools in that line are where the settings
# register it, and test-hook-coverage.sh holds them to it (#413). Two spellings rather than a
# bracketed class, because that check reads each declared pattern as a tool name its matcher must
# match, and a class never matches its own text.
#
# On 2026-11-05 two sessions on the work MacBook each posted a Slack reply after Dan picked a "Post"
# option in a picker, and he did not know either had gone out; one had reworded the text after he
# chose, so what posted was never shown to him. Dan: "it should only ever save as draft in slack,
# never send directly." The rule in CLAUDE.md alone did not stop it: a rule that lives only in a
# prompt is a hope (L27).
#
# The rule and its message live in slack_drafts_only_gate.py; this is the wrapper. It refuses:
#   * slack_send_message, slack_schedule_message (and slack_post_message, slack_reply_to_thread) from
#     ANY tool whose name holds "slack": the Slack plugin, the claude.ai connector, and one added later.
#     slack_send_message_draft and every reading tool pass.
#   * a Bash command that makes the request: curl, wget and the like aimed at chat.postMessage,
#     chat.scheduleMessage, chat.postEphemeral, chat.meMessage or hooks.slack.com; inline code or a
#     script fed on stdin holding one; a script file the command runs that holds one (a project's own
#     alert scripts too). A command that only mentions an endpoint (grep, echo, a test) passes.
#   The one exemption is /nudge, skills/nudge/nudge.py beside this hooks folder by its real path (it
#   posts as Nudge Bot, never as Dan, and runs only when he types it; his choice, 2026-11-05). A copy
#   of it anywhere else is refused. There is no override variable, on purpose.
#
# Why a hook and not a permissions deny list: claude-sync carries the hooks block to both Macs and
# leaves each Mac's permissions alone, so a deny entry would need a new sync feature, while this is
# enforced on both by what already travels. A hook refuses each call; it does not take the tool out
# of the session's list as a deny entry would.
#
# Fails CLOSED. A payload it cannot read that names a send route is refused (lib/push-scope.sh
# ps_unparsed_refuse, #1922); one naming none passes, as every refusing gate does, and so does an
# empty one. python3 missing or crashing on a call it would judge is refused too: letting a send
# through unjudged is exactly the harm this exists to stop, and the remedy (save a draft) is always
# open.

set -uo pipefail

payload="$(cat 2>/dev/null || true)"
case "$payload" in *[![:space:]]*) ;; *) exit 0 ;; esac

# Case blind from here: an endpoint is chat.postMessage however a session spells it, and a tool name
# could arrive as Slack or slack. Bash 3.2 has nocasematch for case and [[ ]] both.
shopt -s nocasematch

# Every Bash call reaches this hook, so the rest skip the python3 start (about 36 ms with the shell
# reader, measured 2026-11-05) unless the payload could post: it names an endpoint or a Slack tool,
# a script file, an interpreter, or a path run from here. Every imprecision runs the gate rather than
# skipping it: the whole payload is read, cwd and description included.
MARKERS='chat[._](postmessage|schedulemessage|postephemeral|memessage)|hooks\.slack\.com|slack_webhook|slack_(send|schedule|post)_message|slack_reply_to_thread'
SCRIPTS='\.(py|sh|bash|zsh|js|mjs|cjs|ts|mts|rb|pl|php|command)([^A-Za-z0-9_]|$)'
RUNS='(^|[^A-Za-z0-9_])(python[0-9.]*|pypy[0-9.]*|node|nodejs|ruby|perl|php|deno|bun|bunx|npx|pnpx|tsx|ts-node|osascript|uv|source)([^A-Za-z0-9_.]|$)|\./'
# Under a UTF-8 locale bash's =~ stops at a byte that is not UTF-8, so a word after one would read as
# absent and the call would pass unjudged (claude-config#1885); the C locale is tried as well.
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }
if ! { payload_match "$payload" "$MARKERS" || payload_match "$payload" "$SCRIPTS" || payload_match "$payload" "$RUNS"; }; then
  exit 0
fi

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"

couldnt() {
  printf 'BLOCKED: slack-drafts-only-gate.sh could not judge this call (%s), so whether it sends a Slack message was not checked, and a send is the one thing this gate exists to stop (claude-config#2302). To put a message in Slack, call slack_send_message_draft with the same channel and thread, then tell Dan where the draft is. If this call does not touch Slack, the gate itself is broken: say so to Dan.\n' "$1" >&2
  exit 2
}

# The shared reader cleans the payload before python3 parses it: a lone surrogate escape survives the
# parse and raises when written back out (claude-config#1944). It is optional: without it the payload
# is read as it came, and an unreadable one is judged by the plain match below.
have_scope=""
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && { have_scope=1; payload="$(ps_clean_payload "$payload")"; }

command -v python3 >/dev/null 2>&1 || couldnt "python3 is not on the PATH"

out="$(printf '%s' "$payload" | GATE_DIR="$HOOK_DIR" python3 "$HOOK_DIR/slack_drafts_only_gate.py" 2>&1)"
rc=$?
verdict="${out%%$'\n'*}"
detail=""
case "$out" in *$'\n'*) detail="${out#*$'\n'}" ;; esac

if [ "$rc" -ne 0 ]; then
  couldnt "slack_drafts_only_gate.py failed, rc=$rc: ${out//$'\n'/ }"
fi

case "$verdict" in
  allow) exit 0 ;;
  refuse) printf '%s\n' "$detail" >&2; exit 2 ;;
  unreadable)
    # The words a send route is written in, matched case blind (nocasematch above).
    if [ -n "$have_scope" ]; then
      ps_unparsed_refuse "$payload" slack-drafts-only-gate.sh - "a Slack send" \
        '*chat[._]postmessage*' '*chat[._]schedulemessage*' '*chat[._]postephemeral*' '*chat[._]memessage*' \
        '*hooks.slack.com*' '*slack_webhook*' '*slack_send_message*' '*slack_schedule_message*' \
        '*slack_post_message*' '*slack_reply_to_thread*'
    fi
    if payload_match "$payload" "$MARKERS"; then
      printf 'BLOCKED: slack-drafts-only-gate.sh could not read its hook payload as a call (%s), and the payload names a Slack send route, so whether this sends a Slack message could not be checked (claude-config#2302, #1922). Save a draft with slack_send_message_draft instead.\n' "$detail" >&2
      exit 2
    fi
    exit 0
    ;;
  *) couldnt "slack_drafts_only_gate.py said nothing it should: ${out//$'\n'/ }" ;;
esac
