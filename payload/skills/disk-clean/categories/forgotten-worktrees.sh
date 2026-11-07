#!/usr/bin/env bash
#
# forgotten-worktrees.sh: disk-clean's kind for worktree folders whose repository is gone
# (claude-config#2346). See scan-lib.sh for the module calls.
#
# From the walk: every .git FILE naming a gitdir inside a "worktrees" folder that no longer exists.
# No repository lists such a folder, so `git worktree remove` cannot reach it, and the stale worktree
# sweep (hooks/check-stale-worktrees.sh) deliberately skips anything git has forgotten. On 2026-11-06
# the personal MacBook held three in its home folder, about 368 MB, from a checkout deleted in
# September. It is offered, moved to the Trash and never deleted, only when Dan ticks it, because a
# folder git has forgotten can still hold uncommitted work and nothing can check it against a branch.
#
# A folder is LEFT ALONE, never judged, when (checked in this order):
#   it is in a synced folder (dcs_synced: iCloud Drive, Desktop or Documents when iCloud syncs them,
#   any ~/Library/CloudStorage mount, a sync client's folder), or its .git file is kept only in iCloud
#   its gitdir is outside this Mac's own home folder: the same day, an iCloud copy of the work
#   MacBook's Documents held 85 worktree records whose links all named the work MacBook's home
#   folder, so from here every one looked gone, and moving one to the Trash would have synced the
#   removal back to the Mac where it may be in use
#   its gitdir is in a synced folder, where a missing folder may only not have synced yet
# Those are counted in the kind's note rather than listed. Otherwise, when its gitdir is gone, it is
# listed, with its size and the date anything in it last changed, and offered when:
#   no Claude Code session's working folder is in it (the live session map)
#   nothing in it was changed or opened in 30 days (the floor every kind keeps, #2134)
# A gitdir whose nearest folder that exists cannot be looked inside is unmeasured, never gone (L11).
# A folder holding a file whose name says it holds secrets is flagged. git is never run here.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

IDS="$DCS_WORK/fw.ids"; CWDS="$DCS_WORK/fw.cwds"

read_map() { MAP_WHY=""; dcs_sessions "$IDS" "$CWDS" || MAP_WHY="the session map could not be read ($DCS_WHY)"; }

