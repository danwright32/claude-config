#!/usr/bin/env bash
# Tests for turn-worked.py, the Stop-hook helper that decides whether the latest turn CHANGED
# anything (claude-config#124).
#
# Everything at the end of a turn hangs off its answer: the reflection, the issue review, the
# memory save. Both ways of being wrong are quiet. Answering "no" on a turn that did work means
# none of those run and nothing says so; answering "yes" on a read-only turn means all of them run
# on a question somebody asked in passing. It had no test.
#
# It also fails safe by printing "no" on any error, which is the right direction and is exactly why
# it needs checking: a helper that answers "no" when it is broken is indistinguishable from one
# answering "no" correctly, and the failure is a review that silently stops happening (L98).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$DIR/turn-worked.py"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-turn-worked: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.turnworked.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-turn-worked: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

user_line() { python3 -c 'import json,sys; print(json.dumps({"type":"user","message":{"content":sys.argv[1]}}))' "$1"; }
tool_line() { python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":sys.argv[1],"input":{}}]}}))' "$1"; }
text_line() { python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":sys.argv[1]}]}}))' "$1"; }
# A tool RESULT arrives as a user-typed message would, except its content is a list of tool_result
# blocks. Telling those apart from a person typing is what decides where the turn began.
result_line() { python3 -c 'import json; print(json.dumps({"type":"user","message":{"content":[{"type":"tool_result","content":"done"}]}}))'; }

answer() { # answer <name> <lines...>  -> runs the helper over a transcript built from the lines
  local f="$TMPROOT/$1.jsonl"; shift
  : > "$f"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
  python3 "$T" "$f" 2>/dev/null
}

# ---------------------------------------------------------------------------
# The two ordinary answers.
# ---------------------------------------------------------------------------
[ "$(answer edited "$(user_line 'fix the bug')" "$(tool_line Edit)")" = "yes" ] \
  && check "a turn that edited a file counts as work" ok \
  || check "a turn that edited a file counts as work" "it said no"
[ "$(answer ran "$(user_line 'what does this do')" "$(tool_line Bash)")" = "yes" ] \
  && check "a turn that ran a command counts as work" ok \
  || check "a turn that ran a command counts as work" "it said no"
[ "$(answer readonly "$(user_line 'what does this do')" "$(tool_line Read)" "$(tool_line Grep)" "$(text_line 'it parses the config')")" = "no" ] \
  && check "a turn that only read counts as no work" ok \
  || check "a turn that only read counts as no work" "it said yes"
[ "$(answer chat "$(user_line 'thanks')" "$(text_line 'you are welcome')")" = "no" ] \
  && check "a turn with no tools at all counts as no work" ok \
  || check "a turn with no tools at all counts as no work" "it said yes"

# ---------------------------------------------------------------------------
# Connected apps. These are named by the app rather than by this repo, so the rule is read off the
# NAME, and both halves have to hold: a reading tool must not count and an acting one must.
# ---------------------------------------------------------------------------
[ "$(answer mcpread "$(user_line 'check my calendar')" "$(tool_line mcp__claude_ai_Google_Calendar__list_events)")" = "no" ] \
  && check "a connected app tool that only reads counts as no work" ok \
  || check "a connected app tool that only reads counts as no work" "it said yes"
[ "$(answer mcpwrite "$(user_line 'book it')" "$(tool_line mcp__claude_ai_Google_Calendar__create_event)")" = "yes" ] \
  && check "a connected app tool that acts counts as work" ok \
  || check "a connected app tool that acts counts as work" "it said no"
[ "$(answer mcpsend "$(user_line 'tell the channel')" "$(tool_line mcp__claude_ai_Slack__slack_send_message)")" = "yes" ] \
  && check "sending a message counts as work" ok \
  || check "sending a message counts as work" "it said no"

# ---------------------------------------------------------------------------
# Where the turn BEGINS. Only a message the person actually typed ends the scan; a tool result
# arrives shaped like a user message and must not, or a turn is cut short at its own tool output
# and the work before it goes unseen.
# ---------------------------------------------------------------------------
[ "$(answer prevturn "$(user_line 'first thing')" "$(tool_line Edit)" "$(user_line 'now just tell me something')" "$(tool_line Read)")" = "no" ] \
  && check "work in an EARLIER turn does not count for this one" ok \
  || check "work in an EARLIER turn does not count for this one" "it said yes"
[ "$(answer toolresult "$(user_line 'do the thing')" "$(tool_line Edit)" "$(result_line)" "$(tool_line Read)")" = "yes" ] \
  && check "a tool result does not end the turn the way a typed message does" ok \
  || check "a tool result does not end the turn the way a typed message does" "it said no, so the turn was cut short at its own tool output"

# ---------------------------------------------------------------------------
# Failing safe, which is the right direction and the one that hides. Each of these must answer, and
# answer "no", rather than crashing and leaving the caller with nothing.
# ---------------------------------------------------------------------------
out_missing="$(python3 "$T" "$TMPROOT/never-written.jsonl" 2>/dev/null)"; code_missing=$?
[ "$out_missing" = "no" ] && [ "$code_missing" -eq 0 ] \
  && check "a transcript that is not there answers no rather than crashing" ok \
  || check "a transcript that is not there answers no rather than crashing" "out=$out_missing exit=$code_missing"
BROKEN="$TMPROOT/broken.jsonl"; printf 'not json\n{"type":"assistant"\n' > "$BROKEN"
[ "$(python3 "$T" "$BROKEN" 2>/dev/null)" = "no" ] \
  && check "lines that do not parse are skipped rather than fatal" ok \
  || check "lines that do not parse are skipped rather than fatal" "it did not answer no"
# The control for the pair above: a transcript that IS readable and DOES hold work must say yes, or
# every "no" here is satisfied by a helper that can only ever say no (L159).
[ "$(answer control "$(user_line 'go')" "$(tool_line Write)")" = "yes" ] \
  && check "the control: it can say yes at all" ok \
  || check "the control: it can say yes at all" "it never says yes, so every 'no' above proves nothing"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
