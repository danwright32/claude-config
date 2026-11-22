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
#   notices.txt  workflow commands for the job to print: one notice listing every part (as many
#                whole parts as fit NOTICE_BYTES, then how many more the summary holds), and one
#                more, held the same way, when it is more than main. Notices show on the
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
# The most one notice's message may hold, in bytes of the text GitHub stores. GitHub cuts a message
# at 4,096 characters, counted on the DECODED text: on run 44826519963 the annotation came back exactly
# 4,096 characters with real newlines, cut mid reason, where the escaped line sent (each newline
# written as %0A) was longer. Held in bytes, which are never fewer than characters, so a reason of
# characters of more than one byte cannot push it over; the 96 left over are a margin. Length is the
# one rule: a list that fits is listed whole, and a count cap (40 parts until 2026-11-22) only ever
# met the length limit second.
NOTICE_BYTES=4000

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
# Each suite that grew is one line of $work/grown, and $more is them all joined, for the summary.
compare=""; more=""
: > "$work/grown"
if [ -n "$missing" ]; then
  compare=incomplete
elif [ -z "$main_rec" ] || [ ! -f "$main_rec" ]; then
  compare=nomain
else
  compare=done
  awk -F'\t' '
      FILENAME == ARGV[1] { if (NF) m[$1]++; next }
      NF { if (!($1 in p)) order[++k] = $1; p[$1]++ }
      END {
        for (i = 1; i <= k; i++) {
          s = order[i]
          if (p[s] > m[s] + 0)
            print s " " p[s] (p[s] == 1 ? " part" : " parts") ", " (m[s] + 0 == 0 ? "none" : m[s]) " on main"
        }
      }' "$main_rec" "$work/record" > "$work/grown"
  more="$(awk '{ printf "%s%s", (NR > 1 ? "; " : ""), $0 }' "$work/grown")"
fi

md(){ sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/|/\\|/g'; }

# fit <head> <lead> <sep> <end> <noun> <items> <tail>: one notice's message, escaped as a workflow
# command's data, from <head>, then the items of the file <items> (one per line) joined by <sep> with
# <lead> before the first and <end> after the last, then each line of the file <tail> on its own
# line. When the whole does not fit NOTICE_BYTES, it keeps the first items that fit with the tail
# and a last line saying how many more <noun>s the run's summary lists: never part of an item. The
# lengths are counted in bytes (LC_ALL=C) on the text before escaping, which is what GitHub stores.
fit(){
  LC_ALL=C awk -v head="$1" -v lead="$2" -v sep="$3" -v fin="$4" -v noun="$5" -v max="$NOTICE_BYTES" '
    FILENAME == ARGV[1] { if ($0 != "") it[++n] = $0; next }
    { tail = tail "\n" $0 }
    END {
      body = ""
      for (i = 1; i <= n; i++) body = body (i == 1 ? lead : sep) it[i]
      msg = head body (n ? fin : "") tail
      if (length(msg) > max) {
        # Room is kept for the longest the last line can be, with every item left out.
        room = max - length(head) - length(fin) - length(tail) - length(more(n))
        body = ""; k = 0
        while (k < n && length(body) + length(k ? sep : lead) + length(it[k + 1]) <= room) {
          body = body (k ? sep : lead) it[k + 1]; k++
        }
        msg = head body (k ? fin : "") tail more(n - k)
      }
      gsub(/%/, "%25", msg); gsub(/\r/, "%0D", msg); gsub(/\n/, "%0A", msg)
      printf "%s", msg
    }
    function more(m) { return "\n...and " m " more " noun (m == 1 ? "" : "s") ", listed in the run'"'"'s summary." }
  ' "$6" "$7"
}

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

# The notices' lines: each part as `<suite>: <why>`, and each part that handed back no record.
awk -F'\t' '{ print $1 ": " substr($0, length($1) + 2) }' "$work/record" > "$work/listed"
: > "$work/gaps"
for n in $missing; do echo "Part $n handed back no record of what it did not test." >> "$work/gaps"; done
{
  if [ "$parts_n" -gt 0 ]; then
    verb=were; [ "$parts_n" -eq 1 ] && verb=was
    head="$(counted "$work/record") $verb not tested on the runner, so these checks do not cover them:"
  elif [ -n "$missing" ]; then
    head="No part that handed back a record left anything untested."
  else
    head="Every suite measured every part on the runner."
  fi
  printf '::notice title=%s::%s\n' "$UNTESTED_TITLE" "$(fit "$head" '\n' '\n' "" part "$work/listed" "$work/gaps")"
  [ -z "$more" ] || printf '::notice title=%s::%s\n' "$MORE_TITLE" \
    "$(fit "This run left more untested than main's last run: " "" "; " "." suite "$work/grown" /dev/null)"
} > "$out/notices.txt"

if [ -z "$missing" ]; then cp "$work/record" "$out/record.tsv"; else rm -f "$out/record.tsv"; fi
exit 0
