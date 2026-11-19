#!/usr/bin/env bash
# Tests for disk-clean's category modules (payload/skills/disk-clean/categories/*.sh, #1806).
#
# Each category rule the plan's red team settled is a check here, seen failing before the module
# existed (L1): the live session map for Claude Code temp, clean pushed and merged worktrees only
# with a gh failure unmeasured, .wrangler/tmp and never .wrangler/state, Playwright's .links and b/
# layout, a cache judged in use by an open file beneath it and never by its name, the Trash only as
# listed at scan time, and forgotten tools by the folder to command table plus 180 days unused.
#
# Every module runs ONLY through the disk-clean harness's dc_run (hooks/lib/disk-clean-harness.sh):
# HOME is a throwaway directory, PATH is stubs plus core tools, and du, lsof, ps, pgrep, git, gh,
# docker and the Xcode sweep are stubs given behaviour per case. Fixture files are made by this
# suite itself, outside dc_run. Sizes come from a du stub, so a 600 MB log is a sparse file that
# costs the disk nothing.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): hooks/lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/scan.sh"
CATS="$DIR/categories"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
finish() {
  echo ""
  echo "passed: $pass, failed: $fail"
  echo "SUITE-RESULT passed=$pass failed=$fail"
  [ "$fail" -eq 0 ]
  exit $?
}
eq() { [ "$1" = "$2" ] && echo ok || echo "expected '$2', got '$1'"; }
has() { grep -qF -- "$2" <<< "$1" && echo ok || echo "'$2' not in: $1"; }
hasnt() { grep -qF -- "$2" <<< "$1" && echo "'$2' should not be in: $1" || echo ok; }

. "$DIR/../../hooks/lib/disk-clean-harness.sh" || { check "the harness is there to source" "could not source it"; finish; }
. "$DIR/../../hooks/lib/disk-clean-record.sh" || { check "the record library is there to source" "could not source it"; finish; }
check "scan.sh is there to run" "$([ -f "$SCAN" ] && echo ok || echo "missing: $SCAN")"
dc_setup || { check "the harness sets up" "dc_setup failed"; finish; }

H="$DC_HOME"
STATE="$H/.claude/state/disk-clean"
REC="$STATE/last-scan.json"
S=$'\037'
OLD=202401011200   # a modification time well past every threshold

default_stubs() {
  dc_stub du 'for a in "$@"; do case "$a" in -*) ;; *) printf "12\t%s\n" "$a" ;; esac; done'
  dc_stub lsof 'exit 1'
  dc_stub ps 'echo "/usr/bin/login"'
  dc_stub pgrep 'exit 1'
  dc_stub docker 'exit 1'
  dc_stub git
  dc_stub gh
  dc_stub derived-data-sweep
}
fresh() {
  chmod -R u+rwx "$H" 2>/dev/null
  rm -rf "$H" "$DC_TMPDIR"
  mkdir -p "$H" "$DC_TMPDIR"
  : > "$DC_CALLS"
  : > "$DC_ROOT/refused.log"
  default_stubs
}
run_scan() { OUT_TEXT="$(dc_run bash "$SCAN" "$@" 2>&1)"; RC=$?; }
judge() { # <category> <target>
  JUDGED="$(dc_run env DISK_CLEAN_CATEGORY="$1" bash "$CATS/$1.sh" judge "$2" 2>&1)"; JRC=$?
}
# The item for <target> from the record, as id, category, method, target, state, bytes, identity,
# size, flags and detail separated by \037; empty when the record has none.
item_of() { [ -f "$REC" ] || return 0; dcr_review_items "$REC" | awk -F "$S" -v t="$1" '$4 == t && !f { print; f = 1 }'; }
field() { awk -F "$S" -v n="$2" '{ print $n }' <<< "$1"; }
state_of() { field "$(item_of "$1")" 5; }
method_of() { field "$(item_of "$1")" 3; }
flags_of() { field "$(item_of "$1")" 9; }
detail_of() { field "$(item_of "$1")" 10; }
status_of() { dcr_header "$REC" "status.$1" 2>/dev/null; }
note_of() { dcr_header "$REC" "note.$1" 2>/dev/null; }
items_in() { [ -f "$REC" ] && dcr_items "$REC" | awk -F "$S" -v c="$1" '$2 == c' | wc -l | tr -d ' ' || echo 0; }
old() { find "$1" -exec touch -t "$OLD" {} + ; }
sparse() { mkdir -p "${1%/*}"; dd if=/dev/zero of="$1" bs=1 count=0 seek="$2" 2>/dev/null; } # <file> <size, such as 600m>
# Five days ago, as touch -t takes it: well inside the 30 day floor, and far enough from its edge
# that no run, however slow, crosses it (L290: the times are set, never waited for).
RECENT="$(date -v-5d '+%Y%m%d%H%M' 2>/dev/null || date -d '5 days ago' '+%Y%m%d%H%M')"
# The 30 day floor every kind but the Trash adds to its own rule (#2134), on <target>, which its
# own rule offers: <file> is a file at or beneath it. Opened is the access time, changed the
# modification time, each set alone, and with "folder" a part of it nothing can read is unmeasured.
# With "own-age", the kind's own longer rule (90 or 180 days) already refuses a recent change, so
# only the opened half is the floor's to check. Ends with the target aged again, so the section's
# later checks see it as they did.
floor_checks() { # <category> <target> <file> [folder] [own-age]
  local c="$1" t="$2" f="$3" o folder="" own=""
  for o in "${@:4}"; do case "$o" in folder) folder=1 ;; own-age) own=1 ;; esac; done
  old "$t"; judge "$c" "$t"
  check "$c floor: with nothing in it changed or opened for 30 days it is offerable (the control)" "$(eq "$JUDGED" offerable)"
  touch -a -t "$RECENT" "$f"; judge "$c" "$t"
  check "$c floor: a file in it opened 5 days ago, changed long ago, makes it not offerable" "$(has "$JUDGED" "not offerable: opened within 30 days")"
  old "$t"
  if [ -z "$own" ]; then
    touch -m -t "$RECENT" "$f"; judge "$c" "$t"
    check "$c floor: a file in it changed 5 days ago makes it not offerable" "$(has "$JUDGED" "not offerable: changed within 30 days")"
    old "$t"
  fi
  [ -n "$folder" ] || return 0
  mkdir -p "$t/floor-locked"; printf 'x\n' > "$t/floor-locked/f"; old "$t"; chmod 000 "$t/floor-locked"
  judge "$c" "$t"
  check "$c floor: a part of it whose times cannot be read makes it unmeasured, never offerable" "$(has "$JUDGED" "unmeasured: ")"
  chmod 755 "$t/floor-locked"; rm -rf "$t/floor-locked"; old "$t"
}

# ================================================================================================
# The Trash: only entries listed at scan time (name plus inode), and never what disk-clean moved
# there itself during this run
# ================================================================================================
fresh
mkdir -p "$H/.Trash/old folder" "$H/Downloads"
printf 'a\n' > "$H/.Trash/photo.NEF"; printf 'b\n' > "$H/.Trash/old folder/x"
run_scan --only trash
check "trash: the scan exits 0" "$(eq "$RC" 0)"
check "trash: an entry is offered" "$(eq "$(state_of "$H/.Trash/photo.NEF")" offerable)"
check "trash: by deleting it, since it is already in the Trash" "$(eq "$(method_of "$H/.Trash/photo.NEF")" delete)"
check "trash: a folder entry is offered whole" "$(eq "$(state_of "$H/.Trash/old folder")" offerable)"
check "trash: what is inside a folder entry is not listed apart" "$(eq "$(item_of "$H/.Trash/old folder/x")" "")"
check "trash: every entry carries its identity" "$(eq "$(field "$(item_of "$H/.Trash/photo.NEF")" 7 | grep -c ':')" 1)"
judge trash "$H/.Trash/photo.NEF"
check "trash judge: an entry listed at scan time is offerable" "$(eq "$JUDGED" offerable)"
# The Trash is exempt from the 30 day floor (#2134): everything in it was put there to go.
touch -a -t "$RECENT" "$H/.Trash/photo.NEF"; touch -m -t "$RECENT" "$H/.Trash/photo.NEF"
judge trash "$H/.Trash/photo.NEF"
check "trash judge: an entry changed and opened 5 days ago is still offerable, at any age" "$(eq "$JUDGED" offerable)"
printf 'c\n' > "$H/.Trash/later.txt"
judge trash "$H/.Trash/later.txt"
check "trash judge: an entry added after the scan is not offerable" "$(has "$JUDGED" "not offerable: it was not in the Trash when the scan ran")"
# The replacement is written while the original still exists, then moved over it, so the two
# can never share an inode: deleting first let Linux hand the freed inode straight back (#1851 CI).
printf 'replaced\n' > "$H/.Trash/photo.new"; mv -f "$H/.Trash/photo.new" "$H/.Trash/photo.NEF"
judge trash "$H/.Trash/photo.NEF"
check "trash judge: an entry replaced since the scan (same name, new inode) is not offerable" "$(has "$JUDGED" "not offerable: it is not the entry the scan listed")"
# What disk-clean trashed this run: an item of another category marked trashed, whose file now sits
# in the Trash with the same inode, as a move within one volume keeps it.
printf 'big\n' > "$H/Downloads/movie.mov"
# GNU stat first, as disk-remove.sh and scan-lib.sh's dcs_identity ask: on Linux, GNU stat -f is a
# file system query that succeeds and prints junk, so asking it first never reaches -c (#1851).
ident="$(stat -c '%d:%i' "$H/Downloads/movie.mov" 2>/dev/null || stat -f '%d:%i' "$H/Downloads/movie.mov")"
sid="$(dcr_header "$REC" scan_id)"
awk -v t="$H/Downloads/movie.mov" -v i="$ident" '/^\{"id":/ && !done { print "{\"id\":\"lf-1\",\"category\":\"large-files\",\"method\":\"trash\",\"target\":\"" t "\",\"bytes\":4096,\"state\":\"offerable\",\"identity\":\"" i "\"},"; done = 1 } { print }' "$REC" > "$REC.new" && mv "$REC.new" "$REC"
printf 'lf-1%strashed\n' "$S" > "$DC_ROOT/marks"; dcr_mark "$REC" "$sid" "$DC_ROOT/marks"
mv "$H/Downloads/movie.mov" "$H/.Trash/movie.mov"
judge trash "$H/.Trash/movie.mov"
check "trash judge: what disk-clean moved to the Trash this run is never offered" "$(has "$JUDGED" "not offerable: disk-clean moved it to the Trash during this scan's removals")"
judge trash "$H/Downloads/elsewhere"
check "trash judge: a path outside the Trash is not offerable" "$(has "$JUDGED" "not offerable: it is not an entry of the Trash")"
fresh
mkdir -p "$H/.Trash"; printf 'a\n' > "$H/.Trash/a"; chmod 000 "$H/.Trash"
run_scan --only trash
check "trash: an unreadable Trash makes the category unmeasured, never empty" "$(has "$(status_of trash)" "unmeasured: the Trash could not be listed")"
check "trash: and names Full Disk Access" "$(has "$(status_of trash)" "Full Disk Access")"
chmod 700 "$H/.Trash"

