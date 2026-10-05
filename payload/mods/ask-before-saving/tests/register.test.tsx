import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { APPROVAL_MS } from '../hooks/rules.ts'

// Ask before saving (claude-config#618) in a session: every route to lasting memory is held until
// Dan answers in the band, his own permanent words skip the question, and each answer does what the
// spec says. A Write is never held open while Dan reads: a tool call hook that waits on a press is
// cut at its 10 second budget and the write then runs (measured 2026-10-04), so the call is refused
// at once. For good approves that save and asks Claude to send the call again (#738): auto mode's
// classifier refuses a call no model request asked for, so the mod never makes the call itself.

// mod-kit, standing in: a mod cannot import another mod's files. It keeps the questions asked and
// draws the first (text, dividers as a rule, options as buttons with their descriptions under
// them), and reads what a command writes from a table the tests fill in the shape the real reader
// gives. mod-kit's own tests prove the real ones.
type Line = { text: string; dim?: boolean }[] | { divider: true }
type Ask = { mod: string; id: string; chip: string; question: string; body: Line[]; options: { button: string; label: string; description: string }[] }
type Writes = { files: { word: string; path?: string }[]; unnamed: { what: string; words: string[]; inputs: string[] }[] }
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    // Everything the stand-in uses is inside register: the kit loads it as a module of its own.
    const CWD = '/Users/dan/Apps/slate'
    const MEM = '/Users/dan/.claude/projects/p/memory'
    const WRITES: Record<string, Writes> = {
      "cat >> CLAUDE.md <<'EOF'\n- Never merge on Fridays.\nEOF": { files: [{ word: 'CLAUDE.md', path: `${CWD}/CLAUDE.md` }], unnamed: [] },
      "cd ~/.claude/projects/p/memory && cat > note.md <<'EOF'\n- skip it\nEOF": { files: [{ word: 'note.md', path: `${MEM}/note.md` }], unnamed: [] },
      'cp note.md ~/.claude/projects/p/memory/': { files: [{ word: '~/.claude/projects/p/memory/note.md', path: `${MEM}/note.md` }], unnamed: [] },
      "python3 -c \"open('/Users/dan/.claude/CLAUDE.md','a').write('- rule')\"": { files: [], unnamed: [{ what: 'an inline python3 script', words: [], inputs: [] }] },
      'git apply rules.patch': { files: [], unnamed: [{ what: 'a patch', words: [], inputs: [`${CWD}/rules.patch`] }] },
      'git apply other.patch': { files: [], unnamed: [{ what: 'a patch', words: [], inputs: [`${CWD}/other.patch`] }] },
      'cp CLAUDE.md /tmp/backup/CLAUDE.md': { files: [{ word: '/tmp/backup/CLAUDE.md', path: '/tmp/backup/CLAUDE.md' }], unnamed: [] },
      'cp CLAUDE.md /tmp/repo/CLAUDE.md': { files: [{ word: '/tmp/repo/CLAUDE.md', path: '/tmp/repo/CLAUDE.md' }], unnamed: [] },
      // #743: a variable the command set is read as its value; a target the words cannot name is
      // given as written, with no path.
      [`F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`]: { files: [{ word: '$F', path: `${MEM}/MEMORY.md` }], unnamed: [] },
      [`export F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`]: { files: [{ word: '$F', path: `${MEM}/MEMORY.md` }], unnamed: [] },
      [`printf 'x\\n' >> "$(ls ~/.claude/projects/p/memory/MEMORY.md)"`]: { files: [{ word: '$(ls ~/.claude/projects/p/memory/MEMORY.md)' }], unnamed: [] },
      [`printf 'x\\n' >> "$OUT"`]: { files: [{ word: '$OUT' }], unnamed: [] },
      'cat ~/.claude/CLAUDE.md > notes.txt': { files: [{ word: 'notes.txt', path: `${CWD}/notes.txt` }], unnamed: [] },
    }
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ref = { plugin: 'mod-kit', key: 'band' } as never
      const rows = async () => (((await built.state.get(ref)) as { value?: Ask[] }).value ?? [])
      const modkit = {
        writes: async ({ command }: { command: string }) => WRITES[command] ?? { files: [], unnamed: [] },
        // A checkout cloned at /tmp/repo, a folder under /tmp/locked the disk cannot read, and no
        // other checkout in a temporary folder (#726).
        workingTree: async ({ path }: { path: string }) => {
          if (path.startsWith('/tmp/locked/')) throw new Error('EACCES: /tmp/locked')
          return path.startsWith('/tmp/repo/') ? '/tmp/repo' : null
        },
        question: async (q: Ask) => {
          // A test makes the band refuse a question through the environment, the one thing it can set here.
          if ((await built.env.get('BAND_REFUSES')) === '1' || JSON.stringify(q).includes('REFUSE-ME')) throw new Error('a question needs a mod and an id')
          // One that refuses only once the test has queued another save behind it (#726: a fixed
          // wait let a loaded machine queue it after the refusal, and the test passed without the
          // queue). The gate is a read the test's world holds until then.
          if (JSON.stringify(q).includes('REFUSE-SLOWLY')) {
            await built.fs.read('/gate/refuse-slowly')
            throw new Error('the band is busy')
          }
          const all = await rows()
          const i = all.findIndex(r => r.mod === q.mod && r.id === q.id)
          await built.state.set(ref, (i < 0 ? [...all, q] : all.map((r, n) => (n === i ? q : r))) as never)
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
          // A question whose text asks for it stands for a band that cannot take it away.
          if ((await rows()).some(r => r.mod === mod && r.id === id && JSON.stringify(r).includes('CLEAR-FAILS'))) throw new Error('the band is gone')
          await built.state.set(ref, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
        },
      }
      return { ...built, modkit } as never
    })
    on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
      const q = (((await $.state.get({ plugin: 'mod-kit', key: 'band' } as never)) as { value?: Ask[] }).value ?? [])[0]
      if (!q) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      const lines = [
        <Box key="head" flexDirection="row">
          <Text dimColor>{`[${q.chip}] `}</Text>
          <Text color="warning">{q.question}</Text>
        </Box>,
        ...q.body.map((l, n) =>
          Array.isArray(l) ? (
            <Box key={`b${n}`} flexDirection="row">
              {l.map((p, i) => (
                <Text key={String(i)} dimColor={p.dim}>
                  {p.text}
                </Text>
              ))}
            </Box>
          ) : (
            <Text key={`b${n}`}>---</Text>
          ),
        ),
        ...q.options.flatMap((o, i) => [
          <Box key={`o${i}`} flexDirection="row">
            <Button key={`${q.mod}:${o.button}`} label={o.label} hotkey={String(i + 1)} plain onPress={() => undefined} />
          </Box>,
          <Text key={`d${i}`} dimColor>
            {o.description}
          </Text>,
        ]),
      ]
      return <Box flexDirection="column">{lines}</Box>
    })
  },
}
// Another mod's guard, refusing a write whose text carries its marker, as the style check refuses a
// dash. Listed after mod-kit, so where ask before saving loads beside it does not decide the order.
const guard: { name: string; register: Register } = {
  name: 'a-guard',
  register: on => {
    on('tool.call', async ($, e, next) => {
      if (JSON.stringify(e).includes('GUARD-REFUSES')) return { deny: 'Blocked: this carries a dash.' }
      return next(e)
    })
  },
}
// The notes Claude reads. A plugin's own $.session.append reaches no hook in a test in 2.1.289, the
// test's or another plugin's (both measured 2026-10-04: "no implementation for session.append"), so
// every note fails here, and the mod's fallback for a note that cannot be added (a toast carrying
// the whole note, so Dan sees what Claude was not told) is how the test reads it.
const withKit = { plugins: [modKit, guard] }
const notesOf = (w: { toasts: string[] }) =>
  w.toasts
    .filter(t => t.startsWith('Claude was not told: '))
    .map(t => t.slice('Claude was not told: '.length))
    .join('\n')

