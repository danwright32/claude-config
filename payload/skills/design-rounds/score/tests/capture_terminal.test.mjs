// The terminal adapter's own logic (claude-config#1414), against a stand in browser and mod-kit's real
// band module, so it runs wherever node does (CI included) with no Playwright and no Chrome. The real
// browser run, a mod's band against a settled terminal design, is in test-score-adapters.sh.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bandSpec, builtDocument, capture, loadKit, parseArgs, readModScreen } from "../capture-terminal.mjs";

const PNG = Buffer.from("89504e470d0a1a0a", "hex");
const kit = await loadKit();

// The status bar's band as its own test harness publishes it to mod-kit (payload/mods/status-bar,
// "a failing PR and unpushed commits" with context at 74%), recorded from a real run on 2026-10-21.
const LOOK = { mod: "status-bar", id: "look", slot: "needs-a-look",
  lines: [[{ text: "PR #636 checks failing", color: "warning" }, { text: " | ", dim: true }, { text: "2 unpushed commits", color: "warning" }]] };
const COMPACT = { mod: "status-bar", id: "compact", slot: "compact",
  lines: [[{ text: "ctx 74% ", color: "warning" }, { button: "compact", label: "Compact", instead: [{ text: "type: ", dim: true }, { text: "/compact" }] }]] };

test("arguments: the usage is refused without a design, the mod's fixture or an out folder", () => {
  assert.throws(() => parseArgs(["node", "x", "--design", "d.html", "--out", "o"]), /usage/);
  assert.throws(() => parseArgs(["node", "x", "--mod", "m.json", "--out", "o"]), /usage/);
  assert.throws(() => parseArgs(["node", "x", "--design", "d.html", "--mod", "m.json", "--build", "u"]), /unknown argument --build/);
  const o = parseArgs(["node", "x", "--design", "d.html", "--mod", "m.json", "--out", "o", "--checks", "c.js"]);
  assert.deepEqual([o.design, o.mod, o.out, o.checks, o.channel], ["d.html", "m.json", "o", "c.js", "chrome"]);
});

test("mod-kit's own band module is what the band is read through", () => {
  assert.equal(typeof kit.compose, "function");
  assert.equal(typeof kit.refusal, "function");
  assert.equal(typeof kit.fallbackOf, "function");
});

test("the status bar's real rows become the terminal's own pieces: amber, dim, and a bracketed button", () => {
  assert.deepEqual(bandSpec([LOOK, COMPACT], { clickable: true }, kit), [
    { card: null, edge: null, lines: [[
      { text: "PR #636 checks failing", styles: ["amber"] }, { text: " | ", styles: ["dim"] },
      { text: "2 unpushed commits", styles: ["amber"] }]] },
    { card: null, edge: null, lines: [[{ text: "ctx 74% ", styles: ["amber"] }, { button: "Compact" }]] },
  ]);
});

test("rows are drawn in mod-kit's own slot order, never the order a fixture lists them", () => {
  const spec = bandSpec([COMPACT, LOOK], { clickable: true }, kit);
  assert.equal(spec[0].lines[0][0].text, "PR #636 checks failing");
});

test("where a click cannot land, a button is drawn as its instead text, as mod-kit draws it", () => {
  const spec = bandSpec([COMPACT], { clickable: false }, kit);
  assert.deepEqual(spec[0].lines[0], [{ text: "ctx 74% ", styles: ["amber"] },
    { text: "type: ", styles: ["dim"] }, { text: "/compact", styles: [] }]);
  const bare = { ...COMPACT, lines: [[{ button: "compact", label: "Compact" }]] };
  assert.deepEqual(bandSpec([bare], { clickable: false }, kit)[0].lines[0],
    [{ text: "type: ", styles: ["dim"] }, { text: "/press status-bar compact", styles: [] }]);
});

