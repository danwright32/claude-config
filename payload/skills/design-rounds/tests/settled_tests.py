#!/usr/bin/env python3
"""The checks behind test-make-settled.sh (claude-config#1364): chrome_frame.py, which draws a round
inside the product's captured chrome (no stand ins), and make-settled.py, which writes the settled
design the build is scored against. Every spec, chrome and builder is written here into a throwaway
folder. Where Chrome is on this machine, the settled file is opened in it and each frame's document
drawn, so the contract the web adapter relies on is read in a real browser, not only as text.
"""
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
MAKE = os.path.join(SKILL, "make-settled.py")
CHECK = os.path.join(SKILL, "check-decision-map.py")
SCORE = os.path.join(SKILL, "score", "design_score.py")
sys.path.insert(0, SKILL)
sys.path.insert(0, os.path.join(SKILL, "score"))
import chrome_frame  # noqa: E402
import pngio  # noqa: E402

passed = failed = 0
html_unescape = html.unescape


def text_of(markup):
    """What a reader sees of a fragment of the page: its tags taken out and its entities read."""
    return html.unescape(re.sub(r"<[^>]+>", "", markup))


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print("FAIL: " + name)
        for line in str(detail).splitlines()[:30]:
            print("    " + line)


T = tempfile.mkdtemp(prefix="make-settled-test.")
CHROME_PAGE = """<!doctype html>
<html lang="en" class="app"><head><meta charset="utf-8"><title>Slate</title>
<style>header { height: 48px; background: #14213d; color: #fff; } main { padding: 16px; }</style>
</head><body class="shell"><header>Slate</header><nav>Bucket availability</nav><main id="main"><p>the old page</p></main></body></html>
"""
BUILDER = """function buildScreen(variant) {
  var h = document.createElement("h1");
  h.textContent = "Team capacity";
  var p = document.createElement("p");
  p.className = "day";
  p.textContent = variant.day + ": " + window.DESIGN_FIXTURE.open[variant.day] + " calls open </script> stays text";
  var box = document.createElement("div");
  box.append(h, p);
  return box;
}
"""


def write(name, text):
    p = os.path.join(T, name)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(text)
    return p


write("chrome.html", CHROME_PAGE)
write("builder.js", BUILDER)
write("screen.css", ".day { color: #3c98da; }\n")
write("fixture.json", json.dumps({"open": {"Tue": 42, "Wed": 17}}))
pngio.write_png(os.path.join(T, "window.png"), 40, 30, bytes([240, 240, 240, 255]) * 1200)

CHROME = {"captured": "chrome.html", "from": "http://localhost:3000/admin/team-capacity, an admin, 2026-10-19",
          "slot": "#main", "width": 1280}

# --- chrome_frame: what counts as captured chrome ---------------------------------------------------
for label, chrome, needle in [
    ("no chrome at all", None, "No stand ins"),
    ("a chrome with no captured file", {"from": "x", "slot": "#main", "width": 1280}, "captured"),
    ("a chrome that does not say where it came from", dict(CHROME, **{"from": ""}), "from"),
    ("a captured file that is not there", dict(CHROME, captured="gone.html"), "not there"),
    ("a slot that is not an id", dict(CHROME, slot="main"), "#<id>"),
    ("a slot the captured page does not hold", dict(CHROME, slot="#content"), "content"),
    ("a page with no width", {k: v for k, v in CHROME.items() if k != "width"}, "width"),
    ("a picture with no slot rectangle", {"captured": "window.png", "from": "Ovation, 2026-10-19", "slot": "#main"}, "[x, y, width, height]"),
    ("a picture slot past its edge", {"captured": "window.png", "from": "Ovation", "slot": [30, 0, 20, 10]}, "outside"),
]:
    try:
        chrome_frame.load_chrome(chrome, T)
        check("%s is refused" % label, False, "it was accepted")
    except chrome_frame.ChromeError as err:
        check("%s is refused, saying so" % label, needle in str(err), str(err))

page = chrome_frame.load_chrome(CHROME, T)
doc = chrome_frame.frame_document(page, BUILDER, ".day { color: #3c98da; }", {"day": "Tue"}, {"open": {"Tue": 42}})
check("a frame document is the captured page with the round's stylesheet in its head",
      doc.index(".day { color: #3c98da; }") < doc.index("</head>") and "<header>Slate</header>" in doc, doc[:400])
check("and the fixture, the builder and the variant in its body, in that order",
      doc.index("DESIGN_FIXTURE") < doc.index("function buildScreen") < doc.index('"day": "Tue"') < doc.index("</body>"), doc[-600:])
check("a closing script tag inside the builder cannot end its script early", "</script> stays" not in doc and "<\\/script> stays" in doc)
pic = chrome_frame.load_chrome({"captured": "window.png", "from": "Ovation, 2026-10-19", "slot": [4, 6, 30, 20]}, T)
pdoc = chrome_frame.frame_document(pic, BUILDER, "", {"day": "Tue"}, {"open": {"Tue": 42}})
check("a picture chrome draws the window as the background, the slot where it says",
      "data:image/png;base64," in pdoc and "left: 4px; top: 6px; width: 30px; height: 20px" in pdoc, pdoc[:500])


