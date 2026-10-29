#!/usr/bin/env bash
# send-gate: scans skills/ hooks/lib/skill-python-tests.py
# runs: hooks/lib/skill-python-tests.py over payload/skills
# Runs every Python test file a skill ships, found from disk, and proves the runner that does it
# can fail (claude-config#676).
#
# Skill tests used to need a `test-*.sh` wrapper each before run-all-tests.sh would find them, and a
# skill that forgot one shipped tests nothing ran: payload/skills/reel-plan/scripts/
# test_render_card.py held 28 tests and had no wrapper, so none of them ran anywhere. A behaviour
# every skill has to opt into is one the next skill forgets (L621), so there is one runner,
# hooks/lib/skill-python-tests.py, and this one suite hands it the whole skills folder. A test file
# added to any skill runs on the day it lands, with nothing to register, and no file is run twice
# because nothing else runs them.
#
# The runner is checked against fixtures first, each built so a broken runner would pass it
# (L1, L98): a failing test, a module that cannot import, a folder with no tests, a test file with no
# tests in it, a test that asks for an argument it cannot be given, and a file whose process ends
# without reporting. Only then is the real tree run and its counts added to this suite's own.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$DIR/lib/skill-python-tests.py"
ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
SKILLS="$ROOT/payload/skills"
# The repository's skills, never an installed ~/.claude/skills: that folder also holds skills no send
# carries (the Claude app's own downloads, plugin skills), whose tests this suite has no say over
# (L36). An installed copy says so in the shape the runner reads as NOT RUN, and the runner re-runs
# it from the checkout (claude-config#155, #237).
if [ -z "$ROOT" ] || [ ! -d "$SKILLS" ]; then
  printf 'SUITE-NOT-RUN %s\n' "runs the repository's payload/skills tests, and there is no repository above $DIR"
  exit 2
fi

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /' | awk 'NR <= 30'; return 0; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not on PATH, so no skill's Python tests could be run. Refusing to report them as passing."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/skill-py-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

run() { # run <dir>...: sets out and rc
  out="$(python3 "$RUNNER" "$@" 2>&1)"; rc=$?
}
result_of() { # the runner's own count line, never a scrape of unittest's summary (L107)
  printf '%s\n' "$out" | sed -n 's/^PY-TESTS-RESULT passed=\([0-9]*\) failed=\([0-9]*\)$/\1 \2/p' | tail -n 1
}

# --- a healthy skill: a unittest class and a bare function, each in a different file ------------
mkdir -p "$TMP/good/tests" "$TMP/good/scripts"
cat > "$TMP/good/tests/test_unit.py" <<'PY'
import unittest
class T(unittest.TestCase):
    def test_adds(self):
        self.assertEqual(1 + 1, 2)
PY
cat > "$TMP/good/scripts/test_bare.py" <<'PY'
def testdata():
    return ["a", "b"]


def test_plain_assert():
    assert "a" in testdata()
PY
run "$TMP/good"
[ "$rc" -eq 0 ] && [ "$(result_of)" = "2 0" ] && ok \
  || bad "a unittest class and a bare test function both run and pass (rc=$rc, result=$(result_of))" "$out"

# --- a failing bare function fails the run and names itself --------------------------------------
mkdir -p "$TMP/red"
cat > "$TMP/red/test_red.py" <<'PY'
def test_this_one_is_wrong():
    assert 1 == 2, "one is not two"
def test_this_one_is_right():
    assert True
PY
run "$TMP/red"
[ "$rc" -eq 1 ] && [ "$(result_of)" = "1 1" ] && grep -q 'test_this_one_is_wrong' <<< "$out" && ok \
  || bad "a failing test fails the run, is counted, and is named (rc=$rc, result=$(result_of))" "$out"

# --- counts are test methods, so subTests can never drive the pass count below zero (#1855) -------
# Each failing subTest adds its own failure or error while testsRun counts its method once, and the
# runner once subtracted the first from the second: a file whose subTests all errored printed
# passed=-12 failed=37. Two methods whose every case fails or errors are two failed methods.
mkdir -p "$TMP/subfail"
cat > "$TMP/subfail/test_subfail.py" <<'PY'
import unittest
class T(unittest.TestCase):
    def test_every_case_errors(self):
        for n in range(5):
            with self.subTest(n=n):
                raise AttributeError("the module under test is empty")
    def test_every_case_fails(self):
        for n in range(4):
            with self.subTest(n=n):
                self.assertEqual(n, -1)
