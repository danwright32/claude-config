#!/usr/bin/env bash
#
# merge-target.sh: shared helpers for hooks that gate a pull request merge.
#
# Sourced by the gates. Also runnable, for the one caller that is not bash: see
# the dispatch at the foot of the file. Holds the things every merge gate has to
# work out before it can say anything about a pull request, so they exist once
# rather than once per gate:
#
#   mt_is_pr_merge   is this command actually a merge
#   mt_repo_dir      which directory the merge will run in, which is not
#                      necessarily the session cwd
#   mt_checkout_dir  the checkout a directory belongs to, which is the part of
#                      that answer a non-merge caller needs too
#   mt_pr_number     the pull request the command names, if it names one
#   mt_remote_slug   owner/name from the git remote, read from the CURRENT
#                      directory, so callers cd first
#   mt_pr_view       the pull request's fields, from whichever logged-in
#                      account can actually see the repo, proved to be about
#                      the repo the remote names
#
# Every one of these was learned the hard way by block-red-merge.sh and is
# commented there with the incident that produced it. They are here rather than
# there because a second merge gate copying them would be a second copy that
# drifts, and the drift would be silent: each gate would go on passing its own
# tests while disagreeing with the other about which pull request it is looking
# at.

# True when the command runs a pull request merge.
mt_is_pr_merge() {  # $1 = command
  case "$1" in
    *"gh pr me""rge"*) return 0 ;;
    *) return 1 ;;
  esac
}

# The pull request number if the command names one; empty otherwise, in which
# case gh resolves it from the current branch, which is also what the merge
# itself would do.
mt_pr_number() {  # $1 = command
  printf '%s' "$1" \
    | grep -oE 'gh pr me''rge[[:space:]]+(--[^[:space:]]+[[:space:]]+)*([0-9]+)' \
    | grep -oE '[0-9]+$' | awk 'NR <= 1'
}

