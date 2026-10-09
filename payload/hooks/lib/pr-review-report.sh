#!/usr/bin/env bash
#
# pr-review-report.sh: this Mac's numbers for the PR lessons review, the measurement
# claude-config#562 gates the lessons core on. Nothing leaves the session imports until reviews
# finish on BOTH Macs for nearly every pull request, so this is run on each Mac after two to three
# weeks, and the two outputs go to Dan together with the decision.
#
#   bash ~/.claude/hooks/lib/pr-review-report.sh [--days N] [--no-github]     (default 21 days)
#
# It reads the two ledgers lib/ai-review-common.sh writes, which the 14 day sweep leaves alone:
# pr-opened.tsv (one line per `gh pr create` the PostToolUse hook saw, which includes a second
# create on a branch that already has a pull request) and pr-reviews.tsv (one line per finished
# review, whatever its outcome). It prints:
#   - pull requests opened, counted by pull request (repository and number, claude-config#1006),
#     with the raw count of openings beside it, labelled as openings. On the personal MacBook
#     between 2026-09-24 and 2026-10-08, 513 openings were 461 pull requests, so the two differ.
#   - how many pull requests had a finished review of a head they were opened at. A pull request
#     counts as reviewed when ANY of its openings had a finished review of the head it was opened
#     at: the gate asks whether each pull request was reviewed, and a repeated `gh pr create` (which
#     opens nothing, the pull request already exists) is a second chance to start a review, not a
#     second pull request that also needs one. The per opening share is printed too, as before.
#   - reviews by outcome, each outcome named; findings per finished review;
#   - findings ACTED ON: a review with findings counts as acted on when the pull request's final head
#     changed a file one of its findings named, compared with the reviewed commit. A file changing is
#     evidence of attention, not proof the finding was fixed, and the count says only what it
#     measured (L11).
#   - a verdict on this Mac's half of the gate. "Nearly every" is read as 90 percent of pull
#     requests having a finished review: a chosen line, not a measurement, printed beside the
#     number so Dan can judge the number instead. Under 5 pull requests it says UNMEASURED (L716).
#
# What it asks GitHub, and what it never does (claude-config#1006). The first version asked once per
# review with findings (about 1,070 calls) and fetched into each repository folder, primary checkouts
# included; the #562 measurement on 2026-10-08 used up the shared GitHub allowance, which every
# session on the Mac depends on, for about six minutes. Now:
#   - Which pull request holds a commit, and that pull request's final head, come from ONE GraphQL
#     query per repository per batch of up to PR_REVIEW_REPORT_BATCH commits (default 50), so the
#     calls scale with the number of distinct commits divided by the batch, never with reviews. No
#     call is made per pull request at all.
#   - Those calls are held to PR_REVIEW_REPORT_CALL_BUDGET (default 100, against an hourly allowance
#     of 5,000). Whatever the budget did not reach is UNMEASURED with its count, never dropped and
#     never counted as zero (L90, L331), and the verdict is UNMEASURED while any of it is.
#   - Before the first lookup it reads the GraphQL allowance left, from GraphQL's own rateLimit
#     (one more call, at most one point; the REST rate_limit endpoint reports a different bucket, see
#     below), and refuses to start, exit 75, naming what is left and when it resets, when that is
#     under the budget plus PR_REVIEW_REPORT_RATE_MARGIN (default 500). An allowance it cannot read
#     refuses too: it does not spend against an allowance it cannot see. So the most a run can ask
#     of GitHub is the budget plus that one read, and a batch of 50 measured at 1 point (2026-10-09).
#   - It never fetches into anybody's checkout. Commits are read from the checkout's object store
#     without writing to it; when the final head is not there, the pull request's head ref is
#     fetched into a scratch bare repository that borrows the checkout's objects read only (git
#     alternates), once per checkout, and the scratch is deleted when the report ends. A git fetch
#     is not an API call and does not spend the allowance.
#   - Since #1006 the hook records the pull request URL gh printed with each opening, so those rows
#     are counted by pull request with no lookup and no folder at all; only older rows, written
#     without it, are looked up. Keys compare owner/name case blind, so the two kinds meet.
#   - --no-github asks GitHub nothing: rows naming their pull request are still counted, and the
#     rest are UNMEASURED, said as such.
#
# A recorded folder that no longer exists (a removed worktree) is placed by the nearest existing
# folder above it that is inside a checkout, which for a worktree under <repo>/.claude/worktrees is
# the repository it was cut from. A folder nested inside a DIFFERENT repository would be misplaced
# that way; its commits are then simply not found there, and are counted as GitHub finding no pull
# request.

