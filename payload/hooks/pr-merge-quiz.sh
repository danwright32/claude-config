#!/usr/bin/env bash
#
# pr-merge-quiz.sh
# Claude Code PostToolUse(Bash) hook.
#
# Goal: the moment a PR is MERGED in a session (Claude running `gh pr merge`, or the
# `scripts/merge-when-green.sh` wrapper that merges internally, for Dan), gate the workflow with a
# short comprehension quiz about what just shipped, so Dan cannot be swept on to the next issue
# without understanding the change that just went out.
#
# Why PostToolUse and not Pre: the quiz is about what SHIPPED, so it has to come after the merge
# lands. Firing before would quiz a PR that has not merged yet, and blocking pre-merge would stop
# the merge itself.
#
# Division of labour, and it is deliberate:
#   - This shell hook owns TWO decisions, and no more. First: did this command merge a PR? Second:
#     does the merged PR's changelog label say, in a person's own words set at PR time, that nobody
#     would notice? Only the second can silence the quiz, and only on a positive reading; every way
#     of failing to read it fires (claude-config#348).
#   - Everything that needs JUDGEMENT is still handed to Claude in the emitted instruction, because
#     Claude can see things the shell cannot: the REAL command output (so it knows whether the merge
#     actually succeeded or errored) and the DIFF (so it knows whether anything USER-FACING shipped,
#     which is the only thing that earns a quiz). A shell script cannot read the tool's exit status
#     reliably from the hook payload, and cannot read a diff at all. So it does not try, and the
#     label narrows what reaches Claude rather than replacing what Claude decides.
#
# The matcher is lib/merge-target.sh's, shared with the blocking merge gates. It reads the
# LEADING TOKENS of each shell segment, never the whole string, so a command whose payload merely
# mentions a merge (an echo, an issue comment, a heredoc) does not fire. That is the
# command-vs-payload distinction check-closing-keyword.sh had to learn the hard way, and the
# blocking gates learned it late (claude-config#349).
#
# What the quiz may ask (Dan's spec, 2026-07-29): only how the system behaves NOW that the change
# has shipped, in the present tense, ideally as a concrete scenario. Questions about the old
# behavior, before and after comparisons, and what the change fixed or why it was needed are out.
# Dan already knows the problem he asked for; what he needs to hold is the state of the product
# today. test-pr-merge-quiz.sh pins this into the emitted instruction so an edit cannot drop it.
#
# WHEN it may ask at all (Dan's spec, 2026-08-03): only when the merge changes something a person
# using the thing could notice. Tests, docs, refactors, performance work, build and CI, and
# groundwork that ships nothing visible yet are all skipped, because "how the program works inside"
# is exactly what he does not need quizzing on. Failure behavior (error handling, retries) is kept
# IN deliberately, since it changes what happens in a real situation. BUG FIXES are skipped, a
# rare edge case fix included (Dan, 2026-09-07: "skip quiz. this is a bug fix, not a change";
# written into the hook 2026-10-15, reversing the 2026-08-03 rule that counted an edge case fix
# in): a fix makes the product do what it always should have, so the quiz is for deliberate
# changes only. The instruction was cut from 5,213 to about 2,300 characters the same day, held
# under 2,600 by test-pr-merge-quiz.sh, since every quizzed merge put it in the transcript for every
# later request to re-read. For his own
# tooling Dan IS the user, so a
# change to how a hook or skill behaves in his sessions counts, while its docs and internals do not.
# A skip is announced in one line rather than done silently, so a wrong judgement is visible and he
# can ask for the quiz anyway.
#
# Guards:
#   - CLAUDE_DETACHED_RUN set: a headless run has no human to quiz. Skip. (Same guard as
#     session-reflection.sh.)
#   - Sleep mode on (lib/sleep.sh's sleep_active): Dan is asleep, so there is nobody to quiz. Skip.
#   - SKIP_PR_QUIZ=1 as an inline prefix on the command: documented override, same style as
#     SKIP_TEST_CHECK / SKIP_STYLE_CHECK / SKIP_CLOSING_CHECK.
#   - A checked in .no-pr-quiz at the root of the repo being merged in: that repo has opted out
#     for good. Skipped with a one line notice, never silently (claude-config#438).
#   - A snooze for this session (pr-merge-quiz.sh --snooze-session <id>, the command the quiz
#     itself names): every later merge in that session is skipped with a one line notice
#     (claude-config#623).
#   - A merge command still running in the background (moved there by the 600 s limit, or started
#     with run_in_background): the quiz is HELD, not skipped, and asked at the first turn end after
#     GitHub says it merged, by this script registered as a Stop hook with --release-held
#     (claude-config#1768, the block above release_held).
#
# Fails QUIET: any parse error exits 0 with no output, so a hiccup never produces a spurious quiz.

set -uo pipefail

# SKIPPED FOR THE REST OF A SESSION (claude-config#623). Dan answered "skip" about 13 times across 8
# Sonar sessions, once as "skip all quizzes for the rest of this session", and that held only while
# Claude remembered it (L57). So the snooze is a file this hook reads, one per session id, set by the
# command the quiz instruction names with this session's id already in it:
#   pr-merge-quiz.sh --snooze-session <session id>
# Kept beside the verdict counts, outside ~/.claude (anything there syncs to the other Mac, and a
# session's snooze is this Mac's alone). It ends with the session, since no other session carries
# that id, and it EXPIRES after SNOOZE_KEEP_DAYS whatever happens, because the read below refuses an
# older one (L523: a suppression carries its expiry; #790 found the expiry had only been the sweep,
# which runs only when another snooze is written). Each snooze written also clears the expired ones,
# so the folder cannot grow without end.
#
# Handled ABOVE the detached run exit: that exit is about having nobody to quiz, and a command
# asked for by name must never exit 0 having done nothing and said nothing (#790, L98).
SNOOZE_KEEP_DAYS=14
snooze_dir() { printf '%s/snoozed' "${CLAUDE_QUIZ_VERDICT_DIR:-$HOME/.claude-quiz-verdicts}"; }
# A session id is Claude Code's uuid; anything else is refused rather than made into a path.
valid_session_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]{7,63}$ ]]; }
if [ "${1:-}" = "--snooze-session" ]; then
  if ! valid_session_id "${2:-}"; then
    echo "pr-merge-quiz: '${2:-}' is not a session id, so nothing was snoozed. Use the exact command the quiz named." >&2
    exit 2
  fi
  if ! mkdir -p "$(snooze_dir)" 2>/dev/null || ! date '+%Y-%m-%dT%H:%M:%S%z' > "$(snooze_dir)/$2" 2>/dev/null; then
    echo "pr-merge-quiz: could not write the snooze under $(snooze_dir), so merges in this session will still be quizzed." >&2
    exit 1
  fi
  find "$(snooze_dir)" -type f -mtime +"$SNOOZE_KEEP_DAYS" -delete 2>/dev/null || true
  echo "PR quiz snoozed for the rest of this session (session $2). Other sessions are still quizzed."
  exit 0
