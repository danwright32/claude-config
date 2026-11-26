import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'

// #3655: Claude Code skips a tool.call hook that throws, as it skips one cut at its 10 seconds, and
// with no catch the call then goes on with nothing of this mod's having judged it. Here
// nothing beneath answers for the Mac's HOME, which the hook reads to find the scanner for text
// that is not plain ASCII, so the hook throws before it judges.
// The registration's catch, built by mod-kit's hooks/hold.ts, answers in its place. What that catch
// answers case by case (a timeout, a failure, a call already passed on) is pinned in mod-kit's
// tests/hold.test.ts; a cut for time is measured live, since a test would wait ten real seconds.
const CASES: [string, Record<string, unknown>, string][] = [
  ['a write it could not scan', { tool: 'Write', file_path: '/tmp/note.md', content: 'caf\u00e9' }, 'Blocked: the style check could not check this call (it failed), so the call was refused and did not run. This is not a judgement of what the call does: send the same call again. If it keeps happening, tell Dan.'],
]

for (const [what, call, words] of CASES)
  test(`#3655: ${what} whose hook throws is refused in the mod's name, and nothing runs beneath`, async ($, on) => {
    const ran: string[] = []
    on('tool.call', async (_$, e) => (ran.push(String(e.tool)), { result: 'ran' }))
    const r = await $.tool.call({ ...call, tool_use_id: 't1' } as never)
    expect(r.deny).toBe(words)
    expect(ran).toEqual([])
  })
