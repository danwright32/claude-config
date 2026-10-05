#!/usr/bin/env bash
# Tests for the bug-bash skill's two helpers (claude-config#719):
#
#   target-guard.sh  decides whether a bug bash may run against a URL at all: a local production
#                    build only, a deployment only when read only is asked for, never a dev server.
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
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '  output: %s\n' "$2"; return 0; }
expect() { # expect <description> <want rc> <want words> <got rc> <got output>
  if [ "$4" -eq "$2" ] && grep -qi -- "$3" <<< "$5"; then ok; else bad "$1 (want rc $2, got $4)" "$5"; fi
}

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

  # Read only asked for against a local URL stays read only (lessons review of #798).
  out="$(bash "$GUARD" --read-only "$BASE/prod/" 2>&1)"; rc=$?
  expect "read only against a local build is still read only" 0 "^READ-ONLY " "$rc" "$out"


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

out="$(PATH="$TMP/bin:$PATH" bash "$GUARD" --read-only "https://app.example.com/" 2>&1)"; rc=$?
expect "a deployed site with read only is allowed in read only mode" 0 "^READ-ONLY https://app.example.com/" "$rc" "$out"

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
out="$(node -e '
const { launch, isRead } = require(process.argv[1])
const routes = []
const opts = []
const fake = { launch: async () => ({ newContext: async o => { opts.push(o || {}); return { route: async (pat, fn) => routes.push({ pat, fn }) } } }) }
const req = m => ({ request: () => ({ method: () => m }), continue: () => "continued", abort: () => "aborted" })
;(async () => {
  const ro = await launch({ chromium: fake, readOnly: true })
  const r = routes.length === 1 ? routes[0] : null
  const verdicts = r ? ["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"].map(m => m + "=" + r.fn(req(m))) : []
  routes.length = 0
  await launch({ chromium: fake, readOnly: false })
  console.log(JSON.stringify({ hasContext: !!ro.context, routed: !!r, verdicts, localRoutes: routes.length, isRead: ["GET","post"].map(isRead), sw: opts.map(o => o.serviceWorkers || "allow") }))
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
out="$(node -e 'require(process.argv[1]).launch({ readOnly: true }).then(() => console.log("launched"), e => { console.log(e.message); process.exit(3) })' "$LAUNCHER" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && grep -qi 'playwright' <<< "$out" && ok || bad "with no Playwright handed in, the launcher refuses by name (rc $rc)" "$out"
grep -q 'explorer-browser.js' "$DIR/SKILL.md" && ok || bad "SKILL.md has every explorer launch through explorer-browser.js"

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
