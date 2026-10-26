#!/usr/bin/env bash
#
# Refuse a pull request merge whose body closes an issue it says stays open (claude-config#1550).
#
# GitHub honours a closing keyword before an issue reference wherever it sits in a pull request
# body, in a sentence saying the opposite included (L1018): "This does not close #4358" closed
# Overture #4358 on merge with three of its four slices unbuilt, and "The next PR ... closes #953"
# closed claude-config#953 a pull request early. check-closing-keyword.sh refuses that sentence as it
# is written, but only where it can see it: a body passed with --body-file, written through the API
# or the web, or edited later never passes through it. This reads the body GitHub actually holds, at
# the one moment the keyword takes effect.
#
# WHAT IS REFUSED. An issue GitHub lists in the pull request's closingIssuesReferences (the issues
# the merge will close, an issue linked by hand in the sidebar included) where the body puts the
# closing keyword in a negated, conditional, "which" or partial sentence, or also calls the change
# "Part of #N", or says #N stays open. The rule is lib/closing-keyword.py's, the one reading
# check-closing-keyword.sh asks too, so a sentence is judged the same written and merged (L263,
# L370). An issue GitHub does not list closes nothing and is not judged.
#
# MEASURED before shipping (L172, L147), over every merged pull request on 2026-10-24: 3 of 633 in
# claude-config and 12 of 1,925 in Overture would have been refused. Of the 15, 9 merges closed an
# issue their body meant to leave open, 4 relinked an issue already closed ("Follows #4036, which
# closed #3769"), and 2 refused a close the body did intend (Overture #2836, a heading ending "not
# fixed" above a paragraph starting "#2784"; Overture #4451, a squashed part's own "Part of #4356"
# kept in the body of the pull request that finished it). Each of those two clears by editing the
# body.
#
# EVERY REPOSITORY, every route to a merge (lib/merge-target.sh), one pull request per command
# (claude-config#1062). Where the body or its closing list cannot be read the merge is refused:
# cannot tell is never "nothing wrong" (L490). Its GitHub read has a budget inside the hook's
# timeout and is asked again while GitHub fails transiently, as the other merge gates do (#1061,
# #1081), and merge-when-ready.sh asks this gate before it merges as it asks every merge gate.
#
# Deliberate override: SKIP_CLOSING_CHECK=1 <the same command>, the one word check-closing-keyword.sh
# takes for the same rule, for a body that has to quote the broken phrasing (visible in the command).
#
# Seams, for the tests: CLOSING_READ_TRIES (3 in all), CLOSING_READ_RETRY_SECONDS (2),
# CLOSING_READ_BUDGET_SECONDS (15, against a hook timeout of 30; MT_GATE_READ_BUDGET_SECONDS, which
# merge-when-ready.sh sets, when it is unset), CLOSING_SLEEP (sleep), all chosen, not measured;
# CLOSING_KEYWORD_LIB (the detector file).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload=$(cat)

# Before every Bash command, so the commonest case leaves here before anything is loaded, by the
# words every merge route names (mt__might_merge in lib/merge-target.sh).
case "$payload" in *merge*|*Merge*|*enqueuePullRequest*) ;; *) exit 0 ;; esac

# shellcheck source=lib/merge-target.sh
. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || exit 0

DETECTOR="${CLOSING_KEYWORD_LIB:-$HOOK_DIR/lib/closing-keyword.py}"
OVERRIDE="Deliberate override, for a body that has to quote the phrasing: SKIP_CLOSING_CHECK=1 <the same command>."

# On stderr with exit 2 rather than through deny(), which builds its JSON with jq, one of the tools
# that can be missing.
refuse_no_reader() {  # $1 = the absence clause, $2 = what it costs, $3 = what to install
  echo "Cannot tell whether this merge closes an issue its body says stays open: $(ps_reader_absent_why "$1" "$2" "$3") $OVERRIDE" >&2
  exit 2
}

if ps_reader_missing jq python3; then
  case "$payload" in
    *SKIP_CLOSING_CHECK=1*) exit 0 ;;
    *)
      refuse_no_reader "neither jq nor python3 is on PATH" \
        "check-closing-merge.sh reads this command out of the hook payload, which is JSON, with one of them, so with neither installed it cannot tell whether this command merges a pull request at all, let alone which one." \
        "jq or python3" ;;
  esac
