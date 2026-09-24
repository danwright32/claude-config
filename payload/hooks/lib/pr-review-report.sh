#!/usr/bin/env bash
#
# pr-review-report.sh: this Mac's numbers for the PR lessons review, the measurement
# claude-config#562 gates the lessons core on. Nothing leaves the session imports until reviews
# finish on BOTH Macs for nearly every pull request, so this is run on each Mac after two to three
# weeks, and the two outputs go to Dan together with the decision.
#
#   bash ~/.claude/hooks/lib/pr-review-report.sh [--days N]     (default 21)
#
# It reads the two ledgers lib/ai-review-common.sh writes, which the 14 day sweep leaves alone:
# pr-opened.tsv (one line per successful `gh pr create`) and pr-reviews.tsv (one line per finished
# review, whatever its outcome). It prints:
#   - pull requests opened, and how many had a finished review of the head they were opened at;
#   - reviews by outcome, each outcome named;
#   - findings per finished review;
#   - findings ACTED ON: a review with findings counts as acted on when a later commit on the same
#     pull request changed a file one of its findings named. The pull request and its final head are
#     asked of GitHub (commits/<sha>/pulls); when gh cannot name one, that review is UNMEASURED,
#     never "not acted on" (L411). A file changing is evidence of attention, not proof the finding was
#     fixed, and the count says only what it measured (L11).
#   - a verdict on this Mac's half of the gate. "Nearly every" is read as 90 percent of pull
#     requests opened having a finished review: a chosen line, not a measurement, printed beside the
#     number so Dan can judge the number instead. Under 5 pull requests it says UNMEASURED (L716).

set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$LIB/ai-review-common.sh" 2>/dev/null || { echo "pr-review-report: lib/ai-review-common.sh is missing, so the ledgers cannot be found." >&2; exit 1; }

days=21
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || { echo "pr-review-report: --days needs a value." >&2; exit 64; }; days="$2"; shift 2 ;;
    *) echo "usage: pr-review-report.sh [--days N]" >&2; exit 64 ;;
  esac
done
case "$days" in ''|*[!0-9]*) echo "pr-review-report: --days takes a whole number of days." >&2; exit 64 ;; esac

host="$(ar_host)"
since=$(( $(date +%s) - days * 86400 ))
since_day="$(date -r "$since" +%Y-%m-%d 2>/dev/null || date -d "@$since" +%Y-%m-%d 2>/dev/null)"
echo "PR lessons review, measured on $host over the last $days days (since $since_day)"

if [ ! -s "$AR_PR_OPENED" ] && [ ! -s "$AR_PR_LEDGER" ]; then
  echo "  no pull request has been recorded on this Mac: neither $AR_PR_OPENED nor $AR_PR_LEDGER holds anything."
  echo "UNMEASURED: nothing recorded here, which is not the same as nothing going wrong."
  exit 0
fi

opened_rows="$(awk -F '\t' -v s="$since" '$1 >= s' "$AR_PR_OPENED" 2>/dev/null)"
review_rows="$(awk -F '\t' -v s="$since" '$1 >= s' "$AR_PR_LEDGER" 2>/dev/null)"
n_opened="$(printf '%s' "$opened_rows" | awk 'NF { n++ } END { print n + 0 }')"
echo "  pull requests opened: $n_opened"

# Outcomes, each named. Finished means the branch was read: ok, or an empty diff with nothing to read.
printf '%s\n' "$review_rows" | awk -F '\t' 'NF {
    n[$7]++; if ($7 == "ok" || $7 == "empty-diff") fin++; else other++
  } END {
    printf "  reviews finished: %d", fin + 0
    if (n["ok"] || n["empty-diff"]) printf " (ok %d, empty diff %d)", n["ok"], n["empty-diff"]
    printf "; not finished: %d", other + 0
    sep = " ("
    for (k in n) if (k != "ok" && k != "empty-diff") { printf "%s%s %d", sep, k, n[k]; sep = ", " }
    if (sep == ", ") printf ")"
    printf "\n"
  }'

# Openings whose own head has a finished review (keyed by directory and sha, the pair both write).
covered="$(awk -F '\t' 'FNR == NR { if ($7 == "ok" || $7 == "empty-diff") done[$4 "\t" $5] = 1; next }
  NF { total++; if (($4 "\t" $5) in done) hit++ } END { printf "%d %d", hit + 0, total + 0 }' \
  <(printf '%s\n' "$review_rows") <(printf '%s\n' "$opened_rows"))"
hit="${covered% *}"; total="${covered#* }"
pct=0; [ "$total" -gt 0 ] && pct=$(( hit * 100 / total ))
echo "  opened with a finished review of that head: $hit of $total ($pct%)"

printf '%s\n' "$review_rows" | awk -F '\t' '$7 == "ok" { c++; v[c] = $8 + 0; t += $8 } END {
    if (!c) { print "  findings per finished review: no finished review to count"; exit }
    for (i = 1; i <= c; i++) for (j = i + 1; j <= c; j++) if (v[j] < v[i]) { x = v[i]; v[i] = v[j]; v[j] = x }
    printf "  findings per finished review: median %s, max %d, total %d in %d reviews\n", v[int((c + 1) / 2)], v[c], t, c
  }'

# Acted on: for each review with findings, did a later commit on its pull request touch a named file?
acted=0; not_acted=0; unmeasured=0
while IFS=$'\t' read -r _fin _host _repo dir sha _base status findings _secs files _lessons; do
  [ "$status" = "ok" ] || continue
  case "$findings" in ''|0|*[!0-9]*) continue ;; esac
  if [ -z "$files" ] || [ -z "$dir" ] || ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    unmeasured=$((unmeasured + 1)); continue
  fi
  final="$(cd "$dir" && gh api "repos/{owner}/{repo}/commits/$sha/pulls" --jq '.[0].head.sha // empty' 2>/dev/null)"
  if [ -z "$final" ]; then unmeasured=$((unmeasured + 1)); continue; fi
  git -C "$dir" cat-file -e "$final^{commit}" 2>/dev/null || git -C "$dir" fetch -q origin "$final" 2>/dev/null
  if ! git -C "$dir" cat-file -e "$final^{commit}" 2>/dev/null; then unmeasured=$((unmeasured + 1)); continue; fi
  IFS=',' read -r -a flagged <<< "$files"
  changed="$(git -C "$dir" diff --name-only "$sha" "$final" -- "${flagged[@]}" 2>/dev/null)"
  if [ -n "$changed" ]; then acted=$((acted + 1)); else not_acted=$((not_acted + 1)); fi
done <<< "$review_rows"
echo "  reviews with findings: acted on $acted (a later commit on the pull request changed a file a finding named), not acted on $not_acted, unmeasured $unmeasured"

if [ "$n_opened" -lt 5 ]; then
  echo "UNMEASURED (#562): only $n_opened pull request(s) opened on $host in the window, too few to say whether nearly every one is reviewed. Keep recording."
elif [ "$pct" -ge 90 ]; then
  echo "GATE MET on $host (#562): $pct% of pull requests opened had a finished review (90 percent is the chosen reading of nearly every, not a measurement). The gate needs the other Mac's report too, and the decision is Dan's."
else
  echo "GATE NOT MET on $host (#562): $pct% of pull requests opened had a finished review, under the 90 percent read as nearly every. Nothing leaves the session imports; the outcomes above say why reviews did not finish."
fi
