#!/usr/bin/env bash
#
# disk-remove.sh: the one place disk-full and disk-clean remove anything, and check that it went
# (claude-config#1805, phase 2 of the Disk cleanup skill milestone).
#
#   bash ~/.claude/hooks/lib/disk-remove.sh --plan <plan file>
#   bash ~/.claude/hooks/lib/disk-remove.sh --propose <trash|delete|truncate> <path>...
#
# --plan removes what a plan names. A plan never carries paths: it names a scan and the ids of the
# items Dan ticked in it, and every path, method and category comes from that scan's own record
# (lib/disk-clean-record.sh), so nothing can be removed that a scan did not measure and offer. The
# plan file, written by whoever relays Dan's choice:
#
#   scan_id <the scan's id>
#   count <how many items follow>
#   item <an item id from that scan>
#   item <...>
#
# Blank lines and lines starting with # are ignored; anything else is refused. A scan_id beginning
# "named-" is a record --propose wrote (state/disk-clean/named/<id>.json); any other is disk-clean's
# scan (state/disk-clean/last-scan.json), and must be the scan in that file now.
#
# --propose is how disk-full removes the folders and files Dan decided on by name. It measures each
# path, refuses the ones this tool never removes, writes a record of its own (category "named") and a
# plan, prints what it offered and refused, and names the --plan command to run once Dan has seen it.
# Its judge, run again before each removal, is that the path is still the same file system object it
# measured: the same device and inode, the same birth time (ctime where the file system keeps none)
# and, for every method but truncate, the same size. Device and inode alone are not enough, because
# a file system gives a deleted file's inode to the next file made (#1840, L1032). A path whose
# identity cannot be read is refused at --propose.
#
# EACH ITEM, IN ORDER (the plan's design, #1804 comment; L514): the identity deny list on the path
# as recorded, whatever the category; refuse a symbolic link and resolve the rest of the path
# physically; the deny list again on the physical path; the allowed root; already gone; measure its
# size; the category's own judge, run again now; for every method but truncate, an lsof open check,
# last of all, so nothing slow sits between it and the removal (#1872, L1034); write INTENT to the
# log; act; verify it is gone (or truncated); write OUTCOME. Nothing is acted on whose INTENT line
# could not be written.
#
# THE METHODS.
#   trash         "${DISK_CLEAN_TRASH:-/usr/bin/trash}" -s <path>, then the path must be gone. Moving
#                 to the Trash frees nothing until the Trash is emptied, and the report says so.
#                 /usr/bin/trash ships with macOS 15; without it the item is skipped saying so, and
#                 this NEVER falls back to deleting. Measured 2026-10-27: it ignores HOME and always
#                 uses the real ~/.Trash, and takes `--` as a file name, so no `--` is passed and every
#                 path given to it is absolute.
#   delete        rm -rf, then the path must be gone.
#   truncate      for a log a process holds open: emptied with tee, a guarded tool, never a bare `>`
#                 redirection, which the test harness's write guard cannot see. Verified by its size
#                 afterwards being smaller than before (a writer may have appended a line since).
#   worktree      git -C <path> worktree remove <path>, never --force, so git refuses a dirty one
#                 (measured 2026-10-27: it works when run from inside the worktree it removes).
#   docker        a target "image <ref>", "container <ref>" (not running) or "builder cache", removed
#                 by `docker image rm`, `docker container rm` or `docker builder prune -f`. Volumes are
#                 never removed, and "volume prune" and "system prune" are refused by name.
#   derived-data  hooks/derived-data-sweep.sh --remove-one <folder>, which takes the automatic sweep's
#                 own lock and judges the folder again with the orphan rule before removing it.
#
# THE JUDGE. A category is a module, payload/skills/disk-clean/categories/<category>.sh, run as
# `<module> judge <target>` with DISK_CLEAN_CATEGORY set to its name. It prints ONE line: `offerable`,
# `not offerable: <reason>` or `unmeasured: <reason>`. Only `offerable` proceeds; a failing judge,
# a missing module or any other answer skips the item, saying which.
#
# THE OPEN CHECK. lsof exits 1 for "not open", for a missing file and for "permission denied" alike
# (measured 2026-10-27, test-disk-clean-harness.sh), so any stderr from it, or any exit but 0 and 1,
# skips the item as "could not tell whether it is in use"; it never reads as free (L42). Directories
# are checked with lsof +D.
#
# THE RESULT. One line per item as it is done: removed, trashed, truncated, skipped: <reason> or
# failed: <error>. The totals are the sum of each item's own size, measured just before it went and
# checked gone after. The disk wide `df -m` change is printed as context only, with any local Time
# Machine snapshots named, because other programs write to the disk too (L375); no exit code depends
# on it. Exit 0 when every item was removed, trashed or truncated; 5 when any was skipped or failed;
# 2 refused before touching anything (a plan or record it cannot use, a test seam outside test mode,
# a test mode HOME outside the throwaway directory); 3 the scan is more than an hour old; 4 the plan's
# scan is not the last scan; 75 another disk-remove run holds the lock.
#
# STATE, all under ~/.claude/state/disk-clean (never synced):
#   last-scan.json, named/<id>.json   scan records; each removed, trashed, truncated or already gone
#                                     item is marked in its record before this exits, from the log,
#                                     so the low space warning never quotes it again
#   removals/<scan_id>.log            INTENT and OUTCOME lines, tab separated, appended; a run killed
#                                     midway leaves an INTENT with no OUTCOME, which the next run for
#                                     that scan reports and settles
#   remove.lock                       a symbolic link naming the pid of the run holding it; one whose
#                                     pid is not running is taken over
#
# TEST MODE. When DISK_CLEAN_TEST_ROOT is set, this refuses to run unless HOME is physically inside
# it by the harness's own predicate (lib/disk-clean-predicates.sh, dc_home_isolated), and only then
# honours the seams DISK_CLEAN_TRASH, DISK_CLEAN_JUDGE, DISK_CLEAN_DERIVED_DATA_SWEEP and
# DISK_CLEAN_CATEGORIES. Outside test mode any of those being set is refused. The allowed roots are
# HOME and TMPDIR, each inside the throwaway directory; outside test mode they are HOME, /private/tmp
# and /private/var/folders.
#
# bash 3.2 safe. Commands: awk cat date df du git docker lsof ln mkdir mktemp mv readlink rm stat tee
# tmutil, the trash and derived-data sweep above, and the category modules.
set -uo pipefail

LIB="${BASH_SOURCE[0]%/*}"; [ "$LIB" != "${BASH_SOURCE[0]}" ] || LIB=.
LIB="$(CDPATH= cd -P "$LIB" 2>/dev/null && pwd -P)" || { echo "disk-remove: cannot find its own folder, so it removed nothing."; exit 2; }
HOOKS="${LIB%/*}"
. "$LIB/disk-clean-predicates.sh" || { echo "disk-remove: lib/disk-clean-predicates.sh is missing beside it, so it removed nothing."; exit 2; }
. "$LIB/disk-clean-record.sh" || { echo "disk-remove: lib/disk-clean-record.sh is missing beside it, so it removed nothing."; exit 2; }
. "$LIB/disk-clean-units.sh" || { echo "disk-remove: lib/disk-clean-units.sh is missing beside it, so it removed nothing."; exit 2; }

