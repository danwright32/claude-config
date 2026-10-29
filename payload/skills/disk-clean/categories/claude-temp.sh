#!/usr/bin/env bash
#
# claude-temp.sh: disk-clean's Claude Code temp folder category (claude-config#1806). See scan-lib.sh
# for the module calls.
#
# Claude Code keeps a folder per project and session at /tmp/claude-<uid>/<project slug>/<session
# id>, each session's scratchpad among them. Offered, by deleting it: a <slug>/<session id> folder
# whose id is in no ~/.claude/sessions/*.json (the live session map) and in which nothing changed in
# the last day (DCS_TEMP_MINUTES, a threshold the code sets, not measured). Neither half alone is enough: a live session's folder can sit untouched for
# days, and a session can end a minute ago. The whole category is unmeasured when the session map
# cannot be read, and when it is EMPTY while a Claude Code process runs, because an empty map then
# means the map is wrong, not that every session ended (the plan's rule). One folder is unmeasured
# when find could not read all of it, since the part it could not read may be in use (#1851).
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

ROOT="$DCS_CLAUDE_TMP"
IDS="$DCS_WORK/ct.ids"; CWDS="$DCS_WORK/ct.cwds"

# Sets MAP_WHY to why the session map cannot be trusted, or leaves it empty.
read_map() {
  MAP_WHY=""
  if ! dcs_sessions "$IDS" "$CWDS"; then MAP_WHY="the session map could not be read ($DCS_WHY)"; return; fi
  [ -s "$IDS" ] && return
  dcs_claude_running
  case $? in
    0) MAP_WHY="the session map (~/.claude/sessions) is empty while Claude Code is running, so no folder can be told abandoned" ;;
    2) MAP_WHY="the session map (~/.claude/sessions) is empty, and whether Claude Code is running could not be read" ;;
  esac
}
is_uuid() {
  case "$1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
  esac
  return 1
}
# Sets V for <target>; read_map has run.
temp_rules() { # <target>
  local t="${1%/}" root_phys grand u recent rc err="$DCS_WORK/ct.find.err.$$"
  u="${t##*/}"
  root_phys="$(CDPATH= cd -P "$ROOT" 2>/dev/null && pwd -P)" || root_phys=""
  grand="$(CDPATH= cd -P "${t%/*}/.." 2>/dev/null && pwd -P)" || grand=""
  if [ -z "$root_phys" ] || [ "$grand" != "$root_phys" ] || ! is_uuid "$u"; then V="not offerable: it is not a Claude Code session folder (<slug>/<session id> under $ROOT)"; return; fi
  [ -d "$t" ] && [ ! -L "$t" ] || { V="not offerable: it is no longer there"; return; }
  if [ -n "$MAP_WHY" ]; then V="unmeasured: $MAP_WHY"; return; fi
  if grep -qxF -- "$u" "$IDS"; then V="not offerable: a live session ($u) owns it"; return; fi
  # find's complaints are read, as build-folders.sh and forgotten-tools.sh read dcs_recent_file's:
  # a folder find could not wholly read may hold something used a minute ago, so it is unmeasured,
  # never offerable (#1851, L10, L11). A find that failed saying nothing is unmeasured too.
  recent="$(find "$t" -mmin -"$DCS_TEMP_MINUTES" -print -quit 2> "$err")"; rc=$?
  if [ -n "$recent" ]; then V="not offerable: used within the last 24 hours"; rm -f "$err"; return; fi
  if [ -s "$err" ]; then V="unmeasured: part of it could not be read ($(awk 'NR == 1' "$err")), so whether it was used in the last 24 hours is not known"; rm -f "$err"; return; fi
  rm -f "$err"
  if [ "$rc" -ne 0 ]; then V="unmeasured: find exited $rc reading it, so whether it was used in the last 24 hours is not known"; return; fi
  V=offerable
}

do_scan() {
  [ -d "$ROOT" ] || return 0
  read_map
  [ -n "$MAP_WHY" ] && dcs_status "unmeasured: $MAP_WHY"
  local s u
  : > "$DCS_WORK/ct.paths"
  for s in "$ROOT"/*/; do
    for u in "$s"*/; do
      [ -d "$u" ] || continue
      u="${u%/}"
      is_uuid "${u##*/}" && printf '%s\n' "$u" >> "$DCS_WORK/ct.paths"
    done
  done
  dcs_measure "$DCS_WORK/ct.paths" > "$DCS_WORK/ct.sized"
  local p kib size ident
  while IFS="$S" read -r p kib size ident; do
    temp_rules "$p"
    dcs_item "$p" delete "$kib" "$size" "$V" "" "" "$ident"
  done < "$DCS_WORK/ct.sized"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) read_map; temp_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: claude-temp.sh scan | claude-temp.sh judge <target>" >&2; exit 2 ;;
esac
