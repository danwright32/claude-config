import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

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
        bandRow: async (row: Row) => {
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
      }
      return { ...built, modkit } as never
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
                    <Button key={`${r.mod}:${p.button}`} label={p.label as string} onPress={() => undefined} />
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
type World = { pr: Gh; issue: Gh; me: Gh; copied: boolean }

// GitHub, the clipboard, the store, toasts and Claude Code's own band beneath the mod.
const world = (on: On, init: Partial<World> = {}) => {
  const w: World = {
    pr: { exitCode: 0, stdout: JSON.stringify({ state: 'MERGED', title: 'Filter bookings by venue', url: `https://github.com/${REPO}/pull/412` }) },
    issue: { exitCode: 0, stdout: JSON.stringify({ author: { login: 'kris-k' } }) },
    me: { exitCode: 0, stdout: 'danwright32\n' },
    copied: true,
    ...init,
  }
  const toasts: string[] = []
  const copies: string[] = []
  const runs: string[][] = []
  mock.clock(on, { now: T0 })
  mock.store(on)
  on('process.run', ($, e) => {
    runs.push([...e.argv])
    const a = e.argv.join(' ')
    const g = a.startsWith('gh pr view') ? w.pr : a.startsWith('gh issue view') ? w.issue : a.startsWith('gh api user') ? w.me : { exitCode: 1, stdout: '', stderr: 'unexpected' }
    return { value: { exitCode: g.exitCode, stdout: g.stdout, stderr: g.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false } } as never
  })
  on('session.repo', () => ({ value: { root: '/Users/dan/Apps/slate', remote: `git@github.com:${REPO}.git`, isOwn: false } }) as never)
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