fi
# A snooze in force: written for this session and not yet past its expiry.
snooze_in_force() {  # $1 = session id
  local f
  f="$(snooze_dir)/$1"
  [ -f "$f" ] || return 1
  [ -n "$(find "$f" -type f -mtime -"$SNOOZE_KEEP_DAYS" -print 2>/dev/null)" ]
}

# A headless / detached run has nobody to quiz. Skip before doing any work.
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0
# Nor does a Mac in sleep mode (claude-config#841): Dan is asleep, so the quiz stands down rather
# than holding an overnight session on a question nobody can answer. Unreadable counts as awake.
if . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sleep.sh" 2>/dev/null && sleep_active; then
  exit 0
fi

# HELD UNTIL THE MERGE HAS HAPPENED (claude-config#1768). A merge command that passes the Bash
# tool's 600 s foreground limit is moved to the background, and PostToolUse fires right then, before
# anything merged: in PostRoll on 2026-10-26 the quiz was demanded at 3:41 PM ET and the merge landed
# at 3:43 PM ET (wait_for_checks.py waiting on a 12 minute CI run). The quiz is about what SHIPPED,
# so for such a run it is HELD instead: one JSON line per held command, in a file per session beside
# the verdict counts (outside ~/.claude, since a hold is this Mac's alone), and this same script,
# registered as a Stop hook with --release-held, asks GitHub at each turn end and releases the quiz
# at the first one after it says the pull request merged. The same shape as is it live's card for a
# merge helper run in the background.
#
# How a backgrounded run is told from a finished one: Claude Code says so in tool_response. The
# moved PostRoll call carried {"backgroundTaskId": "b1y5zlrqd", "timedOutAfterMs": 600000} there, and
# a run_in_background call reached a PostToolUse hook with backgroundTaskId in tool_response
# (measured with a headless run, 2026-10-26). A finished call carries no backgroundTaskId.
#
# A released hold is run through this script's ordinary path, with the payload the merge came in on,
# so the opt out, the snooze and the label gate all judge it as they judge any merge, at the time it
# actually merged. Released only when GitHub says MERGED; dropped, said in one line, when it says
# CLOSED; kept, silently, while it is OPEN or GitHub does not answer, since that is a quiz delayed,
# never one lost. NEVER dropped for its age (Dan, 2026-10-26, "Never drop it"): a pull request that
# merges days later still gets its quiz. The one thing that ends a hold unasked is the sweep in
# quiz_hold (sweep_ended_holds) of a file untouched for two days whose session the session registry
# says has ended (#1787). An idle session keeps its file however old it is, since a session with no
# turn end never rewrites it.
held_dir() { printf '%s/held' "${CLAUDE_QUIZ_VERDICT_DIR:-$HOME/.claude-quiz-verdicts}"; }

# WHAT THE GATE DECIDED, kept so a gate that never fires is visible (claude-config#354).
#
# The label gate below fails open on every route, which is right, but it makes a gate that
# has never once silenced a quiz indistinguishable from one that is working and simply
# meeting a visible change every time. Dan would go on declining quizzes exactly as before
# with nothing reporting that the fix was inert (L557).
#
# One line per VERDICT KIND, never one per merge, so the file is a handful of lines however
# many merges pass through it and nothing has to drain it (L526). Each fail open route gets
# its own name, because "the gate never skips" and "gh has answered nothing for a fortnight"
# are different readings needing different remedies (L11).
#
# A named seam with its default OUTSIDE ~/.claude, the same shape as the issue spool's:
# anything under ~/.claude auto pushes to the other Mac within seconds, and a counter that
# ticks on every merge is not config.
#
# Every write here is best effort. A counter that cannot be written must never stop a quiz.
#
# It ASSUMES IT RUNS TWICE and accepts what that costs, rather than not having been asked:
# Dan runs concurrent sessions on one machine, so two merges can read and write this file
# at once. The write is a rewrite to a temporary file followed by a mv, which is atomic, so
# the file cannot be left half written and no reader ever sees a torn one. What a race can
# lose is one increment, which delays the notice by a merge. A lock for that would be a
# lock taken on every merge to protect a diagnostic count, so the trade is stated here
# rather than defended by a mechanism nothing else needs.
#
# Defined HERE, above the held quiz release, because the release (--release-held, below) returns
# before the rest of the script runs, and it counts too: a GitHub answer it cuts short at its
# deadline or its budget is recorded as `cut` (claude-config#1817). Defined further down, the
# release could never reach them, and a cut answer read as fewer quizzes rather than quizzes cut.
# Nothing here reads the PostToolUse payload, which is still read after the release, so only the
# place these are defined moved.
QUIZ_VERDICT_THRESHOLD="${CLAUDE_QUIZ_VERDICT_THRESHOLD:-10}"

qv_file() { printf '%s/counts' "${CLAUDE_QUIZ_VERDICT_DIR:-$HOME/.claude-quiz-verdicts}"; }

qv_get() {  # $1 = key ; prints its number, 0 when absent
  awk -v k="$1" '$1 == k { print $2 + 0; found = 1 } END { if (!found) print 0 }' \
    "$(qv_file)" 2>/dev/null || printf '0'
}

