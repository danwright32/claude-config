#!/usr/bin/env bash
# Tests for the night's sleep report (claude-config#835): lib/sleep-report.py, which writes the
# report and the notes it is built from, and sleep_note in lib/sleep.sh, the one writer every phase
# hands its notes to.
#
# Nothing here may reach the real ~/Downloads: every record names a report under this suite's own
# folder (the record's `report` is the seam, as /sleep writes it from HOME), HOME is pointed there
# too, and the real Downloads is searched at the end for any file newer than the suite's start that
# carries the stamp every record here writes into its report, to prove it (L2, L322, L375). pmset and gh are
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

# The session this suite runs in must never stamp its own claude.ai link on the suite's notes (#1159):
# a case that wants one sets it.
unset CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_CODE_SESSION_ID

if ! . "$LIB"; then
  echo "FAIL: $LIB could not be sourced"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# The real Downloads, which nothing here may write into. It has other writers: Dan, and his own
# sleep mode, which renders the night's real report there on every note, so it is busiest while
# overnight sessions run this suite. Counting it before and after blamed this suite for theirs (a
# real report deleted mid run read as "expected 1, got 0", #1054, L375). So this suite's writes are
# identified positively instead: every record it makes carries STAMP, which the report prints in its
# header, and only a file there that is newer than the moment this suite began AND carries STAMP is
# one this suite put there.
REAL_DOWNLOADS="$HOME/Downloads"
STAMP="sleep-report-suite-$(basename "$WORK")"
: > "$WORK/began"

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
  # The folder carries STAMP, so every report rendered from this record names this run.
  printf '{"v":1,"generation":"%s","since":%s,"until":%s,"night":"2026-10-07","bootTime":1759800000,"report":"%s/Sleep report %s.md","startedBy":{"sessionId":"aaaa1111","cwd":"/r/repo/%s"},"workers":%s,"placeBefore":"home"}' \
    "$1" "$SINCE" "$((SINCE + 86400000))" "$DL" "$1" "$STAMP" "$2" > "$3"
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

# The writer stamps the claude.ai link of the session writing the note, so what that session's
# subagents merge, whose bodies carry the same link, is credited to it at wake (#1159). Only an id of
# a link's shape is stamped.
link_of_last(){ notes_of g5 | tail -1 | python3 -c 'import json,sys; print(json.load(sys.stdin).get("link"))'; }
CLAUDE_CODE_BRIDGE_SESSION_ID=session_01Writer note '{"kind":"finding","by":"aaaa1111","text":"stamped"}' >/dev/null 2>&1
check_eq "the writing session's link is stamped on its note" "session_01Writer" "$(link_of_last)"
CLAUDE_CODE_BRIDGE_SESSION_ID='session_01x; rm -rf /' note '{"kind":"finding","by":"aaaa1111","text":"odd id"}' >/dev/null 2>&1
check_eq "an id not of a link's shape is never stamped" "None" "$(link_of_last)"
note '{"kind":"finding","by":"aaaa1111","text":"no session"}' >/dev/null 2>&1
check_eq "outside a session nothing is stamped" "None" "$(link_of_last)"

# The writer stamps `by`, the local id of the session writing the note, when the caller gave none,
# as it stamps the link (#1167): on 2026-10-12 every finding, question and issue note the overnight
# session wrote lacked one, so the report said "a session that did not say" and could not count that
# worker as heard from. Only an id of a local id's shape is stamped, and a `by` the caller gave is
# never replaced.
by_of_last(){ notes_of g5 | tail -1 | python3 -c 'import json,sys; print(json.load(sys.stdin).get("by"))'; }
U0="cccc0000-0000-4000-8000-00000000c0de"
CLAUDE_CODE_SESSION_ID=$U0 note '{"kind":"finding","text":"no by given"}' >/dev/null 2>&1
check_eq "the writing session's id is stamped as by when the caller gave none" "$U0" "$(by_of_last)"
CLAUDE_CODE_SESSION_ID=$U0 note '{"kind":"finding","by":"aaaa1111","text":"by given"}' >/dev/null 2>&1
check_eq "a by the caller gave is never replaced" "aaaa1111" "$(by_of_last)"
CLAUDE_CODE_SESSION_ID='cccc0000; rm -rf /' note '{"kind":"finding","text":"odd local id"}' >/dev/null 2>&1
check_eq "an id not of a local id's shape is never stamped as by" "None" "$(by_of_last)"
note '{"kind":"finding","text":"no session id"}' >/dev/null 2>&1
check_eq "outside a session no by is stamped" "None" "$(by_of_last)"
check_eq "and the note is written all the same" "no session id" "$(notes_of g5 | tail -1 | python3 -c 'import json,sys; print(json.load(sys.stdin).get("text"))')"

