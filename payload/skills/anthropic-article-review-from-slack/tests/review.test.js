'use strict';
//
// review.test.js: review.js, the anthropic-article-review-from-slack skill's bookkeeping script
// (claude-config#3544). Run by ../test-anthropic-article-review.sh, which is what run-all-tests.sh
// discovers.
//
// Every seam is set in every run: HOME is a scratch directory, so no case can read or write this
// Mac's real log, app descriptions or channel settings; the clock is --now; and the app repositories
// are real git repositories made here, each with its own local origin, so a fetch never leaves the
// scratch directory. Nothing here reaches Slack or GitHub: the script never does either, the session
// does, and hands the script what it read.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const REVIEW = path.resolve(__dirname, '..', 'review.js');
const SKILL_REL = path.join('.claude', 'skills', 'anthropic-article-review-from-slack');

let passed = 0, failed = 0;
function check(cond, name, evidence) {
  if (cond) { passed++; return; }
  failed++;
  console.log('FAIL: ' + name + (evidence === undefined ? '' : ': ' + String(evidence).slice(0, 1500)));
}

const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), 'aar-'));
let homes = 0;
// A fresh HOME per case, its name carrying a space, with the channel settings already written
// unless the case is about their absence.
function newHome(opts) {
  const home = path.join(SCRATCH, 'home ' + (++homes));
  fs.mkdirSync(path.join(home, SKILL_REL), { recursive: true });
  if (!opts || opts.config !== false) {
    writeLocal(home, 'config.local.json', { channelId: 'C0TEST', botId: 'B0BOT', ownerUserId: 'U0OWNER' });
  }
  return home;
}
function localPath(home, name) { return path.join(home, SKILL_REL, name); }
function writeLocal(home, name, value) {
  fs.writeFileSync(localPath(home, name), typeof value === 'string' ? value : JSON.stringify(value, null, 2));
}
function readLocal(home, name) { return JSON.parse(fs.readFileSync(localPath(home, name), 'utf8')); }
function run(home, args) {
  const r = spawnSync('node', [REVIEW].concat(args), {
    encoding: 'utf8',
    env: Object.assign({}, process.env, { HOME: home, TZ: 'America/New_York' }),
  });
  let json = null;
  try { json = JSON.parse(r.stdout); } catch (e) { json = null; }
  return { code: r.status, out: r.stdout, err: r.stderr, json: json };
}
function tmpJson(value) {
  const f = path.join(SCRATCH, 'in-' + Math.random().toString(36).slice(2) + '.json');
  fs.writeFileSync(f, JSON.stringify(value));
  return f;
}

const NOW = '2026-11-24T15:00:00Z';
const TS_NEW = '1795529923.677559';   // 2026-11-24, the day of NOW
const TS_OLD = '1795293367.258419';   // 2026-11-21
const CHECK = 'white_check_mark';
const HANDS = 'raised_hands';
function post(ts, n, reactions) {
  return { ts: ts, botId: 'B0BOT', title: 'Article ' + n, url: 'https://example.com/a' + n,
    published: 'Nov 23', source: 'Claude resources', reactions: reactions || [] };
}
function mark(name, users) { return { name: name, count: users ? users.length : 1, users: users }; }
function entry(ts, n, more) {
  return Object.assign({ ts: ts, url: 'https://example.com/a' + n, title: 'Article ' + n, published: 'Nov 23',
    source: 'Claude resources', kind: 'customer-story', outcome: 'off-topic',
    reason: 'A retail case study with no practice to adopt.', proposals: [] }, more || {});
}
function worklist(home, posts, extra) {
  return run(home, ['worklist', '--posts', tmpJson({ posts: posts }), '--now', NOW].concat(extra || []));
}
function logAdd(home, e, extra) {
  return run(home, ['log-add', '--entry', tmpJson(e), '--now', NOW].concat(extra || []));
}

// ---------------------------------------------------------------- worklist

(function unmarkedPostIsReviewed() {
  const r = worklist(newHome(), [post(TS_NEW, 1)]);
  check(r.code === 0 && r.json && r.json.toReview.length === 1 && r.json.toReview[0].ts === TS_NEW,
    'a bot post with no mark is on the list to review', r.out + r.err);
})();

(function teammateMarkDoesNotCount() {
  const r = worklist(newHome(), [post(TS_NEW, 1, [mark(CHECK, ['U0TEAMMATE'])])]);
  check(r.code === 0 && r.json && r.json.toReview.length === 1 && r.json.teammateMarksIgnored === 1,
    'a teammate\'s check mark leaves the post on the list and is counted as ignored', r.out + r.err);
})();

(function ownerHandMarkSkips() {
  const r = worklist(newHome(), [post(TS_NEW, 1, [mark(CHECK, ['U0OWNER'])])]);
  check(r.code === 0 && r.json && r.json.toReview.length === 0 && r.json.handMarked.length === 1
    && r.json.handMarked[0].emoji === CHECK,
    'the owner\'s own mark on a post the log does not hold is a hand mark, not a review', r.out + r.err);
})();

