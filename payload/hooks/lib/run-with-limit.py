#!/usr/bin/env python3
"""The program behind lib/run-with-limit.sh: run one command for at most N seconds, in a process
group of its own, and end the WHOLE group when the limit runs out (claude-config#3578).

    run-with-limit.sh <seconds> <command> [its words]

What comes back, and what is said (one line on standard error, only when something was stopped or
could not be done):

    the command's own code   it ended in time and left nothing running (128 plus the signal's
                             number when a signal ended it; 127 or 126 when it could not be started)
    124                      it reached the limit: its group was sent TERM, then KILL GRACE seconds
                             later if anything was still there, so what ignores TERM outlives the
                             limit by GRACE seconds. The line says so when the command was
                             suspended, not running, at that moment, and names the terminal as the
                             likely cause only: the runner sees that it was suspended, never why
    123                      it ended in time and LEFT A PROCESS RUNNING in its group, which was
                             stopped the same way. Whatever the command's own code was, the run
                             fails: a suite that passes and leaves a process behind is the fault
                             of 2026-11-24 (19 shells ran on for 90 minutes, claude-config#3561)
    125                      nothing was run: the limit is not a whole number of seconds from 1 to
                             MAX_SECONDS, there is no command, or this system gives the runner no
                             way to keep the rule below. Also a fault inside the runner once the
                             command's process exists: its group is then sent KILL, while it is
                             still pinned. Also when the process that was to become the command
                             failed before it became it (it does not lead a group of its own once
                             let go, or a call it makes first failed): that process says the line
                             and ends with 125 itself, the command never starts, and the runner
                             hands the code back with no line of its own. Never the command with
                             no limit.
    ended by the signal      the runner itself was sent a signal it carries over (CARRIED, below):
                             the group is ended the same way first, the line says so, and the
                             runner then ends BY THAT SIGNAL, which a shell reports as 128 plus its
                             number and which stops a shell loop around the runner at Ctrl C.
                             That holds once the handlers are in (THE SIGNALS, below).

123, 124 and 125 are also codes a command can exit with by itself (another runner inside this one
does). Only the runner's line on standard error tells its own from the command's. One 125 has no
line there: the launcher's question (`--prove <word>`, at the foot of this file) is answered with
its one line on standard OUTPUT, for the launcher to read.

THE SIGNAL RULE. The runner signals a number only while something it holds pins that number to its
own child. What pins it: a child that has not been collected keeps its process id, running or
ended, and the group it leads has that same number. So the order is fixed:

  0. before anything is started, make sure this process keeps its ended children at all. A caller
     that ignores SIGCHLD hands that setting down, and on Linux a process with it has its children
     collected by the system the moment they end (claude-config#3833). So SIGCHLD is put back to
     its default here, and a child started only to be collected proves it took: where that child
     is gone before the runner collects it, nothing would pin a number and nothing is run (125);
  1. start the command as the leader of a new group, and never collect it while anything may still
     be signalled;
  2. learn that it ended WITHOUT collecting it: on macOS a process event from a kqueue, elsewhere
     waitid with WNOWAIT, both of which only look;
  3. see whether the group still holds anything, and end what it holds, while the uncollected
     child still pins the number;
  4. collect the child, last. After that the number may be handed to any new process, and nothing
     here signals it again.

The Group class is the one place that signals the command or its group and the one place that
collects it. It refuses a signal after the collect, and after either of its own looks (the one
before a fault's KILL, the one for a suspended command) was told the child is no longer this
process's own. The Linux watch's look is outside the class: told the same, it raises, which is a
fault, and the fault's own look asks again before any signal. test-run-with-limit.sh replaces the
calls with recorders and fails on a signal asked for outside the rule (which the recorder never
sends). Two other children exist, both before the command. The one step 0 starts is never
signalled and is collected through the same class. The reader that names the marker folder is
started by python's subprocess module, which collects it and, on a time out, ends it by its own
process id while it is still uncollected.

SEEING WHAT IS LEFT WITHOUT ps. `ps` is a setuid program, which macOS refuses to start inside a
sandbox, so a runner that read it could not run under no-network-run.sh.
  - macOS: signal 0 to the group. Measured on 2026-11-27 on the personal MacBook (macOS 26.6.2),
    one run, with a probe's own children: a group holding only its ended, uncollected leader
    answered EPERM (nothing there that may be signalled), a group with one more member answered
    success, and 15 ms after that member ended it answered EPERM again. A group that does not
    exist answers ESRCH, so both are read as nothing left.
  - Linux: signal 0 succeeds for a group holding only its ended leader (the kernel's documented
    behaviour, not measured here), so it cannot tell. The members are read from /proc (state,
    parent and group in each stat file), and one whose state is Z, ended and waiting to be
    collected, is not counted.
Both are checked before anything is started, against the runner's own group, which must show at
least the runner: a system where that fails is refused (125), since there every leftover would
read as none (L1).

WHAT A COMMAND LEAVES IS GIVEN SETTLE SECONDS TO END BY ITSELF before it counts as left running. A
shell does not wait for a process substitution, so `exec > >(tee log)` ends with tee a moment
behind it, still writing what it was piped; ending tee at once would cut the log short and fail a
passing run by a race. A process still there after SETTLE is stopped and the run fails.

THE GROUP RECORD (bash-shell-mark.sh's seam, claude-config#3561). The leftover process check ties a
process to a session by its group, and a command started here has left its shell's group. So,
when the run is inside a session whose shells are recorded, an empty file named for the new
group's id is made in the folder `agent-leftovers.py dir <session id>` prints, before the command
starts. The check lists a group only once its leader has gone, so the record is what ties to the
session anything the command leaves after it: when the runner could not end the group, and when the
runner was itself ended outright, once the command has ended. THE RUNNER TAKES ITS OWN RECORD AWAY
when the group is known to hold nothing, just before it collects the command: the uncollected
command still pins the number the file is named for, so no shell and no other runner can have made
a file of that name since. A record left for every run would tie that number to the session for
as long as the folder lives, and process ids come round again within minutes. A session with no
marker folder is left alone: the reader says that itself, and the folder's being there is what
tells it the session's shells are recorded.

THE TERMINAL. The command is in a group of its own, which at a terminal is a background group: a
command that reads or sets the terminal there is suspended by the system until the limit ends it.
The runner hands the terminal to nobody. It is for commands that do not read a terminal (an agent
and a gate have none), the usage says so, and the 124 line says when the command was suspended.

THE SIGNALS. CARRIED names the ones that would end the runner and that it carries over; each ends
the group first. On Linux so do IO, PWR, STKFLT and the real time signals python can set, from its
SIGRTMIN up (34 with glibc; 32 and 33 belong to the C library, and python cannot set them). One
the caller had ignored stays ignored. Three more would STOP the runner, and a stopped runner keeps
no limit: TSTP (Ctrl Z) is caught and not acted on, and TTIN and TTOU are ignored while a command
runs, which the command does not inherit. What leaves a command with no limit:
  - KILL, and STOP for as long as the runner is stopped (the limit is applied late, when it goes
    on). Nothing can catch either;
  - a real fault in the runner's own process, since a python handler cannot return from one. That
    is why the signals a fault raises (ABRT, BUS, FPE, ILL, SEGV, SYS, TRAP, and EMT on macOS)
    are left at their default;
  - by choice, those same signals sent from OUTSIDE. ABRT, TRAP, SYS and EMT could be carried
    over when something else sends them, and are not.
The handlers go in a moment after the command's process exists, and before it is let go. Until
then TERM and the others end the runner at once, and the command, not yet let go, never starts.
An INT in that span is turned by python into an error instead: 125 with nothing run, where an end
by INT was meant. A stop that lands in the few steps between the runner's last look for one and
its letting the command go starts the command and stops it at once.

GRACE, SETTLE and GONE are settings, not measurements. Not covered: a process the command starts
outside the group (setsid, a job control shell); a process this user may not signal (a setuid
program), which signal 0 cannot see; a command that left its own group, which runs up to GONE
seconds past its limit before TERM goes to it by its process id (the comment at that wait says
why); and a runner ended or stopped by one of the signals above that it does not answer, after
which the command runs on with no limit.
"""
import errno
import os
import re
import select
import shlex
import signal
import sys
import time

