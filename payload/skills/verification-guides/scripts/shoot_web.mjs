#!/usr/bin/env node
// shoot_web.mjs: a drive helper that takes one screenshot of a web app (claude-config#2516).
//
//   node shoot_web.mjs screenshot <path> <width> <light|dark> <file.png> <rows selector or -> <min rows>
//
// The contract screenshots.py shoot calls every project's drive helper with, through
// run_session.py drive, so the call is logged and runs under the run's egress sandbox. It opens
// VERIFICATION_URL + <path> in a headless browser at <width> by 900, in the colour scheme named,
// waits until at least <min rows> elements match <rows selector> when one is given (the screen is
// shot at the production count, L606, or not at all), and saves a full page picture as <file.png>
// in VERIFICATION_RECEIPT_DIR. Any other first argument exits 2: a project whose drive helper also
// drives its checks dispatches `screenshot` here and handles the rest itself.
//
// The browser is the design match score's (capture-web.mjs): the app's own Playwright, then
// DESIGN_SCORE_PLAYWRIGHT, then the shared install, launched with the same deterministic
// rasterisation, so two shots of an unchanged screen are the same pixels and an unchanged pair reads
// as no visible change. SHOOT_WEB_CHANNEL picks the browser: bundled (Playwright's own Chromium, the
// default, which never starts a Google Chrome) or chrome (the hidden Chrome build). Never the
// Playwright MCP browser, which belongs to the main session.
//
// Exit codes: 0 saved, 1 the screen did not reach its row count or did not load, 2 usage or no browser.
import { mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { findPlaywright, loadPlaywright, launchChrome, LAUNCH_ARGS, settle } from "../../design-rounds/score/capture-web.mjs";

const HEIGHT = 900;
const READY_TIMEOUT_MS = 30_000;
const FILE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.png$/;

export function parseShot(argv, env = process.env) {
  const [verb, path, width, theme, file, rows, minRows] = argv;
  if (verb !== "screenshot") throw new Error(`shoot_web.mjs only takes screenshots; ${verb ?? "nothing"} is for the project's own drive helper`);
  if (argv.length !== 7) throw new Error("usage: shoot_web.mjs screenshot <path> <width> <light|dark> <file.png> <rows selector or -> <min rows>");
  if (!path.startsWith("/")) throw new Error(`the path ${path} must start with /`);
  const w = Number(width);
  if (!Number.isInteger(w) || w < 320) throw new Error(`the width ${width} is not a whole number of pixels`);
  if (theme !== "light" && theme !== "dark") throw new Error(`the theme is light or dark, not ${theme}`);
  if (!FILE_RE.test(file)) throw new Error(`${file} is not a picture name this run can keep`);
  const min = Number(minRows);
  if (!Number.isInteger(min) || min < 0) throw new Error(`the minimum row count ${minRows} is not a whole number`);
  if (!env.VERIFICATION_URL || !env.VERIFICATION_RECEIPT_DIR) throw new Error("VERIFICATION_URL and VERIFICATION_RECEIPT_DIR are unset: run this through run_session.py drive");
  const channel = env.SHOOT_WEB_CHANNEL || "bundled";
  if (channel !== "bundled" && channel !== "chrome") throw new Error("SHOOT_WEB_CHANNEL is bundled or chrome");
  return { url: env.VERIFICATION_URL.replace(/\/$/, "") + path, width: w, theme, out: join(env.VERIFICATION_RECEIPT_DIR, file),
    rows: rows === "-" ? null : rows, min, channel, repo: env.VERIFICATION_WORKTREE || process.cwd() };
}

export async function shoot(o, pw) {
  const browser = await launchChrome(pw, o.channel, LAUNCH_ARGS);
  try {
    const context = await browser.newContext({ viewport: { width: o.width, height: HEIGHT }, colorScheme: o.theme, deviceScaleFactor: 1 });
    const page = await context.newPage();
    let res;
    try {
      res = await page.goto(o.url, { waitUntil: "load", timeout: READY_TIMEOUT_MS });
    } catch (e) {
      // A refused connection or a load past the timeout is the screen not loading (exit 1), not a usage fault.
      return { ok: false, why: `${o.url} did not load: ${String(e).split("\n")[0]}` };
    }
    if (!res || !res.ok()) return { ok: false, why: `${o.url} answered ${res ? res.status() : "nothing"}` };
    if (o.rows) {
      try {
        await page.waitForFunction(([sel, n]) => document.querySelectorAll(sel).length >= n, [o.rows, o.min], { timeout: READY_TIMEOUT_MS });
      } catch {
        const n = await page.evaluate((sel) => document.querySelectorAll(sel).length, o.rows);
        return { ok: false, why: `${o.url} shows ${n} rows matching ${o.rows}, and the screen is shot at ${o.min} or more` };
      }
    }
    await settle(page, o.width);
    mkdirSync(dirname(o.out), { recursive: true });
    await page.screenshot({ path: o.out, fullPage: true, animations: "disabled" });
    return { ok: true };
  } finally {
    await browser.close();
  }
}

async function main() {
  let o;
  try { o = parseShot(process.argv.slice(2)); } catch (e) { console.error(`shoot_web: ${e.message}`); return 2; }
  let pw;
  try { pw = loadPlaywright(findPlaywright({ repo: o.repo })); } catch (e) { console.error(`shoot_web: ${e.message}`); return 2; }
  const r = await shoot(o, pw);
  if (!r.ok) { console.error(`shoot_web: not shot: ${r.why}`); return 1; }
  console.log(`shoot_web: saved ${o.out}`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url).endsWith(process.argv[1].split("/").pop()) &&
    process.argv[1].endsWith("shoot_web.mjs")) {
  main().then((code) => process.exit(code), (e) => { console.error(`shoot_web: ${String(e)}`); process.exit(2); });
}
