"""Tests for merge_check.py, the merge check's judgment (claude-config#1529), and the readers it added
to verification.py (drives, every record across a pull request's comments, the warn tally).

Every refusal is seen on a bundle built to trip it, and its kind is asserted, because distinct causes
must stay distinct messages (L11). The hook that gathers a bundle from GitHub has its own suite,
hooks/test-require-verification-run.sh, which drives the real hook end to end.
"""

import difflib
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # a module beside this one is carried by the sync: leave no cache (#2919)
sys.path.insert(0, HERE)

import verification as v  # noqa: E402
import merge_check as mc  # noqa: E402
import screenshots as shots  # noqa: E402

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
        # GitHub's compare of any two commits, by (from, to): None for a read that failed, a string
        # for an answer written as it is (#3574).
        self.diffs = {}
        self.pin = "required " + HEAD
        # The screenshots reads (#2516): GitHub's answer about the repository, each folder listing
        # of the pr-screenshots branch by commit (None for a failed read), and the override.
        self.repo = None
        self.listings = {}
        self.allow_no_screenshots = False
        # Every record posted is one record render wrote (#1572), unless a test says otherwise.
        self.render_all = True
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

    def rendered(self, *records):
        """Record each one as record render does, beside the receipt it names."""
        for rec in records:
            v.remember_rendered(rec["receipt_id"], [rec], self.home)

    def save(self, skip=()):
        if self.render_all:
            for e in v.comment_records(self.comments):
                if e["record"] and os.path.isdir(os.path.join(self.home, "receipts", e["record"]["receipt_id"])):
                    self.rendered(e["record"])
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
        for (a, b), cmp in self.diffs.items():
            if cmp is None:
                write(os.path.join(self.dir, "compare", "%s...%s.err" % (a, b)), "gh: Server Error (HTTP 502)")
            else:
                write(os.path.join(self.dir, "compare", "%s...%s.json" % (a, b)),
                      cmp if isinstance(cmp, str) else json.dumps(cmp))
        if self.repo == "fail":
            write(os.path.join(self.dir, "repo.err"), "gh: Server Error (HTTP 502)")
        elif self.repo is not None:
            write(os.path.join(self.dir, "repo.json"), json.dumps(self.repo))
        for commit, names in self.listings.items():
            if names is None:
                write(os.path.join(self.dir, "shots", commit + ".err"), "gh: Server Error (HTTP 502)")
            else:
                write(os.path.join(self.dir, "shots", commit + ".json"),
                      json.dumps([{"name": n, "type": "file"} for n in names]))
        if self.allow_no_screenshots:
            write(os.path.join(self.dir, "allow-no-screenshots"), "")

    def judge(self, skip=(), final=False):
        self.save(skip)
        return mc.verdict(self.dir, home=self.home, final=final)


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

    def test_an_untouched_rendered_record_passes(self):
        self.f.render_all = False
        self.f.rendered(record())
        self.assertEqual(self.f.judge()["problems"], [])

    def test_a_failing_result_edited_to_pass_after_render_is_refused(self):
        self.f.render_all = False
        self.f.rendered(record(fail=("C2",)))
        out = self.f.judge()
        self.assertEqual((kinds(out), out["decision"]), (["record-edited"], "refuse"))
        self.assertIn(RID, out["text"])

    def test_a_note_rewritten_after_render_is_refused(self):
        self.f.render_all = False
        rendered = record()
        self.f.rendered(rendered)
        edited = record()
        edited["checks"][0]["note"] = "rewritten by hand"
        self.f.comments = [comment(edited)]
        self.assertEqual(kinds(self.f.judge()), ["record-edited"])

    def test_a_record_render_never_wrote_is_its_own_refusal(self):
        self.f.render_all = False
        out = self.f.judge()
        self.assertEqual(kinds(out), ["record-not-rendered"])
        self.assertIn("record render", out["text"])

    def test_a_record_rendered_twice_passes_as_either(self):
        self.f.render_all = False
        self.f.rendered(record(fail=("C1",)), record())
        self.assertEqual(self.f.judge()["problems"], [])

    def test_an_unreadable_rendered_log_is_said_not_read_as_unrendered(self):
        self.f.render_all = False
        write(os.path.join(self.f.home, "receipts", RID, "rendered.jsonl"), "{not json\n")
        out = self.f.judge()
        self.assertEqual(kinds(out), ["receipt-unreadable"])
        self.assertIn("rendered", out["text"])

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
                                       "compares": [OLD], "diffs": [], "listings": [], "repo": False})

    def test_a_need_left_unanswered_on_the_final_call_is_unreadable_not_a_crash(self):
        self.f.guides = {}
        self.f.save()
        out = mc.verdict(self.f.dir, home=self.f.home, final=True)
        self.assertEqual(kinds(out), ["github-unreadable"])


