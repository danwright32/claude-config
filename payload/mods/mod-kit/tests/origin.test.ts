import { expect, test } from 'claude-code/testing'
import type { PromptOrigin, Register } from 'claude-code'
import { isDans } from '../hooks/origin.ts'

// Whether a prompt is Dan's own words (#1135). Five mods asked it two ways: picker manners, ask
// before saving and scope modes counted his Enter and his phone, while the goal tracker and auto
// session name also counted a handoff's opening prompt he pressed Use on. Dan decided on 2026-10-13
// that only what he types counts, at the terminal or from his phone through Remote Control, never a
// handoff's opening prompt, in every mod. One reader now answers it for all of them.
const HIS: [string, PromptOrigin][] = [
  ['typed at the terminal', { kind: 'composer' }],
  ['sent from his phone through Remote Control', { kind: 'bridge' }],
]
const NOT_HIS: [string, PromptOrigin][] = [
  ["a handoff's opening prompt he pressed Use on", { kind: 'plugin', name: 'handoff', asUser: true }],
  ['a background task notification', { kind: 'task-notification' }],
  ["another plugin's prompt sent as a person's", { kind: 'plugin', name: 'simpler', asUser: true }],
  ["another plugin's own prompt", { kind: 'plugin', name: 'scope-modes' }],
  ["a peer session's message", { kind: 'peer' }],
  ['a scheduled task', { kind: 'scheduled-trigger' }],
  ["the SDK host's turn", { kind: 'sdk' }],
  ['a turn the engine could not classify', { kind: 'unclassified' }],
  ['a follow up to a UI action', { kind: 'auto-continuation' }],
]

test("only what Dan types, at the terminal or from his phone, is his words", () => {
  for (const [why, origin] of HIS) expect({ why, dans: isDans(origin) }).toEqual({ why, dans: true })
  for (const [why, origin] of NOT_HIS) expect({ why, dans: isDans(origin) }).toEqual({ why, dans: false })
})

test('a prompt with no origin is not his', () => {
  expect(isDans(undefined)).toBe(false)
  expect(isDans({} as never)).toBe(false)
})

// The noun every mod calls, asked from another plugin as a mod asks it.
const asker: { name: string; register: Register } = {
  name: 'asker',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      const origin = JSON.parse(String((e as { command?: string }).command)) as PromptOrigin
      return { deny: `dans ${String(await $.modkit.isDans({ origin }))}` }
    })
  },
}

test('$.modkit.isDans gives the same answer to another mod', { plugins: [asker] }, async $ => {
  const ask = async (origin: PromptOrigin) => ((await $.tool.call({ tool: 'Bash', command: JSON.stringify(origin) } as never)) as { deny?: string }).deny
  for (const [why, origin] of HIS) expect({ why, said: await ask(origin) }).toEqual({ why, said: 'dans true' })
  for (const [why, origin] of NOT_HIS) expect({ why, said: await ask(origin) }).toEqual({ why, said: 'dans false' })
})
