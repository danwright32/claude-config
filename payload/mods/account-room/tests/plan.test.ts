import { expect, test } from 'claude-code/testing'
import { PLANS, planOf, planText } from '../hooks/plan.ts'

// The plan a login is on, named from its organizationType (#1156). The values are the ones Claude
// Code 2.1.296 itself maps (claude_max, claude_pro, claude_enterprise, claude_team), measured from
// its build on 2026-10-13; claude_team is what this Mac's own login record held that day.

test('each organizationType Claude Code knows is named as the plan Dan buys', () => {
  expect(planOf('claude_team')).toBe('Team')
  expect(planOf('claude_max')).toBe('Max')
  expect(planOf('claude_pro')).toBe('Pro')
  expect(planOf('claude_enterprise')).toBe('Enterprise')
  // Every entry of the table is one of these: a value added later is tested by being added here.
  expect(Object.keys(PLANS).sort()).toEqual(['claude_enterprise', 'claude_max', 'claude_pro', 'claude_team'])
})

test('a value nobody has mapped is shown as it came, never hidden (Dan, 2026-10-13)', () => {
  expect(planOf('claude_free')).toBe('claude_free')
  // Control bytes go, so a value cannot colour or break the line it is drawn on; the ends are trimmed.
  expect(planOf(' claude_\u001b[31mx\u0007 ')).toBe('claude_[31mx')
})

test('no value, an empty one or one that is not text is no plan, not an unknown one', () => {
  expect(planOf(undefined)).toBeUndefined()
  expect(planOf(null)).toBeUndefined()
  expect(planOf('')).toBeUndefined()
  expect(planOf('  \u0000 ')).toBeUndefined()
  expect(planOf(7)).toBeUndefined()
})

test('the plan reads as "<plan> plan", so an org named Team is not mistaken for it', () => {
  expect(planText('Team')).toBe('Team plan')
  expect(planText('claude_free')).toBe('claude_free plan')
})
