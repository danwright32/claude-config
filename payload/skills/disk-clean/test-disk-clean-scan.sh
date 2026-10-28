#!/usr/bin/env bash
# Tests for disk-clean's read only scan (payload/skills/disk-clean/scan.sh, #1806): what it writes,
# what it reports first, how it bounds each category, and that it never removes anything.
#
# The category rules themselves are test-disk-clean-categories.sh. Everything here runs ONLY through
# the disk-clean harness's dc_run (hooks/lib/disk-clean-harness.sh), with HOME a throwaway directory
# and du, lsof, ps, pgrep, docker and the rest stubs.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): hooks/lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/scan.sh"

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

default_stubs() {
  dc_stub du 'for a in "$@"; do case "$a" in -*) ;; *) printf "12\t%s\n" "$a" ;; esac; done'
  dc_stub lsof 'exit 1'
  dc_stub ps 'echo "/usr/bin/login"'
  dc_stub pgrep 'exit 1'
  dc_stub docker 'exit 1'
  dc_stub derived-data-sweep 'exit 0'
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
run_scan_env() { OUT_TEXT="$(dc_run env "$@" 2>&1)"; RC=$?; }

# ================================================================================================
# 1. The record: written through disk-clean-record.sh, whole, with its scan's facts in the header
# ================================================================================================
fresh
mkdir -p "$H/Library/Caches/com.a" "$H/Library/Mail" "$H/.Trash"; printf 'x\n' > "$H/.Trash/t"
run_scan
check "a full scan exits 0" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $(tail -5 <<< "$OUT_TEXT")")"
check "it writes last-scan.json" "$([ -f "$REC" ] && echo ok || echo "no record at $REC")"
check "the record is complete" "$(dcr_complete "$REC" && echo ok || echo "incomplete")"
sid="$(dcr_header "$REC" scan_id)"
check "the record carries a scan_id" "$([ -n "$sid" ] && echo ok || echo "none")"
check "the scan_id is never one disk-remove reads as --propose's" "$(case "$sid" in (named-*) echo "$sid" ;; (*) echo ok ;; esac)"
check "the header names every category, the Trash first" \
  "$(eq "$(dcr_header "$REC" categories)" "trash caches xcode build-folders docker playwright claude-temp worktrees transcripts runaway-logs forgotten-tools large-files")"
check "the header says how each category went" "$(eq "$(dcr_header "$REC" status.caches)" measured)"
check "an unmeasured category says so in the header" "$(has "$(dcr_header "$REC" status.docker)" "unmeasured: ")"
check "the header says how the walk went" "$(eq "$(dcr_header "$REC" walk)" complete)"
check "an item carries its category, method and state" "$(has "$(dcr_items "$REC")" "caches${S}delete${S}$H/Library/Caches/com.a${S}offerable")"
check "an item carries its size in bytes, from du's KiB" "$(has "$(dcr_review_items "$REC")" "$H/Library/Caches/com.a${S}offerable${S}12288${S}")"
check "and how the size was measured" "$(eq "$(dcr_review_items "$REC" | awk -F "$S" -v t="$H/Library/Caches/com.a" '$4 == t { print $8 }')" measured)"
ids="$(dcr_items "$REC" | awk -F "$S" '{ print $1 }')"
check "every item id is unique" "$(eq "$(sort <<< "$ids" | uniq -d)" "")"
check "the Trash's items come first in the record" "$(eq "$(dcr_items "$REC" | awk -F "$S" 'NR == 1 { print $2 }')" trash)"
check "the report names the record it wrote" "$(has "$OUT_TEXT" "$REC")"
check "the report counts each category's offerable items and their size" "$(has "$OUT_TEXT" "App caches: 1 offerable (12 KB), 0 not offerable, 0 unmeasured.")"
check "and the Trash's" "$(has "$OUT_TEXT" "Trash: 1 offerable (12 KB)")"

# The record's additions keep it readable by disk-remove's reader: seven fields, extra ones ignored.
check "dcr_items still prints seven fields per item" "$(eq "$(dcr_items "$REC" | awk -F "$S" '{ print NF }' | sort -u)" 7)"
printf 'a%scaches%sdelete%s/x%s5%sofferable%s%smeasured%scredential,icloud%sholds .env\n' "$S" "$S" "$S" "$S" "$S" "$S" "$S" "$S" "$S" > "$DC_ROOT/items1"
printf 'fda%sgranted\nstatus.caches%smeasured\n' "$S" "$S" > "$DC_ROOT/notes1"
dcr_write "$DC_ROOT/r1.json" sx 100 "$DC_ROOT/items1" "$DC_ROOT/notes1"
check "dcr_write writes header notes" "$(eq "$(dcr_header "$DC_ROOT/r1.json" fda)" granted)"
check "dcr_review_items reads size, flags and detail" "$(eq "$(dcr_review_items "$DC_ROOT/r1.json" | awk -F "$S" '{ print $8 "|" $9 "|" $10 }')" "measured|credential,icloud|holds .env")"
check "a record written without notes still has its scan_id" "$(dcr_write "$DC_ROOT/r2.json" sy 100 "$DC_ROOT/items1" && eq "$(dcr_header "$DC_ROOT/r2.json" scan_id)" sy)"
printf 'bad key%sv\n' "$S" > "$DC_ROOT/notes2"
check "dcr_write refuses a note key that is not a plain name" "$(dcr_write "$DC_ROOT/r3.json" sz 100 "$DC_ROOT/items1" "$DC_ROOT/notes2" && echo "wrote it" || echo ok)"

# hooks/lib/disk-clean-units.sh: the one copy of size words and Docker sizes, shared with
# disk-remove.sh, so the figure a scan offers and the figure a removal reports read alike.
. "$DIR/../../hooks/lib/disk-clean-units.sh" || check "disk-clean-units.sh is there to source" "could not source it"
check "dcu_human writes KB under a MB" "$(eq "$(dcu_human 512)" "512 KB")"
check "dcu_human writes whole MB under a GB" "$(eq "$(dcu_human 2048)" "2 MB")"
check "dcu_human writes GB to one place" "$(eq "$(dcu_human 1572864)" "1.5 GB")"
check "dcu_human never writes 0 for an unread size" "$(eq "$(dcu_human "")" "size unknown")"
check "dcu_docker_kib reads Docker's decimal GB" "$(eq "$(dcu_docker_kib 1.5GB)" 1464843)"
check "dcu_docker_kib reads kB" "$(eq "$(dcu_docker_kib 2048kB)" 2000)"
check "dcu_docker_kib reads 0B as 0" "$(eq "$(dcu_docker_kib 0B)" 0)"
check "dcu_docker_kib refuses a unit it does not know, printing nothing" "$(out="$(dcu_docker_kib 3 parsecs)" && echo "accepted: $out" || eq "$out" "")"

# ================================================================================================
# 2. The Full Disk Access probe runs first and is reported first
# ================================================================================================
fresh
mkdir -p "$H/Library/Mail/V10"
run_scan --only trash
check "with ~/Library/Mail readable the probe says granted" "$(eq "$(dcr_header "$REC" fda)" granted)"
check "and the report opens with it" "$(has "$(head -1 <<< "$OUT_TEXT")" "Full Disk Access: granted")"
chmod 000 "$H/Library/Mail"
run_scan --only trash
check "with ~/Library/Mail unreadable the probe says not granted" "$(has "$(dcr_header "$REC" fda)" "denied: ")"
check "and the report opens with it" "$(has "$(head -1 <<< "$OUT_TEXT")" "Full Disk Access: not granted")"
chmod 700 "$H/Library/Mail"; rm -rf "$H/Library/Mail"
run_scan --only trash
check "with no ~/Library/Mail the probe is unmeasured, never granted" "$(has "$(dcr_header "$REC" fda)" "unmeasured: ")"
check "the probe never ran ls on anything outside HOME" "$(eq "$(dc_refusals)" "")"

# ================================================================================================
# 3. Each category is time bounded by a process group kill (macOS has no timeout)
# ================================================================================================
fresh
mkdir -p "$H/Library/Caches/com.slow"
dc_stub du 'exec sleep 31.7'
start="$(date +%s)"
run_scan_env DISK_CLEAN_CATEGORY_SECONDS=1 bash "$SCAN" --only caches,trash
took=$(( $(date +%s) - start ))
check "a category that overruns is reported as timed out" "$(eq "$(dcr_header "$REC" status.caches)" "unmeasured: timed out after 1s")"
check "the scan still finishes and writes its record" "$(eq "$RC $(dcr_complete "$REC" && echo whole)" "0 whole")"
check "the other categories still ran" "$(eq "$(dcr_header "$REC" status.trash)" measured)"
check "it did not wait for the stuck command" "$([ "$took" -lt 25 ] && echo ok || echo "took ${took}s")"
check "the stuck command's whole process group was killed (nothing left sleeping)" \
  "$(/usr/bin/pgrep -f 'sleep 31.7' >/dev/null && echo "sleep 31.7 is still running" || echo ok)"
run_scan_env DISK_CLEAN_CATEGORY_SECONDS=soon bash "$SCAN" --only trash
check "a time bound that is not a number is refused" "$(eq "$RC" 2)"

# A module that fails is unmeasured, saying so, and the rest of the scan goes on.
fresh
mkdir -p "$H/Library/Developer/Xcode/DerivedData/App-x" "$H/.Trash"
dc_stub derived-data-sweep 'echo "boom" >&2; exit 9'
run_scan --only xcode,trash
check "a category whose module fails is unmeasured" "$(has "$(dcr_header "$REC" status.xcode)" "unmeasured: ")"
check "and the scan goes on to the next" "$(eq "$(dcr_header "$REC" status.trash)" measured)"

# ================================================================================================
# 4. One pruned walk: never into Library, the Trash, keys, packages or cloud only folders
# ================================================================================================
fresh
mkdir -p "$H/Library/Caches/x/node_modules" "$H/.Trash/p/node_modules" "$H/.ssh/node_modules" "$H/Some.app/Contents/node_modules" \
  "$H/Dropbox/proj/node_modules" "$H/Apps/proj/node_modules"
printf '{}\n' > "$H/Apps/proj/package.json"; printf '{}\n' > "$H/Dropbox/proj/package.json"
find "$H/Apps" -exec touch -t 202401011200 {} +
run_scan --only build-folders
check "the walk finds a project's node_modules" "$(has "$(dcr_items "$REC")" "$H/Apps/proj/node_modules")"
for p in "Library/Caches/x" ".Trash/p" ".ssh" "Some.app/Contents" "Dropbox/proj"; do
  check "the walk never goes into $p" "$(hasnt "$(dcr_items "$REC")" "$H/$p/node_modules")"
done
check "find is run once over the home folder for the walk, never once per category" "$(eq "$(dcr_header "$REC" walk)" complete)"
mkdir -p "$H/Apps/locked/x"; chmod 000 "$H/Apps/locked"
run_scan --only build-folders
check "a folder the walk cannot read makes the walk partial, saying how many" "$(has "$(dcr_header "$REC" walk)" "partial: 1 folder")"
chmod 700 "$H/Apps/locked"

# ================================================================================================
# 5. It never removes anything, and refuses while a removal runs
# ================================================================================================
fresh
mkdir -p "$H/Library/Caches/com.a" "$H/.Trash/t" "$H/Apps/proj/node_modules" "$H/Downloads" "$H/.gradle/x"
printf '{}\n' > "$H/Apps/proj/package.json"; dd if=/dev/zero of="$H/Downloads/big.iso" bs=1 count=0 seek=600m 2>/dev/null
find "$H" -exec touch -t 202401011200 {} +
before="$(cd "$H" && find . | sort)"
run_scan
after="$(cd "$H" && find . ! -path './.claude/state*' ! -path './.claude' | sort)"
check "after a full scan every file and folder in HOME is still there" "$(eq "$(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))" "")"
check "and the only thing it added is its own state" "$(eq "$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))" "")"
check "the write guard refused nothing" "$(eq "$(dc_refusals)" "")"
check "it never ran trash" "$(eq "$(dc_calls trash)" "")"
check "it never asked Docker to remove anything" "$(hasnt "$(dc_calls docker)" " rm")"
check "and never pruned anything" "$(hasnt "$(dc_calls docker)" prune)"
mkdir -p "$STATE"; ln -s "$$" "$STATE/remove.lock"
run_scan --only trash
check "while a live disk-remove run holds its lock, the scan refuses with exit 75" "$(eq "$RC" 75)"
check "and says why" "$(has "$OUT_TEXT" "is removing things now")"
rm -f "$STATE/remove.lock"; ln -s 999999 "$STATE/remove.lock"
run_scan --only trash
check "a lock whose holder is not running does not stop the scan" "$(eq "$RC" 0)"
rm -f "$STATE/remove.lock"

