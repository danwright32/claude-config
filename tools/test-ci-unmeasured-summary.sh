#!/usr/bin/env bash
# tools/ci-unmeasured-summary.sh turns what each part of the pull request checks recorded as not
# tested into the run's step summary, the notices a reviewer sees on the pull request, and the record
# main's next run is compared against (claude-config#3312). Every suite it lists comes from a part's
# record, which the runner writes from the suites' own SUITE-PART-UNMEASURED lines, never from a list
# of names kept here or there.
#
# Driven against fixtures of those records: two suites and their reasons, the same against a main
# that left as much, nothing untested at all, a part that handed back no record, no record from main,
# and a list too long for one notice. It reports; a run it describes is never failed by it.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/ci-unmeasured-summary.sh"
MWR="$DIR/../payload/hooks/lib/merge-when-ready.sh"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.untested.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-ci-unmeasured-summary: refusing to run: the throwaway directory came back as '$TMPROOT'." >&2
    exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

A_WHY1="the SwiftUI adapter, because this is not macOS"
A_WHY2="a settled email scored end to end, because there is no Chrome here"
B_WHY="the keyboard wiring | its focus ring, because <no browser> here"

# parts <case>: four parts as download-artifact lays them out, part 1 and 3 with records, 2 and 4 empty.
parts(){
  local d="$TMPROOT/$1/parts" n
  for n in 1 2 3 4; do mkdir -p "$d/part-unmeasured-$n"; : > "$d/part-unmeasured-$n/unmeasured.tsv"; done
  printf 'test-a.sh\t%s\ntest-a.sh\t%s\n' "$A_WHY1" "$A_WHY2" > "$d/part-unmeasured-1/unmeasured.tsv"
  printf 'test-b.sh\t%s\n' "$B_WHY" > "$d/part-unmeasured-3/unmeasured.tsv"
}
# summarise <case> <main record or nothing>: runs the tool, leaving its files in <case>/out.
summarise(){
  rm -rf "$TMPROOT/$1/out"; mkdir -p "$TMPROOT/$1/out"
  bash "$TOOL" "$TMPROOT/$1/parts" 4 "$2" "$TMPROOT/$1/out" > "$TMPROOT/$1/stdout" 2>&1
  rc=$?
  sum="$(cat "$TMPROOT/$1/out/summary.md" 2>/dev/null)"
  notices="$(cat "$TMPROOT/$1/out/notices.txt" 2>/dev/null)"
}

# 1. Two suites, three parts, against a main that left one of test-a's: MORE, said first.
parts more
printf 'test-a.sh\t%s\n' "$A_WHY1" > "$TMPROOT/more/main.tsv"
summarise more "$TMPROOT/more/main.tsv"
[ "$rc" -eq 0 ] && check "#3312 the tool exits 0 when it has summarised" ok || check "#3312 the tool exits 0 when it has summarised" "exit $rc: $(cat "$TMPROOT/more/stdout")"
first="$(head -1 <<< "$sum")"
case "$first" in
  "**More left untested than main's last run:** test-a.sh 2 parts, 1 on main; test-b.sh 1 part, none on main.")
    check "#3312 a run that left more untested than main says so on the summary's first line, naming each suite" ok ;;
  *) check "#3312 a run that left more untested than main says so on the summary's first line, naming each suite" "first line: $first" ;;
esac
grep -qF "| test-a.sh | 1 | $A_WHY1 |" <<< "$sum" && grep -qF "| test-a.sh | 1 | $A_WHY2 |" <<< "$sum" \
  && check "#3312 each part of a suite is listed with the reason the suite gave and the part that ran it" ok \
  || check "#3312 each part of a suite is listed with the reason the suite gave and the part that ran it" "summary: $sum"
grep -qF '| test-b.sh | 3 | the keyboard wiring \| its focus ring, because &lt;no browser&gt; here |' <<< "$sum" \
  && check "#3312 a reason's table breaking and markup characters are escaped" ok \
  || check "#3312 a reason's table breaking and markup characters are escaped" "summary: $sum"
grep -qF '3 parts in 2 suites' <<< "$sum" \
  && check "#3312 the summary counts the parts and the suites" ok \
  || check "#3312 the summary counts the parts and the suites" "summary: $sum"
