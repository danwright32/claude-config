#!/usr/bin/env bash
# Tests for the bug-bash skill's two helpers (claude-config#719):
#
#   target-guard.sh  decides whether a bug bash may run against a URL at all: a local production
#                    build only, a deployment only when read only is asked for, never a dev server.
#   read-only-proxy.js holds a read only run to reading outside any browser (#813).
#   report.py        builds what Dan reads from the run's findings file, and refuses to call a
#                    finding a bug unless a test failed for the reason the explorer gave.
#
# The guard is driven against a throwaway local HTTP server serving fixture pages, so nothing here
# reaches a real site. Refusals of a remote URL happen before any request is made, and a fake curl
# on PATH proves it.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$DIR/target-guard.sh"
REPORT="$DIR/report.py"
TMP="$(mktemp -d)"
SERVER_PID=""
# Every other process the suite starts in the background, stopped with it.
BG_PIDS=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; for p in $BG_PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '  output: %s\n' "$2"; return 0; }
expect() { # expect <description> <want rc> <want words> <got rc> <got output>
  if [ "$4" -eq "$2" ] && grep -qi -- "$3" <<< "$5"; then ok; else bad "$1 (want rc $2, got $4)" "$5"; fi
}

# ---------------------------------------------------------------- read-only-proxy.js
# A read only run is held to reading outside the browser (#813): a local proxy every explorer
# browser goes through refuses every request that could change something, and every WebSocket,
# before it reaches the site. Tested against fixture sites that record every request they receive,
# one over http and one over https, so a write that got through is seen where it would land. Nothing
# here reaches a real site: the fixtures are on this machine, and the guard's probe goes to a name
# that resolves nowhere.
PROXY_JS="$DIR/read-only-proxy.js"
cat > "$TMP/recorder.py" <<'PY'
import http.server, socketserver, sys, os, ssl, time
log, port_file = sys.argv[1], sys.argv[2]
cert = sys.argv[3] if len(sys.argv) > 3 else None
class Recorder(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a, **k):
        pass
    # Every request is recorded before it is answered: method, path, and whether it asked to upgrade.
    def any(self):
        n = int(self.headers.get('content-length') or 0)
        if n:
            self.rfile.read(n)
        if self.path == '/stall':
            time.sleep(60)
            return
        # An answer cut off part way: it promises 100 bytes, sends 5 and closes.
        if self.path == '/cut':
            self.send_response(200)
            self.send_header('content-length', '100')
            self.end_headers()
            self.wfile.write(b'start')
            self.wfile.flush()
            return
        # A slow answer, a byte at a time: it records when its reader went away, which is when a
        # write to the socket fails.
        if self.path == '/drip':
            self.send_response(200)
            self.end_headers()
            try:
                for _ in range(200):
                    self.wfile.write(b'.')
                    self.wfile.flush()
                    time.sleep(0.1)
            except OSError:
                with open(log + '.dropped', 'a') as f:
                    f.write('DROPPED /drip\n')
            return
        with open(log, 'a') as f:
            f.write('%s %s%s\n' % (self.command, self.path, ' upgrade' if self.headers.get('upgrade') else ''))
        body = b'fixture ok\n'
        self.send_response(200)
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)
    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = any
class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
httpd = Server(('127.0.0.1', 0), Recorder)
if cert:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, cert)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
with open(port_file + '.tmp', 'w') as f:
    f.write(str(httpd.server_address[1]))
os.rename(port_file + '.tmp', port_file)
httpd.serve_forever()
PY
# A stand in that answers the proxy's health check as the proxy does, but forwards every write.
cat > "$TMP/impostor.py" <<'PY'
import http.server, socketserver, sys, os
port_file = sys.argv[1]
class Impostor(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a, **k):
        pass
    def any(self):
        body = b'{"proxy":"bug-bash-read-only"}' if self.path.endswith('/__bug-bash-proxy__/health') else b'forwarded\n'
        self.send_response(200)
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = do_POST = any
httpd = socketserver.TCPServer(('127.0.0.1', 0), Impostor)
with open(port_file + '.tmp', 'w') as f:
    f.write(str(httpd.server_address[1]))
os.rename(port_file + '.tmp', port_file)
httpd.serve_forever()
PY
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost \
  -keyout "$TMP/site.key" -out "$TMP/site.crt" >/dev/null 2>&1
