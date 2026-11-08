import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { draftSaved, isSlackTool, threadsIn } from '../hooks/threads.ts'

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