n_notices="$(grep -c '^::notice ' <<< "$notices" || true)"
grep -qF "::notice title=Not tested by the checks::3 parts in 2 suites were not tested on the runner, so these checks do not cover them:%0Atest-a.sh: $A_WHY2%0Atest-a.sh: $A_WHY1%0Atest-b.sh: the keyboard wiring | its focus ring, because <no browser> here" <<< "$notices" \
  && grep -qF "::notice title=Not tested by the checks and more than on main::This run left more untested than main's last run: test-a.sh 2 parts, 1 on main; test-b.sh 1 part, none on main." <<< "$notices" \
  && [ "$n_notices" = 2 ] \
  && check "#3312 one notice lists every part, one line each, and a second says it is more than main" ok \
  || check "#3312 one notice lists every part, one line each, and a second says it is more than main" "notices ($n_notices): $notices"
rec="$(cat "$TMPROOT/more/out/record.tsv" 2>/dev/null)"
[ "$rec" = "$(printf 'test-a.sh\t%s\ntest-a.sh\t%s\ntest-b.sh\t%s' "$A_WHY2" "$A_WHY1" "$B_WHY")" ] \
  && check "#3312 the record for main's next comparison holds every part, sorted, without the part number" ok \
  || check "#3312 the record for main's next comparison holds every part, sorted, without the part number" "record: $rec"

# 2. The same parts against a main that left as many: not more, and the first line is the heading.
parts same
printf 'test-b.sh\t%s\ntest-a.sh\t%s\ntest-a.sh\t%s\n' "$B_WHY" "$A_WHY2" "$A_WHY1" > "$TMPROOT/same/main.tsv"
summarise same "$TMPROOT/same/main.tsv"
first="$(head -1 <<< "$sum")"
[ "$first" = "### Not tested by the checks: 3 parts in 2 suites" ] \
  && check "#3312 a run that left no more than main leads with the heading" ok \
  || check "#3312 a run that left no more than main leads with the heading" "first line: $first"
grep -qF "No suite left more untested than on main's last run, which left 3 parts in 2 suites untested." <<< "$sum" \
  && ! grep -q 'More left untested' <<< "$sum" \
  && [ "$(grep -c '^::notice ' <<< "$notices")" = 1 ] \
  && check "#3312 and says it is no more than main, with no second notice" ok \
  || check "#3312 and says it is no more than main, with no second notice" "summary: $sum notices: $notices"

# 3. Nothing untested anywhere: nothing listed, said plainly, and recorded as empty for main.
mkdir -p "$TMPROOT/none/parts"
for n in 1 2 3 4; do mkdir -p "$TMPROOT/none/parts/part-unmeasured-$n"; : > "$TMPROOT/none/parts/part-unmeasured-$n/unmeasured.tsv"; done
summarise none "$TMPROOT/same/main.tsv"
first="$(head -1 <<< "$sum")"
[ "$first" = "### Every suite measured every part on the runner" ] \
  && ! grep -q '^| test-' <<< "$sum" \
  && check "#3312 a run that left nothing untested lists nothing and says so" ok \
  || check "#3312 a run that left nothing untested lists nothing and says so" "summary: $sum"
[ "$notices" = "::notice title=Not tested by the checks::Every suite measured every part on the runner." ] \
  && check "#3312 and its one notice says so, so the merge helper has something to name" ok \
  || check "#3312 and its one notice says so, so the merge helper has something to name" "notices: $notices"
[ -f "$TMPROOT/none/out/record.tsv" ] && [ ! -s "$TMPROOT/none/out/record.tsv" ] \
  && check "#3312 and its record for main is empty, not missing" ok \
  || check "#3312 and its record for main is empty, not missing" "record: $(ls -l "$TMPROOT/none/out" 2>&1)"

# 3b. Against a main that left nothing untested (an empty record), every part this run left is more.
parts fromnone
summarise fromnone "$TMPROOT/none/out/record.tsv"
first="$(head -1 <<< "$sum")"
[ "$first" = "**More left untested than main's last run:** test-a.sh 2 parts, none on main; test-b.sh 1 part, none on main." ] \
  && check "#3312 against a main that left nothing untested, every suite this run left is more" ok \
  || check "#3312 against a main that left nothing untested, every suite this run left is more" "first line: $first"

