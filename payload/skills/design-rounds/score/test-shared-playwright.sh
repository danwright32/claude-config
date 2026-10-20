#!/usr/bin/env bash
# test-shared-playwright.sh: install-playwright.sh, the one Playwright each Mac shares for the design
# match score's design side (claude-config#1385). The Mac apps have no node_modules of their own, so
# capture-web.mjs falls back to this install, under HOME and outside ~/.claude.
#
# Run against a stand in npm whose package's launch needs the Chromium its own installer put under
# PLAYWRIGHT_BROWSERS_PATH, so nothing is downloaded here and a browser installed to the wrong place
# fails the same way it would for real. Every run reads stdin from /dev/null: the installer must
# never wait on a prompt.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$HERE/install-playwright.sh"
PIN="$HERE/shared-playwright.json"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0; unmeasured=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed -n '1,30p' | sed 's/^/    /'; }
said() { grep -q -- "$1" "$2"; }

if ! command -v node >/dev/null 2>&1; then
  echo "UNMEASURED: node is not on PATH, so the installer (which needs node and npm) was not run"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 0
fi

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PIN")"
REL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root"])' "$PIN")"

# --- the stand in npm and the package it installs ---------------------------------------------------
mkdir -p "$T/bin" "$T/pkg"
cat > "$T/pkg/index.js" <<'JS'
const fs = require("fs"), path = require("path");
module.exports.chromium = {
  launch: async () => {
    const dir = process.env.PLAYWRIGHT_BROWSERS_PATH || "";
    if (!dir || !fs.existsSync(path.join(dir, "fake-chromium"))) {
      throw new Error("browserType.launch: Executable doesn't exist under " + (dir || "the default cache"));
    }
    return { close: async () => {} };
  },
};
JS
cat > "$T/pkg/cli.js" <<'JS'
const fs = require("fs"), path = require("path");
fs.appendFileSync(process.env.FAKE_LOG, "playwright " + process.argv.slice(2).join(" ") + " browsers=" + (process.env.PLAYWRIGHT_BROWSERS_PATH || "") + "\n");
if (process.env.FAKE_BROWSER_FAIL) { console.error("Error: download failed: ECONNRESET"); process.exit(1); }
fs.mkdirSync(path.join(process.env.PLAYWRIGHT_BROWSERS_PATH, "fake-chromium"), { recursive: true });
JS
cat > "$T/bin/npm" <<SH
#!/usr/bin/env bash
echo "npm \$*" >> "\$FAKE_LOG"
if [ -n "\${FAKE_NPM_FAIL:-}" ]; then echo "npm ERR! code ETIMEDOUT" >&2; exit 1; fi
prefix=""; spec=""
while [ \$# -gt 0 ]; do
  case "\$1" in --prefix) prefix="\$2"; shift 2;; playwright@*) spec="\${1#playwright@}"; shift;; *) shift;; esac
done
pkg="\$prefix/node_modules/playwright"
mkdir -p "\$pkg"
printf '{"name": "playwright", "version": "%s", "main": "index.js"}\n' "\$spec" > "\$pkg/package.json"
cp "$T/pkg/index.js" "$T/pkg/cli.js" "\$pkg/"
SH
chmod +x "$T/bin/npm"

run_install() {  # run_install <home> <log> <out> [args...]
  local home="$1" log="$2" out="$3"; shift 3
  HOME="$home" PATH="$T/bin:$PATH" FAKE_LOG="$log" bash "$INSTALL" "$@" < /dev/null > "$out" 2>&1
}
npm_runs() { grep -c '^npm install' "$1" 2>/dev/null || true; }

# --- 1. where it lives ------------------------------------------------------------------------------
case "$REL" in
  .claude*|*/.claude*) bad "the shared install lives outside ~/.claude, so the sync never carries it (root is $REL)";;
  *) ok;;
esac
if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok; else bad "the Playwright version is pinned exactly (it is $VERSION)"; fi

# --- 2. a fresh install -----------------------------------------------------------------------------
H="$T/h1"; mkdir -p "$H"; L="$T/h1.log"; : > "$L"
ROOT="$H/$REL"
run_install "$H" "$L" "$T/h1.out"; rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "a fresh install succeeds (rc=$rc)" "$(cat "$T/h1.out")"; fi
if grep -q "^npm install .*--prefix $ROOT .*playwright@$VERSION" "$L"; then ok; else bad "it installs exactly the pinned version into the shared root" "$(cat "$L")"; fi
if grep -q "^playwright install chromium .*browsers=$ROOT/browsers$" "$L"; then ok; else bad "it installs Chromium beside the package, under the shared root" "$(cat "$L")"; fi
if said "export DESIGN_SCORE_PLAYWRIGHT=$ROOT/node_modules/playwright" "$T/h1.out"; then ok; else bad "it prints the path to export" "$(cat "$T/h1.out")"; fi
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/node_modules/playwright/package.json" 2>/dev/null)" = "$VERSION" ]; then ok; else bad "the installed package is the pinned version"; fi

# --- 3. idempotent: a second run installs nothing ---------------------------------------------------
before="$(npm_runs "$L")"; lines_before="$(wc -l < "$L")"
run_install "$H" "$L" "$T/h1b.out"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(wc -l < "$L")" -eq "$lines_before" ] && said "already installed" "$T/h1b.out" \
  && said "export DESIGN_SCORE_PLAYWRIGHT=$ROOT/node_modules/playwright" "$T/h1b.out"; then ok