qv_set() {  # $1 = key, $2 = value (absolute), or $1 = key with $2 = + to increment
  local file tmp
  file="$(qv_file)"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  [ -f "$file" ] || : > "$file" 2>/dev/null || return 0
  tmp="$file.$$"
  awk -v k="$1" -v v="$2" '
    BEGIN { seen = 0 }
    $1 == k { print k, (v == "+" ? $2 + 1 : v); seen = 1; next }
    { print }
    END { if (!seen) print k, (v == "+" ? 1 : v) }
  ' "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# The counts, most frequent first, as one readable phrase. This IS the diagnosis: no-label
# says the repo does not use the convention, no-answer says gh is not answering at all.
# Only what the LABEL GATE recorded: the snooze, a hold and the release's cut answers are other
# decisions, kept under their own names, and listing them here would read as the gate failing (L11).
qv_breakdown() {
  awk '$1 !~ /^(fired_since_quiet|warned|started|snoozed|held|cut)$/ { print $2 + 0, $1 }' "$(qv_file)" 2>/dev/null \
    | sort -rn \
    | awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }'
}

qv_record() {  # $1 = verdict
  qv_set "$1" +
  if [ "$1" = "quiet" ]; then
    qv_set fired_since_quiet 0
    qv_set warned 0
  else
    qv_set fired_since_quiet +
  fi
}

# The notice, once, when the gate has run the threshold's worth of quizzes without silencing
# one. Cleared by a quiet verdict, so if the gate starts working and later stops again it
# says so again rather than staying silent for ever (L523). A notice repeated on every merge
# is what teaches somebody to skim the whole instruction (L36).
qv_notice() {
  local fired warned
  fired="$(qv_get fired_since_quiet)"
  warned="$(qv_get warned)"
  [ "$warned" = "0" ] || return 0
  [ "$fired" -ge "$QUIZ_VERDICT_THRESHOLD" ] 2>/dev/null || return 0
  qv_set warned 1
  printf '\n\nSAY THIS TO DAN IN ONE LINE FIRST, then run the quiz as normal: the changelog label gate has now run %s times without once silencing a quiz. What it has recorded: %s. If those were all genuinely user facing changes then nothing is wrong. If they were not, the gate is not reading the label, and that breakdown names the step that is failing.' \
    "$fired" "$(qv_breakdown)"
}

# EACH GITHUB QUESTION HAS ITS OWN DEADLINE, AND THE RELEASE A BUDGET (claude-config#1786). The release
# is a Stop hook with a 60 second timeout (settings.hooks.json), and a hook the harness kills says
# nothing: before this, one hung answer from GitHub cost every hold in the file a turn. So each
# question is asked through lib/bounded-run.sh, which kills the whole process tree it started (gh,
# and the accounts walk mt_pr_view makes), and an answer cut at its deadline counts as no answer:
# that hold is kept for the next turn end, and the release goes on to the next one.
#
# THE NUMBERS, settings rather than measured limits:
#   - QUIZ_RELEASE_ASK_SECONDS, 10 a question. A healthy read of a merged pull request took 0.29,
#     0.30 and 0.31 s on 2026-10-27 (load 15 on 12 cores), and a read that walks the other logged in
#     accounts adds about 2 s an account (merge-target.sh, #1173), so 10 s is far past a slow healthy
#     answer, and a hung one costs the hook a sixth of its timeout.
#   - QUIZ_RELEASE_BUDGET_SECONDS, 40 for the whole release. Past it nothing more is asked, and each
#     question is cut to what is left, so however many holds hang, the last question ends by 40 s.
#     The one released quiz that can follow runs the label gate under its own 8 s deadline
#     (QUIZ_LABEL_DEADLINE_SECONDS, below), which still ends inside 60.
# A hold NOT asked because the budget ran out is written back AHEAD of the ones that were asked, so
# a pull request whose answer keeps hanging cannot starve the holds behind it turn after turn.
#
# Asked in a child bash because bounded_run runs a command, never a shell function, and mt_pr_view
# is one. Its standard error is dropped there, since bounded_run hands back both streams as one and
# the envelope is read as JSON.
RELEASE_ASK_SECONDS="${QUIZ_RELEASE_ASK_SECONDS:-10}"
# The one test of a whole number above zero, 00 included as zero (claude-config#1948). Missing, the
# shell names the missing function and each default is used.
# shellcheck source=lib/whole-number.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/whole-number.sh" 2>/dev/null
whole_above_zero "$RELEASE_ASK_SECONDS" RELEASE_ASK_SECONDS || RELEASE_ASK_SECONDS=10
RELEASE_BUDGET_SECONDS="${QUIZ_RELEASE_BUDGET_SECONDS:-40}"
whole_above_zero "$RELEASE_BUDGET_SECONDS" RELEASE_BUDGET_SECONDS || RELEASE_BUDGET_SECONDS=40
held_ask() {  # $1 = folder to ask in, $2 = pr, $3 = remote slug, $4 = --repo value ; prints mt_pr_view's envelope, or nothing
  local left secs
  left=$((RELEASE_BUDGET_SECONDS - SECONDS))
  [ "$left" -gt 0 ] || return 1
  secs="$RELEASE_ASK_SECONDS"; [ "$left" -lt "$secs" ] && secs="$left"
  bounded_run "$secs" bash -c '
    exec 2>/dev/null </dev/null
    . "$1/lib/push-scope.sh" && . "$1/lib/merge-target.sh" && cd "$2" && mt_pr_view "$3" "number,state,mergedAt,url" "$4" "$5"
  ' held-ask "$HOOK_DIR" "$1" "$2" "$3" "$4"
  # Cut short at its deadline, or at what was left of the budget: counted, so a release that keeps
  # cutting shows in the counts rather than as quizzes that never came (#1817, L357).
  if [ "$BOUNDED_RC" = 124 ]; then
    qv_set cut +
    return 1
  fi
  printf '%s' "$BOUNDED_OUT"
}

