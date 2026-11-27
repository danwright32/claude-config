import { expect, mock } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { On, Register } from 'claude-code'
import type { ModKitBandRow } from '../.claude-plugin/types/mod-kit/index.d.ts'
import { type Command } from './mod-kit/hooks/commands.ts'
import { ghArgs, mergeHelperArgs } from './mod-kit/hooks/gh.ts'
import { githubRepo, linkRepo, repoName } from './mod-kit/hooks/repo.ts'
import { pipelineIn } from './mod-kit/hooks/writes.ts'

// The announcement for agents a merged change owes (claude-config#3667), in a session: kept in the
// store under a key of its own when the merge lands, drafted on the card's word once the change is
// out, judged by the draft's own answer, and said in every session until it is settled. Nothing here
// calls a real Slack tool: Slack's draft tool, GitHub, and the hooks' three command lines (the merge
// gate's reader, the one comparison of a draft with its wording, and the check that the wording is
// the one the pull request claimed) are the world beneath the mod.

type Part = { text?: string; color?: string; bold?: boolean; button?: string; label?: string }
type Row = { mod: string; id: string; slot: string; lines: Part[][] }
// mod-kit, standing in (a mod cannot import another mod's files): it keeps published rows and draws
// their text and buttons, and reads a command, a gh call and a link with copies of its own readers.
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ref = { plugin: 'mod-kit', key: 'band' } as never
      const rows = async () => (((await built.state.get(ref)) as { value?: Row[] }).value ?? [])
      const kit = async (what: string, input: unknown) => {
        const r = await built.process.run(['__modkit', what, JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return r.stdout === '' ? undefined : JSON.parse(r.stdout)
      }
      const modkit = {
        bandRow: async (row: ModKitBandRow) => {
          // Why the band refuses a row, when a test's world makes it (asked of the world, which this module cannot read).
          const fault = (await kit('bandFault', {})) as string
          if (fault) throw new Error(fault)
          // A row published again keeps its place, as mod-kit's own `put` keeps it (hooks/band.ts):
          // the button a second press lands on is where the first one was (#3847).
          const held = await rows()
          const at = held.findIndex(r => r.mod === row.mod && r.id === row.id)
          await built.state.set(ref, (at < 0 ? [...held, row] : held.map((r, i) => (i === at ? row : r))) as never)
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
          await built.state.set(ref, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
        },
        card: async () => undefined,
        screen: async () => null,
        press: async () => ({ isAnswered: false }),
        clickable: async () => true,
        isDans: async ({ origin }: { origin?: { kind?: string } }) => origin?.kind === 'composer' || origin?.kind === 'bridge',
        repo: async (input: unknown) => kit('repo', input),
        linkRepo: async (input: unknown) => kit('linkRepo', input),
        gh: async (input: unknown) => kit('gh', input),
        mergeHelper: async (input: unknown) => kit('mergeHelper', input),
        pipeline: async (input: unknown) => kit('pipeline', input),
      }
      // Only the members this mod calls on these paths: the rest of the kit is never reached here.
      return { ...built, modkit: modkit as never }
    })
    // For these tests only: raises modkit.press with whatever element a test names, so the mod's
    // own answer to a press of a button that is not drawn can be read. mod-kit's /press presses
    // only a button showing now.
    on('command.run', { command: 'raise-press' }, async ($, e) => ({ text: JSON.stringify(await $.modkit.press({ element: e.args, surface: 'terminal', how: 'typed' })) }))
    // As mod-kit does since Claude Code 2.1.323 (#2903): while it draws a row, every other row is
    // left out of the stacked band.
    on('ui.render', { component: 'AbovePromptList' } as never, (async (_$: unknown, e: { props: { rows: readonly { plugin: string }[] } }, next: (e: unknown) => Promise<unknown>) => {
      const ours = e.props.rows.filter(r => r.plugin === 'mod-kit')
      return next(ours.length === 0 || ours.length === e.props.rows.length ? e : { ...e, props: { ...e.props, rows: ours } })
    }) as never)
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
                    <Text key={String(i)} color={p.color} bold={p.bold}>
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
const REPO = 'acme/widget'
const CH = 'C0123456789'
const HOME = '/tmp/announce-home'
const FOLDER = '/tmp/announce-home/widget'
const LABEL = 'changelog/announce'
const POST = '@here\n**Handing a call back**\n\nYou can now hand a call back to the queue.\n\n- Press Hand back\n- Pick a reason'
const normal = (text: string) => text.split('\n').filter(l => l.trim()).join('\n')
const hashOf = (text: string) => `sha-of-${normal(text).length}`

type Gh = { exitCode: number; stdout: string; stderr?: string }
/** A merged pull request as GitHub holds it: its labels and its description. */
type Pr = { labels?: string[]; body?: string; state?: string }
/** What the merge gate's reader answers (hooks/lib/changelog-entry.js, `announcement`), in its own shape. */
type Owed = { state: 'owed' | 'none' | 'unknown'; channel: string; text: string; normalized: string; hash: string; why: string }
type World = {
  prs: Record<string, Pr>
  /** The reader's answer for a pull request, as its command line prints it; the default reads the label. */
  reader: (repo: string, pr: { labels: { name: string }[]; body: string }) => Gh
  /** When given, answers a `gh pr view` asking for labels and body first. */
  labelsRead?: (argv: string[]) => Gh | undefined
  /** The one judgement of a draft (hooks/lib/announce-compare.js, `draft`), as its command line prints it. */
  judge: (input: Judged) => Gh
  /**
   * Whether the wording about to be drafted is the wording the pull request merged on
   * (hooks/lib/announce-compare.js, `claimed`), as its command line prints it; the default says it is.
   */
  claim: (repo: string, pr: string, text: string) => Gh
  remote: string | null
  stored?: Record<string, unknown>
  /** When set, every read of the store fails with these words. */
  storeFails?: string
  /** When set, every write to the store fails with these words. */
  storeWriteFails?: string
  /** When set, the band refuses every row with these words. */
  bandFails?: string
  /** When set, the session's timers never run: the clock moves and nothing scheduled fires. */
  timersNeverRun?: true
  /** With `timersNeverRun`: when set, every read of the clock fails with these words. */
  clockFails?: string
  /** What Slack's draft tool answers, or the refusal of a gate beneath the mod. */
  slackDraft: { text: string; isError?: true; deny?: string }
}

const answer = (o: Partial<Owed> & { state: Owed['state'] }): Gh => {
  const text = o.text ?? ''
  return { exitCode: 0, stdout: JSON.stringify({ channel: '', why: '', ...o, text, normalized: normal(text), hash: text ? hashOf(text) : '' }) + '\n' }
}
/** The reader as it answers a repository whose registry entry names the channel. */
const reads = (repo: string, pr: { labels: { name: string }[]; body: string }): Gh =>
  pr.labels.some(l => l.name === LABEL) ? answer({ state: 'owed', channel: CH, text: pr.body }) : answer({ state: 'none' })

/**
 * The judgement, standing in for the hooks' command line, whose own suite
 * (hooks/test-announce-compare.sh) proves the real one: an error is an error, no draft_id is a draft
 * not kept, and a kept draft is the approved wording when its words are, markup and spacing aside.
 */
type Judged = { text: string; message: string; answer: { text: string; isError?: boolean } }
const wordsOf = (s: string) => (s.toLowerCase().match(/[a-z0-9]+/g) ?? []).join(' ')
const NOT_KEPT = "Slack's answer holds no draft_id, which is what it answers when a draft is already waiting in that channel, and it keeps nothing then"
const judges = (i: Judged): Gh => {
  const named = /"error":"([a-z_]+)"/.exec(i.answer.text)?.[1]
  const id = /"draft_id":"([^"]+)"/.exec(i.answer.text)?.[1]
  const out =
    i.answer.isError || named
      ? { state: 'error', error: named ?? '', why: `Slack answered ${named}: the Slack account is not a member of that channel, so nothing was kept` }
      : !id
        ? { state: 'not-kept', why: NOT_KEPT }
        : wordsOf(i.message) !== wordsOf(i.text)
          ? { state: 'differs', draftId: id, why: 'the approved wording has 21 words and the draft 21, and they first differ at word 20, where the approved wording has "pick" and the draft has "choose"' }
          : { state: 'saved', draftId: id }
  return { exitCode: 0, stdout: JSON.stringify(out) + '\n' }
}

