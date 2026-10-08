import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type { ModKitBandRow } from '../.claude-plugin/types/mod-kit/index.d.ts'
import { githubRepo, repoName } from './mod-kit/hooks/repo.ts'
import { REPO_FIXTURES } from './mod-kit/tests/repo-fixtures.ts'

// Is it live (claude-config#617) in a session: Claude hands the card tool what it found after a
// merge, the mod confirms the merge with GitHub itself, keeps the card, toasts it, and pins any
// message for whoever asked in the band until Dan presses Mark sent. /live lists them.

// mod-kit, standing in: a mod cannot import another mod's files. It keeps published rows and draws
// their text and buttons. mod-kit's own tests prove the real composer.
type Part = { text?: string; color?: string; button?: string; label?: string }
type Row = { mod: string; id: string; slot: string; lines: Part[][] }
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ref = { plugin: 'mod-kit', key: 'band' } as never
      const cardsRef = { plugin: 'mod-kit', key: 'cards' } as never
      const rows = async () => (((await built.state.get(ref)) as { value?: Row[] }).value ?? [])
      const modkit = {
        bandRow: async (row: ModKitBandRow) => {
          await built.state.set(ref, [...(await rows()).filter(r => !(r.mod === row.mod && r.id === row.id)), row] as never)
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
          await built.state.set(ref, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
        },
        // The boxed card for a tool result, kept where the test can read it; a call whose id is
        // refuse-me is refused, as the real kit refuses a malformed card.
        card: async (c: { toolUseId: string }) => {
          if (c.toolUseId === 'refuse-me') throw new Error('a card needs a title of one or more runs')
          const held = ((await built.state.get(cardsRef)) as { value?: unknown[] }).value ?? []
          await built.state.set(cardsRef, [...held, c] as never)
        },
        // The screen (#707): refuses a call carrying SCREEN-REFUSES, as the secret guard refuses a
        // token; mod-kit's own tests prove the real one asks the secret guard.
        screen: async (call: unknown) => (JSON.stringify(call).includes('SCREEN-REFUSES') ? { deny: 'Blocked: this message contains a secret. Refer to it by its name, not its value.' } : null),
        // #939: a press raised by the kit's Button below, and whether a click lands; every Button here is clickable.
        press: async () => ({ isAnswered: false }),
        clickable: async () => true,
        // #951: the session's repository, asked of the world (a plugin in a test runs in its own
        // environment), which reads with a byte for byte copy of mod-kit's own reader.
        repo: async (input: { root?: string | null; remote: string | null }) => {
          const r = await built.process.run(['__modkit', 'repo', JSON.stringify(input)])
          if (r.exitCode !== 0) throw new Error(r.stderr)
          return JSON.parse(r.stdout)
        },
        // The kit's other members, which these tests never reach: each refuses by name if one ever is.
        blocked: async () => { throw new Error("mod-kit's blocked is not stood in by these tests") },
        commands: async () => { throw new Error("mod-kit's commands is not stood in by these tests") },
        writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
        git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
        pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
        workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
        pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
        clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
      }
      return { ...built, modkit }
    })
    // A result row with a card is drawn as its title's runs, then its lines' runs, as plain Texts.
    on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
      type C = { toolUseId: string; title: { text: string; color?: string; bold?: boolean }[]; lines: { text: string }[][] }
      const held = ((await $.state.get({ plugin: 'mod-kit', key: 'cards' } as never)) as { value?: C[] }).value ?? []
      const c = held.find(x => x.toolUseId === e.props.tool_use_id)
      if (!c) return next(e)
      const { Box, Text } = $.ui.resolve(e)
      return (
        <Box flexDirection="column">
          {[c.title, ...c.lines].map((l, n) => (
            <Box key={String(n)} flexDirection="row">
              {l.map((r, i) => (
                <Text key={String(i)} color={(r as { color?: string }).color} bold={(r as { bold?: boolean }).bold}>
                  {r.text}
                </Text>
              ))}
            </Box>
          ))}
        </Box>
      )
    })
    on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
      const rows = ((await $.state.get({ plugin: 'mod-kit', key: 'band' } as never)) as { value?: Row[] }).value ?? []
      if (!rows.length) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      return (
        <Box flexDirection="column">
          {rows.flatMap(r =>
            r.lines.map((l, n) => (
              <Box key={`${r.id}${n}`} flexDirection="row">
                {l.map((p, i) =>
                  p.button ? (
                    <Button key={`${r.mod}:${p.button}`} label={p.label as string} onPress={press => void $.modkit.press({ element: press.element, surface: String(press.surface), how: 'click' })} />
                  ) : (
                    <Text key={String(i)} color={p.color}>
                      {p.text}
                    </Text>
                  ),
                )}
              </Box>
            )),
          )}
        </Box>
      )
    })
  },
}
const withKit = { plugins: [modKit] }

