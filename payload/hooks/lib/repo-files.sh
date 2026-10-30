#!/usr/bin/env bash
# repo-files.sh [--uncommitted | --changed] <root> [pathspec...]
#
# The files a whole tree scanner reads, one per line, relative to <root>: everything git tracks,
# plus what is staged, plus every untracked file that is not ignored (claude-config#522). With
# --uncommitted, only the staged and untracked ones, which is what a gate reports it included.
#
# With --changed, every path among those whose contents on disk may differ from the commit: a
# tracked file edited, staged or DELETED, a staged addition, and an untracked file (#1910). It is
# what a key over what the scanners read is built from, alongside the commit's tree. The scanners
# read tracked files from disk, so an edit not committed changes what they read as much as a new
# file does; a key built from --uncommitted alone did not change with it, and a pass reached before
# the edit let a push skip scanning the edited file. A deleted path is listed although it is not
# there, since its absence also changes what the scanners read. Refused when there is no commit to
# compare against, rather than listed as nothing differing (L98).
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
only_changed=""
case "${1:-}" in
  --uncommitted) only_uncommitted=1; shift ;;
  --changed) only_changed=1; shift ;;
esac
root="${1:-}"
[ -n "$root" ] || { echo "repo-files: usage: repo-files.sh [--uncommitted | --changed] <root> [pathspec...]" >&2; exit 2; }
shift

if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  echo "repo-files: $root is not a git repository, so there is no list of its files to give." >&2
  exit 1
fi

if [ -n "$only_changed" ]; then
  # Both listings must succeed, each judged by its own exit code, or the list is refused: a key
  # built from half of it would let a pass stand for files nobody compared. Without --no-renames a
  # deleted file and a staged one with the same contents are paired as one rename and only the new
  # name is printed, so the deletion went unlisted (seen in this suite's fixture).
  #
  # Read with -z, so a name git would otherwise quote, one with a non-ASCII character or a double
  # quote in it, arrives as it is on disk. Quoted, it named no file there, so it read as deleted and
  # an edit to it never changed the key. The NULs become newlines for the list this prints, under
  # pipefail so git's own failure still refuses; a name holding a newline is the one this cannot
  # carry, and it splits into two that each read as deleted.
  if ! changed="$(git -C "$root" diff --name-only -z --no-renames HEAD -- "$@" 2>/dev/null | tr '\0' '\n')" \
     || ! untracked="$(git -C "$root" ls-files -z --others --exclude-standard -- "$@" 2>/dev/null | tr '\0' '\n')"; then
    echo "repo-files: git could not list the files under $root that differ from its commit." >&2
    exit 1
  fi
  # A path that is a file, or is not there at all (deleted). A directory is a nested checkout,
  # which is somebody else's and is not read.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$root/$f" ] || [ ! -e "$root/$f" ]; then printf '%s\n' "$f"; fi
  done <<LIST
$(printf '%s\n%s\n' "$changed" "$untracked" | sort -u)
LIST
  exit 0
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
