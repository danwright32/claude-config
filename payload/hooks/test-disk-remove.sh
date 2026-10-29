#!/usr/bin/env bash
# Tests for lib/disk-remove.sh, the one place disk-full and disk-clean remove anything
# (claude-config#1805).
#
# disk-remove.sh deletes files on a real Mac, so it is run here ONLY through the disk-clean
# harness's dc_run (lib/disk-clean-harness.sh): a HOME inside a throwaway directory the harness made,
# a PATH of stubs plus core tools, writing tools that refuse anything outside that directory, and
# /usr/bin/trash replaced by a stub, because the real one ignores HOME and empties into the real
# ~/.Trash. Every refusal is aimed at a sentinel in a second throwaway directory OUTSIDE the
# harness's, standing in for the real Mac, so a refusal that fails destroys only that (L5).
#
# DR_UNDER_TEST names another copy of disk-remove.sh to run, with its three libraries beside it (predicates, record, units), so a
# deliberately broken copy can be shown to fail these tests (L1).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DR="${DR_UNDER_TEST:-$DIR/lib/disk-remove.sh}"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
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
there() { { [ -e "$1" ] || [ -L "$1" ]; } && echo ok || echo "$1 is gone"; }
gone() { { [ -e "$1" ] || [ -L "$1" ]; } && echo "$1 is still there" || echo ok; }

. "$DIR/lib/disk-clean-harness.sh" || { check "the harness is there to source" "could not source it"; finish; }
. "$DIR/lib/disk-clean-record.sh" || { check "the record library is there to source" "could not source it"; finish; }
check "disk-remove.sh is there to run" "$([ -f "$DR" ] && echo ok || echo "missing: $DR")"
# Size words and Docker sizes have one copy, lib/disk-clean-units.sh, which disk-clean's scan reads
# too (#1806), so a removal reports a size the way the scan offered it. Its functions are tested in
# skills/disk-clean/test-disk-clean-scan.sh; the Docker and report cases below run them through here.
. "$DIR/lib/disk-clean-units.sh" || check "lib/disk-clean-units.sh is there to source" "could not source it"
check "disk-remove.sh sources lib/disk-clean-units.sh rather than keeping its own copy" \
  "$(grep -qF '. "$LIB/disk-clean-units.sh"' "$DR" && grep -qF 'dcu_docker_kib "$(build_cache_kib)"' "$DR" && echo ok || echo "it does not source it, or does not read the build cache's size through dcu_docker_kib")"
check "the units library writes sizes as disk-remove reports them" "$(eq "$(dcu_human 1572864)" "1.5 GB")"
dc_setup || { check "the harness sets up" "dc_setup failed"; finish; }

# Outside the harness's root: the stand in for the real Mac.
OUT="$(mktemp -d "${TMPDIR:-/tmp}/disk-remove-outside.XXXXXXXX")" || OUT=""
[ -n "$OUT" ] || { check "an outside directory for sentinels" "mktemp failed"; finish; }
OUT="$(cd -P "$OUT" && pwd -P)"
trap 'dc_cleanup; chmod -R u+rwx "$OUT" 2>/dev/null; rm -rf "$OUT"' EXIT
printf 'keep\n' > "$OUT/sentinel"

H="$DC_HOME"
STATE="$H/.claude/state/disk-clean"
S=$'\037'
NOW="$(date +%s)"
VERDICTS="$DC_ROOT/verdicts"
FAKE_STAT="$DC_ROOT/fake-stat" # what section 17's stand in stat reports

# ---- the stubs every case starts from ----
default_stubs() {
  # The fixture category's judge: offerable, unless a verdict file named after the target says else.
  dc_stub judge "v=$(printf %q "$VERDICTS")/\${2##*/}; if [ -f \"\$v\" ]; then cat \"\$v\"; else echo offerable; fi"
  dc_stub lsof 'exit 1'
  dc_stub du 'for a in "$@"; do case "$a" in -*) ;; *) printf "12\t%s\n" "$a" ;; esac; done'
  dc_stub df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 100 50 5000 50%% /\n"'
  dc_stub tmutil 'echo "Snapshots for disk /:"; echo "com.apple.TimeMachine.2026-10-27-100000.local"'
  # Moves nothing to any real Trash: removes what it is given, and only inside the harness's root.
  dc_stub trash "for a in \"\$@\"; do case \"\$a\" in -*) ;; $(printf %q "$DC_ROOT")/*) /bin/rm -rf \"\$a\" ;; *) echo \"trash stub: refused \$a\" >&2; exit 1 ;; esac; done"
  dc_stub git
  dc_stub docker
  dc_stub derived-data-sweep
}

# A fresh case: no state, no calls recorded, no verdicts, a work folder in HOME.
fresh() {
  rm -rf "$H/.claude" "$H/w" "$VERDICTS" "$DC_ROOT/tmp/"* 2>/dev/null
  rm -f "$DC_STUBS/stat" "$FAKE_STAT" # section 17's stand in stat never outlives its case
  mkdir -p "$H/w" "$VERDICTS" "$STATE"
  : > "$DC_CALLS"
  : > "$DC_ROOT/refused.log"
  : > "$DC_ROOT/items"
  default_stubs
}
item() { printf '%s\n' "$1$S${2}$S${3}$S${4}$S${5:-}${S}${6:-offerable}$S${7:-}" >> "$DC_ROOT/items"; } # <id> <category> <method> <target> [bytes] [state] [identity]
record() { # <scan_id> <age in seconds> [record file]
  dcr_write "${3:-$STATE/last-scan.json}" "$1" "$((NOW - $2))" "$DC_ROOT/items"
}
plan() { # <plan file> <scan_id> <id>...
  local f="$1" sid="$2"; shift 2
  { printf 'scan_id %s\ncount %s\n' "$sid" "$#"; for i in "$@"; do printf 'item %s\n' "$i"; done; } > "$f"
}
run() { OUT_TEXT="$(dc_run bash "$DR" "$@" 2>&1)"; RC=$?; }
runenv() { OUT_TEXT="$(dc_run env "$@" 2>&1)"; RC=$?; } # env assignments, then bash "$DR" ...
LOGF() { printf '%s' "$STATE/removals/$1.log"; }
# How many INTENT lines in <log> are for an item id matching the regular expression <re>; 0 for no log.
intents() { [ -f "$1" ] || { echo 0; return; }; awk -F '\t' -v re="$2" '$1 == "INTENT" && $4 ~ re { n++ } END { print n + 0 }' "$1"; }
calls_of() { dc_calls "$1"; }

# ================================================================================================
# 1. Test mode: it runs only with HOME inside the throwaway directory, and seams only in test mode
# ================================================================================================
fresh
printf 'x\n' > "$H/w/f1"
item i1 fixture trash "$H/w/f1"; record s1 10; plan "$H/plan" s1 i1
runenv HOME="$OUT" bash "$DR" --plan "$H/plan"
check "with HOME outside the throwaway directory it refuses with exit 2" "$(eq "$RC" 2)"
check "and says HOME is not inside it" "$(has "$OUT_TEXT" "is not inside that throwaway directory")"
check "and wrote nothing into that HOME" "$(gone "$OUT/.claude")"
check "and moved nothing" "$(there "$H/w/f1")"
check "and never ran trash" "$(eq "$(calls_of trash)" "")"

runenv DISK_CLEAN_TEST_ROOT="$OUT" bash "$DR" --plan "$H/plan"
check "with DISK_CLEAN_TEST_ROOT naming a directory the harness did not make it refuses with exit 2" "$(eq "$RC" 2)"
check "and moved nothing" "$(there "$H/w/f1")"

