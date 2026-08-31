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
// A repo opts in by being listed in the dev update skill's repos.json, which
// already exists and already names the repos the post covers. A second registry
// beside it would be one more thing to add Slate to, and the two would disagree
// the first time only one was updated.

const REGISTRY = {
  repos: [
    { name: 'PET', repo: 'Try-Pennie/project-enrollment-tracker', changelogFrom: '2026-09-01' },
    { name: 'NoDate', repo: 'acme/nodate' },
    { name: 'Later', repo: 'acme/later', changelogFrom: '2026-12-01' },
    { name: 'Bad', repo: 'acme/bad', changelogFrom: 'December' },
  ],
};

// The day is always passed in. A test that reads the machine's clock is a test
// about the machine, and this one would change its own answer on 1 December.
const TODAY = '2026-09-15';
function scope(slug, today) { return entry.repoScope(REGISTRY, slug, today || TODAY); }

let s = scope('Try-Pennie/project-enrollment-tracker');
check(s.inScope === true && s.from === '2026-09-01',
  'a listed repo carrying a past start date was not in scope: ' + JSON.stringify(s));

s = scope('someone/else');
check(s.inScope === false, 'an unlisted repo was gated: ' + JSON.stringify(s));

// Case: GitHub slugs are not case sensitive and a remote can be spelled either way.
s = scope('try-pennie/Project-Enrollment-Tracker');
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
s = entry.repoScope(null, 'Try-Pennie/project-enrollment-tracker');
check(s.inScope === false && s.unreadable === true,
  'an unreadable registry read as a deliberate opt out: ' + JSON.stringify(s));

console.log('  ' + passed + ' passed, ' + failed + ' failed');
console.log('SUITE-RESULT passed=' + passed + ' failed=' + failed);
process.exit(failed === 0 ? 0 : 1);
