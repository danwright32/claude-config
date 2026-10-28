#!/usr/bin/env bash
#
# large-files.sh: disk-clean's large personal file category (claude-config#1806). See scan-lib.sh for
# the module calls.
#
# From the walk: every file over 500 MB in Downloads, Desktop, Documents and Movies, and nowhere
# else; a *.log is a runaway log instead. Files iCloud keeps only in the cloud (dataless) are never
# listed, since removing one frees nothing here. Offered, moved to the Trash, one by one by name on
# the review page; one in an iCloud synced Desktop or Documents is flagged, because removing it
# removes it from iCloud on every device.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

in_roots() { # <path>
  case "$1" in
    "$HOME/Downloads/"*|"$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Movies/"*) return 0 ;;
    "$DCS_HOME/Downloads/"*|"$DCS_HOME/Desktop/"*|"$DCS_HOME/Documents/"*|"$DCS_HOME/Movies/"*) return 0 ;;
  esac
  return 1
}
lf_rules() { # <target>
  local t="$1" b
  in_roots "$t" || { V="not offerable: it is not in Downloads, Desktop, Documents or Movies"; return; }
  case "$t" in *.log) V="not offerable: a log is the runaway log category's"; return ;; esac
  [ -f "$t" ] && [ ! -L "$t" ] || { V="not offerable: it is no longer there"; return; }
  dcs_dataless "$t" && { V="not offerable: iCloud keeps it only in the cloud, so removing it frees nothing here"; return; }
  b="$(dcs_bytes "$t")"
  case "$b" in ''|*[!0-9]*) V="unmeasured: its size could not be read"; return ;; esac
  [ "$b" -gt $((DCS_LARGE_MB * 1048576)) ] || { V="not offerable: it is no longer over $DCS_LARGE_MB MB"; return; }
  V=offerable
}

do_scan() {
  dcs_walk_ready
  : > "$DCS_WORK/lf.paths"
  local p
  while IFS= read -r p; do
    in_roots "$p" || continue
    case "$p" in *.log|*/.git) continue ;; esac
    [ -f "$p" ] || continue
    printf '%s\n' "$p" >> "$DCS_WORK/lf.paths"
  done < "$DCS_WALK"
  dcs_measure "$DCS_WORK/lf.paths" > "$DCS_WORK/lf.sized"
  local kib size ident flags m
  while IFS="$S" read -r p kib size ident; do
    lf_rules "$p"
    flags=""
    [ -n "$(dcs_credential "$p")" ] && flags=credential
    dcs_icloud "$p" && flags="$(dcs_join "$flags" icloud)"
    m="$(dcs_mtime "$p")"
    dcs_item "$p" trash "$kib" "$size" "$V" "$flags" "modified $(dcs_date "${m:-0}")" "$ident"
  done < "$DCS_WORK/lf.sized"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) lf_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: large-files.sh scan | large-files.sh judge <target>" >&2; exit 2 ;;
esac
