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
//   the LABEL   changelog/visible | changelog/technical | changelog/none | changelog/announce
//   the BODY    a "## Changelog" block carrying the sentence a manager reads, and under the
//               announce label an "## Announcement" block carrying the post for agents
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
// Only a change a manager notices requires prose: the visible label needs the
// Changelog sentence, and the announce label needs that sentence and the post for
// agents as well. Most pull requests are plumbing, and requiring a manager facing
// sentence on each one would be a cost paid on every change to buy a line that gets
// collapsed into a single roll-up anyway.
//
// A fourth label, changelog/announce (claude-config#3665), is for a change whose
// agents must or can act differently. It is a visible change that ALSO carries the
// whole post for agents, under a "## Announcement" heading beside the sentence for
// managers. Two functions read it, and the split between them is the design:
//   parseEntry    reads a record, on any Mac, whatever its registry says. It is also
//                 the reader of merged history (skills/pennie-dev-update/gather.js),
//                 where a refusal turns a change that shipped into a "gap". So
//                 nothing that depends on a registry, or on what an announcement may
//                 contain, is ever in it.
//   gateRefusal   is what the MERGE GATE alone adds: the label is refused where the
//                 repository's registry entry names no announcements channel, and
//                 the post is held to what was measured to survive the trip to Slack.

const registryReader = require('./dev-update-registry.js');

const LABEL_PREFIX = 'changelog/';

const VISIBLE = 'visible';     // a manager would notice this; needs a sentence
const TECHNICAL = 'technical'; // plumbing worth a line in the roll-up at the bottom
const NONE = 'none';           // does not appear in the post at all
const ANNOUNCE = 'announce';   // agents must or can act differently; needs the sentence and the post

// New kinds go on the END: a caller that does not know a kind is handed the ones before it, in the
// order it has always had them (requiredLabels).
const KINDS = [VISIBLE, TECHNICAL, NONE, ANNOUNCE];

// Every fact about a kind is ONE map naming EVERY kind, and every reader asks the map, never a kind
// by name. Before these, pr-merge-quiz.sh asked "is it visible?" and read every other kind as quiet,
// so a fourth kind would have been quiet there without anybody deciding it (L96). A kind added to
// KINDS with no entry in each map fails changelog-entry.test.js, which walks KIND_FACTS.
const MANAGER_VISIBLE = { visible: true, technical: false, none: false, announce: true };
// The wording under this label is Dan's to approve before it merges.
const NEEDS_DAN = { visible: false, technical: false, none: false, announce: true };
// The label is in use only where the repository's registry entry names an announcements channel.
const NEEDS_ANNOUNCE_CHANNEL = { visible: false, technical: false, none: false, announce: true };
const KIND_FACTS = { managerVisible: MANAGER_VISIBLE, needsDan: NEEDS_DAN, needsAnnounceChannel: NEEDS_ANNOUNCE_CHANNEL };

function factOf(map, kind) {
  return typeof kind === 'string' && Object.prototype.hasOwnProperty.call(map, kind) && map[kind] === true;
}

// Would a manager notice a change of this kind? Asked by the merge quiz, which fires on such a
// change, and by the dev update's gatherer, which files it with what managers read. Anything that
// is not a kind is not one a manager notices.
function isManagerVisible(kind) { return factOf(MANAGER_VISIBLE, kind); }

