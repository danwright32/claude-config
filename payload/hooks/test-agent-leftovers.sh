#!/usr/bin/env bash
# Tests for the check that says which processes an agent's commands left running
# (claude-config#3561): bash-shell-mark.sh, lib/agent-leftovers.py and agent-leftovers-gate.sh.
#
# On 2026-11-24 a builder agent's harness started several thousand generated commands with no time
# limit. 19 never ended, the agent handed back, and the 19 shells ran on with no parent for about 90
# minutes. Nothing said so: the job watcher holds an agent's stop only for background work it knows
# of, and these were children of a foreground command that had already returned.
#
# A suite never leaves a real stray process behind, so every process table here is a stand in: a
# file in the shape `ps -axo pid=,ppid=,pgid=,lstart=,command=` prints, handed to the reader through
# AGENT_LEFTOVERS_PS. The one thing run for real is the marker line itself, in bash and in zsh, since
# what it writes and how it fails are properties of those shells (measured 2026-11-25).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARK="$DIR/bash-shell-mark.sh"
GATE="$DIR/agent-leftovers-gate.sh"
READER="$DIR/lib/agent-leftovers.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
has() { # has <description> <text> <ERE>
  if grep -Eq -- "$3" <<< "$2"; then check "$1" ok; else check "$1" "wanted /$3/ in: ${2:0:400}"; fi
}
lacks() { # lacks <description> <text> <ERE>
  if grep -Eq -- "$3" <<< "$2"; then check "$1" "found /$3/ in: ${2:0:400}"; else check "$1" ok; fi
}
. "$DIR/lib/hook-notice.sh" 2>/dev/null || true
said() { # said <description> <stdout> <ERE>: one JSON object whose systemMessage says it
  local why; why="$(hook_notice_verdict "$2" "$3" 2>&1)"
  if [ -z "$why" ]; then check "$1" ok; else check "$1" "$why"; fi
}
silent() { # silent <description> <text>
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then check "$1" ok; else check "$1" "it said: ${2:0:300}"; fi
}

ROOT="$WORK/marks"
SPOOL="$WORK/spool"
SESSION="sess-one"
NOW=1795620000   # a fixed instant: every time below is this plus or minus seconds
# The world a case stands in: fixture <name> then lines on stdin, each one of
#   proc <pid> <ppid> <pgid> <started, seconds from NOW> <command...>
#   mark <session> <pid> <made, seconds from NOW>          a shell that recorded itself
#   bash <agent file> <tool id> <began> <ended or -> <command...>   a Bash call in a transcript
fixture() {
  local name="$1"
  mkdir -p "$WORK/$name"
  python3 -c '
import json, os, sys, time
out, root, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)
table, scripts = [], {}
for line in sys.stdin:
    w = line.split()
    if not w:
        continue
    if w[0] == "proc":
        started = time.strftime("%a %b %e %H:%M:%S %Y", time.localtime(now + float(w[4])))
        table.append("%5s %5s %5s %s %s" % (w[1], w[2], w[3], started, " ".join(w[5:])))
    elif w[0] == "mark":
        d = os.path.join(root, w[1])
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, w[2])
        open(p, "w").close()
        os.utime(p, (now + float(w[3]), now + float(w[3])))
    elif w[0] == "bash":
        rows = scripts.setdefault(w[1], [])
        rows.append({"type": "assistant", "timestamp": iso(now + float(w[3])), "message": {"content": [
            {"type": "tool_use", "id": w[2], "name": "Bash", "input": {"command": " ".join(w[5:])}}]}})
        if w[4] != "-":
            rows.append({"type": "user", "timestamp": iso(now + float(w[4])), "message": {"content": [
                {"type": "tool_result", "tool_use_id": w[2], "content": "ok"}]}})
open(os.path.join(out, "ps.txt"), "w").write("\n".join(table) + "\n")
for name, rows in scripts.items():
    with open(os.path.join(out, name), "w") as f:
        f.write("not json at all\n[1, 2]\n")   # lines of another shape are skipped, never fatal
        for r in rows:
            f.write(json.dumps(r) + "\n")
