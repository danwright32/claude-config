import { describe, expect, test } from 'claude-code/testing'
import { isDans, scopesAskedOffIn, triggersIn } from '../hooks/triggers.ts'

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
    // Turning one mode off by its own name (#805): Dan's words on 2026-10-05 in Slate.
    ['stop winding down mode. run load 1', [{ kind: 'off', scope: 'WINDING DOWN' }]],
    ['ok, stop winding down', [{ kind: 'off', scope: 'WINDING DOWN' }]],
    ['turn winding down off', [{ kind: 'off', scope: 'WINDING DOWN' }]],
    ['turn off wind down mode please', [{ kind: 'off', scope: 'WINDING DOWN' }]],
    ['exit no build mode', [{ kind: 'off', scope: 'NO BUILD' }]],
    ['stop read only, fix the bug', [{ kind: 'off', scope: 'NO BUILD' }]],
    ['switch no build off', [{ kind: 'off', scope: 'NO BUILD' }]],
  ]
  for (const [text, want] of cases) test(JSON.stringify(text), () => expect(triggersIn(text)).toEqual(want))

  test('turning a mode off by name, used in passing or asked, switches nothing (#805)', () => {
    for (const t of ['stop winding down the cluster', 'the job should stop winding down workers',
      'did you stop winding down mode?', 'we never exit no build mode in prod', 'the guide says to turn off read only access'])
      expect(triggersIn(t)).toEqual([])
  })

  test('the scope modes a message asks to end, in words the triggers do not read (#805)', () => {
    expect(scopesAskedOffIn('winding down is done, thanks')).toEqual(['WINDING DOWN'])
    expect(scopesAskedOffIn('no more wind-down please')).toEqual(['WINDING DOWN'])
    expect(scopesAskedOffIn('get out of no build')).toEqual(['NO BUILD'])
    expect(scopesAskedOffIn('read-only is over')).toEqual(['NO BUILD'])
    expect(scopesAskedOffIn('the no build mode is getting in the way')).toEqual(['NO BUILD'])
    expect(scopesAskedOffIn('run load 1')).toEqual([])
    // The name in passing, or asked about, is not a request to end the mode (lessons review of #820).
    for (const t of ['use a read-only connection', "there's no build step in this repo", 'the project is winding down',
      'is winding down over?', 'Ok. Is no build done?'])
      expect(scopesAskedOffIn(t)).toEqual([])
  })

  test('ordinary sentences that share a word turn nothing on', () => {
    for (const t of ['build the invoice page', 'the away team won', 'is this file read by anything?', 'take it home', 'pause the video',
      // Decided with Dan (2026-10-04, picker): only phrasings aimed at Claude switch a mode, never
      // the words used in passing.
      'make this column read only', 'use a read-only Supabase connection', 'the project is winding down',
      'the wind down the hall', 'is the read only query safe?',
      'this column should be read only', 'the file will be read only by the loader',
      'please wind down the staging cluster', "let's wind down the Redis instance",
      'the database is in read only mode', 'make this column read only for now',
      'keep it read only in the form', 'keep things read only for admins',
      'Keep it.', 'Keep it?', 'Ok, stay.', 'Great. Keep things!', 'Read only mode?', 'Read only for now?'])
      expect(triggersIn(t)).toEqual([])
  })
  test('the away, home, no coding and build phrases used in passing switch nothing (#702: the rule from #686 holds for every phrase)', () => {
    for (const t of [
      'add an idle timeout for when the user is stepping away from the form',
      'when the user is back at the desk, refresh the token',
      "there's no coding yet in that repo",
      'once it merges, CI will go ahead and build the image',
      'the queue should pause after the issue is filed',
      'the workers wind down after the job finishes',
      'the guide says to just file, don\'t build anything custom',
      // A question asks rather than instructs.
      'Stepping away from the form, what happens to the draft?',
      'Are you back at your desk?',
      'Should I go ahead and build?',
      // The let's wind down family too (lessons review of #714).
      'the workers start winding down.',
      'once the sprint ends, time to wind down.',
      'users said it is time to wind down for the night',
    ])
      expect(triggersIn(t)).toEqual([])
  })
  test('the same phrases aimed at Claude still switch, as a sentence or clause of their own', () => {
    expect(triggersIn('Heads up, I am stepping away for a bit.')).toEqual([{ kind: 'place', place: 'away' }])
    expect(triggersIn('Thanks. Back at my mac.')).toEqual([{ kind: 'place', place: 'home' }])
    expect(triggersIn('Research the sync first. No coding yet.')).toEqual([{ kind: 'scope', scope: 'NO BUILD' }])
    expect(triggersIn('Research the sync first, no coding yet.')).toEqual([{ kind: 'scope', scope: 'NO BUILD' }])
    expect(triggersIn('ok, go ahead and build')).toEqual([{ kind: 'build' }])
    expect(triggersIn("Just file, don't build it yet.")).toEqual([{ kind: 'scope', scope: 'NO BUILD' }])
    // Led by the words a request to Claude opens with, which the anywhere match used to allow.
    expect(triggersIn('can you pause after this issue')).toEqual([{ kind: 'scope', scope: 'WINDING DOWN' }])
    expect(triggersIn('pls go ahead and build')).toEqual([{ kind: 'build' }])
    expect(triggersIn("Let's go ahead and build.")).toEqual([{ kind: 'build' }])
    expect(triggersIn('you can go ahead and build now')).toEqual([{ kind: 'build' }])
    expect(triggersIn('so the worker can go ahead and build')).toEqual([])
    expect(triggersIn('Great work today, let’s wind down.')).toEqual([{ kind: 'scope', scope: 'WINDING DOWN' }])
    expect(triggersIn('ok, time to wind down for the night')).toEqual([{ kind: 'scope', scope: 'WINDING DOWN' }])
    expect(triggersIn('Thanks. Start winding down.')).toEqual([{ kind: 'scope', scope: 'WINDING DOWN' }])
    expect(triggersIn('Nice.\nPause after this PR and clean up.')).toEqual([{ kind: 'scope', scope: 'WINDING DOWN' }])
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