# Twenty writers at once: every line lands whole (append mode, one write per note).
for i in $(seq 1 20); do note "{\"kind\":\"finding\",\"by\":\"w$i\",\"text\":\"finding $i\"}" >/dev/null 2>&1 & done
wait
check_eq "twenty notes at once all land" 29 "$(notes_of g5 | wc -l | tr -d ' ')"
check_eq "and every line is whole JSON" 29 "$(notes_of g5 | python3 -c 'import json,sys; print(sum(1 for l in sys.stdin if json.loads(l)))')"
r="$(report_of g5)"
missing=""; for i in $(seq 1 20); do [[ "$r" == *"finding $i"$'\n'* || "$r" == *"finding $i" ]] || missing="$missing $i"; done
check_eq "the report after them carries every finding (#909)" "" "$missing"
# #1279: a before bed question left unasked or unanswered says why, so the morning names it.
note '{"kind":"question","by":"aaaa1111","repo":"o/r","issue":14,"text":"Keep the old flag?","why":"not asked: the 10 minutes for bedtime questions ran out"}' >/dev/null 2>&1
has "#1279 a question left before bed says why" "o/r#14: Keep the old flag? (left before bed: not asked: the 10 minutes for bedtime questions ran out)" "$(report_of g5)"

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
  # The driver's circuit breaker ended o/r#22 as failed while a subagent finished it; once a
  # merged pull request closed it, the queue let the holder's done land over that end (#1119).
  echo '{"v":1,"kind":"claim","at":1791444800000,"by":"aaaa1111","repo":"o/r","issue":22,"generation":"g6"}'
  echo '{"v":1,"kind":"failed","at":1791444900000,"by":"aaaa1111","repo":"o/r","issue":22,"text":"circuit breaker: 22 minutes of active time with no new commit, claim or note","driver":true,"generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791445000000,"by":"aaaa1111","repo":"o/r","issue":22,"text":"closed by merged PR #40 after it was ended failed","replaces":"failed","pr":40,"generation":"g6"}'
  # A plain done after another session's failure is no replacement GitHub confirmed: the failure stands.
  echo '{"v":1,"kind":"failed","at":1791445100000,"by":"bbbb2222","repo":"o/r","issue":23,"text":"tests would not build","generation":"g6"}'
  echo '{"v":1,"kind":"done","at":1791445200000,"by":"aaaa1111","repo":"o/r","issue":23,"text":"finished it later","generation":"g6"}'
  # Noted done overnight, but merged only after wake (#1167).
  echo '{"v":1,"kind":"done","at":1791445300000,"by":"aaaa1111","repo":"o/r","pr":42,"text":"Merged in the morning","generation":"g6"}'
  echo '{"v":1,"kind":"woke","at":'"$WOKE"',"by":"eeee5555","generation":"g6"}'
} > "$N"
echo '[{"number":34,"title":"Split cache","url":"https://github.com/o/r/pull/34","mergedAt":"2026-10-08T07:05:00Z"},{"number":35,"title":"Nobody noted","url":"https://github.com/o/r/pull/35","mergedAt":"2026-10-08T08:00:00Z"},{"number":30,"title":"Before sleep","url":"https://github.com/o/r/pull/30","mergedAt":"2026-10-07T20:00:00Z"},{"number":41,"title":"After wake","url":"https://github.com/o/r/pull/41","mergedAt":"2026-10-08T12:32:00Z"}]' > "$FAKE/gh-pr-o_r"
echo '[{"number":12,"title":"Cache per account","url":"https://github.com/o/r/issues/12","closedAt":"2026-10-08T07:06:00Z","stateReason":"COMPLETED"},{"number":22,"title":"Finished by a subagent","url":"https://github.com/o/r/issues/22","closedAt":"2026-10-08T07:10:00Z","stateReason":"COMPLETED"},{"number":24,"title":"Closed in the daytime","url":"https://github.com/o/r/issues/24","closedAt":"2026-10-08T13:00:00Z","stateReason":"COMPLETED"}]' > "$FAKE/gh-issue-o_r"
echo '{"number":36,"title":"Not merged","mergedAt":null}' > "$FAKE/gh-pr-view-o_r-36"
echo '{"number":38,"title":"Lagging search","mergedAt":"2026-10-08T07:30:00Z"}' > "$FAKE/gh-pr-view-o_r-38"
echo 'HTTP 502: Bad Gateway' > "$FAKE/gh-pr-view-o_r-39.fail"
echo '{"number":42,"title":"Morning merge","mergedAt":"2026-10-08T12:40:00Z"}' > "$FAKE/gh-pr-view-o_r-42"
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
has "a PR merged with no note is flagged" "o/r PR #35 merged with no session accounting for it" "$r"
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
has "searching from the moment sleep began to the woke note's time (#1167)" "[merged:2026-10-08T03:42:00Z..2026-10-08T11:05:00Z]" "$calls"
has "and closed issues the same way" "[closed:2026-10-08T03:42:00Z..2026-10-08T11:05:00Z]" "$calls"
# Rendered after wake, the night's report never takes the daytime's work as its own (#1167): on
# 2026-10-12 a render at 3 PM ET listed PR #1127, merged 8:32 AM ET after wake, under Done. The
# stand in answers past the search, so the script's own predicate is what is tested (L1014).
lacks "a PR merged after wake is not the night's" "PR #41" "$r"
lacks "nor an issue closed after wake" "issue #24" "$r"
has "a PR noted done but merged only after wake is said as such" "o/r PR #42 was noted done, but GitHub shows it merged 8:40 AM ET, after the night ended at 7:05 AM ET" "$r"
lacks "and is never listed as done overnight" "PR #42 Morning merge" "$r"
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
has "an issue the breaker ended as failed and a merged PR then closed is done (#1119)" "o/r issue #22 Finished by a subagent" "$r"
lacks "and is never also listed as failed" "Failed o/r#22" "$r"
lacks "nor as ended unexpectedly" "o/r#22, claimed" "$r"
has "a failure a plain done followed, not the queue's confirmed replacement, is still listed (lessons review of 162acef)" "Failed o/r#23: tests would not build" "$r"
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