# --- make-settled ----------------------------------------------------------------------------------
def spec(**changes):
    s = {
        "title": "Team capacity",
        "chrome": CHROME, "builder": "builder.js", "styles": "screen.css", "fixture": "fixture.json",
        "frames": [{"id": "f1", "title": "Tuesday", "width": 1280, "variant": {"day": "Tue"}},
                   {"id": "f2", "title": "Wednesday, phone", "width": 390, "height": 844, "variant": {"day": "Wed"}}],
        "decisions": [
            {"id": "D1", "decision": "The page is called Team capacity", "why": "Sam's word for it",
             "requirement": "1", "frames": ["f1", "f2"], "check": "main h1 reads Team capacity"},
            {"id": "D2", "decision": "Open calls are sky", "requirement": "2", "verify": "picture", "frames": ["f1"]},
            {"id": "D3", "decision": "History kept for good", "noCode": "already built", "verify": "elsewhere",
             "provenBy": "scripts/test-history.ts"},
        ],
        "exceptions": [],
        "idioms": ["the hover state, which a picture cannot hold"],
    }
    for k, v in changes.items():
        if v is None:
            s.pop(k, None)
        else:
            s[k] = v
    return s


def make(name, s):
    p = write(name + ".json", json.dumps(s))
    out = os.path.join(T, name + ".html")
    proc = subprocess.run([sys.executable, MAKE, p, out], capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr, out


usage = subprocess.run([sys.executable, MAKE], capture_output=True, text=True)
check("with no arguments it prints the spec's whole shape, exit 2",
      usage.returncode == 2 and '"decisions"' in usage.stderr and '"exceptions"' in usage.stderr, usage.stderr[:300])
rc, out, settled = make("settled", spec())
check("a full spec writes the settled design", rc == 0 and os.path.isfile(settled), out)
check("and says what it wrote", "SETTLED" in out and "frames=2 decisions=3 exceptions=0" in out, out)
src = open(settled, encoding="utf-8").read() if os.path.isfile(settled) else ""
rc2 = subprocess.run([sys.executable, CHECK, settled], capture_output=True, text=True)
check("its decision map holds by check-decision-map.py's own rule", rc2.returncode == 0, rc2.stdout)
fr = subprocess.run([sys.executable, SCORE, "frames", settled], capture_output=True, text=True)
check("the score reads its frames, with each one's width and height",
      fr.returncode == 0 and json.loads(fr.stdout)["frames"] == [{"id": "f1", "title": "Tuesday", "width": 1280},
                                                                   {"id": "f2", "title": "Wednesday, phone", "width": 390, "height": 844}],
      fr.stdout + fr.stderr)
check("it carries an exceptions block, empty, and says how a difference is settled",
      'id="design-exceptions"' in src and "None. A deliberate difference" in src, src[:200])
check("each decision is written so a check can be authored from it",
      "main h1 reads Team capacity" in src and "Checked on f1, f2" in src and "Proven by scripts/test-history.ts" in src)
check("it names where the chrome was captured", "an admin, 2026-10-19" in src)
check("it never carries the switcher's chooser", "dr-tabs" not in src and "picker" not in src)

for n, (label, s, needle) in enumerate([
    ("a stand in chrome (none named)", spec(chrome=None), "No stand ins"),
    ("no fixture", spec(fixture=None), "fixture"),
    ("a frame with no width", spec(frames=[{"id": "f1", "title": "x", "variant": {}}]), "width"),
    ("a frame with no variant", spec(frames=[{"id": "f1", "title": "x", "width": 1280}]), "variant"),
    ("a checked decision that says nothing of what is checked", spec(decisions=[
        {"id": "D1", "decision": "x", "requirement": "1", "frames": ["f1"]}]), "check"),
    ("a checked decision on no frame", spec(decisions=[
        {"id": "D1", "decision": "x", "requirement": "1", "check": "h1 reads x"}]), "frames"),
    ("a decision on a frame the design does not hold", spec(decisions=[
        {"id": "D1", "decision": "x", "requirement": "1", "frames": ["f9"], "check": "y"}]), "f9"),
    ("a decision with no owner", spec(decisions=[
        {"id": "D1", "decision": "x", "frames": ["f1"], "check": "y"}]), "UNMAPPED D1"),
    ("a decision with no id", spec(decisions=[{"decision": "x", "requirement": "1", "frames": ["f1"], "check": "y"}]), "no id"),
    ("two decisions sharing an id", spec(decisions=[
        {"id": "D1", "decision": "x", "requirement": "1", "frames": ["f1"], "check": "y"},
        {"id": "D1", "decision": "z", "requirement": "1", "frames": ["f1"], "check": "y"}]), "share the id D1"),
    ("an exception without Dan's words", spec(exceptions=[
        {"id": "X1", "decision": "D1", "date": "2026-10-19", "source": "u"}]), "words"),
]):
    rc, out, path = make("bad-%d" % n, s)
    check("%s is refused, writing nothing" % label, rc == 2 and needle in out and not os.path.exists(path), out)
rc, out, _ = make("with-exception", spec(exceptions=[
    {"id": "X1", "frame": "f1", "region": [0, 0, 100, 40], "words": "the clock can differ, it's live",
     "date": "2026-10-19", "source": "https://github.com/Try-Pennie/slate/issues/3941#issuecomment-1"}]))
check("an exception in Dan's words is kept and shown", rc == 0 and "the clock can differ, it&#x27;s live" in open(
    os.path.join(T, "with-exception.html"), encoding="utf-8").read(), out)

# --- a design with no product page around it (claude-config#1393) ------------------------------------
# Dan, 2026-10-20, on #1393: "allow named kinds". An email, a document or a new product names its kind
# in "screen", as a round does, and every frame is drawn at its own width with nothing around it.
rc, out, nopage = make("nopage", spec(chrome=None, screen="email"))
check("a design declaring itself an email is written with no captured page", rc == 0 and os.path.isfile(nopage), out)
nsrc = open(nopage, encoding="utf-8").read() if os.path.isfile(nopage) else ""
check("it says what it is, plainly, where a design in chrome names its capture",
      "An email, with no product page around it." in nsrc and "inside the product's real chrome" not in nsrc, nsrc[:900])
fm = re.search(r'<script type="application/json" id="design-frames">(.*?)</script>', nsrc, re.S)
check("its frames block records the kind for the score", fm is not None and json.loads(fm.group(1)).get("kind") == "email",
      fm.group(1) if fm else nsrc[-800:])
check("its frames carry no captured page", "<header>Slate</header>" not in nsrc and "the old page" not in nsrc)
fr = subprocess.run([sys.executable, SCORE, "frames", nopage], capture_output=True, text=True)
check("the score reads its frames at their own sizes",
      fr.returncode == 0 and [(f["id"], f["width"], f.get("height")) for f in json.loads(fr.stdout)["frames"]]
      == [("f1", 1280, None), ("f2", 390, 844)], fr.stdout + fr.stderr)
rc2 = subprocess.run([sys.executable, CHECK, nopage], capture_output=True, text=True)
check("and its decision map holds", rc2.returncode == 0, rc2.stdout + rc2.stderr)
for kind, words in [("document", "A document, with no product page around it."),
                    ("new-product", "A new product, whose page does not exist yet.")]:
    rc, out, path = make("nopage-" + kind, spec(chrome=None, screen=kind))
    check("a design declaring itself %s is written and says so" % kind,
          rc == 0 and words in open(path, encoding="utf-8").read(), out)
for n, (label, s, needle) in enumerate([
    ("a kind that is not allowed", spec(chrome=None, screen="postcard"), "email, document, new-product, terminal"),
    ("a kind beside a captured page", spec(screen="email"), "keep one"),
    ("no kind and no captured page", spec(chrome=None), "email, document, new-product"),
]):
    rc, out, path = make("bad-kind-%d" % n, s)
    check("%s is refused, writing nothing" % label, rc == 2 and needle in out and not os.path.exists(path), out)
nodoc = chrome_frame.frame_document(chrome_frame.no_page("email"), BUILDER, ".day { color: #3c98da; }",
                                    {"day": "Tue"}, {"open": {"Tue": 42}})
check("a no page frame document is the round's own drawing alone, its slot the body's first element",
      re.search(r"<body>\s*<div id=\"dr-slot\"></div>", nodoc) is not None and nodoc.index(".day {") < nodoc.index("</head>")
      and nodoc.index("function buildScreen") < nodoc.index("</body>"), nodoc[:600])
try:
    chrome_frame.no_page("postcard")
    check("an unknown kind is refused by the drawing too", False, "accepted")
except chrome_frame.ChromeError as err:
    check("an unknown kind is refused by the drawing too, naming the allowed ones", "email, document, new-product" in str(err), str(err))

# --- a design drawn in the shared terminal, a Claude Code mod's screen (claude-config#1413) -----------
# The terminal is itself a mod's chrome, so a mod's settled design names it in "screen" as its rounds
# did, and each frame is drawn as the switcher draws the terminal: the shared screen's script and
# stylesheet ahead of the round's own, the terminal window alone at the size its builder gives it.
TERM_BUILDER = """function buildScreen(variant) {
  var T = Terminal;
  return T.screen({
    title: "claude-config",
    width: variant.width,
    transcript: [T.user("keep going")],
    band: [[T.amber(variant.lead), "  ", window.DESIGN_FIXTURE.room]]
  });
}
"""
write("term-builder.js", TERM_BUILDER)
write("term-fixture.json", json.dumps({"room": "5h 12%, week 30%"}))
TERM_FRAMES = [{"id": "t1", "title": "Laptop", "width": 640, "variant": {"width": 640, "lead": "Work has more room"}},
               {"id": "t2", "title": "Wide", "width": 820, "height": 420, "variant": {"width": 820, "lead": "Work has more room"}}]
TERM_DECISIONS = [{"id": "D1", "decision": "The band leads with Work has more room", "requirement": "1",
                   "frames": ["t1", "t2"], "check": "the band's first line starts Work has more room"}]


def term_spec(**changes):
    return spec(**dict(dict(chrome=None, screen="terminal", styles=None, builder="term-builder.js",
                            fixture="term-fixture.json", frames=TERM_FRAMES, decisions=TERM_DECISIONS,
                            idioms=None), **changes))


rc, out, term = make("terminal", term_spec())
check("a design drawn in the shared terminal is written", rc == 0 and os.path.isfile(term), out)
tsrc = open(term, encoding="utf-8").read() if os.path.isfile(term) else ""
tm = re.search(r'<script type="application/json" id="design-frames">(.*?)</script>', tsrc, re.S)
check("its frames block records the kind as terminal, for the score",
      tm is not None and json.loads(tm.group(1)).get("kind") == "terminal", tm.group(1) if tm else tsrc[-800:])
check("it says it is the terminal, where a design in chrome names its capture",
      "The Claude Code terminal" in tsrc and "inside the product's real chrome" not in tsrc, tsrc[:900])
fr = subprocess.run([sys.executable, SCORE, "frames", term], capture_output=True, text=True)
check("the score reads its frames at their own sizes",
      fr.returncode == 0 and [(f["id"], f["width"], f.get("height")) for f in json.loads(fr.stdout)["frames"]]
      == [("t1", 640, None), ("t2", 820, 420)], fr.stdout + fr.stderr)
rc2 = subprocess.run([sys.executable, CHECK, term], capture_output=True, text=True)
check("and its decision map holds", rc2.returncode == 0, rc2.stdout + rc2.stderr)
try:
    tchrome = chrome_frame.shared_screen("terminal", TERM_BUILDER, "term-builder.js")
    tdoc = chrome_frame.frame_document(tchrome, TERM_BUILDER, ".term-band { margin: 0; }", {"width": 640}, {"room": "x"})
    check("a terminal frame document holds the shared terminal's script ahead of the round's builder, and its "
          "stylesheet ahead of the round's, in the head",
          # The round's own line, since the terminal's comments show a buildScreen of their own.
          tdoc.index("var Terminal") < tdoc.index("width: variant.width") and tdoc.index(".term-window") < tdoc.index(
              ".term-band { margin: 0; }") < tdoc.index("</head>"), tdoc[:600])
    check("and draws the terminal alone, its slot the body's first element, with no margin",
          re.search(r"<body>\s*<div id=\"dr-slot\"></div>", tdoc) is not None and "html, body { margin: 0; }" in tdoc, tdoc[:600])
except Exception as err:  # noqa: BLE001
    check("chrome_frame draws a terminal frame document", False, repr(err))
for n, (label, s, needle) in enumerate([
    ("the terminal beside a captured page", term_spec(chrome=CHROME), "keep one"),
    ("a builder declaring Terminal itself, which would replace the shared screen",
     term_spec(builder="term-own.js"), "declares Terminal at its top level"),
    ("a builder calling the terminal in a design drawn in captured chrome",
     spec(builder="term-builder.js", fixture="term-fixture.json"), '"screen": "terminal"'),
]):
    if n == 1:
        write("term-own.js", "var Terminal = {};\n" + TERM_BUILDER)
    rc, out, path = make("bad-term-%d" % n, s)
    check("%s is refused, writing nothing" % label, rc == 2 and needle in out and not os.path.exists(path), out)

# --- the design's requirements and its opening paragraph (claude-config#1401) -------------------------
# Slate's Team capacity design, regenerated with make-settled, lost its Requirements list (which the
# decision map's numbers point at) and its intro, because the spec had nowhere to hold them.
import design_score  # noqa: E402

INTRO = "For Sam's team leads, settled over three rounds and approved by Dan on 2026-10-19."
REQS = [{"number": "1", "text": "Sam sees tomorrow's open calls by team."},
        {"number": "2", "text": "Open calls stand out from booked ones <b>at a glance</b>."},
        {"number": "6.4", "text": "History is kept for good."}]
rc, out, rpath = make("requirements", spec(intro=INTRO, requirements=REQS))
check("a spec with an intro and numbered requirements writes the settled design", rc == 0 and os.path.isfile(rpath), out)
rsrc = open(rpath, encoding="utf-8").read() if os.path.isfile(rpath) else ""
rbody = rsrc.split('<script type="application/json"')[0]
check("the intro is the page's opening paragraph, under its title and ahead of everything else",
      "<p>%s</p>" % html.escape(INTRO, quote=True) in rbody
      and rbody.index("<h1>") < rbody.index(html.escape(INTRO, quote=True)) < rbody.index("<h2>"), rbody[:900])
check("the requirements are listed under their own heading, ahead of the decisions that point at them",
      "<h2>Requirements</h2>" in rbody and rbody.index("<h2>Requirements</h2>") < rbody.index("<h2>Decisions</h2>"), rbody[:1500])
check("each requirement shows its own number, as the PRD numbers it, beside its sentence",
      all("<strong>%s</strong> %s" % (r["number"], html.escape(r["text"], quote=True)) in rbody for r in REQS), rbody[:1500])
check("a requirement's sentence is text, never markup", "<b>at a glance</b>" not in rsrc and "&lt;b&gt;at a glance" in rbody)
d1 = re.search(r'<li id="D1">.*?</li>', rbody, re.S)
# Dan, 2026-10-20, on claude-config#1429 (picker answer "Number linked to the list"): a decision shows
# its requirement's number as a link to the list, and the sentence is on the page once, in the list.
# This replaces #1401's "Requirement 1: the sentence" on every decision line.
check("a decision's owner is its requirement's number, linked to the list, with the sentence left to the list",
      d1 is not None and "Requirement 1. Checked on f1, f2" in text_of(d1.group(0))
      and "Sam sees" not in d1.group(0), d1.group(0) if d1 else rbody[:1500])
for r in REQS:
    check("requirement %s's sentence is on the page exactly once" % r["number"],
          rbody.count(html.escape(r["text"], quote=True)) == 1, rbody[:2000])
d3 = re.search(r'<li id="D3">.*?</li>', rbody, re.S)
rc, out, qpath = make("requirements-question", spec(requirements=[
    {"number": "1", "text": "Can Sam see tomorrow's open calls?"}, {"number": "2", "text": "Open calls stand out!"}]))
qsrc = open(qpath, encoding="utf-8").read() if os.path.isfile(qpath) else ""
qbody = qsrc.split('<script type="application/json"')[0]
check("a requirement ending in a question or exclamation mark is listed with its own mark, once",
      qbody.count("open calls?") == 1 and qbody.count("stand out!") == 1 and "?." not in qbody and "!." not in qbody,
      out + qbody[:1200])
check("and a decision with no code consequence still gives its reason", d3 is not None and "No code: already built." in d3.group(0),
      d3.group(0) if d3 else "")
rm = re.search(r'<script type="application/json" id="decision-map">(.*?)</script>', rsrc, re.S)
check("the decision map carries the requirements, so the file alone resolves every number",
      rm is not None and json.loads(rm.group(1)).get("requirements") == REQS, rm.group(1) if rm else rsrc[-800:])
rc2 = subprocess.run([sys.executable, CHECK, rpath], capture_output=True, text=True)
check("its decision map holds by check-decision-map.py's own rule", rc2.returncode == 0, rc2.stdout + rc2.stderr)
try:
    _raw, rdecisions, rframes, _x, _k = design_score.read_design(rpath)
    check("the score still reads its decisions and frames", [d["id"] for d in rdecisions] == ["D1", "D2", "D3"]
          and [f["id"] for f in rframes] == ["f1", "f2"], repr(rdecisions))
except design_score.Unreadable as err:
    check("the score still reads its decisions and frames", False, str(err))
check("it says nothing about missing sentences when the list is given", "without their sentences" not in out, out)

# Without the list, a decision's number is shown alone and the PRD holds the sentence: specs written
# before #1401 keep working, and the page says nothing it was not given.
rc, out, bare = make("no-requirements", spec())
bsrc = open(bare, encoding="utf-8").read() if os.path.isfile(bare) else ""
bm = re.search(r'<script type="application/json" id="decision-map">(.*?)</script>', bsrc, re.S)
check("a spec with no requirements still writes, showing each owner by number alone",
      rc == 0 and "Requirement 1. Checked on f1, f2" in bsrc and "<h2>Requirements</h2>" not in bsrc
      and bm is not None and "requirements" not in json.loads(bm.group(1)), out)
check("and says, without refusing, which numbers the page shows without their sentences",
      "Requirement 1, 2" in out and "without their sentences" in out, out)
check("a spec with no intro has no opening paragraph", "<h1>Team capacity</h1>\n<p class=\"dr-meta\">" in bsrc, bsrc[:600])

for n, (label, s, needle) in enumerate([
    ("a decision naming a requirement the list does not hold",
     spec(requirements=[{"number": "1", "text": "a"}]), "Requirement 2"),
    ("a requirement whose number is not text", spec(requirements=[{"number": 1, "text": "a"}]), "number"),
    ("a requirement with no sentence", spec(requirements=[{"number": "1", "text": " "}]), "sentence"),
    ("two requirements sharing a number",
     spec(requirements=[{"number": "1", "text": "a"}, {"number": "1", "text": "b"}, {"number": "2", "text": "c"}]),
     "share the number 1"),
    ("an empty requirements list", spec(requirements=[]), "requirements"),
    ("requirements that are not a list", spec(requirements={"1": "a"}), "requirements"),
    ("an intro that is not text", spec(intro=["a"]), "intro"),
    ("an intro with nothing in it", spec(intro="  "), "intro"),
]):
    rc, out, path = make("bad-req-%d" % n, s)
    check("%s is refused, writing nothing" % label, rc == 2 and needle in out and not os.path.exists(path), out)
rc, out, _ = make("bad-req-unlisted", spec(requirements=[{"number": "1", "text": "a"}]))
check("the refusal of an unlisted requirement names the decision that cites it", "D2" in out and "UNLISTED" in out, out)


# --- a decision's reason, its owner, and the page in both schemes (claude-config#1426, #1429) ----------
# The #1401 builder's screenshots read "Dan chose it in round 1 Requirement 6.1: ..." run together: the
# reason had no full stop before the muted owner. And the page had fixed light colours, though Dan reads
# it in both schemes.
def decision_text(src, did):
    m = re.search(r'<li id="%s">.*?</li>' % re.escape(did), src, re.S)
    return text_of(m.group(0)) if m else ""


check("a decision's reason ends its sentence before its owner begins, with a requirements list",
      "Sam's word for it. Requirement 1. Checked" in decision_text(rbody, "D1"), decision_text(rbody, "D1"))
check("and without one", "Sam's word for it. Requirement 1. Checked" in decision_text(bsrc, "D1"), decision_text(bsrc, "D1"))
rc, out, mpath = make("marks", spec(decisions=[
    {"id": "D1", "decision": "The page is called Team capacity.", "why": "Is it Sam's word?", "requirement": "1",
     "frames": ["f1"], "check": "main h1 reads Team capacity"},
    {"id": "D2", "decision": "Open calls are sky", "why": "They stand out.", "noCode": "drawn only", "verify": "picture"}]))
msrc = open(mpath, encoding="utf-8").read() if os.path.isfile(mpath) else ""
check("a reason or decision that already ends a sentence keeps its own mark, never doubled",
      "Team capacity. Is it Sam's word? Requirement 1." in decision_text(msrc, "D1")
      and "They stand out. No code: drawn only." in decision_text(msrc, "D2"), out + decision_text(msrc, "D1"))
check("and no decision line has two marks in a row",
      not re.search(r"[.?!]\.", decision_text(msrc, "D1") + decision_text(msrc, "D2")),
      decision_text(msrc, "D1") + " | " + decision_text(msrc, "D2"))
check("a page with no requirements list shows a decision's number alone, linking nowhere",
      "<a " not in re.search(r'<ol class="dr-decisions">.*?</ol>', bsrc, re.S).group(0), bsrc[:1500])


def anchors(src):
    """{number: id} for each listed requirement, and every id the page's markup holds."""
    body = src.split('<script type="application/json"')[0]
    listed = re.search(r'<ul class="dr-requirements">(.*?)</ul>', body, re.S)
    found = {}
    for rid, number in re.findall(r'<li id="([^"]+)"[^>]*><strong>(.*?)</strong>', listed.group(1) if listed else ""):
        found[html.unescape(number)] = rid
    return found, re.findall(r'\bid="([^"]+)"', body)


rfound, rids = anchors(rsrc)
check("each listed requirement carries an anchor", sorted(rfound) == sorted(r["number"] for r in REQS), repr(rfound))
for d in ("D1", "D2"):
    m = re.search(r'<li id="%s">.*?</li>' % d, rbody, re.S)
    link = re.search(r'<a href="#([^"]+)">Requirement ([^<]+)</a>', m.group(0)) if m else None
    check("decision %s links its requirement's number to that requirement's entry in the list" % d,
          link is not None and rfound.get(html.unescape(link.group(2))) == link.group(1), m.group(0) if m else rbody[:900])

# Numbers are text exactly as the PRD writes them, so anchors are derived to be safe in a fragment and
# unique on the page, whatever two numbers look like once their unsafe characters are replaced, and
# whatever a decision happens to be called.
ODD = [{"number": "6.4", "text": "Six point four"}, {"number": "6-4", "text": "Six dash four"},
       {"number": "6 4", "text": "Six space four"}, {"number": "R 1/2", "text": "R one of two"},
       {"number": "é1", "text": "Accented"}, {"number": "1", "text": "One"}]
ODD_DECISIONS = [{"id": "req-1", "decision": "Named like an anchor", "requirement": "1", "verify": "picture"}] + [
    {"id": "D%d" % n, "decision": "Cites %s" % r["number"], "requirement": r["number"], "verify": "picture"}
    for n, r in enumerate(ODD)]
rc, out, opath = make("odd-numbers", spec(requirements=ODD, decisions=ODD_DECISIONS))
osrc = open(opath, encoding="utf-8").read() if os.path.isfile(opath) else ""
ofound, oids = anchors(osrc)
check("a page whose requirement numbers clash once made safe is written", rc == 0 and len(ofound) == len(ODD), out + repr(ofound))
check("every requirement's anchor is safe in a fragment: a letter, then letters, digits, hyphens and underscores",
      all(re.match(r"^[A-Za-z][A-Za-z0-9_-]*$", a) for a in ofound.values()), repr(ofound))
check("and no two ids on the page are the same, a decision's included", len(oids) == len(set(oids)), repr(oids))
obody = osrc.split('<script type="application/json"')[0]
links = re.findall(r'<li id="([^"]+)">.*?<a href="#([^"]+)">Requirement ([^<]+)</a>', obody, re.S)
check("each decision's link lands on the entry for the number it names",
      len(links) == len(ODD_DECISIONS) and all(ofound.get(html.unescape(n)) == target for _d, target, n in links), repr(links))


def schemes(css):
    """The colour tokens the page defines for light (on :root) and for dark (under the media query)."""
    light = re.search(r"(?<![\w-]):root\s*\{([^}]*)\}", css)
    dark = re.search(r"@media\s*\(prefers-color-scheme:\s*dark\)\s*\{\s*:root\s*\{([^}]*)\}", css)
    read = lambda block: dict(re.findall(r"(--dr-[\w-]+):\s*(#[0-9A-Fa-f]{6})\s*;", block.group(1))) if block else {}  # noqa: E731
    return read(light), read(dark)


def contrast(a, b):
    def lum(h):
        c = [int(h[i:i + 2], 16) / 255.0 for i in (1, 3, 5)]
        c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    hi, lo = sorted((lum(a), lum(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


for label, page_src in (("a page with requirements", rsrc), ("a page without", bsrc)):
    css = re.search(r"<style>(.*?)</style>", page_src, re.S).group(1)
    light, dark = schemes(css)
    check("%s defines its colours as tokens on :root, and every one again for the dark scheme" % label,
          light and set(light) == set(dark), "light=%r dark=%r" % (light, dark))
    rules = re.sub(r"@media\s*\(prefers-color-scheme:\s*dark\)\s*\{\s*:root\s*\{[^}]*\}\s*\}", "",
                   re.sub(r"(?<![\w-]):root\s*\{[^}]*\}", "", css))
    check("%s uses no colour outside its tokens, so nothing stays light in the dark scheme" % label,
          not re.search(r"#[0-9A-Fa-f]{3,8}\b|rgb\(", rules) and "var(--dr-bg)" in rules, rules)
    for scheme, tokens in (("light", light), ("dark", dark)):
        for fg, bg in (("--dr-text", "--dr-bg"), ("--dr-muted", "--dr-bg"), ("--dr-link", "--dr-bg"),
                       ("--dr-text", "--dr-target")):
            ratio = contrast(tokens[fg], tokens[bg]) if fg in tokens and bg in tokens else 0
            check("%s, %s: %s on %s reads at 4.5 to 1 or better" % (label, scheme, fg, bg), ratio >= 4.5,
                  "%.2f" % ratio)

# --- in a real browser, where there is one ------------------------------------------------------------
CHROME_APP = os.environ.get("SETTLED_TEST_CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
HEADLESS_DOM = os.path.join(SKILL, "headless-dom.sh")
if not os.access(CHROME_APP, os.X_OK):
    print("UNMEASURED: no Chrome at %s, so the settled file's frames were not drawn in a browser" % CHROME_APP)
else:
    probe = src.replace("</body></html>", """<script>
var out = [];
["f1", "f2"].forEach(function (id) {
  var d = new DOMParser().parseFromString(designFrameDocument(id), "text/html");
  out.push(id + "=" + (d.querySelector("#main") ? "slot" : "noslot"));
});
try { designFrameDocument("f9"); out.push("f9=drawn"); } catch (e) { out.push("f9=refused"); }
var pre = document.createElement("pre"); pre.id = "PROBE"; pre.textContent = out.join(","); document.body.append(pre);
</script></body></html>""")
    with open(os.path.join(T, "probe.html"), "w", encoding="utf-8") as fh:
        fh.write(probe)
    proc = subprocess.run(["bash", HEADLESS_DOM, "--headless", "--disable-gpu", "--no-sandbox", "--dump-dom",
                           "file://" + os.path.join(T, "probe.html")], capture_output=True, text=True,
                          env=dict(os.environ, HEADLESS_DOM_CHROME=CHROME_APP, HEADLESS_DOM_DEADLINE="60"))
    m = re.search(r'<pre id="PROBE">(.*?)</pre>', proc.stdout, re.S)
    check("in Chrome, designFrameDocument gives each frame's whole document and refuses an unknown one",
          proc.returncode == 0 and m and m.group(1) == "f1=slot,f2=slot,f9=refused", (m.group(1) if m else proc.stdout[-500:] + proc.stderr[-500:]))

    # A decision's requirement link, driven as a keyboard user drives it: it takes focus, its name read
    # alone says what it is, and following it puts focus on the requirement it names, so a screen reader
    # reads the sentence next (claude-config#1429). And the page's colours follow the scheme Chrome is
    # told to prefer, given explicitly because left alone it follows the Mac's own (#1426).
    lprobe = rsrc.replace("</body></html>", """<script>
var link = document.querySelector('.dr-decisions a[href^="#"]'), out = [];
link.focus();
out.push(document.activeElement === link ? "focused" : "unfocused", link.tabIndex, link.textContent);
window.addEventListener("hashchange", function () {
  var target = document.getElementById(link.getAttribute("href").slice(1));
  out.push(document.activeElement === target ? "landed" : "notlanded:" + document.activeElement.tagName,
           target && target.closest(".dr-requirements") ? "inlist" : "elsewhere");
  out.push(getComputedStyle(document.body).backgroundColor, getComputedStyle(document.body).color);
  var pre = document.createElement("pre"); pre.id = "PROBE"; pre.textContent = out.join("|"); document.body.append(pre);
}, {once: true});
link.click();
</script></body></html>""")
    with open(os.path.join(T, "lprobe.html"), "w", encoding="utf-8") as fh:
        fh.write(lprobe)
    seen = {}
    for scheme, setting in (("light", "1"), ("dark", "0")):
        proc = subprocess.run(["bash", HEADLESS_DOM, "--headless", "--disable-gpu", "--no-sandbox", "--virtual-time-budget=5000",
                               "--blink-settings=preferredColorScheme=" + setting,
                               "--dump-dom", "file://" + os.path.join(T, "lprobe.html")], capture_output=True, text=True,
                              env=dict(os.environ, HEADLESS_DOM_CHROME=CHROME_APP, HEADLESS_DOM_DEADLINE="60"))
        m = re.search(r'<pre id="PROBE">(.*?)</pre>', proc.stdout, re.S)
        seen[scheme] = m.group(1).split("|") if m and proc.returncode == 0 else [
            "rc=%d" % proc.returncode, proc.stdout[-500:] + proc.stderr[-500:]]
    check("in Chrome, a decision's requirement link takes keyboard focus and is named by its own text",
          seen["light"][:3] == ["focused", "0", "Requirement 1"], repr(seen["light"]))
    check("and following it puts focus on that requirement in the list",
          seen["light"][3:5] == ["landed", "inlist"], repr(seen["light"]))
    light_bg, dark_bg = (seen[s][5] if len(seen[s]) > 6 else "" for s in ("light", "dark"))
    lum = lambda rgb: sum(int(x) for x in re.findall(r"\d+", rgb)[:3])  # noqa: E731
    check("in Chrome, the page is light when light is preferred and dark when dark is",
          light_bg and dark_bg and lum(light_bg) > 600 and lum(dark_bg) < 150, repr(seen))

    # The email design's frame drawn for real, as the web adapter draws it: a document of its own whose
    # body holds the round's drawing and nothing else (claude-config#1393).
    nprobe = nsrc.replace("</body></html>", """<script>
var f = document.createElement("iframe");
f.style.cssText = "width:390px;height:300px;border:0";
f.onload = function () {
  var d = f.contentDocument, slot = d.getElementById("dr-slot");
  var out = [d.body.firstElementChild === slot ? "bare" : "around", slot ? (slot.textContent.indexOf("Wed: 17 calls open") >= 0 ? "drawn" : slot.textContent.slice(0, 40)) : "noslot",
             String(d.body.getBoundingClientRect().left)];
  var pre = document.createElement("pre"); pre.id = "PROBE"; pre.textContent = out.join("|"); document.body.append(pre);
};
f.srcdoc = designFrameDocument("f2");
document.body.append(f);
</script></body></html>""")
    with open(os.path.join(T, "nprobe.html"), "w", encoding="utf-8") as fh:
        fh.write(nprobe)
    proc = subprocess.run(["bash", HEADLESS_DOM, "--headless", "--disable-gpu", "--no-sandbox", "--virtual-time-budget=5000",
                           "--dump-dom", "file://" + os.path.join(T, "nprobe.html")], capture_output=True, text=True,
                          env=dict(os.environ, HEADLESS_DOM_CHROME=CHROME_APP, HEADLESS_DOM_DEADLINE="60"))
    m = re.search(r'<pre id="PROBE">(.*?)</pre>', proc.stdout, re.S)
    check("in Chrome, an email frame is drawn from the fixture with nothing around it and no margin",
          proc.returncode == 0 and m and m.group(1) == "bare|drawn|0", (m.group(1) if m else proc.stdout[-500:] + proc.stderr[-500:]))

    # Each terminal frame drawn for real, as the web adapter draws it: the dark terminal window alone,
    # from the fixture, at exactly the frame's width, at the top left with nothing around it (#1413).
    tprobe = tsrc.replace("</body></html>", """<script>
var out = [], left = 2;
[["t1", 640], ["t2", 820]].forEach(function (pair) {
  var f = document.createElement("iframe");
  f.style.cssText = "width:" + pair[1] + "px;height:500px;border:0";
  f.onload = function () {
    var d = f.contentDocument, slot = d.getElementById("dr-slot"), win = slot && slot.querySelector(".term-window");
    var r = win ? win.getBoundingClientRect() : null;
    out.push(pair[0] + ":" + [d.body.firstElementChild === slot ? "bare" : "around",
             win ? "window" : "nowindow", r ? r.width + "x" + r.left + "," + r.top : "-",
             win ? getComputedStyle(win).backgroundColor : "-",
             slot && slot.textContent.indexOf("Work has more room  5h 12%, week 30%") >= 0 ? "drawn" : "notdrawn"].join("|"));
    if (--left === 0) {
      var pre = document.createElement("pre"); pre.id = "PROBE"; pre.textContent = out.sort().join(";"); document.body.append(pre);
    }
  };
  f.srcdoc = designFrameDocument(pair[0]);
  document.body.append(f);
});
</script></body></html>""")
    with open(os.path.join(T, "tprobe.html"), "w", encoding="utf-8") as fh:
        fh.write(tprobe)
    proc = subprocess.run(["bash", HEADLESS_DOM, "--headless", "--disable-gpu", "--no-sandbox", "--virtual-time-budget=5000",
                           "--dump-dom", "file://" + os.path.join(T, "tprobe.html")], capture_output=True, text=True,
                          env=dict(os.environ, HEADLESS_DOM_CHROME=CHROME_APP, HEADLESS_DOM_DEADLINE="60"))
    m = re.search(r'<pre id="PROBE">(.*?)</pre>', proc.stdout, re.S)
    check("in Chrome, each terminal frame is the terminal window alone, drawn from the fixture at its own width",
          proc.returncode == 0 and m and m.group(1) == ("t1:bare|window|640x0,0|rgb(27, 27, 29)|drawn;"
                                                         "t2:bare|window|820x0,0|rgb(27, 27, 29)|drawn"),
          (m.group(1) if m else proc.stdout[-500:] + proc.stderr[-500:]))

    # capture-chrome.js, run in a page as Playwright's browser_evaluate would: the page's own rules
    # inlined, its scripts taken out, and a stylesheet it cannot read NAMED, never silently dropped.
    snippet = open(os.path.join(SKILL, "capture-chrome.js"), encoding="utf-8").read()
    write("linked.css", "nav { color: red; }\n")
    cap_page = """<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="linked.css">
<style>header { background: rgb(20, 33, 61); }</style></head>
<body><header>Slate</header><main id="main">x</main><script>window.APP_RAN = 1;</script>
<script>
var run = (%s);
run().then(function (doc) { var pre = document.createElement("pre"); pre.id = "PROBE"; pre.textContent = doc; document.body.append(pre); });
</script></body></html>""" % snippet
    write("capture-probe.html", cap_page)
    proc = subprocess.run(["bash", HEADLESS_DOM, "--headless", "--disable-gpu", "--no-sandbox", "--virtual-time-budget=5000",
                           "--dump-dom", "file://" + os.path.join(T, "capture-probe.html")], capture_output=True, text=True,
                          env=dict(os.environ, HEADLESS_DOM_CHROME=CHROME_APP, HEADLESS_DOM_DEADLINE="60"))
    m = re.search(r'<pre id="PROBE">(.*?)</pre>', proc.stdout, re.S)
    captured = html_unescape(m.group(1)) if m else ""
    check("capture-chrome.js gives a whole page with the page's own rules inlined",
          proc.returncode == 0 and captured.startswith("<!doctype html>") and "rgb(20, 33, 61)" in captured and 'id="main"' in captured,
          captured[:600] or proc.stdout[-600:] + proc.stderr[-300:])
    check("with every script taken out, so the chrome is drawn, never run", "APP_RAN" not in captured, captured[-400:])
    check("naming the stylesheet it could not read, rather than leaving it out silently",
          "NOT inlined" in captured and "linked.css" in captured, captured[:400])

shutil.rmtree(T, ignore_errors=True)
print()
print("passed: %d, failed: %d" % (passed, failed))
print("SUITE-RESULT passed=%d failed=%d" % (passed, failed))
sys.exit(1 if failed else 0)
