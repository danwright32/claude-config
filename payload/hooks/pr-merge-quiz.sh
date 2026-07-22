#!/usr/bin/env bash
#
# pr-merge-quiz.sh
# Claude Code PostToolUse(Bash) hook.
#
# Goal: the moment a PR is MERGED in a session (Claude running `gh pr merge` for Dan), gate the
# workflow with a short comprehension quiz about what just shipped, so Dan cannot be swept on to
# the next issue without understanding the change that just went out.
#
# Why PostToolUse and not Pre: the quiz is about what SHIPPED, so it has to come after the merge
# lands. Firing before would quiz a PR that has not merged yet, and blocking pre-merge would stop
# the merge itself.
#
# Division of labour, and it is deliberate:
#   - This shell hook owns exactly ONE decision: did this command merge a PR? If yes, it emits a
#     decision:block whose `reason` is an instruction back to Claude.
#   - Everything that needs judgement is handed to Claude in that instruction, because Claude can
#     see things the shell cannot: the REAL command output (so it knows whether the merge actually
#     succeeded or errored) and the DIFF (so it knows whether the change is substantive enough to
#     be worth a quiz). A shell script cannot read the tool's exit status reliably from the hook
#     payload, and cannot judge triviality at all. So it does not try.
#
# The matcher reads the LEADING TOKENS of each shell segment, never the whole string, so a command
# whose payload merely mentions "gh pr merge" (an echo, an issue comment) does not fire. That is
# the command-vs-payload distinction check-closing-keyword.sh had to learn the hard way.
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

parse_payload() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -j '(.tool_input.command // "")' 2>/dev/null && return 0
  fi
  printf '%s' "$payload" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ti = d.get("tool_input") or {}
sys.stdout.write(ti.get("command") or "")
' 2>/dev/null
}

cmd="$(parse_payload)" || exit 0
[ -n "$cmd" ] || exit 0

# Documented override: an inline SKIP_PR_QUIZ=1 prefix.
if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])SKIP_PR_QUIZ=1([[:space:]]|$)'; then
  exit 0
fi

# Does any shell segment RUN `gh pr merge` (as opposed to merely mentioning it)? Match on the
# leading tokens of each segment, after stripping any leading env assignments (GH_TOKEN=... gh ...).
is_merge=0
while IFS= read -r seg; do
  head_tokens="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*//' | awk '{print $1, $2, $3}')"
  if printf '%s' "$head_tokens" | grep -Eq '(^|/)gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
    is_merge=1
    break
  fi
done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;)/\n/g')
[ "$is_merge" -eq 1 ] || exit 0

# Fire: hand Claude an instruction to run the comprehension quiz before moving on. The reason is a
# single JSON string; newlines are \n. Kept free of dashes and emoji per the writing-style rule.
cat <<'JSON'
{"decision":"block","reason":"A `gh pr merge` command just ran. Before you do ANYTHING else (do NOT suggest, pick, or start the next issue, and do NOT run the next-issue flow) run a short PR comprehension quiz, then continue normally.\n\nStep 1, confirm it shipped: look at the actual output of the merge command you just ran. If the merge did NOT succeed (it errored, was already merged, needed input, or was a no-op), say so in one line and proceed as normal. Do NOT quiz on a merge that did not happen.\n\nStep 2, triviality gate: read what shipped (`gh pr view <number> --json title,body,url` and `gh pr diff <number>`; if no number was given, resolve the PR for the merged branch first). If the change is inconsequential (only comments, docs, formatting, whitespace, a version or dependency bump, or similar), do NOT quiz: say 'Nothing substantive shipped, skipping quiz.' in one line and proceed.\n\nStep 3, quiz: otherwise write 1 to 4 questions, scaled to how much shipped (a small change gets 1, a substantial feature gets 3 or 4). Test BEHAVIOR AND IMPACT in plain language, what the change means for users or the system (for example, who is affected, what happens now in a given situation), NOT code trivia like file names or function names. Ask them ONE AT A TIME, one AskUserQuestion picker per question, each with plausible concrete options. ANTI-GAMING, this matters: vary which option is the correct one from question to question and do NOT default to putting the correct answer first (choosing the first option must never be a winning strategy). Give NO tell: do not mark any option 'Recommended', and keep all options similar in length, specificity, and plausibility so the answer is not guessable from shape. After each answer: if it is correct, just move on with a quiet check mark, no explanation; if it is wrong, briefly state the correct answer and why in plain language. Nothing is saved anywhere. Only after every question is answered may you go on to the next issue."}
JSON
