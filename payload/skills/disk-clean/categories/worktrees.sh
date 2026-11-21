#!/usr/bin/env bash
#
# worktrees.sh: disk-clean's git worktree category (claude-config#1806). See scan-lib.sh for the
# module calls.
#
# From the walk: every .git FILE naming a folder under some repository's .git/worktrees (a
# submodule's .git file names .git/modules and is not one), apart from one whose gitdir is gone, which
# no repository lists and forgotten-worktrees.sh lists or leaves alone instead (#2346). A .git file iCloud keeps only in the
# cloud is never read, since reading it makes iCloud fetch it: its folder is listed as unmeasured. Offered, through `git worktree remove`
# without --force (disk-remove.sh's worktree method), only when ALL of these hold, checked in order:
#   no Claude Code session's working folder is in it (the live session map)
#   nothing in it was changed or opened in 30 days (the floor every kind keeps, #2134)
#   `git --no-optional-locks status --porcelain --untracked-files=all` is empty, untracked files included
#   it is on a branch, and gh finds a MERGED pull request for that branch whose head is exactly the
#   worktree's HEAD, so nothing in it is unpushed or unmerged. Asked of gh because squash merges
#   leave no merged branch git could see locally (L642)
# Any git or gh failure is unmeasured, never merged. A worktree holding a file whose name says it
# holds secrets (.env and the like, which git ignores and so never blocks the removal) is flagged.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

IDS="$DCS_WORK/wt.ids"; CWDS="$DCS_WORK/wt.cwds"

read_map() { MAP_WHY=""; dcs_sessions "$IDS" "$CWDS" || MAP_WHY="the session map could not be read ($DCS_WHY)"; }

# Succeeds when <dir> holds a .git file pointing into a repository's .git/worktrees.
is_worktree() { # <dir>
  local g="$1/.git" line
  [ -f "$g" ] && [ -r "$g" ] || return 1
  line="$(awk 'NR == 1' "$g")"
  case "$line" in "gitdir: "*/.git/worktrees/?*) return 0 ;; esac
  return 1
}
# Sets V and D for <worktree>.
wt_rules() { # <worktree>
  local t="${1%/}" cwd
  D=""
  # Reading a .git file iCloud keeps only in the cloud makes iCloud fetch it, and so would git.
  if [ -f "$t/.git" ] && dcs_dataless "$t/.git"; then
    V="unmeasured: its .git file is kept only in iCloud, so whether it is a git worktree is not known without downloading it"; return
  fi
  is_worktree "$t" || { V="not offerable: it is not a git worktree"; return; }
  [ -z "$MAP_WHY" ] || { V="unmeasured: $MAP_WHY"; return; }
  while IFS= read -r cwd; do
    [ -n "$cwd" ] || continue
    case "$cwd" in "$t"|"$t"/*) V="not offerable: a session is working in it ($cwd)"; return ;; esac
  done < "$CWDS"
  # The 30 day floor runs before git does, since git status reads files and so moves their access
  # times. The .git file and the ignore and attribute files are read by is_worktree above and by git
  # on every look, so only their change times count.
  V=offerable
  dcs_floor "$t" .git .gitignore .gitattributes
  [ "$V" = offerable ] || return
  # Clean, on a branch, and merged by gh at exactly its HEAD: the one test in scan-lib.sh, which
  # the git checkouts in session notes are held to as well.
  dcs_git_merged "$t"
}

do_scan() {
  dcs_walk_ready
  read_map
  local g gd
  : > "$DCS_WORK/wt.paths"
  while IFS= read -r g; do
    case "$g" in */.git) ;; *) continue ;; esac
    [ -f "$g" ] || continue
    # A .git file kept only in iCloud cannot be read to tell, so the folder is listed for wt_rules
    # to call unmeasured rather than left out without a word (L10, L11).
    if dcs_dataless "$g"; then printf '%s\n' "${g%/.git}" >> "$DCS_WORK/wt.paths"; continue; fi
    is_worktree "${g%/.git}" || continue
    # One whose gitdir is gone no repository lists, so git cannot remove it: it is the forgotten
    # worktrees kind's, which lists it or counts it as left alone (#2346), never both kinds.
    gd="$(dcs_gitdir "${g%/.git}")" && [ ! -e "$gd" ] && continue
    printf '%s\n' "${g%/.git}" >> "$DCS_WORK/wt.paths"
  done < "$DCS_WALK"
  dcs_measure "$DCS_WORK/wt.paths" > "$DCS_WORK/wt.sized"
  local p kib size ident flags cred
  while IFS="$S" read -r p kib size ident; do
    wt_rules "$p"
    flags=""; cred="$(dcs_credential "$p")"
    [ -n "$cred" ] && { flags=credential; D="${D:+$D; }holds ${cred#"$p"/}"; }
    dcs_icloud "$p" && flags="$(dcs_join "$flags" icloud)"
    dcs_item "$p" worktree "$kib" "$size" "$V" "$flags" "$D" "$ident"
  done < "$DCS_WORK/wt.sized"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) read_map; wt_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: worktrees.sh scan | worktrees.sh judge <target>" >&2; exit 2 ;;
esac
