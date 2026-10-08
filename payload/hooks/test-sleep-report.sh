#!/usr/bin/env bash
# Tests for the night's sleep report (claude-config#835): lib/sleep-report.py, which writes the
# report and the notes it is built from, and sleep_note in lib/sleep.sh, the one writer every phase
# hands its notes to.
#
# Nothing here may reach the real ~/Downloads: every record names a report under this suite's own
# folder (the record's `report` is the seam, as /sleep writes it from HOME), HOME is pointed there
# too, and the real Downloads is listed before and after to prove it (L2, L322). pmset and gh are
# stand-ins on PATH that log every call, so a stand-in that was never reached is seen (L143).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/sleep.sh"
PY="$DIR/lib/sleep-report.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '${3:0:400}')"; fi; }
has(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (wanted '$2' in: ${3:0:1500})"; fi; }
lacks(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (did not want '$2' in: ${3:0:1500})"; fi; }

if ! . "$LIB"; then
  echo "FAIL: $LIB could not be sourced"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# The real Downloads, as it stands before anything runs: no sleep report may appear in it.
real_downloads_before="$(ls "$HOME/Downloads" 2>/dev/null | grep -c -E '^(sleep-report-|Sleep report )' || true)"

# Stand-ins on PATH. Each logs its argv; what it answers is set by files in $WORK/fake.
FAKE="$WORK/fake"; BIN="$WORK/bin"; mkdir -p "$FAKE" "$BIN"
cat > "$BIN/pmset" <<'SH'
#!/bin/bash
echo "pmset $*" >> "$FAKE_DIR/calls"
[ -f "$FAKE_DIR/pmset.fail" ] && { echo "pmset: no power source" >&2; exit 1; }
cat "$FAKE_DIR/pmset.out"
SH
cat > "$BIN/gh" <<'SH'
#!/bin/bash
printf 'gh' >> "$FAKE_DIR/calls"; printf ' [%s]' "$@" >> "$FAKE_DIR/calls"; echo >> "$FAKE_DIR/calls"
repo=""; kind="$1"
# gh pr view N reads gh-pr-view-<repo>-N, and is not found when that file is absent.
[ "$2" = view ] && kind="$1-view" && num="$3"
while [ $# -gt 0 ]; do [ "$1" = "-R" ] && repo="$2"; shift; done
f="$FAKE_DIR/gh-$kind-${repo//\//_}${num:+-$num}"
[ -f "$f.fail" ] && { cat "$f.fail" >&2; exit 1; }
if [ -n "${num:-}" ] && [ ! -f "$f" ]; then echo "no pull requests found" >&2; exit 1; fi
[ -f "$f" ] && cat "$f" || echo '[]'
SH
chmod +x "$BIN/pmset" "$BIN/gh"
export FAKE_DIR="$FAKE"
export PATH="$BIN:$PATH"
echo "Now drawing from 'AC Power'" > "$FAKE/pmset.out"

SINCE=1791430920000   # 11:42 PM ET on Wed Oct 7 2026
WOKE=1791457500000    # 7:05 AM ET on Thu Oct 8
SLEEPDIR="$WORK/hm/.claude/state/sleep"
DL="$WORK/hm/Downloads"
mkdir -p "$SLEEPDIR/ended"
record(){   # $1 = generation, $2 = workers as a JSON list, $3 = where (current or an ended file)
  printf '{"v":1,"generation":"%s","since":%s,"until":%s,"night":"2026-10-07","bootTime":1759800000,"report":"%s/Sleep report %s.md","startedBy":{"sessionId":"aaaa1111","cwd":"/r/repo"},"workers":%s,"placeBefore":"home"}' \
    "$1" "$SINCE" "$((SINCE + 86400000))" "$DL" "$1" "$2" > "$3"
}
report_of(){ cat "$DL/Sleep report $1.md" 2>/dev/null; }
notes_of(){ cat "$SLEEPDIR/notes/$1.jsonl" 2>/dev/null; }
py(){ HOME="$WORK/hm" SLEEP_REPORT_NOW_MS="${NOW:-$SINCE}" python3 "$PY" "$@"; }

# ---- /sleep writes the report at once, with its header (L10) ----
record g1 '["aaaa1111","bbbb2222"]' "$SLEEPDIR/current.json"
out="$(py start --record "$SLEEPDIR/current.json" --by aaaa1111 2>&1)"; rc=$?
check_eq "start succeeds" 0 "$rc"
r="$(report_of g1)"
has "the report exists from /sleep, titled by its night" "# Sleep report, night of Wed Oct 7" "$r"
has "the header gives the start in ET and the folder" "Started 11:42 PM ET on Wed Oct 7 in /r/repo" "$r"
has "the header gives the power state" "on AC power" "$r"
has "the header names the workers" "Overnight workers: 2 sessions (aaaa1111, bbbb2222)" "$r"
has "before wake it says it is not final" "Still asleep as of 11:42 PM ET on Wed Oct 7" "$r"
has "pmset was asked" "pmset -g batt" "$(cat "$FAKE/calls")"
check_eq "the start note is one JSON line naming the power" "start|on AC power|g1|$SINCE" \
  "$(notes_of g1 | python3 -c 'import json,sys; [print("%s|%s|%s|%s" % (j["kind"], j["power"], j["generation"], j["at"])) for j in map(json.loads, sys.stdin)]')"
check_eq "no temp file is left beside the report" "Sleep report g1.md" "$(ls -A "$DL")"

echo "Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1)	41%; discharging; 3:10 remaining present: true" > "$FAKE/pmset.out"
record g2 '[]' "$SLEEPDIR/ended/g2.json"
py start --record "$SLEEPDIR/ended/g2.json" --by aaaa1111 >/dev/null 2>&1
r="$(report_of g2)"
has "on battery is said with the charge" "on battery (41%)" "$r"
has "no worker is said as such" "No session was enrolled to work overnight." "$r"
touch "$FAKE/pmset.fail"
record g3 '[]' "$SLEEPDIR/ended/g3.json"
py start --record "$SLEEPDIR/ended/g3.json" --by aaaa1111 >/dev/null 2>&1
has "a power read that fails is said, never guessed" "power unknown (pmset: no power source)" "$(report_of g3)"
rm -f "$FAKE/pmset.fail"

# A report that cannot be written at /sleep is a failure, said (the report must exist).
printf '{"v":1,"generation":"g4","since":%s,"until":%s,"night":"2026-10-07","bootTime":1,"report":"%s/afile/sleep-report.md","startedBy":{"sessionId":"a","cwd":"/r"},"workers":[],"placeBefore":"home"}' "$SINCE" "$((SINCE + 1))" "$WORK" > "$SLEEPDIR/ended/g4.json"
: > "$WORK/afile"
out="$(py start --record "$SLEEPDIR/ended/g4.json" --by a 2>&1)"; rc=$?
check_eq "a report that cannot be written fails start" 1 "$rc"
has "and says why" "the report could not be written" "$out"

# A record missing what the report needs is refused by name.
echo '{"v":1}' > "$WORK/thin.json"
out="$(py render --record "$WORK/thin.json" 2>&1)"; rc=$?
check_eq "a record with no generation is refused" 2 "$rc"
has "naming what is missing" "generation" "$out"

# ---- sleep_note: the one writer, append only, then the report again ----
CUR="$SLEEPDIR/current.json"
record g5 '["aaaa1111"]' "$CUR"
NOW_ASLEEP=$((SINCE + 1000))
note(){ HOME="$WORK/hm" SLEEP_REPORT_NOW_MS="${NOW:-$NOW_ASLEEP}" sleep_note "$1" "$CUR" "$NOW_ASLEEP" 1759800000; }
out="$(note '{"kind":"question","by":"aaaa1111","repo":"o/r","issue":12,"text":"Should the cache be per account?"}' 2>&1)"; rc=$?
check_eq "a note while asleep is written" 0 "$rc"
has "the report is rendered after the note" "Should the cache be per account?" "$(report_of g5)"
has "a question sits under its heading with its issue" "o/r#12" "$(report_of g5)"
note '{"kind":"lesson","by":"aaaa1111","text":"Read the schema first."}' >/dev/null 2>&1
check_eq "notes append, never replace" 2 "$(notes_of g5 | wc -l | tr -d ' ')"
check_eq "the writer stamps version, time and generation" "1|$NOW_ASLEEP|g5" \
  "$(notes_of g5 | tail -1 | python3 -c 'import json,sys; j=json.load(sys.stdin); print("%s|%s|%s" % (j["v"], j["at"], j["generation"]))')"

# Twenty writers at once: every line lands whole (append mode, one write per note).
for i in $(seq 1 20); do note "{\"kind\":\"finding\",\"by\":\"w$i\",\"text\":\"finding $i\"}" >/dev/null 2>&1 & done
wait
check_eq "twenty notes at once all land" 22 "$(notes_of g5 | wc -l | tr -d ' ')"
check_eq "and every line is whole JSON" 22 "$(notes_of g5 | python3 -c 'import json,sys; print(sum(1 for l in sys.stdin if json.loads(l)))')"
r="$(report_of g5)"
missing=""; for i in $(seq 1 20); do [[ "$r" == *"finding $i"$'\n'* || "$r" == *"finding $i" ]] || missing="$missing $i"; done
check_eq "the report after them carries every finding (#909)" "" "$missing"

# Two renders out of order, made to happen every time (#909): the first note's render reads the
# notes and is then held before it replaces the report; a second note lands and renders. The held
# render must never put back a report that is missing the second note. Each wait is on a marker
# the render drops, with a deadline, never a fixed sleep.
PAUSE="$WORK/pause"; MARKS="$WORK/marks"; mkdir -p "$PAUSE" "$MARKS"
upto(){ local end=$((SECONDS + 20)); while [ "$SECONDS" -lt "$end" ]; do eval "$1" && return 0; sleep 0.05; done; return 1; }
SLEEP_REPORT_PAUSE="$PAUSE" SLEEP_REPORT_MARKS="$MARKS" note '{"kind":"finding","by":"a","text":"held render A"}' >/dev/null 2>&1 &
held=$!
upto 'ls "$MARKS"/paused.* >/dev/null 2>&1' || { fail=$((fail + 1)); echo "FAIL: the held render never reached its pause"; }
SLEEP_REPORT_MARKS="$MARKS" note '{"kind":"finding","by":"b","text":"late note B"}' >/dev/null 2>&1 &
late=$!
# The late note either finishes its render, or waits for the held one's: either way it has acted.
upto '! kill -0 "$late" 2>/dev/null || ls "$MARKS"/waiting.* >/dev/null 2>&1' || { fail=$((fail + 1)); echo "FAIL: the late note neither rendered nor waited"; }
touch "$PAUSE/go"
wait "$held" "$late"
has "a render held after reading never replaces a newer one (#909)" "late note B" "$(report_of g5)"
has "and the held note is there too" "held render A" "$(report_of g5)"

# A note whose render gives up is still in the report: the render holding the lock looks again
# once it has written, and renders again while the notes have grown since it read them (#909).
rm -f "$PAUSE/go" "$MARKS"/paused.* "$MARKS"/waiting.*
SLEEP_REPORT_PAUSE="$PAUSE" SLEEP_REPORT_MARKS="$MARKS" note '{"kind":"finding","by":"a","text":"held render C"}' >/dev/null 2>&1 &
held=$!
upto 'ls "$MARKS"/paused.* >/dev/null 2>&1' || { fail=$((fail + 1)); echo "FAIL: the held render never reached its pause"; }
out="$(SLEEP_REPORT_LOCK_S=1 note '{"kind":"finding","by":"b","text":"gave up note D"}' 2>&1)"
has "the note behind the held render gave up its own render" "so this one gave up" "$out"
touch "$PAUSE/go"
wait "$held"
has "and the held render, looking again, put it in the report" "gave up note D" "$(report_of g5)"

# A render that cannot take its turn within the deadline gives up and says so; its note is written.
LOCKF="$SLEEPDIR/notes/g5.render.lock"
python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(60)' "$LOCKF" "$MARKS/holder" &
holder=$!
upto '[ -e "$MARKS/holder" ]' || { fail=$((fail + 1)); echo "FAIL: the stand in holder never took the lock"; }
before="$(notes_of g5 | wc -l | tr -d ' ')"
out="$(SLEEP_REPORT_LOCK_S=1 note '{"kind":"finding","by":"c","text":"behind a held lock"}' 2>&1)"; rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check_eq "a note whose render cannot take its turn is still written" 0 "$rc"
check_eq "and its line is there" "$((before + 1))" "$(notes_of g5 | wc -l | tr -d ' ')"
has "and the render that gave up says so" "held it for 1 seconds, so this one gave up" "$out"

# A lock that cannot even be opened is a refusal said in words, never a traceback.
rm -f "$LOCKF"; mkdir "$LOCKF"
out="$(py render --record "$CUR" 2>&1)"; rc=$?
rmdir "$LOCKF"
check_eq "a render whose lock cannot be opened fails" 1 "$rc"
has "and says why" "the report's render lock could not be opened" "$out"
lacks "never as a traceback" "Traceback" "$out"

# A garbled bound setting never costs a note: it falls back to its default.
out="$(SLEEP_REPORT_GH_TOTAL_S=abc note '{"kind":"finding","by":"aaaa1111","text":"garbled bound"}' 2>&1)"; rc=$?
check_eq "a note is written whatever the GitHub bound setting says" 0 "$rc"
has "and landed" "garbled bound" "$(notes_of g5)"

# Refusals write nothing.
before="$(notes_of g5 | wc -l | tr -d ' ')"
out="$(note 'not json' 2>&1)"; rc=$?
check_eq "a note that is not JSON is refused" 1 "$rc"
has "and says so" "not JSON" "$out"
out="$(note '{"text":"no kind"}' 2>&1)"; rc=$?
check_eq "a note with no kind is refused" 1 "$rc"
out="$(note '{"kind":"Bad Kind!"}' 2>&1)"; rc=$?
check_eq "a kind that is not a plain word is refused" 1 "$rc"
out="$(note '{"kind":"done","pr":"12","repo":"o/r"}' 2>&1)"; rc=$?
check_eq "a PR that is not a number is refused at the writer" 1 "$rc"
has "naming the field" "the note's pr must be a number" "$out"
out="$(note '{"kind":"done","issue":3,"repo":["o","r"]}' 2>&1)"; rc=$?
check_eq "a repo that is not text is refused at the writer" 1 "$rc"
check_eq "no refused note was written" "$before" "$(notes_of g5 | wc -l | tr -d ' ')"
out="$(HOME="$WORK/hm" sleep_note '{"kind":"finding","text":"late"}' "$CUR" "$((SINCE + 86400000))" 1759800000 2>&1)"; rc=$?
check_eq "a note when the Mac is not asleep is refused" 1 "$rc"
has "naming the state the record is in" "expired" "$out"
check_eq "and wrote nothing" "$before" "$(notes_of g5 | wc -l | tr -d ' ')"

# A report that cannot be rendered never loses the note: written, said, and exit 0 so nobody retries it.
mv "$DL" "$WORK/dl-aside"; : > "$DL"
out="$(note '{"kind":"finding","by":"aaaa1111","text":"kept"}' 2>&1)"; rc=$?
check_eq "a note whose report cannot be rendered still succeeds" 0 "$rc"
has "and the render failure is said" "the note was written, but the report could not be rendered" "$out"
has "the note is there" "kept" "$(notes_of g5)"
rm -f "$DL"; mv "$WORK/dl-aside" "$DL"

# ---- the report at wake: done from GitHub, cross checked against notes (L78) ----
record g6 '["aaaa1111","bbbb2222","cccc3333","dddd4444"]' "$SLEEPDIR/ended/g6.json"
N="$SLEEPDIR/notes/g6.jsonl"
mkdir -p "$SLEEPDIR/notes"
{
  echo '{"v":1,"kind":"start","at":'"$SINCE"',"by":"aaaa1111","power":"on AC power","generation":"g6"}'
  echo '{"v":1,"kind":"claim","at":1791442800000,"by":"aaaa1111","repo":"o/r","issue":12,"generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791443000000,"by":"aaaa1111","repo":"o/r","issue":12,"pr":34,"text":"Cache split by account","generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791443100000,"by":"aaaa1111","repo":"o/r","issue":13,"pr":36,"text":"Said done but not merged","generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791443150000,"by":"aaaa1111","repo":"o/r","pr":38,"text":"Merged but the search lags","generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791443160000,"by":"aaaa1111","repo":"o/r","pr":39,"text":"Cannot be confirmed","generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791443170000,"by":"bbbb2222","repo":"o/r","pr":39,"text":"Noted twice","generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791443180000,"by":"aaaa1111","repo":"o/q","pr":5,"text":"Half read","generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791443182000,"by":"aaaa1111","repo":"o/r","pr":"--web","text":"A flag for a number","generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791443183000,"by":"aaaa1111","repo":"o/q","text":"Paired on a review","generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791443184000,"by":"aaaa1111","repo":"o/r","pr":[1,2],"issue":{"n":3},"text":"Odd shapes","generation":"g6"}'
  echo '{"v":1,"kind":"question","at":1791443185000,"by":"aaaa1111","cwd":"/r/repo","questions":["Merge PR #31, the wording change?","Keep the old flag?"],"generation":"g6"}'
  echo '{"v":1,"kind":"save","at":1791443186000,"by":"aaaa1111","files":["~/.claude/CLAUDE.md"],"rule":"Always ask first.","generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791443190000,"by":"aaaa1111","text":"Tidied the scratch notes","generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791443195000,"by":"aaaa1111","repo":"o/r","text":"Answered a review","generation":"g6"}'
  echo '{"v":1,"kind":"claim","at":1791443200000,"by":"bbbb2222","repo":"o/r","issue":20,"generation":"g6"}'
  echo '{"v":1,"kind":"claim","at":1791443300000,"by":"bbbb2222","repo":"o/r","issue":21,"generation":"g6"}'
  echo '{"v":1,"kind":"parked","at":1791443400000,"by":"bbbb2222","repo":"o/r","issue":21,"branch":"fix-21","text":"Two hours with no fix","generation":"g6"}'
  echo '{"v":1,"kind":"heartbeat","at":1791455100000,"by":"aaaa1111","usage":{"costUsd":1.25,"rateLimits":[{"kind":"five_hour","percentUsed":100},{"kind":"seven_day","percentUsed":61}]},"generation":"g6"}'
  echo '{"v":1,"kind":"heartbeat","at":1791456900000,"by":"bbbb2222","usage":{"costUsd":2.25},"generation":"g6"}'
  echo '{"v":1,"kind":"heartbeat","at":1791443000000,"by":"dddd4444","generation":"g6"}'
  echo '{"v":1,"kind":"stopped","at":1791443500000,"by":"dddd4444","text":"queue empty","generation":"g6"}'
  echo '{"v":1,"kind":"wait","at":1791444000000,"by":"aaaa1111","minutes":5,"error":"rate_limit","generation":"g6"}'
  echo '{"v":1,"kind":"wait","at":1791444300000,"by":"aaaa1111","minutes":10,"error":"server_error","generation":"g6"}'
  echo '{"v":1,"kind":"wait","at":1791444600000,"by":"aaaa1111","minutes":20.0,"error":"rate_limit","generation":"g6"}'
  echo '{"v":1,"kind":"issue","at":1791444400000,"by":"aaaa1111","repo":"o/r","title":"Cache misses on cold start","priority":"p2","labels":["perf"],"milestone":"Ungrouped","text":"Seen while fixing 12","generation":"g6"}'
  echo '{"v":1,"kind":"mystery","at":1791444500000,"by":"aaaa1111","text":"a kind nobody renders yet","generation":"g6"}'
  echo 'this line is broken'
  echo '{"v":1,"kind":"claim","at":1791444600000,"by":"aaaa1111","repo":"o/s","issue":3,"generation":"g6"}'
  echo '{"v":1,"kind":"failed","at":1791444700000,"by":"aaaa1111","repo":"o/s","issue":3,"text":"Classifier refused the push","generation":"g6"}'
  echo '{"v":1,"kind":"woke","at":'"$WOKE"',"by":"eeee5555","generation":"g6"}'
} > "$N"
echo '[{"number":34,"title":"Split cache","url":"https://github.com/o/r/pull/34","mergedAt":"2026-10-08T07:05:00Z"},{"number":35,"title":"Nobody noted","url":"https://github.com/o/r/pull/35","mergedAt":"2026-10-08T08:00:00Z"},{"number":30,"title":"Before sleep","url":"https://github.com/o/r/pull/30","mergedAt":"2026-10-07T20:00:00Z"}]' > "$FAKE/gh-pr-o_r"
echo '[{"number":12,"title":"Cache per account","url":"https://github.com/o/r/issues/12","closedAt":"2026-10-08T07:06:00Z","stateReason":"COMPLETED"}]' > "$FAKE/gh-issue-o_r"
echo '{"number":36,"title":"Not merged","mergedAt":null}' > "$FAKE/gh-pr-view-o_r-36"
echo '{"number":38,"title":"Lagging search","mergedAt":"2026-10-08T07:30:00Z"}' > "$FAKE/gh-pr-view-o_r-38"
echo 'HTTP 502: Bad Gateway' > "$FAKE/gh-pr-view-o_r-39.fail"
echo '[{"number":5,"title":"Half","url":"u","mergedAt":"2026-10-08T03:40:00.123-04:00"}]' > "$FAKE/gh-pr-o_q"
echo 'HTTP 500' > "$FAKE/gh-issue-o_q.fail"
echo 'HTTP 502: Bad Gateway' > "$FAKE/gh-pr-o_s.fail"
echo 'HTTP 503: Service Unavailable' > "$FAKE/gh-issue-o_s.fail"
: > "$FAKE/calls"
out="$(NOW=$WOKE py render --record "$SLEEPDIR/ended/g6.json" --final 2>&1)"; rc=$?
check_eq "the final render succeeds though one repo could not be read" 0 "$rc"
r="$(report_of g6)"
has "it says when sleep ended" "Woke at 7:05 AM ET on Thu Oct 8" "$r"
lacks "and no longer says still asleep" "Still asleep" "$r"
has "a merged PR a note named is done" "o/r PR #34 Split cache" "$r"
has "a closed issue is done" "o/r issue #12 Cache per account" "$r"
lacks "a PR merged before sleep is not done tonight" "PR #30" "$r"
has "a PR merged with no note is flagged" "o/r PR #35 merged with no session noting it" "$r"
has "a note saying done that GitHub does not show is flagged" "o/r PR #36 was noted done, but GitHub does not show it merged since sleep began" "$r"
has "only after reading that PR by its number" "[pr] [view] [36] [-R] [o/r]" "$(cat "$FAKE/calls")"
has "a noted PR the search missed but its own read shows merged is done, not accused (L1014)" "o/r PR #38 Lagging search, merged 3:30 AM ET (found by its number" "$r"
lacks "and is not flagged" "PR #38 was noted done" "$r"
has "a noted PR GitHub cannot confirm says so, never accuses" "o/r PR #39 was noted done, and GitHub could not confirm it: HTTP 502: Bad Gateway" "$r"
check_eq "one PR noted twice is read by its number once" 1 "$(grep -c '\[pr\] \[view\] \[39\]' "$FAKE/calls")"
check_eq "and flagged once" 1 "$(printf '%s\n' "$r" | grep -c 'PR #39 was noted done')"
has "with only the issue list failing, the PR list still checks a PR note" "o/q PR #5 Half, merged 3:40 AM ET" "$r"
lacks "and the PR is not repeated as unchecked" "PR #5: Half read (as noted, unchecked)" "$r"
has "the failed issue list is said, naming the read that failed (#926)" "Issues could not be read from GitHub for o/q: HTTP 500." "$r"
has "a done note naming no repo is kept, said as unchecked" "a repo not named: Tidied the scratch notes (as noted, unchecked: it names no repo GitHub can be asked about)" "$r"
has "a done note naming no PR or issue is kept, said as unchecked" "o/r: Answered a review (as noted, unchecked: it names no PR or issue)" "$r"
has "a repo whose two reads failed for different reasons is one line giving each reason (#926)" "PRs and issues could not be read from GitHub for o/s (PRs: HTTP 502: Bad Gateway; issues: HTTP 503: Service Unavailable)." "$r"
check_eq "and is said once, never once per read (#926)" 1 "$(printf '%s\n' "$r" | grep -c 'could not be read from GitHub for o/s')"
calls="$(cat "$FAKE/calls")"
has "gh is asked for merged PRs with an explicit limit" "[pr] [list] [-R] [o/r] [--state] [merged]" "$calls"
has "with the limit" "[--limit] [200]" "$calls"
has "searching from the moment sleep began" "[merged:>=2026-10-08T03:42:00Z]" "$calls"
has "and closed issues the same way" "[closed:>=2026-10-08T03:42:00Z]" "$calls"
check_eq "GitHub is asked about exactly the repos the notes name, no other" "o/q o/r o/s" \
  "$(printf '%s\n' "$calls" | grep '\[list\]' | sed -n 's/.*\[-R\] \[\([^]]*\)\].*/\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//')"
# Heartbeats and claims (L13, L98).
has "a worker silent past 30 minutes ended unexpectedly" "Session aaaa1111 ended unexpectedly: last heard 6:25 AM ET, 40 minutes before the end" "$r"
lacks "a worker heard 10 minutes before is fine" "Session bbbb2222 ended" "$r"
has "a worker that never wrote a note is flagged" "Session cccc3333 ended unexpectedly: it never wrote a note" "$r"
lacks "a worker that said it stopped is fine" "Session dddd4444 ended" "$r"
has "a claim with no done, parked or failed note ended unexpectedly" "o/r#20, claimed by bbbb2222 at 3:06 AM ET, ended unexpectedly" "$r"
lacks "a parked claim is not flagged" "o/r#21, claimed" "$r"
lacks "a failed claim is not flagged" "o/s#3, claimed" "$r"
has "parked work is listed with its branch" "Parked o/r#21 (branch fix-21): Two hours with no fix" "$r"
has "failed work is listed" "Failed o/s#3: Classifier refused the push" "$r"
has "a proposed issue is listed" "Cache misses on cold start" "$r"
has "a proposed issue carries its priority, labels and milestone, for the morning picker (#837)" "o/r: Cache misses on cold start (p2, perf, milestone Ungrouped). Seen while fixing 12" "$r"
has "a PR that is not a number is flagged" 'o/r PR "--web" was noted done, but that is not a PR number, so GitHub was not asked' "$r"
lacks "and never reaches gh" "[--web]" "$(cat "$FAKE/calls")"
has "a PR held as a list in an old note is flagged, never breaking the report" 'o/r PR "[1, 2]" was noted done, but that is not a PR number' "$r"
check_eq "a done note naming neither, in a repo whose issue list failed, is listed once" 1 "$(printf '%s\n' "$r" | grep -c 'Paired on a review')"
has "a refused question scope modes noted is listed with its folder (#841)" "/r/repo: Merge PR #31, the wording change?" "$r"
has "every question in it, not only the first" "/r/repo: Keep the old flag?" "$r"
has "a save held for Dan is listed (#841)" "Always ask first., to ~/.claude/CLAUDE.md" "$r"
has "each wait is noted" "Waited 5 minutes from 3:20 AM ET (rate_limit)" "$r"
has "every wait, not only the first" "Waited 10 minutes from 3:25 AM ET (server_error)" "$r"
has "a whole number of minutes written as a float reads as a whole number" "Waited 20 minutes from 3:30 AM ET (rate_limit)" "$r"
has "paid usage is summed over each session's latest reading" 'Paid usage: $3.50' "$r"
has "the 5 hour limit passed is said" "5 hour limit: reached 100% (aaaa1111 at 6:25 AM ET)" "$r"
has "a kind no section knows is still shown" "a kind nobody renders yet" "$r"
has "a line that cannot be read is counted, never dropped" "1 line of the notes could not be read" "$r"

# More results than the limit asked for is said, never read as all of them (L24).
python3 -c 'import json; print(json.dumps([{"number":i,"title":"t","url":"u","mergedAt":"2026-10-08T07:00:00Z"} for i in range(1000,1200)]))' > "$FAKE/gh-pr-o_r"
NOW=$WOKE py render --record "$SLEEPDIR/ended/g6.json" --final >/dev/null 2>&1
has "a full page of results is said as cut" "GitHub returned 200 merged PRs for o/r, the most asked for" "$(report_of g6)"

# An item whose time GitHub gave unreadably is said, never dropped (L215).
echo '[{"number":34,"title":"Split cache","url":"u","mergedAt":"2026-10-08T07:05:00Z"},{"number":37,"title":"Odd","url":"u","mergedAt":null}]' > "$FAKE/gh-pr-o_r"
NOW=$WOKE py render --record "$SLEEPDIR/ended/g6.json" --final >/dev/null 2>&1
has "a PR with no readable merge time is flagged" "o/r PR #37 came back from GitHub with no merge time that could be read (null)" "$(report_of g6)"

# Paid usage takes each session's latest reading by its time, not by where it sits in the file (L751).
record g9 '[]' "$SLEEPDIR/ended/g9.json"
{
  echo '{"v":1,"kind":"heartbeat","at":1791456900000,"by":"aaaa1111","usage":{"costUsd":4.00},"generation":"g9"}'
  echo '{"v":1,"kind":"heartbeat","at":1791455100000,"by":"aaaa1111","usage":{"costUsd":1.00},"generation":"g9"}'
} > "$SLEEPDIR/notes/g9.jsonl"
NOW=$WOKE py render --record "$SLEEPDIR/ended/g9.json" >/dev/null 2>&1
has "a reading written later but taken earlier never wins" 'Paid usage: $4.00' "$(report_of g9)"

# A render that fails in any way after the note is written still exits 0, so the note is not written twice.
printf '{"v":1,"generation":"g10","since":%s,"until":1,"night":"2026-10-07","bootTime":1,"report":"%s/Sleep report g10.md","startedBy":"not a record","workers":[],"placeBefore":"home"}' "$SINCE" "$DL" > "$SLEEPDIR/ended/g10.json"
out="$(py note --record "$SLEEPDIR/ended/g10.json" --line '{"kind":"finding","by":"aaaa1111","text":"render crashes"}' 2>&1)"; rc=$?
check_eq "a note whose render crashes still succeeds" 0 "$rc"
has "and the crash is said" "the note was written, but the report could not be rendered: AttributeError" "$out"
has "the note is there" "render crashes" "$(cat "$SLEEPDIR/notes/g10.jsonl")"
# A time no clock gives is refused before it is written, so it cannot break every later render.
out="$(py note --record "$SLEEPDIR/ended/g9.json" --line '{"kind":"wait","by":"aaaa1111","at":1e300,"minutes":5}' 2>&1)"; rc=$?
check_eq "a note with an impossible time is refused" 1 "$rc"
has "naming it" "the note's at must be ms since the epoch" "$out"

# Sourced from zsh, where BASH_SOURCE is empty, sleep_note uses the installed script, never one in
# the caller's folder.
if command -v zsh >/dev/null 2>&1; then
  mkdir -p "$WORK/hm/.claude/hooks/lib"; cp "$PY" "$WORK/hm/.claude/hooks/lib/sleep-report.py"
  printf 'import sys\nopen(sys.argv[0] + ".ran", "w").write("decoy")\n' > "$WORK/sleep-report.py"
  out="$(cd "$WORK" && HOME="$WORK/hm" SLEEP_REPORT_NOW_MS=$NOW_ASLEEP zsh -c '. "$1"; sleep_note "{\"kind\":\"finding\",\"by\":\"z\",\"text\":\"from zsh\"}" "$2" "$3" 1759800000' _ "$LIB" "$CUR" "$NOW_ASLEEP" 2>&1)"; rc=$?
  check_eq "sleep_note from zsh writes" 0 "$rc"
  has "and the note landed" "from zsh" "$(notes_of g5)"
  check_eq "a sleep-report.py in the caller's folder was never run" no "$([ -e "$WORK/sleep-report.py.ran" ] && echo yes || echo no)"
else
  echo "UNMEASURED: no zsh here, so sleep_note sourced from zsh is not exercised"
fi

# GitHub's reads together are bounded: past the bound each repo left is said as not read, never as nothing done.
: > "$FAKE/calls"
NOW=$WOKE SLEEP_REPORT_GH_TOTAL_S=0 py render --record "$SLEEPDIR/ended/g6.json" --final >/dev/null 2>&1
r="$(report_of g6)"
has "a repo past the bound is said as not read, naming both reads (#926)" "PRs and issues could not be read from GitHub for o/r: the report ran out of its 0 seconds for GitHub before reaching it." "$r"
check_eq "in one line per repository, never one per read (#926)" 1 "$(printf '%s\n' "$r" | grep -c 'could not be read from GitHub for o/r')"
check_eq "and gh was not asked at all" "" "$(cat "$FAKE/calls")"

# ---- paid usage with nothing to read, and the healthy night ----
record g7 '["aaaa1111"]' "$SLEEPDIR/ended/g7.json"
{
  echo '{"v":1,"kind":"heartbeat","at":1791456900000,"by":"aaaa1111","generation":"g7"}'
  echo '{"v":1,"kind":"stopped","at":1791457000000,"by":"aaaa1111","text":"done","generation":"g7"}'
  echo '{"v":1,"kind":"woke","at":'"$WOKE"',"by":"aaaa1111","generation":"g7"}'
} > "$SLEEPDIR/notes/g7.jsonl"
NOW=$WOKE py render --record "$SLEEPDIR/ended/g7.json" --final >/dev/null 2>&1
r="$(report_of g7)"
has "no reading at all is not measurable, said only then" "Paid usage: not measurable, since no session reported a cost reading" "$r"
has "a night with nothing wrong says so" "Nothing needs a look." "$r"
has "and a night with nothing done says so" "Nothing was merged or closed in a repo worked tonight." "$r"

# An ended record (by limit) says so in the header.
record g8 '[]' "$SLEEPDIR/ended/g8.json"
echo '{"v":1,"kind":"limit","at":1791475200000,"by":"aaaa1111","reason":"it was past noon ET","generation":"g8"}' > "$SLEEPDIR/notes/g8.jsonl"
NOW=1791475200000 py render --record "$SLEEPDIR/ended/g8.json" --final >/dev/null 2>&1
has "a sleep that ended by itself says when and why" "Ended by itself at 12:00 PM ET on Thu Oct 8: it was past noon ET." "$(report_of g8)"
# The overnight check (#834): what GitHub and the disk show happened overnight, and what it could
# not read, lead the report under Needs a look, never under Other notes.
echo '{"v":1,"kind":"outward","at":1791475100000,"by":"aaaa1111","text":"Issue created overnight: o/r#9 \"Filed\"","generation":"g8"}' >> "$SLEEPDIR/notes/g8.jsonl"
echo '{"v":1,"kind":"unmeasured","at":1791475100000,"by":"aaaa1111","text":"deploy runs in o/r were not checked (gh run list: HTTP 502)","generation":"g8"}' >> "$SLEEPDIR/notes/g8.jsonl"
NOW=1791475200000 py render --record "$SLEEPDIR/ended/g8.json" --final >/dev/null 2>&1
r="$(report_of g8)"
look="$(printf '%s\n' "$r" | sed -n '/^## Needs a look/,/^## /p')"
has "an overnight check hit is under Needs a look" "Done overnight, check it: Issue created overnight: o/r#9" "$look"
has "a read it could not make is under Needs a look too" "Not checked overnight: deploy runs in o/r were not checked" "$look"
lacks "neither is left for Other notes" "## Other notes" "$r"

# ---- where the writes landed ----
real_downloads_after="$(ls "$HOME/Downloads" 2>/dev/null | grep -c -E '^(sleep-report-|Sleep report )' || true)"
check_eq "the real Downloads gained no sleep report" "$real_downloads_before" "$real_downloads_after"
# Named "Sleep report <night>.md" (Dan, decision 4), a space in the name, so listed one a line.
check_eq "every report landed in the suite's own Downloads" "Sleep report g1.md|Sleep report g2.md|Sleep report g3.md|Sleep report g5.md|Sleep report g6.md|Sleep report g7.md|Sleep report g8.md|Sleep report g9.md" "$(ls "$DL" | tr '\n' '|' | sed 's/|$//')"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
