import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { git, pipeline } from './mod-kit/hooks/commands.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'

// The three mods this one depends on, standing in (a mod cannot import another mod's files):
// mod-kit's band, card and send retry, the status bar's setModes, and the session registry's list.
// One plugin named mod-kit, so a band button it draws is pressed as mod-kit's. Each call it is
// handed comes back to the world as a transcript line the world reads (BAND, CLEAR, CARD, MODES);
// the registry asks the world for the sessions with a process.run. mod-kit's readers are its own:
// the stand-in asks the world (`__modkit`), which reads with a byte for byte copy of mod-kit's
// reader under tests/mod-kit, held to mod-kit's by tools/check-mod-shared-parts.sh, so a quoted
// separator is read as it is in a session (#730: the stand-in reader split inside quotes).
type Part = { text?: string; color?: string; button?: string; label?: string }
type Line = Part[] | { divider: true }
type Row = { mod: string; id: string; slot: string; frame?: { kind: string }; lines: Line[] }
const deps: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    // mod-kit's retry of a mod's refused send (its hooks/send.ts), standing in: once more when
    // refused, never after a throw, the reason tidied. mod-kit's own tests prove the real one.
    on('session.send', async ($, e, next) => {
      let why = ''
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const sent = await next(e)
          if (sent.isDelivered) return sent
          why = sent.reason
        } catch (err) {
          why = String((err as Error)?.message ?? err)
          break
        }
      }
      return { isDelivered: false, reason: why.trim().replace(/\.$/, '') || 'no reason given' }
    })
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const rows = async () => (((await built.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? [])
      // mod-kit's own readers, asked of the world, which reads with mod-kit's copy.
      const kit = async (method: string, input: unknown) => {
        const r = await built.process.run(['__modkit', method, JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return r.stdout === '' ? undefined : JSON.parse(r.stdout)
      }
      return {
        ...built,
        modkit: {
          blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
          pipeline: async (input: { command: string }) => kit('pipeline', input),
          writes: async (input: { command: string; cwd: string; home: string }) => kit('writes', input),
          git: async (input: { words: string[] }) => kit('git', input),
          bandRow: async (row: Row) => {
            built.ui.log('BAND ' + JSON.stringify(row))
            await built.state.set({ plugin: 'mod-kit', key: 'band' }, [...(await rows()).filter(r => !(r.mod === row.mod && r.id === row.id)), row] as never)
          },
          clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
            built.ui.log('CLEAR ' + id)
            await built.state.set({ plugin: 'mod-kit', key: 'band' }, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
          },
          // The screen (#707): refuses a call carrying SCREEN-REFUSES, as the secret guard refuses a
          // token; mod-kit's own tests prove the real one asks the secret guard.
          screen: async (call: unknown) => (JSON.stringify(call).includes('SCREEN-REFUSES') ? { deny: 'Blocked: this message contains a secret. Refer to it by its name, not its value.' } : null),
          // The kit's other members, which these tests never reach: each refuses by name if one ever is.
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          commands: async () => { throw new Error("mod-kit's commands is not stood in by these tests") },
          workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
        },
        statusbar: {
          setModes: async ({ modes }: { modes: string[] }) => built.ui.log('MODES ' + JSON.stringify(modes)),
          setMode: async () => undefined,
        },
        sessions: {
          list: async () => {
            const r = await built.process.run(['__sessions'])
            if (r.exitCode !== 0) throw new Error(r.stderr)
            return JSON.parse(r.stdout)
          },
          noteEdit: async () => undefined,
          setExtra: async () => undefined,
        },
      }
    })
    // The band as mod-kit draws it, enough to press a button by its key.
    on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
      const rows = ((await $.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? []
      if (!rows.length) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      return (
        <Box flexDirection="column">
          {rows.flatMap(r =>
            r.lines.map((l, n) =>
              Array.isArray(l) ? (
                <Box key={`${r.id}${n}`} flexDirection="row">
                  {l.map((p, i) => (p.button ? <Button key={`${r.mod}:${p.button}`} label={p.label as string} onPress={() => undefined} /> : <Text key={String(i)}>{p.text}</Text>))}
                </Box>
              ) : (
                <Text key={`${r.id}${n}`}>----</Text>
              ),
            ),
          )}
        </Box>
      )
    })
  },
}
// is it live's verdict, standing in as its own plugin so a test can leave it out: asked of the
// world as a process.run (__verdict).
const isItLive: { name: string; register: Register } = {
  name: 'is-it-live',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        isItLive: {
          verdict: async ({ repo, pr }: { repo: string; pr: number }) => {
            const r = await built.process.run(['__verdict', repo, String(pr)])
            if (r.exitCode !== 0) throw new Error(r.stderr)
            return JSON.parse(r.stdout)
          },
        },
      }
    })
  },
}
const withDeps = { plugins: [deps, isItLive] }
const withoutIsItLive = { plugins: [deps] }

const MIN = 60_000
const T0 = 1_000_000
const BOOT = 1759800000
const SCRATCH = '/private/tmp/claude-501/-Users-x-proj/s1/scratchpad'
const AWAY_TEXT = 'Dan switched every session on this Mac to away.'
const PHONE_LINE = "You're on your phone. Reply away to switch every session."

type Session = { sessionId: string; extra?: Record<string, unknown> }
// The one PR GitHub holds, found by `gh pr list --head` only for its own branch (scope-modes-616
// unless headRefName says otherwise) and by `gh pr view` only by its own number.
type GhPr = { number: number; state: string; url?: string; headRefName?: string; closingIssuesReferences: { number: number }[] }
// `others` are PRs GitHub also holds, found only by `gh pr view` by number (#856).
type Gh = { pr: GhPr | null; others?: GhPr[]; issues: Record<number, string>; fails?: string }
type Opts = {
  /** What a `gh pr create` call prints, as gh does: the new PR's link. */
  created?: string
  /** is it live's verdict for the PR asked about: a card's state, no card, or a read that throws. */
  verdict?: { state: string; at: number } | null | { throws: string }
  open?: Session[]
  unreadable?: string[]
  sends?: (true | { refused: string })[]
  branch?: string
  gh?: Gh
  branchHere?: boolean
  branchOnGitHub?: boolean
  worktrees?: string
  ask?: string
  /** The Mac's files beneath the sleep record (#840), by path; mv, ln and rm act on them. */
  files?: Record<string, string>
  /** This boot's start, as sysctl gives it; null when sysctl fails. */
  boot?: number | null
  /** A move or link of the sleep record that fails for a reason other than the file being gone. */
  mvFails?: string
  lnFails?: string
  notifyFails?: boolean
  /** The night's notes file cannot be appended to (#841): the shell's own words. */
  noteFails?: string
  /** A new record written over the old one just before the first move of it: a sleep begun between a read and a move. */
  replacedBeforeMove?: string
  /** Each folder's origin remote (#843); /repo is o/r unless said. */
  origins?: Record<string, string>
  /** The repositories GitHub shows to the active account (`default`) and to each other account's token, by account. */
  githubRepos?: Record<string, string[]>
  /** Dan's bedtime answer, or none: the question waits until the test moves the clock. */
  repoAnswer?: string | null
  /** A link of the preparing marker or the answers lock that fails (#843). */
  markerFails?: string
}

const ok = (stdout = '') => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
const fail = (exitCode: number, stderr = '') => ({ value: { exitCode, stdout: '', stderr, isStdoutTruncated: false, isStderrTruncated: false } })

