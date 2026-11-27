#!/usr/bin/env python3
"""The egress monitor of a verification run (claude-config#1571), owned by run_session.py's supervisor.

What it measures: every connection that serve's process tree and the drive helper open to any
address other than this machine's loopback, for the whole run, judged against the hosts the
project's areas.json allows (egress.allow, always including 127.0.0.1, localhost and ::1). It
never sees, and so never records, a request body or a header: only the process, the port and the
remote address.

How, and why this way (measured on macOS 26 without a password, 2026-10-23; see the PR for #1571):

  * serve and the drive helper run under `sandbox-exec` with a profile that ALLOWS every outbound
    connection but asks the kernel to REPORT each one whose remote is not localhost, tagged with
    this run's id. A sandbox is inherited by every descendant whatever its process group or
    session, so a child that daemonizes is still seen, and nothing is blocked: the app behaves as
    it would anywhere else.
  * The reports are read live with `log stream`, which needs no root. They name the process and
    the port but spell the address as `*`, so each report is NAMED by reading that process's open
    sockets with `lsof` the moment it arrives. A connection that closed before then, or whose
    sockets lsof could not read (it failed, timed out or could not run), stays in the receipt as
    unnamed, each saying which of the two it was, and an unnamed connection is never clean (fail
    closed).
  * The stream is proved live by a CANARY, a process under a profile of its own (tagged apart, so a
    reused pid can never pass a real connection off as the canary's) that connects a UDP
    socket to 198.51.100.1 (TEST-NET-2: reserved, and a UDP connect sends no packet at all). The
    monitor counts as started only once the start canary's report arrives, and the run's verdict
    counts only once an end canary, fired after serve's whole process group is gone, has arrived.
    Anything less is `unmeasured` with the reason, never `clean` (L1, L98, L557).
  * A Mac may not WRITE every report it is asked for (claude-config#3576, measured on macOS 26.6.2
    on 2026-11-24: in each window of about 60 seconds the kernel did not write 8 of the reports for
    programs not signed by Apple, counted across every profile and process. In 17 windows before
    a restart of the Mac they were the first 8; in the windows measured after it, the first 5 and
    then 3 more about 8 seconds on. Programs signed by Apple were never withheld; refusals still
    held). So a serve that connects out a few times a minute can go wholly unreported. The monitor cannot
    see a report that was never written, so it asks for reports of its own and counts them:
      a. the BEAT PROGRAM, an ad hoc signed copy of /bin/bash made in the receipt folder (cp, then
        codesign, no compiler) and checked to be ad hoc signed, since only a program not signed by
        Apple is withheld. It makes one test connection (the canary's kind: a UDP connect that
        sends no packet, to 198.51.100.1, under a tag of its own, on a port that names it) before
        the first canary, one about every second for the whole run, and one after serve is gone.
        Every one is recorded when made and marked when its report arrives.
      b. every canary fired counts too, where main waited for one to be seen and forgot the rest.
    Any test connection or canary never reported makes the run `unmeasured`, never `clean`: this
    Mac did not report every connection it was asked to, so finding nothing proves nothing. A
    connection that WAS seen outside the allowed hosts still reads `not-clean`. A beat program
    that cannot be made or run is `unmeasured` too, with the reason, and so is one that ended
    badly: its exit status is read when it stops, and a program that had ended by itself before
    the run was over, that exited non zero or that had to be killed is the reason. The rule rests
    on no count, no order and no window length: one missing report is enough.
  * So that a report missed because the stream had not attached yet is never read as a withheld
    one (1 of 27 starts lost its first canary that way), the stream is first shown attached by an
    ATTACH canary: /bin/bash itself, signed by Apple, fired until one is reported. Unseen attach
    canaries are counted in the receipt and prove nothing either way.
  What this does not catch, stated: a window whose withheld reports all fall on connections by
  serve or the drive helper and none on a test connection, which needs them to arrive between two
  test connections a second apart. And on a Mac that withholds, a run can still read clean when
  it starts and ends in the part of a window after its withheld reports are spent (a second run
  within the minute did, 6 of 6); every test connection was reported in that case, one a second
  for the whole run.

Options measured and rejected: `nettop` and `lsof -i` sampling miss a connection that opens and
closes between samples (nettop, one second apart, missed a whole TCP connection to 1.0.0.1:80 by
a child process), and a pid list misses a child in another process group; a proxy given through
HTTP(S)_PROXY is ignored by Node's fetch (node 22 reached 1.1.1.1 directly with both set to a dead
port) and by any raw socket; a sandbox profile cannot name a host other than `*` or `localhost`,
so it cannot enforce an allow list itself; and packet capture needs root (/dev/bpf* is root only).

Env, for tests: VERIFICATION_EGRESS_SANDBOX (default /usr/bin/sandbox-exec) and
VERIFICATION_EGRESS_LOG (default /usr/bin/log), the two tools a monitor cannot start without, and
VERIFICATION_EGRESS_CODESIGN (default /usr/bin/codesign), which signs the beat program.
"""

