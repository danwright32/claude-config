import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { PAGE_MARK } from '../hooks/page.ts'
import { FAR_BYTES, FAR_MS, PROSE_MARK, REFUSED_MARK, TURN_BYTES, TURN_TIMEOUT_MS, UNREAD_MARK, refusalAsk, turnAt, turnIn, unreadStep, type TurnAt, type TurnRun } from '../hooks/turn.ts'

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
    expect(turnIn(out)).toEqual({ texts: ['One thing is still yours to do.', 'Done with the rest.'], isOurs: false, promptId: 'p2', refused: 0, refusedUnasked: 0, saidAfterRefusal: [], refusedMet: 0, isPinned: false, isCutShort: false })
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
    expect(turnIn([said('a'), said('b')].join('\n'))).toEqual({ texts: ['a', 'b'], isOurs: false, promptId: null, refused: 0, refusedUnasked: 0, saidAfterRefusal: [], refusedMet: 0, isPinned: false, isCutShort: false })
    expect(turnIn('')).toEqual({ texts: [], isOurs: false, promptId: null, refused: 0, refusedUnasked: 0, saidAfterRefusal: [], refusedMet: 0, isPinned: false, isCutShort: false })
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
  // the refused call and the unread turn, so a turn holding any of them is blocked by this mod again
  // only for a call refused after it.
  test('reads the transcript\'s last bytes through perl, the path and each mark as arguments, never in the program', async () => {
    const { asked, run } = runs(ok([user('p1'), said('hello')].join('\n')))
    expect(await turnAt(T, run)).toEqual({ state: 'read', texts: ['hello'], isOurs: false, promptId: 'p1', refused: 0, refusedUnasked: 0, saidAfterRefusal: [], refusedMet: 0, isPinned: false, isCutShort: false })
    const argv = asked[0] ?? []
    expect(argv.slice(0, 2)).toEqual(['perl', '-e'])
    expect(argv.slice(3)).toEqual(['--', String(TURN_BYTES), String(FAR_BYTES), String(FAR_MS), T, 'mcp__manual-steps__steps', PROSE_MARK, PAGE_MARK, REFUSED_MARK, UNREAD_MARK])
    expect(argv[2]).toContain('@marks')
    expect(argv[2]).not.toContain(T)
  })

  test('a transcript that cannot be read is said to be unreadable with the reason, never read as an empty turn', async () => {
    expect(await turnAt(T, runs({ exitCode: 2, stdout: '', stderr: `${T}: No such file or directory\n`, isStdoutTruncated: false }).run))
      .toEqual({ state: 'unreadable', why: `${T}: No such file or directory`, isUnfinished: false })
    expect(await turnAt(T, runs({ exitCode: 2, stdout: '', stderr: '', isStdoutTruncated: false }).run)).toEqual({ state: 'unreadable', why: 'the transcript reader exited 2', isUnfinished: true })
    expect(await turnAt(T, runs('throws').run)).toEqual({ state: 'unreadable', why: 'perl could not be started', isUnfinished: true })
    expect(await turnAt('', runs(ok('')).run)).toEqual({ state: 'unreadable', why: 'no transcript was given', isUnfinished: false })
  })

  test('output cut short by the engine is unreadable, since the turn\'s last messages are what it lost', async () => {
    expect(await turnAt(T, runs({ ...ok(said('x')), isStdoutTruncated: true }).run)).toEqual({ state: 'unreadable', why: 'the transcript reader printed more than could be read whole', isUnfinished: true })
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

  // Review of pull request 3854: a subagent's records can sit inside the main record, and a step it
  // pinned is its own, not the one the main conversation's refused call left. The same call by the
  // main conversation, in the same place, does answer.
  test('a steps tool call a subagent made inside the main record does not answer a refusal', () => {
    const byAgent = JSON.stringify({ type: 'assistant', isSidechain: true, isPinning: true })
    const byAgentWhole = JSON.stringify({ type: 'assistant', isSidechain: true, message: { content: [{ type: 'text', text: 'Pinning it.' }, { type: 'tool_use', name: 'mcp__manual-steps__steps', input: {} }] } })
    for (const agentPin of [byAgent, byAgentWhole])
      expect(turnIn([user('p1'), denied('automode-blocked'), agentPin, user('p1'), said('The agent pinned a step of its own.')].join('\n')).refused).toBe(1)
    const byMain = JSON.stringify({ type: 'assistant', isSidechain: false, isPinning: true })
    expect(turnIn([user('p1'), denied('automode-blocked'), byMain, user('p1'), said('It is on the card.')].join('\n')).refused).toBe(0)
  })

  // Review of pull request 3854: the count (tools/steps-phrase-count.ts) kept its own copy of the
  // test for a refused call and for a steps tool call, and the copies differed from these. The
  // reader now reports both, so the count asks it.
  test('every refused call it met in the turn is reported beside those left open', () => {
    const t = turnIn([user('p1'), denied('automode-blocked'), pinned, user('p1'), denied('automode-blocked'), said('x')].join('\n'))
    expect([t.refusedMet, t.refused]).toEqual([2, 1])
    const answered = turnIn([user('p1'), denied('automode-blocked'), pinned, user('p1'), said('It is on the card.')].join('\n'))
    expect([answered.refusedMet, answered.refused]).toEqual([1, 0])
    // The turn before's, a subagent's, another kind and one under no prompt are not met.
    const others = [user('p0'), denied('automode-blocked', 'p0'), said('Stopped.'), user('p1'), denied('permission-rule'), denied('automode-blocked', 'p1', { isSidechain: true }), denied('automode-blocked', 'p1', { promptId: undefined }), said('x')]
    expect(turnIn(others.join('\n')).refusedMet).toBe(0)
  })

  test('whether the main conversation called the steps tool in the turn is reported', () => {
    expect(turnIn([user('p1'), pinned, user('p1'), said('x')].join('\n')).isPinned).toBe(true)
    expect(turnIn([user('p1'), pinnedWhole, user('p1'), said('x')].join('\n')).isPinned).toBe(true)
    expect(turnIn([user('p1'), said('x')].join('\n')).isPinned).toBe(false)
    // A subagent's call inside the main record is not the main conversation's.
    const byAgent = JSON.stringify({ type: 'assistant', isSidechain: true, isPinning: true })
    expect(turnIn([user('p1'), byAgent, user('p1'), said('x')].join('\n')).isPinned).toBe(false)
    // A call after the turn before's last record of its prompt is the turn before's.
    expect(turnIn([user('p0'), said('Pinning it.'), pinned, user('p1'), said('x')].join('\n')).isPinned).toBe(false)
    // A window that starts inside the turn: a call before the first record it holds is the turn's.
    expect(turnIn([pinned, user('p1'), said('x')].join('\n')).isPinned).toBe(true)
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
    expect(await turnAt('/t.jsonl', run)).toEqual({ state: 'read', texts: [], isOurs: false, promptId: 'p1', refused: 1, refusedUnasked: 1, saidAfterRefusal: [], refusedMet: 1, isPinned: false, isCutShort: false })
    expect(asked[0]?.slice(3)).toEqual(['--', String(TURN_BYTES), String(FAR_BYTES), String(FAR_MS), '/t.jsonl', 'mcp__manual-steps__steps', PROSE_MARK, PAGE_MARK, REFUSED_MARK, UNREAD_MARK])
    expect(asked[0]?.[2]).toContain('toolDenialKind')
    expect(asked[0]?.[2]).not.toContain('mcp__manual-steps__steps')
  })
})