# ================================================================================================
# Caches: in use is any running process holding a file beneath the folder, never the folder's name
# ================================================================================================
fresh
C="$H/Library/Caches"
mkdir -p "$C/com.tinyspeck.slackmacgap" "$C/SomeHelperCache/sub" "$C/com.idle.app" "$C/CloudKit" "$C/com.apple.bird" \
  "$C/com.apple.nsurlsessiond" "$C/ms-playwright/chromium-1"
printf 'x\n' > "$C/com.idle.app/Cache.db"; old "$C"
dc_stub lsof "printf 'p10\ncSlack Helper\nf3\nn%s\n' $(printf %q "$C/SomeHelperCache/sub/data.db")"
run_scan --only caches
check "caches: a folder not named by bundle id with a file held open beneath it is in use" "$(has "$(state_of "$C/SomeHelperCache")" "not offerable: in use by Slack Helper")"
check "caches: a folder named after an app with nothing held open in it is offerable" "$(eq "$(state_of "$C/com.tinyspeck.slackmacgap")" offerable)"
check "caches: by deleting it" "$(eq "$(method_of "$C/com.idle.app")" delete)"
for n in CloudKit com.apple.bird com.apple.nsurlsessiond; do
  check "caches: $n is never offered" "$(has "$(state_of "$C/$n")" "not offerable: ")"
done
check "caches: ms-playwright belongs to the Playwright category, not this one" "$(eq "$(item_of "$C/ms-playwright")" "")"
judge caches "$C/com.idle.app"
check "caches judge: an idle cache is offerable" "$(eq "$JUDGED" offerable)"
floor_checks caches "$C/com.idle.app" "$C/com.idle.app/Cache.db" folder
touch -a -t "$RECENT" "$C/com.idle.app/Cache.db"
run_scan --only caches
check "caches: the scan applies the floor as the judge does: a cache opened 5 days ago is not offered" "$(has "$(state_of "$C/com.idle.app")" "not offerable: opened within 30 days")"
old "$C"
judge caches "$C/SomeHelperCache"
check "caches judge: a cache with an open file beneath it is not" "$(has "$JUDGED" "not offerable: in use by Slack Helper")"
judge caches "$H/Library/Preferences"
check "caches judge: a folder outside Caches is not offerable" "$(has "$JUDGED" "not offerable: it is not a folder directly inside")"
dc_stub lsof 'echo "lsof: WARNING: can not stat() fuse file system" >&2; exit 1'
run_scan --only caches
check "caches: lsof saying anything on stderr makes in use unknown, never free" "$(has "$(state_of "$C/com.idle.app")" "unmeasured: could not tell whether it is in use")"
# Sizes: du's exit code and stderr decide measured, partial or permission denied; never 0 for unread.
dc_stub lsof 'exit 1'
dc_stub du "for a in \"\$@\"; do case \"\$a\" in -*) ;; */com.idle.app) printf '40\t%s\n' \"\$a\"; echo \"du: \$a/locked: Permission denied\" >&2 ;; */com.tinyspeck.slackmacgap) echo \"du: \$a: Operation not permitted\" >&2 ;; *) printf '12\t%s\n' \"\$a\" ;; esac; done; exit 1"
run_scan --only caches
it="$(item_of "$C/com.idle.app")"
check "caches: a figure du gave while failing beneath the folder is partial" "$(eq "$(field "$it" 8)" partial)"
check "caches: and keeps its figure as a lower bound" "$(eq "$(field "$it" 6)" "$((40 * 1024))")"
it="$(item_of "$C/com.tinyspeck.slackmacgap")"
check "caches: a folder du could not read at all is permission denied" "$(eq "$(field "$it" 8)" denied)"
check "caches: with no figure, never 0" "$(eq "$(field "$it" 6)" "")"
it="$(item_of "$C/CloudKit")"
check "caches: a folder du read cleanly in the same run is still measured" "$(eq "$(field "$it" 8)" measured)"

# ================================================================================================
# Xcode build caches: orphans through derived-data-sweep.sh; the rest only while no xcodebuild runs
# ================================================================================================
fresh
DD="$H/Library/Developer/Xcode/DerivedData"
mkdir -p "$DD/App-orphan/Build" "$DD/App-live" "$DD/App-busy" "$DD/ModuleCache.noindex" "$DD/App-noplist"
printf 'x\n' > "$DD/App-orphan/Build/obj.o"; printf '<plist/>\n' > "$DD/App-orphan/info.plist"; old "$H/Library"
dc_stub derived-data-sweep "T=\$(printf '\t'); [ \"\$1\" = --classify ] || exit 2; shift; for d in \"\$@\"; do case \"\$d\" in
  */App-orphan) echo \"orphan\${T}\$d\${T}/gone/App.xcodeproj\" ;; */App-live) echo \"live\${T}\$d\${T}/here/App.xcodeproj\" ;;
  */App-busy) echo \"in-use\${T}\$d\${T}modified in the last 60 minutes\" ;; */ModuleCache.noindex) echo \"shared-cache\${T}\$d\${T}\" ;;
  *) echo \"unattributed\${T}\$d\${T}no-info-plist\" ;; esac; done"
run_scan --only xcode
check "xcode: an orphan is offered through the Xcode build cache sweep" "$(eq "$(method_of "$DD/App-orphan")" derived-data)"
check "xcode: and is offerable" "$(eq "$(state_of "$DD/App-orphan")" offerable)"
check "xcode: a live project's cache is offered separately, by deleting it, while no xcodebuild runs" "$(eq "$(method_of "$DD/App-live") $(state_of "$DD/App-live")" "delete offerable")"
check "xcode: an orphan a build may still be using is not offerable" "$(has "$(state_of "$DD/App-busy")" "not offerable: a build may still be using it")"
check "xcode: a shared cache is not offerable" "$(has "$(state_of "$DD/ModuleCache.noindex")" "not offerable: ")"
check "xcode: a folder nothing attributes is not offerable" "$(has "$(state_of "$DD/App-noplist")" "not offerable: nothing says which project made it")"
dc_stub pgrep 'echo 4242'
run_scan --only xcode
check "xcode: with xcodebuild running a live project's cache is not offerable" "$(has "$(state_of "$DD/App-live")" "not offerable: xcodebuild is running")"
check "xcode: but an orphan still is" "$(eq "$(state_of "$DD/App-orphan")" offerable)"
dc_stub pgrep 'echo "pgrep: cannot list processes" >&2; exit 3'
run_scan --only xcode
check "xcode: when whether xcodebuild runs cannot be told, a live cache is unmeasured" "$(has "$(state_of "$DD/App-live")" "unmeasured: ")"
dc_stub pgrep 'exit 1'
judge xcode "$DD/App-orphan"
check "xcode judge: an orphan is offerable" "$(eq "$JUDGED" offerable)"
floor_checks xcode "$DD/App-orphan" "$DD/App-orphan/Build/obj.o" folder
# The sweep reads info.plist to name the project, which moves its access time on the first read
# after a build; the scan's own read must not count as the folder being opened.
touch -a -t "$RECENT" "$DD/App-orphan/info.plist"
judge xcode "$DD/App-orphan"
check "xcode floor: an info.plist read, as the sweep itself reads it, is not counted as opened" "$(eq "$JUDGED" offerable)"
touch -m -t "$RECENT" "$DD/App-orphan/info.plist"
judge xcode "$DD/App-orphan"
check "xcode floor: but an info.plist changed 5 days ago still counts as changed" "$(has "$JUDGED" "not offerable: changed within 30 days")"
old "$DD/App-orphan"
judge xcode "$DD/App-busy"
check "xcode judge: an orphan in use is not" "$(has "$JUDGED" "not offerable: a build may still be using it")"
dc_stub derived-data-sweep 'echo "derived-data-sweep: could not read it"; exit 2'
run_scan --only xcode
check "xcode: a sweep that cannot classify makes the category unmeasured" "$(has "$(status_of xcode)" "unmeasured: the Xcode build cache sweep could not classify")"

# ================================================================================================
# Build folders: node_modules and .next by the project's own newest file; .wrangler/tmp only,
# never .wrangler/state
# ================================================================================================
fresh
P="$H/Apps"
mkdir -p "$P/stale/node_modules/x" "$P/stale/.next/cache" "$P/stale/src" "$P/active/node_modules/x" "$P/active/src" \
  "$P/worker/.wrangler/tmp/b" "$P/worker/.wrangler/state/v3/d1" "$P/nopkg/node_modules/x" "$H/.nvm/versions/node/v20/lib/node_modules/x"
printf '{}\n' > "$P/stale/package.json"; printf 'x\n' > "$P/stale/src/a.ts"
printf '{}\n' > "$P/active/package.json"; printf 'x\n' > "$P/active/src/a.ts"
printf 'name = "w"\n' > "$P/worker/wrangler.toml"
printf '{}\n' > "$H/.nvm/versions/node/v20/lib/package.json"
old "$P/stale"; old "$P/worker"; old "$P/active"; printf 'edited\n' > "$P/active/src/a.ts"
# A file inside node_modules itself is new, which must not count as the PROJECT being used; it does
# count as the folder itself having changed, under the 30 day floor every kind keeps (#2134).
printf 'new\n' > "$P/stale/node_modules/x/fresh.js"
run_scan --only build-folders
check "build folders: a new file inside node_modules is the folder changing, not the project" "$(eq "$(state_of "$P/stale/node_modules")" "not offerable: changed within 30 days (x/fresh.js)")"
old "$P/stale/node_modules"
run_scan --only build-folders
check "build folders: node_modules of a project untouched for 30 days is offerable" "$(eq "$(state_of "$P/stale/node_modules")" offerable)"
check "build folders: by deleting it" "$(eq "$(method_of "$P/stale/node_modules")" delete)"
check "build folders: its .next too" "$(eq "$(state_of "$P/stale/.next")" offerable)"
check "build folders: a project whose own files changed recently keeps its node_modules" "$(has "$(state_of "$P/active/node_modules")" "not offerable: the project's own files changed within 30 days")"
check "build folders: .wrangler/tmp is offerable" "$(eq "$(state_of "$P/worker/.wrangler/tmp")" offerable)"
check "build folders: .wrangler/state is never listed (local D1, KV and R2 data)" "$(eq "$(item_of "$P/worker/.wrangler/state")" "")"
check "build folders: nor .wrangler as a whole" "$(eq "$(item_of "$P/worker/.wrangler")" "")"
check "build folders: node_modules with no package.json beside it is not a project's, so not listed" "$(eq "$(item_of "$P/nopkg/node_modules")" "")"
check "build folders: nothing under a home dotfolder (global node packages) is listed" "$(eq "$(item_of "$H/.nvm/versions/node/v20/lib/node_modules")" "")"
judge build-folders "$P/worker/.wrangler/state"
check "build folders judge: .wrangler/state is not offerable" "$(has "$JUDGED" "not offerable: ")"
judge build-folders "$P/stale/node_modules"
check "build folders judge: a stale project's node_modules is offerable" "$(eq "$JUDGED" offerable)"
floor_checks build-folders "$P/stale/node_modules" "$P/stale/node_modules/x/fresh.js" folder
printf 'today\n' > "$P/stale/src/b.ts"
judge build-folders "$P/stale/node_modules"
check "build folders judge: once the project is edited again it is not" "$(has "$JUDGED" "not offerable: the project's own files changed within 30 days")"

