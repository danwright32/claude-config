"""Checks for jdiff.py and the page script read_lines.js (claude-config#1853).

Run by hooks/lib/skill-python-tests.py, which finds every test_*.py under payload/skills.

journey_v1.json is shaped on a real fetch-journey result (journey 298, version 111, read on
2026-10-28): one flat "flow" list holding lines (source, target, sourceHandle) and nodes (id, type,
data with friendlyId, layout fields, analyticsData whose counts move on every read). Every id, name
and address in it is invented. The exit names on the conditional node ("yes", "no") are invented
too: the journey read had no conditional node.
"""
import copy
import html.parser
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
JDIFF = os.path.join(SKILL, "jdiff.py")
PAGE_SCRIPT = os.path.join(SKILL, "read_lines.js")
HARNESS = os.path.join(HERE, "page_harness.js")

with open(os.path.join(HERE, "journey_v1.json"), encoding="utf-8") as f:
    V1 = json.load(f)

N = {  # node number to its id in the fixture
    1: "a0000001-0000-4000-8000-000000000001",
    3: "a0000003-0000-4000-8000-000000000003",
    14: "a0000014-0000-4000-8000-000000000014",
    15: "a0000015-0000-4000-8000-000000000015",
    16: "a0000016-0000-4000-8000-000000000016",
}
EDITOR_URL = "https://app.regal.io/orchestration/journeys/" + V1["id"]


def run(*args):
    p = subprocess.run([sys.executable, "-I", JDIFF, *args], capture_output=True, text=True, timeout=60)
    return p.returncode, p.stdout + p.stderr


def element(flow, **match):
    for e in flow:
        if all(e.get(k) == v for k, v in match.items()):
            return e
    raise AssertionError(f"fixture has no element matching {match}")


