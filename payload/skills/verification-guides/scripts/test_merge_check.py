"""Tests for merge_check.py, the merge check's judgment (claude-config#1529), and the readers it added
to verification.py (drives, every record across a pull request's comments, the warn tally).

Every refusal is seen on a bundle built to trip it, and its kind is asserted, because distinct causes
must stay distinct messages (L11). The hook that gathers a bundle from GitHub has its own suite,
hooks/test-require-verification-run.sh, which drives the real hook end to end.
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
import merge_check as mc  # noqa: E402

HEAD = "1111111111111111111111111111111111111111"
OLD = "2222222222222222222222222222222222222222"
BASE = "3333333333333333333333333333333333333333"
RID = "20261022T230000Z-1111111-a1b2c3"
RID_OLD = "20261021T230000Z-2222222-d4e5f6"
SLUG = "acme/widget"

GUIDE = """# Invoices verification guide

## Roles
An owner with two clients.

## Reach
Open /invoices.

## State setup
Seed the demo dataset.

## Checks
- [C1] The list shows every sent invoice.
- [C2] Opening an invoice shows its total.
- [C3] A draft can be sent.

## Known traps
None yet.
"""
CHECKS = [("C1", "The list shows every sent invoice."), ("C2", "Opening an invoice shows its total."),
          ("C3", "A draft can be sent.")]
BODY = "Fixes the list.\n\n## Done when\n- [ ] The list loads in under a second\n"


def areas_doc(mode="block", **over):
    doc = {
        "schema": "verification-areas/1",
        "mode": mode,
        "url": "http://127.0.0.1:4173",
        "commands": {"serve": "pnpm preview", "ready": "true", "stop": "true", "drive": "node drive.mjs"},
        "areas": [
            {"name": "invoices", "guide": ".claude/verification/guides/invoices.md", "owns": ["src/invoices/**"]},
            {"name": "clients", "guide": ".claude/verification/guides/clients.md", "owns": ["src/clients/**"]},
        ],
        "exempt": [{"glob": "docs/**", "why": "documentation only"}],
    }
    doc.update(over)
    return doc


def record(area="invoices", sha=HEAD, rid=RID, fail=(), done=(("D1", "The list loads in under a second", "pass"),),
           checks=CHECKS, machine=None):
    return {
        "schema": "verification-run/1", "area": area, "head_sha": sha, "receipt_id": rid,
        "machine": machine or v.machine_name(), "runner_agent_id": "agent-abc123",
        "checks": [dict({"id": cid, "text": text, "result": "fail" if cid in fail else "pass", "note": "seen"},
                        **({"blame": "code"} if cid in fail else {})) for cid, text in checks],
        "done_when": [{"id": d, "text": t, "result": r, "note": "seen"} for d, t, r in done],
        "screenshots": [], "guide_edits": [],
    }


def comment(*records, raw=None):
    parts = ["## Verification run"]
    for r in records:
        parts += ["```verification-run", json.dumps(r, indent=2), "```"]
    if raw is not None:
        parts += ["```verification-run", raw, "```"]
    return "\n".join(parts)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class Fixture:
    """A bundle as the hook writes it, and a receipt home holding this machine's receipts."""

    def __init__(self, tmp):
        self.dir = os.path.join(tmp, "bundle")
        self.home = os.path.join(tmp, "home")
        os.makedirs(self.dir)
        os.makedirs(self.home)
        self.view = {"number": 7, "url": "https://github.com/acme/widget/pull/7", "headRefOid": HEAD,
                     "baseRefOid": BASE, "baseRefName": "main", "body": BODY, "changedFiles": 1}
        self.areas = areas_doc()
        self.files = [{"filename": "src/invoices/list.ts", "status": "modified"}]
        self.comments = [comment(record())]
        self.guides = {"invoices": GUIDE, "clients": GUIDE.replace("Invoices", "Clients")}
        self.compares = {}
        self.pin = "required " + HEAD
        self.receipt(RID, HEAD)

    def receipt(self, rid, sha, drives=({"area": "invoices", "exit": 0},), **over):
        rec = {"schema": "verification-receipt/1", "receipt_id": rid, "machine": v.machine_name(),
               "repo": "/tmp/widget", "head_sha": sha, "checkout_sha": sha, "areas": ["invoices"],
               "stopped_at": "2026-10-22T23:10:00Z", "stopped_by": "stop",
               "build_stamp": sha, "build_stamp_source": "stamp-command",
               "egress": {"verdict": "clean", "why": "the monitor saw no outside host"}}
        rec.update(over)
        rdir = os.path.join(self.home, "receipts", rid)
        write(os.path.join(rdir, "receipt.json"), json.dumps(rec))
        if drives is not None:
            write(os.path.join(rdir, "drives.jsonl"), "".join(json.dumps(d) + "\n" for d in drives))
        return rdir

    def save(self, skip=()):
        write(os.path.join(self.dir, "view.json"), json.dumps(self.view))
        write(os.path.join(self.dir, "slug"), SLUG)
        write(os.path.join(self.dir, "pin"), self.pin)
        write(os.path.join(self.dir, "areas.json"), json.dumps(self.areas))
        if "files" not in skip:
            write(os.path.join(self.dir, "files.json"), json.dumps(self.files))
        if "comments" not in skip:
            # gh api --paginate prints each page's array one after another, so two pages are written.
            half = len(self.comments) // 2
            write(os.path.join(self.dir, "comments.json"),
                  json.dumps([{"body": b} for b in self.comments[:half]]) +
                  json.dumps([{"body": b} for b in self.comments[half:]]))
        for area, text in self.guides.items():
            if text is None:
                write(os.path.join(self.dir, "guides", area + ".absent"), "")
            elif "guides" not in skip:
                write(os.path.join(self.dir, "guides", area + ".md"), text)
        for sha, cmp in self.compares.items():
            write(os.path.join(self.dir, "compare", sha + ".json"), json.dumps(cmp))

    def judge(self, skip=()):
        self.save(skip)
        return mc.verdict(self.dir, home=self.home)


