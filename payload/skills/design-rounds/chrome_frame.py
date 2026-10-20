"""chrome_frame.py: one frame of a design, drawn inside the product's REAL chrome (claude-config#1364).

Dan, 2026-10-19: "No stand ins." A design round draws the product's real header, sidebar and
controls, so nothing in a round is masked and the settled design can be compared with the built page
pixel for pixel. Rounds used to draw their own copy of the chrome, by hand, beside the part being
decided; a copy drifts from the product, and a design that differs from the product everywhere
outside the part being decided can never score 100% against it.

So a round names the chrome it was CAPTURED from, in its spec:

    "chrome": {
      "captured": "chrome.html",      the product's page as it renders, saved with its stylesheets
                                      and fonts inlined (capture-chrome.js does this in the browser);
                                      or "chrome.png", a screenshot of a native app's real window
      "from":     "http://localhost:3000/admin/team-capacity, signed in as an admin, 2026-10-19",
                                      where and when it was captured, so it can be captured again
      "slot":     "#main"             the element the round's builder draws into (an id); for a
                                      picture, [x, y, width, height] in its pixels
      "width":    1280                the width it was captured at (a picture's is its own)
    }

and every option, and every frame of the settled design, is drawn as its own document: the captured
page with the round's stylesheet added, the fixture (when given) as window.DESIGN_FIXTURE, the
round's builder, and a few lines that put buildScreen(variant) into the slot. Each is a document of
its own, so it draws at its own width with its own media queries, and nothing in the round's builder
can collide with the page around it.

make-settled.py draws each frame of the settled design this way, in an iframe for the reader, and the
settled file gives each frame's whole document from designFrameDocument(<id>), which the score's web
adapter draws as a page of its own at the frame's width.

A screen that has no product page around it (claude-config#1393) is drawn by no_page(<kind>) instead:
an email, a document or a new product, the three kinds Dan allowed by name on 2026-10-20, each frame
then the round's drawing alone at its own size, with no margin around it. Any other kind is refused.

A Claude Code mod's design is drawn in the shared terminal of screens/, which is itself the mod's chrome
(claude-config#1413): shared_screen(<name>) gives it, and each frame is the terminal window alone, the
screen's script and stylesheet ahead of the round's (on_screen), as the switcher draws it. load_screen
is the one reader of screens/ for the switcher and the settled design, so both draw the same terminal.
"""
import base64
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "score"))
import pngio  # noqa: E402
from design_file import NO_PAGE_KINDS, SCREEN_KINDS, no_page_kinds  # noqa: E402

ID = re.compile(r"^#([A-Za-z][\w-]*)$")

SCREENS_DIR = os.path.join(HERE, "screens")

TOP_LEVEL = re.compile(r"^(?:var|let|const|function|class)\s+([A-Za-z_$][\w$]*)", re.M)


class ChromeError(Exception):
    """The spec's chrome cannot be drawn; the message says what to change."""


NO_CHROME = ('this round names no captured chrome. Dan, 2026-10-19: "No stand ins": a design round '
             "draws the product's real chrome and controls, captured from the product, so nothing is "
             'masked and the settled design can be scored against the build. Add "chrome": {"captured": '
             '"<the page saved with capture-chrome.js, or a screenshot of the app\'s window>", "from": '
             '"<where and when>", "slot": "<#id, or [x, y, width, height]>", "width": <pixels>} to the '
             'spec. A round about a Claude Code mod asks for "screen": "terminal" instead, and a screen '
             'with no product page around it names its kind as "screen", one of: ' + no_page_kinds() +
             ' (Dan, 2026-10-20, claude-config#1393).')


def no_page(kind):
    """A design drawn with no product page around it (claude-config#1393): an email, a document or a new
    product, the kinds Dan allowed by name. Each frame is then the round's drawing alone, at its own
    size. Any other kind is refused, naming the allowed ones."""
    if kind not in NO_PAGE_KINDS:
        raise ChromeError('the spec names the kind "%s", and a screen drawn with no product page around it is '
                          "one of: %s. Every other round is drawn inside the product's captured page."
                          % (kind, no_page_kinds()))
    return {"kind": "none", "page": kind, "line": NO_PAGE_KINDS[kind] + ".", "slot": None, "width": None,
            "height": None, "source": None}


