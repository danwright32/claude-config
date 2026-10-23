#!/usr/bin/env bash
# test-headless-chrome.sh: every headless Chrome this repository starts goes through headless-dom.sh,
# and a run that is killed leaves no copy of Chrome behind (claude-config#1537).
#
# Chrome copies its app bundle into a per user code sign clone folder each time it starts and removes
# the copy only on a quit it finishes itself, so a killed run left one every time: 288 between
# 2026-10-20 and 2026-10-22. headless-dom.sh starts Chrome with the copy switched off, as a dump of a
# page (its own tests are in test-make-switcher.sh) and, for Playwright, in place of Chrome's own
# binary (HEADLESS_DOM_EXEC). This holds:
#   1. the guard, check-chrome-launches.py, failing on each shape of a launch that goes around it and
#      passing what goes through it (L1);
#   2. that guard run over this whole repository, so the next hand written launch fails here (L613);
#   3. HEADLESS_DOM_EXEC, on a stand in Chrome: it becomes Chrome under the same pid, with every
#      disabled feature folded into the one switch Chrome reads;
#   4. a real Chrome started that way and killed mid run, and 5. a real Chrome Playwright started
#      through capture-web.mjs's launchChrome and abandoned by a killed node, each leaving no copy.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../../.." && pwd)"
GUARD="$DIR/check-chrome-launches.py"
HEADLESS_DOM="$DIR/headless-dom.sh"
KILL_TREE="$DIR/../../hooks/lib/kill-tree.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check_eq() { # check_eq <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
check() { # check <description> <expected substring> <actual>
  case "$3" in *"$2"*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); printf 'FAIL: %s\n  expected to contain: %s\n  actual: %s\n' "$1" "$2" "$3" ;; esac
}
# Chrome's headless switch, spelled so this file holds no launch of its own for the guard to find.
HL="--head""less"

# --- 1. the guard, on launches planted in a folder of its own ---
F="$TMP/tree"
mkdir -p "$F/skills" "$F/score"
cat > "$F/skills/direct.sh" <<EOF
#!/bin/bash
"\$CHROME" $HL --disable-gpu \\
  --dump-dom file:///x.html
EOF
cat > "$F/skills/routed.sh" <<EOF
#!/bin/bash
HEADLESS_DOM_CHROME="\$CHROME" bash "\$DIR/headless-dom.sh" $HL --disable-gpu \\
  --dump-dom file:///x.html
headless_dom $HL --dump-dom file:///y.html
# "\$CHROME" $HL in a comment runs nothing
check "the arguments it was given" "$HL --dump-dom file:///x.html" "\$(cat args)"
EOF
cat > "$F/skills/probe.py" <<EOF
import subprocess
subprocess.run([CHROME, "$HL", "--dump-dom", "file:///x.html"])
subprocess.run(["bash", HEADLESS_DOM, "$HL", "--dump-dom", "file:///x.html"])
EOF
cat > "$F/score/direct.mjs" <<EOF
const browser = await pw.chromium.launch({ channel: "chrome", args: LAUNCH_ARGS });
const other = await pw.chromium.launch({
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
});
const opts = { executablePath: process.env.CHROME };
const bundled = await pw.chromium.launch({ headless: true, args: ["--disable-gpu"] });
const routed = await pw.chromium.launch(chromeLaunchOptions(o.channel, LAUNCH_ARGS));
const defaults = { channel: "chrome", designOnly: false };
EOF
cat > "$F/score/spawn.js" <<EOF
spawn(chrome, ["$HL", "--screenshot", url]);
EOF
python3 -I "$GUARD" "$F" > "$TMP/guard.out" 2>&1; rc=$?
out="$(cat "$TMP/guard.out")"
check_eq "the guard fails on a tree holding a launch around headless-dom.sh" "1" "$rc"
check "it names a shell launch continued over lines, by its first line" "skills/direct.sh:2: runs headless Chrome without headless-dom.sh" "$out"
check "and a Python one" "skills/probe.py:2: runs headless Chrome without headless-dom.sh" "$out"
check "and one in JavaScript" "score/spawn.js:1: runs headless Chrome without headless-dom.sh" "$out"
check "and a Playwright launch of real Chrome by channel" "score/direct.mjs:1: launches a real Chrome through Playwright without headless-dom.sh (by channel)" "$out"
check "and by an executable path written across lines" "score/direct.mjs:2: launches a real Chrome through Playwright without headless-dom.sh (by executablePath)" "$out"
check "and an executable path handed over in options built away from the launch" "score/direct.mjs:5: hands a browser an executable path that is not headless-dom.sh" "$out"
check "and says how to start it instead" "through headless-dom.sh" "$out"
check_eq "and nothing else: not a launch through headless-dom.sh, a comment, an expected argument list, Playwright's own Chromium, or options naming no launch" \
  "6" "$(grep -c '^[a-z]*/[a-z]*\.[a-z]*:[0-9]*: ' "$TMP/guard.out")"
