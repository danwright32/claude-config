#!/usr/bin/env bash
# Tests for make-switcher.py, the tool that builds a design round's switcher page.
#
# Everything here runs against real files in a temp directory. The generator
# touches no network and starts no browser, so there is nothing to stub and no
# clock or sleep to inject.
#
# The regression these tests exist for is real and dated. On 2026-09-07 a
# hand written switcher (round13-dismiss.html) drew a keyboard badge on every
# tab and had no keydown listener at all, so it showed three shortcuts that did
# nothing, and the round before it had working ones. Badges and handler are
# emitted from ONE list here, and a key that cannot be wired is refused rather
# than drawn.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/make-switcher.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
unmeasured=0
check() { # check <description> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
    echo "  expected to contain: $2"
    echo "  actual (first 400 chars): ${3:0:400}"
  fi
}
check_eq() { # check_eq <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (expected '$2', got '$3')"
  fi
}
check_not() { # check_not <description> <forbidden-substring> <actual>
  if [[ "$3" != *"$2"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (output should not contain '$2')"
  fi
}

# --- fixtures ---

printf 'function buildScreen(variant) { var d = document.createElement("div"); d.className = "screen " + variant; return d; }\n' > "$TMP/builder.js"
printf '.screen { color: #111; }\n' > "$TMP/screen.css"

# spec <file> <variants-json> [extra-top-level-json]
spec() {
  local out="$1" variants="$2" extra="${3:-}"
  python3 - "$out" "$variants" "$extra" <<'PY'
import json, sys
out, variants, extra = sys.argv[1], sys.argv[2], sys.argv[3]
s = {
  "title": "Ovation, the rail",
  "round": "Which colour carries the rail",
  "asks": "The rail is twenty times the area of the bands.",
  "measurement": "72 contrast checks, worst 4.83.",
  "builder": "builder.js",
  "styles": "screen.css",
  "variants": json.loads(variants),
}
if extra:
  s.update(json.loads(extra))
open(out, "w").write(json.dumps(s))
PY
}

TWO='[{"key":"1","name":"Espresso","why":"The warm one you settled on, at twenty times the area.","measured":"Worst contrast 5.65."},
      {"key":"2","name":"Ink","why":"Near black, no hue, so this asks whether the panel or the colour was doing the work."}]'

run() { python3 "$SCRIPT" "$@" 2>&1; }

# --- 1. a good spec produces a page carrying every option and its reason ---

spec "$TMP/spec.json" "$TWO"
out="$(run "$TMP/spec.json" "$TMP/out.html")"; rc=$?
check_eq "a good spec exits 0" "0" "$rc"
page="$(cat "$TMP/out.html" 2>/dev/null)"
check "the round title is on the page" "Which colour carries the rail" "$page"
check "what the round asks is on the page" "twenty times the area of the bands" "$page"
check "the round's measurement is on the page" "72 contrast checks" "$page"
check "the first option is named" "Espresso" "$page"
check "the second option is named" "Ink" "$page"
check "the first option's reason is carried" "The warm one you settled on" "$page"
check "the second option's reason is carried" "whether the panel or the colour" "$page"
check "an option's own measurement is carried" "Worst contrast 5.65." "$page"
check "the builder is inlined" "function buildScreen" "$page"
check "the styles are inlined" ".screen { color: #111; }" "$page"

# --- 2. every key badge drawn is a key that actually works ---

check "the page listens for keys" "keydown" "$page"
check "left arrow steps back" "ArrowLeft" "$page"
check "right arrow steps on" "ArrowRight" "$page"
check "the first key is in the data the handler reads" '"key": "1"' "$page"
check "the second key is in the data the handler reads" '"key": "2"' "$page"
check_eq "the page declares its options exactly once" "1" "$(grep -c 'var VARIANTS =' "$TMP/out.html")"
check_eq "the page wires keys exactly once" "1" "$(grep -c 'addEventListener("keydown"' "$TMP/out.html")"

# --- 3. the page needs nothing from the network ---

check_not "no external script" "<script src=" "$page"
check_not "no external stylesheet" "<link" "$page"
check_not "no http reference" "http://" "$page"
check_not "no https reference" "https://" "$page"

# --- 4. a key that cannot be wired is refused, not drawn ---

BAD_KEY='[{"key":"Esc","name":"A","why":"first reason"},{"key":"2","name":"B","why":"second reason"}]'
spec "$TMP/badkey.json" "$BAD_KEY"
out="$(run "$TMP/badkey.json" "$TMP/badkey.html")"; rc=$?
check_eq "a multi character key exits 2" "2" "$rc"
check "the refusal names the variant" "A" "$out"
check "the refusal says what is wrong with the key" "Esc" "$out"
check_eq "nothing is written when a key is refused" "0" "$([ -e "$TMP/badkey.html" ] && echo 1 || echo 0)"

# --- 5. an option with no reason is refused ---

NO_WHY='[{"key":"1","name":"A","why":"first reason"},{"key":"2","name":"B","why":"   "}]'
spec "$TMP/nowhy.json" "$NO_WHY"
out="$(run "$TMP/nowhy.json" "$TMP/nowhy.html")"; rc=$?
check_eq "an option with no reason exits 2" "2" "$rc"
check "the refusal names the option with no reason" "B" "$out"
check_eq "nothing is written when a reason is missing" "0" "$([ -e "$TMP/nowhy.html" ] && echo 1 || echo 0)"

# --- 6. a missing builder is a loud failure, not a page with a dead stage ---

spec "$TMP/nobuilder.json" "$TWO" '{"builder":"absent.js"}'
out="$(run "$TMP/nobuilder.json" "$TMP/nobuilder.html")"; rc=$?
check_eq "a missing builder exits 2" "2" "$rc"
check "the refusal names the missing file" "absent.js" "$out"
check_eq "no page is written for a missing builder" "0" "$([ -e "$TMP/nobuilder.html" ] && echo 1 || echo 0)"

# --- 7. a switcher with nothing to compare is refused ---

ONE='[{"key":"1","name":"Only","why":"the only one"}]'
spec "$TMP/one.json" "$ONE"
out="$(run "$TMP/one.json" "$TMP/one.html")"; rc=$?
check_eq "one option exits 2" "2" "$rc"
check "the refusal says a switcher needs two" "two" "$out"

# --- 8. two options sharing a key are refused ---

DUP='[{"key":"1","name":"A","why":"first reason"},{"key":"1","name":"B","why":"second reason"}]'
spec "$TMP/dup.json" "$DUP"
out="$(run "$TMP/dup.json" "$TMP/dup.html")"; rc=$?
check_eq "a repeated key exits 2" "2" "$rc"
check "the refusal names the repeated key" "1" "$out"

# --- 9. an unreadable spec says so rather than crashing ---

printf '{ not json\n' > "$TMP/broken.json"
out="$(run "$TMP/broken.json" "$TMP/broken.html")"; rc=$?
check_eq "a broken spec exits 2" "2" "$rc"
check "a broken spec is reported as unreadable" "read" "$out"
check_not "a broken spec does not print a traceback" "Traceback" "$out"

out="$(run "$TMP/absent-spec.json" "$TMP/x.html")"; rc=$?
check_eq "a missing spec exits 2" "2" "$rc"
check "a missing spec names the file" "absent-spec.json" "$out"

# --- 10. usage ---

out="$(run)"; rc=$?
check_eq "no arguments exits 2" "2" "$rc"
check "no arguments prints usage" "Usage:" "$out"

# --- 11. the keys actually work, proved in a browser engine ---
#
# The checks above read the emitted source, and source cannot tell a wired key from a
# drawn one: that is exactly the regression this tool exists to stop. So the page is
# loaded in real Chrome, keys are dispatched, and the rendered result is read back.
# When Chrome is not on this machine the section reports UNMEASURED rather than passing,
# because a check that silently skips is indistinguishable from one that succeeded.

CHROME="${SWITCHER_TEST_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

probe() { # probe <page> -> the readout heading at the start and after each key
  python3 - "$1" <<'PROBEPY'
import sys
page = open(sys.argv[1], encoding="utf-8").read()
harness = """
<script>
function heading() { return document.querySelector(".dr-readout h2").textContent; }
var log = [heading()];
["ArrowRight", "1", "2", "ArrowLeft"].forEach(function (k) {
  document.dispatchEvent(new KeyboardEvent("keydown", {key: k, bubbles: true}));
  log.push(heading());
});
var out = document.createElement("pre"); out.id = "PROBE"; out.textContent = log.join(",");
document.body.append(out);
</script>
"""
open(sys.argv[1] + ".probe.html", "w", encoding="utf-8").write(page + harness)
PROBEPY
  "$CHROME" --headless --disable-gpu --no-sandbox --virtual-time-budget=2000 \
    --dump-dom "file://$1.probe.html" 2>/dev/null \
    | python3 -c 'import sys,re; m=re.search(r"<pre id=\"PROBE\">(.*?)</pre>", sys.stdin.read(), re.S); print(m.group(1) if m else "NO-PROBE")'
}

if [[ ! -x "$CHROME" ]]; then
  echo "UNMEASURED: no browser at $CHROME, so the keyboard wiring was not tested. Set SWITCHER_TEST_CHROME."
  unmeasured=1
else
  keys="$(probe "$TMP/out.html")"
  check_eq "arrows and jump keys move between the options" "Espresso,Ink,Espresso,Ink,Espresso" "$keys"

  # The mutant: the same page with its key handler removed, which is exactly what a hand
  # written switcher did on 2026-09-07 while still drawing the badges on every tab.
  python3 - "$TMP/out.html" "$TMP/mutant.html" <<'MUTPY'
import sys
page = open(sys.argv[1], encoding="utf-8").read()
start = page.index('document.addEventListener("keydown"')
end = page.index("show(0);", start)
open(sys.argv[2], "w", encoding="utf-8").write(page[:start] + page[end:])
MUTPY
  mutant="$(probe "$TMP/mutant.html")"
  check_eq "a page whose keys are not wired is caught" "Espresso,Espresso,Espresso,Espresso,Espresso" "$mutant"
fi


# --- 12. the committed example is what the tool produces today ---
#
# example/switcher.html is generated and committed beside its own source, so it goes
# stale silently the first time the generator changes. This regenerates it into a temp
# file and compares, so a drifted example is a failure rather than a surprise later.

python3 "$SCRIPT" "$DIR/example/spec.json" "$TMP/example-now.html" >/dev/null 2>&1
check_eq "the committed example matches what the tool produces now" \
  "$(shasum "$DIR/example/switcher.html" | cut -d' ' -f1)" \
  "$(shasum "$TMP/example-now.html" | cut -d' ' -f1)"

# --- 13. the page fills the window, and a tall screen is never clipped ---
#
# Dan opened the first page this tool produced and said "there's weird dead grey space
# at the bottom". Measured at 1440x900 it was 261px of empty background under the last
# element, because the shell sat at its natural height at the top of the window. The
# stage now takes the space that is left, which raises the opposite risk: a screen
# taller than the window, centred with align-items, has its top cut off and unreachable.
# Both are measured here in a real browser, at a viewport this test sets itself.

geometry() { # geometry <page> <viewport-height> -> one line per measurement
  python3 - "$1" <<'GEOMPY'
import sys
page = open(sys.argv[1], encoding="utf-8").read()
harness = """
<script>
function box(sel) {
  var e = document.querySelector(sel);
  if (!e) return sel + " missing";
  var r = e.getBoundingClientRect();
  return sel + " top=" + Math.round(r.top) + " bottom=" + Math.round(r.bottom) +
         " centre=" + Math.round(r.x + r.width / 2);
}
var last = document.querySelector(".dr-hint").getBoundingClientRect().bottom;
var screenTop = document.querySelector(".dr-stage > *").getBoundingClientRect().top;
var lines = [
  "viewport-centre " + window.innerWidth / 2,
  "dead-space-below " + Math.round(window.innerHeight - last),
  "screen-top " + Math.round(screenTop),
  box(".dr-stage")
];
var out = document.createElement("pre"); out.id = "G"; out.textContent = lines.join("\\n");
document.body.append(out);
</script>
"""
open(sys.argv[1] + ".geom.html", "w", encoding="utf-8").write(page + harness)
GEOMPY
  "$CHROME" --headless --disable-gpu --no-sandbox --window-size=1440,"$2" \
    --virtual-time-budget=2000 --dump-dom "file://$1.geom.html" 2>/dev/null \
    | python3 -c 'import sys,re; m=re.search(r"<pre id=\"G\">(.*?)</pre>", sys.stdin.read(), re.S); print(m.group(1) if m else "NO-GEOM")'
}

if [[ -x "$CHROME" ]]; then
  g="$(geometry "$TMP/out.html" 900)"
  dead="$(echo "$g" | awk '/dead-space-below/ {print $2}')"
  check_eq "the page leaves no dead space under a short screen" "1" \
    "$([ -n "$dead" ] && [ "$dead" -le 48 ] && echo 1 || echo "0 (measured ${dead:-none}px)")"
  check "the stage is centred on the window" "centre 720" \
    "$(echo "$g" | awk '/viewport-centre/ {print "centre", $2}')"
  check_eq "the stage sits on the window centre line" "720" \
    "$(echo "$g" | awk '/^.dr-stage/ {for(i=1;i<=NF;i++) if ($i ~ /^centre=/) {sub("centre=","",$i); print $i}}')"

  # A screen taller than the window must not have its top cut off, which is what
  # centring an overflowing flex item does.
  python3 - "$TMP/tallspec.json" <<'TALLPY'
import json, sys
spec = json.load(open(sys.argv[1].replace("tallspec.json", "spec.json")))
open(sys.argv[1], "w").write(json.dumps(spec))
TALLPY
  printf 'function buildScreen(variant) { var d = document.createElement("div"); d.className = "screen"; d.style.height = "2000px"; d.style.width = "400px"; d.style.background = "#DDD"; return d; }\n' > "$TMP/tall-builder.js"
  python3 - "$TMP/tallspec.json" "$TMP/tall.json" <<'TALLSPEC'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "tall-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
TALLSPEC
  python3 "$SCRIPT" "$TMP/tall.json" "$TMP/tall.html" >/dev/null 2>&1
  gt="$(geometry "$TMP/tall.html" 900)"
  top="$(echo "$gt" | awk '/screen-top/ {print $2}')"
  stagetop="$(echo "$gt" | awk '/^.dr-stage/ {for(i=1;i<=NF;i++) if ($i ~ /^top=/) {sub("top=","",$i); print $i}}')"
  check_eq "a screen taller than the window keeps its top reachable" "1" \
    "$([ -n "$top" ] && [ -n "$stagetop" ] && [ "$top" -ge "$stagetop" ] && echo 1 || echo "0 (screen top ${top:-none} is above stage top ${stagetop:-none})")"
fi


# --- 14. the picker's options are emitted from the spec, not retyped ---
#
# The round closes with an AskUserQuestion picker carrying one option per tab, each
# labelled as the tab is and described by what that option is testing. Those are the
# same two facts the switcher already draws, so retyping them by hand is a second
# derivation that drifts: the picker ends up naming an option differently from the tab
# on screen, or giving a different reason for it, and the person comparing has to
# reconcile the two. The tool writes them beside the page instead.

spec "$TMP/spec.json" "$TWO"
out="$(run "$TMP/spec.json" "$TMP/out.html")"; rc=$?
check_eq "a good spec still exits 0" "0" "$rc"
check_eq "the picker options are written beside the page" "1" \
  "$([ -e "$TMP/out.picker.json" ] && echo 1 || echo 0)"
check "the run says where the picker options went" "out.picker.json" "$out"

picker="$(cat "$TMP/out.picker.json" 2>/dev/null)"
check_eq "there is one option per switcher tab and no extra escape option" "2" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["options"]))' "$TMP/out.picker.json" 2>/dev/null)"
check_eq "the first option is labelled as its tab is" "Espresso" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["options"][0]["label"])' "$TMP/out.picker.json" 2>/dev/null)"
check_eq "the options are in the switcher's own order" "Ink" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["options"][1]["label"])' "$TMP/out.picker.json" 2>/dev/null)"
check "an option is described by what it is testing" "asks whether the panel or the colour" "$picker"
check "an option's measured number rides with its description" "Worst contrast 5.65." "$picker"
check "the picker asks the round's own question" "Which colour carries the rail" "$picker"
check_not "no none of these option is offered" "one of these" "$picker"

