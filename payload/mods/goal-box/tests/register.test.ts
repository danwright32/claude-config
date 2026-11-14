import { expect, mock } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { On, Register } from 'claude-code'
import DESIGN_FIXTURE from './1563-goal-box.fixture.ts'

// The Goal accomplished box (claude-config#1563) in a session: shown once when a /goal is met (the
// session is sent a prompt of its own asking for it once the turn has ended, since the met record
// lands after the Stop hooks and the mod hooks no Stop) or when Claude judges the work Dan asked for
// finished and calls the tool; never while a merge, a deploy, an agent or a pull request is in flight.

const T = `${'/Users'}/dan/.claude/projects/-repo/s1.jsonl`
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
        // The one reader of a github.com link's repository, standing in: owner/name as the link spells it.
        linkRepo: async ({ link }: { link: string }) => {
          const parts = link.startsWith('https://github.com/') ? new URL(link).pathname.split('/').filter(Boolean) : []
          return parts.length >= 2 ? `${parts[0]}/${parts[1]}` : null
        },
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
        // #2132: a hold on goal-box's reload and its letting go, asked of the world, which keeps
        // them in order beside each prompt sent and can refuse one as mod-kit would.
        hold: async (input: unknown) => {
          const r = await built.process.run(['__modkit', 'hold', JSON.stringify(input)])
          if (r.exitCode !== 0) throw new Error(r.stderr)
        },
        release: async (input: unknown) => {
          const r = await built.process.run(['__modkit', 'release', JSON.stringify(input)])
          if (r.exitCode !== 0) throw new Error(r.stderr)
        },
      }
      return { ...built, modkit }
    })
  },
}