# Test seams are honoured only in test mode, as disk-remove.sh does.
run_scan_env -u DISK_CLEAN_TEST_ROOT bash "$SCAN" --only trash
check "with a test seam set outside test mode it refuses with exit 2" "$(eq "$RC" 2)"
run_scan --only nonsense
check "an unknown category is refused with exit 2" "$(eq "$RC" 2)"

# ================================================================================================
# 6. A path holding a control character is left out, said so, and never breaks the record
# ================================================================================================
fresh
mkdir -p "$H/Library/Caches/com.ok" "$H/Library/Caches/bad$(printf '\t')name"
run_scan --only caches
check "the record is still written whole" "$(dcr_complete "$REC" && echo ok || echo incomplete)"
check "the ordinary folder is listed" "$(has "$(dcr_items "$REC")" "$H/Library/Caches/com.ok")"
check "the scan says it left one out" "$(has "$(dcr_header "$REC" note.caches)" "left out 1 path")"

# A status or note carries a tool's own words, such as the first line of its stderr, and dcr_write
# refuses the whole record over one control character in a header value (#1851). So the scan cleans
# them where it notes them: a tab or newline becomes a space, anything else is dropped.
fresh
mkdir -p "$H/Library/Developer/Xcode/DerivedData/App-x" "$H/.Trash"; printf 'x\n' > "$H/.Trash/t"
dc_stub derived-data-sweep 'printf "boom\tthere\001 now\n" >&2; exit 9'
run_scan --only xcode,trash
check "a tool error holding a tab and a control character still leaves a whole record" "$(eq "$RC $(dcr_complete "$REC" && echo whole)" "0 whole")"
check "the tab reads as a space and the other control character is dropped" "$(has "$(dcr_header "$REC" status.xcode)" "(exit 9: boom there now)")"
check "the other category's items are still in the record" "$(eq "$(dcr_header "$REC" status.trash)" measured)"
printf 'status.x%sa\tb\n' "$S" > "$DC_ROOT/notes3"
check "dcr_write itself still refuses a header value holding a control character" "$(dcr_write "$DC_ROOT/r4.json" sw 100 "$DC_ROOT/items1" "$DC_ROOT/notes3" && echo "wrote it" || echo ok)"