# The refusals must not leave a picker list behind either: a stale options file beside a
# page that was never written is a list of options nobody can look at.
rm -f "$TMP/nowhy.html" "$TMP/nowhy.picker.json"
spec "$TMP/nowhy.json" "$NO_WHY"
run "$TMP/nowhy.json" "$TMP/nowhy.html" >/dev/null 2>&1
check_eq "a refused round writes no picker options" "0" \
  "$([ -e "$TMP/nowhy.picker.json" ] && echo 1 || echo 0)"

# The committed example carries its picker list too, guarded the same way the page is.
python3 "$SCRIPT" "$DIR/example/spec.json" "$TMP/example-now.html" >/dev/null 2>&1
# Both sides are asserted PRESENT first: shasum of a missing file is empty, so a bare
# hash comparison passes when neither exists and measures nothing at all.
check_eq "the example ships a committed picker list" "1" \
  "$([ -s "$DIR/example/switcher.picker.json" ] && echo 1 || echo 0)"
check_eq "regenerating the example produces a picker list" "1" \
  "$([ -s "$TMP/example-now.picker.json" ] && echo 1 || echo 0)"
check_eq "the committed example's picker options match what the tool produces now" \
  "$(shasum "$DIR/example/switcher.picker.json" 2>/dev/null | cut -d' ' -f1)x" \
  "$(shasum "$TMP/example-now.picker.json" 2>/dev/null | cut -d' ' -f1)x"

