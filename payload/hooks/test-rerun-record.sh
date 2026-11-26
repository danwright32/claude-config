#!/usr/bin/env bash
# Hand reruns of a failed check are recorded and a repeat flake is offered (claude-config#3613).
#
# rerun-record.sh (with rerun_record.py) is a PostToolUse hook on Bash that records each `gh run
# rerun` in the issue spool's reruns folder; issue-spool.sh resolve-reruns, run by the end of turn
# review (feature-issue-review.sh), reads each run's final result from GitHub and spools a finding for
# a job that failed and then went green on a rerun for the second time, and for one that failed again.
# Every payload here is built by hand and every gh answer is a recorded fixture served by a stub: no
# real run is read or rerun.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="${RERUN_HOOKS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
HOOK="$DIR/rerun-record.sh"
LIB="$DIR/lib/issue-spool.sh"
REVIEW="$DIR/feature-issue-review.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-rerun-record.XXXXXX")" || exit 2
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export CLAUDE_ISSUE_SPOOL_DIR="$WORK/spool"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
export CLAUDE_TRANSCRIPT_ROOT="$WORK/projects"
export CLAUDE_AREA_CHECK_DIR="$WORK/area"; mkdir -p "$CLAUDE_AREA_CHECK_DIR"
printf '%s' "$(( $(date +%s) * 1000 ))" > "$CLAUDE_AREA_CHECK_DIR/weekly-line.stamp"
export CLAUDE_SLEEP_RECORD="$WORK/sleep-none.json"
unset CLAUDE_CODE_SESSION_ID GH_REPO

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# A project folder, a git repository whose origin is on GitHub, and a session transcript in it.
PROJ="$WORK/proj"; mkdir -p "$PROJ"
git -C "$PROJ" init -q 2>/dev/null
git -C "$PROJ" remote add origin git@github.com:own/rep.git
mkdir -p "$CLAUDE_TRANSCRIPT_ROOT/p"
TR="$CLAUDE_TRANSCRIPT_ROOT/p/sess-a.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the thing"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","id":"t1","input":{}}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
} > "$TR"

KEY="$(bash "$LIB" key "$PROJ" "$TR" 2>/dev/null)"
RDIR="$(bash "$LIB" reruns-dir 2>/dev/null)"
WAIT="$RDIR/$KEY.jsonl"
FLAKES="$RDIR/flakes.jsonl"