// is it live, standing in: its session state, as its own contract has it, which this mod reads,
// written from what the world says at the session's start, and again at each turn end before this
// mod reads it, as is it live's own record moves while a session runs (a deploy going live, #2523).
const live: { name: string; register: Register } = {
  name: 'is-it-live',
  register: on => {
    on('session.start', async ($, e, next) => {
      const facts = JSON.parse((await $.process.run(['__live'])).stdout) as { owed: unknown; verdicts: unknown }
      await $.state.set({ plugin: 'is-it-live', key: 'owed' } as never, facts.owed as never)
      await $.state.set({ plugin: 'is-it-live', key: 'verdicts' } as never, facts.verdicts as never)
      return next(e)
    })
    on('turn.complete', async ($, e, next) => {
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
type Owed = { key: string; how: 'merged' | 'unproven' | 'waiting'; pr: number; at: number; cwd: string; repo?: string; named?: string; selector?: string }

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
  /**
   * How the session registry holds this session (#2898): open, as a live session's record is; closed,
   * as the real registry lists a live session whose record a session end it outlived closed (no
   * transcript looked up for it); or absent, with no id of its own (selfId null).
   */
  registry: 'open' | 'closed' | 'closed naming it' | 'absent'
  /** Where a transcript is on disk, by path; a string is the error checking that path gives. */
  disk: Record<string, true | string>
  /** The folder the session is in now, where it started in /repo. */
  here: string
  /** The transcript's pr-link records, as Claude Code writes them. */
  links: string[]
  /** What `gh pr list --state open` answers per repository; absent answers an empty list. */
  open: Record<string, Gh>
  agents: { id: string; status: string; spawnedBy?: string; description?: string }[]
  /** How each of the mod's own next prompts fails, in order: thrown, or dropped by a hook beneath. */
  submitFails: ('throw' | 'drop')[]
  /** #2132: each hold, letting go and prompt the mod sent, in order; and why mod-kit refuses a hold, or ''. */
  held: string[]
  holdFails: string
  /** What `gh pr view` answers, by the repository it names (or the folder it runs in) and the account's token. */
  view: (q: { pr: string; repo?: string; cwd?: string; token?: string }) => Gh
}
const link = (repo: string, pr: number, at = '2026-10-24T18:00:00.000Z') =>
  JSON.stringify({ type: 'pr-link', sessionId: 's1', prNumber: pr, prUrl: `https://github.com/${repo}/pull/${pr}`, prRepository: repo, timestamp: at })

const world = (on: On, init: Partial<World> = {}) => {
  const w: World = { goal: { state: 'none' }, cardFails: '', cards: [], transcript: T, registry: 'open', disk: {}, here: '/repo', owed: [], verdicts: {}, links: [], open: {}, agents: [], submitFails: [], held: [], holdFails: '', view: () => ({ exitCode: 1, stdout: '', stderr: 'unexpected' }), ...init }
  const runs: string[][] = []
  const views: { pr: string; repo?: string; cwd?: string; token?: string; fields?: string }[] = []
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
      if (e.argv[1] === 'hold' || e.argv[1] === 'release') {
        if (e.argv[1] === 'hold' && w.holdFails) return ok('', 1, w.holdFails)
        w.held.push(`${e.argv[1]} ${e.argv[2]}`)
        return ok('')
      }
      return ok(JSON.stringify(w.goal))
    }
    if (e.argv[0] === '__sessions') {
      const me = { sessionId: 's1', transcriptPath: w.transcript || null, ...(w.transcript ? {} : { transcriptUnread: 'the transcript search was cut off' }) }
      if (w.registry === 'closed') return ok(JSON.stringify({ open: [], closed: [{ sessionId: 's1', transcriptPath: null }], unreadable: [], selfId: 's1' }))
      if (w.registry === 'closed naming it') return ok(JSON.stringify({ open: [], closed: [{ sessionId: 's1', transcriptPath: w.transcript }], unreadable: [], selfId: 's1' }))
      if (w.registry === 'absent') return ok(JSON.stringify({ open: [], closed: [], unreadable: [], selfId: null }))
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
    if (a.startsWith('gh pr view')) {
      const init = (e as { init?: { cwd?: string; env?: Record<string, string> } }).init
      const at = (flag: string) => (e.argv.includes(flag) ? (e.argv[e.argv.indexOf(flag) + 1] as string) : undefined)
      const repo = at('--repo')
      const q = { pr: e.argv[3] as string, ...(repo ? { repo } : {}), ...(init?.cwd ? { cwd: init.cwd } : {}), ...(init?.env?.GH_TOKEN ? { token: init.env.GH_TOKEN } : {}) }
      const fields = at('--json')
      views.push({ ...q, ...(fields ? { fields } : {}) })
      const g = w.view(q)
      return ok(g.stdout, g.exitCode, g.stderr ?? '')
    }
    if (a.startsWith('gh auth status')) return ok('', 0, '  Logged in to github.com account danwright32 (keyring)\n')
    if (a.startsWith('gh auth token')) return ok('gho_test_not_a_token\n')
    return ok('', 1, 'unexpected')
  })
  on('agent.list', () => ({ value: w.agents.map(a => ({ description: 'a task', type: 'general-purpose', ...a })) }) as never)
  on('session.id', () => ({ value: 's1' }) as never)
  on('session.cwd', () => ({ value: w.here }) as never)
  on('env.get', ($, e) => ({ value: (e as unknown as { name: string }).name === 'HOME' ? `${'/Users'}/dan` : undefined }) as never)
  on('fs.exists', ($, e) => {
    const at = w.disk[e.path]
    return (typeof at === 'string' ? { deny: at } : { value: at === true }) as never
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }) as never)
  on('turn.complete', ($, e) => ({ text: e.answer }) as never)
  on('tool.register', ($, e) => {
    tools.push({ name: e.name, isDeferred: (e as { isDeferred?: unknown }).isDeferred, description: e.description })
    return { value: { tool: `mcp__goal-box__${e.name}` } } as never
  })
  on('prompt.submit', ($, e) => {
    if ((e.origin as { kind?: string } | undefined)?.kind === 'plugin') {
      w.held.push('submit')
      const fails = w.submitFails.shift()
      if (fails === 'throw') throw new Error('the session is shutting down')
      if (fails === 'drop') return { drop: 'held by a guard beneath' } as never
    }
    submitted.push({ text: e.text, origin: e.origin })
    return { text: e.text } as never
  })
  on('ui.log', ($, e) => {
    logs.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  return { w, cards: async () => w.cards, runs: () => runs.filter(a => !a[0]?.startsWith('__')), submitted, tools, logs, views }
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
const DESIGN: { goal: string; shipped: string[] } = DESIGN_FIXTURE
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
  // #2512: the text result leads with the goal and the shipped lines follow at once, so Claude
  // Code's collapse of a tool result after its first lines (where the card is not drawn: a resumed
  // session) still shows the goal and what shipped at rest, never a heading alone above "+5 lines".
  expect(textOf(r).split('\n')).toEqual(['GOAL ACCOMPLISHED: Show a green box when the goal is met', '• #1563 closed: Goal accomplished box', '• PR #1700 merged and live'])
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

// The settled design's own goal and shipped lines (docs/design/1563-goal-box.html draws them from
// its committed fixture; a mod's test loads only code, so the copy here is that file's bytes behind
// `export default `, and tests/test-mods.sh holds it byte for byte to the design's),
// drawn by the mod as the design's card draws them: the bold green heading, the goal first in plain
// text, then each shipped line behind a green bullet, in a green border (claude-config#1729).
test('the settled design\'s fixture, drawn by the mod, is the card the design draws', withKit, async ($, on) => {
  const { cards } = world(on)
  await start($)
  await says($, 'Finish the open issues')
  expect(DESIGN.shipped.length).toBeGreaterThan(0)
  expect((await box($, DESIGN)).deny).toBeUndefined()
  const [c] = await cards()
  expect(c?.title).toEqual([{ text: 'GOAL ACCOMPLISHED', color: 'success', bold: true }])
  expect(c?.border).toBe('success')
  expect(c?.lines.map(l => l.map(x => x.text).join(''))).toEqual([DESIGN.goal, ...DESIGN.shipped.map(s => `• ${s}`)])
  expect(c?.lines[0]?.map(x => x.color)).toEqual([undefined])
  expect(c?.lines.slice(1).map(l => l[0]?.color)).toEqual(DESIGN.shipped.map(() => 'success'))
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

// #1818: a merge the helper made in the background is "waiting" in is it live's record until a turn
// end asks GitHub again, and that ask can fail (one account, a folder since removed) or never come, so
// the box asks GitHub itself, as each account, with `gh pr view`. It counts only an answer that says
// MERGED for that exact pull request in that exact repository; a call that failed, or an answer about
// another number or repository, still holds the box.
const WORK_REPO = 'acme-hq/booking'
const RAN = 1_799_999_000_000
const MERGED_AT = 1_799_999_500_000
const waiting = (pr: number, more: Partial<Owed> = {}): Owed => ({ key: `wait:${WORK_REPO}#${pr}@${RAN}`, how: 'waiting', pr, at: RAN, cwd: '/gone/worktree', selector: String(pr), named: WORK_REPO, repo: WORK_REPO, ...more })
const answer = (pr: number, more: Record<string, unknown> = {}): Gh => ({
  exitCode: 0,
  stdout: JSON.stringify({ number: pr, state: 'MERGED', mergedAt: new Date(MERGED_AT).toISOString(), url: `https://github.com/${WORK_REPO}/pull/${pr}`, ...more }),
})

test('a background merge GitHub says is MERGED, for that number in that repository, holds nothing once its card is made', withLive, async ($, on) => {
  const { views } = world(on, { owed: [waiting(4284)], verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: MERGED_AT + 1 } }, view: q => answer(Number(q.pr)) })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toBeUndefined()
  // Asked by its repository, never the folder it was merged from (which may be gone), with every field the check reads.
  expect(views).toEqual([{ pr: '4284', repo: WORK_REPO, fields: 'number,state,mergedAt,url' }])
})

test('a background merge GitHub confirms but no card has been made for holds the box as owed its card, not as unconfirmed', withLive, async ($, on) => {
  world(on, { owed: [waiting(4284)], verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: RAN - 1 } }, view: q => answer(Number(q.pr)) })
  await start($)
  await says($, 'Finish milestone 77')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/acme-hq\/booking#4284 was merged and has no is it live card yet/)
  expect(r.deny).not.toMatch(/not been confirmed/)
})

test('a merge GitHub only answers for as another account is confirmed: asked as each account gh is logged in to', withLive, async ($, on) => {
  const { views } = world(on, {
    owed: [waiting(4284)],
    verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: MERGED_AT } },
    view: q => (q.token ? answer(Number(q.pr)) : { exitCode: 1, stdout: '', stderr: 'GraphQL: Could not resolve to a Repository with the name acme-hq/booking.' }),
  })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(views.map(v => v.token ?? 'active')).toEqual(['active', 'gho_test_not_a_token'])
})

