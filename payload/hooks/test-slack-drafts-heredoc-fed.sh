#!/usr/bin/env bash
# Tests for where the Slack drafts gate's own reading of a heredoc's body ends (Judge.fed,
# claude-config#3497).
#
# fed() works out what a shell or an interpreter that reads its input is fed. For a heredoc it cut
# the lines after the command up to the first line that, with the blanks round it taken off, was
# the first plain word after the <<. The shells end a heredoc only at a line that IS its marker (a
# <<- lets leading tabs go and nothing else), read the whole word after the << as the marker, and
# in an unquoted body join a line ending in a backslash to the next. So fed() ended a body early
# at a marker with a space or a tab beside it, at the first letters of a longer marker (<<E"F",
# <<E-1), at a line that belongs to an earlier heredoc of the same line, and at a marker a
# backslash joins to the line before, and the lines the shell went on feeding the program were
# read as shell commands, where an import names no file. The shared reader refuses a joined marker
# (#3495), but gives up on a text whose earlier heredoc leaves a $( open before it reaches the
# later one, and the gate then judged it by fed() alone. Measured 2026-11-23 at 4ba7b6ba78 (the
# issue's comment) and 2026-11-26 on main at 6c4cee7247, through this wrapper: exit 0 for each.
#
# fed() now reads the body to where bash 3.2 and zsh end it, and where it cannot tell, the gate
# refuses the command as one it could not check. There are seven kinds of that refusal (fed and
# Reader.body_at in lib/heredoc-fed.py):
#   1. a line joined by a backslash before the marker;
#   2. more than one << in the command;
#   3. a marker it reads the first letters of and not the rest;
#   4. an opener line that ends in a backslash, so the command goes on over the next line;
#   5. an earlier heredoc on the opener's line that cannot be read or never ends;
#   6. a body whose marker is not quoted, that never ends, and that holds a $ or a backquote;
#   7. one command text at two places whose bodies run into one another (the second review of
#      #3497, 2026-11-27).
# An opener it never took for one (a marker written with a backslash) is not refused for the
# opener, only for the seventh kind: the body is handed on after the command's line where its
# end is certain. The last section holds fed() against the shells of the machine the suite runs
# on, with texts that only print.
#
# Kept apart from test-slack-drafts-comment-start.sh, which covers the reader's side of a heredoc,
# so that suite does not grow; the helpers below are copied from it as they are, so a case here is
# driven the same way: a hook payload piped into slack-drafts-only-gate.sh, exit 0 allowed and 2
# refused, the reason on stderr. Nothing a case names is ever run but the texts of the last
# section, which only print, and no file here holds a token, a webhook address or a channel.
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
# The reading this suite holds is lib/heredoc-fed.py's, which the gate loads at its start.
if [ ! -f "$DIR/lib/heredoc-fed.py" ]; then
  echo "FAIL: there is no lib/heredoc-fed.py beside this suite at $DIR, so the gate cannot tell what a heredoc feeds a program."
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

BS='\'
NL=$'\n'
TAB=$'\t'
shown() { local s="${1//$NL/ (line break) }"; printf '%s' "${s//$TAB/(tab)}"; }
POSTS="REFUSED: this command posts to Slack"
COULD_NOT="REFUSED: the gate could not check whether this command posts to Slack"

# The folder every case runs in: a module and a script that post, and one of each that does not.
FED="$T/fed"
mkdir -p "$FED"
printf '%s\n' 'import urllib.request' "urllib.request.urlopen('https://slack.com/api/chat.postMessage', b'text=hi')" > "$FED/poster.py"
printf '%s\n' 'x = 1' > "$FED/quiet.py"
printf '%s\n' 'curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage' > "$FED/posts.sh"
printf '%s\n' 'echo hi' > "$FED/quiet.sh"

echo "slack drafts only: a heredoc feeds a program every line the shells feed it (claude-config#3497)"

# The controls, as they were before this change: a body every shell ends at its marker.
run_bash "python3 <<E${NL}import poster${NL}E" "$FED"
refused "the control: python3 fed a program that imports a module that posts is refused"
says "the control: as the post it is" "$POSTS"
run_bash "python3 <<E${NL}import quiet${NL}E" "$FED"
allowed "the control: python3 fed a program that imports a quiet module passes"
run_bash "python3 <<E${NL}pass${NL}E${NL}import poster" "$FED"
allowed "the control: after a heredoc every shell closes, the same line is a shell command that names no file, and passes"

# A line that is the marker with a blank beside it ends nothing: the shells feed the program that
# line and every line after it, to the marker on a line of its own or to the end of the text. Each
# shape feeds a module, then a script, that posts, and then one that does not. @P@ stands for the
# program and its first line, @M@ for what the body goes on to hold.
while IFS= read -r shape; do
  [ -n "$shape" ] || continue
  shape="${shape//@NL@/$NL}"; shape="${shape//@TAB@/$TAB}"
  for feeds in "python3:pass:import poster:import quiet" "bash:true:bash posts.sh:bash quiet.sh"; do
    prog="${feeds%%:*}"; rest="${feeds#*:}"; first="${rest%%:*}"; rest="${rest#*:}"
    loud="${rest%%:*}"; calm="${rest#*:}"
    text="${shape//@P@/$prog}"; text="${text//@1@/$first}"
    run_bash "${text//@M@/$loud}" "$FED"
    refused "$prog fed a line that posts, after a line the shells do not end the heredoc at, is refused: $(shown "$shape")"
    says "as the post it is: $prog, $(shown "$shape")" "$POSTS"
    printf '%s\n' "${text//@M@/$loud}" > "$FED/script.sh"
    run_bash "bash script.sh" "$FED"
    refused "and the same lines in a script that is run are refused: $prog, $(shown "$shape")"
    run_bash "${text//@M@/$calm}" "$FED"
    allowed "the same heredoc feeding a line that does not post passes: $prog, $(shown "$shape")"
  done
done <<'SHAPES'
@P@ <<E@NL@@1@@NL@ E@NL@@M@@NL@E
@P@ <<E@NL@@1@@NL@E @NL@@M@@NL@E
@P@ <<E@NL@@1@@NL@@TAB@E@NL@@M@@NL@E
@P@ <<'E'@NL@@1@@NL@ E@NL@@M@@NL@E
@P@ <<"E"@NL@@1@@NL@E @NL@@M@@NL@E
@P@ <<-E@NL@@1@@NL@ E@NL@@M@@NL@@TAB@E
@P@ <<-E@NL@@1@@NL@@TAB@ E@NL@@M@@NL@E
@P@ <<E@NL@@1@@NL@ E@NL@@M@
@P@ <<'E'@NL@@1@@NL@E @NL@@M@
@P@ <<E"F"@NL@@1@@NL@E@NL@@M@@NL@EF
@P@ <<E-1@NL@@1@@NL@E@NL@@M@@NL@E-1
@P@ <<E.x@NL@@1@@NL@E@NL@@M@@NL@E.x
: <<A | @P@ <<B@NL@B@NL@A@NL@@M@@NL@B
SHAPES