const HOME = '/Users/dan'
const CWD = '/Users/dan/Apps/slate'

// The Mac and Claude Code beneath the mod: files, the tools that write them, the notes Claude reads,
// the memory section of the system prompt, toasts and the band.
// A gate the band stand-in waits on before it refuses: `reached` is called as it starts waiting,
// and it refuses once `opened` settles.
type Gate = { reached: () => void; opened: Promise<void> }
// `auto` stands for auto mode (#738): its classifier judges each call by the model request that
// produced it, beneath every hook, so it refuses a call no request asked for, which a call a plugin
// makes for itself is, with the words it gave on 2026-10-05.
// `ownClock` leaves the clock to the test, which answers it itself.
const world = (on: On, init: { files?: Record<string, string>; failWrites?: boolean; bandRefuses?: boolean; cwdFails?: boolean; gate?: Gate; auto?: boolean; ownClock?: true } = {}) => {
  const files: Record<string, string> = { ...(init.files ?? {}) }
  const ran: { tool: string; input: Record<string, unknown> }[] = []
  const toasts: string[] = []
  // The prompts a plugin submitted, each a turn of Claude's own.
  const prompts: string[] = []
  const clock = init.ownClock ? (undefined as unknown as ReturnType<typeof mock.clock>) : mock.clock(on)
  mock.env(on, { HOME, BAND_REFUSES: init.bandRefuses ? '1' : '0' })
  // Where the session runs; a test moves it as /cd or a worktree move does.
  const at = { cwd: CWD }
  on('session.cwd', () => {
    if (init.cwdFails) throw new Error('no session')
    return { value: at.cwd } as never
  })
  on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined }) as never)
  on('fs.read', async ($, e) => {
    if (init.gate && e.path === '/gate/refuse-slowly') {
      init.gate.reached()
      await init.gate.opened
      return { value: '' } as never
    }
    const t = files[e.path]
    if (t === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: t } as never
  })
  on('tool.call', ($, e, next) => {
    const { tool, tool_use_id: _id, agentId: _a, consent: _c, ...input } = e as unknown as Record<string, unknown>
    if (init.auto && next.origin.plugin !== 'engine')
      return { deny: `The server-side auto mode classifier gave no verdict for ${String(tool)}: the request that produced this action did not ask for one.` } as never
    ran.push({ tool: String(tool), input })
    if (init.failWrites) return { isError: true, result: 'String to replace not found in file.', text: 'String to replace not found in file.' } as never
    return { result: 'written', text: 'written' } as never
  })
  on('ui.invalidate', () => ({ value: undefined }) as never)
  on('prompt.section', ($, e) => ({ text: e.text }))
  on('prompt.submit', ($, e) => {
    if (e.origin.kind === 'plugin') prompts.push(e.text)
    return { text: e.text } as never
  })
  on('turn.start', ($, e) => ({ turnId: e.turnId }) as never)
  on('turn.complete', ($, e) => ({ text: e.answer }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }) as never)
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  on('session.compact', () => ({ messages: [{ role: 'assistant', text: 'summary', toolUses: [] }] }) as never)
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  return { files, ran, toasts, prompts, clock, at }
}
// Everything Claude was told to do, by a note or by a prompt of its own.
const toldOf = (w: { toasts: string[]; prompts: string[] }) => [notesOf(w), ...w.prompts].join('\n')
// A turn of Claude's on the main loop, running while Dan presses (#738).
type Turns = { turn: { start: (x: never) => Promise<unknown>; complete: (x: never) => Promise<unknown> } }
const startTurn = ($: unknown) => ($ as Turns).turn.start({ text: 'go on', turnId: 'turn-1' } as never)
const endTurn = ($: unknown) => ($ as Turns).turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 'turn-1', reason: 'answer' } as never)