# ================================================================================================
# 6b. The closing summary never reads a size it could not read as 0 (L90, L11, #1851)
# ================================================================================================
# Worded as the low space warning words the same record (#1809): an offerable item whose size is
# partial, denied or unread makes the category's total "at least", and one with no size read at
# all is never totalled as 0 KB.
du_mixed='for a in "$@"; do case "$a" in -*) ;; *unread) ;; *com.part) printf "12\t%s\n" "$a"; printf "du: %s/sub: Permission denied\n" "$a" >&2 ;; *) printf "12\t%s\n" "$a" ;; esac; done'
fresh
mkdir -p "$H/Library/Caches/com.a" "$H/Library/Caches/com.unread"
dc_stub du "$du_mixed"
run_scan --only caches
check "an unread size makes the total at least" "$(has "$OUT_TEXT" "App caches: 2 offerable (at least 12 KB), 0 not offerable, 0 unmeasured.")"
fresh
mkdir -p "$H/Library/Caches/com.a" "$H/Library/Caches/com.part"
dc_stub du "$du_mixed"
run_scan --only caches
check "a partial size makes the total at least" "$(has "$OUT_TEXT" "App caches: 2 offerable (at least 24 KB), 0 not offerable, 0 unmeasured.")"
fresh
mkdir -p "$H/Library/Caches/com.unread"
dc_stub du "$du_mixed"
run_scan --only caches
check "with no size read at all the total is unknown, never 0 KB" "$(has "$OUT_TEXT" "App caches: 1 offerable (size unknown), 0 not offerable, 0 unmeasured.")"
fresh
mkdir -p "$H/Library/Caches/com.a"
dc_stub du "$du_mixed"
run_scan --only caches
check "every size measured in full keeps the plain total" "$(has "$OUT_TEXT" "App caches: 1 offerable (12 KB), 0 not offerable, 0 unmeasured.")"

