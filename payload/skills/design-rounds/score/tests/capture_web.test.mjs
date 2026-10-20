// The web adapter's own logic, against a stand in browser, so it runs wherever node does (CI
// included) with no Playwright and no Chrome. The real browser run is in test-score-adapters.sh.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { capture, frameUrl, parseArgs, runChecks } from "../capture-web.mjs";

const PNG = Buffer.from("89504e470d0a1a0a", "hex");

/** A stand in browser: records every page's viewport, what it drew and its screenshot options. */
function fakeBrowser({ failBuilt = null, checks = null, noFrames = false } = {}) {
  const log = [];
  const page = (viewport) => {
    const me = { viewport, url: null, content: null, shots: [], scripts: [] };
    log.push(me);
    return {
      goto: async (url) => {
        me.url = url;
        if (failBuilt && !url.startsWith("file:")) throw new Error(failBuilt);
      },
      setContent: async (doc) => { me.content = doc; },
      mouse: { move: async () => {} },
      evaluate: async (_fn, arg) => {
        if (arg && typeof arg === "object" && "frame" in arg) {
          return checks ? checks(arg.frame, me.content !== null ? "design" : "built") : [];
        }
        if (typeof arg === "string") return `<!doctype html><p>frame ${arg}</p>`;
        return !noFrames;
      },
      screenshot: async (opts) => { me.shots.push(opts); return PNG; },
      addScriptTag: async (s) => { me.scripts.push(s.content); },
      addStyleTag: async () => {},
      setViewportSize: async (v) => { me.viewport = v; },
      close: async () => { me.closed = true; },
    };
  };
  return {
    log,
    newPage: async ({ viewport } = {}) => page(viewport),
    newContext: async () => ({ newPage: async () => page(null), close: async () => {} }),
  };
}

function setup() {
  const dir = mkdtempSync(join(tmpdir(), "capture-web-test."));
  writeFileSync(join(dir, "settled.html"), "<!doctype html><p>design</p>");
  writeFileSync(join(dir, "settled.checks.js"), "window.DESIGN_CHECKS = [];");
  writeFileSync(join(dir, "fixture.json"), JSON.stringify({ advisors: 3 }));
  return dir;
}
const FRAMES = [{ id: "f1", title: "Tomorrow", width: 1280 }, { id: "f2", title: "Phone", width: 390, height: 844 }];
const GIT = () => ({ commit: "a".repeat(40), dirty: false });
const drawn = (b) => b.log.slice(1);  // every page after the settled file itself

test("the frame's id is added to the build's URL, keeping a query it had", () => {
  assert.equal(frameUrl("http://127.0.0.1:3000/admin/capacity?day=2", "f1"), "http://127.0.0.1:3000/admin/capacity?day=2&frame=f1");
});

test("arguments: the usage is refused without a design, a build or an out folder", () => {
  assert.throws(() => parseArgs(["node", "x", "--design", "d.html", "--out", "o"]), /usage/);
  assert.throws(() => parseArgs(["node", "x", "--design", "d.html", "--build"]), /needs a value/);
  assert.throws(() => parseArgs(["node", "x", "--bogus", "1"]), /unknown argument/);
  assert.equal(parseArgs(["node", "x", "--design", "d.html", "--out", "o", "--design-only"]).designOnly, true);
});

test("every frame is drawn on both sides at its own width, full page unless it declares a height", async () => {
  const dir = setup();
  const b = fakeBrowser();
  const cap = await capture({ design: join(dir, "settled.html"), build: "http://127.0.0.1:3000/p", out: join(dir, "cap"), fixture: join(dir, "fixture.json") }, b, FRAMES, { gitState: GIT });
  assert.ok(b.log[0].url.startsWith("file://") && b.log[0].url.endsWith("settled.html"), "the settled file is opened once");
  assert.deepEqual(drawn(b).map((p) => [p.viewport.width, p.viewport.height]), [[1280, 900], [1280, 900], [390, 844], [390, 844]]);
  assert.deepEqual(drawn(b).map((p) => p.shots[0].fullPage), [true, true, false, false]);
  assert.equal(drawn(b)[0].content, "<!doctype html><p>frame f1</p>", "the design side is the frame's own document, drawn as a page");
  assert.equal(drawn(b)[1].url, "http://127.0.0.1:3000/p?frame=f1");
  assert.ok(b.log.every((p) => p.closed), "every page is closed, the settled file's included");
  assert.equal(cap.format, "design-capture");
  assert.equal(cap.version, 1);
  assert.equal(cap.platform, "web");
  assert.equal(cap.commit, "a".repeat(40));
  assert.equal(cap.dirty, false);
  for (const f of ["f1-design.png", "f1-built.png", "f2-design.png", "f2-built.png", "capture.json"]) {
    assert.ok(existsSync(join(dir, "cap", f)), `${f} is written`);
  }
  assert.deepEqual(JSON.parse(readFileSync(join(dir, "cap", "capture.json"), "utf8")).frames.map((f) => f.id), ["f1", "f2"]);
  rmSync(dir, { recursive: true, force: true });
});