type Caller = { tool: { call: (e: never) => Promise<unknown> } }
type Result = { deny?: string; text?: string; isError?: boolean; context?: readonly string[] }
const call = async ($: Caller, input: Record<string, unknown>) => (await $.tool.call({ tool_use_id: `t${Math.random()}`, ...input } as never)) as Result
// What Claude reads of a refused call: the refusal, whether a tool.call hook or the classic hook gave it.
const refusalOf = (r: Result) => r.deny ?? (r.isError ? r.text : undefined) ?? ''
const band = () => ({ plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 40, bodyColumns: 100, scroll: { offset: 0, bodyRows: 40 }, view: {} } }) as never
type Found = { text: string; key?: string; children: unknown[]; props: Record<string, unknown> }
type Mounted = { findAll: (q: { type: string }) => Promise<Found[]>; press: (t: object) => Promise<unknown>; unmount: () => Promise<void> }
const shown = async (ui: Mounted) => (await ui.findAll({ type: 'Text' })).filter(t => t.children.every(c => typeof c === 'string')).map(t => t.text)
const mount = async ($: unknown) => (await ($ as { ui: { mount: (x: never) => Promise<unknown> } }).ui.mount(band())) as Mounted
// Presses the shown question's answer, by the button the band drew for it.
const answer = async ($: unknown, button: string) => {
  const ui = await mount($)
  const key = (await ui.findAll({ type: 'Button' })).map(b => String(b.key ?? b.props.key ?? '')).find(k => k.startsWith(`ask-before-saving:${button}:`))
  if (!key) throw new Error(`no ${button} button in the band`)
  await ui.press({ key })
  await ui.unmount()
  return key
}
const dan = async ($: unknown, text: string, kind = 'composer') => {
  await ($ as { prompt: { submit: (x: never) => Promise<unknown> } }).prompt.submit({ text, origin: { kind } } as never)
}

test('a Write to a project CLAUDE.md is held: refused at once, and the band asks with the exact text and the file', withKit, async ($, on) => {
  const w = world(on)
  const r = await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '# Slate\n\n- Ask before merging.\n' })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain('Dan is being asked')
  const ui = await mount($)
  expect(await shown(ui)).toEqual([
    '[Standing rule] ',
    'Save this as a standing rule?',
    '---',
    '# Slate',
    '',
    '- Ask before merging.',
    '~/Apps/slate/CLAUDE.md',
    '---',
    'Saved to ~/Apps/slate/CLAUDE.md',
    'Kept until this session ends; nothing is written',
    'Nothing is saved',
  ])
  await ui.unmount()
})

test('an Edit to a file in the memory folder shows the text it puts in', withKit, async ($, on) => {
  const path = `${HOME}/.claude/projects/-Users-dan-Apps-slate/memory/MEMORY.md`
  const w = world(on, { files: { [path]: '- [a](a.md)\n' } })
  const r = await call($, { tool: 'Edit', file_path: path, old_string: '- [a](a.md)', new_string: '- [a](a.md)\n- [b](b.md) just for now' })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain('Dan is being asked')
  const ui = await mount($)
  const lines = await shown(ui)
  expect(lines).toContain('- [b](b.md) just for now')
  expect(lines).toContain('~/.claude/projects/-Users-dan-Apps-slate/memory/MEMORY.md')
  await ui.unmount()
})

// #705, the spec's "verify at build": Claude Code's built-in auto-memory writer saves through tool
// calls (the engine's memory fork runs a loop of its own whose calls raise tool.call and PreToolUse
// like any other, docs/mods-design.md), so its file in the memory folder is asked about the same way.
test("the built-in auto-memory writer's topic file in the memory folder is asked about like any other save", withKit, async ($, on) => {
  const w = world(on)
  const path = `${HOME}/.claude/projects/-Users-dan-Apps-slate/memory/feedback-no-merge-quiz.md`
  const r = await call($, { tool: 'Write', file_path: path, content: '---\nname: No merge quizzes\ntype: feedback\n---\nSkip the merge quiz.\n' })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain('Dan is being asked')
})

