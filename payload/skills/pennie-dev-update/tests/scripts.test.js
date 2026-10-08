'use strict';
//
// scripts.test.js: gather.js and lint-post.js, the pennie-dev-update skill's scripts
// (claude-config#680). Run by ../test-pennie-dev-update-scripts.sh, which is what
// run-all-tests.sh discovers.
//
// Every seam is set in every run (L284): GitHub is fake-gh.js through PENNIE_DEV_UPDATE_GH, a `gh`
// that fails loudly sits first on PATH in case anything bypasses the seam (L143), the clock is
// --now, the timezone is set (L504), and HOME is a scratch directory whose name carries spaces and
// a curly apostrophe, the shape of the work MacBook's Documents folder. Nothing here can reach
// GitHub, Slack or a real state file (L2).

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const SKILL = path.resolve(__dirname, '..');
const GATHER = path.join(SKILL, 'gather.js');
const LINT = path.join(SKILL, 'lint-post.js');
const FAKE_GH = path.join(__dirname, 'fake-gh.js');
// Characters the post must never carry, and the curly apostrophe of the work MacBook's folder, are
// built from their code points rather than typed, so this file holds none of them.
const HY = String.fromCharCode(45);
const EM = String.fromCharCode(0x2014);
const EN = String.fromCharCode(0x2013);
const BULLET = String.fromCharCode(0x2022);
const APOS = String.fromCharCode(0x2019);
const ROCKET = String.fromCodePoint(0x1F680);
const SHORTCODE = ':' + 'tada' + ':';

let passed = 0, failed = 0;
function check(cond, name, evidence) {
  if (cond) { passed++; return; }
  failed++;
  console.log('FAIL: ' + name + (evidence === undefined ? '' : ': ' + String(evidence).slice(0, 1500)));
}

const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), 'pdu-'));
const HOME = path.join(SCRATCH, 'Documents ' + HY + ' Dan' + APOS + 's MacBook Pro', 'home dir');
fs.mkdirSync(HOME, { recursive: true });
const POISON = path.join(SCRATCH, 'poison-bin');
fs.mkdirSync(POISON);
const REAL_GH_LOG = path.join(SCRATCH, 'real-gh-reached.log');
fs.writeFileSync(path.join(POISON, 'gh'),
  '#!/bin/sh\necho "real gh reached: $*" >> "' + REAL_GH_LOG + '"\nexit 97\n', { mode: 0o755 });
fs.chmodSync(FAKE_GH, 0o755);

const NOW = '2026-10-08T16:00:00Z';
const PET = 'acme/pet';
const SONAR = 'acme/sonar';

function sha(n) { return ('f' + String(n)).padEnd(40, '0'); }
function pr(n, mergedAt, opts) {
  const o = opts || {};
  return {
    number: n,
    merged_at: mergedAt,
    title: 'Change ' + n,
    labels: (o.labels || []).map(function (name) { return { name: name }; }),
    body: o.body === undefined ? 'Body of ' + n : o.body,
    merge_commit_sha: mergedAt ? (o.sha || sha(n)) : null,
    user: { login: o.author || 'dan' },
  };
}
const VISIBLE_BODY = 'Why.\n\n## Changelog\nManagers now see the Rolled column.\n\n## Testing\nran it';

let caseNo = 0;
function workspace(scenario, config, state) {
  caseNo++;
  const dir = path.join(SCRATCH, 'case ' + caseNo + ' Dan' + APOS + 's');
  fs.mkdirSync(dir);
  const files = {
    dir: dir,
    scenario: path.join(dir, 'scenario.json'),
    config: path.join(dir, 'repos.json'),
    state: path.join(dir, 'state dir', 'state.json'),
    ghLog: path.join(dir, 'gh.log'),
    out: path.join(dir, 'gathered.json'),
  };
  fs.writeFileSync(files.scenario, JSON.stringify(scenario));
  fs.writeFileSync(files.config, JSON.stringify(config || defaultConfig()));
  if (state !== undefined) {
    fs.mkdirSync(path.dirname(files.state), { recursive: true });
    fs.writeFileSync(files.state, typeof state === 'string' ? state : JSON.stringify(state));
  }
  return files;
}
function defaultConfig() {
  return { repos: [
    { name: 'PET', repo: PET, deployRecord: 'build_history', deployRecordFrom: '2026-07-29', changelogFrom: '2026-08-31' },
    { name: 'Sonar', repo: SONAR, changelogFrom: '2026-09-28' },
  ] };
}
function env(ws, extra) {
  return Object.assign({}, process.env, {
    HOME: HOME,
    TZ: 'America/New_York',
    PATH: POISON + path.delimiter + process.env.PATH,
    PENNIE_DEV_UPDATE_GH: FAKE_GH,
    FAKE_GH_SCENARIO: ws.scenario,
    FAKE_GH_LOG: ws.ghLog,
  }, extra || {});
}
function run(script, args, ws, extra) {
  const r = spawnSync(process.execPath, [script].concat(args), { env: env(ws, extra), encoding: 'utf8', timeout: 60000 });
  return { code: r.status, out: r.stdout || '', err: r.stderr || '', all: (r.stdout || '') + (r.stderr || '') };
}
function gather(ws, more, extra) {
  const args = ['gather', '--config', ws.config, '--now', NOW, '--out', ws.out]
    .concat(ws.noState ? [] : ['--state', ws.state]).concat(more || []);
  const r = run(GATHER, args, ws, extra);
  try { r.json = JSON.parse(fs.readFileSync(ws.out, 'utf8')); } catch (e) { r.json = null; }
  return r;
}
function repoOf(r, slug) {
  return r.json && r.json.repos.filter(function (x) { return x.repo === slug; })[0];
}
function nums(list) { return (list || []).map(function (p) { return p.number; }); }
const LIVE_OK = ['--live', PET + '=' + sha(900) + '@2026-10-08T10:00:00Z'];

