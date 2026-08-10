#!/usr/bin/env bash
#
# push-scope.sh — shared helpers for hooks that act on a `git push`.
#
# Sourced, never executed. Holds the three things every push hook has to work
# out for itself, so they exist once rather than once per hook:
#   ps_is_git_push   — is this command actually a push (leading tokens, not a
#                      substring, so an `echo "git push"` cannot trigger a hook)
#   ps_commit_in_chain / ps_add_in_chain — does the same command commit/stage
#                      before pushing? PreToolUse runs BEFORE the command, so a
#                      `git add … && git commit … && git push` has nothing in
#                      history yet and the pending work must be folded in.
#   ps_base_ref / ps_merge_base — what the pushed commits are measured against.
#
# Every function is pure: it reads its arguments and echoes or returns, touching
# no globals, so a caller can use one without inheriting the others.

# True when the command runs a git push, judged by the LEADING TOKENS of each
# shell segment. Substring matching is wrong here: a command whose payload
# merely mentions a push (an echo, a doc write, a commit message) would fire a
# hook that has nothing to act on.
ps_is_git_push() {
  local cmd="$1" seg
  while IFS= read -r seg; do
    : "$seg"
  done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;|\|)/\n/g')
  return 1
}

ps__segment_is_push() {
  # Tokenize crudely on whitespace: quoting only matters here for arguments we
  # already skip, and a quoted subcommand is not a thing.
  local seg="$1"
  local -a tok
  read -r -a tok <<< "$seg"
  local i=0 n=${#tok[@]} t

  # Leading environment assignments: SKIP_TEST_CHECK=1 git push
  while [ "$i" -lt "$n" ]; do
    case "${tok[$i]}" in
      [A-Za-z_]*=*) i=$((i+1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 1

  # The binary, with any leading path stripped. `rtk git push` is the same push:
  # the rtk-rewrite hook rewrites git commands, so a hook that only knew about
  # bare `git` would silently stop firing.
  t="${tok[$i]##*/}"
  if [ "$t" = "rtk" ]; then
    i=$((i+1))
    [ "$i" -lt "$n" ] || return 1
    t="${tok[$i]##*/}"
  fi
  [ "$t" = "git" ] || return 1
  i=$((i+1))

  # Walk to the subcommand, skipping git's own options. The two-part options
  # must consume their argument, or `git -C /some/path status` would read as a
  # command whose subcommand is a path.
  while [ "$i" -lt "$n" ]; do
    t="${tok[$i]}"
    case "$t" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path)
        i=$((i+2)) ;;
      -*) i=$((i+1)) ;;
      [A-Za-z_]*=*) i=$((i+1)) ;;
      push) return 0 ;;
      *) return 1 ;;   # some other subcommand
    esac
  done
  return 1
}

# Does the command carry an inline `VAR=1` override, e.g. SKIP_TEST_CHECK=1?
ps_has_override() {
  # $1 command, $2 variable name
  printf '%s' "$1" | grep -Eq "(^|[[:space:];&|])$2=1([[:space:]]|$)"
}

ps_commit_in_chain() {
  printf '%s' "$1" | grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'
}

ps_add_in_chain() {
  printf '%s' "$1" | grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+add([[:space:]]|$)' && return 0
  printf '%s' "$1" | grep -Eq 'git[[:space:]][^&|;]*commit[[:space:]][^&|;]*-[A-Za-z]*a'
}

# What the pushed commits are measured against: the branch's upstream if it has
# one, else the remote's default branch, else a local main/master.
ps_base_ref() {
  local base
  base="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  if [ -n "$base" ]; then printf '%s' "$base"; return 0; fi
  base="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/##')"
  if [ -n "$base" ]; then printf '%s' "$base"; return 0; fi
  local c
  for c in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$c" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

# The commit the pushed range starts from. Falls back to HEAD~1 so a repo with
# no resolvable base still yields the most recent change rather than nothing.
#
# The second fallback matters as much as the first: with no upstream, ps_base_ref
# walks down to a local `main`, which on an unpushed branch IS the current branch,
# so the merge-base comes back as HEAD and the range is empty. A caller cannot
# tell that empty range from "this push adds nothing", so it would read a scan of
# zero commits as a clean result. Drop to HEAD~1 instead and scan the real change.
ps_merge_base() {
  local base="${1:-}" mb=""
  if [ -n "$base" ] && git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
    mb="$(git merge-base "$base" HEAD 2>/dev/null)"
  fi
  if [ -z "$mb" ] || [ "$mb" = "$(git rev-parse HEAD 2>/dev/null)" ]; then
    mb="$(git rev-parse --verify --quiet HEAD~1 2>/dev/null)"
  fi
  printf '%s' "$mb"
}
