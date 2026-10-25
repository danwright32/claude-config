import { expect, mock } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { On, Register } from 'claude-code'

// The Goal accomplished box (claude-config#1563) in a session: shown once when a /goal is met (the
// session is told to show it, at the Stop hook if the met record is already written, else by a
// prompt of its own once the turn has ended) or when Claude judges the work Dan asked for finished
// and calls the tool; never while a merge, a deploy, an agent or a pull request is in flight.

const T = '/Users/dan/.claude/projects/-repo/s1.jsonl'
const TOOL = 'mcp__goal-box__goal_accomplished'
type Goal = { state: 'set'; condition: string } | { state: 'none'; met?: { condition: string; reason: string; id: string } } | { state: 'unreadable'; why: string }
type Card = { toolUseId: string; border?: string; title: { text: string; color?: string; bold?: boolean }[]; lines: { text: string; color?: string }[][] }

// mod-kit, standing in: a mod cannot import another mod's files, and a plugin in a test runs apart
// from the test's module, so it asks the world (process.run '__modkit') what the transcript's goal
// is and whether drawing the card fails. mod-kit's own tests prove the real reader on real records.
const kit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ask = async (what: string, arg = '') => JSON.parse((await built.process.run(['__modkit', what, arg])).stdout)
      const modkit = {
        card: async (c: { toolUseId: string }) => {
          const r = await built.process.run(['__modkit', 'card', JSON.stringify(c)])
          if (r.exitCode !== 0) throw new Error(r.stderr)
        },
        screen: async (call: unknown) => (JSON.stringify(call).includes('SCREEN-REFUSES') ? { deny: 'Blocked: this carries a secret.' } : null),
        goal: async ({ transcript }: { transcript: string }) => ask('goal', transcript),
        // The one reader of Dan's own words (#1135): what he types at the terminal or from his phone.
        isDans: async ({ origin }: { origin?: { readonly kind?: string } }) => origin?.kind === 'composer' || origin?.kind === 'bridge',
        // The kit's other members, which these tests never reach: each refuses by name if one ever is.
        blocked: async () => { throw new Error("mod-kit's blocked is not stood in by these tests") },
        commands: async () => { throw new Error("mod-kit's commands is not stood in by these tests") },
        writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
        git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
        gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
        mergeHelper: async () => { throw new Error("mod-kit's mergeHelper is not stood in by these tests") },
        ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
        linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
        pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
        pythonText: async () => { throw new Error("mod-kit's pythonText is not stood in by these tests") },
        login: async () => { throw new Error("mod-kit's login is not stood in by these tests") },
        account: async () => { throw new Error("mod-kit's account is not stood in by these tests") },
        workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
        repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
        branch: async () => { throw new Error("mod-kit's branch is not stood in by these tests") },
        bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
        clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
        pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
        clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
        press: async () => { throw new Error("mod-kit's press is not stood in by these tests") },
        clickable: async () => { throw new Error("mod-kit's clickable is not stood in by these tests") },
        typedAnswer: async () => { throw new Error("mod-kit's typedAnswer is not stood in by these tests") },
      }
      return { ...built, modkit }
    })
  },
}

// is it live, standing in: its session state, as its own contract has it, which this mod reads,
// written from what the world says at the session's start.
const live: { name: string; register: Register } = {
  name: 'is-it-live',
  register: on => {
    on('session.start', async ($, e, next) => {
      const facts = JSON.parse((await $.process.run(['__live'])).stdout) as { owed: unknown; verdicts: unknown }
      await $.state.set({ plugin: 'is-it-live', key: 'owed' } as never, facts.owed as never)
      await $.state.set({ plugin: 'is-it-live', key: 'verdicts' } as never, facts.verdicts as never)
      return next(e)
    })
  },
}
// The session registry, standing in: this session's record names the transcript the world says.
const registry: { name: string; register: Register } = {
  name: 'session-registry',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const sessions = {
        list: async () => {
          const r = await built.process.run(['__sessions'])
          if (r.exitCode !== 0) throw new Error(r.stderr)
          return JSON.parse(r.stdout)
        },
        noteEdit: async () => { throw new Error("the registry's noteEdit is not stood in by these tests") },
        setExtra: async () => { throw new Error("the registry's setExtra is not stood in by these tests") },
      }
      return { ...built, sessions }
    })
  },
}
type Owed = { key: string; how: 'merged' | 'unproven' | 'waiting'; pr: number; at: number; cwd: string; repo?: string }