// ---------------------------------------------------------------- the window

{
  const T = '2026-09-28T18:30:00Z';
  const ws = workspace({ pulls: {
    [PET]: [],
    [SONAR]: [
      pr(1, '2026-09-28T18:29:59Z'), pr(2, T), pr(3, '2026-09-28T18:30:01Z'),
      pr(4, null), pr(5, '2026-10-01T12:00:00Z'),
    ],
  } }, { repos: [{ name: 'Sonar', repo: SONAR, changelogFrom: '2026-09-28' }] }, { [SONAR]: { lastEnd: T } });
  const r = gather(ws);
  const s = repoOf(r, SONAR);
  check(r.code === 0, 'a clean gather exits 0', r.all);
  check(s && JSON.stringify(nums(s.prs)) === '[3,5]',
    'the window is strictly after lastEnd: the PR merged AT lastEnd is not listed again, an unmerged PR never is', s && JSON.stringify(nums(s.prs)));
  check(s && s.window.start === T && s.window.end === NOW, 'the window runs from lastEnd to --now', s && JSON.stringify(s.window));
  const log = fs.existsSync(ws.ghLog) ? fs.readFileSync(ws.ghLog, 'utf8') : '(gh was never called)';
  check(/merged:>2026-09-28T18:30:00\+00:00/.test(decodeURIComponent(log)),
    'the count cross check asks for merges strictly after the same instant', log);
}

// Pagination: a read that stopped at the first page reports as a quiet week.
{
  const many = [];
  for (let i = 1; i <= 250; i++) many.push(pr(i, new Date(Date.parse('2026-09-01T00:00:00Z') + i * 60000).toISOString().replace('.000', '')));
  const ws = workspace({ pulls: { [SONAR]: many } }, { repos: [{ name: 'Sonar', repo: SONAR }] }, { [SONAR]: { lastEnd: '2026-08-31T00:00:00Z' } });
  const r = gather(ws);
  const s = repoOf(r, SONAR);
  check(s && s.prs.length === 250, 'every page is read, not only the first hundred', s && s.prs.length);
  check(s && s.counts.searchCount === 250, 'the search count is recorded beside the list it checked', s && JSON.stringify(s.counts));
}

// A short read: the list and the search disagree, so that repo refuses and the others go on.
{
  const ws = workspace({
    pulls: { [PET]: [pr(10, '2026-10-02T12:00:00Z')], [SONAR]: [pr(20, '2026-10-02T12:00:00Z')] },
    compare: { [PET]: { [sha(10) + '...' + sha(900)]: 'ahead' } },
    searchDelta: { [SONAR]: 1 },
  }, null, { [PET]: { lastEnd: '2026-10-01T00:00:00Z' }, [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } });
  const r = gather(ws, LIVE_OK);
  const s = repoOf(r, SONAR), p = repoOf(r, PET);
  check(s && s.status === 'refused' && /1/.test(s.reason) && /2/.test(s.reason),
    'a count that disagrees with the list refuses that repo, naming both numbers', s && JSON.stringify(s));
  check(p && p.status === 'ok', 'one repo refusing does not stop the others', p && p.status);
  check(r.code === 3, 'a run with a refused repo exits 3, not 0', r.code);
  check(/Sonar/.test(r.err) && /refused/i.test(r.err), 'the terminal names the refused repo', r.err);
}

// A merged_at that does not parse would compare false against every boundary and silently drop
// the PR (L50), so it refuses the repo by PR number instead.
{
  const ws = workspace({ pulls: { [SONAR]: [pr(25, '2026-10-02T12:00:00Z'), pr(26, 'yesterday-ish')] } },
    { repos: [{ name: 'Sonar', repo: SONAR }] }, { [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } });
  const s = repoOf(gather(ws), SONAR);
  check(s && s.status === 'refused' && /#26/.test(s.reason) && /merged_at/.test(s.reason),
    'a merged_at that does not parse refuses the repo by PR number, never drops the PR', s && JSON.stringify(s));
}

