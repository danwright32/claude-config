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
# It also checks that each listed project carries its OWN instructions file (claude-config#469).
# Claude Code looks for one starting at the project directory and walking UP, so a project without
# one is not merely uninformed: it is handed whatever file happens to sit above it. On 2026-09-19
# that was a Vercel best practices AGENTS.md in the home directory, loaded as "project
# instructions" into a Swift app, an iOS app and a bash tool, none of which has ever touched
# Vercel. The synced CLAUDE.md asserted that every listed project had its own file, and six of them
# never had. A claim in a file that loads into every session is believed without re-checking
# (L244), so it is checked here rather than asserted there.
#
# CLAUDE.md or AGENTS.md, because that is the predicate Claude Code itself uses when it decides
# what to load, and a guard must ask the question the thing it guards asks (L144). NurseDex carries
# an AGENTS.md and no CLAUDE.md and is correctly provided for.
#
# Run:  bash ~/.claude/hooks/check-project-list.sh
#
# Exit 0 = every path listed for this machine is there and each one carries its own instructions
#          file, or the list names no block for this machine at all, which is said out loud rather
#          than passed over.
# Exit 1 = at least one listed path is missing.
# Exit 2 = the file, the section, or the machine blocks are absent, so nothing could be checked.
#          Refusing rather than passing, because reading nothing and finding nothing wrong are
#          indistinguishable otherwise (L98).
# Exit 3 = every listed path is there, but at least one of those projects carries neither a
#          CLAUDE.md nor an AGENTS.md of its own, on this branch or on the default one. A separate
#          code because it is a separate fault with a separate remedy (L11): the entry is right and
#          the repository is not provided for. A missing path outranks it, because what a directory
#          contains is not a question worth answering when the directory is not there.
# Exit 5 = a listed project has no instructions file in its WORKING TREE, but its repository's
#          default branch has one, so this checkout is standing on a branch created before the file
#          landed (claude-config#495). Its own code and its own sentence, because the remedy is to
#          merge and the exit 3 sentence sends the reader to write a file that already exists, which
#          is an instruction that cannot change the state they are stuck in (L111). Measured on
#          2026-09-19: PostRoll was reported bare while its CLAUDE.md sat on origin/main.
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

# A project whose working tree carries no instructions file may still have one on the branch the
# repository actually develops on, which is the common case on a Mac where sessions work in feature
# branches. That is a different fault from a project that has never had a file, and it has a
# different remedy, so it is asked here rather than assumed either way.
#
# Two routes to the default branch, because a repository may have a remote or not, and the real
# case uses the first: refs/remotes/origin/HEAD when there is an origin, and a local main or master
# when there is not. Nothing here touches the network: symbolic-ref, rev-parse and cat-file all read
# what is already on disk, so a project with no connectivity answers as fast as one with it.
#
# It runs only for a project already found to be bare, so the ordinary healthy run pays nothing.
# Every git call is guarded: a directory that is not a repository at all answers nothing, which
# leaves the plain bare case, and that is the answer for a checkout with no default branch too.
instructions_on_default_branch() { # <dir> -> a sentence naming both branches, or nothing
  local d="$1" default="" here="" cand="" f=""
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || return 0
  default="$(git -C "$d" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -z "$default" ]; then
    for cand in origin/main origin/master main master; do
      if git -C "$d" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then default="$cand"; break; fi
    done
  fi
  [ -n "$default" ] || return 0
  for f in CLAUDE.md AGENTS.md; do
    if git -C "$d" cat-file -e "$default:$f" 2>/dev/null; then
      here="$(git -C "$d" branch --show-current 2>/dev/null)"
      [ -n "$here" ] || here="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      [ -n "$here" ] || here="a detached HEAD"
      printf '%s is on %s, this checkout is on %s' "$f" "$default" "$here"
      return 0
    fi
  done
  return 0
}

missing=""
bare=""
predates=""
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
  if [ ! -e "$full" ]; then
    missing="$missing  $p
"
  elif [ ! -f "$full/CLAUDE.md" ] && [ ! -f "$full/AGENTS.md" ]; then
    elsewhere="$(instructions_on_default_branch "$full")"
    if [ -n "$elsewhere" ]; then
      predates="$predates  $p ($elsewhere)
"
    else
      bare="$bare  $p
"
    fi
  fi
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

case "$bare" in
  *[![:space:]]*)
    echo "check-project-list: these projects are listed under $HOST but carry neither a CLAUDE.md nor an AGENTS.md of their own, so a session started in one of them is handed whatever instructions sit ABOVE it instead:" >&2
    printf '%s' "$bare" >&2
    echo "Claude Code looks for a project's instructions by walking UP from the directory it starts in, so the fallback is silent and can be another project's file entirely. Write one at the root of each, or take the entry out of the list." >&2
    exit 3 ;;
esac

case "$predates" in
  *[![:space:]]*)
    echo "check-project-list: these projects have no instructions file in their working tree, but their repository's default branch has one, so this checkout is standing on a branch created before the file landed:" >&2
    printf '%s' "$predates" >&2
    echo "Merge that branch in, or switch to it. This is said separately from a project that has no file anywhere because writing one here would add a second copy of a file that already exists." >&2
    exit 5 ;;
esac

echo "check-project-list: $n project(s) listed under $HOST, all present, each carrying its own instructions file."
exit 0
