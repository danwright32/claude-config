#!/usr/bin/env bash
#
# claude-versions.sh: disk-clean's old Claude Code versions category (claude-config#3235). See
# scan-lib.sh for the module calls.
#
# Claude Code's installer keeps each version as one file, ~/.local/share/claude/versions/<version>
# (about 340 MB each), and points the claude command, ~/.local/bin/claude, at the current one. Its
# updater keeps the last three by itself (measured on the personal MacBook on 2026-11-18: three, made
# 2026-11-13 to 11-17). Offered, by deleting it, since the installer fetches any version again: an
# entry that is not the one the claude command points at, that no running process holds (a session
# started before an update goes on running the version it started with, and lsof lists that file),
# and that was not run or changed in the last 30 days (the floor every kind keeps; running a program
# moves its access time). Unmeasured when the claude command cannot be read, since then which version
# is current is not known, and when lsof cannot say what is running. A link among the versions is
# never listed.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

VD="$HOME/.local/share/claude/versions"
LAUNCHER="$HOME/.local/bin/claude"

# Sets CUR to the physical path the claude command points at, or CUR_WHY to why it is not known.
read_current() {
  local to
  CUR=""; CUR_WHY=""
  if [ ! -L "$LAUNCHER" ]; then CUR_WHY="the claude command ($LAUNCHER) is not a link to a version, so which version is current is not known"; return; fi
  to="$(readlink "$LAUNCHER" 2>/dev/null)" || to=""
  [ -n "$to" ] || { CUR_WHY="the claude command ($LAUNCHER) could not be read, so which version is current is not known"; return; }
  case "$to" in /*) ;; *) to="${LAUNCHER%/*}/$to" ;; esac
  CUR="$(dcs_phys "$to")" || CUR=""
  [ -n "$CUR" ] || CUR_WHY="the version the claude command points at ($to) could not be found, so which version is current is not known"
}

open_listing() {
  OPEN_WHY=""
  LISTING="$DCS_WORK/cv.open"
  dcs_open_files "$LISTING" || { OPEN_WHY="$DCS_WHY"; : > "$LISTING"; }
}

# Sets V for <target>; read_current and open_listing have run.
cv_rules() { # <target>
  local t="${1%/}" phys held
  dcs_parent_is "$t" "$(dcs_phys "$VD" 2>/dev/null)" || { V="not offerable: it is not a Claude Code version (an entry directly in ~/.local/share/claude/versions)"; return; }
  [ -e "$t" ] && [ ! -L "$t" ] || { V="not offerable: it is no longer there, or is a link"; return; }
  if [ -n "$CUR_WHY" ]; then V="unmeasured: $CUR_WHY"; return; fi
  phys="$(dcs_phys "$t")" || phys=""
  if [ "$phys" = "$CUR" ]; then V="not offerable: it is the version the claude command starts"; return; fi
  if [ -n "$OPEN_WHY" ]; then V="unmeasured: could not tell whether it is running ($OPEN_WHY)"; return; fi
  held="$(dcs_holders "$phys" "$LISTING")"
  [ -n "$held" ] || held="$(dcs_holders "$t" "$LISTING")"
  if [ -n "$held" ]; then V="not offerable: in use by $held"; return; fi
  V=offerable
  dcs_floor "$t"
}

do_scan() {
  [ -d "$VD" ] || return 0
  read_current
  [ -n "$CUR_WHY" ] && dcs_status "unmeasured: $CUR_WHY"
  open_listing
  local e
  : > "$DCS_WORK/cv.paths"
  for e in "$VD"/*; do
    [ -e "$e" ] && [ ! -L "$e" ] || continue
    printf '%s\n' "$e" >> "$DCS_WORK/cv.paths"
  done
  dcs_measure "$DCS_WORK/cv.paths" > "$DCS_WORK/cv.sized"
  local p kib size ident
  while IFS="$S" read -r p kib size ident; do
    cv_rules "$p"
    dcs_item "$p" delete "$kib" "$size" "$V" "" "" "$ident"
  done < "$DCS_WORK/cv.sized"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) read_current; open_listing; cv_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: claude-versions.sh scan | claude-versions.sh judge <target>" >&2; exit 2 ;;
esac
