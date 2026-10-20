#!/usr/bin/env bash
#
# derived-data-sweep.sh: list the Xcode build caches whose project folder is gone, and delete them
# only when told to (claude-config#1369).
#
# Xcode keeps one build cache per project PATH under ~/Library/Developer/Xcode/DerivedData. Every
# agent worktree, scratch copy and temporary gate tree is a new path, so each starts a cache of its
# own (about 2.5 GB for Overture), and nothing removes it when the path is deleted. On 2026-10-19
# Daniels-MacBook-Pro-2 held 30 of them, about 48.6 GB, every one keyed to a path that no longer
# existed. Overture already reclaimed its own, but only when its own suite ran, and no other project
# reclaimed anything.
#
# Which folders are orphans is decided in ONE place, lib/derived-data.sh, lifted from Overture's
# tested copy rather than written again (L370). This file only reports that decision and, with
# --delete, acts on it.
#
# WHAT IT DOES BY DEFAULT IS LIST. Whether the sweep may delete on its own is Dan's decision and has
# not been made (L9), so nothing runs --delete automatically: the low free space warning carries
# only --summary. Usage:
#
#   derived-data-sweep.sh            list every folder, grouped by what the rule decided, and delete
#                                    nothing
#   derived-data-sweep.sh --delete   delete the orphans nothing is using, judged again one by one
#                                    just before each removal, and report the gain df measured
#   derived-data-sweep.sh --summary  one short paragraph for the low free space warning, or nothing
#                                    on a Mac with no DerivedData
#
# What is never deleted, whatever the flag: a folder whose project is still on disk; one whose
# project is on a volume that is not mounted (an unplugged drive is not a deleted worktree); one with
# no info.plist or no usable WorkspacePath, which nothing can attribute; one with anything modified
# in the last DERIVED_DATA_RECENT_MINUTES or named by a running xcodebuild; and the shared caches
# (ModuleCache.noindex and the like), which every project uses.
#
# --delete reports `df -m` before and after, because `du` counts APFS clones and hard links in full
# and so states an upper bound, never the gain. A delete that frees nothing df can see says so,
# rather than reporting the du figure as space recovered (L93, L98).
#
# Exit codes: 0 done (a list, a summary, or every removal worked); 1 at least one removal failed;
# 2 refused (an argument or setting it does not know, or a DerivedData folder it cannot read).
#
# Environment (every one a seam the suite sets, so no test reads this Mac, L2):
#   XCODE_DERIVED_DATA_ROOT        the DerivedData folder (lib/derived-data.sh)
#   DERIVED_DATA_RECENT_MINUTES    the in use window, default 60 (lib/derived-data.sh)
#   DERIVED_DATA_PS                the process list program, default ps (lib/derived-data.sh)
#   DERIVED_DATA_DF_VOLUME         the volume df measures for --delete (default the data volume)
#   DERIVED_DATA_SUMMARY_SECONDS   how long --summary may spend sizing, default 4, so the prompt hook
#                                  carrying it stays inside its 10 second timeout
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/derived-data.sh
. "$DIR/lib/derived-data.sh" || { echo "derived-data-sweep: lib/derived-data.sh is missing beside it, so it decided nothing."; exit 2; }

SWEEP_CMD="bash ~/.claude/hooks/derived-data-sweep.sh"

refuse() { echo "derived-data-sweep: $1"; exit 2; }
is_number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

MODE=list
for arg in "$@"; do
  case "$arg" in
    --delete) [ "$MODE" = list ] || refuse "--delete and --summary cannot be given together, so it did nothing."; MODE=delete ;;
    --summary) [ "$MODE" = list ] || refuse "--delete and --summary cannot be given together, so it did nothing."; MODE=summary ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) refuse "it does not know the argument '$arg' (the only ones are --delete and --summary), so it listed and deleted nothing." ;;
  esac
done

RECENT="${DERIVED_DATA_RECENT_MINUTES-60}"
SUMMARY_SECONDS="${DERIVED_DATA_SUMMARY_SECONDS:-4}"
is_number "$RECENT" || refuse "DERIVED_DATA_RECENT_MINUTES is set to '$RECENT', which is not a number, so it listed and deleted nothing."
is_number "$SUMMARY_SECONDS" || refuse "DERIVED_DATA_SUMMARY_SECONDS is set to '$SUMMARY_SECONDS', which is not a number, so it listed and deleted nothing."
export DERIVED_DATA_RECENT_MINUTES="$RECENT"

ROOT="$(derived_data_root)"
if [ ! -e "$ROOT" ]; then
  # Finding nothing to look at is its own outcome, never a clean sweep (L98). The summary says
  # nothing, because a Mac without Xcode output has nothing to add to a disk warning.
  [ "$MODE" = summary ] && exit 0
  echo "There is no Xcode build output on this Mac to look at (nothing at $ROOT)."
  exit 0
fi
if [ ! -d "$ROOT" ] || [ ! -r "$ROOT" ] || [ ! -x "$ROOT" ]; then
  refuse "could not read $ROOT, so nothing here says which build caches are orphaned."
fi