# A build folder iCloud syncs (Documents or Desktop while iCloud syncs them) is never offered:
# removing one removes it from iCloud on every device (#3215: the personal MacBook's dry run offered
# 98 of them). It is left out of the list, counted in the kind's note so leaving it out is visible,
# and the judge refuses it, so a record from before this rule cannot remove one either.
fresh
mkdir -p "$H/Library/Mobile Documents/com~apple~CloudDocs/Documents" "$H/Documents/proj/node_modules/x" "$H/Documents/proj/src" \
  "$H/Documents/proj2/node_modules/x" "$H/Apps/local/node_modules/x"
printf '{}\n' > "$H/Documents/proj/package.json"; printf 'x\n' > "$H/Documents/proj/src/a.ts"
printf '{}\n' > "$H/Documents/proj2/package.json"; printf '{}\n' > "$H/Apps/local/package.json"
old "$H/Documents"; old "$H/Apps"
run_scan --only build-folders
check "build folders: one iCloud syncs is not listed" "$(eq "$(item_of "$H/Documents/proj/node_modules")" "")"
check "build folders: nor its neighbour" "$(eq "$(item_of "$H/Documents/proj2/node_modules")" "")"
check "build folders: a project outside iCloud is still offered (the control)" "$(eq "$(state_of "$H/Apps/local/node_modules")" offerable)"
check "build folders: the kind's note counts what iCloud syncs and says why" "$(eq "$(note_of build-folders)" "2 build folders were left out because iCloud syncs them: removing one would remove it from iCloud on every device.")"
check "build folders: the scan's summary says so too" "$(has "$OUT_TEXT" "2 build folders were left out because iCloud syncs them")"
check "build folders: one iCloud syncs is never passed to du" "$(hasnt "$(dc_calls du)" "$H/Documents/proj/node_modules")"
judge build-folders "$H/Documents/proj/node_modules"
check "build folders judge: one iCloud syncs is not offerable" "$(eq "$JUDGED" "not offerable: iCloud syncs it, so removing it would remove it from iCloud on every device")"
# The control: the same folder once iCloud no longer syncs Documents is listed and offered.
rm -rf "$H/Library/Mobile Documents/com~apple~CloudDocs/Documents"
run_scan --only build-folders
check "build folders: once iCloud does not sync Documents, the same folder is offered" "$(eq "$(state_of "$H/Documents/proj/node_modules")" offerable)"
check "build folders: and no note is written" "$(eq "$(note_of build-folders)" "")"
mkdir -p "$H/Library/Mobile Documents/com~apple~CloudDocs/Documents"; rm -rf "$H/Documents/proj2"; old "$H/Documents"
run_scan --only build-folders
check "build folders: one left out is counted in the singular" "$(eq "$(note_of build-folders)" "1 build folder was left out because iCloud syncs it: removing it would remove it from iCloud on every device.")"

# A folder iCloud keeps only in the cloud (dataless) is never read, because listing one makes iCloud
# fetch it, and du does not skip it (#1860: four Slate worktree build folders held 1,673). chflags
# cannot set the flag, so DISK_CLEAN_DATALESS names a file of paths that stand in for dataless ones,
# honoured only in test mode. A folder with one beneath it is sized by a find that stops there,
# never by du, and its size is exact for this Mac (nothing under a dataless folder is stored here),
# so it is measured, never partial, and flagged icloud-only-part.
fresh
P="$H/Apps"
mkdir -p "$P/cloudy/node_modules/local" "$P/cloudy/node_modules/evicted/deep" "$P/cloudy/src" "$P/gone/node_modules/x" "$P/plain/node_modules/x"
printf '{}\n' > "$P/cloudy/package.json"; printf 'x\n' > "$P/cloudy/src/a.ts"; printf '{}\n' > "$P/gone/package.json"; printf '{}\n' > "$P/plain/package.json"
dd if=/dev/zero of="$P/cloudy/node_modules/local/a.bin" bs=1024 count=64 2>/dev/null
dd if=/dev/zero of="$P/cloudy/node_modules/evicted/deep/b.bin" bs=1024 count=1024 2>/dev/null
old "$P/cloudy"; old "$P/gone"; old "$P/plain"
printf '%s\n' "$P/cloudy/node_modules/evicted" "$P/gone" > "$DC_ROOT/dataless"
dl_run_scan() { OUT_TEXT="$(dc_run env DISK_CLEAN_DATALESS="$DC_ROOT/dataless" bash "$SCAN" "$@" 2>&1)"; RC=$?; }
dl_run_scan --only build-folders
it="$(item_of "$P/cloudy/node_modules")"
# What is stored outside the stand-in, read by this suite's own du on its own scratch folder.
want_kib=$(( $(du -sk "$P/cloudy/node_modules" | awk '{ print $1 }') - $(du -sk "$P/cloudy/node_modules/evicted" | awk '{ print $1 }') ))
# Listed, but never offered: what the cloud only folder holds cannot be read without fetching it, so
# whether any of it was changed or opened in 30 days is not known (#2134).
check "build folders: a folder holding a cloud only folder is still listed, and unmeasured" "$(has "$(state_of "$P/cloudy/node_modules")" "unmeasured: part of it is kept only in iCloud")"
check "build folders: the folder beside it with nothing in the cloud is offerable (the control)" "$(eq "$(state_of "$P/plain/node_modules")" offerable)"
check "build folders: it is never passed to du" "$(hasnt "$(dc_calls du)" "$P/cloudy/node_modules")"
check "build folders: its size is what is stored here, the cloud only folder left out" "$(eq "$(field "$it" 6)" "$((want_kib * 1024))")"
check "build folders: and that size is exact, so measured, never partial" "$(eq "$(field "$it" 8)" measured)"
check "build folders: it is flagged as partly kept only in iCloud" "$(has "$(flags_of "$P/cloudy/node_modules")" icloud-only-part)"
check "build folders: a folder with no cloud only folder beneath it is still sized by du" "$(has "$(dc_calls du)" "$P/plain/node_modules")"
check "build folders: and is not flagged as partly kept only in iCloud" "$(hasnt "$(flags_of "$P/plain/node_modules")" icloud-only-part)"
# The search for cloud only folders takes the listed paths 200 to a find, so a list longer than that
# crosses a batch (L101): the first and the last of 201 cache folders hold a stand-in.
fresh
C="$H/Library/Caches"
for n in $(seq -w 1 201); do mkdir -p "$C/app$n"; done
mkdir -p "$C/app001/evicted" "$C/app201/evicted"; printf '%s\n' "$C/app001/evicted" "$C/app201/evicted" > "$DC_ROOT/dataless"
dl_run_scan --only caches
check "sizes: a cloud only folder in a full first batch of 200 is found and flagged" "$(has "$(flags_of "$C/app001")" icloud-only-part)"
check "sizes: and one in the batch after it too" "$(has "$(flags_of "$C/app201")" icloud-only-part)"
check "sizes: the folders between them are still sized by du" "$(eq "$(field "$(item_of "$C/app100")" 8) $(hasnt "$(flags_of "$C/app100")" icloud-only-part) $(has "$(dc_calls du)" "$C/app100")" "measured ok ok")"
check "build folders: the walk never goes into a cloud only project folder" "$(eq "$(item_of "$P/gone/node_modules")" "")"

# ================================================================================================
# Docker: only when docker info answers; volumes listed and never offerable
# ================================================================================================
fresh
run_scan --only docker
check "docker: when docker info fails the category is unmeasured" "$(has "$(status_of docker)" "unmeasured: Docker is not running")"
rm -f "$DC_STUBS/docker"
run_scan --only docker
check "docker: with no docker command the category is unmeasured, naming the tool" "$(has "$(status_of docker)" "unmeasured: docker is not installed")"
dc_stub docker 'case "$1 $2" in
  "info "*) echo ok ;;
  "images "*) printf "sha256abc\t1.5GB\n" ;;
  "ps "*) printf "c0ffee\told_web\t12.3MB (virtual 1GB)\n" ;;
  "volume ls") echo pgdata ;;
  "system df") printf "Images|2GB\nBuild Cache|3.2GB\n" ;;
  "image inspect") echo 0 ;;
  "container inspect") cat '"$(printf %q "$DC_ROOT/docker-inspect")"' ;;
  *) echo "docker stub: $*" >&2; exit 1 ;;
esac'
# What container inspect answers: running, then Created, StartedAt and FinishedAt as Docker prints
# them (UTC, nanoseconds), all long past; StartedAt is Docker's zero time for a container never run.
printf 'false 2024-01-01T12:00:00.123456789Z 0001-01-01T00:00:00Z 2024-01-03T08:00:00.5Z\n' > "$DC_ROOT/docker-inspect"
run_scan --only docker
# Docker records when an image was made and last tagged, never when it was last used, so whether a
# dangling image or the build cache was used in 30 days is not read and neither is offered (#2134).
check "docker: a dangling image is unmeasured under the 30 day floor" "$(has "$(state_of "image sha256abc")" "unmeasured: Docker records no time an image was last used")"
check "docker: through the docker method" "$(eq "$(method_of "image sha256abc")" docker)"
check "docker: with Docker's own figure" "$(eq "$(field "$(item_of "image sha256abc")" 8)" reported)"
check "docker: a stopped container last run long ago is offerable" "$(eq "$(state_of "container c0ffee")" offerable)"
check "docker: the build cache is unmeasured under the 30 day floor" "$(has "$(state_of "builder cache")" "unmeasured: ")"
check "docker: a volume is listed and never offerable" "$(has "$(state_of "volume pgdata")" "not offerable: Docker volumes hold data")"
judge docker "volume pgdata"
check "docker judge: a volume is not offerable" "$(has "$JUDGED" "not offerable: ")"
judge docker "image sha256abc"
check "docker judge: a dangling image is unmeasured" "$(has "$JUDGED" "unmeasured: Docker records no time an image was last used")"
judge docker "builder cache"
check "docker judge: the build cache is unmeasured" "$(has "$JUDGED" "unmeasured: ")"
judge docker "container c0ffee"
check "docker judge: a container created, run and stopped long ago is offerable (the control)" "$(eq "$JUDGED" offerable)"
printf 'false 2024-01-01T12:00:00Z 2024-01-02T00:00:00Z %s\n' "$(date -u -v-5d '+%Y-%m-%dT%H:%M:%S.000000001Z' 2>/dev/null || date -u -d '5 days ago' '+%Y-%m-%dT%H:%M:%S.000000001Z')" > "$DC_ROOT/docker-inspect"
judge docker "container c0ffee"
check "docker judge: a container that stopped 5 days ago is not offerable" "$(has "$JUDGED" "not offerable: used within 30 days")"
run_scan --only docker
check "docker: the scan applies the floor as the judge does" "$(has "$(state_of "container c0ffee")" "not offerable: used within 30 days")"
printf 'false 2024-01-01T12:00:00Z yesterday 2024-01-03T00:00:00Z\n' > "$DC_ROOT/docker-inspect"
judge docker "container c0ffee"
check "docker judge: a time Docker gave that cannot be read is unmeasured, never offerable" "$(has "$JUDGED" "unmeasured: ")"
printf 'false 2024-01-01T12:00:00Z\n' > "$DC_ROOT/docker-inspect"
judge docker "container c0ffee"
check "docker judge: a missing time is unmeasured too" "$(has "$JUDGED" "unmeasured: ")"
printf 'true 2024-01-01T12:00:00Z 2024-01-02T00:00:00Z 2024-01-03T00:00:00Z\n' > "$DC_ROOT/docker-inspect"
judge docker "container c0ffee"
check "docker judge: a running container is still not offerable" "$(has "$JUDGED" "not offerable: it is running")"