# A marker written with a backslash, or in quotes with a character that is no letter, digit or
# underscore, is a quoted one to the shells, and a word fed() never read as an opener at all: it
# gave the program's own line for what it is fed, so the body was read by nobody, and python3
# <<\E importing a module that posts passed (measured 2026-11-26 on main at 6c4cee7247). fed() now
# gives that line and then the body, where it reads the marker and finds where the shells end it,
# and still does not call it a body: python3 fed that way has its imports read, while what a pipe
# from such a heredoc carries stays not worked out, and refused, as it was. Each row is the opener,
# then the line that ends the body; the last body is never ended, and the shells feed it whole.
while IFS='|' read -r marked closes; do
  [ -n "$marked" ] || continue
  run_bash "$marked${NL}import poster${NL}$closes" "$FED"
  refused "python3 fed a module that posts by a heredoc whose marker the loose reading never took is refused: $marked"
  says "as the post it is: $marked" "$POSTS"
  printf '%s\n' "$marked${NL}import poster${NL}$closes" > "$FED/script.sh"
  run_bash "bash script.sh" "$FED"
  refused "and the same lines in a script that is run are refused: $marked"
  run_bash "$marked${NL}import quiet${NL}$closes" "$FED"
  allowed "the same heredoc feeding a quiet module passes: $marked"
done <<'MARKED'
python3 <<\E|E
python3 - <<\EOF|EOF
python3 <<'E.\'|E.\
python3 <<"E F"|E F
python3 <<!|!
python3 <<~E|~E
python3 - <<!EOF|!EOF
python3 <<\EOF|E
MARKED
# The three rows with a ! or a ~ are a bare marker that starts with a character the loose reading
# took for no opener, an old and real way to write one (`cat <<!`). Both shells take each as the
# marker (the last section holds that), and at 5019457df1 the gate read neither, so python3 fed an
# import of a module that posts that way passed, as it does on main (the review's probes h01 and
# h08, 2026-11-27).

# The first build of this change refused every such opener as one the gate does not read, and so
# refused a program that is no shell and no interpreter, fed a quiet body: the control
# test-slack-drafts-comment-start.sh pins for a quoted marker ending in a backslash (seen
# 2026-11-26). These hold that it passes, and that the opener alone is no refusal.
run_bash "cat <<'E$BS'${NL}body${NL}E$BS" "$FED"
allowed "cat fed a quiet body by a heredoc whose quoted marker ends in a backslash passes"
run_bash "cat <<${BS}E${NL}body${NL}E" "$FED"
allowed "cat fed a quiet body by a heredoc whose marker is written with a backslash passes"
run_bash "cat <<'E$BS' > out.txt${NL}import poster${NL}E$BS" "$FED"
allowed "cat writing out a body that only names a module, by such a heredoc, passes"
# What such a heredoc hands down a pipe is still not worked out (fed() gives no word that it is a
# body), so a shell reading that pipe is refused whatever the body holds, as it was before.
run_bash "cat <<${BS}E | bash${NL}bash quiet.sh${NL}E" "$FED"
refused "a shell reading a pipe from a heredoc with a backslash marker is still refused, its input not worked out"
# A shell fed a line that names a send route by such a heredoc passed as well (measured on main
# the same day): the body is handed on now, so the name is found in it.
run_bash "bash <<${BS}E${NL}curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage${NL}E" "$FED"
refused "a shell fed a line that names a send route by a heredoc with a backslash marker is refused"
says "as the post it is" "$POSTS"
run_bash "bash <<${BS}E${NL}echo hi${NL}E" "$FED"
allowed "the same heredoc feeding a shell a line that does not post passes"
# Not covered, and so not asserted either way: bash <<\E whose body runs a script that posts. The
# body is handed over without the word that it is one, so its lines are not walked as commands.

# More than one << in the command is still a heredoc whose end the gate does not read: refused as
# a check it could not make, whatever the bodies hold, with how to write it.
for body in "import poster" "import quiet"; do
  run_bash "python3 <<E <<F${NL}$body${NL}E${NL}F" "$FED"
  refused "a program fed by two heredocs in one command is refused: $body"
  says "as a check it could not make: $body" "$COULD_NOT"
  says "naming the line and how to write the marker: $body" "it feeds a program by a heredoc whose end the gate does not read, in the line \`python3 <<E <<F\`"
done

# The measured shape: an earlier heredoc whose body leaves a substitution open makes the shared
# reader give up on the whole text before it reaches the heredoc that feeds python3, whose marker
# a backslash joins to the line before. Every shell keeps that heredoc open and feeds python3 the
# import (bash 3.2, bash --posix, sh and ksh, measured 2026-11-23, the issue's comment). The gate
# cannot follow such a text whatever it feeds, so a quiet module is refused too.
for open in '$(echo' '`echo' '${x'; do
  lead="cat <<A${NL}${open}${NL}A${NL}"
  run_bash "${lead}python3 <<E${NL}# note$BS${NL}E${NL}import poster" "$FED"
  refused "python3 fed a module that posts through a heredoc a backslash keeps open, after a heredoc the reader gives up on, is refused: $open"
  says "and as a check it could not make: $open" "$COULD_NOT"
  says "naming the heredoc and the line it opens on: $open" "it opens a heredoc the gate cannot find the end of, in the line \`python3 <<E\`"
  printf '%s\n' "${lead}python3 <<E${NL}# note$BS${NL}E${NL}import poster" > "$FED/script.sh"
  run_bash "bash script.sh" "$FED"
  refused "and the same lines in a script that is run are refused: $open"
  run_bash "${lead}python3 <<E${NL}# note$BS${NL}E${NL}import quiet" "$FED"
  refused "the same open heredoc feeding a quiet module is refused too, since the gate cannot read it: $open"
  says "and as a check it could not make, not as a post: $open" "$COULD_NOT"
  # The control: with no backslash every shell ends the heredoc at E, and the import is a shell
  # command that names no file.
  run_bash "${lead}python3 <<E${NL}# note${NL}E${NL}import poster" "$FED"
  allowed "the control: the same text with no backslash, where every shell ends the heredoc, passes: $open"
