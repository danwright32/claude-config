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
# script, so before it merges this hands the EXACT merge command it is about to run to the same
# gates, block-red-merge.sh, pr-review-gate.sh and require-changelog-tag.sh, as a hook payload, and
# merges only when every one allows it. Green, up to date, pinned, reviewed and carrying its
# changelog record are therefore judged by the one implementation of each rule, never by a second
# copy here (L263, L370).
#
# EVERY merge gate, not a chosen few (claude-config#1178). This asked only the first two, so the
# changelog record gate never saw a merge made here. Slate #3645 merged through it with no
# changelog/* label (its run is quoted in #1087), one of nine unlabelled Slate merges between
# 2026-10-07 and 2026-10-12, all after this helper shipped, lost from the manager update until
# somebody read them by hand. test-merge-when-ready.sh checks the gates named here against every
# PreToolUse Bash hook in the hooks block that recognises a merge, so a gate added there and not
# here fails the suite. The changelog gate is also asked once BEFORE the wait: a record does not
# depend on the head or its checks, so a missing one is known at once, and finding it after a CI
# run and a lessons review costs both (L667). It is asked again at the merge, because a label can
# be taken off while this waits. What this file decides is only WHEN to ask: it waits
# while the head's checks are unfinished, while a workflow run GitHub has created for the head has not
# finished (its checks may not have registered yet, claude-config#1087), or while its review is still
# running (pr-review.sh check exit 3),
# and it updates the branch while the head is behind. A wrong "wait" costs time and ends at the
# deadline; a wrong "ready" is refused by the gates. Neither can merge anything they would refuse.
#
# THE MERGE IS PINNED to the head the gates judged (--match-head-commit), so a push landing between
# the judgement and the merge is refused by GitHub, and this goes round again for the new head.
#
# WHEN THE BASE KEEPS MOVING it waits for it to be still, and keeps going (claude-config#1271). This
# used to update at most three times and then stop with nothing merged. On 2026-10-16, with several
# pull requests merging at once and each head's checks taking 15 to 30 minutes, main moved faster
# than that: #1267 stopped twice and #1257 once, and each time a person waited for main to go quiet
# and started it again by hand. Now a pull request behind its base is updated at once the first
# time, and after that only once the base's tip (read from the same compare that measures how far
# behind it is, so it costs no call) has been unchanged for MWR_SETTLE_SECONDS, so a burst of merges
# costs one fresh check run, not one per merge. There is no count of updates: the deadline, three
# hours by default, and the poll count bound the run, and is-it-live's window for a background merge
# (WAIT_MS) is held at twice that deadline by test-merge-when-ready.sh (L227). Waiting changes only
# WHEN an update is made; what merges is still exactly the head every gate judged, as above. A queue
# across sessions, so only one helper per repository updates at a time, was the other remedy the
# issue named and is not built: it would serialise only this Mac's helpers, not the other MacBook's
# or a typed merge, and would need a holder that dies to be noticed (L409).
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
#      closed, or a read GitHub refused or still did not answer after being asked again
#   3  still waiting (on checks, the review, or a base still moving) when the deadline or the poll
#      count ran out; running it again resumes
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
# Environment (each also a test seam): MWR_POLL_SECONDS (60), MWR_DEADLINE_SECONDS (10800),
# MWR_MAX_POLLS (derived from the two, bounding the loop by count as well as by clock, L704),
# MWR_SETTLE_SECONDS (300: how long the base must have been still before a pull request it moved
# past is updated again; a setting, not a measurement), MWR_NOW (a command printing the time in
# epoch seconds, the clock's seam), MWR_NO_CHECKS_GRACE_SECONDS (180: how long a fresh head with no checks
# reported yet is waited on before the checks gate is asked whether the repository runs any),
# MWR_HEARTBEAT_SECONDS (300), MWR_READ_TRIES (4: how many times a GitHub read that did not answer
# is asked in all) and MWR_READ_RETRY_SECONDS (20: the wait between, so about a minute, see
# with_retries), MWR_SLEEP (sleep), MWR_RED_GATE, MWR_REVIEW_GATE, MWR_CHANGELOG_GATE, MWR_REVIEW_LIB.

set -uo pipefail

