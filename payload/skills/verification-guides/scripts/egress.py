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
    session, so a child that daemonizes is still seen. Serve's profile blocks nothing: the app
    behaves as it would anywhere else.
  * ONE kind of connection is refused, in the profile of drive calls only (claude-config#3319,
    Dan's decision of 2026-11-24): a UDP connect to port 443 on any address but this machine's
    loopback, by a process whose executable file is named chrome-headless-shell, the helper
    browser the drive helpers start. Before its first address lookup that browser asks whether a
    fixed public IPv6 address could be reached, with a UDP connect that sends no packet and is
    closed before lsof can read it, so every run with a browser was not clean. Refused, the
    attempt never leaves, so `clean` still means nothing left this machine for a host outside
    the allowed ones. Each refusal is
    reported by the kernel with a message of its own, written into the record as an event of its
    own (`refused`, never `report`) and counted in the receipt's `refused`, apart from every
    connection that left. Nothing else is refused: the same browser on TCP, or on UDP to any other
    port, is reported as before, and so is every other program and all of serve, an executable of
    the same name included. A page that would use HTTP/3 (which is UDP on port 443) falls back to
    HTTP over TCP, which is reported. A refusal carrying this run's tag that the rule could not
    have produced (another process name, another port) makes the run not clean. The kernel's own
    word decides what a line is, never its message: `allow` under the refusal's message is a
    connection that left and is recorded as a `report`, `deny` under the reporting message is a
    `refused`, each is marked `mismatch`, and either makes the run not clean.
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
  * Each canary is a round of three processes (CANARY_PARTS), because what a compiled profile
    reports cannot be read off its text (see refusal_rule). One runs under serve's profile, as the
    canary always did. One runs under the exact profile of drive calls and tries the refused kind
    of connection as a program that is not the helper browser: it must be let through AND
    reported, or that profile hides or refuses more than the one connection chosen. One runs
    under the refusal rule aimed at itself: it must be refused, and the refusal must reach the
    report stream. A round counts only when all three arrived. Anything less is `unmeasured` and
    says which part was missing. A refusal that cannot be written into the record stops the
    reader, and the run is `unmeasured` with that error.

Options measured and rejected: `nettop` and `lsof -i` sampling miss a connection that opens and
closes between samples (nettop, one second apart, missed a whole TCP connection to 1.0.0.1:80 by
a child process), and a pid list misses a child in another process group; a proxy given through
HTTP(S)_PROXY is ignored by Node's fetch (node 22 reached 1.1.1.1 directly with both set to a dead
port) and by any raw socket; a sandbox profile cannot name a host other than `*` or `localhost`,
so it cannot enforce an allow list itself; and packet capture needs root (/dev/bpf* is root only).