PATH = "src/invoices/list.ts"
MB_THEN = "4444444444444444444444444444444444444444"   # where the branch left main, as of the record
MB_NOW = "5555555555555555555555555555555555555555"    # the commit of main the branch merged since


def rows(n=40):
    return ["const row%d = %d;" % (i, i) for i in range(1, n + 1)]


def edit(src, *ops):
    """`src` with each (line, how many to remove, lines to put there) applied, lines counted in src."""
    out = list(src)
    for at, remove, add in sorted(ops, reverse=True):
        out[at - 1:at - 1 + remove] = add
    return out


def patch(old, new):
    """The patch text GitHub gives for one file: a unified diff's hunks, three lines of context."""
    return "\n".join(list(difflib.unified_diff(old, new, lineterm="", n=3))[2:])


def file_entry(path, old, new):
    """GitHub's entry for one modified file in a compare or a pull request's files."""
    text = patch(old, new)
    marks = [line[0] for line in text.split("\n")]
    return {"filename": path, "status": "modified", "additions": marks.count("+"), "deletions": marks.count("-"),
            "patch": text}


# The pull request's own change to the file, and what main did to it meanwhile, both in the lines of
# the file as the branch first found it. Main's two added lines move the pull request's hunks down.
OWN = ((20, 1, ["const row20 = 2000;"]), (31, 0, ["const extra = 1;"]))
MAINS = ((6, 0, ["import a;", "import b;"]), (38, 1, ["const row38 = 3800;"]))


