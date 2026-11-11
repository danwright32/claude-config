import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
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
          repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
          gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
          mergeHelper: async () => { throw new Error("mod-kit's mergeHelper is not stood in by these tests") },
          goal: async () => { throw new Error("mod-kit's goal is not stood in by these tests") },
          ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
          linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
          branch: async () => { throw new Error("mod-kit's branch is not stood in by these tests") },
          bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
          clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
          screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
          // #939: a press raised by the kit's Button below, and whether a click lands; every Button here is clickable.
          press: async () => ({ isAnswered: false }),
          clickable: async () => true,
          isDans: async () => { throw new Error("mod-kit's isDans is not stood in by these tests") },
          typedAnswer: async () => { throw new Error("mod-kit's typedAnswer is not stood in by these tests") },
          hold: async () => { throw new Error("mod-kit's hold is not stood in by these tests") },
          release: async () => { throw new Error("mod-kit's release is not stood in by these tests") },
          pythonText: async () => { throw new Error("mod-kit's pythonText is not stood in by these tests") },
          login: async () => { throw new Error("mod-kit's login is not stood in by these tests") },
          account: async () => { throw new Error("mod-kit's account is not stood in by these tests") },
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
// files: more files on disk, by path, beside the project .env.
const world = (on: On, files: Record<string, string> = {}, failing?: string) => {
  const logs: string[] = []
  const reached: string[] = []
  const toasts: string[] = []
  const cards: { toolUseId: string; guard: string; reason: string; safeWay?: string }[] = []
  on('process.run', ($, e) => {
    const cmd = e.argv.join(' ')
    if (cmd === 'env') return { value: { exitCode: 0, stdout: `HOME=${'/Users'}/x\nAPI_TOKEN=${KNOWN}\n`, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    if (cmd === 'gh auth token') return { value: { exitCode: 0, stdout: `${GH_TOKEN}\n`, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    if (cmd.startsWith('git rev-parse')) return { value: { exitCode: 0, stdout: '/repo\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    return { value: { exitCode: 1, stdout: '', stderr: 'unexpected', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.list', ($, e) => ({ value: e.path === '/repo' ? [{ name: '.env', kind: 'file' as const }, { name: 'src', kind: 'dir' as const }] : [] }) as never)
  on('fs.read', ($, e) => {
    if (e.path === '/repo/.env') return { value: `SUPABASE_SERVICE_ROLE_KEY=${ENV_SECRET}\nPORT=3000\n` }
    const more = files[e.path]
    if (more !== undefined) return { value: more }
    throw new Error(`no file ${e.path}`)
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    if (e.text.startsWith('CARD ')) cards.push(JSON.parse(e.text.slice(5)))
    else logs.push(e.text)
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', ($, e) => {
    reached.push(e.tool)
    if (failing !== undefined && (e as { command?: string }).command === failing) throw new Error('the tool beneath failed')
    return { result: 'ran', text: 'ran' } as never
  })
  return { reached, toasts, cards, logs }
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

// #1703: session.start fires again at every fresh load of the mod (once per process, then once per
// fresh load, never at /clear), with the session going on, and loads the secrets again from the
// environment, the gh token and the .env files at the top of the project. A secret Claude wrote this
// session into a .env file anywhere else (a monorepo's apps/web/.env) was guarded only by the
// module's memory, so after a reload it went out in a commit unrefused.
test('a reload of the mod still guards a secret written this session into a .env file deeper in the project (#1703)', withKit, async ($, on) => {
  const fresh = 'wr1tten-deep-v4lue-pp'
  const w = world(on, { '/repo/apps/web/.env': `API_TOKEN=${fresh}\n` })
  await start($)
  await $.tool.call({ tool: 'Write', file_path: '/repo/apps/web/.env', content: `API_TOKEN=${fresh}\n` } as never)
  expect(w.reached).toContain('Write')
  await start($)
  await $.tool.call({ tool: 'Bash', command: `git commit -m "${fresh}"` } as never)
  expect(w.reached).not.toContain('Bash')
})

test('a written .env file that cannot be kept for a reload is said, and its secret is still guarded now (#1703)', withKit, async ($, on) => {
  const fresh = 'wr1tten-deep-v4lue-pp'
  const w = world(on, { '/repo/apps/web/.env': `API_TOKEN=${fresh}\n` })
  on('state.set', async ($, e, next) => ((e as { plugin?: string }).plugin === 'secret-guard' ? ({ deny: 'state store unavailable' } as never) : next(e)))
  await start($)
  await $.tool.call({ tool: 'Write', file_path: '/repo/apps/web/.env', content: `API_TOKEN=${fresh}\n` } as never)
  expect(w.reached).toContain('Write')
  expect(w.logs.filter(l => l.includes("couldn't keep /repo/apps/web/.env for a reload") && l.includes('state store unavailable')).length).toBe(1)
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
      return {
        ...built,
        modkit: {
          blocked: async () => { throw new Error('the card could not be kept') },
          commands: async () => [],
          // The kit's other members, which these tests never reach: each refuses by name if one ever is.
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
          git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
          pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
          workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
          repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
          gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
          mergeHelper: async () => { throw new Error("mod-kit's mergeHelper is not stood in by these tests") },
          goal: async () => { throw new Error("mod-kit's goal is not stood in by these tests") },
          ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
          linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
          branch: async () => { throw new Error("mod-kit's branch is not stood in by these tests") },
          bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
          clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
          screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
          // #939: a press raised by the kit's Button below, and whether a click lands; every Button here is clickable.
          press: async () => ({ isAnswered: false }),
          clickable: async () => true,
          isDans: async () => { throw new Error("mod-kit's isDans is not stood in by these tests") },
          typedAnswer: async () => { throw new Error("mod-kit's typedAnswer is not stood in by these tests") },
          hold: async () => { throw new Error("mod-kit's hold is not stood in by these tests") },
          release: async () => { throw new Error("mod-kit's release is not stood in by these tests") },
          pythonText: async () => { throw new Error("mod-kit's pythonText is not stood in by these tests") },
          login: async () => { throw new Error("mod-kit's login is not stood in by these tests") },
          account: async () => { throw new Error("mod-kit's account is not stood in by these tests") },
        },
      }
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

// #1298: a check that throws inside the tool.call hook must refuse the call. Without a .catch the
// engine skips a failed hook and runs the call with no screening at all (L42). An older mod-kit
// loaded beside this mod (#1281) has no commands reader, so reading a Bash command throws; this
// stand-in's reader throws the same way.
const olderKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        modkit: {
          blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
          // Its error quotes the command it could not read, secret and all, as a parser's error may
          // (lessons review of #1298), so the refusal must not carry the error's own words.
          commands: async ({ command }: { command: string }) => { throw new Error(`could not read: ${command}`) },
          // The kit's other members, which these tests never reach: each refuses by name if one ever is.
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
          git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
          pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
          workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
          repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
          gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
          mergeHelper: async () => { throw new Error("mod-kit's mergeHelper is not stood in by these tests") },
          goal: async () => { throw new Error("mod-kit's goal is not stood in by these tests") },
          ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
          linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
          branch: async () => { throw new Error("mod-kit's branch is not stood in by these tests") },
          bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
          clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
          screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
          press: async () => ({ isAnswered: false }),
          clickable: async () => true,
          isDans: async () => { throw new Error("mod-kit's isDans is not stood in by these tests") },
          typedAnswer: async () => { throw new Error("mod-kit's typedAnswer is not stood in by these tests") },
          hold: async () => { throw new Error("mod-kit's hold is not stood in by these tests") },
          release: async () => { throw new Error("mod-kit's release is not stood in by these tests") },
          pythonText: async () => { throw new Error("mod-kit's pythonText is not stood in by these tests") },
          login: async () => { throw new Error("mod-kit's login is not stood in by these tests") },
          account: async () => { throw new Error("mod-kit's account is not stood in by these tests") },
        },
      }
    })
  },
}

test('a tool call whose secret check throws is refused, never run unscreened (#1298, L42)', { plugins: [olderKit] }, async ($, on) => {
  const w = world(on)
  await start($)
  const r = await $.tool.call({ tool: 'Bash', command: `git commit -m "token ${KNOWN}"`, tool_use_id: 'f1' } as never)
  const said = String((r as { text?: string }).text ?? (r as { deny?: string }).deny)
  expect(w.reached).not.toContain('Bash')
  expect(said).toStartWith('Blocked: the secret guard could not check this for secrets (')
  expect(said).toEndWith('), so it did not run. Try it again; if it fails the same way, tell Dan.')
  expect(said).not.toContain(KNOWN)
  expect(said).not.toContain('could not read')
})

// #1491: from 2.1.307 a mod's own $.tool.call goes through every plugin's hooks, the job watcher's
// TaskStop among them, sent with no call id. A task id carries no secret and no command to read, so
// it runs, even with a kit whose command reader throws.
test("a TaskStop, the job watcher's own with no call id or Claude's with one, runs (#1491)", { plugins: [olderKit] }, async ($, on) => {
  const w = world(on)
  await start($)
  const own = (await $.tool.call({ tool: 'TaskStop', task_id: 'b1' } as never)) as { deny?: string; isError?: boolean }
  const claudes = (await $.tool.call({ tool: 'TaskStop', task_id: 'b2', tool_use_id: 'f2' } as never)) as { deny?: string; isError?: boolean }
  expect([own.deny, own.isError, claudes.deny, claudes.isError]).toEqual([undefined, undefined, undefined, undefined])
  expect(w.reached).toEqual(['TaskStop', 'TaskStop'])
  expect(w.toasts).toEqual([])
})

// The session.append hook fails open the same way: a scrub that throws is skipped and the row is
// kept as it came, secret and all. Its .catch withholds the text instead.
test('a tool result the guard cannot scrub is withheld rather than kept as it was (#1298, L42)', withKit, async ($, on) => {
  let stored = ''
  world(on)
  on('session.append', ($, e, next) => {
    stored = JSON.stringify(e.message.content)
    return next(e)
  })
  const w = { stored: () => stored }
  await start($)
  // A block the scrub cannot read makes the scrub itself throw; withholding block by block then turns it into a withheld text without throwing, so no second try runs.
  await appendRow($, {
    door: 'tool-result',
    origin: { kind: 'tool', tool: 'Bash' },
    uuid: 'u4',
    message: { type: 'user', role: 'user', content: [null, { type: 'tool_result', tool_use_id: 't4', content: `out: ${KNOWN}` }] },
  })
  expect(w.stored()).not.toContain(KNOWN)
  expect(w.stored()).toContain('withheld: the secret guard could not check it for secrets')
  expect(w.stored()).toContain('t4')
})

// Each tool_result in a withheld row keeps its own block and its id, so no call in the transcript is
// left with no answer (a request carrying a tool_use with no tool_result for it is refused). The
// catch's second try, one withheld text, has no ids, and these two pins say why it never reaches
// the transcript. First: withholding block by block reads only plain data, and the engine refuses a
// row that is not plain data before any hook sees it, so that first try cannot throw on a row.
test('a row that is not plain data is refused before the guard sees it, so withholding cannot throw on it (#2039)', withKit, async ($, on) => {
  world(on)
  await start($)
  const block: Record<string, unknown> = { type: 'tool_result', tool_use_id: 'a1' }
  Object.defineProperty(block, 'content', { enumerable: true, get: () => { throw new Error('unreadable') } })
  const settled = await $.session
    .append({ door: 'tool-result', origin: { kind: 'tool', tool: 'Bash' }, uuid: 'u5', message: { type: 'user', role: 'user', content: [block] } } as never)
    .then(() => 'answered', (err: unknown) => String(err))
  expect(settled).toContain('not plain data')
})

// Second: the first try fails only in next, and the test world's store beneath always fails (it
// has no implementation), so this row takes exactly that path. The second try's next is answered
// with the first outcome, so the store is asked once, and what it keeps is one withheld result per
// call id.
test('a withheld row whose store fails keeps one withheld result per call id, never one text (#2039)', withKit, async ($, on) => {
  const seen: unknown[] = []
  world(on)
  on('session.append', ($, e, next) => {
    seen.push(JSON.parse(JSON.stringify(e.message.content)))
    return next(e)
  })
  await start($)
  // The null block makes the scrub itself throw, so the row reaches the catch before next.
  await appendRow($, {
    door: 'tool-result',
    origin: { kind: 'tool', tool: 'Bash' },
    uuid: 'u6',
    message: { type: 'user', role: 'user', content: [null, { type: 'tool_result', tool_use_id: 'a1', content: `out: ${KNOWN}` }, { type: 'tool_result', tool_use_id: 'a2', content: [{ type: 'text', text: KNOWN }] }] },
  })
  const WITHHELD = '[Output withheld: the secret guard could not check it for secrets.]'
  expect(seen).toEqual([[
    { type: 'text', text: WITHHELD },
    { type: 'tool_result', tool_use_id: 'a1', content: WITHHELD },
    { type: 'tool_result', tool_use_id: 'a2', content: WITHHELD },
  ]])
})

// #2039: once next was called the call has already run beneath the guard, so the catch replays what
// the call settled to, outside neverThrows. Here the tool beneath fails (the test world has nothing
// below it, so the replay rejects with the engine's own "no implementation"). That failure reaches
// Claude as the tool's own, never as a refusal saying the call did not run, which would be untrue
// and could make Claude run it twice.
test('a call whose tool fails after it was passed on reaches Claude as the tool failing, not a refusal (#2039)', withKit, async ($, on) => {
  const w = world(on, {}, 'echo boom')
  await start($)
  const settled = await $.tool.call({ tool: 'Bash', command: 'echo boom', tool_use_id: 'r1' } as never).then(
    r => ({ answered: r as { deny?: string; text?: string } }),
    (err: unknown) => ({ rejected: String(err) }),
  )
  expect(w.reached).toEqual(['Bash'])
  expect(settled).not.toHaveProperty('answered')
  expect((settled as { rejected: string }).rejected).toContain('no implementation')
})

// #2039, measured on Claude Code 2.1.317 with the probe in the issue. The hooks beneath a hook run
// once per next call from the hook BODY, so a body that calls next twice runs them twice. A catch
// is different: a next(e) there, after the body already called next, is answered with the first
// call's outcome and the hooks beneath are not run again (also when called twice, or after a
// timeout). The secret guard replays in its catch and depends on that, so these tests pin both
// halves. The test world is the engine itself (claude-code/testing), not a model of it.
// One stand-in mod answers each, switched by a word in the call's command or the row's uuid (an
// inline plugin cannot reach this file's variables). Its catch runs the whole chain again for
// 'rerun', the deliberate break each pin was seen failing against.
const standIn: { name: string; tier: 'prepend'; register: Register } = {
  name: 'stand-in',
  tier: 'prepend',
  register: on => {
    on('tool.call', async ($, e, next) => {
      if (String((e as { command?: string }).command).includes('twice')) {
        await next(e).catch(() => undefined)
        return next(e)
      }
      await next(e).catch(() => undefined)
      throw new Error('after next')
    }).catch(async ($, e, next) => {
      if (String((e as { command?: string }).command).includes('rerun')) return $.tool.call({ ...e, command: 'again' } as never) as never
      return next(e)
    })
    on('session.append', async ($, e, next) => {
      const content = [{ type: 'text', text: 'SCRUBBED' }] as typeof e.message.content
      await next({ ...e, message: { ...e.message, content } }).catch(() => undefined)
      throw new Error('after next')
    }).catch(async ($, e, next) => {
      if (String(e.uuid).includes('rerun')) return $.session.append({ ...e, uuid: 'again' } as never) as never
      return next(e)
    })
  },
}
const withStandIn = { plugins: [kit, standIn] }
const callOnce = async ($: { tool: { call: (e: never) => Promise<unknown> } }, command: string) =>
  $.tool.call({ tool: 'Bash', command, tool_use_id: 'p1' } as never)

test('a hook body that calls next a second time runs the hooks beneath again, so nobody writes one (#2039)', withStandIn, async ($, on) => {
  const w = world(on)
  await start($)
  await callOnce($, 'echo twice')
  expect(w.reached).toEqual(['Bash', 'Bash'])
})

test('a catch that replays next after the body called it does not run the hooks beneath again (#2039)', withStandIn, async ($, on) => {
  const w = world(on)
  await start($)
  const r = (await callOnce($, 'echo replay')) as { text?: string }
  expect(w.reached).toEqual(['Bash'])
  expect(r.text).toBe('ran')
})

test('the replay pin fails against a replay that runs the chain again (#2039)', withStandIn, async ($, on) => {
  const w = world(on)
  await start($)
  await callOnce($, 'echo rerun')
  expect(w.reached.length).toBeGreaterThan(1)
})

// The same on session.append, with the row: the store beneath is asked once and the replay returns
// the scrubbed row the body passed on, never the raw one.
const appended = async (uuid: string, $: { session: { append: (e: never) => Promise<unknown> } }, on: On) => {
  const seen: string[] = []
  world(on)
  on('session.append', ($, e, next) => {
    seen.push(JSON.stringify(e.message.content))
    return next(e)
  })
  await start($ as never)
  const settled = await $.session
    .append({ door: 'tool-result', origin: { kind: 'tool', tool: 'Bash' }, uuid, message: { type: 'user', role: 'user', content: [{ type: 'text', text: 'RAW' }] } } as never)
    .then(r => ({ answered: r }), (err: unknown) => ({ rejected: String(err) }))
  return { seen, settled }
}
test('a replay of a scrubbed row runs the store once and carries the scrubbed row (#2039)', withStandIn, async ($, on) => {
  const { seen, settled } = await appended('u7', $ as never, on)
  expect(seen).toEqual(['[{"type":"text","text":"SCRUBBED"}]'])
  expect(JSON.stringify(settled)).not.toContain('RAW')
})
test('the scrubbed row pin fails against a replay that runs the chain again (#2039)', withStandIn, async ($, on) => {
  const { seen } = await appended('rerun', $ as never, on)
  expect(seen.length).toBeGreaterThan(1)
})

// The real guard: the store beneath is asked once for a row carrying a secret, and what it was
// asked is the scrubbed text.
test('the guard passes a scrubbed row to the store once (#2039)', withKit, async ($, on) => {
  const seen: string[] = []
  world(on)
  on('session.append', ($, e, next) => {
    seen.push(JSON.stringify(e.message.content))
    return next(e)
  })
  await start($)
  await appendRow($, { door: 'tool-result', origin: { kind: 'tool', tool: 'Bash' }, uuid: 'u9', message: { type: 'user', role: 'user', content: [{ type: 'tool_result', tool_use_id: 't9', content: `out: ${KNOWN}` }] } })
  expect(seen).toHaveLength(1)
  expect(seen[0]).not.toContain(KNOWN)
})