' "$WORK/$name" "$ROOT" "$NOW"
}
# gate <fixture> <event> <agent> [report]: runs the real gate on a hook payload; sets OUT, ERR, RC.
gate() {
  local name="$1" event="$2" agent="$3" report="${4-}" payload
  payload="$(python3 -c '
import json, sys
name, event, agent, report, session, work = sys.argv[1:7]
p = {"session_id": session, "hook_event_name": event, "agent_id": agent, "cwd": work,
     "transcript_path": work + "/parent.jsonl", "agent_transcript_path": work + "/" + name + "/" + agent + ".jsonl"}
if event == "PreToolUse":
    p["tool_name"] = "SubagentHandback"; p["tool_input"] = {"message": report}
print(json.dumps(p))' "$name" "$event" "$agent" "$report" "${GATE_SESSION:-$SESSION}" "$WORK")"
  OUT="$(printf '%s' "$payload" | env HOME="$WORK/home" AGENT_LEFTOVERS_ROOT="$ROOT" AGENT_LEFTOVERS_PS="${GATE_PS-$WORK/$name/ps.txt}" \
    AGENT_LEFTOVERS_NOW="$((NOW + 600))" CLAUDE_ISSUE_SPOOL_DIR="$SPOOL" \
    CLAUDE_SLEEP_RECORD="${GATE_SLEEP-$WORK/no-sleep-record.json}" bash "$GATE" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
spooled() { cat "$SPOOL"/*.jsonl 2>/dev/null || true; }

for f in "$MARK" "$GATE" "$READER"; do
  [ -f "$f" ] && check "${f##*/} exists" ok || check "${f##*/} exists" "missing: the leftover process check is not built"
done

echo "the marker line: every Bash tool shell records its own process id"
ENVF="$WORK/envfile"; : > "$ENVF"
sout="$(printf '{"session_id":"%s","hook_event_name":"SessionStart"}' "$SESSION" | env CLAUDE_ENV_FILE="$ENVF" AGENT_LEFTOVERS_ROOT="$ROOT" bash "$MARK" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && check "the SessionStart hook exits 0" ok || check "the SessionStart hook exits 0" "rc=$rc: $sout"
[ "$(wc -l < "$ENVF" | tr -d ' ')" = 1 ] && check "it writes one line into the session's env file" ok || check "it writes one line into the session's env file" "$(cat "$ENVF")"
[ -d "$ROOT/$SESSION" ] && check "and makes the session's marker folder" ok || check "and makes the session's marker folder" "no $ROOT/$SESSION"
printf '{"session_id":"%s","hook_event_name":"SessionStart"}' "$SESSION" | env CLAUDE_ENV_FILE="$ENVF" AGENT_LEFTOVERS_ROOT="$ROOT" bash "$MARK" >/dev/null 2>&1
[ "$(wc -l < "$ENVF" | tr -d ' ')" = 1 ] && check "a second SessionStart of the same session adds no second copy of the line" ok || check "a second SessionStart of the same session adds no second copy of the line" "$(wc -l < "$ENVF") lines"
for sh in /bin/bash /bin/zsh; do
  [ -x "$sh" ] || { echo "SUITE-PART-UNMEASURED the marker line in $sh, because $sh is not on this machine"; continue; }
  # As Claude Code runs it: the env file's lines, then a line that starts a new list, then the command.
  got="$("$sh" -c "set -o noclobber
$(cat "$ENVF")
: && echo \"ran as \$\$\"" 2>&1)"
  pid="${got##*ran as }"
  has "$sh: the command after the line still runs, and the line prints nothing" "$got" '^ran as [0-9]+$'
  [ -e "$ROOT/$SESSION/$pid" ] && check "$sh: the shell left a marker named for its own process id" ok || check "$sh: the shell left a marker named for its own process id" "no $ROOT/$SESSION/$pid; got: $got"
  [ ! -s "$ROOT/$SESSION/$pid" ] && check "$sh: the marker is an empty file" ok || check "$sh: the marker is an empty file" "it holds data"
done
mv "$ROOT/$SESSION" "$ROOT/$SESSION.away" 2>/dev/null
for sh in /bin/bash /bin/zsh; do
  [ -x "$sh" ] || continue
  got="$("$sh" -c "$(cat "$ENVF")
: && echo still-runs" 2>&1)"
  [ -s "$ENVF" ] && [ "$got" = "still-runs" ] && check "$sh: with the marker folder gone the line fails in silence and the command still runs" ok || check "$sh: with the marker folder gone the line fails in silence and the command still runs" "$got"
done
rm -rf "$ROOT/$SESSION.away"
sout="$(printf '{"session_id":"%s"}' "$SESSION" | env -u CLAUDE_ENV_FILE AGENT_LEFTOVERS_ROOT="$ROOT" bash "$MARK" 2>&1)"
has "with no env file the hook says shells are not recorded this session" "$sout" 'not recorded'
sout="$(printf '{"session_id":"../../evil"}' | env CLAUDE_ENV_FILE="$WORK/envfile2" AGENT_LEFTOVERS_ROOT="$ROOT" bash "$MARK" 2>&1)"
[ ! -s "$WORK/envfile2" ] && check "a session id that is not a plain name writes no line" ok || check "a session id that is not a plain name writes no line" "$(cat "$WORK/envfile2")"
has "and the hook says so" "$sout" 'not recorded'

echo "the hook and the reader name one marker folder"
mkdir -p "$WORK/tmp"
for suite_run in "" "run 7/x"; do
  want="$(env -u AGENT_LEFTOVERS_ROOT TMPDIR="$WORK/tmp/" CLAUDE_SUITE_RUN_ID="$suite_run" python3 "$READER" dir sess-two 2>&1)"
  : > "$WORK/envfile3"
  printf '{"session_id":"sess-two"}' | env -u AGENT_LEFTOVERS_ROOT TMPDIR="$WORK/tmp/" CLAUDE_SUITE_RUN_ID="$suite_run" CLAUDE_ENV_FILE="$WORK/envfile3" bash "$MARK" >/dev/null 2>&1
  case "$(cat "$WORK/envfile3")" in
    *"'$want/'"*) [ -d "$want" ] && check "with the suite run id '${suite_run}' the line writes into the folder the reader reads" ok || check "with the suite run id '${suite_run}' the line writes into the folder the reader reads" "no folder $want" ;;
    *) check "with the suite run id '${suite_run}' the line writes into the folder the reader reads" "reader: $want; line: $(cat "$WORK/envfile3")" ;;
  esac
