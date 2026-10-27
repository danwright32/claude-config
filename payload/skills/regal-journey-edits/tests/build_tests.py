"""Checks for build_page.py, the regal-journey-edits page builder. Run by ../test-regal-journey-edits.sh."""
import copy
import html
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
sys.path.insert(0, SKILL)
import build_page  # noqa: E402

passed = failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print(f"FAIL: {name}" + (f" ({detail})" if detail else ""))


def refused(spec):
    try:
        build_page.build(spec)
    except build_page.SpecError as e:
        return str(e)
    return None


FIXTURE = json.load(open(os.path.join(HERE, "fixture.json"), encoding="utf-8"))
DASH = re.compile("[" + chr(0x2013) + chr(0x2014) + "]")

page = build_page.build(copy.deepcopy(FIXTURE))
check("the fixture builds a page", "<main" in page and "Example Journey" in page)

# Every [[value]] in the spec, every new node's name and every Change or Add value gets its own Copy button.
wanted = set(re.findall(r"\[\[(.+?)\]\]", json.dumps(FIXTURE)))
for j in FIXTURE["journeys"]:
    for c in j.get("changes", []):
        for n in c.get("new", []):
            if n.get("name"):
                wanted.add(n["name"])
            for r in n.get("rows", []):
                if r["tag"] in ("Change", "Add"):
                    wanted.add(r["value"])
                if r["tag"] == "Add":
                    wanted.add(r["attr"])
buttons = {html.unescape(v) for v in re.findall(r'class="cp" data-copy="([^"]*)"', page)}
missing = sorted(wanted - buttons)
check("every copyable value has its own Copy button", not missing, f"no button for {missing}")

check("an existing node is named by number and exact live name",
      "node 3 " + chr(0x201C) + "Double Booking (Reschedule)?" + chr(0x201D) in page)
check("an unnamed node is named by number, type and detail, never a made up label",
      "(an unnamed Delay, 5 seconds)" in page)
check("a copy is named through the node it copies", "the copy of " in page and "node 5</span> (an unnamed Delay" in page)
check("a cross journey reference names the journey", "journey 100 " in page)
check("a tickable journey has its tick and Open in Regal button",
      'data-tick="1"' in page and 'data-href="https://app.regal.io/orchestration/journeys/00000000-0000-4000-8000-000000000100"' in page)
check("a no change journey has no tick", 'id="j101" data-j="101">' in page)
check("the attribute table counts what it asks for", "1 to change, 1 to add and 1 to delete" in page)
check("no em or en dash reaches the page", not DASH.search(page))

bad = copy.deepcopy(FIXTURE)
del bad["journeys"][0]["nodes"]["3"]["label"]
check("a node with no label is refused", refused(bad) and "needs a type and a label" in refused(bad), refused(bad))

bad = copy.deepcopy(FIXTURE)
del bad["journeys"][0]["changes"][0]["node"]
check("a change with no node number is refused", refused(bad) and "needs the number" in refused(bad), refused(bad))

bad = copy.deepcopy(FIXTURE)
bad["journeys"][0]["changes"][0]["steps"].append("Draw a line to <<77>>.")
check("a reference to a node the journey does not hold is refused", refused(bad) and "no node 77" in refused(bad), refused(bad))

bad = copy.deepcopy(FIXTURE)
bad["journeys"][0]["changes"][0]["steps"].append("Draw it to <<new:Nobody?>>.")
check("a reference to a new node the change does not add is refused", refused(bad) and "Nobody?" in refused(bad), refused(bad))

bad = copy.deepcopy(FIXTURE)
bad["journeys"][0]["changes"][0]["steps"].append("Then <<copy:3>>.")
check("a reference to a copy the change does not make is refused", refused(bad) and "no copy of node 3" in refused(bad), refused(bad))

bad = copy.deepcopy(FIXTURE)
bad["journeys"][0]["changes"][0]["new"][1]["rows"][0]["tag"] = "Maybe"
check("an unknown row tag is refused", refused(bad) and "Maybe" in refused(bad), refused(bad))

bad = copy.deepcopy(FIXTURE)
bad["journeys"][0]["changes"][0]["title"] = "A branch " + chr(0x2014) + " here"
check("a dash in the spec is refused", refused(bad) and "dash" in refused(bad), refused(bad))

bad = copy.deepcopy(FIXTURE)
bad["journeys"][1]["group"] = "later"
check("an unknown group is refused", refused(bad) and "later" in refused(bad), refused(bad))

# The command line: exit 0 and a page, exit 2 and nothing written.
with tempfile.TemporaryDirectory() as t:
    good, out = os.path.join(t, "spec.json"), os.path.join(t, "page.html")
    json.dump(FIXTURE, open(good, "w", encoding="utf-8"))
    r = subprocess.run([sys.executable, "-I", os.path.join(SKILL, "build_page.py"), good, out], capture_output=True, text=True)
    check("the command writes the page and exits 0", r.returncode == 0 and os.path.exists(out), r.stdout + r.stderr)
    worse, out2 = os.path.join(t, "bad.json"), os.path.join(t, "bad.html")
    b = copy.deepcopy(FIXTURE)
    b["journeys"][0]["changes"][0]["steps"].append("<<77>>")
    json.dump(b, open(worse, "w", encoding="utf-8"))
    r = subprocess.run([sys.executable, "-I", os.path.join(SKILL, "build_page.py"), worse, out2], capture_output=True, text=True)
    check("a refused spec exits 2 and writes nothing", r.returncode == 2 and not os.path.exists(out2), r.stdout + r.stderr)

print()
print("passed: %d, failed: %d" % (passed, failed))
print("SUITE-RESULT passed=%d failed=%d" % (passed, failed))
sys.exit(1 if failed else 0)
