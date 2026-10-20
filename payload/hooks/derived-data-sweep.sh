#!/usr/bin/env bash
#
# derived-data-sweep.sh: list the Xcode build caches whose project folder is gone, and delete them
# when told to or when the low free space warning fires (claude-config#1369).
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
# WHAT IT DOES BY DEFAULT IS LIST. Deleting on its own is Dan's decision, made on #1369 on
# 2026-10-20 (L9): when the low free space warning fires it clears the orphans without asking and
# reports the space freed. The warning runs inside a 10 second hook timeout, so it never deletes in
# its own time: --start takes the lock and hands the work to a detached --auto, and the warning reads
# what the LAST sweep did with --last. FREE_SPACE_DERIVED_DATA_AUTO_DELETE=0 (read by
# free-space-nudge.sh) turns that off for one Mac and the warning falls back to --summary. Usage:
#
#   derived-data-sweep.sh            list every folder, grouped by what the rule decided, and delete
#                                    nothing
#   derived-data-sweep.sh --delete   delete the orphans nothing is using, judged again one by one
#                                    just before each removal, and report the gain df measured
#   derived-data-sweep.sh --summary  one short paragraph for the low free space warning, or nothing
#                                    on a Mac with no DerivedData
#   derived-data-sweep.sh --start    take the lock and start a detached --delete that records what it
#                                    did; returns at once. Exit 0 started, 75 one is already running
#                                    (so none was started), 3 no DerivedData on this Mac (nothing to
#                                    sweep), 2 it could not start one
#   derived-data-sweep.sh --last     one paragraph saying what the last automatic sweep did, freed or
#                                    failed, or that it died before recording; nothing when none has run
#   derived-data-sweep.sh --auto     the detached sweep itself, only ever started by --start, which
#                                    holds the lock it runs under; run by hand it refuses
#
# Two automatic sweeps never run at once ("assume it runs twice"): --start takes an flock on
# STATE/lock BEFORE handing off, and the detached sweep inherits that lock, so it is held exactly as
# long as the sweep lives and is released by the kernel however it ends, a kill included (L409). What
# a sweep did goes in STATE/last-result (written whole, then renamed into place), its full output in
# STATE/run-<started>-<pid>.log (the newest five kept), and while it runs STATE/in-progress says when
# it started. An in-progress mark nobody holds the lock for is a sweep that died partway, and --last
# says so rather than reading as no sweep at all (L13, L98).
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
# 2 refused (an argument or setting it does not know, or a DerivedData folder it cannot read), or
# --start could not start a sweep; and for --start only, 3 no DerivedData on this Mac, so nothing was
# started, and 75 a sweep is already running, so no second one was started.
#
# Environment (every one a seam the suite sets, so no test reads this Mac, L2):
#   XCODE_DERIVED_DATA_ROOT        the DerivedData folder (lib/derived-data.sh)
#   DERIVED_DATA_RECENT_MINUTES    the in use window, default 60 (lib/derived-data.sh)
#   DERIVED_DATA_PS                the process list program, default ps (lib/derived-data.sh)
#   DERIVED_DATA_DF_VOLUME         the volume df measures for --delete (default the data volume)
#   DERIVED_DATA_SUMMARY_SECONDS   how long --summary may spend sizing, default 4, so the prompt hook
#                                  carrying it stays inside its 10 second timeout; 0 skips sizing
#   DERIVED_DATA_SWEEP_STATE_DIR   where the automatic sweep keeps its lock, record and logs (default
#                                  ~/.claude/state/derived-data-sweep, which is never synced)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/derived-data.sh
. "$DIR/lib/derived-data.sh" || { echo "derived-data-sweep: lib/derived-data.sh is missing beside it, so it decided nothing."; exit 2; }

SWEEP_CMD="bash ~/.claude/hooks/derived-data-sweep.sh"

refuse() { echo "derived-data-sweep: $1"; exit 2; }
is_number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

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

MODE=list
for arg in "$@"; do
  case "$arg" in
    --delete|--summary|--start|--last|--auto)
      [ "$MODE" = list ] || refuse "only one of --delete, --summary, --start, --last and --auto can be given, so it did nothing."
      MODE="${arg#--}" ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) refuse "it does not know the argument '$arg' (the only ones are --delete, --summary, --start, --last and --auto), so it listed and deleted nothing." ;;
  esac