// The kinds in use in one repository, given what repoScope said about it. Every refusal that lists
// labels and requiredLabels both ask this, so a repository that does not announce is never told to
// use, or told it may set, the label it would be refused for.
function kindsValidFor(scope) {
  const announces = !!(scope && typeof scope.announceChannel === 'string' && scope.announceChannel);
  return KINDS.filter(function (kind) { return announces || !factOf(NEEDS_ANNOUNCE_CHANNEL, kind); });
}
function labelList(kinds) {
  return kinds.map(function (k) { return LABEL_PREFIX + k; }).join(', ');
}
const COUNT_WORDS = ['no', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine'];
function countWord(n) { return COUNT_WORDS[n] || String(n); }

// The heading, matched leniently on depth and case, strictly on shape: it has to
// be a heading line of its own, so the word appearing in a sentence cannot open
// a block.
const BLOCK_HEADING = /^[ \t]{0,3}#{1,6}[ \t]*changelog[ \t]*:?[ \t]*$/i;
const ANNOUNCEMENT_HEADING = /^[ \t]{0,3}#{1,6}[ \t]*announcement[ \t]*:?[ \t]*$/i;
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

// Does this pull request carry the announce label at all? Asked about the LABEL alone, whatever
// else it carries and whether or not the record under it reads. The merge gate asks before it
// honours its override, which does not cover an announcement (Dan, 2026-11-25), so a second label or
// a missing post cannot turn one into a pull request the override covers. announcementOwed asks the
// same question of a merged one.
function carriesAnnounce(labels) {
  return changelogLabels(labels).indexOf(ANNOUNCE) !== -1;
}

// The text under the block heading, folded to one line because a bullet in the
// post is one line.
//
// Returns null when there is no heading at all, which is a DIFFERENT answer from
// an empty string and has to stay different: one is a person who wrote no block,
// the other is a person who wrote an empty one, and they need different
// sentences (L11).
function extractBlock(body) {
  const collected = linesUnder(body, BLOCK_HEADING);
  return collected === null ? null : collected.join(' ').replace(/\s+/g, ' ').trim();
}

// The lines under the first heading matching `heading`, up to the next heading of any kind, or null
// when the body has no such heading. The one walk both blocks are read with.
function linesUnder(body, heading) {
  if (typeof body !== 'string') return null;
  const lines = body.split(/\r?\n/);
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (heading.test(lines[i])) { start = i; break; }
  }
  if (start === -1) return null;
  const collected = [];
  for (let i = start + 1; i < lines.length; i++) {
    if (ANY_HEADING.test(lines[i])) break;
    collected.push(lines[i]);
  }
  return collected;
}

function isBlank(line) { return !/\S/.test(line); }

// The post for agents under the Announcement heading, WITH its line breaks: it is a whole post of
// several lines and a list, where the Changelog block is one sentence folded to one line. This is
// the text that is drafted, so the blank lines between its paragraphs are kept. Only what is never
// part of the wording goes: the line endings GitHub returns for a description edited on its own
// page (CRLF), spaces at the end of a line, and blank lines before the first line and after the last.
//
// null and the empty string are different answers here too, as for extractBlock (L11).
function extractAnnouncement(body) {
  const collected = linesUnder(body, ANNOUNCEMENT_HEADING);
  if (collected === null) return null;
  const lines = collected.map(function (l) { return l.replace(/\s+$/, ''); });
  while (lines.length && isBlank(lines[0])) lines.shift();
  while (lines.length && isBlank(lines[lines.length - 1])) lines.pop();
  return lines.join('\n');
}

// The ONE normalised form of an announcement, for every hash and every comparison of two copies of
// it (the approved wording against the pull request, the pull request against the draft): line
// endings, spaces at the end of a line, and every blank line dropped. Blank lines go everywhere and
// not only at the ends because Slack moves them: measured 2026-11-25 (claude-config#3664), the
// message box showed a blank line the draft did not have and the post read back had lost others.
// Never the text to draft, which is extractAnnouncement's, paragraphs kept.
function normalizeAnnouncement(text) {
  if (typeof text !== 'string') return '';
  return text.split(/\r\n?|\n/)
    .map(function (l) { return l.replace(/\s+$/, ''); })
    .filter(function (l) { return !isBlank(l); })
    .join('\n');
}

// The ONE hash of an announcement (claude-config#3666): the sha256 of its normalised form, in hex, or
// the empty string for wording that says nothing, so an empty file or an empty block is never a hash
// anything could be approved under. The wording Dan approves is a file and the wording that merges
// is a block in a pull request, read by lib/announce-approval.py and by the merge gate, and both
// come here (the announcement-hash command line below), so no reader normalises for itself.
function announcementHash(text) {
  const normal = normalizeAnnouncement(text);
  if (!normal) return '';
  return require('crypto').createHash('sha256').update(normal, 'utf8').digest('hex');
}

// `labelKind` is the one changelog label the pull request carries, where it carries exactly one,
// known kind or not: the merge gate needs it on a refusal too, to say that a label is not in use in
// a repository before it says what is missing from the writing under it.
function refuse(code, reason, labelKind) {
  const out = { ok: false, code: code, reason: reason };
  if (labelKind !== undefined) out.labelKind = labelKind;
  return out;
}