test("a framed card keeps its frame and its colour, and a divider is the terminal's grey rule", () => {
  const card = { mod: "manual-steps", id: "steps", slot: "steps", frame: { kind: "left-rule", color: "warning" },
    lines: [[{ text: "Step 1", bold: true }], { divider: true }, [{ text: "done", color: "gray", indent: 2 }]] };
  assert.deepEqual(bandSpec([card], { clickable: true }, kit), [{ card: "rule", edge: "amber", lines: [
    [{ text: "Step 1", styles: ["bold"] }], { divider: "grey" }, [{ text: "  ", styles: [] }, { text: "done", styles: ["grey"] }]] }]);
  const box = { ...card, frame: { kind: "box" } };
  assert.deepEqual(bandSpec([box], { clickable: true }, kit)[0].card, "box");
  assert.deepEqual(bandSpec([box], { clickable: true }, kit)[0].edge, "grey");
});

test("a colour the shared terminal cannot draw is refused by name, never drawn plain", () => {
  const green = { ...LOOK, lines: [[{ text: "Live:", color: "success" }]] };
  assert.throws(() => bandSpec([green], { clickable: true }, kit), /colour "success".*draws warning, error, magenta, gray/);
  const edge = { ...LOOK, frame: { kind: "box", color: "suggestion" } };
  assert.throws(() => bandSpec([edge], { clickable: true }, kit), /colour "suggestion"/);
});

test("what the shared terminal has no drawing for is refused by name: strikethrough, a hotkey, a plain button", () => {
  assert.throws(() => bandSpec([{ ...LOOK, lines: [[{ text: "old", strikethrough: true }]] }], { clickable: true }, kit), /strikethrough/);
  assert.throws(() => bandSpec([{ ...LOOK, lines: [[{ button: "a", label: "A", hotkey: "1" }]] }], { clickable: true }, kit), /hotkey/);
  assert.throws(() => bandSpec([{ ...LOOK, lines: [[{ button: "a", label: "A", plain: true }]] }], { clickable: true }, kit), /plain/);
});

test("a row mod-kit itself refuses is refused with mod-kit's own reason", () => {
  assert.throws(() => bandSpec([{ ...LOOK, slot: "sidebar" }], { clickable: true }, kit), /slot "sidebar" is not one of needs-a-look/);
});

function fixtureFile(body) {
  const dir = mkdtempSync(join(tmpdir(), "capture-terminal-test."));
  const path = join(dir, "band.screen.json");
  writeFileSync(path, typeof body === "string" ? body : JSON.stringify(body));
  return { dir, path };
}
const GOOD = { format: "mod-screen", version: 1, mod: "status-bar",
  provenBy: "payload/mods/status-bar/tests/register.test.tsx",
  frames: [{ id: "f1", band: [LOOK, COMPACT] }, { id: "f2", band: [LOOK], clickable: false }] };

test("the mod's fixture is read with its frames, and clickable defaults to a click landing", () => {
  const { dir, path } = fixtureFile(GOOD);
  const m = readModScreen(path);
  assert.equal(m.mod, "status-bar");
  assert.equal(m.provenBy, GOOD.provenBy);
  assert.deepEqual(Object.keys(m.frames), ["f1", "f2"]);
  assert.equal(m.frames.f1.clickable, true);
  assert.equal(m.frames.f2.clickable, false);
  rmSync(dir, { recursive: true, force: true });
});

