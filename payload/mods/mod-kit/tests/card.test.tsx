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

// #698: the settled look of the blocked card (docs/mods-design.md, Guard surfaces): a grey rounded
// border, the title in bold, the reason in the terminal's own colour, then the safe way and any note
// in dim text. Only the words were checked, so plain text or a coloured border would have passed.
test('the blocked card keeps its settled look on every surface: a grey round border, the safe way and the note dim', { plugins: [noting] }, async ($, on) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine row</Text>
  })
  await $.tool.call({ tool: 'Bash', command: 'x', tool_use_id: 'look1' } as never)
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...row('look1'), surface } as never)
    const box = await ui.find({ type: 'Box' })
    expect(box?.props.borderStyle).toBe('round')
    expect(box?.props.borderColor).toBe('gray')
    const texts = await ui.findAll({ type: 'Text' })
    const leaf = (text: string) => texts.find(t => t.text === text && t.children.every(c => typeof c === 'string'))
    const lineOf = (text: string) => texts.find(t => t.text === text && t.children.some(c => typeof c !== 'string'))
    expect(lineOf('Blocked by Collision guard')?.props.bold).toBe(true)
    expect(leaf('Blocked by Collision guard')?.props.color).toBeUndefined()
    expect(leaf('Another session is working on app.ts.')?.props.dimColor).toBeFalsy()
    expect(leaf('Another session is working on app.ts.')?.props.color).toBeUndefined()
    expect(leaf('Move this work to its own worktree and redo it there.')?.props.dimColor).toBe(true)
    expect(leaf('The other session could not be told: Classifier unavailable.')?.props.dimColor).toBe(true)
    await ui.unmount()
  }
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

// #698: a reader that judges what a heredoc feeds asks for its body through the kit, as plain data.
const heredocReader: { name: string; register: Register } = {
  name: 'heredoc-reader',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => ({ deny: JSON.stringify(await $.modkit.pipeline({ command: String((e as { command?: string }).command) })) }))
  },
}

// #712: and the program each command runs, read once by the kit, with what that program can do.
test("a heredoc's body, and the program each command runs, are shared on $.modkit.pipeline's commands", { plugins: [heredocReader] }, async ($, on) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  const r = (await $.tool.call({ tool: 'Bash', command: "python3 - <<'EOF'\nimport os; os.system('ls')\nEOF" } as never)) as { deny?: string; text?: string }
  expect(JSON.parse(r.deny ?? r.text ?? '[]')).toEqual([
    {
      words: ['python3', '-', '<<EOF'],
      heredocs: [{ word: 2, body: "import os; os.system('ls')", quoted: true }],
      language: 'python',
      program: { text: "import os; os.system('ls')", stdin: true },
      verdict: { does: 'run a process', seen: 'os.system' },
    },
  ])
})

// #726: the working tree a path sits in, asked of the disk through the kit. The reader stands in
// for ask before saving, and the disk is the test's: a .git folder at /tmp/repo and nowhere else.
const treeReader: { name: string; register: Register } = {
  name: 'tree-reader',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      try {
        return { deny: JSON.stringify(await $.modkit.workingTree({ path: String((e as { command?: string }).command) })) }
      } catch (err) {
        return { deny: `refused: ${String((err as Error).message ?? err)}` }
      }
    })
  },
}

test('the working tree a path sits in is shared as $.modkit.workingTree, a look the disk cannot answer refused', { plugins: [treeReader] }, async ($, on) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('fs.exists', ($, e) => {
    if (e.path === '/locked/.git') throw new Error('the disk is gone')
    return { value: e.path === '/tmp/repo/.git' } as never
  })
  const ask = async (path: string) => {
    const r = (await $.tool.call({ tool: 'Bash', command: path } as never)) as { deny?: string; text?: string }
    return r.deny ?? r.text
  }
  expect(await ask('/tmp/repo/docs/CLAUDE.md')).toBe('"/tmp/repo"')
  expect(await ask('/tmp/backup/CLAUDE.md')).toBe('null')
  // The engine skips a hook that throws, so the failed look reaches the kit as no answer at all;
  // either way it is refused, never taken for "no checkout".
  expect(await ask('/locked/CLAUDE.md')).toMatch(/^refused: /)
  expect(await ask('relative/CLAUDE.md')).toBe('refused: a working tree is found from an absolute path, not relative/CLAUDE.md')
})

