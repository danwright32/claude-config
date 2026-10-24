#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans settings.hooks.json
# Tests for the three gates on an agent getting past the checks (claude-config#1587).
#
# On 2026-10-23 a Bidspoke builder agent committed twice with `git commit --no-verify` because the
# pre-commit typecheck and lint were slow, merged a pull request after a Monitor loop got it past the
# lessons review's read step, and then handed back a report saying "no `--no-verify`, no overrides".
# Nothing refused either bypass, and the report the main session relied on was untrue. So:
#
#   no-verify-gate.sh        refuses an AGENT's git command that skips the repository's own git hooks
#                            (--no-verify, commit -n, core.hooksPath, HUSKY=0), unless the main
#                            session approved that agent with lib/no-verify-approval.sh
#   monitor-action-gate.sh   refuses a Monitor whose command merges, pushes, commits or runs the merge
#                            helper, because no PreToolUse(Bash) gate is ever run for a Monitor's
#                            command, so a merge there meets no merge gate at all
#   handback-claims-gate.sh  compares a hand-back's "no --no-verify" and "no overrides" claims with
#                            the agent's own commands, and says so when they disagree
#
# lib/agent-overrides.py is the one reading all three share.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/agent-overrides.py"
NV_GATE="$DIR/no-verify-gate.sh"
APPROVE="$DIR/lib/no-verify-approval.sh"
MON_GATE="$DIR/monitor-action-gate.sh"
HB_GATE="$DIR/handback-claims-gate.sh"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

missing=""
for f in "$LIB" "$NV_GATE" "$APPROVE" "$MON_GATE" "$HB_GATE"; do
  [ -f "$f" ] || missing="$missing $(basename "$f")"
done
if [ -n "$missing" ]; then
  echo "FAIL: test-agent-bypass-gates: missing beside this suite:$missing"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" 1
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-bypass.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export NO_VERIFY_APPROVAL_DIR="$WORK/approvals"
export HANDBACK_CHECK_STATE_DIR="$WORK/handback-state"
export CLAUDE_ISSUE_SPOOL_DIR="$WORK/spool"
export NO_VERIFY_NOW=1000000

# ---------------------------------------------------------------------------------------------
echo "agent-overrides.py skips: what skips a repository's own git hooks"

skips_says() { # skips_says <label> <command> <expected exit>
  local out rc
  out="$(printf '%s' "$2" | python3 "$LIB" skips 2>&1)"; rc=$?
  if [ "$rc" = "$3" ]; then check "$1" ok; else check "$1" "exit $rc, wanted $3: $out"; fi
}
skips_says "commit --no-verify skips hooks" 'git commit --no-verify -m "wip"' 0
skips_says "commit -n skips hooks" 'git commit -n -m "wip"' 0
skips_says "commit -anm skips hooks (n before the value letter)" 'git commit -anm wip' 0
skips_says "commit -am with n in the message value does not" 'git commit -amn' 1
skips_says "a message mentioning --no-verify is not a skip" 'git commit -m "refuse --no-verify from agents"' 1
skips_says "a heredoc message mentioning it is not a skip" "$(printf 'git commit -F - <<EOF\nno --no-verify here\nEOF')" 1
skips_says "--verify after --no-verify turns hooks back on" 'git commit --no-verify --verify -m x' 1
skips_says "push --no-verify skips the pre-push hook" 'git push --no-verify origin x' 0
skips_says "merge --no-verify" 'git merge --no-verify feature' 0
skips_says "push -n is a dry run, not a skip" 'git push -n origin x' 1
skips_says "core.hooksPath on the git command" 'git -c core.hooksPath=/dev/null commit -m x' 0
skips_says "core.hooksPath in any case" 'git -c Core.HooksPath=/tmp/none push' 0
skips_says "HUSKY=0 in front of a commit" 'HUSKY=0 git commit -m x' 0
skips_says "export HUSKY=0" 'export HUSKY=0; git commit -m x' 0
skips_says "behind rtk" 'rtk git commit --no-verify -m x' 0
skips_says "inside an if" 'if true; then git commit --no-verify -m x; fi' 0
skips_says "inside bash -c" "bash -c 'git commit --no-verify -m x'" 0
skips_says "a rebase whose --exec commits with --no-verify" "git rebase origin/main --exec \"git commit --amend --no-edit --no-verify\"" 0
skips_says "a rebase whose --exec commits plainly does not" "git rebase origin/main --exec \"git commit --amend --no-edit\"" 1
skips_says "an echo of the words is not a skip" 'echo "git commit --no-verify"' 1
skips_says "a plain commit is not a skip" 'git commit -m "x"' 1
skips_says "a grep for the flag is not a skip" 'grep -rn -- "--no-verify" payload' 1

