#!/usr/bin/env bash
# Global Stop hook: periodically ask Claude to review the session for feature
# ideas / tech debt worth filing as GitHub issues. Repo-agnostic (auto-detects
# the current repo; falls back to listing ideas if there's no repo/gh).
# Throttled per-project, and guarded so the re-prompt can't loop on itself.
# Tune COOLDOWN_SECONDS, or remove the hooks.Stop entry in ~/.claude/settings.json
# to disable everywhere.

set -euo pipefail

input=$(cat)

# Detached-run guard: see session-reflection.sh. A headless `claude -p` launched by an app has no
# reader, so an issue-review re-prompt spends the run on ceremony and can never reach a person
# anyway. It would also file issues nobody asked for, from a run that was told to do one job.
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

# Loop guard: if this stop was triggered by our own re-prompt, let it end.
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
[ "$stop_active" = "true" ] && exit 0

# Only after turns that actually changed something (Edit/Write/Bash/Agent/...):
# chat-only and read-only Q&A turns skip, and skips do NOT consume the cooldown
# stamp below (shared helper, also used by session-reflection.sh).
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# Per-conversation kill switch: `touch <transcript>.skip-stop-hooks` silences
# this hook for that one conversation only; delete the file to re-enable.
[ -f "${transcript}.skip-stop-hooks" ] && exit 0
worked=$(python3 "$(dirname "${BASH_SOURCE[0]}")/turn-worked.py" "$transcript" 2>/dev/null)
[ "$worked" = "yes" ] || exit 0

# Findings harvested from subagents that finished for this project (see
# subagent-issue-harvest.sh). Fetched BEFORE the cooldown is judged, because a
# pending finding has to beat it: a batch of agents finishing together would
# otherwise get one review between them, and the rest of what they found would
# sit unread until the window reopened, by which point the session is usually
# over. Reading does not consume the spool; only filing does.
# The session's own transcript path is handed to every spool call. It is what
# keys the spool, so that an agent working in a repo nested inside this folder
# lands where this review will actually look: keying each side on its own
# directory let the two drift apart, and 47 findings sat unread for a week
# because of it (see issue_spool_key).
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
SPOOL_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/issue-spool.sh"
# `pending` exits non-zero when there is nothing to show, and this script runs
# under errexit, so both the missing-library case and the ordinary empty case
# have to be caught explicitly. Left bare, an empty spool would kill the hook
# and the review would simply stop happening, with nothing anywhere to say why.
pending=""
urgent="no"
# WHICH RECORDS THIS RENDER READ go to a stamp file, written by the same read that produces
# `pending` (claude-config#381). The clear line written below names it, and files only those records,
# so anything a finishing agent appends while the picker is open stays pending for the next review.
# It starts in a throwaway file and is moved into place only when a clear line is actually written,
# because this hook can still exit on its cooldown after rendering, and a stamp left where a clear
# line points would describe a render nobody was shown.
render_stamp="$(mktemp "${TMPDIR:-/tmp}/claude-issue-stamp.XXXXXX" 2>/dev/null)" || render_stamp=""
trap 'rm -f ${render_stamp:+"$render_stamp"}' EXIT
if [ -f "$SPOOL_LIB" ]; then
  pending=$(bash "$SPOOL_LIB" pending "$proj" "$transcript" "$render_stamp" 2>/dev/null) || pending=""
  # Only a real FINDING earns the cooldown bypass. A harvest that FAILED is
  # reported whenever the review next speaks, but does not itself make it speak:
  # a recurring failure keeps the spool permanently non-empty, which would fire
  # the review on every single turn and teach us both to ignore it.
  if bash "$SPOOL_LIB" has-findings "$proj" "$transcript" >/dev/null 2>&1; then urgent="yes"; fi
fi

# One failure reason has no remedy at all: an agent spawned by another agent
# names a transcript that is never written, so the harvest can never read it.
# The spool holds those back from every review (see MUTED_ERROR_REASONS) because
# a notice carrying no action, delivered every turn, is what teaches a person to
# skip the whole review. Holding them back is only honest if the fault still
# surfaces, so the count rides along with whatever review speaks next once a
# week has passed.
#
# It never MAKES a review speak. `urgent` above is untouched, for the same
# reason it excludes ordinary failures: a fault nobody can act on must not be
# able to interrupt a turn.
MUTED_REPORT_SECONDS="${CLAUDE_ISSUE_MUTED_REPORT_SECONDS:-604800}"  # 7 days
muted_stamp="${TMPDIR:-/tmp}/claude-feature-issue-muted-$(printf '%s' "$proj" | shasum | cut -c1-12).stamp"
muted_line=""
if [ -f "$SPOOL_LIB" ]; then
  muted_last=0
  [ -f "$muted_stamp" ] && muted_last=$(cat "$muted_stamp" 2>/dev/null || echo 0)
  case "$muted_last" in ''|*[!0-9]*) muted_last=0 ;; esac
  if [ $(( $(date +%s) - muted_last )) -ge "$MUTED_REPORT_SECONDS" ]; then
    muted_line=$(bash "$SPOOL_LIB" muted-summary "$proj" "$transcript" 2>/dev/null) || muted_line=""
  fi
