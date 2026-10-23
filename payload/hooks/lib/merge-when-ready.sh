#!/usr/bin/env bash
#
# merge-when-ready.sh: update a pull request that is behind its base, wait for the new head's checks
# and lessons review, and merge exactly that head the moment both are green (claude-config#851).
#
#   bash ~/.claude/hooks/lib/merge-when-ready.sh <pr> [--repo owner/name] [--squash|--merge|--rebase] [--delete-branch]
#
# With no merge method, the repository's settings choose one when they allow only one, and it stops
# at once, naming them, when they allow more (claude-config#1476, see choose_method).
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
# gates, block-red-merge.sh, pr-review-gate.sh, require-changelog-tag.sh and design-score-gate.sh,
# as a hook payload, and merges only when every one allows it. Green, up to date, pinned, reviewed,
# carrying its changelog record and, when it closes a Match the settled design issue, at 100% of its
# design match score (#1364) are therefore judged by the one implementation of each rule, never by a
# second copy here (L263, L370).
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
# AND THAT HEAD IS THE BRANCH'S TIP (claude-config#1458). The pull request's head is GitHub's record,
# and it can lag the branch: on 2026-10-21 Bidspoke #2577 showed 30ff7b1 for over ten minutes after
# its branch was pushed to d854a1a (git ls-remote and the branches API both showed d854a1a), so this
# merged pinned to the old head and GitHub refused it twice with "Head branch is out of date". So the
# branch's tip is read (from the fork, for a fork's pull request) the first time a head is seen,
# before any update or lessons review is spent on it, and again just before the gates are asked.
# When they differ, this waits MWR_HEAD_LAG_SECONDS for GitHub to catch up, then sets the pull
# request's base again to the base it already has, the no op write that made GitHub read the branch
# at once that day, and waits as long again for the real head, whose checks and review are then
# waited on as any new head's are. Still lagging after that, it stops in its own words; the base is
# set again once per lag, never in a loop. A branch GitHub says is not there, or will not show, stops
# it too: with no tip to confirm, nothing is merged. The same lag can follow an update this makes,
# and then GitHub shows the head it updated as if nothing happened (claude-config#1500), so after an
# update the next look confirms the head against the branch again, and an update GitHub has not shown
# is said and waited on, never answered with another update.
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
# WHEN an update is made; what merges is still exactly the head every gate judged, as above.
#
# ONE HELPER PER REPOSITORY AT A TIME, IN TURN (claude-config#1515). Settling answers a base that
# moves; it did not stop the helpers themselves moving it. On 2026-10-22 PET #1885 sat here about 112
# minutes: its checks take about 23, and four other pull requests from parallel agents merged under
# it, each putting it behind main and restarting them, until the main session told the other agents
# to hold. So a run now takes the repository's turn (lib/merge-turn.sh, a queue under this Mac's own
# state) at its first look, once the checks that need no wait have passed, and holds it through the
# update, the checks, the review and the merge, giving it up once the merge lands or at any stop.
# Another run waits for it, and says so as its own state, naming the holder and how long it has held
# it, never as a wait on checks. A holder whose run has gone is passed over at once; one that has held
# the turn for MWR_TURN_HOLD_SECONDS is passed over by a run waiting for it, and joins the line again,
# so a stuck pull request cannot starve the rest either. The turn is asked again just before the
# gates, so a run that lost it never merges under the one that has it. It orders only this Mac's
# helpers: the other MacBook's, a typed merge and GitHub's merge queue never see it, and settling
# still answers those. It decides the order of merges, never whether one is right, so a run that
# cannot take a turn says so and goes on as before, and every gate judges every merge.
#
# WHAT IT REFUSES TO CARRY. Only the merge method is passed to gh, and --delete-branch is carried
# out here once the merge has landed: the open pull requests based on the branch are moved onto the
# merged one's base first, so deleting it closes none of them (claude-config#1337). Anything
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
#      closed, its head is still not its branch's tip after the base was set again (or the branch
#      is gone), an update GitHub has still not shown four minutes after it, or a read GitHub
#      refused or still did not answer after being asked again
#   3  still waiting (on checks, the review, a base still moving, or the repository's turn) when the
#      deadline or the poll count ran out; running it again resumes, at the back of the line
#   4  merged, but with --delete-branch the branch was left in place, saying why: a pull request
#      based on it could not be moved, GitHub could not be read, or the branch holds commits the
#      merge did not; running it again finishes the branch
#   64 refused its arguments, was run outside a checkout, or was passed no merge method for a
#      repository that allows more than one (or does not say which)
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
# MWR_HEARTBEAT_SECONDS (120: how often a wait that has not changed is said again, with how long it
# has lasted, see wait_a_look), MWR_HEAD_LAG_SECONDS (120: how long GitHub's head for the pull request
# may lag its branch's tip before the base is set again to resync it, and how long after that before
# it stops; a setting, see head_is_tip), MWR_READ_TRIES (4: how many times a GitHub read that did not answer
# is asked in all) and MWR_READ_RETRY_SECONDS (20: the wait between, so about a minute, see
# with_retries), MWR_TURN_DIR (~/.claude/state/merge-turns: where the repositories' turns are kept)
# and MWR_TURN_HOLD_SECONDS (3600: how long one pull request may hold the turn while another waits
# for it, room for a check run of 15 to 30 minutes, a review and one update; a setting, not a
# measurement), MWR_SLEEP (sleep), MWR_RED_GATE, MWR_REVIEW_GATE, MWR_CHANGELOG_GATE, MWR_DESIGN_GATE,
# MWR_REVIEW_LIB, MWR_WORKTREE_CHECK (the check that judges the merged branch's agent worktree).
#
# AFTER A MERGE THAT LANDED it removes the merged branch's agent worktree when
# check-stale-worktrees.sh --just-merged allows it, and never the folder it was run from
# (claude-config#1521, see tidy_worktree). What it removed, or why it kept it, is said after the
# merge's own line, and nothing about it changes the exit.

