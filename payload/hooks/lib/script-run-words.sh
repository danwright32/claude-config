#!/usr/bin/env bash
# script-run-words.sh: whether a hook payload's command can run a script file or hand a wrapper a
# command, read off the payload's raw text before any reader loads (claude-config#2301). Source it;
# it sets the patterns below and defines one function.
#
#   srw_may_run_script PAYLOAD   exit 0 when the payload names a shell, eval, env, find, watch,
#                                script or parallel as a word (SRW_NAMED=wrapper, the word in
#                                SRW_WRAPPER), or begins a command with a script run by its path or
#                                with source or `.` (SRW_NAMED=direct or source); exit 1 otherwise,
#                                with SRW_NAMED empty.
#
# It is a cheap filter, never an answer. lib/shell-words.py (wrapped, _script_run) is the reader that
# says what a command runs; this only says when that reader is worth starting, so it errs wide: it
# must be a superset of what the reader calls a script run, or a command it misses passes unread.
# check-wrapped-commands.sh asks it before refusing a wrapper beside git, gh or rtk (#1478, #1623),
# and check-add-scope.sh before reading the scripts a command runs for a git add (#2301). The
# patterns lived in check-wrapped-commands.sh alone until the second caller needed them; they live
# here so there is one copy, and test-check-wrapped-commands.sh runs every refused case through a
# copy of that guard with no reader beside it, which holds this filter to being that superset.
#
# A caller whose copy of this file is missing has no filter, and must then treat every command as
# one that may run a script (start the reader), never as one that cannot.

# A script run by its path, or sourced, where a command can begin (claude-config#1623), read off the
# payload as written, so a command naming git with paths only as its arguments (`git -C /x add ./y`)
# is still answered before the reader loads. A command begins at the start of the command, after
# ; & | ( ` ! or `{ `, or a line break, past blanks, reserved words, assignments (`X="a b" ./x`,
# `T=$(gh auth token -u x) ./x`) and runners with their options and values (`sudo -u bob ./x`,
# `timeout 30 ./x`); what can begin it is `source`, `.`, or a path: a word holding a slash, its name
# before the slash free of = and : as the reader requires, or starting ~ or /, or a variable then a
# slash, optionally quoted or escaped. The payload is JSON: a line break is \n and a double quote \"
# there.
RUNS_FILE_AT='(^|[;&|(`!]|\{[[:space:]]|\\[nt]|"command"[[:space:]]*:[[:space:]]*")'
RUNS_FILE_VALUE="(\\\$\\([^()]*\\)|\\\\\"[^\"]*\\\\\"|'[^']*'|[^[:space:];&|])*"
RUNS_FILE_PAST="([[:space:]]|(then|do|else|elif|if|while|until|time)[[:space:]]|[A-Za-z_][A-Za-z0-9_]*=$RUNS_FILE_VALUE[[:space:]]|(nohup|exec|command|sudo|doas|xargs|caffeinate|stdbuf|nice|timeout|gtimeout|env|proxy)([[:space:]]+(-[^[:space:];&|]*([[:space:]]+[^-[:space:];&|][^[:space:];&|]*)?|[0-9][^[:space:];&|]*|[A-Za-z_][A-Za-z0-9_]*=$RUNS_FILE_VALUE))*[[:space:]])*"
SQ="'"
RUNS_FILE_WORD='(\\\\)?(\\"|'$SQ')?((source|\.)[[:space:]]|\.*/|[^[:space:];&|"'$SQ'=:/~$\\()`<>{}][^[:space:];&|"'$SQ'=:]*/|[~/]|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(\\"|'$SQ')?/)'

WRAPPER_WORD='(^|[^A-Za-z0-9_.-]|\\[nt])(bash|sh|zsh|dash|ksh|eval|env|find|watch|script|parallel)([^A-Za-z0-9_.-]|$)'

# Does payload text $1 match regex $2? Under a UTF-8 locale bash's =~ stops at a byte that is not
# UTF-8, so a word after one reads as absent and the call passes unread (claude-config#1885). The C
# locale reads every byte as a character, so it is tried as well; the session's locale is tried first,
# since only it counts a Unicode space as [[:space:]], so a match is only ever added, never lost.
# BASH_REMATCH is the matching try's.
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }

srw_may_run_script() {   # $1 = the hook payload, as received
  SRW_NAMED=""; SRW_WRAPPER=""
  if payload_match "$1" "$WRAPPER_WORD"; then
    SRW_NAMED=wrapper; SRW_WRAPPER="${BASH_REMATCH[2]}"
    return 0
  fi
  if payload_match "$1" "$RUNS_FILE_AT$RUNS_FILE_PAST$RUNS_FILE_WORD"; then
    # The longest match ends in a blank only for source or `.`.
    case "${BASH_REMATCH[0]}" in
      *[[:space:]]) SRW_NAMED=source ;;
      *) SRW_NAMED=direct ;;
    esac
    return 0
  fi
  return 1
}