cat "$TMP/site.key" "$TMP/site.crt" > "$TMP/site.pem"
python3 "$TMP/recorder.py" "$TMP/plain.log" "$TMP/plain.port" & BG_PIDS="$BG_PIDS $!"
python3 "$TMP/recorder.py" "$TMP/tls.log" "$TMP/tls.port" "$TMP/site.pem" & BG_PIDS="$BG_PIDS $!"
python3 "$TMP/impostor.py" "$TMP/impostor.port" & BG_PIDS="$BG_PIDS $!"
# The proxy verifies the real site's certificate as usual; here the fixture's is made trusted the
# way Node itself offers, so no switch in the proxy turns verification off.
# A stale proxy.json from an earlier run in the same directory, which the proxy must not leave
# standing for a reader to take as its own.
mkdir -p "$TMP/proxy"
# Its pid is a process that has already exited, as a left over file's would be.
sh -c 'exit 0' & DEAD_PID=$!
wait "$DEAD_PID"
kill -0 "$DEAD_PID" 2>/dev/null && bad "the stand in for an exited process is really gone (pid $DEAD_PID was reused)"
printf '{"proxy":"http://127.0.0.1:1","pid":%s}\n' "$DEAD_PID" > "$TMP/proxy/proxy.json"
# The upstream deadline is shortened so a stalled site is seen to time out within the suite.
NODE_EXTRA_CA_CERTS="$TMP/site.crt" node "$PROXY_JS" --state "$TMP/proxy" --upstream-timeout-ms 1000 >"$TMP/proxy.out" 2>&1 & PROXY_PID=$!
BG_PIDS="$BG_PIDS $PROXY_PID"
for _ in $(seq 1 400); do
  [ -s "$TMP/plain.port" ] && [ -s "$TMP/tls.port" ] && [ -s "$TMP/impostor.port" ] && grep -q "\"pid\":$PROXY_PID" "$TMP/proxy/proxy.json" 2>/dev/null && break
  sleep 0.05
done
PROXY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["proxy"])' "$TMP/proxy/proxy.json" 2>/dev/null)"
PROXY_CA="$TMP/proxy/certs/ca.pem"
PLAIN="http://127.0.0.1:$(cat "$TMP/plain.port" 2>/dev/null)"
SECURE="https://localhost:$(cat "$TMP/tls.port" 2>/dev/null)"
IMPOSTOR="http://127.0.0.1:$(cat "$TMP/impostor.port" 2>/dev/null)"
# --noproxy '' so no proxy setting in the environment lets curl skip the proxy for this machine.
code_of() { curl -s --noproxy '' -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
if [ -z "$PROXY" ]; then
  bad "the read only proxy started and wrote its address" "$(cat "$TMP/proxy.out" 2>/dev/null)"
else
  out="$(curl -s --noproxy '*' --max-time 5 "$PROXY/__bug-bash-proxy__/health")"
  grep -q '"proxy":"bug-bash-read-only"' <<< "$out" && ok || bad "the proxy answers its health check as itself" "$out"

  # Reads pass: the positive control, so a refusal below is the proxy's choice, not a dead path (L159).
  got="$(code_of -x "$PROXY" "$PLAIN/read?token=secret")"
  [ "$got" = 200 ] && grep -qx 'GET /read?token=secret' "$TMP/plain.log" && ok || bad "a GET through the proxy reaches the site" "$got $(cat "$TMP/plain.log" 2>/dev/null)"
  got="$(code_of -x "$PROXY" -I "$PLAIN/head")"
  [ "$got" = 200 ] && grep -qx 'HEAD /head' "$TMP/plain.log" && ok || bad "a HEAD through the proxy reaches the site" "$got"
  got="$(code_of -x "$PROXY" --cacert "$PROXY_CA" "$SECURE/secure-read")"
  [ "$got" = 200 ] && grep -qx 'GET /secure-read' "$TMP/tls.log" && ok || bad "a GET over https, through the proxy's tunnel, reaches the site" "$got $(cat "$TMP/proxy.out")"

  # Writes never reach the site, over http, over https, or inside a plain CONNECT tunnel.
  for m in POST PUT PATCH DELETE; do
    got="$(code_of -x "$PROXY" -X "$m" --data x=1 "$PLAIN/write-$m")"
    [ "$got" = 405 ] && ok || bad "a $m through the proxy is refused (got $got)"
    got="$(code_of -x "$PROXY" --cacert "$PROXY_CA" -X "$m" --data x=1 "$SECURE/write-$m")"
    [ "$got" = 405 ] && ok || bad "a $m over https through the proxy is refused (got $got)"
  done
  got="$(code_of -p -x "$PROXY" -X POST --data x=1 "$PLAIN/tunnelled-write")"
  [ "$got" = 405 ] && ok || bad "a POST inside a plain CONNECT tunnel is refused (got $got)"
  # WebSocket upgrades are refused: a socket's messages cannot be judged one by one.
  got="$(code_of -x "$PROXY" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$PLAIN/socket")"
  [ "$got" = 403 ] && ok || bad "a WebSocket upgrade through the proxy is refused (got $got)"
  got="$(code_of -x "$PROXY" --cacert "$PROXY_CA" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$SECURE/socket")"
  [ "$got" = 403 ] && ok || bad "a WebSocket upgrade over https through the proxy is refused (got $got)"
  writes="$(grep -Ev '^(GET|HEAD) ' "$TMP/plain.log" "$TMP/tls.log"; grep -h 'upgrade$' "$TMP/plain.log" "$TMP/tls.log")"
  [ -z "$writes" ] && ok || bad "the fixture sites received no write and no upgrade" "$writes"

  # Every request is logged with its verdict, and never with its query string (L741).
  grep -q '^REFUSED POST http://127.0.0.1:[0-9]*/write-POST$' "$TMP/proxy/requests.log" && grep -q '^FORWARDED GET https://localhost:[0-9]*/secure-read$' "$TMP/proxy/requests.log" && ok \
    || bad "the proxy logs each request with its verdict" "$(cat "$TMP/proxy/requests.log" 2>/dev/null)"
  ! grep -q 'token=secret' "$TMP/proxy/requests.log" && ok || bad "the proxy's log leaves out query strings"

  # A site that never answers is given up on with a 504, never held open for the whole run (L110).
  got="$(code_of -x "$PROXY" "$PLAIN/stall")"
  [ "$got" = 504 ] && ok || bad "a stalled site is answered 504 once the upstream deadline passes (got $got)"
  # A browser that goes away mid answer takes the proxy's upstream request with it: the site sees
  # its reader leave within seconds, not after the whole answer.
  code_of -x "$PROXY" --max-time 1 "$PLAIN/drip" >/dev/null
  for _ in $(seq 1 100); do grep -q '^DROPPED /drip' "$TMP/plain.log.dropped" 2>/dev/null && break; sleep 0.1; done
  grep -q '^DROPPED /drip' "$TMP/plain.log.dropped" 2>/dev/null && ok || bad "a request the browser abandons is dropped upstream too"
  # A site that drops its answer part way ends the browser's request at once: curl then reports a
  # short transfer (18), never its own deadline (28).
  curl -s --noproxy '' -o /dev/null --max-time 5 -x "$PROXY" "$PLAIN/cut"; rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 28 ] && ok || bad "an answer the site cuts off ends the browser's request too (curl rc $rc)"
  # A tunnel opened and then sent nothing is closed after the deadline, never held open.
  out="$(python3 - "${PROXY#http://}" "${PLAIN#http://}" <<'PY'
import socket, sys
host, port = sys.argv[1].split(':')
s = socket.create_connection((host, int(port)), timeout=5)
s.sendall(('CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n' % (sys.argv[2], sys.argv[2])).encode())
got = b''
while b'\r\n\r\n' not in got:
    got += s.recv(1024)
try:
    print('closed' if s.recv(1024) == b'' else 'data')
except socket.timeout:
    print('still open')
PY
)"
  [ "$out" = closed ] && ok || bad "an idle tunnel is closed after the deadline" "$out"
  # The run's certificates outlive any run, so https does not stop working part way through one.
  openssl x509 -checkend $((7 * 86400)) -noout -in "$PROXY_CA" >/dev/null && ok || bad "the proxy's certificate authority is good for at least a week"