const T0 = 1_800_000_000_000
const REPO = 'danwright32/slate'
type Gh = { exitCode: number; stdout: string; stderr?: string }
type World = { pr: Gh; issue: Gh; me: Gh; accounts: Gh; repoName: Gh; remote: string | null; copied: boolean; stored?: Record<string, unknown>; kitFails?: boolean }

// GitHub, the clipboard, the store, toasts and Claude Code's own band beneath the mod.
const world = (on: On, init: Partial<World> = {}) => {
  const w: World = {
    pr: { exitCode: 0, stdout: JSON.stringify({ state: 'MERGED', title: 'Filter bookings by venue', url: `https://github.com/${REPO}/pull/412` }) },
    issue: { exitCode: 0, stdout: JSON.stringify({ author: { login: 'kris-k' } }) },
    me: { exitCode: 0, stdout: 'danwright32\n' },
    // Every account gh is logged in to on this Mac, as `gh auth status --json hosts --jq` lists them.
    accounts: { exitCode: 0, stdout: 'danwright32\n' },
    // The session folder's origin, and the name GitHub gives that repository now (`gh repo view`).
    remote: `git@github.com:${REPO}.git`,
    repoName: { exitCode: 0, stdout: `${REPO}\n` },
    copied: true,
    ...init,
  }
  const toasts: string[] = []
  const copies: string[] = []
  const runs: string[][] = []
  mock.clock(on, { now: T0 })
  mock.store(on, w.stored)
  on('process.run', ($, e) => {
    // mod-kit's repo reader, standing in: its byte for byte copy, as the kit reads (#951).
    if (e.argv[0] === '__modkit') {
      if (w.kitFails) return { value: { exitCode: 1, stdout: '', stderr: 'mod-kit is not loaded', isStdoutTruncated: false, isStderrTruncated: false } } as never
      const input = JSON.parse(e.argv[2] as string) as { root?: string | null; remote: string | null }
      return { value: { exitCode: 0, stdout: JSON.stringify({ github: githubRepo(input.remote), name: repoName(input) }), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
    }
    runs.push([...e.argv])
    const a = e.argv.join(' ')
    const g = a.startsWith('gh pr view')
      ? w.pr
      : a.startsWith('gh issue view')
        ? w.issue
        : a.startsWith('gh api user')
          ? w.me
          : a.startsWith('gh auth status')
            ? w.accounts
            : a.startsWith('gh repo view')
              ? w.repoName
              : { exitCode: 1, stdout: '', stderr: 'unexpected' }
    return { value: { exitCode: g.exitCode, stdout: g.stdout, stderr: g.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false } } as never
  })
  on('session.repo', () => ({ value: { root: '/Users/dan/Apps/slate', remote: w.remote, isOwn: false } }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }) as never)
  on('tool.register', () => ({ value: undefined }) as never)
  on('command.register', () => ({ value: undefined }) as never)
  on('ui.copy', ($, e) => {
    copies.push(String((e as { text?: string }).text))
    return { value: w.copied ? { isCopied: true } : { isCopied: false, reason: 'no-clipboard' } } as never
  })
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  return { w, toasts, copies, runs }
}

const CARD = {
  repo: REPO,
  pr: 412,
  deploy: 'live',
  checked: 'Loaded /bookings and saw the venue filter.',
  changed: 'The bookings list now filters by venue. Old bookings keep their venue.',
  see: { link: 'https://slate.example.com/bookings', clicks: ['Open Bookings', 'Pick a venue in the filter'] },
}
type Out = { deny?: string; result?: unknown; text?: string; context?: readonly string[] }
const card = async ($: unknown, input: Record<string, unknown>) =>
  (await ($ as { tool: { call: (e: never) => Promise<unknown> } }).tool.call({ tool: 'mcp__is-it-live__card', tool_use_id: 'c1', ...input } as never)) as Out
const textOf = (o: Out) => String(o.deny ?? o.text ?? o.result ?? '')
const band = () => ({ plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 40, bodyColumns: 100, scroll: { offset: 0, bodyRows: 40 }, view: {} } }) as never
type Found = { text: string; children: unknown[] }
type Mounted = { findAll: (q: { type: string }) => Promise<Found[]>; press: (t: object) => Promise<unknown>; unmount: () => Promise<void> }
const mount = async ($: unknown) => (await ($ as { ui: { mount: (x: never) => Promise<unknown> } }).ui.mount(band())) as Mounted
const shown = async ($: unknown) => {
  const ui = await mount($)
  const t = (await ui.findAll({ type: 'Text' })).filter(x => x.children.every(c => typeof c === 'string')).map(x => x.text)
  await ui.unmount()
  return t
}
const press = async ($: unknown, key: string) => {
  const ui = await mount($)
  await ui.press({ key })
  await ui.unmount()
}
const live = async ($: unknown) =>
  String(((await ($ as { command: { run: (x: never) => Promise<unknown> } }).command.run({ command: 'live', args: '', origin: { kind: 'human' }, presentation: {} } as never)) as { text?: string }).text)
