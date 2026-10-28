#!/usr/bin/env bash
#
# scan-lib.sh: what disk-clean's scan and every category module share (claude-config#1806).
#
# Sourced by scan.sh and by each categories/<name>.sh, never run. It holds the readings more than
# one category takes, so each is taken one way: the size of a list of paths (du, judged by its exit
# code and stderr), the identity of a file, the open file listing (lsof), the live session map, the
# one pruned walk of the home folder, and the flags a reviewer must see (credentials, iCloud).
#
# A MODULE answers two calls, and both use the same rules (the plan's design principle, #1804):
#   <module> scan           prints one line per finding, fields separated by \037:
#                             item \037 target \037 method \037 KiB \037 size \037 state \037 flags
#                                  \037 detail \037 identity \037 end
#                             status \037 unmeasured: <why the whole category could not be measured>
#                             note \037 <a sentence about the category as a whole>
#                           scan.sh assigns ids and the category, and drops a line not ending in
#                           "end", which a kill partway through a write leaves.
#   <module> judge <target> prints exactly one line: offerable, "not offerable: <reason>" or
#                           "unmeasured: <reason>". disk-remove.sh runs it again just before removing.
#
# TEST MODE is the harness's (hooks/lib/disk-clean-harness.sh): DISK_CLEAN_TEST_ROOT set and HOME
# physically inside it, judged by hooks/lib/disk-clean-predicates.sh, the predicate disk-remove.sh
# uses. Only then are the seams honoured: DISK_CLEAN_DERIVED_DATA_SWEEP (a command),
# DISK_CLEAN_DATALESS (a file of paths that stand in for entries iCloud keeps only in the cloud,
# since chflags cannot set that flag) and the Claude Code temp folder moving under TMPDIR. Outside
# test mode a seam being set refuses everything.
#
# Commands: awk cat date dirname du find grep id ls lsof mkdir mktemp ps sed sort stat tr wc xargs,
# and the builtins. bash 3.2 safe. Sourcing defines constants and functions and runs dcs_init.

DCS_LIB="${BASH_SOURCE[0]%/*}"; [ "$DCS_LIB" != "${BASH_SOURCE[0]}" ] || DCS_LIB=.
DCS_LIB="$(CDPATH= cd -P "$DCS_LIB" 2>/dev/null && pwd -P)" || { echo "disk-clean: cannot find its own folder"; exit 2; }
DCS_HOOKS="$DCS_LIB/../../hooks"
. "$DCS_HOOKS/lib/disk-clean-predicates.sh" || { echo "disk-clean: hooks/lib/disk-clean-predicates.sh is missing"; exit 2; }
. "$DCS_HOOKS/lib/disk-clean-record.sh" || { echo "disk-clean: hooks/lib/disk-clean-record.sh is missing"; exit 2; }
. "$DCS_HOOKS/lib/disk-clean-units.sh" || { echo "disk-clean: hooks/lib/disk-clean-units.sh is missing"; exit 2; }

S=$'\037'
TAB=$'\t'

# The thresholds the plan settled, one place each.
DCS_LARGE_MB=500        # a personal file, and a runaway log, is "large" over this
DCS_BUILD_DAYS=30       # a project untouched this long keeps no build folder
DCS_TOOL_DAYS=180       # a tool folder untouched this long, and mentioned nowhere, is forgotten
DCS_TRANSCRIPT_DAYS=90  # Claude Code keeps 30 days itself, so anything past 90 means that stopped
DCS_TEMP_MINUTES=1440   # a Claude Code temp folder used in the last 24 hours is kept

