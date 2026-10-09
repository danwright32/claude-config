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
#   pr-review.sh start   --dir <repo> [--sha <head>] [--base-ref <ref>] [--branch <name>] [--gate merge|push]
#   pr-review.sh check   --dir <repo> [--sha <head>] [--base-ref <ref>] [--branch <name>] [--gate merge|push]
#   pr-review.sh restart --dir <repo> [--sha <head>] [--base-ref <ref>] [--branch <name>] [--gate merge|push]
#
# start: begins a detached review of <base>..<head> and returns at once. <base> is the merge base
#   of the head with --base-ref (default: origin's default branch). A ref on origin is FETCHED
#   first, so the base is the branch's real tip and never this checkout's copy of it, which can be
#   any number of commits stale (claude-config#852: a merge from a primary checkout 130 commits
#   behind diffed 305 KB against a 300 KB cap). A review that cannot begin is recorded as a
#   FINISHED review saying why, never left as nothing, so the gate can tell "could not run" from
#   "never asked" (L98, L11).
# check: what the merge gate and a repo's own merge script ask. Exit 0 allows the merge, 1 refuses
#   on a verdict, and 3 refuses because the review has not finished yet (running, or started by
#   this very check), so a caller that waits (lib/merge-when-ready.sh) can tell the two apart
#   without reading the words. stdout says why in every case. A caller that only asks "may this
#   merge" treats any non zero as a refusal, as before. No review yet for this head starts one.
# --branch: the label the messages and the review file carry, which is the PULL REQUEST's head
#   branch when the caller knows it (the merge gate reads headRefName). Without it, the checkout's
#   branch is used only when the checkout stands on the reviewed head; otherwise the label is the
#   short commit. The checkout's branch used to label every review, so a merge run from a checkout
#   another session had on fix/2210-corrected-number-wins named that branch in a refusal about a
#   different pull request (claude-config#852).
# restart: throws away this head's review, whatever state it is in, and starts it again. The remedy
#   the refusals name for a review that failed or ran out of time.
# --gate push: the push gate asking (pr-review-push-gate.sh, claude-config#599). Same verdicts, its
#   own words, and a presented read key recorded where only pushes read it (see below).
# A finished review is reused by check only when it covers the range asked about: with --base-ref,
#   its recorded base must be an ancestor of (or be) that ref's merge base with the head, else it is
#   started again (claude-config#599), because a review started at commit or push time reads from the
#   default branch and a merge into an older base brings commits it never read.
#
# THE OUTCOMES, each its own named state and its own words (L260: two outcomes with one
# consequence are one outcome, so each consequence is stated):
#   ok, N findings, not yet read        refused, carrying the findings (capped) and their READ KEY,
#                                       on every attempt until a merge presents the key as
#                                       PR_REVIEW_READ=<key> (claude-config#788). Printing them is
#                                       not reading them: a refusal can be hidden behind another
#                                       hook's, and the nudge reaches whichever session prompts next.
#   ok, N findings, read / 0            allowed (<review>.acknowledged).
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
# Before refusing, a branch over the cap leaves out the files PROVEN to need no reading
# (ar_left_out_candidates: generated by .gitattributes at base and head, fixture data, byte for byte
# mod-kit copies; claude-config#583), putting back whichever still fit, and is reviewed when the rest
# fits. Every file left out is named with its size in the start line, the reviewer's file list and
# every verdict. Measured 2026-10-08 on the range that became #951 and #974 (ae96c5a4^..f73a8132):
# 583 KB, of which 132 KB was twelve such copies. A branch under the cap leaves out nothing.
# A branch still over the cap is read in GROUPS of files that each fit (plan_groups, #601), every
# group by the same runner with the same deadline, all at once, and its review is ok only when every
# group returned one; a group that timed out, failed or answered in some other shape makes the
# branch's review that outcome, which refuses as before. One review file holds every group's
# findings under its own header, so one read key covers them. It is refused as too large only when
# no split fits: one file's own diff over what a group can hold, or more than PR_REVIEW_MAX_GROUPS
# (8) groups. That same 2026-10-08 range, run through it with a stand-in reviewer: 3.7 s to plan,
# two groups of 30 and 21 files, inputs of 306 and 304 KB.
# PR_REVIEW_DEADLINE_SECONDS defaults to 600, measured 2026-09-24 with sonnet on two real branches:
# Overture 5c7bdd8 (117 KB with 5 of 10 full files) took 195 s and returned one finding citing L11;
# claude-config #567 (82 KB, 7 of 7 full files) took 231 s and was clean. 600 is about 2.6 times the
# slower. The FIRST attempt at that measurement took 390 s and 600 s and reviewed nothing: the
# headless claude ran Dan's global hooks, and the answer was the end of turn issue review of the
# session. Hence --settings disableAllHooks in the runner, and the `unparsed` outcome. And, measured
# 2026-10-08 (claude-config#804), the reviewer answered through Claude Code's built in ReportFindings
# tool in 6 of about 10 rounds on one pull request, leaving no finding line to read, so the runner
# also disallows that tool and the text it parses is the review's only channel.
#
# Environment: AI_REVIEW_STATE_DIR (shared with the push review), PR_REVIEW_DEADLINE_SECONDS,
# PR_REVIEW_MAX_BYTES, PR_REVIEW_MAX_GROUPS, AI_REVIEW_MODEL, AI_REVIEW_LESSONS_DIR.

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
PRR_MAX_GROUPS="${PR_REVIEW_MAX_GROUPS:-8}"
case "$PRR_MAX_GROUPS" in ''|*[!0-9]*|0) PRR_MAX_GROUPS=8 ;; esac
PRR_SHOW_LINES=20
PRR_LINE_CHARS=300
PRR_OVERRIDE="SKIP_PR_REVIEW=1"

usage() { echo "usage: pr-review.sh start|check|restart --dir <repo> [--sha <head>] [--base-ref <ref>] [--branch <name>] [--gate merge|push]" >&2; exit 64; }

