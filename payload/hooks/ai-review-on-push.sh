#!/usr/bin/env bash
#
# ai-review-on-push.sh
# Claude Code PostToolUse(Bash) hook.
#
# Start an advisory AI review of what a `git push` just sent, once per push, in the background
# (claude-config#433). Two of the ten confirmed findings in the 2026-09-18 Slate review were class
# fixes that missed a sibling: `deleteEvent` skipped when its twin got a typed error, and the
# webhook first send skipped when every retry path got the attempt claim (Try-Pennie/slate#2561,
# #2563). No scan can see that class; an independent reader did, by reading. So this hands the
# pushed diff to `claude -p` with the review prompt in lib/ai-review-prompt.txt and lets the answer
# arrive on a later prompt through ai-review-nudge.sh.
#
# IT NEVER BLOCKS AND IT ADDS NO WAIT TO THE PUSH. Every path here exits 0, and the review itself
# runs in a process this hook starts and does not wait for (`nohup ... &` then `disown`, with all
# three standard streams redirected so nothing holds the hook's pipes open). A blocking version
# teaches people to set the skip variable, which is the one habit a review cannot afford. The hook
# does exactly four things before it returns: decide this was a successful push, compute the diff,
# write the pending marker, start the runner.
#
# WHAT IS REVIEWED. The diff of code files only (ts, tsx, js, jsx, py, sh, sql) over the range the
# push added. That range is NOT what ps_base_ref gives a PreToolUse hook: after the push the branch's
# upstream IS its HEAD, so the shared merge-base falls through to HEAD~1 and a three commit push
# would be reviewed one commit short. So the base is chosen in this order, each step only when the
# one before it cannot answer:
#   1. the upstream's previous tip (`@{u}@{1}`), when it is an ancestor of HEAD: exactly what this
#      push added, on a branch pushed before;
#   2. the merge-base with the remote's default branch: the whole branch, on a first push;
#   3. ps_merge_base over ps_base_ref, the shared fallback, which lands on HEAD~1.
#
# SKIPS, each said out loud in one line, because a silent skip is indistinguishable from a review
# that found nothing (L98):
#   - the push did not succeed (tool_response.exit_code non-zero, or the command was interrupted);
#     when the payload cannot say, the review goes ahead;
#   - `claude` is not on PATH;
#   - CLAUDE_DETACHED_RUN is set (a headless run has nobody to read the review);
#   - this computer is not one AI_REVIEW_HOSTS names (default: the work Mac, Dans-MacBook-Pro);
#   - SKIP_AI_REVIEW_CHECK=1 was put on the push command;
#   - the diff is empty (no code files changed), or over the size cap.
#
# WHAT THE REVIEWER IS SHOWN, and why it is more than the diff. The first real run of this hook
# (2026-09-18, sonnet, a fixture where createEvent got a typed error and its twin deleteEvent did
# not) answered "No issues found.", correctly, because a three line diff context never put
# deleteEvent in front of it. The class this exists to catch is by definition NOT in the diff. In
# Slate the two real pairs from the review sit 98 and 265 lines apart in one file, so wider context
# alone would not show them either. So the input is the diff with 20 lines of context, FOLLOWED by
# the full contents at the pushed revision of each changed code file, appended smallest first for
# as long as the size budget lasts, each headed `===== FULL FILE`. Files left out are named in the
# start line. AI_REVIEW_FULL_FILES=0 sends the diff alone.
#
# THE SIZE CAP IS MEASURED, not guessed (L172). Over the last 200 first-parent commits on Slate main
# (measured 2026-09-18; each is one squash merged push): the code-only diff at -U20 was median
# 40 KB, p95 132 KB, p99 242 KB, largest 291 KB, and 3 of 200 changed no code file, so the 300 KB
# cap on the DIFF skips none of them and refuses only a diff a reader could not use either. The
# full contents of the changed code files were median 108 KB (6 files), p90 430 KB, largest 712 KB;
# diff plus every file fits under 300 KB for 147 of 200 and the rest get the smaller files. Sending
# every file regardless was rejected because it would send 400 KB or more on 36 of 200 pushes, which
# is Dan's usage allowance for a review a reader could not finish either. Override with
# AI_REVIEW_MAX_BYTES; the same number bounds the diff and the whole input.
#
# THE MODEL is `sonnet` by default (AI_REVIEW_MODEL overrides it). This runs on Dan's subscription,
# so it costs usage allowance rather than money, and a review is worth a mid-tier model's attention
# and not more. The budget per review is AI_REVIEW_DEADLINE_SECONDS (240 by default), enforced in
# the runner, which records a review that did not finish rather than leaving a pending marker for
# ever. Measured 2026-09-18 with sonnet, four other agents running: the planted fixture above
# (one file, 1 KB) took 9 s end to end through the hook and was caught; real Slate commit 962a568
# took 130 s with the diff plus all 8 changed files (289 KB, just under the cap) and 193 s on its bare
# 30 KB diff, which is 80 percent of the deadline. If unfinished reviews start appearing, raise the
# deadline before anything else.
#
# State: $HOME/.claude/state/ai-review/<repo key>-<head sha>.txt (.pending while it runs), where the
# key is a hash of the origin URL; see lib/ai-review-common.sh. AI_REVIEW_STATE_DIR moves it.
#
# Fails QUIET on a payload it cannot read, and OPEN everywhere else: nothing here can stop a push
# that has already happened.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0
# shellcheck source=lib/ai-review-common.sh
. "$HOOK_DIR/lib/ai-review-common.sh" 2>/dev/null || exit 0