done

# What must still pass: a body whose lines a backslash joins, and whose marker follows a line that
# ends in none, is ended at that marker by every shell.
run_bash "python3 <<E${NL}x = 1 + $BS${NL}    2${NL}import quiet${NL}E${NL}echo done" "$FED"
allowed "a heredoc whose body joins two lines and then ends at its marker passes"
run_bash "python3 - <<'EOF'${NL}import quiet${NL}print('a $BS${NL}EOF b')${NL}EOF${NL}echo done" "$FED"
allowed "a quoted heredoc with a backslash at a line's end passes, the body read as written"
run_bash "python3 <<E${NL}x = 1 + $BS${NL}    2${NL}import poster${NL}E" "$FED"
refused "and the same joined body importing a module that posts is refused"
says "as the post it is" "$POSTS"

# A dollar sign or a backquote in the end marker. Inside single quotes every shell takes the marker
# as it is written (bash 3.2.57, sh and zsh 5.9 each ended `cat <<'E$'`, and the same with a
# backquote, at that line: measured 2026-11-26 with a touch after each), and the gate reads it, so
# the body is the program's. Main read neither: python3 fed an import of a module that posts that
# way passed (measured the same day at f0c2aba6fd). Outside single quotes the gate does not read
# the marker, and the refusal says so. It named any dollar sign or backquote as a cause, which one
# in single quotes never is.
for mark in 'E$' 'E`'; do
  run_bash "python3 <<'$mark'${NL}import poster${NL}$mark" "$FED"
  refused "python3 fed a module that posts by a heredoc whose single quoted marker is $mark is refused"
  says "as the post it is: $mark" "$POSTS"
  run_bash "python3 <<'$mark'${NL}import quiet${NL}$mark${NL}echo done" "$FED"
  allowed "the same heredoc feeding a quiet module passes: $mark"
done
for open in 'E$' "E$BS\$"; do
  run_bash "python3 <<$open${NL}import quiet${NL}E\$" "$FED"
  refused "a program fed by a heredoc whose marker holds a dollar sign outside single quotes is refused: $open"
  says "as a check it could not make: $open" "$COULD_NOT"
  says "saying where a dollar sign is not read: $open" "the end marker holds a dollar sign or a backquote outside single quotes"
done

echo "slack drafts only: a body read further is judged as it was before as well (review of claude-config#3497)"

# The lines fed() adds past the place it always ended a body can weaken how the gate reads the
# lines before them: a shell's body with a quote left open is read by the crude cut, which follows
# no variable, and a later sys.path line is applied to an import that ran before it. Each command
# here was refused on main at 969bb0fce0 and passed at 5019457df1, the first build of this change
# (the review's probes a02, a03, a05, a11 and a13, 2026-11-27), and each posts in a real shell: the
# fed program runs the early lines before it reaches the added ones (measured there in bash 3.2
# and zsh with texts that only print). The gate now judges the call twice where a body grew, once
# with every body as it always was, and refuses where either reading gives a reason.
mkdir -p "$FED/elsewhere"
printf '%s\n' 'x = 1' > "$FED/elsewhere/poster.py"
printf '%s\n' 'x = 1' > "$FED/elsewhere/quiet.py"
OPEN_QUOTE='echo "unclosed'
while IFS='|' read -r probe opener loose strict; do
  [ -n "$probe" ] || continue
  loose="${loose//@SP@/ }"; opener="${opener//@BAR@/|}"
  text="$opener${NL}kept=posts.sh${NL}bash \"\$kept\"${NL}$loose${NL}$OPEN_QUOTE${NL}$strict"
  run_bash "$text" "$FED"
  refused "$probe: a shell fed a script that posts through a variable, then a line the heredoc does not end at and a quote left open, is refused: $opener"
  says "$probe: as the post it is" "$POSTS"
  says "$probe: naming the script the variable holds" "the script posts.sh runs a command that posts"
  printf '%s\n' "$text" > "$FED/script.sh"
  run_bash "bash script.sh" "$FED"
  refused "$probe: and the same lines in a script that is run are refused: $opener"
  # The control that pins the cause (the review's a02b): with nothing left open the longer body
  # is readable, and was refused at 5019457df1 too.
  run_bash "${text//$OPEN_QUOTE/echo fine}" "$FED"
  refused "$probe: the control: the same text with no quote left open is refused: $opener"
  run_bash "${text//posts.sh/quiet.sh}" "$FED"
  allowed "$probe: the same text running a quiet script through the variable passes: $opener"
done <<'OPEN'
a02|bash <<'E'|@SP@E|E
a03|cat <<'E' @BAR@ bash|@SP@E|E
a05|bash <<'E'F|E|EF
OPEN
while IFS='|' read -r probe opener loose strict; do
  [ -n "$probe" ] || continue
  loose="${loose//@SP@/ }"
  text="$opener${NL}import poster${NL}$loose${NL}import sys${NL}sys.path.insert(0, 'elsewhere')${NL}$strict"
  run_bash "$text" "$FED"
  refused "$probe: python3 fed an import of a module that posts, then a line the heredoc does not end at and a sys.path line naming a folder with a quiet module of that name, is refused: $opener"
  says "$probe: as the post it is" "$POSTS"
  printf '%s\n' "$text" > "$FED/script.sh"
  run_bash "bash script.sh" "$FED"
  refused "$probe: and the same lines in a script that is run are refused: $opener"
  run_bash "${text//import poster/import quiet}" "$FED"
  allowed "$probe: the same text importing a quiet module passes: $opener"
done <<'PATHS'
a11|python3 <<'E'|E@SP@|E
a13|python3 <<'E'F|E|EF
PATHS

echo "slack drafts only: one command text at two places whose bodies run into one another is refused as a check not made (second review of claude-config#3497)"

