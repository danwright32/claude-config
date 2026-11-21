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
check "the units library writes sizes as disk-remove reports them" "$(eq "$(dcu_human 1572864)" "1.6 GB")"
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
  dc_stub pnpm
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
# How many times git was asked <question> in <folder>: a recorded call that starts with the folder
# and ends with the question, whatever dc_git put between the two (#3328). What it puts there is
# test-disk-clean-git.sh's to hold it to.
git_asked() { # <folder> <question>
  dc_calls git | awk -v p="git -C $(printf '%q' "$1") " -v s=" $2" 'index($0, p) == 1 && length($0) >= length(s) && substr($0, length($0) - length(s) + 1) == s { n++ } END { print n + 0 }'
}

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
# 4b. Claude Code's state folder, and the one folder shape in it that reaches a judge (#3235)
# ================================================================================================
# Dan, 2026-11-19, recorded on #3235: "Allow it". A folder exactly four levels under session-notes
# (session-notes/<project>/<session>/<task>/<folder>) reaches the claude-records judge, by its own
# path, as a plan item that goes to the Trash. Everything else under ~/.claude/state stays refused.
NOTES="$H/.claude/state/session-notes"
NP="$NOTES/-Users-x-proj"; NS="$NP/22222222-2222-4222-8222-222222222222"; NT="$NS/task-1"
notes_tree() {
  fresh
  mkdir -p "$NT/photos" "$NT/my shots" "$NT/deep/inner" "$NT/other" "$NS/my task" "$H/.claude/state/ai-review" \
    "$H/w/elsewhere/inner" "$H/w/real-folder"
  printf 'img\n' > "$NT/photos/a.jpg"; printf 'img\n' > "$NT/my shots/b.jpg"; printf 'x\n' > "$NT/deep/inner/c"
  printf 'x\n' > "$NT/other/d"; printf 'n\n' > "$NT/evidence.md"; printf 'n\n' > "$NS/handoff.md"
  printf 'x\n' > "$H/.claude/state/ai-review/x"; printf 'x\n' > "$H/w/elsewhere/inner/e"; printf 'x\n' > "$NS/my task/f"
}
# The pure shape rule, asked directly: what it accepts is the whole exception.
PH="$(cd -P "$H" && pwd -P)"
shape() { if dc_notes_shape "$1" "$PH" 2>/dev/null; then echo yes; else echo no; fi; }
B="$PH/.claude/state/session-notes"
check "shape: a folder four levels under session-notes is the shape" "$(eq "$(shape "$B/p/s/t/f")" yes)"
check "shape: a name holding a space is still one level" "$(eq "$(shape "$B/p/s/t/my shots")" yes)"
check "shape: session-notes itself is not" "$(eq "$(shape "$B")" no)"
check "shape: a project is not" "$(eq "$(shape "$B/p")" no)"
check "shape: a session is not" "$(eq "$(shape "$B/p/s")" no)"
check "shape: a task folder is not" "$(eq "$(shape "$B/p/s/t")" no)"
check "shape: a task folder whose name holds a space is not" "$(eq "$(shape "$B/p/s/my task")" no)"
check "shape: five levels is not" "$(eq "$(shape "$B/p/s/t/f/g")" no)"
check "shape: six levels is not" "$(eq "$(shape "$B/p/s/t/f/g/h")" no)"
check "shape: a trailing slash on a task folder does not make it four levels" "$(eq "$(shape "$B/p/s/t/")" no)"
check "shape: a trailing slash on a four level folder is refused rather than read" "$(eq "$(shape "$B/p/s/t/f/")" no)"
check "shape: an empty level does not count as one" "$(eq "$(shape "$B//s/t/f")" no)"
check "shape: an empty level in the middle does not count as one" "$(eq "$(shape "$B/p/s//f")" no)"
check "shape: a .. level is refused" "$(eq "$(shape "$B/p/s/t/..")" no)"
check "shape: a .. level in the middle is refused" "$(eq "$(shape "$B/p/../t/f")" no)"
check "shape: a . level is refused" "$(eq "$(shape "$B/p/s/./f")" no)"
check "shape: a name holding a newline is refused" "$(eq "$(shape "$B/p/s/t/a"$'\n'"b")" no)"
check "shape: a newline does not hide deeper levels" "$(eq "$(shape "$B/p/s/t"$'\n'"/f/g")" no)"
check "shape: another folder of state is not" "$(eq "$(shape "$PH/.claude/state/disk-clean/a/b/c/d")" no)"
check "shape: a sibling whose name starts the same is not" "$(eq "$(shape "$PH/.claude/state/session-notes-old/p/s/t/f")" no)"
check "shape: the same shape under another home is not" "$(eq "$(shape "$OUT/.claude/state/session-notes/p/s/t/f")" no)"