set -uo pipefail

# Its own folder by parameter expansion, never dirname, which under a PATH without it gave the
# caller's folder (claude-config#1104, test-lib-self-locate.sh).
MWR_LIB="${BASH_SOURCE[0]%/*}"; [ "$MWR_LIB" != "${BASH_SOURCE[0]}" ] || MWR_LIB=.
MWR_LIB="$(cd "${MWR_LIB:-/}" && pwd)"
MWR_HOOKS="$(cd "$MWR_LIB/.." && pwd)"
RED_GATE="${MWR_RED_GATE:-$MWR_HOOKS/block-red-merge.sh}"
REVIEW_GATE="${MWR_REVIEW_GATE:-$MWR_HOOKS/pr-review-gate.sh}"
CHANGELOG_GATE="${MWR_CHANGELOG_GATE:-$MWR_HOOKS/require-changelog-tag.sh}"
DESIGN_GATE="${MWR_DESIGN_GATE:-$MWR_HOOKS/design-score-gate.sh}"
REVIEW_LIB="${MWR_REVIEW_LIB:-$MWR_LIB/pr-review.sh}"
SLEEP="${MWR_SLEEP:-sleep}"
num_or(){ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
POLL="$(num_or "${MWR_POLL_SECONDS:-}" 60)"; [ "$POLL" -ge 1 ] || POLL=1
DEADLINE="$(num_or "${MWR_DEADLINE_SECONDS:-}" 10800)"
MAX_POLLS="$(num_or "${MWR_MAX_POLLS:-}" $((DEADLINE / POLL + 10)))"
SETTLE="$(num_or "${MWR_SETTLE_SECONDS:-}" 300)"
NOW_CMD="${MWR_NOW:-}"
GRACE="$(num_or "${MWR_NO_CHECKS_GRACE_SECONDS:-}" 180)"
HEARTBEAT="$(num_or "${MWR_HEARTBEAT_SECONDS:-}" 120)"
LAG_WAIT="$(num_or "${MWR_HEAD_LAG_SECONDS:-}" 120)"
TURN_HOLD="$(num_or "${MWR_TURN_HOLD_SECONDS:-}" 3600)"
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
    *) usage "$1 is not carried: only the merge method is passed to gh pr merge, and --delete-branch is done here after the merge, so nothing here can bypass, defer or override the gates it waits for." ;;
  esac
done
[ -n "$pr" ] || usage "name the pull request by number."
if [ -n "$repo" ] && ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  usage "--repo $repo is not owner/name."
fi
read_key="${PR_REVIEW_READ:-}"
case "$read_key" in *[!a-f0-9]*) usage "PR_REVIEW_READ is not a read key (a key is lowercase hex, copied from the review's refusal)." ;; esac

top="$(git rev-parse --show-toplevel 2>/dev/null)" || usage "run it from a checkout of the repository: the lessons review reads the branch from one."
# Where the caller stands, read before this moves, so the merged branch's worktree is never removed
# from under the session that ran it (claude-config#1521, see tidy_worktree).
caller_dir="$(pwd -P)"
cd "$top" || usage "could not enter $top."

# shellcheck source=merge-target.sh
. "$MWR_LIB/merge-target.sh" 2>/dev/null || { echo "merge-when-ready: $MWR_LIB/merge-target.sh is missing, so the pull request cannot be read. Nothing was merged." >&2; exit 1; }
# shellcheck source=merge-turn.sh
. "$MWR_LIB/merge-turn.sh" 2>/dev/null || { echo "merge-when-ready: $MWR_LIB/merge-turn.sh is missing, so the repository's turn to merge cannot be taken. Nothing was merged." >&2; exit 1; }
# A place in the line is given up however this run ends: a stop, a signal, or the end of the
# script. Only a kill that cannot be caught leaves it, and the next run passes it over (see
# merge-turn.sh). The signals exit, so the EXIT trap runs for them too.
trap 'turn_leave' EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
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
dur(){ if [ "$1" -ge 60 ]; then printf '%dm %02ds' "$(($1 / 60))" "$(($1 % 60))"; else printf '%ds' "$1"; fi; }
elapsed(){ dur $(( $(now) - t0 )); }
say(){ printf 'merge-when-ready: [%s] %s\n' "$(elapsed)" "$*"; }
# Every stop after a merge that landed (finish_branch, and a pull request found already merged)
# tidies the merged branch's agent worktree once its own line is said. The tidy is never able to
# change the exit: a merge that landed is reported as landed whatever the tidy found.
merged_now=""
stop(){ say "$2"; [ -z "$merged_now" ] || { merged_now=""; tidy_worktree || true; }; exit "$1"; }

account=""
gh_as(){
  if [ -n "$account" ]; then
    local tok; tok="$(gh auth token -u "$account" 2>/dev/null)" || tok=""
    [ -n "$tok" ] && { GH_TOKEN="$tok" gh "$@"; return; }
  fi
  gh "$@"
}

# The exact command the gates judge and gh runs, as one line of text and as an argument list.
# --delete-branch is taken out of it and done here, after the merge (claude-config#1337, see
# finish_branch), so the gates judge the command that actually runs.
want_delete=""; method=""
merge_argv=(pr merge "$pr" --repo "$slug")
for f in ${flags[@]+"${flags[@]}"}; do
  case "$f" in --delete-branch|-d) want_delete=1 ;; *) merge_argv+=("$f"); method="$f" ;; esac
done
merge_text(){ printf 'gh'; printf ' %s' "${merge_argv[@]}" --match-head-commit "$1"; }

