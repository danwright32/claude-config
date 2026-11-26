'use strict';
// Cases for announce-compare.js's judgement of a Slack draft of an announcement (claude-config#3667),
// and for its claimed wording check (claimedWording and the `claimed` command line): only the
// wording whose hash the pull request claimed in the record of approvals is drafted.
// The "found posted" half of that file keeps its cases in the dev update skill's suite
// (skills/pennie-dev-update/tests/scripts.test.js), which is where its command line lives.
//
// Run by test-announce-compare.sh, which passes on the tally printed at the end.

const path = require('path');
const childProcess = require('child_process');
const LIB = path.join(__dirname, 'announce-compare.js');
// Spelled out in the require, as changelog-entry.test.js spells its own, so the installer that
// copies a helper with the files it requires (lib/install-hook-libs.py) can read which file this is.
const compare = require(path.join(__dirname, 'announce-compare.js'));

let passed = 0;
let failed = 0;
function check(ok, what, got) {
  if (ok) { passed++; return; }
  failed++;
  console.log('  FAIL: ' + what + (got === undefined ? '' : ': ' + String(got).slice(0, 400)));
}

const HY = String.fromCharCode(45);
const POST = '@here\n**Handing a call back**\n\nYou can now hand a call back to the queue & pick a reason.\n\n'
  + HY + ' Press Hand back\n' + HY + ' Read [the guide](https://example.com/guide?a=1)';
// What Slack answered a draft it kept, and one it did not (measured 2026-11-25, claude-config#3664):
// the first holds a draft_id, the second says "Draft created" and holds none.
const KEPT = { text: '{"result":"Draft created","draft_id":"Dr0123ABC","channel_link":"https://example.slack.com/archives/C0123456789"}' };
const NOT_KEPT = { text: '{"result":"Draft created","channel_link":"https://example.slack.com/archives/C0123456789"}' };

const judge = compare.judgeDraft;
check(typeof judge === 'function', 'announce-compare.js has no judgeDraft');