# --- the chrome must not collide with the project's own class names ---
#
# Dated regression, 2026-09-08, PaperBoi round 63. The chrome styled a class it
# called `frame` with `max-width: 1180px`. A project builder that also called its
# element `frame` inherited that ceiling, so three options declaring 1100, 1440 and
# 1720 all rendered at 1180: identical pictures under three different labels, with
# the readout confidently naming three widths. Nothing refused, because the page was
# structurally fine. It was caught by a person noticing the pictures matched.
#
# The fix is a namespace the project cannot reach by accident, so this asserts the
# namespace itself rather than the one name that happened to collide.

chrome_classes() { # chrome_classes <page> -> one class selector per line, chrome block only
  python3 - "$1" <<'CHROMEPY'
import re, sys
page = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"<style>(.*?)</style>", page, re.S)
if len(blocks) < 1:
    print("NO-STYLE-BLOCK")
    raise SystemExit
# The FIRST block is the tool's own chrome; the second is the project's stylesheet.
for name in sorted(set(re.findall(r"\.([A-Za-z][\w-]*)", blocks[0]))):
    print(name)
CHROMEPY
}

# Its own spec and its own output file: a test that reads a path an earlier test
# wrote is judging that test's output, not its own.
spec "$TMP/ns.json" '[{"key":"1","name":"A","why":"first"},{"key":"2","name":"B","why":"second"}]'
python3 "$SCRIPT" "$TMP/ns.json" "$TMP/ns.html" || fail=$((fail + 1))
bare="$(chrome_classes "$TMP/ns.html" | grep -v '^dr-' | tr '\n' ' ')"
check_eq "every class the chrome styles is namespaced, so a project cannot collide with one" "" "${bare% }"