notes_tree
ln -s "$H/w/real-folder" "$NT/leaf-link"
ln -s "$H/w/elsewhere" "$NS/task-link"
ln -s "$NP" "$NOTES/proj-link"
ln -s "$NT" "$H/w/into-notes"
printf 'f\n' > "$NT/loose.txt"
# Reaches the judge: the claude-records category, going to the Trash, by its own path.
item a1 claude-records trash "$NT/photos"
item a2 claude-records trash "$NT/my shots"
# Stays refused, whatever its category says.
item r1 claude-records trash "$H/.claude/state"
item r2 claude-records trash "$NOTES"
item r3 claude-records trash "$NP"
item r4 claude-records trash "$NS"
item r5 claude-records trash "$NT"
item r6 claude-records trash "$NT/deep/inner"
item r7 claude-records trash "$H/.claude/state/ai-review"
item r8 claude-records trash "$NT/"
item r9 claude-records trash "$NS/my task"
item r10 claude-records trash "$NT/photos/.."
item r11 claude-records trash "$NT/deep/../other"
item r12 claude-records trash "$NT/leaf-link"
item r13 claude-records trash "$NS/task-link/inner"
item r14 claude-records trash "$NOTES/proj-link/${NS##*/}/task-1/other"
item r15 claude-records trash "$H/w/into-notes/other"
item r16 claude-records trash "$NS//task-1"
item r17 claude-records trash "$NT/loose.txt"
# The same four level folder under any other category, or by any way but the Trash.
item r18 fixture trash "$NT/other"
item r19 claude-records delete "$NT/other"
item r20 claude-records truncate "$NT/other"
item r21 named trash "$NT/other"
record s1 10; plan "$H/plan" s1 a1 a2 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 r13 r14 r15 r16 r17 r18 r19 r20 r21
run --plan "$H/plan"
check "notes: a four level folder reaches its judge and is moved to the Trash" "$(gone "$NT/photos")"
check "notes: and so does one whose name holds a space" "$(gone "$NT/my shots")"
check "notes: the judge was asked about exactly those two, and nothing else under state" \
  "$(eq "$(calls_of judge | sort | tr '\n' '|')" "$(printf 'judge judge %q\n' "$NT/my shots" "$NT/photos" | sort | tr '\n' '|')")"
check "notes: both went through trash, never rm" "$(eq "$(calls_of trash | wc -l | tr -d ' ')" 2)"
check "notes: an INTENT was written for each of the two" "$(eq "$(intents "$(LOGF s1)" '^a[12]$')" 2)"
check "notes: and for nothing that was refused" "$(eq "$(intents "$(LOGF s1)" '^r')" 0)"
line_of() { grep -F -- "$1" <<< "$OUT_TEXT" | awk 'NR == 1'; }
for pair in "the state folder itself|$H/.claude/state:" "session-notes itself|$NOTES:" "a project|$NP:" "a session|$NS:" "a task folder|$NT:" "a five level path|$NT/deep/inner:" \
  "another folder of state|$H/.claude/state/ai-review:" "a task folder with a trailing slash|$NT/:" "a task folder whose name holds a space|$NS/my task:" \
  "a file at four levels|$NT/loose.txt:"; do
  check "notes: ${pair%%|*} stays refused as Claude Code's own state" "$(has "$(line_of "${pair#*|}")" "never removed: it is Claude Code's own state")"
done
check "notes: a .. at the end of a four level path is refused" "$(has "$(line_of "$NT/photos/..:")" ". or .. component")"
check "notes: a .. inside a path that lands four levels down is refused" "$(has "$(line_of "$NT/deep/../other:")" ". or .. component")"
check "notes: a link at the fourth level is refused as a link" "$(has "$(line_of "$NT/leaf-link:")" "symbolic link")"
check "notes: a link at the task level, leading out of state, does not reach the judge" "$(has "$(line_of "$NS/task-link/inner:")" "never removed: it is Claude Code's own state")"
check "notes: a link at the project level, leading to another project, does not reach the judge" "$(has "$(line_of "$NOTES/proj-link/")" "never removed: it is Claude Code's own state")"
check "notes: a link from outside state into a task folder does not reach the judge" "$(has "$(line_of "$H/w/into-notes/other:")" "never removed: it is Claude Code's own state")"
check "notes: an empty level that makes a task folder read as four levels does not reach the judge" "$(has "$(line_of "$NS//task-1:")" "never removed: it is Claude Code's own state")"
check "notes: a four level folder under another category stays refused" "$(eq "$(grep -c "skipped.*$NT/other: never removed: it is Claude Code's own state" <<< "$OUT_TEXT")" 4)"
check "notes: everything refused is still there" \
  "$(for f in "$NT/deep/inner/c" "$NT/other/d" "$NT/evidence.md" "$NS/handoff.md" "$H/.claude/state/ai-review/x" "$H/w/elsewhere/inner/e" "$NS/my task/f" "$NT/loose.txt" "$H/w/real-folder"; do [ -e "$f" ] || { echo "$f is gone"; exit; }; done; echo ok)"
check "notes: and every link is still a link" "$([ -L "$NT/leaf-link" ] && [ -L "$NS/task-link" ] && [ -L "$NOTES/proj-link" ] && [ -L "$H/w/into-notes" ] && echo ok || echo "a link is gone")"
check "notes: a plan with refusals in it exits 5" "$(eq "$RC" 5)"

# --propose is how a path is removed by name, judged only by its identity: it has no keep rules and
# no 30 day floor, so the exception is never open to it.
notes_tree
run --propose trash "$NT/photos"
check "notes: --propose refuses a four level folder, since its judge is not the keep rules" "$(has "$OUT_TEXT" "refused  $NT/photos: never removed: it is Claude Code's own state")"
check "notes: and wrote no named record for it" "$([ -z "$(ls "$STATE/named" 2>/dev/null)" ] && echo ok || echo "a record was written")"
check "notes: and the folder is still there" "$(there "$NT/photos/a.jpg")"

# What the judge says still decides: the exception only lets the question be asked.
notes_tree
printf 'not offerable: the daily keep rules run does not list it\n' > "$VERDICTS/photos"
item k1 claude-records trash "$NT/photos"; record s1 10; plan "$H/plan" s1 k1
run --plan "$H/plan"
check "notes: a four level folder its judge does not offer is kept, with the judge's reason" "$(has "$OUT_TEXT" "judged again just now: not offerable: the daily keep rules run does not list it")"
check "notes: and it is still there" "$(there "$NT/photos/a.jpg")"