payload="$(cat)"

parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

# Only a push, judged by the leading tokens of each segment, never a mention of one.
ps_is_git_push "$cmd" || exit 0

say() { printf 'ai-review: %s\n' "$1"; exit 0; }

[ -n "${CLAUDE_DETACHED_RUN:-}" ] && say "skipped: this is a detached run, so nobody is here to read a review."

if ps_has_override "$cmd" SKIP_AI_REVIEW_CHECK; then
  say "skipped: SKIP_AI_REVIEW_CHECK=1 was set on the push. Tell Dan why the review was skipped; never skip it silently."
fi

# Which computers review at all. This hook syncs to both of Dan's Macs, and he wants the review on
# the work computer only (2026-09-18), so the list names that one and every other skips out loud.
# The short name, because `hostname` answers with a trailing .local here (the same reading
# check-project-list.sh makes). AI_REVIEW_HOSTS is space separated; `*` means every computer.
# AI_REVIEW_HOST judges as a named machine instead of this one, for the suite.
review_hosts="${AI_REVIEW_HOSTS-Dans-MacBook-Pro}"
this_host="${AI_REVIEW_HOST:-$(hostname 2>/dev/null)}"
this_host="${this_host%.local}"
# Matched as text, never looped over unquoted: an unquoted `*` expands to the files in the working
# directory, so the one value meaning everywhere would match nowhere.
host_allowed=0
padded=" $(printf '%s' "$review_hosts" | tr -s '[:space:]' ' ') "
case "$padded" in *" * "*) host_allowed=1 ;; esac
if [ -n "$this_host" ]; then
  case "$padded" in *" $this_host "*) host_allowed=1 ;; esac
fi
[ "$host_allowed" -eq 1 ] \
  || say "skipped: this computer (${this_host:-unknown}) is not one AI_REVIEW_HOSTS names (${review_hosts:-none}), so no review runs here."

# Did the push succeed? The payload says so through tool_response.exit_code. A push that was
# refused sent nothing, so there is nothing to review; a payload with no exit code is read as
# success, because a review of a push that did happen is worth more than silence over one that
# might not have.
fields="$(ar_payload_fields "$payload")" || fields=""
rest="${fields#*$'\x1f'}"
session_id="${rest%%$'\x1f'*}"
rest="${rest#*$'\x1f'}"
push_exit="${rest%%$'\x1f'*}"
push_interrupted="${rest#*$'\x1f'}"
case "$push_exit" in
  ''|0|null) : ;;
  *) say "skipped: the push did not succeed (exit $push_exit), so there is nothing to review." ;;
esac
[ "$push_interrupted" = "true" ] && say "skipped: the push command was interrupted, so there is nothing to review."

command -v claude >/dev/null 2>&1 || say "skipped: no 'claude' command is on PATH, so no review can run. Install the Claude Code CLI to turn this on."

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

head_sha="$(git rev-parse HEAD 2>/dev/null)"
[ -n "$head_sha" ] || say "skipped: could not read HEAD in $repo_dir."

# The base, in the order the header gives. Step 1: the upstream's tip before this push.
mb=""
prev_tip="$(git rev-parse --verify --quiet '@{u}@{1}' 2>/dev/null || true)"
if [ -n "$prev_tip" ] && [ "$prev_tip" != "$head_sha" ] \
   && git merge-base --is-ancestor "$prev_tip" HEAD 2>/dev/null; then
  mb="$prev_tip"
fi
# Step 2: the whole branch against the remote's default branch.
if [ -z "$mb" ]; then
  default_ref="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/##')"
  if [ -z "$default_ref" ]; then
    for c in origin/main origin/master; do
      if git rev-parse --verify --quiet "$c" >/dev/null 2>&1; then default_ref="$c"; break; fi
    done
  fi
  if [ -n "$default_ref" ]; then
    cand="$(git merge-base "$default_ref" HEAD 2>/dev/null || true)"
    [ -n "$cand" ] && [ "$cand" != "$head_sha" ] && mb="$cand"
  fi
fi
# Step 3: the shared fallback.
if [ -z "$mb" ]; then
  base="$(ps_base_ref || true)"
  mb="$(ps_merge_base "$base")"
fi
[ -n "$mb" ] || say "skipped: could not work out what this push added (no base commit to compare against)."

short_mb="$(git rev-parse --short "$mb" 2>/dev/null || printf '%s' "$mb")"
short_head="$(git rev-parse --short "$head_sha" 2>/dev/null || printf '%s' "$head_sha")"

