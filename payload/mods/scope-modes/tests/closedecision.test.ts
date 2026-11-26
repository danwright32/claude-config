import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { closeDecisions, closesUnmerged, namedAsPr, notePicked, pickedClosed, placePicked, type PickedIo, type PlaceIo } from '../hooks/closedecision.ts'
import { leftByChoice, outstanding, type Reading } from '../hooks/winddown.ts'
import { CLOSE_IT, SIGN_OFF, SIGN_OFF_OPTIONS, signOff } from './close-decision-fixtures.ts'

// #3779: on 2026-11-26 Dan chose, in a picker, to close claude-config's pull request 3749 unmerged.
// An hour later winding down sent it back to be reopened and finished, and he was asked again. His
// own pick in the dialog is a decision no session can write for itself, so it is read here: one
// offered answer that begins "Close" and says unmerged, about the one pull request the words he read
// name as a pull request. The picker he answered is kept word for word in close-decision-fixtures.ts.

const picker = (question: string = SIGN_OFF, options: { label: string; description?: string }[] = SIGN_OFF_OPTIONS): Record<string, unknown> => signOff(question, options)
// What the dialog hands back: the questions it showed and his answer to each, by the question's words.
const answered = (question: string, answer: unknown, more: Record<string, unknown> = {}) => ({ result: { questions: [], answers: { [question]: answer }, annotations: {}, ...more } })
const labels = (...all: string[]) => all.map(label => ({ label, description: 'What it does.' }))

test('the picker Dan answered on 2026-11-26 is read as his decision to close pull request 3749 unmerged (#3779)', () => {
  expect(closeDecisions(picker(), answered(SIGN_OFF, CLOSE_IT))).toEqual([{ pr: { number: 3749 }, answer: CLOSE_IT, unless: [{ number: 3692 }] }])
  // What is recorded from it: the one record winding down reads a closed PR against, marked as
  // picked, with the other number his question named kept until GitHub says it is no pull request.
  expect(pickedClosed('danwright32/claude-config', { pr: { number: 3749 }, answer: CLOSE_IT, unless: [{ number: 3692 }] })).toEqual({
    repo: 'danwright32/claude-config',
    number: 3749,
    closed: true,
    why: 'Dan answered "3.79.1 Close it unmerged (Recommended)" in a picker naming it',
    picked: true,
    unless: [{ number: 3692 }],
  })
  // With no other number named, nothing is left to ask GitHub.
  expect(pickedClosed('o/r', { pr: { number: 31 }, answer: 'Close it unmerged', unless: [] })).toEqual({ repo: 'o/r', number: 31, closed: true, why: 'Dan answered "Close it unmerged" in a picker naming it', picked: true })
})

test('only an offered answer that begins Close and says unmerged is a decision to close it', () => {
  for (const yes of ['Close it unmerged', '3.79.1 Close it unmerged (Recommended)', '1. Close PR 31 without merging', 'Close it, do not merge', 'close it and never merge it', "Close it, don't merge", 'Closed unmerged'])
    expect({ label: yes, closes: closesUnmerged(yes) }).toEqual({ label: yes, closes: true })
  // Any other answer, the tool's own keep answers included (#917, #1033), a close that does not say
  // unmerged, and a sentence that only mentions closing.
  for (const no of ['Merge it', 'Keep it open', 'Leave it closed', 'Leave it open', 'Reopen it', 'Close it', 'Close the issue', "Don't close it unmerged", 'Never close it unmerged', 'Reopen it, never close it unmerged', 'Merge it, or close it unmerged later', ''])
    expect({ label: no, closes: closesUnmerged(no) }).toEqual({ label: no, closes: false })
})

test('a pull request is named only in words that say it is one, or by its link', () => {
  expect(namedAsPr('Sign off for #3692 (pull request 3749)')).toEqual([{ number: 3749 }])
  expect(namedAsPr('PR 31, PR #32, PR#33, pull request #34 and PR o/r#35')).toEqual([{ number: 31 }, { number: 32 }, { number: 33 }, { number: 34 }, { repo: 'o/r', number: 35 }])
  // Named twice it is one pull request; in another repository it is another.
  expect(namedAsPr('PR 31 again: pull request #31, and PR o/other#31')).toEqual([{ number: 31 }, { repo: 'o/other', number: 31 }])
  // A link names its pull request once mod-kit's link reader has said which repository it is in.
  const link = 'https://github.com/o/r/pull/716'
  expect(namedAsPr(`See ${link}`, new Map([[link, 'o/r']]))).toEqual([{ repo: 'o/r', number: 716 }])
  expect(namedAsPr(`See ${link}`)).toEqual([])
  // A bare number, an issue, a picker's own numbering and a count name no pull request.
  expect(namedAsPr('3.79 Sign off for #3692, issue 12, the 3 PRs and PR 3.79')).toEqual([])
})

