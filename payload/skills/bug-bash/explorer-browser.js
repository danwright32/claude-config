// explorer-browser.js: the one way a bug bash explorer starts its browser (claude-config#719).
//
//   const { launch } = require(`${process.env.HOME}/.claude/skills/bug-bash/explorer-browser.js`)
//   const { chromium } = require('<project>/node_modules/playwright')
//   const { context, close } = await launch({ chromium, readOnly })
//   const page = await context.newPage()
//
// A headless browser of the explorer's own, from the project's own Playwright install, with a
// context of its own so no two explorers share cookies (measured 2026-10-05: four at once, 1.2 to
// 1.5 s, isolated). In a read only run, against a deployment with real users, the context aborts
// every HTTP request that could change something and blocks service workers, so read only is
// enforced in the browser rather than asked for in a prompt (lessons review of #798, L27): a form an
// explorer submits there goes nowhere. It is not a sealed box: messages over a WebSocket the page
// opens are not intercepted, and a script that starts its own browser rather than this one bypasses
// all of it, which is why the skill has every explorer start through here.
//
// It refuses, by throwing, when no Playwright browser type is handed in, rather than finding one on
// its own: which install is used is the project's, and a guessed one is a different browser.

const READS = new Set(['GET', 'HEAD', 'OPTIONS'])
/** Whether a request method only reads. */
const isRead = method => READS.has(String(method).toUpperCase())

async function launch({ chromium, readOnly = false, headless = true } = {}) {
  if (!chromium || typeof chromium.launch !== 'function') {
    throw new Error("explorer-browser: hand in the project's own Playwright browser type: launch({ chromium: require('<project>/node_modules/playwright').chromium, readOnly })")
  }
  const browser = await chromium.launch({ headless })
  // A service worker's requests do not pass through context.route, so a read only context has none.
  const context = await browser.newContext(readOnly ? { serviceWorkers: 'block' } : {})
  if (readOnly) {
    await context.route('**/*', route => (isRead(route.request().method()) ? route.continue() : route.abort()))
  }
  // The browser itself is not handed back, so no explorer can make a second context without the
  // read only route; close() is all it needs of it.
  return { context, close: () => browser.close() }
}

module.exports = { launch, isRead }
