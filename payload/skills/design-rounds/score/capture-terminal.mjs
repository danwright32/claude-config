#!/usr/bin/env node
// capture-terminal.mjs: the terminal adapter of the design match score (claude-config#1414).
//
//   node capture-terminal.mjs --design <settled.html> --mod <the mod's screen fixture.json> --out <capture folder>
//        [--fixture <the design's fixture.json>] [--checks <checks.js>] [--channel chrome|bundled] [--repo <checkout>]
//
// A Claude Code mod draws inside Claude Code itself, so neither the web adapter nor the SwiftUI adapter
// can picture it, and a picture of the real terminal would differ from the design's drawing everywhere
// outside the part being decided (font rendering, window chrome). So the build is drawn in the SAME form
// as the design: the mod's own band, as it publishes it to mod-kit, read from a committed fixture and put
// through mod-kit's own composer (payload/mods/mod-kit/hooks/band.ts), is drawn through the shared terminal
// (screens/terminal.js and terminal.css) in place of the band the design's own frame draws. Both pictures
// come from one renderer at the frame's width, and the checks read one kind of document.
//
// What the built window shows that is NOT the mod's: everything but the band (the title, the transcript,
// the prompt, the status line) is the design's own frame on both sides, as a captured page is on the web.
// So the picture compares the band, and the build's checks are run on the same window with everything
// but the band left out, so a check about the design's transcript or status line can never pass on the
// build's behalf. The score says this on every capture of this adapter.
//
// THE MOD'S FIXTURE, committed with the mod, and held to what the mod really publishes by the mod's own
// test, which "provenBy" names (the test asserts the rows it captured from the mod equal this file):
//
//     {"format": "mod-screen", "version": 1, "mod": "status-bar",
//      "provenBy": "payload/mods/status-bar/tests/register.test.tsx",
//      "frames": [{"id": "f1", "band": [<the mod's band rows, as $.modkit.bandRow is handed them>],
//                  "clickable": true}]}     clickable: whether a click lands (mod-kit's clicksReach);
//                                           where it does not, a button is drawn as its instead text
//
// Every frame of the design needs one; a fixture frame the design does not declare is refused. A band
// the shared terminal has no drawing for (a colour it lacks, strikethrough, a hotkey, a plain button) is
// recorded against its frame as not drawn, which the score reads as no score, never drawn plain.
//
// It writes the capture design_score.py reads (platform "terminal") and scores it, exiting with the
// score's own code: 0 matched, 1 not matched yet, 2 no score. Playwright is found as capture-web.mjs
// finds it.
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { LAUNCH_ARGS, designFrames, drawDesignFrame, findPlaywright, gitState, loadPlaywright, openDesign, runChecks, settle } from "./capture-web.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCORE = join(HERE, "design_score.py");
// mod-kit's band module, the one composer of every mod's band: in this repository at payload/mods, and
// installed at ~/.claude/mods, the same three folders up from this one either way.
export const KIT = join(HERE, "..", "..", "..", "mods", "mod-kit", "hooks", "band.ts");
const FORMAT = "mod-screen";
const FRAME_KEYS = ["id", "band", "clickable"];

// mod-kit's colour names (Claude Code theme keys), each as the shared terminal draws it (docs/mods-design.md:
// "color: 'warning' is the amber", "the violet drawn as the terminal's magenta", the terminal's grey). A
// colour not here has no drawing in the shared terminal and is refused, never drawn plain.
const COLOURS = { warning: "amber", error: "red", magenta: "violet", gray: "grey" };

export function parseArgs(argv) {
  const want = { "--design": "design", "--mod": "mod", "--out": "out", "--fixture": "fixture", "--checks": "checks",
    "--channel": "channel", "--repo": "repo" };
  const o = { channel: "chrome" };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (!(a in want)) throw new Error(`unknown argument ${a}`);
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) throw new Error(`${a} needs a value`);
    o[want[a]] = v; i++;
  }
  if (!o.design || !o.mod || !o.out) {
    throw new Error("usage: capture-terminal.mjs --design <settled.html> --mod <mod screen fixture.json> --out <capture folder> [--fixture <json>] [--checks <checks.js>] [--channel chrome|bundled] [--repo <checkout>]");
  }
  if (o.channel !== "chrome" && o.channel !== "bundled") throw new Error("--channel is chrome or bundled");
  return o;
}

