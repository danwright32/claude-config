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
# The lessons review of a whole branch (lib/pr-review.sh, kind=pr) is shown here too, under its own
# heading, and marked DELIVERED (<file>.delivered) once shown, which is what lets the merge gate
# allow the merge without refusing once to deliver the findings itself.
#
# Housekeeping, only on the full path: finished files older than 14 days are removed, with their
# delivery stamps. They are records of a push, not data anybody restores from. citations.tsv, the
# ledger of which lessons reviews cite, is not a .txt and is never swept.
#
# Environment: AI_REVIEW_STATE_DIR and AI_REVIEW_DEADLINE_SECONDS, shared with the push hook through
# lib/ai-review-common.sh.

set -uo pipefail

input="$(cat 2>/dev/null || true)"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ai-review-common.sh
. "$HOOK_DIR/lib/ai-review-common.sh" 2>/dev/null || exit 0

[ -d "$AR_STATE_DIR" ] || exit 0
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
LIST=""
[ -n "$session" ] && LIST="$SHOWN_DIR/$session.list"

# Fast path: nothing written since this session last looked, and nothing pending.
pending=( "$AR_STATE_DIR"/*.txt.pending )
if [ -n "$LIST" ] && [ -f "$LIST" ] && [ "${#pending[@]}" -eq 0 ] \
   && ! [ "$AR_STATE_DIR/.updated" -nt "$LIST" ]; then
  exit 0
fi

finished=( "$AR_STATE_DIR"/*.txt )
[ "${#finished[@]}" -gt 0 ] || [ "${#pending[@]}" -gt 0 ] || exit 0

# Full path. The repository this session is in, from the payload's cwd.
fields="$(ar_payload_fields "$input")" || exit 0
cwd="${fields%%$'\x1f'*}"
if [ -z "$session" ]; then
  rest="${fields#*$'\x1f'}"
  session="${rest%%$'\x1f'*}"
  session="${session//[^A-Za-z0-9_-]/_}"
  [ -n "$session" ] && LIST="$SHOWN_DIR/$session.list"
fi
[ -n "$cwd" ] || exit 0
key="$(ar_repo_key "$cwd")" || exit 0

if [ -z "$LIST" ]; then
  # No session to key on. It speaks, because said twice is a smaller failure than never said
  # (L98), and says on stderr why it could not hold itself to once, which the person is not shown.
  echo "ai-review-nudge: the hook payload carried no session id, so finished reviews cannot be held to once per session and may be repeated." >&2
fi

mkdir -p "$SHOWN_DIR" 2>/dev/null || true
shown=$'\n'
[ -n "$LIST" ] && [ -f "$LIST" ] && shown=$'\n'"$(cat "$LIST" 2>/dev/null)"$'\n'

mark_shown() {   # $1 = file name
  [ -n "$LIST" ] || return 0
  printf '%s\n' "$1" >> "$LIST" 2>/dev/null || true
  shown="${shown}$1"$'\n'
}
was_shown() {    # $1 = file name
  case "$shown" in *$'\n'"$1"$'\n'*) return 0 ;; *) return 1 ;; esac
}

now="$(date +%s)"
NUDGE_LINES=20
NUDGE_CHARS=300
NUDGE_BUDGET=8000
printed=0
held=0

elapsed_text() {   # $1 = seconds -> "1m 42s" or "42s"
  local s="$1"
  case "$s" in ''|*[!0-9]*) printf 'an unknown time'; return ;; esac
  if [ "$s" -ge 60 ]; then printf '%dm %02ds' "$((s / 60))" "$((s % 60))"; else printf '%ds' "$s"; fi
}

read_meta() {   # $1 = file -> sets m_repo m_branch m_sha m_started m_finished m_status m_deadline m_kind m_findings
  m_repo=""; m_branch=""; m_sha=""; m_started=""; m_finished=""; m_status=""; m_deadline=""; m_kind=""; m_findings=""
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
      kind=*) m_kind="${line#kind=}" ;;
      findings=*) m_findings="${line#findings=}" ;;
    esac
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
[ "${#pending[@]}" -gt 0 ] && for p in "${pending[@]}"; do
  base="$(basename "$p")"
  case "$base" in "$key"-*) ;; *) continue ;; esac
  read_meta "$p"
  case "$m_started" in ''|*[!0-9]*) continue ;; esac
  limit="${m_deadline:-$AR_DEADLINE}"
  case "$limit" in ''|*[!0-9]*) limit="$AR_DEADLINE" ;; esac
  if [ $((now - m_started)) -gt $((limit + 60)) ]; then
    final="${p%.pending}"
    if [ ! -e "$final" ]; then
      {
        printf 'repo=%s\nbranch=%s\nsha=%s\nstarted=%s\nfinished=%s\nstatus=abandoned\n\n' \
          "$m_repo" "$m_branch" "$m_sha" "$m_started" "$now"
        printf 'The review was started and never finished: %s passed with no answer written, which means the background runner died. Nothing was read back. Push again to re-run it.\n' \
          "$(elapsed_text $((now - m_started)))"
      } > "$final.tmp" 2>/dev/null && mv -f "$final.tmp" "$final" 2>/dev/null
      # A pull request review's outcome is counted in the durable ledger like every other (#562).
      case "$base" in *-pr-*) ar_pr_ledger "$final" "" ;; esac
    fi
    rm -f "$p" 2>/dev/null
    finished=( "$AR_STATE_DIR"/*.txt )
  fi
done

[ "${#finished[@]}" -gt 0 ] && for f in "${finished[@]}"; do
  base="$(basename "$f")"
  case "$base" in "$key"-*) ;; *) continue ;; esac
  was_shown "$base" && continue
  if [ "$printed" -ge "$NUDGE_BUDGET" ]; then held=$((held + 1)); continue; fi
  read_meta "$f"
  short="${m_sha:0:7}"
  took="$(elapsed_text $((${m_finished:-0} - ${m_started:-0})))"
  body="$(ar_capped_body "$f" "$NUDGE_LINES" "$NUDGE_CHARS")"
  printed=$((printed + ${#body} + 300))
  if [ "$m_kind" = "pr" ]; then
    case "$m_status" in
      ok) printf 'Lessons review of the whole branch %s %s at %s, finished in %s with %s findings (the full review is in %s). The merge waits until these have been read: check each against the code before acting on it.\n' \
            "${m_repo:-this repository}" "${m_branch:-?}" "$short" "$took" "${m_findings:-?}" "$f"
          printf '%s\n' "$body" ;;
      *) printf 'Lessons review of the whole branch %s %s at %s ended as %s, so the merge will be refused until it is run again:\n%s\n' \
            "${m_repo:-this repository}" "${m_branch:-?}" "$short" "${m_status:-no status}" "$body" ;;
    esac
    touch "$f.delivered" 2>/dev/null || true
    mark_shown "$base"
    continue
  fi
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

# Housekeeping and the fast path stamp: this session has now seen everything written so far.
[ "$held" -gt 0 ] && printf '%s more finished review(s) are not shown, to stay under the hook output cap; they will be shown on the next prompt.\n' "$held"
find "$AR_STATE_DIR" -maxdepth 1 \( -name '*.txt' -o -name '*.txt.delivered' \) -type f -mtime +14 -exec rm -f {} + 2>/dev/null || true
[ -n "$LIST" ] && { touch "$LIST" 2>/dev/null || true; }
exit 0