release_held() {
  command -v jq >/dev/null 2>&1 || return 0
  local stop sid f g rec keep="" unasked="" reasons="" notes="" open unknown merged closed
  local m_dir m_repo m_slug m_pr envelope state num child r msg
  stop="$(cat)"
  # Cleaned when the shared reader loaded: a lone surrogate escape in the last message made jq read
  # no session, and every held quiz waited for another stop (claude-config#1944). Without it the
  # payload is read as it came, as before.
  [ "$ps_loaded" = 1 ] && stop="$(ps_clean_payload "$stop")"
  sid="$(printf '%s' "$stop" | jq -r '.session_id // ""' 2>/dev/null)"
  valid_session_id "$sid" || return 0
  f="$(held_dir)/$sid"
  # Taken by RENAMING, so a hold written while this runs lands in a fresh file and is never
  # overwritten. A file left by a release that was stopped part way is taken too, so a hook the
  # harness killed delays a quiz rather than losing it. Kept holds are appended back BEFORE the taken
  # files are removed: a stop between the two asks a quiz twice, the harmless side (L648).
  local -a parts=()
  for g in "$f".releasing.*; do [ -f "$g" ] && parts+=("$g"); done
  if [ -f "$f" ] && mv "$f" "$f.releasing.$$" 2>/dev/null; then parts+=("$f.releasing.$$"); fi
  [ "${#parts[@]}" -gt 0 ] || return 0

  # The one bound every hook shares. Missing, every question is refused, so every hold is kept.
  . "$HOOK_DIR/lib/bounded-run.sh" 2>/dev/null || bounded_run() { BOUNDED_OUT=""; BOUNDED_RC=127; }
  # The holds and each hold's merges are read whole and fed to the loops from here documents, never
  # through process substitution: this hook prints its answer into a pipe, and a child it never
  # waits for can exit during that write, which bash 3.2 then drops (claude-config#1984, L1035). The
  # `x` keeps the files' last byte, so a last line with no newline, which read never took, is left
  # out here too rather than read as a hold.
  local recs merges
  recs="$(cat "${parts[@]}" 2>/dev/null; printf x)" || true
  recs="${recs%x}"
  case "$recs" in *$'\n') ;; *$'\n'*) recs="${recs%$'\n'*}"$'\n' ;; *) recs="" ;; esac
  while IFS= read -r rec <&5; do
    [ -n "$rec" ] || continue
    # The budget spent: kept without asking, and asked first at the next turn end.
    if [ $((RELEASE_BUDGET_SECONDS - SECONDS)) -le 0 ]; then
      unasked+="$rec"$'\n'
      continue
    fi
    open=0; unknown=0; merged=""; closed=""
    # One line per merge, its fields split on 0x1f, never a tab: a tab is whitespace to read, so an
    # empty field between two would vanish and shift the pull request number into the repository.
    merges="$(printf '%s' "$rec" | jq -r '.merges[]? | [.dir // "", .repo // "", .slug // "", .pr // ""] | join("\u001f")' 2>/dev/null)" || true
    # No merges is no pass at all, as it was before, never one pass over an empty line.
    while [ -n "$merges" ] && IFS=$'\x1f' read -r m_dir m_repo m_slug m_pr <&6; do
      # Asked in the folder the merge ran in, or, when that folder is gone (a worktree removed after
      # its merge), anywhere with the repository named, as long as there is a number to ask about.
      if [ -d "$m_dir" ]; then
        envelope="$(held_ask "$m_dir" "$m_pr" "${m_repo:-$m_slug}" "$m_repo")"
      elif [ -n "$m_pr" ] && [ -n "$m_slug" ]; then
        envelope="$(held_ask "$HOME" "$m_pr" "$m_slug" "$m_slug")"
      else
        envelope=""
      fi
      state="$(printf '%s' "$envelope" | jq -r 'if .found then (.view.state // "") else "" end' 2>/dev/null)"
      num="$(printf '%s' "$envelope" | jq -r '.view.number // empty' 2>/dev/null)"
      num="#${num:-$m_pr}"
      case "$state" in
        MERGED) merged="${merged:+$merged, }$num" ;;
        CLOSED) closed="${closed:+$closed, }$num" ;;
        OPEN) open=1 ;;
        *) unknown=1 ;;
      esac
    done 6<<MERGES
$merges
MERGES
    if [ "$open" = 1 ] || [ "$unknown" = 1 ]; then
      keep+="$rec"$'\n'
      continue
    fi
    if [ -z "$merged" ]; then
      notes="${notes:+$notes }PR quiz dropped: ${closed:-the pull request} was closed without merging, so nothing shipped to quiz on."
      continue
    fi
    child="$(printf '%s' "$rec" | jq -c '.payload' 2>/dev/null | bash "$HOOK_DIR/pr-merge-quiz.sh" --merged-from-hold 2>/dev/null)"
    r="$(printf '%s' "$child" | jq -r '.reason // ""' 2>/dev/null)"
    msg="$(printf '%s' "$child" | jq -r '.systemMessage // ""' 2>/dev/null)"
    if [ -n "$r" ]; then
      reasons="${reasons:+$reasons

}The merge command that ran in the background has finished, and GitHub says $merged merged. Its output is in the background task's output file; read that for Step 1.

$r"
    fi
    [ -n "$msg" ] && notes="${notes:+$notes }$msg"
  done 5<<HOLDS
$recs
HOLDS

  if [ -n "$unasked$keep" ]; then
    mkdir -p "$(held_dir)" 2>/dev/null
    printf '%s' "$unasked$keep" >> "$f" 2>/dev/null
  fi
  rm -f "${parts[@]}" 2>/dev/null

  # The systemMessage comes from lib/hook-notice.sh, the one builder of it (#1906); a refusal's
  # decision and reason are added to it by jq.
  if [ -n "$reasons" ]; then
    { jq -nc --arg r "$reasons" '{decision: "block", reason: $r}'; [ -z "$notes" ] || hook_notice_json "$notes"; } | jq -sc add
  elif [ -n "$notes" ]; then
    hook_notice_json "$notes"
  fi
  return 0
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Every systemMessage this prints is built by lib/hook-notice.sh, so it is valid JSON whatever the
# text holds and with or without jq (#1906). release_held needs the object without the exit.
# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
command -v hook_notice_json >/dev/null 2>&1 || hook_notice_json() {
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; }
# The library, not a copy: five near copies of this had already drifted (claude-config#102). Loaded
# before either path, since both read a payload through it (claude-config#1944). Whether it loaded is
# kept, and each path says what its absence costs.
ps_loaded=1
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || ps_loaded=0
if [ "${1:-}" = "--release-held" ]; then
  release_held
  exit 0
fi
# Set only by release_held, for the payload of a merge GitHub has since confirmed: never held again.
merge_confirmed=0
[ "${1:-}" = "--merged-from-hold" ] && merge_confirmed=1

payload="$(cat)"

# A library this hook cannot load is not a merge with no quiz to ask (claude-config#1922): it stopped
# here in silence. Said once, as a systemMessage, on a call whose raw text names a merge.
did_not_run() {   # $1 = the library
  case "$payload" in
    *merge*|*Merge*) hook_allow_notice "PR MERGE QUIZ DID NOT RUN: pr-merge-quiz.sh could not load lib/$1 (reinstall the hooks with claude-sync pull), so whether this command merged a pull request, and the quiz on it, were not asked." PostToolUse ;;
  esac
  exit 0
}
[ "$ps_loaded" = 1 ] || did_not_run push-scope.sh

