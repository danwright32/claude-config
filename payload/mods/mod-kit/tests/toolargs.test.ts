import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { toolArgs } from '../hooks/toolargs.ts'

// A tool call's own arguments, without the keys Claude Code carries beside them (#3190). Eight mods
// took them off by hand, in twelve places, each copy having to learn a key the engine adds; this is the one
// copy every mod keeps at hooks/mod-kit/toolargs.ts, which tools/check-mod-shared-parts.sh holds to it.

test('each of the five keys the engine carries is taken off, and the arguments are kept', () => {
  for (const key of ['tool', 'tool_use_id', 'agentId', 'consent', 'requestMeta']) {
    expect(toolArgs({ command: 'ls', description: 'List', [key]: 'x' })).toEqual({ command: 'ls', description: 'List' })
  }
})

test('all five at once leave the arguments alone', () => {
  expect(toolArgs({ tool: 'Bash', tool_use_id: 't1', agentId: 'a1', consent: 'granted', requestMeta: { 'anthropic/sources': 's' }, command: 'git status' })).toEqual({ command: 'git status' })
})

// A hook ahead may set requestMeta for an MCP server (#3219): Claude Code's own reading of a call's
// arguments takes it off, so a call carrying it is the same call as one that does not, in a refusal
// key, a pass, and the text of a held call.
test('a call carrying requestMeta reads as the same call without it', () => {
  const plain = { tool: 'mcp__x__y', tool_use_id: 't3', query: 'q' }
  expect(JSON.stringify(toolArgs({ ...plain, requestMeta: { 'anthropic/sources': 'relay' } }))).toBe(JSON.stringify(toolArgs(plain)))
})

test('a call carrying none of the keys comes back whole, as a new object', () => {
  const e = { file_path: '/x/y.ts', content: 'z' }
  const args = toolArgs(e)
  expect(args).toEqual({ file_path: '/x/y.ts', content: 'z' })
  expect(args === e).toBe(false)
})

test('a key the engine set to undefined is taken off too, and any other key is an argument', () => {
  const args = toolArgs({ tool: 'Write', agentId: undefined, tool_use_id: undefined, requestMeta: undefined, input: { a: 1 }, meta: { k: 'v' } })
  expect(Object.keys(args).sort()).toEqual(['input', 'meta'])
})

// Claude Code 2.1.327 moves a call's own argument whose name clashes with one of its keys (an MCP
// tool taking an argument named tool or consent, say) into $shadowed, and its own reading of the
// arguments spreads that back (#3256). No call on this Mac carried one in a month (0 of 105,555), but
// any MCP server may name an argument so, and without this the argument was lost and $shadowed itself
// read as an argument.
test('an argument the engine moved into $shadowed comes back, and $shadowed is not an argument', () => {
  const args = toolArgs({ tool: 'mcp__x__y', tool_use_id: 't4', $shadowed: { tool: 'hammer', consent: 'yes' }, query: 'q' })
  expect(args).toEqual({ query: 'q', tool: 'hammer', consent: 'yes' })
})

test('a $shadowed that is not a plain object is taken off and restores nothing', () => {
  for (const shadowed of ['tool', ['tool'], null, 3]) {
    expect(toolArgs({ tool: 'Bash', $shadowed: shadowed, command: 'ls' })).toEqual({ command: 'ls' })
  }
})

test('the caller\'s event is left as it was', () => {
  const e = { tool: 'Bash', tool_use_id: 't2', command: 'pwd' }
  toolArgs(e)
  expect(e).toEqual({ tool: 'Bash', tool_use_id: 't2', command: 'pwd' })
})