# Resolve the directory the merge will actually run in.
#
# Not necessarily the session cwd: PET keeps its git repo in a pet/ subdirectory,
# so a hook started outside any repo and gh could not resolve the pull request at
# all. That produced a false block on a green pull request the first time this
# ran.
#
# Order: an explicit `cd` at the head of the command wins, because that is where
# the merge itself will run. Otherwise the session cwd, then walk up for a repo,
# then look one level down.
mt_repo_dir() {  # $1 = command, $2 = session cwd
  local command="$1" d="$2" from_cd=""

  # Bash's own regex, not sed: macOS sed is BRE and treats \+ as a literal plus,
  # so a sed version of this silently matched nothing and every merge was blocked.
  if [[ "$command" =~ ^[[:space:]]*cd[[:space:]]+(\"[^\"]+\"|\'[^\']+\'|[^[:space:]\&\|\;]+) ]]; then
    from_cd="${BASH_REMATCH[1]}"
    from_cd="${from_cd%\"}"; from_cd="${from_cd#\"}"
    from_cd="${from_cd%\'}"; from_cd="${from_cd#\'}"
  fi
  if [ -n "$from_cd" ] && [ -d "$from_cd" ]; then printf '%s' "$from_cd"; return; fi

  [ -n "$d" ] && [ -d "$d" ] || d=$PWD
  mt_checkout_dir "$d"
}

# The checkout a directory belongs to: the directory itself, else the first
# ancestor holding a .git, else the first child holding one. When there is none
# anywhere, the directory itself, unchanged, so a caller is still handed
# somewhere it can run and reports the refusal in its own words.
#
# Named and separate because a second caller asks the same question for a
# different reason: the issue review's duplicate check has to find the checkout
# before it can ask gh anything, and it used to assume the project directory was
# one. In PET it is not, the workspace root sits above pet/, so gh refused there
# and the check had never once run in that project (claude-config#344). Two
# copies of this walk, one of them in Python, would be two rules that drift with
# each suite passing its own (L263, L370), so the copy in Python is a call to
# the executed mode at the foot of this file instead.
mt_checkout_dir() {  # $1 = a directory
  local d="$1" up sub
  [ -n "$d" ] && [ -d "$d" ] || d=$PWD

  up=$d
  while [ "$up" != "/" ]; do
    [ -e "$up/.git" ] && { printf '%s' "$up"; return; }
    up=$(dirname "$up")
  done

  for sub in "$d"/*/; do
    [ -e "${sub}.git" ] && { printf '%s' "${sub%/}"; return; }
  done
  printf '%s' "$d"
}

# owner/name from the git remote of the CURRENT directory.
#
# The identity comes from the remote, not from gh, because a check whose two
# sides come from one lookup can only confirm that lookup is self-consistent,
# never that it is correct (L70).
mt_remote_slug() {
  git config --get remote.origin.url 2>/dev/null \
    | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##'
}

# An answer is usable when it is non-empty AND names the repo the remote names.
# With no parseable remote there is nothing to compare against, so the identity
# half is skipped rather than failing every repo that has no GitHub origin.
mt_usable_answer() {  # $1 = json, $2 = remote slug
  [ -n "$1" ] || return 1
  [ -n "$2" ] || return 0
  local url; url=$(printf '%s' "$1" | jq -r '.url // ""' 2>/dev/null)
  [ -n "$url" ] || return 0
  case "$url" in
    "https://github.com/$2/pull/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# The pull request's fields, as JSON, or empty.
#
# The account gh has ACTIVE cannot necessarily see this repo. Dan runs concurrent
# sessions under different GitHub accounts, and a repo owned by one 404s under
# the other: gh then returns nothing, which is indistinguishable from a pull
# request that does not exist. Measured 2026-08-30 on nursedexapp/nursedex, where
# it blocked every merge.
#
# So: try the active account, then each other logged-in account, scoping the
# token PER CALL. Never `gh auth switch`, which changes the shared keyring's
# active account and would break whatever other session is using it.
#
# Answers with an ENVELOPE rather than the bare view, and with a global:
#
#   {"found":true,"view":{...}}
#   {"found":false,"wrongRepo":"https://github.com/someone/else/pull/7"}
#
# because callers read this through a command substitution, which runs it in a
# subshell, so anything it assigns to a variable is discarded on the way out. The
# first version set a global here and the caller always saw it empty: an answer
# about the WRONG repo was reported as gh having said nothing at all, which is a
# different fault with a different remedy (L11). Its own test caught that.
#
# wrongRepo lets a caller tell "gh said nothing" from "gh answered about
# something else" and refuse each in its own words.
mt_pr_view() {  # $1 = pr number or empty, $2 = --json field list, $3 = remote slug
  local pr="$1" fields="$2" slug="$3" answer candidate account token wrong=""

  if [ -n "$pr" ]; then
    answer=$(gh pr view "$pr" --json "$fields" 2>/dev/null)
  else
    answer=$(gh pr view --json "$fields" 2>/dev/null)
  fi
  if mt_usable_answer "$answer" "$slug"; then
    printf '%s' "$answer" | jq -c '{found: true, view: .}'
    return 0
  fi

  [ -n "$answer" ] && wrong=$(printf '%s' "$answer" | jq -r '.url // ""' 2>/dev/null)

  for account in $(gh auth status 2>/dev/null \
      | grep -oE 'account [A-Za-z0-9_.-]+' | awk '{print $2}' | sort -u); do
    token=$(gh auth token -u "$account" 2>/dev/null) || continue
    [ -n "$token" ] || continue
    if [ -n "$pr" ]; then
      candidate=$(GH_TOKEN="$token" gh pr view "$pr" --json "$fields" 2>/dev/null)
    else
      candidate=$(GH_TOKEN="$token" gh pr view --json "$fields" 2>/dev/null)
    fi
    if mt_usable_answer "$candidate" "$slug"; then
      printf '%s' "$candidate" | jq -c '{found: true, view: .}'
      return 0
    fi
    if [ -n "$candidate" ] && [ -z "$wrong" ]; then
      wrong=$(printf '%s' "$candidate" | jq -r '.url // ""' 2>/dev/null)
    fi
  done

  jq -nc --arg wrong "$wrong" '{found: false, wrongRepo: $wrong}'
  return 1
}

# EXECUTED mode, for a caller that cannot source bash. Guarded on this file
# being the script rather than the source, because both merge gates source it
# and a dispatch that ran on the way in would run with whatever positional
# arguments the gate was holding.
#
# It refuses a subcommand it does not know rather than falling back to a default
# answer: a run about the wrong thing is indistinguishable afterwards from a run
# about the right one (L320).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    checkout-dir) mt_checkout_dir "${2:-}" ;;
    *)
      echo "merge-target.sh: unknown subcommand [${1:-}] (known: checkout-dir <dir>)" >&2
      exit 2
      ;;
  esac
fi