payload() { # payload <command> [cwd] [exit code] -> a PostToolUse payload for one Bash call
  python3 -c '
import json, sys
resp = {"stdout": "", "stderr": ""}
if sys.argv[3]:
    resp["exit_code"] = int(sys.argv[3])
print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash", "session_id": "sess-a",
                  "transcript_path": sys.argv[4], "cwd": sys.argv[2],
                  "tool_input": {"command": sys.argv[1], "description": "x"}, "tool_response": resp}))' \
    "$1" "${2:-$PROJ}" "${3:-}" "$TR"
}
run_hook() { # run_hook <command> [cwd] [exit code] -> sets OUT, ERR, RC
  payload "$@" > "$WORK/payload.json"
  OUT="$(bash "$HOOK" < "$WORK/payload.json" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
# grep -c prints 0 AND fails on an empty file, so a fallback after it would print a second 0.
lines() { if [ -f "$1" ]; then grep -c . "$1" 2>/dev/null; true; else echo 0; fi; }
last_field() { # last_field <field> -> that field of the last waiting record
  [ -f "$WAIT" ] || { echo "<no waiting file>"; return; }
  tail -n 1 "$WAIT" | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$1"
}
expect_record() { # expect_record <case> <command> <repo> <run> <job> [cwd]
  rm -f "$WAIT"
  run_hook "$2" "${6:-$PROJ}"
  local n; n="$(lines "$WAIT")"
  if [ "$n" = 1 ] && [ "$(last_field repo)" = "$3" ] && [ "$(last_field run)" = "$4" ] && [ "$(last_field job)" = "$5" ] \
     && [ -z "$OUT" ] && [ "$RC" = 0 ]; then
    check "$1" ok
  else
    check "$1" "records=$n repo=[$(last_field repo)] run=[$(last_field run)] job=[$(last_field job)] rc=$RC out=[$OUT] err=[$ERR]"
  fi
}
expect_none() { # expect_none <case> <command> [cwd] [exit code]
  rm -f "$WAIT"
  run_hook "$2" "${3:-$PROJ}" "${4:-}"
  local n; n="$(lines "$WAIT")"
  if [ "$n" = 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && [ "$RC" = 0 ]; then check "$1" ok
  else check "$1" "records=$n rc=$RC out=[$OUT] err=[$ERR]"; fi
}

# ---------------------------------------------------------------------------
# 1. The recorder: every form of a hand rerun leaves one record (R1), nothing else does.
# ---------------------------------------------------------------------------
[ -f "$HOOK" ] || check "rerun-record.sh exists beside the other hooks" "no file at $HOOK"
expect_record "a rerun with a run id and --repo is recorded" "gh run rerun 123 --repo own/rep" own/rep 123 ""
expect_record "a rerun with --failed and -R is recorded" "gh run rerun 124 --failed -R other/x" other/x 124 ""
expect_record "a rerun named by --job is recorded with its job" "gh run rerun --job 900 -R own/rep" own/rep "" 900
expect_record "a rerun behind rtk is recorded" "rtk gh run rerun 125 --failed -R own/rep" own/rep 125 ""
expect_record "a rerun joined to other commands is recorded" "git status && gh run rerun 126 --failed -R own/rep; echo done" own/rep 126 ""
expect_record "a rerun with no repository flag takes the repository from the git remote" "gh run rerun 127 --failed" own/rep 127 ""
expect_record "a rerun with GH_REPO set on it takes that repository" "GH_REPO=env/repo gh run rerun 128" env/repo 128 ""
expect_record "-R written against its value is read" "gh run rerun 129 -Rjoined/repo" joined/repo 129 ""
expect_none "an ordinary command records nothing and says nothing" "git status"
expect_none "a quoted mention of a rerun records nothing" "echo \"gh run rerun 999 -R own/rep\""
expect_none "a rerun asking for help records nothing" "gh run rerun 5 -R own/rep --help"
expect_none "a command the reader cannot read records nothing and says nothing" "gh run rerun 7 -R own/rep \"unclosed"
expect_none "a rerun that failed records nothing" "gh run rerun 8 -R own/rep" "$PROJ" 1
expect_none "a rerun with no run and no job records nothing" "gh run rerun -R own/rep --failed"
expect_none "a rerun whose repository cannot be told records nothing" "gh run rerun 9 --failed" "$WORK"

# Two reruns in one command, two records.
rm -f "$WAIT"; run_hook "gh run rerun 130 -R own/rep && gh run rerun 131 -R own/rep"
n="$(lines "$WAIT")"
[ "$n" = 2 ] && check "two reruns in one command leave two records" ok || check "two reruns in one command leave two records" "records=$n"

# A record that cannot be written is said, on stderr and to Dan (fail loud).
rm -rf "$RDIR"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"; : > "$RDIR"
run_hook "gh run rerun 140 -R own/rep"
case "$ERR" in *"HAND RERUN NOT RECORDED"*140*) e=ok ;; *) e="stderr=[$ERR]" ;; esac
check "a record the hook cannot write is said on stderr" "$e"
case "$OUT" in *systemMessage*"HAND RERUN NOT RECORDED"*) e=ok ;; *) e="stdout=[$OUT]" ;; esac
check "a record the hook cannot write is said to Dan as a systemMessage" "$e"
[ "$RC" = 0 ] && check "the recorder never blocks: exit 0 when the write fails" ok || check "the recorder never blocks: exit 0 when the write fails" "rc=$RC"
rm -f "$RDIR"

# A test run may not write into the real spool.
out="$(env CLAUDE_ISSUE_SPOOL_DIR= CLAUDE_SUITE_RUN_ID=rerun-suite bash "$LIB" rerun "$PROJ" own/rep 1 "" "$TR" 2>&1)"; rc=$?
[ "$rc" = 3 ] && check "rerun refuses the real spool under a test run" ok || check "rerun refuses the real spool under a test run" "rc=$rc out=[$out]"

# ---------------------------------------------------------------------------
# 2. The resolver, against recorded gh answers served by a stub.
# ---------------------------------------------------------------------------
FIX="$WORK/fix"; mkdir -p "$FIX" "$WORK/bin"
export GH_LOG="$WORK/gh.log" FIX
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
for a in "$@"; do
  case "$a" in
    repos/*/actions/runs/*/jobs*) id="${a#*/actions/runs/}"; id="run-${id%%/*}" ;;
    repos/*/actions/jobs/*) id="job-${a##*/}" ;;
  esac
