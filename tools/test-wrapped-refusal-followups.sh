#!/usr/bin/env bash
# Tests for tools/wrapped-refusal-followups.py: how often the wrapped command gate refused against
# every Bash call in a period, the shape of each refused command as today's gate reads it, and what
# came next after each refusal (claude-config#1492). Every fixture command is invented.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/wrapped-refusal-followups.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:3000}"; fi; }
absent(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; fi; }

P="$WORK/projects"
mkdir -p "$P/-proj-a/s1/subagents" "$P/-proj-b"

# Fixture transcripts, built from a compact list: each call is (id, minute, command, result), where
# the result is ok, err (a failure of the command itself), refused (the gate's refusal, as Claude
# Code writes a PreToolUse refusal) or quoted (a read of the gate's source whose output holds the
# refusal sentence, which is no refusal).
python3 - "$P" <<'PY'
import json, os, sys
P = sys.argv[1]
GATE = "PreToolUse:Bash hook error: [/h/.claude/hooks/check-wrapped-commands.sh]: "
REFUSAL = GATE + "BLOCKED: this command runs `bash` on a command that cannot be read before it runs: it runs a script file. It also names git, gh or rtk, so the gates cannot see what it would run, and it is refused rather than passed unjudged (claude-config#1478). Run the script in a command of its own."
QUOTED = '  echo "BLOCKED: this command $runs ... (claude-config#1478). $ASK"'
def write(path, calls, day="2026-10-25", extra=()):
    with open(path, "w") as f:
        for line in extra:
            f.write(line + "\n")
        for cid, minute, cmd, res in calls:
            ts = "%sT14:%02d:00Z" % (day, minute)
            f.write(json.dumps({"type": "assistant", "sessionId": "s", "timestamp": ts, "message": {"role": "assistant", "content": [{"type": "tool_use", "id": cid, "name": "Bash", "input": {"command": cmd}}]}}) + "\n")
            content = {"ok": "done", "err": "fatal: no such remote", "refused": REFUSAL, "quoted": QUOTED}[res]
            f.write(json.dumps({"type": "user", "sessionId": "s", "timestamp": ts, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": cid, "content": content, "is_error": res in ("err", "refused")}]}}) + "\n")
s1 = [
    ("b1", 0, "ls", "ok"),
    # Episode 1: refused, then the script alone, then the git part alone, which succeeds. Taught.
    ("b2", 1, "bash ./build-zq.sh && git push origin feature-zq", "refused"),
    ("b3", 2, "bash ./build-zq.sh", "ok"),
    ("b4", 3, "git push origin feature-zq", "ok"),
    # Episode 2: refused twice, then gh alone, which fails for its own reason.
    ("b5", 4, 'bash -c "$CMD_ZQ" && gh pr list', "refused"),
    ("b6", 5, 'bash -c "$CMD_ZQ" && gh pr list', "refused"),
    ("b7", 6, "gh pr list", "err"),
    # A read whose output quotes the refusal is no refusal.
    ("b13", 7, "grep -n BLOCKED check-wrapped-commands.sh", "quoted"),
    # Episode 3: refused, then overridden.
    ("b11", 8, "bash ./x-zq.sh && git log", "refused"),
    ("b12", 9, "SKIP_WRAPPED_CHECK=1 bash ./x-zq.sh && git log", "ok"),
    # Episode 4: refused at the time, and passes today's gate (a declared read only call).
    ("b14", 10, "~/claude-config-sync/claude-sync lesson L1 && git status", "refused"),
    ("b15", 11, "git status", "ok"),
]
write(os.path.join(P, "-proj-a", "s1.jsonl"), s1, extra=['{"type":"assistant","message":{"content":[{"type":"tool_use", this line is not json'])
# The same session resumed into a second file: its history repeated with the same ids, counted once.
write(os.path.join(P, "-proj-a", "s1-resumed.jsonl"), s1[:4])
# A subagent. Episode 5: a shell fed from a pipe, then a call naming none of the three, then the end.
write(os.path.join(P, "-proj-a", "s1", "subagents", "agent-q.jsonl"), [
    ("b8", 20, "cat steps-zq | bash && git status", "refused"),
    ("b9", 21, "echo hi", "ok"),
])
# Episode 6: a script run by its path, and the session ends at the refusal.
write(os.path.join(P, "-proj-b", "s2.jsonl"), [
    ("b10", 30, "./deploy-zq.sh && git push", "refused"),
])
# Episode 7: one of the shared config's own scripts beside git, then git alone. Its name is public.
write(os.path.join(P, "-proj-b", "s3.jsonl"), [
    ("b16", 40, "bash ~/.claude/hooks/lib/issue-spool.sh clear . && git status", "refused"),
    ("b17", 41, "git status", "ok"),
])
# Before the period: neither the call nor the refusal counts.
write(os.path.join(P, "-proj-b", "old.jsonl"), [
    ("b20", 0, "bash ./old-zq.sh && git push", "refused"),
    ("b21", 1, "git push", "ok"),
], day="2026-10-10")
PY

# The gate's record for the same period: three rows in it, one before it, one unreadable line.
L="$WORK/ledger"; mkdir -p "$L"
{
  printf '1793066400\tmac\tbash\tscript-file\trefused\n'
  printf '1793066460\tmac\tbash -c\tvariable\trefused\n'
  printf '1793066520\tmac\tbash\tinput\trefused\n'
  printf '1791900000\tmac\tbash\tscript-file\trefused\n'
  printf 'not a row\n'
} > "$L/refusals.tsv"

run(){ python3 "$TOOL" --root "$P" --ledger "$L/refusals.tsv" --since 2026-10-23 --until 2026-11-04 "$@" 2>&1; }
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: exit $rc"; echo "${out:0:3000}"; }

check "the period is stated in ET, with its length" "2026-10-23 ET to 2026-11-04 ET (12 days, the last day not included)" "$out"
check "every Bash call in the period is counted once, a resumed copy included" "Bash calls: 17" "$out"
check "an unreadable transcript line is counted, never skipped silently" "1 transcript lines could not be read" "$out"
check "refusals are counted against the Bash calls, a quoted refusal sentence excluded" "refused by the wrapped command gate: 8 (47.1% of Bash calls), in 7 episodes" "$out"
check "the gate's own record for the same period is set beside it" "the record (refusals.tsv) holds 3 refusals in the same period" "$out"
check "the record's unreadable line is counted" "1 record lines could not be read" "$out"
check "each refused command is read by today's gate for its shape" "3  bash, script-file" "$out"
check "a script outside the shared config is counted without its name" "3  a script outside the shared config" "$out"
check "one of the shared config's own scripts is named" "1  ~/.claude/hooks/lib/issue-spool.sh" "$out"
check "outcomes are broken down by script" "~/.claude/hooks/lib/issue-spool.sh: taught 1, retried and failed 0, overridden 0, dropped 0, ended 0" "$out"
check "a variable handed to bash -c keeps its shape" "2  bash -c, variable" "$out"
check "a shell fed from a pipe" "1  bash, input" "$out"
check "a script run by its path" "1  direct, script-file" "$out"
check "a refusal today's gate no longer makes is said so" "1  passes today's gate" "$out"
check "a refusal followed by the git part run alone and succeeding taught" "taught, the git, gh or rtk part ran on its own and succeeded: 3" "$out"
check "a retry that failed for its own reason is its own outcome" "retried on its own, but that call failed: 1" "$out"
check "an override is its own outcome" "overridden with SKIP_WRAPPED_CHECK=1: 1" "$out"
check "a refusal followed only by calls naming none of the three is dropped" "dropped, no later call ran git, gh or rtk within 5 Bash calls: 1" "$out"
check "a refusal that is the session's last call ended there" "ended, the refusal was the transcript's last Bash call: 1" "$out"
check "outcomes are broken down by shape" "bash, script-file: taught 2, retried and failed 0, overridden 1, dropped 0, ended 0" "$out"
absent "a call before the period is not counted" "Bash calls: 19" "$out"
# Privacy: the report carries counts and shapes only, never a command, a path or a project.
for leak in zq proj-a proj-b agent-q "$P"; do
  absent "no command text, path or project name is printed ($leak)" "$leak" "$out"
done
# The count of transcripts left out is always printed, so a zero is a reading, not an absence.
check "a run that read every transcript says none was left out" "transcripts that could not be read: 0" "$out"
check "a run that read every transcript says none was gone" "transcripts gone before they could be read (deleted or moved after being listed): 0" "$out"
absent "a run that read every transcript gives no shortfall warning" "every total below leaves out" "$out"

# A transcript that cannot be opened, and one gone between being listed and being read, are each
# counted beside the totals, never skipped silently (claude-config#2239).
U="$WORK/unread"
mkdir -p "$U"
cp -R "$P/." "$U/"
printf '%s\n' '{"type":"assistant","timestamp":"2026-10-25T15:00:00Z","message":{"content":[{"type":"tool_use","id":"u1","name":"Bash","input":{"command":"bash ./locked-zq.sh && git push"}}]}}' > "$U/-proj-b/locked-zq.jsonl"
chmod 000 "$U/-proj-b/locked-zq.jsonl"
ln -s "$U/-proj-b/deleted-zq.jsonl" "$U/-proj-b/gone-zq.jsonl"
if [ -r "$U/-proj-b/locked-zq.jsonl" ]; then
  # Running as a user chmod cannot lock out (root): the unreadable case cannot be built here.
  echo "UNMEASURED: a file with no read permission is still readable to this user, so the unreadable transcript case was not tested"
else
  out="$(python3 "$TOOL" --root "$U" --ledger "$L/refusals.tsv" --since 2026-10-23 --until 2026-11-04 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a run with an unreadable transcript exits $rc"; echo "${out:0:3000}"; }
  check "a transcript that cannot be opened is counted" "transcripts that could not be read: 1" "$out"
  check "a transcript gone before it was read is counted on its own" "transcripts gone before they could be read (deleted or moved after being listed): 1" "$out"
  check "the totals say they are short" "every total below leaves out whatever those 2 transcripts hold" "$out"
  check "the readable transcripts are still measured" "Bash calls: 17" "$out"
  for leak in zq locked-zq gone-zq deleted-zq "$U"; do
    absent "no name or path of a transcript left out is printed ($leak)" "$leak" "$out"
  done
fi

# A root holding no transcript is unmeasured, never a rate of zero.
mkdir -p "$WORK/empty"
out="$(python3 "$TOOL" --root "$WORK/empty" --ledger "$L/refusals.tsv" --since 2026-10-23 --until 2026-11-04 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: an empty root exits 0"; }
check "an empty root says it measured nothing" "no Bash call found" "$out"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