done
has "under a suite run the folder is never this Mac's real one" "$want" 'claude-shell-marks-[0-9]+-suite-run7x/sess-two$'

echo "a child that outlives its command is listed for the agent whose command started it"
# Agent a1's Bash call ran from -100 to -90 in shell 7318, which has gone; its children 7322 and 7323
# run on under launchd in the dead shell's group. Another session's shell 8100 left 8101 at the very
# same second, a sibling agent a2's later call left 9001, and a1's own call in shell 7400 still runs.
fixture one <<'EOF'
proc 1 0 1 -99999 /sbin/launchd
proc 2068 727 2068 -5000 claude
proc 7322 1 7318 -99 sleep 240
proc 7323 1 7318 -98 bash -c while-true
proc 8101 1 8100 -99 sleep 999
proc 9001 1 9000 -50 sleep 555
proc 7400 2068 7400 -20 /bin/zsh -c still-running-call
proc 7401 7400 7400 -19 sleep 30
mark sess-one 7318 -99.6
mark sess-one 9000 -50.5
mark sess-one 7400 -20.2
mark sess-other 8100 -99.5
bash a1.jsonl t1 -100 -90 python3 harness.py --all
bash a1.jsonl t2 -21 - sleep 30
bash a2.jsonl t3 -51 -49 nohup sleep 555
bash o1.jsonl t9 -100 -90 python3 other-harness.py
EOF
gate one PreToolUse a1 "All done, nothing left running."
[ "$RC" -eq 2 ] && check "the hand back is refused while its children run" ok || check "the hand back is refused while its children run" "rc=$RC out=$OUT err=$ERR"
has "the refusal names the first child's process id" "$ERR" 'pid 7322'
has "and the second's" "$ERR" 'pid 7323'
has "with its command" "$ERR" 'sleep 240'
has "and when it started" "$ERR" 'started [0-9]{1,2}:[0-9]{2}:[0-9]{2} [AP]M ET'
has "and the command of the agent's own that started it" "$ERR" 'harness\.py'
has "it tells the agent how to stop one by its process id" "$ERR" 'kill 7322'
has "and that nothing was stopped for it" "$ERR" '[Nn]othing was stopped'
lacks "a process another session started at the same second is never listed" "$ERR" '8101|sleep 999'
lacks "nor a sibling agent's child" "$ERR" '9001|sleep 555'
lacks "nor the agent's own command that is still running" "$ERR" '7401|7400|sleep 30'
silent "a refusal prints nothing on stdout" "$OUT"
# The control, both ways: the same table read as the other session, by an agent of its own whose
# command ran in that same second. Which session's folder holds the marker is all that differs.
GATE_SESSION="sess-other" gate one PreToolUse o1 "Done."
has "read as the other session, that same table lists the other session's process" "$ERR" 'pid 8101.*sleep 999'
lacks "and none of this session's" "$ERR" '7322|7323|sleep 240'
GATE_SESSION="sess-one" gate one PreToolUse a2 "Done."
has "and the sibling agent's own hand back lists the sibling's child" "$ERR" 'pid 9001.*sleep 555'
lacks "and not the first agent's" "$ERR" '7322|7323'

