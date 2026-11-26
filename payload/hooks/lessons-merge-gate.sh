#!/usr/bin/env bash
#
# Refuse a pull request merge that changes lesson entries in payload/LESSONS.md until Dan has
# answered the lesson picker's merge form for exactly that change (claude-config#3343, route 3).
#
# An entry added to ~/.claude/LESSONS.md by an Edit goes to the lesson picker, where Dan reads its
# rule and its SHORT line (#3320, #3347). A pull request that edits a checkout's payload/LESSONS.md
# reached the same file on both Macs through the next pull with nothing shown to him. Dan,
# 2026-11-20, by picker: "Guard the merge (Recommended)". A pull request that adds or changes an
# entry there, other than by the sync's send, cannot merge until he has answered the lesson picker
# for it, and a sweep over many entries gets one question naming the count and the change.
#
# THE RULE is lib/lesson-merge.py's: what counts as an entry and as a change to one, the sha256 that
# ties his answer to the change, what the question must have shown him, and where his answer is
# read and kept. This file finds the merge, reads GitHub, and refuses whenever it cannot tell.
#
# WHAT IS COMPARED. The file at the merge base of the pull request's base and head against the file
# at its head: what the pull request itself does, never what the sync sent to main meanwhile.
#
# THE SYNC'S OWN SEND is a push to the branch (claude-sync commits "sync from <host>" and pushes),
# never a pull request, so it never meets this gate. Nothing inside a pull request marks it as the
# sync's, since anything there could be written by anybody: one whose branch carries a commit named
# like a send is asked about like any other.
#
# SCOPE. Any pull request whose change reaches payload/LESSONS.md, in any repository (only this one
# holds that path). One that does not leaves after one read, the pull request itself, by its file
# list. A list that cannot say (cut short, or holding a rename or a change type this cannot read)
# has the file itself read at both commits instead.
#
# EVERY ROUTE a session has to a merge (lib/merge-target.sh), one pull request per command.
# merge-when-ready.sh asks this gate itself, before any wait and again at the pinned merge, with no
# transcript, so his answer is also kept on a record (lib/lesson-merge.py), and this gate keeps what
# the session's transcript holds when the session starts that helper. A merge made on GitHub's own
# page, in its app, or by gh in a terminal Dan types in never meets this gate or any other.
#
# NO OVERRIDE. The remedy is always open: Dan's answer.
#
# THE WAYS ROUND IT (claude-config#3583). It is also registered for Edit, Write, MultiEdit and
# NotebookEdit, where it does one thing: refuse a write of a file in the record's folder
# (lm_write_tool_judged). A file list naming the lessons file under another spelling is refused
# (ANOTHER SPELLING OF THE LESSONS FILE, below). And the rule believes no line of the record on its
# own word, and shows every rule and SHORT line whenever the shared picker check says they fit.
#
# Where the pull request, the file or the verdict cannot be read the merge is refused: cannot tell
# is never "nothing changed" (L490). Its GitHub reads are asked again while GitHub fails
# transiently, inside a budget, as the other merge gates' are (#1061, #1081).
#
# Seams, each honoured only with HOOK_TESTS_RUNNING=1 (claude-config#2231, #2317), since this hook
# reads Claude Code's own environment: LM_MERGE_RECORD_DIR (the record's folder), LM_MERGE_RULE (the
# rule's file), LM_MERGE_MAX_BYTES (the largest lessons file read, 20,000,000), LM_MERGE_SLEEP (the
# wait between reads), LM_MERGE_READ_TRIES (3). LM_MERGE_READ_BUDGET_SECONDS, or
# MT_GATE_READ_BUDGET_SECONDS, which merge-when-ready.sh sets, is the read budget, clamped to 25
# against a hook timeout of 45: settings, not measurements.

set -uo pipefail

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
payload=$(cat)

# Before every Bash command, so the commonest case leaves here before anything is loaded, by the
# words every merge route names (mt__might_merge in lib/merge-target.sh). The merge helper's name
# and the record's folder both hold the word.
# The word in any case (claude-config#3583): on a Mac's file system the record's folder spelled in
# capitals is the same folder, and a payload naming it that way left here unread. A call of a tool
# that writes a file names the file it writes, and goes on to be asked where that file lands.
shopt -s nocasematch
case "$payload" in *merge*|*enqueuePullRequest*|*'"file_path"'*|*'"notebook_path"'*) ;; *) exit 0 ;; esac
shopt -u nocasematch