fi

# ---------------------------------------------------------------- target-guard.sh
# Three fixture sites under one server: a production build, a Next dev server, a Vite dev server.
mkdir -p "$TMP/www/prod" "$TMP/www/nextdev" "$TMP/www/vitedev/@vite" "$TMP/www/wpdev"
printf '<!doctype html><title>App</title><script src="/static/js/bundle.js"></script><script src="/webpack-dev-server.js"></script>\n' > "$TMP/www/wpdev/index.html"
printf '<!doctype html><title>App</title><script src="/_next/static/chunks/main-abc123.js"></script>\n' > "$TMP/www/prod/index.html"
printf '<!doctype html><title>App</title><script src="/_next/static/chunks/react-refresh.js"></script><script id="__NEXT_DATA__">{"buildId":"development"}</script>\n' > "$TMP/www/nextdev/index.html"
printf '<!doctype html><title>App</title><div id="root"></div>\n' > "$TMP/www/vitedev/index.html"
printf 'import "/node_modules/vite/dist/client/env.mjs";\n' > "$TMP/www/vitedev/@vite/client"
# A production single page app answers every path with its own index page, the dev client's path
# included, so a 200 there must not read as a dev server.
mkdir -p "$TMP/www/prod/@vite"
cp "$TMP/www/prod/index.html" "$TMP/www/prod/@vite/client"

PORT_FILE="$TMP/port"
python3 - "$TMP/www" "$PORT_FILE" <<'PY' &
import http.server, socketserver, sys, os, functools
root, port_file = sys.argv[1], sys.argv[2]
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a, **k):
        pass
    # Two redirects: one staying on this machine, one leaving it.
    def do_GET(self):
        hops = {'/redir-local/': '/prod/', '/redir-remote/': 'http://app.example.com/', '/loop/': '/loop/'}
        if self.path in hops:
            self.send_response(302)
            self.send_header('Location', hops[self.path])
            self.end_headers()
            return
        super().do_GET()
handler = functools.partial(Quiet, directory=root)
with socketserver.TCPServer(("127.0.0.1", 0), handler) as httpd:
    with open(port_file + ".tmp", "w") as f:
        f.write(str(httpd.server_address[1]))
    os.rename(port_file + ".tmp", port_file)
    httpd.serve_forever()
PY
SERVER_PID=$!
# Waited on the condition itself, with a deadline, never a fixed sleep.
for _ in $(seq 1 200); do [ -s "$PORT_FILE" ] && break; sleep 0.05; done
PORT="$(cat "$PORT_FILE" 2>/dev/null)"
if [ -z "$PORT" ]; then
  bad "the fixture server started"
