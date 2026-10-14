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
//     "fail":    { "owner/name": "<stderr text>" },
//     "failRoute": { "<text a route contains>": "<stderr text>" },
//     "runs":    { "owner/name": { "<workflow file>": [ <workflow runs, newest first> ] } },
//     "jobs":    { "<run id>": [ <jobs of that run> ] },
//     "annotations": { "<job id>": [ <check run annotations> ] },
//     "checkRuns": { "owner/name": { "<sha>": [ <check runs on that commit> ] } },
//     "signedIn": [ "<login>", ... ],
//     "access":  { "owner/name": [ "<login>", ... ] },
//     "issueCommands": true, "issueExit": <exit code of an issue command> }
//
// Accounts (claude-config#1182). A call is made AS the account whose token is in GH_TOKEN, and one
// with no GH_TOKEN would be made as the ACTIVE account, which is refused outright: the skill must
// scope every call, so an unscoped one fails the case rather than quietly succeeding. `gh auth
// token --hostname github.com -u <login>` answers a token for a login in signedIn (every login,
// when signedIn is absent) and fails as gh does for any other. Every other `gh auth` subcommand is
// refused, so a switch of the active account can never pass. A repo listed in access answers 404,
// as GitHub does for a private repo, to any account not listed beside it. The tokens are made up
// here and carry the login, so the log records the ACCOUNT a call was made as, never a token.
//
// issueCommands lets `gh issue ...` and `gh label ...` through, for the cases that drive the issue
// check's commands through `gather.js gh`; they print what they were asked and change nothing.

const fs = require('fs');

const args = process.argv.slice(2);
const log = process.env.FAKE_GH_LOG;
function record(line) { if (log) fs.appendFileSync(log, line + '\n'); }
function die(code, msg) { process.stderr.write(msg + '\n'); process.exit(code); }

record(JSON.stringify(args));

let scenario;
try { scenario = JSON.parse(fs.readFileSync(process.env.FAKE_GH_SCENARIO, 'utf8')); }
catch (e) { die(8, 'fake gh: no readable scenario: ' + e.message); }

const TOKEN_PREFIX = 'fake-gh-token-for-';
function signedIn(login) { return !scenario.signedIn || scenario.signedIn.indexOf(login) !== -1; }

if (args[0] === 'auth') {
  const u = args.indexOf('-u') !== -1 ? args.indexOf('-u') : args.indexOf('--user');
  const login = u === -1 ? null : args[u + 1];
  if (args[1] !== 'token' || !login || args[args.indexOf('--hostname') + 1] !== 'github.com') {
    record('REFUSED auth ' + args.slice(1).join(' '));
    die(9, 'fake gh: only the token of one named github.com account is served');
  }
  // A token already in the environment is what gh would answer with, whoever was asked about,
  // so a caller that leaves its own GH_TOKEN in place reads as the wrong account.
  if (process.env.GH_TOKEN) { process.stdout.write(process.env.GH_TOKEN + '\n'); process.exit(0); }
  if (!signedIn(login)) die(1, 'no oauth token found for github.com account ' + login);
  process.stdout.write(TOKEN_PREFIX + login + '\n');
  process.exit(0);
}

const token = process.env.GH_TOKEN;
const as = token ? (token.indexOf(TOKEN_PREFIX) === 0 ? token.slice(TOKEN_PREFIX.length) : 'UNKNOWN TOKEN') : null;
record('AS ' + (as || 'ACTIVE'));
if (!as) { record('REFUSED unscoped'); die(9, 'fake gh: a call made as the active account, with no GH_TOKEN'); }
function canSee(slug) {
  const list = scenario.access && scenario.access[slug];
  return !list || list.indexOf(as) !== -1;
}

if ((args[0] === 'issue' || args[0] === 'label') && scenario.issueCommands) {
  const r = args.indexOf('--repo');
  const slug = r === -1 ? null : args[r + 1];
  if (!slug) die(2, 'fake gh: no --repo');
  if (!canSee(slug)) die(1, 'GraphQL: Could not resolve to a Repository with the name \'' + slug + '\'. (repository)');
  process.stdout.write('fake gh ran ' + args.join(' ') + ' as ' + as + '\n');
  process.exit(Number(scenario.issueExit || 0));
}

const WRITES = ['-X', '--method', '-f', '-F', '--field', '--raw-field', '--input'];
if (args[0] !== 'api') { record('REFUSED not an api read'); die(9, 'fake gh: only `gh api` reads are served'); }
if (args.some(function (a) { return WRITES.indexOf(a) !== -1; })) {
  record('REFUSED write'); die(9, 'fake gh: a write was attempted');
}
const route = args.filter(function (a) { return a !== 'api'; })[0] || '';

const clean = route.replace(/^\//, '');
const [routePath, query] = clean.split('?');
const params = new URLSearchParams(query || '');

// A failure scoped to one kind of read, so a test can fail the deploy record alone.
Object.keys(scenario.failRoute || {}).forEach(function (part) {
  if (clean.indexOf(part) !== -1) die(1, scenario.failRoute[part]);
});

function failFor(slug) {
  if (!canSee(slug)) die(1, 'gh: Not Found (HTTP 404)');
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

m = routePath.match(/^repos\/([^/]+\/[^/]+)\/actions\/workflows\/([^/]+)\/runs$/);
if (m) {
  failFor(m[1]);
  const runs = ((scenario.runs && scenario.runs[m[1]]) || {})[m[2]];
  if (!runs) die(1, 'gh: Not Found (HTTP 404)');
  const per = Number(params.get('per_page') || 30);
  process.stdout.write(JSON.stringify({ total_count: runs.length, workflow_runs: runs.slice(0, per) }));
  process.exit(0);
}

m = routePath.match(/^repos\/([^/]+\/[^/]+)\/actions\/runs\/(\d+)\/jobs$/);
if (m) {
  failFor(m[1]);
  const jobs = scenario.jobs && scenario.jobs[m[2]];
  if (!jobs) die(1, 'gh: Not Found (HTTP 404)');
  process.stdout.write(JSON.stringify({ total_count: jobs.length, jobs: jobs }));
  process.exit(0);
}

m = routePath.match(/^repos\/([^/]+\/[^/]+)\/check-runs\/(\d+)\/annotations$/);
if (m) {
  failFor(m[1]);
  process.stdout.write(JSON.stringify((scenario.annotations && scenario.annotations[m[2]]) || []));
  process.exit(0);
}

m = routePath.match(/^repos\/([^/]+\/[^/]+)\/commits\/([0-9a-f]+)\/check-runs$/);
if (m) {
  failFor(m[1]);
  const name = params.get('check_name');
  const all = ((scenario.checkRuns && scenario.checkRuns[m[1]]) || {})[m[2]] || [];
  const runs = all.filter(function (c) { return !name || c.name === name; });
  process.stdout.write(JSON.stringify({ total_count: runs.length, check_runs: runs }));
  process.exit(0);
}

die(2, 'fake gh: no route for ' + route);
