#!/usr/bin/env bash
#
# xcode.sh: disk-clean's Xcode build cache category (claude-config#1806). See scan-lib.sh for the
# module calls.
#
# Every folder directly in ~/Library/Developer/Xcode/DerivedData, classified by
# hooks/derived-data-sweep.sh --classify, the same rule its automatic sweep and --remove-one use, so
# this category can never disagree with them (L370):
#   orphan        its project folder is gone: offered through the sweep (method derived-data), which
#                 judges it again under its own lock before removing it
#   live          its project is still on disk: offered separately, by deleting it, and only while no
#                 xcodebuild is running; Xcode rebuilds it on the next build
#   in-use        an orphan a build may still be using: not offered
#   shared-cache  ModuleCache.noindex and the like, every project's: not offered
#   unattributed  nothing says which project made it: not offered
# A sweep that cannot classify makes the whole category unmeasured.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

DD="$HOME/Library/Developer/Xcode/DerivedData"

# Sets XB to running, none or unknown.
xcodebuild_state() {
  pgrep -x xcodebuild >/dev/null 2>&1 </dev/null
  case $? in 0) XB=running ;; 1) XB=none ;; *) XB=unknown ;; esac
}
# Writes the sweep's lines for the folders in "$@" to <out>; fails setting DCS_WHY.
classify() { # <out> <folder>...
  local out="$1" rc; shift
  "${DISK_CLEAN_DERIVED_DATA_SWEEP:-$DCS_HOOKS/derived-data-sweep.sh}" --classify "$@" > "$out" 2>&1 </dev/null; rc=$?
  [ "$rc" -eq 0 ] && return 0
  DCS_WHY="exit $rc: $(awk 'NR == 1' "$out")"
  return 1
}
# Sets V, M (method) and D (detail) from one line of the sweep.
rules() { # <verdict> <detail>
  M=delete; D="$2"
  case "$1" in
    orphan) M=derived-data; V=offerable; D="its project folder is gone ($2)" ;;
    live)
      D="its project is still on disk ($2); Xcode rebuilds it on the next build"
      case "$XB" in
        none) V=offerable ;;
        running) V="not offerable: xcodebuild is running, and it may be building into this folder" ;;
        *) V="unmeasured: could not tell whether xcodebuild is running" ;;
      esac ;;
    in-use) M=derived-data; V="not offerable: a build may still be using it ($2)" ;;
    shared-cache) V="not offerable: it is a cache every project shares" ;;
    unattributed) V="not offerable: nothing says which project made it ($2)" ;;
    refused) V="not offerable: it is not a folder directly inside the DerivedData folder" ;;
    *) V="unmeasured: the Xcode build cache sweep answered '$1'" ;;
  esac
}

do_scan() {
  [ -d "$DD" ] || return 0
  local d n=0
  : > "$DCS_WORK/xcode.paths"
  for d in "$DD"/*/; do [ -d "$d" ] || continue; printf '%s\n' "${d%/}" >> "$DCS_WORK/xcode.paths"; n=$((n + 1)); done
  [ "$n" -gt 0 ] || return 0
  set --; while IFS= read -r d; do set -- "$@" "$d"; done < "$DCS_WORK/xcode.paths"
  if ! classify "$DCS_WORK/xcode.classes" "$@"; then
    dcs_status "unmeasured: the Xcode build cache sweep could not classify its folders ($DCS_WHY)"
    return 0
  fi
  xcodebuild_state
  dcs_measure "$DCS_WORK/xcode.paths" > "$DCS_WORK/xcode.sized"
  local p kib size ident verdict detail
  while IFS="$S" read -r p kib size ident; do
    verdict="$(awk -F '\t' -v p="$p" '$2 == p { print $1; exit }' "$DCS_WORK/xcode.classes")"
    detail="$(awk -F '\t' -v p="$p" '$2 == p { print $3; exit }' "$DCS_WORK/xcode.classes")"
    rules "${verdict:-missing}" "$detail"
    dcs_item "$p" "$M" "$kib" "$size" "$V" "" "$D" "$ident"
  done < "$DCS_WORK/xcode.sized"
}

do_judge() { # <target>
  local t="${1%/}" line
  classify "$DCS_WORK/xcode.one" "$t" || { echo "unmeasured: the Xcode build cache sweep could not classify it ($DCS_WHY)"; return 0; }
  line="$(awk 'NR == 1' "$DCS_WORK/xcode.one")"
  xcodebuild_state
  rules "${line%%$TAB*}" "$(printf '%s' "$line" | awk -F '\t' '{ print $3 }')"
  echo "$V"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) do_judge "${2:-}" ;;
  *) echo "usage: xcode.sh scan | xcode.sh judge <target>" >&2; exit 2 ;;
esac