// The Mac, GitHub and the person beneath the mod. Everything that gets past the mod is recorded.
const world = (on: On, o: Opts = {}) => {
  const w = {
    o,
    reached: [] as string[],
    cards: [] as Record<string, unknown>[],
    bands: [] as Row[],
    cleared: [] as string[],
    modes: [] as string[][],
    toasts: [] as string[],
    sent: [] as { to: unknown; text: string }[],
    prompts: [] as string[],
    runs: [] as string[][],
    /** Every mv, ln and rm, in order, as the Mac saw them (#843). */
    fileOps: [] as string[][],
    asked: [] as string[],
    tools: [] as string[],
    logs: [] as string[],
    files: { ...o.files } as Record<string, string>,
    fsWrites: [] as string[],
    notified: [] as string[],
    appended: [] as { file: string; line: string }[],
  }
  const clock = mock.clock(on, { now: T0 })
  mock.env(on, { HOME: '/Users/x' })
  // The Mac's files, in memory, for the sleep record (#840). Every move and link is one step, as
  // rename and link are on the disk, so of two sessions moving one record exactly one succeeds.
  on('fs.write', ($, e) => {
    w.fsWrites.push(e.path)
    w.files[e.path] = e.text
    return { value: undefined }
  })
  on('fs.read', ($, e) => {
    if (!(e.path in w.files)) throw new Error(`ENOENT: no such file or directory, open '${e.path}'`)
    return { value: w.files[e.path] as string } as never
  })
  on('fs.exists', ($, e) => ({ value: e.path in w.files || Object.keys(w.files).some(f => f.startsWith(`${e.path}/`)) }) as never)
  on('process.run', ($, e) => {
    const argv = [...e.argv]
    const [cmd, ...a] = argv
    const ops = a.filter(x => !x.startsWith('-'))
    if (cmd === 'mv' || cmd === 'ln' || cmd === 'rm') w.fileOps.push(argv)
    if (cmd === 'sysctl') return o.boot === null ? fail(1, 'sysctl: unknown oid') : ok(`{ sec = ${o.boot ?? BOOT}, usec = 5 } Tue Oct  6 09:00:00 2026\n`)
    if (cmd === 'mkdir') return ok()
    if (cmd === 'mv') {
      const [from, to] = ops as [string, string]
      if (!(from in w.files)) return fail(1, `mv: rename ${from} to ${to}: No such file or directory`)
      if (o.mvFails) return fail(1, `mv: rename ${from} to ${to}: ${o.mvFails}`)
      if (o.replacedBeforeMove && from.endsWith('/current.json')) {
        w.files[from] = o.replacedBeforeMove
        o.replacedBeforeMove = undefined
      }
      if (a.includes('-n') && to in w.files) return ok()
      w.files[to] = w.files[from] as string
      delete w.files[from]
      return ok()
    }
    if (cmd === 'ln') {
      const [from, to] = ops as [string, string]
      if (o.lnFails && to.endsWith('/current.json')) return fail(1, `ln: ${to}: ${o.lnFails}`)
      if (o.markerFails && !to.endsWith('/current.json')) return fail(1, `ln: ${to}: ${o.markerFails}`)
      if (to in w.files) return fail(1, `ln: ${to}: File exists`)
      if (!(from in w.files)) return fail(1, `ln: ${from}: No such file or directory`)
      w.files[to] = w.files[from] as string
      return ok()
    }
    if (cmd === 'rm') {
      for (const f of ops) for (const k of Object.keys(w.files)) if (k === f || (a.includes('-rf') && k.startsWith(`${f}/`))) delete w.files[k]
      return ok()
    }
    if (cmd === 'sh' && a[0] === '-c' && String(a[1]).includes('>>')) {
      // The note appended to the night's notes file: sh -c '...' sh <dir> <line> <file>
      const [, , , , line, file] = a as string[]
      if (o.noteFails) return fail(1, o.noteFails)
      w.appended.push({ file: file as string, line: line as string })
      w.files[file as string] = `${w.files[file as string] ?? ''}${line}\n`
      return ok()
    }
    if (cmd === 'terminal-notifier') {
      if (o.notifyFails) return fail(1, 'terminal-notifier: no permission to notify')
      w.notified.push(a[a.indexOf('-message') + 1] as string)
      return ok()
    }
    // mod-kit's readers, read here with its copy; a command naming __reader_fails stands for a
    // reader that throws. Not one of the runs a test watches, which reach the Mac.
    if (cmd === '__modkit') {
      const input = JSON.parse(a[1] as string) as { command?: string; cwd?: string; home?: string; words?: string[] }
      if ((input.command ?? '').includes('__reader_fails')) return fail(1, 'the reader broke')
      const out = a[0] === 'pipeline' ? pipeline(input.command ?? '') : a[0] === 'writes' ? commandWrites(input.command ?? '', input.cwd ?? '', input.home ?? '') : git(input.words ?? [])
      return ok(out === undefined ? '' : JSON.stringify(out))
    }
    w.runs.push(argv)
    if (cmd === '__sessions') {
      if (o.unreadable?.includes('*')) return fail(1, 'the sessions folder could not be read')
      return ok(JSON.stringify({ open: [{ sessionId: 's1' }, ...(o.open ?? [])], closed: [], unreadable: o.unreadable ?? [], selfId: 's1' }))
    }
    if (cmd === '__verdict') {
      const v = o.verdict ?? null
      return v && 'throws' in v ? fail(1, v.throws) : ok(JSON.stringify(v))
    }
    // Sleep mode phase 7 (#843): each folder's origin, GitHub's answer to a repo view by account, and gh's accounts.
    if (cmd === 'git' && a.includes('get-url')) {
      const url = (o.origins ?? { '/repo': 'git@github.com:o/r.git' })[a[1] as string]
      return url ? ok(`${url}\n`) : fail(2, 'error: No such remote')
    }
    if (cmd === 'gh' && a[0] === 'repo' && a[1] === 'view') {
      const token = e.init?.env?.GH_TOKEN
      const seen = token ? (o.githubRepos?.[token] ?? []) : (o.githubRepos?.default ?? [])
      return seen.some(r => r.toLowerCase() === String(a[2]).toLowerCase()) ? ok(JSON.stringify({ nameWithOwner: a[2] })) : fail(1, `GraphQL: Could not resolve to a Repository with the name '${a[2]}'. (repository)`)
    }
    if (cmd === 'gh' && a[0] === 'auth' && a[1] === 'status') return ok(Object.keys(o.githubRepos ?? {}).filter(k => k !== 'default').map(k => `  Logged in to github.com account ${k} (keyring)`).join('\n'))
    if (cmd === 'gh' && a[0] === 'auth' && a[1] === 'token') return ok(`${a[3]}\n`)
    if (cmd === 'git' && a.includes('--show-current') && o.branch === '__fails') return fail(128, 'fatal: not a git repository')
    if (cmd === 'git' && a.includes('--show-current')) return ok(`${o.branch ?? 'scope-modes-616'}\n`)
    if (cmd === 'git' && a.includes('symbolic-ref')) return ok('origin/main\n')
    if (cmd === 'git' && a.includes('--list')) return ok(o.branchHere === false ? '' : `  ${o.branch ?? 'scope-modes-616'}\n`)
    if (cmd === 'git' && a.includes('ls-remote')) return o.branchOnGitHub === false ? fail(2) : ok(`abc\trefs/heads/${o.branch ?? 'scope-modes-616'}\n`)
    if (cmd === 'git' && a.includes('worktree')) return ok(o.worktrees ?? `worktree /repo\nbranch refs/heads/main\n`)
    if (cmd === 'git' && a.includes('status')) return ok('')
    if (cmd === 'gh') {
      const gh = o.gh ?? { pr: null, issues: {} }
      if (gh.fails) return fail(1, gh.fails)
      const head = gh.pr?.headRefName ?? 'scope-modes-616'
      if (a[0] === 'pr' && a[1] === 'list') return ok(JSON.stringify(gh.pr && a[a.indexOf('--head') + 1] === head ? [{ headRefName: head, ...gh.pr }] : []))
      if (a[0] === 'pr' && a[1] === 'view') {
        if (gh.pr && a[2] === String(gh.pr.number)) return ok(JSON.stringify({ headRefName: head, ...gh.pr }))
        const other = gh.others?.find(p => a[2] === String(p.number))
        return other ? ok(JSON.stringify(other)) : fail(1, 'no pull requests found')
      }
      if (a[0] === 'issue' && a[1] === 'view' && (gh as { garbled?: boolean }).garbled) return ok('<html>rate limited</html>')
      if (a[0] === 'issue' && a[1] === 'view') return ok(JSON.stringify({ state: gh.issues[Number(a[2])] ?? 'OPEN' }))
    }
    return fail(1, `unexpected: ${argv.join(' ')}`)
  })
  on('session.id', () => ({ value: 's1' }) as never)
  on('session.cwd', () => ({ value: '/repo' }) as never)
  on('session.repo', () => ({ value: { root: '/repo', remote: 'git@github.com:o/r.git', internal: false, name: null } }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  on('command.register', () => ({ value: undefined }) as never)
  on('tool.register', ($, e) => {
    w.tools.push(String((e as { name?: string }).name))
    return { value: undefined } as never
  })
  let sends = 0
  on('session.send', ($, e) => {
    w.sent.push({ to: e.to, text: e.text })
    const outcome = o.sends?.[sends++] ?? true
    return (outcome === true ? { isDelivered: true } : { isDelivered: false, reason: outcome.refused }) as never
  })
  on('prompt.submit', ($, e) => {
    w.prompts.push(e.text)
    return { text: e.text, context: e.context } as never
  })
  on('turn.complete', ($, e) => ({ text: e.answer }) as never)
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  on('classic.Stop', () => ({}) as never)
  on('ui.toast', ($, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    w.logs.push(e.text)
    const [tag, ...rest] = e.text.split(' ')
    const body = rest.join(' ')
    if (tag === 'CARD') w.cards.push(JSON.parse(body))
    if (tag === 'BAND') w.bands.push(JSON.parse(body))
    if (tag === 'CLEAR') w.cleared.push(body)
    if (tag === 'MODES') w.modes.push(JSON.parse(body))
    return { value: undefined }
  })
  on('tool.call', ($, e) => {
    // $.ui.ask raises the AskUserQuestion dialog as a tool call; Dan answers it here.
    if (e.tool === 'AskUserQuestion') {
      const q = String((e as unknown as { questions: { question: string }[] }).questions[0]?.question)
      w.asked.push(q)
      if (q.endsWith('what may Claude do?') && o.repoAnswer === null) return new Promise(() => undefined) as never
      if (q.endsWith('what may Claude do?') && o.repoAnswer === '__dismissed') throw new Error('the dialog was dismissed')
      if (q.endsWith('what may Claude do?') && o.repoAnswer !== undefined) {
        const a = o.repoAnswer
        return { result: { questions: (e as unknown as { questions: unknown[] }).questions, answers: { [q]: a } }, text: `answered ${a}` } as never
      }
      return { result: { questions: (e as unknown as { questions: unknown[] }).questions, answers: { [q]: o.ask ?? 'Yes' } }, text: `answered ${o.ask ?? 'Yes'}` } as never
    }
    const command = (e as { command?: string }).command
    w.reached.push(String(command ?? (e as { file_path?: string }).file_path ?? e.tool))
    if (command?.includes('gh pr create') && o.created) return { result: { stdout: o.created, stderr: '' }, text: o.created } as never
    return { result: 'ran', text: 'ran' } as never
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  return { w, clock }
}

type $T = {
  session: { start: (e: never) => Promise<unknown>; end: (e: never) => Promise<unknown>; receive: (e: never) => Promise<unknown> }
  tool: { call: (e: never) => Promise<unknown> }
  command: { run: (e: never) => Promise<unknown> }
  prompt: { submit: (e: never) => Promise<unknown> }
  turn: { complete: (e: never) => Promise<unknown> }
  classic: { Stop: (e: never) => Promise<unknown> }
}
const start = async ($: $T, clock: { settle: () => Promise<void> }) => {
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  await clock.settle()
}
const command = async ($: $T, name: string, origin: string = 'composer') =>
  (await $.command.run({ command: name, args: '', origin: { kind: origin }, presentation: {} } as never)) as { text?: string; context?: string[] }
const say = async ($: $T, text: string, origin: string = 'composer') => (await $.prompt.submit({ text, origin: { kind: origin }, wait: false } as never)) as { text: string; context?: string[] }
const bash = (command: string, id = 'c1') => ({ tool: 'Bash', command, tool_use_id: id }) as never
const edit = (path: string, id = 'c1') => ({ tool: 'Edit', file_path: path, old_string: 'a', new_string: 'b', tool_use_id: id }) as never
const call = async ($: $T, e: never) => {
  const r = (await $.tool.call(e)) as { deny?: string; text?: string }
  return r.deny ?? r.text ?? ''
}
const stop = async ($: $T) => (await $.classic.Stop({ stop_hook_active: false } as never)) as { block?: string }
const lastModes = (w: { modes: string[][] }) => w.modes[w.modes.length - 1]

// ---- Scope modes (#616) ----

test('a phrase from Dan turns no build on: the mode leads the band, and Claude is told to say so', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  const r = await say($ as never, 'no coding yet, just research how the sync works')
  expect(lastModes(w)).toEqual(['NO BUILD'])
  expect(r.context?.join('\n')).toMatch(/No build just turned on.*Say so in one line/s)
})

test('the same phrase from another session, a plugin or a notification changes nothing', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  for (const kind of ['peer', 'task-notification', 'unclassified']) await say($ as never, 'no coding yet', kind)
  expect(w.modes).toEqual([])
  expect(await call($ as never, edit('/repo/app.ts'))).toBe('ran')
})

test('/nobuild and /winddown say which mode turned on; /build turns it off and confirms', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  expect((await command($ as never, 'nobuild')).text).toBe('No build is on.')
  expect(lastModes(w)).toEqual(['NO BUILD'])
  expect((await command($ as never, 'winddown')).text).toBe('Winding down is on.')
  expect(lastModes(w)).toEqual(['WINDING DOWN'])
  expect((await command($ as never, 'build')).text).toBe('Winding down is off.')
  expect(lastModes(w)).toEqual([])
  expect((await command($ as never, 'build')).text).toBe('No scope mode was on.')
})

test('"go ahead and build" from Dan turns no build off, and Claude confirms it', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  const r = await say($ as never, 'ok, go ahead and build')
  expect(lastModes(w)).toEqual([])
  expect(r.context?.join('\n')).toMatch(/No build just turned off.*Say so in one line/s)
  expect(await call($ as never, edit('/repo/app.ts'))).toBe('ran')
})

// A message Dan types while a turn runs reaches prompt.submit at Enter carrying that turn's id
// (the engine's PromptSubmitInput.turnId), so it is read like any other (#805).
const sayMidTurn = async ($: $T, text: string) =>
  (await $.prompt.submit({ text, origin: { kind: 'composer' }, wait: false, turnId: 'turn-running' } as never)) as { text: string; context?: string[] }

test('"stop winding down mode" sent mid turn turns winding down off, and the turn end is no longer refused (#805)', withDeps, async ($, on) => {
  const { w, clock } = world(on, { gh: merged('OPEN') })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  expect((await stop($ as never)).block).toMatch(/Winding down is not finished/)
  const r = await sayMidTurn($ as never, 'stop winding down mode. run load 1')
  expect(lastModes(w)).toEqual([])
  expect(r.context?.join('\n')).toMatch(/Winding down just turned off.*Say so in one line/s)
  expect((await stop($ as never)).block).toBeUndefined()
  expect(w.logs.filter(l => l.includes('sent mid turn'))).toEqual(['scope-modes: a message from Dan sent mid turn reached the mod: switched 1, still on note not added'])
})

test('turning one mode off by name leaves the other mode alone (#805)', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  const r = await say($ as never, 'stop winding down mode')
  expect(lastModes(w)).toEqual(['NO BUILD'])
  expect(r.context?.join('\n') ?? '').not.toMatch(/just turned off/)
})

test('a message naming the mode that is on, in words that do not switch it, gets a note that it is still on and how to turn it off (#805)', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'winddown')
  const r = await sayMidTurn($ as never, 'winding down is done for today, thanks')
  expect(lastModes(w)).toEqual(['WINDING DOWN'])
  expect(r.context?.join('\n')).toMatch(/names winding down.*still on.*\/build turns it off/s)
  // The note switches nothing, and the debug line says so (lessons review of #820).
  expect(w.logs.filter(l => l.includes('sent mid turn'))).toEqual(['scope-modes: a message from Dan sent mid turn reached the mod: switched 0, still on note added'])
  // The same words from elsewhere, or with the mode off, add no such note.
  expect((await say($ as never, 'winding down is done', 'peer')).context?.join('\n') ?? '').not.toMatch(/names winding down/)
  // Naming it in passing adds no note (lessons review of #820).
  expect((await say($ as never, 'the project is winding down, add the release notes')).context?.join('\n') ?? '').not.toMatch(/names winding down/)
  await command($ as never, 'build')
  expect((await say($ as never, 'the project is winding down')).context?.join('\n') ?? '').not.toMatch(/names winding down/)
})

