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
#
# EVERY REFUSAL IS RECORDED (claude-config#1492), overrides included, so how often it fires and on
# what shapes is read from real use rather than guessed: one tab separated line of time (epoch), Mac,
# wrapper (`bash -c`, `eval`, `find -execdir`, ...), reason category and outcome (refused or
# overridden), appended to ${WRAPPED_REFUSAL_LEDGER_DIR:-~/.claude/state/wrapped-commands}/refusals.tsv.
# Under ~/.claude/state, per Mac and never synced (claude-sync mirrors hooks, agents, commands,
# audits, mods and skills only), beside the push gate ledger. Never the command and never a path: a
# script file's name or a variable's value is somebody's content, so the reason is recorded as a
# category, not the sentence the refusal prints. Read with lib/wrapped-refusal-report.py. Capped at
# WRAPPED_REFUSAL_LEDGER_MAX lines (5000, about 250 KB): past that and a tenth more it keeps the
# newest, so it is rewritten once in hundreds of refusals rather than on every one.
#
# The record never changes the decision (L95). The verdict is fixed before anything is written, and a
# record that cannot be written, or trimmed, is said once in what the gate prints: in the refusal
# itself, or for an override, which runs, as a systemMessage shown to Dan.

OVERRIDE=SKIP_WRAPPED_CHECK
ASK="Write out the command it runs in full, as a command of its own or as a literal string, so every gate can read it. If this refusal is wrong, say so and add $OVERRIDE=1 to that one command."

payload="$(cat)"
# Every Bash call passes through here, and nearly none name a wrapper beside git, gh or rtk: answer
# those at once, before the shared reader is even loaded. The payload is JSON, so a line break or a
# tab before a word is written \n or \t there.
[[ $payload =~ (^|[^A-Za-z0-9_.-]|\\[nt])(bash|sh|zsh|dash|ksh|eval|env|find|watch|script|parallel)([^A-Za-z0-9_.-]|$) ]] || exit 0
# The wrapper the text names, which is all a refusal made with no reader to judge it can record.
NAMED_WRAPPER="${BASH_REMATCH[2]}"
[[ $payload =~ (^|[^A-Za-z0-9_.-]|\\[nt])(git|gh|rtk)([^A-Za-z0-9_.-]|$) ]] || exit 0

LEDGER_DIR="${WRAPPED_REFUSAL_LEDGER_DIR:-$HOME/.claude/state/wrapped-commands}"
LEDGER="$LEDGER_DIR/refusals.tsv"
LEDGER_MAX="${WRAPPED_REFUSAL_LEDGER_MAX:-5000}"
case "$LEDGER_MAX" in ''|*[!0-9]*|0) LEDGER_MAX=5000 ;; esac
RECORD_NOTE=""

# Appends one line for this refusal. Sets RECORD_NOTE, the one sentence saying so, when the line
# could not be written or the record could not be trimmed; never exits and never changes the verdict.
# Only ordinary tools, never the shared reader, so a refusal made because the reader is missing is
# recorded as well.
record_refusal() {   # $1 = wrapper  $2 = reason category  $3 = refused|overridden
  local wrapper="$1" reason="$2" now host err n trim re='^[a-z]+( -[A-Za-z]+)?$'
  # Both come from fixed vocabularies (`env -S` among them); anything else is recorded as "other",
  # never as text.
  [[ $wrapper =~ $re ]] || wrapper=other
  [[ $reason =~ ^[a-z0-9-]+$ ]] || reason=other
  now="$(date +%s 2>/dev/null)"
  case "$now" in
    ''|*[!0-9]*) RECORD_NOTE="This refusal could not be recorded in $LEDGER (the time could not be read), so the count of how often this gate fires (claude-config#1492) is missing it."; return 0 ;;
  esac
  host="${HOSTNAME:-$(hostname 2>/dev/null)}"; host="${host%%.*}"; host="${host//[!A-Za-z0-9-]/_}"
  err="$( { mkdir -p "$LEDGER_DIR" && printf '%s\t%s\t%s\t%s\t%s\n' "$now" "${host:-unknown}" "$wrapper" "$reason" "$3" >> "$LEDGER"; } 2>&1 )" || {
    err="${err%%$'\n'*}"
    RECORD_NOTE="This refusal could not be recorded in $LEDGER (${err:-the write failed}), so the count of how often this gate fires (claude-config#1492) is missing it."
    return 0
  }
  n="$(wc -l < "$LEDGER" 2>/dev/null)"; n="${n//[!0-9]/}"
  if [ "${n:-0}" -gt $((LEDGER_MAX + LEDGER_MAX / 10)) ]; then
    # A copy beside it, then a rename, so the record is never half written; a refusal that lands
    # between the two is lost, which at worst drops one line in hundreds.
    trim="$(mktemp "$LEDGER.trim.XXXXXX" 2>/dev/null)" \
      && tail -n "$LEDGER_MAX" "$LEDGER" > "$trim" 2>/dev/null \
      && mv -f "$trim" "$LEDGER" 2>/dev/null \
      || { [ -n "$trim" ] && rm -f "$trim" 2>/dev/null
           RECORD_NOTE="This refusal was recorded, but $LEDGER could not be trimmed to its newest $LEDGER_MAX lines, so it is growing past its cap (claude-config#1492)."; }
  fi
  return 0
}

