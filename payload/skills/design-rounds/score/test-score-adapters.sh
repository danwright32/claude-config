#!/usr/bin/env bash
# test-score-adapters.sh: the design match score's two platform adapters (claude-config#1364).
#
#   capture-web.mjs                      the web adapter: a Playwright screenshot of each frame of the
#                                        settled design and of the build's fixture route, plus checks
#   swiftui/DesignScoreTests/DesignScoreCapture.swift
#                                        the SwiftUI adapter: a snapshot test drawing the real view
#
# The web adapter's logic runs against a stand in browser wherever node does, CI included. The two
# real runs need what only a Mac set up for the apps has (a Playwright package, Chrome, a Swift
# toolchain), so each says UNMEASURED by name where that is missing, never a pass (L411): a fixture
# design and a fixture build drawn for real, scored at 100%, and then changed on purpose and scored
# below it (the negative control, L1).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
SCORE="$HERE/design_score.py"
ADAPTER="$HERE/capture-web.mjs"
SWIFT_HELPER="$HERE/swiftui/DesignScoreTests/DesignScoreCapture.swift"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0; unmeasured=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed -n '1,30p' | sed 's/^/    /'; }
said() { grep -q -- "$1" "$2"; }

# --- 1. the web adapter's logic, against a stand in browser -----------------------------------------
if command -v node >/dev/null 2>&1; then
  node --test "$SKILL/score/tests/capture_web.test.mjs" > "$T/node.out" 2>&1
  n_pass="$(sed -n 's/^# pass \([0-9]*\)$/\1/p' "$T/node.out")"
  n_fail="$(sed -n 's/^# fail \([0-9]*\)$/\1/p' "$T/node.out")"
  if [ -n "$n_pass" ] && [ "${n_fail:-1}" = 0 ] && [ "$n_pass" -gt 0 ]; then
    pass=$((pass + n_pass))
  else
    bad "the web adapter's node tests (passed ${n_pass:-none}, failed ${n_fail:-unknown})" "$(grep -E '^not ok|Error|assert' "$T/node.out")"
  fi
else
  echo "UNMEASURED: node is not on PATH, so the web adapter's logic was not tested"
  unmeasured=$((unmeasured + 1))
fi

