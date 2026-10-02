#!/usr/bin/env bash
#
# sync-main-to-dev.sh
# Claude Code PostToolUse(Bash) hook: after a pull request merges into main in a repo listed in
# main-to-dev-repos.txt, merge main INTO dev through GitHub's merges API, so staging keeps up with
# production. The rule came from a partner (Denys, trypennie, 2026-10-01) and merges there are rare,
# which is exactly when a rule kept only in memory gets missed (L27, L57), so the hook does the merge
# rather than reminding anyone to.
#
# It decides by the repo the MERGE targets (-R, a PR link, or the checkout's remote), never by the
# session's project, so it works from any folder. It says nothing on any other command.
#
# It acts only on a PR it has READ as MERGED with base main, so a --auto merge still waiting, a PR
# into dev, or a failed merge requests nothing. Every outcome that is not a clean merge is said:
# already level, a CONFLICT (left untouched for a person, since resolving it means choosing between
# dev's unready work and main), any other API failure, a PR it could not read. Silence would read as
# done (L98, L11).
#
# Blind spot: a merge made outside a Claude Code session (the GitHub website) is never seen here.
#
# Override, explained to the person first and never silently: SKIP_MAIN_DEV_SYNC=1 as an inline
# prefix on the merge command, for that one command.

set -uo pipefail

payload="$(cat)"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_FILE="$HOOK_DIR/main-to-dev-repos.txt"
[ -f "$REPOS_FILE" ] || exit 0
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

parsed="$(ps_parse_payload "$payload" raw)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0
if grep -Eq '(^|[[:space:];&|])SKIP_MAIN_DEV_SYNC=1([[:space:]]|$)' <<< "$cmd"; then exit 0; fi

. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || exit 0
mt_runs_merge "$cmd" || exit 0

say() {
  local m="Main to dev sync: $1"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$m" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  else
    printf '{"systemMessage":"%s"}\n' "$(printf '%s' "$m" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
  exit 0
}

repo_flag="$(mt_repo_flag "$cmd")"
cd "$(mt_repo_dir "$cmd" "$cwd")" 2>/dev/null || exit 0
slug="${repo_flag:-$(mt_remote_slug)}"
[ -n "$slug" ] || exit 0

listed=""
while IFS= read -r line; do
  line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [ -n "$line" ] || continue
  if [ "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" ]; then
    listed="$line"; break
  fi
done < "$REPOS_FILE"
[ -n "$listed" ] || exit 0
slug="$listed"

by_hand="gh api -X POST repos/$slug/merges -f base=dev -f head=main -f commit_message='Merge main into dev'"
command -v gh >/dev/null 2>&1 || say "this merge was in $slug, where main must be merged into dev after every merge, and gh is not on PATH, so the sync did NOT run. Run by hand: $by_hand"
command -v jq >/dev/null 2>&1 || say "jq is missing, so the merged PR in $slug could not be read and the sync did NOT run. Run by hand: $by_hand"

pr="$(mt_pr_number "$cmd")"
envelope="$(mt_pr_view "$pr" "number,url,state,baseRefName" "$slug" "$repo_flag")"
if [ "$(printf '%s' "$envelope" | jq -r '.found // false' 2>/dev/null)" != "true" ]; then
  say "could not read the pull request this command merged in $slug, so main was NOT merged into dev and the sync did NOT run. If it merged into main, run: $by_hand"
fi
state="$(printf '%s' "$envelope" | jq -r '.view.state // ""')"
base="$(printf '%s' "$envelope" | jq -r '.view.baseRefName // ""')"
num="$(printf '%s' "$envelope" | jq -r '.view.number // ""')"
account="$(printf '%s' "$envelope" | jq -r '.account // ""')"

[ "$base" = "main" ] || exit 0
[ "$state" = "MERGED" ] || say "PR #$num in $slug is not merged yet (state $state), so dev was not synced. Once it lands on main, run: $by_hand"

token=""
[ -n "$account" ] && token="$(gh auth token -u "$account" 2>/dev/null)"
# The account that could READ the PR is the one that can write to the repo; the active account may
# not be (mt_pr_view's comment has why). Scoped per call, never gh auth switch.
merge_args=(api -i -X POST "repos/$slug/merges" -f base=dev -f head=main -f "commit_message=Merge main into dev after #$num")
if [ -n "$token" ]; then
  resp="$(GH_TOKEN="$token" gh "${merge_args[@]}" 2>&1)"
else
  resp="$(gh "${merge_args[@]}" 2>&1)"
fi
code="$(printf '%s' "$resp" | awk 'toupper($1) ~ /^HTTP\// { print $2; exit }')"

case "$code" in
  201)
    sha="$(sed -n '/"sha":"[0-9a-f]\{7\}/{s/.*"sha":"\([0-9a-f]\{7\}\).*/\1/p;q;}' <<<"$resp")"
    say "merged main into dev in $slug after PR #$num (commit ${sha:-unknown}), so staging matches production. Mention it in one line." ;;
  204)
    say "dev in $slug already contains main after PR #$num, nothing to merge." ;;
  409)
    say "CONFLICT merging main into dev in $slug after PR #$num. Nothing was changed on dev. Tell Dan now: someone has to resolve it by hand, because it means choosing between dev's unready work and what just shipped." ;;
  *)
    first="$(awk 'NF { print substr($0, 1, 200); exit }' <<<"$resp")"
    say "FAILED to merge main into dev in $slug after PR #$num (GitHub answered ${code:-nothing}: $first). Dev is behind main. Tell Dan, then retry: $by_hand" ;;
esac
