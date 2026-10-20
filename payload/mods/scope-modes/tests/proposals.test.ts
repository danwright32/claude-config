import { describe, expect, test } from 'claude-code/testing'
import { CLAIM_MS, claimEntry, closeMatchIn, declinedEntry, declinedIn, filedEntry, issueLinkIn, judgeProposal, proposalPath } from '../hooks/proposals.ts'

// #1389: an overnight proposal is offered and filed once. On 2026-10-20 an Overture session was
// handed four proposals as never put to Dan that had been filed on 2026-10-09, and three of them had
// been filed twice, by two sessions seconds apart.

const SLEEP = '/Users/x/.claude/state/sleep'
const NOW = 10 * CLAIM_MS

describe('proposalPath: one folder per proposal, by its repository and title', () => {
  test('the same proposal from two nights is one folder, whatever the case and punctuation', () => {
    expect(proposalPath(SLEEP, 'Acme/Bidspoke', 'Bid totals round twice')).toBe(proposalPath(SLEEP, 'acme/bidspoke', 'bid totals: round twice!'))
  })
  test('another repository or another title is another folder', () => {
    const p = proposalPath(SLEEP, 'acme/bidspoke', 'Bid totals round twice')
    expect(proposalPath(SLEEP, 'acme/slate', 'Bid totals round twice')).not.toBe(p)
    expect(proposalPath(SLEEP, 'acme/bidspoke', 'Bid totals round once')).not.toBe(p)
  })
  test('it sits under the sleep folder, named so a file system takes it, however long the title', () => {
    const p = proposalPath(SLEEP, 'acme/bidspoke', `${'very long words '.repeat(40)}end`) as string
    expect(p.startsWith(`${SLEEP}/proposals/acme_bidspoke/`)).toBe(true)
    expect((p.split('/').pop() as string).length).toBeLessThanOrEqual(100)
    expect(p).toMatch(/^[\w./-]+$/)
  })
  test('two long titles that differ only past the cut are still two folders', () => {
    const lead = 'same words '.repeat(20)
    expect(proposalPath(SLEEP, 'a/b', `${lead}one`)).not.toBe(proposalPath(SLEEP, 'a/b', `${lead}two`))
  })
  test('a proposal with no title has no folder, since nothing can recognise it again', () => {
    expect(proposalPath(SLEEP, 'a/b', null)).toBeNull()
    expect(proposalPath(SLEEP, 'a/b', '  !! ')).toBeNull()
  })
})

describe('judgeProposal: what the entries say of a proposal now', () => {
  const open = new Set(['s1', 's7'])
  test('no entries: free, and the first claim is entry 1', () => {
    expect(judgeProposal({}, 's1', open, NOW)).toEqual({ state: 'free', next: 1 })
  })
  test("another open session's claim inside the window holds it", () => {
    expect(judgeProposal({ 1: claimEntry('s7', NOW - 1000) }, 's1', open, NOW)).toEqual({ state: 'held', by: 's7', at: NOW - 1000, next: 2 })
  })
  test("this session's own claim is its own, however old", () => {
    expect(judgeProposal({ 1: claimEntry('s1', NOW - 3 * CLAIM_MS) }, 's1', open, NOW)).toEqual({ state: 'mine', next: 2 })
  })
  test('a claim whose session has closed is free at once, so the proposal is not lost', () => {
    expect(judgeProposal({ 1: claimEntry('s5', NOW - 1000) }, 's1', open, NOW)).toEqual({ state: 'free', next: 2 })
  })
  test('a claim older than the window is free, though its session is still open', () => {
    expect(judgeProposal({ 1: claimEntry('s7', NOW - CLAIM_MS) }, 's1', open, NOW)).toEqual({ state: 'free', next: 2 })
    expect(judgeProposal({ 1: claimEntry('s7', NOW - CLAIM_MS + 1) }, 's1', open, NOW).state).toBe('held')
  })
  test('with the registry unreadable, only the window can free a claim', () => {
    expect(judgeProposal({ 1: claimEntry('s5', NOW - 1000) }, 's1', null, NOW).state).toBe('held')
    expect(judgeProposal({ 1: claimEntry('s5', NOW - CLAIM_MS) }, 's1', null, NOW).state).toBe('free')
  })
  test('the latest claim decides, not the first', () => {
    expect(judgeProposal({ 1: claimEntry('s1', NOW - 5000), 2: claimEntry('s7', NOW - 1000) }, 's1', open, NOW).state).toBe('held')
  })
  test('a filed entry is handled for good, whatever claims stand beside it', () => {
    const entries = { 1: claimEntry('s7', NOW - 1000), 2: filedEntry('s7', NOW, { url: 'https://github.com/acme/bidspoke/issues/12', number: 12 }) }
    expect(judgeProposal(entries, 's1', open, NOW)).toEqual({ state: 'filed', number: 12, url: 'https://github.com/acme/bidspoke/issues/12' })
    expect(judgeProposal({ ...entries, 3: claimEntry('s1', NOW) }, 's1', open, NOW).state).toBe('filed')
  })
  test('one Dan declined stays declined, never expiring as a claim does', () => {
    expect(judgeProposal({ 1: claimEntry('s7', NOW - 5 * CLAIM_MS), 2: declinedEntry('s7', NOW - 4 * CLAIM_MS) }, 's1', open, NOW)).toEqual({ state: 'declined', next: 3 })
  })
  test('filed outranks declined: Dan asking for it later files it, and it is filed for good', () => {
    const entries = { 1: declinedEntry('s7', NOW - 1000), 2: filedEntry('s1', NOW, { url: 'https://github.com/a/b/issues/3', number: 3 }) }
    expect(judgeProposal(entries, 's1', open, NOW).state).toBe('filed')
  })
  test('an entry that cannot be read decides nothing, but its number is never reused', () => {
    expect(judgeProposal({ 1: 'not json', 2: '{"kind":"other"}' }, 's1', open, NOW)).toEqual({ state: 'free', next: 3 })
  })
})

