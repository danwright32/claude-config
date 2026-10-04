import { describe, expect, test } from 'claude-code/testing'
import { isDans, triggersIn } from '../hooks/triggers.ts'

// Each phrase the specs name (#616, #621), and the ones mined from Dan's chats that they quote.
describe('triggersIn', () => {
  const cases: [string, ReturnType<typeof triggersIn>][] = [
    ['pause after this issue', [{ kind: 'scope', scope: 'WINDING DOWN' }]],
    ["Pause after the issue you're working on. Make sure it's merged and everything is finalized/cleaned up.", [{ kind: 'scope', scope: 'WINDING DOWN' }]],
    ['ok, wind down now', [{ kind: 'scope', scope: 'WINDING DOWN' }]],
    ['no coding yet just research', [{ kind: 'scope', scope: 'NO BUILD' }]],
    ['read only for now please', [{ kind: 'scope', scope: 'NO BUILD' }]],
    ['stay read-only', [{ kind: 'scope', scope: 'NO BUILD' }]],
    ["just file, don't build", [{ kind: 'scope', scope: 'NO BUILD' }]],
    ['just file don’t build', [{ kind: 'scope', scope: 'NO BUILD' }]],
    ["don't start git yet", [{ kind: 'scope', scope: 'NO BUILD' }]],
    ['wind down after this one', [{ kind: 'scope', scope: 'WINDING DOWN' }]],
    ["let's wind down", [{ kind: 'scope', scope: 'WINDING DOWN' }]],
    ["let's wind down for today", [{ kind: 'scope', scope: 'WINDING DOWN' }]],
    ['wind down', [{ kind: 'scope', scope: 'WINDING DOWN' }]],
    ['keep it read only', [{ kind: 'scope', scope: 'NO BUILD' }]],
    ['read only mode please', [{ kind: 'scope', scope: 'NO BUILD' }]],
    ['Looks good. Stay read only until I say.', [{ kind: 'scope', scope: 'NO BUILD' }]],
    ['go ahead and build', [{ kind: 'build' }]],
    ['Looks right. Go ahead and build it.', [{ kind: 'build' }]],
    ["I'm stepping away for an hour", [{ kind: 'place', place: 'away' }]],
    ['stepping away from the desk', [{ kind: 'place', place: 'away' }]],
    ['away', [{ kind: 'place', place: 'away' }]],
    ['Away.', [{ kind: 'place', place: 'away' }]],
    ["I'm back at my computer, so you can stop doing artifacts", [{ kind: 'place', place: 'home' }]],
    ['back at my desk now', [{ kind: 'place', place: 'home' }]],
  ]
  for (const [text, want] of cases) test(JSON.stringify(text), () => expect(triggersIn(text)).toEqual(want))

  test('ordinary sentences that share a word turn nothing on', () => {
    for (const t of ['build the invoice page', 'the away team won', 'is this file read by anything?', 'take it home', 'pause the video',
      // Decided with Dan (2026-10-04, picker): only phrasings aimed at Claude switch a mode, never
      // the words used in passing.
      'make this column read only', 'use a read-only Supabase connection', 'the project is winding down',
      'the wind down the hall', 'is the read only query safe?',
      'this column should be read only', 'the file will be read only by the loader',
      'please wind down the staging cluster', "let's wind down the Redis instance",
      'the database is in read only mode', 'make this column read only for now',
      'keep it read only in the form', 'keep things read only for admins'])
      expect(triggersIn(t)).toEqual([])
  })
  test('one mode named twice in a message comes back once', () => {
    expect(triggersIn("let's wind down now")).toEqual([{ kind: 'scope', scope: 'WINDING DOWN' }])
  })
  test('two in one message come back in the order they were written', () => {
    expect(triggersIn("I'm stepping away, pause after this issue")).toEqual([
      { kind: 'place', place: 'away' },
      { kind: 'scope', scope: 'WINDING DOWN' },
    ])
  })
})

describe('isDans', () => {
  test("Dan's own Enter and his phone count; a peer, a plugin or a notification never turns a mode on", () => {
    expect(isDans({ kind: 'composer' })).toBe(true)
    expect(isDans({ kind: 'bridge' })).toBe(true)
    for (const kind of ['peer', 'peer-send-message', 'task-notification', 'scheduled-trigger', 'unclassified', 'sdk'])
      expect(isDans({ kind } as never)).toBe(false)
    expect(isDans({ kind: 'plugin', name: 'x', asUser: true })).toBe(false)
  })
})
