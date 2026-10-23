import { describe, expect, test } from 'claude-code/testing'
import { PROSE_MARK, TURN_BYTES, turnAt, turnIn, type TurnRun } from '../hooks/turn.ts'

// #1608: every message Claude wrote since the turn began, read from the tail of the transcript, so a
// step handed over in an earlier message of the turn is judged as well as the last one. The reader
// keeps only what the reader needs: Claude's text records whole, and each user record cut down to
// its promptId and whether it carries this mod's own block.

// The records as the reader prints them (Claude Code's own shape, measured 2026-10-23: every record
// of a turn that Dan's prompt started carries that prompt's promptId, Stop hook feedback included).
const said = (text: string, extra: Record<string, unknown> = {}) =>
  JSON.stringify({ type: 'assistant', isSidechain: false, message: { role: 'assistant', content: [{ type: 'text', text }] }, ...extra })
const user = (promptId?: string, isOurs = false) => JSON.stringify({ type: 'user', ...(promptId ? { promptId } : {}), isOurs })
const tool = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'ls' } }] } })

describe('turnIn', () => {
  test('reads every text Claude wrote since the prompt, oldest first, and none from the turn before', () => {
    const out = [
      user('p1'), said('An earlier turn, already judged at its own end.'),
      user('p2'), said('One thing is still yours to do.'), tool, user('p2'), said('Done with the rest.'),
    ].join('\n')
    expect(turnIn(out)).toEqual({ texts: ['One thing is still yours to do.', 'Done with the rest.'], isOurs: false, promptId: 'p2' })
  })

  test('Stop hook feedback keeps the prompt\'s promptId, so a reflection after it is the same turn', () => {
    const out = [user('p1'), said('the step'), user('p1'), said('the reflection')].join('\n')
    expect(turnIn(out).texts).toEqual(['the step', 'the reflection'])
  })

  test('a turn whose prompt lies before the window is read from the window\'s start', () => {
    // The first line is cut by the byte window and is not a record.
    const out = ['cut":"short"}', said('early in the turn'), user('p9'), said('later')].join('\n')
    expect(turnIn(out).texts).toEqual(['early in the turn', 'later'])
  })

  test('a window holding no prompt record names no prompt, so the turn it read cannot be told from nothing read', () => {
    expect(turnIn([said('a'), said('b')].join('\n'))).toEqual({ texts: ['a', 'b'], isOurs: false, promptId: null })
    expect(turnIn('')).toEqual({ texts: [], isOurs: false, promptId: null })
  })

  test('this mod\'s own block already given in the turn is reported, so it is never given twice', () => {
    expect(turnIn([user('p1'), said('a'), user('p1', true), said('b')].join('\n')).isOurs).toBe(true)
    // One given in the turn before does not count.
    expect(turnIn([user('p0', true), said('a'), user('p1'), said('b')].join('\n')).isOurs).toBe(false)
  })

  test('a user record with no promptId, an unparsable line, a subagent\'s record and a text in no record are passed over', () => {
    const out = [user('p1'), said('kept'), user(), '{not json', said('a side chain', { isSidechain: true }), JSON.stringify({ type: 'assistant', message: { content: 'plain' } })].join('\n')
    expect(turnIn(out).texts).toEqual(['kept'])
  })

  test('several text blocks in one record are one message', () => {
    const rec = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: 'one' }, { type: 'tool_use' }, { type: 'text', text: 'two' }] } })
    expect(turnIn([user('p1'), rec].join('\n')).texts).toEqual(['one\n\ntwo'])
  })
})

describe('turnAt', () => {
  const T = '/Users/dan/.claude/projects/x/s.jsonl'
  const runs = (answer: Awaited<ReturnType<TurnRun>> | 'throws') => {
    const asked: string[][] = []
    const run: TurnRun = async argv => {
      asked.push([...argv])
      if (answer === 'throws') throw new Error('perl could not be started')
      return answer
    }
    return { asked, run }
  }
  const ok = (stdout: string) => ({ exitCode: 0, stdout, stderr: '', isStdoutTruncated: false })

  test('reads the transcript\'s last bytes through perl, the path and the mark as arguments, never in the program', async () => {
    const { asked, run } = runs(ok([user('p1'), said('hello')].join('\n')))
    expect(await turnAt(T, run)).toEqual({ state: 'read', texts: ['hello'], isOurs: false, promptId: 'p1' })
    const argv = asked[0] ?? []
    expect(argv.slice(0, 2)).toEqual(['perl', '-e'])
    expect(argv.slice(3)).toEqual(['--', String(TURN_BYTES), T, PROSE_MARK])
    expect(argv[2]).not.toContain(T)
  })

  test('a transcript that cannot be read is said to be unreadable with the reason, never read as an empty turn', async () => {
    expect(await turnAt(T, runs({ exitCode: 2, stdout: '', stderr: `${T}: No such file or directory\n`, isStdoutTruncated: false }).run))
      .toEqual({ state: 'unreadable', why: `${T}: No such file or directory` })
    expect(await turnAt(T, runs({ exitCode: 2, stdout: '', stderr: '', isStdoutTruncated: false }).run)).toEqual({ state: 'unreadable', why: 'the transcript reader exited 2' })
    expect(await turnAt(T, runs('throws').run)).toEqual({ state: 'unreadable', why: 'perl could not be started' })
    expect(await turnAt('', runs(ok('')).run)).toEqual({ state: 'unreadable', why: 'no transcript was given' })
  })

  test('output cut short by the engine is unreadable, since the turn\'s last messages are what it lost', async () => {
    expect(await turnAt(T, runs({ ...ok(said('x')), isStdoutTruncated: true }).run)).toEqual({ state: 'unreadable', why: 'the transcript reader printed more than could be read whole' })
  })
})