done
[ -f "$FIX/$id.sleep" ] && sleep "$(cat "$FIX/$id.sleep")"
if [ -f "$FIX/$id.rc" ]; then echo "HTTP 404: Not Found" >&2; exit "$(cat "$FIX/$id.rc")"; fi
cat "$FIX/$id.out"
STUB
chmod +x "$WORK/bin/gh"
export CLAUDE_RERUN_GH="$WORK/bin/gh"

job() { # job <name> <attempt> <status> <conclusion>
  printf '{"name":"%s","workflow_name":"ci","run_attempt":%s,"status":"%s","conclusion":%s,"head_sha":"abc"}\n' \
    "$1" "$2" "$3" "$( [ "$4" = null ] && echo null || printf '"%s"' "$4")"
}
{ job test 1 completed failure; job lint 1 completed success; job test 2 completed success; } > "$FIX/run-101.out"
{ job test 1 completed failure; job test 2 completed success; job lint 2 completed success; } > "$FIX/run-102.out"
{ job test 1 completed failure; job test 2 completed failure; } > "$FIX/run-103.out"
{ job test 1 completed failure; job test 2 in_progress null; } > "$FIX/run-104.out"
{ job test 1 completed failure; job build 1 completed failure; job test 2 completed success; job build 2 completed failure; } > "$FIX/run-105.out"
echo 1 > "$FIX/run-106.rc"
{ job test 1 completed failure; job test 2 completed success; } > "$FIX/run-107.out"; echo 30 > "$FIX/run-107.sleep"
echo '{"id":900,"run_id":108}' > "$FIX/job-900.out"
{ job e2e 1 completed failure; job e2e 2 completed success; } > "$FIX/run-108.out"
{ job test 1 completed failure; } > "$FIX/run-109.out"
{ job e2e 1 completed failure; job e2e 2 completed success; } > "$FIX/run-110.out"

reset_spool() { rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"; : > "$GH_LOG"; }
record() { bash "$LIB" rerun "$PROJ" own/rep "$1" "${2:-}" "$TR"; }
resolve() { RES_ERR="$(bash "$LIB" resolve-reruns "$PROJ" "$TR" 2>&1 >/dev/null)"; RES_RC=$?; }
pending_text() { bash "$LIB" pending "$PROJ" "$TR" 2>/dev/null; }
waiting_runs() { [ -f "$WAIT" ] && python3 -c 'import json,sys; print(" ".join(sorted(str(json.loads(l).get("run")) for l in open(sys.argv[1]) if l.strip())))' "$WAIT"; }

# R2: a run still in progress is kept, and nothing is offered.
reset_spool; record 104; resolve
[ "$(waiting_runs)" = 104 ] && check "a run still in progress waits for the next review (R2)" ok || check "a run still in progress waits for the next review (R2)" "waiting=[$(waiting_runs)] err=[$RES_ERR]"
if bash "$LIB" has-findings "$PROJ" "$TR" >/dev/null 2>&1; then check "a run still in progress offers nothing (R2)" "has-findings said a finding is pending"; else check "a run still in progress offers nothing (R2)" ok; fi
[ "$(lines "$FLAKES")" = 0 ] && check "a run still in progress counts no flake" ok || check "a run still in progress counts no flake" "flakes=$(lines "$FLAKES")"

# The first flake of a job is counted, not offered; the second is offered.
reset_spool; record 101; resolve
[ "$(lines "$FLAKES")" = 1 ] && check "a job that failed then passed on a rerun is counted once" ok || check "a job that failed then passed on a rerun is counted once" "flakes=$(lines "$FLAKES") err=[$RES_ERR]"
[ ! -s "$WAIT" ] && check "a resolved rerun stops waiting" ok || check "a resolved rerun stops waiting" "waiting=[$(waiting_runs)]"
if bash "$LIB" has-findings "$PROJ" "$TR" >/dev/null 2>&1; then check "the first flake of a job is not offered" "a finding is pending"; else check "the first flake of a job is not offered" ok; fi
grep -q '"job": "lint"' "$FLAKES" && check "a job that passed first time is no flake" "lint was counted" || check "a job that passed first time is no flake" ok
record 102; record 102; resolve
p="$(pending_text)"
case "$p" in *"'test' (workflow 'ci') in own/rep failed and then passed on a hand rerun for the 2nd time (runs 101, 102)"*) e=ok ;; *) e="pending=[$p] err=[$RES_ERR]" ;; esac
check "the second flake of a job is offered, naming both runs" "$e"
[ "$(lines "$FLAKES")" = 2 ] && check "a run recorded twice counts once" ok || check "a run recorded twice counts once" "flakes=$(lines "$FLAKES")"
[ "$(grep -o 'runs 101, 102' <<<"$p" | grep -c .)" = 1 ] && check "a run recorded twice is offered once" ok || check "a run recorded twice is offered once" "pending=[$p]"
grep -q '"session": "sess-a"' "$CLAUDE_ISSUE_SPOOL_DIR/$KEY.jsonl" && check "the finding belongs to the session that reran" ok || check "the finding belongs to the session that reran" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$KEY.jsonl")"

