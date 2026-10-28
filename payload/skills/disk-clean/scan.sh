#!/usr/bin/env bash
#
# scan.sh: disk-clean's read only scan (claude-config#1806, phase 3 of the Disk cleanup skill).
#
#   bash ~/.claude/skills/disk-clean/scan.sh [--only <category>[,<category>...]]
#
# Measures what could be removed, category by category, and writes it to
# ~/.claude/state/disk-clean/last-scan.json (per Mac, never synced) through hooks/lib/
# disk-clean-record.sh, which owns the layout. It NEVER removes anything: removal is
# hooks/lib/disk-remove.sh, run on a plan naming this scan's id and the items Dan ticked, which runs
# each item's category judge again first.
#
# IN ORDER:
#   1. Refuses (exit 75) while a disk-remove run holds its lock, since a new record would orphan the
#      plan that run is working through.
#   2. The Full Disk Access probe: lists ~/Library/Mail, which macOS lets only a process with Full
#      Disk Access read. Reported first, because without it every protected folder reads as
#      permission denied, never as small.
#   3. The one pruned walk of the home folder (scan-lib.sh, dcs_walk), when a category that reads it
#      is asked for.
#   4. Each category module in turn (categories/<name>.sh scan), the Trash first, since its entries
#      must be settled before anything else is moved into it.
#   5. The record, written whole and renamed into place, then a summary.
#
# THE TIME BOUND. macOS has no timeout command, so each category (and the walk) runs as a background
# job under job control, which puts it in a process group of its own, and a watchdog kills that
# whole group when the bound passes (L321): du, find and lsof started by the module die with it. A
# category that ran out is recorded as "unmeasured: timed out after Ns", and the rest go on.
#   DISK_CLEAN_CATEGORY_SECONDS  each category's bound, default 600. Measured on the personal
#                                MacBook on 2026-10-27: build folders, the slowest, took 141 s for 399
#                                folders, 106 s of it du; the bound is about four times that
#   DISK_CLEAN_WALK_SECONDS      the walk's bound, default 900 (measured 24 to 34 s on the personal
#                                MacBook, 2026-10-27)
#
# THE RECORD'S HEADER carries, beyond scan_id and scanned_at: fda (granted, "denied: ..." or
# "unmeasured: ..."), walk (complete, "partial: ..." or "unmeasured: ..."), categories (the ones this
# scan ran, in order), status.<category> (measured or "unmeasured: <why>") and, where a category has
# one, note.<category>. Each item carries id, category, method, target, bytes, state, identity, size
# (measured, partial, reported, denied, unread), flags (credential, icloud) and detail.
#
# Exit: 0 the record was written (unmeasured categories included); 2 refused or the record could not
# be written; 75 a disk-remove run is removing things now.
#
# bash 3.2 safe. Commands: those scan-lib.sh lists, kill, sleep, and the category modules.
set -uo pipefail

HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/scan-lib.sh" || { echo "disk-clean scan: scan-lib.sh is missing beside it, so it scanned nothing."; exit 2; }
CATS="$DCS_LIB/categories"
W="$DCS_WORK"

ALL="trash caches xcode build-folders docker playwright claude-temp worktrees transcripts runaway-logs forgotten-tools large-files"
WALKERS=" build-folders worktrees runaway-logs forgotten-tools large-files "

title() {
  case "$1" in
    trash) echo "Trash" ;; caches) echo "App caches" ;; xcode) echo "Xcode build caches" ;; build-folders) echo "Build folders" ;;
    docker) echo "Docker" ;; playwright) echo "Playwright browsers" ;; claude-temp) echo "Claude Code temp folders" ;;
    worktrees) echo "Worktrees" ;; transcripts) echo "Claude Code transcripts" ;; runaway-logs) echo "Runaway logs" ;;
    forgotten-tools) echo "Forgotten tools" ;; large-files) echo "Large personal files" ;; *) echo "$1" ;;
  esac
}

LIMIT="${DISK_CLEAN_CATEGORY_SECONDS:-600}"
WALK_LIMIT="${DISK_CLEAN_WALK_SECONDS:-900}"
case "$LIMIT" in ''|*[!0-9]*|0) echo "disk-clean scan: DISK_CLEAN_CATEGORY_SECONDS is '$LIMIT', which is not a whole number of seconds, so it scanned nothing."; exit 2 ;; esac
case "$WALK_LIMIT" in ''|*[!0-9]*|0) echo "disk-clean scan: DISK_CLEAN_WALK_SECONDS is '$WALK_LIMIT', which is not a whole number of seconds, so it scanned nothing."; exit 2 ;; esac

ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only) [ "$#" -ge 2 ] || { echo "disk-clean scan: --only takes a comma separated list of categories."; exit 2; }; ONLY="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^set -uo/ { exit } NR > 1 { print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "disk-clean scan: it does not know '$1' (the only option is --only), so it scanned nothing."; exit 2 ;;
  esac
