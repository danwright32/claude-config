"""Unit tests for egress.py, the egress monitor (claude-config#1571), on any platform.

The end to end cases (a real sandbox, a real report stream, a real merge check) are EgressTests in
test_run_session.py and run only on a Mac. These drive the monitor's reader and judgment with a
report stream written here, so the rules hold wherever the suite runs.
"""

import io
import json
import os
import sys
import tempfile
import threading
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # a module beside this one is carried by the sync: leave no cache (#2919)
sys.path.insert(0, HERE)

import egress  # noqa: E402
import run_session  # noqa: E402
import verification as v  # noqa: E402

RID = "20261023T230000Z-1234567-abcdef"


def report(pid, port, tag, process="node", dupes=None):
    msg = "Sandbox: %s(%d) allow network-outbound remote:*:%d\n%s" % (process, pid, port, tag)
    if dupes:
        msg = "%d duplicate reports for %s" % (dupes, msg)
    return json.dumps({"eventMessage": msg}).encode() + b"\n"


def refusal(pid, tag, process="chrome-headless-shell", port=443, dupes=None):
    """The kernel's line for a connection the sandbox refused, as macOS 26.6 writes it (measured for
    claude-config#3319): the word deny where a report says allow, and the message of the rule."""
    msg = "Sandbox: %s(%d) deny(1) network-outbound remote:*:%d\n%s" % (process, pid, port, tag)
    if dupes:
        msg = "%d duplicate reports for %s" % (dupes, msg)
    return json.dumps({"eventMessage": msg}).encode() + b"\n"


def canary_runs(**said):
    """A subprocess.run for rounds of canaries. Each of a round's three processes says what the kernel
    did with its connect, and is known here by the profile it was started under. The default is what
    a working sandbox does; a keyword changes one part's answer."""
    words = {"serve": "passed", "drive": "passed", "refusal": "refused"}
    words.update(said)

    def run(cmd, **kw):
        with open(cmd[2]) as f:
            text = f.read()
        part = "refusal" if '"^/"' in text else "drive" if "chrome-headless-shell" in text else "serve"
        return egress.subprocess.CompletedProcess(cmd, 0, "%s\n500\n" % words[part], "")
    return run


class FakeStream:
    def __init__(self, lines):
        self.stdout = io.BytesIO(b"".join(lines))
        self.pid = 0
        self.returncode = 0

    def poll(self):
        return 0


class ReaderAndJudgment(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.m = egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 30)
        # These rules are about the reports that arrive, so the Mac here reports everything it is
        # asked to: its one test connection was reported. WithheldReports covers the Mac that does not.
        fired(self.m, 1)
        self.m.beats[0]["seen"] = True

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, lines, names):
        self.m.proc = FakeStream(lines)
        with mock.patch.object(self.m, "_name", side_effect=lambda pid, port: (names.get(pid, []), None, [])):
            self.m._read()

    def test_a_reused_canary_pid_never_hides_a_real_connection(self):
        # The canary exits at once and macOS hands its pid to serve, which then reaches an outside host.
        self.read([report(500, 9, self.m.canary_tag + "-1", process="Python"), report(500, 443, self.m.tag)],
                  {500: ["203.0.113.7"]})
        self.assertEqual(self.m.canaries_seen, {self.m.canary_tag + "-1"})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual([(d["address"], d["port"]) for d in out["destinations"]], [("203.0.113.7", 443)])

    def test_canary_reports_alone_are_clean(self):
        self.read([report(501, 9, self.m.canary_tag + "-1", process="Python")], {})
        out = self.m.judge()
        self.assertEqual((out["verdict"], out["destinations"], out["unnamed"]), ("clean", [], []))

    def test_another_runs_reports_are_not_counted(self):
        self.read([report(502, 443, "vg-egress-20261023T230000Z-7654321-fedcba")], {502: ["203.0.113.8"]})
        self.assertEqual(self.m.judge()["verdict"], "clean")

    def test_duplicates_count_and_unnamed_is_never_clean(self):
        self.read([report(503, 443, self.m.tag), report(503, 443, self.m.tag, dupes=4)], {})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean")
        self.assertEqual(out["unnamed"], [{"process": "node", "port": 443, "reports": 5, "pids": [503],
                                           "name_error": None, "this_machine": []}])
        self.assertIn("node port 443 (5 reports): closed before it could be read", out["why"])

    def test_a_connection_lsof_failed_to_name_is_not_said_to_have_closed(self):
        # lsof is faked at subprocess.run, so _read names each report through the real _name: pid 600's
        # connection had closed (lsof exits 1 saying nothing), pid 601's lsof failed, and pid 602's
        # lsof timed out. One cause must never be reported as the other (L11, #1633).
        def lsof(cmd, **kw):
            pid = cmd[cmd.index("-p") + 1]
            if pid == "602":
                raise egress.subprocess.TimeoutExpired(cmd, 10)
            if pid == "601":
                return egress.subprocess.CompletedProcess(cmd, 2, "", "lsof: illegal option")
            return egress.subprocess.CompletedProcess(cmd, 1, "", "")

        self.m.proc = FakeStream([report(600, 443, self.m.tag), report(601, 443, self.m.tag),
                                  report(602, 80, self.m.tag, process="curl")])
        with mock.patch.object(egress.subprocess, "run", side_effect=lsof):
            self.m._read()
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        by_pid = {u["pids"][0]: u for u in out["unnamed"]}
        self.assertEqual(sorted(by_pid), [600, 601, 602], out["unnamed"])
        self.assertIsNone(by_pid[600]["name_error"])
        self.assertEqual(by_pid[601]["name_error"], "lsof exited 2 reading pid 601: lsof: illegal option")
        self.assertIn("could not read the sockets of pid 602", by_pid[602]["name_error"])
        self.assertIn("node port 443 (1 report): closed before it could be read", out["why"])
        self.assertIn("node port 443 (1 report): lsof could not read it: lsof exited 2 reading pid 601:"
                      " lsof: illegal option", out["why"])
        self.assertIn("curl port 80 (1 report): lsof could not read it: lsof could not read the sockets of"
                      " pid 602", out["why"])
        self.assertEqual(out["why"].count("closed before"), 1, out["why"])

    def test_an_allowed_address_is_clean_and_says_which_host(self):
        self.m.allow = list(v.EGRESS_LOCAL_HOSTS) + ["203.0.113.9"]
        self.read([report(504, 5432, self.m.tag)], {504: ["203.0.113.9"]})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "clean", out)
        self.assertEqual(out["destinations"][0]["allowed_as"], "203.0.113.9")

    def test_lsof_output_is_read_for_the_reported_port_only(self):
        out = ("p77\nf5\nn192.168.4.2:50000->203.0.113.1:443\nf6\nn127.0.0.1:50001->127.0.0.1:443\n"
               "f7\nn[2600::1]:50002->[2001:db8::5]:443\nf8\nn192.168.4.2:50003->203.0.113.2:80\n")
        self.assertEqual(egress.remote_addresses(out, 443), {"203.0.113.1", "2001:db8::5"})

    def test_a_monitor_that_never_started_finishes_unmeasured(self):
        out = self.m.finish()
        self.assertEqual(out["verdict"], "unmeasured")
        self.assertIn("before the egress monitor had proved", out["why"])


def fired(m, n):
    """The monitor's own record of n test connections it had its beat program make, none reported yet."""
    m.beats = [{"beat": i, "port": 20000 + i, "at": "2026-11-24T23:00:%02dZ" % i, "t": 0.0, "seen": False}
               for i in range(1, n + 1)]


def beat_report(m, i):
    """The kernel's line for test connection i, in the format measured on 2026-11-24: the process is
    named for the beat program's file, the port names the connection, the tag is the beats' own."""
    return report(4242, 20000 + i, m.tag + "-beat", process="egress-beat")


def fire_rounds(m, n):
    """Have the monitor fire n rounds of canaries through its own _fire_canary, with a working sandbox
    stood in for, and return each round's messages: what the report stream must show for it."""
    with mock.patch.object(egress.subprocess, "run", side_effect=canary_runs()):
        return [m._fire_canary() for _ in range(n)]