const start = async ($: unknown) => {
  await ($ as { session: { start: (x: never) => Promise<unknown> } }).session.start({ cwd: '/Users/dan/Apps/slate', surface: 'terminal', isInteractive: true } as never)
}

test('verified live: the card leads with Live, confirms the merge with GitHub, and is toasted, with no message when nobody else asked', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  const r = await card($, CARD)
  expect(r.deny).toBeUndefined()
  expect(textOf(r).split('\n')[0]).toBe('Live: Filter bookings by venue')
  expect(textOf(r)).toContain('See it: https://slate.example.com/bookings')
  expect((r.context ?? []).join(' ')).toContain('no sentence that repeats it')
  expect(w.runs[0]).toEqual(['gh', 'pr', 'view', '412', '--repo', REPO, '--json', 'state,title,url'])
  expect(w.toasts).toEqual(['Live: Filter bookings by venue'])
  expect(await shown($)).toEqual(['engine band'])
})

// #707: this mod answers its card tool itself, so the secret guard beneath it never sees the call;
// it asks mod-kit's screen first. A card whose message carries a token is refused before GitHub is
// asked, the card kept or toasted, or the message pinned with Copy.
test('a card a guard refuses is refused before GitHub is asked or anything is kept, toasted or pinned (#707)', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  const r = await card($, { ...CARD, requester: { name: 'Kris', via: 'named' }, message: 'Here is the key: SCREEN-REFUSES' })
  expect(textOf(r)).toBe('Blocked: this message contains a secret. Refer to it by its name, not its value.')
  expect(w.runs).toEqual([])
  expect(w.toasts).toEqual([])
  expect(await shown($)).toEqual(['engine band'])
  expect(await live($)).not.toContain('Filter bookings by venue')
})

// What the card's result row shows: each leaf Text's words and colour, top to bottom.
const row = async ($: unknown, id: string) => {
  const ui = (await ($ as { ui: { mount: (x: never) => Promise<unknown> } }).ui.mount({
    plugin: 'mod-kit',
    surface: 'terminal',
    component: 'ToolResult',
    props: { tool_use_id: id, tool: 'mcp__is-it-live__card', output: 'text', isErrored: false },
  } as never)) as { findAll: (q: { type: string }) => Promise<{ text: string; props: { color?: string; bold?: boolean }; children: unknown[] }[]> } & Mounted
  const t = (await ui.findAll({ type: 'Text' })).filter(x => x.children.every(c => typeof c === 'string')).map(x => ({ text: x.text, color: x.props.color, bold: x.props.bold }))
  await ui.unmount()
  return t
}

test("the card's result row is mod-kit's boxed card, its state word in colour, for this call", withKit, async ($, on) => {
  world(on)
  await card($, CARD)
  await card($, { ...CARD, deploy: 'failed', checked: 'The deploy check timed out.', tool_use_id: 'c2' })
  const live = await row($, 'c1')
  expect(live.slice(0, 3)).toEqual([
    { text: 'Live:', color: 'success', bold: true },
    { text: ' Filter bookings by venue', color: undefined, bold: undefined },
    { text: 'The bookings list now filters by venue. Old bookings keep their venue.', color: undefined, bold: undefined },
  ])
  const failed = await row($, 'c2')
  expect(failed[0]).toEqual({ text: 'Could not confirm live:', color: 'warning', bold: true })
  expect(failed[2]?.text).toBe('The deploy check timed out.')
})

test('a card mod-kit refuses to box is still made, shown as its text, and Claude is told why', withKit, async ($, on) => {
  const w = world(on)
  const r = await card($, { ...CARD, tool_use_id: 'refuse-me' })
  expect(r.deny).toBeUndefined()
  expect(textOf(r).split('\n')[0]).toBe('Live: Filter bookings by venue')
  expect((r.context ?? []).join(' ')).toContain('could not be drawn boxed (a card needs a title of one or more runs)')
  expect(w.toasts).toEqual(['Live: Filter bookings by venue'])
  expect(await row($, 'refuse-me')).toEqual([{ text: 'engine band', color: undefined, bold: undefined }])
})

test('no boxed card when no card is made', withKit, async ($, on) => {
  world(on, { pr: { exitCode: 0, stdout: JSON.stringify({ state: 'OPEN', title: 't', url: 'u' }) } })
  await card($, CARD)
  expect(await row($, 'c1')).toEqual([{ text: 'engine band', color: undefined, bold: undefined }])
})

test('merged but still deploying reads "Merged, deploying", never live', withKit, async ($, on) => {
  world(on)
  const r = await card($, { ...CARD, deploy: 'deploying', checked: undefined })
  expect(textOf(r).split('\n')[0]).toBe('Merged, deploying: Filter bookings by venue')
})

