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

# Does any shell segment RUN `gh issue create` (leading tokens, after stripping simple
# leading env assignments), as opposed to merely mentioning it?
is_create=0
while IFS= read -r seg; do
  # Documented override: an inline SKIP_LESSON_CHECK=1 prefix. It is judged PER
  # SEGMENT, because it belongs to the one command it prefixes. Reading it across
  # the whole call let a genuine create sitting in a later segment go unexamined.
  if printf '%s' "$seg" | grep -Eq '(^|[[:space:]])SKIP_LESSON_CHECK=1([[:space:]]|$)'; then
    continue
  fi
  stripped="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*//')"
  head_tokens="$(printf '%s' "$stripped" | awk '{print $1, $2, $3}')"
  if printf '%s' "$head_tokens" | grep -Eq '(^|/)gh[[:space:]]+issue[[:space:]]+create([[:space:]]|$)'; then
    # A help invocation files nothing, so there is no issue to draw a lesson from.
    if printf '%s' "$stripped" | grep -Eq '(^|[[:space:]])(--help|-h)([[:space:]]|$)'; then
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
{"decision":"block","reason":"A `gh issue create` command just ran. Before moving on, run the durable lesson check on the issue(s) filed this turn, evaluating them TOGETHER in one pass.\n\nStep 1, confirm it happened: look at the actual output of the create command(s). If no issue was actually created (an error, a dry run), skip the rest silently.\n\nStep 2, judge: does any issue just filed record a MISTAKE in how something was built (a wrong assumption, a missed constraint, a silent failure, a defect class) that carries a durable lesson applicable across Dan's projects? Apply a strict bar: a feature idea, a plan record, a one-off, or a project-specific behavior does NOT qualify. The test is: would a one-sentence build-time rule plausibly have prevented defects in more than one project?\n\nStep 3, dedupe: read ~/.claude/LESSONS.md and the rules in ~/.claude/CLAUDE.md. If the lesson is already covered there (or in the current project's memory for project-specific ones), or nothing qualifies, say NOTHING about this check and continue normally. Silence is the expected outcome for most issues.\n\nStep 4, propose: only if a genuinely new durable lesson survives, propose the exact rule wording (one to two sentences, stating the rule and the why, no dashes as punctuation, no emoji) via an AskUserQuestion picker with options to add it to LESSONS.md, save it as project memory instead, or skip. Only on Dan's approval append it to ~/.claude/LESSONS.md under the best-fitting section, numbered with the next free L number, with provenance (repo#issue). NEVER edit LESSONS.md without that approval. A lesson that is real but project-specific goes to the project's memory instead, silently, as usual."}
JSON