runenv -u DISK_CLEAN_TEST_ROOT bash "$DR" --plan "$H/plan"
check "with a test seam set outside test mode it refuses with exit 2" "$(eq "$RC" 2)"
check "and says the seams are honoured only in test mode" "$(has "$OUT_TEXT" "honoured only in test mode")"
check "and moved nothing" "$(there "$H/w/f1")"
check "and never ran trash" "$(eq "$(calls_of trash)" "")"

# ================================================================================================
# 2. The plan and its scan: unusable, stale and mismatched are each refused, and say which
# ================================================================================================
fresh
printf 'x\n' > "$H/w/f1"
item i1 fixture trash "$H/w/f1"; record s1 3700; plan "$H/plan" s1 i1
run --plan "$H/plan"
check "a scan over an hour old is refused with exit 3" "$(eq "$RC" 3)"
check "and says it is over an hour old" "$(has "$OUT_TEXT" "over an hour")"
stale_text="$OUT_TEXT"
check "and nothing was judged or moved" "$([ -z "$(calls_of judge)$(calls_of trash)" ] && [ -e "$H/w/f1" ] && echo ok || echo "calls: $(dc_calls)")"

fresh
printf 'x\n' > "$H/w/f1"
item i1 fixture trash "$H/w/f1"; record s2 10; plan "$H/plan" s1 i1
run --plan "$H/plan"
check "a plan for a scan that is not the last scan is refused with exit 4" "$(eq "$RC" 4)"
check "and names both scans" "$(has "$OUT_TEXT" "the plan is for scan s1, but the last scan is s2")"
check "and its message is not the stale one" "$([ "$OUT_TEXT" != "$stale_text" ] && echo ok || echo same)"
check "and nothing was moved" "$(there "$H/w/f1")"

fresh
item i1 fixture trash "$H/w/f1"; record s1 -900; plan "$H/plan" s1 i1
run --plan "$H/plan"
check "a scan dated in the future is refused with exit 2" "$(eq "$RC" 2)"

fresh
item i1 fixture trash "$H/w/f1"; record s1 10
sed -i '' -e '$d' "$STATE/last-scan.json" 2>/dev/null || sed -i -e '$d' "$STATE/last-scan.json"
plan "$H/plan" s1 i1
run --plan "$H/plan"
check "a record that stops before its closing line is refused with exit 2" "$(eq "$RC" 2)"
check "and called incomplete, not read as a shorter scan" "$(has "$OUT_TEXT" "incomplete")"

fresh
item i1 fixture trash "$H/w/f1"; record s1 10
plan_bad() { printf '%s' "$1" > "$H/plan"; run --plan "$H/plan"; }
plan_bad $'scan_id s1\ncount 2\nitem i1\n'
check "a plan whose count does not match its items is refused with exit 2" "$(eq "$RC" 2)"
check "and says so" "$(has "$OUT_TEXT" "says count 2 but names 1")"
plan_bad $'scan_id s1\ncount 0\n'
check "a plan naming no items is refused with exit 2, never an empty success" "$(eq "$RC" 2)"
plan_bad $'scan_id s1\ncount 2\nitem i1\nitem i1\n'
check "a plan naming one item twice is refused with exit 2" "$(eq "$RC" 2)"
check "and the refusal is one line, with no second verdict after it" "$(eq "$(printf '%s\n' "$OUT_TEXT" | awk 'END { print NR }')" 1)"
plan_bad $'scan_id s1\ncount 1\nitem i1\npath /etc/passwd\n'
check "a plan carrying a line it does not hold, a path among them, is refused with exit 2" "$(eq "$RC" 2)"
plan_bad $'count 1\nitem i1\n'
check "a plan with no scan_id is refused with exit 2" "$(eq "$RC" 2)"
run --plan "$H/no-such-plan"
check "a plan file that is not there is refused with exit 2" "$(eq "$RC" 2)"
rm -f "$STATE/last-scan.json"; plan "$H/plan" s1 i1
run --plan "$H/plan"
check "a plan with no scan record to read is refused with exit 2" "$(eq "$RC" 2)"
check "and says to scan again" "$(has "$OUT_TEXT" "Scan again")"
run
check "no arguments is refused with exit 2" "$(eq "$RC" 2)"

# ================================================================================================
# 3. The happy path: trash and delete, INTENT before acting, the record marked, the report
# ================================================================================================
fresh
printf 'x\n' > "$H/w/f1"; mkdir -p "$H/w/d2/sub"; printf 'y\n' > "$H/w/d2/sub/f"
LOG1="$(LOGF s1)"
# The trash stub records whether the INTENT line for what it is given was already in the log.
dc_stub trash "for a in \"\$@\"; do case \"\$a\" in -*) ;; *) if grep -q \"^INTENT.*\$a\" $(printf %q "$LOG1"); then echo seen >> $(printf %q "$DC_ROOT/intent-seen"); fi; /bin/rm -rf \"\$a\" ;; esac; done"
rm -f "$DC_ROOT/intent-seen"
item i1 fixture trash "$H/w/f1"; item i2 fixture delete "$H/w/d2"; record s1 10; plan "$H/plan" s1 i1 i2
run --plan "$H/plan"
check "a plan of two offerable items exits 0" "$(eq "$RC" 0)"
check "the trashed file is gone" "$(gone "$H/w/f1")"
check "the deleted folder is gone" "$(gone "$H/w/d2")"
check "trash was called with -s and the path" "$(has "$(calls_of trash)" "trash -s $H/w/f1")"
check "the INTENT line was in the log before trash ran" "$([ -f "$DC_ROOT/intent-seen" ] && echo ok || echo "trash ran before its INTENT was written")"
check "the report says the file was moved to the Trash, which frees it only once emptied" \
  "$(has "$OUT_TEXT" "freed only once the Trash is emptied")"
check "the report names the deleted folder as removed" "$(has "$OUT_TEXT" "removed    $H/w/d2")"
check "the disk wide df change is given as context only" "$(has "$OUT_TEXT" "as context only")"
check "and the local snapshots are named" "$(has "$OUT_TEXT" "com.apple.TimeMachine.2026-10-27-100000.local")"
log1="$(cat "$LOG1" 2>/dev/null)"
check "the log holds an INTENT and an OUTCOME for each item, INTENT first" \
  "$(awk -F '\t' '$1 == "INTENT" { i[$4] = NR } $1 == "OUTCOME" { o[$4] = NR } END { exit !(i["i1"] && o["i1"] > i["i1"] && i["i2"] && o["i2"] > i["i2"]) }' "$LOG1" && echo ok || echo "log: $log1")"
rec="$(cat "$STATE/last-scan.json")"
check "the record marks the trashed item trashed" "$(has "$(grep '"id":"i1"' <<< "$rec")" '"state":"trashed"')"
check "and the deleted item removed" "$(has "$(grep '"id":"i2"' <<< "$rec")" '"state":"removed"')"
check "and the record is still complete" "$(dcr_complete "$STATE/last-scan.json" && echo ok || echo "$rec")"
check "the lock is released" "$(gone "$STATE/remove.lock")"
check "no write was refused by the harness's guard" "$(eq "$(dc_refusals)" "")"

run --plan "$H/plan"
check "the same plan run again skips both, as already settled, exit 5" "$(eq "$RC" 5)"
check "and says an earlier run settled them" "$(has "$OUT_TEXT" "an earlier run already settled it (trashed)")"

