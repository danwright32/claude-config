#!/usr/bin/env bash
#
# sync-main-to-dev.sh
# Claude Code PostToolUse(Bash) hook: after a pull request merges into main in a repo listed in
# this Mac's ~/.claude/hooks/main-to-dev-repos.local.txt, merge main INTO dev through GitHub's
# merges API, so staging keeps up with production. The rule came from a partner (Denys, trypennie, 2026-10-01) and merges there are rare,
# which is exactly when a rule kept only in memory gets missed (L27, L57), so the hook does the merge
# rather than reminding anyone to.
#
# It decides by the repo the MERGE targets (-R, a PR link, or the checkout's remote), never by the
# session's project, so it works from any folder. It says nothing on any other command. A command
# running more than one merge has each one acted on and each outcome said (claude-config#1082).
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
# The list names work repositories, so it is each Mac's own file, never tracked in the public
# repository (claude-config#1568). claude-sync moved each Mac's installed copy of the old tracked
# hooks/main-to-dev-repos.txt here byte for byte (MOVED_TO_LOCAL), and never sends or deletes it.
# Missing is said on every merge, never read as an empty list: a Mac that never got it would
# otherwise skip the rule silently, which is how a rule kept in memory gets missed (L27, L11).
# An empty file is the deliberate way to sync nothing here.
REPOS_FILE="${CLAUDE_HOME:-$HOME/.claude}/hooks/main-to-dev-repos.local.txt"
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

parsed="$(ps_parse_payload "$payload" raw)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0
if grep -Eq '(^|[[:space:];&|])SKIP_MAIN_DEV_SYNC=1([[:space:]]|$)' <<< "$cmd"; then exit 0; fi

. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || exit 0
mt_runs_merge "$cmd" || exit 0


# What it says, collected per merge and said once at the end: a command merging two pull requests
# (only ever under an override, since the merge gates refuse one, #1072) gets a line for each, and
# one merge's outcome can never stand in for another's (claude-config#1082).
said=()
say() { said+=("$1"); }
speak() {
  [ "${#said[@]}" -gt 0 ] || exit 0
  local m="Main to dev sync: ${said[0]}" i
  for ((i = 1; i < ${#said[@]}; i++)); do m="$m
Main to dev sync: ${said[$i]}"; done
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$m" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  else
    printf '{"systemMessage":"%s"}\n' "$(printf '%s' "$m" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
  fi
  exit 0
}

if [ ! -f "$REPOS_FILE" ]; then
  say "this Mac has no list of repositories to merge main into dev after a merge, at $REPOS_FILE, so no repository was synced. It names work repositories, so it is this Mac's own file and never sent between Macs. Create it with one owner/name a line (a # starts a comment), or leave it empty to sync nothing here on purpose."
  speak
fi

# One merge: the directory it runs in, the repository it names with -R or a link, and its number.
sync_one() {  # $1 = directory, $2 = repo flag or empty, $3 = pr number or empty
  local repo_flag="$2" pr="$3" slug listed line by_hand envelope state base num account token resp code sha first
  local -a merge_args
  cd "$1" 2>/dev/null || return 0
  slug="${repo_flag:-$(mt_remote_slug)}"
  [ -n "$slug" ] || return 0

  listed=""
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] || continue
    if [ "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" ]; then
      listed="$line"; break
    fi
  done < "$REPOS_FILE"
  [ -n "$listed" ] || return 0
  slug="$listed"

  by_hand="gh api -X POST repos/$slug/merges -f base=dev -f head=main -f commit_message='Merge main into dev'"
  command -v gh >/dev/null 2>&1 || { say "this merge was in $slug, where main must be merged into dev after every merge, and gh is not on PATH, so the sync did NOT run. Run by hand: $by_hand"; return 0; }
  command -v jq >/dev/null 2>&1 || { say "jq is missing, so the merged PR in $slug could not be read and the sync did NOT run. Run by hand: $by_hand"; return 0; }

  envelope="$(mt_pr_view "$pr" "number,url,state,baseRefName" "$slug" "$repo_flag")"
  if [ "$(printf '%s' "$envelope" | jq -r '.found // false' 2>/dev/null)" != "true" ]; then
    say "could not read the pull request this command merged in $slug${pr:+ (#$pr)}, so main was NOT merged into dev and the sync did NOT run. If it merged into main, run: $by_hand"
    return 0
  fi
  state="$(printf '%s' "$envelope" | jq -r '.view.state // ""')"
  base="$(printf '%s' "$envelope" | jq -r '.view.baseRefName // ""')"
  num="$(printf '%s' "$envelope" | jq -r '.view.number // ""')"
  account="$(printf '%s' "$envelope" | jq -r '.account // ""')"

  [ "$base" = "main" ] || return 0
  [ "$state" = "MERGED" ] || { say "PR #$num in $slug is not merged yet (state $state), so dev was not synced. Once it lands on main, run: $by_hand"; return 0; }

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
  code="$(printf '%s' "$resp" | awk 'toupper($1) ~ /^HTTP\// && !got { print $2; got = 1 }')"

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
}

# EVERY merge in the command (claude-config#1082). It read only the first, so under an override a
# second merge's repository was left with dev behind main and nothing said. When the command runs
# more than one merge and nothing can read which pull requests they are, that is said by name rather
# than acting on the first.
merges="$(mt_merge_each "$cmd" "$cwd")"
if [ $? -eq 2 ]; then
  say "this command ran more than one merge and nothing here could read which pull request each was ($(mt_reader_absent_why)), so main was NOT merged into dev for any of them. For each one that merged into main in a repository listed in $REPOS_FILE, merge main into dev by hand through GitHub's merges API, base dev and head main."
  speak
fi
# Read on its own descriptor, so nothing sync_one runs (gh above all) can swallow the remaining lines.
while IFS= read -r m <&3; do
  [ -n "$m" ] || continue
  sync_one "${m%%$'\t'*}" "$(printf '%s' "$m" | cut -f2)" "${m##*$'\t'}"
done 3<<< "$merges"
speak
