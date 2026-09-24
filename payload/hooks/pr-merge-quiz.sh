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
# is exactly what he does not need quizzing on. Two invisible-while-healthy categories are kept IN
# deliberately: failure behavior (error handling, retries, alerting) and a fix to a rare edge case,
# since both change what happens in a real situation. For his own tooling Dan IS the user, so a
# change to how a hook or skill behaves in his sessions counts, while its docs and internals do not.
# A skip is announced in one line rather than done silently, so a wrong judgement is visible and he
# can ask for the quiz anyway.
#
# Guards:
#   - CLAUDE_DETACHED_RUN set: a headless run has no human to quiz. Skip. (Same guard as
#     session-reflection.sh.)
#   - SKIP_PR_QUIZ=1 as an inline prefix on the command: documented override, same style as
#     SKIP_TEST_CHECK / SKIP_STYLE_CHECK / SKIP_CLOSING_CHECK.
#   - A checked in .no-pr-quiz at the root of the repo being merged in: that repo has opted out
#     for good. Skipped with a one line notice, never silently (claude-config#438).
#
# Fails QUIET: any parse error exits 0 with no output, so a hiccup never produces a spurious quiz.

set -uo pipefail

# A headless / detached run has nobody to quiz. Skip before doing any work.
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

payload="$(cat)"


# The library, not a copy: five near copies of this had already drifted (claude-config#102).
# `raw` because the shared matcher does its own splitting and has to see the heredocs intact to
# strip them, and because quoting a command back at somebody with its newlines rewritten shows
# them something they did not type.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0
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
. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || exit 0
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
QUIZ_OPT_OUT_MARKER=".no-pr-quiz"
quiz_repo="$(mt_checkout_dir "$(mt_repo_dir "$cmd" "$cwd")")"
if [ -n "$quiz_repo" ] && [ -f "$quiz_repo/$QUIZ_OPT_OUT_MARKER" ]; then
  msg="PR quiz skipped: $(basename "$quiz_repo") has opted out with $QUIZ_OPT_OUT_MARKER at its root. Delete that file to have merges here quizzed again."
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$msg" '{systemMessage: $m}'
  else
    printf '{"systemMessage":"%s"}\n' "$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
  exit 0
