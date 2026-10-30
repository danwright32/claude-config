#!/usr/bin/env bash
#
# hook-notice.sh: say something to the person from a hook, in the one channel Claude Code shows
# them, as JSON that is valid whatever the text holds. Sourced, never run (claude-config#1906,
# #1912). The ONE place a hook script builds a systemMessage: test-hook-notice.sh fails on a hook
# that writes the field any other way.
#
# WHY IT EXISTS. Claude Code discards a hook's stderr on exit 0: the hooks documentation says
# "Claude never sees stderr from a hook that exits 0" and sends it to the debug log, and the exit
# code table shows nothing to the person either. So a gate that let a call through on exit 0 and
# printed "DID NOT RUN" on stderr said it to nobody, and a check that was off looked exactly like a
# check that passed (L98). The gates that knew this said their notice with exit 1, the non blocking
# error whose first stderr line the transcript shows (#735, #1065), and that kept them from being
# registered with "onFailure": "block" (#1899), which treats every exit but 0 and 2 as a failure and
# so refuses the call. A JSON systemMessage on exit 0 reaches the person ("Warning message shown to
# the user", same documentation) and is not a failure, so one shape serves both.
#
# WHICH EVENTS IT SERVES. The documentation says systemMessage is shown to the user except on the
# events whose own section says otherwise, and it names InstructionsLoaded, Setup, MessageDisplay,
# Notification and SessionEnd as discarding it. So it is for PreToolUse, PostToolUse,
# UserPromptSubmit, SessionStart, Stop and the like, never for those five.
#
# THE RULES IT KEEPS, each a way the call it allows could otherwise be refused once the hook carries
# onFailure block (the documentation lists invalid output among the failures):
#   * stdout holds exactly one JSON object, so a hook calls this once, as its last word, and has
#     printed nothing to stdout before it. hook_allow_notice exits, which makes a second call
#     impossible.
#   * the object is valid whatever the text holds: quotes, backslashes, newlines, tabs, control
#     characters. Python's json module writes it when python3 is on PATH, replacing bytes that are
#     not UTF-8; without python3 (the very fault some of these notices report) an encoder in bash
#     alone does, which escapes the JSON specials and drops every other control character. Bytes
#     that are not UTF-8 pass through that encoder unchanged.
#   * each text is cut to HN_MAX characters, under the 10,000 Claude Code caps a systemMessage and
#     an additionalContext at, and says so, so the cut is chosen here rather than somewhere unseen.
#
#   hook_notice_json <text> [<event> [<context>]]
#       print {"systemMessage": <text>}. Given an event, also hand the session <context> (default
#       <text>) as hookSpecificOutput.additionalContext for that event.
#   hook_allow_notice <text> [<event> [<context>]]
#       the same, with <text> on stderr too for the debug log, then exit 0. The call goes ahead.
#   hook_notice_verdict <stdout> <ERE>
#       for the suites: print why <stdout> is not exactly one JSON object whose systemMessage
#       matches <ERE> (Python's re), or nothing when it is.
#
# A HOOK SOURCES IT WITH A FALLBACK, the same three lines in each, so a missing library cannot leave
# hook_allow_notice undefined, where "command not found" would carry on into the gate's own logic
# instead of letting the call through:
#
#   . "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
#     printf '%s\n' "$1" >&2
#     printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
#
# The fallback keeps only characters that need no escaping, so its JSON is valid whatever the text
# held. test-hook-notice.sh holds every registered hook that calls hook_allow_notice to that form.

HN_MAX=9000

# _hn_string <text>: <text> as the inside of a JSON string, cut to HN_MAX, in bash alone.
_hn_string() {
  local s="$1" cut=""
  if [ "${#s}" -gt "$HN_MAX" ]; then
    s="${s:0:$HN_MAX}"
    cut=" ... (cut short at $HN_MAX characters; the whole notice is in the debug log)"
  fi
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  # Every other control character would make the string invalid JSON, so it is dropped. Done after
  # the escapes above, which are all printable, and in bash itself, since a PATH that has lost
  # python3 may have lost tr with it.
  s="${s//[[:cntrl:]]/}"
  printf '%s%s' "$s" "$cut"
}

hook_notice_json() {
  local text="$1" event="${2:-}" context="${3-$1}"
  case "$event" in *[!A-Za-z]*) event="" ;; esac
  if command -v python3 >/dev/null 2>&1; then
    # Bytes in, so text that is not UTF-8 is replaced rather than refused, and ASCII out, so the
    # object survives any locale between here and Claude Code. The two texts travel in the
    # environment, as bytes, so neither needs a delimiter that the other could contain.
    HN_TEXT="$text" HN_CONTEXT="$context" HN_EVENT="$event" HN_MAX="$HN_MAX" python3 -c '
import json, os
n = int(os.environ["HN_MAX"])
def cut(b):
    m = b.decode("utf-8", "replace")
    if len(m) > n:
        m = m[:n] + " ... (cut short at %d characters; the whole notice is in the debug log)" % n
    return m
out = {"systemMessage": cut(os.environb[b"HN_TEXT"])}
event = os.environ["HN_EVENT"]
if event:
    out["hookSpecificOutput"] = {"hookEventName": event, "additionalContext": cut(os.environb[b"HN_CONTEXT"])}
print(json.dumps(out))' 2>/dev/null && return 0
  fi
  if [ -n "$event" ]; then
    printf '{"systemMessage": "%s", "hookSpecificOutput": {"hookEventName": "%s", "additionalContext": "%s"}}\n' \
      "$(_hn_string "$text")" "$event" "$(_hn_string "$context")"
  else
    printf '{"systemMessage": "%s"}\n' "$(_hn_string "$text")"
  fi
}

hook_allow_notice() {
  printf '%s\n' "$1" >&2
  hook_notice_json "$@"
  exit 0
}

hook_notice_verdict() {
  HN_OUT="$1" HN_WANT="$2" python3 -c '
import json, os, re, sys
raw = os.environ["HN_OUT"]
try:
    d = json.loads(raw)
except Exception as e:
    print("stdout is not exactly one JSON object (%s): %r" % (e, raw[:300])); sys.exit()
m = d.get("systemMessage") if isinstance(d, dict) else None
if not isinstance(m, str):
    print("stdout carries no systemMessage: %r" % raw[:300]); sys.exit()
if not re.search(os.environ["HN_WANT"], m):
    print("the systemMessage does not say /%s/: %r" % (os.environ["HN_WANT"], m[:300]))' 2>&1
}