gate one PreToolUse a1 "Done. I left pid 7322 and pid 7323 running on purpose: they serve the next step."
[ "$RC" -eq 0 ] && [ -f "$GATE" ] && check "a report that names each process id goes through" ok || check "a report that names each process id goes through" "rc=$RC err=$ERR"
silent "in silence, since the report itself tells the orchestrating session" "$OUT$ERR"
gate one SubagentStop a1
silent "and the stop after it says nothing more of processes the report named" "$OUT$ERR"

echo "an agent that neither stops them nor names them is let through, and it is said"
fixture two <<'EOF'
proc 7322 1 7318 -99 sleep 240
mark sess-one 7318 -99.6
bash b1.jsonl t1 -100 -90 python3 harness.py
EOF
gate two PreToolUse b1 "Done."; r1=$RC
gate two PreToolUse b1 "Done."; r2=$RC
gate two PreToolUse b1 "Done."; r3=$RC
[ "$r1/$r2/$r3" = "2/2/0" ] && check "refused twice, let through on the third hand back" ok || check "refused twice, let through on the third hand back" "$r1/$r2/$r3"
said "the third says to Dan what the agent left, by process id" "$OUT" 'pid 7322'
has "and spools it for the orchestrating session's review" "$(spooled)" '7322'
gate two SubagentStop b1
[ -f "$GATE" ] && silent "the stop after it does not say the same processes again" "$OUT$ERR" || check "the stop after it does not say the same processes again" "no gate"
[ -f "$WORK/home/.claude/state/agent-leftovers/agents/$SESSION.b1.json" ] && check "what was said is kept in this Mac's own state folder" ok || check "what was said is kept in this Mac's own state folder" "no file for agent b1 under $WORK/home/.claude/state/agent-leftovers/agents"
[ -z "$(ls -A "$ROOT/$SESSION" | grep -v '^[0-9]*$')" ] && check "and the gate writes nothing into the marker folder, which only a session's shells write" ok || check "and the gate writes nothing into the marker folder, which only a session's shells write" "$(ls -A "$ROOT/$SESSION")"
# A state folder that cannot be written must never become a refusal at every attempt.
mkdir -p "$WORK/rohome/.claude/state"; : > "$WORK/rohome/.claude/state/agent-leftovers"
rogate() { OUT="$(printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"SubagentHandback","tool_input":{"message":"Done."},"agent_id":"b9","agent_transcript_path":"%s"}' "$SESSION" "$WORK/two/b1.jsonl" \
  | env HOME="$WORK/rohome" AGENT_LEFTOVERS_ROOT="$ROOT" AGENT_LEFTOVERS_PS="$WORK/two/ps.txt" AGENT_LEFTOVERS_NOW="$((NOW + 600))" CLAUDE_ISSUE_SPOOL_DIR="$SPOOL" bash "$GATE" 2>"$WORK/err")"; RC=$?; }
rogate
[ "$RC" -eq 0 ] && check "with nowhere to keep count the hand back is let through, never refused for ever" ok || check "with nowhere to keep count the hand back is let through, never refused for ever" "rc=$RC $(cat "$WORK/err")"
said "and what the agent left is still said" "$OUT" 'pid 7322.*could not keep count'

