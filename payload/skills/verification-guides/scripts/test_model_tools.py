"""Tests for model_tools.py, which says whether a model check can run on this Mac (claude-config#3471).

No real checker is installed or run here. Every case puts a stand in `java` (a small shell script)
and a stand in jar in a folder of its own, so what is tested is the helper's reading of what it
finds: each way the tools can be missing or wrong is reported as the check being unable to run,
under its own kind, and never as ready (L98, L11).
"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # a module beside this one is carried by the sync: leave no cache (#2919)

JAR_BYTES = b"PK\x03\x04 a stand in for the TLA+ tools jar, not the real one\n"


class ModelToolsCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.bin = os.path.join(self.tmp.name, "bin")
        self.home = os.path.join(self.tmp.name, "home")
        os.makedirs(self.bin)
        os.makedirs(os.path.join(self.home, "tools"))
        self.jar = os.path.join(self.home, "tools", "tla2tools.jar")

    def tearDown(self):
        self.tmp.cleanup()

    def java(self, exit_code=0, text='openjdk version "21.0.5" 2024-10-15'):
        path = os.path.join(self.bin, "java")
        with open(path, "w") as f:
            f.write("#!/bin/sh\necho '%s' >&2\nexit %d\n" % (text, exit_code))
        os.chmod(path, 0o755)

    def put_jar(self, recorded=None):
        with open(self.jar, "wb") as f:
            f.write(JAR_BYTES)
        if recorded is not False:
            digest = recorded or hashlib.sha256(JAR_BYTES).hexdigest()
            with open(self.jar + ".sha256", "w") as f:
                f.write(digest + "\n")

    def check(self):
        # PATH holds only the stand in folder and the system's /bin (for sh), so a real java
        # elsewhere on this Mac can never answer for the stand in.
        env = {"PATH": self.bin + ":/bin", "VERIFICATION_HOME": self.home, "HOME": self.tmp.name}
        r = subprocess.run([sys.executable, os.path.join(HERE, "model_tools.py"), "check"],
                           capture_output=True, text=True, env=env, timeout=60)
        out = json.loads(r.stdout) if r.stdout.strip() else None
        return r, out

    def assert_cannot_run(self, r, out, kind, code):
        self.assertEqual(r.returncode, code, r.stderr)
        self.assertIn("verification: %s:" % kind, r.stderr)
        self.assertIn("could not run", r.stderr)
        self.assertIsNotNone(out)
        self.assertIs(out["ready"], False)

    def test_ready_when_java_runs_and_the_jar_matches_its_recorded_checksum(self):
        self.java()
        self.put_jar()
        r, out = self.check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIs(out["ready"], True)
        self.assertEqual(out["jar"], self.jar)
        self.assertEqual(out["sha256"], hashlib.sha256(JAR_BYTES).hexdigest())

    def test_no_java_is_could_not_run(self):
        self.put_jar()
        r, out = self.check()
        self.assert_cannot_run(r, out, "model-tools-missing", 3)
        self.assertIn("java", r.stderr)

    def test_a_java_that_will_not_start_is_could_not_run(self):
        # macOS ships a java that only says no runtime is installed, and exits 1.
        self.java(exit_code=1, text="The operation could not be completed. Unable to locate a Java Runtime.")
        self.put_jar()
        r, out = self.check()
        self.assert_cannot_run(r, out, "model-tools-broken", 4)
        # What java said is quoted, so the person reading it learns why (seen as "True" on 2026-11-26).
        self.assertIn("Unable to locate a Java Runtime", r.stderr)

    def test_no_jar_is_could_not_run(self):
        self.java()
        r, out = self.check()
        self.assert_cannot_run(r, out, "model-tools-missing", 3)
        self.assertIn("tla2tools.jar", r.stderr)

    def test_a_jar_with_no_recorded_checksum_is_could_not_run(self):
        self.java()
        self.put_jar(recorded=False)
        r, out = self.check()
        self.assert_cannot_run(r, out, "model-tools-missing", 3)
        self.assertIn("checksum", r.stderr)

    def test_a_malformed_checksum_record_is_could_not_run(self):
        self.java()
        self.put_jar(recorded="not a checksum")
        r, out = self.check()
        self.assert_cannot_run(r, out, "model-tools-unverified", 4)

    def test_a_jar_that_differs_from_its_checksum_is_could_not_run(self):
        self.java()
        self.put_jar(recorded="0" * 64)
        r, out = self.check()
        self.assert_cannot_run(r, out, "model-tools-mismatch", 4)

    def test_every_problem_is_named_at_once(self):
        r, out = self.check()
        self.assertEqual(r.stderr.count("verification: model-tools-missing:"), 2, r.stderr)
        self.assertIs(out["ready"], False)

    def test_usage(self):
        r = subprocess.run([sys.executable, os.path.join(HERE, "model_tools.py")], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
