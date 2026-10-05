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
// How the call fares beneath the guard: it runs (the default), it runs and fails, or a later guard
// refuses it.
type Ran = 'ok' | 'error' | { deny: string }
type Opts = { self?: Record<string, unknown>; open?: unknown[]; unreadable?: string[]; judge?: Judge; repo?: string; sends?: Send[]; tail?: 'fails' | 'no-request'; ran?: Ran; gits?: Record<string, 'dir' | 'file'>; tmpdir?: string }

const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })

// The Mac and the model beneath the guard. Everything that gets past it, every question put to the
// judge, every message sent and every card and toast is recorded.
const world = (on: On, o: Opts = {}) => {
  const w = { reached: [] as string[], prompts: [] as { model: string; prompt: string }[], sent: [] as { to: unknown; text: string }[], toasts: [] as string[], cards: [] as Record<string, unknown>[], edits: [] as string[], runs: [] as string[] }
  on('process.run', ($, e) => {
    w.runs.push(e.argv.join(' '))
    const [cmd, ...args] = e.argv
    if (cmd === '__sessions') return ok(JSON.stringify({ open: [rec('me', o.self), ...(o.open ?? [])], closed: [], unreadable: o.unreadable ?? [], selfId: 'me' }))
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
  // The .git entries on the disk, a folder or a linked worktree's file; anything else is no entry.
  const gits = o.gits
  if (gits) {
    on('fs.stat', ($, e) => {
      const kind = gits[(e as unknown as { path: string }).path] ?? 'other'
      return { value: { kind, size: 0, mtimeMs: 0, isLink: false } } as never
    })
  }
  const tmpdir = o.tmpdir
  if (tmpdir) on('env.get', ($, e) => ({ value: (e as unknown as { name: string }).name === 'TMPDIR' ? tmpdir : undefined }) as never)
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
    if (typeof o.ran === 'object') return { deny: o.ran.deny } as never
    w.reached.push(e.tool)
    if (o.ran === 'error') return { result: 'exit status 1', text: 'exit status 1', isError: true } as never
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
      text: 'Another session wanted to edit "src/InvoiceTable.tsx" while you are working on it, so it was moved to its own worktree to redo its change there. Nothing here was touched.',
      origin: { kind: 'plugin', name: 'collision-guard' },
    },
  ])
})

test('a Stop verdict blocks with the card and tells the other session', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx'] })], judge: '{"verdict":"Stop","reason":"They are mid rebase."}' })
  const r = await $.tool.call(edit('/repo/src/InvoiceTable.tsx'))
  expect(refusal(r)).toBe('Blocked: Another session is working on InvoiceTable.tsx. They are mid rebase. Leave it to the other session, or ask Dan.')
  expect(w.sent[0]?.text).toBe('Another session wanted to edit "src/InvoiceTable.tsx" while you are working on it, so it was stopped. Nothing here was touched.')
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

test('the session that was working first gets a toast when it hears from the guard, in the shape the live check delivered before #700', withDeps, async ($, on) => {
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

// #654: in the live check of #639 a session appended to a file with printf, its record kept no
// edits, and a second session editing that file would not have been judged.
test("the live check's printf append is noted as this session's edit, unjudged with nobody else on it", withDeps, async ($, on) => {
  const w = world(on)
  await $.tool.call(bash(`printf 'one more line\\n' >> notes.txt`))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('a shell write to a file another open session edited is judged like an edit, and a Stop blocks it', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: '{"verdict":"Stop","reason":"They are rewriting the notes."}' })
  const r = await $.tool.call(bash('echo done >> notes.txt', 'sh1'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts[0]?.prompt).toContain('/repo/notes.txt')
  expect(w.prompts[0]?.prompt).toContain('echo done >> notes.txt')
  expect(refusal(r)).toBe('Blocked: Another session is working on notes.txt. They are rewriting the notes. Leave it to the other session, or ask Dan.')
  expect(w.cards[0]?.toolUseId).toBe('sh1')
  expect(w.sent[0]?.text).toBe('Another session wanted to edit "notes.txt" while you are working on it, so it was stopped. Nothing here was touched.')
  // Blocked, so it wrote nothing and is not noted.
  expect(w.edits).toEqual([])
})

// The decided rule (docs/mods-design.md, #654), pinned for #700: a command that ran is recorded even
// when it failed, since it may have written before it failed; only a refusal, a later guard's
// included, leaves the record alone.
test('a shell write whose command failed is still noted, since it may have written first', withDeps, async ($, on) => {
  const w = world(on, { ran: 'error' })
  const r = await $.tool.call(bash('printf x >> notes.txt; false'))
  expect(w.reached).toContain('Bash')
  expect((r as { isError?: boolean }).isError).toBe(true)
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

// A refusal from Claude Code's own permission step comes after the guard has judged, the one
// refusal it cannot wait for (#707: every guard's refusal comes first, tested below).
test('a shell write refused after it was judged, by the permission step, is not noted, and the refusal is passed on', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], ran: { deny: 'Permission to use Bash was denied.' } })
  const r = await $.tool.call(bash('echo x >> notes.txt'))
  expect(w.toasts).toContain('Checked with the other session: safe to edit notes.txt.')
  expect(refusal(r)).toBe('Permission to use Bash was denied.')
  expect(w.edits).toEqual([])
})

test('a shell write judged Proceed goes through with the toast and is noted', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash('sed -i "" s/a/b/ notes.txt'))
  expect(w.reached).toContain('Bash')
  expect(w.toasts).toContain('Checked with the other session: safe to edit notes.txt.')
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('a read only command on a file another session edited is neither judged nor noted', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash('cat notes.txt'))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
  expect(w.edits).toEqual([])
})

