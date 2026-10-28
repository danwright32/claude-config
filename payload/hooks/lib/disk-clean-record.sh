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
# carry more fields (bytes, identity, size, flags, detail), which marking leaves untouched. size says
# how bytes was measured: measured, partial (a lower bound: du could not read everything beneath it),
# reported (the owning tool's own figure, Docker's), denied or unread (and then there is no bytes,
# never a 0). flags is a comma list: credential (it holds keys or secrets), icloud (removing it
# removes it from iCloud on every device). The header may carry more string keys after scanned_at. Strings escape
# only \ and " (as \\ and \"); a string holding anything else escaped, or a control character, is
# not one this layout carries, and its item reads as unreadable. A trailing comma after the last
# item is allowed. States: offerable, "not offerable: <reason>", "unmeasured: <reason>", and the ones
# disk-remove.sh writes: removed, trashed, truncated, gone.
#
# Functions (bash 3.2; commands: awk, mv, rm, and the builtins):
#   dcr_header <record> <key>          the header's value for scan_id, scanned_at or any note
#                                      dcr_write put there (fda, walk, categories,
#                                      status.<category>, note.<category>); fails when absent
#   dcr_complete <record>              succeeds when the record ends in its closing line
#   dcr_items <record>                 one line per item: id, category, method, target, state, the
#                                      bytes field (empty when absent), identity (empty when absent),
#                                      separated by \037; a line that cannot be read prints its id
#                                      (or ?) with state "unreadable"
#   dcr_write <record> <scan_id> <scanned_at> <items file> [<notes file>]
#                                      writes a record from lines of id, category, method, target,
#                                      bytes, state, identity, and optionally size, flags and detail,
#                                      separated by \037, through a temp file renamed into place;
#                                      fails, writing nothing, on a field holding a control character.
#                                      <notes file> holds lines of key \037 value, written into the
#                                      header as strings after scanned_at (disk-clean's scan, #1806:
#                                      fda, walk, categories, status.<category>, note.<category>); a
#                                      key must be letters, digits, dots, hyphens and underscores, and
#                                      none of version, scan_id, scanned_at or items
#   dcr_review_items <record>          what dcr_items prints, then size, flags and detail (empty when
#                                      absent): ten fields, for the review page (#1807). dcr_items
#                                      keeps its seven, which disk-remove.sh reads
#   dcr_title <category>               the category as a person reads it ("App caches"), or the name
#                                      itself for one this table does not know. DCR_TITLES is the
#                                      table (name|title rows), read by dcr_title and by the review
#                                      page's awk (#1807) through DCR_AWK_TITLES, one lookup for both
#   dcr_mark <record> <scan_id> <marks file>
#                                      sets the state of every item named in <marks file> (lines of
#                                      id \037 state), refusing when the record's scan_id is no longer
#                                      <scan_id> or when what it would write is shorter than what it
#                                      read (L105)

DCR_SEP=$'\037'

# How old a scan may be, in seconds, before disk-remove.sh refuses a plan made from it: what it
# measured may have changed since. The review page states the deadline from the same number (#1807).
DCR_MAX_SCAN_AGE=3600

# Every category's name as a person reads it, in one table: the scan's summary, the review page and
# the checker's confirmation all say the same words (#1806, #1807), the ones Dan settled for the
# review page on 2026-10-28 (docs/design/disk-clean-review-page.html). The 180 is scan-lib.sh's
# DCS_TOOL_DAYS. Rows are name|title separated by
# semicolons, on one line, because BSD awk refuses a -v value holding a newline.
DCR_TITLES='trash|Trash;caches|App caches;xcode|Xcode build caches;build-folders|Project build folders;docker|Docker;playwright|Playwright browsers;claude-temp|Claude Code temporary folders;worktrees|Finished worktrees;transcripts|Old transcripts;runaway-logs|Runaway logs;forgotten-tools|Tools not used in 180 days;large-files|Large personal files;named|Named by disk-full'
# dcr_t(<name>, <the table>): the lookup, for any awk program handed DCR_TITLES with -v.
DCR_AWK_TITLES='
function dcr_t(name, table,    n, i, rows, k) {
  n = split(table, rows, ";")
  for (i = 1; i <= n; i++) { k = index(rows[i], "|"); if (substr(rows[i], 1, k - 1) == name) return substr(rows[i], k + 1) }
  return name
}
'
dcr_title() { # <category>
  awk -v name="${1:-}" -v table="$DCR_TITLES" "$DCR_AWK_TITLES"'BEGIN { printf "%s\n", dcr_t(name, table) }'
}

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

