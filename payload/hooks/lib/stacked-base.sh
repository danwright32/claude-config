#!/usr/bin/env bash
# lib/stacked-base.sh: the base a STACKED branch is judged from at a push (claude-config#3444).
#
# A branch cut from another open branch was judged all the way back to the default branch, so its
# push answered for the base branch's changes as well as its own. On 2026-11-21 the pre push test
# gate refused a branch stacked on pull request 3421 for changes that belong to 3421, and on
# 2026-11-22 the lessons review twice refused a branch stacked two deep for stopping findings in
# files its base branches own.
#
# ONE function answers "is this branch stacked, and on what", and both gates ask it, so the two can
# never come to judge one push from two different places (L261, L613). It narrows what a gate reads,
# so it answers only what it can establish; anything short of that is "not established", and the
# gate judges from the default branch exactly as before. The narrower range is never a guess.
#
#   sb_stacked_base <directory> [<floor commit>]
#     prints one line and returns 0 when a base is established:
#       base <remote ref> <commit> <pull request number>      e.g.  base origin/fix/a 1f3c... 3421
#     and otherwise prints why not:
#       none <the reason, in words>
#     returning 1 when it found no other branch under this one, or could not look for one (a
#     directory it cannot enter, a repository with no commit, a detached HEAD, a missing
#     lib/push-scope.sh, no known default branch, no merge base with it): a gate's refusal says
#     nothing for a 1. It returns 2 when a branch does lie under this one and could not be
#     established as the base, which a gate's refusal says, since that branch is then part of what
#     was judged.
#     It runs in a subshell, so it changes no directory and sets nothing in the caller.
#
# A base is ESTABLISHED only when every one of these holds:
#   1. HEAD is on a named branch. Detached, the branch's own copy on origin cannot be told from a
#      base by name.
#   2. A branch on origin, which is not the default branch and not this branch's own copy (the one
#      of its own name), has its tip in HEAD's history, short of HEAD, past the floor (where the
#      gate's range starts today; the merge base with the default branch when none is given) and
#      not already on the default branch. The tip is this checkout's copy of the ref, which is what
#      the next step checks against GitHub. The branch's upstream is neither favoured nor left out:
#      a branch cut from origin's copy of its base tracks that base, which is the commonest stack,
#      and it is a candidate on the same terms as any other branch.
#      A branch that merely NAMES a base (an upstream, the setting
#      gh pr create records, its own pull request's base) and does not descend from it has no such
#      tip, so naming establishes nothing.
#   3. It is the NEAREST such tip: every other one is in its history. Two that do not hold each
#      other (a branch that merged two others) is not a stack this can read, and is not established.
#      Only the nearest is asked about: when it fails, the one under it is never tried, because the
#      nearest's own changes would then be judged by nobody.
#   4. GitHub says an OPEN pull request of this repository (never a fork's) has that branch as its
#      head AT EXACTLY THAT COMMIT. This is the half the pusher does not control alone: a remote ref
#      in this checkout can be moved by hand onto a commit that was never pushed, and GitHub's own
#      head for the pull request is what refuses it. It is also what says the base's changes are
#      still to be judged: an open pull request cannot merge until the merge gate's lessons review
#      has read its whole range (pr-review-gate.sh), and a base whose pull request is closed, merged
#      or gone, or that was never pushed, fails here.
# A read of GitHub that fails, times out or needs a tool that is missing is "not established": the
# gate then reads more, never less (L93). What that costs is the defect this file exists for, a
# stacked push refused for its base's changes, and the reason says which read failed.
#
# The read is one `gh pr view <branch>` through mt_pr_view (lib/merge-target.sh), so it is asked as
# whichever logged in account can see the repository, and it is bounded: SB_READ_SECONDS for all the
# reads of one question together (lib/bounded-run.sh). GitHub is asked only when step 2 found a
# candidate, so a branch cut from the default branch costs one listing of origin's refs and no
# request at all.

# Its own folder, set once and plainly, so a reader of this file can follow what it sources (the
# Slack drafts gate reads every script a command runs, and could not follow a second assignment).
_SB_LIB="${BASH_SOURCE[0]%/*}"; [ "$_SB_LIB" != "${BASH_SOURCE[0]}" ] || _SB_LIB=.

# Seconds every GitHub read of one question may take together. A gate's own deadline counts them.
SB_READ_SECONDS=10

