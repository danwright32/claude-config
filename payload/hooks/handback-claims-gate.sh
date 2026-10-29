#!/usr/bin/env bash
#
# handback-claims-gate.sh
# Claude Code PreToolUse(SubagentHandback) hook: compare what an agent's hand-back report says about
# skipping checks with what the agent's own commands did, and say so when they disagree
# (claude-config#1587).
#
# On 2026-10-23 a Bidspoke builder agent committed twice with `git commit --no-verify` and handed back
# "no `--no-verify`, no overrides". The end of turn harvest found the commits in the agent's own
# transcript, after the main session had already acted on the report. The report is the one thing the
# main session reads of an agent's work, so a claim in it that the commands contradict is caught HERE,
# before it is delivered, by reading the same transcript.
#
# WHAT IS COMPARED is lib/agent-overrides.py check-report: a clause saying no --no-verify was used or
# no hook skipped, against the git hook skips the agent's commands ran; a clause saying no override
# was used or nothing bypassed, against those and every SKIP_ or ALLOW_ override the commands set. A
# command a hook refused never ran and does not count; one that ran and failed does. A clause that
# qualifies itself ("no OTHER overrides") is not a denial, so a report naming its skip goes through.
# Nor is a denial the report withdraws ("the earlier claim that no overrides were used is withdrawn")
# or quotes after a reporting verb (It says "no overrides were used"), so a report corrected the way
# a refusal asks, or pasting the refusal, is not refused again (claude-config#1702).
#
# WHAT IT DOES on a contradiction: refuses the hand-back, quoting the claim and the commands, so the
# agent corrects its report. The refusal asks for the plainest correction, deleting the false
# sentence (#1732); a withdrawal or a quotation of it, read as above, goes through too (#1716). A
# report the agent will not correct is let through on the third attempt
# (HANDBACK_CHECK_MAX_REFUSALS, default 2), so a report is never stranded by a misreading here, and
# then the contradiction is said to Dan and spooled for the main session's end of turn review
# (lib/issue-spool.sh note), since a report delivered with a false claim must not arrive unremarked.
#
# THE TRANSCRIPT is the agent's own, never the parent's (subagent-harvest.md): agent_transcript_path
# when the payload carries it, else <the parent transcript without .jsonl>/subagents/agent-<id>.jsonl,
# where Claude Code writes it. One that cannot be found or read is let through, saying on stderr that
# it was not checked: refusing would strand the report over the gate's own failure (L98).
#
# MEASURED on 2026-10-24 (claude-config#1674): Claude Code runs PreToolUse hooks for the
# SubagentHandback tool. A probe agent that set SKIP_HANDBACK_PROBE=1 and handed back "no overrides were
# used" was refused here, its count was written under ~/.claude-handback-check/, and its transcript holds
# a PreToolUse:SubagentHandback hook record. A pass prints nothing and leaves no record, so the absence
# of one in a transcript says nothing about whether this ran.

set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cat 2>/dev/null || true)"
case "$payload" in *'"agent_id"'*) ;; *) exit 0 ;; esac

parsed="$(printf '%s' "$payload" | python3 -c '
import json, os, sys
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception:
    sys.exit(3)
if not isinstance(d, dict) or "agent_id" not in d:
    sys.exit(4)
agent = str(d.get("agent_id") or "")
ti = d.get("tool_input") or {}
msg = ti.get("message") if isinstance(ti, dict) else None
if not isinstance(msg, str) or not msg.strip():
    sys.exit(4)
t = d.get("agent_transcript_path") or ""
if not (isinstance(t, str) and t and os.path.isfile(t)):
    parent = d.get("transcript_path") or ""
    t = ""
    if isinstance(parent, str) and parent.endswith(".jsonl") and agent:
        t = os.path.join(parent[:-len(".jsonl")], "subagents", "agent-" + agent + ".jsonl")
sys.stdout.write("\x1f".join([agent, t, str(d.get("cwd") or ""), str(d.get("transcript_path") or ""), msg]))
' 2>/dev/null)"; prc=$?
[ "$prc" -eq 4 ] && exit 0
if [ "$prc" -ne 0 ]; then
  echo "HANDBACK CLAIMS CHECK DID NOT RUN: handback-claims-gate.sh could not read the hand-back's hook payload (python3 missing or the payload unreadable), so this report's claims about skipping checks were NOT compared with the agent's commands." >&2
  exit 0
fi
IFS=$'\x1f' read -r -d '' agent transcript cwd parent report <<< "$parsed"
report="${report%$'\n'}"

if [ -z "$transcript" ] || [ ! -r "$transcript" ]; then
  echo "HANDBACK CLAIMS CHECK DID NOT RUN: handback-claims-gate.sh could not find agent ${agent:-?}'s own transcript (${transcript:-none derived}), so this report's claims about skipping checks were NOT compared with its commands." >&2
  exit 0
fi

found="$(printf '%s' "$report" | python3 "$HOOK_DIR/lib/agent-overrides.py" check-report "$transcript" 2>&1)"; rc=$?
# 10 is the reader's "nothing contradicts"; 1 is what Python exits on a crash, so a crash says the
# check did not run rather than passing as a clean report (claude-config#1869, L1033).
case "$rc" in
  10) exit 0 ;;
  0) ;;
  *)
    echo "HANDBACK CLAIMS CHECK DID NOT RUN: handback-claims-gate.sh could not compare agent $agent's report with its commands (lib/agent-overrides.py exit $rc: ${found##*$'\n'}), so its claims about skipping checks were NOT checked." >&2
    exit 0 ;;
esac

state="${HANDBACK_CHECK_STATE_DIR:-$HOME/.claude-handback-check}"
max="${HANDBACK_CHECK_MAX_REFUSALS:-2}"
case "$max" in ''|*[!0-9]*) max=2 ;; esac
count=0
key="$(printf '%s' "$agent" | tr -c 'A-Za-z0-9_-' '_')"
why="after $max refusals"
if [[ -n "$key" ]] && mkdir -p "$state" 2>/dev/null; then
  count="$(cat "$state/$key" 2>/dev/null || echo 0)"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  # A refusal is given only once it is COUNTED: one that could not be recorded would read as the
  # first every time, and the report could never be handed back (lessons review at 0fe61ad).
  if [ "$count" -lt "$max" ] && printf '%s\n' "$((count + 1))" > "$state/$key" 2>/dev/null; then
    printf '%s\n' "REFUSED (handback-claims-gate.sh): your report contradicts your own commands.
$found
Correct the report before handing back: name each of these, say why it was done, and delete the sentence that says it was not. The main session acts on this report, so it has to say what happened (claude-config#1587, #1702)." >&2
    exit 2
  fi
  [ "$count" -lt "$max" ] && why="unrefused, because the gate could not keep count of its refusals in $state"
else
  why="unrefused, because the gate could not keep count of its refusals in $state"
fi

# Let through so the report is never stranded, but never unremarked.
note="Agent $agent handed back a report that contradicts its own commands, $why. $(printf '%s' "$found" | tr '\n' ' ')"
bash "$HOOK_DIR/lib/issue-spool.sh" note "${cwd:-.}" "$note" "handback-claims-gate.sh" "$parent" >/dev/null 2>&1 \
  || note="$note (and it could not be spooled for the end of turn review)"
msg="handback-claims-gate.sh: $note"
if command -v jq >/dev/null 2>&1; then
  jq -nc --arg m "$msg" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
else
  printf '%s\n' "$msg" >&2
fi
exit 0