# ---------------------------------------------------------------------------------------------
echo "no-verify-gate.sh: an agent's skip of the git hooks is refused unless the main session approved it"

bash_payload() { # bash_payload <command> [agent_id]
  python3 -c '
import json, sys
d = {"session_id": "s-1587", "transcript_path": "/tmp/s-1587.jsonl", "cwd": "/tmp",
     "hook_event_name": "PreToolUse", "tool_name": sys.argv[3], "tool_input": {"command": sys.argv[1]},
     "tool_use_id": "toolu_01"}
if sys.argv[2]:
    d["agent_id"] = sys.argv[2]
    d["agent_type"] = "general-purpose"
print(json.dumps(d))
' "$1" "${2:-}" "${3:-Bash}"
}
RC=0; OUT=""; ERR=""
run_hook() { # run_hook <hook> <payload>
  local errf; errf="$(mktemp "$WORK/err.XXXXXXXX")"
  OUT="$(printf '%s' "$2" | bash "$1" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR$OUT" in *"$2"*) check "$1" ok ;; *) check "$1" "did not say '$2': ${ERR:0:400}" ;; esac; }

# The control first: the main thread's own --no-verify is not this gate's business, so a refusal
# below is the agent_id doing it and not a gate that refuses every --no-verify (L159).
run_hook "$NV_GATE" "$(bash_payload 'git commit --no-verify -m wip')"
allowed "the main session's --no-verify goes through"
run_hook "$NV_GATE" "$(bash_payload 'git commit -m wip' a1b2c3d4)"
allowed "an agent's plain commit goes through"
run_hook "$NV_GATE" "$(bash_payload 'git commit --no-verify -m wip' a1b2c3d4)"
refused "an agent's commit --no-verify is refused"
says "the refusal names the agent" "a1b2c3d4"
says "the refusal names the approval the main session can give" "no-verify-approval.sh approve a1b2c3d4"
run_hook "$NV_GATE" "$(bash_payload 'HUSKY=0 git push origin x' a1b2c3d4)"
refused "an agent's HUSKY=0 push is refused"
run_hook "$NV_GATE" "$(bash_payload 'git -c core.hooksPath=/dev/null commit -m x' a1b2c3d4)"
refused "an agent's core.hooksPath commit is refused"

# An agent may not approve itself: the approval is the main session's, and the gate is what tells the
# two apart (only an agent's payload carries agent_id).
run_hook "$NV_GATE" "$(bash_payload "bash ~/.claude/hooks/lib/no-verify-approval.sh approve a1b2c3d4 'slow lint'" a1b2c3d4)"
refused "an agent running the approval itself is refused"
says "and told the approval is the main session's" "main session"
# Nor write one by hand (lessons review at f654145): the folder is the approval, so an agent's command
# naming it is refused whatever it does there.
run_hook "$NV_GATE" "$(bash_payload "printf 'expires=9999999999\nreason=x\n' > ~/.claude-no-verify-approvals/a1b2c3d4" a1b2c3d4)"
refused "an agent writing an approval file by hand is refused"
run_hook "$NV_GATE" "$(bash_payload "printf 'expires=9999999999\nreason=x\n' > ~/.claude-no-verify-approvals/a1b2c3d4")"
allowed "the main session's command naming the folder is not this gate's business"
run_hook "$NV_GATE" "$(bash_payload "bash ~/.claude/hooks/lib/no-verify-approval.sh approve a1b2c3d4 'slow lint'")"
allowed "the main session running the approval goes through the gate"