# ================================================================================================
# Playwright: a revision is offerable only when no project in .links, nor any b/ entry, needs it
# ================================================================================================
fresh
PW="$H/Library/Caches/ms-playwright"
LA="$H/Apps/one/node_modules/playwright-core"; LB="$H/.npm/_npx/x/node_modules/playwright-core"
mkdir -p "$PW/.links" "$PW/b" "$LA" "$LB" "$PW/chromium-1243" "$PW/chromium_headless_shell-1243" "$PW/chromium-1100" \
  "$PW/webkit-2359" "$PW/ffmpeg-1011" "$PW/firefox-1500"
printf '%s' "$LA" > "$PW/.links/aaa"
printf '%s' "$H/Apps/deleted/node_modules/playwright-core" > "$PW/.links/bbb"
cat > "$LA/browsers.json" <<'JSON'
{
  "comment": "Do not edit this file, use utils/roll_browser.js",
  "browsers": [
    {
      "name": "chromium",
      "revision": "1243",
      "installByDefault": true,
      "browserVersion": "141.0.7390.37"
    },
    {
      "name": "chromium-headless-shell",
      "revision": "1243",
      "installByDefault": true
    },
    {
      "name": "ffmpeg",
      "revision": "1011",
      "installByDefault": true
    }
  ]
}
JSON
printf '{\n  "name": "webkit",\n  "revision": "2200",\n  "revisionOverrides": {\n    "mac14": "2359"\n  }\n}\n' > "$LB/browsers.json"
printf '{\n  "playwrightVersion": "1.63.0",\n  "playwrightLib": "%s",\n  "title": "claude-code"\n}\n' "$LB" > "$PW/b/browser@079b"
printf 'x\n' > "$PW/chromium-1100/chrome"; old "$PW"
run_scan --only playwright
check "playwright: a revision a linked project needs is kept" "$(has "$(state_of "$PW/chromium-1243")" "not offerable: ")"
check "playwright: chromium-headless-shell's folder is matched by its underscored name" "$(has "$(state_of "$PW/chromium_headless_shell-1243")" "not offerable: ")"
check "playwright: a revision named only in a b/ entry's library (an override) is kept" "$(has "$(state_of "$PW/webkit-2359")" "not offerable: ")"
check "playwright: a revision nothing needs is offerable" "$(eq "$(state_of "$PW/chromium-1100")" offerable)"
check "playwright: another browser nothing needs is offerable" "$(eq "$(state_of "$PW/firefox-1500")" offerable)"
check "playwright: .links and b are never items" "$(eq "$(item_of "$PW/.links")$(item_of "$PW/b")" "")"
judge playwright "$PW/chromium-1100"
check "playwright judge: an unneeded revision is offerable" "$(eq "$JUDGED" offerable)"
# Running a browser moves its executable's access time on every run (measured for #2134).
floor_checks playwright "$PW/chromium-1100" "$PW/chromium-1100/chrome" folder
judge playwright "$PW/ffmpeg-1011"
check "playwright judge: a needed one is not" "$(has "$JUDGED" "not offerable: ")"
rm -f "$LA/browsers.json"
run_scan --only playwright
check "playwright: a linked library whose browsers.json cannot be read makes the category unmeasured" "$(has "$(status_of playwright)" "unmeasured: ")"

# ================================================================================================
# Claude Code temp: <slug>/<uuid> folders no live session owns, nothing in them changed or opened
# for DCS_UNUSED_DAYS (the floor every kind keeps, #2134)
# ================================================================================================
fresh
uid="$(id -u)"
CT="$DC_TMPDIR/claude-$uid/-Users-x-Apps-proj"
U1=11111111-1111-4111-8111-111111111111; U2=22222222-2222-4222-8222-222222222222; U3=33333333-3333-4333-8333-333333333333
mkdir -p "$CT/$U1/scratchpad" "$CT/$U2/scratchpad" "$CT/$U3/scratchpad" "$CT/not-a-uuid" "$H/.claude/sessions"
printf 'x\n' > "$CT/$U1/scratchpad/f"; printf 'x\n' > "$CT/$U2/scratchpad/f"; printf 'x\n' > "$CT/$U3/scratchpad/f"
old "$CT/$U1"; old "$CT/$U2"
printf '{"pid":1,"sessionId":"%s","cwd":"/x"}\n' "$U1" > "$H/.claude/sessions/1.json"
run_scan --only claude-temp
check "claude temp: a live session's folder is not offerable, however old" "$(has "$(state_of "$CT/$U1")" "not offerable: a live session")"
check "claude temp: a folder no session owns, untouched for 30 days, is offerable" "$(eq "$(state_of "$CT/$U2")" offerable)"
check "claude temp: by deleting it" "$(eq "$(method_of "$CT/$U2")" delete)"
check "claude temp: a folder changed today is not offerable" "$(has "$(state_of "$CT/$U3")" "not offerable: changed within 30 days")"
check "claude temp: a folder that is not a session id is not listed" "$(eq "$(item_of "$CT/not-a-uuid")" "")"
check "claude temp: the slug folder itself is not listed" "$(eq "$(item_of "$CT")" "")"
judge claude-temp "$CT/$U1"
check "claude temp judge: a live session's folder is not offerable" "$(has "$JUDGED" "not offerable: a live session")"
judge claude-temp "$CT/$U2"
check "claude temp judge: an abandoned one is offerable" "$(eq "$JUDGED" offerable)"
floor_checks claude-temp "$CT/$U2" "$CT/$U2/scratchpad/f" folder
rm -f "$H/.claude/sessions/1.json"
dc_stub ps 'echo "/usr/bin/login"; echo "/usr/local/bin/claude"'
run_scan --only claude-temp
check "claude temp: an empty session map while Claude Code runs makes the category unmeasured" "$(has "$(status_of claude-temp)" "unmeasured: the session map")"
check "claude temp: and offers nothing" "$(hasnt "$(state_of "$CT/$U1")" offerable)"
printf '{"pid":1,"sessionId":"%s","cwd":"/x"}\n' "$U1" > "$H/.claude/sessions/1.json"; chmod 000 "$H/.claude/sessions/1.json"
run_scan --only claude-temp
check "claude temp: an unreadable session map makes the category unmeasured" "$(has "$(status_of claude-temp)" "unmeasured: the session map")"
chmod 600 "$H/.claude/sessions/1.json"
# A folder find could not read all of is never offered (#1851): its errors once went to /dev/null,
# so a folder with an unreadable subfolder, in which nothing readable was recent, read as abandoned
# although the unread part could have been used a minute ago.
U4=44444444-4444-4444-8444-444444444444
mkdir -p "$CT/$U4/locked/inner"; printf 'x\n' > "$CT/$U4/locked/inner/f"
old "$CT/$U4"; chmod 000 "$CT/$U4/locked"
run_scan --only claude-temp
check "claude temp: a folder find could not wholly read is unmeasured, never offerable" "$(has "$(state_of "$CT/$U4")" "unmeasured: part of it could not be read")"
check "claude temp: and says what find said" "$(has "$(state_of "$CT/$U4")" "Permission denied")"
check "claude temp: an abandoned folder beside it is still offerable" "$(eq "$(state_of "$CT/$U2")" offerable)"
judge claude-temp "$CT/$U4"
check "claude temp judge: a folder find could not wholly read is unmeasured" "$(has "$JUDGED" "unmeasured: part of it could not be read")"
chmod 700 "$CT/$U4/locked"

# ================================================================================================
# Worktrees: clean, pushed and merged only, by gh; a gh failure is unmeasured, never merged
# ================================================================================================
fresh
R="$H/Apps/repo"
mkdir -p "$R/.git/worktrees"
# What the git stub answers for each worktree is kept in $R/.fx/<name>, outside the worktree, because
# the stub reading it would otherwise move access times inside the folder the 30 day floor judges.
wt() { # <name> <status text> <branch> <head> <remote>
  local d="$R/.claude/worktrees/$1" x="$R/.fx/$1"
  mkdir -p "$d" "$x" "$R/.git/worktrees/$1"
  printf 'gitdir: %s\n' "$R/.git/worktrees/$1" > "$d/.git"
  printf '%s' "$2" > "$x/status"; printf '%s' "$3" > "$x/branch"; printf '%s' "$4" > "$x/head"; printf '%s' "$5" > "$x/remote"
  printf 'x\n' > "$d/README.md"; old "$d"
}
GH_URL=https://github.com/dan/repo.git
wt merged "" feat-a aaa1 "$GH_URL"
wt dirty " M src/a.ts" feat-b bbb1 "$GH_URL"
wt untracked "?? notes.txt" feat-c ccc1 "$GH_URL"
wt ahead "" feat-d ddd2 "$GH_URL"
wt open "" feat-e eee1 "$GH_URL"
wt detached "" "" fff1 "$GH_URL"
wt elsewhere "" feat-g ggg1 "https://gitlab.com/dan/repo.git"
wt ghfail "" feat-h hhh1 "$GH_URL"
wt insession "" feat-i iii1 "$GH_URL"
printf 'KEY=1\n' > "$R/.claude/worktrees/merged/.env"; old "$R/.claude/worktrees"
# The submodule shape of a .git file is not a worktree.
mkdir -p "$H/Apps/sub"; printf 'gitdir: ../.git/modules/sub\n' > "$H/Apps/sub/.git"
mkdir -p "$H/.claude/sessions"
printf '{"pid":1,"sessionId":"s1","cwd":"%s/src"}\n' "$R/.claude/worktrees/insession" > "$H/.claude/sessions/1.json"
dc_stub git 'd=""; if [ "$1" = -C ]; then d="$2"; shift 2; fi
x="${d%/.claude/worktrees/*}/.fx/${d##*/}"
case "$1 $2" in
  "--no-optional-locks status") cat "$x/status" ;;
  "status --porcelain") echo "git stub: a status without --no-optional-locks can rewrite the index" >&2; exit 1 ;;
  "symbolic-ref --short") b="$(cat "$x/branch")"; [ -n "$b" ] && echo "$b" || exit 1 ;;
  "rev-parse HEAD") cat "$x/head" ;;
  "remote get-url") cat "$x/remote" ;;
  *) echo "git stub: $*" >&2; exit 1 ;;
