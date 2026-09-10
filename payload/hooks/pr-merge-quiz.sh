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
  # An early exit, not the safeguard: gh's absence is answered again below, where
  # mt_pr_view finds nothing and this returns 0 anyway. Kept because it saves the
  # whole auth dance, and named so nobody reads it as the thing deciding.
  command -v gh >/dev/null 2>&1 || return 0
  command -v node >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  cd "$(mt_repo_dir "$cmd" "$cwd")" 2>/dev/null || return 0

  local slug pr envelope labels verdict
  slug="$(mt_remote_slug)"
  pr="$(mt_pr_number "$cmd")"
  envelope="$(mt_pr_view "$pr" "number,url,labels" "$slug")"
  [ "$(printf '%s' "$envelope" | jq -r '.found // false' 2>/dev/null)" = "true" ] || return 0

  labels="$(printf '%s' "$envelope" | jq -c '.view.labels // []' 2>/dev/null)"
  [ -n "$labels" ] || return 0

  verdict="$(printf '%s' "$labels" | HOOK_DIR="$HOOK_DIR" node -e '
    var entry = require(process.env.HOOK_DIR + "/lib/changelog-entry.js");
    var raw = "";
    process.stdin.on("data", function (d) { raw += d; });
    process.stdin.on("end", function () {
      var labels;
      try { labels = JSON.parse(raw); } catch (e) { process.stdout.write("unknown"); return; }
      var kinds = entry.changelogLabels(labels);
      if (!kinds.length) { process.stdout.write("unknown"); return; }
      process.stdout.write(kinds.indexOf(entry.VISIBLE) === -1 ? "quiet" : "visible");
    });
  ' 2>/dev/null)"

  [ "$verdict" = "quiet" ] && return 1
  return 0
}

quiz_is_owed || exit 0

# Fire: hand Claude an instruction to run the comprehension quiz before moving on. The reason is a
# single JSON string; newlines are \n. Kept free of dashes and emoji per the writing-style rule.
cat <<'JSON'
{"decision":"block","reason":"A `gh pr merge` command just ran. Before you do ANYTHING else (do NOT suggest, pick, or start the next issue, and do NOT run the next-issue flow) run a short PR comprehension quiz, then continue normally.\n\nStep 1, confirm it shipped: look at the actual output of the merge command you just ran. If the merge did NOT succeed (it errored, was already merged, needed input, or was a no-op), say so in one line and proceed as normal. Do NOT quiz on a merge that did not happen.\n\nStep 2, the user-facing gate, and this is the ONLY thing that decides whether to quiz at all: read what shipped (`gh pr view <number> --json title,body,url` and `gh pr diff <number>`; if no number was given, resolve the PR for the merged branch first). Quiz ONLY if a person using this thing could notice a difference. Any of these counts: what they see (a screen, copy, a label, a price, an email, an alert), what they interact with (a flow, a control, an input, a command), what they receive and when (a notification, a schedule, the timing of something going out), what happens when something goes wrong (error handling, a retry, alerting, an error message), or a fix to a rare edge case, since that situation now behaves differently. When the repo you merged in is Dan's own tooling (a hook, a skill, a gate, a script, his Claude config), Dan IS the user: a change to how it behaves in his sessions is user-facing.\n\nSkip the quiz when what shipped is ONLY internal. These never quiz: tests, fixtures, and test infrastructure; documentation of any kind in any repo, including README, CLAUDE.md, lessons, plan docs, and code comments; refactors and internal restructuring, meaning how the program works inside; performance work, even a speedup someone would feel; build, CI, dependencies, version bumps, formatting, whitespace, and config plumbing; and groundwork that ships nothing visible yet, such as a column nothing reads or a module nothing calls. How the program works inside is never a reason to quiz.\n\nOn a skip, say so in ONE line that names what you judged and what you actually saw, for example: Skipping quiz, nothing user-facing shipped (test coverage plus a refactor of the matcher). Do not skip silently, because Dan has to be able to see the judgement and say 'quiz me anyway' when it is wrong. Then carry on as normal.\n\nA mixed change: if ANY user-facing change is in the diff then the quiz fires, however small that part is and however large the internal part. But draw every question only from the user-facing part, and never ask about the internal, test, or documentation parts even when they are most of what shipped.\n\nStep 3, quiz: otherwise write 1 to 4 questions, scaled to how much of the USER-FACING part shipped and not the size of the whole diff (a one line copy change riding along with a big refactor gets 1; a substantial user-facing feature gets 3 or 4). Every question must be about the current behavior of the system as it stands NOW that this change has shipped, asked in the present tense, in plain language. Prefer a concrete scenario whenever one fits: name a situation and ask what happens in it now (for example, 'a user with no saved payment method opens checkout, what happens?'). FORBIDDEN, with no exceptions: the old behavior or what anything used to do, before and after comparisons, what problem this solved or what bug it fixed, why the change was needed, and code trivia like file names or function names. If a question only makes sense to someone who already knows the state before the change, it is the wrong question: rewrite it as a question about how the system behaves now. Ask them ONE AT A TIME, one AskUserQuestion picker per question, each with plausible concrete options. ANTI-GAMING, this matters: vary which option is the correct one from question to question and do NOT default to putting the correct answer first (choosing the first option must never be a winning strategy). Give NO tell: do not mark any option 'Recommended', and keep all options similar in length, specificity, and plausibility so the answer is not guessable from shape. After each answer: if it is correct, just move on with a quiet check mark, no explanation. If it is wrong, state the correct current behavior briefly in plain language and in the present tense, without describing the old behavior or what the change did to it.\n\nStep 4, a wrong answer is a product signal, not just a miss: the option Dan picked is the behavior he EXPECTED, so the shipped behavior may be the thing that is wrong. Right after correcting him, ask with ONE AskUserQuestion picker whether the behavior should stay as it is or become what he expected. Give at least three options: keep it as it shipped, change it to what he picked, and log it and decide later. If he wants it changed or logged, do NOT start coding in the middle of the quiz: open a GitHub issue in the repo you just merged in, stating the expected behavior in his words and the behavior that ships today, then carry on with the remaining questions. Quiz answers are never logged anywhere; the only thing that persists is an issue he asks for. Only after every question is answered, and any issue he asked for is opened, may you go on to the next issue."}
JSON
