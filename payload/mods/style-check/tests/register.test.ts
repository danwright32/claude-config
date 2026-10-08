import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

// A stand-in for mod-kit: an inline plugin cannot reach this file's variables, so it reports each
// card as a transcript line the world collects.
// Its command reader asks the world (`__modkit`), which answers with a small stand-in for the real
// reader, enough for most commands below; where what the real reader gives matters (#974), a test
// gives the world that reading, written out (a mod cannot import another mod's files) and held to
// the real reader by mod-kit's commands.test.ts ("the readings other guards' tests take as given").
const standIn = (cmd: string): string[][] =>
  cmd
    .split(/&&|;|\n/)
    .map(part => {
      const words: string[] = []
      // A word may mix bare and quoted parts (X="a b" is one word), as the shell's are.
      for (const m of part.matchAll(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g)) words.push(m[0].replace(/"([^"]*)"|'([^']*)'/g, '$1$2'))
      while (words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0] ?? '')) words.shift()
      return words
    })
    .filter(w => w.length > 0)
const kit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        modkit: {
          blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
          commands: async (input: { command: string }) => {
            const r = await built.process.run(['__modkit', 'commands', JSON.stringify(input)])
            if (r.exitCode !== 0) throw new Error(r.stderr)
            return JSON.parse(r.stdout)
          },
          // A stand-in for mod-kit's git reader, enough for the commands below.
          git: async ({ words }: { words: string[] }) => {
            if ((words[0] ?? '').split('/').pop() !== 'git') return undefined
            const rest = words.slice(1)
            while (rest[0] === '-C' || rest[0] === '-c') rest.splice(0, 2)
            while ((rest[0] ?? '').startsWith('-')) rest.shift()
            return { sub: rest[0], args: rest.slice(1), dir: undefined }
          },
          // The kit's other members, which these tests never reach: each refuses by name if one ever is.
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
          pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
          workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
          repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
          branch: async () => { throw new Error("mod-kit's branch is not stood in by these tests") },
          bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
          clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
          screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
          // #939: a press raised by the kit's Button below, and whether a click lands; every Button here is clickable.
          press: async () => ({ isAnswered: false }),
          clickable: async () => true,
        },
      }
    })
  },
}
const withKit = { plugins: [kit] }

// The mod never judges a character itself: it hands the text to the push hook's own scanner,
// hooks/lib/style-scan.py, and relays its verdict, so the two cannot disagree (claude-config#609).
// The scanner is stood in for here (a test has no processes); its own rule, and the proof that the
// push hook and this --plain mode agree on one fixture set, live in test-check-style-guide.sh.
const SCRIPT = '/Users/x/.claude/hooks/lib/style-scan.py'
const DASH = '\u2014'
const BAD = `const label = "Loading ${DASH} please wait"`

type Run = { argv: readonly string[]; stdin: string }