# ---- what a session's subagents merged and closed is credited to it (#1159) ----
# On 2026-10-12 the one overnight session's subagents merged 11 PRs and closed 21 issues, and every
# one was listed as "with no session noting it". A merge is the session's when its branch is that
# session's claim (sleep/N), when it closes an issue that session claimed, or when its body carries
# the session link of a session that wrote a note tonight; an issue is when a PR so credited, or one
# a note names, closed it. Only what no session can account for is listed.
U1="aaaa1111-0000-4000-8000-000000000001"
record g11 '["'"$U1"'"]' "$SLEEPDIR/ended/g11.json"
{
  echo '{"v":1,"kind":"start","at":'"$SINCE"',"by":"'"$U1"'","power":"on AC power","link":"session_01Night","generation":"g11"}'
  echo '{"v":1,"kind":"claim","at":1791442800000,"by":"'"$U1"'","repo":"o/r","issue":50,"link":"session_01Night","generation":"g11"}'
  echo '{"v":1,"kind":"claim","at":1791442900000,"by":"'"$U1"'","repo":"o/r","issue":51,"generation":"g11"}'
  echo '{"v":1,"kind":"done","at":1791443000000,"by":"'"$U1"'","repo":"o/r","issue":51,"pr":66,"text":"noted by the session","generation":"g11"}'
  echo '{"v":1,"kind":"done","at":1791443100000,"by":"'"$U1"'","repo":"o/r","issue":50,"text":"claimed and done","generation":"g11"}'
  echo '{"v":1,"kind":"finding","at":1791443200000,"link":"session_01Lone","text":"a session that gave no by","generation":"g11"}'
  echo '{"v":1,"kind":"stopped","at":1791457000000,"by":"'"$U1"'","text":"queue empty","generation":"g11"}'
  echo '{"v":1,"kind":"woke","at":'"$WOKE"',"by":"'"$U1"'","generation":"g11"}'
} > "$SLEEPDIR/notes/g11.jsonl"
# One merged PR as gh pr list gives it: number, title, minute past 3:00 AM ET, branch, body, the issues it closes.
pr(){ printf '{"number":%s,"title":"%s","url":"u","mergedAt":"2026-10-08T07:%s:00Z","headRefName":"%s","body":"%s","closingIssuesReferences":%s}' "$@"; }
ref(){ printf '{"number":%s,"repository":{"name":"%s","owner":{"login":"%s"}}}' "$1" "${2#*/}" "${2%%/*}"; }
{
  printf '['
  pr 60 "By a subagent" 10 "fix/60-thing" 'Plain words.\n\nhttps://claude.ai/code/session_01Night\n' '[]'; printf ,
  pr 61 "On the claim branch" 11 "sleep/50" 'No link here.' '[]'; printf ,
  pr 62 "Local session line" 12 "fix/62" "Claude-Session: local $U1" '[]'; printf ,
  pr 63 "Closes a claimed issue" 13 "fix/50-more" 'Closes #50' "[$(ref 50 o/r)]"; printf ,
  pr 64 "Another session" 14 "fix/64" 'https://claude.ai/code/session_01Stranger' '[]'; printf ,
  pr 65 "Nobody at all" 15 "fix/65" 'Nothing.' '[]'; printf ,
  pr 66 "Noted" 16 "fix/66" 'Nothing.' '[]'; printf ,
  pr 67 "Branch of no claim" 17 "sleep/99" 'Nothing.' '[]'; printf ,
  pr 68 "From a session known by its link" 18 "fix/68" 'https://claude.ai/code/session_01Lone' '[]'
  printf ']'
} > "$FAKE/gh-pr-o_r"
iss(){ printf '{"number":%s,"title":"%s","url":"u","closedAt":"2026-10-08T07:%s:00Z","stateReason":"COMPLETED","closedByPullRequestsReferences":%s}' "$@"; }
{
  printf '['
  iss 50 "The claimed issue" 19 "[$(ref 63 o/r)]"; printf ,
  iss 70 "Closed by the subagent PR" 20 "[$(ref 60 o/r)]"; printf ,
  iss 71 "Closed by the unaccounted PR" 21 "[$(ref 65 o/r)]"; printf ,
  iss 72 "Closed by hand" 22 '[]'; printf ,
  iss 73 "Closed by a PR from before sleep" 23 "[$(ref 9 o/r)]"; printf ,
  iss 74 "Closed by the noted PR" 24 "[$(ref 66 o/r)]"; printf ,
  iss 75 "Closed from another repository" 25 "[$(ref 4 o/other)]"
  printf ']'
} > "$FAKE/gh-issue-o_r"
: > "$FAKE/calls"
NOW=$WOKE py render --record "$SLEEPDIR/ended/g11.json" --final >/dev/null 2>&1
r="$(report_of g11)"
look="$(printf '%s\n' "$r" | sed -n '/^## Needs a look/,/^## /p')"
has "a subagent's PR is credited to the session by the link in its body" "o/r PR #60 By a subagent, merged 3:10 AM ET, under session aaaa1111 (the session link in its body)" "$r"
has "a PR on a claim's branch is credited to the claiming session" "o/r PR #61 On the claim branch, merged 3:11 AM ET, under session aaaa1111 (its branch sleep/50, that session's claim)" "$r"
has "a PR naming by its local id a session that wrote a note is credited to it" "o/r PR #62 Local session line, merged 3:12 AM ET, under session aaaa1111 (the session line in its body)" "$r"
has "a PR closing an issue a session claimed is credited to it" "o/r PR #63 Closes a claimed issue, merged 3:13 AM ET, under session aaaa1111 (it closes o/r#50, which that session claimed)" "$r"
has "a PR naming a session that wrote nothing tonight is still listed, saying which" "o/r PR #64 merged with no session accounting for it (its body names session_01Stranger, which wrote no note tonight)." "$look"
has "a PR nothing ties to a session is listed" "o/r PR #65 merged with no session accounting for it." "$look"
has "a claim branch of an issue nobody claimed credits nobody" "o/r PR #67 merged with no session accounting for it." "$look"
has "a session known only by the link on its notes is named by that link" "o/r PR #68 From a session known by its link, merged 3:18 AM ET, under session_01Lone (the session link in its body)" "$r"
has "a noted PR is done as before" "o/r PR #66 Noted, merged 3:16 AM ET" "$r"
lacks "with no session named on it" "PR #66 Noted, merged 3:16 AM ET, under" "$r"
has "an issue's done line says which PR closed it" "o/r issue #70 Closed by the subagent PR, closed 3:20 AM ET by PR #60" "$r"
has "an issue the unaccounted PR closed is listed, by that PR" "o/r issue #71 closed with no session accounting for it (by PR #65)." "$look"
has "an issue closed by hand is listed" "o/r issue #72 closed with no session accounting for it." "$look"
has "an issue a PR from before sleep closed is listed" "o/r issue #73 closed with no session accounting for it (by PR #9)." "$look"
has "an issue closed from another repository names it" "o/r issue #75 closed with no session accounting for it (by o/other PR #4)." "$look"
check_eq "exactly what no session accounts for is listed, nothing else" "64 65 67 71 72 73 75" \
  "$(printf '%s\n' "$look" | grep -E 'with no session' | sed -E 's/.* (PR|issue) #([0-9]+) (merged|closed) with no session.*/\2/' | tr '\n' ' ' | sed 's/ $//')"
