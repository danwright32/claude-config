#!/usr/bin/env python3
"""Build a Regal journey edits page from a JSON spec (the regal-journey-edits skill).

    python3 build_page.py spec.json page.html

The page is the Slate Journey Edits layout Dan chose on 2026-10-27: one card per journey with an
Open in Regal button, one ticked row per node change, every existing node named by its number and
its exact live name, wiring written as sentences, and a Copy button beside every value he types.

Text fields take these marks, so nothing is typed by hand that the spec already knows:
    <<8>>         node 8 of this journey, rendered with its live name from the journey's "nodes" map
    <<479:8>>     node 8 of journey 479, for notes outside a journey card
    <<new:Name>>  a node this change adds, by the name given in its "new" list
    <<copy:97>>   the copy this change makes of node 97 (a copy keeps its source's name in Regal)
    [[value]]     a value Dan types or pastes, drawn with its own Copy button
    `text`        code that is read, not typed

Anything the spec cannot back is refused, every problem named, exit 2: a node with no number or no
name, a reference to a node the journey does not hold, an unknown tag or group, and any em or en
dash, because the page must never invent a label or a node (Dan, 2026-10-27: "Node numbers can't
change. why does the name of the 3 change").
"""
import html
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TAGS = ("Keep", "Change", "Add", "Remove")
TYPE_WORDS = {
    "trigger": "Trigger", "conditional": "Conditional", "delay": "Delay", "sms": "SMS",
    "agentSms": "Agent SMS", "updateContact": "Update Contact", "webhook": "Webhook",
    "cancelTask": "Cancel Task", "call": "Call", "ABTest": "A/B Test", "email": "Email",
}
# Built from code points so this file holds no dash for the style gate to catch.
DASHES = re.compile("[" + chr(0x2013) + chr(0x2014) + "]")
LQ, RQ = chr(0x201C), chr(0x201D)
MARK = re.compile(r"<<([^<>]+)>>|\[\[(.+?)\]\]|`([^`]+)`")


class SpecError(Exception):
    pass


def E(s):
    return html.escape(str(s), quote=True)


def copy_chip(value):
    v = E(value)
    return f'<span class="cv"><code>{v}</code><button type="button" class="cp" data-copy="{v}" aria-label="Copy {v}">Copy</button></span>'


def type_word(t):
    return TYPE_WORDS.get(t, t)


def quoted(label):
    return f"{LQ}{E(label)}{RQ}"


def node_phrase(num, node):
    label = node.get("label", "")
    if label:
        return f'<span class="nref">node {E(num)} {quoted(label)}</span>'
    detail = node.get("detail")
    extra = f", {E(detail)}" if detail else ""
    return f'<span class="nref">node {E(num)}</span> (an unnamed {E(type_word(node.get("type", "")))}{extra})'


