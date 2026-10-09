import { expect, test } from 'claude-code/testing'
import {
  HEADER,
  NOT_LOOK,
  SETTLED_NO,
  SETTLED_QUESTION,
  SETTLED_YES,
  SKIP_NO,
  SKIP_QUESTION,
  SKIP_YES,
  agentRefusal,
  callKey,
  dataOnlyChange,
  editedText,
  isOwnRecord,
  READS_ONLY,
  isSwiftUI,
  lookKindIn,
  mentionedLookFiles,
  pathsOf,
  refusal,
  settledOptions,
  settledQuestion,
  skipOptions,
  skipQuestion,
  subjectsOf,
  textsOf,
} from '../hooks/rules.ts'

// The design round guard's rules (claude-config#978), each on its own: which files change how a
// screen looks, what an issue or branch is keyed by, and what Claude and Dan read.

// The two dashes the writing style forbids, built from their code points so this file holds neither.
const DASHES = new RegExp(`[${String.fromCharCode(0x2014)}${String.fromCharCode(0x2013)}]`)

test('style, screen and component files, the Tailwind config and design tokens change the look; logic and docs do not', () => {
  for (const p of ['/r/app/globals.css', '/r/a.scss', '/r/a.sass', '/r/a.less', '/r/a.styl', '/r/a.pcss']) expect(lookKindIn(p, '/r')).toBe('style')
  for (const p of ['/r/app/page.tsx', '/r/Button.jsx', '/r/App.vue', '/r/Card.svelte', '/r/index.html', '/r/old.htm', '/r/payload/mods/x/hooks/register.tsx']) expect(lookKindIn(p, '/r')).toBe('screen')
  for (const p of ['/r/tailwind.config.js', '/r/tailwind.config.ts', '/r/tailwind.config.mjs', '/r/tailwind.config.cjs']) expect(lookKindIn(p, '/r')).toBe('tailwind')
  for (const p of ['/r/design-tokens.json', '/r/src/tokens.css', '/r/tokens.json', '/r/theme/colors.tokens.json', '/r/design_tokens.ts']) expect(lookKindIn(p, '/r')).toBe('tokens')
  expect(lookKindIn('/r/Views/Main.swift', '/r')).toBe('swift')
  // What passes untouched: logic, tests in plain TypeScript, docs, config, shell.
  for (const p of ['/r/app/route.ts', '/r/lib/date.js', '/r/README.md', '/r/package.json', '/r/hooks/rules.test.ts', '/r/run.sh', '/r/auth/token.ts', '/r/styles.py', '/r/htmlparse.ts'])
    expect(lookKindIn(p, '/r')).toBe(null)
})

// Dan, 2026-10-08, on seeing the guard: "On, but let tests through". A test of a screen does not
// change how it looks, so a test file is never held, by the usual markers of one.
test('a test file is not look changing, by its .test. or .spec. part, a test folder, or a Swift test target', () => {
  for (const p of [
    '/r/app/page.test.tsx',
    '/r/components/Button.spec.jsx',
    '/r/src/Card.test.svelte',
    '/r/src/__tests__/Header.tsx',
    '/r/tests/fixtures/index.html',
    '/r/test/styles/site.css',
    '/r/payload/mods/x/tests/register.test.tsx',
    '/r/OvationTests/MainViewTests.swift',
    '/r/Sources/App/RowTests.swift',
    '/r/Tests/Helpers.swift',
  ])
    expect(lookKindIn(p, '/r')).toBe(null)
  // A name merely holding "test" elsewhere is no test file, and neither is a folder whose name only contains it.
  for (const [p, kind] of [
    ['/r/app/latest.tsx', 'screen'],
    ['/r/styles/contest.css', 'style'],
    ['/r/attestation/Form.jsx', 'screen'],
    ['/r/testimonials/Quote.tsx', 'screen'],
    ['/r/Views/TestimonialView.swift', 'swift'],
  ] as const)
    expect(lookKindIn(p, '/r')).toBe(kind)
  // A folder ending Tests marks a Swift test target only: a web file there is still a screen.
  expect(lookKindIn('/r/AppTests/page.tsx', '/r')).toBe('screen')
})