type Gh = { exitCode: number; stdout: string; stderr?: string }
type World = {
  goal: Goal
  /** Why mod-kit refuses to draw the card, or '' when it draws it. */
  cardFails: string
  /** The cards mod-kit was asked to draw, in order. */
  cards: Card[]
  owed: Owed[]
  verdicts: Record<string, { state: string; at: number }>
  /** This session's transcript as its registry record names it ('' when it names none). */
  transcript: string
  /** The transcript's pr-link records, as Claude Code writes them. */
  links: string[]
  /** What `gh pr list --state open` answers per repository; absent answers an empty list. */
  open: Record<string, Gh>
  agents: { id: string; status: string; spawnedBy?: string; description?: string }[]
}
const link = (repo: string, pr: number, at = '2026-10-24T18:00:00.000Z') =>
  JSON.stringify({ type: 'pr-link', sessionId: 's1', prNumber: pr, prUrl: `https://github.com/${repo}/pull/${pr}`, prRepository: repo, timestamp: at })

const world = (on: On, init: Partial<World> = {}) => {
  const w: World = { goal: { state: 'none' }, cardFails: '', cards: [], transcript: T, owed: [], verdicts: {}, links: [], open: {}, agents: [], ...init }
  const runs: string[][] = []
  const submitted: { text: string; origin: unknown }[] = []
  const tools: { name: string; isDeferred?: unknown; description: string }[] = []
  const logs: string[] = []
  mock.clock(on, { now: 1_800_000_000_000 })
  on('process.run', ($, e) => {
    runs.push([...e.argv])
    const ok = (stdout: string, exitCode = 0, stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } }) as never
    if (e.argv[0] === '__modkit') {
      if (e.argv[1] === 'card') {
        if (w.cardFails) return ok('', 1, w.cardFails)
        w.cards.push(JSON.parse(e.argv[2] as string) as Card)
        return ok('')
      }
      return ok(JSON.stringify(w.goal))
    }
    if (e.argv[0] === '__sessions') {
      const me = { sessionId: 's1', transcriptPath: w.transcript || null, ...(w.transcript ? {} : { transcriptUnread: 'the transcript search was cut off' }) }
      return ok(JSON.stringify({ open: [me], closed: [], unreadable: [], selfId: 's1' }))
    }
    if (e.argv[0] === '__live') return ok(JSON.stringify({ owed: w.owed, verdicts: w.verdicts }))
    if (e.argv[0] === 'bash' && e.argv.includes('"type":"pr-link"')) {
      if (e.argv[e.argv.length - 1] !== T) return ok('', 2, `grep: ${e.argv[e.argv.length - 1]}: No such file or directory`)
      return w.links.length ? ok(`${w.links.join('\n')}\n`) : ok('', 1)
    }
    const a = e.argv.join(' ')
    if (a.startsWith('gh pr list')) {
      const repo = e.argv[e.argv.indexOf('--repo') + 1] as string
      const g = w.open[repo] ?? { exitCode: 0, stdout: '[]' }
      return ok(g.stdout, g.exitCode, g.stderr ?? '')
    }
    if (a.startsWith('gh auth status')) return ok('', 0, '  Logged in to github.com account danwright32 (keyring)\n')
    if (a.startsWith('gh auth token')) return ok('gho_test_not_a_token\n')
    return ok('', 1, 'unexpected')
  })
  on('agent.list', () => ({ value: w.agents.map(a => ({ description: 'a task', type: 'general-purpose', ...a })) }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }) as never)
  on('turn.complete', ($, e) => ({ text: e.answer }) as never)
  on('tool.register', ($, e) => {
    tools.push({ name: e.name, isDeferred: (e as { isDeferred?: unknown }).isDeferred, description: e.description })
    return { value: { tool: `mcp__goal-box__${e.name}` } } as never
  })
  on('prompt.submit', ($, e) => {
    submitted.push({ text: e.text, origin: e.origin })
    return { text: e.text } as never
  })
  on('ui.log', ($, e) => {
    logs.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  return { w, cards: async () => w.cards, runs: () => runs.filter(a => !a[0]?.startsWith('__')), submitted, tools, logs }
}

type Engine = Parameters<Parameters<typeof test>[2]>[0]
const start = async ($: Engine, isInteractive = true) => {
  await $.session.start({ cwd: '/repo', surface: isInteractive ? 'terminal' : null, isInteractive } as never)
}
// Dan types a message, or something else sends one.
const says = ($: Engine, text: string, kind = 'composer') => $.prompt.submit({ text, origin: { kind }, wait: false } as never)
type Out = { deny?: string; result?: unknown; text?: string; context?: readonly string[] }
const box = async ($: Engine, input: Record<string, unknown>, id = 'b1', more: Record<string, unknown> = {}) =>
  (await $.tool.call({ tool: TOOL, tool_use_id: id, ...input, ...more } as never)) as Out
const textOf = (o: Out) => String(o.deny ?? o.text ?? o.result ?? '')
const turnEnds = ($: Engine, more: Record<string, unknown> = {}) =>
  $.turn.complete({ answer: 'done', durationMs: 10, isAborted: false, turnId: 't1', reason: 'answer', ...more } as never)

const ASKED = { goal: 'Show a green box when the goal is met', shipped: ['#1563 closed: Goal accomplished box', 'PR #1700 merged and live'] }
const MET = { state: 'none' as const, met: { condition: 'complete issue 1563', reason: 'Issue #1563 is closed and PR #1700 is merged.', id: 'met-1' } }
const withKit = { plugins: [kit, registry] }
const withLive = { plugins: [kit, registry, live] }

test('the tool is offered to an interactive session with its rules in the prompt, never to a headless one', withKit, async ($, on) => {
  const { tools, cards } = world(on)
  await start($)
  expect(tools.map(t => t.name)).toEqual(['goal_accomplished'])
  expect(tools[0]?.isDeferred).toBe(false)
  expect(tools[0]?.description).toMatch(/once/)
  expect(tools[0]?.description).toMatch(/\/goal/)
})

test('a headless session is not offered the tool', withKit, async ($, on) => {
  const { tools, cards } = world(on)
  await start($, false)
  expect(tools).toEqual([])
})

test('the work Dan asked for, finished: the box is the tool result, drawn as the green headed card, the goal then each thing shipped', withKit, async ($, on) => {
  const { cards } = world(on)
  await start($)
  await says($, 'Add the goal box from issue 1563')
  const r = await box($, ASKED)
  expect(r.deny).toBeUndefined()
  const t = textOf(r)
  expect(t.split('\n').slice(0, 3)).toEqual([`╔${'═'.repeat(19)}╗`, '║ GOAL ACCOMPLISHED ║', `╚${'═'.repeat(19)}╝`])
  expect(t).toContain('Goal: Show a green box when the goal is met')
  expect(t).toContain('• PR #1700 merged and live')
  expect((r.context ?? []).join(' ')).toMatch(/do not repeat/i)
  const [c] = await cards()
  expect(c?.toolUseId).toBe('b1')
  expect(c?.title).toEqual([{ text: 'GOAL ACCOMPLISHED', color: 'success', bold: true }])
  expect(c?.lines.map(l => l.map(x => x.text).join(''))).toEqual(['Show a green box when the goal is met', '• #1563 closed: Goal accomplished box', '• PR #1700 merged and live'])
  // Settled with Dan in the #1563 design round (2026-10-24, "Green border and heading"): the border,
  // the heading and the bullets green; the goal and the shipped lines plain.
  expect(c?.border).toBe('success')
  expect(c?.lines[0]?.map(x => x.color)).toEqual([undefined])
  expect(c?.lines.slice(1).map(l => l.map(x => x.color))).toEqual([['success', undefined], ['success', undefined]])
})

test('never twice for one request: a second call is refused until Dan asks for something new', withKit, async ($, on) => {
  const { cards } = world(on)
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED, 'b1')).deny).toBeUndefined()
  const again = await box($, ASKED, 'b2')
  expect(again.deny).toMatch(/already shown for this request/)
  // A background task's notice, or another plugin's message, is not Dan asking for something new.
  await says($, '<task-notification>done</task-notification>', 'task-notification')
  expect((await box($, ASKED, 'b3')).deny).toMatch(/already shown/)
  await says($, 'Now make the status bar quieter')
  expect((await box($, { goal: 'Quieter status bar', shipped: ['#1701 closed'] }, 'b4')).deny).toBeUndefined()
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b1', 'b4'])
})

