import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { gateAnswerOf, gateArgv, gateOf, openedFrom, sentenceNote, type GateAnswer } from '../hooks/requiredlabel.ts'
import type { Ran } from '../hooks/adminmerge.ts'
import { ASKED_BY_THE_MOD, ASKED_WITHOUT_THE_FLAG, GATED, GATED_AND_ANNOUNCING, GATE_LABEL_FIXTURES } from './gate-label-fixtures.ts'

// #3439: how sleep mode asks a project's merge gate which label it requires, and how it reads the
// session's record of the pull requests it opened. What a command is then allowed to do is judged
// from the command as written, in overnight.test.ts. The gate's answers are the committed set its
// own suite (payload/hooks/lib/changelog-entry.test.js) holds requiredLabels to, so the two sides
// are held to one set of cases, never to each other's reading of them (L58).
const ran = (stdout: string, more: Partial<Ran> = {}): Ran => ({ exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, ...more })
const UNKNOWN = (why: string): GateAnswer => ({ state: 'unknown', why })

describe('the gate asked which label it requires', () => {
  // #3665: the flag is how this reader says it understands a label's `needsDan`. Without it the gate
  // never lists the announce label, so a session running the mod as it was is never handed it.
  test('it is asked through its own library, by the repository, under this Mac home folder, saying it understands needsDan', () => {
    expect(gateArgv(`${'/Users'}/x`, 'o/r')).toEqual(['node', `${'/Users'}/x/.claude/hooks/lib/changelog-entry.js`, 'required-labels', 'o/r', '--needs-dan'])
  })
  test('every answer the gate gives a caller passing that flag is read as the gate means it (the shared fixtures)', () => {
    expect(ASKED_BY_THE_MOD.length).toBeGreaterThanOrEqual(5)
    // register.test.tsx reads the first case by position, as the answer its session is given.
    expect(GATE_LABEL_FIXTURES[0]?.name).toBe(GATED_AND_ANNOUNCING.name)
    for (const c of ASKED_BY_THE_MOD) {
      const got = gateAnswerOf(ran(`${JSON.stringify({ ...c.answer, why: c.answer.state === 'required' ? '' : 'because' })}\n`))
      const want: unknown = c.answer.state === 'required' ? { state: 'required', labels: c.answer.labels } : c.answer.state === 'not-required' ? { state: 'not-required' } : UNKNOWN('because')
      expect({ name: c.name, got }).toEqual({ name: c.name, got: want })
    }
    // The announce label arrives only where the repository names a channel, saying what it needs.
    const labelsOf = (answer: unknown) => {
      const got = gateAnswerOf(ran(JSON.stringify({ ...(answer as object), why: '' })))
      return got.state === 'required' ? got.labels : []
    }
    expect(labelsOf(GATED_AND_ANNOUNCING.answer).filter(l => l.label === 'changelog/announce')).toEqual([{ label: 'changelog/announce', needsSentence: true, needsAnnouncement: true, needsDan: true }])
    expect(labelsOf(GATED.answer).map(l => l.label)).toEqual(['changelog/visible', 'changelog/technical', 'changelog/none'])
    expect(labelsOf(GATED.answer).every(l => l.needsDan === false && l.needsAnnouncement === false)).toBe(true)
  })
  test('the answer a caller NOT passing the flag gets is not one this reader takes, since it does not say whether a label needs Dan', () => {
    const gated = ASKED_WITHOUT_THE_FLAG.filter(c => c.answer.state === 'required')
    expect(gated.length).toBeGreaterThanOrEqual(3)
    for (const c of gated) expect({ name: c.name, got: gateAnswerOf(ran(JSON.stringify({ ...c.answer, why: '' }))) }).toEqual({ name: c.name, got: UNKNOWN('its answer was not one this reader knows') })
  })
  test('what a session is told as it sets a label names each piece of writing the gate will ask for, and that the wording is Dan\'s to approve', () => {
    const label = (name: string) => {
      const got = gateAnswerOf(ran(JSON.stringify({ ...GATED_AND_ANNOUNCING.answer, why: '' })))
      const found = got.state === 'required' ? got.labels.find(l => l.label === name) : undefined
      if (!found) throw new Error(`the gate's answer holds no ${name}`)
      return found
    }
    // The label that needs only the sentence is told what it always was.
    expect(sentenceNote(label('changelog/visible'), 'o/r')).toBe('The merge gate of o/r refuses the merge of a PR labelled changelog/visible until its description carries the Changelog sentence a manager reads, so see that the description has it before merging.')
    expect(sentenceNote(label('changelog/announce'), 'o/r')).toBe(
      "The merge gate of o/r refuses the merge of a PR labelled changelog/announce until its description carries the Changelog sentence a manager reads and the post for agents under an Announcement heading, so see that the description has both before merging. The wording under changelog/announce is Dan's to approve before the PR merges.",
    )
    // A label that needs nothing has nothing to be told.
    expect(sentenceNote(label('changelog/none'), 'o/r')).toBe('')
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
      '{"state":"required","labels":[{"label":"changelog/none","needsSentence":"no","needsAnnouncement":false,"needsDan":false}]}',
      '{"state":"required","labels":[{"label":"","needsSentence":false,"needsAnnouncement":false,"needsDan":false}]}',
      '{"state":"required","labels":[{"label":"a,b","needsSentence":false,"needsAnnouncement":false,"needsDan":false}]}',
      '{"state":"required","labels":[{"label":12,"needsSentence":false,"needsAnnouncement":false,"needsDan":false}]}',
      // #3665: a label that does not say whether it needs Dan, or the post for agents, could not be read.
      '{"state":"required","labels":[{"label":"changelog/none","needsSentence":false}]}',
      '{"state":"required","labels":[{"label":"changelog/none","needsSentence":false,"needsAnnouncement":false}]}',
      '{"state":"required","labels":[{"label":"changelog/none","needsSentence":false,"needsDan":false}]}',
      '{"state":"required","labels":[{"label":"changelog/none","needsSentence":false,"needsAnnouncement":"no","needsDan":false}]}',
      '{"state":"required","labels":[{"label":"changelog/none","needsSentence":false,"needsAnnouncement":false,"needsDan":1}]}',
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
