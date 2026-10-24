// The terminal adapter's own logic (claude-config#1414), against a stand in browser and mod-kit's real
// band module, so it runs wherever node does (CI included) with no Playwright and no Chrome. The real
// browser run, a mod's band against a settled terminal design, is in test-score-adapters.sh.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { bandSpec, builtDocument, capture, loadKit, parseArgs, readModScreen } from "../capture-terminal.mjs";

const PNG = Buffer.from("89504e470d0a1a0a", "hex");
const kit = await loadKit();

// The settled file's own reader of a frame's report, as chrome_frame.py writes it into every settled
// page (claude-config#1539), so a test of the build's words holds them to the page's, never to a copy.
const CHROME_FRAME = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "chrome_frame.py");
const TROUBLE_SRC = /FRAME_TROUBLE = """([\s\S]*?)"""/.exec(readFileSync(CHROME_FRAME, "utf8"))[1];
const designFrameTrouble = new Function(`${TROUBLE_SRC}\nreturn designFrameTrouble;`)();
const WHOLE = { built: true, why: "", noSlot: false, shownWhy: "" };

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

/** A stand in browser: each page reports what its document would, per document and side.
 * reports(doc, side): the DR_FRAME report the frame leaves, copied to plain values, null for none;
 * side is "design" or "built". reader: the settled file's designFrameTrouble, none when left out, as a
 * file made before claude-config#1539 has. screens(doc): the terminal windows the band script counted. */
function fakeBrowser({ reports = () => null, reader = null, screens = () => 1, checks = null } = {}) {
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
        if (arg && typeof arg === "object" && "modScreens" in arg) return screens(me.content);
        // A frame's own report, on either side, and the settled file's reader of it (claude-config#1539).
        if (arg && typeof arg === "object" && "designReport" in arg) return reports(me.content, (me.content || "").includes("DR-MOD-BAND") ? "built" : "design");
        if (arg && typeof arg === "object" && "troubleOf" in arg) return reader ? reader(arg.troubleOf) : undefined;
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

test("a design frame that draws no terminal window, or two, leaves the band nowhere to go", async () => {
  const { dir, o } = setupCapture();
  const b = fakeBrowser({ reports: () => WHOLE, reader: designFrameTrouble, screens: (doc) => (doc.includes("frame f1") ? 0 : 2) });
  const cap = await capture(o, b, FRAMES, { gitState: git, kit });
  assert.match(cap.frames[0].builtError, /draws no terminal window/);
  assert.match(cap.frames[1].builtError, /draws 2 terminal windows/);
  assert.ok(cap.frames.every((f) => f.designError === undefined), "a whole design side records nothing");
  rmSync(dir, { recursive: true, force: true });
});

// The built side's report was read by a reader of its own, which took only built and why: a builder's
// throw was worded unlike the settled page and the score, and a screenShown throw was not read at all
// (claude-config#1581). It is read through the settled file's designFrameTrouble, as the design side is.
test("the built side's builder throw and screenShown throw are worded as the settled page words them", async () => {
  const { dir, o } = setupCapture();
  const built = { f1: { built: false, why: "Terminal: unknown style", noSlot: false, shownWhy: "" },
    f2: { built: true, why: "", noSlot: false, shownWhy: "no partner list" } };
  const asked = [];
  const reader = (r) => { asked.push(r); return designFrameTrouble(r); };
  const b = fakeBrowser({ reports: (doc, side) => (side === "built" ? built[/frame (f\d)/.exec(doc)[1]] : WHOLE), reader });
  const cap = await capture(o, b, FRAMES, { gitState: git, kit });
  const said = "the design's frame with the mod's band put in it is not drawn whole: ";
  assert.equal(cap.frames[0].builtError, said + "its builder threw (Terminal: unknown style), so nothing of the round is drawn in it");
  assert.equal(cap.frames[1].builtError, said + "its builder's screenShown threw (no partner list), so whatever that draws once the frame is shown is missing from it");
  assert.deepEqual(asked, [WHOLE, built.f1, WHOLE, built.f2], "each side's own report is what the reader is handed");
  assert.ok(cap.frames.every((f) => f.designError === undefined && f.checks.length === 0));
  assert.deepEqual(b.log.filter((p) => p.shots.length).length, 2, "only the two design sides are pictured");
  rmSync(dir, { recursive: true, force: true });
});

test("a built frame that reports nothing is said as its builder never running, in the settled file's words", async () => {
  const { dir, o } = setupCapture();
  const b = fakeBrowser({ reports: (doc, side) => (side === "built" ? null : WHOLE), reader: designFrameTrouble });
  const cap = await capture(o, b, FRAMES, { gitState: git, kit });
  assert.equal(cap.frames[0].builtError, "the design's frame with the mod's band put in it is not drawn whole: its builder never ran, so nothing of the round is drawn in it");
  rmSync(dir, { recursive: true, force: true });
});

test("a settled file older than its reader is said once for both sides, never read by a second reader", async () => {
  const { dir, o } = setupCapture();
  const b = fakeBrowser({ reports: (doc, side) => (side === "built" ? { built: false, why: "x", noSlot: false, shownWhy: "" } : WHOLE) });
  const cap = await capture(o, b, FRAMES, { gitState: git, kit });
  const notes = cap.notes.filter((n) => /designFrameTrouble/.test(n));
  assert.equal(notes.length, 1, cap.notes.join("\n"));
  assert.match(notes[0], /make-settled\.py/);
  assert.ok(cap.frames.every((f) => f.builtError === undefined && f.designError === undefined));
  rmSync(dir, { recursive: true, force: true });
});