else
  BASE="http://127.0.0.1:$PORT"

  out="$(bash "$GUARD" "$BASE/prod/" 2>&1)"; rc=$?
  expect "a local production build is allowed" 0 "^LOCAL " "$rc" "$out"

  out="$(bash "$GUARD" "http://localhost:$PORT/prod/" 2>&1)"; rc=$?
  expect "localhost counts as local" 0 "^LOCAL " "$rc" "$out"

  out="$(bash "$GUARD" "$BASE/nextdev/" 2>&1)"; rc=$?
  expect "a Next dev server is refused" 4 "dev server" "$rc" "$out"

  out="$(bash "$GUARD" "$BASE/wpdev/" 2>&1)"; rc=$?
  expect "a webpack dev server (Create React App and kin) is refused" 4 "dev server" "$rc" "$out"

  out="$(bash "$GUARD" "$BASE/vitedev/" 2>&1)"; rc=$?
  expect "a Vite dev server is refused" 4 "dev server" "$rc" "$out"

  # A refusal names the remedy: build and serve a production build.
  grep -qi "production build" <<< "$out" && ok || bad "the dev server refusal says to use a production build" "$out"

  # Redirects are followed one hop at a time, each judged before it is requested (lessons review
  # of #798: curl -L followed a local page to a remote host and judged that host's page).
  out="$(bash "$GUARD" "$BASE/redir-local/" 2>&1)"; rc=$?
  expect "a redirect that stays on this machine is followed" 0 "^LOCAL " "$rc" "$out"
  out="$(bash "$GUARD" "$BASE/redir-remote/" 2>&1)"; rc=$?
  expect "a redirect off this machine is refused" 3 "redirects to app.example.com" "$rc" "$out"
  # A chain that never ends is refused, never judged by a page it did not reach.
  out="$(bash "$GUARD" "$BASE/loop/" 2>&1)"; rc=$?
  expect "a redirect chain past the hop limit is refused" 6 "redirects more than" "$rc" "$out"

  # Read only asked for against a local URL stays read only (lessons review of #798), and still
  # needs the read only proxy (#813).
  out="$(bash "$GUARD" --read-only --proxy "$PROXY" "$BASE/prod/" 2>&1)"; rc=$?
  expect "read only against a local build is still read only" 0 "^READ-ONLY .* via $PROXY" "$rc" "$out"
  # The guard's header documents the line it prints, so a reader parsing by it is not misled (L32).
  grep -q '`READ-ONLY <url> via <proxy>`' "$GUARD" && ok || bad "target-guard.sh's header names the READ-ONLY line it prints"
  out="$(BUG_BASH_PROXY= bash "$GUARD" --read-only "$BASE/prod/" 2>&1)"; rc=$?
  expect "read only against a local build with no proxy is refused" 7 "no read only proxy" "$rc" "$out"


  kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
  out="$(bash "$GUARD" "$BASE/prod/" 2>&1)"; rc=$?
  expect "a local URL nothing answers on is refused, not passed" 5 "nothing answer" "$rc" "$out"
fi

# Remote URLs: refused before any request. A fake curl records any call.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho called >> "%s/curl-calls"\nexit 0\n' "$TMP" > "$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
out="$(PATH="$TMP/bin:$PATH" bash "$GUARD" "https://app.example.com/" 2>&1)"; rc=$?
expect "a deployed site is refused without read only" 3 "real users" "$rc" "$out"
[ ! -e "$TMP/curl-calls" ] && ok || bad "the refusal of a deployed site makes no request to it"

# A read only run starts only behind a working read only proxy (#813), refused before any request
# is made to the target: with none named, with nothing answering where it is named, with something
# else answering there, and with something that answers as the proxy but lets a write through.
out="$(BUG_BASH_PROXY= PATH="$TMP/bin:$PATH" bash "$GUARD" --read-only "https://app.example.com/" 2>&1)"; rc=$?
expect "a read only run with no proxy is refused" 7 "no read only proxy" "$rc" "$out"
[ ! -e "$TMP/curl-calls" ] && ok || bad "a read only run refused for no proxy makes no request"
dead_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
out="$(bash "$GUARD" --read-only --proxy "http://127.0.0.1:$dead_port" "https://app.example.com/" 2>&1)"; rc=$?
expect "a read only run whose proxy is not answering is refused" 7 "answers as the bug bash read only proxy" "$rc" "$out"
out="$(bash "$GUARD" --read-only --proxy "$PLAIN" "https://app.example.com/" 2>&1)"; rc=$?
expect "a read only run whose proxy is some other server is refused" 7 "answers as the bug bash read only proxy" "$rc" "$out"
out="$(bash "$GUARD" --read-only --proxy "$IMPOSTOR" "https://app.example.com/" 2>&1)"; rc=$?
expect "a read only run whose proxy lets a write through is refused" 7 "did not refuse a write" "$rc" "$out"
out="$(bash "$GUARD" --read-only --proxy "http://proxy.example.com:8080" "https://app.example.com/" 2>&1)"; rc=$?
expect "a read only proxy that is not on this machine is refused" 7 "not on this machine" "$rc" "$out"
: > "$TMP/proxy/requests.log"
out="$(bash "$GUARD" --read-only --proxy "$PROXY" "https://app.example.com/" 2>&1)"; rc=$?
expect "a deployed site with read only is allowed behind the proxy" 0 "^READ-ONLY https://app.example.com/ via $PROXY" "$rc" "$out"
out="$(BUG_BASH_PROXY="$PROXY" bash "$GUARD" --read-only "https://app.example.com/" 2>&1)"; rc=$?
expect "the proxy can be named by BUG_BASH_PROXY" 0 "^READ-ONLY https://app.example.com/ via $PROXY" "$rc" "$out"
# The guard's own check went only to the probe name, which resolves nowhere, and was refused there.
probe_log="$(cat "$TMP/proxy/requests.log" 2>/dev/null)"
grep -q '^REFUSED POST http://bug-bash-probe.invalid/write$' <<< "$probe_log" && ! grep -q 'example.com' <<< "$probe_log" && ok \
  || bad "the guard's write probe goes only to a name that resolves nowhere, and is refused" "$probe_log"

