#!/usr/bin/env python3
"""The checks behind test-score-vendoring.sh (claude-config#1385): vendor-score.py, which copies the
score tools into an app's repository (Slate's, so the score runs in its CI) with a manifest of hashes,
and checks a copy against that manifest everywhere and against claude-config's own copy wherever that
is on disk.

Everything is written into a throwaway folder. HOME points there too, so the copy installed in this
Mac's ~/.claude is never found by accident: a test that wants claude-config's copy names one.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCORE_DIR = os.path.dirname(HERE)
SKILL_DIR = os.path.dirname(SCORE_DIR)
TOOL = os.path.join(SCORE_DIR, "vendor-score.py")
EXPECTED = {
    "capture-web.mjs": os.path.join(SCORE_DIR, "capture-web.mjs"),
    "design_score.py": os.path.join(SCORE_DIR, "design_score.py"),
    "pngio.py": os.path.join(SCORE_DIR, "pngio.py"),
    "score_github.py": os.path.join(SCORE_DIR, "score_github.py"),
    "design_file.py": os.path.join(SKILL_DIR, "design_file.py"),
    "headless-dom.sh": os.path.join(SKILL_DIR, "headless-dom.sh"),
    "shared-playwright.json": os.path.join(SCORE_DIR, "shared-playwright.json"),
    "vendor-score.py": TOOL,
}

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


T = tempfile.mkdtemp(prefix="vendor-score-test.")
HOME = os.path.join(T, "home")
os.makedirs(HOME)
ENV = dict(os.environ, HOME=HOME)
ENV.pop("DESIGN_SCORE_PLAYWRIGHT", None)


def run(*args, tool=TOOL, cwd=None):
    p = subprocess.run([sys.executable, "-I", tool] + list(args), capture_output=True, text=True, env=ENV, cwd=cwd)
    return p.returncode, p.stdout + p.stderr


def sha(path):
    with open(path, "rb") as fh:
        return "sha256:" + hashlib.sha256(fh.read()).hexdigest()


def upstream(name):
    """A claude-config of our own, laid out as the real one is, which a test can move on."""
    root = os.path.join(T, name, "design-rounds")
    os.makedirs(os.path.join(root, "score"))
    for dest, src in EXPECTED.items():
        to = os.path.join(root, dest) if dest in ("design_file.py", "headless-dom.sh") else os.path.join(root, "score", dest)
        shutil.copy(src, to)
    return os.path.join(root, "score")


# 1. copy: every file the score needs, flat in one folder, and a manifest of their hashes.
V = os.path.join(T, "slate", "scripts", "design-score")
rc, out = run("copy", V)
check("copy into a new folder succeeds", rc == 0, out)
check("the folder holds exactly the score's files and the manifest",
      sorted(os.listdir(V)) == sorted(list(EXPECTED) + ["vendor-manifest.json"]), sorted(os.listdir(V)) if os.path.isdir(V) else out)
try:
    with open(os.path.join(V, "vendor-manifest.json")) as fh:
        man = json.load(fh)
except (OSError, ValueError) as e:
    man = {}
    check("the manifest is JSON", False, str(e))
check("the manifest names its format and every file by the hash of claude-config's copy",
      man.get("format") == "design-score-vendor" and man.get("version") == 1
      and man.get("files") == {n: sha(p) for n, p in EXPECTED.items()}, json.dumps(man, indent=1))
check("the manifest records no path from this Mac (it is committed in another repository)",
      HOME not in json.dumps(man) and os.path.expanduser("~") not in json.dumps(man) and "/Users/" not in json.dumps(man),
      json.dumps(man, indent=1))

# 2. check: a fresh copy matches its manifest and claude-config's copy.
rc, out = run("check", V, "--against", SCORE_DIR)
check("a fresh copy matches its manifest and claude-config's copy, exit 0",
      rc == 0 and "matches its manifest" in out and "matches claude-config" in out, out)

# 3. With claude-config's copy not on the machine (as in CI), only the manifest is checked, said so.
rc, out = run("check", V)
check("with no claude-config copy reachable, the manifest alone is checked and that is said, exit 0",
      rc == 0 and "matches its manifest" in out and "not compared with claude-config" in out, out)

# 4. The vendored copy checks itself, in a repository with no ~/.claude at all (Slate's CI).
rc, out = run("check", V, tool=os.path.join(V, "vendor-score.py"))
check("the vendored copy's own vendor-score.py checks it with no ~/.claude", rc == 0 and "matches its manifest" in out, out)

# 5. The vendored copy runs on its own: the score finds design_file.py beside it, not in claude-config.
design = os.path.join(T, "design.html")
with open(design, "w") as fh:
    fh.write('<!doctype html><script type="application/json" id="design-frames">'
             '{"frames": [{"id": "f1", "title": "Wide", "width": 640}]}</script>')
p = subprocess.run([sys.executable, "-I", os.path.join(V, "design_score.py"), "frames", design],
                   capture_output=True, text=True, env=ENV, cwd=T)
check("the vendored design_score.py reads a design's frames with only its own folder",
      p.returncode == 0 and '"f1"' in p.stdout, p.stdout + p.stderr)
if shutil.which("node"):
    app = os.path.join(T, "app")
    os.makedirs(app)
    p = subprocess.run(["node", os.path.join(V, "capture-web.mjs"), "--design", design, "--out", os.path.join(T, "cap"),
                        "--design-only", "--repo", app], capture_output=True, text=True, env=ENV, cwd=T)
    check("the vendored capture-web.mjs loads, and with no Playwright says so and exits 2",
          p.returncode == 2 and "install-playwright.sh" in p.stderr, "rc=%d %s" % (p.returncode, p.stdout + p.stderr))
    # Chrome is started through headless-dom.sh beside it (claude-config#1537), which Playwright runs
    # as the browser itself, so the copy must be there and runnable.
    p = subprocess.run(["node", "--input-type=module", "-e",
                        "const m = await import(process.argv[1]); console.log(m.chromeLaunchOptions('chrome', [], {platform: 'darwin'}).executablePath)",
                        "file://" + os.path.join(V, "capture-web.mjs")], capture_output=True, text=True, env=ENV, cwd=T)
    check("the vendored capture-web.mjs starts Chrome through the headless-dom.sh beside it",
          p.returncode == 0 and os.path.realpath(p.stdout.strip()) == os.path.realpath(os.path.join(V, "headless-dom.sh")), "rc=%d %s" % (p.returncode, p.stdout + p.stderr))
else:
    print("SUITE-PART-UNMEASURED node is not on PATH, so the vendored capture-web.mjs was not loaded")
check("and the vendored headless-dom.sh can be run as a program, as Playwright runs it",
      os.access(os.path.join(V, "headless-dom.sh"), os.X_OK), oct(os.stat(os.path.join(V, "headless-dom.sh")).st_mode)
      if os.path.exists(os.path.join(V, "headless-dom.sh")) else "missing")
# Running the score in the folder leaves nothing behind there (python writes __pycache__ beside a
# module it imports unless told not to), so a CI job that scores and then checks still matches.
p = subprocess.run([sys.executable, os.path.join(V, "design_score.py"), "frames", design],
                   capture_output=True, text=True, env=ENV, cwd=T)
rc, out = run("check", V)
check("running the vendored score leaves the folder matching its manifest (no __pycache__)",
      p.returncode == 0 and rc == 0 and not os.path.exists(os.path.join(V, "__pycache__")),
      "rc=%d %s" % (rc, out))

# 6. A hand edit to the copy is drift against the manifest, named, with the command to refresh it.
with open(os.path.join(V, "design_score.py"), "a") as fh:
    fh.write("\n# edited by hand\n")
rc, out = run("check", V)
check("a vendored file edited by hand is drift, exit 1, naming the file",
      rc == 1 and "design_score.py" in out and "differs from its manifest" in out, out)
check("and the drift report prints the command that refreshes the copy",
      "vendor-score.py copy " + V in out, out)

# 7. A missing file and a file that is not part of the copy are each drift.
rc, out = run("copy", V)
os.remove(os.path.join(V, "pngio.py"))
with open(os.path.join(V, "notes.txt"), "w") as fh:
    fh.write("mine\n")
rc, out = run("check", V)
check("a vendored file that is gone is drift, named", rc == 1 and "pngio.py" in out and "missing" in out, out)
check("a file that is not part of the copy is drift, named", rc == 1 and "notes.txt" in out, out)
os.remove(os.path.join(V, "notes.txt"))

# 8. A manifest that leaves out a file the score needs is drift, even when it matches what is there.
rc, out = run("copy", V)
mpath = os.path.join(V, "vendor-manifest.json")
with open(mpath) as fh:
    man = json.load(fh)
del man["files"]["score_github.py"]
with open(mpath, "w") as fh:
    json.dump(man, fh)
os.remove(os.path.join(V, "score_github.py"))
rc, out = run("check", V)
check("a manifest without a file the score needs is drift, naming it", rc == 1 and "score_github.py" in out, out)

# 9. No manifest, or one that cannot be read, is no check at all: exit 2, never a pass.
B = os.path.join(T, "bare")
os.makedirs(B)
shutil.copyfile(EXPECTED["design_score.py"], os.path.join(B, "design_score.py"))
rc, out = run("check", B)
check("a folder with no manifest cannot be checked, exit 2", rc == 2 and "vendor-manifest.json" in out, out)
with open(os.path.join(B, "vendor-manifest.json"), "w") as fh:
    fh.write("{not json")
rc, out = run("check", B)
check("a manifest that is not JSON cannot be checked, exit 2", rc == 2, out)
rc, out = run("check", os.path.join(T, "nowhere"))
check("a folder that is not there cannot be checked, exit 2", rc == 2, out)

# 10. claude-config moving on is drift against claude-config, though the manifest still matches.
U = upstream("cc")
V2 = os.path.join(T, "slate2", "design-score")
rc, out = run("copy", V2, "--from", U)
check("copy --from a claude-config copy succeeds", rc == 0, out)
with open(os.path.join(U, "capture-web.mjs"), "a") as fh:
    fh.write("\n// a later change in claude-config\n")
rc, out = run("check", V2, "--against", U)
check("claude-config's copy changed since the copy is drift, exit 1, naming the file",
      rc == 1 and "capture-web.mjs" in out and "matches its manifest" in out and "changed in claude-config" in out, out)
check("and names the command that refreshes it", "vendor-score.py copy " + V2 in out, out)
rc, out = run("copy", V2, "--from", U)
rc, out = run("check", V2, "--against", U)
check("after the refresh it matches again", rc == 0, out)

# 11. claude-config's copy found where it is installed, ~/.claude, when nothing names one.
installed = os.path.join(HOME, ".claude", "skills", "design-rounds")
shutil.copytree(os.path.dirname(U), installed)
rc, out = run("check", V2)
check("with nothing named, claude-config's copy in ~/.claude is compared", rc == 0 and "matches claude-config" in out, out)
with open(os.path.join(installed, "design_file.py"), "a") as fh:
    fh.write("\n# a later change\n")
rc, out = run("check", V2)
check("and its design_file.py, one folder up there, is compared too",
      rc == 1 and "design_file.py" in out and "changed in claude-config" in out, out)
shutil.rmtree(os.path.join(HOME, ".claude"))

# 12. A --against that is not a claude-config copy is refused, never read as nothing having changed.
rc, out = run("check", V2, "--against", os.path.join(T, "nowhere"))
check("a --against folder that is not a claude-config copy is exit 2", rc == 2, out)

# 13. copy needs claude-config's copy to copy from: run from a vendored copy it refuses.
rc, out = run("copy", os.path.join(T, "slate3"), tool=os.path.join(V2, "vendor-score.py"))
check("copy run from a vendored copy, with no --from, refuses, exit 2", rc == 2 and "--from" in out, out)
check("and writes nothing", not os.path.exists(os.path.join(T, "slate3", "vendor-manifest.json")), out)

# 14. Usage.
rc, out = run()
check("no arguments prints the usage and exits 2", rc == 2 and "usage" in out.lower(), out)

shutil.rmtree(T, ignore_errors=True)
print()
print("passed: %d, failed: %d" % (passed, failed))
print("SUITE-RESULT passed=%d failed=%d" % (passed, failed))
sys.exit(1 if failed else 0)