test('a Write over an existing file shows only the lines it adds', withKit, async ($, on) => {
  const path = `${HOME}/.claude/CLAUDE.md`
  world(on, { files: { [path]: '# Global\n- old rule\n' } })
  await call($, { tool: 'Write', file_path: path, content: '# Global\n- old rule\n- new rule\n' })
  const ui = await mount($)
  const lines = await shown(ui)
  expect(lines).toContain('- new rule')
  expect(lines).not.toContain('- old rule')
  await ui.unmount()
})

test('a Bash heredoc into CLAUDE.md is held too, showing the command that carries the text', withKit, async ($, on) => {
  const w = world(on)
  const command = "cat >> CLAUDE.md <<'EOF'\n- Never merge on Fridays.\nEOF"
  const r = await call($, { tool: 'Bash', command })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain('Dan is being asked')
  const ui = await mount($)
  const lines = await shown(ui)
  expect(lines).toContain('- Never merge on Fridays.')
  expect(lines).toContain('~/Apps/slate/CLAUDE.md')
  await ui.unmount()
})

// #705: these went straight through. The paths are mod-kit's shared reader's (proved in its tests):
// a cd before a relative path, a copy into the memory folder, an inline script, a patch.
test('a write by any shell route mod-kit reads is held: a cd into the memory folder, a copy into it, an inline script, a patch', withKit, async ($, on) => {
  const w = world(on, { files: { [`${CWD}/rules.patch`]: '--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ -1 +1,2 @@\n x\n+- rule\n' } })
  const routes = [
    "cd ~/.claude/projects/p/memory && cat > note.md <<'EOF'\n- skip it\nEOF",
    'cp note.md ~/.claude/projects/p/memory/',
    "python3 -c \"open('/Users/dan/.claude/CLAUDE.md','a').write('- rule')\"",
    'git apply rules.patch',
  ]
  for (const command of routes) expect(`${command}: ${refusalOf(await call($, { tool: 'Bash', command }))}`).toContain('Dan is being asked')
  expect(w.ran).toEqual([])
  const ui = await mount($)
  expect(await shown(ui)).toContain('~/.claude/projects/p/memory/note.md')
  await ui.unmount()
})

// #743: `F=<memory folder>/MEMORY.md; printf ... >> "$F"` appended to MEMORY.md with no question.
test('a save through a path the command holds in a variable is held and asked about, showing the file it goes to', withKit, async ($, on) => {
  const w = world(on)
  for (const command of [`F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`, `export F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`])
    expect(`${command}: ${refusalOf(await call($, { tool: 'Bash', command }))}`).toContain('Dan is being asked')
  expect(w.ran).toEqual([])
  const ui = await mount($)
  expect(await shown(ui)).toContain('~/.claude/projects/p/memory/MEMORY.md')
  await ui.unmount()
})

test('a save to a target the words cannot name is asked about when the command mentions lasting memory, and goes through when it mentions none', withKit, async ($, on) => {
  const w = world(on)
  const asked = await call($, { tool: 'Bash', command: `printf 'x\\n' >> "$(ls ~/.claude/projects/p/memory/MEMORY.md)"` })
  expect(refusalOf(asked)).toContain('Dan is being asked')
  const ui = await mount($)
  expect(await shown(ui)).toContain('~/.claude/projects/p/memory/MEMORY.md')
  await ui.unmount()
  // A target nothing in the command names, and a file spelled out beside a mention of lasting
  // memory (a backup of it), are no save.
  await call($, { tool: 'Bash', command: `printf 'x\\n' >> "$OUT"` })
  await call($, { tool: 'Bash', command: 'cat ~/.claude/CLAUDE.md > notes.txt' })
  expect(w.ran.map(r => r.input.command)).toEqual([`printf 'x\\n' >> "$OUT"`, 'cat ~/.claude/CLAUDE.md > notes.txt'])
})

test('a write anywhere else, a patch that touches no lasting memory, a backup in a temporary folder, and a Bash call that writes nothing go straight through', withKit, async ($, on) => {
  const w = world(on, { files: { [`${CWD}/other.patch`]: '--- a/README.md\n+++ b/README.md\n' } })
  await call($, { tool: 'Write', file_path: 'README.md', content: 'x' })
  await call($, { tool: 'Bash', command: 'git apply other.patch' })
  await call($, { tool: 'Bash', command: 'cp CLAUDE.md /tmp/backup/CLAUDE.md' })
  await call($, { tool: 'Bash', command: 'ls -la' })
  expect(w.ran.map(r => r.tool)).toEqual(['Write', 'Bash', 'Bash', 'Bash'])
  const ui = await mount($)
  expect(await shown(ui)).toEqual(['engine band'])
  await ui.unmount()
})

