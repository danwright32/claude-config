#!/usr/bin/env bash
#
# Refuse a pull request merge unless every area it touches has a passing verification run at the
# head being merged (claude-config#1529).
#
# A verification run is the verification-guides skill's RUN procedure (claude-config#1528): a fresh
# agent serves the app at the pull request's head on this machine, works through each touched
# area's guide, and posts one record per area in a PR comment, backed by a receipt the harness wrote.
# This gate is what makes that run a condition of merging rather than a suggestion (L27).
#
# SCOPE. A repository is judged only when the BASE commit of the pull request holds
# .claude/verification/areas.json. Every other merge in every project leaves after two reads, the
# pull request and that file at its base, and says nothing. Nothing in this repository lists the
# projects that opted in: the file is the opt in, and it lives in the project.
#
# BASE, NOT HEAD. areas.json (the ownership rules, which are the areas command, #1528) and every
# guide are read from the base commit GitHub reports for the pull request, so a pull request cannot
# edit what judges it: a record run against a guide the pull request changed does not count, and a
# new file no area owns needs an owner merged first.
#
# WHAT PASSES. Every changed file lands in exactly one bucket, and each touched area's newest record
# at the head (or at an earlier commit whose later patch, in this pull request's own files, leaves the
# area untouched) passes every check and done when item. Its receipt is on this machine, shows serve
# stopped, a clean egress verdict, a build stamp equal to the record's commit, and a successful drive
# call for the area. The merge is pinned to the head judged (--match-head-commit), read by the same
# lib/merge-target.sh reading block-red-merge.sh uses; a repository's own merge tool pins for itself
# and asks the gates again with the exact pinned command (merge-when-ready.sh does).
#
# The judgment is skills/verification-guides/scripts/merge_check.py, which reads every verification
# format through verification.py, the one reader the skill writes them with (L370, L655). This file
# only gathers what GitHub says into a bundle folder and turns the verdict into a hook answer.
#
# MODE. areas.json's `mode` decides. `block` refuses with every problem named. `warn` allows every
# merge, hands the full verdict to the session through additionalContext, and appends it to a tally
# keyed by pull request (verification.py, outside ~/.claude); verification-tally-notice.sh asks Dan
# whether to switch to block once that tally reaches its count. Where the mode cannot be read (the
# pull request or areas.json unreadable, areas.json malformed), the gate refuses: cannot tell is
# never "not gated" (L490).
#
# KNOWN TODAY, said rather than hidden: nothing measures network egress for a verification run yet,
# so every receipt says unmeasured, which is never clean. In block mode that refuses every merge; in
# warn mode it is named in every verdict.
#
# Covers every route to a merge (lib/merge-target.sh), refuses a command merging more than one pull
# request as block-red-merge.sh does, and gives its GitHub reads a budget inside the hook's timeout:
# a hook the harness kills for overrunning says nothing, which for a PreToolUse gate can read as an
# allow (#1081).
#
# Deliberate override: ALLOW_UNVERIFIED_MERGE=1 <the same command> (visible in the command).
#
# Seams, for the tests: VR_READ_TRIES (3 in all), VR_READ_RETRY_SECONDS (2), VR_READ_BUDGET_SECONDS
# (15, against a hook timeout of 30), VR_SLEEP (sleep), all chosen, not measured; VR_SCRIPTS (the
# skill's scripts folder); VERIFICATION_HOME (where receipts and the tally live, verification.py).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload=$(cat)

# Before every Bash command, so the commonest case leaves here before anything is loaded, by the
# words every merge route names (mt__might_merge in lib/merge-target.sh).
case "$payload" in *merge*|*Merge*|*enqueuePullRequest*) ;; *) exit 0 ;; esac

# shellcheck source=lib/merge-target.sh
. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || exit 0

SCRIPTS="${VR_SCRIPTS:-$HOOK_DIR/../skills/verification-guides/scripts}"
AREAS_PATH=".claude/verification/areas.json"
OVERRIDE="Deliberate override: ALLOW_UNVERIFIED_MERGE=1 <the same command>."

# On stderr with exit 2 rather than through deny(), which builds its JSON with jq, one of the tools
# that can be missing.
refuse_no_reader() {  # $1 = the absence clause, $2 = what it costs, $3 = what to install
  echo "Cannot judge this merge's verification runs: $(ps_reader_absent_why "$1" "$2" "$3") $OVERRIDE" >&2
  exit 2
}

