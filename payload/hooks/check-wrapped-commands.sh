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
# commit message, a heredoc body) is no wrapper. A command naming none of the three, or naming no
# wrapper and running no script by its path, passes before anything is loaded.
#
# A SCRIPT RUN BY ITS PATH (claude-config#1623). `./build.sh && git push` runs a script file exactly
# as `bash ./build.sh && git push` does, and passed here unread, since it names no shell. The reader
# (lib/shell-words.py _script_run) now reports a command word holding a slash as a script file run
# directly (wrapper `direct`), and `source` or `.` with a file (wrapper `source`), with the reason a
# shell running a script file gives, so each is refused beside git, gh or rtk the same, and the
# declared scripts below keep their declarations run either way. It judges the word alone and opens no
# file. Not a script file: a path named git, gh or rtk, which every gate reads by that name, and a
# program in the directories the system and Homebrew install into (shell-words.py PROGRAM_DIRS). Still
# unread and passed: a script on PATH run by its bare name, an interpreter running a file (`python3
# x.py`), a command word that is a variable with no slash, one whose name before its first slash
# holds = or : (an assignment or a URL to both readings), and a function or alias. The fast path
# below answers a command running no script by its path before the reader loads (RUNS_FILE_*).
#
# A SCRIPT WHOSE ARGUMENTS ARE DATA (claude-config#1574). A script file cannot be read, so `bash x.sh`
# beside git, gh or rtk is refused, and that included those words inside a quoted argument: the
# documented `bash ~/.claude/hooks/lib/issue-spool.sh note . "<finding>" "<who>"` was refused for any
# finding about the three tools (4 of the first 14 refusals recorded, 2026-10-22 to 23). A script
# could run an argument, so a quoted argument is never data in general. It is data only for a script
# subcommand declared below, whose argument handling has been read and runs none of them, and only
# when the command is that call alone, read by lib/shell-words.py data_blanked: `bash` (or nothing,
# the script run by its path, claude-config#1623), the declared path (~/ or the home directory
# written out), the subcommand, then words, and nothing a shell would do
# beyond splitting words and removing quotes. Each argument quoted whole is set aside, and the command
# passes only if what is left names none of the three. Every other shape is refused as before, and so
# is a note the reader cannot judge. The milestone duplicate check is declared the same way, every
# argument of it (claude-config#1610), and in front of either call one thing may stand, the account
# rule's GH_TOKEN=$(gh auth token -u <login>) with a plain login, to read another account's repository;
# behind it only 2>&1 and pipes into grep, head, tail or cut (lib/shell-words.py DATA_FILTERS). A
# declared script refused for its shape is told the shapes its declared call passes in.
#
# The declared scripts are DATA_ARGUMENT_SCRIPTS, below.
#
# A CALL DECLARED READ ONLY (claude-config#1669). `claude-sync lesson <id>` only reads, so, unlike the
# scripts above, it may stand BESIDE git, gh or rtk: as a command of its own of exactly the declared
# shape (read_only_record) it is no unread wrapper, and the refusal is judged on the command's other
# unread records only (first_unexcused). The declared calls are READ_ONLY_CALLS, below.
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

# The scripts whose arguments are data, each "<path under ~/> <subcommand>" when only that
# subcommand's are, or "<path under ~/>" when every argument the script takes is.
#   issue-spool.sh note (claude-config#1574): issue_spool_note hands the text and the reporter to
#     python as argv strings, and the directory to cd and git -C as a path; none is run as a command.
#   milestone-candidates.sh, the duplicate check (claude-config#1610): the repository goes to gh as
#     --repo and into the path of a GET, --like to python as an argv string, --limit and --show to
#     python's int() and gh's --limit, --snapshot to cat, --closed-since only once it matches a date;
#     it only reads from GitHub, runs none of them as a command, and writes only its own temp files.
# A new entry needs the same reading of its script, and test-check-wrapped-commands.sh fails until it
# is changed with it. The ~/ is literal: the reader matches it as written, and against the home
# directory. In front of a declared call only the account rule's GH_TOKEN=$(gh auth token -u <login>)
# may stand (lib/shell-words.py DATA_TOKEN_PREFIX), and nothing else.
# shellcheck disable=SC2088
DATA_ARGUMENT_SCRIPTS=(
  "~/.claude/hooks/lib/issue-spool.sh note"
  "~/.claude/skills/milestone/milestone-candidates.sh"
)