echo "no-verify-approval.sh: approve, expiry, revoke"
out="$(bash "$APPROVE" approve a1b2c3d4 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && check "an approval with no reason is refused" ok || check "an approval with no reason is refused" "exit $rc: $out"
out="$(bash "$APPROVE" approve 'a1/../x' because 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && check "an agent id that is not a plain id is refused" ok || check "an agent id that is not a plain id is refused" "exit $rc: $out"
out="$(bash "$APPROVE" approve a1b2c3d4 "the pre-commit lint takes 20 minutes under load" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && check "the main session approves one agent" ok || check "the main session approves one agent" "exit $rc: $out"
run_hook "$NV_GATE" "$(bash_payload 'git commit --no-verify -m wip' a1b2c3d4)"
allowed "the approved agent's --no-verify then goes through"
says "and the allow says it was approved, with the reason" "the pre-commit lint takes 20 minutes"
run_hook "$NV_GATE" "$(bash_payload 'git commit --no-verify -m wip' ffff0000)"
refused "another agent is still refused"
NO_VERIFY_NOW=$((1000000 + 7201)) run_hook "$NV_GATE" "$(bash_payload 'git commit --no-verify -m wip' a1b2c3d4)"
refused "the approval expires after two hours"
out="$(bash "$APPROVE" list 2>&1)"
case "$out" in *a1b2c3d4*) check "list names the approval" ok ;; *) check "list names the approval" "$out" ;; esac
bash "$APPROVE" revoke a1b2c3d4 >/dev/null 2>&1
run_hook "$NV_GATE" "$(bash_payload 'git commit --no-verify -m wip' a1b2c3d4)"
refused "a revoked approval no longer lets it through"

# ---------------------------------------------------------------------------------------------
echo "monitor-action-gate.sh: a Monitor never carries a merge, a push or a commit"

mon() { run_hook "$MON_GATE" "$(bash_payload "$1" "${2:-}" Monitor)"; }
mon 'until gh pr merge 2679 --squash; do sleep 60; done'
refused "a merge retried in a Monitor is refused"
says "the refusal says no gate sees a Monitor's command" "no merge or push gate"
mon 'until gh pr merge 2679 --squash; do sleep 60; done' a1b2c3d4
refused "an agent's merge in a Monitor is refused too"
mon 'gh api -X PUT repos/o/x/pulls/7/merge'
refused "an API merge in a Monitor is refused"
mon 'while true; do git push origin x && break; sleep 30; done'
refused "a push in a Monitor is refused"
mon 'git commit -m wip'
refused "a commit in a Monitor is refused"
mon 'until PR_REVIEW_READ=$k bash ~/.claude/hooks/lib/merge-when-ready.sh 2679 --squash; do sleep 60; done'
refused "the merge helper run from a Monitor is refused"
mon 'tail -n +1 -f /tmp/x/merge.log | grep --line-buffered -E "merged|Stopped"'
allowed "watching the merge helper's log is allowed"
mon 'until ! pgrep -f "merge-when-ready.sh 923" >/dev/null; do sleep 15; done; tail -3 /tmp/x/merge.log'
allowed "waiting on the merge helper's process is allowed"
mon 'while pgrep -f "git push origin x" >/dev/null; do sleep 30; done'
allowed "waiting on a push's process is allowed"
mon 'gh pr checks 2679 --watch'
allowed "watching checks is allowed"
run_hook "$MON_GATE" '{"tool_name":"Monitor","tool_input":{"ws":{"url":"wss://x"}},"hook_event_name":"PreToolUse"}'
allowed "a WebSocket Monitor has no command and is allowed"

# ---------------------------------------------------------------------------------------------
echo "handback-claims-gate.sh: a report's 'no overrides' against the agent's own commands"

# A transcript in the shape Claude Code writes: assistant tool_use blocks, user tool_result blocks.
# transcript <path> <command>... : each command a Bash call that ran ("ok"), unless prefixed
# "REFUSED:" (a hook refused it, so it never ran) or "EXIT1:" (it ran and failed).
transcript() {
  python3 - "$@" <<'PY'
import json, sys
path, cmds = sys.argv[1], sys.argv[2:]
with open(path, "w") as f:
    for i, c in enumerate(cmds):
        result, err = "done", False
        if c.startswith("REFUSED:"):
            c, result, err = c[8:], "PreToolUse:Bash hook error: [no-verify-gate.sh]: REFUSED", True
        elif c.startswith("EXIT1:"):
            c, result, err = c[6:], "Exit code 1\nlint failed", True
        tid = "toolu_%02d" % i
        f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": c}}]}}) + "\n")
        f.write(json.dumps({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tid, "content": result, "is_error": err}]}}) + "\n")
