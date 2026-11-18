#!/usr/bin/env bash
#
# gh-cache.sh: disk-clean's GitHub command line cache category (claude-config#3235). See scan-lib.sh
# for the module calls.
#
# gh keeps two things in ~/.cache/gh: run-log-<run>-<attempt>.zip, a copy of an Actions run's logs
# that `gh run view --log` downloaded, and folders of cached API answers (`gh api --cache`). Sessions
# fill it by reading CI logs: measured on the personal MacBook on 2026-11-18, 344 MB in 2,089 files,
# nearly all run logs. Every entry directly in it is offered, by deleting it, since gh downloads it
# again when asked, unless a running process holds a file in it (one lsof listing, as caches.sh
# reads it) or it was changed or opened in the last 30 days (the floor every kind keeps). GitHub
# keeps a run's logs for 90 days by default, so a log older than that cannot be downloaded again;
# it is a copy of CI output, never anyone's work. A link is never listed.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

G="$HOME/.cache/gh"

# Sets V for <target>, given the open file listing <listing> or, when that failed, OPEN_WHY.
gh_rules() { # <target> <listing>
  local t="${1%/}" held
  dcs_parent_is "$t" "$(dcs_phys "$G" 2>/dev/null)" || { V="not offerable: it is not an entry directly inside ~/.cache/gh"; return; }
  [ -e "$t" ] && [ ! -L "$t" ] || { V="not offerable: it is no longer there, or is a link"; return; }
  if [ -n "${OPEN_WHY:-}" ]; then V="unmeasured: could not tell whether it is in use ($OPEN_WHY)"; return; fi
  held="$(dcs_holders "$t" "$2")"
  if [ -n "$held" ]; then V="not offerable: in use by $held"; return; fi
  V=offerable
  dcs_floor "$t"
}

open_listing() {
  OPEN_WHY=""
  LISTING="$DCS_WORK/gh.open"
  dcs_open_files "$LISTING" || { OPEN_WHY="$DCS_WHY"; : > "$LISTING"; }
}

do_scan() {
  [ -d "$G" ] || return 0
  if ! ls -A "$G" > "$DCS_WORK/gh.names" 2> "$DCS_WORK/gh.err"; then
    dcs_status "unmeasured: ~/.cache/gh could not be listed ($(awk 'NR == 1' "$DCS_WORK/gh.err"))"
    return 0
  fi
  local n
  : > "$DCS_WORK/gh.paths"
  while IFS= read -r n; do
    [ -n "$n" ] && [ ! -L "$G/$n" ] || continue
    printf '%s\n' "$G/$n" >> "$DCS_WORK/gh.paths"
  done < "$DCS_WORK/gh.names"
  open_listing
  dcs_measure "$DCS_WORK/gh.paths" > "$DCS_WORK/gh.sized"
  local p kib size ident
  while IFS="$S" read -r p kib size ident; do
    gh_rules "$p" "$LISTING"
    dcs_item "$p" delete "$kib" "$size" "$V" "" "" "$ident"
  done < "$DCS_WORK/gh.sized"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) open_listing; gh_rules "${2:-}" "$LISTING"; echo "$V" ;;
  *) echo "usage: gh-cache.sh scan | gh-cache.sh judge <target>" >&2; exit 2 ;;
esac