// #3860: what the refused call check could not see. The records here are as the reader prints
// them, the ids invented. Shapes measured on 2026-11-28 over the main conversations' records of 30
// days on the personal MacBook: a user record holds at most one tool result (0 of 69,470 held
// two), a refused or denied call's result carries `is_error` and its call's `tool_use_id` (2,320
// of 2,320), and a steps tool call is a block of its own carrying its `id` (223 of 223).
const pinCall = (id: string, extra: Record<string, unknown> = {}) => JSON.stringify({ type: 'assistant', isSidechain: false, isPinning: true, callIds: [id], ...extra })
const resultOf = (id: string, isError: boolean, promptId = 'p1') => JSON.stringify({ type: 'user', promptId, isOurs: false, resultOf: id, isError })
const STOPPED = JSON.stringify({ type: 'reader', isCutShort: true })

describe('what the refused call check could not see (#3860)', () => {
  test('a refusal record too long to keep whole, cut down by the reader to its top level fields, is counted', () => {
    const cutDown = JSON.stringify({ type: 'user', isSidechain: false, promptId: 'p1', toolDenialKind: 'automode-blocked', isOurs: false, isCutDown: true, resultOf: 't1', isError: true })
    expect(turnIn([user('p1'), cutDown, said('The row is still yours.')].join('\n')).refused).toBe(1)
    // A subagent's, cut down the same way, is still not the main conversation's.
    expect(turnIn([user('p1'), cutDown.replace('"isSidechain":false', '"isSidechain":true'), said('x')].join('\n')).refused).toBe(0)
  })

  test('the reader stopping before the turn\'s first record is reported, so a stretch it never read is not taken for a clean one', () => {
    expect(turnIn([STOPPED, user('p1'), said('x')].join('\n')).isCutShort).toBe(true)
    expect(turnIn([user('p1'), said('x')].join('\n')).isCutShort).toBe(false)
    // What it did read of the turn is still read.
    const t = turnIn([STOPPED, user('p1'), denied('automode-blocked'), said('x')].join('\n'))
    expect([t.isCutShort, t.refused, t.texts]).toEqual([true, 1, ['x']])
  })

  test('a refusal that came after this mod\'s own block in the turn has not been asked about, and one before the block has', () => {
    const late = turnIn([user('p1'), denied('automode-blocked'), said('a'), user('p1', true), said('b'), denied('automode-blocked'), said('c')].join('\n'))
    expect([late.isOurs, late.refused, late.refusedUnasked]).toEqual([true, 2, 1])
    const early = turnIn([user('p1'), denied('automode-blocked'), said('a'), user('p1', true), said('b')].join('\n'))
    expect([early.isOurs, early.refused, early.refusedUnasked]).toEqual([true, 1, 0])
    // With no block in the turn, none has been asked about.
    expect(turnIn([user('p1'), denied('automode-blocked'), denied('automode-blocked'), said('a')].join('\n')).refusedUnasked).toBe(2)
    // A step pinned after the late refusal answers it as it answers any other.
    expect(turnIn([user('p1'), user('p1', true), denied('automode-blocked'), pinCall('t2'), resultOf('t2', false), said('c')].join('\n')).refusedUnasked).toBe(0)
  })

  test('only what Claude wrote after the latest refusal not yet asked about is reported as able to answer it', () => {
    const t = turnIn([user('p1'), denied('automode-blocked'), said('Nothing from the refusal is yours to do.'), user('p1', true), said('b'), denied('automode-blocked'), said('c'), user('p1'), said('d')].join('\n'))
    expect(t.saidAfterRefusal).toEqual(['c', 'd'])
    expect(turnIn([user('p1'), said('a')].join('\n')).saidAfterRefusal).toEqual([])
  })

  test('a steps tool call whose result is an error does not answer the refusal before it', () => {
    const failed = turnIn([user('p1'), denied('automode-blocked'), pinCall('t9'), resultOf('t9', true), said('It is on the card.')].join('\n'))
    expect([failed.refused, failed.refusedUnasked, failed.isPinned]).toEqual([1, 1, false])
    const worked = turnIn([user('p1'), denied('automode-blocked'), pinCall('t9'), resultOf('t9', false), said('It is on the card.')].join('\n'))
    expect([worked.refused, worked.isPinned]).toEqual([0, true])
    // A second call that worked, after the one that failed, answers it.
    expect(turnIn([user('p1'), denied('automode-blocked'), pinCall('t8'), resultOf('t8', true), pinCall('t9'), resultOf('t9', false), said('x')].join('\n')).refused).toBe(0)
    // Another call's failure is not the steps tool call's.
    expect(turnIn([user('p1'), denied('automode-blocked'), pinCall('t9'), resultOf('t9', false), resultOf('t7', true), said('x')].join('\n')).refused).toBe(0)
  })

  test('a failed steps tool call is read the same in records kept whole, and one the permission check refused is itself a refusal', () => {
    const call = JSON.stringify({ type: 'assistant', isSidechain: false, message: { content: [{ type: 'text', text: 'Pinning it.' }, { type: 'tool_use', id: 't9', name: 'mcp__manual-steps__steps', input: {} }] } })
    const refusedPin = denied('automode-blocked', 'p1', { message: { role: 'user', content: [{ type: 'tool_result', content: 'refused', is_error: true, tool_use_id: 't9' }] } })
    const t = turnIn([user('p1'), denied('automode-blocked'), call, refusedPin, said('x')].join('\n'))
    expect([t.refused, t.isPinned]).toEqual([2, false])
  })

  test('a steps tool call with no result in what was read still answers, as it did before its result was read', () => {
    expect(turnIn([user('p1'), denied('automode-blocked'), pinCall('t9'), said('x')].join('\n')).refused).toBe(0)
    expect(turnIn([user('p1'), denied('automode-blocked'), pinned, said('x')].join('\n')).refused).toBe(0)
  })

  // Point 4 of #3860, left as it is until Dan decides: Claude Code writes a prompt typed while a
  // turn runs under the running prompt's promptId (111 such records in the 30 days measured), so
  // the reader cannot tell it from a tool result and starts no new turn at it.
  test('a prompt typed while the turn runs keeps the turn\'s promptId, so a refusal and a block before it are still this turn\'s', () => {
    const typed = user('p1')
    const t = turnIn([user('p1'), denied('automode-blocked'), said('The row is still yours.'), typed, said('Thanks, carrying on.')].join('\n'))
    expect([t.promptId, t.refused, t.texts]).toEqual(['p1', 1, ['The row is still yours.', 'Thanks, carrying on.']])
    expect(turnIn([user('p1'), said('a'), user('p1', true), typed, said('b')].join('\n')).isOurs).toBe(true)
  })
})

