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
# it is a copy of CI output, never anyone's work. A link is never listed. The page draws the kind as
# one row (review-lib.sh, DCRV_WHOLE), so only offerable entries are items and the kept ones are a
# count by reason in the kind's note; when lsof cannot say what is open, the kind is unmeasured.
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
  [ -n "$OPEN_WHY" ] && dcs_status "unmeasured: could not tell whether its entries are in use ($OPEN_WHY)"
  dcs_measure "$DCS_WORK/gh.paths" > "$DCS_WORK/gh.sized"
  # The page draws this kind as ONE row of what can go (review-lib.sh, DCRV_WHOLE, #3232): only an
  # offerable entry is an item, and what is kept is counted here, in the kind's note, by why.
  local p kib size ident recent=0 used=0 unjudged=0 other=0 kept
  while IFS="$S" read -r p kib size ident; do
    gh_rules "$p" "$LISTING"
    case "$V" in
      offerable) dcs_item "$p" delete "$kib" "$size" "$V" "" "" "$ident" ;;
      "not offerable: changed within"*|"not offerable: opened within"*) recent=$((recent + 1)) ;;
      "not offerable: in use by"*) used=$((used + 1)) ;;
      unmeasured:*) unjudged=$((unjudged + 1)) ;;
      *) other=$((other + 1)) ;;
    esac
  done < "$DCS_WORK/gh.sized"
  kept=$((recent + used + other))
  local why="" note=""
  if [ "$kept" -gt 0 ]; then
    [ "$recent" -gt 0 ] && why="$recent changed or opened within $DCS_UNUSED_DAYS days"
    [ "$used" -gt 0 ] && why="${why:+$why, }$used in use"
    [ "$other" -gt 0 ] && why="${why:+$why, }$other gone or changed since they were listed"
    note="$kept $([ "$kept" -eq 1 ] && echo "entry is" || echo "entries are") kept: $why."
  fi
  [ "$unjudged" -eq 0 ] || note="${note:+$note }$unjudged $([ "$unjudged" -eq 1 ] && echo "entry" || echo "entries") could not be judged, so none of them is offered."
  [ -z "$note" ] || dcs_note "$note"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) open_listing; gh_rules "${2:-}" "$LISTING"; echo "$V" ;;
  *) echo "usage: gh-cache.sh scan | gh-cache.sh judge <target>" >&2; exit 2 ;;
esac
