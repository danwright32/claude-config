#!/usr/bin/env node
'use strict';
//
// lint-post.js: the /pennie-dev-update post's format rules, as a check rather than prose
// (claude-config#680). Every rule here is one Dan corrected by hand in a draft (SKILL.md section
// 6), and a rule that lives only in a prompt is a hope (L27).
//
//   lint-post.js [--config <repos.json>] <draft file>
//
// The config names the products and their order (default: the repos.json beside this file). A post
// with sections for two or more of them must open with the product line, and keep their order.
//
// Prints one line per finding, "line N: ...", and exits 0 when nothing is refused, 1 when
// something is, 2 when the draft cannot be read. A warning (a hyphenated word, which is allowed
// only as the literal name of something on screen) is printed but refuses nothing.
//
// The characters it refuses are built from their code points, so this file holds none of them.

const fs = require('fs');
const path = require('path');

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
const PING = /@(channel|here|everyone)\b/i;
const OPENER = /^Updates for .+ :thread:$/;
const THREAD = ':thread:';

function outsideParens(s) { return s.replace(/\([^)]*\)/g, ''); }
function isUppercaseLine(s) {
  const bare = outsideParens(s).replace(/[*_]/g, '');
  return /[A-Z].*[A-Z]/.test(bare) && !/[a-z]/.test(bare);
}

// A line made only of product names joined by "|" is a product line, a lone name included.
function isProductLine(text, products) {
  const parts = text.split('|').map(function (p) { return p.trim(); });
  return parts.every(function (p) { return products.indexOf(p) !== -1; });
}

function lint(text, products) {
  products = products || [];
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

  // A product heading is a product's name in uppercase with something under it. In Dan's layout
  // (2026-10-13) the first one sits straight under the opener with no blank line, so it starts
  // inside the opener's block and is split off here into the body it begins.
  const byHeading = new Map(products.map(function (p) { return [p.toUpperCase(), p]; }));
  const isProductHead = function (l) {
    const next = lines[l.n];
    return byHeading.has(l.text.trim()) && next !== undefined && next.trim() !== '';
  };
  let firstHeadInOpener = false;
  if (blocks.length) {
    const k = blocks[0].findIndex(function (l, i) { return i > 0 && isProductHead(l); });
    if (k > 0) { blocks.splice(0, 1, blocks[0].slice(0, k), blocks[0].slice(k)); firstHeadInOpener = true; }
  }

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
    if (PING.test(raw)) say(refusals, n, 'a bare @channel, @here or @everyone pings the whole channel when pasted; write it with a space, "@ channel"');
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
  // The product line (Dan, 2026-10-13): "Updates for <period> :thread:", then the products this
  // post covers joined with " | ", in the order repos.json lists them, which is also the order of
  // their sections. A product with nothing to report has no section and is left off. A one product
  // post has no product heading, so it carries no product line either.
  const sections = body.filter(function (b) { return isProductHead(b[0]); })
    .map(function (b) { return { name: byHeading.get(b[0].text.trim()), n: b[0].n }; });
  const inOrder = sections.slice().sort(function (a, b) { return products.indexOf(a.name) - products.indexOf(b.name); });
  const misplaced = sections.find(function (s, i) { return s.name !== inOrder[i].name; });
  if (misplaced) {
    say(refusals, misplaced.n, 'product sections go in the repos.json order (' + products.join(', ') + ')');
  }
  const expected = inOrder.map(function (s) { return s.name; }).join(' | ');
  if (inOrder.length >= 2) {
    if (!firstHeadInOpener) say(refusals, sections[0].n, 'the first product\'s heading goes on the line straight after the opener, with no blank line between');
    sections.slice(1).forEach(function (s) {
      let blank = 0;
      while (s.n - 2 - blank >= 0 && lines[s.n - 2 - blank].trim() === '') blank++;
      if (blank !== 2) say(refusals, s.n, 'two blank lines go before each product after the first (found ' + blank + ')');
    });
    const second = opener[1];
    if (!second) say(refusals, opener[0].n, 'a post covering more than one product needs the product line "' + expected + '" on the line after the opener');
    else if (second.text.trim() !== expected) say(refusals, second.n, 'the line after the opener must be the product line "' + expected + '"');
  } else {
    opener.slice(1).forEach(function (l) {
      if (isProductLine(l.text, products)) say(refusals, l.n, 'a post covering one product carries no product line; delete it');
    });
  }

  refusals.sort(function (a, b) { return a.n - b.n; });
  return { refusals: refusals, warnings: warnings };
}

function main(argv) {
  let configPath = path.join(__dirname, 'repos.json');
  if (argv[0] === '--config') { configPath = argv[1]; argv = argv.slice(2); }
  const file = argv[0];
  if (!file || !configPath) { process.stderr.write('Usage: lint-post.js [--config <repos.json>] <draft file>\n'); return 2; }
  // An unreadable config is refused, never read as a world with no products, which would pass a
  // multi product post with no product line at all (L98).
  let products;
  try {
    const cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    products = cfg.repos.map(function (r) { return r.name; });
    if (!products.every(function (n) { return typeof n === 'string' && n; })) throw new Error('a repo has no name');
  } catch (e) {
    process.stderr.write('The product list in repos.json at ' + configPath + ' could not be read (' + (e.code || e.message) + ').\n');
    return 2;
  }
  let text;
  try { text = fs.readFileSync(file, 'utf8'); }
  catch (e) { process.stderr.write('The draft at ' + file + ' could not be read (' + e.code + ').\n'); return 2; }
  const r = lint(text, products);
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
