#!/usr/bin/env bash
#
# no-verify-approval.sh: the main session's approval for ONE agent to skip a repository's own git
# hooks (claude-config#1587). no-verify-gate.sh refuses an agent's `git commit --no-verify` (and the
# other skips lib/agent-overrides.py reads) unless the agent it came from is approved here.
#
#   bash ~/.claude/hooks/lib/no-verify-approval.sh approve <agent id> "<why>"
#   bash ~/.claude/hooks/lib/no-verify-approval.sh revoke <agent id>
#   bash ~/.claude/hooks/lib/no-verify-approval.sh list
#
# Only the main session can approve: no-verify-gate.sh refuses this script's approve when an agent
# runs it, since only an agent's hook payload carries agent_id. The agent id is the one the Agent
# tool's result names, and the one the gate's refusal quotes.
#
# Decided for #1587's open question (should an agent ever be allowed --no-verify while the push gates
# and CI still run the full checks?): only with this approval, for one agent, with a reason, for two
# hours. The repository's hooks are the only check that runs before the commit exists, CI is not the
# same check in every repository, and an approval that is never needed costs nothing, while a skip
# nobody saw is the defect #1587 records.
#
# Approvals live outside ~/.claude (anything under it is synced to the other Mac), one file per agent,
# in NO_VERIFY_APPROVAL_DIR (default ~/.claude-no-verify-approvals). NO_VERIFY_NOW sets the clock and
# NO_VERIFY_APPROVAL_SECONDS the lifetime (default 7200), so the suite never waits for time (L524).
set -uo pipefail

DIR="${NO_VERIFY_APPROVAL_DIR:-$HOME/.claude-no-verify-approvals}"
LIFE="${NO_VERIFY_APPROVAL_SECONDS:-7200}"
case "$LIFE" in ''|*[!0-9]*) LIFE=7200 ;; esac
now() { case "${NO_VERIFY_NOW:-}" in ''|*[!0-9]*) date +%s ;; *) printf '%s\n' "$NO_VERIFY_NOW" ;; esac; }

usage() {
  echo "usage: no-verify-approval.sh approve <agent id> \"<why>\" | revoke <agent id> | list" >&2
  exit 64
}
plain_id() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }

cmd="${1:-}"
case "$cmd" in
  approve)
    id="${2:-}"
    reason="${*:3}"
    plain_id "$id" || { echo "no-verify-approval: '$id' is not an agent id (letters, digits, - and _ only)." >&2; exit 64; }
    [ -n "${reason//[[:space:]]/}" ] || { echo "no-verify-approval: an approval needs a reason, in words Dan can read later." >&2; exit 64; }
    mkdir -p "$DIR" || { echo "no-verify-approval: could not create $DIR, so nothing was approved." >&2; exit 1; }
    t="$(now)"
    tmp="$DIR/.$id.$$"
    printf 'approved=%s\nexpires=%s\nreason=%s\n' "$t" "$((t + LIFE))" "$(printf '%s' "$reason" | tr '\n' ' ')" > "$tmp" \
      && mv -f "$tmp" "$DIR/$id" || { rm -f "$tmp"; echo "no-verify-approval: could not write the approval for $id, so nothing was approved." >&2; exit 1; }
    echo "Approved agent $id to skip git hooks for $((LIFE / 60)) minutes: $reason"
    ;;
  revoke)
    id="${2:-}"
    plain_id "$id" || usage
    if [ -f "$DIR/$id" ]; then rm -f "$DIR/$id" && echo "Revoked the approval for agent $id."
    else echo "Agent $id had no approval."; fi
    ;;
  list)
    t="$(now)"; n=0
    for f in "$DIR"/*; do
      [ -f "$f" ] || continue
      exp="$(sed -n 's/^expires=//p' "$f" | head -1)"
      reason="$(sed -n 's/^reason=//p' "$f" | head -1)"
      case "$exp" in ''|*[!0-9]*) exp=0 ;; esac
      if [ "$exp" -gt "$t" ]; then
        echo "$(basename "$f"): $(( (exp - t) / 60 )) minutes left: $reason"; n=$((n + 1))
      fi
    done
    [ "$n" -gt 0 ] || echo "No agent is approved to skip git hooks."
    ;;
  *) usage ;;
esac
