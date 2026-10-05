import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'

// The three mods this one depends on, standing in (a mod cannot import another mod's files):
// mod-kit's band, card, command readers and send retry, the status bar's setModes, and the session registry's
// list. One plugin named mod-kit, so a band button it draws is pressed as mod-kit's. Each call it
// is handed comes back to the world as a transcript line the world reads (BAND, CLEAR, CARD,
// MODES); the registry asks the world for the sessions with a process.run.
type Part = { text?: string; color?: string; button?: string; label?: string }
type Line = Part[] | { divider: true }
type Row = { mod: string; id: string; slot: string; frame?: { kind: string }; lines: Line[] }
const deps: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    // mod-kit drops a heredoc's body before reading, and so does this stand-in; a command naming
    // __reader_fails stands for a reader that throws.
    const dropBodies = (cmd: string) => {
      const out: string[] = []
      let end: string | undefined
      for (const line of cmd.split('\n')) {
        if (end !== undefined) {
          if (line.trim() === end) end = undefined
          continue
        }
        out.push(line)
        end = /<<-?\s*'?"?([A-Za-z_]+)/.exec(line.replace(/<<</g, ''))?.[1]
      }
      return out.join('\n')
    }
    const read = (cmd: string): string[][] => {
      if (cmd.includes('__reader_fails')) throw new Error('the reader broke')
      return dropBodies(cmd)
        .split(/&&|;|\||\n/)
        .map(part => [...part.matchAll(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g)].map(m => m[0].replace(/"([^"]*)"|'([^']*)'/g, '$1$2')))
        .map(w => w.filter(x => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(x) || false))
        .filter(w => w.length > 0)
    }
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
      return {
        ...built,
        modkit: {
          blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
          commands: async ({ command }: { command: string }) => read(command),
          git: async ({ words }: { words: string[] }) => {
            if ((words[0] ?? '').split('/').pop() !== 'git') return undefined
            const rest = words.slice(1)
            let dir: string | undefined
            while (rest[0] === '-C') {
              dir = rest[1]
              rest.splice(0, 2)
            }
            return { sub: rest[0], args: rest.slice(1), dir }
          },
          bandRow: async (row: Row) => {
            built.ui.log('BAND ' + JSON.stringify(row))
            await built.state.set({ plugin: 'mod-kit', key: 'band' }, [...(await rows()).filter(r => !(r.mod === row.mod && r.id === row.id)), row] as never)
          },
          clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
            built.ui.log('CLEAR ' + id)
            await built.state.set({ plugin: 'mod-kit', key: 'band' }, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
          },
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
      } as never
    })
  },
}
const withDeps = { plugins: [deps, isItLive] }
const withoutIsItLive = { plugins: [deps] }

const MIN = 60_000
const T0 = 1_000_000
const SCRATCH = '/private/tmp/claude-501/-Users-x-proj/s1/scratchpad'
const AWAY_TEXT = 'Dan switched every session on this Mac to away.'
const PHONE_LINE = "You're on your phone. Reply away to switch every session."

type Session = { sessionId: string }
// The one PR GitHub holds, found by `gh pr list --head` only for its own branch (scope-modes-616
// unless headRefName says otherwise) and by `gh pr view` only by its own number.
type Gh = { pr: { number: number; state: string; url?: string; headRefName?: string; closingIssuesReferences: { number: number }[] } | null; issues: Record<number, string>; fails?: string }
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
    asked: [] as string[],
    tools: [] as string[],
  }
  const clock = mock.clock(on, { now: T0 })
  mock.env(on, { HOME: '/Users/x' })
  on('process.run', ($, e) => {
    const argv = [...e.argv]
    w.runs.push(argv)
    const [cmd, ...a] = argv
    if (cmd === '__sessions') {
      if (o.unreadable?.includes('*')) return fail(1, 'the sessions folder could not be read')
      return ok(JSON.stringify({ open: [{ sessionId: 's1' }, ...(o.open ?? [])], closed: [], unreadable: o.unreadable ?? [], selfId: 's1' }))
    }
    if (cmd === '__verdict') {
      const v = o.verdict ?? null
      return v && 'throws' in v ? fail(1, v.throws) : ok(JSON.stringify(v))
    }
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
      if (a[0] === 'pr' && a[1] === 'view') return gh.pr && a[2] === String(gh.pr.number) ? ok(JSON.stringify({ headRefName: head, ...gh.pr })) : fail(1, 'no pull requests found')
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

test('no build refuses a script fed to python or a shell by a heredoc, and reads what a shell runs through -lc (#702)', withDeps, async ($, on) => {
  const { w, clock } = world(on)
  await start($ as never, clock)
  await command($ as never, 'nobuild')
  const heredoc = await call($ as never, bash("python3 - <<'EOF'\nopen('/repo/app.ts','w').write('x')\nEOF", 'h1'))
  expect(heredoc).toMatch(/^Blocked: no build is on, so this did not run a python3 script it cannot read \(fed by a heredoc\)\. Code passed inline \(python3 -c, node -e\) is read and judged/)
  expect(await call($ as never, bash("cat <<'EOF' | sh\necho x > /repo/app.ts\nEOF"))).toMatch(/did not run a sh script it cannot read \(fed by a heredoc\)/)
  expect(await call($ as never, bash("bash -lc 'echo x > /repo/app.ts'"))).toMatch(/did not write to app\.ts/)
  expect(await call($ as never, bash("python3 -c 'print(1)'"))).toBe('ran')
  expect(w.reached).toEqual(["python3 -c 'print(1)'"])
  expect(w.cards[0]).toEqual({ toolUseId: 'h1', guard: 'No build', reason: 'No build is on, so this would not run a python3 script it cannot read (fed by a heredoc).', safeWay: 'Claude asks you: Switch to build?' })
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
    on('tool.call', { tool: 'HoldIt' }, async $ => {
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
  expect(await holdIt()).toBe('{"isHeld":true}')
  await command($ as never, 'home')
  expect((w.bands[w.bands.length - 1] as Row).lines[1]).toEqual([{ text: 'Paste the key into Stripe ' }, { button: 'held-1', label: 'Do it' }])
})
