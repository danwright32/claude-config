#!/bin/bash
# PreToolUse gate: refuse a Bash command whose `log`, in command position, would run zsh's own
# builtin rather than /usr/bin/log (claude-config#2200).
#
# WHY. zsh, which runs the Bash tool on both Macs, has a builtin named log (it lists logins), and a
# builtin wins over a program on PATH. Given any argument it prints `(eval):log:1: too many
# arguments` and nothing else. Reproduced on 2026-11-04: `log show --last 1m 2>/dev/null | wc -l`
# printed 0 with exit 0, and `/usr/bin/log show --last 1m 2>/dev/null | wc -l` printed 15793. With the
# error hidden or piped on, the empty answer reads as a finding: no log entries matched.
#
# WHAT IT DOES. The command is read word by word by zsh_builtin_gate.py over lib/shell-words.py, the
# one reading every gate shares, so log is found in command position after a cd, in a chain, a
# subshell, a group, a substitution, behind an assignment or a redirection, and behind the modifiers
# measured to still run the builtin (builtin, noglob, nocorrect, -, exec, time), quoted or
# backslashed, and inside eval or zsh -c. It passes a bare `log` (the builtin with no argument works),
# /usr/bin/log, `command log` and `env log` (both run the program), sudo, nohup and xargs (they run
# the program), bash -c and sh -c (another shell, where log is the program), and every mention: git
# log, a log file, an echo, a grep pattern, a commit message, a heredoc body. Outside zsh nothing is
# refused unless the command itself starts zsh.
#
# When it cannot read the command word by word (no python3, the judge or lib/shell-words.py missing,
# a payload nothing can parse or read as a call), it refuses only a command whose text puts log and
# an argument at the start of a command or a quoted string, saying it could not be read, and erring
# toward refusing since it cannot tell which shell runs it; everything else passes. The fix is always
# one word, so there is no override.

HOW="In zsh, which runs the Bash tool here, log is the shell's own builtin, not the macOS log tool, so any argument makes it print only \"(eval):log:1: too many arguments\" and the real tool never runs. With the error hidden, or piped into wc, grep or tail, that reads as no matching log entries rather than as a failure (claude-config#2200)."

# Bash builtins only up to the python call: with python3 missing, PATH may hold nothing else.
IFS= read -r -d '' payload

# The raw payload is matched in the session locale and then in C, since under a UTF-8 locale =~
# stops at a byte that is not UTF-8 and every word after it reads as absent (claude-config#1885).
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }

# Every Bash call passes through here, and nearly none name log as a word: answer those at once. The
# payload is JSON, so a newline or tab before the word is the two characters \n or \t. Any end of
# the word passes on, since a command sent as a list of its words (claude-config#2057) ends it with
# a quote and a comma.
FAST='(^|[^A-Za-z0-9_./~-]|\\[nt])log([^A-Za-z0-9_./~-]|$)'
payload_match "$payload" "$FAST" || exit 0

shell_name="${SHELL##*/}"
if [ -n "$shell_name" ] && [ "$shell_name" != zsh ]; then
  case "$payload" in *zsh*) ;; *) exit 0 ;; esac
fi

# Refuse a command whose text puts log and an argument at the start of a command or of a quoted
# string, saying it could not be read word by word; pass anything else. The text is every word the
# payload holds (lib/push-scope.sh ps_payload_text, claude-config#2057), so a command sent as a list
# of its words or an input sent as one string is read too; without that library, the raw payload.
not_judged() {   # $1 = why it could not be read
  local text="$payload"
  local tool='"tool_name"[[:space:]]*:[[:space:]]*"Bash"'
  local crude='(^|"command"[[:space:]]*:[[:space:]]*"|[;&|({`'\''"'$'\n'']|\\n|\$\()[[:space:]]*log[[:space:]]+[^[:space:]"]'
  payload_match "$payload" "$tool" || exit 0
  [ "$have_ps" = 1 ] && text="$(ps_payload_text "$payload")"
  payload_match "$text" "$crude" || exit 0
  echo "BLOCKED: this command seems to run log with an argument, and it could not be read word by word: $1. $HOW Write the full path, /usr/bin/log, or put command in front (command log), which looks only for programs." >&2
  exit 2
}

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
JUDGE="$HOOK_DIR/zsh_builtin_gate.py"

# The shared readers: ps_reader_missing asks whether python3 is installed (claude-config#480), and
# ps_payload_text gives the crude reading every word of the payload. Without the library the gate
# still judges, asking for python3 itself, so a missing library never refuses fewer commands.
have_ps=0
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && have_ps=1

if [ "$have_ps" = 1 ]; then ps_reader_missing python3; else ! command -v python3 >/dev/null 2>&1; fi \
  && not_judged "python3 is not on PATH, and the command's words are read with it"
[ -f "$JUDGE" ] || not_judged "$JUDGE, the judge, is missing (reinstall the hooks with claude-sync pull)"

# The judge exits 0 to pass, 3 to refuse (printing the fix), and 4 when it could not read the
# command (printing why). Anything else is the judge failing, and the crude reading decides.
said="$(printf '%s' "$payload" | python3 "$JUDGE")"
case $? in
  0) exit 0 ;;
  3)
    echo "BLOCKED: this command runs log with an argument. $HOW Write the full path instead, $said, or put command in front (command log), which looks only for programs." >&2
    exit 2 ;;
  4) not_judged "$said" ;;
  *) not_judged "$JUDGE failed while reading it" ;;
esac
