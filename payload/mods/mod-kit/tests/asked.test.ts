import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { ASKED_KEEP, type AskedIo, askedDir, askedOf, recordedAsk, resetAskedSaid } from '../hooks/asked.ts'
import { MAX_QUESTION } from '../hooks/shown.ts'

// A question a mod asks Dan through its own dialog is counted before any limit is put on it
// (#3321; Dan, 2026-11-21: "Record, then decide"): its size and which question it was, never a
// word of it. These hold the record's shape, that the question is asked whatever happens to the
// record, the bound on how many are kept, and that a record that cannot be kept is said.

type World = { files: Map<string, string>; ran: string[][]; asked: { question: string; options: unknown }[]; said: string[]; now: number; io: AskedIo; failWrite?: string; noDir?: boolean; home?: string | undefined }
const world = (): World => {
  const w: World = { files: new Map(), ran: [], asked: [], said: [], now: 1_800_000_000_000, home: '/Users/x', io: undefined as never }
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
      w.asked.push({ question, options })
      return 'Go ahead'
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
