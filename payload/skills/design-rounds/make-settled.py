#!/usr/bin/env python3
"""make-settled.py: write the settled design, the one file a design round leaves behind (#1364).

    python3 make-settled.py <settled.json> <out.html>

The settled design is what the build is scored against (score/design_score.py), so it is generated
from the round's own builder and the product's captured chrome, never assembled by hand from the
switcher. It holds, in one self contained file:

  - every frame of the design, each drawn by the round's builder inside the captured chrome, from the
    committed fixture data the built page also renders (the score's two sides draw the same data);
  - designFrameDocument(<id>), which gives a frame's whole document, for the web adapter to draw as a
    page of its own at the frame's width;
  - designFrameTrouble(report), what kept a frame from being drawn whole (its builder, or its
    screenShown, threw), said beside that frame on the page and read by the score in the same words
    (claude-config#1539);
  - the decision record and its map (decision-map), each decision written so a check can be authored
    from it: what is on screen, on which frames, and how it is verified;
  - the frames (design-frames) and Dan's exceptions (design-exceptions), in his words.
  - its seal, the last line, the SHA-256 of everything above it (design_file.seal), which the design
    round guard checks before letting the file be committed under docs/design unasked
    (claude-config#1524); any edit to the file breaks it, and running this again reseals it.

The spec, with paths resolved against the spec's own folder:

    {
      "title":    "Team capacity",
      "intro":    "For Sam's team leads, settled over three rounds, approved by Dan on 2026-10-19",
                                         optional: the design's opening paragraph, shown under its title
      "requirements": [{"number": "1", "text": "Sam sees tomorrow's open calls by team"}],
                                         optional: the PRD's numbered requirements, each number written as
                                         text exactly as the PRD numbers it. Given, they are listed on the
                                         page, each with an anchor, every decision's owner is its number
                                         linked to that entry (the sentence is on the page once, in the
                                         list, claude-config#1429), the decision map carries them, and a
                                         decision naming a number they do not hold is refused. Left out, a
                                         decision's number is shown alone and the PRD holds its sentence,
                                         and it says so when it writes
      "chrome":   {...the round's "chrome", see chrome_frame.py...},
                | "chromes": [{"name": "edit", ...what "chrome" takes...}, {"name": "view", ...}],
                                         in place of "chrome", for a design whose frames were captured
                                         from different pages (a panel in edit mode, a card in view
                                         mode): each frame names its own in "chrome", so the whole
                                         design is one file and one decision map (claude-config#1474)
      "screen":   "email" | "document" | "new-product",   in place of "chrome", for a design with no
                                         product page around it: each frame is drawn alone at its own
                                         width (claude-config#1393)
                | "terminal",            for a Claude Code mod's design: each frame is the shared
                                         terminal alone, drawn as the switcher draws it, at the size
                                         its builder gives the window (claude-config#1413), which is
                                         measured in Chrome and must be the frame's own "width"
                                         (claude-config#1422; DESIGN_ROUNDS_CHROME names the Chrome)
      "builder":  "builder.js",          buildScreen(variant), as in the rounds
      "styles":   "screen.css",          optional
      "fixture":  "../fixtures/team-capacity.json",   the committed data both sides draw
      "frames": [
        {"id": "f1", "title": "Tomorrow, light", "width": 1280, "height": 900 (optional),
         "variant": {...what buildScreen is handed for this frame...},
         "chrome": "edit"                  with "chromes" only: the captured page it is drawn in}
      ],
      "decisions": [
        {"id": "D1", "decision": "The page is called Team capacity", "why": "Sam's word for it",
         "requirement": "1" (or "noCode": "why it needs no code"),
         "verify": "check" (default) | "picture" | "elsewhere",
         "frames": ["f1"],                  where it shows, so its check runs on each
         "check": "main h1 reads Team capacity",   what the check asserts, for a check
         "provenBy": "scripts/test-x.ts"}   for elsewhere
      ],
      "exceptions": [{"id": "X1", "decision": "D7" | "frame": "f3", "region": [x, y, w, h],
                      "words": "Dan's own words", "date": "YYYY-MM-DD", "source": "where he said them"}],
      "idioms": ["what is an idiom of the medium rather than a decision"]   optional
    }

It writes NOTHING when it refuses, and refuses: a chrome that is not a captured one (no stand ins), a
"screen" that is not one of the three kinds or the terminal, or one named beside a captured chrome,
"chromes" beside "chrome" or a "screen", a "chromes" that is empty, a chrome in it with no name, two
sharing a name, or one no frame is drawn in, a frame naming a chrome the design does not hold, naming
none in a design of several, or naming one in a design of one, a builder calling the terminal in a design that does not ask for it or declaring its name, a frame with
no width or variant, a terminal design with no Chrome to measure it in or whose measurement fails, a
terminal frame whose window draws at a width other than the frame's own, that draws no window, or whose
builder or its screenShown throws, a decision with no owner (check-decision-map.py's rule), a decision a
check would verify with no "check" sentence or no frames, a decision naming a frame the design does
not hold, an intro that is not text, a requirements list that is empty or not in the shape above (a
number not written as text, a requirement with no sentence, two sharing a number), a decision naming a
requirement the list does not hold (check-decision-map.py's UNLISTED), and an exception without Dan's
words, a date and where he said them. Exit 2 with the reason.
"""
import html
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "score"))
import chrome_frame  # noqa: E402
import design_file  # noqa: E402
import design_score  # noqa: E402

