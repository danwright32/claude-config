#!/usr/bin/env node
'use strict';
//
// review.js: the bookkeeping behind the anthropic-article-review-from-slack skill
// (claude-config#3544). The session reads Slack and the articles and makes every judgement; this
// script holds the rules that must not drift from run to run: which posts still need a review,
// what the log may contain, which emoji an outcome earns, when a kind of article has a track
// record, and whether an app's standing description still matches the app.
//
// It never reaches Slack or GitHub. The session hands it what it read (the channel's posts as
// JSON) and acts on what comes back.
//
// Its files live in this skill's folder under the HOME directory, never beside this code, which
// also runs from a checkout of a public repository. All are named *.local.json, which claude-sync
// keeps on one Mac (LOCAL_FILE_GLOBS), because they name work repositories:
//   config.local.json   the channel, the article bot and the owner's Slack user
//   log.local.json      one entry per reviewed post, with rotating backups log.local.json.1 to .5
//   apps.local.json     a standing description of each app, with the facts it was measured from
//
// Every command prints JSON on stdout. A refusal goes to stderr with a non zero exit.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const SKILL_DIR = path.join('.claude', 'skills', 'anthropic-article-review-from-slack');
const CHECK = 'white_check_mark';
const HANDS = 'raised_hands';
const MARKS = [CHECK, HANDS];
// The one list of kinds and the one list of outcomes. The skill's text points here.
const KINDS = ['how-to', 'product-launch', 'model-launch', 'customer-story', 'industry-solution',
  'enterprise-admin', 'research', 'other'];
const OUTCOMES = ['off-topic', 'no-change', 'changed', 'hand-marked'];
const EMOJI_FOR = { 'off-topic': CHECK, 'no-change': CHECK, 'changed': HANDS, 'hand-marked': null };
const BACKUPS_KEPT = 5;
// A kind is due a suggestion to drop it from the feed once this many of its articles were
// reviewed and every one was off topic, and again each time this many more go the same way.
const FEED_THRESHOLD = 5;
const QUIET_FEED_DAYS = 7;
// What counts as source naming a model, and as an AI package. Docs, lock files and package.json
// itself are left out of the file count: packages are measured on their own.
const MODEL_PATTERN = 'anthropic|claude-(opus|sonnet|haiku|fable)|@ai-sdk|openai|workers-ai|generativelanguage';
const MODEL_EXCLUDES = ['*.md', '*.mdx', '*.lock', '*lock.json', '*lock.yaml', '*.snap', '*package.json', '.claude/*'];
const AI_PACKAGE = /anthropic|claude|openai|^ai$|^@ai-sdk\/|^agents$|langchain|generative-ai|workers-ai|mistral|cohere|ollama/i;

// A refusal is thrown, and the command line at the foot of this file turns it into the message on
// stderr and a non zero exit. Nothing in between may catch one and carry on.
class Refusal extends Error {}
function fail(message) { throw new Refusal(message); }
function print(value) { process.stdout.write(JSON.stringify(value, null, 2) + '\n'); }
function local(name) { return path.join(os.homedir(), SKILL_DIR, name); }

function parseArgs(argv) {
  const flags = { 'recheck-hand-marked': true, replace: true };
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.slice(0, 2) !== '--') { out._.push(a); continue; }
    const key = a.slice(2);
    if (flags[key]) { out[key] = true; continue; }
    if (i + 1 >= argv.length) fail('The option ' + a + ' needs a value.');
    out[key] = argv[++i];
  }
  return out;
}
function nowIso(args) {
  if (args.now === undefined) return new Date().toISOString();
  if (isNaN(Date.parse(args.now))) fail('The time given to --now cannot be read: ' + args.now);
  return args.now;
}
function readJsonArg(file, what) {
  if (!file) fail('This command needs ' + what + '.');
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (e) { return fail('The file ' + file + ' could not be read as JSON (' + e.message + ').'); }
}

// ------------------------------------------------------------------ files on this Mac