set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$LIB/ai-review-common.sh" 2>/dev/null || { echo "pr-review-report: lib/ai-review-common.sh is missing, so the ledgers cannot be found." >&2; exit 1; }

days=21
github=1
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || { echo "pr-review-report: --days needs a value." >&2; exit 64; }; days="$2"; shift 2 ;;
    --no-github) github=0; shift ;;
    *) echo "usage: pr-review-report.sh [--days N] [--no-github]" >&2; exit 64 ;;
  esac
done
case "$days" in ''|*[!0-9]*) echo "pr-review-report: --days takes a whole number of days." >&2; exit 64 ;; esac

budget="${PR_REVIEW_REPORT_CALL_BUDGET:-100}"
margin="${PR_REVIEW_REPORT_RATE_MARGIN:-500}"
batch="${PR_REVIEW_REPORT_BATCH:-50}"
for pair in "PR_REVIEW_REPORT_CALL_BUDGET=$budget" "PR_REVIEW_REPORT_RATE_MARGIN=$margin" "PR_REVIEW_REPORT_BATCH=$batch"; do
  case "${pair#*=}" in ''|*[!0-9]*) echo "pr-review-report: ${pair%%=*} takes a whole number, not '${pair#*=}'." >&2; exit 64 ;; esac
done
[ "$batch" -ge 1 ] || { echo "pr-review-report: PR_REVIEW_REPORT_BATCH must be at least 1." >&2; exit 64; }

host="$(ar_host)"
since=$(( $(date +%s) - days * 86400 ))
since_day="$(date -r "$since" +%Y-%m-%d 2>/dev/null || date -d "@$since" +%Y-%m-%d 2>/dev/null)"
echo "PR lessons review, measured on $host over the last $days days (since $since_day)"

if [ ! -s "$AR_PR_OPENED" ] && [ ! -s "$AR_PR_LEDGER" ]; then
  echo "  no pull request has been recorded on this Mac: neither $AR_PR_OPENED nor $AR_PR_LEDGER holds anything."
  echo "UNMEASURED: nothing recorded here, which is not the same as nothing going wrong."
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-report.XXXXXX")" || { echo "pr-review-report: could not make a scratch folder, so nothing was measured." >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

awk -F '\t' -v s="$since" 'NF && $1 >= s' "$AR_PR_OPENED" > "$work/opened" 2>/dev/null
awk -F '\t' -v s="$since" 'NF && $1 >= s' "$AR_PR_LEDGER" > "$work/reviews" 2>/dev/null

# The items: every opening, and every finished review with findings that name a file (one naming
# none is counted as unmeasured below, and needs no lookup). kind, timestamp, folder, sha, files
# (comma joined, reviews only), and for an opening whose row carries the pull request URL (written
# since #1006), its owner/name and number, which it is placed by with no lookup at all.
# Every two file awk here names its first file (FILENAME == ARGV[1]), never FNR == NR, which stays
# true through the second file when the first is empty: a window with no openings would read every
# review as one.
awk -F '\t' 'FILENAME == ARGV[1] {
    slug = ""; num = ""
    if (match($6, /github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/pull\/[0-9]+/)) {
      split(substr($6, RSTART, RLENGTH), p, "/"); slug = p[2] "/" p[3]; num = p[5]
    }
    printf "o\t%s\t%s\t%s\t\t%s\t%s\n", $1, $4, $5, slug, num; next
  }
  $7 == "ok" && $8 ~ /^[0-9]+$/ && $8 > 0 && $10 != "" { printf "r\t%s\t%s\t%s\t%s\n", $1, $4, $5, $10 }' \
  "$work/opened" "$work/reviews" > "$work/items"