test('no build refuses an edit with the grey card, and tells Claude to ask Dan "Switch to build?"', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  const r = await call($ as never, edit('/repo/app.ts', 'e1'))
  expect(r).toMatch(/^Blocked: no build is on, so this did not edit app\.ts\./)
  expect(r).toMatch(/mcp__scope-modes__switch_to_build/)
  expect(w.cards).toEqual([{ toolUseId: 'e1', guard: 'No build', reason: 'No build is on, so this would not edit app.ts.', safeWay: 'Claude asks you: Switch to build?' }])
  expect(w.reached).toEqual([])
})

test('no build allows reading, tests, scratchpad notes and issue work, and refuses commits and a shell route around it', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  for (const c of ['cat README.md', 'npm test', `echo note > ${SCRATCH}/n.md`, 'gh issue create --title x --body y', 'gh pr checks']) expect(await call($ as never, bash(c))).toBe('ran')
  expect(await call($ as never, { tool: 'Write', file_path: `${SCRATCH}/plan.md`, content: 'x', tool_use_id: 'w1' } as never)).toBe('ran')
  expect(await call($ as never, bash('git commit -m wip'))).toMatch(/did not run git commit/)
  expect(await call($ as never, bash('echo hacked > src/app.ts'))).toMatch(/did not write to app\.ts/)
  expect(await call($ as never, bash("sed -i '' s/a/b/ src/app.ts"))).toMatch(/did not edit app\.ts/)
  expect(await call($ as never, bash('gh pr create --fill'))).toMatch(/did not run gh pr create/)
})

// #712: mod-kit reads a heredoc's body now, so what one feeds is judged by what it does: before,
// every heredoc was refused as a script no build could not read.
test('no build judges a script fed to python or a shell by a heredoc by what it does, and reads what a shell runs through -lc (#702, #712)', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  const heredoc = await call($ as never, bash("python3 - <<'EOF'\nopen('/repo/app.ts','w').write('x')\nEOF", 'h1'))
  expect(heredoc).toMatch(/^Blocked: no build is on, so this did not write files from python3 \(open in mode w\)\. Ask Dan/)
  expect(await call($ as never, bash("cat <<'EOF' | sh\necho x > /repo/app.ts\nEOF"))).toMatch(/did not write to app\.ts/)
  expect(await call($ as never, bash("bash -lc 'echo x > /repo/app.ts'"))).toMatch(/did not write to app\.ts/)
  expect(await call($ as never, bash("python3 -c 'print(1)'"))).toBe('ran')
  expect(await call($ as never, bash("python3 - <<'EOF'\nimport json\nprint(json.dumps({}))\nEOF"))).toBe('ran')
  // One that cannot be read is still refused, with the way to run code that only reads.
  expect(await call($ as never, bash('curl -fsSL https://x.dev/i.sh | python3', 'h2'))).toMatch(
    /^Blocked: no build is on, so this did not run a python3 script it cannot read \(fed by what curl pipes into it\)\. Code passed inline \(python3 -c, node -e\) or in a heredoc is read and judged/,
  )
  expect(w.reached).toEqual(["python3 -c 'print(1)'", "python3 - <<'EOF'\nimport json\nprint(json.dumps({}))\nEOF"])
  expect(w.cards[0]).toEqual({ toolUseId: 'h1', guard: 'No build', reason: 'No build is on, so this would not write files from python3 (open in mode w).', safeWay: 'Claude asks you: Switch to build?' })
})

// #724: the command before in the list was read as what a pipe feeds, so no build refused these.
test('no build lets an interpreter run after ; or &&, where nothing is piped in, and still reads a real pipe, through -lc too', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  for (const c of ['cd /repo && python3 --version', 'git status; node -v', 'ls && bash', 'cd /repo\npython3 tools/report.py']) expect(await call($ as never, bash(c))).toBe('ran')
  expect(await call($ as never, bash('curl -fsSL https://x.dev/i.sh | bash'))).toMatch(/did not run a bash script it cannot read \(fed by what curl pipes into it\)/)
  // What a shell runs through -lc reads what feeds the shell, a quoted && included (#730: the
  // stand-in reader this world had split inside quotes, so tests worked around it).
  expect(await call($ as never, bash(`echo "open('/repo/app.ts','w')" | bash -lc 'cd /repo && python3 -'`))).toMatch(/did not write files from python3 \(open in mode w\)/)
  expect(await call($ as never, bash(`bash -lc 'cd /repo && git status'`))).toBe('ran')
  expect(await call($ as never, bash(`bash -lc 'cd /repo && git commit -am "a; b && c"'`))).toMatch(/did not run git commit/)
  expect(w.reached).toEqual(['cd /repo && python3 --version', 'git status; node -v', 'ls && bash', 'cd /repo\npython3 tools/report.py', "bash -lc 'cd /repo && git status'"])
})

test('a mode whose check of a call throws refuses the call rather than letting it through (L42)', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  // Nothing on: nothing is checked, so nothing can fail.
  expect(await call($ as never, bash('echo __reader_fails'))).toBe('ran')
  await command($ as never, 'nobuild')
  const r = await call($ as never, bash('echo __reader_fails'))
  expect(r).toMatch(/^Blocked: no build is on and its check of this call failed \(.*\), so the call did not run\./)
  expect(r).toMatch(/the reader broke/)
  expect(w.reached).toEqual(['echo __reader_fails'])
})

test('"Switch to build?" is asked of Dan, naming the change; only his yes lifts no build', withDeps, async ($, on) => {
  const { w, clock } = world(on, { ask: 'No' })
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  const no = await call($ as never, { tool: 'mcp__scope-modes__switch_to_build', change: 'edit app.ts to fix the date parse', tool_use_id: 't1' } as never)
  expect(w.asked).toEqual(['Claude wants to edit app.ts to fix the date parse. Switch to build?'])
  expect(no).toMatch(/Dan said no: no build stays on/)
  expect(lastModes(w)).toEqual(['NO BUILD'])
  w.o.ask = 'Yes'
  const yes = await call($ as never, { tool: 'mcp__scope-modes__switch_to_build', change: 'edit app.ts', tool_use_id: 't2' } as never)
  expect(yes).toMatch(/Dan said yes: no build is off/)
  expect(lastModes(w)).toEqual([])
})

// #707: this mod answers switch_to_build itself, so the secret guard beneath it never sees the call;
// it asks mod-kit's screen first. A change carrying a token is refused before Dan is asked about it.
test('a switch to build a guard refuses is refused before Dan is asked (#707)', withDeps, async ($, on) => {
  const { w, clock } = world(on, { ask: 'Yes' })
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  const r = await call($ as never, { tool: 'mcp__scope-modes__switch_to_build', change: 'paste the key SCREEN-REFUSES into .env', tool_use_id: 't3' } as never)
  expect(r).toBe('Blocked: this message contains a secret. Refer to it by its name, not its value.')
  expect(w.asked).toEqual([])
  expect(lastModes(w)).toEqual(['NO BUILD'])
})

const merged = (state = 'MERGED') => ({ pr: { number: 12, state, url: 'https://github.com/o/r/pull/12', closingIssuesReferences: [{ number: 616 }] }, issues: { 616: state === 'MERGED' ? 'CLOSED' : 'OPEN' } })

