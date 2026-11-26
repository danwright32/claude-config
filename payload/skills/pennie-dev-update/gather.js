#!/usr/bin/env node
'use strict';
//
// gather.js: the window, the gathering and the state of the /pennie-dev-update skill, as code
// (claude-config#680). Each rule here used to be prose in SKILL.md that a run had to follow by
// hand (L27), and the one it got wrong, a >= where the window is strictly after lastEnd, listed
// the last post's newest change twice (claude-config#679).
//
//   gather.js gather [--config P] [--state P] [--now ISO] [--only NAME] [--out P]
//                    [--live owner/name=SHA@ISO]... [--since ISO [--confirm-skip]]
//   gather.js commit-state --gathered P --draft P --repo owner/name
//                    [--listed N,N,...] [--headings 'A|B'] [--outcomes N=OUTCOME,...] [--drafts DIR] [--state P]
//   gather.js posted --gathered P --repo owner/name --number N --read FILE[,FILE...]
//   gather.js draftable --gathered P --repo owner/name --number N --drafts DIR
//   gather.js drafted --gathered P --repo owner/name --number N --drafts DIR [--tool-error yes]
//   gather.js gh [--config P] -- <gh command naming its repo with --repo owner/name>
//
// gather prints one JSON document (and writes it to --out): per repo, its window, every merged
// PR in it with its changelog record and whether it reached production, what to hold back, and
// any refusal with its reason. It only ever READS from GitHub, through `gh api`, by owner/name,
// so it runs from any directory and needs no local checkout.
//
// Every call is made as the GitHub account the registry (this Mac's repos.local.json) names for the repo, through that account's
// token in the call's own environment, whichever account gh has active (claude-config#1182).
// `gather.js gh` runs the issue check's own gh commands (SKILL.md section 9) the same way: it is
// the only part of this file that can change anything on GitHub, and only what it is told to run.
//
// Whether a PR reached production comes from the repo's deploy record (the registry's deployRecord).
// PET's lives in its database, so it is read by hand and handed over with --live. Slate's and
// Sonar's live on GitHub, so gather reads them itself (claude-config#1177): Slate's CI deploy job,
// with the exit code of the step that touches production, plus its Rollback runs; and Sonar's
// Cloudflare Pages check run on the merge commit.
//
// commit-state is the only writer of the state file, and it refuses without the draft: if a run
// dies before the draft exists, the boundary must not move, or that period is skipped for ever.
//
// Exit codes: 0 every repo gathered (a first appearance included), 3 at least one repo refused or
// unreachable (the rest are still in the output), 1 the whole run refused (usage, config, state).

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

// The one definition of a changelog record, shared with the merge gate that enforces it
// (hooks/require-changelog-tag.sh). The skill and the hooks sit side by side both in this
// repository's payload/ and once installed in ~/.claude, so the path is the same in both.
const ENTRY_PATH = path.join(__dirname, '..', '..', 'hooks', 'lib', 'changelog-entry.js');
// The one reader of the registry, shared with the same gate (claude-config#1526): where this Mac
// keeps it (never the shared config, because it names work repositories) and how it is read.
const REGISTRY_PATH = path.join(__dirname, '..', '..', 'hooks', 'lib', 'dev-update-registry.js');
// The one comparison of an announcement with what Slack holds, words only (claude-config#3668),
// shared since #3667 with the is it live mod, which judges a draft of one through its command line.
const COMPARE_PATH = path.join(__dirname, '..', '..', 'hooks', 'lib', 'announce-compare.js');

const PER_PAGE = 100;
const MAX_PAGES = 200;             // 20,000 PRs, far past any repo here; a guard against a loop
const GH_TIMEOUT_MS = 120000;      // a gh call that hangs is a failure, never a wait (L110)
const RECORDER_STALE_DAYS = 3;     // build_history with no row this recent: the recorder stopped
const MAX_SEED_WALK = 200;         // newest merges walked looking for a live one on a first run
const DEPLOY_SCAN = 30;            // newest deploy runs, or merges, read looking for the live one
// The line the Actions runner annotates a failed step with. It is the only place GitHub keeps a
// step's exit code, and Slate's exit code is what says where production ended (its DEPLOY.md).
const EXIT_ANNOTATION = /Process completed with exit code (\d+)/;
const RECORD_KINDS = ['actions_deploy_job', 'deploy_check_run'];
const DEPENDABOT = 'dependabot[bot]';
const GH_HOST = 'github.com';
// A GitHub login: letters, digits and single hyphens, at most 39 characters.
const LOGIN = /^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$/;
// The one command that signs an account in to gh, without asking which host or protocol.
const SIGN_IN = 'gh auth login --hostname ' + GH_HOST + ' --git-protocol https --web';

class Refusal extends Error {}
class Unreachable extends Error {}

function refuse(msg) { throw new Refusal(msg); }

// ---------------------------------------------------------------- arguments

function parseArgs(argv) {
  const out = { _: [], live: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    // Everything after a bare -- is a gh command for `gather.js gh`, passed on word for word.
    if (a === '--') { out.rest = argv.slice(i + 1); break; }
    if (!a.startsWith('--')) { out._.push(a); continue; }
    const key = a.slice(2);
    if (key === 'confirm-skip') { out.confirmSkip = true; continue; }
    const val = argv[i + 1];
    if (val === undefined || val.startsWith('--')) refuse('--' + key + ' needs a value.');
    i++;
    if (key === 'live') out.live.push(val);
    else out[key] = val;
  }
  return out;
}

function instant(value, what) {
  const ms = Date.parse(value);
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(value) || Number.isNaN(ms)) {
    refuse(what + ' is not a full ISO timestamp: ' + JSON.stringify(value));
  }
  return ms;
}

function iso(ms) { return new Date(ms).toISOString().replace(/\.000Z$/, 'Z'); }

// ---------------------------------------------------------------- files

function defaultStatePath() {
  return path.join(os.homedir(), '.pennie-dev-update', 'state.json');
}

function readJson(file, what) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); }
  catch (e) { if (e.code === 'ENOENT') return undefined; refuse(what + ' at ' + file + ' could not be read: ' + e.message); }
  try { return JSON.parse(text); }
  catch (e) { refuse(what + ' at ' + file + ' is not valid JSON (' + e.message + '). Nothing was changed.'); }
}

function writeJsonAtomic(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n');
  fs.renameSync(tmp, file);
}

function loadRegistryReader() {
  try { return require(REGISTRY_PATH); }
  catch (e) { refuse('The dev update registry reader is not at ' + REGISTRY_PATH + ' (' + e.message + '), so no registry can be read.'); }
}

// The registry this run reads: --config when given, otherwise this Mac's own file.
function configPathFor(args) {
  return args.config || loadRegistryReader().registryPath();
}

function loadConfig(file) {
  const read = loadRegistryReader().readRegistry(file);
  if (read.state !== 'ok') refuse(read.why + (read.state === 'unreadable' ? ' Nothing was changed.' : ''));
  const cfg = read.registry;
  if (cfg.repos.length === 0) {
    refuse(file + ' lists no repos, so there is nothing to gather. An empty list only tells the merge gate to gate nothing on '
      + 'this Mac; add an entry for each repository the update covers (SKILL.md, "The registry").');
  }
  cfg.repos.forEach(function (r, i) {
    if (!r || typeof r.name !== 'string' || !r.name.trim()) refuse('Entry ' + (i + 1) + ' in ' + file + ' has no name.');
    // No step reads a local checkout, and the paths entries used to carry were typed by hand and
    // pointed at nothing after a folder move (claude-config#679). Checked here since #1526, where
    // the file is read, because a suite in the repository cannot read a Mac's own registry.
    if (Object.prototype.hasOwnProperty.call(r, 'path')) {
      refuse(r.name + ' in ' + file + ' carries a path, and nothing in this skill reads a local checkout: every repo is read '
        + 'from GitHub by owner/name. Remove its "path".');
    }
    if (typeof r.repo !== 'string' || !/^[\w.-]+\/[\w.-]+$/.test(r.repo)) {
      refuse(r.name + ' in ' + file + ' has repo ' + JSON.stringify(r.repo) + ', which is not owner/name.');
    }
    // No account would mean reading as whichever one gh has active, so it is never a default.
    if (typeof r.account !== 'string' || !LOGIN.test(r.account)) {
      refuse(r.name + ' in ' + file + ' has account ' + JSON.stringify(r.account) + ', which is not a GitHub login. Every repo names '
        + 'the account it is read as, the one that can see it, so the active account never decides.');
    }
    if (r.deployRecord !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(String(r.deployRecordFrom || ''))) {
      refuse(r.name + ' names a deploy record but no deployRecordFrom date (YYYY-MM-DD) saying where it starts.');
    }
    if (r.deployRecord !== undefined) checkDeployRecord(r, file);
  });
  return cfg;
}