class MainMerged(unittest.TestCase):
    """A record made before main was merged into the branch (claude-config#3574).

    Shape of the first measured case: the record's commit, then a merge of main, and main changed a
    file the pull request also changes. Each fixture is the four versions of that file (main and the
    branch, at the record and at the head), with every patch derived from them, so no patch here is
    written to suit the rule under test (L48).
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(self.tmp.name)
        self.f.comments = [comment(record(sha=OLD, rid=RID_OLD))]
        self.f.receipt(RID_OLD, OLD)

    def tearDown(self):
        self.tmp.cleanup()

    def merged(self, then, at_record, now, at_head, path=PATH, more=()):
        """One file as main held it at the record (`then`) and holds it at the head's merge base
        (`now`), and as the branch held it at the record and holds it at the head. `more` is further
        (path, then, at_record, now, at_head) files."""
        files = [(path, then, at_record, now, at_head)] + list(more)

        def entries(pick):
            return [file_entry(p, *pick(t, r, n, h))
                    for p, t, r, n, h in files if pick(t, r, n, h)[0] != pick(t, r, n, h)[1]]
        self.f.files = entries(lambda t, r, n, h: (n, h))
        self.f.view["changedFiles"] = len(self.f.files)
        self.f.compares = {OLD: {
            "status": "ahead", "total_commits": 2,
            "commits": [{"sha": MB_NOW, "parents": [{"sha": MB_THEN}]},
                        {"sha": HEAD, "parents": [{"sha": OLD}, {"sha": MB_NOW}]}],
            "files": entries(lambda t, r, n, h: (r, h))}}
        self.f.diffs = {
            (BASE, OLD): {"status": "diverged", "merge_base_commit": {"sha": MB_THEN},
                          "files": entries(lambda t, r, n, h: (t, r))},
            (BASE, HEAD): {"status": "ahead", "merge_base_commit": {"sha": MB_NOW},
                           "files": entries(lambda t, r, n, h: (n, h))},
            (MB_THEN, MB_NOW): {"status": "ahead", "merge_base_commit": {"sha": MB_THEN},
                                "files": entries(lambda t, r, n, h: (t, n))},
        }

    def clean_merge(self):
        self.merged(rows(), edit(rows(), *OWN), edit(rows(), *MAINS), edit(rows(), *OWN, *MAINS))

    def stale(self, out, *says):
        self.assertEqual(kinds(out), ["stale-record"])
        self.assertEqual((out["passed"], out["decision"]), (False, "refuse"))
        for needle in says:
            self.assertIn(needle, out["text"])

    # -- the record still describes the head -------------------------------------------------

    def test_a_merge_of_main_that_changed_a_file_the_pull_request_also_changes_leaves_the_record_standing(self):
        self.clean_merge()
        # The premise: main moved the pull request's hunks, so the two patches are not the same text.
        self.assertNotEqual(self.f.diffs[(BASE, OLD)]["files"][0]["patch"], self.f.files[0]["patch"])
        out = self.f.judge(final=True)
        self.assertEqual(out["problems"], [])
        self.assertEqual((out["passed"], out["decision"]), (True, "allow"))

    def test_main_changing_the_file_below_every_hunk_leaves_the_record_standing(self):
        mains = ((38, 1, ["const row38 = 3800;"]),)
        self.merged(rows(), edit(rows(), *OWN), edit(rows(), *mains), edit(rows(), *OWN, *mains))
        self.assertEqual(self.f.diffs[(BASE, OLD)]["files"][0]["patch"], self.f.files[0]["patch"])
        self.assertTrue(self.f.judge(final=True)["passed"])

    def test_the_branch_level_with_the_base_is_judged_the_same(self):
        # merge-when-ready.sh brings the branch level with the base, so the head's merge base is the
        # base commit itself.
        self.clean_merge()
        self.f.diffs[(BASE, HEAD)]["merge_base_commit"]["sha"] = BASE
        self.f.diffs[(MB_THEN, BASE)] = self.f.diffs.pop((MB_THEN, MB_NOW))
        self.assertTrue(self.f.judge(final=True)["passed"])

    # -- the record is still stale: every one of these the old rule refused too --------------

    def test_the_pull_requests_own_commits_since_the_record_are_stale_and_ask_github_nothing_more(self):
        # Shape of the measured control: commits of the pull request's own since the record, no merge.
        then = edit(rows(), *OWN)
        now = edit(rows(), (20, 1, ["const row20 = 2001;"]), OWN[1])
        self.merged(rows(), then, rows(), now)
        self.f.compares[OLD]["commits"] = [{"sha": "a" * 40, "parents": [{"sha": OLD}]},
                                           {"sha": HEAD, "parents": [{"sha": "a" * 40}]}]
        self.f.diffs = {}
        out = self.f.judge()   # not final: a verdict here means nothing more was asked of GitHub
        self.stale(out, "since then this pull request changed " + PATH)

    def test_the_pull_requests_own_patch_changed_as_well_as_the_merge_is_stale(self):
        own_now = ((20, 1, ["const row20 = 2001;"]), OWN[1])
        self.merged(rows(), edit(rows(), *OWN), edit(rows(), *MAINS), edit(rows(), *own_now, *MAINS))
        self.stale(self.f.judge(final=True), PATH, "patch to it differs")

    def test_a_hunk_the_pull_request_added_since_the_record_is_stale(self):
        own_now = OWN + ((12, 1, ["const row12 = 1200;"]),)
        self.merged(rows(), edit(rows(), *OWN), edit(rows(), *MAINS), edit(rows(), *own_now, *MAINS))
        self.stale(self.f.judge(final=True), "patch to it differs")

    def test_a_conflict_resolved_by_changing_the_pull_requests_own_lines_is_stale(self):
        # Main changed the very line the pull request changes, and the merge's resolution wrote a
        # third line: the pull request's own lines at the head are not the ones the run saw.
        mains = MAINS + ((20, 1, ["const row20 = 20000;"]),)
        at_head = edit(rows(), (20, 1, ["const row20 = 2500;"]), OWN[1], *MAINS)
        self.merged(rows(), edit(rows(), *OWN), edit(rows(), *mains), at_head)
        self.stale(self.f.judge(final=True), "patch to it differs")

    def test_a_conflict_resolved_by_keeping_the_pull_requests_line_is_still_stale(self):
        # The same conflict resolved in the pull request's favour: its line is the same text, but it
        # now replaces a different line of main than the run saw it replace.
        mains = MAINS + ((20, 1, ["const row20 = 20000;"]),)
        self.merged(rows(), edit(rows(), *OWN), edit(rows(), *mains), edit(rows(), *OWN, *MAINS))
        self.stale(self.f.judge(final=True), "patch to it differs")

    def test_a_hunk_moved_onto_identical_lines_elsewhere_is_stale(self):
        # The nearest case to a clean merge that must still be refused. Main dropped two lines from
        # the top, and the merge put the pull request's added line two rows further down, among
        # identical rows: its patch is the SAME TEXT, line numbers included, at the record and at
        # the head. Only main's own change says where the line should have landed.
        then = ["// one", "// two"] + ["row();"] * 8
        now = ["row();"] * 8
        self.merged(then, edit(then, (6, 0, ["extra();"])), now, edit(now, (6, 0, ["extra();"])))
        self.assertEqual(self.f.diffs[(BASE, OLD)]["files"][0]["patch"], self.f.files[0]["patch"])
        self.stale(self.f.judge(final=True), "sits on other lines")

    def test_main_changing_a_line_the_pull_requests_hunk_rests_on_is_stale(self):
        # Kept refused on purpose: main changed a line right beside the pull request's, so the
        # pull request's lines no longer sit in the surroundings the run saw.
        mains = MAINS + ((19, 1, ["const row19 = 1900;"]),)
        self.merged(rows(), edit(rows(), *OWN), edit(rows(), *mains), edit(rows(), *OWN, *mains))
        self.stale(self.f.judge(final=True), "patch to it differs")

    def test_a_file_main_did_not_change_is_the_pull_requests_own_change(self):
        other = "src/invoices/total.ts"
        self.merged(rows(), edit(rows(), *OWN), edit(rows(), *MAINS), edit(rows(), *OWN, *MAINS),
                    more=[(other, rows(9), edit(rows(9), (4, 1, ["const total = 1;"])),
                           rows(9), edit(rows(9), (4, 1, ["const total = 2;"])))])
        out = self.f.judge(final=True)
        self.stale(out, "this pull request changed " + other, "no change to it by the base branch")
        self.assertNotIn("changed " + PATH, out["text"])

    def test_a_merge_that_took_in_nothing_from_the_base_is_stale(self):
        # A merge commit since the record, but of some other branch: the merge base did not move.
        self.clean_merge()
        self.f.diffs[(BASE, HEAD)]["merge_base_commit"]["sha"] = MB_THEN
        del self.f.diffs[(MB_THEN, MB_NOW)]
        self.stale(self.f.judge(), "took in nothing")

    def test_merge_bases_github_does_not_place_one_after_the_other_are_stale(self):
        self.clean_merge()
        self.f.diffs[(MB_THEN, MB_NOW)]["status"] = "diverged"
        self.stale(self.f.judge(final=True), "diverged")

    def test_a_file_with_no_patch_text_is_stale(self):
        # GitHub gives no patch for a binary file or a very large one.
        for side in ((BASE, OLD), (BASE, HEAD), (MB_THEN, MB_NOW)):
            with self.subTest(side=side):
                self.clean_merge()
                del self.f.diffs[side]["files"][0]["patch"]
                self.stale(self.f.judge(final=True), "no patch")

    def test_a_patch_cut_short_is_stale(self):
        self.clean_merge()
        entry = self.f.diffs[(BASE, HEAD)]["files"][0]
        entry["patch"] = "\n".join(entry["patch"].split("\n")[:-2])
        self.stale(self.f.judge(final=True), "no patch")

    def test_patches_that_stop_after_a_whole_hunk_are_stale(self):
        # The pull request's second hunk changed since the record, and both patches stop after the
        # first. Every hunk left is well formed and the same at both, so only GitHub's own count of
        # the file's lines shows that something is missing.
        own_now = (OWN[0], (31, 0, ["const extra = 2;"]))
        self.merged(rows(), edit(rows(), *OWN), edit(rows(), *MAINS), edit(rows(), *own_now, *MAINS))
        for side in ((BASE, OLD), (BASE, HEAD)):
            entry = self.f.diffs[side]["files"][0]
            entry["patch"] = entry["patch"].split("\n@@ ")[0]
        self.stale(self.f.judge(final=True), "no patch")

    def test_a_patch_with_no_count_of_its_lines_is_stale(self):
        self.clean_merge()
        del self.f.diffs[(MB_THEN, MB_NOW)]["files"][0]["additions"]
        self.stale(self.f.judge(final=True), "no patch")

    def test_a_renamed_file_is_stale(self):
        self.clean_merge()
        for side in ((BASE, OLD), (BASE, HEAD)):
            self.f.diffs[side]["files"][0].update(status="renamed", previous_filename="src/invoices/old.ts")
        self.stale(self.f.judge(final=True), "added, removed or renamed")

    def test_a_file_the_pull_request_did_not_change_at_the_record_is_stale(self):
        self.clean_merge()
        self.f.diffs[(BASE, OLD)]["files"] = []
        self.stale(self.f.judge(final=True), "by this pull request at the record")

    # -- what it costs, and what a failed read does ------------------------------------------

    def test_it_asks_for_three_more_compares_and_only_once_a_file_calls_for_them(self):
        self.clean_merge()
        answers, self.f.diffs = self.f.diffs, {}
        out = self.f.judge()
        self.assertEqual(out["need"]["diffs"], [{"from": BASE, "to": OLD}, {"from": BASE, "to": HEAD}])
        self.f.diffs = {k: answers[k] for k in ((BASE, OLD), (BASE, HEAD))}
        out = self.f.judge()
        self.assertEqual(out["need"], {"guides": [], "compares": [], "listings": [], "repo": False,
                                       "diffs": [{"from": MB_THEN, "to": MB_NOW}]})
        self.f.diffs = answers
        out = self.f.judge()
        self.assertNotIn("need", out)
        self.assertTrue(out["passed"])

    def test_a_merge_that_left_the_area_alone_asks_nothing_more(self):
        self.clean_merge()
        self.f.files.append({"filename": "docs/notes.md", "status": "modified"})
        self.f.view["changedFiles"] = 2
        self.f.compares[OLD]["files"] = [{"filename": "docs/notes.md"}]
        self.f.diffs = {}
        out = self.f.judge()
        self.assertNotIn("need", out)
        self.assertTrue(out["passed"])

    def test_two_areas_with_one_record_commit_ask_for_each_compare_once(self):
        self.clean_merge()
        self.f.files.append({"filename": "src/clients/list.ts", "status": "modified"})
        self.f.view["changedFiles"] = 2
        self.f.compares[OLD]["files"].append({"filename": "src/clients/list.ts"})
        self.f.comments = [comment(record(sha=OLD, rid=RID_OLD), record(area="clients", sha=OLD, rid=RID_OLD))]
        self.f.diffs = {}
        self.assertEqual(self.f.judge()["need"]["diffs"], [{"from": BASE, "to": OLD}, {"from": BASE, "to": HEAD}])

    def test_a_compare_github_failed_is_unreadable_never_still_describing(self):
        for side in ((BASE, OLD), (BASE, HEAD), (MB_THEN, MB_NOW)):
            with self.subTest(side=side):
                self.clean_merge()
                self.f.diffs[side] = None
                out = self.f.judge(final=True)
                self.assertEqual(kinds(out), ["github-unreadable"])
                self.assertEqual((out["passed"], out["decision"]), (False, "refuse"))
                self.assertIn("HTTP 502", out["text"])
                os.remove(os.path.join(self.f.dir, "compare", "%s...%s.err" % side))

    def test_a_compare_never_answered_is_unreadable_on_the_final_ask(self):
        for side in ((BASE, OLD), (BASE, HEAD), (MB_THEN, MB_NOW)):
            with self.subTest(side=side):
                self.clean_merge()
                answer = os.path.join(self.f.dir, "compare", "%s...%s.json" % side)
                self.f.save()
                os.remove(answer)
                out = mc.verdict(self.f.dir, home=self.f.home, final=True)
                self.assertEqual(kinds(out), ["github-unreadable"])
                self.assertFalse(out["passed"])

    def test_a_compare_that_is_not_json_is_unreadable(self):
        self.clean_merge()
        self.f.diffs[(MB_THEN, MB_NOW)] = "<html>502 Bad Gateway</html>"
        self.assertEqual(kinds(self.f.judge(final=True)), ["github-unreadable"])

    def test_a_compare_naming_no_merge_base_is_unreadable(self):
        self.clean_merge()
        del self.f.diffs[(BASE, HEAD)]["merge_base_commit"]
        self.assertEqual(kinds(self.f.judge(final=True)), ["github-unreadable"])

    def test_a_pull_request_with_no_base_commit_reported_is_unreadable(self):
        self.clean_merge()
        self.f.view["baseRefOid"] = ""
        self.assertEqual(kinds(self.f.judge(final=True)), ["github-unreadable"])

    def test_no_answer_about_whose_change_it_was_is_never_a_pass(self):
        # Whatever leaves the question unanswered without saying why, the area is not passed.
        self.clean_merge()
        real = mc._Verdict.own_changes
        mc._Verdict.own_changes = lambda *a: None
        try:
            for final in (True, False):
                with self.subTest(final=final):
                    out = self.f.judge(final=final)
                    self.assertEqual(kinds(out), ["github-unreadable"])
                    self.assertEqual((out["passed"], out["decision"]), (False, "refuse"))
        finally:
            mc._Verdict.own_changes = real

    def test_a_commit_list_cut_short_is_asked_about_not_assumed(self):
        # GitHub lists 250 commits at most: past that a merge may be among those not listed.
        self.clean_merge()
        self.f.compares[OLD].update(commits=[], total_commits=300)
        self.assertTrue(self.f.judge(final=True)["passed"])
        # And with those answers not in yet, they are asked for, the same two first.
        os.remove(os.path.join(self.f.dir, "compare", "%s...%s.json" % (BASE, OLD)))
        os.remove(os.path.join(self.f.dir, "compare", "%s...%s.json" % (BASE, HEAD)))
        out = mc.verdict(self.f.dir, home=self.f.home)
        self.assertEqual(out["need"]["diffs"], [{"from": BASE, "to": OLD}, {"from": BASE, "to": HEAD}])


class Patches(unittest.TestCase):
    """The patch reader under the #3574 rule: anything it cannot read exactly is not a patch."""

    def test_hunks_are_read_with_their_line_numbers(self):
        hunks = mc._hunks("@@ -3,4 +3,5 @@ function total() {\n a\n-b\n+c\n+d\n e\n f\n@@ -40 +41 @@\n-x\n+y")
        self.assertEqual([(h["old"], h["olen"], h["new"], h["nlen"]) for h in hunks], [(3, 4, 3, 5), (40, 1, 41, 1)])
        self.assertEqual(hunks[0]["body"], [" a", "-b", "+c", "+d", " e", " f"])

    def test_the_no_newline_marker_is_part_of_a_hunk_and_counts_as_no_line(self):
        hunks = mc._hunks("@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+c")
        self.assertEqual(len(hunks[0]["body"]), 4)

    def test_what_is_not_a_whole_patch_is_none(self):
        for bad in (None, "", 7, "a\n b", "@@ -1,3 +1,3 @@\n a\n-b\n+c", "@@ -1,2 +1,2 @@\n a\n-b\n+c\n",
                    "@@ -1,2 +1,2 @@\n a\n-b\n+c\nstray", "@@ nonsense @@\n a"):
            with self.subTest(patch=bad):
                self.assertIsNone(mc._hunks(bad))

    def test_where_a_diff_carries_lines(self):
        # Lines 3 to 4 replaced by one line, and two lines put in before line 10.
        blocks = mc._blocks(mc._hunks("@@ -1,6 +1,5 @@\n a\n b\n-c\n-d\n+x\n e\n f\n@@ -7,6 +6,8 @@\n g\n h\n i\n+y\n+z\n j\n k\n l"))
        self.assertEqual(blocks, [(3, 2, 1), (10, 0, 2)])
        self.assertEqual(mc._carried(blocks, 1, 2), 0)       # above every change
        self.assertEqual(mc._carried(blocks, 5, 5), -1)      # below the first, ending where the second goes in
        self.assertEqual(mc._carried(blocks, 10, 3), 1)      # starting where the second goes in
        self.assertEqual(mc._carried(blocks, 20, 3), 1)
        self.assertIsNone(mc._carried(blocks, 4, 3))         # one of its lines was replaced
        self.assertIsNone(mc._carried(blocks, 8, 4))         # lines were put in between its lines


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

    def test_a_line_that_is_not_utf8_is_counted_not_crashed_on(self):
        # claude-config#1923: one damaged tally must not stop tally_due for every repository.
        self.add(1)
        with open(v.tally_file(SLUG, home=self.home), "ab") as f:
            f.write(b"{caf\xff\n")
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


