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
mkdir -p "$DD/App-orphan" "$DD/App-live" "$DD/App-busy" "$DD/ModuleCache.noindex" "$DD/App-noplist"
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
# A file inside node_modules itself is new, which must not count as the project being used.
printf 'new\n' > "$P/stale/node_modules/x/fresh.js"
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
printf 'today\n' > "$P/stale/src/b.ts"
judge build-folders "$P/stale/node_modules"
check "build folders judge: once the project is edited again it is not" "$(has "$JUDGED" "not offerable: the project's own files changed within 30 days")"

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
check "build folders: a folder holding a cloud only folder is still listed" "$(eq "$(state_of "$P/cloudy/node_modules")" offerable)"
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
  "container inspect") echo false ;;
  *) echo "docker stub: $*" >&2; exit 1 ;;
esac'
run_scan --only docker
check "docker: a dangling image is offerable" "$(eq "$(state_of "image sha256abc")" offerable)"
check "docker: through the docker method" "$(eq "$(method_of "image sha256abc")" docker)"
check "docker: with Docker's own figure" "$(eq "$(field "$(item_of "image sha256abc")" 8)" reported)"
check "docker: a stopped container is offerable" "$(eq "$(state_of "container c0ffee")" offerable)"
check "docker: the build cache is offerable" "$(eq "$(state_of "builder cache")" offerable)"
check "docker: a volume is listed and never offerable" "$(has "$(state_of "volume pgdata")" "not offerable: Docker volumes hold data")"
judge docker "volume pgdata"
check "docker judge: a volume is not offerable" "$(has "$JUDGED" "not offerable: ")"
judge docker "image sha256abc"
check "docker judge: a dangling image is offerable" "$(eq "$JUDGED" offerable)"

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
run_scan --only playwright
check "playwright: a revision a linked project needs is kept" "$(has "$(state_of "$PW/chromium-1243")" "not offerable: ")"
check "playwright: chromium-headless-shell's folder is matched by its underscored name" "$(has "$(state_of "$PW/chromium_headless_shell-1243")" "not offerable: ")"
check "playwright: a revision named only in a b/ entry's library (an override) is kept" "$(has "$(state_of "$PW/webkit-2359")" "not offerable: ")"
check "playwright: a revision nothing needs is offerable" "$(eq "$(state_of "$PW/chromium-1100")" offerable)"
check "playwright: another browser nothing needs is offerable" "$(eq "$(state_of "$PW/firefox-1500")" offerable)"
check "playwright: .links and b are never items" "$(eq "$(item_of "$PW/.links")$(item_of "$PW/b")" "")"
judge playwright "$PW/chromium-1100"
check "playwright judge: an unneeded revision is offerable" "$(eq "$JUDGED" offerable)"
judge playwright "$PW/ffmpeg-1011"
check "playwright judge: a needed one is not" "$(has "$JUDGED" "not offerable: ")"
rm -f "$LA/browsers.json"
run_scan --only playwright
check "playwright: a linked library whose browsers.json cannot be read makes the category unmeasured" "$(has "$(status_of playwright)" "unmeasured: ")"

# ================================================================================================
# Claude Code temp: <slug>/<uuid> folders no live session owns, untouched for a day (DCS_TEMP_MINUTES)
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
check "claude temp: a folder no session owns, untouched for 24 hours, is offerable" "$(eq "$(state_of "$CT/$U2")" offerable)"
check "claude temp: by deleting it" "$(eq "$(method_of "$CT/$U2")" delete)"
check "claude temp: a folder used within 24 hours is not offerable" "$(has "$(state_of "$CT/$U3")" "not offerable: used within the last 24 hours")"
check "claude temp: a folder that is not a session id is not listed" "$(eq "$(item_of "$CT/not-a-uuid")" "")"
check "claude temp: the slug folder itself is not listed" "$(eq "$(item_of "$CT")" "")"
judge claude-temp "$CT/$U1"
check "claude temp judge: a live session's folder is not offerable" "$(has "$JUDGED" "not offerable: a live session")"
judge claude-temp "$CT/$U2"
check "claude temp judge: an abandoned one is offerable" "$(eq "$JUDGED" offerable)"
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
wt() { # <name> <status text> <branch> <head> <remote>
  local d="$R/.claude/worktrees/$1"
  mkdir -p "$d" "$R/.git/worktrees/$1"
  printf 'gitdir: %s\n' "$R/.git/worktrees/$1" > "$d/.git"
  printf '%s' "$2" > "$d/.fx-status"; printf '%s' "$3" > "$d/.fx-branch"; printf '%s' "$4" > "$d/.fx-head"; printf '%s' "$5" > "$d/.fx-remote"
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
printf 'KEY=1\n' > "$R/.claude/worktrees/merged/.env"
# The submodule shape of a .git file is not a worktree.
mkdir -p "$H/Apps/sub"; printf 'gitdir: ../.git/modules/sub\n' > "$H/Apps/sub/.git"
mkdir -p "$H/.claude/sessions"
printf '{"pid":1,"sessionId":"s1","cwd":"%s/src"}\n' "$R/.claude/worktrees/insession" > "$H/.claude/sessions/1.json"
dc_stub git 'd=""; if [ "$1" = -C ]; then d="$2"; shift 2; fi
case "$1 $2" in
  "status --porcelain") cat "$d/.fx-status" ;;
  "symbolic-ref --short") b="$(cat "$d/.fx-branch")"; [ -n "$b" ] && echo "$b" || exit 1 ;;
  "rev-parse HEAD") cat "$d/.fx-head" ;;
  "remote get-url") cat "$d/.fx-remote" ;;
  *) echo "git stub: $*" >&2; exit 1 ;;
esac'
dc_stub gh 'for a in "$@"; do case "$a" in feat-a) echo "41 aaa1" ;; feat-d) echo "42 ddd1" ;; feat-e) : ;; feat-h) echo "gh: could not resolve host" >&2; exit 1 ;; feat-i) echo "43 iii1" ;; esac; done; exit 0'
run_scan --only worktrees
W="$R/.claude/worktrees"
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
printf ' M late.txt' > "$W/merged/.fx-status"
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

# ================================================================================================
# Runaway logs: *.log over 500 MB, emptied in place when a process holds it
# ================================================================================================
fresh
sparse "$H/Apps/svc/server.log" 600m; sparse "$H/.cache/tool/held.log" 600m; sparse "$H/Apps/svc/small.log" 100m
dc_stub lsof "for a in \"\$@\"; do case \"\$a\" in */held.log) printf 'p7\ncnode\n'; exit 0 ;; esac; done; exit 1"
run_scan --only runaway-logs
check "runaway logs: a big log nothing holds is offerable, deleted" "$(eq "$(state_of "$H/Apps/svc/server.log") $(method_of "$H/Apps/svc/server.log")" "offerable delete")"
check "runaway logs: a big log in a dotfolder that a process holds is emptied in place" "$(eq "$(state_of "$H/.cache/tool/held.log") $(method_of "$H/.cache/tool/held.log")" "offerable truncate")"
check "runaway logs: a 100 MB log is not listed" "$(eq "$(item_of "$H/Apps/svc/small.log")" "")"
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
judge large-files "$H/Pictures/raw.dng"
check "large files judge: outside the four folders it is not" "$(has "$JUDGED" "not offerable: ")"

finish