function readConfig() {
  const file = local('config.local.json');
  const want = 'It is a file this Mac keeps for itself, holding a JSON object with channelId (the '
    + 'Slack channel the articles are posted to), botId (the id of the bot that posts them, as the '
    + 'channel read shows it) and ownerUserId (the Slack user whose emoji mark a post reviewed).';
  let config;
  try { config = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (e) {
    if (e.code === 'ENOENT') return fail('The channel settings are not at ' + file + '. ' + want);
    return fail('The channel settings at ' + file + ' could not be read (' + e.message + '). ' + want);
  }
  ['channelId', 'botId', 'ownerUserId'].forEach(function (k) {
    if (typeof config[k] !== 'string' || !config[k]) fail('The channel settings at ' + file + ' have no ' + k + '. ' + want);
  });
  return config;
}

function backupNames(name) {
  const out = [];
  for (let n = 1; n <= BACKUPS_KEPT; n++) if (fs.existsSync(local(name + '.' + n))) out.push(n);
  return out;
}
function newestGoodBackup(name, isGood) {
  const ns = backupNames(name);
  for (let i = 0; i < ns.length; i++) {
    try { if (isGood(JSON.parse(fs.readFileSync(local(name + '.' + ns[i]), 'utf8')))) return ns[i]; }
    catch (e) { /* an unreadable backup is passed over for the next one */ }
  }
  return null;
}
// Keep the version being replaced as .1, shifting older ones down, then write the new one under a
// temporary name and rename it into place, so a crash leaves the old file or the new one, whole.
function writeRotating(name, value) {
  const file = local(name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (fs.existsSync(file)) {
    if (fs.existsSync(local(name + '.' + BACKUPS_KEPT))) fs.unlinkSync(local(name + '.' + BACKUPS_KEPT));
    for (let n = BACKUPS_KEPT - 1; n >= 1; n--) {
      if (fs.existsSync(local(name + '.' + n))) fs.renameSync(local(name + '.' + n), local(name + '.' + (n + 1)));
    }
    fs.copyFileSync(file, local(name + '.1'));
  }
  const tmp = file + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n');
  fs.renameSync(tmp, file);
}

function isLog(v) { return v && Array.isArray(v.articles); }
function restoreHint() {
  const n = newestGoodBackup('log.local.json', isLog);
  if (n === null) return 'No readable backup is beside it, so the reasons and the track record cannot be recovered; move the file aside to start a new log.';
  return 'The newest good backup is ' + local('log.local.json.' + n) + '. Put it back with: node ' + __filename + ' log-restore --from ' + n;
}
function readLog() {
  const file = local('log.local.json');
  let text;
  try { text = fs.readFileSync(file, 'utf8'); }
  catch (e) {
    if (e.code !== 'ENOENT') return fail('The review log at ' + file + ' could not be read (' + e.message + '). ' + restoreHint());
    // No log and no backups is a first run. No log beside its own backups is a lost file.
    if (backupNames('log.local.json').length) return fail('The review log at ' + file + ' is gone, though backups of it remain. ' + restoreHint());
    return remember({ articles: [], feedSuggestions: [] }, null);
  }
  let log;
  try { log = JSON.parse(text); } catch (e) { log = null; }
  if (!isLog(log)) return fail('The review log at ' + file + ' is not a readable log. ' + restoreHint());
  if (!Array.isArray(log.feedSuggestions)) log.feedSuggestions = [];
  return remember(log, text);
}
// Two sessions can run this skill at once, and each reads the log, changes its copy and writes it
// back. The text a log was read from travels with it (out of sight of JSON), and a write is
// refused when the file no longer holds that text, so the later writer never erases the earlier.
function remember(log, text) {
  Object.defineProperty(log, 'readFrom', { value: text, enumerable: false });
  return log;
}
function writeLog(log) {
  const file = local('log.local.json');
  let current = null;
  try { current = fs.readFileSync(file, 'utf8'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  if (current !== log.readFrom) {
    fail('The review log at ' + file + ' changed after this command read it, so another session is writing to it. Nothing was written. Run this command again; it will read the log as it is now.');
  }
  writeRotating('log.local.json', log);
}

// ------------------------------------------------------------------ worklist

function sameLink(a, b) {
  const norm = function (u) { return String(u || '').trim().replace(/\/+$/, '').toLowerCase(); };
  return norm(a) !== '' && norm(a) === norm(b);
}
function worklist(args) {
  const config = readConfig();
  const log = readLog();
  const now = Date.parse(nowIso(args));
  const input = readJsonArg(args.posts, 'the channel\'s posts, as --posts <file>');
  if (!input || !Array.isArray(input.posts)) fail('The posts file must hold a JSON object with a "posts" list.');
  const fromBot = input.posts.filter(function (p) { return p && p.botId === config.botId; });
  const notFromBot = input.posts.length - fromBot.length;
  // An empty read cannot be told from a read that failed, so it is never a clean day (L98).
  if (!fromBot.length) fail('There is no post from the article bot (' + config.botId + ') in what was read. That is a failed or misdirected read, not a channel with nothing to review: read channel ' + config.channelId + ' again.');
  fromBot.forEach(function (p) {
    if (typeof p.ts !== 'string' || !/^\d+\.\d+$/.test(p.ts)) fail('A post has no usable ts: ' + JSON.stringify(p).slice(0, 200));
    if (!p.url || !p.title) fail('The post ' + p.ts + ' has no title or no link to its article.');
    if (!Array.isArray(p.reactions)) p.reactions = [];
  });
  fromBot.sort(function (a, b) { return Number(a.ts) - Number(b.ts); });
  const byTs = {};
  log.articles.forEach(function (a) { byTs[a.ts] = a; });

  const out = { channelId: config.channelId, toReview: [], handMarked: [], repeats: [], owed: [], reviewed: 0,
    teammateMarksIgnored: 0, notFromBot: notFromBot };
  const newest = Number(fromBot[fromBot.length - 1].ts);
  const days = Math.floor((now - newest * 1000) / 86400000);
  out.feed = { quiet: days > QUIET_FEED_DAYS, daysSinceLastPost: days, newestTs: fromBot[fromBot.length - 1].ts };

  let subjects = fromBot;
  if (args.only !== undefined) {
    subjects = fromBot.filter(function (p) { return p.ts === args.only; });
    if (!subjects.length) fail('The post ' + args.only + ' is not among the article bot\'s posts in what was read, so there is nothing to review under that name.');
  }

  const unknown = [];
  subjects.forEach(function (p) {
    const entry = byTs[p.ts];
    const marks = p.reactions.filter(function (r) { return MARKS.indexOf(r.name) !== -1; });
    // Who reacted matters unless the log already records that this skill marked the post.
    const trusted = !!(entry && entry.markedAt);
    if (!trusted && marks.some(function (r) { return !Array.isArray(r.users); })) { unknown.push(p.ts); return; }
    const owners = marks.filter(function (r) { return Array.isArray(r.users) ? r.users.indexOf(config.ownerUserId) !== -1 : trusted; })
      .map(function (r) { return r.name; });
    if (marks.some(function (r) { return Array.isArray(r.users) && r.users.some(function (u) { return u !== config.ownerUserId; }); })) out.teammateMarksIgnored++;
    const ownerMark = owners.indexOf(HANDS) !== -1 ? HANDS : (owners.indexOf(CHECK) !== -1 ? CHECK : null);
    const item = { ts: p.ts, title: p.title, url: p.url, published: p.published || null, source: p.source || null };

    if (args.only !== undefined) {
      out.toReview.push(Object.assign(item, { alreadyMarked: ownerMark, logged: !!entry }));
      return;
    }
    if (entry) {
      out.reviewed++;
      const emoji = EMOJI_FOR[entry.outcome];
      if (emoji && owners.indexOf(emoji) === -1) out.owed.push(Object.assign(item, { emoji: emoji }));
      return;
    }
    if (ownerMark) {
      if (args['recheck-hand-marked']) out.toReview.push(Object.assign(item, { alreadyMarked: ownerMark, logged: false }));
      else out.handMarked.push(Object.assign(item, { emoji: ownerMark }));
      return;
    }
    const earlier = log.articles.filter(function (a) { return a.outcome !== 'hand-marked' && !a.repeatOf && sameLink(a.url, p.url); })[0];
    if (earlier) {
      out.repeats.push(Object.assign(item, { sameAsTs: earlier.ts, outcome: earlier.outcome, kind: earlier.kind, emoji: EMOJI_FOR[earlier.outcome] }));
      return;
    }
    out.toReview.push(Object.assign(item, { alreadyMarked: null, logged: false }));
  });
  if (unknown.length) {
    fail('Who reacted is not known for ' + unknown.length + ' post(s): ' + unknown.join(', ') + '. A check mark or raised hands counts only when it is the owner\'s, so call slack_get_reactions for each of these and give every reaction its "users" list of Slack user ids, then run this again.');
  }
  print(out);
}

// ------------------------------------------------------------------ the log

function validateEntry(e) {
  if (!e || typeof e !== 'object') fail('The entry must be a JSON object.');
  if (typeof e.ts !== 'string' || !/^\d+\.\d+$/.test(e.ts)) fail('The entry has no usable ts (the post\'s Slack timestamp).');
  if (!e.url || !e.title) fail('The entry for ' + e.ts + ' needs the article\'s url and title.');
  if (OUTCOMES.indexOf(e.outcome) === -1) fail('The outcome "' + e.outcome + '" is not one of: ' + OUTCOMES.join(', ') + '.');
  const proposals = e.proposals === undefined ? [] : e.proposals;
  if (!Array.isArray(proposals)) fail('The entry\'s proposals must be a list.');
  if (e.outcome !== 'hand-marked') {
    if (KINDS.indexOf(e.kind) === -1) fail('The kind "' + e.kind + '" is not one of: ' + KINDS.join(', ') + '.');
    if (typeof e.reason !== 'string' || !e.reason.trim()) fail('The entry for ' + e.ts + ' needs a reason: one line saying why it ended as ' + e.outcome + '.');
  }
  let accepted = 0;
  proposals.forEach(function (p) {
    if (!p || typeof p.summary !== 'string' || !p.summary.trim()) fail('Every proposal needs a summary.');
    if (p.decision !== 'accepted' && p.decision !== 'declined') fail('The proposal "' + p.summary + '" needs a decision of accepted or declined.');
    if (p.decision === 'accepted') {
      accepted++;
      if (!(typeof p.issue === 'string' && p.issue.trim()) && p.draftNote !== true) {
        fail('The accepted proposal "' + p.summary + '" has no issue link, and no draftNote saying a draft reply was saved for a system the owner did not build. File the issue or save the draft before logging.');
      }
    }
  });
  if (e.outcome === 'changed' && accepted === 0) fail('An outcome of changed needs at least one accepted proposal, and this entry has none.');
  if (e.outcome !== 'changed' && accepted > 0) fail('This entry holds ' + accepted + ' accepted proposal(s), so its outcome is changed, not ' + e.outcome + '.');
  return proposals;
}
function logAdd(args) {
  const now = nowIso(args);
  const e = readJsonArg(args.entry, 'the entry, as --entry <file>');
  const proposals = validateEntry(e);
  const log = readLog();
  const at = log.articles.findIndex(function (a) { return a.ts === e.ts; });
  if (at !== -1 && !args.replace) {
    fail('The post ' + e.ts + ' is already in the log as ' + log.articles[at].outcome + '. To record a fresh review of it, which keeps the earlier entry inside the new one, add --replace.');
  }
  const stored = { ts: e.ts, url: e.url, title: e.title, published: e.published || null, source: e.source || null,
    kind: e.outcome === 'hand-marked' ? null : e.kind, outcome: e.outcome, reason: e.reason || null,
    proposals: proposals, reviewedAt: now, markedAt: null };
  if (e.repeatOf) stored.repeatOf = String(e.repeatOf);
  if (at !== -1) {
    const old = Object.assign({}, log.articles[at]);
    const previous = old.previous || [];
    delete old.previous;
    stored.previous = previous.concat([old]);
    log.articles[at] = stored;
  } else {
    log.articles.push(stored);
  }
  writeLog(log);
  print({ ts: e.ts, outcome: e.outcome, emoji: EMOJI_FOR[e.outcome] });
}
function logMarked(args) {
  const now = nowIso(args);
  const log = readLog();
  const entry = log.articles.filter(function (a) { return a.ts === args.ts; })[0];
  if (!entry) fail('The post ' + args.ts + ' is not in the log, so there is no entry to record its emoji on. Log the review first.');
  entry.markedAt = now;
  writeLog(log);
  print({ ts: entry.ts, markedAt: now });
}
function logRestore(args) {
  const n = Number(args.from);
  if (!(n >= 1 && n <= BACKUPS_KEPT)) fail('Name the backup to restore as --from 1 to --from ' + BACKUPS_KEPT + '.');
  const from = local('log.local.json.' + n);
  let value;
  try { value = JSON.parse(fs.readFileSync(from, 'utf8')); } catch (e) { return fail('The backup ' + from + ' could not be read (' + e.message + ').'); }
  if (!isLog(value)) fail('The backup ' + from + ' is not a readable log.');
  const file = local('log.local.json');
  // The file being replaced is kept beside the log, never deleted (L5).
  if (fs.existsSync(file)) fs.renameSync(file, file + '.set-aside-' + Date.now());
  fs.copyFileSync(from, file);
  print({ restoredFrom: from, articles: value.articles.length });
}
function declined() {
  const out = [];
  readLog().articles.forEach(function (a) {
    (a.proposals || []).forEach(function (p) {
      if (p.decision === 'declined') out.push({ summary: p.summary, declineReason: p.declineReason || null, title: a.title, url: a.url, reviewedAt: a.reviewedAt });
    });
  });
  print({ declined: out });
}

// ------------------------------------------------------------------ the track record

function tallyOf(log) {
  const kinds = {};
  KINDS.forEach(function (k) { kinds[k] = { reviewed: 0, offTopic: 0, noChange: 0, changed: 0 }; });
  let handMarked = 0;
  log.articles.forEach(function (a) {
    if (a.outcome === 'hand-marked') { handMarked++; return; }
    if (a.repeatOf || !kinds[a.kind]) return;
    const k = kinds[a.kind];
    k.reviewed++;
    if (a.outcome === 'off-topic') k.offTopic++;
    else if (a.outcome === 'no-change') k.noChange++;
    else if (a.outcome === 'changed') k.changed++;
  });
  const due = KINDS.filter(function (name) {
    const k = kinds[name];
    if (k.reviewed < FEED_THRESHOLD || k.offTopic !== k.reviewed) return false;
    const asked = log.feedSuggestions.filter(function (s) { return s.kind === name; });
    if (!asked.length) return true;
    return k.reviewed >= asked[asked.length - 1].reviewed + FEED_THRESHOLD;
  });
  return { kinds: kinds, handMarked: handMarked, dueForFeedSuggestion: due, feedSuggestions: log.feedSuggestions };
}
function feedSuggested(args) {
  const now = nowIso(args);
  if (KINDS.indexOf(args.kind) === -1) fail('The kind "' + args.kind + '" is not one of: ' + KINDS.join(', ') + '.');
  if (args.decision !== 'accepted' && args.decision !== 'declined') fail('The --decision is accepted or declined.');
  const log = readLog();
  const reviewed = tallyOf(log).kinds[args.kind].reviewed;
  log.feedSuggestions.push({ kind: args.kind, decision: args.decision, at: now, reviewed: reviewed });
  writeLog(log);
  print({ kind: args.kind, decision: args.decision, reviewed: reviewed });
}

// ------------------------------------------------------------------ app descriptions

function git(folder, gitArgs, okCodes) {
  const r = spawnSync('git', ['-C', folder].concat(gitArgs), { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.error) throw new Error('git could not be run: ' + r.error.message);
  if ((okCodes || [0]).indexOf(r.status) === -1) throw new Error('git ' + gitArgs.slice(0, 2).join(' ') + ' failed: ' + (r.stderr || '').trim().split('\n')[0]);
  return { code: r.status, out: r.stdout };
}
// Measured from the remote's default branch after a fetch, never from the working folder, which
// can sit weeks behind main. Nothing here checks out, resets or writes in the working folder.
function measure(folder, now) {
  const where = folder.slice(0, 2) === '~/' ? path.join(os.homedir(), folder.slice(2)) : folder;
  if (!fs.existsSync(where)) throw new Error('the folder ' + folder + ' is not there');
  git(where, ['fetch', '--quiet', 'origin']);
  let ref = null;
  const head = git(where, ['symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD'], [0, 1, 128]);
  if (head.code === 0 && head.out.trim()) ref = head.out.trim();
  ['origin/main', 'origin/master'].forEach(function (candidate) {
    if (ref === null && git(where, ['rev-parse', '--verify', '--quiet', candidate], [0, 1, 128]).code === 0) ref = candidate;
  });
  if (ref === null) throw new Error('no default branch was found on the remote of ' + folder);
  const commit = git(where, ['rev-parse', ref]).out.trim();
  const spec = ['.'].concat(MODEL_EXCLUDES.map(function (x) { return ':(exclude)' + x; }));
  const grep = git(where, ['grep', '-l', '-I', '-i', '-E', MODEL_PATTERN, ref, '--'].concat(spec), [0, 1]);
  const modelFiles = grep.code === 1 ? 0 : grep.out.split('\n').filter(Boolean).length;
  const packages = {};
  const unreadable = [];
  git(where, ['ls-tree', '-r', '--name-only', ref]).out.split('\n').forEach(function (file) {
    if (!/(^|\/)package\.json$/.test(file) || /(^|\/)node_modules\//.test(file)) return;
    let pkg;
    // A package.json that cannot be read is named in the result, so a missing AI package is
    // never the quiet result of a file that was skipped.
    try { pkg = JSON.parse(git(where, ['show', ref + ':' + file]).out); } catch (e) { unreadable.push(file); return; }
    ['dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies'].forEach(function (group) {
      Object.keys((pkg && pkg[group]) || {}).forEach(function (name) { if (AI_PACKAGE.test(name)) packages[name] = true; });
    });
  });
  return { branch: ref, commit: commit, aiPackages: Object.keys(packages).sort(), modelFiles: modelFiles,
    unreadablePackageFiles: unreadable.sort(), measuredAt: now };
}
// Ordinary churn must not make a description stale, or every run rewrites every description.
// It is stale when the AI packages changed, when the app went between naming no model and naming
// one, or when the count of files naming a model moved by a quarter and by at least 5.
function whyStale(stored, measured) {
  const why = [];
  const added = measured.aiPackages.filter(function (p) { return stored.aiPackages.indexOf(p) === -1; });
  const removed = stored.aiPackages.filter(function (p) { return measured.aiPackages.indexOf(p) === -1; });
  if (added.length) why.push('AI packages added: ' + added.join(', '));
  if (removed.length) why.push('AI packages removed: ' + removed.join(', '));
  const s = stored.modelFiles, m = measured.modelFiles;
  const moved = Math.abs(m - s) >= Math.max(5, Math.ceil(s * 0.25));
  if ((s === 0) !== (m === 0) || moved) why.push('source files naming a model went from ' + s + ' to ' + m);
  return why.join('; ');
}
function readApps(orEmpty) {
  const file = local('apps.local.json');
  let text;
  try { text = fs.readFileSync(file, 'utf8'); }
  catch (e) {
    if (e.code === 'ENOENT' && orEmpty) return { apps: [] };
    if (e.code === 'ENOENT') return fail('There are no app descriptions at ' + file + ' on this Mac, so which apps an article bears on cannot be judged. Write one per app with: node ' + __filename + ' apps-set --entry <file>');
    return fail('The app descriptions at ' + file + ' could not be read (' + e.message + ').');
  }
  let value;
  try { value = JSON.parse(text); } catch (e) { value = null; }
  if (!value || !Array.isArray(value.apps)) return fail('The app descriptions at ' + file + ' are not readable JSON with an "apps" list. A backup may be beside it as apps.local.json.1.');
  return value;
}
function appsSet(args) {
  const now = nowIso(args);
  const e = readJsonArg(args.entry, 'the app, as --entry <file>');
  if (!e || typeof e.name !== 'string' || !e.name.trim()) fail('The app needs a name.');
  if (typeof e.mine !== 'boolean') fail('The app "' + e.name + '" must say whether it is the owner\'s: "mine" is true for a system the owner built, false for one somebody else owns.');
  if (typeof e.description !== 'string' || !e.description.trim()) fail('The app "' + e.name + '" needs a description of what it uses Claude for, or that it does not.');
  const app = { name: e.name.trim(), repo: e.repo || null, path: e.path || null, mine: e.mine, description: e.description.trim(), facts: null };
  if (app.path) {
    try { app.facts = measure(app.path, now); }
    catch (err) { fail('The app "' + app.name + '" could not be measured: ' + err.message + '. Nothing was stored.'); }
  }
  const value = readApps(true);
  const at = value.apps.findIndex(function (a) { return a.name === app.name; });
  if (at === -1) value.apps.push(app); else value.apps[at] = app;
  writeRotating('apps.local.json', value);
  print({ name: app.name, facts: app.facts });
}
function appsCheck(args) {
  const now = nowIso(args);
  const value = readApps(false);
  let failures = 0;
  const apps = value.apps.map(function (a) {
    const row = { name: a.name, repo: a.repo, mine: a.mine, description: a.description, state: null, why: '', measured: null };
    // A system with no folder to measure is never reported as current: nothing checked it (L411).
    if (!a.path) { row.state = 'unmeasured'; row.why = 'no repository on this Mac to measure; the description is as written'; return row; }
    try { row.measured = measure(a.path, now); }
    catch (err) { failures++; row.state = 'failed'; row.why = err.message; return row; }
    row.why = a.facts ? whyStale(a.facts, row.measured) : 'it was never measured';
    row.state = row.why ? 'stale' : 'current';
    return row;
  });
  print({ apps: apps });
  if (failures) process.exit(1);
}

// ------------------------------------------------------------------ commands

const COMMANDS = {
  'worklist': worklist,
  'log-add': logAdd,
  'log-marked': logMarked,
  'log-restore': logRestore,
  'declined': declined,
  'tally': function () { print(tallyOf(readLog())); },
  'feed-suggested': feedSuggested,
  'apps-set': appsSet,
  'apps-check': appsCheck,
  'vocabulary': function () { print({ kinds: KINDS, outcomes: OUTCOMES, emoji: EMOJI_FOR, feedThreshold: FEED_THRESHOLD }); },
};

if (require.main === module) {
  try {
    const args = parseArgs(process.argv.slice(2));
    const command = COMMANDS[args._[0]];
    if (!command) fail('Usage: node review.js <' + Object.keys(COMMANDS).join(' | ') + '> [options]');
    command(args);
  } catch (e) {
    if (!(e instanceof Refusal)) throw e;
    process.stderr.write(e.message + '\n');
    process.exit(2);
  }
}

module.exports = { readLog: readLog, writeLog: writeLog };
