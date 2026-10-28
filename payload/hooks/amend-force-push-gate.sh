#!/usr/bin/env bash
#
# amend-force-push-gate.sh
# Claude Code PreToolUse(Bash) hook: refuse a SUBAGENT's git command that rewrites a commit it already
# made, `git commit --amend` and a forced `git push` (--force, -f, --force-with-lease, a +refspec),
# saying the rule the global CLAUDE.md gives every dispatched builder (claude-config#1856):
# never amend a commit or force push; add a new commit and push normally.
#
# On 2026-10-28 the #1806 builder tried to amend its own commit after a push review finding, the auto
# mode classifier refused it as "Git Destructive", and the push that followed sent the commit without
# the fix, which the builder then added as a new commit. The #1840 builder and a merge brief hit the
# same refusal for a force push the same night. Builders found the rule by trial, a round trip each
# time, and a rule that lives only in a prompt is a hope (L27), so this makes it hold.
#
# WHAT A REWRITE IS is lib/agent-overrides.py's `rewrites`, over lib/shell-words.py, the one reading
# every gate uses: behind rtk, env, a cd, an if or a `bash -c` string alike, and inside a rebase's
# --exec. Words that only mention one (a commit message, an echo, a grep) are not one.
#
# WHO IS ASKED is read from agent_id, which only a subagent's payload carries (measured on Claude Code
# 2.1.274, see playwright-subagent-gate.sh). The main session is not judged: Dan sees what it runs,
# and it is where a deliberate rewrite, when one is ever needed, is done.
#
# An agent's payload this cannot judge (no python3, or the reader failing) is refused when it names
# --amend, a force, or a push with -f or a leading +: an agent can say it plainly and run it again,
# while one let through unread is the defect this exists for (L42, L490).
#
# No override.

set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cat 2>/dev/null || true)"

# Only a subagent's git command is judged, and only one naming an amend or a push, so nearly every
# call leaves before python starts.
case "$payload" in *'"agent_id"'*) ;; *) exit 0 ;; esac
case "$payload" in *git*) ;; *) exit 0 ;; esac
case "$payload" in *amend*|*push*) ;; *) exit 0 ;; esac

refuse() { printf '%s\n' "$1" >&2; exit 2; }

# The one degraded judgement, for every path that cannot read the command (L370).
refuse_unread() {   # $1 = the text to look in, $2 = why it could not be read
  case "$1" in
    *--amend*|*--force*|*push*' -f'*|*push*' +'*|*push*':+'*)
      refuse "REFUSED (amend-force-push-gate.sh): this agent's command names an amend or a force push, and $2, so the gate cannot tell what it does. Never amend a commit or force push: add a new commit and push normally (claude-config#1856)." ;;
  esac
  exit 0
}

if ! . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || ps_reader_missing python3; then
  refuse_unread "$payload" "python3 (or lib/push-scope.sh) is missing; install python3"
fi

parsed="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
if not isinstance(d, dict) or "agent_id" not in d:
    sys.exit(4)
ti = d.get("tool_input") or {}
cmd = ti.get("command") if isinstance(ti, dict) else ""
sys.stdout.write(str(d.get("agent_id") or "") + "\x1f" + (cmd if isinstance(cmd, str) else ""))
' 2>/dev/null)"; prc=$?
[ "$prc" -eq 4 ] && exit 0
[ "$prc" -eq 0 ] || refuse_unread "$payload" "the gate could not read the hook payload"
agent="${parsed%%$'\x1f'*}"
cmd="${parsed#*$'\x1f'}"
[ -n "$agent" ] || agent="(no id given)"

case "$cmd" in *amend*|*push*) ;; *) exit 0 ;; esac

said="$(printf '%s' "$cmd" | python3 "$HOOK_DIR/lib/agent-overrides.py" rewrite-refusal "$agent" 2>&1)"; rc=$?
# 10 is the reader's "nothing to refuse"; 1 is what Python exits on a crash, so it is unread.
case "$rc" in
  10) exit 0 ;;
  0) refuse "REFUSED (amend-force-push-gate.sh): $said" ;;
  *) refuse_unread "$cmd" "lib/agent-overrides.py could not read it (exit $rc: ${said##*$'\n'})" ;;
esac