# The script calls that are read only, each "<path under ~/> <subcommand>", taking one plain id
# (claude-config#1669). Unlike the scripts above, such a call may stand BESIDE git, gh or rtk: it runs
# none of them, so it is no unread wrapper, and the rest of the command is judged by the gates as
# usual. Only as a command of its own (read_only_record): nothing in front, one id of letters and
# digits after, and at most 2>&1 or a pipe behind.
#   claude-sync lesson, by the live clone's path (Dan, 2026-10-24: "Allow lesson only"): do_lesson
#     reads LESSONS.md, hands the id to awk as a -v string and prints one entry; it takes no lock,
#     writes nothing and runs no git, gh or rtk, and nothing claude-sync does before its dispatch
#     does either. Every other subcommand (sync, send, pull, next-lesson, ...) commits, pushes, pulls
#     or reserves, and stays refused. The development checkout's ./claude-sync is not declared: it is
#     a copy a branch may be changing.
# A new entry is Dan's decision, and test-check-wrapped-commands.sh fails until it is changed with it.
# shellcheck disable=SC2088
READ_ONLY_CALLS=(
  "~/claude-config-sync/claude-sync lesson"
)

# A script run by its path, or sourced, where a command can begin (claude-config#1623), read off the
# payload as written, so a command naming git with paths only as its arguments (`git -C /x add ./y`)
# is still answered before the reader loads. A command begins at the start of the command, after
# ; & | ( ` ! or `{ `, or a line break, past blanks, reserved words, assignments (`X="a b" ./x`,
# `T=$(gh auth token -u x) ./x`) and runners with their options and values (`sudo -u bob ./x`,
# `timeout 30 ./x`); what can begin it is `source`, `.`, or a path: a word holding a slash, its name
# before the slash free of = and : as the reader requires, or starting ~ or /, or a variable then a
# slash, optionally quoted or escaped. It must be a superset of what the reader calls a script run,
# since a command it misses passes unread, so it errs wide, and test-check-wrapped-commands.sh runs
# every refused case through a copy of the guard with no reader to hold it to that. The payload is
# JSON: a line break is \n and a double quote \" there.
RUNS_FILE_AT='(^|[;&|(`!]|\{[[:space:]]|\\[nt]|"command"[[:space:]]*:[[:space:]]*")'
RUNS_FILE_VALUE="(\\\$\\([^()]*\\)|\\\\\"[^\"]*\\\\\"|'[^']*'|[^[:space:];&|])*"
RUNS_FILE_PAST="([[:space:]]|(then|do|else|elif|if|while|until|time)[[:space:]]|[A-Za-z_][A-Za-z0-9_]*=$RUNS_FILE_VALUE[[:space:]]|(nohup|exec|command|sudo|doas|xargs|caffeinate|stdbuf|nice|timeout|gtimeout|env|proxy)([[:space:]]+(-[^[:space:];&|]*([[:space:]]+[^-[:space:];&|][^[:space:];&|]*)?|[0-9][^[:space:];&|]*|[A-Za-z_][A-Za-z0-9_]*=$RUNS_FILE_VALUE))*[[:space:]])*"
SQ="'"
RUNS_FILE_WORD='(\\\\)?(\\"|'$SQ')?((source|\.)[[:space:]]|\.*/|[^[:space:];&|"'$SQ'=:/~$\\()`<>{}][^[:space:];&|"'$SQ'=:]*/|[~/]|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(\\"|'$SQ')?/)'

WRAPPER_WORD='(^|[^A-Za-z0-9_.-]|\\[nt])(bash|sh|zsh|dash|ksh|eval|env|find|watch|script|parallel)([^A-Za-z0-9_.-]|$)'
GUARDED_WORD='(^|[^A-Za-z0-9_.-]|\\[nt])(git|gh|rtk)([^A-Za-z0-9_.-]|$)'

# Does payload text $1 match regex $2? Under a UTF-8 locale bash's =~ stops at a byte that is not
# UTF-8, so a word after one reads as absent and the call passes unread (claude-config#1885). The C
# locale reads every byte as a character, so it is tried as well; the session's locale is tried first,
# since only it counts a Unicode space as [[:space:]], so a match is only ever added, never lost.
# BASH_REMATCH is the matching try's.
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }

