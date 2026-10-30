#!/usr/bin/env python3
"""Snapshot a Regal journey and diff it, for edits Claude makes in the Regal journey editor
(the regal-journey-edits skill, claude-config#1853).

    jdiff.py snap <fetch-journey.json> <snapshot.json>
    jdiff.py diff <snapshot.json> <canvas.json | fetch-journey.json>

snap  Reads the Regal MCP's fetch-journey (or fetch-journey-version) result for the version about
      to be edited, either the JSON itself or the tool's saved file of it, and writes a snapshot of
      every node, its settings and every line. It never overwrites a snapshot: the one taken before
      the edit is the only record of what the journey was.

diff  Compares a snapshot against either
        the page script's output (read_lines.js run in the editor), listing exactly the lines
        removed and added on the canvas, and the nodes added or missing; or
        a later fetch-journey of the saved version, listing every line and every node setting that
        changed (the read back after saving).

A line is its source node, the exit it leaves from (sourceHandle, null on a node with one exit) and
its target node. A node's settings are everything a person sets on it: its layout on the canvas
(position, size, selection) and Regal's live counts (data.analyticsData) are left out, because they
move on their own and would turn every read back into a list of differences nobody made.

Exit: 0 no differences, 1 differences (printed), 2 an input could not be read or is not what it
should be. A file that cannot be read is never "no differences".
"""

import json
import os
import re
import sys
from collections import Counter

SNAP_FORMAT = "regal-journey-edits jdiff snapshot 1"
CANVAS_SOURCE = "react-flow canvas"
LAYOUT_KEYS = {"position", "positionAbsolute", "width", "height", "selected", "dragging", "id"}
LIVE_DATA_KEYS = {"analyticsData"}
NAME_KEYS = ("label", "name", "nodeName", "title", "conditionalName", "webhookName", "updateContactName")
UNKNOWN = "\x00unknown exit"
JOURNEY_URL = re.compile(r"/journeys/([0-9a-fA-F-]{36})")


class InputError(Exception):
    pass


def load_json(path, what):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        raise InputError(f"cannot read the {what} {path}: {e.strerror or e}")
    if not text.strip():
        raise InputError(f"the {what} {path} is empty")
    try:
        obj = json.loads(text)
    except json.JSONDecodeError as e:
        raise InputError(f"the {what} {path} is not JSON ({e.msg} at line {e.lineno})")
    # A tool result saved to a file can arrive as the MCP content list: [{"type": "text", "text": "<json>"}].
    if isinstance(obj, list) and obj and all(isinstance(x, dict) and x.get("type") == "text" for x in obj):
        try:
            obj = json.loads("".join(x.get("text", "") for x in obj))
        except json.JSONDecodeError as e:
            raise InputError(f"the {what} {path} holds a tool result whose text is not JSON ({e.msg})")
    return obj


def is_line(e):
    return isinstance(e, dict) and "source" in e and "target" in e


def node_name(data):
    for k in NAME_KEYS:
        v = data.get(k)
        if isinstance(v, str) and v.strip():
            return v
    return ""


def journey_of(obj, path):
    """A fetch-journey result as {journey, nodes, lines}, or InputError naming what is wrong."""
    if not isinstance(obj, dict) or not isinstance(obj.get("flow"), list):
        raise InputError(f"{path} is not a fetch-journey result: it has no flow list")
    if not obj.get("id") or obj.get("version") is None:
        raise InputError(f"{path} is not a fetch-journey result: it has no journey id or version")
    nodes, lines = {}, []
    for i, e in enumerate(obj["flow"]):
        if not isinstance(e, dict) or not e.get("id"):
            raise InputError(f"{path}: flow[{i}] has no id")
        if is_line(e):
            lines.append({"edge": e["id"], "from": e["source"], "handle": e.get("sourceHandle"), "to": e["target"]})
            continue
        data = e.get("data") if isinstance(e.get("data"), dict) else {}
        settings = {k: v for k, v in e.items() if k not in LAYOUT_KEYS and k != "data"}
        settings["data"] = {k: v for k, v in data.items() if k not in LIVE_DATA_KEYS}
        if e["id"] in nodes:
            raise InputError(f"{path}: node {e['id']} appears twice in the flow")
        nodes[e["id"]] = {"number": data.get("friendlyId"), "type": e.get("type"),
                          "name": node_name(data), "settings": settings}
    if not nodes:
        raise InputError(f"{path} holds no nodes, so there is nothing to snapshot or compare")
    journey = {"id": obj["id"], "friendlyId": obj.get("friendlyId"), "name": obj.get("name"), "version": obj["version"]}
    return {"journey": journey, "nodes": nodes, "lines": lines}