// A deploy record is either a NAME (a string: read by hand and handed over with --live, PET's
// build_history) or an object gather reads from GitHub itself. A field missing from the object
// would make every PR read as held or every deploy as unseen, so each one is refused by name.
function checkDeployRecord(r, file) {
  const rec = r.deployRecord;
  const where = r.name + '\'s deployRecord in ' + file;
  if (typeof rec === 'string') { if (!rec.trim()) refuse(where + ' is an empty name.'); return; }
  if (!rec || typeof rec !== 'object' || RECORD_KINDS.indexOf(rec.kind) === -1) {
    refuse(where + ' has kind ' + JSON.stringify(rec && rec.kind) + ', which gather.js cannot read. It reads '
      + RECORD_KINDS.join(' and ') + ', or a name read by hand and passed with --live.');
  }
  function text(obj, key, label) {
    if (typeof obj[key] !== 'string' || !obj[key].trim()) refuse(where + ' has no ' + label + '.');
  }
  function codes(obj, key, label) {
    if (!Array.isArray(obj[key]) || !obj[key].every(Number.isInteger)) refuse(where + ' has no ' + label + ' list of exit codes.');
  }
  if (rec.kind === 'deploy_check_run') { text(rec, 'checkName', 'checkName'); text(rec, 'app', 'app'); return; }
  ['workflow', 'branch', 'job', 'step'].forEach(function (k) { text(rec, k, k); });
  codes(rec, 'liveExits', 'liveExits');
  codes(rec, 'unchangedExits', 'unchangedExits');
  if (rec.liveExits.indexOf(0) === -1) refuse(where + ' does not list exit 0 among liveExits, so a deploy that succeeded would never count.');
  if (rec.rollback !== undefined) {
    if (!rec.rollback || typeof rec.rollback !== 'object') refuse(where + ' has a rollback that is not an object.');
    ['workflow', 'job', 'step'].forEach(function (k) { text(rec.rollback, k, 'rollback ' + k); });
    codes(rec.rollback, 'unchangedExits', 'rollback unchangedExits');
  }
}

function readByHand(repoCfg) { return typeof repoCfg.deployRecord === 'string'; }
function recordName(repoCfg) {
  const rec = repoCfg.deployRecord;
  if (typeof rec === 'string') return rec;
  return rec.kind === 'deploy_check_run' ? 'the ' + rec.checkName + ' check run' : 'the ' + rec.job + ' job in ' + rec.workflow;
}

function loadEntry() {
  try { return require(ENTRY_PATH); }
  catch (e) { refuse('The changelog record parser is not at ' + ENTRY_PATH + ' (' + e.message + '), so no record can be read.'); }
}

// ---------------------------------------------------------------- GitHub, read only

// Every repo is read as the GitHub account the registry names for it (claude-config#1182), never as
// whichever account gh has active. Dan runs sessions under different accounts at once, so the
// active one is whatever the last switch left, and on the personal MacBook it is danwright32,
// which GitHub answers 404 for the work organisation's private repos: every Pennie repo read as unreachable.
// So the account's token is taken from gh's own store and handed to each call in that call's
// environment only, as hooks/lib/merge-target.sh and hooks/lib/lesson-fanout.sh scope theirs. The
// active account is never switched, and a token is never printed, logged or written anywhere.

function ghBin() { return process.env.PENNIE_DEV_UPDATE_GH || 'gh'; }

// The environment one gh call runs in. A GH_TOKEN or GITHUB_TOKEN the caller already carries is
// removed first: either would win over gh's store, so the call would run as THAT account, and gh
// answers `auth token` with it whoever is asked about.
function ghEnv(token) {
  const e = Object.assign({}, process.env);
  delete e.GH_TOKEN;
  delete e.GITHUB_TOKEN;
  if (token) e.GH_TOKEN = token;
  return e;
}

// account -> { account, token } or { refusal }, asked of gh once per account per run.
const ACCOUNTS = new Map();
function readAs(account, who) {
  if (!ACCOUNTS.has(account)) {
    const r = spawnSync(ghBin(), ['auth', 'token', '--hostname', GH_HOST, '-u', account],
      { encoding: 'utf8', timeout: GH_TIMEOUT_MS, env: ghEnv(null) });
    if (r.error) throw new Unreachable('gh could not run to find the token of ' + account + ': ' + r.error.message);
    const token = r.status === 0 ? String(r.stdout || '').trim() : '';
    // gh prints the token on stdout and only its complaint on stderr, so stderr is safe to quote.
    ACCOUNTS.set(account, token ? { account: account, token: token } : {
      refusal: 'is read as the GitHub account ' + account + ', which is not signed in to gh on this Mac (gh found no token for it: '
        + (String(r.stderr || '').trim() || 'exit ' + r.status) + '), so it was not read as any other account either. Sign it in with: '
        + SIGN_IN + ' and choose ' + account + ' in the browser. gh makes a newly signed in account the active one, so switch back '
        + 'afterwards if another session relies on the account active now.',
    });
  }
  const got = ACCOUNTS.get(account);
  if (got.refusal) refuse(who + ' ' + got.refusal);
  return got;
}

function gh(as, apiPath) {
  // A read with no account would run as whichever one is active, the fault this exists to end.
  if (!as || !as.token) throw new Error('gather.js read ' + apiPath + ' without naming the account to read it as.');
  const r = spawnSync(ghBin(), ['api', apiPath], { encoding: 'utf8', timeout: GH_TIMEOUT_MS, maxBuffer: 256 * 1024 * 1024, env: ghEnv(as.token) });
  if (r.error) throw new Unreachable('gh could not run for ' + apiPath + ' (read as ' + as.account + '): ' + r.error.message);
  if (r.status !== 0) {
    const said = String(r.stderr || r.stdout || '').trim();
    throw new Unreachable('gh api ' + apiPath + ', read as ' + as.account + ', failed (exit ' + r.status + '): ' + said
      + (/HTTP 404|Not Found/.test(said) ? '. GitHub also answers 404 when ' + as.account + ' cannot see a private repo, so check that it '
        + 'still has access, and that the registry names the account that does' : ''));
  }
  try { return JSON.parse(r.stdout); }
  catch (e) { throw new Unreachable('gh api ' + apiPath + ' returned something that is not JSON: ' + String(r.stdout).slice(0, 200)); }
}

// Every closed PR, page by page in creation order, so a PR opened during the read lands on a
// later page rather than shifting one already read (L746). A short read reports as a quiet week,
// so the pages are read until one comes back short, and the count is checked against search.
function mergedPulls(rc) {
  const slug = rc.slug;
  const seen = new Map();
  for (let page = 1; page <= MAX_PAGES; page++) {
    const batch = gh(rc.as, 'repos/' + slug + '/pulls?state=closed&sort=created&direction=asc&per_page=' + PER_PAGE + '&page=' + page);
    if (!Array.isArray(batch)) throw new Unreachable('the pulls list for ' + slug + ' page ' + page + ' was not a list.');
    batch.forEach(function (p) {
      if (!p || !p.merged_at) return;
      // A merged_at that does not parse compares false against every boundary, so the PR would
      // drop out of every window with nothing said (L50). Refuse it by number instead.
      if (Number.isNaN(Date.parse(p.merged_at)) || !/^\d{4}-\d{2}-\d{2}T/.test(p.merged_at)) {
        refuse('#' + p.number + ' in ' + slug + ' has a merged_at GitHub sent as ' + JSON.stringify(p.merged_at) + ', which does not parse, so no window can place it.');
      }
      seen.set(p.number, p);
    });
    if (batch.length < PER_PAGE) {
      return Array.from(seen.values()).sort(function (a, b) { return Date.parse(a.merged_at) - Date.parse(b.merged_at) || a.number - b.number; });
    }
  }
  refuse(slug + ' has more than ' + (MAX_PAGES * PER_PAGE) + ' closed PRs, past what this reads; raise MAX_PAGES on purpose.');
}

function searchCount(rc, startMs) {
  const slug = rc.slug;
  const after = iso(startMs).replace(/Z$/, '+00:00');
  const q = 'repo:' + slug + ' is:pr is:merged merged:>' + after;
  const r = gh(rc.as, 'search/issues?q=' + encodeURIComponent(q) + '&per_page=1');
  if (!r || typeof r.total_count !== 'number') throw new Unreachable('the search count for ' + slug + ' came back without a total.');
  return r.total_count;
}

// Is mergeSha an ancestor of liveSha? Asked of GitHub, which always has both, never of a local
// clone, which may not have fetched the live sha (claude-config#679).
function isLive(rc, pr, liveSha) {
  const slug = rc.slug;
  if (!pr.merge_commit_sha) refuse('#' + pr.number + ' in ' + slug + ' has no merge commit, so whether it is live could not be checked.');
  let status;
  // per_page=1: only the status is read, so the commit list it would otherwise carry is not fetched.
  try { status = gh(rc.as, 'repos/' + slug + '/compare/' + pr.merge_commit_sha + '...' + liveSha + '?per_page=1').status; }
  // A failed call is GitHub not answering, so the repo is unreachable, never refused (L11).
  catch (e) {
    if (e instanceof Unreachable) throw new Unreachable('whether #' + pr.number + ' is live could not be checked: ' + e.message);
    throw e;
  }
  if (status === 'ahead' || status === 'identical') return true;
  if (status === 'behind' || status === 'diverged') return false;
  refuse('GitHub answered ' + JSON.stringify(status) + ' comparing #' + pr.number + ' with the live sha, so whether it is live could not be checked.');
}

