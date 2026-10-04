import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'

// Ask before saving (claude-config#618) in a session: every route to lasting memory is held until
// Dan answers in the band, his own permanent words skip the question, and each answer does what the
// spec says. A Write is never held open while Dan reads: a tool call hook that waits on a press is
// cut at its 10 second budget and the write then runs (measured 2026-10-04), so the call is refused
// at once and the mod replays it exactly on For good.

// mod-kit, standing in: a mod cannot import another mod's files. It keeps the rows the mod
// publishes and draws them (text, dividers as a rule, buttons), and reads commands from a table the
// tests fill in the shape the real reader gives. mod-kit's own tests prove the real ones.
type Part = { text?: string; dim?: boolean; color?: string; button?: string; label?: string }
type Line = Part[] | { divider: true }
type Row = { mod: string; id: string; slot: string; lines: Line[] }
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    // Everything the stand-in uses is inside register: the kit loads it as a module of its own.
    const READER: Record<string, string[][]> = {
      "cat >> CLAUDE.md <<'EOF'\n- Never merge on Fridays.\nEOF": [['cat', '>>', 'CLAUDE.md', '<<EOF'], ['-', 'Never', 'merge', 'on', 'Fridays.']],
      'ls -la': [['ls', '-la']],
    }
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ref = { plugin: 'mod-kit', key: 'band' } as never
      const rows = async () => (((await built.state.get(ref)) as { value?: Row[] }).value ?? [])
      const modkit = {
        commands: async ({ command }: { command: string }) => READER[command] ?? [command.split(' ')],
        bandRow: async (row: Row) => {
          // A test makes the band refuse a row through the environment, the one thing it can set here.
          if ((await built.env.get('BAND_REFUSES')) === '1') throw new Error('a band row needs a mod and an id')
          await built.state.set(ref, [...(await rows()).filter(r => !(r.mod === row.mod && r.id === row.id)), row] as never)
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
          await built.state.set(ref, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
        },
      }
      return { ...built, modkit } as never
    })
    on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
      const rows = ((await $.state.get({ plugin: 'mod-kit', key: 'band' } as never)) as { value?: Row[] }).value ?? []
      if (!rows.length) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      return (
        <Box flexDirection="column">
          {rows.flatMap(r =>
            r.lines.map((l, n) =>
              Array.isArray(l) ? (
                <Box key={`${r.id}${n}`} flexDirection="row">
                  {l.map((p, i) =>
                    p.button ? (
                      <Button key={`${r.mod}:${p.button}`} label={p.label as string} onPress={() => undefined} />
                    ) : (
                      <Text key={String(i)} color={p.color} dimColor={p.dim}>
                        {p.text}
                      </Text>
                    ),
                  )}
                </Box>
              ) : (
                <Text key={`${r.id}${n}`}>---</Text>
              ),
            ),
          )}
        </Box>
      )
    })
  },
}
// The notes Claude reads. A plugin's own $.session.append reaches no hook in a test in 2.1.289, the
// test's or another plugin's (both measured 2026-10-04: "no implementation for session.append"), so
// every note fails here, and the mod's fallback for a note that cannot be added (a toast carrying
// the whole note, so Dan sees what Claude was not told) is how the test reads it.
const withKit = { plugins: [modKit] }
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
const call = async ($: Caller, input: Record<string, unknown>) =>
  (await $.tool.call({ tool_use_id: `t${Math.random()}`, ...input } as never)) as { deny?: string; text?: string; context?: readonly string[] }
const band = () => ({ plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 40, bodyColumns: 100, scroll: { offset: 0, bodyRows: 40 }, view: {} } }) as never
type Found = { text: string; children: unknown[] }
type Mounted = { findAll: (q: { type: string }) => Promise<Found[]>; press: (t: object) => Promise<unknown>; unmount: () => Promise<void> }
const shown = async (ui: Mounted) => (await ui.findAll({ type: 'Text' })).filter(t => t.children.every(c => typeof c === 'string')).map(t => t.text)
const mount = async ($: unknown) => (await ($ as { ui: { mount: (x: never) => Promise<unknown> } }).ui.mount(band())) as Mounted
const answer = async ($: unknown, button: string) => {
  const ui = await mount($)
  await ui.press({ key: `ask-before-saving:${button}` })
  await ui.unmount()
}
const dan = async ($: unknown, text: string) => {
  await ($ as { prompt: { submit: (x: never) => Promise<unknown> } }).prompt.submit({ text, origin: { kind: 'composer' } } as never)
}

test('a Write to a project CLAUDE.md is held: refused at once, and the band asks with the exact text and the file', withKit, async ($, on) => {
  const w = world(on)
  const r = await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '# Slate\n\n- Ask before merging.\n' })
  expect(w.ran).toEqual([])
  expect(r.deny).toContain('Dan is being asked')
  const ui = await mount($)
  expect(await shown(ui)).toEqual([
    'Standing rule',
    '  Save this as a standing rule?',
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
  expect(r.deny).toContain('Dan is being asked')
  const ui = await mount($)
  const lines = await shown(ui)
  expect(lines).toContain('- [b](b.md) just for now')
  expect(lines).toContain('~/.claude/projects/-Users-dan-Apps-slate/memory/MEMORY.md')
  await ui.unmount()
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
  expect(r.deny).toContain('Dan is being asked')
  const ui = await mount($)
  const lines = await shown(ui)
  expect(lines).toContain('- Never merge on Fridays.')
  expect(lines).toContain('~/Apps/slate/CLAUDE.md')
  await ui.unmount()
})

test('a write anywhere else, and a Bash call that writes nothing, go straight through', withKit, async ($, on) => {
  const w = world(on)
  await call($, { tool: 'Write', file_path: 'README.md', content: 'x' })
  await call($, { tool: 'Bash', command: 'ls -la' })
  expect(w.ran.map(r => r.tool)).toEqual(['Write', 'Bash'])
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
  expect(again.deny).toContain('Dan is being asked')
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
  expect(r.deny).toContain('Dan is being asked')
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

test('a question the band cannot show still refuses the save, and says why', withKit, async ($, on) => {
  const w = world(on, { bandRefuses: true })
  const r = await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- rule\n' })
  expect(w.ran).toEqual([])
  expect(r.deny).toContain('could not be shown')
  expect(w.toasts.join('\n')).toContain('could not be shown')
})

test('a save the mod cannot judge is refused, never let through: a failing hook fails closed', withKit, async ($, on) => {
  const w = world(on, { cwdFails: true })
  const r = await call($, { tool: 'Write', file_path: '/anywhere/CLAUDE.md', content: '- rule\n' })
  expect(w.ran).toEqual([])
  expect(r.deny).toContain('could not check')
})