// #726: everything under a temporary folder was exempt, but a session started in a repository
// cloned there loads its CLAUDE.md and AGENTS.md, so a save to one went through unasked.
test('a save into a checkout in a temporary folder is held and asked about, by Write and by Bash', withKit, async ($, on) => {
  const w = world(on)
  const written = await call($, { tool: 'Write', file_path: '/tmp/repo/AGENTS.md', content: '- use pnpm\n' })
  expect(refusalOf(written)).toContain('Dan is being asked')
  const copied = await call($, { tool: 'Bash', command: 'cp CLAUDE.md /tmp/repo/CLAUDE.md' })
  expect(refusalOf(copied)).toContain('Dan is being asked')
  expect(w.ran).toEqual([])
  const ui = await mount($)
  expect(await shown(ui)).toContain('/tmp/repo/AGENTS.md')
  await ui.unmount()
})

test('a save to a temporary folder the disk cannot read is refused, never let through', withKit, async ($, on) => {
  const w = world(on)
  const r = await call($, { tool: 'Write', file_path: '/tmp/locked/CLAUDE.md', content: '- rule\n' })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain('could not check whether this writes lasting memory (EACCES: /tmp/locked)')
})

// #705: Dan was asked about a save before any guard had judged it, then the save was refused when
// For good replayed it. The question is asked beneath every mod's tool.call hook now.
test('a save another guard refuses is refused before Dan is asked, so he never approves a save that cannot land', withKit, async ($, on) => {
  const w = world(on)
  const r = await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- GUARD-REFUSES this rule\n' })
  expect(r.deny).toBe('Blocked: this carries a dash.')
  expect(w.ran).toEqual([])
  const ui = await mount($)
  expect(await shown(ui)).toEqual(['engine band'])
  await ui.unmount()
})

// #707: a settings hook (the payload write gate) decides beneath every mod at classic.PreToolUse,
// as the test's own hook does here, and its refusal comes before the question too.
test('a save a settings hook refuses is refused before Dan is asked (#707)', withKit, async ($, on) => {
  const w = world(on)
  on('classic.PreToolUse', ($, e) => (JSON.stringify(e).includes('GATE-REFUSES') ? { deny: 'Blocked: the payload write gate refused it.' } : {}))
  const r = await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- GATE-REFUSES this rule\n' })
  expect(refusalOf(r)).toBe('Blocked: the payload write gate refused it.')
  expect(w.ran).toEqual([])
  const ui = await mount($)
  expect(await shown(ui)).toEqual(['engine band'])
  await ui.unmount()
  // The same hook letting a save through leaves it to be asked about as before.
  const asked = await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- Ask before merging.\n' })
  expect(refusalOf(asked)).toContain('Dan is being asked')
})

test("Dan's own permanent words skip the question, and Claude is told to say what it saved", withKit, async ($, on) => {
  const w = world(on)
  await dan($, 'From now on, ask before you merge anything.')
  const r = await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'a', new_string: 'a\n- Ask before merging.' })
  expect(w.ran.map(x => x.tool)).toEqual(['Edit'])
  expect(r.deny).toBeUndefined()
  expect((r.context ?? []).join(' ')).toContain('say in one line what you saved')
  expect((r.context ?? []).join(' ')).toContain('~/Apps/slate/CLAUDE.md')
  // The words count for Dan's message alone: the next one, without them, asks again.
  await dan($, 'ok and the other thing')
  const again = await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'b', new_string: 'b\n- x' })
  expect(refusalOf(again)).toContain('Dan is being asked')
})

test("the same words from his phone count, and still pass every other guard's check", withKit, async ($, on) => {
  const w = world(on)
  await dan($, 'Always run the linter first.', 'bridge')
  await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'a', new_string: 'a\n- Run the linter first.' })
  expect(w.ran.map(x => x.tool)).toEqual(['Edit'])
  const refused = await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'b', new_string: 'b\n- GUARD-REFUSES' })
  expect(refused.deny).toBe('Blocked: this carries a dash.')
  expect(w.ran.length).toBe(1)
})

// #705: only Dan's own messages count for the skip, and no test sent the words from anyone else.
test("permanent words from a peer session's message or a plugin's prompt do not skip the question", withKit, async ($, on) => {
  const w = world(on)
  for (const kind of ['peer', 'plugin']) {
    await dan($, 'From now on, never merge on Fridays.', kind)
    const r = await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: kind, new_string: `${kind}\n- Never merge on Fridays.` })
    expect(`${kind}: ${refusalOf(r)}`).toContain('Dan is being asked')
  }
  expect(w.ran).toEqual([])
})

