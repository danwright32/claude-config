#!/usr/bin/env python3
"""make-switcher.py: build one design round's switcher page.

    python3 make-switcher.py <spec.json> <out.html>

A design round shows several versions of ONE screen, differing in ONE variable,
and lets the person swap between them in place. This writes that page: the tabs,
the keyboard wiring, the readout that says what each option is testing, and a
stage the project's own builder draws the screen into.

It writes NOTHING when it refuses. A switcher with a dead frame, an option with
no reason next to it, or a key badge that is not wired to anything is worse than
no page at all, because each one looks finished.

The spec, with paths resolved against the spec file's own directory:

    {
      "title":       "Ovation, the rail",         the product and surface
      "round":       "Which colour carries it",   the question this round asks
      "asks":        "one or two sentences",      why the round exists (optional)
      "measurement": "72 checks, worst 4.83",     what was measured (optional)
      "builder":     "builder.js",                defines buildScreen(variant)
      "styles":      "screen.css",                optional, inlined
      "variants": [
        {"key": "1", "name": "Espresso",
         "why": "what this option is testing",
         "measured": "the number behind it"}      optional
      ]
    }

buildScreen(variant) receives the whole variant object and returns one element:
the entire screen, chrome included. Every option goes through that one function
with one field changed between them, which is what makes "everything else held
byte identical" structural rather than a promise.

Beside the page it writes <out>.picker.json, the options for the picker the round
closes with: one per tab, in the same order, labelled as the tab is and described
by what that option is testing. The tab and the picker entry are the same two
facts, so they are emitted from one list rather than retyped, which is the drift
this tool already exists to stop for the keyboard shortcuts.
"""

import json
import os
import re
import sys

KEY = re.compile(r"^[0-9a-z]$")


def fail(message):
    print("make-switcher: " + message, file=sys.stderr)
    sys.exit(2)


def read_file(path, what):
    if not os.path.isfile(path):
        fail("the %s file is not there: %s" % (what, path))
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as err:
        fail("the %s file could not be read: %s (%s)" % (what, path, err))


def load_spec(path):
    if not os.path.isfile(path):
        fail("the spec is not there: %s" % path)
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (ValueError, OSError) as err:
        fail("the spec could not be read as JSON: %s (%s)" % (path, err))


