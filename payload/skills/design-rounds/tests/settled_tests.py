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