test('winding down refuses the turn end until merged, live and cleaned, then ends itself with a safe to close toast (injected clock)', withDeps, async ($, on) => {
  const { w, clock } = world(on, { gh: merged('OPEN') })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  const first = await stop($ as never)
  expect(first.block).toMatch(/^Winding down is not finished: PR #12 is not merged yet\./)
  expect(first.block).toMatch(/Keep watching CI and the deploy/)

  w.o.gh = merged()
  const second = await stop($ as never)
  expect(second.block).toMatch(
    /PR #12 has no is it live card yet: check the deploy and make the card \(mcp__is-it-live__card\); the branch scope-modes-616 still exists here; the branch scope-modes-616 still exists on GitHub/,
  )

  // The card says Live: is it live's verdict, never Claude's word, is what counts (#687).
  w.o.verdict = { state: 'live', at: T0 }
  w.o.branchHere = false
  w.o.branchOnGitHub = false
  // Nothing finishes it between checks but the clock: the next minute's check does.
  expect(w.toasts).toEqual([])
  await clock.advance(MIN)
  expect(w.toasts).toEqual(['Wind down finished: safe to close this session.'])
  expect(lastModes(w)).toEqual([])
  expect((await stop($ as never)).block).toBeUndefined()
  // The verdict asked for is this PR's, in the repository GitHub's own link for it names.
  expect(w.runs.filter(r => r[0] === '__verdict')[0]).toEqual(['__verdict', 'o/r', '12'])
})

const cleaned = { gh: merged(), branchHere: false, branchOnGitHub: false }

test("deploying, or could not confirm live, keeps the turn end refused with that reason; no deploy step recorded finishes it", withDeps, async ($, on) => {
  const { w, clock } = world(on, { ...cleaned, verdict: { state: 'deploying', at: T0 } })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  expect((await stop($ as never)).block).toMatch(/^Winding down is not finished: the deploy is still running \(is it live says Merged, deploying\)\./)
  w.o.verdict = { state: 'unconfirmed', at: T0 }
  expect((await stop($ as never)).block).toMatch(/^Winding down is not finished: is it live could not confirm the deploy live: find out why, and make the card again once it is\./)
  await clock.advance(5 * MIN)
  expect(w.toasts).toEqual([])
  w.o.verdict = { state: 'no-deploy', at: T0 }
  expect((await stop($ as never)).block).toBeUndefined()
  expect(w.toasts).toEqual(['Wind down finished: safe to close this session.'])
})

test('without the is it live mod the deploy is unmeasured, never live: the turn end stays refused', withoutIsItLive, async ($, on) => {
  const { w, clock } = world(on, cleaned)
  await start($ as never, clock)
  await command($ as never, 'winddown')
  expect((await stop($ as never)).block).toMatch(/^Winding down is not finished: the deploy is unmeasured: the is it live mod is not loaded\./)
  await clock.advance(5 * MIN)
  expect(w.toasts).toEqual([])
  expect(lastModes(w)).toEqual(['WINDING DOWN'])
})

test('a verdict that cannot be read, or a PR GitHub gave no link for, is said and never counts as live', withDeps, async ($, on) => {
  const { w, clock } = world(on, { ...cleaned, verdict: { throws: 'the session state could not be read' } })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  expect((await stop($ as never)).block).toMatch(/the deploy verdict could not be read \(the session state could not be read\)/)
  w.o.verdict = { state: 'live', at: T0 }
  w.o.gh = { ...merged(), pr: { number: 12, state: 'MERGED', closingIssuesReferences: [{ number: 616 }] } }
  expect((await stop($ as never)).block).toMatch(/the deploy verdict could not be read \(GitHub gave no link for PR #12\)/)
  expect(w.toasts).toEqual([])
})

test("Claude's own report is retired: no winddown_live tool, and calling it records nothing", withDeps, async ($, on) => {
  const { w, clock } = world(on, cleaned)
  await start($ as never, clock)
  expect(w.tools).toContain('switch_to_build')
  expect(w.tools).not.toContain('winddown_live')
  await command($ as never, 'winddown')
  await call($ as never, { tool: 'mcp__scope-modes__winddown_live', how: 'I checked, trust me', tool_use_id: 'l1' } as never)
  expect((await stop($ as never)).block).toMatch(/PR #12 has no is it live card yet/)
  expect(w.toasts).toEqual([])
})

test('a finish check that cannot read GitHub never counts as finished', withDeps, async ($, on) => {
  const { w, clock } = world(on, { gh: { pr: null, issues: {}, fails: 'HTTP 502' } })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  expect((await stop($ as never)).block).toMatch(/the PR could not be read \(HTTP 502\)/)
  await clock.advance(5 * MIN)
  expect(w.toasts).toEqual([])
  expect(lastModes(w)).toEqual(['WINDING DOWN'])
})

test('a branch that cannot be read when winding down turns on is said, never read as nothing to finish (L11)', withDeps, async ($, on) => {
  const { w, clock } = world(on, { branch: '__fails' })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  expect((await stop($ as never)).block).toMatch(/what this session is working on could not be read \(fatal: not a git repository\)/)
  await clock.advance(MIN)
  expect(w.toasts).toEqual([])
  // Once it can be read, the check goes on from there.
  w.o.branch = 'scope-modes-616'
  w.o.gh = merged('OPEN')
  expect((await stop($ as never)).block).toMatch(/PR #12 is not merged yet/)
})

test('an answer from GitHub that is not what was asked for refuses the turn end rather than letting it through', withDeps, async ($, on) => {
  const { w, clock } = world(on, { gh: { ...merged(), issues: {}, garbled: true } as never })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  expect((await stop($ as never)).block).toMatch(/^Winding down is not finished: the finish check failed/)
  expect(w.toasts).toEqual([])
})

test("winding down allows the fix that blocks this issue's merge, and denies new work", withDeps, async ($, on) => {
  const { w, clock } = world(on, { gh: merged('OPEN') })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  for (const c of ['git commit -m "fix the failing check"', 'git push', 'gh pr merge 12 --squash']) expect(await call($ as never, bash(c))).toBe('ran')
  expect(await call($ as never, edit('/repo/app.ts'))).toBe('ran')
  expect(await call($ as never, { tool: 'Skill', skill: 'next-issue', tool_use_id: 'k1' } as never)).toMatch(/^Blocked: winding down, so this did not start the next issue\./)
  expect(await call($ as never, bash('git checkout -b issue-700'))).toMatch(/did not start a new branch/)
  expect(await call($ as never, { tool: 'Agent', prompt: 'Build #700', description: 'x', tool_use_id: 'a1' } as never)).toMatch(/did not dispatch an agent for issue #700/)
  expect(w.cards.map(c => c.guard)).toEqual(['Winding down', 'Winding down', 'Winding down'])
})

// ---- Winding down's target, as the milestone audit found it (#702) ----

test('turning winding down on again keeps the PR it already found, rather than reading the target afresh', withDeps, async ($, on) => {
  const { w, clock } = world(on, { gh: merged('OPEN') })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  expect((await stop($ as never)).block).toMatch(/PR #12 is not merged yet/)
  // The session is back on main now; saying the phrase again must not drop PR #12.
  w.o.branch = 'main'
  await say($ as never, 'ok, wind down now')
  await command($ as never, 'winddown')
  expect((await stop($ as never)).block).toMatch(/PR #12 is not merged yet/)
  expect(w.toasts).toEqual([])
})

test('turned on from the default branch, winding down finishes the PRs this session opened, an agent\'s included', withDeps, async ($, on) => {
  const pr31 = (state: string) => ({ number: 31, state, url: 'https://github.com/o/r/pull/31', headRefName: 'fix-31', closingIssuesReferences: [{ number: 700 }] })
  const { w, clock } = world(on, { branch: 'main', created: 'https://github.com/o/r/pull/31\n', gh: { pr: pr31('OPEN'), issues: { 700: 'OPEN' } } })
  await start($ as never, clock)
  // An agent working in a worktree the session is not in opens the PR.
  await $.tool.call({ tool: 'Bash', command: 'gh pr create --fill', tool_use_id: 'g1', agentId: 'a1' } as never)
  await command($ as never, 'winddown')
  await clock.advance(MIN)
  expect(w.toasts).toEqual([])
  expect((await stop($ as never)).block).toMatch(/^Winding down is not finished: PR #31 is not merged yet\./)
  w.o.gh = { pr: pr31('MERGED'), issues: { 700: 'CLOSED' } }
  w.o.verdict = { state: 'live', at: T0 }
  w.o.branchHere = false
  w.o.branchOnGitHub = false
  expect((await stop($ as never)).block).toBeUndefined()
  expect(w.toasts).toEqual(['Wind down finished: safe to close this session.'])
  // GitHub was asked about PR #31 in the repository its link names.
  expect(w.runs.some(r => r.join(' ') === 'gh pr view 31 --repo o/r --json number,state,url,closingIssuesReferences,headRefName')).toBe(true)
})

// #856: winding down finalizes everything the session has open. A session whose own branch PR was
// finished parked three PRs it had opened "waiting on you"; every one it opened is outstanding.
const FINALIZE = [
  /Winding down finalizes everything this session has open/,
  /every PR (it|this session) opened is merged, never left open waiting on Dan/,
  /When a decision or sign off is needed, ask Dan right then with an AskUserQuestion picker, one question at a time, and merge once he answers/,
]

test('a session whose own PR is finished is not finished while a PR it opened is still open (#856)', withDeps, async ($, on) => {
  const pr31 = (state: string) => ({ number: 31, state, url: 'https://github.com/o/r/pull/31', headRefName: 'fix-31', closingIssuesReferences: [] })
  // PR #40 is open in the same repository, opened by another session: it never holds this one.
  const pr40 = { number: 40, state: 'OPEN', url: 'https://github.com/o/r/pull/40', headRefName: 'other-40', closingIssuesReferences: [] }
  const { w, clock } = world(on, { ...cleaned, verdict: { state: 'live', at: T0 }, created: 'https://github.com/o/r/pull/12\n' })
  w.o.gh = { ...merged(), others: [pr31('OPEN'), pr40] }
  await start($ as never, clock)
  // The session opens its own branch's PR, then a second one it means to leave for Dan.
  await $.tool.call({ tool: 'Bash', command: 'gh pr create --fill', tool_use_id: 'g1' } as never)
  w.o.created = 'https://github.com/o/r/pull/31\n'
  await $.tool.call({ tool: 'Bash', command: 'gh pr create --title wording', tool_use_id: 'g2' } as never)
  await command($ as never, 'winddown')
  const block = (await stop($ as never)).block ?? ''
  expect(block).toMatch(/^Winding down is not finished: PR #31 is not merged yet\./)
  for (const want of FINALIZE) expect(block).toMatch(want)
  // The branch's own PR is read once, as the branch's, not again as one the session opened.
  expect(block).not.toMatch(/PR #12/)
  expect(w.runs.some(r => r.join(' ').startsWith('gh pr view 12 '))).toBe(false)
  await clock.advance(MIN)
  expect(w.toasts).toEqual([])
  expect(lastModes(w)).toEqual(['WINDING DOWN'])
  // Merged, it finishes; another session's open PR never held it.
  w.o.gh = { ...merged(), others: [pr31('MERGED'), pr40] }
  expect((await stop($ as never)).block).toBeUndefined()
  expect(w.toasts).toEqual(['Wind down finished: safe to close this session.'])
  expect(w.runs.some(r => r.join(' ').startsWith('gh pr view 40 '))).toBe(false)
})

// The lessons review of #857: with no link from GitHub, the branch's own PR is matched by its number
// in the session's own repository, so it is still read once.
test("the branch's own PR GitHub gave no link for is still read once, not again as one the session opened (#856)", withDeps, async ($, on) => {
  const { w, clock } = world(on, { ...cleaned, verdict: { state: 'live', at: T0 }, created: 'https://github.com/o/r/pull/12\n' })
  w.o.gh = { ...merged(), pr: { number: 12, state: 'MERGED', closingIssuesReferences: [{ number: 616 }] } }
  await start($ as never, clock)
  await $.tool.call({ tool: 'Bash', command: 'gh pr create --fill', tool_use_id: 'g1' } as never)
  await command($ as never, 'winddown')
  expect((await stop($ as never)).block).toMatch(/GitHub gave no link for PR #12/)
  expect(w.runs.some(r => r.join(' ').startsWith('gh pr view 12 '))).toBe(false)
})

test('winding down never refuses AskUserQuestion: Claude asks Dan rather than parking a PR (#856)', withDeps, async ($, on) => {
  const { w, clock } = world(on, { gh: merged('OPEN') })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  const r = await call($ as never, { tool: 'AskUserQuestion', questions: [{ question: 'Merge PR #31, the wording change?', options: [{ label: 'Merge' }, { label: 'Close it' }] }], tool_use_id: 'q1' } as never)
  expect(r).toBe('answered Yes')
  expect(w.asked).toEqual(['Merge PR #31, the wording change?'])
  expect(w.cards).toEqual([])
})

test('the winding down note, its command context and the Stop reason all say to finalize everything, asking Dan with a picker and merging (#856)', withDeps, async ($, on) => {
  const { clock } = world(on, { gh: merged('OPEN') })
  await start($ as never, clock)
  const ran = (await command($ as never, 'winddown')).context?.join('\n') ?? ''
  const note = (await say($ as never, 'carry on')).context?.join('\n') ?? ''
  const block = (await stop($ as never)).block ?? ''
  for (const [where, text] of [['command', ran], ['note', note], ['stop', block]] as const)
    for (const want of FINALIZE) expect({ where, ok: want.test(text) }).toEqual({ where, ok: true })
})

test('a PR the session opened in another repository has its branch cleanup said to be uncheckable here, never read as done (lessons review of #714)', withDeps, async ($, on) => {
  const pr = { number: 31, state: 'MERGED', url: 'https://github.com/o/other/pull/31', headRefName: 'fix-31', closingIssuesReferences: [] }
  const { w, clock } = world(on, { branch: 'main', created: 'https://github.com/o/other/pull/31\n', gh: { pr, issues: {} }, verdict: { state: 'live', at: T0 }, branchOnGitHub: false })
  await start($ as never, clock)
  await $.tool.call({ tool: 'Bash', command: 'gh pr create --repo o/other --fill', tool_use_id: 'g1', agentId: 'a1' } as never)
  await command($ as never, 'winddown')
  const block = (await stop($ as never)).block ?? ''
  expect(block).toMatch(/whether fix-31 is gone here could not be read \(PR #31 is in o\/other, whose checkout this session cannot see\)/)
  expect(block).toMatch(/whether a worktree is still on fix-31 could not be read \(PR #31 is in o\/other, whose checkout this session cannot see\)/)
  // GitHub's copy of the branch is checked in that repository.
  expect(block).not.toMatch(/gone from GitHub/)
  expect(w.runs.some(r => r.join(' ') === 'git -C /repo ls-remote --exit-code --heads https://github.com/o/other.git fix-31')).toBe(true)
  expect(w.toasts).toEqual([])
})

// The lessons review of #714 at b154bc9.
test('a PR opened through bash -lc is noted like any other', withDeps, async ($, on) => {
  const pr31 = { number: 31, state: 'OPEN', url: 'https://github.com/o/r/pull/31', headRefName: 'fix-31', closingIssuesReferences: [] }
  const { clock } = world(on, { branch: 'main', created: 'https://github.com/o/r/pull/31\n', gh: { pr: pr31, issues: {} } })
  await start($ as never, clock)
  await $.tool.call({ tool: 'Bash', command: "bash -lc 'gh pr create --fill'", tool_use_id: 'g1' } as never)
  await command($ as never, 'winddown')
  expect((await stop($ as never)).block).toMatch(/PR #31 is not merged yet/)
})

test("a session on a branch with no PR of its own still finishes the PRs it opened, as the docs say", withDeps, async ($, on) => {
  const pr31 = { number: 31, state: 'MERGED', url: 'https://github.com/o/r/pull/31', headRefName: 'fix-31', closingIssuesReferences: [] }
  const { clock } = world(on, { branch: 'feature-x', created: 'https://github.com/o/r/pull/31\n', gh: { pr: pr31, issues: {} }, verdict: { state: 'live', at: T0 } })
  await start($ as never, clock)
  await $.tool.call({ tool: 'Bash', command: 'gh pr create --fill', tool_use_id: 'g1', agentId: 'a1' } as never)
  await command($ as never, 'winddown')
  const block = (await stop($ as never)).block ?? ''
  expect(block).toMatch(/there is no PR for feature-x yet/)
  expect(block).toMatch(/the branch fix-31 still exists here/)
})

test('no build reads what a find -exec runs through a shell', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  expect(await call($ as never, bash("find src -exec sh -c 'echo x > /repo/app.ts' _ {} +"))).toMatch(/did not write to app\.ts/)
  expect(await call($ as never, bash("find src -name '*.ts' -exec wc -l {} +"))).toBe('ran')
  expect(w.reached).toEqual(["find src -name '*.ts' -exec wc -l {} +"])
})

test('a gh pr create that printed no link notes no PR; one that cannot be read to note is said', withDeps, async ($, on) => {
  const { w, clock } = world(on, { branch: 'main', created: 'Warning: 2 uncommitted changes\n' })
  await start($ as never, clock)
  await $.tool.call({ tool: 'Bash', command: 'gh pr create --fill', tool_use_id: 'g1' } as never)
  w.o.created = 'https://github.com/o/r/pull/32\n'
  await $.tool.call({ tool: 'Bash', command: 'gh pr create --title __reader_fails', tool_use_id: 'g2' } as never)
  expect(w.toasts).toEqual([expect.stringMatching(/^Scope modes could not note the PR this call opened \(.*the reader broke.*\), so winding down will not know to finish it\.$/)])
  await command($ as never, 'winddown')
  // Neither PR was noted, so on a clean default branch there is nothing to finish.
  expect((await stop($ as never)).block).toBeUndefined()
})

test('on the default branch, winding down follows the session onto the branch it moves to', withDeps, async ($, on) => {
  const { w, clock } = world(on, { branch: 'main' })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  w.o.branch = 'scope-modes-616'
  w.o.gh = merged('OPEN')
  expect((await stop($ as never)).block).toMatch(/PR #12 is not merged yet/)
})

test("an agent sent to fix this PR's merge is allowed though its prompt names the PR or the issue it closes", withDeps, async ($, on) => {
  const pr = { number: 665, state: 'OPEN', url: 'https://github.com/o/r/pull/665', headRefName: 'fix-ci', closingIssuesReferences: [{ number: 700 }] }
  const { w, clock } = world(on, { branch: 'fix-ci', gh: { pr, issues: {} } })
  await start($ as never, clock)
  await command($ as never, 'winddown')
  const agent = (prompt: string, id: string) => call($ as never, { tool: 'Agent', prompt, description: 'x', tool_use_id: id } as never)
  expect(await agent('Watch CI on PR #665 and report why it failed', 'a1')).toBe('ran')
  expect(await agent('Fix the failing check for issue #700', 'a2')).toBe('ran')
  expect(await agent('Build #701', 'a3')).toMatch(/did not dispatch an agent for issue #701/)
  expect(w.cards.map(c => c.toolUseId)).toEqual(['a3'])
})

test('the session ending turns every mode off: nothing carries into a new session', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  await command($ as never, 'away')
  await $.session.end({ sessionId: 's1', reason: 'clear' } as never)
  expect(lastModes(w)).toEqual([])
  expect(await call($ as never, edit('/repo/app.ts'))).toBe('ran')
  expect(await call($ as never, bash('open -a Preview a.pdf'))).toBe('ran')
})

// ---- Away and home (#621) ----

test('a new session starts at home: no mode, nothing added to the prompt, opening goes ahead', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  expect((await say($ as never, 'show me the report')).context).toBeUndefined()
  expect(await call($ as never, bash('open -a "Google Chrome" /tmp/report.html'))).toBe('ran')
  expect(w.modes).toEqual([])
})

test('away: Claude is told to publish pages for the phone; opening on the Mac is held, not run', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  expect((await command($ as never, 'away')).text).toBe('Away is on in this session.')
  expect(lastModes(w)).toEqual(['AWAY'])
  expect((await say($ as never, 'show me the report')).context?.join('\n')).toMatch(/Dan is away from the Mac.*private claude\.ai page/s)
  const r = await call($ as never, bash('open -a "Google Chrome" /tmp/report.html', 'o1'))
  expect(r).toMatch(/^Held: Dan is away from the Mac, so "Open report\.html in Google Chrome" waits for him to come back\./)
  expect(w.reached).toEqual([])
  expect(w.cards).toEqual([{ toolUseId: 'o1', guard: 'Away', reason: 'Held for when you are back: Open report.html in Google Chrome.', safeWay: 'Claude publishes a private page for your phone instead.' }])
  // No card while away: Dan is not at the Mac to press it.
  expect(w.bands).toEqual([])
})

test('away holds a browser opened by another tool, the Artifact open action and an AppleScript dialog, and a press replays the call (#702)', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'away')
  expect(await call($ as never, { tool: 'mcp__playwright__browser_navigate', url: 'https://x.dev/a', tool_use_id: 'p1' } as never)).toMatch(
    /^Held: Dan is away from the Mac, so "Open https:\/\/x\.dev\/a in the Playwright browser" waits for him to come back\./,
  )
  expect(await call($ as never, { tool: 'Artifact', action: 'open', url: 'https://claude.ai/artifact/abc', tool_use_id: 'p2' } as never)).toMatch(/"Open https:\/\/claude\.ai\/artifact\/abc" waits/)
  expect(await call($ as never, bash(`osascript -e 'display dialog "Done?"'`, 'p3'))).toMatch(/"Show a dialog on the Mac" waits/)
  // Publishing the page for the phone goes ahead.
  expect(await call($ as never, { tool: 'Artifact', file_path: '/tmp/p.html', tool_use_id: 'p4' } as never)).toBe('ran')
  expect(w.reached).toEqual(['/tmp/p.html'])
  expect(w.cards.map(c => c.reason)).toEqual([
    'Held for when you are back: Open https://x.dev/a in the Playwright browser.',
    'Held for when you are back: Open https://claude.ai/artifact/abc.',
    'Held for when you are back: Show a dialog on the Mac.',
  ])
  await command($ as never, 'home')
  const ui = await ($ as never as { ui: { mount: (m: object) => Promise<{ press: (t: object) => Promise<unknown>; unmount: () => Promise<void> }> } }).ui.mount({ plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false } })
  await ui.press({ key: 'scope-modes:held-1' })
  await ui.unmount()
  expect(w.prompts).toEqual([
    'Dan is back and picked this from what was held while he was away: Open https://x.dev/a in the Playwright browser. Do it now. What was held: mcp__playwright__browser_navigate {"url":"https://x.dev/a"}',
  ])
})

test('no build and away together both show, scope first', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'away')
  await command($ as never, 'nobuild')
  expect(lastModes(w)).toEqual(['NO BUILD', 'AWAY'])
})

test('a switch reaches every other open session on this Mac, and says which could not be told', withDeps, async ($, on) => {
  const { w, clock } = world(on, { open: [{ sessionId: 's2' }, { sessionId: 's3' }], sends: [true, { refused: 'the session is not running' }, { refused: 'the session is not running' }] })
  await start($ as never, clock)
  const r = await command($ as never, 'away')
  expect(w.sent).toEqual([
    { to: 's2', text: AWAY_TEXT },
    { to: 's3', text: AWAY_TEXT },
    { to: 's3', text: AWAY_TEXT },
  ])
  expect(r.text).toBe('Away is on in this session and 1 other. 1 could not be told: the session is not running.')
})

test('a registry that cannot be read is said, never read as no other session (L215)', withDeps, async ($, on) => {
  const { clock } = world(on, { unreadable: ['*'] })
  await start($ as never, clock)
  expect((await command($ as never, 'away')).text).toMatch(/^Away is on in this session\. The other sessions could not be told: the session registry could not be read/)
})

test('the switch arriving from another session is applied and taken, never shown to the model', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  const r = (await $.session.receive({ origin: { kind: 'peer', plugin: 'scope-modes' }, text: AWAY_TEXT } as never)) as { consumed?: string }
  expect(r.consumed).toBeTruthy()
  expect(lastModes(w)).toEqual(['AWAY'])
  // It does not pass the switch on again.
  expect(w.sent).toEqual([])
  const fromModel = (await $.session.receive({ origin: { kind: 'peer' }, text: AWAY_TEXT } as never)) as { consumed?: string; text?: string }
  expect(fromModel.consumed).toBeUndefined()
})

test('a message from the phone while home gets the one line at the end of the reply; not while away, not from the Mac', withDeps, async ($, on) => {
  const { clock } = world(on)
  await start($ as never, clock)
  const complete = async () => ((await $.turn.complete({ answer: 'Done.', durationMs: 1, isAborted: false, turnId: 't', reason: 'answer' } as never)) as { text: string }).text
  await say($ as never, 'how is it going', 'bridge')
  expect(await complete()).toBe(PHONE_LINE)
  await say($ as never, 'and now', 'composer')
  expect(await complete()).toBe('Done.')
  await say($ as never, 'away', 'bridge')
  expect(await complete()).toBe('Done.')
})

test('coming home: one boxed card of what was held, nothing opens until a button is pressed, which asks Claude to do that one', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'away')
  await call($ as never, bash('open -a "Google Chrome" /tmp/report.html', 'o1'))
  await call($ as never, bash('open -a "Google Chrome" /tmp/report.html', 'o2'))
  await call($ as never, bash('TARGET_APP=/Applications/Overture.app/Contents/MacOS/Overture osascript -e \'tell application "System Events" to keystroke "n"\'', 'o3'))
  const runsBefore = w.runs.length
  expect((await command($ as never, 'home')).text).toBe('Home is on in this session.')
  const card = w.bands[w.bands.length - 1] as Row
  expect(card).toMatchObject({ mod: 'scope-modes', id: 'held', slot: 'held', frame: { kind: 'box' } })
  // The same open held twice is one row.
  expect(card.lines).toEqual([
    [{ text: 'Held while you were away', color: 'warning' }],
    [{ text: 'Open report.html in Google Chrome ' }, { button: 'held-1', label: 'Open' }],
    { divider: true },
    [{ text: 'Type into Overture ' }, { button: 'held-2', label: 'Do it' }],
  ])
  // Coming home opened nothing and asked Claude for nothing.
  expect(w.prompts).toEqual([])
  expect(w.runs.slice(runsBefore).filter(r => r[0] === 'open' || r[0] === 'osascript')).toEqual([])
  expect((await say($ as never, 'hi')).context?.join('\n')).toMatch(/Dan is back at the Mac/)

  const ui = await ($ as never as { ui: { mount: (m: object) => Promise<{ press: (t: object) => Promise<unknown>; unmount: () => Promise<void> }> } }).ui.mount({ plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false } })
  await ui.press({ key: 'scope-modes:held-1' })
  expect(w.prompts.filter(p => p.startsWith('Dan is back'))).toEqual([
    'Dan is back and picked this from what was held while he was away: Open report.html in Google Chrome. Do it now. What was held: open -a "Google Chrome" /tmp/report.html',
  ])
  const after = w.bands[w.bands.length - 1] as Row
  expect(after.lines).toEqual([[{ text: 'Held while you were away', color: 'warning' }], [{ text: 'Type into Overture ' }, { button: 'held-2', label: 'Do it' }]])
  await ui.press({ key: 'scope-modes:held-2' })
  expect(w.cleared).toContain('held')
  await ui.unmount()
})

// The manual steps mod (#614), standing in: a call to HoldIt holds a step through the noun.
const holder: { name: string; register: Register } = {
  name: 'manual-steps',
  register: on => {
    // Its tool is matched in the hook, since a stand-in's tool is in no list of tools Claude Code's types name.
    on('tool.call', async ($, e, next) => {
      if (String(e.tool) !== 'HoldIt') return next(e)
      const r = await $.scopeModes.hold({ label: 'Paste the key into Stripe', prompt: 'Walk Dan through the Stripe key step.' })
      return { result: r, text: JSON.stringify(r) } as never
    })
  },
}

test('another mod holds its own item while away, and is told nothing was held at home', { plugins: [deps, isItLive, holder] }, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  const holdIt = () => call($ as never, { tool: 'HoldIt', tool_use_id: 'h' } as never)
  expect(await holdIt()).toBe('{"isHeld":false}')
  await command($ as never, 'away')
  // Held, with the refusal worded as this mod's own held actions are, for a guard that holds a call
  // (the keystroke guard, #707) to answer it with and draw the same card.
  expect(JSON.parse(await holdIt())).toEqual({
    isHeld: true,
    card: { guard: 'Away', reason: 'Held for when you are back: Paste the key into Stripe.', safeWay: 'Claude publishes a private page for your phone instead.' },
    deny: 'Held: Dan is away from the Mac, so "Paste the key into Stripe" waits for him to come back. Publish what he needs to see as a private claude.ai page instead (the Artifact tool).',
  })
  await command($ as never, 'home')
  expect((w.bands[w.bands.length - 1] as Row).lines[1]).toEqual([{ text: 'Paste the key into Stripe ' }, { button: 'held-1', label: 'Do it' }])
})

// ---- Sleep mode phase 1 (#840): the machine wide sleep record ----

const SLEEP = '/Users/x/.claude/state/sleep'
const CURRENT = `${SLEEP}/current.json`
// T0 is 7:16 PM ET on Wed Dec 31 1969, so the night is Dec 31 and sleep ends at noon ET on Jan 1,
// 17:00 UTC (EST).
const UNTIL = Date.UTC(1970, 0, 1, 17)
const recordOf = (w: { files: Record<string, string> }) => JSON.parse(w.files[CURRENT] as string) as Record<string, unknown>
const asleepRecord = (extra: Record<string, unknown> = {}) =>
  JSON.stringify({ v: 1, generation: 'g0', since: T0 - 5 * MIN, until: UNTIL, night: '1969-12-31', bootTime: BOOT, report: '/Users/x/Downloads/sleep-report-1969-12-31.md', startedBy: { sessionId: 's9', cwd: '/other' }, workers: ['s9'], placeBefore: 'home', ...extra })
const interactive = (sessionId: string): Session => ({ sessionId, extra: { 'scope-modes': { isInteractive: true } } })

// The shared merge and deploy lists (#843), as installed with the payload.
const LISTS_PATH = '/Users/x/.claude/mods/sleep-repos.json'
const listsFile = (mergeOnly: { repo: string; mergeDeploys?: boolean }[], mayDeploy: string[] = []) => JSON.stringify({ v: 1, mergeOnly, mayDeploy }, null, 2) + '\n'

test('/sleep writes the record whole, enrols the interactive sessions, and the band shows ASLEEP', withDeps, async ($, on) => {
  const { w, clock } = world(on, {
    open: [interactive('s2'), { sessionId: 's3', extra: { 'scope-modes': { isInteractive: false } } }, { sessionId: 's4' }],
    files: { [LISTS_PATH]: listsFile([{ repo: 'o/r', mergeDeploys: false }]) },
    githubRepos: { default: ['o/r'] },
  })
  await start($ as never, clock)
  const r = await command($ as never, 'sleep')
  expect(recordOf(w)).toEqual({
    v: 1,
    generation: `${T0}-s1`,
    since: T0,
    until: UNTIL,
    night: '1969-12-31',
    bootTime: BOOT,
    report: '/Users/x/Downloads/sleep-report-1969-12-31.md',
    startedBy: { sessionId: 's1', cwd: '/repo' },
    workers: ['s1', 's2'],
    placeBefore: 'home',
    repos: { mayDeploy: [], mergeOnly: [{ repo: 'o/r', mergeDeploys: false }], closed: [] },
  })
  // Written beside it and linked into place, never written straight over it; the temp file is gone.
  expect(w.fsWrites.filter(f => !f.includes('/preparing')).length).toBe(1)
  expect(w.fsWrites.filter(f => !f.includes('/preparing'))[0]).toMatch(new RegExp(`^${SLEEP}/\\.current-${T0}-s1-[a-z0-9]+\\.tmp$`))
  expect(Object.keys(w.files).sort()).toEqual([LISTS_PATH, CURRENT].sort())
  expect(lastModes(w)).toEqual(['ASLEEP'])
  expect(r.text).toBe('Sleep mode is on until 12:00 PM ET on Thu Jan 1. Enrolled to work overnight: this session and 1 other. Not enrolled: 2 sessions that are not interactive or have not said.')
})

test('/sleep run twice says when and where sleep started, and changes nothing', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'sleep')
  const first = w.files[CURRENT]
  await clock.advance(10 * MIN)
  const r = await command($ as never, 'sleep')
  expect(r.text).toBe('Sleep mode is already on: it started at 7:16 PM ET on Wed Dec 31 in /repo, and ends at 12:00 PM ET on Thu Jan 1. Nothing changed.')
  expect(w.files[CURRENT]).toBe(first)
  expect(w.fsWrites.filter(f => !f.includes('/preparing')).length).toBe(1)
})

test('/sleep started by another session, or being prepared, changes nothing', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord() } })
  await start($ as never, clock)
  expect((await command($ as never, 'sleep')).text).toMatch(/^Sleep mode is already on: it started at 7:11 PM ET on Wed Dec 31 in \/other/)
  delete w.files[CURRENT]
  w.files[`${SLEEP}/preparing`] = JSON.stringify({ owner: 's1', at: T0, nonce: 'n7' })
  expect((await command($ as never, 'sleep')).text).toBe('Sleep mode is already being prepared in session s1 since 7:16 PM ET on Wed Dec 31. Nothing changed; if that session has gone, /wake clears it.')
  // Only a marker of its own was tried, and it is gone again.
  expect(w.fsWrites.filter(f => !f.includes('/preparing'))).toEqual([])
  expect(Object.keys(w.files).filter(f => f.includes('/preparing.'))).toEqual([])
})