TOKEN = "__DR_VARIANT__"


def fail(message):
    print("make-settled: " + message, file=sys.stderr)
    sys.exit(2)


def read(path, what):
    if not os.path.isfile(path):
        fail("the %s is not there: %s" % (what, path))
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    spec_path, out_path = argv[1], argv[2]
    try:
        spec = json.loads(read(spec_path, "spec"))
    except ValueError as err:
        fail("the spec is not JSON: %s (%s)" % (spec_path, err))
    if not isinstance(spec, dict):
        fail("the spec must be an object")
    base = os.path.dirname(os.path.abspath(spec_path))

    # A design with no product page around it names its kind in "screen", as its rounds did; every other
    # design is drawn in the captured page. Naming both is refused rather than one winning, because they
    # contradict each other, and picking either silently draws the frames against the other's intent:
    # bare when they belong in the product (the stand in this skill forbids), or in a page an email
    # never has (claude-config#1393, the same "keep one" the switcher says for the terminal).
    # A mod's design names the shared terminal the same way, which is itself the mod's chrome
    # (claude-config#1413), and is refused beside a captured page for the same reason.
    kind = spec.get("screen")
    if kind is not None:
        if not isinstance(kind, str) or kind not in design_file.FRAME_KINDS:
            fail('the spec asks for the screen %s, and make-settled.py draws every frame inside the product\'s '
                 "captured page, alone as one of the kinds with no product page around it, or in a shared "
                 "screen, one of: %s" % (json.dumps(kind), design_file.frame_kinds()))
        if spec.get("chrome") is not None:
            if kind in design_file.SCREEN_KINDS:
                fail('the spec asks for the shared screen "%s", which is its chrome, and names a captured page as '
                     "well; keep one" % kind)
            fail('the spec names the kind "%s", which has no product page around it, and a captured page as '
                 "well; keep one" % kind)
    # A design whose frames were captured from different pages lists them in "chromes" and each frame
    # names its own (claude-config#1474). Beside "chrome" or a kind, one would win over the other, so
    # both are refused as above, by the reader a round's switcher uses too (claude-config#1536).
    try:
        several = chrome_frame.several_chromes(spec, "frames")
    except chrome_frame.ChromeError as err:
        fail(str(err))
    builder_name = str(spec.get("builder", "")).strip()
    if not builder_name:
        fail('the spec names no "builder"')
    builder = read(os.path.join(base, builder_name), "builder")
    if "buildScreen" not in builder:
        fail("the builder %s does not define buildScreen" % builder_name)
    chrome_bin = None
    chromes = None   # {name: chrome}, for a design drawn in several captured pages
    try:
        if kind in design_file.SCREEN_KINDS:
            chrome = chrome_frame.shared_screen(kind, builder, builder_name)
            # Found now, so a machine with no Chrome is told before anything else is checked, while the
            # windows themselves are measured last, on the page as it will be written (claude-config#1422).
            chrome_bin = chrome_frame.find_chrome()
        else:
            # The same reader as the switcher's, so a builder calling the terminal in a design that does
            # not ask for it is refused here as it is in the rounds, never drawn as a builder that threw.
            chrome_frame.load_screen(kind, builder, builder_name)
            if several:
                chromes = chrome_frame.load_chromes(spec["chromes"], base)
                chrome = None
            else:
                chrome = chrome_frame.no_page(kind) if kind is not None else chrome_frame.load_chrome(spec.get("chrome"), base)
    except chrome_frame.ChromeError as err:
        fail(str(err))
    styles = read(os.path.join(base, spec["styles"]), "styles") if spec.get("styles") else ""
    fixture_name = str(spec.get("fixture", "")).strip()
    if not fixture_name:
        fail('the spec names no "fixture": the settled design and the built page must draw the same '
             "committed data, or no picture of one can match the other")
    try:
        fixture = json.loads(read(os.path.join(base, fixture_name), "fixture"))
    except ValueError as err:
        fail("the fixture %s is not JSON (%s)" % (fixture_name, err))

    frames = spec.get("frames")
    if not isinstance(frames, list) or not frames:
        fail("the spec lists no frames, so there is nothing to score the build against")
    ids = []
    for n, f in enumerate(frames, 1):
        if not isinstance(f, dict) or not isinstance(f.get("id"), str) or not f["id"].strip():
            fail("frame %d has no id" % n)
        if f["id"] in ids:
            fail("two frames share the id %s" % f["id"])
        ids.append(f["id"])
        w = f.get("width")
        if not isinstance(w, int) or isinstance(w, bool) or w <= 0:
            fail("frame %s has no width in pixels, and every frame is scored at its own width" % f["id"])
        if not isinstance(f.get("variant"), dict):
            fail("frame %s has no \"variant\", the object its builder is handed" % f["id"])
        if not str(f.get("title", "")).strip():
            fail("frame %s has no title, which is what a reader of the design sees it by" % f["id"])
    # Each frame's captured page, refused as a round's options are (claude-config#1474, #1536).
    try:
        page_of = chrome_frame.chrome_names(
            [(f["id"], f.get("chrome")) for f in frames], chromes, "frame", "design",
            'the spec names one captured page, in "chrome", for every frame' if kind is None
            else 'the design is drawn with no captured page ("screen": "%s")' % kind)
    except chrome_frame.ChromeError as err:
        fail(str(err))
    for f in frames:
        own = chromes[page_of[f["id"]]] if chromes is not None else chrome
        if own["kind"] == "png" and f["width"] != own["width"]:
            fail("frame %s is %d wide, and its chrome %sis a picture %d wide: a picture's width is its own"
                 % (f["id"], f["width"], (page_of[f["id"]] + " ") if chromes is not None else "", own["width"]))

    decisions = spec.get("decisions")
    if not isinstance(decisions, list) or not decisions:
        fail("the spec lists no decisions; a settled design always has some")
    seen_ids = set()
    for n, d in enumerate(decisions, 1):
        if not isinstance(d, dict):
            fail("decision %d is not an object" % n)
        did = d.get("id")
        if not isinstance(did, str) or not did.strip():
            fail("decision %d has no id, which its check and any exception name it by" % n)
        if did in seen_ids:
            fail("two decisions share the id %s" % did)
        seen_ids.add(did)
        verify = d.get("verify", "check")
        shown = d.get("frames")
        if shown is not None and (not isinstance(shown, list) or any(x not in ids for x in shown)):
            fail("decision %s names frames %s, and the design's frames are %s" % (did, shown, ", ".join(ids)))
        if verify == "check":
            if not str(d.get("check", "")).strip():
                fail("decision %s is verified by a check but does not say what the check asserts (\"check\"), "
                     "so nobody can write it" % did)
            if not shown:
                fail("decision %s is verified by a check but names no frames it shows on (\"frames\")" % did)

    # The design's opening paragraph and its numbered requirements (claude-config#1401), each optional.
    # Present but empty is refused rather than read as absent, since nobody can tell the two apart later.
    if "intro" in spec and (not isinstance(spec["intro"], str) or not spec["intro"].strip()):
        fail('the spec\'s "intro" must be the design\'s opening paragraph, as text; leave it out for none')
    requirements = spec.get("requirements")
    if "requirements" in spec:
        try:
            design_file.read_requirements(requirements)
        except ValueError as err:
            fail(str(err))

    exceptions = spec.get("exceptions", [])
    if not isinstance(exceptions, list):
        fail('"exceptions" must be a list')
    problems = design_score.check_exceptions(exceptions, decisions, [{"id": f["id"], "width": f["width"], **(
        {"height": f["height"]} if f.get("height") else {})} for f in frames])
    if problems:
        fail("; ".join(problems))

    if chromes is None:
        template = chrome_frame.frame_document(chrome, builder, styles, TOKEN, fixture)
    else:
        # One document per captured page, never per frame, so a page several frames share is carried once.
        template = {name: chrome_frame.frame_document(c, builder, styles, TOKEN, fixture) for name, c in chromes.items()}
    variants = {f["id"]: chrome_frame.script_text(json.dumps(f["variant"])) for f in frames}
    # Each frame of a design in several pages carries the page it is drawn in, which the score keeps on the
    # frame's row and says beside it (claude-config#1474); a design in one page carries none, as before.
    frames_block = {"frames": [dict({"id": f["id"], "title": f["title"], "width": f["width"]},
                                    **({"height": f["height"]} if f.get("height") else {}),
                                    **({"chrome": f["chrome"]} if chromes is not None else {})) for f in frames]}
    if chrome is not None and chrome["kind"] in ("none", "screen"):
        # Read by the score, which records and says it, so a 100% on an email is never read as a build
        # drawn inside the product (claude-config#1393), and a terminal design's pictures are measured only
        # from the terminal adapter's capture of the mod's band (claude-config#1413, #1414).
        frames_block["kind"] = chrome["page"]
    # Sealed as its last line (claude-config#1524), so the design round guard lets the file be committed
    # under docs/design unasked while it is exactly what was written here, and holds any hand edit.
    page = design_file.seal(render_page(spec, chrome, decisions, exceptions, frames, frames_block, template, variants, chromes))

    # The decision map is held to check-decision-map.py's own rule, on the file as written, before it
    # is put where anyone can use it.
    fd, tmp = tempfile.mkstemp(suffix=".html", dir=os.path.dirname(os.path.abspath(out_path)) or ".")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(page)
    check = subprocess.run([sys.executable, os.path.join(HERE, "check-decision-map.py"), tmp],
                           capture_output=True, text=True)
    if check.returncode != 0:
        os.unlink(tmp)
        fail("the decision map does not hold:\n" + check.stdout + check.stderr)
    # A terminal frame is scored at its declared width, and its window is drawn at the width its builder
    # gives Terminal.screen, so each is drawn in Chrome from the page as written and the two held equal,
    # as a captured picture's width is held to its own (claude-config#1422).
    if chrome is not None and chrome["kind"] == "screen":
        try:
            problems = chrome_frame.window_width_problems(
                frames, chrome_frame.measure_screen_windows(page, frames, chrome_bin))
        except chrome_frame.ChromeError as err:
            problems = [str(err)]
        if problems:
            os.unlink(tmp)
            fail("; ".join(problems))
    os.replace(tmp, out_path)
    print("SETTLED %s frames=%d decisions=%d exceptions=%d" % (out_path, len(frames), len(decisions), len(exceptions)))
    if requirements is None:
        named = []
        for d in decisions:
            req = d.get("requirement")
            if isinstance(req, str) and req.strip() and req.strip() not in named:
                named.append(req.strip())
        if named:
            print('make-settled: the decisions name Requirement %s, and the spec gives no "requirements", so the '
                  "page shows those numbers without their sentences" % ", ".join(named), file=sys.stderr)
    return 0


