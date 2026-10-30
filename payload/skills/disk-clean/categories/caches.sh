#!/usr/bin/env bash
#
# caches.sh: disk-clean's app caches category (claude-config#1806). See scan-lib.sh for the module calls.
#
# Every entry directly in ~/Library/Caches, offered by deleting it, since apps rebuild their caches.
# IN USE is judged by any running process holding a file at or beneath the folder, read from one lsof
# listing of every open file, and NEVER by the folder's name: the plan on #1804 records that 96% of
# cache bytes sat in folders not named by any bundle id, so a name match would have called most of
# them idle. When lsof says anything on stderr, in use is unknown, never free
# (L42). CloudKit, com.apple.bird and com.apple.nsurlsessiond (iCloud and the system download
# service) are listed and never offered. ms-playwright belongs to the Playwright category.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

C="$HOME/Library/Caches"

# Sets V for <target>, given the open file listing <listing> or, when that failed, OPEN_WHY.
cache_rules() { # <target> <listing>
  local t="${1%/}" held
  dcs_parent_is "$t" "$DCS_HOME/Library/Caches" || { V="not offerable: it is not a folder directly inside ~/Library/Caches"; return; }
  case "${t##*/}" in
    CloudKit|com.apple.bird|com.apple.nsurlsessiond) V="not offerable: macOS's iCloud and download services keep it, so it is never offered"; return ;;
    ms-playwright) V="not offerable: it is Playwright's browser store, which the Playwright category judges"; return ;;
  esac
  if [ ! -e "$t" ]; then V="not offerable: it is no longer there"; return; fi
  if [ -n "${OPEN_WHY:-}" ]; then V="unmeasured: could not tell whether it is in use ($OPEN_WHY)"; return; fi
  held="$(dcs_holders "$t" "$2")"
  if [ -n "$held" ]; then V="not offerable: in use by $held"; return; fi
  V=offerable
}

open_listing() {
  OPEN_WHY=""
  LISTING="$DCS_WORK/caches.open"
  dcs_open_files "$LISTING" || { OPEN_WHY="$DCS_WHY"; : > "$LISTING"; }
}

do_scan() {
  [ -e "$C" ] || return 0
  if ! ls -A "$C" > "$DCS_WORK/caches.names" 2> "$DCS_WORK/caches.err"; then
    dcs_status "unmeasured: ~/Library/Caches could not be listed ($(awk 'NR == 1' "$DCS_WORK/caches.err"))"
    return 0
  fi
  awk -v d="$C" 'NF && $0 != "ms-playwright" { print d "/" $0 }' "$DCS_WORK/caches.names" > "$DCS_WORK/caches.paths"
  open_listing
  dcs_measure "$DCS_WORK/caches.paths" > "$DCS_WORK/caches.sized"
  local p kib size ident
  while IFS="$S" read -r p kib size ident; do
    cache_rules "$p" "$LISTING"
    dcs_item "$p" delete "$kib" "$size" "$V" "" "" "$ident"
  done < "$DCS_WORK/caches.sized"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) open_listing; cache_rules "${2:-}" "$LISTING"; echo "$V" ;;
  *) echo "usage: caches.sh scan | caches.sh judge <target>" >&2; exit 2 ;;
esac
