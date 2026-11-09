#!/usr/bin/env bash
# test-hidden-chrome.sh: every hidden Chrome the design rounds start is a separate build, never the
# Google Chrome Dan uses, and all of them are found by one lookup, score/headless_chrome.py
# (claude-config#2191).
#
# A hidden copy of Dan's Chrome checks in with macOS as com.google.Chrome (unified log, 2026-11-03
# 22:25 ET: CHECKIN com.google.Chrome, foreground=1, launchedByLS=0), so while a suite started them
# back to back, a click on Chrome in the Dock reached a windowless test copy and Dan's own Chrome did
# not open. The separate build is the Chrome Headless Shell install-playwright.sh puts in the shared
# Playwright folder: a bare program with no bundle, which checks in with no bundle id at all
# (lsappinfo, 2026-11-08: bundleID=[ NULL ], type UIElement). This holds:
#   1. the lookup this machine actually uses (make-settled.py's, capture-web.mjs's, and the CLI every
#      suite reads) never resolves inside a bundle whose id is com.google.Chrome;
#   2. the lookup on a stand in HOME: the shared install's headless shell is found by the revision the
#      installed Playwright names; with none there it refuses by name, naming the install command,
#      and never hands back Google Chrome though one is there;
#   3. DESIGN_ROUNDS_CHROME naming Dan's Chrome is refused, and naming another build is used;
#   4. headless-dom.sh, which every hidden Chrome is started through, refuses Dan's Chrome in both of
#      its modes without running it;
#   5. no file of the design rounds names Google Chrome's program, so the next hand written lookup
#      fails here (L613).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOKUP="$DIR/score/headless_chrome.py"
PROBE="$DIR/tests/find_chrome_probe.py"
HEADLESS_DOM="$DIR/headless-dom.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check_eq() { # check_eq <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
check() { # check <description> <expected substring> <actual>
  case "$3" in *"$2"*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); printf 'FAIL: %s\n  expected to contain: %s\n  actual: %s\n' "$1" "$2" "$3" ;; esac
}
check_not() { # check_not <description> <forbidden substring> <actual>
  case "$3" in *"$2"*) fail=$((fail + 1)); printf 'FAIL: %s\n  expected NOT to contain: %s\n  actual: %s\n' "$1" "$2" "$3" ;; *) pass=$((pass + 1)) ;; esac
}
# Chrome's headless switch, spelled so this file holds no launch for check-chrome-launches.py to find.
HL="--head""less"

# The bundle id of the app bundle a program sits in, or "none": read from the bundle's own
# Info.plist, never from the program's name, so a renamed copy of Dan's Chrome is still told.
bundle_of() {
  python3 - "$1" <<'PY'
import os, plistlib, sys
p = os.path.realpath(sys.argv[1]) if sys.argv[1] else ""
while p and p != os.path.dirname(p):
    if p.endswith(".app") and os.path.isfile(os.path.join(p, "Contents", "Info.plist")):
        with open(os.path.join(p, "Contents", "Info.plist"), "rb") as fh:
            print(plistlib.load(fh).get("CFBundleIdentifier") or "none")
        sys.exit(0)
    p = os.path.dirname(p)
print("none")
PY
}

# A stand in app bundle: Contents/Info.plist naming <id>, and a program at Contents/MacOS/<name>
# that records it ran and prints a complete page.
fake_bundle() { # fake_bundle <folder.app> <bundle id> <program name>
  mkdir -p "$1/Contents/MacOS"
  python3 -c 'import plistlib,sys; plistlib.dump({"CFBundleIdentifier": sys.argv[2], "CFBundleExecutable": sys.argv[3]}, open(sys.argv[1], "wb"))' \
    "$1/Contents/Info.plist" "$2" "$3"
  printf '#!/bin/bash\n: > "%s.ran"\nprintf "<html><body>drawn</body></html>\\n"\n' "$1" > "$1/Contents/MacOS/$3"
  chmod +x "$1/Contents/MacOS/$3"
}
DAN_ID="com.google.""Chrome"

# --- 1. the lookup this machine uses never resolves to Dan's Chrome ---
said="$(env -u DESIGN_ROUNDS_CHROME python3 "$LOOKUP" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  check_eq "the lookup's Chrome is not in a bundle whose id is $DAN_ID ($said)" "no" "$([ "$(bundle_of "$said")" = "$DAN_ID" ] && echo yes || echo no)"
  check_eq "and it can be run" "yes" "$([ -x "$said" ] && echo yes || echo no)"
else
  check_eq "with no separate Chrome here the lookup refuses with exit 2" "2" "$rc"
  check "naming the command that installs it" "install-playwright.sh" "$said"
  echo "SUITE-PART-UNMEASURED no separate headless Chrome on this machine ($said), so the Chrome it finds was not read"
fi
# make-settled.py's own lookup, which measures a terminal design's windows.
got="$(env -u DESIGN_ROUNDS_CHROME python3 "$PROBE" 2>&1)"
case "$got" in
  REFUSED*) check "make-settled.py's lookup, finding no separate Chrome, names the install command" "install-playwright.sh" "$got" ;;
  *) check_eq "make-settled.py's Chrome is not Dan's ($got)" "no" "$([ "$(bundle_of "$got")" = "$DAN_ID" ] && echo yes || echo no)"
     check_eq "and it is the one the shared lookup finds" "$said" "$got" ;;
