"""Tests for screenshots.py, the before and after pictures on a UI pull request (claude-config#2516).

Each refusal is seen on a fixture built to trip it and its kind is asserted, because distinct causes
must stay distinct messages (L11). Publishing is tested against a fake of GitHub's git data API kept
in memory, so no picture leaves this Mac while the suite runs.
"""

import base64
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import verification as v  # noqa: E402
import screenshots as s  # noqa: E402

HEAD = "1111111111111111111111111111111111111111"
BASE = "3333333333333333333333333333333333333333"
OLD = "2222222222222222222222222222222222222222"
RID_H = "20261110T230000Z-1111111-a1b2c3"
RID_B = "20261110T225000Z-3333333-d4e5f6"
SLUG = "acme/widget"
PNG = b"\x89PNG\r\n\x1a\n" + b"made up pixels"
LINK = "https://claude.ai/code/artifact/0b9f7a2c-1111-4222-8333-444455556666"


def areas_doc(synthetic=True, shots_mode=None, screens=True):
    doc = {
        "schema": "verification-areas/1", "mode": "warn", "url": "http://127.0.0.1:4173",
        "commands": {"serve": "x", "ready": "true", "stop": "true", "drive": "x"},
        "seeds": {"demo-136": {"synthetic": synthetic, "why": "136 made up clients from scripts/seed.ts"}},
        "areas": [
            {"name": "invoices", "guide": ".claude/verification/guides/invoices.md", "owns": ["src/invoices/**"]},
            {"name": "api", "guide": ".claude/verification/guides/api.md", "owns": ["src/api/**"]},
        ],
        "exempt": [{"glob": "docs/**", "why": "documentation only"}],
    }
    if screens:
        doc["areas"][0]["screens"] = [{"name": "list", "path": "/invoices", "seed": "demo-136",
                                       "rows": "[data-row]", "min_rows": 136}]
    if shots_mode:
        doc["screenshots"] = {"mode": shots_mode}
    return v.parse_areas(json.dumps(doc))


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())


