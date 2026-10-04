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

// Any mod's own tool result drawn as the boxed card (#663), from plain data: a title whose runs can
// carry colour (a state word leading it), then body lines. The blocked card is one use of it.
// A plugin in a test runs in its own environment, so the card is spelled inside the hook.
const carder: { name: string; register: Register } = {
  name: 'carder',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      const command = String((e as { command?: string }).command)
      try {
        const live = {
          toolUseId: String(e.tool_use_id),
          title: [{ text: 'Live:', color: 'success', bold: true }, { text: ' Filter bookings by venue' }],
          lines: [[{ text: 'The bookings list now filters by venue.' }], [{ text: 'See it: ' }, { text: 'https://slate.example.com', color: 'suggestion' }], [{ text: 'a dim line', dim: true }]],
        }
        await $.modkit.card(command === 'card' ? live : JSON.parse(command))
      } catch (err) {
        return { deny: `refused: ${String((err as Error).message ?? err)}` }
      }
      return { deny: 'carded' }
    })
  },
}

const resultRow = (id: string) => ({
  plugin: 'mod-kit',
  component: 'ToolResult' as const,
  props: { tool_use_id: id, tool: 'mcp__carder__card', output: 'card text', isErrored: false },
})

test("a mod's own tool result is drawn as the boxed card, its title's runs keeping their colour, on every surface", { plugins: [carder] }, async ($, on) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine row</Text>
  })
  const made = (await $.tool.call({ tool: 'Bash', command: 'card', tool_use_id: 'k1' } as never)) as { deny?: string; text?: string }
  expect(made.deny ?? made.text).toBe('carded')
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...resultRow('k1'), surface } as never)
    expect(await ui.find({ text: 'engine row' })).toBeUndefined()
    const box = await ui.find({ type: 'Box' })
    expect(box?.props.borderStyle).toBe('round')
    expect(box?.props.borderColor).toBe('gray')
    // A run is a leaf Text nested in its line's Text, so a line wraps as one piece of text.
    const texts = await ui.findAll({ type: 'Text' })
    const leaf = (text: string) => texts.find(t => t.text === text && t.children.every(c => typeof c === 'string'))
    const lineOf = (text: string) => texts.find(t => t.text === text && t.children.some(c => typeof c !== 'string'))
    expect(leaf('Live:')?.props.color).toBe('success')
    expect(leaf('Live:')?.props.bold).toBe(true)
    // The whole title is one line of bold text, the state word leading it.
    expect(lineOf('Live: Filter bookings by venue')?.props.bold).toBe(true)
    expect(leaf(' Filter bookings by venue')?.props.color).toBeUndefined()
    expect(leaf('The bookings list now filters by venue.')).toBeDefined()
    expect(lineOf('See it: https://slate.example.com')).toBeDefined()
    expect(leaf('https://slate.example.com')?.props.color).toBe('suggestion')
    expect(leaf('a dim line')?.props.dimColor).toBe(true)
    await ui.unmount()
  }
})

test('a card with no tool use id, no title or malformed lines is refused by name, and the row is left to Claude Code', { plugins: [carder] }, async ($, on) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine row</Text>
  })
  const send = async (card: unknown, id: string) => {
    const r = (await $.tool.call({ tool: 'Bash', command: JSON.stringify(card), tool_use_id: id } as never)) as { deny?: string; text?: string }
    return String(r.deny ?? r.text ?? '')
  }
  expect(await send({ toolUseId: '', title: [{ text: 'x' }], lines: [] }, 'r1')).toMatch(/refused: .*tool use id/)
  expect(await send({ toolUseId: 'r2', title: [], lines: [] }, 'r2')).toMatch(/refused: .*title/)
  expect(await send({ toolUseId: 'r3', title: [{ text: 'x' }], lines: ['a string'] }, 'r3')).toMatch(/refused: .*line 1/)
  expect(await send({ toolUseId: 'r4', title: [{ text: 'x', color: 3 }], lines: [] }, 'r4')).toMatch(/refused: .*colour/)
  expect(await send({ toolUseId: 'r5', title: [{ text: 'x' }], lines: [[{ text: 7 }]] }, 'r5')).toMatch(/refused: .*text/)
  for (const id of ['r2', 'r3', 'r4', 'r5']) {
    const ui = await $.ui.mount({ ...resultRow(id), surface: 'terminal' } as never)
    expect(await ui.find({ text: 'engine row' })).toBeDefined()
    await ui.unmount()
  }
})
