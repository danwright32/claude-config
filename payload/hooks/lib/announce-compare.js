'use strict';
//
// announce-compare.js: is this what Slack holds the announcement for agents Dan approved?
// (claude-config#3668, #3667)
//
// Two questions, one comparison. The dev update reads the announcements channel since each announce
// change merged, and where the post is there it says "found posted" and asks Dan nothing
// (foundPosted, whose command line is `gather.js posted`). And once a change is live its post is
// saved as a Slack draft, which counts as saved only when it is the approved wording (judgeDraft,
// whose command line is `draft` below, asked by the is it live mod).
//
// Slack's copy and the wording never match as text: measured 2026-11-25 (claude-config#3664), a post
// read back from Slack has *bold* where the draft had **bold**, <url|label> where it had
// [label](url), dot bullets where it had dash bullets, blank lines lost, and an opening <!here>
// where it had @here. So the comparison is of WORDS only: markup, link targets, entities,
// punctuation and spacing all go. A post is found when its words appear in the read, in order and
// unbroken; a draft is the approved wording when its words are those words and no others.
//
// This is the one place that decides either. It was skills/pennie-dev-update/posted.js until #3667
// gave it a second caller, a mod, which can load nothing and so asks the command line; nothing else
// compares an announcement with its wording.
//
// A third question sits beside those two, asked before any draft is asked for: is the wording about
// to be drafted the wording its pull request merged on (claimedWording, whose command line is
// `claimed` below)? That one is a comparison of hashes, not of words, and says why further down.

// Slack's escapes for the three characters it escapes, decoded so `&` and `&amp;` are the same.
function decodeEntities(text) {
  return text.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
}

// The words of a post as either side writes it. A link keeps its label and loses its target, on
// both sides, because the two put them in opposite orders; a link with no label keeps its address.
// A special mention (<!here>) and a user or channel mention (<@U123>, <#C123|name>) keep their name.
function wordsWithin(text) {
  const plain = decodeEntities(String(text))
    .replace(/<!([a-z]+)(?:\|[^>]*)?>/gi, ' $1 ')
    .replace(/<[@#][A-Z0-9]+\|([^>]*)>/g, ' $1 ')
    .replace(/<([^|<>\s]+)\|([^<>]*)>/g, ' $2 ')
    .replace(/<([^|<>\s]+)>/g, ' $1 ')
    .replace(/\[([^\]]*)\]\(([^)\s]*)\)/g, ' $1 ');
  const words = [];
  const re = /[\p{L}\p{N}]+/gu;
  let m;
  while ((m = re.exec(plain)) !== null) words.push({ word: m[0].toLowerCase(), at: m.index });
  return { plain: plain, words: words };
}

function words(text) { return wordsWithin(text).words.map(function (w) { return w.word; }); }

// What a channel read holds to compare against (claude-config#3845). The reading tool answers with
// one JSON object whose `messages` string is the read, and the skill saves each answer exactly as it
// came, so every line break in it is the two characters backslash and n, and the n was taken as a
// word: no announcement, whose mention always stands alone on its first line, was ever found. So a
// page that parses as JSON holding a string `messages` is compared as that string, decoded, and any
// other page as the text it is. A read can be several pages, one answer each, so each is decoded on
// its own: joined first, they would no longer parse. It lives here, beside the comparison, so no
// caller can hand foundPosted a read it has not decoded.
function readOf(read) {
  const pages = Array.isArray(read) ? read : [read];
  return pages.map(function (page) {
    const text = String(page);
    let parsed;
    try { parsed = JSON.parse(text); } catch (e) { return text; }
    const answer = parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed);
    return answer && typeof parsed.messages === 'string' ? parsed.messages : text;
  }).join('\n');
}

// Whether every word of the announcement appears in the read, in order and unbroken. The read is a
// page, or a list of pages, as the reading tool answered or as plain text (readOf). `before` is
// what the read held just before the match (its markup taken out), which is where the reading tool
// puts the time a message was posted, so the session can say "found posted at <time>". An
// announcement with no words would be found in anything, so it is refused, never found.
const BEFORE_CHARS = 240;
function foundPosted(announcement, read) {
  return wordsInOrder(announcement, readOf(read));
}