describe('a read that did not finish (#3860)', () => {
  const T = '/t.jsonl'
  const answer = (a: Partial<Awaited<ReturnType<TurnRun>>>): TurnRun => async () => ({ exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, ...a })

  test('a transcript perl names as one it could not open is absent, and a read that started and gave no whole answer is unfinished', async () => {
    expect(await turnAt(T, answer({ exitCode: 2, stderr: `${T}: No such file or directory\n` }))).toEqual({ state: 'unreadable', why: `${T}: No such file or directory`, isUnfinished: false })
    expect(await turnAt('', answer({}))).toEqual({ state: 'unreadable', why: 'no transcript was given', isUnfinished: false })
    // Stopped at its time limit or killed: whatever the engine answers then, it is not perl's own reason.
    expect(await turnAt(T, answer({ exitCode: 143 }))).toEqual({ state: 'unreadable', why: 'the transcript reader exited 143', isUnfinished: true })
    // A failure of the reader's own once it is reading is not a transcript that is not there.
    expect(await turnAt(T, answer({ exitCode: 5, stderr: `reading ${T}: Input/output error\n` }))).toEqual({ state: 'unreadable', why: `reading ${T}: Input/output error`, isUnfinished: true })
    expect(await turnAt(T, answer({ exitCode: 1, stderr: 'the process was stopped at its time limit' }))).toEqual({ state: 'unreadable', why: 'the process was stopped at its time limit', isUnfinished: true })
    expect(await turnAt(T, async () => { throw new Error('timed out after 2000ms') })).toEqual({ state: 'unreadable', why: 'timed out after 2000ms', isUnfinished: true })
    expect(await turnAt(T, answer({ isStdoutTruncated: true }))).toEqual({ state: 'unreadable', why: 'the transcript reader printed more than could be read whole', isUnfinished: true })
  })

  test('the reader is handed how far back it may walk past the window and its own time limit, under the limit its caller stops it at', async () => {
    const asked: string[][] = []
    await turnAt(T, async argv => {
      asked.push([...argv])
      return { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false }
    })
    expect(asked[0]?.slice(3, 8)).toEqual(['--', String(TURN_BYTES), String(FAR_BYTES), String(FAR_MS), T])
    expect(FAR_MS).toBeLessThan(TURN_TIMEOUT_MS)
    // Only its failure to open the transcript is said with the bare path, which is how a
    // transcript that is not there is told from a read that failed part way.
    expect(asked[0]?.[2]?.match(/die "\$f: /g)).toHaveLength(1)
    expect(asked[0]?.[2]?.match(/die "reading \$f: /g)).toHaveLength(4)
  })
})

describe('what the turn\'s end asks about refused calls (#3860)', () => {
  const read = (lines: string[]): TurnAt => ({ state: 'read', ...turnIn(lines.join('\n')) })
  const answers = (said: readonly string[]) => said.some(t => t.includes('Nothing from the refusal is yours to do.'))
  const LINE = 'Nothing from the refusal is yours to do.'

  test('a refusal not yet asked about is asked about, with how many', () => {
    expect(refusalAsk(read([user('p1'), denied('automode-blocked'), denied('automode-blocked'), said('x')]), ['x'], false, answers)).toEqual({ ask: 'refused', calls: 2 })
    expect(refusalAsk(read([user('p1'), said('x')]), ['x'], false, answers)).toEqual({ ask: 'none' })
  })

  test('a refusal after this mod already held the turn is asked about once more, and the line said for the earlier one does not answer it', () => {
    const turn = read([user('p1'), denied('automode-blocked'), said('a'), user('p1', true), said(LINE), denied('automode-blocked'), said('The second row is still yours.')])
    expect(refusalAsk(turn, ['a', LINE, 'The second row is still yours.'], true, answers)).toEqual({ ask: 'refused', calls: 1 })
    // The line said after the later refusal answers it.
    const answered = read([user('p1'), denied('automode-blocked'), said('a'), user('p1', true), said(LINE), denied('automode-blocked'), said(LINE)])
    expect(refusalAsk(answered, ['a', LINE, LINE], true, answers)).toEqual({ ask: 'none' })
    // Held again for the later one, the turn has nothing new, so it cannot loop.
    const again = read([user('p1'), denied('automode-blocked'), user('p1', true), said(LINE), denied('automode-blocked'), said('b'), user('p1', true), said('c')])
    expect(refusalAsk(again, [LINE, 'b', 'c'], true, answers)).toEqual({ ask: 'none' })
  })

  test('the last message, not yet in the transcript, can answer a refusal', () => {
    const turn = read([user('p1'), denied('automode-blocked'), said('a')])
    expect(refusalAsk(turn, ['a', LINE], false, answers)).toEqual({ ask: 'none' })
  })

  test('a turn the reader could not read to its start is said to be unread, unless what it did read settles it', () => {
    expect(refusalAsk(read([STOPPED, user('p1'), said('x')]), ['x'], false, answers)).toEqual({ ask: 'unread' })
    // A refusal it did read is asked about as itself.
    expect(refusalAsk(read([STOPPED, user('p1'), denied('automode-blocked'), said('x')]), ['x'], false, answers)).toEqual({ ask: 'refused', calls: 1 })
    // A step pinned in the part it read answers any refusal before it; the line does too; and a turn already held is not held again.
    expect(refusalAsk(read([STOPPED, user('p1'), pinCall('t1'), resultOf('t1', false), said('x')]), ['x'], false, answers)).toEqual({ ask: 'none' })
    expect(refusalAsk(read([STOPPED, user('p1'), said(LINE)]), [LINE], false, answers)).toEqual({ ask: 'none' })
    expect(refusalAsk(read([STOPPED, user('p1', true), said('x')]), ['x'], true, answers)).toEqual({ ask: 'none' })
    // A step whose pin failed settles nothing.
    expect(refusalAsk(read([STOPPED, user('p1'), pinCall('t1'), resultOf('t1', true), said('x')]), ['x'], false, answers)).toEqual({ ask: 'unread' })
  })

  test('a read that did not finish is said to be unread once per chain of turn ends, and a transcript that is not there asks nothing', () => {
    expect(refusalAsk({ state: 'unreadable', why: 'timed out', isUnfinished: true }, ['x'], false, answers)).toEqual({ ask: 'unread' })
    expect(refusalAsk({ state: 'unreadable', why: 'timed out', isUnfinished: true }, ['x'], true, answers)).toEqual({ ask: 'none' })
    expect(refusalAsk({ state: 'unreadable', why: 'timed out', isUnfinished: true }, [LINE], false, answers)).toEqual({ ask: 'none' })
    expect(refusalAsk({ state: 'unreadable', why: '/t: No such file or directory', isUnfinished: false }, ['x'], false, answers)).toEqual({ ask: 'none' })
  })

  test('the words for an unread turn begin with their own mark, name the steps tool and the one line, and stay short', () => {
    const words = unreadStep()
    expect(words.startsWith(`${UNREAD_MARK},`)).toBe(true)
    expect(words).toContain('mcp__manual-steps__steps')
    expect(words).toContain('"Nothing from the refusal is yours to do."')
    expect(words.trim().split(/\s+/).length).toBeLessThanOrEqual(50)
  })
})
