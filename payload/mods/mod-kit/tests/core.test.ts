import { expect, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import { reasonOf, standInCore } from './core.ts'

// The stand-in for Claude Code's core that guard mods' tests share (#1484): the tool.check chain
// over every plugin decides whether a call runs, and a refusal reaches the call as an errored
// result. Claude Code 2.1.307's test kit raises that chain itself on every $.tool.call, and 2.1.304's
// did not, so the stand-in raises it only for a call the kit has not already checked: never twice,
// never not at all.

// A guard that judges every Bash call, reporting each judgement as a log line (an inline plugin
// cannot reach this file's variables), and refuses `refuse me`.
const guard: { name: string; register: Register } = {
  name: 'core-guard',
  register: on => {
    on('tool.check', { tool: 'Bash' }, async ($, e, next) => {
      const command = String((e.input as { command?: string }).command)
      await $.ui.log('JUDGED ' + command)
      if (command === 'refuse me') return { decision: 'deny', reason: 'Blocked: the guard says no.' }
      return next(e)
    })
  },
}
const withGuard = { plugins: [guard] }
// Every judgement the guard makes, in turn.
const judgements = (on: On) => {
  const judged: string[] = []
  on('ui.log', ($, e) => {
    if (e.text.startsWith('JUDGED ')) judged.push(e.text.slice(7))
    return { value: undefined }
  })
  return judged
}

test('a call is judged once, runs when allowed, and is refused with the guard reason when not', withGuard, async ($, on) => {
  const judged = judgements(on)
  const ran: string[] = []
  const core = standInCore($, on)
  on('tool.call', async ($$, e) => {
    const c = await core(e)
    if ('refused' in c) return c.refused as never
    ran.push(String(c.call.input.command))
    return { result: 'ran', text: 'ran' } as never
  })
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: 't1' } as never)
  const r = await $.tool.call({ tool: 'Bash', command: 'refuse me', tool_use_id: 't2' } as never)
  expect(judged).toEqual(['ls', 'refuse me'])
  expect(ran).toEqual(['ls'])
  expect(reasonOf(r, 'core-guard')).toBe('Blocked: the guard says no.')
})

test('a call the kit never checked, as on a build whose kit does not, is checked by the stand-in', withGuard, async ($, on) => {
  const judged = judgements(on)
  const core = standInCore($, on)
  // Handed straight to the stand-in, as a tool.call hook is on such a build: no check came first.
  const allowed = await core({ tool: 'Bash', command: 'ls', tool_use_id: 'u1' })
  const refused = await core({ tool: 'Bash', command: 'refuse me', tool_use_id: 'u2' })
  expect(judged).toEqual(['ls', 'refuse me'])
  expect(allowed).toEqual({ call: { tool: 'Bash', id: 'u1', input: { command: 'ls' } } })
  expect(reasonOf((refused as { refused: unknown }).refused, 'core-guard')).toBe('Blocked: the guard says no.')
})

test("a test's own check, which names no call, is never taken for the kit checking a call", withGuard, async ($, on) => {
  const judged = judgements(on)
  const core = standInCore($, on)
  await $.tool.check({ tool: 'Bash', input: { command: 'ls' } } as never)
  await core({ tool: 'Bash', command: 'ls' })
  expect(judged).toEqual(['ls', 'ls'])
})

test('the rules beneath every plugin can refuse, and a refused call is not taken as checked', withGuard, async ($, on) => {
  const judged = judgements(on)
  let refuse = true
  const core = standInCore($, on, () => (refuse ? { decision: 'deny', reason: 'Blocked by a settings hook.' } : { decision: 'allow' }))
  const ran: string[] = []
  on('tool.call', async ($$, e) => {
    const c = await core(e)
    if ('refused' in c) return c.refused as never
    ran.push(String(c.call.input.command))
    return { result: 'ran', text: 'ran' } as never
  })
  const r = await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: 'v1' } as never)
  expect(ran).toEqual([])
  expect(String((r as { text?: string }).text)).toContain('Blocked by a settings hook.')
  refuse = false
  // The same call again, now allowed beneath: judged once more, and it runs.
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: 'v1' } as never)
  expect(judged).toEqual(['ls', 'ls'])
  expect(ran).toEqual(['ls'])
})

// What a refusal says, in either form Claude Code wraps it: 2.1.307 reports a plugin's refusal as
// "Permission to use <tool> denied by plugin <name>: <reason>", a stand-in as the bare reason.
test('the reason read from a refusal is the named mod reason, never another plugin', () => {
  expect(reasonOf({ isError: true, text: 'Permission to use Edit denied by plugin core-guard: Blocked: no.' }, 'core-guard')).toBe('Blocked: no.')
  expect(reasonOf({ isError: true, text: 'Blocked: no.' }, 'core-guard')).toBe('Blocked: no.')
  expect(reasonOf({ deny: 'Blocked: no.' }, 'core-guard')).toBe('Blocked: no.')
  // Another plugin's refusal keeps its whole text, so a test expecting this mod's reason fails on it.
  expect(reasonOf({ isError: true, text: 'Permission to use Edit denied by plugin other-guard: Blocked: no.' }, 'core-guard'))
    .toBe('Permission to use Edit denied by plugin other-guard: Blocked: no.')
  // A mod whose name another begins with is not that one.
  expect(reasonOf({ isError: true, text: 'Permission to use Bash denied by plugin core-guard-two: Blocked: no.' }, 'core-guard'))
    .toBe('Permission to use Bash denied by plugin core-guard-two: Blocked: no.')
  expect(reasonOf(undefined, 'core-guard')).toBe('')
})
