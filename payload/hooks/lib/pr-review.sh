#!/usr/bin/env bash
#
# pr-review.sh: the lessons review of a WHOLE BRANCH before its pull request merges
# (claude-config#560, milestone "Lessons core with PR checkpoint").
#
# Dan's decision, 2026-09-24: the recorded lessons are checked "definitely before a PR", and "PR is
# the net". The push review (ai-review-on-push.sh) cannot be that net: it runs on the work Mac only
# (740 of 740 firings on Daniels-MacBook-Pro-2 in 60 days printed skipped), reads code types that
# leave out Swift, and sees one push rather than the branch. This reviews merge base to head, every
# file type, on BOTH Macs, with the same reviewer (lib/ai-review-run.py, --kind pr), and the merge
# gate waits for it.
#
#   pr-review.sh start   --dir <repo> [--sha <head>] [--base-ref <ref>]
#   pr-review.sh check   --dir <repo> [--sha <head>] [--base-ref <ref>]
#   pr-review.sh restart --dir <repo> [--sha <head>] [--base-ref <ref>]
#
# start: begins a detached review of <base>..<head> and returns at once. <base> is the merge base
#   of the head with --base-ref (default: origin's default branch). A review that cannot begin is
#   recorded as a FINISHED review saying why, never left as nothing, so the gate can tell "could not
#   run" from "never asked" (L98, L11).
# check: what the merge gate and a repo's own merge script ask. Exit 0 allows the merge, 1 refuses,
#   and stdout says why in either case. No review yet for this head starts one and refuses.
# restart: throws away this head's review, whatever state it is in, and starts it again. The remedy
#   the refusals name for a review that failed or ran out of time.
#
# THE OUTCOMES, each its own named state and its own words (L260: two outcomes with one
# consequence are one outcome, so each consequence is stated):
#   ok, N findings, not yet delivered   refused ONCE, carrying the findings (capped), then allowed.
#                                       Delivered means they reached a session: shown by this
#                                       check or by the nudge on a prompt (<review>.delivered).
#   ok, N findings, delivered / 0       allowed.
#   empty-diff                          allowed: the head adds nothing to the base.
#   running                             refused, with elapsed time against the deadline.
#   timeout, error, empty, unparsed,    refused, with the reason, the restart command, and the one
#   abandoned, could-not-run, too-large command override SKIP_PR_REVIEW=1, which the session must
#                                       explain to Dan before using (a review that cannot run blocks).
#
# THE SIZE CAP AND DEADLINE, measured on whole branches (2026-09-24, the last 150 first parent
# commits on each main, every one a squash merged branch, diff -U20, every file type):
#   claude-config median 16K p95 80K max 441K; Overture median 49K p95 212K max 507K;
#   Ovation median 38K p95 203K max 991K; PostRoll median 31K p95 160K max 212K.
# 11 of 600 were over 300 KB, so PR_REVIEW_MAX_BYTES keeps the push review's 307200: a branch over it
# is refused as too large (1.8% of branches) rather than sent to a reader that could not use it.
# PR_REVIEW_DEADLINE_SECONDS defaults to 600, measured 2026-09-24 with sonnet on two real branches:
# Overture 5c7bdd8 (117 KB with 5 of 10 full files) took 195 s and returned one finding citing L11;
# claude-config #567 (82 KB, 7 of 7 full files) took 231 s and was clean. 600 is about 2.6 times the
# slower. The FIRST attempt at that measurement took 390 s and 600 s and reviewed nothing: the
# headless claude ran Dan's global hooks, and the answer was the end of turn issue review of the
# session. Hence --settings disableAllHooks in the runner, and the `unparsed` outcome.
#
# Environment: AI_REVIEW_STATE_DIR (shared with the push review), PR_REVIEW_DEADLINE_SECONDS,
# PR_REVIEW_MAX_BYTES, AI_REVIEW_MODEL, AI_REVIEW_LESSONS_DIR.

set -uo pipefail

PRR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ai-review-common.sh
. "$PRR_LIB/ai-review-common.sh" 2>/dev/null || {
  echo "The lessons review could not run: $PRR_LIB/ai-review-common.sh is missing, so the review state cannot be read. Nothing was reviewed. Override for one merge, explained to Dan first: SKIP_PR_REVIEW=1 <the merge command>."
  exit 1
}