verb="${1:-}"; shift || true
dir="."; sha=""; base_ref=""; branch_arg=""; gate="merge"
while [ $# -gt 0 ]; do
  case "$1" in
    # A flag given last has no value, and `shift 2` then fails WITHOUT shifting, which loops.
    --dir|--sha|--base-ref|--branch|--gate)
      [ $# -ge 2 ] || { echo "pr-review.sh: $1 needs a value." >&2; usage; }
      case "$1" in --dir) dir="$2" ;; --sha) sha="$2" ;; --base-ref) base_ref="$2" ;; --branch) branch_arg="$2" ;; --gate) gate="$2" ;; esac
      shift 2 ;;
    *) usage ;;
  esac
done
# _groups is internal: the detached process that runs a branch's groups and writes its review (#601).
case "$verb" in start|check|restart|_groups) ;; *) usage ;; esac
# --gate: which action is asking (claude-config#599). It changes the WORDS of check's answers and
# where a presented read key is recorded, never the verdict: a push presenting the key records it in
# <review>.push-acknowledged, which a later push reads and a merge does NOT, so the merge gate asks
# for the key itself exactly as before (the key the push was shown still reads the same review).
case "$gate" in merge|push) ;; *) usage ;; esac
act="$gate"

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
acknowledged="$final.acknowledged"  # a merge presented the read key; this is what allows it
push_acknowledged="$final.push-acknowledged"  # a push presented it; allows later pushes, never a merge
leftout="$final.leftout"            # the files this review did not read, for its verdict (#583)
# A review in groups (#601) keeps each group's input and answer in a folder of its own RUN, named by
# the run= its pending marker records, so a restarted review never reads an answer an earlier run's
# reviewer left or was still writing (lessons review of #601). parts is that folder once known.
parts_root="$AR_STATE_DIR/parts"
parts=""
parts_for() { printf '%s/%s.%s' "$parts_root" "$name" "$1"; }   # $1 = a run
repo_label="$(basename "$top")"
# The label: the caller's (the pull request's head branch), else this checkout's branch only when the
# checkout stands on the reviewed commit, else the commit itself (claude-config#852). Line breaks and
# spaces are removed, since the label is one field of the review file's header.
branch="$(printf '%s' "$branch_arg" | tr -d '[:space:]')"
if [ -z "$branch" ] && [ -n "$full_sha" ] && [ "$(git rev-parse HEAD 2>/dev/null)" = "$full_sha" ]; then
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [ "$branch" = "HEAD" ] && branch=""
fi
[ -n "$branch" ] || branch="$short"

elapsed_text() {   # seconds -> "1m 42s" or "42s"
  local s="$1"
  case "$s" in ''|*[!0-9]*) printf 'an unknown time'; return ;; esac
  if [ "$s" -ge 60 ]; then printf '%dm %02ds' "$((s / 60))" "$((s % 60))"; else printf '%ds' "$s"; fi
}

meta_of() {   # $1 = file, $2 = field
  awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit } /^$/ { exit }' "$1" 2>/dev/null
}

# A review that could not begin still becomes a finished file, in its own words.
record() {   # $1 = status, $2 = body, $3 = base or empty, $4 = how many groups, for a review in groups
  local now; now="$(date +%s)"
  {
    printf 'repo=%s\nbranch=%s\nsha=%s\nstarted=%s\nfinished=%s\nstatus=%s\nkind=pr\nbase=%s\n' \
      "$repo_label" "$branch" "${full_sha:-$sha}" "$now" "$now" "$1" "${3:-}"
    [ -n "${4:-}" ] && printf 'groups=%s\n' "$4"
    printf 'findings=\n\n'
    printf '%s\n' "$2"
  } > "$final.tmp" 2>/dev/null && mv -f "$final.tmp" "$final" && ar_pr_ledger "$final" "$top"
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

# Bring a base on origin up to date before it is used, so the merge base is the branch's real tip
# (claude-config#852). Only a ref named origin/<branch> is fetched; a commit or a local ref is used as
# given. When the fetch fails the review goes ahead from this checkout's copy, and base_note says so
# in the message. That copy can only be STALE, never ahead, and a stale base makes the diff LARGER
# (main's own commits read as the branch's), never smaller, so nothing on the branch goes unreviewed;
# what it can cost is a too-large refusal, which the note then explains (L93, L11).
base_note=""
refresh_base_ref() {   # $1 = ref
  case "$1" in
    origin/HEAD) return 0 ;;
    origin/?*) ;;
    *) return 0 ;;
  esac
  local b="${1#origin/}"
  if ! git fetch -q origin "+refs/heads/$b:refs/remotes/origin/$b" >/dev/null 2>&1; then
    base_note=" (could not fetch $1 from origin, so the base is this checkout's copy of it, which may be stale and then makes the diff larger than the branch)"
  fi
}

# The complete list of changed files the reviewer reads first. Each file is "(changed, shown below)"
# unless the marks file ($1, "<path><TAB><mark>" lines) gives it another mark. Called from do_start,
# whose total, short_mb, mb and full_sha it reads.
file_list() {   # $1 = marks file
  printf '===== FILES THIS PUSH CHANGED: the complete list, %s file(s), from %s..%s =====\n' "$total" "$short_mb" "$short"
  git -c core.quotepath=false diff --name-status "$mb" "$full_sha" 2>/dev/null | awk -F '\t' -v marks="$1" '
    BEGIN { while ((getline l < marks) > 0) { i = index(l, "\t"); if (i) m[substr(l, 1, i - 1)] = substr(l, i + 1) } }
    NR > 500 { over++; next }
    { printf "%s\t%s\t%s\n", $1, $NF, (($NF in m) ? m[$NF] : "(changed, shown below)") }
    END { if (over) printf "TRUNCATED: %d more changed file(s) are not listed\n", over }'
  printf '===== END OF FILE LIST =====\n\n'
}