# Its own folder by parameter expansion, never dirname, which under a PATH without it gave the
# caller's folder (claude-config#1104, test-lib-self-locate.sh).
MWR_LIB="${BASH_SOURCE[0]%/*}"; [ "$MWR_LIB" != "${BASH_SOURCE[0]}" ] || MWR_LIB=.
MWR_LIB="$(cd "${MWR_LIB:-/}" && pwd)"
MWR_HOOKS="$(cd "$MWR_LIB/.." && pwd)"
RED_GATE="${MWR_RED_GATE:-$MWR_HOOKS/block-red-merge.sh}"
REVIEW_GATE="${MWR_REVIEW_GATE:-$MWR_HOOKS/pr-review-gate.sh}"
CHANGELOG_GATE="${MWR_CHANGELOG_GATE:-$MWR_HOOKS/require-changelog-tag.sh}"
REVIEW_LIB="${MWR_REVIEW_LIB:-$MWR_LIB/pr-review.sh}"
SLEEP="${MWR_SLEEP:-sleep}"
num_or(){ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
POLL="$(num_or "${MWR_POLL_SECONDS:-}" 60)"; [ "$POLL" -ge 1 ] || POLL=1
DEADLINE="$(num_or "${MWR_DEADLINE_SECONDS:-}" 10800)"
MAX_POLLS="$(num_or "${MWR_MAX_POLLS:-}" $((DEADLINE / POLL + 10)))"
SETTLE="$(num_or "${MWR_SETTLE_SECONDS:-}" 300)"
NOW_CMD="${MWR_NOW:-}"
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

# The clock is a seam like the sleep (L524): MWR_NOW names a command printing epoch seconds. One that
# prints anything else is not believed, and the real clock is read instead.
now(){
  local t=""
  [ -n "$NOW_CMD" ] && t="$("$NOW_CMD" 2>/dev/null)"
  case "$t" in ''|*[!0-9]*) date +%s ;; *) printf '%s' "$t" ;; esac
}
t0="$(now)"
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

# THE READS ARE ASKED AGAIN when GitHub did not answer (claude-config#1061). On 2026-10-09 two
# queued merges each waited 7 to 16 minutes for CI, then stopped on one "TLS handshake timeout" or
# "connection reset by peer" reading the compare, and the wait was thrown away. So each read below
# is a reader that sets its globals and returns 0 (answered), 1 (GitHub answered no, or failed in a
# way nobody recognised) or 2 (the transport or GitHub's server failed, mt_gh_transient), and
# with_retries asks again only on 2, READ_TRIES times in all with READ_WAIT between, through the
# same injected sleep (L524). A read still failing after that stops exactly as before, naming the
# last error: nothing merges on an unconfirmed read. A write (update-branch, the merge) is never
# asked again here: its failure can be a refusal, and it is judged by reading the state it left.
READ_TRIES="$(num_or "${MWR_READ_TRIES:-}" 4)"; [ "$READ_TRIES" -ge 1 ] || READ_TRIES=1
READ_WAIT="$(num_or "${MWR_READ_RETRY_SECONDS:-}" 20)"
read_err=""
reading=""
announce_retry(){ say "GitHub did not answer reading $reading (try $1 of $READ_TRIES: ${read_err:0:200}); asking again in ${READ_WAIT}s."; }
# The loop itself is mt_retry_read, shared with block-red-merge.sh's own reads (claude-config#1081).
with_retries(){   # $1 = what is being read, for the line it says; $2 = the reader
  reading="$1"
  mt_retry_read "$READ_TRIES" "$READ_WAIT" "$SLEEP" "" announce_retry "$2"
}
tried(){ [ "$1" -eq 2 ] && [ "$READ_TRIES" -gt 1 ] && printf ', still failing after %s tries over %ss' "$READ_TRIES" "$(( (READ_TRIES - 1) * READ_WAIT ))"; }
read_pr(){   # sets view_env
  local rc
  view_env="$(mt_pr_view "$pr" "number,state,headRefOid,headRefName,baseRefName,statusCheckRollup,mergeStateStatus,url" "$slug" "$slug")"
  mt_view_class "$view_env"; rc=$?
  read_err="$MT_VIEW_ERR"
  [ "$rc" -eq 1 ] && read_err="${read_err:-no answer}"
  return "$rc"
}
# The workflow runs GitHub has created for the head and not finished (claude-config#1087): sets
# runs_pending. Asked as the account that could see the pull request.
read_runs(){
  local rc
  mt_unfinished_runs "$slug" "$head" "$account"; rc=$?
  runs_pending="$MT_RUNS_PENDING"; read_err="$MT_RUNS_ERR"
  return "$rc"
}
read_compare(){   # sets compare, crc, behind, base_tip
  compare="$(gh_as api "repos/$slug/compare/$base...$head?per_page=1" 2>&1)"; crc=$?
  behind="$(printf '%s' "$compare" | jq -r '.behind_by // ""' 2>/dev/null)"
  # base_commit is the base branch's tip (measured against git ls-remote, 2026-10-16), read here so
  # knowing whether main has moved costs no call of its own.
  base_tip="$(printf '%s' "$compare" | jq -r '.base_commit.sha // ""' 2>/dev/null)"
  case "$behind" in ''|*[!0-9]*) ;; *) return 0 ;; esac
  read_err="${compare:0:300}, exit $crc"
  [ "$crc" -ne 0 ] && mt_gh_transient "$compare" && return 2
  return 1
}
read_back(){   # sets after
  local env
  env="$(mt_pr_view "$pr" "state,headRefOid" "$slug" "$slug")"
  after="$(printf '%s' "$env" | jq -c '.view // {}' 2>/dev/null)"
  [ "$(printf '%s' "$env" | jq -r '.found // false' 2>/dev/null)" = "true" ] && return 0
  read_err="$(printf '%s' "$env" | jq -r '.error // ""' 2>/dev/null)"
  mt_gh_transient "$read_err" && return 2
  return 1
}