(function recheckLooksPastHandMarks() {
  const r = worklist(newHome(), [post(TS_NEW, 1, [mark(CHECK, ['U0OWNER'])])], ['--recheck-hand-marked']);
  check(r.code === 0 && r.json && r.json.toReview.length === 1 && r.json.toReview[0].alreadyMarked === CHECK
    && r.json.handMarked.length === 0,
    'the first run flag puts a hand marked post back on the list and says how it is marked', r.out + r.err);
})();

(function onlyReviewsTheNamedPost() {
  const r = worklist(newHome(), [post(TS_NEW, 1), post(TS_OLD, 2, [mark(HANDS, ['U0OWNER'])])], ['--only', TS_OLD]);
  check(r.code === 0 && r.json && r.json.toReview.length === 1 && r.json.toReview[0].ts === TS_OLD
    && r.json.toReview[0].alreadyMarked === HANDS,
    'a named post is reviewed even when marked, and nothing else is', r.out + r.err);
})();

(function onlyRefusesAnUnknownPost() {
  const r = worklist(newHome(), [post(TS_NEW, 1)], ['--only', '1.000001']);
  check(r.code !== 0 && /1\.000001/.test(r.err),
    'naming a post the channel read does not hold is refused, not answered with an empty list', r.out + r.err);
})();

(function unknownReactorIsRefused() {
  const r = worklist(newHome(), [post(TS_NEW, 1, [mark(CHECK, undefined)])]);
  check(r.code !== 0 && r.err.indexOf(TS_NEW) !== -1 && /slack_get_reactions/.test(r.err),
    'a mark with nobody named is refused and the refusal says which post and which tool settles it', r.out + r.err);
})();

(function loggedAndMarkedIsDone() {
  const home = newHome();
  logAdd(home, entry(TS_NEW, 1));
  run(home, ['log-marked', '--ts', TS_NEW, '--now', NOW]);
  const r = worklist(home, [post(TS_NEW, 1, [mark(CHECK, undefined)])]);
  check(r.code === 0 && r.json && r.json.toReview.length === 0 && r.json.owed.length === 0 && r.json.reviewed === 1,
    'a post the log recorded as marked is done, with no need to ask who reacted', r.out + r.err);
})();

(function loggedButNeverMarkedIsOwed() {
  const home = newHome();
  logAdd(home, entry(TS_NEW, 1));
  const r = worklist(home, [post(TS_NEW, 1)]);
  check(r.code === 0 && r.json && r.json.toReview.length === 0 && r.json.owed.length === 1
    && r.json.owed[0].ts === TS_NEW && r.json.owed[0].emoji === CHECK,
    'a logged post whose emoji never landed is owed its emoji and is not reviewed again', r.out + r.err);
})();

(function removedEmojiIsOwedAgain() {
  const home = newHome();
  logAdd(home, entry(TS_NEW, 1));
  run(home, ['log-marked', '--ts', TS_NEW, '--now', NOW]);
  const r = worklist(home, [post(TS_NEW, 1, [])]);
  check(r.code === 0 && r.json && r.json.owed.length === 1,
    'a logged post that no longer shows its emoji is owed it again', r.out + r.err);
})();

(function repostIsMatchedByLink() {
  const home = newHome();
  logAdd(home, entry(TS_OLD, 1));
  run(home, ['log-marked', '--ts', TS_OLD, '--now', NOW]);
  const r = worklist(home, [post(TS_NEW, 1)]);
  check(r.code === 0 && r.json && r.json.toReview.length === 0 && r.json.repeats.length === 1
    && r.json.repeats[0].ts === TS_NEW && r.json.repeats[0].sameAsTs === TS_OLD && r.json.repeats[0].emoji === CHECK,
    'a second post of an article already logged is a repeat carrying the first outcome', r.out + r.err);
})();

(function otherAuthorsAreNotArticles() {
  const stranger = post(TS_NEW, 1); stranger.botId = 'B0OTHER';
  const r = worklist(newHome(), [stranger, post(TS_OLD, 2)]);
  check(r.code === 0 && r.json && r.json.toReview.length === 1 && r.json.toReview[0].ts === TS_OLD && r.json.notFromBot === 1,
    'a post from anything but the article bot is counted and left alone', r.out + r.err);
})();

(function quietFeedIsReported() {
  const r = run(newHome(), ['worklist', '--posts', tmpJson({ posts: [post(TS_OLD, 1)] }), '--now', '2026-12-05T15:00:00Z']);
  check(r.code === 0 && r.json && r.json.feed && r.json.feed.quiet === true && r.json.feed.daysSinceLastPost >= 13,
    'a newest post more than 7 days old is reported as a quiet feed', r.out + r.err);
  const fresh = worklist(newHome(), [post(TS_NEW, 1)]);
  check(fresh.json && fresh.json.feed && fresh.json.feed.quiet === false,
    'a post from today is not a quiet feed', fresh.out + fresh.err);
})();

(function noPostsIsNotACleanDay() {
  const r = worklist(newHome(), []);
  check(r.code !== 0 && /no post/i.test(r.err),
    'a channel read holding no bot post at all is refused, since it cannot be told from a failed read', r.out + r.err);
})();

(function missingSettingsAreExplained() {
  const r = worklist(newHome({ config: false }), [post(TS_NEW, 1)]);
  check(r.code !== 0 && /config\.local\.json/.test(r.err) && /botId/.test(r.err),
    'with no channel settings the refusal names the file and what goes in it', r.out + r.err);
})();