echo "an agent that ends without handing back: the stop is never refused, and it is said once"
fixture three <<'EOF'
proc 7322 1 7318 -99 sleep 240
mark sess-one 7318 -99.6
bash c1.jsonl t1 -100 -90 python3 harness.py
EOF
gate three SubagentStop c1
[ "$RC" -eq 0 ] && check "the stop goes ahead" ok || check "the stop goes ahead" "rc=$RC err=$ERR"
said "and says what the agent left" "$OUT" 'pid 7322.*sleep 240'
gate three SubagentStop c1
[ -f "$GATE" ] && silent "a second stop of the same agent does not repeat it" "$OUT$ERR" || check "a second stop of the same agent does not repeat it" "no gate"

echo "nothing left running is silence"
fixture clean <<'EOF'
proc 2068 727 2068 -5000 claude
proc 8101 1 8100 -99 sleep 999
mark sess-one 7318 -99.6
bash d1.jsonl t1 -100 -90 make test
EOF
gate clean PreToolUse d1 "Done."
[ "$RC" -eq 0 ] && check "a clean agent's hand back goes through" ok || check "a clean agent's hand back goes through" "rc=$RC err=$ERR"
silent "and nothing is said" "$OUT$ERR"
out="$(printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"SubagentHandback","tool_input":{"message":"x"}}' "$SESSION" | env AGENT_LEFTOVERS_ROOT="$ROOT" AGENT_LEFTOVERS_PS="$WORK/one/ps.txt" bash "$GATE" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && silent "a call that is not from an agent is passed in silence" "$out" || check "a call that is not from an agent is passed in silence" "rc=$rc $out"

echo "a process id used again is not taken for the shell that had it before"
# Shell 7318 of agent e1 ran and ended clean; much later something else's shell got the same number
# and left a child. Its child started long after the agent's call ended, so it is not the agent's.
fixture reuse <<'EOF'
proc 7999 1 7318 -10 sleep 777
mark sess-one 7318 -99.6
bash e1.jsonl t1 -100 -90 make test
EOF
gate reuse PreToolUse e1 "Done."
[ "$RC" -eq 0 ] && check "the hand back is not refused over it" ok || check "the hand back is not refused over it" "rc=$RC err=$ERR"
said "it is said as one that could not be told" "$OUT" 'could not be told.*7999|7999.*could not be told'
lacks "and never as one the agent left" "$OUT$ERR" 'agent e1 left|your commands started'

echo "a process settled once does not settle a later one given the same number"
# Agent j1's first hand back named pid 7650 and passed this check, but the agent carried on (another
# hook refused that hand back). 7650 ended, and a later command of j1's left a child that was given
# 7650 again (on 2026-11-25 a measurement sleep's number was given to another process within the hour,
# one sample). That later child is j1's and unnamed, so it is said.
fixture againa <<'EOF'
proc 7650 1 7610 -99 sleep 240
mark sess-one 7610 -99.6
bash j1.jsonl t1 -100 -90 python3 harness.py
EOF
fixture againb <<'EOF'
proc 7650 1 7620 -39 sleep 888
mark sess-one 7620 -40.2
bash j1.jsonl t1 -100 -90 python3 harness.py
bash j1.jsonl t2 -40 -30 python3 second.py
EOF
gate againa PreToolUse j1 "Done. I left pid 7650 running on purpose."
[ "$RC" -eq 0 ] && check "the first hand back, naming pid 7650, goes through" ok || check "the first hand back, naming pid 7650, goes through" "rc=$RC err=$ERR"
gate againb PreToolUse j1 "Done."
[ "$RC" -eq 2 ] && check "a later process given the same number is refused like any other" ok || check "a later process given the same number is refused like any other" "rc=$RC out=$OUT err=$ERR"
has "and the refusal names it with its own command" "$ERR" 'pid 7650.*sleep 888'

echo "a process that could not be told is still said when the same hand back is refused"
# Agent l1's call left 7710 (its own) and, in another shell of that call, 7730, which started after
# the call ended. The refusal is about 7710 only, so 7730 must still be said at a later pass.
fixture mixed <<'EOF'
proc 7710 1 7700 -99 sleep 240
proc 7730 1 7720 -10 sleep 666
mark sess-one 7700 -99.6
mark sess-one 7720 -95.2
bash l1.jsonl t1 -100 -90 python3 harness.py
EOF
gate mixed PreToolUse l1 "Done."
[ "$RC" -eq 2 ] && check "the hand back is refused over the agent's own process" ok || check "the hand back is refused over the agent's own process" "rc=$RC out=$OUT err=$ERR"
gate mixed PreToolUse l1 "Done. pid 7710 stays on purpose: it serves the next step."
[ "$RC" -eq 0 ] && check "the next hand back, naming it, goes through" ok || check "the next hand back, naming it, goes through" "rc=$RC err=$ERR"
said "and says the process that could not be told, which the refusal left unsaid" "$OUT" '7730.*could not be told|could not be told.*7730'