# `raw` because the shared matcher does its own splitting and has to see the heredocs intact to
# strip them, and because quoting a command back at somebody with its newlines rewritten shows
# them something they did not type. Cleaned first: a lone surrogate escape made jq read nothing
# (claude-config#1944).
payload="$(ps_clean_payload "$payload")"
parsed="$(ps_parse_payload "$payload" raw)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

# Documented override: an inline SKIP_PR_QUIZ=1 prefix.
if grep -Eq '(^|[[:space:];&|])SKIP_PR_QUIZ=1([[:space:]]|$)' <<< "$cmd"; then
  exit 0
fi

# Does any shell segment RUN a merge, as opposed to merely mentioning one? Three
# forms count, and the shared predicate knows all three: the direct command, a
# project's own wrapper (which merges INTERNALLY in a subprocess this hook cannot
# see, so matching the wrapper is the only way the quiz is not silently dodged by
# using the project's own recommended merge command), and `npm run merge`, which
# is how one of those wrappers is invoked.
#
# The matcher used to live HERE, correct, while the two BLOCKING gates shared a
# whole string match in lib/merge-target.sh that fired on any command merely
# naming the phrase. That was the wrong way round: a false positive costs most
# where it denies. It moved into the library and this hook calls it, so the
# advising hook and the blocking gates cannot answer differently
# (claude-config#349).
# shellcheck source=lib/merge-target.sh
. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || did_not_run merge-target.sh
mt_runs_merge "$cmd" || exit 0

# A REPOSITORY CAN OPT OUT, by checking in a marker file at its root (claude-config#438).
#
# Dan asked for no quiz in claude-config, and that decision lived only in a session memory:
# the hook fired on every merge there and the skip was re-decided by judgement each time, five
# times in one session on 2026-09-18. A rule only a memory carries is enforced by nothing, and
# a skip Dan reads five times for a reason that never changes is the one he stops reading, which
# costs the "quiz me anyway" this hook depends on (L57, L36).
#
# The shape is the one lib/merge-target.sh already uses to learn a repo carries its own merge
# tool: a repo relative path whose presence is the declaration, checked in, so the decision
# lives in the repo it is about and travels with every clone and worktree of it.
#
# Resolved from the repo the merge RUNS in (a leading cd wins, then the session cwd walked up
# to its checkout root), the same resolution the label gate below uses, so a merge from a
# subdirectory still finds it and a cd into another repo is judged as that repo.
#
# Checked before the label gate and recorded nowhere in its verdict store: an opted out merge
# is not a quiz the label failed to silence, and counting it there would ring the notice that
# says the gate never works (#354).
#
# Announced, never silent. A skip nobody sees reads exactly like a hook that never fired (L98),
# so it says so in one line straight to Dan, through systemMessage rather than a block, because
# there is nothing for Claude to decide and a block would spend a turn relaying a fixed fact.
#
# EVERY MERGE IN THE COMMAND (claude-config#1082). The merge gates refuse a command merging more
# than one pull request (#1072), so this hook meets one only when an override let it through, and it
# read the first merge alone: an opted out or quietly labelled first merge silenced the quiz for a
# visible second one. So each merge is read where it ran (mt_merge_each), the opt out skips only when
# EVERY merge's repository carries the marker, and the label gate below reads every merge that is not
# opted out. A command running several merges that nothing can read is quizzed, saying so.
QUIZ_OPT_OUT_MARKER=".no-pr-quiz"
merge_lines="$(mt_merge_each "$cmd" "$cwd")"; each_rc=$?
merges_unread=0; [ "$each_rc" -eq 2 ] && merges_unread=1
quizzed_lines=""; opted_out_repos=""; merge_count=0
while IFS= read -r m <&3; do
  [ -n "$m" ] || continue
  merge_count=$((merge_count + 1))
  quiz_repo="$(mt_checkout_dir "${m%%$'\t'*}")"
  if [ -n "$quiz_repo" ] && [ -f "$quiz_repo/$QUIZ_OPT_OUT_MARKER" ]; then
    case " $opted_out_repos " in *" $(basename "$quiz_repo") "*) ;; *) opted_out_repos="${opted_out_repos:+$opted_out_repos }$(basename "$quiz_repo")" ;; esac
  else
    quizzed_lines+="$m"$'\n'
  fi
done 3<<< "$merge_lines"
if [ "$merges_unread" = 0 ] && [ "$merge_count" -gt 0 ] && [ -z "$quizzed_lines" ]; then
  msg="PR quiz skipped: $opted_out_repos has opted out with $QUIZ_OPT_OUT_MARKER at its root. Delete that file to have merges here quizzed again."
  [ "$merge_count" -gt 1 ] && msg="PR quiz skipped: every repository this command merged in ($opted_out_repos) has opted out with $QUIZ_OPT_OUT_MARKER at its root. Delete that file to have merges there quizzed again."
  hook_allow_notice "$msg"
fi

# This session's id, for the snooze (#623, the block at the top), which is checked just before the
# label gate below. A payload with no readable session id (no jq, or no id at all) cannot be
# snoozed, so the quiz fires: a missing reader costs a quiz, never a merge skipped in silence (L490).
session_id=""
ps_reader_missing jq || session_id="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"
valid_session_id "$session_id" || session_id=""