// The comparison itself, of the announcement's words against plain text.
function wordsInOrder(announcement, plainText) {
  const want = words(announcement);
  if (want.length === 0) throw new Error('the announcement has no words, so it would be found in any read; nothing was compared');
  const read = wordsWithin(plainText);
  const got = read.words;
  for (let i = 0; i + want.length <= got.length; i++) {
    let j = 0;
    while (j < want.length && got[i + j].word === want[j]) j++;
    if (j === want.length) {
      const start = got[i].at;
      return { found: true, words: want.length, before: read.plain.slice(Math.max(0, start - BEFORE_CHARS), start) };
    }
  }
  return { found: false, words: want.length, before: '' };
}

// ---------------------------------------------------------------- a draft (claude-config#3667)
//
// Measured 2026-11-25 (claude-config#3664), for a draft to a channel with no thread: a draft Slack
// kept is answered with a `draft_id`. With a draft already waiting in that channel the tool answers
// "Draft created" with no `draft_id` and keeps nothing, twice out of twice, and the error its own
// description lists for that (attached_draft_exists) was never returned. So only a `draft_id` says a
// draft was kept, and an answer naming no error is not enough.

// The errors Slack's draft tool names in its own description, each with what it means for the
// draft. The last two are about a thread, which a draft of an announcement never names.
const DRAFT_ERRORS = {
  attached_draft_exists: 'a draft is already attached to that channel, so this one was not kept',
  channel_not_found: 'it knows no channel with that id, so nothing was kept',
  not_in_channel: 'the Slack account is not a member of that channel, so nothing was kept',
  failed_to_create_draft: 'and gave no reason, so nothing was kept',
  invalid_thread_ts: 'which is about a thread, and an announcement is drafted to the channel with no thread; nothing was kept',
  thread_not_found: 'which says the thread no longer exists, and an announcement is drafted to the channel with no thread; nothing was kept',
};