# The project's own stylesheet is left alone: namespacing the chrome must not rewrite
# the project's classes, or every existing round's builder stops being styled.
check "the project's own class is untouched in its own block" ".screen { color: #111; }" \
  "$(cat "$TMP/ns.html")"

if [[ -x "$CHROME" ]]; then
  # End to end, the exact failure: a builder whose element is called `frame` and asks
  # for 1400px must be 1400px on the page, not clamped to the chrome's ceiling.
  printf 'function buildScreen(variant) { var d = document.createElement("div"); d.className = "frame"; d.style.width = "1400px"; d.style.height = "200px"; return d; }\n' > "$TMP/collide-builder.js"
  python3 - "$TMP/ns.json" "$TMP/collide.json" <<'COLLIDE'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "collide-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
COLLIDE
  python3 "$SCRIPT" "$TMP/collide.json" "$TMP/collide.html" || fail=$((fail + 1))
  width="$(python3 - "$TMP/collide.html" <<'WIDTHPY'
import sys
page = open(sys.argv[1], encoding="utf-8").read()
harness = """
<script>
var e = document.querySelector(".dr-stage > *");
var out = document.createElement("pre"); out.id = "W";
out.textContent = e ? String(Math.round(e.getBoundingClientRect().width)) : "missing";
document.body.append(out);
</script>
"""
open(sys.argv[1] + ".w.html", "w", encoding="utf-8").write(page + harness)
WIDTHPY
  "$CHROME" --headless --disable-gpu --no-sandbox --window-size=1900,900 \
    --virtual-time-budget=2000 --dump-dom "file://$TMP/collide.html.w.html" 2>/dev/null \
    | python3 -c 'import sys,re; m=re.search(r"<pre id=\"W\">(.*?)</pre>", sys.stdin.read(), re.S); print(m.group(1).strip() if m else "NO-WIDTH")')"
  check_eq "a project element named like the chrome keeps its own width" "1400" "$width"