WHAT="Cannot tell whether this merge changes a lesson entry Dan has not approved"
LESSONS_PATH="payload/LESSONS.md"
RULE="$HOOK_DIR/lib/lesson-merge.py"
RECORD_DIR="${CLAUDE_HOME:-$HOME/.claude}/state/lesson-merges"
MAX_BYTES=20000000
READ_TRIES=3
READ_SLEEP=sleep
if [ "${HOOK_TESTS_RUNNING:-}" = 1 ]; then
  [ -n "${LM_MERGE_RULE:-}" ] && RULE="$LM_MERGE_RULE"
  [ -n "${LM_MERGE_RECORD_DIR:-}" ] && RECORD_DIR="$LM_MERGE_RECORD_DIR"
  [ -n "${LM_MERGE_SLEEP:-}" ] && READ_SLEEP="$LM_MERGE_SLEEP"
  case "${LM_MERGE_MAX_BYTES:-}" in ''|*[!0-9]*) ;; *) MAX_BYTES="$LM_MERGE_MAX_BYTES" ;; esac
  case "${LM_MERGE_READ_TRIES:-}" in ''|*[!0-9]*) ;; *) READ_TRIES="$LM_MERGE_READ_TRIES" ;; esac
fi

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

# THE RECORD OF HIS ANSWERS IS THIS GATE'S TO WRITE (claude-config#3583). An Edit, Write, MultiEdit
# or NotebookEdit of a file in its folder is refused: by where the path lands on disk once .., a
# doubled slash, another case, a linked folder and a linked file are followed. A line put there any
# other way is never believed (lib/lesson-merge.py, A LINE ON THE RECORD IS A POINTER), so this is
# a tripwire that says so at the write, not the thing that keeps a forged line from counting.
#
# Returns 0 having judged the call (it exits when it refuses), 1 when the payload is not such a
# call or could not be read as one; a call it returns 1 for goes on to be read as a command.
lm_write_tool_judged() {  # $1 = the payload
  local row tool target folder ran lands
  command -v jq >/dev/null 2>&1 || return 1
  row="$(printf '%s' "$1" | jq -r '[(.tool_name // "" | strings), ((.tool_input.file_path // .tool_input.notebook_path // "") | strings), (.cwd // "" | strings), ((.tool_input.command // "") | tostring | length | tostring)] | join("\u001f")' 2>/dev/null)" || return 1
  tool="${row%%$'\x1f'*}"; row="${row#*$'\x1f'}"
  target="${row%%$'\x1f'*}"; row="${row#*$'\x1f'}"
  folder="${row%%$'\x1f'*}"; ran="${row#*$'\x1f'}"
  case "$tool" in Edit|Write|MultiEdit|NotebookEdit) ;; *) return 1 ;; esac
  # One that also carries a command is read as a command, never passed here.
  [ "$ran" = 0 ] || return 1
  [ -n "$target" ] || return 0
  lands=""
  if command -v python3 >/dev/null 2>&1; then
    lands="$(python3 -c '
import os, sys
target, folder, record = sys.argv[1:4]
real = lambda p: os.path.realpath(p).lower()
t, r = real(os.path.join(folder or "/", target)), real(record)
print("inside" if t == r or t.startswith(r.rstrip("/") + "/") else "outside")' "$target" "$folder" "$RECORD_DIR" 2>/dev/null)"
  fi
  case "$lands" in
    outside) return 0 ;;
    inside) deny "Refusing: this $tool writes $target, which is in $RECORD_DIR, the record of Dan's answers about lesson entries in a pull request (claude-config#3343, #3583). Only lessons-merge-gate.sh writes it, from his own answer in the picker a refused merge names. A line put there any other way would be an approval he never gave, and it would count for nothing: a line is believed only when the session transcript it names holds that answer. To see the record, read it with the Read tool." ;;
  esac
  # Where it lands could not be followed: a path that names the folder's own word is held.
  shopt -s nocasematch
  case "$target" in
    *lesson-merges*) shopt -u nocasematch
      deny "Refusing: this $tool writes $target, and whether that is in $RECORD_DIR, the record of Dan's answers about lesson entries in a pull request, could not be followed on disk (python3 follows it, and is not on PATH or failed). Only lessons-merge-gate.sh writes that record, and a line put there any other way would be an approval he never gave (claude-config#3583)." ;;
  esac
  shopt -u nocasematch
  return 0
}
# Before anything is loaded: every Edit and Write passes through here. Whatever is left is read as a
# command, and leaves at once unless it holds a word a merge route or the record's folder names.
case "$payload" in *'"file_path"'*|*'"notebook_path"'*) lm_write_tool_judged "$payload" && exit 0 ;; esac
shopt -s nocasematch
case "$payload" in *merge*|*enqueuePullRequest*) ;; *) exit 0 ;; esac
shopt -u nocasematch

