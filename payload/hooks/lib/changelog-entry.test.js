'use strict';
//
// changelog-entry.test.js: what counts as a changelog record, and what the
// refusal says when a pull request does not carry one.
//
// Run through the harness wrapper ~/.claude/hooks/test-changelog-tag.sh, which
// is where run-all-tests.sh finds it. Every case drives the REAL module rather
// than restating its rules here (L52).

const path = require('path');
const entry = require(path.join(__dirname, 'changelog-entry.js'));

let passed = 0, failed = 0;
function pass() { passed++; }
function fail(msg) { console.log('  FAIL: ' + msg); failed++; }
function check(cond, msg) { cond ? pass() : fail(msg); }

function parse(labels, body) {
  return entry.parseEntry({ labels: labels, body: body });
}

// ------------------------------------------------- a change a manager notices

let r = parse(['changelog/visible'], 'Some prose.\n\n## Changelog\nA personal goal of 0 now reads as a deliberate 0.\n');
check(r.ok === true, 'a labelled PR carrying a block was refused: ' + JSON.stringify(r));
check(r.kind === 'visible', 'the kind did not come from the label: ' + JSON.stringify(r));
check(r.line === 'A personal goal of 0 now reads as a deliberate 0.',
  'the line was not read from under the heading: ' + JSON.stringify(r));

// Other labels on the pull request are none of this gate's business.
r = parse(['priority-p2', 'changelog/visible', 'tech-debt'], '## Changelog\nBadge cutoffs were re-modelled.');
check(r.ok === true && r.kind === 'visible',
  'unrelated labels stopped the changelog label being found: ' + JSON.stringify(r));

// The block runs to the next heading and folds to one line, because a bullet in
// the post is one line.
r = parse(['changelog/visible'], '## Changelog\nFirst sentence.\nSecond sentence.\n\n## Testing\nnot part of it\n');
check(r.ok === true && r.line === 'First sentence. Second sentence.',
  'the block did not stop at the next heading, or did not fold: ' + JSON.stringify(r));

// Lenient on depth and case, strict on shape.
r = parse(['changelog/visible'], '### changelog\nA line.\n');
check(r.ok === true && r.line === 'A line.', 'a lower case h3 heading was not accepted: ' + JSON.stringify(r));

// The word in a sentence is not a heading.
r = parse(['changelog/visible'], 'I updated the changelog for this.\n');
check(r.ok === false && r.code === 'NO_BLOCK',
  'the word changelog inside a sentence opened a block: ' + JSON.stringify(r));

// ------------------------------------------------- plumbing needs no sentence
// Most pull requests are plumbing. Requiring manager prose for each one would
// be a cost paid on every change to buy a line that gets collapsed into a
// single roll-up anyway, so technical carries no block requirement. Only the
// visible half needs prose, because there the engineering-voiced title really
// is not usable and the detail IS the substance.

r = parse(['changelog/technical'], 'Pinned the SFTP host key.');
check(r.ok === true && r.kind === 'technical' && r.line === null,
  'changelog/technical was refused for having no block: ' + JSON.stringify(r));

// A sentence on a technical change is still kept when someone writes one.
r = parse(['changelog/technical'], '## Changelog\nSFTP host key pinned.');
check(r.ok === true && r.kind === 'technical' && r.line === 'SFTP host key pinned.',
  'a technical block was written and then dropped: ' + JSON.stringify(r));

r = parse(['changelog/none'], 'Fixed a typo in a comment.');
check(r.ok === true && r.kind === 'none' && r.line === null,
  'changelog/none was not accepted on its own: ' + JSON.stringify(r));

// ------------------------------------------------- the refusals
// Each cause gets its own code AND its own sentence. Two refusals that read the
// same are one refusal, and the reader cannot act on either (L11, L260).

const refusals = [];
function refusal(name, labels, body, expectCode) {
  const got = parse(labels, body);
  check(got.ok === false, name + ': accepted when it should have been refused: ' + JSON.stringify(got));
  check(got.code === expectCode, name + ': expected code ' + expectCode + ', got ' + got.code);
  check(typeof got.reason === 'string' && got.reason.length > 20,
    name + ': the refusal carries no usable sentence: ' + JSON.stringify(got));
  if (got.reason) refusals.push([name, got.reason]);
  return got;
}

refusal('no changelog label at all', ['priority-p2'], '## Changelog\nA line.', 'NO_LABEL');
refusal('two changelog labels', ['changelog/visible', 'changelog/none'], '## Changelog\nA line.', 'MANY_LABELS');
refusal('a label outside the kinds', ['changelog/goals'], '## Changelog\nA line.', 'UNKNOWN_KIND');
refusal('visible with no block in the body', ['changelog/visible'], 'Prose with no heading.', 'NO_BLOCK');
refusal('a heading with nothing under it', ['changelog/visible'], '## Changelog\n\n## Testing\nx', 'EMPTY_BLOCK');
refusal('a block saying None while labelled visible', ['changelog/visible'], '## Changelog\nNone\n', 'BLOCK_SAYS_NONE');
refusal('changelog/none but a line was written anyway', ['changelog/none'], '## Changelog\nA line someone wrote.', 'NONE_WITH_BLOCK');

// A refusal must NAME what it would have accepted, or the person is told they
// are wrong and not told what right looks like.
const unknown = parse(['changelog/goals'], '## Changelog\nA line.');
check(/changelog\/visible/.test(unknown.reason)
   && /changelog\/technical/.test(unknown.reason)
   && /changelog\/none/.test(unknown.reason),
  'the unknown-label refusal does not list the labels it would accept: ' + unknown.reason);
check(/changelog\/visible/.test(parse([], 'x').reason),
  'the missing-label refusal does not say what to add: ' + parse([], 'x').reason);

// No two refusals may share a sentence.
const seen = new Map();
refusals.forEach(function (pair) {
  if (seen.has(pair[1])) fail('two causes share one refusal sentence: ' + seen.get(pair[1]) + ' and ' + pair[0]);
  else { seen.set(pair[1], pair[0]); pass(); }
});

// A null body: GitHub returns one for a pull request with an empty description.
r = parse(['changelog/visible'], null);
check(r.ok === false && r.code === 'NO_BLOCK',
  'a null body was not refused as a missing block: ' + JSON.stringify(r));

// The same label twice is one label, not a contradiction.
r = parse(['changelog/visible', 'changelog/visible'], '## Changelog\nA line.');
check(r.ok === true, 'the same label applied twice was read as two conflicting labels: ' + JSON.stringify(r));

