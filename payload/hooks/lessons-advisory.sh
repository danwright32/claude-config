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
#   - Cooldown stamp (90s per repo): a retried or split push advises once.
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

parse_payload() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -j '
      ((.tool_input.command // "") | gsub("\n"; " ")) + "" + (.cwd // "")
    ' 2>/dev/null && return 0
  fi
  printf '%s' "$payload" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ti = d.get("tool_input") or {}
cmd = (ti.get("command") or "").replace("\n", " ")
sys.stdout.write(cmd + "\x1f" + (d.get("cwd") or ""))
' 2>/dev/null
}

parsed="$(parse_payload)" || exit 0
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
  "L33,L35,L77"
  "L50"
)
TRIG_WHAT=(
  "an error path that returns an empty or success value"
  "new scheduled, queued or background work"
  "a new route or endpoint"
  "a destructive data operation"
  "new retry or failure-handling logic"
  "a parsed value flowing into a comparison"
)
TRIG_RE1=(
  '(^|[^[:alnum:]_])(catch[[:space:]]*[({]|except[[:space:]:])'
  '(cron|setInterval|\.schedule\(|scheduleJob|CronCreate|BackgroundTasks|celery|sidekiq|queue\.(add|push|send))'
  '((app|router|server)\.(get|post|put|patch|delete)\(|export[[:space:]]+(async[[:space:]]+)?function[[:space:]]+(GET|POST|PUT|PATCH|DELETE)|@(app|router)\.route|addEventListener\([[:punct:]]fetch)'
  '(DROP[[:space:]]+TABLE|DROP[[:space:]]+COLUMN|TRUNCATE[[:space:]]|DELETE[[:space:]]+FROM|rm[[:space:]]+-rf|fs\.rm\(|unlinkSync|\.drop\()'
  '(retry|retries|backoff|maxAttempts|exponential)'
  '(parseInt|parseFloat|JSON\.parse|Number\()'
)
TRIG_RE2=(
  '(return[[:space:]]*(\[\]|\{\}|null|None|true|""|'"''"'|;|$)|^[[:space:]]*pass[[:space:]]*$)'
  ''
  ''
  ''
  ''
  '([<>]=?|[=!]==?)'
)

files="$(printf '%s\n' "$added" | cut -f1 | sort -u)"

hit_ids=""
findings=""
for i in "${!TRIG_IDS[@]}"; do
  hit_files=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    lines="$(printf '%s\n' "$added" | awk -F'\t' -v want="$f" '$1 == want { print $2 }')"
    printf '%s\n' "$lines" | grep -Eqi -- "${TRIG_RE1[$i]}" || continue
    if [ -n "${TRIG_RE2[$i]}" ]; then
      printf '%s\n' "$lines" | grep -Eqi -- "${TRIG_RE2[$i]}" || continue
    fi
    hit_files="$hit_files $f"
  done <<< "$files"
  [ -z "$hit_files" ] && continue
  # Three examples is enough to find it; a full list turns advice into a wall.
  shown="$(printf '%s' "$hit_files" | tr ' ' '\n' | sed '/^$/d' | head -3 | tr '\n' ' ')"
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
  lesson_text="COULD NOT READ $LESSONS_FILE — the lessons below could not be quoted, so read them there yourself. This is not a clean result."
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
$id NOT FOUND in $LESSONS_FILE — the trigger map names a lesson this file no longer has. Do not treat it as inapplicable; the id was renumbered or removed."
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
