#!/usr/bin/env python3
"""The program behind lib/run-with-limit.sh: run one command for at most N seconds, in a process
group of its own, and end the WHOLE group when the limit runs out (claude-config#3578).

    run-with-limit.sh <seconds> <command> [its words]

What comes back, and what is said (one line on standard error, only when something was stopped or
could not be done):

    the command's own code   it ended in time and left nothing running (128 plus the signal's
                             number when a signal ended it; 127 or 126 when it could not be started)
    124                      it reached the limit: its group was sent TERM, then KILL GRACE seconds
                             later if anything was still there
    123                      it ended in time and LEFT A PROCESS RUNNING in its group, which was
                             stopped the same way. Whatever the command's own code was, the run
                             fails: a suite that passes and leaves a process behind is the fault
                             of 2026-11-24 (19 shells ran on for 90 minutes, claude-config#3561)
    125                      nothing was run: the limit is not a whole number of seconds from 1 to
                             MAX_SECONDS, there is no command, or this system gives the runner no
                             way to keep the rule below. Also a fault inside the runner, after
                             which the group was sent KILL. Never the command with no limit.
    128 plus the signal      the runner itself was sent TERM, INT or HUP: the group is ended the
                             same way first. A command in a group of its own is out of reach of
                             whatever stops the runner's group, so the runner carries the stop over.

THE SIGNAL RULE. The runner signals a number only while something it holds pins that number to its
own child. What pins it: a child that has not been collected keeps its process id, running or
ended, and the group it leads has that same number. So the order is fixed:

  1. start the command as the leader of a new group, and never collect it while anything may still
     be signalled;
  2. learn that it ended WITHOUT collecting it: on macOS a process event from a kqueue, elsewhere
     waitid with WNOWAIT, both of which only look;
  3. see whether the group still holds anything, and end what it holds, while the uncollected
     child still pins the number;
  4. collect the child, last. After that the number may be handed to any new process, and nothing
     here signals it again.

The Group class is the one place that signals and the one place that collects, and it refuses the
first after the second. test-run-with-limit.sh replaces both calls with recorders and fails on a
signal asked for after the collect (which the recorder never sends).

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
starts. A runner that is killed outright (KILL) cannot stop its group, and the record is what lets
the check find it. A session with no marker folder is left alone: the reader says that itself, and
the folder's being there is what tells it the session's shells are recorded.

GRACE, SETTLE and GONE are settings, not measurements. Not covered: a process that leaves the
group (setsid, a job control shell); a process this user may not signal (a setuid program), which
signal 0 cannot see; and the runner itself ended by KILL, after which the command runs on with no
limit and only the record names it.
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
STOPPERS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)

USAGE = """usage: run-with-limit.sh <seconds> <command> [its words]
  Runs the command in a process group of its own for at most <seconds>, a whole number from 1 to
  %d. At the limit the whole group is ended (TERM, then KILL) and the run comes back as 124. A
  command that ends in time and leaves a process running in its group has it stopped, and the run
  comes back as 123. Otherwise the command's own exit code comes back. 125: nothing was run.
""" % MAX_SECONDS

now = time.monotonic


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


def signal_group(pgid, sig):
    """THE ONE CALL THAT SIGNALS. Its two callers are Group.send, which holds the pin, and the check
    of the runner's own group in pick."""
    os.killpg(pgid, sig)


