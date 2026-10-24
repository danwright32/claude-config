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
    sockets with `lsof` the moment it arrives. A connection that closed before then stays in the
    receipt as unnamed, and an unnamed connection is never clean (fail closed).
  * The stream is proved live by a CANARY, a process under a profile of its own (tagged apart, so a
    reused pid can never pass a real connection off as the canary's) that connects a UDP
    socket to 198.51.100.1 (TEST-NET-2: reserved, and a UDP connect sends no packet at all). The
    monitor counts as started only once the start canary's report arrives, and the run's verdict
    counts only once an end canary, fired after serve's whole process group is gone, has arrived.
    Anything less is `unmeasured` with the reason, never `clean` (L1, L98, L557).

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

import verification as v

SANDBOX_EXEC = "/usr/bin/sandbox-exec"
LOG = "/usr/bin/log"
LSOF = "/usr/sbin/lsof"
MONITOR = "sandbox-exec reports read with log stream, named with lsof"
CANARY_RETRY_S = 1.0  # how long one canary is waited for before another is fired: never a fixed wait
STREAM_STOP_S = 10
CANARY_RUN_MAX_S = 30  # one canary process, which a loaded Mac can take seconds to start


def finish_budget_s(egress_s):
    """The longest Monitor.finish can take: canaries until egress_s, the last one started just before
    it and running its whole limit, then stopping the stream and joining its reader (which may be in
    the middle of one lsof). Whoever waits for a supervisor's stop adds this (the #1571 review)."""
    return egress_s + CANARY_RUN_MAX_S + 3 * STREAM_STOP_S
CANARY = ("import os, socket\n"
          "s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n"
          "s.connect(('198.51.100.1', 9))\n"
          "s.close()\n"
          "print(os.getpid())\n")
# "Sandbox: node(123) allow network-outbound remote:*:443\n<tag>", or the same line prefixed with
# "N duplicate reports for " when the kernel collapsed repeats of it.
REPORT = re.compile(r"^(?:(\d+) duplicate reports? for )?Sandbox: (.*)\((\d+)\) allow network-outbound"
                    r" remote:\S*?:(\d+)\n(\S+)\s*$", re.S)


class Unavailable(Exception):
    """The monitor cannot measure this run; the message is the receipt's reason."""


def profile_text(tag):
    return ("(version 1)\n"
            "(allow default)\n"
            "(allow network-outbound (remote ip \"*:*\") (with report) (with message \"%s\"))\n"
            "(allow network-outbound (remote ip \"localhost:*\"))\n" % tag)


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
        with open(self.profile, "w") as f:
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
        if not self._canary_seen():
            raise Unavailable("the report stream showed no report of the start canary within %ss, so it cannot be"
                              " shown to see this run's connections%s" % (self.egress_s, self._stream_state()))
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
                tag = m.group(5) if m else None
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
                               capture_output=True, text=True, timeout=10)
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
            os.write(fd, (json.dumps(obj) + "\n").encode())
        finally:
            os.close(fd)

    # -- the canary ------------------------------------------------------------------------------

    def _fire_canary(self):
        """Run one canary under a profile tagged for it alone, and return that tag."""
        self.canaries_fired += 1
        tag = "%s-%d" % (self.canary_tag, self.canaries_fired)
        with open(self.canary_profile, "w") as f:
            f.write(profile_text(tag))
        try:
            r = subprocess.run([self.sandbox, "-f", self.canary_profile, sys.executable, "-c", CANARY],
                               capture_output=True, text=True, timeout=CANARY_RUN_MAX_S)
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
                return self.field("unmeasured", "the report stream showed no report of the end canary within %ss,"
                                  " so connections made late in the run may be missing%s"
                                  % (self.egress_s, self._stream_state()))
            self.stop_stream()
            return self.judge()
        except Exception as e:
            return self.field("unmeasured", "the egress monitor failed while finishing: %s: %s" % (type(e).__name__, e))
        finally:
            self.stop_stream()

    # -- the verdict -----------------------------------------------------------------------------

    def field(self, verdict, why, destinations=(), unnamed=()):
        return {"verdict": verdict, "why": why, "monitor": MONITOR, "allowed_hosts": self.allow,
                "allowed_unresolved": self.unresolved, "measured_from": self.started_at,
                "measured_to": v.utc_now() if verdict != "unmeasured" else None,
                "destinations": list(destinations), "unnamed": list(unnamed)}

    def judge(self):
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
                u = unnamed.setdefault((r["process"], r["port"]), {"process": r["process"], "port": r["port"],
                                                                   "reports": 0, "pids": []})
                u["reports"] += r["count"]
                if r["pid"] not in u["pids"]:
                    u["pids"].append(r["pid"])
        dests = sorted(dests.values(), key=lambda d: (d["address"], d["port"]))
        unnamed = sorted(unnamed.values(), key=lambda u: (u["process"], u["port"]))
        outside = [d for d in dests if not d["allowed"]]
        if outside or unnamed:
            parts = []
            if outside:
                parts.append("serve or the drive helper reached hosts outside egress.allow: " + "; ".join(
                    "%s port %d (%s, %s)" % (d["address"], d["port"], ", ".join(d["processes"]), plural(d["reports"]))
                    for d in outside))
            if unnamed:
                parts.append("connections outside this machine closed before their address could be read: "
                             + "; ".join("%s port %d (%s)" % (u["process"], u["port"], plural(u["reports"]))
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