# A four level folder already gone is reported as gone, like any other item.
notes_tree
item g1 claude-records trash "$NT/already-gone"; record s1 10; plan "$H/plan" s1 g1
run --plan "$H/plan"
check "notes: a four level folder that is already gone is reported as gone" "$(has "$OUT_TEXT" "it was already gone")"

# Dan, 2026-11-19, recorded on #3235: "Offer when git says safe". The second shape that reaches the
# claude-records judge: a task folder (three levels under session-notes) that is itself a git
# checkout holding its own repository, a real .git folder at its top. A task folder that is not one
# stays refused here, whatever a judge would say of it.
tshape() { if dc_notes_task_shape "$1" "$PH" 2>/dev/null; then echo yes; else echo no; fi; }
check "task shape: a folder three levels under session-notes is the shape" "$(eq "$(tshape "$B/p/s/t")" yes)"
check "task shape: two levels is not" "$(eq "$(tshape "$B/p/s")" no)"
check "task shape: four levels is not" "$(eq "$(tshape "$B/p/s/t/f")" no)"
check "task shape: an empty level does not count as one" "$(eq "$(tshape "$B/p//t")" no)"
check "task shape: a .. level is refused" "$(eq "$(tshape "$B/p/s/..")" no)"
check "task shape: a trailing slash is refused rather than read" "$(eq "$(tshape "$B/p/s/t/")" no)"
check "task shape: the same shape under another home is not" "$(eq "$(tshape "$OUT/.claude/state/session-notes/p/s/t")" no)"
# git is a stub here, so the one question dc_notes_checkout asks of it (which git folder it answers
# from in a folder) is answered by the harness's stand in, which section "real git" below holds to
# what real git says. A repository is a .git holding HEAD, objects and refs, as git itself reads one.
repo_at() { mkdir -p "$1/.git/objects" "$1/.git/refs"; printf 'ref: refs/heads/main\n' > "$1/.git/HEAD"; } # <folder>
git_dir_stub() { dc_stub git "$DC_GIT_HELPER_STANDIN"'
case "$*" in "rev-parse --absolute-git-dir") '"$DC_GIT_DIR_STANDIN"' ;; esac
echo "git stub: $*" >&2; exit 98'; }
checkout_tree() {
  notes_tree
  mkdir -p "$NS/repo-task/src" "$NS/wt-task" "$NS/linked-git" "$NS/empty-git/.git" "$H/w/outside-repo/.git/worktrees/w"
  repo_at "$NS/repo-task"; repo_at "$NT/clone"; repo_at "$H/w/outside-repo"
  printf 'x\n' > "$NS/repo-task/src/a"; printf 'x\n' > "$NS/empty-git/a"
  # A worktree of the repository outside: its .git is a file naming that repository's folder for it.
  printf 'ref: refs/heads/w\n' > "$H/w/outside-repo/.git/worktrees/w/HEAD"; printf '../..\n' > "$H/w/outside-repo/.git/worktrees/w/commondir"
  printf 'gitdir: %s\n' "$H/w/outside-repo/.git/worktrees/w" > "$NS/wt-task/.git"; printf 'x\n' > "$NS/wt-task/a"
  ln -s "$H/w/outside-repo/.git" "$NS/linked-git/.git"
  ln -s "$NS/repo-task" "$NS/repo-link"
  ln -s "$NP" "$NOTES/proj-link"
  git_dir_stub
}
checkout_tree
item d1 claude-records trash "$NT"
item d10 claude-records trash "$NS/empty-git"
item d2 claude-records trash "$NS/wt-task"
item d3 claude-records trash "$NS/linked-git"
item d4 claude-records trash "$NS/repo-link"
item d5 claude-records delete "$NS/repo-task"
item d6 fixture trash "$NS/repo-task"
item d7 named trash "$NS/repo-task"
item d8 claude-records trash "$NOTES/proj-link/${NS##*/}/repo-task"
item d9 claude-records trash "$NS"
item c1 claude-records trash "$NS/repo-task"
item c2 claude-records trash "$NT/clone"
record s1 10; plan "$H/plan" s1 d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 c1 c2
run --plan "$H/plan"
check "checkout: a task folder that is a git checkout reaches its judge and is moved to the Trash" "$(gone "$NS/repo-task")"
check "checkout: git was asked which repository it answers for in that task folder" \
  "$(eq "$(git_asked "$NS/repo-task" "rev-parse --absolute-git-dir")" 1)"
check "checkout: and was asked nothing else, by the remover" "$(eq "$(calls_of git | grep -vc ' rev-parse --absolute-git-dir$')" 0)"
check "checkout: and so does a checkout four levels down, by the first shape" "$(gone "$NT/clone")"
check "checkout: the judge was asked about exactly those two" \
  "$(eq "$(calls_of judge | sort | tr '\n' '|')" "$(printf 'judge judge %q\n' "$NS/repo-task" "$NT/clone" | sort | tr '\n' '|')")"
check "checkout: both went through trash, never rm" "$(eq "$(calls_of trash | wc -l | tr -d ' ')" 2)"
check "checkout: an INTENT was written for each of the two, and for nothing refused" "$(eq "$(intents "$(LOGF s1)" '^c[12]$')|$(intents "$(LOGF s1)" '^d')" "2|0")"
for pair in "a task folder that is no checkout|$NT:" "a task folder whose .git is a file, a worktree of a repository elsewhere|$NS/wt-task:" \
  "a task folder whose .git is a link|$NS/linked-git:" "a task folder whose .git folder holds no repository|$NS/empty-git:" "a session folder|$NS:"; do
  check "checkout: ${pair%%|*} stays refused as Claude Code's own state" "$(has "$(line_of "${pair#*|}")" "never removed: it is Claude Code's own state")"