# "<bytes><TAB><path><TAB><kind><TAB><why>" rows -> the file list's mark for each, saying it is
# not shown.
left_out_marks() {   # $1 = rows
  local b p kind why
  while IFS=$'\t' read -r b p kind why; do
    [ -n "$p" ] || continue
    printf '%s\tleft out of this review (%s, %s): its changes are not shown below\n' "$p" "$why" "$(ar_size_text "$b")"
  done <<ROWS
$1
ROWS
}

# A branch over the cap, without the files ar_left_out_candidates PROVES need no reading
# (claude-config#583): generated by the repository's own .gitattributes, fixture data, or a byte for
# byte copy of a mod-kit file. Every other file is read, so the code is never what gives way. The
# candidates are put back smallest first while they still fit, so a file is left out only when it
# must be. Rewrites $diff_file; sets left_excl (an exclude pathspec for each file left out); writes
# the files left out to $leftout, which the start line, every verdict on this head and the nudge
# then name through ar_left_out_note (L98: nothing silently unreviewed). Returns 1, changing
# nothing, when no file is proven. Called from do_start, whose variables it reads and sets.
leave_out_proven() {
  local cands p kind why b rows="" kept="" gen_in="" budget built
  local marks="$AR_STATE_DIR/$name.marks" code="$AR_STATE_DIR/$name.code"
  local -a all_excl=() incl=()
  cands="$(ar_left_out_candidates "$mb" "$full_sha")"
  [ -n "$cands" ] || return 1
  while IFS=$'\t' read -r p kind why; do
    [ -n "$p" ] || continue
    # Measured as ar_review_diff would show it: a generated file's changed lines only.
    case "$kind" in
      generated) b="$(git diff --no-color -U0 "$mb" "$full_sha" -- ":(literal)$p" 2>/dev/null | wc -c | tr -d '[:space:]')" ;;
      *) b="$(git diff --no-color -U20 "$mb" "$full_sha" -- ":(literal)$p" 2>/dev/null | wc -c | tr -d '[:space:]')" ;;
    esac
    rows="$rows${b:-0}"$'\t'"$p"$'\t'"$kind"$'\t'"$why"$'\n'
    all_excl+=(":(exclude,literal)$p")
  done <<CANDS
$cands
CANDS
  rows="$(printf '%s' "$rows" | sort -t "$(printf '\t')" -k1,1n)"
  # A file marked generated but not proven (marked only by this branch) stays, at no context.
  ar_review_diff "$(ar_generated_paths "$mb" "$full_sha" "${all_excl[@]}")" "$mb" "$full_sha" "${all_excl[@]}" > "$code" 2>/dev/null
  # The budget for putting files back is measured against the file list with every candidate
  # marked left out, the longest that list can be.
  left_out_marks "$rows" > "$marks"
  budget=$((PRR_MAX_BYTES - $(file_list "$marks" | wc -c) - $(wc -c < "$code")))
  while IFS=$'\t' read -r b p kind why; do
    [ -n "$p" ] || continue
    if [ "$budget" -ge "$b" ]; then
      budget=$((budget - b)); incl+=(":(literal)$p")
      [ "$kind" = generated ] && gen_in="$gen_in$p"$'\n'
    else
      kept="$kept$b"$'\t'"$p"$'\t'"$kind"$'\t'"$why"$'\n'
    fi
  done <<ROWS
$rows
ROWS
  for built in with-put-back all-left-out; do
    left_out_marks "$kept" > "$marks"
    {
      file_list "$marks"
      cat "$code"
      [ "${#incl[@]}" -gt 0 ] && ar_review_diff "$gen_in" "$mb" "$full_sha" "${incl[@]}"
    } > "$diff_file" 2>/dev/null
    # The generated files' own header can tip a put back set over; then none is put back.
    [ "$(wc -c < "$diff_file")" -le "$PRR_MAX_BYTES" ] || [ "${#incl[@]}" -eq 0 ] && break
    kept="$rows"; incl=(); gen_in=""
  done
  rm -f "$marks" "$code"
  left_excl=()
  while IFS=$'\t' read -r b p kind why; do
    [ -n "$p" ] && left_excl+=(":(exclude,literal)$p")
  done <<KEPT
$kept
KEPT
  printf '%s' "$kept" > "$leftout" 2>/dev/null
  return 0
}