# A record written by hand, as the scanner will write it, rather than by the library this reads it
# with: the layout is pinned by its text, not by one function agreeing with another (L58).
fresh
printf 'x\n' > "$H/w/hand"
{
  printf '{"version":1,"scan_id":"hand-1","scanned_at":%s,"items":[\n' "$((NOW - 5))"
  printf '{"id":"h1","category":"fixture","method":"delete","target":"%s","bytes":4096,"state":"offerable","flags":"x"},\n' "$H/w/hand"
  printf ']}\n'
} > "$STATE/last-scan.json"
plan "$H/plan" hand-1 h1
run --plan "$H/plan"
check "a record written by hand in the documented layout is read, and its item removed" \
  "$([ "$RC" -eq 0 ] && [ ! -e "$H/w/hand" ] && echo ok || echo "exit $RC: $OUT_TEXT")"
check "and marking it keeps the fields it does not own" "$(has "$(cat "$STATE/last-scan.json")" '"flags":"x"')"

# ================================================================================================
# 4. The identity deny list: checked first, for every item, whatever its category says
# ================================================================================================
fresh
mkdir -p "$H/Library/Mobile Documents/com~apple~CloudDocs" "$H/Downloads/Thing.app/Contents" "$H/.ssh" "$H/Library/Mail/V10" \
  "$H/Pictures" "$H/Library/Application Support/SynologyDrive/data" "$H/Library/CloudStorage/GoogleDrive-x" "$H/.claude/projects"
for f in "$H/Library/Mobile Documents/com~apple~CloudDocs/doc.txt" "$H/Downloads/Thing.app/Contents/Info.plist" "$H/.ssh/id_ed25519" \
  "$H/Library/Mail/V10/mbox" "$H/Pictures/Cat.lrcat" "$H/Library/Application Support/SynologyDrive/data/x" \
  "$H/Library/CloudStorage/GoogleDrive-x/f"; do printf 'precious\n' > "$f"; done
ln -s "$H/Library/Mobile Documents" "$H/w/icloud-link"
n=0
for t in "$H/Library/Mobile Documents/com~apple~CloudDocs/doc.txt" "$H/Downloads/Thing.app/Contents/Info.plist" "$H/.ssh/id_ed25519" \
  "$H/Library/Mail/V10/mbox" "$H/Pictures/Cat.lrcat" "$H/Library/Application Support/SynologyDrive/data" \
  "$H/Library/CloudStorage/GoogleDrive-x/f" "$H/.claude" "$H/Downloads" "$H" /Applications/Safari.app /System/Library \
  "$H/w/icloud-link/com~apple~CloudDocs/doc.txt"; do
  n=$((n + 1)); item "d$n" fixture delete "$t"
done
record s1 10; plan "$H/plan" s1 $(i=1; while [ "$i" -le "$n" ]; do printf 'd%s ' "$i"; i=$((i + 1)); done)
run --plan "$H/plan"
check "a plan of deny listed items exits 5" "$(eq "$RC" 5)"
check "every one of the $n is skipped as never removed" "$(eq "$(grep -c 'never removed: ' <<< "$OUT_TEXT")" "$n")"
check "an iCloud Drive file is named as in iCloud Drive" "$(has "$OUT_TEXT" "in iCloud Drive (removing it removes it from iCloud on every device)")"
check "a file inside an app package is refused as inside a package" "$(has "$OUT_TEXT" "app package or inside one")"
check "a key in ~/.ssh is refused as credentials" "$(has "$OUT_TEXT" "keys and credentials")"
check "the Mail store is refused" "$(has "$OUT_TEXT" "the Mail store")"
check "a photo editor catalog is refused" "$(has "$OUT_TEXT" "photo editor catalog")"
check "Synology Drive's store is refused" "$(has "$OUT_TEXT" "Synology Drive")"
check "a cloud storage folder is refused" "$(has "$OUT_TEXT" "cloud storage folder")"
check "the ~/.claude dotfolder itself is refused" "$(has "$OUT_TEXT" "dotfolder .claude itself")"
check "a standard folder itself is refused" "$(has "$OUT_TEXT" "standard folder Downloads itself")"
check "the home folder itself is refused" "$(has "$OUT_TEXT" "the home folder itself")"
check "/Applications is refused" "$(has "$OUT_TEXT" "under /Applications")"
check "/System is refused" "$(has "$OUT_TEXT" "under /System")"
check "a path reaching iCloud Drive through a linked folder is refused by where it really is" \
  "$(has "$(grep -F "$H/w/icloud-link/" <<< "$OUT_TEXT")" "iCloud Drive")"
check "and every deny listed file is still there" \
  "$(for f in "$H/Library/Mobile Documents/com~apple~CloudDocs/doc.txt" "$H/Downloads/Thing.app/Contents/Info.plist" "$H/.ssh/id_ed25519" "$H/Library/Mail/V10/mbox" "$H/Pictures/Cat.lrcat" "$H/Library/Application Support/SynologyDrive/data/x" "$H/Library/CloudStorage/GoogleDrive-x/f" "$H/.claude/projects"; do [ -e "$f" ] || { echo "$f is gone"; exit; }; done; echo ok)"
check "the deny list came before the judge: no category judge ran for any of them" "$(eq "$(calls_of judge)" "")"
check "and no INTENT was written for any of them" "$(eq "$(intents "$(LOGF s1)" '.')" 0)"

# ================================================================================================
# 5. Symbolic links and the allowed root
# ================================================================================================
fresh
printf 'real\n' > "$H/w/real"; ln -s "$H/w/real" "$H/w/link"
mkdir -p "$DC_ROOT/beside-home"; printf 'x\n' > "$DC_ROOT/beside-home/f"
item l1 fixture delete "$H/w/link"; item l2 fixture delete "$DC_ROOT/beside-home/f"; item l3 fixture delete "$OUT/sentinel"
item l4 fixture delete "w/relative"; item l5 fixture delete "$H/w/../w/real"
record s1 10; plan "$H/plan" s1 l1 l2 l3 l4 l5
run --plan "$H/plan"
check "a symbolic link item is skipped, saying it is a link" "$(has "$(grep -F "$H/w/link" <<< "$OUT_TEXT")" "symbolic link")"
check "and neither the link nor what it points at was touched" "$([ -L "$H/w/link" ] && [ -f "$H/w/real" ] && echo ok || echo touched)"
check "an item outside HOME and the temp folder is skipped as outside the folders it removes from" \
  "$(has "$(grep -F "$DC_ROOT/beside-home/f" <<< "$OUT_TEXT")" "outside the folders this tool removes from")"
check "an item outside the throwaway directory is skipped too" "$(has "$(grep -F "$OUT/sentinel" <<< "$OUT_TEXT")" "outside the folders")"
check "and the sentinel standing in for the real Mac is intact" "$(eq "$(cat "$OUT/sentinel")" keep)"
check "a relative path is skipped" "$(has "$OUT_TEXT" "not absolute")"
check "a path with a .. component is skipped" "$(has "$OUT_TEXT" ". or .. component")"
check "and the file it named is still there" "$(there "$H/w/real")"
check "no write was refused by the guard: disk-remove refused them itself" "$(eq "$(dc_refusals)" "")"

# The temp folder is an allowed root too.
fresh
mkdir -p "$DC_ROOT/tmp/claude-cache"; printf 'x\n' > "$DC_ROOT/tmp/claude-cache/f"
item t1 fixture delete "$DC_ROOT/tmp/claude-cache"; record s1 10; plan "$H/plan" s1 t1
run --plan "$H/plan"
check "an item in the temp folder is removed" "$([ "$RC" -eq 0 ] && [ ! -e "$DC_ROOT/tmp/claude-cache" ] && echo ok || echo "exit $RC: $OUT_TEXT")"