# Added only to a page that lists its requirements: each entry is the target of the decisions that cite
# it (claude-config#1429), so the one a reader followed a link to is marked where it lands.
REQUIREMENTS_STYLE = """  .dr-requirements { list-style: none; padding-left: 0; }
  .dr-requirements li { margin: 0 -6px 10px; padding: 2px 6px; border-radius: 4px; scroll-margin-top: 16px; }
  .dr-requirements li:target { background: var(--dr-target); outline: none; }
  .dr-decisions a { color: var(--dr-link); text-decoration: underline; text-underline-offset: 2px; }
  .dr-decisions a:focus-visible { outline: 2px solid var(--dr-link); outline-offset: 2px; border-radius: 2px; }
"""

# Every colour is a token on :root and is given again for the dark scheme, because Dan reads the page in
# both (claude-config#1426). Text, muted text and links each clear 4.5 to 1 on the page in both schemes,
# and text clears it on a requirement marked as the one a link landed on; test-make-settled.sh measures
# all of it from this block. A frame's own surface stays white in both: a frame is the product's screen
# as drawn, not the page around it, and a document that paints no background of its own is white.
DOC_STYLE = """
  :root {
    color-scheme: light dark;
    --dr-bg: #F4F1ED; --dr-text: #1B1613; --dr-muted: #665A51; --dr-border: #DDD5CD;
    --dr-frame: #FFFFFF; --dr-link: #1D5A96; --dr-target: #F7E3BE; --dr-warn: #A3260F;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --dr-bg: #171412; --dr-text: #EDE6DF; --dr-muted: #ADA197; --dr-border: #3F3731;
      --dr-frame: #FFFFFF; --dr-link: #8FBDEB; --dr-target: #3D3122; --dr-warn: #F29A80;
    }
  }
  body { margin: 0; background: var(--dr-bg); color: var(--dr-text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  .dr-doc { max-width: 1400px; margin: 0 auto; padding: 32px 24px 64px; }
  .dr-doc h1 { font-size: 28px; margin: 0 0 6px; }
  .dr-doc h2 { font-size: 18px; margin: 36px 0 10px; }
  .dr-doc h3 { font-size: 15px; margin: 24px 0 8px; }
  .dr-meta { color: var(--dr-muted); font-size: 13px; margin: 0; }
  .dr-decisions li { margin: 0 0 10px; }
  .dr-how { color: var(--dr-muted); font-size: 13px; }
  .dr-frame { border: 1px solid var(--dr-border); background: var(--dr-frame); display: block; }
  .dr-trouble { color: var(--dr-warn); font-weight: 600; max-width: 72ch; margin: 0 0 8px; }
"""