# The folder to command TABLE for forgotten tools (the plan: a table, never name matching). One line
# each: the folder relative to HOME | the command it belongs to | the files a project using it holds.
# A command shorter than four letters (go, pod, sdk) is never searched for as a word in shell files,
# where it matches ordinary words; its folder's path still is.
DCS_TOOLS='.gradle|gradle|build.gradle build.gradle.kts settings.gradle settings.gradle.kts gradlew
.m2|mvn|pom.xml mvnw
.android|adb|AndroidManifest.xml
Library/Android/sdk|adb|AndroidManifest.xml
.pyenv|pyenv|.python-version
.rbenv|rbenv|.ruby-version
.bun|bun|bun.lockb bun.lock bunfig.toml
.deno|deno|deno.json deno.jsonc deno.lock
go|go|go.mod
.cocoapods|pod|Podfile
.pub-cache|dart|pubspec.yaml
.expo|expo|app.json app.config.js app.config.ts eas.json
.conda|conda|environment.yml environment.yaml
miniconda3|conda|environment.yml environment.yaml
anaconda3|conda|environment.yml environment.yaml
.vagrant.d|vagrant|Vagrantfile
.minikube|minikube|
.terraform.d|terraform|.terraform.lock.hcl
.platformio|pio|platformio.ini
.sdkman|sdk|
.nuget|dotnet|*.csproj *.fsproj *.sln global.json
.dotnet|dotnet|*.csproj *.fsproj *.sln global.json
.stack|stack|stack.yaml
.ghcup|ghc|cabal.project stack.yaml *.cabal
.julia|julia|Project.toml'

# ---------------------------------------------------------------------------------------------
# Test mode and the folders everything reads
# ---------------------------------------------------------------------------------------------
dcs_init() {
  DCS_TEST_ROOT="${DISK_CLEAN_TEST_ROOT:-}"
  if [ -n "$DCS_TEST_ROOT" ]; then
    dc_home_isolated "${HOME:-}" "$DCS_TEST_ROOT" || {
      echo "disk-clean: test mode (DISK_CLEAN_TEST_ROOT is $DCS_TEST_ROOT), but HOME ('${HOME:-}') is not inside that throwaway directory, so it scanned nothing."
      exit 2
    }
  else
    [ -z "${DISK_CLEAN_DERIVED_DATA_SWEEP+x}${DISK_CLEAN_TRASH+x}${DISK_CLEAN_JUDGE+x}${DISK_CLEAN_CATEGORIES+x}${DISK_CLEAN_DATALESS+x}" ] || {
      echo "disk-clean: a test seam (DISK_CLEAN_DERIVED_DATA_SWEEP, DISK_CLEAN_TRASH, DISK_CLEAN_JUDGE, DISK_CLEAN_CATEGORIES or DISK_CLEAN_DATALESS) is set, but DISK_CLEAN_TEST_ROOT is not, and the seams are honoured only in test mode, so it scanned nothing."
      exit 2
    }
  fi
  dcs_dl_setup
  [ -n "${HOME:-}" ] || { echo "disk-clean: HOME is not set, so it scanned nothing."; exit 2; }
  DCS_HOME="$(CDPATH= cd -P "$HOME" 2>/dev/null && pwd -P)" || { echo "disk-clean: could not read the home folder $HOME, so it scanned nothing."; exit 2; }
  DCS_STATE="$HOME/.claude/state/disk-clean"
  DCS_RECORD="$DCS_STATE/last-scan.json"
  DCS_UID="$(id -u 2>/dev/null)" || DCS_UID=""
  # Claude Code keeps a temp folder per project and session under /tmp/claude-<uid>.
  if [ -n "$DCS_TEST_ROOT" ]; then DCS_CLAUDE_TMP="${TMPDIR%/}/claude-$DCS_UID"; else DCS_CLAUDE_TMP="/private/tmp/claude-$DCS_UID"; fi
  # The private working folder: scan.sh hands its own down; a judge run alone makes one.
  if [ -n "${DISK_CLEAN_WORK:-}" ] && [ -d "$DISK_CLEAN_WORK" ]; then
    DCS_WORK="$DISK_CLEAN_WORK"; DCS_OWN_WORK=""
  else
    DCS_WORK="$(mktemp -d "${TMPDIR:-/tmp}/disk-clean.XXXXXXXX")" || { echo "unmeasured: could not make a working folder under ${TMPDIR:-/tmp}"; exit 0; }
    DCS_OWN_WORK=1
    trap 'dcs_cleanup' EXIT
  fi
}
dcs_cleanup() { [ -n "${DCS_OWN_WORK:-}" ] && [ -n "${DCS_WORK:-}" ] && rm -rf "$DCS_WORK"; return 0; }