done
check "checkout: a worktree is refused for the repository git answers for there, which lies outside it" \
  "$(has "$(line_of "$NS/wt-task:")" "git answers there for a repository that lies outside it ($PH/w/outside-repo/.git/worktrees/w)")"
check "checkout: a .git that is a link is refused the same way, for the repository the link names" \
  "$(has "$(line_of "$NS/linked-git:")" "git answers there for a repository that lies outside it ($PH/w/outside-repo/.git)")"
check "checkout: a .git folder holding no repository is refused because git names none" "$(has "$(line_of "$NS/empty-git:")" "git names no repository for it (git exit 128)")"
check "checkout: a task folder with no .git is refused because git names none" "$(has "$(line_of "$NT:")" "git names no repository for it (git exit 128)")"
check "checkout: a link to a checkout task folder is refused as a link" "$(has "$(line_of "$NS/repo-link:")" "symbolic link")"
check "checkout: one reached through a link above it does not reach the judge" "$(has "$(line_of "$NOTES/proj-link/")" "never removed: it is Claude Code's own state")"
check "checkout: the same task folder under another kind, by deleting, or named, stays refused" "$(eq "$(grep -c "skipped.*$NS/repo-task: never removed: it is Claude Code's own state" <<< "$OUT_TEXT")" 3)"
check "checkout: everything refused is still there" \
  "$(for f in "$NT/evidence.md" "$NS/wt-task/a" "$NS/linked-git" "$NS/empty-git/a" "$NS/handoff.md" "$H/w/outside-repo/.git"; do [ -e "$f" ] || { echo "$f is gone"; exit; }; done; [ -L "$NS/repo-link" ] && echo ok || echo "the link is gone")"
checkout_tree
run --propose trash "$NS/repo-task"
check "checkout: --propose refuses a checkout task folder, since its judge is not git's" "$(has "$OUT_TEXT" "refused  $NS/repo-task: never removed: it is Claude Code's own state")"
check "checkout: and it is still there" "$(there "$NS/repo-task/src/a")"
# git itself failing (not installed, or refusing the folder) is a refusal, never a pass.
checkout_tree
dc_stub git 'exit 127'
item f1 claude-records trash "$NS/repo-task"; record s1 10; plan "$H/plan" s1 f1
run --plan "$H/plan"
check "checkout: when git cannot be asked, the task folder stays refused" "$(has "$(line_of "$NS/repo-task:")" "git names no repository for it (git exit 127)")"
check "checkout: and it is still there" "$(there "$NS/repo-task/src/a")"