# Hand one gate a PreToolUse payload for the merge command; prints its reason when it refuses.
# MWR_DELETE_BRANCH tells block-red-merge.sh this run was asked for --delete-branch, which the merge
# command no longer carries, so the rerun command it suggests keeps it (claude-config#1351).
ask_gate(){   # $1 = gate script, $2 = command text
  local payload out rc reason
  payload="$(jq -nc --arg c "$2" --arg d "$top" '{session_id:"merge-when-ready",cwd:$d,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')"
  out="$(printf '%s' "$payload" | MWR_DELETE_BRANCH="$want_delete" bash "$1" 2>&1)"; rc=$?
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
  view_env="$(mt_pr_view "$pr" "number,state,headRefOid,headRefName,baseRefName,isCrossRepository,headRepositoryOwner,headRepository,statusCheckRollup,mergeStateStatus,url" "$slug" "$slug")"
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
  # 3: GitHub cannot find what it was asked to compare. Just after an update that is GitHub not
  # having caught up with the branch (claude-config#1500), which the caller waits through; at any
  # other time it stops as any refused read does.
  [ "$crc" -ne 0 ] && case "$compare" in *"HTTP 404"*) return 3 ;; esac
  return 1
}
# The merge methods the repository allows, when none was passed (claude-config#1476): sets allowed
# (the names, in gh's flag spelling, space separated) and methods_said (false when GitHub left the
# settings out, as it does for an account that cannot change them, so absent never reads as not
# allowed).
read_methods(){
  local out rc
  allowed=""; methods_said=""
  out="$(gh_as api "repos/$slug" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && methods_said="$(printf '%s' "$out" | jq -r '[has("allow_squash_merge"), has("allow_merge_commit"), has("allow_rebase_merge")] | all' 2>/dev/null)"; then
    allowed="$(printf '%s' "$out" | jq -r '[if .allow_squash_merge == true then "squash" else empty end, if .allow_merge_commit == true then "merge" else empty end, if .allow_rebase_merge == true then "rebase" else empty end] | join(" ")')"
    return 0
  fi
  methods_said=""
  read_err="${out:0:300}, exit $rc"
  [ "$rc" -ne 0 ] && mt_gh_transient "$out" && return 2
  return 1
}
# "squash", "squash and rebase", "squash, merge and rebase"
and_list(){
  local n=$# out="" i=0 w
  for w in "$@"; do
    i=$((i + 1))
    if [ "$i" -eq 1 ]; then out="$w"; elif [ "$i" -eq "$n" ]; then out="$out and $w"; else out="$out, $w"; fi
  done
  printf '%s' "$out"
}
# WHICH MERGE METHOD, when none was passed (claude-config#1476). gh pr merge refuses to choose one
# outside a terminal, so on 2026-10-21 about a dozen PET merges waited out their checks and review
# and then stopped at the merge itself. Now the repository's own settings decide, when they allow
# exactly one method. When they allow more, nothing here decides: this stops, before any update or
# wait, naming them. The issue also suggested squash when "the repository's history is squash only",
# and that is deliberately not built. GitHub records no merge method for a merged pull request, and a
# squash merge and a rebase of one commit leave the same single parent commit, so "squash only"
# could only be guessed from history, never read; and a guess picks how commits land on the base,
# which cannot be undone, for a repository whose settings say a person may choose otherwise (L93).
# Both repositories measured on 2026-10-22, PET and claude-config, allow all three, so for them the
# change is that the refusal comes at once, before the wait, instead of after it.
method_name(){ case "$1" in merge) printf 'merge commit' ;; *) printf '%s' "$1" ;; esac; }
choose_method(){
  local rrc am names=() others="" m
  with_retries "which merge methods $slug allows" read_methods; rrc=$?
  [ "$rrc" -eq 0 ] || stop 1 "Stopped: no merge method was passed, and could not read which merge methods $slug allows ($read_err$(tried "$rrc")). Nothing was merged; pass --squash, --merge or --rebase."
  [ "$methods_said" = "true" ] || stop 64 "Stopped: no merge method was passed, and GitHub did not say which merge methods $slug allows (it leaves them out for an account that cannot change the repository's settings). Nothing was merged; run it again naming one: $SELF $pr --repo $slug --squash${want_delete:+ --delete-branch} (or --merge, or --rebase)."
  read -r -a am <<<"$allowed"
  for m in ${am[@]+"${am[@]}"}; do names+=("$(method_name "$m")"); done
  case "${#am[@]}" in
    1) method="--${am[0]}"; merge_argv+=("$method")
       say "Merging by $(method_name "${am[0]}"), the only merge method $slug allows, since none was passed." ;;
    0) stop 64 "Stopped: no merge method was passed, and GitHub says $slug allows none. Nothing was merged." ;;
    *) for m in "${am[@]:1}"; do others="$others, or --$m"; done
       stop 64 "Stopped: no merge method was passed, and $slug allows $(and_list "${names[@]}") merges, so which one is a person's choice. Nothing was merged; run it again naming one: $SELF $pr --repo $slug --${am[0]}${want_delete:+ --delete-branch} (${others#, })." ;;
  esac
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

