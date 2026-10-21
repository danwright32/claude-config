#!/usr/bin/env bash
#
# ai-review-nudge.sh
# Claude Code UserPromptSubmit hook.
#
# Show the advisory AI reviews ai-review-on-push.sh has finished for the repository this session is
# in, once each per session (claude-config#433). The review runs detached after a push so the push
# waits for nothing, which means its answer has no turn to land in; this is the turn. Its stdout is
# added to the conversation, so what it prints is read by Claude and acted on or not, and it NEVER
# blocks the prompt: a UserPromptSubmit hook exiting non-zero stops the turn, and a review finding
# is something to mention, not a reason to refuse to work (L54). Every path exits 0.
#
# WHAT IT COSTS, which is the thing that decides whether a per prompt hook may exist. Measured
# 2026-09-18 on this Mac (bash 3.2, jq present, four other agents running): with nothing to show,
# the fast path below is one glob, one bash regex over the payload and two stat comparisons, no
# process started, and the whole hook ran in 7.1 ms median over 20 runs (7.6 ms max); the full path
# (payload parsed with jq, one git call and one cksum to key the repository, the state directory
# read) ran in 33.8 ms median with nothing for this repository and 35.9 ms median when it showed a
# review. Both are under the 50 ms the brief allows. test-ai-review-on-push.sh measures the
# nothing-to-show case on every run and prints the number rather than asserting a fixed bound, which
# would measure the machine's load (L224).
#
# The fast path: the state directory keeps a `.updated` stamp touched on every write, and each
# session keeps a `shown/<session key>.list` touched on every pass. When nothing has been written
# since this session last looked, and nothing is pending, there is nothing to say and nothing to
# parse. A pending review is checked every prompt, because it goes stale by TIME passing and not by
# anything being written (L74 in reverse: a clock based state needs a clock based check).
#
# WHAT IT SAYS. Each finished review for this repository not yet shown to this session, headed with
# the repository, the branch, the sha and how long the review took, then the review text as claude
# wrote it. A review that ran out of time, errored or printed nothing is reported in its own words
# once, so a review that could not run is never mistaken for a review that found nothing (L11,
# L98). A review still `.pending` past its deadline plus a minute of grace, which means the runner
# died without writing, is reported once as not finished and rewritten as a finished file saying
# so, so it stops being pending and every session learns of it exactly once.
#
# CAPPED (claude-config#560). What this prints reaches the session as additionalContext, which the
# platform cuts at 10,000 characters with nothing said, so a long review arrived as its first part
# and read as the whole (L351). Each review prints at most NUDGE_LINES lines of NUDGE_CHARS through
# ar_capped_body, which ends by naming how many were left out and the file holding them all, and
# once NUDGE_BUDGET characters have been printed the rest wait, unshown, for the next prompt.
#
# NOT SHOWN HERE: the lessons review of a whole branch (lib/pr-review.sh, kind=pr, named
# <key>-pr-<sha>.txt), since claude-config#1090 (Dan, 2026-10-12). The merge gate prints its
# findings and issues their read key when it refuses a merge, which is where they must be read
# anyway, and showing them here only added early sight that rarely reached anyone: branches are
# mostly built by agents, which never fire UserPromptSubmit. They were 2,008 of the 2,010 finished
# files on 2026-10-12, and walking them is what timed the hook out. They are dropped by NAME, in the
# one awk that lists what is unshown, so none costs a process. A pending one past its deadline is
# still settled below, so its marker cannot keep every session off the fast path; and so is every
# other repository's, by whichever session prompts first (claude-config#1095).
#
# Nothing below may start a process per FILE, nor per review before the budget has decided to show
# it: the state directory holds every repository's reviews for 14 days (1,975 files on 2026-10-03),
# and one `basename` per file took the hook to 15 to 17 s on a heavily loaded machine, past its 5 s
# timeout, so its output was discarded on every prompt; on 2026-10-12 a fresh session walked 1,200
# reviews of its own repository, about 7 ms each, before the budget held them (9.7 to 10 s; against
# a copy of the same folder, 4,453 files, at load 9, the old hook took 43.6 to 51.8 s for a fresh
# claude-config session and this one 0.48 to 0.60 s, three runs each, 2026-10-12). Names
# are cut with parameter expansion, and a review's cost is bounded in bash from its file before
# anything is started for it. test-ai-review-on-push.sh sections 6b and 6c count the processes
# started against 300 files of another repository, 300 branch reviews of this one, and 300 push
# reviews of this one against 30, and require each pair to be equal.
#
# SHOWN WHAT FINISHES DURING THE SESSION (claude-config#1216). A session with no record yet is at its
# first look, and the reviews of its repository already finished then belong to earlier sessions:
# on 2026-10-15 a new Slate session found about 650, mostly background agents' pushes from sessions
# long gone, and printed 8,000 characters of them on every prompt for dozens of prompts. So the first
# look records them as seen without printing them, and says in one line how many and where they
# are. A review still pending then, or settled by this very pass, is not in that baseline, and is
# shown when it finishes. A first prompt with nothing to baseline records an empty list all the same,
# or the next review to finish would be taken for an earlier one. Subagents never prompt, so a
# session's own pushes and its agents' all finish after its first look and are shown.
#
# MARKED SHOWN ONLY ONCE IT IS OUT. The platform throws a hook's output away when it kills it at the
# timeout, so a review recorded as shown the moment it was printed was, when the hook was then
# killed, never seen and never shown again. What was shown is appended to the session's list as the
# last write of the run, after everything else, so a run killed at any point before records nothing
# and the next prompt shows it all again (section 6d).
#
# Housekeeping, on the full path: finished files older than 14 days are removed, with their
# delivery stamps, and so are other sessions' shown/ records not touched in 14 days (a record is
# touched on every full pass, so one that old lists only reviews already swept). The records sweep
# also runs on a session's first look with nothing to baseline (sweep_session_records, called from
# first_look_empty), since on a Mac where no review runs that is the only pass that writes a
# record, and without it one empty list per session would pile up. They are records of
# a push, not data anybody restores from. citations.tsv, the ledger of which lessons reviews cite,
# is not a .txt and is never swept.
#
# Environment: AI_REVIEW_STATE_DIR and AI_REVIEW_DEADLINE_SECONDS, shared with the push hook through
# lib/ai-review-common.sh.