# Each recorded folder placed in its checkout: folder, owner/name, git common dir, origin url. Read
# only: rev-parse and config never write. A folder that cannot be placed gets empty fields.
resolve_dir() {
  local d="$1" n=0 top url slug common
  while [ -n "$d" ] && [ ! -d "$d" ] && [ "$n" -lt 64 ]; do d="$(dirname "$d")"; n=$((n + 1)); done
  [ -d "$d" ] || return 1
  # Walking up must not land on the home folder or the root and adopt whatever repository is there.
  if [ "$n" -gt 0 ]; then case "$d" in /|"$HOME") return 1 ;; esac; fi
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
  url="$(git -C "$top" config --get remote.origin.url 2>/dev/null)" || return 1
  slug="$(printf '%s' "$url" | sed -nE 's#^(https?://([^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/?$#\3/\4#p')"
  slug="${slug%.git}"
  [ -n "$slug" ] || return 1
  common="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in /*) ;; *) common="$top/$common" ;; esac
  common="$(cd "$common" 2>/dev/null && pwd)" || return 1
  printf '%s\t%s\t%s\t%s\n' "$1" "$slug" "$common" "$url"
}
: > "$work/dirs"
awk -F '\t' '$3 != "" && $7 == "" { print $3 }' "$work/items" | sort -u > "$work/dirlist"
while IFS= read -r d; do
  resolve_dir "$d" >> "$work/dirs" || printf '%s\t\t\t\n' "$d" >> "$work/dirs"
done < "$work/dirlist"

# The distinct commits to look up, by repository: only items whose folder was placed and whose sha
# is a full commit id, since GitHub refuses a whole query over one malformed id.
awk -F '\t' 'FILENAME == ARGV[1] { slug[$1] = $2; next }
  $7 == "" && ($3 in slug) && slug[$3] != "" && $4 ~ /^[0-9a-f]{40}$/ { print slug[$3] "\t" $4 }' \
  "$work/dirs" "$work/items" | sort -u > "$work/wanted"
awk -F '\t' -v b="$batch" '
  $1 != cur { if (cur != "") print cur "\t" list; cur = $1; list = ""; n = 0 }
  { if (n == b) { print cur "\t" list; list = ""; n = 0 } list = list (list == "" ? "" : " ") $2; n++ }
  END { if (cur != "") print cur "\t" list }' "$work/wanted" > "$work/batches"
needed="$(awk 'END { print NR + 0 }' "$work/batches")"

refuse() { echo "REFUSED: $1"; exit 75; }
et_time() { TZ=America/New_York date -r "$1" '+%-I:%M %p ET' 2>/dev/null || TZ=America/New_York date -d "@$1" '+%-I:%M %p ET' 2>/dev/null || echo "an unknown time"; }