// ------------------------------------------------- which repos are in scope
// A repo opts in by being listed in the dev update registry, which
// already exists and already names the repos the post covers. A second registry
// beside it would be one more thing to add Slate to, and the two would disagree
// the first time only one was updated.

const REGISTRY = {
  repos: [
    { name: 'PET', repo: 'Acme-Corp/enrollment-board', changelogFrom: '2026-09-01' },
    { name: 'NoDate', repo: 'acme/nodate' },
    { name: 'Later', repo: 'acme/later', changelogFrom: '2026-12-01' },
    { name: 'Bad', repo: 'acme/bad', changelogFrom: 'December' },
  ],
};

// The day is always passed in. A test that reads the machine's clock is a test
// about the machine, and this one would change its own answer on 1 December.
const TODAY = '2026-09-15';
function scope(slug, today) { return entry.repoScope(REGISTRY, slug, today || TODAY); }

let s = scope('Acme-Corp/enrollment-board');
check(s.inScope === true && s.from === '2026-09-01',
  'a listed repo carrying a past start date was not in scope: ' + JSON.stringify(s));

s = scope('someone/else');
check(s.inScope === false, 'an unlisted repo was gated: ' + JSON.stringify(s));

// Case: GitHub slugs are not case sensitive and a remote can be spelled either way.
s = scope('acme-corp/Enrollment-Board');
check(s.inScope === true, 'a differently cased slug was not recognised: ' + JSON.stringify(s));

// The date is a START DATE, not merely an on switch. Setting a repo's date to
// its launch day in advance has to mean "begin then", or setting it early
// silently begins refusing merges now, which is the opposite of what the field
// says. This is the case Slate will actually use.
s = scope('acme/later');
check(s.inScope === false && /2026-12-01/.test(s.why || ''),
  'a repo whose start date has not arrived was gated anyway, or did not say when it starts: '
  + JSON.stringify(s));

// Inclusive: on the day itself the rule is in force.
s = scope('acme/later', '2026-12-01');
check(s.inScope === true, 'the rule was not in force on its own start date: ' + JSON.stringify(s));

// The day before is not.
s = scope('acme/later', '2026-11-30');
check(s.inScope === false, 'the rule was in force the day before its start date: ' + JSON.stringify(s));

// A date nobody can parse must not read as "not yet". That would disable the
// gate silently on a typo, and a silently disabled gate is indistinguishable
// from one that is passing (L98, L214). It is a config error and says so.
s = scope('acme/bad');
check(s.inScope === false && s.badDate === true,
  'an unparseable start date was treated as a date rather than as a config error: ' + JSON.stringify(s));
check(/December/.test(s.why || ''),
  'the bad-date refusal does not quote the value that could not be read: ' + JSON.stringify(s));
// And it must not be confused with a repo that simply has no date.
check(scope('acme/nodate').badDate !== true,
  'a repo with no date at all was reported as having a bad one: ' + JSON.stringify(scope('acme/nodate')));

// A repo listed with NO start date is not gated. The gate can only speak for
// changes made after the rule reached that repo, and treating "no date" as
// "always" would refuse every pull request in a repo that has not adopted this
// yet, including the one adding the date (L214: absent and empty are different).
s = entry.repoScope(REGISTRY, 'acme/nodate');
check(s.inScope === false && /changelogFrom/.test(s.why || ''),
  'a repo with no changelogFrom was gated anyway, or did not say why not: ' + JSON.stringify(s));

// A registry that cannot be read is not the same as a registry saying no. One
// means the gate is off for this repo, the other means the gate cannot tell,
// and merging blind on an unreadable registry is the failure worth naming.
s = entry.repoScope(null, 'Acme-Corp/enrollment-board');
check(s.inScope === false && s.unreadable === true,
  'an unreadable registry read as a deliberate opt out: ' + JSON.stringify(s));

// ------------------------------------- which label this gate requires, for sleep mode
//
// Sleep mode lets a session working overnight set the one label this gate requires on a pull
// request it opened, and asks THIS file which labels those are, so there is no second list of them
// in the mod to drift from this one (claude-config#3439). The cases are the committed set the mod's
// reader of this answer is held to as well (L58): mods/scope-modes/tests/gate-label-fixtures.ts.

const fs = require('fs');
const os = require('os');
const childProcess = require('child_process');

const FIXTURES_FILE = path.join(__dirname, '..', '..', 'mods', 'scope-modes', 'tests', 'gate-label-fixtures.ts');
let gateCases = [];
try {
  const text = fs.readFileSync(FIXTURES_FILE, 'utf8');
  const from = text.indexOf('export const GATE_LABEL_FIXTURES = ');
  const to = text.indexOf('\n]', from);
  gateCases = JSON.parse(text.slice(from + 'export const GATE_LABEL_FIXTURES = '.length, to + 2));
} catch (e) {
  fail('the shared required label fixtures could not be read from ' + FIXTURES_FILE + ': ' + e.message);
}
// A set that read as empty would pass every case below by running none of them (L98).
check(gateCases.length >= 10, 'the shared required label fixtures hold ' + gateCases.length + ' cases, fewer than the 10 committed');

check(typeof entry.requiredLabels === 'function', 'changelog-entry.js exports no requiredLabels');
const requiredLabels = typeof entry.requiredLabels === 'function'
  ? entry.requiredLabels
  : function () { return { state: 'absent', labels: null }; };

// A case carrying "flags" is one asked the way a caller that understands `needsDan` asks; a case with
// none is a session still running the mod as it was before the announce label, which must go on
// getting the answer it always got and never sees a label it cannot handle (claude-config#3665).
check(gateCases.some(function (c) { return (c.flags || []).indexOf('--needs-dan') !== -1; })
  && gateCases.some(function (c) { return !(c.flags || []).length; }),
  'the shared required label fixtures do not hold both a caller passing --needs-dan and one that does not');
gateCases.forEach(function (c) {
  const read = c.registry === null
    ? { state: 'unreadable', why: 'the registry could not be read' }
    : { state: 'ok', registry: c.registry };
  const got = requiredLabels(read, c.repo, c.today, { needsDan: (c.flags || []).indexOf('--needs-dan') !== -1 });
  check(got.state === c.answer.state && JSON.stringify(got.labels) === JSON.stringify(c.answer.labels),
    'required labels, ' + c.name + ': wanted ' + JSON.stringify(c.answer) + ', got ' + JSON.stringify(got));
  // Whatever is not a plain "required" says why, since sleep mode puts that sentence in its refusal.
  if (c.answer.state !== 'required') {
    check(typeof got.why === 'string' && got.why.length > 0, 'required labels, ' + c.name + ': no reason given: ' + JSON.stringify(got));
  }
});

