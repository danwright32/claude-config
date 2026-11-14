#!/usr/bin/env bash
# test-shoot-native-swift.sh: the shared Swift camera, native/VerificationShot.swift (claude-config#2950),
# run for real against shoot_native.py, the helper that calls it (claude-config#2696).
#
# test_shoot_native.py proves the helper's side of the contract with a Python stub in place of the
# test. This suite proves the camera's side: it builds a SwiftPM package holding a copy of the template
# and a fixture frame list, then shoots it through shoot_native.py exactly as a verification run does,
# so a picture is judged by the same rules a real one is (exit code, PNG width at a scale of 1, 2 or 3,
# the row count). It also reads the pictures' pixels, because a file of the right width proves only
# that something was written: the light and the dark shot must differ in the way the theme says, and
# the frame's rows must have left ink on the backdrop (L146).
#
# Where the Swift toolchain or XCTest is missing (CI's Linux runner, a Mac without Xcode), the camera
# cannot be built, and that is said by name as unmeasured, never a pass (L411). Nothing here orders a
# window front or activates an app: the camera orders its window back, outside every display.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
TEMPLATE="$SKILL/native/VerificationShot.swift"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed -n '1,30p' | sed 's/^/    /'; }
finish() {
  echo
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
}

if [ "$(uname -s)" != Darwin ] || ! command -v swift >/dev/null 2>&1 || ! xcrun --find xctest >/dev/null 2>&1; then
  echo "SUITE-PART-UNMEASURED the Swift toolchain with XCTest is not here (needs macOS and Xcode), so the Swift camera was not built or run"
  finish
fi

if [ ! -f "$TEMPLATE" ]; then
  bad "the Swift camera template is missing at $TEMPLATE"
  finish
fi

# The package a native app's test target stands for: the template copied in unchanged, beside a
# frame list of the app's own.
PKG="$T/pkg"
mkdir -p "$PKG/Tests/ShotFixtureTests"
cp "$TEMPLATE" "$PKG/Tests/ShotFixtureTests/VerificationShot.swift"
cat > "$PKG/Package.swift" <<'SWIFT'
// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "ShotFixture",
  platforms: [.macOS(.v13)],
  targets: [.testTarget(name: "ShotFixtureTests")]
)
SWIFT
cat > "$PKG/Tests/ShotFixtureTests/Fixture.swift" <<'SWIFT'
import SwiftUI
import XCTest

/// The frame list an app's test hands the camera: one frame, three rows of text.
final class VerificationShotFixture: XCTestCase {
  @MainActor func testShot() throws {
    try VerificationShot.shoot([
      "three-rows": {
        VerificationShot.Frame(rows: 3) {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(1...3, id: \.self) { n in
              Text("Row \(n) of the fixture").font(.system(size: 28, weight: .bold))
            }
          }
          .padding(24)
        }
      },
    ])
  }
}

/// The camera's reading of what it was asked to draw, every refusal included.
final class VerificationShotRequestTests: XCTestCase {
  let full = [
    "VERIFICATION_SHOT_FRAME": "three-rows", "VERIFICATION_SHOT_WIDTH": "480",
    "VERIFICATION_SHOT_HEIGHT": "900", "VERIFICATION_SHOT_THEME": "dark",
    "VERIFICATION_SHOT_FILE": "/x/a.png", "VERIFICATION_SHOT_ROWS_FILE": "/x/a.rows",
    "VERIFICATION_SHOT_MIN_ROWS": "3",
  ]

  @MainActor func testNoFrameNamedIsAnOrdinaryTestRun() throws {
    XCTAssertNil(try VerificationShot.request(from: [:]))
  }

  @MainActor func testAFullRequestIsRead() throws {
    let r = try XCTUnwrap(try VerificationShot.request(from: full))
    XCTAssertEqual(r.frame, "three-rows")
    XCTAssertEqual(r.width, 480)
    XCTAssertEqual(r.height, 900)
    XCTAssertTrue(r.dark)
    XCTAssertEqual(r.file.path, "/x/a.png")
    XCTAssertEqual(r.rowsFile.path, "/x/a.rows")
  }