# The record of earlier flakes survives the spool's clear (between sessions).
bash "$LIB" clear "$PROJ" "$TR" >/dev/null 2>&1
[ "$(lines "$FLAKES")" = 2 ] && check "the flake history survives a clear of the pending findings" ok || check "the flake history survives a clear of the pending findings" "flakes=$(lines "$FLAKES")"

# A job that failed again on its rerun is shown as that.
reset_spool; record 103; resolve
p="$(pending_text)"
case "$p" in *"'test' (workflow 'ci') in own/rep failed again on its hand rerun (run 103, attempt 2)"*) e=ok ;; *) e="pending=[$p] err=[$RES_ERR]" ;; esac
check "a job that failed again on its rerun is shown as that" "$e"

# A run that never ended green is not a flake.
reset_spool; record 101; resolve; record 105; resolve
p="$(pending_text)"
case "$p" in *"'build'"*"failed again"*) e=ok ;; *) e="pending=[$p]" ;; esac
check "in a run that never ended green, the job that failed again is shown" "$e"
case "$p" in *"for the 2nd time"*) e="a flake was offered from a run that never ended green: [$p]" ;; *) e=ok ;; esac
check "a run that never ended green is not a flake and is not offered" "$e"
[ "$(lines "$FLAKES")" = 1 ] && check "a run that never ended green counts no flake" ok || check "a run that never ended green counts no flake" "flakes=$(lines "$FLAKES")"

# A run that cannot be read is kept and not offered; one that does not answer in time is kept too.
reset_spool; record 106; resolve
[ "$(waiting_runs)" = 106 ] && check "a run whose result cannot be read waits for the next review" ok || check "a run whose result cannot be read waits for the next review" "waiting=[$(waiting_runs)]"
grep -q 'HTTP 404' "$WAIT" && check "a run that cannot be read keeps the reason" ok || check "a run that cannot be read keeps the reason" "$(cat "$WAIT")"
reset_spool; record 107
t0=$(date +%s); CLAUDE_RERUN_RESOLVE_BUDGET=2 CLAUDE_RERUN_CALL_TIMEOUT=1 resolve; t1=$(date +%s)
[ $((t1 - t0)) -le 6 ] && check "a gh call that does not answer is stopped at its time limit" ok || check "a gh call that does not answer is stopped at its time limit" "took $((t1 - t0))s"
[ "$(waiting_runs)" = 107 ] && check "a run that did not answer in time waits for the next review" ok || check "a run that did not answer in time waits for the next review" "waiting=[$(waiting_runs)]"

# A run with only its first attempt has not shown the rerun yet.
reset_spool; record 109; resolve
[ "$(waiting_runs)" = 109 ] && check "a run showing only its first attempt waits" ok || check "a run showing only its first attempt waits" "waiting=[$(waiting_runs)]"

# A rerun named by its job learns its run once, then is judged by it.
reset_spool; record "" 900; resolve
[ "$(lines "$FLAKES")" = 1 ] && grep -q '"run": "108"' "$FLAKES" && check "a rerun named by its job is resolved through its run" ok || check "a rerun named by its job is resolved through its run" "flakes=[$(cat "$FLAKES" 2>/dev/null)] err=[$RES_ERR] gh=[$(cat "$GH_LOG")]"
record 110; resolve
case "$(pending_text)" in *"'e2e'"*"2nd time (runs 108, 110)"*) e=ok ;; *) e="pending=[$(pending_text)]" ;; esac
check "a job rerun by --job and then by run id counts both" "$e"

