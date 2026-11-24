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
# runs the command inside a macOS sandbox that denies every network operation, and the gate lets
# a command through when its program is this file at its installed path (Dan, 2026-11-18: "Yes,
# any command"). Every process the command starts inherits the sandbox, a detached one too, and
# none can take it off. There is one exception, which this file makes itself: ps (below).
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
# IT ALSO REFUSES A HAND OFF (#3288, decided 2026-11-20: denied). A request to launchd or to
# another app is not a network operation, so under the network rule alone a command could have
# something outside the sandbox act for it: a page written to disk whose form submits itself,
# opened in a browser, is posted by the browser. So the profile also refuses
#   * to start the programs in HANDOFFS, each by its real path: open, osascript and launchctl,
#     and with them crontab (cron runs what it is given, outside the sandbox) and shortcuts (a
#     Shortcut is run by another process). A link to one is refused as the file is. They are
#     proved on every run as the network is: each must start outside the sandbox and be refused
#     inside it, or THE COMMAND IS NOT RUN. Each of those starts is the program with --help, which
#     prints its usage and ends. One that is not on the machine at all is passed over;
#   * the requests themselves, whoever makes them: to have something opened (lsopen), to send an
#     Apple event to another app (appleevent-send), and to have launchd make a job (job-creation,
#     which this sandbox already refused before the rule was written out).
# Measured 2026-11-20 on macOS 26.6.2: the starts for real, and the three requests by asking the
# sandbox what it answers (sandbox_check), not by making them. Making one that turned out not to
# be refused would open, script or load something on a Mac in use.
#
# IT LETS ONE PROGRAM OUT: /bin/ps (#3482). macOS refuses to start a setuid program from inside
# any sandbox, whatever the profile allows, and ps is one: the kernel logs "deny(1)
# forbidden-exec-sugid" (measured 2026-11-24, macOS 26.6.2, under a profile naming the network
# alone). So every ps under this file ended "Operation not permitted", and four suites that read
# a process through it could not pass on the route the gate sends them down. Reading the process
# list was never something this file set out to stop: the profile allows everything it does not
# name, and a wrapped command already reads another process from the kernel. But a profile has
# one form that lets a setuid program start, (with no-sandbox), and it does what it says: the program it
# names is started OUTSIDE the sandbox, network and all. Eight forms were tried and no other
# starts ps. So the rule names ps by its real path and nothing else, and (each measured in
# test-no-network-run.sh):
#   * a link to ps runs it. Another program called ps stays in the sandbox, and every other
#     setuid program is still refused;
#   * ps opens no connection and starts no program, and macOS does not load into it a library the
#     caller names (DYLD_INSERT_LIBRARIES), so the caller's own code does not leave with it. The
#     command that ran ps is where it was: its connection is refused and so are the hand offs;
#   * what a wrapped command gains is what ps prints. The arguments and the environment of this
#     user's other processes it could already read with no ps (sysctl, measured under the profile
#     without the rule), so ps eww shows nothing new of them. NEW is the arguments of processes
#     that are NOT this user's: the kernel refuses those to a wrapped command, and ps, which is
#     root's while it runs, prints them. Whether it prints their environment too was not
#     measured: no process of another user's could be given a marker without being root.
#
# ONE PROGRAM AND NEVER A LIST. A second program is not a line to add here: whatever a rule with
# (with no-sandbox) names runs with the network on. Twelve ways of writing a second one into the
# profile were each run in a copy of this file with the check below taken out, and in every one
# curl's post arrived (measured 2026-11-24, macOS 26.6.2, the personal MacBook): a second rule on
# the same line, on a continued line, built from a variable, written process-exec*, a regex in
# place of the literal, a subpath, a prefix, a second literal inside the one rule, a later line
# that adds to the profile, a line just before the command is run, a rule in a file the profile
# imports, and the one rule naming curl. So this file checks its own profile on every run, before
# anything is handed to the sandbox tool ("THE PROFILE IS HELD TO ONE PROGRAM" below), and runs
# nothing when the profile lets more out than ps: a suite that is not run stops nothing, and this
# does not wait for one. It reads the profile as put together, not the lines that made it, so it
# does not matter how the second rule was written. The suite holds the same promise a second way,
# from its own copy of the whole profile and from what this file is seen to hand the sandbox tool,
# so a change made to the profile and to the check below together is still caught there. Neither
# stops somebody who rewrites this file: that is "WHAT IT DOES NOT COVER", a file.
#
# There is no retry, backoff or poll here. The one time limit is PROBE_SECONDS, a ceiling only a
# hang reaches, and a constant so that the suite can shorten it on a copy (L524).
#
# WHAT IT IS, AND WHAT IT DOES NOT COVER. It stops code from using the network while that code
# runs under it, which is what makes an accidental post from a test impossible, and it refuses the
# hand offs named above. It does not contain code written to get out. The profile allows
# everything else, so:
#   * A file. The command can write any file it could without this, this one included, and a later
#     call can read that file without the gate reading it: a shell startup file (every Bash call
#     starts a login shell, which reads ~/.zshenv, ~/.zprofile and ~/.zlogin), a tool's own config
#     file, a program in a folder on the PATH that the user can write. A file left in a folder
#     that something outside the sandbox watches is the same thing: ~/Library/LaunchAgents, which
#     launchd reads at the next login, is not refused.
#   * A hand off the rules above do not name (all measured 2026-11-20, macOS 26.6.2). A plain copy
#     of one of the programs is ended by macOS itself, with or without this file. A copy signed
#     again on this Mac starts, and so would a program written to make the same request: what
#     stands in their way is the rule on the request, which was asked of the sandbox and not
#     exercised. Finding a service by its name (mach-lookup) is still allowed, so a service that
#     acts for its caller in a way no rule here names can be reached. Denying every such lookup
#     was tried: it also stopped a user's name being looked up, a folder being watched, a
#     preference being read and the keychains being listed, so it is left for Dan to decide.
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
# tool, 70 when the sandbox could not be proved or this file's own profile lets more out than ps;
# each says on stderr that nothing was run.
# Tests: test-no-network-run.sh.
set -u
SANDBOX=/usr/bin/sandbox-exec
PYTHON=/Library/Developer/CommandLineTools/usr/bin/python3
# The programs that have something outside the sandbox act for the caller, each by its real path
# (#3288). This one list makes both the profile's rule and the proof of it below.
HANDOFFS='/usr/bin/open /usr/bin/osascript /bin/launchctl /usr/bin/crontab /usr/bin/shortcuts'
DENY_STARTS=''
for handoff in $HANDOFFS; do DENY_STARTS="$DENY_STARTS (literal \"$handoff\")"; done
# The one program started OUTSIDE the sandbox, by its real path (#3482, "IT LETS ONE PROGRAM OUT"
# above). Whatever this names has the network back, so it is one program and never a list.
OUTSIDE='/bin/ps'
PROFILE="(version 1)(allow default)(deny network*)(deny process-exec*$DENY_STARTS)(deny lsopen)(deny appleevent-send)(deny job-creation)(allow process-exec (literal \"$OUTSIDE\") (with no-sandbox))"
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

