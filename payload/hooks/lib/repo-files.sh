#!/usr/bin/env bash
# repo-files.sh [--uncommitted] <root> [pathspec...]
#
# The files a whole tree scanner reads, one per line, relative to <root>: everything git tracks,
# plus what is staged, plus every untracked file that is not ignored (claude-config#522). With
# --uncommitted, only the staged and untracked ones, which is what a gate reports it included.
#
# Every scanner here used to ask `git ls-files`, which lists TRACKED files only, so the file just
# written was exempt from the checks that exist to catch it, and it is the one most likely to be
# wrong (L456). Measured 2026-09-20: a new hook with two short circuiting pipelines passed the
# pipefail ratchet while untracked and failed it the moment it was committed.
#
# Left out, deliberately: a file deleted from the tree (there is nothing to read), an ignored file,
# and a nested checkout, which git reports as a directory and which is somebody else's (L234).
#
# Exit 1, with the reason, when <root> is not a git repository: an empty list there would read as
# a clean tree rather than an unread one (L98).
set -uo pipefail

only_uncommitted=""
if [ "${1:-}" = "--uncommitted" ]; then only_uncommitted=1; shift; fi
root="${1:-}"
[ -n "$root" ] || { echo "repo-files: usage: repo-files.sh [--uncommitted] <root> [pathspec...]" >&2; exit 2; }
shift

if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  echo "repo-files: $root is not a git repository, so there is no list of its files to give." >&2
  exit 1
fi

if [ -n "$only_uncommitted" ]; then
  # Staged but never committed, and untracked. A tracked file with edits is not listed: it was
  # already being read.
  listed="$( { git -C "$root" diff --cached --name-only --diff-filter=A -- "$@"
               git -C "$root" ls-files --others --exclude-standard -- "$@"; } 2>/dev/null)" || {
    echo "repo-files: git could not list the uncommitted files under $root." >&2; exit 1; }
else
  listed="$(git -C "$root" ls-files --cached --others --exclude-standard -- "$@" 2>/dev/null)" || {
    echo "repo-files: git could not list the files under $root." >&2; exit 1; }
fi

# Sorted once, into a variable, and filtered by a loop rather than piped into a consumer that
# leaves early (L183). Only what exists as a file survives.
sorted="$(printf '%s\n' "$listed" | sort -u)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$root/$f" ] && printf '%s\n' "$f"
done <<LIST
$sorted
LIST
exit 0