def canary_lines(messages):
    """The kernel's line for each canary message: a refusal for the one the sandbox must refuse, a
    report for the others."""
    return [refusal(900 + i, msg, process="Python") if msg.endswith("-refused")
            else report(900 + i, 443 if msg.endswith("-drive") else 9, msg, process="Python")
            for i, msg in enumerate(messages)]


def reporting_mac(m):
    """A monitor on a Mac that reports everything it is asked to: its one test connection was made
    and reported. For the cases whose rule is about something else; WithheldReports covers the Mac
    that does not."""
    fired(m, 1)
    m.beats[0]["seen"] = True
    return m


def lsof_answers(by_pid):
    """A subprocess.run for lsof: each pid's open sockets as `lsof -F n` prints them, written here by
    hand, or exit 1 saying nothing for a pid that holds none (its connection had closed)."""
    def run(cmd, **kw):
        sockets = by_pid.get(int(cmd[cmd.index("-p") + 1]))
        if not sockets:
            return egress.subprocess.CompletedProcess(cmd, 1, "", "")
        out = "p1\n" + "".join("f%d\nn%s\n" % (3 + i, s) for i, s in enumerate(sockets))
        return egress.subprocess.CompletedProcess(cmd, 0, out, "")
    return run


class ConnectionsToThisMachine(unittest.TestCase):
    """A report for which lsof showed only a connection to this machine itself (pull request 3570).

    macOS 27.2 reports a TCP connection to 127.0.0.1 or ::1 under the profile of drive calls, where
    macOS 26.6.2 writes nothing (measured on each, 2026-11-25). The report names a process and a
    port and never an address, for a connection to this machine too, so the monitor cannot tell it
    from a report for a connection off this machine that had already closed while the process
    held another one, to this machine, on the same port. So it is never excused: it stays unnamed
    and not clean. What changes is that the record says what lsof saw, apart from a connection
    that had closed before it could be read, which reads exactly as it did. The same rule against
    a real sandbox is EgressTests in test_run_session.py."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.m = reporting_mac(egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 30))

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, lines, sockets):
        """Read a report stream through the real _name, with lsof's answers written by hand."""
        self.m.proc = FakeStream(lines)
        with mock.patch.object(egress.subprocess, "run", side_effect=lsof_answers(sockets)):
            self.m._read()

    def reports(self):
        with open(self.m.events_path) as f:
            return [e for e in map(json.loads, f) if e.get("event") == "report"]

    def test_only_a_connection_to_this_machine_seen_is_kept_apart_and_is_not_clean(self):
        # What the work MacBook saw: the helper browser loading the test's own page, with the
        # connection held open long enough for lsof to read it.
        self.read([report(800, 59176, self.m.tag, process="chrome-headless-shell")],
                  {800: ["127.0.0.1:59572->127.0.0.1:59176"]})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual(out["destinations"], [])
        self.assertEqual(out["unnamed"], [{"process": "chrome-headless-shell", "port": 59176, "reports": 1,
                                           "pids": [800], "name_error": None, "this_machine": ["127.0.0.1"]}])
        self.assertIn("chrome-headless-shell port 59176 (1 report): the only connection the process held on that"
                      " port was to this machine (127.0.0.1)", out["why"])
        self.assertIn("does not say which connection", out["why"])
        self.assertNotIn("closed before it could be read", out["why"])
        self.assertEqual([(e["addresses"], e["this_machine"]) for e in self.reports()], [([], ["127.0.0.1"])])

    def test_the_same_over_ipv6(self):
        self.read([report(801, 59176, self.m.tag, process="chrome-headless-shell")],
                  {801: ["[::1]:59572->[::1]:59176"]})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual([(u["port"], u["this_machine"]) for u in out["unnamed"]], [(59176, ["::1"])])
        self.assertIn("was to this machine (::1)", out["why"])

    def test_a_connection_that_closed_before_it_could_be_read_reads_as_it_always_did(self):
        self.read([report(802, 443, self.m.tag)], {})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual(out["unnamed"], [{"process": "node", "port": 443, "reports": 1, "pids": [802],
                                           "name_error": None, "this_machine": []}])
        self.assertIn("node port 443 (1 report): closed before it could be read", out["why"])
        self.assertNotIn("to this machine (", out["why"])
        self.assertNotIn("this_machine", self.reports()[0])

    def test_the_two_are_never_one_entry(self):
        # The same program and the same port: one process was read holding a connection to this
        # machine, the other holding nothing. Neither is clean, and neither is told as the other.
        self.read([report(803, 443, self.m.tag), report(804, 443, self.m.tag)],
                  {803: ["127.0.0.1:50001->127.0.0.1:443"]})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual(sorted((u["pids"], u["this_machine"]) for u in out["unnamed"]),
                         [([803], ["127.0.0.1"]), ([804], [])])
        self.assertEqual(out["why"].count("closed before it could be read"), 1, out["why"])
        self.assertEqual(out["why"].count("was to this machine"), 1, out["why"])

    def test_a_process_holding_both_is_judged_by_the_address_off_this_machine(self):
        # A connection to this machine beside it excuses nothing: the outside address on that port
        # is named and judged as it always was.
        self.read([report(805, 443, self.m.tag)],
                  {805: ["127.0.0.1:50001->127.0.0.1:443", "192.168.4.2:50002->203.0.113.7:443"]})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual([(d["address"], d["port"], d["allowed"]) for d in out["destinations"]],
                         [("203.0.113.7", 443, False)])
        self.assertEqual(out["unnamed"], [])
        self.assertIn("203.0.113.7 port 443", out["why"])
        self.assertEqual([(e["addresses"], e["this_machine"]) for e in self.reports()],
                         [(["203.0.113.7"], ["127.0.0.1"])])

    def test_no_report_with_a_connection_to_this_machine_seen_ever_reads_clean(self):
        # Every shape of "the process held a connection to this machine on that port": alone, twice,
        # over both address families, and collapsed by the kernel into a count.
        for n, (sockets, dupes) in enumerate([
                (["127.0.0.1:50001->127.0.0.1:8080"], None),
                (["127.0.0.1:50001->127.0.0.1:8080", "127.0.0.1:50002->127.0.0.1:8080"], None),
                (["127.0.0.1:50001->127.0.0.1:8080", "[::1]:50002->[::1]:8080"], None),
                (["127.0.0.1:50001->127.0.0.1:8080"], 6)]):
            with self.subTest(sockets=sockets, dupes=dupes):
                m = reporting_mac(egress.Monitor(tempfile.mkdtemp(dir=self.tmp.name), RID,
                                                 list(v.EGRESS_LOCAL_HOSTS), 30))
                m.proc = FakeStream([report(810 + n, 8080, m.tag, dupes=dupes)])
                with mock.patch.object(egress.subprocess, "run", side_effect=lsof_answers({810 + n: sockets})):
                    m._read()
                out = m.judge()
                self.assertEqual(out["verdict"], "not-clean", out)
                self.assertEqual([u["reports"] for u in out["unnamed"]], [dupes or 1])
                self.assertTrue(out["unnamed"][0]["this_machine"], out)

    def test_an_address_that_only_looks_local_is_an_address_off_this_machine(self):
        # A LAN address, a link local one, the unspecified address and a name: none is this machine,
        # each is named as a destination and judged against the allowed hosts as before.
        for n, (remote, named) in enumerate([
                ("192.168.1.20:8080", "192.168.1.20"), ("10.0.0.5:8080", "10.0.0.5"),
                ("169.254.10.1:8080", "169.254.10.1"), ("0.0.0.0:8080", "0.0.0.0"),
                ("localhost:8080", "localhost"), ("127.0.0.1.example.com:8080", "127.0.0.1.example.com"),
                ("[::]:8080", "::"), ("[fe80::1%en0]:8080", "fe80::1"), ("[fd00::1]:8080", "fd00::1")]):
            with self.subTest(remote=remote):
                lsof = "p1\nf3\nn192.168.4.2:50000->%s\n" % remote
                self.assertEqual(egress.this_machine_addresses(lsof, 8080), set())
                self.assertEqual(egress.remote_addresses(lsof, 8080), {named})
                m = reporting_mac(egress.Monitor(tempfile.mkdtemp(dir=self.tmp.name), RID,
                                                 list(v.EGRESS_LOCAL_HOSTS), 30))
                m.proc = FakeStream([report(820 + n, 8080, m.tag)])
                with mock.patch.object(egress.subprocess, "run",
                                       side_effect=lsof_answers({820 + n: ["192.168.4.2:50000->" + remote]})):
                    m._read()
                out = m.judge()
                self.assertEqual(out["verdict"], "not-clean", out)
                self.assertEqual([(d["address"], d["allowed"]) for d in out["destinations"]], [(named, False)])
                self.assertEqual(out["unnamed"], [])

    def test_a_connection_to_this_machine_on_another_port_is_not_seen_for_this_one(self):
        self.read([report(830, 443, self.m.tag)], {830: ["127.0.0.1:50001->127.0.0.1:3000"]})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual([(u["port"], u["this_machine"]) for u in out["unnamed"]], [(443, [])])
        self.assertIn("node port 443 (1 report): closed before it could be read", out["why"])

    def test_lsof_output_is_read_for_this_machine_on_the_reported_port_only(self):
        out = ("p77\nf5\nn192.168.4.2:50000->203.0.113.1:443\nf6\nn127.0.0.1:50001->127.0.0.1:443\n"
               "f7\nn[::1]:50002->[::1]:443\nf8\nn127.0.0.1:50003->127.0.0.1:80\nf9\nn127.0.0.1:50004->127.9.9.9:443\n"
               "f10\nn*:443\nf11\nn127.0.0.1:443\n")
        self.assertEqual(egress.this_machine_addresses(out, 443), {"127.0.0.1", "::1", "127.9.9.9"})
        self.assertEqual(egress.this_machine_addresses(out, 80), {"127.0.0.1"})
        self.assertEqual(egress.this_machine_addresses(out, 8080), set())
        self.assertEqual(egress.remote_addresses(out, 443), {"203.0.113.1"})

    def test_a_failure_to_read_says_nothing_about_this_machine(self):
        def lsof(cmd, **kw):
            return egress.subprocess.CompletedProcess(cmd, 2, "p1\nf3\nn127.0.0.1:5->127.0.0.1:443\n",
                                                      "lsof: illegal option")
        self.m.proc = FakeStream([report(840, 443, self.m.tag)])
        with mock.patch.object(egress.subprocess, "run", side_effect=lsof):
            self.m._read()
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual([(u["name_error"], u["this_machine"]) for u in out["unnamed"]],
                         [("lsof exited 2 reading pid 840: lsof: illegal option", [])])
        self.assertIn("lsof could not read it", out["why"])


