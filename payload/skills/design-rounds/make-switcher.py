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
  .dr-sameness { margin: 0 0 16px; padding: 10px 12px; border-radius: 6px;
         background: #FDECEA; color: #6B1A12; border: 1px solid #E4A9A1; font-weight: 600; }
  .dr-frame { max-width: 1180px; margin: 0 auto; padding: 28px 24px 24px;
           box-sizing: border-box; min-height: 100vh;
           display: flex; flex-direction: column; }
  .dr-eyebrow { font-size: 12px; letter-spacing: .08em; text-transform: uppercase;
             color: #6E6259; margin: 0 0 6px; }
  .dr-round { font-size: 26px; line-height: 1.2; margin: 0 0 10px; font-weight: 600; }
  .dr-asks { margin: 0 0 6px; max-width: 62ch; color: #3D342E; }
  .dr-measurement { margin: 0 0 20px; max-width: 62ch; color: #6E6259; font-size: 13px; }
  .dr-tabs { display: flex; flex-wrap: wrap; gap: 8px; margin: 0 0 16px; }
  .dr-tab { display: inline-flex; align-items: center; gap: 8px; cursor: pointer;
         background: #FFFDFB; border: 1px solid #DAD1C8; border-radius: 7px;
         padding: 7px 12px; font: inherit; font-size: 13px; color: #1B1613; }
  .dr-tab:hover { border-color: #B9AC9F; }
  .dr-tab[aria-pressed="true"] { background: #1B1613; border-color: #1B1613; color: #FBFAF8; }
  .dr-tab .dr-badge { display: inline-grid; place-items: center; width: 17px; height: 17px;
                border-radius: 4px; background: #EDE7E1; color: #584D45; font-size: 11px;
                font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  .dr-tab[aria-pressed="true"] .dr-badge { background: #453B34; color: #F6F3F0; }
  .dr-readout { border-left: 2px solid #D9D0C7; padding: 2px 0 2px 14px; margin: 0 0 20px;
             max-width: 68ch; }
  .dr-readout h2 { font-size: 15px; margin: 0 0 5px; font-weight: 600; }
  .dr-readout p { margin: 0 0 6px; color: #3D342E; }
  .dr-readout .dr-measured { color: #6E6259; font-size: 13px; margin: 0; }
  /* The stage is a canvas, not leftover background: it fills the rest of the window and
     says so, so the space around a small screen reads as room rather than as a void. */
  .dr-stage { flex: 1; display: flex; background: #E9E4DE;
           border: 1px solid #DDD5CD; border-radius: 10px; padding: 24px;
           box-sizing: border-box; overflow: auto; }
  /* Centred on the canvas, settled with Dan on 2026-09-07 against pinning it to the top:
     centred holds its position while options of different heights are switched between,
     which is the whole activity. Auto margins do the centring because, unlike
     align-items, they never cut off the top of a screen taller than the window. */
  /* `flex: none` because a flex item SHRINKS by default: a screen declaring a width
     wider than the stage was silently squeezed to the stage's width, which is half of
     how three options declaring 1100, 1440 and 1720 all rendered at the same size on
     2026-09-08. The stage scrolls instead, so a declared width is the width drawn. */
  .dr-stage > * { margin: auto; flex: none; }
  .dr-hint { margin: 22px 0 0; color: #7C7168; font-size: 12px; flex: none; }
</style>
<style>
__STYLES__
</style>
</head>
<body>
<div class="dr-frame">
  <p class="dr-eyebrow">__TITLE__</p>
  <h1 class="dr-round">__ROUND__</h1>
  __ASKS__
  __MEASUREMENT__
  <div class="dr-tabs" id="dr-tabs"></div>
  <div class="dr-readout" id="dr-readout"></div>
  <div class="dr-stage" id="dr-stage"></div>
  <p class="dr-hint">Left and right arrows step through the options. The key on each tab jumps
  straight to it, unless the design on the stage wants that key for itself.</p>
</div>
<script>
__BUILDER__
</script>
<script>
/* Everything this page needs is INSIDE this scope, and nothing it declares reaches the
   page's top level.

   The builder is a second top level script in this same page, so a global here is a
   global the project can collide with. It did: on 2026-09-10 a project declaring var
   stage and var tabs and its own function el took over this page's tab strip and stage,
   show() threw on tabs.children at every press, and the stage kept whatever was already
   on it. Every option then drew the identical screen, which is exactly what a round whose
   options do not differ looks like, so nothing refused and the round read as a real
   finding about the design (claude-config#355).

   Same remedy as the chrome's CSS namespace, for the same reason: a project must not be
   able to reach this by accident. buildScreen is still read from the top level, because
   that is the one name this page and the builder agree on by contract. */
(function () {
  "use strict";

  var VARIANTS = __VARIANTS__;

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  var frame = document.querySelector(".dr-frame");
  var tabs = document.getElementById("dr-tabs");
  var readout = document.getElementById("dr-readout");
  var stage = document.getElementById("dr-stage");
  var current = 0;
  var built = [];

  function show(index) {
    current = (index + VARIANTS.length) % VARIANTS.length;
    var variant = VARIANTS[current];
    Array.prototype.forEach.call(tabs.children, function (button, position) {
      button.setAttribute("aria-pressed", String(position === current));
    });
    var lines = [el("h2", null, variant.name), el("p", null, variant.why)];
    if (variant.measured) lines.push(el("p", "dr-measured", variant.measured));
    readout.replaceChildren.apply(readout, lines);
    /* The picture drawn at load, not a fresh one. See drawAll below: the builder is asked
       for each option exactly once, and the same element is moved onto the stage every
       time that option is chosen. The fallback covers the one case where drawAll could not
       finish, so a page whose builder threw is still usable rather than blank. */
    stage.replaceChildren(built[current] || buildScreen(variant));
  }

  /* Draw every option once, keep the pictures, and say whether any two are the same.

     ONE call per option for the life of the page, which is fewer than this page used to
     make: show() rebuilt on every press, so walking back and forth redrew each option
     again and again. That matters for a builder that does anything besides return an
     element, such as touching the page itself or starting a fetch, because the extra work
     would happen far away from anything that would explain it (claude-config#357). The
     contract is that buildScreen is a function of its argument; this makes the cost of
     breaking it a fixed one rather than one that grows with how long somebody looks.

     What it gives up, and it is worth stating: a builder that reads the window size draws
     once and no longer refreshes on the next press. A design round is a comparison at one
     size, and the pictures staying identical between presses is the property being
     compared, so that is the right way round.

     The sameness answer falls out of the same pass. Two options rendering the same markup
     are either a collision between this page and the builder or a round whose options do
     not differ, and both are worth saying out loud rather than handing somebody a page
     that looks finished.

     A builder that THROWS is a third answer with its own sentence, because a check that
     could not run must never read as a check that passed. */
  function drawAll() {
    var seen = {};
    var clashes = [];
    for (var i = 0; i < VARIANTS.length; i++) {
      var node;
      try {
        node = buildScreen(VARIANTS[i]);
      } catch (err) {
        return { ran: false, why: String(err && err.message ? err.message : err) };
      }
      built[i] = node;
      var probe = document.createElement("div");
      probe.appendChild(node);
      var mark = probe.innerHTML;
      if (Object.prototype.hasOwnProperty.call(seen, mark)) {
        clashes.push(VARIANTS[seen[mark]].name + " and " + VARIANTS[i].name);
      } else {
        seen[mark] = i;
      }
    }
    return { ran: true, clashes: clashes };
  }

  function warn(text) {
    var strip = el("p", "dr-sameness", text);
    frame.insertBefore(strip, frame.firstChild);
  }

  var verdict = drawAll();
  if (!verdict.ran) {
    warn("Whether these options draw the same picture could not be checked, because the "
         + "builder threw when it was asked to draw one on its own: " + verdict.why
         + ". Read the options against each other yourself before reading anything into "
         + "this round.");
  } else if (verdict.clashes.length) {
    warn(verdict.clashes.join(", ") + " draw the same picture. That is what a round whose "
         + "options do not differ looks like, and it is also what it looks like when the "
         + "builder and this page collide over a name. Check the builder actually reads "
         + "its argument before reading anything into this round.");
  }

  VARIANTS.forEach(function (variant, index) {
    var button = el("button", "dr-tab");
    button.type = "button";
    button.setAttribute("aria-pressed", "false");
    button.append(el("span", "dr-badge", variant.key), el("span", null, variant.name));
    button.addEventListener("click", function () { show(index); });
    tabs.append(button);
  });

  /* The listener has to stay on the document: nothing on this page is focusable, so
     scoping it to the frame would stop the arrow keys working at all. What it does
     instead is YIELD, because the document is the last surface this page shares with the
     project and the project's screen is the thing being judged (claude-config#356, L452).

     Two ways to lose the key, and both are the project winning on purpose:

       the project CLAIMED it. Its own listener is registered first, because its script
         runs first, so it sees the key first. If it called preventDefault, that key is
         spoken for and this page must not also act on it.

       the key was typed INTO the design. A design carrying a text field would otherwise
         have every "1" and "2" jump tabs while somebody types in it, which is the key
         being stolen rather than shared (L596). */
  document.addEventListener("keydown", function (event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.defaultPrevented) return;
    var target = event.target;
    if (target && (target.isContentEditable
        || /^(INPUT|TEXTAREA|SELECT|OPTION)$/.test(target.tagName || ""))) return;
    if (event.key === "ArrowRight") { show(current + 1); event.preventDefault(); return; }
    if (event.key === "ArrowLeft") { show(current - 1); event.preventDefault(); return; }
    for (var i = 0; i < VARIANTS.length; i++) {
      if (VARIANTS[i].key === event.key.toLowerCase()) { show(i); event.preventDefault(); return; }
    }
  });

  show(0);
})();
</script>
</body>
</html>
"""


def chrome_ids(page):
    """The names of the elements THIS PAGE owns, read out of the markup that defines them.

    Derived rather than listed, because a list that must mirror another source of truth
    drifts the moment somebody edits one of them, and the drift is silent: add a fourth
    element with an id and a hand written tuple simply would not mention it, so the refusal
    below would stop covering it while still reporting a clean build (L41, L452).

    Returns the bare names, without the dr- namespace, because that is the form a builder
    written against its own standalone page would use.
    """
    return tuple(sorted(set(re.findall(r'id="dr-([A-Za-z0-9_-]+)"', page))))


CHROME_IDS = chrome_ids(PAGE)


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

    # A builder that reaches for one of the page's OWN elements by its bare name.
    #
    # Ovation's design files are each a page in their own right, with their own stage, and
    # they carry a bootstrap line like document.getElementById("stage").replaceChildren(...).
    # Lift the script out as a builder and, before the ids were namespaced, that line found
    # the CHROME's stage and wrote into it, which show() then replaced: wasteful and silent,
    # and it survived. With the ids namespaced it finds nothing and throws part way through,
    # so whatever the file declares below that line never runs (claude-config#356).
    #
    # The namespace stays. What changes is that this is said HERE, where the person is
    # holding the spec and the builder, rather than left to throw at load with the cause
    # nowhere near the symptom. Same principle as the two refusals above.
    reached = [name for name in CHROME_IDS
               if ('getElementById("%s")' % name) in builder
               or ("getElementById('%s')" % name) in builder
               or ('querySelector("#%s")' % name) in builder
               or ("querySelector('#%s')" % name) in builder]
    if reached:
        fail("the builder %s reaches for an element called %s, which is this page's own and "
             "is now called dr-%s so that a project cannot take it by accident. A builder is "
             "handed one option and must RETURN the element to draw for it, rather than "
             "reach for somewhere to put it: whatever it returns is placed on the stage for "
             "it. If that line is the file's own bootstrap for running as a page on its own, "
             "it does not belong in the builder. This is a text match over the ways that "
             "lookup is usually written, so a builder that spells it some other way is not "
             "caught here and will simply find nothing when the page opens."
             % (builder_name, ", ".join(reached), reached[0]))

    styles = ""
    styles_name = str(spec.get("styles", "")).strip()
    if styles_name:
        styles = read_file(os.path.join(base, styles_name), "styles")

    asks = str(spec.get("asks", "")).strip()
    measurement = str(spec.get("measurement", "")).strip()

    page = PAGE
    page = page.replace("__TITLE__", escape_text(spec.get("title", "Design round")))
    page = page.replace("__ROUND__", escape_text(spec.get("round", "Which of these")))
    page = page.replace("__ASKS__", '<p class="dr-asks">%s</p>' % escape_text(asks) if asks else "")
    page = page.replace("__MEASUREMENT__",
                        '<p class="dr-measurement">%s</p>' % escape_text(measurement)
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