test('a deploy that failed or could not be reached says it could not confirm live, and why', withKit, async ($, on) => {
  world(on)
  for (const deploy of ['failed', 'unreachable']) {
    const r = await card($, { ...CARD, deploy, checked: 'The deploy check timed out.' })
    expect(textOf(r).split('\n').slice(0, 2)).toEqual(['Could not confirm live: Filter bookings by venue', 'The deploy check timed out.'])
  }
})

test('a project with no recorded deploy step says so rather than calling the merge live', withKit, async ($, on) => {
  world(on)
  const r = await card($, { ...CARD, deploy: 'none', checked: undefined })
  expect(textOf(r).split('\n')[0]).toBe('Merged, no deploy step recorded: Filter bookings by venue')
})

test('no card for a pull request GitHub does not report merged, or when GitHub cannot be asked', withKit, async ($, on) => {
  const w = world(on, { pr: { exitCode: 0, stdout: JSON.stringify({ state: 'OPEN', title: 't', url: 'u' }) } })
  const open = await card($, CARD)
  expect(open.deny).toContain('#412 is open, not merged')
  w.w.pr = { exitCode: 1, stdout: '', stderr: 'HTTP 502' }
  const down = await card($, CARD)
  expect(down.deny).toContain('could not confirm #412 is merged')
  expect(down.deny).toContain('HTTP 502')
  expect(w.toasts).toEqual([])
  expect(await live($)).toBe('No merged changes have a card in this project yet.')
})

test('live without saying how it was checked is refused', withKit, async ($, on) => {
  world(on)
  const r = await card($, { ...CARD, checked: '' })
  expect(r.deny).toContain('how it was checked')
})

test('someone else asked in an issue: the message is pinned in the band, Copy copies it, Mark sent takes it away', withKit, async ($, on) => {
  const w = world(on)
  const r = await card($, { ...CARD, requester: { name: 'Kris', via: 'issue', issue: 88 }, message: 'The venue filter is live now, have a look.' })
  expect(r.deny).toBeUndefined()
  const lines = await shown($)
  expect(lines).toEqual(['Message for Kris', 'The venue filter is live now, have a look.'])
  await press($, 'is-it-live:copy-danwright32-slate-412')
  expect(w.copies).toEqual(['The venue filter is live now, have a look.'])
  expect(await live($)).toContain('Not sent yet:\n- Message for Kris (#412)')
  await press($, 'is-it-live:sent-danwright32-slate-412')
  expect(await shown($)).toEqual(['engine band'])
  expect(await live($)).not.toContain('Not sent yet')
})

test('a Copy the clipboard refuses says so, rather than seeming to work', withKit, async ($, on) => {
  const w = world(on, { copied: false })
  await card($, { ...CARD, requester: { name: 'Kris', via: 'named' }, message: 'It is live now.' })
  await press($, 'is-it-live:copy-danwright32-slate-412')
  expect(w.toasts.join('\n')).toContain('Not copied: no-clipboard')
})

test('an issue Dan or Claude filed gets no message: the card is made and the message dropped, saying why', withKit, async ($, on) => {
  world(on, { issue: { exitCode: 0, stdout: JSON.stringify({ author: { login: 'danwright32' } }) } })
  const r = await card($, { ...CARD, requester: { name: 'Kris', via: 'issue', issue: 88 }, message: 'It is live.' })
  expect(r.deny).toBeUndefined()
  expect(textOf(r)).toContain('Live: Filter bookings by venue')
  expect((r.context ?? []).join(' ')).toContain('issue #88 was filed from your own account')
  expect(await shown($)).toEqual(['engine band'])
  expect(await live($)).not.toContain('Not sent yet')
})

test('an issue whose author cannot be read gets no card, rather than a guess', withKit, async ($, on) => {
  world(on, { issue: { exitCode: 1, stdout: '', stderr: 'Could not resolve to an issue' } })
  const r = await card($, { ...CARD, requester: { name: 'Kris', via: 'issue', issue: 88 }, message: 'It is live.' })
  expect(r.deny).toContain('could not read who filed issue #88')
})

test('/live keeps an unsent message across a new card for the same change, and lists the newest first', withKit, async ($, on) => {
  world(on)
  await card($, { ...CARD, deploy: 'deploying', checked: undefined, requester: { name: 'Kris', via: 'slack' }, message: 'Deploying now.' })
  await card($, { ...CARD, requester: { name: 'Kris', via: 'slack' }, message: 'It is live now.' })
  const out = await live($)
  expect(out).toBe(['- Live: Filter bookings by venue (#412)', '', 'Not sent yet:', '- Message for Kris (#412): It is live now.'].join('\n'))
})

// ---- The verdict other mods read (#687): wind down finishes only on what the card says. ----