fi
# The held-back count stays in the REASON, never in the findings file. This hook
# files those records away and restarts their week on the strength of having
# reported them, so a copy that only exists in a file nobody opened would lose the
# report AND silence the next week of them (L98). The findings file is for the
# findings; anything settled by being shown is shown.

# Throttle: only re-prompt once per cooldown window, tracked per project.
COOLDOWN_SECONDS=1800  # 30 minutes
hash=$(printf '%s' "$proj" | shasum | cut -c1-12)
stamp="${TMPDIR:-/tmp}/claude-feature-issue-review-${hash}.stamp"

now=$(date +%s)
last=0
[ -f "$stamp" ] && last=$(cat "$stamp" 2>/dev/null || echo 0)
if [ "$urgent" != "yes" ] && [ $(( now - last )) -lt "$COOLDOWN_SECONDS" ]; then
  exit 0
fi

printf '%s' "$now" > "$stamp"

# decision:block feeds `reason` back to Claude as a continuation instruction, and
# Claude Code prints that reason to Dan verbatim. So the instruction does NOT live
# in this file any more: it lives in review/issue-review.md and what follows emits a
# short pointer to it. Dan, 2026-08-31, looking at the 8,000 character version plus
# the spooled findings appended to it: "I think showing this all is unnecessary and
# ugly".
#
# The path is RESOLVED FROM THIS FILE'S OWN LOCATION, never written down and never
# read from the environment. This config is synced between two Macs whose paths
# differ, so a pointer that resolves itself is correct on both with nothing to
# configure. test-review-instructions.sh proves that by running a relocated copy of
# the tree and requiring the reason to name the copy.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTRUCTION="$SELF_DIR/review/issue-review.md"

# The findings go to a file the pointer names, and that file OUTLIVES this hook:
# Claude opens it after the hook has exited, so it is deliberately not a mktemp that
# gets removed on the way out. One stable name per project, overwritten by every
# review, so it reports what is pending now and cannot accumulate.
#
# It also replaces the old ARG_MAX dance. The spool has no natural size limit, and
# nothing here passes it as an argument any more.
findings_file=""
if [ -n "$pending" ]; then
  # ${TMPDIR%/} rather than $TMPDIR, because macOS sets it with a trailing slash
  # and this path is now SHOWN to Dan in the reason rather than only used.
  findings_file="${TMPDIR:-/tmp}"
  findings_file="${findings_file%/}/claude-issue-findings-${hash}.txt"
  # Annotated with the open issue that already covers a finding, where one clearly does
  # (claude-config#256). An agent auditing the backlog restates the issues it read, and those
  # restatements were filed as fresh issues and closed as duplicates within the hour. It FAILS
  # OPEN: no gh, no network, no repo and the findings go out exactly as they were, because this is
  # a convenience on a review and losing it must never cost the review.
  _matcher="$SELF_DIR/lib/match-open-issues.py"
  if [ -f "$_matcher" ]; then
    _annotated="$(printf '%s\n' "$pending" | python3 "$_matcher" "$proj" 2>/dev/null)" || _annotated=""
    [ -n "$_annotated" ] && pending="$_annotated"
  fi
  printf '%s\n' "$pending" > "$findings_file" 2>/dev/null || findings_file=""
  # THE CLEAR COMMAND IS WRITTEN HERE, out of the same two values this render used
  # (claude-config#287, claude-config#284). The instruction used to name it as a fixed line,
  # `issue-spool.sh clear "$PWD"`, which passes no transcript and therefore keys on the git common
  # dir, while this render keyed on the transcript's directory. The two agreed only when those
  # roots coincided. Observed live on 2026-09-03: the findings file named
  # `bfea61f932c1.jsonl (107 records)` and the clear answered `nothing was pending under the key(s)
  # this project reads (ac694bb5abad)`. Both were true, about different files, and 138 records sat
  # unfiled across 9 keys while the same five findings came back at every review.
  #
  # There is now ONE derivation of the key, here, and the reader is handed the command rather than
  # a rule for reconstructing it. Two independent derivations that must stay in step is what failed
  # (L70, L285), and it is the same drift this design already recorded once, on the writing side.
  #
  # Quoted with %q, so a path holding a space is still one argument when the line is run verbatim.
  #
  # AND THE STAMP, as its third argument (claude-config#381). Named per SESSION, not per project like
  # the findings file: two sessions in one project each have a picker open at times, and one render
  # overwriting the other's stamp would hand the first clear a record of records it never showed.
  #
  # When the stamp cannot be put in place there is deliberately NO clear line. A line without one is
  # the old command, which files every record under the key including any harvested while the picker
  # is open, so the honest answer is that these cannot be filed from this review and will come back
  # at the next one (L173, L11).
  if [ -n "$findings_file" ]; then
    stamp_file="${findings_file%.txt}.$(basename "$transcript" .jsonl).manifest"
    if [ -n "$render_stamp" ] && [ -s "$render_stamp" ] \
        && mv -f "$render_stamp" "$stamp_file" 2>/dev/null && [ -f "$stamp_file" ]; then
      render_stamp=""
      printf '\nTO FILE THESE, run this line exactly as it stands:\n  bash %q clear %q %q %q\n' \
        "$SELF_DIR/lib/issue-spool.sh" "$proj" "$transcript" "$stamp_file" >> "$findings_file" 2>/dev/null || true
    else
      printf '\nTHESE cannot be filed from this review: the record of which spool records it read could not be written, and filing without it would also file anything harvested while the picker is open. There is nothing to run; they stay pending and come back at the next review.\n' \
        >> "$findings_file" 2>/dev/null || true
    fi
  fi