/** mod-kit's own band module, read as it ships: its composer, its refusals and its button fallback. */
export async function loadKit(path = KIT) {
  try {
    return await import(pathToFileURL(path).toString());
  } catch (e) {
    throw new Error(`mod-kit's band module could not be loaded from ${path} (${String(e && e.message ? e.message : e).split("\n")[0]}), so the band cannot be composed as mod-kit composes it; node ${process.version} must be 22.18 or later to read it`);
  }
}

/** The mod's committed fixture, checked for shape: {mod, provenBy, frames: {id: {band, clickable}}}. */
export function readModScreen(path) {
  let m;
  try { m = JSON.parse(readFileSync(path, "utf8")); } catch (e) {
    throw new Error(e instanceof SyntaxError ? `the mod's fixture ${path} is not JSON (${e.message})` : `the mod's fixture ${path} could not be read (${e.message})`);
  }
  if (!m || typeof m !== "object" || m.format !== FORMAT || m.version !== 1) {
    throw new Error(`${path} is not a mod screen (its "format" is not ${FORMAT}, version 1)`);
  }
  if (typeof m.mod !== "string" || !m.mod.trim()) throw new Error(`the mod's fixture ${path} names no mod`);
  if (typeof m.provenBy !== "string" || !m.provenBy.trim()) {
    throw new Error(`the mod's fixture ${path} does not say which test holds its rows to what the mod publishes ("provenBy"), so nothing shows they are the mod's`);
  }
  if (!Array.isArray(m.frames) || !m.frames.length) throw new Error(`the mod's fixture ${path} lists no frames`);
  const frames = {};
  for (const [n, f] of m.frames.entries()) {
    const id = f && typeof f.id === "string" && f.id.trim() ? f.id : null;
    if (!id) throw new Error(`frame ${n + 1} of the mod's fixture ${path} has no id`);
    if (id in frames) throw new Error(`the mod's fixture ${path} holds the frame ${id} twice`);
    const extra = Object.keys(f).filter((k) => !FRAME_KEYS.includes(k));
    if (extra.length) {
      throw new Error(`frame ${id} of the mod's fixture carries ${extra.map((k) => JSON.stringify(k)).join(", ")}, and a frame of a mod screen holds only ${FRAME_KEYS.join(", ")}: the band is what the shared terminal draws of a mod`);
    }
    if (!Array.isArray(f.band)) throw new Error(`frame ${id} of the mod's fixture: its band is not a list of the mod's band rows`);
    if (f.clickable !== undefined && typeof f.clickable !== "boolean") throw new Error(`frame ${id} of the mod's fixture: clickable is true or false, not ${JSON.stringify(f.clickable)}`);
    for (const r of f.band) {
      if (r && typeof r === "object" && r.mod !== m.mod) {
        throw new Error(`a row of frame ${id} is published by ${r.mod}, and this fixture is ${m.mod}'s: a mod's fixture holds its own band`);
      }
    }
    frames[id] = { band: f.band, clickable: f.clickable !== false };
  }
  return { mod: m.mod, provenBy: m.provenBy, frames };
}

function colour(name, what) {
  if (!Object.prototype.hasOwnProperty.call(COLOURS, name)) {
    throw new Error(`${what}: the colour ${JSON.stringify(name)} has no drawing in the shared terminal, which draws ${Object.keys(COLOURS).join(", ")}; add it to screens/terminal.js before a design or a build can show it`);
  }
  return COLOURS[name];
}

function run(p, where) {
  if (p.strikethrough) throw new Error(`${where}: "${p.text}" is struck through, and the shared terminal has no drawing for strikethrough`);
  const styles = [];
  if (p.color !== undefined) styles.push(colour(p.color, where));
  if (p.bold) styles.push("bold");
  if (p.dim) styles.push("dim");
  return { text: p.text, styles };
}

/**
 * The band rows as the shared terminal draws them: each row in mod-kit's own order, through mod-kit's
 * own refusals and button fallback, as {card: "box" | "rule" | null, edge, lines}, each line a divider
 * or a list of {text, styles} and {button}. Throws, saying what, on anything the terminal cannot draw.
 */