refuse() { # <exit code> <reason>
  local code="$1"; shift
  printf 'disk-remove: %s\n' "$*"
  exit "$code"
}

S=$'\037'
T0="$(date +%s)" || refuse 2 "could not read the clock, so it removed nothing."
MAX_SCAN_AGE="$DCR_MAX_SCAN_AGE" # lib/disk-clean-record.sh, which the review page reads too

# ---------- arguments ----------
MODE="" PLAN="" PROPOSE_METHOD=""
case "${1:-}" in
  --plan)
    [ "$#" -eq 2 ] && [ -n "$2" ] || refuse 2 "--plan takes exactly one plan file, so it removed nothing."
    MODE=plan; PLAN="$2" ;;
  --propose)
    [ "$#" -ge 3 ] || refuse 2 "--propose takes a method (trash, delete or truncate) and at least one path, so it proposed nothing."
    MODE=propose; PROPOSE_METHOD="$2"; shift 2 ;;
  -h|--help) awk 'NR > 1 && /^set -uo/ { exit } NR > 1 { print }' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) refuse 2 "it needs --plan <file> or --propose <method> <path>..., so it removed nothing." ;;
esac

# ---------- test mode, and the seams it alone honours ----------
TEST_ROOT="${DISK_CLEAN_TEST_ROOT:-}"
if [ -n "$TEST_ROOT" ]; then
  dc_home_isolated "${HOME:-}" "$TEST_ROOT" || \
    refuse 2 "test mode (DISK_CLEAN_TEST_ROOT is $TEST_ROOT), but HOME ('${HOME:-}') is not inside that throwaway directory, so it removed nothing."
else
  [ -z "${DISK_CLEAN_TRASH+x}${DISK_CLEAN_JUDGE+x}${DISK_CLEAN_DERIVED_DATA_SWEEP+x}${DISK_CLEAN_CATEGORIES+x}" ] || \
    refuse 2 "a test seam (DISK_CLEAN_TRASH, DISK_CLEAN_JUDGE, DISK_CLEAN_DERIVED_DATA_SWEEP or DISK_CLEAN_CATEGORIES) is set, but DISK_CLEAN_TEST_ROOT is not, and the seams are honoured only in test mode, so it removed nothing."
fi
[ -n "${HOME:-}" ] || refuse 2 "HOME is not set, so it removed nothing."
HOME_PHYS="$(CDPATH= cd -P "$HOME" 2>/dev/null && pwd -P)" || refuse 2 "could not read the home folder $HOME, so it removed nothing."
CATEGORIES="${DISK_CLEAN_CATEGORIES:-$HOOKS/../skills/disk-clean/categories}"

# The roots an item must lie strictly inside.
if [ -n "$TEST_ROOT" ]; then
  ALLOW_TMP=""
  if [ -n "${TMPDIR:-}" ] && dc_inside "${TMPDIR%/}/x" "$TEST_ROOT"; then ALLOW_TMP="$(dc_resolve "${TMPDIR%/}")"; fi
  ALLOW_A="$ALLOW_TMP" ALLOW_B=""
else
  ALLOW_A=/private/tmp ALLOW_B=/private/var/folders
fi
allowed_root() { # <physical path>
  case "$1" in "$HOME_PHYS"/?*) return 0 ;; esac
  [ -n "$ALLOW_A" ] && case "$1" in "$ALLOW_A"/?*) return 0 ;; esac
  [ -n "$ALLOW_B" ] && case "$1" in "$ALLOW_B"/?*) return 0 ;; esac
  return 1
}

