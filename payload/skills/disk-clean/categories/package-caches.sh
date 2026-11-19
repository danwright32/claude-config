#!/usr/bin/env bash
#
# package-caches.sh: disk-clean's npm and pnpm cache category (claude-config#3235). See scan-lib.sh
# for the module calls.
#
# Shows, sized, the package managers' own stores, which sessions fill by installing and by running
# npx. Dan's decision on 2026-11-18 ("Offer npx copies only (Recommended)", #3235): only npx copies
# are offered; every other row says why it is kept, and the judge refuses it.
#   ~/.npm/_cacache         npm's download cache. It refills, but it is shared with every build Dan
#                           runs himself, so it is only partly Claude's: shown, never offered.
#                           npm's own `npm cache clean --force` empties it.
#   ~/.npm/_npx/<hash>      one folder per package npx has run, made again on the next npx run of
#                           it. Offered, by deleting it, unless a running process holds a file in it
#                           (one lsof listing, as caches.sh reads it; unmeasured when lsof cannot
#                           say) or it was run or changed in the last 30 days (the floor). A link is
#                           never listed. build-folders.sh never offers the node_modules inside one.
#   ~/.npm/_logs            npm's own logs, which npm itself keeps to its last ten
#   ~/Library/pnpm/store/<version>  pnpm's store. On APFS pnpm copies a package into a project as a
#                           clone that shares disk blocks with the store, so removing the store can
#                           free far less than its size; `pnpm store prune` removes only what no
#                           project uses.
# Measured on the personal MacBook on 2026-11-18: ~/.npm 4,541 MB (the cache 3,567 MB, npx copies
# 974 MB), growing about 47 MB a week; the pnpm store 111 MB, last written 2026-09-16.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

N="$HOME/.npm"
PS="$HOME/Library/pnpm/store"

open_listing() {
  OPEN_WHY=""
  LISTING="$DCS_WORK/pc.open"
  dcs_open_files "$LISTING" || { OPEN_WHY="$DCS_WHY"; : > "$LISTING"; }
}

# Sets V for <target>; open_listing has run. Only an npx copy can be offerable.
pc_rules() { # <target>
  local t="${1%/}" held
  case "$t" in
    "$N/_npx/"*/*) V="not offerable: it is not one of the caches this kind shows" ;;
    "$N/_npx/"?*)
      dcs_parent_is "$t" "$(dcs_phys "$N/_npx" 2>/dev/null)" || { V="not offerable: it is not one of the caches this kind shows"; return; }
      [ -d "$t" ] && [ ! -L "$t" ] || { V="not offerable: it is no longer there, or is a link"; return; }
      if [ -n "${OPEN_WHY:-}" ]; then V="unmeasured: could not tell whether it is in use ($OPEN_WHY)"; return; fi
      held="$(dcs_holders "$t" "$LISTING")"
      if [ -n "$held" ]; then V="not offerable: in use by $held"; return; fi
      V=offerable
      dcs_floor "$t" ;;
    "$N/_cacache") V="not offerable: npm's download cache, shared with builds you run yourself, so only part of it is Claude Code's, and it is kept by your decision" ;;
    "$N/_logs") V="not offerable: npm's own logs, which npm keeps to its last ten itself" ;;
    "$PS/"*/*) V="not offerable: it is not one of the caches this kind shows" ;;
    "$PS/"?*) V="not offerable: pnpm's store, whose packages projects hold as clones sharing its disk blocks, so removing it can free far less than its size; pnpm store prune removes only what no project uses" ;;
    *) V="not offerable: it is not one of the caches this kind shows" ;;
  esac
}

do_scan() {
  local e
  : > "$DCS_WORK/pc.paths"
  [ -d "$N/_cacache" ] && printf '%s\n' "$N/_cacache" >> "$DCS_WORK/pc.paths"
  for e in "$N/_npx"/* "$PS"/*; do
    [ -d "$e" ] && [ ! -L "$e" ] && printf '%s\n' "$e" >> "$DCS_WORK/pc.paths"
  done
  [ -d "$N/_logs" ] && printf '%s\n' "$N/_logs" >> "$DCS_WORK/pc.paths"
  open_listing
  dcs_measure "$DCS_WORK/pc.paths" | sort -t "$S" -k2,2nr > "$DCS_WORK/pc.sized" # largest first (L609)
  local p kib size ident
  while IFS="$S" read -r p kib size ident; do
    pc_rules "$p"
    dcs_item "$p" delete "$kib" "$size" "$V" "" "" "$ident"
  done < "$DCS_WORK/pc.sized"
  # Said once here rather than on each of a couple of dozen npx rows (L605).
  grep -q "/_npx/" "$DCS_WORK/pc.paths" && dcs_note "Each npx copy is one package npx has run, made again the next time npx runs it."
  return 0
}

case "${1:-}" in
  scan) do_scan ;;
  judge) open_listing; pc_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: package-caches.sh scan | package-caches.sh judge <target>" >&2; exit 2 ;;
esac
