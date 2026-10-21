#!/usr/bin/env bash
# test-swift-xctest.sh: how the SwiftUI adapter's snapshot run tells a toolchain that cannot build
# XCTest from a real fault (claude-config#1400).
#
#   swift-xctest.sh   swift_xctest_run runs `swift test` in the proof package and says ran, failed,
#                     or unmeasured with the reason. Unmeasured is said only when the attempt itself
#                     showed the compiler could not find the XCTest module and nothing else failed
#                     (L411, L460), so a Mac with only the command line tools reads as unmeasured and
#                     a broken adapter on that same Mac still reads as failed.
#
# The swift here is a stand in on PATH that replays a log `swift test` really wrote, so the probe's
# answer is injected and every case runs on any machine, CI included. The logs in
# tests/fixtures/swift-test were written by the real toolchains on 2026-10-20 (L48): the command line
# tools at /Library/Developer/CommandLineTools, which have no XCTest, and Xcode 26 with a deliberate
# type error in the library and in the test file.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/swift-xctest.sh"
FIX="$HERE/tests/fixtures/swift-test"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed -n '1,30p' | sed 's/^/    /'; }

if [ ! -f "$LIB" ]; then
  bad "swift-xctest.sh exists beside the adapters"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 1
fi
. "$LIB"

# The stand in swift: records where it ran and what it was asked, replays a log, exits as told.
mkdir -p "$T/bin" "$T/pkg"
cat > "$T/bin/swift" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD" > "$FAKE_SWIFT_SEEN"
printf '%s\n' "$*" >> "$FAKE_SWIFT_SEEN"
printf '%s\n' "${CAPTURE_MATCH:-}" >> "$FAKE_SWIFT_SEEN"
[ -n "${FAKE_SWIFT_LOG:-}" ] && cat "$FAKE_SWIFT_LOG"
exit "${FAKE_SWIFT_RC:-0}"
SH
chmod +x "$T/bin/swift"

# run <case> <log or empty> <rc>: the verdict line swift_xctest_run printed for that replay.
run() {
  PATH="$T/bin:$PATH" FAKE_SWIFT_SEEN="$T/$1.seen" FAKE_SWIFT_LOG="$2" FAKE_SWIFT_RC="$3" \
    DEVELOPER_DIR=/Library/Developer/CommandLineTools CAPTURE_MATCH="$T/match-$1" \
    swift_xctest_run "$T/pkg" "$T/$1.log"
}

# --- 1. the command line tools, which have no XCTest: unmeasured, saying why and what changes it ----
v="$(run clt "$FIX/command-line-tools.txt" 1)"
case "$v" in
  unmeasured\ *) ok ;;
  *) bad "a toolchain whose swift test cannot find the XCTest module is unmeasured, never a fail (got: $v)" ;;
esac
case "$v" in *XCTest*) ok ;; *) bad "the reason names XCTest, the thing this toolchain lacks (got: $v)" ;; esac
case "$v" in *"/Library/Developer/CommandLineTools"*) ok ;; *) bad "the reason names the developer directory the attempt used (got: $v)" ;; esac
case "$v" in *"xcode-select -s"*) ok ;; *) bad "the reason names the step that changes it: selecting a full Xcode (got: $v)" ;; esac

# The probe is the real attempt: swift test, in the package, with the caller's environment.
seen="$(cat "$T/clt.seen" 2>/dev/null)"
if [ "$(sed -n 1p "$T/clt.seen" 2>/dev/null)" = "$(cd "$T/pkg" && pwd -P)" ] || [ "$(sed -n 1p "$T/clt.seen" 2>/dev/null)" = "$T/pkg" ]; then ok; else bad "swift test runs inside the package" "$seen"; fi
if [ "$(sed -n 2p "$T/clt.seen" 2>/dev/null)" = "test" ]; then ok; else bad "the attempt is swift test itself" "$seen"; fi
if [ "$(sed -n 3p "$T/clt.seen" 2>/dev/null)" = "$T/match-clt" ]; then ok; else bad "the caller's capture folders reach the snapshot tests" "$seen"; fi
if cmp -s "$FIX/command-line-tools.txt" "$T/clt.log"; then ok; else bad "swift test's whole output is kept in the log the caller named"; fi

# --- 2. it built and ran: the snapshot tests ran, and the caller goes on to score them --------------
v="$(run good "" 0)"
[ "$v" = "ran" ] && ok || bad "a swift test that exits 0 ran (got: $v)"

# --- 3. a real fault reads as failed, on either toolchain -------------------------------------------
v="$(run libfault "$FIX/command-line-tools-library-fault.txt" 1)"
[ "$v" = "failed" ] && ok || bad "a type error in the adapter itself, on the command line tools, is a fail, not unmeasured (got: $v)"
v="$(run testfault "$FIX/xcode-test-fault.txt" 1)"
[ "$v" = "failed" ] && ok || bad "a type error in the snapshot test, on Xcode, is a fail (got: $v)"
# XCTest missing AND a source error elsewhere: what failed is the code, which would fail anywhere.
cat "$FIX/command-line-tools.txt" > "$T/mixed.replay"
grep -m 1 'DesignScoreCapture.swift:[0-9]*:[0-9]*:' "$FIX/command-line-tools-library-fault.txt" >> "$T/mixed.replay"
v="$(run mixed "$T/mixed.replay" 1)"
[ "$v" = "failed" ] && ok || bad "XCTest missing beside a real error in the adapter's own code is a fail (got: $v)"
# A swift test that died saying nothing has shown no missing XCTest, so it is a fail (L11).
v="$(run silent "" 1)"
[ "$v" = "failed" ] && ok || bad "a swift test that exits nonzero with no output is a fail (got: $v)"

# --- 4. the adapter suite says what it did not measure where the runner prints it --------------------
# With no Playwright to be found (an empty HOME, nothing named), every real section stands down, as
# on Linux CI. The suite must still pass with no failure, and carry a SUITE-PART-UNMEASURED line the
# runner counts and prints under its ok line naming the SwiftUI adapter, so a reader never takes it as
# passed (#1444).
mkdir -p "$T/home"
env -u DESIGN_SCORE_PLAYWRIGHT HOME="$T/home" bash "$HERE/test-score-adapters.sh" > "$T/adapters.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q '^SUITE-RESULT passed=[0-9]* failed=0$' "$T/adapters.out" && ok \
  || bad "the adapter suite with nothing to draw with passes with no failure (rc=$rc)" "$(tail -20 "$T/adapters.out")"
grep -E '^SUITE-PART-UNMEASURED .*SwiftUI adapter' "$T/adapters.out" >/dev/null && ok \
  || bad "the adapter suite prints a SUITE-PART-UNMEASURED line naming the SwiftUI adapter" "$(grep -E 'UNMEASURED|SUITE-' "$T/adapters.out")"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
