#!/usr/bin/env bash
#
# builder-model-gate.sh
# Claude Code PreToolUse(Agent) hook: in a session that is ORCHESTRATING builders, refuse a builder
# dispatch that names no model, and say which tiers exist (claude-config#2027). The rule's one home
# is "Which model a builder runs on" in skills/orchestrate/SKILL.md; this hook only enforces that a
# choice was made.
#
# WHY. A rule that lives only in a prompt is a hope (L27). Measured on 2026-11-13 over the personal
# MacBook's transcripts since the tiers changed on 2026-11-09: 8 of 216 builder dispatches named no
# model and ran on the session default with nothing said. The issue's own decision was to build the
# check once any builder dispatch skipped the model.
#
# ONLY WHILE ORCHESTRATING (Dan, 2026-11-13: narrow it, so ordinary sessions see no new stop). A
# session is orchestrating builders once its own transcript (transcript_path, which for a call made
# inside a subagent is the parent's) already holds ORCHESTRATING other builder dispatches, so a
# session's first two builders are never stopped. Chosen over the other signals by measurement on
# the same window: the orchestrate skill was loaded in no main transcript at all (so a gate keyed on
# it refuses nothing), and the sleep mode worker record is gone once the night ends, while this count
# lives in the transcript and caught every one of the 7 skipped models in the orchestrating session.
# The 8th, an ordinary session's first builder, is now let through. Thresholds of 1, 2 and 3 gave
# the same answer there; 2 leans toward fewer stops. The transcript is read only for a builder with
# no model, and only as far as the second earlier builder.
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
ORCHESTRATING = 2  # earlier builder dispatches in this session that make it an orchestrating one
RO = ("Explore", "Plan", "claude-code-guide", "statusline-setup")
def is_builder(inp):
    t = inp.get("subagent_type") or ""
    p = inp.get("prompt") or ""
    if not isinstance(t, str) or not isinstance(p, str):
        return False
    if t == "fork" or t in RO or t.startswith("plan-"):
        return False
    return inp.get("isolation") == "worktree" or "Claude-Session:" in p
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
if not is_builder(ti):
    print("allow"); sys.exit()
model = ti.get("model")
if isinstance(model, str) and model.strip():
    print("allow"); sys.exit()
# Only a session orchestrating builders is refused (Dan, 2026-11-13). Read only now, because the
# transcript can run past 100 MB and every cheaper answer above has already been given.
tp = d.get("transcript_path")
if not isinstance(tp, str) or not tp:
    print("unknown\tthe hook payload names no transcript_path"); sys.exit()
own = d.get("tool_use_id")
earlier = 0
try:
    with open(tp, "rb") as f:
        for raw in f:
            if b"\"Agent\"" not in raw:
                continue
            try:
                e = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                continue
            if not isinstance(e, dict) or e.get("type") != "assistant":
                continue
            c = (e.get("message") or {}).get("content") if isinstance(e.get("message"), dict) else None
            if not isinstance(c, list):
                continue
            for b in c:
                if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Agent" \
                        and b.get("id") != own and isinstance(b.get("input"), dict) and is_builder(b["input"]):
                    earlier += 1
            if earlier >= ORCHESTRATING:
                break
except OSError as e:
    print("unknown\tthe session transcript could not be read: " + type(e).__name__); sys.exit()
print("refuse" if earlier >= ORCHESTRATING else "allow")
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
  unknown$'\t'*)
    hook_allow_notice "BUILDER MODEL GATE DID NOT RUN: this builder dispatch names no model, and builder-model-gate.sh could not tell whether this session is orchestrating builders (${verdict#*$'\t'}), so it was let through."
    ;;
  *)
    hook_allow_notice "BUILDER MODEL GATE DID NOT RUN: builder-model-gate.sh failed (${verdict//$'\n'/ }), so this Agent call was let through without checking that it names a model."
    ;;
esac
