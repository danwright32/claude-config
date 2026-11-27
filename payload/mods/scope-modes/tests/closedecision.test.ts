import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { closeDecisions, closesUnmerged, namedAsPr, notedSaid, notePicked, pickedClosed, picksSaid, placePicked, type PickedIo, type PlaceIo } from '../hooks/closedecision.ts'
import { leftByChoice, outstanding, type Reading } from '../hooks/winddown.ts'
import { CLOSE_IT, SIGN_OFF, SIGN_OFF_OPTIONS, signOff } from './close-decision-fixtures.ts'

// #3779: on 2026-11-26 Dan chose, in a picker, to close claude-config's pull request 3749 unmerged.
// An hour later winding down sent it back to be reopened and finished, and he was asked again. His
// own pick in the dialog is a decision no session can write for itself, so it is read here: one
// offered answer whose whole wording closes the pull request unmerged, about the one pull request
// the words he read name as a pull request. The picker he answered is kept word for word in
// close-decision-fixtures.ts.

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

test('only an answer whose whole wording closes the pull request unmerged is a decision to close it', () => {
  for (const yes of ['Close it unmerged', '3.79.1 Close it unmerged (Recommended)', '1. Close PR 31 without merging', 'Close it, do not merge', 'close it and never merge it', "Close it, don't merge", 'Closed unmerged'])
    expect({ label: yes, closes: closesUnmerged(yes) }).toEqual({ label: yes, closes: true })
  // Any other answer, the tool's own keep answers included (#917, #1033), a close that does not say
  // unmerged, and a sentence that only mentions closing.
  for (const no of ['Merge it', 'Keep it open', 'Leave it closed', 'Leave it open', 'Reopen it', 'Close it', 'Close the issue', "Don't close it unmerged", 'Never close it unmerged', 'Reopen it, never close it unmerged', 'Merge it, or close it unmerged later', ''])
    expect({ label: no, closes: closesUnmerged(no) }).toEqual({ label: no, closes: false })
})