# Did anything a person could notice actually ship?
#
# The quiz fired five times in one session on 2026-09-10 and was declined five times,
# every one correctly judged internal, so every merge cost a turn spent declining. Dan
# was offered turning the quiz off and chose to narrow it instead (claude-config#348).
#
# The signal did not exist when this hook was written and does now: PET and Slate
# enforce exactly one of changelog/visible, changelog/technical or changelog/none on
# every merged pull request, through require-changelog-tag.sh. changelog/visible means
# precisely what this hook's own user facing gate means, it is chosen by a person while
# they still hold the change, and it is already enforced at merge.
#
# So this file now owns TWO decisions rather than one, and the division of labour above
# is written that way rather than carrying an exception bolted beside it. The second is
# still narrow: the label says whether to ASK Claude, never what the answer is. The
# instruction keeps its own gate, because the label is a claim by whoever set it and a
# mixed pull request can carry changelog/technical while touching something visible.
#
# Read through lib/changelog-entry.js, the same module the merge gate enforces with, so
# there is one definition of the vocabulary rather than a copy of the three label names
# in shell that would drift from the one being enforced (L370, L611).
#
# FAILS OPEN, on every route: gh missing, node missing, no answer, an unreadable answer,
# an answer about another repo, or no changelog label at all. A hook that silently stops
# asking is worse than one that asks too often, and firing is what already shipped, so
# every repo that does not use the convention keeps working exactly as before.
#
# The cost, stated: a network round trip on a path that had none. Only on a merge, so it
# is bounded, and only after the matcher has already decided a merge happened.
#
# What a silent skip gives up, also stated: Dan asked for silence here (2026-09-10),
# where a skip DECIDED BY CLAUDE is announced in one line so a wrong judgement is
# visible. The difference is that this skip is driven by a label a person set and can
# see on the pull request, rather than by a judgement made out of his sight.
quiz_is_owed() {
  QUIZ_VERDICT="no-gh"
  # An early exit, not the safeguard: gh's absence is answered again below, where
  # mt_pr_view finds nothing and this returns 0 anyway. Kept because it saves the
  # whole auth dance, and named so nobody reads it as the thing deciding.
  command -v gh >/dev/null 2>&1 || return 0
  QUIZ_VERDICT="no-node"
  command -v node >/dev/null 2>&1 || return 0
  QUIZ_VERDICT="no-jq"
  command -v jq >/dev/null 2>&1 || return 0

  # The third tool, and the one this hook never named (claude-config#475). The shared library
  # reads which pull request and which repository the merge names with python3, and without it
  # both come back empty: the label was then read from whatever pull request gh resolves from the
  # current branch, so a quiet record there silenced the quiz for a merge nobody identified. Its
  # own verdict name, because one name covering two causes cannot tell them apart (L11). Only the
  # direct form needs the reader: a wrapper names its number as a positional argument the shell
  # reads, and names no repository at all.
  if mt_is_pr_merge "$cmd" && mt_reader_missing; then
    QUIZ_VERDICT="no-python3"
    return 0
  fi

  # Several merges nothing could read (#1082): which pull requests they were is unknown, so no label
  # can silence the quiz.
  QUIZ_VERDICT="unread-merges"
  [ "$merges_unread" = 1 ] && return 0

  # Every merge that is not opted out, and the quiz is owed when ANY of them owes it (#1082): the
  # first merge's quiet label used to silence a visible second one. All quiet is quiet.
  local m
  while IFS= read -r m <&4; do
    [ -n "$m" ] || continue
    quiz_owed_for "${m%%$'\t'*}" "$(printf '%s' "$m" | cut -f2)" "${m##*$'\t'}" && return 0
  done 4<<< "$quizzed_lines"
  [ "$QUIZ_VERDICT" = "quiet" ] && return 1
  return 0
}

# One merge's label: 0 when it owes a quiz (QUIZ_VERDICT says why), 1 when its label says quiet.
quiz_owed_for() {  # $1 = the directory the merge runs in, $2 = the repository it names or empty, $3 = its number or empty
  QUIZ_VERDICT="no-repo"
  # WHICH repository, resolved the way gh resolves it: the merge's own --repo, -R or pull
  # request link first, then the directory the merge runs in (claude-config#463, #470). This
  # read asked gh about the session's folder whatever the merge named, so a merge from another
  # project had its label read from a stranger's pull request, or from nothing at all.
  local repo_flag="$2"
  cd "$1" 2>/dev/null || return 0

  local slug pr="$3" envelope labels
  slug="${repo_flag:-$(mt_remote_slug)}"
  envelope="$(mt_pr_view "$pr" "number,url,labels" "$slug" "$repo_flag")"
  if [ "$(printf '%s' "$envelope" | jq -r '.found // false' 2>/dev/null)" != "true" ]; then
    # Three different faults, three names. An answer about ANOTHER repo means the wrong
    # repository was resolved; a not found means the pull request is not in the repository
    # that was searched, which is a question about the command rather than about gh; and no
    # answer at all means gh is not answering. One name for all three would be a number that
    # cannot tell them apart (L11).
    if [ -n "$(printf '%s' "$envelope" | jq -r '.wrongRepo // ""' 2>/dev/null)" ]; then
      QUIZ_VERDICT="wrong-repo"
    elif [ "$(printf '%s' "$envelope" | jq -r '.notFound // false' 2>/dev/null)" = "true" ]; then
      QUIZ_VERDICT="not-found"
    else
      QUIZ_VERDICT="no-answer"
    fi
    return 0
  fi

  QUIZ_VERDICT="unreadable"
  labels="$(printf '%s' "$envelope" | jq -c '.view.labels // []' 2>/dev/null)"
  [ -n "$labels" ] || return 0

  QUIZ_VERDICT="$(printf '%s' "$labels" | HOOK_DIR="$HOOK_DIR" node -e '
    var entry = require(process.env.HOOK_DIR + "/lib/changelog-entry.js");
    var raw = "";
    process.stdin.on("data", function (d) { raw += d; });
    process.stdin.on("end", function () {
      var labels;
      try { labels = JSON.parse(raw); } catch (e) { process.stdout.write("unreadable"); return; }
      var kinds = entry.changelogLabels(labels);
      if (!kinds.length) { process.stdout.write("no-label"); return; }
      process.stdout.write(kinds.indexOf(entry.VISIBLE) === -1 ? "quiet" : "visible");
    });
  ' 2>/dev/null)"
  case "$QUIZ_VERDICT" in
    quiet|visible|no-label|unreadable) ;;
    *) QUIZ_VERDICT="unreadable" ;;
  esac

  [ "$QUIZ_VERDICT" = "quiet" ] && return 1
  return 0
}

# This session snoozed the quiz (#623). Checked after the opt out and before the label gate: a
# snoozed merge is not a quiz the label failed to silence, so it never touches fired_since_quiet,
# but it IS counted, under its own name, so a skip leaves a trace (#790, L357). Announced in one
# line straight to Dan.
if [ -n "$session_id" ] && snooze_in_force "$session_id"; then
  qv_set snoozed +
  hook_allow_notice "PR quiz skipped: you snoozed it for the rest of this session. A new session quizzes again."
fi