# THE BRANCH IS DELETED HERE, NEVER BY gh (claude-config#1337). On 2026-10-19 this merged
# Try-Pennie/bidspoke#2478 with --delete-branch passed through to gh pr merge, which deleted the
# branch the moment the merge landed. GitHub closed #2482, which was based on that branch (a branch
# deleted through the API does not move the pull requests based on it, as one deleted in the web
# page does), and a closed pull request's base can never be changed, so it was opened again as a
# new one, losing its review thread and a CI round. So gh merges without deleting anything, and only
# once the merge is read back MERGED does finish_branch move every open pull request based on the
# branch onto the merged one's base and then delete it. Nothing moves BEFORE the merge: a stacked
# pull request moved onto main while its parent is still open shows the parent's commits as its own,
# and the merge can still be refused. Every step is judged by the state it leaves, and any doubt
# leaves the branch where it is, which costs a stray branch, where deleting wrongly costs a closed
# pull request that cannot be reopened onto anything (L5). That is stop 4, and running the same
# command again finishes the job: the read at the top finds the merge done and comes back here,
# where only what is still based on the branch is moved. Only the branch on GitHub is deleted;
# gh's --delete-branch also deleted the local one and switched the checkout, which from a worktree
# failed after the merge had landed, and touched a checkout another session may be standing in.
# The repository it reads is ref_repo, set by the caller: this one for finish_branch, the fork for a
# fork's pull request in head_is_tip (a reader takes no arguments, see with_retries).
ref_repo=""
read_ref(){   # sets ref_tip, or ref_gone when the branch is not there
  local out rc
  ref_tip=""; ref_gone=""
  out="$(gh_as api "repos/${ref_repo:-$slug}/git/ref/heads/$branch" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    ref_tip="$(printf '%s' "$out" | jq -r '.object.sha // ""' 2>/dev/null)"
    [ -n "$ref_tip" ] && return 0
    read_err="${out:0:300}"; return 1
  fi
  # GitHub answers 404 for what the account cannot see as well as for what is not there, so a 404
  # reads as deleted only when the base branch, asked the same way, can be seen.
  case "$out" in *"HTTP 404"*)
    if gh_as api "repos/${ref_repo:-$slug}/git/ref/heads/$base" >/dev/null 2>&1; then ref_gone=1; return 0; fi
    read_err="GitHub answered 404 for $branch and could not show $base either, so a deleted branch cannot be told from one it will not show"
    return 1 ;;
  esac
  read_err="${out:0:300}, exit $rc"
  mt_gh_transient "$out" && return 2
  return 1
}
# The open pull requests based on the branch, one number a line in stacked. An answer that is not a
# list is a failed read, never an empty one: "could not list" must not read as "nothing stacked".
read_stacked(){
  local out rc
  stacked=""
  out="$(gh_as pr list --repo "$slug" --base "$branch" --state open --limit 1000 --json number 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && stacked="$(printf '%s' "$out" | jq -r 'if type == "array" then .[].number else error("not a list") end' 2>/dev/null)"; then
    return 0
  fi
  stacked=""
  read_err="${out:0:300}, exit $rc"
  [ "$rc" -ne 0 ] && mt_gh_transient "$out" && return 2
  return 1
}
# Moves one pull request onto the merged one's base. A write, so never asked again here; prints
# GitHub's answer when the base it reports is not the one asked for.
retarget(){   # $1 = pull request number
  local out rc
  out="$(gh_as api -X PATCH "repos/$slug/pulls/$1" -f "base=$base" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | jq -r '.base.ref // ""' 2>/dev/null)" = "$base" ] && return 0
  printf '%s, exit %s' "${out:0:300}" "$rc"
  return 1
}
# THE MERGED BRANCH'S AGENT WORKTREE GOES AT THE MERGE (claude-config#1521). On 2026-10-22 this
# repository held 66 agent worktrees, about 2.5 GB, 63 of them for merged pull requests: the sweep
# (check-stale-worktrees.sh, started by stale-worktree-nudge.sh) ran only at a session's first
# prompt, and one coordinator session dispatched over 60 builders in three days without another
# session starting. So once the merge has landed, the worktree under <repo>/.claude/worktrees/ whose
# branch is the one just merged is handed to check-stale-worktrees.sh --just-merged, which applies
# every one of its own rules to that one worktree (merged holding every commit, nothing uncommitted
# or untracked, no running process in it, no live agent's lock, the progress marker) except the six
# hour recency, which a worktree merged a moment ago can never pass. The rules are the check's,
# never a copy here (L370), and its branch is never deleted. What this adds is the one fact only the
# caller has: the folder it was run from. An agent merging from inside its own worktree keeps it,
# because removing it would take the floor from under the session still standing in it; the sweep
# takes it later. Nothing here can change the exit: the merge has landed, and a worktree that could
# not be judged or removed is said and left for the sweep.
WT_CHECK="${MWR_WORKTREE_CHECK:-$MWR_HOOKS/check-stale-worktrees.sh}"
tidy_worktree(){
  local all line cur="" main="" wt="" real out rc tok="" said_any=""
  [ -n "${branch:-}" ] || return 0
  all="$(git -C "$top" worktree list --porcelain 2>/dev/null)" || return 0
  # The first worktree git lists is the main checkout, whose .claude/worktrees holds the agents'.
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur="${line#worktree }"; [ -n "$main" ] || main="$cur" ;;
      "branch refs/heads/$branch") case "$cur" in "$main/.claude/worktrees/"*) wt="$cur" ;; esac ;;
    esac
  done <<<"$all"
  [ -n "$wt" ] || return 0
  real="$(cd "$wt" 2>/dev/null && pwd -P)" || real="$wt"
  case "$caller_dir/" in
    "$real/"*|"$wt/"*)
      say "Kept the agent worktree $wt: it is the folder this merge was run from, so removing it would take the floor from under the session that ran it. The stale worktree sweep removes it once nothing is working in it."
      return 0 ;;
  esac
  if [ ! -f "$WT_CHECK" ]; then
    say "Kept the agent worktree $wt: $WT_CHECK, which judges whether it can go, is missing."
    return 0
  fi
  # The same account the merge used, so the merged list is read as the merge was.
  [ -z "$account" ] || tok="$(gh auth token -u "$account" 2>/dev/null)" || tok=""
  if [ -n "$tok" ]; then
    out="$(cd "$main" && GH_TOKEN="$tok" bash "$WT_CHECK" --remove --just-merged "$wt" "$main" 2>&1)"; rc=$?
  else
    out="$(cd "$main" && bash "$WT_CHECK" --remove --just-merged "$wt" "$main" 2>&1)"; rc=$?
  fi
  case "$rc" in
    0|1)
      while IFS= read -r line; do
        case "$line" in "  "*) say "Agent worktree: ${line#  }"; said_any=1 ;; esac
      done <<<"$out"
      [ -n "$said_any" ] || say "Kept the agent worktree $wt: check-stale-worktrees.sh said nothing about it (exit $rc)." ;;
    2) say "Kept the agent worktree $wt: whether it can go could not be judged ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)). The stale worktree sweep looks at it again." ;;
    *) say "Kept the agent worktree $wt: check-stale-worktrees.sh broke (exit $rc, which it never returns on purpose: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ' | cut -c1-300))." ;;
  esac
  return 0
}

