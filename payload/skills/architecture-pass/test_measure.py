"""Tests for measure.py, the deterministic half of the architecture pass (claude-config#1504).

Every test runs against a git repository built in a throwaway directory, never a real checkout, and
against a state directory of its own, never this Mac's record of past passes.

What the manual passes of 2026-10-22 got wrong, each pinned here:
1. `git log --grep` matched commit BODIES and turned 5 real fixes into 59, so a commit whose body,
   but not its title, says fix must not count.
2. About half of one repo's "fix" titles were new features worded "Page when X stops" or "Stop X",
   so those are sorted into kinds of their own and kept out of the fix total.
3. Hot files were mostly hot because they grew, so every file carries its pure addition share.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
import measure  # noqa: E402

SCRIPT = HERE / "measure.py"
RECENT = "2026-10-20T12:00:00"
OLD = "2020-01-01T12:00:00"


def git(repo, *args, date=RECENT):
    env = dict(os.environ)
    env.update({
        "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.com",
        "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.com",
        "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date,
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
    })
    return subprocess.run(["git", "-C", str(repo), *args], check=True, env=env,
                          capture_output=True, text=True).stdout


def write(repo, rel, lines):
    p = Path(repo) / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("".join(f"{line}\n" for line in lines))


def commit(repo, message, date=RECENT):
    git(repo, "add", "-A", date=date)
    git(repo, "commit", "-q", "-m", message, date=date)


def build_fixture(root):
    """A small history holding every case the lessons name. Returns the repo path."""
    repo = Path(root) / "widgets"
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main")
    # Outside the window: a fix that must not be counted.
    write(repo, "old.ts", ["old"])
    commit(repo, "Fix old bug in old.ts", date=OLD)
    # app.ts: two pure additions, one real fix, one tidy whose BODY says it fixes a bug.
    write(repo, "app.ts", [f"line {i}" for i in range(10)])
    commit(repo, "Add app.ts")
    write(repo, "app.ts", [f"line {i}" for i in range(15)])
    commit(repo, "Grow app.ts with a feature")
    write(repo, "app.ts", ["line 0 changed"] + [f"line {i}" for i in range(1, 15)])
    commit(repo, "Fix the crash when the list is empty")
    write(repo, "app.ts", ["line 0 tidied"] + [f"line {i}" for i in range(1, 15)])
    commit(repo, "Tidy app.ts\n\nThis also fixes the bug from last week.")
    # A monitoring feature worded like a fix, and a Stop title.
    write(repo, "monitor.ts", ["watch"])
    commit(repo, "Page when the nightly sync stops")
    write(repo, "monitor.ts", ["watch", "quiet"])
    commit(repo, "Stop paging on weekends")
    # worker.ts: two concurrency fixes, then a rename, then a third under the new name.
    write(repo, "worker.ts", ["a", "b", "c"])
    commit(repo, "Add worker")
    write(repo, "worker.ts", ["a2", "b", "c"])
    commit(repo, "Fix race between two retries")
    write(repo, "worker.ts", ["a2", "b2", "c"])
    commit(repo, "Fix duplicate send when retried twice")
    git(repo, "mv", "worker.ts", "lib-worker.ts")
    commit(repo, "Move worker")
    (repo / "lib").mkdir()
    git(repo, "mv", "lib-worker.ts", "lib/worker.ts")
    write(repo, "lib/worker.ts", ["a2", "b2", "c", "d"])
    commit(repo, "Move worker into lib")
    write(repo, "lib/worker.ts", ["a2", "b2", "c3", "d"])
    write(repo, "README.md", ["the worker no longer races"])
    write(repo, "package-lock.json", ["{}"])
    commit(repo, "Fix another race in worker")
    return repo


class FixtureCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.repo = build_fixture(cls._tmp.name)
        cls.since = "2026-01-01"

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def spots(self):
        return {row["path"]: row for row in measure.hotspots(str(self.repo), "HEAD", self.since)["files"]}


class TitleRules(unittest.TestCase):
    def test_a_plain_fix_title_is_a_fix(self):
        self.assertEqual(measure.classify_title("Fix the crash when the list is empty"), (True, "missing-value"))

    def test_a_paging_feature_is_not_a_fix(self):
        is_fix, kind = measure.classify_title("Page when the nightly sync stops")
        self.assertFalse(is_fix)
        self.assertEqual(kind, "alerting-feature")

    def test_a_stop_title_is_its_own_kind_and_not_counted(self):
        self.assertEqual(measure.classify_title("Stop paging on weekends"), (False, "stop-title"))

    def test_a_title_with_no_fix_word_is_not_a_candidate(self):
        self.assertEqual(measure.classify_title("Add worker"), (False, None))

    def test_no_longer_reads_as_a_fix(self):
        is_fix, _ = measure.classify_title("Never open a fifo, so git commit no longer hangs (#1813)")
        self.assertTrue(is_fix)

    def test_concurrency_kind(self):
        self.assertEqual(measure.classify_title("Fix duplicate send when retried twice"), (True, "concurrency"))

    def test_a_word_inside_another_word_does_not_match(self):
        # "prefix" holds "fix", "debugger" holds "bug": neither is a fix title.
        self.assertEqual(measure.classify_title("Add a prefix to the debugger panel"), (False, None))


class RenameParsing(unittest.TestCase):
    def test_brace_form(self):
        self.assertEqual(measure.rename_parts("src/{a => b}/x.ts"), ("src/a/x.ts", "src/b/x.ts"))

    def test_brace_form_into_a_new_folder(self):
        self.assertEqual(measure.rename_parts("{ => lib}/worker.ts"), ("worker.ts", "lib/worker.ts"))

    def test_plain_arrow(self):
        self.assertEqual(measure.rename_parts("a.ts => b.ts"), ("a.ts", "b.ts"))

    def test_no_rename(self):
        self.assertEqual(measure.rename_parts("a.ts"), (None, "a.ts"))


class Hotspots(FixtureCase):
    def test_a_body_that_says_fix_does_not_count(self):
        app = self.spots()["app.ts"]
        self.assertEqual(app["commits"], 4)
        self.assertEqual(app["fix_commits"], 1)

    def test_the_fixture_really_holds_the_body_trap(self):
        # The positive control: git log --grep, which the manual pass used, DOES match the tidy
        # commit by its body, so a body reading implementation would fail the test above.
        grep_titles = git(self.repo, "log", "-i", "--grep=fix", f"--since={self.since}", "--format=%s").splitlines()
        self.assertIn("Tidy app.ts", grep_titles)

    def test_pure_addition_share_is_measured(self):
        app = self.spots()["app.ts"]
        self.assertEqual(app["pure_addition_commits"], 2)
        self.assertEqual(app["pure_addition_share"], 0.5)
        self.assertEqual(app["size_now"], 15)
        self.assertEqual(app["added"] - app["deleted"], 15)

    def test_history_follows_renames_to_the_current_name(self):
        spots = self.spots()
        self.assertNotIn("worker.ts", spots)
        self.assertNotIn("lib-worker.ts", spots)
        worker = spots["lib/worker.ts"]
        self.assertEqual(worker["commits"], 6)
        self.assertEqual(worker["fix_commits"], 3)

    def test_docs_and_lockfiles_are_not_hot_files(self):
        # Every fix touches the README on a repo that documents as it goes, so it topped every
        # kind on claude-config's own history until it was left out.
        spots = self.spots()
        self.assertNotIn("README.md", spots)
        self.assertNotIn("package-lock.json", spots)

    def test_commits_outside_the_window_are_not_read(self):
        self.assertNotIn("old.ts", self.spots())

    def test_the_report_names_what_it_read(self):
        out = measure.hotspots(str(self.repo), "HEAD", self.since)
        self.assertEqual(out["ref"], "HEAD")
        self.assertEqual(out["ref_sha"], git(self.repo, "rev-parse", "HEAD").strip())
        self.assertEqual(out["since"], self.since)
        self.assertEqual(out["commits_read"], 12)


class Kinds(FixtureCase):
    def test_fixes_are_sorted_into_kinds_with_the_recurring_one_first(self):
        out = measure.kinds(str(self.repo), "HEAD", self.since)
        self.assertEqual(out["fix_total"], 4)
        first = out["kinds"][0]
        self.assertEqual(first["kind"], "concurrency")
        self.assertEqual(first["count"], 3)
        self.assertEqual(first["paths"], [{"path": "lib/worker.ts", "count": 3}])

    def test_the_noise_is_reported_beside_the_fixes_not_inside_them(self):
        out = measure.kinds(str(self.repo), "HEAD", self.since)
        not_fixes = {k["kind"]: k["count"] for k in out["not_fixes"]}
        self.assertEqual(not_fixes, {"alerting-feature": 1, "stop-title": 1})
        counted = {k["kind"] for k in out["kinds"]}
        self.assertNotIn("alerting-feature", counted)
        self.assertNotIn("stop-title", counted)

    def test_the_body_fix_is_in_no_kind(self):
        out = measure.kinds(str(self.repo), "HEAD", self.since)
        titles = [t for k in out["kinds"] + out["not_fixes"] for t in k["titles"]]
        self.assertNotIn("Tidy app.ts", titles)


class DefaultRef(unittest.TestCase):
    def test_without_an_origin_ref_it_reads_head_and_says_so(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = build_fixture(tmp)
            ref, note = measure.default_ref(str(repo))
            self.assertEqual(ref, "HEAD")
            self.assertIn("no origin", note)

    def test_with_an_origin_main_it_reads_that(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = build_fixture(tmp)
            git(repo, "update-ref", "refs/remotes/origin/main", "HEAD~1")
            ref, note = measure.default_ref(str(repo))
            self.assertEqual(ref, "origin/main")
            self.assertEqual(note, "")


class RepoKey(unittest.TestCase):
    def test_ssh_and_https_remotes_give_owner_and_name(self):
        for url in ("git@github.com:acme/widgets.git", "https://github.com/acme/widgets.git",
                    "https://github.com/acme/widgets"):
            with tempfile.TemporaryDirectory() as tmp:
                git(tmp, "init", "-q")
                git(tmp, "remote", "add", "origin", url)
                self.assertEqual(measure.repo_key(tmp), "acme/widgets", url)

    def test_no_origin_is_an_error_not_a_guess(self):
        with tempfile.TemporaryDirectory() as tmp:
            git(tmp, "init", "-q")
            with self.assertRaises(measure.MeasureError):
                measure.repo_key(tmp)


class LastPass(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def test_no_record_says_so(self):
        msg = measure.last_pass("acme/widgets", self.state, "2026-10-27")
        self.assertIn("No architecture pass recorded for acme/widgets", msg)

    def test_a_pass_older_than_a_month_is_due(self):
        measure.record_pass("acme/widgets", self.state, "2026-09-20")
        msg = measure.last_pass("acme/widgets", self.state, "2026-10-27")
        self.assertIn("2026-09-20, 37 days ago", msg)
        self.assertIn("due", msg)
        self.assertNotIn("not due", msg)

    def test_a_recent_pass_is_not_due_and_says_when_it_will_be(self):
        measure.record_pass("acme/widgets", self.state, "2026-10-20")
        msg = measure.last_pass("acme/widgets", self.state, "2026-10-27")
        self.assertIn("7 days ago", msg)
        self.assertIn("not due until 2026-11-19", msg)

    def test_recording_one_repo_keeps_the_others(self):
        measure.record_pass("acme/one", self.state, "2026-09-01")
        measure.record_pass("acme/two", self.state, "2026-10-01")
        data = json.loads((Path(self.state) / "last-pass.json").read_text())
        self.assertEqual(data, {"acme/one": "2026-09-01", "acme/two": "2026-10-01"})

    def test_an_unreadable_record_is_an_error_not_an_empty_one(self):
        (Path(self.state) / "last-pass.json").write_text("{not json")
        with self.assertRaises(measure.MeasureError):
            measure.last_pass("acme/widgets", self.state, "2026-10-27")
        with self.assertRaises(measure.MeasureError):
            measure.record_pass("acme/widgets", self.state, "2026-10-27")


class CommandLine(unittest.TestCase):
    def test_the_commands_the_skill_runs_work_as_written(self):
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as state:
            repo = build_fixture(tmp)
            git(repo, "remote", "add", "origin", "git@github.com:acme/widgets.git")
            git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
            env = dict(os.environ, ARCH_PASS_STATE_DIR=state, ARCH_PASS_TODAY="2026-10-27")
            run = lambda *a: subprocess.run([sys.executable, str(SCRIPT), *a], env=env,  # noqa: E731
                                            capture_output=True, text=True)
            spots = run("hotspots", str(repo), "--since", self.since_arg())
            self.assertEqual(spots.returncode, 0, spots.stderr)
            self.assertEqual(json.loads(spots.stdout)["ref"], "origin/main")
            kinds = run("kinds", str(repo), "--since", self.since_arg())
            self.assertEqual(json.loads(kinds.stdout)["fix_total"], 4)
            first = run("last-pass", str(repo))
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertIn("No architecture pass recorded for acme/widgets", first.stdout)
            self.assertEqual(run("record-pass", str(repo)).returncode, 0)
            again = run("last-pass", str(repo))
            self.assertIn("2026-10-27, 0 days ago", again.stdout)

    def test_a_failure_exits_non_zero_with_the_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = subprocess.run([sys.executable, str(SCRIPT), "last-pass", tmp],
                                 capture_output=True, text=True)
            self.assertNotEqual(out.returncode, 0)
            self.assertTrue(out.stderr.strip())

    @staticmethod
    def since_arg():
        return "2026-01-01"


if __name__ == "__main__":
    unittest.main()