# Hosts that only look local are not local.
out="$(PATH="$TMP/bin:$PATH" bash "$GUARD" "http://localhost.example.com/" 2>&1)"; rc=$?
expect "a host merely starting with localhost is remote" 3 "real users" "$rc" "$out"
out="$(PATH="$TMP/bin:$PATH" bash "$GUARD" "http://127.0.0.1.nip.io/" 2>&1)"; rc=$?
expect "a host merely starting with 127.0.0.1 is remote" 3 "real users" "$rc" "$out"

out="$(bash "$GUARD" 2>&1)"; rc=$?
expect "no URL prints usage" 2 "usage" "$rc" "$out"
out="$(bash "$GUARD" "app.example.com" 2>&1)"; rc=$?
expect "a URL with no scheme is refused" 2 "http" "$rc" "$out"

# ---------------------------------------------------------------- report.py
write() { printf '%s\n' "$2" > "$TMP/$1.json"; }
run_report() { python3 "$REPORT" "$TMP/$1.json" 2>&1; }

write good '{
  "target": "http://127.0.0.1:4173/", "mode": "local",
  "cost": {"model_calls": 23},
  "findings": [
    {"id": "f3", "area": "Invoices", "persona": "numbers and copy", "title": "Invoice total does not match its line items",
     "status": "confirmed", "test": "e2e/bug-bash/invoice-total.spec.ts",
     "failure": "Expected: \"$1,004.00\" Received: \"$1,040.00\"",
     "reason_match": "the total is asserted against the sum of the line items, which is what the explorer reported"},
    {"id": "f4", "area": "Clients", "persona": "odd input", "title": "Saving a client name with an emoji returns 500",
     "status": "unverified", "why_unverified": "the local database accepts it; production uses a different collation"},
    {"id": "f1", "area": "Navigation", "persona": "first time visitor", "title": "Reports link is a dead link",
     "status": "rejected", "reject_reason": "explorer-artifact", "note": "a slow first load, the page renders"},
    {"id": "f2", "area": "Export", "persona": "first time visitor", "title": "Export CSV does nothing",
     "status": "rejected", "reject_reason": "explorer-artifact", "note": "it opens a new tab"},
    {"id": "f5", "area": "Invoices", "persona": "first time visitor", "title": "Invoices tab is empty",
     "status": "rejected", "reject_reason": "local-setup", "note": "the seed client has no invoices"}
  ]}'
out="$(run_report good)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "a well formed findings file reports (rc $rc)" "$out"
# Order: confirmed, then unverified, then rejected, then cost.
order="$(grep -n -E '^## ' <<< "$out" | cut -d: -f1 | tr '\n' ' ')"
c=$(grep -n '^## Confirmed' <<< "$out" | cut -d: -f1); u=$(grep -n '^## Risks' <<< "$out" | cut -d: -f1)
r=$(grep -n '^## Rejected' <<< "$out" | cut -d: -f1); k=$(grep -n '^## Cost' <<< "$out" | cut -d: -f1)
if [ -n "$c" ] && [ -n "$u" ] && [ -n "$r" ] && [ -n "$k" ] && [ "$c" -lt "$u" ] && [ "$u" -lt "$r" ] && [ "$r" -lt "$k" ]; then ok
else bad "sections run confirmed, risks, rejected, cost (headings at $order)" "$out"; fi
grep -q '^## Confirmed bugs (1)' <<< "$out" && ok || bad "the confirmed count is the one confirmed finding" "$out"
grep -q 'e2e/bug-bash/invoice-total.spec.ts' <<< "$out" && ok || bad "a confirmed bug names its failing test" "$out"
grep -qF 'Received: "$1,040.00"' <<< "$out" && ok || bad "a confirmed bug quotes the failure" "$out"
# The confirmed section holds only the confirmed finding.
conf_section="$(sed -n '/^## Confirmed/,/^## Risks/p' <<< "$out")"
grep -q 'emoji\|dead link\|Export CSV' <<< "$conf_section" && bad "nothing unconfirmed appears among the confirmed bugs" "$conf_section" || ok
# Rejected findings are grouped by reason, each reason once, with its count.
[ "$(grep -c '^### ' <<< "$(sed -n '/^## Rejected/,/^## Cost/p' <<< "$out")")" = "2" ] && ok \
  || bad "rejected findings are grouped under one heading per reason" "$out"