// The two refusals that list the labels to choose from. Written once, for the kinds handed in:
// parseEntry names every kind, and the merge gate names the ones in use in that repository.
function noLabelReason(kinds) {
  return 'This pull request carries no ' + LABEL_PREFIX + '* label, so the manager update has no record '
    + 'of whether anyone outside engineering would notice this change. Deciding that months later '
    + 'means re-reading every merged title, which is the cost this label exists to remove. '
    + 'Add exactly one of: ' + labelList(kinds) + '.';
}
function unknownKindReason(kind, kinds) {
  return LABEL_PREFIX + kind + ' is not one of the changelog labels. The update is assembled by reading '
    + 'these ' + countWord(kinds.length) + ', so a label outside them records nothing. Use one of: ' + labelList(kinds) + '.';
}

// Why the Changelog sentence under a label that requires one cannot be used, or null when it can.
// Shared by every kind that requires the sentence, so they cannot come to differ.
function sentenceRefusal(kind, block) {
  const label = LABEL_PREFIX + kind;
  if (block === null) {
    return refuse('NO_BLOCK',
      'This pull request is labelled ' + label + ' but its body has no '
      + '"## Changelog" heading, so there is no sentence for the update to carry. Its title is '
      + 'written for the person merging it. Add the heading with one plain language line under it '
      + 'saying what a manager would notice.', kind);
  }
  if (block === '') {
    return refuse('EMPTY_BLOCK',
      'The "## Changelog" heading in this pull request has no sentence under it. An empty block '
      + 'reads exactly like a forgotten one, so it cannot stand for a deliberate choice. Write the '
      + 'line, or relabel this ' + LABEL_PREFIX + TECHNICAL + ' or ' + LABEL_PREFIX + NONE + '.', kind);
  }
  if (SAYS_NOTHING.test(block)) {
    return refuse('BLOCK_SAYS_NONE',
      'The Changelog block says only "' + block + '", while the label (' + label
      + ') files this as something a manager notices, so the update would carry a bullet reading "'
      + block + '". The "nothing to say" answer belongs on the label: relabel this '
      + LABEL_PREFIX + NONE + ' and drop the block, or write the real sentence.', kind);
  }
  return null;
}

// { labels, body } -> one of
//   { ok:true, kind, line }                line is null when none was written
//   { ok:true, kind:'announce', line, announcement }
//                                          the sentence for managers and the post for agents
//   { ok:false, code, reason, labelKind? } one code and one sentence per cause
//
// It takes the pull request and NOTHING else, on purpose: no registry, no repository, no date. It
// is the reader of merged history as well as of the pull request about to merge, so what it accepts
// has to be the same on every Mac and on every later day (the head of this file).
function parseEntry(input) {
  const tags = changelogLabels(input && input.labels);

  if (tags.length === 0) return refuse('NO_LABEL', noLabelReason(KINDS));
  if (tags.length > 1) {
    return refuse('MANY_LABELS',
      'This pull request carries more than one changelog label ('
      + tags.map(function (t) { return LABEL_PREFIX + t; }).join(', ')
      + '). The update files each change in one place, by its one label, so two labels file it '
      + 'nowhere. Pick one.');
  }

  const kind = tags[0];
  if (KINDS.indexOf(kind) === -1) return refuse('UNKNOWN_KIND', unknownKindReason(kind, KINDS), kind);

  const block = extractBlock(input && input.body);
  const wroteSomething = block !== null && block !== '' && !SAYS_NOTHING.test(block);

  if (kind === NONE) {
    if (wroteSomething) {
      return refuse('NONE_WITH_BLOCK',
        'This pull request is labelled ' + LABEL_PREFIX + NONE + ', which keeps it out of the update '
        + 'entirely, but its body carries a Changelog block: "' + block + '". That sentence would be '
        + 'written and then thrown away. Either relabel it ' + LABEL_PREFIX + VISIBLE + ' so the line '
        + 'is used, or delete the block.', kind);
    }
    return { ok: true, kind: NONE, line: null };
  }

  if (kind === TECHNICAL) {
    // No block required. Plumbing is collapsed into a handful of roll-up lines,
    // and a sentence per change would be written far more often than it is read.
    return { ok: true, kind: TECHNICAL, line: wroteSomething ? block : null };
  }

  // VISIBLE and ANNOUNCE. Here the sentence is the whole point: pull request titles are
  // written for the person merging, not for a sales manager, so a title alone
  // still costs a rewrite every time the update is assembled.
  const noSentence = sentenceRefusal(kind, block);
  if (noSentence) return noSentence;
  if (kind === VISIBLE) return { ok: true, kind: VISIBLE, line: block };

  // ANNOUNCE: the post for agents as well, since the label says there is something to tell them and
  // the post is where it is told. What the post may contain is the merge gate's (gateRefusal), not
  // this reader's.
  const announcement = extractAnnouncement(input && input.body);
  if (announcement === null) {
    return refuse('NO_ANNOUNCEMENT',
      'This pull request is labelled ' + LABEL_PREFIX + ANNOUNCE + ', which says agents must or can act '
      + 'differently, but its body has no "## Announcement" heading, so there is no post for agents to '
      + 'draft once the change is live. Add the heading with the whole post under it, opening with '
      + ANNOUNCEMENT_OPENER + ' on a line of its own, beside the Changelog sentence for managers.', kind);
  }
  if (announcement === '') {
    return refuse('EMPTY_ANNOUNCEMENT',
      'The "## Announcement" heading in this pull request has no post under it, while the label ('
      + LABEL_PREFIX + ANNOUNCE + ') says there is something to tell agents. Write the post, opening with '
      + ANNOUNCEMENT_OPENER + ' on a line of its own, or relabel this ' + LABEL_PREFIX + VISIBLE
      + ' if agents have nothing to do differently.', kind);
  }
  return { ok: true, kind: ANNOUNCE, line: block, announcement: announcement };
}