if [ "$github" = 1 ] && [ "$needed" -gt 0 ]; then
  # Read from GraphQL itself, the bucket the lookups are charged to. The REST rate_limit endpoint's
  # "graphql" entry is a different bucket: on 2026-10-09 it reported 4,876 of 5,000 left, resetting
  # at 11:50 AM ET, while GraphQL's own rateLimit reported 502 left, resetting at 11:36 AM ET, so a
  # check reading REST would have started against a nearly spent allowance (L82). This read costs
  # at most one point.
  rl="$(gh api graphql -f query='query { rateLimit { limit remaining resetAt } }' \
    --jq '.data.rateLimit | "\(.remaining) \(.limit) \(.resetAt | fromdateiso8601)"' 2>&1)"; rl_rc=$?
  case "$rl_rc:$rl" in
    0:*) [[ "$rl" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] || rl_rc=1 ;;
  esac
  if [ "$rl_rc" -ne 0 ]; then
    refuse "refusing to start, because it could not read GitHub's rate limit (gh said: ${rl%%$'\n'*}), and it does not spend calls against an allowance it cannot see. Run it again later, or with --no-github for the figures the ledgers alone can give."
  fi
  read -r rl_left rl_limit rl_reset <<< "$rl"
  if [ "$rl_left" -lt $((budget + margin)) ]; then
    refuse "refusing to start, because GitHub's GraphQL allowance, shared by every session on this Mac, has $rl_left of $rl_limit left, under the call budget of $budget plus a margin of $margin. It resets at $(et_time "$rl_reset"). Run it after that, or with --no-github."
  fi
fi

# The lookups. Each answer line: owner/name, sha, pull request number, its final head, created (epoch).
: > "$work/found"; : > "$work/looked"; : > "$work/failed"; : > "$work/skipped"
calls=0
jq_lines='.data.repository | to_entries[] | (.key | ltrimstr("c")) as $sha | ((.value // {}).associatedPullRequests.nodes // [])[] | "\($sha)\t\(.number)\t\(.headRefOid)\t\(.createdAt | fromdateiso8601)"'
while IFS=$'\t' read -r slug shas; do
  [ -n "$slug" ] || continue
  if [ "$github" != 1 ]; then
    for s in $shas; do printf '%s\t%s\n' "$slug" "$s" >> "$work/skipped"; done; continue
  fi
  if [ "$calls" -ge "$budget" ]; then
    for s in $shas; do printf '%s\t%s\n' "$slug" "$s" >> "$work/skipped"; done; continue
  fi
  q="query { repository(owner: \"${slug%%/*}\", name: \"${slug#*/}\") {"
  for s in $shas; do
    q="$q c$s: object(oid: \"$s\") { ... on Commit { associatedPullRequests(first: 10) { nodes { number headRefOid createdAt } } } }"
  done
  q="$q } }"
  calls=$((calls + 1))
  if ans="$(gh api graphql -f query="$q" --jq "$jq_lines" 2>/dev/null)"; then
    printf '%s\n' "$ans" | awk -F '\t' -v slug="$slug" 'NF >= 4 { print slug "\t" $0 }' >> "$work/found"
    for s in $shas; do printf '%s\t%s\n' "$slug" "$s" >> "$work/looked"; done
  else
    for s in $shas; do printf '%s\t%s\n' "$slug" "$s" >> "$work/failed"; done
  fi
done < "$work/batches"

# Every item placed: kind, ts, folder, sha, files, status, owner/name, number, final head, git dir,
# origin url. Status is pr, or the reason it is not measured: gone (folder or GitHub remote gone),
# nocommit (no full commit id recorded), nopr (GitHub found none), failed, budget, off. When a commit
# is in several pull requests, the one created nearest the item's own time is taken.
awk -F '\t' -v off="$([ "$github" = 1 ] && echo 0 || echo 1)" '
  FILENAME == ARGV[1] { slug[$1] = $2; gd[$1] = $3; url[$1] = $4; next }
  FILENAME == ARGV[2] { k = $1 "\t" $2; c = ++nc[k]; num[k, c] = $3; head[k, c] = $4; made[k, c] = $5; next }
  FILENAME == ARGV[3] { looked[$1 "\t" $2] = 1; next }
  FILENAME == ARGV[4] { failed[$1 "\t" $2] = 1; next }
  FILENAME == ARGV[5] { skipped[$1 "\t" $2] = 1; next }
  {
    s = slug[$3]; k = s "\t" $4; st = ""; n = ""; h = ""
    if ($7 != "") { st = "pr"; s = $6; n = $7 }
    else if (s == "") st = "gone"
    else if ($4 !~ /^[0-9a-f]{40}$/) st = "nocommit"
    else if (k in failed) st = "failed"
    else if (k in skipped) st = (off ? "off" : "budget")
    else if (!(k in looked)) st = "budget"
    else if (!(k in nc)) st = "nopr"
    else {
      st = "pr"; best = -1
      for (i = 1; i <= nc[k]; i++) {
        d = made[k, i] - $2; if (d < 0) d = -d
        if (best < 0 || d < best) { best = d; n = num[k, i]; h = head[k, i] }
      }
    }
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, st, s, n, h, gd[$3], url[$3]
  }' "$work/dirs" "$work/found" "$work/looked" "$work/failed" "$work/skipped" "$work/items" > "$work/placed"

reasons() { # $1 = a file of status words: prints "word count, word count" in a fixed order, named
  awk -v b="$budget" '{ n[$1]++ } END {
    split("gone nocommit nopr failed budget off nofiles fetch", order, " ")
    name["gone"] = "folder or GitHub remote gone"; name["nocommit"] = "no commit recorded"
    name["nopr"] = "GitHub found no pull request"; name["failed"] = "GitHub lookup failed"
    name["budget"] = "call budget of " b " reached"; name["off"] = "not looked up, --no-github"
    name["nofiles"] = "no file named"; name["fetch"] = "commits could not be fetched"
    sep = ""; for (i = 1; i <= 8; i++) if (n[order[i]]) { printf "%s%s %d", sep, name[order[i]], n[order[i]]; sep = ", " }
  }' "$1"
}