// #738: in auto mode For good never saved. The mod replayed the call itself, the classifier refused
// a call no model request had asked for, Claude sent it again as told, and that was asked about as a
// new save, so For good went round for ever. Seen twice on 2026-10-05: a Bash append to MEMORY.md
// and a Write to a memory file.
test("For good in auto mode saves on Claude's own call, exactly once, with no second question (#738)", withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const command = `F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`
  expect(refusalOf(await call($, { tool: 'Bash', command, description: 'Append the rule to MEMORY.md' }))).toContain('Dan is being asked')
  await answer($, 'for-good')
  // Nothing has run: the mod makes no call of its own, which the classifier would refuse.
  expect(w.ran).toEqual([])
  expect(w.toasts.join('\n')).not.toContain('Not saved')
  // The question is gone, and Claude is asked, in a turn of its own while it is idle, to send the
  // call again, which it is given whole.
  let ui = await mount($)
  expect(await shown(ui)).toEqual(['engine band'])
  await ui.unmount()
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]).toContain('Dan answered For good to saving this to ~/.claude/projects/p/memory/MEMORY.md')
  expect(w.prompts[0]).toContain(JSON.stringify(command))
  // Claude sends it from a request of its own, describing it in its own words: it goes through the
  // classifier and is saved, and nothing is asked.
  const again = await call($, { tool: 'Bash', command, description: 'Save the rule Dan approved' })
  expect(again.deny).toBeUndefined()
  expect(again.isError).toBeUndefined()
  expect(w.ran.map(r => r.input.command)).toEqual([command])
  expect((again.context ?? []).join(' ')).toContain('Saved to ~/.claude/projects/p/memory/MEMORY.md, as Dan answered For good.')
  ui = await mount($)
  expect(await shown(ui)).toEqual(['engine band'])
  await ui.unmount()
  // The approval was for that one save: the same call once more is asked about again.
  expect(refusalOf(await call($, { tool: 'Bash', command }))).toContain('Dan is being asked')
  expect(w.ran.length).toBe(1)
})

test('For good approves the save, not the spelling: the same file and text by another path goes through, other text does not', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' })
  await answer($, 'for-good')
  expect(refusalOf(await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- Use npm.\n' }))).toContain('Dan is being asked')
  expect(w.ran).toEqual([])
  const r = await call($, { tool: 'Write', file_path: `${CWD}/AGENTS.md`, content: '- Use pnpm.\n' })
  expect(r.deny).toBeUndefined()
  expect(w.ran.map(x => x.input.content)).toEqual(['- Use pnpm.\n'])
})

// Lessons review of #738: For good approves the file Dan was shown. A relative path, or a Bash call's
// relative target, sent again after the session has moved writes another file, which he never saw.
test('For good approves the file Dan was shown: sent again after the session moves, a relative path is asked about again', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- Ask before merging.\n' })
  w.at.cwd = '/Users/dan/Apps/other'
  await answer($, 'for-good')
  expect(refusalOf(await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- Ask before merging.\n' }))).toContain('Dan is being asked')
  expect(w.ran).toEqual([])
  const r = await call($, { tool: 'Write', file_path: `${CWD}/CLAUDE.md`, content: '- Ask before merging.\n' })
  expect(r.deny).toBeUndefined()
  expect(w.ran.map(x => x.input.file_path)).toEqual([`${CWD}/CLAUDE.md`])
})

test('a Bash save approved in one folder is asked about again when it is sent from another', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const command = "cat >> CLAUDE.md <<'EOF'\n- Never merge on Fridays.\nEOF"
  await call($, { tool: 'Bash', command })
  await answer($, 'for-good')
  w.at.cwd = '/Users/dan/Apps/other'
  expect(refusalOf(await call($, { tool: 'Bash', command }))).toContain('Dan is being asked')
  expect(w.ran).toEqual([])
  w.at.cwd = CWD
  expect((await call($, { tool: 'Bash', command })).deny).toBeUndefined()
  expect(w.ran.length).toBe(1)
})

// A turn marked running by a process that then stopped never sees its turn end, and a note to an
// idle session waits for Dan's next message; a session start has no turn running.
test('after a session start, For good asks by a prompt even when a turn was marked running before it', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  await startTurn($)
  await ($ as unknown as { session: { start: (x: never) => Promise<unknown> } }).session.start({ cwd: CWD, surface: 'terminal', isInteractive: true } as never)
  await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' })
  await answer($, 'for-good')
  expect(w.prompts.length).toBe(1)
  expect(notesOf(w)).not.toContain('Dan answered For good')
})

// L523, L567: an approval nobody uses must not stand open, and one past its time is refused where it
// is used, said plainly both ways.
test('an approval Claude does not use within its time lapses: Dan and Claude are told, and the call is asked about again', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await call($, input)
  await answer($, 'for-good')
  await w.clock.advance(APPROVAL_MS - 1)
  expect(w.toasts.join('\n')).not.toContain('lapsed')
  await w.clock.advance(1)
  expect(w.toasts.join('\n')).toContain('The For good you gave for saving to ~/Apps/slate/AGENTS.md lapsed after 10 minutes unused')
  expect(notesOf(w)).toContain("Dan's For good on saving this to ~/Apps/slate/AGENTS.md lapsed after 10 minutes unused")
  const late = await call($, input)
  expect(refusalOf(late)).toContain('Dan is being asked')
  expect(w.ran).toEqual([])
})