# fed() finds the command's text wherever it stands in the call: in a comment, in a quoted text
# and in another heredoc's body as well as where the shell runs it, and it cannot tell which is
# which. At 5019457df1 every place was handed every line the shells would feed it, which for 300
# places was the square of the text. At 010c05a1b0 a line past where a body always ended was
# handed on once, by the first place to reach it: with the text in a comment above the real
# command, the real one was handed its body cut where main cut it, the joined text ended in a
# quote left open or an if with no fi, and a script that posts through a variable passed where
# 5019457df1 refused it (the second review's probes g01, g02, g14 and g13, 2026-11-27; bash 3.2
# and zsh run the command after the assignment in each, measured there with texts that only
# print). Handing every place its lines whole and reading each line about once cannot both be
# had: of two places whose added lines are the same lines, one is handed them a second time or
# one is handed fewer than the shells feed it. So the gate refuses as a check it could not make,
# and says why. Each case is the text above the real command, and then the real command's body.
TWICE="the same command stands at more than one place"
ONE_QUOTE="bash <<'E'${NL}kept=posts.sh${NL}echo \"open${NL} E${NL}\" ; bash \"\$kept\"${NL}E"
ONE_IF="bash <<'E'${NL}kept=posts.sh${NL}if true; then${NL} E${NL}fi${NL}bash \"\$kept\"${NL}E"
for one in "$ONE_QUOTE" "$ONE_IF"; do
  # The control that pins the cause: at one place the body is read whole, and the post is found.
  run_bash "$one" "$FED"
  refused "the control: at one place, a shell fed a script that posts through a variable after a line the heredoc does not end at is refused: $(shown "$one")"
  says "the control: as the post it is: $(shown "$one")" "$POSTS"
  run_bash "${one//posts.sh/quiet.sh}" "$FED"
  allowed "the control: at one place, the same text running a quiet script passes: $(shown "$one")"
  # And a comment that names another program is no second place of this command.
  run_bash "# python3 <<'E'${NL}$one" "$FED"
  refused "the control: under a comment that names another program, the same text is refused: $(shown "$one")"
  says "the control: under a comment that names another program, as the post it is: $(shown "$one")" "$POSTS"
done
while IFS='|' read -r probe above body; do
  [ -n "$probe" ] || continue
  above="${above//@NL@/$NL}"
  case "$body" in quote) one="$ONE_QUOTE" ;; *) one="$ONE_IF" ;; esac
  text="$above${NL}$one"
  run_bash "$text" "$FED"
  refused "$probe: a shell fed a script that posts through a variable, with the command's text once more above it, is refused: $(shown "$above")"
  says "$probe: as a check it could not make" "$COULD_NOT"
  says "$probe: saying the command stands at two places" "$TWICE"
  printf '%s\n' "$text" > "$FED/script.sh"
  run_bash "bash script.sh" "$FED"
  refused "$probe: and the same lines in a script that is run are refused: $(shown "$above")"
  # The same text with the quote closed, or the if ended: refused all the same, since the
  # refusal is for the two places and not for what the body holds.
  closed="${text//echo \"open/echo \"shut\"}"; closed="${closed//\" ; bash/true ; bash}"
  closed="${closed//if true; then/if true; then true; fi}"; closed="${closed//${NL}fi${NL}/${NL}true${NL}}"
  run_bash "$closed" "$FED"
  refused "$probe: the same text with nothing left open is refused: $(shown "$above")"
  says "$probe: with nothing left open, as a check it could not make" "$COULD_NOT"
  # The quiet twin is refused too, falsely: the gate does not read either place's lines.
  run_bash "${text//posts.sh/quiet.sh}" "$FED"
  refused "$probe: the quiet twin is refused as well, as a check not made: $(shown "$above")"
  says "$probe: the quiet twin, as a check it could not make" "$COULD_NOT"
done <<'ABOVE'
g01|# bash <<'E'|quote
g02|echo "next: bash <<'E'"|quote
g14|cat <<'USAGE'@NL@feed it so:@NL@  bash <<'E'@NL@USAGE|quote
g13|# bash <<'E'|if
ABOVE
# What is not refused that way: two places whose bodies do not run into one another. With each
# body ended by its marker alone on a line nothing is added, and the reading is main's.
run_bash "# bash <<'E'${NL}bash <<'E'${NL}kept=quiet.sh${NL}bash \"\$kept\"${NL}E" "$FED"
allowed "a quiet twin that passes: the command's text in a comment above a heredoc that ends at its marker"
run_bash "# bash <<'E'${NL}bash <<'E'${NL}kept=posts.sh${NL}bash \"\$kept\"${NL}E" "$FED"
refused "and the same with a script that posts is refused"
says "and the same with a script that posts, as the post it is" "$POSTS"
# And two real places, each with a body that grew and its own end: each is handed its lines whole.
APART="bash <<'E'${NL}echo one${NL} E${NL}echo two${NL}E${NL}bash <<'E'${NL}kept=@F@.sh${NL} E${NL}bash \"\$kept\"${NL}E"
run_bash "${APART//@F@/quiet}" "$FED"
allowed "a quiet twin that passes: the same command twice, each body ended by its own marker"
run_bash "${APART//@F@/posts}" "$FED"
refused "the same command twice, each body ended by its own marker, the second running a script that posts, is refused"
says "the same command twice, as the post it is" "$POSTS"
# An opener the loose reading never took (a backslash marker) is held to the same rule.
run_bash "# python3 <<${BS}E${NL}python3 <<${BS}E${NL}import poster${NL}E" "$FED"
refused "python3 fed an import of a module that posts by a backslash marker, with the command's text in a comment above, is refused"
run_bash "# python3 <<${BS}E${NL}python3 <<${BS}E${NL}import quiet${NL}E" "$FED"
refused "and its quiet twin is refused as well, as a check not made"
says "the quiet twin of the backslash marker, as a check it could not make" "$COULD_NOT"
says "the quiet twin of the backslash marker, saying the command stands at two places" "$TWICE"
run_bash "python3 <<${BS}E${NL}import quiet${NL}E${NL}python3 <<${BS}E${NL}import quiet${NL}E" "$FED"
allowed "a quiet twin that passes: the same backslash marker command twice, each body ended by its own marker"

# The second judgement runs on what is left of the first one's time, never on a time of its own:
# two whole budgets would be 22 seconds, past the 15 the hook is given (not measured: the gate
# sets the one and the hook's settings the other). Counted in the gate's
# steps, which no load can move (SLACK_GATE_TICK_BUDGET under a test run): the fewest steps a
# quiet command whose body grew is allowed in must be more than the fewest for the same command
# with a body that did not grow by at least half of it, and no more than twice that and a few.
fewest() { # fewest <command>: the smallest step budget, up to 60, the gate allows the command in
  local b rc p
  p="$(payload Bash "$(bash_input "$1")" "$FED")"
  b=1
  while [ "$b" -le 60 ]; do
    printf '%s' "$p" | HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET="$b" SLACK_GATE_CACHE_DIR="$T/steps-cache.$b.$RANDOM" bash "$HOOK" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 0 ]; then printf '%s' "$b"; return; fi
    b=$((b + 1))
  done
  printf 'none'
}
once="$(fewest "python3 <<'E'${NL}import quiet${NL}import quiet${NL}E")"
twice="$(fewest "python3 <<'E'${NL}import quiet${NL}E ${NL}import quiet${NL}E")"
if [ "$once" != none ] && [ "$twice" != none ] && [ "$twice" -ge $((once + (once + 1) / 2)) ] && [ "$twice" -le $((2 * once + 8)) ]; then
  check "a command whose body grew is judged twice inside one budget ($once steps for a body that did not grow, $twice for one that did)" ok
