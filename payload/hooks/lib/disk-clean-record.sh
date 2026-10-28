#!/usr/bin/env bash
#
# disk-clean-record.sh: the one place a disk-clean scan record is read and written (claude-config#1805).
#
# A scan record says what one scan measured and offered, under one scan_id. disk-clean's scan
# (payload/skills/disk-clean/scan.sh, #1806) writes ~/.claude/state/disk-clean/last-scan.json;
# disk-remove.sh --propose writes a narrow one for the items disk-full names; disk-remove.sh reads
# whichever its plan names and marks what it removed; the low space warning (#1810) reads what is
# left. They all go through these functions, so the layout has one owner (L370).
#
# THE LAYOUT. JSON, with one fact per line so a line tool can read and mark it without a JSON parser
# (neither jq nor python3 is a tool the disk-clean scripts may call):
#
#   {"version":1,"scan_id":"<id>","scanned_at":<epoch seconds>,"items":[
#   {"id":"<id>","category":"<name>","method":"<method>","target":"<path or docker target>","bytes":<n>,"state":"<state>"},
#   {"id":"<id>",...},
#   ]}
#
# Line 1 is the header and the last line is exactly `]}`; a record without that last line is a write
# that stopped partway and is read as unreadable, never as a shorter scan (L211). Every item is one
# line beginning {"id":, carries at least id, category, method, target and state as strings, and may
# carry more fields (bytes, identity, reason, flags), which marking leaves untouched. Strings escape
# only \ and " (as \\ and \"); a string holding anything else escaped, or a control character, is
# not one this layout carries, and its item reads as unreadable. A trailing comma after the last
# item is allowed. States: offerable, "not offerable: <reason>", "unmeasured: <reason>", and the ones
# disk-remove.sh writes: removed, trashed, truncated, gone.
#
# Functions (bash 3.2; commands: awk, mv, rm, and the builtins):
#   dcr_header <record> <key>          the header's value for scan_id or scanned_at; fails when absent
#   dcr_complete <record>              succeeds when the record ends in its closing line
#   dcr_items <record>                 one line per item: id, category, method, target, state, the
#                                      bytes field (empty when absent), identity (empty when absent),
#                                      separated by \037; a line that cannot be read prints its id
#                                      (or ?) with state "unreadable"
#   dcr_write <record> <scan_id> <scanned_at> <items file>
#                                      writes a record from lines of id, category, method, target,
#                                      bytes, state, identity separated by \037, through a temp file
#                                      renamed into place; fails, writing nothing, on a field holding
#                                      a control character
#   dcr_mark <record> <scan_id> <marks file>
#                                      sets the state of every item named in <marks file> (lines of
#                                      id \037 state), refusing when the record's scan_id is no longer
#                                      <scan_id> or when what it would write is shorter than what it
#                                      read (L105)

DCR_SEP=$'\037'

# Shared awk: reads one string or number field from an item or header line.
DCR_AWK_LIB='
function dcr_str(line, key,    start, i, c, n, out) {
  start = index(line, "\"" key "\":\"")
  if (start == 0) { DCR_ABSENT = 1; return "" }
  DCR_ABSENT = 0
  i = start + length(key) + 4; n = length(line); out = ""
  while (i <= n) {
    c = substr(line, i, 1)
    if (c == "\\") {
      c = substr(line, i + 1, 1)
      if (c != "\\" && c != "\"") { DCR_BAD = 1; return "" }
      out = out c; i += 2; continue
    }
    if (c == "\"") return out
    out = out c; i++
  }
  DCR_BAD = 1
  return ""
}
function dcr_num(line, key,    start, rest) {
  start = index(line, "\"" key "\":")
  if (start == 0) return ""
  rest = substr(line, start + length(key) + 3)
  if (match(rest, /^[0-9]+/)) return substr(rest, 1, RLENGTH)
  return ""
}
'