# ---------------------------------------------------------------------------------------------
# Output lines
# ---------------------------------------------------------------------------------------------
# Every item carries icloud-only-part when dcs_measure sized it around a folder iCloud keeps only in
# the cloud: added here, where every module writes its items, so no module can leave it off (L621).
dcs_item() { # <target> <method> <KiB> <size> <state> <flags> <detail> <identity>
  local fl="$6"
  if [ -s "$DCS_WORK/dataless-part" ] && grep -qxF -- "$1" "$DCS_WORK/dataless-part"; then fl="$(dcs_join "$fl" icloud-only-part)"; fi
  printf 'item%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%send\n' "$S" "$1" "$S" "$2" "$S" "$3" "$S" "$4" "$S" "$5" "$S" "$fl" "$S" "$7" "$S" "$8" "$S"
}
dcs_status() { printf 'status%s%s\n' "$S" "$1"; }
dcs_note() { printf 'note%s%s\n' "$S" "$1"; }

# Prints the size and identity of every path listed in <file> (one per line) as path, KiB, size and
# identity separated by \037, to stdout. du runs over the whole list in batches, never once per path,
# and its exit code and stderr decide each figure (the plan, L460):
#   measured  du read everything and said nothing
#   partial   du gave a figure but said it could not read something beneath the path: a lower bound
#   denied    du could not read the path itself (Full Disk Access, or a root only folder): no figure
#   unread    du gave no figure for it and said nothing about it: no figure, never 0
# du does not skip a folder iCloud keeps only in the cloud, and reading one makes iCloud fetch it
# (#1860: 1,673 of them in four Slate worktree build folders). So a path with one at or beneath it
# (the walk's own test, DCS_DL) is never given to du: a find that stops at each one lists the rest
# and their blocks are summed, each file once however many links it has. That is exactly what is
# stored on this Mac, since nothing under a dataless folder is, so it is measured, never partial, and
# the path is written to dataless-part, which makes dcs_item flag it icloud-only-part. Its errors are
# read as du's are; a find or stat that failed saying nothing leaves it unread. The search costs
# about one more du over the same paths (measured 2026-10-28 on the personal MacBook at load 16, a
# 97,000 entry node_modules: 0.6 s, against 0.4 s for du warm and 1.4 s cold); it is run on every
# path rather than only on iCloud synced ones, because missing one makes iCloud fetch it.
dcs_measure() { # <file of paths>
  local list="$1" out="$DCS_WORK/du.out.$$" err="$DCS_WORK/du.err.$$" ids="$DCS_WORK/stat.out.$$" rc
  local dl="$DCS_WORK/dl.found.$$" plain="$DCS_WORK/du.list.$$" part="$DCS_WORK/dl.list.$$" p
  : > "$out"; : > "$err"; : > "$ids"; : > "$dl"; : > "$part"
  [ -s "$list" ] || return 0
  if [ -n "$DCS_DL_ANY" ]; then
    dcs_dl_beneath "$list" > "$dl"
    awk -v plain="$plain" -v part="$part" 'FILENAME == ARGV[1] { d[$0] = 1; next }
      { for (x in d) if (x == $0 || index(x, $0 "/") == 1) { print > part; next } print > plain }' "$dl" "$list"
  else
    cat "$list" > "$plain"
  fi
  rc=0
  if [ -s "$plain" ]; then tr '\n' '\000' < "$plain" | xargs -0 du -sk -- > "$out" 2> "$err"; rc=$?; fi
  while IFS= read -r p; do
    dcs_size_around "$p" >> "$out" 2>> "$err"
    printf '%s\n' "$p" >> "$DCS_WORK/dataless-part"
  done < "$part"
  if stat -c '%d:%i' / >/dev/null 2>&1; then
    tr '\n' '\000' < "$list" | xargs -0 stat -c "%d:%i$S%n" > "$ids" 2>/dev/null
  else
    tr '\n' '\000' < "$list" | xargs -0 stat -f "%d:%i$S%N" > "$ids" 2>/dev/null
  fi
  awk -v sep="$S" -v rc="$rc" '
    FILENAME == ARGV[1] { t = index($0, "\t"); if (t) kib[substr($0, t + 1)] = substr($0, 1, t - 1); next }
    FILENAME == ARGV[2] {
      # "du: <path>: <reason>" (or find: or stat:): the path is everything between the first ": "
      # and the last.
      line = $0; sub(/^(du|find|stat): /, "", line)
      n = 0; for (i = length(line) - 1; i > 0; i--) if (substr(line, i, 2) == ": ") { n = i; break }
      if (n) { p = substr(line, 1, n - 1); bad[p] = 1; nbad++ } else { loose++ }
      next
    }
    FILENAME == ARGV[3] { k = index($0, sep); if (k) ident[substr($0, k + 1)] = substr($0, 1, k - 1); next }
    {
      p = $0; k = kib[p]; size = "measured"
      if (p in bad) { size = "denied"; k = "" }
      else if (k == "") { size = "unread" }
      else {
        for (b in bad) if (index(b, p "/") == 1) { size = "partial"; break }
        if (size == "measured" && (loose || (rc != 0 && nbad == 0))) size = "partial"
      }
      print p sep k sep size sep ident[p]
    }' "$out" "$err" "$ids" "$list"
  rm -f "$out" "$err" "$ids" "$dl" "$plain" "$part"
}
# Prints every folder at or beneath the paths listed in <file> that the walk's test (DCS_DL) says
# iCloud keeps only in the cloud, never going into one. One find per 200 paths, never one per path.
dcs_dl_beneath() { # <file of paths>
  local p batch=()
  while IFS= read -r p; do
    batch=( "${batch[@]+"${batch[@]}"}" "$p" )
    if [ "${#batch[@]}" -ge 200 ]; then
      find "${batch[@]}" -type d \( "${DCS_DL[@]}" \) -print -prune 2>/dev/null; batch=()
    fi
  done < "$1"
  [ "${#batch[@]}" -eq 0 ] || find "${batch[@]}" -type d \( "${DCS_DL[@]}" \) -print -prune 2>/dev/null
  return 0
}
# Prints "KiB<TAB><path>" for what is stored on this Mac at or beneath <path>, never going into a
# folder iCloud keeps only in the cloud. find's and stat's own complaints go to stderr, where
# dcs_measure reads them as it reads du's; when either failed saying nothing, there is no figure.
dcs_size_around() { # <path>
  local p="$1" files="$DCS_WORK/dl.files.$$" sizes="$DCS_WORK/dl.sizes.$$" e="$DCS_WORK/dl.err.$$" frc src=0
  : > "$sizes"; : > "$e"
  find "$p" -type d \( "${DCS_DL[@]}" \) -prune -o -print0 > "$files" 2>> "$e"; frc=$?
  if [ -s "$files" ]; then
    if stat -c '%d:%i' / >/dev/null 2>&1; then xargs -0 stat -c '%d:%i %b' < "$files" > "$sizes" 2>> "$e"; src=$?
    else xargs -0 stat -f '%d:%i %b' < "$files" > "$sizes" 2>> "$e"; src=$?; fi
  fi
  if { [ "$frc" -eq 0 ] && [ "$src" -eq 0 ]; } || [ -s "$e" ]; then
    awk -v p="$p" '!seen[$1]++ { b += $2 } END { printf "%d\t%s\n", int((b + 1) / 2), p }' "$sizes"
  fi
  cat "$e" >&2
  rm -f "$files" "$sizes" "$e"
}

