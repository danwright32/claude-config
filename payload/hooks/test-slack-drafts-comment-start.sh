#!/usr/bin/env bash
# Tests for where the Slack drafts gate takes a shell comment to start (claude-config#3464).
#
# Two of its readers decided that by a rule the shell does not follow, so text the shell runs was
# dropped before the gate judged it:
#
# 1. The shared reader (lib/shell-words.py commands()) took a # for a comment whenever the character
#    before it was white space, a separator or a parenthesis. The shell starts a comment only where
#    a word starts, so after an escaped space, right after the ) of a substitution, or on a line a
#    backslash joined to a word, it read the # as text and ran the command after the ; while the
#    gate judged a line that ended at the #. Measured 2026-11-22 on main at 2522b81440, through this
#    wrapper: a command ending in an escaped space and a #, then a ; and a post, then a second line,
#    exited 0, and its control with no # was refused.
# 2. sh_keeps_positional removed every # after white space to the end of its line, quoted or not,
#    from the text of a file a `bash -c` string reads in, before looking for a shift or a set. With
#    a quoted # before a shift in that file the gate kept the string's $1 where the shell had moved
#    to $2, and read one file while the shell read in another. Same day, same wrapper: exit 0, and
#    the control whose file is the one line `shift` was refused.
#
# Both ask one rule now, lib/shell-words.py word_starts, which test-shell-words-comment-start.sh
# holds against the shells themselves. Kept apart from test-slack-drafts-only-gate.sh and
# test-slack-drafts-code-loaders.sh, which cover the two readers, so neither grows (the precedent is
# test-slack-drafts-unread-shapes.sh, claude-config#3251); the helpers below are copied from them as
# they are, so a case here is driven the same way: a hook payload piped into
# slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason on stderr. Nothing a case names
# is ever run.
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
shown() { printf '%s' "${1//$NL/ (line break) }"; }

echo "slack drafts only: a # the shell reads inside a word hides nothing after it (claude-config#3464)"

run_bash "echo see 3; $POST${NL}echo done"
refused "the control: with no # the post after the ; is refused"
says "the control: as the post it is" "REFUSED: this command posts to Slack"
run_bash "echo see$BS # 3; $POST${NL}echo done"
refused "the measured shape: a post after an escaped space and a # is refused"
says "the measured shape: as a check it could not make" "REFUSED: the gate could not check whether this command posts to Slack"
says "the measured shape: naming the # and the line it is on" "it holds a # the gate cannot tell from a comment, in the line \`echo see$BS # 3; $POST\`"
for hides in "echo see$BS #3; $POST" \
  "echo see$BS$BS$BS # 3; $POST" \
  "echo a$BS;# c; $POST" \
  "echo a$BS&# c; $POST" \
  "echo a$BS)# c; $POST" \
  "echo \$(echo b)# c; $POST" \
  "cat <(echo b)# c; $POST" \
  "echo \$((1))# c; $POST" \
  "echo a$BS${NL}# c; $POST" \
  "echo a$BS $BS${NL}# c; $POST" \
  "echo \$(echo b)$BS${NL}# c; $POST" \
  "x=(a b)# c; $POST" \
  "x=(a$BS # c \$($POST)${NL})" \
  "echo \`echo a # c\`; $POST" \
  "echo \`echo a$BS$BS # c; $POST${NL}\`" \
  "cat <<E${NL}\$(echo a$BS # c; $POST${NL})${NL}E"; do
  # On two lines, since a command with no line break is read with "; " ending a comment, which reads
  # the post either way.
  run_bash "$hides${NL}echo done"
  refused "a post after a # the shell reads inside a word is refused: $(shown "$hides")"
done
# What was refused before stays refused: a # that is escaped, quoted, or inside a word.
for kept in "echo $BS# c; $POST" "echo 'a # c'; $POST" "echo \"a # c\"; $POST" "echo \$'a # c'; $POST" \
  "echo \$#; $POST" "echo \${#x}; $POST" "echo a#b; $POST"; do
  run_bash "$kept"
  refused "as before, a post after a # that starts no word is refused: $kept"