done

# ---------- the automatic sweep: its lock, its record, and what the next warning reads ----------
STATE_DIR="${DERIVED_DATA_SWEEP_STATE_DIR:-${HOME}/.claude/state/derived-data-sweep}"
LOCK="$STATE_DIR/lock"
RECORD="$STATE_DIR/last-result"
IN_PROGRESS="$STATE_DIR/in-progress"

# Succeeds when nobody holds the lock. A missing lock file is a free lock; a lock that cannot be
# opened at all is reported as held, so an unreadable state never reads as a sweep that died (L11).
lock_is_free() {
  [ -e "$LOCK" ] || return 0
  perl -e 'use Fcntl qw(:flock); open(my $fh, "<", $ARGV[0]) or exit 1; flock($fh, LOCK_EX | LOCK_NB) ? exit 0 : exit 1;' "$LOCK" 2>/dev/null
}

age_words() {   # age_words <seconds>
  local s="${1:-}"
  is_number "$s" || { printf 'at a time not recorded'; return 0; }
  if [ "$s" -lt 60 ]; then printf 'less than a minute ago'
  elif [ "$s" -lt 3600 ]; then printf '%s minute(s) ago' "$((s / 60))"
  elif [ "$s" -lt 86400 ]; then printf '%s hour(s) ago' "$((s / 3600))"
  else printf '%s day(s) ago' "$((s / 86400))"
  fi
}

# Reads a record of key=value lines into REC_<key>, taking only the keys it knows and only numbers
# where a number is meant (L50): a value that fails is left empty and the sentence says unknown.
read_record() {   # read_record <file>
  local k v
  REC_started="" REC_finished="" REC_exit="" REC_log="" REC_died="" REC_no_root="" REC_orphans=""
  REC_deleted="" REC_failed="" REC_du_kib="" REC_df_before_mb="" REC_df_after_mb="" REC_volume=""
  [ -r "$1" ] || return 1
  while IFS='=' read -r k v; do
    case "$k" in
      started|finished|exit|died|no_root|orphans|deleted|failed|du_kib|df_before_mb|df_after_mb)
        is_number "$v" && printf -v "REC_$k" '%s' "$v" ;;
      log|volume) printf -v "REC_$k" '%s' "$v" ;;
    esac
  done < "$1"
  return 0
}

log_words() { [ -n "$REC_log" ] && printf ' What it said is in %s' "$REC_log"; return 0; }

last_report() {
  local now ip1 ip2 gain lead
  now="$(date +%s)"
  # A sweep marked in progress that holds no lock died partway. Read the mark, test the lock, read the
  # mark again: a sweep finishing or starting in between changes the mark, so only a mark that stayed
  # the same with nobody holding the lock is called a death.
  ip1="$(cat "$IN_PROGRESS" 2>/dev/null || true)"
  if [ -n "$ip1" ] && lock_is_free; then
    ip2="$(cat "$IN_PROGRESS" 2>/dev/null || true)"
    if [ "$ip1" = "$ip2" ]; then
      read_record "$IN_PROGRESS"
      echo "The last automatic sweep of Xcode build caches, started $(age_words "$((now - ${REC_started:-now}))"), stopped before recording what it did, so what it deleted is not known.$(log_words)"
      return 0
    fi
  fi
  [ -e "$RECORD" ] || return 0
  # A death recorded by --start carries no exit code (the sweep never wrote one), so it is read before
  # the exit code is required, or every death would read as a record nobody can parse (L11).
  if read_record "$RECORD" && [ "$REC_died" = 1 ]; then
    echo "The last automatic sweep of Xcode build caches, started $(age_words "$((now - ${REC_started:-now}))"), stopped before recording what it did, so what it deleted is not known.$(log_words)"
    return 0
  fi
  if [ -z "$REC_exit" ]; then
    echo "The record of the last automatic sweep of Xcode build caches, $RECORD, could not be read, so what it did is not known."
    return 0
  fi
  lead="The last automatic sweep of Xcode build caches, which finished $(age_words "$((now - ${REC_finished:-now}))"),"
  case "$REC_exit" in
    0)
      if [ "$REC_no_root" = 1 ]; then
        echo "$lead found no Xcode build output on this Mac to sweep."
      elif [ "${REC_orphans:-0}" -eq 0 ] || [ "${REC_deleted:-0}" -eq 0 ]; then
        echo "$lead found no orphaned folder that nothing was using, so it deleted nothing.$(log_words)"
      elif [ -n "$REC_df_before_mb" ] && [ -n "$REC_df_after_mb" ]; then
        gain=$((REC_df_after_mb - REC_df_before_mb))
        if [ "$gain" -gt 0 ]; then
          echo "$lead deleted $REC_deleted of $REC_orphans orphaned folder(s), about $(human_size "$REC_du_kib") by du, and df measured a gain of $gain MB on ${REC_volume:-the data volume}.$(log_words)"
        else
          echo "$lead deleted $REC_deleted of $REC_orphans orphaned folder(s), about $(human_size "$REC_du_kib") by du, but df measured no gain on ${REC_volume:-the data volume} ($REC_df_before_mb MB before, $REC_df_after_mb MB after): what du counted was clones or hard links, or something else wrote as much meanwhile.$(log_words)"
        fi
      else
        echo "$lead deleted $REC_deleted of $REC_orphans orphaned folder(s), about $(human_size "$REC_du_kib") by du. df could not be read before and after, so how much it freed is not known.$(log_words)"
      fi ;;
    1)
      echo "$lead FAILED: it could not delete ${REC_failed:-some} of ${REC_orphans:-the} orphaned folder(s), so part of them may be left (it deleted ${REC_deleted:-none}).$(log_words)" ;;
    *)
      echo "$lead FAILED (it exited $REC_exit), so it may have deleted nothing.$(log_words)" ;;
  esac
  return 0
}