fi


# --- the chrome's JAVASCRIPT must not collide with the project's own either ---
#
# claude-config#355, 2026-09-10. The chrome kept its state in top level globals: tabs,
# stage, readout, current, show and el. The builder is a second top level script in the
# same page, so a project that declares any of those names wins or loses by script order,
# silently. Ovation's clients.html declares var stage and var tabs, and both design files
# declare function el.
#
# The symptom is the same one the CSS collision above produced: EVERY OPTION DRAWS THE
# IDENTICAL SCREEN, which is exactly what a round whose options do not differ looks like,
# so the tool reports nothing and the round reads as a real finding about the design.
#
# Same remedy as the CSS: a namespace the project cannot reach by accident. For script
# that means a scope, so the assertion is on the SCOPE rather than on the six names that
# happened to collide.

chrome_globals() { # chrome_globals <page> -> one top level declaration per line, chrome block only
  python3 - "$1" <<'GLOBPY'
import re, sys
page = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"<script>(.*?)</script>", page, re.S)
if len(blocks) < 2:
    print("NO-CHROME-SCRIPT")
    raise SystemExit
# The FIRST script block is the project's builder; the SECOND is the tool's own chrome.
for line in blocks[1].split("\n"):
    m = re.match(r"^(?:var|let|const|function)\s+([A-Za-z_$][\w$]*)", line)
    if m:
        print(m.group(1))
GLOBPY
}

spec "$TMP/js.json" '[{"key":"1","name":"A","why":"first"},{"key":"2","name":"B","why":"second"}]'
python3 "$SCRIPT" "$TMP/js.json" "$TMP/js.html" || fail=$((fail + 1))
leaked="$(chrome_globals "$TMP/js.html" | tr '\n' ' ')"
check_eq "the chrome's script declares nothing at the page's top level" "" "${leaked% }"
# And the block is really there, so the check above is not passing because the extractor
# found no script at all and printed nothing (L98).
check "the chrome's script block was found to look at" "VARIANTS" "$(cat "$TMP/js.html")"

# The page says so when two options draw the same thing, rather than looking finished. The
# tool cannot know this at build time, because the drawing happens in the browser, so the
# refusal lives where the information is.
check "the page checks its options actually differ" "draw the same" "$(cat "$TMP/js.html")"

if [[ -x "$CHROME" ]]; then
  render() { # render <page> -> the stage's markup after load
    "$CHROME" --headless --disable-gpu --no-sandbox --virtual-time-budget=2000 \
      --dump-dom "file://$1" 2>/dev/null \
      | python3 -c 'import sys,re; m=re.search(r"<div class=\"dr-stage\"[^>]*>(.*?)</div>\s*<p class=\"dr-hint\"", sys.stdin.read(), re.S); print((m.group(1).strip() if m else "NO-STAGE")[:200])'
  }

  # The exact failure: a builder holding the same names AND reassigning them while it
  # draws, which is what makes the page's own tabs and stage stop being the page's.
  cat > "$TMP/collide-js-builder.js" <<'JSB'
var tabs = null;
var stage = null;
function el(tag) { return document.createElement(tag); }
function buildScreen(variant) {
  tabs = { children: [] };
  stage = document.createElement("div");
  var d = el("div");
  d.className = "screen";
  d.textContent = "drawn:" + variant.name;
  return d;
}
JSB
  python3 - "$TMP/js.json" "$TMP/collide-js.json" <<'CJ'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "collide-js-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
CJ
  python3 "$SCRIPT" "$TMP/collide-js.json" "$TMP/collide-js.html" || fail=$((fail + 1))
  first="$(render "$TMP/collide-js.html")"
  check "a builder holding the chrome's own names still draws its option" "drawn:A" "$first"

  # And the option really CHANGES, which is the half the symptom hides: a page stuck on
  # option one looks exactly like a page whose options are identical.
  # show() is deliberately NOT reachable from outside the scope any more, so the page is
  # driven by the key the badge advertises instead, which is what a person actually presses.
  python3 - "$TMP/collide-js.html" "$TMP/collide-js-key.html" <<'KEYED'
import sys
page = open(sys.argv[1], encoding="utf-8").read()
harness = """
<script>
document.dispatchEvent(new KeyboardEvent("keydown", {key: "2", bubbles: true}));
</script>
"""
open(sys.argv[2], "w", encoding="utf-8").write(page.replace("</body>", harness + "</body>"))
KEYED
  second="$(render "$TMP/collide-js-key.html")"
  check "pressing the second option's key draws the second option" "drawn:B" "$second"

  # A builder that ignores its argument draws one picture under every label. The tool
  # cannot see that at build time, so the page has to say it (L98, L11).
  printf 'function buildScreen(variant) { var d = document.createElement("div"); d.textContent = "always the same"; return d; }\n' \
    > "$TMP/same-builder.js"
  python3 - "$TMP/js.json" "$TMP/same.json" <<'SAME'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "same-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
