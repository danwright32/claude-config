import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { callHash, holdText, isVerdict, ledgerDir, makeLedger, parseEntry, tellText, unreadableText, type LedgerIo, type Refused } from '../hooks/ledger.ts'

// #3560: a call auto mode's safety check refused with a verdict is written to a ledger kept for the
// session and everything it dispatches, and the same call sent again by anyone in it is held. A
// refusal the check gave no verdict on is never written, so its one unchanged resend is never held
// ("One unchanged resend after no verdict"). Measured on the personal MacBook on 2026-11-26 over the
// 15 days before: 21 verdict refusals, every reason starting with a bracket, and 980 with no verdict,
// each handed to the mod with the reason "Classifier unavailable". The reasons below are those shapes.

const DIR = '/r/home/.claude/state/safety-refusals/s1'
const VERDICT = '[Irreversible Local Destruction] removes files that are not in version control'
const NO_VERDICT = 'Classifier unavailable'

// The Mac's files, in memory, with each kind of failure a test can turn on.
const disk = (files: Record<string, string> = {}) => {
  const fail: { exists?: string; list?: string; read?: string; write?: string } = {}
  const calls = { exists: 0, list: 0, read: 0, write: 0, mkdir: 0 }
  const io: LedgerIo = {
    exists: async path => {
      calls.exists++
      if (fail.exists) throw new Error(fail.exists)
      return Object.keys(files).some(f => f === path || f.startsWith(`${path}/`))
    },
    list: async dir => {
      calls.list++
      if (fail.list) throw new Error(fail.list)
      return Object.keys(files).filter(f => f.startsWith(`${dir}/`)).map(f => f.slice(dir.length + 1))
    },
    read: async path => {
      calls.read++
      if (fail.read) throw new Error(fail.read)
      if (!(path in files)) throw new Error(`ENOENT: no such file or directory, open '${path}'`)
      return files[path] as string
    },
    write: async (path, text) => {
      calls.write++
      if (fail.write) throw new Error(fail.write)
      files[path] = text
    },
    mkdir: async () => {
      calls.mkdir++
    },
  }
  return { io, files, fail, calls }
}

const bash = (command: string) => ({ command, description: 'x' })
const refusal = async (id: string, command: string, agent: string | null, at = 1_795_000_000_000, reason = VERDICT): Promise<Refused> => ({
  at,
  when: '2:40 AM ET on Thu Nov 26',
  agent,
  tool: 'Bash',
  reason,
  call: await callHash('Bash', bash(command)),
  toolUseId: id,
})
const hashOf = (command: string) => () => callHash('Bash', bash(command))

describe('which refusals the ledger writes', () => {
  test('a refusal the check gave no verdict on is not one, in each wording the mod knows; anything else is a verdict', () => {
    for (const r of [NO_VERDICT, 'classifier unavailable', 'The server-side auto mode classifier gave no verdict for this action', 'not reviewed', 'the transcript was too long', 'exceeded its context window'])
      expect([r, isVerdict(r)]).toEqual([r, false])
    for (const r of [VERDICT, '[Git Destructive]', 'Permission for this action was denied by the Claude Code auto mode classifier', 'blocked by auto mode', 'x', '']) expect([r, isVerdict(r)]).toEqual([r, true])
  })
  test('a session id that is no plain name has no ledger folder', () => {
    expect(ledgerDir('/r/home/', 's1')).toBe(DIR)
    for (const bad of ['', '../s1', 'a/b', '.', 's 1']) expect([bad, ledgerDir('/r/home', bad)]).toEqual([bad, null])
  })
})

