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
//                    [--listed N,N,...] [--headings 'A|B'] [--state P]
//
// gather prints one JSON document (and writes it to --out): per repo, its window, every merged
// PR in it with its changelog record and whether it reached production, what to hold back, and
// any refusal with its reason. It only ever READS from GitHub, through `gh api`, by owner/name,
// so it runs from any directory and needs no local checkout.
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

const PER_PAGE = 100;
const MAX_PAGES = 200;             // 20,000 PRs, far past any repo here; a guard against a loop
const GH_TIMEOUT_MS = 120000;      // a gh call that hangs is a failure, never a wait (L110)
const RECORDER_STALE_DAYS = 3;     // build_history with no row this recent: the recorder stopped
const MAX_SEED_WALK = 200;         // newest merges walked looking for a live one on a first run
const DEPENDABOT = 'dependabot[bot]';

class Refusal extends Error {}
class Unreachable extends Error {}

function refuse(msg) { throw new Refusal(msg); }

// ---------------------------------------------------------------- arguments

function parseArgs(argv) {
  const out = { _: [], live: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
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

function loadConfig(file) {
  const cfg = readJson(file, 'repos.json');
  if (cfg === undefined) refuse('repos.json is not at ' + file + '.');
  if (!cfg || !Array.isArray(cfg.repos) || cfg.repos.length === 0) refuse(file + ' holds no "repos" list.');
  cfg.repos.forEach(function (r, i) {
    if (!r || typeof r.name !== 'string' || !r.name.trim()) refuse('Entry ' + (i + 1) + ' in ' + file + ' has no name.');
    if (typeof r.repo !== 'string' || !/^[\w.-]+\/[\w.-]+$/.test(r.repo)) {
      refuse(r.name + ' in ' + file + ' has repo ' + JSON.stringify(r.repo) + ', which is not owner/name.');
    }
    if (r.deployRecord !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(String(r.deployRecordFrom || ''))) {
      refuse(r.name + ' names a deploy record but no deployRecordFrom date (YYYY-MM-DD) saying where it starts.');
    }
  });
  return cfg;
}

function loadEntry() {
  try { return require(ENTRY_PATH); }
  catch (e) { refuse('The changelog record parser is not at ' + ENTRY_PATH + ' (' + e.message + '), so no record can be read.'); }
}

// ---------------------------------------------------------------- GitHub, read only

function gh(apiPath) {
  const bin = process.env.PENNIE_DEV_UPDATE_GH || 'gh';
  const r = spawnSync(bin, ['api', apiPath], { encoding: 'utf8', timeout: GH_TIMEOUT_MS, maxBuffer: 256 * 1024 * 1024 });
  if (r.error) throw new Unreachable('gh could not run for ' + apiPath + ': ' + r.error.message);
  if (r.status !== 0) throw new Unreachable('gh api ' + apiPath + ' failed (exit ' + r.status + '): ' + (r.stderr || r.stdout || '').trim());
  try { return JSON.parse(r.stdout); }
  catch (e) { throw new Unreachable('gh api ' + apiPath + ' returned something that is not JSON: ' + String(r.stdout).slice(0, 200)); }
}

// Every closed PR, page by page in creation order, so a PR opened during the read lands on a
// later page rather than shifting one already read (L746). A short read reports as a quiet week,
// so the pages are read until one comes back short, and the count is checked against search.
function mergedPulls(slug) {
  const seen = new Map();
  for (let page = 1; page <= MAX_PAGES; page++) {
    const batch = gh('repos/' + slug + '/pulls?state=closed&sort=created&direction=asc&per_page=' + PER_PAGE + '&page=' + page);
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

function searchCount(slug, startMs) {
  const after = iso(startMs).replace(/Z$/, '+00:00');
  const q = 'repo:' + slug + ' is:pr is:merged merged:>' + after;
  const r = gh('search/issues?q=' + encodeURIComponent(q) + '&per_page=1');
  if (!r || typeof r.total_count !== 'number') throw new Unreachable('the search count for ' + slug + ' came back without a total.');
  return r.total_count;
}

// Is mergeSha an ancestor of liveSha? Asked of GitHub, which always has both, never of a local
// clone, which may not have fetched the live sha (claude-config#679).
function isLive(slug, pr, liveSha) {
  if (!pr.merge_commit_sha) refuse('#' + pr.number + ' in ' + slug + ' has no merge commit, so whether it is live could not be checked.');
  let status;
  // per_page=1: only the status is read, so the commit list it would otherwise carry is not fetched.
  try { status = gh('repos/' + slug + '/compare/' + pr.merge_commit_sha + '...' + liveSha + '?per_page=1').status; }
  // A failed call is GitHub not answering, so the repo is unreachable, never refused (L11).
  catch (e) {
    if (e instanceof Unreachable) throw new Unreachable('whether #' + pr.number + ' is live could not be checked: ' + e.message);
    throw e;
  }
  if (status === 'ahead' || status === 'identical') return true;
  if (status === 'behind' || status === 'diverged') return false;
  refuse('GitHub answered ' + JSON.stringify(status) + ' comparing #' + pr.number + ' with the live sha, so whether it is live could not be checked.');
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
  const parsed = entry.parseEntry({ labels: pr.labels, body: pr.body });
  if (parsed.ok) return { kind: parsed.kind, line: parsed.line };
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

  // The deploy record, checked before anything else is read: a stopped recorder means every
  // answer below is "cannot tell", not "nothing shipped".
  let live = null;
  if (repoCfg.deployRecord) {
    live = ctx.live[key];
    if (!live) {
      refuse(repoCfg.name + ' has a deploy record (' + repoCfg.deployRecord + ') and it was not read. Run the query in SKILL.md section 4 and pass --live '
        + slug + '=<commit_sha>@<recorded_at>.');
    }
    if (live.recordedMs < ctx.nowMs - RECORDER_STALE_DAYS * 86400000) {
      refuse(repoCfg.deployRecord + ' has no row in the last ' + RECORDER_STALE_DAYS + ' days (newest ' + live.recordedAt
        + '), so the recorder has stopped and an empty answer would mean "cannot tell", not "nothing shipped".');
    }
    out.deploy = { kind: repoCfg.deployRecord, liveSha: live.sha, recordedAt: live.recordedAt, coversFrom: repoCfg.deployRecordFrom };
  }
  function deployOf(pr) {
    if (!live) return 'unchecked';
    if (ctx.entry.localDay(new Date(pr.merged_at)) < repoCfg.deployRecordFrom) return 'uncovered';
    return isLive(slug, pr, live.sha) ? 'live' : 'held';
  }

  const all = mergedPulls(slug);

  if (startMs === null) {
    out.status = 'first_appearance';
    out.window = { start: null, end: iso(ctx.nowMs), startExclusive: true, source: 'none' };
    out.counts = { merged: all.length };
    const newestFirst = all.slice().reverse();
    for (let i = 0; i < newestFirst.length && i < MAX_SEED_WALK; i++) {
      const pr = newestFirst[i];
      const d = deployOf(pr);
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
  const total = searchCount(slug, startMs);
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
  const counts = { inWindow: inWindow.length, searchCount: total, carried: carried.length, recorded: 0, handJudged: 0, gaps: 0, dependency: 0, held: 0, uncovered: 0, unchecked: 0 };
  candidates.forEach(function (pr) {
    const record = recordOf(ctx.entry, repoCfg, pr);
    const deploy = deployOf(pr);
    if (record.kind === 'unrecorded') counts.handJudged++;
    else if (record.kind === 'gap') counts.gaps++;
    else if (record.kind === 'dependency') counts.dependency++;
    else counts.recorded++;
    if (deploy === 'held') { counts.held++; out.heldBack.push(pr.number); }
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
  if (counts.unchecked) out.notes.push(repoCfg.name + ' has no deploy record, so whether its ' + counts.unchecked + ' PR(s) reached production could not be checked.');
  if (counts.gaps) out.notes.push(counts.gaps + ' PR(s) merged after the changelog cutover carry no valid record: something merged around the gate.');
  return out;
}

// ---------------------------------------------------------------- gather

function cmdGather(args) {
  const configPath = args.config || path.join(__dirname, 'repos.json');
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

  const ctx = { state: state || {}, nowMs: nowMs, entry: entry, live: live, sinceMs: sinceMs, since: args.since, confirmSkip: !!args.confirmSkip };
  const result = {
    v: 1, generatedAt: iso(nowMs), statePath: statePath, stateExisted: state !== undefined, configPath: configPath, repos: [],
  };
  repos.forEach(function (repoCfg) {
    let r;
    try { r = gatherRepo(ctx, repoCfg); }
    catch (e) {
      if (!(e instanceof Refusal) && !(e instanceof Unreachable)) throw e;
      r = { name: repoCfg.name, repo: repoCfg.repo, status: e instanceof Unreachable ? 'unreachable' : 'refused', reason: e.message,
        stateLastEnd: (ctx.state[repoCfg.repo] || {}).lastEnd || null, prs: [], heldBack: [], notes: [] };
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
        + c.handJudged + ' judged by hand, ' + c.gaps + ' gap(s), ' + c.dependency + ' dependency update(s); ' + c.held + ' held back';
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
  if (headings) updated.headings = headings;
  next[repo.repo] = updated;
  writeJsonAtomic(statePath, next);
  process.stderr.write(repo.name + ': ' + said.join('; ') + '; heldBack ' + JSON.stringify(updated.heldBack)
    + (headings ? '; headings ' + JSON.stringify(headings) : '') + '. Written to ' + statePath + '\n');
  return 0;
}

// ---------------------------------------------------------------- main

function main(argv) {
  const args = parseArgs(argv);
  const cmd = args._[0];
  if (cmd === 'gather') return cmdGather(args);
  if (cmd === 'commit-state') return cmdCommitState(args);
  refuse('Usage: gather.js gather [options] | gather.js commit-state --gathered P --draft P --repo owner/name [--listed N,N] [--headings \'A|B\']');
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
