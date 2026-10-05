import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'

// Ask before saving (claude-config#618) in a session: every route to lasting memory is held until
// Dan answers in the band, his own permanent words skip the question, and each answer does what the
// spec says. A Write is never held open while Dan reads: a tool call hook that waits on a press is
// cut at its 10 second budget and the write then runs (measured 2026-10-04), so the call is refused
// at once and the mod replays it exactly on For good.

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
    }
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ref = { plugin: 'mod-kit', key: 'band' } as never
      const rows = async () => (((await built.state.get(ref)) as { value?: Ask[] }).value ?? [])
      const modkit = {
        writes: async ({ command }: { command: string }) => WRITES[command] ?? { files: [], unnamed: [] },
        question: async (q: Ask) => {
          // A test makes the band refuse a question through the environment, the one thing it can set here.
          if ((await built.env.get('BAND_REFUSES')) === '1' || JSON.stringify(q).includes('REFUSE-ME')) throw new Error('a question needs a mod and an id')
          const all = await rows()
          const i = all.findIndex(r => r.mod === q.mod && r.id === q.id)
          await built.state.set(ref, (i < 0 ? [...all, q] : all.map((r, n) => (n === i ? q : r))) as never)
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
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
const world = (on: On, init: { files?: Record<string, string>; failWrites?: boolean; bandRefuses?: boolean; cwdFails?: boolean } = {}) => {
  const files: Record<string, string> = { ...(init.files ?? {}) }
  const ran: { tool: string; input: Record<string, unknown> }[] = []
  const toasts: string[] = []
  mock.env(on, { HOME, BAND_REFUSES: init.bandRefuses ? '1' : '0' })
  on('session.cwd', () => {
    if (init.cwdFails) throw new Error('no session')
    return { value: CWD } as never
  })
  on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined }) as never)
  on('fs.read', ($, e) => {
    const t = files[e.path]
    if (t === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: t } as never
  })
  on('tool.call', ($, e) => {
    const { tool, tool_use_id: _id, agentId: _a, consent: _c, ...input } = e as unknown as Record<string, unknown>
    ran.push({ tool: String(tool), input })
    if (init.failWrites) return { isError: true, result: 'String to replace not found in file.', text: 'String to replace not found in file.' } as never
    return { result: 'written', text: 'written' } as never
  })
  on('ui.invalidate', () => ({ value: undefined }) as never)
  on('prompt.section', ($, e) => ({ text: e.text }))
  on('prompt.submit', ($, e) => ({ text: e.text }) as never)
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
  return { files, ran, toasts }
}

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

test('For good replays the exact call once, tells Claude it was saved, and takes the question away', withKit, async ($, on) => {
  const w = world(on)
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await call($, input)
  await answer($, 'for-good')
  expect(w.ran).toEqual([{ tool: 'Write', input: { file_path: 'AGENTS.md', content: '- Use pnpm.\n' } }])
  expect(notesOf(w)).toContain('For good')
  expect(notesOf(w)).toContain('saved to ~/Apps/slate/AGENTS.md')
  const ui = await mount($)
  expect(await shown(ui)).toEqual(['engine band'])
  await ui.unmount()
  // The approval was for that one call: the same write again asks again.
  const r = await call($, input)
  expect(refusalOf(r)).toContain('Dan is being asked')
  expect(w.ran.length).toBe(1)
})

test('For good that fails to save says so to Dan and to Claude, never that it was saved', withKit, async ($, on) => {
  const w = world(on, { failWrites: true })
  await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'gone', new_string: 'gone\n- rule' })
  await answer($, 'for-good')
  expect(w.toasts.join('\n')).toContain('Not saved to ~/Apps/slate/CLAUDE.md: String to replace not found in file.')
  expect(notesOf(w)).toContain('could not be saved')
  expect(notesOf(w)).not.toContain('For good: saved')
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
  expect(w.ran.map(r => r.input.file_path)).toEqual(['CLAUDE.md'])
  const again = await mount($)
  expect(await shown(again)).toContain('- second')
  await again.unmount()
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
  expect(w.ran.map(r => r.input.file_path)).toEqual(['AGENTS.md'])
  const ui = await mount($)
  expect(await shown(ui)).toEqual(['engine band'])
  await ui.unmount()
})
