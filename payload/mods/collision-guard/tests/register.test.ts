import { expect, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

// Stand-ins for the two mods this one depends on. An inline plugin cannot reach this file's
// variables, so the registry stand-in asks the world below for the sessions (a process.run the
// world answers) and every write it or the kit is handed comes back as a transcript line.
const deps: { name: string; register: Register } = {
  name: 'deps',
  register: on => {
    const read = (cmd: string): string[][] =>
      cmd
        .split(/&&|;|\n/)
        .map(part => [...part.matchAll(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g)].map(m => m[0].replace(/"([^"]*)"|'([^']*)'/g, '$1$2')))
        .filter(w => w.length > 0)
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
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
        },
        sessions: {
          list: async () => JSON.parse((await built.process.run(['__sessions'])).stdout),
          noteEdit: async ({ path }: { path: string }) => built.ui.log('EDIT ' + path),
          setExtra: async () => undefined,
        },
      }
    })
  },
}
const withDeps = { plugins: [deps] }

const rec = (id: string, over: Record<string, unknown> = {}) => ({
  v: 1,
  sessionId: id,
  cwd: '/repo',
  repoRoot: '/repo',
  startedAt: 0,
  lastSeen: 0,
  closedAt: null,
  transcriptPath: `/t/${id}.jsonl`,
  edits: [],
  extra: {},
  ...over,
})

type Judge = string | 'no-answer'
// Each send's outcome in turn: delivered, refused with this reason, or a throw.
type Send = true | { refused: string } | 'throws'
type Opts = { open?: unknown[]; unreadable?: string[]; judge?: Judge; repo?: string; sends?: Send[]; tail?: 'fails' | 'no-request' }

const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })

// The Mac and the model beneath the guard. Everything that gets past it, every question put to the
// judge, every message sent and every card and toast is recorded.
const world = (on: On, o: Opts = {}) => {
  const w = { reached: [] as string[], prompts: [] as { model: string; prompt: string }[], sent: [] as { to: unknown; text: string }[], toasts: [] as string[], cards: [] as Record<string, unknown>[], edits: [] as string[] }
  on('process.run', ($, e) => {
    const [cmd, ...args] = e.argv
    if (cmd === '__sessions') return ok(JSON.stringify({ open: [rec('me'), ...(o.open ?? [])], closed: [], unreadable: o.unreadable ?? [], selfId: 'me' }))
    if (cmd === 'tail' && o.tail === 'fails') return { value: { exitCode: 1, stdout: '', stderr: 'Permission denied', isStdoutTruncated: false, isStderrTruncated: false } }
    if (cmd === 'tail' && o.tail === 'no-request') return ok(JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: 'hi' } }) + '\n')
    if (cmd === 'tail') {
      const user = { type: 'user', message: { role: 'user', content: 'restyle the invoice table' } }
      return ok(JSON.stringify(user) + '\n')
    }
    if (cmd === 'git' && args.includes('rev-parse')) return ok((o.repo ?? '/repo') + '\n')
    if (cmd === 'git' && args.includes('status')) return ok(' M src/InvoiceTable.tsx\n')
    if (cmd === 'git' && args.includes('branch')) return ok('main\n')
    return { value: { exitCode: 1, stdout: '', stderr: 'unexpected', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('model.complete', ($, e) => {
    const req = e as unknown as { model: string; prompt: string }
    w.prompts.push({ model: req.model, prompt: req.prompt })
    if (o.judge === 'no-answer') return { value: { isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage: {} } } as never
    return { value: { isAnswered: true, text: o.judge ?? '{"verdict":"Proceed","reason":"They only read it."}', usage: {} } } as never
  })
  let sends = 0
  on('session.send', ($, e) => {
    w.sent.push(e as never)
    const outcome = o.sends?.[sends++] ?? true
    if (outcome === 'throws') throw new Error('the session has ended')
    if (outcome === true) return { isDelivered: true } as never
    return { isDelivered: false, reason: outcome.refused } as never
  })
  on('session.cwd', () => ({ value: '/repo' }) as never)
  on('ui.toast', ($, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    if (e.text.startsWith('CARD ')) w.cards.push(JSON.parse(e.text.slice(5)))
    if (e.text.startsWith('EDIT ')) w.edits.push(e.text.slice(5))
    return { value: undefined }
  })
  on('clock.after', () => ({ value: undefined }) as never)
  on('tool.call', ($, e) => {
    w.reached.push(e.tool)
    return { result: 'ran', text: 'ran' } as never
  })
  return w
}

const edit = (path: string, id = 'c1') => ({ tool: 'Edit', file_path: path, old_string: 'a', new_string: 'b', tool_use_id: id }) as never
const bash = (command: string, id = 'c1') => ({ tool: 'Bash', command, tool_use_id: id }) as never
const refusal = (r: unknown) => {
  const x = r as { deny?: string; text?: string }
  return x.deny ?? x.text ?? ''
}

test('an edit nobody else is making goes through and is noted for the others', withDeps, async ($, on) => {
  const w = world(on)
  await $.tool.call(edit('/repo/src/a.ts'))
  expect(w.reached).toContain('Edit')
  expect(w.prompts.length).toBe(0)
  expect(w.edits).toEqual(['/repo/src/a.ts'])
})

test('an edit another open session made first is judged, and a Proceed goes through with a toast', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx'] })] })
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx'))
  expect(w.reached).toContain('Edit')
  expect(w.prompts[0]?.model).toBe('claude-sonnet-5-5')
  // The judge sees what the other session was last asked, read from its transcript.
  expect(w.prompts[0]?.prompt).toContain('restyle the invoice table')
  expect(w.prompts[0]?.prompt).toContain('/repo/src/InvoiceTable.tsx')
  expect(w.toasts).toContain('Checked with the other session: safe to edit InvoiceTable.tsx.')
})

