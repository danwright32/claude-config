#!/usr/bin/env bash
#
# no-verify-gate.sh
# Claude Code PreToolUse(Bash) hook: refuse an AGENT's git command that skips the repository's own
# git hooks (claude-config#1587). Nothing lets one through (claude-config#1666).
#
# On 2026-10-23 a Bidspoke builder agent made two commits with `git commit --no-verify` because the
# pre-commit typecheck and lint were slow under load, then handed back "no `--no-verify`, no
# overrides". CI ran every check and they passed, so nothing broken shipped; but nothing refused the
# skip, and the gates this config adds run on a push or a merge, never on a commit, so the
# repository's own hooks are the only check that runs before the commit exists.
#
# WHAT A SKIP IS is lib/agent-overrides.py's one reading (`skips`): --no-verify on any git
# subcommand, commit's -n, a core.hooksPath set with -c, and HUSKY=0 and the other hook managers'
# switches, behind rtk, env, an if or a `bash -c` string alike, and inside a rebase's --exec. Words
# that only mention one (a commit message, an echo, a grep) are not one.
#
# WHO IS ASKED is read from agent_id, which only a subagent's payload carries (measured on Claude
# Code 2.1.274, see playwright-subagent-gate.sh). The main session is not judged: Dan sees what it
# runs.
#
# NO APPROVAL. #1587 shipped one, the main session approving one agent for two hours by a file in a
# folder of approvals. Dan removed it on 2026-10-24 ("Remove it", claude-config#1666): an agent could
# write that file itself with the Write tool, which no Bash gate sees. So an agent's skip is always
# refused. The main session, which this gate does not judge, runs where Dan sees it.
#
# An agent's payload this cannot judge (no python3, or the reader missing or failing) is refused when
# it names a skip's words at all: an agent can rerun without the skip, while a skip let through unread
# is the defect this exists for (L42, L490).
#
# No override.

set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cat 2>/dev/null || true)"

# Only a subagent's payload is judged, and most commands name no git at all, so both leave before
# anything starts.
case "$payload" in *'"agent_id"'*) ;; *) exit 0 ;; esac
case "$payload" in *git*) ;; *) exit 0 ;; esac

refuse() { printf '%s\n' "$1" >&2; exit 2; }

# EVERY path that cannot read the command judges the same words the reading path acts on: a skip's
# words. Three lessons review rounds on #1587 each found a degraded path judging fewer things than the
# normal one, so they share this one list (L370).
refuse_unread() {   # $1 = the text to look in, $2 = why it could not be read
  case "$1" in
    *no-verify*|*hooksPath*|*hookspath*|*HooksPath*|*HUSKY*|*LEFTHOOK*|*SIMPLE_GIT_HOOKS*)
      refuse "REFUSED (no-verify-gate.sh): this agent's command names a way to skip the repository's git hooks, and $2, so the gate cannot tell what it does. Run the command without it." ;;
  esac
  exit 0
}

# The payload and the skip are both read with python3. Without it nothing here can tell a skip from
# a mention, so an agent's command naming those words is refused, saying what is missing (L490).
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

case "$cmd" in
  *commit*|*no-verify*|*hooksPath*|*hookspath*|*HooksPath*|*HUSKY*|*LEFTHOOK*|*SIMPLE_GIT_HOOKS*) ;;
  *) exit 0 ;;
esac

found="$(printf '%s' "$cmd" | python3 "$HOOK_DIR/lib/agent-overrides.py" skips 2>&1)"; rc=$?
case "$rc" in
  1) exit 0 ;;
  0) ;;
  *) refuse_unread "$cmd" "lib/agent-overrides.py could not read it (exit $rc: ${found##*$'\n'})" ;;
esac

refuse "REFUSED (no-verify-gate.sh): agent $agent ran a git command that skips the repository's own git hooks:
  ${found//$'\n'/$'\n'  }
Those hooks are the only check that runs before the commit exists, and an agent skipping them is what claude-config#1587 records. No agent may skip them (claude-config#1666). Run it without the skip and wait for the hooks in the foreground, however slow they are. If they cannot pass, stop and hand back to the main session saying why. Whatever happens, never report a skip as not having happened."