else bad "a second run finds it installed and usable, installs nothing and prints the path again (rc=$rc, npm runs $before then $(npm_runs "$L"))" "$(cat "$T/h1b.out")"; fi

# --- 4. --check reads without installing ------------------------------------------------------------
run_install "$H" "$L" "$T/h1c.out" --check; rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "--check on a usable install exits 0 (rc=$rc)" "$(cat "$T/h1c.out")"; fi
H2="$T/h2"; mkdir -p "$H2"; L2="$T/h2.log"; : > "$L2"
run_install "$H2" "$L2" "$T/h2.out" --check; rc=$?
if [ "$rc" -eq 1 ] && said "install-playwright.sh" "$T/h2.out" && [ ! -e "$H2/$REL" ] && [ ! -s "$L2" ]; then ok
else bad "--check with nothing installed exits 1, names the install command and installs nothing (rc=$rc)" "$(cat "$T/h2.out")"; fi

# --- 5. a wrong version or missing browsers are repaired ---------------------------------------------
printf '{"name": "playwright", "version": "1.0.0", "main": "index.js"}\n' > "$ROOT/node_modules/playwright/package.json"
before="$(npm_runs "$L")"
run_install "$H" "$L" "$T/h1d.out"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(npm_runs "$L")" -gt "$before" ] && said "1.0.0" "$T/h1d.out"; then ok
else bad "an install of another version is replaced by the pinned one, saying which it found (rc=$rc)" "$(cat "$T/h1d.out")"; fi
rm -rf "$ROOT/browsers"
run_install "$H" "$L" "$T/h1e.out"; rc=$?
run_install "$H" "$L" "$T/h1f.out" --check; rc2=$?
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ]; then ok; else bad "an install whose Chromium is gone gets it back (rc=$rc, then --check rc=$rc2)" "$(cat "$T/h1e.out")"; fi

# --- 6. failures are said, and never end with the path to export -------------------------------------
H3="$T/h3"; mkdir -p "$H3"
FAKE_NPM_FAIL=1 run_install "$H3" "$T/h3.log" "$T/h3.out"; rc=$?
if [ "$rc" -ne 0 ] && said "ETIMEDOUT" "$T/h3.out" && ! said "export DESIGN_SCORE_PLAYWRIGHT" "$T/h3.out"; then ok
else bad "npm failing fails the install, showing npm's error and no path to export (rc=$rc)" "$(cat "$T/h3.out")"; fi
H4="$T/h4"; mkdir -p "$H4"
FAKE_BROWSER_FAIL=1 run_install "$H4" "$T/h4.log" "$T/h4.out"; rc=$?
if [ "$rc" -ne 0 ] && said "ECONNRESET" "$T/h4.out" && ! said "export DESIGN_SCORE_PLAYWRIGHT" "$T/h4.out"; then ok
else bad "the Chromium download failing fails the install, showing why and no path to export (rc=$rc)" "$(cat "$T/h4.out")"; fi

# --- 7. two installs at once: the second refuses while the first is alive -----------------------------
H5="$T/h5"; mkdir -p "$H5/$REL.lock"
sleep 600 & live=$!
echo "$live" > "$H5/$REL.lock/pid"
run_install "$H5" "$T/h5.log" "$T/h5.out"; rc=$?
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
if [ "$rc" -eq 2 ] && said "another install" "$T/h5.out" && [ ! -s "$T/h5.log" ]; then ok
else bad "an install while another is running refuses, naming it, and installs nothing (rc=$rc)" "$(cat "$T/h5.out")"; fi
# A lock whose pid is not written yet belongs to an install that has only just taken it: held, not dead.
H7="$T/h7"; mkdir -p "$H7/$REL.lock"
run_install "$H7" "$T/h7.log" "$T/h7.out"; rc=$?
if [ "$rc" -eq 2 ] && said "another install" "$T/h7.out" && [ -d "$H7/$REL.lock" ] && [ ! -s "$T/h7.log" ]; then ok
else bad "a lock with no pid written yet is held, never taken over (rc=$rc)" "$(cat "$T/h7.out")"; fi
# The same lock left by an install that died is taken over.
run_install "$H5" "$T/h5.log" "$T/h5b.out"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$H5/$REL.lock" ]; then ok; else bad "a lock left by an install that died is taken over, and released at the end (rc=$rc)" "$(cat "$T/h5b.out")"; fi

# --- 8. no node: said by name --------------------------------------------------------------------------
if PATH=/usr/bin:/bin command -v node >/dev/null 2>&1 || PATH=/usr/bin:/bin command -v npm >/dev/null 2>&1; then
  echo "UNMEASURED: node or npm is in /usr/bin or /bin here, so a machine without them could not be stood in for"
  unmeasured=$((unmeasured + 1))
else
  HOME="$T/h6" PATH=/usr/bin:/bin bash "$INSTALL" < /dev/null > "$T/h6.out" 2>&1; rc=$?
  if [ "$rc" -eq 2 ] && said "node" "$T/h6.out"; then ok; else bad "with no node or npm it exits 2 naming what is missing (rc=$rc)" "$(cat "$T/h6.out")"; fi
fi

echo
echo "passed: $pass, failed: $fail"
[ "$unmeasured" -gt 0 ] && echo "UNMEASURED-SECTIONS $unmeasured"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
