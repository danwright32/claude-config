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
# Every shell keeps that # inside the word (measured 2026-11-23 in bash, sh, dash, zsh and ksh, run
# as a -c text, a file and an eval), so the reader reads the rest of the line as the shell does and
# the post is found as the control's is (claude-config#3481).
says "the measured shape: as the post it is, the same answer as the control's" "REFUSED: this command posts to Slack"
# Where the shells differ the reader is not sure, and the gate says which line it could not check.
run_bash "x=(a b)# c; $POST${NL}echo done"
refused "a post after a # right after an array, which bash and zsh read differently, is refused"
says "an array's #: as a check it could not make" "REFUSED: the gate could not check whether this command posts to Slack"
says "an array's #: naming the # and the line it is on" "it holds a # the gate cannot tell from a comment, in the line \`x=(a b)# c; $POST\`"
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
# Where the command names anything that look sends to the reader, the reader reads the rest of the
# line wherever every shell keeps the # inside the word, so it can say that nothing there posts: a
# quiet command passes, as the same command with no # does (claude-config#3481).
printf '%s\n' 'echo quiet' > "$T/quiet.sh"
# Held in a variable, so that no word of this file is itself a command after such a #: the gate
# reads the words of a script it is asked to run, and this suite is run by name.
QUIET="bash quiet.sh"
for sure in "echo see$BS # 3; $QUIET" "echo a$BS${NL}# c; $QUIET" "echo \$(echo b)# c; $QUIET" \
  "echo a$BS|# c; $QUIET"; do
  run_seen "$sure${NL}echo done"
  read_through "a quiet script after a # every shell keeps inside a word is read by the reader: $(shown "$sure")"
  allowed "and passes, its line read as the shell reads it: $(shown "$sure")"
  run_seen "${sure//\#/}${NL}echo done"
  allowed "as the same command with no # passes: $(shown "${sure//\#/}")"
done
# Where the reader is not sure (the shells differ, or the text is inside backquotes) it refuses the
# #, quiet or not: it has not read the rest of that line, so it cannot say that nothing there posts.
for doubt in "x=(a b)# c; $QUIET" "echo \`echo a # c\`; $QUIET"; do
  run_seen "$doubt${NL}echo done"
  refused "a # the gate cannot tell from a comment is refused wherever the reader is started: $(shown "$doubt")"
  says "and as a check it could not make: $(shown "$doubt")" "REFUSED: the gate could not check whether this command posts to Slack"
done
# A reading that goes on past such a # and then cannot be read to its end is one the reader cannot
# vouch for: the apostrophe after this # opens a string that never closes, and a text the gate
# cannot read is judged by a cruder look, which does not find the script run inside the
# substitution on the first line, while bash runs that line before it reaches the second. So the #
# is named and the gate refuses.
# Seen to fail on 2026-11-23 with the reader reading on and not naming the #: exit 0.
mkdir -p "$T/u3481/hot/lib"
printf '%s\n' "$POST" > "$T/u3481/hot/lib/x.sh"
printf '%s\n' 'x=$(bash hot/lib/x.sh)' "echo see$BS # it's" > "$T/u3481/unclosed.sh"
run_bash "bash unclosed.sh" "$T/u3481"
refused "a script that runs a file that posts, then opens a string after such a # that never closes, is refused"
says "and as a check it could not make" "REFUSED: the gate could not check whether this command posts to Slack"
# The same in a script the command runs: the file is read as the command is.
printf '%s\n' '#!/bin/bash' "echo see$BS # 3; $POST" 'echo done' > "$T/hash-posts.sh"
printf '%s\n' '#!/bin/bash' "echo see # 3; $POST" 'echo done' > "$T/hash-quiet.sh"
run_bash "bash hash-posts.sh"
refused "a script whose post follows a # the shell reads inside a word is refused"
run_bash "bash hash-quiet.sh"
allowed "the control: a script whose post is written in a real comment passes"
# A backslash joins a line to the next only where it is live. One that ends a comment, or the
# closing line of a heredoc, joins nothing: every shell reads the # that starts the next line as a
# comment too and runs the lines after it (bash, bash --posix, sh, dash, zsh, zsh emulating sh and
# ksh, measured 2026-11-23 with texts that only echo). The reader walked back over that backslash
# as if it joined the two lines, took the second # for text, and the apostrophe in it opened a
# string that held the lines after it, so a script run on one of them was read by nobody
# (claude-config#3481). The file that posts is named with no directory, so that nothing but the
# reading of its own line finds it.
# Seen to fail on 2026-11-23, before the reader asked what the earlier line was: exit 0 for each.
mkdir -p "$T/dead"
printf '%s\n' "$POST" > "$T/dead/posts.sh"
printf '%s\n' 'echo quiet' > "$T/dead/quiet.sh"
HIDDEN="bash posts.sh"
CALM="bash quiet.sh"
for ends in "true # a note that ends in a$BS" "true # a note that ends in a$BS$BS$BS" "# a note$BS" \
  "cat <<'E$BS'${NL}body${NL}E$BS"; do
  printf '%s\n' "$ends" "#it's" "$HIDDEN" "echo end #'" > "$T/dead/script.sh"
  run_bash "bash script.sh" "$T/dead"
  refused "a script that runs a file that posts, on a line after a backslash that joins nothing and a #, is refused: $(shown "$ends")"
  run_bash "$ends${NL}#it's${NL}$HIDDEN${NL}echo end #'" "$T/dead"
  refused "and the same lines as the command itself are refused: $(shown "$ends")"
  # The control: the same lines running a quiet file pass, so nothing was fixed by refusing them all.
  printf '%s\n' "$ends" "#it's" "$CALM" "echo end #'" > "$T/dead/script.sh"
  run_bash "bash script.sh" "$T/dead"
  allowed "the control: the same script running a quiet file passes: $(shown "$ends")"
done
# The control beside them: two backslashes, where the reader always read the next line's # as the
# comment it is. Refused before and now.
printf '%s\n' "true # a note that ends in a$BS$BS" "#it's" "$HIDDEN" "echo end #'" > "$T/dead/script.sh"
run_bash "bash script.sh" "$T/dead"
refused "the control: after a comment that ends in two backslashes the script that posts is refused"

echo "slack drafts only: a heredoc the shells keep open hides no substitution after it (claude-config#3492)"

# The same backslash, where it IS live: at the end of a line of an unquoted heredoc's body it joins
# that line to the next, so an end marker there is the tail of a longer line and the heredoc stays
# open. The rest of the text is then its body, and every shell runs a $( ) in it, single quotes or
# not (bash 3.2, bash --posix, sh, dash, zsh, zsh emulating sh and ksh, measured 2026-11-23 with
# texts that only echo). The reader closed the heredoc at the marker line and read the rest as
# commands, where a substitution in single quotes is a word that runs nothing, so a script run from
# one was read by nobody. An unquoted heredoc whose marker never comes was read the same way. The
# last three shapes are ones the shells differ on: at least one of them keeps the heredoc open.
# Seen to fail on 2026-11-23, before the reader named such a heredoc: exit 0 for each.
mkdir -p "$T/open"
printf '%s\n' "$POST" > "$T/open/posts.sh"
printf '%s\n' 'echo quiet' > "$T/open/quiet.sh"
RUNS="echo '\$(bash posts.sh)'"
TAB=$'\t'
COULD_NOT="REFUSED: the gate could not check whether this command posts to Slack"
for opens in "cat <<E${NL}a$BS${NL}E" \
  "cat <<E${NL}a$BS$BS$BS${NL}E" \
  "cat <<-E${NL}${TAB}a$BS${NL}${TAB}E" \
  "cat <<E${NL}body${NL}E$BS" \
  "cat <<E${NL}body" \
  "cat <<A <<B${NL}a${NL}A${NL}b$BS${NL}B" \
  "cat <<A <<B${NL}a$BS${NL}A${NL}b${NL}B" \
  "x=\$(cat <<E${NL}a$BS${NL}E" \
  "cat <<E${NL}$BS${NL}E" \
  "cat <<EOF${NL}a${NL}E$BS${NL}OF" \
  "cat <<EOF${NL}EO$BS$BS${NL}EOF"; do
  closes=""
  case "$opens" in 'x=$('*) closes=")" ;; esac
  printf '%s\n' "$opens" "$RUNS" $closes "echo end" > "$T/open/script.sh"
  run_bash "bash script.sh" "$T/open"
  refused "a script that runs a file that posts, from a \$( ) after a heredoc a shell keeps open, is refused: $(shown "$opens")"
  says "and as a check it could not make: $(shown "$opens")" "$COULD_NOT"
  run_bash "$opens${NL}$RUNS${NL}${closes:+$closes$NL}echo end" "$T/open"
  refused "and the same lines as the command itself are refused: $(shown "$opens")"
  says "naming the heredoc and the line it opens on: $(shown "$opens")" "it opens a heredoc the gate cannot find the end of, in the line \`${opens%%"$NL"*}\`"
