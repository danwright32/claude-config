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
  changedRuns,
  isModHook,
  modHookLogicOnly,
  onScreenProblem,
  sourceSpans,
  settledTyped,
  skipTyped,
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
  patternMayBeLook,
  inScratchpad,
  namesScratchpad,
  tempRoots,
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
  // Only a call's own name before its parenthesis is dropped, never a folder holding one (lessons review of #1010).
  expect(mentionedLookFiles('cat x > /w/slate/app/x(1)/page.tsx')).toEqual(['/w/slate/app/x(1)/page.tsx'])
  expect(mentionedLookFiles('echo /w/slate/(a)(b)/page.tsx')).toEqual(['/w/slate/(a)(b)/page.tsx'])
  expect(mentionedLookFiles('print(open(app/page.tsx).read())')).toEqual(['app/page.tsx'])
  // A name before a parenthesis may be a call or a folder (`x(1)`), which its spelling cannot tell
  // apart, so both readings are given and either holds; a call's absolute argument is only itself.
  expect(mentionedLookFiles('fs.writeFileSync(src/site.css)')).toEqual(['src/site.css', 'fs.writeFileSync(src/site.css'])
  expect(mentionedLookFiles('cat x > x(1)/page.tsx')).toContain('x(1)/page.tsx')
  expect(mentionedLookFiles('cat x > app(shop)/page.tsx')).toContain('app(shop)/page.tsx')
  expect(mentionedLookFiles('open(/tmp/x.tsx)')).toEqual(['/tmp/x.tsx'])
  // A name that starts with a route group keeps it.
  expect(mentionedLookFiles(`open('(shop)/page.tsx','w')`)).toEqual(['(shop)/page.tsx'])
  expect(mentionedLookFiles(`cd src/app && python3 -c "open('(shop)/[id]/page.tsx','w')"`)).toEqual(['(shop)/[id]/page.tsx'])
})