# ================================================================================================
# 6. The category's judge, run again immediately before acting
# ================================================================================================
fresh
for n in 1 2 3 4 5; do printf 'x\n' > "$H/w/j$n"; done
printf 'not offerable: a session is using it\n' > "$VERDICTS/j2"
printf 'unmeasured: timed out after 10s\n' > "$VERDICTS/j3"
printf 'probably fine\n' > "$VERDICTS/j4"
dc_stub judge "case \"\${2##*/}\" in j5) exit 3 ;; esac; v=$(printf %q "$VERDICTS")/\${2##*/}; if [ -f \"\$v\" ]; then cat \"\$v\"; else echo offerable; fi"
for n in 1 2 3 4 5; do item "j$n" fixture trash "$H/w/j$n"; done
record s1 10; plan "$H/plan" s1 j1 j2 j3 j4 j5
run --plan "$H/plan"
check "only the item its judge calls offerable is trashed" "$(gone "$H/w/j1")"
check "a not offerable verdict skips the item with the judge's reason" "$(has "$OUT_TEXT" "judged again just now: not offerable: a session is using it")"
check "an unmeasured verdict skips it" "$(has "$OUT_TEXT" "judged again just now: unmeasured: timed out after 10s")"
check "an answer that is none of the three skips it, quoting the answer" "$(has "$OUT_TEXT" "answered 'probably fine'")"
check "a judge that fails skips it, naming the exit" "$(has "$OUT_TEXT" "judge failed (exit 3)")"
check "and every item not judged offerable is still there" "$(for n in 2 3 4 5; do [ -e "$H/w/j$n" ] || { echo "j$n is gone"; exit; }; done; echo ok)"
check "the judge was asked with the word judge and the item's path, under its category" \
  "$(has "$(calls_of judge)" "judge judge $H/w/j1")"
check "an INTENT was written for the item its judge offered" "$(eq "$(intents "$(LOGF s1)" '^j1$')" 1)"
check "and none for an item its judge kept" "$(eq "$(intents "$(LOGF s1)" '^j[2-5]$')" 0)"
check "a plan with any item skipped exits 5" "$(eq "$RC" 5)"

# The real module dispatch, with a fixture category module on disk instead of the judge seam.
fresh
CATS="$DC_ROOT/categories"; mkdir -p "$CATS"
cat > "$CATS/fixture.sh" <<'EOF'
#!/bin/bash
# A fixture category: offerable unless its path says refuse; it checks how it was asked.
[ "${1:-}" = judge ] && [ "${DISK_CLEAN_CATEGORY:-}" = fixture ] || { echo "unmeasured: asked wrongly"; exit 0; }
case "${2:-}" in *refuse*) echo "not offerable: the fixture says no" ;; *) echo offerable ;; esac
EOF
chmod +x "$CATS/fixture.sh"
printf 'x\n' > "$H/w/ok"; printf 'x\n' > "$H/w/refuse"; printf 'x\n' > "$H/w/nomodule"; printf 'x\n' > "$H/w/badname"
item m1 fixture trash "$H/w/ok"; item m2 fixture trash "$H/w/refuse"; item m3 nosuchcategory trash "$H/w/nomodule"; item m4 '../fixture' trash "$H/w/badname"
record s1 10; plan "$H/plan" s1 m1 m2 m3 m4
runenv DISK_CLEAN_JUDGE= DISK_CLEAN_CATEGORIES="$CATS" bash "$DR" --plan "$H/plan"
check "through the real dispatch, the category module's offerable item is trashed" "$(gone "$H/w/ok")"
check "its not offerable item is kept with its reason" "$(has "$OUT_TEXT" "not offerable: the fixture says no")"
check "an item whose category has no module is kept, naming the missing file" "$(has "$OUT_TEXT" "no judge for the category nosuchcategory")"
check "an item whose category is not a category name is kept" "$(has "$OUT_TEXT" "is not a category name")"
check "and those three are still there" "$([ -e "$H/w/refuse" ] && [ -e "$H/w/nomodule" ] && [ -e "$H/w/badname" ] && echo ok || echo "one is gone")"

# ================================================================================================
# 7. The open check: lsof's stderr means it could not tell, never that the item is free (L42)
# ================================================================================================
fresh
printf 'x\n' > "$H/w/inuse"; printf 'x\n' > "$H/w/denied"; mkdir -p "$H/w/dir"; printf 'x\n' > "$H/w/dir/f"
dc_stub lsof 'case "$*" in
  *inuse*) printf "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nSlack 77 dan 3r REG 1,4 2 9 %s\n" "$2"; exit 0 ;;
  *denied*) echo "lsof: WARNING: can'"'"'t stat() file: Permission denied" >&2; exit 1 ;;
  *) exit 1 ;;
esac'
item o1 fixture delete "$H/w/inuse"; item o2 fixture delete "$H/w/denied"; item o3 fixture delete "$H/w/dir"
record s1 10; plan "$H/plan" s1 o1 o2 o3
run --plan "$H/plan"
check "an item lsof says is open is skipped, naming who has it" "$(has "$OUT_TEXT" "in use by Slack")"
check "an item lsof wrote to stderr about is skipped as could not tell" "$(has "$(grep -F "$H/w/denied" <<< "$OUT_TEXT")" "could not tell whether it is in use")"
check "and both are still there" "$([ -e "$H/w/inuse" ] && [ -e "$H/w/denied" ] && echo ok || echo "one is gone")"
check "a folder is checked with lsof +D" "$(has "$(calls_of lsof)" "lsof +D $H/w/dir")"
check "and, with lsof silent, the folder is removed" "$(gone "$H/w/dir")"

# ================================================================================================
# 8. The trash method never falls back to deleting
# ================================================================================================
fresh
printf 'x\n' > "$H/w/t1"
item t1 fixture trash "$H/w/t1"; record s1 10; plan "$H/plan" s1 t1
runenv DISK_CLEAN_TRASH=/nonexistent/usr/bin/trash bash "$DR" --plan "$H/plan"
check "without /usr/bin/trash the item is skipped, exit 5" "$(eq "$RC" 5)"
check "saying it ships with macOS 15 and this never deletes instead" "$(has "$OUT_TEXT" "ships with macOS 15), and this tool never deletes in place of moving to the Trash")"
check "and the file is still there" "$(there "$H/w/t1")"
dc_stub trash 'echo "trash: could not move" >&2; exit 5'
run --plan "$H/plan"
check "a trash that fails leaves the item reported failed, still there" "$([ "$RC" -eq 5 ] && [ -e "$H/w/t1" ] && echo ok || echo "exit $RC")"
check "and the failure quotes trash" "$(has "$OUT_TEXT" "still there after trash (exit 5: trash: could not move)")"
dc_stub trash 'exit 0'
run --plan "$H/plan"
check "a trash that says it worked but moved nothing is reported failed, never trashed" "$(has "$OUT_TEXT" "failed     $H/w/t1")"

