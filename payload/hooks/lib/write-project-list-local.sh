#!/usr/bin/env bash
#
# lib/write-project-list-local.sh: write this Mac's own projects.local.txt from the last version
# of payload/CLAUDE.md that still listed this Mac's projects (claude-config#2112).
#
# The work MacBook's projects are work repositories, and the synced CLAUDE.md is public, so they
# left it for a file kept on that Mac only, which the sync never carries. The pull that delivers
# the new CLAUDE.md replaces that Mac's copy, so the list it held is gone from the file it used to
# be read from. It is not gone: every version of payload/CLAUDE.md is in the sync clone's history.
# This takes it from there, so nothing has to be typed out again by hand and nothing is lost in
# between (L5).
#
# Which version: the NEWEST commit touching payload/CLAUDE.md whose block for this host still has
# entries. The newest commit outright is the one that removed them, so it would yield nothing.
#
# It never writes over a file that is already there: a file this Mac holds is that Mac's own
# record, possibly edited since, and the run is safe to repeat (it says so and exits 0). It writes
# to a temporary name and moves it into place, so a run cut short leaves no half written list for
# the check to read as complete. What it prints is counts, paths and a commit, never the entries:
# they are work repository names, and this output lands in session transcripts.
#
# Run:  bash ~/.claude/hooks/lib/write-project-list-local.sh
#
# Exit 0 = written, or already there and left alone.
# Exit 2 = the repository to read history from is not a git repository here.
# Exit 3 = no version of payload/CLAUDE.md in that history lists any project for this host, so
#          there is nothing to write, and no empty file is written in its place.
# Exit 4 = the file could not be written.
#
# Environment:
#   PROJECT_LIST_HOST        write for this machine instead of the real hostname
#   PROJECT_LIST_LOCAL_FILE  write here instead of ~/.claude/projects.local.txt
#   PROJECT_LIST_REPO        read history from here instead of ~/claude-config-sync

set -uo pipefail

case "${BASH_SOURCE[0]}" in */*) DIR="${BASH_SOURCE[0]%/*}" ;; *) DIR=. ;; esac
DIR="$(cd "${DIR:-/}" && pwd)"
if ! . "$DIR/project-list.sh" 2>/dev/null; then
  echo "write-project-list-local: $DIR/project-list.sh is missing, so the list could not be read." >&2
  exit 2
fi

HOST="${PROJECT_LIST_HOST:-$(hostname 2>/dev/null)}"
HOST="${HOST%%.*}"
OUT="${PROJECT_LIST_LOCAL_FILE:-${CLAUDE_HOME:-$HOME/.claude}/$PL_LOCAL_NAME}"
REPO="${PROJECT_LIST_REPO:-$HOME/claude-config-sync}"

if [ -z "$HOST" ]; then
  echo "write-project-list-local: this machine has no readable hostname, so which block of the list to take could not be decided." >&2
  exit 2
fi

if [ -e "$OUT" ]; then
  echo "write-project-list-local: $OUT is already there, so it was left exactly as it is. Nothing was written."
  exit 0
fi

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "write-project-list-local: $REPO is not a git repository on this Mac, so there is no history to take the list from. Nothing was written." >&2
  exit 2
fi

found_sha=""
found_lines=""
shas="$(git -C "$REPO" log --format=%H HEAD -- payload/CLAUDE.md 2>/dev/null)"
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  lines="$(git -C "$REPO" show "$sha:payload/CLAUDE.md" 2>/dev/null | pl_section | pl_block "$HOST" | pl_entry_lines)"
  case "$lines" in
    *[![:space:]]*) found_sha="$sha"; found_lines="$lines"; break ;;
  esac
done <<EOF
$shas
EOF

if [ -z "$found_sha" ]; then
  echo "write-project-list-local: no version of payload/CLAUDE.md in $REPO lists a project under $HOST, so there is nothing to write. Nothing was written." >&2
  exit 3
fi

short="$(git -C "$REPO" rev-parse --short "$found_sha" 2>/dev/null)"
n="$(printf '%s\n' "$found_lines" | grep -c '^- `')"

case "$OUT" in */*) out_dir="${OUT%/*}" ;; *) out_dir=. ;; esac
tmp="$out_dir/.$PL_LOCAL_NAME.writing.$$"
if ! mkdir -p "${out_dir:-/}" 2>/dev/null \
  || ! printf '%s\n' \
    "This Mac's projects, kept on this Mac only because they are work repositories and the shared" \
    "CLAUDE.md is public (claude-config#2112). The sync never carries this file, and" \
    "hooks/check-project-list.sh checks each entry is here. Written $(date '+%Y-%m-%d') from commit $short." \
    "" \
    "$found_lines" > "$tmp" 2>/dev/null \
  || ! mv "$tmp" "$OUT" 2>/dev/null; then
  rm -f "$tmp" 2>/dev/null
  echo "write-project-list-local: $OUT could not be written. Nothing was left in its place." >&2
  exit 4
fi

echo "write-project-list-local: wrote $n entries for $HOST to $OUT, taken from commit $short, the last version of payload/CLAUDE.md that listed them."
exit 0