test('no other answer confirms a background merge: a failed call, another number, another repository, open, or no merge time', withLive, async ($, on) => {
  const { w } = world(on, { owed: [waiting(4284)], verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: MERGED_AT + 1 } } })
  await start($)
  await says($, 'Finish milestone 77')
  const refused: [string, Gh, RegExp][] = [
    ['a call that failed for every account', { exitCode: 1, stdout: '', stderr: 'error connecting to api.github.com' }, /error connecting to api\.github\.com/],
    ['an answer about another pull request', answer(4285), /#4285/],
    ['an answer whose number and link disagree', answer(4284, { url: `https://github.com/${WORK_REPO}/pull/4285` }), /pull\/4285/],
    ['an answer about another repository', answer(4284, { url: 'https://github.com/acme-hq/other/pull/4284' }), /acme-hq\/other/],
    ['a pull request still open', answer(4284, { state: 'OPEN', mergedAt: null }), /GitHub says it is still open/],
    ['a merge with no time', answer(4284, { mergedAt: null }), /no time/],
    ['an answer that is not JSON', { exitCode: 0, stdout: 'MERGED' }, /could not be read/],
  ]
  for (const [what, g, why] of refused) {
    w.view = () => g
    const deny = (await box($, ASKED)).deny ?? ''
    expect({ what, unconfirmed: /the merge of acme-hq\/booking#4284 has not been confirmed yet/.test(deny), why: why.test(deny) }).toEqual({ what, unconfirmed: true, why: true })
  }
  w.view = q => answer(Number(q.pr))
  expect((await box($, ASKED)).deny).toBeUndefined()
})

// #1991: is it live's turn end and the box ask GitHub through one check (mod-kit's prmerged.ts), so
// they settle a background merge alike: one GitHub says was closed unmerged, or whose number is no
// pull request in that repository, merged nothing, is let go at is it live's turn end, and owes no
// card, so it holds the box no longer.
test('a background merge GitHub says was closed, or names no pull request, holds nothing, as is it live lets it go', withLive, async ($, on) => {
  const { w } = world(on, { owed: [waiting(4284)] })
  await start($)
  await says($, 'Finish milestone 77')
  w.view = () => answer(4284, { state: 'CLOSED', mergedAt: null })
  expect((await box($, ASKED)).deny).toBeUndefined()
  // A box is shown once per request, so the next answer is asked under a new one.
  await says($, 'Finish milestone 78')
  w.view = () => ({ exitCode: 1, stdout: '', stderr: 'GraphQL: Could not resolve to a PullRequest with the number of 4284. (repository.pullRequest)' })
  expect((await box($, ASKED)).deny).toBeUndefined()
})

test('a background merge GitHub says merged before the helper run started still counts, settled by a card made since it merged (#1991)', withLive, async ($, on) => {
  const earlier = (at: number) => answer(4284, { mergedAt: new Date(at).toISOString() })
  world(on, { owed: [waiting(4284)], verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: RAN - 3_000_000 } }, view: () => earlier(RAN - 3_600_000) })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toBeUndefined()
})