test('his answer counts for the one pull request the words he read name, the answer first and then the question', () => {
  const one = (question: string, answer: string, offered: string[] = [answer, 'Merge it']) => closeDecisions(picker(question, labels(...offered)), answered(question, answer))
  // The answer names it: nothing else in the question changes which one he chose.
  expect(one('PR 711 was replaced by PR 716. What now?', 'Close PR 711 unmerged')).toEqual([{ pr: { number: 711 }, answer: 'Close PR 711 unmerged', unless: [] }])
  // The question names one pull request and nothing else.
  expect(one('PR o/r#31 is stale. What now?', 'Close it unmerged')).toEqual([{ pr: { repo: 'o/r', number: 31 }, answer: 'Close it unmerged', unless: [] }])
  // Another number beside it may be a pull request too, so it is kept for GitHub to say.
  expect(one('PR 711 lost its base (#716 carries the work). What now?', 'Close it unmerged')).toEqual([{ pr: { number: 711 }, answer: 'Close it unmerged', unless: [{ number: 716 }] }])
  // Two pull requests named and an answer naming neither: which one is not on record.
  expect(one('PR 711 was replaced by PR 716. What now?', 'Close it unmerged')).toEqual([])
  expect(one('PR 711 was replaced by PR 716. What now?', 'Close PR 711 and PR 716 unmerged')).toEqual([])
  // No pull request named as one: an issue's number is never read as a pull request.
  expect(one('Sign off for #3692. What should happen to it?', 'Close it unmerged')).toEqual([])
  // An answer that is no decision to close.
  expect(one('PR 31 is stale. What now?', 'Merge it', ['Close it unmerged', 'Merge it'])).toEqual([])
  expect(one('Leave PR #711 closed?', 'Leave it closed', ['Leave it closed', 'Reopen it'])).toEqual([])
})

test('nothing a session can write for itself, and nothing he did not pick, is read as his decision', () => {
  // The call carrying its own answers: only the dialog's answer is his.
  expect(closeDecisions({ ...picker(), answers: { [SIGN_OFF]: CLOSE_IT } }, answered(SIGN_OFF, CLOSE_IT))).toEqual([])
  // An empty set of answers on the call fills nothing in.
  expect(closeDecisions({ ...picker(), answers: {} }, answered(SIGN_OFF, CLOSE_IT)).length).toBe(1)
  // A subagent's picker.
  expect(closeDecisions({ ...picker(), agentId: 'a1' }, answered(SIGN_OFF, CLOSE_IT))).toEqual([])
  // A picker that was refused, failed, closed by itself while he was away, or came back unanswered.
  expect(closeDecisions(picker(), { deny: 'refused' })).toEqual([])
  expect(closeDecisions(picker(), { ...answered(SIGN_OFF, CLOSE_IT), isError: true })).toEqual([])
  expect(closeDecisions(picker(), answered(SIGN_OFF, CLOSE_IT, { afkTimeoutMs: 60_000 }))).toEqual([])
  expect(closeDecisions(picker(), { result: { answers: {} } })).toEqual([])
  expect(closeDecisions(picker(), {})).toEqual([])
  // Words he typed, or an answer the picker never offered: not a pick of an answer he was shown.
  expect(closeDecisions(picker(), answered(SIGN_OFF, 'close it unmerged'))).toEqual([])
  expect(closeDecisions(picker(), answered(SIGN_OFF, 'Close it unmerged'))).toEqual([])
  // Several answers at once say no one thing, whether picked or the picker allowed it.
  expect(closeDecisions(picker(), answered(SIGN_OFF, [CLOSE_IT]))).toEqual([])
  expect(closeDecisions({ questions: [{ question: SIGN_OFF, header: '3.79 #3692', multiSelect: true, options: SIGN_OFF_OPTIONS }] }, answered(SIGN_OFF, CLOSE_IT))).toEqual([])
  // An answer given to another question than the one that names the pull request.
  expect(closeDecisions(picker(), answered('Some other question?', CLOSE_IT))).toEqual([])
  // A call that is no picker at all.
  expect(closeDecisions({}, answered(SIGN_OFF, CLOSE_IT))).toEqual([])
  expect(closeDecisions({ questions: 'not a list' }, answered(SIGN_OFF, CLOSE_IT))).toEqual([])
})

