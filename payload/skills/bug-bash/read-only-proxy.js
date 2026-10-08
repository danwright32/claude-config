#!/usr/bin/env node
// read-only-proxy.js: the guard a read only bug bash runs behind (claude-config#813).
//
//   node ~/.claude/skills/bug-bash/read-only-proxy.js --state <dir>
//
// A read only run looks at a deployment with real users. Blocking writes inside the browser (the
// route explorer-browser.js sets) covers only the context it hands back: a browser an explorer
// launches for itself, a second context, and every WebSocket message pass it by (lessons review of
// PR #798, L27). So the rule is also enforced here, outside the browser: a local proxy that
// explorer-browser.js launches every read only browser through, which forwards a request only when
// it reads. That covers every context and every socket of such a browser. A browser launched some
// other way never meets this proxy; against a deployment the egress rule covers it (egress.sh):
// started with --egress, in the _bugbash group, this proxy is the one process that rule lets
// through to the site, and it takes the rule away as it stops.
//
// What it forwards: GET, HEAD and OPTIONS (the CORS preflight a cross origin read needs), the one
// list explorer-browser.js reads by. What it refuses, without a byte reaching the site: every other
// method (405), and every WebSocket or other protocol upgrade (403), since a socket's messages are
// not requests and cannot be judged one by one. It refuses them to every host, the target's and any
// third party's alike.
//
// HTTPS is judged too: a CONNECT tunnel is opened onto this proxy's own TLS, with a certificate for
// that host signed by a certificate authority made for this run (openssl, in <dir>/certs), so the
// method inside is seen. The browser is launched to accept it. Upstream, the real site's
// certificate is verified as usual. A tunnel whose certificate cannot be made is refused, never
// passed through blind.
//
// Once listening it writes <dir>/proxy.json: { "proxy": "http://127.0.0.1:<port>", "pid", "ca" }.
// GET <proxy>/__bug-bash-proxy__/health answers { "proxy": "bug-bash-read-only", "pid", "egid",
// "egress" }, which is how target-guard.sh and explorer-browser.js know it is this proxy that is up,
// and how the guard knows which process the egress rule is for and which group it must let through. Every request is logged,
// one line each, to <dir>/requests.log as `<verdict> <method> <origin><path>`, the query string and
// fragment left out (they can carry tokens, L741).
//
// It runs until stopped: whoever starts it stops it when the run ends (kill the pid in proxy.json).
// proxy.json exists only while the proxy does: a stale one is removed before it starts, and its own
// is removed as it stops, so the file never names a dead process. A site that has not answered
// within the upstream deadline (--upstream-timeout-ms, 30 s by default) is answered 504, and an
// upstream request is dropped when the browser that asked for it goes away (L110).

'use strict'
const http = require('http')
const https = require('https')
const tls = require('tls')
const net = require('net')
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { execFile, execFileSync } = require('child_process')
// The read predicate, the health path and its answer are the launcher's, so the two cannot drift.
const { isRead, MARK, HEALTH, proxyAnswers } = require('./explorer-browser.js')

// Headers that describe one connection, never forwarded across the proxy.
const HOP = new Set(['connection', 'keep-alive', 'proxy-connection', 'proxy-authorization', 'proxy-authenticate', 'te', 'trailer', 'transfer-encoding', 'upgrade'])

