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
// calls a real Slack tool: Slack's draft tool, GitHub, and the hooks' two command lines (the merge
// gate's reader and the one comparison of a draft with its wording) are the world beneath the mod.

type Part = { text?: string; color?: string; button?: string; label?: string }
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
          await built.state.set(ref, [...(await rows()).filter(r => !(r.mod === row.mod && r.id === row.id)), row] as never)
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
  remote: string | null
  stored?: Record<string, unknown>
  slackDraft: { text: string; isError?: true }
}

const answer = (o: Partial<Owed> & { state: Owed['state'] }): Gh => {
  const text = o.text ?? ''
  return { exitCode: 0, stdout: JSON.stringify({ channel: '', why: '', ...o, text, normalized: normal(text), hash: text ? hashOf(text) : '' }) + '\n' }
}
/** The reader as it answers a repository whose registry entry names the channel. */
const reads = (repo: string, pr: { labels: { name: string }[]; body: string }): Gh =>
  pr.labels.some(l => l.name === LABEL) ? answer({ state: 'owed', channel: CH, text: pr.body }) : answer({ state: 'none' })

const world = (on: On, init: Partial<World> = {}) => {
  const w: World = { prs: {}, reader: reads, remote: `git@github.com:${REPO}.git`, slackDraft: { text: '{"result":"Draft created","draft_id":"Dr0123ABC"}' }, ...init }
  const toasts: string[] = []
  const copies: string[] = []
  const runs: string[][] = []
  const clock = mock.clock(on, { now: T0 })
  // The store every session shares, held where a test can read it and write under the mod.
  const store = new Map<string, unknown>(Object.entries(w.stored ?? {}))
  on('store.get', ($, e) => ({ value: store.get(e.key) }) as never)
  on('store.set', ($, e) => {
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
      const read =
        what === 'gh' ? ghArgs(input.words) : what === 'mergeHelper' ? mergeHelperArgs(input as unknown as Command) : what === 'pipeline' ? pipelineIn(input.command, input.cwd, input.home ?? '') : what === 'linkRepo' ? linkRepo(input.link) : { github: githubRepo(input.remote), name: repoName(input) }
      return ok(read === undefined ? '' : JSON.stringify(read))
    }
    runs.push([...e.argv])
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
    else if (a.startsWith('gh repo view')) g = { exitCode: 0, stdout: `${REPO}\n` }
    else if (e.argv[0] === 'node' && e.argv[1] === `${HOME}/.claude/hooks/lib/changelog-entry.js` && e.argv[2] === 'announcement') g = w.reader(e.argv[3] as string, JSON.parse(stdin ?? 'null'))
    return { value: { exitCode: g.exitCode, stdout: g.stdout, stderr: g.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false } } as never
  })
  on('session.repo', () => ({ value: { root: FOLDER, remote: w.remote, isOwn: false } }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }) as never)
  on('session.cwd', () => ({ value: FOLDER }) as never)
  on('env.get', ($, e) => ({ value: (e as unknown as { name: string }).name === 'HOME' ? HOME : undefined }) as never)
  on('tool.call', { tool: 'Bash' }, () => ({ result: { stdout: '', stderr: '', interrupted: false }, text: '' }) as never)
  on('classic.Stop', () => ({}) as never)
  on('prompt.submit', ($, e) => ({ text: e.text, context: [] }) as never)
  on('tool.call', { tool: [DRAFT, SEND] }, () => (w.slackDraft.isError ? { isError: true, result: w.slackDraft.text, text: w.slackDraft.text } : { result: w.slackDraft.text, text: w.slackDraft.text }) as never)
  on('ui.log', () => ({ value: undefined }) as never)
  on('tool.register', () => ({ value: undefined }) as never)
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
  return { w, toasts, copies, runs, clock, store, keys: () => [...store.keys()].sort() }
}

const DRAFT = 'mcp__plugin_slack_slack__slack_send_message_draft'
const SEND = 'mcp__plugin_slack_slack__slack_send_message'
type Out = { deny?: string; result?: unknown; text?: string; context?: readonly string[]; isError?: boolean }
const call = async ($: unknown, tool: string, input: Record<string, unknown>) =>
  (await ($ as { tool: { call: (e: never) => Promise<unknown> } }).tool.call({ tool, tool_use_id: 't1', ...input } as never)) as Out
const bash = ($: unknown, command: string) => call($, 'Bash', { command })
const said = (o: Out) => (o.context ?? []).join('\n')
const start = async ($: unknown) => {
  await ($ as { session: { start: (x: never) => Promise<unknown> } }).session.start({ cwd: FOLDER, surface: 'terminal', isInteractive: true } as never)
}
const readerRuns = (runs: string[][]) => runs.filter(r => r[0] === 'node' && r[2] === 'announcement')

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