class FakeGitHub:
    """GitHub's git data API for one repository, in memory, answering as `gh api` does."""

    def __init__(self, private=False):
        self.private = private
        self.blobs, self.trees, self.commits, self.refs = {}, {}, {}, {}
        self.calls = []
        self.race_once = False
        self.n = 0

    def _sha(self):
        self.n += 1
        return "%040x" % (0xabc000 + self.n)

    def __call__(self, args, data=None):
        self.calls.append(list(args))
        body = json.loads(data) if data else {}
        method = args[args.index("--method") + 1] if "--method" in args else "GET"
        path = [a for a in args if a.startswith("repos/")][0]
        rest = path[len("repos/%s/" % SLUG):] if path != "repos/" + SLUG else ""
        if rest == "":
            return 0, json.dumps({"full_name": SLUG, "private": self.private}), ""
        if rest == "git/ref/heads/" + s.BRANCH:
            if s.BRANCH not in self.refs:
                return 1, "", "gh: Not Found (HTTP 404)"
            return 0, json.dumps({"object": {"sha": self.refs[s.BRANCH]}}), ""
        if rest.startswith("git/commits/") and method == "GET":
            c = self.commits[rest.split("/")[-1]]
            return 0, json.dumps({"sha": rest.split("/")[-1], "tree": {"sha": c["tree"]}}), ""
        if rest == "git/blobs":
            sha = self._sha()
            self.blobs[sha] = base64.b64decode(body["content"])
            return 0, json.dumps({"sha": sha}), ""
        if rest == "git/trees":
            sha = self._sha()
            files = dict(self.trees.get(body.get("base_tree"), {}))
            for e in body["tree"]:
                files[e["path"]] = e["sha"]
            self.trees[sha] = files
            return 0, json.dumps({"sha": sha}), ""
        if rest == "git/commits":
            sha = self._sha()
            self.commits[sha] = {"tree": body["tree"], "parents": body["parents"], "message": body["message"]}
            return 0, json.dumps({"sha": sha}), ""
        if rest == "git/refs" and method == "POST":
            name = body["ref"][len("refs/heads/"):]
            if name in self.refs:
                return 1, "", "gh: Reference already exists (HTTP 422)"
            self.refs[name] = body["sha"]
            return 0, "{}", ""
        if rest == "git/refs/heads/" + s.BRANCH and method == "PATCH":
            if self.race_once:
                # Another publish moved the branch between our read and our write.
                self.race_once = False
                other = self._sha()
                self.commits[other] = {"tree": self.commits[self.refs[s.BRANCH]]["tree"],
                                       "parents": [self.refs[s.BRANCH]], "message": "another PR"}
                self.refs[s.BRANCH] = other
                return 1, "", "gh: Update is not a fast forward (HTTP 422)"
            if self.commits[body["sha"]]["parents"] != [self.refs[s.BRANCH]]:
                return 1, "", "gh: Update is not a fast forward (HTTP 422)"
            self.refs[s.BRANCH] = body["sha"]
            return 0, "{}", ""
        return 1, "", "fake: no answer for %s %s" % (method, path)

    def files_at(self, commit):
        return self.trees[self.commits[commit]["tree"]]

    def posts(self, what):
        return [c for c in self.calls if any(a.endswith(what) for a in c) and "POST" in c]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = os.path.join(self.tmp.name, "home")
        self.areas = areas_doc()

    def tearDown(self):
        self.tmp.cleanup()

    def receipt(self, rid, sha, shots=(), areas=("invoices",)):
        rdir = os.path.join(self.home, "receipts", rid)
        rec = {"schema": "verification-receipt/1", "receipt_id": rid, "machine": v.machine_name(),
               "head_sha": sha, "areas": list(areas), "stopped_at": "2026-11-10T23:10:00Z", "stopped_by": "stop"}
        write(os.path.join(rdir, "receipt.json"), json.dumps(rec))
        for name in shots:
            write(os.path.join(rdir, name), PNG + name.encode())
        return rdir

    def shoot_all(self, same=False):
        req = s.required_shots(self.areas, ["invoices"])
        self.receipt(RID_B, BASE, [r["name"] for r in req if r["side"] == "base"])
        self.receipt(RID_H, HEAD, [r["name"] for r in req if r["side"] == "head"])
        if same:
            for r in req:
                write(os.path.join(self.home, "receipts", RID_H if r["side"] == "head" else RID_B, r["name"]),
                      PNG + ("%s-%s-%s" % (r["screen"], r["width"], r["theme"])).encode())
        return req

    def publish(self, gh, link=None, pr=7):
        return s.publish(self.areas, SLUG, pr, RID_B, RID_H, gh=gh, home=self.home, link=link)


class AreasScreens(Base):
    def test_screens_and_seeds_are_read(self):
        a = self.areas["areas"][0]
        self.assertEqual(a["screens"][0]["name"], "list")
        self.assertEqual(self.areas["seeds"]["demo-136"]["synthetic"], True)

    def test_the_block_switch_is_present_and_off_by_default(self):
        self.assertEqual(areas_doc()["screenshots"]["mode"], "warn")
        self.assertEqual(areas_doc(shots_mode="block")["screenshots"]["mode"], "block")

    def test_a_screen_naming_an_undeclared_seed_is_refused(self):
        doc = json.loads(json.dumps(areas_doc()))
        doc["areas"][0]["screens"][0]["seed"] = "nope"
        with self.assertRaises(v.VerificationError) as e:
            v.parse_areas(json.dumps(doc))
        self.assertIn("areas-unknown-seed", [k for k, _ in e.exception.problems])

    def test_a_seed_with_no_why_is_refused(self):
        doc = json.loads(json.dumps(areas_doc()))
        doc["seeds"]["demo-136"]["why"] = ""
        with self.assertRaises(v.VerificationError) as e:
            v.parse_areas(json.dumps(doc))
        self.assertIn("areas-seed-no-why", [k for k, _ in e.exception.problems])

    def test_a_seed_whose_synthetic_flag_is_not_a_boolean_is_refused(self):
        doc = json.loads(json.dumps(areas_doc()))
        doc["seeds"]["demo-136"]["synthetic"] = "yes"
        with self.assertRaises(v.VerificationError) as e:
            v.parse_areas(json.dumps(doc))
        self.assertIn("areas-bad-seed", [k for k, _ in e.exception.problems])

    def test_a_screen_with_a_bad_path_or_name_is_refused(self):
        doc = json.loads(json.dumps(areas_doc()))
        doc["areas"][0]["screens"] = [{"name": "List!", "path": "invoices", "seed": "demo-136"}]
        with self.assertRaises(v.VerificationError) as e:
            v.parse_areas(json.dumps(doc))
        self.assertEqual(["areas-bad-screen", "areas-bad-screen"], [k for k, _ in e.exception.problems])

    def test_an_unknown_screenshots_mode_is_refused(self):
        doc = json.loads(json.dumps(areas_doc()))
        doc["screenshots"] = {"mode": "sometimes"}
        with self.assertRaises(v.VerificationError) as e:
            v.parse_areas(json.dumps(doc))
        self.assertIn("areas-bad-screenshots-mode", [k for k, _ in e.exception.problems])