# shellcheck source=lib/merge-target.sh
{ . "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null && declare -F mt_runs_merge >/dev/null; } || {
  # A library this gate cannot load is not a merge with nothing to check (claude-config#1900, L10).
  echo "$WHAT: lessons-merge-gate.sh could not load $HOOK_DIR/lib/merge-target.sh, or lib/push-scope.sh beneath it, which reads whether this command merges a pull request and which one, so the lesson entries it changes could not be checked. A library this gate cannot load is not a merge with nothing to check. Reinstall the hooks with claude-sync pull." >&2
  exit 2
}

# On stderr with exit 2 rather than through deny(), which builds its JSON with jq, one of the tools
# that can be missing.
refuse_no_reader() {  # $1 = the absence clause, $2 = what it costs, $3 = what to install
  echo "$WHAT: $(ps_reader_absent_why "$1" "$2" "$3")" >&2
  exit 2
}

if ps_reader_missing jq python3; then
  refuse_no_reader "neither jq nor python3 is on PATH" \
    "lessons-merge-gate.sh reads this command out of the hook payload, which is JSON, with one of them, so with neither installed it cannot tell whether this command merges a pull request at all, let alone which one." \
    "jq or python3"
fi

# Cleaned before anything parses it (claude-config#1944). A payload still unreadable is judged by
# its words (#1922).
payload="$(ps_clean_payload "$payload")"
parsed=$(ps_parse_payload "$payload" raw) \
  || ps_unparsed_refuse "$payload" lessons-merge-gate.sh - "a merge of a pull request" '*merge*' '*Merge*' '*enqueuePullRequest*'
command="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"

# Who is asking, for his answer: the session's transcript, and whether the call is a subagent's.
# Read with jq when it is here; without it they stay empty, and a merge is refused for jq below.
session_id=""; transcript=""; agent_id=""
if command -v jq >/dev/null 2>&1; then
  session_id="$(printf '%s' "$payload" | jq -r '.session_id // "" | strings' 2>/dev/null)"
  transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // "" | strings' 2>/dev/null)"
  agent_id="$(printf '%s' "$payload" | jq -r '.agent_id // "" | strings' 2>/dev/null)"
fi

# The record of his answers is this gate's to write. A line put there any other way is never
# believed (lib/lesson-merge.py, A LINE ON THE RECORD IS A POINTER), so what follows is a tripwire
# that says so at the write, not the thing that keeps a forged line from counting.
#
# A shell command naming the folder, in any case and with a doubled slash or a dot between its two
# names, which on a Mac's file system are all the same folder (claude-config#3583).
named="$command"
while :; do case "$named" in *//*) named="${named//\/\///}" ;; */./*) named="${named//\/.\///}" ;; *) break ;; esac; done
shopt -s nocasematch
case "$named" in *"state/lesson-merges"*) named=yes ;; *) named="" ;; esac
shopt -u nocasematch
if [ -n "$named" ]; then
  command -v jq >/dev/null 2>&1 || { echo "Refusing: this command names the record of Dan's answers about lesson entries in a pull request, which is written only by lessons-merge-gate.sh." >&2; exit 2; }
  deny "Refusing: this command names $RECORD_DIR, the record of Dan's answers about lesson entries in a pull request (claude-config#3343). It is written only by lessons-merge-gate.sh, from his own answer in the picker a refused merge names, and a line put there any other way would be an approval he never gave. To see it, read the file with the Read tool."
fi

# A call of a tool that writes a file, whose payload had to be cleaned before it could be read
# (lm_write_tool_judged, above, reads the rest before anything is loaded). It runs no command, so
# one that does not write to the record leaves here.
if [ -z "$command" ]; then
  lm_write_tool_judged "$payload" && exit 0
  # No jq to say which tool this is: a payload that runs no command and names the folder is held.
  if ! command -v jq >/dev/null 2>&1; then
    shopt -s nocasematch
    case "$payload" in *lesson-merges*) echo "Refusing: this call names the record of Dan's answers about lesson entries in a pull request, and without jq on PATH lessons-merge-gate.sh cannot read whether it writes there. Only that gate writes the record (claude-config#3583). Install jq." >&2; exit 2 ;; esac
    shopt -u nocasematch
  fi
