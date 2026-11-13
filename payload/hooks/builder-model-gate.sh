#!/usr/bin/env bash
#
# builder-model-gate.sh
# Claude Code PreToolUse(Agent) hook: refuse a BUILDER dispatch that names no model, and say which
# tiers exist (claude-config#2027). The rule's one home is "Which model a builder runs on" in
# skills/orchestrate/SKILL.md; this hook only enforces that a choice was made.
#
# WHY. A rule that lives only in a prompt is a hope (L27). Measured on 2026-11-13 over the personal
# MacBook's transcripts since the tiers changed on 2026-11-09: 8 of 204 builder dispatches named no
# model and ran on the session default with nothing said. The issue's own decision was to build the
# check once any builder dispatch skipped the model.
#
# WHAT IS A BUILDER. The same test the measurement used: an Agent call that is isolated in a
# worktree or whose brief carries the commit session line, other than a read only type (Explore,
# Plan, claude-code-guide, statusline-setup, plan-*). A fork is never refused: it ignores `model`
# and runs on the session's own model, so asking it for one cannot be satisfied.
#
# Fails OPEN on a payload it cannot read, loudly, through a systemMessage (lib/hook-notice.sh):
# Claude Code discards a PreToolUse hook's stderr on exit 0 (#1906).

set -uo pipefail

payload="$(cat 2>/dev/null || true)"
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && payload="$(ps_clean_payload "$payload")"

verdict="$(printf '%s' "$payload" | python3 -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception as e:
    print("unreadable\t" + type(e).__name__); sys.exit()
if not isinstance(d, dict):
    print("unreadable\tthe payload is not a JSON object"); sys.exit()
if d.get("tool_name") != "Agent":
    print("allow"); sys.exit()
ti = d.get("tool_input")
if not isinstance(ti, dict):
    print("unreadable\ttool_input is not an object"); sys.exit()
st = ti.get("subagent_type") or ""
prompt = ti.get("prompt") or ""
if not isinstance(st, str) or not isinstance(prompt, str):
    print("unreadable\tsubagent_type or prompt is not text"); sys.exit()
if st == "fork" or st in ("Explore", "Plan", "claude-code-guide", "statusline-setup") or st.startswith("plan-"):
    print("allow"); sys.exit()
builder = ti.get("isolation") == "worktree" or "Claude-Session:" in prompt
if not builder:
    print("allow"); sys.exit()
model = ti.get("model")
print("allow" if isinstance(model, str) and model.strip() else "refuse")
' 2>&1)"

case "$verdict" in
  allow) exit 0 ;;
  refuse)
    echo "REFUSED: this builder dispatch names no model, so it would run on the session default with nothing said (claude-config#2027). Set model on the Agent call by the kind of task: \"sonnet\" for a rename or move that changes no behaviour, tests for code that already exists, or a fix for a review comment; \"fable\" for design, security and compliance work; \"opus\" for everything else. The rule is in \"Which model a builder runs on\" in ~/.claude/skills/orchestrate/SKILL.md. To use another model for one brief, suggest it to Dan with the reason first." >&2
    exit 2
    ;;
  unreadable$'\t'*)
    hook_allow_notice "BUILDER MODEL GATE DID NOT RUN: builder-model-gate.sh could not read the hook payload (${verdict#*$'\t'}), so this Agent call was let through without checking that it names a model."
    ;;
  *)
    hook_allow_notice "BUILDER MODEL GATE DID NOT RUN: builder-model-gate.sh failed (${verdict//$'\n'/ }), so this Agent call was let through without checking that it names a model."
    ;;
esac
