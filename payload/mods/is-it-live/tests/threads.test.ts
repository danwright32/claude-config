import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { draftSaved, isSlackTool, threadGone, threadsIn } from '../hooks/threads.ts'

// #2436: the Slack thread a session starts from, read from a link Dan pastes, and what counts as a
// draft reply saved to it.

test('a pasted thread link gives its channel and the parent message time (#2436)', () => {
  expect(threadsIn('see https://acme.slack.com/archives/C07ABCDEF/p1730912345123456 please')).toEqual([
    { channel: 'C07ABCDEF', ts: '1730912345.123456', link: 'https://acme.slack.com/archives/C07ABCDEF/p1730912345123456' },
  ])
})

test("a link to a reply in a thread names the thread's parent, from its thread_ts (#2436)", () => {
  const link = 'https://acme.slack.com/archives/C07ABCDEF/p1730912399000200?thread_ts=1730912345.123456&cid=C07ABCDEF'
  expect(threadsIn(`<${link}|the thread>`)).toEqual([{ channel: 'C07ABCDEF', ts: '1730912345.123456', link }])
})

test('the same thread twice is one thread, and a channel link or another site is none (#2436)', () => {
  const link = 'https://acme.slack.com/archives/C07ABCDEF/p1730912345123456'
  expect(threadsIn(`${link} and again ${link}`)).toHaveLength(1)
  expect(threadsIn('https://acme.slack.com/archives/C07ABCDEF')).toEqual([])
  expect(threadsIn('https://example.com/archives/C07ABCDEF/p1730912345123456')).toEqual([])
})

test("a Slack tool is named by its own name under any server, never by a name that only ends like it (#2436)", () => {
  expect(isSlackTool('mcp__claude_ai_Slack__slack_send_message_draft', 'slack_send_message_draft')).toBe(true)
  expect(isSlackTool('mcp__plugin_slack_slack__slack_send_message_draft', 'slack_send_message_draft')).toBe(true)
  expect(isSlackTool('mcp__claude_ai_Slack__slack_send_message', 'slack_send_message_draft')).toBe(false)
  expect(isSlackTool('slack_send_message_draft', 'slack_send_message_draft')).toBe(false)
})

test('a draft counts as saved only when Slack answered without an error (#2436)', () => {
  expect(draftSaved({ text: '{"channel_link":"https://app.slack.com/client/T1/C1"}' })).toBe(true)
  expect(draftSaved({ text: 'attached_draft_exists', isError: true })).toBe(false)
  expect(draftSaved({ text: '{"ok":false,"error":"not_in_channel"}' })).toBe(false)
  expect(draftSaved({ deny: 'Blocked' })).toBe(false)
})

// #3617: saved is a positive check. Until 2026-11-26 every answer that was not denied, not marked
// an error and named none of Slack's errors counted as saved, so an answer that says nothing about a
// draft at all settled the thread. Slack's draft tool answers a saved draft with channel_link (its
// description says it returns that, "a Slack web client URL"), so only that link counts.
const LINK_AT = 'https://app.slack.com/client/T1/C1'
const SAVED = `{"result":"Draft created","channel_link":"${LINK_AT}"}`

// No call handed to the background has been seen (#3617 counted 0 of 30,155 MCP calls in the 30
// days to 2026-11-25), so these stand in for one, built from the documentation's words: "Claude
// receives the task ID immediately and keeps working, and the result arrives as a task notification
// when the call settles."
test('an answer that only says the call was accepted and gives a task id is no saved draft (#3617)', () => {
  expect(draftSaved({ text: 'The call is still running and moved to a background task. Task ID: mcp-task-7f3a. Its result arrives as a task notification.' })).toBe(false)
  expect(draftSaved({ text: '{"status":"accepted","task_id":"mcp-task-7f3a"}' })).toBe(false)
  expect(draftSaved({ text: '{"taskId":"mcp-task-7f3a","status":"running"}', result: { taskId: 'mcp-task-7f3a', status: 'running' } })).toBe(false)
  expect(draftSaved({ result: { backgroundTaskId: 'b7f3a' }, text: '' })).toBe(false)
  expect(draftSaved({ result: [{ type: 'text', text: 'Running in the background as task mcp-task-7f3a.' }] })).toBe(false)
})

