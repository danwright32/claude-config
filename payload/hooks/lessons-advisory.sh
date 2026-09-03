#!/usr/bin/env bash
#
# lessons-advisory.sh
# Claude Code PreToolUse(Bash) hook: ADVISORY, never blocking.
#
# When a `git push` introduces code matching a pattern that a past defect was
# made of, hand Claude the specific lessons from ~/.claude/LESSONS.md that apply,
# with the files that triggered them. It injects context via
# hookSpecificOutput.additionalContext and exits 0, so the push proceeds and no
# override flag is needed.
#
# WHY ADVISORY AND NOT A GATE. The lessons are mostly design shaped (assume it
# runs twice, fail closed, never destroy good state). By push time the design is
# committed, so a gate there produces rework at the moment the pressure to skip
# is highest, and a third overridable push gate would train the reflex of typing
# SKIP_ past the two that already work.
#
# WHAT IT CANNOT DO. Its trigger list is hand written, so it only ever sees what
# that list names, and the design shaped majority of the lessons are invisible to
# any pattern match (LESSONS.md L96). It therefore NEVER reports a clean result:
# it either has something specific to say, or it says nothing at all. Silence
# from this hook means "no pattern matched", never "this push is lesson clean".
#
# It also deliberately does NOT emit permissionDecision. Emitting "allow" would
# auto-approve every push and bypass both the user's confirmation and the other
# hooks on this matcher.
#
# Guards:
#   - CLAUDE_DETACHED_RUN set: nobody is reading advice in a headless run. Skip.
#   - Not a git push, or not inside a work tree ................. silent
#   - Nothing matched .......................................... silent
#   - Cooldown stamp (90s per repo AND per finding, a window this hook sets and not measured):
#     pushing again after acting
#     on the advice does not repeat it, while a DIFFERENT finding still gets
#     through rather than being swallowed by the window.
#
# Seams for tests: LESSONS_FILE overrides the lessons path, TMPDIR the cooldown
# stamp directory.
#
# Fails QUIET: it is an advisor, so a broken advisor should add nothing rather
# than nag. The one thing it will not do quietly is lose a lesson: an id that no
# longer resolves, or a lessons file it cannot read, is reported in the advisory
# itself rather than dropped.

set -uo pipefail