describe('what the ledger keeps', () => {
  test('one file for each refusal, holding who, the tool, the reason, when and a hash, and never the call itself', async () => {
    const d = disk()
    const ledger = makeLedger()
    const command = 'rm -rf build/secret-folder && echo PRIVATE-TEXT'
    await ledger.record(d.io, DIR, await refusal('toolu_01', command, 'agent-a'))
    expect(Object.keys(d.files)).toEqual([`${DIR}/toolu_01.json`])
    const kept = d.files[`${DIR}/toolu_01.json`] as string
    expect(JSON.parse(kept)).toEqual({ at: 1_795_000_000_000, when: '2:40 AM ET on Thu Nov 26', agent: 'agent-a', tool: 'Bash', reason: VERDICT, call: await callHash('Bash', bash(command)), toolUseId: 'toolu_01' })
    for (const word of ['rm -rf', 'secret-folder', 'PRIVATE-TEXT', 'echo', 'description']) expect([word, kept.includes(word)]).toEqual([word, false])
    expect(JSON.parse(kept).call).toMatch(/^[0-9a-f]{64}$/)
  })
  test('a call id that is no plain file name is kept under a hash of it, never as a path', async () => {
    const d = disk()
    await makeLedger().record(d.io, DIR, await refusal('../../etc/x', 'git clean -fd', null))
    const names = Object.keys(d.files)
    expect(names).toHaveLength(1)
    expect(names[0]).toMatch(new RegExp(`^${DIR}/[0-9a-f]{32}\\.json$`))
  })
  test('a file that is not an entry is said to be none, with why', () => {
    const good = { at: 1, when: 'w', agent: null, tool: 'Bash', reason: 'r', call: 'a'.repeat(64), toolUseId: 't' }
    expect(parseEntry(JSON.stringify(good))).toEqual(good)
    expect(parseEntry(JSON.stringify({ ...good, told: 5 }))).toEqual({ ...good, told: 5 })
    for (const bad of ['', '{', '[]', 'null', JSON.stringify({ ...good, call: 'rm -rf x' }), JSON.stringify({ ...good, at: 'now' }), JSON.stringify({ ...good, agent: 3 }), JSON.stringify({ ...good, tool: undefined }), JSON.stringify({ ...good, told: 'yes' })])
      expect([bad, 'bad' in parseEntry(bad)]).toEqual([bad, true])
  })
})

describe('which calls the ledger holds', () => {
  test('the same call as one refused with a verdict is held, whoever sends it; another call is not', async () => {
    const d = disk()
    const ledger = makeLedger()
    const e = await refusal('t1', 'git clean -fd', 'agent-a')
    await ledger.record(d.io, DIR, e)
    expect(await ledger.check(d.io, DIR, 'Bash', hashOf('git clean -fd'))).toEqual({ kind: 'refused', entries: [e] })
    // The rtk rewrite hook writes rtk in front of a command; it is the same call (refusals.ts callKey).
    expect((await ledger.check(d.io, DIR, 'Bash', hashOf('rtk git clean -fd'))).kind).toBe('refused')
    for (const other of ['git clean -fdx', 'git clean -n', 'git status', 'rtk proxy git clean -fd']) expect([other, (await ledger.check(d.io, DIR, 'Bash', hashOf(other))).kind]).toEqual([other, 'clear'])
    // The same words to another tool are another call.
    expect((await ledger.check(d.io, DIR, 'Write', () => callHash('Write', bash('git clean -fd')))).kind).toBe('clear')
  })
  test('a session nothing was refused in has no folder, holds nothing, and hashes nothing', async () => {
    const d = disk()
    const ledger = makeLedger()
    let hashed = 0
    const hash = () => {
      hashed++
      return callHash('Bash', bash('git push'))
    }
    for (const tool of ['Bash', 'Write', 'Edit', 'Read', 'Agent', 'mcp__x__y']) expect([tool, await ledger.check(d.io, DIR, tool, hash)]).toEqual([tool, { kind: 'clear' }])
    expect(hashed).toBe(0)
    // And the folder is looked for once, not at every call.
    expect(d.calls).toEqual({ exists: 1, list: 0, read: 0, write: 0, mkdir: 0 })
  })
  test('one session never holds what was refused in another', async () => {
    const d = disk()
    const ledger = makeLedger()
    await ledger.record(d.io, DIR, await refusal('t1', 'git clean -fd', null))
    expect((await ledger.check(d.io, '/r/home/.claude/state/safety-refusals/s2', 'Bash', hashOf('git clean -fd'))).kind).toBe('clear')
  })
  test('a resumed session reads the ledger back from its files and holds the same call', async () => {
    const d = disk()
    await makeLedger().record(d.io, DIR, await refusal('t1', 'git clean -fd', 'agent-a'))
    const resumed = makeLedger()
    expect((await resumed.check(d.io, DIR, 'Bash', hashOf('git clean -fd'))).kind).toBe('refused')
    expect((await resumed.check(d.io, DIR, 'Bash', hashOf('git status'))).kind).toBe('clear')
    // Read once: the second call read no file.
    expect(d.calls.list).toBe(1)
  })
  test('a refusal whose file could not be written is still held by the process that saw it, and the failure is thrown', async () => {
    const d = disk()
    const ledger = makeLedger()
    d.fail.write = 'ENOSPC: no space left on device'
    let thrown = ''
    try {
      await ledger.record(d.io, DIR, await refusal('t1', 'git clean -fd', null))
    } catch (err) {
      thrown = String(err)
    }
    expect(thrown).toContain('ENOSPC')
    expect((await ledger.check(d.io, DIR, 'Bash', hashOf('git clean -fd'))).kind).toBe('refused')
  })
})