do_start() {
  if [ -e "$final" ] || [ -e "$pending" ]; then
    echo "The lessons review of $repo_label $branch at $short has already been run, or is still running."
    return 0
  fi
  # A new review answers for itself: a read key or an acknowledgement left by an earlier review of
  # this head (its file swept, or restarted) must not let THESE findings through unread (#788).
  rm -f "$acknowledged" "$push_acknowledged" "$final.readkey"* "$final.readkeys"* "$leftout" 2>/dev/null
  # The groups of a review in groups (#601) are removed once it is written; these are what is left
  # when its waiting process died and nothing wrote it up, swept on the reviews' own 14 days.
  find "$parts_root" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + 2>/dev/null || true
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
  [ -n "$ref" ] && refresh_base_ref "$ref"
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
    file_list /dev/null
    ar_review_diff "$(ar_generated_paths "$mb" "$full_sha")" "$mb" "$full_sha"
  } > "$diff_file" 2>/dev/null
  size="$(wc -c < "$diff_file" | tr -d '[:space:]')"
  # Over the cap, the files proven to need no reading are left out (claude-config#583), and the
  # review goes ahead only when what is left fits; under it, nothing is left out.
  local -a left_excl=()
  local whole_size="$size"
  if [ "${size:-0}" -gt "$PRR_MAX_BYTES" ] && leave_out_proven; then
    size="$(wc -c < "$diff_file" | tr -d '[:space:]')"
  fi
  local model="${AI_REVIEW_MODEL:-sonnet}" started
  if [ "${size:-0}" -gt "$PRR_MAX_BYTES" ]; then
    # Still over: read in groups of files that each fit (#601), and refused as too large only when
    # no split fits. The list of what was left out stays beside either, which names it.
    rm -f "$diff_file"
    local groups_n=0 groups_text="" groups_refusal="" run_id
    run_id="$(date +%s)-$$"
    parts="$(parts_for "$run_id")"
    if plan_groups; then
      started="$(date +%s)"
      printf 'repo=%s\nbranch=%s\nsha=%s\nstarted=%s\nmodel=%s\ndeadline=%s\nkind=pr\nbase=%s\ndir=%s\ngroups=%s\nrun=%s\n' \
        "$repo_label" "$branch" "$full_sha" "$started" "$model" "$PRR_DEADLINE" "$mb" "$top" "$groups_n" "$run_id" > "$pending" 2>/dev/null \
        || { rm -rf "$parts"; record could-not-run "Could not write $pending."; echo "The lessons review could not run: could not write its state."; return 0; }
      touch "$AR_STATE_DIR/.updated" 2>/dev/null || true
      # Detached, as one reviewer is: the process that runs every group at once, waits for them,
      # and writes the branch's review from their answers.
      nohup bash "$PRR_LIB/pr-review.sh" _groups --dir "$top" --sha "$full_sha" --branch "$branch" \
        </dev/null >/dev/null 2>&1 &
      disown "$!" 2>/dev/null || true
      echo "The lessons review of the whole branch $repo_label $branch ($short_mb..$short, $(ar_size_text "$whole_size") of diff, over the $((PRR_MAX_BYTES / 1024)) KB one review can use) started in the background in $groups_n groups of files read at once ($groups_text), each by $model with the same deadline; the $act waits for every group (deadline $(elapsed_text "$PRR_DEADLINE"))$base_note."
      ar_left_out_note "$leftout"
      return 0
    fi
    rm -rf "$parts"
    local after="" after_line=""
    if [ "${#left_excl[@]}" -gt 0 ]; then
      after=", $(ar_size_text "$size") without the files proven to need no reading"
      after_line=$'\n'"Leaving out the ${#left_excl[@]} file(s) proven to need no reading still leaves $(ar_size_text "$size")."
    fi
    record too-large "The whole branch diff $short_mb..$short is $(ar_size_text "$whole_size"), over the $((PRR_MAX_BYTES / 1024)) KB a review can use (PR_REVIEW_MAX_BYTES; 11 of 600 measured branches were over it)$base_note, and it cannot be read in groups of files either: $groups_refusal. Split the branch, or merge with the override after telling Dan why.$after_line" "$mb"
    echo "The lessons review could not run: the branch diff is too large ($(ar_size_text "$whole_size")$after, and $groups_refusal)."; return 0
  fi
  local fitted in out note
  fitted="$(ar_append_full_files "$diff_file" "$mb" "$full_sha" $((PRR_MAX_BYTES - size)) ${left_excl[@]+"${left_excl[@]}"})"
  in="${fitted%% *}"; out="${fitted#* }"; out="${out%% *}"
  note="diff plus the full text of $in of $((in + out)) changed files"
  [ "${#left_excl[@]}" -gt 0 ] && note="$note; the whole diff was $(ar_size_text "$whole_size"), over the $((PRR_MAX_BYTES / 1024)) KB cap, so the files named below were left out"
  started="$(date +%s)"
  printf 'repo=%s\nbranch=%s\nsha=%s\nstarted=%s\nmodel=%s\ndeadline=%s\nkind=pr\nbase=%s\ndir=%s\n' \
    "$repo_label" "$branch" "$full_sha" "$started" "$model" "$PRR_DEADLINE" "$mb" "$top" > "$pending" 2>/dev/null \
    || { rm -f "$diff_file"; record could-not-run "Could not write $pending."; echo "The lessons review could not run: could not write its state."; return 0; }
  touch "$AR_STATE_DIR/.updated" 2>/dev/null || true
  # Detached: no standard streams held, not waited for, not in this shell's job table.
  run_reviewer "$AR_STATE_DIR" "$name" "$diff_file" "$mb" "$model" "$PRR_DEADLINE" "$started" \
    </dev/null >/dev/null 2>&1 &
  disown "$!" 2>/dev/null || true
  echo "The lessons review of the whole branch $repo_label $branch ($short_mb..$short, $((size / 1024)) KB, $note) started in the background with $model; the $act waits for it (deadline $(elapsed_text "$PRR_DEADLINE"))$base_note."
  ar_left_out_note "$leftout"
}

# One reviewer over one review input, waited for: the single review of a branch that fits, and
# each group of one that does not (#601), so the two can never be run two ways (L613).
run_reviewer() {   # $1 = state dir, $2 = name, $3 = diff file, $4 = base, $5 = model, $6 = deadline, $7 = started
  nohup python3 "$PRR_LIB/ai-review-run.py" \
    --state-dir "$1" --key "$key" --sha "$full_sha" --name "$2" --kind pr --base "$4" \
    --repo-label "$repo_label" --branch "$branch" --repo-dir "$top" \
    --model "$5" --prompt-file "$PRR_LIB/ai-review-prompt.txt" \
    --scope-file "$PRR_LIB/ai-review-pr-scope.txt" \
    --lessons-dir "${AI_REVIEW_LESSONS_DIR:-$PRR_LIB/../..}" \
    --diff-file "$3" --deadline "$6" --started "$7" \
    </dev/null >/dev/null 2>&1
}

# What each group is told about itself, after the complete file list.
group_note() {   # $1 = this group, $2 = how many
  printf '===== THIS REVIEW IS GROUP %s OF %s OF THE WHOLE BRANCH: the branch is over the size one review can use, so its files are read in %s groups at once, each by its own reviewer. Review only the files whose changes are shown below. The list above names every file the branch changed; a file marked as reviewed in another group is read there, so its absence below is not a finding. =====\n\n' "$1" "$2" "$2"
}