test('two /sleep at once: one record, and the second says it is already on', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  const [a, b] = await Promise.all([command($ as never, 'sleep'), command($ as never, 'sleep')])
  const texts = [a.text, b.text]
  expect(texts.filter(t => t?.startsWith('Sleep mode is on until')).length).toBe(1)
  // The other finds the first one's record, or its preparing marker while it is still settling the night.
  expect(texts.filter(t => /^Sleep mode is already (on|being prepared)/.test(t ?? '')).length).toBe(1)
  // Beside the record only the night's notes: no lists file here, so every repository is closed and noted (#843).
  expect(Object.keys(w.files).filter(f => !f.startsWith(`${SLEEP}/notes/`))).toEqual([CURRENT])
  // Each attempt writes its own temp file, so one attempt's cleanup never removes the other's.
  expect(new Set(w.fsWrites.filter(f => f.includes('/preparing.'))).size).toBe(2)
})

test('a record that cannot be written is said, and nothing is left behind', withDeps, async ($, on) => {
  const { w, clock } = world(on, { lnFails: 'Permission denied' })
  await start($ as never, clock)
  expect((await command($ as never, 'sleep')).text).toBe('Sleep mode did not start: the record could not be put in place (ln: /Users/x/.claude/state/sleep/current.json: Permission denied).')
  expect(Object.keys(w.files)).toEqual([])
  expect(w.modes.some(m => m.includes('ASLEEP'))).toBe(false)
})

