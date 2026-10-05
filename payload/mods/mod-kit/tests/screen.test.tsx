import { expect, test } from 'claude-code/testing'
import type { Register } from 'claude-code'

// #707: a mod that answers a tool call itself (manual steps, is it live, picker manners, handoff,
// the job watcher, scope modes' switch to build) never calls next, so no guard beneath it sees the
// call. It asks $.modkit.screen first. The answering mod here stands in for them: it answers Pin,
// and says by a toast that it acted.
const answerer: { name: string; register: Register } = {
  name: 'manual-steps',
  register: on => {
    on('tool.call', { tool: 'Pin' }, async ($, e) => {
      const refused = await $.modkit.screen(e as never)
      if (refused) return refused
      await $.ui.toast('ACTED')
      return { result: 'Pinned.' } as never
    })
  },
}

// The secret guard, standing in (a mod's tests cannot load another mod's files): it refuses a call
// carrying SECRET, as the real one refuses a known secret, and throws on one carrying BREAK.
const secretGuard: { name: string; register: Register } = {
  name: 'secret-guard',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const screen = async (call: unknown) => {
        const text = JSON.stringify(call)
        if (text.includes('BREAK')) throw new Error('the secrets could not be read')
        if (text.includes('TYPEERR')) throw new TypeError("undefined is not an object (evaluating 'known.some')")
        return text.includes('SECRET') ? { deny: 'Blocked: this message contains a secret. Refer to it by its name, not its value.' } : null
      }
      return { ...built, secretGuard: { screen } } as never
    })
  },
}

const pin = (value: string, id: string) => ({ tool: 'Pin', tool_use_id: id, value }) as never
const row = (id: string) => ({ plugin: 'mod-kit', surface: 'terminal', component: 'ToolResult', props: { tool_use_id: id, tool: 'Pin', output: 'x', isErrored: true } }) as never
const textOf = (r: unknown) => {
  const x = r as { deny?: string; text?: string; result?: unknown }
  return x.deny ?? x.text ?? String(x.result)
}
const world = (on: Parameters<Register>[0]) => {
  const toasts: string[] = []
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine row</Text>
  })
  return { toasts }
}

test('the secret guard refusing a call is the answer the answering mod returns, before it acts (#707)', { plugins: [answerer, secretGuard] }, async ($, on) => {
  const w = world(on)
  const r = await $.tool.call(pin('sk_SECRET', 's1'))
  expect(textOf(r)).toBe('Blocked: this message contains a secret. Refer to it by its name, not its value.')
  expect(w.toasts).toEqual([])
  // A clean call is screened and goes ahead.
  expect(textOf(await $.tool.call(pin('public', 's2')))).toBe('Pinned.')
  expect(w.toasts).toEqual(['ACTED'])
})

test('with the secret guard not loaded nothing refuses, and the answering mod goes ahead (#707)', { plugins: [answerer] }, async ($, on) => {
  const w = world(on)
  expect(textOf(await $.tool.call(pin('sk_SECRET', 's3')))).toBe('Pinned.')
  expect(w.toasts).toEqual(['ACTED'])
})

// Lessons review of #707: a TypeError from inside a loaded secret guard is a failure, never taken
// for the secret guard being absent.
test('a TypeError from inside a loaded secret guard refuses the call too (#707 review)', { plugins: [answerer, secretGuard] }, async ($, on) => {
  const w = world(on)
  const r = await $.tool.call(pin('TYPEERR', 's5'))
  expect(textOf(r)).toMatch(/^Blocked: the secret guard could not be asked about this/)
  expect(w.toasts).toEqual([])
})

// A mod may hand the screen a call with no id (it builds the call itself): a failure still refuses,
// and no card is kept under an empty id for some other row to be drawn as (#707 review).
const idless: { name: string; register: Register } = {
  name: 'handoff',
  register: on => {
    on('tool.call', { tool: 'Save' }, async ($, e) => {
      const { tool_use_id: _id, ...call } = e as unknown as Record<string, unknown>
      const refused = await $.modkit.screen(call as never)
      return refused ?? ({ result: 'Saved.' } as never)
    })
  },
}
test('a failed screen of a call with no id refuses it and keeps no card under an empty id (#707 review)', { plugins: [idless, secretGuard] }, async ($, on) => {
  world(on)
  const r = await $.tool.call({ tool: 'Save', tool_use_id: 'v1', value: 'BREAK' } as never)
  expect(textOf(r)).toMatch(/^Blocked: the secret guard could not be asked about this/)
  for (const id of ['', 'v1']) {
    const ui = await $.ui.mount(row(id))
    expect(await ui.find({ text: 'Blocked by Secret guard' })).toBeUndefined()
    await ui.unmount()
  }
})

test('a secret guard that fails to answer refuses the call, with the grey card (#707, L42)', { plugins: [answerer, secretGuard] }, async ($, on) => {
  const w = world(on)
  const r = await $.tool.call(pin('BREAK', 's4'))
  expect(textOf(r)).toMatch(/^Blocked: the secret guard could not be asked about this \(.*the secrets could not be read.*\), so it did not run\. Try it again; if it fails the same way, tell Dan\.$/)
  expect(w.toasts).toEqual([])
  const ui = await $.ui.mount(row('s4'))
  expect(await ui.find({ text: 'Blocked by Secret guard' })).toBeDefined()
  expect(await ui.find({ text: "Couldn't check this for secrets, so it was stopped." })).toBeDefined()
  await ui.unmount()
})