class Recognising(Base):
    def test_a_pull_request_is_ui_when_it_touches_an_area_with_screens(self):
        self.assertEqual([a["name"] for a in s.ui_areas(self.areas, ["invoices", "api"])], ["invoices"])
        self.assertEqual(s.ui_areas(self.areas, ["api"]), [])

    def test_each_screen_needs_eight_shots_base_and_head_two_widths_two_themes(self):
        req = s.required_shots(self.areas, ["invoices"])
        self.assertEqual(len(req), 8)
        self.assertEqual({(r["side"], r["width"], r["theme"]) for r in req},
                         {(sd, w, t) for sd in ("base", "head") for w in (1440, 1280) for t in ("light", "dark")})
        self.assertIn("invoices__list__base__1440__light.png", [r["name"] for r in req])


class Shooting(Base):
    def test_each_shot_goes_through_the_logged_drive_call_with_the_helper_contract(self):
        self.receipt(RID_H, HEAD)
        calls = []

        class Done:
            returncode = 0

        def run(argv):
            calls.append(argv)
            name = argv[argv.index("--") + 5]
            if not name.endswith("1280__dark.png"):
                write(os.path.join(self.home, "receipts", RID_H, name), PNG)
            return Done()
        failed = s.shoot(RID_H, "head", self.areas, run=run, home=self.home)
        self.assertEqual(len(calls), 4)
        first = calls[0]
        self.assertEqual(first[2:6], ["drive", RID_H, "--area", "invoices"])
        self.assertEqual(first[first.index("--") + 1:],
                         ["screenshot", "/invoices", "1440", "light", "invoices__list__head__1440__light.png",
                          "[data-row]", "136"])
        self.assertEqual([label for label in map(s.label, failed)], ["invoices list head 1280 dark"],
                         "a helper that exits 0 without saving its picture is a failed shot")