// ---------------------------------------------------------------- the log

(function logAddSaysWhichEmoji() {
  const home = newHome();
  const off = logAdd(home, entry(TS_NEW, 1));
  check(off.code === 0 && off.json && off.json.emoji === CHECK, 'an off topic article is owed the check mark', off.out + off.err);
  const changed = logAdd(home, entry(TS_OLD, 2, { kind: 'how-to', outcome: 'changed', reason: 'One change accepted.',
    proposals: [{ summary: 'Shorten the builder brief', decision: 'accepted', issue: 'https://example.com/issues/1' }] }));
  check(changed.code === 0 && changed.json && changed.json.emoji === HANDS, 'an article with an accepted change is owed raised hands', changed.out + changed.err);
  const log = changed.code === 0 ? readLocal(home, 'log.local.json') : { articles: [] };
  check(log.articles.length === 2 && log.articles[0].markedAt === null && log.articles[0].reviewedAt === NOW,
    'the entry is stored unmarked with the time of the review', JSON.stringify(log));
})();

(function logRefusesBadEntries() {
  const home = newHome();
  const kind = logAdd(home, entry(TS_NEW, 1, { kind: 'case-study' }));
  check(kind.code !== 0 && /customer-story/.test(kind.err), 'a kind outside the list is refused and the list is shown', kind.err);
  const outcome = logAdd(home, entry(TS_NEW, 1, { outcome: 'done' }));
  check(outcome.code !== 0 && /off-topic/.test(outcome.err), 'an outcome outside the list is refused', outcome.err);
  const noIssue = logAdd(home, entry(TS_NEW, 1, { kind: 'how-to', outcome: 'changed',
    proposals: [{ summary: 'x', decision: 'accepted' }] }));
  check(noIssue.code !== 0 && /issue/.test(noIssue.err), 'an accepted change with no issue and no draft note is refused', noIssue.err);
  const draft = logAdd(home, entry(TS_NEW, 1, { kind: 'how-to', outcome: 'changed',
    proposals: [{ summary: 'x', decision: 'accepted', draftNote: true }] }));
  check(draft.code === 0, 'an accepted change for someone else\'s system may carry a draft note in place of an issue', draft.err);
  const hollow = logAdd(home, entry(TS_OLD, 2, { kind: 'how-to', outcome: 'changed', proposals: [] }));
  check(hollow.code !== 0 && /accepted/.test(hollow.err), 'an outcome of changed with nothing accepted is refused', hollow.err);
  const sneaky = logAdd(home, entry(TS_OLD, 2, { kind: 'how-to', outcome: 'no-change',
    proposals: [{ summary: 'x', decision: 'accepted', issue: 'https://example.com/issues/2' }] }));
  check(sneaky.code !== 0 && /accepted/.test(sneaky.err), 'an outcome of no change that holds an accepted change is refused', sneaky.err);
  const noReason = logAdd(home, entry(TS_OLD, 2, { reason: '' }));
  check(noReason.code !== 0 && /reason/.test(noReason.err), 'an entry with no reason is refused', noReason.err);
  check(fs.existsSync(localPath(home, 'log.local.json')) && readLocal(home, 'log.local.json').articles.length === 1,
    'only the one good entry reached the log', '');
})();

(function logRefusesASecondEntryUnlessReplacing() {
  const home = newHome();
  logAdd(home, entry(TS_NEW, 1));
  const again = logAdd(home, entry(TS_NEW, 1));
  check(again.code !== 0 && /--replace/.test(again.err), 'a second entry for one post is refused and names the flag for a fresh review', again.err);
  const replaced = logAdd(home, entry(TS_NEW, 1, { kind: 'how-to', outcome: 'no-change', reason: 'Audited, already matches.' }), ['--replace']);
  const log = replaced.code === 0 ? readLocal(home, 'log.local.json') : { articles: [] };
  check(replaced.code === 0 && log.articles.length === 1 && log.articles[0].outcome === 'no-change'
    && log.articles[0].previous.length === 1 && log.articles[0].previous[0].outcome === 'off-topic',
    'a fresh review replaces the entry and keeps the earlier one inside it', replaced.err + JSON.stringify(log));
})();

(function handMarkedNeedsNoKind() {
  const home = newHome();
  const r = logAdd(home, { ts: TS_NEW, url: 'https://example.com/a1', title: 'Article 1', outcome: 'hand-marked', proposals: [] });
  check(r.code === 0 && r.json && r.json.emoji === null, 'a hand marked post is logged with no kind and owes no emoji', r.out + r.err);
  const w = worklist(home, [post(TS_NEW, 1, [mark(CHECK, ['U0OWNER'])])]);
  check(w.code === 0 && w.json && w.json.handMarked.length === 0 && w.json.toReview.length === 0 && w.json.owed.length === 0,
    'once logged, a hand marked post is not listed again', w.out + w.err);
})();