RID_BASE = "20261022T225000Z-3333333-d4e5f6"


def with_screens(doc, shots_mode=None):
    doc = json.loads(json.dumps(doc))
    doc["seeds"] = {"demo": {"synthetic": True, "why": "made up invoices from the fixture seed"}}
    doc["areas"][0]["screens"] = [{"name": "list", "path": "/invoices", "seed": "demo"}]
    if shots_mode:
        doc["screenshots"] = {"mode": shots_mode}
    return doc


class Screenshots(unittest.TestCase):
    """The pictures check (#2516), judged beside the run records, with its own mode and override."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(self.tmp.name)
        self.f.areas = with_screens(areas_doc())
        self.f.repo = {"full_name": SLUG, "private": False}

    def tearDown(self):
        self.tmp.cleanup()

    def publish_block(self):
        """Every picture shot, published through the fake git data API and rendered into the body."""
        from test_screenshots import FakeGitHub
        areas = v.parse_areas(json.dumps(self.f.areas))
        req = shots.required_shots(areas, ["invoices"])
        self.f.receipt(RID_BASE, BASE)
        for r in req:
            write(os.path.join(self.f.home, "receipts", RID if r["side"] == "head" else RID_BASE, r["name"]),
                  "png " + r["name"])
        gh = FakeGitHub()  # it answers for SLUG, the fixture's repository
        m = shots.publish(areas, SLUG, 7, RID_BASE, RID, gh=gh, home=self.f.home)
        self.f.view["body"] = shots.render_into_body(m, BODY, home=self.f.home)
        self.f.listings = {m["commit"]: [r["name"] for r in req]}
        return m

    def test_warn_names_every_missing_shot_and_still_allows(self):
        out = self.f.judge()
        self.assertEqual(out["decision"], "allow")
        self.assertTrue(out["passed"], "the run records still pass; the pictures are judged apart")
        self.assertTrue(out["say"], "a warning must reach the session even when the run check is in block mode")
        self.assertEqual([p["kind"] for p in out["screenshots"]["problems"]], ["screenshots-missing"])
        for side in ("base", "head"):
            self.assertIn("invoices list %s 1280 dark" % side, out["text"])
        self.assertIn("warn", out["text"])

    def test_block_mode_refuses_naming_the_override(self):
        self.f.areas = with_screens(areas_doc(), shots_mode="block")
        out = self.f.judge()
        self.assertEqual(out["decision"], "refuse")
        self.assertIn("invoices list head 1440 light", out["text"])
        self.assertIn("ALLOW_NO_SCREENSHOTS=1", out["text"])

    def test_the_override_allows_and_says_so(self):
        self.f.areas = with_screens(areas_doc(), shots_mode="block")
        self.f.allow_no_screenshots = True
        out = self.f.judge()
        self.assertEqual(out["decision"], "allow")
        self.assertIn("ALLOW_NO_SCREENSHOTS=1", out["text"])
        self.assertTrue(out["screenshots"]["overridden"])

    def test_the_override_does_not_excuse_a_missing_run_record(self):
        self.f.allow_no_screenshots = True
        self.f.comments = []
        self.assertEqual(self.f.judge()["decision"], "refuse")

    def test_a_published_block_passes_and_says_nothing_in_block_mode(self):
        self.f.areas = with_screens(areas_doc(), shots_mode="block")
        self.publish_block()
        out = self.f.judge()
        self.assertEqual((out["decision"], out["screenshots"]["problems"], out["say"]), ("allow", [], False))

    def test_the_folder_listing_is_asked_for_then_unreadable_on_the_final_ask(self):
        m = self.publish_block()
        self.f.listings = {}
        out = self.f.judge()
        self.assertEqual(out["need"]["listings"], [{"commit": m["commit"], "folder": m["folder"]}])
        final = self.f.judge(final=True)
        self.assertEqual([p["kind"] for p in final["screenshots"]["problems"]], ["screenshots-github-unreadable"])

    def test_a_listing_github_failed_is_unreadable(self):
        m = self.publish_block()
        self.f.listings = {m["commit"]: None}
        out = self.f.judge()
        self.assertEqual([p["kind"] for p in out["screenshots"]["problems"]], ["screenshots-github-unreadable"])

    def test_the_repository_is_asked_about_only_for_an_images_block(self):
        self.f.repo = None
        self.assertNotIn("need", self.f.judge(), "a merge with no pictures block costs no extra read")
        self.publish_block()
        self.assertTrue(self.f.judge()["need"]["repo"])
        final = self.f.judge(final=True)
        self.assertEqual([p["kind"] for p in final["screenshots"]["problems"]], ["screenshots-github-unreadable"])

    def test_a_failed_read_of_the_repository_is_unreadable_for_an_images_block(self):
        self.publish_block()
        self.f.repo = "fail"
        out = self.f.judge()
        self.assertEqual([p["kind"] for p in out["screenshots"]["problems"]], ["screenshots-github-unreadable"])

    def test_a_block_at_an_older_head_is_judged_by_the_changes_since(self):
        self.publish_block()
        self.f.view["headRefOid"] = OLD
        self.f.receipt(RID_OLD, OLD)
        self.f.comments = [comment(record(sha=OLD, rid=RID_OLD))]
        self.f.pin = "required " + OLD
        self.f.compares = {HEAD: {"status": "ahead", "files": [{"filename": "src/invoices/list.ts"}]}}
        out = self.f.judge()
        self.assertEqual([p["kind"] for p in out["screenshots"]["problems"]], ["screenshots-stale"])

    def test_warn_tally_carries_the_screenshot_kinds(self):
        self.f.areas = with_screens(areas_doc(mode="warn"))
        self.f.judge()
        self.assertIn("screenshots-missing", v.tally_read(SLUG, home=self.f.home)[7]["kinds"])

    def test_no_screens_anywhere_is_said_unmeasured_in_warn_mode(self):
        self.f.areas = areas_doc(mode="warn")
        out = self.f.judge()
        self.assertIn("Screenshots: unmeasured", out["text"])


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