PY
}
mkdir -p "$WORK/proj/s-hb/subagents"
hb_payload() { # hb_payload <agent_id> <report>
  python3 -c '
import json, sys
print(json.dumps({"session_id": "s-hb", "transcript_path": sys.argv[3] + "/proj/s-hb.jsonl", "cwd": sys.argv[3],
                  "hook_event_name": "PreToolUse", "tool_name": "SubagentHandback",
                  "tool_input": {"message": sys.argv[2]}, "agent_id": sys.argv[1],
                  "agent_type": "general-purpose", "tool_use_id": "toolu_hb"}))
' "$1" "$2" "$WORK"
}
hb() { run_hook "$HB_GATE" "$(hb_payload "$1" "$2")"; }

T1="$WORK/proj/s-hb/subagents/agent-b1.jsonl"
transcript "$T1" 'git status' 'git commit --no-verify -m wip' 'git push origin x'
# The Bidspoke report, word for word in its claim.
hb b1 'Merged #2679. Tests green. No `--no-verify`, no overrides.'
refused "a report saying no --no-verify after a --no-verify commit is refused"
says "the refusal quotes the claim" "No --no-verify"
says "the refusal names the command that contradicts it" "git commit --no-verify -m wip"
hb b1 'Merged #2679. I committed twice with --no-verify because the lint was slow; no other overrides.'
allowed "the corrected report, naming it, goes through"
hb b1 'Merged #2679. No overrides except the two --no-verify commits named above.'
allowed "a denial that qualifies itself (except ...) is not a denial"
hb b1 "Merged #2679. I didn$(printf '\342\200\231')t use --no-verify."
refused "a denial written with a curly apostrophe is still read"

T2="$WORK/proj/s-hb/subagents/agent-b2.jsonl"
transcript "$T2" 'git commit -m wip' 'git push origin x'
hb b2 'Done. No --no-verify, no overrides.'
allowed "the same claim with no override in the commands goes through"

T3="$WORK/proj/s-hb/subagents/agent-b3.jsonl"
transcript "$T3" 'REFUSED:git commit --no-verify -m wip' 'git commit -m wip'
hb b3 'Done. I did not use --no-verify.'
allowed "a --no-verify the gate refused never ran, so the claim is true"

T4="$WORK/proj/s-hb/subagents/agent-b4.jsonl"
transcript "$T4" 'SKIP_TEST_CHECK=1 git push origin x'
hb b4 'Pushed. No --no-verify.'
allowed "a SKIP_ override does not contradict a claim only about --no-verify"
hb b4 'Pushed. I never used ALLOW_RED_MERGE.'
allowed "a claim naming one override is about that override only"
hb b4 'Pushed. Nothing was bypassed.'
refused "but it contradicts a claim that nothing was bypassed"
says "naming the override" "SKIP_TEST_CHECK=1"
# A real hand-back on this Mac (2026-10, claude-config #799's builder) said "I never used
# `SKIP_PAYLOAD_WRITE_CHECK=1`" after running two commands with it set.
T7="$WORK/proj/s-hb/subagents/agent-b7.jsonl"
transcript "$T7" 'SKIP_PAYLOAD_WRITE_CHECK=1 TESTS_ONLY=1 python3 /tmp/fix.py'
hb b7 'The gate never refused any of my edits. I never used `SKIP_PAYLOAD_WRITE_CHECK=1`, took no hold.'
refused "a claim naming the very override the commands set is refused"

T5="$WORK/proj/s-hb/subagents/agent-b5.jsonl"
transcript "$T5" 'EXIT1:git commit --no-verify -m wip'
hb b5 'Never used --no-verify.'
refused "a --no-verify that ran and failed still ran"

