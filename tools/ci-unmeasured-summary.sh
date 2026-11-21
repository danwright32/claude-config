#!/usr/bin/env bash
# ci-unmeasured-summary.sh: say which parts of the suites a run of the pull request checks did not
# test, where a reviewer sees it without opening a log (claude-config#3312).
#
#   bash tools/ci-unmeasured-summary.sh <parts dir> <part count> <main's record, or ""> <out dir>
#
# A suite that cannot drive part of itself on the runner (no claude, no Mac only tool) prints
# `SUITE-PART-UNMEASURED <what, and why>` and passes. The runner names those suites only in the job
# log, so on 2026-11-19 a green check stood on 27 suites with parts nobody had tested, and two mod
# faults hid behind it (#3291, #3285). Each part job now hands its runner's record of those lines
# (HOOK_TESTS_UNMEASURED_FILE in run-all-tests.sh: `<suite><TAB><why>` per part) to the fan in as
# the artifact part-unmeasured-<n>, which lands as <parts dir>/part-unmeasured-<n>/unmeasured.tsv.
# Nothing here names a suite: every one listed is one a part's record holds (L96).
#
# Writes into <out dir>:
#   summary.md   the step summary. Its FIRST line says so when this run left more untested than
#                main's last run, naming each suite that grew; otherwise it is the heading.
#   notices.txt  workflow commands for the job to print: one notice listing every part (capped, the
#                rest in the summary), and one more when it is more than main. Notices show on the
#                run's page and the pull request's checks, and merge-when-ready.sh reads them back by
#                their title before it merges.
#   record.tsv   every part as `<suite><TAB><why>`, sorted, for main's next comparison. Written only
#                when every part handed back its record, so an incomplete run is never the baseline.
#
# It reports and never judges: it exits 0 whatever it finds, and 2 only when asked wrongly. A part
# with no record is named rather than read as a part that left nothing untested (L98), and with no
# record from main the run says it cannot be compared rather than claiming either way.
set -uo pipefail

# The title every notice here starts with. merge-when-ready.sh reads notices by it, and
# tools/test-ci-unmeasured-summary.sh holds the two equal.
UNTESTED_TITLE="Not tested by the checks"
MORE_TITLE="$UNTESTED_TITLE and more than on main"
# How many parts one notice lists before saying how many more the summary holds.
NOTICE_MAX=40

usage(){ echo "usage: $0 <parts dir> <part count> <main's record, or \"\"> <out dir>" >&2; exit 2; }
[ $# -eq 4 ] || usage
parts_dir="$1"; count="$2"; main_rec="$3"; out="$4"
case "$count" in ''|*[!0-9]*) echo "ci-unmeasured-summary: the part count '$count' is not a number." >&2; usage ;; esac
mkdir -p "$out" || { echo "ci-unmeasured-summary: cannot make $out." >&2; exit 2; }

TAB="$(printf '\t')"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/untested.XXXXXXXX")" || { echo "ci-unmeasured-summary: no scratch folder." >&2; exit 2; }
trap 'rm -rf "$work"' EXIT

# Every part's record as `<part><TAB><suite><TAB><why>`, and the parts that handed back none.
missing=""
: > "$work/all"
n=1
while [ "$n" -le "$count" ]; do
  f="$parts_dir/part-unmeasured-$n/unmeasured.tsv"
  if [ -f "$f" ]; then
    awk -F'\t' -v p="$n" 'NF && $0 !~ /^[[:space:]]*$/ {
        s = $1; w = substr($0, length($1) + 2)
        if (index($0, "\t") == 0) w = "(the suite gave no reason)"
        print p "\t" s "\t" w }' "$f" >> "$work/all"
  else
    missing="$missing $n"
  fi
  n=$((n + 1))
done
LC_ALL=C sort -t "$TAB" -k2,2 -k3,3 -k1,1n "$work/all" > "$work/sorted"
cut -f2- "$work/sorted" > "$work/record"