const world = (on: On, opts: { scanner?: 'ok' | 'missing' | 'crash'; files?: Record<string, string>; store?: Record<string, unknown>; reads?: ReadonlyMap<string, string[][]> } = {}) => {
  const runs: Run[] = []
  const reached: string[] = []
  const toasts: string[] = []
  const logs: string[] = []
  const debug: string[] = []
  const cards: { toolUseId: string; guard: string; reason: string; safeWay?: string }[] = []
  mock.env(on, { HOME: '/Users/x' })
  mock.store(on, opts.store ?? {})
  on('process.run', ($, e) => {
    // The kit's command reader asking: answered, and never counted as a run of the scanner.
    if (e.argv[0] === '__modkit') {
      const { command } = JSON.parse(e.argv[2] as string) as { command: string }
      // A test giving readings has one for every command it runs, never the stand-in's (L143).
      const read = opts.reads ? opts.reads.get(command) : standIn(command)
      if (!read) return { value: { exitCode: 1, stdout: '', stderr: `no reading given for ${command}`, isStdoutTruncated: false, isStderrTruncated: false } }
      return { value: { exitCode: 0, stdout: JSON.stringify(read), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    const stdin = e.init?.stdin ?? ''
    runs.push({ argv: e.argv, stdin })
    if (opts.scanner === 'crash') {
      return { value: { exitCode: 1, stdout: '', stderr: 'SyntaxError: invalid syntax', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    if (opts.scanner === 'missing') {
      return { value: { exitCode: 2, stdout: '', stderr: "can't open file", isStdoutTruncated: false, isStderrTruncated: false } }
    }
    const lines = stdin.split('\n')
    const hits = lines.map((l, i) => (l.includes(DASH) ? `line ${i + 1}: ${l}` : '')).filter(Boolean)
    return { value: { exitCode: hits.length ? 1 : 0, stdout: hits.join('\n'), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.read', ($, e) => {
    const f = opts.files?.[e.path]
    if (f === undefined) throw new Error(`no file ${e.path}`)
    return { value: f }
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    if (e.text.startsWith('CARD ')) cards.push(JSON.parse(e.text.slice(5)))
    else if (e.to === 'debug') debug.push(e.text)
    else logs.push(e.text)
    return { value: undefined }
  })
  on('tool.call', ($, e) => {
    reached.push(e.tool)
    return { result: 'ran', text: 'ran' } as never
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', () => ({ value: undefined }) as never)
  return { runs, reached, toasts, logs, debug, cards }
}

const refused = (r: unknown): string => {
  const x = r as { deny?: string; text?: string; isError?: boolean }
  return x.deny ?? (x.isError ? (x.text ?? '') : '')
}

test('a Write carrying a dash is refused, naming the line', withKit, async ($, on) => {
  const w = world(on)
  const r = await $.tool.call({ tool: 'Write', file_path: '/repo/a.ts', content: `ok\n${BAD}\n`, tool_use_id: 'w1' } as never)
  expect(w.reached).not.toContain('Write')
  // Wording settled with Dan, 2026-10-03 (docs/mods-design.md).
  expect(refused(r)).toBe('Blocked: this text has a dash or emoji on line 2. Use a comma, colon or parentheses.')
  expect(w.cards).toEqual([{ toolUseId: 'w1', guard: 'Style check', reason: 'This text has a dash or emoji on line 2.', safeWay: 'Use a comma, colon or parentheses.' }])
  expect(w.toasts).toContain('Blocked a dash or emoji.')
  expect(w.runs[0]?.argv).toEqual(['python3', SCRIPT, '--plain', '--path', '/repo/a.ts'])
  expect(w.runs[0]?.stdin).toContain(BAD)
})

test('a clean Write goes through', withKit, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Write', file_path: '/repo/a.ts', content: 'all fine\n' } as never)
  expect(w.reached).toContain('Write')
})

test('an Edit is judged on its new text, not the old', withKit, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Edit', file_path: '/repo/a.ts', old_string: BAD, new_string: 'fixed' } as never)
  expect(w.reached).toContain('Edit')
  await $.tool.call({ tool: 'Edit', file_path: '/repo/a.ts', old_string: 'x', new_string: BAD } as never)
  expect(w.reached.filter(t => t === 'Edit').length).toBe(1)
})

test('a MultiEdit is judged on every new text', withKit, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'MultiEdit', file_path: '/repo/a.ts', edits: [{ old_string: 'a', new_string: 'b' }, { old_string: 'c', new_string: BAD }] } as never)
  expect(w.reached).not.toContain('MultiEdit')
})

test('a NotebookEdit is judged on its new source', withKit, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'NotebookEdit', notebook_path: '/repo/n.ipynb', new_source: BAD } as never)
  expect(w.reached).not.toContain('NotebookEdit')
})

test('a commit message carrying a dash is refused', withKit, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Bash', command: `git commit -m "Fix ${DASH} again"` } as never)
  expect(w.reached).not.toContain('Bash')
})

test('a commit message read from a file is judged too', withKit, async ($, on) => {
  const w = world(on, { files: { '/tmp/msg.txt': `Subject ${DASH} body\n` } })
  await $.tool.call({ tool: 'Bash', command: 'git commit -F /tmp/msg.txt' } as never)
  expect(w.reached).not.toContain('Bash')
})

test('a git command that only mentions commit is not scanned (lessons review)', withKit, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Bash', command: `git log --grep=commit --format="%s ${DASH}"` } as never)
  expect(w.reached).toContain('Bash')
  expect(w.runs.length).toBe(0)
})

test('a commit made with git -C is still judged', withKit, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Bash', command: `git -C /repo commit -m "x ${DASH} y"` } as never)
  expect(w.reached).not.toContain('Bash')
})

