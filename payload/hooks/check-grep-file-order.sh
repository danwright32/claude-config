#!/bin/bash
# PreToolUse gate: refuse a Bash command whose grep, as the Bash tool's own shell runs it, drops file
# names (-h) over more than one file, since the lines then come out in whichever order the files
# finish rather than the order they were named (claude-config#3546).
#
# WHY. In a Claude Code Bash call grep is not /usr/bin/grep: it is a shell function from Claude
# Code's shell snapshot that runs its built in ugrep, which searches several files at once. With -h
# nothing on a line says which file it came from, so a reader mapping lines back to files by position
# gets the wrong mapping with no error. Reproduced on 2026-11-26 on the personal MacBook: `grep -h
# result big small1 small2` came out of argument order in 10 of 10 runs, and `command grep` kept it in
# 5 of 5. The first report (2026-11-22) was a finisher mapping three suite result lines by position
# and getting two counts swapped. The rtk hook is not involved: rtk declines every grep.
#
# WHAT IT DOES. The command is read word by word by grep_file_order_gate.py over lib/shell-words.py,
# the one reading every gate shares, so grep is found in command position after a cd, in a chain, a
# pipeline, a subshell, a substitution, eval and a loop, behind an assignment or a redirection, and
# behind noglob, nocorrect and exec, quoted or backslashed. It refuses one with -h (or --no-filename)
# and two or more files, or one word the shell may expand into several (a glob, a brace list). It
# passes one file, a grep without -h or with -H after it, a grep held to one job (-J1, --jobs=1, which
# keeps the order), and every spelling that runs the real binary: command grep, a full path, env,
# xargs, timeout, find -exec, and bash -c or zsh -c, another shell with no such function. Mentions
# (git grep, an echo, a commit message) pass.
#
# When it cannot read the command word by word (no python3, the judge or lib/shell-words.py missing,
# a payload nothing can parse or read as a call), it refuses only a command whose text puts grep with
# -h or --no-filename at the start of a command or a quoted string, saying it could not be read;
# everything else passes. The fix is always one word, so there is no override.

HOW="In a Claude Code Bash call grep is Claude Code's built in ugrep, which searches several files at once, so with -h, which drops the file names, the lines come out in whichever order the files finish rather than the order they were named, and nothing says so (claude-config#3546)."
FIX="Put command in front (command grep), which runs the real grep and keeps the order, or drop -h so each line names its file."

# Bash builtins only up to the python call: with python3 missing, PATH may hold nothing else.
IFS= read -r -d '' payload

# The raw payload is matched in the session locale and then in C, since under a UTF-8 locale =~
# stops at a byte that is not UTF-8 and every word after it reads as absent (claude-config#1885).
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }

# Every Bash call passes through here, and few name grep with an h flag: answer the rest at once.
FAST_GREP='(^|[^A-Za-z0-9_./~-]|\\[nt])grep([^A-Za-z0-9_./~-]|$)'
FAST_H='(^|[^A-Za-z0-9_-])-[A-Za-z0-9]*h|--no-filename'
payload_match "$payload" "$FAST_GREP" && payload_match "$payload" "$FAST_H" || exit 0

# Refuse a command whose text puts grep with -h at the start of a command or of a quoted string,
# saying it could not be read word by word; pass anything else. The text is every word the payload
# holds (lib/push-scope.sh ps_payload_text, claude-config#2057); without that library, the raw payload.
not_judged() {   # $1 = why it could not be read
  local text="$payload"
  local tool='"tool_name"[[:space:]]*:[[:space:]]*"Bash"'
  local crude='(^|"command"[[:space:]]*:[[:space:]]*"|[;&|({`'\''"'$'\n'']|\\n|\$\()[[:space:]]*grep[[:space:]]+([^;&|"]*[[:space:]])?(-[A-Za-z0-9]*h|--no-filename)'
  payload_match "$payload" "$tool" || exit 0
  [ "$have_ps" = 1 ] && text="$(ps_payload_text "$payload")"
  if payload_match "$text" "$crude"; then
    echo "BLOCKED: this command seems to run grep with -h, and it could not be read word by word: $1. $HOW $FIX" >&2
    exit 2
  fi
  exit 0
}

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
JUDGE="$HOOK_DIR/grep_file_order_gate.py"

# The shared readers: ps_reader_missing asks whether python3 is installed (claude-config#480), and
# ps_payload_text gives the crude reading every word of the payload. Without the library the gate
# still judges, asking for python3 itself, so a missing library never refuses fewer commands.
have_ps=0
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && have_ps=1

if [ "$have_ps" = 1 ]; then ps_reader_missing python3; else ! command -v python3 >/dev/null 2>&1; fi \
  && not_judged "python3 is not on PATH, and the command's words are read with it"
[ -f "$JUDGE" ] || not_judged "$JUDGE, the judge, is missing (reinstall the hooks with claude-sync pull)"

# The judge exits 0 to pass, 3 to refuse, and 4 when it could not read the command (printing why).
# Anything else is the judge failing, and the crude reading decides.
said="$(printf '%s' "$payload" | python3 "$JUDGE")"
case $? in
  0) exit 0 ;;
  3)
    echo "BLOCKED: this command runs grep with -h over more than one file. $HOW $FIX" >&2
    exit 2 ;;
  4) not_judged "$said" ;;
  *) not_judged "$JUDGE failed while reading it" ;;
esac