function argOf(name) {
  const i = process.argv.indexOf(name)
  return i > 0 ? process.argv[i + 1] : undefined
}
// Started for a run against a deployment: the guard loads the egress rule for this process, and
// this process takes it away as it stops.
const EGRESS = process.argv.includes('--egress')
const stateDir = argOf('--state')
if (!stateDir) {
  console.error('read-only-proxy: give --state <dir>, where proxy.json, the certificates and requests.log go.')
  process.exit(2)
}
fs.mkdirSync(path.join(stateDir, 'certs'), { recursive: true })
const certDir = path.join(stateDir, 'certs')
const stateFile = path.join(stateDir, 'proxy.json')
let wroteState = false
const removeState = () => {
  try {
    fs.rmSync(stateFile, { force: true })
  } catch (e) {
    console.error(`read-only-proxy: could not remove ${stateFile}: ${e.message}`)
  }
}
// A proxy.json naming a proxy that is still up means this directory is in use: refuse rather than
// take its address away. Up means its pid is alive AND its address answers as this proxy, since a
// pid can be handed to another process once its proxy is gone. Anything else is left from an
// earlier run, and is removed.
async function claimStateDir() {
  let prior
  try {
    prior = JSON.parse(fs.readFileSync(stateFile, 'utf8'))
  } catch {
    // No proxy.json, or one that cannot be read: it names nothing that is up.
  }
  const pid = prior && prior.pid
  if (Number.isInteger(pid) && pid > 0 && pid !== process.pid && typeof prior.proxy === 'string') {
    let alive = false
    try {
      process.kill(pid, 0)
      alive = true
    } catch (e) {
      alive = e.code === 'EPERM'
    }
    const answers = alive && (await proxyAnswers(prior.proxy, 2000).then(() => true, () => false))
    if (answers) {
      console.error(`read-only-proxy: a proxy is already running for ${stateDir} (pid ${pid}, ${prior.proxy}); stop it or use another --state directory.`)
      process.exit(3)
    }
  }
  removeState()
}
// Certificates outlive any run: a run that went on past them would fail every https tunnel.
const CERT_DAYS = '30'
const UPSTREAM_MS = Number(argOf('--upstream-timeout-ms') || 30_000)
if (!Number.isFinite(UPSTREAM_MS) || UPSTREAM_MS <= 0) {
  console.error('read-only-proxy: --upstream-timeout-ms takes a positive number of milliseconds.')
  process.exit(2)
}
const logFile = path.join(stateDir, 'requests.log')