# ================================================================================================
# 9. Truncate, for a log a process holds open, through a guarded tool
# ================================================================================================
fresh
head -c 50000 /dev/zero > "$H/w/run.log"; mkdir -p "$H/w/logdir"
dc_stub du 'for a in "$@"; do case "$a" in -*) ;; *) s=$(/usr/bin/stat -c %s "$a" 2>/dev/null || /usr/bin/stat -f %z "$a"); printf "%s\t%s\n" "$(( (s + 1023) / 1024 ))" "$a" ;; esac; done'
item r1 fixture truncate "$H/w/run.log"; item r2 fixture truncate "$H/w/logdir"
record s1 10; plan "$H/plan" s1 r1 r2
run --plan "$H/plan"
check "a truncated log is still there" "$(there "$H/w/run.log")"
check "and empty" "$(eq "$(wc -c < "$H/w/run.log" | tr -d ' ')" 0)"
check "and reported truncated with what it freed" "$(has "$OUT_TEXT" "truncated  $H/w/run.log  (49 KB freed")"
check "truncate never runs the open check, since the point is a file held open" "$(hasnt "$(calls_of lsof)" run.log)"
check "a folder is skipped by truncate" "$(has "$(grep -F "$H/w/logdir" <<< "$OUT_TEXT")" "truncate empties a single file")"
check "the record marks it truncated" "$(has "$(grep '"id":"r1"' "$STATE/last-scan.json")" '"state":"truncated"')"
# The tool it truncates with is guarded: pointed outside the throwaway directory it refuses (the
# harness cannot see a `>` redirection, which is why truncate does not use one).
outside="$(dc_run tee "$OUT/sentinel" < /dev/null 2>&1)"; trc=$?
check "the truncating tool, aimed outside the throwaway directory, is refused by the guard" \
  "$([ "$trc" -eq 97 ] && [ "$(cat "$OUT/sentinel")" = keep ] && echo ok || echo "exit $trc, sentinel: $(cat "$OUT/sentinel"), said: $outside")"
redirects="$(awk '!/^[[:space:]]*#/ && /[^0-9&<]>[[:space:]]*"\$(PHYS|t|target|p|a)"/ { print FNR ": " $0 }' "$DR")"
check "disk-remove empties with tee and never with a redirection onto an item" \
  "$([ -z "$redirects" ] && grep -qE 'tee "\$PHYS"' "$DR" && echo ok || echo "redirections onto an item: $redirects")"

# ================================================================================================
# 10. Worktrees: git worktree remove without --force, so git refuses a dirty one
# ================================================================================================
fresh
mkdir -p "$H/w/wt-clean" "$H/w/wt-dirty"
dc_stub git 'case "$2" in */wt-dirty) echo "fatal: '"'"'$2'"'"' contains modified or untracked files, use --force to delete it" >&2; exit 128 ;; esac; /bin/rm -rf "$2"'
item w1 fixture worktree "$H/w/wt-clean"; item w2 fixture worktree "$H/w/wt-dirty"
record s1 10; plan "$H/plan" s1 w1 w2
run --plan "$H/plan"
check "a clean worktree is removed" "$(gone "$H/w/wt-clean")"
check "git was asked to remove it from inside, without --force" "$(has "$(calls_of git)" "git -C $H/w/wt-clean worktree remove $H/w/wt-clean")"
check "and never with --force" "$(hasnt "$(calls_of git)" "--force")"
check "a dirty worktree git refuses is skipped, quoting git" "$(has "$OUT_TEXT" "git refused to remove the worktree: fatal:")"
check "and is still there" "$(there "$H/w/wt-dirty")"

# ================================================================================================
# 11. Docker: named removals only, volumes never, prune all refused by name
# ================================================================================================
fresh
dc_stub docker 'exit 1'
item k1 fixture docker "image sha256:abc"; record s1 10; plan "$H/plan" s1 k1
run --plan "$H/plan"
check "with Docker not running a Docker item is skipped, saying so" "$(has "$OUT_TEXT" "Docker is not running")"
check "and nothing but docker info was asked" "$(eq "$(calls_of docker)" "docker info")"

fresh
GONE_MARK="$DC_ROOT/image-gone"; CACHE_MARK="$DC_ROOT/cache-pruned"; rm -f "$GONE_MARK" "$CACHE_MARK"
dc_stub docker "case \"\$1 \$2\" in
  'info ') exit 0 ;;
  'image inspect') [ -e $(printf %q "$GONE_MARK") ] && exit 1; echo 2097152 ;;
  'image rm') : > $(printf %q "$GONE_MARK") ;;
  'container inspect') echo 'true 1024' ;;
  'system df') if [ -e $(printf %q "$CACHE_MARK") ]; then echo 'Build Cache|0B'; else echo 'Build Cache|1.5GB'; fi ;;
  'builder prune') : > $(printf %q "$CACHE_MARK") ;;
  *) echo \"unexpected docker \$*\" >&2; exit 99 ;;
esac"
item k1 fixture docker "image sha256:abc"; item k2 fixture docker "volume prune"; item k3 fixture docker "system prune"
item k4 fixture docker "volume rm pgdata"; item k5 fixture docker "container web-1"; item k6 fixture docker "builder cache"
item k7 fixture docker "image sha256:def"; printf 'not offerable: a project still uses it\n' > "$VERDICTS/image sha256:def"
record s1 10; plan "$H/plan" s1 k7 k1 k2 k3 k4 k5 k6
run --plan "$H/plan"
check "a Docker image its judge keeps is skipped with the judge's reason" \
  "$(has "$(grep -F 'image sha256:def' <<< "$OUT_TEXT")" "judged again just now: not offerable: a project still uses it")"
check "and only the image the judge offered was removed" "$(eq "$(calls_of docker | awk '/^docker image rm/')" "docker image rm sha256:abc")"
check "a named image is removed, and its size is Docker's" "$(has "$OUT_TEXT" "removed    docker image sha256:abc  (2 MB, as Docker reports its size)")"
check "docker volume prune is refused by name" "$(has "$(grep -F 'volume prune' <<< "$OUT_TEXT")" "refused by name")"
check "docker system prune is refused by name" "$(has "$(grep -F 'system prune' <<< "$OUT_TEXT")" "refused by name: docker system prune")"
check "a named volume is never removed either" "$(has "$(grep -F 'volume rm pgdata' <<< "$OUT_TEXT")" "never removed by this tool")"
check "a running container is skipped" "$(has "$(grep -F 'container web-1' <<< "$OUT_TEXT")" "it is running")"
check "the build cache is pruned, freed as measured before and after" "$(has "$(grep -F 'builder cache' <<< "$OUT_TEXT")" "of build cache")"
bad_docker="$(calls_of docker | awk '/^docker (volume|system prune|container rm|image prune)/')"
check "nothing ever ran a volume, prune or running container command" "$([ -z "$bad_docker" ] && echo ok || echo "ran: $bad_docker")"

# ================================================================================================
# 12. Xcode build caches, through derived-data-sweep.sh --remove-one under its own lock
# ================================================================================================
fresh
mkdir -p "$H/w/DD/App-a" "$H/w/DD/App-b" "$H/w/DD/App-c"
dc_stub derived-data-sweep 'case "$2" in */App-a) /bin/rm -rf "$2"; echo "removed $2" ;; */App-b) echo "kept $2: modified in the last 60 minutes"; exit 4 ;; *) echo "derived-data-sweep: a sweep is already running"; exit 75 ;; esac'
item x1 fixture derived-data "$H/w/DD/App-a"; item x2 fixture derived-data "$H/w/DD/App-b"; item x3 fixture derived-data "$H/w/DD/App-c"
record s1 10; plan "$H/plan" s1 x1 x2 x3
run --plan "$H/plan"
check "an orphaned build cache the sweep removes is reported removed" "$(has "$OUT_TEXT" "removed    $H/w/DD/App-a")"
check "the sweep was asked with --remove-one and the folder" "$(has "$(calls_of derived-data-sweep)" "derived-data-sweep --remove-one $H/w/DD/App-a")"
check "one the sweep keeps is skipped with the sweep's reason" "$(has "$OUT_TEXT" "the Xcode build cache sweep kept it: kept $H/w/DD/App-b: modified in the last 60 minutes")"
check "while an automatic sweep holds the lock the item is skipped, saying so" "$(has "$OUT_TEXT" "automatic sweep of Xcode build caches is running now")"
check "and those two are still there" "$([ -d "$H/w/DD/App-b" ] && [ -d "$H/w/DD/App-c" ] && echo ok || echo "one is gone")"