test('a Worktree verdict blocks with the card and tells the other session', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx'] })], judge: '{"verdict":"Worktree","reason":"Both change the header row."}' })
  const r = await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'wt1'))
  expect(w.reached).not.toContain('Edit')
  expect(refusal(r)).toBe(
    'Blocked: Another session is working on InvoiceTable.tsx. Both change the header row. Move this work to its own worktree and redo it there.',
  )
  expect(w.cards).toEqual([
    {
      toolUseId: 'wt1',
      guard: 'Collision guard',
      reason: 'Another session is working on InvoiceTable.tsx. Both change the header row.',
      safeWay: 'Move this work to its own worktree and redo it there.',
    },
  ])
  // The engine sends to the session by its id, stamped as coming from this mod.
  expect(w.sent).toEqual([
    {
      to: 'them',
      text: 'Another session wanted to edit src/InvoiceTable.tsx while you are working on it, so it was moved to its own worktree to redo its change there. Nothing here was touched.',
      origin: { kind: 'plugin', name: 'collision-guard' },
    },
  ])
})

test('a Stop verdict blocks with the card and tells the other session', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx'] })], judge: '{"verdict":"Stop","reason":"They are mid rebase."}' })
  const r = await $.tool.call(edit('/repo/src/InvoiceTable.tsx'))
  expect(refusal(r)).toBe('Blocked: Another session is working on InvoiceTable.tsx. They are mid rebase. Leave it to the other session, or ask Dan.')
  expect(w.sent[0]?.text).toBe('Another session wanted to edit src/InvoiceTable.tsx while you are working on it, so it was stopped. Nothing here was touched.')
})

test('a judge that cannot answer stops the edit (the spec, L42)', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/src/a.ts'] })], judge: 'no-answer' })
  const r = await $.tool.call(edit('/repo/src/a.ts'))
  expect(w.reached).not.toContain('Edit')
  expect(refusal(r)).toBe("Blocked: Couldn't check with the other session's work, so this was stopped. Try again, or ask Dan.")
})

test('a verdict that cannot be read stops the edit too', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/src/a.ts'] })], judge: 'Sure, go ahead.' })
  await $.tool.call(edit('/repo/src/a.ts'))
  expect(w.reached).not.toContain('Edit')
})

test('a record that cannot be read stops a watched action and names it (Dan, 2026-10-03)', withDeps, async ($, on) => {
  const w = world(on, { unreadable: ['abc.json'] })
  const r = await $.tool.call(edit('/repo/src/a.ts'))
  expect(w.reached).not.toContain('Edit')
  expect(refusal(r)).toBe(
    "Blocked: Couldn't read another session's record (abc.json), so this was stopped. Delete the damaged file in ~/.claude/state/sessions, or ask Dan.",
  )
})

test('a branch switch in a checkout another session works in is judged', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them')], judge: '{"verdict":"Stop","reason":"They have uncommitted work."}' })
  const r = await $.tool.call(bash('git checkout main'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe('Blocked: Another session is working in this checkout. They have uncommitted work. Leave it to the other session, or ask Dan.')
  expect(w.sent[0]?.text).toBe('Another session wanted to run git checkout main in this checkout while you are working in it, so it was stopped. Nothing here was touched.')
})

test('a branch switch with nobody else in the checkout goes through unjudged', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('elsewhere', { repoRoot: '/other' })] })
  await $.tool.call(bash('git checkout main'))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
})

