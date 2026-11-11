#!/usr/bin/env bash
#
# ci-section-time-readings.sh: rebuild tests/ci-section-time-readings.tsv, the record of CI runs the
# sync suite's section time budget is fitted to (claude-config#2692).
#
#   bash tools/ci-section-time-readings.sh                      # refresh the record from GitHub
#   bash tools/ci-section-time-readings.sh --print              # print what it read, change nothing
#   bash tools/ci-section-time-readings.sh --cache <dir>        # keep the logs, so a rerun is quick
#   bash tools/ci-section-time-readings.sh --since <ISO time>   # the window, and drop rows before it
#   bash tools/ci-section-time-readings.sh --split <seconds>    # where the slower runner group starts
#   bash tools/ci-section-time-readings.sh --runs <file> --logs <dir>   # read saved logs, no network
#
# For every completed run of the tests workflow (pushes to main and pull requests) since the
# earliest run the record holds, it fetches the log with `gh run view --log`, finds the part the
# sync suite ran in, and reads from THAT part: the section time, the check count, and the runner's
# core count, processor and Azure region. #2614 built the record this way by hand with a scratch
# extractor; a budget fitted to data nobody can regenerate drifts as the suite changes (L316).
#
# Refreshing merges: a run it reads replaces that run's row, and a row it did not re-read (a log
# GitHub has expired, a listing cut short) is kept, so a refresh never loses readings it could not
# fetch again (L5). Only --since drops rows, and it says how many.
#
# What it will not do is guess. A run whose log has no core count, a core count of UNKNOWN, a sync
# suite result with no section time after it, a suite that reported in two parts, or a log gh could
# not fetch for a run the record does not hold yet is named, and then NOTHING is written or printed,
# since a record with the readable runs only reads as a complete one. A run the record already holds
# whose log gh cannot fetch keeps its recorded row, and is named. A run with no jobs, or no sync suite result (cancelled before it
# finished), carries no reading and is named as skipped with that reason. The processor and region
# are recorded as unknown when the log does not print them, which is how runs from before the step
# printed the processor already read (#2403).
#
# The runner group: section time above the split is "slower". The split defaults to the middle of
# the gap the record already has between its two groups (1179s and 1201s on 2026-11-10, so 1190s,
# the line #2614 drew), derived from the record each time rather than written down here (L244).
# Every row is labelled from that one split, so the groups can never overlap (#2614's check).
#
# Exit 0 when the record was written (or printed), 1 when a run could not be read and nothing was
# written, 2 for a usage error or a record it cannot work from.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORD="$ROOT/tests/ci-section-time-readings.tsv"
REPO="danwright32/claude-config"
WORKFLOW="tests.yml"
# gh run list's own ceiling for one call. Reaching it means the listing may be cut short, which is
# said; the rows it could not list are kept from the record rather than lost.
LIST_LIMIT=1000
HEADER="$(printf 'run_id\tcreated_at\tsha\tevent\tconclusion\tcores\tprocessor\tregion\tchecks\tsection_seconds\trunner_group')"
ME="ci-section-time-readings"

say() { printf '%s: %s\n' "$ME" "$*" >&2; }
usage() { sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

since=""; split=""; print=0; runs=""; logs=""; cache=""
while [ $# -gt 0 ]; do
  case "$1" in
    --record) RECORD="${2:-}"; shift 2 ;;
    --since)  since="${2:-}"; shift 2 ;;
    --split)  split="${2:-}"; shift 2 ;;
    --print)  print=1; shift ;;
    --runs)   runs="${2:-}"; shift 2 ;;
    --logs)   logs="${2:-}"; shift 2 ;;
    --cache)  cache="${2:-}"; shift 2 ;;
    --repo)   REPO="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) say "unknown argument: $1"; usage ;;
  esac
done
if { [ -n "$runs" ] && [ -z "$logs" ]; } || { [ -z "$runs" ] && [ -n "$logs" ]; }; then
  say "--runs and --logs go together: a saved run list and the folder holding <run_id>.log for each"; exit 2
