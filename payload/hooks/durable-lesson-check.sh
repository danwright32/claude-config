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
# Before a lesson is proposed it is asked the rungs (claude-config#3245): whether the code can be
# shaped so the mistake cannot be written, whether a static check can catch it, whether running the
# thing shows it. A written lesson is the last of those places and the most expensive (L27), so the
# proposal says which rung it reached, and the entry carries the one line saying what holds it,
# CHECK: or NO CHECK:. The picker shows Dan that line and carries it in its metadata, which is what
# lets his one answer cover it (the ask before saving mod; Dan, 2026-11-19: "Yes, cover the check
# line"). The line is plain ASCII within the mod's cap and sits in one place, just before the SHORT
# line, or last in an entry with none: the place the mod approves, and one claude-sync's reader of
# the lessons file reads (security review of #3245). The suite holds this wording to the mod's own
# names and numbers.
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
# Fails QUIET: any parse error exits 0 with no output. A library it cannot load is said once, on a
# call naming an issue create (claude-config#1922).

set -uo pipefail

[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

payload="$(cat)"


# The library, not a copy: five near copies of this had already drifted (claude-config#102).
# `raw` because this hook searches the whole command rather than splitting it, and quoting a
# command back at somebody with its newlines rewritten shows them something they did not type.
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
# A library this hook cannot load is said once, as a systemMessage, on a call whose raw text names an
# issue create, the one call it checks (claude-config#1922): it stopped here in silence.
# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || {
  case "$payload" in
    *"issue create"*) hook_allow_notice "DURABLE LESSON CHECK DID NOT RUN: durable-lesson-check.sh could not load lib/push-scope.sh (reinstall the hooks with claude-sync pull), so this issue was not checked for a lesson it should record." PostToolUse ;;
  esac
  exit 0
}
# Cleaned before anything parses it: a lone surrogate escape made jq read nothing (claude-config#1944).
payload="$(ps_clean_payload "$payload")"
parsed="$(ps_parse_payload "$payload" raw)" || exit 0
cmd="${parsed%%$'\x1f'*}"
[ -n "$cmd" ] || exit 0

# Does any command the shell would run RUN `gh issue create`, as opposed to merely mentioning it?
# Asked of lib/push-scope.sh's one reading (ps_runs_gh), which finds the subcommand as gh itself does,
# past flags in front (`gh -R o/x issue create`, `gh issue -R o/x create`) and past rtk, env or sudo
# (claude-config#1188; the first three words were read before, and missed each of those).
is_create=0
ps__read "$cmd" || :
segs="$(ps__shell_segments "$cmd")"
[ "$?" -eq 1 ] && segs="$(ps__crude_cut "$cmd" | tr '\n' '\036')"
while IFS= read -r -d $'\x1e' seg; do
  # Documented override: an inline SKIP_LESSON_CHECK=1 prefix. It is judged PER
  # SEGMENT, because it belongs to the one command it prefixes. Reading it across
  # the whole call let a genuine create sitting in a later segment go unexamined.
  if grep -Eq '(^|[[:space:]])SKIP_LESSON_CHECK=1([[:space:]]|$)' <<< "$seg"; then
    continue
  fi
  if ps_runs_gh "$seg" issue create; then
    # A help invocation files nothing, so there is no issue to draw a lesson from.
    case " ${PS_RUN_ARGS[*]-} " in *" --help "*|*" -h "*) continue ;; esac
    is_create=1
    break
  fi
