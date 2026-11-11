// node --test test_shoot_web.mjs: the drive helper contract of shoot_web.mjs (claude-config#2516).
// Run by test-shoot-web.sh beside it, through the TAP reporter so its counts read the same on every node.
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseShot, shoot } from "./shoot_web.mjs";

const ENV = { VERIFICATION_URL: "http://127.0.0.1:4173/", VERIFICATION_RECEIPT_DIR: "/tmp/r", VERIFICATION_WORKTREE: "/tmp/wt" };
const ARGS = ["screenshot", "/invoices", "1440", "dark", "invoices__list__head__1440__dark.png", "[data-row]", "136"];

test("the screenshots.py contract reads into one shot", () => {
  const o = parseShot(ARGS, ENV);
  assert.equal(o.url, "http://127.0.0.1:4173/invoices");
  assert.equal(o.out, "/tmp/r/invoices__list__head__1440__dark.png");
  assert.deepEqual([o.width, o.theme, o.rows, o.min, o.channel, o.repo], [1440, "dark", "[data-row]", 136, "bundled", "/tmp/wt"]);
});

test("no rows selector means no count to wait for", () => {
  const o = parseShot([...ARGS.slice(0, 5), "-", "0"], ENV);
  assert.equal(o.rows, null);
});

test("anything but a screenshot belongs to the project's own helper", () => {
  assert.throws(() => parseShot(["check", "C1"], ENV), /only takes screenshots/);
});

test("a picture name that could leave the receipt folder is refused", () => {
  assert.throws(() => parseShot([...ARGS.slice(0, 4), "../escape.png", "-", "0"], ENV), /not a picture name/);
});

test("a theme other than light or dark is refused", () => {
  assert.throws(() => parseShot([...ARGS.slice(0, 3), "sepia", ...ARGS.slice(4)], ENV), /light or dark/);
});

test("a page that never loads is a screen not shot, and the browser is still closed", async () => {
  let closed = false;
  const pw = { chromium: { launch: async () => ({
    newContext: async () => ({ newPage: async () => ({
      goto: async () => { throw new Error("page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/invoices\nCall log: ..."); },
    }) }),
    close: async () => { closed = true; },
  }) } };
  const r = await shoot(parseShot(ARGS, ENV), pw);
  assert.equal(r.ok, false);
  assert.match(r.why, /did not load: Error: page\.goto: net::ERR_CONNECTION_REFUSED/);
  assert.equal(closed, true);
});

function rowsPage(waitError) {
  return { chromium: { launch: async () => ({
    newContext: async () => ({ newPage: async () => ({
      goto: async () => ({ ok: () => true, status: () => 200 }),
      waitForFunction: async () => { throw waitError; },
      evaluate: async () => 12,
    }) }),
    close: async () => {},
  }) } };
}

test("a screen short of its row count when the wait runs out is not shot, naming the count", async () => {
  const timeout = Object.assign(new Error("Timeout 30000ms exceeded."), { name: "TimeoutError" });
  const r = await shoot(parseShot(ARGS, ENV), rowsPage(timeout));
  assert.equal(r.ok, false);
  assert.match(r.why, /shows 12 rows matching \[data-row\], and the screen is shot at 136 or more/);
});

test("a row wait that fails for another reason is not reported as too few rows", async () => {
  const bad = new Error("SyntaxError: '[data-row' is not a valid selector");
  await assert.rejects(shoot(parseShot(ARGS, ENV), rowsPage(bad)), /not a valid selector/);
});

test("outside run_session.py drive there is no app to shoot", () => {
  assert.throws(() => parseShot(ARGS, {}), /run_session.py drive/);
});