# ---- real git: what dc_git_own_repo says of each shape, asked of the git on this machine ----
# Everything above stood in for git. Here the predicate is asked with the real one, on repositories
# real git made, all inside the harness's throwaway home: a full clone holds its own repository;
# a worktree, a submodule, a folder whose .git is a link, a bare repository, a folder whose .git
# only looks like one, and a plain folder do not. Then the harness's stand in is run on the same
# folders and must give the answer real git gave, or every stubbed case above proved nothing (L404).
fresh
if command -v git >/dev/null 2>&1; then
  RG="$PH/.claude/state/session-notes/p/s"
  rgit() { HOME="$H" GIT_CONFIG_NOSYSTEM=1 git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false -c protocol.file.allow=always -c init.defaultBranch=main "$@" </dev/null >/dev/null 2>&1; }
  mkdir -p "$RG/plain" "$RG/empty/.git" "$RG/headonly/.git" "$RG/linked"
  printf 'ref: refs/heads/main\n' > "$RG/headonly/.git/HEAD"; printf 'x\n' > "$RG/plain/a"
  rgit init "$RG/clone"; printf 'x\n' > "$RG/clone/a"; rgit -C "$RG/clone" add a; rgit -C "$RG/clone" commit -m seed
  rgit -C "$RG/clone" worktree add --detach "$RG/wt"
  rgit init "$RG/super"; printf 'x\n' > "$RG/super/a"; rgit -C "$RG/super" add a; rgit -C "$RG/super" commit -m seed
  rgit -C "$RG/super" submodule add "$RG/clone" sub
  rgit init --bare "$RG/bare"
  ln -s "$RG/clone/.git" "$RG/linked/.git"
  check "real git: the fixtures were made (a clone, a worktree of it, a submodule, a bare repository)" \
    "$([ -f "$RG/clone/.git/HEAD" ] && [ -f "$RG/wt/.git" ] && [ -f "$RG/super/sub/.git" ] && [ -f "$RG/bare/HEAD" ] && echo ok || echo "git did not make them")"
  own() { if dc_git_own_repo "$1" 2>/dev/null; then echo yes; else echo "no: $DC_GIT_WHY"; fi; }
  check "real git: a full clone holds its own repository" "$(eq "$(own "$RG/clone")" yes)"
  check "real git: and so does the repository a submodule sits in" "$(eq "$(own "$RG/super")" yes)"
  check "real git: a worktree does not, and the reason names the repository it belongs to" \
    "$(eq "$(own "$RG/wt")" "no: git answers there for a repository that lies outside it ($RG/clone/.git/worktrees/wt): it is a worktree or submodule of a repository elsewhere, or its .git is a link to one")"
  check "real git: a submodule does not" "$(has "$(own "$RG/super/sub")" "no: git answers there for a repository that lies outside it ($RG/super/.git/modules/sub)")"
  check "real git: a folder whose .git is a link to a repository does not" "$(has "$(own "$RG/linked")" "no: git answers there for a repository that lies outside it ($RG/clone/.git)")"
  # Asked through dc_git (#3328), git works with no bare repository it merely finds at a folder, so
  # one is refused as holding none, where a bare call answered for the folder itself.
  check "real git: a bare repository does not: git is asked to answer for none it merely finds" "$(eq "$(own "$RG/bare")" "no: git names no repository for it (git exit 128)")"
  check "real git: an empty .git folder only looks like one" "$(eq "$(own "$RG/empty")" "no: git names no repository for it (git exit 128)")"
  check "real git: a .git folder holding only a HEAD only looks like one" "$(eq "$(own "$RG/headonly")" "no: git names no repository for it (git exit 128)")"
  check "real git: a plain folder is none" "$(eq "$(own "$RG/plain")" "no: git names no repository for it (git exit 128)")"
  check "real git: a folder inside a clone is not the clone" "$(has "$(mkdir -p "$RG/clone/src"; own "$RG/clone/src")" "no: git answers there for a repository that lies outside it ($RG/clone/.git)")"
  check "real git: a folder that is not there is none" "$(has "$(own "$RG/absent")" "no: ")"
  check "real git: with git told to answer for another repository, a clone is refused, as the judge's own git calls would answer for that one" \
    "$(has "$(GIT_DIR="$RG/super/.git" own "$RG/clone")" "no: git answers there for a repository that lies outside it ($RG/super/.git)")"
  # The same folders, by the path as HOME writes it (a link above it on macOS), are read alike.
  check "real git: a clone named through a link above it is still its own" "$(eq "$(own "$H/.claude/state/session-notes/p/s/clone")" yes)"
  # The two shapes under session-notes, with real git: a clone task folder is the item, a worktree is not.
  ck3() { if dc_notes_checkout "$1" "$H" "$PH" 2>/dev/null; then echo yes; else echo "no: $DC_NOTES_WHY"; fi; }
  check "real git: a task folder that is a full clone is a checkout the remover takes" "$(eq "$(ck3 "$H/.claude/state/session-notes/p/s/clone")" yes)"
  check "real git: a task folder that is a worktree is not" "$(has "$(ck3 "$H/.claude/state/session-notes/p/s/wt")" "no: it is a session's task folder and not a git checkout with a repository of its own (git answers there for a repository that lies outside it")"
  check "real git: a submodule four levels down is not a task folder, so it is refused by its shape" "$(has "$(ck3 "$H/.claude/state/session-notes/p/s/super/sub")" "no: it is not a session's task folder")"
  check "real git: a task folder whose .git only looks like one is not" "$(has "$(ck3 "$H/.claude/state/session-notes/p/s/empty")" "(git names no repository for it (git exit 128))")"
  # The stand in every stubbed suite uses, against real git asked as dc_git_own_repo asks it,
  # through dc_git, folder by folder. A bare repository is among them now that both say none.
  git_dir_stub
  for d in clone super wt super/sub linked empty headonly plain bare; do
    real="$(dc_git "$RG/$d" rev-parse --absolute-git-dir 2>/dev/null </dev/null)"; real="$?|$real"
    stood="$(dc_run git -C "$RG/$d" rev-parse --absolute-git-dir 2>/dev/null)"; stood="$?|$stood"
    check "real git: the stand in answers as real git does for $d" "$(eq "$stood" "$real")"
  done
  default_stubs
  # The worktree method with real git, on a worktree whose repository names a program for each
  # setting measured to start one (#3328): git removes it, and none of those programs runs. The
  # same fixture run bare is test-disk-clean-git.sh's control, where each is seen to run.
  fresh
  RLOG="$DC_ROOT/markers.log"; : > "$RLOG"
  REAL_GIT="$(command -v git)"
  dc_marker_repo "$REAL_GIT" "$H/w/real-repo" "$RLOG" || check "real git: the marker repository was made" "dc_marker_repo failed"
  _dc_rgit "$REAL_GIT" -C "$H/w/real-repo" worktree add "$H/w/real-wt" -b side >/dev/null
  check "real git: the fixture is a worktree of a repository whose own configuration names programs" \
    "$([ -f "$H/w/real-wt/.git" ] && grep -q 'fsmonitor = ' "$H/w/real-repo/.git/config" && [ -x "$H/w/real-repo/.git/hooks/post-index-change" ] && echo ok || echo "it was not made")"
  touch -t 203001010000 "$H/w/real-wt/a.txt"; : > "$RLOG"
  dc_stub git "GIT_CONFIG_NOSYSTEM=1 exec $(printf '%q' "$REAL_GIT") \"\$@\""
  item r1 fixture worktree "$H/w/real-wt"; record s1 10; plan "$H/plan" s1 r1
  run --plan "$H/plan"
  check "real git: the remover removes a clean worktree through git" "$(eq "$RC|$([ -e "$H/w/real-wt" ] && echo there || echo gone)" "0|gone")"
  check "real git: and no program the worktree's repository names ran while it did" "$(eq "$(dc_markers_ran "$RLOG")" nothing)"
  check "real git: git was asked to remove it, with the repository's programs turned off, its filter by name" \
    "$(eq "$(dc_calls git | grep -cF -- " -c core.fsmonitor=false -c core.hooksPath=/dev/null -c safe.bareRepository=explicit -c log.showSignature=false -c filter.mark.clean= -c filter.mark.smudge= -c filter.mark.process= worktree remove ")" 1)"
  default_stubs
else
  check "real git: git is on this machine, so the predicate can be asked for real" "no git on the PATH"