export function bandSpec(rows, { clickable }, kit) {
  for (const r of rows) {
    const why = kit.refusal(r);
    if (why) throw new Error(why);
  }
  return kit.compose(rows).map((r) => {
    const where = `${r.mod}/${r.id}`;
    const part = (p) => {
      const indent = p.indent ? [{ text: " ".repeat(p.indent), styles: [] }] : [];
      if (!("button" in p)) return [...indent, run(p, where)];
      if (p.hotkey !== undefined) throw new Error(`${where}: button "${p.button}" has a hotkey, and the shared terminal has no drawing for one`);
      if (p.plain) throw new Error(`${where}: button "${p.button}" is plain, and the shared terminal has no drawing for a plain button`);
      if (clickable) return [...indent, { button: p.label }];
      return [...indent, ...kit.fallbackOf(r.mod, p).map((t) => run(t, where))];
    };
    const lines = r.lines.map((l) => (kit.isDivider(l) ? { divider: "grey" } : l.flatMap(part)));
    if (!r.frame) return { card: null, edge: null, lines };
    return { card: r.frame.kind === "box" ? "box" : "rule", edge: colour(r.frame.color ?? "gray", `${where} frame`), lines };
  });
}

// Put first in the frame's head, so it is there before the design's builder runs: Terminal is caught as
// terminal.js defines it, and its screen() draws the mod's band in place of the band the builder gives.
// With bandOnly the window keeps its size and loses everything that is not the band, for the checks.
const BAND_SCRIPT = `<script>
/* DR-MOD-BAND: the mod's band, in the design's own terminal window (claude-config#1414) */
(function () {
  "use strict";
  var spec = __SPEC__;
  var bandOnly = __BAND_ONLY__;
  var report = window.DR_MOD = { screens: 0 };
  var held;
  function piece(T, p) { return p.button !== undefined ? T.button(p.button) : T.run.apply(null, [p.text].concat(p.styles)); }
  function line(T, l) { return l.divider ? T.divider(l.divider) : l.map(function (p) { return piece(T, p); }); }
  function band(T) {
    var out = [];
    spec.forEach(function (r) {
      var lines = r.lines.map(function (l) { return line(T, l); });
      if (r.card) out.push(T.card(r.card, lines, { edge: r.edge }));
      else out.push.apply(out, lines);
    });
    return out;
  }
  Object.defineProperty(window, "Terminal", { configurable: true, get: function () { return held; }, set: function (T) {
    var screen = T.screen;
    T.screen = function (opts) {
      report.screens += 1;
      var o = {};
      Object.keys(opts || {}).forEach(function (k) { o[k] = opts[k]; });
      o.band = band(T);
      if (bandOnly) { o.title = ""; o.transcript = []; o.prompt = false; delete o.footer; o.status = false; }
      return screen(o);
    };
    held = T;
  } });
})();
</script>`;

/** The design's own frame document with the mod's band put in its terminal window. */
export function builtDocument(designDoc, spec, { bandOnly }) {
  const head = /<head[^>]*>/i.exec(designDoc);
  if (!head) throw new Error("the design's frame document has no <head> to put the mod's band ahead of its builder");
  const json = JSON.stringify(spec).replace(/</g, "\\u003c");
  const script = BAND_SCRIPT.replace("__SPEC__", () => json).replace("__BAND_ONLY__", bandOnly ? "true" : "false");
  const at = head.index + head[0].length;
  return designDoc.slice(0, at) + script + designDoc.slice(at);
}

// What the frame reported once drawn: whether its builder ran, and how many terminal windows it drew.
const readReport = () => ({
  built: !!(window.DR_FRAME && window.DR_FRAME.built),
  why: (window.DR_FRAME && window.DR_FRAME.why) || "its builder never ran",
  screens: window.DR_MOD ? window.DR_MOD.screens : 0,
});

function notDrawn(report) {
  if (!report.built) return `the design's frame could not be drawn with the mod's band in it: ${report.why}`;
  if (report.screens !== 1) {
    return report.screens === 0
      ? "the design's frame draws no terminal window, so there is no band to put the mod's in"
      : `the design's frame draws ${report.screens} terminal windows, so which band is the mod's is not one answer`;
  }
  return null;
}

