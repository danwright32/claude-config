// Runs the page script (../read_lines.js) against a fixture DOM, the way the browser tools run it:
// the file's text evaluated as one script whose last value is the answer. Used by test_jdiff.py.
//
//   node page_harness.js <tree.json> <page script> [<page url>]
//
// tree.json is the fixture HTML parsed by Python's html.parser into
// {"tag", "attrs", "children": [element | {"text"}]}. The document built from it answers only what
// the page script is allowed to ask (querySelectorAll with ONE class selector, getAttribute,
// textContent, own property names). Anything else throws, so a page script that starts relying on a
// selector this fixture cannot answer fails here instead of passing on a guess.
"use strict";
const fs = require("fs");
const vm = require("vm");

const [treePath, scriptPath, pageUrl] = process.argv.slice(2);
if (!treePath || !scriptPath) {
  console.error("usage: node page_harness.js <tree.json> <page script> [<page url>]");
  process.exit(2);
}

class FakeElement {
  constructor(node, parent) {
    this.tagName = String(node.tag || "").toUpperCase();
    this._attrs = node.attrs || {};
    this._parent = parent;
    this._children = (node.children || []).map((c) => (c.text !== undefined ? { text: c.text } : new FakeElement(c, this)));
    const handle = this._attrs["data-fake-fiber-handle"];
    if (handle !== undefined) {
      // What React keeps on a rendered element: a fiber whose ancestors carry the component props.
      // The edge component's props hold source, target and sourceHandle.
      const label = this._attrs["aria-label"] || "";
      const m = /^Edge from (\S+) to (\S+)$/.exec(label) || [];
      this["__reactFiber$fixture"] = {
        memoizedProps: { className: this._attrs["class"] },
        return: {
          memoizedProps: { children: null },
          return: { memoizedProps: { id: "x", source: m[1], target: m[2], sourceHandle: handle === "null" ? null : handle } },
        },
      };
    }
  }
  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this._attrs, name) ? this._attrs[name] : null;
  }
  get classTokens() {
    return String(this._attrs["class"] || "").split(/\s+/).filter(Boolean);
  }
  get textContent() {
    return this._children.map((c) => (c instanceof FakeElement ? c.textContent : c.text)).join("");
  }
  querySelectorAll(selector) {
    return queryAll(this, selector);
  }
}

function queryAll(root, selector) {
  const m = /^\.([A-Za-z0-9_-]+)$/.exec(selector);
  if (!m) throw new Error(`fixture document: unsupported selector ${JSON.stringify(selector)} (only one class selector)`);
  const out = [];
  const walk = (el) => {
    for (const c of el._children) {
      if (!(c instanceof FakeElement)) continue;
      if (c.classTokens.includes(m[1])) out.push(c);
      walk(c);
    }
  };
  walk(root);
  return out;
}

const tree = JSON.parse(fs.readFileSync(treePath, "utf8"));
const body = new FakeElement({ tag: "body", attrs: {}, children: tree }, null);
const documentStub = { querySelectorAll: (s) => queryAll(body, s) };
const context = { document: documentStub };
if (pageUrl) context.location = { href: pageUrl };
const result = vm.runInNewContext(fs.readFileSync(scriptPath, "utf8"), context, { filename: scriptPath });
if (typeof result !== "string") {
  console.error(`the page script's last value was ${typeof result}, not the JSON text the browser tools hand back`);
  process.exit(3);
}
process.stdout.write(result);