# ================================================================================================
# 13. Gone already, ids the scan never had, the lock
# ================================================================================================
fresh
item g1 fixture delete "$H/w/never-made"; record s1 10; plan "$H/plan" s1 g1 g9
run --plan "$H/plan"
check "an item already gone is skipped as already gone, exit 5" "$([ "$RC" -eq 5 ] && echo ok || echo "exit $RC")"
check "and says so" "$(has "$OUT_TEXT" "it was already gone")"
check "and the record marks it gone, so the warning does not quote it" "$(has "$(grep '"id":"g1"' "$STATE/last-scan.json")" '"state":"gone"')"
check "an id the scan never had is skipped, never guessed at" "$(has "$OUT_TEXT" "has no item with this id")"

fresh
printf 'x\n' > "$H/w/l1"; item l1 fixture delete "$H/w/l1"; record s1 10; plan "$H/plan" s1 l1
sleep 300 & holder=$!
ln -s "$holder" "$STATE/remove.lock"
run --plan "$H/plan"
check "while another live run holds the lock it exits 75" "$(eq "$RC" 75)"
check "and removed nothing" "$(there "$H/w/l1")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
run --plan "$H/plan"
check "a lock left by a run that is no longer alive is taken over" "$([ "$RC" -eq 0 ] && [ ! -e "$H/w/l1" ] && echo ok || echo "exit $RC: $OUT_TEXT")"
check "and the report says it took it over" "$(has "$OUT_TEXT" "had stopped without releasing its lock")"

# ================================================================================================
# 14. A run killed midway leaves its INTENT lines, and the next run settles them (L617)
# ================================================================================================
. "$DIR/lib/hang-wait.sh" || { check "lib/hang-wait.sh is there" "missing"; finish; }
fresh
for n in 1 2 3 4 5; do printf 'x\n' > "$H/w/k$n"; item "k$n" fixture trash "$H/w/k$n"; done
record s1 10; plan "$H/plan" s1 k1 k2 k3 k4 k5
PIDF="$DC_ROOT/dr.pid"; REL="$DC_ROOT/release"; rm -f "$PIDF" "$REL"
# On the third item the trash stub says it has been reached and waits for the suite, so the run is
# killed exactly while that item is in hand. disk-remove's own pid is the one its lock names (the
# stub's parent is the command substitution's subshell, not disk-remove).
dc_stub trash "for a in \"\$@\"; do case \"\$a\" in -*) ;; */k3) echo reached > $(printf %q "$PIDF"); n=0; while [ ! -e $(printf %q "$REL") ] && [ \$n -lt $((HANG_S * 10)) ]; do sleep 0.1; n=\$((n + 1)); done; /bin/rm -f \"\$a\" ;; *) /bin/rm -f \"\$a\" ;; esac; done"
( dc_run bash "$DR" --plan "$H/plan" > "$DC_ROOT/killed.out" 2>&1 ) &
bg=$!
hang_wait "[ -s \"\$PIDF\" ]"
drpid=""; [ -s "$PIDF" ] && drpid="$(readlink "$STATE/remove.lock" 2>/dev/null)"
case "$drpid" in ''|*[!0-9]*) drpid="" ;; *) kill -9 "$drpid" 2>/dev/null ;; esac
: > "$REL"
wait "$bg" 2>/dev/null
check "the run reached the third item and was killed there" "$([ -n "$drpid" ] && echo ok || echo "the third item was never reached")"
LOGK="$(LOGF s1)"
check "the log holds INTENT and OUTCOME for the first two items" \
  "$(awk -F '\t' '$4 == "k1" || $4 == "k2" { c[$1 $4]++ } END { exit !(c["INTENTk1"] && c["OUTCOMEk1"] && c["INTENTk2"] && c["OUTCOMEk2"]) }' "$LOGK" && echo ok || echo "log: $(cat "$LOGK")")"
check "and an INTENT for the third with no OUTCOME, so what was in hand is on record" \
  "$(awk -F '\t' '$4 == "k3" { c[$1]++ } END { exit !(c["INTENT"] == 1 && !c["OUTCOME"]) }' "$LOGK" && echo ok || echo "log: $(cat "$LOGK")")"
check "and nothing at all for the two it never reached" "$(awk -F '\t' '$4 == "k4" || $4 == "k5"' "$LOGK" | awk 'END { exit NR > 0 }' && echo ok || echo "log: $(cat "$LOGK")")"
check "the killed run left its lock behind" "$([ -L "$STATE/remove.lock" ] && echo ok || echo "no lock left")"
default_stubs
run --plan "$H/plan"
check "the next run takes over the dead run's lock and finishes" "$([ "$RC" -eq 5 ] && echo ok || echo "exit $RC: $OUT_TEXT")"
check "and reports what the killed run had in hand, and that it is gone now" "$(has "$OUT_TEXT" "stopped partway while removing $H/w/k3; it is gone now")"
check "the two it never reached are trashed now" "$([ ! -e "$H/w/k4" ] && [ ! -e "$H/w/k5" ] && echo ok || echo "still there")"
check "the record marks all five settled" "$(eq "$(grep -cE '"state":"(trashed|gone)"' "$STATE/last-scan.json")" 5)"
# A killed run that was removing a Docker target: nothing here can look it up, so the next run says
# that rather than claiming it is still there.
fresh
printf 'x\n' > "$H/w/z1"; item z1 fixture delete "$H/w/z1"; record s1 10; plan "$H/plan" s1 z1
mkdir -p "$STATE/removals"; printf 'INTENT\t%s\t1-1\tdk\tdocker\timage sha256:abc\t\n' "$NOW" > "$(LOGF s1)"
run --plan "$H/plan"
check "an interrupted Docker removal is reported as not checked, never as still there" \
  "$(has "$OUT_TEXT" "stopped partway while removing docker image sha256:abc; whether it went is not checked here")"

# ================================================================================================
# 15. A large plan (L101): every item judged, checked, measured, trashed and logged, nothing skipped
# ================================================================================================
# Why 200 and not thousands (claude-config#1843). Nothing in disk-remove.sh branches on how many
# items a plan holds: the plan, the record, the log and the marks all go through files read a line
# at a time, never an argument list or an in memory limit. Its cost is per item, about 22 to 30 ms
# here, almost all of it the four tools each item runs (judge, lsof, du, trash) plus its own
# substitutions, and measured flat from 200 to 2000 items (2026-10-27: 24 to 30 ms an item at 200,
# 22 to 23 ms at 2000, load average 14 to 15 on 12 cores), so 2000 items spent 36 to 104 seconds
# proving what 200 do. The one count dependent branch is the total's unit: the du stub reports
# 12 KB an item, so the "MB" words need at least 86 items, and the total is asserted below so a
# smaller BIG fails here rather than quietly testing the KB branch. Every item running each tool
# exactly once is asserted from the stubs' own call log, so a per item step that starts being
# skipped, or repeated, at size is caught structurally rather than by a timing.
if [ -n "${DR_UNDER_TEST:-}" ] && [ -n "${DR_SKIP_BIG:-}" ]; then
  # Only for a run against a deliberately broken copy, where the large case adds seconds to every
  # mutant and proves nothing the cases above do not.
  echo "SUITE-PART-UNMEASURED the large plan case: skipped for a copy under test (DR_SKIP_BIG)"
