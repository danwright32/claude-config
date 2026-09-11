#!/usr/bin/env bash
#
# durable-lesson-check.sh
# Claude Code PostToolUse(Bash) hook: the self-improving half of the 2026-07-27 issue
# audit. The moment an issue is FILED in any project (`gh issue create` actually ran),
# ask Claude to judge whether the issue records a mistake carrying a durable,
# cross-project lesson, and if so propose adding it to ~/.claude/LESSONS.md for Dan's
# approval. The shell owns exactly one decision (did this command run an issue create?);
# all judgement is handed back to Claude, which can see the real command output and the
# current LESSONS.md.
#
# Matching discipline follows pr-merge-quiz.sh: read the LEADING TOKENS of each shell
# segment, never the whole string, so a command whose payload merely mentions
# "gh issue create" (an echo, a doc write) does not fire.
#
# Guards:
#   - CLAUDE_DETACHED_RUN set: a headless run has nobody to approve a rule. Skip.
#   - SKIP_LESSON_CHECK=1 inline prefix: documented override, same style as the others.
#   - Cooldown stamp (120s per project): when one turn files several issues, the check
#     fires once and evaluates them together instead of interrupting per issue.
#
# Fails QUIET: any parse error exits 0 with no output.

set -uo pipefail

[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

payload="$(cat)"


# The library, not a copy: five near copies of this had already drifted (claude-config#102).
# `raw` because this hook searches the whole command rather than splitting it, and quoting a
# command back at somebody with its newlines rewritten shows them something they did not type.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0
parsed="$(ps_parse_payload "$payload" raw)" || exit 0
cmd="${parsed%%$'\x1f'*}"
[ -n "$cmd" ] || exit 0

# Does any shell segment RUN `gh issue create` (leading tokens, after stripping simple
# leading env assignments), as opposed to merely mentioning it?
is_create=0
while IFS= read -r seg; do
  # Documented override: an inline SKIP_LESSON_CHECK=1 prefix. It is judged PER
  # SEGMENT, because it belongs to the one command it prefixes. Reading it across
  # the whole call let a genuine create sitting in a later segment go unexamined.
  if grep -Eq '(^|[[:space:]])SKIP_LESSON_CHECK=1([[:space:]]|$)' <<< "$seg"; then
    continue
  fi
  stripped="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*//')"
  head_tokens="$(printf '%s' "$stripped" | awk '{print $1, $2, $3}')"
  if grep -Eq '(^|/)gh[[:space:]]+issue[[:space:]]+create([[:space:]]|$)' <<< "$head_tokens"; then
    # A help invocation files nothing, so there is no issue to draw a lesson from.
    if grep -Eq '(^|[[:space:]])(--help|-h)([[:space:]]|$)' <<< "$stripped"; then
      continue
    fi
    is_create=1
    break
  fi
done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;)/\n/g')
[ "$is_create" -eq 1 ] || exit 0

# Cooldown: several creates in one turn get one combined evaluation.
COOLDOWN_SECONDS=120
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
hash=$(printf '%s' "$proj" | shasum | cut -c1-12)
stamp="${TMPDIR:-/tmp}/claude-lesson-check-${hash}.stamp"
now=$(date +%s)
last=0
[ -f "$stamp" ] && last=$(cat "$stamp" 2>/dev/null || echo 0)
[ $(( now - last )) -lt "$COOLDOWN_SECONDS" ] && exit 0
printf '%s' "$now" > "$stamp"

# Hand judgement back to Claude. Single JSON string, newlines as \n, no dashes or emoji.
cat <<'JSON'
{"decision":"block","reason":"A `gh issue create` command just ran. Before moving on, run the durable lesson check on the issue(s) filed this turn, evaluating them TOGETHER in one pass.\n\nStep 1, confirm it happened: look at the actual output of the create command(s). If no issue was actually created (an error, a dry run), skip the rest silently.\n\nStep 2, judge: does any issue just filed record a MISTAKE in how something was built (a wrong assumption, a missed constraint, a silent failure, a defect class) that carries a durable lesson applicable across Dan's projects? Apply a strict bar: a feature idea, a plan record, a one-off, or a project-specific behavior does NOT qualify. The test is: would a one-sentence build-time rule plausibly have prevented defects in more than one project?\n\nStep 3, dedupe: read ~/.claude/LESSONS.md and the rules in ~/.claude/CLAUDE.md. If the lesson is already covered there (or in the current project's memory for project-specific ones), or nothing qualifies, say NOTHING about this check and continue normally. Silence is the expected outcome for most issues.\n\nStep 4, propose: only if a genuinely new durable lesson survives, propose the exact rule wording (one to two sentences, stating the rule and the why, no dashes as punctuation, no emoji) via an AskUserQuestion picker with options to add it to LESSONS.md, save it as project memory instead, or skip. Only on Dan's approval append it to ~/.claude/LESSONS.md under the best-fitting section, numbered with the number `~/claude-config-sync/claude-sync next-lesson` prints, never one picked by reading the file (each Mac mints from its own band, so a number chosen by eye is one the other Mac may already have used), with provenance (repo#issue). ALSO WRITE A SHORT FORM: LESSONS-INDEX.md renders one line per lesson into every session in every project, and a single line may not exceed the ENTRY_CAP in hooks/test-rule-file-budget.sh (160 characters today, counted as '- L429. <text>'). Most rule sentences are longer than that, so unless the rule you just wrote renders inside it, add a line reading 'SHORT: <the rule in one line>' inside the entry, indented, carrying the condition and the instruction. The full rule stays exactly as written and the index renders the short form. A lesson over the cap without one is refused by the send, which holds the whole lessons file back until it is fixed. NEVER edit LESSONS.md without that approval. A lesson that is real but project-specific goes to the project's memory instead, silently, as usual."}
JSON