// A clock whose time a test moves and whose timers never run (#3847), as on a Mac too busy to have
// run them: what the mod decides by the time alone is read here, with no timer having tidied up.
const stillClock = (on: On, w: { clockFails?: string }) => {
  let now = T0
  on('clock.now', () => {
    if (w.clockFails) throw new Error(w.clockFails)
    return { value: now } as never
  })
  // The engine runs a timer's function once this hook answers, so it never answers.
  on('clock.after', () => new Promise<never>(() => {}))
  return {
    advance: async (ms: number) => {
      now += ms
    },
    set: async (at: number) => {
      now = at
    },
    settle: async () => {},
  }
}

const world = (on: On, init: Partial<World> = {}) => {
  const w: World = { prs: {}, reader: reads, judge: judges, claim: () => ({ exitCode: 0, stdout: '{"state":"approved"}\n' }), remote: `git@github.com:${REPO}.git`, slackDraft: { text: '{"result":"Draft created","draft_id":"Dr0123ABC"}' }, ...init }
  const toasts: string[] = []
  const copies: string[] = []
  const tools: string[] = []
  const runs: string[][] = []
  // How long each command line was given to answer, as the mod asked for it.
  const limits: { argv: string[]; ms: number | undefined }[] = []
  const clock = w.timersNeverRun ? stillClock(on, w) : mock.clock(on, { now: T0 })
  // The store every session shares, held where a test can read it and write under the mod.
  const store = new Map<string, unknown>(Object.entries(w.stored ?? {}))
  on('store.get', ($, e) => {
    if (w.storeFails) throw new Error(w.storeFails)
    return { value: store.get(e.key) } as never
  })
  on('store.set', ($, e) => {
    if (w.storeWriteFails) throw new Error(w.storeWriteFails)
    store.set(e.key, JSON.parse(JSON.stringify(e.value)))
    return { value: undefined } as never
  })
  on('store.delete', ($, e) => {
    store.delete(e.key)
    return { value: undefined } as never
  })
  on('store.keys', () => ({ value: [...store.keys()] }) as never)
  const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never
  on('process.run', ($, e) => {
    if (e.argv[0] === '__modkit') {
      const input = JSON.parse(e.argv[2] as string) as { words: string[]; command: string; cwd: string; home?: string; link: string; root?: string | null; remote: string | null }
      const what = e.argv[1]
      if (what === 'bandFault') return ok(JSON.stringify(w.bandFails ?? ''))
      const read =
        what === 'gh' ? ghArgs(input.words) : what === 'mergeHelper' ? mergeHelperArgs(input as unknown as Command) : what === 'pipeline' ? pipelineIn(input.command, input.cwd, input.home ?? '') : what === 'linkRepo' ? linkRepo(input.link) : { github: githubRepo(input.remote), name: repoName(input) }
      return ok(read === undefined ? '' : JSON.stringify(read))
    }
    runs.push([...e.argv])
    limits.push({ argv: [...e.argv], ms: (e as { init?: { timeoutMs?: number } }).init?.timeoutMs })
    const a = e.argv.join(' ')
    const stdin = (e as { init?: { stdin?: string } }).init?.stdin
    let g: Gh = { exitCode: 1, stdout: '', stderr: 'unexpected' }
    if (a.startsWith('gh pr view')) {
      const n = e.argv[3] as string
      const at = e.argv.indexOf('--repo')
      const repo = at >= 0 ? (e.argv[at + 1] as string) : REPO
      const p = w.prs[`${repo}#${n}`]
      const fields = e.argv[e.argv.indexOf('--json') + 1] ?? ''
      const first = fields === 'labels,body' ? w.labelsRead?.([...e.argv]) : undefined
      if (first) g = first
      else if (!p) g = { exitCode: 1, stdout: '', stderr: 'no pull requests found' }
      else if (fields === 'labels,body') g = { exitCode: 0, stdout: JSON.stringify({ labels: (p.labels ?? []).map(name => ({ name })), body: p.body ?? '' }) }
      else g = { exitCode: 0, stdout: JSON.stringify({ number: Number(n), state: p.state ?? 'MERGED', mergedAt: new Date(T0 + 30_000).toISOString(), title: 'Hand a call back', url: `https://github.com/${repo}/pull/${n}` }) }
    } else if (a === 'gh auth status') g = { exitCode: 0, stdout: '', stderr: '  Logged in to github.com account dan (keyring)' }
    else if (a.startsWith('gh repo view')) g = { exitCode: 0, stdout: `${e.argv[3]}\n` }
    else if (e.argv[0] === 'node' && e.argv[1] === `${HOME}/.claude/hooks/lib/changelog-entry.js` && e.argv[2] === 'announcement') g = w.reader(e.argv[3] as string, JSON.parse(stdin ?? 'null'))
    else if (e.argv.join(' ') === `node ${HOME}/.claude/hooks/lib/announce-compare.js draft`) g = w.judge(JSON.parse(stdin ?? 'null'))
    else if ((e.argv.length === 7 || (e.argv.length === 9 && e.argv[7] === '--within-ms')) && e.argv.slice(0, 4).join(' ') === `node ${HOME}/.claude/hooks/lib/announce-compare.js claimed --repo` && e.argv[5] === '--pr') g = w.claim(e.argv[4] as string, e.argv[6] as string, stdin ?? '')
    return { value: { exitCode: g.exitCode, stdout: g.stdout, stderr: g.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false } } as never
  })
  on('session.repo', () => ({ value: { root: FOLDER, remote: w.remote, isOwn: false } }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }) as never)
  on('session.cwd', () => ({ value: FOLDER }) as never)
  on('env.get', ($, e) => ({ value: (e as unknown as { name: string }).name === 'HOME' ? HOME : undefined }) as never)
  on('tool.call', { tool: 'Bash' }, () => ({ result: { stdout: '', stderr: '', interrupted: false }, text: '' }) as never)
  on('classic.Stop', () => ({}) as never)
  on('prompt.submit', ($, e) => ({ text: e.text, context: [] }) as never)
  on('tool.call', { tool: [DRAFT, DRAFT_OTHER] }, () => (w.slackDraft.deny ? { deny: w.slackDraft.deny } : w.slackDraft.isError ? { isError: true, result: w.slackDraft.text, text: w.slackDraft.text } : { result: w.slackDraft.text, text: w.slackDraft.text }) as never)
  on('ui.log', () => ({ value: undefined }) as never)
  on('tool.register', ($, e) => {
    tools.push(String((e as { name?: string }).name))
    return { value: undefined } as never
  })
  on('command.register', () => ({ value: undefined }) as never)
  on('ui.copy', ($, e) => {
    copies.push(String((e as { text?: string }).text))
    return { value: { isCopied: true } } as never
  })
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  return { w, toasts, copies, tools, runs, limits, clock, store, keys: () => [...store.keys()].sort() }
}

const DRAFT = 'mcp__plugin_slack_slack__slack_send_message_draft'
const DRAFT_OTHER = 'mcp__claude_ai_Slack__slack_send_message_draft'
type Out = { deny?: string; result?: unknown; text?: string; context?: readonly string[]; isError?: boolean }
const call = async ($: unknown, tool: string, input: Record<string, unknown>) =>
  (await ($ as { tool: { call: (e: never) => Promise<unknown> } }).tool.call({ tool, tool_use_id: 't1', ...input } as never)) as Out
const bash = ($: unknown, command: string) => call($, 'Bash', { command })
const said = (o: Out) => (o.context ?? []).join('\n')
const start = async ($: unknown) => {
  await ($ as { session: { start: (x: never) => Promise<unknown> } }).session.start({ cwd: FOLDER, surface: 'terminal', isInteractive: true } as never)
}
const readerRuns = (runs: string[][]) => runs.filter(r => r[0] === 'node' && r[2] === 'announcement')
// The band above the prompt, as mod-kit draws it: its lines of text, and a press of one of its buttons.
const band = () => ({ plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 40, bodyColumns: 100, scroll: { offset: 0, bodyRows: 40 }, view: {} } }) as never
type Found = { text: string; children: unknown[]; props?: { label?: string; color?: string; bold?: boolean } }
type Mounted = { findAll: (q: { type: string }) => Promise<Found[]>; press: (t: object) => Promise<unknown>; unmount: () => Promise<void> }
const mount = async ($: unknown) => (await ($ as { ui: { mount: (x: never) => Promise<unknown> } }).ui.mount(band())) as Mounted
const shown = async ($: unknown) => {
  const ui = await mount($)
  const t = (await ui.findAll({ type: 'Text' })).filter(x => x.children.every(c => typeof c === 'string')).map(x => x.text)
  await ui.unmount()
  return t
}
const buttons = async ($: unknown) => {
  const ui = await mount($)
  const b = (await ui.findAll({ type: 'Button' })).map(x => x.props?.label)
  await ui.unmount()
  return b
}
const press = async ($: unknown, key: string) => {
  const ui = await mount($)
  await ui.press({ key })
  await ui.unmount()
}

