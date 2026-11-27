import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { PAGE_MARK } from '../hooks/page.ts'
import { PROSE_MARK, REFUSED_MARK, TURN_BYTES, turnAt, turnIn, type TurnRun } from '../hooks/turn.ts'

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
    expect(turnIn(out)).toEqual({ texts: ['One thing is still yours to do.', 'Done with the rest.'], isOurs: false, promptId: 'p2', refused: 0 })
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
    expect(turnIn([said('a'), said('b')].join('\n'))).toEqual({ texts: ['a', 'b'], isOurs: false, promptId: null, refused: 0 })
    expect(turnIn('')).toEqual({ texts: [], isOurs: false, promptId: null, refused: 0 })
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
  const T = `${'/Users'}/dan/.claude/projects/x/s.jsonl`
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

  // #1811, #3842: each of this mod's blocks is a mark, the step left in prose, the page of steps
  // and the refused call, so a turn holding any of them is never blocked by this mod again.
  test('reads the transcript\'s last bytes through perl, the path and each mark as arguments, never in the program', async () => {
    const { asked, run } = runs(ok([user('p1'), said('hello')].join('\n')))
    expect(await turnAt(T, run)).toEqual({ state: 'read', texts: ['hello'], isOurs: false, promptId: 'p1', refused: 0 })
    const argv = asked[0] ?? []
    expect(argv.slice(0, 2)).toEqual(['perl', '-e'])
    expect(argv.slice(3)).toEqual(['--', String(TURN_BYTES), T, 'mcp__manual-steps__steps', PROSE_MARK, PAGE_MARK, REFUSED_MARK])
    expect(argv[2]).toContain('@marks')
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

// #3842: a call the permission check refused, as Claude Code's own session record holds it. Shape
// measured on 2026-11-27 over the 32 such records of 30 days on the personal MacBook (Claude Code
// 2.1.311 to 2.1.332): a user record, 3.3 to 4.4 KB, carrying the turn's promptId and
// `toolDenialKind`, beside 1,938 `permission-rule` (a hook's or a rule's refusal), 93
// `automode-unavailable` (no verdict) and 65 `user-rejected` (Dan declined a prompt). The ids here
// are invented.
const denied = (kind: string, promptId = 'p1', extra: Record<string, unknown> = {}) =>
  JSON.stringify({
    type: 'user',
    isSidechain: false,
    promptId,
    toolDenialKind: kind,
    permissionDecision: { decision: 'reject', reasonType: 'classifier', reasonCode: 'classifier:auto-mode', source: 'config' },
    toolUseResult: 'Error: Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Destructive or Unwanted Actions].',
    message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_01', is_error: true, content: 'Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Destructive or Unwanted Actions].' }] },
    ...extra,
  })
const pinned = JSON.stringify({ type: 'assistant', isPinning: true })
const pinnedWhole = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: 'Pinning it.' }, { type: 'tool_use', name: 'mcp__manual-steps__steps', input: {} }] } })

describe('a call the permission check refused in the turn (#3842)', () => {
  test('one refused call, with no steps tool call after it, is counted', () => {
    expect(turnIn([user('p1'), said('Setting the row.'), denied('automode-blocked'), said('The row is still yours.')].join('\n')).refused).toBe(1)
  })

  test('each refused call of the turn is counted', () => {
    expect(turnIn([user('p1'), denied('automode-blocked'), said('a'), denied('automode-blocked'), said('b')].join('\n')).refused).toBe(2)
  })

  test('a steps tool call after the refusal answers it, as the reader prints it or in a record kept whole', () => {
    expect(turnIn([user('p1'), denied('automode-blocked'), pinned, user('p1'), said('It is on the card.')].join('\n')).refused).toBe(0)
    expect(turnIn([user('p1'), denied('automode-blocked'), pinnedWhole, user('p1'), said('It is on the card.')].join('\n')).refused).toBe(0)
  })

  test('a steps tool call before the refusal does not answer it', () => {
    expect(turnIn([user('p1'), pinned, user('p1'), denied('automode-blocked'), said('That one is yours too.')].join('\n')).refused).toBe(1)
    // Of two refusals, only the one after the last steps tool call is left open.
    expect(turnIn([user('p1'), denied('automode-blocked'), pinned, user('p1'), denied('automode-blocked'), said('x')].join('\n')).refused).toBe(1)
  })

  test('no verdict, a hook\'s or a rule\'s refusal, a prompt Dan declined and a cancelled call are not it', () => {
    for (const kind of ['automode-unavailable', 'permission-rule', 'user-rejected', 'cancelled', 'interrupted'])
      expect(turnIn([user('p1'), denied(kind), said('Carrying on.')].join('\n')).refused).toBe(0)
  })

  test('a refusal in the turn before, in a subagent\'s record, or under no prompt is not this turn\'s', () => {
    expect(turnIn([user('p0'), denied('automode-blocked', 'p0'), said('Stopped.'), user('p1'), said('A new turn.')].join('\n')).refused).toBe(0)
    expect(turnIn([user('p1'), denied('automode-blocked', 'p1', { isSidechain: true }), said('x')].join('\n')).refused).toBe(0)
    expect(turnIn([user('p1'), denied('automode-blocked', 'p1', { promptId: undefined }), said('x')].join('\n')).refused).toBe(0)
  })

  test('the kind is read from the record itself, never from the same words inside a tool result', () => {
    const quoting = JSON.stringify({ type: 'user', isSidechain: false, promptId: 'p1', message: { content: [{ type: 'tool_result', content: '{"toolDenialKind":"automode-blocked"}' }] } })
    expect(turnIn([user('p1'), quoting, said('I read the record.')].join('\n')).refused).toBe(0)
  })

  test('the reader is handed the steps tool to look for, and its own refusal mark', async () => {
    const asked: string[][] = []
    const run: TurnRun = async argv => {
      asked.push([...argv])
      return { exitCode: 0, stdout: [user('p1'), denied('automode-blocked')].join('\n'), stderr: '', isStdoutTruncated: false }
    }
    expect(await turnAt('/t.jsonl', run)).toEqual({ state: 'read', texts: [], isOurs: false, promptId: 'p1', refused: 1 })
    expect(asked[0]?.slice(3)).toEqual(['--', String(TURN_BYTES), '/t.jsonl', 'mcp__manual-steps__steps', PROSE_MARK, PAGE_MARK, REFUSED_MARK])
    expect(asked[0]?.[2]).toContain('toolDenialKind')
    expect(asked[0]?.[2]).not.toContain('mcp__manual-steps__steps')
  })
})
