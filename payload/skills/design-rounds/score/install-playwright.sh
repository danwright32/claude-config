#!/usr/bin/env bash
# install-playwright.sh: the one Playwright each Mac shares for the design match score's design side
# (claude-config#1385).
#
#   bash install-playwright.sh            install it if it is missing or not usable, then say where
#   bash install-playwright.sh --check    say whether it is usable, installing nothing
#
# The Mac apps (Ovation, Overture, Downbeat) have no node_modules, so capture-web.mjs --design-only
# needs a Playwright from somewhere. Dan's decision, 2026-10-20: one shared install per Mac, outside
# the app repositories. shared-playwright.json, beside this script, names the exact version and the
# folder under HOME (outside ~/.claude, so the sync never carries a few hundred megabytes of browser
# between the Macs). The package goes in <root>/node_modules/playwright and its Chromium in
# <root>/browsers; capture-web.mjs finds both there on its own, after the app's own Playwright and
# DESIGN_SCORE_PLAYWRIGHT.
#
# Usable means the pinned version is installed AND its Chromium launches, measured each run rather
# than read from a marker, so an install that died halfway is found and finished on the next run.
# It never prompts, and it is safe to run twice: a second run that finds it usable installs nothing,
# and two at once are kept apart by a lock that a dead install's leftover does not hold.
#
# Exit 0 usable (the path to export is printed), 1 not usable (the install failed, or --check found
# it missing), 2 could not run (no node or npm, another install running, an unknown argument).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN="$HERE/shared-playwright.json"

check_only=0
case "${1:-}" in
  "") ;;
  --check) check_only=1 ;;
  *) echo "install-playwright: unknown argument $1 (usage: install-playwright.sh [--check])"; exit 2 ;;
esac

for tool in node npm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "install-playwright: $tool is not on PATH, and the shared Playwright is installed with node and npm. Install node (with npm), then run this again."
    exit 2
  fi
done

pin_field() { node -e 'process.stdout.write(String(require(process.argv[1])[process.argv[2]] || ""))' "$PIN" "$1"; }
VERSION="$(pin_field version)"
REL="$(pin_field root)"
if [ -z "$VERSION" ] || [ -z "$REL" ]; then
  echo "install-playwright: $PIN does not name a version and a root"
  exit 2
fi
ROOT="$HOME/$REL"
PKG="$ROOT/node_modules/playwright"
BROWSERS="$ROOT/browsers"
LOCK="$ROOT.lock"

installed_version() {
  [ -f "$PKG/package.json" ] || return 0
  node -e 'process.stdout.write(String(require(process.argv[1]).version || ""))' "$PKG/package.json" 2>/dev/null
}

# Launches the installed Chromium headless and closes it; prints why when it cannot.
launches() {
  PLAYWRIGHT_BROWSERS_PATH="$BROWSERS" node -e '
    require(process.argv[1]).chromium.launch()
      .then((b) => b.close())
      .then(() => process.exit(0), (e) => { console.log(String(e && e.message ? e.message : e).split("\n")[0]); process.exit(1); });
  ' "$PKG" 2>&1
}

# Sets $why to what is wrong, and returns 0 only when the install is usable.
usable() {
  local have
  have="$(installed_version)"
  if [ -z "$have" ]; then why="Playwright is not installed at $PKG"; return 1; fi
  if [ "$have" != "$VERSION" ]; then why="Playwright $have is installed at $PKG, not the pinned $VERSION"; return 1; fi
  local out
  if ! out="$(launches)"; then why="Playwright $have is installed but its Chromium does not launch: $out"; return 1; fi
  why=""
  return 0
}

say_usable() {
  echo "install-playwright: Playwright $VERSION and its Chromium are installed at $ROOT ($(du -sh "$ROOT" 2>/dev/null | cut -f1) on disk)."
  echo "capture-web.mjs finds it there on its own. To name it explicitly:"
  echo "export DESIGN_SCORE_PLAYWRIGHT=$PKG"
}

why=""
if usable; then
  echo "install-playwright: already installed, nothing to do."
  say_usable
  exit 0
fi
if [ "$check_only" -eq 1 ]; then
  echo "install-playwright: not usable: $why"
  echo "Install it with: bash $HERE/install-playwright.sh"
  exit 1
fi
echo "install-playwright: $why; installing."

# One install at a time. mkdir is atomic; a lock whose install has died (its pid is gone) is taken over.
mkdir -p "$(dirname "$LOCK")"
if ! mkdir "$LOCK" 2>/dev/null; then
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    echo "install-playwright: another install is running (pid $holder, lock at $LOCK). Let it finish, then run this again."
    exit 2
  fi
  rm -rf "$LOCK"
  if ! mkdir "$LOCK" 2>/dev/null; then
    echo "install-playwright: another install took the lock at $LOCK just now. Let it finish, then run this again."
    exit 2
  fi
fi
echo "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

mkdir -p "$ROOT"
[ -f "$ROOT/package.json" ] || printf '{"name": "design-score-playwright", "private": true}\n' > "$ROOT/package.json"

if [ "$(installed_version)" != "$VERSION" ]; then
  echo "install-playwright: npm install playwright@$VERSION into $ROOT"
  if ! npm install --prefix "$ROOT" --save-exact --no-audit --no-fund "playwright@$VERSION" 2>&1; then
    echo "install-playwright: FAILED: npm could not install playwright@$VERSION (its output is above). Nothing usable was installed."
    exit 1
  fi
fi

# The headless shell only: capture-web.mjs always launches headless.
echo "install-playwright: installing Playwright $VERSION's Chromium into $BROWSERS"
if ! PLAYWRIGHT_BROWSERS_PATH="$BROWSERS" node "$PKG/cli.js" install chromium --only-shell 2>&1; then
  echo "install-playwright: FAILED: Playwright could not install its Chromium (its output is above)."
  exit 1
fi

if ! usable; then
  echo "install-playwright: FAILED: installed, but still not usable: $why"
  exit 1
fi
say_usable
exit 0