# A report the agent will not correct is let through after two refusals, so it is never stranded,
# and the main session is told through the spool instead.
T6="$WORK/proj/s-hb/subagents/agent-b6.jsonl"
transcript "$T6" 'git commit --no-verify -m wip'
hb b6 'No overrides.'
refused "first contradicting hand-back: refused"
hb b6 'No overrides.'
refused "second: refused"
hb b6 'No overrides.'
allowed "third: let through so the report is not stranded"
says "and it says the report contradicts the commands" "contradicts"
if grep -rq "b6" "$CLAUDE_ISSUE_SPOOL_DIR" 2>/dev/null; then check "the contradiction is spooled for the main session" ok
else check "the contradiction is spooled for the main session" "nothing under $CLAUDE_ISSUE_SPOOL_DIR mentions b6: $(ls -R "$CLAUDE_ISSUE_SPOOL_DIR" 2>&1)"; fi

# A counter that cannot be stored must not refuse for ever (lessons review at 0fe61ad): with no record
# of the refusals, every attempt would read as the first, and the report could never be handed back.
T8="$WORK/proj/s-hb/subagents/agent-b8.jsonl"
transcript "$T8" 'git commit --no-verify -m wip'
: > "$WORK/not-a-dir"
HANDBACK_CHECK_STATE_DIR="$WORK/not-a-dir/state" hb b8 'No overrides.'
allowed "a contradicting report is let through when the refusal count cannot be kept"
says "saying so" "could not keep count"

hb b404 'No overrides.'
allowed "an agent whose transcript cannot be found is let through"
says "saying it could not check" "could not"

run_hook "$HB_GATE" "$(python3 -c 'import json; print(json.dumps({"tool_name":"SubagentHandback","tool_input":{"message":"No overrides."},"hook_event_name":"PreToolUse","session_id":"x","transcript_path":"/tmp/x.jsonl"}))')"
allowed "a hand-back with no agent_id (not a subagent) is not judged"

# ---------------------------------------------------------------------------------------------
echo "with no python3: each gate says so rather than passing what it cannot read"
NOPY="$WORK/nopy"; mkdir -p "$NOPY"
for t in bash cat dirname sed head tail tr date mkdir rm mv grep cut wc printf env; do
  p="$(command -v "$t" 2>/dev/null)"; case "$p" in /*) ln -sf "$p" "$NOPY/$t" ;; esac
done
run_nopy() { # run_nopy <hook> <payload>
  local errf; errf="$(mktemp "$WORK/err.XXXXXXXX")"
  OUT="$(printf '%s' "$2" | PATH="$NOPY" "$NOPY/bash" "$1" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run_nopy "$NV_GATE" "$(bash_payload 'git commit --no-verify -m wip' a1b2c3d4)"
refused "no-verify-gate.sh refuses an agent's skip it cannot read"
says "naming python3" "python3"
run_nopy "$NV_GATE" "$(bash_payload 'git commit -m wip' a1b2c3d4)"
allowed "and lets a command naming no skip through"
run_nopy "$MON_GATE" "$(bash_payload 'until gh pr merge 7; do sleep 60; done' '' Monitor)"
refused "monitor-action-gate.sh refuses a merge it cannot read"
says "naming python3" "python3"
run_nopy "$HB_GATE" "$(hb_payload b1 'No overrides.')"
allowed "handback-claims-gate.sh lets the report through rather than strand it"
says "and says the check did not run" "DID NOT RUN"

# ---------------------------------------------------------------------------------------------
echo "settings.hooks.json: each gate is registered where its header says"
reg() { # reg <matcher> <hook basename>
  jq -e --arg m "$1" --arg h "$2" '[.hooks.PreToolUse[] | select(.matcher == $m) | .hooks[].command | select(endswith("/hooks/" + $h))] | length == 1' "$SETTINGS" >/dev/null 2>&1
}
reg Bash no-verify-gate.sh && check "no-verify-gate.sh runs before every Bash call" ok || check "no-verify-gate.sh runs before every Bash call" "not registered under Bash"
reg Monitor monitor-action-gate.sh && check "monitor-action-gate.sh runs before every Monitor" ok || check "monitor-action-gate.sh runs before every Monitor" "not registered under Monitor"
reg SubagentHandback handback-claims-gate.sh && check "handback-claims-gate.sh runs before every hand-back" ok || check "handback-claims-gate.sh runs before every hand-back" "not registered under SubagentHandback"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