const log = (verdict, method, origin, rawPath) => {
  const p = String(rawPath || '/').split(/[?#]/)[0]
  try {
    fs.appendFileSync(logFile, `${verdict} ${method} ${origin}${p}\n`)
  } catch (e) {
    console.error(`read-only-proxy: could not write ${logFile}: ${e.message}`)
  }
}

const run = (args) =>
  new Promise((resolve, reject) =>
    execFile('openssl', args, { cwd: certDir }, (err, _out, stderr) => (err ? reject(new Error(`openssl ${args[0]}: ${stderr || err.message}`)) : resolve())),
  )

// The run's certificate authority and the one key every host's certificate shares.
async function makeAuthority() {
  await run(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', CERT_DAYS, '-subj', '/CN=bug bash read only proxy', '-keyout', 'ca.key', '-out', 'ca.pem'])
  await run(['genrsa', '-out', 'leaf.key', '2048'])
}
const contexts = new Map()
// A host name, or an IP literal, safe to put in a file name and a subjectAltName.
const safeHost = h => /^[A-Za-z0-9.:-]+$/.test(h) && h.length <= 253
function contextFor(host) {
  if (!contexts.has(host)) {
    const made = (async () => {
      if (!safeHost(host)) throw new Error(`a host name it will not put in a certificate: ${JSON.stringify(host)}`)
      const base = crypto.createHash('sha256').update(host).digest('hex').slice(0, 16)
      const san = net.isIP(host) ? `IP:${host}` : `DNS:${host}`
      fs.writeFileSync(path.join(certDir, `${base}.ext`), `subjectAltName=${san}\nextendedKeyUsage=serverAuth\n`)
      await run(['req', '-new', '-key', 'leaf.key', '-subj', `/CN=${host.slice(0, 64)}`, '-out', `${base}.csr`])
      await run(['x509', '-req', '-in', `${base}.csr`, '-CA', 'ca.pem', '-CAkey', 'ca.key', '-set_serial', `0x${crypto.randomBytes(8).toString('hex')}`, '-days', CERT_DAYS, '-extfile', `${base}.ext`, '-out', `${base}.pem`])
      return tls.createSecureContext({ key: fs.readFileSync(path.join(certDir, 'leaf.key')), cert: fs.readFileSync(path.join(certDir, `${base}.pem`)) })
    })()
    // A failure is not cached: the next tunnel to that host tries again.
    made.catch(() => contexts.delete(host))
    contexts.set(host, made)
  }
  return contexts.get(host)
}

const refuse = (res, code, why) => {
  res.writeHead(code, { 'content-type': 'text/plain; charset=utf-8', 'x-bug-bash-proxy': 'refused', connection: 'close' })
  res.end(`Refused by the bug bash read only proxy: ${why}\n`)
}

const originOf = t => `${t.scheme}://${net.isIPv6(t.host) ? `[${t.host}]` : t.host}${t.port === (t.scheme === 'https' ? 443 : 80) ? '' : `:${t.port}`}`

// One request, already known to be bound for `target` (scheme, host, port) at `reqPath`.
function forward(req, res, target, reqPath) {
  const origin = originOf(target)
  if (!isRead(req.method)) {
    log('REFUSED', req.method, origin, reqPath)
    req.resume()
    return refuse(res, 405, `${req.method} could change something, and this run only reads.`)
  }
  log('FORWARDED', req.method, origin, reqPath)
  const headers = {}
  for (const [k, v] of Object.entries(req.headers)) if (!HOP.has(k.toLowerCase())) headers[k] = v
  const lib = target.scheme === 'https' ? https : http
  const up = lib.request({ host: target.host, port: target.port, method: req.method, path: reqPath, headers, servername: net.isIP(target.host) ? undefined : target.host }, upRes => {
    const out = {}
    for (const [k, v] of Object.entries(upRes.headers)) if (!HOP.has(k.toLowerCase())) out[k] = v
    res.writeHead(upRes.statusCode || 502, out)
    // A site that drops the answer part way ends the browser's request too, never leaves it open.
    upRes.on('aborted', () => res.destroy())
    upRes.on('error', () => res.destroy())
    upRes.pipe(res)
  })
  let timedOut = false
  up.setTimeout(UPSTREAM_MS, () => {
    timedOut = true
    up.destroy(new Error(`no answer within ${UPSTREAM_MS} ms`))
  })
  up.on('error', e => {
    if (!res.headersSent && !res.destroyed) {
      res.writeHead(timedOut ? 504 : 502, { 'content-type': 'text/plain; charset=utf-8', 'x-bug-bash-proxy': 'upstream-error' })
      res.end(`The bug bash read only proxy could not reach ${origin}: ${e.message}\n`)
    } else res.destroy()
  })
  // The browser went away before the answer finished: nothing is waiting for the rest of it.
  res.on('close', () => {
    if (!res.writableFinished) up.destroy()
  })
  req.pipe(up)
}

// An upgrade is refused whatever its method: once switched, the socket's messages are not requests.
const refuseUpgrade = (req, socket, origin) => {
  // Once a request upgrades, Node stops handling its socket's errors: a client that resets as it
  // is refused would otherwise take the whole proxy down.
  socket.on('error', () => {})
  log('REFUSED', `${req.method} upgrade:${String(req.headers.upgrade || '')}`, origin, req.url)
  socket.end(`HTTP/1.1 403 Forbidden\r\nx-bug-bash-proxy: refused\r\ncontent-type: text/plain\r\nconnection: close\r\n\r\nRefused by the bug bash read only proxy: a ${req.headers.upgrade || 'protocol'} upgrade carries messages it cannot judge.\n`)
}

// Requests arriving inside a CONNECT tunnel, the tunnel's target on the socket.
const tunnelled = http.createServer((req, res) => forward(req, res, req.socket.bugBashTarget, req.url))
tunnelled.on('upgrade', (req, socket) => {
  const t = socket.bugBashTarget
  refuseUpgrade(req, socket, originOf(t))
})
tunnelled.on('clientError', (_e, socket) => socket.destroy())

const server = http.createServer((req, res) => {
  if (req.url === HEALTH) {
    res.writeHead(200, { 'content-type': 'application/json' })
    return res.end(JSON.stringify({ proxy: MARK, pid: process.pid, egid: process.getegid(), egress: EGRESS }))
  }
  let u
  try {
    u = new URL(req.url)
  } catch {
    return refuse(res, 400, 'it is a proxy: send it absolute URLs.')
  }
  if (u.protocol !== 'http:') return refuse(res, 400, `it forwards http:// requests directly and https:// through CONNECT, not ${u.protocol}`)
  forward(req, res, { scheme: 'http', host: u.hostname.replace(/^\[|\]$/g, ''), port: Number(u.port || 80) }, `${u.pathname}${u.search}`)
})
// A plain upgrade names its absolute URL as its path, so the origin is left empty.
server.on('upgrade', (req, socket) => refuseUpgrade(req, socket, ''))
server.on('clientError', (_e, socket) => socket.destroy())

server.on('connect', (req, client, head) => {
  // Handled before anything is written, so a client resetting during any reply cannot crash it.
  client.on('error', () => {})
  const m = /^\[?([^\]]+?)\]?:(\d+)$/.exec(req.url || '')
  if (!m) {
    log('REFUSED', 'CONNECT', String(req.url), '')
    return client.end('HTTP/1.1 400 Bad Request\r\nx-bug-bash-proxy: refused\r\n\r\n')
  }
  const host = m[1]
  const port = Number(m[2])
  client.write('HTTP/1.1 200 Connection Established\r\n\r\n')
  if (head && head.length) client.unshift(head)
  // The first byte says what the tunnel carries: 0x16 opens a TLS handshake; anything else is
  // plain HTTP (a ws:// socket or an http:// request tunnelled), judged just the same.
  // A tunnel that is opened and then sent nothing is closed after the same deadline as an upstream.
  client.setTimeout(UPSTREAM_MS, () => client.destroy())
  client.once('data', first => {
    client.setTimeout(0)
    client.pause()
    client.unshift(first)
    if (first[0] !== 0x16) {
      client.bugBashTarget = { scheme: 'http', host, port }
      tunnelled.emit('connection', client)
      client.resume()
      return
    }
    contextFor(host).then(
      secureContext => {
        const secure = new tls.TLSSocket(client, { isServer: true, secureContext })
        secure.on('error', () => client.destroy())
        secure.bugBashTarget = { scheme: 'https', host, port }
        tunnelled.emit('connection', secure)
        client.resume()
      },
      e => {
        // No certificate, no tunnel: never passed through unjudged.
        log('REFUSED', 'CONNECT', `https://${host}:${port}`, `/ (${e.message.split('\n')[0]})`)
        client.destroy()
      },
    )
  })
})

claimStateDir().then(makeAuthority).then(
  () =>
    server.listen(Number(argOf('--port') || 0), '127.0.0.1', () => {
      const { port } = server.address()
      const state = { proxy: `http://127.0.0.1:${port}`, pid: process.pid, ca: path.join(certDir, 'ca.pem') }
      fs.writeFileSync(`${stateFile}.tmp`, JSON.stringify(state) + '\n')
      fs.renameSync(`${stateFile}.tmp`, stateFile)
      wroteState = true
      console.log(`read-only-proxy: listening on ${state.proxy}`)
    }),
  e => {
    console.error(`read-only-proxy: could not make the run's certificate authority, so it will not start: ${e.message}`)
    process.exit(1)
  },
)
process.on('exit', () => {
  if (wroteState) removeState()
  // The egress rule loaded for this process goes with it. Scoped to this pid, so a rule another run
  // holds is left alone; a failure is said, since the rule would go on refusing the site.
  if (EGRESS) {
    try {
      execFileSync('bash', [path.join(__dirname, 'egress.sh'), 'unload', String(process.pid)], { stdio: ['ignore', 'ignore', 'pipe'], timeout: 20_000 })
    } catch (e) {
      const why = (e.stderr && String(e.stderr).trim()) || e.message
      console.error(`read-only-proxy: could not take the egress rule away (${why}). Remove it with: bash ~/.claude/skills/bug-bash/egress.sh unload`)
    }
  }
})
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => process.exit(0))