import ipaddress
import json
import os
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True  # a module beside this one is carried by the sync: leave no cache (#2919)
import verification as v  # noqa: E402

SANDBOX_EXEC = "/usr/bin/sandbox-exec"
LOG = "/usr/bin/log"
LSOF = "/usr/sbin/lsof"
MONITOR = "sandbox-exec reports read with log stream, named with lsof"
CANARY_RETRY_S = 1.0  # how long one canary is waited for before another is fired: never a fixed wait
STREAM_STOP_S = 10
CANARY_RUN_MAX_S = 30  # one canary process, which a loaded Mac can take seconds to start
BASH = "/bin/bash"  # signed by Apple: the attach canary runs it as it is, the beat program is a copy signed ad hoc
CODESIGN = "/usr/bin/codesign"
CODESIGN_MAX_S = 30
ATTACH_RETRY_S = 0.25  # how long one attach canary is waited for before another is fired
ATTACH = "{ :; } 3<>/dev/udp/198.51.100.1/9"  # bash connects a UDP socket, which sends nothing, and closes it
BEAT_EVERY_S = 1.0  # the heartbeat: one test connection about this often for the whole run
BEAT_RUN_MAX_S = 10  # how long the beat program may take to answer for one test connection
BEAT_STOP_S = 5  # how long the beat program may take to end once its input is closed
BEAT_EXIT_S = 1.0  # how long a beat program whose pipe has closed is waited for, to say how it ended
SETTLE_S = 5.0  # how long a report still outstanding at the end of a run is waited for
BEAT_PORT = 20000  # test connection n goes to port BEAT_PORT + n, so every report names its connection
BEAT_PORTS = 40000  # and the ports go round again after this many
UNREPORTED_KEPT = 20  # how many unreported test connections a receipt lists; its counts are always whole
# The beat program's whole job: told a port on its input, connect a UDP socket to it (no packet is
# sent), close it, and answer with the port and whether the connect worked. It ends when its
# input closes, so a supervisor that is killed leaves no beat program behind.
BEAT_LOOP = 'while read -r n; do { :; } 3<>"/dev/udp/198.51.100.1/$n"; echo "$n $?"; done'
BEAT_FINISH_S = 2 * BEAT_RUN_MAX_S + 1 + SETTLE_S + BEAT_STOP_S


def finish_budget_s(egress_s):
    """The longest Monitor.finish can take: the heartbeat's last test connection and one more, canaries
    until egress_s, the last one started just before it and running its whole limit, the wait for
    reports still outstanding, then stopping the beat program and the stream and joining its reader
    (which may be in the middle of one lsof). Whoever waits for a supervisor's stop adds this (the
    #1571 review)."""
    return egress_s + CANARY_RUN_MAX_S + 3 * STREAM_STOP_S + BEAT_FINISH_S
CANARY = ("import os, socket\n"
          "s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n"
          "s.connect(('198.51.100.1', 9))\n"
          "s.close()\n"
          "print(os.getpid())\n")
# "Sandbox: node(123) allow network-outbound remote:*:443\n<tag>", or the same line prefixed with
# "N duplicate reports for " when the kernel collapsed repeats of it.
REPORT = re.compile(r"^(?:(\d+) duplicate reports? for )?Sandbox: (.*)\((\d+)\) allow network-outbound"
                    r" remote:\S*?:(\d+)\n(\S+)\s*\Z", re.S)


class Unavailable(Exception):
    """The monitor cannot measure this run; the message is the receipt's reason."""


def profile_text(tag):
    return ("(version 1)\n"
            "(allow default)\n"
            "(allow network-outbound (remote ip \"*:*\") (with report) (with message \"%s\"))\n"
            "(allow network-outbound (remote ip \"localhost:*\"))\n" % tag)


def beat_program_path(rdir):
    return os.path.join(rdir, "egress-beat")


def exit_words(status):
    """A process's exit status in words: `exit 3`, or `killed by signal 9`."""
    return "exit %d" % status if status >= 0 else "killed by signal %d" % -status


def remove_beat_program(rdir):
    """Remove a run's beat program from its receipt folder. Returns why it could not, or None when it
    is gone (or was never made). Also called for a run whose supervisor was killed (run_session.py)."""
    try:
        os.unlink(beat_program_path(rdir))
    except FileNotFoundError:
        return None
    except OSError as e:
        return "the beat program %s could not be removed: %s" % (beat_program_path(rdir), e)
    return None


def remote_addresses(lsof_output, port):
    """The non-loopback remote addresses on `port` in `lsof -F n` output."""
    found = set()
    for line in lsof_output.splitlines():
        if not line.startswith("n") or "->" not in line:
            continue
        remote = line.split("->", 1)[1].strip()
        if remote.startswith("["):
            host, _, rport = remote[1:].partition("]:")
        else:
            host, _, rport = remote.rpartition(":")
        if rport != str(port):
            continue
        host = host.split("%", 1)[0]
        try:
            ip = ipaddress.ip_address(host)
        except ValueError:
            found.add(host)
            continue
        if not ip.is_loopback:
            found.add(str(ip))
    return found


