#!/usr/bin/env bash
# claim-issue.sh: claim a GitHub issue on the issue itself before a builder starts on it
# (claude-config#3317).
#
#   claim-issue.sh claim   <owner/repo> <issue> <branch>
#   claim-issue.sh check   <owner/repo> <issue> <branch>
#   claim-issue.sh release <owner/repo> <issue> <branch> <reason>
#
# Why it exists. On 2026-11-19 two sessions, one on each Mac, built the same fix for #3285. A branch
# that exists only in a local worktree is invisible to the other Mac, and nothing on the issue said
# the work was taken, so only a note on the issue can carry the claim. The orchestrate skill's rule
# is to run `claim` before dispatching a builder for an issue and to dispatch only on exit 0.
#
# claim does three reads, and refuses when any of them shows another session holds the issue:
#   1. the claims on the issue: a live claim posted by this script from another Mac or branch;
#   2. open pull requests naming it (#<issue> in the title or body, or a branch that names it);
#   3. remote branches that name it.
# Which issues a branch names is read by hooks/lib/branch-issues.mjs, the one shared reader.
# When none does, it posts a claim naming the Mac (as Dan names them), the time in ET and the
# branch, then reads the issue back. Two sessions that both found the issue free both post; the
# claim GitHub shows first wins, and the later one posts its own release and exits 1.
#
# check does the same reads and posts nothing. release posts that this Mac's claim on that branch
# has ended, with the reason, so the claim does not block the next session; it posts nothing when
# there is no live claim of ours to release.
#
# A claim is held by a hidden marker line, never by the prose around it:
#   <!-- orchestrate-claim branch=<branch> host=<host> -->
#   <!-- orchestrate-release branch=<branch> host=<host> -->
# A claim with no release goes stale after CLAIM_STALE_HOURS (default 24) and stops blocking; it is
# still printed. The open pull request and remote branch reads block whatever a claim's age.
#
# Exit codes: 0 claimed by us (or free, for check, or released); 1 held by someone else or closed,
# do not start it; 2 could not check, or bad arguments: do not start it. After exit 2 nothing was
# claimed unless the message says a claim may have been posted (the post errored, or the claim could
# not be read back); then it names the release command to run.
# A failed read is never taken as "nobody holds it".
#
# Test seams: CLAIM_NOW (epoch seconds) and CLAIM_HOST stand in for the clock and the hostname, and
# CLAIM_READBACK_WAIT (seconds, default 2) and CLAIM_READBACK_TRIES (default 3) for the read back.
set -uo pipefail

STALE_HOURS="${CLAIM_STALE_HOURS:-24}"
READBACK_WAIT="${CLAIM_READBACK_WAIT:-2}"
READBACK_TRIES="${CLAIM_READBACK_TRIES:-3}"
BRANCH_READER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/branch-issues.mjs"

usage() {
  echo "usage: claim-issue.sh claim|check <owner/repo> <issue> <branch>" >&2
  echo "       claim-issue.sh release <owner/repo> <issue> <branch> <reason>" >&2
  exit 2
}

mode="${1:-}"
repo="${2:-}"
issue="${3:-}"
branch="${4:-}"
reason="${5:-}"
case "$mode" in claim|check|release) ;; *) usage ;; esac
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "COULD NOT CHECK: '$repo' is not owner/repo." >&2; usage; }
[[ "$issue" =~ ^[0-9]+$ ]] || { echo "COULD NOT CHECK: '$issue' is not an issue number." >&2; usage; }
[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "COULD NOT CHECK: '$branch' is not a branch name this script can record." >&2; usage; }
if [ "$mode" = release ] && [ -z "$reason" ]; then
  echo "COULD NOT CHECK: a release needs a reason, such as 'handed back unfinished'." >&2
  usage
fi

now="${CLAIM_NOW:-$(date +%s)}"
host="${CLAIM_HOST:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"