PRR_DEADLINE="${PR_REVIEW_DEADLINE_SECONDS:-600}"
case "$PRR_DEADLINE" in ''|*[!0-9]*) PRR_DEADLINE=600 ;; esac
PRR_MAX_BYTES="${PR_REVIEW_MAX_BYTES:-307200}"
case "$PRR_MAX_BYTES" in ''|*[!0-9]*) PRR_MAX_BYTES=307200 ;; esac
PRR_SHOW_LINES=20
PRR_LINE_CHARS=300
PRR_OVERRIDE="SKIP_PR_REVIEW=1"

usage() { echo "usage: pr-review.sh start|check|restart --dir <repo> [--sha <head>] [--base-ref <ref>]" >&2; exit 64; }

verb="${1:-}"; shift || true
dir="."; sha=""; base_ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    # A flag given last has no value, and `shift 2` then fails WITHOUT shifting, which loops.
    --dir|--sha|--base-ref)
      [ $# -ge 2 ] || { echo "pr-review.sh: $1 needs a value." >&2; usage; }
      case "$1" in --dir) dir="$2" ;; --sha) sha="$2" ;; --base-ref) base_ref="$2" ;; esac
      shift 2 ;;
    *) usage ;;
  esac
done
case "$verb" in start|check|restart) ;; *) usage ;; esac

top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "The lessons review could not run: $dir is not inside a git repository. Override for one merge, explained to Dan first: $PRR_OVERRIDE <the merge command>."
  exit 1
}
cd "$top" || exit 1
[ -n "$sha" ] || sha="$(git rev-parse HEAD 2>/dev/null)"
# A head this checkout does not hold yet (a merge run from a checkout behind the remote) is fetched
# rather than refused: the pull request's head is on origin by definition.
if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
  git fetch -q origin "$sha" 2>/dev/null || true
fi
full_sha="$(git rev-parse --verify -q "$sha^{commit}" 2>/dev/null)"
short="${sha:0:7}"

key="$(ar_repo_key "$top")" || { echo "The lessons review could not run: could not key the repository at $top. Override: $PRR_OVERRIDE."; exit 1; }
mkdir -p "$AR_STATE_DIR" 2>/dev/null
name="$key-pr-${full_sha:-$sha}"
final="$AR_STATE_DIR/$name.txt"
pending="$final.pending"
delivered="$final.delivered"
repo_label="$(basename "$top")"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$branch" ] && [ "$branch" != "HEAD" ] || branch="$short"

elapsed_text() {   # seconds -> "1m 42s" or "42s"
  local s="$1"
  case "$s" in ''|*[!0-9]*) printf 'an unknown time'; return ;; esac
  if [ "$s" -ge 60 ]; then printf '%dm %02ds' "$((s / 60))" "$((s % 60))"; else printf '%ds' "$s"; fi
}

meta_of() {   # $1 = file, $2 = field
  awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit } /^$/ { exit }' "$1" 2>/dev/null
}

# A review that could not begin still becomes a finished file, in its own words.
record() {   # $1 = status, $2 = body, $3 = base or empty
  local now; now="$(date +%s)"
  {
    printf 'repo=%s\nbranch=%s\nsha=%s\nstarted=%s\nfinished=%s\nstatus=%s\nkind=pr\nbase=%s\nfindings=\n\n' \
      "$repo_label" "$branch" "${full_sha:-$sha}" "$now" "$now" "$1" "${3:-}"
    printf '%s\n' "$2"
  } > "$final.tmp" 2>/dev/null && mv -f "$final.tmp" "$final"
  touch "$AR_STATE_DIR/.updated" 2>/dev/null || true
}

resolve_base_ref() {
  [ -n "$base_ref" ] && { printf '%s' "$base_ref"; return; }
  local d
  d="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  [ -n "$d" ] && { printf '%s' "$d"; return; }
  for d in origin/main origin/master; do
    git rev-parse -q --verify "$d" >/dev/null 2>&1 && { printf '%s' "$d"; return; }
  done
}