(function backupsRotateAndRestore() {
  const home = newHome();
  logAdd(home, entry('1795000001.000001', 1));
  logAdd(home, entry('1795000002.000001', 2));
  const third = logAdd(home, entry('1795000003.000001', 3));
  if (third.code !== 0) { check(false, 'three entries can be logged before the backup cases', third.err); return; }
  const b1 = readLocal(home, 'log.local.json.1'), b2 = readLocal(home, 'log.local.json.2');
  check(b1.articles.length === 2 && b2.articles.length === 1, 'each write keeps the version before it, newest first', JSON.stringify([b1.articles.length, b2.articles.length]));
  writeLocal(home, 'log.local.json', '{"articles": [');
  const broken = run(home, ['tally']);
  check(broken.code !== 0 && /log-restore/.test(broken.err) && /log\.local\.json\.1/.test(broken.err),
    'a log that cannot be read is refused, naming the newest good backup and how to restore it', broken.err);
  const restored = run(home, ['log-restore', '--from', '1']);
  check(restored.code === 0 && readLocal(home, 'log.local.json').articles.length === 2, 'restoring puts the named backup back', restored.out + restored.err);
  fs.unlinkSync(localPath(home, 'log.local.json'));
  const gone = run(home, ['tally']);
  check(gone.code !== 0 && /log-restore/.test(gone.err), 'a log that vanished while backups remain is a loss, never a first run', gone.err);
})();

(function backupsAreCapped() {
  const home = newHome();
  for (let i = 1; i <= 8; i++) logAdd(home, entry('17950000' + (10 + i) + '.000001', i));
  const names = fs.readdirSync(path.join(home, SKILL_REL)).filter(function (n) { return /^log\.local\.json\.\d+$/.test(n); });
  check(names.length === 5, 'only the 5 newest backups are kept', names.join(' '));
})();

guarded('the two sessions case', function aStaleWriteIsRefused() {
  const home = newHome();
  logAdd(home, entry('1795000001.000001', 1));
  const savedHome = process.env.HOME;
  process.env.HOME = home;
  try {
    const lib = require(REVIEW);
    const mine = lib.readLog();                         // this session reads the log
    logAdd(home, entry('1795000002.000001', 2));        // another session writes to it
    mine.articles.push(Object.assign(entry('1795000003.000001', 3), { reviewedAt: NOW, markedAt: null }));
    let refused = null;
    try { lib.writeLog(mine); } catch (e) { refused = e; }
    const onDisk = readLocal(home, 'log.local.json').articles.map(function (a) { return a.ts; });
    check(refused !== null && /changed/.test(refused.message) && onDisk.length === 2 && onDisk[1] === '1795000002.000001',
      'a write built on a read that another session has since overtaken is refused, and the other session\'s entry survives',
      (refused && refused.message) + ' ' + onDisk.join(' '));
    let clean = null;
    const fresh = lib.readLog();
    fresh.articles.push(Object.assign(entry('1795000003.000001', 3), { reviewedAt: NOW, markedAt: null }));
    try { lib.writeLog(fresh); } catch (e) { clean = e; }
    check(clean === null && readLocal(home, 'log.local.json').articles.length === 3, 'a write built on the current log goes through', clean && clean.message);
  } finally { process.env.HOME = savedHome; }
});

(function declinedProposalsAreListed() {
  const home = newHome();
  logAdd(home, entry(TS_NEW, 1, { kind: 'how-to', outcome: 'no-change', reason: 'One proposal, declined.',
    proposals: [{ summary: 'Drop the plan first rule', decision: 'declined', declineReason: 'Kept on purpose.' }] }));
  const r = run(home, ['declined']);
  check(r.code === 0 && r.json && r.json.declined.length === 1 && r.json.declined[0].summary === 'Drop the plan first rule'
    && r.json.declined[0].declineReason === 'Kept on purpose.' && r.json.declined[0].url === 'https://example.com/a1',
    'declined proposals come back with their reason and the article they came from', r.out + r.err);
})();

guarded('declines from before a fresh review', function declinesSurviveAReplace() {
  const home = newHome();
  logAdd(home, entry(TS_NEW, 1, { kind: 'how-to', outcome: 'no-change', reason: 'One proposal, declined.',
    proposals: [{ summary: 'Drop the plan first rule', decision: 'declined', declineReason: 'Kept on purpose.' }] }));
  logAdd(home, entry(TS_NEW, 1, { kind: 'how-to', outcome: 'no-change', reason: 'Reviewed again, nothing new.' }), ['--replace']);
  const r = run(home, ['declined']);
  check(r.code === 0 && r.json && r.json.declined.length === 1 && r.json.declined[0].summary === 'Drop the plan first rule',
    'a proposal declined in an earlier review of a post is still listed after a fresh review replaces the entry', r.out + r.err);
});

