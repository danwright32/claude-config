'use strict';
//
// changelog-entry.js: the one definition of what a changelog record is.
//
// Why this exists: the first manager facing update covering June to August meant
// reading all 499 pull request titles merged in that period and judging each one
// as manager visible or plumbing by hand, because nothing recorded the
// distinction at the time the change shipped. That judgment is both cheaper and
// better at merge time than in arrears (PET #1186).
//
// A change carries its record in two halves, on purpose:
//   the LABEL   changelog/visible | changelog/technical | changelog/none
//   the BODY    a "## Changelog" block carrying the sentence a manager reads
//
// The label is the half that shows in the pull request list, filters in the
// GitHub UI with no tooling, and can be corrected after a merge with one click.
// The body is the half that carries prose, which a label cannot. Split that way,
// neither field is written twice and neither can contradict the other.
//
// The vocabulary is deliberately COARSE. The post's section headings are derived
// per run by the /pennie-dev-update skill from what actually shipped, so a fixed
// per repo list of sections here would be a second mechanism deciding the same
// headings, and the two would drift.
//
// Only the VISIBLE half requires prose. Most pull requests are plumbing, and
// requiring a manager facing sentence on each one would be a cost paid on every
// change to buy a line that gets collapsed into a single roll-up anyway.

const LABEL_PREFIX = 'changelog/';

const VISIBLE = 'visible';     // a manager would notice this; needs a sentence
const TECHNICAL = 'technical'; // plumbing worth a line in the roll-up at the bottom
const NONE = 'none';           // does not appear in the post at all

const KINDS = [VISIBLE, TECHNICAL, NONE];
const KIND_LIST = KINDS.map(function (k) { return LABEL_PREFIX + k; }).join(', ');

// The heading, matched leniently on depth and case, strictly on shape: it has to
// be a heading line of its own, so the word appearing in a sentence cannot open
// a block.
const BLOCK_HEADING = /^[ \t]{0,3}#{1,6}[ \t]*changelog[ \t]*:?[ \t]*$/i;
// Any other heading closes it. Whitespace after the hashes is required so that a
// "#1186" cross reference at the start of a line is not read as a heading.
const ANY_HEADING = /^[ \t]{0,3}#{1,6}[ \t]+\S/;
// A block whose whole content is the word None: the "nothing to say" answer put
// in the body instead of on the label.
const SAYS_NOTHING = /^none[.!]?$/i;

// A calendar day, which is the only shape changelogFrom may take.
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

// This machine's local day, as YYYY-MM-DD. Built from the local parts rather
// than toISOString(), which converts to UTC first and so reports tomorrow's date
// all evening anywhere east of Greenwich and yesterday's all night in New York.
function localDay(now) {
  const d = now || new Date();
  const pad = function (n) { return String(n).padStart(2, '0'); };
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
}

// The changelog labels on a pull request, lowercased and deduplicated. Accepts
// bare strings or the {name} objects `gh --json labels` returns, because
// normalising at every call site is how one call site ends up not doing it.
function changelogLabels(labels) {
  const tags = (labels || [])
    .map(function (l) {
      if (l && typeof l === 'object' && typeof l.name === 'string') return l.name;
      return typeof l === 'string' ? l : '';
    })
    .map(function (n) { return n.trim().toLowerCase(); })
    .filter(function (n) { return n.indexOf(LABEL_PREFIX) === 0; })
    .map(function (n) { return n.slice(LABEL_PREFIX.length).trim(); })
    .filter(Boolean);
  return Array.from(new Set(tags));
}

// The text under the block heading, folded to one line because a bullet in the
// post is one line.
//
// Returns null when there is no heading at all, which is a DIFFERENT answer from
// an empty string and has to stay different: one is a person who wrote no block,
// the other is a person who wrote an empty one, and they need different
// sentences (L11).
function extractBlock(body) {
  if (typeof body !== 'string') return null;
  const lines = body.split(/\r?\n/);
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (BLOCK_HEADING.test(lines[i])) { start = i; break; }
  }
  if (start === -1) return null;
  const collected = [];
  for (let i = start + 1; i < lines.length; i++) {
    if (ANY_HEADING.test(lines[i])) break;
    collected.push(lines[i]);
  }
  return collected.join(' ').replace(/\s+/g, ' ').trim();
}

