#!/usr/bin/env bash
#
# claude-user-temp.sh: disk-clean's Claude named items in the user temp folder (claude-config#3235).
# See scan-lib.sh for the module calls.
# offers: nothing
#
# This config's hooks, the sync and its test suites keep small working files and markers in the user
# temp folder ($TMPDIR, /var/folders/.../T): claude-add-scope-*, claude-stale-worktrees-* (a lock
# among them), claude-sync work folders, .claude-lessons-advisory.*. Each is read by the run or hook
# that made it, some while a run is in progress, and nothing records which run is over, so none is
# offered. Measured on the personal MacBook on 2026-11-18: about 1,050 entries holding 2.2 MB, all
# made since the restart of 2026-11-17, which emptied the folder. So the kind lists no rows (a
# thousand greyed rows for 2 MB would bury the page) and says the count and size in its note.
# Claude Code's own temp folder, claude-<uid>, is the claude-temp kind's and is not counted here.
# Outside test mode the folder is TMPDIR only when it is under /private/var/folders; otherwise which
# folder is the user's is not known, and the kind is unmeasured.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

# Sets UT to the user temp folder's physical path, or UT_WHY to why it is not known.
user_temp() {
  UT=""; UT_WHY=""
  [ -n "${TMPDIR:-}" ] || { UT_WHY="TMPDIR is not set, so the user temp folder is not known"; return; }
  UT="$(CDPATH= cd -P "$TMPDIR" 2>/dev/null && pwd -P)" || UT=""
  [ -n "$UT" ] || { UT_WHY="the user temp folder $TMPDIR could not be read"; return; }
  if [ -z "$DCS_TEST_ROOT" ]; then
    case "$UT" in /private/var/folders/?*) ;; *) UT_WHY="TMPDIR is $TMPDIR, not a folder under /var/folders, so the user temp folder is not known"; UT=""; return ;; esac
  fi
}

do_scan() {
  user_temp
  if [ -n "$UT_WHY" ]; then dcs_status "unmeasured: $UT_WHY"; return 0; fi
  local e n=0 oldest="" m
  : > "$DCS_WORK/ut.paths"
  for e in "$UT"/claude* "$UT"/.claude*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ "${e##*/}" = "claude-$DCS_UID" ] && continue
    printf '%s\n' "$e" >> "$DCS_WORK/ut.paths"
    n=$((n + 1))
    m="$(dcs_mtime "$e")"
    [ -n "$m" ] && { [ -z "$oldest" ] || [ "$m" -lt "$oldest" ]; } && oldest="$m"
  done
  [ "$n" -gt 0 ] || return 0
  dcs_measure "$DCS_WORK/ut.paths" > "$DCS_WORK/ut.sized"
  local p kib size ident total=0 short=""
  while IFS="$S" read -r p kib size ident; do
    case "$kib" in ''|*[!0-9]*) short=1 ;; *) total=$((total + kib)) ;; esac
    [ "$size" = measured ] || short=1
  done < "$DCS_WORK/ut.sized"
  dcs_note "$n entries in the user temp folder are named for Claude Code or this config, holding $([ -n "$short" ] && printf 'at least ')$(dcu_human "$total"), the oldest from $(dcs_date "${oldest:-0}"). None is offered: each is a hook's or a test run's working file, read by the run that made it."
}

case "${1:-}" in
  scan) do_scan ;;
  judge) echo "not offerable: the user temp folder's Claude named entries are working files of hooks and test runs, read by the run that made them, so none is offered" ;;
  *) echo "usage: claude-user-temp.sh scan | claude-user-temp.sh judge <target>" >&2; exit 2 ;;
esac