repo_key="$(ar_repo_key "$repo_dir")" || say "skipped: could not key the repository in $repo_dir."
mkdir -p "$AR_STATE_DIR" 2>/dev/null || say "skipped: could not create the state directory $AR_STATE_DIR."

name="$repo_key-$head_sha"
diff_file="$AR_STATE_DIR/$name.diff"
pending_file="$AR_STATE_DIR/$name.txt.pending"
final_file="$AR_STATE_DIR/$name.txt"

# One review per push of one sha: a second push of the same tip (a retry, a push of a second
# remote) has nothing new to read.
if [ -e "$final_file" ] || [ -e "$pending_file" ]; then
  say "skipped: $short_head has already been reviewed, or its review is still running."
fi

CODE_PATHS=('*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.sh' '*.sql')
git diff --no-color -U20 "$mb" "$head_sha" -- "${CODE_PATHS[@]}" > "$diff_file" 2>/dev/null \
  || { rm -f "$diff_file"; say "skipped: git could not produce the diff $short_mb..$short_head."; }

size="$(wc -c < "$diff_file" | tr -d '[:space:]')"
case "$size" in ''|*[!0-9]*) size=0 ;; esac
if [ "$size" -eq 0 ]; then
  rm -f "$diff_file"
  say "skipped: the push changed no code files (ts, tsx, js, jsx, py, sh, sql) between $short_mb and $short_head."
fi
max_bytes="${AI_REVIEW_MAX_BYTES:-307200}"
case "$max_bytes" in ''|*[!0-9]*) max_bytes=307200 ;; esac
if [ "$size" -gt "$max_bytes" ]; then
  rm -f "$diff_file"
  say "skipped: the code diff $short_mb..$short_head is $((size / 1024)) KB, over the $((max_bytes / 1024)) KB cap (AI_REVIEW_MAX_BYTES) a review can use."
fi

# The full contents of each changed code file, smallest first, while the budget lasts. Smallest
# first because a push that touches one large generated file and five small real ones should still
# show the five, and a file that does not fit is named rather than silently absent (L98).
files_in=0; files_out=0; left_out=""
if [ "${AI_REVIEW_FULL_FILES:-1}" != "0" ]; then
  budget=$((max_bytes - size))
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fsize="${line%% *}"; f="${line#* }"
    case "$fsize" in ''|*[!0-9]*) continue ;; esac
    if [ "$fsize" -le "$budget" ] \
       && { printf '\n\n===== FULL FILE at %s: %s =====\n' "$short_head" "$f"; git show "$head_sha:$f"; } >> "$diff_file" 2>/dev/null; then
      budget=$((budget - fsize)); files_in=$((files_in + 1))
    else
      files_out=$((files_out + 1)); left_out="$left_out $f"
    fi
  done < <(git diff --name-only --diff-filter=AM "$mb" "$head_sha" -- "${CODE_PATHS[@]}" 2>/dev/null \
           | while IFS= read -r f; do [ -n "$f" ] && printf '%s %s\n' "$(git cat-file -s "$head_sha:$f" 2>/dev/null || echo x)" "$f"; done \
           | sort -n)
fi
context_note="diff alone"
if [ "$files_in" -gt 0 ] || [ "$files_out" -gt 0 ]; then
  context_note="diff plus the full text of $files_in of $((files_in + files_out)) changed files"
  [ "$files_out" -gt 0 ] && context_note="$context_note; left out for size:$left_out"
fi

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$branch" ] && [ "$branch" != "HEAD" ] || branch="$short_head"
repo_label="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$repo_dir")")"
model="${AI_REVIEW_MODEL:-sonnet}"
started="$(date +%s)"

# The pending marker is written by the HOOK, before the runner exists, so a nudge fired in the gap
# between this exit and the runner's first instruction still sees that a review is under way.
{
  printf 'repo=%s\nbranch=%s\nsha=%s\nstarted=%s\nmodel=%s\ndeadline=%s\nsession=%s\n' \
    "$repo_label" "$branch" "$head_sha" "$started" "$model" "$AR_DEADLINE" "$session_id"
} > "$pending_file" 2>/dev/null || { rm -f "$diff_file"; say "skipped: could not write $pending_file."; }
touch "$AR_STATE_DIR/.updated" 2>/dev/null || true

# Detached: no stdin, no stdout, no stderr, not waited for, not in this shell's job table.
nohup python3 "$HOOK_DIR/lib/ai-review-run.py" \
  --state-dir "$AR_STATE_DIR" --key "$repo_key" --sha "$head_sha" \
  --repo-label "$repo_label" --branch "$branch" --repo-dir "$repo_dir" \
  --model "$model" --prompt-file "$HOOK_DIR/lib/ai-review-prompt.txt" \
  --diff-file "$diff_file" --deadline "$AR_DEADLINE" --started "$started" \
  </dev/null >/dev/null 2>&1 &
disown "$!" 2>/dev/null || true

say "review of $repo_label $branch ($short_mb..$short_head, $((size / 1024)) KB of code diff, $context_note) started in the background with $model; findings will appear on a later prompt."