class Publishing(Base):
    def test_public_repo_with_a_synthetic_seed_gets_images_on_an_orphan_branch(self):
        self.shoot_all()
        gh = FakeGitHub(private=False)
        m = self.publish(gh)
        self.assertEqual(m["mode"], "images")
        commit = gh.refs[s.BRANCH]
        self.assertEqual(m["commit"], commit)
        self.assertEqual(gh.commits[commit]["parents"], [], "the first publish starts an orphan branch")
        files = gh.files_at(commit)
        self.assertEqual(len(files), 8)
        shot = m["shots"][0]
        self.assertIn("pr-7/%s/%s" % (HEAD, shot["name"]), files)
        self.assertEqual(shot["url"], "https://github.com/%s/blob/%s/pr-7/%s/%s?raw=true" % (SLUG, commit, HEAD, shot["name"]))

    def test_a_second_publish_keeps_every_older_picture(self):
        self.shoot_all()
        gh = FakeGitHub()
        first = self.publish(gh)
        second = self.publish(gh, pr=8)
        files = gh.files_at(second["commit"])
        self.assertEqual(len(files), 16, "old screenshots are never pruned")
        self.assertEqual(gh.commits[second["commit"]]["parents"], [first["commit"]])

    def test_a_publish_that_loses_a_race_for_the_branch_tries_again_on_the_new_tip(self):
        self.shoot_all()
        gh = FakeGitHub()
        self.publish(gh)
        gh.race_once = True
        m = self.publish(gh, pr=8)
        self.assertEqual(gh.refs[s.BRANCH], m["commit"])
        self.assertEqual(len(gh.files_at(m["commit"])), 16)

    def test_public_repo_without_a_synthetic_seed_uploads_nothing_and_needs_a_private_link(self):
        self.areas = areas_doc(synthetic=False)
        self.shoot_all()
        gh = FakeGitHub(private=False)
        with self.assertRaises(v.VerificationError) as e:
            self.publish(gh)
        self.assertEqual(e.exception.problems[0][0], "screenshots-need-private-link")
        self.assertEqual(gh.posts("git/blobs"), [], "no picture of real data may reach a public repository")

    def test_public_repo_without_a_synthetic_seed_with_a_private_link(self):
        self.areas = areas_doc(synthetic=False)
        self.shoot_all()
        gh = FakeGitHub(private=False)
        m = self.publish(gh, link=LINK)
        self.assertEqual(m["mode"], "link")
        self.assertEqual(gh.posts("git/blobs"), [])
        self.assertTrue(all(sh["url"] is None for sh in m["shots"]))

    def test_a_private_repo_uses_the_private_link_until_inline_rendering_is_measured(self):
        self.assertFalse(s.PRIVATE_REPO_IMAGES, "flip this test with the constant, once the render is measured")
        self.shoot_all()
        gh = FakeGitHub(private=True)
        with self.assertRaises(v.VerificationError) as e:
            self.publish(gh)
        self.assertEqual(e.exception.problems[0][0], "screenshots-need-private-link")
        self.assertEqual(gh.posts("git/blobs"), [])

    def test_a_link_that_is_not_a_claude_artifact_is_refused(self):
        self.areas = areas_doc(synthetic=False)
        self.shoot_all()
        with self.assertRaises(v.VerificationError) as e:
            self.publish(FakeGitHub(), link="https://example.com/pics")
        self.assertEqual(e.exception.problems[0][0], "screenshots-bad-link")

    def test_a_missing_shot_is_refused_naming_area_screen_side_width_and_theme(self):
        self.shoot_all()
        os.remove(os.path.join(self.home, "receipts", RID_H, "invoices__list__head__1280__dark.png"))
        gh = FakeGitHub()
        with self.assertRaises(v.VerificationError) as e:
            self.publish(gh)
        kind, msg = e.exception.problems[0]
        self.assertEqual(kind, "screenshots-missing-shot")
        self.assertIn("invoices list head 1280 dark", msg)
        self.assertEqual(gh.posts("git/blobs"), [])

    def test_the_same_receipt_on_both_sides_is_refused(self):
        self.shoot_all()
        with self.assertRaises(v.VerificationError) as e:
            s.publish(self.areas, SLUG, 7, RID_H, RID_H, gh=FakeGitHub(), home=self.home)
        self.assertEqual(e.exception.problems[0][0], "screenshots-same-receipt")

    def test_github_unreadable_for_the_repository_is_its_own_refusal(self):
        self.shoot_all()

        def broken(args, data=None):
            return 1, "", "gh: connection refused"
        with self.assertRaises(v.VerificationError) as e:
            self.publish(broken)
        self.assertEqual(e.exception.problems[0][0], "screenshots-github-unreadable")

    def test_a_blob_upload_that_fails_is_said_and_moves_no_branch(self):
        self.shoot_all()
        gh = FakeGitHub()
        real = gh.__call__

        def failing(args, data=None):
            if any(a.endswith("git/blobs") for a in args):
                return 1, "", "gh: Server Error (HTTP 502)"
            return real(args, data)
        with self.assertRaises(v.VerificationError) as e:
            self.publish(failing)
        self.assertEqual(e.exception.problems[0][0], "screenshots-upload-failed")
        self.assertEqual(gh.refs, {})

    def test_identical_pairs_are_said_as_no_visible_change(self):
        self.shoot_all(same=True)
        m = self.publish(FakeGitHub())
        self.assertTrue(m["no_visible_change"])