// Another mod, standing in for scope-modes: it reads $.isItLive.verdict from a hook of its own.
type Verdict = { state: string; at: number } | null
const reader: { name: string; register: Register } = {
  name: 'reader',
  register: on => {
    on('command.run', { command: 'verdict' }, async ($, e) => {
      const [repo, pr] = String(e.args).split(' ')
      try {
        const v = await ($ as unknown as { isItLive: { verdict: (q: { repo: string; pr: number }) => Promise<Verdict> } }).isItLive.verdict({ repo: String(repo), pr: Number(pr) })
        return { text: JSON.stringify(v) }
      } catch (err) {
        return { text: `threw: ${String((err as Error).message)}` }
      }
    })
  },
}
const withReader = { plugins: [modKit, reader] }
const verdict = async ($: unknown, args: string) =>
  String(((await ($ as { command: { run: (x: never) => Promise<unknown> } }).command.run({ command: 'verdict', args, origin: { kind: 'human' }, presentation: {} } as never)) as { text?: string }).text)

test("another mod reads the verdict for a PR: each card's state, the newest card winning", withReader, async ($, on) => {
  world(on)
  await card($, { ...CARD, deploy: 'deploying', checked: undefined })
  expect(JSON.parse(await verdict($, `${REPO} 412`))).toEqual({ state: 'deploying', at: T0 })
  await card($, { ...CARD, deploy: 'failed', checked: 'The deploy check timed out.' })
  expect(JSON.parse(await verdict($, `${REPO} 412`)).state).toBe('unconfirmed')
  await card($, { ...CARD, deploy: 'none', checked: undefined })
  expect(JSON.parse(await verdict($, `${REPO} 412`)).state).toBe('no-deploy')
  await card($, CARD)
  expect(JSON.parse(await verdict($, `${REPO} 412`)).state).toBe('live')
})

test('a PR with no card, in this repository or another, has no verdict rather than a guess', withReader, async ($, on) => {
  world(on)
  expect(await verdict($, `${REPO} 412`)).toBe('null')
  await card($, CARD)
  expect(await verdict($, `${REPO} 413`)).toBe('null')
  expect(await verdict($, 'danwright32/other 412')).toBe('null')
})

test('a card GitHub refused (not merged) leaves no verdict', withReader, async ($, on) => {
  world(on, { pr: { exitCode: 0, stdout: JSON.stringify({ state: 'OPEN', title: 't', url: 'u' }) } })
  await card($, CARD)
  expect(await verdict($, `${REPO} 412`)).toBe('null')
})

test('a malformed question is refused loudly, never answered as no card', withReader, async ($, on) => {
  world(on)
  expect(await verdict($, 'not-a-repo 412')).toMatch(/^threw: .*owner\/name/)
  expect(await verdict($, `${REPO} zero`)).toMatch(/^threw: .*pull request number/)
})

// ---- The milestone audit's gaps (#704, and the verdict key in #702) ----

const mergedIn = (repo: string, pr = 412) => ({ exitCode: 0, stdout: JSON.stringify({ state: 'MERGED', title: 'Filter bookings by venue', url: `https://github.com/${repo}/pull/${pr}` }) })

test("the verdict is found under GitHub's own spelling of the repo, whatever case Claude typed it in", withReader, async ($, on) => {
  // gh accepts any case, so the card is made; GitHub's link spells it PostRoll.
  world(on, { pr: mergedIn('danwright32/PostRoll', 5) })
  expect((await card($, { ...CARD, repo: 'danwright32/postroll', pr: 5 })).deny).toBeUndefined()
  // Wind down asks with the spelling from GitHub's own link for the PR.
  expect(JSON.parse(await verdict($, 'danwright32/PostRoll 5')).state).toBe('live')
  expect(JSON.parse(await verdict($, 'danwright32/POSTROLL 5')).state).toBe('live')
})

test("a card made under a repo's old name gives its verdict under the name GitHub gives it now", withReader, async ($, on) => {
  // gh follows the rename, so the card is accepted; GitHub's link names the repo as it is now.
  world(on, { pr: mergedIn('danwright32/backstage', 9) })
  await card($, { ...CARD, repo: 'danwright32/shared-swift', pr: 9 })
  expect(JSON.parse(await verdict($, 'danwright32/backstage 9')).state).toBe('live')
})

test("Copy and Mark sent work on a message for a PR in another repository than the session folder's", withKit, async ($, on) => {
  const w = world(on, { pr: mergedIn('danwright32/backstage', 31) })
  await card($, { ...CARD, repo: 'danwright32/backstage', pr: 31, requester: { name: 'Kris', via: 'named' }, message: 'The sign in fix is live.' })
  expect(await shown($)).toEqual(['Message for Kris', 'The sign in fix is live.'])
  await press($, 'is-it-live:copy-danwright32-backstage-31')
  expect(w.copies).toEqual(['The sign in fix is live.'])
  expect(w.toasts).not.toContain('That message is no longer kept.')
  await press($, 'is-it-live:sent-danwright32-backstage-31')
  expect(await shown($)).toEqual(['engine band'])
})