# A BRANCH STILL OVER THE CAP, in groups of files whose review input each fits it (claude-config#601).
# Slate #3049 (456 KB across about 86 files) was green and read by hand, and could only merge by Dan
# clicking merge on GitHub. Every file not left out (#583) is measured as ar_review_diff shows it,
# and the files are packed in path order, so a folder's files tend to share a group, each group
# holding as much as fits beside the complete file list (every file marked shown below, reviewed in
# another group, or left out) and the note saying which group it is. Then each group's own files'
# full text is added while it fits, as one review's is. Called from do_start, whose variables it
# reads. Writes $parts/<name>-g<k>.diff for each group and sets groups_n and groups_text, or returns
# 1 with groups_refusal saying why no split fits: one file's own diff over what a group can hold, or
# more groups than PR_REVIEW_MAX_GROUPS (8 by default, the branches measured on 2026-09-24 needing
# at most 4) runs at once. A group that comes out over the cap all the same refuses too: an estimate
# is never trusted over the measured input (L42).
plan_groups() {
  local p b k sz budget fitted gin lo_marks="" ng_names ng_sizes gen_reserve=0
  local rows="$parts/rows" marks="$parts/marks" gen
  local -a ng_excl=() gspecs=()
  rm -rf "$parts"
  mkdir -p "$parts" 2>/dev/null || { groups_refusal="its working folder $parts could not be made"; return 1; }
  : > "$rows"
  gen="$(ar_generated_paths "$mb" "$full_sha" ${left_excl[@]+"${left_excl[@]}"})"
  ng_excl=(${left_excl[@]+"${left_excl[@]}"})
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    ng_excl+=(":(exclude,literal)$p")
    # A generated file is shown at no context, and named in its section's header line.
    b="$(git diff --no-color -U0 "$mb" "$full_sha" -- ":(literal)$p" 2>/dev/null | wc -c | tr -d '[:space:]')"
    printf '%s\t%s\n' "$((b + ${#p} + 1))" "$p" >> "$rows"
    gen_reserve=300
  done <<GEN
$gen
GEN
  # Every other file measured in one pass: one diff, cut at each file's header, paired with the
  # names in the order git gives both. A count that disagrees measures each file on its own instead.
  ng_names="$(git -c core.quotepath=false diff --no-renames --name-only "$mb" "$full_sha" -- ${ng_excl[@]+"${ng_excl[@]}"} 2>/dev/null)"
  ng_sizes="$(git diff --no-color --no-renames -U20 "$mb" "$full_sha" -- ${ng_excl[@]+"${ng_excl[@]}"} 2>/dev/null \
    | LC_ALL=C awk '/^diff --git / { if (n) print b; n++; b = 0 } { b += length($0) + 1 } END { if (n) print b }')"
  if [ -n "$ng_names" ]; then
    if [ "$(printf '%s\n' "$ng_names" | grep -c .)" = "$(printf '%s\n' "$ng_sizes" | grep -c .)" ]; then
      paste <(printf '%s\n' "$ng_sizes") <(printf '%s\n' "$ng_names") >> "$rows"
    else
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        b="$(git diff --no-color --no-renames -U20 "$mb" "$full_sha" -- ":(literal)$p" 2>/dev/null | wc -c | tr -d '[:space:]')"
        printf '%s\t%s\n' "$b" "$p" >> "$rows"
      done <<NAMES
$ng_names
NAMES
    fi
  fi
  LC_ALL=C sort -t "$(printf '\t')" -k2 -o "$rows" "$rows"
  # The room each group has: the cap less the file list at its longest (every file marked reviewed
  # in another group) and the note, and a generated section's header when there is one.
  [ -s "$leftout" ] && lo_marks="$(left_out_marks "$(cat "$leftout")")"
  { [ -n "$lo_marks" ] && printf '%s\n' "$lo_marks"
    awk -F '\t' '{ printf "%s\t(changed, reviewed in another group: not shown below)\n", $2 }' "$rows"; } > "$marks"
  budget=$((PRR_MAX_BYTES - $(file_list "$marks" | wc -c) - $(group_note 99 99 | wc -c) - gen_reserve))
  if [ "$budget" -le 0 ]; then
    groups_refusal="the list of its $total changed files alone leaves no room under the cap for any file's changes"; return 1
  fi
  k=1; sz=0
  while IFS=$'\t' read -r b p; do
    [ -n "$p" ] || continue
    if [ "$b" -gt "$budget" ]; then
      groups_refusal="$p alone is $(ar_size_text "$b") of diff, more than the $(ar_size_text "$budget") one group can hold beside the file list"; return 1
    fi
    if [ "$sz" -gt 0 ] && [ $((sz + b)) -gt "$budget" ]; then k=$((k + 1)); sz=0; fi
    sz=$((sz + b))
    printf '%s\n' "$p" >> "$parts/g$k.list"
  done < "$rows"
  groups_n="$k"
  if [ "$groups_n" -gt "$PRR_MAX_GROUPS" ]; then
    groups_refusal="it would need $groups_n groups, more than the $PRR_MAX_GROUPS (PR_REVIEW_MAX_GROUPS) that may be read at once"; return 1
  fi
  for k in $(seq 1 "$groups_n"); do
    gspecs=()
    while IFS= read -r p; do [ -n "$p" ] && gspecs+=(":(literal)$p"); done < "$parts/g$k.list"
    { [ -n "$lo_marks" ] && printf '%s\n' "$lo_marks"
      awk -F '\t' 'NR == FNR { mine[$0] = 1; next } !($2 in mine) { printf "%s\t(changed, reviewed in another group: not shown below)\n", $2 }' "$parts/g$k.list" "$rows"
    } > "$marks"
    {
      file_list "$marks"
      group_note "$k" "$groups_n"
      ar_review_diff "$(ar_generated_paths "$mb" "$full_sha" "${gspecs[@]}")" "$mb" "$full_sha" "${gspecs[@]}"
    } > "$parts/$name-g$k.diff" 2>/dev/null
    sz="$(wc -c < "$parts/$name-g$k.diff" | tr -d '[:space:]')"
    if [ "$sz" -gt "$PRR_MAX_BYTES" ]; then
      groups_refusal="group $k came to $(ar_size_text "$sz"), over the cap all the same"; return 1
    fi
    fitted="$(ar_append_full_files "$parts/$name-g$k.diff" "$mb" "$full_sha" $((PRR_MAX_BYTES - sz)) "${gspecs[@]}")"
    gin="${fitted%% *}"
    groups_text="$groups_text${groups_text:+; }group $k: ${#gspecs[@]} file(s), $(ar_size_text "$sz") of diff, the full text of $gin of them"
  done
  rm -f "$rows" "$marks"
  return 0
}