if (typeof judge === 'function') {
  let j = judge({ text: POST, message: POST, answer: KEPT });
  check(j.state === 'saved' && j.draftId === 'Dr0123ABC', 'a draft Slack kept, holding the approved wording, is not judged saved with its id', JSON.stringify(j));

  // Words only: Slack's own marks, a blank line more or fewer, and its entity for & change nothing.
  const asSlack = '<!here>\n*Handing a call back*\nYou can now hand a call back to the queue &amp; pick a reason.\n\n\n'
    + '• Press Hand back\n• Read <https://example.com/guide?a=1|the guide>';
  j = judge({ text: POST, message: asSlack, answer: KEPT });
  check(j.state === 'saved', 'a draft that differs only in markup, bullets, blank lines and entities is not judged saved', JSON.stringify(j));

  // R8: one word changed, a line dropped, a line added: each is a draft that differs, never saved.
  j = judge({ text: POST, message: POST.replace('pick a reason', 'choose a reason'), answer: KEPT });
  check(j.state === 'differs' && j.draftId === 'Dr0123ABC' && /choose/.test(j.why) && /pick/.test(j.why), 'a draft with one word changed is not judged as differing, naming the word', JSON.stringify(j));
  j = judge({ text: POST, message: POST.split('\n').slice(0, -1).join('\n'), answer: KEPT });
  check(j.state === 'differs' && /ends/.test(j.why), 'a draft missing its last line is not judged as differing', JSON.stringify(j));
  j = judge({ text: POST, message: POST + '\nThanks all', answer: KEPT });
  check(j.state === 'differs' && /goes on/.test(j.why), 'a draft with a line added is not judged as differing', JSON.stringify(j));
  j = judge({ text: POST, message: 'Before that. ' + POST, answer: KEPT });
  check(j.state === 'differs', 'a draft with words put before the approved wording is not judged as differing', JSON.stringify(j));

  // No draft_id: Slack kept nothing, whatever its words say, and the wording is not even compared.
  j = judge({ text: POST, message: POST, answer: NOT_KEPT });
  check(j.state === 'not-kept' && /draft_id/.test(j.why) && /already waiting/.test(j.why), 'an answer holding no draft_id is not judged as nothing kept', JSON.stringify(j));
  j = judge({ text: POST, message: 'something else', answer: NOT_KEPT });
  check(j.state === 'not-kept', 'an answer holding no draft_id, beside a draft whose words differ, is not judged not kept', JSON.stringify(j));
  ['{"result":"Draft created","draft_id":null}', '{"result":"Draft created","draft_id":""}', 'Draft created'].forEach(function (text) {
    const k = judge({ text: POST, message: POST, answer: { text: text } });
    check(k.state === 'not-kept', 'an answer with an empty or null draft_id is not judged not kept (' + text + ')', JSON.stringify(k));
  });
  // The id is read wherever the answer carries it: plain words, or JSON inside a JSON string.
  j = judge({ text: POST, message: POST, answer: { text: 'Draft created. draft_id: Dr9' } });
  check(j.state === 'saved' && j.draftId === 'Dr9', 'a draft_id given in plain words is not read', JSON.stringify(j));
  j = judge({ text: POST, message: POST, answer: { text: JSON.stringify({ content: [{ type: 'text', text: '{"draft_id":"Dr7"}' }] }) } });
  check(j.state === 'saved' && j.draftId === 'Dr7', 'a draft_id inside a JSON string is not read', JSON.stringify(j));

  // Each error Slack's draft tool names has a sentence of its own, and none of them is a saved draft.
  const seen = {};
  ['attached_draft_exists', 'channel_not_found', 'not_in_channel', 'failed_to_create_draft', 'invalid_thread_ts', 'thread_not_found'].forEach(function (name) {
    const k = judge({ text: POST, message: POST, answer: { text: '{"ok":false,"error":"' + name + '"}', isError: true } });
    check(k.state === 'error' && k.error === name && k.why.indexOf(name) !== -1, name + ' is not judged as that error', JSON.stringify(k));
    check(!seen[k.why.replace(name, '')], name + ' shares its sentence with another error', k.why);
    seen[k.why.replace(name, '')] = true;
  });
  // An error names itself even beside a draft_id, and one that names nothing is still no saved draft.
  j = judge({ text: POST, message: POST, answer: { text: '{"ok":false,"error":"not_in_channel","draft_id":"Dr1"}' } });
  check(j.state === 'error' && j.error === 'not_in_channel', 'an answer naming an error beside a draft_id is not judged as that error', JSON.stringify(j));
  j = judge({ text: POST, message: POST, answer: { text: 'Something went wrong', isError: true } });
  check(j.state === 'error' && j.error === '' && /Something went wrong/.test(j.why), 'an answer marked as an error that names none is not judged an error, quoting it', JSON.stringify(j));
  j = judge({ text: POST, message: POST, answer: { text: '{"ok":false}' } });
  check(j.state === 'error', 'an answer saying ok false is not judged an error', JSON.stringify(j));

  // What cannot be judged is refused, never judged saved (L98): no wording, no draft text, no answer.
  [{ message: POST, answer: KEPT }, { text: '   ', message: POST, answer: KEPT }, { text: '**', message: POST, answer: KEPT },
    { text: POST, answer: KEPT }, { text: POST, message: POST }, { text: POST, message: POST, answer: {} }, null, 'x'].forEach(function (input) {
    let threw = '';
    try { judge(input); } catch (e) { threw = e.message; }
    check(threw !== '', 'an input that cannot be judged was judged', JSON.stringify(input));
  });
}