calls="$(cat "$FAKE/calls")"
has "the merged PRs are asked for with their branch, body and the issues they close" "headRefName,body,closingIssuesReferences" "$calls"
has "the closed issues are asked for with the PRs that closed them" "closedByPullRequestsReferences" "$calls"

# ---- a worker whose notes named nobody is heard from all the same (#1167) ----
# The overnight session's own notes carry its id though the caller gave none, so the report counts
# the worker as heard from rather than saying it never wrote a note.
U2="bbbb2222-0000-4000-8000-000000000002"
record g12 '["'"$U2"'"]' "$SLEEPDIR/ended/g12.json"
CLAUDE_CODE_SESSION_ID=$U2 NOW=1791443000000 py note --record "$SLEEPDIR/ended/g12.json" --line '{"kind":"finding","repo":"o/t","text":"seen at 3:03"}' >/dev/null 2>&1
CLAUDE_CODE_SESSION_ID=$U2 NOW=1791457000000 py note --record "$SLEEPDIR/ended/g12.json" --line '{"kind":"stopped","text":"queue empty"}' >/dev/null 2>&1
echo '{"v":1,"kind":"woke","at":'"$WOKE"',"by":"eeee5555","generation":"g12"}' >> "$SLEEPDIR/notes/g12.jsonl"
NOW=$WOKE py render --record "$SLEEPDIR/ended/g12.json" --final >/dev/null 2>&1
r="$(report_of g12)"
has "a worker whose notes gave no by is heard from, by the id the writer stamped" "bbbb2222: last heard 6:56 AM ET" "$r"
lacks "and is never said to have written nothing" "Session bbbb2222 ended unexpectedly" "$r"