test('a pull request the helper was run for twice is asked about once and named once', withLive, async ($, on) => {
  const { views } = world(on, { owed: [waiting(4290), waiting(4290, { key: `wait:${WORK_REPO}#4290@${RAN + 5}`, at: RAN + 5 })] })
  await start($)
  await says($, 'Finish milestone 77')
  const r = await box($, ASKED)
  expect(r.deny?.match(/acme-hq\/booking#4290/g)).toHaveLength(1)
  expect(views.filter(v => !v.token)).toHaveLength(1)
})

test('a background merge naming no repository is asked about in the folder it was merged from, and named by the link GitHub gives', withLive, async ($, on) => {
  const { views } = world(on, {
    owed: [{ key: `wait:/repo#4284@${RAN}`, how: 'waiting', pr: 4284, at: RAN, cwd: '/repo', selector: '4284' }],
    verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: MERGED_AT + 1 } },
    view: q => (q.cwd === '/repo' && !q.repo ? answer(Number(q.pr)) : { exitCode: 1, stdout: '', stderr: 'unexpected' }),
  })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(views[0]).toEqual({ pr: '4284', cwd: '/repo', fields: 'number,state,mergedAt,url' })
})

// is it live crosses a carded merge off its record only at a turn end, so a card made since then is
// read from its verdicts: one made since the merge settles it, one older (another merge's) does not.
const MERGED_4305: Owed = { key: `${WORK_REPO}#4305`, how: 'merged', pr: 4305, at: RAN, cwd: '/repo', repo: WORK_REPO }
test('a merge is it live has not yet crossed off is settled by a card made since it merged', withLive, async ($, on) => {
  world(on, { owed: [MERGED_4305], verdicts: { [`${WORK_REPO}#4305`]: { state: 'live', at: RAN + 1 } } })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toBeUndefined()
})

