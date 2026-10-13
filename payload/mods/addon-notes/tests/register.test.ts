import { expect, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import { ADD_ON_CONTEXT, AMENDMENT_CONTEXT, TOAST } from '../hooks/classify.ts'
import { isDans } from './mod-kit/hooks/origin.ts'

// mod-kit, standing in (#1135): whether a prompt is Dan's words is its one answer. A plugin in a test
// runs in its own environment, so the stand-in asks the world (`__modkit`), which reads with a byte
// for byte copy of mod-kit's reader under tests/mod-kit, held to mod-kit's by
// tools/check-mod-shared-parts.sh. The kit's other members are never reached here.
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const isDans = async (input: unknown) => {
        const r = await built.process.run(['__modkit', 'isDans', JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return JSON.parse(r.stdout) as boolean
      }
      return { ...built, modkit: { isDans } as never }
    })
  },
}
const KIT = { plugins: [modKit] }

// Add-on notes (claude-config#620). What the mod changes is only ever what the model reads beside
// the prompt (its context) and one toast; the words Dan typed reach the model as typed.

type Seen = { text: string; context: readonly string[] }

const world = (on: On, opts: { dropBelow?: boolean } = {}) => {
  const seen: Seen[] = []
  const toasts: string[] = []
  // Claude Code beneath the mod: records what entered, or refuses it.
  on('prompt.submit', ($, e) => {
    if (opts.dropBelow) return { drop: 'blocked by a settings hook' }
    seen.push({ text: e.text, context: e.context ?? [] })
    return { text: e.text, context: e.context, origin: e.origin }
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('session.end', () => ({ sessionId: 's1' }) as never)
  // mod-kit's reader, as the stand-in above asks it: mod-kit's own copy.
  on('process.run', ($, e) => {
    if (e.argv[0] !== '__modkit' || e.argv[1] !== 'isDans') throw new Error(`unexpected run: ${e.argv.join(' ')}`)
    const { origin } = JSON.parse(e.argv[2] as string)
    return { value: { exitCode: 0, stdout: JSON.stringify(isDans(origin)), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
  })
  return { seen, toasts }
}

// A prompt as Claude Code raises it: typed at the terminal, mid turn when turnId is set.
const typed = (text: string, turnId?: string, kind: string | object = 'composer') =>
  ({ text, wait: false, origin: typeof kind === 'string' ? { kind } : kind, ...(turnId ? { turnId } : {}) }) as never

const ended = (reason: 'answer' | 'aborted' | 'error', extra: Record<string, unknown> = {}) =>
  ({ answer: '', durationMs: 10, isAborted: reason === 'aborted', turnId: 't1', reason, ...extra }) as never

test('a + note mid turn is marked as an add-on and acknowledged with a toast', KIT, async ($, on) => {
  const w = world(on)
  const r = await $.prompt.submit(typed('+ also link the commission', 't1'))
  expect(w.seen).toEqual([{ text: '+ also link the commission', context: [ADD_ON_CONTEXT] }])
  expect(w.toasts).toEqual([TOAST])
  expect(TOAST).toBe('Noted, applying after this step.')
  expect((r as { text?: string }).text).toBe('+ also link the commission')
})

test('a + note from the phone counts too', KIT, async ($, on) => {
  const w = world(on)
  await $.prompt.submit(typed('+ include links', 't1', 'bridge'))
  expect(w.seen[0]?.context).toEqual([ADD_ON_CONTEXT])
  expect(w.toasts).toEqual([TOAST])
})

test('context another hook already attached is kept beside the add-on note', KIT, async ($, on) => {
  const w = world(on)
  await $.prompt.submit({ ...(typed('+ include links', 't1') as object), context: ['earlier'] } as never)
  expect(w.seen[0]?.context).toEqual(['earlier', ADD_ON_CONTEXT])
})

test('a plain message mid turn is left to Claude Code, which already delivers it', KIT, async ($, on) => {
  const w = world(on)
  await $.prompt.submit(typed('also link the commission', 't1'))
  expect(w.seen).toEqual([{ text: 'also link the commission', context: [] }])
  expect(w.toasts).toEqual([])
})

test('a + message from another session or a background task is not Dan, so it is left alone', KIT, async ($, on) => {
  const w = world(on)
  await $.prompt.submit(typed('+ also x', 't1', 'peer'))
  await $.prompt.submit(typed('+ also x', 't1', 'task-notification'))
  expect(w.seen.map(s => s.context)).toEqual([[], []])
  expect(w.toasts).toEqual([])
})

// #1135: only what Dan types is an add-on, at the Mac or from his phone, as in every mod (Dan,
// 2026-10-13): a handoff's opening prompt he pressed Use on is not his note, nor is a task notification.
for (const [who, origin, counts] of [
  ['typed at the terminal', { kind: 'composer' }, true],
  ['sent from his phone through Remote Control', { kind: 'bridge' }, true],
  ["a handoff's opening prompt he pressed Use on", { kind: 'plugin', name: 'handoff', asUser: true }, false],
  ['a background task notification', { kind: 'task-notification' }, false],
] as [string, object, boolean][]) {
  test(`a + note mid turn ${who} ${counts ? 'is an add-on' : 'is left alone'}`, KIT, async ($, on) => {
    const w = world(on)
    await $.prompt.submit(typed('+ also link the commission', 't1', origin))
    expect(w.seen.map(x => x.context)).toEqual([counts ? [ADD_ON_CONTEXT] : []])
    expect(w.toasts).toEqual(counts ? [TOAST] : [])
  })
}

test('no toast when the note never entered: refused beneath', KIT, async ($, on) => {
  const w = world(on, { dropBelow: true })
  const r = await $.prompt.submit(typed('+ also x', 't1'))
  expect((r as { drop?: string }).drop).toBe('blocked by a settings hook')
  expect(w.toasts).toEqual([])
})

// Each phrase Dan used after pressing Esc (from the issue): the interrupted step resumes.
for (const phrase of ['also do a direct link to commission', 'and open it in bbedit', 'include links', 'sorry keep going', '+ add the tests too']) {
  test(`after an interrupt, "${phrase}" is an amendment that resumes the step`, KIT, async ($, on) => {
    const w = world(on)
    await $.turn.complete(ended('aborted'))
    await $.prompt.submit(typed(phrase))
    expect(w.seen).toEqual([{ text: phrase, context: [AMENDMENT_CONTEXT] }])
    // The acknowledgement after an interrupt is Claude's own one line, not a toast.
    expect(w.toasts).toEqual([])
  })
}

for (const phrase of ['stop, do the README first instead', 'no, use the other file', 'actually never mind, revert that', 'do the issue list now']) {
  test(`after an interrupt, the redirect "${phrase}" is not read as an add-on`, KIT, async ($, on) => {
    const w = world(on)
    await $.turn.complete(ended('aborted'))
    await $.prompt.submit(typed(phrase))
    expect(w.seen).toEqual([{ text: phrase, context: [] }])
    expect(w.toasts).toEqual([])
  })
}

test('the same reply after a turn that finished normally is a new message', KIT, async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('answer'))
  await $.prompt.submit(typed('also do a direct link to commission'))
  expect(w.seen[0]?.context).toEqual([])
})

test('a finished turn after an interrupt clears it', KIT, async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.turn.complete(ended('answer'))
  await $.prompt.submit(typed('also do a direct link to commission'))
  expect(w.seen[0]?.context).toEqual([])
})

test('a turn that died on an API error is no interrupt', KIT, async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('error'))
  await $.prompt.submit(typed('also do a direct link to commission'))
  expect(w.seen[0]?.context).toEqual([])
})

