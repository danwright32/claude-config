#!/usr/bin/env bash
#
# transcripts.sh: disk-clean's Claude Code transcript category (claude-config#1806). See scan-lib.sh
# for the module calls.
#
# Claude Code deletes its own transcripts (~/.claude/projects/**/*.jsonl) after 30 days. Dan kept a
# 90 day rule as a safety net (the plan, 2026-10-27): any transcript older than that is offered,
# moved to the Trash, and its presence at all means Claude Code's own cleanup has stopped, which the
# category's note says.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

P="$HOME/.claude/projects"

tr_rules() { # <target>
  local t="$1" phys old
  phys="$(dcs_phys "$t")" || phys=""
  case "$phys" in "$DCS_HOME/.claude/projects/"*.jsonl) ;; *) V="not offerable: it is not a Claude Code transcript"; return ;; esac
  [ -f "$t" ] && [ ! -L "$t" ] || { V="not offerable: it is no longer there"; return; }
  old="$(find "$t" -type f -mtime +"$DCS_TRANSCRIPT_DAYS" -print 2>/dev/null)"
  [ -n "$old" ] || { V="not offerable: it changed within $DCS_TRANSCRIPT_DAYS days"; return; }
  V=offerable
}

do_scan() {
  [ -d "$P" ] || return 0
  find "$P" -type f -name '*.jsonl' -mtime +"$DCS_TRANSCRIPT_DAYS" -print > "$DCS_WORK/tr.paths" 2> "$DCS_WORK/tr.err"
  if [ -s "$DCS_WORK/tr.err" ]; then
    dcs_status "unmeasured: part of ~/.claude/projects could not be read ($(awk 'NR == 1' "$DCS_WORK/tr.err"))"
  fi
  dcs_measure "$DCS_WORK/tr.paths" > "$DCS_WORK/tr.sized"
  local p kib size ident n=0 m
  while IFS="$S" read -r p kib size ident; do
    tr_rules "$p"
    m="$(dcs_mtime "$p")"
    dcs_item "$p" trash "$kib" "$size" "$V" "" "last written $(dcs_date "${m:-0}")" "$ident"
    n=$((n + 1))
  done < "$DCS_WORK/tr.sized"
  [ "$n" -eq 0 ] || dcs_note "Claude Code's 30 day cleanup appears to have stopped: $n transcript(s) are older than $DCS_TRANSCRIPT_DAYS days."
}

case "${1:-}" in
  scan) do_scan ;;
  judge) tr_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: transcripts.sh scan | transcripts.sh judge <target>" >&2; exit 2 ;;
esac