else
  check "a command whose body grew is judged twice inside one budget" "allowed in $once steps where the body did not grow and in $twice where it did"
fi
echo "  steps: $once for a body that did not grow, $twice for one that did"
# And a call that runs out of time in the second judgement is refused, never allowed: with one
# step fewer than the grown command needs, which the first judgement fits in, the gate exits 2
# and says it ran out of time (the second review's finding 2, 2026-11-27).
if [ "$once" != none ] && [ "$twice" != none ] && [ $((twice - 1)) -ge "$once" ]; then
  errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(payload Bash "$(bash_input "python3 <<'E'${NL}import quiet${NL}E ${NL}import quiet${NL}E")" "$FED" \
    | HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET="$((twice - 1))" SLACK_GATE_CACHE_DIR="$T/steps-cache.out.$RANDOM" bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
  refused "a quiet command whose second judgement runs out of steps is refused, not allowed"
  says "saying it ran out of time, and that this is no finding that it posts" "ran out of time judging this call"
else
  check "a quiet command whose second judgement runs out of steps is refused, not allowed" "no step budget between the two was found: $once and $twice"
fi

# The two readings themselves, asked of the gate's own code: the short one is what Judge.fed gave
# on main, line for line; the longer one gives every line of the short one and every place every
# line the shells feed it, or refuses; the gate is told when the two differ; and the work the
# longer one does is counted, which no load can move (L290). 300 `python3 <<EOF`, each with its
# EOF indented so that it ends nothing, are 300 bodies that all run to the end of the text: handed
# on whole they were 135,000 lines for a text of 900, and a script main judged in 1.47 seconds ran
# out of the gate's 11 at 5019457df1 (the review's probe d_hd_300, measured 2026-11-27). Such a
# text is refused now, after about one read of each line, and so is the shape the second review
# found (the command's text once more above the real one); heredocs that each end at their own
# marker are handed each of their lines once.
cat > "$T/readings.py" <<'PY'
import bisect, collections, importlib.util, io, json, os, random, re, sys

spec = importlib.util.spec_from_file_location("gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
lib, lines_of = gate.HeredocFed, gate.lines_of


class Unsure(Exception):
    def __init__(self, kind):
        self.kind = kind


def unsure(at, kind):
    return Unsure(kind)


def cost(key, piece, n):
    """(the lines read to find where the heredocs of n such pieces end, the lines handed on or the
    kind of refusal raised, the lines of the text)."""
    whole = "\n".join(piece for _ in range(n)) + "\n"
    read, plain = [0], lib.end

    def counted(lines, k, *rest):
        got = plain(lines, k, *rest)
        reached = got[1] if isinstance(got, tuple) else len(lines) if got is None else got
        read[0] += reached - k + 1
        return got
    lib.end = counted
    try:
        handed = lib.fed(key, whole, lines_of, unsure)[0].count("\n") + 1
    except Unsure as e:
        handed = e.kind
    finally:
        lib.end = plain
    return read[0], handed, whole.count("\n")


# Heredocs that never end, 200 and 400 of them, and the second review's shape, the command's text
# in a comment above the real one: refused, each after no more than about one read of each line.
NEVER = ("python3 <<EOF", "python3 <<EOF\nimport quiet\n  EOF")
SHAPE = ("bash <<'E'", "# bash <<'E'\nbash <<'E'\nkept=quiet.sh\necho \"open\n E\n\" ; bash \"$kept\"\nE")
cheap = []
for name, (key, piece) in (("never ending", NEVER), ("in a comment above", SHAPE)):
    small, large = cost(key, piece, 200), cost(key, piece, 400)
    if large[1] != "places" or small[1] != "places":
        print("FAIL 400 heredocs %s were not refused as one command at several places whose bodies run "
              "into one another: fed() gave %r for 400 and %r for 200" % (name, large[1], small[1]))
    if large[0] > 2 * large[2] or large[0] > 3 * max(small[0], 1):
        print("FAIL refusing 400 heredocs %s read %d lines of a text of %d, and refusing 200 read %d of %d: "
              "it grows with the square of the commands" % (name, large[0], large[2], small[0], small[2]))
    cheap.append("%s read=%d of %d" % (name, large[0], large[2]))
print("cheap " + ", ".join(cheap))
# Heredocs whose bodies each grew and each end at their own marker: every place is handed its
# three lines, and each line of the text is read about once.
APART = ("python3 <<EOF", "python3 <<EOF\nimport quiet\n  EOF\nimport quiet\nEOF")
small, large = cost(*APART, 200), cost(*APART, 400)
if large[0] > 3 * small[0] or large[0] > 2 * large[2]:
    print("FAIL finding where 400 heredocs end read %d lines of a text of %d, and where 200 end %d of %d: "
          "it grows with the square of the commands" % (large[0], large[2], small[0], small[2]))
if large[1] != 3 * 400 or small[1] != 3 * 200:
    print("FAIL 400 heredocs, each with a body of 3 lines, were handed %r lines of a text of %d, and 200 were "
          "handed %r of %d" % (large[1], large[2], small[1], small[2]))
print("counted read=%d handed=%s of %d lines, for 400 heredocs each ended by its own marker" % large)


def before(text, whole):
    """Judge.fed as it stood on main at 969bb0fce0, copied line for line but for its name."""
    lines, starts = lines_of(whole)
    key = text.strip()
    ats, at = [], whole.find(key) if key and "\n" not in key else -1
    while at >= 0:
        i = bisect.bisect_right(starts, at) - 1
        ats.append(i)
        at = whole.find(key, starts[i + 1]) if i + 1 < len(starts) else -1
    if not ats:
        return whole, False
    m = re.search(r"<<-?\s*(['\"]?)([A-Za-z0-9_]+)\1", text)
    if not m:
        return "\n".join(lines[i] for i in ats), False
    bodies = []
    for at in ats:
        body = []
        for ln in lines[at + 1:]:
            if ln.strip() == m.group(2):
                break
            body.append(ln)
        else:
            return whole, False  # a body never closed: read it all
        bodies.append("\n".join(body))
    return "\n".join(bodies), True


loose, flags = getattr(lib, "loose", None), getattr(gate, "FED", None)
if loose is None or flags is None:
    print("FAIL the gate keeps no reading of a heredoc as it was before (loose in lib/heredoc-fed.py: %s, "
          "FED in the gate: %s), so a body read further is judged by the longer reading alone"
          % ("there" if loose else "missing", "there" if flags else "missing"))
    sys.exit(0)

# Texts put together from the lines that matter here, the same ones on every run.
rng = random.Random(3497)
OPENERS = ["python3 <<E", "python3 <<'E'", "python3 <<-E", 'python3 <<E"F"', "python3 <<\\E", "python3 <<!",
           "bash <<'E'", "python3 - <<E-1", "cat <<A | python3 <<E"]
PIECES = ["E", " E", "E ", "\tE", "EF", "E-1", "!", "A", "import quiet", "x = 1 \\", "echo $HOME", "",
          "python3 <<E", "python3 <<'E'", "python3 <<\\E"]
def every_place_whole(key, whole):
    """What fed() gives where it hands every place the command stands at every line the shells
    feed it, worked out here one place at a time with a reader of its own for each, so nothing one
    place was handed is held against the next: the body it always gave and then the lines up to
    where the shells end the heredoc, or, for an opener the loose reading never took, the lines
    holding the command and then each body. None where one place's end cannot be told."""
    lines, starts, _, ats = lib.places(key, whole, lines_of)
    m = lib.LOOSE.search(key)
    strict = lib.word(key, key.index("<<"), not m)
    if not strict:
        return None
    bodies = []
    for i, at in ats:
        got = lib.Reader(lines, starts).body_at(i, at, strict)
        if isinstance(got, str):
            if m:
                return None
            continue
        was = lib.loose_end(lines, i, m.group(2)) if m else got[0]
        bodies.append("\n".join(lines[i + 1 if m else got[0]:max(was, got[1])]))
    return "\n".join(bodies if m else [lines[i] for i, _ in ats] + bodies)


asked = longer = refused = twice = whole_held = 0
for _ in range(4000):
    opener = rng.choice(OPENERS)
    key = opener.split("| ")[-1]
    whole = "\n".join([rng.choice(PIECES) for _ in range(rng.randrange(3))] + [opener]
                      + [rng.choice(PIECES) for _ in range(rng.randrange(10))])
    where = repr(whole)
    want = before(key, whole)
    short = loose(key, whole, lines_of)
    asked += 1
    if short != want:
        print("FAIL the short reading gave %r where main gave %r: %s" % (short, want, where))
        break
    try:
        got = lib.fed(key, whole, lines_of, unsure)
    except Unsure as e:
        refused += 1
        twice += e.kind == "places"
        continue
    longer += got != want
    # No place is handed fewer lines than the shells feed it: where fed() answers and the text is
    # not main's whole text handed back for a body that never ended, what it gives is every place's
    # lines whole (the second review of #3497: a later place was handed its body cut short).
    if got != (whole, False) and key.count("<<") == 1:
        full = every_place_whole(key, whole)
        if full is not None:
            whole_held += 1
            if got[0] != full:
                print("FAIL the longer reading gave %r where every place's lines whole are %r: %s" % (got[0], full, where))
                break
    if got[1] != want[1]:
        print("FAIL the longer reading %s a body where main %s: %s"
              % ("gave" if got[1] else "gave no", "gave one" if want[1] else "gave none", where))
        break
    lost = collections.Counter(l for l in want[0].split("\n") if l) - collections.Counter(l for l in got[0].split("\n") if l)
    if lost:
        print("FAIL the longer reading left out %r, which main gave: %s" % (sorted(lost), where))
        break
    if got[0].count("\n") > want[0].count("\n") + whole.count("\n") + whole.count(key) + 1:
        print("FAIL the longer reading gave %d lines where main gave %d of a text of %d: %s"
              % (got[0].count("\n") + 1, want[0].count("\n") + 1, whole.count("\n") + 1, where))
        break
print("held asked=%d longer=%d refused=%d twice=%d whole=%d" % (asked, longer, refused, twice, whole_held))

# What the gate is told. A body that grew sets "grew", one that did not sets nothing, and with
# "short" set Judge.fed gives what main gave.
grown = "python3 <<'E'\nimport poster\nE \nimport sys\nE"
same = "python3 <<'E'\nimport poster\nE\nimport sys"
gate.Judge.fed.cache_clear()
flags.update(short=False, grew=False)
gate.Judge.fed("python3 <<'E'", same)
if flags["grew"]:
    print("FAIL a body the shells end where it always ended was said to have grown")
got = gate.Judge.fed("python3 <<'E'", grown)
if not flags["grew"] or got == before("python3 <<'E'", grown):
    print("FAIL a body the shells feed two more lines of was not said to have grown: %r" % (got,))
gate.Judge.fed("python3 <<'E'", grown)
if not flags["grew"]:
    print("FAIL asked a second time, the gate forgot that the body grew")
flags["short"] = True
gate.Judge.fed.cache_clear()
got = gate.Judge.fed("python3 <<'E'", grown)
if got != before("python3 <<'E'", grown):
    print("FAIL with the short reading asked for, Judge.fed gave %r where main gave %r"
          % (got, before("python3 <<'E'", grown)))

# Two Judges run in one process where a body grew, and a dict, list or set kept on the Judge's
# classes outlives a Judge: eight memos were shared by the two that way (the second review's
# finding 5, 2026-11-27). Every one that is empty before the first judgement is emptied again
# before the second, so nothing worked out under the longer reading is handed to the shorter one,
# whichever memo is added next. Asked of the gate itself: the first judgement leaves some of them
# filled (or this shows nothing), and the second begins with all of them empty.
both, held_on = getattr(gate, "both_readings", None), getattr(gate, "class_held", None)
if both is None or held_on is None:
    print("FAIL the gate has no both_readings or no class_held, so what the first judgement leaves on the "
          "Judge's classes is handed to the second as it is")
    sys.exit(0)
with open(os.path.join(sys.argv[2], "memo.sh"), "w") as f:
    f.write("run() {\n  local t\n  t=quiet.sh\n  bash \"$t\"\n}\nrun\necho hi | { cat; }\n"
            "python3 <<'E'\nimport quiet\nE \nimport quiet\nE\n")
empty = [v for v in held_on() if not v]
if len(empty) < 8:
    print("FAIL only %d empty dicts, lists and sets were found on the Judge's classes, fewer than the "
          "eight memos the review counted there" % len(empty))
seen, plain = [], gate.Judge.judged


def watched(self, cmd, cwd):
    seen.append(sum(len(v) for v in empty))
    try:
        return plain(self, cmd, cwd)
    finally:
        seen.append(sum(len(v) for v in empty))


gate.Judge.judged = watched
gate.Judge.fed.cache_clear()
flags.update(short=False, grew=False)
try:
    reason = both(gate.load_reader(), "bash memo.sh", sys.argv[2], [])
finally:
    gate.Judge.judged = plain
if reason or len(seen) != 4:
    print("FAIL a quiet script whose heredoc body grew was not judged twice and allowed: reason %r, "
          "entries on the Judge's classes at each start and end %r" % (reason, seen))
elif not seen[1]:
    print("FAIL the first judgement left nothing on the Judge's classes, so emptying them is not shown: %r" % (seen,))
elif seen[2]:
    print("FAIL the second judgement began with %d entries the first left on the Judge's classes: %r" % (seen[2], seen))
else:
    print("emptied left_by_first=%d at_second_start=%d containers=%d" % (seen[1], seen[2], len(empty)))
if flags["short"] or flags["grew"]:
    print("FAIL after both judgements the gate still says a body grew or asks for the short reading: %r" % (flags,))
# And a second call judged in the same process starts as the first did. After a call judged
# twice, Judge.fed still held the short reading for every text the second judgement asked about,
# so the same call judged again was never told its body grew and was judged once, by the short
# reading alone (third review of #3497, 2026-11-27). The hook judges one call a process, so this
# is for whatever loads the gate and judges more than one. Nothing is cleared between the two
# calls here: that is what both_readings itself has to leave right.
del seen[:]
gate.Judge.judged = watched
try:
    reason = both(gate.load_reader(), "bash memo.sh", sys.argv[2], [])
finally:
    gate.Judge.judged = plain
if reason or len(seen) != 4:
    print("FAIL the same call judged a second time in one process was judged %d times, not twice, "
          "so the first call left the short reading behind in Judge.fed: reason %r" % (len(seen) // 2, reason))
else:
    print("again judged_twice=%d" % (len(seen) // 2))
PY
rows="$(python3 -B "$T/readings.py" "$DIR/slack_drafts_only_gate.py" "$FED" 2>&1)"
counted=""; held=""; cheap=""; emptied=""; again=""
while IFS= read -r row; do
  case "$row" in
    "counted "*) counted="$row" ;;
    "held "*) held="$row" ;;
    "cheap "*) cheap="$row" ;;
    "emptied "*) emptied="$row" ;;
    "again "*) again="$row" ;;
    "") ;;
    *) check "the gate's two readings of a heredoc" "$row" ;;
  esac
