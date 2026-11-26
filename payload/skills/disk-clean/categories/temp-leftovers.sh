#!/usr/bin/env bash
#
# temp-leftovers.sh: disk-clean's leftovers in the user temp folder (claude-config#3235). See
# scan-lib.sh for the module calls.
#
# What test runs, gates and tools leave in the user temp folder ($TMPDIR, /var/folders/.../T) under
# names of their own: pytest-of-<user>, pkg-<hash>, the tmp.<random> folders mktemp makes, browser
# profiles, a gate's cache. Measured on the personal MacBook: about 530 MB on 2026-11-23, and 883 MB
# in 2,922 entries on 2026-11-26, two days after a restart; no kind sized it, and only a restart
# empties it. Never this kind's: macOS's own entries (com.apple.* and TemporaryItems, where the
# system's file provider kept 7.8 GB), which are left out and not counted; the entries named for
# Claude Code or this config (claude*, .claude*), which the claude-user-temp kind counts; and
# claude-<uid>, Claude Code's own folder when TMPDIR holds it, which is the claude-temp kind's.
#
# Offered, by deleting it, since the folder is scratch that a restart empties anyway: an entry
# directly in the folder that is not a link, that no running process holds a file at or beneath
# (one lsof listing, as the caches kind reads it; anything lsof says on stderr makes in use unknown,
# never free, L42), and in which nothing was changed or opened in 30 days (the floor every kind
# keeps, #2134). Nothing records which run made an entry or whether that run is over, so the floor
# and the open file test are the whole rule, and a long running test that holds no file open but
# touched its folder within 30 days is kept by the floor.
#
# Rows: each entry of 1 MB or more, largest first, and each whose size could not be read, since it
# may be the large one. On 2026-11-26 that was 22 of the 2,922; the rest, 641 tmp.* folders among
# them, are counted with their size in the kind's note rather than as rows that would bury the page
# (L605).
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

ROW_KIB=1024 # an entry this size or more is a row; smaller ones are counted in the note

# Succeeds when <name> is never this kind's, setting WHY to the reason.
tl_not_ours() { # <name>
  case "$1" in
    com.apple.*|TemporaryItems) WHY="macOS keeps it, so it is never offered"; return 0 ;;
    claude*|.claude*) WHY="it is named for Claude Code or this config, which the Claude items in the user temp folder kind and the Claude Code temporary folders kind count"; return 0 ;;
  esac
  return 1
}

# Sets V for <target>, given the open file listing <listing> or, when that failed, OPEN_WHY.
# dcs_user_temp has run.
tl_rules() { # <target> <listing>
  local t="${1%/}" held
  if [ -n "$DCS_UT_WHY" ]; then V="unmeasured: $DCS_UT_WHY"; return; fi
  dcs_parent_is "$t" "$DCS_UT" || { V="not offerable: it is not an entry directly in the user temp folder"; return; }
  if tl_not_ours "${t##*/}"; then V="not offerable: $WHY"; return; fi
  if [ -L "$t" ]; then V="not offerable: it is a link, which is never followed or offered"; return; fi
  if [ ! -e "$t" ]; then V="not offerable: it is no longer there"; return; fi
  if [ -n "${OPEN_WHY:-}" ]; then V="unmeasured: could not tell whether it is in use ($OPEN_WHY)"; return; fi
  held="$(dcs_holders "$t" "$2")"
  if [ -n "$held" ]; then V="not offerable: in use by $held"; return; fi
  V=offerable
  dcs_floor "$t"
}

open_listing() {
  OPEN_WHY=""
  LISTING="$DCS_WORK/tl.open"
  dcs_open_files "$LISTING" || { OPEN_WHY="$DCS_WHY"; : > "$LISTING"; }
}

do_scan() {
  dcs_user_temp
  if [ -n "$DCS_UT_WHY" ]; then dcs_status "unmeasured: $DCS_UT_WHY"; return 0; fi
  if ! ls -A "$DCS_UT" > "$DCS_WORK/tl.names" 2> "$DCS_WORK/tl.err"; then
    dcs_status "unmeasured: the user temp folder could not be listed ($(awk 'NR == 1' "$DCS_WORK/tl.err"))"
    return 0
  fi
  local e
  : > "$DCS_WORK/tl.paths"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    tl_not_ours "$e" && continue
    printf '%s/%s\n' "$DCS_UT" "$e" >> "$DCS_WORK/tl.paths"
  done < "$DCS_WORK/tl.names"
  [ -s "$DCS_WORK/tl.paths" ] || return 0
  open_listing
  dcs_measure "$DCS_WORK/tl.paths" | sort -t "$S" -k2,2nr > "$DCS_WORK/tl.sized"
  local p kib size ident n=0 total=0 short=""
  while IFS="$S" read -r p kib size ident; do
    case "$kib" in
      ''|*[!0-9]*) ;;
      *) if [ "$kib" -lt "$ROW_KIB" ]; then
           n=$((n + 1)); total=$((total + kib)); [ "$size" = measured ] || short=1
           continue
         fi ;;
    esac
    tl_rules "$p" "$LISTING"
    dcs_item "$p" delete "$kib" "$size" "$V" "" "" "$ident"
  done < "$DCS_WORK/tl.sized"
  [ "$n" -eq 0 ] || dcs_note "$n smaller entries, each under 1 MB, hold $([ -n "$short" ] && printf 'at least ')$(dcu_human "$total") and are not listed; a restart empties the folder. macOS's own entries there (com.apple.* and TemporaryItems) are not counted."
}

case "${1:-}" in
  scan) do_scan ;;
  judge) dcs_user_temp; open_listing; tl_rules "${2:-}" "$LISTING"; echo "$V" ;;
  *) echo "usage: temp-leftovers.sh scan | temp-leftovers.sh judge <target>" >&2; exit 2 ;;
esac