SAME
  python3 "$SCRIPT" "$TMP/same.json" "$TMP/same.html" || fail=$((fail + 1))
  same_dom="$("$CHROME" --headless --disable-gpu --no-sandbox --virtual-time-budget=2000 \
    --dump-dom "file://$TMP/same.html" 2>/dev/null)"
  # Matched on the RENDERED attribute, not the bare class name: the script that can build
  # the strip names it too, and a check the source satisfies would pass on every page.
  check "a page whose options draw the same thing says so" 'class="dr-sameness"' "$same_dom"
  check "and it names which options matched" "A and B" "$same_dom"

  # The control: options that genuinely differ must NOT carry the warning, or the notice
  # is on every page and means nothing (L36, L159).
  differ_dom="$("$CHROME" --headless --disable-gpu --no-sandbox --virtual-time-budget=2000 \
    --dump-dom "file://$TMP/collide-js.html" 2>/dev/null)"
  check_not "a page whose options differ carries no warning" 'class="dr-sameness"' "$differ_dom"
else
  unmeasured=$((unmeasured + 1))
  echo "UNMEASURED: no headless Chrome, so the script collision was checked in the source only"
fi


# --- and the last two surfaces the chrome shares with the project (claude-config#356) ---
#
# Third instance of one pattern. The style names were namespaced after PaperBoi round 63,
# the script moved into its own scope after claude-config#355, and the same two words were
# still sitting on the elements as bare ids, with a keydown listener on the whole document
# beside them. Each namespace left open fails the identical silent way, and the remedy
# keeps being scoped to whichever one the last incident named (L452).
#
# So this asserts the NAMESPACE, derived from the chrome's own markup, rather than the
# three ids that happen to be there today.

chrome_ids() { # chrome_ids <page> -> one id per line, from the chrome's own markup only
  python3 - "$1" <<'IDPY'
import re, sys
page = open(sys.argv[1], encoding="utf-8").read()
body = page.split("<body>", 1)[-1].split("<script>", 1)[0]
found = re.findall(r'\bid="([^"]+)"', body)
if not found:
    print("NO-IDS-FOUND")
for name in sorted(set(found)):
    print(name)
IDPY
}

bare_ids="$(chrome_ids "$TMP/js.html" | grep -v '^dr-' | tr '\n' ' ')"
check_eq "every id the chrome puts on the page is namespaced" "" "${bare_ids% }"
# The extractor really found the markup, so the check above is not passing on an empty read.
check_not "the id extractor read the chrome's markup" "NO-IDS-FOUND" "$(chrome_ids "$TMP/js.html")"

# The keydown listener is the other shared surface, and it cannot simply move: the page has
# nothing focusable, so scoping it to the frame would stop the arrow keys working at all.
# It YIELDS instead. A project that claims a key gets it, because the project's screen is
# the thing being judged, and a key typed into the design is the design's, not a shortcut.
check "the chrome stands down on a key the project claimed" "defaultPrevented" "$(cat "$TMP/js.html")"
check "the chrome stands down inside a field" "isContentEditable" "$(cat "$TMP/js.html")"

if [[ -x "$CHROME" ]]; then
  # A builder that binds its own arrow and digit keys. Both listeners are on the document
  # and the builder's is registered first, so it runs first: if it claims the key, the tab
  # strip must not also move.
  cat > "$TMP/keys-builder.js" <<'KB'
document.addEventListener("keydown", function (event) {
  if (event.key === "2") { event.preventDefault(); }
});
function buildScreen(variant) {
  var d = document.createElement("div");
  d.textContent = "drawn:" + variant.name;
  return d;
}
KB
  python3 - "$TMP/js.json" "$TMP/keys.json" <<'KJ'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "keys-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
KJ
  python3 "$SCRIPT" "$TMP/keys.json" "$TMP/keys.html" || fail=$((fail + 1))

  press() { # press <page> <key> <out> -> renders after that key is pressed
    python3 - "$1" "$2" "$3" <<'PRESS'
import sys
page = open(sys.argv[1], encoding="utf-8").read()
harness = '<script>document.dispatchEvent(new KeyboardEvent("keydown", {key: "%s", bubbles: true, cancelable: true}));</script>' % sys.argv[2]
open(sys.argv[3], "w", encoding="utf-8").write(page.replace("</body>", harness + "</body>"))
PRESS
    render "$3"
  }

  check "a key the project claimed does not also move the tabs" "drawn:A" \
    "$(press "$TMP/keys.html" 2 "$TMP/keys-2.html")"
  # The control: a key the project did NOT claim still works, or the yield has simply
  # turned the shortcuts off (L159). Its own builder, because the shared fixture writes the
  # option into a class and leaves the element empty, so a check for the name would be
  # looking for text that is never drawn whatever the keys do.
  printf 'function buildScreen(variant) { var d = document.createElement("div"); d.textContent = "drawn:" + variant.name; return d; }\n' \
    > "$TMP/plain-builder.js"
  python3 - "$TMP/js.json" "$TMP/plain.json" <<'PJ'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "plain-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
PJ
  python3 "$SCRIPT" "$TMP/plain.json" "$TMP/plain.html" || fail=$((fail + 1))
  check "the option drawn before any key is the first one" "drawn:A" "$(render "$TMP/plain.html")"
  check "a key the project left alone still works" "drawn:B" \
    "$(press "$TMP/plain.html" 2 "$TMP/plain-2.html")"
  check "the arrow keys still step through the options" "drawn:B" \
    "$(press "$TMP/plain.html" ArrowRight "$TMP/plain-right.html")"

  # A design carrying a text field: typing its own key into it must not jump tabs.
  cat > "$TMP/field-builder.js" <<'FB'
