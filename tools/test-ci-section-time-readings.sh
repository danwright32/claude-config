#!/usr/bin/env bash
#
# test-ci-section-time-readings.sh: the tool that rebuilds tests/ci-section-time-readings.tsv, the
# CI record the sync suite's section time budget is fitted to (claude-config#2692).
#
# Why it exists: #2614 rebuilt that record by hand from `gh run view --log` with a scratch
# extractor, and a budget fitted to data nobody can regenerate drifts silently as the suite changes
# (L316). So the first thing held here is that the tool REPRODUCES the committed record's rows from
# saved logs, compared against the committed file itself rather than a copy of what the tool printed
# once (L84). The logs in tools/ci-section-time-sample/logs are real ones from those runs, cut down
# to the lines the tool reads and the lines that look like them (the echo of the step that prints
# the core count, the "Shards dealt from measured section time" line, every other job's Region), so
# a reader matching too loosely picks the wrong one.
#
# GitHub, the one outside dependency, is a stub `gh` first on PATH that answers from the same saved
# logs and records every call, so the live path is exercised without the network.

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/ci-section-time-readings.sh"
SAMPLE="$DIR/ci-section-time-sample"
RECORD="$DIR/../tests/ci-section-time-readings.tsv"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.cireadings.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;;
esac
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
says() {  # says <description> <literal needle> <text>
  case "$3" in *"$2"*) ok ;; *) bad "$1 (wanted [$2] in: ${3:0:900})" ;; esac
}
lacks() {  # lacks <description> <literal needle> <text>
  case "$3" in *"$2"*) bad "$1 (did not want [$2] in: ${3:0:900})" ;; *) ok ;; esac
}
same() {  # same <description> <file a> <file b>
  if cmp -s "$2" "$3"; then ok; else diff "$2" "$3" > "$WORK/diff.out"; bad "$1 ($(sed -n '1,8p' "$WORK/diff.out"))"; fi
}
rc_is() {  # rc_is <description> <wanted> <got>
  if [ "$3" -eq "$2" ]; then ok; else bad "$1 (exit $3, wanted $2)"; fi
}
rc_not() {  # rc_not <description> <unwanted> <got>
  if [ "$3" -ne "$2" ]; then ok; else bad "$1 (exit $3)"; fi
}