// A registry file that is not there is "cannot tell", in the registry reader's own words.
let g = requiredLabels({ state: 'missing', why: 'The dev update registry is not at /x.' }, 'acme/board', '2026-11-21');
check(g.state === 'unknown' && /not at \/x/.test(g.why || ''), 'a missing registry did not read as unknown with its reason: ' + JSON.stringify(g));

// Which labels need a sentence comes from parseEntry itself, never from a second statement of the
// rule: each label the answer marks is one parseEntry refuses on a description with no block, and
// each it does not mark is one parseEntry accepts there.
// Asked of a repository where every kind is in use (it names an announcements channel) by a caller
// that understands every field, so no kind is left out of the comparison.
g = requiredLabels({ state: 'ok', registry: { repos: [{ name: 'Board', repo: 'acme/board', changelogFrom: '2026-09-01', announceChannel: 'C0000TEST01' }] } },
  'acme/board', TODAY, { needsDan: true });
check(g.state === 'required' && g.labels.length === entry.KINDS.length, 'a gated repo did not list every changelog label: ' + JSON.stringify(g));
(g.labels || []).forEach(function (l) {
  const bare = parse([l.label], 'A description with no block.');
  check(bare.ok === !l.needsSentence, l.label + ' is marked needsSentence=' + l.needsSentence + ' while parseEntry says ok=' + bare.ok + ' with no block');
});

// The command line sleep mode runs: `node changelog-entry.js required-labels <owner/name> [file]`.
// Run for real against a registry file on disk, with dates far either side of any clock.
const cliDir = fs.mkdtempSync(path.join(os.tmpdir(), 'changelog-required-'));
const cliRegistry = path.join(cliDir, 'repos.local.json');
fs.writeFileSync(cliRegistry, JSON.stringify({ repos: [
  { name: 'Board', repo: 'acme/board', changelogFrom: '2026-01-01' },
  { name: 'Later', repo: 'acme/later', changelogFrom: '2999-01-01' },
  { name: 'NoDate', repo: 'acme/nodate' },
] }));
function cli(args) {
  const r = childProcess.spawnSync(process.execPath, [path.join(__dirname, 'changelog-entry.js')].concat(args), { encoding: 'utf8' });
  let json = null;
  try { json = JSON.parse(r.stdout); } catch (e) { json = null; }
  return { status: r.status, json: json, stdout: r.stdout, stderr: r.stderr };
}
let c = cli(['required-labels', 'acme/board', cliRegistry]);
check(c.status === 0 && c.json && c.json.state === 'required'
  && JSON.stringify(c.json.labels.map(function (l) { return l.label; })) === JSON.stringify(['changelog/visible', 'changelog/technical', 'changelog/none']),
  'the command line did not answer required with the three labels for a gated repo: ' + JSON.stringify(c));
c = cli(['required-labels', 'acme/elsewhere', cliRegistry]);
check(c.status === 0 && c.json && c.json.state === 'not-required' && c.json.labels.length === 0,
  'the command line did not answer not-required for an unlisted repo: ' + JSON.stringify(c));
c = cli(['required-labels', 'acme/later', cliRegistry]);
check(c.status === 0 && c.json && c.json.state === 'not-required',
  'the command line gated a repo whose start date has not arrived: ' + JSON.stringify(c));
c = cli(['required-labels', 'acme/nodate', cliRegistry]);
check(c.status === 0 && c.json && c.json.state === 'unknown' && /changelogFrom/.test(c.json.why || ''),
  'the command line did not answer unknown, with why, for a repo listed with no start date: ' + JSON.stringify(c));
c = cli(['required-labels', 'acme/board', path.join(cliDir, 'not-there.json')]);
check(c.status === 0 && c.json && c.json.state === 'unknown' && /not at/.test(c.json.why || ''),
  'the command line did not answer unknown for a registry file that is not there: ' + JSON.stringify(c));
fs.writeFileSync(path.join(cliDir, 'broken.json'), '{ "repos": [');
c = cli(['required-labels', 'acme/board', path.join(cliDir, 'broken.json')]);
check(c.status === 0 && c.json && c.json.state === 'unknown' && /not valid JSON/.test(c.json.why || ''),
  'the command line did not answer unknown for a registry that does not parse: ' + JSON.stringify(c));
// No repository named is a usage error, never an answer about some repository.
c = cli(['required-labels']);
check(c.status === 2 && c.json === null, 'the command line answered with no repository named: ' + JSON.stringify(c));
c = cli(['something-else']);
check(c.status === 2, 'an unknown command did not exit 2: ' + JSON.stringify(c));
fs.rmSync(cliDir, { recursive: true, force: true });

// ------------------------------------- the announce label (claude-config#3665)
//
// A fourth label, for a change whose agents must or can act differently. Its pull request carries
// the sentence for managers AND the post for agents, under an Announcement heading. Every repository
// and channel id below is invented.

const EM_DASH = String.fromCharCode(0x2014);
const EN_DASH = String.fromCharCode(0x2013);
const SENTENCE = '## Changelog\nAgents can now hand a call back to the queue.\n';
const POST = '@here\n**Handing a call back**\n\nYou can now hand a call back to the queue.\n\n- Press Hand back\n- Pick a reason\n\n1. First\n2. Second\n\nMore at https://example.com/guide and in [the guide](https://example.com/guide).';
const ANNOUNCE_BODY = 'Why.\n\n' + SENTENCE + '\n## Announcement\n' + POST + '\n\n## Testing\nran it';

// ---- the kinds, and the one map each fact about a kind lives in
check(entry.ANNOUNCE === 'announce' && entry.KINDS.indexOf('announce') !== -1,
  'announce is not one of the kinds: ' + JSON.stringify(entry.KINDS));
check(JSON.stringify(entry.KINDS.slice(0, 3)) === JSON.stringify(['visible', 'technical', 'none']),
  'the three kinds that came first no longer come first, in their order: ' + JSON.stringify(entry.KINDS));
check(typeof entry.isManagerVisible === 'function', 'changelog-entry.js exports no isManagerVisible');
const isManagerVisible = typeof entry.isManagerVisible === 'function' ? entry.isManagerVisible : function () { return undefined; };
check(isManagerVisible('visible') === true && isManagerVisible('announce') === true,
  'a visible or an announce change is not read as one a manager would notice');