test("a settled file that cannot give a frame's document is refused, never drawn as a whole page", async () => {
  const dir = setup();
  await assert.rejects(
    capture({ design: join(dir, "settled.html"), build: "http://127.0.0.1:3000/p", out: join(dir, "cap") }, fakeBrowser({ noFrames: true }), FRAMES, { gitState: GIT }),
    /designFrameDocument/);
  assert.ok(!existsSync(join(dir, "cap", "capture.json")), "and no capture is written");
  rmSync(dir, { recursive: true, force: true });
});

test("a built page that cannot be loaded is recorded by frame, for the score to call no score", async () => {
  const dir = setup();
  const cap = await capture({ design: join(dir, "settled.html"), build: "http://127.0.0.1:9/p", out: join(dir, "cap") },
    fakeBrowser({ failBuilt: "net::ERR_CONNECTION_REFUSED at http://127.0.0.1:9/p" }), FRAMES, { gitState: GIT });
  assert.match(cap.frames[0].builtError, /ERR_CONNECTION_REFUSED/);
  assert.deepEqual(cap.frames[0].checks, []);
  rmSync(dir, { recursive: true, force: true });
});

test("the checks run on both sides with the frame and the committed fixture", async () => {
  const dir = setup();
  const seen = [];
  const b = fakeBrowser({ checks: (frame, side) => { seen.push([frame, side]); return [{ id: "D1", ok: true, detail: "" }]; } });
  const cap = await capture({ design: join(dir, "settled.html"), build: "http://127.0.0.1:3000/p", out: join(dir, "cap") }, b, FRAMES, { gitState: GIT });
  assert.deepEqual(seen, [["f1", "design"], ["f1", "built"], ["f2", "design"], ["f2", "built"]]);
  assert.deepEqual(cap.frames[0].designChecks, [{ id: "D1", ok: true, detail: "" }]);
  assert.deepEqual(cap.frames[0].checks, [{ id: "D1", ok: true, detail: "" }]);
  assert.match(drawn(b)[0].scripts[0], /DESIGN_CHECKS/);
  rmSync(dir, { recursive: true, force: true });
});

test("no checks file is said, and no decision is reported checked", async () => {
  const dir = setup();
  rmSync(join(dir, "settled.checks.js"));
  const cap = await capture({ design: join(dir, "settled.html"), build: "http://127.0.0.1:3000/p", out: join(dir, "cap") }, fakeBrowser(), FRAMES, { gitState: GIT });
  assert.deepEqual(cap.frames[0].checks, []);
  assert.match(cap.notes[0], /no checks file/);
  rmSync(dir, { recursive: true, force: true });
});

test("design only draws the design's side and leaves the build to the platform's own test", async () => {
  const dir = setup();
  const b = fakeBrowser();
  const cap = await capture({ design: join(dir, "settled.html"), out: join(dir, "cap"), designOnly: true }, b, FRAMES, { gitState: GIT });
  assert.equal(drawn(b).length, 2);
  assert.ok(drawn(b).every((p) => p.content !== null && p.url === null));
  assert.equal(cap.build, null);
  assert.ok(!existsSync(join(dir, "cap", "f1-built.png")));
  rmSync(dir, { recursive: true, force: true });
});

test("a checks file that cannot be run is one result that threw, never an empty pass", async () => {
  const page = { addScriptTag: async () => { throw new Error("SyntaxError: Unexpected token"); } };
  const r = await runChecks(page, "window.DESIGN_CHECKS = [", "f1", null);
  assert.equal(r.length, 1);
  assert.equal(r[0].threw, true);
  assert.match(r[0].detail, /could not be run/);
});