class Refusals(unittest.TestCase):
    """The one connection the sandbox refuses (claude-config#3319): a UDP connect to port 443 off this
    machine by the helper browser a drive call starts. A refusal is written into the record, counted
    apart from a connection that left, and never hides one. The same rules against a real sandbox,
    and a real browser, are EgressTests in test_run_session.py."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.m = reporting_mac(egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 30))
        # A case here that fails after a monitor really started must not leave its report stream
        # running: the red run of these cases left one behind for 23 minutes.
        self.addCleanup(self.m.stop_stream)
        self.refused_tag = self.m.tag + "-refused"

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, lines, names=None):
        self.m.proc = FakeStream(lines)
        with mock.patch.object(self.m, "_name", side_effect=lambda pid, port: ((names or {}).get(pid, []), None, [])):
            self.m._read()

    def events(self, kind):
        with open(self.m.events_path) as f:
            return [e for e in map(json.loads, f) if e.get("event") == kind]

    def test_a_refused_probe_is_recorded_and_counted_and_the_run_is_clean(self):
        self.read([refusal(700, self.refused_tag), refusal(701, self.refused_tag, dupes=2)])
        out = self.m.judge()
        self.assertEqual(out["verdict"], "clean", out)
        self.assertEqual((out["destinations"], out["unnamed"]), ([], []))
        self.assertEqual(out["refused"], [{"process": "chrome-headless-shell", "port": 443, "reports": 3,
                                           "pids": [700, 701], "by_the_rule": True, "mismatch": False}])
        self.assertIn("chrome-headless-shell UDP port 443 (3 reports)", out["why"])
        self.assertIn("refused", out["why"])
        written = self.events("refused")
        self.assertEqual([(e["pid"], e["process"], e["port"], e["count"]) for e in written],
                         [(700, "chrome-headless-shell", 443, 1), (701, "chrome-headless-shell", 443, 2)])
        self.assertEqual(self.events("report"), [], "a refusal must never be written as a connection that left")

    def test_a_run_with_no_refusal_says_so_with_an_empty_list(self):
        self.read([])
        out = self.m.judge()
        self.assertEqual((out["verdict"], out["refused"]), ("clean", []))
        self.assertNotIn("refused", out["why"])

    def test_a_refusal_never_hides_a_connection_that_left(self):
        # The same browser, the same port: the probe was refused (UDP), and a TCP connection to port
        # 443 was reported and had closed before lsof read it. The second one left this machine.
        self.read([refusal(710, self.refused_tag),
                   report(710, 443, self.m.tag, process="chrome-headless-shell"),
                   report(710, 8443, self.m.tag, process="chrome-headless-shell")], {710: []})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual([(u["process"], u["port"], u["reports"]) for u in out["unnamed"]],
                         [("chrome-headless-shell", 443, 1), ("chrome-headless-shell", 8443, 1)])
        self.assertEqual([(r["port"], r["reports"]) for r in out["refused"]], [(443, 1)])
        self.assertIn("chrome-headless-shell port 443 (1 report): closed before it could be read", out["why"])
        self.assertEqual((len(self.events("refused")), len(self.events("report"))), (1, 2))

    def test_a_named_outside_connection_by_the_browser_is_still_not_clean(self):
        self.read([refusal(711, self.refused_tag), report(711, 8080, self.m.tag, process="chrome-headless-shell")],
                  {711: ["192.0.2.1"]})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual([(d["address"], d["port"]) for d in out["destinations"]], [("192.0.2.1", 8080)])

    def test_a_refusal_the_one_rule_could_not_have_produced_is_never_clean(self):
        # The profile holds one refusal, for one executable name and one port. A refusal carrying this
        # run's tag for anything else means the sandbox is refusing something nobody chose.
        for process, port in (("node", 443), ("chrome-headless-shell", 80)):
            with self.subTest(process=process, port=port):
                m = reporting_mac(egress.Monitor(tempfile.mkdtemp(dir=self.tmp.name), RID,
                                                 list(v.EGRESS_LOCAL_HOSTS), 30))
                m.proc = FakeStream([refusal(720, m.tag + "-refused", process=process, port=port)])
                m._read()
                out = m.judge()
                self.assertEqual(out["verdict"], "not-clean", out)
                self.assertEqual([(r["process"], r["port"], r["by_the_rule"]) for r in out["refused"]],
                                 [(process, port, False)])
                self.assertIn("%s port %d (1 report)" % (process, port), out["why"])
                self.assertIn("could not have produced", out["why"])

    def test_another_runs_refusals_are_not_counted(self):
        self.read([refusal(730, "vg-egress-20261023T230000Z-7654321-fedcba-refused")])
        out = self.m.judge()
        self.assertEqual((out["verdict"], out["refused"]), ("clean", []))

    # The kernel's own word (allow or deny) decides what a line is, never the message it carries (the
    # review of #3570). What a compiled profile does cannot be read off its text, so a line whose
    # word and message disagree is the sandbox doing something nobody wrote. It is recorded by the
    # kernel's word, marked `mismatch`, and the run is never clean. Until that review one case here
    # asserted that both such lines were dropped, which let a connection that left read as clean.

    def test_a_connection_let_through_under_the_refusal_message_left_and_is_never_clean(self):
        # `allow` under the refused tag: the kernel says this connection LEFT this machine, whatever
        # the message says its rule does.
        self.read([report(740, 443, self.refused_tag, process="chrome-headless-shell")], {740: []})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual(out["refused"], [], "a connection the kernel let through is never a refusal")
        self.assertEqual([(u["process"], u["port"], u["reports"]) for u in out["unnamed"]],
                         [("chrome-headless-shell", 443, 1)])
        self.assertIn("let through", out["why"])
        self.assertIn("chrome-headless-shell port 443 (1 report)", out["why"])
        self.assertEqual([(e["pid"], e["port"], e.get("mismatch")) for e in self.events("report")],
                         [(740, 443, True)])
        self.assertEqual(self.events("refused"), [], "nor is it written into the record as one")

    def test_a_refusal_under_the_report_message_is_recorded_and_never_clean(self):
        # `deny` under the plain tag: nothing left, but no rule of either profile refuses under that
        # message, so what refused it is not known. The helper browser on port 443 is what the one
        # refusal names, so there only the message tells this line from the refusal that was chosen.
        for process, port in (("chrome-headless-shell", 443), ("node", 80)):
            with self.subTest(process=process, port=port):
                m = reporting_mac(egress.Monitor(tempfile.mkdtemp(dir=self.tmp.name), RID,
                                                 list(v.EGRESS_LOCAL_HOSTS), 30))
                m.proc = FakeStream([refusal(741, m.tag, process=process, port=port)])
                m._read()
                out = m.judge()
                self.assertEqual(out["verdict"], "not-clean", out)
                self.assertEqual(out["refused"], [{"process": process, "port": port, "reports": 1, "pids": [741],
                                                   "by_the_rule": False, "mismatch": True}])
                self.assertEqual((out["destinations"], out["unnamed"]), ([], []),
                                 "a refusal is never counted as a connection that left")
                self.assertIn("reporting rule", out["why"])
                self.assertIn("%s port %d (1 report)" % (process, port), out["why"])
                with open(m.events_path) as f:
                    written = [json.loads(line) for line in f]
                self.assertEqual([(e["event"], e["pid"], e.get("mismatch")) for e in written], [("refused", 741, True)])

    def test_the_chosen_refusal_and_one_under_the_report_message_are_counted_apart(self):
        self.read([refusal(750, self.refused_tag), refusal(751, self.m.tag)])
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual([(r["pids"], r["by_the_rule"], r["mismatch"]) for r in out["refused"]],
                         [([750], True, False), ([751], False, True)])

    def test_the_kernels_word_decides_in_each_of_the_four_combinations(self):
        # One connection by the helper browser to port 443 at an address the project allows, so a
        # report of it is clean by itself: whatever is not clean below is so for the mismatch alone.
        for word, message, event, mismatch, verdict in (("allow", "report", "report", None, "clean"),
                                                        ("deny", "refused", "refused", None, "clean"),
                                                        ("allow", "refused", "report", True, "not-clean"),
                                                        ("deny", "report", "refused", True, "not-clean")):
            with self.subTest(word=word, message=message):
                m = reporting_mac(egress.Monitor(tempfile.mkdtemp(dir=self.tmp.name), RID,
                                                 list(v.EGRESS_LOCAL_HOSTS) + ["192.0.2.1"], 30))
                tag = m.tag + ("-refused" if message == "refused" else "")
                line = (report(770, 443, tag, process="chrome-headless-shell") if word == "allow"
                        else refusal(770, tag))
                m.proc = FakeStream([line])
                with mock.patch.object(m, "_name", return_value=(["192.0.2.1"], None, [])):
                    m._read()
                out = m.judge()
                with open(m.events_path) as f:
                    written = [json.loads(line) for line in f]
                self.assertEqual([(e["event"], e.get("mismatch")) for e in written], [(event, mismatch)])
                self.assertEqual(out["verdict"], verdict, out)
                self.assertEqual((len(m.reports), len(m.refusals)), (1, 0) if word == "allow" else (0, 1))
                self.assertEqual([(d["address"], d["allowed"]) for d in out["destinations"]],
                                 [("192.0.2.1", True)] if word == "allow" else [])

    def test_a_canary_line_whose_word_and_message_disagree_proves_no_canary(self):
        # A canary proves a profile only by the line that profile is written to produce. The other
        # line under its tag leaves the round unfinished, which is `unmeasured`, as it always was.
        base = self.m.canary_tag + "-1"
        self.read([report(760, 443, base + "-self-refused", process="Python"),
                   refusal(761, base + "-drive", process="Python")])
        self.assertEqual(self.m.canaries_seen, set())
        self.assertEqual((self.m.reports, self.m.refusals), ([], []))
        self.read([refusal(760, base + "-self-refused", process="Python"),
                   report(761, 443, base + "-drive", process="Python")])
        self.assertEqual(self.m.canaries_seen, {base + "-self-refused", base + "-drive"})

    def test_only_drive_calls_get_the_rule_and_it_names_only_the_helper_browser(self):
        serve, drive = egress.profile_text("T"), egress.drive_profile_text("T")
        self.assertNotIn("deny", serve)
        self.assertTrue(drive.startswith(serve), drive)
        self.assertEqual(drive[len(serve):].splitlines(), [
            '(deny network-outbound (require-all (process-path-regex "/chrome-headless-shell$")'
            ' (remote udp "*:443")) (with message "T-refused"))',
            '(allow network-outbound (require-all (process-path-regex "/chrome-headless-shell$")'
            ' (remote udp "localhost:443")))'])

    def test_the_monitor_writes_both_profiles_or_does_not_start(self):
        real_open = open

        def no_drive_profile(path, *a, **kw):
            if str(path).endswith("egress-drive.sb"):
                raise OSError(28, "No space left on device")
            return real_open(path, *a, **kw)

        with mock.patch.object(egress.sys, "platform", "darwin"), \
                mock.patch.object(egress.os, "access", return_value=True), \
                mock.patch("builtins.open", side_effect=no_drive_profile):
            why = self.m.start()
        self.assertIn("No space left on device", why or "")
        out = self.m.finish()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("No space left on device", out["why"])

    def test_a_canary_the_sandbox_did_not_refuse_cannot_prove_the_monitor(self):
        # One canary tries the refused kind of connection under the rule aimed at itself. One that
        # got through means the sandbox here does not apply the rule, so the monitor must not start.
        with mock.patch.object(egress.subprocess, "run", side_effect=canary_runs(refusal="passed")):
            with self.assertRaises(egress.Unavailable) as caught:
                self.m._fire_canary()
        self.assertIn("did not refuse", str(caught.exception))

    def test_a_drive_profile_that_refuses_another_program_cannot_prove_the_monitor(self):
        # One canary runs under the exact profile of drive calls as a program that is not the helper
        # browser. Refused there, the rule reaches further than the one executable it names.
        with mock.patch.object(egress.subprocess, "run", side_effect=canary_runs(drive="refused")):
            with self.assertRaises(egress.Unavailable) as caught:
                self.m._fire_canary()
        self.assertIn("the profile of drive calls", str(caught.exception))
        self.assertIn("more would be refused", str(caught.exception))

    def a_round_missing(self, ending):
        """The verdict of a run whose every round of canaries arrives but for the message that ends so."""
        m = egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 0.3)
        fire = m._fire_canary

        def all_but_one():
            want = fire()
            self.assertEqual(len([w for w in want if w.endswith(ending)]), 1, want)
            m.canaries_seen.update(w for w in want if not w.endswith(ending))
            return want

        with mock.patch.object(egress.subprocess, "run", side_effect=canary_runs()), \
                mock.patch.object(m, "_fire_canary", side_effect=all_but_one):
            self.assertFalse(m._canary_seen())
            m.started_at = v.utc_now()
            out = m.finish()
        self.assertEqual(out["verdict"], "unmeasured", out)
        return out["why"]

    def test_a_canary_whose_refusal_never_reaches_the_record_is_not_proof(self):
        why = self.a_round_missing("-self-refused")
        self.assertIn("the record of the connection the sandbox refused it", why)

    def test_a_canary_the_drive_profile_let_through_unreported_is_not_proof(self):
        # Measured on macOS 26.6.2: one line fewer in the profile and another program's UDP connect
        # to port 443 is let through with no report. Every run proves that did not happen to it.
        why = self.a_round_missing("-drive")
        self.assertIn("its report under the profile of drive calls", why)

    def test_a_round_whose_lines_arrive_after_the_next_was_fired_still_counts(self):
        # A round needs three lines where the canary used to need one, and a loaded Mac delivers them
        # late. A round fired by this wait is proof whenever it becomes whole, never thrown away for
        # the retry that followed it. (A round from an earlier wait never counts: CanaryIdentity.)
        m = egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 2)
        fire, fired = m._fire_canary, []

        def late():
            fired.append(fire())
            if len(fired) == 2:
                m.canaries_seen.update(fired[0])  # the first round's lines, arriving only now
            return fired[-1]

        with mock.patch.object(egress.subprocess, "run", side_effect=canary_runs()), \
                mock.patch.object(egress, "CANARY_RETRY_S", 0.05), \
                mock.patch.object(m, "_fire_canary", side_effect=late):
            self.assertTrue(m._canary_seen())
        self.assertEqual(len(fired), 2)

    def test_a_whole_round_of_canaries_is_proof_and_none_of_it_is_the_runs(self):
        m = reporting_mac(egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 5))
        m.proc = FakeStream([report(750, 9, m.canary_tag + "-1", process="Python"),
                             report(751, 443, m.canary_tag + "-1-drive", process="Python"),
                             refusal(752, m.canary_tag + "-1-self-refused", process="Python")])
        m._read()
        m.stream_ended = False
        with mock.patch.object(egress.subprocess, "run", side_effect=canary_runs()):
            self.assertTrue(m._canary_seen())
        out = m.judge()
        self.assertEqual((out["verdict"], out["refused"], out["unnamed"]), ("clean", [], []))

    def test_a_refusal_that_cannot_be_written_into_the_record_is_unmeasured(self):
        real_event = self.m._event

        def full_disk(obj):
            if obj.get("event") == "refused":
                raise OSError(28, "No space left on device")
            return real_event(obj)

        self.m.proc = FakeStream([refusal(760, self.refused_tag)])
        with mock.patch.object(self.m, "_event", side_effect=full_disk):
            self.m._read()
            self.m.started_at = v.utc_now()
            with mock.patch.object(egress.subprocess, "run", side_effect=canary_runs()):
                out = self.m.finish()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("No space left on device", out["why"])


class WithheldReports(unittest.TestCase):
    """A Mac that does not write every sandbox report it is asked for can never read clean
    (claude-config#3576). Measured on macOS 26.6.2 on 2026-11-24: in each window of about a minute
    the kernel did not write 8 of the reports for programs not signed by Apple, so a serve that
    connected out a few times a minute went wholly unreported and the run read clean."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.m = egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 30)

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, lines, names=None):
        self.m.proc = FakeStream(lines)
        with mock.patch.object(self.m, "_name", side_effect=lambda pid, port: ((names or {}).get(pid, []), None, [])):
            self.m._read()

    def test_a_test_connection_never_reported_is_unmeasured(self):
        # The measured shape: ten made, the first eight never reported, the ninth and tenth reported.
        fired(self.m, 10)
        self.read([beat_report(self.m, 9), beat_report(self.m, 10)])
        out = self.m.judge()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("this Mac did not report every connection it was asked to report", out["why"])
        self.assertIn("8 of the 10 test connections", out["why"])
        self.assertIn("cannot be trusted", out["why"])
        self.assertEqual((out["beats"]["fired"], out["beats"]["reported"]), (10, 2), out)
        self.assertEqual([b["beat"] for b in out["beats"]["unreported"]], list(range(1, 9)), out)
        self.assertIsNone(out["measured_to"])

    def test_the_shape_measured_after_a_restart_is_unmeasured_too(self):
        # 11:24 PM ET, after the Mac was restarted: of twelve made, number 1 and then 9, 10 and 11
        # were never reported, with seven reported between them. No order is relied on.
        fired(self.m, 12)
        self.read([beat_report(self.m, i) for i in (2, 3, 4, 5, 6, 7, 8, 12)])
        out = self.m.judge()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("4 of the 12 test connections", out["why"])
        self.assertEqual([b["beat"] for b in out["beats"]["unreported"]], [1, 9, 10, 11], out)

    def test_a_mac_that_reports_every_test_connection_still_reads_clean(self):
        fired(self.m, 3)
        self.read([beat_report(self.m, i) for i in (1, 2, 3)])
        out = self.m.judge()
        self.assertEqual(out["verdict"], "clean", out)
        self.assertEqual((out["beats"]["fired"], out["beats"]["reported"], out["beats"]["unreported"]), (3, 3, []))

    # A canary is a round of three connections (CANARY_PARTS, claude-config#3319), each under a profile
    # and a message of its own, and every one of them is a report the monitor asked this Mac for. So
    # the count of canaries never seen is a count over all three of every round fired. Counted by
    # round, as it was before the two changes met, a round whose first connection was reported
    # read as seen whatever became of the other two.

    def test_a_canary_never_seen_is_unmeasured_and_counted(self):
        # What main hid: nine canaries fired, only the ninth reported, and the run read clean.
        fired(self.m, 1)
        rounds = fire_rounds(self.m, 9)
        self.read([beat_report(self.m, 1)] + canary_lines(rounds[8]))
        out = self.m.judge()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("this Mac did not report every connection it was asked to report", out["why"])
        self.assertIn("24 of the 27 canary connections", out["why"])
        self.assertEqual(out["canaries"], {"rounds": 9, "fired": 27, "seen": 3,
                                           "unseen": {"serve": 8, "drive": 8, "refusal": 8}})

    def test_one_connection_of_an_earlier_round_never_seen_is_unmeasured(self):
        # The start of a run on a Mac that withholds: one line of the first round never comes, the
        # second round arrives whole and proves the stream live. Whichever of the three it was, the
        # run did not get every report it asked for, and it must not read clean.
        for part, ending, said in (("serve", "", "under serve's profile"),
                                   ("drive", "-drive", "under the profile of drive calls"),
                                   ("refusal", "-self-refused", "that the sandbox refused")):
            with self.subTest(part=part):
                m = reporting_mac(egress.Monitor(tempfile.mkdtemp(dir=self.tmp.name), RID,
                                                 list(v.EGRESS_LOCAL_HOSTS), 30))
                first, second = fire_rounds(m, 2)
                missing = m.canary_tag + "-1" + ending
                self.assertIn(missing, first)
                m.proc = FakeStream(canary_lines([msg for msg in first if msg != missing] + second))
                m._read()
                out = m.judge()
                self.assertEqual(out["verdict"], "unmeasured", out)
                self.assertIn("this Mac did not report every connection it was asked to report", out["why"])
                self.assertIn("1 of the 6 canary connections, 1 %s, never reported" % said, out["why"])
                self.assertEqual(out["canaries"], {"rounds": 2, "fired": 6, "seen": 5, "unseen": dict(
                    {"serve": 0, "drive": 0, "refusal": 0}, **{part: 1})})

    def test_rounds_that_all_arrived_whole_read_clean(self):
        fired(self.m, 1)
        first, second = fire_rounds(self.m, 2)
        self.read([beat_report(self.m, 1)] + canary_lines(first + second))
        out = self.m.judge()
        self.assertEqual(out["verdict"], "clean", out)
        self.assertEqual(out["canaries"], {"rounds": 2, "fired": 6, "seen": 6,
                                           "unseen": {"serve": 0, "drive": 0, "refusal": 0}})

    def test_a_canary_line_for_a_connection_never_fired_is_not_counted_as_seen(self):
        # A line under a canary's tag that this monitor never fired (round 7 of a run that fired one)
        # must not stand in for one it did fire: two of the three came, and the receipt says two.
        fired(self.m, 1)
        (only,) = fire_rounds(self.m, 1)
        self.read([beat_report(self.m, 1), report(501, 9, self.m.canary_tag + "-7", process="Python")]
                  + canary_lines(only[:2]))
        out = self.m.judge()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertEqual((out["canaries"]["fired"], out["canaries"]["seen"]), (3, 2), out)

    def test_each_canary_connection_is_recorded_as_fired_before_it_is_made(self):
        # So its report can never arrive ahead of the record, and a receipt's log names every
        # connection that was asked for, by the message the report stream must show for it.
        recorded_when_run, stand_in = [], canary_runs()

        def run(cmd, **kw):
            with open(self.m.events_path) as f:
                recorded_when_run.append([e["canary"] for e in map(json.loads, f) if e["event"] == "canary-fired"])
            return stand_in(cmd, **kw)

        with mock.patch.object(egress.subprocess, "run", side_effect=run):
            want = self.m._fire_canary()
        self.assertEqual(want, [self.m.canary_tag + "-1", self.m.canary_tag + "-1-drive",
                                self.m.canary_tag + "-1-self-refused"])
        self.assertEqual(recorded_when_run, [want[:1], want[:2], want[:3]])

    def test_settling_waits_for_a_late_canary_connection_of_any_part(self):
        # The end round's report under the profile of drive calls comes a fifth of a second after the
        # other two, with the stream still open: a line that is merely late must not read as withheld.
        reporting_mac(self.m)
        (only,) = fire_rounds(self.m, 1)
        late_one = only[1]

        def arrive():
            with self.m.cond:
                self.m.canaries_seen.add(late_one)
                self.m.cond.notify_all()

        with self.m.cond:
            self.m.canaries_seen.update(msg for msg in only if msg != late_one)
        late = threading.Timer(0.2, arrive)
        with mock.patch.object(egress, "SETTLE_S", 8):
            late.start()
            began = egress.time.monotonic()
            self.m._settle()
            waited = egress.time.monotonic() - began
        late.join()
        self.assertGreater(waited, 0.1, "settling returned before the late canary connection had come")
        self.assertLess(waited, 4, "settling went on after the late canary connection had come")
        self.assertEqual(self.m.judge()["verdict"], "clean")

    def test_a_refused_line_under_the_beats_tag_never_marks_a_test_connection_reported(self):
        # The report pattern matches a refusal too (claude-config#3319). The beat's profile refuses
        # nothing, so a refusal under its tag is no report of a test connection.
        fired(self.m, 1)
        self.read([refusal(4242, self.m.tag + "-beat", process="egress-beat", port=20001)])
        out = self.m.judge()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("1 of the 1 test connections", out["why"])
        self.assertEqual((out["refused"], out["unnamed"]), ([], []), "nor is it a connection by serve")

    def test_a_seen_outside_connection_stays_not_clean_when_reports_were_withheld(self):
        fired(self.m, 4)
        self.read([beat_report(self.m, 4), report(700, 443, self.m.tag)], {700: ["203.0.113.7"]})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertIn("203.0.113.7 port 443", out["why"])
        self.assertIn("this Mac did not report every connection it was asked to report", out["why"])
        self.assertIn("there may have been more", out["why"])

    def test_an_unnamed_connection_stays_not_clean_when_reports_were_withheld(self):
        fired(self.m, 2)
        self.read([report(701, 9, self.m.tag, process="python3.14")])
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertIn("python3.14 port 9", out["why"])
        self.assertIn("2 of the 2 test connections", out["why"])

    def test_a_beat_program_that_could_not_be_made_is_unmeasured(self):
        self.m.beat_failure = "the copy of /bin/bash could not be signed ad hoc (codesign exit 1: no identity)"
        out = self.m.judge()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("could not check that this Mac reports every connection", out["why"])
        self.assertIn("codesign exit 1: no identity", out["why"])
        self.assertEqual(out["beats"]["failure"], self.m.beat_failure)

    def test_a_run_with_no_test_connection_at_all_is_unmeasured(self):
        # Nothing checked this Mac, so nothing says it reports everything (L98).
        out = self.m.judge()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("made no test connection", out["why"])

    def test_an_allowed_destination_does_not_make_a_withholding_mac_clean(self):
        self.m.allow = list(v.EGRESS_LOCAL_HOSTS) + ["203.0.113.9"]
        fired(self.m, 2)
        self.read([beat_report(self.m, 2), report(504, 5432, self.m.tag)], {504: ["203.0.113.9"]})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertEqual([d["address"] for d in out["destinations"]], ["203.0.113.9"])

    def test_a_beat_report_is_never_counted_as_a_connection_by_serve(self):
        fired(self.m, 1)
        self.read([beat_report(self.m, 1)])
        out = self.m.judge()
        self.assertEqual((out["verdict"], out["destinations"], out["unnamed"]), ("clean", [], []), out)

    def test_a_report_for_a_connection_the_monitor_never_made_proves_nothing(self):
        # Another run's beat, or a stray line on this run's beat tag: it must not mark one of ours seen.
        fired(self.m, 1)
        self.read([report(4242, 20001, "vg-egress-20261023T230000Z-7654321-fedcba-beat", process="egress-beat"),
                   beat_report(self.m, 7)])
        self.assertEqual(self.m.judge()["verdict"], "unmeasured")