fi
if [ -n "$runs" ] && [ -n "$cache" ]; then say "--cache is for reading from GitHub, not with --runs"; exit 2; fi
case "$split" in
  '') ;;
  *[!0-9]*) say "--split takes whole seconds, not '$split'"; exit 2 ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/$ME.XXXXXXXX")" || { say "could not make a temporary folder"; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# ---- What the record says: its earliest run, and the gap between its runner groups ----
# Read by column NAME from the record's own header, the way the budget reads it (#524).
rec_rows="$TMP/record-rows.tsv"
: > "$rec_rows"
rec_ok=0
if [ -s "$RECORD" ]; then
  if [ "$(head -1 "$RECORD")" = "$HEADER" ]; then rec_ok=1; tail -n +2 "$RECORD" | grep . > "$rec_rows"; fi
fi
if [ -z "$since" ]; then
  since="$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "created_at") c = i; if (!c) exit; next }
    $c != "" && (m == "" || $c < m) { m = $c } END { if (m != "") print m }' "$RECORD" 2>/dev/null)"
  [ -n "$since" ] || { say "the record ($RECORD) gives no earliest run to start from, so give --since"; exit 2; }
fi
gap_lo=""; gap_hi=""
if [ -z "$split" ]; then
  gap="$(awk -F'\t' '
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; s = c["section_seconds"]; g = c["runner_group"]; if (!s || !g) exit; next }
    $s ~ /^[0-9]+$/ && $g == "faster" && (fh == "" || $s + 0 > fh) { fh = $s + 0 }
    $s ~ /^[0-9]+$/ && $g == "slower" && (sl == "" || $s + 0 < sl) { sl = $s + 0 }
    END { if (fh != "" && sl != "" && fh < sl) print fh, sl }' "$RECORD" 2>/dev/null)"
  read -r gap_lo gap_hi <<< "$gap"
  if [ -z "$gap_lo" ]; then
    say "the record ($RECORD) has no faster and slower groups with a gap between them to split at, so give --split"
    exit 2
  fi
  split=$(( (gap_lo + gap_hi) / 2 ))
  say "runner groups split at ${split}s, the middle of the record's gap (faster up to ${gap_lo}s, slower from ${gap_hi}s)"
else
  say "runner groups split at ${split}s, as given"
fi

# ---- Which runs, and their logs ----
refusals="$TMP/refusals"; : > "$refusals"
if [ -z "$runs" ]; then
  logs="${cache:-$TMP/logs}"
  mkdir -p "$logs" || { say "could not make the log folder $logs"; exit 2; }
  runs="$TMP/runs.tsv"
  : > "$runs"
  # Finished runs are picked out HERE, never with `--status completed`: measured 2026-11-10, that
  # filter left out 3 of the 290 finished pull request runs since 2026-11-08 21:27 UTC, one of them
  # a run #2614's record holds, so a refresh through it would have quietly lost readings.
  list_runs() {  # list_runs <event> [more gh run list arguments]
    local ev="$1"; shift
    if ! gh run list --repo "$REPO" --workflow "$WORKFLOW" --event "$ev" "$@" \
         --created ">=$since" --limit "$LIST_LIMIT" \
         --json databaseId,createdAt,headSha,event,conclusion,status \
         --jq '.[] | [.databaseId, .createdAt, .headSha, .event, .conclusion, .status] | @tsv' > "$TMP/list-$ev" 2>"$TMP/list-$ev.err"; then
      say "gh could not list the $ev runs: $(head -1 "$TMP/list-$ev.err")"; exit 1
    fi
    if [ "$(grep -c . "$TMP/list-$ev")" -ge "$LIST_LIMIT" ]; then
      say "the $ev listing reached gh's limit of $LIST_LIMIT, so older runs may be missing from it; their rows are kept from the record"
    fi
    awk -F'\t' -v OFS='\t' '$6 == "completed" { print $1, $2, $3, $4, $5 }' "$TMP/list-$ev" >> "$runs"
  }
  # Pushes run on main only, which is the workflow's own trigger; every pull request is in the record.
  list_runs push --branch main
  list_runs pull_request
  # A log gh cannot fetch (GitHub expires them) loses nothing when the record already holds that
  # run: its row is kept, as it is for any run not re-read, and the run is named. A run the record
  # does not hold yet has no reading to keep, so it is a refusal like any other unreadable run.
  recorded_ids="$(cut -f1 "$rec_rows")"
  : > "$TMP/unfetched"
  while IFS=$'\t' read -r id _rest; do
    [ -n "$id" ] || continue
    [ -f "$logs/$id.log" ] && continue   # a finished run's log never changes, so a cached one is final
    if gh run view "$id" --repo "$REPO" --log > "$logs/$id.log.part" 2>"$TMP/view.err"; then
      mv "$logs/$id.log.part" "$logs/$id.log"
    else
      rm -f "$logs/$id.log.part"
      why="$(sed -n '1p' "$TMP/view.err")"
      case $'\n'"$recorded_ids"$'\n' in
        *$'\n'"$id"$'\n'*)
          printf '%s\n' "$id" >> "$TMP/unfetched"
          say "kept run $id's row from the record: gh could not fetch its log ($why)" ;;
        *) printf '%s\tgh could not fetch its log: %s\n' "$id" "$why" >> "$refusals" ;;
      esac
    fi
  done < "$runs"
  # Those runs are left out of the reading below, so the merge keeps their recorded rows.
  awk -F'\t' 'FILENAME == ARGV[1] { gone[$1] = 1; next } !($1 in gone)' "$TMP/unfetched" "$runs" > "$TMP/runs-fetched.tsv"
  runs="$TMP/runs-fetched.tsv"
