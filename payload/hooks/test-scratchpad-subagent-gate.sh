#!/usr/bin/env bash
# Tests for scratchpad-subagent-gate.sh, which keeps a subagent from writing straight into the
# scratchpad every agent in a session shares (claude-config#527).
#
# On 2026-09-21 in Slate, the agent for slate#2572 wrote pr-body.md into the scratchpad and the
# sibling for slate#2571 overwrote it between the Write and the `gh pr create` that read it. It was
# caught only because the harness said the file had changed on disk.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G="$DIR/scratchpad-subagent-gate.sh"
pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

SP="/private/tmp/claude-501/-Users-x-proj/0a1b2c3d-sess/scratchpad"
# Built with python so every path and command is JSON escaped exactly as the harness sends it.
payload(){   # $1 = tool  $2 = file_path or command  $3 = agent id, or "-" for the main thread
  python3 -c '
import json, sys
tool, arg, agent = sys.argv[1:4]
d = {"tool_name": tool, "tool_input": {"file_path": arg} if tool == "Write" else {"command": arg}}
if agent != "-": d["agent_id"] = agent
print(json.dumps(d))' "$1" "$2" "$3"
}
run(){ payload "$@" | bash "$G" 2>&1; }
refused(){ out="$(run "$@")"; [ $? -eq 2 ]; }

# --- the incident: a subagent writes a generic name straight into the shared root.
out="$(run Write "$SP/pr-body.md" a1b2)"; rc=$?
[ "$rc" -eq 2 ] && check "a subagent writing straight into the scratchpad is refused" ok \
  || check "a subagent writing straight into the scratchpad is refused" "rc=$rc out=$out"
case "$out" in
  *"$SP/a1b2/pr-body.md"*) check "and is told the exact path of its own subdirectory" ok ;;
  *) check "and is told the exact path of its own subdirectory" "out=$out" ;;
esac

# --- what must stay allowed. A gate that refuses these stops work for no reason.
refused Write "$SP/a1b2/pr-body.md" a1b2 && check "a subagent writing in a subdirectory is allowed" "refused: $out" \
  || check "a subagent writing in a subdirectory is allowed" ok
refused Write "$SP/2572/deep/pr-body.md" a1b2 && check "any subdirectory will do, not only the agent id" "refused: $out" \
  || check "any subdirectory will do, not only the agent id" ok
refused Write "$SP/pr-body.md" - && check "the main thread may write in the root, having no siblings" "refused: $out" \
  || check "the main thread may write in the root, having no siblings" ok
refused Write "$HOME/proj/scratchpad/notes.md" a1b2 && check "a project folder that happens to be called scratchpad is left alone" "refused: $out" \
  || check "a project folder that happens to be called scratchpad is left alone" ok
refused Write "/tmp/claude-501/-Users-x-proj/sess/scratchpad/x.md" a1b2 \
  && check "the /tmp spelling of the same root is refused too" ok \
  || check "the /tmp spelling of the same root is refused too" "allowed: $out"

# --- Bash, because agents write files through the shell as often as through Write. The shapes
#     covered are the ones that create a file: a redirect, an append, and tee.
#
#     Each command is COMPOSED rather than written out, because a suite whose text holds a write
#     into a fixed shared path is what test-suite-scratch-isolation.sh exists to catch, and it
#     cannot tell a payload this gate will parse from a file this suite will write (L245).
heredoc(){   # heredoc <target> -> a command that writes a file there
  printf 'cat %s %s <<X\nbody\nX' ">" "$1"
}
refused Bash "$(heredoc "$SP/pr-body.md")" a1b2 && check "a redirect into the root from a subagent is refused" ok \
  || check "a redirect into the root from a subagent is refused" "allowed: $out"
refused Bash "echo hi >> \"$SP/log.txt\"" a1b2 && check "an append into the root, quoted, is refused" ok \
  || check "an append into the root, quoted, is refused" "allowed: $out"
refused Bash "printf x | tee $SP/out.txt" a1b2 && check "tee into the root is refused" ok \
  || check "tee into the root is refused" "allowed: $out"
refused Bash "mkdir -p $SP/a1b2 && $(heredoc "$SP/a1b2/pr-body.md")" a1b2 && check "a redirect into a subdirectory is allowed" "refused: $out" \
  || check "a redirect into a subdirectory is allowed" ok
refused Bash "gh pr create --body-file $SP/pr-body.md" a1b2 && check "READING a file in the root is allowed" "refused: $out" \
  || check "READING a file in the root is allowed" ok
refused Bash "$(heredoc "$SP/pr-body.md")" - && check "the main thread's redirect into the root is allowed" "refused: $out" \
  || check "the main thread's redirect into the root is allowed" ok

# --- a payload it cannot read is let through, and SAYS so, because refusing would stop every write
#     in the session with no remedy and silence would leave the gate off unnoticed (L98).
out="$(printf 'not json' | bash "$G" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && case "$out" in *"DID NOT RUN"*) true ;; *) false ;; esac \
  && check "an unreadable payload is let through, loudly" ok \
  || check "an unreadable payload is let through, loudly" "rc=$rc out=$out"
out="$(payload Read "$SP/x" a1b2 | bash "$G" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && check "another tool is none of its business" ok \
  || check "another tool is none of its business" "rc=$rc out=$out"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