NAME = 'run-with-limit'
EXIT_LEFT = 123
EXIT_LIMIT = 124
EXIT_REFUSED = 125
MAX_SECONDS = 86400      # a day: a limit nothing reaches is no limit
GRACE = 2.0              # from TERM to KILL
SETTLE = 1.0             # what a command leaves may take this long to end by itself
GONE = 10.0              # after KILL, how long the group is watched before the runner gives up
LOOK = 0.02              # between two looks at a group
HELPER_SECONDS = 10      # the reader naming the marker folder
PROVE = '--prove'        # the launcher's one question, answered with EXIT_REFUSED: nothing is run
# The signals that would end the runner and that it can catch. Each is carried over to the group.
CARRIED = ('SIGTERM', 'SIGINT', 'SIGHUP', 'SIGQUIT', 'SIGUSR1', 'SIGUSR2', 'SIGALRM', 'SIGVTALRM',
           'SIGPROF', 'SIGXCPU')
CARRIED_LINUX = ('SIGIO', 'SIGPWR', 'SIGSTKFLT')    # these end a process on Linux only
# How a child's end reads in a waitid look. macOS answers a look for an ended child with a child
# that is only suspended (measured on 2026-11-27, macOS 26.6.2, python 3.14.4, one run), so the
# kind is read, never taken from there being an answer.
ENDED = (getattr(os, 'CLD_EXITED', 1), getattr(os, 'CLD_KILLED', 2), getattr(os, 'CLD_DUMPED', 3))
SUSPENDED = getattr(os, 'CLD_STOPPED', 5)