esac'
dc_stub gh 'for a in "$@"; do case "$a" in feat-a) echo "41 aaa1" ;; feat-d) echo "42 ddd1" ;; feat-e) : ;; feat-h) echo "gh: could not resolve host" >&2; exit 1 ;; feat-i) echo "43 iii1" ;; esac; done; exit 0'
run_scan --only worktrees
W="$R/.claude/worktrees"
# A plain git status refreshes the index file it reads, a write the scan must not make (#3216; the
# PR's evidence measured it on git 2.51): every status runs with optional locks off.
check "worktrees: git status runs with optional locks off, so it never rewrites the index" "$(has "$(dc_calls git)" "--no-optional-locks status --porcelain")"
check "worktrees: and no git status runs without that" "$(eq "$(dc_calls git | grep -c ' status ')" "$(dc_calls git | grep -cF -- ' --no-optional-locks status ')")"
check "worktrees: clean, merged by gh at exactly its HEAD, is offerable" "$(eq "$(state_of "$W/merged")" offerable)"
check "worktrees: through git worktree remove" "$(eq "$(method_of "$W/merged")" worktree)"
check "worktrees: a worktree holding a .env is flagged as holding credentials" "$(has "$(flags_of "$W/merged")" credential)"
check "worktrees: modified files make it not offerable" "$(has "$(state_of "$W/dirty")" "not offerable: it has uncommitted or untracked files")"
check "worktrees: untracked files make it not offerable" "$(has "$(state_of "$W/untracked")" "not offerable: it has uncommitted or untracked files")"
check "worktrees: commits its merged pull request does not have make it not offerable" "$(has "$(state_of "$W/ahead")" "not offerable: it has commits its merged pull request #42 does not")"
check "worktrees: no merged pull request makes it not offerable" "$(has "$(state_of "$W/open")" "not offerable: no merged pull request")"
check "worktrees: a detached HEAD is not offerable" "$(has "$(state_of "$W/detached")" "not offerable: it is on no branch")"
check "worktrees: a repository not on GitHub is not offerable" "$(has "$(state_of "$W/elsewhere")" "not offerable: ")"
check "worktrees: a gh failure is unmeasured, never merged" "$(has "$(state_of "$W/ghfail")" "unmeasured: gh could not say")"
check "worktrees: a session working inside it makes it not offerable" "$(has "$(state_of "$W/insession")" "not offerable: a session is working in it")"
check "worktrees: a submodule's .git file is not taken for a worktree" "$(eq "$(item_of "$H/Apps/sub")" "")"
judge worktrees "$W/merged"
check "worktrees judge: the merged one is offerable" "$(eq "$JUDGED" offerable)"
floor_checks worktrees "$W/merged" "$W/merged/README.md" folder
# git reads a worktree's .git file and its .gitignore files on every status, so their access times
# are the scan's own and never count as the worktree being opened; changing them still counts.
printf 'node_modules\n' > "$W/merged/.gitignore"; old "$W/merged"
touch -a -t "$RECENT" "$W/merged/.git" "$W/merged/.gitignore"
judge worktrees "$W/merged"
check "worktrees floor: git's own reads of .git and .gitignore are not counted as opened" "$(eq "$JUDGED" offerable)"
touch -m -t "$RECENT" "$W/merged/.gitignore"
judge worktrees "$W/merged"
check "worktrees floor: but a .gitignore changed 5 days ago counts as changed" "$(has "$JUDGED" "not offerable: changed within 30 days (.gitignore)")"
old "$W/merged"
printf ' M late.txt' > "$R/.fx/merged/status"
judge worktrees "$W/merged"
check "worktrees judge: once it has changes it is not" "$(has "$JUDGED" "not offerable: it has uncommitted or untracked files")"
# A folder whose own .git file iCloud keeps only in the cloud cannot be read without fetching it, so
# whether it is a worktree is not known: it is unmeasured and says why, never silently left out (L10,
# L11), and git is never run in it. The stand-in is DISK_CLEAN_DATALESS, as for build folders.
wt evicted "" feat-j jjj1 "$GH_URL"
printf '%s\n' "$W/evicted/.git" > "$DC_ROOT/dataless"
: > "$DC_CALLS"
dl_run_scan --only worktrees
check "worktrees: one whose .git file is kept only in iCloud is listed" "$(eq "$(field "$(item_of "$W/evicted")" 4)" "$W/evicted")"
check "worktrees: as unmeasured, saying its .git file is kept only in iCloud" "$(has "$(state_of "$W/evicted")" "unmeasured: its .git file is kept only in iCloud")"
check "worktrees: and git is never run in it" "$(hasnt "$(dc_calls git)" "$W/evicted")"
check "worktrees: the others are judged as before" "$(eq "$(state_of "$W/merged")" "not offerable: it has uncommitted or untracked files")"
JUDGED="$(dc_run env DISK_CLEAN_DATALESS="$DC_ROOT/dataless" DISK_CLEAN_CATEGORY=worktrees bash "$CATS/worktrees.sh" judge "$W/evicted" 2>&1)"
check "worktrees judge: one whose .git file is kept only in iCloud is unmeasured" "$(has "$JUDGED" "unmeasured: its .git file is kept only in iCloud")"

# ================================================================================================
# Transcripts: .jsonl over 90 days, and any hit says Claude Code's own cleanup stopped
# ================================================================================================
fresh
TP="$H/.claude/projects/-Users-x-proj"
U_OLD=0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d
U_NEW=1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d
mkdir -p "$TP"; printf '{}\n' > "$TP/$U_OLD.jsonl"; printf '{}\n' > "$TP/$U_NEW.jsonl"; old "$TP/$U_OLD.jsonl"
run_scan --only transcripts
check "transcripts: one over 90 days is offerable" "$(eq "$(state_of "$TP/$U_OLD.jsonl")" offerable)"
check "transcripts: moved to the Trash" "$(eq "$(method_of "$TP/$U_OLD.jsonl")" trash)"
check "transcripts: a recent one is not listed" "$(eq "$(item_of "$TP/$U_NEW.jsonl")" "")"
check "transcripts: a hit says Claude Code's 30 day cleanup appears to have stopped" "$(has "$(note_of transcripts)" "Claude Code's 30 day cleanup appears to have stopped")"
rm -f "$TP/$U_OLD.jsonl"
run_scan --only transcripts
check "transcripts: with none over 90 days there is no such note" "$(eq "$(note_of transcripts)" "")"

# Only Claude Code's own transcripts belong (#1851). On the work MacBook on 2026-10-28 every one of
# the 52 files this category offered was a plugin's vercel-plugin/skill-injections.jsonl, kept
# beside the transcripts, and the note blamed Claude Code's cleanup for them. A session transcript
# is <project>/<session id>.jsonl; a subagent's is agent-<id>.jsonl under <session id>/subagents/,
# which Claude Code's 30 day cleanup removes with its session. Anything else there is not offered.
fresh
mkdir -p "$TP/vercel-plugin" "$TP/$U_OLD/subagents/workflows/wf_1" "$TP/$U_OLD/tool-results"
printf '{}\n' > "$TP/vercel-plugin/skill-injections.jsonl"
printf '{}\n' > "$TP/notes.jsonl"
printf '{}\n' > "$TP/$U_OLD/subagents/agent-a1b2c3.jsonl"
printf '{}\n' > "$TP/$U_OLD/subagents/workflows/wf_1/agent-d4e5f6.jsonl"
printf '{}\n' > "$TP/$U_OLD/subagents/workflows/wf_1/journal.jsonl"
printf '{}\n' > "$TP/$U_OLD/tool-results/out.jsonl"
old "$TP"
run_scan --only transcripts
check "transcripts: a plugin's sidecar file is not listed" "$(eq "$(item_of "$TP/vercel-plugin/skill-injections.jsonl")" "")"
check "transcripts: a .jsonl not named for a session is not listed" "$(eq "$(item_of "$TP/notes.jsonl")" "")"
check "transcripts: a workflow journal is not listed" "$(eq "$(item_of "$TP/$U_OLD/subagents/workflows/wf_1/journal.jsonl")" "")"
check "transcripts: a .jsonl in a session's tool results is not listed" "$(eq "$(item_of "$TP/$U_OLD/tool-results/out.jsonl")" "")"
check "transcripts: an old subagent transcript is offerable" "$(eq "$(state_of "$TP/$U_OLD/subagents/agent-a1b2c3.jsonl")" offerable)"
check "transcripts: and so is one a workflow's agent wrote" "$(eq "$(state_of "$TP/$U_OLD/subagents/workflows/wf_1/agent-d4e5f6.jsonl")" offerable)"
check "transcripts: the note counts only the transcripts" "$(has "$(note_of transcripts)" ": 2 transcript(s) are older than")"
judge transcripts "$TP/vercel-plugin/skill-injections.jsonl"
check "transcripts judge: a plugin's sidecar file is not offerable" "$(eq "$JUDGED" "not offerable: it is not a Claude Code transcript")"
judge transcripts "$TP/$U_OLD/subagents/agent-a1b2c3.jsonl"
check "transcripts judge: an old subagent transcript is offerable" "$(eq "$JUDGED" offerable)"
T_A="$TP/$U_OLD/subagents/agent-a1b2c3.jsonl"
floor_checks transcripts "$T_A" "$T_A" own-age
touch -a -t "$RECENT" "$T_A"
run_scan --only transcripts
check "transcripts: the scan applies the floor too: one opened 5 days ago is not offered" "$(has "$(state_of "$T_A")" "not offerable: opened within 30 days (agent-a1b2c3.jsonl)")"
old "$T_A"
rm -f "$TP/$U_OLD/subagents/agent-a1b2c3.jsonl" "$TP/$U_OLD/subagents/workflows/wf_1/agent-d4e5f6.jsonl"
run_scan --only transcripts
check "transcripts: with only sidecar files old, nothing is listed and there is no note" "$(eq "$(items_in transcripts) $(note_of transcripts)" "0 ")"
# A folder it cannot read is unmeasured, never read as holding no old transcripts.
printf '{}\n' > "$TP/$U_OLD.jsonl"; old "$TP/$U_OLD.jsonl"
mkdir -p "$H/.claude/projects/-Users-x-locked"; chmod 000 "$H/.claude/projects/-Users-x-locked"
run_scan --only transcripts
check "transcripts: a projects folder it cannot read makes the category unmeasured" "$(has "$(status_of transcripts)" "unmeasured: part of ~/.claude/projects could not be read")"
check "transcripts: and the transcripts it could read are still listed" "$(eq "$(state_of "$TP/$U_OLD.jsonl")" offerable)"
chmod 700 "$H/.claude/projects/-Users-x-locked"
# A find that fails reading the transcript, as when it vanishes between the judge's check that it
# is there and the find, measured nothing, so it says so rather than "it changed within 90 days"
# (#1907, L11). The race cannot be timed, so a stand in find fails, once quietly and once saying why.
judge transcripts "$TP/$U_OLD.jsonl"
check "transcripts judge: an old transcript the core find reads is offerable (the control)" "$(eq "$JUDGED" offerable)"
dc_stub find 'exit 1'
judge transcripts "$TP/$U_OLD.jsonl"
check "transcripts judge: a find that fails saying nothing is unmeasured, naming its exit" \
  "$(eq "$JUDGED" "unmeasured: find exited 1 reading it, so whether it changed within 90 days is not known")"
dc_stub find "echo \"find: \$1: No such file or directory\" >&2; exit 1"
judge transcripts "$TP/$U_OLD.jsonl"
check "transcripts judge: and so is one that fails saying the file has gone" \
  "$(eq "$JUDGED" "unmeasured: find exited 1 reading it, so whether it changed within 90 days is not known")"
dc_stub find 'printf "%s\n" "$1"; exit 2'
judge transcripts "$TP/$U_OLD.jsonl"
check "transcripts judge: a find that printed the file and then failed is unmeasured too, never offerable" \
  "$(eq "$JUDGED" "unmeasured: find exited 2 reading it, so whether it changed within 90 days is not known")"