def top_level_names(source):
    """The names a script declares at column 0, which is where a top level declaration sits
    in every builder and screen this tool has met. A text match, not a parse."""
    return sorted(set(TOP_LEVEL.findall(source)))


def code_only(source):
    """The script with its comments and its quoted strings blanked out. Approximate (a
    regular expression literal holding a quote can fool it), which is enough to tell a
    reference to a name from a sentence that happens to contain it."""
    pattern = re.compile(r"""//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`""",
                         re.S)
    return pattern.sub(" ", source)


def available_screens():
    """The shared screens that ship beside this script: a name with both a .js and a .css
    in screens/. Read from the directory rather than listed, so a screen added there is
    offered, and named in the refusal below, without anybody editing a second list (L41)."""
    if not os.path.isdir(SCREENS_DIR):
        return []
    names = set()
    for entry in os.listdir(SCREENS_DIR):
        stem, ext = os.path.splitext(entry)
        if ext == ".js" and os.path.isfile(os.path.join(SCREENS_DIR, stem + ".css")):
            names.add(stem)
    return sorted(names)


def _read_screen_file(path, what):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as err:
        raise ChromeError("the %s file could not be read: %s (%s)" % (what, path, err))


def screen_global(name, source):
    """The ONE name a shared screen puts at the page's top level. A screen declaring more,
    or none, is a fault in the screen rather than in the round, so it is refused as such."""
    names = top_level_names(source)
    if len(names) != 1:
        raise ChromeError("the shared screen %s declares %s at the top level, and a screen must declare "
                          "exactly one name so a builder's own top level names cannot replace its parts"
                          % (name, ", ".join(names) if names else "nothing"))
    return names[0]


def load_screen(asked, builder, builder_name):
    """The shared screen's script and stylesheet, or two empty strings for a round with none.

    The one reader of screens/ for the switcher and the settled design (claude-config#1413), so a round
    and its settled design are drawn in the same terminal. Three refusals, each one a page that would
    otherwise throw at load, where the page can say only that the builder threw: a screen that does
    not exist, a builder declaring the screen's own name (which replaces it for the whole page), and a
    builder calling a screen its spec never asked for."""
    if asked is not None and not isinstance(asked, str):
        raise ChromeError('"screen" names one shared screen, as text, and this spec gives %s'
                          % json.dumps(asked))
    asked = (asked or "").strip()
    screens = available_screens()
    # First, so a misspelt screen is reported as that rather than as a builder using a screen
    # its spec never asked for, which would send somebody to add a field they already wrote.
    if asked and asked not in screens and asked not in NO_PAGE_KINDS:
        raise ChromeError('the spec asks for the screen "%s". A round is drawn in one of the shared screens that '
                          "ship with this tool (%s), or, with no product page around it, names its kind, one of: %s"
                          % (asked, ", ".join(screens) if screens else "none", no_page_kinds()))

    code = code_only(builder)
    for name in screens:
        if name == asked:
            continue
        other = screen_global(name, _read_screen_file(os.path.join(SCREENS_DIR, name + ".js"), "screen script"))
        # Any mention in the CODE, not only Terminal.screen: every round so far wrote
        # var T = Terminal. Strings and comments are left out, so copy reading "Terminal.app"
        # is not mistaken for a call.
        if re.search(r"(?<![\w$])%s(?![\w$])" % re.escape(other), code):
            raise ChromeError('the builder %s calls %s, which is the %s screen, and the spec does not ask for '
                              'it. Add "screen": "%s" to the spec so it is on the page.'
                              % (builder_name, other, name, name))

    if not asked or asked in NO_PAGE_KINDS:
        return "", ""
    script = _read_screen_file(os.path.join(SCREENS_DIR, asked + ".js"), "screen script")
    styles = _read_screen_file(os.path.join(SCREENS_DIR, asked + ".css"), "screen stylesheet")
    owned = screen_global(asked, script)
    if owned in top_level_names(builder):
        raise ChromeError("the builder %s declares %s at its top level, which is the name the %s screen "
                          "ships under, so it would replace the screen for the whole page. Call it by "
                          "another name. This is a text match on declarations at the start of a line."
                          % (builder_name, owned, asked))
    return script, styles


