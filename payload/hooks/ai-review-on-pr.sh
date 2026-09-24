#!/usr/bin/env bash
#
# ai-review-on-pr.sh
# Claude Code PostToolUse(Bash) hook.
#
# When a `gh pr create` has just succeeded, start the lessons review of the whole branch
# (lib/pr-review.sh start), detached, so the merge gate (pr-review-gate.sh) finds it running or done
# rather than starting it then (claude-config#560). Recognised in COMMAND POSITION only, with
# environment prefixes such as `GH_TOKEN=$(gh auth token -u name)` stripped, never a mention of one
# in an argument or a heredoc (ps_is_gh_pr_create, L673).
#
# Runs on EVERY computer, unlike the push review, which AI_REVIEW_HOSTS confines to the work Mac.
# Never blocks: the pull request already exists, and every path exits 0 with one line saying what
# happened. The base is the pull request's --base/-B when the command names one, else origin's
# default branch.

set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || { echo "pr-review: lib/push-scope.sh is missing, so no lessons review was started; the merge gate will start one."; exit 0; }
# shellcheck source=lib/ai-review-common.sh
. "$HOOK_DIR/lib/ai-review-common.sh" 2>/dev/null || { echo "pr-review: lib/ai-review-common.sh is missing, so no lessons review was started; the merge gate will say why."; exit 0; }

payload="$(cat)"
parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0
ps_is_gh_pr_create "$cmd" || exit 0

say() { printf 'pr-review: %s\n' "$1"; exit 0; }

fields="$(ar_payload_fields "$payload")" || fields=""
rest="${fields#*$'\x1f'}"; rest="${rest#*$'\x1f'}"
create_exit="${rest%%$'\x1f'*}"
create_interrupted="${rest#*$'\x1f'}"
case "$create_exit" in
  ''|0|null) : ;;
  *) say "the pull request creation did not succeed (exit $create_exit), so no lessons review was started." ;;
esac
[ "$create_interrupted" = "true" ] && say "the pull request creation was interrupted, so no lessons review was started."

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || say "could not tell which repository this pull request is in, so no lessons review was started; the merge gate will start one."
[ -n "$repo_dir" ] || exit 0

base=""
read -r -a words <<< "$cmd"
for ((i = 0; i < ${#words[@]}; i++)); do
  case "${words[$i]}" in
    --base|-B) base="${words[$((i + 1))]:-}" ;;
    --base=*) base="${words[$i]#--base=}" ;;
  esac
done
base="${base//[\"\']/}"
top="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$repo_dir")"
ar_pr_opened "$(basename "$top")" "$top" "$(git -C "$top" rev-parse HEAD 2>/dev/null)"
args=(start --dir "$repo_dir")
[ -n "$base" ] && args+=(--base-ref "origin/$base")
say "$(bash "$HOOK_DIR/lib/pr-review.sh" "${args[@]}" 2>&1)"