# 4. A part that handed back no record: named, never compared, never recorded for main.
parts gap
rm -rf "$TMPROOT/gap/parts/part-unmeasured-2"
summarise gap "$TMPROOT/same/main.tsv"
grep -qF 'Part 2 handed back no record of what it did not test, so its suites are missing from this list and this run is not compared with main.' <<< "$sum" \
  && ! grep -q "More left untested\|No suite left more" <<< "$sum" \
  && check "#3312 a part with no record is named, and the run is not compared with main" ok \
  || check "#3312 a part with no record is named, and the run is not compared with main" "summary: $sum"
grep -qF 'Part 2 handed back no record' <<< "$notices" \
  && check "#3312 and its notice says the part is missing" ok \
  || check "#3312 and its notice says the part is missing" "notices: $notices"
[ ! -e "$TMPROOT/gap/out/record.tsv" ] \
  && check "#3312 and an incomplete run leaves no record for main to be compared with" ok \
  || check "#3312 and an incomplete run leaves no record for main to be compared with" "record.tsv was written"

# 5. No record from main: the run cannot be compared, and says so rather than claiming either way.
parts nomain
summarise nomain "$TMPROOT/nomain/missing.tsv"
grep -qF "Main's last run left no record of what it did not test, so this run cannot be compared with it." <<< "$sum" \
  && ! grep -q "More left untested\|No suite left more" <<< "$sum" \
  && check "#3312 with no record from main it says it cannot compare" ok \
  || check "#3312 with no record from main it says it cannot compare" "summary: $sum"
summarise nomain ""
grep -qF "Main's last run left no record" <<< "$sum" \
  && check "#3312 and an empty path for main's record reads the same" ok \
  || check "#3312 and an empty path for main's record reads the same" "summary: $sum"

# GitHub cuts a notice's message at 4,096 characters of the DECODED text (on run 44826519963 the
# annotation came back 4,096 long with real newlines, where the escaped line it was sent as was longer),
# so the tool holds the decoded message to NOTICE_BYTES bytes, never more than characters.
NOTICE_BYTES=4000
# decode <title>: the message of the notice with exactly that title, with its escapes undone, into
# $TMPROOT/decoded (no trailing newline), as GitHub stores it.
decode(){
  grep -F "::notice title=$1::" <<< "$notices" | head -1 | sed "s/^::notice title=$1:://" \
    | perl -pe 'chomp; s/%(25|0A|0D)/$1 eq "25" ? "%" : $1 eq "0A" ? "\n" : "\r"/ge' > "$TMPROOT/decoded"
}
# fits <case> <title> <what>: the decoded message is within the bytes the tool holds itself to.
fits(){
  local b; b="$(LC_ALL=C wc -c < "$TMPROOT/decoded" | tr -d ' ')"
  [ -s "$TMPROOT/decoded" ] && [ "$b" -le "$NOTICE_BYTES" ] \
    && check "#3312 $3: the message is within $NOTICE_BYTES bytes" ok \
    || check "#3312 $3: the message is within $NOTICE_BYTES bytes" "$b bytes"
}
# a fixture's reasons the length of the real ones (about 150 bytes), made up, numbered so each is unique.
long_why(){ printf '#%d the settle step wired end to end through the hook and its picker, because the tool it reads is macOS only, and the runner here is Linux (case %d)' "$((1800 + $1))" "$1"; }

# 6. Fifty short parts fit one notice whole: every one listed, and no line saying more.
mkdir -p "$TMPROOT/many/parts"
for n in 1 2 3 4; do mkdir -p "$TMPROOT/many/parts/part-unmeasured-$n"; : > "$TMPROOT/many/parts/part-unmeasured-$n/unmeasured.tsv"; done
for n in $(seq 1 50); do printf 'test-m%02d.sh\tpart %s\n' "$n" "$n"; done > "$TMPROOT/many/parts/part-unmeasured-4/unmeasured.tsv"
summarise many ""
decode "Not tested by the checks"
lines="$(awk 'END { print NR }' "$TMPROOT/decoded")"
[ "$lines" = 51 ] && ! grep -q 'more part' "$TMPROOT/decoded" && grep -qx 'test-m50.sh: part 50' "$TMPROOT/decoded" \
  && [ "$(grep -c '^| test-m' <<< "$sum")" = 50 ] \
  && check "#3312 a list that fits is written whole in the notice, with no line saying more" ok \
  || check "#3312 a list that fits is written whole in the notice, with no line saying more" "lines=$lines notice: $(head -c 300 "$TMPROOT/decoded")"
