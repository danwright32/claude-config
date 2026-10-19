import { expect, test } from 'claude-code/testing'
import {
  ISSUE_READING,
  answerCounts,
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
  isModHookTs,
  drawsChange,
  modHookLogicOnly,
  onScreenProblem,
  sourceSpans,
  settledNotYet,
  settledTypedSaid,
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
  joinedOnly,
  addedOntoFolder,
  shellBraces,
  afterVariable,
  shellVarPath,
  tempRoots,
  ROUND_FILES,
  checked,
  unsure,
  unreadable,
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

// #1191, lessons review: a name read as a round's file must be one the text joins onto a folder.
test('a name is joined only where every place the text spells it joins it onto a folder', () => {
  expect(joinedOnly("open(os.path.join(d, 'screen.css'), 'w')", 'screen.css')).toBe(true)
  expect(joinedOnly('fs.writeFileSync(path.join(d, "screen.css"), x)', 'screen.css')).toBe(true)
  expect(joinedOnly("(d / 'screen.css').write_text(x)", 'screen.css')).toBe(true)
  // The shell's `$R/screen.css` is not joined: its folder is R's value (shellVarPath).
  expect(joinedOnly('open("$R/screen.css", "w")', 'R/screen.css')).toBe(false)
  expect(joinedOnly("p = os.path.join(d, 'a.css')\nq = d / 'a.css'", 'a.css')).toBe(true)
  // Opened as written, in a list, after a call inside the join, or spelled nowhere: not joined.
  expect(joinedOnly("open('index.html', 'w')", 'index.html')).toBe(false)
  expect(joinedOnly("open(os.path.join(d, 'a.css'))\nopen('a.css', 'w')", 'a.css')).toBe(false)
  expect(joinedOnly("for f in ['a.css']: open(f, 'w')", 'a.css')).toBe(false)
  expect(joinedOnly("os.path.join(os.getcwd(), 'a.css')", 'a.css')).toBe(false)
  expect(joinedOnly("x = 'b.css' // 'a.css'", 'a.css')).toBe(false)
  expect(joinedOnly('open("x")', 'a.css')).toBe(false)
  expect(joinedOnly('', '')).toBe(false)
  // A longer name holding it is another name.
  expect(joinedOnly("os.path.join(d, 'screen.css')\nopen('app/screen.css')", 'screen.css')).toBe(true)
  // #1194: added onto a folder in a variable, by a string or an f-string's brace.
  expect(joinedOnly('open(d + "/screen.css", "w")', 'screen.css')).toBe(true)
  expect(joinedOnly('open(f"{d}/screen.css", "w")\nopen(d+\'/screen.css\')', 'screen.css')).toBe(true)
  expect(joinedOnly('open(f"{d}/screen.css", "w")\nopen("screen.css", "w")', 'screen.css')).toBe(false)
})

// #1194: mentionedLookFiles reads `root + "/app/page.tsx"` and `f"{root}/app/page.tsx"` as a name at the
// disk's root, in no checkout, so a program writing a page that way was never held by that name.
test('a name that looks absolute is added onto a folder only where every place the text spells it is', () => {
  expect(addedOntoFolder('p=W+"/docs/design/clients.html"; open(p)', '/docs/design/clients.html')).toBe(true)
  expect(addedOntoFolder("open(W + '/app/page.tsx', 'w')", '/app/page.tsx')).toBe(true)
  expect(addedOntoFolder('open(f"{W}/app/page.tsx", "w")', '/app/page.tsx')).toBe(true)
  // The shell's braces hold a folder too, but its value is read by shellBraces, not as a join.
  expect(addedOntoFolder('cat > "${R}/screen.css"', '/screen.css')).toBe(false)
  // Spelled from the root anywhere, or not looking absolute at all: not added.
  expect(addedOntoFolder('open(f"{W}/app/page.tsx")\nopen("/app/page.tsx", "w")', '/app/page.tsx')).toBe(false)
  expect(addedOntoFolder("open('/w/slate/app/page.tsx', 'w')", '/w/slate/app/page.tsx')).toBe(false)
  expect(addedOntoFolder('open(W + "/app/page.tsx")', 'app/page.tsx')).toBe(false)
  expect(addedOntoFolder('x', '/app/page.tsx')).toBe(false)
})

// Lessons review of #1194: the shell's `${APP}/booker.css` is `$APP/booker.css`, for shellVarPath.
test("a name after the shell's braced variable names that variable, and is never added onto a folder", () => {
  expect(shellBraces('open("${APP}/booker.css", "w")', '/booker.css')).toEqual(['APP'])
  expect(shellBraces('cat "${APP}/booker.css" > "${APP}/booker.css"', '/booker.css')).toEqual(['APP'])
  expect(shellBraces('cp "${A}/booker.css" "${B}/booker.css"', '/booker.css')).toEqual(['A', 'B'])
  expect(shellBraces('open("${A_LONG_ROUND_FOLDER_NAME}/booker.css")', '/booker.css')).toEqual(['A_LONG_ROUND_FOLDER_NAME'])
  expect(shellBraces('open(f"{d}/booker.css")', '/booker.css')).toBeUndefined()
  expect(shellBraces('open("${APP}/booker.css")\nopen("/booker.css")', '/booker.css')).toBeUndefined()
  expect(shellBraces('open("${APP}/booker.css")', 'booker.css')).toBeUndefined()
  // The shell's braces are no f-string's: neither reading takes them for a folder a name is added onto.
  expect(addedOntoFolder('cp "${A}/x.css" "${B}/x.css"', '/x.css')).toBe(false)
  expect(addedOntoFolder('open("${A_LONG_ROUND_FOLDER_NAME}/x.css")', '/x.css')).toBe(false)
  expect(joinedOnly('cp "${A}/x.css" "${B}/x.css"', 'x.css')).toBe(false)
  // Spelled after a shell variable and after a python one: after a variable, so not at the root,
  // but not joined either.
  const mixed = 'open("${APP}/x.css")\nopen(f"{d}/x.css", "w")'
  expect(afterVariable(mixed, '/x.css')).toBe(true)
  expect(joinedOnly(mixed, 'x.css')).toBe(false)
  expect(afterVariable('open("${APP}/x.css")\nopen("/x.css")', '/x.css')).toBe(false)
  expect(afterVariable('open("${APP}/x.css")', 'x.css')).toBe(false)
})

// #1191: every refusal of a look changing edit says where a round's own files go, so a round the
// guard held is never sent back to /design-rounds, which held it.
test("every refusal of a look changing edit says a design round's files go in the session's scratchpad", () => {
  const subjects = [{ key: 'k', label: 'issue #3718 in slate' }]
  const files = ['src/app/globals.css']
  expect(ROUND_FILES).toContain("this session's scratchpad")
  for (const said of [refusal('t1', files, subjects), agentRefusal(files, subjects, 't2'), checked(files, subjects), unsure(files, 'a detached head names no branch'), unreadable(files, subjects, 'EIO')]) {
    expect(said).toContain(ROUND_FILES)
    expect(DASHES.test(said)).toBe(false)
  }
})

// #1191, lessons review: `$APP/globals.css` was read as joined, and its disk check looked for a
// project folder named APP. A name through a variable lands where the command's assignment puts it.
test("a name the shell spells through a variable lands where the command's own assignment of it puts it", () => {
  const text = 'open("$R/screen.css", "w")'
  expect(shellVarPath("R='/tmp/claude-501/x/s1/scratchpad/3718/round1'; python3 - <<PY", text, 'R/screen.css')).toBe('/tmp/claude-501/x/s1/scratchpad/3718/round1/screen.css')
  expect(shellVarPath('R="/Users/dan/Temp Dir/r1/"; x', text, 'R/screen.css')).toBe('/Users/dan/Temp Dir/r1/screen.css')
  expect(shellVarPath('export R=/w/slate/src/app && x', text, 'R/screen.css')).toBe('/w/slate/src/app/screen.css')
  expect(shellVarPath('R=src/app; x', text, 'R/screen.css')).toBe('src/app/screen.css')
  expect(shellVarPath('R=/a; R=/a; x', text, 'R/screen.css')).toBe('/a/screen.css')
  // Set nowhere, set twice to different values, built from another value, or the name also spelled
  // without its $: not read.
  expect(shellVarPath('python3 - <<PY', text, 'R/screen.css')).toBe(undefined)
  expect(shellVarPath('R=/a; R=/b; x', text, 'R/screen.css')).toBe(undefined)
  expect(shellVarPath('R="$HOME/x"; x', text, 'R/screen.css')).toBe(undefined)
  expect(shellVarPath('R=$(pwd); x', text, 'R/screen.css')).toBe(undefined)
  expect(shellVarPath('XR=/a; x', text, 'R/screen.css')).toBe(undefined)
  expect(shellVarPath('R=/a', `${text}\nopen('R/screen.css')`, 'R/screen.css')).toBe(undefined)
  expect(shellVarPath('R=/a', text, 'screen.css')).toBe(undefined)
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
  for (const x of [t.still, t.again]) expect(DASHES.test(x)).toBe(false)
})

// #1336: a typed answer to the settled question counts as Not yet, and is the next round's feedback.
test('a typed answer to the settled question is said as Not yet, with his words as the next round\'s feedback', () => {
  const said = settledTypedSaid('too much dead space in the boxes')
  expect(said).toContain('"too much dead space in the boxes"')
  expect(said).toContain(`counts as ${SETTLED_NO}`)
  expect(said).toContain(settledNotYet)
  expect(said).toContain('feedback for the next design round')
  expect(said).not.toContain(`"${SETTLED_QUESTION}" again`)
  expect(DASHES.test(said)).toBe(false)
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

// #1248: on 2026-10-16 a subagent's Edit for #1245 to manual steps' hook file was refused as a look
// change (call toolu_013hHV3QP5RaaVGuwwQJvTXj). It only added a type and a helper that sends Dan a
// notification when a card is pinned, which nothing in the file called yet; the helper reads the
// steps card's heading, and `card` is a word a mod draws with; the untouched line below it, naming the
// card too, was read with it. The file as it stood, cut to its
// imports and the lines around the insertion (payload/mods/manual-steps/hooks/register.tsx at
// 5681b31a^), with one drawing line added at its end, and the refused call's new_string, word for word.
const STEPS_BEFORE = [
  "import type { EngineInterface, Hook, Register } from 'claude-code'",
  "import type { ManualSteps, StepsCard, StepsPaneId } from '../types/index.d.ts'",
  "import { cardFrom, cardLines, carriedNote, donePrompt, DROPPED_AFTER_MS, finish, fold, keepAdded, keepFinished, nextStep, paneColumns, sent, VERDICTS } from './card.ts'",
  "import type { DrawnAt, StepsVerdict } from './card.ts'",
  "import { waitingPhrase } from './waiting.ts'",
  '',
  "/** The scope modes mod's noun (#621) as its contract has it; it may not be loaded at all. */",
  'type ScopeModes = { hold: (input: { label: string; prompt: string }) => Promise<{ isHeld: boolean }> }',
  '',
  'const holdWhileAway = async ($: EngineInterface, card: StepsCard): Promise<boolean> => {',
  '  try {',
  '    const r = await ($ as unknown as { scopeModes: ScopeModes }).scopeModes.hold({',
  '      label: card.heading,',
  '      prompt: `Pin the manual steps for "${card.heading}" again with the manual-steps steps tool: check each against the current state first.`,',
  '    })',
  '    return r?.isHeld === true',
  '  } catch (err) {',
  '    const isAbsent = err instanceof TypeError && /undefined|not a function|null/.test(message(err))',
  "    if (!isAbsent) $.ui.log(`Manual steps could not ask whether Dan is away, so the card is shown: ${message(err)}`)",
  '    return false',
  '  }',
  '}',
  '',
  'const left = (card: StepsCard) => {',
  '  const n = nextStep(card)',
  "  return n === undefined ? 'every step is finished' : `step ${n + 1} of ${card.steps.length} is next`",
  '}',
  '',
  'export const draw = (card: StepsCard) => <Text dimColor>{left(card)}</Text>',
  '',
].join('\n')
const STEPS_OLD = 'const left = (card: StepsCard) => {'
const STEPS_NEW = [
  "/** The goal tracker's noun (#1245) as its contract has it; it may not be loaded at all. */",
  'type GoalTracker = { waitingOnYou: (input: { message: string }) => Promise<{ isSent: boolean; reason?: string }> }',
  '',
  '// #1245: a card pinned while Dan is not looking at the terminal sat unseen, so a pin with a step he',
  "// can do now tells him through the goal tracker's notifier, the one that pages him for a session",
  '// waiting on him and stays silent while the Mac is asleep. Never on a card held while he is away or',
  '// one already done, neither of which reaches here. Why it was not sent, said to Claude, who can then',
  '// tell Dan in the reply; undefined once it was.',
  'const tellDan = async ($: EngineInterface, card: StepsCard): Promise<string | undefined> => {',
  '  const n = nextStep(card)',
  '  const s = n === undefined ? undefined : card.steps[n]',
  '  if (n === undefined || !s) return undefined',
  '  const message = `"${card.heading}" is pinned. Next, step ${n + 1} of ${card.steps.length}: ${s.title}`',
  '  try {',
  '    const r = await ($ as unknown as { goalTracker: GoalTracker }).goalTracker.waitingOnYou({ message })',
  "    return r?.isSent === true ? undefined : r?.reason || 'the goal tracker did not say why'",
  '  } catch (err) {',
  "    // The noun missing is a TypeError in this mod's own code; one that failed inside the goal",
  '    // tracker reaches here rewrapped by the engine, and is said as it is.',
  '    const isAbsent = err instanceof TypeError && /goalTracker|undefined|not a function|null/.test(message(err))',
  "    return isAbsent ? 'the goal tracker mod, which sends the notifications, is not loaded' : message(err)",
  '  }',
  '}',
  '',
  STEPS_OLD,
].join('\n')
test("#1248: the refused helper is still asked about, by Dan's choice, for the card it reads; one naming no drawing word passes", () => {
  if (STEPS_BEFORE.split(STEPS_OLD).length !== 2) throw new Error('the fixture holds the refused old_string other than once')
  // Dan, 2026-10-16: the line fix only, no word exempted, so the helper reading the card is asked.
  expect(modHookLogicOnly(STEPS_BEFORE, STEPS_BEFORE.replace(STEPS_OLD, STEPS_NEW))).toBe(false)
  // Added directly above the line naming the card, a helper naming no drawing word passes: the
  // untouched line below it is no longer read.
  expect(modHookLogicOnly(STEPS_BEFORE, STEPS_BEFORE.replace(STEPS_OLD, `const nextOf = (n: number) => n + 1\n\n${STEPS_OLD}`))).toBe(true)
})

// #1248: lines added directly above an unchanged line were judged with that line, so a logic line
// added above one that draws (JSX, or a drawing word) was held for a line it never touched.
test('#1248: lines added above, or removed from above, an unchanged line that draws are judged alone; changing that line is still asked', () => {
  // Above a line holding JSX, at the top level.
  expect(modHookLogicOnly(TSX, TSX.replace('export const draw', 'void n(1, 2)\nexport const draw'))).toBe(true)
  // Above a line naming the card, inside a function: added whole, or added after a shared start of line.
  const line = '  const n = nextStep(card)\n'
  expect(modHookLogicOnly(STEPS_BEFORE, STEPS_BEFORE.replace(line, `  void nextStep\n${line}`))).toBe(true)
  expect(modHookLogicOnly(STEPS_BEFORE, STEPS_BEFORE.replace(line, `  const m = 1\n${line}`))).toBe(true)
  // The drawing line itself changed, or an added line naming a drawing word, is asked about.
  expect(modHookLogicOnly(TSX, TSX.replace('<Text color="green">', '<Text color="green" bold>'))).toBe(false)
  expect(modHookLogicOnly(STEPS_BEFORE, STEPS_BEFORE.replace(line, '  const n = nextStep(card) ?? 0\n'))).toBe(false)
  expect(modHookLogicOnly(STEPS_BEFORE, STEPS_BEFORE.replace(line, `  void card\n${line}`))).toBe(false)
  // A line taken from above one that draws, alike.
  expect(modHookLogicOnly(STEPS_BEFORE.replace(line, `  void nextStep\n${line}`), STEPS_BEFORE)).toBe(true)
  expect(modHookLogicOnly(STEPS_BEFORE.replace(line, `  void card\n${line}`), STEPS_BEFORE)).toBe(false)
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

// #1275: on 2026-10-16 the #1263 divider was added in manual steps' card.ts (cardLines), which builds
// every line the steps card draws, and the guard never saw it: only .tsx and .jsx files counted. A
// mod's .ts hook file is judged by what in it reaches what the mod draws: a line builder (a function
// making mod-kit's text runs, dividers or buttons), anything handed to a drawing call (mod-kit's
// band, pane and card, a blocked card, a pane's size) or used inside JSX, and every name those use.
// The fixture is shaped after manual steps: card.ts builds the lines, register.tsx draws them.
const LINES_TS = [
  "import type { StepsCard } from '../types/index.d.ts'",
  '',
  '/** How long a sent step waits for the turn its Done starts. */',
  'export const DROPPED_AFTER_MS = 2 * 60_000',
  "const AMBER = 'warning'",
  'export type CardText = { text: string; color?: string; dim?: boolean }',
  '// One line each.',
  "const oneLine = (s: string) => s.replace(/\\s+/g, ' ').trim()",
  'export const finish = (card: StepsCard, n: number): string | undefined => {',
  '  if (!card.steps[n - 1]) return `There is no step ${n}; the card has ${card.steps.length}.`',
  '  return undefined',
  '}',
  'const finishedWhen = (at: number): string => `on ${new Date(at).toISOString().slice(0, 10)}`',
  'export const cardLines = (card: StepsCard): (CardText[] | { divider: true })[] => {',
  '  // The heading first, then each step.',
  '  const lines: (CardText[] | { divider: true })[] = [[{ text: card.heading, color: AMBER }]]',
  '  card.steps.forEach((s, i) => {',
  '    const label = `${i + 1}. ${oneLine(s.title)}`',
  '    lines.push([{ text: label }, ...(s.finishedAt === undefined ? [] : [{ text: `  ${finishedWhen(s.finishedAt)}`, dim: true }])])',
  '  })',
  '  return lines',
  '}',
  'export const MAX_PANE_COLUMNS = 80',
  'export const paneColumns = (card: StepsCard): number => Math.min(MAX_PANE_COLUMNS, 2 + Math.max(...card.steps.map(s => s.title.length)))',
  '// A generic arrow, which a .ts file may write with no comma.',
  'const serial = <T>(work: () => Promise<T>): Promise<T> => work()',
  'export const later = serial',
  '',
].join('\n')
const WAITING_TS = ['export const phrase = (n: number): string => `waiting ${n} min`', 'export const waitedLong = (n: number): boolean => n > 5', ''].join('\n')
const STORE_TS = ["export const KEY = 'steps'", 'export const keyOf = (repo: string): string => `${KEY}:${repo}`', ''].join('\n')
const DRAW_TSX = [
  "import type { Register } from 'claude-code'",
  "import { cardLines, DROPPED_AFTER_MS, finish, paneColumns } from './card.ts'",
  "import { phrase, waitedLong } from './waiting.ts'",
  "import { keyOf } from './store.ts'",
  '',
  'export const register: Register = on => {',
  "  on('session.start', async ($, e, next) => {",
  '    const card = await $.store.get(keyOf(e.repo))',
  '    if (finish(card, 1) || waitedLong(DROPPED_AFTER_MS)) return next(e)',
  "    await $.modkit.bandRow({ mod: 'demo', id: 'steps', slot: 'steps', lines: cardLines(card) as never })",
  '    await $.ui',
  "      .open({ id: 'pane', title: 'Steps', columns: paneColumns(card) })",
  '    return next(e)',
  '  })',
  "  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {",
  '    const { Text } = $.ui.resolve(e)',
  '    return <Text dimColor>{phrase(e.props.n)}</Text>',
  '  })',
  '}',
  '',
].join('\n')
const MOD_FILES = [
  { name: 'card.ts', text: LINES_TS },
  { name: 'waiting.ts', text: WAITING_TS },
  { name: 'store.ts', text: STORE_TS },
  { name: 'register.tsx', text: DRAW_TSX },
]
// Whether changing `name` from its text in MOD_FILES, replacing `from` with `to`, changes what the mod draws.
const draws = (name: string, from: string, to: string): boolean => {
  const was = MOD_FILES.find(f => f.name === name)?.text ?? ''
  if (was.split(from).length !== 2) throw new Error(`${name} holds ${from} other than once`)
  return drawsChange(MOD_FILES, name, was, was.replace(from, to))
}

test('#1275: a mod hook .ts file is one in its hooks folder, never a declaration file or one elsewhere in the mod', () => {
  for (const rel of ['payload/mods/manual-steps/hooks/card.ts', 'mods/x/hooks/a.mts', '/r/payload/mods/x/hooks/a.cts']) expect(isModHookTs(rel)).toBe(true)
  for (const rel of ['payload/mods/x/hooks/types.d.ts', 'payload/mods/x/types/index.ts', 'payload/mods/x/hooks/sub/a.ts', 'payload/mods/x/hooks/register.tsx', 'src/hooks/a.ts', 'payload/mods/x/tests/a.ts']) expect(isModHookTs(rel)).toBe(false)
})

test('#1275: a change to what a line builder draws is asked about: the #1263 divider, a run it builds, a helper or value it uses, and a pane size', () => {
  // The #1263 divider, as it was added to cardLines.
  expect(draws('card.ts', '    const label = `${i + 1}. ${oneLine(s.title)}`', '    if (i > 0) lines.push({ divider: true })\n    const label = `${i + 1}. ${oneLine(s.title)}`')).toBe(true)
  // A run's look, and its words.
  expect(draws('card.ts', '{ text: card.heading, color: AMBER }', '{ text: card.heading, color: AMBER, bold: true }')).toBe(true)
  expect(draws('card.ts', 'const label = `${i + 1}. ', 'const label = `Step ${i + 1}: ')).toBe(true)
  // What it uses: a helper's words, a colour's value, a trimming of what is shown.
  expect(draws('card.ts', '`on ${new Date', '`finished ${new Date')).toBe(true)
  expect(draws('card.ts', "const AMBER = 'warning'", "const AMBER = 'error'")).toBe(true)
  expect(draws('card.ts', ".replace(/\\s+/g, ' ')", ".replace(/\\s+/g, '  ')")).toBe(true)
  // A value handed to a drawing call that builds no run: the pane's width, and what it is made of.
  expect(draws('card.ts', 'Math.min(MAX_PANE_COLUMNS, 2 +', 'Math.min(MAX_PANE_COLUMNS, 4 +')).toBe(true)
  expect(draws('card.ts', 'MAX_PANE_COLUMNS = 80', 'MAX_PANE_COLUMNS = 100')).toBe(true)
  // Used inside JSX in another file of the mod.
  expect(draws('waiting.ts', '`waiting ${n} min`', '`waiting ${n} minutes`')).toBe(true)
})

test('#1275: a logic only edit to a line builder file passes, as does any edit to a .ts file that draws nothing', () => {
  // Logic beside the builder: a value only a condition reads, a refusal Claude reads (naming the card), a new function.
  expect(draws('card.ts', '2 * 60_000', '3 * 60_000')).toBe(false)
  expect(draws('card.ts', 'the card has ${card.steps.length}', 'the card holds ${card.steps.length} steps')).toBe(false)
  expect(draws('card.ts', 'export const MAX_PANE_COLUMNS', 'export const isOpen = (card: StepsCard): boolean => card.steps.length > 0\nexport const MAX_PANE_COLUMNS')).toBe(false)
  // A comment inside the builder, its spacing, and a type, none of which is drawn.
  expect(draws('card.ts', '// The heading first, then each step.', '// The heading first, then each step, in order.')).toBe(false)
  expect(draws('card.ts', '  return lines\n}', '  return   lines\n}')).toBe(false)
  expect(draws('card.ts', 'dim?: boolean }', 'dim?: boolean; bold?: boolean }')).toBe(false)
  // A function the mod uses only to decide, in a file that also feeds JSX.
  expect(draws('waiting.ts', 'n > 5', 'n > 10')).toBe(false)
  // What an element does when pressed is no part of how it looks, so a handler's names are not followed.
  const pressed = MOD_FILES.map(f => (f.name === 'register.tsx' ? { ...f, text: f.text.replace('<Text dimColor>', '<Text dimColor onPress={() => waitedLong(1)}>') } : f))
  expect(drawsChange(pressed, 'waiting.ts', WAITING_TS, WAITING_TS.replace('n > 5', 'n > 10'))).toBe(false)
  expect(drawsChange(pressed, 'waiting.ts', WAITING_TS, WAITING_TS.replace('min`', 'minutes`'))).toBe(true)
  // A file that draws nothing, edited anywhere, made or taken away.
  expect(draws('store.ts', "export const KEY = 'steps'", "export const KEY = 'manual-steps'")).toBe(false)
  expect(drawsChange(MOD_FILES, 'store.ts', STORE_TS, undefined)).toBe(false)
  expect(drawsChange(MOD_FILES, 'new.ts', undefined, 'export const twice = (n: number) => n * 2\n')).toBe(false)
})

test('#1275: a new line builder, a builder taken away, a call drawing in the file itself, and what cannot be read are asked about', () => {
  expect(drawsChange(MOD_FILES, 'new.ts', undefined, "export const row = (t: string) => [{ text: t, color: 'warning' }]\n")).toBe(true)
  expect(drawsChange(MOD_FILES, 'card.ts', LINES_TS, undefined)).toBe(true)
  // A .ts file of its own that draws through mod-kit: the call's own values, and none beside it.
  const own = [
    'export const show = async ($: { modkit: { bandRow: (r: unknown) => Promise<void> } }, n: number) => {',
    '  if (n > 2) return',
    "  await $.modkit.bandRow({ mod: 'demo', id: 'x', slot: 'steps', frame: { kind: 'left-rule' }, lines: [] })",
    '}',
    '',
  ].join('\n')
  const files = [...MOD_FILES, { name: 'show.ts', text: own }]
  expect(drawsChange(files, 'show.ts', own, own.replace("kind: 'left-rule'", "kind: 'box'"))).toBe(true)
  expect(drawsChange(files, 'show.ts', own, own.replace('n > 2', 'n > 3'))).toBe(false)
  // Text the reader cannot follow, in the file or beside it, is held rather than passed.
  expect(drawsChange(MOD_FILES, 'store.ts', STORE_TS, STORE_TS.replace("'steps'", "'steps"))).toBe(true)
  const broken = MOD_FILES.map(f => (f.name === 'register.tsx' ? { ...f, text: f.text.replace('<Text dimColor>', '<Text dimColor') } : f))
  expect(drawsChange(broken, 'store.ts', STORE_TS, STORE_TS.replace("'steps'", "'manual-steps'"))).toBe(true)
})

test('#1275 (lessons review): a statement continued on an unindented line stays one, and an import written without .ts is followed', () => {
  // A drawn constant whose value goes on past its first line, at the left edge.
  const split = ["export const AMBER =", "'warning'", 'export const row = (t: string) => [{ text: t, color: AMBER }]', 'export const later = 1', ''].join('\n')
  const files = [{ name: 'look.ts', text: split }]
  expect(drawsChange(files, 'look.ts', split, split.replace("'warning'", "'error'"))).toBe(true)
  expect(drawsChange(files, 'look.ts', split, split.replace('later = 1', 'later = 2'))).toBe(false)
  // A statement ending in a generic's `>` is whole, so the declaration after it is its own; an
  // arrow left open at `=>` goes on.
  const generic = ['export type Rows = Array<string>', "const AMBER = 'warning'", 'export const row = (t: string) =>', '  [{ text: t, color: AMBER }]', ''].join('\n')
  const g = [{ name: 'look.ts', text: generic }]
  expect(drawsChange(g, 'look.ts', generic, generic.replace("'warning'", "'error'"))).toBe(true)
  expect(drawsChange(g, 'look.ts', generic, generic.replace('Array<string>', 'Array<number>'))).toBe(false)
  // So is one ending in a non-null assertion or an increment, which leave nothing open.
  for (const end of ['export const sure = maybe!', 'export let n = 0; n++', 'export let m = 9; m--']) {
    const t = [end, "const AMBER = 'warning'", 'export const row = (t: string) => [{ text: t, color: AMBER }]', ''].join('\n')
    expect(drawsChange([{ name: 'look.ts', text: t }], 'look.ts', t, t.replace("'warning'", "'error'"))).toBe(true)
  }
  // The names a drawing file imports from './card' or './card.js' are the card.ts file's.
  for (const spec of ['./card', './card.js']) {
    const tsx = DRAW_TSX.replace("from './card.ts'", `from '${spec}'`)
    const mod = MOD_FILES.map(f => (f.name === 'register.tsx' ? { ...f, text: tsx } : f))
    expect(drawsChange(mod, 'card.ts', LINES_TS, LINES_TS.replace('MAX_PANE_COLUMNS = 80', 'MAX_PANE_COLUMNS = 100'))).toBe(true)
  }
})

test('#1275: the reader follows a .ts file with no JSX in it, a generic arrow with no comma included', () => {
  const serial = 'const serial = <T>(work: () => Promise<T>): Promise<T> => work()\n'
  expect(sourceSpans(serial)).toBeNull()
  expect(sourceSpans(serial, false)?.jsx).toEqual([])
})

// #1296: a value reaching a drawing call through a local variable or a function's parameter is
// followed too. The fixture is shaped after a guard: its blocked card sentences are handed to its own
// drawCard, through a local holding a card's words and as literals at each call.
const GUARD_TS = [
  "import { judge } from './judge.ts'",
  "const GUARD = 'Demo guard'",
  "const BLOCKED = 'This would change the record.'",
  "const unsureCard = (files: string[]) => ({ reason: `Could not tell ${files.join(', ')}.`, safeWay: 'Name the file.' })",
  'const drawCard = async ($: Engine, id: string, reason: string, safeWay: string) => {',
  '  try {',
  '    await $.modkit.blocked({ toolUseId: id, guard: GUARD, reason, safeWay })',
  '  } catch (err) {',
  '    log(err)',
  '  }',
  '}',
  'export const refuse = async ($: Engine, id: string, all: string[], forged: boolean) => {',
  '  if (forged) {',
  "    await drawCard($, id, BLOCKED, 'Only answers write it.')",
  "    return 'forged'",
  '  }',
  '  const c = unsureCard(judge(all))',
  '  await drawCard($, id, c.reason, c.safeWay)',
  '  const note = `Held ${all.length} files.`',
  "  await $.modkit.blocked({ toolUseId: id, guard: GUARD, reason: note, safeWay: 'Ask Dan.' })",
  "  for (const title of TITLES) await $.ui.open({ id: 'p', title })",
  "  ROWS.forEach(r => $.ui.open({ id: 'q', title: r }))",
  "  return 'unsure'",
  '}',
  "const TITLES = ['Held']",
  "const ROWS = ['Waiting']",
  'export const ttl = (n: number) => n * 1000',
  'const log = (err: unknown) => console.error(String(err))',
  '',
].join('\n')
const JUDGE_TS = ["export const judge = (paths: string[]) => paths.filter(p => p.endsWith('.ts'))", ''].join('\n')
const GUARD_FILES = [
  { name: 'register.ts', text: GUARD_TS },
  { name: 'judge.ts', text: JUDGE_TS },
]
const guardDraws = (name: string, from: string, to: string, files = GUARD_FILES): boolean => {
  const was = files.find(f => f.name === name)?.text ?? ''
  if (was.split(from).length !== 2) throw new Error(`${name} holds ${from} other than once`)
  return drawsChange(files, name, was, was.replace(from, to))
}

test('#1296: a value reaching a drawing call through a parameter or a local is asked about', () => {
  // A sentence handed to the guard's own drawCard, as a constant and as a literal at the call.
  expect(guardDraws('register.ts', "BLOCKED = 'This would change the record.'", "BLOCKED = 'This changes the record.'")).toBe(true)
  expect(guardDraws('register.ts', "'Only answers write it.'", "'Only his answers write it.'")).toBe(true)
  // A card's words, reached through a local holding what a top level function builds.
  expect(guardDraws('register.ts', '`Could not tell ${', '`Could not say ${')).toBe(true)
  expect(guardDraws('register.ts', "safeWay: 'Name the file.'", "safeWay: 'Name it.'")).toBe(true)
  // A local handed straight to a drawing call, and a pane title through a loop's binding and a callback's parameter.
  expect(guardDraws('register.ts', '`Held ${all.length} files.`', '`Holding ${all.length} files.`')).toBe(true)
  expect(guardDraws('register.ts', "TITLES = ['Held']", "TITLES = ['Holding']")).toBe(true)
  expect(guardDraws('register.ts', "ROWS = ['Waiting']", "ROWS = ['Queued']")).toBe(true)
})

test('#1296: a drawing function called from another of the mod files is followed into that call', () => {
  const card = GUARD_TS.replace('const drawCard =', 'export const drawCard =')
  const other = ["import { drawCard } from './register.ts'", "export const warn = ($: Engine, id: string) => drawCard($, id, 'Careful.', 'Stop.')", 'export const wait = 30', ''].join('\n')
  const files = [
    { name: 'register.ts', text: card },
    { name: 'judge.ts', text: JUDGE_TS },
    { name: 'warn.ts', text: other },
  ]
  expect(guardDraws('warn.ts', "'Careful.'", "'Be careful.'", files)).toBe(true)
  expect(guardDraws('warn.ts', 'wait = 30', 'wait = 60', files)).toBe(false)
})

test('#1296: following values into drawing calls still passes logic only edits', () => {
  // What decides which files a card names is data handed to the function building its words, not its look.
  expect(guardDraws('judge.ts', "p.endsWith('.ts')", "p.endsWith('.tsx')")).toBe(false)
  // The guard's own conditions, what it returns, what it logs, and a value nothing draws.
  expect(guardDraws('register.ts', '  if (forged) {', '  if (forged && id) {')).toBe(false)
  expect(guardDraws('register.ts', "return 'unsure'", "return 'unsure!'")).toBe(false)
  expect(guardDraws('register.ts', 'console.error(String(err))', 'console.warn(String(err))')).toBe(false)
  expect(guardDraws('register.ts', 'n * 1000', 'n * 60_000')).toBe(false)
})

test('#1296: which call a card attaches to, what a value is only tested for, and data a method works on are not followed', () => {
  const t = [
    'export const show = async ($: Engine, raw: { id?: string }, files: string[], away: boolean) => {',
    "  const id = raw.id ?? 'none'",
    "  const named = files.filter(f => f.endsWith('.ts'))",
    "  const note = away ? 'You are away.' : `Held ${named}.`",
    "  await $.modkit.blocked({ toolUseId: id, guard: 'G', reason: note, safeWay: 'Ask.' })",
    '}',
    '',
  ].join('\n')
  const one = (from: string, to: string) => drawsChange([{ name: 'a.ts', text: t }], 'a.ts', t, t.replace(from, to))
  expect(one("raw.id ?? 'none'", "raw.id ?? 'nobody'")).toBe(false)
  expect(one("f.endsWith('.ts')", "f.endsWith('.tsx')")).toBe(false)
  // The words themselves, either way the test goes, are still asked about.
  expect(one("'You are away.'", "'You are out.'")).toBe(true)
  expect(one('`Held ${named}.`', '`Holding ${named}.`')).toBe(true)
  // Only the keys named for that are left out: any other key's value is followed (lessons review).
  const keyed = ["const KIND = 'steps'", 'export const show = async ($: Engine) => {', '  const k = KIND', "  await $.modkit.bandRow({ mod: 'demo', id: 'x', slot: 's', key: k, lines: [] })", '}', ''].join('\n')
  expect(drawsChange([{ name: 'b.ts', text: keyed }], 'b.ts', keyed, keyed.replace("'steps'", "'rows'"))).toBe(true)
})

// #1322: an answer under an issue counts only from the fixed branch reading on; one under a branch or
// a session counts whatever it carries.
test('which kept answers count, by the branch reading they were written with (#1322)', () => {
  const issue = 'record:/w/slate|issue:84'
  expect(answerCounts(issue, undefined)).toBe(false)
  expect(answerCounts(issue, 1)).toBe(false)
  expect(answerCounts(issue, '2')).toBe(false)
  expect(answerCounts(issue, ISSUE_READING)).toBe(true)
  expect(answerCounts(issue, ISSUE_READING + 1)).toBe(true)
  expect(answerCounts('record:/w/slate|branch:worktree-agent-ad4e7831d26de84f8', undefined)).toBe(true)
  expect(answerCounts('record:/w/slate|branch:main|session:s1', undefined)).toBe(true)
  // A branch whose name holds an issue: key text, not a subject keyed by issue.
  expect(answerCounts('record:/w/slate|branch:issue:84', undefined)).toBe(true)
})