# <path> written from the home folder as ~.
tilde() { # <path>
  case "$1" in
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    "$DCS_HOME"/*) printf '~/%s\n' "${1#"$DCS_HOME"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
# The newest modification time at or beneath <dir>, in epoch seconds; nothing when none was read.
# It never lists a folder iCloud keeps only in the cloud, since that makes iCloud fetch it.
newest_change() { # <dir>
  if stat -c '%Y' / >/dev/null 2>&1; then
    find "$1" -type d \( "${DCS_DL[@]}" \) -prune -o -exec stat -c '%Y' {} + 2>/dev/null
  else
    find "$1" -type d \( "${DCS_DL[@]}" \) -prune -o -exec stat -f '%m' {} + 2>/dev/null
  fi | awk '$1 ~ /^[0-9]+$/ && $1 + 0 > m + 0 { m = $1 } END { if (m != "") print m }'
}

# Sorts <dir> into FW: "alone" (left alone, never judged), "mine" (a forgotten worktree of this
# Mac's, for fw_rules to judge) or empty (not this kind's). Sets V to why when it is not "mine", and
# G to its gitdir when that was read.
fw_class() { # <dir>
  local t="${1%/}" pt a
  FW=""; G=""
  [ -d "$t" ] && [ ! -L "$t" ] || { V="not offerable: it is no longer there"; return; }
  pt="$(dcs_phys "$t" 2>/dev/null)" || pt="$t"
  if dcs_synced "$t" || dcs_synced "$pt"; then
    V="not offerable: it is in $DCS_WHY, where moving it to the Trash would remove it on every device that syncs it"
    # Only a worktree's .git file is counted, read only when it is on this Mac, never fetched.
    if [ -f "$t/.git" ] && { dcs_dataless "$t/.git" || dcs_gitdir "$t" >/dev/null; }; then FW=alone; fi
    return
  fi
  if [ -f "$t/.git" ] && dcs_dataless "$t/.git"; then
    FW=alone; V="not offerable: its .git file is kept only in iCloud, so where its repository is cannot be read without downloading it"; return
  fi
  G="$(dcs_gitdir "$t")" || { G=""; V="not offerable: it is not a git worktree"; return; }
  case "$G/" in
    "$HOME"/*|"$DCS_HOME"/*) ;;
    *)
      [ ! -e "$G" ] || { V="not offerable: its repository still has it, so it is judged under $(dcr_title worktrees)"; return; }
      FW=alone; V="not offerable: its repository is recorded at $G, outside this Mac's home folder, so whether it is gone cannot be told from this Mac"; return ;;
  esac
  if dcs_synced "$G"; then
    FW=alone; V="not offerable: its repository is recorded in $DCS_WHY, where a missing folder may only not have synced yet"; return
  fi
  [ ! -e "$G" ] || { V="not offerable: its repository still has it, so it is judged under $(dcr_title worktrees)"; return; }
  # Gone only when the nearest folder that exists could be looked inside (L11).
  a="${G%/*}"
  while [ -n "$a" ] && [ ! -e "$a" ]; do a="${a%/*}"; done
  if [ -n "$a" ] && [ -d "$a" ] && [ ! -x "$a" ]; then
    FW=mine; V="unmeasured: $(tilde "$a") could not be looked inside, so whether its repository still has it is not known"; return
  fi
  FW=mine; V=""
}

# Sets V and D for <dir>.
fw_rules() { # <dir>
  local t="${1%/}" cwd repo m
  D=""
  fw_class "$t"
  [ "$FW" = mine ] && [ -z "$V" ] || return
  [ -z "$MAP_WHY" ] || { V="unmeasured: $MAP_WHY"; return; }
  while IFS= read -r cwd; do
    [ -n "$cwd" ] || continue
    case "$cwd" in "$t"|"$t"/*) V="not offerable: a session is working in it ($cwd)"; return ;; esac
  done < "$CWDS"
  repo="${G%/worktrees/*}"
  if [ -e "$repo" ]; then D="its repository $(tilde "${repo%/.git}") no longer lists it"
  else D="its repository $(tilde "${repo%/.git}") is gone"; fi
  m="$(newest_change "$t")"
  if [ -n "$m" ]; then D="$D; last changed $(dcs_date "$m")"; else D="$D; when it last changed could not be read"; fi
  # The floor's find never reads files, but this module reads the .git file, so only its change time
  # counts (as for the Finished worktrees kind).
  V=offerable
  dcs_floor "$t" .git
}

do_scan() {
  dcs_walk_ready
  read_map
  local g alone=0
  : > "$DCS_WORK/fw.paths"
  while IFS= read -r g; do
    case "$g" in */.git) ;; *) continue ;; esac
    [ -f "$g" ] || continue
    fw_class "${g%/.git}"
    case "$FW" in
      alone) alone=$((alone + 1)) ;;
      mine) printf '%s\n' "${g%/.git}" >> "$DCS_WORK/fw.paths" ;;
    esac
  done < "$DCS_WALK"
  [ "$alone" -eq 0 ] || dcs_note "$alone worktree folder(s) were left alone without being judged: each is in a synced folder, or its repository is recorded outside this Mac's home folder or in a synced folder, so from this Mac it can look gone when it is not, and moving it to the Trash could remove it on another Mac too."
  dcs_measure "$DCS_WORK/fw.paths" > "$DCS_WORK/fw.sized"
  local p kib size ident flags cred
  while IFS="$S" read -r p kib size ident; do
    fw_rules "$p"
    flags=""; cred="$(dcs_credential "$p")"
    [ -n "$cred" ] && { flags=credential; D="${D:+$D; }holds ${cred#"$p"/}"; }
    dcs_item "$p" trash "$kib" "$size" "$V" "$flags" "$D" "$ident"
  done < "$DCS_WORK/fw.sized"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) read_map; fw_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: forgotten-worktrees.sh scan | forgotten-worktrees.sh judge <target>" >&2; exit 2 ;;
esac