fi

# The merge helper being started (claude-config#3343). It merges inside itself and asks this gate
# with no transcript, so whatever answers this session's transcript holds are put on the record
# now. Nothing is decided here: the helper asks before any wait and again at the merge.
case "$command" in
  *merge-when-ready*)
    if [ -z "$agent_id" ] && [ -n "$transcript" ] && [ -n "$session_id" ] && command -v python3 >/dev/null 2>&1 \
       && printf '%s' "$command" | python3 "$HOOK_DIR/lib/agent-overrides.py" runs-script merge-when-ready.sh >/dev/null 2>&1; then
      kept="$(python3 "$RULE" harvest --record-dir "$RECORD_DIR" --transcript "$transcript" --session "$session_id" 2>&1)"; kept_rc=$?
      if [ "$kept_rc" = 3 ] && command -v jq >/dev/null 2>&1; then
        deny "Refusing to start the merge helper: Dan's answer about the lesson entries in a pull request could not be kept on this Mac's record ($kept), and the helper reads his answer from that record alone, so it would stop on a merge he approved. Make that folder writable, or send the merge as a typed gh pr merge from this session, which reads his answer here."
      fi
    fi ;;
esac

mt_runs_merge "$command" || exit 0

# Asleep, Dan is not asked: the refusal says the merge waits (lib/sleep.sh, the one reader of the
# night's record). Loaded here, before anything is read from GitHub, and refused on stderr with exit
# 2 as a library that cannot be loaded is above: loaded where it was first used, after the reads, a
# missing one was only reached by a merge GitHub answered for, and any other was refused in other
# words that named no library (test-gates-fail-closed.sh, found for claude-config#3583).
# shellcheck source=lib/sleep.sh
{ . "$HOOK_DIR/lib/sleep.sh" 2>/dev/null && declare -F sleep_active >/dev/null; } || {
  echo "$WHAT: lessons-merge-gate.sh could not load $HOOK_DIR/lib/sleep.sh, which says whether Dan is asleep, and what a refused merge is told to do depends on it. A library this gate cannot load is not a merge with nothing to check. Reinstall the hooks with claude-sync pull." >&2
  exit 2
}

ps_reader_missing jq && refuse_no_reader "jq is not on PATH" \
  "lessons-merge-gate.sh reads GitHub's answer about this pull request with it, so with jq absent nothing here can read which files it changes." \
  "jq"

command -v gh >/dev/null 2>&1 || deny "$WHAT: gh is not on PATH, so GitHub cannot be asked which files the pull request changes."

# One pull request per command: the change read below is one pull request's.
if span_why="$(mt_merge_span_why "$command" "$cwd")"; then
  deny "Cannot judge whether this merge changes a lesson entry: $span_why"
fi

# A merge through the GitHub API whose pull request cannot be named (#1181).
if mt_api_merge_untold "$command"; then
  deny "Cannot judge whether this merge changes a lesson entry: $MT_API_WHY"
fi

if mt_is_pr_merge "$command" && mt_reader_missing; then
  deny "$WHAT: $(mt_reader_absent_why)"
fi

repo_flag="$(mt_repo_flag "$command")"
cd "$(mt_repo_dir "$command" "$cwd")" 2>/dev/null || true
local_slug=$(mt_remote_slug)
slug="${repo_flag:-$local_slug}"
pr=$(mt_pr_number "$command")
mt_merge_pin "$command"

# The reads are asked again while GitHub fails transiently, inside a budget measured from the start
# of this hook in the shell's own SECONDS, through mt_retry_read, the one retry loop the merge gates
# use. The budget is clamped whichever setting named it, as check-work-names-merge.sh clamps its own
# and for its reasons (claude-config#2217): a hook killed at its timeout gives no verdict at all.
READ_WAIT=2
READ_BUDGET_CAP=25
READ_DEADLINE="$(mt_gate_read_budget "${LM_MERGE_READ_BUDGET_SECONDS:-}" "$READ_BUDGET_CAP")"
if _lm_got="$(whole_above_zero "$READ_DEADLINE")"; then READ_DEADLINE="$_lm_got"
  case "$READ_DEADLINE" in ???*) READ_DEADLINE="$READ_BUDGET_CAP" ;; esac
  [ "$READ_DEADLINE" -le "$READ_BUDGET_CAP" ] || READ_DEADLINE="$READ_BUDGET_CAP"