# STILL RUNNING IN THE BACKGROUND (#1768, the block above release_held). Checked after the opt out and
# the snooze, which would skip this merge whenever it lands, and before the label gate, which is read
# when the hold is released. Counted under its own name, so a hold leaves a trace (L357).
#
# A hold needs this session's id (the file it is kept in) and to know which pull requests the command
# merges. Without either it cannot be released, so the quiz fires now as it always did, saying the
# merge was still running: a missing reader costs a quiz asked early, never one skipped (L490).
ran_in_background=0
if [ "$merge_confirmed" = 0 ] && ! ps_reader_missing jq; then
  [ "$(printf '%s' "$payload" | jq -r '[(.tool_input.run_in_background? == true), ((.tool_response? | if type == "object" then .backgroundTaskId else null end) | (type == "string" and length > 0))] | any' 2>/dev/null)" = "true" ] \
    && ran_in_background=1
fi
quiz_hold() {
  local dir merges rec m slug
  dir="$(held_dir)"
  mkdir -p "$dir" 2>/dev/null || return 1
  # Each merge's repository is resolved NOW, while its folder certainly exists: a worktree is often
  # removed straight after its merge, and the release must still be able to ask about it.
  merges="$(while IFS= read -r m <&3; do
      [ -n "$m" ] || continue
      slug="$(printf '%s' "$m" | cut -f2)"
      [ -n "$slug" ] || slug="$(cd "${m%%$'\t'*}" 2>/dev/null && mt_remote_slug)"
      jq -nc --arg dir "${m%%$'\t'*}" --arg repo "$(printf '%s' "$m" | cut -f2)" --arg slug "$slug" --arg pr "${m##*$'\t'}" \
        '{dir: $dir, repo: $repo, slug: $slug, pr: $pr}'
    done 3<<< "$quizzed_lines" | jq -s -c '.')" || return 1
  [ "$merges" != "[]" ] || return 1
  rec="$(printf '%s' "$payload" | jq -c --argjson merges "$merges" --argjson at "$(date +%s)" \
    '{heldAt: $at, merges: $merges, payload: del(.tool_response)}' 2>/dev/null)" || return 1
  [ -n "$rec" ] || return 1
  printf '%s\n' "$rec" >> "$dir/$session_id" 2>/dev/null || return 1
  sweep_ended_holds "$dir"
  return 0
}
# A session that ended with a hold never released leaves its file behind, so files untouched for two
# days are looked at, and one is removed only when the session registry says its SESSION has ended
# (claude-config#1787). Age alone is not evidence: a session left open with no turn end for days
# never rewrites its file, and its quiz must still come (Dan, 2026-10-26, "Never drop it"). The
# registry's own rule decides, through lib/session_registry.py, the one reading the sleep queue uses
# too: ended means closed, silent past five minutes, or no longer in the registry. Any doubt keeps
# the file: no python3, a registry that cannot be read, a record that cannot be read, or a registry
# that does not show THIS session open (then it is not keeping track, and its absences prove nothing).
# A `.releasing.<pid>` file a stopped release left belongs to the session its name begins with.
sweep_ended_holds() {
  local dir="$1" stale ended f sid
  stale="$(find "$dir" -type f -mtime +2 2>/dev/null)"
  [ -n "$stale" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  ended="$(printf '%s\n' "$stale" | sed -e 's#.*/##' -e 's#\.releasing\..*$##' | sort -u \
    | python3 "$HOOK_DIR/lib/session_registry.py" ended "$(( $(date +%s) * 1000 ))" "$session_id" 2>/dev/null)" || return 0
  [ -n "$ended" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sid="${f##*/}"
    sid="${sid%%.releasing.*}"
    grep -qxF -- "$sid" <<< "$ended" && rm -f -- "$f"
  done <<< "$stale"
  return 0
}
background_note=""
if [ "$ran_in_background" = 1 ]; then
  if [ -n "$session_id" ] && [ "$merges_unread" = 0 ] && quiz_hold; then
    qv_set held +
    held_prs="$(while IFS= read -r m <&3; do [ -n "$m" ] && mt_pr_label "${m##*$'\t'}"; [ -n "$m" ] && printf ', '; done 3<<< "$quizzed_lines")"
    held_prs="${held_prs%, }"
    hook_allow_notice \
      "PR quiz held: the merge command is still running in the background, so the quiz waits for the first turn end after GitHub says $held_prs merged." \
      PostToolUse \
      "The PR merge quiz for this command is held, not skipped: the command was moved to the background before it finished, so nothing has merged yet. Do not run the quiz now. A turn end after GitHub says $held_prs merged asks for it."
  fi
  background_note="

This merge command was moved to the background before it finished, so it may not have merged yet, and the quiz could not be held for it. Wait until its output, or \`gh pr view <n> --json state\`, says it merged before Step 1; if it never merges, there is no quiz."
fi

# THE LABEL GATE HAS ITS OWN DEADLINE (claude-config#568). This hook is registered with a 15 second
# timeout, the gate's read goes through mt_pr_view, which asks gh once per logged in account, and a
# hook the harness kills emits NOTHING, which reads exactly like a decision not to quiz (L98). On
# 2026-09-24 two merges in a Slate session got no quiz, both at the end of long turns with gh under
# load, and replaying the hook ruled out every other cause. So:
#   - `started` is counted BEFORE any network read, so a run that dies still leaves a trace (#354);
#   - the gate runs in its own process group (L321) and is given QUIZ_LABEL_DEADLINE_SECONDS
#     (default 8, a chosen number well inside the 15 the settings give the hook, not a measurement);
#   - past that, the whole group is stopped, the verdict is label-timeout, and the quiz FIRES,
#     saying the label could not be read in time. A slow gh costs a quiz that might have been
#     silenced, never a merge that goes unquizzed without a word (L42).
QUIZ_VERDICT=""
qv_set started +
label_deadline="${QUIZ_LABEL_DEADLINE_SECONDS:-8}"
case "$label_deadline" in ''|*[!0-9]*) label_deadline=8 ;; esac
label_timed_out=0
gate_out="$(mktemp "${TMPDIR:-/tmp}/pr-merge-quiz.XXXXXX" 2>/dev/null)" || gate_out=""
if [ -n "$gate_out" ]; then
  set -m
  # Reaped on both paths below before this hook writes anything, and nothing is written while it runs
  # (#1989): a gate exiting while the decision is printed would cut it short under bash 3.2 (L1035).
  ( quiz_is_owed; printf '%s %s\n' "$?" "$QUIZ_VERDICT" > "$gate_out" ) </dev/null >/dev/null 2>&1 &
  gate_pid=$!
  set +m
  gate_t0=$SECONDS
  while kill -0 "$gate_pid" 2>/dev/null && [ $((SECONDS - gate_t0)) -lt "$label_deadline" ]; do sleep 0.1; done
  if kill -0 "$gate_pid" 2>/dev/null; then
    # KILL, which nothing in the gate can ignore, so the wait straight after returns at once. A TERM
    # left a gh that ignored it running after the hook had answered, and the gate unreaped.
    kill -KILL -- "-$gate_pid" 2>/dev/null || kill -KILL "$gate_pid" 2>/dev/null
    wait "$gate_pid" 2>/dev/null
    label_timed_out=1
    gate_rc=0; QUIZ_VERDICT="label-timeout"
  else
    wait "$gate_pid" 2>/dev/null
    read -r gate_rc QUIZ_VERDICT < "$gate_out" 2>/dev/null || { gate_rc=0; QUIZ_VERDICT="unreadable"; }
  fi
  rm -f "$gate_out"
else
  if quiz_is_owed; then gate_rc=0; else gate_rc=1; fi
fi
qv_record "$QUIZ_VERDICT"
[ "$gate_rc" = "1" ] && exit 0
notice="$(qv_notice)"
if [ "$label_timed_out" = 1 ]; then
  notice="$notice

The changelog label on this pull request could not be read in time (gh took longer than ${label_deadline}s), so the quiz fired without it; judge the user facing gate yourself as usual."
fi

# Fire: hand Claude an instruction to run the comprehension quiz before moving on. The reason is a
# single JSON string; newlines are \n. Kept free of dashes and emoji per the writing-style rule.
IFS= read -r -d '' quiz_json <<'JSON' || true
{"decision": "block", "reason": "A `gh pr merge` command just ran. Before ANYTHING else (no next issue, no next-issue flow), run this PR comprehension quiz, then carry on.\n\nStep 1: read the merge command's output. If the merge did not succeed or was a no-op, say so in one line and carry on; never quiz a merge that did not happen.\n\nStep 2, the only gate: read what shipped (`gh pr view <n> --json title,body,url`, `gh pr diff <n>`; with no number, resolve the PR for the merged branch first). Quiz only on a deliberate change a person using it could notice a difference from: what they see, what they interact with, what they receive and when, or what happens when something goes wrong. In Dan's own tooling Dan IS the user. Never quiz on tests, fixtures, documentation of any kind, refactors and internal restructuring, performance work, even a speedup, build, CI, dependencies, config, groundwork that ships nothing visible yet, or bug fixes, including a fix to a rare edge case: a fix makes it do what it was always meant to, and how it works inside is never a reason to quiz. On a skip, write ONE line that names what you judged and what you saw, so Dan can say quiz me anyway. Do not skip silently. If any deliberate user-facing change is in the diff the quiz fires, but ask only from the user-facing part and never ask about the internal, test or documentation parts.\n\nStep 3: 1 to 4 questions, scaled to the user-facing part, not the size of the whole diff. Ask about current behavior, in the present tense, ideally as a concrete scenario. Never ask what anything used to do, what problem it solved, or anything that needs the state before the change; no file or function names. One AskUserQuestion picker per question, plausible options of similar length, the correct position varied, nothing marked Recommended. Right: a quiet check mark. Wrong: state the current behavior briefly, without describing the old behavior.\n\nStep 4: a wrong answer is what Dan expected. Ask in one picker: keep it as it shipped, change it to what he picked, or log it and decide later. For change or log, do NOT start coding in the middle of the quiz: open a GitHub issue in the repo you just merged in with his expected behavior and today's, then continue. Only after every question may you go to the next issue."}
JSON
quiz_json="${quiz_json%$'\n'}"

# Skipping (#623): one skip ends the whole set (skipping question 1 of 2 left question 2 standing
# in two Sonar sessions), and a skip for the rest of the session is the snooze command, named here
# with this session's id so Claude never has to find it. With no id the hook cannot snooze, so the
# sentence offering it is left out rather than naming a command that would do nothing.
skip_note="

Skipping: if Dan answers skip to any question, that skips every remaining question of this quiz, not only the one asked; say so in one line and carry on."
if [ -n "$session_id" ]; then
  # Quoted with printf %q, never by hand: a folder path holding an apostrophe broke the
  # single quoted form (#790), and this is the command Claude is told to run exactly.
  skip_note="$skip_note If he says to skip quizzes for the rest of this session, run exactly this command, then confirm in one line: bash $(printf '%q' "$HOOK_DIR/pr-merge-quiz.sh") --snooze-session $session_id"
fi
notice="$notice$background_note$skip_note"

# More than one merge (#1082): the instruction is written for one, so it names every pull request
# the command merged and asks for each to be judged, rather than leaving Claude to quiz the first.
if [ "$merges_unread" = 1 ]; then
  notice="$notice

This command ran more than one merge, and nothing here could read which pull requests they were. Find each one from the command and its output, and run steps 1 to 3 for EACH of them."
elif [ "$merge_count" -gt 1 ]; then
  merged_list=""
  while IFS= read -r m <&3; do
    [ -n "$m" ] || continue
    m_flag="$(printf '%s' "$m" | cut -f2)"
    m_repo="${m_flag:-$(cd "${m%%$'\t'*}" 2>/dev/null && mt_remote_slug)}"
    merged_list="${merged_list:+$merged_list, }$(mt_pr_label "${m##*$'\t'}") in ${m_repo:-${m%%$'\t'*}}"
  done 3<<< "$quizzed_lines"
  notice="$notice

This command merged more than one pull request: $merged_list. Run steps 1 to 3 for EACH of them, and quiz on every one that shipped something user facing.${opted_out_repos:+ Merges in $opted_out_repos are not quizzed: that repository has opted out with $QUIZ_OPT_OUT_MARKER.}"
fi

# Appended through jq rather than by rebuilding the reason, because the reason is a single
# JSON string carrying its own escapes and re-quoting it by hand is how they get lost.
if [ -n "$notice" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$quiz_json" | jq -c --arg extra "$notice" '.reason = .reason + $extra'
else
  printf '%s' "$quiz_json"
fi