echo "an id ending in a line break is not a plain name"
out="$(AGENT_LEFTOVERS_ROOT="$ROOT" python3 "$READER" dir "$(printf 'sess-two\nx')" 2>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && check "the reader names no folder for a session id holding a line break" ok || check "the reader names no folder for a session id holding a line break" "rc=$rc out=$out"
out="$(AGENT_LEFTOVERS_ROOT="$ROOT" python3 "$READER" dir "sess-two
" 2>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && [ -z "$out" ] && check "nor for one ending in a line break, which bash-shell-mark.sh refuses too" ok || check "nor for one ending in a line break, which bash-shell-mark.sh refuses too" "rc=$rc out=$out"
GATE_SESSION="sess-nl
" gate two PreToolUse k1 "Done."
said "the gate says it did not run for a session id ending in a line break" "$OUT" 'DID NOT RUN'

echo "what cannot be read is said as not told, never as nothing left"
GATE_PS="$WORK/no-such-table" gate two PreToolUse f1 "Done."
[ "$RC" -eq 0 ] && check "an unreadable process table never refuses the hand back" ok || check "an unreadable process table never refuses the hand back" "rc=$RC err=$ERR"
said "and says the check could not tell" "$OUT" 'COULD NOT TELL what agent f1 left running: the process table could not be read'
lacks "never that nothing is left" "$OUT" '[Nn]othing (is )?left|no process'
printf 'this is not a process table\n' > "$WORK/garbage.txt"
GATE_SESSION="sess-garbage" GATE_PS="$WORK/garbage.txt" gate two PreToolUse f2 "Done."
said "a table that does not parse is said the same way" "$OUT" 'COULD NOT TELL what agent f2 left running'
fixture norec <<'EOF'
proc 7322 1 7318 -99 sleep 240
bash g1.jsonl t1 -100 -90 python3 harness.py
EOF
GATE_SESSION="sess-unrecorded" gate norec PreToolUse g1 "Done."
[ "$RC" -eq 0 ] && check "a session whose shells are not recorded never refuses" ok || check "a session whose shells are not recorded never refuses" "rc=$RC err=$ERR"
said "and says that it cannot tell what an agent leaves" "$OUT" 'not recorded'
GATE_SESSION="sess-unrecorded" gate norec PreToolUse g1 "Done."
[ -f "$GATE" ] && silent "the same session is not told again at every hand back" "$OUT$ERR" || check "the same session is not told again at every hand back" "no gate"
fixture notranscript <<'EOF'
proc 7322 1 7318 -99 sleep 240
mark sess-one 7318 -99.6
EOF
gate notranscript PreToolUse h1 "Done."
[ "$RC" -eq 0 ] && check "an agent whose transcript cannot be read is never refused" ok || check "an agent whose transcript cannot be read is never refused" "rc=$RC err=$ERR"
said "and the process is said as this session's, whose agent could not be told" "$OUT" '7322.*could not be told|could not be told.*7322'

out="$(printf '[{"agent_id":"x1","hook_event_name":"PreToolUse"}]' | env HOME="$WORK/home" AGENT_LEFTOVERS_ROOT="$ROOT" AGENT_LEFTOVERS_PS="$WORK/two/ps.txt" bash "$GATE" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && check "a payload the reader cannot read as a hook payload never refuses" ok || check "a payload the reader cannot read as a hook payload never refuses" "rc=$rc"
said "and says the check did not run" "$out" 'DID NOT RUN'

echo "the reader's cost is bounded: it reads the transcript only when something is tied"
fixture big <<'EOF'
proc 2068 727 2068 -5000 claude
mark sess-one 7318 -99.6
bash i1.jsonl t1 -100 -90 make test
EOF
chmod 000 "$WORK/big/i1.jsonl"
gate big PreToolUse i1 "Done."
chmod 600 "$WORK/big/i1.jsonl"
[ -f "$GATE" ] && silent "with nothing tied to the session, an unreadable transcript is never even opened" "$OUT$ERR" || check "with nothing tied to the session, an unreadable transcript is never even opened" "no gate"