// Decided (docs/mods-design.md, #654): a write the command reader cannot see is not guessed at.
test('a script that writes the file is not seen, so it is neither judged nor noted', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash(`python3 -c "open('notes.txt','a').write('x')"`))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
  expect(w.edits).toEqual([])
})

test('a cp into a folder writes the file of the same name inside it', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/docs/notes.txt'] })] })
  on('fs.stat', ($, e) => ({ value: { kind: (e as unknown as { path: string }).path === '/repo/docs' ? 'dir' : 'other', size: 0, mtimeMs: 0, isLink: false } }) as never)
  await $.tool.call(bash('cp /tmp/notes.txt docs'))
  expect(w.prompts[0]?.prompt).toContain('/repo/docs/notes.txt')
  expect(w.edits).toEqual(['/repo/docs/notes.txt'])
})

test('a cp onto a path that cannot be looked at is taken as that file', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash('cp /tmp/x.txt notes.txt'))
  expect(w.prompts.length).toBe(1)
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('a shell write with a record that cannot be read is stopped, as an edit is', withDeps, async ($, on) => {
  const w = world(on, { unreadable: ['abc.json'] })
  const r = await $.tool.call(bash('echo x > notes.txt'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toContain("Couldn't read another session's record (abc.json)")
  expect(w.edits).toEqual([])
})

test('a shell write the judge cannot answer is stopped (L42)', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: 'no-answer' })
  const r = await $.tool.call(bash('echo x > notes.txt'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe("Blocked: Couldn't check with the other session's work, so this was stopped. Try again, or ask Dan.")
})

// #674: rm takes away a file another session is working on, the most destructive write there is.
test('an rm of a file another open session edited is judged, and a Stop blocks it with the card and the message', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: '{"verdict":"Stop","reason":"They are still writing it."}' })
  const r = await $.tool.call(bash('rm notes.txt', 'rm1'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts[0]?.prompt).toContain('remove /repo/notes.txt with the shell command: rm notes.txt')
  expect(refusal(r)).toBe('Blocked: Another session is working on notes.txt. They are still writing it. Leave it to the other session, or ask Dan.')
  expect(w.cards[0]?.toolUseId).toBe('rm1')
  // Dan, 2026-10-04 (#700): a removal says remove, where #674 had kept the edit words.
  expect(w.sent[0]?.text).toBe('Another session wanted to remove "notes.txt" while you are working on it, so it was stopped. Nothing here was touched.')
  expect(w.edits).toEqual([])
})

test('an rm of a file another open session edited, judged Proceed, says safe to remove', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash('unlink notes.txt'))
  expect(w.toasts).toEqual(['Checked with the other session: safe to remove notes.txt.'])
  expect(w.reached).toContain('Bash')
})

test('an rm of a file nobody else edited goes through unjudged and is noted', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/other.txt'] })] })
  await $.tool.call(bash('rm -f old.txt'))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
  expect(w.edits).toEqual(['/repo/old.txt'])
})