done <<LOOP_INPUT
$segs
LOOP_INPUT
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
{"decision":"block","reason":"A `gh issue create` command just ran. Before moving on, run the durable lesson check on the issue(s) filed this turn, evaluating them TOGETHER in one pass.\n\nStep 1, confirm it happened: look at the actual output of the create command(s). If no issue was actually created (an error, a dry run), skip the rest silently.\n\nStep 2, judge: does any issue just filed record a MISTAKE in how something was built (a wrong assumption, a missed constraint, a silent failure, a defect class) that carries a durable lesson applicable across Dan's projects? Apply a strict bar: a feature idea, a plan record, a one-off, or a project-specific behavior does NOT qualify. The test is: would a one-sentence build-time rule plausibly have prevented defects in more than one project?\n\nStep 3, dedupe: read ~/.claude/LESSONS.md and the rules in ~/.claude/CLAUDE.md. If the lesson is already covered there (or in the current project's memory for project-specific ones), or nothing qualifies, say NOTHING about this check and continue normally. Silence is the expected outcome for most issues.\n\nStep 4, ask the rungs before prose: a written lesson is the most expensive place for a correction to live, because it holds only while a session reads it and obeys (L27). For a lesson that survives Step 3, ask in order, cheapest first: (1) can you shape the code (the API, the types, the folder layout) so the mistake cannot be written at all; (2) can a static check catch it (a hook, a guard script, a lint rule, a type, a test); (3) can verification show it (the thing is run and shown to work). Where a rung fits, build that check, or file the issue for it when it is not this turn's work. The entry then carries ONE check line saying what holds it: CHECK: <path> (full) when a check holds the whole rule or CHECK: <path> (partial) when a reader holds the rest, naming the check once that file exists (a path relative to ~/.claude such as hooks/x.sh, or owner/repo:path for a check in another repository), or NO CHECK: <why no check can hold it> in at least three words. Write it on one line of plain ASCII (letters, digits, punctuation and spaces: no tab, no accented or typographic character, nothing invisible), at most 300 characters, because Dan approves it by reading it and the picker refuses a line holding anything he could not see. `claude-sync lesson-faults` refuses a line in neither shape, and `claude-sync lesson-checks` counts them.\n\nStep 5, propose: only if a genuinely new durable lesson survives, propose the exact rule wording (one to two sentences, stating the rule and the why, no dashes as punctuation, no emoji) via an AskUserQuestion picker: one question stating that rule word for word, then in one or two plain sentences which rung it reached and why the rungs above it do not fit, then the check line word for word on a line of its own, with metadata {\"source\": \"durable-lesson\", \"rule\": \"<the rule, word for word>\", \"check\": \"<the check line, word for word>\"}. Ask before saving sets its answers (Add to LESSONS.md, Project memory instead, Skip), and Dan's Add to LESSONS.md approves the one Edit that adds that rule, with that check line, to ~/.claude/LESSONS.md, so he is not asked For good about either a second time. That entry must be its number, the rule word for word, then only its provenance as (repo#issue, YYYY-MM-DD), its check line as approved and its SHORT line, the check line just before the SHORT line, or last when the entry needs no SHORT line: any other text, evidence included, written beside it is asked about again, and so is a check line that differs from the one he read. In that picker's question text, ALSO tell Dan which of his other projects the lesson likely applies to. Read the project list live, never from memory: `gh api -H 'Accept: application/vnd.github.raw' repos/dwright-pennie/repo-digest/contents/repos.json` and the same for repos-weekly.json. Write one line, 'Likely applies to: <repo> (<why, a few words>), ...; unlikely in: <the rest>', judged from what each project does. It is information for Dan only: once the lesson is added, the sweep issue is still filed in every digest repo. Only on Dan's approval append it to ~/.claude/LESSONS.md under the best-fitting section, numbered with the number `~/claude-config-sync/claude-sync next-lesson` prints, never one picked by reading the file (each Mac mints from its own band, so a number chosen by eye is one the other Mac may already have used), with provenance (repo#issue, YYYY-MM-DD). ALSO WRITE A SHORT FORM: the generated lessons index renders one line per lesson, the line a session loads when that lesson is in the core, and a single line may not exceed the ENTRY_CAP in hooks/test-rule-file-budget.sh (160 characters today, counted as '- L429. <text>'). Most rule sentences are longer than that, so unless the rule you just wrote renders inside it, add a line reading 'SHORT: <the rule in one line>' inside the entry, indented, carrying the condition and the instruction. The full rule stays exactly as written and the index renders the short form. A lesson over the cap without one is refused by the send, which holds the whole lessons file back until it is fixed. Once the lesson is in, lesson-fanout-notice.sh asks for the issues that check every other digest repo for the same defect; run the command it names. NEVER edit LESSONS.md without that approval. A lesson that is real but project-specific goes to the project's memory instead, silently, as usual."}
JSON