test('an answer to a picker he could not read whole records nothing', () => {
  // The hidden character is made from its code point, never written here.
  const zw = String.fromCodePoint(0x200b)
  const hidden = `PR 31 is stale${zw}. What now?`
  expect(closeDecisions(picker(hidden, labels('Close it unmerged', 'Merge it')), answered(hidden, 'Close it unmerged'))).toEqual([])
  const hiddenAnswer = `Close it unmerged${zw}`
  expect(closeDecisions(picker('PR 31 is stale. What now?', labels(hiddenAnswer, 'Merge it')), answered('PR 31 is stale. What now?', hiddenAnswer))).toEqual([])
  const long = `PR 31 is stale. ${'word '.repeat(400)}What now?`
  expect(closeDecisions(picker(long, labels('Close it unmerged', 'Merge it')), answered(long, 'Close it unmerged'))).toEqual([])
  // The same picker in plain words is read.
  expect(closeDecisions(picker('PR 31 is stale. What now?', labels('Close it unmerged', 'Merge it')), answered('PR 31 is stale. What now?', 'Close it unmerged')).length).toBe(1)
})

// The one rule for a PR left as it is (leftByChoice) and what the finish check lists (outstanding).
const reading = (state: 'OPEN' | 'CLOSED', choice: Reading['choice'], more: Partial<Reading> = {}): Reading => ({
  branch: '',
  isDefault: false,
  pr: { number: 3749, state, head: 'aaa1111', issues: [] },
  branchHere: false,
  branchOnGitHub: false,
  worktreeOnBranch: false,
  deploy: null,
  dirty: [],
  ...(choice ? { choice } : {}),
  ...more,
})

