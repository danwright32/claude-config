#!/usr/bin/env bash
# Tests for the file classifier (is_test / is_source) inside
# require-tests-before-push.sh. We source ONLY those two function definitions
# out of the hook so we exercise the real code without running the whole hook.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/require-tests-before-push.sh"

# Pull the two pure functions out of the hook and define them here.
eval "$(sed -n '/^is_test() {/,/^}/p' "$HOOK")"
eval "$(sed -n '/^is_source() {/,/^}/p' "$HOOK")"

pass=0
fail=0
want_test()    { if is_test "$1";    then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected TEST: $1"; fi; }
want_nottest() { if is_test "$1";    then fail=$((fail+1)); echo "FAIL: expected NOT-test: $1"; else pass=$((pass+1)); fi; }
want_source()    { if is_source "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected SOURCE: $1"; fi; }
want_notsource() { if is_source "$1"; then fail=$((fail+1)); echo "FAIL: expected NOT-source: $1"; else pass=$((pass+1)); fi; }

# --- the reported gap: scripts/test-*.ts convention ---
want_test "scripts/test-cron-routes.ts"
want_test "scripts/test-sync.js"
want_test "scripts/test_legacy_thing.ts"   # underscore variant too

# --- existing conventions must still register (regression) ---
want_test "src/components/Foo.test.ts"
want_test "src/components/Foo.spec.tsx"
want_test "tests/foo.ts"
want_test "test_foo.py"
want_test "foo_test.go"

# --- must NOT over-match real source or test-only helpers ---
want_nottest "src/app/api/cron/route.ts"   # the source file from the report
want_nottest "scripts/deploy.ts"
want_nottest "scripts/test-utils.ts"        # helper, not a runnable test
want_nottest "src/test-helpers.ts"
want_nottest "scripts/testimonials.ts"      # 'test' substring, not a test file

# --- one-off analysis scripts in scripts/ are exempt from the gate ---
want_notsource "scripts/check-menjivar.js"
want_notsource "scripts/check-menjivar-beyond.js"
want_notsource "scripts/check_enrollment_gaps.py"
want_notsource "apps/worker/scripts/check-export-state.ts"

# --- but the exemption must not leak beyond scripts/check-* ---
want_source "src/app/api/check-email/route.ts"   # real route, not a script
want_source "scripts/checkout.ts"                # 'check' substring only
want_source "scripts/deploy.ts"
want_source "lib/check-utils.ts"                 # not under scripts/

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