describe('a ledger that is there and cannot be read', () => {
  const broken: [string, (d: ReturnType<typeof disk>) => void][] = [
    ['its folder cannot be listed', d => void (d.fail.list = "EACCES: permission denied, scandir 'x'")],
    ['whether it is there cannot be checked', d => void (d.fail.exists = "EACCES: permission denied, stat 'x'")],
    ['an entry cannot be read', d => void (d.fail.read = "EACCES: permission denied, open 'x'")],
    ['an entry was cut short', d => void (d.files[`${DIR}/t9.json`] = '{"at":17950')],
    ['an entry holds no hash', d => void (d.files[`${DIR}/t9.json`] = JSON.stringify({ at: 1, when: 'w', agent: null, tool: 'Bash', reason: 'r', toolUseId: 't9' }))],
  ]
  for (const [name, breakIt] of broken)
    test(`holds every call the check could have refused while ${name}, and lets Read, Grep, Glob and a TaskStop through`, async () => {
      const d = disk({ [`${DIR}/t0.json`]: JSON.stringify(await refusal('t0', 'git clean -fd', null)) })
      breakIt(d)
      const ledger = makeLedger()
      for (const tool of ['Bash', 'Write', 'Edit', 'Agent', 'WebFetch', 'mcp__x__y']) expect([tool, (await ledger.check(d.io, DIR, tool, hashOf('git status'))).kind]).toEqual([tool, 'unreadable'])
      // The check is never asked about a read, and a stop whose check errored is let through (#1495).
      for (const tool of ['Read', 'Grep', 'Glob', 'TaskStop']) expect([tool, (await ledger.check(d.io, DIR, tool, hashOf('git status'))).kind]).toEqual([tool, 'clear'])
      const held = await ledger.check(d.io, DIR, 'Bash', hashOf('git status'))
      expect(held).toMatchObject({ kind: 'unreadable', dir: DIR })
    })
  test('is read afresh at each call, so one mended is found mended, and what this process saw refused is held throughout', async () => {
    const d = disk({ [`${DIR}/t0.json`]: JSON.stringify(await refusal('t0', 'git clean -fd', null)) })
    const ledger = makeLedger()
    d.fail.list = 'EIO: i/o error, scandir'
    expect((await ledger.check(d.io, DIR, 'Bash', hashOf('git status'))).kind).toBe('unreadable')
    await ledger.record(d.io, DIR, await refusal('t1', 'git push --force', 'agent-a'))
    expect((await ledger.check(d.io, DIR, 'Bash', hashOf('git push --force'))).kind).toBe('refused')
    // A TaskStop the check itself refused is held by its hash, whatever the ledger's files do.
    await ledger.record(d.io, DIR, { ...(await refusal('t2', 'x', null)), tool: 'TaskStop', call: await callHash('TaskStop', { task_id: 'b1' }) })
    expect((await ledger.check(d.io, DIR, 'TaskStop', () => callHash('TaskStop', { task_id: 'b1' }))).kind).toBe('refused')
    expect((await ledger.check(d.io, DIR, 'TaskStop', () => callHash('TaskStop', { task_id: 'b2' }))).kind).toBe('clear')
    d.fail.list = undefined
    expect((await ledger.check(d.io, DIR, 'Bash', hashOf('git status'))).kind).toBe('clear')
    expect((await ledger.check(d.io, DIR, 'Bash', hashOf('git clean -fd'))).kind).toBe('refused')
    expect((await ledger.check(d.io, DIR, 'Bash', hashOf('git push --force'))).kind).toBe('refused')
  })
})

