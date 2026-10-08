#!/usr/bin/env node
'use strict';
//
// lint-post.js: the /pennie-dev-update post's format rules, as a check rather than prose
// (claude-config#680). Every rule here is one Dan corrected by hand in a draft (SKILL.md section
// 6), and a rule that lives only in a prompt is a hope (L27).
//
//   lint-post.js <draft file>
//
// Prints one line per finding, "line N: ...", and exits 0 when nothing is refused, 1 when
// something is, 2 when the draft cannot be read. A warning (a hyphenated word, which is allowed
// only as the literal name of something on screen) is printed but refuses nothing.
//
// The characters it refuses are built from their code points, so this file holds none of them.

const fs = require('fs');

const ch = function (code) { return String.fromCodePoint(code); };
const DASHES = [0x2012, 0x2013, 0x2014, 0x2015].map(ch).join('');
const BULLETS = [0x2022, 0x2023, 0x2043, 0x2219, 0x25AA, 0x25CF, 0x25E6, 0x00B7].map(ch).join('');

const DASH_CHAR = new RegExp('[' + DASHES + ']');
const DASH_CONNECTOR = /(^|\s)-{1,2}(\s|$)/;
const ITEM_PREFIX = new RegExp('^\\s*(?:[-*+' + BULLETS + ']|\\d+[.)])\\s+');
const BOLD = /\*\*[^*\n]+\*\*|__[^_\n]+__|(^|[^\w*])\*(?=\S)[^*\n]*?\S?\*(?![\w*])/;
const EMOJI = /\p{Extended_Pictographic}/u;
const SHORTCODE = /:(?=[a-z0-9_+-]*[a-z])[a-z0-9_+-]+:/gi;
const HYPHENATED = /\b[A-Za-z]+(?:-[A-Za-z]+)+\b/g;
const OPENER = /^Updates for .+ :thread:$/;
const THREAD = ':thread:';

function outsideParens(s) { return s.replace(/\([^)]*\)/g, ''); }
function isUppercaseLine(s) {
  const bare = outsideParens(s).replace(/[*_]/g, '');
  return /[A-Z].*[A-Z]/.test(bare) && !/[a-z]/.test(bare);
}

function lint(text) {
  const lines = text.split(/\r?\n/);
  const refusals = [];
  const warnings = [];
  const say = function (list, n, msg) { list.push({ n: n, msg: msg }); };

  // Blocks of consecutive non-blank lines, each line keeping its 1-based number.
  const blocks = [];
  let cur = null;
  lines.forEach(function (raw, i) {
    if (raw.trim() === '') { cur = null; return; }
    if (!cur) { cur = []; blocks.push(cur); }
    cur.push({ n: i + 1, text: raw });
  });

  if (blocks.length === 0) { say(refusals, 1, 'the draft is empty'); return { refusals: refusals, warnings: warnings }; }

  // Line by line rules, everywhere.
  lines.forEach(function (raw, i) {
    const n = i + 1;
    if (raw.trim() === '') return;
    if (DASH_CHAR.test(raw)) say(refusals, n, 'an em or en dash; use a comma, colon, parentheses or a new sentence');
    else if (DASH_CONNECTOR.test(raw) && !ITEM_PREFIX.test(raw)) say(refusals, n, 'a dash used as a connector; use a comma, colon, parentheses or a new sentence');
    if (ITEM_PREFIX.test(raw)) say(refusals, n, 'an item prefix; items carry no prefix at all, each is its own line under its heading');
    if (BOLD.test(raw)) say(refusals, n, 'bold markers; there is no bold anywhere in the post');
    if (EMOJI.test(raw)) say(refusals, n, 'an emoji; the post carries none');
    const codes = (raw.match(SHORTCODE) || []).filter(function (c) { return !(n === blocks[0][0].n && c === THREAD); });
    if (codes.length) say(refusals, n, 'an emoji shortcode (' + codes.join(' ') + '); only the opener carries ' + THREAD);
    const hyph = raw.match(HYPHENATED);
    if (hyph) say(warnings, n, 'warning: hyphenated ' + hyph.join(', ') + '; keep it only if it is the literal name of something on screen, otherwise write it as separate words');
  });

  // The opener (Dan, 2026-09-28): "Updates for <period> :thread:", an optional launch line, and no
  // line saying some items are backend only.
  const opener = blocks[0];
  if (!OPENER.test(opener[0].text.trim())) {
    say(refusals, opener[0].n, 'the opener must read "Updates for <period> ' + THREAD + '" (Dan, 2026-09-28)');
  }
  opener.forEach(function (l) {
    if (/backend only/i.test(l.text)) say(refusals, l.n, 'the "backend only" line was removed on 2026-09-28; delete it');
  });

  // Headings. A post with any bare uppercase heading is sectioned, and then every block after the
  // opener starts with one. A post with none is a flat list, under about five items, and has no
  // headings to judge (its first item would otherwise be read as one).
  const body = blocks.slice(1);
  const sectioned = body.some(function (b) { return isUppercaseLine(b[0].text); });
  if (sectioned) {
    let afterLoneHeading = false;
    body.forEach(function (b) {
      const h = b[0];
      if (afterLoneHeading) { afterLoneHeading = false; return; }
      const t = h.text.trim();
      if (!isUppercaseLine(t)) say(refusals, h.n, 'a heading must be bare uppercase (' + JSON.stringify(t) + ')');
      if (/:\s*$/.test(t)) say(refusals, h.n, 'a heading ends in a colon; headings are bare');
      if (b.length === 1) {
        say(refusals, h.n, 'a heading with no item on the next line; the first item goes directly under it');
        afterLoneHeading = true;
      }
    });
  }
  refusals.sort(function (a, b) { return a.n - b.n; });
  return { refusals: refusals, warnings: warnings };
}

function main(argv) {
  const file = argv[0];
  if (!file) { process.stderr.write('Usage: lint-post.js <draft file>\n'); return 2; }
  let text;
  try { text = fs.readFileSync(file, 'utf8'); }
  catch (e) { process.stderr.write('The draft at ' + file + ' could not be read (' + e.code + ').\n'); return 2; }
  const r = lint(text);
  r.refusals.concat(r.warnings).sort(function (a, b) { return a.n - b.n; })
    .forEach(function (f) { process.stdout.write('line ' + f.n + ': ' + f.msg + '\n'); });
  if (r.refusals.length) {
    process.stdout.write(r.refusals.length + ' finding(s) to fix before Dan sees the draft.\n');
    return 1;
  }
  process.stdout.write('The draft follows the post format' + (r.warnings.length ? ', with ' + r.warnings.length + ' warning(s) to confirm.' : '.') + '\n');
  return 0;
}

module.exports = { lint: lint };
if (require.main === module) process.exitCode = main(process.argv.slice(2));