// ------------------------------------------------------------------ the merge gate's own rules
//
// What an announcement may hold, measured on 2026-11-25 by sending a drafted post of about 1,200
// characters and reading it back (claude-config#3664). These are the constants that measurement
// decided, and each is measured again, never edited, if Slack or the draft tool changes.
//
// The opener: `@here` typed plainly on its own first line showed as a mention in the message box and
// read back as a real one once sent. The other spelling, <!here>, was never measured. The post
// carries its own opener because nothing is added to the wording after Dan approves it.
const ANNOUNCEMENT_OPENER = '@here';

// What arrived intact: bold, italics with asterisks or underscores, dot and dash bullets, a
// numbered list, a bare link, a labelled link, and the characters & < >. Everything else in
// markdown was not sent, so nobody knows what agents would see, and it is refused by name. Each
// test reads one line of the post. A bullet is a hyphen, a star, a plus or a dot.
const BULLET = '[-*+' + String.fromCharCode(0x2022) + ']';
const TASK_BOX = new RegExp('^[ \\t]*' + BULLET + '[ \\t]+\\[[ xX]\\]');
const NESTED_LIST = new RegExp('^(?:\\t+| {2,})(?:' + BULLET + '|\\d+[.)])[ \\t]+\\S');
const UNMEASURED_MARKDOWN = [
  { name: 'code (a backtick)', test: function (line) { return line.indexOf('`') !== -1; } },
  { name: 'a block quote (a line starting with >)', test: function (line) { return /^[ \t]{0,3}>/.test(line); } },
  { name: 'a table (a line starting with |)', test: function (line) { return /^[ \t]*\|/.test(line); } },
  { name: 'a picture (![...])', test: function (line) { return line.indexOf('![') !== -1; } },
  { name: 'struck through text (~~)', test: function (line) { return line.indexOf('~~') !== -1; } },
  { name: 'a task box ([ ] or [x] after a bullet)', test: function (line) { return TASK_BOX.test(line); } },
  { name: 'a nested list (an indented bullet or number)', test: function (line) { return NESTED_LIST.test(line); } },
  { name: 'a rule line (three hyphens, stars or underscores)', test: function (line) { return /^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$/.test(line); } },
];

// Dan's voice has no dashes as punctuation, and this is a post in his name. The rule is written for
// text of SEVERAL lines: the is it live card's own test (mods/is-it-live/hooks/card.ts) is one
// pattern over a few sentences, where a line break counts as the space before a hyphen, so it reads
// every dash bullet as a dash between words. Here each line is judged alone, after its links are
// taken out (an address may hold two hyphens) and after the bullet that starts it, if one does.
// The two long dashes are built from their code points, so this file holds neither.
const LINK = /https?:\/\/[^\s)>\]]+/g;
const LEADING_BULLET = /^[ \t]*-[ \t]+/;
const DASH_AS_PUNCTUATION = new RegExp('[' + String.fromCharCode(0x2014) + String.fromCharCode(0x2013) + ']|-{2}|(?:^|\\s)-(?:\\s|$)');
function dashLine(text) {
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (DASH_AS_PUNCTUATION.test(lines[i].replace(LINK, '').replace(LEADING_BULLET, ''))) return lines[i];
  }
  return null;
}