  @MainActor func testTheTestRunnerSpellingIsReadToo() throws {
    var prefixed: [String: String] = [:]
    for (k, v) in full { prefixed["TEST_RUNNER_" + k] = v }
    XCTAssertEqual(try VerificationShot.request(from: prefixed)?.frame, "three-rows")
  }

  @MainActor func testEveryBadValueIsRefusedByName() {
    let cases: [(String, String?)] = [
      ("VERIFICATION_SHOT_THEME", "sepia"), ("VERIFICATION_SHOT_WIDTH", "wide"),
      ("VERIFICATION_SHOT_WIDTH", "0"), ("VERIFICATION_SHOT_HEIGHT", "-1"),
      ("VERIFICATION_SHOT_FILE", nil), ("VERIFICATION_SHOT_ROWS_FILE", ""),
    ]
    for (key, value) in cases {
      var env = full
      env[key] = value
      XCTAssertThrowsError(try VerificationShot.request(from: env), "\(key)=\(value ?? "unset")") { error in
        XCTAssertTrue(String(describing: error).contains(key), "\(error) does not name \(key)")
      }
    }
  }

  @MainActor func testAFrameTheListDoesNotHoldFailsNamingTheOnesItDoes() {
    var env = full
    env["VERIFICATION_SHOT_FRAME"] = "no-such-frame"
    XCTAssertThrowsError(try VerificationShot.shoot(["three-rows": { VerificationShot.Frame { Text("x") } }], env: env)) {
      let text = String(describing: $0)
      XCTAssertTrue(text.contains("no-such-frame") && text.contains("three-rows"), text)
    }
  }
}
SWIFT

# The pixel reader: a PNG decoder small enough to read here, so the suite needs nothing installed.
cat > "$T/pixels.py" <<'PY'
import struct, sys, zlib

