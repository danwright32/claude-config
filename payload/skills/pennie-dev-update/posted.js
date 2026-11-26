'use strict';
//
// posted.js: is an announcement for agents already in a channel? (claude-config#3668)
//
// The dev update reads the announcements channel since each announce change merged, and where the
// post is there it says "found posted" and asks Dan nothing. The read and the draft never match as
// text: measured 2026-11-25 (claude-config#3664), a post read back from Slack has *bold* where the
// draft had **bold**, <url|label> where it had [label](url), dot bullets where it had dash bullets,
// blank lines lost, and an opening <!here> where it had @here. So the comparison is of WORDS only:
// markup, link targets, entities, punctuation and spacing all go, and what is left must appear in
// the read, in order and unbroken.
//
// This is the one place that decides it. `gather.js posted` is its command line, and nothing else
// compares a posted announcement with its wording.

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

// Whether every word of the announcement appears in the read, in order and unbroken. `before` is
// what the read held just before the match (its markup taken out), which is where the reading tool
// puts the time a message was posted, so the session can say "found posted at <time>". An
// announcement with no words would be found in anything, so it is refused, never found.
const BEFORE_CHARS = 240;
function foundPosted(announcement, readText) {
  const want = words(announcement);
  if (want.length === 0) throw new Error('the announcement has no words, so it would be found in any read; nothing was compared');
  const read = wordsWithin(readText);
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

module.exports = { words: words, foundPosted: foundPosted };