else
fresh
BIG=200
mkdir -p "$H/w/big"
i=1; while [ "$i" -le "$BIG" ]; do : > "$H/w/big/f$i"; printf '%s\n' "b$i${S}fixture${S}trash${S}$H/w/big/f$i${S}${S}offerable${S}" >> "$DC_ROOT/items"; i=$((i + 1)); done
record big 10
{ printf 'scan_id big\ncount %s\n' "$BIG"; i=1; while [ "$i" -le "$BIG" ]; do printf 'item b%s\n' "$i"; i=$((i + 1)); done; } > "$H/plan"
big_start="$(date +%s)"
run --plan "$H/plan"
big_took=$(( $(date +%s) - big_start ))
echo "  ($BIG items took ${big_took}s)"
check "a plan of $BIG items exits 0" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $(tail -5 <<< "$OUT_TEXT")")"
check "every one of them is gone" "$(eq "$(find "$H/w/big" -type f | wc -l | tr -d ' ')" 0)"
check "the report counts all of them" "$(has "$OUT_TEXT" "moved $BIG item(s) to the Trash")"
check "the total is every item's own size summed, in MB (the unit the count must reach)" \
  "$(has "$OUT_TEXT" "moved $BIG item(s) to the Trash, $((BIG * 12 / 1024)) MB, which")"
# Each per item tool ran once for every item and for no item twice: <calls> <distinct targets>.
for big_tool in judge lsof du trash; do
  check "every item ran $big_tool exactly once" \
    "$(eq "$(dc_calls "$big_tool" | awk '{ n++; if (!seen[$NF]++) d++ } END { print n + 0, d + 0 }')" "$BIG $BIG")"
done
check "the log holds $BIG INTENT and $BIG OUTCOME lines" "$(eq "$(grep -c '^INTENT' "$(LOGF big)") $(grep -c '^OUTCOME' "$(LOGF big)")" "$BIG $BIG")"
check "the record marks all $BIG trashed and is still complete" \
  "$([ "$(grep -c '"state":"trashed"' "$STATE/last-scan.json")" -eq "$BIG" ] && dcr_complete "$STATE/last-scan.json" && echo ok || echo "marked $(grep -c '"state":"trashed"' "$STATE/last-scan.json")")"
fi

# ================================================================================================
# 16. --propose: how disk-full names what Dan decided on, and its own judge at removal
# ================================================================================================
fresh
mkdir -p "$H/Downloads/old-installer" "$H/Library/Mobile Documents/x"
printf 'big\n' > "$H/Downloads/old-installer/setup.dmg"; printf 'x\n' > "$H/Library/Mobile Documents/x/doc"; printf 'x\n' > "$H/w/swap"
run --propose trash "$H/Downloads/old-installer" "$H/Library/Mobile Documents/x/doc" "$H/w/not-there" "$H/w/swap"
check "--propose with one refusal among its paths exits 5" "$(eq "$RC" 5)"
check "it offers the folder Dan named" "$(has "$OUT_TEXT" "offered  $H/Downloads/old-installer")"
check "it refuses a deny listed path at once, before any plan" "$(has "$OUT_TEXT" "refused  $H/Library/Mobile Documents/x/doc: never removed:")"
check "it refuses a path that is not there" "$(has "$OUT_TEXT" "refused  $H/w/not-there: it is not there")"
named_plan="$(sed -n 's/^Plan: \([^ ]*\) .*/\1/p' <<< "$OUT_TEXT")"
check "it writes a plan and names it" "$([ -n "$named_plan" ] && [ -f "$named_plan" ] && echo ok || echo "said: $OUT_TEXT")"
check "and names the command that removes them" "$(has "$OUT_TEXT" "bash ~/.claude/hooks/lib/disk-remove.sh --plan $named_plan")"
check "the plan holds the two offered items only" "$(eq "$(grep -c '^item ' "$named_plan" 2>/dev/null)" 2)"
check "and it removed nothing" "$([ -e "$H/Downloads/old-installer" ] && [ -e "$H/w/swap" ] && echo ok || echo "something went")"
# The file is replaced by another of the same name. The replacement is written BEFORE the original
# goes and renamed over it, so both exist at once and cannot share an inode: deleting first let Linux
# hand the new file the old one's inode, and this check failed on CI only some of the time
# (claude-config#1840). Inode reuse itself is tested with a stubbed stat in section 17.
printf 'new\n' > "$H/w/swap.new"; rm -f "$H/w/swap"; mv "$H/w/swap.new" "$H/w/swap"
run --plan "$named_plan"
check "running the plan trashes the folder that was proposed" "$(gone "$H/Downloads/old-installer")"
check "and skips a file replaced since it was proposed" "$(has "$OUT_TEXT" "it is not the item that was proposed")"
check "which is still there" "$(there "$H/w/swap")"
# GNU stat (the Ubuntu CI runner) takes -f as "file system status" and exits 0 with a meaningless
# answer, while BSD stat refuses GNU's -c, so the identity and size readers must ask -c first.
bsd_first="$(awk '/stat -f/ && !/stat -c[^|]*\|\|[^|]*stat -f/ && !/^[[:space:]]*#/ { print FNR ": " $0 }' "$DR")"
check "every stat in disk-remove.sh asks GNU's -c before BSD's -f" "$([ -z "$bsd_first" ] && echo ok || echo "BSD first: $bsd_first")"
run --propose shred "$H/w/swap"
check "--propose with a method it does not offer is refused with exit 2" "$(eq "$RC" 2)"
run --propose truncate "$H/Downloads"
check "--propose truncate of a folder refuses it" "$(has "$OUT_TEXT" "refused")"

# ================================================================================================
# 17. Inode reuse (claude-config#1840, L1032): a file created where a removed one was can be given
#     the same device and inode, so the named judge must also compare what a replacement changes
# ================================================================================================
# A stand in stat for ONE path, put ahead of the core tools on dc_run's PATH; every other path goes
# to the real stat. It reports what $FAKE_STAT says, so a case can change the answer between
# --propose and --plan, which no real file system lets a test do on demand:
#   line 1  gnu    answers -c, and takes -f as file system status, printing junk with exit 0 as GNU
#                  stat does (the Ubuntu CI runner)
#           bsd    refuses -c, as macOS stat does, and answers -f
#           none   fails both, as for a file it cannot read
#   line 2  the path it stands in for
#   line 3  dev ino birth birth_with_fraction ctime ctime_with_fraction size, where size "real"
#           reads the real file's size, so emptying it in place can be seen
fake_stat_on() {
  {
    printf '#!/bin/bash\nreal=%q\nctl=%q\n' "$DC_CORE/stat" "$FAKE_STAT"
    cat <<'STUB'
for last in "$@"; do :; done
[ "$last" = "$(sed -n 2p "$ctl")" ] || exec "$real" "$@"
shape="$(sed -n 1p "$ctl")"
read -r dev ino bw bf cw cf size <<< "$(sed -n 3p "$ctl")"
[ "$size" = real ] && size="$("$real" -c %s "$last" 2>/dev/null || "$real" -f %z "$last")"
flag="$1" out="$2"
case "$shape:$flag" in
  gnu:-c)
    out="${out//%.9W/$bf}"; out="${out//%W/$bw}"; out="${out//%.9Z/$cf}"; out="${out//%Z/$cw}"
    out="${out//%d/$dev}"; out="${out//%i/$ino}"; out="${out//%s/$size}"; printf '%s\n' "$out" ;;
  gnu:-f) printf '%s\n' "ext2/ext3 255 4096 0"; exit 0 ;;
  bsd:-c) echo "stat: illegal option -- c" >&2; exit 1 ;;
  bsd:-f)
    out="${out//%FB/$bf}"; out="${out//%B/$bw}"; out="${out//%Fc/$cf}"; out="${out//%c/$cw}"
    out="${out//%d/$dev}"; out="${out//%i/$ino}"; out="${out//%z/$size}"; printf '%s\n' "$out" ;;
  *) echo "stat: cannot stat '$last'" >&2; exit 1 ;;