# One gh call per run, and none when nothing waits.
reset_spool; record 101; record 101; resolve
[ "$(lines "$GH_LOG")" = 1 ] && check "one gh call per recorded run" ok || check "one gh call per recorded run" "calls=$(lines "$GH_LOG")"
: > "$GH_LOG"; resolve
[ "$(lines "$GH_LOG")" = 0 ] && [ "$RES_RC" = 0 ] && check "nothing waiting, no gh call" ok || check "nothing waiting, no gh call" "calls=$(lines "$GH_LOG") rc=$RES_RC"

# A finding that cannot be written puts the reruns back and is said.
reset_spool; record 102; record 101; chmod 500 "$CLAUDE_ISSUE_SPOOL_DIR"
: > "$FLAKES" 2>/dev/null; resolve
chmod 700 "$CLAUDE_ISSUE_SPOOL_DIR"
case "$RES_ERR" in *"could not"*) e=ok ;; *) e="rc=$RES_RC err=[$RES_ERR]" ;; esac
check "a resolver that cannot write says so" "$e"

# ---------------------------------------------------------------------------
# 3. The end of turn review: asleep it reads nothing and the records wait; awake it resolves them.
# ---------------------------------------------------------------------------
BOOT="$( . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sleep.sh" && sleep_boot_of "$(sysctl -n kern.boottime 2>/dev/null)" )"
NOW_MS="$(( $(date +%s) * 1000 ))"
printf '{"v":1,"generation":"g-test","since":%s,"until":%s,"night":"2026-10-07","bootTime":%s,"report":"%s/r.md","startedBy":{"sessionId":"s0","cwd":"/"},"workers":[],"placeBefore":"home"}\n' \
  "$((NOW_MS - 60000))" "$((NOW_MS + 3600000))" "$BOOT" "$WORK" > "$WORK/sleep-asleep.json"
review() { printf '{"transcript_path":"%s","stop_hook_active":false}' "$TR" | CLAUDE_PROJECT_DIR="$PROJ" bash "$REVIEW" 2>/dev/null; }

reset_spool; record 101; record 102
before="$(cat "$WAIT")"
out="$(CLAUDE_SLEEP_RECORD="$WORK/sleep-asleep.json" review)"
[ -z "$out" ] && [ "$(cat "$WAIT")" = "$before" ] && [ "$(lines "$GH_LOG")" = 0 ] \
  && check "asleep, the review reads no rerun, offers nothing, and every record waits" ok \
  || check "asleep, the review reads no rerun, offers nothing, and every record waits" "out=[$out] gh calls=$(lines "$GH_LOG")"
out="$(review)"
case "$out" in *'"decision"'*) e=ok ;; *) e="the review did not speak: [$out]" ;; esac
check "awake, the review speaks with the resolved flake pending" "$e"
[ ! -s "$WAIT" ] && [ "$(lines "$GH_LOG")" = 2 ] && check "awake, the review reads each waiting run once" ok || check "awake, the review reads each waiting run once" "waiting=[$(waiting_runs)] calls=$(lines "$GH_LOG")"
case "$(pending_text)" in *"2nd time (runs 101, 102)"*) e=ok ;; *) e="pending=[$(pending_text)]" ;; esac
check "awake, the repeat flake is in the spool the picker is built from" "$e"

# ---------------------------------------------------------------------------
# 4. Retention (Dan, 2026-11-26): a rerun unreadable for 7 days is dropped with one line saying so,
#    and the flake history keeps 90 days. Time is SET with CLAUDE_RERUN_NOW, never waited for.
# ---------------------------------------------------------------------------
DAY=86400
T0=1790000000
resolve_at() { # resolve_at <epoch> -> sets RES_OUT (what the review is told), RES_ERR, RES_RC
  RES_OUT="$(CLAUDE_RERUN_NOW="$1" bash "$LIB" resolve-reruns "$PROJ" "$TR" 2>"$WORK/res-err")"; RES_RC=$?
  RES_ERR="$(cat "$WORK/res-err")"
}
record_at() { CLAUDE_RERUN_NOW="$1" bash "$LIB" rerun "$PROJ" own/rep "$2" "" "$TR"; }
flake_line() { # flake_line <epoch or empty> <run> -> a history line for job test in workflow ci
  python3 -c '
import json, sys, datetime
r = {"repo": "own/rep", "run": sys.argv[2], "workflow": "ci", "job": "test", "sha": "old"}
if sys.argv[1]:
    r["ts"] = datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps(r))' "$1" "$2"
}