def load_snapshot(path):
    snap = load_json(path, "snapshot")
    if not isinstance(snap, dict) or snap.get("format") != SNAP_FORMAT:
        raise InputError(f"{path} is not a jdiff snapshot (make one with: jdiff.py snap <fetch-journey.json> <snapshot.json>)")
    for k in ("journey", "nodes", "lines"):
        if k not in snap:
            raise InputError(f"the snapshot {path} has no {k}")
    return snap


# ---- naming things the way the edits page names them


def describe_node(nid, snap_nodes, extra_labels=None):
    n = snap_nodes.get(nid)
    if n:
        num = n.get("number")
        head = f"node {num}" if num is not None else f"node {nid}"
        return f'{head} "{n["name"]}"' if n.get("name") else f"{head} ({n.get('type')})"
    label = (extra_labels or {}).get(nid)
    return f'new node "{label}"' if label else f"node {nid} (not in the snapshot)"


def describe_line(key, snap_nodes, extra_labels=None):
    src, handle, dst = key
    s = describe_node(src, snap_nodes, extra_labels)
    t = describe_node(dst, snap_nodes, extra_labels)
    if handle == UNKNOWN:
        return f"{s}, exit not read from the canvas, to {t}"
    if handle is not None:
        return f"{s}, exit {handle}, to {t}"
    return f"{s} to {t}"


def line_report(before, after, snap_nodes, extra_labels=None):
    removed = list((before - after).elements())
    added = list((after - before).elements())
    out = []
    for title, keys in (("Lines removed", removed), ("Lines added", added)):
        if keys:
            out.append(f"{title} ({len(keys)}):")
            out.extend("  " + describe_line(k, snap_nodes, extra_labels) for k in sorted(keys, key=str))
    return out, len(removed) + len(added)


# ---- settings


def short(v, limit=160):
    text = json.dumps(v, ensure_ascii=False, sort_keys=True)
    return text if len(text) <= limit else text[: limit - 3] + "..."


ROW_NAME_KEYS = ("profileAttrName", "propertyName", "header", "name")


def row_name(*rows):
    """What a row keyed by a random id sets, so a changed row is named by its attribute."""
    for row in rows:
        if isinstance(row, dict):
            for k in ROW_NAME_KEYS:
                if isinstance(row.get(k), str) and row[k].strip():
                    return row[k]
    return ""


def setting_changes(a, b, path=""):
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b), key=str):
            seg = str(k)
            named = row_name(a.get(k), b.get(k))
            if named:
                seg += f" ({named})"
            p = f"{path}.{seg}" if path else seg
            if k not in b:
                out.append(f"{p}: removed (was {short(a[k])})")
            elif k not in a:
                out.append(f"{p}: added, {short(b[k])}")
            else:
                out.extend(setting_changes(a[k], b[k], p))
        return out
    if isinstance(a, list) and isinstance(b, list):
        if a == b:
            return []
        scalar = all(not isinstance(x, (dict, list)) for x in a + b)
        if scalar:
            gone = list((Counter(map(short, a)) - Counter(map(short, b))).elements())
            new = list((Counter(map(short, b)) - Counter(map(short, a))).elements())
            if gone or new:
                return [f"{path}: " + "; ".join(([f"removed {', '.join(gone)}"] if gone else [])
                                                + ([f"added {', '.join(new)}"] if new else []))]
            return [f"{path}: same items, new order"]
        if len(a) == len(b):
            out = []
            for i, (x, y) in enumerate(zip(a, b)):
                out.extend(setting_changes(x, y, f"{path}[{i}]"))
            return out
        return [f"{path}: was {short(a)}, now {short(b)}"]
    if a != b:
        return [f"{path}: was {short(a)}, now {short(b)}"]
    return []