test("a fixture that is not a mod screen, or does not say which test holds it to the mod, is refused", () => {
  for (const [body, why] of [
    ["not json", /is not JSON/],
    [{ ...GOOD, format: "design-capture" }, /is not a mod screen/],
    [{ ...GOOD, provenBy: "" }, /provenBy/],
    [{ ...GOOD, mod: undefined }, /names no mod/],
    [{ ...GOOD, frames: [] }, /lists no frames/],
    [{ ...GOOD, frames: [{ id: "f1", band: [] }, { id: "f1", band: [] }] }, /f1 twice/],
    [{ ...GOOD, frames: [{ id: "f1", band: "rows" }] }, /band is not a list/],
    [{ ...GOOD, frames: [{ id: "f1", band: [], pane: [] }] }, /"pane"/],
    [{ ...GOOD, frames: [{ id: "f1", band: [], clickable: "yes" }] }, /clickable/],
    [{ ...GOOD, frames: [{ id: "f1", band: [{ ...LOOK, mod: "account-room" }] }] }, /account-room.*status-bar/],
  ]) {
    const { dir, path } = fixtureFile(body);
    assert.throws(() => readModScreen(path), why, JSON.stringify(body).slice(0, 80));
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the built document is the design's own frame with the band put in place, first in its head", () => {
  const design = '<!doctype html>\n<html><head><meta charset="utf-8"><style>x{}</style></head><body><div id="dr-slot"></div><script>B</script></body></html>';
  const spec = bandSpec([LOOK], { clickable: true }, kit);
  const doc = builtDocument(design, spec, { bandOnly: false });
  const at = doc.indexOf("<head>") + "<head>".length;
  assert.ok(doc.slice(at).startsWith("<script>"), doc.slice(at, at + 40));
  assert.ok(doc.includes("PR #636 checks failing"));
  // Everything the design wrote is still there, unchanged and in order.
  assert.equal(doc.replace(/<script>\n\/\* DR-MOD-BAND[\s\S]*?<\/script>/, ""), design);
  assert.ok(builtDocument(design, spec, { bandOnly: true }).includes("bandOnly = true"));
  assert.ok(!doc.includes("bandOnly = true"));
  // A band carrying a closing script tag cannot end the injected script early.
  const sly = bandSpec([{ ...LOOK, lines: [[{ text: "</script><b>x" }]] }], { clickable: true }, kit);
  assert.ok(!builtDocument(design, sly, { bandOnly: false }).includes("</script><b>x"));
  // A band whose own text spells a placeholder keeps its text: only the template's placeholders are filled.
  const named = bandSpec([{ ...LOOK, lines: [[{ text: "__BAND_ONLY__ and __SPEC__" }]] }], { clickable: true }, kit);
  assert.ok(builtDocument(design, named, { bandOnly: true }).includes('"text":"__BAND_ONLY__ and __SPEC__"'));
});

/** A stand in browser: each page reports what the injected band script would, per document. */
function fakeBrowser({ report = () => ({ built: true, screens: 1 }), checks = null } = {}) {
  const log = [];
  const page = (viewport) => {
    const me = { viewport, content: null, shots: [] };
    log.push(me);
    return {
      goto: async () => {},
      setContent: async (doc) => { me.content = doc; },
      mouse: { move: async () => {} },
      evaluate: async (fn, arg) => {
        if (typeof fn === "string") return undefined;
        if (arg && typeof arg === "object" && "frame" in arg) {
          const side = me.content.includes("DR-MOD-BAND") ? (me.content.includes("bandOnly = true") ? "built" : "picture") : "design";
          return checks ? checks(arg.frame, side) : [];
        }
        if (arg && typeof arg === "object" && arg.report) return report(me.content);
        // The design side's own report and the settled file's reader of it (claude-config#1539): this
        // stand in's design documents report nothing, and its settled file has no reader.
        if (arg && typeof arg === "object" && "designReport" in arg) return null;
        if (arg && typeof arg === "object" && "troubleOf" in arg) return undefined;
        if (typeof arg === "string") return `<!doctype html><html><head></head><body>frame ${arg}</body></html>`;
        return true;
      },
      screenshot: async (opts) => { me.shots.push(opts); return PNG; },
      close: async () => {},
    };
  };
  return { log, newPage: async ({ viewport } = {}) => page(viewport) };
}

function setupCapture(mod = GOOD) {
  const { dir, path } = fixtureFile(mod);
  writeFileSync(join(dir, "settled.html"), "<!doctype html><p>settled</p>");
  writeFileSync(join(dir, "settled.checks.js"), "window.DESIGN_CHECKS = [];");
  return { dir, o: { design: join(dir, "settled.html"), mod: path, out: join(dir, "cap"), channel: "chrome" } };
}
const FRAMES = [{ id: "f1", width: 820 }, { id: "f2", width: 640, height: 400 }];
const git = () => ({ commit: "c".repeat(40), dirty: false });

test("every frame is drawn twice at its own width, the design's and the mod's band in it, the checks reading the band alone", async () => {
  const { dir, o } = setupCapture();
  const b = fakeBrowser({ checks: (frame, side) => [{ id: "D1", ok: side !== "picture", detail: side }] });
  const cap = await capture(o, b, FRAMES, { gitState: git, kit });
  assert.equal(cap.platform, "terminal");
  assert.match(cap.build, /status-bar.*band\.screen\.json.*register\.test\.tsx/);
  assert.equal(cap.commit, "c".repeat(40));
  const f1 = cap.frames[0];
  assert.deepEqual([f1.id, f1.designImage, f1.builtImage, f1.builtError], ["f1", "f1-design.png", "f1-built.png", undefined]);
  // Never the pictured page: the build's checks run on the band alone, so the design's own transcript
  // or status line can never pass a check on the build's behalf.
  assert.deepEqual(f1.checks, [{ id: "D1", ok: true, detail: "built" }]);
  assert.deepEqual(f1.designChecks, [{ id: "D1", ok: true, detail: "design" }]);
  const shots = b.log.filter((p) => p.shots.length);
  assert.deepEqual(shots.map((p) => p.viewport.width), [820, 820, 640, 640]);
  assert.deepEqual(shots[2].shots[0].fullPage, false);
  assert.deepEqual(shots[0].shots[0].fullPage, true);
  const written = JSON.parse(readFileSync(join(o.out, "capture.json"), "utf8"));
  assert.equal(written.platform, "terminal");
  rmSync(dir, { recursive: true, force: true });
});

test("a design frame the mod's fixture draws no band for is recorded as not drawn, never pictured empty", async () => {
  const { dir, o } = setupCapture({ ...GOOD, frames: [GOOD.frames[0]] });
  const cap = await capture(o, fakeBrowser(), FRAMES, { gitState: git, kit });
  assert.match(cap.frames[1].builtError, /fixture .* draws no band for frame f2/);
  assert.deepEqual(cap.frames[1].checks, []);
  rmSync(dir, { recursive: true, force: true });
});

test("a fixture frame the design does not declare is refused, never left out quietly", async () => {
  const { dir, o } = setupCapture({ ...GOOD, frames: [...GOOD.frames, { id: "f9", band: [] }] });
  await assert.rejects(capture(o, fakeBrowser(), FRAMES, { gitState: git, kit }), /f9, which the design does not declare/);
  rmSync(dir, { recursive: true, force: true });
});

test("a band the terminal cannot draw is recorded by frame with the reason, for the score to call no score", async () => {
  const green = { ...GOOD, frames: [{ id: "f1", band: [{ ...LOOK, lines: [[{ text: "Live:", color: "success" }]] }] }, GOOD.frames[1]] };
  const { dir, o } = setupCapture(green);
  const cap = await capture(o, fakeBrowser(), FRAMES, { gitState: git, kit });
  assert.match(cap.frames[0].builtError, /could not be drawn in the shared terminal: .*"success"/);
  assert.equal(cap.frames[1].builtError, undefined);
  rmSync(dir, { recursive: true, force: true });
});

test("a design frame that draws no terminal window, or whose builder throws, leaves the band nowhere to go", async () => {
  const { dir, o } = setupCapture();
  const b = fakeBrowser({ report: (doc) => (doc.includes("frame f1") ? { built: true, screens: 0 } : { built: false, why: "Terminal: unknown style" }) });
  const cap = await capture(o, b, FRAMES, { gitState: git, kit });
  assert.match(cap.frames[0].builtError, /draws no terminal window/);
  assert.match(cap.frames[1].builtError, /Terminal: unknown style/);
  rmSync(dir, { recursive: true, force: true });
});