grep -qi '^### .*explorer.*(2)' <<< "$out" && ok || bad "the explorer artefact group counts its two findings" "$out"
grep -q '23 model calls' <<< "$out" && ok || bad "the cost line says how many model calls the run made" "$out"
# Every finding appears exactly once (L517).
for t in "Invoice total" "emoji" "Reports link" "Export CSV" "Invoices tab"; do
  [ "$(grep -c "$t" <<< "$out")" = "1" ] && ok || bad "'$t' appears exactly once in the report" "$out"
done

# A confirmed finding without its evidence is refused, naming the finding.
write nofail '{"target":"http://127.0.0.1/","mode":"local","cost":{"model_calls":3},"findings":[
  {"id":"f9","area":"A","persona":"p","title":"t","status":"confirmed","test":"x.spec.ts","reason_match":"r"}]}'
out="$(run_report nofail)"; rc=$?
expect "a confirmed finding with no failing output is refused" 2 "f9.*fail" "$rc" "$out"
write notest '{"target":"http://127.0.0.1/","mode":"local","cost":{"model_calls":3},"findings":[
  {"id":"f8","area":"A","persona":"p","title":"t","status":"confirmed","failure":"boom","reason_match":"r"}]}'
out="$(run_report notest)"; rc=$?
expect "a confirmed finding with no test is refused" 2 "f8.*test" "$rc" "$out"
write noreason '{"target":"http://127.0.0.1/","mode":"local","cost":{"model_calls":3},"findings":[
  {"id":"f7","area":"A","persona":"p","title":"t","status":"confirmed","test":"x.spec.ts","failure":"boom"}]}'
out="$(run_report noreason)"; rc=$?
expect "a confirmed finding that does not say why the failure is the explorer's reason is refused" 2 "f7.*reason" "$rc" "$out"
write badreject '{"target":"http://127.0.0.1/","mode":"local","cost":{"model_calls":3},"findings":[
  {"id":"f6","area":"A","persona":"p","title":"t","status":"rejected","reject_reason":"meh"}]}'
out="$(run_report badreject)"; rc=$?
expect "a rejection reason outside the vocabulary is refused, listing the vocabulary" 2 "local-setup" "$rc" "$out"
write badstatus '{"target":"http://127.0.0.1/","mode":"local","cost":{"model_calls":3},"findings":[
  {"id":"f5","area":"A","persona":"p","title":"t","status":"probably"}]}'
out="$(run_report badstatus)"; rc=$?
expect "an unknown status is refused" 2 "f5.*status" "$rc" "$out"
write nocost '{"target":"http://127.0.0.1/","mode":"local","findings":[]}'
out="$(run_report nocost)"; rc=$?
expect "a run that does not say what it cost is refused" 2 "model_calls" "$rc" "$out"
write strcost '{"target":"http://127.0.0.1/","mode":"local","cost":{"model_calls":"lots"},"findings":[]}'
out="$(run_report strcost)"; rc=$?
expect "a cost that is not a count is refused" 2 "model_calls" "$rc" "$out"
write dupe '{"target":"http://127.0.0.1/","mode":"local","cost":{"model_calls":3},"findings":[
  {"id":"f1","area":"A","persona":"p","title":"t","status":"unverified","why_unverified":"w"},
  {"id":"f1","area":"A","persona":"p","title":"u","status":"unverified","why_unverified":"w"}]}'
out="$(run_report dupe)"; rc=$?
expect "two findings with one id are refused" 2 "f1.*twice\|duplicate" "$rc" "$out"
printf 'not json' > "$TMP/broken.json"
out="$(run_report broken)"; rc=$?
expect "a findings file that is not JSON is refused" 2 "json" "$rc" "$out"

# A read only run cannot have run a test, so nothing in it can be confirmed (lessons review of #798).
write roconf '{"target":"https://app.example.com/","mode":"read-only","cost":{"model_calls":3},"findings":[
  {"id":"f4","area":"A","persona":"p","title":"t","status":"confirmed","test":"x.spec.ts","failure":"boom","reason_match":"r"}]}'
out="$(run_report roconf)"; rc=$?
expect "a confirmed finding in a read only run is refused" 2 "f4.*read only" "$rc" "$out"

# The healthy day is said, not left blank (L610).
write empty '{"target":"http://127.0.0.1/","mode":"local","cost":{"model_calls":9},"findings":[]}'
out="$(run_report empty)"; rc=$?
expect "a run with no findings says so" 0 "no findings" "$rc" "$out"
# A read only run says so at the top, since its risks could not be reproduced with a test.
write ro '{"target":"https://app.example.com/","mode":"read-only","cost":{"model_calls":9},"findings":[]}'
out="$(run_report ro)"; rc=$?
expect "a read only run is labelled read only" 0 "read only" "$rc" "$out"