done
# A real comment read as text would hide a command as well: its apostrophe would open a string
# around the next line. The comment is still one, so the post on the line after it is read.
run_bash "echo a $BS$BS # it's${NL}$POST${NL}echo 'x'"
refused "a post on the line after a real comment that holds an apostrophe is refused"
run_bash "echo a # it's${NL}$POST${NL}echo 'x'"
refused "and the same after a plain space"
# The controls: a real comment is still nobody's text, so a post written in one runs nowhere.
for quiet in "echo see # 3; $POST${NL}echo done" \
  "echo a${NL}# $POST${NL}echo done" \
  "# $POST" \
  "echo a;# $POST" \
  "echo a $BS$BS # c; $POST${NL}echo done" \
  "(echo a)# c; $POST${NL}echo done" \
  "echo a $BS${NL}# c; $POST${NL}echo done" \
  "echo \$(echo b) # c; $POST${NL}echo done"; do
  run_bash "$quiet"
  allowed "the control: a post written in a real comment passes as before: $(shown "$quiet")"
done
# A command with no line break is read with "; " ending a comment, so a post after one there was
# refused, where the shell runs nothing. That stays as it was.
for kept in "echo a # c; $POST" "echo a $BS$BS # c; $POST" "(echo a)# c; $POST"; do
  run_bash "$kept"
  refused "as before, on one line a post after a comment and a ; is refused: $kept"
done
# A # the reader always read as text, with nothing that posts after it, is no reason to refuse.
for quiet in "echo \$#; echo quiet" "echo a#b" "echo \${#x}; echo quiet" "echo 'a # c'; echo quiet" "echo $BS# c; echo quiet"; do
  run_bash "$quiet"
  allowed "the control: a quiet command after a # that starts no word passes: $quiet"
