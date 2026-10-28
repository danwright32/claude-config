#!/usr/bin/env bash
# Tests for disk-clean's review page renderer (claude-config#1807): review-page.sh, which renders the
# last scan into one self contained local page, with the nonce beside it, drawn to the design Dan
# settled on 2026-10-28 (docs/design/disk-clean-review-page.html, its fixture
# review-page.fixture.json beside this file).
#
# Everything runs ONLY through the disk-clean harness's dc_run (hooks/lib/disk-clean-harness.sh),
# with HOME a throwaway directory and pbcopy a stub, so no test ever touches the real clipboard.
# What only a browser can see (the colours of decisions D6, D7 and D10, the one line rows of D5, and
# the Copy selection button producing its payload) is checked headlessly in the PR, since CI has no
# browser. Everything the markup itself decides is checked here.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): hooks/lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAGE_SH="$DIR/review-page.sh"
FIXTURE="$DIR/review-page.fixture.json"

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
count_of() { grep -oF -- "$2" <<< "$1" | wc -l | tr -d ' '; }

. "$DIR/../../hooks/lib/disk-clean-harness.sh" || { check "the harness is there to source" "could not source it"; finish; }
. "$DIR/../../hooks/lib/disk-clean-record.sh" || { check "the record library is there to source" "could not source it"; finish; }
check "review-page.sh is there to run" "$([ -f "$PAGE_SH" ] && echo ok || echo "missing: $PAGE_SH")"
check "the settled design's fixture is beside this suite" "$([ -f "$FIXTURE" ] && echo ok || echo "missing: $FIXTURE")"
command -v python3 >/dev/null 2>&1 || { check "python3 is here to read the fixture" "it is not on PATH"; finish; }
dc_setup || { check "the harness sets up" "dc_setup failed"; finish; }

H="$DC_HOME"
STATE="$H/.claude/state/disk-clean"
REC="$STATE/last-scan.json"
OUT="$H/scratch/review"
PAGE="$OUT/disk-clean-review.html"
NONCE="$OUT/disk-clean-review.nonce"
S=$'\037'
SID="scan-1761600000-4242"

# The settled fixture as a scan record: its items in record order, /Users/dan as this HOME.
fixture_items() {
  python3 - "$FIXTURE" "$H" <<'PY'
import json, sys
f = json.load(open(sys.argv[1]))
for it in f["items"]:
    b = "" if it["bytes"] is None else str(it["bytes"])
    t = it["target"].replace("/Users/dan", sys.argv[2], 1)
    print("\037".join([it["id"], it["category"], "delete", t, b, it["state"], "1:1", it["size"], it["flags"], it["detail"]]))
PY
}
# What decision D3 says the order of kinds is, worked out here from the fixture, not by the renderer.
fixture_order() {
  python3 - "$FIXTURE" <<'PY'
import json, sys
f = json.load(open(sys.argv[1]))
personal = ["forgotten-tools", "large-files"]
tot = {c: sum(it["bytes"] or 0 for it in f["items"] if it["category"] == c and it["state"] == "offerable") for c in f["categories"]}
rest = sorted([c for c in f["categories"] if c not in personal], key=lambda c: -tot[c])
print(" ".join(rest + personal))
PY
}
notes() { # [<categories>]
  printf 'categories%s%s\n' "$S" "${1:-trash caches xcode build-folders docker playwright claude-temp worktrees transcripts runaway-logs forgotten-tools large-files}"
}
fresh() {
  chmod -R u+rwx "$H" 2>/dev/null
  rm -rf "$H" "$DC_TMPDIR"
  mkdir -p "$H" "$DC_TMPDIR" "$STATE"
  : > "$DC_CALLS"
  : > "$DC_ROOT/refused.log"
  dc_stub pbcopy 'cat > "$HOME/clipboard.txt"; [ -e "$HOME/scratch/review/disk-clean-review.html" ] && echo after > "$HOME/clip-order.txt" || echo before > "$HOME/clip-order.txt"; exit 0'
}
write_record() { # <items file> [<categories>]
  notes "${2:-}" > "$H/notes.txt"
  dcr_write "$REC" "$SID" 1761600000 "$1" "$H/notes.txt" || { echo "fixture: dcr_write failed" >&2; return 1; }
}
fixture_record() { fixture_items > "$H/items.txt" && write_record "$H/items.txt"; }
render() { OUT_TEXT="$(dc_run bash "$PAGE_SH" "$@" 2>&1)"; RC=$?; HTML="$(cat "$PAGE" 2>/dev/null)"; }
nonce_of() { awk '$1 == "nonce" { print $2 }' "$NONCE"; }
row() { awk -v id="data-id=\"$1\"" 'index($0, id) && /class="item/ { print; exit }' <<< "$HTML"; }

