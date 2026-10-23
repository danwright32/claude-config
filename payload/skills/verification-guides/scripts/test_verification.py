"""Tests for verification.py, the one shared reader of every verification file (claude-config#1528).

The merge check of #1529 parses records, buckets files and reads guides through this same module,
so each refusal here is one that check inherits. Every refusal is seen on a fixture built to trip
it, and its kind is asserted, because distinct causes must stay distinct messages (L11).
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import verification as v  # noqa: E402

SHA = "0123456789abcdef0123456789abcdef01234567"
OTHER_SHA = "fedcba9876543210fedcba9876543210fedcba98"
RECEIPT_ID = "20261022T230000Z-0123456-a1b2c3"

GUIDE = """# Invoices verification guide

## Roles
An owner with two clients and one sent invoice.

## Reach
Open /invoices from the sidebar.

## State setup
Seed the demo dataset.

## Checks
- [C1] The list shows every sent invoice with its client name.
- [C2] Opening an invoice shows its line items and total.
- [C3] A draft can be sent and then reads as sent.

## Known traps
The list is cached for a minute after a send.
"""


def areas_doc(**over):
    doc = {
        "schema": "verification-areas/1",
        "mode": "warn",
        "url": "http://127.0.0.1:4173",
        "commands": {
            "serve": "pnpm preview --port 4173",
            "ready": "curl -fsS http://127.0.0.1:4173/ >/dev/null",
            "stop": "true",
            "drive": "node scripts/verify-drive.mjs",
        },
        "areas": [
            {"name": "invoices", "guide": ".claude/verification/guides/invoices.md",
             "owns": ["src/routes/invoices/**", "src/api/invoices.ts"]},
            {"name": "clients", "guide": ".claude/verification/guides/clients.md",
             "owns": ["src/routes/clients/**"]},
        ],
        "exempt": [{"glob": "docs/**", "why": "documentation only"}],
    }
    doc.update(over)
    return doc


def kinds_of(err):
    return sorted({p[0] for p in err.problems})


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class AreasTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        write(os.path.join(self.root, ".claude/verification/guides/invoices.md"), GUIDE)
        write(os.path.join(self.root, ".claude/verification/guides/clients.md"), GUIDE)

    def tearDown(self):
        self.tmp.cleanup()

    def load(self, doc):
        return v.parse_areas(json.dumps(doc), root=self.root)

    def refused(self, doc_or_text, kind):
        text = doc_or_text if isinstance(doc_or_text, str) else json.dumps(doc_or_text)
        with self.assertRaises(v.VerificationError) as cm:
            v.parse_areas(text, root=self.root)
        self.assertIn(kind, kinds_of(cm.exception), cm.exception.problems)
        return cm.exception

    def test_a_good_file_loads_with_defaults(self):
        areas = self.load(areas_doc())
        self.assertEqual([a["name"] for a in areas["areas"]], ["invoices", "clients"])
        self.assertEqual(areas["timeouts"]["max_run_s"], 3600)
        self.assertEqual(areas["mode"], "warn")

    def test_missing_file_is_its_own_cause(self):
        with self.assertRaises(v.VerificationError) as cm:
            v.load_areas(os.path.join(self.root, "nope.json"))
        self.assertEqual(kinds_of(cm.exception), ["areas-missing"])
        self.assertEqual(cm.exception.code, 3)

    def test_not_json(self):
        err = self.refused('{"schema": ', "areas-not-json")
        self.assertEqual(err.code, 4)

    def test_not_an_object(self):
        self.refused("[]", "areas-not-object")

    def test_unsupported_schema(self):
        self.refused(areas_doc(schema="verification-areas/2"), "areas-schema-unsupported")

    def test_missing_key_names_the_key(self):
        doc = areas_doc()
        del doc["commands"]
        err = self.refused(doc, "areas-missing-key")
        self.assertIn("commands", " ".join(m for _, m in err.problems))

    def test_each_command_is_required(self):
        for name in ("serve", "ready", "stop", "drive"):
            doc = areas_doc()
            del doc["commands"][name]
            err = self.refused(doc, "areas-missing-key")
            self.assertIn("commands." + name, " ".join(m for _, m in err.problems))

    def test_empty_command(self):
        doc = areas_doc()
        doc["commands"]["serve"] = "   "
        self.refused(doc, "areas-empty-command")

    def test_wrong_type(self):
        self.refused(areas_doc(areas={"invoices": {}}), "areas-wrong-type")

    def test_bad_mode(self):
        self.refused(areas_doc(mode="enforce"), "areas-bad-mode")

    def test_url_must_be_this_machine(self):
        self.refused(areas_doc(url="https://app.example.com"), "areas-url-not-local")
        self.load(areas_doc(url="http://localhost:3000/app"))

    def test_bad_area_name(self):
        doc = areas_doc()
        doc["areas"][0]["name"] = "Invoices Page"
        self.refused(doc, "areas-bad-area-name")

    def test_duplicate_area(self):
        doc = areas_doc()
        doc["areas"][1]["name"] = "invoices"
        self.refused(doc, "areas-duplicate-area")

    def test_area_with_no_owns(self):
        doc = areas_doc()
        doc["areas"][0]["owns"] = []
        self.refused(doc, "areas-no-owns")

    def test_bad_globs(self):
        for glob in ("/abs/**", "src/../x", "src/{a,b}.ts", "src/[ab].ts", "", "src/a**b"):
            doc = areas_doc()
            doc["areas"][0]["owns"] = [glob]
            self.refused(doc, "areas-bad-glob")

    def test_guide_path_shape(self):
        doc = areas_doc()
        doc["areas"][0]["guide"] = "../guides/invoices.md"
        self.refused(doc, "areas-bad-guide-path")

    def test_guide_must_exist(self):
        doc = areas_doc()
        doc["areas"][0]["guide"] = ".claude/verification/guides/missing.md"
        self.refused(doc, "areas-guide-missing")

    def test_exempt_needs_a_reason(self):
        self.refused(areas_doc(exempt=[{"glob": "docs/**"}]), "areas-exempt-no-why")

    def test_bad_timeout(self):
        self.refused(areas_doc(timeouts={"ready_s": 0}), "areas-bad-timeout")
        self.refused(areas_doc(timeouts={"ready_s": 600, "max_run_s": 300}), "areas-bad-timeout")

    def test_every_problem_is_reported_at_once(self):
        doc = areas_doc(mode="nope")
        doc["areas"][0]["owns"] = []
        err = self.refused(doc, "areas-bad-mode")
        self.assertIn("areas-no-owns", kinds_of(err))

    def test_unknown_keys_are_allowed_for_additive_versions(self):
        self.load(areas_doc(note="kept for later"))


class GlobAndBucketTests(unittest.TestCase):
    def setUp(self):
        self.areas = {
            "areas": [
                {"name": "invoices", "owns": ["src/routes/invoices/**", "src/api/*.ts"]},
                {"name": "clients", "owns": ["src/routes/clients/**", "src/api/clients.ts"]},
            ],
            "exempt": [{"glob": "**/*.md", "why": "docs"}],
        }

    def test_globs(self):
        m = v.glob_matches
        self.assertTrue(m("src/routes/invoices/**", "src/routes/invoices/a/b.ts"))
        self.assertTrue(m("src/routes/invoices/**", "src/routes/invoices/index.ts"))
        self.assertFalse(m("src/routes/invoices/**", "src/routes/invoicesX/index.ts"))
        self.assertTrue(m("src/api/*.ts", "src/api/x.ts"))
        self.assertFalse(m("src/api/*.ts", "src/api/deep/x.ts"))
        self.assertTrue(m("**/*.md", "README.md"))
        self.assertTrue(m("**/*.md", "a/b/c.md"))
        self.assertTrue(m("src/?.ts", "src/a.ts"))
        self.assertFalse(m("src/?.ts", "src/ab.ts"))
        self.assertFalse(m("src/a.ts", "src/a.tsx"))

    def test_every_file_lands_in_exactly_one_bucket(self):
        out = v.bucket(self.areas, ["src/routes/invoices/x.ts", "README.md", "src/api/x.ts"])
        self.assertEqual([f["bucket"] for f in out["files"]], ["area:invoices", "exempt", "area:invoices"])
        self.assertEqual(out["unowned"], [])
        self.assertEqual(out["ambiguous"], [])
        self.assertEqual(out["touched_areas"], ["invoices"])

    def test_unowned_and_ambiguous_are_named(self):
        out = v.bucket(self.areas, ["lib/x.ts", "src/api/clients.ts"])
        self.assertEqual(out["unowned"], ["lib/x.ts"])
        self.assertEqual(out["ambiguous"], [{"path": "src/api/clients.ts",
                                             "buckets": ["area:invoices", "area:clients"]}])
        self.assertIsNone(out["files"][0]["bucket"])


class GuideTests(unittest.TestCase):
    def test_template_shape_parses(self):
        g = v.parse_guide(GUIDE)
        self.assertEqual([c["id"] for c in g["checks"]], ["C1", "C2", "C3"])
        self.assertTrue(g["checks"][1]["text"].startswith("Opening an invoice"))

    def test_shipped_template_is_a_valid_shape_once_filled(self):
        with open(os.path.join(HERE, "..", "guide-template.md")) as f:
            tmpl = f.read()
        for heading in v.GUIDE_SECTIONS:
            self.assertIn("## " + heading, tmpl)

    def refused(self, text, kind):
        with self.assertRaises(v.VerificationError) as cm:
            v.parse_guide(text)
        self.assertIn(kind, kinds_of(cm.exception), cm.exception.problems)

    def test_missing_section(self):
        self.refused(GUIDE.replace("## Known traps", "## Notes"), "guide-missing-section")

    def test_too_few_and_too_many_checks(self):
        two = GUIDE.replace("- [C3] A draft can be sent and then reads as sent.\n", "")
        self.refused(two, "guide-check-count")
        many = GUIDE.replace("- [C3] A draft can be sent and then reads as sent.\n",
                             "".join("- [C%d] Check %d holds.\n" % (i, i) for i in range(3, 8)))
        self.refused(many, "guide-check-count")

    def test_duplicate_and_malformed_check_ids(self):
        self.refused(GUIDE.replace("[C3]", "[C2]"), "guide-duplicate-check")
        self.refused(GUIDE.replace("- [C3] A draft", "- A draft"), "guide-bad-check-line")


class DoneWhenTests(unittest.TestCase):
    def test_items_are_numbered_in_order(self):
        body = "Intro\n\n## Done when\n- [ ] The list loads\n- [x] Sending works\n* Totals add up\n\n## Notes\n- not this\n"
        self.assertEqual(v.done_when_items(body), [
            {"id": "D1", "text": "The list loads"},
            {"id": "D2", "text": "Sending works"},
            {"id": "D3", "text": "Totals add up"},
        ])

    def test_no_section_is_no_items(self):
        self.assertEqual(v.done_when_items("Closes #1\n"), [])
        self.assertEqual(v.done_when_items(None), [])


def good_record(**over):
    rec = {
        "schema": "verification-run/1",
        "area": "invoices",
        "head_sha": SHA,
        "receipt_id": RECEIPT_ID,
        "machine": "test-mac",
        "runner_agent_id": "a68029cdc4459702f",
        "checks": [
            {"id": "C1", "text": "The list shows every sent invoice.", "result": "pass", "note": "saw 3 of 3"},
            {"id": "C2", "text": "Opening shows line items.", "result": "fail", "note": "total missing",
             "blame": "code"},
        ],
        "done_when": [{"id": "D1", "text": "The list loads", "result": "pass", "note": "loaded"}],
        "screenshots": ["C1-list.png"],
        "guide_edits": [],
    }
    rec.update(over)
    return rec


def comment_with(*objs, raw=None):
    parts = ["Some words first.\n"]
    for o in objs:
        parts.append("```verification-run\n" + json.dumps(o) + "\n```\n")
    if raw is not None:
        parts.append("```verification-run\n" + raw + "\n```\n")
    return "\n".join(parts)


class RecordParseTests(unittest.TestCase):
    def test_a_good_record_parses_and_its_verdict_is_derived(self):
        out = v.parse_comment(comment_with(good_record()))
        self.assertEqual(out["invalid"], [])
        self.assertEqual(len(out["records"]), 1)
        self.assertFalse(out["records"][0]["passed"])
        passing = good_record(checks=[good_record()["checks"][0]])
        self.assertTrue(v.parse_comment(comment_with(passing))["records"][0]["passed"])

    def test_no_block_is_its_own_cause(self):
        with self.assertRaises(v.VerificationError) as cm:
            v.parse_comment("just prose\n")
        self.assertEqual(kinds_of(cm.exception), ["record-none"])

    def test_malformed_json_is_reported_not_skipped(self):
        out = v.parse_comment(comment_with(good_record(), raw='{"schema": "verification-run/1",'))
        self.assertEqual(len(out["records"]), 1)
        self.assertEqual(out["invalid"][0]["errors"][0][0], "record-not-json")

    def test_each_malformation_has_its_kind(self):
        cases = [
            (good_record(schema="verification-run/2"), "record-schema-unsupported"),
            (good_record(head_sha="abc"), "record-bad-field"),
            (good_record(checks=[]), "record-no-checks"),
            (good_record(checks=[dict(good_record()["checks"][0], result="ok")]), "record-bad-result"),
            (good_record(checks=[dict(good_record()["checks"][0], note="two\nlines")]), "record-bad-note"),
            (good_record(checks=[dict(good_record()["checks"][0], note="")]), "record-bad-note"),
            (good_record(checks=[good_record()["checks"][0], good_record()["checks"][0]]), "record-duplicate-id"),
            (good_record(checks=[dict(good_record()["checks"][1], blame=None)]), "record-missing-blame"),
            (good_record(checks=[dict(good_record()["checks"][0], blame="code")]), "record-blame-on-pass"),
            (good_record(checks=[dict(good_record()["checks"][1], blame="guide")]), "record-guide-blame-without-edit"),
            (good_record(screenshots=["../x.png"]), "record-bad-screenshot"),
            (good_record(guide_edits=[{"check_id": "C9", "old": "a", "new": "b", "why": "c"}]), "record-bad-guide-edit"),
        ]
        rec = good_record()
        del rec["runner_agent_id"]
        cases.append((rec, "record-missing-key"))
        for obj, kind in cases:
            out = v.parse_comment(comment_with(obj))
            self.assertEqual(out["records"], [], kind)
            self.assertIn(kind, [k for k, _ in out["invalid"][0]["errors"]], (kind, out["invalid"]))

    def test_a_list_or_object_where_a_string_belongs_is_named_not_a_crash(self):
        c0 = good_record()["checks"][0]
        cases = [
            (good_record(checks=[dict(c0, id=["C1"])]), "record-bad-field"),
            (good_record(guide_edits=[{"check_id": ["C1"], "old": "a", "new": "b", "why": "c"}]), "record-bad-guide-edit"),
            (good_record(screenshots=[["x.png"]]), "record-bad-screenshot"),
            (good_record(area=["invoices"]), "record-bad-field"),
            (good_record(checks=[dict(c0, result=["pass"])]), "record-bad-result"),
            (good_record(checks=[dict(good_record()["checks"][1], blame=["code"])]), "record-missing-blame"),
            (good_record(checks=[dict(good_record()["checks"][1], id=["C2"], blame="guide")]), "record-bad-field"),
            (good_record(checks=[dict(good_record()["checks"][1], id={"x": 1}, blame="guide")]), "record-bad-field"),
        ]
        for obj, kind in cases:
            out = v.parse_comment(comment_with(obj))
            self.assertIn(kind, [k for k, _ in out["invalid"][0]["errors"]], (kind, out["invalid"]))

    def test_unknown_keys_are_allowed(self):
        out = v.parse_comment(comment_with(good_record(extra="later field")))
        self.assertEqual(out["invalid"], [])

    def test_a_record_from_another_sha_is_named(self):
        out = v.parse_comment(comment_with(good_record(head_sha=OTHER_SHA)), sha=SHA)
        self.assertFalse(out["records"][0]["sha_matches"])
        self.assertEqual(out["matching"], [])

    def test_several_records_in_one_comment(self):
        out = v.parse_comment(comment_with(good_record(), good_record(area="clients")), sha=SHA)
        self.assertEqual([r["area"] for r in out["matching"]], ["invoices", "clients"])


class CliTests(unittest.TestCase):
    def run_cli(self, *args, stdin=""):
        return subprocess.run([sys.executable, os.path.join(HERE, "verification.py")] + list(args),
                              input=stdin, capture_output=True, text=True,
                              env=dict(os.environ, VERIFICATION_HOME=tempfile.gettempdir()))

    def test_record_parse_exit_codes_are_distinct(self):
        ok = self.run_cli("record", "parse", "--sha", SHA, stdin=comment_with(good_record()))
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertEqual(json.loads(ok.stdout)["matching"][0]["area"], "invoices")
        none = self.run_cli("record", "parse", stdin="nothing\n")
        self.assertEqual(none.returncode, 3)
        self.assertIn("record-none", none.stderr)
        bad = self.run_cli("record", "parse", stdin=comment_with(raw="{"))
        self.assertEqual(bad.returncode, 4)
        self.assertIn("record-not-json", bad.stderr)
        other = self.run_cli("record", "parse", "--sha", SHA, stdin=comment_with(good_record(head_sha=OTHER_SHA)))
        self.assertEqual(other.returncode, 6)
        self.assertIn("record-other-sha", other.stderr)

    def test_areas_validate_names_each_cause(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "areas.json")
            write(p, "{")
            r = self.run_cli("areas", "validate", p)
            self.assertEqual(r.returncode, 4)
            self.assertIn("areas-not-json", r.stderr)
            r = self.run_cli("areas", "validate", os.path.join(d, "none.json"))
            self.assertEqual(r.returncode, 3)
            self.assertIn("areas-missing", r.stderr)

    def test_bucket_exits_7_on_an_unowned_file(self):
        with tempfile.TemporaryDirectory() as d:
            write(os.path.join(d, ".claude/verification/guides/invoices.md"), GUIDE)
            write(os.path.join(d, ".claude/verification/guides/clients.md"), GUIDE)
            p = os.path.join(d, ".claude/verification/areas.json")
            write(p, json.dumps(areas_doc()))
            r = self.run_cli("bucket", p, stdin="src/routes/invoices/a.ts\ndocs/x.md\n")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(json.loads(r.stdout)["touched_areas"], ["invoices"])
            r = self.run_cli("bucket", p, stdin="lib/x.ts\n")
            self.assertEqual(r.returncode, 7)
            self.assertIn("bucket-unowned", r.stderr)

    def test_usage(self):
        self.assertEqual(self.run_cli().returncode, 2)
        self.assertEqual(self.run_cli("record", "frob").returncode, 2)


def transcript(path, first_content, agent_id, later=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(json.dumps({"parentUuid": None, "agentId": agent_id, "type": "user",
                            "message": {"role": "user", "content": first_content}}) + "\n")
        if later:
            f.write(json.dumps({"parentUuid": "x", "type": "assistant",
                                "message": {"content": [{"type": "text", "text": later}]}}) + "\n")


class WhoAmITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.nonce = v.new_nonce()

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_agent_whose_brief_holds_the_nonce(self):
        transcript(os.path.join(self.root, "proj/s1/subagents/agent-aaa111.jsonl"),
                   "Run brief. Nonce " + self.nonce, "aaa111")
        transcript(os.path.join(self.root, "proj/s1/subagents/agent-bbb222.jsonl"),
                   "Another brief", "bbb222", later="I dispatched " + self.nonce)
        self.assertEqual(v.find_agent_id(self.nonce, self.root), "aaa111")

    def test_content_as_a_list_of_blocks(self):
        transcript(os.path.join(self.root, "proj/s1/subagents/agent-ccc333.jsonl"),
                   [{"type": "text", "text": "brief " + self.nonce}], "ccc333")
        self.assertEqual(v.find_agent_id(self.nonce, self.root), "ccc333")

    def test_not_found_and_ambiguous_are_distinct(self):
        with self.assertRaises(v.VerificationError) as cm:
            v.find_agent_id(self.nonce, self.root)
        self.assertEqual(kinds_of(cm.exception), ["agent-not-found"])
        transcript(os.path.join(self.root, "p/s/subagents/agent-a1.jsonl"), self.nonce, "a1")
        transcript(os.path.join(self.root, "p/s/subagents/agent-a2.jsonl"), self.nonce, "a2")
        with self.assertRaises(v.VerificationError) as cm:
            v.find_agent_id(self.nonce, self.root)
        self.assertEqual(kinds_of(cm.exception), ["agent-ambiguous"])

    def test_a_malformed_nonce_is_refused(self):
        with self.assertRaises(v.VerificationError) as cm:
            v.find_agent_id("x", self.root)
        self.assertEqual(kinds_of(cm.exception), ["agent-bad-nonce"])


def stopped_receipt(home, **over):
    rdir = os.path.join(home, "receipts", RECEIPT_ID)
    os.makedirs(os.path.join(rdir, "guides"), exist_ok=True)
    rec = {
        "schema": "verification-receipt/1",
        "receipt_id": RECEIPT_ID,
        "machine": v.machine_name(),
        "repo": "/w/app",
        "head_sha": SHA,
        "checkout_sha": SHA,
        "areas": ["invoices"],
        "url": "http://127.0.0.1:4173",
        "started_at": "2026-10-22T23:00:00Z",
        "ready_at": "2026-10-22T23:00:05Z",
        "stopped_at": "2026-10-22T23:10:00Z",
        "stopped_by": "stop",
        "build_stamp": None,
        "build_stamp_source": "none",
        "egress": {"verdict": "unmeasured", "why": "no egress monitor"},
    }
    rec.update(over)
    write(os.path.join(rdir, "receipt.json"), json.dumps(rec))
    write(os.path.join(rdir, "guides", "invoices.md"), GUIDE)
    write(os.path.join(rdir, "C1-list.png"), "png")
    return rdir


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = os.path.join(self.tmp.name, "home")
        self.transcripts = os.path.join(self.tmp.name, "projects")
        self.nonce = v.new_nonce()
        transcript(os.path.join(self.transcripts, "p/s/subagents/agent-a9f9.jsonl"), "brief " + self.nonce, "a9f9")
        self.body = "## Done when\n- The list loads\n"

    def tearDown(self):
        self.tmp.cleanup()

    def draft(self, **area_over):
        area = {
            "area": "invoices",
            "checks": [
                {"id": "C1", "result": "pass", "note": "saw `3` of 3 | all"},
                {"id": "C2", "result": "pass", "note": "items and total"},
                {"id": "C3", "result": "fail", "note": "still reads draft", "blame": "guide"},
            ],
            "done_when": [{"id": "D1", "result": "pass", "note": "loaded"}],
            "screenshots": ["C1-list.png"],
            "guide_edits": [{"check_id": "C3", "new": "A draft can be sent and reads as sent after a reload.",
                             "why": "the list is cached, so the old check failed on correct code"}],
        }
        area.update(area_over)
        return {"receipt_id": RECEIPT_ID, "nonce": self.nonce, "areas": [area]}

    def render(self, draft):
        return v.render_comment(draft, home=self.home, transcripts=self.transcripts, pr_body=self.body)

    def refused(self, draft, kind):
        with self.assertRaises(v.VerificationError) as cm:
            self.render(draft)
        self.assertIn(kind, kinds_of(cm.exception), cm.exception.problems)

    def test_render_fills_measured_fields_and_round_trips(self):
        stopped_receipt(self.home)
        body = self.render(self.draft())
        out = v.parse_comment(body, sha=SHA)
        self.assertEqual(out["invalid"], [])
        rec = out["matching"][0]
        self.assertEqual(rec["runner_agent_id"], "a9f9")
        self.assertEqual(rec["machine"], v.machine_name())
        self.assertEqual(rec["checks"][0]["text"], "The list shows every sent invoice with its client name.")
        self.assertEqual(rec["checks"][0]["note"], "saw `3` of 3 | all")
        self.assertEqual(rec["done_when"][0]["text"], "The list loads")
        self.assertEqual(rec["guide_edits"][0]["old"], "A draft can be sent and then reads as sent.")
        self.assertFalse(rec["passed"])
        self.assertIn("Old check", body)
        self.assertIn("Why", body)

    def test_a_running_receipt_cannot_be_recorded(self):
        stopped_receipt(self.home, stopped_at=None, stopped_by=None)
        self.refused(self.draft(), "render-receipt-not-stopped")

    def test_a_receipt_from_another_machine(self):
        stopped_receipt(self.home, machine="someone-else")
        self.refused(self.draft(), "render-other-machine")

    def test_a_missing_receipt(self):
        self.refused(self.draft(), "receipt-missing")

    def test_checks_must_match_the_guide(self):
        stopped_receipt(self.home)
        d = self.draft()
        d["areas"][0]["checks"] = d["areas"][0]["checks"][:2]
        d["areas"][0]["guide_edits"] = []
        self.refused(d, "render-checks-mismatch")

    def test_done_when_must_match_the_pr(self):
        stopped_receipt(self.home)
        self.refused(self.draft(done_when=[]), "render-done-when-mismatch")

    def test_an_entry_with_no_id_is_a_mismatch_not_a_crash(self):
        stopped_receipt(self.home)
        self.refused(self.draft(done_when=[{"result": "pass", "note": "x"}]), "render-done-when-mismatch")
        d = self.draft()
        d["areas"][0]["checks"][0] = {"result": "pass", "note": "x"}
        self.refused(d, "render-checks-mismatch")

    def test_a_guide_edit_naming_no_check_is_refused_not_a_crash(self):
        stopped_receipt(self.home)
        for bad in (["C3"], {"id": "C3"}, 3, None):
            d = self.draft(guide_edits=[{"check_id": bad, "new": "x", "why": "y"}])
            self.refused(d, "record-bad-guide-edit")

    def test_screenshot_must_exist_beside_the_receipt(self):
        stopped_receipt(self.home)
        self.refused(self.draft(screenshots=["C2-missing.png"]), "render-screenshot-missing")

    def test_area_must_be_one_the_run_served(self):
        stopped_receipt(self.home)
        self.refused(self.draft(area="clients"), "render-area-not-in-run")

    def test_guide_blame_needs_an_edit(self):
        stopped_receipt(self.home)
        self.refused(self.draft(guide_edits=[]), "record-guide-blame-without-edit")


WRONG_TYPES = [None, 3, 2.5, True, [], ["x"], {}, {"a": 1}, "", "x\ny"]


def field_paths(obj, prefix=()):
    yield prefix
    if isinstance(obj, dict):
        for k, val in obj.items():
            yield from field_paths(val, prefix + (k,))
    elif isinstance(obj, list):
        for i, val in enumerate(obj):
            yield from field_paths(val, prefix + (i,))


def with_value(obj, path, val):
    if not path:
        return val
    out = json.loads(json.dumps(obj))
    cur = out
    for p in path[:-1]:
        cur = cur[p]
    cur[path[-1]] = val
    return out


class WrongTypeSweepTests(unittest.TestCase):
    """Every field of a record, a draft and areas.json, given every wrong type, is a named refusal.

    The merge check reads what an agent wrote, so a list where a string belongs must be refused by
    kind, never crash the reader with a traceback that reads as the check being broken. Found one
    field at a time by three review rounds, so closed for the class here (L30).
    """

    def crashes(self, obj, call):
        found = []
        for path in list(field_paths(obj)):
            for bad in WRONG_TYPES:
                try:
                    call(with_value(obj, path, bad))
                except v.VerificationError:
                    pass
                except Exception as e:  # the defect this sweep exists to find, so it is recorded
                    found.append((path, bad, repr(e)))
        return found

    def test_records(self):
        rec = good_record()
        self.assertEqual(self.crashes(rec, lambda r: v.parse_comment(comment_with(r), sha=SHA)), [])

    def test_drafts(self):
        with tempfile.TemporaryDirectory() as tmp:
            home, tr = os.path.join(tmp, "home"), os.path.join(tmp, "tr")
            nonce = v.new_nonce()
            transcript(os.path.join(tr, "p/s/subagents/agent-a1b2.jsonl"), "brief " + nonce, "a1b2")
            stopped_receipt(home)
            case = RenderTests("test_a_missing_receipt")
            case.nonce = nonce
            body = "## Done when\n- The list loads\n"
            found = self.crashes(case.draft(), lambda d: v.render_comment(d, home=home, transcripts=tr, pr_body=body))
            self.assertEqual(found, [])

    def test_areas(self):
        with tempfile.TemporaryDirectory() as root:
            for g in ("invoices", "clients"):
                write(os.path.join(root, ".claude/verification/guides/%s.md" % g), GUIDE)
            found = self.crashes(areas_doc(), lambda d: v.parse_areas(json.dumps(d), root=root))
            self.assertEqual(found, [])


class SkillDocTests(unittest.TestCase):
    """The rules the RUN brief must carry, read from SKILL.md itself."""

    def setUp(self):
        with open(os.path.join(HERE, "..", "SKILL.md")) as f:
            self.text = f.read()

    def test_frontmatter(self):
        self.assertTrue(self.text.startswith("---\nname: verification-guides\n"))
        self.assertIn("\ndescription: ", self.text.split("\n---", 1)[0])

    def test_the_three_procedures(self):
        for heading in ("## CREATE", "## MAINTAIN", "## RUN"):
            self.assertIn(heading, self.text)

    def test_run_brief_carries_the_subagent_rules(self):
        for phrase in ("never call a Playwright tool", "payload/CLAUDE.md", "run_session.py drive",
                       "run_session.py stop", "detached worktree", "hand back"):
            self.assertIn(phrase, self.text)

    def test_maintain_names_who_decides(self):
        self.assertIn("the runner, not the builder", self.text)
        self.assertIn("old check, the new check and why", self.text)


if __name__ == "__main__":
    unittest.main()