// #1010 held a name whose EXTENSION is a pattern; #1015: a pattern anywhere in the name is judged by
// every name it could expand to (`[t]ailwind.config.ts` slipped through, its extension literal and
// its literal name no look file). A name whose literal parts rule out every look changing file
// (`run-*.log`) is not one, and a pattern this cannot read is said to be one it cannot read.
test('a name holding a pattern may be a look changing file exactly where some name it can expand to is one', () => {
  for (const w of [
    'app/page.ts[x]',
    'out.*',
    'site.c?s',
    'x.{css,md}',
    'a.[js]sx',
    'View.swi*',
    '[t]ailwind.config.ts',
    'app/[t]okens.json',
    'design-[t]okens.json',
    'design.tokens.?son',
    '[T]AILWIND.CONFIG.TS',
    'tailwind.config.*',
    'brand.tok*.json',
    'build/*',
    '*',
    'x.{c{s,x}s,md}',
    'page.[!j]sx',
    // Any case counts: a capital C is read as the lower case one, and on the Mac's disk it is that file.
    'x.[!c]ss',
    // An escaped character is itself: this names the file `a*.css`.
    'a\\*.css',
    // A `*` runs past a dot: `notes.mine.css` is one of these. #1010 read only the extension and
    // counted `notes.m*` out; the shell does not stop at the dot, so it counts.
    'notes.m*',
    'timing-test-post.l*',
  ])
    expect([w, patternMayBeLook(w)]).toEqual([w, 'look'])
  for (const w of [
    'logs/x.l[o]g',
    'x.{md,txt}',
    'x.t?t',
    'run-*.log',
    'notes.m?',
    '[t]ailwind.config.json',
    'tokens-[0-9].json',
    'foo[0-9].json',
    'x.[!cC]ss',
    'page.[!jJtT]sx',
    'x.[[:alpha:]]d',
    'a\\*.log',
  ])
    expect([w, patternMayBeLook(w)]).toEqual([w, 'not'])
  // A pattern with a group in it (bash's extglob, zsh's alternation and qualifiers) is read by no
  // rule here, so it is said to be one that cannot be read.
  for (const w of ['x.@(css|md)', '*.css(N)', 'x.(css|md)', 'x.*(.)']) expect([w, patternMayBeLook(w)]).toEqual([w, 'unread'])
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

// #1191: a design round's working files go in the session's scratchpad, which Claude Code hands every
// session as <temp>/claude-<uid>/<project>/<session id>/scratchpad, its temp folder wherever that is.
test("the session's scratchpad is known by the session's id, under Claude Code's own temp folder", () => {
  // CLAUDE_CODE_TMPDIR when it is set, else /tmp; macOS spells /tmp and /var under /private too.
  expect(tempRoots(undefined)).toEqual(['/tmp', '/private/tmp'])
  expect(tempRoots('')).toEqual(['/tmp', '/private/tmp'])
  expect(tempRoots('/Users/dan/Temp Dir/')).toEqual(['/Users/dan/Temp Dir'])
  expect(tempRoots('/var/folders/x/T')).toEqual(['/var/folders/x/T', '/private/var/folders/x/T'])
  // A relative or climbing setting is not one Claude Code could have used as written: the default.
  expect(tempRoots('tmp')).toEqual(['/tmp', '/private/tmp'])
  expect(tempRoots('/tmp/../w/slate')).toEqual(['/tmp', '/private/tmp'])
  const tmp = tempRoots(undefined)
  const spaced = tempRoots('/Users/dan/Temp Dir')
  expect(inScratchpad('/private/tmp/claude-501/-Users-dan-slate/s1/scratchpad/3718/round1/screen.css', 's1', tmp)).toBe(true)
  expect(inScratchpad('/tmp/claude-501/-Users-dan-slate/s1/scratchpad', 's1', tmp)).toBe(true)
  expect(inScratchpad('/Users/dan/Temp Dir/claude-501/-Users-dan-slate/s1/scratchpad/a b/screen.css', 's1', spaced)).toBe(true)
  // Lessons review: a folder shaped like it anywhere else, a checkout included, is not it.
  expect(inScratchpad('/w/slate/app/claude-1/x/s1/scratchpad/page.tsx', 's1', tmp)).toBe(false)
  expect(inScratchpad('/w/slate/tmp/claude-501/x/s1/scratchpad/page.tsx', 's1', tmp)).toBe(false)
  expect(inScratchpad('/Users/dan/Temp Dir/claude-501/x/s1/scratchpad/screen.css', 's1', tmp)).toBe(false)
  // Another session's, a folder merely called scratchpad, a name that only starts like it, a climb out, and no id.
  expect(inScratchpad('/private/tmp/claude-501/-Users-dan-slate/s2/scratchpad/screen.css', 's1', tmp)).toBe(false)
  expect(inScratchpad('/w/slate/scratchpad/screen.css', 's1', tmp)).toBe(false)
  expect(inScratchpad('/private/tmp/claude-501/x/s1/scratchpads/screen.css', 's1', tmp)).toBe(false)
  expect(inScratchpad('/private/tmp/claude-501/x/s1/scratchpad/../../../../../w/slate/a.css', 's1', tmp)).toBe(false)
  expect(inScratchpad('/private/tmp/claude-501/x/s1/scratchpad/screen.css', '', tmp)).toBe(false)
  // An id is matched as written, never as a pattern.
  expect(inScratchpad('/private/tmp/claude-501/x/s1x/scratchpad/screen.css', 's1.', tmp)).toBe(false)
  // A command naming it, quoted or not, or with a space in the temp folder's name.
  expect(namesScratchpad("d = '/private/tmp/claude-501/-Users-dan-slate/s1/scratchpad/3718/round1'", 's1', tmp)).toBe(true)
  expect(namesScratchpad('cd /tmp/claude-501/x/s1/scratchpad && ls', 's1', tmp)).toBe(true)
  expect(namesScratchpad('R="/Users/dan/Temp Dir/claude-501/x/s1/scratchpad"; ls "$R"', 's1', spaced)).toBe(true)
  expect(namesScratchpad("d = '/private/tmp/claude-501/x/s2/scratchpad'", 's1', tmp)).toBe(false)
  expect(namesScratchpad("d = '/private/tmp/claude-501/x/s1/scratchpads'", 's1', tmp)).toBe(false)
  expect(namesScratchpad("d = '/w/slate/tmp/claude-501/x/s1/scratchpad'", 's1', tmp)).toBe(false)
  expect(namesScratchpad('cd scratchpad && ls', 's1', tmp)).toBe(false)
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
  // #1138: what changes on screen leads, in the session's words; the plan's question, then the file.
  const q = skipQuestion('The Save button on the invoice screen turns blue', ['app/page.tsx'], subjects)
  expect(q).toBe(`The Save button on the invoice screen turns blue. ${SKIP_QUESTION} This is for issue #978 in slate; the file is app/page.tsx.`)
  expect(DASHES.test(q)).toBe(false)
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

// #1138: the sentence the skip question leads with is refused when it is missing, too long for one
// sentence, or names a file, the very thing Dan could not read.
test("the skip question's plain sentence is required, one sentence long, and names no file", () => {
  const files = ['payload/mods/mod-kit/hooks/register.tsx']
  expect(onScreenProblem('Nothing on screen changes: mod-kit gains one reader of whether a message is yours.', files)).toBeUndefined()
  expect(onScreenProblem('The steps card in the band gets an amber edge.', files)).toBeUndefined()
  for (const missing of [undefined, null, '', '  ', 3]) expect(onScreenProblem(missing, files)).toContain('"onScreen"')
  expect(onScreenProblem('Changes register.tsx', files)).toContain('names a file (register.tsx)')
  expect(onScreenProblem('Restyles app/globals.css', files)).toContain('globals.css')
  expect(onScreenProblem('y'.repeat(301), files)).toContain('at most 300')
  // A file named with no name of its own (a folder's path) never makes every sentence name it.
  expect(onScreenProblem('The steps card in the band gets an amber edge.', ['app/', ''])).toBeUndefined()
  for (const t of [onScreenProblem('', files), onScreenProblem('Changes register.tsx', files)]) expect(DASHES.test(String(t))).toBe(false)
})

// #1145: the wording is mod-kit's ($.modkit.typedAnswer); the guard gives its two parts.
test("a typed answer's two parts, what stays as it was and how to ask again", () => {
  const subjects = [{ key: 'k', label: 'issue #978 in slate' }]
  const t = skipTyped(['app/page.tsx'], subjects)
  expect(t.still).toContain('app/page.tsx')
  expect(t.still).toContain('issue #978 in slate')
  expect(t.again).toBe('ask him the same question again, with the same metadata')
  expect(settledTyped().again).toBe(`ask him "${SETTLED_QUESTION}" again, with the same metadata`)
  for (const x of [t.still, t.again, settledTyped().still, settledTyped().again]) expect(DASHES.test(x)).toBe(false)
})

// #1138: a mod's own hook files, judged by what they draw.
test("a mod's hook file is one under mods/<mod>/hooks, in TSX or JSX; nothing else is", () => {
  expect(isModHook('payload/mods/mod-kit/hooks/register.tsx')).toBe(true)
  expect(isModHook('mods/x/hooks/panel.jsx')).toBe(true)
  expect(isModHook('payload/mods/mod-kit/hooks/rules.ts')).toBe(false)
  expect(isModHook('src/app/mods/page.tsx')).toBe(false)
  expect(isModHook('src/mods/x/components/hooks.tsx')).toBe(false)
})

const TSX = [
  "import type { Register } from 'claude-code'",
  '// a < b, and <Text> in a comment is no element',
  "const re = /<Box>'/g",
  'const n = (a: number, b: number): Promise<Array<number>> => Promise.resolve([a < b ? a : b / 2])',
  'const label = `${n} <x>`',
  "export const draw = (ok: boolean) => ok ? <Text color=\"green\">don't {label}</Text> : (",
  '  <Box flexDirection="column">',
  '    {/* note */}',
  '    <Text {...{ a: 1 }} dimColor>{[1].map(x => <Text key={String(x)}>x</Text>)}</Text>',
  '  </Box>',
  ')',
  '',
].join('\n')

test('the JSX reader finds elements only where an expression starts, past strings, regexes, comments and generics', () => {
  const spans = sourceSpans(TSX)
  if (!spans) throw new Error('the fixture could not be read')
  // The two elements the code holds, and the one inside the second's map, which lies within it.
  const outer = spans.jsx.filter(([a, b]) => !spans.jsx.some(([c, d]) => (c < a && b <= d) || (c <= a && b < d)))
  const shown = outer.map(([a, b]) => TSX.slice(a, b))
  expect(shown.length).toBe(2)
  expect(shown[0]).toBe('<Text color="green">don\'t {label}</Text>')
  expect(shown[1]?.startsWith('<Box flexDirection="column">')).toBe(true)
  expect(shown[1]?.endsWith('</Box>')).toBe(true)
  expect(spans.jsx.map(([a, b]) => TSX.slice(a, b))).toContain('<Text key={String(x)}>x</Text>')
  expect(spans.comments.map(([a, b]) => TSX.slice(a, b))).toEqual(['// a < b, and <Text> in a comment is no element', '/* note */'])
  // What it cannot follow is null, never a partial reading.
  for (const bad of ['const x = <Box>', "const s = 'open", 'const x = (<Box></Text>)', '/* open', 'const f = <T,(x: T) => x']) expect(sourceSpans(bad)).toBeNull()
  // A generic arrow's type parameters are no element, mod-kit's drawCard among them.
  for (const generic of ['const f = <T,>(x: T) => x', 'const drawCard = <E extends ResolveInput>($: E) => <Box />', 'const g = <T = Map<string, number>>(x: T) => x']) {
    const s = sourceSpans(generic)
    expect(s?.jsx.map(([a, b]) => generic.slice(a, b))).toEqual(generic.includes('<Box />') ? ['<Box />'] : [])
  }
})

test('a mod hook edit is logic only when it touches no JSX line and names no drawing word, comments aside', () => {
  const swapIn = (from: string, to: string) => {
    if (!TSX.includes(from)) throw new Error(`the fixture holds no ${from}`)
    return TSX.replace(from, to)
  }
  expect(modHookLogicOnly(TSX, swapIn('b / 2', 'b / 3'))).toBe(true)
  expect(modHookLogicOnly(TSX, swapIn('// a < b, and', '// a < b in any colour, and'))).toBe(true)
  expect(modHookLogicOnly(TSX, swapIn("import type { Register } from 'claude-code'", "import type { Register, On } from 'claude-code'"))).toBe(true)
  // Lines holding JSX, or naming how it is drawn.
  expect(modHookLogicOnly(TSX, swapIn('color="green"', 'color="red"'))).toBe(false)
  expect(modHookLogicOnly(TSX, swapIn('{/* note */}', '{/* a note */}'))).toBe(false)
  expect(modHookLogicOnly(TSX, swapIn('const label = `${n} <x>`', 'const label = `${n} <x>`\nconst EDGE = AMBER'))).toBe(false)
  expect(modHookLogicOnly(TSX, swapIn('b / 2', 'b / 2, dimColor'))).toBe(false)
  // A colour or terminal style spelled with no word (lessons review): hex, ANSI escapes, rgb().
  for (const literal of ["'#ff0000'", "'\\x1b[31m'", "'\\u001b[1m'", "'\\u{1b}[2m'", "'\\033[0m'", "'rgb(255, 0, 0)'"])
    expect(modHookLogicOnly(TSX, swapIn('const label = `${n} <x>`', `const label = \`\${n} <x>\`\nconst EDGE = ${literal}`))).toBe(false)
  // No change, or text the reader cannot follow, is never logic only.
  expect(modHookLogicOnly(TSX, TSX)).toBe(false)
  expect(modHookLogicOnly(TSX, swapIn("const re = /<Box>'/g", "const re = /<Box>'/g\nconst open = <Box>"))).toBe(false)
})

// #1158: a git checkout or restore puts back every edit since its source at once, each of which was
// an edit of its own, so it is judged one run of changed lines at a time.
test('changedRuns: each run of changed lines as its own step, the last step ending at the new text', () => {
  const a = 'one\ntwo\nthree\nfour\nfive\n'
  expect(changedRuns(a, a)).toEqual([])
  // One run: the whole change, exactly.
  expect(changedRuns(a, a.replace('three', 'THREE'))).toEqual([[a, a.replace('three', 'THREE')]])
  // Two runs apart, each made alone, from the last back, so the texts chain from a to the new text.
  const b = a.replace('two', 'TWO').replace('five', 'FIVE')
  expect(changedRuns(a, b)).toEqual([
    [a, a.replace('five', 'FIVE')],
    [a.replace('five', 'FIVE'), b],
  ])
  // Lines added and taken away are runs too.
  expect(changedRuns(a, a.replace('two\n', '')).map(([, after]) => after)).toEqual([a.replace('two\n', '')])
  const grown = a.replace('one\n', 'one\nnew\n').replace('four\n', '')
  const steps = changedRuns(a, grown)
  expect(steps.length).toBe(2)
  expect(steps[steps.length - 1]?.[1]).toBe(grown)
  // A last line with no newline is a line like any other.
  expect(changedRuns('x\ny', 'x\nz')).toEqual([['x\ny', 'x\nz']])
  // Past the most it compares, the change is one run, judged whole.
  const big = Array.from({ length: 2500 }, (_, i) => `line ${i}\n`)
  const from = big.join('')
  const to = big.map((l, i) => (i % 2 ? l.toUpperCase() : l)).join('')
  expect(changedRuns(from, to)).toEqual([[from, to]])
  // So is one of more runs than it judges one by one, each costing a read of the whole text
  // (lessons review): a hold costs Dan one answer.
  const lines = Array.from({ length: 200 }, (_, i) => `row ${i}\n`)
  const many = lines.map((l, i) => (i % 4 ? l : l.toUpperCase())).join('')
  expect(changedRuns(lines.join(''), many)).toEqual([[lines.join(''), many]])
  const few = lines.map((l, i) => (i % 20 ? l : l.toUpperCase())).join('')
  expect(changedRuns(lines.join(''), few).length).toBe(10)
})