done <<EOF
$rows
EOF
if [ -n "$counted" ]; then check "the work of reading 400 heredocs that each end at their own marker was counted" ok
else check "the work of reading 400 heredocs that each end at their own marker was counted" "no count was printed: ${rows:0:300}"; fi
if [ -n "$cheap" ]; then check "the work of refusing 400 heredocs whose bodies run into one another was counted" ok
else check "the work of refusing 400 heredocs whose bodies run into one another was counted" "no count was printed: ${rows:0:300}"; fi
longer="${held#*longer=}"; longer="${longer%% *}"
if [ "${longer:-0}" -ge 200 ] 2>/dev/null; then check "the two readings were held against each other where they differ ($held)" ok
else check "the two readings were held against each other where they differ" "only '${longer:-none}' texts had a longer body: '$held'"; fi
places="${held#*twice=}"; places="${places%% *}"; whole="${held#*whole=}"; whole="${whole%% *}"
if [ "${places:-0}" -ge 50 ] 2>/dev/null && [ "${whole:-0}" -ge 200 ] 2>/dev/null; then
  check "every place was held to its lines whole, and texts with one command at two places were among them ($held)" ok
else
  check "every place was held to its lines whole, and texts with one command at two places were among them" "'${places:-none}' texts were refused for two places and '${whole:-none}' were held whole: '$held'"