# What an override that runs says about a record it could not make: Claude Code shows a
# systemMessage to Dan, where stderr from a hook that allows the call is shown to nobody.
say_record_note() {
  [ -n "$RECORD_NOTE" ] || return 0
  local m="${RECORD_NOTE//\\/\\\\}"; m="${m//\"/\\\"}"
  printf '{"systemMessage": "%s"}\n' "$m"
}

not_judged() {   # $1 = what went wrong, as a clause  $2 = its reason category
  case "$payload" in
    *"$OVERRIDE=1"*) record_refusal "$NAMED_WRAPPER" "$2" overridden; say_record_note; exit 0 ;;
  esac
  record_refusal "$NAMED_WRAPPER" "$2" refused
  echo "BLOCKED: this command names a shell, eval, env, find, watch, script or parallel beside git, gh or rtk, and whether it runs one of them where no gate can see it could not be read: $1. So it is refused rather than passed unjudged (claude-config#1478). $ASK${RECORD_NOTE:+ $RECORD_NOTE}" >&2
  exit 2
}

# The category of each reason lib/shell-words.py gives (its WHY_ sentences), matched on how each
# begins. test-check-wrapped-commands.sh records one refusal for every reason and fails when the
# reader gains one, so a new reason cannot sit in "other" unnoticed.
why_category() {   # $1 = the reason, as the reader says it; sets REASON
  case "$1" in
    "its command is a variable"*) REASON=variable ;;
    "it holds a quote that never closes"*) REASON=quote ;;
    "it reads its commands from its input"*) REASON=input ;;
    "it is wrapped more than"*) REASON=depth ;;
    "it changes directory"*) REASON=eval-cd ;;
    "it runs the script file"*) REASON=script-file ;;
    "it runs its command in the directory of each file"*) REASON=execdir ;;
    "its "*" command never ends"*) REASON=unended ;;
    *) REASON=other ;;
  esac
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null \
  || not_judged "$HOOK_DIR/lib/push-scope.sh, the reader of the command, could not be loaded (reinstall the hooks with claude-sync pull)" reader-lib-missing

command -v python3 >/dev/null 2>&1 \
  || not_judged "python3 is not on PATH, and the command's words are read with it" no-python3

parsed="$(ps_parse_payload "$payload" raw)" \
  || not_judged "it could not read the hook payload (neither jq nor python3 could parse it as JSON)" payload-unreadable
cmd="${parsed%%$'\x1f'*}"
[ -n "$cmd" ] || exit 0
[[ $cmd =~ (^|[^A-Za-z0-9_.-])(git|gh|rtk)([^A-Za-z0-9_.-]|$) ]] || exit 0
# The override is read here and honoured below, once the command has been judged, so an override of
# a real refusal is recorded as one (claude-config#1492). Only a command carrying it pays the reading.
overridden=0
ps_has_override "$cmd" "$OVERRIDE" && overridden=1

ps__read "$cmd"
case $? in
  0|3) ;;
  *)
    if [ -f "$PS_SHELL_WORDS" ]; then not_judged "$PS_SHELL_WORDS could not read the command" reader-failed; fi
    not_judged "$PS_SHELL_WORDS, the reader of the command, is missing (reinstall the hooks with claude-sync pull)" reader-missing ;;
esac

ps_unreadable "$cmd" || exit 0
why_category "$PS_UNREAD_WHY"
if [ "$overridden" = 1 ]; then
  record_refusal "$PS_UNREAD_WRAPPER" "$REASON" overridden
  say_record_note
  exit 0
fi
record_refusal "$PS_UNREAD_WRAPPER" "$REASON" refused
echo "BLOCKED: this command runs \`$PS_UNREAD_WRAPPER\` on a command that cannot be read before it runs: $PS_UNREAD_WHY. It also names git, gh or rtk, so the push, commit, add, merge, issue and rtk gates cannot see what it would run, and it is refused rather than passed unjudged (claude-config#1478). $ASK${RECORD_NOTE:+ $RECORD_NOTE}" >&2
exit 2
