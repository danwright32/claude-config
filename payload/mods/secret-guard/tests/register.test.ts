import { expect, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

// A stand-in for mod-kit, which draws the grey card. An inline plugin runs in an environment of
// its own and cannot reach this file's variables, so it reports each card as a transcript line
// the world below collects (measured 2026-10-03). Its command reader is a small stand-in for the
// real one (a mod cannot import another mod's files), enough for the commands below; the real
// reader is tested in mod-kit.
const kit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    const read = (cmd: string): string[][] =>
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
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        modkit: {
          blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
          commands: async ({ command }: { command: string }) => read(command),
          // The kit's other members, which these tests never reach: each refuses by name if one ever is.
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
          git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
          pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
          workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
          bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
          clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
          screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
        },
      }
    })
  },
}
const withKit = { plugins: [kit] }

const KNOWN = 'kN0wn-S3cr3t-v4lue-zz'
const ENV_SECRET = 'fr0m-the-env-f1le-yy'
const GH_TOKEN = 'gho_' + 'Q'.repeat(36)

// The world beneath the mod: the environment, the gh token and one project .env file. Every tool
// call that gets past the mod is answered here, and recorded, so a test can tell a refusal (the
// call never arrived) from a pass.
const world = (on: On) => {
  const reached: string[] = []
  const toasts: string[] = []
  const cards: { toolUseId: string; guard: string; reason: string; safeWay?: string }[] = []
  on('process.run', ($, e) => {
    const cmd = e.argv.join(' ')
    if (cmd === 'env') return { value: { exitCode: 0, stdout: `HOME=/Users/x\nAPI_TOKEN=${KNOWN}\n`, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    if (cmd === 'gh auth token') return { value: { exitCode: 0, stdout: `${GH_TOKEN}\n`, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    if (cmd.startsWith('git rev-parse')) return { value: { exitCode: 0, stdout: '/repo\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    return { value: { exitCode: 1, stdout: '', stderr: 'unexpected', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.list', ($, e) => ({ value: e.path === '/repo' ? [{ name: '.env', kind: 'file' as const }, { name: 'src', kind: 'dir' as const }] : [] }) as never)
  on('fs.read', ($, e) => {
    if (e.path === '/repo/.env') return { value: `SUPABASE_SERVICE_ROLE_KEY=${ENV_SECRET}\nPORT=3000\n` }
    throw new Error(`no file ${e.path}`)
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    if (e.text.startsWith('CARD ')) cards.push(JSON.parse(e.text.slice(5)))
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', ($, e) => {
    reached.push(e.tool)
    return { result: 'ran', text: 'ran' } as never
  })
  return { reached, toasts, cards }
}

const appendRow = async ($: { session: { append: (e: never) => Promise<unknown> } }, row: unknown) => {
  try {
    await $.session.append(row as never)
  } catch (err) {
    if (!/no implementation for session.append/.test(String(err))) throw err
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const start = async ($: { session: { start: (e: { cwd: string; surface: 'terminal'; isInteractive: boolean }) => Promise<unknown> } }) =>
  $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

test('a command that prints a secret is refused and a toast says so', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  const r = await $.tool.call({ tool: 'Bash', command: 'cat .env', tool_use_id: 'c1' } as never)
  expect(String((r as { text?: string }).text ?? (r as { deny?: string }).deny)).toBe(
    'Blocked: this would print the secrets in .env. Check it without printing: test -n, its length, or gh auth status.',
  )
  expect(w.reached).not.toContain('Bash')
  expect(w.toasts).toContain('Blocked a command that would print a secret.')
  expect(w.cards[w.cards.length - 1]).toEqual({
    toolUseId: 'c1',
    guard: 'Secret guard',
    reason: 'This would print the secrets in .env.',
    safeWay: 'Check it without printing: test -n, its length, or gh auth status.',
  })
})

test('an ordinary command runs', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'ls -la' } as never)
  expect(w.reached).toContain('Bash')
})

test('a secret from the environment in a commit message is refused', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  const r = await $.tool.call({ tool: 'Bash', command: `git commit -m "token ${KNOWN}"`, tool_use_id: 'c2' } as never)
  expect(w.reached).not.toContain('Bash')
  expect(String((r as { text?: string }).text ?? (r as { deny?: string }).deny)).toBe('Blocked: this message contains a secret. Refer to it by its name, not its value.')
  expect(w.toasts).toContain('Blocked a message containing a secret.')
  expect(w.cards[w.cards.length - 1]).toEqual({ toolUseId: 'c2', guard: 'Secret guard', reason: 'This message contains a secret.', safeWay: 'Refer to it by its name, not its value.' })
})

test('a secret from the project .env file in a gh body is refused', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'Bash', command: `gh issue create --title t --body "uses ${ENV_SECRET}"` } as never)
  expect(w.reached).not.toContain('Bash')
})

test('the gh token written into a source file is refused', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'Write', file_path: '/repo/src/a.ts', content: `const t = '${GH_TOKEN}'` } as never)
  expect(w.reached).not.toContain('Write')
})

