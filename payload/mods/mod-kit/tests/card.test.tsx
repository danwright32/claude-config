import { expect, test } from 'claude-code/testing'
import type { Register } from 'claude-code'

// A stand-in guard that blocks every Bash call through the kit, as the real guards do.
const guard: { name: string; register: Register } = {
  name: 'fake-guard',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      await $.modkit.blocked({
        toolUseId: String(e.tool_use_id),
        guard: 'Secret guard',
        reason: 'This would print GITHUB_TOKEN.',
        safeWay: 'Check it without printing: test -n, its length, or gh auth status.',
      })
      return { deny: 'Blocked: this would print GITHUB_TOKEN. Check it without printing: test -n, its length, or gh auth status.' }
    })
  },
}

const row = (id: string) => ({
  plugin: 'mod-kit',
  component: 'ToolResult' as const,
  props: { tool_use_id: id, tool: 'Bash', output: 'Blocked: this would print GITHUB_TOKEN.', isErrored: true },
})

test('a blocked call is drawn as the grey card on every surface', { plugins: [guard] }, async ($, on) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  // Claude Code's own row, beneath the kit: what is drawn when no guard blocked the call.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine row</Text>
  })
  await $.tool.call({ tool: 'Bash', command: 'echo $GITHUB_TOKEN', tool_use_id: 't1' } as never)
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...row('t1'), surface } as never)
    expect(await ui.find({ text: 'Blocked by Secret guard' })).toBeDefined()
    expect(await ui.find({ text: 'This would print GITHUB_TOKEN.' })).toBeDefined()
    expect(await ui.find({ text: /test -n/ })).toBeDefined()
    await ui.unmount()
  }
})

// A note under the safe way: something the guard could not do, such as tell the other session.
const noting: { name: string; register: Register } = {
  name: 'noting-guard',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      await $.modkit.blocked({
        toolUseId: String(e.tool_use_id),
        guard: 'Collision guard',
        reason: 'Another session is working on app.ts.',
        safeWay: 'Move this work to its own worktree and redo it there.',
        note: 'The other session could not be told: Classifier unavailable.',
      })
      return { deny: 'Blocked.' }
    })
  },
}

test('a note is drawn on the card under the safe way', { plugins: [noting] }, async ($, on) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine row</Text>
  })
  await $.tool.call({ tool: 'Bash', command: 'x', tool_use_id: 'n1' } as never)
  const ui = await $.ui.mount({ ...row('n1'), surface: 'terminal' } as never)
  expect(await ui.find({ text: 'The other session could not be told: Classifier unavailable.' })).toBeDefined()
  await ui.unmount()
})

test('a call no guard blocked is left to Claude Code', { plugins: [guard] }, async ($, on) => {
  // Claude Code's own row, beneath the kit: what is drawn when no guard blocked the call.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine row</Text>
  })
  const ui = await $.ui.mount({ ...row('other'), surface: 'terminal' } as never)
  expect(await ui.find({ text: /Blocked by/ })).toBeUndefined()
  expect(await ui.find({ text: 'engine row' })).toBeDefined()
  await ui.unmount()
})

// The shared command reader, reached as a noun so every guard uses the one copy (L613).
const reader: { name: string; register: Register } = {
  name: 'reader',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => ({ deny: JSON.stringify(await $.modkit.commands({ command: String((e as { command?: string }).command) })) }))
  },
}

test('the command reader is shared as $.modkit.commands', { plugins: [reader] }, async ($, on) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  const r = (await $.tool.call({ tool: 'Bash', command: 'sudo cat .env && git status' } as never)) as { deny?: string; text?: string }
  expect(JSON.parse(r.deny ?? r.text ?? '[]')).toEqual([['cat', '.env'], ['git', 'status']])
})