set -uo pipefail

input="$(cat 2>/dev/null || true)"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ai-review-common.sh
. "$HOOK_DIR/lib/ai-review-common.sh" 2>/dev/null || exit 0

shopt -s nullglob

# The session, read with a bash regex first because the fast path must start no process. A session
# id is letters, digits, hyphens and underscores; anything else falls through to the real parser.
session=""
if [[ "$input" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]]; then
  session="${BASH_REMATCH[1]}"
fi

# The per session record is named by the session id itself, which the regex above has already
# confined to file safe characters, so the fast path hashes nothing and starts no process.
SHOWN_DIR="$AR_STATE_DIR/shown"
LIST=""; HELD=""
[ -n "$session" ] && { LIST="$SHOWN_DIR/$session.list"; HELD="$SHOWN_DIR/$session.held"; }

# A first look with nothing to baseline still records the session's list (see the header), which
# costs a process only on that one prompt: every later one finds the list and goes on as before.
#
# That first look also sweeps other sessions' records past 14 days, as the full path does below: on
# a computer where no review ever runs, it is the only pass that writes a record, so without the
# sweep here one empty list per session would pile up for ever. One more process, on that one prompt.
sweep_session_records() {   # another session's record by its age; this session's own never
  find "$SHOWN_DIR" -maxdepth 1 \( -name '*.list' -o -name '*.held' \) ! -name "${session:-.}.list" ! -name "${session:-.}.held" -type f -mtime +14 -exec rm -f {} + 2>/dev/null || true
}
first_look_empty() {
  if [ -n "$LIST" ] && [ ! -e "$LIST" ]; then
    { mkdir -p "$SHOWN_DIR" && : > "$LIST"; } 2>/dev/null
    sweep_session_records
  fi
  exit 0
}
[ -d "$AR_STATE_DIR" ] || first_look_empty