# ---------------------------------------------------------------- explorer-browser.js
# Read only is enforced in the browser, not asked for in a prompt (lessons review of #798): the
# launcher every explorer uses aborts any request that is not a read. Driven with a stand in
# Playwright, so no browser starts here; what is asserted is what the launcher wires.
LAUNCHER="$DIR/explorer-browser.js"
out="$(BUG_BASH_PROXY="$PROXY" node -e '
const { launch, isRead } = require(process.argv[1])
const routes = []
const opts = []
const launches = []
const fake = { launch: async o => { launches.push(o || {}); return { newContext: async o => { opts.push(o || {}); return { route: async (pat, fn) => routes.push({ pat, fn }) } } } } }
const req = m => ({ request: () => ({ method: () => m }), continue: () => "continued", abort: () => "aborted" })
;(async () => {
  const ro = await launch({ chromium: fake, readOnly: true })
  const r = routes.length === 1 ? routes[0] : null
  const verdicts = r ? ["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"].map(m => m + "=" + r.fn(req(m))) : []
  routes.length = 0
  await launch({ chromium: fake, readOnly: false })
  console.log(JSON.stringify({ noBrowser: !("browser" in ro), canClose: typeof ro.close === "function", hasContext: !!ro.context, routed: !!r, verdicts, localRoutes: routes.length, isRead: ["GET","post"].map(isRead), sw: opts.map(o => o.serviceWorkers || "allow"), certs: opts.map(o => !!o.ignoreHTTPSErrors), proxies: launches.map(o => (o.proxy && o.proxy.server) || "none"), bypass: launches.map(o => (o.args || []).join(" ")) }))
})().catch(e => { console.log("ERR " + e.message); process.exit(1) })
' "$LAUNCHER" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "the explorer launcher loads and launches with a stand in browser" "$out"
grep -q '"verdicts":\["GET=continued","HEAD=continued","OPTIONS=continued","POST=aborted","PUT=aborted","PATCH=aborted","DELETE=aborted"\]' <<< "$out" && ok \
  || bad "read only lets reads through and aborts every request that could change something" "$out"
grep -q '"localRoutes":0' <<< "$out" && ok || bad "a local run is not restricted" "$out"
# A service worker's requests bypass context.route, so a read only context blocks service workers
# (lessons review of #798).
grep -q '"sw":\["block","allow"\]' <<< "$out" && ok || bad "a read only context blocks service workers, a local one does not" "$out"
grep -q '"hasContext":true' <<< "$out" && ok || bad "the launcher hands back the context explorers drive" "$out"
# A read only browser goes through the read only proxy, loopback hosts included, and accepts the
# certificates the proxy makes to see inside https; a local run does neither (#813).
grep -qF "\"proxies\":[\"$PROXY\",\"none\"]" <<< "$out" && ok || bad "a read only browser is launched through the read only proxy, a local one is not" "$out"
grep -qF '"bypass":["--proxy-bypass-list=<-loopback>",""]' <<< "$out" && ok || bad "a read only browser sends this machine's hosts through the proxy too" "$out"
grep -q '"certs":\[true,false\]' <<< "$out" && ok || bad "only a read only context accepts the proxy's certificates" "$out"
# No browser handle comes back, so no explorer can make a second context without the read only route.
grep -q '"noBrowser":true,"canClose":true' <<< "$out" && ok || bad "the launcher hands back a close, never the browser" "$out"
out="$(node -e 'require(process.argv[1]).launch({ readOnly: true }).then(() => console.log("launched"), e => { console.log(e.message); process.exit(3) })' "$LAUNCHER" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && grep -qi 'playwright' <<< "$out" && ok || bad "with no Playwright handed in, the launcher refuses by name (rc $rc)" "$out"
# A setup that fails after the browser started closes it rather than leaking it (lessons review).
out="$(BUG_BASH_PROXY="$PROXY" node -e '
const { launch } = require(process.argv[1])
let closed = 0
const fake = { launch: async () => ({ close: async () => { closed++ }, newContext: async () => ({ route: async () => { throw new Error("route failed") } }) }) }
launch({ chromium: fake, readOnly: true }).then(() => console.log("no throw"), e => console.log("threw " + e.message + " closed=" + closed))
' "$LAUNCHER" 2>&1)"
grep -q 'threw route failed closed=1' <<< "$out" && ok || bad "a failed read only setup closes the browser it started and rethrows" "$out"
grep -q 'explorer-browser.js' "$DIR/SKILL.md" && ok || bad "SKILL.md has every explorer launch through explorer-browser.js"
# A read only browser is never launched without the proxy answering as itself (#813): with none
# named, with nothing answering, and with some other server answering. The stand in counts every
# launch, so a refusal is seen to come before the browser starts.
proxied_launch() { # $1 = proxy value ("" for none)
  BUG_BASH_PROXY="$1" node -e '
const { launch } = require(process.argv[1])
let launched = 0
const fake = { launch: async () => { launched++; return { close: async () => {}, newContext: async () => ({ route: async () => {} }) } } }
launch({ chromium: fake, readOnly: true }).then(() => console.log("launched=" + launched), e => console.log("threw launched=" + launched + " " + e.message))
' "$LAUNCHER" 2>&1
}
out="$(proxied_launch "")"
grep -q '^threw launched=0 .*read only proxy' <<< "$out" && ok || bad "a read only browser with no proxy named is refused before it launches" "$out"
out="$(proxied_launch "http://127.0.0.1:$dead_port")"
grep -q '^threw launched=0 .*not answering' <<< "$out" && ok || bad "a read only browser whose proxy is not answering is refused before it launches" "$out"
out="$(proxied_launch "$PLAIN")"
grep -q '^threw launched=0 .*not as the bug bash read only proxy' <<< "$out" && ok || bad "a read only browser whose proxy is some other server is refused before it launches" "$out"
out="$(proxied_launch "$PROXY")"
grep -q '^launched=1$' <<< "$out" && ok || bad "a read only browser whose proxy answers as itself launches" "$out"
grep -q 'read-only-proxy.js' "$DIR/SKILL.md" && ok || bad "SKILL.md starts the read only proxy for a read only run"

