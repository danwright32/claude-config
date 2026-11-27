#!/usr/bin/env bash
# Tests for what the Slack drafts gate does with an operator that a backslash and a line break
# split (claude-config#3504).
#
# A shell takes a backslash and the line break after it out of a text before it reads words. So a
# dollar sign, the pair and a parenthesis is a command substitution in bash, sh and dash, and in
# zsh outside double quotes; a less than sign, the pair and another opens a heredoc. The shared
# reader (lib/shell-words.py commands()) went past the pair and read the two characters apart, so
# a post written inside such a substitution was never shown to the gate, and a post after such a
# heredoc was hidden by an apostrophe in its body. The shells do not agree with each other on
# these, so the reader names the operator as one it is not sure of, and the gate refuses the
# command as a check it could not make. test-shell-words-split-operators.sh holds the reader
# against the shells themselves; this suite holds the gate's answer.
#
# Kept apart from the other suites of the gate so none of them grows (the precedent is
# test-slack-drafts-comment-start.sh, claude-config#3464); the helpers below are copied from that
# suite as they are, so a case here is driven the same way: a hook payload piped into
# slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason on stderr. Nothing a case
# names is ever run.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/slack-drafts-only-gate.sh"
unset SLACK_GATE_UNWORKED_PATHS

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no slack-drafts-only-gate.sh beside this suite at $DIR, so no Slack send is refused."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
# Every case runs with a judgement cache of its own, never this Mac's (claude-config#2918).
export SLACK_GATE_CACHE_DIR="$T/gate-cache"
unset SLACK_GATE_CACHE_TRACE

# payload <tool name> <tool_input JSON> [cwd]: one PreToolUse payload in the measured shape.
payload() {
  python3 -c '
import json, sys
tool, inp, cwd = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
                  "transcript_path": "/tmp/transcript.jsonl", "cwd": cwd,
                  "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": inp, "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "$1" "$2" "${3:-$T}"
}
bash_input() { python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1], "description": "d"}))' "$1"; }

RC=0; OUT=""; ERR=""
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run_bash() { run_raw "$(payload Bash "$(bash_input "$1")" "${2:-$T}")"; }

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }

POST="curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage"
BS='\'
NL=$'\n'
LT='<'
shown() { printf '%s' "${1//$NL/ (line break) }"; }
# A backslash and a line break, the pair that splits an operator in every case below.
J="$BS$NL"

echo "slack drafts only: a post behind an operator a backslash and a line break split is refused (claude-config#3504)"

run_bash "echo \"\$($POST)\"${NL}echo done"
refused "the control: with nothing split, the post in a substitution is refused"
says "the control: as the post it is" "REFUSED: this command posts to Slack"

# Each of these ran its post in a shell on the Mac it was measured on (2026-11-26: bash 3.2, sh and
# dash for all of them but the process substitution, which only bash runs, and the here string,
# which bash and sh run; zsh for the substitution outside quotes, in a heredoc's body, in
# backquotes and in a parameter's word, and for the dollar quote), and the reader listed no post.
for hides in "echo \"\$$J($POST)\"" \
  "echo \$$J($POST)" \
  "echo \"\$$J$J($POST)\"" \
  "cat $LT${LT}E${NL}\$$J($POST)${NL}E" \
  "echo \`echo \$$J($POST)\`" \
  "echo \`echo \"\$$BS$J($POST)\"\`" \
  "echo \${x:-\$$J($POST)}" \
  "echo \"\$(echo \"\$$J($POST)\")\"" \
  "cat $LT$J${LT}E${NL}'${NL}E${NL}$POST #'" \
  "cat $LT$J$LT${LT}E${NL}$POST${NL}E" \
  "cat $LT$J($POST)" \
  "echo \$$J'a$BS' b' ; $POST #'" \
  "case y in x) : ;$J; y) $POST ;; esac"; do
  run_bash "$hides${NL}echo done"
  refused "a post behind a split operator is refused: $(shown "$hides")"
  says "as a check the gate could not make: $(shown "$hides")" "REFUSED: the gate could not check whether this command posts to Slack"
done

# Where zsh ends the double quotes before the post and bash reads the post as text inside the
# substitution, the reader's own reading already listed the post. It is still refused.
run_bash "echo \"\$$J(echo \" ; $POST ; echo \")\"${NL}echo done"
refused "a post zsh runs after a split \$( that bash reads as text is refused"