PY
run "$TMP/subfail"
[ "$rc" -eq 1 ] && [ "$(result_of)" = "0 2" ] && grep -q 'test_subfail.py passed=0 failed=2$' <<< "$out" && ok \
  || bad "a file whose subTests all fail or error counts two failed methods and passed=0, never negative (rc=$rc, result=$(result_of))" "$out"

# A method passes only if none of its subTests failed or errored; one skipped as a whole is neither
# passed nor failed, while one whose cases skip but which itself ran to the end counts as passed.
mkdir -p "$TMP/submixed"
cat > "$TMP/submixed/test_submixed.py" <<'PY'
import unittest
class T(unittest.TestCase):
    def test_some_cases_fail(self):
        for n in range(4):
            with self.subTest(n=n):
                self.assertLess(n, 2)
    def test_all_cases_pass(self):
        for n in range(3):
            with self.subTest(n=n):
                self.assertGreaterEqual(n, 0)
    def test_plain_no_subtest(self):
        self.assertTrue(True)
    def test_whole_method_skipped(self):
        self.skipTest("not on this machine")
    def test_cases_skipped(self):
        for n in range(3):
            with self.subTest(n=n):
                self.skipTest("each case skipped")
PY
run "$TMP/submixed"
[ "$rc" -eq 1 ] && [ "$(result_of)" = "3 1" ] && ok \
  || bad "a method with some failing subTests is one failure, and its passing neighbours still count (rc=$rc, result=$(result_of))" "$out"