finish_branch(){   # $1 = the sentence saying it merged; always stops
  local said="$1" left n why moved="" failed="" del rrc
  merged_now=1
  # Merged: the turn is passed on now, not after the branch and worktree are tidied (#1515).
  turn_leave
  [ -n "$want_delete" ] || stop 0 "$said."
  if [ "$(printf '%s' "$view" | jq -r '.isCrossRepository // false')" = "true" ]; then
    stop 0 "$said. Its branch $branch is in a fork, not in $slug, so no branch was deleted."
  fi
  left="$said, but branch $branch was left in place"
  [ -n "$branch" ] || stop 4 "$said, but GitHub did not name its branch, so no branch was deleted."
  ref_repo="$slug"
  with_retries "branch $branch" read_ref; rrc=$?
  [ "$rrc" -eq 0 ] || stop 4 "$left: could not read it from GitHub ($read_err$(tried "$rrc")). Delete it by hand, or run the same command again to finish."
  [ -z "$ref_gone" ] || stop 0 "$said. Its branch $branch was already deleted."
  [ "$ref_tip" = "$head" ] || stop 4 "$left: it now points at ${ref_tip:0:7}, not the merged head ${head:0:7}, so it holds commits the merge did not."
  with_retries "the pull requests based on $branch" read_stacked; rrc=$?
  [ "$rrc" -eq 0 ] || stop 4 "$left: could not list the open pull requests based on it ($read_err$(tried "$rrc")), and deleting it would close every one. Run the same command again to finish."
  for n in $stacked; do
    case "$n" in ''|*[!0-9]*) stop 4 "$left: GitHub listed '$n' among the pull requests based on it, which is not a number." ;; esac
    if why="$(retarget "$n")"; then moved="$moved #$n"; else failed="$failed #$n ($why)"; fi
  done
  [ -z "$moved" ] || say "Moved the pull request(s) based on $branch onto $base:$moved."
  [ -z "$failed" ] || stop 4 "$left: GitHub would not move$failed onto $base, and deleting the branch would close them.${moved:+ Already moved:$moved.} Move them by hand, or run the same command again to finish."
  # Judged by the state left, never by the answers: a pull request still based on the branch now
  # (one GitHub said yes about, or one opened meanwhile) would be closed by the delete.
  with_retries "the pull requests based on $branch" read_stacked; rrc=$?
  [ "$rrc" -eq 0 ] || stop 4 "$left: could not list the open pull requests based on it after moving them ($read_err$(tried "$rrc")). Run the same command again to finish."
  if [ -n "$stacked" ]; then
    stop 4 "$left: $(printf '#%s ' $stacked)still based on it after the move, and deleting it would close them. Run the same command again to finish."
  fi
  if ! del="$(gh_as api -X DELETE "repos/$slug/git/refs/heads/$branch" 2>&1)"; then
    with_retries "branch $branch" read_ref
    [ -n "$ref_gone" ] || stop 4 "$left: GitHub refused to delete it (${del:0:300}). Delete it by hand, or run the same command again to finish."
  fi
  stop 0 "$said. Deleted its branch $branch${moved:+, after moving$moved onto $base}."
}

record_asked=""; polls=0; updates=0; head_seen=""; head_since=0; started_for=""; last_status=""; last_said=0
tip_seen=""; tip_moved_at=""
# The last update this run made (claude-config#1500): the head it was made to, when, and whether a
# compare has answered since. See head_is_tip and not_caught_up.
updated_from=""; updated_at=0; catching_up=""
# Out of time while waiting on something: the same stop wherever the wait is.
out_of_time(){   # $1 = what it was still waiting for
  if [ "$polls" -ge "$MAX_POLLS" ] || [ $(( $(now) - t0 )) -ge "$DEADLINE" ]; then
    stop 3 "Out of time: #$pr at ${head:0:7} $1 after $polls look(s). Nothing was merged; run the same command again to resume."
  fi
}
# An update GitHub has not shown, other than as a branch ahead of its pull request, which
# head_is_tip handles: the pull request and its branch both still at the head the update was made to
# and still behind, or a compare GitHub answers 404 for just after it (claude-config#1500; PET #1885
# stopped on such a 404). Waited on and never answered with another update, for the same four minutes
# head_is_tip allows a lag in all (two before the base is set again and two after), timed from the
# update; then a plain stop.
not_caught_up(){   # $1 = what GitHub shows
  local bound=$(( 2 * LAG_WAIT ))
  if [ $(( $(now) - updated_at )) -ge "$bound" ]; then
    stop 1 "Stopped: #$pr has not caught up with its branch $(mins "$bound") after it was updated with $base: $1. Nothing was merged; GitHub has not shown the update yet, so wait a while, then run the same command again."
  fi
  out_of_time "has not caught up with its branch since it was updated ($1)"
  wait_a_look "caught-up:$updated_from" "Head ${head:0:7}: #$pr has not caught up with its branch since it was updated: $1; waiting up to $(mins "$bound") from the update for GitHub to catch up, without updating again."
}
# THE HEARTBEAT (claude-config#1476). On PET #1857 this updated the branch and then said nothing for
# long enough that the agent watching it stopped it: the line repeated only every five minutes, and
# said nothing a stuck run would not also say. So a wait's line is said when it changes, and while it
# does not, every HEARTBEAT seconds again with how long this wait has lasted, so a log with nothing new
# for well past that (a look, with a read asked again, takes about a minute at most) means the
# helper is not running. A wait is what $1 names (a head's checks and
# review, a lag, main settling, an update GitHub has not shown), so a count of checks changing within
# it does not restart its clock. Two minutes is two looks at the default pace: a setting, not a
# measurement, on the injected clock (L524), and checked at each look, so it falls on the first look
# at or after it.
wait_key=""; wait_since=0
# $3, when given, is said with the line but is not part of it: a figure that grows at every look
# (how long the turn's holder has held it, claude-config#1515) would otherwise make every look a
# change, and the line would be said every minute instead of on the heartbeat.
wait_a_look(){   # $1 = what is being waited on, $2 = the status line, $3 = what grows with it
  local t; t="$(now)"
  if [ "$1" != "$wait_key" ]; then wait_key="$1"; wait_since="$t"; fi
  if [ "$2" != "$last_status" ]; then
    say "$2${3:-}"; last_status="$2"; last_said="$t"
  elif [ $(( t - last_said )) -ge "$HEARTBEAT" ]; then
    say "$2${3:-} Still waiting, for $(dur $(( t - wait_since ))) so far."; last_said="$t"
  fi
  "$SLEEP" "$POLL"
}
mins(){ if [ "$1" -ge 60 ] && [ $(( $1 % 60 )) -eq 0 ]; then printf '%dm' "$(( $1 / 60 ))"; else printf '%ds' "$1"; fi; }