// The independent read of #3779: "begins Close" and "says unmerged" were two separate tests, so an
// answer that closes something else and leaves the pull request open was read as closing it. Only
// an answer whose whole wording closes the pull request unmerged counts; one that could be read
// either way records nothing, so the pull request stays outstanding and he is asked.
test('an answer that leaves the pull request open, closes something else, or closes it only later is never his decision to close it unmerged (#3779)', () => {
  const about = 'Pull request 3749 still needs a count from the work MacBook. What should happen to the issue?'
  const one = (answer: string, question = about) => closeDecisions(picker(question, labels(answer, 'Merge it')), answered(question, answer))
  const leavesItOpen = [
    // The two the review found.
    'Close the issue and leave the PR unmerged for now',
    'Close #3692 as not planned, do not merge PR 3749 yet',
    // An issue closed while the pull request stays open.
    'Close the issue, keep the pull request open and unmerged',
    // Not merging yet says nothing of closing it.
    'Close the review thread, do not merge yet',
    'Close the review thread, not merging is fine',
    // Another pull request closed, in words this reader takes for none, beside this one kept.
    'Close #3750 unmerged, keep PR 3749',
    'Close the duplicate unmerged',
    // Closed already and to be undone, or to be closed only later or on a condition.
    'Closed unmerged by mistake: reopen it',
    'Close it unmerged later',
    'Close it unmerged once PR 3760 merges',
  ]
  expect(leavesItOpen.map(answer => ({ answer, closes: closesUnmerged(answer), decisions: one(answer).length }))).toEqual(leavesItOpen.map(answer => ({ answer, closes: false, decisions: 0 })))
  // An answer that closes another pull request by name is a decision about that one, never this one.
  expect(one('Close PR 3750 unmerged')).toEqual([{ pr: { number: 3750 }, answer: 'Close PR 3750 unmerged', unless: [] }])
  // And an answer that really does close this pull request unmerged still counts.
  const itself = 'Pull request 3749 is not needed. What should happen to it?'
  const closesIt = ['Close it unmerged', 'Close the pull request unmerged', 'Close this PR without merging it', 'Close pull request 3749 unmerged.', 'Close it and do not merge it', 'Closed unmerged']
  expect(closesIt.map(answer => ({ answer, read: one(answer, itself).map(d => d.pr) }))).toEqual(closesIt.map(answer => ({ answer, read: [{ number: 3749 }] })))
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
    opened: async () => [],
    state: async () => 'OPEN',
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
// The same answer once GitHub has said #3692, which its picker also named, is a pull request too.
const NOT_KEPT_3749 = { ...PICKED_3749, notKept: 'its picker also named #3692, which is a PR too, so which one he chose to close is not on record' }

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
  // It is a pull request: which one he meant is not on record, so his answer is not kept as his
  // choice. It stays on the record marked so, with why, for the turn end to say (the review's S4).
  let askedOfGitHub = 0
  const isPr = io({ named: async (_repo, refs) => (askedOfGitHub++, refs[0]) }, [open, waits])
  const dropped = await placePicked(isPr.made)
  expect(dropped.choices).toEqual([open, NOT_KEPT_3749])
  expect(dropped.unread.size).toBe(0)
  expect(isPr.seen).toMatchObject({ left: [open, NOT_KEPT_3749], writes: 1 })
  expect(isPr.seen.logs).toEqual(["Dan's answer about PR #3749 in o/r is not kept: its picker also named #3692, which is a PR too, so which one he chose to close is not on record"])
  // Marked, it is never asked about again, and never written again.
  await placePicked(isPr.made)
  expect(isPr.seen).toMatchObject({ left: [open, NOT_KEPT_3749], writes: 1 })
  expect(askedOfGitHub).toBe(1)
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
  expect((await placePicked(dropped.made)).choices).toEqual([OPEN_31, NOT_KEPT_3749, PICKED_3751])
  expect(dropped.seen.left).toEqual([OPEN_31, NOT_KEPT_3749, PICKED_3751])
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
  expect(placed.choices).toEqual([OPEN_31, NOT_KEPT_3749, other])
  expect(raced.seen).toMatchObject({ left: [OPEN_31, NOT_KEPT_3749, other], writes: 1, missed: 1 })
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

// ---- The independent read of #3779: what is said, a later answer, and another repository ----
const PICKED_31 = { repo: 'o/r', number: 31, closed: true as const, why: 'Dan answered "Close it unmerged" in a picker naming it', picked: true as const }
const closeOrMerge = labels('Close it unmerged', 'Merge it')
const RECORDED_TAIL = 'Winding down leaves it closed while it stays closed without merging, every turn end names it, and a later answer of his in a picker naming that pull request while it is still open, other than to close it unmerged, withdraws it.'

test('his pick is said the moment it is recorded, with the pull request named and his answer quoted (#3779)', async () => {
  // The picker of the day: recorded, and waiting on GitHub for the other number it named.
  const day = io()
  const noted = await notePicked(day.made, picker(), answered(SIGN_OFF, CLOSE_IT))
  expect(noted).toEqual({ recorded: [{ ...PICKED_3749, unless: [{ number: 3692 }] }], withdrawn: [], failed: [] })
  expect(notedSaid(noted)).toEqual([
    `Recorded as Dan's choice to close it unmerged: PR #3749 in o/r (Dan answered "3.79.1 Close it unmerged (Recommended)" in a picker naming it; not counted until GitHub says #3692, which that picker also named, is no pull request). ${RECORDED_TAIL}`,
  ])
  // With no other number named, nothing waits on GitHub.
  const plain = 'PR 31 is stale. What now?'
  const alone = await notePicked(io().made, picker(plain, closeOrMerge), answered(plain, 'Close it unmerged'))
  expect(notedSaid(alone)).toEqual([`Recorded as Dan's choice to close it unmerged: PR #31 in o/r (Dan answered "Close it unmerged" in a picker naming it). ${RECORDED_TAIL}`])
  // A picker with no decision in it, and one he answered another way with no pick on record, says nothing.
  const none = await notePicked(io().made, picker(plain, closeOrMerge), answered(plain, 'Merge it'))
  expect(none).toEqual({ recorded: [], withdrawn: [], failed: [] })
  expect(notedSaid(none)).toEqual([])
})

test('every turn end names each pull request he chose to close unmerged and quotes his answer, but for one the refusal already quotes (#3779)', () => {
  const tool: Left[number] = { repo: 'o/r', number: 716, closed: true, why: 'PR #720 superseded it' }
  // Only his own picks: an answer of his to leave_pr_open, open or closed, is the tool's to say.
  expect(picksSaid([OPEN_31, tool])).toBe('')
  expect(picksSaid([])).toBe('')
  expect(picksSaid([OPEN_31, PICKED_3749, tool])).toBe(
    'On record as Dan\'s choice to close unmerged: PR #3749 in o/r (Dan answered "3.79.1 Close it unmerged (Recommended)" in a picker naming it). Winding down leaves it closed while it stays closed without merging.',
  )
  // One still waiting on GitHub says so, and several are each named.
  expect(picksSaid([{ ...PICKED_3749, unless: [{ number: 3692 }, { repo: 'o/other', number: 7 }] }, PICKED_31])).toBe(
    'On record as Dan\'s choice to close unmerged: PR #3749 in o/r (Dan answered "3.79.1 Close it unmerged (Recommended)" in a picker naming it; not counted until GitHub says #3692 and o/other#7, which that picker also named, are no pull requests); PR #31 in o/r (Dan answered "Close it unmerged" in a picker naming it). Winding down leaves each closed while it stays closed without merging.',
  )
  // One the turn end's refusal already quotes is not said twice, and one not kept is no choice of his to name.
  expect(picksSaid([PICKED_3749, PICKED_31], d => d.number === 3749)).toBe('On record as Dan\'s choice to close unmerged: PR #31 in o/r (Dan answered "Close it unmerged" in a picker naming it). Winding down leaves it closed while it stays closed without merging.')
  expect(picksSaid([PICKED_3749], () => true)).toBe('')
  expect(picksSaid([NOT_KEPT_3749])).toBe('')
})

test('a later answer of his in a picker naming that pull request while it is still open, other than to close it unmerged, withdraws his pick (#3779)', async () => {
  const tool: Left[number] = { repo: 'o/r', number: 716, closed: true, why: 'PR #720 superseded it' }
  const again = 'Pull request 3749 turned out to be needed after all. What should happen to it?'
  const start = (): Left => [OPEN_31, PICKED_3749, PICKED_31, tool]
  // He picks to merge it: his earlier pick about it no longer stands, and every other answer is kept.
  const asked: string[] = []
  const merge = io({ state: async (repo, number) => (asked.push(`${repo}#${number}`), 'OPEN') }, start())
  const noted = await notePicked(merge.made, picker(again, closeOrMerge), answered(again, 'Merge it'))
  expect(merge.seen.left).toEqual([OPEN_31, PICKED_31, tool])
  expect(noted).toEqual({ recorded: [], withdrawn: [{ was: PICKED_3749, answer: 'Merge it' }], failed: [] })
  // GitHub was asked about that one pull request, once.
  expect(asked).toEqual(['o/r#3749'])
  // Closed already, his pick has been carried out: a later answer naming it withdraws nothing, so
  // a picker that only mentions the closed pull request never has him asked a second time.
  const closed = io({ state: async () => 'CLOSED' }, start())
  expect(await notePicked(closed.made, picker(again, closeOrMerge), answered(again, 'Merge it'))).toEqual({ recorded: [], withdrawn: [], failed: [] })
  expect(closed.seen).toMatchObject({ left: start(), writes: 0 })
  // GitHub cannot say whether it is still open: withdrawn, since asking him again is the harmless side.
  const unread = io({ state: async () => ({ unreadable: 'no network' }) }, start())
  expect((await notePicked(unread.made, picker(again, closeOrMerge), answered(again, 'Merge it'))).withdrawn).toEqual([{ was: PICKED_3749, answer: 'Merge it' }])
  expect(notedSaid(noted)).toEqual([
    'Withdrawn: Dan\'s choice to close PR #3749 in o/r unmerged (Dan answered "3.79.1 Close it unmerged (Recommended)" in a picker naming it) no longer stands, as he then answered "Merge it" in a picker naming that pull request. Winding down waits on it until it is merged, or until he is asked about it again.',
  ])
  // Words he typed there count too, and so does the pull request named by its # alone.
  const typed = io({}, start())
  await notePicked(typed.made, picker('What about #3749 now?', closeOrMerge), answered('What about #3749 now?', 'hold on, keep it open for Denys'))
  expect(typed.seen.left).toEqual([OPEN_31, PICKED_31, tool])
  // One waiting on GitHub, and one not kept, are withdrawn the same way.
  for (const was of [{ ...PICKED_3749, unless: [{ number: 3692 }] }, NOT_KEPT_3749]) {
    const waiting = io({}, [was])
    expect((await notePicked(waiting.made, picker(again, closeOrMerge), answered(again, 'Merge it'))).withdrawn).toEqual([{ was, answer: 'Merge it' }])
    expect(waiting.seen.left).toEqual([])
  }
  // The same pull request in another repository is another pull request.
  const elsewhere = io({}, start())
  await notePicked(elsewhere.made, picker('PR o/other#3749 is ready. What now?', closeOrMerge), answered('PR o/other#3749 is ready. What now?', 'Merge it'))
  expect(elsewhere.seen).toMatchObject({ left: start(), writes: 0 })
  // A picker naming another pull request withdraws nothing, writes nothing, and asks GitHub nothing.
  const other = io({ state: async () => { throw new Error('GitHub was asked') } }, start())
  expect(await notePicked(other.made, picker('PR 40 is ready. What now?', closeOrMerge), answered('PR 40 is ready. What now?', 'Merge it'))).toEqual({ recorded: [], withdrawn: [], failed: [] })
  expect(other.seen).toMatchObject({ left: start(), writes: 0 })
  // The same choice picked again replaces his earlier pick: recorded, never said as withdrawn.
  const same = io({}, start())
  const repicked = await notePicked(same.made, picker(again, closeOrMerge), answered(again, 'Close it unmerged'))
  const newer = { ...PICKED_3749, why: 'Dan answered "Close it unmerged" in a picker naming it' }
  expect(repicked).toEqual({ recorded: [newer], withdrawn: [], failed: [] })
  expect(same.seen.left).toEqual([OPEN_31, PICKED_31, tool, newer])
  // Nothing he did not answer withdraws it: a subagent's picker, a call carrying its own answers, a picker left unanswered.
  for (const [call, result] of [
    [{ ...picker(again, closeOrMerge), agentId: 'a1' }, answered(again, 'Merge it')],
    [{ ...picker(again, closeOrMerge), answers: { [again]: 'Merge it' } }, answered(again, 'Merge it')],
    [picker(again, closeOrMerge), { result: { answers: {} } }],
    [picker(again, closeOrMerge), answered(again, 'Merge it', { afkTimeoutMs: 60_000 })],
  ] as const) {
    const not = io({}, start())
    expect(await notePicked(not.made, call, result)).toEqual({ recorded: [], withdrawn: [], failed: [] })
    expect(not.seen).toMatchObject({ left: start(), writes: 0 })
  }
  // An answer of his to leave_pr_open is the tool's own, and no picker of a session's withdraws it.
  const tools = io({}, start())
  await notePicked(tools.made, picker('PR 716 again. What now?', closeOrMerge), answered('PR 716 again. What now?', 'Merge it'))
  expect(tools.seen).toMatchObject({ left: start(), writes: 0 })
})

test('a pull request in another repository is recorded there, and one this session opened under that number in two is not recorded (#3779)', async () => {
  // Named in plain words, "PR 31 in owner/name", as the review's picker did.
  expect(namedAsPr('PR 31 in danwright32/Ovation is not needed. Pull request #32 in o/r.')).toEqual([{ repo: 'danwright32/Ovation', number: 31 }, { repo: 'o/r', number: 32 }])
  const inWords = 'PR 31 in danwright32/Ovation is not needed. What now?'
  const plain = io()
  await notePicked(plain.made, picker(inWords, closeOrMerge), answered(inWords, 'Close it unmerged'))
  expect(plain.seen.left).toEqual([{ ...PICKED_31, repo: 'danwright32/Ovation' }])
  // Named by its number alone: the one pull request this session opened under it says which repository.
  const bare = 'PR 31 is not needed. What now?'
  const opened = io({ opened: async () => [{ repo: 'o/other', number: 31 }, { repo: 'o/r', number: 12 }] })
  await notePicked(opened.made, picker(bare, closeOrMerge), answered(bare, 'Close it unmerged'))
  expect(opened.seen.left).toEqual([{ ...PICKED_31, repo: 'o/other' }])
  // None opened under it: the session's own repository, where its branch's pull request is.
  const own = io({ opened: async () => [{ repo: 'o/other', number: 12 }] })
  await notePicked(own.made, picker(bare, closeOrMerge), answered(bare, 'Close it unmerged'))
  expect(own.seen.left).toEqual([PICKED_31])
  // Opened under that number in two repositories: which one he chose is not on record, and that is said.
  const two = io({ opened: async () => [{ repo: 'o/other', number: 31 }, { repo: 'O/R', number: 31 }] })
  const noted = await notePicked(two.made, picker(bare, closeOrMerge), answered(bare, 'Close it unmerged'))
  const why = 'Dan\'s answer "Close it unmerged" about PR #31 could not be recorded: this session opened a pull request numbered 31 in o/other and in O/R, and his picker named no repository, so which one he chose to close is not on record. Winding down asks about that PR as if he had not answered'
  expect(two.seen).toMatchObject({ left: [], writes: 0, logs: [why] })
  expect(noted).toEqual({ recorded: [], withdrawn: [], failed: [why] })
})

test('a pick that cannot be recorded, and one not kept, are said where the session reads them, never only in the debug log (#3779)', async () => {
  // Not recorded: the reason comes back with the picker's own result, for the session and for Dan.
  const noRepo = await notePicked(io({ slug: async () => undefined }).made, picker(), answered(SIGN_OFF, CLOSE_IT))
  const unknown = 'Dan\'s answer "3.79.1 Close it unmerged (Recommended)" about PR #3749 could not be recorded: this session\'s repository could not be read, so which repository it is in is not known. Winding down asks about that PR as if he had not answered'
  expect(noRepo).toEqual({ recorded: [], withdrawn: [], failed: [unknown] })
  expect(notedSaid(noRepo)).toEqual([`${unknown}.`])
  const noWrite = await notePicked(io({ setLeft: async () => { throw new Error('the state is read only') } }).made, picker(), answered(SIGN_OFF, CLOSE_IT))
  expect(notedSaid(noWrite)).toEqual(["Dan's answer to close a PR unmerged could not be recorded (the state is read only), so winding down asks about that PR as if he had not answered."])
  // Not kept: it settles nothing, and the turn end says why with the pull request, every time.
  expect(leftByChoice({ state: 'CLOSED' }, NOT_KEPT_3749)).toBe(false)
  const said = outstanding(reading('CLOSED', NOT_KEPT_3749))
  expect(said).toEqual([
    'PR #3749 was closed without merging: reopen it (gh pr reopen 3749) and finish it, as Dan would rather merge it. Ask him whether to leave it closed (mcp__scope-modes__leave_pr_open) only when he said earlier that another PR superseded it, passing his words as dan_said. Dan answered "3.79.1 Close it unmerged (Recommended)" in a picker naming it, but that answer is not kept as his choice to close it: its picker also named #3692, which is a PR too, so which one he chose to close is not on record',
  ])
  // With no answer of his at all, the same pull request is sent back in the plain words, as before.
  expect(outstanding(reading('CLOSED', undefined))).toEqual([said[0]?.split(' Dan answered')[0]?.replace(/\.$/, '')])
})