start_sweep() {
  local now log rc
  # Nothing to sweep on a Mac without Xcode output, and a warning there should say nothing about it.
  [ -e "$(derived_data_root)" ] || exit 3
  mkdir -p "$STATE_DIR" 2>/dev/null || { echo "derived-data-sweep: could not make $STATE_DIR, so no sweep was started."; exit 2; }
  now="$(date +%s)"
  log="$STATE_DIR/run-$now-$$.log"
  # perl because it can take an flock and keep it across exec, which no shell builtin here can. The
  # lock is taken BEFORE the fork, so a second --start is refused from that instant (exit 75). A mark
  # left by a sweep that died is turned into its record first, while the lock proves nobody owns it.
  # The child starts a session of its own (so the hook's timeout, which kills its process group,
  # cannot reach it) with stdin from /dev/null and stdout and stderr in its log (so it holds nothing
  # of the hook's capture open, L235, L240), and the parent writes the in-progress mark before it
  # returns, so whoever asks next sees the sweep that is running.
  perl -e '
    use Fcntl qw(:flock); use POSIX ();
    my ($lock, $mark, $record, $log, $now, @cmd) = @ARGV;
    $^F = 255;
    open(my $fh, ">>", $lock) or do { print "derived-data-sweep: could not open its lock $lock ($!), so no sweep was started.\n"; exit 2 };
    flock($fh, LOCK_EX | LOCK_NB) or exit 75;
    if (open(my $old, "<", $mark)) {
      local $/; my $text = <$old>; close($old);
      if (open(my $out, ">", "$record.tmp.$$")) { print $out $text, "died=1\n"; close($out); rename("$record.tmp.$$", $record); }
      unlink($mark);
    }
    # Written BEFORE the fork: a sweep with nothing to do can finish, and remove its mark, before a
    # parent writing it afterwards would get there, leaving a mark that reads as a sweep that died.
    open(my $m, ">", "$mark.tmp.$$") or do { print "derived-data-sweep: could not write $mark ($!), so no sweep was started.\n"; exit 2 };
    print $m "started=$now\nlog=$log\n"; close($m);
    rename("$mark.tmp.$$", $mark) or do { print "derived-data-sweep: could not write $mark ($!), so no sweep was started.\n"; exit 2 };
    my $pid = fork();
    defined $pid or do { unlink($mark); print "derived-data-sweep: could not start a process ($!), so no sweep was started.\n"; exit 2 };
    if ($pid == 0) {
      POSIX::setsid();
      open(STDIN, "<", "/dev/null");
      open(STDOUT, ">", $log) or POSIX::_exit(127);
      open(STDERR, ">&", \*STDOUT);
      $ENV{DERIVED_DATA_SWEEP_LOCKED} = 1;
      $ENV{DERIVED_DATA_SWEEP_LOG} = $log;
      $ENV{DERIVED_DATA_SWEEP_STARTED} = $now;
      exec(@cmd) or POSIX::_exit(127);
    }
    exit 0;' "$LOCK" "$IN_PROGRESS" "$RECORD" "$log" "$now" bash "$0" --auto
  rc=$?
  case "$rc" in
    0)
      # The newest five logs are kept; the record names the one it came from.
      find "$STATE_DIR" -maxdepth 1 -name 'run-*.log' 2>/dev/null | sort -r | tail -n +6 | while IFS= read -r old; do rm -f "$old"; done
      exit 0 ;;
    75) echo "derived-data-sweep: a sweep is already running (it holds $LOCK), so it did not start another."; exit 75 ;;
    *) exit 2 ;;
  esac
}

