import { describe, expect, test } from 'claude-code/testing'
import { ACK_LEAD, ackOff, ackOn, MODE_DEF, modeDoes, type Mode } from '../hooks/modes.ts'
import { FINISHED, NEW_WORK, newWork } from '../hooks/winddown.ts'

const MODES = Object.keys(MODE_DEF) as Mode[]

// #1055: Dan switched to winding down and had to ask what it does; the answer had three
// differences from what he assumed. Each switch now opens Claude's reply with what the mode does,
// from the one definition the mode's own note is built from (L41).
describe('the acknowledgement of a mode switch (#1055)', () => {
  test('every mode scope-modes switches has a definition: the scope modes and both places', () => {
    expect([...MODES].sort()).toEqual(['NO BUILD', 'WINDING DOWN', 'away', 'home'])
  })

  test("names the mode, then says what it will and will not do, in its definition's own words", () => {
    for (const mode of MODES) {
      const d = MODE_DEF[mode]
      const said = ackOn(mode)
      expect(said.startsWith(`${ACK_LEAD} "${d.name} is on. `)).toBe(true)
      expect(said).toContain(`I will ${d.will}.`)
      expect(said).toContain(`I will not ${d.willNot}.`)
      expect(said).toContain(modeDoes(mode))
      // Two or three sentences after the name, never a paragraph.
      expect(modeDoes(mode).split(/(?<=\.)\s+/).length).toBeLessThanOrEqual(3)
    }
  })

  test('says which mode it replaced when another was on, and nothing when the same one is turned on again', () => {
    expect(ackOn('WINDING DOWN', { replaced: 'NO BUILD' })).toContain('Winding down is on. It replaces no build. I will')
    expect(ackOn('NO BUILD', { replaced: 'WINDING DOWN' })).toContain('No build is on. It replaces winding down. I will')
    expect(ackOn('WINDING DOWN', { replaced: 'WINDING DOWN' })).not.toContain('replaces')
    expect(ackOn('WINDING DOWN', { replaced: null })).not.toContain('replaces')
  })

  test('a place opens with what was switched, then what it does', () => {
    const first = 'Away is on in this session and 2 others.'
    expect(ackOn('away', { first })).toBe(`${ACK_LEAD} "${first} ${modeDoes('away')}"`)
  })

  test('turning a scope mode off says what it no longer stops', () => {
    expect(ackOff('WINDING DOWN')).toContain('Winding down is off.')
    expect(ackOff('WINDING DOWN')).toContain(MODE_DEF['WINDING DOWN'].willNot)
    expect(ackOff('NO BUILD')).toContain(MODE_DEF['NO BUILD'].willNot)
  })

  test('winding down says what its own guard refuses, in the words the refusal uses, and what finishing means', () => {
    const d = MODE_DEF['WINDING DOWN']
    for (const words of Object.values(NEW_WORK)) expect(d.willNot).toContain(words)
    expect(d.will).toContain(FINISHED)
    const call = (tool: string, input: Record<string, unknown>) => newWork({ tool, input, commands: [], issues: [616] })?.what
    expect(call('Skill', { skill: 'next-issue' })).toBe(NEW_WORK.nextIssue)
    expect(call('EnterWorktree', {})).toBe(NEW_WORK.branch)
    expect(call('Agent', { prompt: 'Build #700' })).toBe(NEW_WORK.agent.replace('another issue', 'issue #700'))
  })
})
