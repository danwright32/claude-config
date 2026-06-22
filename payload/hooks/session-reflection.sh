#!/usr/bin/env bash
# Global Stop hook: after a turn that involved REAL work (any tool use other
# than AskUserQuestion), re-prompt Claude to reflect before it actually stops —
# (1) what it is least sure about, and (2) the biggest thing the user probably
# does not realize about what was just done.
#
# Skips:
#   - trivial chat turns (no tools used since the last genuine user message)
#   - turns whose only tool was AskUserQuestion (Claude was asking the user)
#   - its own continuation (stop_hook_active guard) so it cannot loop
#
# Fails SAFE: any parse/transcript error -> skip (do not fire), to avoid noise.
# No time throttle by design: it fires once per substantive turn. To disable,
# remove its hooks.Stop entry in ~/.claude/settings.json.

set -uo pipefail

input=$(cat)

# Loop guard: don't re-fire on our own (or another Stop hook's) continuation.
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$stop_active" = "true" ] && exit 0

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] || exit 0
[ -f "$transcript" ] || exit 0

# Did the latest turn (since the last genuine user message) use any tool other
# than AskUserQuestion? If not, it was a trivial chat or a question turn -> skip.
worked=$(python3 - "$transcript" <<'PY'
import sys, json

path = sys.argv[1]
SKIP_TOOLS = {"AskUserQuestion"}

try:
    with open(path, "r", encoding="utf-8") as f:
        lines = [ln for ln in f if ln.strip()]
except Exception:
    print("no"); sys.exit(0)

def is_genuine_user(obj):
    # A real human turn: type "user" carrying text, not a tool_result-only entry.
    if obj.get("type") != "user":
        return False
    content = (obj.get("message") or {}).get("content")
    if isinstance(content, str):
        return content.strip() != ""
    if isinstance(content, list):
        return any(isinstance(it, dict) and it.get("type") == "text" for it in content)
    return False

used_work_tool = False
for ln in reversed(lines):
    try:
        obj = json.loads(ln)
    except Exception:
        continue
    if obj.get("type") == "assistant":
        for it in ((obj.get("message") or {}).get("content") or []):
            if isinstance(it, dict) and it.get("type") == "tool_use" and it.get("name") not in SKIP_TOOLS:
                used_work_tool = True
        continue
    if is_genuine_user(obj):
        break
    # tool_result-bearing user messages sit between assistant tool calls -> keep scanning

print("yes" if used_work_tool else "no")
PY
)

[ "$worked" = "yes" ] || exit 0

# decision:block feeds `reason` back to Claude as a continuation instruction.
cat <<'JSON'
{"decision":"block","reason":"FORMAT: open your reply with the SESSION REFLECTION banner — a 3-line double-line box (corners ╔╗╚╝, sides ║, fill ═) labeled SESSION REFLECTION — then answer below it. Emit the box only in your reply; do NOT restate this FORMAT line.\n\nBefore you actually wrap up, answer one question honestly and specifically, and do NOT redo or re-summarize the work itself: What are you least sure about right now? Surface anything you guessed at, assumed, or glossed over without fully thinking through — decisions you made on my behalf, edge cases you did not verify, places the approach could be wrong. Be concrete, not reassuring. Write it in PLAIN LANGUAGE for a product manager, not an engineer: no code or jargon, and explain any technical thing in terms of what it means or what it affects. Keep it brief and pointed; if nothing genuinely applies, say so in one line. Be SUCCINCT: only surface points that need my attention, a decision, or an action — do NOT report things that are purely informational or that you checked and found fine. For EACH uncertainty, ACT — do not merely list it — classifying it three ways: (a) RESOLVE-NOW: if you can settle it yourself with read-only / non-destructive tools (reading files, looking up the current fact or latest version, reading docs or release notes, running a safe check or test), DO it BEFORE printing. If it CLEARS with nothing for me to do, do NOT write it up as a point — at most collapse all cleared checks into one short trailing line (e.g. 'Also checked and cleared: X, Y'); only surface a RESOLVE-NOW as its own numbered point if it found a real problem I need to know about. (b) DECIDE-NOW: if it is really a quick decision or choice I can make to unblock acting now (e.g. remove this now-unused code or leave it; take approach X or Y), POSE IT as a multiple-choice question using the AskUserQuestion tool — the same picker UI you use elsewhere — with concrete options, so we settle it this turn instead of just flagging it; batch several such decisions into one AskUserQuestion call (up to 4) when they co-occur. ALWAYS-PICKER RULE: if your reply leaves ANY open question or choice to me — INCLUDING one you already posed in prose earlier in the same reply (e.g. 'want me to do X, or fold it into Y?') — you MUST end the turn by presenting it as an AskUserQuestion picker with concrete options (prefix each option's label with the point number it answers, e.g. '1.1 ...') so I can answer by selecting. NEVER leave an open question sitting only in prose; convert it to the picker. (c) FLAG: if it genuinely needs me and cannot be settled now (an action only I can take later, anything post-merge or post-deploy, or external), give me ACTIONABLE INSTRUCTIONS — the concrete steps to check or do it (e.g. 'after it deploys, visit /v0 and confirm it redirects to the dashboard'), not just a description of the worry, and say why you cannot do it yourself. Anything with side effects (writing, installing, deploying, pushing) still needs my go-ahead — only auto-run read-only checks. If after all this nothing needs me, say so in ONE short line — never pad with numbered filler. Number each point 1.1, 1.2, and so on so I can refer to it (when the reflection is the only section printed it IS section 1; a single point is just 1.1). NEVER use dashes or bullet points for any list anywhere in your reply — give EVERY item (including side notes, asides, or things you are only flagging) its own number in the 1.x sequence so I can reference any of them. EXCEPTION: if an ISSUE REVIEW also fired this same turn, do NOT print this reflection as its own section — no banner — and instead hand your point(s) to the issue review's SECOND PASS, applying the same verify-or-flag rule there. Print the SESSION REFLECTION banner and answer as your own section ONLY on turns where the issue review did not run."}
JSON
