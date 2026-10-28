#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans settings.hooks.json
# Tests for amend-force-push-gate.sh, which refuses a SUBAGENT's git command that rewrites a commit
# already made: `git commit --amend`, and `git push` with --force, -f, --force-with-lease or a +refspec
# (claude-config#1856).
#
# On 2026-10-28 the #1806 builder tried to amend its own commit after a push review finding, the auto
# mode classifier refused it as "Git Destructive", and the push that followed sent the commit without
# the fix; the #1840 builder and a merge brief hit the same refusal for a force push the same night.
# Builders found the rule by trial. The rule is said in the global CLAUDE.md, and this gate makes it
# hold without the prompt, saying the same sentence.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/amend-force-push-gate.sh"
LIB="$DIR/lib/agent-overrides.py"
RULES="$DIR/../CLAUDE.md"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
# The one sentence the brief, the rule file and the refusal all say (claude-config#1856).
RULE="Never amend a commit or force push: add a new commit and push normally."

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

missing=""
for f in "$GATE" "$LIB" "$RULES"; do
  [ -f "$f" ] || missing="$missing $(basename "$f")"
done
if [ -n "$missing" ]; then
  echo "FAIL: test-amend-force-push-gate: missing beside this suite:$missing"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" 1
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/amend-force-push.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT

bash_payload() { # bash_payload <command> [agent_id]
  python3 -c '
import json, sys
d = {"session_id": "s-1856", "transcript_path": "/tmp/s-1856.jsonl", "cwd": "/tmp",
     "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]},
     "tool_use_id": "toolu_01"}
if sys.argv[2]:
    d["agent_id"] = sys.argv[2]
    d["agent_type"] = "general-purpose"
print(json.dumps(d))
' "$1" "${2:-}"
}
RC=0; OUT=""; ERR=""
run_hook() { # run_hook <payload>
  local errf; errf="$(mktemp "$WORK/err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$GATE" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
agent_refused() { # agent_refused <label> <command>
  # Refused by the library's reading of the command, not by the degraded path that refuses on words.
  run_hook "$(bash_payload "$2" a1b2c3d4)"
  case "$RC:$ERR" in
    "2:REFUSED (amend-force-push-gate.sh): agent a1b2c3d4 ran a git command that rewrites a commit already made:"*) check "$1" ok ;;
    *) check "$1" "exit $RC, stderr: ${ERR:0:300}" ;;
  esac
}
agent_allowed() { # agent_allowed <label> <command>
  run_hook "$(bash_payload "$2" a1b2c3d4)"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then check "$1" ok; else check "$1" "exit $RC, stderr: ${ERR:0:300}"; fi
}
main_allowed() { # main_allowed <label> <command>
  run_hook "$(bash_payload "$2")"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then check "$1" ok; else check "$1" "exit $RC, stderr: ${ERR:0:300}"; fi
}
says() { case "$ERR$OUT" in *"$2"*) check "$1" ok ;; *) check "$1" "did not say '$2': ${ERR:0:400}" ;; esac; }

# ---------------------------------------------------------------------------------------------
echo "a subagent's amend or force push is refused"
agent_refused "commit --amend" 'git commit --amend --no-edit'
says "the refusal is the rule's own sentence" "$RULE"
says "the refusal names the agent" "a1b2c3d4"
says "the refusal names the issue" "#1856"
agent_refused "commit --amend with a message file" 'git commit --amend -F /tmp/msg.txt'
agent_refused "commit -a --amend" 'git commit -a --amend -m "fix"'
agent_refused "commit --amend behind rtk" 'rtk git commit --amend --no-edit'
agent_refused "commit --amend after a cd" 'cd /tmp/repo && git commit --amend --no-edit'
agent_refused "commit --amend inside bash -c" "bash -c 'git commit --amend --no-edit'"
agent_refused "commit --amend with git -C" 'git -C /tmp/repo commit --amend --no-edit'
agent_refused "a rebase whose --exec amends" 'git rebase origin/main --exec "git commit --amend --no-edit"'
agent_refused "push --force" 'git push --force origin feature'
says "a force push's refusal is the same sentence" "$RULE"
agent_refused "push -f" 'git push -f origin feature'
agent_refused "push -uf, a clustered -f" 'git push -uf origin feature'
agent_refused "push --force-with-lease" 'git push --force-with-lease origin feature'
agent_refused "push --force-with-lease=ref:sha" 'git push --force-with-lease=feature:abc123 origin feature'
agent_refused "push --force-if-includes with a lease" 'git push --force-with-lease --force-if-includes origin feature'
agent_refused "push of a +refspec" 'git push origin +feature'
agent_refused "push of a +src:dst refspec" 'git push origin +HEAD:refs/heads/feature'
agent_refused "push --force behind rtk after a cd" 'cd /tmp/repo && rtk git push --force'
agent_refused "push --force behind env" 'env GIT_TRACE=0 git push --force origin feature'
# git takes an unambiguous prefix of a long option, and --mirror force updates every ref; the same
# reading as the scope-modes overnight refusal, so the two agree on what a force push is.
agent_refused "push --forc, a prefix git reads as --force" 'git push --forc origin feature'
agent_refused "push --mirror" 'git push --mirror backup'
agent_refused "push with a + on the far side of a refspec" 'git push origin HEAD:+feature'
agent_refused "push --force after a --no-force" 'git push --no-force --force origin feature'