Env, for tests: VERIFICATION_EGRESS_SANDBOX (default /usr/bin/sandbox-exec) and
VERIFICATION_EGRESS_LOG (default /usr/bin/log), the two tools a monitor cannot start without.
"""

import ipaddress
import json
import os
import re
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


def finish_budget_s(egress_s):
    """The longest Monitor.finish can take: canaries until egress_s, the last round started just before
    it and each of its processes running its whole limit, then stopping the stream and joining its
    reader (which may be in the middle of one lsof). Whoever waits for a supervisor's stop adds this
    (the #1571 review)."""
    return egress_s + len(CANARY_PARTS) * CANARY_RUN_MAX_S + 3 * STREAM_STOP_S
# The one refusal (claude-config#3319). The helper browser is known by the file name of its
# executable, which is all a sandbox profile can know a process by here, and the port is the one its
# reachability probe uses.
HELPER_BROWSER = "chrome-headless-shell"
REFUSED_PORT = 443
HELPER_BROWSER_PATH = "/%s$" % HELPER_BROWSER  # a regular expression over the executable's resolved path
ANY_PATH = "^/"  # the refusal canary's own rule: whatever program the canary runs as
REFUSED = "-refused"  # what a refusal's message carries after the tag of the profile that refused it
# One canary process: a UDP connect to the port it is given, which sends no packet, saying whether
# the kernel let it happen.
CANARY = ("import os, socket, sys\n"
          "s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n"
          "try:\n"
          "    s.connect(('198.51.100.1', int(sys.argv[1])))\n"
          "    print('passed')\n"
          "except PermissionError:\n"
          "    print('refused')\n"
          "s.close()\n"
          "print(os.getpid())\n")
# "Sandbox: node(123) allow network-outbound remote:*:443\n<tag>" for a connection that was let
# through and reported, "Sandbox: node(123) deny(1) network-outbound remote:*:443\n<tag>-refused" for
# one that was refused (both measured on macOS 26.6), or either line prefixed with
# "N duplicate reports for " when the kernel collapsed repeats of it.
REPORT = re.compile(r"^(?:(\d+) duplicate reports? for )?Sandbox: (.*)\((\d+)\) (allow|deny\(\d+\)) network-outbound"
                    r" remote:\S*?:(\d+)\n(\S+)\s*\Z", re.S)


class Unavailable(Exception):
    """The monitor cannot measure this run; the message is the receipt's reason."""


def profile_text(tag):
    """Serve's profile: every connection allowed, each one off this machine reported."""
    return ("(version 1)\n"
            "(allow default)\n"
            "(allow network-outbound (remote ip \"*:*\") (with report) (with message \"%s\"))\n"
            "(allow network-outbound (remote ip \"localhost:*\"))\n" % tag)


def refusal_rule(path_regex, tag):
    """Refuse a UDP connect to REFUSED_PORT off this machine by a process whose executable path
    matches, reported under `tag` + REFUSED, and leave the same port on loopback alone. A later rule
    wins in a profile, so these two lines go after profile_text's.

    The second line does more than its words say, measured on macOS 26.6.2 (2026-11-24): with the
    deny as the profile's LAST rule, a program the deny does not name has its UDP connect to this
    port let through with NO report, where every other route is still reported. With the second
    line after it, every route by every other program is reported as under profile_text alone. So
    what a compiled profile reports cannot be read off its text. The whole table of routes is
    pinned by EgressTests in test_run_session.py, and every run proves the one that broke with a
    canary under this exact shape (CANARY_PARTS)."""
    who = '(process-path-regex "%s")' % path_regex
    return ('(deny network-outbound (require-all %s (remote udp "*:%d")) (with message "%s%s"))\n'
            '(allow network-outbound (require-all %s (remote udp "localhost:%d")))\n'
            % (who, REFUSED_PORT, tag, REFUSED, who, REFUSED_PORT))


def drive_profile_text(tag):
    """The profile of drive calls: serve's, and the one refusal, for the helper browser alone."""
    return profile_text(tag) + refusal_rule(HELPER_BROWSER_PATH, tag)


def canary_profile_text(tag):
    """The refusal canary's profile: the same two halves, with the refusal aimed at the canary itself."""
    return profile_text(tag) + refusal_rule(ANY_PATH, tag)


# One round of canaries is three processes, each under a profile of its own shape and tag:
# (name, the profile, what its tag adds to the round's, the port, what the kernel must do, what the
# report stream must then show, in the words of a reason).
#   serve    serve's profile reports a connection off this machine, as it always has.
#   drive    the profile of drive calls, the exact text a drive call runs under but for the tag,
#            neither refuses nor hides a UDP connect to the refused port by a program that is not
#            the helper browser (the canary is Python): it is let through AND reported.
#   refusal  the refusal rule, aimed at the canary itself, refuses, and the refusal reaches the
#            report stream, so what a drive call's profile refuses can reach the record.
CANARY_PARTS = (
    ("serve", profile_text, "", 9, "passed", "its report under serve's profile"),
    ("drive", drive_profile_text, "-drive", REFUSED_PORT, "passed", "its report under the profile of drive calls"),
    ("refusal", canary_profile_text, "-self", REFUSED_PORT, "refused",
     "the record of the connection the sandbox refused it"),
)


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
        self.allow = list(allow)
        self.egress_s = egress_s
        self.profile = os.path.join(rdir, "egress.sb")
        # Drive calls run under a profile of their own, the only one that carries the refusal, so
        # nothing serve starts is ever refused anything, whatever its executable is called.
        self.drive_profile = os.path.join(rdir, "egress-drive.sb")
        self.refused_tag = self.tag + REFUSED
        self.refusals = []
        self.canary_want = []  # the last round of canaries: (what the stream must show, in words; its message)
        self.reader_error = None
        self.events_path = os.path.join(rdir, "egress.jsonl")
        self.sandbox = os.environ.get("VERIFICATION_EGRESS_SANDBOX") or SANDBOX_EXEC
        self.log = os.environ.get("VERIFICATION_EGRESS_LOG") or LOG
        self.proc = None
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
        # Both profiles exist before anything is measured: a drive profile that cannot be written is
        # a monitor that cannot start, never a drive call run under serve's profile instead.
        with open(self.drive_profile, "w", errors="replace") as f:
            f.write(drive_profile_text(self.tag))
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
        if not self._canary_seen():
            raise Unavailable("the report stream showed %s within %ss, so it cannot be shown to see this run's"
                              " connections%s" % (self._canary_gap("start"), self.egress_s, self._stream_state()))
        exited = proc.poll()
        if exited is not None:  # it reported the canary and then died: nothing would see serve
            raise Unavailable("the report stream exited with %s right after the start canary%s"
                              % (exited, self._stream_state()))
        self.started_at = v.utc_now()
        self._event({"event": "started", "at": self.started_at})

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
                if not m:
                    continue
                # The kernel's own word says whether the connection was let through or refused, and
                # that word alone decides what the line is. The message is the one the rule of that
                # kind carries, and a line where the two disagree is nothing either profile is
                # written to produce. It is never dropped for that: what a compiled profile does
                # cannot be read off its text (see refusal_rule), so an `allow` under the refusal's
                # message is a connection that left, and it is counted as one.
                refused, tag = m.group(4) != "allow", m.group(6)
                mismatch = refused != tag.endswith(REFUSED)
                if tag.startswith(self.canary_tag + "-"):
                    # A canary proves a profile only by the line that profile is written to produce,
                    # so the other line under its tag proves nothing: the round stays unfinished and
                    # the run is unmeasured.
                    if not mismatch:
                        with self.cond:
                            self.canaries_seen.add(tag)
                            self.cond.notify_all()
                        self._event({"event": "canary", "at": v.utc_now(), "canary": tag})
                    continue
                if tag not in (self.tag, self.refused_tag):
                    continue
                pid, port = int(m.group(3)), int(m.group(5))
                rec = {"event": "refused" if refused else "report", "at": v.utc_now(), "pid": pid,
                       "process": m.group(2), "port": port, "count": int(m.group(1) or 1)}
                if mismatch:
                    # Recorded by the kernel's word and marked, and judge() never calls it clean.
                    rec["mismatch"] = True
                if refused:
                    # Nothing to name: the connect never happened, so the process holds no socket for
                    # lsof to read. It is kept apart from the reports from here on.
                    with self.cond:
                        self.refusals.append(rec)
                    self._event(rec)
                    continue
                rec["addresses"], why = self._name(pid, port)
                if why:
                    rec["name_error"] = why
                with self.cond:
                    self.reports.append(rec)
                self._event(rec)
        except Exception as e:
            # A line that could not be written into the record (a full disk) or read at all. The
            # reader stops, so the end canary is never seen and the run is unmeasured, saying this.
            self.reader_error = "%s: %s" % (type(e).__name__, e)
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
        """Run one round of canaries (CANARY_PARTS), each under a profile tagged for it alone, and
        return the messages the report stream must show for the round to count."""
        self.canaries_fired += 1
        base = "%s-%d" % (self.canary_tag, self.canaries_fired)
        self.canary_want = []
        for name, text, suffix, port, must, shown in CANARY_PARTS:
            tag = base + suffix
            with open(self.canary_profile, "w", errors="replace") as f:
                f.write(text(tag))
            try:
                r = subprocess.run([self.sandbox, "-f", self.canary_profile, sys.executable, "-c", CANARY, str(port)],
                                   capture_output=True, text=True, timeout=CANARY_RUN_MAX_S, errors="replace")
            except (OSError, subprocess.TimeoutExpired) as e:
                raise Unavailable("the canary could not run under %s: %s" % (self.sandbox, e))
            out = r.stdout.split()
            if r.returncode != 0 or len(out) != 2 or out[0] not in ("passed", "refused") or not out[1].isdigit():
                raise Unavailable("the canary could not run under %s (exit %s): %s"
                                  % (self.sandbox, r.returncode, (r.stderr or r.stdout).strip()[-300:]))
            if out[0] != must:
                # The kernel did the opposite of what this profile is written to do, so nothing the
                # profiles of this run say about what is refused can be relied on here.
                if must == "refused":
                    raise Unavailable("%s did not refuse the canary's UDP connect to port %d under the refusal"
                                      " rule, so the one kind of connection a drive call's profile refuses cannot"
                                      " be shown to be refused here" % (self.sandbox, port))
                raise Unavailable("%s refused the canary's UDP connect to port %d under %s, which must refuse it"
                                  " nothing, so more would be refused here than the one connection chosen"
                                  % (self.sandbox, port, "serve's profile" if name == "serve"
                                     else "the profile of drive calls"))
            self.canary_want.append((shown, tag + (REFUSED if must == "refused" else "")))
        return [message for _, message in self.canary_want]

    def _canary_seen(self):
        """Fire rounds of canaries until every message of one round has arrived (its report under each
        profile and the record of its refused connection), the stream ends, or egress_s passes. Any
        round fired by THIS call counts once it is whole, so three lines that take longer than one
        retry to arrive on a loaded Mac are not thrown away; a round from an earlier call never does."""
        deadline = time.monotonic() + self.egress_s
        rounds = []
        while time.monotonic() < deadline:
            rounds.append(self._fire_canary())

            def whole():
                return any(all(message in self.canaries_seen for message in want) for want in rounds)
            with self.cond:
                self.cond.wait_for(lambda: whole() or self.stream_ended,
                                   timeout=max(0.0, min(CANARY_RETRY_S, deadline - time.monotonic())))
                if whole():
                    return True
                if self.stream_ended:
                    return False
        return False

    def _canary_gap(self, which):
        """What the last round of canaries was still waiting for, in the words of a reason."""
        with self.cond:
            missing = [shown for shown, message in self.canary_want if message not in self.canaries_seen]
        if len(missing) == len(self.canary_want):
            return "no report of the %s canary" % which
        return "the %s canary only in part, without %s," % (which, " or ".join(missing))

    def _stream_state(self):
        said = ""
        if self.reader_error:
            said = " (the reader of the report stream stopped on an error, so the record is incomplete: %s)" \
                % self.reader_error
        if self.proc is not None and self.proc.poll() is not None:
            said += " (the stream exited with %s and said: %s)" % (self.proc.returncode,
                                                                    "; ".join(self.chatter) or "nothing")
        return said

    # -- stopping --------------------------------------------------------------------------------

    def stop_stream(self):
        if self.proc is None:
            return
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                self.proc.wait(timeout=STREAM_STOP_S)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                self.proc.wait()
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
            try:
                ended = self._canary_seen()
            except Unavailable as e:
                return self.field("unmeasured", "the end of the run could not be proved: %s" % e)
            if not ended:
                return self.field("unmeasured", "the report stream showed %s within %ss, so connections made or"
                                  " refused late in the run may be missing%s"
                                  % (self._canary_gap("end"), self.egress_s, self._stream_state()))
            self.stop_stream()
            return self.judge()
        except Exception as e:
            return self.field("unmeasured", "the egress monitor failed while finishing: %s: %s" % (type(e).__name__, e))
        finally:
            self.stop_stream()

    # -- the verdict -----------------------------------------------------------------------------

    def field(self, verdict, why, destinations=(), unnamed=(), refused=()):
        return {"verdict": verdict, "why": why, "monitor": MONITOR, "allowed_hosts": self.allow,
                "allowed_unresolved": self.unresolved, "measured_from": self.started_at,
                "measured_to": v.utc_now() if verdict != "unmeasured" else None,
                "destinations": list(destinations), "unnamed": list(unnamed), "refused": list(refused)}

    def refused(self):
        """What the sandbox refused, one entry per process name, port and `mismatch`. `mismatch` says
        the kernel's line carried the message of the reporting rule, which refuses nothing, and not
        the refusal's. `by_the_rule` says whether the entry is what the one refusal rule produces
        (the helper browser, REFUSED_PORT, under the refusal's message); the log line holds nothing
        more to check it against, and an entry that is not is never clean."""
        with self.cond:
            refusals = list(self.refusals)
        out = {}
        for r in refusals:
            mismatch = bool(r.get("mismatch"))
            e = out.setdefault((r["process"], r["port"], mismatch), {
                "process": r["process"], "port": r["port"], "reports": 0, "pids": [],
                "by_the_rule": not mismatch and r["process"] == HELPER_BROWSER and r["port"] == REFUSED_PORT,
                "mismatch": mismatch})
            e["reports"] += r["count"]
            if r["pid"] not in e["pids"]:
                e["pids"].append(r["pid"])
        return sorted(out.values(), key=lambda e: (e["process"], e["port"], e["mismatch"]))

    def judge(self):
        more, unresolved = resolve(self.allow)
        allowed_ips = dict(self.allowed_ips, **more)
        self.unresolved = sorted(set(self.unresolved) | set(unresolved))
        dests, unnamed = {}, {}
        refused = self.refused()
        ruled = [e for e in refused if e["by_the_rule"]]
        strays = [e for e in refused if not e["by_the_rule"] and not e["mismatch"]]
        unruled = [e for e in refused if e["mismatch"]]  # refused under the reporting rule's message
        let_through = {}  # let through under the refusal's message, by process name and port
        # Said on every verdict that has one, so a refusal is always visible beside what left.
        refused_said = ""
        if ruled:
            refused_said = (". The sandbox refused these before they left this machine, and they are counted"
                            " apart from any connection that left: " + "; ".join(
                                "%s UDP port %d (%s)" % (e["process"], e["port"], plural(e["reports"]))
                                for e in ruled))
        with self.cond:
            reports = list(self.reports)
        for r in reports:
            if r.get("mismatch"):
                # Counted here AND below as the connection it is, so its address is in the receipt.
                lt = let_through.setdefault((r["process"], r["port"]), {"process": r["process"],
                                                                        "port": r["port"], "reports": 0})
                lt["reports"] += r["count"]
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
        let_through = [let_through[k] for k in sorted(let_through)]
        if outside or unnamed or strays or unruled or let_through:
            parts = []
            if let_through:
                # Fail closed, whatever host it reached: the kernel let through what the one refusal
                # is written to refuse, so nothing this run's profiles say about refusing holds here.
                parts.append("the kernel let through connections that carry the message of the refusal rule, which"
                             " is written to refuse them, so what this sandbox refuses is not what its profile"
                             " says: " + "; ".join("%s port %d (%s)" % (e["process"], e["port"], plural(e["reports"]))
                                                   for e in let_through))
            if unruled:
                # Fail closed: no rule of either profile refuses under that message.
                parts.append("the sandbox refused connections under the message of its reporting rule, which is"
                             " written to refuse nothing, so what refused them is not known: "
                             + "; ".join("%s port %d (%s)" % (e["process"], e["port"], plural(e["reports"]))
                                         for e in unruled))
            if strays:
                # Fail closed: the profile holds one refusal, so anything else refused under this
                # run's tag is the sandbox doing something nobody chose, and nothing here can say what.
                parts.append("the sandbox refused connections that its one refusal rule (%s, UDP port %d) could"
                             " not have produced, so what else it refused is not known: " % (HELPER_BROWSER,
                                                                                             REFUSED_PORT)
                             + "; ".join("%s port %d (%s)" % (e["process"], e["port"], plural(e["reports"]))
                                         for e in strays))
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
            return self.field("not-clean", ". ".join(parts) + refused_said, dests, unnamed, refused)
        if dests:
            why = "every connection outside this machine went to an allowed host: " + "; ".join(
                "%s port %d (%s)" % (d["address"], d["port"], d["allowed_as"]) for d in dests)
        else:
            why = ("the sandbox reported no connection from serve or the drive helper to any host other than %s"
                   " or %s for the whole run" % (", ".join(v.EGRESS_LOCAL_HOSTS[:-1]), v.EGRESS_LOCAL_HOSTS[-1]))
        return self.field("clean", why + refused_said, dests, unnamed, refused)


def plural(n):
    return "%d report%s" % (n, "" if n == 1 else "s")