// #978: where a checkout stands, read once by the kit for every mod. The reader stands in for the
// design round guard; the disk (a .git folder at /tmp/repo) and git's answers are the test's.
const branchReader: { name: string; register: Register } = {
  name: 'branch-reader',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      try {
        return { deny: JSON.stringify(await $.modkit.branch({ path: String((e as { command?: string }).command) })) }
      } catch (err) {
        return { deny: `refused: ${String((err as Error).message ?? err)}` }
      }
    })
  },
}

test('where a checkout stands is shared as $.modkit.branch: null in no checkout, git asked with a bound in one', { plugins: [branchReader] }, async ($, on) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('fs.exists', ($, e) => {
    if (e.path === '/locked/.git') throw new Error('the disk is gone')
    return { value: e.path === '/tmp/repo/.git' } as never
  })
  const runs: { argv: string; timeoutMs?: number }[] = []
  const out = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never
  on('process.run', ($, e) => {
    runs.push({ argv: e.argv.join(' '), timeoutMs: e.init?.timeoutMs })
    const sub = e.argv.slice(3).join(' ')
    if (sub === 'branch --show-current') return out('41-header\n')
    if (sub === 'worktree list --porcelain') return out('worktree /tmp/repo\nHEAD a\n')
    return out('origin/main\n')
  })
  const ask = async (path: string) => {
    const r = (await $.tool.call({ tool: 'Bash', command: path } as never)) as { deny?: string; text?: string }
    return r.deny ?? r.text
  }
  expect(JSON.parse(String(await ask('/tmp/repo/app/page.tsx')))).toEqual({ root: '/tmp/repo', main: '/tmp/repo', branch: '41-header', defaultBranch: 'main', isDefault: false, issues: [41] })
  expect(runs.map(r => r.argv).sort()).toEqual(['git -C /tmp/repo branch --show-current', 'git -C /tmp/repo symbolic-ref --short refs/remotes/origin/HEAD', 'git -C /tmp/repo worktree list --porcelain'])
  // Each read is bounded well inside the 10 seconds a noun has (docs/mods-design.md, standing rule 4).
  for (const r of runs) expect(r.timeoutMs).toBe(3_000)
  runs.length = 0
  expect(await ask('/tmp/backup/page.tsx')).toBe('null')
  expect(runs).toEqual([])
  expect(await ask('/locked/page.tsx')).toMatch(/^refused: /)
})

// #951: a session's repository, read once by the kit for every mod: the GitHub repository and the
// name, each its own answer. The reader stands in for a mod, handing the kit what
// $.session.repo() gives.
const repoReader: { name: string; register: Register } = {
  name: 'repo-reader',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => ({ deny: JSON.stringify(await $.modkit.repo(JSON.parse(String((e as { command?: string }).command)))) }))
  },
}

test("a session's repository is read as $.modkit.repo: its GitHub repository and its name, each its own answer", { plugins: [repoReader] }, async ($, on) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  const ask = async (repo: unknown) => {
    const r = (await $.tool.call({ tool: 'Bash', command: JSON.stringify(repo) } as never)) as { deny?: string; text?: string }
    return JSON.parse(r.deny ?? r.text ?? 'null')
  }
  expect(await ask({ root: '/Users/x/Apps/folder', remote: 'git@github.com:danwright32/Overture.git' })).toEqual({ github: 'danwright32/Overture', name: 'Overture' })
  expect(await ask({ root: '/Users/x/Apps/claude-config/.claude/worktrees/agent-1', remote: null })).toEqual({ github: null, name: 'claude-config' })
  expect(await ask({ remote: 'https://gitlab.com/team/thing.git' })).toEqual({ github: null, name: 'thing' })
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