const ANNOUNCED: Pr = { labels: [LABEL], body: POST }
const ENTRY = { repo: REPO, pr: 7, channel: CH, text: POST, normalized: normal(POST), hash: hashOf(POST), at: T0 }

// ---- R4: what is owed is kept when the merge lands, under a key of its own ----

test('a merge of a change that owes an announcement keeps it under a store key of its own, with its channel, wording and hash, outside the cards (R4)', withKit, async ($, on) => {
  const { toasts, store, keys } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  expect(store.get(`announce:${REPO}#7`)).toEqual(ENTRY)
  // One key per pull request, and no card: the list of cards keeps only the newest 50.
  expect(keys()).toEqual([`announce:${REPO}#7`])
  expect(toasts).toEqual([])
})

test('an answer the gate\'s reader gives as unknown is kept as owed with its why, never dropped (R4)', withKit, async ($, on) => {
  const why = `the entry for ${REPO} in this Mac's dev update registry names no announcements channel`
  const { store } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED }, reader: (_r, pr) => answer({ state: 'unknown', text: pr.body, why }) })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  expect(store.get(`announce:${REPO}#7`)).toEqual({ ...ENTRY, channel: '', why })
})

test('a change with any other label owes nothing: nothing is kept and nothing is said', withKit, async ($, on) => {
  const { toasts, runs, keys } = world(on, { prs: { [`${REPO}#7`]: { labels: ['changelog/technical'], body: 'x' }, [`${REPO}#8`]: { labels: [], body: 'x' } } })
  await start($)
  const r = await bash($, 'gh pr merge 7 --squash')
  await bash($, 'gh pr merge 8 --squash')
  expect(keys()).toEqual([])
  expect(toasts).toEqual([])
  expect(said(r)).not.toContain('nnouncement')
  // A pull request carrying no label at all cannot carry that one, so the reader is not run for it.
  expect(readerRuns(runs).length).toBe(1)
})

test('the merge landing twice keeps the one entry as first kept, and an entry that reads is never asked for again', withKit, async ($, on) => {
  const { w, runs, clock, store } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  await clock.advance(60_000)
  w.reader = () => answer({ state: 'unknown', why: 'the registry could not be read' })
  await bash($, 'gh pr merge 7 --squash')
  expect(store.get(`announce:${REPO}#7`)).toEqual(ENTRY)
  expect(readerRuns(runs).length).toBe(1)
})

test('an entry kept with a why is asked for again, and the answer that now reads replaces it', withKit, async ($, on) => {
  const { w, store } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED }, reader: (_r, pr) => answer({ state: 'unknown', text: pr.body, why: 'the registry could not be read' }) })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  w.reader = reads
  await bash($, 'gh pr merge 7 --squash')
  expect(store.get(`announce:${REPO}#7`)).toEqual(ENTRY)
})

test('a reader or a GitHub that cannot be asked is said to Dan with why, and nothing is kept as owed on a guess', withKit, async ($, on) => {
  const { w, toasts, keys } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED }, reader: () => ({ exitCode: 1, stdout: '', stderr: 'node: cannot find module' }) })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  expect(keys()).toEqual([])
  expect(toasts).toEqual([`Is it live could not tell whether ${REPO} pull request 7 owes an announcement for agents (the merge gate's reader failed: node: cannot find module). It is asked again when its card is made.`])
  toasts.length = 0
  w.labelsRead = () => ({ exitCode: 1, stdout: '', stderr: 'HTTP 502' })
  await bash($, 'gh pr merge 7 --squash')
  expect(keys()).toEqual([])
  expect(toasts.join(' ')).toContain('GitHub could not be asked for its labels: HTTP 502')
  toasts.length = 0
  w.labelsRead = () => ({ exitCode: 0, stdout: '{"body":"x"}' })
  await bash($, 'gh pr merge 7 --squash')
  expect(toasts.join(' ')).toContain("GitHub's answer named no list of labels")
  toasts.length = 0
  w.labelsRead = undefined
  w.reader = () => ({ exitCode: 0, stdout: '{"state":"owed","channel":"","text":""}' })
  await bash($, 'gh pr merge 7 --squash')
  expect(keys()).toEqual([])
  expect(toasts.join(' ')).toContain('its answer was not one this reader knows')
})

// ---- the card's answer: the session saves the draft, once the change is out ----

const CARD = {
  repo: REPO,
  pr: 7,
  deploy: 'live',
  checked: 'Opened a call and saw Hand back.',
  changed: 'Agents can hand a call back to the queue. They pick a reason first.',
  see: { link: 'https://widget.example.com/calls', clicks: ['Open a call', 'Press Hand back'] },
}
const card = ($: unknown, more: Record<string, unknown> = {}) => call($, 'mcp__is-it-live__card', { ...CARD, ...more })
const draft = ($: unknown, input: Record<string, unknown> = {}, tool = DRAFT) => call($, tool, { channel_id: CH, message: POST, ...input })
const NAME = `${REPO} pull request 7`
const DONE_KEY = `announce-done:${REPO}#7`
const OUT_KEY = `announce-out:${REPO}#7`

test('a card saying the change is live tells the session to save the approved wording as a draft in the channel, no thread, word for word', withKit, async ($, on) => {
  const { store } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  const r = await card($)
  expect(r.deny).toBeUndefined()
  const told = said(r)
  expect(told).toContain(`${NAME} owes an announcement for agents`)
  expect(told).toContain(`call slack_send_message_draft with channel_id "${CH}", no thread_ts`)
  // The wording itself, every line and blank line of it, between two marker lines.
  expect(told).toContain(`\n-----\n${POST}\n-----`)
  // The wording is approved already, so nothing may reword it, and it is never sent.
  expect(told).toContain('Do not run /no-ai-tells on it')
  expect(told).toContain('Never call slack_send_message or slack_schedule_message.')
  expect(told).toContain('Never ask him with AskUserQuestion whether to save it')
  expect(store.get(OUT_KEY)).toEqual({ at: T0 })
  expect(store.get(DONE_KEY)).toBeUndefined()
})

test('a deploying card, or one that could not confirm live, drafts nothing and settles nothing: the live card still asks for the draft', withKit, async ($, on) => {
  const { store } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  for (const more of [{ deploy: 'deploying' }, { deploy: 'unreachable', checked: 'The site timed out.' }]) {
    const told = said(await card($, more))
    expect(told).toContain(`${NAME} owes an announcement for agents, which is drafted only once its change is live: nothing is drafted now.`)
    expect(told).not.toContain('slack_send_message_draft')
    expect(store.get(OUT_KEY)).toBeUndefined()
    expect(store.get(DONE_KEY)).toBeUndefined()
    expect(store.get(`announce:${REPO}#7`)).toEqual(ENTRY)
  }
  expect(said(await card($))).toContain(`call slack_send_message_draft with channel_id "${CH}"`)
})

test('a card finds the announcement of a merge this session never saw land, and one whose reader could not tell says why and asks for no draft', withKit, async ($, on) => {
  const why = `the entry for ${REPO} in this Mac's dev update registry names no announcements channel`
  const { w, store } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED, [`${REPO}#8`]: ANNOUNCED } })
  await start($)
  expect(said(await card($))).toContain(`call slack_send_message_draft with channel_id "${CH}"`)
  expect(store.get(`announce:${REPO}#7`)).toEqual(ENTRY)
  w.reader = (_r, pr) => answer({ state: 'unknown', text: pr.body, why })
  const told = said(await card($, { pr: 8 }))
  expect(told).toContain(`${REPO} pull request 8 owes an announcement for agents that cannot be drafted from this Mac: ${why}.`)
  expect(told).not.toContain('slack_send_message_draft')
  expect(told).toContain('It stays listed in the band and in /live until he marks it sent or says it is not being announced.')
  expect(store.get(`announce-out:${REPO}#8`)).toEqual({ at: T0 })
})

test('a card for a change that owes none says nothing of one, and one whose labels could not be read says so', withKit, async ($, on) => {
  const { w, keys } = world(on, { prs: { [`${REPO}#7`]: { labels: ['changelog/technical'], body: 'x' } } })
  await start($)
  expect(said(await card($))).not.toContain('nnouncement')
  expect(keys().filter(k => k.startsWith('announce'))).toEqual([])
  w.labelsRead = () => ({ exitCode: 1, stdout: '', stderr: 'HTTP 502' })
  expect(said(await card($))).toContain(`Whether ${NAME} owes an announcement for agents could not be told (GitHub could not be asked for its labels: HTTP 502).`)
})

