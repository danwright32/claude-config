#!/bin/bash
# PreToolUse gate: refuse deleting a branch on GitHub while an open pull request is based on it
# (claude-config#1723).
#
# WHY. GitHub closes an open pull request the moment the branch it is based on is deleted through
# the API or a push (the web page's delete button moves it instead), and a closed pull request's base
# can never be changed again, so it has to be opened again as a new one, losing its review thread and
# a CI round. On 2026-10-25 in bidspoke, #2760 squash merged and its branch 2337-http-service was
# deleted with `gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>`, the step the global
# CLAUDE.md names for a merge that could not delete its own branch. #2763 was stacked on that branch,
# and was closed at once with nothing said; it was found only because the next step read its state.
# lib/merge-when-ready.sh already moves every stacked pull request onto the merged one's base before
# it deletes a branch (claude-config#1337). This holds every other way a command here deletes one.
#
# WHAT IT DOES. Reads the command in COMMAND POSITION with lib/push-scope.sh's reader, so a delete
# quoted in an argument or written in a heredoc is not one, and one inside `bash -c` is. Three
# spellings delete a branch on GitHub:
#   gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>   (any spelling of the method;
#                    {owner}/{repo} is the checkout's origin, as gh reads it)
#   git push <remote> --delete <branch> (or -d), and git push <remote> :<branch>, to a GitHub remote
#   gh pr merge --delete-branch (or -d), which deletes the pull request's head branch as it merges
# For each, the open pull requests based on the branch are listed with lib/stacked-prs.sh, the same
# reading merge-when-ready.sh moves them with, as the account the command itself runs as when it
# names one (`GH_TOKEN=$(gh auth token -u <account>)`). Any listed refuses (exit 2), naming them and
# the command that moves each onto the branch the merged pull request went into; for a merge, the
# helper that merges, moves them and only then deletes.
#
# FAILS CLOSED. A list GitHub will not give, an answer that is not a list, a pull request whose
# branch cannot be read, or a repository it cannot tell, refuses: the next step is a delete, and a
# delete that cannot see what it would close is the exact harm this exists to stop (L98). Without its
# reader (python3, lib/push-scope.sh, lib/shell-words.py, lib/stacked-prs.sh) a command that looks
# like a delete is refused by name, and one that does not passes.
#
# Override: SKIP_STACKED_CHECK=1 in front of that one command, after saying why the refusal is wrong
# (for example, GitHub will not show this account the pull requests, and the branch is known to have
# none based on it).

payload="$(cat)"
# Every Bash call passes through here, and nearly none can delete a branch: answer those at once,
# before anything is loaded. What can: a DELETE method, a --delete or --delete-branch, a short flag
# cluster holding d (git push -d, gh pr merge -sd), or a refspec that is a bare :branch.
fast_re='(^|[[:space:]"'"'"'])(-[A-Za-z]*d|\+?:[A-Za-z0-9_./-]+)([[:space:]"'"'"']|$)'
case "$payload" in
  *DELETE*|*--delete*) ;;
  *) [[ "$payload" =~ $fast_re ]] || exit 0 ;;
esac

# The crude reading used only when the real one cannot run: does the payload LOOK like a delete?
looks_like_delete() {
  grep -Eq 'DELETE.*refs/heads|push.*(--delete|[[:space:]]-[A-Za-z]*d[[:space:]]|[[:space:]]\+?:[A-Za-z0-9_./-])|merge.*(--delete-branch|[[:space:]]-[A-Za-z]*d([[:space:]]|$))' <<< "$payload"
}
cannot_read() {   # $1 = what is missing or failed, as a clause
  looks_like_delete || exit 0
  echo "BLOCKED: this command looks like it deletes a branch on GitHub, and $1, so whether an open pull request is based on that branch (and would be closed by deleting it) cannot be told (claude-config#1723). Reinstall the hooks with claude-sync pull. If this refusal is wrong, say so and add SKIP_STACKED_CHECK=1 to that one command." >&2
  exit 2
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || cannot_read "$HOOK_DIR/lib/push-scope.sh, the reader of the command, could not be loaded"
# shellcheck source=lib/stacked-prs.sh
. "$HOOK_DIR/lib/stacked-prs.sh" 2>/dev/null || cannot_read "$HOOK_DIR/lib/stacked-prs.sh, which lists them, could not be loaded"
command -v python3 >/dev/null 2>&1 || cannot_read "python3 is not on PATH, and the command's words are read with it"

parsed="$(ps_parse_payload "$payload" segmented)" || cannot_read "the hook payload could not be read (neither jq nor python3 could parse it as JSON)"
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0
ps_has_override "$cmd" SKIP_STACKED_CHECK && exit 0

ps__read "$cmd"
case $? in
  0|3) ;;
  *)
    [ -f "$PS_SHELL_WORDS" ] && cannot_read "$PS_SHELL_WORDS could not read the command"
    cannot_read "$PS_SHELL_WORDS, the reader of the command, is missing" ;;