dcr_header() { # <record> <key>
  local v
  [ -f "$1" ] || return 1
  v="$(awk -v key="$2" "$DCR_AWK_LIB"'
    NR == 1 {
      if (key == "scanned_at") v = dcr_num($0, key); else { v = dcr_str($0, key); if (DCR_ABSENT || DCR_BAD) v = "" }
      print v; exit
    }' "$1")" || return 1
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

dcr_complete() { # <record>
  [ -f "$1" ] || return 1
  awk 'END { exit !(last == "]}") } NF { last = $0 }' "$1"
}

dcr_items() { # <record>
  awk -v sep="$DCR_SEP" "$DCR_AWK_LIB"'
    NR == 1 { next }
    /^\{"id":/ {
      DCR_BAD = 0
      id = dcr_str($0, "id"); cat = dcr_str($0, "category"); m = dcr_str($0, "method")
      t = dcr_str($0, "target"); st = dcr_str($0, "state"); idn = dcr_str($0, "identity")
      b = dcr_num($0, "bytes")
      if (DCR_BAD || id == "" || cat == "" || m == "" || t == "" || st == "") {
        if (id == "") id = "?"
        print id sep "" sep "" sep "" sep "unreadable" sep "" sep ""
      } else {
        print id sep cat sep m sep t sep st sep b sep idn
      }
    }' "$1"
}

_dcr_has_control() { case "$1" in *[[:cntrl:]]*) return 0 ;; esac; return 1; }

dcr_write() { # <record> <scan_id> <scanned_at> <items file>
  local record="$1" sid="$2" at="$3" items="$4" tmp
  _dcr_has_control "$sid" && return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  tmp="$record.tmp.$$"
  awk -v sep="$DCR_SEP" -v sid="$sid" -v at="$at" '
    function esc(s,    i, c, out) {
      out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "\\" || c == "\"") out = out "\\"; out = out c }
      return out
    }
    BEGIN { printf "{\"version\":1,\"scan_id\":\"%s\",\"scanned_at\":%s,\"items\":[\n", esc(sid), at }
    {
      n = split($0, f, sep)
      if (n < 6) { bad = 1; exit }
      for (k = 1; k <= n; k++) if (f[k] ~ /[\001-\037]/) { bad = 1; exit }
      line = "{\"id\":\"" esc(f[1]) "\",\"category\":\"" esc(f[2]) "\",\"method\":\"" esc(f[3]) "\",\"target\":\"" esc(f[4]) "\""
      if (f[5] ~ /^[0-9]+$/) line = line ",\"bytes\":" f[5]
      line = line ",\"state\":\"" esc(f[6]) "\""
      if (n >= 7 && f[7] != "") line = line ",\"identity\":\"" esc(f[7]) "\""
      lines[++count] = line "}"
    }
    END {
      if (bad) exit 1
      for (k = 1; k <= count; k++) print lines[k] (k < count ? "," : "")
      print "]}"
    }' "$items" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
}

dcr_mark() { # <record> <scan_id> <marks file>
  local record="$1" sid="$2" marks="$3" tmp now_sid in_n out_n
  dcr_complete "$record" || return 1
  tmp="$record.mark.$$"
  awk -v sep="$DCR_SEP" "$DCR_AWK_LIB"'
    function esc(s,    i, c, out) {
      out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "\\" || c == "\"") out = out "\\"; out = out c }
      return out
    }
    FILENAME == ARGV[1] { split($0, f, sep); if (f[1] != "") want[f[1]] = f[2]; next }
    /^\{"id":/ {
      DCR_BAD = 0; id = dcr_str($0, "id")
      if (!DCR_BAD && (id in want)) {
        s = index($0, "\"state\":\"")
        if (s > 0) {
          i = s + 9; n = length($0)
          while (i <= n) { c = substr($0, i, 1); if (c == "\\") { i += 2; continue }; if (c == "\"") break; i++ }
          $0 = substr($0, 1, s + 8) esc(want[id]) substr($0, i)
        }
      }
    }
    { print }' "$marks" "$record" > "$tmp" || { rm -f "$tmp"; return 1; }
  in_n="$(awk 'END { print NR }' "$record")"
  out_n="$(awk 'END { print NR }' "$tmp")"
  now_sid="$(dcr_header "$record" scan_id)" || now_sid=""
  if [ "$in_n" != "$out_n" ] || ! dcr_complete "$tmp" || [ "$now_sid" != "$sid" ]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
}