fi

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
check "and reported truncated with what it freed" "$(has "$OUT_TEXT" "truncated  $H/w/run.log  (50 KB freed")"
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
dc_stub git "$DC_GIT_HELPER_STANDIN"'
case "$1 $2" in "worktree remove") ;; *) echo "git stub: $*" >&2; exit 98 ;; esac
case "$d" in */wt-dirty) echo "fatal: '"'"'$d'"'"' contains modified or untracked files, use --force to delete it" >&2; exit 128 ;; esac; /bin/rm -rf "$d"'
item w1 fixture worktree "$H/w/wt-clean"; item w2 fixture worktree "$H/w/wt-dirty"
record s1 10; plan "$H/plan" s1 w1 w2
run --plan "$H/plan"
check "a clean worktree is removed" "$(gone "$H/w/wt-clean")"
check "git was asked to remove it from inside, without --force" "$(eq "$(git_asked "$H/w/wt-clean" "worktree remove $(printf '%q' "$H/w/wt-clean")")" 1)"
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
# 11b. pnpm: its own `pnpm store prune`, on its store in ~/Library/pnpm/store, and nothing else
#      (Dan, 2026-11-19, recorded on #3235: "Offer a prune row")
# ================================================================================================
# pnpm is a stand in that records its arguments; the real one is never run. The store holds one file
# no project uses (the orphan) and one a project does. du is a stand in too: the store measures
# 5000 KiB with the orphan in it and 1000 without, so the figures say what the prune did.
PSTORE="$H/Library/pnpm/store"; PST="$PSTORE/v11"; ORPHAN="$PST/files/aa/orphan"; PRUNED="$DC_ROOT/pnpm-pruned"
PLOG_AT="$DC_ROOT/log-at-prune"
pnpm_home() { # [<what pnpm store prune does> [<what pnpm store path prints>]]
  fresh
  rm -f "$PRUNED" "$PLOG_AT"
  mkdir -p "$PST/files/aa" "$PST/files/bb" "$H/w/other-store/v11"
  printf 'unused\n' > "$ORPHAN"; printf 'used\n' > "$PST/files/bb/kept"; printf 'x\n' > "$H/w/other-store/v11/f"
  dc_stub pnpm "case \"\$*\" in
  'store path') ${2:-echo $(printf %q "$PST")} ;;
  'store prune') : > $(printf %q "$PRUNED"); /bin/cp $(printf %q "$(LOGF s1)") $(printf %q "$PLOG_AT") 2>/dev/null; ${1:-/bin/rm -f $(printf %q "$ORPHAN")} ;;
  *) echo \"unexpected pnpm \$*\" >&2; exit 99 ;;
esac"
  dc_stub du "for a in \"\$@\"; do case \"\$a\" in -*) ;; *) if [ -e $(printf %q "$ORPHAN") ]; then printf '5000\t%s\n' \"\$a\"; else printf '1000\t%s\n' \"\$a\"; fi ;; esac; done"
}
pnpm_line() { grep -F -- 'pnpm ' <<< "$OUT_TEXT" | awk 'NR == 1'; }
outcome_of() { awk -F '\t' -v id="$1" '$1 == "OUTCOME" && $4 == id { print $5 "|" $6 }' "$(LOGF s1)" 2>/dev/null; } # <id>: result|freed KiB