# ---- the two comparisons


def lines_of_snapshot(snap):
    return Counter((l["from"], l["handle"], l["to"]) for l in snap["lines"])


def single_exit_nodes(snap):
    """Nodes every one of whose snapshot lines leaves from no named exit: a line drawn from one of
    them leaves from that one exit, whether or not the canvas showed it."""
    by_node = {}
    for l in snap["lines"]:
        by_node.setdefault(l["from"], set()).add(l["handle"])
    return {n for n, hs in by_node.items() if hs == {None}}


def diff_canvas(snap, canvas, path):
    if canvas.get("error"):
        raise InputError(f"the page script reported an error, so no lines were read: {canvas['error']}")
    if not isinstance(canvas.get("lines"), list) or not isinstance(canvas.get("nodes"), list):
        raise InputError(f"{path} is not the page script's output: it has no lines and nodes lists")
    if canvas.get("unreadable"):
        raise InputError(f"the page script found {len(canvas['unreadable'])} line(s) or node(s) on the canvas it could not read, "
                         f"so the canvas cannot be judged: {short(canvas['unreadable'], 400)}")
    page = canvas.get("page") or ""
    m = JOURNEY_URL.search(page)
    if m and m.group(1).lower() != str(snap["journey"]["id"]).lower():
        raise InputError(f"the canvas is journey {m.group(1)}, the snapshot is journey {snap['journey']['id']}")
    if not canvas["lines"] and not canvas["nodes"]:
        raise InputError("the page script read no lines and no nodes, so it did not read a journey canvas")

    snap_edges = {l["edge"]: l for l in snap["lines"]}
    single = single_exit_nodes(snap)
    after = Counter()
    for i, l in enumerate(canvas["lines"]):
        if not isinstance(l, dict) or not l.get("from") or not l.get("to"):
            raise InputError(f"{path}: lines[{i}] has no from or to")
        if "handle" in l:
            handle = l["handle"]
        else:
            known = snap_edges.get(l.get("edge"))
            if known and known["from"] == l["from"] and known["to"] == l["to"]:
                handle = known["handle"]
            elif l["from"] in single:
                handle = None
            else:
                handle = UNKNOWN
        after[(l["from"], handle, l["to"])] += 1

    labels = {n["id"]: n.get("label") or "" for n in canvas["nodes"] if isinstance(n, dict) and n.get("id")}
    out, count = line_report(lines_of_snapshot(snap), after, snap["nodes"], labels)
    added_nodes = [nid for nid in labels if nid not in snap["nodes"]]
    missing = [nid for nid in snap["nodes"] if nid not in labels]
    if added_nodes:
        out.append(f"Nodes on the canvas the snapshot does not hold ({len(added_nodes)}):")
        out.extend("  " + describe_node(n, snap["nodes"], labels) for n in added_nodes)
    if missing:
        out.append(f"Nodes in the snapshot not on the canvas ({len(missing)}), deleted or not drawn "
                   "(zoom out to fit the whole journey and read the canvas again):")
        out.extend("  " + describe_node(n, snap["nodes"]) for n in missing)
    head = (f"journey {snap['journey'].get('friendlyId')} \"{snap['journey'].get('name')}\": "
            f"snapshot of version {snap['journey']['version']}, compared with the editor canvas")
    return head, out, count + len(added_nodes) + len(missing)