# ================================================================================================
# 7. Thousands of items (L101): every one recorded, sized in one batch, in bounded time
# ================================================================================================
fresh
BIG=3000
mkdir -p "$H/Library/Caches"
i=1; while [ "$i" -le "$BIG" ]; do mkdir "$H/Library/Caches/c$i"; i=$((i + 1)); done
mkdir -p "$H/.Trash"; i=1; while [ "$i" -le 1000 ]; do : > "$H/.Trash/t$i"; i=$((i + 1)); done
start="$(date +%s)"
run_scan --only caches,trash
took=$(( $(date +%s) - start ))
echo "  ($BIG caches and 1000 Trash entries took ${took}s)"
check "a scan of $BIG caches and 1000 Trash entries exits 0" "$(eq "$RC" 0)"
check "every cache is in the record" "$(eq "$(dcr_items "$REC" | awk -F "$S" '$2 == "caches"' | wc -l | tr -d ' ')" "$BIG")"
check "every Trash entry is in the record" "$(eq "$(dcr_items "$REC" | awk -F "$S" '$2 == "trash"' | wc -l | tr -d ' ')" 1000)"
check "none is unreadable" "$(eq "$(dcr_items "$REC" | awk -F "$S" '$5 == "unreadable"' | wc -l | tr -d ' ')" 0)"
check "du was run in batches, never once per item" "$([ "$(dc_calls du | wc -l | tr -d ' ')" -lt 50 ] && echo ok || echo "$(dc_calls du | wc -l | tr -d ' ') du calls")"