sb_stacked_base() {   # $1 = a directory inside the repository  $2 = floor commit, or empty
  (
    # Loaded before the subshell changes directory, since this file may be sourced by a relative
    # path; SB__LIB_ABS is the same folder for the process the GitHub read runs in.
    declare -F ps__default_ref >/dev/null || . "$_SB_LIB/push-scope.sh" 2>/dev/null
    declare -F bounded_run >/dev/null || . "$_SB_LIB/bounded-run.sh" 2>/dev/null
    SB__LIB_ABS="$(cd "$_SB_LIB" 2>/dev/null && pwd)"
    sb__answer "${1:-.}" "${2:-}"
  )
}

# One field of an established answer, so no caller cuts the line up for itself: ref, tip or pr.
# Prints nothing and returns 1 for an answer that establishes no base.
sb_field() {   # $1 = sb_stacked_base's answer  $2 = ref | tip | pr
  local rest
  case "$1" in "base "*) ;; *) return 1 ;; esac
  rest="${1#base }"
  case "$2" in
    ref) printf '%s' "${rest%% *}" ;;
    tip) rest="${rest#* }"; printf '%s' "${rest%% *}" ;;
    pr) printf '%s' "${rest##* }" ;;
    *) return 1 ;;
  esac
}

sb__none() { printf 'none %s\n' "$1"; return 1; }

# GitHub's one line answer split on tabs into the caller's `fields`, every empty field kept, the
# last one included. Returns 1 unless there are exactly the five that were asked for.
sb__fields() {   # $1 = the line
  local rest="$1"
  fields=()
  while :; do
    case "$rest" in
      *$'\t'*) fields+=("${rest%%$'\t'*}"); rest="${rest#*$'\t'}" ;;
      *) fields+=("$rest"); break ;;
    esac
  done
  [ "${#fields[@]}" -eq 5 ]
}

# One more item on a list in words: "a", then "a and b", then "a, b and c".
sb__and() {   # $1 = the list so far, or empty  $2 = the item
  case "$1" in
    "") printf '%s' "$2" ;;
    *" and "*) printf '%s, %s and %s' "${1% and *}" "${1##* and }" "$2" ;;
    *) printf '%s and %s' "$1" "$2" ;;
  esac
}

sb__answer() {
  local dir="$1" floor="$2" head branch def tip ref near="" i j n holds
  local -a tips=() refs=()
  cd "$dir" 2>/dev/null || { sb__none "$dir is not a directory that can be entered"; return 1; }
  head="$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
  [ -n "$head" ] || { sb__none "the repository has no commit yet"; return 1; }
  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)"
  [ -n "$branch" ] || { sb__none "HEAD is detached, so this branch's own copy on origin cannot be told from a base"; return 1; }
  declare -F ps__default_ref >/dev/null || { sb__none "lib/push-scope.sh is missing, so origin's default branch could not be read"; return 1; }
  def="$(ps__default_ref)"
  [ -n "$def" ] || { sb__none "this checkout knows no default branch for origin"; return 1; }
  [ -n "$floor" ] || floor="$(git merge-base "$def" "$head" 2>/dev/null)"
  floor="$(git rev-parse --verify --quiet "$floor^{commit}" 2>/dev/null)"
  [ -n "$floor" ] || { sb__none "this branch has no merge base with $def"; return 1; }

  # Read into a variable first, which waits for git, then fed from a here document: a child the
  # shell never waits for can cost bash 3.2 what it prints next (claude-config#1984). An empty
  # listing is one empty line, which the first test in the loop skips.
  local listing
  listing="$(git for-each-ref --merged "$head" --format='%(objectname) %(refname)' refs/remotes/origin 2>/dev/null)" || listing=""
  while read -r tip ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      refs/remotes/origin/HEAD|"refs/remotes/$def"|"refs/remotes/origin/$branch") continue ;;
    esac
    [ "$tip" = "$head" ] && continue
    [ "$tip" = "$floor" ] && continue
    git merge-base --is-ancestor "$floor" "$tip" 2>/dev/null || continue
    git merge-base --is-ancestor "$tip" "$def" 2>/dev/null && continue
    tips+=("$tip"); refs+=("$ref")
  done <<SB_REFS
