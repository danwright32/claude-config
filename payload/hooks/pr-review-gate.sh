#!/usr/bin/env bash
#
# pr-review-gate.sh
# Claude Code PreToolUse(Bash) hook.
#
# Refuse a merge until the lessons review of that pull request's head has FINISHED and its findings
# have been READ by the session merging (claude-config#560, #788): the merge presents the findings'
# read key as PR_REVIEW_READ=<key>, which only the messages carrying them hold. The review itself, and every outcome it can have, is
# lib/pr-review.sh; this hook only decides whether a command merges and which head it merges.
#
# EVERY MERGE ROUTE this hook can see: `gh pr merge`, the GitHub API's merge endpoint and GraphQL
# merge mutations (claude-config#1181), and a repo's own merge script in command position
# (mt_runs_merge, the matcher block-red-merge.sh and the changelog gate share). It is registered
# WITHOUT an `if` filter, as every merge gate now is, because a filter such as `Bash(gh pr merge*)`
# never fires for a script or an API call. A merge made INSIDE a script this hook cannot see (Overture's merge_pr is called by
# verify-and-merge-branch.sh and verify-and-merge-batch.sh, which are not merge tools by name) is
# covered by that script asking `pr-review.sh check` itself before it merges, so the rule lives in
# one place and every route asks it.
#
# The head is the PULL REQUEST's, read from GitHub (headRefOid) through mt_pr_view, never the local
# HEAD, which can be a different commit (L179). Refuses when the pull request cannot be found:
# merging something no review has read is what this gate exists to stop (L42).
#
# The branch is read from a checkout of the pull request's repository: a merge naming its repository
# from a folder that is not a checkout of it is read from one this Mac knows, or refused saying a
# checkout is needed (mt_review_checkout, claude-config#1607).
#
# Only minor findings do not hold a merge (claude-config#1356): they are handed to the session and to
# Dan as advisory, through mt_review_allowed in lib/merge-target.sh.
#
# Override, one command, visible: SKIP_PR_REVIEW=1 on the merge. Explain to Dan first.

set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cat)"

refuse() { printf '%s\n' "$1" >&2; exit 2; }

# THE RECORDS OF WHO WAS SHOWN THE FINDINGS ARE THE GATES' ALONE (claude-config#1700, #1719). A Bash
# command naming the typed helper key's folder, the secret it and the read keys are kept under, a
# review's read keys file, or the functions that write or reach them (all spelled helper-key,
# helper-secret or readkeys, with a hyphen or an underscore, in any case, since the disk does not
# tell case apart) is refused before it runs, the way the design round guard refuses a write to its
# own record: a session making such a record by hand is the merge without reading this gate exists to
# stop. test-pr-review.sh reads every function of lib/ai-review-common.sh that reaches the secret or
# a read keys file and fails on one this does not refuse by name. The raw payload is matched first, so every
# other command leaves at once; one that matches is judged on its command text, read through the
# shared reader once it is known to be installed. Where the library or the reader is missing, or the
# text cannot be read, the command is refused, since a reader that cannot run must not pass what it
# was asked to judge (L490). There is no override: an override is exactly what a session forging a
# record would use.
pr_review_names_record() { local rc=1; shopt -s nocasematch; case "$1" in *helper[-_]key*|*helper[-_]secret*|*readkeys*) rc=0 ;; esac; shopt -u nocasematch; return "$rc"; }
if pr_review_names_record "$payload"; then
  . "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null \
    || refuse "Refused: this command names a record the lessons review keeps of whose merge or push was shown its findings, and lib/merge-target.sh is missing, so pr-review-gate.sh cannot read the command to tell whether it touches that record (claude-config#1700, #1719). Restore the hooks library and run it again."
  if ps_reader_missing jq python3; then
    refuse "Refused: $(ps_reader_absent_why "neither jq nor python3 is on PATH" "pr-review-gate.sh reads this command's text with one of them to tell whether it touches a record the lessons review keeps of whose merge or push was shown its findings (claude-config#1700, #1719)." "jq")"
  fi
  named_parsed="$(ps_parse_payload "$payload" raw)" || named_parsed="$payload"
  named_command="${named_parsed%%$'\x1f'*}"
  if pr_review_names_record "$named_command"; then
    refuse "Refused: this command names a record the lessons review keeps of whose merge or push was shown its findings (the helper-keys folder under its state, the secret those records are kept under, a review's read keys file, or the functions that write them), and only the lessons review's own gates write those records, when they show the findings or see their key typed (claude-config#1700, #1719). To merge or push, read the findings and type their key in front of the command: PR_REVIEW_READ=<key> <the gh pr merge, git push or merge helper command>. To read the code that keeps the records, use the Read or Grep tool rather than a shell command."
  fi
fi

# It runs before EVERY Bash command, so the commonest case leaves before anything is loaded: every
# route mt_runs_merge recognises names a merge, as mt__might_merge in lib/merge-target.sh says in
# which words, and a payload naming none cannot be one (a GraphQL merge says "Merge" or nothing at
# all, claude-config#1181).
case "$payload" in *merge*|*Merge*|*enqueuePullRequest*) ;; *) exit 0 ;; esac