# --- 2. the frames both adapters draw come from the score's own reader --------------------------------
cat > "$T/design.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Fixture design</title>
<style>
  html, body { margin: 0; background: #fff; font: 16px/1.4 Helvetica, Arial, sans-serif; }
  .band { height: 60px; background: #3c98da; }
  .card { margin: 12px; padding: 12px; background: #f6efe3; color: #1b1613; }
</style></head>
<body>
<script type="application/json" id="decision-map">{"decisions": [
  {"id": "D1", "decision": "The heading reads Team capacity", "requirement": "1"},
  {"id": "D2", "decision": "The band is sky", "requirement": "2", "verify": "picture"}]}</script>
<script type="application/json" id="design-frames">{"frames": [
  {"id": "f1", "title": "Wide", "width": 640, "height": 240},
  {"id": "f2", "title": "Narrow", "width": 320}]}</script>
<script>
  // The settled file's contract: designFrameDocument(id) gives a frame's whole document.
  // The build's contract: the page itself, opened with ?frame=<id>, draws that frame from the fixture.
  var STYLE = document.querySelector("style").outerHTML;
  function frameBody(id) {
    return '<div class="band"></div><div class="card"><h1>Team capacity</h1><p>' + id + '</p></div>';
  }
  function designFrameDocument(id) {
    return '<!doctype html><html><head><meta charset="utf-8">' + STYLE + '</head><body>' + frameBody(id) + '</body></html>';
  }
  var frame = new URLSearchParams(location.search).get("frame");
  if (frame) document.body.innerHTML = frameBody(frame);
</script>
</body></html>
HTML
printf '%s\n' "window.DESIGN_CHECKS = [{id: 'D1', frames: ['f1', 'f2'], check: function (doc) { var h = doc.querySelector('h1'); return h && h.textContent === 'Team capacity' ? {ok: true, detail: ''} : {ok: false, detail: 'the heading reads ' + (h ? h.textContent : 'nothing')}; }}];" > "$T/design.checks.js"
python3 "$SCORE" frames "$T/design.html" > "$T/frames.json" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))["frames"]; sys.exit(0 if [(x["id"], x["width"], x.get("height")) for x in f] == [("f1", 640, 240), ("f2", 320, None)] else 1)' "$T/frames.json"; then ok; else bad "design_score.py frames prints the design's frames as the score reads them (rc=$rc)" "$(cat "$T/frames.json")"; fi
printf '<!doctype html><p>no blocks</p>\n' > "$T/blockless.html"
python3 "$SCORE" frames "$T/blockless.html" > "$T/frames-none.out" 2>&1; rc=$?
if [ "$rc" -eq 2 ] && said "design-frames" "$T/frames-none.out"; then ok; else bad "frames of a design with no frames block is exit 2, naming the block (rc=$rc)" "$(cat "$T/frames-none.out")"; fi

# --- 3. the web adapter for real: a fixture design and build in Chrome, through Playwright ------------
PW="${DESIGN_SCORE_PLAYWRIGHT:-}"
if [ -z "$PW" ]; then
  # The Playwright the browser tools install with npx, where this Mac has one.
  for cand in "$HOME"/.npm/_npx/*/node_modules/playwright; do
    [ -f "$cand/package.json" ] && { PW="$cand"; break; }
  done
fi
CHROME_APP="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
APP="$T/app"
mkdir -p "$APP"
git init -q "$APP"
cp "$T/design.html" "$APP/built.html"
git -C "$APP" add built.html
git -C "$APP" -c user.name=t -c user.email=t@t commit -q -m fixture
if [ -z "$PW" ] || ! command -v node >/dev/null 2>&1 || [ ! -x "$CHROME_APP" ]; then
  echo "UNMEASURED: no Playwright package (set DESIGN_SCORE_PLAYWRIGHT), node or Chrome here, so the web adapter was not run in a real browser"
  unmeasured=$((unmeasured + 1))
else
  run_web() {  # run_web <out> <extra args...>
    local out="$1"; shift
    DESIGN_SCORE_PLAYWRIGHT="$PW" node "$ADAPTER" --design "$T/design.html" --build "file://$APP/built.html" \
      --out "$out" --channel chrome --repo "$APP" "$@" > "$out.log" 2>&1
  }
  run_web "$T/web-match"; rc=$?
  if [ "$rc" -eq 0 ] && said "MATCHED: both halves are 100%" "$T/web-match.log"; then ok; else bad "a build drawing what the design draws scores 100% on both halves through the web adapter (rc=$rc)" "$(cat "$T/web-match.log")"; fi
  if python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c["platform"] == "web" and c["dirty"] is False and len(c["commit"]) == 40 and c["frames"][0]["designChecks"][0]["ok"] else 1)' "$T/web-match/capture.json" 2>/dev/null; then ok; else bad "its capture names the platform, the build's commit, a clean checkout and the design's own checks passing" "$(cat "$T/web-match/capture.json" 2>/dev/null)"; fi
  if python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import pngio; w,h,_=pngio.read_png(sys.argv[2]); sys.exit(0 if (w,h)==(640,240) else 1)' "$HERE" "$T/web-match/f1-design.png"; then ok; else bad "a frame declaring 640 by 240 is drawn at exactly that size"; fi
  # The card's blue channel 19 levels off (227 to 208), past the tolerance of 8.
  run_web "$T/web-off" --perturb ".card { background: #f6efd0 }"; rc=$?
  if [ "$rc" -eq 1 ] && said "not matched yet" "$T/web-off.log" && said "see f1-diff.png" "$T/web-off.log"; then ok; else bad "the same build with its card drawn 19 levels off scores below 100%, naming the frame (rc=$rc)" "$(cat "$T/web-off.log")"; fi
  run_web "$T/web-gone" --build "http://127.0.0.1:9/nothing"; rc=$?
  if [ "$rc" -eq 2 ] && said "could not be drawn" "$T/web-gone.log"; then ok; else bad "a build that cannot be loaded is no score, exit 2 (rc=$rc)" "$(cat "$T/web-gone.log")"; fi
fi

# --- 4. the SwiftUI adapter for real: the real view drawn by a snapshot test ---------------------------
if [ "$(uname -s)" != Darwin ] || ! command -v swift >/dev/null 2>&1 || [ -z "$PW" ] || [ ! -x "$CHROME_APP" ]; then
  echo "UNMEASURED: no Swift toolchain, Playwright or Chrome here, so the SwiftUI adapter was not run"
  unmeasured=$((unmeasured + 1))
else
  PKG="$T/swift"
  mkdir -p "$PKG/Sources/DesignScore" "$PKG/Tests/DesignScoreTests"
  cp "$SWIFT_HELPER" "$PKG/Sources/DesignScore/"
  cat > "$PKG/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "DesignScoreProof", platforms: [.macOS(.v14)],
  targets: [.target(name: "DesignScore"), .testTarget(name: "DesignScoreTests", dependencies: ["DesignScore"])])
SWIFT
  # Two snapshot tests, each filling its own capture: the view as designed, and one drawn 15 levels off.
  cat > "$PKG/Tests/DesignScoreTests/ProofTests.swift" <<'SWIFT'
import DesignScore
import SwiftUI
import XCTest

final class ProofTests: XCTestCase {
    @MainActor func draw(_ folder: String, sky: Double) throws {
        try DesignScoreCapture.capture(
            folder: URL(fileURLWithPath: ProcessInfo.processInfo.environment[folder]!),
            build: "BandsView", commit: String(repeating: "c", count: 40), dirty: false,
            view: { _ in AnyView(VStack(spacing: 0) {
                Color(.sRGB, red: sky / 255, green: 152 / 255, blue: 218 / 255).frame(height: 40)
                Color(.sRGB, red: 246 / 255, green: 239 / 255, blue: 227 / 255).frame(height: 40)
            }) },
            checks: { _ in [DesignScoreCheck("D1", ok: true)] })
    }
    @MainActor func testAsDesigned() throws { try draw("CAPTURE_MATCH", sky: 60) }
    @MainActor func testOffByFifteen() throws { try draw("CAPTURE_OFF", sky: 75) }
}
SWIFT
  cat > "$T/bands.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><style>html, body { margin: 0; } .a, .b { width: 120px; height: 40px; } .a { background: #3c98da; } .b { background: #f6efe3; }</style></head>
<body><div class="a"></div><div class="b"></div>
<script>function designFrameDocument(id) { return document.documentElement.outerHTML.replace(/<script[\s\S]*$/, "</body></html>"); }</script>
<script type="application/json" id="decision-map">{"decisions": [{"id": "D1", "decision": "Sky above beige", "requirement": "1"}]}</script>
<script type="application/json" id="design-frames">{"frames": [{"id": "f1", "title": "The two bands", "width": 120, "height": 80}]}</script>
</body></html>
HTML
  for name in match off; do
    DESIGN_SCORE_PLAYWRIGHT="$PW" node "$ADAPTER" --design "$T/bands.html" --out "$T/swift-$name" --design-only --channel chrome --repo "$APP" > "$T/swift-$name.design.log" 2>&1 \
      || bad "the design side of the SwiftUI capture is drawn by the web adapter (--design-only)" "$(cat "$T/swift-$name.design.log")"
  done
  (cd "$PKG" && CAPTURE_MATCH="$T/swift-match" CAPTURE_OFF="$T/swift-off" swift test > "$T/swift.log" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "the SwiftUI snapshot tests run (rc=$rc)" "$(tail -30 "$T/swift.log")"
  else
    python3 "$SCORE" score "$T/swift-match" > "$T/swift-match.score" 2>&1; rc=$?
    if [ "$rc" -eq 0 ] && said "MATCHED" "$T/swift-match.score" && said ", swiftui," "$T/swift-match.score"; then ok; else bad "the real SwiftUI view, drawn at the frame's size in sRGB, matches the browser's drawing of the design at 100% (rc=$rc)" "$(cat "$T/swift-match.score")"; fi
    python3 "$SCORE" score "$T/swift-off" > "$T/swift-off.score" 2>&1; rc=$?
    if [ "$rc" -eq 1 ] && said "not matched yet" "$T/swift-off.score"; then ok; else bad "the same view drawn 15 levels off scores below 100% (rc=$rc)" "$(cat "$T/swift-off.score")"; fi
    if said "no positive control" "$T/swift-match.score"; then ok; else bad "and says its Swift checks have no positive control on the HTML design"; fi
  fi
fi

echo
echo "passed: $pass, failed: $fail"
[ "$unmeasured" -gt 0 ] && echo "UNMEASURED-SECTIONS $unmeasured"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
