import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { ASKED_KEEP, type Asked, type AskedIo, askedDir, askedOf, dialogOf, ENGINE_CHIP, dialogOfCall, isOwnDialog, OWN_ASKERS, OWN_KEY, recordedAsk, resetAskedSaid, withDialog, withoutDialog } from '../hooks/asked.ts'
import { MAX_QUESTION } from '../hooks/shown.ts'

// A question a mod asks Dan through its own dialog is counted before any limit is put on it
// (#3321; Dan, 2026-11-21: "Record, then decide"): its size and which question it was, never a
// word of it. These hold the record's shape, that the question is asked whatever happens to the
// record, the bound on how many are kept, and that a record that cannot be kept is said.

type World = { files: Map<string, string>; ran: string[][]; asked: { question: string; options: unknown }[]; said: string[]; now: number; io: AskedIo; failWrite?: string; noDir?: boolean; home?: string | undefined; order: string[]; own: string[]; ownValue: readonly string[] | undefined; ownVersion: number; misses: number; failAsking?: string }
const world = (): World => {
  const w: World = { files: new Map(), ran: [], asked: [], said: [], now: 1_800_000_000_000, home: '/Users/x', io: undefined as never, order: [], own: [], ownValue: undefined, ownVersion: 0, misses: 0 }
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
    // The mod's own state for its open dialogs, as $.state keeps a value: with a version, written
    // only at the version read. `misses` makes that many writes miss, as another write in between does.
    own: {
      read: async () => {
        if (w.failAsking) throw new Error(w.failAsking)
        return { value: w.ownValue, version: w.ownVersion }
      },
      write: async (value, ifVersion) => {
        if (w.misses > 0) {
          w.misses--
          w.ownVersion++
          return { isSet: false }
        }
        if (ifVersion !== w.ownVersion) return { isSet: false }
        w.order.push(value.length > w.own.length ? 'kept' : 'taken back')
        w.own = [...value]
        w.ownValue = [...value]
        w.ownVersion++
        return { isSet: true }
      },
    },
    said: line => void w.said.push(line),
  }
  resetAskedSaid()
  return w
}
const records = (w: World): (Asked & { path: string })[] => [...w.files.entries()].map(([path, text]) => ({ ...(JSON.parse(text) as Asked), path }))

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
// asking mod says so itself: it keeps the dialog in its own $.state for as long as it is open.
// $.state is written by its owner alone, so a session, which has only tools, can put nothing there.
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

test('a call is a mod own dialog only while that very dialog is kept as open', () => {
  const dialog = dialogOf('o/r#7: Keep the old flag?', { options: ['Keep it', 'Drop it'], header: 'Before bed' })
  const kept = withDialog([], dialog)
  expect(isOwnDialog(kept, CALL)).toBe(true)
  // Nothing kept, another dialog kept, or a state that is no list of dialogs: a session's picker.
  expect(isOwnDialog([], CALL)).toBe(false)
  expect(isOwnDialog(undefined, CALL)).toBe(false)
  expect(isOwnDialog('x', CALL)).toBe(false)
  expect(isOwnDialog([{ dialog }], CALL)).toBe(false)
  expect(isOwnDialog(withDialog([], dialogOf('Another?', ['Yes', 'No'])), CALL)).toBe(false)
  expect(isOwnDialog(kept, { ...CALL, metadata: { source: 'x' } })).toBe(false)
  // Two of the same dialog open at once are kept twice, and one answered leaves the other.
  const twice = withDialog(kept, dialog)
  expect(twice.length).toBe(2)
  expect(isOwnDialog(withoutDialog(twice, dialog), CALL)).toBe(true)
  expect(withoutDialog(withoutDialog(twice, dialog), dialog)).toEqual([])
  // Taking back one never kept changes nothing.
  expect(withoutDialog(kept, 'another')).toEqual(kept)
  // The mods a reader looks at, and the key, are named once, here.
  expect([...OWN_ASKERS]).toEqual(['scope-modes', 'keystroke-guard'])
  expect(OWN_KEY).toBe('asking')
})

test('the mod keeps the dialog as its own before it asks, and takes it back once it is answered or dismissed', async () => {
  const w = world()
  expect(await recordedAsk(w.io, 'scope-modes', 'bedtime', 'Keep?', { options: ['Yes', 'No'], header: 'Before bed' })).toBe('Go ahead')
  expect(w.order).toEqual(['kept', 'ask', 'taken back'])
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

test('a write that misses because the state moved is made again, so no dialog is lost', async () => {
  const w = world()
  w.ownValue = ['another dialog, open at the same time']
  w.own = [...w.ownValue]
  w.misses = 3
  let during: string[] = []
  w.io = { ...w.io, ask: async () => { during = [...w.own]; return 'Go ahead' } }
  expect(await recordedAsk(w.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes', 'No'])).toBe('Go ahead')
  expect(during).toEqual(['another dialog, open at the same time', dialogOf('Keep?', ['Yes', 'No'])])
  expect(w.own).toEqual(['another dialog, open at the same time'])
})

test('a dialog that could not be said to be its own is asked all the same, said once, and nothing is taken back', async () => {
  const w = world()
  w.failAsking = 'the state could not be read'
  expect(await recordedAsk(w.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes', 'No'])).toBe('Go ahead')
  expect(await recordedAsk(w.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes', 'No'])).toBe('Go ahead')
  expect(w.order).toEqual(['ask', 'ask'])
  expect(w.said.length).toBe(1)
  expect(w.said[0]).toContain('scope-modes could not say a question it asked is its own (the state could not be read)')
  expect(w.said[0]).toContain('is refused')
  // A state that moves under every attempt is said the same way, and the question still asked.
  const m = world()
  m.misses = 99
  expect(await recordedAsk(m.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes', 'No'])).toBe('Go ahead')
  expect(m.said[0]).toContain('changed under every one of 10 attempts')
  // A taking back that fails never costs the answer.
  const v = world()
  const write = v.io.own.write
  let writes = 0
  v.io = { ...v.io, own: { read: v.io.own.read, write: async (value, ifVersion) => { if (++writes > 1) throw new Error('no state'); return write(value, ifVersion) } } }
  expect(await recordedAsk(v.io, 'scope-modes', 'bedtime', 'Keep?', ['Yes', 'No'])).toBe('Go ahead')
})