// ---- R8: the draft counts only when Slack kept it and it is the approved wording ----

test('a draft Slack kept, holding the approved wording, moves the announcement to drafted, and no later card asks for it again (R8)', withKit, async ($, on) => {
  const { store, toasts, clock } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  await card($)
  toasts.length = 0
  await clock.advance(5_000)
  const r = await draft($)
  expect(store.get(DONE_KEY)).toEqual({ how: 'drafted', at: T0 + 5_000, draftId: 'Dr0123ABC' })
  expect(said(r)).toContain(`The announcement for agents for ${NAME} is saved as a Slack draft in channel ${CH}, word for word the wording Dan approved`)
  expect(said(r)).toContain('nothing was sent')
  expect(toasts).toEqual([`Announcement for agents drafted in Slack: ${NAME}. It waits in your Drafts for you to send.`])
  // Drafted is never asked for again, so a second card cannot make a duplicate.
  expect(said(await card($))).not.toContain('nnouncement')
  toasts.length = 0
  expect((await draft($)).context ?? []).toEqual([])
  expect(toasts).toEqual([])
})

test('a draft that differs from the approved wording is said as that, to Dan and the session, and the announcement stays owed (R8)', withKit, async ($, on) => {
  const { store, toasts } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  await card($)
  toasts.length = 0
  const r = await draft($, { message: POST.replace('Pick a reason', 'Choose a reason') })
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(said(r)).toContain(`The draft in Slack differs from the approved wording of the announcement for agents for ${NAME}`)
  expect(said(r)).toContain('they first differ at word 20')
  expect(said(r)).toContain('It is not counted as its draft, and the announcement is still owed.')
  expect(said(r)).toContain('he can put the approved wording in its place (Copy on the "Announcement for agents" row in the band copies it) or delete it')
  expect(said(r)).not.toContain('is saved as a Slack draft')
  expect(toasts.length).toBe(1)
  expect(toasts[0]).toContain(`The draft in Slack differs from the approved wording of the announcement for agents for ${NAME}`)
  // Still owed: the next card asks for it again.
  expect(said(await card($))).toContain(`call slack_send_message_draft with channel_id "${CH}"`)
})

test('an answer holding no draft_id keeps the announcement owed and says a draft is already waiting in that channel, never to delete it (R8)', withKit, async ($, on) => {
  const { store, toasts } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED }, slackDraft: { text: '{"result":"Draft created"}' } })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  await card($)
  toasts.length = 0
  const r = await draft($)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(said(r)).toContain(`No draft of the announcement for agents for ${NAME} was saved: ${NOT_KEPT}.`)
  expect(said(r)).toContain(`a draft is already waiting in channel ${CH}`)
  expect(said(r)).toContain('if it is, he can send it and press Mark sent on the "Announcement for agents" row in the band, and if it is something else')
  expect(said(r)).toContain('Do not tell him to delete it')
  expect(toasts).toEqual([`No Slack draft was saved for the announcement for agents for ${NAME}: a draft is already waiting in that channel. It is still owed.`])
})

test('an error from Slack, or a judgement that cannot be made, each has its own sentence and keeps the announcement owed', withKit, async ($, on) => {
  const { w, store, toasts } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED }, slackDraft: { text: '{"ok":false,"error":"not_in_channel"}', isError: true } })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  await card($)
  toasts.length = 0
  let r = await draft($)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(said(r)).toContain(`No draft of the announcement for agents for ${NAME} was saved: Slack answered not_in_channel: the Slack account is not a member of that channel, so nothing was kept.`)
  expect(toasts[0]).toContain('Slack answered not_in_channel')
  toasts.length = 0
  w.slackDraft = { text: '{"result":"Draft created","draft_id":"Dr0123ABC"}' }
  w.judge = () => ({ exitCode: 2, stdout: '', stderr: 'The draft could not be judged: the approved wording has no words. Usage: announce-compare.js draft' })
  r = await draft($)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(said(r)).toContain(`Whether the draft just made in channel ${CH} is the announcement for agents for ${NAME} could not be checked`)
  expect(toasts[0]).toContain('could not be checked')
  toasts.length = 0
  w.judge = () => ({ exitCode: 0, stdout: '{"state":"saved"}' })
  r = await draft($)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(said(r)).toContain('its answer was not one this reader knows')
})

test('a draft that is not the announcement is left alone: another channel, a thread reply, a refused call, or nothing owed', withKit, async ($, on) => {
  const { w, store, toasts, runs } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  expect((await draft($)).context ?? []).toEqual([])
  await bash($, 'gh pr merge 7 --squash')
  await card($)
  toasts.length = 0
  runs.length = 0
  expect((await draft($, { channel_id: 'C0999999999' })).context ?? []).toEqual([])
  expect((await draft($, { thread_ts: '1730900000.123456' })).context ?? []).toEqual([])
  w.slackDraft = { text: '', deny: 'Blocked by a gate beneath.' }
  expect((await draft($)).context ?? []).toEqual([])
  expect(runs.filter(r => r.join(' ').includes('announce-compare.js'))).toEqual([])
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(toasts).toEqual([])
  // The other connector's draft tool is the same tool.
  w.slackDraft = { text: '{"result":"Draft created","draft_id":"Dr9"}' }
  await draft($, {}, DRAFT_OTHER)
  expect(store.get(DONE_KEY)).toEqual({ how: 'drafted', at: T0, draftId: 'Dr9' })
})

// ---- R4: said in every session until it is settled ----

const live =async ($: unknown) =>
  String(((await ($ as { command: { run: (x: never) => Promise<unknown> } }).command.run({ command: 'live', args: '', origin: { kind: 'human' }, presentation: {} } as never)) as { text?: string }).text)
const says = async ($: unknown, text: string) => (await ($ as { prompt: { submit: (e: never) => Promise<unknown> } }).prompt.submit({ text, origin: { kind: 'composer' }, wait: false } as never)) as { context?: string[] }
const turnEnd = async ($: unknown, isActive = false) =>
  (await ($ as { classic: { Stop: (e: object) => Promise<unknown> } }).classic.Stop({ hook_event_name: 'Stop', session_id: 's1', transcript_path: '/t', cwd: FOLDER, stop_hook_active: isActive, last_assistant_message: 'Done.' })) as { block?: string }
// What another session left in the store: the entry, and that a card said its change is out.
const OWED_AND_OUT = { [`announce:${REPO}#7`]: ENTRY, [OUT_KEY]: { at: T0 } }

const ROW = ['Announcement for agents', `${NAME}: not yet a Slack draft in channel ${CH}.`]
const ALL_THREE = ['Copy', 'Mark sent', 'Not announcing']

test('every session started in that project says it in one line, to Dan and in its first prompt, and pins its row, though no card is kept for it (R4)', withKit, async ($, on) => {
  const { toasts } = world(on, { stored: OWED_AND_OUT })
  await start($)
  const LINE = `An announcement for agents is still owed in this project: ${NAME} is live and not yet a Slack draft. /live lists it, and its row in the band has Copy, Mark sent and Not announcing.`
  expect(toasts).toEqual([LINE])
  expect(await shown($)).toEqual(ROW)
  expect(await buttons($)).toEqual(ALL_THREE)
  const first = (await says($, 'Morning')).context ?? []
  expect(first.length).toBe(1)
  expect(first[0]).toContain(LINE)
  expect(first[0]).toContain('call the is it live card for that pull request with deploy "live"')
  expect((await says($, 'And then?')).context ?? []).toEqual([])
  // A session that only heard of it holds no turn end for it: the session that carded it live does.
  expect((await turnEnd($)).block).toBeUndefined()
})

test('a session in another project is told nothing, and one settled or owed by no change says nothing at start', withKit, async ($, on) => {
  const { toasts } = world(on, { stored: OWED_AND_OUT, remote: 'git@github.com:acme/other.git' })
  await start($)
  expect(toasts).toEqual([])
  expect((await says($, 'Morning')).context ?? []).toEqual([])
  expect(await live($)).not.toContain('nnouncement')
  expect(await shown($)).toEqual(['engine band'])
})