check(isManagerVisible('technical') === false && isManagerVisible('none') === false,
  'a technical or a none change is read as one a manager would notice');
check(isManagerVisible('goals') === false && isManagerVisible(undefined) === false && isManagerVisible('toString') === false,
  'something that is not a kind is read as manager visible');
// Every fact about a kind is a map naming EVERY kind, so a kind added to KINDS without an entry in
// each map fails here, never reads as false in whichever reader nobody thought of (L96, R5).
const facts = entry.KIND_FACTS && typeof entry.KIND_FACTS === 'object' ? entry.KIND_FACTS : {};
check(Object.keys(facts).length >= 3 && Object.prototype.hasOwnProperty.call(facts, 'managerVisible'),
  'changelog-entry.js exports no KIND_FACTS holding the maps over the kinds: ' + JSON.stringify(Object.keys(facts)));
Object.keys(facts).forEach(function (name) {
  entry.KINDS.forEach(function (kind) {
    check(Object.prototype.hasOwnProperty.call(facts[name], kind) && typeof facts[name][kind] === 'boolean',
      'the kind ' + kind + ' has no entry in the ' + name + ' map, so a reader of that map has no answer for it');
  });
  Object.keys(facts[name]).forEach(function (kind) {
    check(entry.KINDS.indexOf(kind) !== -1, 'the ' + name + ' map names ' + kind + ', which is not a kind');
  });
});
// The check above can fail: the same loop over a map missing one kind finds it.
(function () {
  const short = { visible: true, technical: false, none: false };
  const missing = entry.KINDS.filter(function (k) { return !Object.prototype.hasOwnProperty.call(short, k); });
  check(missing.length === 1 && missing[0] === 'announce', 'a map holding three kinds was not found one kind short: ' + JSON.stringify(missing));
})();

// ---- the announcement block: line breaks kept, and one normalised form
check(typeof entry.extractAnnouncement === 'function' && typeof entry.normalizeAnnouncement === 'function',
  'changelog-entry.js exports no extractAnnouncement or no normalizeAnnouncement');
const extractAnnouncement = typeof entry.extractAnnouncement === 'function' ? entry.extractAnnouncement : function () { return undefined; };
const normalizeAnnouncement = typeof entry.normalizeAnnouncement === 'function' ? entry.normalizeAnnouncement : function () { return undefined; };
check(extractAnnouncement(ANNOUNCE_BODY) === POST, 'the announcement was not read with its line breaks, up to the next heading: ' + JSON.stringify(extractAnnouncement(ANNOUNCE_BODY)));
check(extractAnnouncement('prose only') === null && extractAnnouncement(null) === null, 'a body with no Announcement heading did not read as no block');
check(extractAnnouncement('## Announcement\n\n   \n## Testing\nx') === '', 'an Announcement heading with nothing under it did not read as an empty block');
check(extractAnnouncement('### announcement:\n\n@here\nA line.  \n\n') === '@here\nA line.', 'the heading is not matched leniently, or outer blank lines and trailing spaces were kept: ' + JSON.stringify(extractAnnouncement('### announcement:\n\n@here\nA line.  \n\n')));
// GitHub returns CRLF for a description edited on its own page.
check(extractAnnouncement('## Announcement\r\n@here\r\nA line.\r\n\r\nAnother.\r\n') === '@here\nA line.\n\nAnother.', 'a description with CRLF line endings kept its carriage returns: ' + JSON.stringify(extractAnnouncement('## Announcement\r\n@here\r\nA line.\r\n\r\nAnother.\r\n')));
check(extractAnnouncement('The word announcement in a sentence.\nMore.') === null, 'the word in a sentence opened a block');
// The Changelog sentence is still one line, and stops at the Announcement heading.
check(entry.extractBlock(ANNOUNCE_BODY) === 'Agents can now hand a call back to the queue.', 'the Changelog sentence ran on into the Announcement: ' + JSON.stringify(entry.extractBlock(ANNOUNCE_BODY)));
// One normalised form: line endings, trailing spaces, outer blank lines, and blank lines anywhere,
// since Slack's message box added one the draft did not have and the post read back had lost others
// (measured 2026-11-25, claude-config#3664).
const NORMAL = '@here\nA line.\n  - indented stays\nAnother.';
['@here\nA line.\n  - indented stays\nAnother.', '\n\n@here\r\nA line.  \r\n\r\n  - indented stays\t\r\n\r\n\r\nAnother.\r\n\r\n', '@here\n\nA line.\n\n  - indented stays\n\nAnother.\n'].forEach(function (text) {
  check(normalizeAnnouncement(text) === NORMAL, 'one announcement spelled another way did not normalise to the one form: ' + JSON.stringify(normalizeAnnouncement(text)));
});
check(normalizeAnnouncement('@here\nA line!') !== normalizeAnnouncement('@here\nA line.') && normalizeAnnouncement('@here\nA line.') !== normalizeAnnouncement('@here A line.'),
  'two announcements whose words or lines differ normalise to the same text');
check(normalizeAnnouncement(null) === '' && normalizeAnnouncement(undefined) === '', 'no text did not normalise to the empty string');

// ---- the record, read on ANY Mac whatever its registry says
r = parse(['changelog/announce'], ANNOUNCE_BODY);
check(r.ok === true && r.kind === 'announce', 'an announce record carrying both pieces of writing was refused: ' + JSON.stringify(r));
check(r.line === 'Agents can now hand a call back to the queue.', 'an announce record does not carry the sentence for managers: ' + JSON.stringify(r));
check(r.announcement === POST, 'an announce record does not carry the post for agents, line breaks kept: ' + JSON.stringify(r));
// parseEntry takes no registry and no repository, so nothing here can depend on one: it is the
// reader of merged history (skills/pennie-dev-update/gather.js), where a refusal is a "gap".
check(entry.parseEntry.length === 1, 'parseEntry takes more than the pull request, so a registry could reach it');
// The Changelog checks are the visible label's own, shared: the same three causes, the same codes.
refusal('announce with no Changelog block', ['changelog/announce'], '## Announcement\n' + POST, 'NO_BLOCK');
refusal('announce with an empty Changelog block', ['changelog/announce'], '## Changelog\n\n## Announcement\n' + POST, 'EMPTY_BLOCK');
refusal('announce with a Changelog block saying None', ['changelog/announce'], '## Changelog\nNone\n\n## Announcement\n' + POST, 'BLOCK_SAYS_NONE');
check(/changelog\/announce/.test(parse(['changelog/announce'], '## Announcement\n' + POST).reason || '')
  && !/changelog\/visible/.test(parse(['changelog/announce'], '## Announcement\n' + POST).reason || ''),
  'the missing sentence refusal for an announce change names the wrong label: ' + parse(['changelog/announce'], '## Announcement\n' + POST).reason);