test('a card made before the merge does not settle it', withLive, async ($, on) => {
  world(on, { owed: [MERGED_4305], verdicts: { [`${WORK_REPO}#4305`]: { state: 'live', at: RAN - 1 } } })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toMatch(/acme-hq\/booking#4305 was merged and has no is it live card yet/)
})

// L50: is it live's record is another mod's state, read here; one not in the shape its contract
// says (an older or newer copy of that mod) holds the box, saying so, rather than failing the call.
test("an is it live record not in its contract's shape holds the box, saying so", withLive, async ($, on) => {
  const { cards } = world(on, { owed: 'not a list' as never, verdicts: { 'danwright32/claude-config#1699': null as never } })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/is it live's record of this session's merges could not be read/)
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

// #2898: a live session the registry counts as ended, or holds no record of, was refused with "this
// session's transcript was not found in the session registry" though its transcript sat where Claude
// Code keeps it. Reproduced against the real registry: a session end the process outlives (a resume
// keeping its id, before the look that reopens it; any other reason, for good) leaves the record
// closed, and a closed record's transcript is never looked up. So the session's own transcript is
// first the one at its id's path, as scope-modes finds its own (#1678), and the registry's after.
for (const registry of ['closed', 'absent'] as const) {
  test(`a live session the registry holds as ${registry} finds its transcript at its id's path, and the box shows (#2898)`, withKit, async ($, on) => {
    const { cards } = world(on, { registry, disk: { [T]: true }, links: [link('danwright32/claude-config', 1700)] })
    await start($)
    await says($, 'Add the goal box')
    const r = await box($, ASKED)
    expect(r.deny).toBeUndefined()
    expect(await cards()).toHaveLength(1)
  })
}

test("a record the registry counts as ended that still names its transcript is used, as it was before (#2898)", withKit, async ($, on) => {
  const { cards } = world(on, { registry: 'closed naming it' })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(await cards()).toHaveLength(1)
})

test("the transcript is looked for in the folder the session started in, after it moved into another (#2898)", withKit, async ($, on) => {
  const { cards } = world(on, { registry: 'closed', disk: { [T]: true }, here: '/repo/.claude/worktrees/fix' })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(await cards()).toHaveLength(1)
})

test("a transcript found nowhere is refused saying where it looked and how the registry holds the session, never that a goal is open (#2898)", withKit, async ($, on) => {
  const { w, cards } = world(on, { registry: 'absent' })
  await start($)
  await says($, 'Add the goal box')
  const absent = (await box($, ASKED)).deny ?? ''
  expect(absent).toContain(`not at ${T}`)
  expect(absent).toMatch(/the session registry has no record of this session/)
  expect(absent).not.toMatch(/not found in the session registry|still set/)
  w.registry = 'closed'
  const closed = (await box($, ASKED, 'b2')).deny ?? ''
  expect(closed).toMatch(/the session registry counts this session as ended, so it did not look its transcript up/)
  expect(await cards()).toEqual([])
})

test("a check at the id's path that fails is said beside the registry's why, and the registry's transcript is used when it names one (#2898)", withKit, async ($, on) => {
  const { w, cards } = world(on, { transcript: '', disk: { [T]: "EACCES: permission denied, stat" } })
  await start($)
  await says($, 'Add the goal box')
  const r = (await box($, ASKED)).deny ?? ''
  expect(r).toContain(`whether it is at ${T} could not be checked`)
  expect(r).toMatch(/permission denied/)
  expect(r).toMatch(/the transcript search was cut off/)
  w.transcript = T
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
  expect(await cards()).toHaveLength(1)
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
  expect(textOf(r).split('\n')[0]).toBe('GOAL ACCOMPLISHED: complete issue 1563')
  // Once shown, never again for that goal, nor for the request it answered, until Dan asks for more.
  expect((await box($, { goal: 'again', shipped: ['x'] }, 'b2')).deny).toMatch(/already shown/)
  await turnEnds($)
  expect(submitted).toHaveLength(1)
  expect(await cards()).toHaveLength(1)
})

// L368: a met goal is recorded as asked about only once its prompt has entered, so a failure (one
// thrown, or one a hook beneath dropped) is said and asked again at the next turn end, never lost.
test('a prompt for a met goal that could not be sent is said and sent again at the next turn end', withKit, async ($, on) => {
  const { submitted, logs } = world(on, { goal: MET, submitFails: ['throw', 'drop'] })
  await start($)
  await turnEnds($)
  expect(submitted).toEqual([])
  expect(logs.join('\n')).toMatch(/could not be asked for \(.+\); it is asked again at the next turn end/)
  await turnEnds($)
  expect(submitted).toEqual([])
  expect(logs.join('\n')).toMatch(/could not be asked for \(held by a guard beneath\); it is asked again at the next turn end/)
  await turnEnds($)
  expect(submitted.map(x => x.text)).toEqual([expect.stringContaining('GOAL ACCOMPLISHED. The /goal "complete issue 1563" was judged met.')])
  await turnEnds($)
  expect(submitted).toHaveLength(1)
})

// #2132: the prompt for a met goal waits until the session is idle, and mod-kit's reload of goal-box
// in that time would drop it, so it holds that reload back until sent, thrown or dropped.
const GOAL_HELD = `hold ${JSON.stringify({ mod: 'goal-box', id: 'ask', what: 'the prompt asking for the Goal accomplished box', ms: 60 * 60_000 })}`
const GOAL_LET_GO = `release ${JSON.stringify({ mod: 'goal-box', id: 'ask' })}`
test('the prompt for a met goal holds back a reload of goal-box while it waits, and lets go sent, thrown or dropped (#2132)', withKit, async ($, on) => {
  const { w } = world(on, { goal: MET, submitFails: ['throw', 'drop'] })
  await start($)
  await turnEnds($)
  await turnEnds($)
  await turnEnds($)
  expect(w.held).toEqual([GOAL_HELD, 'submit', GOAL_LET_GO, GOAL_HELD, 'submit', GOAL_LET_GO, GOAL_HELD, 'submit', GOAL_LET_GO])
})

test('a hold mod-kit refuses is said in the debug log, and the prompt for a met goal is sent as before (#2132)', withKit, async ($, on) => {
  const { w, submitted, logs } = world(on, { goal: MET, holdFails: 'mod-kit is not loaded' })
  await start($)
  await turnEnds($)
  expect(w.held).toEqual(['submit'])
  expect(submitted).toHaveLength(1)
  expect(logs).toContain('goal-box: could not hold back a reload while it waits on the prompt asking for the Goal accomplished box, so one now would drop that wait (mod-kit is not loaded)')
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

// #2523: with no /goal, the only reminder to call the tool was the session reflection's last line,
// and a reflection folded into the issue review dropped it (L27). So the mod asks too, at the turn
// end where work measurably shipped: an is it live card made since Dan's last message, nothing still
// in flight, and no box for this request. Once per request, whatever the session then decides.
const NOW = 1_800_000_000_000
const CARDED = { 'danwright32/claude-config#1700': { state: 'live', at: NOW } }
const ASKS_DONE = 'GOAL ACCOMPLISHED? Since Dan\'s last message'
test('no /goal: a merge carded since Dan\'s message, nothing in flight and no box, and the session is asked once whether the work is finished (#2523)', withLive, async ($, on) => {
  const { submitted, cards } = world(on, { verdicts: CARDED })
  await start($)
  await turnEnds($)
  expect(submitted).toEqual([])
  await says($, 'Merge PR 1700')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
  expect(submitted.at(-1)?.text).toContain(TOOL)
  expect(submitted.at(-1)?.origin).toMatchObject({ kind: 'plugin' })
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(await cards()).toHaveLength(1)
})

test('no /goal: a box already shown for the request asks nothing (#2523)', withLive, async ($, on) => {
  const shown = world(on, { verdicts: CARDED })
  await start($)
  await says($, 'Merge PR 1700')
  expect((await box($, ASKED)).deny).toBeUndefined()
  await turnEnds($)
  expect(shown.submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
})

test('no /goal: a card made before Dan\'s message asks nothing (#2523)', withLive, async ($, on) => {
  const { submitted } = world(on, { verdicts: { 'danwright32/claude-config#1700': { state: 'live', at: NOW - 1 } } })
  await start($)
  await says($, 'Now make the status bar quieter')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
})

test('no /goal: an agent still running, or a deploy not yet live, asks nothing; once settled it asks (#2523)', withLive, async ($, on) => {
  const { w, submitted } = world(on, { verdicts: { 'danwright32/claude-config#1700': { state: 'deploying', at: NOW } }, agents: [{ id: 'a1', status: 'running', description: 'Fix issue 1702' }] })
  await start($)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
  w.verdicts = CARDED
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
  w.agents = [{ id: 'a1', status: 'completed' }]
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
})

test('no /goal: a /goal still set, a subagent or an interrupted turn is never asked (#2523)', withLive, async ($, on) => {
  const { w, submitted } = world(on, { verdicts: CARDED, goal: { state: 'set', condition: 'complete milestone 80' } })
  await start($)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  w.goal = { state: 'none' }
  await turnEnds($, { agentId: 'a1' })
  await turnEnds($, { isAborted: true, reason: 'aborted' })
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
})

test('no /goal: a headless session is never asked (#2523)', withLive, async ($, on) => {
  const { submitted } = world(on, { verdicts: CARDED })
  await start($, false)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
})

test('no /goal: a question that could not be sent is said and sent again at the next turn end (#2523)', withLive, async ($, on) => {
  const { submitted, logs } = world(on, { verdicts: CARDED, submitFails: ['drop'] })
  await start($)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
  expect(logs.join('\n')).toMatch(/could not be asked whether the work is finished \(held by a guard beneath\); it is asked again at the next turn end/)
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
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

test("mod-kit unable to draw the card still shows the box as text, the goal first, and says why in the debug log", withKit, async ($, on) => {
  const { logs, cards } = world(on, { cardFails: 'a card needs a title of one or more runs' })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toBeUndefined()
  expect(textOf(r).split('\n')[0]).toBe('GOAL ACCOMPLISHED: Show a green box when the goal is met')
  expect(logs.join('\n')).toMatch(/goal-box: the card could not be drawn \(a card needs a title/)
})