// The id Slack gave the draft, wherever the answer carries it: a JSON field, JSON inside a JSON
// string (its quotes escaped), or plain words. A null or empty one is none.
function draftIdIn(answerText) {
  const m = /\bdraft_id\b[\\"'\s]*[:=][\\"'\s]*([A-Za-z0-9_.-]+)/.exec(answerText);
  if (!m) return '';
  return /^(null|undefined|none|false)$/i.test(m[1]) ? '' : m[1];
}

function errorIn(answer) {
  const text = answer.text;
  for (const name of Object.keys(DRAFT_ERRORS)) {
    if (new RegExp('\\b' + name + '\\b').test(text)) return { error: name, why: 'Slack answered ' + name + ': ' + DRAFT_ERRORS[name] };
  }
  // ok false is read with its quotes escaped too, for an answer held inside a JSON string (#3845).
  if (answer.isError === true || /\\*"ok\\*"\s*:\s*false/.test(text)) {
    return { error: '', why: 'Slack\'s draft tool answered with an error it did not name, so nothing was kept: ' + JSON.stringify(text.trim().slice(0, 200)) };
  }
  return null;
}

// Where two lists of words part, said for a person: the first place they differ, or which one ends.
function whereTheyPart(want, got) {
  let i = 0;
  while (i < want.length && i < got.length && want[i] === got[i]) i++;
  const at = 'word ' + (i + 1);
  if (i === want.length) return 'the draft goes on past the approved wording, from ' + at + ' ("' + got[i] + '")';
  if (i === got.length) return 'the draft ends before the approved wording does, at ' + at + ' ("' + want[i] + '")';
  return 'they first differ at ' + at + ', where the approved wording has "' + want[i] + '" and the draft has "' + got[i] + '"';
}

// What became of one draft of an announcement. `text` is the approved wording, `message` what the
// draft call carried, `answer` what Slack's draft tool answered ({text, isError}). Four answers, kept
// apart (L11), judged in this order so an answer that kept nothing is never read by its wording:
//   error     the answer is an error or names one: `error` (the name, '' where it named none), `why`.
//   not-kept  it names no error and holds no draft_id, so Slack kept nothing: `why`.
//   differs   Slack kept a draft (`draftId`) whose words are not the approved wording's: `why` says
//             where they part.
//   saved     Slack kept a draft (`draftId`) holding the approved wording, word for word.
// Whatever cannot be judged throws, since a judgement nobody could make is never "saved" (L98).
function judgeDraft(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('the draft to judge was not given as an object holding the wording, the message and Slack\'s answer');
  if (typeof input.text !== 'string') throw new Error('the approved wording was not given, so there is nothing to compare the draft with');
  if (typeof input.message !== 'string') throw new Error('the message the draft call carried was not given, so it cannot be compared with the approved wording');
  const answer = input.answer;
  if (!answer || typeof answer !== 'object' || typeof answer.text !== 'string') throw new Error('Slack\'s answer to the draft call was not given as text, so whether it kept a draft cannot be told');
  const want = words(input.text);
  if (want.length === 0) throw new Error('the approved wording has no words, so any draft would match it; nothing was compared');

  const refused = errorIn(answer);
  if (refused) return { state: 'error', error: refused.error, why: refused.why };
  const draftId = draftIdIn(answer.text);
  if (!draftId) {
    return { state: 'not-kept', why: 'Slack\'s answer holds no draft_id, which is what it answers when a draft is already waiting in that channel, and it keeps nothing then' };
  }
  const got = words(input.message);
  // The message is the wording the draft call carried, never a channel read, so it is compared as
  // the text it is.
  const same = got.length === want.length && wordsInOrder(input.text, input.message).found;
  if (!same) {
    return { state: 'differs', draftId: draftId, why: 'the approved wording has ' + want.length + ' words and the draft ' + got.length + ', and ' + whereTheyPart(want, got) };
  }
  return { state: 'saved', draftId: draftId };
}

// ---- is the wording about to be drafted the wording the pull request merged on? (#3667) ----
// The post is read from the pull request's description, and a description can be edited after the
// merge by an ordinary command no hook judges. The merge gate, though, let the pull request through
// on one hash and wrote it down: the claim line in the record of approvals, naming the repository,
// that hash and the pull request (lib/announce-approval.py). So wording is drafted only when its
// hash, by the one hash of an announcement (lib/changelog-entry.js, announcementHash), is the hash
// of that pull request's claim. This is the one place that decides it, for the is it live mod's
// card and for the dev update's "Draft it now"; both ask before any draft is asked for.
//
// `input.listed` is what `announce-approval.py list` printed, which only reads: this file never
// writes that record and never names where it is. Three answers, told apart (L11):
//   approved  the wording's hash is the hash of the pull request's latest claim.
//   changed   the pull request has a claim and the wording's hash is another: `why`.
//   unread    no claim by that pull request could be read, because the record names none or could
//             not be read: `why` says which. Never an empty record taken for an answer (L98).
// A pull request can claim more than once (a merge the gate let through that GitHub then refused,
// its wording changed and approved again): the latest claim is the one it merged on. The gate
// writes no second line for wording a pull request claimed before, so one that went back to an
// earlier wording reads as changed here, which refuses a draft rather than drafting on a guess.
const SLUG = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
function claimedWording(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('the wording to check was not given as an object holding the repository, the pull request, the wording and the record as listed');
  if (typeof input.repo !== 'string' || !SLUG.test(input.repo.trim())) throw new Error('the repository was not given as owner/name, so no claim could be looked up for it');
  if (!Number.isInteger(input.pr) || input.pr <= 0) throw new Error('the pull request was not given as its number, so no claim could be looked up for it');
  if (typeof input.text !== 'string') throw new Error('the wording about to be drafted was not given, so there is nothing to check');
  const hash = require('./changelog-entry.js').announcementHash(input.text);
  if (!hash) throw new Error('the wording about to be drafted says nothing, so there is nothing to check');

  const listed = input.listed;
  if (!listed || typeof listed !== 'object' || !Array.isArray(listed.entries)) {
    const said = listed && typeof listed === 'object' && typeof listed.why === 'string' ? listed.why.trim() : '';
    return { state: 'unread', why: said || 'this Mac\'s record of the announcements Dan approved could not be read' };
  }
  const repo = input.repo.trim().toLowerCase();
  const claims = listed.entries.filter(function (e) {
    return e && typeof e === 'object' && e.kind === 'used' && e.claim === true && e.pr === input.pr
      && typeof e.repo === 'string' && e.repo.toLowerCase() === repo && typeof e.hash === 'string' && e.hash !== '';
  });
  if (claims.length === 0) {
    return { state: 'unread', why: 'this Mac\'s record of the announcements Dan approved names no approval that pull request ' + input.pr + ' of ' + input.repo.trim() + ' merged on' };
  }
  if (claims[claims.length - 1].hash !== hash) {
    return { state: 'changed', why: 'the wording its description holds now is not the wording it merged on, by the one hash both are compared by' };
  }
  return { state: 'approved' };
}

// The record, as lib/announce-approval.py's `list` prints it: the one command line of that library
// that only reads, whatever it finds. A listing that could not be made is handed on as one that
// could not be read, with why, so claimedWording answers unread. The listing gets LIST_MS to answer,
// or the shorter time a caller says it has: a caller that is itself cut off sooner (a press of a
// button, at 10 seconds) passes less, so this wait ends first and the answer is this one, with its
// reason, in place of a command that was killed part way (L842).
const LIST_MS = 15000;
const LIST_MS_LEAST = 100;
function listApprovals(withinMs) {
  const within = withinMs === undefined ? LIST_MS : withinMs;
  const r = require('child_process').spawnSync('python3', ['-B', require('path').join(__dirname, 'announce-approval.py'), 'list'], { encoding: 'utf8', timeout: within });
  const failed = function (why) { return { entries: null, why: 'this Mac\'s record of the announcements Dan approved could not be listed (' + why + ')' }; };
  if (r.error && r.error.code === 'ETIMEDOUT') return failed('announce-approval.py list did not answer within ' + within + ' ms');
  if (r.error) return failed(r.error.code === 'ENOENT' ? 'python3 is not on PATH' : String(r.error.message || r.error));
  if (r.status !== 0) return failed('announce-approval.py list exited ' + r.status);
  try {
    const listed = JSON.parse(r.stdout);
    return listed && typeof listed === 'object' && !Array.isArray(listed) ? listed : failed('its answer was not an object');
  } catch (e) {
    return failed('its answer was not JSON');
  }
}

// claimedWording against the record as it reads now: what both callers ask. `withinMs` is how long
// the listing may take, for a caller with less time than LIST_MS.
function claimedNow(repo, pr, text, withinMs) {
  return claimedWording({ repo: repo, pr: pr, text: text, listed: listApprovals(withinMs) });
}

module.exports = { words: words, foundPosted: foundPosted, judgeDraft: judgeDraft, claimedWording: claimedWording, claimedNow: claimedNow };

// The command lines, for the is it live mod, which cannot load this file (claude-config#3667).
//   draft
//       reads {text, message, answer: {text, isError}} as JSON on standard input and prints
//       judgeDraft's answer as JSON: {state: saved | differs | not-kept | error, draftId, error, why}.
//   claimed --repo <owner/name> --pr <number> [--within-ms <100 to 15000>]
//       reads the wording about to be drafted on standard input and prints claimedNow's answer as
//       JSON: {state: approved | changed | unread, why}. It reads the record and writes nothing.
//       --within-ms is how long the record's listing may take, for a caller cut off sooner than
//       the 15 seconds it otherwise gets.
// Every judgement exits 0, so a reader tells a draft that was not kept, or wording that was changed,
// from a command that failed. An input that cannot be judged prints why on standard error and exits
// 2, as does any other command.
if (require.main === module) {
  const usage = function (why) {
    // One line, since a reader of a failed run quotes the last line it printed.
    process.stderr.write((why ? why + '. ' : '') + 'Usage: announce-compare.js draft, with {text, message, answer: {text, isError}} as JSON on standard input | claimed --repo <owner/name> --pr <number> [--within-ms <100 to 15000>], with the wording on standard input\n');
    process.exit(2);
  };
  const args = process.argv.slice(3);
  const command = process.argv[2];
  const flag = function (name) { const i = args.indexOf(name); return i >= 0 && i + 1 < args.length ? args[i + 1] : null; };
  // The time a caller gives the listing: a whole number of milliseconds, LIST_MS_LEAST to LIST_MS.
  const timed = args.indexOf('--within-ms') >= 0;
  const withinMs = timed && /^[0-9]{1,5}$/.test(flag('--within-ms') || '') ? Number(flag('--within-ms')) : undefined;
  const timedWrong = timed && (withinMs === undefined || withinMs < LIST_MS_LEAST || withinMs > LIST_MS);
  if (command === 'draft' ? args.length !== 0 : command !== 'claimed' || args.length !== (timed ? 6 : 4) || timedWrong || flag('--repo') === null || !/^[0-9]+$/.test(flag('--pr') || '')) usage('');
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', function (d) { raw += d; });
  process.stdin.on('end', function () {
    if (command === 'claimed') {
      let answer;
      try { answer = claimedNow(flag('--repo'), Number(flag('--pr')), raw, withinMs); } catch (e) { return usage('The wording could not be checked: ' + e.message); }
      return process.stdout.write(JSON.stringify(answer) + '\n');
    }
    let input;
    try { input = JSON.parse(raw); } catch (e) { return usage('The draft to judge could not be read as JSON on standard input'); }
    let judged;
    try { judged = judgeDraft(input); } catch (e) { return usage('The draft could not be judged: ' + e.message); }
    process.stdout.write(JSON.stringify(judged) + '\n');
  });
}