function gateRefuse(code, reason) { return { code: code, reason: reason }; }

// How to tell a repository that never announced from one whose registry entry lost its key: the
// two look exactly the same from here.
function howToCheckChannel(scope) {
  const slug = (scope && (scope.repo || scope.name)) || '<owner/name>';
  return 'node ~/.claude/hooks/lib/dev-update-registry.js announce-channel ' + slug;
}

const HTML_COMMENT_OPEN = '<!' + '-'.repeat(2);

// Why the post under an announce label cannot be drafted as it stands, or null when it can.
function announcementRefusal(text) {
  if (text.indexOf(HTML_COMMENT_OPEN) !== -1) {
    return gateRefuse('ANNOUNCEMENT_HTML_COMMENT',
      'The Announcement block holds an HTML comment. GitHub hides a comment on the pull request '
      + 'page, but the block is drafted to Slack as written, so agents would be shown it. Delete the '
      + 'comment from the block.');
  }
  const first = text.split('\n')[0];
  if (first !== ANNOUNCEMENT_OPENER) {
    return gateRefuse('ANNOUNCEMENT_NO_OPENER',
      'The Announcement does not open with ' + ANNOUNCEMENT_OPENER + ' on a line of its own: its first line is "'
      + first + '". The post is drafted exactly as written and nothing is added to it afterwards, so '
      + 'without that line agents are not notified. Put ' + ANNOUNCEMENT_OPENER + ', typed plainly, alone '
      + 'on the first line under the heading.');
  }
  const found = [];
  text.split('\n').forEach(function (line) {
    UNMEASURED_MARKDOWN.forEach(function (rule) {
      if (found.indexOf(rule.name) === -1 && rule.test(line)) found.push(rule.name);
    });
  });
  if (found.length) {
    return gateRefuse('ANNOUNCEMENT_MARKDOWN',
      'The Announcement uses formatting that was never measured to arrive in Slack: ' + found.join('; ')
      + '. What a sent post was seen to keep is bold, italics, dot and dash bullets, a numbered list, '
      + 'a bare link and a labelled link. Rewrite it with those.');
  }
  const dashed = dashLine(text);
  if (dashed !== null) {
    return gateRefuse('ANNOUNCEMENT_DASHES',
      'The Announcement uses a dash as punctuation in this line: "' + dashed + '". The post goes out in '
      + 'Dan\'s name, and his writing has none: no long dash, no two hyphens together, and no hyphen '
      + 'standing alone between words. A hyphen that starts a line as a bullet, or sits inside a word, '
      + 'is fine. Use a comma, a colon or a new sentence.');
  }
  return null;
}

// What the MERGE GATE refuses, beyond what parseEntry refuses on every Mac (the head of this file).
// Called by hooks/require-changelog-tag.sh and by nothing else: `entry` is parseEntry's answer for
// the pull request, `body` its description, `scope` what repoScope said about its repository.
// Returns null when the merge may go ahead, or { code, reason }.
function gateRefusal(entry, body, scope) {
  const valid = kindsValidFor(scope);
  const announces = valid.indexOf(ANNOUNCE) !== -1;
  const labelKind = entry && (entry.ok === true ? entry.kind : entry.labelKind);

  // The label is not in use here. Said before anything about the writing under it, so nobody is
  // told to finish a post for a label this repository refuses.
  if (labelKind === ANNOUNCE && !announces) {
    return gateRefuse('ANNOUNCE_NOT_HERE',
      'This pull request is labelled ' + LABEL_PREFIX + ANNOUNCE + ', and the entry for '
      + ((scope && (scope.repo || scope.name)) || 'this repository') + ' in this Mac\'s dev update registry names '
      + 'no announcements channel (announceChannel), so there is nowhere to draft its post and the label '
      + 'is not in use here. An entry that lost its announceChannel key looks exactly the same as one '
      + 'that never had it, so check which this is with: ' + howToCheckChannel(scope) + '. If this '
      + 'repository does not announce, use one of: ' + labelList(valid) + '.');
  }

  if (!entry || entry.ok !== true) {
    if (!entry || entry.code === 'NO_LABEL') return gateRefuse('NO_LABEL', noLabelReason(valid));
    if (entry.code === 'UNKNOWN_KIND') return gateRefuse(entry.code, unknownKindReason(entry.labelKind, valid));
    return gateRefuse(entry.code, entry.reason);
  }

  if (entry.kind === ANNOUNCE) return announcementRefusal(entry.announcement);

  // Any other label over an Announcement block: a post somebody wrote that nothing will ever draft.
  const stray = extractAnnouncement(body);
  if (stray !== null && stray !== '' && !SAYS_NOTHING.test(stray)) {
    return gateRefuse('ANNOUNCEMENT_WITHOUT_LABEL',
      'This pull request is labelled ' + LABEL_PREFIX + entry.kind + ' and its body carries an Announcement '
      + 'block, which only ' + LABEL_PREFIX + ANNOUNCE + ' uses, so that post would be written and never '
      + 'drafted for agents. '
      + (announces
        ? 'Either relabel it ' + LABEL_PREFIX + ANNOUNCE + ' so the post is used, or delete the block.'
        : 'This repository\'s registry entry names no announcements channel (announceChannel), so '
          + 'that label is not in use here: delete the block.'));
  }
  return null;
}

