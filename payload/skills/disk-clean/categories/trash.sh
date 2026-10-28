#!/usr/bin/env bash
#
# trash.sh: disk-clean's Trash category (claude-config#1806). See scan-lib.sh for the module calls.
#
# Every entry directly in ~/.Trash is offered, by deleting it, since it is already in the Trash. The
# plan's rules: only entries listed at scan time, by name AND inode, so an entry added or replaced
# since is never removed on the strength of a scan that did not see it; and never anything
# disk-clean itself moved to the Trash during this scan's removals, which the judge finds by its
# inode matching an item the record marks trashed (a move within one volume keeps the inode). The
# skill empties the Trash first, before anything else is trashed, for the same reason.
#
# An unreadable ~/.Trash (macOS asks for Full Disk Access) makes the category unmeasured, never empty.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

TR="$HOME/.Trash"

# Sets V. With <expected identity> empty it is the scan's own view, which has just listed the entry.
trash_rules() { # <target> <judge: 1 or empty>
  local t="${1%/}" judging="$2" ident rec line
  dcs_parent_is "$t" "$DCS_HOME/.Trash" || { V="not offerable: it is not an entry of the Trash"; return; }
  if [ ! -e "$t" ] && [ ! -L "$t" ]; then V="not offerable: it is no longer in the Trash"; return; fi
  [ -n "$judging" ] || { V=offerable; return; }
  ident="$(dcs_identity "$t")"
  [ -n "$ident" ] || { V="unmeasured: its device and inode could not be read"; return; }
  rec="$DCS_RECORD"
  if [ ! -f "$rec" ] || ! dcr_complete "$rec"; then V="not offerable: there is no whole scan record listing what was in the Trash"; return; fi
  line="$(dcr_review_items "$rec" | awk -F "$S" -v i="$ident" '$5 == "trashed" && $7 == i && !f { print $4; f = 1 }')"
  if [ -n "$line" ]; then V="not offerable: disk-clean moved it to the Trash during this scan's removals (it was $line)"; return; fi
  line="$(dcr_review_items "$rec" | awk -F "$S" -v t="$t" '$2 == "trash" && $4 == t && !f { print "x" $7; f = 1 }')"
  if [ -z "$line" ]; then V="not offerable: it was not in the Trash when the scan ran"; return; fi
  if [ "${line#x}" != "$ident" ]; then V="not offerable: it is not the entry the scan listed (device and inode were ${line#x}, now $ident)"; return; fi
  V=offerable
}

do_scan() {
  [ -e "$TR" ] || return 0
  if ! ls -A "$TR" > "$DCS_WORK/trash.names" 2> "$DCS_WORK/trash.err"; then
    dcs_status "unmeasured: the Trash could not be listed ($(awk 'NR == 1' "$DCS_WORK/trash.err")), which macOS allows only with Full Disk Access"
    return 0
  fi
  awk -v d="$TR" 'NF { print d "/" $0 }' "$DCS_WORK/trash.names" > "$DCS_WORK/trash.paths"
  dcs_measure "$DCS_WORK/trash.paths" > "$DCS_WORK/trash.sized"
  local p kib size ident
  while IFS="$S" read -r p kib size ident; do
    trash_rules "$p" ""
    dcs_item "$p" delete "$kib" "$size" "$V" "" "" "$ident"
  done < "$DCS_WORK/trash.sized"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) trash_rules "${2:-}" 1; echo "$V" ;;
  *) echo "usage: trash.sh scan | trash.sh judge <target>" >&2; exit 2 ;;
esac