test('two calls at once show one box: the second is refused', withKit, async ($, on) => {
  const { cards } = world(on)
  await start($)
  await says($, 'Add the goal box')
  const [a, b] = await Promise.all([box($, ASKED, 'p1'), box($, ASKED, 'p2')])
  expect([a.deny, b.deny].filter(d => d === undefined)).toHaveLength(1)
  expect(String(a.deny ?? b.deny)).toMatch(/already shown/)
  expect(await cards()).toHaveLength(1)
})

test('two calls at once for a met /goal show one box', withKit, async ($, on) => {
  const { cards } = world(on, { goal: MET })
  await start($)
  const [a, b] = await Promise.all([box($, ASKED, 'g1'), box($, ASKED, 'g2')])
  expect([a.deny, b.deny].filter(d => d === undefined)).toHaveLength(1)
  expect(await cards()).toHaveLength(1)
})

test('not while a merge is unconfirmed or a deploy is not live: refused naming each, shown once settled', withLive, async ($, on) => {
  const { cards } = world(on, {
    owed: [{ key: 'k', how: 'waiting', pr: 1700, at: 1, cwd: '/repo', repo: 'danwright32/claude-config' }],
    verdicts: { 'danwright32/claude-config#1699': { state: 'deploying', at: 1 }, 'danwright32/claude-config#1698': { state: 'unconfirmed', at: 1 }, 'danwright32/claude-config#1697': { state: 'live', at: 1 } },
  })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/the merge of danwright32\/claude-config#1700 has not been confirmed/)
  expect(r.deny).toMatch(/danwright32\/claude-config#1699 is still deploying/)
  expect(r.deny).toMatch(/danwright32\/claude-config#1698's deploy was not confirmed live/)
  expect(r.deny).not.toMatch(/1697/)
  expect(await cards()).toEqual([])
})

test('a merge settled as live holds nothing', withLive, async ($, on) => {
  const { cards } = world(on, { verdicts: { 'danwright32/claude-config#1697': { state: 'live', at: 1 }, 'danwright32/claude-config#1696': { state: 'no-deploy', at: 1 } } })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toBeUndefined()
})

test('not while a pull request this session touched is still open: GitHub asked once per repository, as each account', withKit, async ($, on) => {
  const { w, runs, cards } = world(on, {
    links: [link('danwright32/claude-config', 1700), link('danwright32/claude-config', 1700, '2026-10-24T18:05:00.000Z'), link('danwright32/claude-config', 1701), link('DanWright32/Overture', 4694)],
    open: { 'danwright32/claude-config': { exitCode: 0, stdout: JSON.stringify([{ number: 1701 }, { number: 1650 }]) } },
  })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/danwright32\/claude-config#1701 is still open/)
  expect(r.deny).not.toMatch(/1700|1650|4694/)
  expect(runs().filter(a => a[0] === 'gh' && a[1] === 'pr').map(a => a[a.indexOf('--repo') + 1])).toEqual(['danwright32/claude-config', 'danwright32/overture'])
  w.open = {}
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
})

test('a pull request GitHub cannot be asked about holds the box, saying it could not be confirmed', withKit, async ($, on) => {
  const { cards } = world(on, { links: [link('danwright32/claude-config', 1700)], open: { 'danwright32/claude-config': { exitCode: 1, stdout: '', stderr: 'error connecting to api.github.com' } } })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/could not ask GitHub whether danwright32\/claude-config's pull requests .*are still open \(error connecting to api.github.com\)/)
  expect(await cards()).toEqual([])
})

test("a transcript whose pull requests cannot be read holds the box, saying why", withKit, async ($, on) => {
  const { cards } = world(on, { transcript: '/elsewhere.jsonl' })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/pull requests this session touched could not be read \(grep: \/elsewhere.jsonl: No such file or directory\)/)
  expect(await cards()).toEqual([])
})

test("a session whose transcript the registry cannot name holds the box, saying why", withKit, async ($, on) => {
  const { cards } = world(on, { transcript: '' })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toMatch(/the transcript search was cut off/)
  expect(await cards()).toEqual([])
})

test('not while an agent this session started is still running; one a plugin started, or one finished, holds nothing', withKit, async ($, on) => {
  const { w, cards } = world(on, { agents: [{ id: 'a1', status: 'running', description: 'Fix issue 1702' }, { id: 'a2', status: 'completed' }, { id: 'a3', status: 'running', spawnedBy: 'auto-session-name' }, { id: 'a4', status: 'idle' }] })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/the agent "Fix issue 1702" is still running/)
  expect(r.deny).not.toMatch(/a3|auto-session-name/)
  w.agents = [{ id: 'a1', status: 'completed' }]
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
})