fits many "Not tested by the checks" "a short list"

# 6b. About fifty parts with reasons as long as the real ones, one part missing: the notice lists the
# whole parts that fit, in the record's order, then the missing part, and its LAST line says how
# many more there are and where they all are.
mkdir -p "$TMPROOT/long/parts"
for n in 1 2 3 4; do mkdir -p "$TMPROOT/long/parts/part-unmeasured-$n"; : > "$TMPROOT/long/parts/part-unmeasured-$n/unmeasured.tsv"; done
rm -rf "$TMPROOT/long/parts/part-unmeasured-2"
for n in $(seq 1 52); do printf 'test-long-%02d.sh\t%s\n' "$(( (n + 1) / 2 + n % 3 ))" "$(long_why "$n")"; done > "$TMPROOT/long/parts/part-unmeasured-1/unmeasured.tsv"
summarise long ""
decode "Not tested by the checks"
fits long "Not tested by the checks" "a long list"
total="$(grep -c . "$TMPROOT/long/parts/part-unmeasured-1/unmeasured.tsv")"
# The listed parts: every line after the first, up to the missing part's line.
sed -n '2,$p' "$TMPROOT/decoded" | sed '/^Part 2 handed back/,$d' > "$TMPROOT/listed"
shown="$(grep -c . "$TMPROOT/listed" || true)"
LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 "$TMPROOT/long/parts/part-unmeasured-1/unmeasured.tsv" \
  | awk -F'\t' '{ print $1 ": " substr($0, length($1) + 2) }' | head -n "$shown" > "$TMPROOT/expected"
last="$(tail -n 1 "$TMPROOT/decoded")"
[ "$shown" -gt 0 ] && [ "$shown" -lt "$total" ] && cmp -s "$TMPROOT/listed" "$TMPROOT/expected" \
  && check "#3312 a long list shows only whole parts, the first ones in the record's order" ok \
  || check "#3312 a long list shows only whole parts, the first ones in the record's order" "shown=$shown of $total; diff: $(diff "$TMPROOT/listed" "$TMPROOT/expected" | head -4)"
[ "$last" = "...and $((total - shown)) more parts, listed in the run's summary." ] \
  && grep -qx 'Part 2 handed back no record of what it did not test.' "$TMPROOT/decoded" \
  && check "#3312 and its last line says how many more parts there are and where they are" ok \
  || check "#3312 and its last line says how many more parts there are and where they are" "last line: $last"

# 6c. Reasons made of characters of two bytes each: the notice is held in bytes, so it still fits.
mkdir -p "$TMPROOT/wide/parts"
for n in 1 2 3 4; do mkdir -p "$TMPROOT/wide/parts/part-unmeasured-$n"; : > "$TMPROOT/wide/parts/part-unmeasured-$n/unmeasured.tsv"; done
wide="$(printf 'caf\303\251 %.0s' $(seq 1 30))"
for n in $(seq 1 50); do printf 'test-w%02d.sh\t%s%s\n' "$n" "$wide" "$n"; done > "$TMPROOT/wide/parts/part-unmeasured-3/unmeasured.tsv"
summarise wide ""
decode "Not tested by the checks"
fits wide "Not tested by the checks" "a list with reasons of more than one byte a character"
last="$(tail -n 1 "$TMPROOT/decoded")"
shown="$(sed -n '2,$p' "$TMPROOT/decoded" | grep -c '^test-w' || true)"
[ "$last" = "...and $((50 - shown)) more parts, listed in the run's summary." ] && [ "$shown" -gt 0 ] \
  && [ "$(sed -n '2,$p' "$TMPROOT/decoded" | grep '^test-w' | grep -cv "$wide[0-9]*\$" || true)" = 0 ] \
  && check "#3312 and it ends on a whole part followed by how many more" ok \
  || check "#3312 and it ends on a whole part followed by how many more" "shown=$shown last: $last"