# ---- a final render with no woke or limit note (#1167) ----
# Wake writes its note and then renders; when the note could not be written the render still runs,
# and reads the night up to its own moment, never past the record's until (noon ET the day after,
# when the night ends by itself), so a render long after cannot take the day's work as the night's.
record g13 '[]' "$SLEEPDIR/ended/g13.json"
echo '{"v":1,"kind":"done","at":1791443000000,"by":"aaaa1111","repo":"o/u","pr":7,"text":"merged overnight","generation":"g13"}' > "$SLEEPDIR/notes/g13.jsonl"
echo '[{"number":7,"title":"Overnight","url":"u","mergedAt":"2026-10-08T07:00:00Z"},{"number":8,"title":"Past the bound","url":"u","mergedAt":"2026-10-09T04:00:00Z"}]' > "$FAKE/gh-pr-o_u"
: > "$FAKE/calls"
NOW=$WOKE py render --record "$SLEEPDIR/ended/g13.json" --final >/dev/null 2>&1
r="$(report_of g13)"
has "with no end note the search ends at the render's own moment" "[merged:2026-10-08T03:42:00Z..2026-10-08T11:05:00Z]" "$(cat "$FAKE/calls")"
has "and the header says the night was read up to then, with no end note" "No woke or limit note was written, so the night is read up to 7:05 AM ET on Thu Oct 8." "$r"
lacks "never as still asleep, waiting on a wake that has been" "Still asleep" "$r"
has "what merged within it is done" "o/u PR #7 Overnight" "$r"
: > "$FAKE/calls"
NOW=$((SINCE + 86400000 + 4 * 3600000)) py render --record "$SLEEPDIR/ended/g13.json" --final >/dev/null 2>&1
r="$(report_of g13)"
has "rendered past the record's until, the search ends at the until" "[merged:2026-10-08T03:42:00Z..2026-10-09T03:42:00Z]" "$(cat "$FAKE/calls")"
lacks "and what merged after it is not the night's" "PR #8" "$r"
has "the header names that bound" "the night is read up to 11:42 PM ET on Thu Oct 8." "$r"

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