// ---------------------------------------------------------------- deploy records on GitHub

// Where one run of an Actions job left production, judged by the step that touches it:
//   live       the step reached production (exit 0, or a failure whose exit code is a liveExit)
//   none       production was never touched, or was put back as it was (not started, skipped,
//              or a failure whose exit code is an unchangedExit)
//   running    the job is still going
//   unknown    anything else: a cancelled step, an exit code that does not say, or none on record
function jobOutcome(rc, run, jobName, stepName, liveExits, unchangedExits) {
  const slug = rc.slug;
  const what = 'run ' + run.id + ' (' + String(run.head_sha || '').slice(0, 9) + ')';
  const got = gh(rc.as, 'repos/' + slug + '/actions/runs/' + run.id + '/jobs?per_page=100');
  if (!got || !Array.isArray(got.jobs)) throw new Unreachable('the jobs of ' + what + ' in ' + slug + ' were not a list.');
  const job = got.jobs.filter(function (j) { return j && j.name === jobName; })[0];
  // A run not finished whose job is not listed yet is queued or just starting: it may be about
  // to touch production, so it is running, never "touched nothing" (lessons review of #1180).
  if (!job && run.status !== 'completed') return { outcome: 'running', what: what };
  // A finished run with no such job was cancelled while pending, superseded by a newer merge,
  // before its jobs existed: it touched nothing.
  if (!job) return { outcome: 'none', what: what };
  if (job.status !== 'completed') return { outcome: 'running', what: what };
  const at = job.completed_at;
  const step = (job.steps || []).filter(function (s) { return s && typeof s.name === 'string' && s.name.indexOf(stepName) === 0; })[0];
  if (!step) {
    if (job.conclusion === 'success') {
      refuse('the ' + jobName + ' job of ' + what + ' succeeded but has no step named "' + stepName
        + '", so the deploy record has changed shape. Update deployRecord in the dev update registry.');
    }
    return { outcome: 'none', what: what, at: at };
  }
  if (step.conclusion === 'success') return { outcome: 'live', what: what, at: at, exit: 0, startedAt: job.started_at };
  if (step.conclusion === 'skipped' || step.conclusion === null || step.conclusion === undefined) return { outcome: 'none', what: what, at: at };
  if (step.conclusion !== 'failure') {
    return { outcome: 'unknown', what: what, at: at, why: 'the step "' + stepName + '" of ' + what + ' ended ' + step.conclusion + ', so where it left production is not recorded' };
  }
  const notes = gh(rc.as, 'repos/' + slug + '/check-runs/' + job.id + '/annotations');
  if (!Array.isArray(notes)) throw new Unreachable('the annotations of ' + what + ' in ' + slug + ' were not a list.');
  const hit = notes.map(function (a) { return a && EXIT_ANNOTATION.exec(String(a.message || '')); }).filter(Boolean)[0];
  if (!hit) {
    return { outcome: 'unknown', what: what, at: at, why: 'the step "' + stepName + '" of ' + what + ' failed with no exit code on record, so where it left production cannot be told' };
  }
  const code = Number(hit[1]);
  if (liveExits.indexOf(code) !== -1) return { outcome: 'live', what: what, at: at, exit: code, startedAt: job.started_at };
  if (unchangedExits.indexOf(code) !== -1) return { outcome: 'none', what: what, at: at, exit: code };
  return { outcome: 'unknown', what: what, at: at, exit: code, why: what + ' failed with exit code ' + code + ', which does not say production ended on one whole version' };
}

function workflowRuns(rc, file, branch) {
  const slug = rc.slug;
  const q = '?' + (branch ? 'event=push&branch=' + encodeURIComponent(branch) + '&' : '') + 'per_page=' + DEPLOY_SCAN;
  const got = gh(rc.as, 'repos/' + slug + '/actions/workflows/' + file + '/runs' + q);
  if (!got || !Array.isArray(got.workflow_runs)) throw new Unreachable('the runs of ' + file + ' in ' + slug + ' were not a list.');
  return got.workflow_runs;
}

// Slate: the newest deploy run that left a version serving 100%, then anything since that may have
// changed production without saying to what: a deploy that may have left a split, or a rollback,
// whose target commit GitHub does not record.
function readDeployJob(rc, rec) {
  const runs = workflowRuns(rc, rec.workflow, rec.branch);   // newest first, as GitHub lists them
  const doubts = [];
  let live = null;
  for (let i = 0; i < runs.length && !live; i++) {
    const o = jobOutcome(rc, runs[i], rec.job, rec.step, rec.liveExits, rec.unchangedExits);
    if (o.outcome === 'live') live = { sha: runs[i].head_sha, at: o.at, startedAt: o.startedAt, what: o.what, exit: o.exit };
    else if (o.outcome === 'unknown') doubts.push(o.why);
  }
  if (!live) {
    refuse('none of the newest ' + runs.length + ' runs of the ' + rec.job + ' job in ' + rec.workflow
      + ' put a version into production, so whether anything is live cannot be told' + (doubts.length ? ' (' + doubts.join('; ') + ')' : '') + '.');
  }
  if (rec.rollback) {
    const rb = rec.rollback;
    const liveStartMs = Date.parse(live.startedAt);
    workflowRuns(rc, rb.workflow, null).forEach(function (run) {
      // A time that does not parse compares false against everything (L50), which would skip
      // this rollback and keep the deploy live, so either missing time counts as "after".
      const runMs = Date.parse(run.created_at);
      const timed = !Number.isNaN(runMs) && !Number.isNaN(liveStartMs);
      if (timed && runMs <= liveStartMs) return;
      const o = jobOutcome(rc, run, rb.job, rb.step, [0], rb.unchangedExits);
      if (!timed && o.outcome !== 'none') {
        doubts.push('a rollback (' + rb.workflow + ' run ' + run.id + ') has no readable time, so whether it ran after that deploy cannot be told');
        return;
      }
      if (o.outcome === 'none') return;
      if (o.outcome === 'running') doubts.push('a rollback (' + rb.workflow + ' ' + o.what + ') is running now');
      else {
        doubts.push('a rollback (' + rb.workflow + ' ' + o.what + ', ' + (o.exit === undefined ? 'no exit code on record' : 'exit code ' + o.exit)
          + ') ran after that deploy, and GitHub does not record which commit it put back');
      }
    });
  }
  return {
    sha: live.sha, recordedAt: live.at,
    source: 'the ' + rec.job + ' job of ' + rec.workflow + ' ' + live.what + (live.exit ? ', exit code ' + live.exit : ''),
    unconfirmed: doubts.length ? 'the newest deploy that reached 100% is ' + live.what + ', but since then ' + doubts.join('; ') : null,
  };
}

// Sonar: the newest merge whose Cloudflare Pages check run, from Cloudflare's own app, succeeded.
// Only merge commits are read: a branch commit carried onto main by a merge has a PREVIEW build on
// it, which says nothing about production (3 of Sonar's main commits had one, 2026-10-13).
function readDeployCheck(rc, rec, all) {
  const slug = rc.slug;
  const merges = all.slice().reverse().slice(0, DEPLOY_SCAN);
  for (let i = 0; i < merges.length; i++) {
    const pr = merges[i];
    if (!pr.merge_commit_sha) continue;
    const got = gh(rc.as, 'repos/' + slug + '/commits/' + pr.merge_commit_sha + '/check-runs?check_name=' + encodeURIComponent(rec.checkName));
    if (!got || !Array.isArray(got.check_runs)) throw new Unreachable('the check runs on #' + pr.number + ' in ' + slug + ' were not a list.');
    const ok = got.check_runs.filter(function (c) {
      return c && c.name === rec.checkName && c.app && c.app.slug === rec.app && c.status === 'completed' && c.conclusion === 'success';
    });
    if (ok.length) {
      return { sha: pr.merge_commit_sha, recordedAt: ok[0].completed_at, source: 'the ' + rec.checkName + ' check run on #' + pr.number, unconfirmed: null };
    }
  }
  refuse('none of the newest ' + merges.length + ' merges in ' + slug + ' carries a successful ' + rec.checkName + ' check run from ' + rec.app
    + ', so whether anything is live cannot be told.');
}

// ---------------------------------------------------------------- one repo

function parseLive(values) {
  const live = {};
  values.forEach(function (v) {
    const m = /^([\w.-]+\/[\w.-]+)=([0-9a-f]{7,40})@(.+)$/i.exec(v);
    if (!m) refuse('--live ' + JSON.stringify(v) + ' is not owner/name=SHA@ISO-TIMESTAMP.');
    live[m[1].toLowerCase()] = { sha: m[2], recordedAt: m[3], recordedMs: instant(m[3], '--live recorded time') };
  });
  return live;
}

