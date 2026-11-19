#!/usr/bin/env bash
# install-claude-code.sh <folder> [--newest]: install Claude Code into <folder> from the vendor's own
# npm package, @anthropic-ai/claude-code, at one exact version, and print the path of its claude
# command on stdout, nothing else (claude-config#3297). Everything it says goes to stderr.
#
# With no second argument the version is the one written in .github/claude-code-version, and this is
# the only thing that reads that file: the pull request checks install from it, so raising the
# version is a pull request whose checks say whether the mods still pass on it. --newest asks npm
# for the newest release instead and installs that exact version, for the daily run that catches a
# release breaking a mod before the file is raised. A version is never "latest" or a range: whatever
# is installed is one exact version, said on stderr, so a red run names what it ran.
#
# Nothing is signed in and no key is needed (measured 2026-11-19 on 2.1.328: plugin validate and
# plugin test ran in an empty home folder with the network blocked). The command is left in
# <folder>/node_modules/.bin, never on PATH, so only the suites handed it (MODS_CLAUDE) start it.
# A folder already holding the version (restored from a cache) is used as it is.
#
# Exit codes: 0 installed or already there, 1 the install or its check failed, 2 bad arguments or a
# version file that does not hold exactly one version.
# CLAUDE_CODE_VERSION_FILE moves the version file, for tests. NPM_BIN names npm, else the one on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${CLAUDE_CODE_VERSION_FILE:-$ROOT/.github/claude-code-version}"
NPM="${NPM_BIN:-npm}"
PACKAGE="@anthropic-ai/claude-code"

say(){ echo "install-claude-code: $*" >&2; }

folder="${1:-}"
mode="${2:-}"
if [ -z "$folder" ] || [ $# -gt 2 ] || { [ -n "$mode" ] && [ "$mode" != --newest ]; }; then
  say "usage: install-claude-code.sh <folder> [--newest]. The version comes from $VERSION_FILE, or with --newest from npm; it is never given here, so the file stays the one place it is written."
  exit 2
fi

exact(){ [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

if [ "$mode" = --newest ]; then
  version="$("$NPM" view "$PACKAGE" dist-tags.latest 2>/dev/null | tr -d '[:space:]')"
  if ! exact "$version"; then
    say "npm did not name the newest release of $PACKAGE as one exact version (it answered '${version:-nothing}'), so nothing was installed."
    exit 1
  fi
  say "the newest release of $PACKAGE is $version."
else
  if [ ! -f "$VERSION_FILE" ]; then
    say "$VERSION_FILE is missing, so there is no version to install."
    exit 2
  fi
  lines="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$VERSION_FILE" | tr -d '[:blank:]')"
  if [ "$(printf '%s\n' "$lines" | grep -c .)" -ne 1 ] || ! exact "$lines"; then
    say "$VERSION_FILE must hold one exact version such as 2.1.328 on a line of its own, besides comment lines; it holds: $(printf '%s' "${lines:-nothing}" | tr '\n' ' ')"
    exit 2
  fi
  version="$lines"
fi

bin="$folder/node_modules/.bin/claude"
installed(){ [ -x "$bin" ] && [ "$("$bin" --version 2>/dev/null | head -n 1 | awk '{ print $1 }')" = "$version" ]; }

if installed; then
  say "Claude Code $version is already in $folder, so it was not downloaded again."
else
  mkdir -p "$folder" || { say "could not make $folder."; exit 1; }
  # The vendor's own package at the exact version; its install step copies the native build for this
  # platform over its placeholder, so scripts must run. No lockfile or package.json is kept.
  if ! out="$("$NPM" install --prefix "$folder" --no-save --no-package-lock --no-audit --no-fund "$PACKAGE@$version" 2>&1)"; then
    say "npm could not install $PACKAGE@$version into $folder. It said: $(printf '%s\n' "$out" | tail -n 5 | tr '\n' ' ')"
    exit 1
  fi
  if ! installed; then
    say "npm installed $PACKAGE@$version, but $bin does not answer --version with $version (it said: $("$bin" --version 2>&1 | head -n 2 | tr '\n' ' ')), so it is not the build asked for."
    exit 1
  fi
  say "installed Claude Code $version into $folder."
fi
printf '%s\n' "$bin"
