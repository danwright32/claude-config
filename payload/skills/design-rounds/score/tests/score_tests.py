#!/usr/bin/env python3
"""The checks behind test-design-score.sh (claude-config#1364): the PNG reader and writer, and the
score a build gets against its settled design. Every design file, capture and picture is written
here into a throwaway folder; only the decoder fixtures in fixtures/ are committed.

PNGs are made by an encoder written here, separately from pngio.py, so a reader bug cannot be
cancelled out by the same bug in the writer, and the committed fixtures are checked against the
pixels Pillow decodes from them (fixtures/expected.json).
"""
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SCORE_DIR = os.path.dirname(HERE)
SCORE = os.path.join(SCORE_DIR, "design_score.py")
sys.path.insert(0, SCORE_DIR)

passed = 0
failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print("FAIL: " + name)
        if detail:
            for line in str(detail).splitlines()[:40]:
                print("    " + line)


# --- an encoder of our own, independent of pngio ------------------------------------------------

def _chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def encode(w, h, samples, colortype=6, depth=8, filt=0, palette=None, interlace=0):
    """samples: the raw sample bytes of every row, unfiltered, in the given colour type and depth."""
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colortype]
    bpp = max(1, channels * depth // 8)
    stride = w * channels * depth // 8
    out = bytearray()
    prev = bytes(stride)
    for y in range(h):
        row = samples[y * stride:(y + 1) * stride]
        f = filt if isinstance(filt, int) else filt[y % len(filt)]
        enc = bytearray()
        for i, x in enumerate(row):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            pred = [0, a, b, (a + b) // 2, _paeth(a, b, c)][f]
            enc.append((x - pred) & 255)
        out.append(f)
        out += enc
        prev = row
    png = b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, colortype, 0, 0, interlace))
    if palette is not None:
        png += _chunk(b"PLTE", bytes(palette))
    png += _chunk(b"IDAT", zlib.compress(bytes(out)))
    return png + _chunk(b"IEND", b"")


def rgba_image(w, h, fill, sets=()):
    px = bytearray(bytes(fill) * (w * h))
    for (x, y, colour) in sets:
        k = (y * w + x) * 4
        px[k:k + 4] = bytes(colour)
    return bytes(px)


def write(path, data):
    with open(path, "wb") as fh:
        fh.write(data)


