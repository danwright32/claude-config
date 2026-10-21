"""score_fixture.py: one real design match score, made by design_score.py from a capture written
here, for the suites that need a score to post and read back (gate_tests.py, reopen_tests.py).

make() writes a settled design into a fresh git checkout, a capture of a build of it, and scores
that capture with the real scorer, so no test reads a score shaped by hand. With `exception`, the
design records an exception Dan approved on its last decision, and `failing` names the decisions
whose check fails on the build: a failing decision that carries an exception still scores 100%.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCORE_DIR = os.path.dirname(HERE)
SCORE = os.path.join(SCORE_DIR, "design_score.py")
sys.path.insert(0, SCORE_DIR)
import pngio  # noqa: E402

DESIGN = "docs/design/capacity.html"
HEAD = "1" * 40
WORDING = {"D1": "Heading reads Team capacity", "D2": "The total sits under the heading"}


def make(root, name="app", decisions=("D1",), exception=False, failing=(), commit=HEAD, kind=None):
    """(checkout, the design's bytes, the score, the scorer's process) for a build of the design. With
    `kind`, the design's frames block names it (an email, or the terminal of claude-config#1413)."""
    work = os.path.join(root, name)
    os.makedirs(os.path.join(work, "docs", "design"))
    subprocess.run(["git", "init", "-q", work], check=True)
    rows = ", ".join('{"id": "%s", "decision": "%s", "requirement": "1"}' % (d, WORDING[d]) for d in decisions)
    html = ('<!doctype html><html><body>\n'
            '<script type="application/json" id="decision-map">{"decisions": [' + rows + ']}</script>\n'
            '<script type="application/json" id="design-frames">{"frames": [{"id": "f1", "width": 4}]%s}</script>\n'
            % ((', "kind": %s' % json.dumps(kind)) if kind else ""))
    if exception:
        html += ('<script type="application/json" id="design-exceptions">{"exceptions": [{"id": "X1", '
                 '"decision": "%s", "words": "Leave the total where it is", "date": "2026-10-19", '
                 '"source": "https://github.com/acme/widgets/issues/9#issuecomment-7"}]}</script>\n' % decisions[-1])
    html += '</body></html>\n'
    design_bytes = html.encode()
    with open(os.path.join(work, DESIGN), "wb") as fh:
        fh.write(design_bytes)
    cap = os.path.join(root, name + "-capture")
    os.makedirs(cap)
    px = bytes([200, 180, 160, 255]) * 12
    pngio.write_png(os.path.join(cap, "f1-design.png"), 4, 3, px)
    pngio.write_png(os.path.join(cap, "f1-built.png"), 4, 3, px)
    checks = [{"id": d, "ok": d not in failing, "detail": "" if d not in failing else "not drawn"} for d in decisions]
    with open(os.path.join(cap, "capture.json"), "w") as fh:
        json.dump({"format": "design-capture", "version": 1, "platform": "web", "designFile": os.path.join(work, DESIGN),
                   "build": "http://127.0.0.1:3000/admin/capacity", "commit": commit, "dirty": False,
                   "frames": [{"id": "f1", "designImage": "f1-design.png", "builtImage": "f1-built.png",
                               "checks": checks,
                               "designChecks": [{"id": d, "ok": True, "detail": ""} for d in decisions]}]}, fh)
    proc = subprocess.run([sys.executable, SCORE, "score", cap], capture_output=True, text=True)
    # 0 matched and 1 not matched are both scores a test can use; 2 is no score at all, which is the
    # fixture broken, never a reading to test against, except for a terminal design, whose picture half
    # this web capture leaves unmeasured, since only the terminal adapter's capture measures it (#1414).
    if proc.returncode not in ((0, 1, 2) if kind == "terminal" else (0, 1)):
        raise RuntimeError("the fixture could not be scored (exit %d): %s" % (proc.returncode, proc.stdout + proc.stderr))
    with open(os.path.join(cap, "score.json")) as fh:
        score = json.load(fh)
    return work, design_bytes, score, proc, cap
