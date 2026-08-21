#!/usr/bin/env bash
#
# check-project-list.sh: fail when a project this Mac is listed as holding is not there
# (claude-config#122).
#
# The Projects section of the synced CLAUDE.md named four projects by absolute path and not one of
# them existed on this machine. That file loads at the start of every session on both Macs, so the
# list was read constantly and was wrong on at least one of them, and working out why cost a search
# of the whole home directory before it became clear they were simply on the other Mac. It is a
# path recording where something happened to be rather than what it is (L153), shared between two
# machines whose contents differ.
#
# The list cannot be DERIVED, which is what L41 would normally ask for: nothing on disk says which
# of the repos here are the ones being worked on. So it stays hand written and is CHECKED instead,
# which is the next best thing and costs one stat per entry.
#
# Run:  bash ~/.claude/hooks/check-project-list.sh
#
# Exit 0 = every path listed for this machine is there, or the list names no block for this
#          machine at all, which is said out loud rather than passed over.
# Exit 1 = at least one listed path is missing.
# Exit 2 = the file, the section, or the machine blocks are absent, so nothing could be checked.
#          Refusing rather than passing, because reading nothing and finding nothing wrong are
#          indistinguishable otherwise (L98).
#
# Environment:
#   PROJECT_LIST_FILE   read this file instead of the synced CLAUDE.md
#   PROJECT_LIST_HOST   judge as this machine instead of the real hostname

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FILE="${PROJECT_LIST_FILE:-}"
if [ -z "$FILE" ]; then
  # In the repo the payload's CLAUDE.md sits one level up; installed, the hooks directory sits
  # inside the config directory and the file is beside it. Both are tried, and neither is assumed.
  for cand in "$DIR/../CLAUDE.md" "${CLAUDE_HOME:-$HOME/.claude}/CLAUDE.md"; do
    if [ -f "$cand" ]; then FILE="$cand"; break; fi
  done
fi
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "check-project-list: no CLAUDE.md to read (looked for '${PROJECT_LIST_FILE:-$DIR/../CLAUDE.md}'). Refusing rather than reporting a list with nothing wrong in it." >&2
  exit 2
fi

# The short name, because `hostname` answers with a trailing .local here while the sync's own
# commit subjects use the short form, and the list is written to match what a person would type.
HOST="${PROJECT_LIST_HOST:-$(hostname 2>/dev/null)}"
HOST="${HOST%%.*}"
if [ -z "$HOST" ]; then
  echo "check-project-list: this machine has no readable hostname, so which block of the list applies could not be decided." >&2
  exit 2
fi

# The Projects section only, so a path mentioned anywhere else in the file is not read as an entry.
section="$(awk '/^## Projects[[:space:]]*$/ {inside=1; next} /^## / {inside=0} inside {print}' "$FILE")"
case "$section" in
  *[![:space:]]*) ;;
  *)
    echo "check-project-list: $FILE has no '## Projects' section, so there is no list to check. Refusing rather than reporting one with nothing wrong in it." >&2
    exit 2 ;;
esac

# Every machine the list names, and the entries under this one. Both are collected in a single
# pass: the count of blocks is what tells a section holding no machine at all apart from one that
# simply says nothing about THIS machine, and those are different faults (L11).
blocks=0
mine=""
current=""
while IFS= read -r line; do
  case "$line" in
    "On "*:)
      current="${line#On }"; current="${current%:}"
      blocks=$((blocks + 1))
      continue ;;
  esac
  [ "$current" = "$HOST" ] || continue
  # An entry is a list item whose path is in backticks. Anything else under the heading is prose.
  case "$line" in
    '- `'*) ;;
    *) continue ;;
  esac
  p="${line#- \`}"; p="${p%%\`*}"
  [ -n "$p" ] || continue
  mine="$mine$p
"
done <<EOF
$section
EOF

if [ "$blocks" -eq 0 ]; then
  echo "check-project-list: the '## Projects' section in $FILE names no machine at all, so no entry could be attributed to one. Every entry belongs under an 'On <machine>:' heading." >&2
  exit 2
fi

case "$mine" in
  *[![:space:]]*) ;;
  *)
    echo "check-project-list: no entries for $HOST in $FILE, so nothing was checked. The list names $blocks machine(s), none of them this one."
    exit 0 ;;
esac

missing=""
n=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  n=$((n + 1))
  # Written with a tilde on purpose: a real home directory in a synced file is wrong on every
  # other Mac, and check-home-paths.sh refuses one. So it has to be expanded here.
  case "$p" in
    '~') full="$HOME" ;;
    '~/'*) full="$HOME/${p#\~/}" ;;
    *) full="$p" ;;
  esac
  [ -e "$full" ] || missing="$missing  $p
"
done <<EOF
$mine
EOF

case "$missing" in
  *[![:space:]]*)
    echo "check-project-list: these projects are listed under $HOST but are not on this Mac, so anything reading the list is being sent somewhere that does not exist:" >&2
    printf '%s' "$missing" >&2
    echo "Move the entry under the machine that actually holds it, correct the path, or remove it. The list loads at the start of every session on both Macs, so a wrong entry is read constantly." >&2
    exit 1 ;;
esac

echo "check-project-list: $n project(s) listed under $HOST, all present."
exit 0