// Is this repo gated, and from when?
//
// A repo opts in by being listed in the /pennie-dev-update registry (each Mac's own repos.local.json, claude-config#1526)
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
      why: 'the /pennie-dev-update registry could not be read, so whether this repo is gated is unknown',
    };
  }
  const want = String(slug || '').trim().toLowerCase();
  if (!want) return { inScope: false, why: 'no repo slug could be resolved for this merge' };

  const found = registry.repos.filter(function (r) {
    return r && String(r.repo || '').trim().toLowerCase() === want;
  })[0];

  if (!found) {
    return { inScope: false, why: slug + ' is not listed in the /pennie-dev-update registry' };
  }
  if (!found.changelogFrom) {
    // Listed with no start date is an UNFINISHED SETUP, not an opt out. Standing down here was a
    // bare exit 0, indistinguishable from a working gate on a repo whose start date has not
    // arrived (L98). The PET entry lost this field twice on 2026-08-31 to sessions that
    // regenerated the registry instead of read-modify-writing it, and nothing reported either loss.
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

  // Whether this repository announces, and where (claude-config#3665): the entry's own
  // announceChannel, judged by the registry's one reader of that key. `announceChannel` is the id,
  // or '' when the entry names none, which is the ordinary case and means the announce label is
  // refused here. One present that is not a channel id is `badAnnounce`: a config error the gate
  // refuses on, as it does on a start date that is not a date, because reading a typo as "names
  // none" would switch the label off in the one repository that uses it and say nothing (L98).
  const scope = { inScope: true, from: from, name: found.name || slug, repo: String(found.repo).trim(), announceChannel: '' };
  const announce = registryReader.announceChannelOf(found);
  if (announce.bad) {
    scope.badAnnounce = true;
    scope.why = registryReader.badAnnounceWhy(scope.repo, announce.value);
  } else {
    scope.announceChannel = announce.channel;
  }
  return scope;
}

