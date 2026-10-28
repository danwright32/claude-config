#!/usr/bin/env bash
#
# playwright.sh: disk-clean's Playwright browser category (claude-config#1806). See scan-lib.sh for
# the module calls.
#
# Playwright keeps downloaded browsers in ~/Library/Caches/ms-playwright/<name>-<revision> and
# records which projects use the store in .links/ (each file holds a playwright-core folder's path).
# Newer releases also keep b/browser@<id> files, each naming its playwright-core in "playwrightLib".
# A revision is NEEDED when the browsers.json of any library either one names, and that is still on
# disk, lists it: its "revision" or any revision override, by browser name with hyphens written as
# underscores (chromium-headless-shell's folder is chromium_headless_shell-1243). A revision nothing
# needs is offered, by deleting it; Playwright downloads it again if it is ever wanted. A link to a
# library that is gone is ignored, as Playwright's own cleanup does; a library still there whose
# browsers.json cannot be read, or a link that cannot be read, makes the category unmeasured.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

PW="$HOME/Library/Caches/ms-playwright"

# Appends folder-name<TAB>library for every revision <lib>'s browsers.json lists to <out>.
needs_of() { # <lib> <out>
  local bj="$1/browsers.json"
  [ -r "$bj" ] || { DCS_WHY="the browsers.json of $1, a library that uses this store, could not be read"; return 1; }
  awk -v lib="$1" '
    match($0, /"name": *"[^"]*"/) { v = substr($0, RSTART, RLENGTH); sub(/^"name": *"/, "", v); sub(/"$/, "", v); gsub(/-/, "_", v); cur = v; next }
    cur != "" && match($0, /": *"[0-9]+"/) { r = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", r); print cur "-" r "\t" lib }' "$bj" >> "$2"
}
# Writes every needed revision to <out>; fails setting DCS_WHY.
needed() { # <out>
  local f lib
  : > "$1"
  for f in "$PW/.links"/*; do
    [ -e "$f" ] || continue
    [ -r "$f" ] || { DCS_WHY="the link $f could not be read"; return 1; }
    lib="$(awk 'NR == 1' "$f")"
    [ -n "$lib" ] && [ -d "$lib" ] || continue
    needs_of "$lib" "$1" || return 1
  done
  for f in "$PW/b"/*; do
    [ -e "$f" ] || continue
    [ -r "$f" ] || { DCS_WHY="the browser record $f could not be read"; return 1; }
    lib="$(sed -n 's/.*"playwrightLib": *"\([^"]*\)".*/\1/p' "$f" | awk 'NR == 1')"
    [ -n "$lib" ] && [ -d "$lib" ] || continue
    needs_of "$lib" "$1" || return 1
  done
  return 0
}
# Sets V for <target> against the needed list <needs>.
pw_rules() { # <target> <needs>
  local t="${1%/}" name="${1%/}" by
  name="${name##*/}"
  dcs_parent_is "$t" "$DCS_HOME/Library/Caches/ms-playwright" || { V="not offerable: it is not a folder directly inside Playwright's browser store"; return; }
  case "$name" in *-[0-9]*) ;; *) V="not offerable: it is not a browser revision folder"; return ;; esac
  [ -d "$t" ] || { V="not offerable: it is no longer there"; return; }
  by="$(awk -F '\t' -v n="$name" '$1 == n { print $2; exit }' "$2")"
  if [ -n "$by" ]; then V="not offerable: needed by $by"; return; fi
  V=offerable
}

do_scan() {
  [ -d "$PW" ] || return 0
  if ! needed "$DCS_WORK/pw.needs"; then dcs_status "unmeasured: $DCS_WHY, so which revisions are still needed is not known"; return 0; fi
  local d
  : > "$DCS_WORK/pw.paths"
  for d in "$PW"/*/; do
    d="${d%/}"
    case "${d##*/}" in b) continue ;; *-[0-9]*) printf '%s\n' "$d" >> "$DCS_WORK/pw.paths" ;; esac
  done
  dcs_measure "$DCS_WORK/pw.paths" > "$DCS_WORK/pw.sized"
  local p kib size ident
  while IFS="$S" read -r p kib size ident; do
    pw_rules "$p" "$DCS_WORK/pw.needs"
    dcs_item "$p" delete "$kib" "$size" "$V" "" "" "$ident"
  done < "$DCS_WORK/pw.sized"
}

do_judge() {
  needed "$DCS_WORK/pw.needs" || { echo "unmeasured: $DCS_WHY"; return 0; }
  pw_rules "$1" "$DCS_WORK/pw.needs"
  echo "$V"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) do_judge "${2:-}" ;;
  *) echo "usage: playwright.sh scan | playwright.sh judge <target>" >&2; exit 2 ;;
esac
