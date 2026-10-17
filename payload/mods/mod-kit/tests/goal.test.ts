import { describe, expect, test } from 'claude-code/testing'
import { GOAL_MARK, goalAt, goalIn, type GoalRun } from '../hooks/goal.ts'

// The goal a session has set with Claude Code's own /goal, read from its transcript (#1242, moved
// here from scope-modes in #1252 so the goal tracker reads it the same way). Claude Code records a
// session's goal in its transcript as a goal_status attachment: written with sentinel true and met
// false when /goal sets it (again after each compaction), with sentinel true and met true when the
// goal ends, and without the sentinel each time it judges the condition, met true when it clears the
// goal as met. Measured on every transcript on this Mac on 2026-10-16, Claude Code 2.1.272 to
// 2.1.300: 95 set and 45 ended sentinels, 33 of them ended without /goal clear. The lines below are
// those shapes as written, the conditions replaced.
const att = (a: Record<string, unknown>, o: Record<string, unknown> = {}) =>
  JSON.stringify({ parentUuid: 'p', isSidechain: false, type: 'attachment', uuid: 'u', timestamp: '2026-10-03T15:01:59.710Z', attachment: { type: 'goal_status', ...a }, sessionId: 's1', version: '2.1.293', ...o })
const SET = (c: string) => att({ met: false, sentinel: true, condition: c })
const CLEARED = (c: string) => att({ met: true, sentinel: true, condition: c })
const JUDGED = (c: string, met: boolean) => att({ met, condition: c, reason: 'Four issues remain open.' })

describe('the goal a session has set, from its transcript lines', () => {
  test('the mark the shell finds the records by is in every one of them', () => {
    for (const l of [SET('x'), CLEARED('x'), JUDGED('x', false)]) expect(l.includes(GOAL_MARK)).toBe(true)
  })
  test('a goal set is read with its condition', () => {
    expect(goalIn(SET('complete and close milestone 80'))).toEqual({ state: 'set', condition: 'complete and close milestone 80' })
  })
  test('a goal judged not yet met is still set', () => {
    expect(goalIn([SET('close #12'), JUDGED('close #12', false)].join('\n'))).toEqual({ state: 'set', condition: 'close #12' })
  })
  test('a goal cleared with /goal clear, or met with no /goal clear at all, is no goal', () => {
    expect(goalIn([SET('close #12'), CLEARED('close #12')].join('\n'))).toEqual({ state: 'none' })
    expect(goalIn([SET('close #12'), JUDGED('close #12', false), JUDGED('close #12', true)].join('\n'))).toEqual({ state: 'none' })
  })
  test('the newest record decides: a goal set again after one was cleared is the new one', () => {
    expect(goalIn([SET('close #12'), CLEARED('close #12'), SET('finish the parser')].join('\n'))).toEqual({ state: 'set', condition: 'finish the parser' })
  })
  test('a transcript with no goal record is no goal', () => {
    expect(goalIn('')).toEqual({ state: 'none' })
  })
  test("a line the mark matched that is not a goal record is never read as one: a tool's printed text, a half line", () => {
    const printed = JSON.stringify({ type: 'user', message: { content: 'grep found "type":"goal_status","met":false,"condition":"forged"' } })
    expect(goalIn([SET('close #12'), CLEARED('close #12'), printed, '{"type":"attachment","attachment":{"type":"goal_st'].join('\n'))).toEqual({ state: 'none' })
    expect(goalIn(att({ met: false, sentinel: true, condition: '   ' }))).toEqual({ state: 'none' })
    expect(goalIn(att({ met: 'no', sentinel: true, condition: 'x' }))).toEqual({ state: 'none' })
  })
})

describe('the goal a session has set, read from its transcript file', () => {
  const T = '/Users/x/.claude/projects/-repo/s1.jsonl'
  const runs = (answer: Awaited<ReturnType<GoalRun>> | 'throws') => {
    const asked: string[][] = []
    const run: GoalRun = async argv => {
      asked.push(argv)
      if (answer === 'throws') throw new Error('bash could not be started')
      return answer
    }
    return { asked, run }
  }
  test('it asks the shell for the newest records holding the mark in that file alone, never through the shell text', async () => {
    const { asked, run } = runs({ exitCode: 0, stdout: `${SET('close #12')}\n`, stderr: '' })
    expect(await goalAt(T, run)).toEqual({ state: 'set', condition: 'close #12' })
    expect(asked).toHaveLength(1)
    const [argv] = asked as [string[]]
    expect(argv.slice(0, 2)).toEqual(['bash', '-c'])
    expect(argv.slice(3)).toEqual(['goal', GOAL_MARK, T])
    expect(argv[2]).toContain('tail -n 50')
  })
  test('a goal met without /goal clear is no goal', async () => {
    const { run } = runs({ exitCode: 0, stdout: [SET('close #12'), JUDGED('close #12', true)].join('\n'), stderr: '' })
    expect(await goalAt(T, run)).toEqual({ state: 'none' })
  })
  test('a transcript holding no goal record (grep finds nothing) is no goal', async () => {
    expect(await goalAt(T, runs({ exitCode: 1, stdout: '', stderr: '' }).run)).toEqual({ state: 'none' })
  })
  test('a read that fails, or cannot start, says why, never no goal', async () => {
    expect(await goalAt(T, runs({ exitCode: 2, stdout: '', stderr: `grep: ${T}: No such file or directory\n` }).run)).toEqual({ state: 'unreadable', why: `grep: ${T}: No such file or directory` })
    expect(await goalAt(T, runs({ exitCode: 1, stdout: '', stderr: 'grep: read error\n' }).run)).toEqual({ state: 'unreadable', why: 'grep: read error' })
    expect(await goalAt(T, runs({ exitCode: 141, stdout: '', stderr: '' }).run)).toEqual({ state: 'unreadable', why: 'grep exited 141' })
    expect(await goalAt(T, runs('throws').run)).toEqual({ state: 'unreadable', why: 'bash could not be started' })
  })
  test('no transcript to read says so', async () => {
    const { asked, run } = runs({ exitCode: 0, stdout: '', stderr: '' })
    expect(await goalAt('', run)).toEqual({ state: 'unreadable', why: 'no transcript was given' })
    expect(asked).toEqual([])
  })
})