test('an announcement settled in any of the three ways is not said at start, in the first prompt or in /live', withKit, async ($, on) => {
  const { toasts, store } = world(on, { stored: OWED_AND_OUT })
  for (const done of [{ how: 'drafted', at: T0, draftId: 'Dr1' }, { how: 'sent', at: T0 }, { how: 'not-announcing', at: T0 }]) {
    store.set(DONE_KEY, done)
    await start($)
    expect(toasts).toEqual([])
    expect((await says($, 'Morning')).context ?? []).toEqual([])
    expect(await live($)).not.toContain('nnouncement')
    expect(await shown($)).toEqual(['engine band'])
  }
  // A record under that key that does not read settles nothing.
  store.set(DONE_KEY, { how: 'maybe', at: T0 })
  expect(await live($)).toContain(`- ${NAME}: not yet a Slack draft in channel ${CH}.`)
  expect(await shown($)).toEqual(ROW)
})

test('one merged that no card has found out yet, one that cannot be drafted here, and several at once are each said as what they are', withKit, async ($, on) => {
  const why = 'this Mac names no announcements channel for it'
  const { toasts } = world(on, {
    stored: {
      [`announce:${REPO}#7`]: ENTRY,
      [`announce:${REPO}#9`]: { ...ENTRY, pr: 9, channel: '', why, at: T0 + 1 },
      [`announce-out:${REPO}#9`]: { at: T0 + 1 },
      [`announce:${REPO}#12`]: { ...ENTRY, pr: 12, at: T0 + 2 },
      [`announce-out:${REPO}#12`]: { at: T0 + 2 },
    },
  })
  await start($)
  expect(toasts).toEqual([`3 announcements for agents are still owed in this project: ${REPO} pull requests 7, 9 and 12. /live says where each stands, and each one that is live has its row in the band.`])
  // A row for each one a card found live, oldest first, and none for the one no card has found live.
  const ROWS = ['Announcement for agents', `${REPO} pull request 9: cannot be drafted from this Mac (${why}).`, 'Announcement for agents', `${REPO} pull request 12: not yet a Slack draft in channel ${CH}.`]
  expect(await shown($)).toEqual(ROWS)
  expect(await buttons($)).toEqual([...ALL_THREE, ...ALL_THREE])
  expect(await live($)).toContain(
    [
      'Announcements for agents still owed:',
      `- ${REPO} pull request 7: merged, and no card has said it is live yet, so nothing is drafted.`,
      `- ${REPO} pull request 9: cannot be drafted from this Mac (${why}).`,
      `- ${REPO} pull request 12: not yet a Slack draft in channel ${CH}.`,
    ].join('\n'),
  )
})

test('/live says nothing of announcements when none is owed, lists one after its card, and stops once another session settled it', withKit, async ($, on) => {
  const { store } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  expect(await live($)).not.toContain('nnouncement')
  await card($)
  // After the cards, under a heading of its own.
  expect(await live($)).toBe(`- Live: Hand a call back (#7)\n\nAnnouncements for agents still owed:\n- ${NAME}: not yet a Slack draft in channel ${CH}.`)
  store.set(DONE_KEY, { how: 'sent', at: T0 })
  expect(await live($)).not.toContain('nnouncement')
})

test('a store that cannot be read is said as that at a session start, never as nothing owed', withKit, async ($, on) => {
  const { toasts } = world(on, { stored: OWED_AND_OUT, storeFails: 'the store is locked' })
  await start($)
  expect(toasts.length).toBe(1)
  // The engine's own words for a read nothing answered follow the colon.
  expect(toasts[0]).toContain('Is it live could not read whether this project still owes an announcement for agents: ')
})

test('the turn end of the session that carded it live is refused once, then let go and said, and never once the draft is saved', withKit, async ($, on) => {
  const { toasts } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  // A deploying card settles the card's own hold and asks no draft, so nothing is held for one yet.
  await card($, { deploy: 'deploying' })
  expect((await turnEnd($)).block).toBeUndefined()
  await card($)
  toasts.length = 0
  const held = (await turnEnd($)).block ?? ''
  expect(held).toContain(`The announcement for agents for ${NAME} is not yet a Slack draft.`)
  expect(held).toContain(`call slack_send_message_draft with channel_id "${CH}", no thread_ts`)
  expect(held).toContain(`\n-----\n${POST}\n-----`)
  expect((await turnEnd($, true)).block).toBeUndefined()
  expect(toasts).toEqual([`Is it live let the turn end with the announcement for agents for ${NAME} not yet a Slack draft. It is still owed, and stays in the band and in /live.`])
  // A new chain of turn ends holds it once more, and a saved draft ends that.
  expect((await turnEnd($)).block ?? '').toContain('is not yet a Slack draft')
  await draft($)
  expect((await turnEnd($)).block).toBeUndefined()
})

test('another session settling it ends this session\'s hold, and a session that asked for no draft holds nothing', withKit, async ($, on) => {
  const { store } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  expect((await turnEnd($)).block).toBeUndefined()
  await card($)
  store.set(DONE_KEY, { how: 'sent', at: T0 })
  expect((await turnEnd($)).block).toBeUndefined()
})

// ---- R4: the row in the band, whose buttons are how Dan settles one without a draft ----

const BUTTON = 'is-it-live:announce-'
const ID = 'acme-widget-7'
// A press raised with any element, drawn or not, through the stand-in's own command.
const typed = async ($: unknown, element: string) =>
  JSON.parse(String(((await ($ as { command: { run: (x: never) => Promise<unknown> } }).command.run({ command: 'raise-press', args: element, origin: { kind: 'human' }, presentation: {} } as never)) as { text?: string }).text)) as { isAnswered: boolean }

test('the live card pins an Announcement for agents row with Copy, Mark sent and Not announcing, and the saved draft takes it down', withKit, async ($, on) => {
  const { copies } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  // A change that is not out yet has no row: nothing can be sent about it.
  await card($, { deploy: 'deploying' })
  expect(await shown($)).toEqual(['engine band'])
  await card($)
  expect(await shown($)).toEqual(ROW)
  // The heading is drawn in the violet of the message row beside it, in bold.
  const ui = await mount($)
  const heading = (await ui.findAll({ type: 'Text' })).find(t => t.text === 'Announcement for agents')
  await ui.unmount()
  expect(heading?.props?.color).toBe('magenta')
  expect(heading?.props?.bold).toBe(true)
  expect(await buttons($)).toEqual(ALL_THREE)
  // Copy copies the wording Dan approved, exactly, and leaves the announcement owed and its row up.
  await press($, `${BUTTON}copy-${ID}`)
  expect(copies).toEqual([POST])
  expect(await shown($)).toEqual(ROW)
  await draft($)
  expect(await shown($)).toEqual(['engine band'])
})

// #3847: Not announcing takes two presses. The first changes its label to this and settles nothing,
// and for this long a second press settles it. The time is written out here, not read from the mod,
// so a change to it is a change somebody made on purpose.
const ARMED_MS = 10_000
const confirmOf = (pr: number) => `Confirm: not announcing #${pr}`
const ARMED = [...ALL_THREE.slice(0, 2), confirmOf(7)]
const armedSaid = (pr: number) =>
  `Nothing is settled: the announcement for agents for ${REPO} pull request ${pr} is still owed. A second press, on ${confirmOf(pr)} within 10 seconds, ends it for every session and cannot be undone. Left alone, the button goes back to Not announcing.`
const NOT_ANNOUNCED = `Not announcing: the announcement for agents for ${NAME} is no longer asked for.`

test('Mark sent in one press, and Not announcing in two, each settle it for every session, take the row down, and say what was recorded (R4)', withKit, async ($, on) => {
  const { store, toasts, clock } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED, [`${REPO}#8`]: ANNOUNCED } })
  await start($)
  await card($)
  await card($, { pr: 8 })
  toasts.length = 0
  await clock.advance(1_000)
  // Mark sent keeps its one press: it records that he posted it, which loses nothing.
  await press($, `${BUTTON}sent-${ID}`)
  expect(store.get(DONE_KEY)).toEqual({ how: 'sent', at: T0 + 1_000 })
  expect(toasts).toEqual([`Marked sent: the announcement for agents for ${NAME}. It is no longer asked for.`])
  expect(await shown($)).toEqual(['Announcement for agents', `${REPO} pull request 8: not yet a Slack draft in channel ${CH}.`])
  toasts.length = 0
  await press($, `${BUTTON}none-acme-widget-8`)
  await press($, `${BUTTON}none-acme-widget-8`)
  expect(store.get(`announce-done:${REPO}#8`)).toEqual({ how: 'not-announcing', at: T0 + 1_000 })
  expect(toasts).toEqual([armedSaid(8), `Not announcing: the announcement for agents for ${REPO} pull request 8 is no longer asked for.`])
  expect(await shown($)).toEqual(['engine band'])
  // Settled is settled in every session: no card, turn end, /live or session start asks again.
  expect(said(await card($))).not.toContain('nnouncement')
  expect((await turnEnd($)).block ?? '').not.toContain('nnouncement')
  expect(await live($)).not.toContain('nnouncement')
  toasts.length = 0
  await start($)
  expect(toasts).toEqual([])
  expect(await shown($)).toEqual(['engine band'])
})