fi
if [ -n "$emptied" ]; then check "the second judgement begins with nothing the first left on the Judge's classes ($emptied)" ok
else check "the second judgement begins with nothing the first left on the Judge's classes" "no count was printed: ${rows:0:300}"; fi
if [ -n "$again" ]; then check "the same call judged a second time in one process is judged twice again ($again)" ok
else check "the same call judged a second time in one process is judged twice again" "no count was printed: ${rows:0:300}"; fi
echo "  $counted"
echo "  $cheap"
echo "  $held"
echo "  $emptied"
echo "  $again"

echo "slack drafts only: fed() ends a heredoc where the shells of this machine end it (claude-config#3497)"

# fed() against the shells themselves (L58): each text is run in every shell found here, with cat
# as the program and nothing after the heredoc but lines that print nothing, so what the shell
# prints is what it fed. fed() must give that body ("same"); or at least those lines, for a
# heredoc that follows another on its line, where it goes on giving the lines it always gave
# ("more"); or raise the refusal (UnsureComment), for a row it does not vouch for ("refuse": it
# must raise, and may never give a body the shell does not feed); or, for an opener the loose
# reading never took, give the command's line and then that body, without calling it a body and
# without raising ("lines"). One line per finding, then the
# count of comparisons made and the shells they ran in, so comparing nothing is a finding and not
# a pass (L98).
cat > "$T/shells.py" <<'PY'
import importlib.util, os, re, shutil, subprocess, sys, tempfile