# WHETHER GITHUB'S HEAD IS THE BRANCH'S TIP (claude-config#1458, see the header). Returns 0 when it
# is. Otherwise it waits a look, sets the base again once, or stops, and returns 1 for the caller to
# look again. The wait before the re-set, MWR_HEAD_LAG_SECONDS, is two minutes because GitHub
# normally shows a push on the pull request within seconds, so two looks at the default pace is well
# past an ordinary race between the push and this read, which then writes nothing to the pull
# request, and still far short of the ten minutes Bidspoke #2577 lagged. The same time again after
# the re-set bounds the wait for it to take, since that day it took at once. Both are settings, not
# measurements of how long GitHub can lag. The lag is timed from the look that first saw it, and a
# head that becomes the tip ends it, so a later lag is its own, with its own single re-set.
#
# THE SAME LAG AFTER AN UPDATE (claude-config#1500). During GitHub's 2026-10-22 incident PET #1885's
# branch moved to 9e50f0c when it was updated, but the pull request showed 60a80b8 for over 45
# minutes, and this read the unmoved head as still behind and updated it seven more times. So an
# update makes the next look confirm the head against the branch again, even when GitHub shows the
# same head, and a lag found then is this same lag, said as the pull request not having caught up
# with its branch since the update, and never answered with another update.
lag_since=""; resynced_at=""
head_is_tip(){
  local rrc why where lagged waitkey waitline
  ref_repo="$slug"; where="branch $branch"
  if [ "$(printf '%s' "$view" | jq -r '.isCrossRepository // false')" = "true" ]; then
    ref_repo="$(printf '%s' "$view" | jq -r '(.headRepositoryOwner.login // "") + "/" + (.headRepository.name // "")')"
    case "$ref_repo" in /*|*/) stop 1 "Stopped: #$pr is from a fork GitHub did not name, so its branch's tip cannot be read to confirm head ${head:0:7} is it. Nothing was merged." ;; esac
    where="branch $ref_repo:$branch"
  fi
  [ -n "$branch" ] || stop 1 "Stopped: GitHub did not name the branch of #$pr, so head ${head:0:7} cannot be confirmed as its tip. Nothing was merged."
  with_retries "the tip of $where" read_ref; rrc=$?
  [ "$rrc" -eq 0 ] || stop 1 "Stopped: could not read the tip of $where ($read_err$(tried "$rrc")), so nothing here can confirm head ${head:0:7} is what the branch holds. Nothing was merged."
  [ -z "$ref_gone" ] || stop 1 "Stopped: $where of #$pr is not on GitHub, so there is no tip to merge. Nothing was merged; push the branch again, then run the same command again."
  if [ "$ref_tip" = "$head" ]; then lag_since=""; resynced_at=""; return 0; fi
  waitkey="lag:$head"
  if [ "$head" = "$updated_from" ]; then
    lagged="#$pr has not caught up with its branch since it was updated: GitHub still shows head ${head:0:7}, but $where is at ${ref_tip:0:7}"
    waitline="Head ${head:0:7}: $lagged; waiting up to $(mins "$LAG_WAIT") for GitHub to catch up, without updating again."
  else
    lagged="GitHub still shows head ${head:0:7} for #$pr, but $where is at ${ref_tip:0:7}"
    waitline="Head ${head:0:7}: GitHub still shows it for #$pr, but $where is at ${ref_tip:0:7}; waiting up to $(mins "$LAG_WAIT") for GitHub to catch up."
  fi
  [ -n "$lag_since" ] || lag_since="$(now)"
  if [ -z "$resynced_at" ]; then
    if [ $(( $(now) - lag_since )) -lt "$LAG_WAIT" ]; then
      out_of_time "is not its branch's tip ($where is at ${ref_tip:0:7})"
      wait_a_look "$waitkey" "$waitline"
      return 1
    fi
    why="$(retarget "$pr")" || stop 1 "Stopped: after $(mins "$LAG_WAIT") $lagged, and GitHub refused to set its base again, the write that makes it read the branch again: $why. Nothing was merged."
    resynced_at="$(now)"
    say "After $(mins "$LAG_WAIT"), $lagged, so its base was set again to $base, which makes GitHub read the branch again. Looking again for the real head."
    "$SLEEP" "$POLL"
    return 1
  fi
  if [ $(( $(now) - resynced_at )) -lt "$LAG_WAIT" ]; then
    out_of_time "is not its branch's tip ($where is at ${ref_tip:0:7}) after its base was set again"
    wait_a_look "$waitkey" "Head ${head:0:7}: $lagged, after its base was set again; waiting up to $(mins "$LAG_WAIT") for that to take."
    return 1
  fi
  stop 1 "Stopped: $lagged, $(mins "$LAG_WAIT") after its base was set again to make GitHub read the branch again (and $(mins "$LAG_WAIT") of waiting before that). Nothing was merged: GitHub refuses to merge a head that is not its branch's tip. Push to the branch again, or wait a while, then run the same command again."
}
tip_ok_for=""