test('an rm -r of a folder holding a file another session edited is judged on that file', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/src/deep/InvoiceTable.tsx', '/repo/README.md'] })] })
  await $.tool.call(bash('rm -rf src'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('remove /repo/src and everything in it, including /repo/src/deep/InvoiceTable.tsx, with the shell command: rm -rf src')
  expect(w.toasts).toContain('Checked with the other session: safe to remove InvoiceTable.tsx.')
  expect(w.reached).toContain('Bash')
  expect(w.edits).toEqual(['/repo/src'])
})

test('an mv of a folder holding a file another session edited is judged on that file', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/src/a.ts'] })], judge: '{"verdict":"Stop","reason":"They are editing it."}' })
  const r = await $.tool.call(bash('mv src /tmp/old-src'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts[0]?.prompt).toContain('remove /repo/src and everything in it, including /repo/src/a.ts, with the shell command: mv src /tmp/old-src')
  expect(refusal(r)).toContain('Another session is working on a.ts.')
  expect(w.sent[0]?.text).toBe('Another session wanted to remove "src/a.ts" while you are working on it, so it was stopped. Nothing here was touched.')
})

test('a folder copied in and then removed in one command keeps the removal (lessons review of #691)', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/docs/sub/a.ts'] })] })
  on('fs.stat', ($, e) => ({ value: { kind: (e as unknown as { path: string }).path === '/repo/docs' ? 'dir' : 'other', size: 0, mtimeMs: 0, isLink: false } }) as never)
  await $.tool.call(bash('cp -r /tmp/sub docs; rm -r docs/sub'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('remove /repo/docs/sub and everything in it, including /repo/docs/sub/a.ts,')
})

// #700, the comment on it: a cp into an existing folder was turned into the file inside it, and a
// later rm -r of that same folder lost its removal, so another session's files there were never judged.
test('a copy into a folder that is then removed in one command keeps the removal of the folder', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/docs/b.ts'] })], judge: '{"verdict":"Stop","reason":"They are editing it."}' })
  on('fs.stat', ($, e) => ({ value: { kind: (e as unknown as { path: string }).path === '/repo/docs' ? 'dir' : 'other', size: 0, mtimeMs: 0, isLink: false } }) as never)
  const r = await $.tool.call(bash('cp /tmp/a.ts docs; rm -r docs'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('remove /repo/docs and everything in it, including /repo/docs/b.ts, with the shell command:')
  expect(refusal(r)).toContain('Another session is working on b.ts.')
})

test('a file written and then removed as a folder in one command is judged as the folder', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/d/x.ts'] })] })
  await $.tool.call(bash('echo > d; rm -r d'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('remove /repo/d and everything in it, including /repo/d/x.ts,')
})

// The coordinator on #691: a folder removal is judged once, naming every affected file, with one
// message to each other session naming its own files, never one judgment and toast per file.
test('an rm -r of a folder holding several edited files is judged once, with one message per other session', withDeps, async ($, on) => {
  const w = world(on, {
    open: [rec('one', { edits: ['/repo/src/a.ts', '/repo/src/b.ts', '/repo/lib/x.ts'] }), rec('two', { edits: ['/repo/src/c.ts'] })],
    judge: '{"verdict":"Stop","reason":"Both are mid change."}',
  })
  const r = await $.tool.call(bash('rm -rf src'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('remove /repo/src and everything in it, including /repo/src/a.ts, /repo/src/b.ts, /repo/src/c.ts, with the shell command: rm -rf src')
  expect(w.cards.length).toBe(1)
  expect(refusal(r)).toBe('Blocked: Another session is working on 3 files in src. Both are mid change. Leave it to the other session, or ask Dan.')
  expect(w.sent.map(s => [s.to, s.text])).toEqual([
    ['one', 'Another session wanted to remove "src/a.ts", "src/b.ts" while you are working on it, so it was stopped. Nothing here was touched.'],
    ['two', 'Another session wanted to remove "src/c.ts" while you are working on it, so it was stopped. Nothing here was touched.'],
  ])
})

test('a folder removal judged Proceed is one toast however many files it holds', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('one', { edits: ['/repo/src/a.ts', '/repo/src/b.ts'] })] })
  await $.tool.call(bash('rm -rf src'))
  expect(w.prompts.length).toBe(1)
  expect(w.toasts).toEqual(['Checked with the other session: safe to remove 2 files in src.'])
  expect(w.reached).toContain('Bash')
})

test('a removal naming several files is told in one toast with each file name, saying remove', withDeps, async ($, on) => {
  const w = world(on)
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.session.receive({
    origin: MEASURED,
    text: 'Another session wanted to remove "src/a.ts", "src/b.ts" while you are working on it, so it was stopped. Nothing here was touched.',
  } as never)
  expect(w.toasts).toEqual(['Another session wanted to remove a.ts, b.ts; it was stopped.'])
})

// #700: the message names a path relative to the other session's repository, or the whole path
// when that is not known, and Dan's folders carry spaces and a curly apostrophe.
const SPACED = '/Users/dan/Documents/Documents - Dan\u2019s MacBook Pro'

test('a whole path with spaces and a curly apostrophe is named in the toast, sent and heard', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { repoRoot: null, cwd: SPACED, edits: [`${SPACED}/app.ts`] })], judge: '{"verdict":"Stop","reason":"They are mid change."}' })
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.tool.call(edit(`${SPACED}/app.ts`))
  const text = w.sent[0]?.text as string
  expect(text).toBe(`Another session wanted to edit "${SPACED}/app.ts" while you are working on it, so it was stopped. Nothing here was touched.`)
  await $.session.receive({ origin: MEASURED, text } as never)
  expect(w.toasts).toEqual(['Another session wanted app.ts; it was stopped.'])
})

