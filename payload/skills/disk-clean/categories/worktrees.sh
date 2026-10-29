#!/usr/bin/env bash
#
# worktrees.sh: disk-clean's git worktree category (claude-config#1806). See scan-lib.sh for the
# module calls.
#
# From the walk: every .git FILE naming a folder under some repository's .git/worktrees (a
# submodule's .git file names .git/modules and is not one). A .git file iCloud keeps only in the
# cloud is never read, since reading it makes iCloud fetch it: its folder is listed as unmeasured. Offered, through `git worktree remove`
# without --force (disk-remove.sh's worktree method), only when ALL of these hold, checked in order:
#   no Claude Code session's working folder is in it (the live session map)
#   `git status --porcelain --untracked-files=all` is empty, untracked files included
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
# owner/name of a GitHub remote URL; fails for anything else.
github_repo() { # <url>
  local u="$1"
  case "$u" in
    https://github.com/*) u="${u#https://github.com/}" ;;
    git@github.com:*) u="${u#git@github.com:}" ;;
    ssh://git@github.com/*) u="${u#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
  u="${u%.git}"; u="${u%/}"
  case "$u" in */*/*|/*|*/|'') return 1 ;; */*) printf '%s\n' "$u" ;; *) return 1 ;; esac
}
# Sets V and D for <worktree>.
wt_rules() { # <worktree>
  local t="${1%/}" cwd st br head url repo out err="$DCS_WORK/wt.err.$$" n oid
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
  st="$(git -C "$t" status --porcelain --untracked-files=all 2> "$err" </dev/null)" || { V="unmeasured: git status failed ($(awk 'NR == 1' "$err"))"; rm -f "$err"; return; }
  [ -z "$st" ] || { V="not offerable: it has uncommitted or untracked files"; rm -f "$err"; return; }
  br="$(git -C "$t" symbolic-ref --short -q HEAD 2>/dev/null </dev/null)"
  [ -n "$br" ] || { V="not offerable: it is on no branch, so no pull request can be matched to it"; rm -f "$err"; return; }
  head="$(git -C "$t" rev-parse HEAD 2> "$err" </dev/null)" || { V="unmeasured: git rev-parse failed ($(awk 'NR == 1' "$err"))"; rm -f "$err"; return; }
  url="$(git -C "$t" remote get-url origin 2>/dev/null </dev/null)" || { V="not offerable: it has no origin remote, so no pull request can say it merged"; rm -f "$err"; return; }
  repo="$(github_repo "$url")" || { V="not offerable: its repository is not on GitHub ($url), so no pull request can say it merged"; rm -f "$err"; return; }
  out="$(gh pr list --repo "$repo" --head "$br" --state merged --json number,headRefOid --jq '.[] | "\(.number) \(.headRefOid)"' 2> "$err" </dev/null)" || {
    V="unmeasured: gh could not say whether its pull request merged ($(awk 'NR == 1' "$err"))"; rm -f "$err"; return; }
  rm -f "$err"
  [ -n "$out" ] || { V="not offerable: no merged pull request for its branch $br"; return; }
  while read -r n oid; do
    [ "$oid" = "$head" ] && { V=offerable; D="branch $br, merged in pull request #$n at its HEAD"; return; }
  done <<< "$out"
  V="not offerable: it has commits its merged pull request #$(printf '%s\n' "$out" | awk 'NR == 1 { print $1 }') does not"
}

do_scan() {
  dcs_walk_ready
  read_map
  local g
  : > "$DCS_WORK/wt.paths"
  while IFS= read -r g; do
    case "$g" in */.git) ;; *) continue ;; esac
    [ -f "$g" ] || continue
    # A .git file kept only in iCloud cannot be read to tell, so the folder is listed for wt_rules
    # to call unmeasured rather than left out without a word (L10, L11).
    if dcs_dataless "$g" || is_worktree "${g%/.git}"; then printf '%s\n' "${g%/.git}" >> "$DCS_WORK/wt.paths"; fi
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
