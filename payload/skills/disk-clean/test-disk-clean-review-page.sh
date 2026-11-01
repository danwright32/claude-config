#!/usr/bin/env bash
# Tests for disk-clean's review page renderer (claude-config#1807): review-page.sh, which renders the
# last scan into one self contained local page, with the nonce beside it, drawn to the design Dan
# settled on 2026-10-28 (docs/design/disk-clean-review-page.html, its fixture
# review-page.fixture.json beside this file, the home folder written as ~).
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

# The settled fixture as a scan record: its items in record order, its ~ as this HOME. The fixture
# is the design's own (docs/design/disk-clean-review-page.fixture.json) with the home folder of the
# machine it was drawn on written as ~, since a synced file may name no machine's home (check-home-paths).
fixture_items() {
  python3 - "$FIXTURE" "$H" <<'PY'
import json, sys
f = json.load(open(sys.argv[1]))
for it in f["items"]:
    b = "" if it["bytes"] is None else str(it["bytes"])
    t = sys.argv[2] + it["target"][1:] if it["target"].startswith("~") else it["target"]
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
  [ -z "${EXTRA_NOTES:-}" ] || printf '%s\n' "$EXTRA_NOTES"
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
check "every kind is a heading row with its total (D1)" "$(eq "$(grep -cE '<div class="group-head" data-category="[a-z-]+"><label class="head-left"><input class="tick head-tick" [^>]*><h2>[^<]+</h2></label><span class="group-total">' <<< "$HTML")" 12)"
heading() { awk -v c="data-category=\"$1\"" 'index($0, c) && /class="group-head/ { print; exit }' <<< "$HTML"; }
check "every kind's heading has a tick box before its name (D11)" "$(eq "$(count_of "$HTML" 'class="tick head-tick"')" 12)"
check "the heading box is named for the kind (D11)" "$(has "$(heading caches)" 'aria-label="Tick every App caches item"')"
check "the heading box ticks only its own kind's items (D11)" "$(grep -qE '<input class="tick head-tick"[^>]* data-category="caches"' <<< "$(heading caches)" && echo ok || echo "the box names no kind: $(heading caches)")"
check "a kind with items to tick has its heading box enabled (D11)" "$(grep -qE '<input class="tick head-tick"[^>]* disabled' <<< "$(heading caches)" && echo "it is disabled" || echo ok)"
check "every row's box says which kind it is in, for its heading box" "$(grep -qE '<input class="tick"[^>]* data-category="caches"' <<< "$(row caches-3)" && echo ok || echo "it does not")"
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
check "a kind's total counts only what can go" "$(has "$(heading caches)" '<h2>App caches</h2></label><span class="group-total">23.2 GB</span>')"
check "a kind's total holding a partial size says so" "$(has "$(heading runaway-logs)" '<span class="group-total">At least ')"
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

# A kind with nothing that can be ticked has its heading box disabled (D11).
fresh
printf '%s\n' "caches-1${S}caches${S}delete${S}$H/Library/Caches/a${S}4096${S}not offerable: Safari has files open in it${S}1:1${S}measured${S}${S}" \
  "trash-1${S}trash${S}delete${S}$H/.Trash/b${S}4096${S}offerable${S}1:2${S}measured${S}${S}" > "$H/items.txt"
write_record "$H/items.txt" "trash caches"
render --out "$OUT"
check "a kind with nothing to tick has its heading box disabled (D11)" "$(grep -qE '<input class="tick head-tick"[^>]* disabled' <<< "$(heading caches)" && echo ok || echo "it can be ticked: $(heading caches)")"
check "while a kind with something to tick does not" "$(grep -qE '<input class="tick head-tick"[^>]* disabled' <<< "$(heading trash)" && echo "it is disabled" || echo ok)"

# A kind's total is the shared tally's (lib/disk-clean-units.sh, #1866): an item whose size was
# never read beside one that was makes it "At least", and a kind where no size was read at all has
# an unknown total, never "At least 0 KB" (L90).
fresh
printf '%s\n' "caches-1${S}caches${S}delete${S}$H/Library/Caches/a${S}4194304${S}offerable${S}1:1${S}measured${S}${S}" \
  "caches-2${S}caches${S}delete${S}$H/Library/Caches/b${S}${S}offerable${S}1:2${S}denied${S}${S}" \
  "trash-1${S}trash${S}delete${S}$H/.Trash/c${S}${S}offerable${S}1:3${S}unread${S}${S}" > "$H/items.txt"
write_record "$H/items.txt" "trash caches"
render --out "$OUT"
check "a kind holding an item with no size read beside a read one totals at least" "$(has "$(heading caches)" '<span class="group-total">At least 4 MB</span>')"
check "a kind with no size read at all has an unknown total" "$(has "$(heading trash)" '<span class="group-total">Size unknown</span>')"
check "never at least 0 KB" "$(hasnt "$HTML" "At least 0 KB")"

# The heading box's rules (D11), run in node from the page's own script: what CI's runner and
# both Macs have. Without node this part is reported as unmeasured, never as a pass (L411).
if command -v node >/dev/null 2>&1; then
  rules="$(awk '/D11 rules begin/ { p = 1; next } /D11 rules end/ { p = 0 } p' <<< "$HTML")"
  check "the page carries the heading box's rules" "$([ -n "$rules" ] && echo ok || echo "no D11 rules block in the page")"
  verdict="$(node -e "$rules"'
    var out = [];
    function eq(name, got, want) { if (JSON.stringify(got) !== JSON.stringify(want)) out.push(name + ": got " + JSON.stringify(got)); }
    function boxes() { return [{ checked: false, disabled: false }, { checked: false, disabled: false }, { checked: false, disabled: true }]; }
    var b = boxes();
    eq("opens empty", headState(b), { disabled: false, checked: false, indeterminate: false });
    b[0].checked = true;
    eq("one of two ticked is half filled", headState(b), { disabled: false, checked: false, indeterminate: true });
    b[1].checked = true;
    eq("both ticked is full", headState(b), { disabled: false, checked: true, indeterminate: false });
    b = boxes(); applyHead(b, true);
    eq("ticking the heading ticks what can be ticked", [b[0].checked, b[1].checked], [true, true]);
    eq("and never a kept item", b[2].checked, false);
    eq("after which the heading is full", headState(b), { disabled: false, checked: true, indeterminate: false });
    applyHead(b, false);
    eq("unticking it unticks them", [b[0].checked, b[1].checked, b[2].checked], [false, false, false]);
    eq("a kind with nothing to tick is disabled", headState([{ checked: false, disabled: true }]), { disabled: true, checked: false, indeterminate: false });
    console.log(out.length ? out.join("; ") : "ok");' 2>&1)"
  check "the heading box: half filled, full, and never ticking a kept item (D11)" "$verdict"
else
  echo "SUITE-PART-UNMEASURED the heading box's rules (D11): node is not on PATH, so the page's script could not be run"
fi

# ================================================================================================
# A kind the scan could not measure at all is shown (Dan, 2026-10-28): its heading greyed, with no
# tick box, its reason where the total goes, no rows, after the measured kinds that regenerate and
# before Dan's own files.
# ================================================================================================
fresh
printf '%s\n' "trash-1${S}trash${S}delete${S}$H/.Trash/a${S}2000000000${S}offerable${S}1:1${S}measured${S}${S}" \
  "caches-1${S}caches${S}delete${S}$H/Library/Caches/b${S}5000000000${S}offerable${S}1:2${S}measured${S}${S}" \
  "large-files-1${S}large-files${S}trash${S}$H/Downloads/c${S}900000000${S}offerable${S}1:3${S}measured${S}${S}" > "$H/items.txt"
EXTRA_NOTES="status.trash${S}measured
status.caches${S}measured
status.docker${S}unmeasured: Docker was not running
status.xcode${S}unmeasured: 
note.xcode${S}Xcode is not installed on this Mac
status.large-files${S}measured" write_record "$H/items.txt" "trash caches xcode docker large-files"
render --out "$OUT"
check "a scan with an unmeasured kind renders with exit 0" "$(eq "$RC" 0)"
check "the unmeasured kind is shown" "$([ -n "$(heading docker)" ] && echo ok || echo "no Docker heading")"
check "its heading is greyed" "$(has "$(heading docker)" 'class="group-head unmeasured"')"
check "its reason stands where the total goes, without the record's prefix" "$(has "$(heading docker)" '<span class="group-reason">Docker was not running</span>')"
check "it has no tick box" "$(grep -q '<input' <<< "$(heading docker)" && echo "it has one" || echo ok)"
check "and no rows beneath it" "$(grep -qE 'class="item[^"]*" data-id="[^"]*"[^>]*>.*data-category="docker"' <<< "$HTML" && echo "a row names it" || echo ok)"
check "so it adds nothing to the bar: only measured kinds carry tick boxes" "$(eq "$(count_of "$HTML" 'class="tick head-tick"')" 3)"
check "a status with no reason of its own takes the kind's note" "$(has "$(heading xcode)" '<span class="group-reason">Xcode is not installed on this Mac</span>')"
order="$(grep -oE '<div class="group-head[^"]*" data-category="[a-z-]+"' <<< "$HTML" | awk -F '"' '{ printf "%s%s", (n++ ? " " : ""), $4 }')"
check "unmeasured kinds come after the measured ones that regenerate, before your own files" "$(eq "$order" "caches trash xcode docker large-files")"
EXTRA_NOTES="status.large-files${S}unmeasured: the walk of the home folder timed out" write_record "$H/items.txt" "trash caches large-files"
awk -F "$S" '$2 != "large-files"' "$H/items.txt" > "$H/items2.txt"
EXTRA_NOTES="status.large-files${S}unmeasured: the walk of the home folder timed out" write_record "$H/items2.txt" "trash caches large-files"
render --out "$OUT"
order="$(grep -oE '<div class="group-head[^"]*" data-category="[a-z-]+"' <<< "$HTML" | awk -F '"' '{ printf "%s%s", (n++ ? " " : ""), $4 }')"
check "an unmeasured kind of your own files still comes last" "$(eq "$order" "caches trash large-files")"
check "and says why" "$(has "$(heading large-files)" "the walk of the home folder timed out")"
: > "$H/items.txt"
EXTRA_NOTES="status.docker${S}unmeasured: Docker was not running" write_record "$H/items.txt" "trash docker"
render --out "$OUT"
check "with nothing found but a kind unmeasured, it never claims the scan found nothing" "$(hasnt "$HTML" "This scan found nothing to remove.")"
check "it says nothing was found in what could be measured" "$(has "$HTML" "Nothing was found to remove in what the scan could measure.")"
check "and still shows the unmeasured kind" "$(has "$(heading docker)" "Docker was not running")"

# A folder partly kept only in iCloud (#1806's icloud-only-part): said in words beside the item, in
# the row's quiet grey, never as an amber mark, which warns about removing.
fresh
printf '%s\n' "build-folders-1${S}build-folders${S}delete${S}$H/Apps/p/node_modules${S}400000000${S}offerable${S}1:1${S}measured${S}icloud-only-part${S}" \
  "build-folders-2${S}build-folders${S}delete${S}$H/Apps/q/node_modules${S}300000000${S}offerable${S}1:2${S}measured${S}credential,icloud-only-part${S}" > "$H/items.txt"
write_record "$H/items.txt" "build-folders"
render --out "$OUT"
check "a folder partly kept only in iCloud says so beside it" "$(has "$(row build-folders-1)" "Partly kept only in iCloud")"
check "in the quiet mark, never the amber one" "$(has "$(row build-folders-1)" '<span class="flag quiet">Partly kept only in iCloud</span>')"
check "and the flag's own name never reaches the page" "$(hasnt "$HTML" "icloud-only-part")"
check "beside a warning, the warning keeps its amber mark" "$(has "$(row build-folders-2)" '<span class="flag">Holds a credential</span>')"
check "and the iCloud note stays quiet" "$(has "$(row build-folders-2)" '<span class="flag quiet">Partly kept only in iCloud</span>')"

# An empty scan says so, rather than drawing an empty page.
fresh
: > "$H/items.txt"
write_record "$H/items.txt" trash
render --out "$OUT"
check "a scan with nothing in it renders with exit 0" "$(eq "$RC" 0)"
check "and says it found nothing" "$(has "$HTML" "This scan found nothing to remove.")"

# ================================================================================================
# 4b. One size rule, written three times because three languages draw sizes: dcu_human (bash, the
#     scan's summary and disk-remove), dcu_h (awk, this page's rows and the checker) and the page's
#     own human() (its selection total). They must agree on every value, boundaries included.
# ================================================================================================
. "$DIR/../../hooks/lib/disk-clean-units.sh" || check "the units library is there to source" "could not source it"
kibs="$(awk 'BEGIN { for (k = 0; k <= 3000; k += 7) print k; for (k = 976540; k <= 976600; k++) print k;
  print 488; print 489; print 976; print 977; print 1220703; print 1220704; print 2441406; print 2441407; print 48828125; print 9765625000 }')"
bash_words="$(while IFS= read -r k; do printf '%s|%s\n' "$k" "$(dcu_human "$k")"; done <<< "$kibs")"
awk_words="$(awk "$DCU_AWK_LIB"'{ printf "%s|%s\n", $1, dcu_h($1) }' <<< "$kibs")"
check "the bash and awk size rules agree on every value" "$(diff <(printf '%s\n' "$bash_words") <(printf '%s\n' "$awk_words") > /dev/null && echo ok || echo "they differ: $(diff <(printf '%s\n' "$bash_words") <(printf '%s\n' "$awk_words") | awk 'NR <= 4' | tr '\n' ' ')")"
fresh
fixture_record
render --out "$OUT"
if command -v node >/dev/null 2>&1; then
  js_human="$(awk '/function human\(bytes\)/ { p = 1 } p { print } p && /^  }/ { exit }' <<< "$HTML")"
  check "the page carries its size rule" "$([ -n "$js_human" ] && echo ok || echo "no human() in the page")"
  js_words="$(node -e "$js_human"'
    require("fs").readFileSync(0, "utf8").trim().split("\n").forEach(function (k) { console.log(k + "|" + human(Number(k) * 1024)); });' <<< "$kibs" 2>&1)"
  check "the page's size rule agrees with the bash one on every value" "$(diff <(printf '%s\n' "$bash_words") <(printf '%s\n' "$js_words") > /dev/null && echo ok || echo "they differ: $(diff <(printf '%s\n' "$bash_words") <(printf '%s\n' "$js_words") | awk 'NR <= 4' | tr '\n' ' ')")"
else
  echo "SUITE-PART-UNMEASURED the page's size rule against the bash one: node is not on PATH"
fi

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