// Unreachable: GitHub fails for one repo.
{
  const ws = workspace({
    pulls: { [PET]: [], [SONAR]: [] },
    fail: { [SONAR]: 'HTTP 502: Bad Gateway' },
  }, null, { [PET]: { lastEnd: '2026-10-01T00:00:00Z' }, [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } });
  const r = gather(ws, LIVE_OK);
  const s = repoOf(r, SONAR);
  check(s && s.status === 'unreachable' && /502/.test(s.reason), 'an unreachable repo says so with GitHub\'s own error, never as an empty window', s && JSON.stringify(s));
  check(repoOf(r, PET).status === 'ok', 'the reachable repo still gathers', repoOf(r, PET).status);
  check(r.code === 3, 'an unreachable repo exits 3', r.code);
}

// ---------------------------------------------------------------- the records

{
  const ws = workspace({ pulls: { [SONAR]: [], [PET]: [
    pr(30, '2026-08-31T03:00:00Z'),
    pr(31, '2026-08-31T05:00:00Z'),
    pr(32, '2026-09-02T12:00:00Z', { labels: ['changelog/visible', 'bug'], body: VISIBLE_BODY }),
    pr(33, '2026-09-02T13:00:00Z', { labels: ['changelog/technical'] }),
    pr(34, '2026-09-02T14:00:00Z', { labels: ['changelog/none'] }),
    pr(35, '2026-09-02T15:00:00Z', { author: 'dependabot[bot]' }),
    pr(36, '2026-09-02T16:00:00Z', { labels: ['changelog/visible'], body: 'no block' }),
  ] }, compare: { [PET]: {} } }, null, { [PET]: { lastEnd: '2026-08-30T00:00:00Z' }, [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } });
  const allLive = {};
  [30, 31, 32, 33, 34, 35, 36].forEach(function (n) { allLive[sha(n) + '...' + sha(900)] = 'ahead'; });
  const sc = JSON.parse(fs.readFileSync(ws.scenario, 'utf8')); sc.compare[PET] = allLive;
  fs.writeFileSync(ws.scenario, JSON.stringify(sc));
  const r = gather(ws, LIVE_OK);
  const p = repoOf(r, PET);
  const rec = {};
  (p ? p.prs : []).forEach(function (x) { rec[x.number] = x.record; });
  check(rec[30] && rec[30].kind === 'unrecorded',
    'a PR merged on the evening before the cutover, New York time, predates the gate and is judged by hand', JSON.stringify(rec[30]));
  check(rec[31] && rec[31].kind === 'gap' && rec[31].code === 'NO_LABEL',
    'a PR merged after the cutover with no record is a gap, named as one', JSON.stringify(rec[31]));
  check(rec[32] && rec[32].kind === 'visible' && rec[32].line === 'Managers now see the Rolled column.',
    'a visible record carries its Changelog sentence verbatim', JSON.stringify(rec[32]));
  check(rec[33] && rec[33].kind === 'technical', 'a technical label reads as technical', JSON.stringify(rec[33]));
  check(rec[34] && rec[34].kind === 'none', 'a none label reads as none', JSON.stringify(rec[34]));
  check(rec[35] && rec[35].kind === 'dependency', 'a Dependabot PR is a dependency update, never a gap', JSON.stringify(rec[35]));
  check(rec[36] && rec[36].kind === 'gap' && rec[36].code === 'NO_BLOCK',
    'a visible label with no block is a gap with the parser\'s own code', JSON.stringify(rec[36]));
  check(p && p.counts.recorded === 3 && p.counts.handJudged === 1 && p.counts.gaps === 2,
    'the counts say how many carried a record, how many were judged by hand, and how many are gaps', p && JSON.stringify(p.counts));
}

// ---------------------------------------------------------------- did it ship

