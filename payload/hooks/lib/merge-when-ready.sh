#!/usr/bin/env bash
#
# merge-when-ready.sh: update a pull request that is behind its base, wait for the new head's checks
# and lessons review, and merge exactly that head the moment both are green (claude-config#851).
#
#   bash ~/.claude/hooks/lib/merge-when-ready.sh <pr> [--repo owner/name] [--squash|--merge|--rebase] [--delete-branch]
#
# Run it from a checkout of the repository (the lessons review reads the branch from there), in the
# background: a round of checks and review takes minutes, longer than one Bash call may run.
#
# WHY. block-red-merge.sh refuses a green pull request whose head does not contain its base's tip
# (#766, L85), and that rule is right. But with several sessions merging into one repository it
# turned into a loop: on 2026-10-06 Slate #3368 was sent back three times in about forty minutes, each
# round a twelve minute CI run plus a fresh lessons review, with a session babysitting every one.
# This does the babysitting. It does NOT relax the rule.
#
# NOTHING HERE DECIDES A MERGE. The gates a typed merge meets cannot see a merge made inside a
# script, so before it merges this hands the EXACT merge command it is about to run to the same two
# gates, block-red-merge.sh and pr-review-gate.sh, as a hook payload, and merges only when both allow
# it. Green, up to date, pinned and reviewed are therefore judged by the one implementation of each
# rule, never by a second copy here (L263, L370). What this file decides is only WHEN to ask: it waits
# while the head's checks are unfinished or its review is still running (pr-review.sh check exit 3),
# and it updates the branch while the head is behind. A wrong "wait" costs time and ends at the
# deadline; a wrong "ready" is refused by the gates. Neither can merge anything they would refuse.
#
# THE MERGE IS PINNED to the head the gates judged (--match-head-commit), so a push landing between
# the judgement and the merge is refused by GitHub, and this goes round again for the new head.
#
# WHAT IT REFUSES TO CARRY. Only the merge method and --delete-branch are passed to gh. Anything
# else is refused before any call: --admin and --auto would bypass or defer the very checks this
# waits for, a pin of your own could disagree with the head judged, and free text (a subject or a
# body) could carry an override token the gates read from the command (ALLOW_RED_MERGE=1 and the
# like), which would widen this into a bypass (L448). There is no override here: a merge that needs
# one is typed, visibly.
#
# STOPS, each in its own words and none of them a merge:
#   0  merged (or found already merged), confirmed by reading the pull request back
#   1  needs a person: a gate refused, the review has findings to read (they are printed, with how to
#      come back carrying their key), GitHub refused the update (a conflict), the pull request is
#      closed or unreadable, or main moved more times than MWR_MAX_UPDATES allows
#   3  still waiting when the deadline or the poll count ran out; running it again resumes
#   64 refused its arguments, or was run outside a checkout
#
# Findings to read: the review's own refusal carries a read key. Read them, fix what is real, then
#   PR_REVIEW_READ=<key> bash ~/.claude/hooks/lib/merge-when-ready.sh <pr> ...
# and the key reaches both the review checker and the merge command the review gate judges.
#
# HOW OFTEN IT LOOKS. Each look reads the pull request through GitHub's GraphQL allowance, 5,000
# points an hour that every session on the Mac shares, so it looks once a minute: about 60 points an
# hour while it waits, where every 30 seconds was 120 (claude-config#1014, measured 2026-10-09: one
# waiter was a third of this Mac's GraphQL spend at that moment). A check run takes minutes, so a
# merge lands at most a minute after it could have.
#
# Environment (each also a test seam): MWR_POLL_SECONDS (60), MWR_DEADLINE_SECONDS (3600),
# MWR_MAX_POLLS (derived from the two, bounding the loop by count as well as by clock, L704),
# MWR_MAX_UPDATES (3), MWR_NO_CHECKS_GRACE_SECONDS (180: how long a fresh head with no checks
# reported yet is waited on before the checks gate is asked whether the repository runs any),
# MWR_HEARTBEAT_SECONDS (300), MWR_SLEEP (sleep), MWR_RED_GATE, MWR_REVIEW_GATE, MWR_REVIEW_LIB.

set -uo pipefail