SH_LOOP_OK = 'while read -r n; do echo "$n 0"; done'
SH_LOOP_REFUSED = 'while read -r n; do echo "$n 1"; done'


class BeatProgram(unittest.TestCase):
    """How the test connections are made: by one long lived program the monitor tells a port at a
    time. A /bin/sh loop stands in for the ad hoc signed copy of bash, so these run anywhere; the
    real copy, under the real sandbox, is EgressTests in test_run_session.py."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.m = egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 30)

    def tearDown(self):
        self.m._stop_beats()
        self.tmp.cleanup()

    def start(self, loop=SH_LOOP_OK):
        def made():
            with open(self.m.beat_program, "w") as f:
                f.write("stand in\n")

        with mock.patch.object(self.m, "_make_beat_program", side_effect=made), \
                mock.patch.object(self.m, "_beat_argv", return_value=["/bin/sh", "-c", loop]):
            self.m._start_beats()

    def test_each_connection_made_is_recorded_before_any_report_of_it(self):
        self.start()
        self.assertIsNone(self.m.beat_failure)
        self.m._beat()
        self.assertEqual([(b["beat"], b["port"], b["seen"]) for b in self.m.beats],
                         [(1, egress.BEAT_PORT + 1, False), (2, egress.BEAT_PORT + 2, False)])
        with open(self.m.events_path) as f:
            events = [json.loads(line) for line in f]
        self.assertEqual([(e["event"], e["beat"]) for e in events], [("beat-fired", 1), ("beat-fired", 2)])

    def test_a_connection_the_program_could_not_make_is_a_failure_not_a_beat(self):
        self.start(SH_LOOP_REFUSED)
        self.assertIn("could not make its test connection", self.m.beat_failure or "")
        self.assertEqual(self.m.beats, [])
        self.assertEqual(self.m.judge()["verdict"], "unmeasured")

    def test_a_program_that_died_is_a_failure(self):
        self.start()
        self.m.beat_proc.kill()
        self.m.beat_proc.wait()
        with self.assertRaises(egress.Unavailable):
            self.m._beat()
        self.assertEqual(len(self.m.beats), 1, "a connection never made must not be counted as fired")

    # How the beat program ENDED is read too (the CI red on pull request 3593: its exit status was
    # waited for and thrown away). Each stand in below made its one test connection and had it
    # reported, so before the status was read every one of these runs read clean.

    def events(self):
        with open(self.m.events_path) as f:
            return [json.loads(line) for line in f]

    def stopped_and_judged(self):
        """Report the one test connection made, stop the beat program and judge the run."""
        self.m._beat_reported(egress.BEAT_PORT + 1, 1)
        self.m._stop_beats()
        return self.m.judge()

    def test_a_program_that_ends_when_told_reads_clean_and_its_exit_is_recorded(self):
        self.start()
        out = self.stopped_and_judged()
        self.assertIsNone(self.m.beat_failure)
        self.assertEqual(out["verdict"], "clean", out)
        ended = [e for e in self.events() if e["event"] == "beat-ended"]
        self.assertEqual([(e["exit"], e["early"], e["killed"]) for e in ended], [(0, False, False)])

    def test_a_program_that_exits_non_zero_when_told_to_end_is_unmeasured(self):
        self.start(SH_LOOP_OK + "; exit 5")
        self.assertIsNone(self.m.beat_failure)
        out = self.stopped_and_judged()
        self.assertIn("exit 5", self.m.beat_failure or "")
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("could not check that this Mac reports every connection", out["why"])
        self.assertIn("exit 5", out["why"])
        self.assertEqual(out["beats"]["failure"], self.m.beat_failure)
        events = self.events()
        self.assertEqual([e["why"] for e in events if e["event"] == "beat-failed"], [self.m.beat_failure])
        self.assertEqual([(e["exit"], e["early"], e["killed"]) for e in events if e["event"] == "beat-ended"],
                         [(5, False, False)])

    def test_a_program_that_ended_by_itself_before_the_run_did_is_unmeasured(self):
        # It answered for its one test connection and then left, with a status of 0: nothing made a
        # test connection for the rest of the run, and no later one was asked for that would say so.
        self.start('read -r n; echo "$n 0"')
        proc = self.m.beat_proc
        if proc is not None:  # None when the start saw it gone already, which is the same failure
            proc.wait(timeout=20)
        out = self.stopped_and_judged()
        self.assertIn("ended by itself (exit 0)", self.m.beat_failure or "")
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("could not check that this Mac reports every connection", out["why"])

    def test_a_program_gone_right_after_its_first_connection_fails_the_start(self):
        real = self.m._beat

        def beat_and_wait():
            real()
            self.m.beat_proc.wait(timeout=20)

        with mock.patch.object(self.m, "_beat", side_effect=beat_and_wait):
            self.start('read -r n; echo "$n 0"; exit 4')
        self.assertIn("ended by itself (exit 4) right after its first test connection", self.m.beat_failure or "")
        self.assertIsNone(self.m.beat_proc)
        self.assertEqual(self.m.judge()["verdict"], "unmeasured")

    def test_a_program_that_dies_between_connections_names_its_exit_status(self):
        self.start('read -r n; echo "$n 0"; read -r n; exit 3')
        self.assertIsNone(self.m.beat_failure)
        with self.assertRaises(egress.Unavailable) as raised:
            self.m._beat()
        self.assertIn("exit 3", str(raised.exception))
        self.assertEqual(len(self.m.beats), 1, "a connection never made must not be counted as fired")

    def test_a_program_that_exits_at_once_is_a_failure_that_names_its_exit_status(self):
        self.start("exit 3")
        self.assertIn("exit 3", self.m.beat_failure or "")
        self.assertEqual(self.m.beats, [])
        out = self.m.judge()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("could not check that this Mac reports every connection", out["why"])

    def test_a_program_that_will_not_end_is_killed_and_the_run_is_unmeasured(self):
        self.start(SH_LOOP_OK + "; exec sleep 600")
        proc = self.m.beat_proc
        with mock.patch.object(egress, "BEAT_STOP_S", 0.3):
            out = self.stopped_and_judged()
        self.assertEqual(proc.poll(), -egress.signal.SIGKILL, "the beat program was left running")
        self.assertIn("did not end within 0.3s of its input closing", self.m.beat_failure or "")
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("could not check that this Mac reports every connection", out["why"])

    def test_a_program_that_cannot_be_started_is_unmeasured(self):
        def made():
            with open(self.m.beat_program, "w") as f:
                f.write("stand in\n")

        with mock.patch.object(self.m, "_make_beat_program", side_effect=made), \
                mock.patch.object(self.m, "_beat_argv", return_value=["/nonexistent/egress-beat"]):
            self.m._start_beats()
        self.assertIn("the beat program could not be started", self.m.beat_failure or "")
        self.assertIsNone(self.m.beat_proc)
        self.assertEqual(self.m.beats, [])
        self.assertFalse(os.path.exists(self.m.beat_program), "a copy that is no use must not be left behind")
        out = self.m.judge()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("could not check that this Mac reports every connection", out["why"])

    def test_a_seen_outside_connection_stays_not_clean_when_the_program_ended_badly(self):
        self.start(SH_LOOP_OK + "; exit 5")
        self.m._beat_reported(egress.BEAT_PORT + 1, 1)
        self.m._stop_beats()
        self.m.proc = FakeStream([report(700, 443, self.m.tag)])
        with mock.patch.object(self.m, "_name", side_effect=lambda pid, port: (["203.0.113.7"], None, [])):
            self.m._read()
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertIn("203.0.113.7 port 443", out["why"])
        self.assertIn("there may have been more", out["why"])
        self.assertIn("exit 5", out["why"])

    def test_a_copy_that_cannot_be_signed_is_a_failure_and_never_raises(self):
        refused = egress.subprocess.CompletedProcess(["codesign"], 1, "", "egress-beat: no identity found")
        with mock.patch.object(egress.subprocess, "run", return_value=refused):
            self.m._start_beats()
        self.assertIn("could not be signed", self.m.beat_failure or "")
        self.assertIn("no identity found", self.m.beat_failure)
        self.assertIsNone(self.m.beat_proc)
        self.assertFalse(os.path.exists(self.m.beat_program), "a copy that is no use must not be left behind")

    def test_a_copy_still_signed_by_apple_is_refused(self):
        # Apple signed programs were never withheld, so a beat from one would prove nothing.
        def codesign(cmd, **kw):
            said = "Signature size=4442\nAuthority=Software Signing\n" if "--display" in cmd else ""
            return egress.subprocess.CompletedProcess(cmd, 0, "", said)

        with mock.patch.object(egress.subprocess, "run", side_effect=codesign):
            self.m._start_beats()
        self.assertIn("is not ad hoc signed", self.m.beat_failure or "")
        self.assertIsNone(self.m.beat_proc)

    def test_the_heartbeat_beats_until_stopped_and_leaves_nothing_behind(self):
        self.start()
        with mock.patch.object(egress, "BEAT_EVERY_S", 0.01):
            self.m._start_heartbeat()
            with self.m.cond:
                self.assertTrue(self.m.cond.wait_for(lambda: len(self.m.beats) >= 4, timeout=20))
            proc = self.m.beat_proc
            self.m._stop_beats()
        self.assertFalse(self.m.beat_thread.is_alive())
        self.assertIsNotNone(proc.poll(), "the beat program was left running")
        self.assertFalse(os.path.exists(self.m.beat_program))
        self.assertIsNone(self.m.beat_failure)

    def test_settling_waits_for_a_late_report_and_never_past_its_limit(self):
        self.start()
        with mock.patch.object(egress, "SETTLE_S", 0.3):
            began = egress.time.monotonic()
            self.m._settle()  # the one beat is never reported: the wait must end by itself
            self.assertLess(egress.time.monotonic() - began, 5)
        # A second test connection whose report comes a fifth of a second late, with the stream
        # still open: the wait must last until it comes, and end then, not at its limit of 8 s.
        self.m._beat_reported(egress.BEAT_PORT + 1, 1)
        self.m._beat()
        late = threading.Timer(0.2, self.m._beat_reported, (egress.BEAT_PORT + 2, 1))
        with mock.patch.object(egress, "SETTLE_S", 8):
            late.start()
            began = egress.time.monotonic()
            self.m._settle()
            waited = egress.time.monotonic() - began
        late.join()
        self.assertGreater(waited, 0.1, "settling returned before the late report had come")
        self.assertLess(waited, 4, "settling went on after the late report had come")
        self.assertTrue(all(b["seen"] for b in self.m.beats))
        with mock.patch.object(egress, "SETTLE_S", 8):
            began = egress.time.monotonic()
            self.m._settle()  # everything is reported and the stream is open: nothing to wait for
            self.assertLess(egress.time.monotonic() - began, 4)


class Attaching(unittest.TestCase):
    """The stream is shown to be attached by an Apple signed program, which was never withheld, before
    the first test connection: a report missed because the stream was not attached yet is not a Mac
    that withholds reports (measured: 1 of 27 starts lost its first canary that way)."""

    def test_attach_probes_are_fired_until_one_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            m = egress.Monitor(tmp, RID, list(v.EGRESS_LOCAL_HOSTS), 30)

            def fire():
                m.attach_fired += 1
                tag = "%s-%d" % (m.attach_tag, m.attach_fired)
                if m.attach_fired == 3:
                    m.attach_seen.add(tag)
                return tag

            with mock.patch.object(m, "_fire_attach", side_effect=fire), \
                    mock.patch.object(egress, "ATTACH_RETRY_S", 0.01):
                self.assertTrue(m._attached())
            self.assertEqual(m.attach_fired, 3)
            fired(m, 1)
            m.proc = FakeStream([beat_report(m, 1)])
            m._read()
            out = m.judge()
            # Unseen attach probes are counted in the receipt and are not a withheld report.
            self.assertEqual((out["verdict"], out["attach"]), ("clean", {"fired": 3, "seen": 1}), out)

    def test_a_stream_that_never_attaches_is_unavailable_and_says_so(self):
        with tempfile.TemporaryDirectory() as tmp:
            m = egress.Monitor(tmp, RID, list(v.EGRESS_LOCAL_HOSTS), 0.2)
            ran = egress.subprocess.CompletedProcess(["attach"], 0, "", "")
            with mock.patch.object(egress.subprocess, "run", return_value=ran), \
                    mock.patch.object(egress, "ATTACH_RETRY_S", 0.01):
                self.assertFalse(m._attached())
            self.assertGreater(m.attach_fired, 1)

    def test_an_attach_report_is_read_by_its_own_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            m = egress.Monitor(tmp, RID, list(v.EGRESS_LOCAL_HOSTS), 30)
            m.proc = FakeStream([report(88, 9, m.tag + "-attach-1", process="bash")])
            m._read()
            self.assertEqual(m.attach_seen, {m.tag + "-attach-1"})
            self.assertEqual(m.reports, [])

    def test_a_refused_line_under_an_attach_tag_shows_nothing_attached(self):
        # The report pattern matches a refusal too (claude-config#3319). The attach canary's profile
        # refuses nothing, so only a report under its tag shows the stream attached.
        with tempfile.TemporaryDirectory() as tmp:
            m = egress.Monitor(tmp, RID, list(v.EGRESS_LOCAL_HOSTS), 30)
            m.proc = FakeStream([refusal(88, m.tag + "-attach-1", process="bash", port=9)])
            m._read()
            self.assertEqual(m.attach_seen, set())
            self.assertEqual((m.reports, m.refusals), ([], []))


class ExitStatuses(unittest.TestCase):
    """A tool that failed is a failure to read, never an answer (L184)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.m = egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 30)

    def tearDown(self):
        self.tmp.cleanup()

    def lsof(self, code, out="", err=""):
        done = egress.subprocess.CompletedProcess(["lsof"], code, out, err)
        with mock.patch.object(egress.subprocess, "run", return_value=done):
            return self.m._name(77, 443)

    def test_lsof_finding_the_socket(self):
        self.assertEqual(self.lsof(0, "p77\nn10.0.0.2:5->203.0.113.1:443\n"), (["203.0.113.1"], None, []))

    def test_lsof_finding_a_connection_to_this_machine(self):
        self.assertEqual(self.lsof(0, "p77\nn127.0.0.1:5->127.0.0.1:443\nn[::1]:6->[::1]:443\n"),
                         ([], None, ["127.0.0.1", "::1"]))

    def test_lsof_finding_nothing_is_an_answer(self):
        self.assertEqual(self.lsof(1), ([], None, []))

    def test_lsof_failing_is_a_naming_error(self):
        names, why, here = self.lsof(1, err="lsof: WARNING: can't stat() vmhgfs file system")
        self.assertEqual((names, here), ([], []))
        self.assertIn("lsof exited 1", why)
        names, why, here = self.lsof(2, out="p77\nn127.0.0.1:5->127.0.0.1:443\n", err="lsof: illegal option")
        self.assertEqual((names, here), ([], []))
        self.assertIn("lsof exited 2", why)

    def test_a_stream_that_dies_right_after_the_start_canary_is_unavailable(self):
        class Died:
            stdout = io.BytesIO(b"")
            pid = 0
            returncode = 3

            def poll(self):
                return 3

        with mock.patch.object(egress.sys, "platform", "darwin"), \
                mock.patch.object(egress.os, "access", return_value=True), \
                mock.patch.object(egress.subprocess, "Popen", return_value=Died()), \
                mock.patch.object(self.m, "_attached", return_value=True), \
                mock.patch.object(self.m, "_start_beats"), \
                mock.patch.object(self.m, "_canary_seen", return_value=True):
            why = self.m.start()
        self.assertIn("exited with 3 right after the start canary", why or "")
        self.assertIsNone(self.m.started_at)
        self.assertEqual(self.m.finish()["verdict"], "unmeasured")


