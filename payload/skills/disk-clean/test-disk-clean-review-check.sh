#!/usr/bin/env bash
# Tests for the half of disk-clean's review page (claude-config#1807) that draws nothing:
# review-lib.sh, which writes the nonce a review page carries and clears the clipboard before one
# opens, and review-check.sh, which takes the selection Dan copied from that page and either refuses
# it, saying why, or writes the plan disk-remove.sh runs.
#
# Everything runs ONLY through the disk-clean harness's dc_run (hooks/lib/disk-clean-harness.sh),
# with HOME a throwaway directory and pbcopy a stub, so no test ever touches the real clipboard.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): hooks/lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SH="$DIR/review-lib.sh"
CHECK_SH="$DIR/review-check.sh"

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
has() { grep -qF -- "$2" <<< "$1" && echo ok || echo "'$2' not in: $(head -c 600 <<< "$1")"; }
hasnt() { grep -qF -- "$2" <<< "$1" && echo "'$2' should not be in it" || echo ok; }

. "$DIR/../../hooks/lib/disk-clean-harness.sh" || { check "the harness is there to source" "could not source it"; finish; }
. "$DIR/../../hooks/lib/disk-clean-record.sh" || { check "the record library is there to source" "could not source it"; finish; }
check "review-lib.sh is there to source" "$([ -f "$LIB_SH" ] && echo ok || echo "missing: $LIB_SH")"
check "review-check.sh is there to run" "$([ -f "$CHECK_SH" ] && echo ok || echo "missing: $CHECK_SH")"
dc_setup || { check "the harness sets up" "dc_setup failed"; finish; }

H="$DC_HOME"
STATE="$H/.claude/state/disk-clean"
REC="$STATE/last-scan.json"
OUT="$H/scratch/review"
NONCE="$OUT/disk-clean-review.nonce"
PLAN="$H/plan.txt"
S=$'\037'
SID="scan-1761600000-4242"

# One item line for dcr_write: id category method target bytes state identity size flags detail.
item() { printf '%s\n' "$1$S$2$S$3$S$4$S$5$S$6$S$7$S$8$S$9$S${10}"; }
standard_items() {
  item trash-1 trash delete "$H/.Trash/old.zip" 2097152 offerable 1:2 measured "" ""
  item caches-1 caches delete "$H/Library/Caches/com.big" 3221225472 offerable 1:3 measured "" ""
  item caches-2 caches delete "$H/Library/Caches/com.part" 1048576 offerable 1:4 partial "" ""
  item caches-3 caches delete "$H/Library/Caches/com.held" 4096 "not offerable: Safari has a file open beneath it" 1:5 measured "" ""
  item caches-4 caches delete "$H/Library/Caches/com.unread" "" "unmeasured: du could not read it" 1:6 unread "" ""
  item large-files-1 large-files trash "$H/Documents/keys.p12" 734003200 offerable 1:9 measured credential "a certificate store"
  item large-files-2 large-files trash "$H/Library/Mobile Documents/com~apple~CloudDocs/film.mov" 943718400 offerable 1:10 measured icloud ""
}
fresh() {
  chmod -R u+rwx "$H" 2>/dev/null
  rm -rf "$H" "$DC_TMPDIR"
  mkdir -p "$H" "$DC_TMPDIR" "$STATE" "$OUT"
  : > "$DC_CALLS"
  : > "$DC_ROOT/refused.log"
  dc_stub pbcopy 'cat > "$HOME/clipboard.txt"; exit 0'
}
write_record() { # [<items file>]
  local items="${1:-$H/items.txt}"
  [ -n "${1:-}" ] || standard_items > "$items"
  printf 'categories%strash caches large-files\n' "$S" > "$H/notes.txt"
  dcr_write "$REC" "$SID" 1761600000 "$items" "$H/notes.txt" || { echo "fixture: dcr_write failed" >&2; return 1; }
}
lib() { OUT_TEXT="$(dc_run bash -c '. "$1" || exit 99; shift; "$@"' lib "$LIB_SH" "$@" 2>&1)"; RC=$?; }
new_nonce() { lib dcrv_write_nonce "$OUT" "$SID"; N="$OUT_TEXT"; }
checker() { OUT_TEXT="$(dc_run bash "$CHECK_SH" "$@" 2>&1)"; RC=$?; }
payload() { # <scan_id> <nonce> <count> <id>...
  local sid="$1" n="$2" c="$3" ids="" i
  shift 3
  for i in "$@"; do ids="$ids${ids:+,}\"$i\""; done
  printf '{"scan_id":"%s","nonce":"%s","count":%s,"ids":[%s]}\n' "$sid" "$n" "$c" "$ids" > "$H/payload.json"
}
run_check() { checker --out "$OUT" --payload "$H/payload.json" --plan "$PLAN"; }