class Block(Base):
    def published(self, **kw):
        self.shoot_all(**kw)
        self.gh = FakeGitHub()
        return self.publish(self.gh)

    def test_render_then_parse_gives_the_manifest_back(self):
        m = self.published()
        body = s.apply_block("Fixes the list.\n", s.render_block(m))
        found = s.parse_block(body)
        self.assertEqual(found["manifest"], m)
        self.assertIn("## Screenshots", body)
        self.assertIn("![invoices list before 1440 light](%s)" % m["shots"][0]["url"], body)

    def test_rendering_twice_leaves_one_block(self):
        m = self.published()
        body = s.apply_block("Fixes the list.\n", s.render_block(m))
        again = s.apply_block(body, s.render_block(m))
        self.assertEqual(body, again)
        self.assertEqual(again.count(s.BEGIN), 1)

    def test_a_block_above_other_sections_is_replaced_in_place(self):
        m = self.published()
        body = s.apply_block("Intro.\n", s.render_block(m)) + "\n## Done when\n- [ ] it works\n"
        again = s.apply_block(body, s.render_block(m))
        self.assertTrue(again.endswith("## Done when\n- [ ] it works\n"))
        self.assertEqual(again.count("## Screenshots"), 1)

    def test_no_visible_change_is_said_in_the_block(self):
        m = self.published(same=True)
        self.assertIn("No visible change measured", s.render_block(m))

    def test_render_remembers_the_fingerprint_beside_the_head_receipt(self):
        m = self.published()
        body = s.render_into_body(m, "Fixes the list.\n", home=self.home)
        digests = s.load_block_digests(RID_H, self.home)
        self.assertIn(s.block_digest(s.parse_block(body)["text"]), digests)

    def test_a_body_github_gave_back_with_crlf_line_ends_has_the_same_fingerprint(self):
        m = self.published()
        body = s.render_into_body(m, "Fixes the list.\n", home=self.home)
        crlf = body.replace("\n", "\r\n")
        self.assertEqual(s.block_digest(s.parse_block(crlf)["text"]), s.block_digest(s.parse_block(body)["text"]))


