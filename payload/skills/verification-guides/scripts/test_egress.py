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


class FakeStream:
    def __init__(self, lines):
        self.stdout = io.BytesIO(b"".join(lines))
        self.pid = 0

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
        with mock.patch.object(self.m, "_name", side_effect=lambda pid, port: (names.get(pid, []), None)):
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
                                           "name_error": None}])
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
        with mock.patch.object(self.m, "_name", side_effect=lambda pid, port: ((names or {}).get(pid, []), None)):
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

    def test_a_canary_never_seen_is_unmeasured_and_counted(self):
        # What main hid: nine canaries fired, only the ninth reported, and the run read clean.
        fired(self.m, 1)
        self.m.canaries_fired = 9
        self.read([beat_report(self.m, 1), report(501, 9, self.m.canary_tag + "-9", process="Python")])
        out = self.m.judge()
        self.assertEqual(out["verdict"], "unmeasured", out)
        self.assertIn("this Mac did not report every connection it was asked to report", out["why"])
        self.assertIn("8 of the 9 canaries", out["why"])
        self.assertEqual(out["canaries"], {"fired": 9, "seen": 1})

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
        with mock.patch.object(self.m, "_name", side_effect=lambda pid, port: (["203.0.113.7"], None)):
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
        self.assertEqual(self.lsof(0, "p77\nn10.0.0.2:5->203.0.113.1:443\n"), (["203.0.113.1"], None))

    def test_lsof_finding_nothing_is_an_answer(self):
        self.assertEqual(self.lsof(1), ([], None))

    def test_lsof_failing_is_a_naming_error(self):
        names, why = self.lsof(1, err="lsof: WARNING: can't stat() vmhgfs file system")
        self.assertEqual(names, [])
        self.assertIn("lsof exited 1", why)
        names, why = self.lsof(2, err="lsof: illegal option")
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
            ran = egress.subprocess.CompletedProcess(["canary"], 0, "500\n", "")
            with mock.patch.object(egress.subprocess, "run", return_value=ran):
                m.canaries_seen.add(m._fire_canary())  # the start canary, seen
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

    def test_a_copy_of_areas_json_from_before_egress_s_still_has_a_budget(self):
        self.assertGreater(run_session.stop_wait_s({"stop_s": 10}), 2 * 10 + 30)


class FakeEnding:
    """A report stream whose ending the test sets: `early` is what poll() says before anything stops
    it, `status` how it ends once stopped, and `hangs` makes a timed wait run out."""

    def __init__(self, early=None, status=-15, hangs=False):
        self.pid, self.early, self.status, self.hangs = 4321, early, status, hangs

    def poll(self):
        return self.early

    def wait(self, timeout=None):
        if self.hangs and timeout is not None:
            raise egress.subprocess.TimeoutExpired("log", timeout)
        self.early = self.status
        return self.status


class StreamEnding(unittest.TestCase):
    """How the report stream ended is read and kept when it is stopped (claude-config#3663), and
    it changes nothing about the verdict."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.m = egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 30)

    def tearDown(self):
        self.tmp.cleanup()

    def stop(self, stream):
        self.m.proc = stream
        with mock.patch.object(egress.os, "killpg") as killpg:
            self.m.stop_stream()
        return killpg

    def ended_events(self):
        with open(self.m.events_path) as f:
            return [json.loads(line) for line in f if '"stream-ended"' in line]

    def test_a_stream_it_stops_is_read_as_it_ends(self):
        killpg = self.stop(FakeEnding(status=-15))
        self.assertEqual(self.m.stream_exit, {"exit": -15, "early": False, "killed": False})
        self.assertEqual(killpg.call_args_list, [mock.call(4321, egress.signal.SIGTERM)])
        self.assertEqual([(e["exit"], e["early"], e["killed"]) for e in self.ended_events()], [(-15, False, False)])

    def test_a_stream_that_had_ended_by_itself_is_kept_as_such(self):
        killpg = self.stop(FakeEnding(early=1))
        self.assertEqual(self.m.stream_exit, {"exit": 1, "early": True, "killed": False})
        killpg.assert_not_called()

    def test_a_stream_that_will_not_end_is_killed_and_read(self):
        stream = FakeEnding(status=-9, hangs=True)
        self.m.proc = stream
        with mock.patch.object(egress.os, "killpg") as killpg:
            with mock.patch.object(stream, "wait", side_effect=[egress.subprocess.TimeoutExpired("log", 1), -9]):
                self.m.stop_stream()
        self.assertEqual(self.m.stream_exit, {"exit": -9, "early": False, "killed": True})
        self.assertEqual(killpg.call_args_list[-1], mock.call(4321, egress.signal.SIGKILL))

    def test_a_second_stop_keeps_the_first_reading(self):
        stream = FakeEnding(status=-15)
        self.stop(stream)
        self.stop(stream)  # finish() stops the stream again in its finally
        self.assertEqual(self.m.stream_exit, {"exit": -15, "early": False, "killed": False})
        self.assertEqual(len(self.ended_events()), 1)

    def test_the_verdict_is_the_same_however_the_stream_ended(self):
        verdicts = []
        for stream in (FakeEnding(status=-15), FakeEnding(early=1), FakeEnding(early=0)):
            m = egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 30)
            fired(m, 1)
            m.beats[0]["seen"] = True
            m.started_at = "2026-11-26T10:00:00Z"
            m.proc = stream
            with mock.patch.object(m, "_last_beat"), mock.patch.object(m, "_canary_seen", return_value=True), \
                    mock.patch.object(m, "_settle"), mock.patch.object(m, "_stop_beats"), \
                    mock.patch.object(egress.os, "killpg"):
                verdicts.append(m.finish())
        self.assertEqual(verdicts[0]["verdict"], "clean")
        self.assertEqual(verdicts[1], verdicts[0])
        self.assertEqual(verdicts[2], verdicts[0])


if __name__ == "__main__":
    unittest.main()