def kinds(out):
    return sorted({p["kind"] for p in out["problems"]})


class Judging(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_passing_run_at_the_head_allows_the_merge(self):
        out = self.f.judge()
        self.assertEqual(out["problems"], [])
        self.assertEqual((out["passed"], out["decision"], out["mode"]), (True, "allow", "block"))
        self.assertEqual(out["touched_areas"], ["invoices"])

    def test_a_pull_request_touching_only_exempt_files_has_nothing_to_verify(self):
        self.f.files = [{"filename": "docs/readme.md"}]
        self.f.comments = []
        out = self.f.judge()
        self.assertEqual((out["passed"], out["touched_areas"]), (True, []))

    def test_unmeasured_egress_is_its_own_refusal_and_never_clean(self):
        self.f.receipt(RID, HEAD, egress={"verdict": "unmeasured", "why": "no egress monitor exists"})
        out = self.f.judge()
        self.assertEqual((kinds(out), out["decision"]), (["egress-unmeasured"], "refuse"))
        self.assertIn("unmeasured", out["text"])

    def test_egress_that_is_not_clean(self):
        self.f.receipt(RID, HEAD, egress={"verdict": "dirty", "why": "reached api.stripe.com"})
        self.assertEqual(kinds(self.f.judge()), ["egress-not-clean"])

    def test_no_stamp_command_is_its_own_message(self):
        self.f.receipt(RID, HEAD, build_stamp=None, build_stamp_source="none")
        out = self.f.judge()
        self.assertEqual(kinds(out), ["stamp-missing"])
        self.assertIn("stamp command", out["text"])

    def test_a_stamp_command_that_failed(self):
        self.f.receipt(RID, HEAD, build_stamp=None, build_stamp_source="stamp-failed")
        self.assertEqual(kinds(self.f.judge()), ["stamp-failed"])

    def test_a_stamp_from_another_commit(self):
        self.f.receipt(RID, HEAD, build_stamp=OLD)
        self.assertEqual(kinds(self.f.judge()), ["stamp-mismatch"])

    def test_receipt_missing(self):
        self.f.comments = [comment(record(rid="20261022T230000Z-1111111-ffffff"))]
        self.assertEqual(kinds(self.f.judge()), ["receipt-missing"])

    def test_receipt_from_another_machine(self):
        self.f.comments = [comment(record(machine="Some-Other-Mac"))]
        out = self.f.judge()
        self.assertEqual(kinds(out), ["receipt-other-machine"])
        self.assertIn("Some-Other-Mac", out["text"])

    def test_receipt_unreadable(self):
        write(os.path.join(self.f.home, "receipts", RID, "receipt.json"), "{not json")
        self.assertEqual(kinds(self.f.judge()), ["receipt-unreadable"])

    def test_receipt_not_stopped(self):
        self.f.receipt(RID, HEAD, stopped_at=None)
        self.assertEqual(kinds(self.f.judge()), ["receipt-not-stopped"])

    def test_receipt_about_another_head(self):
        self.f.receipt(RID, HEAD, head_sha=OLD, checkout_sha=OLD, build_stamp=HEAD)
        self.assertEqual(kinds(self.f.judge()), ["receipt-mismatch"])

    def test_no_drive_call_covering_the_area(self):
        self.f.receipt(RID, HEAD, drives=({"area": "invoices", "exit": 1}, {"area": "clients", "exit": 0}))
        self.assertEqual(kinds(self.f.judge()), ["no-drive"])

    def test_no_record(self):
        self.f.comments = ["Looks good to me"]
        out = self.f.judge()
        self.assertEqual(kinds(out), ["no-record"])
        self.assertIn(HEAD[:7], out["text"])

    def test_failing_record_names_what_failed(self):
        self.f.comments = [comment(record(fail=("C2",)))]
        out = self.f.judge()
        self.assertEqual(kinds(out), ["failing-record"])
        self.assertIn("C2", out["text"])

    def test_a_failing_done_when_item_is_a_failing_record(self):
        self.f.comments = [comment(record(done=(("D1", "The list loads in under a second", "fail"),)))]
        self.assertEqual(kinds(self.f.judge()), ["failing-record"])

    def test_the_newest_record_wins_over_an_older_pass(self):
        self.f.comments = [comment(record()), comment(record(fail=("C1",)))]
        self.assertEqual(kinds(self.f.judge()), ["failing-record"])

    def test_a_malformed_newest_block_reads_as_broken_not_absent(self):
        self.f.comments = [comment(record()), comment(raw='{"schema": "verification-run/1", "area": "invoices"}')]
        self.assertEqual(kinds(self.f.judge()), ["malformed-record"])

    def test_a_block_that_is_not_json_counts_against_every_touched_area(self):
        self.f.comments = [comment(record()), comment(raw="{oops")]
        self.assertEqual(kinds(self.f.judge()), ["malformed-record"])

    def test_a_record_run_against_a_guide_the_pull_request_changed(self):
        changed = [("C1", "The list shows every invoice."), CHECKS[1], CHECKS[2]]
        self.f.comments = [comment(record(checks=changed))]
        self.assertEqual(kinds(self.f.judge()), ["record-not-base-guide"])

    def test_a_record_missing_a_base_check(self):
        self.f.comments = [comment(record(checks=CHECKS[:2] + [("C4", "Something else.")]))]
        self.assertEqual(kinds(self.f.judge()), ["record-not-base-guide"])

    def test_done_when_items_changed_since_the_run(self):
        self.f.view["body"] = BODY + "- [ ] Totals are rounded to cents\n"
        self.assertEqual(kinds(self.f.judge()), ["done-when-changed"])

    def test_an_older_record_whose_later_patch_leaves_the_area_alone_counts(self):
        self.f.comments = [comment(record(sha=OLD, rid=RID_OLD))]
        self.f.receipt(RID_OLD, OLD)
        self.f.files = [{"filename": "src/invoices/list.ts"}, {"filename": "docs/notes.md"}]
        self.f.view["changedFiles"] = 2
        self.f.compares = {OLD: {"status": "ahead", "files": [{"filename": "docs/notes.md"}]}}
        out = self.f.judge()
        self.assertEqual(out["problems"], [])
        self.assertTrue(out["passed"])

    def test_an_older_record_whose_later_patch_touches_the_area_is_stale(self):
        self.f.comments = [comment(record(sha=OLD, rid=RID_OLD))]
        self.f.receipt(RID_OLD, OLD)
        self.f.compares = {OLD: {"status": "ahead", "files": [{"filename": "src/invoices/list.ts"}]}}
        out = self.f.judge()
        self.assertEqual(kinds(out), ["stale-record"])
        self.assertIn("src/invoices/list.ts", out["text"])

    def test_a_base_change_merged_into_the_branch_is_not_the_pull_requests_own_patch(self):
        # main changed an invoices file and the branch was updated: the compare shows it, the pull
        # request's own files do not, so the run still describes this pull request's change.
        self.f.comments = [comment(record(sha=OLD, rid=RID_OLD))]
        self.f.receipt(RID_OLD, OLD)
        self.f.compares = {OLD: {"status": "ahead", "files": [{"filename": "src/invoices/other.ts"}]}}
        self.assertTrue(self.f.judge()["passed"])

    def test_an_older_record_not_in_the_branch_history_is_stale(self):
        self.f.comments = [comment(record(sha=OLD, rid=RID_OLD))]
        self.f.receipt(RID_OLD, OLD)
        self.f.compares = {OLD: {"status": "diverged", "files": []}}
        out = self.f.judge()
        self.assertEqual(kinds(out), ["stale-record"])
        self.assertIn("rebased", out["text"])

    def test_a_compare_too_large_to_list_is_stale(self):
        self.f.comments = [comment(record(sha=OLD, rid=RID_OLD))]
        self.f.receipt(RID_OLD, OLD)
        self.f.compares = {OLD: {"status": "ahead", "files": [{"filename": "x%d" % i} for i in range(300)]}}
        self.assertEqual(kinds(self.f.judge()), ["stale-record"])

    def test_a_record_at_the_head_is_preferred_to_a_newer_one_at_an_older_commit(self):
        self.f.comments = [comment(record()), comment(record(sha=OLD, rid=RID_OLD, fail=("C1",)))]
        self.assertTrue(self.f.judge()["passed"])

    def test_an_unowned_file(self):
        self.f.files.append({"filename": "src/billing/new.ts"})
        self.f.view["changedFiles"] = 2
        out = self.f.judge()
        self.assertEqual(kinds(out), ["unowned-file"])
        self.assertIn("src/billing/new.ts", out["text"])

    def test_a_renamed_away_file_still_lands_in_a_bucket(self):
        self.f.files = [{"filename": "src/invoices/list.ts", "previous_filename": "src/billing/list.ts"}]
        self.assertEqual(kinds(self.f.judge()), ["unowned-file"])

    def test_an_ambiguous_file(self):
        self.f.areas["areas"][1]["owns"] = ["src/**"]
        self.assertEqual(kinds(self.f.judge()), ["ambiguous-file"])

    def test_more_changed_files_than_github_listed(self):
        self.f.view["changedFiles"] = 4000
        self.assertEqual(kinds(self.f.judge()), ["files-incomplete"])

    def test_github_unreadable_for_the_files(self):
        self.f.save(skip=("files",))
        write(os.path.join(self.f.dir, "files.err"), "the pull request's changed files: TLS handshake timeout")
        out = mc.verdict(self.f.dir, home=self.f.home)
        self.assertEqual(kinds(out), ["github-unreadable"])
        self.assertIn("TLS handshake timeout", out["text"])

    def test_github_unreadable_for_the_comments(self):
        self.f.save(skip=("comments",))
        write(os.path.join(self.f.dir, "comments.err"), "the comments: the hook's read budget ran out")
        self.assertEqual(kinds(mc.verdict(self.f.dir, home=self.f.home)), ["github-unreadable"])

    def test_a_guide_missing_on_the_base_branch(self):
        self.f.guides["invoices"] = None
        self.assertEqual(kinds(self.f.judge()), ["base-guide-missing"])

    def test_a_malformed_guide_on_the_base_branch(self):
        self.f.guides["invoices"] = "# Nothing here\n"
        self.assertEqual(kinds(self.f.judge()), ["base-guide-invalid"])

    def test_base_areas_json_malformed_refuses_with_no_mode(self):
        self.f.areas["mode"] = "sometimes"
        out = self.f.judge()
        self.assertEqual((kinds(out), out["mode"], out["decision"]), (["base-areas-invalid"], None, "refuse"))

    def test_an_unpinned_merge(self):
        self.f.pin = "required "
        self.assertEqual(kinds(self.f.judge()), ["merge-unpinned"])

    def test_a_merge_pinned_to_another_commit(self):
        self.f.pin = "required " + OLD
        self.assertEqual(kinds(self.f.judge()), ["merge-pinned-elsewhere"])

    def test_a_wrapper_route_pins_for_itself(self):
        self.f.pin = "not-required"
        self.assertTrue(self.f.judge()["passed"])

    def test_it_asks_for_the_guides_and_compares_it_needs_first(self):
        self.f.comments = [comment(record(sha=OLD, rid=RID_OLD))]
        self.f.guides = {}
        self.f.save()
        out = mc.verdict(self.f.dir, home=self.f.home)
        self.assertEqual(out["need"], {"guides": [{"area": "invoices", "path": ".claude/verification/guides/invoices.md"}],
                                       "compares": [OLD]})

    def test_a_need_left_unanswered_on_the_final_call_is_unreadable_not_a_crash(self):
        self.f.guides = {}
        self.f.save()
        out = mc.verdict(self.f.dir, home=self.f.home, final=True)
        self.assertEqual(kinds(out), ["github-unreadable"])


class WarnMode(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(self.tmp.name)
        self.f.areas = areas_doc(mode="warn")

    def tearDown(self):
        self.tmp.cleanup()

    def test_warn_allows_a_refused_verdict_says_so_and_tallies_it(self):
        self.f.comments = []
        out = self.f.judge()
        self.assertEqual((out["decision"], out["passed"], kinds(out)), ("allow", False, ["no-record"]))
        self.assertIn("warn", out["text"])
        self.assertIn("would be refused", out["text"])
        tally = v.tally_read(SLUG, home=self.f.home)
        self.assertEqual(sorted(tally), [7])
        self.assertEqual(tally[7]["kinds"], ["no-record"])

    def test_warn_tallies_a_pass_too(self):
        out = self.f.judge()
        self.assertEqual((out["decision"], out["passed"]), ("allow", True))
        self.assertIn("would pass", out["text"])
        self.assertTrue(v.tally_read(SLUG, home=self.f.home)[7]["passed"])

    def test_block_mode_never_tallies(self):
        self.f.areas = areas_doc(mode="block")
        self.f.judge()
        self.assertEqual(v.tally_read(SLUG, home=self.f.home), {})

    def test_the_tally_is_keyed_by_pull_request(self):
        for _ in range(3):
            self.f.judge()
        self.assertEqual(len(v.tally_read(SLUG, home=self.f.home)), 1)


class Tally(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def add(self, pr, passed=False, kinds_=("egress-unmeasured",), slug=SLUG):
        v.tally_append(slug, pr, HEAD, passed, list(kinds_), home=self.home)

    def test_nothing_is_due_before_the_count(self):
        for pr in range(1, v.TALLY_ASK_EVERY):
            self.add(pr)
        self.assertEqual(v.tally_due(home=self.home), [])

    def test_due_at_the_count_with_a_summary(self):
        for pr in range(1, v.TALLY_ASK_EVERY + 1):
            self.add(pr, passed=(pr == 1), kinds_=() if pr == 1 else ("egress-unmeasured",))
        due = v.tally_due(home=self.home)
        self.assertEqual(len(due), 1)
        d = due[0]
        self.assertEqual((d["repo"], d["prs"], d["passed"], d["refused"]), (SLUG, v.TALLY_ASK_EVERY, 1, v.TALLY_ASK_EVERY - 1))
        self.assertEqual(d["kinds"], {"egress-unmeasured": v.TALLY_ASK_EVERY - 1})

    def test_marking_asked_waits_for_the_next_count(self):
        for pr in range(1, v.TALLY_ASK_EVERY + 1):
            self.add(pr)
        v.tally_due(home=self.home, mark=True)
        self.assertEqual(v.tally_due(home=self.home), [])
        for pr in range(100, 100 + v.TALLY_ASK_EVERY):
            self.add(pr)
        self.assertEqual(len(v.tally_due(home=self.home)), 1)

    def test_a_repeated_pull_request_counts_once_with_its_latest_verdict(self):
        for _ in range(v.TALLY_ASK_EVERY + 2):
            self.add(5)
        self.add(5, passed=True, kinds_=())
        self.assertEqual(v.tally_read(SLUG, home=self.home)[5]["passed"], True)
        self.assertEqual(v.tally_due(home=self.home), [])

    def test_a_bad_slug_is_refused(self):
        with self.assertRaises(v.VerificationError) as e:
            v.tally_append("../etc", 1, HEAD, True, [], home=self.home)
        self.assertEqual(e.exception.problems[0][0], "tally-bad-repo")

    def test_an_unreadable_line_is_counted_not_crashed_on(self):
        self.add(1)
        with open(v.tally_file(SLUG, home=self.home), "a") as f:
            f.write("{oops\n")
        self.assertEqual(v.tally_summary(SLUG, home=self.home)["unreadable_lines"], 1)

    def test_cli_due_and_mark(self):
        for pr in range(1, v.TALLY_ASK_EVERY + 1):
            self.add(pr)
        env = dict(os.environ, VERIFICATION_HOME=self.home)
        r = subprocess.run([sys.executable, os.path.join(HERE, "verification.py"), "tally", "due", "--mark"],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)[0]["repo"], SLUG)
        r = subprocess.run([sys.executable, os.path.join(HERE, "verification.py"), "tally", "due"],
                           capture_output=True, text=True, env=env)
        self.assertEqual(json.loads(r.stdout), [])


class Readers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_drives_missing_log_is_no_calls(self):
        self.assertEqual(v.load_drives(RID, home=self.home), [])

    def test_drives_read_every_call(self):
        write(os.path.join(self.home, "receipts", RID, "drives.jsonl"),
              '{"at": "x", "area": "invoices", "args": [], "exit": 0}\n\n{"area": "clients", "exit": 2}\n')
        self.assertEqual([(d["area"], d["exit"]) for d in v.load_drives(RID, home=self.home)],
                         [("invoices", 0), ("clients", 2)])

    def test_a_malformed_drive_line_is_named(self):
        write(os.path.join(self.home, "receipts", RID, "drives.jsonl"), '{"area": 3, "exit": "no"}\n')
        with self.assertRaises(v.VerificationError) as e:
            v.load_drives(RID, home=self.home)
        self.assertEqual(e.exception.problems[0][0], "drives-bad-line")

    def test_comment_records_keep_order_and_the_area_of_a_broken_block(self):
        bodies = [comment(record()), comment(raw='{"area": "clients"}'), "no blocks here", comment(raw="{x")]
        got = v.comment_records(bodies)
        self.assertEqual([(e["comment"], e["area"], e["record"] is not None) for e in got],
                         [(0, "invoices", True), (1, "clients", False), (3, None, False)])

    def test_parse_comment_is_unchanged_by_sharing_the_block_reader(self):
        out = v.parse_comment(comment(record(), raw="{x"), sha=HEAD)
        self.assertEqual((len(out["records"]), len(out["invalid"]), len(out["matching"])), (1, 1, 1))


class Cli(unittest.TestCase):
    def test_the_verdict_command_prints_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Fixture(tmp)
            f.save()
            env = dict(os.environ, VERIFICATION_HOME=f.home)
            r = subprocess.run([sys.executable, os.path.join(HERE, "merge_check.py"), "verdict", f.dir],
                               capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(json.loads(r.stdout)["decision"], "allow")

    def test_usage(self):
        r = subprocess.run([sys.executable, os.path.join(HERE, "merge_check.py")], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