mac_name() { # the Mac as Dan names it (global CLAUDE.md, Projects)
  case "$1" in
    Dans-MacBook-Pro) echo "the work MacBook" ;;
    Daniels-MacBook-Pro-2) echo "the personal MacBook" ;;
    *) echo "the Mac named $1" ;;
  esac
}
et_time() { # epoch seconds to "11:25 AM ET on 2026-11-19", on macOS date or GNU date
  TZ=America/New_York date -r "$1" '+%-I:%M %p ET on %Y-%m-%d' 2>/dev/null ||
    TZ=America/New_York date -d "@$1" '+%-I:%M %p ET on %Y-%m-%d'
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---- the reads ----
# The issue's state, then every marker line in its comments, each prefixed with its comment's time.
issue_jq='"STATE " + .state, (.comments[] | (.createdAt | fromdateiso8601 | tostring) as $t | .body | gsub("\r"; "") | split("\n")[] | select(startswith("<!-- orchestrate-")) | $t + " " + .)'
read_issue() { # fills $tmp/issue; returns non zero, with the reason in $tmp/issue.err, when it cannot
  if ! gh issue view "$issue" --repo "$repo" --json state,comments --jq "$issue_jq" >"$tmp/issue" 2>"$tmp/issue.err"; then
    return 1
  fi
  # No STATE line means gh printed nothing it was asked for, which is not an empty issue.
  if ! grep -q '^STATE ' "$tmp/issue"; then
    echo "gh returned no state for the issue" >"$tmp/issue.err"
    return 1
  fi
}

# Live claims, in the order GitHub shows them: "epoch branch host" per line. A release ends the
# claim with the same branch and host. awk, not a bash associative array, which the bash 3.2 macOS
# ships does not have.
live_claims() {
  awk '
    NF == 6 && $2 == "<!--" && $6 == "-->" &&
      $1 ~ /^[0-9]+$/ &&
      $4 ~ /^branch=/ && $5 ~ /^host=/ {
      key = substr($4, 8) " " substr($5, 6)
      if ($3 == "orchestrate-claim") {
        if (!(key in when)) { n++; order[n] = key; pos[key] = n }
        when[key] = $1
      } else if ($3 == "orchestrate-release") {
        delete when[key]
      }
    }
    END { for (i = 1; i <= n; i++) { k = order[i]; if ((k in when) && pos[k] == i) print when[k], k } }
  ' "$tmp/issue"
}

# Prints nothing. Fills three globals from the live claims: blocking (one line per claim held by
# another session), stale (one line per claim past the stale window, which does not block) and
# first_holder ("ours" or "other" for whoever holds the first live claim GitHub lists, "" for none).
blocking=()
stale=()
first_holder=""
judge_claims() {
  local t b h
  blocking=(); stale=(); first_holder=""
  live_claims >"$tmp/live"
  while read -r t b h; do
    [ -n "$t" ] || continue
    local who="$(mac_name "$h") claimed it at $(et_time "$t"), branch $b"
    if [ $((now - t)) -gt $((STALE_HOURS * 3600)) ]; then
      stale+=("stale claim, older than $STALE_HOURS hours with no release, so not counted: $who")
      continue
    fi
    if [ "$b" = "$branch" ] && [ "$h" = "$host" ]; then
      [ -n "$first_holder" ] || first_holder=ours
    else
      [ -n "$first_holder" ] || first_holder=other
      blocking+=("claim: $who")
    fi
  done <"$tmp/live"
}

fail_read() { # fail_read <what> <error file>
  echo "COULD NOT CHECK: could not read $1 for $repo#$issue, so whether another session holds it is unknown. Do not start it, and nothing was claimed."
  sed 's/^/  /' "$2"
  exit 2
}

post() { # post <body file>
  gh issue comment "$issue" --repo "$repo" --body-file "$1" >/dev/null 2>"$tmp/post.err"
}

release_body() { # release_body <reason> <file>
  {
    echo "Released by the session on $(mac_name "$host") at $(et_time "$now"): work on branch \`$branch\` stopped ($1). Another session may take this issue."
    echo ""
    echo "<!-- orchestrate-release branch=$branch host=$host -->"
  } >"$2"
}

read_issue || fail_read "the issue's comments" "$tmp/issue.err"

# ---- release ----
if [ "$mode" = release ]; then
  ours=no
  live_claims >"$tmp/live"
  while read -r t b h; do
    [ "$b" = "$branch" ] && [ "$h" = "$host" ] && ours=yes
  done <"$tmp/live"
  if [ "$ours" = no ]; then
    echo "NOTHING TO RELEASE: $repo#$issue has no live claim from $(mac_name "$host") on branch $branch. Nothing posted."
    exit 0
  fi
  release_body "$reason" "$tmp/release"
  if ! post "$tmp/release"; then
    echo "COULD NOT RELEASE: the release was not posted on $repo#$issue, so the claim still stands."
    sed 's/^/  /' "$tmp/post.err"
    exit 2
  fi
  echo "RELEASED: $repo#$issue, branch $branch."
  exit 0
fi

# ---- claim and check: the other two reads ----
pr_jq='.[] | [(.number | tostring), .headRefName, .title, ((.body // "") | gsub("\\s+"; " "))] | @tsv'
gh pr list --repo "$repo" --state open --limit 1000 --json number,headRefName,title,body --jq "$pr_jq" \
  >"$tmp/prs" 2>"$tmp/prs.err" || fail_read "the open pull requests" "$tmp/prs.err"
gh api --paginate "repos/$repo/branches?per_page=100" --jq '.[].name' \
  >"$tmp/branches" 2>"$tmp/branches.err" || fail_read "the remote branches" "$tmp/branches.err"

state="$(sed -n 's/^STATE //p' "$tmp/issue")"
if [ "$state" != OPEN ]; then
  echo "CLOSED: $repo#$issue is $state. Do not start it."
  exit 1
fi

judge_claims

# Which issues a branch's name names is read by the one shared reader, mod-kit's issuesOfBranch
# through hooks/lib/branch-issues.mjs, never a pattern kept here (claude-config#1475): an agent
# worktree's random id and a branch on two issues are where hand written readings drifted.
{ cut -f 2 "$tmp/prs"; cat "$tmp/branches"; } >"$tmp/names"
if ! node --experimental-strip-types --no-warnings "$BRANCH_READER" <"$tmp/names" >"$tmp/named.json" 2>"$tmp/named.err" ||
  ! jq -r --argjson n "$issue" 'to_entries[] | select(any(.value[]; . == $n)) | .key' \
    "$tmp/named.json" >"$tmp/naming" 2>>"$tmp/named.err"; then
  fail_read "which issues the remote branches name" "$tmp/named.err"
fi
names_it() { grep -q -x -F -- "$1" "$tmp/naming"; }

ref_re="#${issue}([^0-9]|$)"
while IFS=$'\t' read -r n head title body; do
  [ -n "$n" ] || continue
  [ "$head" = "$branch" ] && continue
  if names_it "$head" || [[ "$title" =~ $ref_re ]] || [[ "$body" =~ $ref_re ]]; then
    blocking+=("pull request: #$n ($head) $title")
  fi
done <"$tmp/prs"
while IFS= read -r b; do
  [ -n "$b" ] || continue
  [ "$b" = "$branch" ] && continue
  names_it "$b" && blocking+=("remote branch: $b")
done <"$tmp/branches"

print_list() { local l; for l in "$@"; do echo "  $l"; done; }

if [ "${#blocking[@]}" -gt 0 ]; then
  echo "HELD: $repo#$issue is held by another session, so do not start it."
  print_list "${blocking[@]}"
  print_list "${stale[@]+"${stale[@]}"}"
  exit 1
fi

if [ "$first_holder" = ours ]; then
  echo "ALREADY CLAIMED: $repo#$issue already carries this Mac's claim on branch $branch. Nothing posted."
  print_list "${stale[@]+"${stale[@]}"}"
  exit 0
fi

if [ "$mode" = check ]; then
  echo "FREE: nothing holds $repo#$issue. Nothing posted."
  print_list "${stale[@]+"${stale[@]}"}"
  exit 0
fi

# ---- post the claim, then read it back ----
{
  echo "Claimed for building by an orchestrating session on $(mac_name "$host") at $(et_time "$now"), on branch \`$branch\`. Another session should not start on this issue while the claim stands. If the work is dropped or handed back unfinished, a release is posted here; a claim with no release stops counting after $STALE_HOURS hours."
  echo ""
  echo "<!-- orchestrate-claim branch=$branch host=$host -->"
} >"$tmp/claim"
# A post that errored (a timeout, a 5xx) may still have landed, and GitHub's read path can lag its
# write, so the issue is read back after a pause, up to READBACK_TRIES times, whatever the post said.
posted=yes
post "$tmp/claim" || posted=no
attempt=0
first_holder=""
while [ "$attempt" -lt "$READBACK_TRIES" ]; do
  attempt=$((attempt + 1))
  sleep "$READBACK_WAIT"
  if read_issue; then
    judge_claims
  else
    first_holder=""
  fi
  [ -n "$first_holder" ] && break
done
release_cmd="claim-issue.sh release $repo $issue $branch \"<reason>\""
case "$first_holder" in
  ours)
    echo "CLAIMED: $repo#$issue for branch $branch, from $(mac_name "$host") at $(et_time "$now"). Start the builder."
    print_list "${stale[@]+"${stale[@]}"}"
    exit 0 ;;
  other)
    release_body "another session claimed it first" "$tmp/release"
    post "$tmp/release" || echo "  (the release of this session's claim could not be posted either; post it with the release command)"
    echo "HELD: another session claimed $repo#$issue a moment before this one, so this claim was released. Do not start it."
    print_list "${blocking[@]}"
    exit 1 ;;
  *)
    if [ "$posted" = no ]; then
      echo "COULD NOT CHECK: posting the claim on $repo#$issue failed, and no claim of this session's could be read back. Do not start it. A claim may still have landed: run $release_cmd so it does not block the next session."
      sed 's/^/  /' "$tmp/post.err"
    else
      echo "COULD NOT CHECK: the claim was posted on $repo#$issue but could not be seen on reading it back $READBACK_TRIES times. Do not start it, and run $release_cmd so it does not block the next session."
      [ -s "$tmp/issue.err" ] && sed 's/^/  /' "$tmp/issue.err"
    fi
    exit 2 ;;
esac