# ---------------------------------------------------------------- the proxy's address does not outlive it
# A second proxy started on a directory a live one is using refuses, and leaves the live one's
# proxy.json alone.
if [ -n "${PROXY_PID:-}" ]; then
  # Started in the background and waited on with a deadline, so a proxy that wrongly starts is
  # stopped and reported rather than holding the suite.
  node "$PROXY_JS" --state "$TMP/proxy" >"$TMP/second.out" 2>&1 & second=$!
  for _ in $(seq 1 100); do kill -0 "$second" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$second" 2>/dev/null; then kill "$second" 2>/dev/null; wait "$second" 2>/dev/null; rc=running; else wait "$second"; rc=$?; fi
  out="$(cat "$TMP/second.out")"
  [ "$rc" = 3 ] && grep -q "already running" <<< "$out" && grep -q "\"pid\":$PROXY_PID" "$TMP/proxy/proxy.json" && ok \
    || bad "a second proxy on a live proxy's directory refuses and leaves its proxy.json (rc $rc)" "$out"
fi
# A proxy.json left behind names a dead process as the proxy, so the proxy removes it as it stops,
# here on a hangup, the signal a closed terminal sends.
if [ -n "${PROXY_PID:-}" ]; then
  kill -HUP "$PROXY_PID" 2>/dev/null
  for _ in $(seq 1 200); do kill -0 "$PROXY_PID" 2>/dev/null || break; sleep 0.05; done
  [ ! -e "$TMP/proxy/proxy.json" ] && ok || bad "a stopped proxy removes its proxy.json" "$(cat "$TMP/proxy/proxy.json" 2>/dev/null)"
fi
# A proxy that cannot start (here, no openssl to make its certificates) refuses by name, and leaves
# no stale proxy.json from an earlier run standing in its place.
mkdir -p "$TMP/proxy2" "$TMP/no-openssl"
printf '{"proxy":"http://127.0.0.1:1","pid":%s}\n' "$DEAD_PID" > "$TMP/proxy2/proxy.json"
out="$(PATH="$TMP/no-openssl" "$(command -v node)" "$PROXY_JS" --state "$TMP/proxy2" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'will not start' <<< "$out" && [ ! -e "$TMP/proxy2/proxy.json" ] && ok   || bad "a proxy that cannot start refuses by name and removes a stale proxy.json (rc $rc)" "$out"

# ---------------------------------------------------------------- SKILL.md wires both helpers
SKILL="$DIR/SKILL.md"
fm="$(sed -n '1,/^---$/{p;}' "$SKILL" | sed -n '2,8p')"
grep -q '^name: bug-bash$' <<< "$fm" && ok || bad "SKILL.md is named bug-bash"
grep -q '^disable-model-invocation: true$' <<< "$fm" && ok || bad "SKILL.md is user invoked only, since it dispatches paid agents"
grep -q 'bash ~/.claude/skills/bug-bash/target-guard.sh' "$SKILL" && ok || bad "SKILL.md runs target-guard.sh from its installed path"
grep -q 'python3 ~/.claude/skills/bug-bash/report.py' "$SKILL" && ok || bad "SKILL.md builds the report with report.py from its installed path"
# Every rejection reason the skill names is one report.py accepts, and the reverse (L89).
skill_reasons="$(grep -o '`[a-z][a-z-]*`' "$SKILL" | tr -d '`' | sort -u)"
py_reasons="$(python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("r",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print("\n".join(sorted(m.REJECT_REASONS)))' "$REPORT")"
missing=""
while IFS= read -r r; do grep -qx -- "$r" <<< "$skill_reasons" || missing="$missing $r"; done <<< "$py_reasons"
[ -z "$missing" ] && ok || bad "SKILL.md names every rejection reason report.py accepts (missing:$missing)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