echo "while Dan is asleep: a refusal still goes to the agent, and a notice is spooled, never shown"
# Dan's choice on 2026-11-25 (tests/test-sleep-silence.sh): asleep, nothing is said to him, but what
# an agent left is still kept for the orchestrating session's review, and a hand back naming nothing
# is still refused. Asleep and awake are each a real sleep record judged by lib/sleep.sh's
# sleep_active, never a stand in flag; awake is a record that is not there.
BOOT="$(bash -c '. "$1" && sleep_boot_of "$(sysctl -n kern.boottime 2>/dev/null)"' _ "$DIR/lib/sleep.sh")"
[ -n "$BOOT" ] || BOOT=1   # no sysctl (Linux CI): sleep.sh skips the boot check, so any boot will do
NOW_MS="$(( $(date +%s) * 1000 ))"
ASLEEP="$WORK/asleep-record.json"
printf '{"v":1,"generation":"g-test","since":%s,"until":%s,"night":"2026-11-25","bootTime":%s,"report":"%s/r.md","startedBy":{"sessionId":"s0","cwd":"/"},"workers":[],"placeBefore":"home"}\n' \
  "$((NOW_MS - 60000))" "$((NOW_MS + 3600000))" "$BOOT" "$WORK" > "$ASLEEP"
CLAUDE_SLEEP_RECORD="$ASLEEP" bash -c '. "$1" && sleep_active' _ "$DIR/lib/sleep.sh" >/dev/null 2>&1 \
  && check "the asleep record reads as asleep to lib/sleep.sh (the control)" ok \
  || check "the asleep record reads as asleep to lib/sleep.sh (the control)" "sleep_active says awake, so the cases below prove nothing"
fixture sleepy <<'EOF'
proc 7522 1 7518 -99 sleep 241
proc 7622 1 7618 -59 sleep 242
proc 7722 1 7718 -29 sleep 243
proc 7822 1 7818 -9 sleep 244
mark sess-one 7518 -99.6
mark sess-one 7618 -59.6
mark sess-one 7718 -29.6
mark sess-one 7818 -9.6
bash z1.jsonl t1 -100 -90 python3 night-harness.py
bash z2.jsonl t1 -60 -50 python3 day-harness.py
bash z3.jsonl t1 -30 -20 python3 night-stop.py
bash z4.jsonl t1 -10 -5 python3 day-stop.py
EOF
GATE_SLEEP="$ASLEEP" gate sleepy PreToolUse z1 "Done."; r1=$RC; e1="$ERR"
GATE_SLEEP="$ASLEEP" gate sleepy PreToolUse z1 "Done."; r2=$RC
GATE_SLEEP="$ASLEEP" gate sleepy PreToolUse z1 "Done."; r3=$RC
[ "$r1/$r2/$r3" = "2/2/0" ] && check "asleep, a hand back naming nothing is still refused twice and let through on the third" ok \
  || check "asleep, a hand back naming nothing is still refused twice and let through on the third" "$r1/$r2/$r3"
has "and the refusal still names the process to the agent" "$e1" 'pid 7522'
silent "asleep, the third shows Dan nothing" "$OUT$ERR"
has "and what the agent left is still spooled for the orchestrating session's review" "$(spooled)" '7522'
GATE_SLEEP="$ASLEEP" gate sleepy SubagentStop z3
[ "$RC" -eq 0 ] && check "asleep, an agent's stop still goes ahead" ok || check "asleep, an agent's stop still goes ahead" "rc=$RC err=$ERR"
silent "and shows Dan nothing" "$OUT$ERR"
has "and what it left is spooled" "$(spooled)" '7722'
GATE_SLEEP="$ASLEEP" GATE_SESSION="sess-night-unrecorded" gate norec PreToolUse g9 "Done."
silent "asleep, a session whose shells are not recorded shows Dan nothing" "$OUT$ERR"
has "and that the check could not tell is spooled instead, so it is not lost" "$(spooled)" 'agent g9 left running: this session'
# The awake control, same fixture: what is silent asleep is said awake.
gate sleepy PreToolUse z2 "Done."; gate sleepy PreToolUse z2 "Done."; gate sleepy PreToolUse z2 "Done."
said "awake, the third hand back says to Dan what the agent left (the control)" "$OUT" 'pid 7622'
gate sleepy SubagentStop z4
said "awake, an agent's stop says what it left (the control)" "$OUT" 'pid 7822'