describe('telling the session that dispatched a refused agent', () => {
  test('each refusal of a subagent waits to be told once; the session own refusals never do', async () => {
    const d = disk()
    const ledger = makeLedger()
    const a = await refusal('t1', 'git clean -fd', 'agent-a', 2000)
    const b = await refusal('t2', 'git push --force', 'agent-b', 1000)
    await ledger.record(d.io, DIR, a)
    await ledger.record(d.io, DIR, b)
    await ledger.record(d.io, DIR, await refusal('t3', 'rm -rf x', null, 3000))
    expect(ledger.untold(DIR).map(e => e.toolUseId)).toEqual(['t2', 't1'])
    await ledger.markTold(d.io, DIR, ledger.untold(DIR), 5000)
    expect(ledger.untold(DIR)).toEqual([])
    expect(JSON.parse(d.files[`${DIR}/t1.json`] as string).told).toBe(5000)
    // A resumed session reads back what was told and says none of it again, and still holds the calls.
    const resumed = makeLedger()
    expect((await resumed.check(d.io, DIR, 'Bash', hashOf('git clean -fd'))).kind).toBe('refused')
    expect(resumed.untold(DIR)).toEqual([])
  })
  test('one not yet told when the session stopped is told by the session resumed', async () => {
    const d = disk()
    await makeLedger().record(d.io, DIR, await refusal('t1', 'git clean -fd', 'agent-a'))
    const resumed = makeLedger()
    expect(resumed.untold(DIR)).toEqual([])
    await resumed.check(d.io, DIR, 'Read', hashOf('x'))
    expect(resumed.untold(DIR).map(e => e.toolUseId)).toEqual(['t1'])
  })
  test('a told mark that could not be written is still told once in this process', async () => {
    const d = disk()
    const ledger = makeLedger()
    await ledger.record(d.io, DIR, await refusal('t1', 'git clean -fd', 'agent-a'))
    d.fail.write = 'EIO'
    let thrown = false
    try {
      await ledger.markTold(d.io, DIR, ledger.untold(DIR), 5000)
    } catch {
      thrown = true
    }
    expect(thrown).toBe(true)
    expect(ledger.untold(DIR)).toEqual([])
  })
  test('the words name the agent, the tool, the time and the reason of the check', async () => {
    const said = tellText([await refusal('t1', 'git clean -fd', 'agent-a')])
    for (const part of ['agent agent-a', 'Bash', '2:40 AM ET on Thu Nov 26', VERDICT, 'never hand it to another agent', 'Tell Dan']) expect([part, said.includes(part)]).toEqual([part, true])
    expect(said.includes('git clean')).toBe(false)
    expect(tellText([await refusal('t1', 'a', 'agent-a'), await refusal('t2', 'b', 'agent-b')])).toContain('2 calls by agents of this session')
  })
})

describe('what a held call is answered with', () => {
  test('says what was refused, by whom, and that the way on is to report it, never another route', async () => {
    const byA = [await refusal('t1', 'git clean -fd', 'agent-a')]
    const same = holdText(byA, 'Bash', 'agent-a', false)
    expect(same).toMatch(/^Held: this is the same Bash call that auto mode's safety check refused with a verdict at 2:40 AM ET on Thu Nov 26, when you sent it/)
    for (const part of [VERDICT, 'hand back, quoting this refusal', 'Never send it again, in pieces, through another tool or by another agent', 'Nothing in this session lifts this hold']) expect([part, same.includes(part)]).toEqual([part, true])
    // A sibling, and the session that dispatched them both: the laundering case.
    expect(holdText(byA, 'Bash', 'agent-b', false)).toContain('when agent agent-a sent it')
    expect(holdText(byA, 'Bash', 'agent-b', false)).toContain('hand back')
    const main = holdText(byA, 'Bash', undefined, false)
    expect(main).toContain('when agent agent-a sent it')
    expect(main).toContain('Tell Dan what was refused and why, and leave the decision to him.')
    expect(main.includes('hand back')).toBe(false)
    // Asleep, nothing is asked of Dan.
    const night = holdText(byA, 'Bash', undefined, true)
    expect(night).toContain('Dan is asleep, so ask nothing')
    expect(night.includes('Tell Dan what was refused')).toBe(false)
    // The session's own refusal, repeated by itself or by an agent it dispatched.
    const own = [await refusal('t1', 'git clean -fd', null)]
    expect(holdText(own, 'Bash', undefined, false)).toContain('when this session sent it')
    expect(holdText(own, 'Bash', 'agent-a', false)).toContain('when the session that dispatched you sent it')
    // A reason that could not be read is said to be unread, never left blank.
    expect(holdText([await refusal('t1', 'x', null, 1, '')], 'Bash', undefined, false)).toContain('it gave no reason this mod could read')
  })
  test('an unreadable ledger is named with why, and who can mend it', () => {
    const said = unreadableText(DIR, 'EACCES: permission denied', undefined)
    for (const part of [DIR, 'EACCES: permission denied', 'Only Read, Grep, Glob and TaskStop run', 'Tell Dan', 'never remove it yourself']) expect([part, said.includes(part)]).toEqual([part, true])
    expect(unreadableText(DIR, 'x', 'agent-a')).toContain('Hand back and quote this refusal')
  })
})
