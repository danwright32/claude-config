#!/usr/bin/env bash
#
# push-scope.sh: shared helpers for hooks that act on a `git push`.
#
# Sourced, never executed. Holds the three things every push hook has to work
# out for itself, so they exist once rather than once per hook:
#   ps_is_git_push: is this command actually a push (leading tokens, not a
#                      substring, so an `echo "git push"` cannot trigger a hook)
#   ps_commit_in_chain / ps_add_in_chain: does the same command commit/stage
#                      before pushing? PreToolUse runs BEFORE the command, so a
#                      `git add … && git commit … && git push` has nothing in
#                      history yet and the pending work must be folded in.
#   ps_base_ref / ps_merge_base: what the pushed commits are measured against.
#
# Every function is pure: it reads its arguments and echoes or returns, touching
# no globals, so a caller can use one without inheriting the others.

# True when the command runs a git push, judged by the LEADING TOKENS of each
# shell segment. Substring matching is wrong here: a command whose payload
# merely mentions a push (an echo, a doc write, a commit message) would fire a
# hook that has nothing to act on.
# ---- reading the hook payload, once (claude-config#102) ----
# This lived in five near copies across the hooks, and they had already drifted: three flattened a
# newline into "; " and two did not, which is how claude-config#97 came to live in exactly the
# three that guard a push. A fix applied to one copy was not applied to the others, and nothing
# anywhere reported the difference.
#
# Output is always the command, then a unit separator, then the working directory, whether or not
# the caller wants the second half. One shape means every caller reads it the same way.
#
# MODE decides what happens to a newline, which is the one thing the callers genuinely differ on:
#   segmented  a newline becomes "; ", because it IS a command separator and the caller is about
#              to ask what each segment starts with. Anything that asks "is this a push" needs it.
#   raw        the command is left exactly as typed, for a caller that searches the whole text
#              rather than splitting it, and would otherwise be shown something the person did
#              not write.
ps_parse_payload() {   # $1 = payload JSON  $2 = segmented (default) | raw
  local payload="${1:-}" mode="${2:-segmented}" sep
  case "$mode" in
    segmented) sep="; " ;;
    raw)       sep="" ;;
    # An unknown mode is refused rather than guessed at: guessing here decides whether a gate can
    # see a command at all, and the safe side of that is not a default (L50).
    *)         return 2 ;;
  esac
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -j --arg sep "$sep" '
      ((.tool_input.command // "") | if $sep == "" then . else gsub("\n"; $sep) end)
      + "\u001f" + (.cwd // "")
    ' 2>/dev/null && return 0
  fi
  printf '%s' "$payload" | PS_SEP="$sep" python3 -c '
import os, sys, json
sep = os.environ.get("PS_SEP", "; ")
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ti = d.get("tool_input") or {}
cmd = ti.get("command") or ""
if sep:
    cmd = cmd.replace("\n", sep)
sys.stdout.write(cmd + "\x1f" + (d.get("cwd") or ""))
' 2>/dev/null
}

ps_is_git_push() {
  local cmd="$1" seg
  while IFS= read -r seg; do
    ps__segment_is_push "$seg" && return 0
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

# Which repository is this push about? The hook payload's cwd is the SESSION's
# directory, which is only the project when the session was started there. A
# session rooted elsewhere reaches a project as `cd <repo> && git push` or
# `git -C <repo> push`, and reading the cwd alone makes every one of those pushes
# invisible to the hook. Invisible is indistinguishable from nothing-to-say, so
# prefer a directory named IN the command and fall back to the cwd.
#
# Echoes the directory, or nothing when neither is a work tree.
ps_repo_dir() {
  local cmd="$1" cwd="${2:-}" cand=""

  # `git -C <path> … push`
  cand="$(printf '%s' "$cmd" | sed -nE 's@.*(^|[[:space:];&|])(rtk[[:space:]]+)?git[[:space:]]+-C[[:space:]]+([^[:space:]]+).*@\3@p' | awk 'NR <= 1')"
  if [ -n "$cand" ] && ps__is_worktree "$cand"; then printf '%s' "$cand"; return 0; fi

  # `cd <path> && … git push`
  cand="$(printf '%s' "$cmd" | sed -nE 's@(^|[[:space:];&|])cd[[:space:]]+([^[:space:]&|;]+).*@\2@p' | awk 'NR <= 1')"
  cand="${cand%\"}"; cand="${cand#\"}"
  cand="${cand%\'}"; cand="${cand#\'}"
  if [ -n "$cand" ] && ps__is_worktree "$cand"; then printf '%s' "$cand"; return 0; fi

  if [ -n "$cwd" ] && ps__is_worktree "$cwd"; then printf '%s' "$cwd"; return 0; fi
  return 1
}

ps__is_worktree() {
  [ -d "$1" ] || return 1
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# The command is handed to grep as a here-string in the three questions below, never piped from
# printf (claude-config#403). A quiet grep leaves on its first match, and with the match near the
# start of a command longer than a pipe buffer (a heredoc commit message) the printf was killed
# holding the rest. Every hook sourcing this file runs under pipefail, so that death became the
# answer and a present override or commit read as absent (L183). This file never says pipefail
# itself, which is how the ratchet for exactly this shape never read it.

# Does the command carry an inline `VAR=1` override, e.g. SKIP_TEST_CHECK=1?
ps_has_override() {
  # $1 command, $2 variable name
  grep -Eq "(^|[[:space:];&|])$2=1([[:space:]]|$)" <<< "$1"
}

ps_commit_in_chain() {
  grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)' <<< "$1"
}

ps_add_in_chain() {
  grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+add([[:space:]]|$)' <<< "$1" && return 0
  grep -Eq 'git[[:space:]][^&|;]*commit[[:space:]][^&|;]*-[A-Za-z]*a' <<< "$1"
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

# The ref a push should be judged AGAINST (claude-config#339). The upstream if there is one, then
# the remote's own default branch, then the usual names, then nothing. Written once here because
# three push hooks each need the same answer and three copies of it would drift, and this is the
# half whose drift is invisible: a wrong base scopes a gate to the wrong diff while still reporting
# a clean run (L70, L613).
#
# Prints the ref and returns 0, or prints nothing and returns 1. A caller that gets nothing must
# decide for itself what to do; there is no fallback here, because "judge against HEAD~1" and
# "judge nothing" are different decisions and the gates do not make them the same way.
ps_base_ref() {
  local up base c
  up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  if [ -n "$up" ]; then printf '%s' "$up"; return 0; fi
  base="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/##')"
  if [ -n "$base" ]; then printf '%s' "$base"; return 0; fi
  for c in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$c" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
  done
  return 1
}