test('a removal of a whole path with spaces is named in the toast too', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { repoRoot: null, cwd: SPACED, edits: [`${SPACED}/app.ts`] })], judge: '{"verdict":"Worktree","reason":"They are mid change."}' })
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.tool.call(bash(`rm '${SPACED}/app.ts'`))
  await $.session.receive({ origin: MEASURED, text: w.sent[0]?.text as string } as never)
  expect(w.toasts).toEqual(['Another session wanted to remove app.ts; it was moved to a worktree.'])
})

// #700, the finding Dan folded in: the list was split on comma space, so "Notes, draft.md" read as
// two files. Each name is now quoted in the message and read back whole.
test('a removal naming a file with a comma in it and one under spaces is sent and heard with each name whole', withDeps, async ($, on) => {
  const w = world(on, {
    open: [rec('them', { repoRoot: null, cwd: SPACED, edits: [`${SPACED}/Notes, draft.md`, `${SPACED}/app.ts`] })],
    judge: '{"verdict":"Stop","reason":"They are mid change."}',
  })
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.tool.call(bash(`rm -r '${SPACED}'`))
  const text = w.sent[0]?.text as string
  expect(text).toBe(`Another session wanted to remove "${SPACED}/Notes, draft.md", "${SPACED}/app.ts" while you are working on it, so it was stopped. Nothing here was touched.`)
  await $.session.receive({ origin: MEASURED, text } as never)
  expect(w.toasts).toEqual(['Another session wanted to remove "Notes, draft.md", app.ts; it was stopped.'])
})