test('an empty answer, or one that cannot be read, is no saved draft (#3617)', () => {
  expect(draftSaved({})).toBe(false)
  expect(draftSaved({ text: '' })).toBe(false)
  expect(draftSaved({ text: '   ' })).toBe(false)
  expect(draftSaved({ result: null })).toBe(false)
  expect(draftSaved({ result: [] })).toBe(false)
  expect(draftSaved({ result: {} })).toBe(false)
  expect(draftSaved({ text: 'null' })).toBe(false)
  expect(draftSaved({ text: '[]' })).toBe(false)
  expect(draftSaved({ text: 'Draft created.' })).toBe(false)
  // Cut off before the link's value ended, so it is not the JSON Slack sent.
  expect(draftSaved({ text: '{"result":"Draft created","channel_link":"https://app.sl' })).toBe(false)
  expect(draftSaved({ text: 42 })).toBe(false)
})

// The forms a Slack answer reaches the hook in. `text` is the result as the model reads it, its text
// blocks joined, and `result` the tool's own record. In the session records of the personal MacBook
// on 2026-11-26 the same Slack server's answers (6 that succeeded) are one text block holding a JSON
// object, or a plain string, in both places. No draft call is on record there at any age, so the
// link's own form is the tool description's and the one every quote of it in those records has.
test('a saved draft carries its link, in each form the answer reaches the hook in (#3617)', () => {
  expect(draftSaved({ text: SAVED })).toBe(true)
  expect(draftSaved({ text: `  ${SAVED}\n` })).toBe(true)
  // Core's own shape: the record beside the text the model reads.
  expect(draftSaved({ ref: 3, text: SAVED, result: [{ type: 'text', text: SAVED }] } as never)).toBe(true)
  // An answer with no text of its own (a hook's): the record alone, as blocks, a string, or an
  // MCP result with its content or its structured content.
  expect(draftSaved({ result: [{ type: 'text', text: SAVED }] })).toBe(true)
  expect(draftSaved({ result: SAVED })).toBe(true)
  expect(draftSaved({ result: { channel_link: LINK_AT } })).toBe(true)
  expect(draftSaved({ result: { content: [{ type: 'text', text: SAVED }], isError: false } })).toBe(true)
  expect(draftSaved({ result: { content: [], structuredContent: { channel_link: LINK_AT } } })).toBe(true)
  // A workspace's own host is a link as well.
  expect(draftSaved({ text: '{"channel_link":"https://acme.slack.com/archives/C1"}' })).toBe(true)
})

test('a denied answer, one marked an error and one naming a Slack error stay unsaved, link or not (#3617)', () => {
  expect(draftSaved({ deny: 'Blocked' })).toBe(false)
  expect(draftSaved({ deny: 'Blocked', text: SAVED })).toBe(false)
  expect(draftSaved({ text: SAVED, isError: true })).toBe(false)
  expect(draftSaved({ text: 'attached_draft_exists: A draft already exists for this channel', isError: true })).toBe(false)
  expect(draftSaved({ text: '{"ok":false,"error":"channel_not_found"}' })).toBe(false)
  expect(draftSaved({ text: `{"ok":false,"error":"failed_to_create_draft","channel_link":"${LINK_AT}"}` })).toBe(false)
  expect(draftSaved({ text: 'failed_to_create_draft' })).toBe(false)
})

test("an answer that only mentions channel_link, with no link as the field's value, is no saved draft (#3617)", () => {
  expect(draftSaved({ text: 'The server answered without channel_link, so the draft may not exist.' })).toBe(false)
  expect(draftSaved({ text: '{"message":"no channel_link in the answer"}' })).toBe(false)
  expect(draftSaved({ text: '{"channel_link":""}' })).toBe(false)
  expect(draftSaved({ text: '{"channel_link":null}' })).toBe(false)
  expect(draftSaved({ text: '{"channel_link":"pending"}' })).toBe(false)
  expect(draftSaved({ text: '{"channel_link":true}' })).toBe(false)
  expect(draftSaved({ text: '{"channel_link":{"href":"https://app.slack.com/client/T1/C1"}}' })).toBe(false)
  // The field's name and a link, quoted inside another field's text, are a mention.
  expect(draftSaved({ text: '{"message":"expected \\"channel_link\\":\\"https://app.slack.com/client/T1/C1\\" and got none"}' })).toBe(false)
  expect(draftSaved({ text: 'No channel_link came back. The tool is described at https://example.com/slack/drafts' })).toBe(false)
})

