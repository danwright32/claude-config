// The web adapter's own logic, against a stand in browser, so it runs wherever node does (CI
// included) with no Playwright and no Chrome. The real browser run is in test-score-adapters.sh.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, realpathSync, symlinkSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { capture, findPlaywright, frameUrl, parseArgs, runChecks } from "../capture-web.mjs";

const SCORE_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const PIN = JSON.parse(readFileSync(join(SCORE_DIR, "shared-playwright.json"), "utf8"));

const PNG = Buffer.from("89504e470d0a1a0a", "hex");

/** A stand in browser: records every page's viewport, what it drew and its screenshot options. */
function fakeBrowser({ failBuilt = null, checks = null, noFrames = false, neverReady = false } = {}) {
  const log = [];
  const page = (viewport) => {
    const me = { viewport, url: null, content: null, shots: [], scripts: [], waited: [], steps: [] };
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
      waitForSelector: async (selector, opts) => {
        me.waited.push([selector, opts && opts.timeout]);
        me.steps.push("ready");
        if (neverReady === "crash") throw new Error("Target page, context or browser has been closed");
        if (neverReady) throw Object.assign(new Error(`Timeout ${opts && opts.timeout}ms exceeded waiting for ${selector}`), { name: "TimeoutError" });
      },
      screenshot: async (opts) => { me.shots.push(opts); me.steps.push("shot"); return PNG; },
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

test("--ready names what the built page shows once its content is there", () => {
  assert.equal(parseArgs(["node", "x", "--design", "d.html", "--build", "http://h/p", "--out", "o", "--ready", "main [data-tc]"]).ready, "main [data-tc]");
  assert.equal(parseArgs(["node", "x", "--design", "d.html", "--build", "http://h/p", "--out", "o"]).ready, undefined);
});

test("with --ready the built page is pictured only once it shows that, and the design side never waits", async () => {
  // Slate's trial (Try-Pennie/slate#3947): a streamed page fired load before its content arrived on a
  // slow runner, and CI pictured the loading placeholder, 12.9% where every run since reads 100%.
  const dir = setup();
  const b = fakeBrowser();
  await capture({ design: join(dir, "settled.html"), build: "http://127.0.0.1:3000/p", out: join(dir, "cap"), ready: "main [data-tc]" }, b, FRAMES, { gitState: GIT });
  const [d1, b1, d2, b2] = drawn(b);
  assert.deepEqual([d1.waited, d2.waited], [[], []], "the design side is drawn from a document already whole");
  for (const p of [b1, b2]) {
    assert.equal(p.waited.length, 1);
    assert.equal(p.waited[0][0], "main [data-tc]");
    assert.ok(p.waited[0][1] > 0, "the wait is bounded");
    assert.deepEqual(p.steps, ["ready", "shot"], "the wait comes before the picture");
  }
  rmSync(dir, { recursive: true, force: true });
});

test("a built page that never shows its --ready content is recorded by frame as unloaded, never pictured", async () => {
  const dir = setup();
  const b = fakeBrowser({ neverReady: true, checks: () => [{ id: "D1", ok: true, detail: "" }] });
  const cap = await capture({ design: join(dir, "settled.html"), build: "http://127.0.0.1:3000/p", out: join(dir, "cap"), ready: "main [data-tc]" }, b, FRAMES, { gitState: GIT });
  for (const f of cap.frames) {
    assert.match(f.builtError, /never showed main \[data-tc\]/);
    assert.deepEqual(f.checks, []);
  }
  assert.deepEqual(drawn(b)[1].shots, [], "no picture of a page that is not there yet");
  assert.ok(!existsSync(join(dir, "cap", "f1-built.png")));
  rmSync(dir, { recursive: true, force: true });
});

test("a wait for --ready that fails for another reason says that reason, never that the page was slow", async () => {
  const dir = setup();
  const cap = await capture({ design: join(dir, "settled.html"), build: "http://127.0.0.1:3000/p", out: join(dir, "cap"), ready: "main [data-tc]" },
    fakeBrowser({ neverReady: "crash" }), FRAMES, { gitState: GIT });
  assert.match(cap.frames[0].builtError, /waiting for main \[data-tc\] failed: .*has been closed/);
  assert.doesNotMatch(cap.frames[0].builtError, /never showed/);
  rmSync(dir, { recursive: true, force: true });
});

test("without --ready nothing is waited on, as before", async () => {
  const dir = setup();
  const b = fakeBrowser();
  await capture({ design: join(dir, "settled.html"), build: "http://127.0.0.1:3000/p", out: join(dir, "cap") }, b, FRAMES, { gitState: GIT });
  assert.ok(drawn(b).every((p) => p.waited.length === 0));
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

// --- which Playwright draws the design (claude-config#1385) ------------------------------------------
// A stand in package is enough here: the lookup only finds a folder, it never launches anything.
function fakePlaywright(dir, version = "0.0.1-fake") {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "playwright", version, main: "index.js" }));
  writeFileSync(join(dir, "index.js"), "module.exports = { chromium: {} };\n");
  return dir;
}
function lookupWorld() {
  const dir = mkdtempSync(join(tmpdir(), "capture-web-pw."));
  const home = join(dir, "home");
  const app = join(dir, "app");
  mkdirSync(home, { recursive: true });
  mkdirSync(app, { recursive: true });
  writeFileSync(join(app, "package.json"), "{}");
  const shared = join(home, PIN.root, "node_modules", "playwright");
  return { dir, home, app, shared };
}

test("the shared install lives outside ~/.claude, so the sync never carries it", () => {
  assert.ok(!PIN.root.startsWith(".claude"), `the shared root is ${PIN.root}`);
  assert.match(PIN.version, /^\d+\.\d+\.\d+$/, "the version is pinned exactly");
});

test("the app's own Playwright comes first, ahead of DESIGN_SCORE_PLAYWRIGHT and the shared install", () => {
  const w = lookupWorld();
  fakePlaywright(join(w.app, "node_modules", "playwright"), "1.0.0-app");
  const named = fakePlaywright(join(w.dir, "named"));
  fakePlaywright(w.shared);
  const r = findPlaywright({ repo: w.app, env: { DESIGN_SCORE_PLAYWRIGHT: named }, home: w.home });
  assert.equal(r.from, "app");
  assert.equal(realpathSync(r.path), realpathSync(join(w.app, "node_modules", "playwright")));
  assert.equal(r.version, "1.0.0-app");
  assert.equal(r.browsersPath, null, "the app's own Playwright keeps its own browsers");
  rmSync(w.dir, { recursive: true, force: true });
});

test("with no app Playwright, DESIGN_SCORE_PLAYWRIGHT is used ahead of the shared install", () => {
  const w = lookupWorld();
  const named = fakePlaywright(join(w.dir, "named"));
  fakePlaywright(w.shared);
  const r = findPlaywright({ repo: w.app, env: { DESIGN_SCORE_PLAYWRIGHT: named }, home: w.home });
  assert.equal(r.from, "env");
  assert.equal(r.path, named);
  rmSync(w.dir, { recursive: true, force: true });
});

test("a DESIGN_SCORE_PLAYWRIGHT naming nothing is refused by name, never passed over for another", () => {
  const w = lookupWorld();
  fakePlaywright(w.shared);
  assert.throws(() => findPlaywright({ repo: w.app, env: { DESIGN_SCORE_PLAYWRIGHT: join(w.dir, "gone") }, home: w.home }),
    /DESIGN_SCORE_PLAYWRIGHT names .*gone/);
  rmSync(w.dir, { recursive: true, force: true });
});

test("with nothing named, the shared install is used, with the browsers installed beside it", () => {
  const w = lookupWorld();
  fakePlaywright(w.shared, PIN.version);
  const r = findPlaywright({ repo: w.app, env: {}, home: w.home });
  assert.equal(r.from, "shared");
  assert.equal(r.path, w.shared);
  assert.equal(r.version, PIN.version);
  assert.equal(r.browsersPath, join(w.home, PIN.root, "browsers"));
  // The path the installer prints to export names the same install, and keeps its browsers.
  const named = findPlaywright({ repo: w.app, env: { DESIGN_SCORE_PLAYWRIGHT: w.shared }, home: w.home });
  assert.equal(named.from, "env");
  assert.equal(named.browsersPath, join(w.home, PIN.root, "browsers"));
  rmSync(w.dir, { recursive: true, force: true });
});

test("with no Playwright anywhere it fails, naming the install command, never skipping the design side", () => {
  const w = lookupWorld();
  assert.throws(() => findPlaywright({ repo: w.app, env: {}, home: w.home }),
    (e) => /install-playwright\.sh/.test(e.message) && e.message.includes(w.shared));
  rmSync(w.dir, { recursive: true, force: true });
});

test("run with no Playwright anywhere, the adapter exits 2 (no score) and writes no capture", () => {
  const w = lookupWorld();
  writeFileSync(join(w.dir, "settled.html"), "<!doctype html><p>design</p>");
  const env = { ...process.env, HOME: w.home };
  delete env.DESIGN_SCORE_PLAYWRIGHT;
  const p = spawnSync(process.execPath, [join(SCORE_DIR, "capture-web.mjs"), "--design", join(w.dir, "settled.html"),
    "--out", join(w.dir, "cap"), "--design-only", "--repo", w.app], { env, encoding: "utf8" });
  assert.equal(p.status, 2, p.stdout + p.stderr);
  assert.match(p.stderr, /install-playwright\.sh/);
  assert.ok(!existsSync(join(w.dir, "cap", "capture.json")), "and no capture is written");
  rmSync(w.dir, { recursive: true, force: true });
});

test("run through a symlinked path, the adapter still runs, never exiting 0 having done nothing", () => {
  // Found 2026-10-20 (claude-config#1385): node gives the script's real path to import.meta.url but
  // the path as typed to argv[1], so on macOS (/var is /private/var) the main guard never matched and
  // the adapter exited 0 without drawing anything.
  const dir = mkdtempSync(join(tmpdir(), "capture-web-link."));
  symlinkSync(join(SCORE_DIR, "capture-web.mjs"), join(dir, "linked.mjs"));
  const p = spawnSync(process.execPath, [join(dir, "linked.mjs")], { encoding: "utf8" });
  assert.equal(p.status, 2, `exit ${p.status}: ${p.stdout}${p.stderr}`);
  assert.match(p.stderr, /usage/);
  rmSync(dir, { recursive: true, force: true });
});

test("the capture records which Playwright drew it", async () => {
  const dir = setup();
  const pw = { from: "shared", path: "/somewhere/node_modules/playwright", version: "1.2.3" };
  const cap = await capture({ design: join(dir, "settled.html"), out: join(dir, "cap"), designOnly: true, playwright: pw }, fakeBrowser(), FRAMES, { gitState: GIT });
  assert.deepEqual(cap.playwright, pw);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, "cap", "capture.json"), "utf8")).playwright, pw);
  rmSync(dir, { recursive: true, force: true });
});