else
  READ_DEADLINE=0
fi
BUDGET_SPENT="this hook's read budget of $READ_DEADLINE seconds was spent before it could be read"
TRIED_WITHIN=". Tried within this hook's read budget ($READ_TRIES tries, $READ_DEADLINE seconds)"
read_again(){ mt_retry_read "$READ_TRIES" "$READ_WAIT" "$READ_SLEEP" "$READ_DEADLINE" "" "$1"; }

read_view(){
  if [ "$SECONDS" -gt "$READ_DEADLINE" ]; then
    envelope=$(jq -nc --arg e "$BUDGET_SPENT" '{found: false, wrongRepo: "", notFound: false, error: $e}')
    return 1
  fi
  envelope=$(mt_pr_view "$pr" "number,url,baseRefOid,headRefOid,changedFiles,files" "$slug" "$repo_flag")
  mt_view_class "$envelope"
}
read_again read_view; view_rc=$?

if [ "$(printf '%s' "$envelope" | jq -r '.found // false' 2>/dev/null)" != "true" ]; then
  searched="$(mt_searched_repo "$repo_flag" "$local_slug" "$PWD")"
  searched_why="$(mt_searched_why "$repo_flag" "$local_slug" "$PWD")"
  pr_label="$(mt_pr_label "$pr")"
  wrong=$(printf '%s' "$envelope" | jq -r '.wrongRepo // ""' 2>/dev/null)
  [ -n "$wrong" ] && deny "Refusing to merge: the only answer gh gave was about $wrong, not about $slug, and judging one pull request's lesson entries while merging another judges neither."
  # NOT FOUND is not "GitHub could not be read" (L11): the remedy is naming the right repository.
  if [ "$(printf '%s' "$envelope" | jq -r '.notFound // false' 2>/dev/null)" = "true" ]; then
    deny "Refusing to merge: no $pr_label was found in $searched under any logged-in account, so there is no change here to judge. It was looked for there because $searched_why. If it lives in another repository, name that repository with --repo owner/name on the merge, or cd into its checkout before the merge."
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
head_oid=$(printf '%s' "$view" | jq -r '.headRefOid // ""')
# The repository the answer is about, from its own URL, since mt_pr_view proved it is the one asked.
api_slug=$(printf '%s' "$view" | jq -r '.url // ""' | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#p')
case "$number" in ''|*[!0-9]*) number="" ;; esac
case "$base_oid" in *[!0-9a-f]*) base_oid="" ;; esac
case "$head_oid" in *[!0-9a-f]*) head_oid="" ;; esac
if [ -z "$number" ] || [ -z "$base_oid" ] || [ -z "$head_oid" ] || [ -z "$api_slug" ]; then
  deny "$WHAT: GitHub's answer about the pull request named no number, base commit, head commit or repository, so what it changes cannot be read."
fi

# ANOTHER SPELLING OF THE LESSONS FILE (claude-config#3583). GitHub keeps payload/lessons.md and
# payload/LESSONS.md as two files; a Mac's file system keeps one, so after the next pull the text
# every session loads could be the other file's, which the read of payload/LESSONS.md below never
# sees. So a path in the file list that is the lessons file by any spelling that reaches it on a
# Mac, and is not that exact path, is refused, and no picker covers it: another case in either
# name, a "./", a doubled or leading slash, a ".." (none of which GitHub lists, so one that arrives
# is never read as untouched), characters outside ASCII dropped (a file system that ignores some),
# and the folder itself listed as a file, which is what a link put in the folder's place is.
odd_path=$(printf '%s' "$view" | jq -r --arg p "$LESSONS_PATH" '
  def folded: ascii_downcase | gsub("[^\\x00-\\x7f]"; "") | gsub("/\\.(?=/)"; "") | gsub("/+"; "/") | sub("^(\\./)+"; "") | sub("^/"; "");
  ($p | ascii_downcase) as $lp | ($lp | split("/")) as $parts | ($parts[:-1] | join("/")) as $dir
  | [ (if (.files | type) == "array" then .files[] else empty end) | (.path // "" | tostring) | select(. != $p)
      | (folded) as $f
      | if $f == $lp or (test("(^|/)\\.\\.(/|$)") and ($f | endswith($parts | last))) then "file\t\(.)"
        elif $f == $dir then "folder\t\(.)" else empty end ] | first // ""' 2>/dev/null) \
  || deny "$WHAT: the file list of PR #$number could not be read for another spelling of $LESSONS_PATH, so whether it changes the lessons file under another name is unknown."
case "$odd_path" in
  file$'\t'*)
    deny "Refusing to merge PR #$number: its file list names ${odd_path#*$'\t'}, another spelling of $LESSONS_PATH (claude-config#3583). GitHub keeps the two as separate files and a Mac's file system keeps one, so after the next pull the text every session loads could be that file's, and nothing here can show Dan which. No picker covers it: remove or rename that file on the branch, or leave the merge to Dan." ;;
  folder$'\t'*)
    deny "Refusing to merge PR #$number: its file list names ${odd_path#*$'\t'}, the folder $LESSONS_PATH is in, as a file itself (claude-config#3583). A file or a link put in that folder's place decides what is read as the lessons file on a Mac, and nothing here can show Dan which text that is. No picker covers it: undo that on the branch, or leave the merge to Dan." ;;