test('only a press of the row\'s own button marks one sent or not being announced: nothing a session can call does, and a press naming another row settles nothing (R4)', withKit, async ($, on) => {
  const { store, tools, toasts } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  // The two tools this mod gives a session: neither takes a settlement.
  expect(tools).toEqual(['card', 'unrelated_merges'])
  await bash($, 'gh pr merge 7 --squash')
  await card($, { deploy: 'deploying' })
  await card($)
  await card($)
  await draft($, { message: POST.replace('Pick a reason', 'Choose a reason') })
  await turnEnd($)
  await turnEnd($, true)
  await live($)
  await says($, 'Mark the announcement sent')
  await start($)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(await shown($)).toEqual(ROW)
  // A press that names a row no announcement is kept for, or no button of these rows, settles nothing.
  toasts.length = 0
  expect(await typed($, `${BUTTON}sent-acme-widget-8`)).toEqual({ isAnswered: true })
  expect(toasts).toEqual(['No announcement for agents is kept for that row, so it was taken down and nothing was recorded.'])
  expect(await typed($, `${BUTTON}drafted-${ID}`)).toEqual({ isAnswered: false })
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect([...store.keys()].filter(k => k.startsWith('announce-done:'))).toEqual([])
  expect(await shown($)).toEqual(ROW)
  // Nor did any of it arm the button (#3847): it still reads Not announcing, and his one press now
  // is a first press, which settles nothing.
  expect(await buttons($)).toEqual(ALL_THREE)
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(await buttons($)).toEqual(ARMED)
  // While it is armed, nothing a session can call is the second press: each leaves it owed, and
  // armed for no longer than his own press made it.
  await card($)
  await draft($, { message: POST.replace('Pick a reason', 'Choose a reason') })
  await bash($, 'gh pr merge 7 --squash')
  await turnEnd($)
  await turnEnd($, true)
  await live($)
  await says($, 'Confirm: not announcing #7')
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect([...store.keys()].filter(k => k.startsWith('announce-done:'))).toEqual([])
  expect(await buttons($)).toEqual(ARMED)
  // His second press of the row's own button is what settles it.
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toEqual({ how: 'not-announcing', at: T0 })
})

// ---- #3847: Not announcing settles only on a second press ----

test('one press of Not announcing settles nothing: its label reads Confirm: not announcing #7 and Dan is told so, and a second press settles it and takes the row down (#3847)', withKit, async ($, on) => {
  const { store, toasts, keys, clock } = world(on, { stored: OWED_AND_OUT })
  await start($)
  const before = keys()
  toasts.length = 0
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(toasts).toEqual([armedSaid(7)])
  expect(await shown($)).toEqual(ROW)
  expect(await buttons($)).toEqual(ARMED)
  // Armed is this session's own: nothing is written to the store every session shares, so no other
  // session's row is armed by it.
  expect(keys()).toEqual(before)
  // The second press, a moment before the time is up, settles it as one press used to.
  await clock.advance(ARMED_MS - 1)
  toasts.length = 0
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toEqual({ how: 'not-announcing', at: T0 + ARMED_MS - 1 })
  expect(toasts).toEqual([NOT_ANNOUNCED])
  expect(await shown($)).toEqual(['engine band'])
  // The time it was armed for passing afterwards brings nothing back.
  await clock.advance(ARMED_MS)
  await clock.settle()
  expect(await shown($)).toEqual(['engine band'])
  expect(store.get(DONE_KEY)).toEqual({ how: 'not-announcing', at: T0 + ARMED_MS - 1 })
})

test('left alone for the armed time the button goes back to Not announcing with nothing settled, and the next press only arms it again (#3847)', withKit, async ($, on) => {
  const { store, toasts, clock } = world(on, { stored: OWED_AND_OUT })
  await start($)
  await press($, `${BUTTON}none-${ID}`)
  expect(await buttons($)).toEqual(ARMED)
  toasts.length = 0
  await clock.advance(ARMED_MS)
  await clock.settle()
  expect(await buttons($)).toEqual(ALL_THREE)
  expect(await shown($)).toEqual(ROW)
  expect(store.get(DONE_KEY)).toBeUndefined()
  // Going back is said by the label alone.
  expect(toasts).toEqual([])
  // A press now is a first press again, however many came before it.
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(toasts).toEqual([armedSaid(7)])
  expect(await buttons($)).toEqual(ARMED)
  // An earlier arming's time running out does not cut a later one short. Copy disarms it 4 seconds
  // in and the next press arms it again: when the earlier arming's timer runs, 6 seconds on, the
  // button is still armed, and it stays armed for the whole of its own 10 seconds.
  await clock.advance(4_000)
  await clock.settle()
  await press($, `${BUTTON}copy-${ID}`)
  expect(await buttons($)).toEqual(ALL_THREE)
  await press($, `${BUTTON}none-${ID}`)
  await clock.advance(6_000)
  await clock.settle()
  expect(await buttons($)).toEqual(ARMED)
  await clock.advance(ARMED_MS - 6_000 - 1)
  await clock.settle()
  expect(await buttons($)).toEqual(ARMED)
  await clock.advance(1)
  await clock.settle()
  expect(await buttons($)).toEqual(ALL_THREE)
  expect(store.get(DONE_KEY)).toBeUndefined()
})

test('a press of Not announcing where whether it was armed cannot be read settles nothing, and says that rather than that the label could not change (#3847)', withKit, async ($, on) => {
  // Armed is decided by the clock, so a clock that will not read leaves it unread.
  const { store, toasts, w } = world(on, { stored: OWED_AND_OUT, timersNeverRun: true })
  await start($)
  await press($, `${BUTTON}none-${ID}`)
  w.clockFails = 'the clock would not read'
  toasts.length = 0
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  // The reason is the engine's own words for a clock that did not answer, so only the sentence is held.
  expect(toasts.length).toBe(1)
  expect(toasts[0]).toContain(`Nothing is settled: the announcement for agents for ${NAME} is still owed. Whether Not announcing was armed could not be read (`)
  expect(toasts[0]).toContain('), so this press was not counted.')
  // Read again, the press that was not counted has changed nothing: the button is still armed.
  w.clockFails = undefined
  expect(await buttons($)).toEqual(ARMED)
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toEqual({ how: 'not-announcing', at: T0 })
})

test('a second press that comes once the time is up settles nothing, even where the label has not gone back yet (#3847)', withKit, async ($, on) => {
  // The timer that puts the label back never runs here: the clock alone moves.
  const { store, toasts, clock } = world(on, { stored: OWED_AND_OUT, timersNeverRun: true })
  await start($)
  await press($, `${BUTTON}none-${ID}`)
  await clock.set(T0 + ARMED_MS)
  expect(await buttons($)).toEqual(ARMED)
  toasts.length = 0
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(toasts).toEqual([armedSaid(7)])
  expect(await buttons($)).toEqual(ARMED)
})

test('Copy pressed while Not announcing is armed disarms it and still copies, and Mark sent pressed while it is armed records sent (#3847)', withKit, async ($, on) => {
  const { store, toasts, copies, clock } = world(on, { stored: { ...OWED_AND_OUT, [`announce:${REPO}#8`]: { ...ENTRY, pr: 8 }, [`announce-out:${REPO}#8`]: { at: T0 } } })
  await start($)
  await press($, `${BUTTON}none-${ID}`)
  expect(await buttons($)).toEqual([...ARMED, ...ALL_THREE])
  toasts.length = 0
  await press($, `${BUTTON}copy-${ID}`)
  expect(copies).toEqual([POST])
  expect(toasts).toEqual([])
  expect(await buttons($)).toEqual([...ALL_THREE, ...ALL_THREE])
  // Disarmed: the press after Copy is a first press, inside the time the earlier one armed it for.
  await clock.advance(1_000)
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(toasts).toEqual([armedSaid(7)])
  // Armed is one row's: the other row's button is not armed by it, and its one press settles nothing.
  expect(await buttons($)).toEqual([...ARMED, ...ALL_THREE])
  toasts.length = 0
  await press($, `${BUTTON}none-acme-widget-8`)
  expect(store.get(`announce-done:${REPO}#8`)).toBeUndefined()
  expect(toasts).toEqual([armedSaid(8)])
  // Mark sent while armed records that he posted it, never that it is not being announced.
  toasts.length = 0
  await press($, `${BUTTON}sent-${ID}`)
  expect(store.get(DONE_KEY)).toEqual({ how: 'sent', at: T0 + 1_000 })
  expect(toasts).toEqual([`Marked sent: the announcement for agents for ${NAME}. It is no longer asked for.`])
  expect(await buttons($)).toEqual([...ALL_THREE.slice(0, 2), confirmOf(8)])
})