def read(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, w = 8, b"", None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and ctype in (2, 6) and interlace == 0, "unread PNG form %d/%d/%d" % (depth, ctype, interlace)
            bpp = 4 if ctype == 6 else 3
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, h, bpp, rows

w, h, bpp, rows = read(sys.argv[1])
luma = lambda r, x: (0.2126 * r[x * bpp] + 0.7152 * r[x * bpp + 1] + 0.0722 * r[x * bpp + 2]) / 255
backdrop = luma(rows[h - 2], w - 2)
inked = sum(1 for y in range(0, h, 2) for x in range(0, w, 2) if abs(luma(rows[y], x) - backdrop) > 0.4)
print("%d %d %.3f %d" % (w, h, backdrop, inked))
PY

RDIR="$T/receipt"
mkdir -p "$RDIR"
cat > "$RDIR/areas.json" <<'JSON'
{"schema": "verification-areas/1", "mode": "warn", "url": "http://127.0.0.1:1",
 "commands": {"serve": "x", "ready": "true", "stop": "true", "drive": "x",
              "native_shot": "swift test --disable-sandbox --filter \"$VERIFICATION_SHOT_TEST\""},
 "seeds": {"demo": {"synthetic": true, "why": "three rows of made up text"}},
 "areas": [{"name": "fixture", "guide": "g/fixture.md", "owns": ["**"],
            "screens": [{"name": "rows", "test": "ShotFixtureTests.VerificationShotFixture",
                         "frame": "three-rows", "seed": "demo", "min_rows": 3}]}]}
JSON

shoot() {  # <frame> <theme> <file> <min rows>: shoot_native.py's exit code, its output in $T/<file>.out
  VERIFICATION_RECEIPT_DIR="$RDIR" VERIFICATION_WORKTREE="$PKG" \
    python3 "$SKILL/scripts/shoot_native.py" screenshot-native ShotFixtureTests.VerificationShotFixture \
    "$1" 480 "$2" "$3" "$4" > "$T/$3.out" 2>&1
}

# The camera's own refusals, before any picture. The first build is here, so its output is kept.
(cd "$PKG" && swift test --disable-sandbox --filter VerificationShotRequestTests) > "$T/request.out" 2>&1
rc=$?
executed="$(sed -n 's/.*Executed \([0-9]*\) tests\{0,1\}, with \([0-9]*\) failures.*/\1 \2/p' "$T/request.out" | tail -n 1)"
if [ "$rc" -eq 0 ] && [ "$executed" = "5 0" ]; then ok
else bad "the camera's request tests (swift test exited $rc, executed and failed: ${executed:-none})" "$(tail -n 30 "$T/request.out")"
fi

# An ordinary test run, with no frame named, draws nothing and writes nothing: it skips.
(cd "$PKG" && swift test --disable-sandbox --filter ShotFixtureTests.VerificationShotFixture) > "$T/plain.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q "skipped" "$T/plain.out" && [ -z "$(ls "$RDIR"/*.png 2>/dev/null)" ]; then ok
else bad "an ordinary run of the shot test should skip and write nothing (exit $rc)" "$(tail -n 20 "$T/plain.out")"
fi

for theme in light dark; do
  shoot three-rows "$theme" "rows-$theme.png" 3
  rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$RDIR/rows-$theme.png" ]; then ok
  else bad "the $theme shot through shoot_native.py was not kept (exit $rc)" "$(cat "$T/rows-$theme.png.out"; tail -n 20 "$RDIR/native-shot/rows-$theme.png.log" 2>/dev/null)"; continue
  fi
  measured="$(python3 -I "$T/pixels.py" "$RDIR/rows-$theme.png" 2>&1)"
  # A reading that is not four numbers is the reader failing, said as such, never fed to arithmetic.
  if ! printf '%s\n' "$measured" | grep -Eq '^[0-9]+ [0-9]+ [0-9]+\.[0-9]+ [0-9]+$'; then
    bad "the $theme picture's pixels could not be read" "$measured"; continue
  fi
  w=""; h=""; backdrop=""; inked=""
  read -r w h backdrop inked <<EOF
$measured
EOF
  # Width is shoot_native's to judge; height is the window's 900 points at the same scale, at least.
  if [ -n "${inked:-}" ] && [ $((h * 480)) -ge $((w * 900)) ]; then ok
  else bad "the $theme picture is ${w:-?} by ${h:-?} pixels, shorter than 900 points at its scale"
  fi
  if [ "$theme" = light ]; then awk -v b="${backdrop:-0}" 'BEGIN { exit !(b > 0.7) }'
  else awk -v b="${backdrop:-1}" 'BEGIN { exit !(b < 0.3) }'
  fi && ok || bad "the $theme picture's backdrop has a luma of ${backdrop:-unread}, which is not the $theme theme"
  if [ "${inked:-0}" -gt 200 ]; then ok
  else bad "the $theme picture has ${inked:-no} inked samples, so the frame's rows were not drawn"
  fi
done

shoot no-such-frame light unknown.png 0
rc=$?
if [ "$rc" -eq 1 ] && [ ! -f "$RDIR/unknown.png" ] && grep -q "no-such-frame" "$RDIR/native-shot/unknown.png.log"; then ok
else bad "a frame the test does not know must fail the test and leave no picture (exit $rc)" "$(cat "$T/unknown.png.out")"
fi

shoot three-rows light short.png 5
rc=$?
if [ "$rc" -eq 1 ] && [ ! -f "$RDIR/short.png" ] && grep -q "drew 3 rows" "$T/short.png.out"; then ok
else bad "a frame drawing 3 rows shot at 5 must not be kept (exit $rc)" "$(cat "$T/short.png.out")"
fi

finish