esac

# The entries judged are those at the commit that would merge. A merge pinned to a whole commit
# merges that commit or nothing (GitHub refuses one whose head is not it), so that commit is judged,
# whatever head GitHub's view shows: the view can show a pushed head late, and merge-when-ready.sh
# pins the head it read itself, so refusing every difference would stop the helper on a stale view.
# The view's file list is about its own head, so with a pinned commit that is not it the list cannot
# say the file is untouched. A shortened pin that does not start the head names a commit this gate
# cannot read by that name, so it refuses.
judged_oid="$head_oid"; judged_words="the head"
if [ -n "${MT_PIN_SHA:-}" ]; then
  pin="$(printf '%s' "$MT_PIN_SHA" | tr 'A-F' 'a-f')"
  case "$head_oid" in
    "$pin"*) ;;
    *)
      [ "${#pin}" = 40 ] || deny "Refusing to merge PR #$number: the merge is pinned to $pin, which is shortened and does not start the pull request's head on GitHub ($head_oid), so the commit that would merge cannot be read to judge its lesson entries. Pin the whole commit, or the head GitHub shows."
      judged_oid="$pin"; judged_words="the pinned commit" ;;
  esac
fi

# Does its change reach the lessons file? By its own file list, where the list can say. `maybe` is
# a list that cannot: cut short (gh reads one page of it), holding a renamed or copied file (a file
# renamed away is listed under its new name only), or a change type this does not know.
touch=$(printf '%s' "$view" | jq -r --arg p "$LESSONS_PATH" '
  if (.files | type) != "array" or (.changedFiles | type) != "number" then "maybe"
  elif any(.files[]; .path == $p) then "yes"
  elif .changedFiles > (.files | length) then "maybe"
  elif all(.files[]; (.changeType // "") as $t | ["MODIFIED", "ADDED", "DELETED", "CHANGED"] | index($t)) then "no"
  else "maybe" end' 2>/dev/null)
[ "$judged_oid" = "$head_oid" ] || touch=maybe
[ "$touch" = no ] && exit 0   # the commonest answer: one read, and nothing asked

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/lessons-gate.XXXXXX") \
  || deny "$WHAT: no temporary folder could be made for the lessons file."
trap 'rm -rf "$SCRATCH"' EXIT

# One read through mt_api_read, inside the budget; refuses in the read's own words when it fails.
api_out=""; api_args=()
read_api(){
  if [ "$SECONDS" -gt "$READ_DEADLINE" ]; then
    MT_READ_STATE="unknown"; MT_READ_ERR="$BUDGET_SPENT"; return 1
  fi
  mt_api_read "$api_out" "$view_account" "${api_args[@]}"
}
must_read(){  # $1 = what is being read, in words ; the answer lands in $api_out
  local rc
  read_again read_api; rc=$?
  case "$rc" in
    0) return 0 ;;
    2) deny "$WHAT: GitHub could not be read for $1 ($MT_READ_ERR), and did not answer within this hook's read budget ($READ_TRIES tries, $READ_DEADLINE seconds)." ;;
    "$MT_SIGNIN_RC") deny "$WHAT: $(mt_signin_said "$1" "$MT_READ_ERR")." ;;
    "$MT_CONNECT_RC") deny "$WHAT: $(mt_connect_said "$1" "$MT_READ_ERR")$TRIED_WITHIN." ;;
    *) deny "$WHAT: GitHub could not be read for $1 ($MT_READ_ERR)." ;;
  esac
}