class Judging(Base):
    def judge(self, body, listing=None, changed_since=None, touched=("invoices",), areas=None, head=HEAD,
              private=False):
        return s.judge(areas or self.areas, list(touched), body, head, private=private,
                       listings=listing if listing is not None else self.listings(), changed_since=changed_since,
                       home=self.home)

    def listings(self):
        out = {}
        gh = getattr(self, "gh", None)
        for commit in (gh.commits if gh else {}):
            out[commit] = [p.split("/")[-1] for p in gh.files_at(commit) if p.startswith("pr-7/%s/" % HEAD)]
        return out

    def good_body(self, **kw):
        self.shoot_all(**kw)
        self.gh = FakeGitHub()
        m = self.publish(self.gh)
        return s.render_into_body(m, "Fixes the list.\n", home=self.home), m

    def kinds(self, out):
        return sorted({p["kind"] for p in out["problems"]})

    def test_a_ui_pull_request_with_a_rendered_block_passes(self):
        body, _ = self.good_body()
        self.assertEqual(self.judge(body)["problems"], [])

    def test_no_block_names_every_missing_shot(self):
        out = self.judge("Fixes the list.\n")
        self.assertEqual(self.kinds(out), ["screenshots-missing"])
        msg = out["problems"][0]["message"]
        for side in ("base", "head"):
            for w in (1440, 1280):
                for t in ("light", "dark"):
                    self.assertIn("invoices list %s %d %s" % (side, w, t), msg)

    def test_a_pull_request_touching_no_screen_needs_no_pictures(self):
        out = self.judge("Fixes the api.\n", touched=("api",))
        self.assertEqual(out["problems"], [])
        self.assertEqual(out["required"], [])

    def test_no_area_declaring_screens_is_reported_unmeasured_not_passed(self):
        out = self.judge("x\n", areas=areas_doc(screens=False))
        self.assertEqual(out["problems"], [])
        self.assertTrue(out["unmeasured"])
        self.assertIn("unmeasured", out["note"])

    def test_a_block_edited_by_hand_is_refused(self):
        body, m = self.good_body()
        edited = body.replace("1440 light", "1440 lite", 1)
        self.assertEqual(self.kinds(self.judge(edited)), ["screenshots-edited"])

    def test_a_block_whose_fingerprint_is_not_on_this_machine(self):
        body, _ = self.good_body()
        os.remove(os.path.join(self.home, "receipts", RID_H, "rendered-screenshots.jsonl"))
        self.assertEqual(self.kinds(self.judge(body)), ["screenshots-edited"])

    def test_a_block_rendered_at_an_older_head_is_stale_when_a_ui_file_changed_since(self):
        body, _ = self.good_body()
        out = self.judge(body, head=OLD, changed_since=["src/invoices/list.tsx"])
        self.assertEqual(self.kinds(out), ["screenshots-stale"])

    def test_a_block_at_an_older_head_counts_when_only_other_files_changed_since(self):
        body, _ = self.good_body()
        self.assertEqual(self.judge(body, head=OLD, changed_since=["docs/readme.md"])["problems"], [])

    def test_a_block_at_an_older_head_asks_for_the_changes_since(self):
        body, _ = self.good_body()
        out = self.judge(body, head=OLD, changed_since=None)
        self.assertEqual(out["need"]["compares"], [HEAD])

    def test_a_shot_dropped_from_the_block_is_named(self):
        self.shoot_all()
        self.gh = FakeGitHub()
        m = self.publish(self.gh)
        m["shots"] = [sh for sh in m["shots"] if sh["name"] != "invoices__list__base__1280__dark.png"]
        body = s.render_into_body(m, "x\n", home=self.home)
        out = self.judge(body)
        self.assertEqual(self.kinds(out), ["screenshots-missing-shot"])
        self.assertIn("invoices list base 1280 dark", out["problems"][0]["message"])

    def test_images_of_a_seed_not_declared_made_up_in_a_public_repo_are_refused(self):
        body, _ = self.good_body()
        out = self.judge(body, areas=areas_doc(synthetic=False))
        self.assertIn("screenshots-public-not-synthetic", self.kinds(out))

    def test_the_same_images_in_a_private_repo_are_not_a_public_leak(self):
        body, _ = self.good_body()
        out = self.judge(body, areas=areas_doc(synthetic=False), private=True)
        self.assertNotIn("screenshots-public-not-synthetic", self.kinds(out))

    def test_visibility_github_could_not_tell_is_unreadable_for_an_images_block(self):
        body, _ = self.good_body()
        out = self.judge(body, areas=areas_doc(synthetic=False), private=None)
        self.assertEqual(self.kinds(out), ["screenshots-github-unreadable"])

    def test_a_link_that_does_not_resolve_is_refused(self):
        body, m = self.good_body()
        self.assertEqual(self.kinds(self.judge(body, listing={m["commit"]: []})), ["screenshots-link-unresolved"])

    def test_a_folder_github_could_not_list_is_unreadable_not_unresolved(self):
        body, m = self.good_body()
        out = self.judge(body, listing={m["commit"]: None})
        self.assertEqual(self.kinds(out), ["screenshots-github-unreadable"])

    def test_the_folder_listing_is_asked_for_when_absent(self):
        body, m = self.good_body()
        out = self.judge(body, listing={})
        self.assertEqual(out["need"]["listings"], [{"commit": m["commit"], "folder": m["folder"]}])

    def test_a_link_mode_block_passes_without_a_listing(self):
        self.areas = areas_doc(synthetic=False)
        self.shoot_all()
        m = self.publish(FakeGitHub(), link=LINK)
        body = s.render_into_body(m, "x\n", home=self.home)
        self.assertIn(LINK, body)
        self.assertEqual(self.judge(body, listing={})["problems"], [])

    def test_a_folder_outside_the_published_shape_is_refused_and_never_listed(self):
        self.shoot_all()
        self.gh = FakeGitHub()
        m = self.publish(self.gh)
        m["folder"] = "../../other/" + HEAD
        body = s.render_into_body(m, "x\n", home=self.home)
        out = self.judge(body, listing={})
        self.assertEqual(self.kinds(out), ["screenshots-link-unresolved"])
        self.assertEqual(out["need"]["listings"], [], "a folder from the PR body never reaches a GitHub path")

    def test_two_blocks_are_malformed(self):
        body, _ = self.good_body()
        self.assertEqual(self.kinds(self.judge(body + "\n" + body)), ["screenshots-malformed"])


NATIVE_SCREEN = {"name": "list", "test": "AppHostedTests/VerificationScreens", "frame": "invoice-list",
                 "seed": "demo-136", "min_rows": 13}


def native_doc(screen=None, command="xcodebuild test -only-testing:\"$VERIFICATION_SHOT_TEST\""):
    """areas.json for a native app: its screen is an offscreen test and a frame, not a route (#2696)."""
    doc = json.loads(json.dumps(areas_doc(screens=False)))
    doc["areas"][0]["screens"] = [dict(NATIVE_SCREEN, **(screen or {}))]
    if command is not None:
        doc["commands"]["native_shot"] = command
    for k in ("timeouts", "egress"):
        doc.pop(k, None)
    return doc