class CanaryIdentity(unittest.TestCase):
    def test_an_earlier_canarys_report_never_proves_a_later_one(self):
        # The start canary ran as pid 500 and was seen; macOS gives the end canary pid 500 again, and
        # no report of the end canary arrives. The end must not count as proved (the #1571 review).
        with tempfile.TemporaryDirectory() as tmp:
            m = egress.Monitor(tmp, RID, list(v.EGRESS_LOCAL_HOSTS), 0.3)
            with mock.patch.object(egress.subprocess, "run", side_effect=canary_runs()):
                m.canaries_seen.update(m._fire_canary())  # the start canary's whole round, seen
                self.assertFalse(m._canary_seen())
            self.assertGreater(m.canaries_fired, 1)
            with open(m.canary_profile) as f:
                self.assertIn(m.canary_tag + "-%d" % m.canaries_fired, f.read())


class StopBudget(unittest.TestCase):
    def test_a_stop_waits_long_enough_to_settle_egress(self):
        # Waiting less than the egress monitor's own finish can take would report a supervisor that
        # is still settling egress as hung (the #1571 review).
        t = {"stop_s": 10, "egress_s": 30}
        self.assertGreaterEqual(run_session.stop_wait_s(t), 2 * 10 + egress.finish_budget_s(30))
        self.assertGreaterEqual(egress.finish_budget_s(30), 30 + egress.CANARY_RUN_MAX_S + 2 * egress.STREAM_STOP_S)

    def test_the_budget_covers_the_test_connections_at_the_end_of_a_run(self):
        # finish stops the heartbeat (which may be mid connection), makes one more, waits for late
        # reports and ends the beat program, all before the stream is stopped (claude-config#3576).
        beats = 2 * egress.BEAT_RUN_MAX_S + egress.SETTLE_S + egress.BEAT_STOP_S
        self.assertGreaterEqual(egress.finish_budget_s(30), 30 + egress.CANARY_RUN_MAX_S + 2 * egress.STREAM_STOP_S + beats)

    def test_the_budget_covers_a_whole_round_of_canaries_and_the_test_connections_together(self):
        # Two changes each lengthened the budget, one for the three processes of a round (#3319) and
        # one for the test connections (#3576). A finish can need both, so neither replaces the other.
        beats = 2 * egress.BEAT_RUN_MAX_S + egress.SETTLE_S + egress.BEAT_STOP_S
        self.assertEqual(len(egress.CANARY_PARTS), 3)
        self.assertGreaterEqual(egress.finish_budget_s(30),
                                30 + 3 * egress.CANARY_RUN_MAX_S + 2 * egress.STREAM_STOP_S + beats)

    def test_a_copy_of_areas_json_from_before_egress_s_still_has_a_budget(self):
        self.assertGreater(run_session.stop_wait_s({"stop_s": 10}), 2 * 10 + 30)


if __name__ == "__main__":
    unittest.main()