# The libraries this gate reads through. Missing, it cannot tell a merge from anything else, so it
# refuses only what could be one, by the cheap substring the matcher itself starts with.
if ! . "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null; then
  case "$payload" in
    *SKIP_PR_REVIEW=1*) exit 0 ;;
    *) refuse "Refusing to merge: lib/merge-target.sh is missing, so pr-review-gate.sh cannot tell whether this command merges a pull request or read its head for the lessons review. Override for one merge, explained to Dan first: SKIP_PR_REVIEW=1 <the same command>." ;;
  esac
  exit 0
fi
if ps_reader_missing jq python3 || ! command -v jq >/dev/null 2>&1; then
  case "$payload" in
    *SKIP_PR_REVIEW=1*) exit 0 ;;
    *) refuse "Refusing to merge: jq is not on PATH, and the lessons review gate reads the pull request's head from GitHub with it. Install jq. Override for one merge, explained to Dan first: SKIP_PR_REVIEW=1 <the same command>." ;;
  esac
  exit 0
fi

parsed="$(ps_parse_payload "$payload" raw)" || parsed=""
command="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"

# A READ KEY TYPED IN FRONT OF THE MERGE HELPER (claude-config#1673). The helper merges inside itself
# and takes its key from its environment, so it accepts one only when this gate saw it TYPED as a
# literal in front of the helper's own command (ar_helper_key_record in lib/ai-review-common.sh says
# why). Read by the same reader as a typed merge's key, mt_presented_read_key, with the helper as the
# action. Nothing is refused for carrying no key: the helper waits for the review and asks it itself.
# A key typed here that cannot be recorded refuses the command, saying so, since the helper would
# otherwise refuse it for a reason this gate alone knows (L11, L667).
pr_review_runs_helper() { printf '%s' "$1" | python3 "$HOOK_DIR/lib/agent-overrides.py" runs-script merge-when-ready.sh >/dev/null 2>&1; }
case "$command" in
  *merge-when-ready*)
    helper_key="$(mt_presented_read_key "$command" pr_review_runs_helper)"
    if [ -n "$helper_key" ]; then
      { [ "$(type -t ar_helper_key_record)" = function ] || . "$HOOK_DIR/lib/ai-review-common.sh"; } 2>/dev/null
      if ! ar_helper_key_record "$helper_key" 2>/dev/null; then
        key_home="${AR_STATE_DIR:-}"; [ -n "$key_home" ] || key_home="the state folder of the lessons review"
        refuse "Refusing to run the merge helper: the read key typed in front of it could not be recorded under $key_home (lib/ai-review-common.sh missing, python3, od or /dev/urandom missing, or the folder not writable), and the helper takes a key only once this gate has recorded it as typed (claude-config#1673). Fix that folder, or merge with the key typed in front of gh pr merge instead."
      fi
    fi ;;
esac

mt_runs_merge "$command" || exit 0

if ps_has_override "$command" SKIP_PR_REVIEW; then
  echo "pr-review-gate: SKIP_PR_REVIEW=1 was set, so this merge was NOT held for the lessons review. Tell Dan why it was skipped; never skip it silently."
  exit 0
fi

# ONE pull request per command (claude-config#1062): the head, the review and the read key below are
# all the first merge's, so a second merge in the same command went through on the first one's
# reading. Refused, with how to run them so each is held.
if span_why="$(mt_merge_span_why "$command" "$cwd")"; then
  refuse "Refusing to merge: $span_why"
fi

# A merge through the GitHub API whose pull request cannot be named (claude-config#1181): read as the
# current branch's below, it would be held to another pull request's review. Asked in this shell, so
# a GraphQL merge's node is resolved once and the reads below take that answer.
if mt_api_merge_untold "$command"; then
  refuse "Refusing to merge: $MT_API_WHY"