describe('closeMatchIn: the issue milestone-candidates.sh says this already is', () => {
  test('its first close match, by number, and whether it is closed', () => {
    const out = [
      'CANDIDATES-FOR acme/bidspoke',
      'CANDIDATE 2 #11 Totals page is slow [shares: total]',
      'CLOSE-MATCH 0.812 #4643 Bid totals round twice [in: Ungrouped] [shares: round, total, twice]',
      'CLOSE-MATCH 0.600 #12 Totals round down [in: Ungrouped] [shares: round, total] [closed]',
      'CLOSE-MATCH-COUNT 2',
    ].join('\n')
    expect(closeMatchIn(out)).toEqual({ number: 4643, title: 'Bid totals round twice', closed: false })
    expect(closeMatchIn('CLOSE-MATCH 0.600 #12 Totals round down [in: Ungrouped] [shares: round] [closed]\n')).toEqual({ number: 12, title: 'Totals round down', closed: true })
  })
  test('none when only siblings and duplicate risks share words: those never rule', () => {
    expect(closeMatchIn('CANDIDATE 3 #5 x [shares: a]\nDUPLICATE-RISK 2 #6 y [in: F] [shares: a, b]\nCLOSE-MATCH-COUNT 0\n')).toBeNull()
    expect(closeMatchIn('NO-CANDIDATES acme/bidspoke has nothing\n')).toBeNull()
  })
})

describe('declinedIn: the proposals Dan left unselected in a picker he answered', () => {
  const q = (options: string[], multiSelect = true) => [{ question: 'Which of these should be filed?', header: 'Issues', multiSelect, options: options.map(label => ({ label, description: 'x' })) }]
  const offered = new Set(['1.1', '1.2', '1.3'])
  test('each offered option he did not pick, by its number', () => {
    expect(declinedIn(q(['1.1 Bid totals', '1.2 Slow totals', '1.3 Zone']), { 'Which of these should be filed?': '1.2 Slow totals' }, offered)).toEqual(['1.1', '1.3'])
    expect(declinedIn(q(['1.1 Bid totals', '1.2 Slow totals']), { 'Which of these should be filed?': ['1.1 Bid totals'] }, offered)).toEqual(['1.2'])
    expect(declinedIn(q(['1.1 Bid totals', '1.2 Slow totals']), { 'Which of these should be filed?': '1.1 Bid totals, 1.2 Slow totals' }, offered)).toEqual([])
  })
  test('nothing from a picker left unanswered, which is asked again rather than read as declined', () => {
    expect(declinedIn(q(['1.1 Bid totals', '1.2 Slow totals']), {}, offered)).toEqual([])
    expect(declinedIn(q(['1.1 Bid totals', '1.2 Slow totals']), { 'Which of these should be filed?': '' }, offered)).toEqual([])
  })
  test('nothing from options that are not proposals this session offered: a lesson, a question, another picker', () => {
    expect(declinedIn(q(['2.1 Parse dates', '1.9 Not offered', 'Yes']), { 'Which of these should be filed?': 'Yes' }, offered)).toEqual([])
  })
})

describe('issueLinkIn: the issue gh issue create made', () => {
  test('the link gh prints, and its number', () => {
    expect(issueLinkIn('Creating issue in acme/bidspoke\n\nhttps://github.com/acme/bidspoke/issues/4650\n')).toEqual({ url: 'https://github.com/acme/bidspoke/issues/4650', number: 4650 })
  })
  test('none when nothing was made', () => {
    expect(issueLinkIn('could not create issue: HTTP 422')).toBeNull()
    expect(issueLinkIn('https://github.com/acme/bidspoke/pull/12')).toBeNull()
  })
})
