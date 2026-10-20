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
  - the decision record and its map (decision-map), each decision written so a check can be authored
    from it: what is on screen, on which frames, and how it is verified;
  - the frames (design-frames) and Dan's exceptions (design-exceptions), in his words.

The spec, with paths resolved against the spec's own folder:

    {
      "title":    "Team capacity",
      "chrome":   {...the round's "chrome", see chrome_frame.py...},
      "builder":  "builder.js",          buildScreen(variant), as in the rounds
      "styles":   "screen.css",          optional
      "fixture":  "../fixtures/team-capacity.json",   the committed data both sides draw
      "frames": [
        {"id": "f1", "title": "Tomorrow, light", "width": 1280, "height": 900 (optional),
         "variant": {...what buildScreen is handed for this frame...}}
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
frame with no width or variant, a decision with no owner (check-decision-map.py's rule), a decision a
check would verify with no "check" sentence or no frames, a decision naming a frame the design does
not hold, and an exception without Dan's words, a date and where he said them. Exit 2 with the reason.
"""
import html
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "score"))
import chrome_frame  # noqa: E402
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

    try:
        chrome = chrome_frame.load_chrome(spec.get("chrome"), base)
    except chrome_frame.ChromeError as err:
        fail(str(err))
    builder_name = str(spec.get("builder", "")).strip()
    if not builder_name:
        fail('the spec names no "builder"')
    builder = read(os.path.join(base, builder_name), "builder")
    if "buildScreen" not in builder:
        fail("the builder %s does not define buildScreen" % builder_name)
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
        if chrome["kind"] == "png" and w != chrome["width"]:
            fail("frame %s is %d wide, and its chrome picture is %d: a picture's width is its own" % (f["id"], w, chrome["width"]))

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

    exceptions = spec.get("exceptions", [])
    if not isinstance(exceptions, list):
        fail('"exceptions" must be a list')
    problems = design_score.check_exceptions(exceptions, decisions, [{"id": f["id"], "width": f["width"], **(
        {"height": f["height"]} if f.get("height") else {})} for f in frames])
    if problems:
        fail("; ".join(problems))

    template = chrome_frame.frame_document(chrome, builder, styles, TOKEN, fixture)
    variants = {f["id"]: chrome_frame.script_text(json.dumps(f["variant"])) for f in frames}
    frames_block = {"frames": [dict({"id": f["id"], "title": f["title"], "width": f["width"]},
                                    **({"height": f["height"]} if f.get("height") else {})) for f in frames]}
    page = render_page(spec, chrome, decisions, exceptions, frames, frames_block, template, variants)

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
    os.replace(tmp, out_path)
    print("SETTLED %s frames=%d decisions=%d exceptions=%d" % (out_path, len(frames), len(decisions), len(exceptions)))
    return 0


DOC_STYLE = """
  body { margin: 0; background: #F4F1ED; color: #1B1613; font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  .dr-doc { max-width: 1400px; margin: 0 auto; padding: 32px 24px 64px; }
  .dr-doc h1 { font-size: 28px; margin: 0 0 6px; }
  .dr-doc h2 { font-size: 18px; margin: 36px 0 10px; }
  .dr-doc h3 { font-size: 15px; margin: 24px 0 8px; }
  .dr-meta { color: #6E6259; font-size: 13px; margin: 0; }
  .dr-decisions li { margin: 0 0 10px; }
  .dr-how { color: #6E6259; font-size: 13px; }
  .dr-frame { border: 1px solid #DDD5CD; background: #fff; display: block; }
"""


def render_page(spec, chrome, decisions, exceptions, frames, frames_block, template, variants):
    e = lambda v: html.escape(str(v), quote=True)  # noqa: E731
    items = []
    for d in decisions:
        owner = ("Requirement %s" % e(d["requirement"])) if d.get("requirement") else ("No code: %s" % e(d.get("noCode", "")))
        verify = d.get("verify", "check")
        how = {"check": "Checked on %s: %s" % (e(", ".join(d.get("frames", []))), e(d.get("check", ""))),
               "picture": "Held by the picture half",
               "elsewhere": "Proven by %s" % e(d.get("provenBy", ""))}.get(verify, e(verify))
        why = (" %s" % e(d["why"])) if d.get("why") else ""
        items.append('<li id="%s"><strong>%s</strong> %s.%s <span class="dr-how">%s. %s.</span></li>'
                     % (e(d["id"]), e(d["id"]), e(d.get("decision", "")), why, owner, how))
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
    frame_html = "".join('<h3>%s <span class="dr-meta">%s, %d wide</span></h3><iframe class="dr-frame" data-frame="%s" title="%s" style="width:%dpx;height:%dpx"></iframe>'
                         % (e(f["title"]), e(f["id"]), f["width"], e(f["id"]), e(f["title"]), f["width"], f.get("height") or 400)
                         for f in frames)
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
Array.prototype.forEach.call(document.querySelectorAll("iframe[data-frame]"), function (frame) {
  frame.addEventListener("load", function () {
    var fixed = %s;
    var d = frame.contentDocument;
    if (d && !fixed[frame.dataset.frame]) frame.style.height = d.documentElement.scrollHeight + "px";
  });
  frame.srcdoc = designFrameDocument(frame.dataset.frame);
});
""" % (chrome_frame.script_text(json.dumps(template)), chrome_frame.script_text(json.dumps(variants)),
       json.dumps(json.dumps(TOKEN)),
       json.dumps({f["id"]: bool(f.get("height")) for f in frames}))
    dmap = {"decisions": decisions}
    return """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>%s, the settled design</title>
<style>%s</style></head>
<body><div class="dr-doc">
<h1>%s</h1>
<p class="dr-meta">The settled design. Every frame is drawn inside the product's real chrome, captured from %s, from the committed fixture the built page renders too. The build is done when it scores 100%% against this file on both halves.</p>
<h2>Decisions</h2>
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
""" % (e(spec.get("title", "Design")), DOC_STYLE, e(spec.get("title", "Design")), e(chrome["source"]),
       "".join(items), exc, frame_html, idiom_html,
       chrome_frame.script_text(json.dumps(dmap, indent=1)), chrome_frame.script_text(json.dumps(frames_block, indent=1)),
       chrome_frame.script_text(json.dumps({"exceptions": exceptions}, indent=1)), script)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
