import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import type { Register } from 'claude-code'
import { ASKED_KEEP, type AskedIo, askedDir, askedOf, askingRefusal, dialogOf, ENGINE_CHIP, dialogOfCall, isOwnDialog, recordedAsk, resetAskedSaid, withAsking, withoutAsking } from '../hooks/asked.ts'
import { MAX_QUESTION } from '../hooks/shown.ts'

// A question a mod asks Dan through its own dialog is counted before any limit is put on it
// (#3321; Dan, 2026-11-21: "Record, then decide"): its size and which question it was, never a
// word of it. These hold the record's shape, that the question is asked whatever happens to the
// record, the bound on how many are kept, and that a record that cannot be kept is said.

type World = { files: Map<string, string>; ran: string[][]; asked: { question: string; options: unknown }[]; said: string[]; now: number; io: AskedIo; failWrite?: string; noDir?: boolean; home?: string | undefined; order: string[]; own: string[]; failAsking?: string }
const world = (): World => {
  const w: World = { files: new Map(), ran: [], asked: [], said: [], now: 1_800_000_000_000, home: '/Users/x', io: undefined as never, order: [], own: [] }
  w.io = {
    now: async () => w.now++,
    home: async () => w.home,
    write: async (path, text) => {
      if (w.failWrite) throw new Error(w.failWrite)
      if (w.noDir) throw new Error('ENOENT: no such folder')
      w.files.set(path, text)
    },
    list: async dir => [...w.files.keys()].filter(p => p.startsWith(`${dir}/`)).map(p => p.slice(dir.length + 1)),
    run: async argv => {
      w.ran.push(argv)
      if (argv[0] === 'mkdir') w.noDir = false
      if (argv[0] === 'rm') for (const p of argv.slice(3)) w.files.delete(p)
      return { exitCode: 0, stderr: '' }
    },
    ask: async (question, options) => {
      w.order.push('ask')
      w.asked.push({ question, options })
      return 'Go ahead'
    },
    asking: async dialog => {
      if (w.failAsking) throw new Error(w.failAsking)
      w.order.push('asking')
      w.own.push(dialog)
    },
    answered: async dialog => {
      w.order.push('answered')
      w.own.splice(w.own.indexOf(dialog), 1)
    },
    said: line => void w.said.push(line),
  }
  resetAskedSaid()
  return w
}
const records = (w: World) => [...w.files.entries()].map(([path, text]) => ({ path, ...(JSON.parse(text) as Record<string, unknown>) }))

test('the record holds sizes and which question, and never a word of it', async () => {
  const w = world()
  const question = "I'm about to type into Lightroom. Ready?"
  const answer = await recordedAsk(w.io, 'keystroke-guard', 'ready', question, { options: ['Go ahead', 'Not now'], header: 'Taking over' })
  expect(answer).toBe('Go ahead')
  expect(w.asked).toEqual([{ question, options: { options: ['Go ahead', 'Not now'], header: 'Taking over' } }])
  const { path, ...fields } = records(w)[0] as { path: string }
  expect(fields).toEqual({ at: 1_800_000_000_000, mod: 'keystroke-guard', which: 'ready', units: question.length, rows: 1, options: 2, longest: 8, header: 11, refused: false })
  expect(/^\/Users\/x\/\.claude\/state\/asked-questions\/1800000000000-[a-z0-9]+\.json$/.test(path)).toBe(true)
  expect(askedDir('/Users/x/')).toBe('/Users/x/.claude/state/asked-questions')
  const text = [...w.files.values()].join('\n')
  for (const word of ['Lightroom', 'Ready', 'Go ahead', 'Not now', 'Taking over']) expect(text).not.toContain(word)
  expect(w.said).toEqual([])
})

test('options given as a plain list are counted the same way, and none is counted as none', async () => {
  const w = world()
  await recordedAsk(w.io, 'scope-modes', 'left branch', 'Leave the branch as it is?', ['Leave it as it is', 'Clean it up'])
  await recordedAsk(w.io, 'scope-modes', 'bare', 'Anything?')
  expect(records(w).map(r => [r.which, r.options, r.longest, r.header])).toEqual([['left branch', 2, 17, 0], ['bare', 0, 0, 0]])
  expect(w.asked.map(a => a.options)).toEqual([['Leave it as it is', 'Clean it up'], undefined])
})

