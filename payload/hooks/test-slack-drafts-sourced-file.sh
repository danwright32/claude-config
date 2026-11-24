#!/usr/bin/env bash
# Tests for what the Slack drafts gate says of a file a shell's string reads in, where the file moves
# the string's positional parameters from somewhere its own words do not show (claude-config#3474).
#
# A `bash -c '<string>' x a b` string shares its $1, $2... with every file it reads in with a dot
# command or `source`, so a file that shifts them changes which file a later `. "$1/lib/x.sh"` reads.
# The gate asked that of the file's own text alone (sh_keeps_positional looked for a shift or a set),
# and two routes move them with neither word in the file:
#
# 1. The file hands text to eval, and the text shifts.
# 2. The file reads in a second file, and the second file shifts.
#
# Measured 2026-11-24 on main at 44cb7cec60, through this wrapper: both were read as leaving the
# parameters alone and the command exited 0, with the gate reading calm/lib/x.sh while bash 3.2.57
# and zsh 5.9 each read in hot/lib/x.sh (the same fixtures with the two x.sh files printing their
# folder's name). The control whose file is the one line `shift` was refused.
#
# Now a file keeps the parameters only where every eval and every read of another file in it is
# accounted for: inside a function's body or a subshell, which have parameters of their own, or a
# read whose path the gate works out and whose file, followed the same way to its end, keeps them
# too. Anything else is answered as not keeping them, and the gate's existing refusal of a path it
# cannot work out follows.
#
# Kept apart from test-slack-drafts-only-gate.sh, which covers the string's own commands, so it does
# not grow (the precedent is test-slack-drafts-comment-start.sh, claude-config#3464); the helpers
# below are copied from that suite as they are, so a case here is driven the same way: a hook
# payload piped into slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason on stderr.
# Nothing a case names is ever run.
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
UNSURE="REFUSED: the gate could not check whether this command posts to Slack"

# calm/lib/x.sh is quiet and hot/lib/x.sh posts. The string reads in a file from lib/ and then the
# x.sh under its $1, so which x.sh the shell reads depends on whether that file moved the
# parameters: the gate must not read calm's while the shell reads hot's.
P="$T/p3474"
mkdir -p "$P/calm/lib" "$P/hot/lib" "$P/lib"
printf '%s\n' 'echo ok' > "$P/calm/lib/x.sh"
printf '%s\n' "$POST" > "$P/hot/lib/x.sh"
printf '%s\n' 'shift' > "$P/lib/mover.sh"
printf '%s\n' 'echo quiet' > "$P/lib/quiet.sh"
printf '%s\n' 'shift' > "$P/lib/steps.txt"
# reads <file under lib/> <the words after the string's $0>: the command under test.
reads() { run_bash "bash -c '. lib/$1; . \"\$1/lib/x.sh\"' x $2" "$P"; }
# file <name> <line>...: a file of those lines under lib/.
file() {
  local name="$1"
  shift
  printf '%s\n' "$@" > "$P/lib/$name.sh"
}
# moved <name> <what it is> <line>...: a file of those lines, which the shells read hot's x.sh after,
# so it must be answered as one that may have moved the parameters: refused, as a check the gate
# could not make, on the $1 that is no longer certain.
moved() {
  local name="$1" what="$2"
  shift 2
  file "$name" "$@"
  reads "$name.sh" "calm hot"
  refused "$what is read as one that may move the parameters: $*"
  says "and it is refused as a check the gate could not make: $*" "$UNSURE"
  says "and on the \$1 that is no longer certain: $*" "\$1 is not certain there"
}
# kept <name> <what it is> <line>...: a file of those lines, which the shells read calm's x.sh
# after. It passes with the quiet file under $1, and with the file that posts there it is refused as
# the post the gate read, so the pass is a file read and not a file skipped.
kept() {
  local name="$1" what="$2"
  shift 2
  file "$name" "$@"
  reads "$name.sh" "calm hot"
  allowed "$what leaves \$1, and the quiet file under it passes: $*"
  reads "$name.sh" "hot calm"
  refused "and with the file that posts under \$1 it is refused: $*"
  says "as the post it read: $*" "REFUSED: this command posts to Slack"
}