[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

LESSONS_FILE="${LESSONS_FILE:-$HOME/.claude/LESSONS.md}"
COOLDOWN=90

payload="$(cat)"


parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

stamp_dir="${TMPDIR:-/tmp}"
now="$(date +%s)"

# --- The added lines this push introduces ------------------------------------
# Added lines only. Matching the whole file would re-raise the same lesson on
# every push that happens to touch a file where the pattern already lived, which
# is the fastest way to teach someone to ignore this hook.
base="$(ps_base_ref)"
mb="$(ps_merge_base "$base")"

diff_opts=(--unified=0 --src-prefix=a/ --dst-prefix=b/ --diff-filter=ACMR)

raw=""
[ -n "$mb" ] && raw="$(git diff "${diff_opts[@]}" "$mb" HEAD 2>/dev/null)"
if ps_commit_in_chain "$cmd"; then
  raw="$raw
$(git diff "${diff_opts[@]}" --cached 2>/dev/null)"
  if ps_add_in_chain "$cmd"; then
    raw="$raw
$(git diff "${diff_opts[@]}" 2>/dev/null)"
  fi
fi
[ -n "$(printf '%s' "$raw" | tr -d '[:space:]')" ] || exit 0

# path<TAB>added-line, one per added line.
added="$(printf '%s\n' "$raw" | awk '
  /^\+\+\+ /      { f = substr($0, 7); if (f == "/dev/null") f = ""; next }
  /^\+\+\+/       { next }
  /^\+/           { if (f != "") print f "\t" substr($0, 2) }
')"
[ -n "$added" ] || exit 0

# --- Triggers -----------------------------------------------------------------
# Each entry: lesson ids | what was spotted | regex | second regex (both must
# appear in the same file, empty when the first is enough). Kept deliberately
# small and precise: a trigger that fires on ordinary code costs more than the
# lesson it carries.
TRIG_IDS=(
  "L10,L11,L95"
  "L13,L71"
  "L18,L19"
  "L5,L7,L9"
  "L33,L35,L77,L524"
  "L50"
  "L290,L524"
  "L313"
)
TRIG_WHAT=(
  "an error path that returns an empty or success value"
  "new scheduled, queued or background work"
  "a new route or endpoint"
  "a destructive data operation"
  "new retry or failure-handling logic"
  "a parsed value flowing into a comparison"
  "a test that waits a fixed time instead of waiting on a condition or setting the clock"
  "a workflow job added with no timeout, so a hang runs to the platform's six hour default"
)
TRIG_RE1=(
  '(^|[^[:alnum:]_])(catch[[:space:]]*[({]|except[[:space:]:])'
  '(cron|setInterval|\.schedule\(|scheduleJob|CronCreate|BackgroundTasks|celery|sidekiq|queue\.(add|push|send))'
  '((app|router|server)\.(get|post|put|patch|delete)\(|export[[:space:]]+(async[[:space:]]+)?function[[:space:]]+(GET|POST|PUT|PATCH|DELETE)|@(app|router)\.route|addEventListener\([[:punct:]]fetch)'
  '(DROP[[:space:]]+TABLE|DROP[[:space:]]+COLUMN|TRUNCATE[[:space:]]|DELETE[[:space:]]+FROM|rm[[:space:]]+-rf|fs\.rm\(|unlinkSync|\.drop\()'
  '(retry|retries|backoff|maxAttempts|exponential)'
  '(parseInt|parseFloat|JSON\.parse|Number\()'
  '(waitForTimeout\(|setTimeout\(|Task\.sleep|Thread\.sleep|time\.sleep\(|usleep\(|(^|[^[:alnum:]_.])sleep[[:space:]]*(\(|[0-9]))'
  ''
)
TRIG_RE2=(
  '(return[[:space:]]*(\[\]|\{\}|null|None|true|""|'"''"'|;|$)|^[[:space:]]*pass[[:space:]]*$)'
  ''
  ''
  ''
  ''
  '([<>]=?|[=!]==?)'
  ''
  ''
)
# Which FILES a trigger may fire on (a regex over the path; empty means any file). The fixed
# wait trigger is scoped to test files on purpose: the same setTimeout in production code is a
# retry's business and is covered by the retry trigger above, while in a test it is a wait on
# the machine's load. A trigger with no scope fires everywhere, exactly as before this was added.
TRIG_PATH=(
  ''
  ''
  ''
  ''
  ''
  ''
  '(^|/)(tests?|__tests__|specs?|e2e|spec|Tests)/|\.(test|spec)\.[A-Za-z]+$|(Tests?|Spec)\.swift$|(^|/)test[-_][^/]*\.(sh|py|ts|js)$|_test\.(py|go|rb)$'
  '^\.github/workflows/[^/]*\.ya?ml$'
)

# Some triggers cannot be a regex over the added lines, because what is wrong is a key that is
# ABSENT (claude-config#223). Those name a FUNCTION here instead, which is handed the file of added
# lines and answers by its exit status. Empty means the ordinary regex pair decides, exactly as
# before, so nothing that existed changes shape.
TRIG_FN=(
  ''
  ''
  ''
  ''
  ''
  ''
  ''
  'trig_workflow_job_without_timeout'
)

# A workflow job added with no `timeout-minutes` (L313). The platform default is six hours, and a
# hang that runs to it is both invisible, because it reads as slowness, and expensive on a metered
# runner.
#
# What makes a two-space key a JOB is `runs-on` or `uses` inside its own block. Without that test
# every `on:` block's `push:` and `pull_request:` would read as jobs with no timeout, and the
# advisory would fire on every workflow change anyone ever made, which is how a guard stops being
# read (L36).
#
# It sees only the ADDED lines, so what it catches is a job written in this push. A job whose
# timeout was added in some earlier push is not visible here and is not meant to be: this is the
# moment somebody is looking at that block, and the suite's own check (claude-config#210) is what
# holds the whole tree afterwards.
trig_workflow_job_without_timeout(){   # $1 = a file holding the added lines
  awk '
    function close_job() {
      if (job != "" && isjob && !hastimeout) bad = 1
      job = ""; isjob = 0; hastimeout = 0
    }
    /^[[:space:]]{2}[A-Za-z0-9_-]+:[[:space:]]*$/ { close_job(); job = $1; next }
    job != "" && /^[[:space:]]{4}(runs-on|uses):/ { isjob = 1 }
    job != "" && /^[[:space:]]{4}timeout-minutes:/ { hastimeout = 1 }
    /^[^[:space:]#]/ { close_job() }
    END { close_job(); exit !bad }
  ' "$1"
}

files="$(printf '%s\n' "$added" | cut -f1 | sort -u)"

hit_ids=""
findings=""
# One scratch file for the whole scan, removed on the way out. Named, so a run killed part way
# through leaves something attributable rather than an anonymous file (claude-config#36).
LINES_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-sync-work.advisory.XXXXXXXX")"
trap 'rm -f "$LINES_FILE"' EXIT
for i in "${!TRIG_IDS[@]}"; do
  hit_files=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -n "${TRIG_PATH[$i]}" ]; then
      # A here-string, not a pipe: `printf | grep -q` is the short circuit class this hook was
      # once silenced by (L183), and the repo's ratchet refuses a new one.
      grep -Eq -- "${TRIG_PATH[$i]}" <<< "$f" || continue
    fi
    lines="$(printf '%s\n' "$added" | awk -F'\t' -v want="$f" '$1 == want { print $2 }')"
    # Written to a file and matched from there, rather than piped in from a printf. This runs under
    # `pipefail`, and `grep -q` leaves on its first match: a printf whose string is larger than the
    # pipe buffer is then killed by SIGPIPE, the pipeline reports failure, and `|| continue` reads
    # that as NO MATCH. The advisory would go quiet on exactly the pushes that add the most lines,
    # which is when it has most to say (L183, and the same shape as the guard in claude-config#117
    # that got slower the more it had to report).
    printf '%s\n' "$lines" > "$LINES_FILE"
    if [ -n "${TRIG_FN[$i]:-}" ]; then
      # The predicate reads the same file the regexes would, so it is subject to the same path
      # scope above and sees exactly the same lines.
      "${TRIG_FN[$i]}" "$LINES_FILE" || continue
    else
      grep -Eqi -- "${TRIG_RE1[$i]}" "$LINES_FILE" || continue
      if [ -n "${TRIG_RE2[$i]}" ]; then
        grep -Eqi -- "${TRIG_RE2[$i]}" "$LINES_FILE" || continue
      fi
    fi
    hit_files="$hit_files $f"
  done <<< "$files"
  [ -z "$hit_files" ] && continue
  # Three examples is enough to find it; a full list turns advice into a wall.
  shown="$(printf '%s' "$hit_files" | tr ' ' '\n' | sed '/^$/d' | awk 'NR <= 3' | tr '\n' ' ')"
  more="$(printf '%s' "$hit_files" | tr ' ' '\n' | sed '/^$/d' | wc -l | tr -d ' ')"
  extra=""
  [ "$more" -gt 3 ] && extra=" (and $((more - 3)) more)"
  findings="$findings
- ${TRIG_WHAT[$i]} -> ${TRIG_IDS[$i]}
  in: ${shown}${extra}"
  hit_ids="$hit_ids,${TRIG_IDS[$i]}"
done

[ -n "$hit_ids" ] || exit 0

# --- Cooldown, keyed on WHAT WAS FOUND, not merely on the repo ----------------
# The quiet is for repetition: pushing again after acting on the advice should
# not repeat it. A cooldown keyed on the repo alone would also swallow a DIFFERENT
# problem raised minutes later, and this hook's silence is supposed to mean "no
# pattern matched". Silence that sometimes means "matched, but recently" would
# make the quiet case unreadable.
stamp="$stamp_dir/.claude-lessons-advisory-$(printf '%s|%s' "$repo_root" "$hit_ids" | cksum | tr -d ' ')"
if [ -f "$stamp" ]; then
  last="$(cat "$stamp" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt "$COOLDOWN" ] && exit 0
fi

# --- Resolve each lesson's own words from LESSONS.md --------------------------
# The wording lives in one place. This hook stores pattern-to-id pairs only, so
# an edit to a lesson reaches the advice without anyone updating a second copy
# (LESSONS.md L41). An id that no longer resolves is reported, never dropped: a
# renumbering would otherwise quietly empty the map behind everyone's back.
ids="$(printf '%s' "$hit_ids" | tr ',' '\n' | sed '/^$/d' | sort -u -V)"

lesson_text=""
if [ ! -r "$LESSONS_FILE" ]; then
  lesson_text="COULD NOT READ $LESSONS_FILE: the lessons below could not be quoted, so read them there yourself. This is not a clean result."
else
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    body="$(awk -v id="$id" '
      $0 ~ ("^- \\*\\*" id "\\.") { inblock = 1; print; next }
      inblock && /^- \*\*L[0-9]/   { exit }
      inblock && /^#/              { exit }
      inblock                      { print }
    ' "$LESSONS_FILE")"
    if [ -z "$body" ]; then
      lesson_text="$lesson_text
$id NOT FOUND in $LESSONS_FILE: the trigger map names a lesson this file no longer has. Do not treat it as inapplicable; the id was renumbered or removed."
    else
      lesson_text="$lesson_text
$body"
    fi
  done <<< "$ids"
fi

context="LESSONS CHECK (advisory, from a pattern scan of the lines this push ADDS)

This is a partial pattern check, not a full audit: it can only see the patterns
it was taught, and most of the recorded lessons are about design, which no
pattern match can see. It never means the push is clean.

What was spotted:${findings}

The lessons that apply:
${lesson_text}

Before pushing, check each one against what you actually changed. Where it
applies and the code does not honour it, fix it and push the fix in the same
breath. Where it does not apply, say so in one line and carry on. Do not
silently ignore one."

printf '%s' "$context" | python3 -c '
import sys, json
ctx = sys.stdin.read()
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": ctx}}))
' 2>/dev/null || exit 0

printf '%s' "$now" > "$stamp" 2>/dev/null
exit 0
