import { expect, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import { sendTwice } from '../hooks/send.ts'

// A message one mod sends another session (#688): sent through $.session.send as ever, so the
// receiver still reads which mod sent it, and tried once more by mod-kit when it is refused. A
// stand in sender turns a Bash command into one send and reports the answer it got.
const sender: { name: string; register: Register } = {
  name: 'sender',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      const text = String((e as { command?: string }).command)
      const sent = await $.session.send({ to: { sessionId: 's2' }, text })
      return { deny: JSON.stringify(sent) }
    })
  },
}
const withSender = { plugins: [sender] }

// Each send's outcome in turn: delivered, or refused with this reason.
type Outcome = true | { refused: string }
// Claude Code beneath the kit: every send that reaches it is recorded with who sent it.
const world = (on: On, outcomes: Outcome[]) => {
  const sends: { text: string; origin: unknown }[] = []
  on('session.send', ($, e) => {
    sends.push({ text: e.text, origin: (e as unknown as { origin?: unknown }).origin })
    const o = outcomes[sends.length - 1] ?? true
    return (o === true ? { isDelivered: true } : { isDelivered: false, reason: o.refused }) as never
  })
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  return sends
}
type Caller = { tool: { call: (e: never) => Promise<unknown> } }
const send = async ($: Caller, text = 'Away is on') => {
  const out = (await $.tool.call({ tool: 'Bash', command: text, tool_use_id: 't1' } as never)) as { deny?: string; text?: string }
  return JSON.parse(out.deny ?? out.text ?? 'null') as { isDelivered: boolean; reason?: string }
}

test('a send delivered at once is sent once, as the mod that sent it', withSender, async ($, on) => {
  const sends = world(on, [true])
  expect(await send($)).toEqual({ isDelivered: true })
  expect(sends).toEqual([{ text: 'Away is on', origin: { kind: 'plugin', name: 'sender' } }])
})

test('a refused send is tried once more, still as the mod that sent it, and lands', withSender, async ($, on) => {
  const sends = world(on, [{ refused: 'Classifier unavailable' }, true])
  expect(await send($)).toEqual({ isDelivered: true })
  expect(sends.length).toBe(2)
  // The receiver tells its own mod's messages apart by this, so the retry must not change it.
  expect(sends.every(s => JSON.stringify(s.origin) === JSON.stringify({ kind: 'plugin', name: 'sender' }))).toBe(true)
})

test('a send refused twice is not tried a third time, and answers the second reason, tidied', withSender, async ($, on) => {
  const sends = world(on, [{ refused: 'first.' }, { refused: '  Classifier unavailable.  ' }, true])
  expect(await send($)).toEqual({ isDelivered: false, reason: 'Classifier unavailable' })
  expect(sends.length).toBe(2)
})

test('a refusal with no reason says so rather than answering an empty one', withSender, async ($, on) => {
  world(on, [{ refused: ' ' }, { refused: ' . ' }])
  expect(await send($)).toEqual({ isDelivered: false, reason: 'no reason given' })
})

// Claude Code skips a hook beneath the kit that throws, so a throw out of the send itself is
// produced here by calling the retry directly.
test('a send that throws is not tried again, since it may have landed, and answers why', async () => {
  let calls = 0
  const sent = await sendTwice(async () => {
    calls++
    throw new Error('the session has ended.')
  })
  expect(sent).toEqual({ isDelivered: false, reason: 'the session has ended' })
  expect(calls).toBe(1)
})

test("a send no mod made, such as Claude's own SendMessage, is left as it is", async ($, on) => {
  const sends = world(on, [{ refused: 'Classifier unavailable.' }, true])
  const sent = await $.session.send({ to: { sessionId: 's2' }, text: 'hello' })
  expect(sent).toEqual({ isDelivered: false, reason: 'Classifier unavailable.' })
  expect(sends.length).toBe(1)
  expect((sends[0]?.origin as { kind?: string } | undefined)?.kind).not.toBe('plugin')
})
