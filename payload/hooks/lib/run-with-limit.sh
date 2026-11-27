#!/usr/bin/env bash
#
# run-with-limit.sh: run one command for at most N seconds, and end everything it started when the
# limit runs out (claude-config#3578). RUN, never sourced:
#
#   bash ~/.claude/hooks/lib/run-with-limit.sh <seconds> <command> [its words]
#
# WHY IT EXISTS. Since 2026-11-24 every agent brief says a loop, a harness or a generated command
# runs under a time limit that ends its whole process group (L1040, claude-config#3561). The one
# shared limit, lib/bounded-run.sh, is a function a script has to load, so an agent cannot run it,
# and macOS ships no `timeout`. Each agent wrote its own in perl or python, which the gates could
# not read, and a suite went unrun where it most needed a limit.
#
# WHAT IT DOES, all of it in lib/run-with-limit.py beside this file, whose header has the reasons:
#   - the command runs as the leader of a process group of its own, on the runner's own input and
#     output (nothing is captured). At a terminal that group is a background group, where a command
#     that reads or sets the terminal is suspended until the limit: the runner is for commands
#     that do not read a terminal;
#   - at the limit the whole group is sent TERM, then KILL two seconds later if anything is still
#     there, and the run comes back as 124 with one line saying what was stopped;
#   - a command that ends in time and leaves a process running in its group has it stopped the
#     same way, and the run comes back as 123, whatever the command's own code was;
#   - otherwise the command's own exit code comes back and nothing is said;
#   - the runner signals the group only while the command, ended or not, is still uncollected,
#     which is what keeps the group's number the command's own. It reads no `ps`, so it runs
#     under no-network-run.sh (the wrapper first, this after it);
#   - a signal sent to the runner that it can catch (TERM, INT, HUP, QUIT, USR1, USR2, ALRM and
#     the like) ends the group first, and the runner then ends by that signal;
#   - inside a session whose shells are recorded (bash-shell-mark.sh), the new group is recorded
#     the same way for as long as it may hold anything. The leftover process check lists a group
#     only once its leader has gone, so the record covers what a command leaves after it, never a
#     command that is still running.
#
# 125 MEANS THE RUNNER RAN NOTHING, when the runner's own line says so: a limit that is not a
# whole number of seconds from 1 to 86400, no command, a system the runner cannot keep its rule on,
# or one of the things below missing. The one other 125 of the runner's is a fault inside it once
# the command's process exists: its group is then sent KILL. The command is never run with no
# limit. A command can itself exit with 123, 124 or 125 (another runner inside this one does), and
# only the runner's line on standard error tells the two apart. One 125 of the runner's has no
# line there: the program's answer to the question below (`--prove <word>`) is one line on
# standard OUTPUT, which is where the launcher reads it.
#
# It takes no option and reads no setting of its own. python3 is the first on the PATH, as every
# hook here finds it, started with -I so that no PYTHON variable and no file beside the program
# changes what it loads. This is a time limit and no security boundary: it runs exactly the
# command it is given.

# Its own folder by parameter expansion, never dirname (claude-config#1104, test-lib-self-locate.sh).
_rwl_dir="${BASH_SOURCE[0]%/*}"; [ "$_rwl_dir" != "${BASH_SOURCE[0]}" ] || _rwl_dir=.

# The file a start of python3 would run, found once, so the question below and the hand over go
# to the same one.
_rwl_py="$(type -P python3 2>/dev/null)"
if [ -z "$_rwl_py" ]; then
  echo "run-with-limit: nothing was run: python3 is not on the PATH, and without it no time limit can be kept: $*" >&2
  exit 125
fi
if [ ! -f "$_rwl_dir/run-with-limit.py" ]; then
  echo "run-with-limit: nothing was run: $_rwl_dir/run-with-limit.py, the program this starts, is missing. Reinstall the hooks with claude-sync pull: $*" >&2
  exit 125
fi
# ONE QUESTION BEFORE THE HAND OVER (claude-config#3833). A python3 that starts and is not Python
# (a version manager's shim with no python chosen) would hand back its own exit code as if it were
# the command's, and its 0 would read as a pass with nothing run. So the program is asked to prove
# itself first, and only its own answer lets the command through.
# While bash waits here for that answer, an INT sent to this launcher's process ALONE can be lost:
# bash drops an INT that arrives while it waits on a child which then ends normally (bash's rule,
# read and not measured here). The command then starts and runs to its limit: the limit is kept
# and the sender's stop is not. Ctrl C at a terminal goes to the whole group and is not affected.
_rwl_token="$$.$RANDOM"
_rwl_answer="$("$_rwl_py" -I "$_rwl_dir/run-with-limit.py" --prove "$_rwl_token" 2>/dev/null </dev/null)"
if [ "$_rwl_answer" != "run-with-limit proves $_rwl_token" ]; then
  echo "run-with-limit: nothing was run: $_rwl_py did not answer as a python3 running $_rwl_dir/run-with-limit.py does, so no time limit could be kept: $*" >&2
  exit 125
fi
# Without execfail a shell whose exec fails ends there with 126 or 127, which reads as the command's.
shopt -s execfail
exec "$_rwl_py" -I "$_rwl_dir/run-with-limit.py" "$@"
# Reached only when python3 could not be started at all.
echo "run-with-limit: nothing was run: python3 could not be started: $*" >&2
exit 125