class NativeScreens(Base):
    """A native screen (claude-config#2696): the same eight pictures, taken by an offscreen test."""

    def refused(self, doc):
        with self.assertRaises(v.VerificationError) as e:
            v.parse_areas(json.dumps(doc))
        return [k for k, _ in e.exception.problems], " ".join(m for _, m in e.exception.problems)

    def test_a_native_screen_is_read_with_its_test_frame_and_shot_command(self):
        areas = v.parse_areas(json.dumps(native_doc()))
        sc = areas["areas"][0]["screens"][0]
        self.assertEqual((sc["test"], sc["frame"], sc["min_rows"]), ("AppHostedTests/VerificationScreens", "invoice-list", 13))
        self.assertIn("native_shot", areas["commands"])

    def test_a_native_screen_still_needs_its_eight_pictures(self):
        areas = v.parse_areas(json.dumps(native_doc()))
        self.assertEqual(len(s.required_shots(areas, ["invoices"])), 8)

    def test_a_native_screen_with_no_shot_command_is_refused(self):
        kinds, why = self.refused(native_doc(command=None))
        self.assertEqual(kinds, ["areas-native-no-shot-command"])
        self.assertIn("commands.native_shot", why)

    def test_a_screen_giving_both_a_route_and_a_test_is_refused(self):
        kinds, why = self.refused(native_doc({"path": "/invoices"}))
        self.assertEqual(kinds, ["areas-bad-screen"])
        self.assertIn("a route or a test, not both", why)

    def test_a_native_screen_with_a_css_selector_is_refused(self):
        kinds, why = self.refused(native_doc({"rows": "[data-row]"}))
        self.assertEqual(kinds, ["areas-bad-screen"])
        self.assertIn("no CSS selector", why)

    def test_a_native_screen_with_no_frame_or_a_bad_one_is_refused(self):
        for frame in (None, "Invoice List", "a__b", "x" * 80):
            screen = dict(NATIVE_SCREEN, frame=frame)
            if frame is None:
                del screen["frame"]
            doc = native_doc()
            doc["areas"][0]["screens"] = [screen]
            kinds, why = self.refused(doc)
            self.assertEqual(kinds, ["areas-bad-screen"], frame)
            self.assertIn("frame", why)

    def test_a_test_identifier_that_is_not_one_is_refused(self):
        for test in ("", "Target/$(rm -rf ~)", "Target Name", "/Leading", "Target//Double", 7):
            kinds, why = self.refused(native_doc({"test": test}))
            self.assertEqual(kinds, ["areas-bad-screen"], test)
            self.assertIn("test", why)

    def test_a_swift_testing_function_identifier_is_accepted(self):
        areas = v.parse_areas(json.dumps(native_doc({"test": "AppHostedTests/VerificationScreens/shoot()"})))
        self.assertEqual(areas["areas"][0]["screens"][0]["test"], "AppHostedTests/VerificationScreens/shoot()")

    def test_a_native_min_rows_must_be_a_whole_number_of_at_least_one(self):
        for bad in (0, "13", True, 1.5):
            kinds, _ = self.refused(native_doc({"min_rows": bad}))
            self.assertEqual(kinds, ["areas-bad-screen"], bad)

    def test_a_native_screen_without_min_rows_is_read(self):
        screen = dict(NATIVE_SCREEN)
        del screen["min_rows"]
        doc = native_doc()
        doc["areas"][0]["screens"] = [screen]
        self.assertNotIn("min_rows", v.parse_areas(json.dumps(doc))["areas"][0]["screens"][0])

    def test_an_empty_shot_command_is_refused(self):
        kinds, _ = self.refused(native_doc(command="  "))
        self.assertEqual(kinds, ["areas-empty-command"])

    def test_each_native_shot_goes_through_the_drive_call_with_the_native_contract(self):
        self.areas = v.parse_areas(json.dumps(native_doc()))
        self.receipt(RID_H, HEAD)
        calls = []

        class Done:
            returncode = 0

        def run(argv):
            calls.append(argv)
            write(os.path.join(self.home, "receipts", RID_H, argv[argv.index("--") + 6]), PNG)
            return Done()
        self.assertEqual(s.shoot(RID_H, "head", self.areas, run=run, home=self.home), [])
        self.assertEqual(len(calls), 4)
        first = calls[0]
        self.assertEqual(first[2:6], ["drive", RID_H, "--area", "invoices"])
        self.assertEqual(first[first.index("--") + 1:],
                         ["screenshot-native", "AppHostedTests/VerificationScreens", "invoice-list", "1440", "light",
                          "invoices__list__head__1440__light.png", "13"])

    def test_a_native_screen_without_min_rows_passes_zero(self):
        doc = native_doc()
        del doc["areas"][0]["screens"][0]["min_rows"]
        self.areas = v.parse_areas(json.dumps(doc))
        self.receipt(RID_H, HEAD)
        calls = []

        class Done:
            returncode = 0

        def run(argv):
            calls.append(argv)
            return Done()
        failed = s.shoot(RID_H, "head", self.areas, run=run, home=self.home)
        self.assertEqual(calls[0][-1], "0")
        self.assertEqual(len(failed), 4, "a helper that saved nothing failed every shot")

    def test_a_native_screen_publishes_and_renders_naming_its_test_and_frame(self):
        self.areas = v.parse_areas(json.dumps(native_doc()))
        self.shoot_all()
        gh = FakeGitHub()
        m = self.publish(gh)
        self.assertEqual(m["screens"][0]["test"], "AppHostedTests/VerificationScreens")
        self.assertEqual(m["screens"][0]["frame"], "invoice-list")
        self.assertNotIn("path", m["screens"][0])
        block = s.render_block(m)
        self.assertIn("### invoices: list (test `AppHostedTests/VerificationScreens`, frame `invoice-list`, seed demo-136)",
                      block)
        self.assertEqual(block.count("![invoices list"), 8)

    def test_the_merge_check_judges_a_native_block_unchanged(self):
        self.areas = v.parse_areas(json.dumps(native_doc()))
        self.shoot_all()
        self.gh = FakeGitHub()
        body = s.render_into_body(self.publish(self.gh), "Fixes the list.\n", home=self.home)
        listings = {c: [p.split("/")[-1] for p in self.gh.files_at(c) if p.startswith("pr-7/%s/" % HEAD)]
                    for c in self.gh.commits}
        out = s.judge(self.areas, ["invoices"], body, HEAD, private=False, listings=listings, changed_since=None,
                      home=self.home)
        self.assertEqual(out["problems"], [])

    def test_a_web_screen_still_publishes_its_route(self):
        self.shoot_all()
        m = self.publish(FakeGitHub())
        self.assertEqual(m["screens"][0]["path"], "/invoices")
        self.assertIn("### invoices: list (`/invoices`, seed demo-136)", s.render_block(m))


