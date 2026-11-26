// The engine tests of a PR Dan himself chose to close unmerged (#3779), in a file of their own.
//
// At about 1:38 PM ET on 2026-11-26 Dan picked "3.79.1 Close it unmerged (Recommended)" in a session's
// picker about claude-config's pull request 3749. The session closed it, and an hour later winding
// down sent it back to be reopened and finished: handed his exact answer as dan_said, leave_pr_open
// found "no recorded reason it will never merge", and he was asked again. His pick is read from the
// dialog's own result, which no session writes, and settles that PR while it stays closed. The
// picker is his, word for word (close-decision-fixtures.ts); the repository is the tests' own.
//
// These run in the engine's fake world, which register.test.tsx builds and does not export, so that
// file hands its harness to closeDecisionEngine below and the tests are registered there. Each
// helper is typed only as far as these tests use it, and called with the casts that file's own
// tests use.
import { expect, type TestOptions } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { CLOSE_IT, SESSION_NOTE, SIGN_OFF, SIGN_OFF_OPTIONS, signOff } from './close-decision-fixtures.ts'

// Any function of the harness, whatever it takes: called with `as never`, as its own file does.
type Fn<R> = (...args: never[]) => R
type World = { o: Record<string, unknown>; asked: string[]; toasts: string[]; runs: string[][] }
type Clock = { advance: (ms: number) => Promise<void> }
export type CloseDecisionHarness = {
  withDeps: TestOptions
  world: Fn<{ w: World; clock: Clock }>
  start: Fn<Promise<unknown>>
  command: Fn<Promise<unknown>>
  /** One tool call, answered with its refusal or its text. */
  call: Fn<Promise<string>>
  /** A turn end, with the refusal it met when winding down is not finished. */
  stop: Fn<Promise<{ block?: string }>>
  /** GitHub with the branch's own PR merged and its issue closed. */
  merged: Fn<Record<string, unknown>>
  /** A world whose branch is cleaned up, so only the PRs the session opened can be outstanding. */
  cleaned: Record<string, unknown>
  openPr: Fn<Record<string, unknown>>
  closedPr: Fn<Record<string, unknown>>
  /** A call of leave_pr_open. */
  leave: Fn<unknown>
  /** What a closed PR with no answer of his is sent back with, and what the tool says of one. */
  REOPEN: (n: number) => string
  NO_REASON: (n: number, dan: string) => string
  CLOSED_AT: string
  pr716: Record<string, unknown>
  T0: number
  MIN: number
}

const PICKED_WHY = 'Dan answered "3.79.1 Close it unmerged (Recommended)" in a picker naming it'
const LEFT_CLOSED_3749 = ` Left closed by Dan's choice: PR #3749 in o/r (${PICKED_WHY}). `

