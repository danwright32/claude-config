#!/bin/bash
# PreToolUse gate: refuse a Bash command that names git, gh or rtk and hands a wrapper a command
# nobody can read before it runs (claude-config#1478).
#
# WHY. Every gate reads a command through the shared reader (lib/push-scope.sh over
# lib/shell-words.py), and that reader now reads through the programs that run a command for you:
# a shell's -c string (`bash -c 'git push --force'`), eval, env -S, find's -exec and -ok, watch,
# script, GNU parallel, and the launchers (xargs, nohup, time, nice, timeout, caffeinate, stdbuf,
# doas, rtk proxy). So the push gates, the add scope gate, the merge gates, the issue gates and the
# rtk gates each judge a wrapped command exactly as the bare one. Some wrapped commands cannot be
# read at all: `bash -c "$CMD"`, where the command is a variable or a substitution known only as it
# runs; a string holding a quote that never closes; a shell fed its commands on its input (a pipe, a
# here string, a heredoc, a file) or running a script file (`bash ./x.sh`), whose commands are in the
# file; parallel reading its commands from its input; find -execdir, which runs in each found file's
# directory; a find -exec that never ends; wrapping past the reader's depth; an eval that changes
# directory, which leaves every directory read after it wrong.
# Passed, those would walk past every gate unjudged, which is indistinguishable from judged and
# allowed (L42, L98). Each gate refusing them itself would print the same refusal once per gate, so
# they are refused here, once, for all of them.
#
# WHAT IT DOES. Refuses (exit 2) a command whose reading holds a wrapper that cannot be read, when the
# command names git, gh or rtk anywhere, since those are what the gates guard. A wrapper that can be
# read passes here and is judged by the gates themselves, and so does an unreadable one in a command
# naming none of them (`eval "$(ssh-agent -s)"` on its own). A mention (echo, a grep pattern, a
# commit message, a heredoc body) is no wrapper. A command naming no wrapper and none of the three
# passes before anything is loaded.
#
# When it cannot read the command at all (no python3, a missing lib, a payload nothing can read) and
# the text names both a wrapper and one of the three, it refuses, saying it could not judge.
#
# Override, explained to Dan first and never silently: SKIP_WRAPPED_CHECK=1 as an inline prefix on
# the command, good for that one command.

OVERRIDE=SKIP_WRAPPED_CHECK
ASK="Write out the command it runs in full, as a command of its own or as a literal string, so every gate can read it. If this refusal is wrong, say so and add $OVERRIDE=1 to that one command."

payload="$(cat)"
# Every Bash call passes through here, and nearly none name a wrapper beside git, gh or rtk: answer
# those at once, before the shared reader is even loaded. The payload is JSON, so a line break or a
# tab before a word is written \n or \t there.
[[ $payload =~ (^|[^A-Za-z0-9_.-]|\\[nt])(bash|sh|zsh|dash|ksh|eval|env|find|watch|script|parallel)([^A-Za-z0-9_.-]|$) ]] || exit 0
[[ $payload =~ (^|[^A-Za-z0-9_.-]|\\[nt])(git|gh|rtk)([^A-Za-z0-9_.-]|$) ]] || exit 0

not_judged() {   # $1 = what went wrong, as a clause
  case "$payload" in *"$OVERRIDE=1"*) exit 0 ;; esac
  echo "BLOCKED: this command names a shell, eval, env, find, watch, script or parallel beside git, gh or rtk, and whether it runs one of them where no gate can see it could not be read: $1. So it is refused rather than passed unjudged (claude-config#1478). $ASK" >&2
  exit 2
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null \
  || not_judged "$HOOK_DIR/lib/push-scope.sh, the reader of the command, could not be loaded (reinstall the hooks with claude-sync pull)"

command -v python3 >/dev/null 2>&1 \
  || not_judged "python3 is not on PATH, and the command's words are read with it"

parsed="$(ps_parse_payload "$payload" raw)" \
  || not_judged "it could not read the hook payload (neither jq nor python3 could parse it as JSON)"
cmd="${parsed%%$'\x1f'*}"
[ -n "$cmd" ] || exit 0
ps_has_override "$cmd" "$OVERRIDE" && exit 0
[[ $cmd =~ (^|[^A-Za-z0-9_.-])(git|gh|rtk)([^A-Za-z0-9_.-]|$) ]] || exit 0

ps__read "$cmd"
case $? in
  0|3) ;;
  *)
    if [ -f "$PS_SHELL_WORDS" ]; then not_judged "$PS_SHELL_WORDS could not read the command"; fi
    not_judged "$PS_SHELL_WORDS, the reader of the command, is missing (reinstall the hooks with claude-sync pull)" ;;
esac

ps_unreadable "$cmd" || exit 0
echo "BLOCKED: this command runs \`$PS_UNREAD_WRAPPER\` on a command that cannot be read before it runs: $PS_UNREAD_WHY. It also names git, gh or rtk, so the push, commit, add, merge, issue and rtk gates cannot see what it would run, and it is refused rather than passed unjudged (claude-config#1478). $ASK" >&2
exit 2