echo "slack drafts only: the controls, a file that moves nothing and a file that shifts (claude-config#3474)"

reads quiet.sh "calm hot"
allowed "the control: a file that moves nothing leaves \$1, and the quiet file under it passes"
reads quiet.sh "hot calm"
refused "the control: and the file that posts under \$1 is refused"
reads mover.sh "calm hot"
refused "the control: a file that is the one line shift is read as moving the parameters"
says "the control: and that refusal is on the \$1 that is no longer certain" "\$1 is not certain there"

echo "slack drafts only: a file that hands text to eval may have moved the parameters (claude-config#3474)"

moved e1 "a file that evaluates a variable's text" 'eval "$PREPARE"'
moved e2 "a file that evaluates what a command prints" 'eval "$(cat lib/steps.txt)"'
moved e3 "a file that evaluates a word it builds" 'X=ift' 'eval "sh$X"'
moved e4 "a file whose eval is behind command" 'command eval "$PREPARE"'
moved e5 "a file whose eval is behind builtin" 'builtin eval "$PREPARE"'
moved e6 "a file whose eval is inside an if" 'if true; then eval "$PREPARE"; fi'
moved e7 "a file whose eval is the first command of a case branch" 'case x in' '  x) eval "$PREPARE" ;;' 'esac'
moved e8 "a file whose eval follows &&" 'true && eval "$PREPARE"'
moved e9 "a file whose eval is inside a group" '{ eval "$PREPARE"; }'
moved e10 "a file whose eval is written with a backslash" "${BS}eval \"\$PREPARE\""
moved e11 "a file whose eval is written in quotes" '"eval" "$PREPARE"'
moved e12 "a file whose eval is inside a loop" 'for turn in 1; do' '  eval "$PREPARE"' 'done'
# An eval right after a function's body or a subshell is outside it, at the file's top level.
moved e13 "a file whose eval follows a function's closing brace" 'f() {' '  echo hi' '}' 'eval "$PREPARE"'
moved e14 "a file whose eval follows a function on its line" 'f() { echo hi; }; eval "$PREPARE"'
moved e15 "a file whose eval follows a subshell" '( echo hi ); eval "$PREPARE"'
moved e16 "a file whose eval follows a function inside a function" 'f() {' '  g() { echo hi; }' '}' 'eval "$PREPARE"'

echo "slack drafts only: a file that reads in a second file is followed to that file's end (claude-config#3474)"

moved d1 "a file that reads in a file that shifts, with a dot command," '. lib/mover.sh'
moved d2 "a file that reads in a file that shifts, with source," 'source lib/mover.sh'
moved d3 "a file that reads in a file that reads in a file that shifts" '. lib/d1.sh'
moved d4 "a file whose read of the file that shifts is inside an if" 'if true; then . lib/mover.sh; fi'
moved d5 "a file whose read of the file that shifts is the first command of a case branch" 'case x in' '  x) . lib/mover.sh ;;' 'esac'
moved d6 "a file whose read of the file that shifts follows &&" 'true && . lib/mover.sh'
moved d7 "a file whose read of the file that shifts is behind command" 'command . lib/mover.sh'
moved d8 "a file whose read of the file that shifts is behind builtin" 'builtin source lib/mover.sh'
moved d9 "a file whose dot command is written with a backslash" "$BS. lib/mover.sh"
moved d10 "a file whose dot command is written in quotes" '"." lib/mover.sh'
moved d11 "a file that reads in the file that shifts by a path its own variable holds" 'D=lib' '. "$D/mover.sh"'
moved d12 "a file that reads in the file that shifts beside itself" '. "${BASH_SOURCE[0]%/*}/mover.sh"'
moved d13 "a file that reads in a quiet file and then the file that shifts" '. lib/quiet.sh' '. lib/mover.sh'
moved d14 "a file whose second file evaluates text" '. lib/e1.sh'
moved d16 "a file whose read of the file that shifts follows a function's closing brace" 'f() {' '  echo hi' '}' '. lib/mover.sh'
# One file read in twice, from two directories, reads in a different lib/y.sh each time: the quiet
# one from here, and from calm/ the one that shifts. The first reading does not answer for the second.
printf '%s\n' 'echo quiet' > "$P/lib/y.sh"
printf '%s\n' 'shift' > "$P/calm/lib/y.sh"
file hop '. lib/y.sh'
moved d17 "a file that reads one file in twice, the second time from a directory where it shifts," \
  ". $P/lib/hop.sh" "cd $P/calm" ". $P/lib/hop.sh" "cd $P"