case "$MODE" in
  last) [ -d "$STATE_DIR" ] || exit 0; last_report; exit 0 ;;
  start) start_sweep ;;
  auto)
    [ "${DERIVED_DATA_SWEEP_LOCKED:-}" = 1 ] || refuse "--auto runs only under the lock --start takes, so it deleted nothing. To delete by hand: $SWEEP_CMD --delete"
    AUTO_STARTED="${DERIVED_DATA_SWEEP_STARTED:-}"
    # The record is written however the run ends, a refusal included, so the next warning can say a
    # sweep failed rather than finding nothing (L13). It goes in whole and is renamed into place, and
    # the in-progress mark goes only after it, so a reader never sees neither.
    auto_record() {
      local rc="$1" tmp="$RECORD.tmp.$$"
      {
        printf 'started=%s\nfinished=%s\nexit=%s\nlog=%s\n' "$AUTO_STARTED" "$(date +%s)" "$rc" "${DERIVED_DATA_SWEEP_LOG:-}"
        [ "${NO_ROOT:-0}" = 1 ] && printf 'no_root=1\n'
        if [ "${PASS_DONE:-0}" = 1 ]; then
          printf 'orphans=%s\ndeleted=%s\nfailed=%s\ndu_kib=%s\nvolume=%s\n' "$orphan_n" "$deleted_n" "$failed_n" "$deleted_kib" "$DF_VOLUME"
          [ -n "${df_before:-}" ] && printf 'df_before_mb=%s\n' "$df_before"
          [ -n "${df_after:-}" ] && printf 'df_after_mb=%s\n' "$df_after"
        fi
      } > "$tmp" 2>/dev/null && mv -f "$tmp" "$RECORD"
      rm -f "$IN_PROGRESS"
    }
    trap 'auto_record $?' EXIT
    echo "Automatic sweep started by the low free space warning, $(date '+%Y-%m-%d %H:%M %Z')."
    MODE=delete ;;
esac

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
  NO_ROOT=1
  echo "There is no Xcode build output on this Mac to look at (nothing at $ROOT)."
  exit 0
fi
if [ ! -d "$ROOT" ] || [ ! -r "$ROOT" ] || [ ! -x "$ROOT" ]; then
  refuse "could not read $ROOT, so nothing here says which build caches are orphaned."
fi

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
  # 0 skips the sizing: handed to perl's alarm it would mean no bound at all.
  total=""
  [ "$SUMMARY_SECONDS" -gt 0 ] && total="$(bounded_total_kib "$SUMMARY_SECONDS" "${orphans[@]}")"
  if [ "$SUMMARY_SECONDS" -eq 0 ]; then
    size_words="not sized (DERIVED_DATA_SUMMARY_SECONDS is 0)"
  elif [ -n "$total" ]; then
    size_words="about $(human_size "$total") by du, an upper bound on what deleting them frees"
  else
    size_words="sizing them did not finish within ${SUMMARY_SECONDS}s, so how much they hold is not known here"
  fi
  echo "Xcode build caches whose project folder is gone: ${#orphans[@]} folder(s), $size_words."
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
# From here on the counts are real, so an automatic sweep's record may carry them.
PASS_DONE=1

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
    echo "To delete the $orphan_n orphaned folder(s) listed first (the low free space warning also does this on its own, unless FREE_SPACE_DERIVED_DATA_AUTO_DELETE is 0 on this Mac):"
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