guarded('a repeat of an article that led to a change', function aRepeatTakesItsOutcomeFromTheLog() {
  const home = newHome();
  logAdd(home, entry(TS_OLD, 1, { kind: 'how-to', outcome: 'changed', reason: 'One change accepted.',
    proposals: [{ summary: 'Shorten the builder brief', decision: 'accepted', issue: 'https://example.com/issues/1' }] }));
  const r = logAdd(home, { ts: TS_NEW, url: 'https://example.com/a1', title: 'Article 1', repeatOf: TS_OLD });
  const stored = r.code === 0 ? readLocal(home, 'log.local.json').articles[1] : {};
  check(r.code === 0 && r.json && r.json.emoji === HANDS && stored.outcome === 'changed' && stored.kind === 'how-to'
    && stored.repeatOf === TS_OLD && stored.proposals.length === 0,
    'a repeat names the earlier post and takes its kind, outcome and emoji from the log, with no proposals of its own', r.out + r.err + JSON.stringify(stored));
  const wrong = logAdd(home, { ts: '1795529999.000001', url: 'https://example.com/a1', title: 'Article 1', repeatOf: '1.000001' });
  check(wrong.code !== 0 && /1\.000001/.test(wrong.err), 'a repeat of a post the log does not hold is refused', wrong.err);
  const lying = logAdd(home, { ts: '1795529999.000001', url: 'https://example.com/a1', title: 'Article 1', repeatOf: TS_OLD, outcome: 'off-topic', kind: 'how-to', reason: 'x' });
  check(lying.code !== 0 && /changed/.test(lying.err), 'a repeat that claims a different outcome from the earlier post is refused', lying.err);
});

guarded('the held lock case', function aHeldLockIsWaitedForThenRefused() {
  const home = newHome();
  logAdd(home, entry('1795000001.000001', 1));
  const lock = localPath(home, 'log.local.json.lock');
  fs.mkdirSync(lock);
  fs.writeFileSync(path.join(lock, 'pid'), String(process.pid));   // a live holder: this test
  const held = logAdd(home, entry('1795000002.000001', 2), ['--lock-wait', '150']);
  check(held.code !== 0 && /another session/.test(held.err) && readLocal(home, 'log.local.json').articles.length === 1 && fs.existsSync(lock),
    'while a live session holds the log, a write waits, then is refused, and leaves the lock alone', held.err);
  const dead = spawnSync('node', ['-e', 'process.stdout.write(String(process.pid))'], { encoding: 'utf8' });
  fs.writeFileSync(path.join(lock, 'pid'), dead.stdout);            // a holder that has exited
  const taken = logAdd(home, entry('1795000002.000001', 2), ['--lock-wait', '150']);
  check(taken.code === 0 && readLocal(home, 'log.local.json').articles.length === 2 && !fs.existsSync(lock),
    'a lock left by a session that died is taken over, and released after the write', taken.out + taken.err);
});

guarded('the lock with no owner case', function anOwnerlessLockAgesOut() {
  const home = newHome();
  logAdd(home, entry('1795000001.000001', 1));
  const lock = localPath(home, 'log.local.json.lock');
  fs.mkdirSync(lock);                                              // made, and its maker died before naming itself
  const young = logAdd(home, entry('1795000002.000001', 2), ['--lock-wait', '100']);
  check(young.code !== 0 && /another session/.test(young.err) && fs.existsSync(lock),
    'a lock that names no owner yet is waited for while it is new, since its maker may be about to', young.err);
  const longAgo = new Date(Date.now() - 120000);
  fs.utimesSync(lock, longAgo, longAgo);
  const old = logAdd(home, entry('1795000002.000001', 2), ['--lock-wait', '100']);
  check(old.code === 0 && readLocal(home, 'log.local.json').articles.length === 2 && !fs.existsSync(lock),
    'a lock that names no owner and is older than any write could take is taken over', old.out + old.err);
});

guarded('restoring under the lock', function restoreWaitsForTheLock() {
  const home = newHome();
  logAdd(home, entry('1795000001.000001', 1));
  logAdd(home, entry('1795000002.000001', 2));
  const lock = localPath(home, 'log.local.json.lock');
  fs.mkdirSync(lock);
  fs.writeFileSync(path.join(lock, 'pid'), String(process.pid));
  const r = run(home, ['log-restore', '--from', '1', '--lock-wait', '100']);
  check(r.code !== 0 && /another session/.test(r.err) && readLocal(home, 'log.local.json').articles.length === 2,
    'a restore is refused while another session holds the log, and replaces nothing', r.out + r.err);
});

(function inheritedNamesAreNotFlags() {
  const r = run(newHome(), ['tally', '--constructor']);
  check(r.code !== 0 && /needs a value/.test(r.err), 'an option that only looks like a flag because every object has it is not taken for one', r.out + r.err);
})();

// ---------------------------------------------------------------- the track record

let seeded = 0;
function seedOffTopic(home, kind, n) {
  for (let i = 0; i < n; i++) {
    seeded++;
    const r = logAdd(home, entry('1796' + String(100000 + seeded) + '.000001', 'seed' + seeded, { kind: kind }));
    if (r.code !== 0) throw new Error('seed failed: ' + r.err);
  }
}
function guarded(name, fn) {
  try { fn(); } catch (e) { check(false, name + ' could run', e.message); }
}

guarded('the tally by kind', function tallyCountsByKind() {
  const home = newHome();
  seedOffTopic(home, 'customer-story', 5);
  seedOffTopic(home, 'industry-solution', 4);
  logAdd(home, { ts: '1797000001.000001', url: 'https://example.com/h', title: 'H', outcome: 'hand-marked', proposals: [] });
  const r = run(home, ['tally']);
  const cs = r.json && r.json.kinds['customer-story'];
  check(r.code === 0 && cs && cs.reviewed === 5 && cs.offTopic === 5 && r.json.handMarked === 1,
    'the tally counts reviews by kind and keeps hand marked posts out of every kind', r.out + r.err);
  check(r.json && r.json.dueForFeedSuggestion.length === 1 && r.json.dueForFeedSuggestion[0] === 'customer-story',
    'a kind reviewed 5 times and off topic every time is due a suggestion; one reviewed 4 times is not', r.out);
});

