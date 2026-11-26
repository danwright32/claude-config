import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { BOX_KINDS, INFLIGHT_KINDS, inflightHolds, taskFinished, tasksIn, type InflightFacts } from '../hooks/inflight.ts'

// #3770: the one list of what holds a session's work in flight. Every kind asked about is read from
// the fact handed over, and a fact not handed over or not readable is a hold, never a clear reading.

const CLEAN: Required<InflightFacts> = {
  agents: { value: [{ id: 'a1', status: 'completed' }] },
  merges: { value: [] },
  prs: { value: [] },
  tasks: { value: [] },
  crons: { value: [] },
  jobs: { value: [] },
  goal: { value: { state: 'none' } },
  steps: { value: { card: null } },
  compact: { value: { queued: false, followUp: null } },
  prompts: { value: { holds: [], now: 1_000 } },
  answer: { value: 'Merged and live.' },
}

test('every kind read clean holds nothing', async () => {
  expect(inflightHolds(CLEAN, INFLIGHT_KINDS)).toEqual([])
})

test('each kind false in turn holds by its own kind and words', async () => {
  const cases: [Partial<InflightFacts>, string, RegExp][] = [
    [{ agents: { value: [{ id: 'a1', description: 'Build', status: 'running' }] } }, 'agent', /the agent "Build" is still running/],
    [{ agents: { value: [{ id: 'a1', name: 'mate', status: 'idle' }] } }, 'agent-idle', /the agent "mate" is idle and has not ended/],
    [{ agents: { value: [{ id: 'a1', description: 'Harvest', status: 'running', spawnedBy: 'job-watcher' }] } }, 'agent-plugin', /which a mod started/],
    [{ tasks: { value: [{ id: 'b1', type: 'shell', status: 'running', command: 'npm test' }] } }, 'task', /background shell b1 \(npm test\) is still running/],
    [{ tasks: { value: [{ id: 'm1', type: 'monitor', status: 'pending', description: 'watch CI' }] } }, 'task', /monitor m1/],
    [{ crons: { value: [{ id: 'c1', schedule: '*/5 * * * *', recurring: true, prompt: 'x' }] } }, 'cron', /scheduled wake up \(\*\/5 \* \* \* \*\)/],
    [{ jobs: { value: [{ id: 'j1', label: 'dev server', kept: true, state: 'running' }] } }, 'job', /"dev server", kept, is still running/],
    [{ merges: { value: ['#7 is still deploying'] } }, 'merge', /#7 is still deploying/],
    [{ prs: { value: ['o/r#9 is still open'] } }, 'pr', /o\/r#9 is still open/],
    [{ goal: { value: { state: 'set', condition: 'ship it' } } }, 'goal', /\/goal "ship it" is still set/],
    [{ steps: { value: { card: { heading: 'h', steps: [{ title: 'Add the key' }] } } } }, 'steps', /"Add the key" is not done/],
    [{ compact: { value: { queued: true, followUp: null } } }, 'compact', /compact is queued/],
    [{ compact: { value: { queued: false, followUp: { note: 'n', ranAt: 1, compacted: true } } } }, 'compact', /handoff note/],
    [{ prompts: { value: { holds: [{ mod: 'goal-box', id: 'ask', what: 'the prompt asking for the box', until: 2_000 }], now: 1_000 } } }, 'prompt', /goal-box is waiting to send the prompt asking for the box/],
    [{ answer: { value: 'Done.\n\nShall I merge it?' } }, 'question', /ends on a question/],
  ]
  for (const [change, kind, words] of cases) {
    const holds = inflightHolds({ ...CLEAN, ...change }, INFLIGHT_KINDS)
    expect({ kind, kinds: holds.map(h => h.kind) }).toEqual({ kind, kinds: [kind as never] })
    expect(holds[0]?.text).toMatch(words)
    expect(holds[0]?.unread).toBeUndefined()
  }
})

test('finished tasks, ended agents, a lapsed hold, an ignored step and a finished step hold nothing', async () => {
  const facts: InflightFacts = {
    ...CLEAN,
    tasks: { value: [{ id: 'b1', type: 'shell', status: 'completed' }, { id: 'b2', type: 'shell', status: 'killed' }] },
    agents: { value: [{ id: 'a1', status: 'failed' }, { id: 'a2', status: 'killed' }, { id: 'a3', status: 'completed', spawnedBy: 'x' }] },
    prompts: { value: { holds: [{ mod: 'm', id: 'i', what: 'w', until: 1_000 }], now: 1_000 } },
    steps: { value: { card: { heading: 'h', steps: [{ title: 'Close it' }, { title: 'Done one', finished: 'checked' }] }, ignore: 'Close it' } },
    answer: { value: 'Is it live? Yes.\n\nMerged.' },
  }
  expect(inflightHolds(facts, INFLIGHT_KINDS)).toEqual([])
})

test('a fact not handed over, or that could not be read, is an unread hold of its kind', async () => {
  for (const kind of INFLIGHT_KINDS) {
    const holds = inflightHolds({}, [kind])
    expect(holds).toHaveLength(1)
    expect(holds[0]?.kind).toBe(kind)
    expect(holds[0]?.unread).toBe(true)
    expect(holds[0]?.text).toMatch(/it was not read/)
  }
  const broken: [Partial<InflightFacts>, RegExp][] = [
    [{ agents: { unread: 'the list threw' } }, /agents could not be listed \(the list threw\)/],
    [{ agents: { value: 'nope' } }, /not a list/],
    [{ agents: { value: [null, { id: 'a1', status: 'running' }] } }, /an entry of the agent list is not an agent/],
    [{ tasks: { value: undefined } }, /background work in flight .* could not be read \(it is missing or is not a list\)/],
    [{ crons: { value: { c1: 1 } } }, /scheduled wake ups .* could not be read/],
    [{ jobs: { unread: 'job watcher not loaded' } }, /job watcher's list of background jobs could not be read \(job watcher not loaded\)/],
    [{ goal: { value: { state: 'unreadable', why: 'no transcript' } } }, /\/goal could not be read \(no transcript\)/],
    [{ steps: { value: { card: { steps: 'x' } } } }, /manual steps card could not be read/],
    [{ prompts: { value: { holds: 'x', now: 1 } } }, /prompts a mod is about to send could not be read/],
    [{ answer: { value: undefined } }, /answer could not be read/],
    [{ merges: { value: [1] as never } }, /merges could not be read/],
  ]
  for (const [change, words] of broken) {
    const holds = inflightHolds({ ...CLEAN, ...change }, INFLIGHT_KINDS)
    expect(holds).toHaveLength(1)
    expect(holds[0]?.unread).toBe(true)
    expect(holds[0]?.text).toMatch(words)
  }
})

test('the box asks about its three kinds alone: an idle teammate, a mod\'s agent, a job and a card hold it not', async () => {
  expect([...BOX_KINDS]).toEqual(['agent', 'merge', 'pr'])
  const facts: InflightFacts = {
    agents: { value: [{ id: 'a1', status: 'idle' }, { id: 'a2', status: 'running', spawnedBy: 'x' }, { id: 'a3', description: 'Mine', status: 'waiting' }] },
    merges: { value: ['m'] },
    prs: { value: ['p'] },
  }
  expect(inflightHolds(facts, BOX_KINDS)).toEqual([
    { kind: 'agent', text: 'the agent "Mine" is still waiting' },
    { kind: 'merge', text: 'm' },
    { kind: 'pr', text: 'p' },
  ])
})

test('the tasks a stop carries, read as the job watcher reads them, and which statuses have ended', async () => {
  expect(tasksIn(undefined)).toBeUndefined()
  expect(tasksIn({ b1: 'running' })).toBeUndefined()
  expect(tasksIn([])).toEqual([])
  expect(tasksIn([null, 'b1', { type: 'shell' }, { id: '' }, { id: 'b2' }])).toEqual([{ id: 'b2', what: 'b2', type: '', status: '' }])
  expect(tasksIn([{ id: 'b3', command: 'a very long command', status: 'running', type: 'shell' }], s => s.slice(0, 6))).toEqual([{ id: 'b3', what: 'a very', type: 'shell', status: 'running' }])
  for (const s of ['completed', 'failed', 'killed', 'stopped']) expect(taskFinished(s)).toBe(true)
  for (const s of ['running', 'pending', '', 'backgrounded', 'unlisted']) expect(taskFinished(s)).toBe(false)
})
