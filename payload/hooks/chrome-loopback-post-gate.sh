#!/usr/bin/env bash
#
# chrome-loopback-post-gate.sh
# Claude Code PreToolUse(mcp__claude-in-chrome__(javascript_tool|browser_batch)) hook: refuse a
# Claude in Chrome script that names a loopback address beside a network call (claude-config#2774).
# The tools in that line are where the settings must register this hook and nowhere else, and
# test-chrome-loopback-post-gate.sh checks it.
#
# Twice (2026-11-01 and 2026-11-11) a session capturing a production admin page in Dan's Chrome
# started a receiver on this Mac's loopback address and had the page post a copy of itself there. The
# page's content security policy refused the request and reported it, which paged Dan with nothing
# for him to act on. The design rounds skill now has the page save its capture as a download, which
# sends nothing over the network; a rule that lives only in a prompt is a hope (L27), so this stands
# behind it. It judges the main session and subagents alike: the main session made both calls.
#
# WHAT IT REFUSES: a javascript tool script (alone, or as a call inside browser_batch, a full tool
# name there read as its short one) whose text holds BOTH a loopback host (127.x.x.x, localhost,
# [::1], 0.0.0.0, any case) AND a network call (fetch, XMLHttpRequest, sendBeacon, WebSocket,
# EventSource). Either alone goes through: a script that compares location.hostname with
# "localhost", or one that fetches the page's own API by a relative path.
#
# WHAT IT DOES NOT SEE, named so nobody reads the gate as wider than it is (L400): a request built
# another way (an image's src, a form's action, a URL assembled from pieces at run time), and a
# receiver on any address other than loopback. The skill's rule covers those: a capture never posts
# the page anywhere. A script on a local dev page that fetches its own server by an absolute
# loopback URL is refused too; the refusal says to use a relative path, which reaches the same place.
#
# Fails OPEN on a payload it cannot read, loudly, for the tab gate's reason
# (chrome-subagent-tab-gate.sh): Claude Code writes the payload, so an unreadable one means the
# platform changed, and refusing would take the browser from every caller with no remedy inside the
# session. It says so in a systemMessage (lib/hook-notice.sh): Claude Code discards a PreToolUse
# hook's stderr on exit 0 (#1906).

set -uo pipefail

payload="$(cat 2>/dev/null || true)"
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

# Cleaned by the shared reader before python3 parses it: a lone surrogate escape survives the parse
# and raises when text is written back out (claude-config#1944).
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && payload="$(ps_clean_payload "$payload")"

verdict="$(printf '%s' "$payload" | python3 -c '
import json, re, sys
sys.stdout.reconfigure(errors="replace")
PREFIX = "mcp__claude-in-chrome__"
LOOPBACK = re.compile(r"(?<![A-Za-z0-9.-])(127(?:\.\d{1,3}){3}|localhost|\[::1\]|0\.0\.0\.0)(?![A-Za-z0-9-])", re.I)
NETWORK = re.compile(r"\b(fetch|XMLHttpRequest|sendBeacon|WebSocket|EventSource)\b")
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception as e:
    print("unreadable\t" + type(e).__name__); sys.exit()
if not isinstance(d, dict):
    print("unreadable\tthe payload is not a JSON object"); sys.exit()
tool = d.get("tool_name")
if not isinstance(tool, str) or not tool.startswith(PREFIX):
    print("allow\t"); sys.exit()
ti = d.get("tool_input")
if not isinstance(ti, dict):
    print("unreadable\tthe tool input is not a JSON object"); sys.exit()

class Unreadable(Exception):
    pass

def offence(inp):
    """The loopback host a script sends to, or None."""
    if not isinstance(inp, dict):
        raise Unreadable("a javascript call input is not a JSON object")
    text = inp.get("text")
    if not isinstance(text, str):
        raise Unreadable("a javascript call carries no script text")
    host = LOOPBACK.search(text)
    if host and NETWORK.search(text):
        return host.group(0)
    return None

short = tool[len(PREFIX):]
try:
    if short == "javascript_tool":
        host = offence(ti)
        print(("refuse\t" + tool + "\t" + host) if host else "allow\t"); sys.exit()
    if short == "browser_batch":
        actions = ti.get("actions")
        if not isinstance(actions, list):
            print("allow\t"); sys.exit()
        for i, a in enumerate(actions):
            name = a.get("name") if isinstance(a, dict) else None
            name = name if isinstance(name, str) else ""
            inner = name[len(PREFIX):] if name.startswith(PREFIX) else name
            if inner != "javascript_tool":
                continue
            host = offence(a.get("input"))
            if host:
                print("refuse\t" + tool + " (call " + str(i + 1) + " in it)\t" + host); sys.exit()
        print("allow\t"); sys.exit()
except Unreadable as e:
    print("unreadable\t" + str(e)); sys.exit()
print("allow\t")
' 2>&1)"

case "$verdict" in
  refuse$'\t'*)
    rest="${verdict#*$'\t'}"
    tool="${rest%%$'\t'*}"
    host="${rest#*$'\t'}"
    echo "REFUSED: $tool runs a script in the page that sends to $host, a loopback address. A production page's content security policy refuses that request and reports it, and twice (2026-11-01 and 2026-11-11) a page posting a copy of itself to a receiver on this Mac paged Dan with nothing to act on (claude-config#2774). Never post a page to any receiver. To capture a page, run ~/.claude/skills/design-rounds/capture-chrome.js with {saveAs: \"chrome-<round>-<yyyymmddhhmm>.html\"}: the page saves the capture into ~/Downloads as a download, sending nothing over the network (the design rounds skill gives the steps). If the page is itself on that address (a local dev server), fetch its own server by a relative path instead." >&2
    exit 2
    ;;
  allow$'\t'*)
    exit 0
    ;;
  unreadable$'\t'*)
    hook_allow_notice "CHROME LOOPBACK POST GATE DID NOT RUN: chrome-loopback-post-gate.sh could not read the hook payload (${verdict#*$'\t'}), so this Claude in Chrome script was let through without checking whether it sends to a loopback address."
    ;;
  *)
    hook_allow_notice "CHROME LOOPBACK POST GATE DID NOT RUN: chrome-loopback-post-gate.sh failed (${verdict//$'\n'/ }), so this Claude in Chrome script was let through without checking whether it sends to a loopback address."
    ;;
esac