function recordOf(entry, repoCfg, pr) {
  const author = pr.user && pr.user.login;
  if (author === DEPENDABOT) return { kind: 'dependency' };
  const from = repoCfg.changelogFrom;
  // The gate judged each merge by the local day it ran on, so the same day is used here, through
  // the parser's own helper, or a merge late on the evening before the cutover reads as a gap.
  if (!from || entry.localDay(new Date(pr.merged_at)) < from) return { kind: 'unrecorded' };
  // parseEntry and never the merge gate's own gateRefusal: this reads what MERGED, on whichever Mac,
  // so it must not ask this Mac's registry whether a label was allowed (claude-config#3665). A
  // refusal here is a gap, "something merged around the gate", which a change that passed the gate
  // on the other Mac is not.
  const parsed = entry.parseEntry({ labels: pr.labels, body: pr.body });
  if (parsed.ok) {
    // Whether managers would notice it is decided HERE, in code, from the parser's own map of the
    // kinds, so a kind the skill's text has never heard of still arrives sorted (R5). SKILL.md's
    // label table and section 5 sort by this field, never by the label's name (claude-config#3668).
    // A gap, a dependency update and a record judged by hand carry no such field: nothing decided
    // it for them.
    const record = { kind: parsed.kind, line: parsed.line, managerVisible: entry.isManagerVisible(parsed.kind) };
    if (parsed.announcement !== undefined) record.announcement = parsed.announcement;
    return record;
  }
  return { kind: 'gap', code: parsed.code, reason: parsed.reason };
}

function gatherRepo(ctx, repoCfg) {
  const slug = repoCfg.repo;
  const key = slug.toLowerCase();
  const prior = (ctx.state && ctx.state[slug]) || {};
  const out = {
    name: repoCfg.name, repo: slug, status: 'ok', reason: null,
    stateLastEnd: prior.lastEnd || null,
    window: null, deploy: { kind: 'none' }, prs: [], heldBack: [], seed: null,
    counts: null, notes: [],
    // null until every announce change has been read: a first appearance lists none, and a refused
    // or unreachable repo's are unknown, which is never shown as an empty list (claude-config#3668).
    announcements: null,
  };

  // The window: strictly after lastEnd, up to now. A repo with no lastEnd is a first appearance.
  let startMs = null;
  let source = 'lastEnd';
  if (ctx.sinceMs !== null) {
    if (prior.lastEnd) {
      const lastMs = instant(prior.lastEnd, slug + ' lastEnd in the state file');
      if (ctx.sinceMs > lastMs && !ctx.confirmSkip) {
        refuse('--since ' + ctx.since + ' is later than lastEnd ' + prior.lastEnd + ', so everything merged from '
          + prior.lastEnd + ' to ' + ctx.since + ' would never be reported. Run again with --confirm-skip to skip that period on purpose.');
      }
    }
    startMs = ctx.sinceMs; source = 'since';
  } else if (prior.lastEnd) {
    startMs = instant(prior.lastEnd, slug + ' lastEnd in the state file');
  }

  // A record read by hand is checked before anything else is read: a stopped recorder means
  // every answer below is "cannot tell", not "nothing shipped".
  let live = null;
  if (repoCfg.deployRecord && readByHand(repoCfg)) {
    live = ctx.live[key];
    if (!live) {
      refuse(repoCfg.name + ' has a deploy record (' + repoCfg.deployRecord + ') and it was not read. Run the query in SKILL.md section 4 and pass --live '
        + slug + '=<commit_sha>@<recorded_at>.');
    }
    if (live.recordedMs < ctx.nowMs - RECORDER_STALE_DAYS * 86400000) {
      refuse(repoCfg.deployRecord + ' has no row in the last ' + RECORDER_STALE_DAYS + ' days (newest ' + live.recordedAt
        + '), so the recorder has stopped and an empty answer would mean "cannot tell", not "nothing shipped".');
    }
    out.deploy = { kind: repoCfg.deployRecord, liveSha: live.sha, recordedAt: live.recordedAt, coversFrom: repoCfg.deployRecordFrom, source: '--live', unconfirmed: null };
  } else if (repoCfg.deployRecord && ctx.live[key]) {
    refuse('--live was given for ' + slug + ', whose deploy record (' + recordName(repoCfg) + ') gather.js reads from GitHub itself. Leave --live off for it.');
  }

  // The account before the first read: one not signed in refuses this repo by name, never reads
  // it as some other account, and never reports it as a quiet week (claude-config#1182).
  const rc = { slug: slug, as: readAs(repoCfg.account, repoCfg.name + ' (' + slug + ')') };
  const all = mergedPulls(rc);

  // A record on GitHub is read only once a PR needs a verdict, so a quiet window costs nothing.
  // A failed read makes the repo unreachable, never a PR live or held (L11).
  function liveFromGitHub() {
    const rec = repoCfg.deployRecord;
    let got;
    try { got = rec.kind === 'deploy_check_run' ? readDeployCheck(rc, rec, all) : readDeployJob(rc, rec); }
    catch (e) {
      if (e instanceof Unreachable) throw new Unreachable('the deploy record (' + recordName(repoCfg) + ') could not be read: ' + e.message);
      throw e;
    }
    out.deploy = { kind: rec.kind, liveSha: got.sha, recordedAt: got.recordedAt, coversFrom: repoCfg.deployRecordFrom, source: got.source, unconfirmed: got.unconfirmed };
    return got;
  }
  function deployOf(pr) {
    if (!repoCfg.deployRecord) return 'unchecked';
    if (ctx.entry.localDay(new Date(pr.merged_at)) < repoCfg.deployRecordFrom) return 'uncovered';
    if (!live) live = liveFromGitHub();
    // Production may have changed since the newest deploy that reached 100%, to a commit nobody
    // recorded, so no PR is claimed live or held: each is held back and checked again next run.
    if (live.unconfirmed) return 'unconfirmed';
    return isLive(rc, pr, live.sha) ? 'live' : 'held';
  }

  if (startMs === null) {
    out.status = 'first_appearance';
    out.window = { start: null, end: iso(ctx.nowMs), startExclusive: true, source: 'none' };
    out.counts = { merged: all.length };
    const newestFirst = all.slice().reverse();
    for (let i = 0; i < newestFirst.length && i < MAX_SEED_WALK; i++) {
      const pr = newestFirst[i];
      const d = deployOf(pr);
      if (d === 'unconfirmed') refuse(repoCfg.name + ' cannot be introduced: whether anything is live could not be confirmed, because ' + live.unconfirmed + '.');
      if (d === 'held') { out.heldBack.push(pr.number); continue; }
      out.seed = { number: pr.number, mergedAt: pr.merged_at, deploy: d };
      break;
    }
    out.heldBack.sort(function (a, b) { return a - b; });
    if (!out.seed) {
      if (all.length === 0) out.notes.push(repoCfg.name + ' has no merged PR yet, so there is nothing live to introduce. Its lastEnd stays unset.');
      else refuse('none of ' + repoCfg.name + '\'s newest ' + Math.min(all.length, MAX_SEED_WALK) + ' merges is live yet, so there is nothing live to introduce.');
    }
    return out;
  }

  out.window = { start: iso(startMs), end: iso(ctx.nowMs), startExclusive: true, source: source };
  const inWindow = all.filter(function (p) { return Date.parse(p.merged_at) > startMs; });
  const total = searchCount(rc, startMs);
  if (total !== inWindow.length) {
    refuse('the PR list holds ' + inWindow.length + ' merges after ' + iso(startMs) + ' but GitHub search counts ' + total
      + '. A short read reports as a quiet week, so this repo is refused. Run again; if it persists, the search index is behind.');
  }

  const inWindowNumbers = new Set(inWindow.map(function (p) { return p.number; }));
  const byNumber = new Map(all.map(function (p) { return [p.number, p]; }));
  const carried = [];
  (Array.isArray(prior.heldBack) ? prior.heldBack : []).forEach(function (n) {
    if (inWindowNumbers.has(n)) return;
    const pr = byNumber.get(n);
    if (!pr) refuse('heldBack in the state file names #' + n + ', which GitHub does not show as a merged PR in ' + slug + '.');
    carried.push(pr);
  });

  const candidates = carried.concat(inWindow).sort(function (a, b) { return Date.parse(a.merged_at) - Date.parse(b.merged_at) || a.number - b.number; });
  const counts = { inWindow: inWindow.length, searchCount: total, carried: carried.length, recorded: 0, handJudged: 0, gaps: 0, dependency: 0, held: 0, unconfirmed: 0, uncovered: 0, unchecked: 0 };
  candidates.forEach(function (pr) {
    const record = recordOf(ctx.entry, repoCfg, pr);
    const deploy = deployOf(pr);
    if (record.kind === 'unrecorded') counts.handJudged++;
    else if (record.kind === 'gap') counts.gaps++;
    else if (record.kind === 'dependency') counts.dependency++;
    else counts.recorded++;
    if (deploy === 'held') { counts.held++; out.heldBack.push(pr.number); }
    if (deploy === 'unconfirmed') { counts.unconfirmed++; out.heldBack.push(pr.number); }
    if (deploy === 'uncovered') counts.uncovered++;
    if (deploy === 'unchecked') counts.unchecked++;
    out.prs.push({
      number: pr.number, mergedAt: pr.merged_at, title: pr.title, author: pr.user && pr.user.login,
      labels: (pr.labels || []).map(function (l) { return l && l.name; }), body: pr.body || '',
      mergeSha: pr.merge_commit_sha, carried: !inWindowNumbers.has(pr.number), record: record, deploy: deploy,
    });
  });
  out.counts = counts;
  if (counts.uncovered) out.notes.push('The deploy record does not cover ' + counts.uncovered + ' PR(s) merged before ' + repoCfg.deployRecordFrom + '; they are listed without a check.');
  if (counts.unconfirmed) {
    out.notes.push(counts.unconfirmed + ' PR(s) could not be confirmed live, because ' + out.deploy.unconfirmed
      + '. They are held back, not listed as shipped, and checked again next run.');
  }
  if (counts.unchecked) out.notes.push(repoCfg.name + ' has no deploy record, so whether its ' + counts.unchecked + ' PR(s) reached production could not be checked.');
  if (counts.gaps) out.notes.push(counts.gaps + ' PR(s) merged after the changelog cutover carry no valid record: something merged around the gate.');
  // Announce records in a repository this Mac's registry names no announcements channel for
  // (claude-config#3665). The merge gate refuses that label there, so either they merged from a Mac
  // whose registry names the channel, or this Mac's entry lost its key, and from here the two look
  // the same. They are read as the records they are either way; this says so, where to draft them
  // being the thing this Mac cannot tell. Judged by the registry's one reader of the key.
  const announced = out.prs.filter(function (p) { return p.record.kind === ctx.entry.ANNOUNCE; }).length;
  if (announced) {
    const reader = loadRegistryReader();
    const channel = reader.announceChannelOf(repoCfg);
    const check = 'node ~/.claude/hooks/lib/dev-update-registry.js announce-channel ' + slug;
    if (channel.bad) {
      out.notes.push(announced + ' PR(s) carry changelog/announce, and ' + reader.badAnnounceWhy(slug, channel.value)
        + ', so there is no channel to draft their announcements in. Fix announceChannel in its entry (check it with: ' + check + ').');
    } else if (!channel.channel) {
      out.notes.push(announced + ' PR(s) carry changelog/announce, and this Mac\'s registry names no announcements channel for '
        + repoCfg.name + ' (announceChannel in its entry), so there is no channel to draft their announcements in. Either they '
        + 'merged on a Mac whose registry names one, or this entry lost its key. Check it with: ' + check + '.');
    }
  }
  out.announcements = announcementsOf(ctx, repoCfg, out, prior, byNumber, deployOf);
  return out;
}