// #3617: the link is one more thing asked of an answer, so the check can only refuse more. `before`
// is the check as it stood until 2026-11-26, kept here as the yardstick: nothing it called unsaved
// may now count as saved, over every draft answer this mod's suites hand it and the ones above.
test('nothing the check called unsaved before the link was asked for counts as saved now (#3617)', () => {
  const ERRORS = /"ok"\s*:\s*false|\b(?:attached_draft_exists|channel_not_found|not_in_channel|failed_to_create_draft|invalid_thread_ts|thread_not_found)\b/
  type A = { text?: unknown; result?: unknown; isError?: unknown; deny?: unknown }
  const before = (o: A) => o.deny === undefined && o.isError !== true && !ERRORS.test(typeof o.text === 'string' ? o.text : typeof o.result === 'string' ? o.result : JSON.stringify(o.result ?? ''))
  const answers: A[] = [
    // threads.test.ts and register.test.tsx, as they stood.
    { text: '{"channel_link":"https://app.slack.com/client/T1/C1"}' },
    { text: 'attached_draft_exists', isError: true },
    { text: '{"ok":false,"error":"not_in_channel"}' },
    { deny: 'Blocked' },
    { text: '{"ok":false,"error":"invalid_thread_ts"}' },
    { text: 'invalid_thread_ts' },
    { text: 'invalid_thread_ts', isError: true },
    { text: 'attached_draft_exists: A draft already exists for this channel', isError: true },
    { text: '{"ok":false,"error":"attached_draft_exists"}' },
    { text: '{"channel_link":"https://app.slack.com/client/T1/C07ABCDEF"}', result: '{"channel_link":"https://app.slack.com/client/T1/C07ABCDEF"}' },
    // The record alone, where the old check read the record's JSON for Slack's error words.
    { result: [{ type: 'text', text: '{"ok":false,"error":"channel_not_found"}' }] },
    { result: { content: [{ type: 'text', text: 'failed_to_create_draft' }], structuredContent: { channel_link: LINK_AT } } },
    { result: [{ type: 'text', text: SAVED }] },
    { text: SAVED },
    { text: SAVED, isError: true },
    { deny: 'Blocked', text: SAVED },
    { text: 'Task ID: mcp-task-7f3a' },
    {},
  ]
  for (const a of answers) expect(draftSaved(a) && !before(a)).toBe(false)
  // And the two do differ, so the comparison is not of a thing with itself.
  expect(answers.filter(a => before(a)).length).toBeGreaterThan(answers.filter(a => draftSaved(a)).length)
  expect(answers.filter(a => draftSaved(a)).length).toBe(4)
})

// #2787: on 2026-11-11 the post that started a thread had been deleted, so every draft to it answered
// invalid_thread_ts and every read thread_not_found, and the turn end asked again after every turn.
test('Slack saying the thread no longer exists names that error, and is no saved draft (#2787)', () => {
  expect(threadGone({ text: 'invalid_thread_ts', isError: true })).toBe('invalid_thread_ts')
  expect(threadGone({ text: '{"ok":false,"error":"thread_not_found"}' })).toBe('thread_not_found')
  expect(threadGone({ text: 'Error: invalid_thread_ts' })).toBe('invalid_thread_ts')
  expect(draftSaved({ text: '{"ok":false,"error":"invalid_thread_ts"}' })).toBe(false)
  expect(draftSaved({ text: 'invalid_thread_ts' })).toBe(false)
})

test('any other answer, a refused call, or a thread whose messages only mention the error is not a thread gone (#2787)', () => {
  expect(threadGone({ text: 'attached_draft_exists', isError: true })).toBeUndefined()
  expect(threadGone({ text: '{"ok":false,"error":"not_in_channel"}' })).toBeUndefined()
  expect(threadGone({ text: '{"channel_link":"https://app.slack.com/client/T1/C1"}' })).toBeUndefined()
  expect(threadGone({ deny: 'Blocked: invalid_thread_ts' })).toBeUndefined()
  expect(threadGone({ text: '{"messages":[{"text":"the draft failed with thread_not_found again"}]}' })).toBeUndefined()
})
