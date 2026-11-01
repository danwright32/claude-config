#!/usr/bin/env bash
#
# Refuse a pull request merge whose title, description or commit messages name a work organisation,
# in a repository that guards its files against them (claude-config#1995).
#
# This repository is public, and its whole tree is held free of the work GitHub organisations' names
# by lib/work-names.py (#1568). It squash merges with the commit messages as the body and the title
# as the subject, so a name written into either lands in main without ever being a file the tree scan
# reads, and the description is published beside it. On 2026-10-31 a builder's commit message quoted
# a refusal naming a work organisation and repository; it was caught only by reading it by hand.
# scanners-before-push.sh judges the messages of the commits a push adds; this judges everything the
# merge publishes, at the one moment it is published, which also catches a commit pushed from
# anywhere the push gate did not run, a description written in the web, and a later edit (L280).
#
# THE RULE is lib/work-names.py's, the one the tree suite runs over the files, asked through its
# --texts0-from stream (title, description, then each commit by its short sha), so a name is judged
# the same in a file and in a message (L263, L370). What it prints never repeats the name, only the
# label and the line.
#
# SCOPE. A repository is judged only when the BASE commit of the pull request holds
# payload/hooks/lib/work-names.py: the file check is the opt in, and wherever it guards the files, this
# guards the messages. Every other merge in every project leaves after two reads, the pull request
# and that file at its base, and says nothing. A private work repository naming its own organisation
# is never refused. Read at the base, so a pull request cannot remove what judges it.
#
# Where the pull request, the scope or the verdict cannot be read the merge is refused: cannot tell is
# never "nothing wrong" (L490). Every route to a merge (lib/merge-target.sh), one pull request per
# command (claude-config#1062); its GitHub reads have a budget inside the hook's timeout and are
# asked again while GitHub fails transiently, as the other merge gates' are (#1061, #1081), and
# merge-when-ready.sh asks this gate before it merges as it asks every merge gate.
#
# NO OVERRIDE. It is a privacy rule, and its remedy is always open: edit the title or description,
# or reword the commit on the branch.
#
# Seams, for the tests: WN_MERGE_READ_TRIES (3 in all), WN_MERGE_READ_RETRY_SECONDS (2),
# WN_MERGE_READ_BUDGET_SECONDS (15, against a hook timeout of 30; MT_GATE_READ_BUDGET_SECONDS, which
# merge-when-ready.sh sets, when it is unset), WN_MERGE_SLEEP (sleep), all chosen, not measured;
# WN_MERGE_SCANNER (the scanner file).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload=$(cat)

# Before every Bash command, so the commonest case leaves here before anything is loaded, by the
# words every merge route names (mt__might_merge in lib/merge-target.sh).
case "$payload" in *merge*|*Merge*|*enqueuePullRequest*) ;; *) exit 0 ;; esac

WHAT="Cannot tell whether this merge publishes a work organisation name"

# shellcheck source=lib/merge-target.sh
{ . "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null && declare -F mt_runs_merge >/dev/null; } || {
  # A library this gate cannot load is not a merge with nothing to check (claude-config#1900,
  # L10). Past the words above this may be a merge, so it is refused, naming the file.
  echo "$WHAT: check-work-names-merge.sh could not load $HOOK_DIR/lib/merge-target.sh, or lib/push-scope.sh beneath it, which reads whether this command merges a pull request and which one, so its title, description and commit messages could not be checked. A library this gate cannot load is not a merge with nothing to check. Reinstall the hooks with claude-sync pull." >&2
  exit 2
}

SCANNER="${WN_MERGE_SCANNER:-$HOOK_DIR/lib/work-names.py}"
SCOPE_PATH="payload/hooks/lib/work-names.py"

# On stderr with exit 2 rather than through deny(), which builds its JSON with jq, one of the tools
# that can be missing.
refuse_no_reader() {  # $1 = the absence clause, $2 = what it costs, $3 = what to install
  echo "$WHAT: $(ps_reader_absent_why "$1" "$2" "$3")" >&2
  exit 2
}

if ps_reader_missing jq python3; then
  refuse_no_reader "neither jq nor python3 is on PATH" \
    "check-work-names-merge.sh reads this command out of the hook payload, which is JSON, with one of them, so with neither installed it cannot tell whether this command merges a pull request at all, let alone which one." \
    "jq or python3"
fi

# Cleaned before anything parses it: a lone surrogate escape made jq read nothing (claude-config#1944).
# A payload still unreadable is judged by its words (#1922).
payload="$(ps_clean_payload "$payload")"
parsed=$(ps_parse_payload "$payload" raw) \
  || ps_unparsed_refuse "$payload" check-work-names-merge.sh - "a merge of a pull request" '*merge*' '*Merge*' '*enqueuePullRequest*'