# ================================================================================================
# 1. It refuses what it cannot render, writing nothing
# ================================================================================================
fresh
render --out "$OUT"
check "with no scan record it refuses with exit 2" "$(eq "$RC" 2)"
check "it says there is no scan to review" "$(has "$OUT_TEXT" "no scan to review")"
check "it writes no page" "$([ -e "$PAGE" ] && echo "a page was written" || echo ok)"

fresh
fixture_record
awk '$0 != "]}"' "$REC" > "$REC.cut" && mv "$REC.cut" "$REC"
render --out "$OUT"
check "a record cut short is refused with exit 2" "$(eq "$RC" 2)"
check "it says the record stopped partway" "$(has "$OUT_TEXT" "stopped partway")"
check "a record cut short writes no page" "$([ -e "$PAGE" ] && echo "a page was written" || echo ok)"

fresh
fixture_record
render
check "with no --out folder it refuses with exit 2" "$(eq "$RC" 2)"
render --out "$OUT" --colour blue
check "an unknown option is refused with exit 2" "$(eq "$RC" 2)"
render --out /tmp/disk-clean-review-elsewhere
check "in test mode a folder outside the throwaway directory is refused with exit 2" "$(eq "$RC" 2)"
check "and nothing is written there" "$([ -e /tmp/disk-clean-review-elsewhere ] && echo "it was written" || echo ok)"

# ================================================================================================
# 2. One self contained page, the nonce beside it, nothing ticked
# ================================================================================================
fresh
fixture_record
render --out "$OUT"
check "it renders with exit 0" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT_TEXT")"
check "it writes the page into the folder it was given" "$([ -s "$PAGE" ] && echo ok || echo "no page at $PAGE")"
check "it prints where the page is" "$(has "$OUT_TEXT" "$PAGE")"
check "the nonce file names the scan" "$(eq "$(awk '$1 == "scan_id" { print $2 }' "$NONCE" 2>/dev/null)" "$SID")"
n1="$(nonce_of 2>/dev/null)"
check "the page carries the nonce" "$([ -n "$n1" ] && has "$HTML" "data-nonce=\"$n1\"" || echo "no nonce")"
check "the page carries the scan id" "$(has "$HTML" "data-scan-id=\"$SID\"")"
render --out "$OUT"
check "a second render makes a new nonce" "$([ -n "$n1" ] && [ "$(nonce_of)" != "$n1" ] && echo ok || echo "same nonce $n1")"
check "and carries it" "$(has "$HTML" "data-nonce=\"$(nonce_of)\"")"

check "the page loads nothing from the network" "$(grep -qiE '(src|href)="?(https?:)?//' <<< "$HTML" && echo "it references a remote URL" || echo ok)"
check "the page links no external stylesheet or script" "$(grep -qiE '<link|<script[^>]+src=' <<< "$HTML" && echo "it does" || echo ok)"
check "the page has exactly one script of its own" "$(eq "$(count_of "$HTML" "<script")" 1)"
check "the page has a dark theme by the system setting" "$(has "$HTML" "prefers-color-scheme: dark")"
check "it is called Disk clean" "$(has "$HTML" "<h1>Disk clean</h1>")"
check "it says when the scan was taken" "$(has "$HTML" "Scanned ")"
check "and that nothing goes until the selection is copied back" "$(has "$HTML" "Nothing is removed until you copy your selection back.")"

check "every item has a tick box" "$(eq "$(count_of "$HTML" 'class="tick"')" "$(fixture_items | wc -l | tr -d ' ')")"
check "nothing is ticked" "$(grep -qE '<input[^>]* checked' <<< "$HTML" && echo "an input is ticked" || echo ok)"
check "the browser is asked not to restore ticks on reload" "$(has "$HTML" 'autocomplete="off"')"
check "the foot bar opens on Nothing selected (D9)" "$(has "$HTML" ">Nothing selected<")"
check "beside Copy selection (D9)" "$(has "$HTML" ">Copy selection</button>")"