done
# The endpoint named in the substitution itself, with no file between.
run_bash "cat <<E${NL}a$BS${NL}E${NL}echo '\$($POST)'${NL}echo end" "$T/open"
refused "a post written in a \$( ) after a heredoc a shell keeps open is refused"
# The gate cannot follow such a text whatever it runs, so the same lines running a quiet file are
# refused too, as a check it could not make and never as a post it found.
run_bash "cat <<E${NL}a$BS${NL}E${NL}echo '\$(bash quiet.sh)'${NL}echo end" "$T/open"
refused "the same open heredoc running a quiet file is refused too, since the gate cannot read it"
says "and as a check it could not make, not as a post" "$COULD_NOT"
# The controls: where every shell closes the heredoc at the first line that is its marker, as the
# reader does, the line after it is the command it looks like, its single quoted words run nothing,
# and the gate passes it. Two backslashes join nothing; a quoted marker's body is read as written;
# a backslash in the middle of the body joins two body lines.
for closed in "cat <<E${NL}a$BS$BS${NL}E" \
  "cat <<'E'${NL}a$BS${NL}E" \
  "cat <<E${NL}a$BS${NL}b${NL}E"; do
  printf '%s\n' "$closed" "$RUNS" "echo end" > "$T/open/script.sh"
  run_bash "bash script.sh" "$T/open"
  allowed "the control: a script whose heredoc every shell closes passes, its quoted words running nothing: $(shown "$closed")"
  run_bash "$closed${NL}$RUNS${NL}echo end" "$T/open"
  allowed "the control: and the same lines as the command itself pass: $(shown "$closed")"