fi

parsed=$(ps_parse_payload "$payload" raw) || parsed=""
command="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"

mt_runs_merge "$command" || exit 0

# Matched with the shell's own regex, never a producer piped into a quiet grep, which short circuits
# under pipefail (test-pipefail-shortcircuit.sh, L183).
skip_re='(^|[[:space:];&|])SKIP_CLOSING_CHECK=1([[:space:]]|$)'
[[ "$command" =~ $skip_re ]] && exit 0

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
  "check-closing-merge.sh reads GitHub's answer about this pull request with it, so with jq absent nothing here can tell which issues the merge will close." \
  "jq"

command -v gh >/dev/null 2>&1 || deny "Cannot tell whether this merge closes an issue its body says stays open: gh is not on PATH, so GitHub cannot be asked which issues it will close. $OVERRIDE"

# One pull request per command: the body read below is one pull request's.
if span_why="$(mt_merge_span_why "$command" "$cwd")"; then
  deny "Cannot judge which issues this merge closes: $span_why $OVERRIDE"
fi

# A merge through the GitHub API whose pull request cannot be named (#1181).
if mt_api_merge_untold "$command"; then
  deny "Cannot judge which issues this merge closes: $MT_API_WHY $OVERRIDE"
fi

if mt_is_pr_merge "$command" && mt_reader_missing; then
  deny "Cannot tell whether this merge closes an issue its body says stays open: $(mt_reader_absent_why) $OVERRIDE"
fi

repo_flag="$(mt_repo_flag "$command")"
cd "$(mt_repo_dir "$command" "$cwd")" 2>/dev/null || true
local_slug=$(mt_remote_slug)
slug="${repo_flag:-$local_slug}"
pr=$(mt_pr_number "$command")

# The read is asked again while GitHub fails transiently, inside a budget measured from the start of
# this hook in the shell's own SECONDS, through mt_retry_read, the one retry loop the merge gates use.
# A refused sign in, or a network to GitHub that failed on every try, refuses in its own words
# (mt_unanswered_said), never as GitHub being unreadable (claude-config#1615, #1728, L11).
ck_num(){ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
READ_TRIES="$(ck_num "${CLOSING_READ_TRIES:-}" 3)"
READ_WAIT="$(ck_num "${CLOSING_READ_RETRY_SECONDS:-}" 2)"
READ_DEADLINE="$(mt_gate_read_budget "${CLOSING_READ_BUDGET_SECONDS:-}" 15)"
READ_SLEEP="${CLOSING_SLEEP:-sleep}"
BUDGET_SPENT="this hook's read budget of $READ_DEADLINE seconds was spent before it could be read"

read_view(){
  if [ "$SECONDS" -gt "$READ_DEADLINE" ]; then
    envelope=$(jq -nc --arg e "$BUDGET_SPENT" '{found: false, wrongRepo: "", notFound: false, error: $e}')
    return 1
  fi
  envelope=$(mt_pr_view "$pr" "number,url,body,closingIssuesReferences" "$slug" "$repo_flag")
  mt_view_class "$envelope"
}
mt_retry_read "$READ_TRIES" "$READ_WAIT" "$READ_SLEEP" "$READ_DEADLINE" "" read_view; view_rc=$?

if [ "$(printf '%s' "$envelope" | jq -r '.found // false' 2>/dev/null)" != "true" ]; then
  searched="$(mt_searched_repo "$repo_flag" "$local_slug" "$PWD")"
  searched_why="$(mt_searched_why "$repo_flag" "$local_slug" "$PWD")"
  pr_label="$(mt_pr_label "$pr")"
  wrong=$(printf '%s' "$envelope" | jq -r '.wrongRepo // ""' 2>/dev/null)
  [ -n "$wrong" ] && deny "Refusing to merge: the only answer gh gave was about $wrong, not about $slug, and judging one pull request's body while merging another judges neither. $OVERRIDE"
  # NOT FOUND is not "GitHub could not be read" (L11): the remedy is naming the right repository.
  if [ "$(printf '%s' "$envelope" | jq -r '.notFound // false' 2>/dev/null)" = "true" ]; then
    deny "Refusing to merge: no $pr_label was found in $searched under any logged-in account, so there is no body here to judge. It was looked for there because $searched_why. If it lives in another repository, name that repository with --repo owner/name on the merge, or cd into its checkout before the merge."
  fi
  gh_error=$(printf '%s' "$envelope" | jq -r '.error // ""' 2>/dev/null)
  if said="$(mt_unanswered_said "$view_rc" "the $pr_label in $searched" "$gh_error")"; then
    [ "$view_rc" = "$MT_CONNECT_RC" ] && said="$said. Tried within this hook's read budget ($READ_TRIES tries, $READ_DEADLINE seconds)"
    deny "Cannot tell whether this merge closes an issue its body says stays open: $said. $OVERRIDE"
  fi
  budget=""
  [ "$view_rc" = 2 ] && budget=", and GitHub did not answer within this hook's read budget ($READ_TRIES tries, $READ_DEADLINE seconds)"
  deny "Cannot tell whether this merge closes an issue its body says stays open: GitHub could not be read for the $pr_label in $searched under any logged-in account (${gh_error:-gh printed nothing})$budget. $OVERRIDE"
fi

view=$(printf '%s' "$envelope" | jq -c '.view')
number=$(printf '%s' "$view" | jq -r '.number // ""')
# The repository the answer is about, from its own URL, since mt_pr_view proved it is the one asked.
api_slug=$(printf '%s' "$view" | jq -r '.url // ""' | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#p')
closing_count=$(printf '%s' "$view" | jq -r 'if (.closingIssuesReferences | type) == "array" then (.closingIssuesReferences | length) else "unread" end' 2>/dev/null)
case "$closing_count" in
  ''|unread) deny "Cannot tell whether this merge closes an issue its body says stays open: GitHub's answer about the pull request carried no list of the issues it closes. $OVERRIDE" ;;
  0) exit 0 ;;   # the merge closes nothing, so nothing it says can be contradicted