# Openings, by pull request and by opening. Both share one predicate: an opening is covered when its
# own folder and head have a finished review (the pair both ledgers write).
awk -F '\t' 'FILENAME == ARGV[1] { if ($7 == "ok" || $7 == "empty-diff") done[$4 "\t" $5] = 1; next }
  { print (($3 "\t" $4) in done) ? 1 : 0 }' "$work/reviews" <(awk -F '\t' '$1 == "o"' "$work/placed") > "$work/covered"
paste "$work/covered" <(awk -F '\t' '$1 == "o"' "$work/placed") > "$work/openings"
read -r n_open hit_open n_pr hit_pr <<< "$(awk -F '\t' '
  { o++; if ($1) oh++ }
  # Keyed case blind: a recorded URL and a checkout remote can spell the same owner/name differently.
  $7 == "pr" { k = tolower($8) "#" $9; if (!(k in seen)) { seen[k] = 1; p++ } if ($1 && !(k in hit)) { hit[k] = 1; ph++ } }
  END { print o + 0, oh + 0, p + 0, ph + 0 }' "$work/openings")"
awk -F '\t' '$7 != "pr" { print $7 }' "$work/openings" > "$work/untied"
n_untied="$(awk 'END { print NR + 0 }' "$work/untied")"
# Partial: openings that were never looked up (past the budget, or --no-github) or whose lookup
# failed. Rows that name their pull request need no lookup, so --no-github counts those in full.
awk '$1 == "budget" || $1 == "failed" || $1 == "off"' "$work/untied" > "$work/partial"
n_partial="$(awk 'END { print NR + 0 }' "$work/partial")"

s_open="s"; [ "$n_open" -eq 1 ] && s_open=""
# With any partial opening the count is a floor, and says so rather than read as the whole window (L90).
if [ "$n_partial" -gt 0 ]; then
  echo "  pull requests opened: at least $n_pr, UNMEASURED beyond that (from $n_open gh pr create opening$s_open; a pull request opened more than once counts once)"
else
  echo "  pull requests opened: $n_pr (from $n_open gh pr create opening$s_open; a pull request opened more than once counts once)"