# 6d. More suites grown than main than fit one notice: the second notice is held the same way.
mkdir -p "$TMPROOT/grown/parts"
for n in 1 2 3 4; do mkdir -p "$TMPROOT/grown/parts/part-unmeasured-$n"; : > "$TMPROOT/grown/parts/part-unmeasured-$n/unmeasured.tsv"; done
for n in $(seq 1 120); do printf 'test-grown-with-a-long-suite-name-%03d.sh\tpart %s\n' "$n" "$n"; done > "$TMPROOT/grown/parts/part-unmeasured-1/unmeasured.tsv"
: > "$TMPROOT/grown/main.tsv"
summarise grown "$TMPROOT/grown/main.tsv"
decode "Not tested by the checks and more than on main"
fits grown "Not tested by the checks and more than on main" "a long list of suites that grew"
last="$(tail -n 1 "$TMPROOT/decoded")"
first="$(head -n 1 "$TMPROOT/decoded")"
shown="$(grep -o 'test-grown-with-a-long-suite-name-[0-9]*\.sh 1 part, none on main' <<< "$first" | grep -c . || true)"
[ "$shown" -gt 0 ] && [ "$last" = "...and $((120 - shown)) more suites, listed in the run's summary." ] \
  && [[ "$first" == *"none on main." ]] \
  && check "#3312 the notice that says more than main lists whole suites, then how many more" ok \
  || check "#3312 the notice that says more than main lists whole suites, then how many more" "shown=$shown first: ${first:0:200} last: $last"
grep -qF "test-grown-with-a-long-suite-name-120.sh 1 part, none on main." <<< "$(head -1 <<< "$sum")" \
  && check "#3312 and the summary's first line still names every suite that grew" ok \
  || check "#3312 and the summary's first line still names every suite that grew" "first: $(head -c 200 <<< "$sum")"

# 7. A percent sign in a reason cannot be read as an escape and break the notice into lines.
parts esc
printf 'test-c.sh\t%s\n' "100%0A done" > "$TMPROOT/esc/parts/part-unmeasured-2/unmeasured.tsv"
summarise esc ""
grep -qF 'test-c.sh: 100%250A done' <<< "$notices" \
  && check "#3312 a percent sign in a reason is escaped in the notice" ok \
  || check "#3312 a percent sign in a reason is escaped in the notice" "notices: $notices"

# 8. Asked wrongly, it says how to ask and exits 2.
bash "$TOOL" > "$TMPROOT/usage.out" 2>&1; urc=$?
[ "$urc" -eq 2 ] && grep -q 'usage:' "$TMPROOT/usage.out" \
  && check "#3312 asked with no arguments it prints its usage and exits 2" ok \
  || check "#3312 asked with no arguments it prints its usage and exits 2" "exit $urc: $(cat "$TMPROOT/usage.out")"
bash "$TOOL" "$TMPROOT/more/parts" four "" "$TMPROOT/usage-out" > "$TMPROOT/usage.out" 2>&1; urc=$?
[ "$urc" -eq 2 ] \
  && check "#3312 a part count that is not a number is refused" ok \
  || check "#3312 a part count that is not a number is refused" "exit $urc"

# 9. The merge helper names these notices by the same title the tool writes (one home each side, held
# equal here, since the helper is installed into ~/.claude and the tool is not).
tool_title="$(sed -n 's/^UNTESTED_TITLE="\(.*\)"$/\1/p' "$TOOL")"
mwr_title="$(sed -n 's/^UNTESTED_TITLE_PREFIX="\(.*\)"$/\1/p' "$MWR")"
[ -n "$tool_title" ] && [ "$tool_title" = "$mwr_title" ] \
  && check "#3312 the merge helper reads notices by the title the tool writes" ok \
  || check "#3312 the merge helper reads notices by the title the tool writes" "tool '$tool_title', helper '$mwr_title'"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