test('a secret written into a .env file is allowed', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'Write', file_path: '/repo/.env.local', content: `API_TOKEN=${KNOWN}\n` } as never)
  expect(w.reached).toContain('Write')
})

test('a secret MultiEdited into a .env file is guarded from then on', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  const fresh = 'n3wly-wr1tten-v4lue-qq'
  await $.tool.call({ tool: 'MultiEdit', file_path: '/repo/.env', edits: [{ old_string: 'A=1', new_string: `API_TOKEN=${fresh}` }] } as never)
  expect(w.reached).toContain('MultiEdit')
  await $.tool.call({ tool: 'Bash', command: `git commit -m "${fresh}"` } as never)
  expect(w.reached).not.toContain('Bash')
})

test('a gh token that cannot be read is named in the log', withKit, async ($, on) => {
  const logs: string[] = []
  on('process.run', ($, e) => {
    const cmd = e.argv.join(' ')
    if (cmd === 'env') return { value: { exitCode: 0, stdout: 'HOME=/x\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    return { value: { exitCode: 1, stdout: '', stderr: 'not logged in', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.list', () => ({ value: [] }) as never)
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await start($)
  expect(logs).toContain("Secret guard couldn't read the gh token, so it's guarded by its shape only.")
})

test('a secret in a Slack message is refused', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'mcp__claude_ai_Slack__slack_send_message', channel_id: 'C1', message: `here ${KNOWN}` } as never)
  expect(w.reached).not.toContain('mcp__claude_ai_Slack__slack_send_message')
})

test('a secret in a tool result is scrubbed before it is kept, with a toast', withKit, async ($, on) => {
  const w = world(on)
  let stored = ''
  // In 2.1.288 a test cannot be the store: a bottom that answers is skipped, and one that calls
  // next reaches nothing. So the row the mod passed down is recorded here and the store's own
  // rejection, which comes after, is caught below (measured 2026-10-03).
  on('session.append', ($, e, next) => {
    stored = JSON.stringify(e.message.content)
    return next(e)
  })
  await start($)
  await appendRow($, {
    door: 'tool-result',
    origin: { kind: 'tool', tool: 'Bash' },
    uuid: 'u1',
    message: {
      type: 'user',
      role: 'user',
      content: [{ type: 'tool_result', tool_use_id: 't1', content: [{ type: 'text', text: `out: ${KNOWN} and ${ENV_SECRET}` }] }],
    },
  })
  expect(stored).not.toContain(KNOWN)
  expect(stored).not.toContain(ENV_SECRET)
  expect(stored).toContain('[REDACTED]')
  expect(w.toasts).toContain("Hid 2 secrets from a command's output.")
})