check_eq "a folder it cannot read is no pass" "2" "$(python3 -I "$GUARD" "$TMP/no-such-folder" >/dev/null 2>&1; echo $?)"
mkdir -p "$TMP/locked"
printf '#!/bin/bash\necho hidden\n' > "$TMP/locked/hidden.sh"
chmod 000 "$TMP/locked/hidden.sh"
if [ -r "$TMP/locked/hidden.sh" ]; then
  echo "SUITE-PART-UNMEASURED a file with no read permission is still readable here (run as root?), so a file the guard cannot read was not tested"
else
  python3 -I "$GUARD" "$TMP/locked" > "$TMP/locked.out" 2>&1; rc=$?
  check_eq "nor is a file in it that it cannot read" "2" "$rc"
  check "and it names that file" "hidden.sh" "$(cat "$TMP/locked.out")"
fi
chmod 600 "$TMP/locked/hidden.sh"

# --- 2. the guard, on this whole repository ---
# Three folders up is the checkout only when this runs from one: from the installed copy in
# ~/.claude/skills it is the home folder, which is never scanned (check-root-guard.sh, #503).
if [ -e "$REPO/claude-sync" ] && [ -d "$REPO/payload" ]; then
  python3 -I "$GUARD" "$REPO" > "$TMP/repo.out" 2>&1; rc=$?
  check_eq "every headless Chrome this repository starts goes through headless-dom.sh" "0" "$rc"
  [ "$rc" -eq 0 ] || sed 's/^/    /' "$TMP/repo.out"
else
  echo "SUITE-PART-UNMEASURED $REPO is not a claude-config checkout (no claude-sync and payload there), so the repository was not scanned for Chrome started around headless-dom.sh"
fi

# --- 3. HEADLESS_DOM_EXEC, on a stand in Chrome ---
cat > "$TMP/fake-chrome" <<'FAKE'
#!/bin/bash
# A stand in Chrome: records its pid and its arguments, one per line, and exits with FAKE_RC.
echo "$$" > "$FAKE_OUT.pid"
printf '%s\n' "$@" > "$FAKE_OUT.args"
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$TMP/fake-chrome"
export FAKE_OUT="$TMP/fake"
# The arguments as Playwright gives them: its own disabled features early, the caller's later.
HEADLESS_DOM_EXEC=1 HEADLESS_DOM_CHROME="$TMP/fake-chrome" FAKE_RC=7 "$HEADLESS_DOM" --disable-field-trial-config \
  --disable-features=Translate,PaintHolding "$HL" --remote-debugging-pipe --disable-features=Foo --no-sandbox about:blank &
p=$!
wait "$p"; rc=$?
check_eq "run in Chrome's place, it becomes Chrome under the same pid, which is what Playwright watches and kills" "$p" "$(cat "$FAKE_OUT.pid" 2>/dev/null)"
check_eq "and Chrome's exit status is its own" "7" "$rc"
check_eq "every disabled feature is folded into one switch with the copy switched off" \
  "--disable-features=Translate,PaintHolding,Foo,MacAppCodeSignClone" "$(grep -e '^--disable-features=' "$FAKE_OUT.args" | tr '\n' ' ' | sed 's/ $//')"
check_eq "and every other argument is passed as it came, in its order" \
  "--disable-field-trial-config $HL --remote-debugging-pipe --no-sandbox about:blank" \
  "$(grep -v -e '^--disable-features=' "$FAKE_OUT.args" | tr '\n' ' ' | sed 's/ $//')"
check_eq "and no profile of its own is added, since the caller owns that" "" "$(grep -e '^--user-data-dir' "$FAKE_OUT.args")"
HEADLESS_DOM_EXEC=1 HEADLESS_DOM_CHROME="$TMP/no-such-chrome" "$HEADLESS_DOM" "$HL" about:blank > /dev/null 2> "$TMP/missing.err"; rc=$?
check_eq "a Chrome that is not there fails" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and says which" "no-such-chrome" "$(cat "$TMP/missing.err")"

# --- 4 and 5. a real Chrome, killed mid run, leaves no copy behind ---
#
# Other sessions' Chromes add copies to the real folder at any moment, and can only ever ADD them, so
# a run that shows nothing new proves this run left none, while a run that leaves its copy shows one
# on every attempt: three attempts tell the two apart (as test-make-switcher.sh's real Chrome check).
REAL_CHROME="${HEADLESS_CHROME_TEST_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
real_tmp="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)}"
clones="$(cd "${real_tmp%/}/.." 2>/dev/null && pwd -P)/X/com.google.Chrome.code_sign_clone"
if [ ! -d "$clones" ]; then
  real_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
  clones="$(cd "${real_tmp%/}/.." 2>/dev/null && pwd -P)/X/com.google.Chrome.code_sign_clone"