// R1: the post for agents is required beside the sentence.
const sentencesBefore = refusals.map(function (pair) { return pair[1]; });
const noPost = refusal('announce with no Announcement block', ['changelog/announce'], SENTENCE, 'NO_ANNOUNCEMENT');
const emptyPost = refusal('announce with an empty Announcement block', ['changelog/announce'], SENTENCE + '\n## Announcement\n\n## Testing\nx', 'EMPTY_ANNOUNCEMENT');
// The two new causes each have a sentence of their own (the Changelog causes above keep the
// sentence they have under either label, being the same cause).
check(noPost.reason !== emptyPost.reason && sentencesBefore.indexOf(noPost.reason) === -1 && sentencesBefore.indexOf(emptyPost.reason) === -1,
  'a missing or an empty Announcement shares its sentence with another cause');
check(/## Announcement/.test(noPost.reason || '') && /@here/.test(noPost.reason || ''), 'the missing post refusal does not say what to add: ' + noPost.reason);
// The other kinds read exactly as they did.
r = parse(['changelog/visible'], ANNOUNCE_BODY);
check(r.ok === true && r.kind === 'visible' && r.announcement === undefined, 'a visible record changed shape: ' + JSON.stringify(r));

// ---- the registry: which repository announces, and where
const ANNOUNCING = { repos: [
  { name: 'Board', repo: 'acme/board', changelogFrom: '2026-09-01', announceChannel: 'C0000TEST01' },
  { name: 'Quiet', repo: 'acme/quiet', changelogFrom: '2026-09-01' },
  { name: 'Typo', repo: 'acme/typo', changelogFrom: '2026-09-01', announceChannel: '#announcements' },
  { name: 'Empty', repo: 'acme/empty', changelogFrom: '2026-09-01', announceChannel: '' },
  { name: 'Number', repo: 'acme/number', changelogFrom: '2026-09-01', announceChannel: 12 },
] };
function announcing(slug) { return entry.repoScope(ANNOUNCING, slug, TODAY); }
s = announcing('acme/board');
check(s.inScope === true && s.announceChannel === 'C0000TEST01' && s.badAnnounce !== true, 'a repository naming an announcements channel did not say which: ' + JSON.stringify(s));
check(s.repo === 'acme/board', 'the scope of a gated repository does not name the repository: ' + JSON.stringify(s));
s = announcing('acme/quiet');
check(s.inScope === true && s.announceChannel === '' && s.badAnnounce !== true, 'a repository naming no announcements channel did not read as naming none: ' + JSON.stringify(s));
s = announcing('acme/empty');
check(s.inScope === true && s.announceChannel === '' && s.badAnnounce !== true, 'an empty announceChannel did not read as naming none: ' + JSON.stringify(s));
// One present but not a channel id is a config error with its own flag, never "names none": a typo
// would otherwise switch the label off in silence (L98).
['acme/typo', 'acme/number'].forEach(function (slug) {
  s = announcing(slug);
  check(s.inScope === true && s.badAnnounce === true && s.announceChannel === '' && /announceChannel/.test(s.why || '') && /not a Slack channel id/.test(s.why || ''),
    'an announceChannel that is not a channel id was not reported as a config error for ' + slug + ': ' + JSON.stringify(s));
});
check(/#announcements/.test(announcing('acme/typo').why || ''), 'the bad channel refusal does not quote the value: ' + JSON.stringify(announcing('acme/typo')));

// ---- gateRefusal: what the MERGE GATE refuses, and only the merge gate
check(typeof entry.gateRefusal === 'function', 'changelog-entry.js exports no gateRefusal');
const gateRefusal = typeof entry.gateRefusal === 'function' ? entry.gateRefusal : function () { return { code: 'ABSENT', reason: '' }; };
const HERE = announcing('acme/board');
const NOT_HERE = announcing('acme/quiet');
function gate(labels, body, scopeOf) { return gateRefusal(parse(labels, body), body, scopeOf); }
const gateRefusals = [];
function gateRefuses(name, labels, body, scopeOf, expectCode) {
  const got = gate(labels, body, scopeOf);
  check(got !== null && typeof got === 'object' && got.code === expectCode, name + ': expected the gate to refuse with ' + expectCode + ', got ' + JSON.stringify(got));
  check(got && typeof got.reason === 'string' && got.reason.length > 20, name + ': the refusal carries no usable sentence: ' + JSON.stringify(got));
  if (got && got.reason) gateRefusals.push([name, got.reason]);
  return got || { reason: '' };
}
function gateAllows(name, labels, body, scopeOf) {
  const got = gate(labels, body, scopeOf);
  check(got === null, name + ': the gate refused what it should take: ' + JSON.stringify(got));
}
function withPost(post) { return SENTENCE + '\n## Announcement\n' + post + '\n'; }

// R1 and R7, still possible: both pieces of writing, in the repository that names a channel.
gateAllows('an announce change with both pieces of writing, where the repository announces', ['changelog/announce'], ANNOUNCE_BODY, HERE);
// The other three are judged exactly as before, in either kind of repository.
[HERE, NOT_HERE].forEach(function (sc) {
  gateAllows('a visible change', ['changelog/visible'], SENTENCE, sc);
  gateAllows('a technical change', ['changelog/technical'], 'prose only', sc);
  gateAllows('a none change', ['changelog/none'], 'prose only', sc);
  check((gate(['changelog/visible'], 'prose only', sc) || {}).code === 'NO_BLOCK', 'a visible change with no block is no longer refused as NO_BLOCK by the gate');
  check((gate(['changelog/none'], SENTENCE, sc) || {}).code === 'NONE_WITH_BLOCK', 'a none change carrying a block is no longer refused as NONE_WITH_BLOCK by the gate');
});
// R1: no post for agents, no merge.
gateRefuses('announce with no Announcement block, where the repository announces', ['changelog/announce'], SENTENCE, HERE, 'NO_ANNOUNCEMENT');
gateRefuses('announce with an empty Announcement block, where the repository announces', ['changelog/announce'], SENTENCE + '\n## Announcement\n\n## Testing\nx', HERE, 'EMPTY_ANNOUNCEMENT');
gateRefuses('announce with no Changelog sentence, where the repository announces', ['changelog/announce'], '## Announcement\n' + POST, HERE, 'NO_BLOCK');
// R7: the label is refused where the repository names no channel, whatever the pull request carries.
let notHere = gateRefuses('a complete announce change where the repository names no channel', ['changelog/announce'], ANNOUNCE_BODY, NOT_HERE, 'ANNOUNCE_NOT_HERE');
check(/announceChannel/.test(notHere.reason) && /acme\/quiet/.test(notHere.reason), 'the refusal does not name the registry key or the repository: ' + notHere.reason);
// A key that was lost looks exactly the same, so the refusal says so and says how to check.
check(/lost/.test(notHere.reason) && /dev-update-registry\.js announce-channel acme\/quiet/.test(notHere.reason), 'the refusal does not say a lost key looks the same, or how to check: ' + notHere.reason);
check((gate(['changelog/announce'], SENTENCE, NOT_HERE) || {}).code === 'ANNOUNCE_NOT_HERE' && (gate(['changelog/announce'], 'prose only', NOT_HERE) || {}).code === 'ANNOUNCE_NOT_HERE',
  'an incomplete announce change where the label is not in use was told to finish its writing, not that the label is not in use here');
// A scope the gate never built (no channel field at all) is a repository that names none.
check((gateRefusal(parse(['changelog/announce'], ANNOUNCE_BODY), ANNOUNCE_BODY, { inScope: true, from: '2026-09-01', name: 'Old' }) || {}).code === 'ANNOUNCE_NOT_HERE'
  && (gateRefusal(parse(['changelog/announce'], ANNOUNCE_BODY), ANNOUNCE_BODY, undefined) || {}).code === 'ANNOUNCE_NOT_HERE',
  'a scope naming no channel at all let the announce label through');

// The refusals name the labels valid for THAT repository, and count them, so a repository that does
// not announce is never told to use the label it would be refused for.
let none = gateRefuses('no label, where the repository announces', ['priority-p2'], 'x', HERE, 'NO_LABEL');
check(/changelog\/announce/.test(none.reason) && /changelog\/visible, changelog\/technical, changelog\/none/.test(none.reason), 'the missing label refusal does not list all four where the repository announces: ' + none.reason);
none = gateRefuses('no label, where the repository does not announce', ['priority-p2'], 'x', NOT_HERE, 'NO_LABEL');
check(!/changelog\/announce/.test(none.reason) && /changelog\/visible, changelog\/technical, changelog\/none/.test(none.reason), 'the missing label refusal offers a label this repository is refused for: ' + none.reason);
let odd = gateRefuses('an unknown label, where the repository announces', ['changelog/goals'], 'x', HERE, 'UNKNOWN_KIND');
check(/these four/.test(odd.reason) && /changelog\/announce/.test(odd.reason) && /changelog\/goals/.test(odd.reason), 'the unknown label refusal does not count and list four where the repository announces: ' + odd.reason);
odd = gateRefuses('an unknown label, where the repository does not announce', ['changelog/goals'], 'x', NOT_HERE, 'UNKNOWN_KIND');
check(/these three/.test(odd.reason) && !/changelog\/announce/.test(odd.reason), 'the unknown label refusal counts or lists a label this repository is refused for: ' + odd.reason);
check((gate(['changelog/visible', 'changelog/announce'], ANNOUNCE_BODY, HERE) || {}).code === 'MANY_LABELS', 'two labels, one of them announce, are no longer refused as MANY_LABELS');

// Another kind carrying an Announcement block: the post would be written and never drafted.
let stray = gateRefuses('a visible change carrying an Announcement block, where the repository announces', ['changelog/visible'], ANNOUNCE_BODY, HERE, 'ANNOUNCEMENT_WITHOUT_LABEL');
check(/changelog\/announce/.test(stray.reason) && /changelog\/visible/.test(stray.reason), 'the refusal does not name the label carried and the one that uses the block: ' + stray.reason);
stray = gateRefuses('a technical change carrying an Announcement block, where the repository does not announce', ['changelog/technical'], '## Announcement\n' + POST, NOT_HERE, 'ANNOUNCEMENT_WITHOUT_LABEL');
check(!/relabel/i.test(stray.reason) && /announceChannel/.test(stray.reason), 'a repository that does not announce was told to relabel to the label it is refused for: ' + stray.reason);
gateAllows('a visible change whose Announcement heading has nothing under it', ['changelog/visible'], SENTENCE + '\n## Announcement\n\n## Testing\nx', HERE);
gateAllows('a visible change whose Announcement block says None', ['changelog/visible'], SENTENCE + '\n## Announcement\nNone.\n', HERE);

// The opener: @here typed plainly on its own first line, which is what became a real mention when
// the draft was sent (measured 2026-11-25, claude-config#3664). Nothing is added to the wording
// after it is approved, so a post without it would be drafted without it.
check(entry.ANNOUNCEMENT_OPENER === '@here', 'the opener is not the spelling that was measured: ' + JSON.stringify(entry.ANNOUNCEMENT_OPENER));
gateRefuses('a post that does not open with @here', ['changelog/announce'], withPost('Hi team\nYou can now hand a call back.'), HERE, 'ANNOUNCEMENT_NO_OPENER');
check((gate(['changelog/announce'], withPost('<!here>\nYou can now hand a call back.'), HERE) || {}).code === 'ANNOUNCEMENT_NO_OPENER'
  && (gate(['changelog/announce'], withPost('@here You can now hand a call back.'), HERE) || {}).code === 'ANNOUNCEMENT_NO_OPENER'
  && (gate(['changelog/announce'], withPost('You can now hand a call back.\n@here'), HERE) || {}).code === 'ANNOUNCEMENT_NO_OPENER',
  'an opener spelled another way, sharing its line, or below the first line was taken');

// An HTML comment in the block: the template guidance left in, which would be drafted as text.
gateRefuses('a post carrying an HTML comment', ['changelog/announce'], withPost('@here\n<!-- say what agents do differently -->\nYou can now hand a call back.'), HERE, 'ANNOUNCEMENT_HTML_COMMENT');

// Markdown: only what arrived in a sent post when it was measured (2026-11-25, claude-config#3664).
gateAllows('bold, italics, both bullets, a numbered list, a bare link, a labelled link, and & < >', ['changelog/announce'],
  withPost('@here\n**Bold** and *italic* and _italic_.\n- a dash bullet\n* a star bullet\n• a dot bullet\n1. one\n2. two\nRates & terms, when x < 5 or y > 3.\nhttps://example.com/a-b and [the guide](https://example.com/a--b).'), HERE);
[
  ['a code span', '@here\nRun `the thing` now.', 'code'],
  ['a code fence', '@here\n```\nthe thing\n```', 'code'],
  ['a block quote', '@here\n> quoted', 'quote'],
  ['a table', '@here\n| a | b |\n| 1 | 2 |', 'table'],
  ['a picture', '@here\n![shot](https://example.com/a.png)', 'picture'],
  ['struck through text', '@here\nThis is ~~gone~~ now.', 'struck'],
  ['a nested list', '@here\n- one\n  - inside', 'nested'],
  ['a task box', '@here\n- [ ] do it', 'task'],
  ['a rule line', '@here\nAbove\n\n***\n\nBelow', 'rule'],
].forEach(function (c) {
  const got = gate(['changelog/announce'], withPost(c[1]), HERE);
  check(got !== null && got.code === 'ANNOUNCEMENT_MARKDOWN' && new RegExp(c[2], 'i').test(got.reason || ''),
    c[0] + ' was not refused as markdown nobody measured, naming it: ' + JSON.stringify(got));
});
gateRefusals.push(['markdown nobody measured', (gate(['changelog/announce'], withPost('@here\nRun `the thing` now.'), HERE) || {}).reason]);
// One refusal names every such thing in the post, so it is fixed in one pass.
let both = gate(['changelog/announce'], withPost('@here\nRun `the thing`.\n> quoted'), HERE) || {};
check(/code/i.test(both.reason || '') && /quote/i.test(both.reason || ''), 'a post with two kinds of unmeasured markdown was told about one: ' + both.reason);

// Dashes as punctuation, by a rule written for text of several lines. The card's own test
// (mods/is-it-live/hooks/card.ts) reads a line break before a bullet as a dash between words, which
// would refuse every bulleted post.
gateAllows('dash bullets, hyphenated words and a negative number', ['changelog/announce'],
  withPost('@here\nHi team\n- Do X\n- Do a follow-up\n\nSteps:\n- one\n- minus -5 degrees'), HERE);
[
  ['an em dash', '@here\nHand back' + EM_DASH + 'then pick a reason.'],
  ['an en dash', '@here\nOpen 9' + EN_DASH + '5.'],
  ['a double hyphen', '@here\nHand back -- then pick a reason.'],
  ['a spaced hyphen', '@here\nHand back - then pick a reason.'],
  ['a spaced hyphen inside a bullet', '@here\n- Hand back - then pick a reason.'],
  ['a hyphen ending a line', '@here\nHand back -\nthen pick a reason.'],
].forEach(function (c) {
  const got = gate(['changelog/announce'], withPost(c[1]), HERE);
  check(got !== null && got.code === 'ANNOUNCEMENT_DASHES', c[0] + ' was not refused as a dash used as punctuation: ' + JSON.stringify(got));
});
gateRefusals.push(['a dash as punctuation', (gate(['changelog/announce'], withPost('@here\nHand back - then pick a reason.'), HERE) || {}).reason]);
// The refusal quotes the line, so it can be found.
check(/Hand back - then pick a reason\./.test((gate(['changelog/announce'], withPost('@here\nFine.\nHand back - then pick a reason.'), HERE) || {}).reason || ''), 'the dash refusal does not quote the line');

// Each gate refusal has its own sentence.
(function () {
  const seenGate = new Map();
  gateRefusals.forEach(function (pair) {
    if (seenGate.has(pair[1])) fail('two gate refusals share one sentence: ' + seenGate.get(pair[1]) + ' and ' + pair[0]);
    else { seenGate.set(pair[1], pair[0]); pass(); }
  });
})();
// None of this is in the history reader: every post the gate refuses for what is IN it still reads
// as a record, so a change that merged around the gate is listed, never turned into a gap.
['Hi team\nNo opener.', '@here\nRun `the thing`.', '@here\nHand back - then.', '@here\n<!-- x -->\nText.'].forEach(function (post) {
  const read = parse(['changelog/announce'], withPost(post));
  check(read.ok === true && read.kind === 'announce' && read.announcement === post, 'the history reader refused a post over its wording: ' + JSON.stringify(read));
});

// ---- requiredLabels: the announce label only where it is in use, and only to a caller that says
// it understands needsDan (the shared fixtures above hold the answers; these are the reasons)
g = requiredLabels({ state: 'ok', registry: ANNOUNCING }, 'acme/typo', TODAY, { needsDan: true });
check(g.state === 'unknown' && /announceChannel/.test(g.why || ''), 'a repository whose announceChannel is not a channel id did not read as unknown with why: ' + JSON.stringify(g));
g = requiredLabels({ state: 'ok', registry: ANNOUNCING }, 'acme/board', TODAY, { needsDan: true });
(g.labels || []).forEach(function (l) {
  const kind = l.label.slice('changelog/'.length);
  check(typeof l.needsDan === 'boolean' && l.needsDan === (facts.needsDan || {})[kind], l.label + ' is marked needsDan=' + l.needsDan + ' against the map');
  // Whether a label needs the post for agents is asked of parseEntry itself, never restated.
  const bare = parse([l.label], SENTENCE);
  check(l.needsAnnouncement === (bare.ok === false && bare.code === 'NO_ANNOUNCEMENT'), l.label + ' is marked needsAnnouncement=' + l.needsAnnouncement + ' while parseEntry says ' + JSON.stringify(bare));
});
check((g.labels || []).some(function (l) { return l.label === 'changelog/announce' && l.needsDan === true && l.needsAnnouncement === true && l.needsSentence === true; }),
  'the announce label is not listed, with what it needs, where it is in use: ' + JSON.stringify(g));

// ---- the command lines
const annDir = fs.mkdtempSync(path.join(os.tmpdir(), 'changelog-announce-'));
const annRegistry = path.join(annDir, 'repos.local.json');
fs.writeFileSync(annRegistry, JSON.stringify(ANNOUNCING));
function cliIn(args, input) {
  const ran = childProcess.spawnSync(process.execPath, [path.join(__dirname, 'changelog-entry.js')].concat(args), { encoding: 'utf8', input: input === undefined ? '' : input });
  let json = null;
  try { json = JSON.parse(ran.stdout); } catch (e) { json = null; }
  return { status: ran.status, json: json, stdout: ran.stdout, stderr: ran.stderr };
}
// required-labels: the flag may sit before or after the registry file, and without it the answer is
// the one a session running the mod as it was has always had.
c = cliIn(['required-labels', 'acme/board', annRegistry, '--needs-dan']);
check(c.status === 0 && c.json && c.json.state === 'required' && c.json.labels.length === 4 && c.json.labels[3].label === 'changelog/announce' && c.json.labels[3].needsDan === true,
  'the command line did not list the announce label, with needsDan, to a caller passing the flag: ' + JSON.stringify(c));
c = cliIn(['required-labels', 'acme/board', '--needs-dan', annRegistry]);
check(c.status === 0 && c.json && c.json.state === 'required' && c.json.labels.length === 4, 'the flag ahead of the registry file was read as the file: ' + JSON.stringify(c));
c = cliIn(['required-labels', 'acme/board', annRegistry]);
check(c.status === 0 && c.json && JSON.stringify(c.json.labels) === JSON.stringify([{ label: 'changelog/visible', needsSentence: true }, { label: 'changelog/technical', needsSentence: false }, { label: 'changelog/none', needsSentence: false }]),
  'a caller that does not pass the flag saw the announce label or a field it does not know: ' + JSON.stringify(c));
c = cliIn(['required-labels', 'acme/quiet', annRegistry, '--needs-dan']);
check(c.status === 0 && c.json && c.json.state === 'required' && c.json.labels.length === 3 && c.json.labels.every(function (l) { return l.needsDan === false && l.label !== 'changelog/announce'; }),
  'the announce label was listed for a repository that names no channel: ' + JSON.stringify(c));
c = cliIn(['required-labels', '--needs-dan']);
check(c.status === 2, 'a flag was read as the repository: ' + JSON.stringify(c));
c = cliIn(['required-labels', 'acme/board', annRegistry, '--something-else']);
check(c.status === 2, 'a flag nobody defined did not exit 2: ' + JSON.stringify(c));

// announcement <owner/name> [file]: what a merged pull request owes, from its JSON on standard input.
function prJson(labels, body) { return JSON.stringify({ number: 7, labels: labels.map(function (n) { return { name: n }; }), body: body }); }
c = cliIn(['announcement', 'acme/board', annRegistry], prJson(['changelog/announce'], ANNOUNCE_BODY.replace(/\n/g, '\r\n')));
check(c.status === 0 && c.json && c.json.state === 'owed' && c.json.channel === 'C0000TEST01' && c.json.text === POST && c.json.why === '',
  'a merged announce change did not read as owing its post, to the channel, word for word: ' + JSON.stringify(c));
check(c.json && c.json.normalized === normalizeAnnouncement(POST), 'the answer does not carry the one normalised form of the text: ' + JSON.stringify(c.json));
c = cliIn(['announcement', 'acme/board', annRegistry], prJson(['changelog/visible'], SENTENCE));
check(c.status === 0 && c.json && c.json.state === 'none' && c.json.channel === '' && c.json.text === '', 'a visible change did not read as owing nothing: ' + JSON.stringify(c));
c = cliIn(['announcement', 'acme/board', annRegistry], prJson([], 'x'));
check(c.status === 0 && c.json && c.json.state === 'none', 'a change with no changelog label did not read as owing nothing: ' + JSON.stringify(c));
// Whatever cannot be told is unknown with why, never none: the reader keeps it as owed.
c = cliIn(['announcement', 'acme/quiet', annRegistry], prJson(['changelog/announce'], ANNOUNCE_BODY));
check(c.status === 0 && c.json && c.json.state === 'unknown' && c.json.channel === '' && c.json.text === POST && /announceChannel/.test(c.json.why || ''),
  'an announce change in a repository naming no channel did not read as unknown, text kept, with why: ' + JSON.stringify(c));
c = cliIn(['announcement', 'acme/typo', annRegistry], prJson(['changelog/announce'], ANNOUNCE_BODY));
check(c.status === 0 && c.json && c.json.state === 'unknown' && /not a Slack channel id/.test(c.json.why || ''), 'a channel that is not a channel id did not read as unknown with why: ' + JSON.stringify(c));
c = cliIn(['announcement', 'acme/board', annRegistry], prJson(['changelog/announce'], SENTENCE));
check(c.status === 0 && c.json && c.json.state === 'unknown' && c.json.text === '' && /Announcement/.test(c.json.why || ''), 'an announce change with no post did not read as unknown with why: ' + JSON.stringify(c));
c = cliIn(['announcement', 'acme/board', annRegistry], prJson(['changelog/announce', 'changelog/none'], ANNOUNCE_BODY));
check(c.status === 0 && c.json && c.json.state === 'unknown', 'announce beside another label did not read as unknown: ' + JSON.stringify(c));
c = cliIn(['announcement', 'acme/board', path.join(annDir, 'not-there.json')], prJson(['changelog/announce'], ANNOUNCE_BODY));
check(c.status === 0 && c.json && c.json.state === 'unknown' && c.json.text === POST && /not at/.test(c.json.why || ''), 'a missing registry did not read as unknown, text kept: ' + JSON.stringify(c));
c = cliIn(['announcement', 'acme/elsewhere', annRegistry], prJson(['changelog/announce'], ANNOUNCE_BODY));
check(c.status === 0 && c.json && c.json.state === 'unknown' && /not listed/.test(c.json.why || ''), 'an announce change in a repository the registry does not list did not read as unknown: ' + JSON.stringify(c));
c = cliIn(['announcement', 'acme/board', annRegistry], 'not json');
check(c.status === 0 && c.json && c.json.state === 'unknown' && /standard input/.test(c.json.why || ''), 'a pull request that could not be read did not read as unknown: ' + JSON.stringify(c));
c = cliIn(['announcement', 'acme/board', annRegistry], '');
check(c.status === 0 && c.json && c.json.state === 'unknown', 'nothing on standard input did not read as unknown: ' + JSON.stringify(c));
c = cliIn(['announcement']);
check(c.status === 2 && c.json === null, 'the announcement command answered with no repository named: ' + JSON.stringify(c));
fs.rmSync(annDir, { recursive: true, force: true });

console.log('  ' + passed + ' passed, ' + failed + ' failed');
console.log('SUITE-RESULT passed=' + passed + ' failed=' + failed);
process.exit(failed === 0 ? 0 : 1);