test('what the shared check would refuse is recorded as refused, and is asked all the same', async () => {
  const w = world()
  const long = `${'word '.repeat(MAX_QUESTION / 5)}more?`
  expect(askedOf('scope-modes', 'bedtime', long, undefined, 5)).toEqual({ at: 5, mod: 'scope-modes', which: 'bedtime', units: long.length, rows: askedOf('m', 'w', long, undefined, 0).rows, options: 0, longest: 0, header: 0, refused: true })
  expect(askedOf('m', 'w', long, undefined, 0).rows).toBeGreaterThan(20)
  const hidden = `Keep the old${String.fromCodePoint(0x200b)} flag?`
  expect(await recordedAsk(w.io, 'scope-modes', 'bedtime', hidden, { options: ['Keep it'], header: 'Before bed' })).toBe('Go ahead')
  expect(records(w).map(r => r.refused)).toEqual([true])
  expect(w.asked.map(a => a.question)).toEqual([hidden])
  // An option the check would refuse counts too: the dialog draws it.
  expect(askedOf('m', 'w', 'Plain?', ['<tag>'], 0).refused).toBe(true)
})

test('a folder that is not there yet is made, and the record written', async () => {
  const w = world()
  w.noDir = true
  await recordedAsk(w.io, 'scope-modes', 'no build', 'Switch to build?', ['Yes', 'No'])
  expect(w.ran).toEqual([['mkdir', '-p', askedDir('/Users/x')]])
  expect(records(w).map(r => r.which)).toEqual(['no build'])
  expect(w.said).toEqual([])
})

