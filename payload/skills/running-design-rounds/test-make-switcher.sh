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
function heading() { return document.querySelector("#readout h2").textContent; }
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


echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s unmeasured=%s\n' "$pass" "$fail" "$unmeasured"
[[ "$fail" -eq 0 ]]