dc_unstub find
printf '{}\n' > "$TP/$U_NEW.jsonl"
judge transcripts "$TP/$U_NEW.jsonl"
check "transcripts judge: with the core find back, a recent transcript still changed within 90 days" \
  "$(eq "$JUDGED" "not offerable: it changed within 90 days")"

# ================================================================================================
# Runaway logs: *.log over 500 MB, emptied in place when a process holds it
# ================================================================================================
fresh
sparse "$H/Apps/svc/server.log" 600m; sparse "$H/.cache/tool/held.log" 600m; sparse "$H/Apps/svc/small.log" 100m
dc_stub lsof "for a in \"\$@\"; do case \"\$a\" in */held.log) printf 'p7\ncnode\n'; exit 0 ;; esac; done; exit 1"
# A log still being written is changed today, so under the 30 day floor (#2134) it is not offered.
run_scan --only runaway-logs
check "runaway logs: a big log written today is not offerable" "$(has "$(state_of "$H/Apps/svc/server.log")" "not offerable: changed within 30 days (server.log)")"
old "$H/Apps"; old "$H/.cache"
run_scan --only runaway-logs
check "runaway logs: a big log nothing holds is offerable, deleted" "$(eq "$(state_of "$H/Apps/svc/server.log") $(method_of "$H/Apps/svc/server.log")" "offerable delete")"
check "runaway logs: a big log in a dotfolder that a process holds is emptied in place" "$(eq "$(state_of "$H/.cache/tool/held.log") $(method_of "$H/.cache/tool/held.log")" "offerable truncate")"
check "runaway logs: a 100 MB log is not listed" "$(eq "$(item_of "$H/Apps/svc/small.log")" "")"
floor_checks runaway-logs "$H/Apps/svc/server.log" "$H/Apps/svc/server.log"
dc_stub lsof 'echo "lsof: permission denied" >&2; exit 1'
run_scan --only runaway-logs
check "runaway logs: when lsof cannot tell, it is unmeasured" "$(has "$(state_of "$H/Apps/svc/server.log")" "unmeasured: could not tell whether it is in use")"

# ================================================================================================
# Forgotten tools: the folder to command table, plus 180 days unused and no reference anywhere
# ================================================================================================
fresh
mkdir -p "$H/.gradle/caches" "$H/.m2/repository" "$H/.bun/bin" "$H/.deno/bin" "$H/Apps/javaapp" "$H/Apps/node20" \
  "$H/.nvm/versions/node/v18.0.0/bin" "$H/.nvm/versions/node/v20.1.0/bin" "$H/.nvm/versions/node/v22.1.0/bin" "$H/.nvm/alias" \
  "$H/.pyenv/versions/3.11.4/bin" "$H/.pyenv/versions/3.9.1/bin" "$H/.pyenv/versions/3.8.0/bin" "$H/Apps/py311" "$H/Apps/venvapp/.venv" \
  "$H/.mytool"
printf 'x\n' > "$H/.gradle/caches/a"; printf 'token=1\n' > "$H/.gradle/gradle.properties"
printf 'x\n' > "$H/.m2/repository/a"; printf '<project/>\n' > "$H/Apps/javaapp/pom.xml"
printf 'x\n' > "$H/.bun/bin/bun"; printf 'export PATH="$HOME/.bun/bin:$PATH"\n' > "$H/.zshrc"
printf 'x\n' > "$H/.deno/bin/deno"
for v in v18.0.0 v20.1.0 v22.1.0; do printf 'x\n' > "$H/.nvm/versions/node/$v/bin/node"; done
printf '20\n' > "$H/Apps/node20/.nvmrc"; printf 'v22.1.0\n' > "$H/.nvm/alias/default"
for v in 3.11.4 3.9.1 3.8.0; do printf 'x\n' > "$H/.pyenv/versions/$v/bin/python"; done
printf '3.11\n' > "$H/Apps/py311/.python-version"
printf 'home = %s/.pyenv/versions/3.9.1/bin\n' "$H" > "$H/Apps/venvapp/.venv/pyvenv.cfg"
printf 'x\n' > "$H/.mytool/a"
mkdir -p "$H/.android" "$H/.expo/codesigning/proj"
printf 'key\n' > "$H/.android/adbkey"; printf '{}\n' > "$H/.expo/codesigning/proj/development-code-signing-settings-2.json"
old "$H/.android"; old "$H/.expo"
old "$H/.gradle"; old "$H/.m2"; old "$H/.bun"; old "$H/.nvm"; old "$H/.pyenv"; old "$H/.deno"; old "$H/.mytool"
printf 'recent\n' > "$H/.deno/bin/deno"
run_scan --only forgotten-tools
check "forgotten tools: a table folder unused for 180 days that nothing mentions is offerable" "$(eq "$(state_of "$H/.gradle")" offerable)"
check "forgotten tools: moved to the Trash" "$(eq "$(method_of "$H/.gradle")" trash)"
check "forgotten tools: holding gradle.properties flags it as holding credentials" "$(has "$(flags_of "$H/.gradle")" credential)"
check "forgotten tools: an ADB private key (adbkey, as the personal MacBook's ~/.android held on 2026-10-27) flags it" "$(has "$(flags_of "$H/.android")" credential)"
check "forgotten tools: an Expo code signing file flags it" "$(has "$(flags_of "$H/.expo")" credential)"
check "forgotten tools: a project's marker file keeps it (pom.xml for .m2)" "$(has "$(state_of "$H/.m2")" "not offerable: ")"
check "forgotten tools: naming the marker" "$(has "$(state_of "$H/.m2")" "pom.xml")"
check "forgotten tools: a shell config mentioning it keeps it" "$(has "$(state_of "$H/.bun")" "not offerable: ")"
check "forgotten tools: naming the file" "$(has "$(state_of "$H/.bun")" ".zshrc")"
check "forgotten tools: anything changed within 180 days keeps it" "$(has "$(state_of "$H/.deno")" "not offerable: something in it changed within 180 days")"
check "forgotten tools: a folder not in the table is never listed, however stale" "$(eq "$(item_of "$H/.mytool")" "")"
check "forgotten tools: a node version no project or default names is offerable" "$(eq "$(state_of "$H/.nvm/versions/node/v18.0.0")" offerable)"
check "forgotten tools: a node version a project's .nvmrc names is kept" "$(has "$(state_of "$H/.nvm/versions/node/v20.1.0")" "not offerable: ")"
check "forgotten tools: the nvm default is kept" "$(has "$(state_of "$H/.nvm/versions/node/v22.1.0")" "not offerable: ")"
check "forgotten tools: .nvm itself is never listed" "$(eq "$(item_of "$H/.nvm")" "")"
check "forgotten tools: .pyenv as a whole is kept when a .python-version exists" "$(has "$(state_of "$H/.pyenv")" "not offerable: ")"
check "forgotten tools: a python version a .python-version names is kept" "$(has "$(state_of "$H/.pyenv/versions/3.11.4")" "not offerable: ")"
check "forgotten tools: a python version a venv's pyvenv.cfg points into is kept" "$(has "$(state_of "$H/.pyenv/versions/3.9.1")" "not offerable: ")"
check "forgotten tools: a python version nothing depends on is offerable" "$(eq "$(state_of "$H/.pyenv/versions/3.8.0")" offerable)"
judge forgotten-tools "$H/.gradle"
check "forgotten tools judge: the stale folder is offerable" "$(eq "$JUDGED" offerable)"
floor_checks forgotten-tools "$H/.gradle" "$H/.gradle/caches/a" folder own-age
# Running a tool moves its executable's access time on every run (measured for #2134), so a node
# or python version run last week is not forgotten, however long ago it was installed.
floor_checks forgotten-tools "$H/.nvm/versions/node/v18.0.0" "$H/.nvm/versions/node/v18.0.0/bin/node" own-age
floor_checks forgotten-tools "$H/.pyenv/versions/3.8.0" "$H/.pyenv/versions/3.8.0/bin/python" own-age
judge forgotten-tools "$H/.mytool"
check "forgotten tools judge: a folder not in the table is not offerable" "$(has "$JUDGED" "not offerable: ")"
chmod 000 "$H/Apps/node20/.nvmrc"
run_scan --only forgotten-tools
check "forgotten tools: an unreadable .nvmrc makes every node version unmeasured" "$(has "$(state_of "$H/.nvm/versions/node/v18.0.0")" "unmeasured: ")"
chmod 644 "$H/Apps/node20/.nvmrc"
mkdir -p "$H/Apps/locked/inner"; chmod 000 "$H/Apps/locked"
run_scan --only forgotten-tools
check "forgotten tools: a walk that could not read every folder makes nothing tickable" "$(has "$(state_of "$H/.gradle")" "unmeasured: ")"
chmod 700 "$H/Apps/locked"

# ================================================================================================
# Large personal files: only in Downloads, Desktop, Documents and Movies; iCloud flagged
# ================================================================================================
fresh
sparse "$H/Downloads/disk.iso" 600m; sparse "$H/Documents/talk.mov" 600m; sparse "$H/Pictures/raw.dng" 600m
sparse "$H/Downloads/small.zip" 10m; sparse "$H/Downloads/huge.log" 600m
mkdir -p "$H/Library/Mobile Documents/com~apple~CloudDocs/Documents"
old "$H"
run_scan --only large-files
check "large files: a big file in Downloads is offerable" "$(eq "$(state_of "$H/Downloads/disk.iso")" offerable)"
check "large files: moved to the Trash" "$(eq "$(method_of "$H/Downloads/disk.iso")" trash)"
check "large files: one in an iCloud synced Documents is flagged" "$(has "$(flags_of "$H/Documents/talk.mov")" icloud)"
check "large files: one in Downloads is not flagged iCloud" "$(hasnt "$(flags_of "$H/Downloads/disk.iso")" icloud)"
check "large files: one in Pictures is not looked for" "$(eq "$(item_of "$H/Pictures/raw.dng")" "")"
check "large files: a small file is not listed" "$(eq "$(item_of "$H/Downloads/small.zip")" "")"
check "large files: a big .log is a runaway log, not a personal file" "$(eq "$(item_of "$H/Downloads/huge.log")" "")"
judge large-files "$H/Downloads/disk.iso"
check "large files judge: it is offerable" "$(eq "$JUDGED" offerable)"
floor_checks large-files "$H/Downloads/disk.iso" "$H/Downloads/disk.iso"
judge large-files "$H/Pictures/raw.dng"
check "large files judge: outside the four folders it is not" "$(has "$JUDGED" "not offerable: ")"

# ================================================================================================
# Swift .build beside a Package.swift, and a build folder inside a home dotfolder only when that
# folder is a git worktree (a .git file), never a tool's own copy such as npx's (#3235)
# ================================================================================================
fresh
mkdir -p "$H/Apps/pkg/.build/debug" "$H/Apps/pkg/Sources" "$H/Apps/nopkg/.build/x" "$H/.verify-wt/node_modules/x" "$H/.verify-wt/src" \
  "$H/.npm/_npx/abc/node_modules/y" "$H/.oh-my-thing/node_modules/z"