command="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"

mt_runs_merge "$command" || exit 0

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
  "check-work-names-merge.sh reads GitHub's answer about this pull request with it, so with jq absent nothing here can read its title, description or commit messages." \
  "jq"

command -v gh >/dev/null 2>&1 || deny "$WHAT: gh is not on PATH, so GitHub cannot be asked for the pull request's title, description and commit messages."

# One pull request per command: the text read below is one pull request's.
if span_why="$(mt_merge_span_why "$command" "$cwd")"; then
  deny "Cannot judge whether this merge publishes a work organisation name: $span_why"
fi

# A merge through the GitHub API whose pull request cannot be named (#1181).
if mt_api_merge_untold "$command"; then
  deny "Cannot judge whether this merge publishes a work organisation name: $MT_API_WHY"
fi

if mt_is_pr_merge "$command" && mt_reader_missing; then
  deny "$WHAT: $(mt_reader_absent_why)"
fi

repo_flag="$(mt_repo_flag "$command")"
cd "$(mt_repo_dir "$command" "$cwd")" 2>/dev/null || true
local_slug=$(mt_remote_slug)
slug="${repo_flag:-$local_slug}"
pr=$(mt_pr_number "$command")

# The reads are asked again while GitHub fails transiently, inside a budget measured from the start of
# this hook in the shell's own SECONDS, through mt_retry_read, the one retry loop the merge gates use.
# A refused sign in, or a network to GitHub that failed on every try, refuses in its own words
# (mt_unanswered_said), never as GitHub being unreadable (claude-config#1615, #1728, L11).
wn_num(){ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
READ_TRIES="$(wn_num "${WN_MERGE_READ_TRIES:-}" 3)"
READ_WAIT="$(wn_num "${WN_MERGE_READ_RETRY_SECONDS:-}" 2)"
READ_DEADLINE="$(mt_gate_read_budget "${WN_MERGE_READ_BUDGET_SECONDS:-}" 15)"
READ_SLEEP="${WN_MERGE_SLEEP:-sleep}"
BUDGET_SPENT="this hook's read budget of $READ_DEADLINE seconds was spent before it could be read"
TRIED_WITHIN=". Tried within this hook's read budget ($READ_TRIES tries, $READ_DEADLINE seconds)"
read_again(){ mt_retry_read "$READ_TRIES" "$READ_WAIT" "$READ_SLEEP" "$READ_DEADLINE" "" "$1"; }

read_view(){
  if [ "$SECONDS" -gt "$READ_DEADLINE" ]; then
    envelope=$(jq -nc --arg e "$BUDGET_SPENT" '{found: false, wrongRepo: "", notFound: false, error: $e}')
    return 1
  fi
  envelope=$(mt_pr_view "$pr" "number,url,baseRefOid,title,body,commits" "$slug" "$repo_flag")
  mt_view_class "$envelope"
}
read_again read_view; view_rc=$?

if [ "$(printf '%s' "$envelope" | jq -r '.found // false' 2>/dev/null)" != "true" ]; then
  searched="$(mt_searched_repo "$repo_flag" "$local_slug" "$PWD")"
  searched_why="$(mt_searched_why "$repo_flag" "$local_slug" "$PWD")"
  pr_label="$(mt_pr_label "$pr")"
  wrong=$(printf '%s' "$envelope" | jq -r '.wrongRepo // ""' 2>/dev/null)
  [ -n "$wrong" ] && deny "Refusing to merge: the only answer gh gave was about $wrong, not about $slug, and judging one pull request's text while merging another judges neither."
  # NOT FOUND is not "GitHub could not be read" (L11): the remedy is naming the right repository.
  if [ "$(printf '%s' "$envelope" | jq -r '.notFound // false' 2>/dev/null)" = "true" ]; then
    deny "Refusing to merge: no $pr_label was found in $searched under any logged-in account, so there is no text here to judge. It was looked for there because $searched_why. If it lives in another repository, name that repository with --repo owner/name on the merge, or cd into its checkout before the merge."
  fi
  gh_error=$(printf '%s' "$envelope" | jq -r '.error // ""' 2>/dev/null)
  if said="$(mt_unanswered_said "$view_rc" "the $pr_label in $searched" "$gh_error")"; then
    [ "$view_rc" = "$MT_CONNECT_RC" ] && said="$said$TRIED_WITHIN"
    deny "$WHAT: $said."
  fi
  budget=""
  [ "$view_rc" = 2 ] && budget=", and GitHub did not answer within this hook's read budget ($READ_TRIES tries, $READ_DEADLINE seconds)"
  deny "$WHAT: GitHub could not be read for the $pr_label in $searched under any logged-in account (${gh_error:-gh printed nothing})$budget."
fi

view=$(printf '%s' "$envelope" | jq -c '.view')
view_account=$(printf '%s' "$envelope" | jq -r '.account // ""')
number=$(printf '%s' "$view" | jq -r '.number // ""')
base_oid=$(printf '%s' "$view" | jq -r '.baseRefOid // ""')
# The repository the answer is about, from its own URL, since mt_pr_view proved it is the one asked.
api_slug=$(printf '%s' "$view" | jq -r '.url // ""' | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#p')
if [ -z "$number" ] || [ -z "$base_oid" ] || [ -z "$api_slug" ]; then
  deny "$WHAT: GitHub's answer about the pull request named no number, base commit or repository, so whether its repository guards against the names cannot be read."
fi

# The scope: the scanner at the base commit. Only gh's own 404 is "not guarded"; any other failure is
# unknown, and refused (L42).
read_scope(){
  if [ "$SECONDS" -gt "$READ_DEADLINE" ]; then
    MT_READ_STATE="unknown"; MT_READ_ERR="$BUDGET_SPENT"; return 1
  fi
  mt_api_read /dev/null "$view_account" "repos/$api_slug/contents/$SCOPE_PATH?ref=$base_oid"
}
read_again read_scope; scope_rc=$?
scope_what="$SCOPE_PATH at the base commit $base_oid of $api_slug"
case "$scope_rc" in
  0) [ "$MT_READ_STATE" = absent ] && exit 0 ;;   # the commonest answer: a repository that is not guarded
  2) deny "$WHAT: GitHub could not be read for $scope_what ($MT_READ_ERR), and did not answer within this hook's read budget ($READ_TRIES tries, $READ_DEADLINE seconds)." ;;
  "$MT_SIGNIN_RC") deny "$WHAT: $(mt_signin_said "$scope_what" "$MT_READ_ERR")." ;;
  "$MT_CONNECT_RC") deny "$WHAT: $(mt_connect_said "$scope_what" "$MT_READ_ERR")$TRIED_WITHIN." ;;
  *) deny "$WHAT: GitHub could not be read for $scope_what ($MT_READ_ERR)." ;;
