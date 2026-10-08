import { expect, test } from 'claude-code/testing'
import {
  HEADER,
  SETTLED_NO,
  SETTLED_QUESTION,
  SETTLED_YES,
  SKIP_NO,
  SKIP_QUESTION,
  SKIP_YES,
  agentRefusal,
  isOwnRecord,
  isSwiftUI,
  lookKind,
  mentionedLookFiles,
  refusal,
  settledOptions,
  settledQuestion,
  skipOptions,
  skipQuestion,
  subjectsOf,
} from '../hooks/rules.ts'

// The design round guard's rules (claude-config#978), each on its own: which files change how a
// screen looks, what an issue or branch is keyed by, and what Claude and Dan read.

// The two dashes the writing style forbids, built from their code points so this file holds neither.
const DASHES = new RegExp(`[${String.fromCharCode(0x2014)}${String.fromCharCode(0x2013)}]`)

test('style, screen and component files, the Tailwind config and design tokens change the look; logic and docs do not', () => {
  for (const p of ['/r/app/globals.css', '/r/a.scss', '/r/a.sass', '/r/a.less', '/r/a.styl', '/r/a.pcss']) expect(lookKind(p)).toBe('style')
  for (const p of ['/r/app/page.tsx', '/r/Button.jsx', '/r/App.vue', '/r/Card.svelte', '/r/index.html', '/r/old.htm', '/r/payload/mods/x/hooks/register.tsx']) expect(lookKind(p)).toBe('screen')
  for (const p of ['/r/tailwind.config.js', '/r/tailwind.config.ts', '/r/tailwind.config.mjs', '/r/tailwind.config.cjs']) expect(lookKind(p)).toBe('tailwind')
  for (const p of ['/r/design-tokens.json', '/r/src/tokens.css', '/r/tokens.json', '/r/theme/colors.tokens.json', '/r/design_tokens.ts']) expect(lookKind(p)).toBe('tokens')
  expect(lookKind('/r/Views/Main.swift')).toBe('swift')
  // What passes untouched: logic, tests in plain TypeScript, docs, config, shell.
  for (const p of ['/r/app/route.ts', '/r/lib/date.js', '/r/README.md', '/r/package.json', '/r/hooks/rules.test.ts', '/r/run.sh', '/r/auth/token.ts', '/r/styles.py', '/r/htmlparse.ts'])
    expect(lookKind(p)).toBe(null)
})

test('a Swift file is a SwiftUI view when it imports SwiftUI or declares a view body', () => {
  expect(isSwiftUI('import SwiftUI\n\nstruct Main: View {}')).toBe(true)
  expect(isSwiftUI('struct Row: View {\n  var body: some View { Text("x") }\n}')).toBe(true)
  expect(isSwiftUI('import Foundation\n\nfunc parse(_ s: String) -> Date? { nil }')).toBe(false)
})

test('the look changing files a command only mentions are found by their names', () => {
  expect(mentionedLookFiles(`python3 - <<'EOF'\nopen('app/page.tsx','w').write(x)\nEOF`)).toEqual(['app/page.tsx'])
  expect(mentionedLookFiles('git apply fix.patch')).toEqual([])
  expect(mentionedLookFiles('node -e "fs.writeFileSync(`src/styles/site.css`, s)"')).toEqual(['src/styles/site.css'])
})

test("the guard's own record in the plugin store is recognised, and nothing else there is", () => {
  expect(isOwnRecord('/Users/dan/.claude/plugins/store/design-round-guard_inline-ab12.json')).toBe(true)
  expect(isOwnRecord('/Users/dan/.claude/plugins/store/simpler_inline-dc77.json')).toBe(false)
  expect(isOwnRecord('/Users/dan/Apps/x/design-round-guard.json')).toBe(false)
})

test('a branch naming an issue is keyed by the issue, one naming none by the branch, the default branch by this session only', () => {
  // Where the checkout stands, as mod-kit's $.modkit.branch reads it (its own tests pin that reading).
  const at = { main: '/Users/dan/Apps/slate', repo: 'slate', session: 's1', isDefault: false }
  expect(subjectsOf({ ...at, branch: '978-design-round-guard', issues: [978] })).toEqual([{ key: 'record:/Users/dan/Apps/slate|issue:978', label: 'issue #978 in slate' }])
  expect(subjectsOf({ ...at, branch: '41-52-both', issues: [41, 52] }).map(s => s.key)).toEqual(['record:/Users/dan/Apps/slate|issue:41', 'record:/Users/dan/Apps/slate|issue:52'])
  expect(subjectsOf({ ...at, branch: 'polish-header', issues: [] })).toEqual([{ key: 'record:/Users/dan/Apps/slate|branch:polish-header', label: 'branch polish-header in slate' }])
  // A no on the default branch would otherwise cover every later issue built there, even one it names.
  expect(subjectsOf({ ...at, branch: 'main', isDefault: true, issues: [] })).toEqual([{ key: 'record:/Users/dan/Apps/slate|branch:main|session:s1', label: 'main in slate, for this session' }])
  expect(subjectsOf({ ...at, branch: 'release-2026', isDefault: true, issues: [2026] })[0]?.key).toBe('record:/Users/dan/Apps/slate|branch:release-2026|session:s1')
  // An issue named on the settled question, whatever the branch.
  expect(subjectsOf({ main: at.main, repo: 'slate', session: 's1', issue: 12 })).toEqual([{ key: 'record:/Users/dan/Apps/slate|issue:12', label: 'issue #12 in slate' }])
})

test('the refusal names the file and both ways on, in plain words, tied to the refused call', () => {
  const subjects = [{ key: 'k', label: 'issue #978 in slate' }]
  const r = refusal('t7', ['app/page.tsx'], subjects)
  expect(r).toContain('app/page.tsx')
  expect(r).toContain('issue #978 in slate')
  expect(r).toContain('/design-rounds')
  expect(r).toContain(SKIP_QUESTION)
  expect(r).toContain('"source": "design-round-guard:t7"')
  expect(r).toContain(SETTLED_QUESTION)
  expect(DASHES.test(r)).toBe(false)
  const a = agentRefusal(['app/page.tsx'], subjects, 't8')
  expect(a).toContain('app/page.tsx')
  expect(a).toContain('Stop')
  expect(a).toContain('report')
  expect(a).toContain('design-round-guard:t8')
  expect(DASHES.test(a)).toBe(false)
})

test("Dan's two questions are the plan's words, with answers the guard sets itself", () => {
  const subjects = [{ key: 'k', label: 'issue #978 in slate' }]
  expect(skipQuestion(['app/page.tsx'], subjects).startsWith(SKIP_QUESTION)).toBe(true)
  expect(skipQuestion(['app/page.tsx'], subjects)).toContain('app/page.tsx')
  expect(skipOptions(subjects).map(o => o.label)).toEqual([SKIP_YES, SKIP_NO])
  expect(settledQuestion(subjects).startsWith(SETTLED_QUESTION)).toBe(true)
  expect(settledQuestion(subjects)).toContain('issue #978 in slate')
  expect(settledOptions(subjects).map(o => o.label)).toEqual([SETTLED_YES, SETTLED_NO])
  // Claude Code's dialog takes a header of at most 12 characters.
  expect(HEADER.length).toBeLessThanOrEqual(12)
})