# A second file the gate cannot work out the path of was refused before, for that path, and still is.
file d15 '. "$LIBS/mover.sh"'
reads d15.sh "calm hot"
refused "as before, a file that reads in a file by a path the gate cannot work out is refused"
says "as before, as a check the gate could not make" "$UNSURE"
# Five files each reading in the next is one more than the gate follows (MAX_DEPTH files below the
# one the string names), so the last, which is quiet, is not read and the first is not known to keep.
file k4 'echo quiet'
file k3 '. lib/k4.sh'
file k2 '. lib/k3.sh'
file k1 '. lib/k2.sh'
file k0 '. lib/k1.sh'
reads k0.sh "calm hot"
refused "a chain of files one longer than the gate follows is not known to keep the parameters"

echo "slack drafts only: a file whose eval or second file cannot reach the string's parameters keeps them (claude-config#3474)"

kept n1 "a file that reads in a quiet file" '. lib/quiet.sh'
kept n2 "a file that reads in a file that reads in a quiet file" '. lib/n1.sh'
kept n3 "a file that reads in a quiet file by a path its own variable holds" 'D=lib' '. "$D/quiet.sh"'
kept n4 "a file that reads in a quiet file beside itself" '. "${BASH_SOURCE[0]%/*}/quiet.sh"'
kept n5 "a file that reads in a quiet file inside an if" 'if true; then . lib/quiet.sh; fi'
kept n6 "a chain of files as long as the gate follows" '. lib/k2.sh'
# A function has positional parameters of its own, so an eval or a read inside its body moves the
# function's and never the string's (bash 3.2.57 and zsh 5.9 both read calm's x.sh after each).
kept f1 "a file whose eval is inside a function it calls" 'f() { eval "$PREPARE"; }' 'f'
kept f2 "a file whose read of the file that shifts is inside a function it calls" 'f() { . lib/mover.sh; }' 'f'
kept f3 "a file whose function, over several lines, evaluates and reads in a file" \
  'prepare() {' '  local step="$1"' '  eval "$step"' '  . lib/mover.sh' '}' 'prepare "$PREPARE"'
# So has a subshell, and a substitution.
kept s1 "a file whose eval is inside a subshell" '( eval "$PREPARE" )'
kept s2 "a file whose read of the file that shifts is inside a substitution" 'X="$(. lib/mover.sh; echo done)"'
# A comment naming the words runs nothing.
kept c1 "a file whose comments name eval, source and a dot command" \
  '# eval the words here, then source or . the file' 'echo ok # eval and . lib/mover.sh' '  # source lib/mover.sh'

echo "slack drafts only: the repository's own way of calling a helper in a shell of its own still passes (claude-config#3474)"

# test-sleep-state.sh hands lib/suite-deadline.sh to a `bash -c` string as $1 and its helper as $2,
# and reads in both. That library reads in other files, inside its functions and inside an if that
# runs only where it is run by name, so it is the one file of this repository the question is asked
# of: it must still be read as keeping $2, or the gate refuses that suite's own run.
real() { run_bash "bash -c '. \"\$1\"; suite_deadline_arm; . \"\$2\"; echo ok' _ $DIR/lib/suite-deadline.sh $1" "$P"; }
real "$P/calm/lib/x.sh"
allowed "lib/suite-deadline.sh, read in first, leaves \$2, and the quiet file under it passes"
real "$P/hot/lib/x.sh"
refused "and with the file that posts under \$2 it is refused"
says "as the post it read" "REFUSED: this command posts to Slack"

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