// ---------------------------------------------------------------- announcements (claude-config#3668)
//
// Every announce change this run can see: the window's (and heldBack's), plus every one an earlier
// run kept in the state file because it was only drafted or had no outcome, whatever its merge
// date. The dev update is the safety net for an announcement nobody sent (Dan, 2026-11-25: "an
// unsent one is seen"), so commit-state refuses to record the run until each one that is out has an
// outcome (R6).
//
// What is owed, and where, is asked of the merge gate's own reader (announcementOwed in
// hooks/lib/changelog-entry.js), never worked out here a second time: `owed` with the channel and
// the post, or `unknown` with why, the post still given wherever it could be read.
const OUTCOMES = ['sent', 'drafted', 'not-announcing'];
// What --outcomes carries for "Draft it now" (#3667): not an outcome the state keeps, but a claim
// that this run's own draft call saved it, which commit-state judges again before recording drafted.
const DRAFTED_NOW = 'drafted-now';
// An outcome after which nothing more is asked about it. Drafted is not one: a draft can sit unsent.
const SETTLED = ['sent', 'not-announcing'];
// The two deploy verdicts under which a change cannot be listed as shipped, so nothing is owed yet.
const NOT_OUT = ['held', 'unconfirmed'];

function announcementsOf(ctx, repoCfg, out, prior, byNumber, deployOf) {
  const kept = new Map();
  // Absent is a repo no run has kept one for. Present and not a list is a state file somebody broke,
  // and reading it as "none kept" would drop every unsent announcement in it, so it refuses (L11).
  if (prior.announcements !== undefined && !Array.isArray(prior.announcements)) {
    refuse('announcements in the state file for ' + repoCfg.repo + ' is not a list, so which announcements for agents are still unsent cannot be told. Nothing was changed.');
  }
  (prior.announcements || []).forEach(function (a) {
    if (!a || !Number.isInteger(a.number)) refuse('announcements in the state file for ' + repoCfg.repo + ' holds an entry with no pull request number: ' + JSON.stringify(a) + '.');
    kept.set(a.number, a);
  });
  const listed = new Map(out.prs.map(function (p) { return [p.number, p]; }));
  const numbers = new Set();
  out.prs.forEach(function (p) { if (p.record.kind === ctx.entry.ANNOUNCE) numbers.add(p.number); });
  kept.forEach(function (a, n) { numbers.add(n); });

  const read = loadRegistryReader().readRegistry(ctx.configPath);
  const today = ctx.entry.localDay(new Date(ctx.nowMs));
  const found = [];
  numbers.forEach(function (n) {
    const pr = byNumber.get(n);
    if (!pr) refuse('announcements in the state file names #' + n + ', which GitHub does not show as a merged PR in ' + repoCfg.repo + '.');
    const owed = ctx.entry.announcementOwed({ labels: pr.labels, body: pr.body }, read, repoCfg.repo, today);
    if (owed.state === 'none') {
      out.notes.push('#' + n + ' was kept as an announcement for agents and no longer carries changelog/announce, so it is dropped from the announcements.');
      return;
    }
    const mergedMs = Date.parse(pr.merged_at);
    if (Number.isNaN(mergedMs)) refuse('#' + n + ' has a merge time GitHub gave as ' + JSON.stringify(pr.merged_at) + ', which does not parse, so the channel cannot be read from it.');
    const inPost = listed.get(n);
    const deploy = inPost ? inPost.deploy : deployOf(pr);
    const before = kept.has(n) ? (kept.get(n).outcome || null) : null;
    found.push({
      number: n, title: pr.title, mergedAt: pr.merged_at,
      // The Slack timestamp of the merge, for slack_read_channel's `oldest`: nothing posted before
      // the change merged can be its announcement.
      oldest: String(Math.floor(mergedMs / 1000)),
      deploy: deploy, live: deploy === 'live', carried: !inPost,
      state: owed.state, channel: owed.channel, text: owed.text, why: owed.why,
      previousOutcome: before,
      needsOutcome: NOT_OUT.indexOf(deploy) === -1 && SETTLED.indexOf(before) === -1,
    });
  });
  found.sort(function (a, b) { return Date.parse(a.mergedAt) - Date.parse(b.mergedAt) || a.number - b.number; });
  return found;
}

// ---------------------------------------------------------------- gather