test('an approval past its time is refused where it is used even when nothing announced its lapse (a reload drops the timer)', withKit, async ($, on) => {
  // A clock whose every timer is refused, as a reload loses the mod's timers, and that moves only
  // when the test moves it.
  let now = 0
  on('clock.now', () => ({ value: now }) as never)
  on('clock.after', () => {
    throw new Error('the mod reloaded')
  })
  const w = world(on, { auto: true, ownClock: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await call($, input)
  await answer($, 'for-good')
  // A timer that cannot be set never stops Claude being asked (lessons review of #738).
  expect(w.prompts.length).toBe(1)
  now = APPROVAL_MS
  expect(w.toasts.join('\n')).not.toContain('lapsed')
  const late = await call($, input)
  expect(refusalOf(late)).toContain('Dan is being asked')
  expect(refusalOf(late)).toContain('lapsed')
  expect(w.toasts.join('\n')).toContain('The For good you gave for saving to ~/Apps/slate/AGENTS.md lapsed after 10 minutes unused')
  expect(w.ran).toEqual([])
})

// A note is read at Claude's next step, so one added while it works reaches it at once; one added
// while its last answer is being written is read by nobody, so the end of that turn asks instead.
test('For good while Claude is working reaches it as a note, and as a prompt of its own when the turn ends without the save', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  await startTurn($)
  const input = { tool: 'Write', file_path: `${HOME}/.claude/projects/p/memory/note.md`, content: 'Skip the screenshots.\n' }
  await call($, input)
  await answer($, 'for-good')
  expect(w.prompts).toEqual([])
  expect(notesOf(w)).toContain('Dan answered For good to saving this to ~/.claude/projects/p/memory/note.md')
  await endTurn($)
  await w.clock.settle()
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]).toContain('Dan answered For good to saving this to ~/.claude/projects/p/memory/note.md')
  const r = await call($, input)
  expect(r.deny).toBeUndefined()
  expect(w.ran.map(x => x.input.file_path)).toEqual([input.file_path])
})

test('a save Claude sends again within the turn that was told is saved once, and the end of the turn asks for nothing more', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  await startTurn($)
  const input = { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'a', new_string: 'a\n- Ask before merging.' }
  await call($, input)
  await answer($, 'for-good')
  const r = await call($, input)
  expect(r.deny).toBeUndefined()
  await endTurn($)
  await w.clock.settle()
  expect(w.prompts).toEqual([])
  expect(w.ran.length).toBe(1)
})

test('For good whose save then fails says so to Dan, and never that it was saved', withKit, async ($, on) => {
  const w = world(on, { failWrites: true })
  const input = { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'gone', new_string: 'gone\n- rule' }
  await call($, input)
  await answer($, 'for-good')
  const r = await call($, input)
  expect(r.isError).toBe(true)
  expect(w.toasts.join('\n')).toContain('Not saved to ~/Apps/slate/CLAUDE.md: String to replace not found in file.')
  expect((r.context ?? []).join(' ')).not.toContain('Saved to')
})