guarded('the repeated post case', function aRepeatIsCountedOnce() {
  const home = newHome();
  seedOffTopic(home, 'customer-story', 4);
  const first = readLocal(home, 'log.local.json').articles[0];
  const again = logAdd(home, { ts: '1797000009.000001', url: first.url, title: first.title, repeatOf: first.ts });
  const r = run(home, ['tally']);
  check(again.code === 0 && r.code === 0 && r.json && r.json.kinds['customer-story'].reviewed === 4 && r.json.dueForFeedSuggestion.length === 0,
    'a repeated post is logged but adds nothing to its kind\'s count', again.err + r.out + r.err);
});

guarded('the relevant article case', function oneRelevantArticleKeepsAKind() {
  const home = newHome();
  seedOffTopic(home, 'product-launch', 6);
  logAdd(home, entry('1797000002.000001', 'pl', { kind: 'product-launch', outcome: 'no-change', reason: 'Audited, nothing to change.' }));
  const r = run(home, ['tally']);
  check(r.code === 0 && r.json && r.json.kinds['product-launch'].reviewed === 7 && r.json.dueForFeedSuggestion.length === 0,
    'a kind with even one article worth auditing is never due a suggestion', r.out + r.err);
});

guarded('the repeated suggestion case', function suggestionIsNotRepeatedUntilFiveMore() {
  const home = newHome();
  seedOffTopic(home, 'customer-story', 5);
  const rec = run(home, ['feed-suggested', '--kind', 'customer-story', '--decision', 'declined', '--now', NOW]);
  check(rec.code === 0, 'a suggestion and its answer can be recorded', rec.err);
  seedOffTopic(home, 'customer-story', 4);
  const four = run(home, ['tally']);
  check(four.json && four.json.dueForFeedSuggestion.length === 0, 'a declined suggestion is not made again after 4 more', four.out + four.err);
  seedOffTopic(home, 'customer-story', 1);
  const five = run(home, ['tally']);
  check(five.json && five.json.dueForFeedSuggestion.length === 1, 'it is made again once 5 more have gone the same way', five.out + five.err);
  const bad = run(home, ['feed-suggested', '--kind', 'case-study', '--decision', 'declined', '--now', NOW]);
  check(bad.code !== 0 && /customer-story/.test(bad.err), 'a suggestion for a kind outside the list is refused', bad.err);
  // A recorded suggestion whose count cannot be read must not silence the kind for good (L50).
  const log = readLocal(home, 'log.local.json');
  log.feedSuggestions = [{ kind: 'customer-story', decision: 'declined', at: NOW }];
  writeLocal(home, 'log.local.json', log);
  const unread = run(home, ['tally']);
  check(unread.json && unread.json.dueForFeedSuggestion.length === 1, 'a recorded suggestion with no readable count does not stop the kind coming due', unread.out + unread.err);
});

// ---------------------------------------------------------------- app descriptions

function git(cwd, args) {
  const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'init.defaultBranch=main'].concat(args),
    { cwd: cwd, encoding: 'utf8' });
  if (r.status !== 0) throw new Error('git ' + args.join(' ') + ': ' + r.stderr);
  return r.stdout;
}
let repos = 0;
// A working folder with a local origin. Files are committed and pushed, so origin/main holds them.
function makeRepo(files) {
  const base = path.join(SCRATCH, 'repo ' + (++repos));
  const origin = path.join(base, 'origin.git'), work = path.join(base, 'work');
  fs.mkdirSync(origin, { recursive: true });
  git(origin, ['init', '--bare', '--quiet']);
  git(base, ['clone', '--quiet', origin, 'work']);
  commitFiles(work, files);
  return { origin: origin, work: work, base: base };
}
function commitFiles(work, files) {
  Object.keys(files).forEach(function (rel) {
    fs.mkdirSync(path.dirname(path.join(work, rel)), { recursive: true });
    fs.writeFileSync(path.join(work, rel), files[rel]);
  });
  git(work, ['add', '--all']);
  git(work, ['commit', '--quiet', '-m', 'files']);
  git(work, ['push', '--quiet', 'origin', 'HEAD:main']);
}
function appEntry(name, work, more) {
  return Object.assign({ name: name, repo: 'acme/' + name, path: work, mine: true,
    description: 'Calls Claude to draft replies.' }, more || {});
}
const PKG = JSON.stringify({ dependencies: { '@anthropic-ai/sdk': '1.0.0', react: '19.0.0' } });
function modelFiles(n) {
  const files = { 'package.json': PKG, 'README.md': 'uses anthropic', 'src/plain.ts': 'export const a = 1;' };
  for (let i = 0; i < n; i++) files['src/m' + i + '.ts'] = 'const model = "claude-opus-5-5";';
  return files;
}
function appsSet(home, e) { return run(home, ['apps-set', '--entry', tmpJson(e), '--now', NOW]); }
function appsCheck(home) { return run(home, ['apps-check', '--now', NOW]); }