# ---------- the identity deny list: what this tool never removes, whatever the category says ----------
# Sets DENY to why, and succeeds, when <path> (physical or as recorded) is one of them; no
# substitution, since it runs twice for every item of a plan thousands long. The rest of a home
# dotfolder's contents are left to the category's judge (transcripts live in ~/.claude/projects, the
# Trash's entries in ~/.Trash), but the folder itself is never removed.
deny_reason() { # <path>
  local p="${1%/}" H="$HOME_PHYS" L="$HOME_PHYS/Library"
  case "$p" in
    ''|/) DENY='it is the root of the disk'; return 0 ;;
    "$H"|"$HOME") DENY='it is the home folder itself'; return 0 ;;
    /Applications|/Applications/*) DENY='it is under /Applications'; return 0 ;;
    /System|/System/*) DENY='it is under /System'; return 0 ;;
    /Library/Backblaze.bzpkg|/Library/Backblaze.bzpkg/*) DENY='it is the store of Backblaze, a backup client'; return 0 ;;
    "$L/Mobile Documents"|"$L/Mobile Documents/"*) DENY='it is in iCloud Drive (removing it removes it from iCloud on every device)'; return 0 ;;
    "$L/CloudStorage"|"$L/CloudStorage/"*) DENY='it is in a cloud storage folder (removing it removes it from the cloud)'; return 0 ;;
    "$L/Application Support/FileProvider"|"$L/Application Support/FileProvider/"*) DENY="it is the store of macOS's file provider, which every cloud client syncs through"; return 0 ;;
    "$L/Application Support/CloudDocs"|"$L/Application Support/CloudDocs/"*) DENY="it is iCloud Drive's own store"; return 0 ;;
    "$L/Mail"|"$L/Mail/"*|"$L/Containers/com.apple.mail"|"$L/Containers/com.apple.mail/"*) DENY='it is the Mail store'; return 0 ;;
    "$L/Messages"|"$L/Messages/"*|"$L/Containers/com.apple.MobileSMS"|"$L/Containers/com.apple.MobileSMS/"*) DENY='it is the Messages store'; return 0 ;;
    "$L/Application Support/SynologyDrive"|"$L/Application Support/SynologyDrive/"*|"$H/SynologyDrive"|"$H/SynologyDrive/"*) DENY='it is the store of Synology Drive, a sync client'; return 0 ;;
    "$L/Application Support/Dropbox"|"$L/Application Support/Dropbox/"*|"$H/.dropbox"|"$H/.dropbox/"*|"$H/Dropbox"|"$H/Dropbox/"*) DENY='it is the store of Dropbox, a sync client'; return 0 ;;
    "$L/Application Support/Google/DriveFS"|"$L/Application Support/Google/DriveFS/"*|"$H/Google Drive"|"$H/Google Drive/"*) DENY='it is the store of Google Drive, a sync client'; return 0 ;;
    "$L/Application Support/OneDrive"|"$L/Application Support/OneDrive/"*|"$L/Containers/com.microsoft.OneDrive"*|"$L/Group Containers/"*OneDrive*|"$H/OneDrive"|"$H/OneDrive/"*|"$H/OneDrive - "*) DENY='it is the store of OneDrive, a sync client'; return 0 ;;
    "$L/Application Support/Box"|"$L/Application Support/Box/"*|"$H/Box"|"$H/Box/"*) DENY='it is the store of Box, a sync client'; return 0 ;;
    "$L/Application Support/Backblaze"|"$L/Application Support/Backblaze/"*) DENY='it is the store of Backblaze, a backup client'; return 0 ;;
    "$L/Application Support/ArqAgent"|"$L/Application Support/ArqAgent/"*|"$L/Application Support/Arq"|"$L/Application Support/Arq/"*) DENY='it is the store of Arq, a backup client'; return 0 ;;
    "$L/Application Support/CrashPlan"|"$L/Application Support/CrashPlan/"*) DENY='it is the store of CrashPlan, a backup client'; return 0 ;;
    "$H/.pcloud"|"$H/.pcloud/"*|"$H/pCloud Drive"|"$H/pCloud Drive/"*) DENY='it is the store of pCloud, a sync client'; return 0 ;;
    "$H/.ssh"|"$H/.ssh/"*|"$H/.gnupg"|"$H/.gnupg/"*) DENY='it holds keys and credentials'; return 0 ;;
    "$H/.claude/state"|"$H/.claude/state/"*) DENY="it is Claude Code's own state, this tool's records among it"; return 0 ;;
    "$H/.local"|"$H/.cache"|"$H/.config"|"$H/.claude"|"$H/.docker"|"$H/.Trash"|"$H/.vscode"|"$H/.nvm"|"$H/.cargo"|"$H/.rustup")
      DENY="it is the dotfolder ${p##*/} itself, which this tool never removes whole"; return 0 ;;
    "$L"|"$L/Caches"|"$L/Containers"|"$L/Group Containers"|"$L/Application Support"|"$L/Developer"|"$H/Documents"|"$H/Desktop"|"$H/Downloads"|"$H/Movies"|"$H/Music"|"$H/Pictures"|"$H/Public"|"$H/Applications")
      DENY="it is the standard folder ${p#"$H"/} itself"; return 0 ;;
  esac
  case "$p/" in
    *.[aA][pP][pP]/*) DENY='it is an app package or inside one'; return 0 ;;
    *.photoslibrary/*|*.musiclibrary/*|*.tvlibrary/*|*.imovielibrary/*|*.aplibrary/*|*.fcpbundle/*)
      DENY='it is a Photos, Music, TV, iMovie, Aperture or Final Cut library or inside one'; return 0 ;;
    *.lrcat/*|*.lrdata/*|*.lrlibrary/*|*.lrcat-data/*|*.cocatalog/*|*.cosessiondb/*)
      DENY='it is a photo editor catalog or its previews, or inside one'; return 0 ;;
  esac
  case "$p" in
    *.lrcat|*.lrcat-wal|*.lrcat-shm|*.lrcat.lock) DENY='it is a photo editor catalog'; return 0 ;;
  esac
  return 1
}

# ---------- small readers ----------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/disk-remove.XXXXXXXX")" || refuse 2 "could not make a working folder under ${TMPDIR:-/tmp}, so it removed nothing."
LOCK="" LOCK_HELD=""
cleanup() {
  [ -n "$LOCK_HELD" ] && [ "$(readlink "$LOCK" 2>/dev/null)" = "$$" ] && rm -f "$LOCK"
  rm -rf "$WORK"
}
trap cleanup EXIT

human() { dcu_human "$@"; } # lib/disk-clean-units.sh

# Sets SIZE_KIB (empty when unread), SIZE_PARTIAL (1 when du said anything on stderr or failed, so
# the figure is a lower bound) and SIZE_WORDS, the same in words. Allocated blocks, as du -k reports
# them. The words come from lib/disk-clean-units.sh's dcu_human_to, the one size rule, which starts
# no process: this runs for every item.
measure() { # <path>
  local out
  out="$(du -sk "$1" </dev/null 2>"$WORK/err")"
  local rc=$?
  SIZE_KIB="${out%%[!0-9]*}"
  SIZE_PARTIAL=""
  if [ "$rc" -ne 0 ] || [ -s "$WORK/err" ]; then SIZE_PARTIAL=1; fi
  if [ -z "$SIZE_KIB" ]; then SIZE_WORDS='size could not be read'; return; fi
  dcu_human_to SIZE_WORDS "$SIZE_KIB"
  [ -z "$SIZE_PARTIAL" ] || SIZE_WORDS="at least $SIZE_WORDS"
}

# The one identity of a file system object, "v2:<device>:<inode>:<birth>:<ctime>:<size>" (#1840).
# Device and inode alone let a replacement pass as the original: a file system hands a deleted file's
# inode to the next file made, so a file written just after the original went routinely carries its
# device and inode (Linux CI did, run 40621284222; L1032). Birth time is what a replacement changes;
# where the file system keeps none, GNU stat prints 0 (or "-") for it, birth is left empty, and the
# judge compares ctime instead. Times keep their fractional seconds where stat gives them (GNU %.9W,
# BSD %FB), since a replacement can be made inside the second its original went; the whole second
# forms are asked for only when the fractional answer is unusable. Every stat asks GNU's -c first:
# GNU stat takes -f as file system status and answers it with exit 0. Prints nothing and fails when
# no answer is usable.
file_identity() { # <path>
  local raw
  raw="$(stat -c '%d:%i:%.9W:%.9Z:%s' "$1" 2>/dev/null || stat -f '%d:%i:%FB:%Fc:%z' "$1" 2>/dev/null)"
  identity_from_stat "$raw" && return 0
  raw="$(stat -c '%d:%i:%W:%Z:%s' "$1" 2>/dev/null || stat -f '%d:%i:%B:%c:%z' "$1" 2>/dev/null)"
  identity_from_stat "$raw"
}
identity_from_stat() { # <device:inode:birth:ctime:size, as stat printed it>
  local IFS=: dev ino birth ctime size extra
  read -r dev ino birth ctime size extra <<< "$1"
  case "$birth" in -|'?') birth="" ;; *[!0.]*) ;; *) birth="" ;; esac # 0, 0.000000000, "-" and "?" all mean not kept
  case "$dev$ino$size" in *[!0-9]*) return 1 ;; esac
  [ -n "$dev" ] && [ -n "$ino" ] && [ -n "$size" ] && [ -z "$extra" ] || return 1
  is_stat_time "$ctime" || return 1
  [ -z "$birth" ] || is_stat_time "$birth" || return 1
  printf 'v2:%s:%s:%s:%s:%s\n' "$dev" "$ino" "$birth" "$ctime" "$size"
}
is_stat_time() { case "$1" in ''|*[!0-9.]*|.*|*.|*.*.*) return 1 ;; esac; return 0; }

# Sets JUDGE_VERDICT for a named item from its recorded identity and the one read now, both v2.
identity_verdict() { # <recorded> <now> <method>
  local IFS=: rtag rdev rino rbirth rctime rsize rextra ntag ndev nino nbirth nctime nsize nextra
  read -r rtag rdev rino rbirth rctime rsize rextra <<< "$1"
  read -r ntag ndev nino nbirth nctime nsize nextra <<< "$2"
  if [ "$rtag" != v2 ] || [ -n "$rextra" ] || [ -z "$rdev" ] || [ -z "$rino" ] || [ -z "$rctime" ] || [ -z "$rsize" ]; then
    JUDGE_VERDICT="unmeasured: its record's identity ($1) is not in a shape this tool reads"; return
  fi
  if [ "$rdev:$rino" != "$ndev:$nino" ]; then
    JUDGE_VERDICT="not offerable: it is not the item that was proposed (device and inode were $rdev:$rino, now $ndev:$nino), so it was replaced since"
    return
  fi
  if [ -n "$rbirth" ] && [ -n "$nbirth" ]; then
    if [ "$rbirth" != "$nbirth" ]; then
      JUDGE_VERDICT="not offerable: it is not the item that was proposed (the same device and inode, but born at $rbirth and this one at $nbirth), so it was replaced since by a file given the old one's inode"
      return
    fi
  elif [ "$rctime" != "$nctime" ]; then
    JUDGE_VERDICT="not offerable: it is not the item that was proposed, or it was changed since (its ctime was $rctime, now $nctime, and this file system records no birth time to tell the two apart)"
    return
  fi
  # truncate is for a log a process is still writing to, so it growing is expected. On a file system
  # with no birth time its ctime moves with every write too, so there a log being written is skipped
  # above, which is the safe side; macOS keeps birth times.
  if [ "$3" != truncate ] && [ "$rsize" != "$nsize" ]; then
    JUDGE_VERDICT="not offerable: it changed size since it was proposed ($rsize bytes, now $nsize)"; return
  fi
  JUDGE_VERDICT=offerable
}
file_bytes() { # <path>
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}

# Sets OPEN_VERDICT to free, or to the reason the item is skipped.
open_check() { # <path>
  local out rc names
  if [ -d "$1" ]; then out="$(lsof +D "$1" </dev/null 2>"$WORK/err")"; rc=$?
  else out="$(lsof "$1" </dev/null 2>"$WORK/err")"; rc=$?; fi
  if [ -s "$WORK/err" ] || { [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; }; then
    OPEN_VERDICT="could not tell whether it is in use (lsof exited $rc$([ -s "$WORK/err" ] && printf ', and said: %s' "$(awk 'NR == 1' "$WORK/err")"))"
  elif [ "$rc" -eq 0 ]; then
    names="$(printf '%s\n' "$out" | awk 'NR > 1 && !seen[$1]++ { printf "%s%s", sep, $1; sep = ", " }')"
    OPEN_VERDICT="it is in use by ${names:-a running process}"
  else
    OPEN_VERDICT=free
  fi
}

# Sets JUDGE_VERDICT to the judge's one line, or to an unmeasured line saying why there is none.
run_judge() { # <category> <target> <identity> [method]
  local cat="$1" t="$2" ident="$3" module out rc now_ident
  if [ "$cat" = named ]; then
    # --propose's own judge: still the same file system object it measured.
    if [ -L "$t" ] || [ ! -e "$t" ]; then JUDGE_VERDICT="not offerable: it is no longer there as it was proposed"; return; fi
    [ -n "$ident" ] || { JUDGE_VERDICT="unmeasured: its record holds no identity to compare"; return; }
    # A record written before #1840 holds device:inode only. That is exactly the check a replacement
    # passed, so comparing what it has would repeat the fault: it is UNMEASURED, never a match, and the
    # item is skipped until it is proposed again. Named records are valid for an hour, so few exist.
    case "$ident" in
      v2:*) ;;
      *) JUDGE_VERDICT="unmeasured: its record holds an identity in the older device and inode shape ($ident), which a file made in its place can share, so it cannot tell this is the item proposed; propose it again"; return ;;
    esac
    now_ident="$(file_identity "$t")" || {
      JUDGE_VERDICT="unmeasured: its identity could not be read now (stat gave no usable answer), so nothing confirms it is the item proposed"; return; }
    identity_verdict "$ident" "$now_ident" "${4:-}"
    return
  fi
  case "$cat" in [a-z0-9]*) ;; *) JUDGE_VERDICT="unmeasured: '$cat' is not a category name"; return ;; esac
  case "$cat" in *[!a-z0-9-]*) JUDGE_VERDICT="unmeasured: '$cat' is not a category name"; return ;; esac
  module="$CATEGORIES/$cat.sh"
  if [ -z "${DISK_CLEAN_JUDGE:-}" ] && [ ! -f "$module" ]; then
    JUDGE_VERDICT="unmeasured: there is no judge for the category $cat ($module is not there)"; return
  fi
  out="$(DISK_CLEAN_CATEGORY="$cat" "${DISK_CLEAN_JUDGE:-$module}" judge "$t" </dev/null 2>/dev/null)"; rc=$?
  out="${out%%$'\n'*}"
  if [ "$rc" -ne 0 ]; then JUDGE_VERDICT="unmeasured: the $cat judge failed (exit $rc)"; return; fi
  case "$out" in
    offerable|"not offerable: "?*|"unmeasured: "?*) JUDGE_VERDICT="$out" ;;
    *) JUDGE_VERDICT="unmeasured: the $cat judge answered '$out', which is none of offerable, not offerable or unmeasured" ;;
  esac
}

# Checks a path target as far as acting on it: sets PHYS and succeeds, or sets WHY and fails. Run in
# the current shell, never a substitution, so PHYS reaches the caller.
path_checks() { # <target>
  local t="$1" r
  PHYS="" WHY=""
  case "$t" in /*) ;; *) WHY='its path is not absolute'; return 1 ;; esac
  case "$t" in *[[:cntrl:]]*) WHY='its path holds a control character'; return 1 ;; esac
  case "$t/" in */../*|*/./*) WHY='its path holds a . or .. component'; return 1 ;; esac
  # The deny list first, on the path as recorded: /Applications/Safari.app is itself a link.
  if deny_reason "$t"; then WHY="never removed: $DENY"; return 1; fi
  if [ -L "$t" ]; then
    WHY="it is a symbolic link (to $(readlink "$t" 2>/dev/null)), so what it names is not what was measured"; return 1
  fi
  PHYS="$(dc_resolve "$t")" || { WHY='where it lies could not be read'; return 1; }
  if deny_reason "$PHYS"; then WHY="never removed: $DENY"; return 1; fi
  allowed_root "$PHYS" || { WHY="it is outside the folders this tool removes from ($PHYS)"; return 1; }
  return 0
}

# ---------- the lock: one run at a time ----------
take_lock() {
  local holder
  LOCK="$STATE/remove.lock"
  if ln -s "$$" "$LOCK" 2>/dev/null; then LOCK_HELD=1; return 0; fi
  holder="$(readlink "$LOCK" 2>/dev/null)"
  case "$holder" in ''|*[!0-9]*) refuse 75 "its lock $LOCK is held but names no process, so it removed nothing; if no disk-remove is running, remove that file." ;; esac
  kill -0 "$holder" 2>/dev/null && refuse 75 "another disk-remove run (pid $holder) is removing things now, so this one removed nothing."
  # Taking over is a rename, never rm then ln: two runs can both see the dead holder, and an rm by
  # the slower one would delete the lock the faster one had just taken. Whoever renames away a link
  # that no longer names the dead holder has moved a live run's lock, so puts it back and refuses.
  local moved
  mv "$LOCK" "$WORK/stale-lock" 2>/dev/null || refuse 75 "another disk-remove run took its lock first, so this one removed nothing."
  moved="$(readlink "$WORK/stale-lock" 2>/dev/null)"
  if [ "$moved" != "$holder" ]; then
    ln -s "$moved" "$LOCK" 2>/dev/null
    refuse 75 "another disk-remove run (pid $moved) took its lock first, so this one removed nothing."
  fi
  ln -s "$$" "$LOCK" 2>/dev/null || refuse 75 "another disk-remove run took its lock first, so this one removed nothing."
  LOCK_HELD=1
  echo "A disk-remove run (pid $holder) had stopped without releasing its lock; this run took it over."
}

STATE="$HOME/.claude/state/disk-clean"
mkdir -p "$STATE/removals" "$STATE/named" 2>/dev/null || refuse 2 "could not make $STATE, so it removed nothing."

# ================================ --propose ================================
if [ "$MODE" = propose ]; then
  case "$PROPOSE_METHOD" in trash|delete|truncate) ;; *) refuse 2 "--propose takes trash, delete or truncate, not '$PROPOSE_METHOD', so it proposed nothing." ;; esac
  sid="named-$T0-$$"
  n=0 offered=0 refused_n=0
  : > "$WORK/items"
  for t in "$@"; do
    n=$((n + 1))
    if ! path_checks "$t"; then refused_n=$((refused_n + 1)); echo "refused  $t: $WHY"; continue; fi
    if [ ! -e "$PHYS" ]; then refused_n=$((refused_n + 1)); echo "refused  $t: it is not there"; continue; fi
    if [ "$PROPOSE_METHOD" = truncate ] && { [ ! -f "$PHYS" ] || [ -d "$PHYS" ]; }; then
      refused_n=$((refused_n + 1)); echo "refused  $t: truncate empties a single file, and this is not one"; continue
    fi
    ident="$(file_identity "$PHYS")" || {
      refused_n=$((refused_n + 1)); echo "refused  $t: its identity could not be read (stat gave no usable answer), so nothing could check it is the same item before removing it"; continue; }
    measure "$PHYS"
    bytes=""; [ -n "$SIZE_KIB" ] && bytes=$((SIZE_KIB * 1024))
    printf '%s\n' "n$n${S}named${S}$PROPOSE_METHOD${S}$PHYS${S}$bytes${S}offerable${S}$ident" >> "$WORK/items"
    offered=$((offered + 1))
    echo "offered  $PHYS  ($SIZE_WORDS, to $PROPOSE_METHOD)"
  done
  [ "$offered" -gt 0 ] || refuse 5 "nothing it was given can be removed by this tool, so it wrote no plan."
  dcr_write "$STATE/named/$sid.json" "$sid" "$T0" "$WORK/items" || refuse 2 "could not write the record $STATE/named/$sid.json, so it wrote no plan."
  {
    printf 'scan_id %s\ncount %s\n' "$sid" "$offered"
    awk -F "$S" '{ print "item " $1 }' "$WORK/items"
  } > "$WORK/plan" && mv -f "$WORK/plan" "$STATE/named/$sid.plan" || refuse 2 "could not write the plan $STATE/named/$sid.plan."
  echo "Plan: $STATE/named/$sid.plan ($offered item(s); valid for an hour)"
  echo "To remove them, once Dan has decided to:"
  echo "bash ~/.claude/hooks/lib/disk-remove.sh --plan $STATE/named/$sid.plan"
  [ "$refused_n" -eq 0 ] || exit 5
  exit 0
fi

# ================================ --plan ================================
[ -f "$PLAN" ] && [ -r "$PLAN" ] || refuse 2 "the plan $PLAN is not a file it can read, so it removed nothing."
# One pass over the plan: its scan_id, its count, and its item ids in order, or the first thing
# wrong with it.
plan_check="$(awk -v out="$WORK/ids" '
  { sub(/\r$/, "") }
  /^[ \t]*$/ || /^#/ { next }
  $1 == "scan_id" && NF == 2 { if (sid != "") { print "bad\tit names scan_id twice"; bad = 1; exit } sid = $2; next }
  $1 == "count" && NF == 2 && $2 ~ /^[0-9]+$/ { if (count != "") { print "bad\tit gives count twice"; bad = 1; exit } count = $2; next }
  $1 == "item" && NF == 2 && $2 ~ /^[A-Za-z0-9._:-]+$/ {
    if ($2 in seen) { print "bad\tit names item " $2 " twice"; bad = 1; exit }
    seen[$2] = 1; n++; print $2 > out; next
  }
  { print "bad\tline " NR " is not one a plan holds (scan_id <id>, count <n> or item <id>): " $0; bad = 1; exit }
  END {
    if (bad) exit
    if (sid == "") { print "bad\tit names no scan_id"; exit }
    if (sid !~ /^[A-Za-z0-9._:-]+$/) { print "bad\tits scan_id is not one a scan writes"; exit }
    if (count == "") { print "bad\tit gives no count"; exit }
    if (n == 0) { print "bad\tit names no items"; exit }
    if (n != count + 0) { print "bad\tit says count " count " but names " n " item(s)"; exit }
    print "ok\t" sid "\t" n
  }' "$PLAN")"
case "$plan_check" in
  ok$'\t'*) ;;
  *) refuse 2 "the plan $PLAN cannot be used: ${plan_check#bad$'\t'}, so it removed nothing." ;;
esac
PLAN_SID="$(printf '%s' "$plan_check" | awk -F '\t' '{ print $2 }')"
PLAN_N="$(printf '%s' "$plan_check" | awk -F '\t' '{ print $3 }')"

case "$PLAN_SID" in
  named-*) RECORD="$STATE/named/$PLAN_SID.json" ;;
  *) RECORD="$STATE/last-scan.json" ;;
esac
[ -f "$RECORD" ] || refuse 2 "there is no scan record at $RECORD for the plan's scan $PLAN_SID, so it removed nothing. Scan again."
dcr_complete "$RECORD" || refuse 2 "the scan record $RECORD is incomplete (it does not end where a record ends), so it removed nothing. Scan again."
REC_SID="$(dcr_header "$RECORD" scan_id)" || refuse 2 "the scan record $RECORD names no scan_id, so it removed nothing. Scan again."
REC_AT="$(dcr_header "$RECORD" scanned_at)" || refuse 2 "the scan record $RECORD has no time it was taken, so it removed nothing. Scan again."
[ "$REC_SID" = "$PLAN_SID" ] || \
  refuse 4 "the plan is for scan $PLAN_SID, but the last scan is $REC_SID, so what was reviewed is not what was last measured, and it removed nothing. Scan again and review that."
AGE=$((T0 - REC_AT))
[ "$AGE" -ge -300 ] || refuse 2 "the scan record says it was taken $(( -AGE )) seconds in the future, so its time cannot be trusted, and it removed nothing. Scan again."
[ "$AGE" -le "$MAX_SCAN_AGE" ] || \
  refuse 3 "the scan $PLAN_SID was taken $((AGE / 60)) minutes ago, over an hour, so what it measured may have changed, and it removed nothing. Scan again and review that."

take_lock
LOG="$STATE/removals/$PLAN_SID.log"
RUN="$T0-$$"

# An earlier run for this scan that was killed or crashed left an INTENT with no OUTCOME. Each is
# reported and settled now, by whether its target is still there, so it never reads as healthy (L617).
if [ -f "$LOG" ]; then
  awk -F '\t' '
    $1 == "INTENT" { k = $3 SUBSEP $4; open[k] = $0; order[++n] = k }
    $1 == "OUTCOME" { delete open[$3 SUBSEP $4] }
    END { for (i = 1; i <= n; i++) if (order[i] in open) { print open[order[i]]; delete open[order[i]] } }' "$LOG" > "$WORK/interrupted"
  while IFS="$(printf '\t')" read -r _ _ irun iid imethod itarget _; do
    [ -n "$iid" ] || continue
    if [ "$imethod" = docker ]; then
      # Nothing here can look a Docker target up; its own item, if it is in this plan, is judged
      # again below, which is where whether it went is checked.
      echo "An earlier run ($irun) stopped partway while removing docker $itarget; whether it went is not checked here."
      printf 'OUTCOME\t%s\t%s\t%s\tfailed\t\tinterrupted run; whether it went was not checked\n' "$((T0 + SECONDS))" "$irun" "$iid" >> "$LOG"
    elif [ ! -e "$itarget" ] && [ ! -L "$itarget" ]; then
      echo "An earlier run ($irun) stopped partway while removing $itarget; it is gone now."
      printf 'OUTCOME\t%s\t%s\t%s\tgone\t\tfound gone after an interrupted run\n' "$((T0 + SECONDS))" "$irun" "$iid" >> "$LOG"
    else
      echo "An earlier run ($irun) stopped partway while removing $itarget; it is still there, so it may be partly removed."
      printf 'OUTCOME\t%s\t%s\t%s\tfailed\t\tinterrupted run left it in place\n' "$((T0 + SECONDS))" "$irun" "$iid" >> "$LOG"
    fi
  done < "$WORK/interrupted"
fi

# The plan's items joined to the record, in the plan's order, one per line.
dcr_items "$RECORD" > "$WORK/record-items"
awk -v sep="$S" '
  FILENAME == ARGV[1] { split($0, f, sep); if (!(f[1] in rec)) rec[f[1]] = $0; next }
  { if ($0 in rec) print rec[$0]; else print $0 sep "" sep "" sep "" sep "missing" sep "" sep "" }' \
  "$WORK/record-items" "$WORK/ids" > "$WORK/todo"

DF_VOL=/System/Volumes/Data; [ -d "$DF_VOL" ] || DF_VOL="$HOME_PHYS"
df_mb() { df -Pm "$DF_VOL" </dev/null 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }'; }
DF_BEFORE="$(df_mb)"

echo "disk-remove: plan $PLAN, scan $PLAN_SID (taken $((AGE / 60)) minute(s) ago), $PLAN_N item(s)."
N_REMOVED=0 N_TRASHED=0 N_TRUNCATED=0 N_SKIPPED=0 N_FAILED=0
K_REMOVED=0 K_TRASHED=0 K_TRUNCATED=0 MARK_FAILED=""

# The outcome of one item: printed, logged, counted.
finish_item() { # <id> <result> <freed KiB> <target> <detail>
  local id="$1" result="$2" freed="${3:-}" t="$4" detail="$5"
  printf 'OUTCOME\t%s\t%s\t%s\t%s\t%s\t%s\n' "$((T0 + SECONDS))" "$RUN" "$id" "$result" "$freed" "$detail" >> "$LOG" || \
    detail="$detail (and its OUTCOME line could not be written to $LOG)"
  case "$result" in
    removed) N_REMOVED=$((N_REMOVED + 1)); K_REMOVED=$((K_REMOVED + ${freed:-0})); echo "removed    $t  ($detail)" ;;
    trashed) N_TRASHED=$((N_TRASHED + 1)); K_TRASHED=$((K_TRASHED + ${freed:-0})); echo "trashed    $t  ($detail)" ;;
    truncated) N_TRUNCATED=$((N_TRUNCATED + 1)); K_TRUNCATED=$((K_TRUNCATED + ${freed:-0})); echo "truncated  $t  ($detail)" ;;
    gone|skipped) N_SKIPPED=$((N_SKIPPED + 1)); echo "skipped    $t: $detail" ;;
    *) N_FAILED=$((N_FAILED + 1)); echo "failed     $t: $detail" ;;
  esac
}
# INTENT goes in before anything is touched; when it cannot be written, nothing is.
intent() { # <id> <method> <target> <KiB>
  printf 'INTENT\t%s\t%s\t%s\t%s\t%s\t%s\n' "$((T0 + SECONDS))" "$RUN" "$1" "$2" "$3" "$4" >> "$LOG"
}
gone_now() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

# ---------- docker ----------
DOCKER_UP=""
# The build cache's size as docker system df reports it. Read whole, with no early exit, so the
# reader never leaves before docker has finished writing (L183).
build_cache_kib() { docker system df --format '{{.Type}}|{{.Size}}' </dev/null 2>/dev/null | awk -F '|' '$1 == "Build Cache" && !found { print $2; found = 1 }'; }
do_docker() { # <id> <category> <target> <identity>
  local id="$1" cat="$2" t="$3" kind ref out rc bytes before after
  kind="${t%% *}"; ref=""; [ "$kind" = "$t" ] || ref="${t#* }"
  case "$kind $ref" in
    "volume "*) finish_item "$id" skipped "" "docker $t" "refused by name: Docker volumes hold data and are never removed by this tool (docker volume prune included)"; return ;;
    "system "*) finish_item "$id" skipped "" "docker $t" "refused by name: docker system prune removes whatever is unused, named or not"; return ;;
    "image "?*|"container "?*) case "$ref" in *[!A-Za-z0-9._:/@-]*) finish_item "$id" skipped "" "docker $t" "its name holds characters no Docker name has"; return ;; esac ;;
    "builder cache") ;;
    *) finish_item "$id" skipped "" "docker $t" "it is not a Docker target this tool removes (image <name>, container <name> or builder cache)"; return ;;
  esac
  if [ -z "$DOCKER_UP" ]; then if docker info </dev/null >/dev/null 2>&1; then DOCKER_UP=yes; else DOCKER_UP=no; fi; fi
  [ "$DOCKER_UP" = yes ] || { finish_item "$id" skipped "" "docker $t" "Docker is not running, so nothing of it can be removed or checked"; return; }
  run_judge "$cat" "$t" "$4"
  [ "$JUDGE_VERDICT" = offerable ] || { finish_item "$id" skipped "" "docker $t" "judged again just now: $JUDGE_VERDICT"; return; }
  case "$kind" in
    image)
      bytes="$(docker image inspect --format '{{.Size}}' "$ref" </dev/null 2>/dev/null)" || { finish_item "$id" gone "" "docker $t" "Docker has no such image now, so it was already gone"; return; }
      SIZE_KIB=""; case "$bytes" in ''|*[!0-9]*) ;; *) SIZE_KIB=$(( (bytes + 1023) / 1024 )) ;; esac
      intent "$id" docker "$t" "$SIZE_KIB" || { finish_item "$id" skipped "" "docker $t" "its INTENT line could not be written to $LOG, so it was not touched"; return; }
      out="$(docker image rm "$ref" </dev/null 2>&1)"; rc=$?
      if docker image inspect "$ref" </dev/null >/dev/null 2>&1; then finish_item "$id" failed "" "docker $t" "it is still there after docker image rm (exit $rc: ${out%%$'\n'*})"; return; fi
      finish_item "$id" removed "${SIZE_KIB:-0}" "docker $t" "$(human "$SIZE_KIB"), as Docker reports its size" ;;
    container)
      out="$(docker container inspect --size --format '{{.State.Running}} {{.SizeRw}}' "$ref" </dev/null 2>/dev/null)" || { finish_item "$id" gone "" "docker $t" "Docker has no such container now, so it was already gone"; return; }
      [ "${out%% *}" = false ] || { finish_item "$id" skipped "" "docker $t" "it is running"; return; }
      bytes="${out#* }"; SIZE_KIB=""; case "$bytes" in ''|*[!0-9]*) ;; *) SIZE_KIB=$(( (bytes + 1023) / 1024 )) ;; esac
      intent "$id" docker "$t" "$SIZE_KIB" || { finish_item "$id" skipped "" "docker $t" "its INTENT line could not be written to $LOG, so it was not touched"; return; }
      out="$(docker container rm "$ref" </dev/null 2>&1)"; rc=$?
      if docker container inspect "$ref" </dev/null >/dev/null 2>&1; then finish_item "$id" failed "" "docker $t" "it is still there after docker container rm (exit $rc: ${out%%$'\n'*})"; return; fi
      finish_item "$id" removed "${SIZE_KIB:-0}" "docker $t" "$(human "$SIZE_KIB"), as Docker reports its size" ;;
    builder)
      before="$(dcu_docker_kib "$(build_cache_kib)")" || before=""
      [ -n "$before" ] || { finish_item "$id" skipped "" "docker $t" "the size of Docker's build cache could not be read, so nothing could confirm it shrank"; return; }
      [ "$before" -gt 0 ] || { finish_item "$id" gone "" "docker $t" "Docker's build cache is already empty"; return; }
      intent "$id" docker "$t" "$before" || { finish_item "$id" skipped "" "docker $t" "its INTENT line could not be written to $LOG, so it was not touched"; return; }
      out="$(docker builder prune -f </dev/null 2>&1)"; rc=$?
      after="$(dcu_docker_kib "$(build_cache_kib)")" || after=""
      if [ -z "$after" ]; then finish_item "$id" failed "" "docker $t" "after docker builder prune (exit $rc) the build cache's size could not be read, so nothing confirms it shrank"; return; fi
      if [ "$after" -ge "$before" ]; then finish_item "$id" failed "" "docker $t" "the build cache did not shrink ($(human "$before") before, $(human "$after") after; docker builder prune exit $rc: ${out%%$'\n'*})"; return; fi
      finish_item "$id" removed "$((before - after))" "docker $t" "$(human "$((before - after))") of build cache, as Docker reports it" ;;
  esac
}

# ---------- a path item ----------
do_path() { # <id> <category> <method> <target> <identity>
  local id="$1" cat="$2" method="$3" t="$4" ident="$5" why out rc before_bytes after_bytes after_kib
  path_checks "$t" || { finish_item "$id" skipped "" "$t" "$WHY"; return; }
  gone_now "$PHYS" && { finish_item "$id" gone "" "$t" "it was already gone"; return; }
  case "$method" in
    truncate) { [ -f "$PHYS" ] && [ ! -d "$PHYS" ]; } || { finish_item "$id" skipped "" "$t" "truncate empties a single file, and this is not one"; return; } ;;
    worktree|derived-data) [ -d "$PHYS" ] || { finish_item "$id" skipped "" "$t" "the $method method removes a folder, and this is not one"; return; } ;;
    trash)
      [ -x "${DISK_CLEAN_TRASH:-/usr/bin/trash}" ] || {
        finish_item "$id" skipped "" "$t" "/usr/bin/trash is not on this Mac (it ships with macOS 15), and this tool never deletes in place of moving to the Trash"; return; } ;;
  esac
  # A check guards the removal only for as long as nothing slow sits between them (#1872, L1034).
  # So du runs first (0.4 s for a 97,000 entry node_modules, longer for a big cache); then the judge,
  # so no measuring sits between it confirming this is the item proposed and the removal; then lsof,
  # last, so a file opened while du or the judge ran is still seen. Only the INTENT line, one append
  # to the log, sits between lsof and the removal, since it must go in before anything is touched.
  measure "$PHYS"
  run_judge "$cat" "$t" "$ident" "$method"
  [ "$JUDGE_VERDICT" = offerable ] || { finish_item "$id" skipped "" "$t" "judged again just now: $JUDGE_VERDICT"; return; }
  if [ "$method" != truncate ]; then
    open_check "$PHYS"
    [ "$OPEN_VERDICT" = free ] || { finish_item "$id" skipped "" "$t" "$OPEN_VERDICT"; return; }
  fi
  [ "$method" = truncate ] && before_bytes="$(file_bytes "$PHYS")"
  intent "$id" "$method" "$PHYS" "$SIZE_KIB" || { finish_item "$id" skipped "" "$t" "its INTENT line could not be written to $LOG, so it was not touched"; return; }
  case "$method" in
    trash)
      out="$("${DISK_CLEAN_TRASH:-/usr/bin/trash}" -s "$PHYS" </dev/null 2>&1)"; rc=$?
      if ! gone_now "$PHYS"; then finish_item "$id" failed "" "$t" "it is still there after trash (exit $rc: ${out%%$'\n'*})"; return; fi
      finish_item "$id" trashed "${SIZE_KIB:-0}" "$t" "$SIZE_WORDS, moved to the Trash, which frees it only once the Trash is emptied" ;;
    delete)
      out="$(rm -rf "$PHYS" </dev/null 2>&1)"; rc=$?
      if ! gone_now "$PHYS"; then measure "$PHYS"; finish_item "$id" failed "" "$t" "some of it could not be deleted ($SIZE_WORDS left; rm exit $rc: ${out%%$'\n'*})"; return; fi
      finish_item "$id" removed "${SIZE_KIB:-0}" "$t" "$SIZE_WORDS" ;;
    worktree)
      out="$(git -C "$PHYS" worktree remove "$PHYS" </dev/null 2>&1)"; rc=$?
      if ! gone_now "$PHYS"; then
        if [ "$rc" -ne 0 ]; then finish_item "$id" skipped "" "$t" "git refused to remove the worktree: ${out%%$'\n'*}"
        else finish_item "$id" failed "" "$t" "git said it removed the worktree, but it is still there"; fi
        return
      fi
      finish_item "$id" removed "${SIZE_KIB:-0}" "$t" "$SIZE_WORDS" ;;
    derived-data)
      out="$("${DISK_CLEAN_DERIVED_DATA_SWEEP:-$HOOKS/derived-data-sweep.sh}" --remove-one "$PHYS" </dev/null 2>&1)"; rc=$?
      case "$rc" in
        0) gone_now "$PHYS" || { finish_item "$id" failed "" "$t" "the sweep said it removed it, but it is still there"; return; }
           finish_item "$id" removed "${SIZE_KIB:-0}" "$t" "$SIZE_WORDS" ;;
        4) finish_item "$id" skipped "" "$t" "the Xcode build cache sweep kept it: ${out%%$'\n'*}" ;;
        75) finish_item "$id" skipped "" "$t" "an automatic sweep of Xcode build caches is running now; try again after it" ;;
        *) finish_item "$id" failed "" "$t" "the Xcode build cache sweep exited $rc: ${out%%$'\n'*}" ;;
      esac ;;
    truncate)
      out="$(tee "$PHYS" </dev/null 2>&1 >/dev/null)"; rc=$?
      after_bytes="$(file_bytes "$PHYS")"
      case "$before_bytes:$after_bytes" in *[!0-9:]*|:*|*:) finish_item "$id" failed "" "$t" "its size could not be read after emptying it (tee exit $rc)"; return ;; esac
      if [ "$after_bytes" -ge "$before_bytes" ] && [ "$after_bytes" -gt 0 ]; then
        finish_item "$id" failed "" "$t" "it is no smaller after emptying it ($before_bytes bytes before, $after_bytes after; tee exit $rc: ${out%%$'\n'*})"; return
      fi
      after_kib="$(du -sk "$PHYS" </dev/null 2>/dev/null)"; after_kib="${after_kib%%[!0-9]*}"
      if [ -n "$SIZE_KIB" ] && [ -n "$after_kib" ] && [ "$after_kib" -le "$SIZE_KIB" ]; then
        finish_item "$id" truncated "$((SIZE_KIB - after_kib))" "$t" "$(human "$((SIZE_KIB - after_kib))") freed, emptied in place"
      else
        finish_item "$id" truncated 0 "$t" "emptied in place ($before_bytes bytes before, $after_bytes after), but how much space that freed could not be measured"
      fi ;;
  esac
}

while IFS="$S" read -r -u 3 id cat method target state bytes ident; do
  case "$state" in
    offerable) ;;
    missing) finish_item "$id" skipped "" "item $id" "scan $PLAN_SID has no item with this id"; continue ;;
    unreadable) finish_item "$id" skipped "" "item $id" "its line in the scan record could not be read"; continue ;;
    removed|trashed|truncated|gone) finish_item "$id" skipped "" "$target" "an earlier run already settled it ($state)"; continue ;;
    *) finish_item "$id" skipped "" "$target" "the scan did not offer it ($state)"; continue ;;
  esac
  case "$method" in
    docker) do_docker "$id" "$cat" "$target" "$ident" ;;
    trash|delete|truncate|worktree|derived-data) do_path "$id" "$cat" "$method" "$target" "$ident" ;;
    *) finish_item "$id" skipped "" "$target" "'$method' is not a method this tool knows" ;;
  esac
done 3< "$WORK/todo"

# ---------- the record: every item this scan's log settled is marked, so nothing re-quotes it ----------
awk -F '\t' -v sep="$S" '
  $1 == "OUTCOME" && ($5 == "removed" || $5 == "trashed" || $5 == "truncated" || $5 == "gone") { st[$4] = $5 }
  END { for (k in st) print k sep st[k] }' "$LOG" > "$WORK/marks" 2>/dev/null
if [ -s "$WORK/marks" ]; then
  dcr_mark "$RECORD" "$PLAN_SID" "$WORK/marks" || MARK_FAILED=1
fi

# ---------- the result ----------
echo ""
echo "Verified, each item measured just before it went and checked after:"
echo "  removed $N_REMOVED item(s), freeing $(human "$K_REMOVED")"
[ "$N_TRASHED" -gt 0 ] && echo "  moved $N_TRASHED item(s) to the Trash, $(human "$K_TRASHED"), which is freed only once the Trash is emptied"
[ "$N_TRUNCATED" -gt 0 ] && echo "  emptied $N_TRUNCATED file(s) in place, freeing $(human "$K_TRUNCATED")"
echo "  skipped $N_SKIPPED, failed $N_FAILED"
DF_AFTER="$(df_mb)"
if [ -n "$DF_BEFORE" ] && [ -n "$DF_AFTER" ]; then
  echo "Disk wide, as context only (other programs write to the disk too): df -m read $DF_BEFORE MB free on $DF_VOL before and $DF_AFTER MB after."
else
  echo "Disk wide: df -m could not be read before and after, so the disk wide change is not known."
fi
snaps="$(tmutil listlocalsnapshots / </dev/null 2>/dev/null)"; snap_rc=$?
if [ "$snap_rc" -ne 0 ]; then
  echo "Local Time Machine snapshots could not be listed (tmutil exit $snap_rc), so space they hold is not accounted for."
else
  snap_names="$(printf '%s\n' "$snaps" | awk '/^com\.apple\./ { n++; if (n <= 5) { printf "%s%s", sep, $0; sep = ", " } } END { if (n > 5) printf " and %d more", n - 5 }')"
  if [ -n "$snap_names" ]; then
    echo "Local Time Machine snapshots hold space no item size includes, and removed files stay in them until they expire: $snap_names"
  fi
fi
echo "Log: $LOG"
if [ -n "$MARK_FAILED" ]; then
  echo "The scan record $RECORD could not be marked with what went, so the low space warning may still count those items until the next scan."
  exit 5
fi
[ "$N_SKIPPED" -eq 0 ] && [ "$N_FAILED" -eq 0 ] && exit 0
exit 5