# ================================================================================================
# 3. The settled decisions the markup makes, on the design's own fixture
# ================================================================================================
check "every kind is a heading row with its total (D1)" "$(eq "$(grep -cE '<div class="group-head" data-category="[a-z-]+"><h2>[^<]+</h2><span class="group-total">' <<< "$HTML")" 12)"
check "no kind is drawn inside a box (D1)" "$(grep -qE 'class="(category|items)"' <<< "$HTML" && echo "a kind is boxed" || echo ok)"
order="$(grep -oE '<div class="group-head" data-category="[a-z-]+"' <<< "$HTML" | awk -F '"' '{ printf "%s%s", (n++ ? " " : ""), $4 }')"
check "kinds come largest first, your own files last (D3)" "$(eq "$order" "$(fixture_order)")"
check "the last two kinds are Tools not used in 180 days, then Large personal files (D3)" \
  "$(eq "$(grep -oE '<h2>[^<]+</h2>' <<< "$HTML" | tail -2 | tr -d '\n')" "<h2>Tools not used in 180 days</h2><h2>Large personal files</h2>")"
# D2 and D4: walk the rows in page order, kind by kind.
rows_verdict="$(awk '
  /class="group-head"/ { kind = $0; seen_kept = 0; last = -1; seen_unknown = 0; next }
  /class="item/ {
    id = $0; sub(/.*data-id="/, "", id); sub(/".*/, "", id)
    dis = ($0 ~ /<input[^>]* disabled/)
    b = $0; if (match(b, /data-bytes="[0-9]*"/)) { b = substr(b, RSTART + 12, RLENGTH - 13) } else b = "?"
    if (dis) { seen_kept = 1; next }
    if (seen_kept) { msg = "D2: " id " can be ticked but follows one that cannot"; exit }
    if (b == "") { seen_unknown = 1; next }
    if (seen_unknown) { msg = "D4: " id " has a size but follows one of unknown size"; exit }
    if (last >= 0 && b + 0 > last) { msg = "D4: " id " is larger than the row above it"; exit }
    last = b + 0
  }
  END { print (msg == "" ? "ok" : msg) }' <<< "$HTML")"
check "within a kind, what you can tick comes first, largest first, unknown sizes last (D2, D4)" "$rows_verdict"
check "an item it will not remove is greyed (D2)" "$(has "$(row caches-4)" 'class="item kept"')"
check "and cannot be ticked" "$(grep -qE '<input[^>]* disabled' <<< "$(row caches-4)" && echo ok || echo "it can be ticked")"
check "and says why, without the record's prefix" "$(has "$(row caches-4)" '<span class="note">Chrome has files open in it</span>')"
check "an unmeasured item says why too" "$(has "$(row worktrees-28)" "GitHub did not answer whether its pull request merged")"
check "an item you can tick can be ticked" "$(grep -qE '<input[^>]* disabled' <<< "$(row caches-3)" && echo "it is disabled" || echo ok)"
check "a credential is marked, amber's class (D7)" "$(has "$(row forgotten-tools-33)" '<span class="flag">Holds a credential</span>')"
check "an iCloud item is marked (D7)" "$(has "$(row large-files-37)" '<span class="flag">Removes it from iCloud on every device</span>')"
check "and its note does not repeat the mark (D8)" "$(has "$(row large-files-37)" '<span class="note">in iCloud Drive</span>')"
check "a mark is said once on the row (D8)" "$(eq "$(count_of "$(row large-files-37)" "every device")" 1)"
check "a path under the home folder starts with ~" "$(has "$(row caches-3)" '<span class="path">~/Library/Caches/com.adobe.LightroomClassicCC7</span>')"
check "a size is in decimal units, as the design writes it" "$(has "$(row caches-3)" '<span class="size">18.4 GB</span>')"
check "a partial size says it is a lower bound" "$(has "$(row runaway-logs-32)" "At least 1.6 GB")"
check "a size nobody read says so, never 0" "$(has "$(row caches-8)" '<span class="size unknown">Size unknown</span>')"
check "a kind's total counts only what can go" "$(has "$HTML" 'data-category="caches"><h2>App caches</h2><span class="group-total">23.2 GB</span>')"
check "a kind's total holding a partial size says so" "$(has "$HTML" 'data-category="runaway-logs"><h2>Runaway logs</h2><span class="group-total">At least ')"
check "the tick box is named by its path" "$(has "$(row caches-3)" 'aria-label="~/Library/Caches/com.adobe.LightroomClassicCC7"')"
# The colours themselves are read from the drawn page in the PR; here, no style names red as a value.
check "no style uses red (D7)" "$(grep -qiE '(:|,) *red *[;,)!]|#(f00|ff0000|e00|d00|c00)[^0-9a-f]' <<< "$HTML" && echo "a red is used" || echo ok)"
check "kinds are named from the one table" "$(eq "$(dcr_title forgotten-tools)|$(dcr_title build-folders)|$(dcr_title unknown-x)" "Tools not used in 180 days|Project build folders|unknown-x")"