def on_screen(screen_script, screen_styles, builder, styles):
    """The round's builder and stylesheet with a shared screen ahead of them, as (builder, styles).

    The screen goes FIRST in both: its script so the builder can call it the moment the builder
    runs, its stylesheet so the round's own rules win wherever a round is varying part of the
    screen's look. One composition for the switcher's page and the settled design's frames
    (claude-config#1413), so the two draw the terminal alike."""
    if not screen_script:
        return builder, styles
    return screen_script + "\n" + builder, screen_styles + "\n" + styles


def shared_screen(name, builder, builder_name):
    """A settled design drawn in a shared screen (claude-config#1413): the terminal, a Claude Code mod's
    own chrome. Each frame is then the screen alone at the size its builder draws it, as the switcher
    draws it, with the screen's script and stylesheet ahead of the round's. A screen the score does not
    know (design_file.SCREEN_KINDS) is refused."""
    if name not in SCREEN_KINDS:
        raise ChromeError('a settled design is drawn in one of the shared screens %s, and the spec asks for "%s"'
                          % (", ".join(SCREEN_KINDS), name))
    script, styles = load_screen(name, builder, builder_name)
    return {"kind": "screen", "page": name, "line": SCREEN_KINDS[name] + ".", "script": script,
            "styles": styles, "slot": None, "width": None, "height": None, "source": None}


def script_text(text):
    """Text safe inside a <script> element: a closing tag inside it would end the script early."""
    return text.replace("</", "<\\/")


def load_chrome(chrome, base):
    """The spec's "chrome", checked and read: {kind, slot, width, height, page | picture, source}."""
    if chrome is None:
        raise ChromeError(NO_CHROME)
    if not isinstance(chrome, dict):
        raise ChromeError('"chrome" must be an object naming what was captured; see the design rounds skill')
    captured = chrome.get("captured")
    source = chrome.get("from")
    if not isinstance(captured, str) or not captured.strip():
        raise ChromeError('"chrome" names no "captured" file. ' + NO_CHROME)
    if not isinstance(source, str) or not source.strip():
        raise ChromeError('"chrome" does not say where it was captured from ("from"): name the page or '
                          "window and when, so the chrome can be captured again when the product changes")
    path = os.path.join(base, captured)
    if not os.path.isfile(path):
        raise ChromeError("the captured chrome %s is not there" % path)
    slot = chrome.get("slot")
    if path.lower().endswith(".png"):
        try:
            width, height, _ = pngio.read_png(path)
        except pngio.PngError as err:
            raise ChromeError("the captured chrome picture cannot be read: %s" % err)
        if (not isinstance(slot, list) or len(slot) != 4
                or not all(isinstance(v, int) and not isinstance(v, bool) and v >= 0 for v in slot)
                or slot[2] == 0 or slot[3] == 0):
            raise ChromeError('a captured chrome picture needs "slot": [x, y, width, height], in whole '
                              "pixels, for where the round draws inside it")
        if slot[0] + slot[2] > width or slot[1] + slot[3] > height:
            raise ChromeError("the slot %s reaches outside the %d by %d chrome picture" % (slot, width, height))
        if chrome.get("width") not in (None, width):
            raise ChromeError("the chrome says it is %s wide, and its picture is %d" % (chrome.get("width"), width))
        with open(path, "rb") as fh:
            picture = base64.b64encode(fh.read()).decode("ascii")
        return {"kind": "png", "slot": slot, "width": width, "height": height, "picture": picture, "source": source}
    if not path.lower().endswith((".html", ".htm")):
        raise ChromeError("the captured chrome %s is neither a page (.html) nor a picture (.png)" % path)
    with open(path, encoding="utf-8", errors="replace") as fh:
        page = fh.read()
    m = ID.match(slot) if isinstance(slot, str) else None
    if not m:
        raise ChromeError('a captured chrome page needs "slot": "#<id>", the element the round draws into')
    if not re.search(r"""\bid\s*=\s*(["']?)%s\1(?=[\s>/])""" % re.escape(m.group(1)), page):
        raise ChromeError("the captured chrome %s holds no element with the id %s, so there is nowhere to draw"
                          % (path, m.group(1)))
    if not re.search(r"</head\s*>", page, re.I) or not re.search(r"</body\s*>", page, re.I):
        raise ChromeError("the captured chrome %s is not a whole page (it has no </head> or no </body>); save "
                          "it with capture-chrome.js" % path)
    width = chrome.get("width")
    if not isinstance(width, int) or isinstance(width, bool) or width <= 0:
        raise ChromeError('a captured chrome page needs "width": the width in pixels it was captured at')
    return {"kind": "html", "slot": m.group(1), "width": width, "height": None, "page": page, "source": source}