# Fast path: nothing written since this session last looked, nothing pending, and nothing held back
# by the last pass for want of room (the .held marker, at the end). "Since" is the session's record
# being strictly NEWER than the last write: bash 3.2's -nt compares whole seconds, so a write in the
# same second as the last look read as older and stayed hidden until some later write (#1095). A
# tie takes the full path, which costs one full pass at most, in that second.
pending=( "$AR_STATE_DIR"/*.txt.pending )
if [ -n "$LIST" ] && [ -f "$LIST" ] && [ "${#pending[@]}" -eq 0 ] && [ ! -e "$HELD" ] \
   && [ "$LIST" -nt "$AR_STATE_DIR/.updated" ]; then
  exit 0
fi

finished=( "$AR_STATE_DIR"/*.txt )
[ "${#finished[@]}" -gt 0 ] || [ "${#pending[@]}" -gt 0 ] || first_look_empty

# Full path. The repository this session is in, from the payload's cwd.
fields="$(ar_payload_fields "$input")" || exit 0
cwd="${fields%%$'\x1f'*}"
if [ -z "$session" ]; then
  rest="${fields#*$'\x1f'}"
  session="${rest%%$'\x1f'*}"
  session="${session//[^A-Za-z0-9_-]/_}"
  [ -n "$session" ] && { LIST="$SHOWN_DIR/$session.list"; HELD="$SHOWN_DIR/$session.held"; }
fi
[ -n "$cwd" ] || exit 0
key="$(ar_repo_key "$cwd")" || exit 0

if [ -z "$LIST" ]; then
  # No session to key on. It speaks, because said twice is a smaller failure than never said
  # (L98), and says on stderr why it could not hold itself to once, which the person is not shown.
  echo "ai-review-nudge: the hook payload carried no session id, so finished reviews cannot be held to once per session and may be repeated." >&2
fi

mkdir -p "$SHOWN_DIR" 2>/dev/null || true

# What this run showed, written to the session's list only at the very end (see the header).
shown_names=""
mark_shown() {   # $1 = file name
  shown_names="$shown_names$1"$'\n'
}

# This repository's finished push reviews that this session has not been shown, in glob order,
# worked out by ONE awk over every name at once. Testing each file against the session's list in
# bash was a pattern match over the whole list per file, which with 916 reviews and a 468 line list
# took 2.9 s at load 200 (measured 2026-10-03), most of the hook's 5 s timeout. A whole branch
# review (<key>-pr-<sha>.txt) is the merge gate's to show, and is dropped here by its name.
unshown_reviews() {
  [ "${#finished[@]}" -gt 0 ] || return 0
  printf '%s\n' "${finished[@]##*/}" | awk -v prefix="$key-" -v branch="$key-pr-" -v list="$LIST" '
    BEGIN { if (list != "") while ((getline l < list) > 0) seen[l] = 1 }
    index($0, prefix) == 1 && index($0, branch) != 1 && !($0 in seen)'
}

now="$(date +%s)"
NUDGE_LINES=20
NUDGE_CHARS=300
NUDGE_BUDGET=8000
NUDGE_HEADING=400   # the heading line above a review's text, with the repository, branch and sha
printed=0
held=0

# The baseline, taken before anything pending is settled below, so a review that finishes in this
# very pass is shown rather than counted as an earlier one.
baseline=""
[ -n "$LIST" ] && [ ! -e "$LIST" ] && baseline="$(unshown_reviews)"

elapsed_text() {   # $1 = seconds -> "1m 42s" or "42s"
  local s="$1"
  case "$s" in ''|*[!0-9]*) printf 'an unknown time'; return ;; esac
  if [ "$s" -ge 60 ]; then printf '%dm %02ds' "$((s / 60))" "$((s % 60))"; else printf '%ds' "$s"; fi
}

read_meta() {   # $1 = file -> sets m_repo m_branch m_sha m_started m_finished m_status m_deadline m_dir m_groups
  m_repo=""; m_branch=""; m_sha=""; m_started=""; m_finished=""; m_status=""; m_deadline=""; m_dir=""; m_groups=""
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || break
    case "$line" in
      repo=*) m_repo="${line#repo=}" ;;
      branch=*) m_branch="${line#branch=}" ;;
      sha=*) m_sha="${line#sha=}" ;;
      started=*) m_started="${line#started=}" ;;
      finished=*) m_finished="${line#finished=}" ;;
      status=*) m_status="${line#status=}" ;;
      deadline=*) m_deadline="${line#deadline=}" ;;
      dir=*) m_dir="${line#dir=}" ;;
      groups=*) m_groups="${line#groups=}" ;;
    esac
  done < "$1"
}

