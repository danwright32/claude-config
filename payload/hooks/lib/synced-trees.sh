#!/usr/bin/env bash
#
# synced-trees.sh: the trees of a config root that claude-sync mirrors, and the files in them it
# carries (claude-config#2750).
#
# Installed, a suite's own tree is ~/.claude, and that also holds what each Mac keeps for itself and
# the sync never carries: state/ (the session notes, where agents keep their working files and, for
# a before and after measurement, copies of hooks), projects/, plugins/, and under skills/ the Claude
# app's downloads and Claude Code's .trash. On 2026-11-11 two suites that walked that whole tree
# judged such copies as config and failed, so the pull that had just installed the config reported
# it FAILED over files no send will ever publish. A scan of the config reads synced_files instead.
#
# SYNCED_TREES is claude-sync's MIRROR_DIRS plus skills, which it mirrors on a path of its own
# because of the entries lib/unmanaged-skills.sh leaves out. claude-sync keeps its own copy, since
# it runs from a checkout and its fixtures copy it alone with no payload beside it, and
# test-synced-trees.sh fails when the two lists differ.
#
# Not listed: the top level rule files (CLAUDE.md and its imports), which claude-sync derives from
# CLAUDE.md's imports and which no scan reaches by walking a tree. Inside a tree, .git and
# __pycache__ folders are left out, as the sync leaves them out; its per file excludes (a
# *.conflict-* copy, a *.local.json, .claude-plugin/types/) are not applied, because no scan here
# reads files by those names.
#
# Sourced, never executed. Loads lib/unmanaged-skills.sh from beside itself.

_ST_LIB_DIR="${BASH_SOURCE[0]%/*}"; [ "$_ST_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _ST_LIB_DIR=.
. "$_ST_LIB_DIR/unmanaged-skills.sh" || return 1

SYNCED_TREES=(hooks agents commands audits mods skills)

# Every file the sync carries under the trees named (all of SYNCED_TREES when none are), one path
# per line, sorted within each tree. Exit 2 for a root that is not there or a tree the sync does not
# mirror, which is refused rather than read, so no caller can widen a scan back into state/ by
# naming it; exit 1 when the root holds none of the trees asked for, or a walk fails, since an empty
# list there would read as a clean tree rather than an unread one (L98).
synced_files(){   # $1 = a config root (~/.claude, or a checkout's payload)  $2.. = only these trees
  local root="${1%/}" t found=0 listed
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "synced_files: no config root at '${1:-}', so there is nothing to list." >&2
    return 2
  fi
  shift
  [ "$#" -gt 0 ] || set -- "${SYNCED_TREES[@]}"
  for t in "$@"; do
    case " ${SYNCED_TREES[*]} " in
      *" $t "*) ;;
      *) echo "synced_files: '$t' is not a tree the sync mirrors (${SYNCED_TREES[*]}), so it is not listed." >&2; return 2 ;;
    esac
  done
  for t in "$@"; do
    [ -d "$root/$t" ] || continue
    found=1
    listed="$(find "$root/$t" \( -name .git -o -name __pycache__ \) -prune -o -type f -print)" || {
      echo "synced_files: could not walk $root/$t." >&2; return 1; }
    listed="$(printf '%s\n' "$listed" | sort)"
    if [ "$t" = skills ]; then
      listed="$(printf '%s\n' "$listed" | carried_skill_paths "$root/skills")" || return 1
    fi
    [ -z "$listed" ] || printf '%s\n' "$listed"
  done
  if [ "$found" -eq 0 ]; then
    echo "synced_files: $root holds none of $*, so it is not a config root and nothing was listed." >&2
    return 1
  fi
  return 0
}
