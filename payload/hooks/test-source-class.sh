#!/usr/bin/env bash
# Tests for lib/source-class.sh: the is_source / is_test file classifier shared by
# require-tests-before-push.sh and simplify-before-push.sh.
#
# The classification used to live inline in require-tests-before-push.sh. A second gate needed the
# same predicate, so it moved here rather than being copied: two same-named classifiers either side
# of a boundary drift, and the drift is silent (L263, L370). These assertions moved WITH it from
# test-require-tests-before-push.sh, so no case lost its home; the gate's own suite still exercises
# classification end to end through the real hook.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/source-class.sh"

pass=0
fail=0

# The lib must be sourceable on its own: a gate sources it, so a syntax error or a missing file is a
# break for every gate at once, and an empty classification reads as "no source here" (L98).
if [ -f "$LIB" ] && . "$LIB"; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL: lib/source-class.sh is missing or does not source cleanly"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 1
fi

# Defined exactly once each. bash keeps the last definition of a function without a word, so a second
# copy spliced in by a bad merge would win silently (claude-config#440, the push-scope precedent).
for fn in is_source is_test; do
  n="$(grep -cE "^$fn\(\) \{" "$LIB")"
  if [ "$n" = "1" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $fn defined $n times in the lib, expected 1"; fi
done

want_test()    { if is_test "$1";    then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected TEST: $1"; fi; }
want_nottest() { if is_test "$1";    then fail=$((fail+1)); echo "FAIL: expected NOT-test: $1"; else pass=$((pass+1)); fi; }
want_source()    { if is_source "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected SOURCE: $1"; fi; }
want_notsource() { if is_source "$1"; then fail=$((fail+1)); echo "FAIL: expected NOT-source: $1"; else pass=$((pass+1)); fi; }

# --- the reported gap: scripts/test-*.ts convention ---
want_test "scripts/test-cron-routes.ts"
want_test "scripts/test-sync.js"
want_test "scripts/test_legacy_thing.ts"   # underscore variant too

# --- #95: shell suites are tests too ---
want_test "hooks/test-subagent-issue-harvest.sh"
want_test "test_deploy.sh"
want_test "scripts/deploy_test.sh"
want_nottest "hooks/test-utils.sh"
want_nottest "hooks/test-helpers.sh"
want_nottest "scripts/test-fixtures.sh"
want_nottest "hooks/testimonials.sh"

# --- ovation#130: a `.cases.js` file is the executable form of a rule ---
want_test "docs/design/rules/time-field.cases.js"
want_test "docs/design/rules/typing.cases.js"
want_test "src/pricing.cases.ts"
want_test "lib/duration.cases.mjs"
want_source "docs/design/rules/time-field.js"
want_nottest "docs/design/rules/time-field.js"

# --- claude-config#930: a file inside an Xcode test target folder is a test ---
want_test "mac/OvertureTests/EngineDivergenceGate.swift"
want_test "mac/OvertureHostedTests/Support/HostedHarness.swift"
want_test "mac/TestSupport/FixtureLoader.swift"
want_test "OvertureUITests/LaunchFlow.swift"
want_source  "mac/Overture/TestsPanel.swift"
want_nottest "mac/Overture/TestsPanel.swift"
want_source  "mac/Overture/UnitTestsRunner.swift"
want_nottest "mac/Overture/UnitTestsRunner.swift"
want_source  "mac/OvertureTestsKit/Runner.swift"
want_nottest "mac/OvertureTestsKit/Runner.swift"
want_source  "web/contests/entry.ts"
want_nottest "web/contests/entry.ts"
want_source  "mac/TestSupportive/Thing.swift"
want_nottest "mac/TestSupportive/Thing.swift"

# --- the Test or Tests filename suffix is a WORD, not four letters ---
want_test "mac/OvertureTests/FooTests.swift"
want_test "src/main/FooTest.kt"
want_test "app/src/test/WidgetTest.java"
want_test "Tests/BarTests.cs"
want_test "lib/parser_test.scala"
want_test "pkg/Tests.swift"
want_source  "src/Latest.swift"
want_nottest "src/Latest.swift"
want_source  "src/Contests.swift"
want_nottest "src/Contests.swift"
want_source  "lib/Manifest.kt"
want_nottest "lib/Manifest.kt"

# --- existing conventions must still register (regression) ---
want_test "src/components/Foo.test.ts"
want_test "src/components/Foo.spec.tsx"
want_test "tests/foo.ts"
want_test "test_foo.py"
want_test "foo_test.go"

# --- must NOT over-match real source or test-only helpers ---
want_nottest "src/app/api/cron/route.ts"
want_nottest "scripts/deploy.ts"
want_nottest "scripts/test-utils.ts"
want_nottest "src/test-helpers.ts"
want_nottest "scripts/testimonials.ts"

# --- one-off analysis scripts in scripts/ are exempt from the gate ---
want_notsource "scripts/check-menjivar.js"
want_notsource "scripts/check-menjivar-beyond.js"
want_notsource "scripts/check_enrollment_gaps.py"
want_notsource "apps/worker/scripts/check-export-state.ts"

# --- but the exemption must not leak beyond scripts/check-* ---
want_source "src/app/api/check-email/route.ts"
want_source "scripts/checkout.ts"
want_source "scripts/deploy.ts"
want_source "lib/check-utils.ts"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
