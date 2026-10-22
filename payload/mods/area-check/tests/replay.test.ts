import { expect, test } from 'claude-code/testing'
import { RULE_VERSION, replay, type ReplayInput } from '../hooks/rules.ts'
import { MEASURED, PATHS } from './replay-fixture.ts'

// The replay (#1508): 30 days of a real repository's commits through these rules, each commit standing
// in for a session, measured by tools/area-check-replay.ts from this repository itself (public, so its
// paths may sit in a fixture, L155), the same way the calibration on #1506 was measured. A rule
// change that moves how often sessions would be held fails here, and is measured again rather than
// edited (L48, L354): node tools/area-check-replay.ts . --repo danwright32/claude-config --fixture ...

const input: ReplayInput = { ...MEASURED.input, sessions: MEASURED.input.sessions.map(s => ({ ...s, files: s.files.map(i => PATHS[i] as string) })) }

test('the measured month replays to the holds per session it was measured with', () => {
  expect(replay(input).summary).toEqual(MEASURED.summary)
})

test('the fixture is a real month, not a handful of rows (L606): hundreds of sessions, held and quiet both', () => {
  const s = MEASURED.summary
  expect(s.sessions).toBeGreaterThan(300)
  expect(s.withHold).toBeGreaterThan(0)
  expect(s.judgedSessions - s.withHold).toBeGreaterThan(0)
})

test('it was measured with the rules as they are now: a new rule version is measured again', () => {
  expect(MEASURED.rule).toBe(RULE_VERSION)
})