# ================================================================================================
# 1. The nonce a review page carries: fresh per render, kept beside the page
# ================================================================================================
fresh
new_nonce
check "writing a nonce succeeds" "$(eq "$RC" 0)"
check "it is 32 hex characters" "$(case "$N" in (*[!0-9a-f]*|'') echo "got '$N'" ;; (*) [ "${#N}" -eq 32 ] && echo ok || echo "got '$N'" ;; esac)"
check "the nonce file names the scan" "$(eq "$(awk '$1 == "scan_id" { print $2 }' "$NONCE" 2>/dev/null)" "$SID")"
check "the nonce file holds the nonce printed" "$(eq "$(awk '$1 == "nonce" { print $2 }' "$NONCE" 2>/dev/null)" "$N")"
n1="$N"
new_nonce
check "a second render makes a new nonce" "$([ -n "$n1" ] && [ "$N" != "$n1" ] && echo ok || echo "same nonce $n1")"
lib dcrv_write_nonce "$H/no/such/folder" "$SID"
check "a nonce for a folder that does not exist is refused" "$([ "$RC" -ne 0 ] && echo ok || echo "exit 0")"
lib dcrv_write_nonce "$OUT" "$(printf 'a\tb')"
check "a scan id holding a control character is refused" "$([ "$RC" -ne 0 ] && echo ok || echo "exit 0")"
lib dcrv_write_nonce /tmp "$SID"
check "in test mode a folder outside the throwaway directory is refused" "$([ "$RC" -ne 0 ] && echo ok || echo "exit 0")"
check "and says why" "$(has "$OUT_TEXT" "outside")"

# ================================================================================================
# 2. Clearing the clipboard, through pbcopy, which the harness stubs
# ================================================================================================
fresh
printf 'stale' > "$H/clipboard.txt"
lib dcrv_clear_clipboard
check "clearing the clipboard succeeds" "$(eq "$RC" 0)"
check "it writes the clipboard once" "$(eq "$(dc_calls pbcopy | wc -l | tr -d ' ')" 1)"
check "with nothing" "$([ -f "$H/clipboard.txt" ] && [ ! -s "$H/clipboard.txt" ] && echo ok || echo "clipboard holds: $(cat "$H/clipboard.txt" 2>/dev/null)")"
dc_stub pbcopy 'echo "pbcopy: no pasteboard" >&2; exit 1'
lib dcrv_clear_clipboard
check "a clipboard that cannot be cleared fails" "$([ "$RC" -ne 0 ] && echo ok || echo "exit 0")"
check "saying a selection copied earlier may still be on it" "$(has "$OUT_TEXT" "could not clear the clipboard")"
check "and what pbcopy said" "$(has "$OUT_TEXT" "no pasteboard")"

# ================================================================================================
# 3. The checker: a matching selection becomes disk-remove's plan
# ================================================================================================
fresh
write_record
new_nonce
printf 'keep me\n' > "$PLAN"
payload "$SID" "$N" 2 caches-1 large-files-1
run_check
check "a matching selection is accepted with exit 0" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT_TEXT")"
check "it writes disk-remove's plan" "$(eq "$(cat "$PLAN")" "scan_id $SID
count 2
item caches-1
item large-files-1")"
check "it names what will go, by category, in words" "$(has "$OUT_TEXT" "App caches: 1 item, 3.2 GB")"
check "and every item by path" "$(has "$OUT_TEXT" "$H/Documents/keys.p12")"
check "and flags an item holding credentials" "$(has "$OUT_TEXT" "Holds a credential")"
check "the plan it writes is one disk-remove can read" "$(awk 'NR == 1 && $1 != "scan_id" { bad = 1 } NR == 2 && $1 != "count" { bad = 1 } NR > 2 && $1 != "item" { bad = 1 } END { print (bad ? "not the plan layout" : "ok") }' "$PLAN")"

payload "$SID" "$N" 2 large-files-2 caches-2
run_check
check "a partial size is totalled as a lower bound" "$(has "$OUT_TEXT" "App caches: 1 item, at least 1 MB")"
check "an iCloud item says it goes from every device" "$(has "$OUT_TEXT" "every device")"

printf '{\n  "scan_id": "%s",\n  "nonce": "%s",\n  "count": 1,\n  "ids": [\n    "trash-1"\n  ]\n}\n' "$SID" "$N" > "$H/payload.json"
run_check
check "a payload laid out over several lines is accepted" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT_TEXT")"
check "and planned" "$(eq "$(tail -1 "$PLAN")" "item trash-1")"

# A selection holding an offerable item whose size was never read: totalled by the shared tally
# (lib/disk-clean-units.sh, #1866), so the total is "at least" beside a size that was read, and
# unknown, never 0 KB, when no size in that category was read at all (L90).
fresh
{ standard_items
  item caches-5 caches delete "$H/Library/Caches/com.denied" "" offerable 1:7 denied "" ""
  item trash-2 trash delete "$H/.Trash/locked" "" offerable 1:8 unread "" ""
} > "$H/items-unread.txt"
write_record "$H/items-unread.txt"
new_nonce
payload "$SID" "$N" 3 caches-1 caches-5 trash-2
run_check
check "a selection holding an item with no size read is accepted" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT_TEXT")"
check "beside a size that was read, the total is at least, and the unread one is named" \
  "$(has "$OUT_TEXT" "App caches: 2 items, at least 3.2 GB, plus 1 whose size was not read")"
check "with no size read in the category, the total is unknown, said once" \
  "$(grep -qxF "Trash: 1 item, size unknown" <<< "$OUT_TEXT" && echo ok || echo "said: $(grep '^Trash' <<< "$OUT_TEXT")")"
check "and never 0 KB" "$(hasnt "$OUT_TEXT" "0 KB")"

# ================================================================================================
# 4. The checker's refusals: each distinct, and none writes a plan
# ================================================================================================
printf 'keep me\n' > "$PLAN"
payload "scan-1700000000-1" "$N" 1 caches-1
run_check
check "a selection from another scan is refused with exit 3" "$(eq "$RC" 3)"
check "saying it is not the last scan" "$(has "$OUT_TEXT" "not the last scan")"

payload "$SID" "0123456789abcdef0123456789abcdef" 1 caches-1
run_check
check "a nonce that does not match is refused with exit 4" "$(eq "$RC" 4)"
check "saying it came from another copy of the page" "$(has "$OUT_TEXT" "not the page rendered last")"

payload "$SID" "$N" 3 caches-1 trash-1
run_check
check "a count that does not match the ids is refused with exit 5" "$(eq "$RC" 5)"
check "saying both numbers" "$(has "$OUT_TEXT" "says 3 items but lists 2")"

payload "$SID" "$N" 3 caches-1 caches-3 nope-9
run_check
check "an id that is not offerable is refused with exit 6" "$(eq "$RC" 6)"
check "naming it and why" "$(has "$OUT_TEXT" "caches-3: not offerable: Safari has a file open beneath it")"
check "and an id the scan never had" "$(has "$OUT_TEXT" "nope-9: not in scan $SID")"
check "and never the good one" "$(hasnt "$OUT_TEXT" "caches-1:")"
payload "$SID" "$N" 1 caches-4
run_check
check "an unmeasured id is refused with exit 6" "$(eq "$RC" 6)"

payload "$SID" "$N" 0
run_check
check "an empty selection is refused with exit 7" "$(eq "$RC" 7)"
check "saying nothing was chosen" "$(has "$OUT_TEXT" "nothing was chosen")"

i=0
for bad in 'not json at all' '{"scan_id":"x"}' \
  "{\"scan_id\":\"$SID\",\"nonce\":\"$N\",\"count\":1,\"ids\":[\"trash-1\"],\"extra\":1}" \
  "{\"scan_id\":\"$SID\",\"nonce\":\"$N\",\"count\":2,\"ids\":[\"trash-1\",\"trash-1\"]}" \
  "{\"scan_id\":\"$SID\",\"nonce\":\"$N\",\"count\":1,\"ids\":[\"tr\\nash\"]}" \
  "{\"scan_id\":\"$SID\",\"nonce\":\"$N\",\"count\":\"1\",\"ids\":[\"trash-1\"]}" \
  "{\"scan_id\":\"$SID\",\"nonce\":\"$N\",\"count\":1,\"ids\":[\"trash-1\"]} trailing"; do
  i=$((i + 1))
  printf '%s\n' "$bad" > "$H/payload.json"
  run_check
  check "malformed payload $i is refused with exit 2" "$(eq "$RC" 2)"
  [ "$i" -eq 4 ] && check "a repeated id is named" "$(has "$OUT_TEXT" "trash-1 twice")"
done
: > "$H/payload.json"
run_check
check "an empty payload is refused with exit 2" "$(eq "$RC" 2)"
checker --out "$OUT" --payload "$H/no-such.json" --plan "$PLAN"
check "a payload file that is not there is refused with exit 2" "$(eq "$RC" 2)"
check "after every refusal the plan is untouched" "$(eq "$(cat "$PLAN")" "keep me")"

rm -f "$NONCE"
payload "$SID" "$N" 1 caches-1
run_check
check "with no page rendered it refuses with exit 2" "$(eq "$RC" 2)"
check "saying no review page was rendered there" "$(has "$OUT_TEXT" "no review page was rendered")"
checker --payload "$H/payload.json" --plan "$PLAN"
check "with no --out it refuses with exit 2" "$(eq "$RC" 2)"
checker --out "$OUT" --payload "$H/payload.json" --plan "$PLAN" --force
check "an unknown option is refused with exit 2" "$(eq "$RC" 2)"

fresh
new_nonce
payload "$SID" "$N" 1 caches-1
run_check
check "with no scan record it refuses with exit 2" "$(eq "$RC" 2)"
check "saying there is no scan" "$(has "$OUT_TEXT" "no scan")"
write_record
awk '$0 != "]}"' "$REC" > "$REC.cut" && mv "$REC.cut" "$REC"
run_check
check "a record cut short is refused with exit 2" "$(eq "$RC" 2)"
check "saying it stopped partway" "$(has "$OUT_TEXT" "stopped partway")"

# An item disk-remove has since marked removed is no longer offerable.
fresh
write_record
new_nonce
printf 'caches-1%sremoved\n' "$S" > "$H/marks.txt"
dcr_mark "$REC" "$SID" "$H/marks.txt"
payload "$SID" "$N" 1 caches-1
run_check
check "an item already removed is refused with exit 6" "$(eq "$RC" 6)"
check "saying it was removed" "$(has "$OUT_TEXT" "caches-1: removed")"

# ================================================================================================
# 5. The real count (L101): a scan of thousands, a selection of thousands
# ================================================================================================
fresh
BIG=5000
awk -v n="$BIG" -v h="$H" -v s="$S" 'BEGIN {
  split("caches build-folders large-files", c, " ")
  for (i = 1; i <= n; i++) {
    k = c[(i % 3) + 1]
    st = (i % 7 == 0) ? "not offerable: a process holds a file open beneath it" : "offerable"
    printf "%s-%d%s%s%sdelete%s%s/Library/Caches/item-%d%s%d%s%s%s1:%d%smeasured%s%s\n", k, i, s, k, s, s, h, i, s, i * 4096, s, st, s, i, s, s, s
  }
}' > "$H/big.txt"
write_record "$H/big.txt"
new_nonce
ids="$(awk -F "$S" '$6 == "offerable" && n++ < 2000 { print $1 }' "$H/big.txt")"
# shellcheck disable=SC2086
payload "$SID" "$N" 2000 $ids
start="$(date +%s)"
run_check
took=$(( $(date +%s) - start ))
echo "  (a selection of 2000 from a scan of $BIG checked in ${took}s)"
check "a selection of 2000 is accepted" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $(head -3 <<< "$OUT_TEXT")")"
check "and every one is in the plan" "$(eq "$(grep -c '^item ' "$PLAN")" 2000)"
check "it is checked in under 30 seconds" "$([ "$took" -lt 30 ] && echo ok || echo "${took}s")"
bad="$(awk -F "$S" '$6 != "offerable" { print $1; exit }' "$H/big.txt")"
# shellcheck disable=SC2086
payload "$SID" "$N" 2001 $ids "$bad"
run_check
check "one not offerable id among 2001 is still found" "$(eq "$RC" 6)"
check "and named" "$(has "$OUT_TEXT" "$bad: not offerable")"

check "the category table names categories in words" "$(eq "$(dcr_title large-files)|$(dcr_title unknown-x)" "Large personal files|unknown-x")"

finish
