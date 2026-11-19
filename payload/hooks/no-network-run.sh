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
# first line here runs. Nothing this file starts is found through the environment. The sandbox
# tool is named by its own path. So is python3, which makes the check below and runs OUTSIDE the
# sandbox to make it: one found on the PATH would be whatever stands first there, and folders ahead
# of /usr/bin on the PATH are the user's to write, so a command run under this file could leave a
# python3 there that the next run starts with the network on (the review of 2026-11-19). The one
# used is the command line developer tools' own, in a folder only an administrator can write.
# /usr/bin/python3 is not used: where those tools are missing it is a stub that raises a dialog
# offering to install them. This file only reads whether its python3 is there, and where it is
# not, refuses (exit 69) and runs nothing.
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
# WHAT IT IS, AND WHAT IT DOES NOT COVER. It stops code from using the network while that code
# runs under it, which is what makes an accidental post from a test impossible. It does not contain
# code written to get out. The profile denies the network and allows everything else, so:
#   * A file. The command can write any file it could without this, this one included, and a later
#     call can read that file without the gate reading it: a shell startup file (every Bash call
#     starts a login shell, which reads ~/.zshenv, ~/.zprofile and ~/.zlogin), a tool's own config
#     file, a program in a folder on the PATH that the user can write.
#   * A command that asks something outside the sandbox to act for it, without the network. A
#     request to launchd or to another app is not a network operation (the profile's operations
#     for them, mach-lookup and appleevent-send, are their own): launchctl, osascript and open
#     each have a program started that this sandbox is not on. With open that takes one line and
#     no setup: a page written to disk whose form submits itself, opened in a browser, is posted
#     by the browser (read from the profile, not run). The profile is left as it is: denying
#     those requests too would be a change of design, for Dan to decide.
#   * A connection that was already open when this file started and is handed down to the
#     command: the sandbox refuses a new connection and does not stop a write to an open one
#     (measured 2026-11-19, test-no-network-run.sh "held"). The gate's rule lets nothing but a cd
#     stand before this file in a call, and no /dev/tcp among its words, so a call cannot open
#     one first (lib/no-network-route.py).
# A unix domain socket whose listener is outside the sandbox IS refused (measured the same day).
# Anything that is not macOS: there is no sandbox tool, so nothing is run. And it is not specific
# to Slack: a test that needs any network, a port on this Mac included, fails under it with
# "Operation not permitted".
#
# EXIT: the command's own exit code, unchanged. 64 for no command or an option, 69 for a missing
# tool, 70 when the sandbox could not be proved; each says on stderr that nothing was run.
# Tests: test-no-network-run.sh.
set -u
SANDBOX=/usr/bin/sandbox-exec
PYTHON=/Library/Developer/CommandLineTools/usr/bin/python3
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
[ -x "$PYTHON" ] || refuse 69 "$PYTHON, which checks that the sandbox really blocks a connection, is not on this machine. It comes with Apple's command line developer tools, and no other python3 is used, since one found on the PATH would run outside the sandbox."

# The proof. Its code comes on its input, which leaves the command's own input untouched: the
# heredoc is this one program's alone. -I keeps PYTHONPATH and its like out of it, and the folder
# the call is in off its import path. The probes are run by the same python3, by the same path.
"$PYTHON" -I - "$SANDBOX" "$PROFILE" "$PROBE_SECONDS" "$PYTHON" <<'PROOF'
import socket
import subprocess
import sys

SANDBOX = sys.argv[1]
PROFILE = sys.argv[2]
SECONDS = float(sys.argv[3])
PYTHON = sys.argv[4]
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
        done = subprocess.run(front + [PYTHON, "-I", "-c", PROBE, str(PORT), str(SECONDS)],
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