printf '// swift-tools-version:5.9\n' > "$H/Apps/pkg/Package.swift"; printf 'o\n' > "$H/Apps/pkg/.build/debug/o"
printf 'o\n' > "$H/Apps/nopkg/.build/x/o"
printf '{}\n' > "$H/.verify-wt/package.json"; printf 'gitdir: /x/.git/worktrees/v\n' > "$H/.verify-wt/.git"
printf '{}\n' > "$H/.npm/_npx/abc/package.json"
mkdir -p "$H/.oh-my-thing/.git"; printf '{}\n' > "$H/.oh-my-thing/package.json"
old "$H/Apps"; old "$H/.verify-wt"; old "$H/.npm"; old "$H/.oh-my-thing"
run_scan --only build-folders
check "swift build: .build beside a Package.swift, in a project untouched 30 days, is offerable" "$(eq "$(state_of "$H/Apps/pkg/.build")" offerable)"
check "swift build: by deleting it, since swift build makes it again" "$(eq "$(method_of "$H/Apps/pkg/.build")" delete)"
check "swift build: a .build with no Package.swift beside it is not listed" "$(eq "$(item_of "$H/Apps/nopkg/.build")" "")"
check "dotfolder worktree: node_modules in a home dotfolder that is a git worktree is offerable" "$(eq "$(state_of "$H/.verify-wt/node_modules")" offerable)"
check "dotfolder worktree: npx's own copy in ~/.npm is still not listed" "$(eq "$(item_of "$H/.npm/_npx/abc/node_modules")" "")"
check "dotfolder worktree: a dotfolder holding a whole repository (a .git folder) is not listed" "$(eq "$(item_of "$H/.oh-my-thing/node_modules")" "")"
judge build-folders "$H/Apps/nopkg/.build"
check "swift build judge: a .build with no Package.swift is not offerable" "$(has "$JUDGED" "not offerable: no Package.swift beside it")"
judge build-folders "$H/Apps/pkg/.build"
check "swift build judge: one beside a Package.swift is offerable" "$(eq "$JUDGED" offerable)"
floor_checks build-folders "$H/Apps/pkg/.build" "$H/Apps/pkg/.build/debug/o" folder
printf 'edited\n' > "$H/Apps/pkg/Sources/main.swift"
judge build-folders "$H/Apps/pkg/.build"
check "swift build judge: a project whose own Swift files changed keeps its .build" "$(has "$JUDGED" "not offerable: the project's own files changed within 30 days")"
judge build-folders "$H/.npm/_npx/abc/node_modules"
check "dotfolder worktree judge: npx's copy is not offerable" "$(has "$JUDGED" "not offerable: it is inside a home dotfolder")"
judge build-folders "$H/.verify-wt/node_modules"
check "dotfolder worktree judge: a worktree's node_modules is offerable" "$(eq "$JUDGED" offerable)"
rm -f "$H/.verify-wt/.git"; mkdir -p "$H/.verify-wt/.git"; old "$H/.verify-wt"
judge build-folders "$H/.verify-wt/node_modules"
check "dotfolder worktree judge: once its .git is a folder, not a worktree's file, it is not offerable" "$(has "$JUDGED" "not offerable: it is inside a home dotfolder")"

# ================================================================================================
# Tool output beside transcripts: a session's tool-results folder, offered only once that session's
# own transcript is gone and no live session owns it; subagent records and memory never listed
# ================================================================================================
fresh
PJ="$H/.claude/projects/-Users-x-Apps-proj"
U5=55555555-5555-4555-8555-555555555555; U6=66666666-6666-4666-8666-666666666666
U7=77777777-7777-4777-8777-777777777777; U8=88888888-8888-4888-8888-888888888888; U9=99999999-9999-4999-8999-999999999999
mkdir -p "$PJ/$U5/tool-results" "$PJ/$U6/tool-results" "$PJ/$U7/tool-results" "$PJ/$U8/subagents" "$PJ/memory" "$PJ/$U9" "$H/.claude/sessions"
printf 't\n' > "$PJ/$U5.jsonl"; printf 'r\n' > "$PJ/$U5/tool-results/a.txt"
printf 'r\n' > "$PJ/$U6/tool-results/b.txt"; printf 'r\n' > "$PJ/$U7/tool-results/c.txt"
printf '{}\n' > "$PJ/$U8/subagents/agent-a1.meta.json"; printf 'm\n' > "$PJ/memory/MEMORY.md"
old "$H/.claude/projects"
printf '{"pid":1,"sessionId":"%s","cwd":"/x"}\n' "$U7" > "$H/.claude/sessions/1.json"
run_scan --only transcript-extras
check "beside transcripts: the scan exits 0" "$(eq "$RC" 0)"
check "beside transcripts: tool output whose session transcript is still there is not offerable" "$(has "$(state_of "$PJ/$U5/tool-results")" "not offerable: its session's transcript is still there")"
check "beside transcripts: tool output whose transcript is gone, untouched 30 days, is offerable" "$(eq "$(state_of "$PJ/$U6/tool-results")" offerable)"
check "beside transcripts: by moving it to the Trash" "$(eq "$(method_of "$PJ/$U6/tool-results")" trash)"
check "beside transcripts: a live session's tool output is not offerable, though its transcript is gone" "$(has "$(state_of "$PJ/$U7/tool-results")" "not offerable: a live session")"
check "beside transcripts: subagent records are not listed" "$(eq "$(item_of "$PJ/$U8/subagents")$(item_of "$PJ/$U8/subagents/agent-a1.meta.json")" "")"
check "beside transcripts: memory is not listed" "$(eq "$(item_of "$PJ/memory")$(item_of "$PJ/memory/MEMORY.md")" "")"
check "beside transcripts: the note says memory and subagent records are left out" "$(has "$(note_of transcript-extras)" "memory")"
judge transcript-extras "$PJ/$U6/tool-results"
check "beside transcripts judge: orphaned tool output is offerable" "$(eq "$JUDGED" offerable)"
floor_checks transcript-extras "$PJ/$U6/tool-results" "$PJ/$U6/tool-results/b.txt" folder
judge transcript-extras "$PJ/memory"
check "beside transcripts judge: memory is not offerable" "$(has "$JUDGED" "not offerable: it is not a session's tool output")"
judge transcript-extras "$PJ/$U6/tool-results/b.txt"
check "beside transcripts judge: one file inside is not offerable" "$(has "$JUDGED" "not offerable: it is not a session's tool output")"
judge transcript-extras "$H/Downloads/$U6/tool-results"
check "beside transcripts judge: a folder outside ~/.claude/projects is not offerable" "$(has "$JUDGED" "not offerable: it is not a session's tool output")"
ln -s "$PJ/$U6/tool-results" "$PJ/$U9/tool-results"
judge transcript-extras "$PJ/$U9/tool-results"
check "beside transcripts judge: a link is not offerable" "$(has "$JUDGED" "not offerable: ")"
printf 't\n' > "$PJ/$U6.jsonl"
judge transcript-extras "$PJ/$U6/tool-results"
check "beside transcripts judge: a transcript that is back since the scan makes it not offerable" "$(has "$JUDGED" "not offerable: its session's transcript is still there")"
rm -f "$PJ/$U6.jsonl"
chmod 000 "$H/.claude/sessions/1.json"
judge transcript-extras "$PJ/$U6/tool-results"
check "beside transcripts judge: an unreadable session map makes it unmeasured" "$(has "$JUDGED" "unmeasured: the session map")"
chmod 600 "$H/.claude/sessions/1.json"
# An empty session map while Claude Code runs means the map is wrong, not that every session ended,
# as claude-temp.sh judges it: otherwise a live session's orphaned tool output would read as abandoned.
rm -f "$H/.claude/sessions/1.json"
dc_stub ps 'echo "/usr/bin/login"; echo "/usr/local/bin/claude"'
run_scan --only transcript-extras
check "beside transcripts: an empty session map while Claude Code runs makes the kind unmeasured" "$(has "$(status_of transcript-extras)" "unmeasured: the session map")"
check "beside transcripts: and offers nothing" "$(hasnt "$(state_of "$PJ/$U6/tool-results")" offerable)"
judge transcript-extras "$PJ/$U6/tool-results"
check "beside transcripts judge: an empty session map while Claude Code runs makes it unmeasured" "$(has "$JUDGED" "unmeasured: the session map")"
dc_stub ps 'echo "/usr/bin/login"'

# ================================================================================================
# Old Claude Code versions: never the one the claude command starts, never one a process runs
# ================================================================================================
fresh
CV="$H/.local/share/claude/versions"
mkdir -p "$CV" "$H/.local/bin"
printf 'b\n' > "$CV/2.1.1"; printf 'b\n' > "$CV/2.1.2"; printf 'b\n' > "$CV/2.1.3"; printf 'b\n' > "$CV/2.1.4"
ln -s "$CV/2.1.4" "$H/.local/bin/claude"; ln -s "$CV/2.1.1" "$CV/a-link"
old "$CV"
dc_stub lsof "printf 'p10\nc2.1.2\nf3\nn%s\n' $(printf %q "$CV/2.1.2")"
run_scan --only claude-versions
check "claude versions: the one the claude command starts is not offerable" "$(has "$(state_of "$CV/2.1.4")" "not offerable: it is the version the claude command starts")"
check "claude versions: one a running process holds is not offerable" "$(has "$(state_of "$CV/2.1.2")" "not offerable: in use by 2.1.2")"
check "claude versions: an older one nothing runs, unused 30 days, is offerable" "$(eq "$(state_of "$CV/2.1.1")" offerable)"
check "claude versions: by deleting it, since the installer fetches any version again" "$(eq "$(method_of "$CV/2.1.1")" delete)"
check "claude versions: a link among them is not listed" "$(eq "$(item_of "$CV/a-link")" "")"
judge claude-versions "$CV/2.1.3"
check "claude versions judge: an older one is offerable" "$(eq "$JUDGED" offerable)"
floor_checks claude-versions "$CV/2.1.3" "$CV/2.1.3"
judge claude-versions "$CV/a-link"
check "claude versions judge: a link is not offerable" "$(has "$JUDGED" "not offerable: ")"
judge claude-versions "$H/.local/share/claude/other"
check "claude versions judge: anything outside the versions folder is not offerable" "$(has "$JUDGED" "not offerable: it is not a Claude Code version")"
judge claude-versions "$CV/2.1.4"
check "claude versions judge: the current one is not offerable" "$(has "$JUDGED" "not offerable: it is the version the claude command starts")"
dc_stub lsof 'echo "lsof: WARNING: can not stat() fuse file system" >&2; exit 1'
judge claude-versions "$CV/2.1.3"
check "claude versions judge: lsof saying anything on stderr makes it unmeasured" "$(has "$JUDGED" "unmeasured: could not tell whether it is running")"
dc_stub lsof 'exit 1'
rm -f "$H/.local/bin/claude"
run_scan --only claude-versions
check "claude versions: with no claude command to read, which one is current is unknown, so unmeasured" "$(has "$(state_of "$CV/2.1.3")" "unmeasured: ")"