test('/sleep refuses when this boot cannot be read, since the record could never be told apart from an old one', withDeps, async ($, on) => {
  const { w, clock } = world(on, { boot: null })
  await start($ as never, clock)
  expect((await command($ as never, 'sleep')).text).toBe("Sleep mode did not start: this boot's start could not be read (sysctl: unknown oid).")
  expect(Object.keys(w.files)).toEqual([])
})

test('a record that cannot be read reads as awake, /sleep leaves it, and /wake clears it', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: '{"v":1,' } })
  await start($ as never, clock)
  expect((await command($ as never, 'sleep')).text).toBe('A sleep record is already there but cannot be read (the sleep record is not JSON). Nothing changed; /wake clears it.')
  expect(w.modes.some(m => m.includes('ASLEEP'))).toBe(false)
  expect((await command($ as never, 'wake')).text).toBe('Sleep mode is off. Its record could not be read (the sleep record is not JSON), so where each session delivers is left as it is.')
  expect(Object.keys(w.files).filter(f => f.startsWith(`${SLEEP}/ended/`)).length).toBe(1)
  expect(w.files[CURRENT]).toBeUndefined()
})

test('/wake moves the record aside, puts every session back where it was, and a second /wake does nothing', withDeps, async ($, on) => {
  const { w, clock } = world(on, { open: [{ sessionId: 's2' }], files: { [CURRENT]: asleepRecord({ placeBefore: 'away' }) } })
  await start($ as never, clock)
  await clock.settle()
  const r = await command($ as never, 'wake')
  expect(r.text).toBe('Sleep mode is off. It began at 7:11 PM ET on Wed Dec 31. Away is on in this session and 1 other.')
  expect(w.files[CURRENT]).toBeUndefined()
  expect(Object.keys(w.files)).toEqual([`${SLEEP}/ended/${T0}-woke-s1.json`])
  expect(lastModes(w)).toEqual(['AWAY'])
  expect(w.sent).toEqual([{ to: 's2', text: AWAY_TEXT }])
  expect((await command($ as never, 'wake')).text).toBe('Sleep mode was not on.')
  expect(w.sent.length).toBe(1)
})

test('two /wake calls at once: only the one whose move succeeds acts', withDeps, async ($, on) => {
  const { w, clock } = world(on, { open: [{ sessionId: 's2' }], files: { [CURRENT]: asleepRecord() } })
  await start($ as never, clock)
  const [a, b] = await Promise.all([command($ as never, 'wake'), command($ as never, 'wake')])
  const texts = [a.text, b.text].sort()
  expect(texts[0]).toMatch(/^Sleep mode is off\./)
  expect(texts[1]).toBe('Sleep mode was already woken by another session.')
  // Every other session told once, never twice.
  expect(w.sent.length).toBe(1)
  expect(Object.keys(w.files).filter(f => f.startsWith(`${SLEEP}/ended/`)).length).toBe(1)
})

test('a move that fails for another reason leaves sleep on and says so', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord() }, mvFails: 'Operation not permitted' })
  await start($ as never, clock)
  expect((await command($ as never, 'wake')).text).toBe(`Sleep mode could not be turned off (mv: rename ${CURRENT} to ${SLEEP}/ended/${T0}-woke-s1.json: Operation not permitted). It is still on.`)
  expect(w.files[CURRENT]).toBeDefined()
})

test("Dan's own \"I'm up\" wakes it; the same words from another session do not", withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord() } })
  await start($ as never, clock)
  await say($ as never, "I'm up", 'peer')
  expect(w.files[CURRENT]).toBeDefined()
  await say($ as never, "I'm up for a quick look at the logs")
  expect(w.files[CURRENT]).toBeDefined()
  const r = await say($ as never, "ok I'm up.")
  expect(w.files[CURRENT]).toBeUndefined()
  expect(r.context?.join('\n')).toMatch(/Dan's message woke sleep mode\. Say so in one line first: "Sleep mode is off\./)
})

test('while asleep every session is quiet as away: opening on the Mac is held, though place was home', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord() } })
  await start($ as never, clock)
  expect(await call($ as never, bash('open -a Preview a.pdf'))).toMatch(/^Held: /)
  expect(w.reached).toEqual([])
  const r = await say($ as never, 'how is it going')
  expect(r.context?.join('\n')).toMatch(/Sleep mode is on until 12:00 PM ET on Thu Jan 1\. This session is not one of the overnight workers\./)
  await command($ as never, 'wake')
  expect(await call($ as never, bash('open -a Preview a.pdf', 'c2'))).toBe('ran')
})

test('the record ends by itself at noon ET: asleep a ms before, awake at noon, and the first to see it notes it and notifies once', withDeps, async ($, on) => {
  const { w, clock } = world(on, { open: [{ sessionId: 's2' }], files: { [CURRENT]: asleepRecord({ placeBefore: 'home' }) } })
  await start($ as never, clock)
  await clock.set(UNTIL - 1)
  expect(lastModes(w)).toEqual(['ASLEEP'])
  expect(await call($ as never, bash('open -a Preview a.pdf'))).toMatch(/^Held: /)
  expect(w.notified).toEqual([])
  // At noon exactly the record no longer holds for any decision, before the minute's check moves it.
  await clock.set(UNTIL)
  expect(await call($ as never, bash('open -a Preview a.pdf', 'c2'))).toBe('ran')
  // The minute's check, counted from the session's start, is the first to see it.
  const tick = T0 + Math.ceil((UNTIL - T0) / MIN) * MIN
  await clock.set(tick)
  expect(w.files[CURRENT]).toBeUndefined()
  expect(lastModes(w)).toEqual([])
  expect(w.notified).toEqual(['Sleep mode ended by itself at 12:00 PM ET on Thu Jan 1: it was past noon ET.'])
  expect(w.appended.length).toBe(1)
  expect(w.appended[0]?.file).toBe(`${SLEEP}/notes/g0.jsonl`)
  expect(JSON.parse(w.appended[0]?.line as string)).toEqual({ v: 1, kind: 'limit', at: tick, generation: 'g0', reason: 'it was past noon ET', by: 's1' })
  // Every session put back where it was before sleep.
  expect(w.sent).toEqual([{ to: 's2', text: 'Dan switched every session on this Mac to home.' }])
  await clock.advance(5 * MIN)
  expect(w.notified.length).toBe(1)
})