esac
STUB
  } > "$DC_STUBS/stat"
  chmod +x "$DC_STUBS/stat"
}
fake_says() { printf '%s\n%s\n%s\n' "$1" "$H/w/reused" "$2" > "$FAKE_STAT"; } # <shape> <line 3>
# Proposes $H/w/reused with stat reporting <at propose>, then runs the plan with it reporting
# <at plan>, in [shape at plan] when given. Leaves OUT_TEXT and RC from the plan run.
reuse_case() { # <shape> <at propose> <at plan> [method] [shape at plan]
  fresh
  printf 'xy\n' > "$H/w/reused"
  fake_says "$1" "$2"
  fake_stat_on
  run --propose "${4:-trash}" "$H/w/reused"
  PROPOSE_TEXT="$OUT_TEXT"
  REUSE_PLAN="$(sed -n 's/^Plan: \([^ ]*\) .*/\1/p' <<< "$OUT_TEXT")"
  [ -n "$REUSE_PLAN" ] || { OUT_TEXT="no plan was written: $PROPOSE_TEXT"; RC=99; return; }
  fake_says "${5:-$1}" "$3"
  run --plan "$REUSE_PLAN"
}
T1="1793000000 1793000000.100000000"
T2="1793000500 1793000500.200000000"

# The case that failed on CI: same device and inode, a different birth time. Both stat shapes.
reuse_case gnu "64768 777 $T1 $T1 3" "64768 777 $T2 $T1 3"
check "with GNU stat, a file with the same device and inode but a new birth time is skipped as not the item proposed" \
  "$(has "$OUT_TEXT" "it is not the item that was proposed")"
check "and it is still there" "$(there "$H/w/reused")"
check "and trash never ran on it" "$(eq "$(calls_of trash)" "")"
reuse_case bsd "16777231 777 $T1 $T1 3" "16777231 777 $T2 $T1 3"
check "with macOS stat, a file with the same device and inode but a new birth time is skipped as not the item proposed" \
  "$(has "$OUT_TEXT" "it is not the item that was proposed")"
check "and it is still there" "$(there "$H/w/reused")"

# Where the file system keeps no birth time, GNU stat prints 0 for it (or "-"), and ctime decides.
reuse_case gnu "64768 777 0 0 $T1 3" "64768 777 0 0 $T2 3"
check "with no birth time recorded (0), the same device and inode with a new ctime is skipped" \
  "$(has "$OUT_TEXT" "it is not the item that was proposed, or it was changed since")"
check "and it is still there" "$(there "$H/w/reused")"
reuse_case gnu "64768 777 - - $T1 3" "64768 777 - - $T2 3"
check "with no birth time recorded (-), the same device and inode with a new ctime is skipped" \
  "$(has "$OUT_TEXT" "it is not the item that was proposed, or it was changed since")"
check "and it is still there" "$(there "$H/w/reused")"

# Size: the same device, inode and birth time but a different size is not what Dan was shown.
reuse_case gnu "64768 777 $T1 $T1 3" "64768 777 $T1 $T1 9"
check "a file whose size changed since it was proposed is skipped, saying so" "$(has "$OUT_TEXT" "it changed size since it was proposed (3 bytes, now 9)")"
check "and it is still there" "$(there "$H/w/reused")"

# The controls: an unchanged file still goes, so the cases above are not a judge refusing everything.
reuse_case gnu "64768 777 $T1 $T1 3" "64768 777 $T1 $T1 3"
check "with GNU stat, an unchanged file is trashed (exit $RC)" "$(gone "$H/w/reused")"
reuse_case bsd "16777231 777 $T1 $T1 3" "16777231 777 $T1 $T1 3"
check "with macOS stat, an unchanged file is trashed (exit $RC)" "$(gone "$H/w/reused")"
reuse_case gnu "64768 777 0 0 $T1 3" "64768 777 0 0 $T1 3"
check "with no birth time, an unchanged file is trashed (exit $RC)" "$(gone "$H/w/reused")"
reuse_case gnu "64768 777 $T1 $T1 3" "64768 777 $T1 $T2 3"
check "where a birth time is recorded, a ctime that alone moved (a permissions change) does not stop it (exit $RC)" "$(gone "$H/w/reused")"

# truncate is for a log a process is writing to, so its size growing is expected, not a replacement.
fresh
printf 'xy\n' > "$H/w/reused"
fake_says gnu "64768 777 $T1 $T1 real"
fake_stat_on
run --propose truncate "$H/w/reused"
REUSE_PLAN="$(sed -n 's/^Plan: \([^ ]*\) .*/\1/p' <<< "$OUT_TEXT")"
printf 'more lines written since\n' >> "$H/w/reused"
run --plan "$REUSE_PLAN"
check "a log proposed for truncating that grew since is still emptied (exit $RC)" "$(has "$OUT_TEXT" "truncated")"
check "and it is empty" "$(eq "$(wc -c < "$H/w/reused" | tr -d ' ')" 0)"

# A stat that cannot read the file: unmeasured at removal, refused at proposal.
reuse_case gnu "64768 777 $T1 $T1 3" "64768 777 $T1 $T1 3" trash none
check "an identity that cannot be read now is skipped as unmeasured, never as a match" "$(has "$OUT_TEXT" "unmeasured: its identity could not be read now")"
check "and it is still there" "$(there "$H/w/reused")"
fresh
printf 'xy\n' > "$H/w/reused"
fake_says none "0 0 0 0 0 0 0"
fake_stat_on
run --propose trash "$H/w/reused"
check "--propose refuses a path whose identity cannot be read, since nothing could check it again before removal" \
  "$(has "$OUT_TEXT" "refused  $H/w/reused: its identity could not be read")"

# A record written before #1840 holds device:inode only, which a replacement can share, so it is
# never taken as a match: the item is skipped as unmeasured. Its identity here is the file's REAL
# device and inode, which the old judge accepted.
fresh
printf 'xy\n' > "$H/w/old"
old_ident="$(stat -c '%d:%i' "$H/w/old" 2>/dev/null || stat -f '%d:%i' "$H/w/old")"
item n1 named trash "$H/w/old" 3 offerable "$old_ident"
mkdir -p "$STATE/named"
record named-old 10 "$STATE/named/named-old.json"
plan "$H/plan" named-old n1
run --plan "$H/plan"
check "a record holding only device and inode (the shape before #1840) is skipped as unmeasured" \
  "$(has "$OUT_TEXT" "unmeasured: its record holds an identity in the older device and inode shape")"
check "and the file is still there" "$(there "$H/w/old")"
rm -f "$DC_STUBS/stat" "$FAKE_STAT"

# ================================================================================================
# 18. The open check is the last step before the removal (claude-config#1872, L1034): measuring
#     and judging come first, so du's whole run is no longer a window in which a file can be opened
#     after lsof said nobody had it
# ================================================================================================
fresh
printf 'x\n' > "$H/w/f1"; mkdir -p "$H/w/d2"; printf 'x\n' > "$H/w/d2/f"
item i1 fixture trash "$H/w/f1"; item i2 fixture delete "$H/w/d2"
record s1 10; plan "$H/plan" s1 i1 i2
run --plan "$H/plan"
# The order of the stubbed calls that make up each item: measure (du), judge, open check (lsof) and,
# for trash, the removal itself. delete removes with the real rm, so lsof is its last stubbed step.
order="$(awk '$1 == "du" || $1 == "judge" || $1 == "lsof" || $1 == "trash" { printf "%s%s", sep, $1; sep = " " }' "$DC_CALLS")"
check "each item is measured, then judged, then checked for being open, and the open check comes right before the removal" \
  "$(eq "$order" "du judge lsof trash du judge lsof")"
check "and both items were removed (exit $RC)" "$([ "$RC" -eq 0 ] && [ ! -e "$H/w/f1" ] && [ ! -e "$H/w/d2" ] && echo ok || echo "$OUT_TEXT")"

finish