test('a PR he chose to close is settled while it stays closed, never while another number his picker named is unplaced, and never once reopened', () => {
  const stands = pickedClosed('o/r', { pr: { number: 3749 }, answer: CLOSE_IT, unless: [] })
  const waits = pickedClosed('o/r', { pr: { number: 3749 }, answer: CLOSE_IT, unless: [{ number: 3692 }] })
  expect(leftByChoice({ state: 'CLOSED' }, stands)).toBe(true)
  expect(outstanding(reading('CLOSED', stands))).toEqual([])
  // GitHub has not yet said whether #3692 is a pull request: not settled, and never sent back to be reopened.
  expect(leftByChoice({ state: 'CLOSED' }, waits)).toBe(false)
  const waiting = outstanding(reading('CLOSED', waits, { choiceUnread: 'whether #3692, named in the picker Dan answered about PR #3749, is a PR: no pull requests found' }))
  expect(waiting).toEqual([
    'PR #3749 was closed without merging, and Dan answered "3.79.1 Close it unmerged (Recommended)" in a picker naming it, which settles it once GitHub says #3692, which that picker also named, is no pull request. That could not be read (whether #3692, named in the picker Dan answered about PR #3749, is a PR: no pull requests found), so leave it closed until GitHub answers',
  ])
  expect(waiting.join(' ')).not.toMatch(/reopen it/)
  // Reopened, his answer was about closing it, and it is outstanding until merged.
  expect(leftByChoice({ state: 'OPEN', head: 'aaa1111' }, stands)).toBe(false)
  expect(outstanding(reading('OPEN', stands))).toEqual(['PR #3749 is not merged yet'])
  // With no answer of his, a closed PR is reopened and finished as before (#1767).
  expect(outstanding(reading('CLOSED', undefined)).join(' ')).toMatch(/^PR #3749 was closed without merging: reopen it \(gh pr reopen 3749\) and finish it, as Dan would rather merge it\./)
})

// ---- Recording his pick, and placing the other numbers its picker named ----
// The caller's state, repository, link reader and GitHub reads are handed in, so they are faked here.
type Left = Parameters<PickedIo['setLeft']>[0]
const io = (over: Partial<PickedIo & PlaceIo> = {}, start: Left = []) => {
  // `between` is what another writer does between one read of the record and the write that follows it.
  const seen = { left: start, version: 1, writes: 0, missed: 0, between: [] as (() => void)[], logs: [] as string[], asked: [] as string[] }
  const made: PickedIo & PlaceIo = {
    slug: async () => 'o/r',
    linkRepo: async () => 'o/r',
    left: async () => ({ value: seen.left, version: seen.version }),
    // A write lands only on the version it read, as the engine's state does with ifVersion.
    setLeft: async (all, ifVersion) => {
      seen.between.shift()?.()
      if (ifVersion !== seen.version) {
        seen.missed++
        return { isSet: false }
      }
      seen.left = all
      seen.version++
      seen.writes++
      return { isSet: true }
    },
    log: line => void seen.logs.push(line),
    named: async (_repo, refs) => {
      seen.asked.push(refs.map(r => `#${r.number}`).join(','))
      return undefined
    },
    ...over,
  }
  // Another writer's whole write, as leave_pr_open or another picker's answer lands it.
  const lands = (all: Left) => {
    seen.left = all
    seen.version++
  }
  return { made, seen, lands }
}
const PICKED_3749 ={ repo: 'o/r', number: 3749, closed: true as const, why: 'Dan answered "3.79.1 Close it unmerged (Recommended)" in a picker naming it', picked: true as const }

test('his pick is recorded against the PR in the repository it is in, one answer per PR, the newest kept', async () => {
  const earlier: Left = [
    { repo: 'O/R', number: 3749, head: 'aaa1111', why: 'awaiting review' },
    { repo: 'o/r', number: 31, head: 'bbb2222', why: 'for a reviewer' },
  ]
  const { made, seen } = io({}, earlier)
  await notePicked(made, picker(), answered(SIGN_OFF, CLOSE_IT))
  // His earlier answer about #3749 is replaced; the one about #31 is kept as it was.
  expect(seen.left).toEqual([earlier[1], { ...PICKED_3749, unless: [{ number: 3692 }] }])
  expect(seen.writes).toBe(1)
  expect(seen.logs).toEqual([])
  // A repository its words name is the one it is recorded in, never the session's.
  const other = io({ slug: async () => 'o/session' })
  await notePicked(other.made, picker('PR o/other#31 is stale. What now?', labels('Close it unmerged', 'Merge it')), answered('PR o/other#31 is stale. What now?', 'Close it unmerged'))
  expect(other.seen.left).toEqual([{ repo: 'o/other', number: 31, closed: true, why: 'Dan answered "Close it unmerged" in a picker naming it', picked: true }])
  // A picker with no decision in it writes nothing and reads no link.
  const none = io({ linkRepo: async () => { throw new Error('never asked') } })
  await notePicked(none.made, picker('See https://github.com/o/r/pull/31. Merge it?', labels('Merge it', 'Keep it open')), answered('See https://github.com/o/r/pull/31. Merge it?', 'Merge it'))
  expect(none.seen).toMatchObject({ writes: 0, logs: [] })
})

test('a pick that cannot be recorded is logged and never thrown, so his answer still reaches Claude', async () => {
  // The session's repository cannot be read, so which repository PR 3749 is in is not known.
  const noRepo = io({ slug: async () => undefined })
  await notePicked(noRepo.made, picker(), answered(SIGN_OFF, CLOSE_IT))
  expect(noRepo.seen.writes).toBe(0)
  expect(noRepo.seen.logs).toEqual([
    'Dan\'s answer "3.79.1 Close it unmerged (Recommended)" about PR #3749 could not be recorded: this session\'s repository could not be read, so which repository it is in is not known. Winding down asks about that PR as if he had not answered',
  ])
  // A link whose repository cannot be read is never read as naming nothing.
  const linked = 'PR 31 replaces https://github.com/o/r/pull/30. What now?'
  const noLink = io({ linkRepo: async () => { throw new Error('mod-kit is not loaded') } })
  await notePicked(noLink.made, picker(linked, labels('Close it unmerged', 'Merge it')), answered(linked, 'Close it unmerged'))
  expect(noLink.seen.writes).toBe(0)
  expect(noLink.seen.logs).toEqual(["Dan's answer to close a PR unmerged could not be recorded (mod-kit is not loaded), so winding down asks about that PR as if he had not answered"])
  // And read, the link names a second pull request, so which one he meant is not on record.
  const two = io()
  await notePicked(two.made, picker(linked, labels('Close it unmerged', 'Merge it')), answered(linked, 'Close it unmerged'))
  expect(two.seen).toMatchObject({ writes: 0, logs: [] })
  // The record cannot be written.
  const noWrite = io({ setLeft: async () => { throw new Error('the state is read only') } })
  await notePicked(noWrite.made, picker(), answered(SIGN_OFF, CLOSE_IT))
  expect(noWrite.seen.logs).toEqual(["Dan's answer to close a PR unmerged could not be recorded (the state is read only), so winding down asks about that PR as if he had not answered"])
})

test('a pick whose picker named another number stands once GitHub says it is no pull request, waits while GitHub cannot say, and is dropped where it is one', async () => {
  const waits = { ...PICKED_3749, unless: [{ number: 3692 }] }
  const open: Left[number] = { repo: 'o/r', number: 31, head: 'bbb2222', why: 'for a reviewer' }
  // No pull request: it stands, the number is taken off the record, and the list is written once.
  const stands = io({}, [open, waits])
  const placed = await placePicked(stands.made)
  expect(placed.choices).toEqual([open, PICKED_3749])
  expect(placed.unread.size).toBe(0)
  expect(stands.seen).toMatchObject({ left: [open, PICKED_3749], writes: 1, asked: ['#3692'] })
  // Placed already, GitHub is not asked again and nothing is written.
  const again = await placePicked(stands.made)
  expect(again.choices).toEqual([open, PICKED_3749])
  expect(stands.seen).toMatchObject({ writes: 1, asked: ['#3692'] })
  // GitHub cannot say: it waits unchanged, with why, and nothing is written.
  const unreadable = io({ named: async () => ({ unreadable: 'whether #3692, named in the picker Dan answered about PR #3749, is a PR: no pull requests found' }) }, [open, waits])
  const waiting = await placePicked(unreadable.made)
  expect(waiting.choices).toEqual([open, waits])
  expect(waiting.unread.get(waiting.choices[1] as Left[number])).toBe('whether #3692, named in the picker Dan answered about PR #3749, is a PR: no pull requests found')
  expect(unreadable.seen.writes).toBe(0)
  // It is a pull request: which one he meant is not on record, so his answer is not kept, and that is logged.
  const isPr = io({ named: async (_repo, refs) => refs[0] }, [open, waits])
  const dropped = await placePicked(isPr.made)
  expect(dropped.choices).toEqual([open])
  expect(isPr.seen).toMatchObject({ left: [open], writes: 1 })
  expect(isPr.seen.logs).toEqual(["Dan's answer about PR #3749 in o/r is not kept: its picker also named #3692, which is a PR too, so which one he chose to close is not on record"])
  // Only the ones asked for are placed.
  const narrow = io({}, [waits, { ...waits, number: 3751 }])
  const one = await placePicked(narrow.made, d => d.number === 3751)
  expect(one.choices).toEqual([waits, { ...PICKED_3749, number: 3751 }])
  expect(narrow.seen.asked).toEqual(['#3692'])
})

// The lessons review of #3779: placing read the record, waited on GitHub, then wrote the list it
// had read back whole, so an answer of his recorded during that wait was written over. GitHub is
// still asked first; what it said is then applied to the record as it stands when written.
const WAITS = { ...PICKED_3749, unless: [{ number: 3692 }] }
const OPEN_31: Left[number] = { repo: 'o/r', number: 31, head: 'bbb2222', why: 'for a reviewer' }
const NOT_ASKED = (other: number) => `whether #${other}, named in the picker Dan answered about PR #3749, is a PR: GitHub has not been asked yet, as that answer was recorded while it was being asked about an earlier one`

test('an answer of his recorded while GitHub is being asked about an earlier one is kept, and so is the earlier one (#3779)', async () => {
  // While GitHub is asked whether #3692 is a PR, he answers a second picker, about PR 3751.
  const second = 'Pull request 3751 is not needed either. What should happen to it?'
  const both = io({}, [OPEN_31, WAITS])
  both.made.named = async () => {
    await notePicked(both.made, picker(second, labels('Close it unmerged', 'Merge it')), answered(second, 'Close it unmerged'))
    return undefined
  }
  const PICKED_3751 = { repo: 'o/r', number: 3751, closed: true as const, why: 'Dan answered "Close it unmerged" in a picker naming it', picked: true as const }
  const placed = await placePicked(both.made)
  expect(both.seen.left).toEqual([OPEN_31, PICKED_3749, PICKED_3751])
  expect(placed.choices).toEqual([OPEN_31, PICKED_3749, PICKED_3751])
  expect(placed.unread.size).toBe(0)
  expect(both.seen).toMatchObject({ writes: 2, missed: 0, logs: [] })
  // The same where the earlier answer is dropped: GitHub says #3692 is a PR too.
  const dropped = io({}, [OPEN_31, WAITS])
  dropped.made.named = async (_repo, refs) => {
    await notePicked(dropped.made, picker(second, labels('Close it unmerged', 'Merge it')), answered(second, 'Close it unmerged'))
    return refs[0]
  }
  expect((await placePicked(dropped.made)).choices).toEqual([OPEN_31, PICKED_3751])
  expect(dropped.seen.left).toEqual([OPEN_31, PICKED_3751])
})

test('what GitHub said is applied only to the answer it was asked about, never to one that replaced it or to one withdrawn meanwhile (#3779)', async () => {
  // He answers about PR 3749 again while GitHub is asked, in a picker naming another number, #3700.
  const again = { ...PICKED_3749, unless: [{ number: 3700 }] }
  const replaced = io({}, [OPEN_31, WAITS])
  replaced.made.named = async () => (replaced.lands([OPEN_31, again]), undefined)
  const placed = await placePicked(replaced.made)
  // #3692 is no PR, which says nothing of #3700: his newer answer waits, and is said not to be asked about yet.
  expect(replaced.seen).toMatchObject({ left: [OPEN_31, again], writes: 0 })
  expect(placed.choices).toEqual([OPEN_31, again])
  expect([...placed.unread]).toEqual([[placed.choices[1], NOT_ASKED(3700)]])
  // #3692 is a PR, so the answer naming it would be dropped: his answer to leave_pr_open since is not.
  const leftClosed: Left[number] = { repo: 'o/r', number: 3749, closed: true, why: 'PR #716 superseded it' }
  const answeredSince = io({}, [OPEN_31, WAITS])
  answeredSince.made.named = async (_repo, refs) => (answeredSince.lands([OPEN_31, leftClosed]), refs[0])
  expect((await placePicked(answeredSince.made)).choices).toEqual([OPEN_31, leftClosed])
  expect(answeredSince.seen).toMatchObject({ left: [OPEN_31, leftClosed], writes: 0, logs: [] })
  // Withdrawn meanwhile (he chose to merge it after all), it is not put back by GitHub's answer.
  const withdrawn = io({}, [OPEN_31, WAITS])
  withdrawn.made.named = async () => (withdrawn.lands([OPEN_31]), undefined)
  expect((await placePicked(withdrawn.made)).choices).toEqual([OPEN_31])
  expect(withdrawn.seen).toMatchObject({ left: [OPEN_31], writes: 0 })
})

test('a write the record changed under is made again on the newer record, said once, and one that never lands is an error (#3779)', async () => {
  // Another answer lands between the read the write was made from and the write itself.
  const other: Left[number] = { repo: 'o/r', number: 40, head: 'ccc3333', why: 'awaiting review' }
  const raced = io({ named: async (_repo, refs) => refs[0] }, [OPEN_31, WAITS])
  raced.seen.between.push(() => raced.lands([OPEN_31, WAITS, other]))
  const placed = await placePicked(raced.made)
  expect(placed.choices).toEqual([OPEN_31, other])
  expect(raced.seen).toMatchObject({ left: [OPEN_31, other], writes: 1, missed: 1 })
  expect(raced.seen.logs).toEqual(["Dan's answer about PR #3749 in o/r is not kept: its picker also named #3692, which is a PR too, so which one he chose to close is not on record"])
  // His pick is recorded on the newer record the same way.
  const noted = io({}, [OPEN_31])
  noted.seen.between.push(() => noted.lands([OPEN_31, other]))
  await notePicked(noted.made, picker(), answered(SIGN_OFF, CLOSE_IT))
  expect(noted.seen).toMatchObject({ left: [OPEN_31, other, WAITS], writes: 1, missed: 1, logs: [] })
  // A record that changes under every attempt: placing throws, so the turn end is refused, and a pick is logged as not recorded.
  const never = io({}, [OPEN_31, WAITS])
  never.made.setLeft = async () => ({ isSet: false })
  await expect(placePicked(never.made)).rejects.toThrow('the record of his answers changed under every one of 10 attempts to write it')
  await notePicked(never.made, picker(), answered(SIGN_OFF, CLOSE_IT))
  expect(never.seen.left).toEqual([OPEN_31, WAITS])
  expect(never.seen.logs).toEqual(["Dan's answer to close a PR unmerged could not be recorded (the record of his answers changed under every one of 10 attempts to write it), so winding down asks about that PR as if he had not answered"])
})