test("a card Claude spelled in another case than the session folder's remote is listed, copied and marked sent", withKit, async ($, on) => {
  const w = world(on)
  await card($, { ...CARD, repo: 'DanWright32/Slate', requester: { name: 'Kris', via: 'named' }, message: 'It is live.' })
  expect(await live($)).toContain('- Live: Filter bookings by venue (#412)')
  await press($, 'is-it-live:copy-danwright32-slate-412')
  expect(w.copies).toEqual(['It is live.'])
  await press($, 'is-it-live:sent-danwright32-slate-412')
  expect(await live($)).not.toContain('Not sent yet')
})

test('cards kept under a key in another case are still listed, and a new card loses none of them', withKit, async ($, on) => {
  const old = { repo: 'danwright32/Slate', pr: 300, title: 'Old change', url: 'https://github.com/danwright32/slate/pull/300', state: 'live', at: T0 - 1000, requester: { name: 'Kris', via: 'named' }, message: 'Old news.' }
  world(on, { stored: { 'cards:danwright32/Slate': [old] } })
  expect(await live($)).toBe(['- Live: Old change (#300)', '', 'Not sent yet:', '- Message for Kris (#300): Old news.'].join('\n'))
  await card($, CARD)
  expect(await live($)).toBe(['- Live: Filter bookings by venue (#412)', '- Live: Old change (#300)', '', 'Not sent yet:', '- Message for Kris (#300): Old news.'].join('\n'))
})

test('/live after a rename lists and pins the cards of both names newest first, never grouped by name (lessons review of #710)', withKit, async ($, on) => {
  const old = (pr: number, at: number) => ({ repo: 'danwright32/old-slate', pr, title: `Change ${pr}`, url: `https://github.com/danwright32/old-slate/pull/${pr}`, state: 'live', at, requester: { name: 'Kris', via: 'named' }, message: `About ${pr}.` })
  const now = (pr: number, at: number) => ({ ...old(pr, at), repo: 'danwright32/slate', url: `https://github.com/danwright32/slate/pull/${pr}` })
  world(on, {
    remote: 'git@github.com:danwright32/old-slate.git',
    stored: { 'cards:danwright32/old-slate': [old(300, T0 - 1000), old(302, T0 - 3000)], 'cards:danwright32/slate': [now(301, T0 - 2000)] },
  })
  expect((await live($)).split('\n').slice(0, 3)).toEqual(['- Live: Change 300 (#300)', '- Live: Change 301 (#301)', '- Live: Change 302 (#302)'])
  // Each unsent message is pinned again, the newest first in the band too.
  expect((await shown($)).filter(t => t.startsWith('About'))).toEqual(['About 300.', 'About 301.', 'About 302.'])
})

test('/live after a rename lists a PR kept under both names once, as its newest card (#720)', withKit, async ($, on) => {
  const old = (pr: number, at: number, title: string) => ({ repo: 'danwright32/old-slate', pr, title, url: `https://github.com/danwright32/old-slate/pull/${pr}`, state: 'live', at })
  const now = (pr: number, at: number, title: string) => ({ ...old(pr, at, title), repo: 'danwright32/slate', url: `https://github.com/danwright32/slate/pull/${pr}` })
  // The newer card is under the old name, which /live reads first, so neither a per name key nor
  // the last name read can pick it.
  world(on, {
    remote: 'git@github.com:danwright32/old-slate.git',
    stored: { 'cards:danwright32/old-slate': [old(300, T0 - 1000, 'Newer')], 'cards:danwright32/slate': [now(300, T0 - 5000, 'Older')] },
  })
  expect(await live($)).toBe('- Live: Newer (#300)')
})

test('/live after a rename keeps the unsent message an older card under the other name owes, and Mark sent finds it (#720)', withKit, async ($, on) => {
  const old = { repo: 'danwright32/old-slate', pr: 300, title: 'Older', url: 'https://github.com/danwright32/old-slate/pull/300', state: 'live', at: T0 - 5000, requester: { name: 'Kris', via: 'named' }, message: 'About 300.' }
  const now = { repo: 'danwright32/slate', pr: 300, title: 'Newer', url: 'https://github.com/danwright32/slate/pull/300', state: 'live', at: T0 - 1000 }
  world(on, { remote: 'git@github.com:danwright32/old-slate.git', stored: { 'cards:danwright32/old-slate': [old], 'cards:danwright32/slate': [now] } })
  expect(await live($)).toBe('- Live: Newer (#300)\n\nNot sent yet:\n- Message for Kris (#300): About 300.')
  expect((await shown($)).filter(t => t.startsWith('About'))).toEqual(['About 300.'])
  // The pinned row is the older card's own, so Mark sent finds that card and takes the row away.
  await press($, 'is-it-live:sent-danwright32-old-slate-300')
  expect((await shown($)).filter(t => t.startsWith('About'))).toEqual([])
  expect(await live($)).toBe('- Live: Newer (#300)')
})