esac
# capture-web.mjs's "chrome" channel, which draws the design match score.
if command -v node >/dev/null 2>&1; then
  got="$(cd "$DIR/score" && env -u DESIGN_ROUNDS_CHROME node --input-type=module -e '
const { chromeLaunchOptions } = await import(new URL("./capture-web.mjs", "file://" + process.cwd() + "/").href);
try { console.log(chromeLaunchOptions("chrome", []).env.HEADLESS_DOM_CHROME); }
catch (e) { console.log("REFUSED " + e.message); }' 2>&1)"
  case "$got" in
    REFUSED*) check "capture-web.mjs, finding no separate Chrome, names the install command" "install-playwright.sh" "$got" ;;
    *) check_eq "capture-web.mjs's Chrome is not Dan's ($got)" "no" "$([ "$(bundle_of "$got")" = "$DAN_ID" ] && echo yes || echo no)"
       check_eq "and it is the one the shared lookup finds" "$said" "$got" ;;
  esac
else
  echo "SUITE-PART-UNMEASURED node is not on PATH, so capture-web.mjs's Chrome was not read"
fi

# --- 2. the lookup on a stand in HOME ---
H="$TMP/home"
ROOT="$H/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root"])' "$DIR/score/shared-playwright.json")"
mkdir -p "$ROOT/node_modules/playwright-core"
printf '{"browsers": [{"name": "chromium", "revision": "1200"}, {"name": "chromium-headless-shell", "revision": "1243"}]}\n' \
  > "$ROOT/node_modules/playwright-core/browsers.json"
missing="$(HOME="$H" env -u DESIGN_ROUNDS_CHROME python3 "$LOOKUP" 2>&1)"; rc=$?
check_eq "with the shared Playwright but no headless shell, the lookup refuses with exit 2" "2" "$rc"
check "naming the command that installs it" "install-playwright.sh" "$missing"
check "and the revision it looked for" "chromium_headless_shell-1243" "$missing"
check_not "and hands back no Google Chrome in its place" "Google Chrome.app" "$missing"
SHELL_BIN="$ROOT/browsers/chromium_headless_shell-1243/chrome-headless-shell-test-arch/chrome-headless-shell"
mkdir -p "$(dirname "$SHELL_BIN")" "$ROOT/browsers/chromium_headless_shell-1100/chrome-headless-shell-test-arch"
printf '#!/bin/sh\n' > "$SHELL_BIN"
chmod +x "$SHELL_BIN"
# An older revision beside it, which the installed Playwright no longer names.
cp "$SHELL_BIN" "$ROOT/browsers/chromium_headless_shell-1100/chrome-headless-shell-test-arch/chrome-headless-shell"
got="$(HOME="$H" env -u DESIGN_ROUNDS_CHROME python3 "$LOOKUP" 2>&1)"; rc=$?
check_eq "the shared install's headless shell, at the revision its Playwright names, is found" "0 $SHELL_BIN" "$rc $got"
got="$(HOME="$H" env -u DESIGN_ROUNDS_CHROME python3 "$PROBE" 2>&1)"
check_eq "and make-settled.py's lookup is that same one" "$SHELL_BIN" "$got"
chmod -x "$SHELL_BIN"
got="$(HOME="$H" env -u DESIGN_ROUNDS_CHROME python3 "$LOOKUP" 2>&1)"; rc=$?
check_eq "a headless shell that cannot be run is refused, never passed over for another Chrome" "2" "$rc"
chmod +x "$SHELL_BIN"
rm -rf "$ROOT/node_modules"
got="$(HOME="$H" env -u DESIGN_ROUNDS_CHROME python3 "$LOOKUP" 2>&1)"; rc=$?
check_eq "with no shared Playwright at all the lookup refuses with exit 2" "2" "$rc"
check "naming the command that installs it" "install-playwright.sh" "$got"
# A copy of the lookup whose shared-playwright.json is missing, then names no root: a refusal saying
# so, never a traceback.
mkdir -p "$TMP/pinless"
cp "$LOOKUP" "$TMP/pinless/headless_chrome.py"
got="$(HOME="$H" env -u DESIGN_ROUNDS_CHROME python3 "$TMP/pinless/headless_chrome.py" 2>&1)"; rc=$?
check_eq "with no shared-playwright.json beside it the lookup refuses with exit 2" "2" "$rc"
check "saying the file could not be read" "could not be read" "$got"
check_not "and never as a traceback" "Traceback" "$got"
printf '{"version": "1.63.0"}\n' > "$TMP/pinless/shared-playwright.json"
got="$(HOME="$H" env -u DESIGN_ROUNDS_CHROME python3 "$TMP/pinless/headless_chrome.py" 2>&1)"; rc=$?
check_eq "with a shared-playwright.json naming no root it refuses with exit 2" "2" "$rc"
check "saying so" "names no root" "$got"