dcr_write() { # <record> <scan_id> <scanned_at> <items file> [<notes file>]
  local record="$1" sid="$2" at="$3" items="$4" notes="${5:-/dev/null}" tmp
  _dcr_has_control "$sid" && return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "$notes" ] || return 1
  tmp="$record.tmp.$$"
  awk -v sep="$DCR_SEP" -v sid="$sid" -v at="$at" '
    function esc(s,    i, c, out) {
      out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "\\" || c == "\"") out = out "\\"; out = out c }
      return out
    }
    FILENAME == ARGV[1] {
      if ($0 == "") next
      k = index($0, sep); if (k == 0) { bad = 1; exit }
      key = substr($0, 1, k - 1); val = substr($0, k + 1)
      if (key !~ /^[A-Za-z0-9._-]+$/ || key == "version" || key == "scan_id" || key == "scanned_at" || key == "items") { bad = 1; exit }
      if (val ~ /[\001-\037]/) { bad = 1; exit }
      header = header ",\"" key "\":\"" esc(val) "\""
      next
    }
    FNR == 1 && !started { started = 1; printf "{\"version\":1,\"scan_id\":\"%s\",\"scanned_at\":%s%s,\"items\":[\n", esc(sid), at, header; printed = 1 }
    {
      n = split($0, f, sep)
      if (n < 6) { bad = 1; exit }
      for (k = 1; k <= n; k++) if (f[k] ~ /[\001-\037]/) { bad = 1; exit }
      line = "{\"id\":\"" esc(f[1]) "\",\"category\":\"" esc(f[2]) "\",\"method\":\"" esc(f[3]) "\",\"target\":\"" esc(f[4]) "\""
      if (f[5] ~ /^[0-9]+$/) line = line ",\"bytes\":" f[5]
      line = line ",\"state\":\"" esc(f[6]) "\""
      if (n >= 7 && f[7] != "") line = line ",\"identity\":\"" esc(f[7]) "\""
      if (n >= 8 && f[8] != "") line = line ",\"size\":\"" esc(f[8]) "\""
      if (n >= 9 && f[9] != "") line = line ",\"flags\":\"" esc(f[9]) "\""
      if (n >= 10 && f[10] != "") line = line ",\"detail\":\"" esc(f[10]) "\""
      lines[++count] = line "}"
    }
    END {
      if (bad) exit 1
      if (!printed) printf "{\"version\":1,\"scan_id\":\"%s\",\"scanned_at\":%s%s,\"items\":[\n", esc(sid), at, header
      for (k = 1; k <= count; k++) print lines[k] (k < count ? "," : "")
      print "]}"
    }' "$notes" "$items" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
}

dcr_review_items() { # <record>
  awk -v sep="$DCR_SEP" "$DCR_AWK_LIB"'
    NR == 1 { next }
    /^\{"id":/ {
      DCR_BAD = 0
      id = dcr_str($0, "id"); cat = dcr_str($0, "category"); m = dcr_str($0, "method")
      t = dcr_str($0, "target"); st = dcr_str($0, "state"); idn = dcr_str($0, "identity")
      sz = dcr_str($0, "size"); fl = dcr_str($0, "flags"); dt = dcr_str($0, "detail")
      b = dcr_num($0, "bytes")
      if (DCR_BAD || id == "" || cat == "" || m == "" || t == "" || st == "") {
        if (id == "") id = "?"
        print id sep "" sep "" sep "" sep "unreadable" sep "" sep "" sep "" sep "" sep ""
      } else {
        print id sep cat sep m sep t sep st sep b sep idn sep sz sep fl sep dt
      }
    }' "$1"
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