fi
before(){ ls -1 "$clones" 2>/dev/null | LC_ALL=C sort > "$TMP/clones.before"; }
left(){ ls -1 "$clones" 2>/dev/null | LC_ALL=C sort | LC_ALL=C comm -13 "$TMP/clones.before" - | tr '\n' ' ' | sed 's/ $//'; }
# Ends what a test started, by the pid it recorded (L1011), and waits for it to be gone.
end_tree(){ [ -n "${1:-}" ] || return 0; bash "$KILL_TREE" "$1" 2>/dev/null; kill -KILL "$1" 2>/dev/null; local n=0; while kill -0 "$1" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; }
# Waits, bounded, for a file to hold something (L290).
await_file(){ local n=0; while [ ! -s "$1" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done; [ -s "$1" ]; }

if [ ! -x "$REAL_CHROME" ]; then
  echo "SUITE-PART-UNMEASURED no Chrome at $REAL_CHROME, so whether a killed real Chrome leaves its copy behind was not measured"
elif [ ! -d "$clones" ]; then
  echo "SUITE-PART-UNMEASURED no clone folder at $clones, so whether a killed real Chrome leaves its copy behind was not measured"
else
  # 4. Started in Chrome's place, as Playwright starts it, and killed while it runs.
  got="not run"
  for attempt in 1 2 3; do
    before
    prof="$TMP/profile-$attempt"
    HEADLESS_DOM_EXEC=1 HEADLESS_DOM_CHROME="$REAL_CHROME" "$HEADLESS_DOM" "$HL" --user-data-dir="$prof" --disable-gpu \
      --no-sandbox --remote-debugging-port=0 about:blank > /dev/null 2> "$TMP/exec.err" &
    cp=$!
    # Up once it has written the port it listens on into its profile.
    await_file "$prof/DevToolsActivePort" || true
    up="$([ -s "$prof/DevToolsActivePort" ] && echo up || echo "never up: $(tail -n 2 "$TMP/exec.err" | tr '\n' ' ')")"
    end_tree "$cp"; { wait "$cp"; } 2>/dev/null
    got="$(left)"
    [ -z "$got" ] && break
  done
  check_eq "a real Chrome started through headless-dom.sh in Chrome's place came up" "up" "$up"
  check_eq "and killed while it ran, it left no copy of Chrome in $clones" "" "$got"

  # 5. Started by Playwright through capture-web.mjs's launchChrome, and abandoned by a node that was
  # killed while the page was open, so nothing closed it.
  if ! command -v node >/dev/null 2>&1; then
    echo "SUITE-PART-UNMEASURED node is not on PATH, so a Playwright Chrome abandoned by a killed run was not measured"
  else
    cat > "$TMP/abandon.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const { findPlaywright, launchChrome, loadPlaywright } = await import(pathToFileURL(process.argv[2]).href);
let pw;
try { pw = loadPlaywright(findPlaywright({ repo: process.cwd() })); } catch (e) { console.log("NO-PLAYWRIGHT " + String(e.message || e).split("\n")[0]); process.exit(0); }
const browser = await launchChrome(pw, "chrome", ["--disable-gpu"]);
const page = await browser.newPage();
await page.setContent("<p>drawn</p>");
console.log("drawn " + process.pid);
setInterval(() => {}, 1000);
JS
    got="not run"; said=""
    for attempt in 1 2 3; do
      before
      : > "$TMP/node.out"
      ( cd "$TMP" && exec node "$TMP/abandon.mjs" "$DIR/score/capture-web.mjs" ) > "$TMP/node.out" 2>&1 &
      np=$!
      n=0; while ! grep -q -e '^drawn ' -e '^NO-PLAYWRIGHT' "$TMP/node.out" && kill -0 "$np" 2>/dev/null && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
      said="$(head -c 400 "$TMP/node.out")"
      kids="$(pgrep -P "$np" | tr '\n' ' ')"
      kill -KILL "$np" 2>/dev/null; wait "$np" 2>/dev/null
      for k in $kids; do end_tree "$k"; done
      got="$(left)"
      [ -z "$got" ] && break
    done
    case "$said" in
      NO-PLAYWRIGHT*)
        echo "SUITE-PART-UNMEASURED no Playwright to launch Chrome with here ($said), so a Playwright Chrome abandoned by a killed run was not measured" ;;
      *)
        check "Playwright drew a page in a real Chrome started through launchChrome" "drawn " "$said"
        check_eq "and with the node that started it killed, it left no copy of Chrome in $clones" "" "$got" ;;
    esac
  fi
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