fi
[ -f "$runs" ] || { say "no run list at $runs"; exit 2; }
[ -d "$logs" ] || { say "no log folder at $logs"; exit 2; }

# ---- Read each run's log ----
# One line per run: ROW and the six fields read from the log, SKIP and why, or REFUSE and why.
read_log() {  # read_log <log file>
  awk -F'\t' '
    {
      sub(/\r$/, "")
      job = $1; text = $0
      if (!sub(/^[^\t]*\t[^\t]*\t/, "", text)) next
      sub(/^[0-9][0-9-]*T[0-9:.]+Z /, "", text)
      sub(/[ \t]+$/, "", text)
      if (text ~ /^Region: / && !(job in region)) region[job] = substr(text, 9)
      if (text ~ /^cores: / && !(job in cores)) cores[job] = substr(text, 8)
      if (text ~ /^processor: / && !(job in proc)) proc[job] = substr(text, 12)
      if (text ~ /^ +(ok|FAIL) +test-claude-sync\.sh( |$)/) {
        if (!(job in result)) { parts++; plist = plist (plist == "" ? "" : ", ") job }
        result[job] = text; rjob = job
        if (match(text, /[0-9]+ passed/)) checks[job] = substr(text, RSTART, RLENGTH - 7)
        next
      }
      if ((job in result) && !(job in section)) {
        if (match(text, /^ +note: [0-9]+s of section time against a /)) {
          t = substr(text, RSTART, RLENGTH); sub(/^ +note: /, "", t); sub(/s .*/, "", t); section[job] = t
        } else if (match(text, /sections cost [0-9]+s of section time/)) {
          t = substr(text, RSTART + 14, RLENGTH - 14); sub(/s .*/, "", t); section[job] = t
        }
      }
    }
    END {
      if (NR == 0) { print "SKIP\tno jobs ran"; exit }
      if (parts == 0) { print "SKIP\tthe sync suite printed no result line (the run was cancelled or stopped before it finished)"; exit }
      if (parts > 1) { print "REFUSE\tthe sync suite reported in more than one part (" plist "), so which section time is the run'"'"'s is a guess"; exit }
      j = rjob; r = result[j]; sub(/^ +/, "", r); gsub(/  +/, " ", r)
      if (!(j in checks)) { print "SKIP\tthe sync suite'"'"'s result in " j " carries no check count: " r; exit }
      if (!(j in section)) { print "REFUSE\tno section time line after the sync suite'"'"'s result in " j ", so the log format may have moved"; exit }
      if (!(j in cores)) { print "REFUSE\tno core count line in " j; exit }
      if (cores[j] !~ /^[0-9]+$/) { print "REFUSE\tthe core count in " j " reads \"" cores[j] "\", which is not a count"; exit }
      p = proc[j]; if (p == "" || p == "UNKNOWN") p = "unknown"
      g = region[j]; if (g == "") g = "unknown"
      printf "ROW\t%s\t%s\t%s\t%s\t%s\n", cores[j], p, g, checks[j], section[j]
    }' "$1"
}

new_rows="$TMP/new-rows.tsv"; : > "$new_rows"
listed=0; skipped=0
LC_ALL=C sort -t $'\t' -k1,1 -u "$runs" > "$TMP/runs-unique.tsv"
while IFS=$'\t' read -r id created sha event conclusion; do
  [ -n "$id" ] || continue
  [[ "$created" < "$since" ]] && continue
  listed=$((listed + 1))
  refused_ids="$(cut -f1 "$refusals")"
  case $'\n'"$refused_ids"$'\n' in *$'\n'"$id"$'\n'*) continue ;; esac
  if [ ! -f "$logs/$id.log" ]; then printf '%s\tno saved log at %s\n' "$id" "$logs/$id.log" >> "$refusals"; continue; fi
  verdict="$(read_log "$logs/$id.log")"
  case "$verdict" in
    ROW$'\t'*)
      IFS=$'\t' read -r _ c p g k s <<< "$verdict"
      grp=faster; [ "$s" -gt "$split" ] && grp=slower
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$created" "${sha:0:8}" "$event" "$conclusion" "$c" "$p" "$g" "$k" "$s" "$grp" >> "$new_rows" ;;
    SKIP$'\t'*) skipped=$((skipped + 1)); say "skipped run $id: ${verdict#*$'\t'}" ;;
    REFUSE$'\t'*) printf '%s\t%s\n' "$id" "${verdict#*$'\t'}" >> "$refusals" ;;
    *) printf '%s\tthe log could not be read\n' "$id" >> "$refusals" ;;
  esac