# THE PROFILE IS HELD TO ONE PROGRAM, ON EVERY RUN (the review of 2026-11-24, "ONE PROGRAM AND
# NEVER A LIST" above). The profile is checked as it was put together, whatever lines made it:
#   * with the one rule for ps taken out once, nothing left may say no-sandbox;
#   * what is left must be the opening and then refusals that name their paths with (literal ...),
#     and no other form.
# Then it is made read only, so that no later line adds to it. ONE_OUT is written out here a second
# time and is not built from OUTSIDE, so that changing either one alone is refused. A profile made
# narrower passes.
ONE_OUT='(allow process-exec (literal "/bin/ps") (with no-sandbox))'
rest="${PROFILE/"$ONE_OUT"/}"
case "$rest" in
  *no-sandbox*) refuse 70 "this file's own sandbox profile lets more than /bin/ps out of the sandbox: it holds a (with no-sandbox) beyond the one rule for ps (#3482), and whatever that names would run with the network on. A second program let out is Dan's decision, not a line to add." ;;
esac
case "$rest" in
  "(version 1)(allow default)"*) shape="${rest#"(version 1)(allow default)"}" ;;
  *) shape="(" ;;
esac
shape="${shape//"(deny "/}"
shape="${shape//"(literal "/}"
case "$shape" in
  *"("*) refuse 70 "this file's own sandbox profile holds something other than its opening, its refusals and the one rule for /bin/ps (#3482), so what else it lets through cannot be told here. Beside that rule only (deny ...) rules naming (literal ...) paths are taken." ;;
esac
readonly PROFILE

# The proof. Its code comes on its input, which leaves the command's own input untouched: the
# heredoc is this one program's alone. -I keeps PYTHONPATH and its like out of it, and the folder
# the call is in off its import path. The probes are run by the same python3, by the same path.
# $HANDOFFS is left unquoted on purpose: each path in it is one word of the proof's own.
# shellcheck disable=SC2086
"$PYTHON" -I - "$SANDBOX" "$PROFILE" "$PROBE_SECONDS" "$PYTHON" $HANDOFFS <<'PROOF'
import errno
import socket
import subprocess
import sys

SANDBOX = sys.argv[1]
PROFILE = sys.argv[2]
SECONDS = float(sys.argv[3])
PYTHON = sys.argv[4]
HANDOFFS = sys.argv[5:]
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

# The programs the profile refuses to start (#3288). Each start is one that prints and ends:
# --help makes every one of them print its usage, so nothing is opened, scripted, loaded or
# scheduled whichever way a check goes.
# All of them, tried in turn inside the sandbox. 7: every one was refused with the permission
# error the sandbox gives. 8: one started, and its path is printed. 9: one failed another way.
STARTS = """
import errno
import subprocess
import sys
for path in sys.argv[2:]:
    try:
        subprocess.run([path, "--help"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=float(sys.argv[1]))
    except OSError as e:
        if e.errno == errno.EPERM:
            continue
        print(path)
        sys.exit(9)
    except subprocess.TimeoutExpired:
        print(path)
        sys.exit(9)
    print(path)
    sys.exit(8)
sys.exit(7)
"""

# Outside the sandbox each must start, or its not starting inside proves nothing. One that is not
# on this machine at all cannot be handed anything, so there is nothing to prove about it.
there = []
for path in HANDOFFS:
    try:
        subprocess.run([path, "--help"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=SECONDS)
    except FileNotFoundError:
        continue
    except (OSError, subprocess.TimeoutExpired) as e:
        stop("the sandbox could not be checked: %s did not start even outside the sandbox (%s), so its "
             "being refused inside would prove nothing." % (path, e))
    there.append(path)

if there:
    try:
        done = subprocess.run([SANDBOX, "-p", PROFILE, PYTHON, "-I", "-c", STARTS, str(SECONDS)] + there,
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=SECONDS * (len(there) + 1))
    except (OSError, subprocess.TimeoutExpired) as e:
        stop("the sandbox could not be checked: the check of the programs it refuses to start gave no "
             "answer (%s)." % e)
    named = done.stdout.decode("utf-8", "replace").strip()
    if done.returncode == 8:
        stop("the sandbox did NOT refuse to start %s: from inside it, that program started. %s no longer "
             "stops a command handing its work to a program outside it on this machine." % (named, SANDBOX))
    if done.returncode != 7:
        stop("the sandbox could not be checked: the check of the programs it refuses to start ended %s%s, "
             "where a refusal of every one ends 7." % (done.returncode, " at " + named if named else ""))
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