def diff_saved(snap, later, path):
    j = journey_of(later, path)
    if str(j["journey"]["id"]).lower() != str(snap["journey"]["id"]).lower():
        raise InputError(f"{path} is journey {j['journey']['id']}, the snapshot is journey {snap['journey']['id']}")
    after = Counter((l["from"], l["handle"], l["to"]) for l in j["lines"])
    names = {**snap["nodes"], **{k: v for k, v in j["nodes"].items() if k not in snap["nodes"]}}
    out, count = line_report(lines_of_snapshot(snap), after, names)
    added = [n for n in j["nodes"] if n not in snap["nodes"]]
    removed = [n for n in snap["nodes"] if n not in j["nodes"]]
    if added:
        out.append(f"Nodes added ({len(added)}):")
        out.extend("  " + describe_node(n, j["nodes"]) for n in added)
    if removed:
        out.append(f"Nodes removed ({len(removed)}):")
        out.extend("  " + describe_node(n, snap["nodes"]) for n in removed)
    changed = []
    for nid, before in snap["nodes"].items():
        if nid in j["nodes"]:
            rows = setting_changes(before["settings"], j["nodes"][nid]["settings"])
            if rows:
                changed.append((nid, rows))
    if changed:
        out.append(f"Node settings changed ({len(changed)} node{'s' if len(changed) != 1 else ''}):")
        for nid, rows in changed:
            out.append("  " + describe_node(nid, snap["nodes"]))
            out.extend("    " + r for r in rows)
    v0, v1 = snap["journey"]["version"], j["journey"]["version"]
    head = (f"journey {snap['journey'].get('friendlyId')} \"{snap['journey'].get('name')}\": "
            f"snapshot of version {v0}, compared with version {v1}")
    if v0 == v1:
        head += " (the same version number, so this is not a read back of a new save)"
    return head, out, count + len(added) + len(removed) + sum(len(r) for _, r in changed)


# ---- commands


def cmd_snap(src, dst):
    j = journey_of(load_json(src, "fetch-journey result"), src)
    if os.path.exists(dst):
        raise InputError(f"{dst} already exists; a snapshot is never overwritten, so name a new file")
    snap = {"format": SNAP_FORMAT, **j}
    tmp = dst + ".partial"
    with open(tmp, "w", encoding="utf-8", errors="replace") as f:
        json.dump(snap, f, indent=1, sort_keys=True)
    os.replace(tmp, dst)
    jj = j["journey"]
    print(f"Snapshot of journey {jj['friendlyId']} \"{jj['name']}\" version {jj['version']}: "
          f"{len(j['nodes'])} nodes, {len(j['lines'])} lines, written to {dst}")
    return 0


def cmd_diff(snap_path, other_path):
    snap = load_snapshot(snap_path)
    other = load_json(other_path, "file to compare")
    if isinstance(other, dict) and other.get("source") == CANVAS_SOURCE:
        head, out, count = diff_canvas(snap, other, other_path)
        compared = "every line and every node on the canvas"  # the canvas carries no settings
    elif isinstance(other, dict) and "flow" in other:
        head, out, count = diff_saved(snap, other, other_path)
        compared = "every line and every node setting"
    else:
        raise InputError(f"{other_path} is neither the page script's output nor a fetch-journey result")
    print(head)
    if count == 0:
        print(f"No differences: {compared} matches the snapshot.")
        return 0
    print("\n".join(out))
    print(f"DIFFERENCES: {count}")
    return 1


USAGE = __doc__.split("\n\n")[1]


def main(argv):
    try:
        if len(argv) == 3 and argv[0] == "snap":
            return cmd_snap(argv[1], argv[2])
        if len(argv) == 3 and argv[0] == "diff":
            return cmd_diff(argv[1], argv[2])
    except InputError as e:
        print(f"jdiff: {e}", file=sys.stderr)
        return 2
    print("usage:\n" + USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv[1:]))
