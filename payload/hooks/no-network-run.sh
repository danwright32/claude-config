#!/bin/bash -p
#
# no-network-run.sh: run a command with no network access at all (claude-config#3173).
#
#   no-network-run.sh <command> [its words]
#
# WHY IT EXISTS. The Slack drafts gate (slack-drafts-only-gate.sh) refuses a command whose files
# reach code able to post, which stops one test file being run on its own although its test posts
# nothing. Unsetting the webhook variable does not make a test unable to post: on a fixture posting
# eight ways, seven still arrived with the variable unset and with the whole environment emptied,
# and none arrived with the network taken away (measured 2026-11-18, the design on #3173). So this
# runs the command inside a macOS sandbox whose one rule denies every network operation, and the
# gate lets a command through when its program is this file at its installed path (Dan,
# 2026-11-18: "Yes, any command"). Every process the command starts inherits the sandbox, a
# detached one too, and none can take it off.
#
# IT TAKES NO OPTION AND READS NO SETTING, so nothing in a command line can weaken it: a first
# word starting with a dash is refused, and there is no "this Mac only" mode. The shebang's -p
# keeps bash from sourcing a BASH_ENV file or taking functions from the environment before the
# first line here runs. The sandbox tool is named by its own path, never looked up. python3, which
# only makes the check below, is found on the PATH as every hook finds it: a stand in for it could
# fake the check, and could not take the sandbox off the command, which the last line here starts
# with the tool and the profile written in this file.
#
# IT PROVES THE SANDBOX ON EVERY RUN, because /usr/bin/sandbox-exec is a tool Apple marks as
# deprecated and the whole route rests on it. Before the command, it opens a listener of its own
# on loopback and connects to it twice with one small program: once outside the sandbox, which
# must arrive (or a blocked connection would prove nothing, L1), and once inside the same profile
# the command gets, which must be refused with a permission error. Anything else (it connects,
# the profile cannot be applied, the tool is missing, no answer) and THE COMMAND IS NOT RUN.
#
# There is no retry, backoff or poll here. The one time limit is PROBE_SECONDS, a ceiling only a
# hang reaches, and a constant so that the suite can shorten it on a copy (L524).
#
# WHAT IT DOES NOT COVER. A command that hands its message to something already running outside
# the sandbox without using the network (a file in a folder another program watches, a request to
# a macOS service or another app). Anything that is not macOS: there is no sandbox tool, so
# nothing is run. And it is not specific to Slack: a test that needs any network, a port on this
# Mac included, fails under it with "Operation not permitted".
#
# EXIT: the command's own exit code, unchanged. 64 for no command or an option, 69 for a missing
# tool, 70 when the sandbox could not be proved; each says on stderr that nothing was run.
# Tests: test-no-network-run.sh.
set -u
SANDBOX=/usr/bin/sandbox-exec
PROFILE='(version 1)(allow default)(deny network*)'
PROBE_SECONDS=20
ME=no-network-run

refuse() {
  printf '%s: %s Nothing was run.\n' "$ME" "$2" >&2
  exit "$1"
}

[ "$#" -gt 0 ] || refuse 64 "no command was given. Write the command to run after this file's path."
case "$1" in
  -*) refuse 64 "this takes no option, and the first word after it, $1, starts with a dash. Write the command to run straight after this file's path." ;;
esac
[ -x "$SANDBOX" ] || refuse 69 "$SANDBOX, the macOS tool that takes the network away, is not on this machine, so no command can be run without the network here."
PYTHON="$(command -v python3)" || refuse 69 "python3, which checks that the sandbox really blocks a connection, is not on the PATH."

# The proof. Its code comes on its input, which leaves the command's own input untouched: the
# heredoc is this one program's alone. -I keeps PYTHONPATH and its like out of it.
"$PYTHON" -I - "$SANDBOX" "$PROFILE" "$PROBE_SECONDS" <<'PROOF'
import socket
import subprocess
import sys

SANDBOX = sys.argv[1]
PROFILE = sys.argv[2]
SECONDS = float(sys.argv[3])
# One connection to the listener. 0: it connected. 7: refused with a permission error, which is
# what the sandbox gives. 9: any other failure.
PROBE = """
import socket
import sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(float(sys.argv[2]))
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except PermissionError:
    sys.exit(7)
except OSError:
    sys.exit(9)
sys.exit(0)
"""


def stop(why):
    print("no-network-run: " + why, file=sys.stderr)
    sys.exit(70)


def probe(front):
    """How the probe ended with front before it: its exit code, or words saying why it gave none."""
    try:
        done = subprocess.run(front + [sys.executable, "-I", "-c", PROBE, str(PORT), str(SECONDS)],
                              stdin=subprocess.DEVNULL, timeout=SECONDS)
    except subprocess.TimeoutExpired:
        return "no answer within %g seconds" % SECONDS
    except OSError as e:
        return "it could not be started (%s)" % e
    return done.returncode


def arrived(wait):
    """How many connections are at the listener, each taken and closed. The first is waited for
    up to wait seconds (0 for none), the rest only counted if they are already there."""
    count = 0
    listener.settimeout(wait)
    while True:
        try:
            conn, _ = listener.accept()
        except (BlockingIOError, socket.timeout):
            return count
        conn.close()
        count += 1
        listener.settimeout(0)


listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.bind(("127.0.0.1", 0))
listener.listen(8)
PORT = listener.getsockname()[1]

# Outside the sandbox the connection must arrive, or its not arriving inside proves nothing.
outside = probe([])
if outside != 0 or arrived(SECONDS) < 1:
    stop("the sandbox could not be checked: a connection to this check's own listener on this Mac did not "
         "arrive even outside the sandbox (the probe ended: %s), so a blocked one would prove nothing." % outside)

# Inside the profile the command gets, it must be refused, and nothing may reach the listener.
inside = probe([SANDBOX, "-p", PROFILE])
reached = arrived(0)
if inside == 0 or reached:
    stop("the sandbox did NOT block a connection: from inside it, a connection to this check's own listener "
         "on this Mac arrived. %s no longer takes the network away on this machine." % SANDBOX)
if inside != 7:
    stop("the sandbox could not be checked: the probe inside it ended %s, where a blocked connection ends 7. "
         "The profile may not have been applied (what %s said is above)." % (inside, SANDBOX))
PROOF
proof=$?
if [ "$proof" -ne 0 ]; then
  if [ "$proof" -ne 70 ]; then
    printf '%s: the check that the sandbox blocks a connection ended %s without a verdict.\n' "$ME" "$proof" >&2
  fi
  refuse 70 "The sandbox was not proved to block the network."
fi

printf '%s: running with no network access. A connection that fails with "Operation not permitted" is this wrapper, not the code under it.\n' "$ME" >&2
exec "$SANDBOX" -p "$PROFILE" "$@"
