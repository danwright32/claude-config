import { describe, expect, test } from 'claude-code/testing'
import { BBEDIT, morningPrompt, openers, pickerTags, proposalsIn, SUMMARY_ASK, type ProposedIssue } from '../hooks/wake.ts'

// Sleep mode phase 9 (#837): what wake does once the record is moved aside, as pure decisions.

const line = (n: Record<string, unknown>) => JSON.stringify({ v: 1, generation: 'g0', at: 1, by: 's1', ...n })
// The two dashes the style rule bans, named by code point so this file holds neither.
const DASHES = new RegExp(`[${String.fromCharCode(0x2014, 0x2013)}]| - `)

describe("proposalsIn: the proposed issues and lessons in the night's notes", () => {
  test('each issue keeps its repository, title, priority, labels and milestone; each lesson its text', () => {
    const text = [
      line({ kind: 'issue', repo: 'o/r', title: 'Date parse drops the zone', priority: 'priority-p1', labels: ['bug', 'data-integrity'], milestone: 'Ungrouped', text: 'Seen in parse.ts.' }),
      line({ kind: 'claim', repo: 'o/r', issue: 3 }),
      line({ kind: 'lesson', text: "A date parsed without its zone is read in the Mac's zone." }),
      line({ kind: 'issue', repo: 'o/r', title: 'Tidy the logs', priority: 'p3', labels: 'tech-debt' }),
      '',
    ].join('\n')
    const p = proposalsIn(text)
    expect(p.issues).toEqual([
      { repo: 'o/r', title: 'Date parse drops the zone', priority: 'p1', priorityAsWritten: 'priority-p1', labels: ['bug', 'data-integrity'], milestone: 'Ungrouped', text: 'Seen in parse.ts.' },
      { repo: 'o/r', title: 'Tidy the logs', priority: 'p3', priorityAsWritten: 'p3', labels: ['tech-debt'], milestone: null, text: '' },
    ])
    expect(p.lessons).toEqual(["A date parsed without its zone is read in the Mac's zone."])
    expect(p.bad).toBe(0)
  })
  test('a line that cannot be read is counted, never dropped silently, and the rest still read', () => {
    const p = proposalsIn(`not json\n${line({ kind: 'lesson', text: 'x' })}\n[1,2]\n`)
    expect(p.lessons).toEqual(['x'])
    expect(p.bad).toBe(2)
  })
  test('a priority off the scale is kept as written, never coerced onto it', () => {
    const p = proposalsIn(line({ kind: 'issue', repo: 'o/r', title: 't', priority: 'high' }))
    expect(p.issues[0]?.priority).toBeNull()
    expect(p.issues[0]?.priorityAsWritten).toBe('high')
  })
  test('a lesson with no text proposes nothing, and is counted as unreadable', () => {
    const p = proposalsIn(line({ kind: 'lesson' }))
    expect(p.lessons).toEqual([])
    expect(p.bad).toBe(1)
  })
})

const issue = (o: Partial<ProposedIssue> = {}): ProposedIssue => ({ repo: 'o/r', title: 'T', priority: 'p2', priorityAsWritten: 'p2', labels: ['bug'], milestone: 'Ungrouped', text: '', ...o })

describe('pickerTags: the bracket the end of turn review ends each option with', () => {
  test('priority, then categories, then milestone, as issue-review.md writes it', () => {
    expect(pickerTags(issue({ labels: ['tech-debt', 'accessibility'] }))).toBe('[p2, tech-debt + accessibility, Ungrouped]')
  })
  test('each part not proposed says so, and an off scale priority shows what was written', () => {
    expect(pickerTags(issue({ priority: null, priorityAsWritten: null, labels: [], milestone: null }))).toBe('[priority not proposed, labels not proposed, milestone not proposed]')
    expect(pickerTags(issue({ priority: null, priorityAsWritten: 'high' }))).toBe('[priority "high" is off the p0 to p4 scale, bug, Ungrouped]')
  })
})

describe('morningPrompt: the summary and the morning pickers, on the session that woke it', () => {
  const both = morningPrompt({ worker: true, issues: [issue({ title: 'Date parse drops the zone', priority: 'p1', labels: ['bug', 'data-integrity'] })], lessons: ['Parse dates with their zone.'] })
  test('a worker summarises its own night first', () => {
    expect(both).toMatch(/^Dan is up: sleep mode is off\. Summarise for him in a few plain lines what this session did overnight/)
  })
  test("the issues go to the end of turn issue review's own multi select picker, each with what was proposed", () => {
    expect(both).toContain('~/.claude/hooks/review/issue-review.md')
    expect(both).toMatch(/ONE AskUserQuestion multiSelect picker/)
    expect(both).toContain('1.1 o/r: Date parse drops the zone [p1, bug + data-integrity, Ungrouped]')
    expect(both).toMatch(/File only what he selects/)
  })
  test('each lesson goes to the durable lesson picker, carrying its metadata word for word', () => {
    expect(both).toContain('~/.claude/hooks/durable-lesson-check.sh')
    expect(both).toContain('2.1 Parse dates with their zone. Metadata: {"source":"durable-lesson","rule":"Parse dates with their zone."}')
  })
  test('nothing was filed or added overnight, and the prompt says so', () => {
    expect(both).toMatch(/Nothing was filed and no lesson was added overnight/)
  })
  test('a session that did not work overnight has no summary of its own', () => {
    expect(morningPrompt({ worker: false, issues: [], lessons: [] })).toMatch(/This session was not enrolled overnight, so it has nothing of its own to summarise\./)
  })
  test('no proposals: no pickers, said once', () => {
    const none = morningPrompt({ worker: true, issues: [], lessons: [] })
    expect(none).toMatch(/No issue or lesson was proposed overnight, so there are no morning pickers\./)
    expect(none).not.toMatch(/AskUserQuestion/)
  })
  test('proposals that could not be read are said, pointing at the report', () => {
    expect(morningPrompt({ worker: true, issues: [], lessons: [], unread: 'EACCES' })).toMatch(/The night's proposed issues and lessons could not be read \(EACCES\); they are in the night's report/)
  })
  test('a lesson whose text holds a quote is still one valid metadata object', () => {
    const p = morningPrompt({ worker: true, issues: [], lessons: ['Say "never" once.'] })
    const meta = /Metadata: (\{.*\})$/m.exec(p)?.[1]
    expect(JSON.parse(meta as string)).toEqual({ source: 'durable-lesson', rule: 'Say "never" once.' })
  })
  test('no dashes as punctuation in what Claude is told', () => {
    expect(both).not.toMatch(DASHES)
    expect(SUMMARY_ASK).not.toMatch(DASHES)
  })
})

describe('openers: the BBEdit helper with its front window flag, then open -a BBEdit', () => {
  test('never a bare open', () => {
    const report = '/Users/x/Downloads/Sleep report 1969-12-31.md'
    expect(openers(report)).toEqual([
      [BBEDIT, '--front-window', report],
      ['open', '-a', 'BBEdit', report],
    ])
    expect(BBEDIT).toBe('/Applications/BBEdit.app/Contents/Helpers/bbedit_tool')
  })
})