# The internal _groups verb: the detached process do_start leaves running for a review in groups.
# Runs every group's reviewer at once, each with the deadline the pending review records, waits for
# all of them, then writes the branch's review.
do_groups() {
  [ -e "$pending" ] || return 0
  local n k gbase model dl st run
  run="$(meta_of "$pending" run)"
  [ -n "$run" ] || return 1
  # This run's own folder, held for the whole wait: a restart meanwhile starts another run in
  # another folder, and assemble_groups then refuses to write this run's answers up as that one's.
  parts="$(parts_for "$run")"
  n="$(meta_of "$pending" groups)"; gbase="$(meta_of "$pending" base)"
  model="$(meta_of "$pending" model)"; dl="$(meta_of "$pending" deadline)"; st="$(meta_of "$pending" started)"
  case "$n" in ''|*[!0-9]*|0) return 1 ;; esac
  for k in $(seq 1 "$n"); do
    run_reviewer "$parts" "$name-g$k" "$parts/$name-g$k.diff" "$gbase" "${model:-sonnet}" "${dl:-$PRR_DEADLINE}" "${st:-$(date +%s)}" &
  done
  wait
  assemble_groups || true
}

# The branch's review, written from its groups' answers once every group has one (#601). ok only
# when every group returned a review, its findings every group's together under that group's own
# header, so one read key covers them all; otherwise the first group that did not return decides
# the outcome (timeout, unparsed, error, empty), and the first line names each such group, since
# a branch is reviewed only when all of it was read. Its one line in the outcome ledger is written
# here, the groups' own having been kept apart, and the lessons the groups cited join the citation
# ledger. Returns 1, writing nothing, while a group has not answered or another process is already
# writing it (the waiting process and a check can both arrive).
assemble_groups() {
  [ -e "$pending" ] && [ ! -e "$final" ] || return 1
  local n k f gs gf t fin=0 status=ok failed="" total=0 cnt names run
  # Only the run the pending marker names now: a process left over from before a restart holds an
  # older run's folder, and its answers are not this review's.
  run="$(meta_of "$pending" run)"
  [ -n "$run" ] && [ -n "$parts" ] && [ "$parts" = "$(parts_for "$run")" ] || return 1
  n="$(meta_of "$pending" groups)"
  case "$n" in ''|*[!0-9]*|0) return 1 ;; esac
  for k in $(seq 1 "$n"); do [ -e "$parts/$name-g$k.txt" ] || return 1; done
  mkdir "$parts/.writing" 2>/dev/null || return 1
  for k in $(seq 1 "$n"); do
    f="$parts/$name-g$k.txt"
    gs="$(meta_of "$f" status)"
    t="$(meta_of "$f" finished)"
    case "$t" in ''|*[!0-9]*) ;; *) [ "$t" -gt "$fin" ] && fin="$t" ;; esac
    if [ "$gs" = ok ]; then
      gf="$(meta_of "$f" findings)"
      case "$gf" in ''|*[!0-9]*) gf="$(awk 'found && /^[^ :]+:[0-9]+: / { n++ } /^$/ { found = 1 } END { print n + 0 }' "$f")" ;; esac
      total=$((total + gf))
    else
      [ "$status" = ok ] && status="${gs:-error}"
      failed="$failed${failed:+, }Group $k of $n (${gs:-no outcome recorded})"
    fi
  done
  [ "$fin" -gt 0 ] || fin="$(date +%s)"
  {
    printf 'repo=%s\nbranch=%s\nsha=%s\nstarted=%s\nfinished=%s\nstatus=%s\nmodel=%s\ndeadline=%s\nkind=pr\nbase=%s\nfindings=%s\ngroups=%s\n\n' \
      "$repo_label" "$branch" "$full_sha" "$(meta_of "$pending" started)" "$fin" "$status" \
      "$(meta_of "$pending" model)" "$(meta_of "$pending" deadline)" "$(meta_of "$pending" base)" \
      "$([ "$status" = ok ] && printf '%s' "$total")" "$n"
    if [ "$status" = ok ]; then
      printf 'Read in %s groups of files at once, each by the same reviewer with the same deadline, because the branch is over the size one review can use. Every group returned a review.\n' "$n"
    else
      printf 'Not reviewed: %s did not return a review, and the branch counts as read only when every one of its %s groups did.\n' "$failed" "$n"
    fi
    for k in $(seq 1 "$n"); do
      f="$parts/$name-g$k.txt"
      gs="$(meta_of "$f" status)"
      gf="$(meta_of "$f" findings)"
      case "$gs" in
        ok) case "$gf" in 0) gs="no findings" ;; 1) gs="1 finding" ;; ''|*[!0-9]*) gs="reviewed" ;; *) gs="$gf findings" ;; esac ;;
        '') gs="no outcome recorded" ;;
        *) gs="ended as $gs, so not read" ;;
      esac
      cnt="$(grep -c . "$parts/g$k.list" 2>/dev/null || true)"
      names="$(head -5 "$parts/g$k.list" 2>/dev/null | paste -sd ',' - | sed 's/,/, /g')"
      [ "${cnt:-0}" -gt 5 ] && names="$names and $((cnt - 5)) more"
      printf '\n===== Group %s of %s, %s file(s): %s (%s) =====\n' "$k" "$n" "${cnt:-?}" "$gs" "$names"
      awk 'found { print } /^$/ && !found { found = 1 }' "$f"
    done
  } > "$final.tmp" 2>/dev/null && mv -f "$final.tmp" "$final" || { rm -rf "$parts/.writing"; return 1; }
  ar_pr_ledger "$final" "$top"
  [ -s "$parts/citations.tsv" ] && cat "$parts/citations.tsv" >> "$AR_STATE_DIR/citations.tsv" 2>/dev/null
  rm -rf "$parts"
  rm -f "$pending"
  touch "$AR_STATE_DIR/.updated" 2>/dev/null || true
  return 0
}