test('a record from another boot reads as awake, and is ended with that reason', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord({ bootTime: BOOT - 1000 }) } })
  await start($ as never, clock)
  expect(await call($ as never, bash('open -a Preview a.pdf'))).toBe('ran')
  await clock.advance(MIN)
  expect(w.files[CURRENT]).toBeUndefined()
  expect(w.notified).toEqual(['Sleep mode ended by itself at 7:17 PM ET on Wed Dec 31: the Mac restarted.'])
})

test('a notification that cannot be sent is said in the session', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord({ until: T0 }) }, notifyFails: true })
  await start($ as never, clock)
  await clock.advance(MIN)
  expect(w.toasts).toContain('Sleep mode ended by itself (it was past noon ET), but the notification could not be sent: terminal-notifier: no permission to notify')
})

test('a new sleep begun between reading the old record and moving it is put back, never ended as expired', withDeps, async ($, on) => {
  const fresh = asleepRecord({ generation: 'g1', until: UNTIL })
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord({ until: T0 + 30_000 }) }, replacedBeforeMove: fresh })
  await start($ as never, clock)
  await clock.advance(MIN)
  expect(w.files[CURRENT]).toBe(fresh)
  expect(Object.keys(w.files)).toEqual([CURRENT])
  expect(w.notified).toEqual([])
  expect(w.appended).toEqual([])
})

test('what is held while asleep is not offered until wake, and then is', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord({ placeBefore: 'home' }) } })
  await start($ as never, clock)
  expect(await call($ as never, bash('open -a Preview a.pdf'))).toMatch(/^Held: /)
  const heldRows = () => w.bands.filter(b => b.id === 'held')
  expect(heldRows()).toEqual([])
  await command($ as never, 'wake')
  expect((heldRows()[heldRows().length - 1] as Row).lines[1]).toEqual([{ text: 'Open a.pdf in Preview ' }, { button: 'held-1', label: 'Open' }])
})

test('sleep beginning takes the held card away until wake', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'away')
  await call($ as never, bash('open -a Preview a.pdf'))
  await command($ as never, 'home')
  expect(w.bands.some(b => b.id === 'held')).toBe(true)
  const cleared = w.cleared.length
  await command($ as never, 'sleep')
  expect(w.cleared.slice(cleared)).toContain('held')
})

test('with this boot unreadable, a sound record is never called broken: /sleep says what it could not read', withDeps, async ($, on) => {
  const { w, clock } = world(on, { boot: null, files: { [CURRENT]: asleepRecord() } })
  await start($ as never, clock)
  expect((await command($ as never, 'sleep')).text).toBe("Sleep mode did not start: this boot's start could not be read (sysctl: unknown oid).")
  expect(w.files[CURRENT]).toBe(asleepRecord())
})

// ---- Sleep mode phase 2 (#841): nothing asks Dan while he is asleep ----

const MERGE_Q = { tool: 'AskUserQuestion', questions: [{ question: 'Merge PR #31, the wording change?', options: [{ label: 'Merge' }, { label: 'Close it' }] }], tool_use_id: 'q1' } as never

test('while asleep a question to Dan is refused in every session, noted for the morning report, and Claude told to skip it (#841)', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord() } })
  await start($ as never, clock)
  const r = await call($ as never, MERGE_Q)
  expect(r).toBe(
    'Not asked: Dan is asleep (sleep mode), so no question reaches him tonight. The question is noted for his morning report. Leave whatever needs his answer as it is, say in your final message what is waiting on him, and carry on with work that does not need him.',
  )
  expect(w.asked).toEqual([])
  expect(w.appended.length).toBe(1)
  expect(w.appended[0]?.file).toBe(`${SLEEP}/notes/g0.jsonl`)
  expect(JSON.parse(w.appended[0]?.line as string)).toEqual({ v: 1, kind: 'question', at: T0, by: 's1', cwd: '/repo', questions: ['Merge PR #31, the wording change?'] })
  expect(w.cards).toEqual([{ toolUseId: 'q1', guard: 'Asleep', reason: 'Dan is asleep, so this question waits for his morning report.', safeWay: 'Claude carries on with work that does not need him.' }])
})

test('awake, the same question is asked, and once woken it is asked again (#841)', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord() } })
  await start($ as never, clock)
  await call($ as never, MERGE_Q)
  await command($ as never, 'wake')
  expect(await call($ as never, MERGE_Q)).toBe('answered Yes')
  expect(w.asked).toEqual(['Merge PR #31, the wording change?'])
})

test('a question that cannot be noted is still not asked, and Claude is told to carry it in its final message (#841)', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord() }, noteFails: 'sh: notes: Permission denied' })
  await start($ as never, clock)
  const r = await call($ as never, MERGE_Q)
  expect(r).toBe(
    'Not asked: Dan is asleep (sleep mode), so no question reaches him tonight. It could not be noted for his morning report (sh: notes: Permission denied), so put the question in your final message. Leave whatever needs his answer as it is, say in your final message what is waiting on him, and carry on with work that does not need him.',
  )
  expect(w.asked).toEqual([])
})

test('while asleep no build is not switched by asking Dan (#841)', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [CURRENT]: asleepRecord() } })
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  const r = await call($ as never, { tool: 'mcp__scope-modes__switch_to_build', change: 'edit app.ts', tool_use_id: 't1' } as never)
  expect(r).toBe('Dan is asleep (sleep mode), so he was not asked: no build stays on. The request is noted for his morning report.')
  expect(w.asked).toEqual([])
  expect(lastModes(w)).toEqual(['ASLEEP', 'NO BUILD'])
  expect(JSON.parse(w.appended[0]?.line as string)).toMatchObject({ kind: 'question', questions: ['Claude wants to edit app.ts. Switch to build?'] })
})

// Another mod (the goal tracker, ask before saving) asking the noun whether the Mac is asleep, and
// noting something for the morning report through it.
const asker: { name: string; register: Register } = {
  name: 'goal-tracker',
  register: on => {
    on('tool.call', async ($, e, next) => {
      if (String(e.tool) === 'AskAsleep') {
        const r = await $.scopeModes.isAsleep()
        return { result: r, text: JSON.stringify(r) } as never
      }
      if (String(e.tool) === 'NoteIt') {
        try {
          const r = await $.scopeModes.sleepNote({ kind: 'save', files: ['~/.claude/CLAUDE.md'], rule: 'Always ask first.' })
          return { result: r, text: JSON.stringify(r) } as never
        } catch (err) {
          return { result: 'threw', text: `threw: ${String((err as Error)?.message ?? err)}` } as never
        }
      }
      return next(e)
    })
  },
}

test('another mod reads whether the Mac is asleep through the noun, live, and notes for the morning only while asleep (#841)', { plugins: [deps, isItLive, asker] }, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  const ask = () => call($ as never, { tool: 'AskAsleep', tool_use_id: 'a' } as never)
  const note = () => call($ as never, { tool: 'NoteIt', tool_use_id: 'n' } as never)
  expect(await ask()).toBe('false')
  expect(await note()).toBe('{"isNoted":false}')
  expect(w.appended).toEqual([])
  w.files[CURRENT] = asleepRecord()
  expect(await ask()).toBe('true')
  expect(await note()).toBe('{"isNoted":true}')
  expect(w.appended[0]?.file).toBe(`${SLEEP}/notes/g0.jsonl`)
  expect(JSON.parse(w.appended[0]?.line as string)).toEqual({ v: 1, kind: 'save', files: ['~/.claude/CLAUDE.md'], rule: 'Always ask first.', at: T0, by: 's1' })
  // A record past its end, or one that cannot be read, is awake.
  w.files[CURRENT] = asleepRecord({ until: T0 })
  expect(await ask()).toBe('false')
  w.files[CURRENT] = 'not json'
  expect(await ask()).toBe('false')
})

test('a note the noun cannot write throws, so the caller can say so (#841)', { plugins: [deps, isItLive, asker] }, async ($, on) => {
  const { clock } = world(on, { files: { [CURRENT]: asleepRecord() }, noteFails: 'sh: notes: Permission denied' })
  await start($ as never, clock)
  expect(await call($ as never, { tool: 'NoteIt', tool_use_id: 'n' } as never)).toBe('threw: sh: notes: Permission denied')
})

// ---- Sleep mode phase 7 (#843): per repository merge and deploy lists that fail closed ----

const night = (repos: unknown) => ({ files: { [CURRENT]: asleepRecord({ repos }) } })
const closedNotes = (w: { appended: { line: string }[] }) => w.appended.map(a => JSON.parse(a.line) as Record<string, unknown>).filter(n => n.kind === 'repo-closed')
const asRegExp = (s: string) => new RegExp(s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&'))

test('a worker repository on neither list is asked about at bedtime, and the answer is saved to the shared file and holds tonight', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [LISTS_PATH]: listsFile([{ repo: 'Try-Pennie/slate', mergeDeploys: true }]) }, githubRepos: { default: ['o/r'], work: ['Try-Pennie/slate'] }, repoAnswer: 'Allowed to deploy' })
  await start($ as never, clock)
  const r = await command($ as never, 'sleep')
  expect(w.asked).toEqual(['Choose "Merge, never deploy" only if a merge there does not itself deploy. Overnight in o/r, what may Claude do?'])
  expect(JSON.parse(w.files[LISTS_PATH] as string)).toEqual({ v: 1, mergeOnly: [{ repo: 'Try-Pennie/slate', mergeDeploys: true }], mayDeploy: ['o/r'] })
  // Slate is seen only by the work account, and is found there rather than closed.
  expect(recordOf(w).repos).toEqual({ mayDeploy: ['o/r'], mergeOnly: [{ repo: 'Try-Pennie/slate', mergeDeploys: true }], closed: [] })
  expect(r.text).not.toMatch(/No merge and no deploy/)
  expect(await call($ as never, bash('npx wrangler deploy'))).toBe('ran')
  expect(await call($ as never, bash('gh pr merge 12 --squash'))).toBe('ran')
})

test('a question left unanswered for 10 minutes closes that repository for the night, says so, and notes it for the morning', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [LISTS_PATH]: listsFile([]) }, githubRepos: { default: ['o/r'] }, repoAnswer: null })
  await start($ as never, clock)
  const pending = command($ as never, 'sleep')
  await clock.advance(10 * MIN)
  const r = await pending
  expect(r.text).toMatch(/No merge and no deploy tonight in o\/r \(the question about o\/r was not answered in 10 minutes\)\.$/)
  expect(recordOf(w).repos).toEqual({ mayDeploy: [], mergeOnly: [], closed: [{ repo: 'o/r', why: 'the question about o/r was not answered in 10 minutes' }] })
  expect(closedNotes(w).map(n => n.repo)).toEqual(['o/r'])
  expect(closedNotes(w)[0]?.question).toBe('Choose "Merge, never deploy" only if a merge there does not itself deploy. Overnight in o/r, what may Claude do?')
  // The shared file is untouched: the question is asked again next time.
  expect(JSON.parse(w.files[LISTS_PATH] as string)).toEqual({ v: 1, mergeOnly: [], mayDeploy: [] })
  expect(await call($ as never, bash('gh pr merge 12 --squash'))).toMatch(
    asRegExp('Blocked overnight: this would merge a PR, and the question about o/r was not answered in 10 minutes, so tonight it neither merges nor deploys.'),
  )
  expect(await call($ as never, bash('npm run deploy'))).toMatch(/^Blocked overnight/)
  expect(w.cards[w.cards.length - 1]).toMatchObject({ guard: 'Asleep' })
  // Ordinary overnight work goes on.
  expect(await call($ as never, bash('git push -u origin fix-843'))).toBe('ran')
})