function deployCase(liveArgs, compare, pulls, stateEntry) {
  const ws = workspace({ pulls: { [PET]: pulls, [SONAR]: [] }, compare: { [PET]: compare } }, null,
    { [PET]: stateEntry || { lastEnd: '2026-07-01T00:00:00Z' }, [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } });
  return gather(ws, liveArgs);
}
{
  const live = sha(900);
  const r = deployCase(LIVE_OK, {
    [sha(41) + '...' + live]: 'ahead',
    [sha(42) + '...' + live]: 'identical',
    [sha(43) + '...' + live]: 'behind',
    [sha(44) + '...' + live]: 'diverged',
  }, [pr(40, '2026-07-20T12:00:00Z'), pr(41, '2026-09-01T12:00:00Z'), pr(42, '2026-09-02T12:00:00Z'),
      pr(43, '2026-10-07T12:00:00Z'), pr(44, '2026-10-07T13:00:00Z')]);
  const p = repoOf(r, PET);
  const d = {};
  (p ? p.prs : []).forEach(function (x) { d[x.number] = x.deploy; });
  check(d[41] === 'live' && d[42] === 'live', 'ahead and identical both mean the merge is in production', JSON.stringify(d));
  check(d[43] === 'held' && d[44] === 'held', 'behind and diverged both mean not live yet', JSON.stringify(d));
  check(d[40] === 'uncovered', 'a PR merged before the deploy record existed is listed as uncovered, not held', JSON.stringify(d));
  check(p && JSON.stringify(p.heldBack) === '[43,44]', 'heldBack is exactly the PRs not yet live', p && JSON.stringify(p.heldBack));
  check(p && p.notes.some(function (n) { return /does not cover/.test(n); }), 'uncovered PRs get a note saying the record does not cover them', p && JSON.stringify(p.notes));
}
{
  const r = deployCase([], {}, [pr(41, '2026-09-01T12:00:00Z')]);
  const p = repoOf(r, PET);
  check(p && p.status === 'refused' && /build_history/.test(p.reason) && /--live/.test(p.reason),
    'a repo with a deploy record refuses when the live sha was not passed, naming the record and the flag', p && JSON.stringify(p));
}
{
  const r = deployCase(['--live', PET + '=' + sha(900) + '@2026-10-04T15:59:00Z'], {}, [pr(41, '2026-09-01T12:00:00Z')]);
  const p = repoOf(r, PET);
  check(p && p.status === 'refused' && /3 days/.test(p.reason),
    'a deploy record with no row in the last 3 days refuses: the recorder has stopped', p && JSON.stringify(p));
}
{
  const r = deployCase(['--live', PET + '=' + sha(900) + '@2026-10-05T16:01:00Z'], { [sha(41) + '...' + sha(900)]: 'ahead' }, [pr(41, '2026-09-01T12:00:00Z')]);
  check(repoOf(r, PET).status === 'ok', 'a deploy record just inside 3 days is accepted', JSON.stringify(repoOf(r, PET)));
}
{
  const r = deployCase(LIVE_OK, {}, [pr(41, '2026-09-01T12:00:00Z')]);
  const p = repoOf(r, PET);
  check(p && p.status === 'unreachable' && /could not/.test(p.reason) && /#41/.test(p.reason),
    'a compare GitHub fails to answer makes the repo unreachable, naming the PR, never holds it or calls it refused', p && JSON.stringify(p));
}
{
  const r = deployCase(['--live', PET + '=not-a-sha@2026-10-08T10:00:00Z'], {}, []);
  check(r.code === 1 && /--live/.test(r.err), 'a malformed --live refuses the whole run', r.all);
}
{
  const ws = workspace({ pulls: { [SONAR]: [pr(50, '2026-10-02T12:00:00Z')] } }, { repos: [{ name: 'Sonar', repo: SONAR }] }, { [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } });
  const s = repoOf(gather(ws), SONAR);
  check(s && s.prs[0].deploy === 'unchecked' && s.notes.some(function (n) { return /could not be checked/.test(n); }),
    'a repo with no deploy record lists its PRs as unchecked and says the check could not run', s && JSON.stringify(s));
}