/**
 * Draws every frame and writes the capture. `browser` is a Playwright browser (or a stand in with the
 * same few calls); deps.kit is mod-kit's band module and deps.gitState the build's commit.
 */
export async function capture(o, browser, frames, deps = {}) {
  const kit = deps.kit || (await loadKit());
  const modPath = resolve(o.mod);
  const screen = readModScreen(modPath);
  const declared = new Set(frames.map((f) => f.id));
  for (const id of Object.keys(screen.frames)) {
    if (!declared.has(id)) throw new Error(`the mod's fixture ${modPath} draws a band for the frame ${id}, which the design does not declare`);
  }
  const d = await openDesign(o, browser);
  const rows = [];
  try {
    for (const f of frames) {
      const { row, doc, viewport, shot } = await drawDesignFrame(d, browser, f);
      rows.push(row);
      const mf = screen.frames[f.id];
      let spec = null;
      if (!mf) {
        row.builtError = `the mod's fixture ${modPath} draws no band for frame ${f.id}`;
      } else {
        try { spec = bandSpec(mf.band, { clickable: mf.clickable }, kit); } catch (e) {
          row.builtError = `the mod's band could not be drawn in the shared terminal: ${e.message}`;
        }
      }
      if (row.builtError) { row.checks = []; continue; }
      const bpage = await browser.newPage({ viewport });
      try {
        await bpage.setContent(builtDocument(doc, spec, { bandOnly: false }), { waitUntil: "load" });
        row.builtError = notDrawn(await bpage.evaluate(readReport, { report: true })) || undefined;
        if (!row.builtError) {
          await settle(bpage, f.width);
          writeFileSync(join(d.out, row.builtImage), await bpage.screenshot(shot));
        }
      } finally {
        await bpage.close();
      }
      if (row.builtError) { row.checks = []; continue; }
      // The checks read the band alone: the rest of the window is the design's, never the build's.
      const cpage = await browser.newPage({ viewport });
      try {
        await cpage.setContent(builtDocument(doc, spec, { bandOnly: true }), { waitUntil: "load" });
        row.checks = await runChecks(cpage, d.checksSrc, f.id, d.fixture);
      } finally {
        await cpage.close();
      }
    }
  } finally {
    await d.source.close();
  }
  const git = (deps.gitState || gitState)(resolve(o.repo || process.cwd()));
  const cap = {
    format: "design-capture", version: 1, platform: "terminal", designFile: d.design,
    build: `${screen.mod}'s band, from ${modPath}, held to the mod by ${screen.provenBy}`, modScreen: modPath,
    commit: git.commit, dirty: git.dirty, playwright: o.playwright || null,
    capturedAt: new Date().toISOString().replace(/\.\d+Z$/, "Z"), frames: rows, notes: d.notes,
  };
  writeFileSync(join(d.out, "capture.json"), JSON.stringify(cap, null, 1));
  return cap;
}

async function main() {
  let o;
  try { o = parseArgs(process.argv); } catch (e) { console.error(`capture-terminal: ${e.message}`); return 2; }
  let pw;
  try {
    const found = findPlaywright({ repo: o.repo || process.cwd() });
    pw = loadPlaywright(found);
    o.playwright = { from: found.from, path: found.path, version: found.version };
  } catch (e) {
    console.error(`capture-terminal: could not score: ${String(e.message || e).split("\n")[0]}`);
    return 2;
  }
  const frames = designFrames(o.design);
  const browser = await pw.chromium.launch({ ...(o.channel === "chrome" ? { channel: "chrome" } : {}), args: LAUNCH_ARGS });
  try {
    await capture(o, browser, frames);
  } finally {
    await browser.close();
  }
  const s = spawnSync("python3", [SCORE, "score", o.out], { stdio: "inherit" });
  return s.status === null ? 2 : s.status;
}

function realOrSame(p) { try { return realpathSync(p); } catch { return resolve(p); } }

if (process.argv[1] && realOrSame(resolve(process.argv[1])) === realOrSame(fileURLToPath(import.meta.url))) {
  // Anything unexpected is no score, exit 2: left to node it exits 1, which reads as "not matched yet".
  main().then((code) => process.exit(code), (e) => { console.error(`capture-terminal: could not score: ${String(e && e.message ? e.message : e)}`); process.exit(2); });
}