plural(){ if [ "$1" -eq 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi; }
counted(){ # counted <record> -> "<parts> parts in <suites> suites", or "nothing"
  local p s
  p="$(grep -c . "$1" || true)"; s="$(cut -f1 "$1" | sort -u | grep -c . || true)"
  if [ "${p:-0}" -eq 0 ]; then printf 'nothing'; else printf '%s in %s' "$(plural "$p" part)" "$(plural "$s" suite)"; fi
}
parts_n="$(grep -c . "$work/record" || true)"; parts_n="${parts_n:-0}"

# The comparison with main: per suite, so a part added in one suite and dropped in another still shows.
compare=""; more=""
if [ -n "$missing" ]; then
  compare=incomplete
elif [ -z "$main_rec" ] || [ ! -f "$main_rec" ]; then
  compare=nomain
else
  compare=done
  more="$(awk -F'\t' '
      FILENAME == ARGV[1] { if (NF) m[$1]++; next }
      NF { if (!($1 in p)) order[++k] = $1; p[$1]++ }
      END {
        out = ""
        for (i = 1; i <= k; i++) {
          s = order[i]
          if (p[s] > m[s] + 0) {
            item = s " " p[s] (p[s] == 1 ? " part" : " parts") ", " (m[s] + 0 == 0 ? "none" : m[s]) " on main"
            out = out (out == "" ? "" : "; ") item
          }
        }
        print out
      }' "$main_rec" "$work/record")"
fi

md(){ sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/|/\\|/g'; }
cmd_data(){ awk '{ gsub(/%/, "%25"); gsub(/\r/, "%0D"); printf "%s", $0 }'; }

{
  [ -z "$more" ] || { printf "**More left untested than main's last run:** %s.\n\n" "$more"; }
  if [ "$parts_n" -gt 0 ]; then
    printf '### %s: %s\n\n' "$UNTESTED_TITLE" "$(counted "$work/record")"
  elif [ -n "$missing" ]; then
    printf '### %s: none reported, but not every part handed back a record\n\n' "$UNTESTED_TITLE"
  else
    printf '### Every suite measured every part on the runner\n\n'
  fi
  for n in $missing; do
    printf 'Part %s handed back no record of what it did not test, so its suites are missing from this list and this run is not compared with main.\n\n' "$n"
  done
  case "$compare" in
    nomain) printf "Main's last run left no record of what it did not test, so this run cannot be compared with it.\n\n" ;;
    done)
      if [ -n "$more" ]; then printf "Main's last run left %s untested.\n\n" "$(counted "$main_rec")"
      else printf "No suite left more untested than on main's last run, which left %s untested.\n\n" "$(counted "$main_rec")"; fi ;;
  esac
  if [ "$parts_n" -gt 0 ]; then
    printf 'Each suite below said it could not run these parts on the runner, so no result in this run covers them.\n\n'
    printf '| Suite | Part | Not tested, and why |\n|---|---|---|\n'
    while IFS="$TAB" read -r p s w; do
      printf '| %s | %s | %s |\n' "$(printf '%s' "$s" | md)" "$p" "$(printf '%s' "$w" | md)"
    done < "$work/sorted"
  fi
} > "$out/summary.md"

{
  if [ "$parts_n" -gt 0 ]; then
    verb=were; [ "$parts_n" -eq 1 ] && verb=was
    msg="$(counted "$work/record") $verb not tested on the runner, so these checks do not cover them:"
    i=0
    while IFS="$TAB" read -r s w; do
      i=$((i + 1))
      [ "$i" -le "$NOTICE_MAX" ] || continue
      msg="$msg%0A$(printf '%s: %s' "$s" "$w" | cmd_data)"
    done < "$work/record"
    [ "$parts_n" -le "$NOTICE_MAX" ] || msg="$msg%0A...and $((parts_n - NOTICE_MAX)) more, listed in the run's summary."
  elif [ -n "$missing" ]; then
    msg="No part that handed back a record left anything untested."
  else
    msg="Every suite measured every part on the runner."
  fi
  for n in $missing; do msg="$msg%0APart $n handed back no record of what it did not test."; done
  printf '::notice title=%s::%s\n' "$UNTESTED_TITLE" "$msg"
  [ -z "$more" ] || printf "::notice title=%s::This run left more untested than main's last run: %s.\n" "$MORE_TITLE" "$(printf '%s' "$more" | cmd_data)"
} > "$out/notices.txt"

if [ -z "$missing" ]; then cp "$work/record" "$out/record.tsv"; else rm -f "$out/record.tsv"; fi
exit 0