dcs_identity() { # <path> -> device:inode
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null
}
dcs_mtime() { # <path> -> epoch seconds
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}
dcs_bytes() { # <path> -> apparent size in bytes
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}
dcs_date() { # <epoch seconds> -> YYYY-MM-DD
  date -r "$1" '+%Y-%m-%d' 2>/dev/null || date -d "@$1" '+%Y-%m-%d' 2>/dev/null
}
# Succeeds when <path> is an entry macOS keeps in iCloud only (dataless): a file whose removal frees
# nothing on this Mac, or one that reading would make iCloud fetch. stat does not fetch it. Off
# macOS there is no such flag, and nothing is, apart from the test mode stand-ins.
dcs_dataless() { # <path>
  local f
  case "$DCS_DL_LIST" in *"$TAB$1$TAB"*) return 0 ;; esac
  f="$(stat -f '%Xf' "$1" 2>/dev/null)" || return 1
  case "$f" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  [ $(( 16#$f & 16#40000000 )) -ne 0 ]
}
# Whether this find knows macOS's dataless flag (GNU find does not).
DCS_FIND_DL=""
find / -maxdepth 0 -flags +dataless >/dev/null 2>&1 && DCS_FIND_DL=1
# DCS_DL: the find primaries matching an entry iCloud keeps only in the cloud, the ONE test every
# find here prunes with (the walk, dcs_recent_file, dcs_credential, dcs_measure; L370), because
# listing a dataless folder makes iCloud fetch its contents. It starts with -false, so with nothing
# to add it matches nothing. In test mode DISK_CLEAN_DATALESS names a file of paths, one per line,
# each added as an exact -path, and kept TAB delimited in DCS_DL_LIST for dcs_dataless. DCS_DL_ANY
# says whether anything can match at all, so a Mac or runner with no dataless test skips the search.
dcs_dl_setup() {
  local p q
  DCS_DL=( -false ); DCS_DL_LIST="$TAB"; DCS_DL_ANY=""
  [ -n "$DCS_FIND_DL" ] && { DCS_DL=( "${DCS_DL[@]}" -o -flags +dataless ); DCS_DL_ANY=1; }
  [ -n "$DCS_TEST_ROOT" ] && [ -n "${DISK_CLEAN_DATALESS:-}" ] || return 0
  [ -r "$DISK_CLEAN_DATALESS" ] || { echo "disk-clean: DISK_CLEAN_DATALESS ($DISK_CLEAN_DATALESS) could not be read, so it scanned nothing."; exit 2; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    q="$(printf '%s' "$p" | sed 's/[][*?\\]/\\&/g')"
    DCS_DL=( "${DCS_DL[@]}" -o -path "$q" ); DCS_DL_LIST="$DCS_DL_LIST$p$TAB"; DCS_DL_ANY=1
  done < "$DISK_CLEAN_DATALESS"
}

# Prints the first file under <dir> that changed within <days> days, never going into a folder named
# one of <prune names>; nothing when there is none. It never lists a dataless folder either: it
# prints that FOLDER instead and stops, so a caller seeing a folder knows part of <dir> is kept only
# in iCloud and could not be looked at, which is not the same as nothing in it being recent (L11).
# What find could not read goes to <stderr file>, so a caller can tell "nothing recent" from "could
# not look".
dcs_recent_file() { # <dir> <days> <stderr file> [<prune name>...]
  local d="$1" days="$2" err="$3" n
  shift 3
  local pr=( -name .disk-clean-prunes-nothing )
  for n in "$@"; do pr=( "${pr[@]}" -o -name "$n" ); done
  find "$d" \( "${pr[@]}" \) -prune -o -type d \( "${DCS_DL[@]}" \) -print -quit -o -type f -mtime -"$days" -print -quit 2> "$err"
}

# Physical path of a folder, or of a file's folder plus its name.
dcs_phys() { dc_resolve "$1"; }
# Succeeds when <path> is an entry directly inside the folder whose physical path is <folder>. The
# last folder resolved is remembered, so a scan of thousands of entries of one folder resolves it
# once rather than forking for every entry.
dcs_parent_is() { # <path> <physical folder>
  local dir="${1%/*}"
  case "${1##*/}" in ''|.|..) return 1 ;; esac
  if [ "$dir" != "${_DCS_PDIR:-}" ]; then
    _DCS_PDIR="$dir"
    _DCS_PPHYS="$(CDPATH= cd -P "$dir" 2>/dev/null && pwd -P)" || _DCS_PPHYS=""
  fi
  [ -n "$_DCS_PPHYS" ] && [ "$_DCS_PPHYS" = "$2" ]
}

# ---------------------------------------------------------------------------------------------
# Open files: one lsof listing of every open file, then a prefix match per folder
# ---------------------------------------------------------------------------------------------
# Writes command<TAB>path lines for every open file to <out>. Fails, setting DCS_WHY, when lsof said
# anything on stderr or exited with anything but 0 or 1: lsof exits 1 for nothing found, missing and
# permission denied alike (measured 2026-10-27), so stderr is what tells them apart (L42).
dcs_open_files() { # <out>
  local raw="$DCS_WORK/lsof.raw.$$" err="$DCS_WORK/lsof.err.$$" rc
  lsof -n -P -F cn > "$raw" 2> "$err" </dev/null; rc=$?
  if [ -s "$err" ] || { [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; }; then
    DCS_WHY="lsof exited $rc$([ -s "$err" ] && printf ', and said: %s' "$(awk 'NR == 1' "$err")")"
    rm -f "$raw" "$err"
    return 1
  fi
  awk '/^c/ { c = substr($0, 2); next } /^n/ { print c "\t" substr($0, 2) }' "$raw" > "$1"
  rm -f "$raw" "$err"
}
# The commands holding open any file at or beneath <folder>, comma separated; empty when none.
dcs_holders() { # <folder> <listing>
  awk -F '\t' -v d="$1" '($2 == d || index($2, d "/") == 1) && !seen[$1]++ { printf "%s%s", sep, $1; sep = ", " }' "$2"
}
# For one file: sets DCS_OPEN to the commands holding it (empty when none), or fails setting DCS_WHY.
dcs_file_open() { # <file>
  local out err="$DCS_WORK/lsof1.err.$$" rc
  out="$(lsof -F c -- "$1" </dev/null 2> "$err")"; rc=$?
  if [ -s "$err" ] || { [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; }; then
    DCS_WHY="lsof exited $rc$([ -s "$err" ] && printf ', and said: %s' "$(awk 'NR == 1' "$err")")"
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  DCS_OPEN=""
  [ "$rc" -eq 0 ] && DCS_OPEN="$(printf '%s\n' "$out" | awk '/^c/ && !seen[$0]++ { printf "%s%s", sep, substr($0, 2); sep = ", " }')"
  [ "$rc" -eq 0 ] && [ -z "$DCS_OPEN" ] && DCS_OPEN="a running process"
  return 0
}

# ---------------------------------------------------------------------------------------------
# Claude Code sessions
# ---------------------------------------------------------------------------------------------
# Writes the live session ids to <ids> and their working folders to <cwds>, read from
# ~/.claude/sessions/*.json. Fails, setting DCS_WHY, when any of those files cannot be read, because
# a session missing from the map would read as abandoned (the plan's rule for Claude Code temp).
dcs_sessions() { # <ids> <cwds>
  local f d="$HOME/.claude/sessions"
  : > "$1"; : > "$2"
  [ -d "$d" ] || return 0
  [ -r "$d" ] && [ -x "$d" ] || { DCS_WHY="the session map folder $d could not be read"; return 1; }
  for f in "$d"/*.json; do
    [ -e "$f" ] || continue
    [ -r "$f" ] || { DCS_WHY="the session map file $f could not be read"; return 1; }
    sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "$f" >> "$1" || { DCS_WHY="the session map file $f could not be read"; return 1; }
    sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p' "$f" >> "$2" || { DCS_WHY="the session map file $f could not be read"; return 1; }
  done
  return 0
}
# 0 when a Claude Code process is running, 1 when none is, 2 when the process list could not be read.
# By the name it was started as, as ps reports it: the binary itself is named after its version.
dcs_claude_running() {
  local out
  out="$(ps -axo comm= </dev/null 2>/dev/null)" || return 2
  printf '%s\n' "$out" | awk '{ n = $0; sub(/.*\//, "", n); if (n == "claude") f = 1 } END { exit !f }' && return 0
  return 1
}

# ---------------------------------------------------------------------------------------------
# The one pruned walk of the home folder (the plan: never find over all of home)
# ---------------------------------------------------------------------------------------------
# Never descends into ~/Library (Caches, Mail, iCloud Drive and the cloud folders are under it, and
# each category that wants part of it reads that part directly), the Trash, the key folders, a sync
# client's folder, an app or photo library package, Claude Code's transcripts (their own category),
# or a folder iCloud keeps only in the cloud: on 2026-10-27 the same walk without that last prune ran
# past ten minutes inside the iCloud synced Documents of this Mac, and with it took 34 seconds. It
# prints, one per line:
#   every node_modules and .next folder, and every .wrangler/tmp, without going inside them
#   every .git (a folder is a repository, a file is a worktree or a submodule)
#   every *.log over the large size, anywhere it goes, dotfolders included
#   every file a project for a forgotten tool would hold, .nvmrc, .python-version and pyvenv.cfg
#   every file over the large size in Downloads, Desktop, Documents and Movies
# Its stderr is where it could not read a folder; the caller decides what a partial walk means.
dcs_walk() {
  local H="$HOME" markers="" m line
  # No globbing from here on: the markers hold patterns (*.csproj) find must receive as written.
  set -f
  while IFS= read -r line; do
    for m in ${line##*|}; do markers="$markers -o -name $m"; done
  done <<EOF
$DCS_TOOLS
EOF
  # A .git is printed before the dataless prune and never entered, so a worktree whose own .git
  # file iCloud keeps only in the cloud is still found, and worktrees.sh says so (#1860).
  find "$H" \( -path "$H/Library" -o -path "$H/.Trash" -o -path "$H/.ssh" -o -path "$H/.gnupg" -o -path "$H/.claude/projects" \
      -o -path "$H/Dropbox" -o -path "$H/.dropbox" -o -path "$H/Google Drive" -o -path "$H/OneDrive" -o -path "$H/OneDrive - *" \
      -o -path "$H/Box" -o -path "$H/pCloud Drive" -o -path "$H/.pcloud" -o -path "$H/SynologyDrive" \
      -o -name '*.app' -o -name '*.photoslibrary' -o -name '*.musiclibrary' -o -name '*.tvlibrary' -o -name '*.imovielibrary' \
      -o -name '*.aplibrary' -o -name '*.fcpbundle' -o -name '*.lrdata' -o -name '*.lrlibrary' -o -name '*.lrcat-data' \
      -o -name '*.cocatalog' -o -name '*.cosessiondb' \) -prune \
    -o -name .git -print -prune \
    -o \( "${DCS_DL[@]}" \) -prune \
    -o -type d \( -name node_modules -o -name .next \) -print -prune \
    -o -type d -path '*/.wrangler/tmp' -print -prune \
    -o -type f \( -name '*.log' -size +"$DCS_LARGE_MB"M -o -name .nvmrc -o -name .python-version -o -name pyvenv.cfg $markers \
      -o \( \( -path "$H/Downloads/*" -o -path "$H/Desktop/*" -o -path "$H/Documents/*" -o -path "$H/Movies/*" \) -size +"$DCS_LARGE_MB"M \) \) -print
  local rc=$?
  set +f
  return "$rc"
}
# The walk scan.sh took, or a fresh one for a judge run on its own. Sets DCS_WALK (the file) and
# DCS_WALK_STATE: complete, "partial: N folder(s) could not be read" or "unmeasured: <why>".
dcs_walk_ready() {
  if [ -n "${DISK_CLEAN_WALK:-}" ]; then
    DCS_WALK="$DISK_CLEAN_WALK"; DCS_WALK_STATE="${DISK_CLEAN_WALK_STATE:-unmeasured: the scan did not say how its walk went}"
    [ -r "$DCS_WALK" ] || DCS_WALK_STATE="unmeasured: the walk's output could not be read"
    return 0
  fi
  DCS_WALK="$DCS_WORK/walk.own"
  dcs_walk > "$DCS_WALK" 2> "$DCS_WORK/walk.own.err"
  DCS_WALK_STATE="$(dcs_walk_state $? "$DCS_WORK/walk.own.err")"
}
dcs_walk_state() { # <find exit code> <stderr file>
  local n
  n="$(awk 'END { print NR }' "$2" 2>/dev/null)"; n="${n:-0}"
  if [ "$n" -gt 0 ]; then printf 'partial: %s folder(s) could not be read\n' "$n"
  elif [ "$1" -ne 0 ]; then printf 'partial: find exited %s\n' "$1"
  else printf 'complete\n'; fi
}

# ---------------------------------------------------------------------------------------------
# Flags a reviewer must see
# ---------------------------------------------------------------------------------------------
# File names that say a file holds keys or secrets. adbkey and the code signing settings were found
# in the personal MacBook's ~/.android and ~/.expo by the first real run of the forgotten tools
# predicate (2026-10-27), which the list then lacked.
DCS_CRED_NAMES='.env .env.* *.pem *.key *.p8 *.p12 *.keystore *.jks *.mobileprovision credentials credentials.json .npmrc .netrc gradle.properties settings-security.xml id_rsa id_ed25519 id_ecdsa adbkey *code-signing*'
# Prints the first file at or beneath <path> whose name says it holds keys or secrets; nothing when
# there is none.
dcs_credential() { # <path>
  local expr="" n
  set -f
  if [ -d "$1" ]; then
    for n in $DCS_CRED_NAMES; do expr="$expr${expr:+ -o} -name $n"; done
    # shellcheck disable=SC2086
    find "$1" \( -name node_modules -o -name .git -o -type d \( "${DCS_DL[@]}" \) \) -prune -o -type f \( $expr \) -print -quit 2>/dev/null
  else
    for n in $DCS_CRED_NAMES; do
      case "${1##*/}" in $n) printf '%s\n' "$1"; break ;; esac
    done
  fi
  set +f
}
# Succeeds when <path> lies in a Desktop or Documents folder iCloud syncs, where removing it removes
# it from iCloud on every device.
dcs_icloud() { # <path>
  local cd="$DCS_HOME/Library/Mobile Documents/com~apple~CloudDocs" p="$1"
  case "$p" in
    "$DCS_HOME/Desktop/"*|"$HOME/Desktop/"*) [ -d "$cd/Desktop" ] ;;
    "$DCS_HOME/Documents/"*|"$HOME/Documents/"*) [ -d "$cd/Documents" ] ;;
    *) return 1 ;;
  esac
}
# Joins flags and details: <flags var value> <new flag>
dcs_join() { if [ -n "$1" ]; then printf '%s,%s' "$1" "$2"; else printf '%s' "$2"; fi; }

dcs_init