done
# The wrapper looks at the whole payload before it starts the reader, and starts it only where the
# payload names something that could reach a post: an endpoint, a script file, a shell, an
# interpreter, eval, a dot command, a path that is run. That look takes no # for a comment, here or
# anywhere, so a # can hide nothing from it, and it gives a command the same answer with the # as
# without. Held here by measurement, not by reading the patterns: SLACK_GATE_CACHE_TRACE names a file
# the reader writes a line to as its first step, so a file that is not there after a run is a
# command the wrapper answered by that look alone.
TRACE="$T/reader-started"
run_seen() { rm -f "$TRACE"; SLACK_GATE_CACHE_TRACE="$TRACE" run_bash "$1" "${2:-$T}"; }
# unread <label>: allowed by the wrapper's own look, the reader never started.
unread() {
  if [ "$RC" -eq 0 ] && [ ! -e "$TRACE" ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
  else check "$1" "exit $RC, the reader $([ -e "$TRACE" ] && echo started || echo 'did not start'), stderr: ${ERR:0:300}"; fi
}
# read_through <label>: the reader started, whatever it then answered.
read_through() { if [ -e "$TRACE" ]; then check "$1" ok; else check "$1" "the reader did not start (exit $RC)"; fi; }
run_seen "echo see 3; $POST${NL}echo done"
read_through "the control of that measure: for a command that posts, the reader starts and leaves its line in the file"

# A # the reader would take for a comment where the shell does not, in a command that names nothing
# able to reach a post: the wrapper's look answers it, as it answers the same command without the #.
# Nothing in such a command can post, so there is nothing a refusal would stop.
for calm in "echo see$BS # 3; echo quiet" "echo \$(echo b)# c; echo quiet" "echo a$BS${NL}# c; echo quiet" \
  "x=(a b)# c" "(echo a$BS # c )${NL}echo quiet" "echo see$BS # 3; ls${NL}true"; do
  run_seen "$calm"
  unread "a # the gate cannot tell from a comment, in a command naming nothing that could post, is answered unread: $(shown "$calm")"
  run_seen "${calm//\#/}"
  unread "and the same command with no # is answered the same way: $(shown "${calm//\#/}")"
done
# Where the command names anything that look sends to the reader, the reader refuses the #, quiet
# or not: it does not read the rest of that line, so it cannot say that nothing there posts.
for doubt in "echo see$BS # 3; bash quiet.sh" "echo a$BS # 'x${NL}echo quiet${NL}'" "echo \$(echo b)# c; ./quiet"; do
  run_seen "$doubt"
  refused "a # the gate cannot tell from a comment is refused wherever the reader is started: $(shown "$doubt")"
  says "and as a check it could not make: $(shown "$doubt")" "REFUSED: the gate could not check whether this command posts to Slack"
done
# The same in a script the command runs: the file is read as the command is.
printf '%s\n' '#!/bin/bash' "echo see$BS # 3; $POST" 'echo done' > "$T/hash-posts.sh"
printf '%s\n' '#!/bin/bash' "echo see # 3; $POST" 'echo done' > "$T/hash-quiet.sh"
run_bash "bash hash-posts.sh"
refused "a script whose post follows a # the shell reads inside a word is refused"
run_bash "bash hash-quiet.sh"
allowed "the control: a script whose post is written in a real comment passes"

echo "slack drafts only: a post reached with no posting word in the command is not hidden by such a # either (claude-config#3464)"

# The command names no endpoint: the file it runs holds the post. Each way of running that file,
# after each # the reader would take for a comment where the shell does not, on two lines. The
# wrapper's look must start the reader for every one, and the reader must refuse it.
Q="$T/q3464"
mkdir -p "$Q/hot/lib"
printf '%s\n' "$POST" > "$Q/hot/lib/x.sh"
printf '%s\n' "$POST" > "$Q/hot/lib/x"
printf '%s\n' 'import urllib.request' "urllib.request.urlopen('https://slack.com/api/chat.postMessage', b'text=hi')" > "$Q/hot/lib/p.py"
for reach in "bash hot/lib/x.sh" ". hot/lib/x.sh" "source hot/lib/x.sh" "bash hot/lib/x" ". hot/lib/x" \
  "hot/lib/x.sh" "./hot/lib/x" "eval \"\$(cat hot/lib/x)\"" "cat hot/lib/x | sh" "python3 hot/lib/p.py"; do
  run_seen "echo see 3; $reach${NL}echo done" "$Q"
  refused "the control: with no #, the post is reached and refused: $reach"
  run_seen "echo see # 3; $reach${NL}echo done" "$Q"
  read_through "the control: after a real comment the reader is still started, since the wrapper's look takes no # for a comment: $reach"
  allowed "the control: and the reader, which reads the comment as the shell does, passes it: $reach"
  for front in "echo see$BS # 3" "echo \$(echo b)# c" "echo a$BS${NL}# c" "x=(a b)# c" "echo \`echo a # c\`"; do
    run_seen "$front; $reach${NL}echo done" "$Q"
    refused "a post reached with no posting word is refused after a # the shell reads inside a word: $(shown "$front; $reach")"
    says "and as a check it could not make: $(shown "$front; $reach")" "REFUSED: the gate could not check whether this command posts to Slack"
  done
done

echo "slack drafts only: a quoted # in a file a shell's string reads in hides no shift after it (claude-config#3464)"

# calm/lib/x.sh is quiet and hot/lib/x.sh posts. The string reads in a file from lib/ and then the
# x.sh under its $1, so which x.sh the shell reads depends on whether that file moved the
# parameters: the gate must not read calm's while the shell reads hot's.
P="$T/p3464"
mkdir -p "$P/calm/lib" "$P/hot/lib" "$P/lib"
printf '%s\n' 'echo ok' > "$P/calm/lib/x.sh"
printf '%s\n' "$POST" > "$P/hot/lib/x.sh"
printf '%s\n' 'shift' > "$P/lib/shifter.sh"
printf '%s\n' 'echo quiet' > "$P/lib/quiet.sh"
# reads <file under lib/> <the words after the string's $0>: the command under test.
reads() { run_bash "bash -c '. lib/$1; . \"\$1/lib/x.sh\"' x $2" "$P"; }
# moved <name> <the words> <line>...: a file of those lines, which must be read as moving the parameters.
moved() {
  local name="$1" words="$2"
  shift 2
  printf '%s\n' "$@" > "$P/lib/$name.sh"
  reads "$name.sh" "$words"
  refused "a file that moves the parameters after a # that starts no comment is read as moving them: $*"
}
reads shifter.sh "calm hot"
refused "the control: a file that is the one line shift is read as moving the parameters"
reads quiet.sh "calm hot"
allowed "the control: a file that moves nothing leaves \$1, and the quiet file under it passes"
reads quiet.sh "hot calm"
refused "the control: and the file that posts under \$1 is refused"
moved q1 "calm hot" "echo 'see # 3'; shift"
moved q2 "calm hot" 'echo "see # 3"; shift'
moved q3 "calm hot" "echo \$'see # 3'; shift"
moved q4 "calm hot" "echo see$BS # 3; shift"
moved q5 "calm hot" "X='see" " # 3'; shift"
moved q6 "calm hot" "echo see$BS" "#3; shift"
moved q7 "calm" "echo 'see # 3'; set -- hot"
moved q8 "calm" 'echo "see # 3"; set -- hot'
moved q9 "calm hot" "echo \$(echo b)# 3; shift"
# A file the gate cannot read as the shell does is not one it knows to move nothing.
moved q10 "calm hot" "x=(a b)# 3; shift"
moved q11 "calm hot" "echo 'never closed # 3; shift"
# A file that hands text to eval, or reads in a second file that shifts: whatever the gate says of
# it, a quoted # in front changes nothing about what the shell does, so it must say the same.
printf '%s\n' 'eval "$PREPARE"' > "$P/lib/e0.sh"
printf '%s\n' "echo 'see # 3'; eval \"\$PREPARE\"" > "$P/lib/e1.sh"
printf '%s\n' 'shift' > "$P/lib/mover.sh"
printf '%s\n' '. lib/mover.sh' > "$P/lib/d0.sh"
printf '%s\n' "echo 'see # 3'; . lib/mover.sh" > "$P/lib/d1.sh"
for pair in "e0 e1 eval" "d0 d1 a dot command"; do
  read -r plain hashed what <<< "$pair"
  reads "$plain.sh" "calm hot"
  CRC="$RC"
  reads "$hashed.sh" "calm hot"
  if [ "$RC" -eq "$CRC" ]; then check "a quoted # before $what in the file changes nothing (both exit $CRC)" ok
  else check "a quoted # before $what in the file changes nothing" "exit $RC with the #, $CRC without"; fi
done
# A real comment naming shift or set moves nothing, so such a file passes as before.
printf '%s\n' '# shift the words here, or set -- them' 'echo ok # then shift' '  # set -- x' > "$P/lib/prose.sh"
reads prose.sh "calm hot"
allowed "the control: a file whose comments name shift and set moves nothing, and passes as before"
reads prose.sh "hot calm"
refused "the control: and with the file that posts under \$1 it is refused"
# A comment right after a ; was never left out by the pattern this replaced, so a file with a set
# in one was refused, and still is: nothing refused before passes now.
printf '%s\n' 'echo ok;# set -- x' > "$P/lib/glued.sh"
reads glued.sh "calm hot"
refused "as before, a set in a comment right after a ; still reads as moving the parameters"

# Routine commands of this repository stay allowed. The gate reads the python and awk programs that
# payload-write-gate.sh carries as shell too, and a comment line there holding backquotes was a #
# it could not tell from a comment, so running that hook's suite by name was refused as a check it
# could not make. Its comments name things in plain words now; a backquote put back in one fails
# here, and in test-shell-words-comment-start.sh, which asks the reader itself.
ROOT="$(cd "$DIR/../.." && pwd)"
for routine in "bash payload/hooks/test-payload-write-gate.sh" "bash payload/hooks/payload-write-gate.sh"; do
  run_bash "$routine" "$ROOT"
  allowed "a routine command of this repository is allowed: $routine"
done

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