test('an approval the session ends before Claude uses is dropped, and Dan is told it was never used', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await call($, input)
  await answer($, 'for-good')
  await ($ as unknown as { session: { end: (x: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'clear' } as never)
  expect(w.toasts.join('\n')).toContain('The For good you gave for saving to ~/Apps/slate/AGENTS.md was never used before the session ended')
  expect(refusalOf(await call($, input))).toContain('Dan is being asked')
  expect(w.ran).toEqual([])
})

test('Just this session writes nothing and holds the rule in the system prompt, through a compaction, until the session ends', withKit, async ($, on) => {
  const w = world(on)
  await call($, { tool: 'Write', file_path: `${HOME}/.claude/projects/p/memory/note.md`, content: 'Skip the screenshots today.\n' })
  await answer($, 'this-session')
  expect(w.ran).toEqual([])
  expect(notesOf(w)).toContain('Just this session')
  const section = async () => (await ($ as unknown as { prompt: { section: (x: never) => Promise<{ text: string | null }> } }).prompt.section({ name: 'memory', text: 'core memory' } as never)).text
  expect(await section()).toContain('core memory')
  expect(await section()).toContain('Skip the screenshots today.')
  // A compaction rewrites the conversation; the system prompt is assembled afresh and keeps it.
  await ($ as unknown as { session: { compact: (x: never) => Promise<unknown> } }).session.compact({ messages: [{ role: 'user', text: 'hi', toolUses: [] }] } as never)
  expect(await section()).toContain('Skip the screenshots today.')
  await ($ as unknown as { session: { end: (x: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'other' } as never)
  expect(await section()).toBe('core memory')
})

test('Not at all writes nothing and tells Claude not to save it', withKit, async ($, on) => {
  const w = world(on)
  await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- Not a standing preference.\n' })
  await answer($, 'not-at-all')
  expect(w.ran).toEqual([])
  expect(notesOf(w)).toContain('Not at all')
  expect(notesOf(w)).toContain('nothing was saved')
})

test('a second save waits behind the first, and is asked once the first is answered', withKit, async ($, on) => {
  const w = world(on)
  await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- first\n' })
  await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- second\n' })
  let ui = await mount($)
  expect(await shown(ui)).toContain('- first')
  expect(await shown(ui)).not.toContain('- second')
  await ui.unmount()
  await answer($, 'not-at-all')
  ui = await mount($)
  expect(await shown(ui)).toContain('- second')
  await ui.unmount()
  await answer($, 'for-good')
  await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- second\n' })
  expect(w.ran.map(r => r.input.file_path)).toEqual(['AGENTS.md'])
})

// L243: a press answers the save it was drawn for. A second press on a save already answered (a
// double tap of 1) must not land on the save asked next.
test('a press on a save already answered does nothing to the save asked after it', withKit, async ($, on) => {
  const w = world(on)
  await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- first\n' })
  await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- second\n' })
  const ui = await mount($)
  const first = (await ui.findAll({ type: 'Button' })).map(b => String(b.key ?? b.props.key ?? '')).find(k => k.startsWith('ask-before-saving:for-good:'))
  // Two taps on the button drawn, the second landing before the first has redrawn the band.
  await Promise.all([ui.press({ key: first }), ui.press({ key: first })])
  await ui.unmount()
  // One approval, for the save the button was drawn for: the second save is still asked, and sending
  // it again is not let through.
  expect(w.prompts.length).toBe(1)
  const again = await mount($)
  expect(await shown(again)).toContain('- second')
  await again.unmount()
  expect(refusalOf(await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- second\n' }))).toContain('Dan is being asked')
  await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- first\n' })
  expect(w.ran.map(r => r.input.file_path)).toEqual(['CLAUDE.md'])
})

// Review of #718: the answer took the save out of the queue, then a band that could not take the
// question away threw, and the answer was lost: nothing saved, nothing said.
test("a question the band cannot take away still carries Dan's answer through, and says why", withKit, async ($, on) => {
  const w = world(on)
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- CLEAR-FAILS use pnpm\n' }
  await call($, input)
  await answer($, 'for-good')
  expect(toldOf(w)).toContain('Dan answered For good to saving this to ~/Apps/slate/AGENTS.md')
  expect(w.toasts.join('\n')).toContain('could not be taken out of the band: the band is gone')
  await call($, input)
  expect(w.ran.map(r => r.input.file_path)).toEqual(['AGENTS.md'])
})

// A deadline for a wait on a condition, so a condition never met fails by name rather than hanging:
// under the test runner's own 5 second limit, which would otherwise fire first and name nothing.
const within = async <T,>(p: Promise<T>, what: string, ms = 2000): Promise<T> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([p, new Promise<never>((_, reject) => (timer = setTimeout(() => reject(new Error(`${what} within ${ms} ms`)), ms)))])
  } finally {
    clearTimeout(timer)
  }
}
// Review of #718: a save queued behind one whose question then failed to show was never asked,
// since only the save at the front is shown and nothing showed the next one.
test('a save queued behind one whose question could not be shown is asked in its place', withKit, async ($, on) => {
  let reached!: () => void
  const asking = new Promise<void>(r => (reached = r))
  let open!: () => void
  const opened = new Promise<void>(r => (open = r))
  // The condition the stand-in waits on: ask before saving has written a queue of two.
  let queued!: (files: unknown[]) => void
  const queuedBehind = new Promise<unknown[]>(r => (queued = r))
  on('state.set', async ($, e, next) => {
    const r = await next(e)
    const write = e as unknown as { plugin?: string; key?: string; value?: { input?: { file_path?: unknown } }[] }
    if (write.plugin === 'ask-before-saving' && write.key === 'pending' && write.value?.length === 2) queued(write.value.map(p => p.input?.file_path))
    return r
  })
  const w = world(on, { gate: { reached, opened } })
  const first = call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- REFUSE-SLOWLY rule\n' })
  let second: Promise<Result>
  try {
    // The first save's question is being drawn, so it leads the queue; the second then waits behind it.
    await within(asking, 'the first save never reached the band')
    second = call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- second\n' })
    expect(await within(queuedBehind, 'the second save was never queued behind the first')).toEqual(['CLAUDE.md', 'AGENTS.md'])
  } finally {
    open()
  }
  expect(refusalOf(await within(first, 'the first save never came back'))).toContain('could not be shown (the band is busy)')
  expect(refusalOf(await within(second, 'the second save never came back'))).toContain('Dan is being asked')
  const ui = await mount($)
  expect(await shown(ui)).toContain('- second')
  await ui.unmount()
  await answer($, 'for-good')
  await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- second\n' })
  expect(w.ran.map(r => r.input.file_path)).toEqual(['AGENTS.md'])
})

test('a question the band cannot show still refuses the save, and says why', withKit, async ($, on) => {
  const w = world(on, { bandRefuses: true })
  const r = await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- rule\n' })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain('could not be shown')
  expect(w.toasts.join('\n')).toContain('could not be shown')
})

test('a save the mod cannot judge is refused, never let through: a failing hook fails closed', withKit, async ($, on) => {
  const w = world(on, { cwdFails: true })
  const r = await call($, { tool: 'Write', file_path: '/anywhere/CLAUDE.md', content: '- rule\n' })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain('could not check')
})

test('a save whose question could not be shown is never answered later by a press meant for another', withKit, async ($, on) => {
  const w = world(on)
  const refused = await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- REFUSE-ME\n' })
  expect(refusalOf(refused)).toContain('could not be shown')
  await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- second\n' })
  await answer($, 'for-good')
  expect(toldOf(w)).toContain('saving this to ~/Apps/slate/AGENTS.md')
  expect(toldOf(w)).not.toContain('saving this to ~/Apps/slate/CLAUDE.md')
  await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- second\n' })
  expect(w.ran.map(r => r.input.file_path)).toEqual(['AGENTS.md'])
  const ui = await mount($)
  expect(await shown(ui)).toEqual(['engine band'])
  await ui.unmount()
})