# A KiB count in the unit a person reads.
human_size() {
  local kib="${1:-}"
  is_number "$kib" || { printf 'size unknown'; return 0; }
  if [ "$kib" -ge 1048576 ]; then
    awk -v k="$kib" 'BEGIN { printf "%.1f GB", k / 1048576 }'
  elif [ "$kib" -ge 1024 ]; then
    printf '%s MB' "$((kib / 1024))"
  else
    printf '%s KB' "$kib"
  fi
}

# The newest of the folder's own date and its info.plist's, as a local date and time. GNU stat
# first, then BSD, as check-free-space.sh does; BSD date first, then GNU, because GNU's `date -r`
# reads a FILE and fails on a number, while BSD's -d means something else entirely.
last_modified() {
  local dir="$1" newest="" t f
  for f in "$dir" "$dir/info.plist"; do
    [ -e "$f" ] || continue
    t="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || true)"
    is_number "$t" || continue
    if [ -z "$newest" ] || [ "$t" -gt "$newest" ]; then newest="$t"; fi
  done
  [ -n "$newest" ] || { printf 'unknown'; return 0; }
  date -r "$newest" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$newest" '+%Y-%m-%d %H:%M' 2>/dev/null || printf 'unknown'
}

# Sizes several folders in KiB within a bound, printing the total or nothing when the bound ran out.
# The alarm is set on du itself in a forked child, the pattern claude-sync's scratch sizing uses, so
# the bound holds whatever happens to this script.
bounded_total_kib() {
  local seconds="$1"; shift
  [ "$#" -gt 0 ] || { printf '0'; return 0; }
  local out rc=0
  out="$(perl -e '
    my $t = shift @ARGV;
    my $pid = open(my $fh, "-|") // exit 127;
    if ($pid == 0) { alarm $t; exec("du", "-sk", @ARGV) or exit 127; }
    my $sum = 0; while (<$fh>) { $sum += $1 if /^(\d+)/; }
    close($fh);
    exit 124 if ($? & 127) == 14;
    print $sum;' "$seconds" "$@" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 124 ] && return 0
  is_number "$out" && printf '%s' "$out"
  return 0
}

# ---------- the summary, for the low free space warning ----------
if [ "$MODE" = summary ]; then
  orphans=() checked=0
  for dir in "$ROOT"/*/; do
    dir="${dir%/}"
    [ -d "$dir" ] || continue
    verdict="$(derived_data_classify "$dir")"
    [ "$verdict" = shared-cache ] && continue
    checked=$((checked + 1))
    [ "$verdict" = orphan ] && orphans+=("$dir")
  done
  if [ "${#orphans[@]}" -eq 0 ]; then
    echo "No Xcode build cache is orphaned ($checked folder(s) checked)."
    exit 0
  fi
  total="$(bounded_total_kib "$SUMMARY_SECONDS" "${orphans[@]}")"
  if [ -n "$total" ]; then
    size_words="about $(human_size "$total") by du, an upper bound on what deleting them frees"
  else
    size_words="sizing them did not finish within ${SUMMARY_SECONDS}s, so how much they hold is not known here"
  fi
  echo "Xcode build caches whose project folder is gone: ${#orphans[@]} folder(s), $size_words. Deleting them is Dan's call; nothing deletes them on its own."
  echo "To list them, with the project each belonged to and which a build may still be using:"
  echo "$SWEEP_CMD"
  echo "To delete the ones nothing is using:"
  echo "$SWEEP_CMD --delete"
  exit 0
fi

# ---------- one pass over every folder, for the list and for --delete ----------
# The data volume is where the home folder lives; / is the read only system snapshot.
DF_VOLUME="${DERIVED_DATA_DF_VOLUME:-}"
if [ -z "$DF_VOLUME" ]; then
  if [ -d /System/Volumes/Data ]; then DF_VOLUME=/System/Volumes/Data; else DF_VOLUME=/; fi
fi
df_mb() {
  local mb
  mb="$(df -Pm "$DF_VOLUME" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  is_number "$mb" && printf '%s' "$mb"
  return 0
}

total=0
orphan_lines="" orphan_n=0 orphan_kib=0
inuse_lines="" inuse_n=0
noplist_lines="" noplist_n=0 noplist_kib=0
unmounted_lines="" unmounted_n=0
nopath_lines="" nopath_n=0
live_n=0 shared_n=0
deleted_n=0 deleted_kib=0 failed_n=0 delete_lines=""

df_before=""
[ "$MODE" = delete ] && df_before="$(df_mb)"

for dir in "$ROOT"/*/; do
  dir="${dir%/}"
  [ -d "$dir" ] || continue
  total=$((total + 1))
  verdict="$(derived_data_classify "$dir")"
  case "$verdict" in
    shared-cache) shared_n=$((shared_n + 1)) ;;
    live) live_n=$((live_n + 1)) ;;
    orphan)
      ws="$(derived_data_workspace_path "$dir")"
      if reason="$(derived_data_in_use "$dir")"; then
        inuse_n=$((inuse_n + 1))
        inuse_lines="$inuse_lines  $dir  $reason, project was $ws
