#!/usr/bin/env node
'use strict';
//
// fake-gh.js: the only `gh` the pennie-dev-update tests ever run.
//
// gather.js reaches GitHub through one seam, PENNIE_DEV_UPDATE_GH, and every test points it here.
// This answers from a scenario file (FAKE_GH_SCENARIO) and records every call (FAKE_GH_LOG), so a
// test can assert what was asked as well as what came back. It refuses anything that is not a
// plain read, and says so in the log, so a write can never be mistaken for a quiet success.
//
// Scenario shape:
//   { "pulls":   { "owner/name": [ <pull objects as the GitHub REST API returns them> ] },
//     "compare": { "owner/name": { "<base>...<head>": "ahead" | "behind" | "identical" | "diverged" } },
//     "searchDelta": { "owner/name": <number added to the honest count> },
//     "fail":    { "owner/name": "<stderr text>" } }

const fs = require('fs');

const args = process.argv.slice(2);
const log = process.env.FAKE_GH_LOG;
function record(line) { if (log) fs.appendFileSync(log, line + '\n'); }
function die(code, msg) { process.stderr.write(msg + '\n'); process.exit(code); }

record(JSON.stringify(args));

const WRITES = ['-X', '--method', '-f', '-F', '--field', '--raw-field', '--input'];
if (args[0] !== 'api') { record('REFUSED not an api read'); die(9, 'fake gh: only `gh api` reads are served'); }
if (args.some(function (a) { return WRITES.indexOf(a) !== -1; })) {
  record('REFUSED write'); die(9, 'fake gh: a write was attempted');
}
const route = args.filter(function (a) { return a !== 'api'; })[0] || '';

let scenario;
try { scenario = JSON.parse(fs.readFileSync(process.env.FAKE_GH_SCENARIO, 'utf8')); }
catch (e) { die(8, 'fake gh: no readable scenario: ' + e.message); }

const clean = route.replace(/^\//, '');
const [routePath, query] = clean.split('?');
const params = new URLSearchParams(query || '');

function failFor(slug) {
  if (scenario.fail && scenario.fail[slug]) die(1, scenario.fail[slug]);
}

let m = routePath.match(/^repos\/([^/]+\/[^/]+)\/pulls$/);
if (m) {
  const slug = m[1];
  failFor(slug);
  const all = (scenario.pulls && scenario.pulls[slug]) || [];
  const per = Number(params.get('per_page') || 30);
  const page = Number(params.get('page') || 1);
  if (params.get('state') !== 'closed') die(2, 'fake gh: pulls must be read with state=closed');
  process.stdout.write(JSON.stringify(all.slice((page - 1) * per, page * per)));
  process.exit(0);
}

m = routePath.match(/^repos\/([^/]+\/[^/]+)\/compare\/([^/]+)$/);
if (m) {
  const slug = m[1];
  failFor(slug);
  const status = scenario.compare && scenario.compare[slug] && scenario.compare[slug][m[2]];
  if (!status) die(1, 'gh: Not Found (HTTP 404)');
  process.stdout.write(JSON.stringify({ status: status }));
  process.exit(0);
}

if (routePath === 'search/issues') {
  const q = params.get('q') || '';
  const repo = (q.match(/repo:(\S+)/) || [])[1];
  const after = (q.match(/merged:>(\S+)/) || [])[1];
  if (!repo || !after || !/is:pr/.test(q) || !/is:merged/.test(q)) die(2, 'fake gh: unexpected search ' + q);
  failFor(repo);
  const t = Date.parse(after);
  if (Number.isNaN(t)) die(2, 'fake gh: search date does not parse: ' + after);
  const count = ((scenario.pulls && scenario.pulls[repo]) || [])
    .filter(function (p) { return p.merged_at && Date.parse(p.merged_at) > t; }).length;
  const delta = (scenario.searchDelta && scenario.searchDelta[repo]) || 0;
  process.stdout.write(JSON.stringify({ total_count: count + delta, items: [] }));
  process.exit(0);
}

die(2, 'fake gh: no route for ' + route);