# ================================================================================================
# 4. Hostile file names are text, never markup
# ================================================================================================
fresh
HOSTILE="$H/Downloads/<script>alert(1)</script>\"&'.txt"
printf '%s\n' "large-files-1${S}large-files${S}trash${S}$HOSTILE${S}629145600${S}offerable${S}1:1${S}measured${S}${S}<b>bold</b>" > "$H/items.txt"
write_record "$H/items.txt" large-files
render --out "$OUT"
check "a hostile name renders with exit 0" "$(eq "$RC" 0)"
check "its markup is escaped" "$(has "$(row large-files-1)" "~/Downloads/&lt;script&gt;alert(1)&lt;/script&gt;&quot;&amp;&#39;.txt")"
check "and never live" "$(hasnt "$HTML" "<script>alert(1)")"
check "a detail holding markup is escaped too" "$(has "$(row large-files-1)" "&lt;b&gt;bold&lt;/b&gt;")"
check "the page still has exactly one script" "$(eq "$(count_of "$HTML" "<script")" 1)"

# An empty scan says so, rather than drawing an empty page.
fresh
: > "$H/items.txt"
write_record "$H/items.txt" trash
render --out "$OUT"
check "a scan with nothing in it renders with exit 0" "$(eq "$RC" 0)"
check "and says it found nothing" "$(has "$HTML" "This scan found nothing to remove.")"

# ================================================================================================
# 5. The clipboard is cleared before the page exists, only when asked, and a failure says so
# ================================================================================================
fresh
fixture_record
render --out "$OUT"
check "without --clear-clipboard the clipboard is left alone" "$(eq "$(dc_calls pbcopy | wc -l | tr -d ' ')" 0)"
fresh
fixture_record
render --out "$OUT" --clear-clipboard
check "with --clear-clipboard it renders with exit 0" "$(eq "$RC" 0)"
check "the clipboard is written once" "$(eq "$(dc_calls pbcopy | wc -l | tr -d ' ')" 1)"
check "with nothing" "$([ -f "$H/clipboard.txt" ] && [ ! -s "$H/clipboard.txt" ] && echo ok || echo "clipboard holds: $(cat "$H/clipboard.txt" 2>/dev/null)")"
check "before the page is written" "$(eq "$(cat "$H/clip-order.txt" 2>/dev/null)" before)"
fresh
fixture_record
dc_stub pbcopy 'echo "no pasteboard" >&2; exit 1'
render --out "$OUT" --clear-clipboard
check "a clipboard that cannot be cleared exits 3" "$(eq "$RC" 3)"
check "and says so" "$(has "$OUT_TEXT" "could not clear the clipboard")"
check "the page is still written" "$([ -s "$PAGE" ] && echo ok || echo "no page")"

# ================================================================================================
# 6. The real count (L101, L606): thousands of items, every one a row, in bounded time
# ================================================================================================
fresh
BIG=5000
awk -v n="$BIG" -v h="$H" -v s="$S" 'BEGIN {
  split("caches build-folders large-files", c, " ")
  for (i = 1; i <= n; i++) {
    k = c[(i % 3) + 1]
    st = (i % 7 == 0) ? "not offerable: a process holds a file open beneath it" : "offerable"
    printf "%s-%d%s%s%sdelete%s%s/Library/Caches/item-%d%s%d%s%s%s1:%d%smeasured%s%s\n", k, i, s, k, s, s, h, i, s, (i * 7919) % 100000 * 4096, s, st, s, i, s, s, s
  }
}' > "$H/big.txt"
write_record "$H/big.txt" "caches build-folders large-files"
start="$(date +%s)"
render --out "$OUT"
took=$(( $(date +%s) - start ))
echo "  ($BIG items rendered in ${took}s, page $(wc -c < "$PAGE" | tr -d ' ') bytes)"
check "a scan of $BIG items renders with exit 0" "$(eq "$RC" 0)"
check "every one of them has a tick box" "$(eq "$(count_of "$HTML" 'class="tick"')" "$BIG")"
check "it renders in under 30 seconds" "$([ "$took" -lt 30 ] && echo ok || echo "${took}s")"
big_verdict="$(awk '
  /class="group-head"/ { seen_kept = 0; last = -1; next }
  /class="item/ {
    dis = ($0 ~ /<input[^>]* disabled/)
    b = $0; match(b, /data-bytes="[0-9]*"/); b = substr(b, RSTART + 12, RLENGTH - 13) + 0
    if (dis) { seen_kept = 1; next }
    if (seen_kept || (last >= 0 && b > last)) { msg = "out of order at line " NR; exit }
    last = b
  }
  END { print (msg == "" ? "ok" : msg) }' <<< "$HTML")"
check "at the real count the rows are still in order" "$big_verdict"

finish