esac

# ---- the account and directory one command runs as ----
rec_tok=""; rec_repo_env=""; rec_dir=""
run_gh() { if [ -n "$rec_tok" ]; then GH_TOKEN="$rec_tok" gh "$@"; else gh "$@"; fi; }
record_context() {   # $1 = record index
  local i="$1" line acct
  rec_tok=""; rec_repo_env=""
  while IFS= read -r line; do
    case "$line" in
      GH_TOKEN=*)
        if [[ "$line" =~ ^GH_TOKEN=\$\([[:space:]]*gh[[:space:]]+auth[[:space:]]+token[[:space:]]+(-u|--user)[[:space:]=]+([A-Za-z0-9_-]+)[[:space:]]*\)$ ]]; then
          acct="${BASH_REMATCH[2]}"
          rec_tok="$(gh auth token -u "$acct" 2>/dev/null)" || rec_tok=""
        else
          case "$line" in *'$'*|*'`'*) ;; *) rec_tok="${line#GH_TOKEN=}" ;; esac
        fi ;;
      GH_REPO=*) rec_repo_env="${line#GH_REPO=}" ;;
    esac
  done <<< "${PS__R_ASSIGNS[$i]}"
  # The directory it runs in: its own git -C, then the cd in force for it, then the session's.
  rec_dir="$cwd"
  [ -n "${PS__R_DIR[$i]}" ] && rec_dir="$(ps__named_path "${PS__R_DIR[$i]}" "$cwd")"
  if [ -n "${PS__R_GITDIR[$i]}" ]; then rec_dir="$(ps__named_path "${PS__R_GITDIR[$i]}" "$rec_dir")"; fi
}
origin_slug() {   # owner/name of the checkout's origin, or nothing
  [ -d "$rec_dir" ] || return 0
  sp_github_slug "$(git -C "$rec_dir" remote get-url origin 2>/dev/null)"
}

