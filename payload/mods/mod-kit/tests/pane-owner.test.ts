import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { register } from '../hooks/register.tsx'

// #3285: a mod opens its own side pane with $.ui.open and mod-kit draws the card in it. Claude Code
// names the mod that opened a pane as the pane's owner (`plugin`), and a Pane hook whose matcher
// names no owner hears only its own mod's panes. mod-kit's hook named none, so the manual steps
// pane drew empty (Dan, 2026-11-19). The test kit mounts every drawing with no owner at all
// (measured on 2.1.328: a Pane hook reads `e.plugin` as undefined whatever the mount names), so no
// mounted test can see this. The rule is applied here to the matchers mod-kit registers instead.

type Matcher = { component?: unknown; plugin?: unknown }
const SELF = 'mod-kit'

// Claude Code's rule for an event that names an owner (the types' `plugin`, "a default matcher key:
// a hook leaving it out hears its own plugin's drawings alone; one naming it is read as written,
// { plugin: "*" } for all").
const names = (value: unknown, owner: string) =>
  value === '*' || value === owner || (Array.isArray(value) && value.some(v => v === '*' || v === owner))
const hearsPane = (m: Matcher | undefined, owner: string) => {
  if (m?.component !== undefined && m.component !== 'Pane' && !(Array.isArray(m.component) && m.component.includes('Pane'))) return false
  return m?.plugin === undefined ? owner === SELF : names(m.plugin, owner)
}

const paneMatchers = () => {
  const seen: Matcher[] = []
  register(((event: string, matcher: unknown) => {
    if (event === 'ui.render' && typeof matcher === 'object' && matcher !== null) seen.push(matcher as Matcher)
  }) as never, {} as never)
  return seen.filter(m => m.component === 'Pane' || (Array.isArray(m.component) && m.component.includes('Pane')))
}

test("mod-kit's pane hook hears a pane another mod opened, the manual steps card's among them", async () => {
  const matchers = paneMatchers()
  expect(matchers.length).toBeGreaterThan(0)
  for (const owner of ['manual-steps', 'any-other-mod']) {
    expect(matchers.some(m => hearsPane(m, owner))).toBe(true)
  }
})

test('the rule read here is the one that left the pane empty: a matcher naming no owner hears its own mod alone', () => {
  expect(hearsPane({ component: 'Pane' }, 'manual-steps')).toBe(false)
  expect(hearsPane({ component: 'Pane' }, SELF)).toBe(true)
  expect(hearsPane({ component: 'Pane', plugin: 'manual-steps' }, 'manual-steps')).toBe(true)
  expect(hearsPane({ component: 'Pane', plugin: 'goal-tracker' }, 'manual-steps')).toBe(false)
  expect(hearsPane({ component: 'Pane', plugin: '*' }, 'manual-steps')).toBe(true)
})