class Renderer:
    def __init__(self, spec):
        self.spec = spec
        self.errors = []
        self.journeys = {}
        for j in spec.get("journeys", []) or []:
            if isinstance(j, dict) and "id" in j:
                self.journeys[str(j["id"])] = j

    def err(self, where, msg):
        self.errors.append(f"{where}: {msg}")

    # Text with marks to HTML. `journey` and `change` give the context the marks resolve in.
    def text(self, s, where, journey=None, change=None):
        if not isinstance(s, str):
            self.err(where, "expected text, got %r" % (s,))
            return ""
        out, pos = [], 0
        for m in MARK.finditer(s):
            out.append(E(s[pos:m.start()]))
            pos = m.end()
            ref, copy, code = m.group(1), m.group(2), m.group(3)
            if copy is not None:
                out.append(copy_chip(copy))
            elif code is not None:
                out.append(f"<code>{E(code)}</code>")
            else:
                out.append(self.ref(ref.strip(), where, journey, change))
        out.append(E(s[pos:]))
        return "".join(out)

    def ref(self, ref, where, journey, change):
        if ref.startswith("new:"):
            name = ref[4:]
            names = [n.get("name") for n in (change or {}).get("new", []) if n.get("name")]
            if name not in names:
                self.err(where, f"<<new:{name}>> names no node this change adds (it adds {names})")
            return f'the new node <span class="nref">{quoted(name)}</span>'
        if ref.startswith("copy:"):
            num = ref[5:]
            copies = [str(n.get("copyOf")) for n in (change or {}).get("new", []) if n.get("copyOf") is not None]
            if num not in copies:
                self.err(where, f"<<copy:{num}>> but this change makes no copy of node {num}")
            node = (journey or {}).get("nodes", {}).get(num)
            if node is None:
                self.err(where, f"<<copy:{num}>> but the journey has no node {num}")
                return f"the copy of node {E(num)}"
            return "the copy of " + node_phrase(num, node)
        jid, num = None, ref
        if ":" in ref:
            jid, num = ref.split(":", 1)
        j = self.journeys.get(jid) if jid else journey
        if j is None:
            self.err(where, f"<<{ref}>> names a journey this page does not hold" if jid
                     else f"<<{ref}>> is outside a journey card; write <<journey:node>>")
            return f"node {E(num)}"
        node = (j.get("nodes") or {}).get(num)
        if node is None:
            self.err(where, f"<<{ref}>>: journey {j.get('id')} has no node {num} in its nodes map")
            return f"node {E(num)}"
        phrase = node_phrase(num, node)
        return (f"journey {E(j['id'])} " + phrase) if jid else phrase

    def check_dashes(self, o, where="spec"):
        if isinstance(o, str):
            if DASHES.search(o):
                self.err(where, "holds an em or en dash: %r" % o[:80])
        elif isinstance(o, dict):
            for k, v in o.items():
                self.check_dashes(v, f"{where}.{k}")
        elif isinstance(o, list):
            for i, v in enumerate(o):
                self.check_dashes(v, f"{where}[{i}]")

    def body(self, items, where, journey=None, change=None):
        parts = []
        for i, it in enumerate(items or []):
            w = f"{where}[{i}]"
            if isinstance(it, str):
                parts.append(f"<p>{self.text(it, w, journey, change)}</p>")
            elif isinstance(it, dict) and ("list" in it or "ol" in it):
                tagname = "ol" if "ol" in it else "ul"
                lis = "".join(f"<li>{self.text(x, w, journey, change)}</li>" for x in (it.get("ol") or it.get("list")))
                parts.append(f"<{tagname}>{lis}</{tagname}>")
            else:
                self.err(w, 'a body item is text, {"list": [...]} or {"ol": [...]}')
        return "".join(parts)

    def new_node(self, n, where, journey, change):
        if not isinstance(n, dict) or not n.get("type"):
            self.err(where, "a new node needs a type")
            return ""
        nodes = journey.get("nodes", {})
        if n.get("copyOf") is not None:
            src = nodes.get(str(n["copyOf"]))
            if src is None:
                self.err(where, f"copies node {n['copyOf']}, which journey {journey.get('id')} does not hold")
                title = f"copy of node {E(n['copyOf'])}"
            else:
                title = "copy of " + node_phrase(str(n["copyOf"]), src)
            if n.get("name"):
                title += f', renamed <span class="nref">{quoted(n["name"])}</span>'
        elif n.get("name"):
            title = f'<span class="nref">{quoted(n["name"])}</span>'
        else:
            self.err(where, "a new node needs a name, or copyOf naming the node it copies")
            title = "unnamed"
        rows = [("Node type", E(n["type"]))]
        if n.get("name"):
            rows.append(("Node name", copy_chip(n["name"])))
        for k, f in enumerate(n.get("fields", [])):
            rows.append((E(f.get("field", "")), self.text(f.get("value", ""), f"{where}.fields[{k}]", journey, change)))
        out = [f'<div class="sub-h">New node</div><div class="t">{title}</div>',
               '<div class="tablewrap"><table><thead><tr><th scope="col">Field</th><th scope="col">Set it to</th></tr></thead><tbody>'
               + "".join(f"<tr><td>{a}</td><td>{b}</td></tr>" for a, b in rows) + "</tbody></table></div>"]
        attrs = n.get("rows")
        if attrs:
            counts = {t: 0 for t in TAGS}
            trs = []
            for k, r in enumerate(attrs):
                w = f"{where}.rows[{k}]"
                t = r.get("tag")
                if t not in TAGS:
                    self.err(w, f"tag {t!r} is not one of {', '.join(TAGS)}")
                    continue
                counts[t] += 1
                attr, val, was = r.get("attr", ""), r.get("value", ""), r.get("was", "")
                if t == "Keep":
                    cell = E(val)
                elif t == "Change":
                    cell = f"<s>{E(was)}</s> to {copy_chip(val)}"
                elif t == "Add":
                    cell = copy_chip(val)
                else:
                    cell = f"<s>{E(val)}</s> delete this row"
                acell = copy_chip(attr) if t == "Add" else f"<code>{E(attr)}</code>"
                trs.append(f'<tr class="r-{t.lower()}"><td class="tagcell"><span class="tag tag-{t.lower()}">{t}</span></td>'
                           f"<td>{acell}</td><td>{cell}</td></tr>")
            src_rows = counts["Keep"] + counts["Change"] + counts["Remove"]
            out.append(f'<p class="line">Every attribute row: {src_rows} in the node you copy, with {counts["Change"]} to change, '
                       f'{counts["Add"]} to add and {counts["Remove"]} to delete. Leave every Keep row as it is.</p>')
            out.append('<div class="tablewrap"><table class="attrs"><thead><tr><th scope="col"></th><th scope="col">Attribute</th>'
                       '<th scope="col">Value</th></tr></thead><tbody>' + "".join(trs) + "</tbody></table></div>")
        if n.get("note"):
            out.append(f'<p class="line">{self.text(n["note"], where + ".note", journey, change)}</p>')
        return "".join(out)

    def change_row(self, c, where, journey, tick):
        nodes = journey.get("nodes", {})
        key, num = c.get("key"), c.get("node")
        if not key:
            self.err(where, "a change needs a key")
        if num is None:
            self.err(where, "a change needs the number of the existing node it sits beside")
            return ""
        node = nodes.get(str(num))
        if node is None:
            self.err(where, f"names node {num}, which the journey's nodes map does not hold")
            return ""
        label = node.get("label", "")
        detail = f", {E(node['detail'])}" if node.get("detail") else ""
        head = (f'Node {E(num)} <span class="quiet">({E(type_word(node.get("type", "")))})</span> '
                + (quoted(label) if label else f'<span class="quiet">no name{detail}</span>')
                + (f' <span class="pill">{E(c["do"])}</span>' if c.get("do") else ""))
        parts = [f'<div class="t">{head}</div>']
        if c.get("current"):
            parts.append(f'<div class="cond">{E(c["current"])}</div>')
        if c.get("title"):
            parts.append(f'<div class="t" style="margin-top:8px">{self.text(c["title"], where + ".title", journey, c)}</div>')
        if c.get("why"):
            parts.append(f'<p class="line">{self.text(c["why"], where + ".why", journey, c)}</p>')
        for k, n in enumerate(c.get("new", [])):
            parts.append(self.new_node(n, f"{where}.new[{k}]", journey, c))
        if c.get("steps"):
            parts.append('<div class="sub-h">Steps</div><ol>' + "".join(
                f"<li>{self.text(s, f'{where}.steps[{k}]', journey, c)}</li>" for k, s in enumerate(c["steps"])) + "</ol>")
        for label_, field in (("Skipped on the new path", "skipped"), ("Test", "test"), ("After publishing", "after")):
            if c.get(field):
                parts.append(f'<p class="line"><b>{label_}.</b> {self.text(c[field], f"{where}.{field}", journey, c)}</p>')
        box = (f'<input class="check" type="checkbox" data-c="{E(key)}" aria-label="Journey {E(journey["id"])}, node {E(num)} change done">'
               if tick else "<span></span>")
        return f'<div class="node" id="j{E(journey["id"])}-{E(key)}">{box}<div>{"".join(parts)}</div></div>'

    def journey_card(self, j, where, tick, waiting):
        for f in ("id", "name", "uuid", "version"):
            if j.get(f) in (None, ""):
                self.err(where, f"a journey needs {f}")
        if not isinstance(j.get("nodes"), dict):
            self.err(where, "a journey needs a nodes map of every node its text names")
            j["nodes"] = {}
        for k, n in j["nodes"].items():
            if not str(k).isdigit():
                self.err(f"{where}.nodes", f"node key {k!r} is not a node number")
            if not isinstance(n, dict) or "label" not in n or not n.get("type"):
                self.err(f"{where}.nodes.{k}", 'needs a type and a label ("" when Regal shows none)')
        jid = E(j.get("id"))
        url = f'https://app.regal.io/orchestration/journeys/{E(j.get("uuid", ""))}'
        changes = j.get("changes", [])
        keys = [c.get("key") for c in changes]
        if len(set(keys)) != len(keys):
            self.err(where, "two changes share a key")
        meta = [f'<span class="pill">trigger: {E(j.get("trigger", ""))}</span>',
                f'<span>written against live version {E(j.get("version"))}{", read " + E(j["read"]) if j.get("read") else ""}</span>']
        if changes:
            meta.append(f"<span>{len(changes)} node change{'s' if len(changes) != 1 else ''}</span>")
        pill = f'<span class="pill wait">{E(waiting)}</span>' if waiting else ""
        box = (f'<input class="check" type="checkbox" data-jbox aria-label="Journey {jid} done">' if tick else "<span></span>")
        tick_attr = ' data-tick="1"' if tick else ""
        out = [f'<article class="journey" id="j{jid}" data-j="{jid}"{tick_attr}>',
               f'<div class="jhead">{box}<div><div class="name"><span class="fid">#{jid}</span><span>{E(j.get("name", ""))}</span>{pill}</div>'
               f'<div class="meta">{"".join(meta)}</div></div>'
               f'<button type="button" class="open" data-href="{url}">Open in Regal</button></div>']
        if j.get("note"):
            note = j["note"] if isinstance(j["note"], list) else [j["note"]]
            out.append(f'<div class="jnote">{self.body(note, where + ".note", j)}</div>')
        if changes:
            out.append('<div class="nodes">' + "".join(
                self.change_row(c, f"{where}.changes[{k}]", j, tick) for k, c in enumerate(changes)) + "</div>")
        out.append("</article>")
        return "".join(out)

    def notes_section(self, n, where):
        return (f'<section class="notes" id="{E(n.get("id", ""))}"><h2>{E(n.get("title", ""))}</h2>'
                f'<div class="panel">{self.body(n.get("body"), where + ".body")}</div></section>')

    def render(self):
        s = self.spec
        self.check_dashes(s)
        for f in ("title", "subtitle", "storageKey", "groups", "journeys"):
            if not s.get(f):
                self.err("spec", f"needs {f}")
        if self.errors:
            raise SpecError("\n".join(self.errors))
        groups = {g.get("key"): g for g in s["groups"]}
        seen = set()
        for i, j in enumerate(s["journeys"]):
            if j.get("group") not in groups:
                self.err(f"journeys[{i}]", f"group {j.get('group')!r} is not one of {list(groups)}")
            if str(j.get("id")) in seen:
                self.err(f"journeys[{i}]", f"journey {j.get('id')} appears twice")
            seen.add(str(j.get("id")))
        main = [self.notes_section(n, f"notesTop[{i}]") for i, n in enumerate(s.get("notesTop", []))]
        pattern_shown = False
        for g in s["groups"]:
            items = [(i, j) for i, j in enumerate(s["journeys"]) if j.get("group") == g.get("key")]
            if not items:
                continue
            tick = bool(g.get("tickable"))
            count = f'<span class="n">{len(items)} journey{"s" if len(items) != 1 else ""}</span>'
            sec = [f'<section class="group" id="g-{E(g["key"])}"><h2>{E(g.get("title", ""))} {count}</h2>']
            if g.get("lead"):
                sec.append(f'<p class="lead">{self.text(g["lead"], "groups." + str(g["key"]) + ".lead")}</p>')
            if tick and not pattern_shown and s.get("pattern"):
                p = s["pattern"]
                sec.append(f'<div class="howto"><h3>{E(p.get("title", ""))}</h3><ol>'
                           + "".join(f"<li>{self.text(x, 'pattern.steps')}</li>" for x in p.get("steps", [])) + "</ol></div>")
                pattern_shown = True
            for i, j in items:
                sec.append(self.journey_card(j, f"journeys[{i}] (#{j.get('id')})", tick, g.get("pill")))
            sec.append("</section>")
            main.append("".join(sec))
        main += [self.notes_section(n, f"notesBottom[{i}]") for i, n in enumerate(s.get("notesBottom", []))]
        legend = ""
        if s.get("legend"):
            legend = '<div class="legend">' + "".join(
                f'<span><b>{E(x.get("term", ""))}</b> = {self.text(x.get("text", ""), "legend")}</span>' for x in s["legend"]) + "</div>"
        subtitle = self.text(s["subtitle"], "subtitle")
        if self.errors:
            raise SpecError("\n".join(self.errors))
        tpl = open(os.path.join(HERE, "template.html"), encoding="utf-8", errors="replace").read()
        page = (tpl.replace("__TITLE__", E(s["title"]))
                .replace("__SUBTITLE__", subtitle)
                .replace("__LEGEND__", legend)
                .replace("__STORAGE_KEY__", json.dumps(s["storageKey"]))
                .replace("__DB_DOC__", json.dumps(s.get("dbDoc", "checks/state")))
                .replace("__MAIN__", "\n".join(main)))
        if DASHES.search(page):
            raise SpecError("the built page holds an em or en dash")
        return page


def build(spec):
    return Renderer(spec).render()


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip())
        return 2
    try:
        spec = json.load(open(argv[1], encoding="utf-8", errors="replace"))
    except (OSError, ValueError) as e:
        print(f"build_page: could not read the spec {argv[1]}: {e}")
        return 2
    try:
        page = build(spec)
    except SpecError as e:
        print("build_page: refused, nothing written:\n" + str(e))
        return 2
    with open(argv[2], "w", encoding="utf-8", errors="replace") as f:
        f.write(page)
    n_c = sum(len(j.get("changes", [])) for j in spec["journeys"])
    print(f"build_page: wrote {argv[2]}: {len(spec['journeys'])} journeys, {n_c} node changes")
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv))