fi

repo_dir="$(mt_repo_dir "$command" "$cwd" 2>/dev/null)"
[ -n "$repo_dir" ] || repo_dir="$cwd"
cd "$repo_dir" 2>/dev/null || refuse "Refusing to merge: could not enter $repo_dir to find the lessons review for this merge. Override, explained to Dan first: SKIP_PR_REVIEW=1 <the same command>."

pr="$(mt_pr_number "$command")"
repo_flag="$(mt_repo_flag "$command")"
slug="${repo_flag:-$(mt_remote_slug)}"
envelope="$(mt_pr_view "$pr" "number,headRefOid,baseRefName,headRefName,url" "$slug" "$repo_flag")"
head="$(printf '%s' "$envelope" | jq -r 'if .found then .view.headRefOid // "" else "" end' 2>/dev/null)"
base="$(printf '%s' "$envelope" | jq -r 'if .found then .view.baseRefName // "" else "" end' 2>/dev/null)"
# The pull request's own branch labels the review, never the branch this checkout happens to be on,
# which on a shared primary checkout is another session's work (claude-config#852).
head_branch="$(printf '%s' "$envelope" | jq -r 'if .found then .view.headRefName // "" else "" end' 2>/dev/null)"
if [ -z "$head" ]; then
  err="$(printf '%s' "$envelope" | jq -r '.error // ""' 2>/dev/null)"
  refuse "Refusing to merge: could not read the head of $(mt_pr_label "$pr") in ${slug:-this repository} from GitHub${err:+ ($err)}, so there is no way to know which lessons review answers for it. Override, explained to Dan first: SKIP_PR_REVIEW=1 <the same command>."
fi

# The checkout the review reads the branch from (claude-config#1607): the merge's own directory, unless
# the merge names a repository that directory is not a checkout of, when a checkout of it this Mac
# knows answers, or the merge is refused saying a checkout is needed. The pull request's URL, as GitHub
# gave it, finds the checkout it was opened from first.
pr_url="$(printf '%s' "$envelope" | jq -r 'if .found then .view.url // "" else "" end' 2>/dev/null)"
mt_review_checkout "$repo_dir" "$repo_flag" "$pr_url" || refuse "Refusing to merge: $MT_REVIEW_WHY"
review_dir="$MT_REVIEW_DIR"
from_note=""
[ "$MT_REVIEW_ELSEWHERE" = 1 ] && from_note="pr-review-gate: this merge names $repo_flag and runs in $repo_dir, which is not a checkout of it, so its lessons review is read from $review_dir, a checkout of it on this Mac."$'\n'

args=(check --dir "$review_dir" --sha "$head")
[ -n "$base" ] && args+=(--base-ref "origin/$base")
[ -n "$head_branch" ] && args+=(--branch "$head_branch")
# The pull request a review started here reads the description and comments of, where answers to
# earlier findings are written (claude-config#1161). Its number as GitHub gave it, so a merge naming
# the pull request by branch or link still passes a number.
pr_number="$(printf '%s' "$envelope" | jq -r 'if .found then .view.number // "" else "" end' 2>/dev/null)"
case "$pr_number" in ''|*[!0-9]*) ;; *) args+=(--pr "$pr_number") ;; esac
# The read key the findings' refusal carries, if this merge presents it (claude-config#788). The
# hook does not inherit the command's own assignments, so it is read from the command text and
# handed on; anything else in the environment is cleared, so only THIS command can present one.
#
# Only as an assignment in front of the MERGE segment itself: text in an echo, or an assignment in
# front of some other command, says nothing about this merge (L673). Segments are cut the way the
# merge matcher cuts them, so the segment judged a merge here is the one mt_runs_merge judged, and
# its leading assignments are read as the shell reads them, so a key before
# `GH_TOKEN=$(gh auth token -u x) gh pr merge` is found and quotes around it are removed.
read_key="$(mt_presented_read_key "$command" mt_runs_merge)"
out="$(PR_REVIEW_READ="$read_key" bash "$HOOK_DIR/lib/pr-review.sh" "${args[@]}" 2>&1)"; rc=$?
# An allow with minor findings hands them over as advisory, to the session and to Dan (#1356).
[ "$rc" -eq 0 ] && mt_review_allowed pr-review-gate "$out"
refuse "$from_note$out"
