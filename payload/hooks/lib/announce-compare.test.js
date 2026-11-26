'use strict';
// Cases for announce-compare.js's judgement of a Slack draft of an announcement (claude-config#3667).
// The "found posted" half of that file keeps its cases in the dev update skill's suite
// (skills/pennie-dev-update/tests/scripts.test.js), which is where its command line lives.
//
// Run by test-announce-compare.sh, which passes on the tally printed at the end.

const path = require('path');
const childProcess = require('child_process');
const LIB = path.join(__dirname, 'announce-compare.js');
const compare = require(LIB);

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
  check(j.state === 'differs', 'a draft with words put before the approved wording is judged saved', JSON.stringify(j));

  // No draft_id: Slack kept nothing, whatever its words say, and the wording is not even compared.
  j = judge({ text: POST, message: POST, answer: NOT_KEPT });
  check(j.state === 'not-kept' && /draft_id/.test(j.why) && /already waiting/.test(j.why), 'an answer holding no draft_id is not judged as nothing kept', JSON.stringify(j));
  j = judge({ text: POST, message: 'something else', answer: NOT_KEPT });
  check(j.state === 'not-kept', 'an answer holding no draft_id is judged by the wording', JSON.stringify(j));
  ['{"result":"Draft created","draft_id":null}', '{"result":"Draft created","draft_id":""}', 'Draft created'].forEach(function (text) {
    const k = judge({ text: POST, message: POST, answer: { text: text } });
    check(k.state === 'not-kept', 'an answer with an empty or null draft_id is judged kept (' + text + ')', JSON.stringify(k));
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
  check(j.state === 'error' && j.error === 'not_in_channel', 'an answer naming an error beside a draft_id is judged saved', JSON.stringify(j));
  j = judge({ text: POST, message: POST, answer: { text: 'Something went wrong', isError: true } });
  check(j.state === 'error' && j.error === '' && /Something went wrong/.test(j.why), 'an answer marked as an error that names none is not judged an error, quoting it', JSON.stringify(j));
  j = judge({ text: POST, message: POST, answer: { text: '{"ok":false}' } });
  check(j.state === 'error', 'an answer saying ok false is judged saved', JSON.stringify(j));

  // What cannot be judged is refused, never judged saved (L98): no wording, no draft text, no answer.
  [{ message: POST, answer: KEPT }, { text: '   ', message: POST, answer: KEPT }, { text: '**', message: POST, answer: KEPT },
    { text: POST, answer: KEPT }, { text: POST, message: POST }, { text: POST, message: POST, answer: {} }, null, 'x'].forEach(function (input) {
    let threw = '';
    try { judge(input); } catch (e) { threw = e.message; }
    check(threw !== '', 'an input that cannot be judged was judged', JSON.stringify(input));
  });
}

// The command line the is it live mod and the dev update both ask: `draft`, the input as JSON on
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

console.log('  ' + passed + ' passed, ' + failed + ' failed');
console.log('SUITE-RESULT passed=' + passed + ' failed=' + failed);
process.exit(failed === 0 ? 0 : 1);
