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
refusal('a label outside the three', ['changelog/goals'], '## Changelog\nA line.', 'UNKNOWN_KIND');
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

gateCases.forEach(function (c) {
  const read = c.registry === null
    ? { state: 'unreadable', why: 'the registry could not be read' }
    : { state: 'ok', registry: c.registry };
  const got = requiredLabels(read, c.repo, c.today);
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
g = requiredLabels({ state: 'ok', registry: REGISTRY }, 'Acme-Corp/enrollment-board', TODAY);
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

console.log('  ' + passed + ' passed, ' + failed + ' failed');
console.log('SUITE-RESULT passed=' + passed + ' failed=' + failed);
process.exit(failed === 0 ? 0 : 1);
