import { expect } from 'claude-code/testing'
import type { Register } from 'claude-code'
import { test } from './mod-kit/tests/hang-ceiling.ts'

// #3655: Claude Code skips a tool.call hook that throws, as it skips one cut at its 10 seconds, and
// with no catch the call then goes on with nothing of this mod's having judged it. Here
// mod-kit's screen, which the hook asks before anything else, is not there (the stand in below
// carries only what the module needs to load), so the hook throws before it answers.
// The registration's catch, built by mod-kit's hooks/hold.ts, answers in its place. What that catch
// answers case by case (a timeout, a failure, a call already passed on) is pinned in mod-kit's
// tests/hold.test.ts; a cut for time is measured live, since a test would wait ten real seconds.
// What the module needs to load: the kit's noun, with the two events the kit's mods hook. An inline
// plugin cannot reach this file's variables, so what its methods do is written inside it.
const kit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const fails = async (): Promise<never> => {
        throw new Error('not stood in')
      }
      return { ...(await next(e)), modkit: { press: fails, login: fails } } as never
    })
  },
}
const CASES: [string, Record<string, unknown>, string][] = [
  ['a call its tool.call hook answers', { tool: 'mcp__scope-modes__switch_to_build', change: 'fix the header' }, 'Blocked: scope modes could not check this call (it failed), so the call was refused and did not run. This is not a judgement of what the call does: send the same call again. If it keeps happening, tell Dan.'],
]

for (const [what, call, words] of CASES)
  test(`#3655: ${what} whose hook throws is refused in the mod's name, and nothing runs beneath`, { plugins: [kit] }, async ($, on) => {
    const ran: string[] = []
    on('tool.call', async (_$, e) => (ran.push(String(e.tool)), { result: 'ran' }))
    const r = await $.tool.call({ ...call, tool_use_id: 't1' } as never)
    expect(r.deny).toBe(words)
    expect(ran).toEqual([])
  })

// #1495, Dan's decision 2026-10-22 (picker answer "Let stops through on a check error"): "when scope
// modes' own check of a TaskStop errors, the stop is let through; every other refusal of a TaskStop,
// and every other tool's fail closed behaviour, stays as it is." The hook's own try carries that out
// for a judge that throws. A failure outside that try (here the mode's state cannot be read, so the
// hook throws before it judges) or a cut for time reaches the registration's catch instead, which
// therefore answers nothing for a TaskStop, the one call it lets go on, and refuses every other.
test("#3655, #1495: a TaskStop whose hook throws is let through, and an edit whose hook throws the same way is refused", { plugins: [kit] }, async ($, on) => {
  const ran: string[] = []
  const store = { broken: false }
  on('tool.call', async (_$, e) => (ran.push(String(e.tool)), { result: 'ran' }))
  on('state.get', async (_$, e, next) => (store.broken && (e as { key: string }).key === 'scope' ? ({ deny: 'the state store broke' } as never) : next(e)))
  store.broken = true
  const stop = await $.tool.call({ tool: 'TaskStop', task_id: 'b1', tool_use_id: 't1' } as never)
  expect(stop.deny).toBeUndefined()
  expect(ran).toEqual(['TaskStop'])
  const edit = await $.tool.call({ tool: 'Edit', file_path: '/repo/app.ts', old_string: 'a', new_string: 'b', tool_use_id: 't2' } as never)
  expect(edit.deny).toBe('Blocked: scope modes could not check this call (it failed), so the call was refused and did not run. This is not a judgement of what the call does: send the same call again. If it keeps happening, tell Dan.')
  expect(ran).toEqual(['TaskStop'])
})
