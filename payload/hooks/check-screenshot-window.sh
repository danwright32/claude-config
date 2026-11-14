#!/bin/bash
# PreToolUse gate: refuse a Bash command that runs screencapture on anything wider than one window
# named by its id (claude-config#2908).
#
# WHY. On 2026-11-13 a session checking whether a dialog was blocking one app ran a full screen
# `screencapture -x` while another app was in front, and that app's private content landed in the
# transcript. The file was deleted, but the content had already been read. A screenshot taken to
# check one app's state must hold only that app's window: `screencapture -l <windowid> <file>`, the
# id resolved for the target app's process, or Dan is asked to look.
#
# WHAT IT DOES. The command is read word by word by screenshot_window_gate.py over lib/shell-words.py,
# the one reading every gate shares, so screencapture is found in command position after a cd, in a
# chain, a pipe, a subshell or a substitution, by its full path or in another case, behind
# assignments, redirections, env, sudo, command, exec, nohup, timeout, time, rtk proxy and xargs,
# inside bash -c, zsh -c and eval, and in a script file the command runs. It is refused unless it
# names one window with -l and an id. Every mention passes: echo, grep, man, which, command -v, a
# commit message, a quoted heredoc body. With no arguments screencapture prints its usage and
# captures nothing, so that passes too; behind xargs, which adds words nobody wrote, it does not.
#
# REGION, INTERACTIVE AND VIDEO FLAGS. Refused even beside -l, since each takes more than the one
# window or waits for a person: -R (a rectangle, whatever is on screen there), -S (the screen instead
# of the window), -D (a display), -p (the saved screenshot settings, which ignore the file), -v and
# -V (a video of the screen), and the interactive -i, -s, -w, -W, -J, -U and -u. An interactive
# capture waits for a click from a person who may not be there (overnight, nobody is), and a click
# or the space bar can take any part of the screen; when a person should choose what is captured,
# ask Dan to look instead.
#
# When it cannot read the command word by word (no python3, the judge or lib/shell-words.py missing,
# a payload nothing can parse or read as a call), it refuses a command whose text puts screencapture
# at the start of a command or of a quoted string, saying it could not be read, since it cannot tell
# what the capture would hold; everything else passes. The fix is always available (name the window
# with -l), so there is no override, as with check-zsh-builtins.sh.

HOW="A capture of the screen, or of a region or a selection of it, takes whatever is on screen, which can be another app's private content: on 2026-11-13 a full screen screencapture -x put one into a transcript (claude-config#2908). Capture only the target app's window by its id: screencapture -l <windowid> <file>, the id being the window number CGWindowListCopyWindowInfo gives for a window owned by the target app's process (its PID resolved from its executable path, as CLAUDE.md \"Driving Dan's Machine\" says). When the window cannot be resolved, or a person should choose what is captured, ask Dan to look instead."

# Bash builtins only up to the python call: with python3 missing, PATH may hold nothing else.
IFS= read -r -d '' payload

# The Mac's file system finds the program in any case, so every match here ignores case. The raw
# payload is matched in the session locale and then in C, since under a UTF-8 locale =~ stops at a
# byte that is not UTF-8 (claude-config#1885).
shopt -s nocasematch
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }

# Every Bash call passes through here, and nearly none name screencapture: answer those at once. A
# script file the command runs holds its commands in the file, so a call that may run one (a shell
# script's name, a shell followed by a word, a path from here, source or .) goes to the judge too,
# which reads the file (lib/shell-words.py every_command, claude-config#2301). The payload's own
# "tool_name":"Bash" is followed by a quote, never a space, so it sends nothing on.
SCRIPT_RUN='\.(sh|bash|zsh|ksh|command)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])(bash|sh|zsh|dash|ksh|source)[[:space:]]|\./|(^|[;&|(]|\\n)[[:space:]]*\.[[:space:]]'
[[ $payload == *screencapture* ]] || payload_match "$payload" "$SCRIPT_RUN" || exit 0

# Refuse a command whose text puts screencapture at the start of a command or of a quoted string
# (behind a path, or one of the commonest runners), saying it could not be read word by word; pass
# anything else. The text is every word the payload holds (lib/push-scope.sh ps_payload_text,
# claude-config#2057); without that library, the raw payload.
not_judged() {   # $1 = why it could not be read
  local text="$payload"
  local tool='"tool_name"[[:space:]]*:[[:space:]]*"Bash"'
  local crude='(^|"command"[[:space:]]*:[[:space:]]*"|[;&|({`'\''"'$'\n'']|\\n|\$\()[[:space:]]*((env|sudo|command|exec|nohup|time)[[:space:]]+)*([^[:space:];&|"]*/)?screencapture([[:space:]"]|\\n|$)'
  payload_match "$payload" "$tool" || exit 0
  [ "$have_ps" = 1 ] && text="$(ps_payload_text "$payload")"
  if payload_match "$text" "$crude"; then
    echo "BLOCKED: this command seems to run screencapture, and it could not be read word by word: $1. $HOW" >&2
    exit 2
  fi
  exit 0
}

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
JUDGE="$HOOK_DIR/screenshot_window_gate.py"

# The shared readers: ps_reader_missing asks whether python3 is installed (claude-config#480), and
# ps_payload_text gives the crude reading every word of the payload. Without the library the gate
# still judges, asking for python3 itself, so a missing library never refuses fewer commands.
have_ps=0
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && have_ps=1

if [ "$have_ps" = 1 ]; then ps_reader_missing python3; else ! command -v python3 >/dev/null 2>&1; fi \
  && not_judged "python3 is not on PATH, and the command's words are read with it"
[ -f "$JUDGE" ] || not_judged "$JUDGE, the judge, is missing (reinstall the hooks with claude-sync pull)"

# The judge exits 0 to pass, 3 to refuse (printing what the capture would take), and 4 when it could
# not read the command (printing why). Anything else is the judge failing, and the crude reading
# decides.
said="$(printf '%s' "$payload" | python3 "$JUDGE")"
case $? in
  0) exit 0 ;;
  3)
    echo "BLOCKED: this command runs screencapture $said. $HOW" >&2
    exit 2 ;;
  4) not_judged "$said" ;;
  *) not_judged "$JUDGE failed while reading it" ;;
esac