function refuse(code, reason) {
  return { ok: false, code: code, reason: reason };
}

// { labels, body } -> one of
//   { ok:true, kind, line }      line is null when none was written
//   { ok:false, code, reason }   one code and one sentence per cause
function parseEntry(input) {
  const tags = changelogLabels(input && input.labels);

  if (tags.length === 0) {
    return refuse('NO_LABEL',
      'This pull request carries no ' + LABEL_PREFIX + '* label, so the manager update has no record '
      + 'of whether anyone outside engineering would notice this change. Deciding that months later '
      + 'means re-reading every merged title, which is the cost this label exists to remove. '
      + 'Add exactly one of: ' + KIND_LIST + '.');
  }
  if (tags.length > 1) {
    return refuse('MANY_LABELS',
      'This pull request carries more than one changelog label ('
      + tags.map(function (t) { return LABEL_PREFIX + t; }).join(', ')
      + '). A change is either something a manager notices, plumbing, or not worth mentioning. '
      + 'Pick one.');
  }

  const kind = tags[0];
  if (KINDS.indexOf(kind) === -1) {
    return refuse('UNKNOWN_KIND',
      LABEL_PREFIX + kind + ' is not one of the changelog labels. The update is assembled by reading '
      + 'these three, so a label outside them records nothing. Use one of: ' + KIND_LIST + '.');
  }

  const block = extractBlock(input && input.body);
  const wroteSomething = block !== null && block !== '' && !SAYS_NOTHING.test(block);

  if (kind === NONE) {
    if (wroteSomething) {
      return refuse('NONE_WITH_BLOCK',
        'This pull request is labelled ' + LABEL_PREFIX + NONE + ', which keeps it out of the update '
        + 'entirely, but its body carries a Changelog block: "' + block + '". That sentence would be '
        + 'written and then thrown away. Either relabel it ' + LABEL_PREFIX + VISIBLE + ' so the line '
        + 'is used, or delete the block.');
    }
    return { ok: true, kind: NONE, line: null };
  }

  if (kind === TECHNICAL) {
    // No block required. Plumbing is collapsed into a handful of roll-up lines,
    // and a sentence per change would be written far more often than it is read.
    return { ok: true, kind: TECHNICAL, line: wroteSomething ? block : null };
  }

  // VISIBLE. Here the sentence is the whole point: pull request titles are
  // written for the person merging, not for a sales manager, so a title alone
  // still costs a rewrite every time the update is assembled.
  if (block === null) {
    return refuse('NO_BLOCK',
      'This pull request is labelled ' + LABEL_PREFIX + VISIBLE + ' but its body has no '
      + '"## Changelog" heading, so there is no sentence for the update to carry. Its title is '
      + 'written for the person merging it. Add the heading with one plain language line under it '
      + 'saying what a manager would notice.');
  }
  if (block === '') {
    return refuse('EMPTY_BLOCK',
      'The "## Changelog" heading in this pull request has no sentence under it. An empty block '
      + 'reads exactly like a forgotten one, so it cannot stand for a deliberate choice. Write the '
      + 'line, or relabel this ' + LABEL_PREFIX + TECHNICAL + ' or ' + LABEL_PREFIX + NONE + '.');
  }
  if (SAYS_NOTHING.test(block)) {
    return refuse('BLOCK_SAYS_NONE',
      'The Changelog block says only "' + block + '", while the label (' + LABEL_PREFIX + VISIBLE
      + ') files this as something a manager notices, so the update would carry a bullet reading "'
      + block + '". The "nothing to say" answer belongs on the label: relabel this '
      + LABEL_PREFIX + NONE + ' and drop the block, or write the real sentence.');
  }

  return { ok: true, kind: VISIBLE, line: block };
}