done
RUN="$ALL"
if [ -n "$ONLY" ]; then
  RUN=""
  for c in $ALL; do case ",$ONLY," in *",$c,"*) RUN="$RUN${RUN:+ }$c" ;; esac; done
  for c in $(printf '%s' "$ONLY" | tr ',' ' '); do
    case " $ALL " in *" $c "*) ;; *) echo "disk-clean scan: '$c' is not a category (they are: $ALL), so it scanned nothing."; exit 2 ;; esac
  done
fi

# ---------- 1. never while a removal is running ----------
holder="$(readlink "$DCS_STATE/remove.lock" 2>/dev/null)"
case "$holder" in
  ''|*[!0-9]*) ;;
  *) kill -0 "$holder" 2>/dev/null && { echo "disk-clean scan: a disk-remove run (pid $holder) is removing things now, and a new scan would replace the record it is working from, so it scanned nothing. Scan again once it has finished."; exit 75; } ;;
esac
mkdir -p "$DCS_STATE" 2>/dev/null || { echo "disk-clean scan: could not make $DCS_STATE, so it scanned nothing."; exit 2; }
T0="$(date +%s)" || { echo "disk-clean scan: could not read the clock, so it scanned nothing."; exit 2; }
SID="scan-$T0-$$"
: > "$W/notes"

note() { printf '%s%s%s\n' "$1" "$S" "$2" >> "$W/notes"; }
note host "$(hostname -s 2>/dev/null || hostname 2>/dev/null)"

# ---------- 2. the Full Disk Access probe, first ----------
MAIL="$HOME/Library/Mail"
if [ -d "$MAIL" ]; then
  if ls "$MAIL" >/dev/null 2>"$W/fda.err"; then
    FDA=granted
    echo "Full Disk Access: granted (~/Library/Mail could be listed)."
  else
    why="$(awk 'NR == 1' "$W/fda.err")"
    FDA="denied: ~/Library/Mail could not be listed (${why:-no reason given}), so folders macOS protects are measured as permission denied"
    echo "Full Disk Access: not granted. ~/Library/Mail could not be listed (${why:-no reason given}), so every folder macOS protects reads as permission denied rather than as its size."
  fi
else
  FDA="unmeasured: there is no ~/Library/Mail on this Mac to try, so whether Full Disk Access is granted is not known"
  echo "Full Disk Access: unmeasured. There is no ~/Library/Mail on this Mac to try listing, so whether it is granted is not known."
fi
note fda "$FDA"

# ---------- the time bound ----------
watchdog() { # <marker> <seconds> <process group>
  sleep "$2"
  : > "$1"
  kill -TERM -- "-$3" 2>/dev/null
  sleep 2
  kill -KILL -- "-$3" 2>/dev/null
}
run_module() { # <name>
  export DISK_CLEAN_WORK="$W" DISK_CLEAN_WALK="$W/walk" DISK_CLEAN_WALK_STATE="${WALK_STATE:-}"
  case "$1" in
    walk) dcs_walk ;;
    trash) bash "$CATS/trash.sh" scan ;;
    caches) bash "$CATS/caches.sh" scan ;;
    xcode) bash "$CATS/xcode.sh" scan ;;
    build-folders) bash "$CATS/build-folders.sh" scan ;;
    docker) bash "$CATS/docker.sh" scan ;;
    playwright) bash "$CATS/playwright.sh" scan ;;
    claude-temp) bash "$CATS/claude-temp.sh" scan ;;
    worktrees) bash "$CATS/worktrees.sh" scan ;;
    transcripts) bash "$CATS/transcripts.sh" scan ;;
    runaway-logs) bash "$CATS/runaway-logs.sh" scan ;;
    forgotten-tools) bash "$CATS/forgotten-tools.sh" scan ;;
    large-files) bash "$CATS/large-files.sh" scan ;;
    *) echo "no such module: $1" >&2; return 2 ;;
  esac
}
# Runs <name> under job control, so it has a process group of its own, with a watchdog that kills
# that group after <seconds>. Sets BOUND_RC and BOUND_TIMED_OUT (1 or empty). Output in $W/<name>.out
# and .err.
run_bounded() { # <name> <seconds>
  local name="$1" secs="$2" pid wpid
  rm -f "$W/$name.timedout"
  set -m
  run_module "$name" > "$W/$name.out" 2> "$W/$name.err" < /dev/null &
  pid=$!
  watchdog "$W/$name.timedout" "$secs" "$pid" > /dev/null 2>&1 < /dev/null &
  wpid=$!
  { wait "$pid"; } 2>/dev/null; BOUND_RC=$?
  kill -TERM -- "-$wpid" 2>/dev/null
  { wait "$wpid"; } 2>/dev/null
  set +m
  BOUND_TIMED_OUT=""; [ -e "$W/$name.timedout" ] && BOUND_TIMED_OUT=1
  return 0
}