if ps_reader_missing jq python3; then
  case "$payload" in
    *ALLOW_UNVERIFIED_MERGE=1*) exit 0 ;;
    *)
      refuse_no_reader "neither jq nor python3 is on PATH" \
        "require-verification-run.sh reads this command out of the hook payload, which is JSON, with one of them, so with neither installed it cannot tell whether this command merges a pull request at all, let alone which one." \
        "jq or python3" ;;
  esac
fi

parsed=$(ps_parse_payload "$payload" raw) || parsed=""
command="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"

mt_runs_merge "$command" || exit 0

case "$command" in
  *ALLOW_UNVERIFIED_MERGE=1*) exit 0 ;;
esac

deny() {
  jq -nc --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

ps_reader_missing jq && refuse_no_reader "jq is not on PATH" \
  "require-verification-run.sh reads GitHub's answers about this pull request with it, so with jq absent nothing here can tell whether its base branch asks for verification runs at all." \
  "jq"

command -v gh >/dev/null 2>&1 || deny "Cannot tell whether this merge needs verification runs: gh is not on PATH, so GitHub cannot be asked whether the base branch holds $AREAS_PATH. $OVERRIDE"

# One pull request per command, as block-red-merge.sh insists for every merge (#1062): the verdict
# below is about one head, and a second merge would land on it.
if span_why="$(mt_merge_span_why "$command" "$cwd")"; then
  deny "Cannot judge this merge's verification runs: $span_why"
fi

# A merge through the GitHub API whose pull request cannot be named (#1181). Asked in this shell, so a
# GraphQL merge's node is resolved once, and MT_API_ROUTE and MT_API_PIN reach mt_merge_pin below.
if mt_api_merge_untold "$command"; then
  deny "Cannot judge this merge's verification runs: $MT_API_WHY $OVERRIDE"
fi

if mt_is_pr_merge "$command" && mt_reader_missing; then
  deny "Cannot tell whether this merge needs verification runs: $(mt_reader_absent_why) $OVERRIDE"
fi

repo_flag="$(mt_repo_flag "$command")"
cd "$(mt_repo_dir "$command" "$cwd")" 2>/dev/null || true
local_slug=$(mt_remote_slug)
slug="${repo_flag:-$local_slug}"
pr=$(mt_pr_number "$command")

# THE READS ARE ASKED AGAIN when GitHub did not answer, through mt_retry_read, the one retry loop the
# other merge gates use (#1061, #1081), inside a BUDGET measured from the start of this hook in the
# shell's own SECONDS: no read starts once it is spent, and no retry is made whose wait would end
# past it. A read that still fails refuses, in block mode or wherever the mode cannot yet be read.
vr_num(){ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
READ_TRIES="$(vr_num "${VR_READ_TRIES:-}" 3)"
READ_WAIT="$(vr_num "${VR_READ_RETRY_SECONDS:-}" 2)"
READ_DEADLINE="$(vr_num "${VR_READ_BUDGET_SECONDS:-}" 15)"
READ_SLEEP="${VR_SLEEP:-sleep}"
BUDGET_SPENT="this hook's read budget of $READ_DEADLINE seconds was spent before it could be read"
read_again(){ mt_retry_read "$READ_TRIES" "$READ_WAIT" "$READ_SLEEP" "$READ_DEADLINE" "" "$1"; }

read_view(){
  if [ "$SECONDS" -gt "$READ_DEADLINE" ]; then
    envelope=$(jq -nc --arg e "$BUDGET_SPENT" '{found: false, wrongRepo: "", notFound: false, error: $e}')
    return 1
  fi
  envelope=$(mt_pr_view "$pr" "number,url,headRefOid,baseRefOid,baseRefName,body,changedFiles" "$slug" "$repo_flag")
  mt_view_class "$envelope"
}
read_again read_view; view_rc=$?

if [ "$(printf '%s' "$envelope" | jq -r '.found // false' 2>/dev/null)" != "true" ]; then
  searched="$(mt_searched_repo "$repo_flag" "$local_slug" "$PWD")"
  searched_why="$(mt_searched_why "$repo_flag" "$local_slug" "$PWD")"
  pr_label="$(mt_pr_label "$pr")"
  wrong=$(printf '%s' "$envelope" | jq -r '.wrongRepo // ""' 2>/dev/null)
  [ -n "$wrong" ] && deny "Refusing to merge: the only answer gh gave was about $wrong, not about $slug, and judging one pull request's verification runs while merging another judges neither. $OVERRIDE"
  # NOT FOUND is not "GitHub could not be read" (L11): the remedy is naming the right repository.
  if [ "$(printf '%s' "$envelope" | jq -r '.notFound // false' 2>/dev/null)" = "true" ]; then
    deny "Refusing to merge: no $pr_label was found in $searched under any logged-in account, so there is nothing here to judge. It was looked for there because $searched_why. If it lives in another repository, name that repository with --repo owner/name on the merge, or cd into its checkout before the merge."
  fi
  gh_error=$(printf '%s' "$envelope" | jq -r '.error // ""' 2>/dev/null)
  budget=""
  [ "$view_rc" = 2 ] && budget=", and GitHub did not answer within this hook's read budget ($READ_TRIES tries, $READ_DEADLINE seconds)"
  deny "Cannot tell whether this merge needs verification runs: GitHub could not be read for the $pr_label in $searched under any logged-in account (${gh_error:-gh printed nothing})$budget, so whether its base branch asks for verification runs is unknown. $OVERRIDE"
fi

view=$(printf '%s' "$envelope" | jq -c '.view')
view_account=$(printf '%s' "$envelope" | jq -r '.account // ""')
number=$(printf '%s' "$view" | jq -r '.number // ""')
head=$(printf '%s' "$view" | jq -r '.headRefOid // ""')
base_oid=$(printf '%s' "$view" | jq -r '.baseRefOid // ""')
# The repository the answer is about, from its own URL, since mt_pr_view proved it is the one asked.
api_slug=$(printf '%s' "$view" | jq -r '.url // ""' | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#p')
if [ -z "$number" ] || [ -z "$base_oid" ] || [ -z "$api_slug" ]; then
  deny "Cannot tell whether this merge needs verification runs: GitHub's answer about the pull request named no number, base commit or repository, so its base branch cannot be read. $OVERRIDE"
fi

# One gh api read inside the budget, kept in $1. Returns 0 answered, 3 GitHub's own 404, 1 failed,
# with VR_FAIL the sentence saying what could not be read and why.
VR_OUT=""; VR_WHAT=""; VR_FAIL=""; VR_ARGS=()
vr__read(){
  if [ "$SECONDS" -gt "$READ_DEADLINE" ]; then
    MT_READ_STATE="unknown"; MT_READ_ERR="$BUDGET_SPENT"; return 1
  fi
  mt_api_read "$VR_OUT" "$view_account" "${VR_ARGS[@]}"
}
vr_get(){  # $1 = file for the answer, $2 = what is being read, $3.. = gh api arguments
  local rc
  VR_OUT="$1"; VR_WHAT="$2"; shift 2; VR_ARGS=("$@"); VR_FAIL=""
  read_again vr__read; rc=$?
  case "$rc" in
    0) [ "$MT_READ_STATE" = absent ] && return 3; return 0 ;;
    2) VR_FAIL="$VR_WHAT: $MT_READ_ERR, and GitHub did not answer within this hook's read budget ($READ_TRIES tries, $READ_DEADLINE seconds)" ;;
    *) VR_FAIL="$VR_WHAT: $MT_READ_ERR" ;;
  esac
  return 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/verify-merge.XXXXXX") \
  || deny "Cannot judge this merge's verification runs: no temporary folder could be made for GitHub's answers. $OVERRIDE"
trap 'rm -rf "$WORK"' EXIT

RAW="Accept: application/vnd.github.raw"
vr_get "$WORK/areas.json" "$AREAS_PATH at the base commit $base_oid" -H "$RAW" "repos/$api_slug/contents/$AREAS_PATH?ref=$base_oid"
case "$?" in
  0) ;;
  # The commonest answer by far: this repository has not opted in. Nothing to say.
  3) exit 0 ;;
  *) deny "Cannot tell whether this merge needs verification runs: GitHub could not be read for $VR_FAIL. $OVERRIDE" ;;