test('an rm -r of a folder the judge cannot answer for is stopped (L42)', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/src/a.ts'] })], judge: 'no-answer' })
  const r = await $.tool.call(bash('rm -r src/'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe("Blocked: Couldn't check with the other session's work, so this was stopped. Try again, or ask Dan.")
  expect(w.edits).toEqual([])
})

test('an rm -r with a record that cannot be read is stopped', withDeps, async ($, on) => {
  const w = world(on, { unreadable: ['abc.json'] })
  const r = await $.tool.call(bash('rm -r src'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toContain("Couldn't read another session's record (abc.json)")
})

// #674: scratch outside the repository is not a session's edit, so it cannot push real edits out of
// the twenty the judge reads, nor raise a check between sessions sharing scratch space.
test('a shell write to /tmp or the scratchpad runs and is not noted, while one in the repository is', withDeps, async ($, on) => {
  const w = world(on)
  await $.tool.call(bash('echo x > /tmp/out.txt && echo y > /private/tmp/claude-501/s/scratchpad/674/n.md && echo z >> notes.txt'))
  expect(w.reached).toContain('Bash')
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('an Edit or Write outside the repository is not noted either', withDeps, async ($, on) => {
  const w = world(on)
  await $.tool.call(edit('/private/tmp/claude-501/s/scratchpad/674/pr-body.md'))
  expect(w.reached).toContain('Edit')
  expect(w.edits).toEqual([])
})

test('a session outside any repository takes its own folder as the root', withDeps, async ($, on) => {
  const w = world(on, { self: { repoRoot: null, cwd: '/repo' } })
  await $.tool.call(bash('echo x > /tmp/out.txt; echo z >> notes.txt'))
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('a scratch file another session recorded before this change is still judged, and not noted here', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/tmp/shared.txt'] })] })
  await $.tool.call(bash('echo x > /tmp/shared.txt'))
  expect(w.prompts.length).toBe(1)
  expect(w.edits).toEqual([])
})

// Dan, 2026-10-04 (#700): #674 recorded only paths inside the session's own root, which also dropped
// a file edited in another checkout, so a session working there was never judged against it.
test('an edit to a file in another checkout is recorded, found by its .git rather than by asking git', withDeps, async ($, on) => {
  const w = world(on, { gits: { '/other/.git': 'dir' } })
  await $.tool.call(edit('/other/src/a.ts'))
  expect(w.edits).toEqual(['/other/src/a.ts'])
  expect(w.runs.filter(r => r.includes('/other'))).toEqual([])
})

test('a shell write into a linked worktree, whose .git is a file, is recorded', withDeps, async ($, on) => {
  const w = world(on, { gits: { '/wt/feature/.git': 'file' } })
  await $.tool.call(bash('echo x >> /wt/feature/notes.txt'))
  expect(w.edits).toEqual(['/wt/feature/notes.txt'])
})

test('scratch is still left out, a checkout inside it included, and so is a path in no checkout', withDeps, async ($, on) => {
  const w = world(on, {
    gits: { '/tmp/clone/.git': 'dir', '/private/tmp/claude-501/s/scratchpad/700/.git': 'dir', '/Volumes/fast/tmp/clone/.git': 'dir' },
    tmpdir: '/Volumes/fast/tmp/',
  })
  await $.tool.call(bash('echo a > /tmp/clone/x.txt; echo b > /private/tmp/claude-501/s/scratchpad/700/n.md; echo c > /Volumes/fast/tmp/clone/y.txt; echo d > /Users/dan/Desktop/n.txt; echo e >> notes.txt'))
  expect(w.reached).toContain('Bash')
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('another session working in that checkout is judged against the file this one recorded there', withDeps, async ($, on) => {
  const w = world(on, { open: [rec('them', { cwd: '/other', repoRoot: '/other', edits: ['/other/src/a.ts'] })], gits: { '/other/.git': 'dir' } })
  await $.tool.call(edit('/other/src/a.ts'))
  expect(w.prompts.length).toBe(1)
  expect(w.edits).toEqual(['/other/src/a.ts'])
})

// #707: a guard that refuses decides before this one judges, whichever order the mods load in. The
// guard here stands in for no build, winding down, the secret guard and the style check (a mod's
// tests cannot load another mod's files): it refuses at tool.call anything naming NO-BUILD, as each
// of them refuses there. It is loaded above this guard (the prepend tier) and beneath it (append),
// the two places a mod can stand: the engine nests tiers as it nests mods by load order.
const Refuser = (tier: 'prepend' | 'append'): { name: string; tier: 'prepend' | 'append'; register: Register } => ({
  name: 'refuser',
  tier,
  register: on => {
    on('tool.call', async ($, e, next) => {
      const x = e as unknown as { command?: string; file_path?: string }
      if (`${x.command ?? ''} ${x.file_path ?? ''}`.includes('NO-BUILD')) return { deny: 'Blocked: no build is on.' }
      return next(e)
    })
  },
})
const STOP = '{"verdict":"Stop","reason":"They are mid rebase."}'
const clashes = { open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx', '/repo/src/NO-BUILD.tsx', '/repo/NO-BUILD.txt'] })], judge: STOP }

for (const [where, tier] of [['above', 'prepend'], ['beneath', 'append']] as const) {
  test(`a call a guard ${where} it refuses is never judged, told or toasted, while one it lets through still is (#707)`, { plugins: [deps, Refuser(tier)] }, async ($, on) => {
    const w = world(on, clashes)
    // The same fixture judges an allowed clash, so the silence below is the refusal deciding first.
    const judged = await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'ok1'))
    expect(refusal(judged)).toContain('Another session is working on InvoiceTable.tsx.')
    expect(w.prompts.length).toBe(1)
    expect(w.sent.length).toBe(1)
    for (const call of [edit('/repo/src/NO-BUILD.tsx', 'n1'), bash('echo x >> NO-BUILD.txt', 'n2'), bash('git checkout main && echo NO-BUILD', 'n3')]) {
      const r = await $.tool.call(call)
      expect(refusal(r)).toBe('Blocked: no build is on.')
    }
    expect(w.prompts.length).toBe(1)
    expect(w.sent.length).toBe(1)
    expect(w.toasts).toEqual([])
    expect(w.cards.map(c => c.toolUseId)).toEqual(['ok1'])
    expect(w.reached).toEqual([])
    expect(w.edits).toEqual([])
  })
}

// A settings hook (the payload write gate, the push gates) decides beneath every mod at
// classic.PreToolUse, which the test's own hook stands in for: its refusal comes first too.
test('a call a settings hook refuses is never judged, told or toasted (#707)', withDeps, async ($, on) => {
  const w = world(on, clashes)
  on('classic.PreToolUse', ($, e) => ((e as unknown as { file_path?: string }).file_path?.includes('NO-BUILD') ? { deny: 'Blocked: the payload write gate refused it.' } : {}))
  const r = await $.tool.call(edit('/repo/src/NO-BUILD.tsx', 'g1'))
  expect(refusal(r)).toBe('Blocked: the payload write gate refused it.')
  expect(w.prompts).toEqual([])
  expect(w.sent).toEqual([])
  expect(w.toasts).toEqual([])
  expect(w.cards).toEqual([])
  expect(w.edits).toEqual([])
  // The same hook letting a clash through leaves it to be judged as before.
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'g2'))
  expect(w.prompts.length).toBe(1)
})

// The plan is handed from the classic hook to the tool.call hook by the call's id. A call raised
// with none is given one by the engine (measured 2026-10-04), so two such calls are each noted as
// their own (lessons review of #707).
test('two calls raised without an id are each noted, never mixed up (#707 review)', withDeps, async ($, on) => {
  const w = world(on)
  await Promise.all([
    $.tool.call({ tool: 'Edit', file_path: '/repo/src/a.ts', old_string: 'a', new_string: 'b' } as never),
    $.tool.call({ tool: 'Edit', file_path: '/repo/src/b.ts', old_string: 'a', new_string: 'b' } as never),
  ])
  expect([...w.edits].sort()).toEqual(['/repo/src/a.ts', '/repo/src/b.ts'])
})

// Both sides of that hand over read the key through one helper (#732). A call with no id cannot
// reach the guard by any route: the engine refuses a mod that hands a call on without its id and
// runs the call with the id it was raised under (measured here, Claude Code 2.1.289), so the plan
// the classic hook stores is the one the tool.call hook reads back.
const IdDropper: { name: string; tier: 'prepend'; register: Register } = {
  name: 'id-dropper',
  tier: 'prepend',
  register: on => {
    on('tool.call', async ($, e, next) => {
      const { tool_use_id: _dropped, ...rest } = e as unknown as Record<string, unknown>
      return next(rest as never)
    })
  },
}
test('a mod that hands a call on without its id cannot strip it, so the plan is read back under the id it was stored by (#732)', { plugins: [deps, IdDropper] }, async ($, on) => {
  const w = world(on)
  const seen: unknown[] = []
  on('classic.PreToolUse', ($, e) => {
    seen.push((e as unknown as { tool_use_id?: unknown }).tool_use_id)
    return {}
  })
  const r = await $.tool.call(edit('/repo/src/a.ts', 'd1'))
  expect(refusal(r)).toBe('ran')
  expect(seen).toEqual(['d1'])
  expect(w.edits).toEqual(['/repo/src/a.ts'])
})

// What a settings hook decides about a call the guard lets through is passed on as it was: an allow
// skips Claude Code's permission prompt, and a rewrite (rtk's) is what runs.
const Watcher: { name: string; tier: 'prepend'; register: Register } = {
  name: 'watcher',
  tier: 'prepend',
  register: on => {
    on('classic.PreToolUse', async ($, e, next) => {
      const r = await next(e)
      // Told to the world as a process it records, the one channel an inline plugin has to it.
      await $.process.run(['__decided', JSON.stringify(r)])
      return r
    })
  },
}
test('a settings hook decision on a call the guard lets through is passed on unchanged (#707)', { plugins: [deps, Watcher] }, async ($, on) => {
  const w = world(on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  on('classic.PreToolUse', () => ({ allow: true, additionalContext: ['from a settings hook'] }) as never)
  const r = await $.tool.call(bash('echo x >> notes.txt', 'p1'))
  expect(w.toasts).toEqual(['Checked with the other session: safe to edit notes.txt.'])
  const decided = w.runs.filter(x => x.startsWith('__decided ')).map(x => JSON.parse(x.slice('__decided '.length)))
  expect(decided).toEqual([{ allow: true, additionalContext: ['from a settings hook'] }])
  expect(refusal(r)).toBe('ran')
  expect(w.edits).toEqual(['/repo/notes.txt'])
})
