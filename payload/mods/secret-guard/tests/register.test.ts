import { expect, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

// A stand-in for mod-kit, which draws the grey card. An inline plugin runs in an environment of
// its own and cannot reach this file's variables, so it reports each card as a transcript line
// the world below collects (measured 2026-10-03).
const kit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return { ...built, modkit: { blocked: (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)) } }
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