done
# A joined marker and then the marker on a line of its own: all seven shells close the heredoc at
# the second, so the lines between are its body, where a $( ) runs and a plain line is text. The
# gate read those lines as commands until now, and what it refused on that reading it must not
# come to allow on the strength of the shells measured, so it names the heredoc here too: a file
# that posts run from that body is refused, a quiet one is refused as it was (for another reason,
# before), and the same heredoc with only quoted words after it, which passed, is refused now.
for between in "\$(bash posts.sh)" "\$(bash quiet.sh)" "'\$(bash posts.sh)'" "bash posts.sh"; do
  run_bash "cat <<E${NL}a$BS${NL}E${NL}$between${NL}E${NL}echo end" "$T/open"
  refused "between a joined marker and the marker on its own line, the gate does not vouch for its reading: $between"
  says "and says it could not check: $between" "$COULD_NOT"
done
run_bash "cat <<E${NL}a$BS${NL}E${NL}E${NL}$RUNS${NL}echo end" "$T/open"
refused "a joined marker, then the marker, then only quoted words: refused, where it passed before"
says "and as a check it could not make" "$COULD_NOT"

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
  CONTROL_ERR="$ERR"
  run_seen "echo see # 3; $reach${NL}echo done" "$Q"
  read_through "the control: after a real comment the reader is still started, since the wrapper's look takes no # for a comment: $reach"
  allowed "the control: and the reader, which reads the comment as the shell does, passes it: $reach"
  # Where every shell keeps the # inside the word the reader reads the line, and the answer is the
  # control's own, word for word, once the front is put back to the control's (claude-config#3481).
  for front in "echo see$BS # 3" "echo \$(echo b)# c" "echo a$BS${NL}# c"; do
    run_seen "$front; $reach${NL}echo done" "$Q"
    refused "a post reached with no posting word is refused after a # the shell reads inside a word: $(shown "$front; $reach")"
    said="${ERR//"$front"/echo see 3}"
    if [ "$said" = "$CONTROL_ERR" ]; then check "and by the same answer the command is given with no #: $(shown "$front; $reach")" ok
    else check "and by the same answer the command is given with no #: $(shown "$front; $reach")" "said: ${ERR:0:300}"; fi
  done
  # Where the reader is not sure, as a check it could not make.
  for front in "x=(a b)# c" "echo \`echo a # c\`"; do
    run_seen "$front; $reach${NL}echo done" "$Q"
    refused "a post reached with no posting word is refused after a # the gate cannot tell from a comment: $(shown "$front; $reach")"
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
# The checkout, as lib/checkout-root.sh finds it (claude-config#1663); installed in ~/.claude there
# is none, and the commands name the checkout's paths.
ROOT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -n "$ROOT" ]; then
  for routine in "bash payload/hooks/test-payload-write-gate.sh" "bash payload/hooks/payload-write-gate.sh"; do
    run_bash "$routine" "$ROOT"
    allowed "a routine command of this repository is allowed: $routine"
  done
else
  echo "SUITE-PART-UNMEASURED whether running the payload write gate's suite by name is allowed, because this copy is not in a claude-config checkout"
fi

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