// heldBack from the last run is carried even when it sits below the window.
{
  const r = deployCase(LIVE_OK, {
    [sha(60) + '...' + sha(900)]: 'ahead', [sha(61) + '...' + sha(900)]: 'ahead',
  }, [pr(60, '2026-09-20T12:00:00Z'), pr(61, '2026-10-02T12:00:00Z')], { lastEnd: '2026-10-01T00:00:00Z', heldBack: [60] });
  const p = repoOf(r, PET);
  const carried = (p ? p.prs : []).filter(function (x) { return x.carried; });
  check(p && JSON.stringify(nums(p.prs)) === '[60,61]' && carried.length === 1 && carried[0].number === 60,
    'a held back PR from the last run is a candidate again, marked as carried', p && JSON.stringify(p.prs));
  check(p && p.counts.inWindow === 1, 'a carried PR is not counted against the window\'s search total', p && JSON.stringify(p.counts));
}
{
  const r = deployCase(LIVE_OK, {}, [pr(61, '2026-10-02T12:00:00Z')], { lastEnd: '2026-10-01T00:00:00Z', heldBack: [999] });
  const p = repoOf(r, PET);
  check(p && p.status === 'refused' && /#999/.test(p.reason), 'a held back number GitHub does not show as merged refuses by name', p && JSON.stringify(p));
}

// ---------------------------------------------------------------- first appearance

{
  const ws = workspace({ pulls: { [SONAR]: [], [PET]: [pr(70, '2026-09-01T12:00:00Z'), pr(71, '2026-09-02T12:00:00Z'), pr(72, '2026-10-07T12:00:00Z')] },
    compare: { [PET]: { [sha(72) + '...' + sha(900)]: 'behind', [sha(71) + '...' + sha(900)]: 'ahead' } } },
    null, { [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } });
  const r = gather(ws, LIVE_OK);
  const p = repoOf(r, PET);
  check(p && p.status === 'first_appearance', 'a repo with no lastEnd in an existing state file is a first appearance', p && p.status);
  check(p && p.prs.length === 0, 'a first appearance never lists its PRs one by one', p && JSON.stringify(p.prs));
  check(p && p.seed && p.seed.number === 71 && p.seed.mergedAt === '2026-09-02T12:00:00Z',
    'the seed is the newest merged PR that reached production', p && JSON.stringify(p.seed));
  check(p && JSON.stringify(p.heldBack) === '[72]', 'a newer merge not yet live goes in heldBack', p && JSON.stringify(p.heldBack));
  check(r.code === 0, 'a first appearance is not a failure', r.code);
}
{
  const ws = workspace({ pulls: { [SONAR]: [pr(80, null)], [PET]: [] } }, { repos: [{ name: 'Sonar', repo: SONAR }] }, {});
  const s = repoOf(gather(ws), SONAR);
  check(s && s.status === 'first_appearance' && s.seed === null && s.notes.some(function (n) { return /nothing live to introduce/.test(n); }),
    'a first appearance with no merged PR has nothing to introduce and says so', s && JSON.stringify(s));
}

// ---------------------------------------------------------------- state and options

{
  const ws = workspace({ pulls: { [SONAR]: [] } }, { repos: [{ name: 'Sonar', repo: SONAR }] });
  const r = gather(ws);
  check(r.code === 1 && r.err.indexOf(ws.state) !== -1 && /--since/.test(r.err),
    'a missing state file refuses the whole run, naming the path and the escape hatch, never treats every repo as new', r.all);
  const r2 = gather(ws, ['--since', '2026-10-01T00:00:00Z']);
  const s = repoOf(r2, SONAR);
  check(r2.code === 0 && s && s.status === 'ok' && s.window.start === '2026-10-01T00:00:00Z' && s.window.source === 'since',
    '--since recovers lost state with an explicit start', r2.all);
  // Committing that run with nothing listed must still leave a lastEnd, or the next run reads the
  // repo as a first appearance and introduces the product again (lessons review of #937).
  ws.draft = path.join(ws.dir, 'quiet.txt');
  fs.writeFileSync(ws.draft, 'Updates for October :thread:\n\nNothing changed on screen.\n');
  const c = commitState(ws, ['--draft', ws.draft, '--repo', SONAR]);
  const st = fs.existsSync(ws.state) ? JSON.parse(fs.readFileSync(ws.state, 'utf8')) : {};
  check(c.code === 0 && st[SONAR] && st[SONAR].lastEnd === '2026-10-01T00:00:00Z',
    'a --since run that lists nothing records its start as lastEnd, so the repo is not new next time', c.all + JSON.stringify(st));
  const again = gather(ws);
  check(repoOf(again, SONAR) && repoOf(again, SONAR).status === 'ok', 'the next run after that continues the window rather than introducing the product', again.all);
}
{
  const ws = workspace({ pulls: { [SONAR]: [] } }, { repos: [{ name: 'Sonar', repo: SONAR }] }, '{ not json');
  const r = gather(ws);
  check(r.code === 1 && r.err.indexOf(ws.state) !== -1, 'a corrupt state file refuses the whole run by path', r.all);
}
{
  const ws = workspace({ pulls: { [SONAR]: [] } }, { repos: [{ name: 'Sonar', repo: SONAR }] }, { [SONAR]: { lastEnd: '2026-09-01T00:00:00Z' } });
  const r = gather(ws, ['--since', '2026-09-15T00:00:00Z']);
  const s = repoOf(r, SONAR);
  check(s && s.status === 'refused' && /2026-09-01T00:00:00Z/.test(s.reason) && /2026-09-15T00:00:00Z/.test(s.reason) && /--confirm-skip/.test(s.reason),
    'a --since later than lastEnd refuses, naming exactly the period it would skip', s && JSON.stringify(s));
  const r2 = gather(ws, ['--since', '2026-09-15T00:00:00Z', '--confirm-skip']);
  check(repoOf(r2, SONAR).status === 'ok', '--confirm-skip lets a deliberate skip through', JSON.stringify(repoOf(r2, SONAR)));
}
{
  const ws = workspace({ pulls: { [SONAR]: [], [PET]: [] } }, null, { [PET]: { lastEnd: '2026-10-01T00:00:00Z' }, [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } });
  const r = gather(ws, ['--only', 'sonar']);
  check(r.json && r.json.repos.length === 1 && r.json.repos[0].repo === SONAR, '--only filters to one repo by name, in any case', r.all);
  const r2 = gather(ws, ['--only', 'Nope']);
  check(r2.code === 1 && /Nope/.test(r2.err), '--only naming no configured repo refuses rather than gathering everything', r2.all);
}
{
  const ws = workspace({ pulls: { [SONAR]: [pr(90, '2026-10-02T12:00:00Z')] } }, { repos: [{ name: 'Sonar', repo: SONAR }] });
  const home = path.join(HOME, '.pennie-dev-update');
  fs.mkdirSync(home, { recursive: true });
  fs.writeFileSync(path.join(home, 'state.json'), JSON.stringify({ [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } }));
  ws.noState = true;
  const r = gather(ws);
  const s = repoOf(r, SONAR);
  check(s && s.window.start === '2026-10-01T00:00:00Z' && r.json.statePath === path.join(home, 'state.json'),
    'the default state file is derived from HOME, spaces and curly apostrophe included', r.all);
}
{
  const ws = workspace({ pulls: {} }, { repos: [{ name: 'Sonar', repo: 'not a slug' }] }, {});
  const r = gather(ws);
  check(r.code === 1 && /not a slug/.test(r.err), 'a repos.json entry that is not owner/name refuses the run', r.all);
}

// The repos.json that ships is one gather.js accepts, with every repo still listed.
{
  const shipped = JSON.parse(fs.readFileSync(path.join(SKILL, 'repos.json'), 'utf8'));
  const ws = workspace({ pulls: {} }, shipped, {});
  fs.copyFileSync(path.join(SKILL, 'repos.json'), ws.config);
  const r = gather(ws, shipped.repos.filter(function (x) { return x.deployRecord; })
    .reduce(function (a, x) { return a.concat(['--live', x.repo + '=' + sha(900) + '@2026-10-08T10:00:00Z']); }, []));
  check(r.code === 0 && r.json && r.json.repos.length === shipped.repos.length,
    'the shipped repos.json is accepted, every repo in it gathered', r.all);
}

// ---------------------------------------------------------------- commit-state

function committed(ws) { return JSON.parse(fs.readFileSync(ws.state, 'utf8')); }
function commitState(ws, more) {
  return run(GATHER, ['commit-state', '--gathered', ws.out, '--state', ws.state].concat(more), ws);
}
function commitCase(extraState) {
  const live = sha(900);
  const ws = workspace({ pulls: { [SONAR]: [], [PET]: [
    pr(101, '2026-10-02T12:00:00Z'), pr(102, '2026-10-03T12:00:00Z'), pr(103, '2026-10-07T12:00:00Z'),
  ] }, compare: { [PET]: { [sha(101) + '...' + live]: 'ahead', [sha(102) + '...' + live]: 'ahead', [sha(103) + '...' + live]: 'behind' } } },
  null, Object.assign({
    [PET]: { lastEnd: '2026-10-01T00:00:00Z', heldBack: [], headings: ['GOALS'], note: 'kept' },
    [SONAR]: { lastEnd: '2026-10-01T00:00:00Z', _seededFrom: { number: 5 } },
  }, extraState || {}));
  const g = gather(ws, LIVE_OK);
  ws.draft = path.join(ws.dir, 'Draft for Dan' + APOS + 's post.txt');
  return { ws: ws, g: g };
}
{
  const { ws } = commitCase();
  const before = fs.readFileSync(ws.state, 'utf8');
  const r = commitState(ws, ['--draft', ws.draft, '--repo', PET, '--listed', '101,102']);
  check(r.code !== 0 && /draft/i.test(r.err) && fs.readFileSync(ws.state, 'utf8') === before,
    'commit-state refuses without the draft and leaves the state byte for byte as it was', r.all);
  fs.writeFileSync(ws.draft, '  \n');
  const r2 = commitState(ws, ['--draft', ws.draft, '--repo', PET, '--listed', '101,102']);
  check(r2.code !== 0 && /empty/i.test(r2.err) && fs.readFileSync(ws.state, 'utf8') === before, 'an empty draft is refused too', r2.all);
}
{
  const { ws } = commitCase();
  fs.writeFileSync(ws.draft, 'Updates for October 1 to 8 :thread:\n\nCOMMISSION AND FIRST PAY\nA line.\n');
  const r = commitState(ws, ['--draft', ws.draft, '--repo', PET, '--listed', '101,102', '--headings', 'COMMISSION AND FIRST PAY']);
  const st = committed(ws);
  check(r.code === 0, 'commit-state with a draft succeeds', r.all);
  check(st[PET].lastEnd === '2026-10-03T12:00:00Z', 'lastEnd becomes the merged_at of the newest LISTED PR, not now and not the held one', JSON.stringify(st[PET]));
  check(JSON.stringify(st[PET].heldBack) === '[103]', 'heldBack is written from what gather found not yet live', JSON.stringify(st[PET]));
  check(JSON.stringify(st[PET].headings) === '["COMMISSION AND FIRST PAY"]', 'this run\'s headings are written back', JSON.stringify(st[PET]));
  check(st[PET].note === 'kept' && st[SONAR]._seededFrom && st[SONAR]._seededFrom.number === 5,
    'every other field and every other repo survives the write', JSON.stringify(st));
  const again = commitState(ws, ['--draft', ws.draft, '--repo', PET, '--listed', '101,102']);
  check(again.code !== 0 && /already/i.test(again.err) && committed(ws)[PET].lastEnd === '2026-10-03T12:00:00Z',
    'running commit-state twice on one gather refuses the second time and changes nothing', again.all);
}
{
  const { ws } = commitCase();
  fs.writeFileSync(ws.draft, 'Updates for October 1 to 8 :thread:\n\nA line.\n');
  const r = commitState(ws, ['--draft', ws.draft, '--repo', PET, '--listed', '101,103']);
  check(r.code !== 0 && /#103/.test(r.err), 'a PR that is not live cannot be listed', r.all);
  const r2 = commitState(ws, ['--draft', ws.draft, '--repo', PET, '--listed', '101,555']);
  check(r2.code !== 0 && /#555/.test(r2.err), 'a listed number gather never saw is refused by number', r2.all);
  const r3 = commitState(ws, ['--draft', ws.draft, '--repo', PET, '--listed', '101', '--headings', 'GOALS']);
  check(r3.code !== 0 && /GOALS/.test(r3.err), 'a heading that is not a line of the draft is refused', r3.all);
  const r4 = commitState(ws, ['--draft', ws.draft, '--repo', PET, '--listed', '1o1']);
  check(r4.code !== 0 && /1o1/.test(r4.err), 'a listed value that is not a number is refused', r4.all);
  check(committed(ws)[PET].lastEnd === '2026-10-01T00:00:00Z', 'none of those refusals moved lastEnd', JSON.stringify(committed(ws)[PET]));
}
{
  const { ws } = commitCase();
  fs.writeFileSync(ws.draft, 'Updates for October 1 to 8 :thread:\n\nNothing changed on screen.\n');
  const r = commitState(ws, ['--draft', ws.draft, '--repo', PET]);
  const st = committed(ws);
  check(r.code === 0 && st[PET].lastEnd === '2026-10-01T00:00:00Z' && JSON.stringify(st[PET].heldBack) === '[103]',
    'with nothing listed lastEnd stays put and heldBack is still written', r.all + JSON.stringify(st[PET]));
}
{
  const { ws } = commitCase();
  const st = committed(ws); st[PET].lastEnd = '2026-10-02T00:00:00Z';
  fs.writeFileSync(ws.state, JSON.stringify(st));
  fs.writeFileSync(ws.draft, 'Updates :thread:\n\nA line.\n');
  const r = commitState(ws, ['--draft', ws.draft, '--repo', PET, '--listed', '101']);
  check(r.code !== 0 && /changed since/i.test(r.err), 'a state that moved after this gather is refused, never overwritten', r.all);
}
{
  // A redo with --since earlier than lastEnd never moves lastEnd backwards.
  const live = sha(900);
  const ws = workspace({ pulls: { [SONAR]: [], [PET]: [pr(111, '2026-09-10T12:00:00Z')] },
    compare: { [PET]: { [sha(111) + '...' + live]: 'ahead' } } }, null,
    { [PET]: { lastEnd: '2026-09-20T00:00:00Z' }, [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } });
  gather(ws, LIVE_OK.concat(['--since', '2026-09-01T00:00:00Z', '--only', 'PET']));
  ws.draft = path.join(ws.dir, 'redo.txt');
  fs.writeFileSync(ws.draft, 'Updates :thread:\n\nA line.\n');
  const r = commitState(ws, ['--draft', ws.draft, '--repo', PET, '--listed', '111']);
  check(r.code === 0 && committed(ws)[PET].lastEnd === '2026-09-20T00:00:00Z', 'a redo never moves lastEnd backwards', r.all + JSON.stringify(committed(ws)[PET]));
}
{
  const ws = workspace({ pulls: { [SONAR]: [], [PET]: [pr(120, '2026-09-02T12:00:00Z'), pr(121, '2026-10-07T12:00:00Z')] },
    compare: { [PET]: { [sha(121) + '...' + sha(900)]: 'behind', [sha(120) + '...' + sha(900)]: 'ahead' } } },
    null, { [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } });
  gather(ws, LIVE_OK);
  ws.draft = path.join(ws.dir, 'launch.txt');
  fs.writeFileSync(ws.draft, 'Updates for October :thread:\nIncluding the launch of a new tool, PET!\n');
  const bad = commitState(ws, ['--draft', ws.draft, '--repo', PET, '--listed', '120']);
  check(bad.code !== 0 && /first appearance/i.test(bad.err), 'a first appearance lists nothing, so --listed is refused for it', bad.all);
  const r = commitState(ws, ['--draft', ws.draft, '--repo', PET]);
  const st = committed(ws);
  check(r.code === 0 && st[PET].lastEnd === '2026-09-02T12:00:00Z' && st[PET]._seededFrom.number === 120
    && st[PET]._seededFrom.mergedAt === '2026-09-02T12:00:00Z' && JSON.stringify(st[PET].heldBack) === '[121]',
    'a first appearance seeds lastEnd from the newest live PR and records where it came from', r.all + JSON.stringify(st[PET]));
}
{
  const ws = workspace({ pulls: { [SONAR]: [], [PET]: [] } }, null, { [PET]: { lastEnd: '2026-10-01T00:00:00Z' }, [SONAR]: { lastEnd: '2026-10-01T00:00:00Z' } });
  gather(ws);   // no --live, so PET is refused
  ws.draft = path.join(ws.dir, 'd.txt');
  fs.writeFileSync(ws.draft, 'Updates :thread:\n\nA line.\n');
  const r = commitState(ws, ['--draft', ws.draft, '--repo', PET]);
  check(r.code !== 0 && /refused/i.test(r.err), 'a repo gather refused cannot have its state committed', r.all);
}

// Nothing here wrote to GitHub or reached the real gh.
{
  let writes = '';
  fs.readdirSync(SCRATCH).forEach(function (d) {
    const log = path.join(SCRATCH, d, 'gh.log');
    if (fs.existsSync(log)) writes += fs.readFileSync(log, 'utf8').split('\n').filter(function (l) { return /^REFUSED/.test(l); }).join('\n');
  });
  check(writes === '', 'gather only ever reads from GitHub', writes);
  check(!fs.existsSync(REAL_GH_LOG), 'the real gh was never reached', fs.existsSync(REAL_GH_LOG) && fs.readFileSync(REAL_GH_LOG, 'utf8'));
}

// ---------------------------------------------------------------- lint-post

function lint(text) {
  const file = path.join(SCRATCH, 'post ' + (++caseNo) + ' Dan' + APOS + 's.txt');
  fs.writeFileSync(file, text);
  return run(LINT, [file], { scenario: '', ghLog: '' });
}
const CLEAN = [
  'Updates for September 15 to 28 :thread:',
  'Including the launch of a new tool, Sonar!',
  '',
  'GOALS',
  'The automatic unit goal is now two tiers.',
  'Volume goals follow.',
  '',
  'POWER RANKINGS',
  'Units, Volume and Conversion now show beside each score.',
  '',
  'BEHIND THE SCENES (technical, skip unless curious)',
  'Data checks: weekly checks for a rep who recorded nothing',
  '',
].join('\n');
{
  const r = lint(CLEAN);
  check(r.code === 0 && !/line \d/.test(r.out), 'a post in Dan\'s format passes clean', r.all);
}
function expectFinding(name, text, lineNo, word) {
  const r = lint(text);
  const re = new RegExp('line ' + lineNo + '\\b[^\\n]*' + word, 'i');
  check(r.code === 1 && re.test(r.out), name, r.all);
}
function swap(lineNo, replacement) {
  const lines = CLEAN.split('\n'); lines[lineNo - 1] = replacement; return lines.join('\n');
}
expectFinding('an em dash is refused with its line', swap(5, 'The goal is two tiers ' + EM + ' 15 and 22.'), 5, 'dash');
expectFinding('an en dash is refused', swap(5, 'Months 1' + EN + '3 carry 15 units.'), 5, 'dash');
expectFinding('a spaced hyphen used as a connector is refused', swap(5, 'The goal is two tiers ' + HY + ' 15 and 22.'), 5, 'dash');
expectFinding('a dash item prefix is refused', swap(5, HY + ' The goal is two tiers.'), 5, 'prefix');
expectFinding('a bullet character prefix is refused', swap(5, BULLET + ' The goal is two tiers.'), 5, 'prefix');
expectFinding('a numbered item prefix is refused', swap(5, '1. The goal is two tiers.'), 5, 'prefix');
expectFinding('Markdown bold is refused', swap(5, 'The goal is **two tiers**.'), 5, 'bold');
expectFinding('Slack bold is refused', swap(5, 'The goal is *two tiers*.'), 5, 'bold');
expectFinding('an emoji character is refused', swap(5, 'The goal is two tiers ' + ROCKET), 5, 'emoji');
expectFinding('an emoji shortcode in the body is refused', swap(5, 'The goal is two tiers ' + SHORTCODE), 5, 'emoji');
expectFinding('a heading not in uppercase is refused', swap(4, 'Goals'), 4, 'uppercase');
expectFinding('a heading ending in a colon is refused', swap(4, 'GOALS:'), 4, 'colon');
expectFinding('a bold heading is refused', swap(4, '*GOALS*'), 4, 'bold');
expectFinding('the old Update for opener is refused', swap(1, 'Update for September 15 to 28'), 1, 'opener');
expectFinding('an opener without :thread: is refused', swap(1, 'Updates for September 15 to 28'), 1, 'opener');
expectFinding('the deleted backend only line is refused', swap(2, 'Some of these you will not notice, because they are backend only.'), 2, 'backend only');
expectFinding('a heading with no item on the next line is refused', CLEAN.replace('GOALS\n', 'GOALS\n\n'), 4, 'item');
{
  const r = lint('Updates for the week of October 6 :thread:\n\nThe Rolled column now counts moved deals.\nA rep too new for a rate shows New.\n');
  check(r.code === 0, 'a flat list of a few items with no headings passes', r.all);
}
{
  const r = lint(swap(5, 'The Top' + HY + 'out column now shows the cap.'));
  check(r.code === 0 && /line 5\b[^\n]*Top.out/.test(r.out), 'a hyphenated word is a warning to confirm, not a refusal', r.all);
}
{
  const r = run(LINT, [path.join(SCRATCH, 'no such draft.txt')], { scenario: '', ghLog: '' });
  check(r.code === 2 && /no such draft/.test(r.err), 'a draft that cannot be read is its own exit, named', r.all);
}

fs.rmSync(SCRATCH, { recursive: true, force: true });
console.log('passed: ' + passed + ', failed: ' + failed);
console.log('SUITE-RESULT passed=' + passed + ' failed=' + failed);
process.exit(failed === 0 ? 0 : 1);