# ---------- 3. the walk, once ----------
WALK_STATE=""
need_walk=""
for c in $RUN; do case "$WALKERS" in *" $c "*) need_walk=1 ;; esac; done
if [ -n "$need_walk" ]; then
  run_bounded walk "$WALK_LIMIT"
  mv -f "$W/walk.out" "$W/walk" 2>/dev/null || : > "$W/walk"
  if [ -n "$BOUND_TIMED_OUT" ]; then WALK_STATE="unmeasured: timed out after ${WALK_LIMIT}s"
  else WALK_STATE="$(dcs_walk_state "$BOUND_RC" "$W/walk.err")"; fi
  note walk "$WALK_STATE"
  echo "Walk of the home folder: $WALK_STATE."
fi

# ---------- 4. each category ----------
: > "$W/items"
note categories "$RUN"
for c in $RUN; do
  run_bounded "$c" "$LIMIT"
  status="" catnote=""
  awk -F "$S" -v cat="$c" -v sep="$S" -v items="$W/items" -v meta="$W/$c.meta" '
    $1 == "item" {
      if (NF != 10 || $10 != "end" || $2 == "") { cut++; next }
      bad = 0; for (i = 2; i <= 9; i++) if ($i ~ /[\001-\036]/) bad = 1
      if (bad) { ctl++; next }
      n++
      bytes = ($4 ~ /^[0-9]+$/) ? $4 * 1024 : ""
      printf "%s-%d%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", cat, n, sep, cat, sep, $3, sep, $2, sep, bytes, sep, $6, sep, $9, sep, $5, sep, $7, sep, $8 >> items
      next
    }
    $1 == "status" { st = $2; next }
    $1 == "note" { nt = nt (nt == "" ? "" : " ") $2; next }
    END {
      if (ctl) nt = nt (nt == "" ? "" : " ") "This scan left out " ctl " path(s) holding a control character, which the record cannot carry."
      if (cut) nt = nt (nt == "" ? "" : " ") "This scan left out " cut " line(s) the module did not finish writing."
      printf "%s\n%s\n", st, nt > meta
    }' "$W/$c.out"
  status="$(awk 'NR == 1' "$W/$c.meta")"; catnote="$(awk 'NR == 2' "$W/$c.meta")"
  if [ -n "$BOUND_TIMED_OUT" ]; then status="unmeasured: timed out after ${LIMIT}s"
  elif [ "$BOUND_RC" -ne 0 ]; then status="unmeasured: the $c module failed (exit $BOUND_RC$([ -s "$W/$c.err" ] && printf ': %s' "$(awk 'NR == 1' "$W/$c.err")"))"
  elif [ -z "$status" ]; then status=measured; fi
  note "status.$c" "$status"
  [ -n "$catnote" ] && note "note.$c" "$catnote"
done

# ---------- 5. the record ----------
if ! dcr_write "$DCS_RECORD" "$SID" "$T0" "$W/items" "$W/notes"; then
  echo "disk-clean scan: could not write the record $DCS_RECORD, so this scan cannot be reviewed or acted on."
  exit 2
fi

echo ""
for c in $RUN; do
  status="$(dcr_header "$DCS_RECORD" "status.$c" 2>/dev/null)"
  line="$(awk -F "$S" -v c="$c" '
    # The items file: id, category, method, target, bytes, state (then identity, size, flags, detail).
    $2 == c { n++; if ($6 == "offerable") { o++; if ($5 != "") b += $5 } else if (index($6, "unmeasured: ") == 1) u++; else x++ }
    END { printf "%d %d %d %d %.0f", n, o, x, u, b / 1024 }' "$W/items")"
  set -- $line
  words="$2 offerable ($(dcu_human "$5")), $3 not offerable, $4 unmeasured"
  if [ "$status" = measured ]; then echo "$(title "$c"): $words."
  else echo "$(title "$c"): $status. Found before that: $words."; fi
  n="$(dcr_header "$DCS_RECORD" "note.$c" 2>/dev/null)" && echo "  $n"
done
echo ""
echo "Scan $SID: $(awk 'END { print NR }' "$W/items") item(s), written to $DCS_RECORD."
echo "Nothing was removed."
exit 0