test('a gh pr body carrying a dash is refused', withKit, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Bash', command: `gh pr create --title t --body "x ${DASH} y"` } as never)
  expect(w.reached).not.toContain('Bash')
})

test('a gh issue comment read from a body file is judged', withKit, async ($, on) => {
  const w = world(on, { files: { '/tmp/b.md': `note ${DASH}\n` } })
  await $.tool.call({ tool: 'Bash', command: 'gh issue comment 12 --body-file /tmp/b.md' } as never)
  expect(w.reached).not.toContain('Bash')
})

// #974: mod-kit's command reader now gives the commands a substitution runs as commands of their own,
// so a commit inside $(...) or backticks has its message judged as one on the command line does.
// Quoted, the commit is text: no message command runs, and nothing is scanned.
const FIX = `Fix ${DASH} again`
const READ_974 = new Map<string, string[][]>([
  [`x=$(git commit -m "${FIX}")`, [['git', 'commit', '-m', FIX]]],
  ['echo "made `git commit -F /tmp/msg.txt`"', [['git', 'commit', '-F', '/tmp/msg.txt'], ['echo', 'made `git commit -F /tmp/msg.txt`']]],
  [`cat <<EOF\n$(git commit -m "${FIX}")\nEOF`, [['git', 'commit', '-m', FIX], ['cat', '<<EOF']]],
  [`echo '$(git commit -m "${FIX}")'`, [['echo', `$(git commit -m "${FIX}")`]]],
  [`cat <<'EOF'\n\`git commit -m "${FIX}"\`\nEOF`, [['cat', '<<EOF']]],
])
test('a commit a command substitution runs is judged; quoted, it is text (#974)', withKit, async ($, on) => {
  const w = world(on, { files: { '/tmp/msg.txt': `Subject ${DASH} body\n` }, reads: READ_974 })
  const [judged, text] = [[...READ_974.keys()].slice(0, 3), [...READ_974.keys()].slice(3)]
  for (const command of judged) {
    expect(`${command}: ${refused(await $.tool.call({ tool: 'Bash', command } as never))}`).toContain('Blocked: this text has a dash or emoji')
  }
  expect(w.reached).toEqual([])
  for (const command of text) await $.tool.call({ tool: 'Bash', command } as never)
  expect(w.reached).toEqual(['Bash', 'Bash'])
})

test('an ordinary command is not scanned at all', withKit, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Bash', command: `grep -n "${DASH}" file.txt` } as never)
  expect(w.reached).toContain('Bash')
  expect(w.runs.length).toBe(0)
})

for (const tool of ['mcp__claude_ai_Slack__slack_send_message', 'mcp__claude_ai_Slack__slack_send_message_draft', 'mcp__claude_ai_Slack__slack_schedule_message']) {
  test(`a Slack message through ${tool.split('__').pop()} is judged`, withKit, async ($, on) => {
    const w = world(on)
    await $.tool.call({ tool, channel_id: 'C1', message: `hi ${DASH} there` } as never)
    expect(w.reached).not.toContain(tool)
  })
}

test('when the scanner cannot run, the write goes through and says it was not checked', withKit, async ($, on) => {
  const w = world(on, { scanner: 'missing' })
  await $.tool.call({ tool: 'Write', file_path: '/repo/a.ts', content: BAD } as never)
  expect(w.reached).toContain('Write')
  expect(w.logs).toContain("Style check couldn't run, so this wasn't checked for dashes or emoji. The push check still will.")
  // The cause goes to the debug log, so it is not lost (lessons review); the visible line is Dan's.
  expect(w.debug.join('\n')).toContain("can't open file")
})

