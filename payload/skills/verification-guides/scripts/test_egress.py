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


class Refusals(unittest.TestCase):
    """The one connection the sandbox refuses (claude-config#3319): a UDP connect to port 443 off this
    machine by the helper browser a drive call starts. A refusal is written into the record, counted
    apart from a connection that left, and never hides one. The same rules against a real sandbox,
    and a real browser, are EgressTests in test_run_session.py."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.m = egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 30)
        # A case here that fails after a monitor really started must not leave its report stream
        # running: the red run of these cases left one behind for 23 minutes.
        self.addCleanup(self.m.stop_stream)
        self.refused_tag = self.m.tag + "-refused"

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, lines, names=None):
        self.m.proc = FakeStream(lines)
        with mock.patch.object(self.m, "_name", side_effect=lambda pid, port: ((names or {}).get(pid, []), None)):
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
                m = egress.Monitor(tempfile.mkdtemp(dir=self.tmp.name), RID, list(v.EGRESS_LOCAL_HOSTS), 30)
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
                m = egress.Monitor(tempfile.mkdtemp(dir=self.tmp.name), RID, list(v.EGRESS_LOCAL_HOSTS), 30)
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
                m = egress.Monitor(tempfile.mkdtemp(dir=self.tmp.name), RID,
                                   list(v.EGRESS_LOCAL_HOSTS) + ["192.0.2.1"], 30)
                tag = m.tag + ("-refused" if message == "refused" else "")
                line = (report(770, 443, tag, process="chrome-headless-shell") if word == "allow"
                        else refusal(770, tag))
                m.proc = FakeStream([line])
                with mock.patch.object(m, "_name", return_value=(["192.0.2.1"], None)):
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
        m = egress.Monitor(self.tmp.name, RID, list(v.EGRESS_LOCAL_HOSTS), 5)
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

    def test_a_copy_of_areas_json_from_before_egress_s_still_has_a_budget(self):
        self.assertGreater(run_session.stop_wait_s({"stop_s": 10}), 2 * 10 + 30)


if __name__ == "__main__":
    unittest.main()