$listing
SB_REFS
  n=${#tips[@]}
  [ "$n" -gt 0 ] || { sb__none "no other branch on origin lies between $def and this branch"; return 1; }

  for ((i = 0; i < n; i++)); do
    holds=1
    for ((j = 0; j < n; j++)); do
      [ "${tips[$j]}" = "${tips[$i]}" ] && continue
      git merge-base --is-ancestor "${tips[$j]}" "${tips[$i]}" 2>/dev/null || { holds=0; break; }
    done
    if [ "$holds" -eq 1 ]; then near="${tips[$i]}"; break; fi
  done
  [ -n "$near" ] || { sb__none "more than one branch on origin lies under this one and none of them holds the others"; return 2; }

  local t name why="" left deadline line num state hname hoid cross rerr missing
  local -a fields=()
  for t in gh jq perl; do
    command -v "$t" >/dev/null 2>&1 || { sb__none "$t is not on PATH, so GitHub could not be asked whether the branch under this one is an open pull request"; return 2; }
  done
  declare -F bounded_run >/dev/null || { sb__none "lib/bounded-run.sh is missing, so GitHub could not be asked inside a time limit"; return 2; }
  [ -n "${SB__LIB_ABS:-}" ] && [ -f "$SB__LIB_ABS/merge-target.sh" ] || { sb__none "lib/merge-target.sh is missing, so GitHub could not be asked"; return 2; }
  deadline=$((SECONDS + SB_READ_SECONDS))
  for ((i = 0; i < n; i++)); do
    [ "${tips[$i]}" = "$near" ] || continue
    name="${refs[$i]#refs/remotes/origin/}"
    left=$((deadline - SECONDS))
    if [ "$left" -lt 1 ]; then why="GitHub did not answer about origin/$name within ${SB_READ_SECONDS}s"; break; fi
    # A process of its own, so the bound can end it: the library's reader walks every logged in account.
    bounded_run "$left" bash -c '. "$1/merge-target.sh" 2>/dev/null && mt_pr_view "$2" "number,url,state,headRefName,headRefOid,isCrossRepository" "$(mt_remote_slug)" "" 2>/dev/null' _ "$SB__LIB_ABS" "$name"
    if [ "$BOUNDED_RC" -eq 124 ]; then why="GitHub did not answer about origin/$name within ${SB_READ_SECONDS}s"; break; fi
    line="$(printf '%s' "$BOUNDED_OUT" | jq -r 'select(.found == true) | .view | [(.number | tostring), (.state // ""), (.headRefName // ""), (.headRefOid // ""), (if .isCrossRepository == null then "" else (.isCrossRepository | tostring) end)] | @tsv' 2>/dev/null)"
    if [ -z "$line" ]; then
      # No pull request, and a read that failed, are different faults with different remedies
      # (L11): the reader's envelope says which, and a process that printed none says its exit.
      rerr="the read ended with exit $BOUNDED_RC and no answer"
      if [ -n "$BOUNDED_OUT" ]; then
        rerr="$(printf '%s' "$BOUNDED_OUT" | jq -r 'if (.notFound // false) then "" elif ((.error // "") != "") then .error elif ((.wrongRepo // "") != "") then ("it answered about " + .wrongRepo) else "no answer" end' 2>/dev/null)" \
          || rerr="the read ended with exit $BOUNDED_RC and an answer that could not be read"
      fi
      if [ -n "$rerr" ]; then why="GitHub could not be read about origin/$name ($rerr)"
      else why="GitHub named no pull request for origin/$name"; fi
      continue
    fi
    # Split keeping empty fields: tab is whitespace to `read`, which merges two tabs into one and
    # moves every later field along, so the reason named the wrong one (claude-config#3463). Only
    # the first line is read, as `read` read it.
    if ! sb__fields "${line%%$'\n'*}"; then
      why="GitHub's answer about origin/$name could not be read: it held ${#fields[@]} fields where 5 were expected"; continue
    fi
    num="${fields[0]}"; state="${fields[1]}"; hname="${fields[2]}"; hoid="${fields[3]}"; cross="${fields[4]}"
    missing=""
    [ -n "$num" ] || missing="$(sb__and "$missing" "its number")"
    [ -n "$state" ] || missing="$(sb__and "$missing" "its state")"
    [ -n "$hname" ] || missing="$(sb__and "$missing" "its head branch")"
    [ -n "$hoid" ] || missing="$(sb__and "$missing" "its head commit")"
    [ -n "$cross" ] || missing="$(sb__and "$missing" "whether it comes from a fork")"
    if [ -n "$missing" ]; then why="GitHub's answer about origin/$name left out $missing"; continue; fi
    if [ "$hname" != "$name" ]; then why="GitHub answered about another branch than origin/$name"; continue; fi
    if [ "$state" != OPEN ]; then why="pull request #$num of origin/$name is not open (GitHub says $state)"; continue; fi
    if [ "$cross" != false ]; then why="pull request #$num of $name comes from a fork, not from this repository"; continue; fi
    if [ "$hoid" != "$near" ]; then
      why="GitHub has pull request #$num of origin/$name at ${hoid:0:7}, and this checkout's copy of that branch is at ${near:0:7}"; continue
    fi
    printf 'base origin/%s %s %s\n' "$name" "$near" "$num"
    return 0
  done
  sb__none "${why:-GitHub could not be asked about the branch under this one}"
  return 2
}