# ---- each worker's goal (#1242) ----
# Sleep mode works only a goal Dan set, kept per worker in the record's goals. A worker left without
# one does no work, so the report says so once, in its header, and never calls its silence a session
# that ended unexpectedly. A goal that names no issue is worked as a task whose steps the session
# notes as progress, listed in a section of their own.
record g14 '["aaaa1111","bbbb2222","cccc3333"]' "$SLEEPDIR/ended/g14.json"
python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["goals"] = {"aaaa1111": "Close #12", "bbbb2222": "Tidy the parser"}; json.dump(d, open(p, "w"))' "$SLEEPDIR/ended/g14.json"
{
  echo '{"v":1,"kind":"start","at":'"$SINCE"',"by":"aaaa1111","power":"on AC power","generation":"g14"}'
  echo '{"v":1,"kind":"heartbeat","at":1791455100000,"by":"aaaa1111","generation":"g14"}'
  echo '{"v":1,"kind":"progress","at":1791455200000,"by":"bbbb2222","text":"Split the parser into two files","generation":"g14"}'
  echo '{"v":1,"kind":"stopped","at":1791455300000,"by":"bbbb2222","text":"the parser is tidy","generation":"g14"}'
  echo '{"v":1,"kind":"woke","at":'"$WOKE"',"by":"eeee5555","generation":"g14"}'
} > "$SLEEPDIR/notes/g14.jsonl"
NOW=$WOKE py render --record "$SLEEPDIR/ended/g14.json" --final >/dev/null 2>&1
r="$(report_of g14)"
has "a worker with no goal is said, once, in the header" "No goal was set for 1 session (cccc3333), so it did no work tonight." "$r"
check_eq "and only once" 1 "$(printf '%s\n' "$r" | grep -c 'cccc3333), so it did no work')"
lacks "and its silence is never read as ending unexpectedly" "Session cccc3333 ended unexpectedly" "$r"
has "a worker with a goal is still judged by its silence" "Session aaaa1111 ended unexpectedly" "$r"
has "each worker's goal is in its row" 'aaaa1111: goal "Close #12", last heard' "$r"
has "the goal of the other too" 'bbbb2222: goal "Tidy the parser", last heard' "$r"
has "a step toward a goal is listed under its own heading" "## Progress toward goals" "$r"
has "with the session that noted it" "bbbb2222: Split the parser into two files" "$r"
lacks "never under Other notes" "progress from bbbb2222" "$r"
# A record from before goals were kept says nothing about goals at all.
lacks "an older record without goals names no worker as without one" "No goal was set" "$(report_of g6)"

# ---- where the writes landed ----
# The stamp is proved present in what this suite wrote before its absence from the real Downloads is
# read as evidence (L375): a stamp that had stopped reaching the report would pass the check below.
check_eq "every report this suite wrote carries its stamp" 12 "$(grep -l -F -- "$STAMP" "$DL"/* 2>/dev/null | wc -l | tr -d ' ')"
leaked="$(find "$REAL_DOWNLOADS" -maxdepth 1 -type f -newer "$WORK/began" -size -1024k -exec grep -l -F -- "$STAMP" {} + 2>/dev/null)"
check_eq "the real Downloads gained nothing this suite wrote" "" "$leaked"
# Named "Sleep report <night>.md" (Dan, decision 4), a space in the name, so listed one a line.
check_eq "every report landed in the suite's own Downloads" "Sleep report g1.md|Sleep report g11.md|Sleep report g12.md|Sleep report g13.md|Sleep report g14.md|Sleep report g2.md|Sleep report g3.md|Sleep report g5.md|Sleep report g6.md|Sleep report g7.md|Sleep report g8.md|Sleep report g9.md" "$(ls "$DL" | tr '\n' '|' | sed 's/|$//')"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