test('Mark sent whose record cannot be written while Not announcing is armed leaves the row up and disarmed (#3847)', withKit, async ($, on) => {
  const { store, toasts, w } = world(on, { stored: OWED_AND_OUT })
  await start($)
  await press($, `${BUTTON}none-${ID}`)
  w.storeWriteFails = 'the store is read only'
  toasts.length = 0
  await press($, `${BUTTON}sent-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(toasts.length).toBe(1)
  expect(toasts[0]).toContain('It is still listed in /live, and its row stays in the band.')
  expect(await buttons($)).toEqual(ALL_THREE)
  w.storeWriteFails = undefined
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(await buttons($)).toEqual(ARMED)
})

test('a confirming press whose record cannot be written is said, and the button goes back to Not announcing, so settling it takes two presses again (#3847)', withKit, async ($, on) => {
  const { store, toasts, w } = world(on, { stored: OWED_AND_OUT })
  await start($)
  await press($, `${BUTTON}none-${ID}`)
  w.storeWriteFails = 'the store is read only'
  toasts.length = 0
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(toasts.length).toBe(1)
  expect(toasts[0]).toContain(`Is it live could not record that for the announcement for agents for ${NAME} (`)
  expect(await shown($)).toEqual(ROW)
  expect(await buttons($)).toEqual(ALL_THREE)
  w.storeWriteFails = undefined
  toasts.length = 0
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(toasts).toEqual([armedSaid(7)])
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toEqual({ how: 'not-announcing', at: T0 })
})

test('a band that will not draw the Confirm label leaves the button unarmed, says so, and a second press settles nothing (#3847)', withKit, async ($, on) => {
  const { store, toasts, w } = world(on, { stored: OWED_AND_OUT })
  await start($)
  w.bandFails = 'the band is full'
  toasts.length = 0
  await press($, `${BUTTON}none-${ID}`)
  await press($, `${BUTTON}none-${ID}`)
  const UNARMED = `Nothing is settled: the announcement for agents for ${NAME} is still owed. Its button could not be changed to ${confirmOf(7)} (the band is full), so it is not armed and the next press starts over.`
  expect(toasts).toEqual([UNARMED, UNARMED])
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(await buttons($)).toEqual(ALL_THREE)
  w.bandFails = undefined
  toasts.length = 0
  await press($, `${BUTTON}none-${ID}`)
  expect(toasts).toEqual([armedSaid(7)])
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(await buttons($)).toEqual(ARMED)
})

test('a row pinned again while Not announcing is armed keeps the Confirm label, and a session start forgets the arming (#3847)', withKit, async ($, on) => {
  const { store, toasts } = world(on, { stored: OWED_AND_OUT, prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  await press($, `${BUTTON}none-${ID}`)
  // /live pins every owed row again: the label it draws is the armed one, never a Not announcing
  // that one press would settle.
  await live($)
  expect(await buttons($)).toEqual(ARMED)
  // A session starting again has no button armed: its one press settles nothing.
  await start($)
  expect(await buttons($)).toEqual(ALL_THREE)
  toasts.length = 0
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(toasts).toEqual([armedSaid(7)])
})

test('an announcement another session settles while this one is armed is not written over by the second press, and its row comes down (#3847)', withKit, async ($, on) => {
  const { store, toasts, clock } = world(on, { stored: OWED_AND_OUT })
  await start($)
  await press($, `${BUTTON}none-${ID}`)
  store.set(DONE_KEY, { how: 'sent', at: T0 })
  toasts.length = 0
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toEqual({ how: 'sent', at: T0 })
  expect(toasts).toEqual(['That announcement for agents is already settled, so its row was taken down.'])
  expect(await shown($)).toEqual(['engine band'])
  await clock.advance(ARMED_MS)
  await clock.settle()
  expect(await shown($)).toEqual(['engine band'])
})

test('a row whose announcement another session settled says so when pressed, and comes down at the next turn end or /live', withKit, async ($, on) => {
  const { store, toasts, copies } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED, [`${REPO}#8`]: ANNOUNCED, [`${REPO}#9`]: ANNOUNCED } })
  await start($)
  await card($)
  store.set(DONE_KEY, { how: 'drafted', at: T0, draftId: 'Dr1' })
  toasts.length = 0
  await press($, `${BUTTON}copy-${ID}`)
  expect(copies).toEqual([])
  expect(toasts).toEqual(['That announcement for agents is already settled, so its row was taken down.'])
  expect(await shown($)).toEqual(['engine band'])
  // Settled is never taken back by a press that arrives late.
  expect(store.get(DONE_KEY)).toEqual({ how: 'drafted', at: T0, draftId: 'Dr1' })
  await card($, { pr: 8 })
  expect((await shown($)).length).toBe(2)
  store.set(`announce-done:${REPO}#8`, { how: 'sent', at: T0 })
  expect((await turnEnd($)).block).toBeUndefined()
  expect(await shown($)).toEqual(['engine band'])
  await card($, { pr: 9 })
  expect((await shown($)).length).toBe(2)
  store.set(`announce-done:${REPO}#9`, { how: 'not-announcing', at: T0 })
  expect(await live($)).not.toContain('nnouncement')
  expect(await shown($)).toEqual(['engine band'])
})

test('an announcement whose wording was not read has no Copy, and its session start line names only the buttons its row has', withKit, async ($, on) => {
  const why = 'the description holds no post under its heading'
  const { toasts } = world(on, { stored: { [`announce:${REPO}#7`]: { ...ENTRY, text: '', normalized: '', hash: '', channel: '', why }, [OUT_KEY]: { at: T0 } } })
  await start($)
  expect(toasts).toEqual([`An announcement for agents is still owed in this project: ${NAME} is live and cannot be drafted from this Mac (${why}). /live lists it, and its row in the band has Mark sent and Not announcing.`])
  expect(await shown($)).toEqual(['Announcement for agents', `${NAME}: cannot be drafted from this Mac (${why}).`])
  expect(await buttons($)).toEqual(['Mark sent', 'Not announcing'])
  // Typed, the button that is not drawn copies nothing and says why.
  toasts.length = 0
  await typed($, `${BUTTON}copy-${ID}`)
  expect(toasts).toEqual(['Not copied: no wording was read for that announcement for agents.'])
})

test('a band that refuses the row is said where it happened, and no sentence then names a row', withKit, async ($, on) => {
  const { toasts, w } = world(on, { stored: OWED_AND_OUT, prs: { [`${REPO}#7`]: ANNOUNCED }, bandFails: 'the band is full' })
  await start($)
  const UNPINNED = `The announcement for agents for ${NAME} could not be pinned in the band (the band is full)`
  expect(toasts).toEqual([`${UNPINNED}; /live lists it and tries to pin it again.`, `An announcement for agents is still owed in this project: ${NAME} is live and not yet a Slack draft. /live lists it.`])
  expect(said(await card($))).toContain(`${UNPINNED}; /live lists it and tries to pin it again.`)
  expect(await live($)).toContain(`\n\n${UNPINNED}.`)
  toasts.length = 0
  await turnEnd($)
  await turnEnd($, true)
  expect(toasts).toEqual([`Is it live let the turn end with the announcement for agents for ${NAME} not yet a Slack draft. It is still owed, and /live lists it.`])
  const r = await draft($, { message: POST.replace('Pick a reason', 'Choose a reason') })
  expect(said(r)).toContain('he can put the approved wording in its place or delete it')
  expect(said(r)).not.toContain('row in the band')
  // Once the band takes rows again, /live pins it.
  w.bandFails = undefined
  expect(await live($)).not.toContain('could not be pinned')
  expect(await shown($)).toEqual(ROW)
})

test('a draft judged before any card said the change is live names no row, since none is pinned', withKit, async ($, on) => {
  const { store } = world(on, { stored: { [`announce:${REPO}#7`]: ENTRY }, slackDraft: { text: '{"result":"Draft created"}' } })
  await start($)
  expect(await shown($)).toEqual(['engine band'])
  const r = await draft($)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(said(r)).toContain('if it is, he can send it, and if it is something else')
  expect(said(r)).not.toContain('row in the band')
  expect(await shown($)).toEqual(['engine band'])
})

test('a press whose record cannot be written is said, and the row stays for another press', withKit, async ($, on) => {
  const { store, toasts, w } = world(on, { stored: OWED_AND_OUT })
  await start($)
  toasts.length = 0
  w.storeWriteFails = 'the store is read only'
  await press($, `${BUTTON}sent-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(toasts.length).toBe(1)
  expect(toasts[0]).toContain(`Is it live could not record that for the announcement for agents for ${NAME} (`)
  expect(toasts[0]).toContain('It is still listed in /live, and its row stays in the band.')
  expect(await shown($)).toEqual(ROW)
  w.storeWriteFails = undefined
  await press($, `${BUTTON}sent-${ID}`)
  expect(store.get(DONE_KEY)).toEqual({ how: 'sent', at: T0 })
  expect(await shown($)).toEqual(['engine band'])
})

// ---- R8: only the wording the pull request merged on is ever drafted ----
// A description can be edited after the merge by a command no hook judges, so before any draft is
// asked for, counted or copied, the wording kept is checked against the hash the pull request
// claimed at the merge gate (hooks/lib/announce-compare.js, `claimed`).

const CHANGED: Gh = { exitCode: 0, stdout: '{"state":"changed","why":"the wording its description holds now is not the wording it merged on"}\n' }
const NO_CLAIM = "this Mac's record of the announcements Dan approved names no approval that pull request 7 of acme/widget merged on"
const WAS_CHANGED = 'the wording in its pull request was changed after Dan approved it'
const claimRuns = (runs: string[][]) => runs.filter(r => r[0] === 'node' && r[2] === 'claimed')

test('wording changed after Dan approved it is never asked for as a draft: the card says so in one sentence, and it stays owed until the pull request holds the approved wording again (R8)', withKit, async ($, on) => {
  const asked: { repo: string; pr: string; text: string }[] = []
  const { w, store, runs } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  w.claim = (repo, pr, text) => {
    asked.push({ repo, pr, text })
    return CHANGED
  }
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  const told = said(await card($))
  // The check is asked about this pull request, with the wording about to be drafted and nothing else.
  expect(asked).toEqual([{ repo: REPO, pr: '7', text: POST }])
  expect(claimRuns(runs)[0]).toEqual(['node', `${HOME}/.claude/hooks/lib/announce-compare.js`, 'claimed', '--repo', REPO, '--pr', '7'])
  expect(told).toContain(`${NAME} owes an announcement for agents, and it is not drafted: ${WAS_CHANGED}.`)
  expect(told).toContain('he must be asked again')
  // No draft is asked for, and the changed wording is not handed to the session at all.
  expect(told).not.toContain('slack_send_message_draft with channel_id')
  expect(told).not.toContain('Handing a call back')
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(await shown($)).toEqual(['Announcement for agents', `${NAME}: cannot be drafted from this Mac (${WAS_CHANGED}).`])
  expect(await live($)).toContain(`- ${NAME}: cannot be drafted from this Mac (${WAS_CHANGED}).`)
  // The turn end holds nothing for a draft that was never asked for.
  expect((await turnEnd($)).block ?? '').not.toContain('nnouncement')
  // Once the check passes for what the pull request holds, the next card reads it again and asks.
  const before = readerRuns(runs).length
  w.claim = () => ({ exitCode: 0, stdout: '{"state":"approved"}\n' })
  expect(said(await card($))).toContain(`call slack_send_message_draft with channel_id "${CH}"`)
  expect(readerRuns(runs).length).toBe(before + 1)
  expect(await shown($)).toEqual(ROW)
})

test('an approval that cannot be read, or a check that cannot be run, drafts nothing and says which, never taking silence for approved (R8)', withKit, async ($, on) => {
  const { w, store } = world(on, { prs: { [`${REPO}#7`]: ANNOUNCED } })
  await start($)
  await bash($, 'gh pr merge 7 --squash')
  const answers: [Gh, string][] = [
    [{ exitCode: 0, stdout: JSON.stringify({ state: 'unread', why: NO_CLAIM }) }, NO_CLAIM],
    [{ exitCode: 2, stdout: '', stderr: 'The wording could not be checked: the repository was not given as owner/name. Usage: announce-compare.js claimed' }, 'The wording could not be checked: the repository was not given as owner/name. Usage: announce-compare.js claimed'],
    [{ exitCode: 0, stdout: 'not json' }, 'its answer was not JSON'],
    [{ exitCode: 0, stdout: '{"state":"approved","why":"x"}{' }, 'its answer was not JSON'],
    [{ exitCode: 0, stdout: '{"state":"fine"}' }, 'its answer was not one this reader knows'],
    [{ exitCode: 0, stdout: '{"state":"changed"}' }, 'its answer was not one this reader knows'],
  ]
  for (const [g, why] of answers) {
    w.claim = () => g
    const told = said(await card($))
    expect(told).toContain(`${NAME} owes an announcement for agents, and it is not drafted: Dan's approval of its wording could not be read (${why}).`)
    expect(told).toContain('he must be asked again')
    expect(told).not.toContain('slack_send_message_draft with channel_id')
    expect(told).not.toContain('Handing a call back')
    expect(store.get(DONE_KEY)).toBeUndefined()
  }
})

test('a draft of wording that was changed after Dan approved it is not counted, whoever made it, and Copy hands none of it over (R8)', withKit, async ($, on) => {
  // Owed and live, and no card in this session checked it: a session drafts it on its own.
  const { w, store, toasts, copies } = world(on, { stored: OWED_AND_OUT })
  w.claim = () => CHANGED
  await start($)
  toasts.length = 0
  const r = await draft($)
  expect(store.get(DONE_KEY)).toBeUndefined()
  expect(said(r)).toContain(`A Slack draft was just made in channel ${CH}, and it is not counted as the announcement for agents for ${NAME}: ${WAS_CHANGED}.`)
  expect(said(r)).toContain('he must be asked again')
  expect(said(r)).not.toContain('is saved as a Slack draft')
  expect(toasts).toEqual([`A Slack draft in channel ${CH} is not counted as the announcement for agents for ${NAME}: ${WAS_CHANGED}. It is still owed.`])
  expect(await shown($)).toEqual(['Announcement for agents', `${NAME}: cannot be drafted from this Mac (${WAS_CHANGED}).`])
  // Copy is still on the row, and copies nothing that is not the approved wording.
  toasts.length = 0
  await press($, `${BUTTON}copy-${ID}`)
  expect(copies).toEqual([])
  expect(toasts).toEqual([`Not copied: the wording kept for ${NAME} is not known to be the wording you approved (${WAS_CHANGED}).`])
  // Mark sent and Not announcing still settle it: they hand no wording to anyone. Not announcing
  // takes its two presses here as anywhere (#3847).
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toBeUndefined()
  await press($, `${BUTTON}none-${ID}`)
  expect(store.get(DONE_KEY)).toEqual({ how: 'not-announcing', at: T0 })
})

test('a press of Copy gives its check of the wording less than the 10 seconds Claude Code gives a press, so the press is never cut off waiting on it (#744)', withKit, async ($, on) => {
  const { w, store, toasts, copies, limits } = world(on, { stored: OWED_AND_OUT })
  await start($)
  limits.length = 0
  toasts.length = 0
  await press($, `${BUTTON}copy-${ID}`)
  expect(copies).toEqual([POST])
  const asked = limits.filter(l => l.argv[2] === 'claimed')
  const given = asked.map(l => l.ms)
  expect(given.length).toBe(1)
  expect(given[0]).toBeLessThan(10_000)
  // And the check is told to give up before the press's own limit does, so a slow one answers with its reason (L842).
  expect(asked[0]?.argv.slice(7)).toEqual(['--within-ms', '4000'])
  expect(Number(asked[0]?.argv[8])).toBeLessThan(given[0] ?? 0)
  // A check that did not answer in that time copies nothing, says why, and leaves what is kept as it was.
  const kept = JSON.stringify(store.get(`announce:${REPO}#7`))
  copies.length = 0
  toasts.length = 0
  w.claim = () => {
    throw new Error('timed out after 6000ms')
  }
  await press($, `${BUTTON}copy-${ID}`)
  expect(copies).toEqual([])
  expect(toasts.length).toBe(1)
  expect(toasts[0]).toContain('Not copied:')
  expect(toasts[0]).toContain('the check could not be run:')
  expect(JSON.stringify(store.get(`announce:${REPO}#7`))).toBe(kept)
  expect(store.get(DONE_KEY)).toBeUndefined()
})
