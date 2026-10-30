#!/usr/bin/env bash
#
# runaway-logs.sh: disk-clean's runaway log category (claude-config#1806). See scan-lib.sh for the
# module calls.
#
# From the walk, which goes into home dotfolders too: every *.log over 500 MB. One a process holds
# open is offered for emptying in place (disk-remove.sh's truncate method), since deleting a file a
# writer holds frees nothing until the writer closes it; one nothing holds is offered for deleting.
# When lsof cannot tell (anything on stderr), it is unmeasured, never free (L42).
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

log_rules() { # <target>
  local t="$1" phys b
  phys="$(dcs_phys "$t")" || phys=""
  case "$phys" in "$DCS_HOME/"*.log) ;; *) V="not offerable: it is not a log file in the home folder"; return ;; esac
  [ -f "$t" ] && [ ! -L "$t" ] || { V="not offerable: it is no longer there"; return; }
  b="$(dcs_bytes "$t")"
  case "$b" in ''|*[!0-9]*) V="unmeasured: its size could not be read"; return ;; esac
  [ "$b" -gt $((DCS_LARGE_MB * 1048576)) ] || { V="not offerable: it is no longer over $DCS_LARGE_MB MB"; return; }
  V=offerable
}

do_scan() {
  dcs_walk_ready
  awk '/\.log$/' "$DCS_WALK" > "$DCS_WORK/logs.paths"
  dcs_measure "$DCS_WORK/logs.paths" > "$DCS_WORK/logs.sized"
  local p kib size ident method detail
  while IFS="$S" read -r p kib size ident; do
    [ -f "$p" ] || continue
    log_rules "$p"
    method=delete; detail="nothing holds it open"
    if [ "$V" = offerable ]; then
      if ! dcs_file_open "$p"; then V="unmeasured: could not tell whether it is in use ($DCS_WHY)"
      elif [ -n "$DCS_OPEN" ]; then method=truncate; detail="held open by $DCS_OPEN, so it is emptied in place"; fi
    fi
    dcs_item "$p" "$method" "$kib" "$size" "$V" "" "$detail" "$ident"
  done < "$DCS_WORK/logs.sized"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) log_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: runaway-logs.sh scan | runaway-logs.sh judge <target>" >&2; exit 2 ;;
esac