// Is this repo gated, and from when?
//
// A repo opts in by being listed in the /pennie-dev-update skill's repos.json
// with a changelogFrom date. That file already exists and already names the
// repos the update covers, so a second registry beside it would be one more
// place to add Slate to, and the two would disagree the first time only one was
// updated.
//
// A repo with no changelogFrom is NOT gated. The gate can only speak for changes
// made after the rule reached that repo, and reading a missing date as "always"
// would refuse every pull request in a repo that has not adopted this yet,
// including the one that adds the date.
//
// changelogFrom is a START DATE, not merely an on switch, so a repo's date can be
// set to its launch day in advance and the gate begins then. Setting it early
// otherwise means it begins refusing immediately, which is the opposite of what
// the field says, and Slate is exactly the case where somebody would set it
// ahead of time.
//
// `today` is passed in as a 'YYYY-MM-DD' string. It defaults to this machine's
// local day, which is right for a switch that flips once and is never
// retrospective: a day either side of the boundary changes nothing anyone can
// observe. Every test passes it explicitly, because a test that reads the clock
// is a test about the machine.
function repoScope(registry, slug, today) {
  if (!registry || !Array.isArray(registry.repos)) {
    return {
      inScope: false,
      unreadable: true,
      why: 'the /pennie-dev-update repos.json could not be read, so whether this repo is gated is unknown',
    };
  }
  const want = String(slug || '').trim().toLowerCase();
  if (!want) return { inScope: false, why: 'no repo slug could be resolved for this merge' };

  const found = registry.repos.filter(function (r) {
    return r && String(r.repo || '').trim().toLowerCase() === want;
  })[0];

  if (!found) {
    return { inScope: false, why: slug + ' is not listed in the /pennie-dev-update repos.json' };
  }
  if (!found.changelogFrom) {
    // Listed with no start date is an UNFINISHED SETUP, not an opt out. Standing down here was a
    // bare exit 0, indistinguishable from a working gate on a repo whose start date has not
    // arrived (L98). The PET entry lost this field twice on 2026-08-31 to sessions that
    // regenerated repos.json instead of read-modify-writing it, and nothing reported either loss.
    // The repos nobody gated are the ones NOT listed at all, which is the branch above.
    return {
      inScope: false,
      missingFrom: true,
      why: slug + ' is listed in the registry but carries no changelogFrom date at all. A listed '
        + 'repo with no start date is an unfinished setup, not a repo nobody gated',
    };
  }

  const from = String(found.changelogFrom).trim();
  if (!ISO_DAY.test(from)) {
    // Not a date. Treating it as "not yet" would disable the gate silently on a
    // typo, and a silently disabled gate reads exactly like one that is passing.
    return {
      inScope: false,
      badDate: true,
      why: slug + ' has a changelogFrom of "' + found.changelogFrom + '", which is not a '
        + 'YYYY-MM-DD date. Leaving the gate off on an unreadable date would be indistinguishable '
        + 'from a repo nobody gated',
    };
  }

  const day = typeof today === 'string' && ISO_DAY.test(today) ? today : localDay();
  // String comparison is the whole of the arithmetic: YYYY-MM-DD sorts
  // chronologically as text, so this needs no date parsing and no timezone.
  if (day < from) {
    return {
      inScope: false,
      from: from,
      why: slug + ' does not require changelog records until ' + from + ' (today is ' + day + ')',
    };
  }

  return { inScope: true, from: from, name: found.name || slug };
}

module.exports = {
  parseEntry: parseEntry,
  extractBlock: extractBlock,
  changelogLabels: changelogLabels,
  repoScope: repoScope,
  LABEL_PREFIX: LABEL_PREFIX,
  KINDS: KINDS,
  VISIBLE: VISIBLE,
  TECHNICAL: TECHNICAL,
  NONE: NONE,
};
