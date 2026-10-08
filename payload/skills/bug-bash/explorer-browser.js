// explorer-browser.js: the one way a bug bash explorer starts its browser (claude-config#719).
//
//   const { launch } = require(`${process.env.HOME}/.claude/skills/bug-bash/explorer-browser.js`)
//   const { chromium } = require('<project>/node_modules/playwright')
//   const { context, close } = await launch({ chromium, readOnly })
//   const page = await context.newPage()
//
// A headless browser of the explorer's own, from the project's own Playwright install, with a
// context of its own so no two explorers share cookies (measured 2026-10-05: four at once, 1.2 to
// 1.5 s, isolated).
//
// A read only run, against a deployment with real users, is held to reading in two places. The one
// that decides is outside the browser (#813): read-only-proxy.js, which this launches every read
// only browser through (BUG_BASH_PROXY, or `proxy`), refuses every request that is not a read and
// every WebSocket, before a byte reaches the site, and this refuses to launch at all unless that
// proxy answers as itself. Loopback hosts go through it too, which Chromium would otherwise skip.
// Inside the browser, as before, the context aborts every request that is not a read and blocks
// service workers (lessons review of #798, L27), so a write is stopped before it leaves. The proxy
// signs its own certificate for each https host to see the method inside, so a read only context
// accepts certificates it cannot verify; the proxy verifies the real site's.
//
// It refuses, by throwing, when no Playwright browser type is handed in, rather than finding one on
// its own: which install is used is the project's, and a guessed one is a different browser.

const http = require('http')

const READS = new Set(['GET', 'HEAD', 'OPTIONS'])
/** Whether a request method only reads: the one list the browser's route and the proxy share. */
const isRead = method => READS.has(String(method).toUpperCase())

const HEALTH = '/__bug-bash-proxy__/health'
const MARK = 'bug-bash-read-only'
/**
 * Resolves with the proxy's health answer ({ proxy, pid, egid, egress }) when `proxy` is the bug
 * bash read only proxy and answering; rejects naming why not.
 */
function proxyAnswers(proxy, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    let url
    try {
      url = new URL(HEALTH, proxy)
    } catch {
      return reject(new Error(`explorer-browser: ${proxy} is not a proxy URL; give the "proxy" value from the read only proxy's proxy.json.`))
    }
    if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) {
      return reject(new Error(`explorer-browser: ${proxy} is not a local http proxy; the read only proxy listens on 127.0.0.1.`))
    }
    const req = http.get(url, res => {
      let body = ''
      res.setEncoding('utf8')
      res.on('data', c => (body += c))
      res.on('end', () => {
        let said
        try {
          said = JSON.parse(body)
        } catch {}
        if (res.statusCode === 200 && said && said.proxy === MARK) resolve(said)
        else reject(new Error(`explorer-browser: ${proxy} answered, but not as the bug bash read only proxy (HTTP ${res.statusCode}). Start read-only-proxy.js and use its address.`))
      })
    })
    req.setTimeout(timeoutMs, () => req.destroy(new Error(`no answer within ${timeoutMs} ms`)))
    req.on('error', e => reject(new Error(`explorer-browser: the read only proxy at ${proxy} is not answering (${e.message}). Start read-only-proxy.js first.`)))
  })
}

async function launch({ chromium, readOnly = false, headless = true, proxy = process.env.BUG_BASH_PROXY } = {}) {
  if (!chromium || typeof chromium.launch !== 'function') {
    throw new Error("explorer-browser: hand in the project's own Playwright browser type: launch({ chromium: require('<project>/node_modules/playwright').chromium, readOnly })")
  }
  if (readOnly) {
    if (!proxy) {
      throw new Error('explorer-browser: a read only run goes through the read only proxy, and none was given. Start read-only-proxy.js and set BUG_BASH_PROXY to its address.')
    }
    await proxyAnswers(proxy)
  }
  // <-loopback> takes back Chromium's own exception for this machine, so a read only run against a
  // local build is proxied too.
  const browser = await chromium.launch(readOnly ? { headless, proxy: { server: proxy }, args: ['--proxy-bypass-list=<-loopback>'] } : { headless })
  let context
  try {
    // A service worker's requests do not pass through context.route, so a read only context has none.
    context = await browser.newContext(readOnly ? { serviceWorkers: 'block', ignoreHTTPSErrors: true } : {})
    if (readOnly) {
      await context.route('**/*', route => (isRead(route.request().method()) ? route.continue() : route.abort()))
    }
  } catch (e) {
    // A browser whose setup failed is closed, never left running with no way to reach it.
    await browser.close().catch(() => {})
    throw e
  }
  // The browser itself is not handed back, since close() is all an explorer needs of it. A context
  // made beside this one has no route, but its browser still goes through the proxy. A browser
  // launched any other way never meets the proxy: against a deployment the egress rule (egress.sh)
  // refuses it the site, and the skill still has every explorer launch here.
  return { context, close: () => browser.close() }
}

module.exports = { launch, isRead, proxyAnswers, MARK, HEALTH }