# An unreadable rerun is kept for 6 days and dropped at 7, counted from when it was first recorded.
reset_spool; record_at "$T0" 106
resolve_at "$((T0 + 6 * DAY))"
[ "$(waiting_runs)" = 106 ] && [ -z "$RES_OUT" ] && check "an unreadable rerun 6 days old still waits" ok \
  || check "an unreadable rerun 6 days old still waits" "waiting=[$(waiting_runs)] out=[$RES_OUT] err=[$RES_ERR]"
resolve_at "$((T0 + 7 * DAY))"
[ ! -s "$WAIT" ] && check "an unreadable rerun 7 days old is dropped" ok || check "an unreadable rerun 7 days old is dropped" "waiting=[$(waiting_runs)] err=[$RES_ERR]"
case "$RES_OUT" in *own/rep*"run 106"*"dropped unread after 7 days"*) e=ok ;; *) e="out=[$RES_OUT] err=[$RES_ERR]" ;; esac
check "the drop is said in one line naming the repository and the run" "$e"
[ "$(printf '%s\n' "$RES_OUT" | grep -c .)" = 1 ] && check "one dropped run is one line" ok || check "one dropped run is one line" "out=[$RES_OUT]"

# Counted from the FIRST record of the run, not the newest.
reset_spool; record_at "$T0" 106; record_at "$((T0 + 5 * DAY))" 106
resolve_at "$((T0 + 7 * DAY))"
[ ! -s "$WAIT" ] && case "$RES_OUT" in *"run 106"*) true ;; *) false ;; esac \
  && check "the 7 days count from the first time the run was recorded" ok \
  || check "the 7 days count from the first time the run was recorded" "waiting=[$(waiting_runs)] out=[$RES_OUT]"

# A record with no usable time is never aged: kept, and said.
reset_spool; mkdir -p "$RDIR"
printf '{"repo": "own/rep", "run": "106", "job": null, "cwd": "%s", "session": "sess-a"}\n' "$PROJ" > "$WAIT"
resolve_at "$((T0 + 400 * DAY))"
[ "$(waiting_runs)" = 106 ] && [ -z "$RES_OUT" ] && check "an unreadable rerun with no date is kept" ok \
  || check "an unreadable rerun with no date is kept" "waiting=[$(waiting_runs)] out=[$RES_OUT]"
case "$RES_ERR" in *own/rep*"run 106"*"no readable date"*) e=ok ;; *) e="err=[$RES_ERR]" ;; esac
check "an unreadable rerun with no date says it has none" "$e"
reset_spool; mkdir -p "$RDIR"
printf '{"ts": "last tuesday", "repo": "own/rep", "run": "106", "cwd": "%s"}\n' "$PROJ" > "$WAIT"
resolve_at "$((T0 + 400 * DAY))"
[ "$(waiting_runs)" = 106 ] && case "$RES_ERR" in *"no readable date"*) true ;; *) false ;; esac \
  && check "an unreadable rerun whose date cannot be read is kept and said" ok \
  || check "an unreadable rerun whose date cannot be read is kept and said" "waiting=[$(waiting_runs)] out=[$RES_OUT] err=[$RES_ERR]"

# A rerun the review had no time to read this turn is not dropped unread.
reset_spool; record_at "$T0" 106
RES_OUT="$(CLAUDE_RERUN_RESOLVE_BUDGET=0.1 CLAUDE_RERUN_NOW="$((T0 + 30 * DAY))" bash "$LIB" resolve-reruns "$PROJ" "$TR" 2>/dev/null)"
[ "$(waiting_runs)" = 106 ] && [ -z "$RES_OUT" ] && [ "$(lines "$GH_LOG")" = 0 ] \
  && check "a rerun not read this turn for lack of time is not dropped" ok \
  || check "a rerun not read this turn for lack of time is not dropped" "waiting=[$(waiting_runs)] out=[$RES_OUT] calls=$(lines "$GH_LOG")"

# A rerun whose run CAN be read is judged, however old.
reset_spool; record_at "$T0" 101
resolve_at "$((T0 + 30 * DAY))"
[ "$(lines "$FLAKES")" = 1 ] && [ -z "$RES_OUT" ] && check "a readable rerun 30 days old is judged, not dropped" ok \
  || check "a readable rerun 30 days old is judged, not dropped" "flakes=$(lines "$FLAKES") out=[$RES_OUT]"