function cmdGather(args) {
  const configPath = configPathFor(args);
  const statePath = args.state || defaultStatePath();
  const nowMs = args.now ? instant(args.now, '--now') : Date.now();
  const cfg = loadConfig(configPath);
  const entry = loadEntry();
  const live = parseLive(args.live);
  const sinceMs = args.since ? instant(args.since, '--since') : null;

  const state = readJson(statePath, 'The state file');
  if (state === undefined && sinceMs === null) {
    refuse('The state file is not at ' + statePath + '. Without it every window is unknown, and treating every repo as new would '
      + 'introduce each product again. If the state was lost, pass --since <ISO timestamp> to say where the window starts.');
  }
  if (state !== undefined && (state === null || typeof state !== 'object' || Array.isArray(state))) {
    refuse('The state file at ' + statePath + ' does not hold an object. Nothing was changed.');
  }

  let repos = cfg.repos;
  if (args.only) {
    const want = args.only.toLowerCase();
    repos = repos.filter(function (r) { return r.name.toLowerCase() === want || r.repo.toLowerCase() === want; });
    if (repos.length === 0) refuse('--only ' + args.only + ' names no repo in ' + configPath + '.');
  }

  const ctx = { state: state || {}, nowMs: nowMs, entry: entry, live: live, sinceMs: sinceMs, since: args.since, confirmSkip: !!args.confirmSkip, configPath: configPath };
  const result = {
    v: 1, generatedAt: iso(nowMs), statePath: statePath, stateExisted: state !== undefined, configPath: configPath, repos: [],
  };
  repos.forEach(function (repoCfg) {
    let r;
    try { r = gatherRepo(ctx, repoCfg); }
    catch (e) {
      if (!(e instanceof Refusal) && !(e instanceof Unreachable)) throw e;
      r = { name: repoCfg.name, repo: repoCfg.repo, status: e instanceof Unreachable ? 'unreachable' : 'refused', reason: e.message,
        stateLastEnd: (ctx.state[repoCfg.repo] || {}).lastEnd || null, prs: [], heldBack: [], notes: [], announcements: null };
    }
    result.repos.push(r);
  });

  const text = JSON.stringify(result, null, 2) + '\n';
  if (args.out) { fs.mkdirSync(path.dirname(args.out), { recursive: true }); fs.writeFileSync(args.out, text); }
  process.stdout.write(text);

  result.repos.forEach(function (r) {
    let line = r.name + ': ' + r.status;
    if (r.status === 'ok') {
      const c = r.counts;
      line += ', ' + r.prs.length + ' PR(s) from ' + r.window.start + ' to ' + r.window.end + ': ' + c.recorded + ' carried a record, '
        + c.handJudged + ' judged by hand, ' + c.gaps + ' gap(s), ' + c.dependency + ' dependency update(s); ' + c.held + ' held back'
        + (c.unconfirmed ? ', ' + c.unconfirmed + ' unconfirmed' : '');
      const owing = r.announcements.filter(function (a) { return a.needsOutcome; }).length;
      if (r.announcements.length) line += '; ' + r.announcements.length + ' announcement(s) for agents, ' + owing + ' needing an outcome';
    } else if (r.status === 'first_appearance') {
      line += r.seed ? ', introduced in general; boundary would seed at #' + r.seed.number + ' (' + r.seed.mergedAt + ')' : '';
    } else {
      line += ': ' + r.reason;
    }
    process.stderr.write(line + '\n');
    (r.notes || []).forEach(function (n) { process.stderr.write('  ' + n + '\n'); });
  });
  const bad = result.repos.some(function (r) { return r.status === 'refused' || r.status === 'unreachable'; });
  return bad ? 3 : 0;
}

// ---------------------------------------------------------------- commit-state

// --outcomes 70=sent,71=drafted,72=not-announcing: what became of each announcement this run, as
// Dan answered or as the channel read showed. Refused, naming each one, while an announcement that
// is out has no outcome (R6), and for any value or number that is not one of this run's.
// 73=drafted-now is "Draft it now": recorded as drafted only when the draft's own files, in the
// folder --drafts names, are judged saved here, again, so it never rests on the session's word.
function announcementOutcomes(repo, given, drafts) {
  const outcomes = new Map();
  const pairs = given ? given.split(',').map(function (s) { return s.trim(); }).filter(Boolean) : [];
  if (repo.status !== 'ok') {
    if (pairs.length) refuse(repo.repo + ' is a first appearance: it lists no announcements, so --outcomes does not apply.');
    return outcomes;
  }
  if (!Array.isArray(repo.announcements)) {
    refuse(repo.repo + ' in the gathered file has no announcements list, so whether an announcement for agents is still unsent cannot '
      + 'be told. It was gathered by an older gather.js: gather again. Nothing was written.');
  }
  const byNumber = new Map(repo.announcements.map(function (a) { return [a.number, a]; }));
  pairs.forEach(function (pair) {
    const m = /^#?(\d+)=([a-z-]+)$/.exec(pair);
    if (!m) refuse('--outcomes holds ' + JSON.stringify(pair) + ', which is not <PR number>=<outcome>.');
    const n = Number(m[1]);
    if (OUTCOMES.indexOf(m[2]) === -1 && m[2] !== DRAFTED_NOW) refuse('--outcomes gives #' + n + ' the outcome ' + JSON.stringify(m[2]) + ', which is not one of ' + OUTCOMES.concat(DRAFTED_NOW).join(', ') + '.');
    if (!byNumber.has(n)) refuse('--outcomes names #' + n + ', which is not among the announcements gathered for ' + repo.repo + '.');
    if (outcomes.has(n)) refuse('--outcomes gives #' + n + ' two outcomes.');
    if (m[2] !== DRAFTED_NOW) { outcomes.set(n, m[2]); return; }
    if (!drafts) refuse('--outcomes gives #' + n + ' ' + DRAFTED_NOW + ', which needs --drafts <the folder holding its draft\'s files>, so the draft can be judged. Nothing was written.');
    const v = draftedVerdict(repo, byNumber.get(n), drafts, false);
    if (v.state !== 'saved') refuse('#' + n + ' is not recorded as drafted: ' + v.said + ' Nothing was written.');
    outcomes.set(n, 'drafted');
  });
  const missing = repo.announcements.filter(function (a) { return a.needsOutcome && !outcomes.has(a.number); });
  if (missing.length) {
    refuse('The run is not recorded while an announcement for agents that is out has no outcome: '
      + missing.map(function (a) { return '#' + a.number + ' (merged ' + a.mergedAt + ')'; }).join(', ')
      + '. Settle each (SKILL.md section 11) and pass --outcomes <number>=sent|drafted|not-announcing, or <number>=' + DRAFTED_NOW + ' with --drafts for one this run drafted. Nothing was written.');
  }
  return outcomes;
}

// What the state keeps of this run's announcements. One only drafted, or with no outcome, is always
// kept, so the next run lists it again whatever its merge date. One sent or not being announced is
// kept only while it could come back (merged after the new lastEnd, or still held back), so it is
// never asked about, or drafted, a second time; otherwise it is done with and dropped.
function keptAnnouncements(repo, outcomes, updated) {
  const boundary = updated.lastEnd ? Date.parse(updated.lastEnd) : -Infinity;
  const held = new Set(updated.heldBack || []);
  const kept = [];
  repo.announcements.forEach(function (a) {
    const outcome = outcomes.get(a.number) || a.previousOutcome || null;
    const settled = SETTLED.indexOf(outcome) !== -1;
    // Dropped only when its merge time is known to sit at or below the boundary: a time that does
    // not parse compares false, and the entry is kept, the side that asks again rather than loses it.
    if (settled && Date.parse(a.mergedAt) <= boundary && !held.has(a.number)) return;
    kept.push({ number: a.number, mergedAt: a.mergedAt, outcome: outcome });
  });
  return kept;
}