test('the could not run note is said once a session, not on every write (lessons review)', withKit, async ($, on) => {
  const w = world(on, { scanner: 'missing' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Write', file_path: '/repo/a.ts', content: BAD } as never)
  await $.tool.call({ tool: 'Write', file_path: '/repo/b.ts', content: BAD } as never)
  expect(w.logs.filter(l => l.startsWith("Style check couldn't run")).length).toBe(1)
})

test('a -F inside a quoted commit message is not read as a message file (lessons review)', withKit, async ($, on) => {
  const w = world(on, { files: { '/tmp/b.md': `note ${DASH}\n` } })
  await $.tool.call({ tool: 'Bash', command: 'git commit -m "explain the -F /tmp/b.md option"' } as never)
  expect(w.reached).toContain('Bash')
})

test('python failing with exit 1 and nothing found is not read as a dash (lessons review)', withKit, async ($, on) => {
  const w = world(on, { scanner: 'crash' })
  // Non-ASCII but allowed, so the scanner has to be asked, and fails.
  await $.tool.call({ tool: 'Write', file_path: '/repo/a.ts', content: 'caf\u00e9 text' } as never)
  expect(w.reached).toContain('Write')
  expect(w.logs).toContain("Style check couldn't run, so this wasn't checked for dashes or emoji. The push check still will.")
})

test('plain ASCII text never starts the scanner, since every forbidden character is outside it (lessons review)', withKit, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Write', file_path: '/repo/a.ts', content: 'all plain text, with - hyphens\n' } as never)
  expect(w.reached).toContain('Write')
  expect(w.runs.length).toBe(0)
})

test('two replies counted at once both land (lessons review, L690)', withKit, async ($, on) => {
  const w = world(on, { store: { chatHits: 0 } })
  on('session.append', ($, e, next) => next(e))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  const row = (uuid: string) => ({
    door: 'response',
    origin: { kind: 'model', model: 'm' },
    uuid,
    message: { type: 'assistant', role: 'assistant', content: [{ type: 'text', text: `one ${DASH} two` }] },
  })
  const append = async (uuid: string) => {
    try {
      await $.session.append(row(uuid) as never)
    } catch (err) {
      if (!/no implementation for session.append/.test(String(err))) throw err
    }
  }
  await Promise.all([append('a'), append('b')])
  const out = await $.command.run({ command: 'style-count', args: '', origin: { kind: 'human' }, presentation: {} } as never)
  expect((out as { text?: string }).text).toBe('Replies with a dash or emoji: 2 this session, 2 in total.')
  void w
})

test('a message file given as a quoted path is still read', withKit, async ($, on) => {
  const w = world(on, { files: { '/tmp/my msg.txt': `Subject ${DASH} body\n` } })
  await $.tool.call({ tool: 'Bash', command: 'git commit -F "/tmp/my msg.txt"' } as never)
  expect(w.reached).not.toContain('Bash')
})

test('a chat reply the scanner could not check is not read as clean (lessons review)', withKit, async ($, on) => {
  const w = world(on, { scanner: 'missing', store: { chatHits: 0 } })
  on('session.append', ($, e, next) => next(e))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  try {
    await $.session.append({
      door: 'response',
      origin: { kind: 'model', model: 'm' },
      uuid: 'r1',
      message: { type: 'assistant', role: 'assistant', content: [{ type: 'text', text: 'a caf\u00e9 reply' }] },
    } as never)
  } catch (err) {
    if (!/no implementation for session.append/.test(String(err))) throw err
  }
  const out = await $.command.run({ command: 'style-count', args: '', origin: { kind: 'human' }, presentation: {} } as never)
  expect((out as { text?: string }).text).toBe('Replies with a dash or emoji: 0 this session, 0 in total. 1 reply this session could not be checked.')
})

test('chat replies with a dash are counted silently and read with /style-count', withKit, async ($, on) => {
  const w = world(on, { store: { chatHits: 5 } })
  const row = (text: string) => ({
    door: 'response',
    origin: { kind: 'model', model: 'm' },
    uuid: 'r' + text.length,
    message: { type: 'assistant', role: 'assistant', content: [{ type: 'text', text }] },
  })
  on('session.append', ($, e, next) => next(e))
  const append = async (text: string) => {
    try {
      await $.session.append(row(text) as never)
    } catch (err) {
      if (!/no implementation for session.append/.test(String(err))) throw err
    }
  }
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await append(`a reply ${DASH} with a dash`)
  await append('a clean reply')
  await append(`another ${DASH} one`)
  expect(w.toasts.length).toBe(0)
  const out = await $.command.run({ command: 'style-count', args: '', origin: { kind: 'human' }, presentation: {} } as never)
  expect((out as { text?: string }).text).toBe('Replies with a dash or emoji: 2 this session, 7 in total.')
})