# The setting, and a setting that is not a whole number above zero.
reset_spool; record_at "$T0" 106
RES_OUT="$(CLAUDE_RERUN_UNREAD_KEEP_DAYS=2 CLAUDE_RERUN_NOW="$((T0 + 2 * DAY))" bash "$LIB" resolve-reruns "$PROJ" "$TR" 2>/dev/null)"
case "$RES_OUT" in *"run 106"*"dropped unread after 2 days"*) e=ok ;; *) e="out=[$RES_OUT] waiting=[$(waiting_runs)]" ;; esac
check "CLAUDE_RERUN_UNREAD_KEEP_DAYS sets the days" "$e"
for bad in 0 -3 abc 1.5 000; do
  reset_spool; record_at "$T0" 106
  RES_OUT="$(CLAUDE_RERUN_UNREAD_KEEP_DAYS="$bad" CLAUDE_RERUN_NOW="$((T0 + 1 * DAY))" bash "$LIB" resolve-reruns "$PROJ" "$TR" 2>"$WORK/res-err")"
  RES_ERR="$(cat "$WORK/res-err")"
  [ "$(waiting_runs)" = 106 ] && [ -z "$RES_OUT" ] && case "$RES_ERR" in *CLAUDE_RERUN_UNREAD_KEEP_DAYS*"default of 7 days"*) true ;; *) false ;; esac \
    && check "CLAUDE_RERUN_UNREAD_KEEP_DAYS=$bad falls back to 7 days and says so" ok \
    || check "CLAUDE_RERUN_UNREAD_KEEP_DAYS=$bad falls back to 7 days and says so" "waiting=[$(waiting_runs)] out=[$RES_OUT] err=[$RES_ERR]"
done

# The drop makes a review speak, inside its cooldown, and the line is in what it says.
reset_spool
out="$(review)"
[ -z "$out" ] && check "precondition: inside the cooldown a review with nothing pending is quiet" ok \
  || check "precondition: inside the cooldown a review with nothing pending is quiet" "out=[$out]"
record_at "$T0" 106
out="$(printf '{"transcript_path":"%s","stop_hook_active":false}' "$TR" | CLAUDE_RERUN_NOW="$((T0 + 8 * DAY))" CLAUDE_PROJECT_DIR="$PROJ" bash "$REVIEW" 2>/dev/null)"
case "$out" in *'"decision"'*"run 106"*"dropped unread after 7 days"*) e=ok ;; *) e="out=[$out]" ;; esac
check "a review that drops a rerun speaks, inside its cooldown, and names it" "$e"

# The flake history keeps 90 days: an older line no longer counts and is removed.
reset_spool; mkdir -p "$RDIR"
NOW1=$((T0 + 200 * DAY))
flake_line "$((NOW1 - 91 * DAY))" 50 > "$FLAKES"
record_at "$NOW1" 101; resolve_at "$NOW1"
if bash "$LIB" has-findings "$PROJ" "$TR" >/dev/null 2>&1; then e="a flake older than 90 days was counted: [$(pending_text)]"; else e=ok; fi
check "a flake older than 90 days does not count toward a repeat" "$e"
grep -q '"run": "50"' "$FLAKES" && e="flakes=[$(cat "$FLAKES")]" || e=ok
check "a flake older than 90 days is removed from the history" "$e"
grep -q '"run": "101"' "$FLAKES" && check "the new flake is kept when the old one is trimmed" ok || check "the new flake is kept when the old one is trimmed" "flakes=[$(cat "$FLAKES")]"
ls "$RDIR" | grep -v -e '^flakes.jsonl$' -e "^$KEY.jsonl\$" -e '^flakes.jsonl.lock$' | grep -q . \
  && check "the trim leaves no temporary file beside the history" "left: [$(ls "$RDIR")]" \
  || check "the trim leaves no temporary file beside the history" ok

reset_spool; mkdir -p "$RDIR"
flake_line "$((NOW1 - 89 * DAY))" 50 > "$FLAKES"
record_at "$NOW1" 101; resolve_at "$NOW1"
case "$(pending_text)" in *"2nd time"*) e=ok ;; *) e="pending=[$(pending_text)] err=[$RES_ERR]" ;; esac
check "a flake 89 days old still counts toward a repeat" "$e"