test("/live in a checkout whose origin still has the repo's old name lists the cards kept under the name GitHub gives it now", withKit, async ($, on) => {
  const w = world(on, { remote: 'git@github.com:danwright32/old-slate.git' })
  await card($, CARD)
  expect(await live($)).toBe('- Live: Filter bookings by venue (#412)')
  expect(w.runs).toContainEqual(['gh', 'repo', 'view', 'danwright32/old-slate', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'])
})

// #979 review: mod-kit's reader failing is said as the repository not being read, never as a
// folder with no GitHub repository, and /live answers rather than throwing.
test("/live says the session's repository could not be read when mod-kit's reader fails", withKit, async ($, on) => {
  const { runs } = world(on, { kitFails: true })
  expect(await live($)).toBe("This session's repository could not be read (mod-kit is not loaded), so its cards cannot be listed.")
  expect(runs.filter(r => r[0] === 'gh')).toEqual([])
})

test('/live says so when GitHub cannot be asked for the repo\'s current name, and lists what is kept under the remote\'s', withKit, async ($, on) => {
  world(on, { remote: 'git@github.com:danwright32/old-slate.git', repoName: { exitCode: 1, stdout: '', stderr: 'HTTP 502' } })
  await card($, CARD)
  expect(await live($)).toBe(
    'No merged changes have a card in this project yet.\n\nGitHub could not be asked for the name this repository has now (HTTP 502), so any cards kept under another name for it may be missing.',
  )
})

test('a later card for the same PR that names nobody keeps the unsent message, in /live and in the band', withKit, async ($, on) => {
  world(on)
  await card($, { ...CARD, deploy: 'deploying', checked: undefined, requester: { name: 'Kris', via: 'slack' }, message: 'Deploying now.' })
  await card($, CARD)
  expect(await live($)).toContain('Not sent yet:\n- Message for Kris (#412): Deploying now.')
  expect(await shown($)).toEqual(['Message for Kris', 'Deploying now.'])
})

test("a requester dropped as Dan's own leaves an earlier card's unsent message waiting, and Claude is told both", withKit, async ($, on) => {
  const w = world(on)
  await card($, { ...CARD, deploy: 'deploying', checked: undefined, requester: { name: 'Kris', via: 'slack' }, message: 'Deploying now.' })
  w.w.issue = { exitCode: 0, stdout: JSON.stringify({ author: { login: 'danwright32' } }) }
  const r = await card($, { ...CARD, requester: { name: 'Sam', via: 'issue', issue: 88 }, message: 'It is live.' })
  const said = (r.context ?? []).join(' ')
  expect(said).toContain('The message for Sam was dropped: issue #88 was filed from your own account')
  expect(said).toContain('The earlier message for Kris still waits until Dan marks it sent.')
  expect(await shown($)).toEqual(['Message for Kris', 'Deploying now.'])
})

test('a message Dan marked sent stays sent when the card is made again with it, and a new message waits again', withKit, async ($, on) => {
  world(on)
  const ask = { requester: { name: 'Kris', via: 'slack' }, message: 'It is live now.' }
  await card($, { ...CARD, ...ask })
  await press($, 'is-it-live:sent-danwright32-slate-412')
  await card($, { ...CARD, ...ask })
  expect(await shown($)).toEqual(['engine band'])
  expect(await live($)).not.toContain('Not sent yet')
  // Made again naming nobody, the sent message stays sent too.
  await card($, CARD)
  expect(await shown($)).toEqual(['engine band'])
  expect(await live($)).not.toContain('Not sent yet')
  await card($, { ...CARD, ...ask, message: 'It is live, and faster.' })
  expect(await live($)).toContain('- Message for Kris (#412): It is live, and faster.')
})

test("an issue filed from another of Dan's gh accounts gets no message", withKit, async ($, on) => {
  const w = world(on, { issue: { exitCode: 0, stdout: JSON.stringify({ author: { login: 'dwright-pennie' } }) }, accounts: { exitCode: 0, stdout: 'danwright32\ndwright-pennie\n' } })
  const r = await card($, { ...CARD, requester: { name: 'Kris', via: 'issue', issue: 88 }, message: 'It is live.' })
  expect((r.context ?? []).join(' ')).toContain('issue #88 was filed from your own account')
  expect(await shown($)).toEqual(['engine band'])
  // The accounts come from gh's own list of every account logged in, read without a token.
  expect(w.runs).toContainEqual(['gh', 'auth', 'status', '--hostname', 'github.com', '--json', 'hosts', '--jq', '.hosts["github.com"][].login'])
})

test("when gh cannot list its accounts, the active account counts as Dan's and Claude is told so", withKit, async ($, on) => {
  world(on, { issue: { exitCode: 0, stdout: JSON.stringify({ author: { login: 'danwright32' } }) }, accounts: { exitCode: 1, stdout: '', stderr: 'unknown flag: --json' } })
  const r = await card($, { ...CARD, requester: { name: 'Kris', via: 'issue', issue: 88 }, message: 'It is live.' })
  const said = (r.context ?? []).join(' ')
  expect(said).toContain('issue #88 was filed from your own account')
  expect(said).toContain("could not list every gh account on this Mac (unknown flag: --json), so only the active one counted as Dan's")
})

test('when gh can name no account of Dan\'s at all, no card is made, rather than a guess', withKit, async ($, on) => {
  world(on, { accounts: { exitCode: 1, stdout: '', stderr: 'unknown flag: --json' }, me: { exitCode: 1, stdout: '', stderr: 'HTTP 401: Bad credentials' } })
  const r = await card($, { ...CARD, requester: { name: 'Kris', via: 'issue', issue: 88 }, message: 'It is live.' })
  expect(r.deny).toBe('No card: could not read who filed issue #88 (HTTP 401: Bad credentials).')
})

test("an issue whose author is none of Dan's accounts keeps its message", withKit, async ($, on) => {
  world(on, { accounts: { exitCode: 0, stdout: 'danwright32\ndwright-pennie\n' } })
  await card($, { ...CARD, requester: { name: 'Kris', via: 'issue', issue: 88 }, message: 'It is live.' })
  expect(await shown($)).toEqual(['Message for Kris', 'It is live.'])
})

// #771: after a merge the card's facts showed up to four times. The call's own row (Claude Code's
// echo of the tool's input) carried the whole changed text, checked and see; it is drawn naming the
// change alone, and the card under it is the one place the facts are read.
const toolRow = (input: unknown, tool = 'mcp__is-it-live__card') =>
  ({ plugin: 'is-it-live', surface: 'terminal', component: 'ToolUse', props: { tool_use_id: 'c1', tool, input, isRunning: false, isErrored: false, isInterrupted: false } }) as never
const rowInput = async ($: unknown, input: unknown, tool?: string) => {
  const ui = (await ($ as { ui: { mount: (x: never) => Promise<unknown> } }).ui.mount(toolRow(input, tool))) as Mounted
  const t = (await ui.findAll({ type: 'Text' })).map(x => x.text)
  await ui.unmount()
  return t
}
// Claude Code's own row beneath, drawn here as the input it was handed.
const engineRow = (on: On) =>
  on('ui.render', { component: 'ToolUse' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{JSON.stringify((e.props as { input?: unknown }).input)}</Text>
  })

test("the card call's row names the change alone, never the facts the card shows (#771)", withKit, async ($, on) => {
  engineRow(on)
  world(on)
  expect(await rowInput($, { ...CARD, requester: { name: 'Kris', via: 'named' }, message: 'It is live.' })).toEqual([JSON.stringify({ repo: REPO, pr: 412 })])
})

test("another tool's row is drawn as Claude Code draws it (#771)", withKit, async ($, on) => {
  engineRow(on)
  world(on)
  // An input carrying a repo and pr too, so only the tool's name keeps the row whole.
  const other = { repo: REPO, pr: 412, changed: 'x' }
  expect(await rowInput($, other, 'mcp__other__card')).toEqual([JSON.stringify(other)])
})

test('a card call missing its repo or pr keeps its whole row, so the refusal under it reads against what was sent (#771)', withKit, async ($, on) => {
  engineRow(on)
  world(on)
  const { pr: _pr, ...noPr } = CARD
  expect(await rowInput($, noPr)).toEqual([JSON.stringify(noPr)])
})

test('the answer tells Claude that Dan has already seen the card, so the reply does not restate it (#771)', withKit, async ($, on) => {
  world(on)
  await start($)
  const said = ((await card($, CARD)).context ?? []).join(' ')
  expect(said).toContain('Dan has already seen this card')
  expect(said).toContain('do not restate')
})

// /live reads the session's GitHub repository from its origin through mod-kit's one reader (#951),
// on the table every mod's reading is pinned on: the repository it asks GitHub about, or none.
test("/live reads the session's GitHub repository from its origin as mod-kit's reader does, on every shared case (#951)", withKit, async ($, on) => {
  const { w, runs } = world(on)
  const got: { why: string; github: string | null }[] = []
  for (const f of REPO_FIXTURES) {
    w.remote = f.remote
    runs.length = 0
    const said = await live($)
    const asked = runs.find(r => r.slice(0, 3).join(' ') === 'gh repo view')
    got.push({ why: f.why, github: asked ? (asked[3] as string) : said.startsWith('This folder has no GitHub repository') ? null : `unexpected: ${said}` })
  }
  expect(got).toEqual(REPO_FIXTURES.map(f => ({ why: f.why, github: f.github })))
})