// #707: a mod that answers a tool call itself never calls next, so a hook beneath it never sees the
// call: manual steps, is it live, handoff and the job watcher all sort above this mod. The answering
// mod here stands in for them (a mod's tests cannot load another mod's files), loaded above this
// one: it asks $.secretGuard.screen before it acts, and says it acted by a toast.
const answerer: { name: string; tier: 'prepend'; register: Register } = {
  name: 'manual-steps',
  tier: 'prepend',
  register: on => {
    // Its tool is matched in the hook, since a stand-in's tool is in no list of tools Claude Code's types name.
    on('tool.call', async ($, e, next) => {
      if (String(e.tool) !== 'mcp__manual-steps__steps') return next(e)
      const refused = await $.secretGuard.screen(e as never)
      if (refused) return refused
      await $.ui.toast('ACTED on the steps')
      return { result: 'Pinned.' } as never
    })
  },
}
const steps = (value: string, id = 's1') => ({ tool: 'mcp__manual-steps__steps', tool_use_id: id, heading: 'Stripe', steps: [{ title: 'Paste the key', value, checked: 'not-done' }] }) as never

test('a call another mod answers itself is refused before it acts when it carries a secret, with the card and toast (#707)', { plugins: [kit, answerer] }, async ($, on) => {
  const w = world(on)
  await start($)
  const r = await $.tool.call(steps(`sk_live_${KNOWN}`, 'm1'))
  expect(String((r as { text?: string }).text ?? (r as { deny?: string }).deny)).toBe('Blocked: this message contains a secret. Refer to it by its name, not its value.')
  expect(w.toasts).toEqual(['Blocked a message containing a secret.'])
  expect(w.cards).toEqual([{ toolUseId: 'm1', guard: 'Secret guard', reason: 'This message contains a secret.', safeWay: 'Refer to it by its name, not its value.' }])
  // The same mod's clean call goes ahead: the refusal above was the screen, not the stand-in.
  const ok = await $.tool.call(steps('pk_test_public', 'm2'))
  expect((ok as { result?: unknown }).result).toBe('Pinned.')
  expect(w.toasts).toEqual(['Blocked a message containing a secret.', 'ACTED on the steps'])
})

test('a token shaped value is refused through the screen too, before the guard has read any source (#707)', { plugins: [kit, answerer] }, async ($, on) => {
  const w = world(on)
  const r = await $.tool.call(steps(GH_TOKEN, 'm3'))
  expect(String((r as { text?: string }).text ?? (r as { deny?: string }).deny)).toContain('contains a secret')
  expect(w.toasts).not.toContain('ACTED on the steps')
  // The answering mod's hook ran rather than failing through to this mod's own tool.call hook: its
  // clean call is answered by it.
  expect((await $.tool.call(steps('pk_test_public', 'm4')) as { result?: unknown }).result).toBe('Pinned.')
})

// The screen's check failing part way (here mod-kit cannot draw the card) refuses the call, since a
// screen that fails open would let the secret through to the answering mod (L42).
const brokenKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return { ...built, modkit: { blocked: async () => { throw new Error('the card could not be kept') }, commands: async () => [] } } as never
    })
  },
}
test('a screen whose check fails refuses the call rather than let it through (#707, L42)', { plugins: [brokenKit, answerer] }, async ($, on) => {
  const w = world(on)
  await start($)
  const r = await $.tool.call(steps(KNOWN, 'm5'))
  expect(String((r as { text?: string }).text ?? (r as { deny?: string }).deny)).toBe(
    'Blocked: the secret guard could not check this for secrets, so it did not run. Try it again; if it fails the same way, tell Dan.',
  )
  expect(w.toasts).not.toContain('ACTED on the steps')
})

test('a tool result with no secret is kept as it was', withKit, async ($, on) => {
  const w = world(on)
  let stored = ''
  // In 2.1.288 a test cannot be the store: a bottom that answers is skipped, and one that calls
  // next reaches nothing. So the row the mod passed down is recorded here and the store's own
  // rejection, which comes after, is caught below (measured 2026-10-03).
  on('session.append', ($, e, next) => {
    stored = JSON.stringify(e.message.content)
    return next(e)
  })
  await start($)
  await appendRow($, {
    door: 'tool-result',
    origin: { kind: 'tool', tool: 'Bash' },
    uuid: 'u2',
    message: { type: 'user', role: 'user', content: [{ type: 'tool_result', tool_use_id: 't2', content: 'all fine' }] },
  })
  expect(stored).toContain('all fine')
  expect(w.toasts.length).toBe(0)
})