test('a lists file that is missing closes every repository, and asks nothing', withDeps, async ($, on) => {
  const { w, clock } = world(on, { githubRepos: { default: ['o/r'] } })
  await start($ as never, clock)
  const r = await command($ as never, 'sleep')
  expect(r.text).toMatch(asRegExp('Merging and deploying are off for every repository tonight: mods/sleep-repos.json is missing.'))
  expect(w.asked).toEqual([])
  expect(closedNotes(w).map(n => n.why)).toEqual(['mods/sleep-repos.json is missing'])
  expect(await call($ as never, bash('gh pr merge 12'))).toMatch(asRegExp('Blocked overnight: this would merge a PR, and mods/sleep-repos.json is missing, so tonight'))
})

test('a lists file that does not parse closes every repository, the listed ones too', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [LISTS_PATH]: '{"v":1,"mergeOnly":[{"repo":"o/r"' }, githubRepos: { default: ['o/r'] } })
  await start($ as never, clock)
  expect((await command($ as never, 'sleep')).text).toMatch(asRegExp('every repository tonight: mods/sleep-repos.json is not JSON.'))
  expect(w.asked).toEqual([])
  expect(await call($ as never, bash('gh pr merge 12'))).toMatch(asRegExp('and mods/sleep-repos.json is not JSON, so tonight it neither merges nor deploys'))
})

test('an entry GitHub does not know under any account is closed for the night', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [LISTS_PATH]: listsFile([{ repo: 'o/r', mergeDeploys: false }, { repo: 'o/typo', mergeDeploys: false }]) }, githubRepos: { default: ['o/r'], work: [] } })
  await start($ as never, clock)
  await command($ as never, 'sleep')
  const repos = recordOf(w).repos as { closed: { repo: string; why: string }[] }
  expect(repos.closed.map(c => c.repo)).toEqual(['o/typo'])
  expect(repos.closed[0]?.why).toMatch(/^GitHub does not know o\/typo under any account gh is logged in to \(GraphQL: Could not resolve/)
  expect(await call($ as never, bash('gh pr merge 3 --repo o/typo'))).toMatch(/^Blocked overnight/)
  expect(await call($ as never, bash('gh pr merge 3'))).toBe('ran')
})

test('a repository first met after sleep began is closed and noted once', withDeps, async ($, on) => {
  const { w, clock } = world(on, night({ mayDeploy: [], mergeOnly: [{ repo: 'o/other', mergeDeploys: false }], closed: [] }))
  await start($ as never, clock)
  expect(await call($ as never, bash('gh pr merge 12'))).toMatch(asRegExp('Blocked overnight: this would merge a PR, and o/r is on neither list in mods/sleep-repos.json, so tonight it neither merges nor deploys.'))
  expect(await call($ as never, bash('gh pr merge 13'))).toMatch(/^Blocked overnight/)
  expect(closedNotes(w).map(n => n.repo)).toEqual(['o/r'])
  // Its own --repo is judged by that repository's place on the lists.
  expect(await call($ as never, bash('gh pr merge 4 --repo o/other'))).toBe('ran')
})

test('a record written before this phase, with no lists, refuses every merge and deploy', withDeps, async ($, on) => {
  const { clock } = world(on, { files: { [CURRENT]: asleepRecord() } })
  await start($ as never, clock)
  expect(await call($ as never, bash('gh pr merge 12'))).toMatch(/the sleep record carries no merge and deploy lists/)
  expect(await call($ as never, bash('npx wrangler deploy'))).toMatch(/^Blocked overnight/)
  // Work that neither merges nor deploys goes on.
  expect(await call($ as never, bash('git commit -m wip'))).toBe('ran')
})

test('merge only: a repository whose merge deploys keeps its green PR open; one whose merge does not merges but never deploys', withDeps, async ($, on) => {
  const { clock } = world(on, night({ mayDeploy: [], mergeOnly: [{ repo: 'o/r', mergeDeploys: true }, { repo: 'o/quiet', mergeDeploys: false }], closed: [] }))
  await start($ as never, clock)
  expect(await call($ as never, bash('gh pr merge 12 --auto --squash'))).toMatch(
    asRegExp('Blocked overnight: this would merge a PR (auto merge), and a merge in o/r deploys, so it is never merged overnight. Leave the green PR open'),
  )
  expect(await call($ as never, bash('bash ~/.claude/hooks/lib/merge-when-ready.sh 12 --squash'))).toMatch(/^Blocked overnight/)
  expect(await call($ as never, bash('gh pr merge 5 --repo o/quiet'))).toBe('ran')
  expect(await call($ as never, bash('gh workflow run deploy.yml --repo o/quiet'))).toMatch(asRegExp('o/quiet may merge overnight but never deploy'))
})

test('a package script whose body deploys is refused where deploying is not allowed; a push to main is refused everywhere', withDeps, async ($, on) => {
  const { clock } = world(on, {
    files: {
      [CURRENT]: asleepRecord({ repos: { mayDeploy: ['o/deploys'], mergeOnly: [{ repo: 'o/r', mergeDeploys: false }], closed: [] } }),
      '/repo/package.json': JSON.stringify({ scripts: { ship: 'next build && wrangler deploy', test: 'vitest run' } }),
    },
  })
  await start($ as never, clock)
  expect(await call($ as never, bash('npm run ship'))).toMatch(asRegExp('Blocked overnight: this would run the ship script, which would deploy with wrangler, and o/r may merge overnight but never deploy.'))
  expect(await call($ as never, bash('npm test'))).toBe('ran')
  expect(await call($ as never, bash('git push origin main'))).toMatch(asRegExp('Blocked overnight: this would push main straight to GitHub, and a direct push to a default branch is never made overnight'))
  expect(await call($ as never, bash('git push origin HEAD:main'))).toMatch(/^Blocked overnight/)
  // A folder change first reaches a repository that cannot be told, which is closed (L75).
  expect(await call($ as never, bash('cd /elsewhere && gh pr merge 1'))).toMatch(/which repository this reaches could not be told/)
})

test('awake, none of this applies', withDeps, async ($, on) => {
  const { clock } = world(on)
  await start($ as never, clock)
  expect(await call($ as never, bash('gh pr merge 12'))).toBe('ran')
  expect(await call($ as never, bash('git push origin main'))).toBe('ran')
})

const PREP = `${SLEEP}/preparing`
const LOCK = `${SLEEP}/repos.lock`
const marker = (owner: string, at: number, nonce = 'old') => JSON.stringify({ owner, at, nonce })

test('the preparing marker is placed whole, naming its owner and time, and is gone once /sleep is done', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [LISTS_PATH]: listsFile([{ repo: 'o/r', mergeDeploys: false }]) }, githubRepos: { default: ['o/r'] } })
  await start($ as never, clock)
  await command($ as never, 'sleep')
  // Written beside it and linked into place: never a half written marker.
  const written = w.fsWrites.filter(f => f.startsWith(`${PREP}.`))
  expect(written.length).toBe(1)
  expect(PREP in w.files).toBe(false)
  expect(w.fileOps.some(r => r[0] === 'ln' && r[2] === PREP)).toBe(true)
})

test('a preparing marker held by a live session refuses /sleep naming it; one whose session has gone is taken over by one rename and said', withDeps, async ($, on) => {
  const { w, clock } = world(on, { open: [{ sessionId: 's2' }], files: { [LISTS_PATH]: listsFile([{ repo: 'o/r', mergeDeploys: false }]), [PREP]: marker('s2', T0) }, githubRepos: { default: ['o/r'] } })
  await start($ as never, clock)
  expect((await command($ as never, 'sleep')).text).toBe('Sleep mode is already being prepared in session s2 since 7:16 PM ET on Wed Dec 31. Nothing changed; if that session has gone, /wake clears it.')
  // s9 is in no open session: its marker is stale, moved aside in one rename, never removed then made again.
  w.files[PREP] = marker('s9', T0)
  const r = await command($ as never, 'sleep')
  expect(r.text).toMatch(/^Sleep mode is on until/)
  expect(r.text).toMatch(/A sleep left half prepared by session s9 since 7:16 PM ET on Wed Dec 31 was taken over\./)
  const moved = w.fileOps.findIndex(r => r[0] === 'mv' && r[1] === PREP)
  const linked = w.fileOps.findIndex((r, i) => i > moved && r[0] === 'ln' && r[2] === PREP)
  const removed = w.fileOps.findIndex(r => r[0] === 'rm' && r.includes(PREP))
  expect(moved).toBeGreaterThan(-1)
  expect(linked).toBeGreaterThan(moved)
  // The marker is only ever removed as this /sleep's own release, after it was linked: never rm then make.
  expect(removed).toBeGreaterThan(linked)
})

test('a preparing marker that cannot be written, or cannot be read, is said as itself', withDeps, async ($, on) => {
  const { w, clock } = world(on, { markerFails: 'Permission denied', files: { [LISTS_PATH]: listsFile([]) } })
  await start($ as never, clock)
  expect((await command($ as never, 'sleep')).text).toBe(`Sleep mode did not start: its preparing marker could not be written (ln: ${PREP}: Permission denied).`)
  expect(CURRENT in w.files).toBe(false)
  w.o.markerFails = undefined
  w.files[PREP] = 'g7'
  expect((await command($ as never, 'sleep')).text).toBe('A preparing marker is there but cannot be read (it is not JSON). Nothing changed; /wake clears it.')
  expect((await command($ as never, 'wake')).text).toBe('Sleep mode was not on. A sleep left half prepared was cleared, so /sleep can start again.')
  expect(PREP in w.files).toBe(false)
})

test('a bedtime answer is written under the answers lock: a live holder is waited on, then refused rather than written over (#843)', withDeps, async ($, on) => {
  const { w, clock } = world(on, { open: [{ sessionId: 's2' }], files: { [LISTS_PATH]: listsFile([]), [LOCK]: marker('s2', T0) }, githubRepos: { default: ['o/r'] }, repoAnswer: 'Merge, never deploy' })
  await start($ as never, clock)
  const pending = command($ as never, 'sleep')
  await clock.advance(MIN)
  const r = await pending
  expect(JSON.parse(w.files[LISTS_PATH] as string)).toEqual({ v: 1, mergeOnly: [], mayDeploy: [] })
  expect(r.text).toMatch(/the answer about o\/r was not saved: the lists are being written by session s2/)
  // The holder's lock is left as it was.
  expect(w.files[LOCK]).toBe(marker('s2', T0))
})

test('an answers lock left by a session that has gone is taken over, and the answer saved', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [LISTS_PATH]: listsFile([]), [LOCK]: marker('s9', T0) }, githubRepos: { default: ['o/r'] }, repoAnswer: 'Hold merges, never deploy' })
  await start($ as never, clock)
  await command($ as never, 'sleep')
  expect(JSON.parse(w.files[LISTS_PATH] as string).mergeOnly).toEqual([{ repo: 'o/r', mergeDeploys: true }])
  expect(LOCK in w.files).toBe(false)
  // Held merges: tonight a merge in o/r waits for the morning.
  expect(await call($ as never, bash('gh pr merge 12'))).toMatch(/a merge in o\/r deploys, so it is never merged overnight/)
})

test('a bedtime question that is dismissed or cannot be shown closes the repository and says so, never as unanswered (L11)', withDeps, async ($, on) => {
  const { w, clock } = world(on, { files: { [LISTS_PATH]: listsFile([]) }, githubRepos: { default: ['o/r'] }, repoAnswer: '__dismissed' })
  await start($ as never, clock)
  const r = await command($ as never, 'sleep')
  const closed = (recordOf(w).repos as { closed: { repo: string; why: string }[] }).closed
  expect(closed.map(c => c.repo)).toEqual(['o/r'])
  expect(closed[0]?.why).toMatch(/^the question about o\/r was dismissed or could not be asked \(.+\)$/)
  expect(r.text).not.toMatch(/not answered in 10 minutes/)
})