esac

# The judge needs python3, asked only now that the rule is known to apply, so a machine without it
# loses nothing on the repositories that never opted in (L54).
command -v python3 >/dev/null 2>&1 || deny "Cannot judge this merge's verification runs: $(ps_detector_absent_why "python3 is not on PATH" "require-verification-run.sh judges them through merge_check.py and verification.py, the one reader of every verification format, so with it absent nothing here can tell a passing run from a missing one." "python3") $OVERRIDE"
for f in merge_check.py verification.py; do
  [ -f "$SCRIPTS/$f" ] || deny "Cannot judge this merge's verification runs: $SCRIPTS/$f is missing, and it is part of the judge (the verification-guides skill). Restore it with claude-sync pull. $OVERRIDE"
done

printf '%s' "$view" > "$WORK/view.json"
printf '%s' "$api_slug" > "$WORK/slug"
# A merge this gate can read the pin of must pin the head judged. A repository's own merge tool
# pins for itself and hands the gates the exact pinned command, where this is asked again.
case "${MT_API_ROUTE:-}" in
  pr|rest|graphql) mt_merge_pin "$command"; printf 'required %s' "$MT_PIN_SHA" > "$WORK/pin" ;;
  *) printf 'not-required' > "$WORK/pin" ;;
esac

# What a failed read leaves: its .err beside where the answer would have been, and no answer.
keep_or_fail(){  # $1 = the answer file, $2 = vr_get's return code
  case "$2" in
    0) ;;
    3) rm -f "$1"; printf '%s: GitHub answered that it does not exist (HTTP 404)' "$VR_WHAT" > "${1%.*}.err" ;;
    *) rm -f "$1"; printf '%s' "$VR_FAIL" > "${1%.*}.err" ;;
  esac
}
vr_get "$WORK/files.json" "this pull request's changed files" --paginate "repos/$api_slug/pulls/$number/files?per_page=100"
keep_or_fail "$WORK/files.json" "$?"
vr_get "$WORK/comments.json" "this pull request's comments" --paginate "repos/$api_slug/issues/$number/comments?per_page=100"
keep_or_fail "$WORK/comments.json" "$?"

