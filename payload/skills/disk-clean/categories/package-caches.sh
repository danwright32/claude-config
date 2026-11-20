#!/usr/bin/env bash
#
# package-caches.sh: disk-clean's npm and pnpm cache category (claude-config#3235). See scan-lib.sh
# for the module calls.
#
# Shows, sized, the package managers' own stores, which sessions fill by installing and by running
# npx. Dan's decisions, recorded on #3235: npx copies are offered (2026-11-18, "Offer npx copies
# only (Recommended)"), and so is one row that runs pnpm's own prune of its store (2026-11-19,
# "Offer a prune row"); every other row says why it is kept, and the judge refuses it.
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
#                           project uses. Shown, never offered.
#   store prune             not a path: the one row that runs `pnpm store prune`, through
#                           disk-remove.sh's pnpm method, as the Docker kind's build cache row runs
#                           Docker's own prune. Listed when a store is there. Offered when pnpm is on
#                           the PATH, pnpm itself says its store is a real folder directly inside
#                           ~/Library/pnpm/store (asked from the home folder, so no project's
#                           settings choose it; a store anywhere else is not this row's to prune),
#                           no running process holds a file in that store, and nothing in it was
#                           changed or opened in 30 days (the floor). It carries no size: what a
#                           prune frees is not known until pnpm has run.
# Measured on the personal MacBook on 2026-11-18: ~/.npm 4,541 MB (the cache 3,567 MB, npx copies
# 974 MB), growing about 47 MB a week; the pnpm store 111 MB, last written 2026-09-16.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

N="$HOME/.npm"
PS="$HOME/Library/pnpm/store"
# The prune row's target, which disk-remove.sh's pnpm method takes and no other, and what its row says.
PRUNE="store prune"
PRUNE_DETAIL="runs pnpm's own pnpm store prune, which removes from pnpm's store what no project uses; how much that frees is not known until it runs"

open_listing() {
  OPEN_WHY=""
  LISTING="$DCS_WORK/pc.open"
  dcs_open_files "$LISTING" || { OPEN_WHY="$DCS_WHY"; : > "$LISTING"; }
}

# Succeeds when ~/Library/pnpm/store holds at least one real folder, which is what a store there is.
store_there() {
  local e
  for e in "$PS"/*; do
    if [ -d "$e" ] && [ ! -L "$e" ]; then return 0; fi
  done
  return 1
}

# Sets V for the prune row; open_listing has run. In order: pnpm has to be there to run; a store has
# to be there to prune; pnpm is asked where its store is, from the home folder, and it has to be a
# real folder directly inside ~/Library/pnpm/store, the place disk-remove.sh's pnpm method holds it
# to (L261); no process may hold a file in it, since an install running now is using it; and the 30
# day floor, on the store pnpm named, which is the one a prune removes from.
prune_rules() {
  local store rc held
  command -v pnpm >/dev/null 2>&1 || { V="not offerable: pnpm is not on the PATH, so its own prune cannot be run"; return; }
  store_there || { V="not offerable: there is no pnpm store in ~/Library/pnpm/store"; return; }
  store="$(CDPATH= cd "$HOME" 2>/dev/null && pnpm store path </dev/null 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { V="unmeasured: pnpm could not say where its store is (pnpm store path exit $rc)"; return; }
  # A trailing slash would have the link test below follow a link rather than see it.
  while :; do case "$store" in ?*/) store="${store%/}" ;; *) break ;; esac; done
  case "$store" in
    /*$'\n'*|[!/]*|'') V="unmeasured: pnpm did not name its store as one absolute path (it said: ${store%%$'\n'*})"; return ;;
  esac
  if [ ! -d "$store" ] || [ -L "$store" ] || ! dcs_parent_is "$store" "$(dcs_phys "$PS" 2>/dev/null)"; then
    V="not offerable: pnpm says its store is $store, which is not a folder directly inside ~/Library/pnpm/store, the only store this prunes"; return
  fi
  if [ -n "${OPEN_WHY:-}" ]; then V="unmeasured: could not tell whether pnpm's store is in use ($OPEN_WHY)"; return; fi
  held="$(dcs_holders "$store" "$LISTING")"
  if [ -n "$held" ]; then V="not offerable: pnpm's store is in use by $held"; return; fi
  V=offerable
  dcs_floor "$store"
}

# Sets V for <target>; open_listing has run. Only an npx copy and the prune row can be offerable.
pc_rules() { # <target>
  local t="${1%/}" held
  case "$t" in
    "$PRUNE") prune_rules ;;
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
  # The prune row, after the sized rows: it has no size of its own to be ordered by. Only where a
  # store is there, so a Mac that never ran pnpm shows no row about it.
  if store_there; then
    pc_rules "$PRUNE"
    dcs_item "$PRUNE" pnpm "" unread "$V" "" "$PRUNE_DETAIL" ""
  fi
  # Said once here rather than on each of a couple of dozen npx rows (L605).
  grep -q "/_npx/" "$DCS_WORK/pc.paths" && dcs_note "Each npx copy is one package npx has run, made again the next time npx runs it."
  return 0
}

case "${1:-}" in
  scan) do_scan ;;
  judge) open_listing; pc_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: package-caches.sh scan | package-caches.sh judge <target>" >&2; exit 2 ;;
esac