# THE REPOSITORY'S TURN (claude-config#1515, the queue itself is lib/merge-turn.sh). Returns 0 when
# this run may go on: it holds the turn, or no turn could be taken. Returns 1 to wait, with the
# wait's line in turn_line and the holder's growing time in turn_extra. The turn is taken at the
# first look that finds the pull request open and past the checks that need no wait (the merge
# method, the changelog record), and held through the update, the checks, the review and the merge,
# because each of those is what a merge under it would throw away. It is given up once the merge
# has landed, or at any stop. A run that cannot take one says so and goes on as the helper did
# before: the turn only orders the helpers on this Mac, and every gate still judges every merge.
turn_state=""; turn_waited_from=""; turn_line=""; turn_extra=""
turn_say_passed(){
  local l
  [ -n "$TURN_SAID" ] || return 0
  while IFS= read -r l; do [ -z "$l" ] || say "$l"; done <<<"$TURN_SAID"
}
turn_check(){
  local t
  [ "$turn_state" = off ] && return 0
  t="$(now)"
  if [ -z "$TURN_TICKET" ]; then
    turn_open "$slug"
    if ! turn_join "$pr" "$t"; then
      turn_state=off
      say "Could not take a turn to merge in $slug ($TURN_ERR), so this goes on without one, as it did before claude-config#1515: another helper on this Mac may merge under it."
      return 0
    fi
  fi
  turn_look "$t" "$TURN_HOLD"
  turn_say_passed
  if [ -n "$TURN_GONE" ]; then
    say "#$pr's place in the line to merge in $slug is gone: a run waiting for the turn takes it over once one pull request has held it for $(mins "$TURN_HOLD"). Joining the line again."
    TURN_TICKET=""; turn_state=""
    if ! turn_join "$pr" "$t"; then
      turn_state=off
      say "Could not join the line to merge in $slug again ($TURN_ERR), so this goes on without a turn: another helper on this Mac may merge under it."
      return 0
    fi
    turn_look "$t" "$TURN_HOLD"
    turn_say_passed
  fi
  if [ "$TURN_MINE" = 1 ]; then
    if [ "$turn_state" != held ]; then
      if [ -n "$turn_waited_from" ]; then
        say "It is #$pr's turn to merge in $slug now, after waiting $(dur $(( t - turn_waited_from ))) for it. Other helpers on this Mac wait until it has merged or stopped, for up to $(mins "$TURN_HOLD")."
      else
        say "Took the turn to merge in $slug: other helpers on this Mac wait until #$pr has merged or stopped, for up to $(mins "$TURN_HOLD")."
      fi
      turn_state=held; turn_waited_from=""
    fi
    return 0
  fi
  [ -n "$turn_waited_from" ] || turn_waited_from="$t"
  turn_state=waiting
  turn_line="Head ${head:0:7}: waiting for its turn to merge in $slug, which #${TURN_HEAD_PR:-?} holds ($TURN_AHEAD ahead of it in line)."
  turn_extra=" #${TURN_HEAD_PR:-?} has held it for $(dur $(( t - ${TURN_HEAD_SINCE:-$t} ))), of the $(mins "$TURN_HOLD") any one pull request may hold it."
  return 1
}

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
    # A run that stopped with the branch left in place (stop 4) is finished here when run again.
    MERGED) [ -n "$want_delete" ] && finish_branch "Pull request #$pr in $slug is already merged (head ${head:0:7})"
            merged_now=1
            stop 0 "Pull request #$pr in $slug is already merged (head ${head:0:7}); nothing to do." ;;
    OPEN) ;;
    *) stop 1 "Stopped: pull request #$pr in $slug is ${state:-in an unknown state}, not open. Nothing was merged." ;;
  esac
  [ -n "$head" ] && [ -n "$base" ] || stop 1 "Stopped: GitHub did not report the head commit or base branch of #$pr. Nothing was merged."
  if [ "$head" != "$head_seen" ]; then head_seen="$head"; head_since="$(now)"; fi

  # No method passed: the repository's settings choose one, or it stops here, before the changelog
  # gate judges a merge command and before any update or wait (claude-config#1476, L667).
  [ -n "$method" ] || choose_method

  # The changelog record, once, at the first look that finds the pull request open: before any
  # update, wait or lessons review, since none of them can change it (#1178, L667).
  if [ -z "$record_asked" ]; then
    record_asked=1
    if ! why="$(ask_gate "$CHANGELOG_GATE" "$(merge_text "$head")")"; then
      stop 1 "Stopped: require-changelog-tag.sh refused the merge of #$pr before any wait: $why Nothing was merged; run this again once that is dealt with."
    fi
  fi

  # The repository's turn, before any update, wait or lessons review is spent on a head another
  # helper's merge would put behind (claude-config#1515). Each look while waiting still reads the
  # pull request, so one merged or closed meanwhile stops here as it would have anyway.
  if ! turn_check; then
    out_of_time "is waiting for its turn to merge in $slug, which #${TURN_HEAD_PR:-?} holds"
    wait_a_look "turn:${TURN_HEAD_PR:-?}" "$turn_line" "$turn_extra"
    continue
  fi

  # The first time a head is seen, confirm it is the branch's tip before an update, a wait or a
  # lessons review is spent on it (claude-config#1458).
  if [ "$tip_ok_for" != "$head" ]; then
    head_is_tip || continue
    tip_ok_for="$head"
  fi

  # Behind its base: update, and go round for the new head.
  with_retries "whether #$pr contains the tip of $base" read_compare; rrc=$?
  if [ "$rrc" -eq 3 ] && [ -n "$catching_up" ]; then
    not_caught_up "GitHub answers 404 comparing head ${head:0:7} with $base"
    continue
  fi
  [ "$rrc" -eq 0 ] || stop 1 "Stopped: could not read whether #$pr contains the tip of $base ($read_err$(tried "$rrc")). Nothing was merged."
  # A compare answering for a head other than the one updated, or showing it no longer behind, is
  # GitHub having caught up, so a 404 after this is a refusal again.
  { [ "$head" != "$updated_from" ] || [ "$behind" -eq 0 ]; } && catching_up=""
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
    # STILL THE HEAD THIS RUN UPDATED (claude-config#1500): GitHub has not shown the update, which is
    # not a reason to make another. head_is_tip has already found the branch not ahead of it.
    if [ "$head" = "$updated_from" ]; then
      not_caught_up "GitHub and branch $branch both still show head ${head:0:7}, $behind behind $base"
      continue
    fi
    # MAIN STILL MOVING: wait for it to be still before updating. Each update starts a fresh check
    # run of 15 to 30 minutes (as they ran on 2026-10-16), and a base still taking merges would leave the new head behind again
    # before it finished, so a burst of merges is answered with one update after it, not one each.
    if [ -n "$tip_moved_at" ] && [ $(( $(now) - tip_moved_at )) -lt "$SETTLE" ]; then
      out_of_time "is behind $base, with $base still moving"
      wait_a_look "settle:$base" "Head ${head:0:7}: behind $base, with $base still moving; updating once it has been still for $(mins "$SETTLE")."
      continue
    fi
    upd="$(gh_as pr update-branch "$pr" --repo "$slug" 2>&1)" || stop 1 "Stopped: GitHub refused to update #$pr with $base: ${upd:0:500}. Nothing was merged; resolve it by hand."
    updates=$((updates + 1))
    # The next look confirms the head against the branch again even if GitHub shows the same one,
    # since that is how an update GitHub has not shown looks (claude-config#1500).
    updated_from="$head"; updated_at="$(now)"; catching_up=1; tip_ok_for=""
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
    # An allow can carry findings that repeat ones already answered, listed as answered
    # (claude-config#1338), and minor findings, printed as advisory (claude-config#1356), so the
    # verdict is shown, once each time it changes.
    0) [ -n "$rev_out" ] && [ "$rev_out" != "${rev_said:-}" ] && { printf '%s\n' "$rev_out"; rev_said="$rev_out"; } ;;
    3) waiting="${waiting:+$waiting, }lessons review still running" ;;
    *) printf '%s\n' "$rev_out"
       # After three rounds of findings the review asks to step back (claude-config#1358), and this
       # line asks the same rather than for the one finding at a time fix the review is asking to end.
       # The words are AR_STEP_BACK_LEAD, defined once in lib/ai-review-common.sh, and count only at
       # the start of a line, where the review prints them: a finding line begins with its file, so
       # one quoting the words is not a request to step back.
       [ -n "${AR_STEP_BACK_LEAD:-}" ] || . "$MWR_LIB/ai-review-common.sh" 2>/dev/null
       case $'\n'"$rev_out" in
         *$'\n'"${AR_STEP_BACK_LEAD:-Step back:}"*)
           stop 1 "Stopped: the lessons review of #$pr at ${head:0:7} refused (above), and asks to step back and reconsider the approach: read this round's findings with the earlier rounds' as one group before changing anything, rather than fixing one finding at a time. Then run: PR_REVIEW_READ=<key> $SELF $pr --repo $slug${flags[*]:+ ${flags[*]}} . Nothing was merged." ;;
       esac
       stop 1 "Stopped: the lessons review of #$pr at ${head:0:7} refused (above). If it has findings, read them, fix what is real or say why not, then run: PR_REVIEW_READ=<key> $SELF $pr --repo $slug${flags[*]:+ ${flags[*]}} . Nothing was merged." ;;
  esac

  if [ -n "$waiting" ]; then
    out_of_time "still has $waiting"
    wait_a_look "head:$head" "Head ${head:0:7}: waiting, $waiting."
    continue
  fi

  # Ready by every reading here, so confirm again that the head is the branch's tip, since a push can
  # land while the checks run and GitHub can fail to show it (claude-config#1458). The gates decide.
  head_is_tip || continue
  # Still this run's turn, asked again at the last moment, since the look that took it may have been
  # a minute and a review ago: a run that has lost it never merges under the one that has it.
  turn_check || continue
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
  # A pull request whose closing keywords name a Match the settled design issue merges only at 100% on
  # both halves of the design match score at this head (claude-config#1364).
  if ! why="$(ask_gate "$DESIGN_GATE" "$cmd")"; then
    stop 1 "Stopped: design-score-gate.sh refused the merge of #$pr at ${head:0:7}: $why"
  fi
  say "Head ${head:0:7} is green, up to date with $base and reviewed, and every merge gate allows it. Merging, pinned to that head."
  merge_out="$(gh_as "${merge_argv[@]}" --match-head-commit "$head" 2>&1)"; merge_rc=$?
  # Judged by the state it leaves, never by what gh printed: gh can fail after the merge has landed.
  with_retries "#$pr back after the merge" read_back; rrc=$?
  if [ "$rrc" -ne 0 ]; then
    # Unreadable is not "the head moved": say what is known and look again, where the read at the
    # top of the loop either finds it merged or stops naming GitHub's error.
    say "Could not read #$pr back after the merge command (gh exited $merge_rc: ${merge_out:0:200}; read: ${read_err:-no answer}$(tried "$rrc")); looking again."
    continue
  fi
  if [ "$(printf '%s' "$after" | jq -r '.state // ""')" = "MERGED" ]; then
    note=""; [ "$merge_rc" -ne 0 ] && note=" (gh exited $merge_rc after merging: ${merge_out:0:200})"
    finish_branch "Merged #$pr in $slug at ${head:0:7}$note"
  fi
  if [ "$(printf '%s' "$after" | jq -r '.headRefOid // ""')" != "$head" ]; then
    say "The head moved while it was being merged (GitHub refused the pin on ${head:0:7}); judging the new head."
    continue
  fi
  stop 1 "Stopped: gh pr merge did not merge #$pr at ${head:0:7}: ${merge_out:0:500}"
done