BOOT = """(function () {
  "use strict";
  var V = __VARIANT__;
  var slot = document.getElementById(__SLOT__);
  var report = { built: false, why: "" };
  /* A slot the captured page's text names but its document does not hold (an id inside a comment)
     is said as that, never as the builder throwing (lessons review of #1364). */
  if (!slot) {
    window.DR_FRAME = { built: false, noSlot: true, why: "the captured page holds no element " + __SLOT__ };
    return;
  }
  try {
    var node = buildScreen(V);
    if (!node || !node.nodeType) throw new Error("buildScreen returned no element");
    slot.replaceChildren(node);
    report.built = true;
  } catch (err) {
    report.why = String(err && err.message ? err.message : err);
  }
  window.DR_FRAME = report;
  if (report.built && typeof screenShown === "function") {
    try { screenShown(V, slot.firstElementChild); } catch (err) { report.shownWhy = String(err && err.message ? err.message : err); }
  }
  /* A key pressed while this frame has the focus goes to the page around it, unless the design took
     it or it was typed into a field, as the switcher's own keys yield (claude-config#356). */
  document.addEventListener("keydown", function (event) {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
    var t = event.target;
    if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT|OPTION)$/.test(t.tagName || ""))) return;
    if (window.parent && window.parent !== window) window.parent.postMessage({ drKey: event.key }, "*");
  });
})();"""


def frame_document(chrome, builder, styles, variant, fixture=None):
    """The whole document for one option or frame: the captured chrome with the round drawn in it."""
    if chrome["kind"] == "screen":
        builder, styles = on_screen(chrome["script"], chrome["styles"], builder, styles)
    scripts = ""
    if fixture is not None:
        scripts += "<script>window.DESIGN_FIXTURE = %s;</script>\n" % script_text(json.dumps(fixture))
    scripts += "<script>\n%s\n</script>\n" % script_text(builder)
    boot = BOOT.replace("__VARIANT__", script_text(json.dumps(variant))).replace(
        "__SLOT__", json.dumps(chrome["slot"] if chrome["kind"] == "html" else "dr-slot"))
    scripts += "<script>\n%s\n</script>\n" % boot
    style = "<style>\n%s\n</style>\n" % styles if styles else ""
    if chrome["kind"] in ("none", "screen"):
        # Nothing around the round: its drawing is the body's first element, with no margin, so the
        # frame is the email or the document at its own size, as the build draws it alone (#1393), or
        # the terminal window at the size its builder gives it, which is itself the chrome (#1413).
        return ("<!doctype html>\n<html><head><meta charset=\"utf-8\">\n<style>\nhtml, body { margin: 0; }\n</style>\n"
                "%s</head><body><div id=\"dr-slot\"></div>\n%s</body></html>\n" % (style, scripts))
    if chrome["kind"] == "png":
        x, y, w, h = chrome["slot"]
        return ("<!doctype html>\n<html><head><meta charset=\"utf-8\">\n<style>\nhtml, body { margin: 0; }\n"
                ".dr-chrome { position: relative; width: %dpx; height: %dpx; "
                "background: url(data:image/png;base64,%s) no-repeat; }\n"
                "#dr-slot { position: absolute; left: %dpx; top: %dpx; width: %dpx; height: %dpx; overflow: hidden; }\n"
                "</style>\n%s</head><body><div class=\"dr-chrome\"><div id=\"dr-slot\"></div></div>\n%s</body></html>\n"
                % (chrome["width"], chrome["height"], chrome["picture"], x, y, w, h, style, scripts))
    page = chrome["page"]
    head_at = [m.start() for m in re.finditer(r"</head\s*>", page, re.I)][-1]
    page = page[:head_at] + style + page[head_at:]
    body_at = [m.start() for m in re.finditer(r"</body\s*>", page, re.I)][-1]
    return page[:body_at] + scripts + page[body_at:]