class HtmlToTree(html.parser.HTMLParser):
    """The fixture HTML as the JSON tree page_harness.js builds its document from."""
    VOID = {"path", "rect", "br", "img", "input"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = {"children": []}
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = {"tag": tag, "attrs": {k: (v if v is not None else "") for k, v in attrs}, "children": []}
        self.stack[-1]["children"].append(node)
        if tag not in self.VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.stack[-1]["children"].append({"tag": tag, "attrs": dict(attrs), "children": []})

    def handle_endtag(self, tag):
        if tag in self.VOID:
            return
        if self.stack[-1].get("tag") != tag:
            raise AssertionError(f"fixture HTML is not well formed: </{tag}> closes <{self.stack[-1].get('tag')}>")
        self.stack.pop()

    def handle_data(self, data):
        self.stack[-1]["children"].append({"text": data})


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="jdiff-test-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, obj):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(obj if isinstance(obj, str) else json.dumps(obj))
        return path

    def snapshot(self, journey=None):
        src = self.write("fetch-v1.json", journey or V1)
        out = os.path.join(self.tmp, "snap.json")
        rc, text = run("snap", src, out)
        self.assertEqual(rc, 0, text)
        return out

    def canvas_from_flow(self, flow, url=EDITOR_URL, handles=True):
        """What read_lines.js returns for a canvas showing exactly this flow."""
        lines, nodes = [], []
        for e in flow:
            if "source" in e and "target" in e:
                line = {"edge": e["id"], "from": e["source"], "to": e["target"]}
                if handles:
                    line["handle"] = e.get("sourceHandle")
                lines.append(line)
            else:
                nodes.append({"id": e["id"], "label": e["type"]})
        return {"source": "react-flow canvas", "page": url, "lines": lines, "nodes": nodes,
                "unreadable": [], "handles": "read" if handles else "none"}

    def page_script(self, html_text, url=EDITOR_URL):
        if shutil.which("node") is None:
            self.fail("node is not on PATH, so the page script could not be run against its fixture DOM")
        parser = HtmlToTree()
        parser.feed(html_text)
        parser.close()
        tree = self.write("tree.json", parser.root["children"])
        args = ["node", HARNESS, tree, PAGE_SCRIPT] + ([url] if url else [])
        p = subprocess.run(args, capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout)


class Snap(Base):
    def test_snap_records_every_node_and_line(self):
        snap = json.load(open(self.snapshot(), encoding="utf-8"))
        self.assertEqual(snap["journey"]["friendlyId"], 900)
        self.assertEqual(snap["journey"]["version"], 4)
        self.assertEqual(sorted(n["number"] for n in snap["nodes"].values()), [1, 3, 14, 15, 16])
        self.assertEqual(len(snap["lines"]), 5)
        no_line = [l for l in snap["lines"] if l["from"] == N[3] and l["to"] == N[14]]
        self.assertEqual(no_line[0]["handle"], "no")
        # Settings keep what a person sets and drop what moves on its own.
        webhook = snap["nodes"][N[14]]["settings"]
        self.assertEqual(webhook["data"]["webhookUrl"], "https://example.invalid/tasks/update")
        self.assertNotIn("analyticsData", webhook["data"])
        self.assertNotIn("position", webhook)

    def test_snap_refuses_to_overwrite_a_snapshot(self):
        out = self.snapshot()
        before = open(out, encoding="utf-8").read()
        rc, text = run("snap", self.write("other.json", V1), out)
        self.assertEqual(rc, 2, text)
        self.assertEqual(open(out, encoding="utf-8").read(), before)

    def test_snap_reads_the_mcp_text_wrapper(self):
        wrapped = [{"type": "text", "text": json.dumps(V1)}]
        src = self.write("wrapped.json", wrapped)
        rc, text = run("snap", src, os.path.join(self.tmp, "s.json"))
        self.assertEqual(rc, 0, text)

    def test_snap_refuses_what_is_not_a_journey(self):
        for name, content in [("empty.json", ""), ("broken.json", "{\"flow\": ["),
                              ("noflow.json", {"id": "x", "version": 1}),
                              ("emptyflow.json", {"id": "x", "version": 1, "flow": []})]:
            rc, text = run("snap", self.write(name, content), os.path.join(self.tmp, name + ".snap"))
            self.assertEqual(rc, 2, f"{name}: {text}")
            self.assertFalse(os.path.exists(os.path.join(self.tmp, name + ".snap")), name)

    def test_snap_of_a_missing_file_is_an_error(self):
        rc, text = run("snap", os.path.join(self.tmp, "nope.json"), os.path.join(self.tmp, "s.json"))
        self.assertEqual(rc, 2, text)


class DiffSavedVersion(Base):
    def test_identical_versions_exit_0(self):
        snap = self.snapshot()
        rc, text = run("diff", snap, self.write("same.json", V1))
        self.assertEqual(rc, 0, text)
        self.assertIn("No differences", text)

    def test_a_clean_read_back_says_settings_were_compared_whatever_the_journey_is_called(self):
        named = copy.deepcopy(V1)
        named["name"] = "Leads from the canvas form"
        snap = self.snapshot(named)
        rc, text = run("diff", snap, self.write("same.json", named))
        self.assertEqual(rc, 0, text)
        self.assertIn("every line and every node setting matches", text)

    def test_counts_and_layout_moving_are_not_differences(self):
        snap = self.snapshot()
        later = copy.deepcopy(V1)
        later["version"] = 5
        for e in later["flow"]:
            if "position" in e:
                e["position"] = {"x": 0, "y": 0}
                e["positionAbsolute"] = {"x": 0, "y": 0}
                e["selected"] = True
            if "analyticsData" in e.get("data", {}):
                e["data"]["analyticsData"]["currentUserCount"] += 40
        rc, text = run("diff", snap, self.write("later.json", later))
        self.assertEqual(rc, 0, text)

    def test_a_moved_line_and_a_changed_setting_are_listed(self):
        snap = self.snapshot()
        later = copy.deepcopy(V1)
        later["version"] = 5
        moved = element(later["flow"], source=N[3], sourceHandle="no")
        moved["target"] = N[15]
        moved["id"] = "e0000099-0000-4000-8000-000000000099"
        element(later["flow"], id=N[14])["data"]["webhookUrl"] = "https://example.invalid/tasks/v2"
        rc, text = run("diff", snap, self.write("later.json", later))
        self.assertEqual(rc, 1, text)
        self.assertIn("Lines removed (1)", text)
        self.assertIn("Lines added (1)", text)
        self.assertIn('node 3 "Agent Assigned?", exit no, to node 14 "Update Tasks in Queue"', text)
        self.assertIn('node 3 "Agent Assigned?", exit no, to node 15', text)
        self.assertIn("data.webhookUrl", text)
        self.assertIn("https://example.invalid/tasks/v2", text)
        self.assertNotIn("position", text)
        self.assertNotIn("analyticsData", text)

    def test_a_line_moved_between_exits_is_listed(self):
        snap = self.snapshot()
        later = copy.deepcopy(V1)
        element(later["flow"], source=N[3], sourceHandle="no")["sourceHandle"] = "yes"
        rc, text = run("diff", snap, self.write("later.json", later))
        self.assertEqual(rc, 1, text)
        self.assertIn("exit no, to node 14", text)
        self.assertIn("exit yes, to node 14", text)

    def test_one_row_of_a_list_setting_changed_names_the_row(self):
        snap = self.snapshot()
        later = copy.deepcopy(V1)
        rows = element(later["flow"], id=N[16])["data"]["profileAttributesList"]
        rows["r2"]["profileAttrValue"] = "false"
        rc, text = run("diff", snap, self.write("later.json", later))
        self.assertEqual(rc, 1, text)
        # Regal keys these rows by random ids, so the row is also named by the attribute it sets.
        self.assertIn("data.profileAttributesList.r2 (customProperties.reassigned).profileAttrValue", text)

    def test_a_node_added_and_a_node_removed_are_listed(self):
        snap = self.snapshot()
        later = copy.deepcopy(V1)
        later["flow"] = [e for e in later["flow"] if e.get("id") != N[15] and e.get("target") != N[15]]
        later["flow"].append({"id": "a0000020-0000-4000-8000-000000000020", "type": "delay",
                              "data": {"friendlyId": 20, "days": "1", "delayType": "standard"},
                              "position": {"x": 1, "y": 1}})
        rc, text = run("diff", snap, self.write("later.json", later))
        self.assertEqual(rc, 1, text)
        self.assertIn("Nodes removed (1)", text)
        self.assertIn("node 15", text)
        self.assertIn("Nodes added (1)", text)
        self.assertIn("node 20", text)

    def test_a_different_journey_is_an_error_not_a_diff(self):
        snap = self.snapshot()
        other = copy.deepcopy(V1)
        other["id"] = "0a1b2c3d-0000-4000-8000-000000000901"
        rc, text = run("diff", snap, self.write("other.json", other))
        self.assertEqual(rc, 2, text)
        self.assertNotIn("No differences", text)


class DiffCanvas(Base):
    def test_a_canvas_matching_the_snapshot_exits_0(self):
        snap = self.snapshot()
        rc, text = run("diff", snap, self.write("canvas.json", self.canvas_from_flow(V1["flow"])))
        self.assertEqual(rc, 0, text)
        self.assertIn("No differences", text)

    def test_a_removed_line_is_listed_exactly(self):
        snap = self.snapshot()
        canvas = self.canvas_from_flow(V1["flow"])
        canvas["lines"] = [l for l in canvas["lines"] if not (l["from"] == N[14] and l["to"] == N[15])]
        rc, text = run("diff", snap, self.write("canvas.json", canvas))
        self.assertEqual(rc, 1, text)
        self.assertIn("Lines removed (1)", text)
        self.assertIn('node 14 "Update Tasks in Queue" to node 15', text)
        self.assertNotIn("Lines added", text)

    def test_an_added_line_without_a_readable_exit_says_so(self):
        snap = self.snapshot()
        canvas = self.canvas_from_flow(V1["flow"])
        canvas["lines"].append({"edge": "reactflow__edge-new", "from": N[3], "to": N[15]})
        canvas["handles"] = "some"
        rc, text = run("diff", snap, self.write("canvas.json", canvas))
        self.assertEqual(rc, 1, text)
        self.assertIn("Lines added (1)", text)
        self.assertIn('node 3 "Agent Assigned?", exit not read from the canvas, to node 15', text)
        self.assertNotIn("Lines removed", text)

    def test_a_line_whose_edge_the_snapshot_holds_takes_its_exit_from_the_snapshot(self):
        snap = self.snapshot()
        rc, text = run("diff", snap, self.write("canvas.json", self.canvas_from_flow(V1["flow"], handles=False)))
        self.assertEqual(rc, 0, text)

    def test_a_node_on_the_canvas_the_snapshot_lacks_is_named_by_its_label(self):
        snap = self.snapshot()
        canvas = self.canvas_from_flow(V1["flow"])
        canvas["nodes"].append({"id": "f0000001-0000-4000-8000-000000000001", "label": "Conditional Marcia call?"})
        canvas["lines"].append({"edge": "new1", "from": N[3], "to": "f0000001-0000-4000-8000-000000000001", "handle": "no"})
        rc, text = run("diff", snap, self.write("canvas.json", canvas))
        self.assertEqual(rc, 1, text)
        self.assertIn('new node "Conditional Marcia call?"', text)

    def test_unreadable_lines_are_an_error(self):
        snap = self.snapshot()
        canvas = self.canvas_from_flow(V1["flow"])
        canvas["unreadable"] = [{"edge": "x", "label": None}]
        rc, text = run("diff", snap, self.write("canvas.json", canvas))
        self.assertEqual(rc, 2, text)

    def test_a_page_script_error_is_an_error(self):
        snap = self.snapshot()
        rc, text = run("diff", snap, self.write("canvas.json", {"source": "react-flow canvas", "error": "no canvas"}))
        self.assertEqual(rc, 2, text)
        self.assertIn("no canvas", text)

    def test_a_canvas_of_another_journey_is_an_error(self):
        snap = self.snapshot()
        canvas = self.canvas_from_flow(V1["flow"], url="https://app.regal.io/orchestration/journeys/0a1b2c3d-0000-4000-8000-000000000901")
        rc, text = run("diff", snap, self.write("canvas.json", canvas))
        self.assertEqual(rc, 2, text)

    def test_unreadable_input_is_an_error_never_no_differences(self):
        snap = self.snapshot()
        for args in [(snap, os.path.join(self.tmp, "missing.json")),
                     (snap, self.write("empty.json", "")),
                     (snap, self.write("garbage.json", "not json")),
                     (snap, self.write("shape.json", {"hello": 1})),
                     (os.path.join(self.tmp, "missing-snap.json"), self.write("v1.json", V1)),
                     (self.write("not-a-snap.json", V1), self.write("v1b.json", V1))]:
            rc, text = run("diff", *args)
            self.assertEqual(rc, 2, f"{args}: {text}")
            self.assertNotIn("No differences", text)

    def test_no_arguments_is_an_error(self):
        rc, text = run()
        self.assertEqual(rc, 2, text)


class PageScript(Base):
    def setUp(self):
        super().setUp()
        with open(os.path.join(HERE, "canvas.html"), encoding="utf-8") as f:
            self.canvas_html = f.read()

    def test_reads_every_line_and_node_and_nothing_else(self):
        out = self.page_script(self.canvas_html)
        self.assertNotIn("error", out)
        pairs = sorted((l["from"], l["to"]) for l in out["lines"])
        want = sorted((e["source"], e["target"]) for e in V1["flow"] if "source" in e)
        self.assertEqual(pairs, want)
        self.assertEqual(sorted(n["id"] for n in out["nodes"]), sorted(N.values()))
        self.assertEqual(out["unreadable"], [])
        self.assertEqual(out["page"], EDITOR_URL)
        labels = {n["id"]: n["label"] for n in out["nodes"]}
        self.assertIn("Update Tasks in Queue", labels[N[14]])

    def test_reads_the_exit_when_the_page_exposes_it(self):
        out = self.page_script(self.canvas_html)
        by_pair = {(l["from"], l["to"]): l for l in out["lines"]}
        self.assertEqual(by_pair[(N[3], N[14])]["handle"], "no")
        self.assertIn("handle", by_pair[(N[1], N[3])])
        self.assertIsNone(by_pair[(N[1], N[3])]["handle"])
        self.assertNotIn("handle", by_pair[(N[3], N[16])])
        self.assertEqual(out["handles"], "some")

    def test_the_unchanged_canvas_diffs_clean_against_its_snapshot(self):
        snap = self.snapshot()
        canvas = self.write("canvas.json", self.page_script(self.canvas_html))
        rc, text = run("diff", snap, canvas)
        self.assertEqual(rc, 0, text)

    def test_a_line_dragged_to_the_wrong_node_is_caught(self):
        # The 2026-10-28 case: a drag that missed its handle. Here the line from 16 lands on 15.
        edited = self.canvas_html.replace(
            f'aria-label="Edge from {N[16]} to {N[14]}"', f'aria-label="Edge from {N[16]} to {N[15]}"')
        self.assertNotEqual(edited, self.canvas_html)
        snap = self.snapshot()
        rc, text = run("diff", snap, self.write("canvas.json", self.page_script(edited)))
        self.assertEqual(rc, 1, text)
        self.assertIn('node 16 "Set Booking Details" to node 14', text)
        self.assertIn('node 16 "Set Booking Details" to node 15', text)

    def test_a_line_with_no_readable_label_is_reported_not_skipped(self):
        edited = self.canvas_html.replace(f'aria-label="Edge from {N[14]} to {N[15]}"', "")
        out = self.page_script(edited)
        self.assertEqual(len(out["unreadable"]), 1)
        self.assertEqual(len(out["lines"]), 4)

    def test_a_page_with_no_canvas_is_an_error(self):
        out = self.page_script("<div class=\"app\"><p>Loading</p></div>")
        self.assertIn("error", out)


if __name__ == "__main__":
    unittest.main()