class BadBytes(unittest.TestCase):
    """A byte that is not UTF-8 in what gh prints is read, and one in the PR body is refused by name."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))

    def test_gh_output_holding_a_byte_that_is_not_utf8_is_read_not_raised_on(self):
        from unittest import mock
        gh = os.path.join(self.tmp, "gh")
        with open(gh, "w", errors="strict") as f:
            f.write("#!/bin/sh\nprintf '{\"sha\":\"abc\",\"note\":\"\\377\"}'\nprintf 'warn \\377' >&2\n")
        os.chmod(gh, 0o755)
        with mock.patch.dict(os.environ, {"PATH": self.tmp + os.pathsep + os.environ.get("PATH", "")}):
            rc, out, err = s._gh(["api", "x"])
        self.assertEqual(rc, 0)
        self.assertEqual(s._json(out)["sha"], "abc")
        self.assertIn("\ufffd", out + err)

    def test_a_pr_body_holding_a_byte_that_is_not_utf8_is_refused_not_rewritten(self):
        manifest = os.path.join(self.tmp, "m.json")
        body = os.path.join(self.tmp, "body.md")
        with open(manifest, "w", errors="strict") as f:
            json.dump({}, f)
        with open(body, "wb") as f:
            f.write(b"before \xff after\n")
        with self.assertRaises(UnicodeDecodeError):
            s.main(["render", "--manifest", manifest, "--body", body])


if __name__ == "__main__":
    unittest.main()