# The merge base: what the pull request changes is measured from where its branch left the base.
api_out="$SCRATCH/mergebase"; api_args=(--jq '.merge_base_commit.sha // ""' "repos/$api_slug/compare/$base_oid...$judged_oid")
must_read "the merge base of PR #$number in $api_slug"
merge_base="$(tr -d '[:space:]' < "$SCRATCH/mergebase" 2>/dev/null)"
case "$merge_base" in *[!0-9a-f]*) merge_base="" ;; esac
if [ "$MT_READ_STATE" != ok ] || [ "${#merge_base}" != 40 ]; then
  deny "$WHAT: GitHub's comparison of $base_oid and $judged_oid in $api_slug named no merge base (${MT_READ_ERR:-it answered without one}), so what PR #$number changes in $LESSONS_PATH cannot be measured."
fi

# A file list that cannot say which files change (cut short, holding a rename, or about another
# commit than the pinned one) cannot say either whether the lessons file changes under another
# spelling (ANOTHER SPELLING OF THE LESSONS FILE, above). So every file GitHub holds is read at
# both commits, two reads more, and the other spellings of the path compared by name and sha. A
# spelling the pull request leaves as it was is not its change. A tree GitHub cuts short, which its
# answer says of itself, cannot say, and is refused.
if [ "$touch" = maybe ]; then
  lessons_lower="$(printf '%s' "$LESSONS_PATH" | tr 'A-Z' 'a-z')"
  # shellcheck disable=SC2016
  SPELL_FILTER='def folded: ascii_downcase | gsub("[^\\x00-\\x7f]"; "") | gsub("/+"; "/") | sub("^/"; "");
    if .truncated == true or (.tree | type) != "array" then "cut short"
    else [ .tree[] | select(.type != "tree") | (.path // "" | tostring) as $path | select($path != "'"$LESSONS_PATH"'")
           | ($path | folded) as $f
           | if $f == "'"$lessons_lower"'" then "file\t\($path)\t\(.sha // "")" elif $f == "'"${lessons_lower%/*}"'" then "folder\t\($path)\t\(.sha // "")" else empty end ]
         | sort | join("\n") end'
  spellings_at(){  # $1 = commit, $2 = where to put them, $3 = in words
    api_out="$2"; api_args=(--jq "$SPELL_FILTER" "repos/$api_slug/git/trees/$1?recursive=1")
    must_read "the files of $api_slug at $3 $1"
    [ "$MT_READ_STATE" = ok ] || deny "$WHAT: GitHub listed no files for $3 $1 of $api_slug (${MT_READ_ERR:-it answered without them}), so whether PR #$number changes $LESSONS_PATH under another spelling is unknown."
    if [ "$(head -n 1 "$2" 2>/dev/null)" = "cut short" ]; then
      deny "$WHAT: $api_slug at $3 $1 holds more files than GitHub lists in one answer, and the file list of PR #$number cannot say which it changes, so whether it changes $LESSONS_PATH under another spelling is unknown. That is this gate's limit, not a verdict on the pull request."
    fi
  }
  spellings_at "$merge_base" "$SCRATCH/spell-base" "the merge base"
  spellings_at "$judged_oid" "$SCRATCH/spell-head" "$judged_words"
  if ! cmp -s "$SCRATCH/spell-base" "$SCRATCH/spell-head"; then
    # Written to a file and its first line read from there: a pipe into head would leave comm
    # writing into a closed pipe on a long list, which pipefail reports as a failure
    # (test-pipefail-shortcircuit.sh).
    LC_ALL=C comm -13 "$SCRATCH/spell-base" "$SCRATCH/spell-head" > "$SCRATCH/spell-odd" 2>/dev/null
    odd_path="$(head -n 1 "$SCRATCH/spell-odd" 2>/dev/null)"
    if [ -z "$odd_path" ]; then
      LC_ALL=C comm -23 "$SCRATCH/spell-base" "$SCRATCH/spell-head" > "$SCRATCH/spell-odd" 2>/dev/null
      odd_path="$(head -n 1 "$SCRATCH/spell-odd" 2>/dev/null)"
    fi
    odd_kind="${odd_path%%$'\t'*}"; odd_path="${odd_path#*$'\t'}"; odd_path="${odd_path%$'\t'*}"
    if [ "$odd_kind" = folder ]; then
      deny "Refusing to merge PR #$number: between the merge base and $judged_words it changes $odd_path, the folder $LESSONS_PATH is in, as a file itself (claude-config#3583). A file or a link put in that folder's place decides what is read as the lessons file on a Mac, and nothing here can show Dan which text that is. No picker covers it: undo that on the branch, or leave the merge to Dan."
    fi
    deny "Refusing to merge PR #$number: between the merge base and $judged_words it adds, changes or removes ${odd_path:-a file}, another spelling of $LESSONS_PATH (claude-config#3583). GitHub keeps the two as separate files and a Mac's file system keeps one, so after the next pull the text every session loads could be that file's, and nothing here can show Dan which. No picker covers it: undo that on the branch, or leave the merge to Dan."
  fi
fi

# The lessons file at a commit. gh's own 404 is a file that is not there, which reads as a file
# with no entries; any other failure refuses. Asked for raw, which GitHub serves up to 100 MB; a
# file past what this gate reads is refused by its size, never judged by its first part.
lessons_at(){  # $1 = commit, $2 = where to put it, $3 = in words
  api_out="$2"; api_args=(-H "Accept: application/vnd.github.raw+json" "repos/$api_slug/contents/$LESSONS_PATH?ref=$1")
  must_read "$LESSONS_PATH at $3 $1 of $api_slug"
  if [ "$MT_READ_STATE" = absent ]; then rm -f "$2"; return 0; fi
  local size
  size="$(wc -c < "$2" 2>/dev/null | tr -d '[:space:]')"
  case "$size" in ''|*[!0-9]*) deny "$WHAT: the size of $LESSONS_PATH at $3 $1 could not be read after GitHub sent it." ;; esac
  [ "$size" -le "$MAX_BYTES" ] || deny "$WHAT: $LESSONS_PATH at $3 $1 of $api_slug is $size bytes, more than the $MAX_BYTES bytes this gate reads, so the entries PR #$number changes in it were not compared. That is this gate's limit, not a verdict on the pull request."
}
lessons_at "$merge_base" "$SCRATCH/base.md" "the merge base"
lessons_at "$judged_oid" "$SCRATCH/head.md" "$judged_words"

# The same bytes, or absent at both: the pull request does nothing to the file. Absent at both while
# its own file list names the file as changed is GitHub's two answers disagreeing, and refuses.
if [ -f "$SCRATCH/base.md" ] && [ -f "$SCRATCH/head.md" ]; then
  cmp -s "$SCRATCH/base.md" "$SCRATCH/head.md" && exit 0
elif [ ! -f "$SCRATCH/base.md" ] && [ ! -f "$SCRATCH/head.md" ]; then
  [ "$touch" = yes ] && deny "$WHAT: GitHub's file list for PR #$number names $LESSONS_PATH as changed, yet GitHub returned no such file at the merge base $merge_base or at $judged_words $judged_oid, so what changes in it cannot be read."
  exit 0
fi

command -v python3 >/dev/null 2>&1 || deny "$WHAT: $(ps_detector_absent_why "python3 is not on PATH" "lessons-merge-gate.sh reads the entries through lib/lesson-merge.py, so with it absent nothing here can tell a changed entry from a blank line." "python3")"
[ -f "$RULE" ] || deny "$WHAT: $RULE is missing, and it is the rule this gate applies. Restore it with claude-sync pull."

rule_args=(judge --repo "$api_slug" --pr "$number" --base "$SCRATCH/base.md" --head "$SCRATCH/head.md" --record-dir "$RECORD_DIR")
[ -n "$transcript" ] && [ -n "$session_id" ] && rule_args+=(--transcript "$transcript" --session "$session_id")
[ -n "$agent_id" ] && rule_args+=(--agent)
sleep_active && rule_args+=(--asleep)
verdict_json="$(python3 "$RULE" "${rule_args[@]}" 2>"$SCRATCH/rule.err")"; rule_rc=$?
verdict="$(printf '%s' "$verdict_json" | jq -r '.verdict // ""' 2>/dev/null)"
case "$rule_rc:$verdict" in
  0:untouched|0:covered) exit 0 ;;
  0:refuse)
    why="$(printf '%s' "$verdict_json" | jq -r '.reason // ""' 2>/dev/null)"
    [ -n "$why" ] && deny "$why" ;;
esac
deny "$WHAT: lib/lesson-merge.py gave no verdict on PR #$number (exit $rule_rc: $(tail -n 1 "$SCRATCH/rule.err" 2>/dev/null | cut -c1-300)). That is the rule failing, not the pull request passing."