# --- 3. DESIGN_ROUNDS_CHROME ---
fake_bundle "$TMP/Google Chrome.app" "$DAN_ID" "Google Chrome"
fake_bundle "$TMP/Renamed.app" "$DAN_ID" "Renamed"
fake_bundle "$TMP/Google Chrome for Testing.app" "com.google.chrome.for.testing" "Google Chrome for Testing"
DAN="$TMP/Google Chrome.app/Contents""/MacOS/Google Chrome"
got="$(DESIGN_ROUNDS_CHROME="$DAN" python3 "$LOOKUP" 2>&1)"; rc=$?
check_eq "DESIGN_ROUNDS_CHROME naming Dan's Chrome is refused with exit 2" "2" "$rc"
check "saying it is the Chrome Dan uses" "the Chrome Dan uses" "$got"
check "and naming the variable" "DESIGN_ROUNDS_CHROME" "$got"
got="$(DESIGN_ROUNDS_CHROME="$TMP/Renamed.app/Contents/MacOS/Renamed" python3 "$LOOKUP" 2>&1)"; rc=$?
check_eq "and so is a copy of it under another name, told by its bundle id" "2" "$rc"
got="$(DESIGN_ROUNDS_CHROME="$DAN" python3 "$PROBE" 2>&1)"
check "make-settled.py's lookup refuses it too" "REFUSED" "$got"
CFT="$TMP/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
got="$(DESIGN_ROUNDS_CHROME="$CFT" python3 "$LOOKUP" 2>&1)"; rc=$?
check_eq "DESIGN_ROUNDS_CHROME naming another build is used" "0 $CFT" "$rc $got"
got="$(DESIGN_ROUNDS_CHROME="$TMP/no-such-chrome" python3 "$LOOKUP" 2>&1)"; rc=$?
check_eq "DESIGN_ROUNDS_CHROME naming nothing is refused, never passed over" "2" "$rc"
check "naming the path" "no-such-chrome" "$got"
got="$(python3 "$LOOKUP" vet "$DAN" 2>&1)"; rc=$?
check_eq "vet refuses Dan's Chrome" "2" "$rc"
got="$(python3 "$LOOKUP" vet "$CFT" 2>&1)"; rc=$?
check_eq "and passes another build" "0" "$rc"

# --- 4. headless-dom.sh refuses Dan's Chrome in both modes, without running it ---
rm -f "$TMP/Google Chrome.app.ran"
out="$(HEADLESS_DOM_CHROME="$DAN" HEADLESS_DOM_DEADLINE=10 bash "$HEADLESS_DOM" "$HL" --dump-dom about:blank 2> "$TMP/dom.err")"; rc=$?
check_eq "headless-dom.sh refuses to dump a page with Dan's Chrome" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo "exit $rc")"
check "saying why" "the Chrome Dan uses" "$(cat "$TMP/dom.err")"
check_eq "and handing back nothing" "" "$out"
HEADLESS_DOM_EXEC=1 HEADLESS_DOM_CHROME="$DAN" bash "$HEADLESS_DOM" "$HL" about:blank > /dev/null 2> "$TMP/exec.err"; rc=$?
check_eq "and refuses to become Dan's Chrome in Playwright's place" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo "exit $rc")"
check "saying why" "the Chrome Dan uses" "$(cat "$TMP/exec.err")"
check_eq "and Dan's Chrome never ran" "no" "$([ -e "$TMP/Google Chrome.app.ran" ] && echo yes || echo no)"
# Named bare, as a link on PATH to Dan's Chrome, which PATH would resolve and run.
mkdir -p "$TMP/bin"
ln -s "$DAN" "$TMP/bin/google-chrome"
out="$(PATH="$TMP/bin:$PATH" HEADLESS_DOM_CHROME=google-chrome HEADLESS_DOM_DEADLINE=10 bash "$HEADLESS_DOM" "$HL" --dump-dom about:blank 2> "$TMP/bare.err")"; rc=$?
check_eq "and refuses Dan's Chrome named bare and found on PATH" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo "exit $rc")"
check "saying why" "the Chrome Dan uses" "$(cat "$TMP/bare.err")"
check_eq "and it never ran" "no" "$([ -e "$TMP/Google Chrome.app.ran" ] && echo yes || echo no)"
out="$(HEADLESS_DOM_CHROME="$CFT" HEADLESS_DOM_DEADLINE=10 bash "$HEADLESS_DOM" "$HL" --dump-dom about:blank 2>/dev/null)"; rc=$?
check_eq "while another build is run as before (L1)" "0 <html><body>drawn</body></html>" "$rc $out"

# --- 5. no file of the design rounds names Google Chrome's program ---
# Spelled in two halves, so this file does not name it either.
named="$(grep -rn -F "Google Chrome.app/Contents""/MacOS" "$DIR" --include='*.py' --include='*.sh' --include='*.mjs' --include='*.js' 2>/dev/null)"
check_eq "no file of the design rounds names Google Chrome's program, so every launcher goes through the one lookup" "" "$named"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