fi
[ "$n_untied" -gt 0 ] && echo "  openings not tied to a pull request: $n_untied ($(reasons "$work/untied"))"

# Outcomes, each named. Finished means the branch was read: ok, or an empty diff with nothing to read.
awk -F '\t' 'NF {
    n[$7]++; if ($7 == "ok" || $7 == "empty-diff") fin++; else other++
  } END {
    printf "  reviews finished: %d", fin + 0
    if (n["ok"] || n["empty-diff"]) printf " (ok %d, empty diff %d)", n["ok"], n["empty-diff"]
    printf "; not finished: %d", other + 0
    sep = " ("
    for (k in n) if (k != "ok" && k != "empty-diff") { printf "%s%s %d", sep, k, n[k]; sep = ", " }
    if (sep == ", ") printf ")"
    printf "\n"
  }' "$work/reviews"

pct=0; [ "$n_pr" -gt 0 ] && pct=$(( hit_pr * 100 / n_pr ))
pct_open=0; [ "$n_open" -gt 0 ] && pct_open=$(( hit_open * 100 / n_open ))
if [ "$n_partial" -gt 0 ]; then
  echo "  pull requests with a finished review of a head they were opened at: $hit_pr of the $n_pr found ($pct%), the rest UNMEASURED"
else
  echo "  pull requests with a finished review of a head they were opened at: $hit_pr of $n_pr ($pct%)"
fi
echo "  openings with a finished review of that head: $hit_open of $n_open ($pct_open%)"

awk -F '\t' '$7 == "ok" { c++; v[c] = $8 + 0; t += $8 } END {
    if (!c) { print "  findings per finished review: no finished review to count"; exit }
    for (i = 1; i <= c; i++) for (j = i + 1; j <= c; j++) if (v[j] < v[i]) { x = v[i]; v[i] = v[j]; v[j] = x }
    printf "  findings per finished review: median %s, max %d, total %d in %d reviews\n", v[int((c + 1) / 2)], v[c], t, c
  }' "$work/reviews"

# Acted on. Every review with findings is decided from git objects, read without writing: the
# checkout's own store first, and for what it lacks, one scratch fetch per checkout.
changed_in() { # $1 = git dir, $2 = reviewed sha, $3 = final head, $4 = files (comma joined)
  local flagged
  IFS=',' read -r -a flagged <<< "$4"
  [ "${#flagged[@]}" -gt 0 ] || return 2
  git --git-dir="$1" diff --name-only "$2" "$3" -- "${flagged[@]}" 2>/dev/null
}
has_both() { git --git-dir="$1" cat-file -e "$2^{commit}" 2>/dev/null && git --git-dir="$1" cat-file -e "$3^{commit}" 2>/dev/null; }
# Reviews whose pull request was not found are decided in awk by their reason; the rest go to git
# as candidates. Candidates use the unit separator, never a tab, because read treats a tab as
# whitespace and closes up an empty field, shifting every field after it.
: > "$work/verdicts"; : > "$work/candidates"; : > "$work/pending"
awk -F '\t' '$7 == "ok" && $8 ~ /^[0-9]+$/ && $8 > 0 && $10 == "" { print "nofiles" }' "$work/reviews" >> "$work/verdicts"
awk -F '\t' -v v="$work/verdicts" -v c="$work/candidates" '$1 == "r" {
    if ($6 != "pr") print $6 >> v
    else if ($4 == $9) print "not" >> v
    else printf "%s\037%s\037%s\037%s\037%s\037%s\n", $10, $11, $8, $4, $9, $5 >> c
  }' "$work/placed"
while IFS=$'\037' read -r gd url num sha final files; do
  if has_both "$gd" "$sha" "$final"; then
    if [ -n "$(changed_in "$gd" "$sha" "$final" "$files")" ]; then echo acted; else echo not; fi >> "$work/verdicts"
  else
    printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$gd" "$url" "$num" "$sha" "$final" "$files" >> "$work/pending"
  fi