# ---------------------------------------------------------------------------------------------
echo "a subagent's plain commit and push go through, and so does a mention of the flags"
agent_allowed "plain commit with a message file" 'git commit -F /tmp/msg.txt'
agent_allowed "plain commit -am" 'git commit -am "x"'
agent_allowed "plain push" 'git push origin feature'
agent_allowed "push -u" 'git push -u origin feature'
agent_allowed "push of a branch whose name holds f" 'git push origin fix-force-flag'
agent_allowed "a message naming --amend is not an amend" 'git commit -m "refuse --amend from agents"'
agent_allowed "a message value of -f is not a force" 'git commit -m -f'
agent_allowed "a quoted grep for --amend" 'grep "--amend" notes.txt'
agent_allowed "a grep for --force" 'grep -n -- "--force" payload/hooks/x.sh'
agent_allowed "an echo of a force push" 'echo "never git push --force"'
agent_allowed "a heredoc message naming both" "$(printf 'git commit -F - <<EOF\nno --amend, no push --force\nEOF')"
agent_allowed "push --no-force" 'git push --no-force origin feature'
agent_allowed "push --force then --no-force, the last wins" 'git push --force --no-force origin feature'
agent_allowed "push --follow-tags" 'git push --follow-tags origin feature'
agent_allowed "push -o with a value of f" 'git push -o f origin feature'
agent_allowed "commit --fixup makes a new commit" 'git commit --fixup HEAD'
agent_allowed "a command that is not git" 'ls -la'

# ---------------------------------------------------------------------------------------------
echo "the main session is not judged"
main_allowed "the main session's commit --amend" 'git commit --amend --no-edit'
main_allowed "the main session's push --force" 'git push --force origin feature'
main_allowed "the main session's +refspec push" 'git push origin +feature'

# ---------------------------------------------------------------------------------------------
echo "an agent payload the gate cannot read"
run_hook '{"agent_id": "a1b2", "tool_name": "Bash", "tool_input": {"command": "git commit --amend"'
if [ "$RC" -eq 2 ]; then check "a broken agent payload naming --amend is refused" ok; else check "a broken agent payload naming --amend is refused" "exit $RC: ${ERR:0:300}"; fi
run_hook '{"agent_id": "a1b2", "tool_name": "Bash", "tool_input": {"command": "git push --force"'
if [ "$RC" -eq 2 ]; then check "a broken agent payload naming --force is refused" ok; else check "a broken agent payload naming --force is refused" "exit $RC: ${ERR:0:300}"; fi
run_hook '{"agent_id": "a1b2", "tool_name": "Bash", "tool_input": {"command": "git status"'
if [ "$RC" -eq 0 ]; then check "a broken agent payload naming neither goes through" ok; else check "a broken agent payload naming neither goes through" "exit $RC: ${ERR:0:300}"; fi

NOPY="$WORK/nopy"; mkdir -p "$NOPY"
for t in bash cat dirname sed head tail tr date mkdir rm mv grep cut wc printf env; do
  p="$(command -v "$t" 2>/dev/null)"; case "$p" in /*) ln -sf "$p" "$NOPY/$t" ;; esac
done
run_nopy() { # run_nopy <payload>
  local errf; errf="$(mktemp "$WORK/err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | PATH="$NOPY" "$NOPY/bash" "$GATE" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run_nopy "$(bash_payload 'git commit --amend --no-edit' a1b2c3d4)"
if [ "$RC" -eq 2 ]; then check "with no python3 an agent's amend is refused" ok; else check "with no python3 an agent's amend is refused" "exit $RC: ${ERR:0:300}"; fi
says "naming python3" "python3"
run_nopy "$(bash_payload 'git commit -F /tmp/msg.txt' a1b2c3d4)"
if [ "$RC" -eq 0 ]; then check "with no python3 a plain commit goes through" ok; else check "with no python3 a plain commit goes through" "exit $RC: ${ERR:0:300}"; fi

# ---------------------------------------------------------------------------------------------
echo "the rule is said where every dispatched builder reads it, in the same words"
# The rule file cites its issue before the full stop, as its neighbours do, so the refusal's
# sentence is matched without its own full stop.
RULE_WORDS="${RULE%.}"
if grep -F -q "$RULE_WORDS (#1856)." "$RULES"; then check "payload/CLAUDE.md carries the refusal's sentence" ok
else check "payload/CLAUDE.md carries the refusal's sentence" "not found in $RULES"; fi
line="$(grep -F "A commit message goes in a file" "$RULES")"
case "$line" in *"$RULE_WORDS (#1856)."*) check "it sits in the worktree agent rule, citing #1856" ok ;; *) check "it sits in the worktree agent rule, citing #1856" "${line:0:200}" ;; esac

# ---------------------------------------------------------------------------------------------
echo "settings.hooks.json: the gate runs before every Bash call"
if jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(endswith("/hooks/amend-force-push-gate.sh"))] | length == 1' "$SETTINGS" >/dev/null 2>&1; then
  check "amend-force-push-gate.sh is registered under Bash once" ok
else
  check "amend-force-push-gate.sh is registered under Bash once" "not registered in $SETTINGS"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
