import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const KNOWN = 'kN0wn-S3cr3t-v4lue-zz'
const ENV_SECRET = 'fr0m-the-env-f1le-yy'
const GH_TOKEN = 'gho_' + 'Q'.repeat(36)

// The world beneath the mod: the environment, the gh token and one project .env file. Every tool
// call that gets past the mod is answered here, and recorded, so a test can tell a refusal (the
// call never arrived) from a pass.
const world = (on: On) => {
  const reached: string[] = []
  const toasts: string[] = []
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
  on('ui.log', () => ({ value: undefined }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', ($, e) => {
    reached.push(e.tool)
    return { result: 'ran', text: 'ran' } as never
  })
  return { reached, toasts }
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

test('a command that prints a secret is refused and a toast says so', async ($, on) => {
  const w = world(on)
  await start($)
  const r = await $.tool.call({ tool: 'Bash', command: 'cat .env' } as never)
  expect(String((r as { text?: string }).text ?? (r as { deny?: string }).deny)).toMatch(/refused/)
  expect(w.reached).not.toContain('Bash')
  expect(w.toasts.join('\n')).toMatch(/secret-guard/)
})

test('an ordinary command runs', async ($, on) => {
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'ls -la' } as never)
  expect(w.reached).toContain('Bash')
})

test('a secret from the environment in a commit message is refused', async ($, on) => {
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'Bash', command: `git commit -m "token ${KNOWN}"` } as never)
  expect(w.reached).not.toContain('Bash')
})

test('a secret from the project .env file in a gh body is refused', async ($, on) => {
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'Bash', command: `gh issue create --title t --body "uses ${ENV_SECRET}"` } as never)
  expect(w.reached).not.toContain('Bash')
})

test('the gh token written into a source file is refused', async ($, on) => {
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'Write', file_path: '/repo/src/a.ts', content: `const t = '${GH_TOKEN}'` } as never)
  expect(w.reached).not.toContain('Write')
})

test('a secret written into a .env file is allowed', async ($, on) => {
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'Write', file_path: '/repo/.env.local', content: `API_TOKEN=${KNOWN}\n` } as never)
  expect(w.reached).toContain('Write')
})

test('a secret in a Slack message is refused', async ($, on) => {
  const w = world(on)
  await start($)
  await $.tool.call({ tool: 'mcp__claude_ai_Slack__slack_send_message', channel_id: 'C1', message: `here ${KNOWN}` } as never)
  expect(w.reached).not.toContain('mcp__claude_ai_Slack__slack_send_message')
})

test('a secret in a tool result is scrubbed before it is kept, with a toast', async ($, on) => {
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
  expect(w.toasts.join('\n')).toMatch(/scrubbed/)
})

test('a tool result with no secret is kept as it was', async ($, on) => {
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