def run(*args):
    proc = subprocess.run([sys.executable, SCORE] + list(args), capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


# --- the reader -----------------------------------------------------------------------------------
import pngio  # noqa: E402

T = tempfile.mkdtemp(prefix="design-score-test.")
W, H = 7, 5
src = bytes((x * 37 + y * 11 + c * 50) % 256 for y in range(H) for x in range(W) for c in range(4))
for f in range(5):
    p = os.path.join(T, "filter%d.png" % f)
    write(p, encode(W, H, src, 6, 8, f))
    try:
        got = pngio.read_png(p)
        check("RGBA with filter %d decodes to the pixels it was made from" % f, got == (W, H, src), got[:2])
    except Exception as e:  # noqa: BLE001
        check("RGBA with filter %d decodes" % f, False, repr(e))

write(os.path.join(T, "mixed.png"), encode(W, H, src, 6, 8, [0, 1, 2, 3, 4]))
check("rows using every filter in turn decode", pngio.read_png(os.path.join(T, "mixed.png")) == (W, H, src))

rgb = bytes(b for i, b in enumerate(src) if i % 4 != 3)
write(os.path.join(T, "rgb.png"), encode(W, H, rgb, 2, 8, 4))
want_rgb = bytes(b for i in range(0, len(rgb), 3) for b in (rgb[i], rgb[i + 1], rgb[i + 2], 255))
check("8 bit RGB decodes with an opaque alpha", pngio.read_png(os.path.join(T, "rgb.png")) == (W, H, want_rgb))

grey = bytes(src[i] for i in range(0, len(src), 4))
write(os.path.join(T, "grey.png"), encode(W, H, grey, 0, 8, 1))
check("8 bit grey decodes", pngio.read_png(os.path.join(T, "grey.png")) == (W, H, bytes(b for g in grey for b in (g, g, g, 255))))

ga = bytes(b for i in range(0, len(src), 4) for b in (src[i], src[i + 3]))
write(os.path.join(T, "ga.png"), encode(W, H, ga, 4, 8, 3))
check("8 bit grey with alpha decodes",
      pngio.read_png(os.path.join(T, "ga.png")) == (W, H, bytes(b for i in range(0, len(ga), 2) for b in (ga[i], ga[i], ga[i], ga[i + 1]))))

pal = [10, 20, 30, 200, 100, 50, 0, 255, 0]
idx = bytes((x + y) % 3 for y in range(H) for x in range(W))
write(os.path.join(T, "pal.png"), encode(W, H, idx, 3, 8, 2, palette=pal))
check("8 bit palette decodes",
      pngio.read_png(os.path.join(T, "pal.png")) == (W, H, bytes(b for i in idx for b in (pal[3 * i], pal[3 * i + 1], pal[3 * i + 2], 255))))

rgb16 = bytes(b for v in rgb for b in (v, 0x7F))
write(os.path.join(T, "rgb16.png"), encode(W, H, rgb16, 2, 16, 4))
check("16 bit RGB decodes to its high bytes", pngio.read_png(os.path.join(T, "rgb16.png")) == (W, H, want_rgb))

with open(os.path.join(HERE, "fixtures", "expected.json")) as fh:
    expected = json.load(fh)
for name, want in expected.items():
    if name == "about":
        continue
    w, h, px = pngio.read_png(os.path.join(HERE, "fixtures", name))
    check("%s decodes to the pixels Pillow reads from it" % name,
          (w, h, hashlib.sha256(px).hexdigest()) == (want["width"], want["height"], want["rgbaSha256"]),
          (w, h, hashlib.sha256(px).hexdigest()))

write(os.path.join(T, "laced.png"), encode(W, H, src, 6, 8, 0, interlace=1))
try:
    pngio.read_png(os.path.join(T, "laced.png"))
    check("an interlaced PNG is refused by name", False, "it was read")
except pngio.PngError as e:
    check("an interlaced PNG is refused by name", "interlaced" in str(e), str(e))

good = encode(W, H, src, 6, 8, 0)
write(os.path.join(T, "cut.png"), good[: len(good) // 2])
write(os.path.join(T, "notpng.png"), b"GIF89a not a png at all")
for name in ("cut.png", "notpng.png", "absent.png"):
    try:
        pngio.read_png(os.path.join(T, name))
        check("%s is refused" % name, False, "it was read")
    except pngio.PngError as e:
        check("%s is refused with a PngError naming the file" % name, name in str(e), str(e))

pngio.write_png(os.path.join(T, "written.png"), W, H, src)
check("what write_png writes reads back as the same pixels", pngio.read_png(os.path.join(T, "written.png")) == (W, H, src))
try:
    pngio.write_png(os.path.join(T, "short.png"), W, H, src[:-1])
    check("write_png refuses pixels that do not fill the picture", False, "it wrote")
except pngio.PngError:
    check("write_png refuses pixels that do not fill the picture", True)


# --- the score ------------------------------------------------------------------------------------
FW, FH = 40, 30
LIGHT = (246, 239, 227, 255)
DARK = (20, 30, 50, 255)


def make(name, mutate=None):
    """A scenario that matches on both halves, changed by mutate(s) before it is written."""
    d = os.path.join(T, name)
    os.makedirs(d)
    s = {
        "map": {"decisions": [
            {"id": "D1", "decision": "The heading reads Team capacity", "requirement": "1"},
            {"id": "D2", "decision": "The day cards lead", "requirement": "2"},
        ]},
        "frames": {"frames": [
            {"id": "f1", "title": "Tomorrow, light", "width": FW},
            {"id": "f2", "title": "Tomorrow, dark", "width": FW},
        ]},
        "exceptions": None,
        "images": {"f1": (rgba_image(FW, FH, LIGHT), (FW, FH), rgba_image(FW, FH, LIGHT), (FW, FH)),
                   "f2": (rgba_image(FW, FH, DARK), (FW, FH), rgba_image(FW, FH, DARK), (FW, FH))},
        "capture": {
            "format": "design-capture", "version": 1, "platform": "web",
            "build": "http://127.0.0.1:3000/admin/team-capacity", "commit": "a" * 40, "dirty": False,
            "capturedAt": "2026-10-19T23:00:00Z",
            "frames": [
                {"id": "f1", "designImage": "f1-design.png", "builtImage": "f1-built.png",
                 "checks": [{"id": "D1", "ok": True, "detail": ""}, {"id": "D2", "ok": True, "detail": ""}],
                 "designChecks": [{"id": "D1", "ok": True, "detail": ""}, {"id": "D2", "ok": True, "detail": ""}]},
                {"id": "f2", "designImage": "f2-design.png", "builtImage": "f2-built.png",
                 "checks": [{"id": "D1", "ok": True, "detail": ""}],
                 "designChecks": [{"id": "D1", "ok": True, "detail": ""}]},
            ],
        },
        "raw_design": None,
    }
    if mutate:
        mutate(s)
    design = os.path.join(d, "settled.html")
    if s["raw_design"] is not None:
        body = s["raw_design"]
    else:
        body = "<!doctype html><html><head><title>Team capacity</title></head><body>\n"
        if s["map"] is not None:
            body += '<script type="application/json" id="decision-map">\n%s\n</script>\n' % json.dumps(s["map"])
        if s["frames"] is not None:
            body += '<script type="application/json" id="design-frames">\n%s\n</script>\n' % json.dumps(s["frames"])
        if s["exceptions"] is not None:
            body += '<script type="application/json" id="design-exceptions">\n%s\n</script>\n' % json.dumps(s["exceptions"])
        body += "</body></html>\n"
    with open(design, "w") as fh:
        fh.write(body)
    for fid, (dpx, dsize, bpx, bsize) in s["images"].items():
        if dpx is not None:
            write(os.path.join(d, fid + "-design.png"), encode(dsize[0], dsize[1], dpx))
        if bpx is not None:
            write(os.path.join(d, fid + "-built.png"), encode(bsize[0], bsize[1], bpx))
    cap = s["capture"]
    if isinstance(cap, dict):
        cap.setdefault("designFile", design)
        with open(os.path.join(d, "capture.json"), "w") as fh:
            json.dump(cap, fh)
    elif isinstance(cap, str):
        with open(os.path.join(d, "capture.json"), "w") as fh:
            fh.write(cap)
    return d


def score(d):
    rc, out = run("score", d)
    data = None
    if os.path.exists(os.path.join(d, "score.json")):
        with open(os.path.join(d, "score.json")) as fh:
            data = json.load(fh)
    return rc, out, data


# 1. A build that matches on both halves.
d = make("matched")
rc, out, data = score(d)
check("a build matching every decision and every frame exits 0", rc == 0, "rc=%d\n%s" % (rc, out))
check("and says both halves are 100%", "MATCHED: both halves are 100%" in out, out)
check("and prints the decision half", "decisions  2 of 2 met (100%)" in out, out)
check("and prints the picture half", "pictures   100% of pixels match over 2 frames" in out, out)
check("and says how many exceptions it skipped, none included", "exceptions none recorded in the design" in out, out)
check("the score file has the one format", data is not None and data.get("format") == "design-score" and data.get("version") == 1, data)
check("the score file records the verdict, halves and tolerance",
      data and data["verdict"] == "matched" and data["decisions"]["met"] == 2 and data["decisions"]["of"] == 2
      and data["pictures"]["score"] == 1 and data["tolerance"] == 8, data)
check("the score file names the commit and platform it scored",
      data and data["commit"] == "a" * 40 and data["dirty"] is False and data["platform"] == "web", data)
with open(os.path.join(d, "settled.html"), "rb") as fh:
    design_bytes = fh.read()
check("the score file names the design by a hash of its bytes as committed",
      data and data.get("designSha256") == hashlib.sha256(design_bytes).hexdigest(), data and data.get("designSha256"))
d_crlf = make("crlf", lambda s: s.__setitem__("raw_design", None))
with open(os.path.join(d_crlf, "settled.html"), "rb") as fh:
    crlf_bytes = fh.read().replace(b"\n", b"\r\n")
with open(os.path.join(d_crlf, "settled.html"), "wb") as fh:
    fh.write(crlf_bytes)
rc, out, data_crlf = score(d_crlf)
check("a design saved with CRLF line ends is hashed as its bytes, not as Python reads its text",
      data_crlf and data_crlf.get("designSha256") == hashlib.sha256(crlf_bytes).hexdigest(), out)
check("a diff picture is written for each frame", os.path.exists(os.path.join(d, "f1-diff.png")) and os.path.exists(os.path.join(d, "f2-diff.png")))

# 2. The tolerance edge: 8 levels on one channel still matches, 9 does not.
def nudge(by):
    def m(s):
        c = (LIGHT[0] - by, LIGHT[1], LIGHT[2], 255)
        s["images"]["f1"] = (rgba_image(FW, FH, LIGHT), (FW, FH), rgba_image(FW, FH, LIGHT, [(5, 6, c)]), (FW, FH))
    return m


rc, out, data = score(make("tol8", nudge(8)))
check("a pixel 8 levels off on one channel is within the tolerance", rc == 0, out)
d = make("tol9", nudge(9))
rc, out, data = score(d)
check("a pixel 9 levels off is a difference, exit 1", rc == 1, "rc=%d\n%s" % (rc, out))
check("one pixel in 1200 is never printed as 100%", "100%" not in out.split("pictures")[1].splitlines()[0], out)
check("it is printed rounded down, 99.9%", "99.9% of pixels match" in out, out)
check("the frame that differs is named", "f1" in out and "not matched yet" in out, out)
f1 = [f for f in data["pictures"]["frames"] if f["id"] == "f1"][0] if data else {}
check("the score file counts the one pixel", f1.get("compared") == FW * FH and f1.get("matched") == FW * FH - 1, f1)
w, h, diff = pngio.read_png(os.path.join(d, "f1-diff.png"))
k = (6 * w + 5) * 4
check("the diff picture marks the differing pixel red", tuple(diff[k:k + 3]) == (255, 0, 0), tuple(diff[k:k + 4]))
check("and leaves a matching pixel unmarked", tuple(diff[0:3]) != (255, 0, 0), tuple(diff[0:4]))

# 3. Area only one side has counts as different, never as matching.
rc, out, data = score(make("taller", lambda s: s["images"].__setitem__(
    "f2", (rgba_image(FW, FH, DARK), (FW, FH), rgba_image(FW, FH + 10, DARK), (FW, FH + 10)))))
f2 = [f for f in data["pictures"]["frames"] if f["id"] == "f2"][0] if data else {}
check("a built page taller than its frame is a difference", rc == 1 and f2.get("compared") == FW * (FH + 10) and f2.get("matched") == FW * FH, (rc, f2, out))

# 4. Decisions: met only when passing on every frame they are checked on.
def fail_d1_on_f2(s):
    s["capture"]["frames"][1]["checks"] = [{"id": "D1", "ok": False, "detail": "the heading reads Capacity"}]


rc, out, data = score(make("unmet", fail_d1_on_f2))
check("a decision failing on one of its frames is unmet, exit 1", rc == 1, out)
check("and is named with the frame and what was found", "D1" in out and "f2" in out and "the heading reads Capacity" in out, out)
check("the decision half reads 1 of 2", "decisions  1 of 2 met (50.0%)" in out, out)

# 5. The map is the denominator: a decision with no check is not met.
def add_unchecked(s):
    s["map"]["decisions"].append({"id": "D3", "decision": "Advisors ordered by name", "requirement": "5"})


rc, out, data = score(make("unchecked", add_unchecked))
check("a decision in the map with no check counts against the score", rc == 1 and "decisions  2 of 3 met" in out, out)
check("and is named as having no check", "UNCHECKED D3" in out, out)

# 6. A decision too visual for a check rests on the picture half; one proven elsewhere says where.
def add_verify(s):
    s["map"]["decisions"].append({"id": "D3", "decision": "The bars are sky", "requirement": "5", "verify": "picture"})
    s["map"]["decisions"].append({"id": "D4", "decision": "History kept for good", "requirement": "15",
                                  "verify": "elsewhere", "provenBy": "scripts/test-capacity-history.ts"})


rc, out, data = score(make("verify", add_verify))
check("picture and elsewhere decisions are not in the decision denominator", rc == 0 and "decisions  2 of 2 met" in out, out)
check("the picture decision is listed by name", "D3 rests on the picture half" in out, out)
check("the elsewhere decision is listed with where it is proven", "D4 is proven elsewhere: scripts/test-capacity-history.ts" in out, out)

rc, out, _ = score(make("elsewhere-unsaid", lambda s: s["map"]["decisions"].append(
    {"id": "D3", "decision": "x", "requirement": "5", "verify": "elsewhere"})))
check("an elsewhere decision that does not say where is no score, exit 2", rc == 2 and "D3" in out, out)
rc, out, _ = score(make("verify-typo", lambda s: s["map"]["decisions"].append(
    {"id": "D3", "decision": "x", "requirement": "5", "verify": "pictures"})))
check("a verify value the score does not know is no score", rc == 2 and "pictures" in out, out)
rc, out, _ = score(make("picture-checked", lambda s: s["map"]["decisions"][1].__setitem__("verify", "picture")))
check("a decision marked picture that also has a check is no score, since it cannot be both", rc == 2 and "D2" in out, out)

# 7. The positive control: the design failing its own check means the check is wrong.
def design_fails(s):
    s["capture"]["frames"][0]["designChecks"][1] = {"id": "D2", "ok": False, "detail": "no day cards"}


rc, out, _ = score(make("design-fails", design_fails))
check("the design failing its own check is no score, exit 2", rc == 2, out)
check("and says the check is wrong, not the build", "the design fails its own check" in out and "D2" in out, out)
check("a no score never prints MATCHED", "MATCHED" not in out, out)

rc, out, _ = score(make("threw", lambda s: s["capture"]["frames"][0]["checks"].__setitem__(
    0, {"id": "D1", "ok": False, "detail": "TypeError: x is null", "threw": True})))
check("a check that threw is no score", rc == 2 and "threw" in out, out)

rc, out, _ = score(make("stray", lambda s: s["capture"]["frames"][0]["checks"].append({"id": "D9", "ok": True, "detail": ""})))
check("a check for a decision the map does not hold is no score", rc == 2 and "D9" in out, out)

def no_control(s):
    for f in s["capture"]["frames"]:
        del f["designChecks"]
    s["capture"]["platform"] = "swiftui"


rc, out, _ = score(make("no-control", no_control))
check("checks with no run against the design still score", rc == 0, out)
check("and say they have no positive control", "not run against the design" in out, out)

# 8. Unmeasured is never 100: every way the score cannot be read is exit 2, by name.
rc, out, _ = score(make("missing-frame", lambda s: s["capture"]["frames"].pop()))
check("a design frame the capture lacks is no score", rc == 2 and "f2" in out and "no picture" in out, out)
rc, out, _ = score(make("extra-frame", lambda s: s["capture"]["frames"].append(
    {"id": "f9", "designImage": "f1-design.png", "builtImage": "f1-built.png", "checks": []})))
check("a captured frame the design does not declare is no score", rc == 2 and "f9" in out, out)
rc, out, _ = score(make("missing-image", lambda s: s["images"].__setitem__("f1", (rgba_image(FW, FH, LIGHT), (FW, FH), None, None))))
check("a built picture that is not there is no score", rc == 2 and "f1-built.png" in out, out)
rc, out, _ = score(make("wrong-width", lambda s: s["images"].__setitem__(
    "f1", (rgba_image(FW + 2, FH, LIGHT), (FW + 2, FH), rgba_image(FW + 2, FH, LIGHT), (FW + 2, FH)))))
check("a design picture not drawn at its frame's width is no score", rc == 2 and "42" in out and "40" in out, out)
rc, out, _ = score(make("height", lambda s: s["frames"]["frames"][0].__setitem__("height", FH + 5)))
check("a design picture not drawn at its frame's declared height is no score", rc == 2 and str(FH + 5) in out, out)
rc, out, _ = score(make("load-error", lambda s: s["capture"]["frames"][1].__setitem__("builtError", "net::ERR_CONNECTION_REFUSED")))
check("a built page that could not be loaded is no score", rc == 2 and "ERR_CONNECTION_REFUSED" in out, out)
rc, out, _ = score(make("no-capture", lambda s: s.__setitem__("capture", None)))
check("a folder with no capture is no score", rc == 2 and "capture.json" in out, out)
rc, out, _ = score(make("bad-capture", lambda s: s.__setitem__("capture", "{ not json")))
check("a capture that is not JSON is no score", rc == 2, out)
rc, out, _ = score(make("wrong-version", lambda s: s["capture"].__setitem__("version", 2)))
check("a capture in a version the score does not read is no score", rc == 2 and "version" in out, out)
rc, out, _ = score(make("no-frames-block", lambda s: s.__setitem__("frames", None)))
check("a design with no frames block is no score", rc == 2 and "design-frames" in out, out)
rc, out, _ = score(make("no-map", lambda s: s.__setitem__("map", None)))
check("a design with no decision map is no score", rc == 2 and "decision-map" in out, out)
rc, out, _ = score(make("all-unchecked", lambda s: (
    [d.__setitem__("verify", "picture") for d in s["map"]["decisions"]],
    [f.__setitem__("checks", []) or f.__setitem__("designChecks", []) for f in s["capture"]["frames"]]) and None))
check("a design with no decision left to check is no score, never a vacuous 100%", rc == 2 and "no decision" in out, out)
rc, out, data = score(make("dirty", lambda s: s["capture"].__setitem__("dirty", True)))
check("a build with uncommitted changes still scores", rc == 0, out)
check("and says so, since the score is then tied to no commit", "uncommitted" in out and data and data["dirty"] is True, out)

# 9. Exceptions, each in Dan's words, skipped by the score and listed every time.
EXC = {"id": "X1", "words": "the date picker can use the system font, that's fine", "date": "2026-10-19",
       "source": "https://github.com/Try-Pennie/slate/issues/3941#issuecomment-1"}


def except_decision(s):
    fail_d1_on_f2(s)
    s["exceptions"] = {"exceptions": [dict(EXC, decision="D1")]}


rc, out, data = score(make("exc-decision", except_decision))
check("a decision Dan excepted is skipped, so the rest can reach 100%", rc == 0 and "decisions  1 of 1 met" in out, out)
check("the exception is listed with his words and its date", "X1" in out and EXC["words"] in out and "2026-10-19" in out, out)
check("the score file carries the exception", data and data["exceptions"][0]["id"] == "X1", data)


def except_frame(s):
    s["images"]["f2"] = (rgba_image(FW, FH, DARK), (FW, FH), rgba_image(FW, FH, LIGHT), (FW, FH))
    s["exceptions"] = {"exceptions": [dict(EXC, frame="f2")]}


rc, out, data = score(make("exc-frame", except_frame))
check("a whole frame Dan excepted is skipped from the picture half", rc == 0 and "over 1 frame" in out, out)


def except_region(inside):
    def m(s):
        x = 5 if inside else 30
        s["images"]["f1"] = (rgba_image(FW, FH, LIGHT), (FW, FH), rgba_image(FW, FH, LIGHT, [(x, 6, (0, 0, 0, 255))]), (FW, FH))
        s["exceptions"] = {"exceptions": [dict(EXC, frame="f1", region=[0, 0, 20, 20])]}
    return m


rc, out, data = score(make("exc-region-in", except_region(True)))
check("a difference inside an excepted region is skipped", rc == 0, out)
f1 = [f for f in data["pictures"]["frames"] if f["id"] == "f1"][0] if data else {}
check("and its pixels are left out of the count, not counted as matching", f1.get("compared") == FW * FH - 400, f1)
rc, out, _ = score(make("exc-region-out", except_region(False)))
check("a difference outside the excepted region still counts", rc == 1, out)

for n, (label, bad) in enumerate([("names no decision or frame", {}),
                   ("names both a decision and a frame", {"decision": "D1", "frame": "f1"}),
                   ("names a decision the map does not hold", {"decision": "D7"}),
                   ("names a frame the design does not declare", {"frame": "f7"}),
                   ("gives a region without a frame", {"decision": "D1", "region": [0, 0, 1, 1]}),
                   ("gives a region outside its frame", {"frame": "f1", "region": [30, 20, 20, 20]})]):
    rc, out, _ = score(make("exc-bad-%d" % n, lambda s, bad=bad: s.__setitem__(
        "exceptions", {"exceptions": [dict(EXC, **bad)]})))
    check("an exception that %s is no score" % label, rc == 2 and "X1" in out, out)
for field in ("words", "date", "source"):
    rc, out, _ = score(make("exc-no-%s" % field, lambda s, field=field: s.__setitem__(
        "exceptions", {"exceptions": [dict({k: v for k, v in EXC.items() if k != field}, decision="D1")]})))
    check("an exception without its %s is no score, so none stands without Dan's record" % field,
          rc == 2 and field in out, out)
rc, out, _ = score(make("exc-all-frames", lambda s: s.__setitem__("exceptions", {"exceptions": [
    dict(EXC, frame="f1"), dict(EXC, id="X2", frame="f2")]})))
check("excepting every frame leaves nothing to compare, so no score", rc == 2 and "no frame" in out, out)

# 10. show prints the two scores from a score file, and refuses one that contradicts itself.
d = make("show", fail_d1_on_f2)
score(d)
rc, out = run("show", os.path.join(d, "score.json"))
check("show prints the two scores from the score file", rc == 1 and "decisions  1 of 2 met" in out and "pictures" in out, out)
with open(os.path.join(d, "score.json")) as fh:
    forged = json.load(fh)
forged["verdict"] = "matched"
with open(os.path.join(d, "forged.json"), "w") as fh:
    json.dump(forged, fh)
rc, out = run("show", os.path.join(d, "forged.json"))
check("a score file whose verdict its own rows contradict is no score", rc == 2 and "contradict" in out, out)
rc, out = run("show", os.path.join(d, "absent.json"))
check("show of a score file that is not there is no score", rc == 2, out)
rc, out = run()
check("no arguments prints the usage and exits 2", rc == 2 and "usage" in out.lower(), out)

shutil.rmtree(T, ignore_errors=True)
print()
print("passed: %d, failed: %d" % (passed, failed))
print("SUITE-RESULT passed=%d failed=%d" % (passed, failed))
sys.exit(1 if failed else 0)
