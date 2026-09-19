#!/usr/bin/env bash
#
# teammate-challenge-gate.sh: TeammateIdle hook.
#
# Before a teammate goes idle, nudge it ONCE to surface disagreement/risk rather
# than silently agreeing (anti-rubber-stamp / anti-false-consensus). Fires at
# most once per teammate; if no stable teammate id is found in the payload it
# does nothing, so it can never loop. Only meaningful when agent teams are
# enabled (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1): otherwise no teammate ever
# goes idle and this never runs.
#
# Exit 2 = send the message back and keep the teammate working (per the
# TeammateIdle hook contract). Exit 0 = let it go idle.

set -uo pipefail
input=$(cat)

# THE READER THE IDENTIFIER COMES OUT OF (claude-config#486, L490).
#
# The payload is read with python3. Without it the identifier came back empty and this took the
# same path as a payload naming no teammate: exit 0, nothing said. Every teammate then idled
# unchallenged for ever, looking exactly like teammates that had each already been nudged (L98).
#
# It cannot nudge PER TEAMMATE here, because there is no identifier to key a marker on and a nudge
# that fired every time is the idle loop this whole hook is shaped to avoid. So it says it ONCE,
# on a marker of its own, and carries the challenge itself so the substance is not lost with the
# identifier.
if ! command -v python3 >/dev/null 2>&1; then
  said="${TMPDIR:-/tmp}/claude-teammate-gate-no-python3"
  [ -f "$said" ] && exit 0
  : > "$said" 2>/dev/null || exit 0
  echo "TEAMMATE CHALLENGE GATE DID NOT RUN: python3 is not on PATH, and this hook reads which teammate is idling out of the payload with it. Nothing will nudge each teammate individually until it is installed, so this is said once, to you: have you genuinely pushed back where you disagree, named the risks only your lens catches, and challenged the other agents rather than quietly agreeing? If a weaker idea is sliding toward consensus, say so now, with specifics. If you have truly done that and your work is complete, you may stop." >&2
  exit 2
fi

id=$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
for k in ("agent_id","agentId","teammate","teammate_name","teammateName","name","session_id","sessionId"):
    v = d.get(k)
    if v:
        print(str(v)); sys.exit(0)
print("")
' 2>/dev/null)

# No stable identifier -> do not gate (prevents any chance of an idle loop).
[ -n "$id" ] || exit 0

safe=$(printf '%s' "$id" | tr -cd 'A-Za-z0-9_.-')
marker="${TMPDIR:-/tmp}/claude-teammate-gate-${safe}"
[ -f "$marker" ] && exit 0   # already nudged this teammate -> let it idle
: > "$marker"

echo "Before you go idle: have you genuinely pushed back where you disagree, named the risks only your lens catches, and challenged the other agents rather than quietly agreeing? If a weaker idea is sliding toward consensus, say so now, with specifics. If you have truly done that and your work is complete, you may stop." >&2
exit 2