# A copy of the saved logs a case can damage without touching the fixture.
logs_copy() {  # logs_copy <name>: prints the directory
  mkdir -p "$WORK/$1" && cp "$SAMPLE"/logs/*.log "$WORK/$1/" && printf '%s' "$WORK/$1"
}

# The record this suite compares against must be the shape the budget reads, or every comparison
# below is against the wrong thing (L400).
hdr="$(head -1 "$RECORD")"
says "the committed record names its runner group, the column the budget reads" "runner_group" "$hdr"

# ---- 1. It reproduces the committed record's rows from the saved logs ----
out="$("$TOOL" --print --record "$RECORD" --runs "$SAMPLE/runs.tsv" --logs "$SAMPLE/logs" 2>"$WORK/err1")"; rc=$?
err="$(cat "$WORK/err1")"
printf '%s\n' "$out" > "$WORK/out1"
rc_is "a read of the saved logs succeeds" 0 "$rc"
if [ "$(head -1 "$WORK/out1")" = "$hdr" ]; then ok; else bad "its header is not the committed record's ($(head -1 "$WORK/out1"))"; fi
rows="$(tail -n +2 "$WORK/out1" | grep -c .)"
if [ "$rows" -eq 6 ]; then ok; else bad "six of the seven saved runs carry a reading, got $rows rows"; fi
# Each row, field for field, is the one the committed record holds for that run.
tail -n +2 "$WORK/out1" | cut -f1 > "$WORK/ids1"
grep -F -f "$WORK/ids1" "$RECORD" > "$WORK/want1"
tail -n +2 "$WORK/out1" > "$WORK/got1"
same "every row is the committed record's row for that run" "$WORK/want1" "$WORK/got1"
# The cases the sample was chosen for, named so a failure says which shape broke.
says "a run from before the processor was printed records it as unknown" \
  "$(printf '42525286498\t2026-11-08T21:27:23Z\t37166a2b\tpush\tsuccess\t4\tunknown\teastus2\t3398\t1092\tfaster')" "$out"
says "a run whose sync suite ran in part 2 takes part 2's runner, not part 1's" \
  "$(printf '42779181900\t2026-11-10T07:59:35Z\t566c797f\tpush\tfailure\t4\tAMD EPYC 7763 64-Core Processor\twestus\t3450\t1379\tslower')" "$out"
says "a run the budget turned red is read from its failure line too" \
  "$(printf '42722042892\t2026-11-09T23:38:04Z\t7d801b06\tpull_request\tfailure\t4\tAMD EPYC 9V74 80-Core Processor\twestcentralus\t3418\t1393\tslower')" "$out"
# The run that never started a job has no reading, and says so rather than vanishing (L98).
says "a run with no jobs is named" "42673160323" "$err"
says "and the reason is given" "no jobs ran" "$err"
lacks "and it carries no row" "42673160323" "$out"
says "the split between the runner groups is derived from the record and said" "1190s" "$err"

# ---- 2. The order is stable ----
"$TOOL" --print --record "$RECORD" --runs "$SAMPLE/runs.tsv" --logs "$SAMPLE/logs" > "$WORK/out2" 2>/dev/null
same "two reads of the same runs print the same bytes" "$WORK/out1" "$WORK/out2"
# gh lists newest first; a list in any other order gives the same file.
sort -t "$(printf '\t')" -k1,1 "$SAMPLE/runs.tsv" > "$WORK/runs-shuffled.tsv"
"$TOOL" --print --record "$RECORD" --runs "$WORK/runs-shuffled.tsv" --logs "$SAMPLE/logs" > "$WORK/out3" 2>/dev/null
same "the order runs are listed in does not change the file" "$WORK/out1" "$WORK/out3"
# Oldest first, and two runs started in the same second by run id, which is how the record is laid out.
tail -n +2 "$WORK/out1" | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k1,1n > "$WORK/sorted1"
same "rows are in created_at order, ties by run id" "$WORK/got1" "$WORK/sorted1"
# In the real record run ids rise with time, so the two orders agree and the check above cannot
# tell which one the tool sorts by. A run given an earlier start than its id suggests can.
awk -F'\t' -v OFS='\t' '$1 == "42897282086" { $2 = "2026-11-08T21:27:24Z" } { print }' "$SAMPLE/runs.tsv" > "$WORK/runs-early.tsv"
"$TOOL" --print --record "$RECORD" --runs "$WORK/runs-early.tsv" --logs "$SAMPLE/logs" 2>/dev/null | sed -n '3p' > "$WORK/out-early"
says "the order is by created_at, not by run id" "$(printf '42897282086\t2026-11-08T21:27:24Z')" "$(cat "$WORK/out-early")"

# ---- 3. A log missing the core count is reported, not guessed ----
nc="$(logs_copy nocores)"
grep -v 'Z cores: ' "$SAMPLE/logs/42779181900.log" > "$nc/42779181900.log"
cp "$RECORD" "$WORK/record-nc.tsv"
out="$("$TOOL" --print --record "$RECORD" --runs "$SAMPLE/runs.tsv" --logs "$nc" 2>"$WORK/err3")"; rc=$?
err="$(cat "$WORK/err3")"
rc_not "a log with no core count line fails the read" 0 "$rc"
says "and names the run" "42779181900" "$err"
says "and says what is missing" "no core count" "$err"
lacks "and prints no rows at all, rather than a record with a guess in it" "42779181900" "$out"
lacks "not even the readable runs, since a partial record reads as a complete one" "42897282086" "$out"
"$TOOL" --record "$WORK/record-nc.tsv" --runs "$SAMPLE/runs.tsv" --logs "$nc" >/dev/null 2>&1
same "and a refresh leaves the record exactly as it was" "$RECORD" "$WORK/record-nc.tsv"
# The step prints UNKNOWN when it cannot count, which is no more a core count than silence.
nu="$(logs_copy unknowncores)"
sed 's/Z cores: 4$/Z cores: UNKNOWN/' "$SAMPLE/logs/42897282086.log" > "$nu/42897282086.log"
"$TOOL" --print --record "$RECORD" --runs "$SAMPLE/runs.tsv" --logs "$nu" >/dev/null 2>"$WORK/err3u"; rc=$?
rc_not "a core count of UNKNOWN fails the read too" 0 "$rc"
says "and names the run" "42897282086" "$(cat "$WORK/err3u")"

# ---- 4. A log whose format moved is refused, never read as a quiet skip (L100) ----
ns="$(logs_copy nosection)"
grep -v 'section time against a\|sections cost' "$SAMPLE/logs/42722042201.log" > "$ns/42722042201.log"
"$TOOL" --print --record "$RECORD" --runs "$SAMPLE/runs.tsv" --logs "$ns" >/dev/null 2>"$WORK/err4"; rc=$?
rc_not "a sync suite result with no section time line fails the read" 0 "$rc"
says "and names the run" "42722042201" "$(cat "$WORK/err4")"
says "and says what is missing" "no section time" "$(cat "$WORK/err4")"
# A suite dealt to two parts has two section times, and picking one would be a guess.
tw="$(logs_copy twice)"
cp "$SAMPLE/logs/42897282086.log" "$tw/42897282086.log"
grep -F 'test-claude-sync.sh ' "$SAMPLE/logs/42897282086.log" | grep -F ' passed' | sed 's/^suites part 1/suites part 3/' >> "$tw/42897282086.log"
"$TOOL" --print --record "$RECORD" --runs "$SAMPLE/runs.tsv" --logs "$tw" >/dev/null 2>"$WORK/err4t"; rc=$?
rc_not "a sync suite that reported in two parts fails the read" 0 "$rc"
says "and says so" "more than one part" "$(cat "$WORK/err4t")"
# Nothing read at all is refused, or an empty record would clear every bound the budget has.
: > "$WORK/runs-empty.tsv"
cp "$RECORD" "$WORK/record-empty.tsv"
"$TOOL" --record "$WORK/record-empty.tsv" --runs "$WORK/runs-empty.tsv" --logs "$SAMPLE/logs" >/dev/null 2>"$WORK/err4e"; rc=$?
rc_not "a refresh that read no runs fails" 0 "$rc"
same "and leaves the record alone" "$RECORD" "$WORK/record-empty.tsv"

# ---- 5. The runner group split comes from the record, or is given ----
sed '1s/runner_group/something_else/' "$RECORD" > "$WORK/record-nogroup.tsv"
"$TOOL" --print --record "$WORK/record-nogroup.tsv" --runs "$SAMPLE/runs.tsv" --logs "$SAMPLE/logs" >/dev/null 2>"$WORK/err5"; rc=$?
rc_not "a record with no runner groups gives no split, and the read refuses" 0 "$rc"
says "and asks for one" "--split" "$(cat "$WORK/err5")"
"$TOOL" --print --split 1190 --record "$WORK/record-nogroup.tsv" --runs "$SAMPLE/runs.tsv" --logs "$SAMPLE/logs" > "$WORK/out5" 2>/dev/null; rc=$?
rc_is "a split given by hand is used" 0 "$rc"
tail -n +2 "$WORK/out5" > "$WORK/got5"
same "and gives the same groups the record has" "$WORK/got1" "$WORK/got5"
"$TOOL" --print --split 1350 --record "$RECORD" --runs "$SAMPLE/runs.tsv" --logs "$SAMPLE/logs" > "$WORK/out5b" 2>/dev/null
says "a different split moves a reading between groups" \
  "$(printf '42779181900\t2026-11-10T07:59:35Z\t566c797f\tpush\tfailure\t4\tAMD EPYC 7763 64-Core Processor\twestus\t3450\t1379\tslower')" "$(cat "$WORK/out5b")"
says "one below it goes to the faster group" "$(printf '1092\tfaster')" "$(cat "$WORK/out5b")"
says "and one between them is now faster" "$(printf '1303\tfaster')" "$(cat "$WORK/out5b")"

# ---- 6. Rewriting the record keeps what it did not re-read ----
cp "$RECORD" "$WORK/record-rw.tsv"
"$TOOL" --record "$WORK/record-rw.tsv" --runs "$SAMPLE/runs.tsv" --logs "$SAMPLE/logs" >/dev/null 2>"$WORK/err6"; rc=$?
rc_is "a refresh over the saved runs succeeds" 0 "$rc"
same "and leaves the committed record byte for byte as it was" "$RECORD" "$WORK/record-rw.tsv"
says "it says how many rows it re-read" "6 runs read" "$(cat "$WORK/err6")"
"$TOOL" --record "$WORK/record-rw.tsv" --runs "$SAMPLE/runs.tsv" --logs "$SAMPLE/logs" >/dev/null 2>&1
same "a second refresh changes nothing" "$RECORD" "$WORK/record-rw.tsv"
# A row the record holds wrongly is put right from the log.
awk -F'\t' -v OFS='\t' '$1 == "42722042892" { $10 = 1000; $11 = "faster" } { print }' "$RECORD" > "$WORK/record-wrong.tsv"
"$TOOL" --record "$WORK/record-wrong.tsv" --runs "$SAMPLE/runs.tsv" --logs "$SAMPLE/logs" >/dev/null 2>&1
same "a row that disagrees with its log is rewritten from the log" "$RECORD" "$WORK/record-wrong.tsv"
# A run that is new to the record is added in its place in the order.
grep -v '^42779181900	' "$RECORD" > "$WORK/record-missing.tsv"
"$TOOL" --record "$WORK/record-missing.tsv" --runs "$SAMPLE/runs.tsv" --logs "$SAMPLE/logs" >/dev/null 2>&1
same "a run the record lacks is added where it belongs" "$RECORD" "$WORK/record-missing.tsv"

# ---- 7. The live path lists both events and fetches each log through gh ----
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_LOG"
case "$1 $2" in
  "run list")
    case " $* " in
      *" --event push "*) awk -F'\t' '$4 == "push" { print $0 "\tcompleted" }' "$GH_STUB_RUNS" ;;
      *" --event pull_request "*)
        # A run still going, which has no full log yet and must not be fetched or read.
        printf '42999999999\t2026-11-10T23:00:00Z\tabcdef12\tpull_request\t\tin_progress\n'
        awk -F'\t' '$4 == "pull_request" { print $0 "\tcompleted" }' "$GH_STUB_RUNS" ;;
    esac ;;
  "run view")
    [ "$3" = "${GH_STUB_FAIL_ID:-none}" ] && { echo "HTTP 410: logs expired" >&2; exit 1; }
    cat "$GH_STUB_LOGS/$3.log" ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 3 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export GH_STUB_RUNS="$SAMPLE/runs.tsv" GH_STUB_LOGS="$SAMPLE/logs" GH_STUB_LOG="$WORK/gh-calls"
: > "$GH_STUB_LOG"
PATH="$WORK/bin:$PATH" "$TOOL" --print --record "$RECORD" --cache "$WORK/cache" > "$WORK/out7" 2>"$WORK/err7"; rc=$?
rc_is "a live read through gh succeeds" 0 "$rc"
same "and prints the same rows the saved logs give" "$WORK/out1" "$WORK/out7"
calls="$(cat "$GH_STUB_LOG")"
says "it lists the pushes to main" "--event push --branch main" "$calls"
says "and the pull requests" "--event pull_request" "$calls"
says "from the earliest run the record holds" "--created >=2026-11-08T21:27:23Z" "$calls"
says "and fetches a run's log" "run view 42897282086 --repo danwright32/claude-config --log" "$calls"
lacks "and not the log of a run still going" "run view 42999999999" "$calls"
# GitHub's own status filter left out 3 of 290 finished runs on 2026-11-10, so it is not asked for.
lacks "finished runs are picked out by the tool, not by gh's status filter" "--status" "$calls"
# A second read takes the logs from the cache: a finished run's log never changes.
: > "$GH_STUB_LOG"
PATH="$WORK/bin:$PATH" "$TOOL" --print --record "$RECORD" --cache "$WORK/cache" > "$WORK/out7b" 2>/dev/null
same "a read from the cache prints the same rows" "$WORK/out1" "$WORK/out7b"
lacks "and fetches no log twice" "run view" "$(cat "$GH_STUB_LOG")"
# A log gh could not fetch is not the same as a run that has none. For a run the record already
# holds (GitHub expires logs), the recorded row is kept, so a refresh loses nothing.
cp "$RECORD" "$WORK/record-gone.tsv"
GH_STUB_FAIL_ID=42566634695 PATH="$WORK/bin:$PATH" "$TOOL" --record "$WORK/record-gone.tsv" --cache "$WORK/cache-gone" >/dev/null 2>"$WORK/err7c"; rc=$?
rc_is "a recorded run whose log gh cannot fetch does not stop the refresh" 0 "$rc"
says "it names the run and keeps its row" "kept run 42566634695's row from the record" "$(cat "$WORK/err7c")"
same "and the record keeps that row exactly" "$RECORD" "$WORK/record-gone.tsv"
if [ ! -e "$WORK/cache-gone/42566634695.log" ]; then ok; else bad "a failed fetch left a log in the cache that a later read would trust"; fi
# For a run the record does not hold, there is no reading to keep, so the refresh refuses.
grep -v '^42566634695	' "$RECORD" > "$WORK/record-new.tsv"
cp "$WORK/record-new.tsv" "$WORK/record-new-before.tsv"
GH_STUB_FAIL_ID=42566634695 PATH="$WORK/bin:$PATH" "$TOOL" --record "$WORK/record-new.tsv" --cache "$WORK/cache-new" >/dev/null 2>"$WORK/err7d"; rc=$?
rc_not "a new run whose log gh fails to fetch fails the refresh" 0 "$rc"
says "and names the run" "COULD NOT READ run 42566634695" "$(cat "$WORK/err7d")"
same "and leaves the record alone" "$WORK/record-new-before.tsv" "$WORK/record-new.tsv"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