# The ids the page itself writes, which no requirement's anchor may take.
PAGE_IDS = ("decision-map", "design-frames", "design-exceptions")


def closed(text):
    """A sentence ending with its own mark, or closed with a full stop when it has none (#1426)."""
    text = text.rstrip()
    return text if text.endswith((".", "?", "!")) else text + "."


def requirement_anchors(numbers, taken):
    """{number: id} for each listed requirement (claude-config#1429). A number is text exactly as the PRD
    writes it ("6.4", "R 1/2"), so its id keeps only ASCII letters, digits and underscores, every other
    run becoming one hyphen, behind "req-" so it starts with a letter; and two numbers that come out
    alike, or one that comes out as a decision's own id, are told apart by a counter, in list order."""
    anchors, used = {}, set(taken)
    for number in numbers:
        slug = re.sub(r"[^A-Za-z0-9_]+", "-", number).strip("-")
        base = "req-" + slug if slug else "req"
        candidate, n = base, 2
        while candidate in used:
            candidate, n = "%s-%d" % (base, n), n + 1
        used.add(candidate)
        anchors[number] = candidate
    return anchors


def render_page(spec, chrome, decisions, exceptions, frames, frames_block, template, variants, chromes=None):
    """The settled page. With chromes, a design in several captured pages (claude-config#1474): template
    is {name: document}, each frame names its own, and the page lists each page once, with where it
    was captured, under Frames."""
    e = lambda v: html.escape(str(v), quote=True)  # noqa: E731
    requirements = spec.get("requirements")
    # Dan, 2026-10-20, on claude-config#1429: a decision shows its requirement's number as a link to the
    # requirement in the list, and the sentence is on the page once, there. With no list, the number
    # is shown alone, as it always was.
    anchors = requirement_anchors([r["number"].strip() for r in requirements],
                                  [d["id"] for d in decisions] + list(PAGE_IDS)) if requirements else {}
    items = []
    for d in decisions:
        if d.get("requirement"):
            number = str(d["requirement"]).strip()
            label = "Requirement %s" % e(number)
            owner = ('<a href="#%s">%s</a>.' % (anchors[number], label)) if number in anchors else label + "."
        else:
            owner = closed("No code: %s" % e(d.get("noCode", "")))
        verify = d.get("verify", "check")
        how = {"check": "Checked on %s: %s" % (e(", ".join(d.get("frames", []))), e(d.get("check", ""))),
               "picture": "Held by the picture half",
               "elsewhere": "Proven by %s" % e(d.get("provenBy", ""))}.get(verify, e(verify))
        # The reason is its own sentence, closed before the muted owner begins, so the line never reads
        # "Sam's word for it Requirement 1" run together (claude-config#1426).
        why = (" %s" % closed(e(d["why"]))) if str(d.get("why", "")).strip() else ""
        items.append('<li id="%s"><strong>%s</strong> %s%s <span class="dr-how">%s %s</span></li>'
                     % (e(d["id"]), e(d["id"]), closed(e(d.get("decision", ""))), why, owner, closed(how)))
    if exceptions:
        exc = "".join('<li><strong>%s</strong>, %s, %s: "%s" (%s)</li>' % (
            e(x["id"]), e("decision %s" % x["decision"] if "decision" in x else "frame %s" % x["frame"]),
            e(x["date"]), e(x["words"]), e(x["source"])) for x in exceptions)
        exc = "<ol>%s</ol>" % exc
    else:
        exc = "<p>None. A deliberate difference from this design is a new design round, or an exception Dan approves in his own words, recorded here.</p>"
    idioms = spec.get("idioms") or []
    idiom_html = ("<h2>Idioms of the medium, to translate rather than copy</h2><ul>%s</ul>"
                  % "".join("<li>%s</li>" % e(i) for i in idioms)) if idioms else ""
    frame_html = "".join('<h3>%s <span class="dr-meta">%s, %d wide%s</span></h3><iframe class="dr-frame" data-frame="%s" title="%s" style="width:%dpx;height:%dpx"></iframe>'
                         % (e(f["title"]), e(f["id"]), f["width"], (", in %s" % e(f["chrome"])) if chromes else "",
                            e(f["id"]), e(f["title"]), f["width"], f.get("height") or 400)
                         for f in frames)
    if chromes:
        frame_html = '<ul class="dr-chromes">%s</ul>\n%s' % ("".join(
            "<li><strong>%s</strong>, captured from %s</li>" % (e(name), e(c["source"])) for name, c in chromes.items()),
            frame_html)
        script = """
var DR_TEMPLATES = %s;
var DR_CHROME_OF = %s;
var DR_VARIANTS = %s;
/* A frame's whole document: the captured page the frame names, with the round drawn in it from the
   fixture. The web adapter of the design match score draws it as a page of its own at the frame's
   width. Each page's template holds the variant as the quoted token make-settled.py wrote, replaced
   here by the frame's own. */
function designFrameDocument(id) {
  if (!Object.prototype.hasOwnProperty.call(DR_VARIANTS, id)) throw new Error("this design has no frame " + id);
  return DR_TEMPLATES[DR_CHROME_OF[id]].split(%s).join(DR_VARIANTS[id]);
}
""" % (chrome_frame.script_text(json.dumps(template)), chrome_frame.script_text(json.dumps({f["id"]: f["chrome"] for f in frames})),
       chrome_frame.script_text(json.dumps(variants)), json.dumps(json.dumps(TOKEN)))
    else:
        script = """
var DR_TEMPLATE = %s;
var DR_VARIANTS = %s;
/* A frame's whole document: the captured chrome with the round drawn in it from the fixture. The web
   adapter of the design match score draws it as a page of its own at the frame's width. The template
   holds the variant as the quoted token make-settled.py wrote, replaced here by the frame's own. */
function designFrameDocument(id) {
  if (!Object.prototype.hasOwnProperty.call(DR_VARIANTS, id)) throw new Error("this design has no frame " + id);
  return DR_TEMPLATE.split(%s).join(DR_VARIANTS[id]);
}
""" % (chrome_frame.script_text(json.dumps(template)), chrome_frame.script_text(json.dumps(variants)),
       json.dumps(json.dumps(TOKEN)))
    # A frame its builder did not draw whole is said right above it, in designFrameTrouble's words, the
    # ones the score says too (claude-config#1539).
    script += chrome_frame.FRAME_TROUBLE + """Array.prototype.forEach.call(document.querySelectorAll("iframe[data-frame]"), function (frame) {
  frame.addEventListener("load", function () {
    var fixed = %s;
    var d = frame.contentDocument;
    if (d && !fixed[frame.dataset.frame]) frame.style.height = d.documentElement.scrollHeight + "px";
    var trouble = designFrameTrouble(frame.contentWindow && frame.contentWindow.DR_FRAME);
    var said = frame.previousElementSibling;
    if (said && said.classList.contains("dr-trouble")) said.remove();
    if (!trouble) return;
    var note = document.createElement("p");
    note.className = "dr-trouble";
    note.textContent = "This frame is not the design: " + trouble + ".";
    frame.before(note);
  });
  frame.srcdoc = designFrameDocument(frame.dataset.frame);
});
""" % json.dumps({f["id"]: bool(f.get("height")) for f in frames})
    dmap = {"requirements": requirements, "decisions": decisions} if requirements else {"decisions": decisions}
    intro_html = "<p>%s</p>\n" % e(spec["intro"].strip()) if spec.get("intro") else ""
    req_html = ("<h2>Requirements</h2>\n<ul class=\"dr-requirements\">%s</ul>\n" % "".join(
        # tabindex -1 lets a followed link put focus here, so a screen reader reads the sentence next.
        '<li id="%s" tabindex="-1"><strong>%s</strong> %s</li>' % (
            anchors[r["number"].strip()], e(r["number"].strip()), e(r["text"].strip())) for r in requirements)
        if requirements else "")
    if chromes:
        drawn = "Every frame is drawn inside the product's real chrome, in whichever of its %d captured pages the frame names" % len(chromes)
    elif chrome["kind"] in ("none", "screen"):
        drawn = "%s Every frame is drawn at its own width" % e(chrome["line"])
    else:
        drawn = "Every frame is drawn inside the product's real chrome, captured from %s" % e(chrome["source"])
    return """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>%s, the settled design</title>
<style>%s</style></head>
<body><div class="dr-doc">
<h1>%s</h1>
%s<p class="dr-meta">The settled design. %s, from the committed fixture the built page renders too. The build is done when it scores 100%% against this file on both halves.</p>
%s<h2>Decisions</h2>
<ol class="dr-decisions">%s</ol>
<h2>Exceptions Dan approved</h2>
%s
<h2>Frames</h2>
%s
%s
</div>
<script type="application/json" id="decision-map">
%s
</script>
<script type="application/json" id="design-frames">
%s
</script>
<script type="application/json" id="design-exceptions">
%s
</script>
<script>%s</script>
</body></html>
""" % (e(spec.get("title", "Design")), DOC_STYLE + (REQUIREMENTS_STYLE if requirements else ""),
       e(spec.get("title", "Design")), intro_html, drawn, req_html,
       "".join(items), exc, frame_html, idiom_html,
       chrome_frame.script_text(json.dumps(dmap, indent=1)), chrome_frame.script_text(json.dumps(frames_block, indent=1)),
       chrome_frame.script_text(json.dumps({"exceptions": exceptions}, indent=1)), script)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