reset_spool; mkdir -p "$RDIR"
flake_line "" 50 > "$FLAKES"
record_at "$NOW1" 101; resolve_at "$NOW1"
case "$(pending_text)" in *"2nd time"*) e=ok ;; *) e="pending=[$(pending_text)] err=[$RES_ERR]" ;; esac
check "a flake line with no date still counts" "$e"
grep -q '"sha": "old"' "$FLAKES" && check "a flake line with no date is kept" ok || check "a flake line with no date is kept" "flakes=[$(cat "$FLAKES")]"

reset_spool; mkdir -p "$RDIR"
flake_line "$((NOW1 - 11 * DAY))" 50 > "$FLAKES"
record_at "$NOW1" 101
RES_OUT="$(CLAUDE_RERUN_FLAKE_KEEP_DAYS=10 CLAUDE_RERUN_NOW="$NOW1" bash "$LIB" resolve-reruns "$PROJ" "$TR" 2>/dev/null)"
grep -q '"run": "50"' "$FLAKES" && e="flakes=[$(cat "$FLAKES")]" || e=ok
check "CLAUDE_RERUN_FLAKE_KEEP_DAYS sets the days" "$e"
for bad in 0 -1 ninety; do
  reset_spool; mkdir -p "$RDIR"
  flake_line "$((NOW1 - 30 * DAY))" 50 > "$FLAKES"
  record_at "$NOW1" 106
  CLAUDE_RERUN_FLAKE_KEEP_DAYS="$bad" CLAUDE_RERUN_NOW="$NOW1" bash "$LIB" resolve-reruns "$PROJ" "$TR" >/dev/null 2>"$WORK/res-err"
  RES_ERR="$(cat "$WORK/res-err")"
  grep -q '"run": "50"' "$FLAKES" && case "$RES_ERR" in *CLAUDE_RERUN_FLAKE_KEEP_DAYS*"default of 90 days"*) true ;; *) false ;; esac \
    && check "CLAUDE_RERUN_FLAKE_KEEP_DAYS=$bad keeps 90 days and says so" ok \
    || check "CLAUDE_RERUN_FLAKE_KEEP_DAYS=$bad keeps 90 days and says so" "flakes=[$(cat "$FLAKES" 2>/dev/null)] err=[$RES_ERR]"
done

# Two reviews at once: the trim takes the history's lock, so while another review holds it (to add
# its own lines) the trim does not rewrite the file under it, and says so.
reset_spool; mkdir -p "$RDIR"
flake_line "$((NOW1 - 200 * DAY))" 50 > "$FLAKES"
python3 -c '
import fcntl, os, sys, time
fh = open(sys.argv[1], "a")
fcntl.flock(fh, fcntl.LOCK_EX)
with open(sys.argv[3], "a") as f:
    f.write(sys.argv[4] + "\n")
open(sys.argv[2], "w").close()
deadline = time.monotonic() + 20
while not os.path.exists(sys.argv[5]) and time.monotonic() < deadline:
    time.sleep(0.05)
' "$FLAKES.lock" "$WORK/held" "$FLAKES" "$(flake_line "$NOW1" 77)" "$WORK/release" &
holder=$!
n=0; while [ ! -f "$WORK/held" ] && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
record_at "$NOW1" 101
CLAUDE_RERUN_LOCK_WAIT=0.3 CLAUDE_RERUN_NOW="$NOW1" bash "$LIB" resolve-reruns "$PROJ" "$TR" >/dev/null 2>"$WORK/res-err"
RES_ERR="$(cat "$WORK/res-err")"
: > "$WORK/release"; wait "$holder" 2>/dev/null
grep -q '"run": "50"' "$FLAKES" && grep -q '"run": "77"' "$FLAKES" \
  && check "while another review holds the history, the trim does not rewrite it" ok \
  || check "while another review holds the history, the trim does not rewrite it" "flakes=[$(cat "$FLAKES")]"
case "$RES_ERR" in *"flake history"*"could not"*) e=ok ;; *) e="err=[$RES_ERR]" ;; esac
check "a history the trim could not lock is said" "$e"
record_at "$NOW1" 106
CLAUDE_RERUN_NOW="$NOW1" bash "$LIB" resolve-reruns "$PROJ" "$TR" >/dev/null 2>&1
grep -q '"run": "77"' "$FLAKES" && ! grep -q '"run": "50"' "$FLAKES" \
  && check "once released, the trim keeps the other review's newer line and drops the old one" ok \
  || check "once released, the trim keeps the other review's newer line and drops the old one" "flakes=[$(cat "$FLAKES")]"
rm -f "$WORK/held" "$WORK/release"

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