class Group:
    """The command's process group, pinned by the command itself: an uncollected child keeps its
    process id, and the group it leads has that number. Every signal goes through send, which
    refuses once the child has been collected, and collect is the only collecting call."""

    def __init__(self, pid):
        self.pid = pid
        self.collected = False
        self.status = None

    def send(self, sig):
        """True when the signal reached at least one process. False when the group holds nothing
        this user may signal: only its ended leader, or nothing at all."""
        if self.collected:
            raise RuntimeError('a signal for group %d was asked for after its leader was collected; nothing was sent' % self.pid)
        try:
            signal_group(self.pid, sig)
            return True
        except (ProcessLookupError, PermissionError):
            return False

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
            if os.waitid(os.P_PID, self.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
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
        got = subprocess.run([sys.executable or 'python3', reader, 'dir', session], stdin=subprocess.DEVNULL,
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
    again over an older file of the same number, it takes the new time."""
    if folder is None:
        return
    path = os.path.join(folder, str(pgid))
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            os.utime(fd, None)
        finally:
            os.close(fd)
    except OSError as e:
        unrecorded('%s could not be made: %s' % (path, e.strerror))


def become(command, gate_r, gate_w):
    """The child: lead a new group, wait to be let go, become the command. It is let go only once
    the runner is watching it and has made the record, and if the runner has gone instead it ends
    here: the command is never started with nobody to keep its limit."""
    code = EXIT_REFUSED
    try:
        os.close(gate_w)
        os.setpgid(0, 0)
        # Python ignores these two for itself, and an ignored signal stays ignored in the command.
        for name in ('SIGPIPE', 'SIGXFSZ'):
            if hasattr(signal, name):
                signal.signal(getattr(signal, name), signal.SIG_DFL)
        if os.read(gate_r, 1) == b'1':
            try:
                os.execvp(command[0], command)
            except OSError as e:
                code = 127 if e.errno == errno.ENOENT else 126
                say('could not start %s: %s' % (shlex.quote(command[0]), e.strerror))
    except BaseException:
        pass
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


def code_of(status):
    return 128 + os.WTERMSIG(status) if os.WIFSIGNALED(status) else os.WEXITSTATUS(status)


def supervise(group, watch, asked, left, seconds, deadline, command):
    while not watch.ended and not asked.sig:
        rest = deadline - now()
        if rest <= 0:
            break
        watch.wait(rest)
    in_time = watch.ended
    # The ordinary end: nothing left, or what was left ended by itself inside SETTLE.
    if in_time and (not left() or wait_empty(left, SETTLE, asked)):
        return code_of(group.collect())

    took = stop(group, left)
    # Collected only once the watch says it has ended, so the collect cannot wait on a command that
    # is still running (one this user may not signal reads as nothing left).
    watch.wait(GONE if took else 0, heed=False)
    status = group.collect() if watch.ended else None

    if status is None and took:
        how = 'its process group (id %d) holds nothing this user may signal and the command has not ended, so it is left running' % group.pid
    elif took == 'TERM':
        how = 'its whole process group (id %d) ended at TERM' % group.pid
    elif took == 'KILL':
        how = 'its whole process group (id %d) ended at KILL, %g seconds after TERM' % (group.pid, GRACE)
    else:
        how = 'a process in its group (id %d) was still there %g seconds after KILL and is left running' % (group.pid, GONE)
    if asked.sig:
        say('was sent %s, so its command was stopped: %s: %s' % (signal.Signals(asked.sig).name, how, shown(command)))
        return 128 + asked.sig
    if in_time:
        ended = 'signal %d' % os.WTERMSIG(status) if os.WIFSIGNALED(status) else 'exit code %d' % os.WEXITSTATUS(status)
        say('the command ended in time (%s) and left a process running, which was stopped: %s. This run fails with %d: %s'
            % (ended, how, EXIT_LEFT, shown(command)))
        return EXIT_LEFT
    say('the command reached its %d second limit and was stopped: %s: %s' % (seconds, how, shown(command)))
    return EXIT_LIMIT


def main(argv):
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
    folder = marker_folder()

    gate_r, gate_w = os.pipe()
    try:
        pid = os.fork()
    except OSError as e:
        say('nothing was run: a process could not be started (%s): %s' % (e.strerror, shown(command)))
        return EXIT_REFUSED
    if pid == 0:
        become(command, gate_r, gate_w)
    os.close(gate_r)

    group = Group(pid)
    asked = Asked()
    handled = {}
    watch = None
    try:
        try:
            os.setpgid(pid, pid)     # the child does the same; whichever comes second is refused
        except OSError:
            pass
        for sig in STOPPERS:
            if signal.getsignal(sig) != signal.SIG_IGN:      # a signal the caller had ignored stays ignored
                handled[sig] = signal.signal(sig, asked.note)
        watch = watch_class(pid, asked, list(handled))
        record(folder, pid)
        deadline = now() + seconds
        try:
            os.write(gate_w, b'1')   # the command starts here
        except BrokenPipeError:
            pass                     # the child was ended from outside before it was let go
        os.close(gate_w)
        gate_w = -1
        return supervise(group, watch, asked, lambda: left_of(group), seconds, deadline, command)
    except BaseException as e:
        # A fault in the runner itself. The command must not run on with no limit, and the child,
        # still uncollected, pins the number the KILL goes to.
        if not group.collected:
            group.send(signal.SIGKILL)
        say('failed inside itself (%s: %s), so its command\'s process group (id %d) was sent KILL: %s'
            % (type(e).__name__, e, pid, shown(command)))
        return EXIT_REFUSED
    finally:
        if gate_w >= 0:
            os.close(gate_w)         # a child never let go reads the end of the pipe and ends
        if watch is not None:
            watch.close()
        for sig, old in handled.items():
            signal.signal(sig, old)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