do_start() {
  if [ -e "$final" ] || [ -e "$pending" ]; then
    echo "The lessons review of $repo_label $branch at $short has already been run, or is still running."
    return 0
  fi
  if [ -z "$full_sha" ]; then
    record could-not-run "The commit $sha is not in this checkout and could not be fetched from origin, so there is nothing to review."
    echo "The lessons review could not run: $sha is not in this checkout."; return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    record could-not-run "python3 is not on PATH, and the reviewer (lib/ai-review-run.py) runs under it. Install python3 and run: bash ~/.claude/hooks/lib/pr-review.sh restart --dir $top --sha $full_sha"
    echo "The lessons review could not run: python3 is not on PATH."; return 0
  fi
  if ! command -v claude >/dev/null 2>&1; then
    record could-not-run "No claude command is on PATH, so no reviewer can run. Install the Claude Code CLI and run: bash ~/.claude/hooks/lib/pr-review.sh restart --dir $top --sha $full_sha"
    echo "The lessons review could not run: claude is not on PATH."; return 0
  fi
  local ref mb
  ref="$(resolve_base_ref)"
  mb=""
  [ -n "$ref" ] && mb="$(git merge-base "$ref" "$full_sha" 2>/dev/null)"
  if [ -z "$mb" ]; then
    record could-not-run "Could not find where this branch left its base (${ref:-no origin default branch found}), so the whole branch cannot be told from the rest of history."
    echo "The lessons review could not run: no merge base with ${ref:-the base branch}."; return 0
  fi
  local short_mb="${mb:0:7}" diff_file="$AR_STATE_DIR/$name.diff" total size
  total="$(git diff --name-only "$mb" "$full_sha" 2>/dev/null | awk 'END { print NR }')"
  if [ "${total:-0}" -eq 0 ]; then
    record empty-diff "The head $short adds nothing to $ref (merge base $short_mb), so there is nothing to review." "$mb"
    echo "Nothing to review: $short adds nothing to $ref."; return 0
  fi
  {
    printf '===== FILES THIS PUSH CHANGED: the complete list, %s file(s), from %s..%s =====\n' "$total" "$short_mb" "$short"
    git diff --name-status "$mb" "$full_sha" 2>/dev/null | awk -F '\t' 'NR > 500 { over++; next } { printf "%s\t%s\t(changed, shown below)\n", $1, $NF } END { if (over) printf "TRUNCATED: %d more changed file(s) are not listed\n", over }'
    printf '===== END OF FILE LIST =====\n\n'
    git diff --no-color -U20 "$mb" "$full_sha"
  } > "$diff_file" 2>/dev/null
  size="$(wc -c < "$diff_file" | tr -d '[:space:]')"
  if [ "${size:-0}" -gt "$PRR_MAX_BYTES" ]; then
    rm -f "$diff_file"
    record too-large "The whole branch diff $short_mb..$short is $((size / 1024)) KB, over the $((PRR_MAX_BYTES / 1024)) KB a review can use (PR_REVIEW_MAX_BYTES; 11 of 600 measured branches were over it). Split the branch, or merge with the override after telling Dan why." "$mb"
    echo "The lessons review could not run: the branch diff is too large ($((size / 1024)) KB)."; return 0
  fi
  local fitted in out note
  fitted="$(ar_append_full_files "$diff_file" "$mb" "$full_sha" $((PRR_MAX_BYTES - size)))"
  in="${fitted%% *}"; out="${fitted#* }"; out="${out%% *}"
  note="diff plus the full text of $in of $((in + out)) changed files"
  local model="${AI_REVIEW_MODEL:-sonnet}" started
  started="$(date +%s)"
  printf 'repo=%s\nbranch=%s\nsha=%s\nstarted=%s\nmodel=%s\ndeadline=%s\nkind=pr\nbase=%s\n' \
    "$repo_label" "$branch" "$full_sha" "$started" "$model" "$PRR_DEADLINE" "$mb" > "$pending" 2>/dev/null \
    || { rm -f "$diff_file"; record could-not-run "Could not write $pending."; echo "The lessons review could not run: could not write its state."; return 0; }
  touch "$AR_STATE_DIR/.updated" 2>/dev/null || true
  # Detached: no standard streams held, not waited for, not in this shell's job table.
  nohup python3 "$PRR_LIB/ai-review-run.py" \
    --state-dir "$AR_STATE_DIR" --key "$key" --sha "$full_sha" --name "$name" --kind pr --base "$mb" \
    --repo-label "$repo_label" --branch "$branch" --repo-dir "$top" \
    --model "$model" --prompt-file "$PRR_LIB/ai-review-prompt.txt" \
    --scope-file "$PRR_LIB/ai-review-pr-scope.txt" \
    --lessons-dir "${AI_REVIEW_LESSONS_DIR:-$PRR_LIB/../..}" \
    --diff-file "$diff_file" --deadline "$PRR_DEADLINE" --started "$started" \
    </dev/null >/dev/null 2>&1 &
  disown "$!" 2>/dev/null || true
  echo "The lessons review of the whole branch $repo_label $branch ($short_mb..$short, $((size / 1024)) KB, $note) started in the background with $model; the merge waits for it (deadline $(elapsed_text "$PRR_DEADLINE"))."
}

remedy() {
  printf 'Run it again with: bash ~/.claude/hooks/lib/pr-review.sh restart --dir %s --sha %s\nOr, only after telling Dan why, merge with the one command override: %s <the merge command>.\n' "$top" "${full_sha:-$sha}" "$PRR_OVERRIDE"
}