esac
[ -n "$api_slug" ] || deny "Cannot tell whether this merge closes an issue its body says stays open: GitHub's answer about the pull request named no repository, so a bare #N in its body cannot be read as an issue. $OVERRIDE"

# The detector needs python3, asked only now that the merge is known to close something, so a
# machine without it loses nothing on the merges that close nothing (L54).
command -v python3 >/dev/null 2>&1 || deny "Cannot tell whether this merge closes an issue its body says stays open: $(ps_detector_absent_why "python3 is not on PATH" "check-closing-merge.sh reads the body through lib/closing-keyword.py, so with it absent nothing here can tell a sentence that closes an issue from one that says it stays open." "python3") $OVERRIDE"
[ -f "$DETECTOR" ] || deny "Cannot tell whether this merge closes an issue its body says stays open: $DETECTOR is missing, and it is the rule this gate applies. Restore it with claude-sync pull. $OVERRIDE"

# Its stderr is kept apart, so a warning Python prints on the way is never read as a finding.
DET_ERR=$(mktemp "${TMPDIR:-/tmp}/closing-merge-det.XXXXXX") || DET_ERR=/dev/null
findings=$(printf '%s' "$view" | python3 "$DETECTOR" pr "$api_slug" 2>"$DET_ERR"); det_rc=$?
det_why=$(awk 'NF { last = $0 } END { print last }' "$DET_ERR" 2>/dev/null | cut -c1-300)
[ "$DET_ERR" = /dev/null ] || rm -f "$DET_ERR"
[ "$det_rc" -eq 0 ] || deny "Cannot tell whether this merge closes an issue its body says stays open: lib/closing-keyword.py gave no verdict (exit $det_rc${det_why:+: $det_why}). That is the detector failing, not the body passing. $OVERRIDE"
[ -n "$findings" ] || exit 0

deny "Refusing to merge PR #${number:-$pr}: GitHub will close every issue its body puts a closing word in front of, whatever the sentence around it says (L1018), and this body says otherwise about:

$findings

If this pull request does NOT finish the issue, write \"Part of #N\" or \"Refs #N\" wherever a closing word sits in front of it, with gh pr edit ${number:-$pr} --body-file <file>, and merge again. If it DOES finish it, take out the sentence saying it does not. An issue linked by hand in the pull request's sidebar is closed the same way, so unlink it there if it should stay open. $OVERRIDE"