# What was refused before stays refused, and as the post it is: the pair where it splits nothing.
for kept in "echo a $J  b; $POST" "true && $J$POST" "echo a |$J cat; $POST" "echo \"a $LT$J$LT b\"; $POST"; do
  run_bash "$kept${NL}echo done"
  refused "as before, a post on a continued line is refused: $(shown "$kept")"
  says "as the post it is: $(shown "$kept")" "REFUSED: this command posts to Slack"
done

# The controls: text the shells do not run is still nobody's command. An escaped \$ starts no
# substitution, a quoted heredoc's body keeps the pair as text, and so does a value assigned in
# single quotes (no shell ran the marker in the first two, test-shell-words-split-operators.sh).
for quiet in "echo \"$BS\$$J($POST)\"" \
  "cat $LT$LT'E'${NL}\$$J($POST)${NL}E" \
  "x='\$$J($POST)'" \
  "echo '\$($POST)'"; do
  run_bash "$quiet${NL}echo done"
  allowed "the control: a post in text no shell runs passes as before: $(shown "$quiet")"
done
# The cost, measured here and kept in view. The gate also reads the text a command prints as
# commands, and refuses whatever reading names something it is not sure of. So text that only
# PRINTS a split operator in front of an endpoint is refused as a check the gate could not make,
# where the same text with nothing split passes (the last control above): in single quotes, and
# in double quotes after two backslashes, which print one backslash and the line break. No shell
# runs either. No command in this Mac's session records holds the shape (the count of #3504).
for printed in "echo '\$$J($POST)'" "echo \"\$$BS$J($POST)\""; do
  run_bash "$printed${NL}echo done"
  refused "text that prints a split operator in front of an endpoint is refused: $(shown "$printed")"
  says "as a check the gate could not make, never as a post: $(shown "$printed")" "REFUSED: the gate could not check whether this command posts to Slack"
done
# And a continued line that splits nothing, in a command that posts nothing, is no reason to
# refuse, where the reader starts (a shell is named) as much as where it does not.
for quiet in "echo a $J  b${NL}sh -c 'echo quiet'" "true && $J echo b${NL}sh -c 'echo quiet'" \
  "echo \"a $LT$J$LT b\"${NL}sh -c 'echo quiet'" "echo a $J  b"; do
  run_bash "$quiet"
  allowed "the control: a quiet command with a continued line passes: $(shown "$quiet")"
done

# The wrapper looks at the whole payload before it starts the reader, and starts it only where the
# payload names something that could reach a post. A split operator in a command that names
# nothing of the kind is answered by that look alone, as it was. Where the payload does name
# something that could reach one (a shell, here), the reader starts, names the operator, and the
# gate refuses a command it could not check, though nothing in it posts: the cost of not knowing
# which shell reads it.
TRACE="$T/reader-started"
run_seen() { rm -f "$TRACE"; SLACK_GATE_CACHE_TRACE="$TRACE" run_bash "$1" "${2:-$T}"; }
# unread <label>: allowed by the wrapper's own look, the reader never started.
unread() {
  if [ "$RC" -eq 0 ] && [ ! -e "$TRACE" ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
  else check "$1" "exit $RC, the reader $([ -e "$TRACE" ] && echo started || echo 'did not start'), stderr: ${ERR:0:300}"; fi
}
# read_through <label>: the reader started, whatever it then answered.
read_through() { if [ -e "$TRACE" ]; then check "$1" ok; else check "$1" "the reader did not start (exit $RC)"; fi; }
run_seen "echo \"\$$J($POST)\"${NL}echo done"
read_through "the control of that measure: for a command that names an endpoint, the reader starts"
run_seen "echo \"\$$J(echo hi)\"${NL}echo done"
unread "a split \$( in a command that names nothing that could post is answered by the wrapper's look, as before"
run_seen "echo \"\$$J(sh -c 'echo hi')\"${NL}echo done"
read_through "a split \$( in a command that names a shell reaches the reader"
refused "and is refused, since the gate cannot tell which shell reads it"
says "as a check it could not make, never as a post" "REFUSED: the gate could not check whether this command posts to Slack"

# A run that checked nothing must not read as a pass.
[ "$pass" -ge 49 ] || check "the suite checked its cases" "only $pass checks passed, of the 54 the cases make"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