do_check() {
  local now; now="$(date +%s)"
  if [ ! -e "$final" ] && [ -e "$pending" ]; then
    local st dl
    st="$(meta_of "$pending" started)"; dl="$(meta_of "$pending" deadline)"
    case "$st" in ''|*[!0-9]*) st="$now" ;; esac
    case "$dl" in ''|*[!0-9]*) dl="$PRR_DEADLINE" ;; esac
    if [ $((now - st)) -gt $((dl + 60)) ]; then
      record abandoned "The review was started and never finished: $(elapsed_text $((now - st))) passed with no answer written, which means the background runner died. Nothing was read back." "$(meta_of "$pending" base)"
      rm -f "$pending"
    else
      echo "Refusing to merge yet: the lessons review of $repo_label $branch at $short is still running ($(elapsed_text $((now - st))) of its $(elapsed_text "$dl") deadline). Run the merge again once it has finished."
      return 1
    fi
  fi
  if [ ! -e "$final" ]; then
    local started_msg
    started_msg="$(do_start)"
    if [ -e "$pending" ]; then
      echo "Refusing to merge yet: no lessons review existed for $repo_label at $short, so one was started now. $started_msg Run the merge again once it has finished."
      return 1
    fi
    [ -e "$final" ] || { echo "Refusing to merge: the lessons review could neither start nor record why. $started_msg"; remedy; return 1; }
  fi
  local status findings took
  status="$(meta_of "$final" status)"
  findings="$(meta_of "$final" findings)"
  took="$(elapsed_text $(( $(meta_of "$final" finished || echo 0) - $(meta_of "$final" started || echo 0) )))"
  case "$status" in
    ok)
      case "$findings" in ''|*[!0-9]*) findings="$(awk 'found && /^[^ :]+:[0-9]+: / { n++ } /^$/ { found = 1 } END { print n + 0 }' "$final")" ;; esac
      if [ "$findings" -eq 0 ]; then
        echo "The lessons review of $repo_label $branch at $short finished with 0 findings."
        touch "$delivered" 2>/dev/null; return 0
      fi
      if [ -e "$delivered" ]; then
        echo "The lessons review of $repo_label $branch at $short finished with $findings finding(s), already delivered to the session."
        return 0
      fi
      local noun="findings"; [ "$findings" -eq 1 ] && noun="finding"
      echo "Refusing to merge this once: the lessons review of the whole branch $repo_label $branch at $short finished ($took) with $findings $noun, and they have not reached the session yet. Here they are. Check each against the code, fix what is real or say why it is not, then run the merge again; it will not be refused for these again."
      ar_capped_body "$final" "$PRR_SHOW_LINES" "$PRR_LINE_CHARS"
      touch "$delivered" 2>/dev/null
      return 1
      ;;
    empty-diff)
      echo "The lessons review had nothing to read: the diff was empty. $(ar_capped_body "$final" 2 "$PRR_LINE_CHARS")"
      return 0
      ;;
    timeout) echo "Refusing to merge: the lessons review of $repo_label at $short did not finish inside its deadline ($took), so the branch was never read." ;;
    error) echo "Refusing to merge: the lessons review of $repo_label at $short failed:" ; ar_capped_body "$final" 8 "$PRR_LINE_CHARS" ;;
    unparsed) echo "Refusing to merge: the lessons review of $repo_label at $short answered, but not in the review's format, so it is not a review. The start of what it said:"; ar_capped_body "$final" 6 "$PRR_LINE_CHARS" ;;
    empty) echo "Refusing to merge: the lessons review of $repo_label at $short came back empty (the reviewer printed nothing), which is not the same as finding nothing." ;;
    abandoned) echo "Refusing to merge: the lessons review of $repo_label at $short was started and never finished; the background runner died." ;;
    could-not-run) echo "Refusing to merge: the lessons review of $repo_label at $short could not run:"; ar_capped_body "$final" 4 "$PRR_LINE_CHARS" ;;
    too-large) echo "Refusing to merge: the lessons review of $repo_label at $short could not run, the branch is too large to review:"; ar_capped_body "$final" 2 "$PRR_LINE_CHARS" ;;
    *) echo "Refusing to merge: the lessons review of $repo_label at $short recorded an outcome this gate does not know (${status:-none})." ;;
  esac
  remedy
  return 1
}

case "$verb" in
  start) do_start ;;
  check) do_check; exit $? ;;
  restart) rm -f "$final" "$pending" "$delivered"; do_start ;;
esac
exit 0
