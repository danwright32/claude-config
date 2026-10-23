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

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, lines, names):
        self.m.proc = FakeStream(lines)
        with mock.patch.object(self.m, "_name", side_effect=lambda pid, port: (names.get(pid, []), None)):
            self.m._read()

    def test_a_reused_canary_pid_never_hides_a_real_connection(self):
        # The canary exits at once and macOS hands its pid to serve, which then reaches an outside host.
        self.read([report(500, 9, self.m.canary_tag, process="Python"), report(500, 443, self.m.tag)],
                  {500: ["203.0.113.7"]})
        self.assertEqual(self.m.canaries_seen, {500})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean", out)
        self.assertEqual([(d["address"], d["port"]) for d in out["destinations"]], [("203.0.113.7", 443)])

    def test_canary_reports_alone_are_clean(self):
        self.read([report(501, 9, self.m.canary_tag, process="Python")], {})
        out = self.m.judge()
        self.assertEqual((out["verdict"], out["destinations"], out["unnamed"]), ("clean", [], []))

    def test_another_runs_reports_are_not_counted(self):
        self.read([report(502, 443, "vg-egress-20261023T230000Z-7654321-fedcba")], {502: ["203.0.113.8"]})
        self.assertEqual(self.m.judge()["verdict"], "clean")

    def test_duplicates_count_and_unnamed_is_never_clean(self):
        self.read([report(503, 443, self.m.tag), report(503, 443, self.m.tag, dupes=4)], {})
        out = self.m.judge()
        self.assertEqual(out["verdict"], "not-clean")
        self.assertEqual(out["unnamed"], [{"process": "node", "port": 443, "reports": 5, "pids": [503]}])
        self.assertIn("port 443", out["why"])

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