payload="$(cat)"
# Every Bash call passes through here, and nearly none name a wrapper or run a script by its path
# beside git, gh or rtk: answer those at once, before the shared reader is even loaded. The payload is
# JSON, so a line break or a tab before a word is written \n or \t there.
if payload_match "$payload" "$WRAPPER_WORD"; then
  # The wrapper the text names, which is all a refusal made with no reader to judge it can record.
  NAMED_WRAPPER="${BASH_REMATCH[2]}"
  NAMED_WHAT="names a shell, eval, env, find, watch, script or parallel"
elif payload_match "$payload" "$RUNS_FILE_AT$RUNS_FILE_PAST$RUNS_FILE_WORD"; then
  # The longest match ends in a blank only for source or `.`.
  case "${BASH_REMATCH[0]}" in
    *[[:space:]]) NAMED_WRAPPER=source; NAMED_WHAT="sources a file" ;;
    *) NAMED_WRAPPER=direct; NAMED_WHAT="runs a script by its path" ;;
  esac
else
  exit 0
fi
payload_match "$payload" "$GUARDED_WORD" || exit 0

LEDGER_DIR="${WRAPPED_REFUSAL_LEDGER_DIR:-$HOME/.claude/state/wrapped-commands}"
LEDGER="$LEDGER_DIR/refusals.tsv"
LEDGER_MAX="${WRAPPED_REFUSAL_LEDGER_MAX:-5000}"
# The one test of a whole number above zero, 00 included as zero (claude-config#1948). Missing, the
# shell names the missing function and the default is used.
# shellcheck source=lib/whole-number.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/whole-number.sh" 2>/dev/null
whole_above_zero "$LEDGER_MAX" || LEDGER_MAX=5000
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
# Built by lib/hook-notice.sh, never by hand: the note names the record's path, and a newline or tab
# in it made the hand built object invalid, which Claude Code counts as a hook failure (#1906).
say_record_note() {
  [ -n "$RECORD_NOTE" ] || return 0
  if . "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null; then
    hook_notice_json "$RECORD_NOTE"
  else
    printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${RECORD_NOTE//[^A-Za-z0-9 .,:;()\/_=+#-]/}"
  fi
}

not_judged() {   # $1 = what went wrong, as a clause  $2 = its reason category
  case "$payload" in
    *"$OVERRIDE=1"*) record_refusal "$NAMED_WRAPPER" "$2" overridden; say_record_note; exit 0 ;;
  esac
  record_refusal "$NAMED_WRAPPER" "$2" refused
  echo "BLOCKED: this command $NAMED_WHAT beside git, gh or rtk, and whether it runs one of them where no gate can see it could not be read: $1. So it is refused rather than passed unjudged (claude-config#1478). $ASK${RECORD_NOTE:+ $RECORD_NOTE}" >&2
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

# Is reading record $1 a declared read only call (READ_ONLY_CALLS)? Its words, as the shell reads them,
# must be exactly `[bash] <declared path> <subcommand> <id>`, optionally followed by 2>&1, with no
# assignment in front, the path written ~/ or with the home directory written out, and the id one
# plain word of letters and digits, so nothing in it can expand, substitute or redirect. A command
# naming BASH_ENV anywhere has none, since bash runs the file it names before any script.
read_only_record() {   # $1 = record index
  local -a w=()
  local k=0 n entry path sub id_re='^[A-Za-z0-9]{1,64}$'
  [ -z "${PS__R_ASSIGNS[$1]}" ] || return 1
  case "$cmd" in *BASH_ENV*) return 1 ;; esac
  case "${PS__R_WRAP[$1]%%$'\x1d'*}" in direct|bash) ;; *) return 1 ;; esac
  IFS=$'\x1f' read -r -a w <<< "${PS__R_WORDS[$1]}"
  [ "${w[0]:-}" = bash ] && k=1
  n=$(( ${#w[@]} - k ))
  [ "${w[${#w[@]}-1]:-}" = "2>&1" ] && n=$((n - 1))
  [ "$n" -eq 3 ] || return 1
  [[ ${w[k+2]} =~ $id_re ]] || return 1
  for entry in "${READ_ONLY_CALLS[@]}"; do
    path="${entry%% *}"; sub="${entry#* }"
    [ "${w[k+1]}" = "$sub" ] || continue
    [ "${w[k]}" = "$path" ] || [ "${w[k]}" = "$HOME/${path#\~/}" ] || continue
    return 0
  done
  return 1
}

# Sets PS_UNREAD_WRAPPER and PS_UNREAD_WHY to the first unread record of the command's reading that
# is not a declared read only call, as ps_unreadable does for the first of all; fails when every one
# is such a call. Read off the reading ps_unreadable has just made, so it costs no second reading.
first_unexcused() {   # $1 = command
  local i="${PS__M_FIRST[$PS__HIT]}" end u
  end=$((i + PS__M_COUNT[PS__HIT]))
  while [ "$i" -lt "$end" ]; do
    u="${PS__R_WRAP[$i]}"
    case "$u" in
      *$'\x1d'*)
        if ! read_only_record "$i"; then
          PS_UNREAD_WRAPPER="${u%%$'\x1d'*}"; PS_UNREAD_WHY="${u#*$'\x1d'}"
          return 0
        fi ;;
    esac
    i=$((i + 1))
  done
  return 1
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
# A declared read only call is no unread wrapper (claude-config#1669): the refusal is judged on the
# first script record that is not one, and a command whose only ones are passes.
first_unexcused "$cmd" || exit 0
why_category "$PS_UNREAD_WHY"
# A declared script call (or subcommand call), with nothing in front but the GH_TOKEN prefix and
# nothing behind but 2>&1 and pipes into plain filters, whose git, gh and rtk all sit inside
# arguments quoted whole, is no refusal (claude-config#1574, #1610). A reader that fails or prints
# nothing is no pass.
if [ "$REASON" = script-file ]; then
  # A script is unread only beside git, gh or rtk, so its remedy is to stand apart from them.
  ASK="Run the script in a command of its own, and git, gh and rtk in commands of their own, so every gate can read those; or write out what it runs in full. If this refusal is wrong, say so and add $OVERRIDE=1 to that one command."
  shown="$(printf '%s' "$cmd" | python3 "$PS_SHELL_WORDS" data-blanked "${DATA_ARGUMENT_SCRIPTS[@]}" 2>/dev/null)" \
    && [ -n "$shown" ] \
    && ! [[ $shown =~ (^|[^A-Za-z0-9_.-])(git|gh|rtk)([^A-Za-z0-9_.-]|$) ]] \
    && exit 0
  # A declared script refused for its shape is told the shapes it passes in, rather than only to
  # write the command out (claude-config#1610): the remedy is to change the call, not to unwrap it.
  for entry in "${DATA_ARGUMENT_SCRIPTS[@]}"; do
    script="${entry%% *}"
    case "$PS_UNREAD_WHY" in
      *"script file $script,"*|*"script file $HOME/${script#\~/},"*)
        ASK="Its declared call, \`bash $entry\`, passes only called alone, or piped into grep, head, tail or cut, with git, gh and rtk only inside quoted arguments and nothing in front but GH_TOKEN=\$(gh auth token -u <login>), run by bash or by its path; run it that way, and anything else as a command of its own. If this refusal is wrong, say so and add $OVERRIDE=1 to that one command."
        break ;;
    esac
  done
fi
if [ "$overridden" = 1 ]; then
  record_refusal "$PS_UNREAD_WRAPPER" "$REASON" overridden
  say_record_note
  exit 0
fi
record_refusal "$PS_UNREAD_WRAPPER" "$REASON" refused
case "$PS_UNREAD_WRAPPER" in
  direct) runs="runs a script by its path, whose commands cannot be read before it runs" ;;
  *) runs="runs \`$PS_UNREAD_WRAPPER\` on a command that cannot be read before it runs" ;;
esac
echo "BLOCKED: this command $runs: $PS_UNREAD_WHY. It also names git, gh or rtk, so the push, commit, add, merge, issue and rtk gates cannot see what it would run, and it is refused rather than passed unjudged (claude-config#1478). $ASK${RECORD_NOTE:+ $RECORD_NOTE}" >&2
exit 2
