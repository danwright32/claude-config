#!/usr/bin/env bash
# WHOLE-HOOK tests for pr-merge-quiz.sh: feeds it real PostToolUse(Bash) payloads and asserts
# whether it FIRES (emits a decision:block instruction telling Claude to run the comprehension
# quiz) or STAYS QUIET (exit 0, no output).
#
# The hook fires only on a `gh pr merge` command. It deliberately does NOT try to judge from the
# shell whether the merge succeeded or whether the change is trivial: both of those are handed to
# Claude in the injected instruction, which can see the real command output and the diff. So these
# tests only pin down the ONE thing the shell owns: did this command merge a PR, and should the
# quiz instruction fire.
#
# The matcher works on the LEADING TOKENS of each shell segment, never anywhere in the string, so a
# command whose PAYLOAD merely mentions "gh pr merge" (an echo, an issue comment) must not fire.
# Same command-vs-payload distinction that check-closing-keyword.sh had to learn the hard way.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/pr-merge-quiz.sh"

pass=0
fail=0

# run <description> <fire|skip> <command-string> [env-assignment]
# Builds a PostToolUse payload, pipes it to the hook, and checks stdout for a decision:block.
run() {
  local desc="$1" want="$2" command="$3" envassign="${4:-}"
  local payload out fired
  payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": "/tmp"}))
' "$command")"
  if [ -n "$envassign" ]; then
    out="$(printf '%s' "$payload" | env "$envassign" "$HOOK" 2>/dev/null)"
  else
    out="$(printf '%s' "$payload" | "$HOOK" 2>/dev/null)"
  fi
  if printf '%s' "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    fired="fire"
  else
    fired="skip"
  fi
  if [ "$fired" = "$want" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo "FAIL: $desc (wanted $want, got $fired)"
  fi
}

# --- A real merge must fire ---
run "a plain merge by number"        fire 'gh pr merge 42'
run "a squash auto-merge"            fire 'gh pr merge --squash --auto'
run "a merge of the current branch"  fire 'gh pr merge'
run "an env-prefixed merge"          fire 'GH_TOKEN=abc gh pr merge 42'
run "a merge at the end of a chain"  fire 'git fetch origin && gh pr merge 42 --squash'

# --- Things that are not a merge must stay quiet ---
run "closing without merging"        skip 'gh pr close 42'
run "viewing a pr"                   skip 'gh pr view 42 --json state'
run "a plain push"                   skip 'git push -u origin branch'
run "creating a pr"                  skip 'gh pr create --title x --body y'

# --- A command is not its payload: a mere mention of the phrase must not fire ---
run "an echo of the phrase"          skip 'echo "gh pr merge 42"'
run "an issue comment mentioning it" skip 'gh issue comment 5 --body "then run gh pr merge"'
run "a grep for the phrase"          skip 'grep -r "gh pr merge" .'

# --- The override, and the detached-run guard ---
run "the documented override"        skip 'SKIP_PR_QUIZ=1 gh pr merge 42'
run "a detached headless run"        skip 'gh pr merge 42' 'CLAUDE_DETACHED_RUN=1'

# --- Failure path: a broken or empty payload must fail QUIET, never fire or crash ---
raw() {
  local desc="$1" want="$2" rawpayload="$3"
  local out fired
  out="$(printf '%s' "$rawpayload" | "$HOOK" 2>/dev/null)"
  if printf '%s' "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then fired="fire"; else fired="skip"; fi
  if [ "$fired" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $desc (wanted $want, got $fired)"; fi
}
raw "a malformed json payload"       skip 'not json at all'
raw "a payload with no command"      skip '{"tool_input":{},"cwd":"/tmp"}'
raw "an empty payload"               skip ''

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
