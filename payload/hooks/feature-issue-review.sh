#!/usr/bin/env bash
# Global Stop hook: periodically ask Claude to review the session for feature
# ideas / tech debt worth filing as GitHub issues. Repo-agnostic (auto-detects
# the current repo; falls back to listing ideas if there's no repo/gh).
# Throttled per-project, and guarded so the re-prompt can't loop on itself.
# Tune COOLDOWN_SECONDS, or remove the hooks.Stop entry in ~/.claude/settings.json
# to disable everywhere.

set -euo pipefail

input=$(cat)
# Cleaned by the shared reader when it loads: a lone surrogate escape anywhere in the payload
# (an emoji cut in half is enough) makes jq read none of it (claude-config#1944). Without the
# library the payload is read as it came, as before.
case "${BASH_SOURCE[0]}" in */*) _ps_dir="${BASH_SOURCE[0]%/*}" ;; *) _ps_dir=. ;; esac
. "$_ps_dir/lib/push-scope.sh" 2>/dev/null && input="$(ps_clean_payload "$input")"

# Detached-run guard: see session-reflection.sh. A headless `claude -p` launched by an app has no
# reader, so an issue-review re-prompt spends the run on ceremony and can never reach a person
# anyway. It would also file issues nobody asked for, from a run that was told to do one job.
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

# Asleep (sleep mode, claude-config#841): nobody is there to answer what this would raise, so it
# stands down. Findings made overnight reach the morning report through the overnight driver's own
# instruction, never through this hook, which exits on stop_hook_active and so would run once a
# night. A sleep record that cannot be read counts as awake (lib/sleep.sh).
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) SELF_DIR="${BASH_SOURCE[0]%/*}" ;; *) SELF_DIR=. ;; esac
SELF_DIR="$(cd "${SELF_DIR:-/}" && pwd)"
if . "$SELF_DIR/lib/sleep.sh" 2>/dev/null && sleep_active; then
  exit 0
fi

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

# python3 is what decides whether this turn did real work, so with none this hook has nothing to
# run at all. Said once rather than swallowed, because silence here is indistinguishable from a
# turn with nothing worth filing (claude-config#490, L98).
_SPN="$SELF_DIR/lib/stop-hook-python-notice.sh"
if [ -f "$_SPN" ]; then
  . "$_SPN"
  stop_hook_python3_notice "feature-issue-review.sh"
fi

worked=$(python3 "$SELF_DIR/turn-worked.py" "$transcript" 2>/dev/null)
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
SPOOL_LIB="$SELF_DIR/lib/issue-spool.sh"
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
# WHERE THE FINDINGS AND THE STAMP GO, worked out before the render rather than after it, because the
# render also reads the SEEN LEDGER that sits beside the stamp (#1011): the marks a clear could not
# write into the spool, because the spool could not be written from where the clear line ran. The
# ledger's path comes from the library, from the stamp's, so the clear that writes it and this render
# that reads it cannot derive two different paths (L70). One stable name per project for the
# findings, overwritten by every review; one stamp per SESSION (see below).
#
# ${TMPDIR%/} rather than $TMPDIR, because macOS sets it with a trailing slash and this path is SHOWN
# to Dan in the reason rather than only used.
#
# NO KEY IS SAID, NEVER DIED ON (claude-config#2639). This hook runs under errexit and pipefail, so
# when shasum was missing the pipe below exited 127 and killed it before it spoke: a spool nobody
# could read or write and a quiet turn looked the same. So the library is asked for the spool key
# first, and a refusal is kept, in the library's own words, to go out with the next review that
# speaks. The hook's own files are then named `no-digest`, shared by every project, which only
# costs the per project cooldown while the fault lasts. The library is the one place that knows why
# there is no key, so its words are used rather than this hook guessing at them.
spool_refused=""
if [ -f "$SPOOL_LIB" ] && ! spool_refused="$(bash "$SPOOL_LIB" key "$proj" "$transcript" 2>&1 >/dev/null)"; then
  spool_refused="SUBAGENT FINDINGS COULD NOT BE READ: no spool key could be made for this project, so the subagent findings spool was not read, and no finding a subagent reports can be written to it until this is fixed. ${spool_refused:-The spool library gave no reason.}"
else
  spool_refused=""
fi
if [ -n "$spool_refused" ]; then
  hash="no-digest"
else
  hash="$(printf '%s' "$proj" | shasum 2>/dev/null | cut -c1-12)" || hash=""
  [ -n "$hash" ] || hash="no-digest"
fi
# Every file the review leaves behind for a later step (the findings, each session's stamp, the seen
# ledger beside it) starts with this, and the sweep below removes only files that do (#1019).
findings_prefix="claude-issue-findings-"
findings_dir="${TMPDIR:-/tmp}"
findings_dir="${findings_dir%/}"
findings_path="${findings_dir}/${findings_prefix}${hash}.txt"
stamp_file="${findings_path%.txt}.$(basename "$transcript" .jsonl).manifest"

# The cooldown is read here, before the spool, because the area check's part below runs only once it
# has passed, and it has to run before the spool is read so a note it makes shows in this same review.
COOLDOWN_SECONDS=1800  # 30 minutes
stamp="${TMPDIR:-/tmp}/claude-feature-issue-review-${hash}.stamp"
now=$(date +%s)
last=0
[ -f "$stamp" ] && last=$(cat "$stamp" 2>/dev/null || echo 0)

# THE AREA CHECK'S WEEKLY LINE AND ITS ESCALATIONS (claude-config#1511). Once the cooldown has passed,
# lib/area-check-review.mjs reads this Mac's area check log: once a week it returns a line of counts
# (never a path, since this review may be in any repository), and for this repository's own files
# that sessions keep proceeding past it spools one note each, which `pending` below then shows. The
# stamp sits beside the log, outside the temp folder macOS cleans, and is written only once the
# reason carrying the line was delivered. A suite reads the real log never: under a test run, or with
# the spool pointed elsewhere, nothing runs unless CLAUDE_AREA_CHECK_DIR names a throwaway folder.
AREA_DIR="${CLAUDE_AREA_CHECK_DIR:-$HOME/.claude-area-check}"
area_line=""
area_said=""
area_failed=""
area_now=""
if [ $(( now - last )) -ge "$COOLDOWN_SECONDS" ] \
  && { [ -n "${CLAUDE_AREA_CHECK_DIR:-}" ] || { [ -z "${CLAUDE_SUITE_RUN_ID:-}" ] && [ -z "${CLAUDE_ISSUE_SPOOL_DIR:-}" ]; }; }; then
  area_why=""
  if ! command -v node >/dev/null 2>&1; then
    area_why="node is not installed"
  else
    area_err="$(mktemp "${TMPDIR:-/tmp}/claude-area-review.XXXXXX" 2>/dev/null)" || area_err="/dev/null"
    area_rc=0
    area_out="$(node --experimental-strip-types --no-warnings "$SELF_DIR/lib/area-check-review.mjs" "$AREA_DIR" "$proj" "$transcript" "$SPOOL_LIB" 2>"$area_err")" || area_rc=$?
    if [ "$area_rc" -ne 0 ]; then
      area_why="its runner exited $area_rc: $(head -n 1 "$area_err" 2>/dev/null | cut -c1-160)"
    elif ! area_now="$(printf '%s' "$area_out" | jq -er '.now | numbers' 2>/dev/null)"; then
      area_why="its runner printed no answer that could be read"
      area_now=""
    else
      area_line="$(printf '%s' "$area_out" | jq -r '.line // empty' 2>/dev/null)" || area_line=""
      area_said="$(printf '%s' "$area_out" | jq -r '(.said // []) | join(" ")' 2>/dev/null)" || area_said=""
    fi
    [ "$area_err" = "/dev/null" ] || rm -f "$area_err"
  fi
  # A runner that cannot run is said once a week, like the line it replaces, never at every review.
  if [ -n "$area_why" ] && { [ ! -f "$AREA_DIR/weekly-line.stamp" ] || [ -n "$(find "$AREA_DIR/weekly-line.stamp" -mmin +10080 2>/dev/null)" ]; }; then
    area_failed="The area check's weekly line could not be built ($area_why), so this Mac's counts are not shown; it is tried again next week."
    case "${CLAUDE_AREA_CHECK_NOW:-}" in ''|*[!0-9]*) area_now=$(( $(date +%s) * 1000 )) ;; *) area_now="$CLAUDE_AREA_CHECK_NOW" ;; esac
  fi
fi

seen_ledger=""
kept_said=""
if [ -f "$SPOOL_LIB" ]; then
  # THE MARKS ARE KEPT BESIDE THE SPOOL, AND BOTH COPIES ARE READ (#1019 follow-up). A clear writes
  # its ledger in the temp directory because it is written exactly when the spool cannot be (L561);
  # macOS's temp cleaner removes a file untouched for about three days, a mark must last the week of
  # the ownership window, and this hook can write the spool. So every temp ledger, every project's and
  # every session's, is copied into its kept copy here, on each working turn rather than only at a
  # render with findings, because the cleaner does not wait for a review. Reading both means a mark is
  # honoured whichever copy holds it, including ledgers written before this shipped.
  kept_said="$(bash "$SPOOL_LIB" keep-ledgers "$findings_dir" "$findings_prefix" 2>&1)" || true
  _kept_ledger="$(bash "$SPOOL_LIB" kept-ledger "$stamp_file" 2>/dev/null)" || _kept_ledger=""
  _temp_ledger="$(bash "$SPOOL_LIB" seen-ledger "$stamp_file" 2>/dev/null)" || _temp_ledger=""
  # One path per line; the reader skips an empty one.
  seen_ledger="$(printf '%s\n%s' "$_kept_ledger" "$_temp_ledger")"
  pending=$(bash "$SPOOL_LIB" pending "$proj" "$transcript" "$render_stamp" "$seen_ledger" 2>/dev/null) || pending=""
  # Only a real FINDING earns the cooldown bypass. A harvest that FAILED is
  # reported whenever the review next speaks, but does not itself make it speak:
  # a recurring failure keeps the spool permanently non-empty, which would fire
  # the review on every single turn and teach us both to ignore it. Nor does a
  # finding this session has already been shown and cannot settle (#1011): the
  # render will not show it again, so it must not make a review fire either.
  if bash "$SPOOL_LIB" has-findings "$proj" "$transcript" "$seen_ledger" >/dev/null 2>&1; then urgent="yes"; fi
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
#
# When it last went out is kept BESIDE THE SPOOL, never in TMPDIR (claude-config#2296): macOS empties
# the temp folder of anything untouched for about three and a half days, so a stamp there vanished
# mid week and the count came back early with nothing saying why. The library names the path, one
# derivation. A stamp that is missing or unreadable sends the count now, never starts a fresh week,
# and the line says which, so a stamp that keeps disappearing shows up as the note repeating.
MUTED_REPORT_SECONDS="${CLAUDE_ISSUE_MUTED_REPORT_SECONDS:-604800}"  # 7 days
muted_line=""
if [ -f "$SPOOL_LIB" ]; then
  muted_stamp="$(bash "$SPOOL_LIB" muted-stamp "$proj" 2>/dev/null)" || muted_stamp=""
  muted_last=0
  muted_note=""
  if [ -z "$muted_stamp" ] || [ ! -f "$muted_stamp" ]; then
    muted_note="No record of when this count last went out was found, so it is shown now rather than a week after the last one."
  else
    muted_last=$(cat "$muted_stamp" 2>/dev/null) || muted_last=""
    case "$muted_last" in
      ''|*[!0-9]*)
        muted_last=0
        muted_note="The record of when this count last went out ($muted_stamp) could not be read, so it is shown now rather than a week after the last one."
        ;;
    esac
  fi
  if [ $(( $(date +%s) - muted_last )) -ge "$MUTED_REPORT_SECONDS" ]; then
    muted_line=$(bash "$SPOOL_LIB" muted-summary "$proj" "$transcript" 2>/dev/null) || muted_line=""
    if [ -n "$muted_line" ] && [ -n "$muted_note" ]; then muted_line="$muted_line $muted_note"; fi
  fi
fi
# The held-back count stays in the REASON, never in the findings file. This hook
# files those records away and restarts their week on the strength of having
# reported them, so a copy that only exists in a file nobody opened would lose the
# report AND silence the next week of them (L98). The findings file is for the
# findings; anything settled by being shown is shown.

# Throttle: only re-prompt once per cooldown window, tracked per project (read above the spool).
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
# the tree and requiring the reason to name the copy. SELF_DIR, set near the top of this file,
# is that location.
INSTRUCTION="$SELF_DIR/review/issue-review.md"

# The findings go to a file the pointer names, and that file OUTLIVES this hook:
# Claude opens it after the hook has exited, so it is deliberately not a mktemp that
# gets removed on the way out. One stable name per project, overwritten by every
# review, so it reports what is pending now and cannot accumulate.
#
# It also replaces the old ARG_MAX dance. The spool has no natural size limit, and
# nothing here passes it as an argument any more.
#
# ONE SHELL WORD, written for a person to read as well as for bash to run (#1020). The clear line was
# quoted with printf %q, which under the bash macOS ships (3.2) writes a character outside ASCII as one
# raw byte plus octal escapes: the work MacBook's projects sit under `Documents - Dan<U+2019>s MacBook
# Pro`, a reader was shown a replacement character, and a line retyped from what was shown named a
# different directory and so read different keys. A word made only of characters no shell treats
# specially is left bare; anything else is single quoted, which keeps every byte as it is, with each
# single quote inside written as '\''.
shell_word() { # shell_word <string> -> that string as one shell word
  local s="$1" out=""
  case "$s" in
    "") printf "''"; return 0 ;;
    *[!A-Za-z0-9_./:@%+=,-]*) ;;
    *) printf '%s' "$s"; return 0 ;;
  esac
  while :; do
    case "$s" in
      *\'*) out="$out${s%%\'*}'\\''"; s="${s#*\'}" ;;
      *) out="$out$s"; break ;;
    esac
  done
  printf "'%s'" "$out"
}
findings_file=""
if [ -n "$pending" ]; then
  findings_file="$findings_path"
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
  # Quoted with shell_word (below), so a path holding a space is still one argument when the line is
  # run verbatim, and a path holding a character outside ASCII is still READABLE (#1020).
  #
  # AND THE STAMP, as its third argument (claude-config#381). Named per SESSION, not per project like
  # the findings file: two sessions in one project each have a picker open at times, and one render
  # overwriting the other's stamp would hand the first clear a record of records it never showed.
  #
  # When the stamp cannot be put in place there is deliberately NO clear line. A line without one is
  # the old command, which files every record under the key including any harvested while the picker
  # is open, so the honest answer is that these cannot be filed from this review and will come back
  # at the next one (L173, L11).
  #
  # SPENT BOOKKEEPING IS REMOVED FIRST (#1019). Each session that is shown findings leaves a stamp,
  # and a clear that could not rewrite the spool leaves a seen ledger beside it; nothing removed
  # either, so one Slate project held 26 stamps on 2026-10-09. Both are spent once the ownership
  # window has passed: a seen mark stops counting the moment its record is old enough for anybody to
  # claim (`unclaimed`), and a stamp that old names a render long superseded, whose clear line would
  # only be refused. Every project's are swept, not only this one's, because a project that is never
  # reviewed again never sweeps its own. Only at a render that shows findings, because that is the only
  # render that creates any of these files. The count goes into the file the reader opens (L98), ABOVE
  # the clear line, because review/issue-review.md tells the reader the file ends with that line.
  if [ -n "$findings_file" ] && [ -f "$SPOOL_LIB" ]; then
    swept="$(bash "$SPOOL_LIB" sweep-stamps "$findings_dir" "$findings_prefix" 2>&1)" || true
    if [ -n "$swept" ]; then printf '\n%s\n' "$swept" >> "$findings_file" 2>/dev/null || true; fi
  fi
  if [ -n "$findings_file" ]; then
    if [ -n "$render_stamp" ] && [ -s "$render_stamp" ] \
        && mv -f "$render_stamp" "$stamp_file" 2>/dev/null && [ -f "$stamp_file" ]; then
      render_stamp=""
      printf '\nTO FILE THESE, run this line exactly as it stands:\n  bash %s clear %s %s %s\n' \
        "$(shell_word "$SELF_DIR/lib/issue-spool.sh")" "$(shell_word "$proj")" \
        "$(shell_word "$transcript")" "$(shell_word "$stamp_file")" >> "$findings_file" 2>/dev/null || true
    else
      printf '\nTHESE cannot be filed from this review: the record of which spool records it read could not be written, and filing without it would also file anything harvested while the picker is open. There is nothing to run; they stay pending and come back at the next review.\n' \
        >> "$findings_file" 2>/dev/null || true
    fi
  fi
fi

reason_args=(--instruction "$INSTRUCTION" --label "END OF TURN ISSUE REVIEW")
# The transcript lets the helper send a short pointer once this session has already read the
# instruction since its last compaction, rather than another full read (lib/review-reason.py).
reason_args+=(--transcript "$transcript")
if [ -n "$findings_file" ]; then reason_args+=(--findings "$findings_file"); fi
if [ -n "$muted_line" ]; then reason_args+=(--extra "$muted_line"); fi
# A seen ledger that could not be kept beside the spool rides in the REASON, not the findings file:
# a review without findings writes no findings file, and this fault is the same whether or not there
# are findings, so it goes out with whichever review speaks next (L98). It is a SECOND --extra beside
# the held back count, and both go out: lib/review-reason.py collects --extra with action="append",
# which test-review-reason.sh asserts with two of them.
if [ -n "$kept_said" ]; then reason_args+=(--extra "$kept_said"); fi
# A spool no key could be made for rides the same way, with whichever review speaks next, and does not
# make one speak: it is the same fault at every turn until the digest is back (claude-config#2639).
if [ -n "$spool_refused" ]; then reason_args+=(--extra "$spool_refused"); fi
# The area check's weekly line, or why it could not be built, and anything it could not record (#1511).
if [ -n "$area_line" ]; then reason_args+=(--extra "$area_line"); fi
if [ -n "$area_failed" ]; then reason_args+=(--extra "$area_failed"); fi
if [ -n "$area_said" ]; then reason_args+=(--extra "$area_said"); fi

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
    # The reason has already gone out, so a stamp that cannot be written cannot be said here; the
    # next review finds no record and says so in the count's line instead (#2296).
    bash "$SPOOL_LIB" muted-sent "$proj" >/dev/null 2>&1 || true
  fi
  # The week restarts only once the line, or why it could not be built, actually went out (#1511).
  if [ -n "$area_now" ] && { [ -n "$area_line" ] || [ -n "$area_failed" ]; }; then
    mkdir -p "$AREA_DIR" 2>/dev/null && printf '%s' "$area_now" > "$AREA_DIR/weekly-line.stamp" 2>/dev/null || true
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