record_asked=""; polls=0; updates=0; head_seen=""; head_since=0; started_for=""; last_status=""; last_said=0
tip_seen=""; tip_moved_at=""
# Out of time while waiting on something: the same stop wherever the wait is.
out_of_time(){   # $1 = what it was still waiting for
  if [ "$polls" -ge "$MAX_POLLS" ] || [ $(( $(now) - t0 )) -ge "$DEADLINE" ]; then
    stop 3 "Out of time: #$pr at ${head:0:7} $1 after $polls look(s). Nothing was merged; run the same command again to resume."
  fi
}
wait_a_look(){   # $1 = the status line; said when it changes, and every HEARTBEAT seconds while it does not
  if [ "$1" != "$last_status" ] || [ $(( $(now) - last_said )) -ge "$HEARTBEAT" ]; then
    say "$1"; last_status="$1"; last_said="$(now)"
  fi
  "$SLEEP" "$POLL"
}
mins(){ if [ "$1" -ge 60 ] && [ $(( $1 % 60 )) -eq 0 ]; then printf '%dm' "$(( $1 / 60 ))"; else printf '%ds' "$1"; fi; }
while :; do
  polls=$((polls + 1))
  [ "$polls" -le "$MAX_POLLS" ] || stop 3 "Out of time: $((polls - 1)) look(s) at #$pr without reaching a merge (MWR_MAX_POLLS). Nothing was merged; run the same command again to resume."
  with_retries "pull request #$pr" read_pr; rrc=$?
  if [ "$rrc" -ne 0 ]; then
    stop 1 "Stopped: could not read pull request #$pr in $slug from GitHub ($read_err$(tried "$rrc")). Nothing was merged."
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

  # The changelog record, once, at the first look that finds the pull request open: before any
  # update, wait or lessons review, since none of them can change it (#1178, L667).
  if [ -z "$record_asked" ]; then
    record_asked=1
    if ! why="$(ask_gate "$CHANGELOG_GATE" "$(merge_text "$head")")"; then
      stop 1 "Stopped: require-changelog-tag.sh refused the merge of #$pr before any wait: $why Nothing was merged; run this again once that is dealt with."
    fi
  fi

  # Behind its base: update, and go round for the new head.
  with_retries "whether #$pr contains the tip of $base" read_compare; rrc=$?
  [ "$rrc" -eq 0 ] || stop 1 "Stopped: could not read whether #$pr contains the tip of $base ($read_err$(tried "$rrc")). Nothing was merged."
  # When the base's tip was last SEEN to change (claude-config#1271). The first look has nothing to
  # compare with, so a pull request already behind is updated at once; the time is the look that
  # saw the change, never GitHub's commit date, so a clock between them cannot shorten the wait. A
  # compare that names no tip leaves this unset, and the helper then updates at once each time, as
  # it did before: more check runs spent, never a merge any gate would refuse.
  if [ -n "$base_tip" ]; then
    [ -n "$tip_seen" ] && [ "$base_tip" != "$tip_seen" ] && tip_moved_at="$(now)"
    tip_seen="$base_tip"
  fi
  if [ "$behind" -gt 0 ] || [ "$(printf '%s' "$view" | jq -r '.mergeStateStatus // ""')" = "BEHIND" ]; then
    # MAIN STILL MOVING: wait for it to be still before updating. Each update starts a fresh check
    # run of 15 to 30 minutes (as they ran on 2026-10-16), and a base still taking merges would leave the new head behind again
    # before it finished, so a burst of merges is answered with one update after it, not one each.
    if [ -n "$tip_moved_at" ] && [ $(( $(now) - tip_moved_at )) -lt "$SETTLE" ]; then
      out_of_time "is behind $base, with $base still moving"
      wait_a_look "Head ${head:0:7}: behind $base, with $base still moving; updating once it has been still for $(mins "$SETTLE")."
      continue
    fi
    upd="$(gh_as pr update-branch "$pr" --repo "$slug" 2>&1)" || stop 1 "Stopped: GitHub refused to update #$pr with $base: ${upd:0:500}. Nothing was merged; resolve it by hand."
    updates=$((updates + 1))
    noun="commits"; [ "$behind" -eq 1 ] && noun="commit"
    say "Head ${head:0:7} was $behind $noun behind $base, so it was updated (update $updates). Waiting for the new head's checks and lessons review."
    "$SLEEP" "$POLL"; continue
  fi

  # The review of THIS head runs alongside its checks: started the first time the head is seen. A
  # server side update fires no local push hook, so nothing else would start it.
  rev_args=(--dir "$top" --sha "$head" --base-ref "origin/$base")
  [ -n "$branch" ] && rev_args+=(--branch "$branch")
  # The pull request whose description and comments every review reads when it starts, where the
  # answers to earlier findings are written (claude-config#1161).
  rev_args+=(--pr "$pr")
  if [ "$started_for" != "$head" ]; then
    started_for="$head"
    bash "$REVIEW_LIB" start "${rev_args[@]}" >/dev/null 2>&1 || true
  fi

  waiting=""
  checks_total="$(printf '%s' "$view" | jq '[.statusCheckRollup[]?] | length')"
  checks_open="$(printf '%s' "$view" | jq '[.statusCheckRollup[]? | ((.conclusion // .state // "") | ascii_upcase) | select(IN("", "PENDING", "EXPECTED"))] | length')"
  if [ "$checks_open" -gt 0 ]; then
    waiting="checks still running ($checks_open of $checks_total)"
  else
    # NOTHING OPEN IS NOT EVERYTHING DONE (claude-config#1087). The rollup lists only the checks that
    # have registered, and a workflow run can exist for minutes before its jobs do (a concurrency
    # group, a queue): Slate #3645 was merged on one fast green check from another workflow while
    # its CI run sat pending. So before the checks read as finished, the runs GitHub has created for
    # this head are read too, and any that has not finished is waited on, by whatever name its
    # checks will carry. Read only here, where the head would otherwise read as finished, so it costs
    # one REST call a look at the end of a wait, never during it.
    with_retries "which workflow runs #$pr's head ${head:0:7} has" read_runs; rrc=$?
    [ "$rrc" -eq 0 ] || stop 1 "Stopped: could not read which workflow runs GitHub has for #$pr's head ${head:0:7} ($read_err$(tried "$rrc")), so nothing here can tell whether CI is still to report on it. Nothing was merged."
    if [ -n "$runs_pending" ]; then
      waiting="checks still running (workflow runs not finished: $runs_pending)"
    elif [ "$checks_total" -eq 0 ] && [ $(( $(now) - head_since )) -lt "$GRACE" ]; then
      waiting="checks still running (none reported yet)"
    fi
  fi
  rev_out="$(PR_REVIEW_READ="$read_key" bash "$REVIEW_LIB" check "${rev_args[@]}" 2>&1)"; rev_rc=$?
  case "$rev_rc" in
    0) ;;
    3) waiting="${waiting:+$waiting, }lessons review still running" ;;
    *) printf '%s\n' "$rev_out"
       stop 1 "Stopped: the lessons review of #$pr at ${head:0:7} refused (above). If it has findings, read them, fix what is real or say why not, then run: PR_REVIEW_READ=<key> $SELF $pr --repo $slug${flags[*]:+ ${flags[*]}} . Nothing was merged." ;;
  esac

  if [ -n "$waiting" ]; then
    out_of_time "still has $waiting"
    wait_a_look "Head ${head:0:7}: waiting, $waiting."
    continue
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
  if ! why="$(ask_gate "$CHANGELOG_GATE" "$cmd")"; then
    stop 1 "Stopped: require-changelog-tag.sh refused the merge of #$pr at ${head:0:7}: $why"
  fi
  say "Head ${head:0:7} is green, up to date with $base and reviewed, and every merge gate allows it. Merging, pinned to that head."
  merge_out="$(gh_as "${merge_argv[@]}" --match-head-commit "$head" 2>&1)"; merge_rc=$?
  # Judged by the state it leaves, never by what gh printed: --delete-branch from a worktree can fail
  # after the merge has landed.
  with_retries "#$pr back after the merge" read_back; rrc=$?
  if [ "$rrc" -ne 0 ]; then
    # Unreadable is not "the head moved": say what is known and look again, where the read at the
    # top of the loop either finds it merged or stops naming GitHub's error.
    say "Could not read #$pr back after the merge command (gh exited $merge_rc: ${merge_out:0:200}; read: ${read_err:-no answer}$(tried "$rrc")); looking again."
    continue
  fi
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