USAGE = """usage: run-with-limit.sh <seconds> <command> [its words]
  Runs the command in a process group of its own for at most <seconds>, a whole number from 1 to
  %d. At the limit the whole group is ended (TERM, then KILL) and the run comes back as 124. A
  command that ends in time and leaves a process running in its group has it stopped, and the run
  comes back as 123. Otherwise the command's own exit code comes back. 125: nothing was run.
  It is for commands that do not read or set a terminal: at a terminal the command is in a
  background group, where a read of the terminal suspends it until the limit. A signal sent to the
  runner that it can catch ends the command's group first (TERM, INT, HUP, QUIT, USR1, USR2, ALRM
  and the like); KILL and STOP cannot be caught, and Ctrl Z does not stop the runner.
""" % MAX_SECONDS

now = time.monotonic
TOLD = 0                 # the signal the last run was told to stop by, for the way out
LET_GO = False           # whether the last run had let its command go


def say(text):
    """One line on standard error, in one write."""
    try:
        os.write(2, ('%s: %s\n' % (NAME, ' '.join(str(text).split('\n')))).encode('utf-8', 'replace'))
    except OSError:
        pass


def shown(command):
    """The command on one line, short enough to read."""
    text = ' '.join(shlex.quote(word) for word in command).replace('\n', ' ').replace('\r', ' ')
    return text if len(text) <= 200 else text[:197] + '...'


def name_of(sig):
    try:
        return signal.Signals(sig).name
    except ValueError:
        return 'signal %d' % sig


def signal_group(pgid, sig):
    """THE ONE CALL THAT SIGNALS A GROUP. Its two callers are Group.send, which holds the pin, and
    the check of the runner's own group in pick."""
    os.killpg(pgid, sig)


def signal_process(pid, sig):
    """THE ONE CALL THAT SIGNALS A PROCESS. Its one caller is Group.send_command, which holds the
    pin: the command itself, by the process id it keeps for as long as it is uncollected."""
    os.kill(pid, sig)


