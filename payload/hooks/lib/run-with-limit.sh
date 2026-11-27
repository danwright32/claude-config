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
#   - the command runs as the leader of a process group of its own, with the runner's input and
#     output as they are (nothing is captured);
#   - at the limit the whole group is sent TERM, then KILL two seconds later if anything is still
#     there, and the run comes back as 124 with one line saying what was stopped;
#   - a command that ends in time and leaves a process running in its group has it stopped the
#     same way, and the run comes back as 123, whatever the command's own code was;
#   - otherwise the command's own exit code comes back and nothing is said;
#   - the runner signals the group only while the command, ended or not, is still uncollected,
#     which is what keeps the group's number the command's own. It reads no `ps`, so it runs
#     under no-network-run.sh (the wrapper first, this after it);
#   - inside a session whose shells are recorded (bash-shell-mark.sh), the new group is recorded
#     the same way, so the leftover process check covers a runner that was itself killed.
#
# 125 MEANS NOTHING WAS RUN: a limit that is not a whole number of seconds from 1 to 86400, no
# command, a system the runner cannot keep its rule on, or one of the two things below missing.
# The one other 125 is a fault inside the runner after the command has started: its group is then
# sent KILL. The command is never run with no limit.
#
# It takes no option and reads no setting of its own. python3 is the first on the PATH, as every
# hook here finds it, started with -I so that no PYTHON variable and no file beside the program
# changes what it loads. This is a time limit and no security boundary: it runs exactly the
# command it is given.

# Its own folder by parameter expansion, never dirname (claude-config#1104, test-lib-self-locate.sh).
_rwl_dir="${BASH_SOURCE[0]%/*}"; [ "$_rwl_dir" != "${BASH_SOURCE[0]}" ] || _rwl_dir=.

if ! command -v python3 >/dev/null 2>&1; then
  echo "run-with-limit: nothing was run: python3 is not on the PATH, and without it no time limit can be kept: $*" >&2
  exit 125
fi
if [ ! -f "$_rwl_dir/run-with-limit.py" ]; then
  echo "run-with-limit: nothing was run: $_rwl_dir/run-with-limit.py, the program this starts, is missing. Reinstall the hooks with claude-sync pull: $*" >&2
  exit 125
fi
# Without execfail a shell whose exec fails ends there with 126 or 127, which reads as the command's.
shopt -s execfail
exec python3 -I "$_rwl_dir/run-with-limit.py" "$@"
# Reached only when python3 could not be started at all.
echo "run-with-limit: nothing was run: python3 could not be started: $*" >&2
exit 125