guarded('storing an app', function appsSetMeasuresFromOrigin() {
  const home = newHome();
  const repo = makeRepo(modelFiles(3));
  const r = appsSet(home, appEntry('alpha', repo.work));
  const apps = r.code === 0 ? readLocal(home, 'apps.local.json').apps : [];
  check(r.code === 0 && apps.length === 1 && apps[0].facts.modelFiles === 3
    && apps[0].facts.aiPackages.join(',') === '@anthropic-ai/sdk' && apps[0].facts.measuredAt === NOW,
    'an app is stored with its AI packages and the count of source files naming a model, docs left out', r.out + r.err + JSON.stringify(apps));
});

guarded('the parked folder case', function appsCheckReadsOriginNotTheFolder() {
  const home = newHome();
  const repo = makeRepo(modelFiles(10));
  appsSet(home, appEntry('alpha', repo.work));
  // Someone else pushes 10 more model files to origin; this working folder stays parked behind.
  const other = path.join(repo.base, 'other');
  git(repo.base, ['clone', '--quiet', repo.origin, 'other']);
  const more = {}; for (let i = 10; i < 20; i++) more['src/m' + i + '.ts'] = 'const model = "claude-opus-5-5";';
  commitFiles(other, more);
  const head = git(repo.work, ['rev-parse', 'HEAD']);
  const r = appsCheck(home);
  const a = r.json && r.json.apps[0];
  check(r.code === 0 && a && a.state === 'stale' && a.measured.modelFiles === 20 && /10/.test(a.why) && /20/.test(a.why),
    'a check measures the latest main on the remote, so a parked folder still reads as stale', r.out + r.err);
  check(git(repo.work, ['rev-parse', 'HEAD']) === head && git(repo.work, ['status', '--porcelain']) === '',
    'the check leaves the working folder exactly where it was', '');
});

guarded('the small drift case', function smallDriftIsNotStale() {
  const home = newHome();
  const repo = makeRepo(modelFiles(20));
  appsSet(home, appEntry('alpha', repo.work));
  commitFiles(repo.work, { 'src/extra1.ts': 'const model = "claude-opus-5-5";', 'src/extra2.ts': 'import Anthropic from "anthropic";' });
  const r = appsCheck(home);
  check(r.code === 0 && r.json && r.json.apps[0].state === 'current' && r.json.apps[0].measured.modelFiles === 22,
    '2 more files on 20 is ordinary churn and leaves the description current', r.out + r.err);
});

guarded('the first AI use case', function firstAiUseIsStale() {
  const home = newHome();
  const repo = makeRepo({ 'package.json': JSON.stringify({ dependencies: { react: '19.0.0' } }), 'src/a.ts': 'export const a = 1;' });
  appsSet(home, appEntry('beta', repo.work, { description: 'Does not call a model.' }));
  commitFiles(repo.work, { 'src/ai.ts': 'const model = "claude-haiku-5-5";' });
  const r = appsCheck(home);
  check(r.code === 0 && r.json && r.json.apps[0].state === 'stale',
    'an app that named no model and now names one is stale, however small the change', r.out + r.err);
});

guarded('the new package case', function newPackageIsStale() {
  const home = newHome();
  const repo = makeRepo(modelFiles(20));
  appsSet(home, appEntry('alpha', repo.work));
  commitFiles(repo.work, { 'apps/web/package.json': JSON.stringify({ devDependencies: { agents: '0.2.0' } }) });
  const r = appsCheck(home);
  check(r.code === 0 && r.json && r.json.apps[0].state === 'stale' && /agents/.test(r.json.apps[0].why),
    'a new AI package in any package.json makes the description stale and is named', r.out + r.err);
});

guarded('the unreadable package file case', function aBrokenPackageFileIsNamed() {
  const home = newHome();
  const files = modelFiles(1);
  files['apps/broken/package.json'] = '{ "dependencies": { "openai": ';
  const repo = makeRepo(files);
  const set = appsSet(home, appEntry('alpha', repo.work));
  const r = appsCheck(home);
  const a = r.json && r.json.apps[0];
  check(set.code === 0 && a && a.measured.unreadablePackageFiles.join(',') === 'apps/broken/package.json'
    && a.measured.aiPackages.join(',') === '@anthropic-ai/sdk',
    'a package.json that cannot be read is named in the measurement, never skipped without a word', set.err + r.out + r.err);
});

guarded('the system with no repository', function systemsWithoutARepoAreUnmeasured() {
  const home = newHome();
  const set = appsSet(home, { name: 'crm', repo: null, path: null, mine: false, description: 'The sales CRM, run by another team.' });
  const r = appsCheck(home);
  check(set.code === 0 && r.code === 0 && r.json && r.json.apps[0].state === 'unmeasured' && r.json.apps[0].mine === false,
    'a system with no repository is kept with its description and reported as unmeasured, never as current', set.err + r.out + r.err);
});

guarded('the broken app case', function aBrokenAppIsLoud() {
  const home = newHome();
  const repo = makeRepo(modelFiles(2));
  appsSet(home, appEntry('alpha', repo.work));
  fs.rmSync(repo.work, { recursive: true, force: true });
  const r = appsCheck(home);
  check(r.code !== 0 && r.json && r.json.apps[0].state === 'failed' && r.json.apps[0].why.length > 0,
    'an app whose folder cannot be measured is reported as failed and the command exits non zero', r.out + r.err);
});