done < "$work/candidates"

fetches=0
if [ -s "$work/pending" ]; then
  awk -F '\037' '{ print $1 "\037" $2 }' "$work/pending" | sort -u > "$work/fetch-targets"
  k=0
  while IFS=$'\037' read -r gd url; do
    k=$((k + 1)); scratch="$work/fetch.$k"
    refspecs="$(awk -F '\037' -v g="$gd" -v u="$url" '$1 == g && $2 == u { print "+refs/pull/" $3 "/head:refs/pr/" $3 }' "$work/pending" | sort -u)"
    fetched=0
    if git init -q --bare "$scratch" 2>/dev/null && printf '%s/objects\n' "$gd" > "$scratch/objects/info/alternates"; then
      fetches=$((fetches + 1))
      # shellcheck disable=SC2086
      GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30 \
        git -C "$scratch" -c gc.auto=0 -c maintenance.auto=false fetch -q --no-tags "$url" $refspecs >/dev/null 2>&1 && fetched=1
    fi
    while IFS=$'\037' read -r p_gd p_url _num sha final files; do
      [ "$p_gd" = "$gd" ] && [ "$p_url" = "$url" ] || continue
      if [ "$fetched" = 1 ] && has_both "$scratch" "$sha" "$final"; then
        if [ -n "$(changed_in "$scratch" "$sha" "$final" "$files")" ]; then echo acted; else echo not; fi
      else
        echo fetch
      fi >> "$work/verdicts"
    done < "$work/pending"
  done < "$work/fetch-targets"
fi
acted="$(awk '$1 == "acted" { n++ } END { print n + 0 }' "$work/verdicts")"
not_acted="$(awk '$1 == "not" { n++ } END { print n + 0 }' "$work/verdicts")"
awk '$1 != "acted" && $1 != "not"' "$work/verdicts" > "$work/unmeasured"
unmeasured="$(awk 'END { print NR + 0 }' "$work/unmeasured")"
line="  reviews with findings: acted on $acted (the pull request's final head changed a file a finding named), not acted on $not_acted, unmeasured $unmeasured"
[ "$unmeasured" -gt 0 ] && line="$line ($(reasons "$work/unmeasured"))"
echo "$line"
s_calls=""; [ "$calls" -ne 1 ] && s_calls="s"
s_fetch="es"; [ "$fetches" -eq 1 ] && s_fetch=""
reads="no allowance read"; [ "$needed" -gt 0 ] && reads="1 allowance read"
[ "$github" = 1 ] && echo "  asked of GitHub: $reads and $calls lookup call$s_calls (budget $budget); $fetches scratch fetch$s_fetch, none into a checkout"

if [ "$n_partial" -gt 0 ]; then
  why="$(reasons "$work/partial")"
  remedy="run it again"
  case "$why" in *"call budget"*) remedy="raise PR_REVIEW_REPORT_CALL_BUDGET (now $budget) or shorten --days" ;; esac
  [ "$github" != 1 ] && remedy="run it without --no-github"
  echo "UNMEASURED (#562): $n_partial of $n_open openings on $host were not looked up or their lookup failed ($why), so the share per pull request covers only part of the window. To measure it, $remedy."
elif [ "$n_pr" -lt 5 ]; then
  echo "UNMEASURED (#562): only $n_pr pull request(s) opened on $host in the window, too few to say whether nearly every one is reviewed. Keep recording."
elif [ "$pct" -ge 90 ]; then
  echo "GATE MET on $host (#562): $pct% of pull requests opened had a finished review (90 percent is the chosen reading of nearly every, not a measurement). The gate needs the other Mac's report too, and the decision is Dan's."
else
  echo "GATE NOT MET on $host (#562): $pct% of pull requests opened had a finished review, under the 90 percent read as nearly every. Nothing leaves the session imports; the outcomes above say why reviews did not finish."
fi
