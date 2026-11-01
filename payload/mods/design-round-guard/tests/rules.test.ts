import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import {
  spoolNote,
  ISSUE_READING,
  isDesignRecord,
  sealCheck,
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
  modHookTsHold,
  shellOutcome,
  shellUnchecked,
  card,
  unsureCard,
  unreadableCard,
  messageWordingSame,
  modHookLogicOnly,
  modHookDrawingUntouched,
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
  nameFromOutput,
  nameFromVariable,
  editWouldNotApply,
  outputTrusted,
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
  commentOnlyChange,
  shellUnread,
  bracketsOpen,
  namedByIssue,
  skipIssueProblem,
  notLookWhy,
} from '../hooks/rules.ts'
import * as allRules from '../hooks/rules.ts'

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
  // A group (bash's extglob, zsh's alternation and a zsh qualifier at the end) is read as every name
  // it can spell, the group taken literally included, as a script that globs nothing receives it
  // (#1773; until then every group was said to be unreadable, and held).
  for (const w of [
    'x.@(css|md)',
    'x.(css|md)',
    // A zsh qualifier at the end filters, so the name is what comes before it.
    '*.css(N)',
    'x.*(.)',
    'page.?(tsx)',
    // A group that may spell nothing, or anything, is read as such before a look changing name.
    '!(x)tokens.json',
    '?(a)tailwind.config.ts',
    '+(a).tsx',
    'fn(x.tsx)',
    'x.(md|(c|t)ss)',
    // A parenthesis inside a bracket is one of its set, never a group.
    '[(]x.css',
  ])
    expect([w, patternMayBeLook(w)]).toEqual([w, 'look'])
  for (const w of [
    'x.(md|txt)',
    'x.@(md|txt)',
    '\\(x\\).md',
    // #1773: code snippets a mutation script was handed, which spell no look changing name however
    // their parentheses and bars are read.
    'if (a || b) {',
    'if (!(a)) return',
    'if (ms > CONTINUATION_WINDOW_MS) {',
    'children.filter(c => c.failed)',
    'return retries > 0 ? (n | 1) : 0',
    'a || b',
    'foo(',
    'foo)',
    // A name after a command substitution has closed is read as any name.
    '/api/issues/$(cat id)/events/?full=true',
  ])
    expect([w, patternMayBeLook(w)]).toEqual([w, 'not'])
  // zsh's globbing flags (`(#i)`, `(#a1)`, `(#q...)`) change how the rest matches, and are read by no
  // rule here; nor is a name spelling more ways than are worth reading.
  // A command substitution's output is the names, whatever its own text spells (`$(git ls-files
  // 'src/*.tsx')`, measured on 2026-10-27 among the commands #1773 would otherwise have let through).
  for (const w of ['(#i)x.css', 'x(#a1).tsz', `${'f(a|b|c)'.repeat(6)}.md`, "$(git ls-files 'src/*.tsx')", "$(ls 'app/(shop)')"])
    expect([w, patternMayBeLook(w)]).toEqual([w, 'unread'])
  // So is one holding no pattern at all (#1815: `$(git ls-files src)`), or a backtick's.
  for (const w of ['$(git ls-files src)', '$(git ls-files src/app)', '`git ls-files src`', 'src/$(cat name)', 'x$(date).css', '$(git diff --name-only'])
    expect([w, patternMayBeLook(w)]).toEqual([w, 'unread'])
})

test('#1815: a name a command substitution fills in is known by its last part, read past the slashes inside one', () => {
  for (const w of ['$(git ls-files src)', '$(git ls-files src/app)', '`git ls-files src/app`', 'src/$(cat name)', 'app/x$(date).css', '$(find . -name "*.tsx"', "$(ls 'app/(shop)')"])
    expect([w, nameFromOutput(w)]).toEqual([w, true])
  // A substitution in the folder only, none at all, or a variable, which is no command's output.
  for (const w of ['$(git rev-parse --show-toplevel)/notes.md', '/api/issues/$(cat id)/events/?full=true', '`pwd`/x.md', 'app/page.tsx', '$HOME/x', '${D}/spec.json', 'if (a || b) {', 'cost $5'])
    expect([w, nameFromOutput(w)]).toEqual([w, false])
})

// #1953: a name a shell variable fills in, read by its last part outside any substitution.
test('#1953: a name a shell variable fills in is known by its last part; a folder variable and one only in a folder or a substitution are not', () => {
  for (const w of ['$P', '${P}', 'src/$f', '$PWD/$r', '${args[@]}', '$=T', '--sha=$SHA', 'x-$i.png', '$HOMEDIR', '$PWD2', 'cost $5'])
    expect([w, nameFromVariable(w)]).toEqual([w, true])
  for (const w of ['$PWD', '${PWD}', '$HOME', '${HOME}', '$OLDPWD', '$TMPDIR', '$HOME/x.md', '${D}/spec.json', '$(git -C $W rev-parse HEAD)', '`echo $X`', 'src/$(cat $F)', 'notes.md', 'app/*push*', 'cost$'])
    expect([w, nameFromVariable(w)]).toEqual([w, false])
})

// #1954: an Edit or MultiEdit whose text is not in the file, or is there twice without replace_all,
// would not apply; one Claude Code's Edit may still apply by matching curly quotes to straight ones,
// one replacing empty text, and any other tool are not read so.
test('#1954: an edit would not apply where its text is missing or repeated, read past curly quotes', () => {
  const text = "const a = 'x'\nconst b = 'x'\n"
  const edit = (old_string: string, extra: Record<string, unknown> = {}) => ({ old_string, new_string: 'y', ...extra })
  expect(editWouldNotApply(text, 'Edit', edit('const c'))).toBe(true)
  expect(editWouldNotApply(text, 'Edit', edit("'x'"))).toBe(true)
  expect(editWouldNotApply(text, 'MultiEdit', { edits: [edit('const a'), edit('const a')] })).toBe(true)
  expect(editWouldNotApply(text, 'Edit', edit("'x'", { replace_all: true }))).toBe(false)
  expect(editWouldNotApply(text, 'Edit', edit('const a'))).toBe(false)
  expect(editWouldNotApply(text, 'Edit', edit('a = ‘x’'))).toBe(false)
  expect(editWouldNotApply(text, 'MultiEdit', { edits: [edit('const a'), edit('b = “x')] })).toBe(true)
  expect(editWouldNotApply(text, 'Edit', edit(''))).toBe(false)
  expect(editWouldNotApply(text, 'Write', { content: 'y' })).toBe(false)
  expect(editWouldNotApply(text, 'MultiEdit', { edits: [] })).toBe(false)
})