echo "a notice holding a line break, a tab, a double quote or a backslash reaches Dan whole, as valid JSON"
# The gate's own say(), run as installed, beside a stand in reader that answers with that notice:
# a systemMessage built by hand breaks on each of these (claude-config#1906). Every other library is
# the real one, so the sleep record and the spool are judged as they are above.
SAY_DIR="$WORK/say-hooks"
mkdir -p "$SAY_DIR/lib"
cp "$GATE" "$SAY_DIR/agent-leftovers-gate.sh"
for f in "$DIR"/lib/*; do [ "${f##*/}" = agent-leftovers.py ] || ln -s "$f" "$SAY_DIR/lib/${f##*/}"; done
HARD="$(printf 'LEFTOVER PROCESS CHECK: agent q1 left\tpid 7900: sh -c "echo \\\\ done"\nsecond line')"
printf 'import sys\nsys.stdin.read()\nsys.stdout.write("notice\\x1f" + %s + "\\x1f" + %s)\n' \
  "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$HARD")" \
  "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$HARD")" > "$SAY_DIR/lib/agent-leftovers.py"
saygate() { # saygate [<sleep record>]: the copied gate on a stand in payload; sets OUT, ERR, RC
  OUT="$(printf '{"session_id":"sess-say","hook_event_name":"SubagentStop","agent_id":"q1","cwd":"%s","transcript_path":"%s/parent.jsonl"}' "$WORK" "$WORK" \
    | env HOME="$WORK/home" CLAUDE_ISSUE_SPOOL_DIR="$WORK/say-spool" CLAUDE_SLEEP_RECORD="${1:-$WORK/no-sleep-record.json}" \
      bash "$SAY_DIR/agent-leftovers-gate.sh" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
saygate
[ "$RC" -eq 0 ] && check "awake, the stop with that notice goes ahead" ok || check "awake, the stop with that notice goes ahead" "rc=$RC err=$ERR"
got="$(HARD="$HARD" python3 -c '
import json, os, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except ValueError as e:
    print("not valid JSON (%s): %r" % (e, raw[:300])); sys.exit()
if not isinstance(d, dict) or d.get("systemMessage") != os.environ["HARD"]:
    print("the systemMessage was not the notice whole: %r" % (d,))
else:
    print("ok")' <<< "$OUT")"
check "awake, it is one valid JSON object whose systemMessage is the notice, line break, tab, quote and backslash intact" "$got"
saygate "$ASLEEP"
silent "asleep, that notice shows Dan nothing" "$OUT$ERR"
got="$(HARD="$HARD" python3 -c '
import json, os, sys
texts = []
for line in sys.stdin:
    try:
        texts += json.loads(line).get("findings") or []
    except (ValueError, AttributeError):
        pass
print("ok" if os.environ["HARD"] in texts else "no spooled record holds the notice whole: %r" % texts[:6])' < <(cat "$WORK/say-spool"/*.jsonl 2>/dev/null))"
check "and it is spooled whole for the orchestrating session's review" "$got"

echo "registration"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
reg() { # reg <event> <matcher or -> <script>
  python3 -c '
import json, sys
s = json.load(open(sys.argv[1])); event, matcher, script = sys.argv[2:5]
for group in s.get("hooks", {}).get(event, []):
    if matcher != "-" and group.get("matcher") != matcher:
        continue
    for h in group.get("hooks", []):
        if h.get("command", "").endswith("/hooks/" + script) and h.get("timeout"):
            sys.exit(0)
sys.exit(1)' "$SETTINGS" "$1" "$2" "$3"
}
reg SessionStart - bash-shell-mark.sh && check "bash-shell-mark.sh runs at every session start" ok || check "bash-shell-mark.sh runs at every session start" "not registered with a timeout"
reg PreToolUse SubagentHandback agent-leftovers-gate.sh && check "agent-leftovers-gate.sh runs before every hand back" ok || check "agent-leftovers-gate.sh runs before every hand back" "not registered with a timeout"
reg SubagentStop - agent-leftovers-gate.sh && check "agent-leftovers-gate.sh runs at every agent stop" ok || check "agent-leftovers-gate.sh runs at every agent stop" "not registered with a timeout"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