function buildScreen(variant) {
  var d = document.createElement("div");
  d.textContent = "drawn:" + variant.name;
  var input = document.createElement("input");
  input.id = "typed";
  d.appendChild(input);
  return d;
}
FB
  python3 - "$TMP/js.json" "$TMP/field.json" <<'FJ'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "field-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
FJ
  python3 "$SCRIPT" "$TMP/field.json" "$TMP/field.html" || fail=$((fail + 1))
  python3 - "$TMP/field.html" "$TMP/field-typed.html" <<'TYPED'
import sys
page = open(sys.argv[1], encoding="utf-8").read()
harness = """
<script>
var box = document.getElementById("typed");
box.focus();
box.dispatchEvent(new KeyboardEvent("keydown", {key: "2", bubbles: true, cancelable: true}));
</script>
"""
open(sys.argv[2], "w", encoding="utf-8").write(page.replace("</body>", harness + "</body>"))
TYPED
  check "a key typed into the design's own field does not jump tabs" "drawn:A" \
    "$(render "$TMP/field-typed.html")"
else
  unmeasured=$((unmeasured + 1))
  echo "UNMEASURED: no headless Chrome, so the key yielding was checked in the source only"
fi

# A builder that THROWS is the third answer the page can give about sameness, and it needs
# a case that produces it: an outcome a contract enumerates and no test reaches is a branch
# nobody has run (L151). It must not read as "the options are fine", and it must say what
# it could not do rather than what it found.
if [[ -x "$CHROME" ]]; then
  printf 'function buildScreen(variant) { throw new Error("no canvas here"); }\n' > "$TMP/throw-builder.js"
  python3 - "$TMP/js.json" "$TMP/throw.json" <<'TJ'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "throw-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
TJ
  python3 "$SCRIPT" "$TMP/throw.json" "$TMP/throw.html" || fail=$((fail + 1))
  # Read the STRIP's own text, not the whole document: the script that can build either
  # sentence carries both of them, so a check against the raw dump passes on every page.
  strip_text() { # strip_text <page> -> what the warning strip actually says, or NO-STRIP
    "$CHROME" --headless --disable-gpu --no-sandbox --virtual-time-budget=2000 \
      --dump-dom "file://$1" 2>/dev/null \
      | python3 -c 'import sys,re
m = re.search(r"<p class=\"dr-sameness\">(.*?)</p>", sys.stdin.read(), re.S)
print(re.sub(r"\s+", " ", m.group(1)).strip() if m else "NO-STRIP")'
  }
  throw_strip="$(strip_text "$TMP/throw.html")"
  check "a builder that throws is reported as unchecked" "could not be checked" "$throw_strip"
  check "and the strip quotes what the builder actually said" "no canvas here" "$throw_strip"
  # It must not make the CLASH CLAIM, which is a different thing from not using the clash
  # sentence's words: this strip says "whether these options draw the same picture could
  # not be checked", which contains those words while asserting the opposite. The claim is
  # NAMING a pair, so that is what is checked (L347).
  check_not "it does not also name a pair as matching" "A and B" "$throw_strip"
fi

# --- the names that refusal protects come FROM the template, not from a list beside it ---
#
# The refusal below shipped holding its own tuple of the three names, two hundred lines from
# the markup that defines them. Add a fourth element with an id and the refusal would not
# know, silently, which is the same fault as the two lists of merge tools and the namespaces
# that were each closed one incident at a time this session (L41, L452). Derived, so the
# fourth element is protected by the code that already exists.

ids_from() { # ids_from <page text> -> the names the tool derives from it
  python3 - "$DIR" "$1" <<'IDSPY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ms", sys.argv[1] + "/make-switcher.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(",".join(mod.chrome_ids(sys.argv[2])))
IDSPY
}

check_eq "the names are read out of the real template" "readout,stage,tabs" \
  "$(ids_from "$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('ms', '$DIR/make-switcher.py')
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(mod.PAGE)")")"

# The one that proves it is DERIVED rather than a tuple that happens to agree: a page
# carrying a fourth element is protected without anybody editing the refusal.
check_eq "a fourth element in the template is protected too" "notes,readout,stage,tabs" \
  "$(ids_from '<div id="dr-stage"></div><div id="dr-tabs"></div><div id="dr-readout"></div><div id="dr-notes"></div>')"

# A page it can read nothing out of would leave the refusal protecting nothing while still
# reporting a clean build, which is the one outcome a derived list can fail into (L98).
check_eq "a template with no namespaced ids derives nothing" "" "$(ids_from '<div id="stage"></div>')"

# And the list the tool ACTUALLY uses is not empty, because a derived list that came back
# with nothing would leave the refusal protecting nothing while every case above still
# passed (L98). Read from the constant the refusal reads, not from a fresh derivation, so
# this is about what ships rather than about the function in isolation.
live_ids="$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('ms', '$DIR/make-switcher.py')
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(len(mod.CHROME_IDS))")"
check_eq "the refusal ships with the template's three names" "3" "$live_ids"