function cmdCommitState(args) {
  if (!args.gathered) refuse('commit-state needs --gathered, the file gather wrote with --out.');
  if (!args.repo) refuse('commit-state needs --repo owner/name.');
  if (!args.draft) refuse('commit-state needs --draft, the post as written. lastEnd moves only once the draft exists.');
  const statePath = args.state || defaultStatePath();

  const gathered = readJson(args.gathered, 'The gathered file');
  if (gathered === undefined) refuse('The gathered file is not at ' + args.gathered + '.');
  const repo = (gathered.repos || []).filter(function (r) { return r.repo.toLowerCase() === args.repo.toLowerCase(); })[0];
  if (!repo) refuse(args.repo + ' is not in ' + args.gathered + '.');
  if (repo.status !== 'ok' && repo.status !== 'first_appearance') {
    refuse(repo.repo + ' was ' + repo.status + ' when gathered (' + repo.reason + '), so there is nothing to commit for it.');
  }

  // The draft: it must exist and hold something, or a run that died before writing it would move
  // the boundary over a period nobody was told about.
  let draft;
  try { draft = fs.readFileSync(args.draft, 'utf8'); }
  catch (e) { refuse('The draft is not at ' + args.draft + ' (' + e.code + '). lastEnd stays where it is until the draft exists.'); }
  if (!draft.trim()) refuse('The draft at ' + args.draft + ' is empty. lastEnd stays where it is until the draft exists.');
  const draftLines = new Set(draft.split(/\r?\n/).map(function (l) { return l.trim(); }));

  const headings = args.headings ? args.headings.split('|').map(function (h) { return h.trim(); }).filter(Boolean) : null;
  (headings || []).forEach(function (h) {
    if (!draftLines.has(h)) refuse('The heading ' + JSON.stringify(h) + ' is not a line of the draft at ' + args.draft + '.');
  });

  const listed = args.listed ? args.listed.split(',').map(function (s) { return s.trim(); }).filter(Boolean) : [];
  listed.forEach(function (s) { if (!/^\d+$/.test(s)) refuse('--listed holds ' + JSON.stringify(s) + ', which is not a PR number.'); });
  const listedNums = listed.map(Number);
  // R6: no run is recorded while an announce change that is out has no outcome. Checked before the
  // state is read, so a refusal leaves it exactly as it was.
  const outcomes = announcementOutcomes(repo, args.outcomes, args.drafts);

  const state = readJson(statePath, 'The state file');
  if (state === undefined && gathered.stateExisted) {
    refuse('The state file at ' + statePath + ' existed when this was gathered and is gone now. Nothing was written.');
  }
  const next = state === undefined ? {} : state;
  const entryNow = next[repo.repo] || {};
  if ((entryNow.lastEnd || null) !== (repo.stateLastEnd || null)) {
    refuse('The state for ' + repo.repo + ' has changed since this gather (lastEnd was ' + repo.stateLastEnd + ', is now '
      + entryNow.lastEnd + '). It was probably committed already; gather again rather than overwrite it.');
  }

  const updated = Object.assign({}, entryNow);
  const said = [];
  if (repo.status === 'first_appearance') {
    if (listedNums.length) refuse(repo.repo + ' is a first appearance: it is introduced in general and lists no PRs, so --listed does not apply.');
    if (!repo.seed) refuse(repo.repo + ' has nothing live to introduce, so there is no boundary to seed.');
    updated.lastEnd = repo.seed.mergedAt;
    updated._seededFrom = { number: repo.seed.number, mergedAt: repo.seed.mergedAt };
    said.push('lastEnd seeded at #' + repo.seed.number + ' (' + repo.seed.mergedAt + ')');
  } else if (listedNums.length) {
    const byNumber = new Map(repo.prs.map(function (p) { return [p.number, p]; }));
    let newest = null;
    listedNums.forEach(function (n) {
      const p = byNumber.get(n);
      if (!p) refuse('#' + n + ' is not among the PRs gathered for ' + repo.repo + ', so it cannot have been listed.');
      if (p.deploy === 'held') refuse('#' + n + ' had not reached production when gathered, so it cannot be listed.');
      if (p.deploy === 'unconfirmed') refuse('#' + n + ' could not be confirmed live when gathered, so it cannot be listed as shipped.');
      if (newest === null || Date.parse(p.mergedAt) > Date.parse(newest)) newest = p.mergedAt;
    });
    const was = entryNow.lastEnd ? Date.parse(entryNow.lastEnd) : -Infinity;
    if (Date.parse(newest) > was) { updated.lastEnd = newest; said.push('lastEnd moved to ' + newest); }
    else said.push('lastEnd stays at ' + entryNow.lastEnd + ' (a redo never moves it backwards)');
  } else if (!entryNow.lastEnd && repo.window && repo.window.source === 'since') {
    // Lost state recovered with --since and nothing listed: the chosen start becomes the boundary,
    // or the next run reads this repo as a first appearance and introduces it again.
    updated.lastEnd = repo.window.start;
    said.push('nothing listed; lastEnd set to the --since start ' + repo.window.start);
  } else {
    said.push('nothing listed, so lastEnd stays at ' + entryNow.lastEnd);
  }
  updated.heldBack = repo.heldBack.slice();
  if (repo.status === 'ok') {
    updated.announcements = keptAnnouncements(repo, outcomes, updated);
    said.push(updated.announcements.length
      ? 'announcements kept for the next run ' + JSON.stringify(updated.announcements.map(function (a) { return '#' + a.number + ' ' + (a.outcome || 'no outcome'); }))
      : 'no announcement kept');
  }
  if (headings) updated.headings = headings;
  next[repo.repo] = updated;
  writeJsonAtomic(statePath, next);
  process.stderr.write(repo.name + ': ' + said.join('; ') + '; heldBack ' + JSON.stringify(updated.heldBack)
    + (headings ? '; headings ' + JSON.stringify(headings) : '') + '. Written to ' + statePath + '\n');
  return 0;
}

// ---------------------------------------------------------------- posted

// One gathered announcement, by repo and number, for the commands that act on one.
function gatheredAnnouncement(args) {
  const gathered = readJson(args.gathered, 'The gathered file');
  if (gathered === undefined) refuse('The gathered file is not at ' + args.gathered + '.');
  const repo = (gathered.repos || []).filter(function (r) { return r.repo.toLowerCase() === args.repo.toLowerCase(); })[0];
  if (!repo) refuse(args.repo + ' is not in ' + args.gathered + '.');
  const n = Number(args.number);
  if (!Array.isArray(repo.announcements)) {
    refuse(repo.repo + '\'s announcements were not read when gathered (' + repo.status + (repo.reason ? ': ' + repo.reason : '') + '), so there is nothing to look for.');
  }
  const ann = repo.announcements.filter(function (a) { return a.number === n; })[0];
  if (!ann) refuse('#' + args.number + ' is not among the announcements gathered for ' + repo.repo + '.');
  return { repo: repo, ann: ann, n: n };
}

// Is a gathered announcement already in the channel? `--read` is a file holding what
// slack_read_channel returned, word for word, once per page read (SKILL.md section 11). The
// announcement comes from the gathered file, never retyped, and the comparison is
// hooks/lib/announce-compare.js's, of words only. Not found says only that: whether the read
// reached every message since the merge is the session's to say, and a read that failed or was
// cut short is never handed here.
function cmdPosted(args) {
  if (!args.gathered || !args.repo || !args.number || !args.read) {
    refuse('Usage: gather.js posted --gathered P --repo owner/name --number N --read FILE (one page of the channel read per file; repeat as --read FILE,FILE).');
  }
  const one = gatheredAnnouncement(args);
  const repo = one.repo;
  const ann = one.ann;
  const n = one.n;
  if (!ann.text) refuse('#' + n + ' has no announcement text that could be read (' + (ann.why || 'no reason given') + '), so it cannot be looked for.');
  const text = args.read.split(',').map(function (file) {
    let t;
    try { t = fs.readFileSync(file, 'utf8'); }
    catch (e) { refuse('The channel read is not at ' + file + ' (' + e.code + '), so nothing was compared.'); }
    if (!t.trim()) refuse('The channel read at ' + file + ' is empty. An empty read is not a read that found nothing; read the channel again.');
    return t;
  }).join('\n');
  let got;
  try { got = require(COMPARE_PATH).foundPosted(ann.text, text); }
  catch (e) { refuse('#' + n + ' could not be compared: ' + e.message + '.'); }
  const said = got.found
    ? 'found posted: every word of #' + n + '\'s announcement is in the channel read, in order. The read just before it: ' + JSON.stringify(got.before)
    : 'not found in what was read. This says nothing about messages the read did not reach.';
  process.stdout.write(JSON.stringify({ repo: repo.repo, number: n, found: got.found, words: got.words, before: got.before, said: said }, null, 2) + '\n');
  return 0;
}

// ---------------------------------------------------------------- Draft it now (claude-config#3667)
//
// Dan's fourth answer for an announcement that is live and was never drafted (2026-11-25, by picker:
// "Draft it now"). The session makes the one call that drafts an announcement (Slack's draft tool,
// the channel, no thread, the wording exactly), and this file decides the two things around it,
// neither worked out here: whether the wording may be drafted at all, which is the hooks' one check
// that it is the wording the pull request merged on (claimedNow in hooks/lib/announce-compare.js),
// and whether the call left a draft, which is the hooks' one judgement of Slack's answer (judgeDraft
// in the same file: a draft counts only when the answer holds a draft_id).
//
// The two files of one announcement's draft, in the folder --drafts names: its wording as gathered,
// written by `draftable` for the session to pass on unretyped, and Slack's answer to the draft
// call, written by the session exactly as the tool returned it.
function draftFiles(dir, n) {
  return { message: path.join(dir, 'announce-' + n + '-message.txt'), answer: path.join(dir, 'announce-' + n + '-answer.txt') };
}

// Whether an announcement may be drafted from here now: `said` is why not, each cause in its own
// words (L11). A record of approvals that could not be read is said as that, never as an approval.
function draftableNow(repo, ann) {
  const no = function (said) { return { draftable: false, said: said }; };
  const tag = '#' + ann.number;
  if (SETTLED.indexOf(ann.previousOutcome) !== -1) return no(tag + ' is already settled (' + ann.previousOutcome + '), so nothing is drafted for it.');
  if (!ann.live) return no(tag + ' is not confirmed live (its deploy reads ' + ann.deploy + '), and an announcement is drafted only once its change is live.');
  if (ann.state !== 'owed' || !ann.channel || !ann.text) {
    return no(tag + ' cannot be drafted from this Mac: ' + (ann.why || 'its channel or its wording was not read') + '.');
  }
  let claim;
  try { claim = require(COMPARE_PATH).claimedNow(repo.repo, ann.number, ann.text); }
  catch (e) { return no('Whether ' + tag + '\'s announcement is the wording Dan approved could not be checked (' + e.message + '), so it is not drafted: he must be asked again.'); }
  if (claim.state === 'changed') return no(tag + '\'s announcement was changed in its pull request after Dan approved it, so it is not drafted: he must be asked again.');
  if (claim.state !== 'approved') return no('Dan\'s approval of ' + tag + '\'s announcement could not be read (' + claim.why + '), so it is not drafted: he must be asked again.');
  return { draftable: true, said: '' };
}