test('a git -C into another checkout is judged against that checkout', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { repoRoot: '/other' })], repo: '/other' })
  await $.tool.call(bash('git -C /other reset --hard origin/main'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('git reset --hard origin/main')
})

test('an ordinary git command is not judged', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them')] })
  await $.tool.call(bash('git status'))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
})

// The live check of #639 (2026-10-04): a guard message delivered to an interactive session arrived
// with origin { kind: 'peer', plugin: 'collision-guard', name: <the sending session's own name> }.
// So the plugin field names the guard, and `name` is a session name anybody could choose.
const MEASURED = { kind: 'peer', from: 'uds:/tmp/cc-socks/2012.sock', plugin: 'collision-guard', name: 'collision-throwaway-1004' }

test('the session that was working first gets a toast when it hears from the guard', withDeps, async ($, on) => {
  const w = world(on)
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.session.receive({
    origin: MEASURED,
    text: 'Another session wanted to edit src/app.ts while you are working on it, so it was moved to its own worktree to redo its change there. Nothing here was touched.',
  } as never)
  expect(w.toasts).toContain('Another session wanted app.ts; it was moved to a worktree.')
})

test('a checkout wide action names the command in the toast, as delivered live', withDeps, async ($, on) => {
  const w = world(on)
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.session.receive({
    origin: MEASURED,
    text: 'Another session wanted to run git switch -c window-two in this checkout while you are working in it, so it was moved to its own worktree to redo its change there. Nothing here was touched.',
  } as never)
  expect(w.toasts).toContain('Another session wanted git switch -c window-two; it was moved to a worktree.')
})

test('a session that merely calls itself collision-guard is not taken for the guard', withDeps, async ($, on) => {
  const w = world(on)
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.session.receive({
    origin: { kind: 'peer', name: 'collision-guard' },
    text: 'Another session wanted to run git checkout main in this checkout while you are working in it, so it was stopped. Nothing here was touched.',
  } as never)
  expect(w.toasts).toEqual([])
})

const clash = (over: Opts = {}) => ({ open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx'] })], judge: '{"verdict":"Worktree","reason":"Both change the header row."}', ...over })

// The live check of #605 (2026-10-04): the message to the other session was refused (auto mode's
// classifier gave no verdict) and nothing said so. Decided with Dan: retry once, then say it on the card.
test('a send refused once is tried again, and a second try that lands says nothing more', withDeps, async ($, on) => {
  const w = world(on, clash({ sends: [{ refused: 'Classifier unavailable' }, true] }))
  const r = await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'wt2'))
  expect(w.sent.length).toBe(2)
  expect(w.cards[0]?.note).toBeUndefined()
  expect(refusal(r)).not.toContain('could not be told')
})

test('a send refused twice is said on the card and in the refusal Claude reads', withDeps, async ($, on) => {
  const w = world(on, clash({ sends: [{ refused: 'Classifier unavailable' }, { refused: 'Classifier unavailable' }] }))
  const r = await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'wt3'))
  expect(w.sent.length).toBe(2)
  expect(w.reached).not.toContain('Edit')
  expect(w.cards[0]?.note).toBe('The other session could not be told: Classifier unavailable.')
  expect(refusal(r)).toBe(
    'Blocked: Another session is working on InvoiceTable.tsx. Both change the header row. Move this work to its own worktree and redo it there. The other session could not be told: Classifier unavailable.',
  )
})

test('a send that throws is not tried again, since it may have landed, and is said with the error', withDeps, async ($, on) => {
  const w = world(on, clash({ sends: ['throws', true] }))
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'wt4'))
  expect(w.sent.length).toBe(1)
  // The engine turns a throwing hook into its own error, so that is the text that arrives here.
  expect(w.cards[0]?.note).toBe('The other session could not be told: no implementation for session.send.')
})

test('a session whose transcript was not found is told to the judge as such', withDeps, async ($, on) => {
  const w = world(on, clash({ open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx'], transcriptPath: null })] }))
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx'))
  expect(w.prompts[0]?.prompt).toContain('Its latest request: (its transcript could not be found)')
})

test('a transcript that cannot be read is told to the judge as unreadable', withDeps, async ($, on) => {
  const w = world(on, clash({ tail: 'fails' }))
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx'))
  expect(w.prompts[0]?.prompt).toContain('Its latest request: (its transcript could not be read)')
})

test('a transcript with no request in it is told to the judge as such', withDeps, async ($, on) => {
  const w = world(on, clash({ tail: 'no-request' }))
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx'))
  expect(w.prompts[0]?.prompt).toContain('Its latest request: (none in its transcript)')
})