class Group:
    """The command and its process group, pinned by the command itself: an uncollected child keeps
    its process id, and the group it leads has that number. Every signal goes through send or
    send_command, which refuse once the child has been collected or the system has said it is no
    longer this process's child, and collect is the only collecting call."""

    def __init__(self, pid):
        self.pid = pid
        self.collected = False
        self.lost = False
        self.status = None

    def _pin(self, what):
        if self.collected:
            raise RuntimeError('%s %d was asked for after the command was collected; nothing was sent' % (what, self.pid))
        if self.lost:
            raise RuntimeError('%s %d was asked for after the system said the command is no longer this runner\'s child; nothing was sent' % (what, self.pid))

    def send(self, sig):
        """To the group. True when the signal reached at least one process. False when the group
        holds nothing this user may signal: only its ended leader, or nothing at all."""
        self._pin('a signal for group')
        try:
            signal_group(self.pid, sig)
            return True
        except (ProcessLookupError, PermissionError):
            return False

    def send_command(self, sig):
        """To the command itself, by its own process id, whatever group it has moved to. False
        when this user may not signal it."""
        self._pin('a signal for process')
        try:
            signal_process(self.pid, sig)
            return True
        except (ProcessLookupError, PermissionError):
            return False

    def pinned(self):
        """Whether the number is still the command's: not collected here, and not collected by
        anything else. Where python can look without collecting, the system is asked."""
        if self.collected or self.lost:
            return False
        if hasattr(os, 'waitid'):
            try:
                os.waitid(os.P_PID, self.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            except ChildProcessError:
                self.lost = True
            except OSError:
                pass
        return not self.lost

    def suspended(self):
        """True when the command is suspended (stopped by a signal: not running, not ended). None
        when this python has no call that looks without collecting."""
        if self.collected or self.lost or not hasattr(os, 'waitid') or not hasattr(os, 'WSTOPPED'):
            return None
        try:
            got = os.waitid(os.P_PID, self.pid, os.WSTOPPED | os.WNOHANG | os.WNOWAIT)
        except ChildProcessError:
            self.lost = True         # as in pinned: nothing pins the number now, and _pin refuses
            return None
        except OSError:
            return None
        return got is not None and got.si_code == SUSPENDED

    def collect(self):
        """The command's wait status. Marked collected BEFORE the call that collects, so nothing
        that interrupts the call can be followed by a signal."""
        if not self.collected:
            self.collected = True
            self.status = os.waitpid(self.pid, 0)[1]
        return self.status


class Asked:
    """Which signal told the runner to stop, if one did."""
    sig = 0

    def note(self, signum, frame=None):
        self.sig = self.sig or int(signum)

    def stay(self, signum, frame=None):
        """For TSTP: caught and not acted on, so the runner is never stopped by it."""


class KqueueWatch:
    """macOS: the kernel says when the command ends, and reading that collects nothing. The signals
    that tell the runner to stop wake the same wait."""

    def __init__(self, pid, asked, signals):
        self.ended = False
        self.asked = asked
        self.kq = select.kqueue()
        if signals:
            self.kq.control([select.kevent(s, select.KQ_FILTER_SIGNAL, select.KQ_EV_ADD) for s in signals], 0, 0)
        try:
            self.kq.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 0, 0)
        except ProcessLookupError:
            # The child is uncollected, so the number is still its own: it has already ended.
            self.ended = True

    def wait(self, seconds, heed=True):
        """Returns when the command has ended, when `seconds` have passed, or, with heed, when a
        stop was asked for. It always looks once, so 0 seconds is one look."""
        end = time.monotonic() + max(0.0, seconds)
        while not self.ended and not (heed and self.asked.sig):
            rest = end - time.monotonic()
            for event in self.kq.control(None, 8, max(0.0, rest)):
                if event.filter == select.KQ_FILTER_PROC:
                    self.ended = True
                elif event.filter == select.KQ_FILTER_SIGNAL:
                    self.asked.note(event.ident)
            if rest <= 0:
                return

    def close(self):
        self.kq.close()