test("a tool's file paths are read from every key ending path or paths, and its carried text from its edits", () => {
  expect(pathsOf({ file_path: '/a.tsx', edits: [] })).toEqual(['/a.tsx'])
  expect(pathsOf({ notebook_path: '/n.ipynb', new_source: 'x' })).toEqual(['/n.ipynb'])
  expect(pathsOf({ file_paths: ['/a.css', '/b.md'], path: '/a.css', count: 2 })).toEqual(['/a.css', '/b.md'])
  expect(pathsOf({ command: 'echo', url: 'https://x' })).toEqual([])
  expect(textsOf({ new_string: 'a', edits: [{ new_string: 'b' }, { old_string: 'c' }] })).toEqual(['a', 'b'])
  expect(READS_ONLY.has('Read') && READS_ONLY.has('Artifact') && !READS_ONLY.has('MultiEdit') && !READS_ONLY.has('NotebookEdit')).toBe(true)
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
  // #1010: a Next.js dynamic segment or route group is part of the name, never where it starts, so
  // the file is not read as one at the top of the disk.
  expect(mentionedLookFiles(`python3 -c "open('src/app/booking/[SO_ID]/page.tsx','w')"`)).toEqual(['src/app/booking/[SO_ID]/page.tsx'])
  expect(mentionedLookFiles(`open('src/app/(marketing)/[...slug]/page.tsx','w')`)).toEqual(['src/app/(marketing)/[...slug]/page.tsx'])
})

test("the guard's own record in the plugin store is recognised, and nothing else there is", () => {
  expect(isOwnRecord('/Users/dan/.claude/plugins/store/design-round-guard_inline-ab12.json')).toBe(true)
  expect(isOwnRecord('/Users/dan/.claude/plugins/store/simpler_inline-dc77.json')).toBe(false)
  expect(isOwnRecord('/Users/dan/Apps/x/design-round-guard.json')).toBe(false)
  expect(isOwnRecord('$D/design-round-guard_inline-x.json')).toBe(true)
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
  expect(skipOptions(subjects).map(o => o.label)).toEqual([SKIP_YES, SKIP_NO, NOT_LOOK])
  expect(settledQuestion(subjects).startsWith(SETTLED_QUESTION)).toBe(true)
  expect(settledQuestion(subjects)).toContain('issue #978 in slate')
  expect(settledOptions(subjects).map(o => o.label)).toEqual([SETTLED_YES, SETTLED_NO])
  // Claude Code's dialog takes a header of at most 12 characters.
  expect(HEADER.length).toBeLessThanOrEqual(12)
})

// #1010: a data only prop change on a page (`xbc={xbc}` to `xbc={leadXbc ?? ''}`, which booking code
// the page hands its calendar) was held for a design round, though nothing on screen changes. The
// guard judges the edit itself where that is reliable, and every other shape stays on the picker.
const PAGE = [
  "import { BookingCalendar } from '@/components/BookingCalendar'",
  '',
  'export default function Result({ xbc, leadXbc, slots }: Props) {',
  '  return (',
  '    <main className="p-4">',
  '      <h1 className="text-xl">Pick a time</h1>',
  '      <BookingCalendar slots={slots} xbc={xbc} variant={plain} onPick={() => go(xbc)} />',
  '    </main>',
  '  )',
  '}',
  '',
].join('\n')
const swap = (from: string, to: string) => {
  if (!PAGE.includes(from)) throw new Error(`the fixture holds no ${from}`)
  return PAGE.replace(from, to)
}

test("a change confined to a component's data prop is no look change: Dan's xbc edit, and others like it", () => {
  expect(dataOnlyChange(PAGE, swap('xbc={xbc}', "xbc={leadXbc ?? ''}"))).toBe(true)
  expect(dataOnlyChange(PAGE, swap('xbc={xbc}', 'xbc={lead?.xbc || xbc}'))).toBe(true)
  expect(dataOnlyChange(PAGE, swap('slots={slots}', 'slots={pick(slots, lead)}'))).toBe(true)
  // And back again, so neither direction is judged differently.
  expect(dataOnlyChange(swap('xbc={xbc}', "xbc={leadXbc ?? ''}"), PAGE)).toBe(true)
})

