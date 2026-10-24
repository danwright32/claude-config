#!/usr/bin/env bash
#
# no-verify-gate.sh
# Claude Code PreToolUse(Bash) hook: refuse an AGENT's git command that skips the repository's own
# git hooks, unless the main session approved that agent (claude-config#1587).
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
# runs, and it is the one that approves.
#
# THE APPROVAL is lib/no-verify-approval.sh, run by the main session, for one agent, with a reason,
# for two hours. An agent running that approval itself is refused here, which is what makes it the
# main session's. An approved skip is let through and said, to the agent and to Dan.
#
# An agent's payload this cannot judge (no python3, or the reader missing or failing) is refused when
# it names a skip's words at all: an agent can rerun without the skip, while a skip let through unread
# is the defect this exists for (L42, L490).
#
# No override: a skip that is needed is approved by the main session, visibly.

set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cat 2>/dev/null || true)"

# Only a subagent's payload is judged, and most commands name no git at all, so both leave before
# anything starts.
case "$payload" in *'"agent_id"'*) ;; *) exit 0 ;; esac
case "$payload" in *git*|*no-verify-approval*) ;; *) exit 0 ;; esac

refuse() { printf '%s\n' "$1" >&2; exit 2; }
SKIP_WORDS_WHY="this agent's command names a way to skip the repository's git hooks, and"

# The payload and the skip are both read with python3. Without it nothing here can tell a skip from
# a mention, so an agent's command naming a skip's words is refused, saying what is missing (L490).
if ! . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || ps_reader_missing python3; then
  case "$payload" in
    *no-verify*|*hooksPath*|*hookspath*|*HooksPath*|*HUSKY*|*LEFTHOOK*|*SIMPLE_GIT_HOOKS*)
      refuse "REFUSED (no-verify-gate.sh): $SKIP_WORDS_WHY python3 (or lib/push-scope.sh) is missing, so the gate cannot read whether it really skips them. Install python3, or run the command without the skip." ;;
  esac
  exit 0
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
if [ "$prc" -ne 0 ]; then
  case "$payload" in
    *no-verify*|*hooksPath*|*hookspath*|*HUSKY*|*LEFTHOOK*|*SIMPLE_GIT_HOOKS*)
      refuse "REFUSED (no-verify-gate.sh): $SKIP_WORDS_WHY the gate could not read the hook payload to tell whether it really skips them. Run the command without the skip." ;;
  esac
  exit 0
fi
agent="${parsed%%$'\x1f'*}"
cmd="${parsed#*$'\x1f'}"
[ -n "$agent" ] || agent="(no id given)"

APPROVE_HOW="bash ~/.claude/hooks/lib/no-verify-approval.sh approve $agent \"<why>\""

# The approval belongs to the main session: an agent may not give one, to itself or to a sibling.
case "$cmd" in
  *no-verify-approval*approve*)
    refuse "REFUSED (no-verify-gate.sh): agent $agent ran the approval for skipping git hooks. Only the main session can approve that; an agent approving itself is the bypass the approval exists to stop (claude-config#1587). If the skip is genuinely needed, stop and hand back to the main session saying why." ;;
  # The folder IS the approval, so an agent's command naming it is refused whatever it does there: a
  # file written by hand is an approval nobody gave (lessons review at f654145). The Write tool can
  # still reach it; that is deliberate forgery rather than a corner cut, and the hand-back check
  # still catches a report that then denies the skip.
  *.claude-no-verify-approvals*)
    refuse "REFUSED (no-verify-gate.sh): agent $agent's command names the folder that holds the main session's approvals to skip git hooks. An agent may not read or write approvals there; only the main session gives them (claude-config#1587)." ;;
esac

case "$cmd" in
  *commit*|*no-verify*|*hooksPath*|*hookspath*|*HooksPath*|*HUSKY*|*LEFTHOOK*|*SIMPLE_GIT_HOOKS*) ;;
  *) exit 0 ;;
esac

found="$(printf '%s' "$cmd" | python3 "$HOOK_DIR/lib/agent-overrides.py" skips 2>&1)"; rc=$?
case "$rc" in
  1) exit 0 ;;
  0) ;;
  *)
    case "$cmd" in
      *no-verify*|*hooksPath*|*hookspath*|*HooksPath*|*HUSKY*|*LEFTHOOK*|*SIMPLE_GIT_HOOKS*)
        refuse "REFUSED (no-verify-gate.sh): agent $agent's command names a way to skip the repository's git hooks, and lib/agent-overrides.py could not read it (exit $rc: ${found##*$'\n'}), so the gate cannot tell whether it really skips them. Run the command without the skip." ;;
    esac
    exit 0 ;;
esac

# An approval the main session gave this agent, still in force: the approval script's own reading of
# its file, so the two cannot disagree about what an approval is (L370).
if approval="$(bash "$HOOK_DIR/lib/no-verify-approval.sh" check "$agent" 2>/dev/null)"; then
  msg="no-verify-gate.sh: agent $agent skips the repository's git hooks with the main session's approval (${approval#* }), ${approval%% *} minutes left: ${found//$'\n'/; }. Say so in the hand-back report."
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$msg" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
  else
    printf '%s\n' "$msg"
  fi
  exit 0
fi

refuse "REFUSED (no-verify-gate.sh): agent $agent ran a git command that skips the repository's own git hooks:
  ${found//$'\n'/$'\n'  }
Those hooks are the only check that runs before the commit exists, and an agent skipping them is what claude-config#1587 records. Run it without the skip and wait for the hooks in the foreground, however slow they are. If the skip is genuinely needed, stop and hand back to the main session saying why; only the main session can approve it, for this agent and two hours, with:
  $APPROVE_HOW
Whatever happens, never report a skip as not having happened."