fi

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
qv_breakdown() {
  awk '$1 !~ /^(fired_since_quiet|warned|started)$/ { print $2 + 0, $1 }' "$(qv_file)" 2>/dev/null \
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

  QUIZ_VERDICT="no-repo"
  # WHICH repository, resolved the way gh resolves it: the merge's own --repo, -R or pull
  # request link first, then the directory the merge runs in (claude-config#463, #470). This
  # read asked gh about the session's folder whatever the merge named, so a merge from another
  # project had its label read from a stranger's pull request, or from nothing at all.
  local repo_flag
  repo_flag="$(mt_repo_flag "$cmd")"
  cd "$(mt_repo_dir "$cmd" "$cwd")" 2>/dev/null || return 0

  local slug pr envelope labels
  slug="${repo_flag:-$(mt_remote_slug)}"
  pr="$(mt_pr_number "$cmd")"
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
  ( quiz_is_owed; printf '%s %s\n' "$?" "$QUIZ_VERDICT" > "$gate_out" ) </dev/null >/dev/null 2>&1 &
  gate_pid=$!
  set +m
  gate_t0=$SECONDS
  while kill -0 "$gate_pid" 2>/dev/null && [ $((SECONDS - gate_t0)) -lt "$label_deadline" ]; do sleep 0.1; done
  if kill -0 "$gate_pid" 2>/dev/null; then
    kill -TERM -- "-$gate_pid" 2>/dev/null || kill -TERM "$gate_pid" 2>/dev/null
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
quiz_json="$(cat <<'JSON'
{"decision":"block","reason":"A `gh pr merge` command just ran. Before you do ANYTHING else (do NOT suggest, pick, or start the next issue, and do NOT run the next-issue flow) run a short PR comprehension quiz, then continue normally.\n\nStep 1, confirm it shipped: look at the actual output of the merge command you just ran. If the merge did NOT succeed (it errored, was already merged, needed input, or was a no-op), say so in one line and proceed as normal. Do NOT quiz on a merge that did not happen.\n\nStep 2, the user-facing gate, and this is the ONLY thing that decides whether to quiz at all: read what shipped (`gh pr view <number> --json title,body,url` and `gh pr diff <number>`; if no number was given, resolve the PR for the merged branch first). Quiz ONLY if a person using this thing could notice a difference. Any of these counts: what they see (a screen, copy, a label, a price, an email, an alert), what they interact with (a flow, a control, an input, a command), what they receive and when (a notification, a schedule, the timing of something going out), what happens when something goes wrong (error handling, a retry, alerting, an error message), or a fix to a rare edge case, since that situation now behaves differently. When the repo you merged in is Dan's own tooling (a hook, a skill, a gate, a script, his Claude config), Dan IS the user: a change to how it behaves in his sessions is user-facing.\n\nSkip the quiz when what shipped is ONLY internal. These never quiz: tests, fixtures, and test infrastructure; documentation of any kind in any repo, including README, CLAUDE.md, lessons, plan docs, and code comments; refactors and internal restructuring, meaning how the program works inside; performance work, even a speedup someone would feel; build, CI, dependencies, version bumps, formatting, whitespace, and config plumbing; and groundwork that ships nothing visible yet, such as a column nothing reads or a module nothing calls. How the program works inside is never a reason to quiz.\n\nOn a skip, say so in ONE line that names what you judged and what you actually saw, for example: Skipping quiz, nothing user-facing shipped (test coverage plus a refactor of the matcher). Do not skip silently, because Dan has to be able to see the judgement and say 'quiz me anyway' when it is wrong. Then carry on as normal.\n\nA mixed change: if ANY user-facing change is in the diff then the quiz fires, however small that part is and however large the internal part. But draw every question only from the user-facing part, and never ask about the internal, test, or documentation parts even when they are most of what shipped.\n\nStep 3, quiz: otherwise write 1 to 4 questions, scaled to how much of the USER-FACING part shipped and not the size of the whole diff (a one line copy change riding along with a big refactor gets 1; a substantial user-facing feature gets 3 or 4). Every question must be about the current behavior of the system as it stands NOW that this change has shipped, asked in the present tense, in plain language. Prefer a concrete scenario whenever one fits: name a situation and ask what happens in it now (for example, 'a user with no saved payment method opens checkout, what happens?'). FORBIDDEN, with no exceptions: the old behavior or what anything used to do, before and after comparisons, what problem this solved or what bug it fixed, why the change was needed, and code trivia like file names or function names. If a question only makes sense to someone who already knows the state before the change, it is the wrong question: rewrite it as a question about how the system behaves now. Ask them ONE AT A TIME, one AskUserQuestion picker per question, each with plausible concrete options. ANTI-GAMING, this matters: vary which option is the correct one from question to question and do NOT default to putting the correct answer first (choosing the first option must never be a winning strategy). Give NO tell: do not mark any option 'Recommended', and keep all options similar in length, specificity, and plausibility so the answer is not guessable from shape. After each answer: if it is correct, just move on with a quiet check mark, no explanation. If it is wrong, state the correct current behavior briefly in plain language and in the present tense, without describing the old behavior or what the change did to it.\n\nStep 4, a wrong answer is a product signal, not just a miss: the option Dan picked is the behavior he EXPECTED, so the shipped behavior may be the thing that is wrong. Right after correcting him, ask with ONE AskUserQuestion picker whether the behavior should stay as it is or become what he expected. Give at least three options: keep it as it shipped, change it to what he picked, and log it and decide later. If he wants it changed or logged, do NOT start coding in the middle of the quiz: open a GitHub issue in the repo you just merged in, stating the expected behavior in his words and the behavior that ships today, then carry on with the remaining questions. Quiz answers are never logged anywhere; the only thing that persists is an issue he asks for. Only after every question is answered, and any issue he asked for is opened, may you go on to the next issue."}
JSON
)"

# Appended through jq rather than by rebuilding the reason, because the reason is a single
# JSON string carrying its own escapes and re-quoting it by hand is how they get lost.
if [ -n "$notice" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$quiz_json" | jq -c --arg extra "$notice" '.reason = .reason + $extra'
else
  printf '%s' "$quiz_json"
fi