export const closeDecisionEngine = (h: CloseDecisionHarness): void => {
  const create = ($: unknown, title: string, id: string) => h.call($ as never, { tool: 'Bash', command: `gh pr create --title ${title}`, tool_use_id: id } as never)
  const note = [{ body: SESSION_NOTE, createdAt: h.CLOSED_AT }]
  const live = { ...h.cleaned, verdict: { state: 'live', at: h.T0 } }

  test('a PR Dan himself chose to close unmerged, in a picker answer naming it, is left closed while winding down and the finish check does not list it (#3779)', h.withDeps, async ($, on) => {
    const { w, clock } = h.world(on as never, { ...live, created: 'https://github.com/o/r/pull/3749\n', ask: CLOSE_IT } as never)
    // Open when he was asked; #3692, which his question names beside it, is an issue.
    w.o.gh = { ...h.merged(), others: [h.openPr(3749 as never, 'aaa1111' as never)], notPrs: [3692] }
    await h.start($ as never, clock as never)
    await create($, 'settings', 'g1')
    await h.call($ as never, signOff() as never)
    // The session closes it with a note of its own, and an hour later winding down is switched on.
    w.o.gh = { ...h.merged(), others: [h.closedPr(3749 as never, 'aaa1111' as never, note as never)], notPrs: [3692] }
    await clock.advance(60 * h.MIN)
    await h.command($ as never, 'winddown' as never)
    // Nothing is left: it is not sent back to be reopened, and the finish says what was left closed.
    expect((await h.stop($ as never)).block).toBeUndefined()
    expect(w.toasts).toEqual([`Wind down finished: safe to close this session. Left closed by your choice: PR #3749 in o/r (${PICKED_WHY}).`])
    // He was asked once, by the session's picker, and GitHub was asked once whether #3692 is a PR.
    expect(w.asked).toEqual([SIGN_OFF])
    expect(w.runs.filter(r => r.join(' ').startsWith('gh pr view 3692 ')).length).toBe(1)
  })

  // A second PR the session opened stays open in the tests below, so winding down holds and each
  // turn end says what for.
  const held = async ($: unknown) => {
    const block = (await h.stop($ as never)).block ?? ''
    expect(block).toMatch(/^Winding down is not finished: /)
    expect(block).toContain('PR #3750 is not merged yet')
    return block
  }
  const holder = () => h.openPr(3750 as never, 'ccc3333' as never)

  test('leave_pr_open asks nothing more about a PR Dan already chose to close, and reopened it is outstanding until merged (#3779)', h.withDeps, async ($, on) => {
    const { w, clock } = h.world(on as never, { ...live, created: 'https://github.com/o/r/pull/3749\n', ask: CLOSE_IT } as never)
    const withHolder = (pr3749: Record<string, unknown>) => ({ ...h.merged(), others: [pr3749, holder()], notPrs: [3692] })
    w.o.gh = withHolder(h.openPr(3749 as never, 'aaa1111' as never))
    await h.start($ as never, clock as never)
    await create($, 'settings', 'g1')
    w.o.created = 'https://github.com/o/r/pull/3750\n'
    await create($, 'holder', 'g2')
    await h.call($ as never, signOff() as never)
    await h.command($ as never, 'winddown' as never)
    // Still open, his answer to close it settles nothing yet: it is outstanding as any open PR is.
    expect(await held($)).toMatch(/PR #3749 is not merged yet/)
    // Closed, it is listed apart as left closed by his choice, on this turn end and every later one.
    w.o.gh = withHolder(h.closedPr(3749 as never, 'aaa1111' as never, note as never))
    for (let turn = 0; turn < 2; turn++) {
      const block = await held($)
      expect(block).toContain(LEFT_CLOSED_3749)
      expect(block).not.toMatch(/PR #3749 (was closed|is not merged)/)
      expect(block).not.toContain('gh pr reopen 3749')
      await clock.advance(h.MIN)
    }
    // Handed his exact answer as it was on the day, the tool asks him nothing and says it is settled.
    expect(await h.call($ as never, h.leave(3749 as never, { repo: 'o/r', dan_said: CLOSE_IT } as never) as never)).toBe(
      `PR #3749 in o/r is already left closed by Dan's own choice (${PICKED_WHY}), so he was not asked again: winding down counts it settled unless it is reopened.`,
    )
    expect(w.asked).toEqual([SIGN_OFF])
    expect(await held($)).toContain(LEFT_CLOSED_3749)
    // Reopened on GitHub, his answer was about closing it: an open PR again, outstanding until merged.
    w.o.gh = withHolder(h.openPr(3749 as never, 'aaa1111' as never))
    const reopened = await held($)
    expect(reopened).toMatch(/PR #3749 is not merged yet/)
    expect(reopened).not.toMatch(/Left closed by Dan's choice/)
    expect(w.toasts).toEqual([])
  })

  test('a decision to close that Dan did not make never leaves a PR closed: a session closing its own, a closing comment it wrote, dan_said with no record behind it, or a picker he did not answer that way (#3779)', h.withDeps, async ($, on) => {
    const { w, clock } = h.world(on as never, { ...live, created: 'https://github.com/o/r/pull/3749\n', ask: CLOSE_IT } as never)
    // Closed by the session itself, with a closing comment that says the decision was Dan's.
    w.o.gh = { ...h.merged(), others: [h.closedPr(3749 as never, 'aaa1111' as never, note as never), holder()], notPrs: [3692] }
    await h.start($ as never, clock as never)
    await create($, 'settings', 'g1')
    w.o.created = 'https://github.com/o/r/pull/3750\n'
    await create($, 'holder', 'g2')
    await h.command($ as never, 'winddown' as never)
    const sentBack = async () => {
      const block = await held($)
      expect(block).toContain(h.REOPEN(3749))
      expect(block).not.toMatch(/Left closed by Dan's choice/)
    }
    await sentBack()
    // His words handed to the tool, with no answer of his on record behind them.
    expect(await h.call($ as never, h.leave(3749 as never, { repo: 'o/r', dan_said: CLOSE_IT } as never) as never)).toBe(h.NO_REASON(3749, "Dan's words given as dan_said name no PR"))
    expect(w.asked).toEqual([])
    await sentBack()
    // A picker that carries its own answer, and a subagent's picker.
    await h.call($ as never, signOff(SIGN_OFF, SIGN_OFF_OPTIONS, { answers: { [SIGN_OFF]: CLOSE_IT } }, 'q1') as never)
    await sentBack()
    await h.call($ as never, signOff(SIGN_OFF, SIGN_OFF_OPTIONS, { agentId: 'a1' }, 'q2') as never)
    await sentBack()
    // Another answer of the picker's, words he typed, and a picker that names no pull request as one.
    w.o.ask = '3.79.2 Merge it'
    await h.call($ as never, signOff(SIGN_OFF, SIGN_OFF_OPTIONS, {}, 'q3') as never)
    await sentBack()
    w.o.ask = 'close it unmerged'
    await h.call($ as never, signOff(SIGN_OFF, SIGN_OFF_OPTIONS, {}, 'q4') as never)
    await sentBack()
    w.o.ask = CLOSE_IT
    await h.call($ as never, signOff('3.79 Sign off for #3692 and number 3749. What should happen to it?', SIGN_OFF_OPTIONS, {}, 'q5') as never)
    await sentBack()
    // The same world records his own pick, so none of the above failed for another reason.
    await h.call($ as never, signOff(SIGN_OFF, SIGN_OFF_OPTIONS, {}, 'q6') as never)
    const block = await held($)
    expect(block).toContain(LEFT_CLOSED_3749)
    expect(block).not.toContain(h.REOPEN(3749))
  })

  test('his answer counts for the one PR his picker named: another number beside it waits for GitHub to say it is no PR, and one that is a PR leaves which he meant off the record (#3779)', h.withDeps, async ($, on) => {
    const answers = [{ label: 'Close it unmerged' }, { label: 'Merge it' }]
    const { w, clock } = h.world(on as never, { ...live, created: 'https://github.com/o/r/pull/3751\n', ask: 'Close it unmerged' } as never)
    // GitHub cannot place #3698 yet; #3752's picker names #716 beside it, which is a PR.
    const closedBoth = [h.closedPr(3751 as never, 'aaa1111' as never, [] as never), h.closedPr(3752 as never, 'bbb2222' as never, [] as never), h.pr716]
    w.o.gh = { ...h.merged(), others: closedBoth }
    await h.start($ as never, clock as never)
    await create($, 'a', 'g1')
    w.o.created = 'https://github.com/o/r/pull/3752\n'
    await create($, 'b', 'g2')
    await h.call($ as never, signOff('Sign off for #3698 (pull request 3751). What should happen to it?', answers, {}, 'q1') as never)
    await h.call($ as never, signOff('PR 3752 lost its base (#716 carries the work). What should happen to it?', answers, {}, 'q2') as never)
    await h.command($ as never, 'winddown' as never)
    const unplaced = (await h.stop($ as never)).block ?? ''
    // Unplaced, it is neither settled nor sent back to be reopened, and the turn end says what is unread.
    expect(unplaced).toContain(
      'PR #3751 was closed without merging, and Dan answered "Close it unmerged" in a picker naming it, which settles it once GitHub says #3698, which that picker also named, is no pull request. That could not be read (whether #3698, named in the picker Dan answered about PR #3751, is a PR: no pull requests found), so leave it closed until GitHub answers',
    )
    expect(unplaced).not.toContain('gh pr reopen 3751')
    expect(unplaced).not.toMatch(/Left closed by Dan's choice/)
    // Which of #3752 and #716 he meant is not on record, so #3752 is reopened and finished as before.
    expect(unplaced).toContain(h.REOPEN(3752))
    // The tool says the same of the unplaced one, and asks him nothing.
    expect(await h.call($ as never, h.leave(3751 as never, { repo: 'o/r' } as never) as never)).toBe(
      'PR #3751 in o/r could not be read (whether #3698, named in the picker Dan answered about PR #3751, is a PR: no pull requests found), so Dan was not asked and nothing was recorded: winding down still waits on it.',
    )
    expect(w.asked.length).toBe(2)
    // GitHub says #3698 is an issue: his answer stands from the next read, which comes once the
    // wait a failed read sets is over (#1777), ten minutes at most.
    w.o.gh = { ...h.merged(), others: closedBoth, notPrs: [3698] }
    await clock.advance(10 * h.MIN)
    const placed = (await h.stop($ as never)).block ?? ''
    expect(placed).toContain(' Left closed by Dan\'s choice: PR #3751 in o/r (Dan answered "Close it unmerged" in a picker naming it). ')
    expect(placed).not.toMatch(/PR #3751 was closed/)
    expect(placed).toContain(h.REOPEN(3752))
    expect(w.toasts).toEqual([])
  })
}