test('a record that cannot be kept is said once a session, and the question is still asked', async () => {
  const w = world()
  w.failWrite = 'EACCES: permission denied'
  expect(await recordedAsk(w.io, 'keystroke-guard', 'ready', 'Ready?', ['Go ahead'])).toBe('Go ahead')
  expect(await recordedAsk(w.io, 'keystroke-guard', 'ready', 'Ready again?', ['Go ahead'])).toBe('Go ahead')
  expect(w.asked.map(a => a.question)).toEqual(['Ready?', 'Ready again?'])
  expect(w.said.length).toBe(1)
  expect(w.said[0]).toContain('keystroke-guard could not record the size of a question it asked')
  expect(w.said[0]).toContain('EACCES: permission denied')
  expect(w.said[0]).not.toContain('Ready?')
  // No home to keep it under is a reason of its own (L11).
  const v = world()
  v.home = undefined
  await recordedAsk(v.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes'])
  expect(v.said[0]).toContain('HOME is not set')
  expect(v.asked.length).toBe(1)
})

test('a failure of the record itself never stops the question, whatever throws', async () => {
  const w = world()
  w.io = { ...w.io, now: async () => { throw new Error('no clock') } }
  expect(await recordedAsk(w.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes'])).toBe('Go ahead')
  expect(w.said[0]).toContain('no clock')
  const v = world()
  v.io = { ...v.io, said: () => { throw new Error('no log') }, home: async () => undefined }
  expect(await recordedAsk(v.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes'])).toBe('Go ahead')
})

test('a dismissed dialog rejects as it always did, with its record kept', async () => {
  const w = world()
  w.io = { ...w.io, ask: async () => { throw new Error('dismissed') } }
  let failed = ''
  await recordedAsk(w.io, 'scope-modes', 'left open', 'Leave it open?', ['Yes']).catch((err: unknown) => { failed = String(err) })
  expect(failed).toContain('dismissed')
  expect(records(w).length).toBe(1)
})

test('the folder is bounded: past the most kept, the oldest go, and only files this wrote', async () => {
  const w = world()
  const dir = askedDir('/Users/x')
  for (let k = 0; k < ASKED_KEEP + 2; k++) w.files.set(`${dir}/${1_700_000_000_000 + k}-seed${k}.json`, '{}')
  w.files.set(`${dir}/notes.txt`, 'not a record')
  w.files.set(`${dir}/README`, 'not a record')
  await recordedAsk(w.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes'])
  const names = [...w.files.keys()].map(p => p.slice(dir.length + 1))
  expect(names.filter(n => n.endsWith('.json')).length).toBe(ASKED_KEEP)
  expect(names).toContain('notes.txt')
  expect(names).toContain('README')
  // The three oldest went, the newest stayed.
  for (const k of [0, 1, 2]) expect(names).not.toContain(`${1_700_000_000_000 + k}-seed${k}.json`)
  expect(names).toContain(`${1_700_000_000_000 + 3}-seed3.json`)
  expect(names.some(n => n.startsWith('1800000000000-'))).toBe(true)
  const rm = w.ran.find(a => a[0] === 'rm') as string[]
  expect(rm.slice(0, 3)).toEqual(['rm', '-f', '--'])
  expect(rm.slice(3).every(p => p.startsWith(`${dir}/17000000000`))).toBe(true)
})

// #3321: a question a mod asks through its own dialog reaches every hook on AskUserQuestion like a
// session's picker, with nothing on it saying a mod raised it (seen on Claude Code 2.1.330). So the
// asking mod says so first, through mod-kit ($.modkit.asking), which keeps the dialog in its own
// $.state until it is answered. $.state is written by its owner alone and a noun is called by a
// mod's code alone, so a session, which has only tools, can put nothing there.
const CALL = { tool: 'AskUserQuestion', tool_use_id: 'toolu_x', questions: [{ question: 'o/r#7: Keep the old flag?', header: 'Before bed', options: [{ label: 'Keep it', description: '' }, { label: 'Drop it', description: '' }], multiSelect: false }] }

test('a dialog reads the same from what the mod asked and from the call a hook is handed', () => {
  const asked = dialogOf('o/r#7: Keep the old flag?', { options: ['Keep it', 'Drop it'], header: 'Before bed' })
  expect(dialogOfCall(CALL)).toBe(asked)
  // Answers given as a plain list carry no chip of the mod's, and the engine puts its own over
  // them (seen on Claude Code 2.1.330): the call a hook gets carries that one.
  const plain = { ...CALL, questions: [{ question: 'Leave it open?', header: ENGINE_CHIP, options: [{ label: 'Yes', description: '' }, { label: 'No', description: '' }], multiSelect: false }] }
  expect(dialogOfCall(plain)).toBe(dialogOf('Leave it open?', ['Yes', 'No']))
  expect(dialogOfCall(plain)).toBe(dialogOf('Leave it open?', { options: ['Yes', 'No'] }))
  expect(dialogOfCall({ ...CALL, questions: [{ question: 'Leave it open?', options: [{ label: 'Yes', description: '' }, { label: 'No', description: '' }], multiSelect: false }] })).not.toBe(dialogOf('Leave it open?', ['Yes', 'No']))
  // Any difference is another dialog: a word, an answer, the chip, several answers at once.
  const q = CALL.questions[0] as (typeof CALL.questions)[0]
  for (const other of [
    { ...q, question: 'o/r#7: Keep the new flag?' },
    { ...q, options: [...q.options, { label: 'Both', description: '' }] },
    { ...q, header: 'Bedtime' },
    { ...q, multiSelect: true },
  ])
    expect(dialogOfCall({ ...CALL, questions: [other] })).not.toBe(asked)
})

test("a call shaped as no mod's own dialog is never read as one", () => {
  const q = CALL.questions[0] as (typeof CALL.questions)[0]
  // What a session's picker can carry and a mod's own dialog never does.
  expect(dialogOfCall({ ...CALL, metadata: { source: 'scope-modes' } })).toBeUndefined()
  expect(dialogOfCall({ ...CALL, questions: [q, q] })).toBeUndefined()
  expect(dialogOfCall({ ...CALL, questions: [{ ...q, options: [{ label: 'Keep it', description: 'A long word about it.' }, { label: 'Drop it', description: '' }] }] })).toBeUndefined()
  expect(dialogOfCall({ ...CALL, questions: [{ ...q, preview: 'x' }] })).toBeUndefined()
  expect(dialogOfCall({ ...CALL, title: 'Beside it' })).toBeUndefined()
  expect(dialogOfCall({ ...CALL, questions: [] })).toBeUndefined()
  expect(dialogOfCall({ ...CALL, questions: 'x' })).toBeUndefined()
  expect(dialogOfCall({})).toBeUndefined()
})

test('a call is a mod own dialog only while that very dialog is kept as being asked', () => {
  const dialog = dialogOf('o/r#7: Keep the old flag?', { options: ['Keep it', 'Drop it'], header: 'Before bed' })
  const kept = withAsking([], { mod: 'scope-modes', dialog })
  expect(isOwnDialog(kept, CALL)).toBe(true)
  // Nothing kept, another dialog kept, or a state that is not a list: a session's picker.
  expect(isOwnDialog([], CALL)).toBe(false)
  expect(isOwnDialog(undefined, CALL)).toBe(false)
  expect(isOwnDialog('x' as never, CALL)).toBe(false)
  expect(isOwnDialog(withAsking([], { mod: 'scope-modes', dialog: dialogOf('Another?', ['Yes', 'No']) }), CALL)).toBe(false)
  expect(isOwnDialog(kept, { ...CALL, metadata: { source: 'x' } })).toBe(false)
  // Two of the same dialog open at once are kept twice, and one answered leaves the other.
  const twice = withAsking(kept, { mod: 'scope-modes', dialog })
  expect(twice.length).toBe(2)
  expect(isOwnDialog(withoutAsking(twice, { mod: 'scope-modes', dialog }), CALL)).toBe(true)
  expect(withoutAsking(withoutAsking(twice, { mod: 'scope-modes', dialog }), { mod: 'scope-modes', dialog })).toEqual([])
  // Another mod's entry for the same words is its own, and taking back one never kept changes nothing.
  expect(withoutAsking(kept, { mod: 'keystroke-guard', dialog })).toEqual(kept)
  expect(askingRefusal({ mod: 'scope-modes', dialog })).toBeUndefined()
  expect(askingRefusal({ mod: '', dialog })).toContain('needs mod and dialog')
  expect(askingRefusal({ mod: 'scope-modes', dialog: 7 })).toContain('needs mod and dialog')
  expect(askingRefusal(undefined)).toContain('needs mod and dialog')
})

test('the mod says the dialog is its own before it asks, and takes that back once it is answered or dismissed', async () => {
  const w = world()
  expect(await recordedAsk(w.io, 'scope-modes', 'bedtime', 'Keep?', { options: ['Yes', 'No'], header: 'Before bed' })).toBe('Go ahead')
  expect(w.order).toEqual(['asking', 'ask', 'answered'])
  expect(w.own).toEqual([])
  const v = world()
  let during: string[] = []
  v.io = { ...v.io, ask: async () => { during = [...v.own]; throw new Error('dismissed') } }
  let failed = ''
  await recordedAsk(v.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes', 'No']).catch((err: unknown) => { failed = String(err) })
  expect(failed).toContain('dismissed')
  expect(during).toEqual([dialogOf('Keep?', ['Yes', 'No'])])
  expect(v.own).toEqual([])
})

test('a dialog that could not be said to be its own is asked all the same, said once, and nothing is taken back', async () => {
  const w = world()
  w.failAsking = '$.modkit.asking is not a function'
  expect(await recordedAsk(w.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes', 'No'])).toBe('Go ahead')
  expect(await recordedAsk(w.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes', 'No'])).toBe('Go ahead')
  expect(w.order).toEqual(['ask', 'ask'])
  expect(w.said.length).toBe(1)
  expect(w.said[0]).toContain('scope-modes could not say a question it asked is its own ($.modkit.asking is not a function)')
  expect(w.said[0]).toContain('is refused')
  // A taking back that fails never costs the answer.
  const v = world()
  v.io = { ...v.io, answered: async () => { throw new Error('no state') } }
  expect(await recordedAsk(v.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes', 'No'])).toBe('Go ahead')
})

// The nouns themselves, called from another plugin as a mod calls them, and the state read as
// picker manners reads it. A plugin in a test runs apart from this module, so the stand in is
// driven by Bash commands and answers through its refusal.
const asker: { name: string; register: Register } = {
  name: 'asker',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      const [verb, ...rest] = String((e as { command?: string }).command).split(' ')
      const input = rest.length ? JSON.parse(rest.join(' ')) : undefined
      try {
        if (verb === 'asking') await $.modkit.asking(input)
        if (verb === 'answered') await $.modkit.answered(input)
        // What only mod-kit may do: the engine refuses another plugin's write of its state.
        if (verb === 'forge') await $.state.set({ plugin: 'mod-kit', key: 'asking' } as never, input as never)
      } catch (err) {
        return { deny: `threw: ${err instanceof Error ? err.message : String(err)}` }
      }
      return { deny: JSON.stringify((await $.state.get({ plugin: 'mod-kit', key: 'asking' })).value ?? null) }
    })
  },
}

test('$.modkit.asking keeps a dialog as being asked until $.modkit.answered, and only mod-kit can write it', { plugins: [asker] }, async $ => {
  const run = async (command: string) => String(((await $.tool.call({ tool: 'Bash', command } as never)) as { deny?: string }).deny)
  const one = { mod: 'scope-modes', dialog: dialogOf('Keep?', ['Yes', 'No']) }
  const two = { mod: 'keystroke-guard', dialog: dialogOf('Ready?', ['Go ahead', 'Not now']) }
  expect(await run('read')).toBe('null')
  expect(JSON.parse(await run(`asking ${JSON.stringify(one)}`))).toEqual([one])
  expect(JSON.parse(await run(`asking ${JSON.stringify(two)}`))).toEqual([one, two])
  expect(JSON.parse(await run(`asking ${JSON.stringify(one)}`))).toEqual([one, two, one])
  expect(JSON.parse(await run(`answered ${JSON.stringify(one)}`))).toEqual([two, one])
  expect(JSON.parse(await run(`answered ${JSON.stringify(two)}`))).toEqual([one])
  expect(JSON.parse(await run(`answered ${JSON.stringify(one)}`))).toEqual([])
  // One never kept is fine to take back; an input missing a part is refused by name.
  expect(JSON.parse(await run(`answered ${JSON.stringify(one)}`))).toEqual([])
  expect(await run(`asking ${JSON.stringify({ mod: 'scope-modes' })}`)).toContain('threw: ')
  expect(await run(`asking ${JSON.stringify({ mod: 'scope-modes' })}`)).toContain('$.modkit.asking needs mod and dialog')
  // The guarantee the whole mark rests on, measured: a plugin that is not mod-kit cannot write it.
  expect(await run(`forge ${JSON.stringify([one])}`)).toContain('threw: ')
  expect(await run('read')).toBe('[]')
})