def check_variants(variants):
    if not isinstance(variants, list) or len(variants) < 2:
        fail("a switcher needs two options or more to compare, and this spec has %d"
             % (len(variants) if isinstance(variants, list) else 0))
    seen = {}
    for index, variant in enumerate(variants):
        if not isinstance(variant, dict):
            fail("option %d is not an object" % (index + 1))
        name = str(variant.get("name", "")).strip()
        if not name:
            fail("option %d has no name" % (index + 1))
        why = str(variant.get("why", "")).strip()
        if not why:
            fail('option "%s" has no "why", so nothing on the page would say what it is '
                 "testing. Every option carries its own reason." % name)
        key = str(variant.get("key", ""))
        if not KEY.match(key):
            fail('option "%s" has the key "%s", which cannot be a keyboard shortcut. '
                 "A key is one character, 0 to 9 or a to z, because the badge drawn on "
                 "the tab and the key the page listens for are the same character."
                 % (name, key))
        if key in seen:
            fail('the key "%s" is on two options, "%s" and "%s". Each option needs its own.'
                 % (key, seen[key], name))
        seen[key] = name


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>__TITLE__</title>
<style>
  :root { color-scheme: light; }
  body { margin: 0; background: #F4F1ED; color: #1B1613; min-height: 100vh;
         font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  /* The frame is the window, so a short screen leaves no dead ground under it: the
     stage takes whatever height is left over. */
  .frame { max-width: 1180px; margin: 0 auto; padding: 28px 24px 24px;
           box-sizing: border-box; min-height: 100vh;
           display: flex; flex-direction: column; }
  .eyebrow { font-size: 12px; letter-spacing: .08em; text-transform: uppercase;
             color: #6E6259; margin: 0 0 6px; }
  h1 { font-size: 26px; line-height: 1.2; margin: 0 0 10px; font-weight: 600; }
  .asks { margin: 0 0 6px; max-width: 62ch; color: #3D342E; }
  .measurement { margin: 0 0 20px; max-width: 62ch; color: #6E6259; font-size: 13px; }
  .tabs { display: flex; flex-wrap: wrap; gap: 8px; margin: 0 0 16px; }
  .tab { display: inline-flex; align-items: center; gap: 8px; cursor: pointer;
         background: #FFFDFB; border: 1px solid #DAD1C8; border-radius: 7px;
         padding: 7px 12px; font: inherit; font-size: 13px; color: #1B1613; }
  .tab:hover { border-color: #B9AC9F; }
  .tab[aria-pressed="true"] { background: #1B1613; border-color: #1B1613; color: #FBFAF8; }
  .tab .badge { display: inline-grid; place-items: center; width: 17px; height: 17px;
                border-radius: 4px; background: #EDE7E1; color: #584D45; font-size: 11px;
                font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  .tab[aria-pressed="true"] .badge { background: #453B34; color: #F6F3F0; }
  .readout { border-left: 2px solid #D9D0C7; padding: 2px 0 2px 14px; margin: 0 0 20px;
             max-width: 68ch; }
  .readout h2 { font-size: 15px; margin: 0 0 5px; font-weight: 600; }
  .readout p { margin: 0 0 6px; color: #3D342E; }
  .readout .measured { color: #6E6259; font-size: 13px; margin: 0; }
  /* The stage is a canvas, not leftover background: it fills the rest of the window and
     says so, so the space around a small screen reads as room rather than as a void. */
  .stage { flex: 1; display: flex; background: #E9E4DE;
           border: 1px solid #DDD5CD; border-radius: 10px; padding: 24px;
           box-sizing: border-box; overflow: auto; }
  /* Centred on the canvas, settled with Dan on 2026-09-07 against pinning it to the top:
     centred holds its position while options of different heights are switched between,
     which is the whole activity. Auto margins do the centring because, unlike
     align-items, they never cut off the top of a screen taller than the window. */
  .stage > * { margin: auto; }
  .hint { margin: 22px 0 0; color: #7C7168; font-size: 12px; flex: none; }
</style>
<style>
__STYLES__
</style>
</head>
<body>
<div class="frame">
  <p class="eyebrow">__TITLE__</p>
  <h1>__ROUND__</h1>
  __ASKS__
  __MEASUREMENT__
  <div class="tabs" id="tabs"></div>
  <div class="readout" id="readout"></div>
  <div class="stage" id="stage"></div>
  <p class="hint">Left and right arrows step through the options. The key on each tab jumps
  straight to it.</p>
</div>
<script>
__BUILDER__
</script>
<script>
var VARIANTS = __VARIANTS__;

function el(tag, cls, text) {
  var node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
}

var tabs = document.getElementById("tabs");
var readout = document.getElementById("readout");
var stage = document.getElementById("stage");
var current = 0;

function show(index) {
  current = (index + VARIANTS.length) % VARIANTS.length;
  var variant = VARIANTS[current];
  Array.prototype.forEach.call(tabs.children, function (button, position) {
    button.setAttribute("aria-pressed", String(position === current));
  });
  var lines = [el("h2", null, variant.name), el("p", null, variant.why)];
  if (variant.measured) lines.push(el("p", "measured", variant.measured));
  readout.replaceChildren.apply(readout, lines);
  stage.replaceChildren(buildScreen(variant));
}

VARIANTS.forEach(function (variant, index) {
  var button = el("button", "tab");
  button.type = "button";
  button.setAttribute("aria-pressed", "false");
  button.append(el("span", "badge", variant.key), el("span", null, variant.name));
  button.addEventListener("click", function () { show(index); });
  tabs.append(button);
});

document.addEventListener("keydown", function (event) {
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.key === "ArrowRight") { show(current + 1); event.preventDefault(); return; }
  if (event.key === "ArrowLeft") { show(current - 1); event.preventDefault(); return; }
  for (var i = 0; i < VARIANTS.length; i++) {
    if (VARIANTS[i].key === event.key.toLowerCase()) { show(i); event.preventDefault(); return; }
  }
});

show(0);
</script>
</body>
</html>
"""


def escape_text(value):
    return (str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def picker_options(spec, variants):
    """The round's closing picker, derived from the same list the tabs are drawn from.

    The label is the tab's own name and the description is what the readout shows
    for that option, so the thing on screen and the thing being selected can never
    say different things. No none of these option is added: the picker's own free
    text answer is the escape hatch, and offering a refusal invites one when the
    round's job is a comparison.
    """
    round_text = str(spec.get("round", "Which of these")).strip().rstrip("?").strip()
    options = []
    for variant in variants:
        description = str(variant.get("why", "")).strip()
        measured = str(variant.get("measured", "")).strip()
        if measured:
            description = description + " " + measured
        options.append({"label": str(variant.get("name", "")).strip(),
                        "description": description})
    return {"round": round_text, "question": round_text + "?", "options": options}


def main(argv):
    if len(argv) != 3:
        print(__doc__.split("\n\n")[1].strip().replace(
            "python3 make-switcher.py", "Usage: python3 make-switcher.py"), file=sys.stderr)
        return 2

    spec_path, out_path = argv[1], argv[2]
    spec = load_spec(spec_path)
    if not isinstance(spec, dict):
        fail("the spec must be an object: %s" % spec_path)

    base = os.path.dirname(os.path.abspath(spec_path))
    variants = spec.get("variants", [])
    check_variants(variants)

    builder_name = str(spec.get("builder", "")).strip()
    if not builder_name:
        fail('the spec names no "builder", so there would be nothing to draw the screen with')
    builder = read_file(os.path.join(base, builder_name), "builder")
    if "buildScreen" not in builder:
        fail("the builder %s does not define buildScreen, which is the one function the page "
             "calls for every option" % builder_name)

    styles = ""
    styles_name = str(spec.get("styles", "")).strip()
    if styles_name:
        styles = read_file(os.path.join(base, styles_name), "styles")

    asks = str(spec.get("asks", "")).strip()
    measurement = str(spec.get("measurement", "")).strip()

    page = PAGE
    page = page.replace("__TITLE__", escape_text(spec.get("title", "Design round")))
    page = page.replace("__ROUND__", escape_text(spec.get("round", "Which of these")))
    page = page.replace("__ASKS__", '<p class="asks">%s</p>' % escape_text(asks) if asks else "")
    page = page.replace("__MEASUREMENT__",
                        '<p class="measurement">%s</p>' % escape_text(measurement)
                        if measurement else "")
    page = page.replace("__STYLES__", styles)
    page = page.replace("__BUILDER__", builder)
    page = page.replace("__VARIANTS__",
                        json.dumps(variants, indent=2).replace("</", "<\\/"))

    picker_path = os.path.splitext(out_path)[0] + ".picker.json"
    try:
        with open(out_path, "w", encoding="utf-8") as handle:
            handle.write(page)
        with open(picker_path, "w", encoding="utf-8") as handle:
            json.dump(picker_options(spec, variants), handle, indent=2)
            handle.write("\n")
    except OSError as err:
        fail("the page could not be written to %s (%s)" % (out_path, err))

    print("SWITCHER %s options=%d keys=%s"
          % (out_path, len(variants), ",".join(v["key"] for v in variants)))
    print("PICKER %s, one option per tab, ready for AskUserQuestion" % picker_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