// Which label does this gate require on a pull request of this repository?
//
// Asked by sleep mode (mods/scope-modes/hooks/requiredlabel.ts, claude-config#3439). Overnight a
// session may set no label on a pull request, with one exception: the label this gate will refuse
// the merge without, on a pull request that session opened. On 2026-11-21 that ban had no exception,
// so a pull request opened overnight in a gated repository could not carry its label, and it sat
// green and unmerged for ten and a half hours. Which labels those are is answered HERE, from KINDS
// and parseEntry, so the mod holds no second list of them to drift from this one.
//
// `read` is what dev-update-registry.js's readRegistry returned. Three answers, kept apart as the
// gate keeps them apart (L11, L98):
//   required      the repository is gated today. `labels` is every label the gate takes, each with
//                 `needsSentence`: whether the gate refuses it on a pull request whose description
//                 carries no Changelog block. That is asked of parseEntry itself, never restated.
//   not-required  somebody chose not to gate it: not listed, or its start date has not arrived.
//   unknown       it cannot be told: the registry is missing or unreadable, the repository is listed
//                 with no start date or one that is not a date, its announcements channel is not a
//                 channel id, or no repository was named. The merge gate refuses or cannot judge a
//                 merge there, so nothing is promised about it.
//
// The labels are the ones in use in THAT repository (kindsValidFor), so the announce label is listed
// only where the entry names an announcements channel. And a label whose wording is Dan's to approve
// (`needsDan`) is listed only to a caller that says it understands that field, with
// `options.needsDan`: a session still running the mod as it was before the announce label would
// otherwise be handed a label it would let a session set overnight with nothing said. Such a caller
// gets the answer it has always had, in the shape it has always had. One that passes the option
// gets, on every label, `needsAnnouncement` (the gate refuses it on a description carrying the
// sentence and no post for agents, again asked of parseEntry) and `needsDan`.
function requiredLabels(read, slug, today, options) {
  if (!read || read.state !== 'ok') {
    return { state: 'unknown', why: (read && read.why) || 'the dev update registry could not be read', labels: [] };
  }
  if (!String(slug || '').trim()) {
    return { state: 'unknown', why: 'no repository was named, so whether it is gated cannot be told', labels: [] };
  }
  const understandsDan = !!(options && options.needsDan);
  const scope = repoScope(read.registry, slug, today);
  if (scope.inScope && scope.badAnnounce) return { state: 'unknown', why: scope.why, labels: [] };
  if (scope.inScope) {
    return {
      state: 'required',
      why: '',
      labels: kindsValidFor(scope)
        .filter(function (kind) { return understandsDan || !factOf(NEEDS_DAN, kind); })
        .map(function (kind) {
          const label = LABEL_PREFIX + kind;
          const one = { label: label, needsSentence: !parseEntry({ labels: [label], body: '' }).ok };
          if (understandsDan) {
            one.needsAnnouncement = parseEntry({ labels: [label], body: '## Changelog\nA sentence.' }).code === 'NO_ANNOUNCEMENT';
            one.needsDan = factOf(NEEDS_DAN, kind);
          }
          return one;
        }),
    };
  }
  if (scope.unreadable || scope.missingFrom || scope.badDate) {
    return { state: 'unknown', why: scope.why, labels: [] };
  }
  return { state: 'not-required', why: scope.why, labels: [] };
}

// What a merged pull request owes agents, for the reader that drafts it once the change is live
// (claude-config#3665). `pr` is the pull request as GitHub gives it ({labels, body}), `read` what
// dev-update-registry.js's readRegistry returned. Three answers, kept apart (L11, L98):
//   owed     it is an announce record and its repository names a channel: `channel`, and `text`, the
//            post exactly as written, with `normalized`, the one form to hash and compare it by.
//   none     it carries no announce label, so nothing is owed and nothing is ever asked about it.
//   unknown  it is labelled announce and something cannot be told: the record does not read, the
//            registry does not, or the repository names no channel on this Mac. `why` says which,
//            and `text` is still given wherever the post could be read, so the reader keeps the
//            change as owed with its reason instead of dropping it.
function announcementOwed(pr, read, slug, today) {
  const answer = function (state, why, channel, text) {
    return { state: state, channel: channel || '', text: text || '', normalized: normalizeAnnouncement(text || ''), why: why || '' };
  };
  if (!pr || typeof pr !== 'object' || Array.isArray(pr)) {
    return answer('unknown', 'the pull request on standard input could not be read as JSON holding its labels and body, so whether it owes an announcement cannot be told');
  }
  if (!carriesAnnounce(pr.labels)) return answer('none', '');
  const entry = parseEntry({ labels: pr.labels, body: pr.body });
  if (!entry.ok) return answer('unknown', entry.reason);
  if (!read || read.state !== 'ok') return answer('unknown', (read && read.why) || 'the dev update registry could not be read', '', entry.announcement);
  const scope = repoScope(read.registry, slug, today);
  if (!scope.inScope || scope.badAnnounce) return answer('unknown', scope.why, '', entry.announcement);
  if (!scope.announceChannel) {
    return answer('unknown', 'the entry for ' + scope.repo + ' in this Mac\'s dev update registry names no announcements channel '
      + '(announceChannel), so there is nowhere to draft this post. The merge gate refuses the label there, so '
      + 'either the change merged on another Mac whose registry names one, or this entry lost its key', '', entry.announcement);
  }
  return answer('owed', '', scope.announceChannel, entry.announcement);
}