fi

reason_args=(--instruction "$INSTRUCTION" --label "END OF TURN ISSUE REVIEW")
if [ -n "$findings_file" ]; then reason_args+=(--findings "$findings_file"); fi
if [ -n "$muted_line" ]; then reason_args+=(--extra "$muted_line"); fi

payload="$(python3 "$SELF_DIR/lib/review-reason.py" "${reason_args[@]}" 2>/dev/null)" || payload=""

if [ -n "$payload" ]; then
  printf '%s' "$payload"
  # The spool text really went out with this review, so the records nobody can act
  # on are settled here rather than riding along on every future review (#85). A
  # HARVEST FAILED line has no action attached to it: being told once is the whole
  # of its value, and it could never be cleared, because clearing is what happens
  # after a picker is answered and a spool holding only failures produces no
  # picker. Findings are untouched and still wait for the picker.
  #
  # The condition is the findings FILE, not the pending text. The text is only
  # reported once it has been written somewhere Claude can open and counted in a
  # reason Dan can read; a write that failed leaves findings_file empty, and
  # settling then would file failures nobody was ever shown.
  if [ -n "$findings_file" ] && [ -f "$SPOOL_LIB" ]; then
    bash "$SPOOL_LIB" file-errors "$proj" "$transcript" >/dev/null 2>&1 || true
  fi
  # The held-back records are settled and the week restarted ONLY when their count
  # actually went out with this review. Doing either on a review that could not be
  # delivered would lose the report AND silence the next week of them, which is the
  # one way holding them back could hide a fault for good. The count rides in the
  # reason itself, so it is delivered exactly when this branch is taken.
  if [ -n "$muted_line" ] && [ -f "$SPOOL_LIB" ]; then
    bash "$SPOOL_LIB" file-muted "$proj" "$transcript" >/dev/null 2>&1 || true
    printf '%s' "$(date +%s)" > "$muted_stamp" 2>/dev/null || true
  fi
else
  # The pointer could not be built. Losing its detail is a nuisance; losing the
  # review is not, so a static payload still sends Claude to the instruction. It
  # names the file relatively, because the one thing this branch cannot do is work
  # out an absolute path. Nothing is settled here: this review carried no counts,
  # so it reported nothing that could be filed away.
  cat <<'JSON'
{"decision":"block","reason":"END OF TURN ISSUE REVIEW. Read review/issue-review.md next to the Stop hooks in your Claude config directory (normally ~/.claude/hooks) and follow it exactly. The pointer that normally names its exact path could not be built, so find the file yourself rather than inventing a review from this line. Any subagent findings for this project are still in the spool: `bash ~/.claude/hooks/lib/issue-spool.sh pending \"$PWD\"` reads them without consuming them."}
JSON
fi