def resolve(hosts):
    """Map each address an allowed host resolves to back to that host; and the hosts that did not."""
    by_ip, unresolved = {}, []
    for host in hosts:
        if host in v.EGRESS_LOCAL_HOSTS:
            continue
        try:
            by_ip[str(ipaddress.ip_address(host))] = host
            continue
        except ValueError:
            pass
        try:
            for info in socket.getaddrinfo(host, None):
                by_ip[str(ipaddress.ip_address(info[4][0].split("%", 1)[0]))] = host
        except OSError as e:
            unresolved.append("%s (%s)" % (host, e))
    return by_ip, unresolved


class Monitor:
    def __init__(self, rdir, receipt_id, allow, egress_s):
        self.rdir = rdir
        self.tag = "vg-egress-" + receipt_id
        # Every canary runs under a profile of its own whose tag carries its own sequence number, so a
        # canary is known by that TAG and never by its pid: a canary exits at once, and macOS may hand
        # its pid to serve, to the drive helper or to the next canary. Neither a real connection nor an
        # earlier canary's report can ever be taken for the canary being waited on.
        self.canary_tag = self.tag + "-canary"
        self.canary_profile = os.path.join(rdir, "egress-canary.sb")
        self.canaries_fired = 0
        self.canary_at = {}  # each canary's tag: when it was fired, on the monotonic clock
        # The attach canary and the beat program (claude-config#3576), each under a tag of its own.
        self.attach_tag = self.tag + "-attach"
        self.attach_profile = os.path.join(rdir, "egress-attach.sb")
        self.attach_fired = 0
        self.attach_seen = set()
        self.beat_tag = self.tag + "-beat"
        self.beat_profile = os.path.join(rdir, "egress-beat.sb")
        self.beat_program = beat_program_path(rdir)
        self.beat_said = os.path.join(rdir, "egress-beat.err")
        self.codesign = os.environ.get("VERIFICATION_EGRESS_CODESIGN") or CODESIGN
        self.beat_proc = None
        self.beat_err = None
        self.beat_thread = None
        self.beat_stop = threading.Event()
        self.beat_lock = threading.Lock()  # one test connection at a time
        self.beats = []  # every test connection made: {beat, port, at, t, seen}
        self.beat_failure = None  # why the beat program could not be made or run, or how it ended badly
        self.allow = list(allow)
        self.egress_s = egress_s
        self.profile = os.path.join(rdir, "egress.sb")
        self.events_path = os.path.join(rdir, "egress.jsonl")
        self.sandbox = os.environ.get("VERIFICATION_EGRESS_SANDBOX") or SANDBOX_EXEC
        self.log = os.environ.get("VERIFICATION_EGRESS_LOG") or LOG
        self.proc = None
        self.stream_exit = None  # how the report stream ended, kept by stop_stream
        self.thread = None
        self.cond = threading.Condition()
        self.reports = []
        self.canaries_seen = set()
        self.chatter = []
        self.stream_ended = False
        self.failure = None
        self.started_at = None
        self.allowed_ips, self.unresolved = {}, []

    # -- starting --------------------------------------------------------------------------------

    def start(self):
        """Start measuring. Returns None when the monitor is live, else why it cannot measure."""
        try:
            self._start()
        except Unavailable as e:
            self.failure = str(e)
        except Exception as e:  # any other fault is a reason too, never a crashed supervisor
            self.failure = "the egress monitor failed to start: %s: %s" % (type(e).__name__, e)
        if self.failure:
            self._stop_beats()
            self.stop_stream()
        return self.failure

    def _start(self):
        if sys.platform != "darwin":
            raise Unavailable("this machine runs %s, and the egress monitor is macOS's sandbox-exec, so nothing"
                              " here can see what the served app connects to" % sys.platform)
        if not os.access(self.sandbox, os.X_OK):
            raise Unavailable("%s is not on this machine, so the served app cannot run under the reporting"
                              " sandbox" % self.sandbox)
        with open(self.profile, "w", errors="replace") as f:
            f.write(profile_text(self.tag))
        self.allowed_ips, self.unresolved = resolve(self.allow)
        predicate = 'sender == "Sandbox" AND eventMessage CONTAINS "%s"' % self.tag
        try:
            proc = subprocess.Popen([self.log, "stream", "--style", "ndjson", "--predicate", predicate],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as e:
            raise Unavailable("the report stream %s could not start: %s" % (self.log, e))
        self.proc = proc
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()
        if not self._attached():
            raise Unavailable("the report stream showed no report at all within %ss, not even of the attach canary"
                              " the monitor fires first, so it cannot be shown to see this run's connections%s"
                              % (self.egress_s, self._stream_state()))
        # The first test connection goes BEFORE the first canary: on a Mac that withholds reports the
        # canary (whatever python runs this) could take every withheld one itself and leave none to see.
        self._start_beats()
        if not self._canary_seen():
            raise Unavailable("the report stream showed no report of the start canary within %ss, so it cannot be"
                              " shown to see this run's connections%s" % (self.egress_s, self._stream_state()))
        exited = proc.poll()
        if exited is not None:  # it reported the canary and then died: nothing would see serve
            raise Unavailable("the report stream exited with %s right after the start canary%s"
                              % (exited, self._stream_state()))
        self.started_at = v.utc_now()
        self._event({"event": "started", "at": self.started_at})
        self._start_heartbeat()

    # -- reading ---------------------------------------------------------------------------------

    def _read(self):
        try:
            for raw in self.proc.stdout:
                line = raw.decode(errors="replace").strip()
                try:
                    ev = json.loads(line)
                except ValueError:
                    self.chatter = (self.chatter + [line[:200]])[-5:]
                    continue
                m = REPORT.match(ev.get("eventMessage") or "") if isinstance(ev, dict) else None
                tag = m.group(5) if m else None
                if tag == self.beat_tag:
                    self._beat_reported(int(m.group(4)), int(m.group(1) or 1))
                    continue
                if tag is not None and tag.startswith(self.attach_tag + "-"):
                    with self.cond:
                        self.attach_seen.add(tag)
                        self.cond.notify_all()
                    self._event({"event": "attach", "at": v.utc_now(), "attach": tag})
                    continue
                if tag is not None and tag.startswith(self.canary_tag + "-"):
                    with self.cond:
                        self.canaries_seen.add(tag)
                        self.cond.notify_all()
                    self._event({"event": "canary", "at": v.utc_now(), "canary": tag})
                    continue
                if tag != self.tag:
                    continue
                pid, port = int(m.group(3)), int(m.group(4))
                rec = {"event": "report", "at": v.utc_now(), "pid": pid, "process": m.group(2), "port": port,
                       "count": int(m.group(1) or 1)}
                rec["addresses"], why = self._name(pid, port)
                if why:
                    rec["name_error"] = why
                with self.cond:
                    self.reports.append(rec)
                self._event(rec)
        finally:
            with self.cond:
                self.stream_ended = True
                self.cond.notify_all()

    def _name(self, pid, port):
        """The remote addresses `pid` holds open on `port`, read now, while the connection may be open."""
        try:
            r = subprocess.run([LSOF, "-a", "-n", "-P", "-p", str(pid), "-i", "-F", "n"],
                               capture_output=True, text=True, timeout=10, errors="replace")
        except (OSError, subprocess.TimeoutExpired) as e:
            return [], "lsof could not read the sockets of pid %d: %s" % (pid, e)
        # lsof exits 1 when the process holds no matching socket any more, which is an answer (the
        # connection closed first); anything else, or 1 with an error said, is a failure to read.
        if r.returncode not in (0, 1) or (r.returncode == 1 and r.stderr.strip()):
            return [], "lsof exited %d reading pid %d: %s" % (r.returncode, pid, r.stderr.strip()[-200:])
        return sorted(remote_addresses(r.stdout, port)), None

    def _event(self, obj):
        fd = os.open(self.events_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (json.dumps(obj) + "\n").encode("ascii", "strict"))
        finally:
            os.close(fd)

    # -- the canary ------------------------------------------------------------------------------

    def _fire_canary(self):
        """Run one canary under a profile tagged for it alone, and return that tag."""
        self.canaries_fired += 1
        tag = "%s-%d" % (self.canary_tag, self.canaries_fired)
        with self.cond:
            self.canary_at[tag] = time.monotonic()
        self._event({"event": "canary-fired", "at": v.utc_now(), "canary": tag})
        with open(self.canary_profile, "w", errors="replace") as f:
            f.write(profile_text(tag))
        try:
            r = subprocess.run([self.sandbox, "-f", self.canary_profile, sys.executable, "-c", CANARY],
                               capture_output=True, text=True, timeout=CANARY_RUN_MAX_S, errors="replace")
        except (OSError, subprocess.TimeoutExpired) as e:
            raise Unavailable("the canary could not run under %s: %s" % (self.sandbox, e))
        out = r.stdout.strip()
        if r.returncode != 0 or not out.isdigit():
            raise Unavailable("the canary could not run under %s (exit %s): %s"
                              % (self.sandbox, r.returncode, (r.stderr or r.stdout).strip()[-300:]))
        return tag

    def _canary_seen(self):
        """Fire canaries until one's report arrives, the stream ends, or egress_s passes."""
        deadline = time.monotonic() + self.egress_s
        while time.monotonic() < deadline:
            tag = self._fire_canary()
            with self.cond:
                self.cond.wait_for(lambda: tag in self.canaries_seen or self.stream_ended,
                                   timeout=max(0.0, min(CANARY_RETRY_S, deadline - time.monotonic())))
                if tag in self.canaries_seen:
                    return True
                if self.stream_ended:
                    return False
        return False

    def _stream_state(self):
        if self.proc is not None and self.proc.poll() is not None:
            said = "; ".join(self.chatter) or "nothing"
            return " (the stream exited with %s and said: %s)" % (self.proc.returncode, said)
        return ""

    # -- the attach canary (claude-config#3576) ---------------------------------------------------

    def _fire_attach(self):
        """Run one attach canary, /bin/bash as Apple signed it, under a profile tagged for it alone."""
        self.attach_fired += 1
        tag = "%s-%d" % (self.attach_tag, self.attach_fired)
        with open(self.attach_profile, "w", errors="replace") as f:
            f.write(profile_text(tag))
        try:
            r = subprocess.run([self.sandbox, "-f", self.attach_profile, BASH, "-c", ATTACH],
                               capture_output=True, text=True, timeout=CANARY_RUN_MAX_S, errors="replace")
        except (OSError, subprocess.TimeoutExpired) as e:
            raise Unavailable("the attach canary could not run under %s: %s" % (self.sandbox, e))
        if r.returncode != 0:
            raise Unavailable("the attach canary could not run under %s (exit %s): %s"
                              % (self.sandbox, r.returncode, (r.stderr or r.stdout).strip()[-300:]))
        return tag

    def _attached(self):
        """Fire attach canaries until a report of one arrives, the stream ends, or egress_s passes."""
        deadline = time.monotonic() + self.egress_s
        while time.monotonic() < deadline:
            self._fire_attach()
            with self.cond:
                self.cond.wait_for(lambda: self.attach_seen or self.stream_ended,
                                   timeout=max(0.0, min(ATTACH_RETRY_S, deadline - time.monotonic())))
                if self.attach_seen:
                    return True
                if self.stream_ended:
                    return False
        return False

    # -- the beat program and its test connections (claude-config#3576) ---------------------------

    def _codesign(self, *args):
        try:
            return subprocess.run([self.codesign] + list(args), capture_output=True, text=True,
                                  timeout=CODESIGN_MAX_S, errors="replace")
        except (OSError, subprocess.TimeoutExpired) as e:
            raise Unavailable("%s could not run, so no program not signed by Apple could be made to test this"
                              " Mac's reports: %s" % (self.codesign, e))

    def _make_beat_program(self):
        """Copy /bin/bash into the receipt folder, sign the copy ad hoc and check that it is: only a
        program NOT signed by Apple is withheld, so a beat from any other would prove nothing."""
        try:
            shutil.copyfile(BASH, self.beat_program)
            os.chmod(self.beat_program, 0o700)
        except OSError as e:
            raise Unavailable("%s could not be copied to make the beat program: %s" % (BASH, e))
        signed = self._codesign("--force", "--sign", "-", self.beat_program)
        if signed.returncode != 0:
            raise Unavailable("the copy of %s could not be signed ad hoc (%s exit %s: %s)"
                              % (BASH, self.codesign, signed.returncode,
                                 (signed.stderr or signed.stdout).strip()[-300:]))
        shown = self._codesign("--display", "--verbose=2", self.beat_program)
        said = (shown.stderr or "") + (shown.stdout or "")
        if shown.returncode != 0 or "Signature=adhoc" not in said:
            raise Unavailable("the copy of %s is not ad hoc signed, so its reports would not show whether this Mac"
                              " withholds any (%s exit %s said: %s)"
                              % (BASH, self.codesign, shown.returncode, " ".join(said.split())[-300:]))

    def _beat_argv(self):
        return [self.sandbox, "-f", self.beat_profile, self.beat_program, "-c", BEAT_LOOP]

    def _start_beats(self):
        """Make the beat program, start it and have it make the first test connection. Never raises:
        a failure is the run's reason for reading unmeasured, and serve still runs under the
        reporting sandbox, so a connection that IS seen still reads not-clean."""
        try:
            self._make_beat_program()
            with open(self.beat_profile, "w", errors="replace") as f:
                f.write(profile_text(self.beat_tag))
            self.beat_err = open(self.beat_said, "ab")
            proc = subprocess.Popen(self._beat_argv(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=self.beat_err, start_new_session=True, bufsize=0)
            self.beat_proc = proc
            self._beat()
            exited = proc.poll()
            if exited is not None:  # it answered once and left: nothing would make the run's other test connections
                raise Unavailable("the beat program ended by itself (%s) right after its first test connection%s"
                                  % (exit_words(exited), self._beat_stderr()))
        except Unavailable as e:
            self._beats_failed(str(e))
        except Exception as e:  # any other fault is a reason too, never a crashed supervisor
            self._beats_failed("the beat program could not be started: %s: %s" % (type(e).__name__, e))

    def _beats_failed(self, why):
        if self.beat_failure is None:
            self.beat_failure = why
            try:
                self._event({"event": "beat-failed", "at": v.utc_now(), "why": why})
            except OSError:
                pass
        self._end_beat_program()

    def _beat(self):
        """Have the beat program make one test connection. It is recorded as made BEFORE the program
        is told, so its report can never arrive ahead of the record. Raises Unavailable, with nothing
        left recorded, when the connection was not made."""
        with self.beat_lock:
            proc = self.beat_proc
            if proc is None:
                raise Unavailable("the beat program is not running")
            with self.cond:
                n = len(self.beats) + 1
                rec = {"beat": n, "port": BEAT_PORT + 1 + (n - 1) % BEAT_PORTS, "at": v.utc_now(),
                       "t": time.monotonic(), "seen": False}
                self.beats.append(rec)
                self.cond.notify_all()
            try:
                os.write(proc.stdin.fileno(), b"%d\n" % rec["port"])
                answer = self._beat_answer(proc)
                if answer != "%d 0" % rec["port"]:
                    raise Unavailable("the beat program could not make its test connection (it answered %r%s)"
                                      % (answer, self._beat_stderr()))
            except (OSError, ValueError) as e:
                self._unbeat(rec)
                ended = self._beat_exit(proc, BEAT_EXIT_S)
                raise Unavailable("the beat program could not be told to make a test connection: %s%s%s"
                                  % (e, " (it had ended, %s)" % ended if ended else "", self._beat_stderr()))
            except Unavailable:
                self._unbeat(rec)
                raise
            self._event({"event": "beat-fired", "at": rec["at"], "beat": n, "port": rec["port"]})

    def _unbeat(self, rec):
        with self.cond:
            self.beats.remove(rec)

    def _beat_answer(self, proc):
        """The beat program's one line of answer, waited for on its pipe and never past BEAT_RUN_MAX_S."""
        fd, buf, deadline = proc.stdout.fileno(), b"", time.monotonic() + BEAT_RUN_MAX_S
        while b"\n" not in buf:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([fd], [], [], left)[0]:
                raise Unavailable("the beat program gave no answer within %ss%s" % (BEAT_RUN_MAX_S, self._beat_stderr()))
            chunk = os.read(fd, 64)
            if not chunk:
                # Its output closed. The status is waited for, briefly and never past this answer's
                # limit, so the reason says how it ended and not that it had not quite ended yet.
                ended = self._beat_exit(proc, min(BEAT_EXIT_S, max(0.0, deadline - time.monotonic())))
                raise Unavailable("the beat program %s%s" % ("ended (%s)" % ended if ended else
                                                             "closed its output without ending", self._beat_stderr()))
            buf += chunk
        return buf.split(b"\n", 1)[0].decode(errors="replace").strip()

    def _beat_exit(self, proc, within):
        """How the beat program ended, in words, or None when it is still running after `within` s."""
        try:
            return exit_words(proc.wait(timeout=within))
        except subprocess.TimeoutExpired:
            return None

    def _beat_stderr(self):
        try:
            with open(self.beat_said, errors="replace") as f:
                said = " ".join(f.read().split())[-300:]
        except OSError:
            said = ""
        return ", and said: " + said if said else ""

    def _beat_reported(self, port, count):
        """Mark the oldest unreported test connection on `port` as reported, `count` of them when the
        kernel collapsed repeats. A report for a connection this monitor never made marks nothing."""
        hit = []
        with self.cond:
            for b in self.beats:
                if len(hit) == count:
                    break
                if b["port"] == port and not b["seen"]:
                    b["seen"] = True
                    hit.append(b["beat"])
            self.cond.notify_all()
        for n in hit:
            self._event({"event": "beat", "at": v.utc_now(), "beat": n, "port": port})
        if not hit:
            self._event({"event": "beat-unknown", "at": v.utc_now(), "port": port})

    def _start_heartbeat(self):
        if self.beat_failure or self.beat_proc is None:
            return
        self.beat_stop.clear()
        self.beat_thread = threading.Thread(target=self._heartbeat, daemon=True)
        self.beat_thread.start()

    def _heartbeat(self):
        """One test connection about every BEAT_EVERY_S until stopped. The first that cannot be made
        ends it with the reason: a heartbeat that died is never a heartbeat that saw nothing wrong."""
        while not self.beat_stop.wait(BEAT_EVERY_S):
            try:
                self._beat()
            except Unavailable as e:
                self._beats_failed(str(e))
                return
            except Exception as e:
                self._beats_failed("the heartbeat failed: %s: %s" % (type(e).__name__, e))
                return

    def _stop_heartbeat(self):
        self.beat_stop.set()
        t = self.beat_thread
        if t is not None and t is not threading.current_thread():
            t.join(timeout=BEAT_RUN_MAX_S + 1)

    def _last_beat(self):
        """Stop the heartbeat and make one more test connection, after serve is gone."""
        self._stop_heartbeat()
        if self.beat_failure:
            return
        try:
            self._beat()
        except Unavailable as e:
            self._beats_failed(str(e))

    def _settle(self):
        """Wait for every report still outstanding, on the condition, and for none of them longer than
        SETTLE_S after it was asked for: a report that is merely late must not read as withheld."""
        with self.cond:
            while not self.stream_ended:
                waiting = [b["t"] for b in self.beats if not b["seen"]]
                waiting += [t for tag, t in self.canary_at.items() if tag not in self.canaries_seen]
                if not waiting:
                    return
                left = max(waiting) + SETTLE_S - time.monotonic()
                if left <= 0:
                    return
                self.cond.wait(timeout=left)

    def _end_beat_program(self):
        """End the beat program by closing its input, read how it ended, and remove its copy. Never
        raises. A program that had ended before it was told to, that exited non zero, or that had to
        be killed, is a reason the run reads unmeasured (see _beat_ended)."""
        proc, self.beat_proc = self.beat_proc, None
        if proc is not None:
            early = proc.poll()  # not None: it ended by itself, before its input was closed
            try:
                proc.stdin.close()
            except OSError:
                pass
            killed = False
            try:
                status = proc.wait(timeout=BEAT_STOP_S)
            except subprocess.TimeoutExpired:
                killed = True
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                status = proc.wait()
            try:
                proc.stdout.close()
            except OSError:
                pass
            self._beat_ended(early, status, killed)
        err, self.beat_err = self.beat_err, None
        if err is not None:
            try:
                err.close()
                if os.path.getsize(self.beat_said) == 0:  # it said nothing: leave no empty file in every receipt
                    os.unlink(self.beat_said)
            except OSError:
                pass
        left = remove_beat_program(self.rdir)
        if left:
            try:
                self._event({"event": "beat-program-left", "at": v.utc_now(), "why": left})
            except OSError:
                pass

    def _beat_ended(self, early, status, killed):
        """Record how the beat program ended, and make a bad ending the run's reason for reading
        unmeasured when nothing has failed already. Never raises.

        The exit status comes from the system, not from the program's own answers, so it is the one
        word about the program that the program cannot get wrong (L345). The program is written to
        run until its input closes and then exit 0. One that ended by itself made no test connection
        for the rest of the run, and after the last one nothing else would ever say so; one that
        exited non zero or had to be killed did not do what it was written to do, so its answers are
        not vouched for. The verdict rests on beat_failure, never on the log line being written."""
        why = None
        if early is not None:
            why = "the beat program ended by itself (%s) before the run was over" % exit_words(early)
        elif killed:
            why = "the beat program did not end within %ss of its input closing and was killed" % BEAT_STOP_S
        elif status != 0:
            why = "the beat program ended badly (%s) when its input closed" % exit_words(status)
        if why:
            why += self._beat_stderr()
        failed_now = why is not None and self.beat_failure is None
        if failed_now:
            self.beat_failure = why
        try:
            self._event({"event": "beat-ended", "at": v.utc_now(), "exit": status, "early": early is not None,
                         "killed": killed})
            if failed_now:
                self._event({"event": "beat-failed", "at": v.utc_now(), "why": why})
        except OSError:
            pass

    def _stop_beats(self):
        """Stop the heartbeat and the beat program, and remove the program's copy. Never raises."""
        self._stop_heartbeat()
        self._end_beat_program()

    # -- stopping --------------------------------------------------------------------------------

    def stop_stream(self):
        """Stop the report stream, and read and keep how it ended (claude-config#3663): its status,
        whether it had ended by itself before it was stopped, and whether it had to be killed. The
        first stop's reading is kept; finish() stops it again in its finally."""
        if self.proc is None:
            return
        early = self.proc.poll()  # not None: it had ended by itself, or an earlier stop ended it
        status, killed = early, False
        if early is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                status = self.proc.wait(timeout=STREAM_STOP_S)
            except subprocess.TimeoutExpired:
                killed = True
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                status = self.proc.wait()
        if self.stream_exit is None:
            self.stream_exit = {"exit": status, "early": early is not None, "killed": killed}
            try:
                self._event(dict({"event": "stream-ended", "at": v.utc_now()}, **self.stream_exit))
            except OSError:
                pass
        if self.thread is not None:
            self.thread.join(timeout=STREAM_STOP_S)

    def finish(self):
        """Fire the end canary, stop the stream and return the receipt's egress field. Never raises,
        and always stops the stream."""
        try:
            if self.failure:
                return self.field("unmeasured", self.failure)
            if self.started_at is None:
                return self.field("unmeasured", "the run stopped before the egress monitor had proved it could see")
            self._last_beat()
            try:
                ended = self._canary_seen()
            except Unavailable as e:
                return self.field("unmeasured", "the end of the run could not be proved: %s" % e)
            if not ended:
                return self.field("unmeasured", "the report stream showed no report of the end canary within %ss,"
                                  " so connections made late in the run may be missing%s"
                                  % (self.egress_s, self._stream_state()))
            self._settle()
            self._stop_beats()
            self.stop_stream()
            return self.judge()
        except Exception as e:
            return self.field("unmeasured", "the egress monitor failed while finishing: %s: %s" % (type(e).__name__, e))
        finally:
            self._stop_beats()
            self.stop_stream()

    # -- the verdict -----------------------------------------------------------------------------

    def field(self, verdict, why, destinations=(), unnamed=()):
        with self.cond:
            beats = [dict(b) for b in self.beats]
            canaries_seen, attach_seen = len(self.canaries_seen), len(self.attach_seen)
        unreported = [b for b in beats if not b["seen"]]
        return {"verdict": verdict, "why": why, "monitor": MONITOR, "allowed_hosts": self.allow,
                "allowed_unresolved": self.unresolved, "measured_from": self.started_at,
                "measured_to": v.utc_now() if verdict != "unmeasured" else None,
                "destinations": list(destinations), "unnamed": list(unnamed),
                # What the monitor asked this Mac to report and what came back (claude-config#3576),
                # so a run can be judged again later from its receipt alone.
                "attach": {"fired": self.attach_fired, "seen": attach_seen},
                "canaries": {"fired": self.canaries_fired, "seen": canaries_seen},
                "beats": {"fired": len(beats), "reported": len(beats) - len(unreported),
                          "unreported": [{"beat": b["beat"], "at": b["at"]} for b in unreported[:UNREPORTED_KEPT]],
                          "failure": self.beat_failure}}

    def withheld(self):
        """Why finding nothing would prove nothing, in words, or None when every report this monitor
        asked for arrived. One missing report is enough: the rule rests on no count and no timing."""
        with self.cond:
            fired = len(self.beats)
            unreported = sum(1 for b in self.beats if not b["seen"])
            unseen = sum(1 for i in range(1, self.canaries_fired + 1)
                         if "%s-%d" % (self.canary_tag, i) not in self.canaries_seen)
        said = []
        missing = []
        if unreported:
            missing.append("%d of the %d test connections the monitor made from a program not signed by Apple"
                           % (unreported, fired))
        if unseen:
            missing.append("%d of the %d canaries" % (unseen, self.canaries_fired))
        if missing:
            said.append("this Mac did not report every connection it was asked to report during the run (%s"
                        " never reported)" % " and ".join(missing))
        if self.beat_failure:
            said.append("the monitor could not check that this Mac reports every connection: " + self.beat_failure)
        elif not fired:
            said.append("the monitor made no test connection, so nothing shows that this Mac reports every"
                        " connection")
        return "; and ".join(said) or None

    def judge(self):
        """The verdict over the reports that arrived, and never clean when one the monitor asked for
        did not. A connection that was seen outside the allowed hosts is still not-clean: what was
        seen is never downgraded by what was not."""
        out = self._judge_reports()
        gap = self.withheld()
        if gap is None:
            return out
        if out["verdict"] == "not-clean":
            out["why"] += ". And there may have been more: " + gap
            return out
        return self.field("unmeasured", gap + ". So a reading that found nothing outside the allowed hosts cannot be"
                          " trusted: a connection by serve or the drive helper could have gone unreported the"
                          " same way", out["destinations"], out["unnamed"])

    def _judge_reports(self):
        more, unresolved = resolve(self.allow)
        allowed_ips = dict(self.allowed_ips, **more)
        self.unresolved = sorted(set(self.unresolved) | set(unresolved))
        dests, unnamed = {}, {}
        with self.cond:
            reports = list(self.reports)
        for r in reports:
            if r.get("addresses"):
                for addr in r["addresses"]:
                    d = dests.setdefault((addr, r["port"]), {"address": addr, "port": r["port"], "reports": 0,
                                                             "processes": [], "allowed": addr in allowed_ips,
                                                             "allowed_as": allowed_ips.get(addr)})
                    d["reports"] += r["count"]
                    if r["process"] not in d["processes"]:
                        d["processes"].append(r["process"])
            else:
                # Kept apart by why it went unnamed: null when lsof read the process and the connection
                # had already closed, else why lsof could not read it, so a failure to read is never
                # reported as a connection that closed (L11, #1633).
                err = r.get("name_error")
                u = unnamed.setdefault((r["process"], r["port"], err), {"process": r["process"], "port": r["port"],
                                                                        "reports": 0, "pids": [], "name_error": err})
                u["reports"] += r["count"]
                if r["pid"] not in u["pids"]:
                    u["pids"].append(r["pid"])
        dests = sorted(dests.values(), key=lambda d: (d["address"], d["port"]))
        unnamed = sorted(unnamed.values(), key=lambda u: (u["process"], u["port"], u["name_error"] or ""))
        outside = [d for d in dests if not d["allowed"]]
        if outside or unnamed:
            parts = []
            if outside:
                parts.append("serve or the drive helper reached hosts outside egress.allow: " + "; ".join(
                    "%s port %d (%s, %s)" % (d["address"], d["port"], ", ".join(d["processes"]), plural(d["reports"]))
                    for d in outside))
            if unnamed:
                parts.append("connections outside this machine whose address was never read: " + "; ".join(
                    "%s port %d (%s): %s" % (u["process"], u["port"], plural(u["reports"]),
                                             "lsof could not read it: " + u["name_error"] if u["name_error"]
                                             else "closed before it could be read")
                    for u in unnamed))
            return self.field("not-clean", ". ".join(parts), dests, unnamed)
        if dests:
            why = "every connection outside this machine went to an allowed host: " + "; ".join(
                "%s port %d (%s)" % (d["address"], d["port"], d["allowed_as"]) for d in dests)
        else:
            why = ("the sandbox reported no connection from serve or the drive helper to any host other than %s"
                   " or %s for the whole run" % (", ".join(v.EGRESS_LOCAL_HOSTS[:-1]), v.EGRESS_LOCAL_HOSTS[-1]))
        return self.field("clean", why, dests, unnamed)


def plural(n):
    return "%d report%s" % (n, "" if n == 1 else "s")