test('a /goal still set is never shown over, and a goal that cannot be read holds the box', withKit, async ($, on) => {
  const { cards } = world(on, { goal: { state: 'set', condition: 'complete milestone 80' } })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toMatch(/the \/goal "complete milestone 80" is still set/)
})

test('a /goal that cannot be read holds the box, saying why', withKit, async ($, on) => {
  const { cards } = world(on, { goal: { state: 'unreadable', why: 'grep: read error' } })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toMatch(/could not be read \(grep: read error\)/)
})

// Measured on 2.1.310: the met record is written after the Stop hooks, before the turn ends, so the
// mod asks at turn.complete and hooks no Stop (no classic event reaches a mod, #875).
test('a /goal met: once the turn has ended the session is sent one prompt to show the box, which names the goal', withKit, async ($, on) => {
  const { w, submitted, cards } = world(on, { goal: { state: 'set', condition: 'complete issue 1563' } })
  await start($)
  await turnEnds($)
  expect(submitted).toEqual([])
  w.goal = MET
  await turnEnds($)
  expect(submitted.map(s => s.text)).toEqual([expect.stringContaining('GOAL ACCOMPLISHED. The /goal "complete issue 1563" was judged met.')])
  expect(submitted[0]?.text).toContain(TOOL)
  await turnEnds($)
  expect(submitted).toHaveLength(1)
  const r = await box($, { goal: 'whatever Claude calls it', shipped: ['#1563 closed'] })
  expect(r.deny).toBeUndefined()
  expect(textOf(r)).toContain('Goal: complete issue 1563')
  // Once shown, never again for that goal, nor for the request it answered, until Dan asks for more.
  expect((await box($, { goal: 'again', shipped: ['x'] }, 'b2')).deny).toMatch(/already shown/)
  await turnEnds($)
  expect(submitted).toHaveLength(1)
  expect(await cards()).toHaveLength(1)
})

