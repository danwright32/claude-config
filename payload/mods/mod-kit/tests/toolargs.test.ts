import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { toolArgs } from '../hooks/toolargs.ts'

// A tool call's own arguments, without the keys Claude Code carries beside them (#3190). Eight mods
// took them off by hand, in twelve places, each copy having to learn a key the engine adds; this is the one
// copy every mod keeps at hooks/mod-kit/toolargs.ts, which tools/check-mod-shared-parts.sh holds to it.

test('each of the four keys the engine carries is taken off, and the arguments are kept', () => {
  for (const key of ['tool', 'tool_use_id', 'agentId', 'consent']) {
    expect(toolArgs({ command: 'ls', description: 'List', [key]: 'x' })).toEqual({ command: 'ls', description: 'List' })
  }
})

test('all four at once leave the arguments alone', () => {
  expect(toolArgs({ tool: 'Bash', tool_use_id: 't1', agentId: 'a1', consent: 'granted', command: 'git status' })).toEqual({ command: 'git status' })
})

test('a call carrying none of the keys comes back whole, as a new object', () => {
  const e = { file_path: '/x/y.ts', content: 'z' }
  const args = toolArgs(e)
  expect(args).toEqual({ file_path: '/x/y.ts', content: 'z' })
  expect(args === e).toBe(false)
})

test('a key the engine set to undefined is taken off too, and any other key is an argument', () => {
  const args = toolArgs({ tool: 'Write', agentId: undefined, tool_use_id: undefined, input: { a: 1 }, requestMeta: { k: 'v' } })
  expect(Object.keys(args).sort()).toEqual(['input', 'requestMeta'])
})

test('the caller\'s event is left as it was', () => {
  const e = { tool: 'Bash', tool_use_id: 't2', command: 'pwd' }
  toolArgs(e)
  expect(e).toEqual({ tool: 'Bash', tool_use_id: 't2', command: 'pwd' })
})
