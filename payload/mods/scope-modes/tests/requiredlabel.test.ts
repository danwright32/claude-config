import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { gateAnswerOf, gateArgv, gateOf, openedFrom, type GateAnswer } from '../hooks/requiredlabel.ts'
import type { Ran } from '../hooks/adminmerge.ts'
import { GATE_LABEL_FIXTURES } from './gate-label-fixtures.ts'

// #3439: how sleep mode asks a project's merge gate which label it requires, and how it reads the
// session's record of the pull requests it opened. What a command is then allowed to do is judged
// from the command as written, in overnight.test.ts. The gate's answers are the committed set its
// own suite (payload/hooks/lib/changelog-entry.test.js) holds requiredLabels to, so the two sides
// are held to one set of cases, never to each other's reading of them (L58).
const ran = (stdout: string, more: Partial<Ran> = {}): Ran => ({ exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, ...more })
const UNKNOWN = (why: string): GateAnswer => ({ state: 'unknown', why })

describe('the gate asked which label it requires', () => {
  test('it is asked through its own library, by the repository, under this Mac home folder', () => {
    expect(gateArgv(`${'/Users'}/x`, 'o/r')).toEqual(['node', `${'/Users'}/x/.claude/hooks/lib/changelog-entry.js`, 'required-labels', 'o/r'])
  })
  test('every answer the gate gives is read as the gate means it (the shared fixtures)', () => {
    expect(GATE_LABEL_FIXTURES.length).toBeGreaterThanOrEqual(10)
    for (const c of GATE_LABEL_FIXTURES) {
      const got = gateAnswerOf(ran(`${JSON.stringify({ ...c.answer, why: c.answer.state === 'required' ? '' : 'because' })}\n`))
      const want: GateAnswer = c.answer.state === 'required' ? { state: 'required', labels: c.answer.labels } : c.answer.state === 'not-required' ? { state: 'not-required' } : UNKNOWN('because')
      expect({ name: c.name, got }).toEqual({ name: c.name, got: want })
    }
  })
  test('an answer that cannot be read is never a gate that requires nothing, nor one that requires anything', () => {
    expect(gateAnswerOf(ran('', { exitCode: 2, stderr: 'Usage: changelog-entry.js required-labels <owner/name> [registry file]\n' }))).toEqual(UNKNOWN('Usage: changelog-entry.js required-labels <owner/name> [registry file]'))
    expect(gateAnswerOf(ran('', { exitCode: 1 }))).toEqual(UNKNOWN('the gate exited 1'))
    expect(gateAnswerOf(ran('{"state":"required","labels":[', { isStdoutTruncated: true }))).toEqual(UNKNOWN('its answer was cut short'))
    expect(gateAnswerOf(ran(''))).toEqual(UNKNOWN('its answer was not JSON'))
    expect(gateAnswerOf(ran('not json'))).toEqual(UNKNOWN('its answer was not JSON'))
    const shape = UNKNOWN('its answer was not one this reader knows')
    for (const bad of [
      '[]',
      'null',
      '{}',
      '{"state":"maybe","labels":[]}',
      '{"state":"required"}',
      '{"state":"required","labels":[]}',
      '{"state":"required","labels":"changelog/none"}',
      '{"state":"required","labels":["changelog/none"]}',
      '{"state":"required","labels":[{"label":"changelog/none"}]}',
      '{"state":"required","labels":[{"label":"changelog/none","needsSentence":"no"}]}',
      '{"state":"required","labels":[{"label":"","needsSentence":false}]}',
      '{"state":"required","labels":[{"label":"a,b","needsSentence":false}]}',
      '{"state":"required","labels":[{"label":12,"needsSentence":false}]}',
    ])
      expect({ bad, got: gateAnswerOf(ran(bad)) }).toEqual({ bad, got: shape })
    // An unknown with no reason still says something.
    expect(gateAnswerOf(ran('{"state":"unknown","labels":[]}'))).toEqual(UNKNOWN('the gate gave no reason'))
  })
  test('the reader runs the gate once per question, and a run that cannot start is unknown with why', async () => {
    const asked: string[][] = []
    const gate = gateOf(async argv => {
      asked.push(argv)
      return ran('{"state":"not-required","why":"o/r is not listed","labels":[]}')
    }, `${'/Users'}/x`)
    expect(await gate('o/r')).toEqual({ state: 'not-required' })
    expect(asked).toEqual([gateArgv(`${'/Users'}/x`, 'o/r')])
    const broken = gateOf(async () => {
      throw new Error('posix_spawn node')
    }, `${'/Users'}/x`)
    expect(await broken('o/r')).toEqual(UNKNOWN('posix_spawn node'))
    // With no home folder there is no gate to find, and nothing is run.
    const none: string[][] = []
    const homeless = gateOf(async argv => {
      none.push(argv)
      return ran('{"state":"not-required","why":"x","labels":[]}')
    }, '')
    expect(await homeless('o/r')).toEqual(UNKNOWN('this session has no HOME folder to find the merge gate under'))
    expect(none).toEqual([])
  })
})

describe('the record of the pull requests this session opened', () => {
  test('a list of repository and number is read; anything else cannot be told', async () => {
    expect(await openedFrom(async () => [{ repo: 'o/r', number: 12, closes: [3439] }])()).toEqual([{ repo: 'o/r', number: 12 }])
    expect(await openedFrom(async () => [])()).toEqual([])
    expect(await openedFrom(async () => undefined)()).toEqual([])
    expect(await openedFrom(async () => null)()).toEqual([])
    expect(await openedFrom(async () => {
      throw new Error('state is locked')
    })()).toEqual({ why: 'state is locked' })
    const shape = { why: 'the record of the PRs this session opened is not a list this reader knows' }
    expect(await openedFrom(async () => 'o/r#12')()).toEqual(shape)
    expect(await openedFrom(async () => [{ repo: 'o/r' }])()).toEqual(shape)
    expect(await openedFrom(async () => [{ repo: 'o/r', number: '12' }])()).toEqual(shape)
    expect(await openedFrom(async () => [null])()).toEqual(shape)
  })
})