# A class whose setUpClass fails runs none of its methods and is reported as one failure, beside a
# plain test in the same file that still passes, never as a file that holds no tests.
mkdir -p "$TMP/classfail"
cat > "$TMP/classfail/test_classfail.py" <<'PY'
import unittest
class T(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raise RuntimeError("class setup broke")
    def test_never_runs(self):
        pass
def test_plain_passes():
    assert True
PY
run "$TMP/classfail"
[ "$rc" -eq 1 ] && [ "$(result_of)" = "1 1" ] && grep -q 'class setup broke' <<< "$out" && ok \
  || bad "a failing setUpClass is one failure and the passing plain test still counts (rc=$rc, result=$(result_of))" "$out"

mkdir -p "$TMP/classonly"
cat > "$TMP/classonly/test_classonly.py" <<'PY'
import unittest
class T(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raise RuntimeError("class setup broke")
    def test_never_runs(self):
        pass
PY
run "$TMP/classonly"
[ "$rc" -eq 1 ] && [ "$(result_of)" = "0 1" ] && ! grep -q 'holds no tests' <<< "$out" && ok \
  || bad "a file whose only class fails setUpClass is one failure, not also a file with no tests (rc=$rc, result=$(result_of))" "$out"

# --- a module that cannot import is a failure, never a smaller run --------------------------------
mkdir -p "$TMP/noimport"
printf 'import a_module_that_does_not_exist_anywhere\ndef test_x():\n    pass\n' > "$TMP/noimport/test_broken.py"
run "$TMP/noimport"
[ "$rc" -eq 1 ] && grep -q 'test_broken.py' <<< "$out" && grep -q 'a_module_that_does_not_exist_anywhere' <<< "$out" && ok \
  || bad "a test file that cannot import fails the run and names the file and the cause (rc=$rc)" "$out"

# --- nothing to run is not a pass ---------------------------------------------------------------
mkdir -p "$TMP/empty/scripts"
printf 'print("not a test")\n' > "$TMP/empty/scripts/tool.py"
run "$TMP/empty"
[ "$rc" -ne 0 ] && grep -q 'found no test files' <<< "$out" && ok \
  || bad "a folder holding no test files is refused, not reported as passing (rc=$rc)" "$out"

# --- a test file that holds no tests is not a pass either ----------------------------------------
mkdir -p "$TMP/hollow"
printf 'HELPER = 1\n' > "$TMP/hollow/test_hollow.py"
run "$TMP/hollow"
[ "$rc" -eq 1 ] && grep -q 'test_hollow.py' <<< "$out" && grep -q 'holds no tests' <<< "$out" && ok \
  || bad "a test file with no tests in it fails, by name (rc=$rc)" "$out"

# --- a test asking for a fixture this runner cannot supply fails, never silently skips ------------
mkdir -p "$TMP/fixture"
printf 'def test_wants_tmp_path(tmp_path):\n    assert tmp_path\n' > "$TMP/fixture/test_fixture.py"
run "$TMP/fixture"
[ "$rc" -eq 1 ] && grep -q 'test_wants_tmp_path' <<< "$out" && grep -q 'tmp_path' <<< "$out" && ok \
  || bad "a test function that needs an argument fails and names it (rc=$rc)" "$out"

# --- a file whose process ends without reporting is a failure ------------------------------------
mkdir -p "$TMP/vanish"
printf 'import os\nos._exit(0)\n' > "$TMP/vanish/test_vanish.py"
run "$TMP/vanish"
[ "$rc" -eq 1 ] && grep -q 'test_vanish.py' <<< "$out" && grep -q 'ended without reporting' <<< "$out" && ok \
  || bad "a test file whose process exits without a result is a failure (rc=$rc)" "$out"

# --- two files that each import a sibling of the same name get their own ------------------------
mkdir -p "$TMP/twins/a" "$TMP/twins/b"
printf 'WHO = "a"\n' > "$TMP/twins/a/helper.py"
printf 'WHO = "b"\n' > "$TMP/twins/b/helper.py"
printf 'import helper\ndef test_mine():\n    assert helper.WHO == "a"\n' > "$TMP/twins/a/test_a.py"
printf 'import helper\ndef test_mine():\n    assert helper.WHO == "b"\n' > "$TMP/twins/b/test_b.py"
run "$TMP/twins"
[ "$rc" -eq 0 ] && [ "$(result_of)" = "2 0" ] && ok \
  || bad "each test file imports the helper beside it, not one cached by another file (rc=$rc, result=$(result_of))" "$out"

# --- a folder that is not there is refused by name ----------------------------------------------
run "$TMP/no-such-folder"
[ "$rc" -eq 2 ] && grep -q 'no-such-folder' <<< "$out" && ok \
  || bad "a folder that does not exist is refused by name, not treated as empty (rc=$rc)" "$out"

# --- a timeout that is not a number is refused by name, never a traceback -----------------------
out="$(SKILL_PY_TESTS_TIMEOUT=soon python3 "$RUNNER" "$TMP/good" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'SKILL_PY_TESTS_TIMEOUT must be a number' <<< "$out" && ok \
  || bad "a timeout that is not a number is refused, naming the variable (rc=$rc)" "$out"

# --- the runner writes no bytecode into the skills it reads --------------------------------------
left="$(find "$TMP" \( -name '__pycache__' -o -name '*.pyc' \) -print)"
if [ -n "$left" ]; then
  bad "the runner left bytecode beside the tests it ran" "$left"
else
  ok
fi

# --- the real skills, every test file found from disk --------------------------------------------
# The runner's discovery is compared with an independent listing, so a runner that silently stopped
# finding a folder could not shrink the run and still pass (L70, L288).
expected="$(find "$SKILLS" \( -name '__pycache__' -o -name node_modules -o -name .git \) -prune -o -type f \( -name 'test_*.py' -o -name '*_test.py' \) -print | wc -l | tr -d ' ')"
run "$SKILLS"
printf '%s\n' "$out" | grep '^FILE '
ran="$(printf '%s\n' "$out" | grep -c '^FILE ' || true)"
if [ "$expected" -eq 0 ]; then
  bad "no Python test file exists under $SKILLS, so the real run would prove nothing"
elif [ "$ran" != "$expected" ]; then
  bad "the runner ran $ran test files, but $expected exist under $SKILLS" "$out"
else
  ok
fi
real="$(result_of)"
if [ -z "$real" ]; then
  bad "the run over the real skills printed no result line (rc=$rc)" "$out"
else
  rp="${real% *}"; rf="${real#* }"
  pass=$((pass + rp))
  fail=$((fail + rf))
  [ "$rf" -eq 0 ] || printf '%s\n' "$out" | tail -n 80
  [ "$rc" -eq 0 ] || [ "$rf" -gt 0 ] || bad "the real run exited $rc with no failure counted" "$out"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
