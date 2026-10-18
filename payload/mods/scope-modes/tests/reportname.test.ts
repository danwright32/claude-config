import { describe, expect, test } from 'claude-code/testing'
import { reportBase, reportTitle } from '../hooks/reportname.ts'

// #1287: one sleep report per session with news, named night first, then the project, then the
// session (Dan, 2026-10-17): "2026-10-16 Bidspoke Fix the parser sleep report.md".

describe('reportTitle: the session title a report is named by', () => {
  test("auto naming's (project) prefix is dropped, since the project leads the name already", () => {
    expect(reportTitle('(bidspoke) Fix the parser')).toBe('Fix the parser')
    expect(reportTitle('Fix the parser')).toBe('Fix the parser')
  })
  test('no title, or one that is only the prefix or space, is none', () => {
    expect(reportTitle(null)).toBeNull()
    expect(reportTitle('   ')).toBeNull()
    expect(reportTitle('(bidspoke)')).toBeNull()
  })
})

describe('reportBase: the name, without .md', () => {
  test('night, project, session title, then sleep report', () => {
    expect(reportBase({ night: '2026-10-16', project: 'Bidspoke', title: 'Fix the parser', sessionId: '3f2a9c1e-1111-2222-3333-444444444444' })).toBe('2026-10-16 Bidspoke Fix the parser sleep report')
  })
  test('with no title yet, the first 8 characters of the session id', () => {
    expect(reportBase({ night: '2026-10-16', project: 'Bidspoke', title: null, sessionId: '3f2a9c1e-1111-2222-3333-444444444444' })).toBe('2026-10-16 Bidspoke 3f2a9c1e sleep report')
  })
  test('a second sleep the same night adds (2), and so on', () => {
    expect(reportBase({ night: '2026-10-12', project: 'Bidspoke', title: 'Fix the parser', sessionId: 's1', n: 2 })).toBe('2026-10-12 Bidspoke Fix the parser sleep report (2)')
    expect(reportBase({ night: '2026-10-12', project: 'Bidspoke', title: 'Fix the parser', sessionId: 's1', n: 1 })).toBe('2026-10-12 Bidspoke Fix the parser sleep report')
  })
  test('a slash, colon or control character in a title or project never makes a folder or a broken name', () => {
    expect(reportBase({ night: '2026-10-16', project: 'a/b', title: 'Fix: the\tparser / v2', sessionId: 's1' })).toBe('2026-10-16 a b Fix the parser v2 sleep report')
  })
  test('a very long title is cut, at a word, so the name stays readable', () => {
    const name = reportBase({ night: '2026-10-16', project: 'Bidspoke', title: 'word '.repeat(40), sessionId: 's1' })
    expect(name.length).toBeLessThanOrEqual(120)
    expect(name.endsWith(' sleep report')).toBe(true)
    expect(name).not.toMatch(/  /)
  })
})