spec = importlib.util.spec_from_file_location("gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

SHELLS = {"bash": ["bash", "--noprofile", "--norc", "-c"], "sh": ["sh", "-c"], "zsh": ["zsh", "-f", "-c"]}
HAVE = [name for name in SHELLS if shutil.which(SHELLS[name][0])]
BS, TAB = "\\", "\t"
# (the command fed() is asked about, the whole text's lines, what fed() must do)
ROWS = [
    ("cat <<E", ["cat <<E", "a", "E"], "same"),
    ("cat <<E", ["cat <<E", "a", " E", "b", "E"], "same"),
    ("cat <<E", ["cat <<E", "a", "E ", "b", "E"], "same"),
    ("cat <<E", ["cat <<E", "a", TAB + "E", "b", "E"], "same"),
    ("cat <<-E", ["cat <<-E", "a", TAB + "E"], "same"),
    ("cat <<-E", ["cat <<-E", "a", " E", "b", TAB + TAB + "E"], "same"),
    ("cat <<'E'", ["cat <<'E'", "a", " E", "b", "E"], "same"),
    ("cat <<'E'", ["cat <<'E'", "a" + BS, "E"], "same"),
    ('cat <<"E"', ['cat <<"E"', "a", "E ", "b", "E"], "same"),
    ("cat <<E", ["cat <<E", "a" + BS + BS, "E"], "same"),
    ("cat <<E", ["cat <<E", "a + " + BS, "  b", "E"], "same"),
    ("cat <<E", ["cat <<E", "a", " E", "b"], "same"),
    ("cat <<'E'", ["cat <<'E'", "a", "E ", "b"], "same"),
    ('cat <<E"F"', ['cat <<E"F"', "a", "E", "b", "EF"], "same"),
    ("cat <<E-1", ["cat <<E-1", "a", "E", "b", "E-1"], "same"),
    ("cat <<E.x", ["cat <<E.x", "a", "E", "b", "E.x"], "same"),
    ("cat <<E" + BS + "OF", ["cat <<E" + BS + "OF", "a", "E", "b", "EOF"], "same"),
    ("cat <<B", [": <<A | cat <<B", "B", "A", "x", "B"], "more"),
    ("cat <<B", [": <<A | cat <<B", "a", "A", "x", " B", "y", "B"], "more"),
    ("cat <<" + BS + "E", ["cat <<" + BS + "E", "a", "E"], "lines"),
    ("cat <<" + BS + "E", ["cat <<" + BS + "E", "a", " E", "b", "E"], "lines"),
    ("cat <<" + BS + "E", ["cat <<" + BS + "E", "a", " E", "b"], "lines"),
    ("cat <<'E" + BS + "'", ["cat <<'E" + BS + "'", "a", "E", "b", "E" + BS], "lines"),
    ('cat <<"E F"', ['cat <<"E F"', "a", "E", "b", "E F"], "lines"),
    ("cat <<-" + BS + "E", ["cat <<-" + BS + "E", "a", " E", "b", TAB + "E"], "lines"),
    ("cat <<!", ["cat <<!", "a", "!"], "lines"),
    ("cat <<!", ["cat <<!", "a", " !", "b", "!"], "lines"),
    ("cat <<~E", ["cat <<~E", "a", "E", "b", "~E"], "lines"),
    ("cat <<!EOF", ["cat <<!EOF", "a", "EOF", "b", "!EOF"], "lines"),
    ("cat <<-~E", ["cat <<-~E", "a", " ~E", "b", TAB + "~E"], "lines"),
    ("cat <<E", ["cat <<E", "a" + BS, "E", "b", "E"], "refuse"),
    ("cat <<E", ["cat <<E", "a" + BS, "E", "b"], "refuse"),
    ("cat <<E", ["cat <<E", BS, "E", "b", "E"], "refuse"),
    ("cat <<E", ["cat <<E", "a", "E" + BS, "", "b", "E"], "refuse"),
]


def unquoted(command):
    return not re.search(r"['\"\\]", command.split("<<", 1)[1])


def as_fed(body, command):
    """body as the shell hands it on: in an unquoted heredoc a backslash and a line break vanish,
    and a backslash before a backslash is one."""
    if not unquoted(command):
        return body
    return re.sub(r"\\(\n|\\)", lambda m: "" if m.group(1) == "\n" else "\\", body)


made, d = 0, tempfile.mkdtemp()
for command, lines, want in ROWS:
    whole = "\n".join(lines) + "\n"
    where = whole.replace("\n", " (line break) ").replace(TAB, "(tab)")
    printed = {}
    for shell in HAVE:
        try:
            p = subprocess.run(SHELLS[shell] + [whole], cwd=d, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=20)
        except subprocess.TimeoutExpired:
            print("FAIL %s did not end within 20 seconds: %s" % (shell, where))
            continue
        printed[shell] = p.stdout.decode("utf-8", "replace").rstrip("\n")
    try:
        got = gate.Judge.fed(command, whole)
    except gate.UnsureComment:
        got = None
    for shell, out in printed.items():
        made += 1
        gave = None if got is None else as_fed(got[0], command).rstrip("\n")
        if want == "refuse":
            if got is not None:
                print("FAIL fed() did not refuse a heredoc it cannot vouch for, and gave %r where %s fed %r: %s"
                      % (got[0], shell, out, where))
        elif want == "lines":
            if got is None:
                print("FAIL fed() refused a heredoc whose opener the loose reading never took: %s" % where)
            elif got[1]:
                print("FAIL fed() called what it gave a body, for an opener the loose reading never took: %s" % where)
            elif got[0].rstrip("\n") != (command + "\n" + out).rstrip("\n"):
                print("FAIL fed() gave %r, which is not the command's line and then the %r that %s fed: %s"
                      % (got[0], out, shell, where))
        elif got is None:
            print("FAIL fed() refused a heredoc %s ends plainly: %s" % (shell, where))
        elif not got[1]:
            print("FAIL fed() gave no body for a heredoc %s gave one: %s" % (shell, where))
        elif gave != out and not (want == "more" and ("\n" + gave).endswith("\n" + out)):
            print("FAIL fed() gave %r where %s fed %r: %s" % (got[0], shell, out, where))
shutil.rmtree(d, ignore_errors=True)
print("made %d" % made)
# Each shell with the version it gives of itself, so a run says what it measured.
ASK = {"bash": "echo $BASH_VERSION", "sh": "echo ${BASH_VERSION:-${KSH_VERSION:-unnamed}}", "zsh": "echo $ZSH_VERSION"}
said = []
for shell in HAVE:
    p = subprocess.run(SHELLS[shell] + [ASK[shell]], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, timeout=20)
    said.append("%s=%s" % (shell, p.stdout.decode("utf-8", "replace").strip().replace(" ", "_") or "unnamed"))
print("shells %s" % " ".join(said))
PY
rows="$(python3 -B "$T/shells.py" "$DIR/slack_drafts_only_gate.py" 2>&1)"
made=0; ran=""
while IFS= read -r row; do
  case "$row" in
    "made "*) made="${row#made }" ;;
    "shells "*) ran="${row#shells }" ;;
    "") ;;
    *) check "fed() ends a heredoc where the shell ends it" "$row" ;;
  esac
done <<EOF
$rows
EOF
if [ "$made" -ge 20 ] 2>/dev/null; then check "fed() was held against the shells of this machine ($made comparisons, in: $ran)" ok
else check "fed() was held against the shells of this machine" "only '$made' comparisons were made, in: '$ran'"; fi
case " $ran " in *" bash="*) check "bash is among the shells fed() was held against" ok ;;
  *) check "bash is among the shells fed() was held against" "ran in: '$ran'" ;; esac
echo "  fed() held against the shells: $made comparisons, in: $ran"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