MWR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MWR_HOOKS="$(cd "$MWR_LIB/.." && pwd)"
RED_GATE="${MWR_RED_GATE:-$MWR_HOOKS/block-red-merge.sh}"
REVIEW_GATE="${MWR_REVIEW_GATE:-$MWR_HOOKS/pr-review-gate.sh}"
REVIEW_LIB="${MWR_REVIEW_LIB:-$MWR_LIB/pr-review.sh}"
SLEEP="${MWR_SLEEP:-sleep}"
num_or(){ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
POLL="$(num_or "${MWR_POLL_SECONDS:-}" 60)"; [ "$POLL" -ge 1 ] || POLL=1
DEADLINE="$(num_or "${MWR_DEADLINE_SECONDS:-}" 3600)"
MAX_POLLS="$(num_or "${MWR_MAX_POLLS:-}" $((DEADLINE / POLL + 10)))"
MAX_UPDATES="$(num_or "${MWR_MAX_UPDATES:-}" 3)"
GRACE="$(num_or "${MWR_NO_CHECKS_GRACE_SECONDS:-}" 180)"
HEARTBEAT="$(num_or "${MWR_HEARTBEAT_SECONDS:-}" 300)"
SELF="bash ~/.claude/hooks/lib/merge-when-ready.sh"

usage(){
  [ -n "${1:-}" ] && printf 'merge-when-ready: %s\n' "$1" >&2
  echo "usage: $SELF <pr> [--repo owner/name] [--squash|--merge|--rebase] [--delete-branch]" >&2
  exit 64
}

pr=""; repo=""; flags=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|-R)
      [ $# -ge 2 ] || usage "--repo needs owner/name."
      repo="$2"; shift 2 ;;
    --repo=*) repo="${1#--repo=}"; shift ;;
    --squash|-s|--merge|-m|--rebase|-r|--delete-branch|-d) flags+=("$1"); shift ;;
    [0-9]*)
      case "$1" in *[!0-9]*) usage "$1 is not a pull request number." ;; esac
      [ -z "$pr" ] || usage "more than one pull request number was given."
      pr="$1"; shift ;;
    *) usage "$1 is not carried: only the merge method and --delete-branch are passed to gh pr merge, so nothing here can bypass, defer or override the gates it waits for." ;;
  esac
done
[ -n "$pr" ] || usage "name the pull request by number."
if [ -n "$repo" ] && ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  usage "--repo $repo is not owner/name."
fi
read_key="${PR_REVIEW_READ:-}"
case "$read_key" in *[!a-f0-9]*) usage "PR_REVIEW_READ is not a read key (a key is lowercase hex, copied from the review's refusal)." ;; esac

top="$(git rev-parse --show-toplevel 2>/dev/null)" || usage "run it from a checkout of the repository: the lessons review reads the branch from one."
cd "$top" || usage "could not enter $top."

# shellcheck source=merge-target.sh
. "$MWR_LIB/merge-target.sh" 2>/dev/null || { echo "merge-when-ready: $MWR_LIB/merge-target.sh is missing, so the pull request cannot be read. Nothing was merged." >&2; exit 1; }
for t in gh jq git; do
  command -v "$t" >/dev/null 2>&1 || { echo "merge-when-ready: $t is not on PATH. Nothing was merged." >&2; exit 1; }
done
slug="${repo:-$(mt_remote_slug)}"
[ -n "$slug" ] || usage "this checkout has no GitHub origin; name the repository with --repo owner/name."

t0="$(date +%s)"
now(){ date +%s; }
elapsed(){
  local s=$(( $(now) - t0 ))
  if [ "$s" -ge 60 ]; then printf '%dm %02ds' "$((s / 60))" "$((s % 60))"; else printf '%ds' "$s"; fi
}
say(){ printf 'merge-when-ready: [%s] %s\n' "$(elapsed)" "$*"; }
stop(){ say "$2"; exit "$1"; }

account=""
gh_as(){
  if [ -n "$account" ]; then
    local tok; tok="$(gh auth token -u "$account" 2>/dev/null)" || tok=""
    [ -n "$tok" ] && { GH_TOKEN="$tok" gh "$@"; return; }
  fi
  gh "$@"
}