// The command line the is it live mod asks: `draft`, the input as JSON on
// standard input. Every judgement exits 0; an input that cannot be judged exits 2 with why.
function cli(args, input) {
  const r = childProcess.spawnSync(process.execPath, [LIB].concat(args), { input: input, encoding: 'utf8' });
  let json = null;
  try { json = JSON.parse(r.stdout); } catch (e) { json = null; }
  return { status: r.status, json: json, stderr: r.stderr };
}
let c = cli(['draft'], JSON.stringify({ text: POST, message: POST, answer: KEPT }));
check(c.status === 0 && c.json && c.json.state === 'saved' && c.json.draftId === 'Dr0123ABC', 'the draft command did not judge a kept draft saved', JSON.stringify(c));
c = cli(['draft'], JSON.stringify({ text: POST, message: POST, answer: NOT_KEPT }));
check(c.status === 0 && c.json && c.json.state === 'not-kept', 'the draft command did not exit 0 on a draft that was not kept', JSON.stringify(c));
c = cli(['draft'], 'not json');
check(c.status === 2 && c.json === null && /could not be read as JSON/.test(c.stderr), 'the draft command judged an input that is not JSON', JSON.stringify(c));
c = cli(['draft'], JSON.stringify({ message: POST, answer: KEPT }));
check(c.status === 2 && c.json === null && /wording/.test(c.stderr), 'the draft command judged an input with no wording', JSON.stringify(c));
c = cli([], '');
check(c.status === 2 && /Usage/.test(c.stderr), 'no command did not print the usage and exit 2', JSON.stringify(c));
c = cli(['constructor'], '');
check(c.status === 2 && /Usage/.test(c.stderr), 'a command nobody defined did not print the usage and exit 2', JSON.stringify(c));

// ---- R8: only the wording the pull request merged on is drafted (claimedWording) ----
// A pull request's description can be edited after its merge by a command no hook judges, so the
// block read then is drafted only when its hash is the one the record of approvals holds as claimed
// by that pull request at the merge gate. The record here is a scratch one, under the system's
// temporary folder: the real record is never named, read or written by this suite.
const fs = require('fs');
const os = require('os');
const entry = require(path.join(__dirname, 'changelog-entry.js'));
const claimed = compare.claimedWording;
check(typeof claimed === 'function', 'announce-compare.js has no claimedWording');

