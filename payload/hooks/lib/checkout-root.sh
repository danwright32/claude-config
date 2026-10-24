#!/usr/bin/env bash
# checkout-root.sh <payload dir>
#
# The top level of the claude-config checkout whose payload <payload dir> is, printed on one line,
# exit 0; exit 1 with the reason on stderr when it is not one, exit 2 when no folder is given
# (claude-config#1567). The one test every whole tree scan suite asks before it lists the files the
# repository ships with lib/repo-files.sh: test-two-file-awk.sh, test-pipefail-shortcircuit.sh,
# test-lib-self-locate.sh and test-branch-issue-reader.sh.
#
# A git repository above the folder is not enough. Installed in ~/.claude there is no checkout, and
# a copy sitting inside some other repository (a home folder kept in git) would otherwise have that
# repository scanned as this one, judging somebody else's files and reporting it as a verdict on
# ours (PR #1562). So the folder is a checkout's payload only when its git top level holds
# claude-sync and a payload/ that is this very folder, compared after resolving links.
set -uo pipefail

dir="${1:-}"
[ -n "$dir" ] || { echo "checkout-root: usage: checkout-root.sh <payload dir>" >&2; exit 2; }

real="$(cd "$dir" 2>/dev/null && pwd -P)" || {
  echo "checkout-root: $dir is not a folder, so it is not the payload of a claude-config checkout." >&2; exit 1; }
top="$(git -C "$real" rev-parse --show-toplevel 2>/dev/null)" || top=""
if [ -z "$top" ]; then
  echo "checkout-root: $dir is in no git repository, so it is not the payload of a claude-config checkout." >&2
  exit 1
fi
if [ ! -f "$top/claude-sync" ] || [ ! -d "$top/payload" ] \
   || [ "$(cd "$top/payload" && pwd -P)" != "$real" ]; then
  echo "checkout-root: $dir is in the repository at $top, which is not a claude-config checkout whose payload is this folder (it needs claude-sync and this folder as its payload/)." >&2
  exit 1
fi
printf '%s\n' "$top"