# ================================================================================================
# The GitHub command line's cache: entries in ~/.cache/gh, which gh fetches again
# ================================================================================================
fresh
G="$H/.cache/gh"
mkdir -p "$G/22" "$G/56"
printf 'z\n' > "$G/run-log-1-2.zip"; printf 'z\n' > "$G/run-log-3-4.zip"; printf 'h\n' > "$G/22/abc"; printf 'h\n' > "$G/56/def"
old "$G"; touch -m -t "$RECENT" "$G/run-log-3-4.zip"; ln -s "$G/56" "$G/a-link"
dc_stub lsof "printf 'p10\ncgh\nf3\nn%s\n' $(printf %q "$G/22/abc")"
run_scan --only gh-cache
check "gh cache: a run log untouched 30 days is offerable" "$(eq "$(state_of "$G/run-log-1-2.zip")" offerable)"
check "gh cache: by deleting it" "$(eq "$(method_of "$G/run-log-1-2.zip")" delete)"
check "gh cache: one changed 5 days ago is not offerable" "$(has "$(state_of "$G/run-log-3-4.zip")" "not offerable: changed within 30 days")"
check "gh cache: an entry gh holds open is not offerable" "$(has "$(state_of "$G/22")" "not offerable: in use by gh")"
check "gh cache: an idle cache folder is offerable" "$(eq "$(state_of "$G/56")" offerable)"
check "gh cache: a link is not listed" "$(eq "$(item_of "$G/a-link")" "")"
judge gh-cache "$G/56"
check "gh cache judge: an idle entry is offerable" "$(eq "$JUDGED" offerable)"
floor_checks gh-cache "$G/56" "$G/56/def" folder
judge gh-cache "$G"
check "gh cache judge: the cache folder itself is not offerable" "$(has "$JUDGED" "not offerable: it is not an entry directly inside ~/.cache/gh")"
judge gh-cache "$H/.cache/other"
check "gh cache judge: another tool's cache is not offerable" "$(has "$JUDGED" "not offerable: it is not an entry directly inside ~/.cache/gh")"
judge gh-cache "$G/a-link"
check "gh cache judge: a link is not offerable" "$(has "$JUDGED" "not offerable: ")"
dc_stub lsof 'echo "lsof: WARNING: can not stat() fuse file system" >&2; exit 1'
judge gh-cache "$G/56"
check "gh cache judge: lsof saying anything on stderr makes in use unknown" "$(has "$JUDGED" "unmeasured: could not tell whether it is in use")"

# ================================================================================================
# Claude Code's own records: measured and shown, never offered (state, file history, the finding
# spool and its backups, and the folders this config's hooks keep in the home folder)
# ================================================================================================
fresh
mkdir -p "$H/.claude/state/session-notes/p/s" "$H/.claude/state/ai-review" "$H/.claude/file-history/$U5" "$H/.claude-issue-spool" \
  "$H/.claude-issue-spool.backup-20260829-161937" "$H/.claude-payload-write-gate" "$H/.claude-area-check/rotated" "$H/.claude-quiz-verdicts" \
  "$H/.claude-allow-rule-backups" "$H/.claude-handback-check" "$H/.claude-engine-checks"
printf 'n\n' > "$H/.claude/state/session-notes/p/s/handoff.md"; printf 'a\n' > "$H/.claude/state/ai-review/x"
printf 'v\n' > "$H/.claude/file-history/$U5/abc@v1"; printf '{}\n' > "$H/.claude-issue-spool/aaa.jsonl"
printf '{}\n' > "$H/.claude-issue-spool.backup-20260829-161937/aaa.jsonl"; printf 'x\n' > "$H/.claude-payload-write-gate/toolu_1.list"
old "$H"
dc_stub du 'for a in "$@"; do case "$a" in -*) ;; */session-notes) printf "500\t%s\n" "$a" ;; *) printf "12\t%s\n" "$a" ;; esac; done'
run_scan --only claude-records
check "claude records: the scan exits 0" "$(eq "$RC" 0)"
check "claude records: session notes are shown" "$(has "$(state_of "$H/.claude/state/session-notes")" "not offerable: ")"
check "claude records: the rest of state is not listed row by row, all with one reason" "$(eq "$(item_of "$H/.claude/state/ai-review")" "")"
check "claude records: the note gives the rest of state's count and size instead" "$(has "$(note_of claude-records)" "other entries in ~/.claude/state")"
check "claude records: rows come largest first, so the biggest record leads the kind" \
  "$(eq "$(dcr_review_items "$REC" | awk -F "$S" '$2 == "claude-records" && !f { print $4; f = 1 }')" "$H/.claude/state/session-notes")"
check "claude records: file history is shown, as /rewind's copies" "$(has "$(state_of "$H/.claude/file-history")" "/rewind")"
check "claude records: the finding spool is never offered" "$(has "$(state_of "$H/.claude-issue-spool")" "not offerable: findings not yet reviewed")"
check "claude records: a spool backup is never offered" "$(has "$(state_of "$H/.claude-issue-spool.backup-20260829-161937")" "not offerable: ")"
check "claude records: the payload write gate's notes are shown" "$(has "$(state_of "$H/.claude-payload-write-gate")" "not offerable: ")"
for d in .claude-area-check .claude-quiz-verdicts .claude-allow-rule-backups .claude-handback-check .claude-engine-checks; do
  check "claude records: ~/$d is shown" "$(has "$(state_of "$H/$d")" "not offerable: ")"
done
check "claude records: nothing in the kind is offerable" "$(eq "$(dcr_review_items "$REC" | awk -F "$S" '$2 == "claude-records" && $5 == "offerable"' | wc -l | tr -d ' ')" 0)"
check "claude records: each is sized" "$(eq "$(field "$(item_of "$H/.claude-issue-spool")" 8)" measured)"
judge claude-records "$H/.claude-issue-spool"
check "claude records judge: the spool is not offerable" "$(has "$JUDGED" "not offerable: ")"
judge claude-records "$H/.claude/state/session-notes"
check "claude records judge: session notes are not offerable" "$(has "$JUDGED" "not offerable: ")"
judge claude-records "$H/Downloads"
check "claude records judge: a folder it does not list is not offerable" "$(has "$JUDGED" "not offerable: it is not one of the records this kind shows")"

# ================================================================================================
# npm and pnpm caches: measured and shown, never offered (only partly Claude's; Dan's call, #3235)
# ================================================================================================
fresh
mkdir -p "$H/.npm/_cacache/content-v2" "$H/.npm/_npx/abc123/node_modules" "$H/.npm/_logs" "$H/Library/pnpm/store/v11/files"
printf 'c\n' > "$H/.npm/_cacache/content-v2/x"; printf 'p\n' > "$H/.npm/_npx/abc123/package.json"; printf 's\n' > "$H/Library/pnpm/store/v11/files/y"
old "$H"
dc_stub du 'for a in "$@"; do case "$a" in -*) ;; */v11) printf "500\t%s\n" "$a" ;; *) printf "12\t%s\n" "$a" ;; esac; done'
run_scan --only package-caches
check "package caches: rows come largest first" "$(eq "$(dcr_review_items "$REC" | awk -F "$S" '$2 == "package-caches" && !f { print $4; f = 1 }')" "$H/Library/pnpm/store/v11")"
check "package caches: npm's download cache is shown, not offered" "$(has "$(state_of "$H/.npm/_cacache")" "not offerable: ")"
check "package caches: each npx copy is shown, not offered" "$(has "$(state_of "$H/.npm/_npx/abc123")" "not offerable: ")"
check "package caches: npm's logs are shown, not offered" "$(has "$(state_of "$H/.npm/_logs")" "not offerable: ")"
check "package caches: the pnpm store is shown, not offered" "$(has "$(state_of "$H/Library/pnpm/store/v11")" "not offerable: ")"
check "package caches: the note says once what an npx copy is, rather than on every row" "$(has "$(note_of package-caches)" "Each npx copy is one package npx has run")"
check "package caches: nothing in the kind is offerable" "$(eq "$(dcr_review_items "$REC" | awk -F "$S" '$2 == "package-caches" && $5 == "offerable"' | wc -l | tr -d ' ')" 0)"
judge package-caches "$H/.npm/_npx/abc123"
check "package caches judge: an npx copy is not offerable" "$(has "$JUDGED" "not offerable: ")"
judge package-caches "$H/.npm"
check "package caches judge: ~/.npm itself is not offerable" "$(has "$JUDGED" "not offerable: ")"

# ================================================================================================
# Claude named items in the user temp folder: counted and sized in the kind's note, never listed
# ================================================================================================
fresh
uid="$(id -u)"
mkdir -p "$DC_TMPDIR/claude-sync-suite-work.isolated.AbC123/x" "$DC_TMPDIR/claude-$uid/proj" "$DC_TMPDIR/other-app"
printf 's\n' > "$DC_TMPDIR/claude-add-scope-0f6a3deac760.state"; printf 'l\n' > "$DC_TMPDIR/.claude-lessons-advisory.1"
printf 'o\n' > "$DC_TMPDIR/other-app/f"
run_scan --only claude-user-temp
check "user temp: the scan exits 0" "$(eq "$RC" 0)"
check "user temp: the note counts the three Claude named entries" "$(has "$(note_of claude-user-temp)" "3 entries")"
check "user temp: and lists none of them" "$(eq "$(items_in claude-user-temp)" 0)"
check "user temp: Claude Code's own temp folder is the claude temp kind's, so not counted" "$(hasnt "$(note_of claude-user-temp)" "4 entries")"
judge claude-user-temp "$DC_TMPDIR/claude-add-scope-0f6a3deac760.state"
check "user temp judge: an entry is not offerable" "$(has "$JUDGED" "not offerable: ")"

# ================================================================================================
# Every kind keeps the 30 day floor (#2134), enumerated from the folder, so a kind added later
# without it fails here (L613). The Trash is exempt by Dan's decision; Docker's floor reads
# Docker's own times, since its targets are not files.
# ================================================================================================
# A kind that shows space and offers none (#3235) says so on a line of its own, "# offers: nothing";
# such a module must then never set offerable at all, so the marker cannot hide a kind that does.
for m in "$CATS"/*.sh; do
  case "${m##*/}" in trash.sh|docker.sh) continue ;; esac
  if grep -qx '# offers: nothing' "$m"; then
    check "floor: ${m##*/} says it offers nothing, and sets offerable nowhere" "$(grep -n 'V=offerable\|V="offerable"\|echo offerable' "$m" | awk 'NR == 1 { print "it does: " $0; f = 1 } END { if (!f) print "ok" }')"
  else
    check "floor: ${m##*/} applies dcs_floor" "$(grep -q 'dcs_floor "' "$m" && echo ok || echo "no dcs_floor call in $m")"
  fi
done
for c in transcript-extras claude-records claude-versions claude-user-temp gh-cache package-caches; do
  check "titles: $c has a title in words, so the page never shows its code name" "$(t="$(dcr_title "$c")"; [ -n "$t" ] && [ "$t" != "$c" ] && echo ok || echo "titled '$t'")"
done
check "floor: the folder holds the kinds this suite expects (a control on the loop)" "$(eq "$(ls "$CATS"/*.sh | wc -l | tr -d ' ')" 19)"
check "floor: exactly the three kinds that only show space say they offer nothing (a control on the marker)" \
  "$(eq "$(grep -lx '# offers: nothing' "$CATS"/*.sh | sed 's|.*/||' | tr '\n' ' ')" "claude-records.sh claude-user-temp.sh package-caches.sh ")"

finish