module.exports = {
  parseEntry: parseEntry,
  gateRefusal: gateRefusal,
  extractBlock: extractBlock,
  extractAnnouncement: extractAnnouncement,
  normalizeAnnouncement: normalizeAnnouncement,
  announcementHash: announcementHash,
  changelogLabels: changelogLabels,
  carriesAnnounce: carriesAnnounce,
  repoScope: repoScope,
  requiredLabels: requiredLabels,
  announcementOwed: announcementOwed,
  isManagerVisible: isManagerVisible,
  // The /pennie-dev-update gatherer asks which local day a merge fell on with this same helper, so
  // its "on or after changelogFrom" agrees with what this gate decided at merge time.
  localDay: localDay,
  LABEL_PREFIX: LABEL_PREFIX,
  KINDS: KINDS,
  KIND_FACTS: KIND_FACTS,
  VISIBLE: VISIBLE,
  TECHNICAL: TECHNICAL,
  NONE: NONE,
  ANNOUNCE: ANNOUNCE,
  ANNOUNCEMENT_OPENER: ANNOUNCEMENT_OPENER,
};

// The command lines, for the mods, which cannot load this file (claude-config#3439, #3665).
//   required-labels <owner/name> [file] [--needs-dan]
//       prints requiredLabels' answer for that repository as JSON, read from this Mac's registry, or
//       from `file` for the tests. --needs-dan is how a caller says it understands a label's
//       `needsDan`; without it the answer is the one every caller had before the announce label.
//   announcement <owner/name> [file]
//       reads one pull request as JSON on standard input ({labels, body}, as gh or the API gives it)
//       and prints announcementOwed's answer: {state: owed | none | unknown, channel, text,
//       normalized, why}.
//   announcement-hash [--body]
//       reads wording on standard input and prints {found, hash, lines}: announcementHash's answer and
//       how many lines the normalised wording has. Without the flag the input IS the wording (the
//       file Dan was shown). With --body it is a pull request description, hashed by the block under
//       its Announcement heading, and `found` is false, with no hash, when it has no such heading.
// Every answer either can give exits 0, "unknown" included, so the reader tells a gate that cannot
// tell from a command that failed. A call naming no repository where one is needed, a flag nobody
// defined, or any other command, prints the usage and exits 2.
if (require.main === module) {
  const cmd = process.argv[2];
  const rest = process.argv.slice(3);
  const flags = rest.filter(function (a) { return a.indexOf('--') === 0; });
  const plain = rest.filter(function (a) { return a.indexOf('--') !== 0; });
  const slug = plain[0];
  const named = typeof slug === 'string' && slug.trim();
  // Asked of the table's own names only: a command named `constructor` would otherwise find what
  // every object inherits, and the line below would throw where the usage is owed.
  const flagTable = { 'required-labels': ['--needs-dan'], 'announcement-hash': ['--body'] };
  const known = Object.prototype.hasOwnProperty.call(flagTable, cmd) ? flagTable[cmd] : [];
  const flagsKnown = flags.every(function (f) { return known.indexOf(f) !== -1; });
  const readNow = function () { return registryReader.readRegistry(plain[1] || registryReader.registryPath()); };
  // Standard input, whole, handed to `then` as text.
  const withInput = function (then) {
    let raw = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', function (d) { raw += d; });
    process.stdin.on('end', function () { then(raw); });
  };
  if (cmd === 'required-labels' && named && flagsKnown) {
    process.stdout.write(JSON.stringify(requiredLabels(readNow(), slug, undefined, { needsDan: flags.indexOf('--needs-dan') !== -1 })) + '\n');
  } else if (cmd === 'announcement' && named && flagsKnown) {
    withInput(function (raw) {
      let pr = null;
      try { pr = JSON.parse(raw); } catch (e) { pr = null; }
      process.stdout.write(JSON.stringify(announcementOwed(pr, readNow(), slug)) + '\n');
    });
  } else if (cmd === 'announcement-hash' && flagsKnown && plain.length === 0) {
    withInput(function (raw) {
      const text = flags.indexOf('--body') !== -1 ? extractAnnouncement(raw) : raw;
      const normal = normalizeAnnouncement(text);
      process.stdout.write(JSON.stringify({ found: text !== null, hash: announcementHash(text), lines: normal ? normal.split('\n').length : 0 }) + '\n');
    });
  } else {
    // One line, since a reader of a failed run quotes the last line it printed.
    process.stderr.write('Usage: changelog-entry.js required-labels <owner/name> [registry file] [--needs-dan] | '
      + 'announcement <owner/name> [registry file], with the pull request as JSON on standard input | '
      + 'announcement-hash [--body], with the wording, or with --body a description, on standard input\n');
    process.exit(2);
  }
}
