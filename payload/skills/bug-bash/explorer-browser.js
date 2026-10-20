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

// Errors that say THIS MAC could not open a connection (out of local ports, as on 2026-10-19 at a
// load average of 71, or out of file handles), not that nothing listens there (#1370). A refused
// connection (ECONNREFUSED) is not one of them: that is a proxy that is not up.
const LOCAL_CONNECT_ERRORS = new Set(['EADDRNOTAVAIL', 'EADDRINUSE', 'EMFILE', 'ENFILE', 'ENOBUFS', 'EAGAIN'])
/** Whether a connection error came from this Mac's own shortage rather than from the far end. */
const isLocalConnectError = e => !!e && LOCAL_CONNECT_ERRORS.has(e.code)
// A local shortage often clears in a moment, so a check meeting one is tried again after each of
// these waits before it gives up. The wait goes through module.exports.sleep, which the tests
// replace so they never wait for real (L524).
const RETRY_DELAYS_MS = [100, 400, 1600]
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
async function retryLocal(attempt) {
  for (let i = 0; ; i++) {
    try {
      return await attempt()
    } catch (e) {
      if (!e.local || i >= RETRY_DELAYS_MS.length) throw e
      await module.exports.sleep(RETRY_DELAYS_MS[i])
    }
  }
}
// The refusal for a check this Mac could not make: marked local, so a caller tells it apart from a
// proxy that is missing, and worded so nobody is sent to start a proxy that may well be running.
const localError = (proxy, e) =>
  Object.assign(
    new Error(`explorer-browser: could not check the read only proxy at ${proxy}: this Mac could not open a connection to it (${e.message}), so whether it is up was not judged. The Mac is out of local ports or file handles, usually from many test runs at once; try again when it is less busy, without restarting the proxy.`),
    { local: true, code: e.code }
  )
// The proxy's address, refused unless it is a local http one (the one rule the guard shares, L263).
function proxyUrl(proxy, pathname) {
  let url
  try {
    url = new URL(pathname, proxy)
  } catch {
    throw new Error(`explorer-browser: ${proxy} is not a proxy URL; give the "proxy" value from the read only proxy's proxy.json.`)
  }
  if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) {
    throw new Error(`explorer-browser: ${proxy} is not a local http proxy; the read only proxy listens on 127.0.0.1.`)
  }
  return url
}

/**
 * Resolves with the proxy's health answer ({ proxy, pid, egid, egress }) when `proxy` is the bug
 * bash read only proxy and answering; rejects naming why not. A rejection because this Mac could
 * not open the connection at all, after the retries, carries `local: true`.
 */
function proxyAnswers(proxy, timeoutMs = 3000) {
  let url
  try {
    url = proxyUrl(proxy, HEALTH)
  } catch (e) {
    return Promise.reject(e)
  }
  return retryLocal(() => healthOnce(proxy, url, timeoutMs))
}
function healthOnce(proxy, url, timeoutMs) {
  return new Promise((resolve, reject) => {
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
    req.on('error', e =>
      reject(isLocalConnectError(e) ? localError(proxy, e) : new Error(`explorer-browser: the read only proxy at ${proxy} is not answering (${e.message}). Start read-only-proxy.js first.`))
    )
  })
}

/**
 * Whether the proxy refuses a write sent through it: a POST to a name that resolves nowhere
 * (.invalid), so a proxy that forwarded it would reach nothing. Resolves true only for the proxy's
 * own refusal (405, x-bug-bash-proxy: refused), false for any other answer or none. Like
 * proxyAnswers, a rejection because this Mac could not open the connection carries `local: true`.
 */
function proxyRefusesWrite(proxy, timeoutMs = 5000) {
  let url
  try {
    url = proxyUrl(proxy, '/')
  } catch (e) {
    return Promise.reject(e)
  }
  return retryLocal(
    () =>
      new Promise((resolve, reject) => {
        const req = http.request(
          { host: url.hostname.replace(/^\[|\]$/g, ''), port: url.port || 80, method: 'POST', path: 'http://bug-bash-probe.invalid/write', headers: { host: 'bug-bash-probe.invalid', 'content-type': 'text/plain' } },
          res => {
            res.resume()
            resolve(res.statusCode === 405 && res.headers['x-bug-bash-proxy'] === 'refused')
          }
        )
        req.setTimeout(timeoutMs, () => req.destroy(new Error(`no answer within ${timeoutMs} ms`)))
        req.on('error', e => (isLocalConnectError(e) ? reject(localError(proxy, e)) : resolve(false)))
        req.end('probe')
      })
  )
}

/**
 * What target-guard.sh needs to know of a proxy before a read only run, asked in one place: its
 * health answer and whether it refuses a write. Rejects as the two checks do.
 */
async function checkProxy(proxy) {
  const said = await proxyAnswers(proxy)
  return { pid: said.pid, egid: said.egid, egress: said.egress, refusesWrite: await proxyRefusesWrite(proxy) }
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

module.exports = { launch, isRead, proxyAnswers, proxyRefusesWrite, checkProxy, isLocalConnectError, sleep, MARK, HEALTH }
