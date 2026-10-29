// read_lines.js: reads every line and node off the Regal journey editor canvas (claude-config#1853).
//
// Run the whole file in the editor tab with the browser tools' JavaScript tool; its last value is
// JSON text. Save that text to a file and compare it with the snapshot:
//
//   python3 ~/.claude/skills/regal-journey-edits/jdiff.py diff <snapshot.json> <canvas.json>
//
// The canvas is React Flow. Each line is a g.react-flow__edge whose aria-label is
// "Edge from <source node id> to <target node id>", and each node a div.react-flow__node holding its
// id in data-id; those ids are the ones fetch-journey's flow uses. The exit a line leaves from
// (sourceHandle) is not in the markup. It is read from React's own props on the element when the
// page exposes them, and otherwise left out ("handle" absent), for jdiff to take from the snapshot
// or to report as not read. It reads only; it changes nothing on the page.
//
// A line it cannot read is listed under "unreadable", never skipped, and a page with no canvas
// returns an "error", so neither can reach jdiff as a canvas with fewer lines.
(function () {
  "use strict";
  var EDGE_LABEL = /^Edge from (\S+) to (\S+)$/;
  var out = {
    source: "react-flow canvas",
    page: typeof location !== "undefined" && location ? String(location.href) : null,
    lines: [],
    nodes: [],
    unreadable: [],
    handles: "none",
  };

  function edgeId(el) {
    var id = el.getAttribute("data-id");
    if (id) return id;
    var testid = el.getAttribute("data-testid") || "";
    return testid.indexOf("rf__edge-") === 0 ? testid.slice("rf__edge-".length) : null;
  }

  // React keeps the rendering component's props on a fiber hung off the element under a key such
  // as __reactFiber$<random>. The edge component's props are a few levels up and carry
  // source, target and sourceHandle.
  function handleOf(el, from, to) {
    var keys = Object.keys(el);
    for (var k = 0; k < keys.length; k++) {
      if (keys[k].indexOf("__reactFiber$") !== 0 && keys[k].indexOf("__reactInternalInstance$") !== 0) continue;
      var fiber = el[keys[k]];
      for (var depth = 0; fiber && depth < 20; depth++, fiber = fiber["return"]) {
        var p = fiber.memoizedProps;
        if (p && typeof p === "object" && Object.prototype.hasOwnProperty.call(p, "sourceHandle") &&
            p.source === from && p.target === to) {
          return { found: true, value: p.sourceHandle === undefined ? null : p.sourceHandle };
        }
      }
    }
    return { found: false };
  }

  var seen = {};
  var edges = document.querySelectorAll(".react-flow__edge");
  var withHandle = 0;
  for (var i = 0; i < edges.length; i++) {
    var el = edges[i];
    var id = edgeId(el);
    if (id && seen[id]) continue;
    if (id) seen[id] = true;
    var label = el.getAttribute("aria-label");
    var m = label ? EDGE_LABEL.exec(label.trim()) : null;
    if (!m) {
      out.unreadable.push({ edge: id, label: label });
      continue;
    }
    var line = { edge: id, from: m[1], to: m[2] };
    var h = handleOf(el, m[1], m[2]);
    if (h.found) {
      line.handle = h.value;
      withHandle++;
    }
    out.lines.push(line);
  }
  out.handles = withHandle === 0 ? "none" : withHandle === out.lines.length ? "read" : "some";

  var nodes = document.querySelectorAll(".react-flow__node");
  for (var n = 0; n < nodes.length; n++) {
    var nid = nodes[n].getAttribute("data-id");
    var text = String(nodes[n].textContent || "").replace(/\s+/g, " ").trim();
    if (!nid) {
      out.unreadable.push({ node: text.slice(0, 80) });
      continue;
    }
    out.nodes.push({ id: nid, label: text.slice(0, 80) });
  }

  if (out.lines.length === 0 && out.nodes.length === 0 && out.unreadable.length === 0) {
    out.error = "no React Flow canvas on this page (no .react-flow__edge or .react-flow__node elements); open the journey in the editor and wait for it to draw";
  }
  return JSON.stringify(out);
})();