test('a changed className, style, look naming prop, literal, JSX structure or visible copy is a look change, judged from the same page', () => {
  for (const [from, to] of [
    ['className="p-4"', 'className="p-6"'],
    ['<main className="p-4">', '<main className="p-4" style={{ gap: 4 }}>'],
    ['variant={plain}', 'variant={bold}'],
    ['Pick a time', 'Choose a time'],
    ['<h1 className="text-xl">Pick a time</h1>', '<h1 className="text-xl">Pick a time</h1>\n      <p>Times are local</p>'],
    // A literal in a data prop may be shown, so it is not judged here.
    ['xbc={xbc}', "xbc={'ABC'}"],
    ['xbc={xbc}', 'xbc={2}'],
    ['xbc={xbc}', 'xbc={`${xbc}-x`}'],
    ['xbc={xbc}', 'xbc={xbc === lead}'],
    ['xbc={xbc}', 'xbc={<Badge />}'],
    // A new prop, or one taken away, changes the element.
    ['xbc={xbc}', 'xbc={xbc} compact'],
    ['xbc={xbc} ', ''],
    // An event handler holding an arrow is not a plain expression.
    ['onPick={() => go(xbc)}', 'onPick={() => go(leadXbc)}'],
    // Two changes in one edit, one of them a look change.
    ['slots={slots} xbc={xbc} variant={plain}', 'slots={lead} xbc={xbc} variant={bold}'],
    // A change outside any prop: an import can swap the component itself.
    ["from '@/components/BookingCalendar'", "from '@/components/BookingCalendarV2'"],
  ] as const)
    expect([from, to, dataOnlyChange(PAGE, swap(from, to))]).toEqual([from, to, false])
  // A look naming word anywhere in a camelCase prop name, whatever its case (lessons review of #1010).
  for (const name of ['containerClassName', 'wrapperStyle', 'buttonVariant', 'modalTitle', 'iconColor', 'maxWidth', 'defaultOpen', 'isCompact'])
    expect([name, dataOnlyChange(PAGE, swap('xbc={xbc}', `${name}={a}`)),dataOnlyChange(swap('xbc={xbc}', `${name}={a}`), swap('xbc={xbc}', `${name}={b}`))]).toEqual([name, false, false])
  // A prop on a plain HTML element can be read by CSS, so only a component's props are judged.
  const html = '<a className="link" href={url}>Go</a>\n'
  expect(dataOnlyChange(html, html.replace('href={url}', 'href={next}'))).toBe(false)
  // No change at all changes nothing, and is no evidence either way: the guard asks.
  expect(dataOnlyChange(PAGE, PAGE)).toBe(false)
})

test('the text a call leaves in a file: an Edit, a MultiEdit, a Write, and nothing for an edit that would not apply', () => {
  const before = 'a={x} b={y} a={x}'
  expect(editedText(before, 'Write', { content: 'new' })).toBe('new')
  expect(editedText(before, 'Edit', { old_string: 'b={y}', new_string: 'b={z}' })).toBe('a={x} b={z} a={x}')
  // Edit needs one match unless it replaces every one.
  expect(editedText(before, 'Edit', { old_string: 'a={x}', new_string: 'a={w}' })).toBe(undefined)
  expect(editedText(before, 'Edit', { old_string: 'a={x}', new_string: 'a={w}', replace_all: true })).toBe('a={w} b={y} a={w}')
  expect(editedText(before, 'Edit', { old_string: 'nowhere', new_string: 'x' })).toBe(undefined)
  expect(editedText(before, 'MultiEdit', { edits: [{ old_string: 'b={y}', new_string: 'b={z}' }, { old_string: 'b={z}', new_string: 'b={q}' }] })).toBe('a={x} b={q} a={x}')
  // A tool whose writes are not one file's text is never judged by it.
  expect(editedText(before, 'NotebookEdit', { new_source: 'x' })).toBe(undefined)
  expect(editedText(before, 'FutureWrite', { text: 'x' })).toBe(undefined)
})

test("a refused call's key is the same for the same call however its keys are ordered, and differs for any other, elsewhere or later", () => {
  const at = { cwd: '/r', session: 's1' }
  const a = callKey('Edit', { file_path: '/r/page.tsx', old_string: 'a', new_string: 'b' }, at)
  expect(callKey('Edit', { new_string: 'b', old_string: 'a', file_path: '/r/page.tsx' }, at)).toBe(a)
  expect(callKey('Edit', { file_path: '/r/page.tsx', old_string: 'a', new_string: 'c' }, at)).not.toBe(a)
  expect(callKey('Write', { file_path: '/r/page.tsx', old_string: 'a', new_string: 'b' }, at)).not.toBe(a)
  expect(callKey('Bash', { command: 'echo x > a.css' }, at)).not.toBe(callKey('Bash', { command: 'echo y > a.css' }, at))
  // The same words in another folder, or another session, are another call (lessons review of #1010).
  expect(callKey('Bash', { command: 'echo x > a.css' }, at)).not.toBe(callKey('Bash', { command: 'echo x > a.css' }, { ...at, cwd: '/q' }))
  expect(callKey('Bash', { command: 'echo x > a.css' }, at)).not.toBe(callKey('Bash', { command: 'echo x > a.css' }, { ...at, session: 's2' }))
})

test("the third answer to the skip question says it covers this one edit, in plain words", () => {
  const subjects = [{ key: 'k', label: 'issue #978 in slate' }]
  const third = skipOptions(subjects).find(o => o.label === NOT_LOOK)
  expect(third?.description).toContain('this edit')
  expect(DASHES.test(JSON.stringify(skipOptions(subjects)))).toBe(false)
})