remedy() {
  printf 'Run it again with: bash ~/.claude/hooks/lib/pr-review.sh restart --dir %s --sha %s\nOr, only after telling Dan why, %s with the one command override: %s <the %s command>.\n' "$top" "${full_sha:-$sha}" "$act" "$PRR_OVERRIDE" "$act"
}

do_check() {
  local now; now="$(date +%s)"
  # A review in groups whose groups have all answered is written here too, should the process
  # waiting on them have died before it could (#601). Its groups are in its own run's folder.
  if [ ! -e "$final" ] && [ -e "$pending" ] && [ -n "$(meta_of "$pending" groups)" ]; then
    parts="$(parts_for "$(meta_of "$pending" run)")"
    assemble_groups
  fi
  if [ ! -e "$final" ] && [ -e "$pending" ]; then
    local st dl gn gdone=0 gmissing="" k
    st="$(meta_of "$pending" started)"; dl="$(meta_of "$pending" deadline)"; gn="$(meta_of "$pending" groups)"
    case "$st" in ''|*[!0-9]*) st="$now" ;; esac
    case "$dl" in ''|*[!0-9]*) dl="$PRR_DEADLINE" ;; esac
    case "$gn" in ''|*[!0-9]*) gn="" ;; esac
    if [ -n "$gn" ]; then
      for k in $(seq 1 "$gn"); do
        if [ -e "$parts/$name-g$k.txt" ]; then gdone=$((gdone + 1)); else gmissing="$gmissing${gmissing:+, }group $k"; fi
      done
    fi
    # Past the deadline with every group answered, a write lock still standing was left by a writer
    # that died holding it (the waiting process and a check are each done in seconds), so it is
    # taken down and the review written, never called abandoned over answers that exist.
    if [ $((now - st)) -gt $((dl + 60)) ] && [ -n "$gn" ] && [ "$gdone" -eq "$gn" ]; then
      rm -rf "$parts/.writing"
      assemble_groups
    fi
    if [ -e "$final" ]; then
      :
    elif [ $((now - st)) -gt $((dl + 60)) ]; then
      if [ -n "$gn" ] && [ -n "$gmissing" ]; then
        record abandoned "The review was started in $gn groups of files and never finished: $(elapsed_text $((now - st))) passed with no answer from $gmissing, which means a background runner died. The branch was not read." "$(meta_of "$pending" base)" "$gn"
        rm -rf "$parts"
      elif [ -n "$gn" ]; then
        record abandoned "The review was started in $gn groups of files, and every group answered, but the review could not be written from their answers under $parts. The branch counts as not read." "$(meta_of "$pending" base)" "$gn"
        rm -rf "$parts"
      else
        record abandoned "The review was started and never finished: $(elapsed_text $((now - st))) passed with no answer written, which means the background runner died. Nothing was read back." "$(meta_of "$pending" base)"
      fi
      rm -f "$pending"
    else
      local of_groups=""
      [ -n "$gn" ] && of_groups=", $gdone of $gn groups returned"
      echo "Refusing to $act yet: the lessons review of $repo_label $branch at $short is still running ($(elapsed_text $((now - st))) of its $(elapsed_text "$dl") deadline$of_groups). Run the $act again once it has finished."
      return 3
    fi
  fi
  # A finished review answers for this check only if it READ everything the check is asked about
  # (claude-config#599). Reviews are keyed by repository and commit, not by base, so a review started
  # at commit or push time, from the default branch, is the one a merge into another base finds. It
  # covers the merge when its own base is an ancestor of (or is) the merge base the check is given:
  # then every commit the merge brings is in the range it read. Otherwise it is started again over the
  # whole range, never reused for commits nobody read. Compared on this checkout's copy of the base
  # first, and only when that disagrees is the base fetched, because a stale copy can only make the
  # merge base OLDER and so ask for more, never less.
  if [ -e "$final" ] && [ -n "$base_ref" ] && [ -n "$full_sha" ]; then
    local rbase need
    rbase="$(meta_of "$final" base)"
    if [ -n "$rbase" ]; then
      need="$(git merge-base "$base_ref" "$full_sha" 2>/dev/null)"
      if [ -n "$need" ] && ! git merge-base --is-ancestor "$rbase" "$need" 2>/dev/null; then
        refresh_base_ref "$base_ref"
        need="$(git merge-base "$base_ref" "$full_sha" 2>/dev/null)"
        if [ -n "$need" ] && ! git merge-base --is-ancestor "$rbase" "$need" 2>/dev/null; then
          local again_msg
          rm -f "$final" "$acknowledged" "$push_acknowledged" "$final.readkey"* "$final.readkeys"* 2>/dev/null
          again_msg="$(do_start)"
          if [ -e "$pending" ]; then
            echo "Refusing to $act yet: the lessons review of $repo_label $branch at $short read from ${rbase:0:7}, which does not cover everything $base_ref brings in from ${need:0:7}, so it was started again over the whole range. $again_msg Run the $act again once it has finished."
            return 3
          fi
        fi
      fi
    fi
  fi
  if [ ! -e "$final" ]; then
    local started_msg
    started_msg="$(do_start)"
    if [ -e "$pending" ]; then
      echo "Refusing to $act yet: no lessons review existed for $repo_label at $short, so one was started now. $started_msg Run the $act again once it has finished."
      return 3
    fi
    [ -e "$final" ] || { echo "Refusing to $act: the lessons review could neither start nor record why. $started_msg"; remedy; return 1; }
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
        return 0
      fi
      # READ means a merge presented the key that only the findings' own messages carry (#788),
      # never that this gate or the nudge PRINTED them: a refusal can be printed and not shown.
      # The acknowledgement names the review it read by its finish time, so a review file written
      # again for this head, by any route, is unread until its own findings are acknowledged.
      local fin
      fin="$(meta_of "$final" finished)"
      # A merge reads only a merge's acknowledgement; a push reads either, since a merge that read
      # them has already shown them to a session (claude-config#599).
      local read_by="" ack_file="$acknowledged"
      [ "$gate" = push ] && ack_file="$push_acknowledged"
      if [ -n "$fin" ] && [ "$(cat "$acknowledged" 2>/dev/null)" = "finished=$fin" ]; then
        read_by="merge"
      elif [ -n "$fin" ] && [ "$gate" = push ] && [ "$(cat "$push_acknowledged" 2>/dev/null)" = "finished=$fin" ]; then
        read_by="push"
      fi
      if [ -n "$read_by" ]; then
        echo "The lessons review of $repo_label $branch at $short finished with $findings finding(s), already read by a $read_by that presented their key."
        return 0
      fi
      if [ -n "$fin" ] && ar_review_key_valid "$final" "${PR_REVIEW_READ:-}"; then
        # Braced, so a refused redirection is silenced too; a failed write is said, since the next
        # attempt will then need the key again.
        { printf 'finished=%s\n' "$fin" > "$ack_file"; } 2>/dev/null \
          || echo "(The read could not be recorded beside $final, so a later $act of this head will need the key again.)"
        echo "The lessons review of $repo_label $branch at $short finished with $findings finding(s), read: this $act presented their key."
        return 0
      fi
      local noun="findings"; [ "$findings" -eq 1 ] && noun="finding"
      local readkey keyrc=0
      readkey="$(ar_review_issue_key "$final")" || keyrc=$?
      echo "Refusing to $act until these are read: the lessons review of the whole branch $repo_label $branch at $short finished ($took) with $findings $noun. Here they are. Check each against the code, fix what is real or say why it is not, then $act with their read key in front of the $act command:"
      if [ "$keyrc" -eq 0 ] && [ -n "$readkey" ]; then
        echo "    PR_REVIEW_READ=$readkey <the $act command>"
        echo "The key is only in this message, so a $act carrying it proves the findings were shown. A $act without it is refused again, with the findings again, because this refusal may have been hidden behind another hook's."
      else
        echo "    ($(ar_review_key_failure "$keyrc" "$final" "bash ~/.claude/hooks/lib/pr-review.sh restart --dir $top --sha ${full_sha:-$sha}"))"
      fi
      # Only when keys can be checked at all: with a tool missing, the presented key was never judged.
      [ -n "${PR_REVIEW_READ:-}" ] && [ "$keyrc" -eq 0 ] && echo "The PR_REVIEW_READ given is not this review's key: it belongs to another review or head."
      ar_capped_body "$final" "$PRR_SHOW_LINES" "$PRR_LINE_CHARS"
      return 1
      ;;
    empty-diff)
      echo "The lessons review had nothing to read: the diff was empty. $(ar_capped_body "$final" 2 "$PRR_LINE_CHARS")"
      return 0
      ;;
    timeout) echo "Refusing to $act: the lessons review of $repo_label at $short did not finish inside its deadline ($took), so the branch was never read." ;;
    error) echo "Refusing to $act: the lessons review of $repo_label at $short failed:" ; ar_capped_body "$final" 8 "$PRR_LINE_CHARS" ;;
    unparsed) echo "Refusing to $act: the lessons review of $repo_label at $short answered, but not in the review's format, so it is not a review. The start of what it said:"; ar_capped_body "$final" 6 "$PRR_LINE_CHARS" ;;
    empty) echo "Refusing to $act: the lessons review of $repo_label at $short came back empty (the reviewer printed nothing), which is not the same as finding nothing." ;;
    abandoned) echo "Refusing to $act: the lessons review of $repo_label at $short was started and never finished; the background runner died." ;;
    could-not-run) echo "Refusing to $act: the lessons review of $repo_label at $short could not run:"; ar_capped_body "$final" 4 "$PRR_LINE_CHARS" ;;
    too-large) echo "Refusing to $act: the lessons review of $repo_label at $short could not run, the branch is too large to review:"; ar_capped_body "$final" 2 "$PRR_LINE_CHARS" ;;
    *) echo "Refusing to $act: the lessons review of $repo_label at $short recorded an outcome this gate does not know (${status:-none})." ;;
  esac
  # A review in groups says on its first line which group did not return (#601), and an abandoned
  # one which groups never answered.
  case "$status" in
    timeout|empty|abandoned) [ -n "$(meta_of "$final" groups)" ] && ar_capped_body "$final" 1 "$PRR_LINE_CHARS" ;;
  esac
  remedy
  return 1
}

case "$verb" in
  start) do_start ;;
  # Every verdict names what the review did not read (#583); a review still running is said by
  # its start line, which named them already.
  check) do_check; rc=$?; [ "$rc" -eq 3 ] || ar_left_out_note "$leftout" "$(meta_of "$final" status)"; exit "$rc" ;;
  restart) rm -f "$final" "$pending" "$acknowledged" "$push_acknowledged" "$final.readkey"* "$final.readkeys"* "$leftout"; rm -rf "$parts_root/$name".*; do_start ;;
  _groups) do_groups ;;
esac
exit 0