"
        continue
      fi
      kib="$(derived_data_size_kib "$dir")"
      orphan_n=$((orphan_n + 1))
      is_number "$kib" && orphan_kib=$((orphan_kib + kib))
      orphan_lines="$orphan_lines  $(human_size "$kib")  $dir  last modified $(last_modified "$dir")  project was $ws
"
      if [ "$MODE" = delete ]; then
        err="$(derived_data_remove_if_reclaimable "$dir" 2>&1 >/dev/null)" && removed=1 || removed=0
        if [ "$removed" -eq 1 ]; then
          deleted_n=$((deleted_n + 1))
          is_number "$kib" && deleted_kib=$((deleted_kib + kib))
          delete_lines="${delete_lines}Deleted $dir ($(human_size "$kib"), project was $ws)
"
        elif [ -n "$err" ]; then
          failed_n=$((failed_n + 1))
          delete_lines="${delete_lines}Could not delete $dir: some of it could not be removed, so part of it may be left.
"
        else
          delete_lines="${delete_lines}Kept $dir: judged again just before removing it, it was no longer an idle orphan.
"
        fi
      fi
      ;;
    *)
      why="$(derived_data_unreadable_reason "$dir")"
      case "$why" in
        no-info-plist)
          kib="$(derived_data_size_kib "$dir")"
          noplist_n=$((noplist_n + 1))
          is_number "$kib" && noplist_kib=$((noplist_kib + kib))
          noplist_lines="$noplist_lines  $(human_size "$kib")  $dir  last modified $(last_modified "$dir")
"
          ;;
        volume-not-mounted)
          unmounted_n=$((unmounted_n + 1))
          unmounted_lines="$unmounted_lines  $dir  project was $(derived_data_workspace_path "$dir")
"
          ;;
        *)
          nopath_n=$((nopath_n + 1))
          case "$why" in
            relative-path) why_words="its WorkspacePath is relative: $(derived_data_workspace_path "$dir")" ;;
            no-workspace-path) why_words="its info.plist has no WorkspacePath" ;;
            *) why_words="it could not be read" ;;
          esac
          nopath_lines="$nopath_lines  $dir  $why_words
"
          ;;
      esac
      ;;
  esac
done

echo "Xcode build caches under $ROOT: $total folder(s)."
echo ""
if [ "$MODE" = delete ]; then
  echo "Orphaned, their project folder is gone, and nothing is using them: $orphan_n, about $(human_size "$orphan_kib") by du."
else
  echo "Orphaned, their project folder is gone: $orphan_n, about $(human_size "$orphan_kib") by du. These are what --delete removes."
fi
printf '%s' "$orphan_lines"
if [ "$inuse_n" -gt 0 ]; then
  echo "Orphaned but kept, because a build may still be using them: $inuse_n"
  printf '%s' "$inuse_lines"
fi
if [ "$noplist_n" -gt 0 ]; then
  echo "Kept, no info.plist, so nothing says which project made them: $noplist_n, about $(human_size "$noplist_kib") by du"
  printf '%s' "$noplist_lines"
fi
if [ "$unmounted_n" -gt 0 ]; then
  echo "Kept, project on a volume that is not mounted: $unmounted_n"
  printf '%s' "$unmounted_lines"
fi
if [ "$nopath_n" -gt 0 ]; then
  echo "Kept, info.plist names no usable project path: $nopath_n"
  printf '%s' "$nopath_lines"
fi
[ "$live_n" -gt 0 ] && echo "Kept, project still on disk: $live_n"
[ "$shared_n" -gt 0 ] && echo "Shared caches (ModuleCache.noindex and the like), which every project uses and this never touches: $shared_n"
echo ""

if [ "$MODE" = list ]; then
  echo "Nothing was deleted."
  if [ "$orphan_n" -gt 0 ]; then
    echo "du counts APFS clones and hard links in full, so deleting them can free less than it says; --delete measures the real gain with df."
    echo "To delete the $orphan_n orphaned folder(s) listed first (Dan's call; nothing runs this on its own):"
    echo "$SWEEP_CMD --delete"
  fi
  exit 0
fi

# ---------- what --delete did, and what df says it freed ----------
if [ "$orphan_n" -eq 0 ]; then
  echo "Nothing was orphaned and idle, so nothing was deleted."
  exit 0
fi
printf '%s' "$delete_lines"
echo "Deleted $deleted_n of $orphan_n orphaned folder(s), about $(human_size "$deleted_kib") by du."
df_after="$(df_mb)"
if [ -n "$df_before" ] && [ -n "$df_after" ]; then
  gain=$((df_after - df_before))
  echo "Free space on $DF_VOLUME: $df_before MB before, $df_after MB after, a gain of $gain MB."
  if [ "$deleted_n" -gt 0 ] && [ "$gain" -le 0 ]; then
    echo "df saw no gain. Either what du counted was clones or hard links that cost the disk almost nothing, or something else wrote as much in the meantime. Take another df reading before deleting more of anything (the disk-full skill says how)."
  fi
else
  echo "Could not measure the gain: df did not answer for $DF_VOLUME before and after, so how much this freed is not known."
fi
[ "$failed_n" -eq 0 ] || exit 1
exit 0