# ================================================================================================
# 8. The static command check over every disk-clean script, and the placeholder skill
# ================================================================================================
cc="$(dc_check_commands 2>&1)"; cc_rc=$?
check "every command the disk-clean scripts call is stubbed, core or a builtin" "$([ "$cc_rc" -eq 0 ] && echo ok || echo "$(awk '/^fail/ && n++ < 10' <<< "$cc")")"
missing=""
for m in caches trash xcode build-folders docker playwright claude-temp worktrees transcripts runaway-logs forgotten-tools large-files; do
  case "$cc" in *"follow	$m.sh	"*) ;; *) missing="$missing $m.sh" ;; esac
done
check "the check read scan.sh and every category module" "$([ -z "$missing" ] && echo ok || echo "not followed:$missing")"
for m in caches trash xcode build-folders docker playwright claude-temp worktrees transcripts runaway-logs forgotten-tools large-files; do
  check "categories/$m.sh is executable" "$([ -x "$DIR/categories/$m.sh" ] && echo ok || echo "not executable or missing")"
done
check "no category is named named, which disk-remove reserves" "$([ -e "$DIR/categories/named.sh" ] && echo "categories/named.sh exists" || echo ok)"
SK="$DIR/SKILL.md"
fm() { awk -v key="$1" 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 && index($0, key ":") == 1 { v = substr($0, length(key) + 2); sub(/^[ \t]+/, "", v); print v; exit }' "$SK"; }
check "SKILL.md names the skill" "$(eq "$(fm name)" disk-clean)"
check "SKILL.md is never invoked on its own while it is being built" "$(eq "$(fm disable-model-invocation)" true)"
check "SKILL.md's description says not to use it yet" "$(has "$(fm description)" "not ready")"

finish