judge(){  # $@ = extra arguments to merge_check.py verdict
  verdict=$(python3 "$SCRIPTS/merge_check.py" verdict "$WORK" "$@" 2>"$WORK/judge.err")
}
judge_failed(){
  deny "Cannot judge this merge's verification runs: merge_check.py gave no verdict ($(awk 'NF { last = $0 } END { print last }' "$WORK/judge.err" 2>/dev/null | cut -c1-300)). That is the judge failing, not the runs passing. $OVERRIDE"
}

judge || judge_failed
if [ "$(printf '%s' "$verdict" | jq -r 'has("need")' 2>/dev/null)" = "true" ]; then
  mkdir -p "$WORK/guides" "$WORK/compare"
  # Split by parameter expansion, never `IFS=$'\t' read`, which collapses an empty field.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    area="${line%%$'\t'*}"; gpath="${line#*$'\t'}"
    enc=$(jq -rn --arg p "$gpath" '$p | split("/") | map(@uri) | join("/")')
    vr_get "$WORK/guides/$area.md" "the guide $gpath at the base commit $base_oid" -H "$RAW" "repos/$api_slug/contents/$enc?ref=$base_oid"
    case "$?" in
      0) ;;
      3) rm -f "$WORK/guides/$area.md"; : > "$WORK/guides/$area.absent" ;;
      *) rm -f "$WORK/guides/$area.md"; printf '%s' "$VR_FAIL" > "$WORK/guides/$area.err" ;;
    esac
  done < <(printf '%s' "$verdict" | jq -r '.need.guides[]? | "\(.area)\t\(.path)"')
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    vr_get "$WORK/compare/$sha.json" "the changes from $sha to the head $head" "repos/$api_slug/compare/$sha...$head"
    keep_or_fail "$WORK/compare/$sha.json" "$?"
  done < <(printf '%s' "$verdict" | jq -r '.need.compares[]?')
  judge --final || judge_failed
fi

decision=$(printf '%s' "$verdict" | jq -r '.decision // ""' 2>/dev/null)
text=$(printf '%s' "$verdict" | jq -r '.text // ""' 2>/dev/null)
mode=$(printf '%s' "$verdict" | jq -r '.mode // ""' 2>/dev/null)
case "$decision" in
  refuse) deny "$text" ;;
  allow)
    if [ "$mode" = warn ]; then
      jq -nc --arg t "$text" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $t}}'
    fi
    exit 0 ;;
  *) judge_failed ;;
esac