// #1832, Dan, 2026-10-27 (picker answer "git rev-parse only"): of the substitutions a script is
// handed, only `git rev-parse`'s output is trusted to name no file. Anything else it runs, a second
// command beside it, a substitution inside it or one never closed, is not.
test('#1832: only a substitution running git rev-parse alone is trusted to name no file', () => {
  // git rev-parse in another checkout (-C) is still git rev-parse: 23 of the 147 script arguments the
  // #1832 replay found were `$(git -C <folder> rev-parse HEAD)`.
  for (const w of ['$(git rev-parse HEAD)', '"$(git rev-parse HEAD)"', '$(git rev-parse --short HEAD)', '`git rev-parse HEAD`', '$(git  rev-parse HEAD)', '$(git -C $W rev-parse HEAD)', '$(git -C /w/x rev-parse --short HEAD)', 'abc..$(git rev-parse HEAD)'])
    expect([w, outputTrusted(w)]).toEqual([w, true])
  for (const w of [
    '$(git diff --name-only main)',
    '$(cat /tmp/scope.txt)',
    '`git ls-files src`',
    '$(git rev-parse HEAD; cat x)',
    '$(git rev-parse HEAD && ls src)',
    '$(git rev-parse HEAD | xargs echo)',
    '$(git rev-parse $(cat ref))',
    '$(git rev-parse HEAD)$(cat x)',
    '$(git rev-parse HEAD | cut -c9-)',
    // A redirect inside it writes a file, so it is no longer only printing a commit.
    '$(git rev-parse HEAD > app/page.tsx)',
    '$(git rev-parse HEAD >> log)',
    '$(git rev-parse < x)',
    '$(git -C $(pwd) rev-parse HEAD)',
    '$(git -C x ls-files)',
    '$(git rev-parse HEAD',
    'app/page.tsx',
  ])
    expect([w, outputTrusted(w)]).toEqual([w, false])
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
  // Still so since #1823 (Dan, 2026-10-27: "message wording should be asked about"): the helper
  // draws nothing, but the notification it sends Dan is new wording, so it stays held.
  expect(modHookLogicOnly(STEPS_BEFORE, STEPS_BEFORE.replace(STEPS_OLD, STEPS_NEW))).toBe(false)
  expect(modHookDrawingUntouched([], 'register.tsx', STEPS_BEFORE, STEPS_BEFORE.replace(STEPS_OLD, STEPS_NEW))).toBe(false)
  // And once it is there, rewording the notification is held too.
  const withHelper = STEPS_BEFORE.replace(STEPS_OLD, STEPS_NEW)
  expect(modHookDrawingUntouched([], 'register.tsx', withHelper, withHelper.replace('is pinned. Next, step', 'is on the card. Next, step'))).toBe(false)
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

// #1823: on 2026-10-27 the #1811 builder's Edit to manual steps' register.tsx (held call
// toolu_01F5RzQjX5PsNPoecZroB4fp) only added names to its imports, and was held for the words "card"
// and "StepsCard" in them. The six import lines are the call's old_string and new_string word for
// word; the rest is cut down from the file as it stood: a band row drawn from cardLines, a reply
// sentence Claude reads, and a render hook drawing JSX. card.ts beside it builds the card's lines.
const MS_IMPORTS_OLD = [
  "import type { ManualSteps, StepsCard, StepsPaneId } from '../types/index.d.ts'",
  "import { cardFrom, cardLines, carriedNote, donePrompt, DROPPED_AFTER_MS, finish, fold, keepAdded, keepFinished, nextStep, paneColumns, pressed, sent, VERDICTS } from './card.ts'",
  "import type { DrawnAt, StepsVerdict } from './card.ts'",
  "import { ASKED_PANE, FOLLOW_MS, follow, PANES, UNASKED_PANE } from './place.ts'",
  "import { PROSE_MARK, turnAt } from './turn.ts'",
  "import { waitingPhrase } from './waiting.ts'",
].join('\n')
const MS_IMPORTS_NEW = [
  "import type { ManualSteps, StepsCard, StepsPages, StepsPaneId } from '../types/index.d.ts'",
  "import { cardFrom, cardLines, carriedNote, donePrompt, DROPPED_AFTER_MS, finish, fold, keepAdded, keepFinished, nextStep, paneColumns, pressed, sent, VERDICTS } from './card.ts'",
  "import type { DrawnAt, StepsVerdict } from './card.ts'",
  "import { isStepsPage, pageRefusal, signsOf } from './page.ts'",
  "import { ASKED_PANE, FOLLOW_MS, follow, PANES, UNASKED_PANE } from './place.ts'",
  "import { PROSE_MARK, turnAt } from './turn.ts'",
  "import { saysNoneNow, waitingPhrase } from './waiting.ts'",
].join('\n')
const MS_TSX = [
  "import type { EngineInterface, Register } from 'claude-code'",
  MS_IMPORTS_OLD,
  '',
  "const TOOL = 'steps'",
  "const STEPS_DESCRIPTION = 'Pin manual steps for Dan as a card he works through.'",
  'const PANE_COLUMNS = 144',
  "const placeFor = (columns: number) => (columns >= PANE_COLUMNS ? 'pane' : 'band')",
  '',
  'const movedToBand = ($: EngineInterface, failed: string | undefined) => {',
  '  if (failed) $.ui.toast(`The steps card could not be moved to the band: ${failed}.`)',
  "  $.ui.log('manual-steps: the card went to the band', { to: 'debug' })",
  "  $.ui.log('Manual steps moved the card to the band.')",
  '}',
  'const pinned = (heading: string) => ({ result: `Pinned the card "${heading}".` })',
  '',
  'const proseStep = (phrase: string) =>',
  '  `${PROSE_MARK} ("${phrase}"), and no steps card holds it, so he may never see it once the reply scrolls away. Put it on the card with the ${TOOL} tool.`',
  '',
  'const publishBand = async ($: EngineInterface, card: StepsCard) => {',
  "  const lines = cardLines(card, 'band')",
  "  await $.modkit.bandRow({ mod: 'manual-steps', id: 'steps', lines })",
  '}',
  '',
  'export const register: Register = on => {',
  "  on('session.start', async ($, e, next) => {",
  '    await $.tool.register({ name: TOOL, description: STEPS_DESCRIPTION })',
  '    return next(e)',
  '  })',
  "  on('command.run', { command: 'steps' }, async () => ({ text: 'No steps card is pinned for this project.' }))",
  "  on('classic.Stop', async ($, e, next) => {",
  '    const phrase = waitingPhrase(String(e.last_assistant_message))',
  "    return phrase ? { decision: 'block', reason: proseStep(phrase) } : next(e)",
  '  })',
  "  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {",
  '    const { Box, Text } = $.ui.resolve(e)',
  '    const left = String(e.props.text).length',
  '    return (',
  '      <Box flexDirection="column">',
  '        <Text dimColor>{left} left</Text>',
  '        {await next(e)}',
  '      </Box>',
  '    )',
  '  })',
  '}',
  '',
].join('\n')
const MS_FILES = [
  {
    name: 'card.ts',
    text: [
      'export const DROPPED_AFTER_MS = 2 * 60_000',
      'export const cardLines = (card: { heading: string }, at: string) => [[{ text: `${card.heading} (${at})`, bold: true }]]',
      'export const nextStep = (card: { steps: unknown[] }) => (card.steps.length ? 0 : undefined)',
      '',
    ].join('\n'),
  },
]
const msEdit = (from: string, to: string, text = MS_TSX) => {
  if (text.split(from).length !== 2) throw new Error(`the fixture holds ${from} other than once`)
  return text.replace(from, to)
}

test('#1823: the held Edit adding names to the imports draws nothing new, though it names the card', () => {
  const after = msEdit(MS_IMPORTS_OLD, MS_IMPORTS_NEW)
  // Held today for its words, which is the hold #1823 reports.
  expect(modHookLogicOnly(MS_TSX, after)).toBe(false)
  expect(modHookDrawingUntouched(MS_FILES, 'register.tsx', MS_TSX, after)).toBe(true)
  // A new helper that reads the card's heading for no surface and no message draws nothing either.
  const helper = 'const heading = (card: StepsCard): string => card.heading.trim()\n\n'
  expect(modHookDrawingUntouched(MS_FILES, 'register.tsx', MS_TSX, msEdit('const publishBand', `${helper}const publishBand`))).toBe(true)
})

// #1823, Dan, 2026-10-27: "Timing wording can go through, but message wording should be asked
// about". Where or when the card shows, and words only Claude reads, pass; the wording of a message
// a person sees (a toast, a transcript line, a stop reason, a notification, a tool result) is held.
test('#1823: a placement change and a tool description pass; the wording of a message Dan sees is held', () => {
  const judged = (from: string, to: string) => modHookDrawingUntouched(MS_FILES, 'register.tsx', MS_TSX, msEdit(from, to))
  // Where the card goes, and a description of the tool, which only Claude reads.
  expect(judged('const PANE_COLUMNS = 144', 'const PANE_COLUMNS = 110')).toBe(true)
  expect(judged('as a card he works through.', 'as a card Dan works through, one step at a time.')).toBe(true)
  // A debug log line, which nobody sees in the session, and when the toast is shown, its words alike.
  expect(judged('the card went to the band', 'the steps card went to the band')).toBe(true)
  expect(judged('  if (failed) $.ui.toast(', '  if (failed && failed.length) $.ui.toast(')).toBe(true)
  // A toast's words, a transcript line's, and a stop reason's, each held for its wording.
  expect(judged('could not be moved to the band', 'could not go back to the band')).toBe(false)
  expect(judged('Manual steps moved the card to the band.', 'Manual steps put the card in the band.')).toBe(false)
  expect(judged('Put it on the card with', 'Pin it on the steps card with')).toBe(false)
  // A tool result Claude hands back, which shows in Dan's transcript.
  expect(judged('Pinned the card "', 'Put the card up: "')).toBe(false)
  // What a slash command answers Dan with.
  expect(judged('No steps card is pinned for this project.', 'No steps card is up in this project.')).toBe(false)
})

// #1823: the goal tracker pages Dan by running terminal-notifier, its title reaching it through a
// promise (`title().then(t => notify($, t, ...))`), which the values followed do not cross. Cut down
// from mods/goal-tracker/hooks/register.tsx as it stood on 2026-10-05.
const NOTIFY_TSX = [
  "import type { EngineInterface, Register } from 'claude-code'",
  'const notify = async ($: EngineInterface, title: string, message: string) => {',
  "  await $.process.run(['terminal-notifier', '-title', title, '-message', message], { timeoutMs: 10_000 })",
  '}',
  'const notifySoon = ($: EngineInterface, title: () => Promise<string>, message: string) => {',
  '  void title().then(t => notify($, t, message))',
  '}',
  'const waitingOnYou = ($: EngineInterface, text: string) => notifySoon($, async () => `the steps card is waiting on you`, text)',
  'export const register: Register = on => {',
  "  on('ui.render', { component: 'Pane' }, async ($, e) => {",
  '    const { Text } = $.ui.resolve(e)',
  '    return <Text>goals</Text>',
  '  })',
  '}',
  '',
].join('\n')
test("#1823: a notification's title reaching terminal-notifier through a promise is wording, held when it changes", () => {
  expect(modHookDrawingUntouched([], 'register.tsx', NOTIFY_TSX, NOTIFY_TSX.replace('the steps card is waiting on you', 'the steps card needs you'))).toBe(false)
  // When it is sent is no wording.
  expect(modHookDrawingUntouched([], 'register.tsx', NOTIFY_TSX, NOTIFY_TSX.replace('{ timeoutMs: 10_000 }', '{ timeoutMs: 20_000 }'))).toBe(true)
})

test('#1823: an edit naming the card that changes what is drawn is still held', () => {
  const held = (after: string) => expect(modHookDrawingUntouched(MS_FILES, 'register.tsx', MS_TSX, after)).toBe(false)
  // The words drawn: JSX text, and what a band row is handed.
  held(msEdit('{left} left</Text>', '{left} steps left on the card</Text>'))
  held(msEdit("cardLines(card, 'band')", "cardLines(card, 'pane')"))
  // What a drawn value's call is handed, which the parts compared take out as data.
  held(msEdit("cardLines(card, 'band')", "cardLines({ ...card, heading: 'Card' }, 'band')"))
  // A drawing word inside a function that draws, though nothing reads the new line.
  held(msEdit('    const left = String', '    const card = e.props.text\n    const left = String'))
  // An import now naming another file for a name what is drawn uses.
  held(msEdit("keepFinished, nextStep, paneColumns, pressed, sent, VERDICTS } from './card.ts'", "keepFinished, nextStep, paneColumns, pressed, sent, VERDICTS } from './card2.ts'"))
  held(msEdit('import { cardFrom, cardLines,', 'import { cardFrom, stepLines as cardLines,'))
  // A colour spelled outright, JSX touched, no change, and a text the reader cannot follow.
  held(msEdit("const TOOL = 'steps'", "const TOOL = 'steps'\nconst EDGE = '#ff0000'"))
  held(msEdit('<Text dimColor>', '<Text dimColor bold>'))
  expect(modHookDrawingUntouched(MS_FILES, 'register.tsx', MS_TSX, MS_TSX)).toBe(false)
  held(msEdit("const TOOL = 'steps'", "const TOOL = 'steps'\nconst card = <Box>"))
  // A mod file beside it that cannot be read holds every edit.
  expect(modHookDrawingUntouched([...MS_FILES, { name: 'place.ts', text: "const x = 'open" }], 'register.tsx', MS_TSX, msEdit(MS_IMPORTS_OLD, MS_IMPORTS_NEW))).toBe(false)
})

// What modHookTsHold says of a change to a mod's .ts hook file (#1859): held for what it draws,
// held only for a message's words, or passed. #1911 moved every test of the old yes or no wrapper
// (modHookTsShows) here, so each now says which hold it expects, not only that there is one.
const holdOf = (...a: Parameters<typeof modHookTsHold>): 'look' | 'worded' | 'passes' => {
  const h = modHookTsHold(...a)
  return h === undefined ? 'passes' : 'look' in h ? 'look' : 'worded'
}

// #1841: a mod's .ts hook file was judged only by what it draws (drawsChange), so the wording of a
// toast, a refusal's reason or a tool's result there passed unasked. Dan, 2026-10-27, for #1823:
// "Timing wording can go through, but message wording should be asked about". Cut down from
// mods/secret-guard and mods/job-watcher's register.ts as they stood on 2026-10-28.
const SECRET_TS = [
  "import type { EngineInterface, Register } from 'claude-code'",
  "const GUARD = 'Secret guard'",
  'const KEEP_SPEC = {',
  "  name: 'keep_job',",
  "  description: 'Keep a background job running on purpose, with the reason it must stay up.',",
  '  inputSchema: {',
  "    type: 'object',",
  '    properties: {',
  "      task_id: { type: 'string', description: 'The background job id the Bash call reported.' },",
  "      reason: { type: 'string', description: 'Why it must keep running.' },",
  '    },',
  '  },',
  '}',
  'const refuse = async ($: EngineInterface, what: string, toolUseId: string) => {',
  '  if (what.length > 3) {',
  "    await $.ui.toast('Blocked a command that would print a secret.')",
  '    return { deny: `Blocked: this would print ${what}.` }',
  '  }',
  '  return undefined',
  '}',
  'export const register: Register = on => {',
  "  on('tool.call', { tool: 'keep_job' }, async () => ({ result: 'Kept the job running.' }))",
  '}',
  '',
].join('\n')
test("#1841: the wording of a toast, a refusal or a tool's result in a mod's .ts hook file is asked about, though it draws nothing", () => {
  const edit = (from: string, to: string) => {
    const after = SECRET_TS.replace(from, to)
    if (after === SECRET_TS) throw new Error(`no ${from}`)
    return after
  }
  const judged = (from: string, to: string) => holdOf([], 'register.ts', SECRET_TS, edit(from, to))
  // drawsChange, all a .ts hook file was judged by, lets the toast's new words through.
  expect(drawsChange([], 'register.ts', SECRET_TS, edit('Blocked a command that', 'Stopped a command that'))).toBe(false)
  // A toast's words, a refusal's reason, and a tool's result, each held for its wording.
  expect(judged('Blocked a command that', 'Stopped a command that')).toBe('worded')
  expect(judged('Blocked: this would print', 'Stopped: this would show')).toBe('worded')
  expect(judged('Kept the job running.', 'The job stays up.')).toBe('worded')
  // When the toast is shown, and what decides it, pass.
  expect(judged('what.length > 3', 'what.length > 5')).toBe('passes')
  // A tool's description and its schema's, read only by Claude, pass: a schema property named
  // reason among them, which is no refusal's reason.
  expect(judged('Keep a background job running on purpose', 'Keep a background job up on purpose')).toBe('passes')
  expect(judged('Why it must keep running.', 'Why it has to keep running.')).toBe('passes')
  expect(judged('The background job id', 'The id of the background job')).toBe('passes')
  // What it draws is still held, and a change to nothing at all is none.
  expect(holdOf([], 'row.ts', undefined, "export const row = (t: string) => [{ text: t, color: 'warning' }]\n")).toBe('look')
  expect(holdOf([], 'register.ts', SECRET_TS, SECRET_TS)).toBe('passes')
  // A file made with a message says new words, and one taken away takes them; one with none passes.
  expect(holdOf([], 'register.ts', undefined, SECRET_TS)).toBe('worded')
  expect(holdOf([], 'register.ts', SECRET_TS, undefined)).toBe('worded')
  expect(holdOf([], 'new.ts', undefined, 'export const twice = (n: number) => n * 2\n')).toBe('passes')
  // A mod file beside it that cannot be read holds every edit.
  expect(holdOf([{ name: 'place.ts', text: "const x = 'open" }], 'register.ts', SECRET_TS, edit('what.length > 3', 'what.length > 5'))).toBe('look')
})

// #1925: on 2026-10-29 the #1904 builder's Edit adding "or wording" to the skip question's answers in
// the guard's own rules.ts (skipOptions) went through unasked, though Dan reads each answer's
// description in the picker. Those answers reached no message the check read, while a tool's
// description, which only Claude reads, passes by #1756 and #1841. An answer is an object beside a
// `label`, or one in an `options` list. Cut down from the guard's rules.ts as it stood before #1926,
// with a tool and a schema beside it.
const ANSWERS_TS = [
  "import type { EngineInterface } from 'claude-code'",
  "export const SKIP_YES = 'Skip them'",
  'export const TOOL_SPEC = {',
  "  name: 'skip_rounds',",
  "  description: 'Ask Dan whether to skip design rounds for an issue.',",
  '  inputSchema: {',
  "    type: 'object',",
  '    properties: {',
  "      label: { type: 'string', description: 'The name of the issue to ask about.' },",
  "      description: { type: 'string', description: 'What the refused edit changes.' },",
  '    },',
  '  },',
  '}',
  'export const skipOptions = (named: string) => [',
  '  { label: SKIP_YES, description: `Edits that change the look go ahead on ${named} without a design round` },',
  "  { label: 'Run /design-rounds', description: 'Nothing that changes the look is edited until you settle a design round' },",
  ']',
  "export const onlyOne = (c: boolean, pick: (o?: object) => object) => pick(c ? { label: SKIP_YES, description: 'Only this answer is shown' } : undefined)",
  'export const askAgain = ($: EngineInterface, next: (e: object) => Promise<unknown>) =>',
  "  next({ questions: [{ question: 'Is this design settled?', options: [{ value: 'yes', description: 'Edits that change the look go ahead' }] }] })",
  '',
].join('\n')
test("#1925: an answer's description and label, which Dan reads in the picker, are held as wording; a tool's or a schema's description still passes", () => {
  const edit = (from: string, to: string) => {
    const after = ANSWERS_TS.replace(from, to)
    if (after === ANSWERS_TS) throw new Error(`no ${from}`)
    return after
  }
  const judged = (from: string, to: string) => holdOf([], 'rules.ts', ANSWERS_TS, edit(from, to))
  // The #1904 builder's edit, to an answer's description beside its label, and the same to its label.
  expect(judged('Nothing that changes the look is edited', 'Nothing that changes the look or wording is edited')).toBe('worded')
  expect(judged('go ahead on ${named} without', 'go ahead on ${named} with no')).toBe('worded')
  expect(judged("label: 'Run /design-rounds'", "label: 'Start /design-rounds'")).toBe('worded')
  expect(judged("export const SKIP_YES = 'Skip them'", "export const SKIP_YES = 'Skip the rounds'")).toBe('worded')
  // An answer given by a conditional inside a call's parentheses, which is no parameter's pattern.
  expect(judged('Only this answer is shown', 'Only this one answer is shown')).toBe('worded')
  // An answer in an options list, which names no label of its own.
  expect(judged("description: 'Edits that change the look go ahead' }", "description: 'Edits to the look go ahead' }")).toBe('worded')
  // The refusal names the words it held for.
  const hold = modHookTsHold([], 'rules.ts', ANSWERS_TS, edit('Nothing that changes the look is edited', 'Nothing that changes the look or wording is edited'))
  expect(hold && 'worded' in hold ? hold.worded : '').toContain('Nothing that changes the look or wording')
  // A tool's description, and its schema's, read only by Claude, pass: properties named label and
  // description among them, whose values are schemas, not answers.
  expect(judged('Ask Dan whether to skip', 'Ask Dan if he wants to skip')).toBe('passes')
  expect(judged('The name of the issue to ask about.', 'The issue to ask about.')).toBe('passes')
  expect(judged('What the refused edit changes.', 'What the edit that was refused changes.')).toBe('passes')
  // The logic beside the answers says no new words.
  expect(judged('(named: string)', '(named: string, _first = true)')).toBe('passes')
})

// #1934: the question a mod hands AskUserQuestion through next(), and the header above it, are
// words Dan reads in the picker as surely as its answers (#1925), but reached no message the check
// read, so rewording one passed unless the same words were also said elsewhere. A question is an
// object in a `questions` list, or one with a `question` beside its `options`: its question and header
// read as a message's words. Cut down from the guard's own rules.ts and register.ts (asked) as they
// stood after #1925, with a tool whose schema names question and header properties beside them.
const Q_RULES_TS = [
  "export const HEADER = 'Design round'",
  "export const SKIP_QUESTION = 'Skip design rounds for this issue?'",
  'export const skipQuestion = (named: string) => `${SKIP_QUESTION} It changes ${named}.`',
  'export const TOOL_SPEC = {',
  "  name: 'ask_dan',",
  "  description: 'Ask Dan a question about a design round.',",
  '  inputSchema: {',
  "    type: 'object',",
  '    properties: {',
  "      question: { type: 'string', description: 'The question to put to him.' },",
  "      header: { type: 'string', description: 'A short header above it.' },",
  '    },',
  '  },',
  '}',
  'export type Asked = { questions: { question: string; header: string }[] }',
  '',
].join('\n')
const Q_REGISTER_TS = [
  "import type { EngineInterface } from 'claude-code'",
  "import { HEADER, skipQuestion } from './rules.ts'",
  'type Next = (e: object) => Promise<{ result?: { questions?: { question?: unknown }[] } }>',
  'export const askSkip = async ($: EngineInterface, next: Next, named: string) => {',
  '  const asked = async (question: string, options: { label: string; description: string }[]) => {',
  '    const r = await next({ questions: [{ question, header: HEADER, options, multiSelect: false }] })',
  '    return r.result?.questions?.[0]?.question === question',
  '  }',
  '  return asked(skipQuestion(named), [])',
  '}',
  "export const askSettled = (next: Next) => next({ questions: [{ question: 'Is this design settled?', header: 'Settled', multiSelect: false }] })",
  "export const askOne = (next: Next) => next({ question: 'Keep this answer?', options: [] })",
  '',
].join('\n')
test("#1934: a question's text and header, which Dan reads in the picker, are held as wording, in the file asking it or the one it is worded in; a tool's schema naming them still passes", () => {
  const edited = (text: string, from: string, to: string) => {
    const after = text.replace(from, to)
    if (after === text) throw new Error(`no ${from}`)
    return after
  }
  const inRegister = (from: string, to: string) => holdOf([{ name: 'rules.ts', text: Q_RULES_TS }], 'register.ts', Q_REGISTER_TS, edited(Q_REGISTER_TS, from, to))
  const inRules = (from: string, to: string) => holdOf([{ name: 'register.ts', text: Q_REGISTER_TS }], 'rules.ts', Q_RULES_TS, edited(Q_RULES_TS, from, to))
  // A question and header written where it is asked, in a questions list or beside options.
  expect(inRegister('Is this design settled?', 'Is the design settled?')).toBe('worded')
  expect(inRegister("header: 'Settled'", "header: 'Design settled'")).toBe('worded')
  expect(inRegister('Keep this answer?', 'Keep that answer?')).toBe('worded')
  // One handed in as a parameter (asked's `question`), worded in another file, and the header's constant.
  expect(inRules("'Skip design rounds for this issue?'", "'Skip the design rounds for this issue?'")).toBe('worded')
  expect(inRules('It changes ${named}.', 'It would change ${named}.')).toBe('worded')
  expect(inRules("HEADER = 'Design round'", "HEADER = 'Design rounds'")).toBe('worded')
  // The refusal names the words it held for.
  const hold = modHookTsHold([{ name: 'rules.ts', text: Q_RULES_TS }], 'register.ts', Q_REGISTER_TS, edited(Q_REGISTER_TS, 'Is this design settled?', 'Is the design settled?'))
  expect(hold && 'worded' in hold ? hold.worded : '').toContain('Is the design settled?')
  // A tool's schema describing question and header properties, read only by Claude, passes.
  expect(inRules('The question to put to him.', 'The question to ask him.')).toBe('passes')
  expect(inRules('A short header above it.', 'A header above it.')).toBe('passes')
  // So does the logic around the question.
  expect(inRegister('multiSelect: false }] })\n    return', 'multiSelect: true }] })\n    return')).toBe('passes')
})

// #1859: a hold made only because a message's words changed said the edit "changes how the screen
// looks", and a shell write's that it "changed what the mod draws", claiming more than the check
// measured (L11). The check says why it held (modHookTsHold), naming the words, and every refusal,
// card and shell outcome says that reason; a real look change still says the look.
test("#1859: a hold for a message's words alone says so, naming the words, and never the screen's look; a look change still says the look", () => {
  const reworded = SECRET_TS.replace('Blocked a command that', 'Stopped a command that')
  const hold = modHookTsHold([], 'register.ts', SECRET_TS, reworded)
  const words = hold && 'worded' in hold ? hold.worded : ''
  expect(words).toContain('Stopped a command that')
  // A look change, logic alone, and words taken away.
  expect(modHookTsHold([], 'row.ts', undefined, "export const row = (t: string) => [{ text: t, color: 'warning' }]\n")).toEqual({ look: true })
  expect(modHookTsHold([], 'register.ts', SECRET_TS, SECRET_TS.replace('what.length > 3', 'what.length > 5'))).toBe(undefined)
  const gone = modHookTsHold([], 'register.ts', SECRET_TS, SECRET_TS.replace("result: 'Kept the job running.'", "result: ''"))
  expect(gone && 'worded' in gone ? gone.worded : '').toContain('Kept the job running.')
  // Long words are shortened, their spaces run together.
  const long = SECRET_TS.replace('Blocked a command that would print a secret.', `Stopped ${'a very long sentence   '.repeat(8)}that ends here.`)
  const shortened = modHookTsHold([], 'register.ts', SECRET_TS, long)
  const said = shortened && 'worded' in shortened ? shortened.worded : ''
  expect(said.length).toBeLessThan(80)
  expect(said.includes('  ')).toBe(false)
  expect(said.startsWith('Stopped a very long')).toBe(true)

  const subjects = [{ key: 'k', label: 'issue #1859 in claude-config' }]
  const file = 'payload/mods/demo/hooks/guard.ts'
  const worded = [{ file, words }]
  const LOOK = 'changes how the screen looks'
  const WORDS = 'changes the words of a message Dan reads'
  for (const r of [
    refusal('t1', [file], subjects, [], worded),
    agentRefusal([file], subjects, 't2', [], worded),
    checked([file], subjects, [], worded),
    unsure([file], 'a detached head names no branch', worded),
    unreadable([file], subjects, 'EIO', worded),
  ]) {
    expect({ r, words: r.includes(WORDS) && r.includes('Stopped a command that') }).toEqual({ r, words: true })
    expect({ r, look: r.includes(LOOK) }).toEqual({ r, look: false })
    expect(DASHES.test(r)).toBe(false)
  }
  for (const c of [card([file], subjects, worded), unsureCard([file], worded), unreadableCard([file], worded)]) {
    expect({ c: c.reason, words: c.reason.includes('Stopped a command that') }).toEqual({ c: c.reason, words: true })
    expect({ c: c.reason, look: c.reason.includes('looks on screen') }).toEqual({ c: c.reason, look: false })
  }
  // A real look change says the look, and never a message's words.
  for (const r of [refusal('t3', ['app/page.tsx'], subjects), agentRefusal(['app/page.tsx'], subjects, 't4'), checked(['app/page.tsx'], subjects)]) {
    expect(r).toContain(`app/page.tsx ${LOOK}`)
    expect(r.includes(WORDS)).toBe(false)
  }
  expect(card(['app/page.tsx'], subjects).reason.startsWith('Claude wants to make an edit that may change how something looks on screen')).toBe(true)
  // Both at once: each file is said with its own reason.
  const both = refusal('t5', ['app/page.tsx', file], subjects, [], worded)
  expect(both).toContain(`app/page.tsx ${LOOK}`)
  expect(both).toContain(`${file} ${WORDS}`)
  expect(both.includes(`${file} ${LOOK}`)).toBe(false)

  // A shell write held for a message's words says so, never what the mod draws.
  for (const o of [{ file, undone: '/s/kept' }, { file, unkept: 'no scratchpad' }, { file, changed: '/s/kept' }, { file, failed: 'EIO', kept: '/s/kept' }]) {
    const s = shellOutcome(o, false, words)
    expect({ s, words: s.includes('the words of a message Dan reads') && s.includes('Stopped a command that') }).toEqual({ s, words: true })
    expect({ s, draws: s.includes('what the mod draws') }).toEqual({ s, draws: false })
    expect(shellOutcome(o)).toContain('what the mod draws')
  }
  // One that could not be read after says it cannot tell which of the two it was, and so does a check
  // after a shell write that itself failed.
  expect(shellOutcome({ file, unread: 'EIO' })).toContain('what the mod draws or the words of a message Dan reads')
  expect(shellUnchecked('EIO')).toContain('the words of a message Dan reads')
})

// #1841, Dan, 2026-10-28 ("Narrow it first"): only the words a person reads count. Replayed, about 50
// of the edits the wider reading held changed only a string a message's value is computed from: a
// regular expression (keystroke guard's `open -a` pattern, 2026-10-26), a `typeof` tag, a command's
// words and flags, a separator. Shaped after mods/keystroke-guard's keys.ts and register.ts.
const FRONT_TS = [
  "import type { EngineInterface } from 'claude-code'",
  'const run = async ($: EngineInterface, argv: string[]) => $.process.run(argv, { timeoutMs: 5_000 })',
  'const appOf = (cmd: string): string | undefined => {',
  String.raw`  const open = /\bopen\s+(?:-\w+\s+)*-a\s+(\S+)/.exec(cmd)`,
  '  return open ? open[1] : undefined',
  '}',
  'export const refuse = async ($: EngineInterface, cmd: string, kind: string, extra: unknown) => {',
  '  const app = appOf(cmd)',
  '  if (!app) return undefined',
  "  const front = (await run($, ['osascript', '-e', 'name of first process'])).stdout.split(' then ')[0]",
  "  const mode: 'input' | 'focus' = kind === 'focus' ? 'focus' : 'input'",
  "  const what = `${typeof extra === 'object' ? 'its window' : 'it'}${mode === 'input' ? ' to type into' : ''}`",
  "  const names = [app, front].join(' and ')",
  "  await $.ui.toast(`Blocked bringing ${names}${what ? ', ' : ''}${what} to the front, for ${mode}.`)",
  "  const flag = cmd.split(' ').find(w => ['-g', '--background'].some(f => w.startsWith(f)))",
  '  return { deny: `Blocked: ${app} would be brought to the front${flag ? ` (${flag})` : ""}.` }',
  '}',
  '',
].join('\n')
test('#1841: a string a message is only computed from passes; the words of the message are still held', () => {
  const judged = (from: string, to: string) => {
    const after = FRONT_TS.replace(from, to)
    if (after === FRONT_TS) throw new Error(`no ${from}`)
    return holdOf([], 'register.ts', FRONT_TS, after)
  }
  // A regular expression, a typeof tag, a value compared, a type's union, a command's words and
  // flags, what a string is split by, and a separator with no letter in it.
  expect(judged(String.raw`(\S+)/.exec`, String.raw`([^\s;&|]+)/.exec`)).toBe('passes')
  expect(judged("typeof extra === 'object'", "typeof extra === 'string'")).toBe('passes')
  expect(judged("mode === 'input'", "mode === 'focus'")).toBe('passes')
  expect(judged("mode: 'input' | 'focus'", "mode: 'input' | 'focus' | 'keys'")).toBe('passes')
  expect(judged("'-e', 'name of first process'", "'-ss', 'name of front process'")).toBe('passes')
  expect(judged(".split(' then ')", ".split(' and then ')")).toBe('passes')
  expect(judged("['-g', '--background']", "['-g', '-j', '--background']")).toBe('passes')
  expect(judged("what ? ', ' : ''", "what ? '; ' : ''")).toBe('passes')
  // The words: the toast's, a word it is joined with, what it says of the window, and the refusal's.
  expect(judged('Blocked bringing', 'Stopped bringing')).toBe('worded')
  expect(judged(".join(' and ')", ".join(' or ')")).toBe('worded')
  expect(judged("'its window'", "'the window'")).toBe('worded')
  expect(judged('would be brought to the front${', 'would come forward${')).toBe('worded')
})

// #1841 read a .tsx or .jsx hook file's messages whole, since read only for its words one edit #1823
// held would pass: manual steps' press handler rewritten on 2026-10-16 (call
// toolu_01BEGS4ToEC4pmthioGTcDwD), whose only changed strings were the button names it compares.
// #1864: Dan approved releasing that edit (2026-10-28), and replayed it is the only .tsx hold the
// words only reading releases, so a .tsx or .jsx file is read for its words too.
test('#1864: a compared button name a message is computed from passes in a .ts and a .tsx hook file alike', () => {
  const text = [
    "import type { EngineInterface } from 'claude-code'",
    'export const press = async ($: EngineInterface, element: string) => {',
    "  const field = element === 'manual-steps:copy' ? 'value' : element === 'manual-steps:copy-link' ? 'url' : undefined",
    '  if (field) await $.ui.toast(`Copied the ${field}.`)',
    '}',
    '',
  ].join('\n')
  const after = text.replace(
    "  const field = element === 'manual-steps:copy' ? 'value' : element === 'manual-steps:copy-link' ? 'url' : undefined",
    "  const p = element.split(':')[1]\n  const field = p === 'copy' ? 'value' : p === 'copy-link' ? 'url' : undefined",
  )
  expect(after).not.toBe(text)
  expect(messageWordingSame([], 'register.tsx', text, after)).toBe(true)
  expect(messageWordingSame([], 'register.ts', text, after)).toBe(true)
  expect(holdOf([], 'register.ts', text, after)).toBe('passes')
  // Its words are held either way.
  expect(messageWordingSame([], 'register.tsx', text, text.replace('Copied the', 'Copied your'))).toBe(false)
  expect(holdOf([], 'register.ts', text, text.replace('Copied the', 'Copied your'))).toBe('worded')
  expect(messageWordingSame([], 'register.tsx', text, text.replace("? 'value'", "? 'text'"))).toBe(false)
})

// #1864: six edits #1852's reading still held changed only a one word tag nobody reads. Each is cut
// down from the call that made it: keystroke guard's `kind: 'focus'` (toolu_01PSsWni5JtAvmeRzQzwo59F)
// and its `'away'` answer (toolu_014hZsXxkSZUsS545eiHAC2x), ask before saving's `told: 'prompt'`
// (toolu_01WwdETVTX7s3B57BfHSPt3j), scope modes' `'gh'` argv entry (toolu_01BuZTDUuBx6LfuAhxEqyiJj),
// job watcher's `?? 'x'` fallback handed to a command (toolu_019ieRrjrfJ3Dj5aae7RuZPz), and mod-kit's
// printf escape keys `'a'` and `'b'` (toolu_01M5GecamcwHEqhhHhDkH1bu, whose call also added the words
// "fed by what printf pipes into it" and so stays held for those).
const TAGS_TS = [
  "import type { EngineInterface } from 'claude-code'",
  "type Approval = { id: string; told: 'note' | 'prompt'; text: string }",
  'const run = async ($: EngineInterface, argv: string[]) => $.process.run(argv, { timeoutMs: 5_000 })',
  'const refusalFor = async ($: EngineInterface, agent: string, command: string) => {',
  "  const r = await $.process.run(['python3', 'reader.py', 'stdin-device-refusal', agent], { stdin: command, timeoutMs: 10_000 })",
  "  return r.exitCode === 0 ? { kind: 'refusal', text: r.stdout.trim() } : { kind: 'none' }",
  '}',
  "const holdWhileAway = async ($: EngineInterface, label: string, action: { kind: 'input' | 'focus' }): Promise<{ held: string } | 'home' | 'away'> => {",
  '  const r = await ($ as unknown as { hold: (x: unknown) => Promise<{ isHeld: boolean; isAway?: boolean; deny: string }> }).hold({ label, action })',
  '  if (r.isHeld) return { held: r.deny }',
  "  return 'home'",
  '}',
  'export const guard = async ($: EngineInterface, command: string, agent: string | undefined, typing: boolean, running: boolean) => {',
  "  const step = { argv: ['git', 'log', command], why: `Reading the log of ${command}` }",
  '  const first = await run($, step.argv)',
  '  if (first.exitCode !== 0) return { deny: `Could not read the log: ${first.stderr}` }',
  "  const read = await refusalFor($, agent ?? 'agent', command)",
  "  if (read.kind === 'refusal') return { deny: read.text }",
  "  const away = await holdWhileAway($, `Type into ${command}`, typing ? { kind: 'input' } : { kind: 'input' })",
  "  if (typeof away === 'object') return { deny: `Held while away: ${away.held}` }",
  "  const approval: Approval = { id: command, told: running ? 'note' : 'note', text: `Saving ${command}` }",
  '  $.ui.toast(`${approval.text} (${step.why})`)',
  "  if (running) return { deny: 'mutant' }",
  '  return undefined',
  '}',
  '',
].join('\n')
const PRINTF_TS = [
  "import type { EngineInterface } from 'claude-code'",
  String.raw`const ESCAPES = new Map([['n', '\n'], ['t', '\t']])`,
  'const printf = (format: string): string => {',
  "  let out = ''",
  '  for (let i = 0; i < format.length; i++) {',
  '    const c = format[i] as string',
  '    const d = format[i + 1]',
  String.raw`    if (c === '\\' && d !== undefined) {`,
  '      i++',
  "      out += ESCAPES.get(d) ?? `\\\\${d}`",
  '    } else out += c',
  '  }',
  '  return out',
  '}',
  'export const say = async ($: EngineInterface, format: string) => {',
  '  await $.ui.toast(`It would print ${printf(format)}`)',
  '}',
  '',
].join('\n')
const tagEdit = (text: string, from: string, to: string) => {
  if (text.split(from).length !== 2) throw new Error(`the fixture holds ${from} other than once`)
  return holdOf([], 'register.ts', text, text.replace(from, to))
}
test('#1864: an edit changing only a one word tag in a .ts hook file passes', () => {
  // A record's tag, as a property's value or one of a choice's answers.
  expect(tagEdit(TAGS_TS, "typing ? { kind: 'input' } : { kind: 'input' }", "typing ? { kind: 'input' } : { kind: 'focus' }")).toBe('passes')
  expect(tagEdit(TAGS_TS, "told: running ? 'note' : 'note'", "told: running ? 'note' : 'prompt'")).toBe('passes')
  // An argv entry, beside the variable it is run with.
  expect(tagEdit(TAGS_TS, "['git', 'log', command]", "['gh', 'log', command]")).toBe('passes')
  // A fallback handed to a function that only runs it as a command's word.
  expect(tagEdit(TAGS_TS, "agent ?? 'agent'", "agent ?? 'x'")).toBe('passes')
  // An answer the function's own signature names.
  expect(tagEdit(TAGS_TS, "  return 'home'", "  return r.isAway === true ? 'away' : 'home'")).toBe('passes')
  // A table's keys, each beside what it stands for.
  expect(tagEdit(PRINTF_TS, String.raw`['t', '\t']])`, String.raw`['t', '\t'], ['a', '\x07'], ['b', '\b']])`)).toBe('passes')
})

test('#1864: a one word message, and words beside a tag, are still held', () => {
  // A toast or a refusal saying one word.
  expect(tagEdit(TAGS_TS, '  return undefined', "  $.ui.toast('Saved')\n  return undefined")).toBe('worded')
  expect(tagEdit(TAGS_TS, '  return undefined', "  $.ui.toast('saved')\n  return undefined")).toBe('worded')
  expect(tagEdit(TAGS_TS, "{ deny: 'mutant' }", "{ deny: 'refused' }")).toBe('worded')
  expect(tagEdit(TAGS_TS, "{ deny: 'mutant' }", "{ decision: 'block', reason: 'refused' }")).toBe('worded')
  // The words of the record holding the argv, and an argv entry joined into a sentence.
  expect(tagEdit(TAGS_TS, 'Reading the log of', 'Reading the history of')).toBe('worded')
  expect(tagEdit(TAGS_TS, '(${step.why})', "(${step.why}, ${['ran', 'git'].join(' ')})")).toBe('worded')
  // A table of words picked by a key, a one word answer of a function typed only as a string, and a
  // word handed to a function that says it.
  const words = (from: string, to: string) =>
    tagEdit(
      [
        "import type { EngineInterface } from 'claude-code'",
        "const VERB = { add: 'added', drop: 'dropped' }",
        "const noun = (n: number): string => (n === 1 ? 'step' : 'steps')",
        "const LAST = ['done']",
        'const said = ($: EngineInterface, what: string) => $.ui.toast(`The card ${what}.`)',
        "export const tell = async ($: EngineInterface, k: 'add' | 'drop', n: number) => {",
        '  await $.ui.toast(`${VERB[k]} ${n} ${noun(n)}, ${LAST}`)',
        "  said($, 'moved')",
        '}',
        '',
      ].join('\n'),
      from,
      to,
    )
  expect(words("drop: 'dropped'", "drop: 'removed'")).toBe('worded')
  expect(words("? 'step' :", "? 'item' :")).toBe('worded')
  expect(words("said($, 'moved')", "said($, 'closed')")).toBe('worded')
  // A list of one word (lessons review at 324ee11).
  expect(words("['done']", "['finished']")).toBe('worded')
})

// #1841 (lessons review at 74900c0): a message's words given to a variable with = or added with +=
// are no value compared, so they are still held.
test('#1841: words assigned or appended before they are said are still held', () => {
  const text = [
    "import type { EngineInterface } from 'claude-code'",
    'export const warn = async ($: EngineInterface, n: number) => {',
    "  let msg = 'Blocked a command'",
    "  if (n > 1) msg += ' that would print a secret'",
    '  await $.ui.toast(`${msg}.`)',
    '}',
    '',
  ].join('\n')
  expect(holdOf([], 'register.ts', text, text.replace("'Blocked a command'", "'Stopped a command'"))).toBe('worded')
  expect(holdOf([], 'register.ts', text, text.replace("' that would print a secret'", "' that would show a secret'"))).toBe('worded')
  expect(holdOf([], 'register.ts', text, text.replace('n > 1', 'n > 3'))).toBe('passes')
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
// band, pane and card, a pane's size, and until #1756 a blocked card) or used inside JSX, and every
// name those use.
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
// followed too. The fixture is shaped after a guard: its card sentences are handed to its own
// drawCard, through a local holding a card's words and as literals at each call. Since #1756 it draws
// a boxed card of its own, since the words of a blocked card are copy and no longer followed.
const GUARD_TS = [
  "import { judge } from './judge.ts'",
  "const GUARD = 'Demo guard'",
  "const BLOCKED = 'This would change the record.'",
  "const unsureCard = (files: string[]) => ({ reason: `Could not tell ${files.join(', ')}.`, safeWay: 'Name the file.' })",
  'const drawCard = async ($: Engine, id: string, reason: string, safeWay: string) => {',
  '  try {',
  '    await $.modkit.card({ toolUseId: id, title: [{ text: GUARD }], lines: [[{ text: reason }], [{ text: safeWay }]] })',
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
  "  await $.modkit.card({ toolUseId: id, title: [{ text: GUARD }], lines: [[{ text: note }], [{ text: 'Ask Dan.' }]] })",
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
    "  await $.modkit.card({ toolUseId: id, title: [{ text: 'G' }], lines: [[{ text: note }], [{ text: 'Ask.' }]] })",
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

// #1341: a change that only touches comments in a mod hook file changes nothing it draws, so it is
// never asked about; anything that only looks like a comment (a string, JSX text) still counts.
const COMMENTED = [
  "import type { Register } from 'claude-code'",
  '',
  '// A mod hook file is judged as a screen file, and screen file edits are',
  '// judged by their before and after text,',
  '// so a comment changes nothing.',
  'export const register: Register = on => {',
  "  on('session.start', async ($, e, next) => {",
  "    const note = 'Held. // not a comment'",
  '    /* why the card says so */',
  "    await $.modkit.blocked({ toolUseId: 'x', guard: 'G', reason: note, safeWay: `Ask // Dan` })",
  '    return next(e) // hand on',
  '  })',
  '}',
  '',
].join('\n')

test('#1341: a change to comments alone is comment only, reflowed, added, removed or rewritten, in .ts', () => {
  const swap = (from: string, to: string) => {
    if (!COMMENTED.includes(from)) throw new Error(`the fixture holds no ${from}`)
    return COMMENTED.replace(from, to)
  }
  const only = (after: string) => commentOnlyChange(COMMENTED, after, false)
  // The reflow of #1341: three lines of comment made two, the words the same.
  expect(only(swap('// A mod hook file is judged as a screen file, and screen file edits are\n// judged by their before and after text,\n// so a comment changes nothing.', '// A mod hook file is judged as a screen file, and screen file edits are judged\n// by their before and after text, so a comment changes nothing.'))).toBe(true)
  expect(only(swap('/* why the card says so */', '/* why the card says so, in plain words */'))).toBe(true)
  expect(only(swap('// hand on', '// hand on to the next hook'))).toBe(true)
  expect(only(swap(' // hand on', ''))).toBe(true)
  expect(only(swap('    /* why the card says so */\n', ''))).toBe(true)
  expect(only(swap('export const register', '// One hook.\nexport const register'))).toBe(true)
  expect(only(`// A header.\n${COMMENTED}`)).toBe(true)
  // Nothing changed is no change at all.
  expect(only(COMMENTED)).toBe(false)
  // A comment beside a change that is not one.
  expect(only(swap('// hand on', '// hand on').replace("guard: 'G'", "guard: 'H'"))).toBe(false)
  expect(only(swap('/* why the card says so */', '/* why */').replace('return next(e)', 'return next(e) ?? 1'))).toBe(false)
  // Inside a string or a template literal it only looks like a comment, and is what is shown.
  expect(only(swap('// not a comment', '// not a comment at all'))).toBe(false)
  expect(only(swap('Ask // Dan', 'Ask // Dan first'))).toBe(false)
  // A comment made code, or code made a comment.
  expect(only(swap('/* why the card says so */', 'note.trim()'))).toBe(false)
  expect(only(swap('    return next(e) // hand on', '    // return next(e)'))).toBe(false)
  // A line break taken away where the language reads one (return, then a value on the next line).
  expect(commentOnlyChange('const f = () => {\n  return // nothing\n  1\n}\n', 'const f = () => {\n  return 1\n}\n', false)).toBe(false)
  // Where a template literal's own lines move, what it holds changes.
  expect(commentOnlyChange('const s = `a\n  b` // c\n', 'const s = `a\nb` // c, said again\n', false)).toBe(false)
  // A pragma in a comment changes how the JSX is built.
  expect(commentOnlyChange('/* @jsxImportSource preact */\nconst a = 1\n', '/* @jsxImportSource react */\nconst a = 1\n', true)).toBe(false)
  // Text the reader cannot follow is never comment only.
  expect(commentOnlyChange('/* open\nconst a = 1\n', '/* opened\nconst a = 1\n', false)).toBe(false)
})

test('#1341: in TSX, a JSX comment is a comment, and JSX text or a quoted prop spelled like one is not', () => {
  const tsx = [
    'export const View = () => (',
    '  <Box flexDirection="column">',
    '    {/* the heading */}',
    '    <Text bold>Steps // to do</Text>',
    '    <Text title="// note">Hello world</Text>',
    '  </Box>',
    ')',
    '',
  ].join('\n')
  const only = (from: string, to: string) => {
    if (!tsx.includes(from)) throw new Error(`the fixture holds no ${from}`)
    return commentOnlyChange(tsx, tsx.replace(from, to), true)
  }
  expect(only('{/* the heading */}', '{/* the heading, bold */}')).toBe(true)
  // A JSX comment on a line of its own, added or taken away.
  expect(only('    {/* the heading */}\n', '')).toBe(true)
  expect(only('    <Text bold>', '    {/* each step */}\n    <Text bold>')).toBe(true)
  // A JSX comment beside a look change.
  expect(only('{/* the heading */}\n    <Text bold>', '{/* the heading */}\n    <Text>')).toBe(false)
  // JSX text and a quoted prop that read like comments are what the screen shows.
  expect(only('Steps // to do', 'Steps // to do now')).toBe(false)
  expect(only('title="// note"', 'title="// notes"')).toBe(false)
  // A JSX comment put inside a line of text, between two spaces, leaves two spaces on screen.
  expect(only('Hello world', 'Hello {/* who */} world')).toBe(false)
  // One on a line of its own between two lines of text takes away the space the line break read as:
  // "Hello world" becomes "Helloworld". Its words may still change where it already stands.
  const text = 'const v = (\n  <Text>\n    Hello\n    world\n  </Text>\n)\n'
  const noted = text.replace('Hello\n', 'Hello\n    {/* who */}\n')
  expect(commentOnlyChange(text, noted, true)).toBe(false)
  expect(commentOnlyChange(noted, text, true)).toBe(false)
  expect(commentOnlyChange(noted, noted.replace('who', 'whom'), true)).toBe(true)
})

test('#1576: a mod hook file a shell write cannot be judged after, since it could not be read first, is said so with why', () => {
  const said = shellUnread('payload/mods/demo/hooks/register.tsx', 'EACCES')
  expect(said).toContain('payload/mods/demo/hooks/register.tsx')
  expect(said).toContain('before the command ran (EACCES)')
  expect(said).toContain('judged the whole file')
  expect(DASHES.test(said)).toBe(false)
})

// #1576: on 2026-10-23, building #1483, an Edit to scope modes' nobuild.ts (no build's refusal, which
// no build draws on its blocked card) was refused as a look change. The builder suspected words in a
// code comment quoting Dan's "picker answer". Reproduced against the real file, comments are not why:
// the edit turned `return inNotes(path) ? undefined : { what: ... }` into an if returning undefined
// and a return of the same `{ what: ... }`, and the guard read the returned conditional whole, so its
// `? undefined :` changed though the words drawn did not. A returned conditional is read as each value
// it may return, and a value drawn twice the same is one value. Since #1756 the fixture draws its
// words on a boxed card of its own, since a blocked card's words are copy and no longer followed.
const NOBUILD_TS = [
  "const inNotes = (p: string) => p.startsWith('/notes/')",
  "const base = (p: string) => p.split('/').pop() ?? p",
  'export const noBuildRefusal = (call: { tool: string; path: string; approved?: boolean }): { what: string } | undefined => {',
  "  if (call.tool === 'Edit') {",
  '    return inNotes(call.path) ? undefined : { what: `edit ${base(call.path)}` }',
  '  }',
  '  return undefined',
  '}',
  '',
].join('\n')
const NOBUILD_REGISTER = [
  "import { noBuildRefusal } from './nobuild.ts'",
  'export const register = (on: On) => {',
  "  on('tool.check', async ($: Engine, e: { tool: string; path: string }) => {",
  '    const r = noBuildRefusal(e)',
  "    if (r) await $.modkit.card({ toolUseId: 'x', title: [{ text: 'No build' }], lines: [[{ text: `No build is on, so it will not ${r.what}.` }], [{ text: 'Turn it off.' }]] })",
  '  })',
  '}',
  '',
].join('\n')
const NOBUILD_FILES = [
  { name: 'nobuild.ts', text: NOBUILD_TS },
  { name: 'register.ts', text: NOBUILD_REGISTER },
]
const RETURNED = '    return inNotes(call.path) ? undefined : { what: `edit ${base(call.path)}` }\n'
const SPLIT = [
  '    if (inNotes(call.path)) return undefined',
  '    // Dan\'s picker answer, "Let the approved lesson edit through" (#1483), shown on no screen.',
  '    if (call.approved === true) return undefined',
  '    return { what: `edit ${base(call.path)}` }',
  '',
].join('\n')

test('#1576: the #1483 edit, a returned conditional made into ifs returning the same words, draws nothing new', () => {
  const nobuild = (from: string, to: string, text = NOBUILD_TS) => {
    if (text.split(from).length !== 2) throw new Error(`the fixture holds ${from} other than once`)
    return drawsChange(NOBUILD_FILES, 'nobuild.ts', text, text.replace(from, to))
  }
  expect(nobuild(RETURNED, SPLIT)).toBe(false)
  // And back again, and the conditional turned round.
  expect(nobuild(SPLIT, RETURNED, NOBUILD_TS.replace(RETURNED, SPLIT))).toBe(false)
  expect(nobuild('inNotes(call.path) ? undefined : { what: `edit ${base(call.path)}` }', '!inNotes(call.path) ? { what: `edit ${base(call.path)}` } : undefined')).toBe(false)
  // The words drawn are still read, in either spelling, and so is a branch that draws something else.
  expect(nobuild('`edit ${', '`change ${')).toBe(true)
  expect(nobuild('`edit ${', '`change ${', NOBUILD_TS.replace(RETURNED, SPLIT))).toBe(true)
  expect(nobuild('? undefined :', "? { what: 'read notes' } :")).toBe(true)
  // Words in a comment, Dan's picker answer included, were never what held it.
  expect(nobuild("  if (call.tool === 'Edit') {\n", "  if (call.tool === 'Edit') {\n    // Dan's picker answer: show the colour on screen.\n")).toBe(false)
})

// #1756: on 2026-10-26 the design round guard held the #1751 builder's Edit to keystroke guard's
// keys.ts, a new refusal for a marker naming an app bundle, as a look change. Reproduced against the
// real files, no word in it was why: the refusal's words reached `$.modkit.blocked`, which #1296 read
// as drawing. A blocked card's look is mod-kit's own (blockedCard: its title, its dim safe way), and a
// caller hands it only words, shown as a tool result row. Those words are copy in a result, which the
// guard holds nowhere else (the recommended answer to #1756's open question), so they are not drawn.
// The fixture is shaped after keystroke guard: keys.ts decides the refusal, register.ts shows it, and
// also draws a card and a band row of its own, whose looks are still asked about.
const REFUSE_TS = [
  'export type Refusal = { reason: string; safeWay?: string }',
  'export const judge = (target: string | undefined, pids: number[]): Refusal | undefined => {',
  "  if (!target) return { reason: \"This doesn't say which app it types into.\", safeWay: 'Add TARGET_APP.' }",
  "  const app = target.split('/').pop() ?? target",
  "  if (pids.length === 0) return { reason: `${app} isn't running.`, safeWay: 'Open it first, then type.' }",
  '  return undefined',
  '}',
  "export const refusalText = (r: Refusal): string => `Blocked: ${r.reason}${r.safeWay ? ` ${r.safeWay}` : ''}`",
  '',
].join('\n')
const REFUSE_REGISTER = [
  "import { judge, refusalText } from './keys.ts'",
  "const GUARD = 'Keystroke guard'",
  "const BORDER = 'warning'",
  "const rows = (n: number) => [[{ text: `${n} held`, color: 'warning' }], { divider: true }]",
  'export const register = (on: On) => {',
  "  on('tool.call', async ($: Engine, e: { id: string; target?: string; pids: number[] }) => {",
  '    const r = judge(e.target, e.pids)',
  '    if (r) {',
  '      await $.modkit.blocked({ toolUseId: e.id, guard: GUARD, reason: r.reason, safeWay: r.safeWay })',
  '      return { deny: refusalText(r) }',
  '    }',
  "    await $.modkit.card({ toolUseId: e.id, border: BORDER, title: [{ text: 'Sent' }], lines: [] })",
  "    await $.modkit.bandRow({ mod: 'keys', id: 'held', slot: 'held', frame: { kind: 'box' }, lines: rows(e.pids.length) })",
  '  })',
  '}',
  '',
].join('\n')
const REFUSE_FILES = [
  { name: 'keys.ts', text: REFUSE_TS },
  { name: 'register.ts', text: REFUSE_REGISTER },
]
const refuseDraws = (name: string, from: string, to: string): boolean => {
  const was = REFUSE_FILES.find(f => f.name === name)?.text ?? ''
  if (was.split(from).length !== 2) throw new Error(`${name} holds ${from} other than once`)
  return drawsChange(REFUSE_FILES, name, was, was.replace(from, to))
}

test('#1756: a refusal handed to a blocked card is copy, not drawing: its words, a new refusal, and the guard name pass', () => {
  expect(refuseDraws('keys.ts', "`${app} isn't running.`", "`${app} is not running.`")).toBe(false)
  expect(refuseDraws('keys.ts', "'Open it first, then type.'", "'Start it, then type.'")).toBe(false)
  // The #1751 builder's held Edit, as its transcript holds it: a new refusal for a bundle.
  expect(
    refuseDraws(
      'keys.ts',
      "  const app = target.split('/').pop() ?? target\n",
      "  const app = target.split('/').pop() ?? target\n  // A bundle is a folder, never a running program.\n  const bundle = /^(.*\\/([^/]+)\\.app)\\/?$/.exec(target)\n  if (bundle) {\n    return { reason: `TARGET_APP names the ${bundle[2]} app bundle, not the program inside it.`, safeWay: `Name the program, usually ${bundle[1]}/Contents/MacOS/${bundle[2]}.` }\n  }\n",
    ),
  ).toBe(false)
  expect(refuseDraws('register.ts', "GUARD = 'Keystroke guard'", "GUARD = 'Key guard'")).toBe(false)
})

test('#1756 controls: in the same mod, a colour, a frame, a border and a row it draws itself are still asked about', () => {
  expect(refuseDraws('register.ts', "BORDER = 'warning'", "BORDER = 'error'")).toBe(true)
  expect(refuseDraws('register.ts', "frame: { kind: 'box' }", "frame: { kind: 'left-rule' }")).toBe(true)
  expect(refuseDraws('register.ts', "held`, color: 'warning' }", "held`, color: 'error' }")).toBe(true)
  expect(refuseDraws('register.ts', ", { divider: true }]", ']')).toBe(true)
})

// #1756: on 2026-10-26 the design round guard held the #1747 builder's Edit to its own register.ts,
// which gave a loop braces and a `continue` in one Edit and was to close the brace in the next.
// Reproduced against the real file, no word in it was why: the Edit left a brace open, so the reader
// could not follow the file and held it whole. A text whose brackets do not balance is no TypeScript
// at all, mid way through a change made in more than one edit (bracketsOpen); register.ts judges the
// edit that closes it against the file before the first (rules.ts drawsChange, unchanged).
test('#1756: bracketsOpen says a .ts text is read but for a bracket left open or shut wrongly, and nothing else', () => {
  const t = "export const f = (xs: string[]) => {\n  for (const x of xs)\n    if (x) return x\n  return ''\n}\n"
  expect(bracketsOpen(t)).toBe(false)
  expect(bracketsOpen(t.replace('for (const x of xs)\n', 'for (const x of xs) {\n    if (!x) continue\n'))).toBe(true)
  expect(bracketsOpen(t.replace('(xs: string[])', '(xs: string[]'))).toBe(true)
  expect(bracketsOpen(t.replace('(xs: string[])', '(xs: string[]))'))).toBe(true)
  expect(bracketsOpen(t.replace('(xs: string[])', '(xs: string[)'))).toBe(true)
  // Brackets inside strings, template literals, regular expressions and comments are not counted.
  expect(bracketsOpen("const a = '{'\nconst b = `(${a}`\nconst c = /\\[/\n// }\n/* ) */\n")).toBe(false)
  // A text the reader cannot follow for another reason is not one of these, and is held as before:
  // an unclosed string, and a brace shut that nothing opened, which the reader stops at.
  expect(bracketsOpen("const a = 'open\n")).toBe(false)
  expect(bracketsOpen(t.replace("  return ''\n}", "  return ''\n}\n}"))).toBe(false)
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

// #1524: where a settled design is committed, inside its checkout, and the skill's check run on it.
test('a settled design is under docs/design at the top of its checkout, in any case, and nowhere else', () => {
  for (const rel of ['docs/design/slack-channel-picker.html', 'Docs/Design/x.html', 'docs/design/rules/rail-foot.html'])
    expect({ rel, record: isDesignRecord(rel) }).toEqual({ rel, record: true })
  // Only an HTML page, the one kind make-settled.py writes (lessons review): a sealed stylesheet or component there is no record.
  for (const rel of ['docs/design/x.css', 'docs/design/Picker.tsx', 'docs/design/x.vue', 'docs/design/x.html.tsx', 'docs/design/', 'docs/designs/x.html', 'src/docs/design/x.html', 'app/settled.html', 'docs/design/../../app/x.html', '/w/slate/docs/design/x.html'])
    expect({ rel, record: isDesignRecord(rel) }).toEqual({ rel, record: false })
  expect(sealCheck('/Users/dan')).toEqual(['python3', '-I', '/Users/dan/.claude/skills/design-rounds/design_file.py', '--sealed'])
})

// #1747: only the spool helper at its installed path, and only its note, writes none of what it is handed.
test('spoolNote is the installed spool helper running note, and nothing else', () => {
  const HELPER = '/Users/dan/.claude/hooks/lib/issue-spool.sh'
  const args = (...w: string[]) => w.map(word => ({ word }))
  expect(spoolNote({ path: HELPER, args: args('note', '.', 'app/page.tsx', 'a builder') }, '/Users/dan')).toBe(true)
  expect(spoolNote({ path: HELPER, args: args('append', 'app/page.tsx', '{}') }, '/Users/dan')).toBe(false)
  expect(spoolNote({ path: '/w/slate/scripts/issue-spool.sh', args: args('note', '.', 'x') }, '/Users/dan')).toBe(false)
  expect(spoolNote({ args: args('note', '.', 'x') }, '/Users/dan')).toBe(false)
  expect(spoolNote({ path: HELPER, args: args('note', '.', 'x') }, '/Users/other')).toBe(false)
  expect(spoolNote({ path: '/.claude/hooks/lib/issue-spool.sh', args: args('note', '.', 'x') }, '')).toBe(false)
  expect(spoolNote({ path: HELPER, args: [] }, '/Users/dan')).toBe(false)
})

// #1904: a builder's starting branch, worktree-agent-<id>, names no issue (#1306), so Dan was asked
// about "branch worktree-agent-a09a06788b6ba53ab in claude-config" (2026-10-29, for #1859) rather than
// the issue he knows. The skip question may name the issue the builder works on, and he reads that
// issue, said to hold for this builder only; where his answer is kept does not change, so it reaches
// no other worktree and not the main checkout (#1306, #1740).
test('#1904: the skip question names the issue a builder works on in place of its throwaway branch, kept where it was', () => {
  const at = { main: '/Users/dan/Apps/slate', repo: 'slate', session: 's1', isDefault: false, issues: [] as number[] }
  const wt = '/Users/dan/Apps/slate/.claude/worktrees/agent-a09a06788b6ba53ab'
  const [agent] = subjectsOf({ ...at, branch: 'worktree-agent-a09a06788b6ba53ab', root: wt })
  if (!agent) throw new Error('no subject')
  expect(agent.label).toBe('branch worktree-agent-a09a06788b6ba53ab in slate')
  const named = namedByIssue(agent, 1859)
  expect(named.label).toBe('issue #1859 in slate (this builder only)')
  // Only the label changes: the key and the worktree its skip is also kept under stay the branch's.
  expect({ ...named, label: agent.label }).toEqual(agent)
  expect(named.key).toBe('record:/Users/dan/Apps/slate|branch:worktree-agent-a09a06788b6ba53ab')
  const q = skipQuestion('The heading on the home page gets more space above it.', ['app/page.tsx'], [named])
  expect(q).toContain('This is for issue #1859 in slate (this builder only); the file is app/page.tsx.')
  expect(q).not.toContain('worktree-agent')
  expect(skipOptions([named])[0]?.description).toContain('issue #1859 in slate (this builder only)')
  // With no issue named, the branch as before.
  expect(namedByIssue(agent, undefined)).toEqual(agent)
  // Only a builder's starting branch is renamed: an issue's own branch, an ordinary branch, the
  // default branch, and a branch of that name in the main checkout keep what they are.
  const others = [
    ...subjectsOf({ ...at, branch: '978-design-round-guard', issues: [978], root: wt }),
    ...subjectsOf({ ...at, branch: 'polish-header', root: wt }),
    ...subjectsOf({ ...at, branch: 'main', isDefault: true, root: wt }),
    ...subjectsOf({ ...at, branch: 'worktree-agent-a09a06788b6ba53ab', root: at.main }),
    ...subjectsOf({ ...at, branch: 'worktree-agent-a09a06788b6ba53ab' }),
  ]
  expect(others.length).toBe(5)
  for (const s of others) expect(namedByIssue(s, 1859)).toEqual(s)
})

test('#1904: an issue the skip question names that is not a whole positive number is refused by name', () => {
  for (const bad of ['1859', 0, -3, 2.5, null, true, '#1859']) {
    const why = skipIssueProblem(bad)
    expect([bad, why?.includes('is not an issue number')]).toEqual([bad, true])
  }
  expect(skipIssueProblem(undefined)).toBe(undefined)
  expect(skipIssueProblem(1859)).toBe(undefined)
})

// #1911: since #1859 the skip question can be about a message's words alone, so the answers Dan picks
// from name wording beside the look, where they named only the look.
test("#1911: the skip question's answers name wording beside the look", () => {
  expect(NOT_LOOK).toBe('Not a look or wording change')
  const [yes, no, third] = skipOptions([{ key: 'k', label: 'issue #978 in slate' }])
  expect(yes?.description).toContain('change the look or wording')
  expect(no?.description).toContain('changes the look or wording')
  expect(third?.label).toBe(NOT_LOOK)
  // What it says it means, and the reason kept with it, name both too (lessons review of 83729c4):
  // "nothing on screen changes" read false for a hold that was only ever about a message's words.
  expect(third?.description).toContain('Neither the look nor any wording changes')
  expect(notLookWhy(['hooks/rules.ts'])).toContain('changes neither the look nor any wording')
})

// #1911: modHookTsShows had become a yes or no wrapper over modHookTsHold that only tests called; its
// tests moved to modHookTsHold (holdOf above), and the wrapper is gone.
test('#1911: the guard keeps one reading of a .ts hook change, modHookTsHold, with no wrapper beside it', () => {
  expect(Object.keys(allRules).includes('modHookTsShows')).toBe(false)
  expect(typeof allRules.modHookTsHold).toBe('function')
})

// #2038: moving a hook that toasts into a named top level const and registering it as
// `on('tool.call', { tool: TOOL_NAMES }, saveCall).catch(...)` (mods/ask-before-saving, #2026) was
// held as a wording change naming "tool.call". The hook's `next`, which a toast's words come from,
// was followed to its call in the catch, `saveCall($, e, next)`, and the catch's own `next` from there
// to the words handed to `on`, as though the callback took its values from them; it takes them from
// the engine through `on`, as a callback handed to `on` itself does. Cut down from
// mods/ask-before-saving's register.ts before and after PR #2041.
const SAVE_HEAD = [
  "import type { EngineInterface, Register } from 'claude-code'",
  "const TOOL_NAMES = ['Write', 'Edit']",
  'const cannotCheck = (err: unknown) => `Could not check this call: ${String(err)}`',
  'const againOrHeld = async <R>(run: () => R | Promise<R>, held: () => R): Promise<R> => {',
  '  try {',
  '    return await run()',
  '  } catch {',
  '    return held()',
  '  }',
  '}',
]
const SAVE_BEFORE = [
  ...SAVE_HEAD,
  'export const register: Register = on => {',
  "  on('tool.call', { tool: TOOL_NAMES }, async ($: EngineInterface, e: { input: { file_path?: string } }, next: (e: object) => unknown) => {",
  "    if (e.input.file_path?.endsWith('.md')) {",
  '      $.ui.toast(`Not saved to ${e.input.file_path}: it reads as a lasting memory`, { timeoutMs: 10_000 })',
  "      return { deny: 'Not saved: ask Dan first.' }",
  '    }',
  '    const r = await next(e)',
  '    if (r.denied) $.ui.toast(`Held beneath: ${r.reason}`)',
  '    return r',
  '  }).catch(($, e, next) => ({ deny: cannotCheck(next.error) }))',
  '}',
  '',
].join('\n')
const SAVE_AFTER = [
  ...SAVE_HEAD,
  'const saveCall = async ($: EngineInterface, e: { input: { file_path?: string } }, next: (e: object) => unknown) => {',
  "  if (e.input.file_path?.endsWith('.md')) {",
  '    $.ui.toast(`Not saved to ${e.input.file_path}: it reads as a lasting memory`, { timeoutMs: 10_000 })',
  "    return { deny: 'Not saved: ask Dan first.' }",
  '  }',
  '  const r = await next(e)',
  '  if (r.denied) $.ui.toast(`Held beneath: ${r.reason}`)',
  '  return r',
  '}',
  'export const register: Register = on => {',
  "  on('tool.call', { tool: TOOL_NAMES }, saveCall).catch(($, e, next) =>",
  '    next.called ? next(e) : againOrHeld(() => saveCall($, e, next), () => ({ deny: cannotCheck(next.error) })),',
  '  )',
  '}',
  '',
].join('\n')
test('#2038: a hook moved into a named const and registered with on(...).catch passes, its event name no message words; a real wording change there is still held', () => {
  const edited = (text: string, from: string, to: string) => {
    const after = text.replace(from, to)
    if (after === text) throw new Error(`no ${from}`)
    return after
  }
  // The logic only move, as #2026 made it, and the event name and filter beside the reference changed after it.
  expect(modHookTsHold([], 'register.ts', SAVE_BEFORE, SAVE_AFTER)).toBe(undefined)
  expect(holdOf([], 'register.ts', SAVE_AFTER, edited(SAVE_AFTER, "on('tool.call'", "on('tool.check'"))).toBe('passes')
  expect(holdOf([], 'register.ts', SAVE_AFTER, edited(SAVE_AFTER, '{ tool: TOOL_NAMES }, saveCall', "{ tool: 'Write' }, saveCall"))).toBe('passes')
  // Controls: the toast's words, the refusal's words, and the words the catch's refusal is made from
  // are each still held, in the moved hook and in the catch beside it.
  const toast = modHookTsHold([], 'register.ts', SAVE_BEFORE, edited(SAVE_AFTER, 'it reads as a lasting memory', 'it looks like a lasting memory'))
  expect(toast && 'worded' in toast ? toast.worded : '').toContain('it looks like a lasting memory')
  expect(holdOf([], 'register.ts', SAVE_AFTER, edited(SAVE_AFTER, "'Not saved: ask Dan first.'", "'Not saved: ask Dan.'"))).toBe('worded')
  expect(holdOf([], 'register.ts', SAVE_AFTER, edited(SAVE_AFTER, 'Could not check this call', 'Could not judge this call'))).toBe('worded')
  // A callback on what a function of the mod returns still takes its values from the words handed
  // to that function, so those words, said in a toast, are held as before.
  const listed = [
    "import type { EngineInterface, Register } from 'claude-code'",
    'const lines = (...xs: string[]) => xs.map(x => x.trim())',
    'export const register: Register = on => {',
    "  on('session.start', async ($: EngineInterface) => {",
    "    lines('Saved the note.', 'Kept the job.').forEach(l => $.ui.toast(l))",
    '  })',
    '}',
    '',
  ].join('\n')
  expect(holdOf([], 'register.ts', listed, edited(listed, 'Saved the note.', 'Stored the note.'))).toBe('worded')
})