# ---- what a command deletes ----
# Each target is "<kind> 0x1f <owner/name> 0x1f <branch> 0x1f <merged pr> 0x1f <its base> 0x1f
# <method flags>", the last three for a merge only. A command whose target cannot be told is
# refused at once, by unknown.
targets=()
unknown() {   # $1 = what could not be told
  echo "BLOCKED: $1, so whether deleting that branch would close an open pull request based on it cannot be told (claude-config#1723). If this refusal is wrong, say so and add SKIP_STACKED_CHECK=1 to that one command." >&2
  exit 2
}
branch_of_ref() {   # $1 = a ref as written; prints the branch, or nothing for a tag or other ref
  local r="${1#+}"
  r="${r//%2F//}"; r="${r//%2f//}"
  case "$r" in
    refs/heads/*) printf '%s' "${r#refs/heads/}" ;;
    refs/*|"") ;;
    *) printf '%s' "$r" ;;
  esac
}

api_target() {   # PS_RUN_ARGS of a gh api
  local -a w=(${PS_RUN_ARGS[@]+"${PS_RUN_ARGS[@]}"})
  local i n=${#w[@]} t method="" endpoint="" slug branch
  for ((i = 0; i < n; i++)); do
    t="${w[$i]}"
    case "$t" in
      -X|--method) method="${w[$((i+1))]:-}"; i=$((i+1)) ;;
      --method=*) method="${t#--method=}" ;;
      -X*) method="${t#-X}" ;;
      -H|--header|-f|--raw-field|-F|--field|--input|-q|--jq|-t|--template|--hostname|--cache|-p|--preview) i=$((i+1)) ;;
      -*) ;;
      *) [ -n "$endpoint" ] || endpoint="$t" ;;
    esac
  done
  method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
  [ "$method" = DELETE ] || return 0
  [[ "${endpoint#/}" =~ ^repos/([^/]+)/([^/]+)/git/refs/heads/(.+)$ ]] || return 0
  slug="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  branch="$(branch_of_ref "${BASH_REMATCH[3]}")"
  [ -n "$branch" ] || return 0
  case "$slug" in
    "{owner}/{repo}"|":owner/:repo")
      slug="${rec_repo_env:-$(origin_slug)}"
      [ -n "$slug" ] || unknown "this deletes branch $branch with {owner}/{repo}, and the repository that stands for could not be read from the origin of $rec_dir" ;;
  esac
  targets+=("api"$'\x1f'"$slug"$'\x1f'"$branch")
}

push_target() {   # PS_RUN_ARGS of a git push
  local -a w=(${PS_RUN_ARGS[@]+"${PS_RUN_ARGS[@]}"}) pos=()
  local i n=${#w[@]} t c deleting="" remote="" url slug ref branch
  for ((i = 0; i < n; i++)); do
    t="${w[$i]}"
    case "$t" in
      --) pos+=("${w[@]:$((i+1))}"); break ;;
      --delete) deleting=1 ;;
      --repo=*) remote="${t#--repo=}" ;;
      --repo) remote="${w[$((i+1))]:-}"; i=$((i+1)) ;;
      --push-option|--receive-pack|--exec) i=$((i+1)) ;;
      --*) ;;
      -?*)
        c="${t#-}"
        while [ -n "$c" ]; do
          case "${c:0:1}" in
            d) deleting=1 ;;
            # -o takes a value: the rest of the cluster, or the next word when it ends it.
            o) [ "${#c}" -eq 1 ] && i=$((i+1)); break ;;
          esac
          c="${c:1}"
        done ;;
      *) pos+=("$t") ;;
    esac
  done
  [ "${#pos[@]}" -gt 0 ] || return 0
  if [ -z "$remote" ]; then remote="${pos[0]}"; pos=("${pos[@]:1}"); fi
  case "$remote" in
    *://*|*@*:*) url="$remote" ;;
    *) url="$(git -C "$rec_dir" remote get-url "$remote" 2>/dev/null)" || return 0 ;;
  esac
  slug="$(sp_github_slug "$url")"
  [ -n "$slug" ] || return 0
  for ref in ${pos[@]+"${pos[@]}"}; do
    if [ -z "$deleting" ]; then
      case "$ref" in :*|+:*) ref="${ref#*:}" ;; *) continue ;; esac
    fi
    branch="$(branch_of_ref "$ref")"
    [ -n "$branch" ] && targets+=("push"$'\x1f'"$slug"$'\x1f'"$branch")
  done
}

merge_target() {   # PS_RUN_ARGS of a gh pr merge
  local -a w=(${PS_RUN_ARGS[@]+"${PS_RUN_ARGS[@]}"}) view_args=()
  local i n=${#w[@]} t c deleting="" repo="" sel="" methods="" out slug
  for ((i = 0; i < n; i++)); do
    t="${w[$i]}"
    case "$t" in
      --) break ;;
      --delete-branch|--delete-branch=true) deleting=1 ;;
      --squash|--squash=true) methods="$methods --squash" ;;
      --merge|--merge=true) methods="$methods --merge" ;;
      --rebase|--rebase=true) methods="$methods --rebase" ;;
      --repo|-R) repo="${w[$((i+1))]:-}"; i=$((i+1)) ;;
      --repo=*) repo="${t#--repo=}" ;;
      --body|--body-file|--subject|--author-email|--match-head-commit) i=$((i+1)) ;;
      --*) ;;
      -?*)
        c="${t#-}"
        while [ -n "$c" ]; do
          case "${c:0:1}" in
            s) methods="$methods --squash" ;;
            m) methods="$methods --merge" ;;
            r) methods="$methods --rebase" ;;
            d) deleting=1 ;;
            # A flag taking a value takes the rest of the cluster, or the next word when it ends it.
            R) if [ "${#c}" -eq 1 ]; then repo="${w[$((i+1))]:-}"; i=$((i+1)); else repo="${c:1}"; fi; break ;;
            b|F|t|A) [ "${#c}" -eq 1 ] && i=$((i+1)); break ;;
            *) break ;;
          esac
          c="${c:1}"
        done ;;
      *) [ -n "$sel" ] || sel="$t" ;;
    esac
  done
  [ -n "$deleting" ] || return 0
  [ -n "$repo" ] || repo="$rec_repo_env"
  [ -n "$sel" ] && view_args+=("$sel")
  [ -n "$repo" ] && view_args+=(--repo "$repo")
  if ! out="$(cd "${rec_dir:-.}" 2>/dev/null && run_gh pr view ${view_args[@]+"${view_args[@]}"} --json number,url,headRefName,baseRefName,isCrossRepository 2>&1)" \
    || ! jq -e 'type == "object" and (.headRefName | type == "string")' >/dev/null 2>&1 <<< "$out"; then
    unknown "this merges with --delete-branch, and this gate could not read the pull request it merges (GitHub said: ${out:0:300}), so which branch it would delete is not known"
  fi
  [ "$(jq -r '.isCrossRepository // false' <<< "$out")" = true ] && return 0
  slug="$(sp_github_slug "$(jq -r '.url // ""' <<< "$out" | sed -E 's#/pull/[0-9]+.*$##')")"
  [ -n "$slug" ] || slug="${repo:-$(origin_slug)}"
  [ -n "$slug" ] || unknown "this merges with --delete-branch, and the repository it merges in could not be told"
  targets+=("merge"$'\x1f'"$slug"$'\x1f'"$(jq -r '.headRefName' <<< "$out")"$'\x1f'"$(jq -r '.number // ""' <<< "$out")"$'\x1f'"$(jq -r '.baseRefName // ""' <<< "$out")"$'\x1f'"$methods")
}

# ---- judge every command in the line ----
refusals=""
judge_target() {   # $1 = a target
  local kind slug branch pr base methods nums n list="" moves="" merged_base out
  IFS=$'\x1f' read -r kind slug branch pr base methods <<< "$1"
  if ! sp_read_stacked run_gh "$slug" "$branch"; then
    refusals+="BLOCKED: this deletes branch $branch in $slug, and this gate could not list the open pull requests based on it (GitHub said: ${SP_OUT:0:300}, exit $SP_RC), so whether deleting it would close any cannot be told. GitHub closes a pull request the moment its base branch is deleted, and a closed pull request's base can never be changed again (claude-config#1723). List them yourself with gh pr list --repo $slug --base $branch --state open, move any onto the branch the merged pull request went into, and then delete. If this refusal is wrong, say so and add SKIP_STACKED_CHECK=1 to that one command."$'\n'
    return
  fi
  nums="$SP_STACKED"
  [ -n "$nums" ] || return 0
  for n in $nums; do
    case "$n" in ''|*[!0-9]*) unknown "GitHub listed '$n' among the pull requests based on $branch in $slug, which is not a number" ;; esac
    list="$list #$n"
  done
  if [ "$kind" = merge ]; then
    [ -n "$base" ] || base="the merged pull request's base"
    refusals+="BLOCKED: gh pr merge --delete-branch deletes branch $branch in $slug as it merges #$pr, and that would close the open pull request(s) based on it:$list. GitHub closes a pull request the moment its base branch is deleted, and a closed pull request's base can never be changed again, so it would have to be opened again as a new one (claude-config#1723). Merge with the helper instead, which merges, moves each onto $base and only then deletes the branch:"$'\n'"  bash ~/.claude/hooks/lib/merge-when-ready.sh $pr --repo $slug${methods} --delete-branch"$'\n'"If this refusal is wrong, say so and add SKIP_STACKED_CHECK=1 to that one command."$'\n'
    return
  fi
  # The base to move them onto is the one the merged pull request from this branch went into, read,
  # never guessed: a branch of a stack merges into its parent, not always the default branch.
  merged_base=""
  if out="$(run_gh pr list --repo "$slug" --head "$branch" --state merged --limit 1 --json number,baseRefName 2>/dev/null)"; then
    merged_base="$(jq -r 'if type == "array" then (.[0].baseRefName // "") else "" end' <<< "$out" 2>/dev/null)"
  fi
  if [ -n "$merged_base" ]; then
    for n in $nums; do moves="$moves"$'\n'"  gh pr edit $n --repo $slug --base $merged_base"; done
    moves="Move each onto $merged_base, the branch the merged pull request from $branch went into, and then delete:$moves"
  else
    moves="No merged pull request from $branch was found to say which branch they belong on; move each onto the branch its parent merged into (gh pr edit <number> --repo $slug --base <that branch>), and then delete."
  fi
  refusals+="BLOCKED: deleting branch $branch in $slug would close the open pull request(s) based on it:$list. GitHub closes a pull request the moment its base branch is deleted through the API or a push, and a closed pull request's base can never be changed again, so it would have to be opened again as a new one (claude-config#1723). $moves"$'\n'"If this refusal is wrong, say so and add SKIP_STACKED_CHECK=1 to that one command."$'\n'
}

# Each command's targets are judged before the next is read, so the list is asked as the account
# that command runs as, in the directory it runs in.
i="${PS__M_FIRST[$PS__HIT]}"; end=$((i + PS__M_COUNT[PS__HIT]))
while [ "$i" -lt "$end" ]; do
  targets=()
  if ps_runs_at gh "$i" api; then
    record_context "$i"; api_target
  elif ps_runs_at git "$i" push; then
    record_context "$i"; push_target
  elif ps_runs_at gh "$i" pr merge; then
    record_context "$i"; merge_target
  fi
  if [ "${#targets[@]}" -gt 0 ]; then for t in "${targets[@]}"; do judge_target "$t"; done; fi
  i=$((i + 1))
done
[ -n "$refusals" ] || exit 0
printf '%s' "$refusals" >&2
exit 2