if (typeof claimed === 'function') {
  const HASH = entry.announcementHash(POST);
  const OTHER = POST.replace('Press Hand back', 'Press Return call');
  const approvedLine = function (hash) { return { kind: 'approved', repo: 'acme/widget', hash: hash, at: '2026-11-25T10:00:00Z', session: 's1', picker: 'toolu_1' }; };
  const claimLine = function (hash, pr, repo) { return { kind: 'used', repo: repo || 'acme/widget', hash: hash, pr: pr, claim: true, closes: null, unread: null, at: '2026-11-25T10:05:00Z' }; };
  const listed = function (entries) { return { record: '/scratch/record.jsonl', entries: entries, why: '' }; };
  const ask = function (text, entries, more) { return claimed(Object.assign({ repo: 'acme/widget', pr: 7, text: text, listed: listed(entries) }, more || {})); };

  let v = ask(POST, [approvedLine(HASH), claimLine(HASH, 7)]);
  check(v.state === 'approved', 'the wording pull request 7 merged on is not judged approved', JSON.stringify(v));
  // One normalised form: line endings, spaces at line ends and blank lines change no hash.
  v = ask(POST.replace(/\n/g, '\r\n') + '  \n\n', [approvedLine(HASH), claimLine(HASH, 7)]);
  check(v.state === 'approved', 'the same wording with other line endings and blank lines is not judged approved', JSON.stringify(v));
  v = ask(POST, [approvedLine(HASH), claimLine(HASH, 7)], { repo: 'Acme/Widget' });
  check(v.state === 'approved', 'the repository named in another case is not the one the record names', JSON.stringify(v));

  v = ask(OTHER, [approvedLine(HASH), claimLine(HASH, 7)]);
  check(v.state === 'changed' && typeof v.why === 'string' && v.why !== '', 'wording changed by one word after the merge is not judged changed, with why', JSON.stringify(v));
  // Wording Dan approved for the repository, which this pull request never merged on, is still changed wording.
  v = ask(OTHER, [approvedLine(HASH), approvedLine(entry.announcementHash(OTHER)), claimLine(HASH, 7)]);
  check(v.state === 'changed', 'wording approved for the repository but never claimed by this pull request was judged approved', JSON.stringify(v));

  // No claim by this pull request reads as unread, never as approved: another pull request's claim,
  // an approval nobody used, a line naming the issues it closes, and another repository's claim.
  [
    ['another pull request claimed that wording', [approvedLine(HASH), claimLine(HASH, 8)]],
    ['the approval was never used', [approvedLine(HASH)]],
    ['only the line naming the issues it closes names it', [approvedLine(HASH), { kind: 'used', repo: 'acme/widget', hash: HASH, pr: 7, closes: [], at: 'x' }]],
    ['the claim is another repository\'s', [approvedLine(HASH), claimLine(HASH, 7, 'acme/other')]],
    ['the record is empty', []],
    ['the claim line holds no hash', [{ kind: 'used', repo: 'acme/widget', pr: 7, claim: true }]],
  ].forEach(function (c) {
    const r = ask(POST, c[1]);
    check(r.state === 'unread' && /names no approval/.test(r.why || ''), 'no claim by pull request 7 (' + c[0] + ') was not judged unread, saying the record names none', JSON.stringify(r));
  });

  // The latest claim is the one it merged on: wording approved and claimed earlier, then replaced, is changed.
  const LATER = entry.announcementHash(OTHER);
  v = ask(POST, [approvedLine(HASH), claimLine(HASH, 7), approvedLine(LATER), claimLine(LATER, 7)]);
  check(v.state === 'changed', 'wording the pull request claimed before its latest claim was judged approved', JSON.stringify(v));
  v = ask(OTHER, [approvedLine(HASH), claimLine(HASH, 7), approvedLine(LATER), claimLine(LATER, 7)]);
  check(v.state === 'approved', 'the wording of the pull request\'s latest claim is not judged approved', JSON.stringify(v));

  // A record that could not be read is unread with the reason it gave, never an empty record.
  v = claimed({ repo: 'acme/widget', pr: 7, text: POST, listed: { record: '/scratch/record.jsonl', entries: null, why: 'the record could not be read (PermissionError)' } });
  check(v.state === 'unread' && /PermissionError/.test(v.why || ''), 'a record that could not be read is not judged unread with its reason', JSON.stringify(v));
  [undefined, null, 'x', {}, { entries: 'no' }].forEach(function (bad) {
    const r = claimed({ repo: 'acme/widget', pr: 7, text: POST, listed: bad });
    check(r.state === 'unread' && typeof r.why === 'string' && r.why !== '', 'a listing that is no list of the record was not judged unread, with why', JSON.stringify([bad, r]));
  });

  // What cannot be asked throws: never a verdict about nothing (L98).
  [
    { repo: 'acme/widget', pr: 7, text: ' \n ', listed: listed([]) },
    { repo: 'acme/widget', pr: 7, listed: listed([]) },
    { repo: 'acme/widget', pr: 0, text: POST, listed: listed([]) },
    { repo: 'acme/widget', pr: '7', text: POST, listed: listed([]) },
    { repo: 'widget', pr: 7, text: POST, listed: listed([]) },
    null,
  ].forEach(function (input) {
    let threw = '';
    try { claimed(input); } catch (e) { threw = e.message; }
    check(threw !== '', 'a question that cannot be asked was answered', JSON.stringify(input));
  });

  // The command line, against a scratch record read through the approval library's own `list`.
  const T = fs.mkdtempSync(path.join(os.tmpdir(), 'announce-claimed-'));
  const RECORD = path.join(T, 'approvals', 'record.jsonl');
  const env = Object.assign({}, process.env, { ANNOUNCE_APPROVALS_DIR: path.join(T, 'approvals') });
  const claimedCli = function (args, input) {
    const r = childProcess.spawnSync(process.execPath, [LIB, 'claimed'].concat(args), { input: input, encoding: 'utf8', env: env });
    let json = null;
    try { json = JSON.parse(r.stdout); } catch (e) { json = null; }
    return { status: r.status, json: json, stderr: r.stderr };
  };
  try {
    // No record at all: nothing claimed, and asking made none (the question only reads).
    let k = claimedCli(['--repo', 'acme/widget', '--pr', '7'], POST);
    check(k.status === 0 && k.json && k.json.state === 'unread' && /names no approval/.test(k.json.why), 'with no record the command did not answer unread', JSON.stringify(k));
    check(!fs.existsSync(path.join(T, 'approvals')), 'asking whether wording was claimed made the record\'s folder');

    fs.mkdirSync(path.join(T, 'approvals'));
    const lines = [approvedLine(HASH), claimLine(HASH, 7)].map(function (l) { return JSON.stringify(l); }).join('\n') + '\n';
    fs.writeFileSync(RECORD, lines);
    k = claimedCli(['--repo', 'acme/widget', '--pr', '7'], POST);
    check(k.status === 0 && k.json && k.json.state === 'approved', 'the command did not judge the claimed wording approved', JSON.stringify(k));
    k = claimedCli(['--repo', 'acme/widget', '--pr', '7'], OTHER);
    check(k.status === 0 && k.json && k.json.state === 'changed', 'the command did not exit 0 judging changed wording changed', JSON.stringify(k));
    k = claimedCli(['--repo', 'acme/widget', '--pr', '8'], POST);
    check(k.status === 0 && k.json && k.json.state === 'unread', 'the command judged a pull request with no claim as something other than unread', JSON.stringify(k));
    check(fs.readFileSync(RECORD, 'utf8') === lines, 'asking whether wording was claimed changed the record');

    // A record that cannot be read: said as that, with the library's own reason.
    fs.rmSync(RECORD);
    fs.mkdirSync(RECORD);
    k = claimedCli(['--repo', 'acme/widget', '--pr', '7'], POST);
    check(k.status === 0 && k.json && k.json.state === 'unread' && /could not be read/.test(k.json.why) && !/names no approval/.test(k.json.why), 'a record that cannot be read was not answered unread with why', JSON.stringify(k));

    k = claimedCli(['--repo', 'acme/widget'], POST);
    check(k.status === 2 && k.json === null && /Usage/.test(k.stderr), 'the command answered with no pull request named', JSON.stringify(k));
    k = claimedCli(['--repo', 'acme/widget', '--pr', '7'], '  \n');
    check(k.status === 2 && k.json === null && /wording/.test(k.stderr), 'the command answered for wording that says nothing', JSON.stringify(k));

    // A caller with less time than the listing's own 15 seconds says how long it has (a press of a
    // button is cut off at 10), so the listing gives up first and the answer is its own: unread, with why (L842).
    fs.rmSync(RECORD, { recursive: true });
    fs.writeFileSync(RECORD, lines);
    k = claimedCli(['--repo', 'acme/widget', '--pr', '7', '--within-ms', '4000'], POST);
    check(k.status === 0 && k.json && k.json.state === 'approved', 'the command given a time to answer within did not judge the claimed wording approved', JSON.stringify(k));
    ['abc', '0', '99', '15001', ''].forEach(function (ms) {
      k = claimedCli(['--repo', 'acme/widget', '--pr', '7', '--within-ms', ms], POST);
      check(k.status === 2 && k.json === null && /Usage/.test(k.stderr), 'the command answered with a time to answer within that is not 100 to 15000 ms', ms + ' ' + JSON.stringify(k));
    });
    // A listing that does not answer: a python3 that only waits, first on PATH.
    const slow = path.join(T, 'slow bin');
    fs.mkdirSync(slow);
    fs.writeFileSync(path.join(slow, 'python3'), '#!/bin/sh\nexec sleep 30\n', { mode: 0o755 });
    const slowEnv = Object.assign({}, env, { PATH: slow + path.delimiter + process.env.PATH });
    const began = Date.now();
    const r = childProcess.spawnSync(process.execPath, [LIB, 'claimed', '--repo', 'acme/widget', '--pr', '7', '--within-ms', '300'], { input: POST, encoding: 'utf8', env: slowEnv });
    const took = Date.now() - began;
    let slowJson = null;
    try { slowJson = JSON.parse(r.stdout); } catch (e) { slowJson = null; }
    check(r.status === 0 && slowJson && slowJson.state === 'unread' && /did not answer within 300 ms/.test(slowJson.why), 'a listing that did not answer in the time given was not answered unread, saying so', JSON.stringify({ status: r.status, out: r.stdout, err: r.stderr }));
    check(took < 12000, 'the listing was waited on past the time given, as long as its own 15 seconds', took + ' ms');
  } finally {
    fs.rmSync(T, { recursive: true, force: true });
  }
}

console.log('  ' + passed + ' passed, ' + failed + ' failed');
console.log('SUITE-RESULT passed=' + passed + ' failed=' + failed);
process.exit(failed === 0 ? 0 : 1);