pnpm_home
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: the prune row runs, and the plan exits 0" "$(eq "$RC" 0)"
check "pnpm: it is reported removed, by how much smaller pnpm left its store" "$(has "$OUT_TEXT" "removed    pnpm store prune  ($(dcu_human 4000) less in pnpm's store")"
check "pnpm: pnpm was run to say where its store is and to prune it, and for nothing else" "$(eq "$(calls_of pnpm | tr '\n' '|')" "pnpm store path|pnpm store prune|")"
check "pnpm: the INTENT line names the method and its target, with the store's size before" \
  "$(eq "$(awk -F '\t' '$1 == "INTENT" && $4 == "p1" { print $5 "|" $6 "|" $7 }' "$(LOGF s1)")" "pnpm|store prune|5000")"
check "pnpm: the INTENT was in the log before pnpm store prune ran, and no OUTCOME was" \
  "$(eq "$(awk -F '\t' '$4 == "p1" { print $1 }' "$PLOG_AT" 2>/dev/null | tr '\n' '|')" "INTENT|")"
check "pnpm: the OUTCOME says removed, with what the store lost" "$(eq "$(outcome_of p1)" "removed|4000")"
check "pnpm: the record marks the row removed, so nothing quotes it again" "$(has "$(grep '"id":"p1"' "$STATE/last-scan.json")" '"state":"removed"')"
check "pnpm: the store and what a project uses are still there" "$(there "$PST/files/bb/kept")"
check "pnpm: the report counts it among what was removed" "$(has "$OUT_TEXT" "removed 1 item(s), freeing $(dcu_human 4000)")"

# A prune that found nothing: pnpm succeeded and the store is the size it was.
pnpm_home ":"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: a prune that leaves the store its size says pnpm found nothing no project uses" "$(has "$(pnpm_line)" "skipped    pnpm store prune: pnpm found nothing no project uses")"
check "pnpm: and is logged as gone, freeing nothing, never as removed" "$(eq "$(outcome_of p1)" "gone|")"
check "pnpm: and pnpm store prune did run" "$([ -e "$PRUNED" ] && echo ok || echo "it never ran")"

# A prune that failed is a failure, whatever the store measures afterwards.
pnpm_home "{ echo 'ERR_PNPM_STORE the store server is running' >&2; exit 1; }"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: a prune that exits 1 is failed, with pnpm's own first line" "$(has "$(pnpm_line)" "failed     pnpm store prune: pnpm store prune failed (exit 1: ERR_PNPM_STORE the store server is running)")"
check "pnpm: and is logged failed, and the plan exits 5" "$(eq "$RC|$(outcome_of p1)" "5|failed|")"
pnpm_home "{ /bin/rm -f $(printf %q "$ORPHAN"); exit 3; }"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: a prune that exits 3 after removing something is still failed, and says what the store lost" \
  "$(has "$(pnpm_line)" "failed     pnpm store prune: pnpm store prune failed (exit 3: no output), though its store is $(dcu_human 4000) smaller")"
check "pnpm: and nothing is counted as freed" "$(eq "$(outcome_of p1)" "failed|")"
# pnpm said it worked, and the store is bigger: nothing confirms it removed anything.
pnpm_home ":"
dc_stub du "for a in \"\$@\"; do case \"\$a\" in -*) ;; *) if [ -e $(printf %q "$PRUNED") ]; then printf '5000\t%s\n' \"\$a\"; else printf '1000\t%s\n' \"\$a\"; fi ;; esac; done"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: a store that is bigger after a prune that exited 0 is failed" "$(has "$(pnpm_line)" "failed     pnpm store prune: pnpm's store is bigger after pnpm store prune ($(dcu_human 1000) before, $(dcu_human 5000) after)")"
# The store's size could not be read: before, nothing runs; after, nothing confirms what it did.
pnpm_home
dc_stub du 'exit 1'
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: with the store's size unreadable before, it is skipped" "$(has "$(pnpm_line)" "skipped    pnpm store prune: the size of pnpm's store could not be read, so nothing could confirm what a prune did")"
check "pnpm: and pnpm store prune never ran, and no INTENT was written" "$([ ! -e "$PRUNED" ] && [ "$(intents "$(LOGF s1)" '^p1$')" = 0 ] && echo ok || echo "it ran, or an INTENT was written")"
pnpm_home
dc_stub du "[ -e $(printf %q "$PRUNED") ] && exit 1; for a in \"\$@\"; do case \"\$a\" in -*) ;; *) printf '5000\t%s\n' \"\$a\" ;; esac; done"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: with the store's size unreadable after, it is failed, never called removed" \
  "$(has "$(pnpm_line)" "failed     pnpm store prune: after pnpm store prune (exit 0) the size of its store could not be read, so nothing confirms what it did")"

# Only "store prune", only for the package caches kind: every other target is refused by name, the
# store folder itself among them, and pnpm is never run.
pnpm_home
item q1 package-caches pnpm "store prune --force"; item q2 package-caches pnpm "prune"; item q3 package-caches pnpm "$PST"
item q4 package-caches pnpm "store"; item q5 package-caches pnpm "cache delete lodash"; item q6 package-caches pnpm "store  prune"
item q7 package-caches pnpm "$PSTORE"; item q8 package-caches pnpm "store prune; rm -rf $H/w"; item q9 fixture pnpm "store prune"
item q10 package-caches pnpm ""
record s1 10; plan "$H/plan" s1 q1 q2 q3 q4 q5 q6 q7 q8 q9 q10
run --plan "$H/plan"
check "pnpm: eight targets that are not exactly store prune are each refused by name" \
  "$(eq "$(awk -F '\t' '$1 == "OUTCOME" && $5 == "skipped" && $7 == "it is not a pnpm target this tool runs (store prune, and nothing else)" { printf "%s ", $4 }' "$(LOGF s1)")" "q1 q2 q3 q4 q5 q6 q7 q8 ")"
check "pnpm: and an item with no target at all is skipped too" "$(eq "$(awk -F '\t' '$1 == "OUTCOME" && $4 == "q10" { print $5 }' "$(LOGF s1)")" skipped)"
check "pnpm: the store folder itself is refused as a pnpm target" "$(has "$(grep -F -- "pnpm $PST:" <<< "$OUT_TEXT")" "it is not a pnpm target this tool runs")"
check "pnpm: store prune under another kind is refused, since only the package caches kind's judge answers for it" \
  "$(has "$OUT_TEXT" "the pnpm method is taken only for the package-caches kind, and this item's kind is fixture")"
check "pnpm: the plan exits 5, and pnpm was never run for any of them" "$(eq "$RC|$(calls_of pnpm)" "5|")"
check "pnpm: no INTENT was written for any of them" "$(eq "$(intents "$(LOGF s1)" '^q')" 0)"
check "pnpm: the store is whole" "$([ -e "$ORPHAN" ] && [ -e "$PST/files/bb/kept" ] && echo ok || echo "something in the store is gone")"
# The store folder asked for as a path, by deleting it or moving it to the Trash, is its judge's to
# refuse (categories/package-caches.sh never offers it; test-disk-clean-categories.sh runs that judge).
pnpm_home
printf 'not offerable: pnpm%ss store\n' "'" > "$VERDICTS/v11"
item r1 package-caches delete "$PST"; item r2 package-caches trash "$PST"; record s1 10; plan "$H/plan" s1 r1 r2
run --plan "$H/plan"
check "pnpm: the store folder is not deleted or trashed when its judge keeps it" "$(eq "$(grep -c "judged again just now: not offerable: pnpm's store" <<< "$OUT_TEXT")|$([ -e "$ORPHAN" ] && echo there)" "2|there")"

# No pnpm on the PATH.
pnpm_home
rm -f "$DC_STUBS/pnpm"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: with no pnpm on the PATH it is skipped, saying so" "$(has "$(pnpm_line)" "skipped    pnpm store prune: pnpm is not on the PATH, so its store cannot be pruned")"
dc_stub pnpm

# The judge is asked again just before, and its refusal stops the prune.
pnpm_home
printf 'not offerable: changed within 30 days (files/aa/new)\n' > "$VERDICTS/store prune"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: a row its judge no longer offers is skipped with the judge's reason" "$(has "$(pnpm_line)" "judged again just now: not offerable: changed within 30 days (files/aa/new)")"
check "pnpm: the judge was asked about store prune" "$(has "$(calls_of judge)" "$(printf 'judge judge %q' "store prune")")"
check "pnpm: and pnpm store prune never ran" "$([ ! -e "$PRUNED" ] && echo ok || echo "it ran")"

# pnpm's store has to be a real folder directly inside ~/Library/pnpm/store, by pnpm's own answer.
pnpm_home "" "echo $(printf %q "$H/w/other-store/v11")"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: a store pnpm says is somewhere else is not pruned" \
  "$(has "$(pnpm_line)" "pnpm says its store is $H/w/other-store/v11, which is not a folder directly inside ~/Library/pnpm/store, the only store this tool prunes")"
check "pnpm: and pnpm store prune never ran" "$([ ! -e "$PRUNED" ] && echo ok || echo "it ran")"
pnpm_home "" "echo $(printf %q "$PSTORE/v12")"
ln -s "$H/w/other-store/v11" "$PSTORE/v12"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: a store that is a link to somewhere else is not pruned" "$(has "$(pnpm_line)" "symbolic link")"
check "pnpm: and pnpm store prune never ran" "$([ ! -e "$PRUNED" ] && echo ok || echo "it ran")"
pnpm_home "" "echo $(printf %q "$PSTORE/v12")//"
ln -s "$H/w/other-store/v11" "$PSTORE/v12"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: nor is one named with a trailing slash, which would otherwise be followed" "$(has "$(pnpm_line)" "symbolic link")"
check "pnpm: and pnpm store prune never ran" "$([ ! -e "$PRUNED" ] && echo ok || echo "it ran")"
pnpm_home "" "echo $(printf %q "$PSTORE/v99")"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: a store pnpm names that is not there is skipped as nothing to prune" "$(has "$(pnpm_line)" "skipped    pnpm store prune: pnpm's store ($PSTORE/v99) is not there, so there is nothing to prune")"
pnpm_home "" "echo $(printf %q "$PSTORE")"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: the folder that holds the stores is not itself a store to prune" "$(has "$(pnpm_line)" "which is not a folder directly inside ~/Library/pnpm/store")"
pnpm_home "" "{ echo 'ERR_PNPM no config' >&2; exit 1; }"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: when pnpm cannot say where its store is, it is skipped" "$(has "$(pnpm_line)" "skipped    pnpm store prune: pnpm could not say where its store is (pnpm store path exit 1)")"
check "pnpm: and pnpm store prune never ran" "$([ ! -e "$PRUNED" ] && echo ok || echo "it ran")"
pnpm_home "" "printf '%s\n' relative/store"
item p1 package-caches pnpm "store prune"; record s1 10; plan "$H/plan" s1 p1
run --plan "$H/plan"
check "pnpm: an answer that is not one absolute path is refused" "$(has "$(pnpm_line)" "skipped    pnpm store prune: ")"
check "pnpm: and pnpm store prune never ran" "$([ ! -e "$PRUNED" ] && echo ok || echo "it ran")"

# A killed run that was pruning: nothing here can tell how far pnpm got, so the next run says that.
fresh
printf 'x\n' > "$H/w/z1"; item z1 fixture delete "$H/w/z1"; record s1 10; plan "$H/plan" s1 z1
mkdir -p "$STATE/removals"; printf 'INTENT\t%s\t1-1\tpk\tpnpm\tstore prune\t5000\n' "$NOW" > "$(LOGF s1)"
run --plan "$H/plan"
check "pnpm: an interrupted prune is reported as not checked, never as a path still there" \
  "$(has "$OUT_TEXT" "stopped partway while running pnpm store prune; whether it finished is not checked here")"
check "pnpm: and its INTENT is settled as failed in the log" "$(eq "$(awk -F '\t' '$1 == "OUTCOME" && $4 == "pk" { print $5 }' "$(LOGF s1)")" failed)"
# --propose, which names paths, never takes it.
fresh
run --propose pnpm "store prune"
check "pnpm: --propose refuses the pnpm method with exit 2" "$(eq "$RC" 2)"
check "pnpm: and pnpm was never run" "$(eq "$(calls_of pnpm)" "")"

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
check "an offered size is in words by the one size rule, dcu_human (12 KiB)" "$(has "$OUT_TEXT" "offered  $H/Downloads/old-installer  ($(dcu_human 12), to trash)")"
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
# That the identity and size readers ask GNU's -c before BSD's -f is held, for this file and every
# other disk-clean script and test, by skills/disk-clean/test-disk-clean-stat-order.sh (#1874).
run --propose shred "$H/w/swap"
check "--propose with a method it does not offer is refused with exit 2" "$(eq "$RC" 2)"
run --propose truncate "$H/Downloads"
check "--propose truncate of a folder refuses it" "$(has "$OUT_TEXT" "refused")"

# Each size branch of measure, against dcu_human: under a MB, under a GB in decimal MB (1000 KiB is
# 1 MB, never 1000 KB), and past a GB.
mkdir -p "$H/Downloads/sized"; printf 'x\n' > "$H/Downloads/sized/f"
for sz in 999 1000 976562 1048576; do
  dc_stub du "for a in \"\$@\"; do case \"\$a\" in -*) ;; *) printf \"$sz\\t%s\\n\" \"\$a\" ;; esac; done"
  run --propose trash "$H/Downloads/sized"
  check "an offered size of $sz KiB reads as dcu_human writes it" "$(has "$OUT_TEXT" "offered  $H/Downloads/sized  ($(dcu_human "$sz"), to trash)")"
done
dc_stub du 'for a in "$@"; do case "$a" in -*) ;; *) printf "12\t%s\n" "$a" ;; esac; done'

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