// Before the picker: may "Draft it now" be offered for this announcement? Where it may, its wording
// is written to its message file, exactly as gathered. Where it may not, nothing is written, so no
// session holds a file of wording that must not be drafted.
function cmdDraftable(args) {
  if (!args.gathered || !args.repo || !args.number || !args.drafts) {
    refuse('Usage: gather.js draftable --gathered P --repo owner/name --number N --drafts DIR (a folder in the scratchpad for the draft\'s two files).');
  }
  const one = gatheredAnnouncement(args);
  const files = draftFiles(args.drafts, one.n);
  const verdict = draftableNow(one.repo, one.ann);
  const out = { repo: one.repo.repo, number: one.n, draftable: verdict.draftable, channel: one.ann.channel || '', messageFile: null, answerFile: null, said: verdict.said };
  if (verdict.draftable) {
    try {
      fs.mkdirSync(args.drafts, { recursive: true });
      fs.writeFileSync(files.message, one.ann.text);
    } catch (e) { refuse('The wording of #' + one.n + ' could not be written to ' + files.message + ' (' + e.code + '), so there is nothing to draft from.'); }
    out.messageFile = files.message;
    out.answerFile = files.answer;
    out.said = '"Draft it now" may be offered for #' + one.n + '. If Dan picks it, call slack_send_message_draft with channel_id "' + one.ann.channel
      + '", no thread_ts, and message set to exactly the contents of ' + files.message + ', every line and blank line as written. Then write the tool\'s answer, '
      + 'exactly as it returned it, to ' + files.answer + ' and run gather.js drafted.';
  }
  process.stdout.write(JSON.stringify(out, null, 2) + '\n');
  return 0;
}

// After the draft call: did it leave a draft of the approved wording? `state` is `saved` (and only
// then is `outcome` drafted), `differs`, `not-kept` or `error` as judgeDraft tells them apart, or
// `not-draftable` when the wording may not be drafted at all. Used by `drafted`, which says it, and
// by commit-state, which records drafted-now on nothing less than `saved`.
function draftedVerdict(repo, ann, dir, toolError) {
  const tag = '#' + ann.number;
  const again = ' It is not recorded as drafted: ask the picker again without "Draft it now".';
  const may = draftableNow(repo, ann);
  if (!may.draftable) return { state: 'not-draftable', outcome: null, draftId: '', said: may.said + again };
  const files = draftFiles(dir, ann.number);
  const read = function (file, what) {
    try { return fs.readFileSync(file, 'utf8'); }
    catch (e) { refuse(what + ' is not at ' + file + ' (' + e.code + '), so whether ' + tag + ' was drafted cannot be judged.'); }
  };
  const message = read(files.message, 'The wording passed to the draft call for ' + tag);
  const answer = read(files.answer, 'The draft tool\'s answer for ' + tag);
  if (!answer.trim()) refuse('The draft tool\'s answer at ' + files.answer + ' is empty. An empty answer is not a draft that was not kept: write down what the tool returned.');
  let j;
  try { j = require(COMPARE_PATH).judgeDraft({ text: ann.text, message: message, answer: { text: answer, isError: toolError === true } }); }
  catch (e) { refuse(tag + '\'s draft could not be judged: ' + e.message + '.'); }
  const where = 'channel ' + ann.channel;
  if (j.state === 'saved') {
    return { state: 'saved', outcome: 'drafted', draftId: j.draftId, said: tag + '\'s announcement is saved as a Slack draft in ' + where + ' (Slack\'s id for it is ' + j.draftId
      + '). Its outcome is drafted: tell Dan it waits in his Drafts for him to send and that nothing was sent, and pass ' + ann.number + '=' + DRAFTED_NOW + ' to the state commit. The next run lists it again until it is sent.' };
  }
  if (j.state === 'differs') {
    return { state: 'differs', outcome: null, draftId: j.draftId || '', said: 'The draft Slack kept for ' + tag + ' differs from the wording Dan approved: ' + j.why
      + '. Tell Dan the draft now in ' + where + ' is not the approved wording.' + again };
  }
  if (j.state === 'not-kept') {
    return { state: 'not-kept', outcome: null, draftId: '', said: 'No draft was saved for ' + tag + ': ' + j.why + '. Tell Dan a draft is already waiting in ' + where
      + ', which Slack did not show, so whether it is this announcement is not known. Do not tell him to delete it.' + again };
  }
  return { state: 'error', outcome: null, draftId: '', said: 'No draft was saved for ' + tag + ': ' + j.why + '. Tell Dan that, with the reason.' + again };
}

function cmdDrafted(args) {
  if (!args.gathered || !args.repo || !args.number || !args.drafts) {
    refuse('Usage: gather.js drafted --gathered P --repo owner/name --number N --drafts DIR [--tool-error yes] (the folder gather.js draftable wrote the wording to, now also holding the tool\'s answer).');
  }
  const one = gatheredAnnouncement(args);
  const v = draftedVerdict(one.repo, one.ann, args.drafts, args['tool-error'] === 'yes');
  process.stdout.write(JSON.stringify({ repo: one.repo.repo, number: one.n, state: v.state, outcome: v.outcome, draftId: v.draftId, said: v.said }, null, 2) + '\n');
  return 0;
}

// ---------------------------------------------------------------- gh, as the repo's account

// The repos one gh command names: --repo X, --repo=X, -R X, and the repos/<owner>/<name> path of
// a `gh api` call.
function reposNamed(words) {
  const named = [];
  words.forEach(function (w, i) {
    if ((w === '--repo' || w === '-R') && i + 1 < words.length) named.push(words[i + 1]);
    else if (w.indexOf('--repo=') === 0) named.push(w.slice('--repo='.length));
  });
  if (words[0] === 'api') {
    words.slice(1).forEach(function (w) {
      const m = /^\/?repos\/([^/?#]+\/[^/?#]+)/.exec(w);
      if (m) named.push(m[1]);
    });
  }
  return named;
}

// The issue check (SKILL.md section 9) runs its gh commands through here, so each one runs as the
// account that owns the repo it names, exactly as the reads above do. gh's own output and exit
// code come back unchanged, so a failed edit is never reported as done.
function cmdGh(args) {
  const usage = 'Usage: gather.js gh [--config P] -- <gh command naming its repo with --repo owner/name>';
  if (!args.rest) refuse(usage);
  const words = args.rest;
  if (words.length === 0) refuse('gather.js gh was given no gh command after --. ' + usage);
  if (words[0] === 'auth') {
    refuse('gather.js gh does not run gh auth commands: the account comes from the dev update registry, and the active account is never switched.');
  }
  const configPath = configPathFor(args);
  const cfg = loadConfig(configPath);
  const named = reposNamed(words);
  const distinct = Array.from(new Set(named.map(function (n) { return n.toLowerCase(); })));
  if (distinct.length === 0) {
    refuse('The gh command names no repo (--repo owner/name, or an api path under repos/owner/name), so which account runs it '
      + 'cannot be told. It was not run.');
  }
  if (distinct.length > 1) refuse('The gh command names ' + distinct.join(' and ') + ', so which account runs it cannot be told. It was not run.');
  const entry = cfg.repos.filter(function (r) { return r.repo.toLowerCase() === distinct[0]; })[0];
  if (!entry) refuse(named[0] + ' is not in ' + configPath + ', so the account to run it as is not recorded. It was not run.');
  const as = readAs(entry.account, entry.name + ' (' + entry.repo + ')');
  const r = spawnSync(ghBin(), words, { stdio: 'inherit', timeout: GH_TIMEOUT_MS, env: ghEnv(as.token) });
  if (r.error) refuse('gh could not run (' + r.error.message + '), so the command did not take effect.');
  if (r.status === null) refuse('gh was stopped (' + r.signal + ') before it finished, so whether the command took effect is not known.');
  return r.status;
}

// ---------------------------------------------------------------- main

function main(argv) {
  const args = parseArgs(argv);
  const cmd = args._[0];
  if (cmd === 'gather') return cmdGather(args);
  if (cmd === 'commit-state') return cmdCommitState(args);
  if (cmd === 'gh') return cmdGh(args);
  if (cmd === 'posted') return cmdPosted(args);
  if (cmd === 'draftable') return cmdDraftable(args);
  if (cmd === 'drafted') return cmdDrafted(args);
  refuse('Usage: gather.js gather [options] | gather.js commit-state --gathered P --draft P --repo owner/name [--listed N,N] [--headings \'A|B\'] [--outcomes N=sent|drafted|not-announcing|drafted-now,...] [--drafts DIR]'
    + ' | gather.js posted --gathered P --repo owner/name --number N --read FILE'
    + ' | gather.js draftable --gathered P --repo owner/name --number N --drafts DIR'
    + ' | gather.js drafted --gathered P --repo owner/name --number N --drafts DIR [--tool-error yes]'
    + ' | gather.js gh [--config P] -- <gh command with --repo owner/name>');
}

try {
  process.exitCode = main(process.argv.slice(2));
} catch (e) {
  if (e instanceof Refusal || e instanceof Unreachable) {
    process.stderr.write('Refused: ' + e.message + '\n');
    process.exitCode = 1;
  } else {
    throw e;
  }
}