test("a subagent's turn end, or an interrupted turn, never sends the prompt", withKit, async ($, on) => {
  const { submitted } = world(on, { goal: MET })
  await start($)
  await turnEnds($, { agentId: 'a1' })
  await turnEnds($, { isAborted: true, reason: 'aborted' })
  expect(submitted).toEqual([])
})

test('a headless session is never asked to show the box', withKit, async ($, on) => {
  const { submitted } = world(on, { goal: MET })
  await start($, false)
  await turnEnds($)
  expect(submitted).toEqual([])
})

test('a met goal whose box is held by an open merge is not shown; asked once, it is not asked again', withLive, async ($, on) => {
  const { submitted, cards } = world(on, { goal: MET, owed: [{ key: 'k', how: 'waiting', pr: 1700, at: 1, cwd: '/repo', repo: 'danwright32/claude-config' }] })
  await start($)
  await turnEnds($)
  expect(submitted).toHaveLength(1)
  expect((await box($, { goal: 'x', shipped: ['y'] })).deny).toMatch(/has not been confirmed/)
  await turnEnds($)
  expect(submitted).toHaveLength(1)
  expect(await cards()).toEqual([])
})

test('a subagent cannot show the box, and a call a guard refuses is refused before anything is read', withKit, async ($, on) => {
  const { runs, cards } = world(on)
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED, 'b1', { agentId: 'a1' })).deny).toMatch(/only the main conversation/i)
  expect((await box($, { goal: 'SCREEN-REFUSES', shipped: ['x'] })).deny).toBe('Blocked: this carries a secret.')
  expect(runs()).toEqual([])
  expect(await cards()).toEqual([])
})

test('a call missing the goal or what shipped is refused by name', withKit, async ($, on) => {
  const { cards } = world(on)
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, { goal: '', shipped: ['x'] })).deny).toMatch(/goal must be/)
  expect((await box($, { goal: 'x', shipped: [] })).deny).toMatch(/shipped is empty/)
  expect((await box($, { goal: 'x', shipped: ['ok', 7] })).deny).toMatch(/shipped line 2/)
  expect((await box($, { goal: 'x' })).deny).toMatch(/shipped must be a list/)
})

test("mod-kit unable to draw the card still shows the boxed text, and says why in the debug log", withKit, async ($, on) => {
  const { logs, cards } = world(on, { cardFails: 'a card needs a title of one or more runs' })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toBeUndefined()
  expect(textOf(r)).toContain('║ GOAL ACCOMPLISHED ║')
  expect(logs.join('\n')).toMatch(/goal-box: the card could not be drawn \(a card needs a title/)
})