test('a subagent interrupted is not the session interrupted', KIT, async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted', { agentId: 'a1' }))
  await $.prompt.submit(typed('also do a direct link to commission'))
  expect(w.seen[0]?.context).toEqual([])
})

test('an interrupt is answered once: the next message uses it up, add-on or not', KIT, async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.prompt.submit(typed('no, use the other file'))
  await $.prompt.submit(typed('also include links'))
  expect(w.seen.map(s => s.context)).toEqual([[], []])
})

test('an amendment uses the interrupt up too', KIT, async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.prompt.submit(typed('also include links'))
  await $.prompt.submit(typed('and the footer'))
  expect(w.seen.map(s => s.context)).toEqual([[AMENDMENT_CONTEXT], []])
})

test('a message from another session after an interrupt does not use it up', KIT, async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.prompt.submit(typed('Another session finished', undefined, 'peer'))
  await $.prompt.submit(typed('also include links'))
  expect(w.seen.map(s => s.context)).toEqual([[], [AMENDMENT_CONTEXT]])
})

test('a /clear forgets the interrupt', KIT, async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.session.end({ reason: 'clear' } as never)
  await $.prompt.submit(typed('also include links'))
  expect(w.seen[0]?.context).toEqual([])
})

test('a + note after an interrupt is an amendment, with no toast', KIT, async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.prompt.submit(typed('+ include links'))
  expect(w.seen[0]?.context).toEqual([AMENDMENT_CONTEXT])
  expect(w.toasts).toEqual([])
})

test('a + note while idle with no interrupt is passed through as typed', KIT, async ($, on) => {
  const w = world(on)
  await $.prompt.submit(typed('+ include links'))
  expect(w.seen).toEqual([{ text: '+ include links', context: [] }])
  expect(w.toasts).toEqual([])
})

test('the amendment tells Claude to resume, keep scope, and open with the agreed resume line', () => {
  expect(AMENDMENT_CONTEXT).toContain('Resume the step you were on')
  expect(AMENDMENT_CONTEXT).toContain('Keep every part of the scope already agreed')
  // The agreed wording (docs/mods-design.md, Add-on notes): it names the addition only.
  expect(AMENDMENT_CONTEXT).toContain('+ add-on: Adding a direct link to the commission and carrying on.')
  expect(ADD_ON_CONTEXT).toContain('not a redirect')
})

// #744: picker manners holds no question open any more (Claude Code's own dialog asks, and holds the
// keyboard while it does, so no + note can be typed under a question). An open question an earlier
// build left in the session's state is never read: a + note mid turn is an add-on (L377).
const pickerMannersLeftOver: Register = on => {
  on('tool.call', { tool: 'Bash' }, async $ => {
    await $.state.set({ plugin: 'picker-manners', key: 'open' } as never, { id: 'q1', question: { question: 'Ship it?', header: 'Ship', multiSelect: false, options: [] }, chosen: [] } as never)
    return { deny: 'written' } as never
  })
}

test('an open question an earlier picker manners left in the session state does not stop a + note being an add-on', { plugins: [modKit, { name: 'picker-manners', register: pickerMannersLeftOver }] }, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Bash', command: 'x' } as never)
  await $.prompt.submit(typed('+ also link the commission', 't1'))
  expect(w.seen).toEqual([{ text: '+ also link the commission', context: [ADD_ON_CONTEXT] }])
  expect(w.toasts).toEqual([TOAST])
})
