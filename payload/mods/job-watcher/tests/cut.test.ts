import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'

// #3655: Claude Code skips a tool.call hook that throws, as it skips one cut at its 10 seconds, and
// with no catch the call then goes on with nothing of this mod's having judged it. Here
// mod-kit is not loaded, so its screen, which the hook asks before anything else, is not there
// and the hook throws before it answers.
// The registration's catch, built by mod-kit's hooks/hold.ts, answers in its place. What that catch
// answers case by case (a timeout, a failure, a call already passed on) is pinned in mod-kit's
// tests/hold.test.ts; a cut for time is measured live, since a test would wait ten real seconds.
const CASES: [string, Record<string, unknown>, string][] = [
  ['its own tool', { tool: 'mcp__job-watcher__keep_job', task_id: 'b1', name: 'dev server', reason: 'it serves the page under test' }, 'Blocked: the job watcher could not finish answering this call to its own tool (it failed), so the call was refused. What it had done by then stands, so check before sending the call again. If it keeps happening, tell Dan.'],
]

for (const [what, call, words] of CASES)
  test(`#3655: ${what} whose hook throws is refused in the mod's name, and nothing runs beneath`, async ($, on) => {
    const ran: string[] = []
    on('tool.call', async (_$, e) => (ran.push(String(e.tool)), { result: 'ran' }))
    const r = await $.tool.call({ ...call, tool_use_id: 't1' } as never)
    expect(r.deny).toBe(words)
    expect(ran).toEqual([])
  })