# --- a builder that reaches for the page's own element is refused, not left to throw ---
#
# Found by looking at the real design files after namespacing the ids (claude-config#356).
# Four of Ovation's carry a standalone bootstrap line, document.getElementById("stage")
# .replaceChildren(...), because each is a page in its own right with its own stage. Lift
# the script out as a builder and that line used to find the CHROME's stage and write into
# it, which show() then replaced: wasteful and silent, but it survived. With the ids
# namespaced it finds nothing and throws part way through the builder, so whatever the file
# declares below that line never runs.
#
# The namespace is still right, and the answer is not to give the id back. It is to say so
# at build time, in the tool that already refuses a missing buildScreen and an unwirable
# key, rather than let the page throw at load where the cause is nowhere near the symptom.

reaches_builder() { # reaches_builder <file> <expression>
  printf 'function buildScreen(variant) { %s; return document.createElement("div"); }\n' "$2" > "$1"
}

for reach in 'document.getElementById("stage")' \
             'document.getElementById("tabs")' \
             'document.getElementById("readout")' \
             'document.querySelector("#stage")'; do
  reaches_builder "$TMP/reach-builder.js" "$reach"
  python3 - "$TMP/js.json" "$TMP/reach.json" <<'RJ'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "reach-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
RJ
  out="$(run "$TMP/reach.json" "$TMP/reach.html")"; rc=$?
  # 2 is this tool's refusal code, the same one every other refusal here exits with.
  check_eq "a builder reaching for the page's own element is refused: $reach" "2" "$rc"
  check "the refusal names what the builder reached for: $reach" "stage" "$out$reach"
  check "the refusal says to return the element instead: $reach" "return" "$out"
done
# It must name the file, because the person is looking at a spec and a builder and needs to
# know which one to open (L80).
check "the refusal names the builder file" "reach-builder.js" "$out"
# A text match knows the spellings it was given and no others, and a builder that computes
# the name simply finds nothing at load. The message says so rather than implying the check
# is exhaustive, because a refusal that overstates what it measured is the reason somebody
# trusts it the next time it stays quiet (L11, L440).
check "the refusal says its matching is a text scan" "text match" "$out"

# The control: an ordinary builder is untouched, or this refusal has simply stopped the
# tool working (L159). Its own spec, so it is not reading a file another case wrote.
printf 'function buildScreen(variant) { var d = document.createElement("div"); d.textContent = variant.name; return d; }\n' \
  > "$TMP/fine-builder.js"
python3 - "$TMP/js.json" "$TMP/fine.json" <<'FJ'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "fine-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
FJ
run "$TMP/fine.json" "$TMP/fine.html" >/dev/null; check_eq "an ordinary builder still builds" "0" "$?"

# And a builder that names the chrome's NAMESPACED element is left alone: that is a
# deliberate reach at something that exists, not a name it expected to be its own.
reaches_builder "$TMP/ns-reach-builder.js" 'document.getElementById("dr-stage")'
python3 - "$TMP/js.json" "$TMP/ns-reach.json" <<'NJ'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "ns-reach-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
NJ
run "$TMP/ns-reach.json" "$TMP/ns-reach.html" >/dev/null
check_eq "reaching for the namespaced element is not refused" "0" "$?"

# --- how many times the builder is asked to draw (claude-config#357) ---
#
# The sameness check draws every option once at load. Left beside a show() that redraws on
# every press, that is one MORE call per option than before, and for a builder that does
# anything besides return a picture (touches the page itself, starts a fetch, keeps state
# between calls) the extra call happens far away from anything that would explain it.
#
# The answer is to draw each option ONCE and keep it, which is what the sameness check
# already has to do anyway. That is strictly fewer calls than before the check existed,
# where every press rebuilt, so the cost question closes rather than being traded.

if [[ -x "$CHROME" ]]; then
  cat > "$TMP/counting-builder.js" <<'CB'
var calls = 0;
function buildScreen(variant) {
  calls = calls + 1;
  var d = document.createElement("div");
  d.textContent = "drawn:" + variant.name + " calls:" + calls;
  return d;
}
CB
  python3 - "$TMP/js.json" "$TMP/counting.json" <<'CJ'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["builder"] = "counting-builder.js"
json.dump(spec, open(sys.argv[2], "w"))
CJ
  python3 "$SCRIPT" "$TMP/counting.json" "$TMP/counting.html" || fail=$((fail + 1))

  # Two options, so two calls, ever. The first option shows the first of them.
  check "each option is drawn once at load" "drawn:A calls:1" "$(render "$TMP/counting.html")"

  # Walking away and back must not draw it again. Three presses, and the number the second
  # option carries is the one it was given at load.
  python3 - "$TMP/counting.html" "$TMP/counting-walk.html" <<'WALK'
import sys
page = open(sys.argv[1], encoding="utf-8").read()
harness = """
<script>
function press(k) {
  document.dispatchEvent(new KeyboardEvent("keydown", {key: k, bubbles: true, cancelable: true}));
}
press("2"); press("1"); press("2");
</script>
"""
open(sys.argv[2], "w", encoding="utf-8").write(page.replace("</body>", harness + "</body>"))
WALK
  check "revisiting an option does not draw it again" "drawn:B calls:2" \
    "$(render "$TMP/counting-walk.html")"
else
  unmeasured=$((unmeasured + 1))
  echo "UNMEASURED: no headless Chrome, so how often the builder is called was not counted"
fi

echo
echo "passed: $pass, failed: $fail"
[[ "$unmeasured" -gt 0 ]] && echo "UNMEASURED-SECTIONS $unmeasured"
# The runner parses this exact shape, so nothing else goes on this line.
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