# The exact command the gates judge and gh runs, as one line of text and as an argument list.
merge_argv=(pr merge "$pr" --repo "$slug")
[ ${#flags[@]} -gt 0 ] && merge_argv+=("${flags[@]}")
merge_text(){ printf 'gh'; printf ' %s' "${merge_argv[@]}" --match-head-commit "$1"; }

# Hand one gate a PreToolUse payload for the merge command; prints its reason when it refuses.
ask_gate(){   # $1 = gate script, $2 = command text
  local payload out rc reason
  payload="$(jq -nc --arg c "$2" --arg d "$top" '{session_id:"merge-when-ready",cwd:$d,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')"
  out="$(printf '%s' "$payload" | bash "$1" 2>&1)"; rc=$?
  reason="$(printf '%s' "$out" | jq -r 'select(.hookSpecificOutput.permissionDecision == "deny") | .hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
  if [ "$rc" -ne 0 ] || [ -n "$reason" ]; then
    printf '%s' "${reason:-$out}"
    return 1
  fi
  return 0
}

polls=0; updates=0; head_seen=""; head_since=0; started_for=""; last_status=""; last_said=0
while :; do
  polls=$((polls + 1))
  [ "$polls" -le "$MAX_POLLS" ] || stop 3 "Out of time: $((polls - 1)) look(s) at #$pr without reaching a merge (MWR_MAX_POLLS). Nothing was merged; run the same command again to resume."
  view_env="$(mt_pr_view "$pr" "number,state,headRefOid,headRefName,baseRefName,statusCheckRollup,mergeStateStatus,url" "$slug" "$slug")"
  if [ "$(printf '%s' "$view_env" | jq -r '.found // false' 2>/dev/null)" != "true" ]; then
    stop 1 "Stopped: could not read pull request #$pr in $slug from GitHub ($(printf '%s' "$view_env" | jq -r '.error // "no answer"' 2>/dev/null)). Nothing was merged."
  fi
  account="$(printf '%s' "$view_env" | jq -r '.account // ""')"
  view="$(printf '%s' "$view_env" | jq -c '.view')"
  state="$(printf '%s' "$view" | jq -r '.state // ""')"
  head="$(printf '%s' "$view" | jq -r '.headRefOid // ""')"
  base="$(printf '%s' "$view" | jq -r '.baseRefName // ""')"
  branch="$(printf '%s' "$view" | jq -r '.headRefName // ""')"
  case "$state" in
    MERGED) stop 0 "Pull request #$pr in $slug is already merged (head ${head:0:7}); nothing to do." ;;
    OPEN) ;;
    *) stop 1 "Stopped: pull request #$pr in $slug is ${state:-in an unknown state}, not open. Nothing was merged." ;;
  esac
  [ -n "$head" ] && [ -n "$base" ] || stop 1 "Stopped: GitHub did not report the head commit or base branch of #$pr. Nothing was merged."
  if [ "$head" != "$head_seen" ]; then head_seen="$head"; head_since="$(now)"; fi

  # Behind its base: update, and go round for the new head.
  compare="$(gh_as api "repos/$slug/compare/$base...$head?per_page=1" 2>&1)"; crc=$?
  behind="$(printf '%s' "$compare" | jq -r '.behind_by // ""' 2>/dev/null)"
  case "$behind" in ''|*[!0-9]*) stop 1 "Stopped: could not read whether #$pr contains the tip of $base (${compare:0:300}, exit $crc). Nothing was merged." ;; esac
  if [ "$behind" -gt 0 ] || [ "$(printf '%s' "$view" | jq -r '.mergeStateStatus // ""')" = "BEHIND" ]; then
    if [ "$updates" -ge "$MAX_UPDATES" ]; then
      stop 1 "Stopped: $base moved again; this run has updated it $updates time(s), its limit (MWR_MAX_UPDATES). Nothing was merged. Run it again when merges into $base have quietened."
    fi
    upd="$(gh_as pr update-branch "$pr" --repo "$slug" 2>&1)" || stop 1 "Stopped: GitHub refused to update #$pr with $base: ${upd:0:500}. Nothing was merged; resolve it by hand."
    updates=$((updates + 1))
    noun="commits"; [ "$behind" -eq 1 ] && noun="commit"
    say "Head ${head:0:7} was $behind $noun behind $base, so it was updated (update $updates of at most $MAX_UPDATES). Waiting for the new head's checks and lessons review."
    "$SLEEP" "$POLL"; continue
  fi

  # The review of THIS head runs alongside its checks: started the first time the head is seen. A
  # server side update fires no local push hook, so nothing else would start it.
  rev_args=(--dir "$top" --sha "$head" --base-ref "origin/$base")
  [ -n "$branch" ] && rev_args+=(--branch "$branch")
  if [ "$started_for" != "$head" ]; then
    started_for="$head"
    bash "$REVIEW_LIB" start "${rev_args[@]}" >/dev/null 2>&1 || true
  fi

  waiting=""
  checks_total="$(printf '%s' "$view" | jq '[.statusCheckRollup[]?] | length')"
  checks_open="$(printf '%s' "$view" | jq '[.statusCheckRollup[]? | ((.conclusion // .state // "") | ascii_upcase) | select(IN("", "PENDING", "EXPECTED"))] | length')"
  if [ "$checks_open" -gt 0 ]; then
    waiting="checks still running ($checks_open of $checks_total)"
  elif [ "$checks_total" -eq 0 ] && [ $(( $(now) - head_since )) -lt "$GRACE" ]; then
    waiting="checks still running (none reported yet)"
  fi
  rev_out="$(PR_REVIEW_READ="$read_key" bash "$REVIEW_LIB" check "${rev_args[@]}" 2>&1)"; rev_rc=$?
  case "$rev_rc" in
    0) ;;
    3) waiting="${waiting:+$waiting, }lessons review still running" ;;
    *) printf '%s\n' "$rev_out"
       stop 1 "Stopped: the lessons review of #$pr at ${head:0:7} refused (above). If it has findings, read them, fix what is real or say why not, then run: PR_REVIEW_READ=<key> $SELF $pr --repo $slug${flags[*]:+ ${flags[*]}} . Nothing was merged." ;;
  esac

  if [ -n "$waiting" ]; then
    if [ "$polls" -ge "$MAX_POLLS" ] || [ $(( $(now) - t0 )) -ge "$DEADLINE" ]; then
      stop 3 "Out of time: #$pr at ${head:0:7} still has $waiting after $polls look(s). Nothing was merged; run the same command again to resume."
    fi
    status="Head ${head:0:7}: waiting, $waiting."
    if [ "$status" != "$last_status" ] || [ $(( $(now) - last_said )) -ge "$HEARTBEAT" ]; then
      say "$status"; last_status="$status"; last_said="$(now)"
    fi
    "$SLEEP" "$POLL"; continue
  fi

  # Ready by every reading here. The gates decide.
  cmd="$(merge_text "$head")"
  if ! why="$(ask_gate "$RED_GATE" "$cmd")"; then
    stop 1 "Stopped: block-red-merge.sh refused the merge of #$pr at ${head:0:7}: $why"
  fi
  review_cmd="$cmd"; [ -n "$read_key" ] && review_cmd="PR_REVIEW_READ=$read_key $cmd"
  if ! why="$(ask_gate "$REVIEW_GATE" "$review_cmd")"; then
    stop 1 "Stopped: pr-review-gate.sh refused the merge of #$pr at ${head:0:7}: $why"
  fi
  say "Head ${head:0:7} is green, up to date with $base and reviewed; both gates allow it. Merging, pinned to that head."
  merge_out="$(gh_as "${merge_argv[@]}" --match-head-commit "$head" 2>&1)"; merge_rc=$?
  # Judged by the state it leaves, never by what gh printed: --delete-branch from a worktree can fail
  # after the merge has landed.
  after="$(mt_pr_view "$pr" "state,headRefOid" "$slug" "$slug" | jq -c '.view // {}' 2>/dev/null)"
  if [ "$(printf '%s' "$after" | jq -r '.state // ""')" = "MERGED" ]; then
    note=""; [ "$merge_rc" -ne 0 ] && note=" (gh exited $merge_rc after merging: ${merge_out:0:200})"
    stop 0 "Merged #$pr in $slug at ${head:0:7}$note."
  fi
  if [ "$(printf '%s' "$after" | jq -r '.headRefOid // ""')" != "$head" ]; then
    say "The head moved while it was being merged (GitHub refused the pin on ${head:0:7}); judging the new head."
    continue
  fi
  stop 1 "Stopped: gh pr merge did not merge #$pr at ${head:0:7}: ${merge_out:0:500}"
done