class WaitidWatch:
    """Where there is no kqueue: waitid with WNOWAIT reports that the child has ended and leaves
    it uncollected. Asked every LOOK seconds, since nothing here can wait on it with a time out."""

    def __init__(self, pid, asked, signals):
        self.ended = False
        self.asked = asked
        self.pid = pid

    def wait(self, seconds, heed=True):
        """As KqueueWatch.wait: until the command has ended, `seconds` have passed or, with heed,
        a stop was asked for, and always one look."""
        end = time.monotonic() + max(0.0, seconds)
        while not self.ended:
            got = os.waitid(os.P_PID, self.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if got is not None and got.si_code in ENDED:
                self.ended = True
                return
            rest = end - time.monotonic()
            if rest <= 0 or (heed and self.asked.sig):
                return
            time.sleep(min(LOOK, rest))

    def close(self):
        pass


def proc_members(pgid, root='/proc'):
    """Linux: how many processes in the group are running, from each /proc/<pid>/stat (the fields
    after the name in brackets are state, parent and group). None when /proc cannot be listed."""
    try:
        names = os.listdir(root)
    except OSError:
        return None
    count = 0
    want = b'%d' % pgid
    for name in names:
        if not re.fullmatch('[0-9]+', name):
            continue
        try:
            with open(os.path.join(root, name, 'stat'), 'rb') as f:
                fields = f.read().rpartition(b')')[2].split()
        except OSError:
            continue        # it ended between the listing and the read
        if len(fields) >= 3 and fields[2] == want and fields[0] not in (b'Z', b'X'):
            count += 1
    return count


def left_by_signal(group):
    return group.send(0)


def left_by_proc(group):
    # A /proc that cannot be read is taken as something left, so the group is still sent TERM and
    # KILL while it is pinned. It is never taken as an empty group.
    return proc_members(group.pid) != 0


def pick():
    """(the watch, the reader of what is left) for this system, or a sentence saying why it has
    none. Each reader is first asked about the runner's own group, where the answer is known."""
    if sys.platform == 'darwin' and hasattr(select, 'kqueue'):
        try:
            signal_group(os.getpgrp(), 0)
        except OSError as e:
            return 'signal 0 to its own process group was refused here (%s), so it could not see what a command leaves' % e.strerror
        return KqueueWatch, left_by_signal
    if sys.platform.startswith('linux') and hasattr(os, 'waitid'):
        if not proc_members(os.getpgrp()):
            return '/proc does not show this process in its own group here, so it could not see what a command leaves'
        return WaitidWatch, left_by_proc
    return 'it is built for macOS and Linux, and this is %s' % sys.platform


def parse(argv):
    """(seconds, command), or (None, why)."""
    if len(argv) < 2:
        return None, 'it needs a number of seconds and then a command'
    if not re.fullmatch('[0-9]{1,18}', argv[0]) or not 1 <= int(argv[0]) <= MAX_SECONDS:
        return None, 'the limit must be a whole number of seconds from 1 to %d, and %s is not' % (MAX_SECONDS, shlex.quote(argv[0]))
    if not argv[1]:
        return None, 'the command is an empty word'
    return int(argv[0]), list(argv[1:])


def carried():
    """The numbers of the signals to carry over on this system."""
    linux = sys.platform.startswith('linux')
    found = [int(getattr(signal, name)) for name in CARRIED + (CARRIED_LINUX if linux else ()) if hasattr(signal, name)]
    if linux and hasattr(signal, 'SIGRTMIN') and hasattr(signal, 'SIGRTMAX'):
        found += list(range(int(signal.SIGRTMIN), int(signal.SIGRTMAX) + 1))     # each ends a process by default
    return found


def catch(sig, handler, handled):
    """Catch one signal for the length of the run (or ignore it, with SIG_IGN as the handler),
    remembering what was there. One the caller had ignored stays ignored, and one that cannot be
    set here is left as it is."""
    try:
        if signal.getsignal(sig) == signal.SIG_IGN:
            return False
        handled[sig] = signal.signal(sig, handler)
        return True
    except (OSError, ValueError):
        return False


def keep_children():
    """Step 0 of the rule. (how the caller had SIGCHLD, None) once this process is seen to keep an
    ended child until it collects it, or (that, why not). The child started here does nothing and
    ends at once; it is collected through Group, as the command will be."""
    was = signal.getsignal(signal.SIGCHLD)
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    try:
        Group(pid).collect()
    except ChildProcessError:
        return was, ('this system collected the runner\'s own child before the runner did, with SIGCHLD at its default, '
                     'so nothing here would pin the number a signal goes to')
    return was, None


def unrecorded(why):
    say('this run\'s process group is not recorded for the leftover process check (%s); the limit is kept all the same' % why)


def marker_folder():
    """The session's marker folder, from the reader that owns the path. None when the run is in no
    session (nothing to record), or the session has no folder (its shells are not recorded, which
    the reader says itself)."""
    session = os.environ.get('CLAUDE_CODE_SESSION_ID') or ''
    if not session:
        return None
    import subprocess    # here, so a run outside a session does not pay for loading it
    reader =os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent-leftovers.py')
    try:
        # -I as the launcher starts this program: no PYTHON variable and no file beside the reader
        # changes what it loads.
        got = subprocess.run([sys.executable or 'python3', '-I', reader, 'dir', session], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=HELPER_SECONDS)
    except (OSError, subprocess.SubprocessError) as e:
        unrecorded('%s could not be asked for the session\'s marker folder: %s' % (reader, e))
        return None
    folder = os.fsdecode(got.stdout).rstrip('\n')
    if got.returncode != 0 or not folder.startswith('/') or '\n' in folder:
        unrecorded('%s named no marker folder for this session, exit %d' % (reader, got.returncode))
        return None
    return folder if os.path.isdir(folder) else None


def record(folder, pgid):
    """The empty file named for the group's id, as a recorded shell leaves one for its own. Made
    again over an older file of the same number, it takes the new time. Returns the file's path,
    or None when none was made."""
    if folder is None:
        return None
    path = os.path.join(folder, str(pgid))
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            os.utime(fd, None)
        finally:
            os.close(fd)
    except OSError as e:
        unrecorded('%s could not be made: %s' % (path, e.strerror))
        return None
    return path


def forget(path):
    """Take the runner's own record away, by the name it made. Called only when the group is known
    to hold nothing and just BEFORE the collect: the uncollected command still pins the number the
    file is named for, so the file of that name is this run's and nobody else's. A file that will
    not go is left, as every record was before."""
    if path is None:
        return
    try:
        os.unlink(path)
    except OSError:
        pass


def run_by_sh(command):
    """A file that may be executed and has no interpreter line is a shell script by long custom: a
    shell, env and timeout hand it to sh, and python's execvp does not. Returns the error when sh
    could not be started either, or None when the file could not be found again."""
    path = command[0]
    if '/' not in path:
        tried = (os.path.join(folder or '.', path) for folder in os.get_exec_path())
        path = next((p for p in tried if os.path.isfile(p) and os.access(p, os.X_OK)), None)
        if path is None:
            return None
    try:
        os.execv('/bin/sh', ['sh', path] + list(command[1:]))
    except OSError as e:
        return e


def become(command, gate_r, gate_w, chld_was):
    """The child: lead a new group, wait to be let go, become the command. It is let go only once
    the runner is watching it and has made the record, and if the runner has gone instead it ends
    here: the command is never started with nobody to keep its limit."""
    code = EXIT_REFUSED
    try:
        os.close(gate_w)
        # The runner makes this same call for this process at the same moment (run, below), and
        # macOS now and then refuses one of two that meet: EPERM. Measured on 2026-11-27 on the
        # personal MacBook (macOS 26.6.2, python 3.14.4) at loads of 20 to 83, 13000 children in
        # two runs of a probe that makes only these two calls: this side was refused 10 times,
        # the parent's 10 times, never both, and every child led its own group once its parent's
        # call had come back (one of the ten did not yet when its own came back). Why macOS
        # refuses was not found. So that refusal is not the end, and is not the answer either:
        # where this process is gets asked once it is let go, below. EPERM alone is passed over.
        # Any other error from the call is one nothing here has measured, and it is raised.
        try:
            os.setpgid(0, 0)
        except OSError as e:
            if e.errno != errno.EPERM:
                raise
        # Python ignores these two for itself, and an ignored signal stays ignored in the command.
        for name in ('SIGPIPE', 'SIGXFSZ'):
            if hasattr(signal, name):
                signal.signal(getattr(signal, name), signal.SIG_DFL)
        # The runner took SIGCHLD back to its default for itself. The command starts as its caller
        # would have started it.
        if chld_was == signal.SIG_IGN:
            signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        if os.read(gate_r, 1) == b'1':
            # Let go, so the runner's own call has come back and nothing changes this process's
            # group from here on. A process that does not lead a group of its own never becomes
            # the command: the group is what the limit ends. It does NOT ask again here. A group
            # made after the runner let go is one the runner never looked at, and a stop, a limit
            # or a fault in that span would find no group to end. Both calls refused was seen 0
            # times in the 13000 children measured above, so no run there would have been lost
            # to this. This process ends with 125 and says why, and the command never starts.
            if os.getpgrp() != os.getpid():
                raise RuntimeError('it does not lead a process group of its own')
            try:
                os.execvp(command[0], command)
            except OSError as e:
                if e.errno == errno.ENOEXEC:
                    e = run_by_sh(command) or e
                code = 127 if e.errno == errno.ENOENT else 126
                say('could not start %s: %s' % (shlex.quote(command[0]), e.strerror))
    except BaseException as e:
        say('nothing was run: the process that was to become the command failed first (%s: %s): %s'
            % (type(e).__name__, e, shown(command)))
    finally:
        os._exit(code)


def wait_empty(left, seconds, asked=None):
    """True once the group holds nothing. False when `seconds` passed first, or a stop was asked for."""
    end = now() + seconds
    while left():
        if asked is not None and asked.sig:
            return False
        rest = end - now()
        if rest <= 0:
            return False
        time.sleep(min(LOOK, rest))
    return True


def stop(group, left):
    """End the group: TERM, GRACE seconds, KILL. Says which it took, or None when something was
    still there GONE seconds after KILL."""
    group.send(signal.SIGTERM)
    if wait_empty(left, GRACE):
        return 'TERM'
    group.send(signal.SIGKILL)
    if wait_empty(left, GONE):
        return 'KILL'
    return None


def stop_command(group, watch):
    """End the command itself by its own process id, which it keeps while it is uncollected: for a
    command that is still running when its group holds nothing, because it moved itself to another
    group. Says which it took, or None when this user may not signal it or it did not end."""
    if not group.send_command(signal.SIGTERM):
        return None
    watch.wait(GRACE, heed=False)
    if watch.ended:
        return 'TERM'
    group.send_command(signal.SIGKILL)
    watch.wait(GONE, heed=False)
    return 'KILL' if watch.ended else None


def code_of(status):
    return 128 + os.WTERMSIG(status) if os.WIFSIGNALED(status) else os.WEXITSTATUS(status)


def supervise(group, watch, asked, left, seconds, deadline, command, marker):
    while not watch.ended and not asked.sig:
        rest = deadline - now()
        if rest <= 0:
            break
        watch.wait(rest)
    in_time = watch.ended
    # The ordinary end: nothing left, or what was left ended by itself inside SETTLE.
    if in_time and (not left() or wait_empty(left, SETTLE, asked)):
        forget(marker)
        return code_of(group.collect())

    suspended = not in_time and not asked.sig and group.suspended()
    took = stop(group, left)
    # Collected only once the watch says it has ended, so the collect cannot wait on a command that
    # is still running (one this user may not signal reads as nothing left).
    # THE WATCH GOES ON FOR UP TO GONE SECONDS BEFORE ANYTHING IS SENT BY PROCESS ID, and "the
    # group reads empty and the command has not ended" is no reason to cut it short. On macOS a
    # leader that is ending stops counting as a member of its group at the START of its exit, and
    # its process event is queued near the END of it, after its files are closed (Apple's
    # published kernel source, read on 2026-11-27, not measured here). All through that span a
    # signal to its process id answers success. So an ordinary command that is ending reads there
    # exactly as one that left its group, and a TERM by id sent then would have the line say the
    # command had left a group it never left. The cost is said in README: a command that did
    # leave its group runs up to GONE seconds past its limit before TERM goes to it by its id.
    watch.wait(GONE if took else 0, heed=False)
    by_id = None
    if took and not watch.ended:
        by_id = stop_command(group, watch)
    status = None
    if watch.ended:
        if took:
            forget(marker)
        status = group.collect()

    if by_id:
        how = ('the command had left its process group (id %d), so once that group held nothing the command was ended by its own process id, at %s; '
               'anything it started outside the group is left running' % (group.pid, by_id))
    elif status is None and took:
        how = ('its process group (id %d) holds nothing this user may signal, the command would not be ended by its own process id either, '
               'and it is left running' % group.pid)
    elif took == 'TERM':
        how = 'its whole process group (id %d) ended at TERM' % group.pid
    elif took == 'KILL':
        how = 'its whole process group (id %d) ended at KILL, %g seconds after TERM' % (group.pid, GRACE)
    else:
        how = 'a process in its group (id %d) was still there %g seconds after KILL and is left running' % (group.pid, GONE)
    if asked.sig:
        say('was sent %s, so its command was stopped: %s: %s' % (name_of(asked.sig), how, shown(command)))
        return 128 + asked.sig
    if in_time:
        ended = 'signal %d' % os.WTERMSIG(status) if os.WIFSIGNALED(status) else 'exit code %d' % os.WEXITSTATUS(status)
        say('the command ended in time (%s) and left a process running, which was stopped: %s. This run fails with %d: %s'
            % (ended, how, EXIT_LEFT, shown(command)))
        return EXIT_LEFT
    when = ''
    if suspended:
        # The look says THAT it was suspended, never why: it may have stopped itself, or been sent
        # STOP. So the terminal is named as the likely cause and no more.
        when = (' while it was suspended, not running (the likely cause is the terminal: a command in a background group is suspended '
                'when it reads or sets it, and this runner is for commands that do not)')
    say('the command reached its %d second limit%s and was stopped: %s: %s' % (seconds, when, how, shown(command)))
    return EXIT_LIMIT


def never_let_go(group, watch, asked, left, command, marker):
    """A stop asked for before the command was let go. The gate is already shut: the child reads
    the end of the pipe and ends without becoming the command."""
    watch.wait(GONE, heed=False)
    if not watch.ended and stop(group, left):
        watch.wait(GONE, heed=False)
    if watch.ended:
        forget(marker)
        group.collect()
        say('was sent %s before its command was let go, so nothing was run: %s' % (name_of(asked.sig), shown(command)))
    else:
        say('was sent %s before its command was let go, so nothing was run; the process that waited to become the command (id %d) has not ended: %s'
            % (name_of(asked.sig), group.pid, shown(command)))
    return 128 + asked.sig


def run(argv):
    global TOLD, LET_GO
    seconds, command = parse(argv)
    if seconds is None:
        why = command
        try:
            os.write(2, USAGE.encode('utf-8'))
        except OSError:
            pass
        say('nothing was run: %s' % why)
        return EXIT_REFUSED
    picked = pick()
    if isinstance(picked, str):
        say('nothing was run: %s: %s' % (picked, shown(command)))
        return EXIT_REFUSED
    watch_class, left_of = picked
    chld_was, why = keep_children()
    if why:
        say('nothing was run: %s: %s' % (why, shown(command)))
        return EXIT_REFUSED
    folder = marker_folder()

    gate_r, gate_w = os.pipe()
    try:
        pid = os.fork()
    except OSError as e:
        os.close(gate_r)
        os.close(gate_w)
        say('nothing was run: a process could not be started (%s): %s' % (e.strerror, shown(command)))
        return EXIT_REFUSED
    if pid == 0:
        become(command, gate_r, gate_w, chld_was)

    group = Group(pid)
    asked = Asked()
    handled = {}
    watch = None
    marker = None
    try:
        os.close(gate_r)
        try:
            os.setpgid(pid, pid)     # the child does the same, and one of two that meet may be refused (become)
        except OSError:
            pass                     # any refusal: the child's own look, once let go, is what decides
        stoppers = [sig for sig in carried() if catch(sig, asked.note, handled)]
        if hasattr(signal, 'SIGTSTP'):
            catch(signal.SIGTSTP, asked.stay, handled)
        # TTIN and TTOU stop a process as TSTP does. IGNORED, never caught: a write that raised a
        # caught TTOU fails and is tried again, for ever. Set here, after the fork, so the command
        # does not inherit it: its process exists already, with both as the caller had them.
        for name in ('SIGTTIN', 'SIGTTOU'):
            if hasattr(signal, name):
                catch(getattr(signal, name), signal.SIG_IGN, handled)
        watch = watch_class(pid, asked, stoppers)
        marker = record(folder, pid)
        deadline = now() + seconds
        if asked.sig:
            os.close(gate_w)         # shut, never opened: the command is not started to be stopped
            gate_w = -1
            code = never_let_go(group, watch, asked, lambda: left_of(group), command, marker)
        else:
            LET_GO = True
            try:
                os.write(gate_w, b'1')   # the command starts here
            except BrokenPipeError:
                pass                     # the child was ended from outside before it was let go
            os.close(gate_w)
            gate_w = -1
            code = supervise(group, watch, asked, lambda: left_of(group), seconds, deadline, command, marker)
        if asked.sig and code == 128 + asked.sig:
            TOLD = asked.sig
        return code
    except BaseException as e:
        # A fault in the runner itself. The command must not run on with no limit, and KILL goes
        # only to a number the still uncollected child pins.
        if group.pinned():
            if group.send(signal.SIGKILL):
                done = 'so its command\'s process group (id %d) was sent KILL' % pid
            else:
                done = 'and its command\'s process group (id %d) held nothing that KILL could be sent to' % pid
        elif group.collected:
            done = 'after its command (process %d) was collected, so nothing was signalled' % pid
        else:
            done = ('and its command (process %d) is no longer this runner\'s child, so nothing was signalled and anything it started is left running'
                    % pid)
        say('failed inside itself (%s: %s), %s: %s' % (type(e).__name__, e, done, shown(command)))
        return EXIT_REFUSED
    finally:
        try:
            if gate_w >= 0:
                os.close(gate_w)     # a child never let go reads the end of the pipe and ends
            if watch is not None:
                watch.close()
            for sig, old in handled.items():
                signal.signal(sig, old if old is not None else signal.SIG_DFL)
        except (OSError, ValueError):
            pass


def main(argv):
    """The run's code. A fault of the runner's own never leaves as python's exit code 1 with a
    traceback, which would read as the command's."""
    global TOLD, LET_GO
    TOLD, LET_GO = 0, False
    try:
        return run(argv)
    except BaseException as e:
        words = ' '.join(shlex.quote(str(word)) for word in argv)[:200]
        if LET_GO:
            say('failed inside itself as it finished (%s: %s); what it did to its command is said above: %s' % (type(e).__name__, e, words))
        else:
            say('nothing was run: it failed inside itself before it let a command go (%s: %s): %s' % (type(e).__name__, e, words))
        return EXIT_REFUSED


def leave(code):
    """The way out. A runner that was told to stop ends by that signal, as the command it ran in
    place of would have: a shell loop around it stops at Ctrl C only when its child died of the
    signal. No process id is named: the signal is raised in this process."""
    if TOLD:
        try:
            import resource
            resource.setrlimit(resource.RLIMIT_CORE, (0, resource.getrlimit(resource.RLIMIT_CORE)[1]))
        except Exception:
            pass                     # a core file of the runner is of no use; without the limit it is only that
        try:
            signal.signal(TOLD, signal.SIG_DFL)
            signal.raise_signal(TOLD)
        except (OSError, ValueError, AttributeError):
            pass
    sys.exit(code)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == PROVE:
        # The launcher's question, asked before it hands a command over: only this program answers
        # with these words. The code is the one for "nothing was run", so the question typed as
        # the words of a run can never read as a pass.
        try:
            os.write(1, ('%s proves %s\n' % (NAME, sys.argv[2])).encode('utf-8', 'replace'))
        except OSError:
            pass
        sys.exit(EXIT_REFUSED)
    leave(main(sys.argv[1:]))