# The most characters ar_capped_body can print for this review, worked out in bash from the file,
# so the budget can decide BEFORE anything is started for the review (claude-config#1090). Each
# body line prints at most NUDGE_CHARS characters and "...", and a line under that at its own length
# plus whatever redaction adds: every rule in lib/review-redact.sed replaces a match of at least 9
# characters with the 10 of [REDACTED], so a line grows by at most one ninth. Past NUDGE_LINES, the
# line saying how many more and where they are. An upper bound, so a review let through by it never
# pushes the output past the budget.
body_bound() {   # $1 = finished review file -> sets bound
  local line in_body=0 n=0 len
  bound=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_body" -eq 0 ]; then [ -n "$line" ] || in_body=1; continue; fi
    n=$((n + 1))
    if [ "$n" -gt "$NUDGE_LINES" ]; then bound=$((bound + 120 + ${#1})); break; fi
    len=$(( ${#line} + ${#line} / 9 + 1 ))
    [ "$len" -gt "$NUDGE_CHARS" ] && len="$NUDGE_CHARS"
    bound=$((bound + len + 4))
  done < "$1"
}

# A pending review past its deadline (plus a minute of grace for the runner's own kill) means the
# runner died without writing. It is rewritten as a finished file in its own words, once, so it
# joins the ordinary lifecycle below and stops being pending for everybody.
#
# Both loops are guarded by a count first: under the bash macOS ships (3.2) expanding an EMPTY array
# with `set -u` on is an unbound variable error, and the first version of this hook died there on
# every prompt that had nothing pending, which is every ordinary prompt (found by the suite, not by
# reading).
#
# EVERY repository's, not only this session's (claude-config#1095). The fast path above is off while
# any pending marker exists, from any repository, so a dead review that only its own repository's
# sessions settled kept every other repository's sessions on the full path until one of its own
# prompted. Settling is a file write, the same for any repository; what a session is SHOWN stays its
# own repository's (unshown_reviews). A marker with no start time to judge it by (a write cut short)
# is judged by when it was written instead, one find for that rare marker alone, for the same reason.
[ "${#pending[@]}" -gt 0 ] && for p in "${pending[@]}"; do
  base="${p##*/}"
  read_meta "$p"
  limit="${m_deadline:-$AR_DEADLINE}"
  case "$limit" in ''|*[!0-9]*) limit="$AR_DEADLINE" ;; esac
  case "$m_started" in
    ''|*[!0-9]*)
      [ -n "$(find "$p" -maxdepth 0 -mmin +$(( (limit + 60) / 60 + 1 )) 2>/dev/null)" ] || continue
      m_started=""; age="" ;;
    *) age=$((now - m_started)) ;;
  esac
  if [ -z "$age" ] || [ "$age" -gt $((limit + 60)) ]; then
    final="${p%.pending}"
    # A pull request review read in groups (#601) is settled by lib/pr-review.sh check, which knows
    # its groups: it writes the review up from answers that exist, or records it abandoned naming
    # the groups that never came. Only if that cannot run (its checkout gone) is it written up here.
    if [ -n "$m_groups" ] && [ -n "$m_dir" ] && [ -n "$m_sha" ]; then
      # Labelled with the branch the pending marker records (the pull request's head branch), never
      # whichever branch the checkout happens to stand on (claude-config#852).
      bash "$HOOK_DIR/lib/pr-review.sh" check --dir "$m_dir" --sha "$m_sha" ${m_branch:+--branch "$m_branch"} </dev/null >/dev/null 2>&1
      if [ ! -e "$p" ]; then finished=( "$AR_STATE_DIR"/*.txt ); continue; fi
    fi
    if [ ! -e "$final" ]; then
      {
        printf 'repo=%s\nbranch=%s\nsha=%s\nstarted=%s\nfinished=%s\nstatus=abandoned\n\n' \
          "$m_repo" "$m_branch" "$m_sha" "$m_started" "$now"
        printf 'The review was started and never finished: %s passed with no answer written, which means the background runner died. Nothing was read back. Push again to re-run it.\n' \
          "$(elapsed_text "$age")"
      } > "$final.tmp" 2>/dev/null && mv -f "$final.tmp" "$final" 2>/dev/null
      # A pull request review's outcome is counted in the durable ledger like every other (#562).
      case "$base" in *-pr-*) ar_pr_ledger "$final" "$m_dir" ;; esac
    fi
    rm -f "$p" 2>/dev/null
    # A write like any other, so it takes every OTHER session off its fast path once, or a session
    # already past this pending marker would never be told (claude-config#1095).
    touch "$AR_STATE_DIR/.updated" 2>/dev/null || true
    finished=( "$AR_STATE_DIR"/*.txt )
  fi
done

todo="$(unshown_reviews)"
if [ -n "$baseline" ]; then
  # One awk over both lists, so the baseline costs no process per review (6f).
  todo="$(printf '%s\n' "$todo" | awk 'FILENAME == ARGV[1] { b[$0] = 1; next } !($0 in b)' <(printf '%s\n' "$baseline") -)"
  shown_names="$baseline"$'\n'
  printf '%s review(s) of this repository finished before this session began, so they are not shown here; they are in %s.\n' \
    "$(printf '%s\n' "$baseline" | grep -c .)" "$AR_STATE_DIR"
fi
IFS=$'\n'
for base in $todo; do
  IFS=$' \t\n'
  f="$AR_STATE_DIR/$base"
  if [ "$printed" -ge "$NUDGE_BUDGET" ]; then held=$((held + 1)); continue; fi
  # Decided on a bound read in bash, so a review held back has started nothing (claude-config#1090).
  # A review is shown whole or held whole, and a later one only when it still fits, so the output
  # never reaches the hook cap that would cut it silently (L351).
  # A review that did not finish is reported by its heading alone, so it has no text to bound.
  read_meta "$f"
  case "$m_status" in timeout|abandoned|empty) bound=0 ;; *) body_bound "$f" ;; esac
  if [ "$printed" -gt 0 ] && [ $((printed + bound + NUDGE_HEADING)) -gt "$NUDGE_BUDGET" ]; then held=$((held + 1)); continue; fi
  short="${m_sha:0:7}"
  took="$(elapsed_text $((${m_finished:-0} - ${m_started:-0})))"
  body=""
  [ "$bound" -gt 0 ] && body="$(ar_capped_body "$f" "$NUDGE_LINES" "$NUDGE_CHARS")"
  printed=$((printed + ${#body} + NUDGE_HEADING))
  case "$m_status" in
    ok)
      printf 'AI review of %s, branch %s at %s (advisory, ran %s in the background after the push). Findings are one reviewer'"'"'s opinion: check each against the code before acting on it.\n' \
        "${m_repo:-this repository}" "${m_branch:-?}" "$short" "$took"
      printf '%s\n' "$body"
      ;;
    timeout)
      printf 'AI review of %s, branch %s at %s did not finish inside its deadline (%s), so there is nothing to show for that push.\n' \
        "${m_repo:-this repository}" "${m_branch:-?}" "$short" "$took"
      ;;
    abandoned)
      printf 'AI review of %s, branch %s at %s was started and never finished: the background runner died. Nothing was read back.\n' \
        "${m_repo:-this repository}" "${m_branch:-?}" "$short"
      ;;
    empty)
      printf 'AI review of %s, branch %s at %s came back with no text after %s, so there is nothing to show for that push.\n' \
        "${m_repo:-this repository}" "${m_branch:-?}" "$short" "$took"
      ;;
    *)
      printf 'AI review of %s, branch %s at %s could not run (%s):\n' \
        "${m_repo:-this repository}" "${m_branch:-?}" "$short" "${m_status:-no status recorded}"
      printf '%s\n' "$body"
      ;;
  esac
  mark_shown "$base"
done
IFS=$' \t\n'

[ "$held" -gt 0 ] && printf '%s more finished review(s) are not shown, to stay under the hook output cap; they will be shown on the next prompt.\n' "$held"

# Housekeeping. Another session's record is swept by its age; this session's own never is, since it
# was read above and is appended to below. The last four names are a run's own scratch (#1430): a
# review is written to <review>.txt.tmp and renamed in the same breath, and <name>.diff, .marks and
# .code are inputs the run removes when it ends. Nothing reads any of them by name afterwards and no
# run lives longer than its deadline (minutes), so one older than 14 days is what a review killed
# mid write (a crash, a power loss) left behind, never a live run's file.
find "$AR_STATE_DIR" -maxdepth 1 \( -name '*.txt' -o -name '*.txt.delivered' -o -name '*.txt.readkey*' -o -name '*.txt.acknowledged' -o -name '*.txt.push-acknowledged' -o -name '*.txt.leftout' -o -name '*.txt.prread' -o -name '*.txt.round' -o -name '*.txt.tmp' -o -name '*.diff' -o -name '*.marks' -o -name '*.code' \) -type f -mtime +14 -exec rm -f {} + 2>/dev/null || true
sweep_session_records

# Last, so a run killed at any point before it has recorded nothing (see the header): what was
# shown, then the fast path stamp, since this session has now seen everything written so far.
# Unless something was held back: then the .held marker keeps the next prompt off the fast path, so
# it shows what was held, as the line above promises, rather than the fast path hiding it until
# something else writes to the state folder (lessons review of #601). A marker rather than the list
# dated to 1970 as before, which the sweep above would take for a record past 14 days and delete,
# with everything that session had been shown.
if [ -n "$LIST" ]; then
  { printf '%s' "$shown_names" >> "$LIST"; } 2>/dev/null || true
  touch "$LIST" 2>/dev/null || true
  if [ "$held" -gt 0 ]; then
    { : > "$HELD"; } 2>/dev/null || true
  elif [ -e "$HELD" ]; then
    rm -f "$HELD" 2>/dev/null || true
  fi
fi
exit 0