esac

# Guarded. What the merge publishes, as the scanner's labelled stream. A missing title, description
# or commit list is an answer that cannot be judged, never an empty one.
shape=$(printf '%s' "$view" | jq -r 'if (.title|type) == "string" and (.body|type) == "string" and (.commits|type) == "array" then "ok" else "bad" end' 2>/dev/null)
[ "$shape" = ok ] || deny "$WHAT: GitHub's answer about the pull request carried no title, description or commit list to read."

command -v python3 >/dev/null 2>&1 || deny "$WHAT: $(ps_detector_absent_why "python3 is not on PATH" "check-work-names-merge.sh reads the text through lib/work-names.py, so with it absent nothing here can tell a clean title from one naming a work organisation." "python3")"
[ -f "$SCANNER" ] || deny "$WHAT: $SCANNER is missing, and it is the rule this gate applies. Restore it with claude-sync pull."

STREAM=$(mktemp "${TMPDIR:-/tmp}/work-names-merge.XXXXXX") \
  || deny "$WHAT: no temporary file could be made for the pull request's text."
trap 'rm -f "$STREAM"' EXIT
printf '%s' "$view" | jq -j '
  "title\u0000" + .title + "\u0000"
  + "description\u0000" + .body + "\u0000"
  + ([.commits[] | "commit " + ((.oid // "") | .[0:7]) + "\u0000"
       + (.messageHeadline // "") + "\n\n" + (.messageBody // "") + "\u0000"] | join(""))' > "$STREAM" 2>/dev/null \
  || deny "$WHAT: the pull request's title, description and commit messages could not be put together for the scanner."

findings=$(python3 "$SCANNER" --texts0-from "$STREAM" 2>&1); scan_rc=$?
case "$scan_rc" in
  0) exit 0 ;;
  1) ;;
  *) deny "$WHAT: lib/work-names.py gave no verdict (exit $scan_rc: $(printf '%s' "$findings" | tail -n 1 | cut -c1-300)). That is the scanner failing, not the text passing." ;;
esac

deny "Refusing to merge PR #${number}: it names a work organisation, and $api_slug guards against that, because the merge publishes the title, the description and every commit message (a squash merge copies each one into main):

$findings

A title or description: gh pr edit ${number} --title <a clean title>, or --body-file <a file without it>, and merge again. A commit message: reword it on the branch (git rebase, or git reset --soft to the commit before it and commit again) and force push from the main session, since the branch is already pushed."
