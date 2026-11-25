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
  ['its card tool', { tool: 'mcp__is-it-live__card', repo: 'dan/app', pr: 1 }, 'Blocked: the is it live mod could not finish answering this call to its own tool (it failed), so the call was refused. What it had done by then stands, so check before sending the call again. If it keeps happening, tell Dan.'],
]

for (const [what, call, words] of CASES)
  test(`#3655: ${what} whose hook throws is refused in the mod's name, and nothing runs beneath`, { plugins: [kit] }, async ($, on) => {
    const ran: string[] = []
    on('tool.call', async (_$, e) => (ran.push(String(e.tool)), { result: 'ran' }))
    const r = await $.tool.call({ ...call, tool_use_id: 't1' } as never)
    expect(r.deny).toBe(words)
    expect(ran).toEqual([])
  })