done < "$TMP/runs-unique.tsv"
read_n="$(grep -c . "$new_rows")"

if [ -s "$refusals" ]; then
  while IFS=$'\t' read -r id why; do say "COULD NOT READ run $id: $why"; done < "$refusals"
  say "$(grep -c . "$refusals") of $listed runs could not be read, so nothing was written; a record with only the readable runs would read as complete"
  exit 1
fi
if [ "$read_n" -eq 0 ]; then
  say "no run since $since carried a reading ($listed listed, $skipped skipped), so nothing was written"
  exit 1
fi
if [ -n "$gap_lo" ]; then
  inside="$(awk -F'\t' -v lo="$gap_lo" -v hi="$gap_hi" '$10 > lo && $10 < hi { n++ } END { print n + 0 }' "$new_rows")"
  [ "$inside" -gt 0 ] && say "$inside of the readings fell inside the record's gap between its groups, so the two runner speeds are closing in"
fi

sorted() { LC_ALL=C sort -t $'\t' -k2,2 -k1,1n; }
if [ "$print" -eq 1 ]; then
  say "$read_n runs read, $skipped skipped, of $listed listed since $since"
  { printf '%s\n' "$HEADER"; sorted < "$new_rows"; }
  exit 0
fi

# ---- Merge into the record and write it whole ----
if [ -s "$RECORD" ] && [ "$rec_ok" -ne 1 ]; then
  say "the record's header is not the one this tool writes, so it will not merge into it: $(head -1 "$RECORD")"
  exit 2
fi
cut -f1 "$new_rows" > "$TMP/new-ids"
kept_file="$TMP/kept.tsv"
awk -F'\t' -v OFS='\t' -v since="$since" -v cut_at="$split" '
  FILENAME == ARGV[1] { fresh[$1] = 1; next }
  $1 in fresh { next }
  $2 < since { dropped++; next }
  { $11 = ($10 + 0 > cut_at + 0 ? "slower" : "faster"); kept++; print }
  END { printf "%d %d\n", kept, dropped > "/dev/stderr" }' "$TMP/new-ids" "$rec_rows" > "$kept_file" 2>"$TMP/kept-counts"
read -r kept dropped < "$TMP/kept-counts"
out="$RECORD.tmp.$$"
{ printf '%s\n' "$HEADER"; cat "$new_rows" "$kept_file" | sorted; } > "$out" && mv "$out" "$RECORD" || {
  rm -f "$out"; say "could not write $RECORD"; exit 1
}
msg="$read_n runs read, $skipped skipped, of $listed listed since $since; $kept rows kept from the record that were not re-read"
[ "${dropped:-0}" -gt 0 ] && msg="$msg; $dropped rows older than $since dropped"
say "$msg; $RECORD now holds $(( $(grep -c . "$RECORD") - 1 )) runs"