guarded('two sessions describing apps', function appWritesTakeTheirOwnLock() {
  const home = newHome();
  const repo = makeRepo(modelFiles(1));
  appsSet(home, appEntry('alpha', repo.work));
  const lock = localPath(home, 'apps.local.json.lock');
  fs.mkdirSync(lock);
  fs.writeFileSync(path.join(lock, 'pid'), String(process.pid));
  const r = run(home, ['apps-set', '--entry', tmpJson(appEntry('beta', repo.work)), '--now', NOW, '--lock-wait', '100']);
  check(r.code !== 0 && /another session/.test(r.err) && readLocal(home, 'apps.local.json').apps.length === 1,
    'an app description is not written while another session holds the app descriptions', r.out + r.err);
  fs.rmSync(lock, { recursive: true, force: true });
  const ok = run(home, ['apps-set', '--entry', tmpJson(appEntry('beta', repo.work)), '--now', NOW, '--lock-wait', '100']);
  check(ok.code === 0 && readLocal(home, 'apps.local.json').apps.length === 2, 'and is written once the lock is free', ok.out + ok.err);
});

guarded('the hung remote case', function aSlowRemoteIsAFailureNotAStall() {
  const home = newHome();
  const repo = makeRepo(modelFiles(2));
  appsSet(home, appEntry('alpha', repo.work));
  // A limit no git command can meet stands in for a remote that never answers.
  const r = run(home, ['apps-check', '--now', NOW, '--git-timeout', '1']);
  check(r.code !== 0 && r.json && r.json.apps[0].state === 'failed' && /did not finish/.test(r.json.apps[0].why),
    'a git command that outlasts its limit is stopped and the app reported as failed', r.out + r.err);
});

guarded('refused app entries', function appsSetRefusesBadEntries() {
  const home = newHome();
  const repo = makeRepo(modelFiles(1));
  const noMine = appEntry('alpha', repo.work); delete noMine.mine;
  const a = appsSet(home, noMine);
  check(a.code !== 0 && /mine/.test(a.err), 'an app that does not say whether it is the owner\'s is refused', a.err);
  const b = appsSet(home, appEntry('alpha', repo.work, { description: ' ' }));
  check(b.code !== 0 && /description/.test(b.err), 'an app with no description is refused', b.err);
  const none = appsCheck(home);
  check(none.code !== 0 && /apps\.local\.json/.test(none.err), 'a check with no app descriptions on this Mac is refused, never an empty all clear', none.out + none.err);
});

guarded('updating an app', function appsSetUpdatesInPlace() {
  const home = newHome();
  const repo = makeRepo(modelFiles(1));
  appsSet(home, appEntry('alpha', repo.work));
  const second = appsSet(home, appEntry('alpha', repo.work, { description: 'Rewritten.' }));
  const apps = second.code === 0 ? readLocal(home, 'apps.local.json').apps : [];
  check(apps.length === 1 && apps[0].description === 'Rewritten.', 'setting an app again updates it in place', second.err + JSON.stringify(apps));
});

(function vocabularyIsPrinted() {
  const r = run(newHome({ config: false }), ['vocabulary']);
  check(r.code === 0 && r.json && r.json.kinds.indexOf('customer-story') !== -1 && r.json.outcomes.join(',') === 'off-topic,no-change,changed,hand-marked'
    && r.json.emoji.changed === HANDS && r.json.emoji['off-topic'] === CHECK && r.json.emoji['hand-marked'] === null && r.json.feedThreshold === 5,
    'the kinds, the outcomes and the emoji each outcome earns can be read from the script, with no settings needed', r.out + r.err);
  const none = run(newHome(), ['nonsense']);
  check(none.code !== 0 && /worklist/.test(none.err), 'an unknown command is refused and the commands are listed', none.err);
})();

// An Agent call that names no model runs on the session's model, so a step that dispatches agents
// and names none sends them to whatever Dan is chatting on (claude-config#3604). The script never
// dispatches, the session does, from the skill's text: so the text is what is held here.
(function agentStepsNameTheirModel() {
  const skill = fs.readFileSync(path.resolve(__dirname, '..', 'SKILL.md'), 'utf8').split('\n');
  const step = function (n) { return skill.filter(function (l) { return l.indexOf(n + '. **') === 0; }); };
  const audit = step(9), checker = step(10);
  check(audit.length === 1 && /audit agent/.test(audit[0]) && audit[0].indexOf('`model: "opus"`') !== -1
    && audit[0].indexOf('`model: "fable"`') !== -1 && /security or compliance/.test(audit[0])
    && audit[0].indexOf('Which model a builder runs on') !== -1,
    'the audit step names Opus for its agents, Fable for a security or compliance article, and points at the builder rule for the split', audit.join('\n'));
  check(checker.length === 1 && /checker agent/.test(checker[0]) && checker[0].indexOf('`model: "opus"`') !== -1,
    'the checker step names Opus for its agent', checker.join('\n'));
})();

fs.rmSync(SCRATCH, { recursive: true, force: true });
console.log('SUITE-RESULT passed=' + passed + ' failed=' + failed);
process.exit(failed === 0 ? 0 : 1);
