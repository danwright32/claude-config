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
  modHookTsChange,
  shellOutcome,
  shellUnchecked,
  card,
  unsureCard,
  unreadableCard,
  messageWords,
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
  argumentUnreached,
  handedToUnknown,
  withoutOwnCalls,
  readInFile,
  type OwnCallIo,
  ownBudget,
  calledWith,
  ownDefinitions,
  type RunCommand,
  argvStart,
  argvIndex,
  inScriptTemp,
  inScratchpad,
  inSessionNotes,
  namesScratchpad,
  joinedOnly,
  addedOntoFolder,
  shellBraces,
  afterVariable,
  shellVarPath,
  spelledThrough,
  literalValue,
  tempRoots,
  keptInTemp,
  scriptHidesWrites,
  gitMove,
  movedFiles,
  pickedFiles,
  moveUnread,
  defaultBranchRef,
  beyondDefault,
  onDefaultSaid,
  ROUND_FILES,
  checked,
  unsure,
  unreadable,
  commentOnlyChange,
  logicOnlyChange,
  autoPassWhy,
  shellUnread,
  bracketsOpen,
  namedByIssue,
  skipIssueProblem,
  notLookWhy,
  passesByShape,
  caughtCheck,
  caughtCall,
  cannotCheck,
  removalFilledIn,
  scriptLanguage,
  asProgram,
  mentionedModHookFiles,
  namesInPieces,
  PIECE_CHARS,
  pacer,
  leavesGitAlone,
  pathRestore,
  indexSource,
  wholeRestoreSource,
  plainLine,
  runsAfter,
  holdsAsFile,
  restoredSaid,
  scriptOf,
  scriptPath,
  neverSetVariable,
  scriptNeverSet,
  heredocFile,
  importedFiles,
  scriptsRunIn,
  type ScriptIo,
  MODULES_MAX,
} from '../hooks/rules.ts'
import { commandWrites, pipelineIn } from './mod-kit/hooks/writes.ts'
import { pipeline } from './mod-kit/hooks/commands.ts'
import { tempWord } from '../hooks/mod-kit/scriptvars.ts'
import * as allRules from '../hooks/rules.ts'
import { HELD_2141_AFTER, HELD_2141_BEFORE } from './held-2141-fixture.ts'

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

// #3602: a word whose every `$` and backtick the shell hands on as written (mod-kit's `unexpanded`)
// holds no command substitution, so its `$(` is text. Asked so, it is read as the characters it
// spells, its groups as each name they can spell, as any other word is. The first words are the
// ones four of this repository's suites hand their helpers, as mod-kit gives them.
test('#3602: a word the shell hands on as written is read as the name it spells, its $( ) as no command output', () => {
  for (const w of [
    'gh issue create --repo danwright-test/public-notes --title "$(pwd | tr a-z A-Z)" --body x',
    'bash -c "echo \\$(sort ok.sh | bash)"',
    'perl -ne print "$(printf \'bash post.sh|\')"',
    'perl -ne print "$NOPE_2912/$(printf \'bash post.sh|\')"',
    'eval "$(supabase status -o env | grep API_URL)"',
    '`git ls-files src`',
    'src/$(cat name)',
  ]) {
    expect([w, patternMayBeLook(w)]).toEqual([w, 'unread'])
    expect([w, patternMayBeLook(w, true)]).toEqual([w, 'not'])
  }
  // One that spells a screen file is still one, whichever way its group is read.
  for (const w of ['x$(date).css', 'app/$(a|b).css', 'app/(page|site)$.css', 'cat $(a | b) > app/page.tsx', '$(ls)/[t]okens.json'])
    expect([w, patternMayBeLook(w, true)]).toEqual([w, 'look'])
  // And what no rule reads is read by none here either.
  for (const w of ['(#i)$x.css', `${'f(a|b|c)'.repeat(6)}$.md`]) expect([w, patternMayBeLook(w, true)]).toEqual([w, 'unread'])
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

// #3088: `$((...))` is arithmetic, so its two parentheses open no command substitution: a name it
// fills in is a value the shell works out from numbers and variables, read as a variable's value is.
// A command substitution inside one, or beside one, is still a command's output.
test('#3088: arithmetic in a name is a value, never a command output, unless a substitution sits in it', () => {
  for (const w of [String.raw`a|\$((0-9)),[0-9]{3}|b`, 'x$((N+1)).css', 'app/$((1+1)).tsx', 'app/$((N/2)).tsx', '$((a)+(b)).md'])
    expect([w, nameFromOutput(w), nameFromVariable(w)]).toEqual([w, false, true])
  for (const w of ['x$(( $(cat n) + 1 )).css', 'x$((1+1))$(date).css', 'app/$((`cat n`)).tsx', 'x$((1', '$(git ls-files app)', 'app/$(cat name)'])
    expect([w, nameFromOutput(w)]).toEqual([w, true])
  // In the folder alone it fills in no name.
  expect(nameFromVariable('$((N))/x.css')).toBe(false)
  expect(nameFromOutput('$((N))/x.css')).toBe(false)
  for (const [w, filled] of [['app/x$((N))', 'variable'], ['app/$(( $(cat n) ))', 'output'], ['app/x', null]] as const)
    expect([w, removalFilledIn(w)]).toEqual([w, filled])
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

test('#2991: a python program binds a variable to one of its arguments only by a plain or tuple assignment from sys.argv', () => {
  expect(argvStart(['python3', '-', '$CH', '$1', '<<PY'])).toBe(1)
  expect(argvStart(['python3', '-I', '-', '$CH'])).toBe(2)
  expect(argvStart(['python3', '-c', 'x', '$CH'])).toBe(2)
  expect(argvStart(['python3', 'gen.py', '$CH'])).toBeUndefined()
  expect(argvStart(['node', '-', '$CH'])).toBeUndefined()
  expect(argvIndex('import sys\nch, heading = sys.argv[1], sys.argv[2]\nopen(ch + "/a.html")\n', 'ch')).toBe(1)
  expect(argvIndex('import sys\nmc = sys.argv[2]\n', 'mc')).toBe(2)
  for (const program of [
    'ch = "."\n',
    'ch = sys.argv[1]\nch = "."\n',
    'ch = sys.argv[1]\nch += "/x"\n',
    'ch = sys.argv[1]\nch: str = "."\n',
    'ch = sys.argv[0]\n',
    'ch = sys.argv[1]\nsys.argv[1] = "."\n',
    'ch = sys.argv[1]\nsys.argv.insert(1, ".")\n',
    'for ch in ["."]:\n  pass\n',
    'ch = sys.argv[1]\nwith open("x") as ch:\n  pass\n',
    'ch, h = sys.argv[1]\n',
    'open(ch + "/a.html")\n',
  ]) expect([program, argvIndex(program, 'ch')]).toEqual([program, undefined])
  const program = 'import sys\nch = sys.argv[1]\nopen(ch + "/app/index.html", "w")\n'
  const script = 'T="$(mktemp -d)"\nCH="$T/chain"\n'
  expect(inScriptTemp(program, '/app/index.html', program, ['python3', '-', '$CH'], script)).toBe(true)
  expect(inScriptTemp(program, '/app/index.html', program, ['python3', '-', '$OTHER'], script)).toBe(false)
  expect(inScriptTemp(program, '/app/index.html', program, ['python3', '-', '$CH'], 'CH="$(pwd)"\n')).toBe(false)
  const both = `${program}open("/app/index.html")\n`
  expect(inScriptTemp(both, '/app/index.html', both, ['python3', '-', '$CH'], script)).toBe(false)
  const climbs = 'import sys\nch = sys.argv[1]\nopen(ch + "/../../w/slate/app/index.html", "w")\n'
  expect(inScriptTemp(climbs, '/../../w/slate/app/index.html', climbs, ['python3', '-', '$CH'], script)).toBe(false)
  const attribute = 'import sys\nch = sys.argv[1]\nopen(self.ch + "/app/index.html", "w")\n'
  expect(inScriptTemp(attribute, '/app/index.html', attribute, ['python3', '-', '$CH'], script)).toBe(false)
  const fstring = 'import sys\nch = sys.argv[1]\nopen(f"{ch}/app/index.html", "w")\n'
  expect(inScriptTemp(fstring, '/app/index.html', fstring, ['python3', '-', '$CH'], script)).toBe(true)
  const plainBraces = 'import sys\nch = sys.argv[1]\nopen("{ch}/app/index.html", "w")\n'
  expect(inScriptTemp(plainBraces, '/app/index.html', plainBraces, ['python3', '-', '$CH'], script)).toBe(false)
  const braces = 'open("${CH}/app/index.html", "w")\n'
  expect(inScriptTemp(braces, '/app/index.html', braces, ['python3', '-', '$CH'], script)).toBe(false)
  // #3022: the temporary folder's variable must start the path written; one added after another
  // value (`root + ch + ...`, `f"{root}{ch}..."`, `f"/w/slate{ch}..."`) lands under that value.
  for (const line of [
    'open(root + ch + "/app/index.html", "w")',
    'open(root+ch+"/app/index.html", "w")',
    'open("/w/slate" + ch + "/app/index.html", "w")',
    'open(f"/w/slate{ch}/app/index.html", "w")',
    'open(f"{root}{ch}/app/index.html", "w")',
    'open(os.path.join(root, ch + "/app/index.html"), "w")',
    'p = root + \\\n  ch + "/app/index.html"',
  ]) {
    const text = `import sys\nch = sys.argv[1]\nroot = "/w/slate"\n${line}\n`
    expect([line, inScriptTemp(text, '/app/index.html', text, ['python3', '-', '$CH'], script)]).toEqual([line, false])
  }
  for (const line of ['p = ch + "/app/index.html"', 'open( ch + "/app/index.html", "w")', 'return ch + "/app/index.html"', 'Path(f"{ch}/app/index.html").write_text(x)']) {
    const text = `import sys\nch = sys.argv[1]\n${line}\n`
    expect([line, inScriptTemp(text, '/app/index.html', text, ['python3', '-', '$CH'], script)]).toEqual([line, true])
  }
})

test("the guard's own record in the plugin store is recognised, and nothing else there is", () => {
  expect(isOwnRecord(`${'/Users'}/dan/.claude/plugins/store/design-round-guard_inline-ab12.json`)).toBe(true)
  expect(isOwnRecord(`${'/Users'}/dan/.claude/plugins/store/simpler_inline-dc77.json`)).toBe(false)
  expect(isOwnRecord(`${'/Users'}/dan/Apps/x/design-round-guard.json`)).toBe(false)
  expect(isOwnRecord('$D/design-round-guard_inline-x.json')).toBe(true)
})

test('a branch naming an issue is keyed by the issue, one naming none by the branch, the default branch by this session only', () => {
  // Where the checkout stands, as mod-kit's $.modkit.branch reads it (its own tests pin that reading).
  const at = { main: `${'/Users'}/dan/Apps/slate`, repo: 'slate', session: 's1', isDefault: false }
  expect(subjectsOf({ ...at, branch: '978-design-round-guard', issues: [978] })).toEqual([{ key: `record:${'/Users'}/dan/Apps/slate|issue:978`, label: 'issue #978 in slate' }])
  expect(subjectsOf({ ...at, branch: '41-52-both', issues: [41, 52] }).map(s => s.key)).toEqual([`record:${'/Users'}/dan/Apps/slate|issue:41`, `record:${'/Users'}/dan/Apps/slate|issue:52`])
  expect(subjectsOf({ ...at, branch: 'polish-header', issues: [] })).toEqual([{ key: `record:${'/Users'}/dan/Apps/slate|branch:polish-header`, label: 'branch polish-header in slate' }])
  // A no on the default branch would otherwise cover every later issue built there, even one it names.
  expect(subjectsOf({ ...at, branch: 'main', isDefault: true, issues: [] })).toEqual([{ key: `record:${'/Users'}/dan/Apps/slate|branch:main|session:s1`, label: 'main in slate, for this session' }])
  expect(subjectsOf({ ...at, branch: 'release-2026', isDefault: true, issues: [2026] })[0]?.key).toBe(`record:${'/Users'}/dan/Apps/slate|branch:release-2026|session:s1`)
  // An issue named on the settled question, whatever the branch.
  expect(subjectsOf({ main: at.main, repo: 'slate', session: 's1', issue: 12 })).toEqual([{ key: `record:${'/Users'}/dan/Apps/slate|issue:12`, label: 'issue #12 in slate' }])
})

test('#2792: the session notes folder is known by the home folder, any session of any project, and nothing shaped like it elsewhere', () => {
  const home = `${'/Users'}/dan`
  const notes = `${home}/.claude/state/session-notes`
  expect(inSessionNotes(`${notes}/-w-slate/s1/review/slate-copy`, home)).toBe(true)
  expect(inSessionNotes(`${notes}/-w-slate/s1/review/slate-copy/app/page.tsx`, home)).toBe(true)
  // Another session's, and another project's: a copy an earlier session left is a throwaway too.
  expect(inSessionNotes(`${notes}/-w-other/s2/handoff.md`, home)).toBe(true)
  expect(inSessionNotes(`${notes}/-w-slate`, `${home}/`)).toBe(true)
  // The notes folder itself, a name that only starts like it, and a climb out are not in it.
  expect(inSessionNotes(notes, home)).toBe(false)
  expect(inSessionNotes(`${notes}/`, home)).toBe(false)
  expect(inSessionNotes(`${notes}-old/-w-slate/s1/app/page.tsx`, home)).toBe(false)
  expect(inSessionNotes(`${notes}/-w-slate/s1/../../../../../../../w/slate/app/page.tsx`, home)).toBe(false)
  // A folder shaped like it anywhere else, a checkout included, another home's, and no home at all.
  expect(inSessionNotes('/w/slate/.claude/state/session-notes/-w-slate/s1/app/page.tsx', home)).toBe(false)
  expect(inSessionNotes(`${'/Users'}/eve/.claude/state/session-notes/-w-slate/s1/app/page.tsx`, home)).toBe(false)
  expect(inSessionNotes('/.claude/state/session-notes/-w-slate/s1/app/page.tsx', '')).toBe(false)
  expect(inSessionNotes('dan/.claude/state/session-notes/-w-slate/s1/app/page.tsx', 'dan')).toBe(false)
})

// #3279: a script kept in a temporary folder is one a session wrote to run once. Known by where its
// path lands: /tmp and /var/folders in both of macOS's spellings, and Claude Code's own temp folder.
test('#3279: a script file is kept in a temporary folder by where its path lands, never by a folder merely named like one', () => {
  const tmp = tempRoots(undefined)
  for (const p of ['/tmp/fix.py', '/private/tmp/claude-501/-w-slate/s1/scratchpad/3279/gen.mjs', '/var/folders/ab/T/fix.py', '/private/var/folders/ab/T/x/fix.py', '/w/slate/../../tmp/fix.py'])
    expect({ p, temp: keptInTemp(p, tmp) }).toEqual({ p, temp: true })
  for (const p of ['/w/slate/scripts/gen.py', '/w/slate/tmp/gen.py', '/tmpx/gen.py', '/tmp/../w/slate/scripts/gen.py', `${'/Users'}/dan/.claude/state/session-notes/-w-slate/s1/3279/gen.py`, `${'/Users'}/dan/Temp Dir/gen.py`])
    expect({ p, temp: keptInTemp(p, tmp) }).toEqual({ p, temp: false })
  // Claude Code's temp folder, wherever CLAUDE_CODE_TMPDIR puts it.
  expect(keptInTemp(`${'/Users'}/dan/Temp Dir/claude-501/x/s1/scratchpad/gen.py`, tempRoots(`${'/Users'}/dan/Temp Dir`))).toBe(true)
  expect(scriptHidesWrites('/tmp/fix.py', 'app/globals.css')).toContain('/tmp/fix.py is kept in a temporary folder, its own code does not name every file it writes, and it names app/globals.css by a relative name')
})

// #3279: what each git command that moves committed work brings into the working tree, as the
// question to ask git, read from mod-kit's reading of its words alone.
test('#3279: gitMove reads what to ask git for each move, nothing for a move that brings nothing in, and why for one its words cannot say', () => {
  const g = (line: string) => {
    const [sub, ...args] = line.split(' ')
    return gitMove({ sub, args })
  }
  const ask = (line: string) => {
    const m = g(line)
    return m && 'ask' in m ? m.ask : m
  }
  expect(ask('merge origin/main')).toEqual({ ask: 'merge', commits: ['origin/main'] })
  expect(ask('merge --no-ff -m msg a b')).toEqual({ ask: 'merge', commits: ['a', 'b'] })
  expect(ask('merge --ff-only')).toEqual({ ask: 'merge', commits: ['@{upstream}'] })
  expect(ask('merge -s ours --strategy-option=theirs FETCH_HEAD')).toEqual({ ask: 'merge', commits: ['FETCH_HEAD'] })
  expect(ask('rebase origin/main')).toEqual({ ask: 'merge', commits: ['origin/main'] })
  expect(ask('rebase')).toEqual({ ask: 'merge', commits: ['@{upstream}'] })
  expect(ask('cherry-pick -x -m 1 abc1234 def5678')).toEqual({ ask: 'picks', revs: ['abc1234', 'def5678'] })
  expect(ask('cherry-pick main..topic')).toEqual({ ask: 'picks', revs: ['main..topic'] })
  expect(ask('revert --no-edit HEAD~2')).toEqual({ ask: 'picks', revs: ['HEAD~2'], revert: true })
  expect(ask('switch topic')).toEqual({ ask: 'name', name: 'topic', orPath: false })
  expect(ask('switch -')).toEqual({ ask: 'name', name: '@{-1}', orPath: false })
  expect(ask('switch -c new origin/main')).toEqual({ ask: 'tree', commit: 'origin/main' })
  expect(ask('checkout topic')).toEqual({ ask: 'name', name: 'topic', orPath: true })
  expect(ask('checkout --detach abc1234')).toEqual({ ask: 'name', name: 'abc1234', orPath: true })
  // `--` with nothing after it names no path: it is git's own way to say the word before it is a
  // branch or commit, so the checkout is a move, never a path put back (lessons review of 690e551).
  expect(ask('checkout topic --')).toEqual({ ask: 'name', name: 'topic', orPath: false })
  expect(ask('checkout --detach abc1234 --')).toEqual({ ask: 'name', name: 'abc1234', orPath: false })
  expect(ask('checkout -B new origin/main --')).toEqual({ ask: 'tree', commit: 'origin/main' })
  expect(g('checkout topic -- app/globals.css')).toBeUndefined()
  expect(g('checkout --')).toBeUndefined()
  expect(ask('checkout -B new origin/main')).toEqual({ ask: 'tree', commit: 'origin/main' })
  expect(ask('reset --hard')).toEqual({ ask: 'tree', commit: 'HEAD', worktree: true })
  expect(ask('reset --keep origin/main')).toEqual({ ask: 'tree', commit: 'origin/main', worktree: true })
  expect(ask('stash pop')).toEqual({ ask: 'stash', entry: 'stash@{0}' })
  expect(ask('stash apply --index 2')).toEqual({ ask: 'stash', entry: 'stash@{2}' })
  expect(ask('stash pop stash@{1}')).toEqual({ ask: 'stash', entry: 'stash@{1}' })
  // Nothing comes into the working tree, or mod-kit's write reader gives the files already.
  for (const line of [
    'merge --abort',
    'merge --continue',
    'rebase --skip',
    'rebase --edit-todo',
    'rebase --show-current-patch',
    'cherry-pick --quit',
    'cherry-pick',
    'revert --abort',
    'switch -c new',
    'switch --detach',
    'checkout -b new',
    'checkout',
    'checkout HEAD -- app/page.tsx',
    'checkout origin/main app/page.tsx',
    'checkout -p topic',
    'reset',
    'reset --soft HEAD~1',
    'reset HEAD app/page.tsx',
    'stash',
    'stash push -u',
    'stash list',
    'stash drop',
    'fetch origin',
    'status',
    'commit -m merge',
  ])
    expect({ line, move: g(line) }).toEqual({ line, move: undefined })
  // The option that only shows the stopped patch is named in full, and is read as that only where
  // the command names no commit. One that merely starts the same way is a move like any other.
  expect(ask('rebase --show-anything')).toEqual({ ask: 'merge', commits: ['@{upstream}'] })
  expect(ask('merge --show-anything')).toEqual({ ask: 'merge', commits: ['@{upstream}'] })
  expect(ask('merge --show-anything topic')).toEqual({ ask: 'merge', commits: ['topic'] })
  expect(ask('rebase --show-anything main')).toEqual({ ask: 'merge', commits: ['main'] })
  expect(ask('rebase --show-current-patch main')).toEqual({ ask: 'merge', commits: ['main'] })
  expect(gitMove(undefined)).toBeUndefined()
  expect(gitMove({ sub: undefined, args: [] })).toBeUndefined()
  // A subcommand spelled like a member every object inherits is no move, and reading it never throws.
  for (const sub of ['constructor', 'toString', '__proto__', 'hasOwnProperty']) expect({ sub, move: gitMove({ sub, args: ['-m', 'x', 'topic'] }) }).toEqual({ sub, move: undefined })
  // Its words cannot say what it brings in.
  const unread = (line: string) => {
    const m = g(line)
    return m && 'unread' in m ? m.unread : ''
  }
  expect(unread('pull')).toContain('git pull fetches before it merges')
  expect(unread('pull --rebase origin main')).toContain('git pull fetches before it merges')
  for (const line of ['rebase --onto main a', 'rebase --onto=main a', 'rebase -i main', 'rebase --root', 'rebase -x make main', 'rebase main topic']) expect({ line, said: unread(line).includes('this form of git rebase') }).toEqual({ line, said: true })
  expect(unread('switch --orphan empty')).toContain('takes every tracked file out')
  expect(unread('stash branch rescue')).toContain('git stash branch')
  for (const line of ['merge $BRANCH', 'cherry-pick `cat sha`', 'checkout feat*', 'reset --hard $(cat base)']) expect({ line, said: unread(line).includes('which the guard cannot hand to git to read') }).toEqual({ line, said: true })
  // A pull and a rebase the guard cannot read each say how to run them so it can, or nothing.
  const pull = g('pull')
  expect(pull && 'remedy' in pull ? pull.remedy : '').toContain('Run git fetch as its own command first')
  // The words a refusal quotes are cut short where a message makes them long.
  expect(g(`merge -m ${'x'.repeat(200)} topic`)?.said.length).toBe(120)
})

// #3337: the mainline number of a cherry-pick or revert names the parent each commit is read
// against. gitMove took it as an option's value and dropped it, so every one was read against the
// first parent.
test('#3337: gitMove hands on the mainline number of a cherry-pick or revert, and says why where it cannot read one', () => {
  const g = (line: string) => {
    const [sub, ...args] = line.split(' ')
    return gitMove({ sub, args })
  }
  const ask = (line: string) => {
    const m = g(line)
    return m && 'ask' in m ? m.ask : m
  }
  for (const line of ['cherry-pick -m 2 abc1234', 'cherry-pick --mainline 2 abc1234', 'cherry-pick --mainline=2 abc1234', 'cherry-pick -m2 abc1234', 'cherry-pick abc1234 -m 2', 'cherry-pick -m 2 -m 2 abc1234'])
    expect({ line, ask: ask(line) }).toEqual({ line, ask: { ask: 'picks', revs: ['abc1234'], mainline: 2 } })
  expect(ask('revert --no-edit -m 3 abc1234')).toEqual({ ask: 'picks', revs: ['abc1234'], revert: true, mainline: 3 })
  expect(ask('cherry-pick -m 12 a..b')).toEqual({ ask: 'picks', revs: ['a..b'], mainline: 12 })
  // The first parent is what was always read, so it is handed on as no number at all.
  for (const line of ['cherry-pick -m 1 abc1234', 'cherry-pick --mainline=1 abc1234', 'cherry-pick -m1 abc1234', 'cherry-pick abc1234']) expect({ line, ask: ask(line) }).toEqual({ line, ask: { ask: 'picks', revs: ['abc1234'] } })
  expect(ask('revert -m 1 abc1234')).toEqual({ ask: 'picks', revs: ['abc1234'], revert: true })
  // A number it cannot read, an option that may be the mainline one spelled another way, and two that differ.
  const unreadOf = (line: string) => {
    const m = g(line)
    return m && 'unread' in m ? `${m.unread} ${m.remedy ?? ''}` : ''
  }
  for (const line of [
    'cherry-pick -m $N abc1234',
    'cherry-pick -m two abc1234',
    'cherry-pick -m 0 abc1234',
    'cherry-pick -m 02 abc1234',
    'cherry-pick -m 2x abc1234',
    'cherry-pick --mainline= abc1234',
    'cherry-pick --main 2 abc1234',
    'cherry-pick --mainl=2 abc1234',
    'cherry-pick --m=2 abc1234',
    'cherry-pick --no-mainline abc1234',
    'cherry-pick -xm2 abc1234',
    'cherry-pick -em 2 abc1234',
    'cherry-pick -m 1 -m 2 abc1234',
    'cherry-pick -m 2 --mainline=3 abc1234',
    'revert -m $N abc1234',
    'revert -nm 2 abc1234',
  ])
    expect({ line, said: unreadOf(line).includes('mainline number') && unreadOf(line).includes('Write the mainline number as -m and a whole number') }).toEqual({ line, said: true })
  // A sequence carried on, or no commit named, brings nothing in whatever its options.
  for (const line of ['cherry-pick --continue', 'cherry-pick -m 2', 'revert --abort']) expect({ line, move: g(line) }).toEqual({ line, move: undefined })
  // Every other option of the two is read as before.
  expect(ask('cherry-pick -x --strategy recursive -X theirs abc1234')).toEqual({ ask: 'picks', revs: ['abc1234'] })
  expect(ask('cherry-pick --no-commit --ff abc1234')).toEqual({ ask: 'picks', revs: ['abc1234'] })
  // A letter m inside the value joined onto -X or -S is that option's value, never the mainline one.
  expect(ask('cherry-pick -Xrenormalize -Smykey abc1234')).toEqual({ ask: 'picks', revs: ['abc1234'] })
  expect(ask('merge -m 2 topic')).toEqual({ ask: 'merge', commits: ['topic'] })
})

test('#3279: movedFiles and pickedFiles read what git lists, and give nothing rather than no files for anything else', () => {
  const sha = 'a'.repeat(40)
  const other = 'b'.repeat(40)
  expect(movedFiles('', sha)).toEqual([])
  expect(movedFiles('M\0app/page.tsx\0A\0app/new.css\0D\0app/old.css\0T\0link\0', sha)).toEqual([{ rel: 'app/page.tsx', from: sha }, { rel: 'app/new.css', from: sha }, { rel: 'app/old.css', removes: true }, { rel: 'link', from: sha }])
  // A name with a space or a newline comes whole between the zeros.
  expect(movedFiles('M\0app/my page.tsx\0', sha)).toEqual([{ rel: 'app/my page.tsx', from: sha }])
  for (const bad of ['M\tapp/page.tsx\n', 'warning: something\n', 'M\0app/page.tsx', 'R100\0a\0b\0', 'M\0\0']) expect({ bad, read: movedFiles(bad, sha) }).toEqual({ bad, read: undefined })
  // git log --no-walk: one block per commit, a newline after the zero that ends its name.
  const log = `\u0001${sha}\0\nM\0app/page.tsx\0D\0app/old.css\0\u0001${other}\0\nA\0app/new.css\0`
  expect(pickedFiles(log)).toEqual([{ rel: 'app/page.tsx', from: sha }, { rel: 'app/old.css', removes: true }, { rel: 'app/new.css', from: other }])
  // Reverted, each file goes back to what the commit's parent held, and one the commit added goes.
  expect(pickedFiles(log, true)).toEqual([{ rel: 'app/page.tsx', from: `${sha}^` }, { rel: 'app/old.css', from: `${sha}^` }, { rel: 'app/new.css', removes: true }])
  expect(pickedFiles('')).toEqual([])
  expect(pickedFiles(`\u0001${sha}\n`)).toEqual([])
  for (const bad of ['fatal: bad revision\n', `\u0001not-a-sha\0\nM\0a\0`, `\u0001${sha}\0\nM\ta\n`]) expect({ bad, read: pickedFiles(bad) }).toEqual({ bad, read: undefined })
  // What the session is told: with another way to run it nothing is asked of Dan; with none, it may ask.
  expect(moveUnread('git pull', 'it fetches first', 'Run git fetch first.')).toContain('for `git pull` it could not: it fetches first. So it cannot tell whether a file that changes how the screen looks arrives. Run git fetch first. Nothing is asked of Dan for this.')
  expect(moveUnread('git rebase -i main', 'this form')).toContain('or ask Dan')
  expect(moveUnread('git rebase -i main', 'this form')).not.toContain('Nothing is asked of Dan')
})

// #3279, Dan, 2026-11-20, "Skip what is on main": the pure parts of telling which files a merge of
// the default branch brings in exactly as that branch holds them.
test('#3279: the default branch is read only from a plain branch name under the remote, and a merge is still asked about every file its commit holds beyond that branch', () => {
  expect(defaultBranchRef('main')).toBe('refs/remotes/origin/main')
  expect(defaultBranchRef('release/2026.11')).toBe('refs/remotes/origin/release/2026.11')
  // No name, or one that would read as anything but one branch where git is handed it: none, so the merge is asked about.
  for (const bad of [null, undefined, '', '-main', 'main..topic', 'a b', '$X', 'main^', 'main~1', 'x:y', 'HEAD@{1}', 'a*', '/main', 'main/', 'a//b', '.main', 'a/.b', 'main\n'])
    expect({ bad, ref: defaultBranchRef(bad) }).toEqual({ bad, ref: undefined })
  const sha = 'a'.repeat(40)
  const css = { rel: 'app/globals.css', from: sha }
  const theme = { rel: 'app/theme.css', from: sha }
  const old = { rel: 'app/old.css', removes: true as const }
  // The commit holds nothing beyond the default branch: nothing is asked.
  expect(beyondDefault([css, theme, old], [])).toEqual({ asked: [], shipped: [css, theme, old] })
  // It changed one file since leaving it: that file is asked about, by its exact name, and no other.
  expect(beyondDefault([css, theme, old], [theme, { rel: 'docs/notes.md', from: sha }])).toEqual({ asked: [theme], shipped: [css, old] })
  expect(beyondDefault([css, theme, old], [{ rel: 'app/old.css', removes: true }, { rel: 'app/Globals.css', from: sha }])).toEqual({ asked: [old], shipped: [css, theme] })
  expect(beyondDefault([css], [css])).toEqual({ asked: [css], shipped: [] })
  expect(beyondDefault([], [css])).toEqual({ asked: [], shipped: [] })
  // What the guard's log says of a skip: the files, the command, and the commit of the default branch it was read against.
  const said = onDefaultSaid('git merge origin/main', ['app/globals.css', 'app/old.css'], 'refs/remotes/origin/main', 'd'.repeat(40))
  expect(said).toBe(
    'design-round-guard: not asked about app/globals.css and app/old.css, which `git merge origin/main` brings in exactly as the default branch holds them (refs/remotes/origin/main at dddddddddddd): a look change already on the default branch has shipped (#3279).',
  )
  expect(onDefaultSaid('git rebase', ['app/globals.css'], 'refs/remotes/origin/main', 'd'.repeat(40))).toContain('brings in exactly as the default branch holds it (refs/remotes/origin/main at dddddddddddd)')
})

// #1191: a design round's working files go in the session's scratchpad, which Claude Code hands every
// session as <temp>/claude-<uid>/<project>/<session id>/scratchpad, its temp folder wherever that is.
test("the session's scratchpad is known by the session's id, under Claude Code's own temp folder", () => {
  // CLAUDE_CODE_TMPDIR when it is set, else /tmp; macOS spells /tmp and /var under /private too.
  expect(tempRoots(undefined)).toEqual(['/tmp', '/private/tmp'])
  expect(tempRoots('')).toEqual(['/tmp', '/private/tmp'])
  expect(tempRoots(`${'/Users'}/dan/Temp Dir/`)).toEqual([`${'/Users'}/dan/Temp Dir`])
  expect(tempRoots('/var/folders/x/T')).toEqual(['/var/folders/x/T', '/private/var/folders/x/T'])
  // A relative or climbing setting is not one Claude Code could have used as written: the default.
  expect(tempRoots('tmp')).toEqual(['/tmp', '/private/tmp'])
  expect(tempRoots('/tmp/../w/slate')).toEqual(['/tmp', '/private/tmp'])
  const tmp = tempRoots(undefined)
  const spaced = tempRoots(`${'/Users'}/dan/Temp Dir`)
  expect(inScratchpad('/private/tmp/claude-501/-Users-dan-slate/s1/scratchpad/3718/round1/screen.css', 's1', tmp)).toBe(true)
  expect(inScratchpad('/tmp/claude-501/-Users-dan-slate/s1/scratchpad', 's1', tmp)).toBe(true)
  expect(inScratchpad(`${'/Users'}/dan/Temp Dir/claude-501/-Users-dan-slate/s1/scratchpad/a b/screen.css`, 's1', spaced)).toBe(true)
  // Lessons review: a folder shaped like it anywhere else, a checkout included, is not it.
  expect(inScratchpad('/w/slate/app/claude-1/x/s1/scratchpad/page.tsx', 's1', tmp)).toBe(false)
  expect(inScratchpad('/w/slate/tmp/claude-501/x/s1/scratchpad/page.tsx', 's1', tmp)).toBe(false)
  expect(inScratchpad(`${'/Users'}/dan/Temp Dir/claude-501/x/s1/scratchpad/screen.css`, 's1', tmp)).toBe(false)
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
  expect(namesScratchpad(`R="${'/Users'}/dan/Temp Dir/claude-501/x/s1/scratchpad"; ls "$R"`, 's1', spaced)).toBe(true)
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
  expect(shellVarPath(`R="${'/Users'}/dan/Temp Dir/r1/"; x`, text, 'R/screen.css')).toBe(`${'/Users'}/dan/Temp Dir/r1/screen.css`)
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
  // Lessons review of #3144: read leniently, since a script it cannot place is not read at all. An
  // assignment after `&&` or exported places it as before.
  expect(shellVarPath('true && R=/a; x', text, 'R/screen.css')).toBe('/a/screen.css')
  expect(shellVarPath('R=/a; export R; x', text, 'R/screen.css')).toBe('/a/screen.css')
})

// #3144: a word a command hands on, spelled through variables the command sets to one literal value
// each, is read as the shell spells it; anything else it holds the guard cannot read.
test('spelledThrough spells a word through the literal values the command gives its variables, and nothing it cannot be sure of', () => {
  const sql = 'select count(*) as n from $T; select * from $T limit 8'
  expect(spelledThrough(`T=db.sc.tbl; python -m tool -q "${sql}"`, sql)).toBe('select count(*) as n from db.sc.tbl; select * from db.sc.tbl limit 8')
  expect(spelledThrough(`T='db.sc.tbl' && python -m tool -q "x * \${T}"`, 'x * ${T}')).toBe('x * db.sc.tbl')
  expect(spelledThrough("P='app/*push*'; python3 /tmp/sweep.py $P", '$P')).toBe('app/*push*')
  expect(spelledThrough('A=app; B=css; npx prettier --write "$A/*.$B"', '$A/*.$B')).toBe('app/*.css')
  // Set nowhere, twice to different values, built from another value, only begun, holding a space,
  // or spelled in a form other than $T and ${T}: not read.
  for (const [command, word] of [
    ['python -m tool -q "x * $T"', 'x * $T'],
    ['T=a; T=b; python -m tool -q "x * $T"', 'x * $T'],
    ['T="$HOME/x"; python -m tool -q "x * $T"', 'x * $T'],
    ['T=$(pwd); python -m tool -q "x * $T"', 'x * $T'],
    ['T=a$X; python -m tool -q "x * $T"', 'x * $T'],
    ["T='a b'; python -m tool -q \"x * $T\"", 'x * $T'],
    ['T=a; python -m tool -q "x * ${T:-b}"', 'x * ${T:-b}'],
    ['T=a; python -m tool -q "x * $1 $T"', 'x * $1 $T'],
    ['T=a; python -m tool -q "x * \\$T"', 'x * \\$T'],
    ["T='$Y'; python -m tool -q \"x * $T\"", 'x * $T'],
    ['T=a; python -m tool -q "x * $(cat f) $T"', 'x * $(cat f) $T'],
    ['T=a; python -m tool -q "x * plain"', 'x * plain'],
  ])
    expect({ command, spelled: spelledThrough(command as string, word as string) }).toEqual({ command, spelled: undefined })
})

// Lessons review of #3144: a variable the command changes any other way than a whole literal
// assignment holds another value, or none, when what it is handed runs, so it has no one value.
test('literalValue, asked for the value handed on, reads only a variable every change of which is a whole literal assignment', () => {
  expect(literalValue('T=txt; x "$T"', 'T', true)).toBe('txt')
  expect(literalValue('export T=txt && x "${T}"', 'T', true)).toBe('txt')
  for (const change of [
    'T+=sx', 'for T in tsx; do true; done', 'for T; do true; done', 'read T < f', 'read -r a T < f',
    'mapfile T < f', 'readarray -t T < f', 'printf -v T tsx', 'getopts ab T', 'unset T', 'unset -v T',
    'let T=txt', 'let "T = 1"', '((T=txt))', '(( T += 1 ))', 'declare T', 'declare -i T=txt', 'local T',
    'local T=txt', 'typeset T', 'readonly T=txt', 'export -n T', 'export T',
  ])
    expect({ change, value: literalValue(`T=txt; ${change}; x "$T"`, 'T', true) }).toEqual({ change, value: undefined })
  // Lessons review at d77d5c0: only an assignment standing whole at the top of the command, before
  // its first use, after nothing that may not run, is the value the shell hands on.
  expect(literalValue('T=.md\nx "$T"', 'T', true)).toBe('.md')
  expect(literalValue('cd /w; T=.md && x "$T"', 'T', true)).toBe('.md')
  for (const command of [
    'x "$T"; T=.md',
    'T=.md x "$T"',
    '(T=.md); x "$T"',
    '{ T=.md; }; x "$T"',
    'false && T=.md; x "$T"',
    'true || T=.md; x "$T"',
    'T=.md & x "$T"',
    'echo a | T=.md; x "$T"',
    'if false; then T=.md; fi; x "$T"',
    'while false; do T=.md; done; x "$T"',
    'case a in b) T=.md;; esac; x "$T"',
    'f() { T=.md; }; x "$T"',
    'cat <<EOF\nT=.md\nEOF\nx "$T"',
    'X=$(pwd); T=.md; x "$T"',
  ])
    expect({ command, value: literalValue(command, 'T', true) }).toEqual({ command, value: undefined })
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

test("the source reader's strings end where mod-kit's quotedEnd says, and one a line break leaves open is unread (#2467)", () => {
  const text = `const a = 'it\\'s'; const b = "say \\"hi\\""; const c = 'one\\\ntwo'`
  const spans = sourceSpans(text, false)
  if (!spans) throw new Error('the fixture could not be read')
  expect(spans.strings.map(([x, y]) => text.slice(x, y))).toEqual(["it\\'s", 'say \\"hi\\"', 'one\\\ntwo'])
  // A string a bare line break leaves open, or the end of the text, is read as nothing at all.
  for (const bad of ["const s = 'open\nshut'", 'const s = "open', "const s = 'ends\\"]) expect(sourceSpans(bad, false)).toBeNull()
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
test("#1248, #2845: the refused helper is read past the line test for the card it names; its notification's words pass, named", () => {
  if (STEPS_BEFORE.split(STEPS_OLD).length !== 2) throw new Error('the fixture holds the refused old_string other than once')
  // Dan, 2026-10-16: the line fix only, no word exempted, so the line test still asks about the
  // helper naming the card. #1823 then held the notification it sends Dan as new wording (Dan,
  // 2026-10-27: "message wording should be asked about"); #2845 reverses that (Dan, 2026-11-12:
  // "any words"). The helper draws nothing, so it passes, and its words are named for the record.
  const withHelper = STEPS_BEFORE.replace(STEPS_OLD, STEPS_NEW)
  expect(modHookLogicOnly(STEPS_BEFORE, withHelper)).toBe(false)
  expect(modHookDrawingUntouched([], 'register.tsx', STEPS_BEFORE, withHelper)).toBe(true)
  expect(messageWords([], 'register.tsx', STEPS_BEFORE, withHelper)).not.toBe(undefined)
  // And once it is there, rewording the notification passes too, named.
  const reworded = withHelper.replace('is pinned. Next, step', 'is on the card. Next, step')
  expect(modHookDrawingUntouched([], 'register.tsx', withHelper, reworded)).toBe(true)
  expect(messageWords([], 'register.tsx', withHelper, reworded)).not.toBe(undefined)
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
  // The line test still asks about its drawing words, the hold #1823 reports; the reading below passes it.
  expect(modHookLogicOnly(MS_TSX, after)).toBe(false)
  expect(modHookDrawingUntouched(MS_FILES, 'register.tsx', MS_TSX, after)).toBe(true)
  // A new helper that reads the card's heading for no surface and no message draws nothing either.
  const helper = 'const heading = (card: StepsCard): string => card.heading.trim()\n\n'
  expect(modHookDrawingUntouched(MS_FILES, 'register.tsx', MS_TSX, msEdit('const publishBand', `${helper}const publishBand`))).toBe(true)
})

// #1823 held the wording of a message a person sees in a mod's .tsx hook file (Dan, 2026-10-27:
// "message wording should be asked about"); #2845 reverses it (Dan, 2026-11-12: "any words"). A
// change to those words draws nothing new, so it passes, and messageWords names it for the record;
// where or when the card shows, and words only Claude reads, pass with nothing to name.
test('#1823, #2845: a placement change and a tool description pass unnamed; the wording of a message Dan sees passes, named', () => {
  const judged = (from: string, to: string) => {
    const after = msEdit(from, to)
    if (!modHookDrawingUntouched(MS_FILES, 'register.tsx', MS_TSX, after)) return 'draws'
    return messageWords(MS_FILES, 'register.tsx', MS_TSX, after) === undefined ? 'passes' : 'words'
  }
  // Where the card goes, and a description of the tool, which only Claude reads.
  expect(judged('const PANE_COLUMNS = 144', 'const PANE_COLUMNS = 110')).toBe('passes')
  expect(judged('as a card he works through.', 'as a card Dan works through, one step at a time.')).toBe('passes')
  // A debug log line, which nobody sees in the session, and when the toast is shown.
  expect(judged('the card went to the band', 'the steps card went to the band')).toBe('passes')
  expect(judged('  if (failed) $.ui.toast(', '  if (failed && failed.length) $.ui.toast(')).toBe('passes')
  // A toast's words, a transcript line's, a stop reason's, a tool result's and a slash command's reply.
  expect(judged('could not be moved to the band', 'could not go back to the band')).toBe('words')
  expect(judged('Manual steps moved the card to the band.', 'Manual steps put the card in the band.')).toBe('words')
  expect(judged('Put it on the card with', 'Pin it on the steps card with')).toBe('words')
  expect(judged('Pinned the card "', 'Put the card up: "')).toBe('words')
  expect(judged('No steps card is pinned for this project.', 'No steps card is up in this project.')).toBe('words')
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
test("#1823, #2845: a notification's title reaching terminal-notifier through a promise is wording, named when it changes, never held", () => {
  const needs = NOTIFY_TSX.replace('the steps card is waiting on you', 'the steps card needs you')
  expect(modHookDrawingUntouched([], 'register.tsx', NOTIFY_TSX, needs)).toBe(true)
  expect(messageWords([], 'register.tsx', NOTIFY_TSX, needs)).toBe('the steps card needs you')
  // When it is sent is no wording.
  const later = NOTIFY_TSX.replace('{ timeoutMs: 10_000 }', '{ timeoutMs: 20_000 }')
  expect(modHookDrawingUntouched([], 'register.tsx', NOTIFY_TSX, later)).toBe(true)
  expect(messageWords([], 'register.tsx', NOTIFY_TSX, later)).toBe(undefined)
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

// What modHookTsChange says of a change to a mod's .ts hook file (#1859, #2845): `look`, held for
// what it draws; `words`, a change to a message's words only, which passes recorded naming them; or
// `passes`, neither. Until #2845 `words` was held too; these tests now defend the reading that names
// the words in the record, and that a look change is still told apart from them.
const changeOf = (...a: Parameters<typeof modHookTsChange>): 'look' | 'words' | 'passes' => {
  const h = modHookTsChange(...a)
  return h === undefined ? 'passes' : 'look' in h ? 'look' : 'words'
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
test("#1841, #2845: the wording of a toast, a refusal or a tool's result in a mod's .ts hook file is named as words, never asked about, as it draws nothing", () => {
  const edit = (from: string, to: string) => {
    const after = SECRET_TS.replace(from, to)
    if (after === SECRET_TS) throw new Error(`no ${from}`)
    return after
  }
  const judged = (from: string, to: string) => changeOf([], 'register.ts', SECRET_TS, edit(from, to))
  // drawsChange, all a .ts hook file was judged by, lets the toast's new words through.
  expect(drawsChange([], 'register.ts', SECRET_TS, edit('Blocked a command that', 'Stopped a command that'))).toBe(false)
  // A toast's words, a refusal's reason, and a tool's result, each named as words, never held (#2845).
  expect(judged('Blocked a command that', 'Stopped a command that')).toBe('words')
  expect(judged('Blocked: this would print', 'Stopped: this would show')).toBe('words')
  expect(judged('Kept the job running.', 'The job stays up.')).toBe('words')
  // When the toast is shown, and what decides it, pass.
  expect(judged('what.length > 3', 'what.length > 5')).toBe('passes')
  // A tool's description and its schema's, read only by Claude, pass: a schema property named
  // reason among them, which is no refusal's reason.
  expect(judged('Keep a background job running on purpose', 'Keep a background job up on purpose')).toBe('passes')
  expect(judged('Why it must keep running.', 'Why it has to keep running.')).toBe('passes')
  expect(judged('The background job id', 'The id of the background job')).toBe('passes')
  // What it draws is still held, and a change to nothing at all is none.
  expect(changeOf([], 'row.ts', undefined, "export const row = (t: string) => [{ text: t, color: 'warning' }]\n")).toBe('look')
  expect(changeOf([], 'register.ts', SECRET_TS, SECRET_TS)).toBe('passes')
  // A file made with a message says new words, and one taken away takes them; one with none passes.
  expect(changeOf([], 'register.ts', undefined, SECRET_TS)).toBe('words')
  expect(changeOf([], 'register.ts', SECRET_TS, undefined)).toBe('words')
  expect(changeOf([], 'new.ts', undefined, 'export const twice = (n: number) => n * 2\n')).toBe('passes')
  // A mod file beside it that cannot be read holds every edit where the mod draws (here through a
  // register.tsx); since #3017 (Dan, 2026-11-15) a mod drawing nothing is judged as code instead.
  const unreadable = { name: 'place.ts', text: "const x = 'open" }
  expect(changeOf([unreadable, { name: 'register.tsx', text: 'export const Card = () => <Box />\n' }], 'register.ts', SECRET_TS, edit('what.length > 3', 'what.length > 5'))).toBe('look')
  expect(changeOf([unreadable], 'register.ts', SECRET_TS, edit('what.length > 3', 'what.length > 5'), [])).toBe('passes')
  // Only once the folders inside the hooks folder are read: a caller handing none proves nothing.
  expect(changeOf([unreadable], 'register.ts', SECRET_TS, edit('what.length > 3', 'what.length > 5'))).toBe('look')
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
test("#1925, #2845: an answer's description and label, which Dan reads in the picker, are named as wording, never held; a tool's or a schema's description passes unnamed", () => {
  const edit = (from: string, to: string) => {
    const after = ANSWERS_TS.replace(from, to)
    if (after === ANSWERS_TS) throw new Error(`no ${from}`)
    return after
  }
  const judged = (from: string, to: string) => changeOf([], 'rules.ts', ANSWERS_TS, edit(from, to))
  // The #1904 builder's edit, to an answer's description beside its label, and the same to its label.
  expect(judged('Nothing that changes the look is edited', 'Nothing that changes the look or wording is edited')).toBe('words')
  expect(judged('go ahead on ${named} without', 'go ahead on ${named} with no')).toBe('words')
  expect(judged("label: 'Run /design-rounds'", "label: 'Start /design-rounds'")).toBe('words')
  expect(judged("export const SKIP_YES = 'Skip them'", "export const SKIP_YES = 'Skip the rounds'")).toBe('words')
  // An answer given by a conditional inside a call's parentheses, which is no parameter's pattern.
  expect(judged('Only this answer is shown', 'Only this one answer is shown')).toBe('words')
  // An answer in an options list, which names no label of its own.
  expect(judged("description: 'Edits that change the look go ahead' }", "description: 'Edits to the look go ahead' }")).toBe('words')
  // The record names the words.
  const hold = modHookTsChange([], 'rules.ts', ANSWERS_TS, edit('Nothing that changes the look is edited', 'Nothing that changes the look or wording is edited'))
  expect(hold && 'words' in hold ? hold.words : '').toContain('Nothing that changes the look or wording')
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
test("#1934, #2845: a question's text and header, which Dan reads in the picker, are named as wording, never held, in the file asking it or the one it is worded in; a tool's schema naming them passes unnamed", () => {
  const edited = (text: string, from: string, to: string) => {
    const after = text.replace(from, to)
    if (after === text) throw new Error(`no ${from}`)
    return after
  }
  const inRegister = (from: string, to: string) => changeOf([{ name: 'rules.ts', text: Q_RULES_TS }], 'register.ts', Q_REGISTER_TS, edited(Q_REGISTER_TS, from, to))
  const inRules = (from: string, to: string) => changeOf([{ name: 'register.ts', text: Q_REGISTER_TS }], 'rules.ts', Q_RULES_TS, edited(Q_RULES_TS, from, to))
  // A question and header written where it is asked, in a questions list or beside options.
  expect(inRegister('Is this design settled?', 'Is the design settled?')).toBe('words')
  expect(inRegister("header: 'Settled'", "header: 'Design settled'")).toBe('words')
  expect(inRegister('Keep this answer?', 'Keep that answer?')).toBe('words')
  // One handed in as a parameter (asked's `question`), worded in another file, and the header's constant.
  expect(inRules("'Skip design rounds for this issue?'", "'Skip the design rounds for this issue?'")).toBe('words')
  expect(inRules('It changes ${named}.', 'It would change ${named}.')).toBe('words')
  expect(inRules("HEADER = 'Design round'", "HEADER = 'Design rounds'")).toBe('words')
  // The record names the words.
  const hold = modHookTsChange([{ name: 'rules.ts', text: Q_RULES_TS }], 'register.ts', Q_REGISTER_TS, edited(Q_REGISTER_TS, 'Is this design settled?', 'Is the design settled?'))
  expect(hold && 'words' in hold ? hold.words : '').toContain('Is the design settled?')
  // A tool's schema describing question and header properties, read only by Claude, passes.
  expect(inRules('The question to put to him.', 'The question to ask him.')).toBe('passes')
  expect(inRules('A short header above it.', 'A header above it.')).toBe('passes')
  // So does the logic around the question.
  expect(inRegister('multiSelect: false }] })\n    return', 'multiSelect: true }] })\n    return')).toBe('passes')
})

// #1859 named the words a hold for them alone was made for; since #2845 nothing is held for words,
// and the same naming (messageWords, namedWords) is what an automatic pass's record says. Every
// refusal, card and shell outcome now says only the look, and nothing says a message's words.
test("#1859, #2845: a change to a message's words alone is read as words, named; a look change is read and said as the look", () => {
  const reworded = SECRET_TS.replace('Blocked a command that', 'Stopped a command that')
  const hold = modHookTsChange([], 'register.ts', SECRET_TS, reworded)
  const words = hold && 'words' in hold ? hold.words : ''
  expect(words).toContain('Stopped a command that')
  // A look change, logic alone, and words taken away.
  expect(modHookTsChange([], 'row.ts', undefined, "export const row = (t: string) => [{ text: t, color: 'warning' }]\n")).toEqual({ look: true })
  expect(modHookTsChange([], 'register.ts', SECRET_TS, SECRET_TS.replace('what.length > 3', 'what.length > 5'))).toBe(undefined)
  const gone = modHookTsChange([], 'register.ts', SECRET_TS, SECRET_TS.replace("result: 'Kept the job running.'", "result: ''"))
  expect(gone && 'words' in gone ? gone.words : '').toContain('Kept the job running.')
  // Long words are shortened, their spaces run together.
  const long = SECRET_TS.replace('Blocked a command that would print a secret.', `Stopped ${'a very long sentence   '.repeat(8)}that ends here.`)
  const shortened = modHookTsChange([], 'register.ts', SECRET_TS, long)
  const said = shortened && 'words' in shortened ? shortened.words : ''
  expect(said.length).toBeLessThan(80)
  expect(said.includes('  ')).toBe(false)
  expect(said.startsWith('Stopped a very long')).toBe(true)
  // The record names them (#2845), beside any file changed in logic alone.
  const file = 'payload/mods/demo/hooks/guard.ts'
  expect(autoPassWhy([file], [{ file, words }])).toContain(`only the words of a message the mod shows ("${words}")`)
  const mixed = autoPassWhy(['app/page.tsx', file], [{ file, words }])
  expect(mixed).toContain(`${file} changes only the words`)
  expect(mixed).toContain('app/page.tsx changes only logic')
  expect(mixed).toContain('#2294, #2845')
  expect(DASHES.test(mixed)).toBe(false)

  const subjects = [{ key: 'k', label: 'issue #1859 in claude-config' }]
  const LOOK = 'changes how the screen looks'
  // A look change says the look, and nothing names a message's words any more.
  for (const r of [refusal('t3', ['app/page.tsx'], subjects), agentRefusal(['app/page.tsx'], subjects, 't4'), checked(['app/page.tsx'], subjects), unsure(['app/page.tsx'], 'a detached head names no branch'), unreadable(['app/page.tsx'], subjects, 'EIO')]) {
    expect(r).toContain(`app/page.tsx ${LOOK}`)
    expect(r.includes('words of a message')).toBe(false)
  }
  expect(card(['app/page.tsx'], subjects).reason.startsWith('Claude wants to make an edit that may change how something looks on screen')).toBe(true)
  for (const o of [{ file, undone: '/s/kept' }, { file, unkept: 'no scratchpad' }, { file, changed: '/s/kept' }, { file, failed: 'EIO', kept: '/s/kept' }, { file, unread: 'EIO' }]) {
    expect(shellOutcome(o)).toContain('what the mod draws')
    expect(shellOutcome(o).includes('words of a message')).toBe(false)
  }
  expect(shellUnchecked('EIO').includes('words of a message')).toBe(false)
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
test('#1841, #2845: a string a message is only computed from passes unnamed; the words of the message are named', () => {
  const judged = (from: string, to: string) => {
    const after = FRONT_TS.replace(from, to)
    if (after === FRONT_TS) throw new Error(`no ${from}`)
    return changeOf([], 'register.ts', FRONT_TS, after)
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
  expect(judged('Blocked bringing', 'Stopped bringing')).toBe('words')
  expect(judged(".join(' and ')", ".join(' or ')")).toBe('words')
  expect(judged("'its window'", "'the window'")).toBe('words')
  expect(judged('would be brought to the front${', 'would come forward${')).toBe('words')
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
  expect(messageWords([], 'register.tsx', text, after)).toBe(undefined)
  expect(messageWords([], 'register.ts', text, after)).toBe(undefined)
  expect(changeOf([], 'register.ts', text, after)).toBe('passes')
  // Its words are read as words either way.
  expect(messageWords([], 'register.tsx', text, text.replace('Copied the', 'Copied your'))).toContain('Copied your')
  expect(changeOf([], 'register.ts', text, text.replace('Copied the', 'Copied your'))).toBe('words')
  expect(messageWords([], 'register.tsx', text, text.replace("? 'value'", "? 'text'"))).toBe('text')
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
  return changeOf([], 'register.ts', text, text.replace(from, to))
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

test('#1864, #2845: a one word message, and words beside a tag, are still named as words, never held', () => {
  // A toast or a refusal saying one word.
  expect(tagEdit(TAGS_TS, '  return undefined', "  $.ui.toast('Saved')\n  return undefined")).toBe('words')
  expect(tagEdit(TAGS_TS, '  return undefined', "  $.ui.toast('saved')\n  return undefined")).toBe('words')
  expect(tagEdit(TAGS_TS, "{ deny: 'mutant' }", "{ deny: 'refused' }")).toBe('words')
  expect(tagEdit(TAGS_TS, "{ deny: 'mutant' }", "{ decision: 'block', reason: 'refused' }")).toBe('words')
  // The words of the record holding the argv, and an argv entry joined into a sentence.
  expect(tagEdit(TAGS_TS, 'Reading the log of', 'Reading the history of')).toBe('words')
  expect(tagEdit(TAGS_TS, '(${step.why})', "(${step.why}, ${['ran', 'git'].join(' ')})")).toBe('words')
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
  expect(words("drop: 'dropped'", "drop: 'removed'")).toBe('words')
  expect(words("? 'step' :", "? 'item' :")).toBe('words')
  expect(words("said($, 'moved')", "said($, 'closed')")).toBe('words')
  // A list of one word (lessons review at 324ee11).
  expect(words("['done']", "['finished']")).toBe('words')
})

// #1841 (lessons review at 74900c0): a message's words given to a variable with = or added with +=
// are no value compared, so they are words. Since #2845 words pass, named for the record.
test('#1841, #2845: words assigned or appended before they are said are still named as words', () => {
  const text = [
    "import type { EngineInterface } from 'claude-code'",
    'export const warn = async ($: EngineInterface, n: number) => {',
    "  let msg = 'Blocked a command'",
    "  if (n > 1) msg += ' that would print a secret'",
    '  await $.ui.toast(`${msg}.`)',
    '}',
    '',
  ].join('\n')
  expect(changeOf([], 'register.ts', text, text.replace("'Blocked a command'", "'Stopped a command'"))).toBe('words')
  expect(changeOf([], 'register.ts', text, text.replace("' that would print a secret'", "' that would show a secret'"))).toBe('words')
  expect(changeOf([], 'register.ts', text, text.replace('n > 1', 'n > 3'))).toBe('passes')
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

// #2294: Dan, 2026-11-05: "if nothing on screen changes, why even ask me to skip". An app's React
// screen file changed only in its logic is let through by the guard's own reading of the edit, never by
// a session saying so; anything that can be text, a look or a class on screen is still held.
const OFFERS_PAGE = `import { useState } from 'react'
import { Card } from '@/components/card'

// The offers a person was made.
export default function Page({ offers }: { offers: Offer[] }) {
  const [open, setOpen] = useState(false)
  const visible = offers.filter(o => o.active)
  if (!visible) return null
  return (
    <Card>
      <h1>Your offers</h1>
      {visible.map(o => <Row key={o.id} offer={o} />)}
    </Card>
  )
}
`
test('#2294: a logic only change to an app screen file passes; text, JSX, styles, numbers, booleans, comments, style or side effect imports and a swapped import are held', () => {
  const logic = (from: string, to: string) => {
    const after = OFFERS_PAGE.replace(from, to)
    expect(after).not.toBe(OFFERS_PAGE)
    return logicOnlyChange(OFFERS_PAGE, after)
  }
  const imported = "import { Card } from '@/components/card'\nimport { byDate } from '@/lib/sort'\n"
  // Let through: a condition, a new import from a new module with its use, a type renamed.
  expect(logic('o => o.active)', 'o => o.active && !o.expired)')).toBe(true)
  expect(logic("import { Card } from '@/components/card'\n", imported)).toBe(true)
  expect(logicOnlyChange(OFFERS_PAGE, OFFERS_PAGE.replace("import { Card } from '@/components/card'\n", imported).replace('o.active)', 'o.active).sort(byDate)'))).toBe(true)
  expect(logic('offers: Offer[]', 'offers: OfferRow[]')).toBe(true)
  expect(logic('if (!visible) return null', 'if (!visible.length) return null')).toBe(true)
  // Held: an import swapped for another, which may change a component.
  expect(logic("'@/components/card'", "'@/components/card2'")).toBe(false)
  // Held: a number, a boolean, a comment, a string, an error's message.
  expect(logic('o => o.active)', 'o => o.active).slice(0, 5)')).toBe(false)
  expect(logic('useState(false)', 'useState(true)')).toBe(false)
  expect(logic('// The offers a person was made.', '// The offers made to a person.')).toBe(false)
  expect(logic('o => o.active)', "o => o.status === 'active')")).toBe(false)
  expect(logic('if (!visible) return null', "if (!visible) throw new Error('No offers')")).toBe(false)
  // Held: a style file or a side effect import, which change the page with no word on it.
  expect(logic("import { useState } from 'react'\n", "import { useState } from 'react'\nimport './page.css'\n")).toBe(false)
  expect(logic("import { useState } from 'react'\n", "import { useState } from 'react'\nimport '@/lib/polyfill'\n")).toBe(false)
  expect(logic("import { useState } from 'react'\n", "import { useState } from 'react'\nimport styles from './page.module.scss'\n")).toBe(false)
  // Held: a line naming a look, a class helper or a colour.
  expect(logic('  const visible', '  const styles = pick(offers)\n  const visible')).toBe(false)
  expect(logic('  const visible', '  const k = cn(offers)\n  const visible')).toBe(false)
  expect(logic('  const visible', '  const tone = offers.length ? good : bad\n  const visible')).toBe(false)
  // Held: JSX touched, even only in an expression inside it; a template literal.
  expect(logic('<h1>Your offers</h1>', '<h2>Your offers</h2>')).toBe(false)
  expect(logic('key={o.id}', 'key={o.ref}')).toBe(false)
  expect(logic('  const visible', '  const k = `${a}${b}`\n  const visible')).toBe(false)
  // Held: a text the reader cannot follow, before or after.
  expect(logic('o => o.active)', "o => o.active, 'open)")).toBe(false)
  const broken = OFFERS_PAGE.replace('</Card>', '')
  expect(logicOnlyChange(broken, broken.replace('o.active)', 'o.active && o.live)'))).toBe(false)
  // No change at all is not judged as one.
  expect(logicOnlyChange(OFFERS_PAGE, OFFERS_PAGE)).toBe(false)
})

test('#2294: an automatic pass says what it let through and why, citing the issue', () => {
  const why = autoPassWhy(['src/app/offers/page.tsx'])
  expect(why).toContain('src/app/offers/page.tsx')
  expect(why).toContain('#2294')
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
  expect(sealCheck(`${'/Users'}/dan`)).toEqual(['python3', '-I', `${'/Users'}/dan/.claude/skills/design-rounds/design_file.py`, '--sealed'])
})

// #1747: only the spool helper at its installed path, and only its note, writes none of what it is handed.
test('spoolNote is the installed spool helper running note, and nothing else', () => {
  const HELPER = `${'/Users'}/dan/.claude/hooks/lib/issue-spool.sh`
  const args = (...w: string[]) => w.map(word => ({ word }))
  expect(spoolNote({ path: HELPER, args: args('note', '.', 'app/page.tsx', 'a builder') }, `${'/Users'}/dan`)).toBe(true)
  expect(spoolNote({ path: HELPER, args: args('append', 'app/page.tsx', '{}') }, `${'/Users'}/dan`)).toBe(false)
  expect(spoolNote({ path: '/w/slate/scripts/issue-spool.sh', args: args('note', '.', 'x') }, `${'/Users'}/dan`)).toBe(false)
  expect(spoolNote({ args: args('note', '.', 'x') }, `${'/Users'}/dan`)).toBe(false)
  expect(spoolNote({ path: HELPER, args: args('note', '.', 'x') }, `${'/Users'}/other`)).toBe(false)
  expect(spoolNote({ path: '/.claude/hooks/lib/issue-spool.sh', args: args('note', '.', 'x') }, '')).toBe(false)
  expect(spoolNote({ path: HELPER, args: [] }, `${'/Users'}/dan`)).toBe(false)
})

// #1904: a builder's starting branch, worktree-agent-<id>, names no issue (#1306), so Dan was asked
// about "branch worktree-agent-a09a06788b6ba53ab in claude-config" (2026-10-29, for #1859) rather than
// the issue he knows. The skip question may name the issue the builder works on, and he reads that
// issue, said to hold for this builder only; where his answer is kept does not change, so it reaches
// no other worktree and not the main checkout (#1306, #1740).
test('#1904: the skip question names the issue a builder works on in place of its throwaway branch, kept where it was', () => {
  const at = { main: `${'/Users'}/dan/Apps/slate`, repo: 'slate', session: 's1', isDefault: false, issues: [] as number[] }
  const wt = `${'/Users'}/dan/Apps/slate/.claude/worktrees/agent-a09a06788b6ba53ab`
  const [agent] = subjectsOf({ ...at, branch: 'worktree-agent-a09a06788b6ba53ab', root: wt })
  if (!agent) throw new Error('no subject')
  expect(agent.label).toBe('branch worktree-agent-a09a06788b6ba53ab in slate')
  const named = namedByIssue(agent, 1859)
  expect(named.label).toBe('issue #1859 in slate (this builder only)')
  // Only the label changes: the key and the worktree its skip is also kept under stay the branch's.
  expect({ ...named, label: agent.label }).toEqual(agent)
  expect(named.key).toBe(`record:${'/Users'}/dan/Apps/slate|branch:worktree-agent-a09a06788b6ba53ab`)
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

// #1911 had the answers Dan picks from name wording beside the look while a hold could be for a
// message's words alone. Since #2845 none is, so they name the look only again, and so do the
// refusal and the reason kept with his answer: naming wording would claim a check that is gone (L11).
test("#2845: the skip question's answers, the refusal and the reason kept name only the look, never wording", () => {
  expect(NOT_LOOK).toBe('Not a look change')
  const options = skipOptions([{ key: 'k', label: 'issue #978 in slate' }])
  const [yes, no, third] = options
  expect(yes?.description).toContain('change the look go ahead')
  expect(no?.description).toContain('changes the look is edited')
  expect(third?.label).toBe(NOT_LOOK)
  expect(third?.description).toContain('The look does not change')
  const said = [...options.flatMap(o => [o.label, o.description]), notLookWhy(['hooks/rules.ts']), refusal('t1', ['app/page.tsx'], [{ key: 'k', label: 'issue #978 in slate' }])]
  expect(said.filter(s => /wording/i.test(s))).toEqual([])
})

// #1911 made modHookTsHold the one reading of a .ts hook change, with no wrapper; since #2845 that
// reading is modHookTsChange, and neither name it replaced is left.
test('#1911, #2845: the guard keeps one reading of a .ts hook change, modHookTsChange, with no wrapper beside it', () => {
  expect(Object.keys(allRules).filter(k => ['modHookTsShows', 'modHookTsHold', 'messageWordingSame', 'messageWordings', 'heldWords'].includes(k))).toEqual([])
  expect(typeof allRules.modHookTsChange).toBe('function')
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
test('#2038, #2845: a hook moved into a named const and registered with on(...).catch passes, its event name no message words; a real wording change there is still named', () => {
  const edited = (text: string, from: string, to: string) => {
    const after = text.replace(from, to)
    if (after === text) throw new Error(`no ${from}`)
    return after
  }
  // The logic only move, as #2026 made it, and the event name and filter beside the reference changed after it.
  expect(modHookTsChange([], 'register.ts', SAVE_BEFORE, SAVE_AFTER)).toBe(undefined)
  expect(changeOf([], 'register.ts', SAVE_AFTER, edited(SAVE_AFTER, "on('tool.call'", "on('tool.check'"))).toBe('passes')
  expect(changeOf([], 'register.ts', SAVE_AFTER, edited(SAVE_AFTER, '{ tool: TOOL_NAMES }, saveCall', "{ tool: 'Write' }, saveCall"))).toBe('passes')
  // Controls: the toast's words, the refusal's words, and the words the catch's refusal is made from
  // are each still named as words (held before #2845), in the moved hook and in the catch beside it.
  const toast = modHookTsChange([], 'register.ts', SAVE_BEFORE, edited(SAVE_AFTER, 'it reads as a lasting memory', 'it looks like a lasting memory'))
  expect(toast && 'words' in toast ? toast.words : '').toContain('it looks like a lasting memory')
  expect(changeOf([], 'register.ts', SAVE_AFTER, edited(SAVE_AFTER, "'Not saved: ask Dan first.'", "'Not saved: ask Dan.'"))).toBe('words')
  expect(changeOf([], 'register.ts', SAVE_AFTER, edited(SAVE_AFTER, 'Could not check this call', 'Could not judge this call'))).toBe('words')
  // A callback on what a function of the mod returns still takes its values from the words handed
  // to that function, so those words, said in a toast, are named as before.
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
  expect(changeOf([], 'register.ts', listed, edited(listed, 'Saved the note.', 'Stored the note.'))).toBe('words')
  // Only the engine's `on`, register's first parameter, is read so (Dan, 2026-11-01, narrowing
  // #2043): a callback on what any other function handed in returns is still read through the words
  // handed to it, so those words, said in a toast, are named.
  const handed = [
    "import type { EngineInterface, Register } from 'claude-code'",
    'const tell = ($: EngineInterface, say: (w: string) => Promise<string>) => {',
    "  say('Saved the note.').then(t => $.ui.toast(t))",
    '}',
    'export const register: Register = on => {',
    "  on('session.start', async ($: EngineInterface) => {",
    '    $.ui.toast(`Started.`)',
    '  })',
    '}',
    '',
  ].join('\n')
  expect(changeOf([], 'register.ts', handed, edited(handed, 'Saved the note.', 'Stored the note.'))).toBe('words')
  const inRegister = edited(SAVE_AFTER, 'export const register: Register = on => {', 'export const register: Register = (on, tellLater: (w: string) => Promise<string>) => {')
  const later = edited(inRegister, '  on(\'tool.call\'', "  tellLater('Saved for later.').then(t => $.ui.toast(t))\n  on('tool.call'")
  expect(changeOf([], 'register.ts', later, edited(later, 'Saved for later.', 'Kept for later.'))).toBe('words')
})

// #2161 (Dan, 2026-11-03) passed mod-kit's #2141 edit, whose new words are reasons its shell reader
// gives (`{ unresolved: '...' }`), while other new words were held. Since #2845 no word is held, so
// that narrowing and the key reading behind it are gone: the edit passes however its words are
// reached, and only a reason handed to something the mod draws is still held, as the look.
const plus = (text: string, ...lines: string[]) => `${text}${lines.join('\n')}\n`

test('#2161, #2845: the held #2141 edit passes, and so does any reason a message reads; one handed to a band row is held as the look', () => {
  expect(changeOf([], 'commands.ts', HELD_2141_BEFORE, HELD_2141_AFTER)).not.toBe('look')
  expect(changeOf([], 'commands.ts', HELD_2141_BEFORE, plus(HELD_2141_AFTER, 'export const tell = ($: EngineInterface, line: Line) => $.ui.toast(printed(line).unresolved)'))).toBe('words')
  expect(changeOf([], 'commands.ts', HELD_2141_BEFORE, plus(HELD_2141_AFTER, 'export const tell = ($: EngineInterface, line: Line) => $.ui.toast(JSON.stringify(printed(line)))'))).toBe('words')
  const row = "export const row = ($: EngineInterface, why: string) => $.modkit.bandRow([{ text: why }])"
  expect(changeOf([], 'commands.ts', plus(HELD_2141_BEFORE, row), plus(HELD_2141_AFTER, row, 'export const shownWhy = ($: EngineInterface, line: Line) => row($, printed(line).unresolved)'))).toBe('look')
})

// #2223: reading a mod hook file costs time in step with its size. Every edit to a 180 KB hook file
// took about a second through the hook on a quiet Mac, and past five seconds under load, because
// readMod and drawnOf scanned the whole file again once for each function, local and call in it.
// Judged by growth between two sizes of the same code, never by a wall clock budget: four times the
// file took about eleven times as long before the fix; in step with size it is about four.
// The cost is judged by the MEDIAN ratio over seven rounds, each timing the small and the large size
// back to back (#2790). A starved Mac pauses a run in the middle of one size and not the other, and the
// wall clock counts that wait as work (ratios of 7 to 14 on a loaded Mac, against about four). A pause
// in the large run raises one round's ratio and a pause in the small run lowers it, so the median, which
// three rounds of either kind cannot move, is used rather than the least (a delayed small run would
// let a real regression pass) or the greatest. The bound of six is not loosened.
test('#2223: four times as much mod hook code takes under six times as long to read (it took about eleven)', () => {
  const chunk = (i: number) => [
    `const pick${i} = (rows: string[]) => rows.map(r => r.trim()).filter(r => r.split(',').length > 1 && r !== 'none')`,
    `const show${i} = async ($: any, rows: string[]) => {`,
    `  const names = pick${i}(rows).map((r, k) => { const head = r.slice(0, 4); return head + k })`,
    `  if (names.some(x => x.startsWith('tmp'))) return`,
    `  for (const x of names) await $.process.run(['git', 'log', '--format=%H', x])`,
    `  $.ui.toast(\`Saved \${names.length} rows\`)`,
    '}',
    '',
  ].join('\n')
  const file = (n: number) =>
    "import type { Register } from 'claude-code'\n" + Array.from({ length: n }, (_, i) => chunk(i)).join('') +
    "export const register: Register = on => {\n  on('tool.call', async ($, e) => { await show0($, []) })\n}\n"
  const timed = (n: number) => {
    const before = file(n)
    const after = before.replace('rows.map(r => r.trim())', 'rows.map(r => r.trim() + "")')
    const start = performance.now()
    expect(modHookTsChange([], 'rows.ts', before, after)).toBeUndefined()
    return performance.now() - start
  }
  timed(10)
  const ratios: number[] = []
  for (let round = 0; round < 7; round++) {
    const small = timed(100)
    const large = timed(400)
    expect(small).toBeGreaterThan(0)
    ratios.push(large / small)
  }
  const middle = [...ratios].sort((a, b) => a - b)[3] ?? Infinity
  expect({ ratio: Math.round(middle * 10) / 10, under: middle < 6 }).toEqual({ ratio: expect.any(Number), under: true })
})

// #2726: Claude Code runs every mod in one hooks worker and replaces it when a heartbeat goes
// unanswered, failing every hook in flight at that moment, in every agent, with the words below. The
// guard's catch then refused every such call, an AskUserQuestion picker or a read included, which the
// guard itself passes on its tool and input alone. The catch now answers those as the hook would, and
// still refuses every call the guard would have to read to judge.
const WEDGED = 'no answer to a heartbeat within 5000ms: the hooks worker is wedged (a hook spinning without yielding)'
// Since #2727 said to have timed out and to be no refusal, so it is told apart from one that repeats.
const HELD_WEDGED = `Blocked: the design round guard could not check this call because it timed out (${WEDGED}), so it was stopped. This is not a refusal: try the same call again; if it keeps timing out, tell Dan.`
// #2727: only a timeout is said to be one; every other failure keeps its words and says nothing of
// timing out, since the guard measured no such thing (L11).
test('#2727: a failure that timed out says so and that it is no refusal; any other failure does not', () => {
  for (const why of [WEDGED, 'the hook timed out after 1000ms'])
    expect([why, cannotCheck(why).includes('timed out'), cannotCheck(why).includes('This is not a refusal')]).toEqual([why, true, true])
  // Nor a failure that only names something holding the word (lessons review of 68267d7).
  for (const why of ['EACCES: /w/locked', 'mod-kit: the branch reader failed', 'unknown failure', 'EACCES: /w/timeout/page.tsx', "the hook 'heartbeat' threw: x is undefined"])
    expect([why, cannotCheck(why)]).toEqual([why, `Blocked: the design round guard could not check this call (${why}), so it was stopped. Try again; if it keeps failing, tell Dan.`])
})

// #2948: mentionedLookFiles found names with one pattern whose run of name characters, tried from
// every place in a long run holding no dot and letters, went to its end and back each time: about 1.2
// s for 40,000 such characters, inside the hooks worker's heartbeat, for a large patch or heredoc.
// Judged by growth between two sizes, the median of seven rounds as #2223's test is (#2790): four
// times the text took about sixteen times as long; in step with size it is about four. And what it
// finds is the same as the one pattern found, on text shaped every way it reads.
test('#2948: mentionedLookFiles reads four times the text in under six times as long, and finds what the one pattern found', () => {
  const ONE_PATTERN = /[\w./~@+*[\]()-]+\.[A-Za-z]+\b/g
  for (const text of [
    "open('app/page.tsx','w') and src/app/(shop)/[...slug]/page.tsx, x.css2 y.css",
    'a.b.c/d.e.tsx_1 ~/x/tokens.json @scope/ui+kit/theme.css (open(app/page.tsx).read()',
    'docs/page.html, `src/styles/site.css` x(1)/page.tsx ...css .html. name.tar.gz.x9',
    'aaaa'.repeat(50) + '.tsx ' + 'b/'.repeat(40) + 'c.css',
  ]) {
    const expected = new Set<string>()
    // What the one pattern matched, read through the same rest of mentionedLookFiles.
    for (const m of text.matchAll(ONE_PATTERN)) for (const w of mentionedLookFiles(m[0])) expected.add(w)
    expect([text, mentionedLookFiles(text)]).toEqual([text, [...expected]])
  }
  const timed = (n: number) => {
    const text = `${'a/b_c-d'.repeat(n)} app/page.tsx`
    const start = performance.now()
    expect(mentionedLookFiles(text)).toEqual(['app/page.tsx'])
    return performance.now() - start
  }
  timed(100)
  const ratios: number[] = []
  for (let round = 0; round < 7; round++) {
    const small = timed(1500)
    const large = timed(6000)
    ratios.push(large / Math.max(small, 0.05))
  }
  const middle = [...ratios].sort((a, b) => a - b)[3] ?? Infinity
  expect({ ratio: Math.round(middle * 10) / 10, under: middle < 6 }).toEqual({ ratio: expect.any(Number), under: true })
})

// #2948, measured 2026-11-14 on Claude Code 2.1.325: a design round's captured page (capture-chrome.js)
// inlines its fonts and images as base64, one run of 150,000 name characters for each font. Read before
// #2972, a git apply of three such captures held the hooks worker past its heartbeat, and the engine's
// own log named the design round guard. mentionedModHookFiles kept the same shape of pattern, so a
// program carrying such a run (a heredoc writing a capture) still read it for minutes: 80,000
// characters took 4 to 5 s. And each reader kept its names in a list it searched once per name, so
// 40,000 distinct names took 2.9 s. Judged by growth between two sizes, the median of seven rounds,
// as the test above is: four times the input took about sixteen times as long.
const base64Run = (n: number): string => {
  let seed = 2948
  let s = ''
  for (let i = 0; i < n; i++) {
    seed = (seed * 1103515245 + 12345) >>> 0
    s += String.fromCharCode((seed >>> 16) & 255)
  }
  return btoa(s)
}
const growth = (timed: (n: number) => number, small: number): number => {
  timed(small / 10)
  const ratios: number[] = []
  for (let round = 0; round < 7; round++) {
    const a = timed(small)
    const b = timed(small * 4)
    ratios.push(b / Math.max(a, 0.05))
  }
  return [...ratios].sort((a, b) => a - b)[3] ?? Infinity
}
test('#2948: mentionedModHookFiles reads four times a base64 run in under six times as long, and finds what its one pattern found', () => {
  const ONE_PATTERN = /[\w./~@+-]+\.[cm]?ts\b/g
  for (const text of [
    "p = '/w/r/payload/mods/demo/hooks/rules.ts'; q = 'src/app.ts'; d = 'mods/x/hooks/t.d.ts'; m = \"mods/y/hooks/a.mts\"",
    'mods/a/hooks/x.ts/mods/b/hooks/y.ts mods/c/hooks/z.tsx mods/d/hooks/w.ts-x mods/e/hooks/v.cts_1 ...mods/f/hooks/u.ts',
    'mods/g/hooks/a.ts.ts mods/h/hooks/b.mts mods/h/hooks/b.mts @x/mods/i/hooks/c.ts~ ~/mods/j/hooks/d.ts+',
    `${'a/'.repeat(60)}mods/k/hooks/e.ts ${base64Run(300)}`,
    // A run starting with ts and ending in no hook file once never ended (lessons review of c510731).
    'tsx tsc ts tsconfig.json tsts t.ts .ts ts.ts tstsx mods/l/hooks/f.ts',
  ]) {
    const expected: string[] = []
    for (const m of text.matchAll(ONE_PATTERN)) {
      const word = m[0].replace(/^[.]+(?=[^./])/, '')
      if (/(^|\/)mods\/[^/]+\/hooks\/[^/]+\.(ts|mts|cts)$/i.test(word) && !/\.d\.[mc]?ts$/i.test(word) && !expected.includes(word)) expected.push(word)
    }
    expect([text.slice(0, 80), mentionedModHookFiles(text)]).toEqual([text.slice(0, 80), expected])
  }
  const middle = growth(n => {
    const text = `src: url("data:font/woff2;base64,${base64Run(n)}") mods/demo/hooks/rules.ts`
    const start = performance.now()
    expect(mentionedModHookFiles(text)).toEqual(['mods/demo/hooks/rules.ts'])
    return performance.now() - start
  }, 4000)
  expect({ ratio: Math.round(middle * 10) / 10, under: middle < 6 }).toEqual({ ratio: expect.any(Number), under: true })
})
test('#2948: each name reader reads four times as many distinct names in under six times as long', () => {
  for (const [name, read, named] of [
    ['mentionedLookFiles', mentionedLookFiles, (i: number) => `app/p${i}.css`],
    ['mentionedModHookFiles', mentionedModHookFiles, (i: number) => `mods/m/hooks/h${i}.ts`],
  ] as const) {
    const middle = growth(n => {
      const text = Array.from({ length: n }, (_, i) => named(i)).join(' ')
      const start = performance.now()
      expect(read(text).length).toBe(n)
      return performance.now() - start
      // 5,000 names, not 2,000: at 2,000 a reading took a few ms, and once at load 49 on 12 cores
      // (2026-11-15) the median ratio went over six with nothing changed.
    }, 5000)
    expect({ name, under: middle < 6 }).toEqual({ name, under: true })
  }
})

// #2948: a reader of a text larger than the heartbeat allows for reads it in pieces, cut only where a
// name cannot run on (whitespace), and pauses between them, so the hooks worker answers its heartbeat
// however large the text. Every name is found exactly as one reading finds it, in the same order.
test('#2948: namesInPieces finds what one reading finds, and pauses between pieces', async () => {
  const font = `url("data:font/woff2;base64,${base64Run(PIECE_CHARS)}")`
  const rows = Array.from({ length: 4000 }, (_, i) => `+<link href="app/p${i % 700}.css"> open('mods/m/hooks/h${i % 300}.ts') ${i % 9 === 0 ? font : ''}`).join('\n')
  const text = `${rows}\napp/page.tsx\n${font}`
  expect(text.length).toBeGreaterThan(PIECE_CHARS * 8)
  for (const read of [mentionedLookFiles, mentionedModHookFiles]) {
    let pauses = 0
    const found = await namesInPieces(text, read, async () => {
      pauses++
    })
    expect(found).toEqual(read(text))
    // A base64 run longer than a piece is never cut: each piece holds whole runs.
    expect(pauses).toBeGreaterThanOrEqual(8)
    expect(pauses).toBeLessThan(text.length / PIECE_CHARS + 1)
  }
  // A text within one piece is read at once, with no pause.
  let pauses = 0
  expect(await namesInPieces('see app/page.tsx', mentionedLookFiles, async () => void pauses++)).toEqual(['app/page.tsx'])
  expect(pauses).toBe(0)
  // A pause that fails fails the reading, never a reading cut short.
  await expect(namesInPieces(text, mentionedLookFiles, async () => {
    throw new Error('pause failed')
  })).rejects.toThrow('pause failed')
})

// #2948: a loop of steps of unknown cost (a guess at each name a patch holds reads the whole patch
// again) pauses once a stretch has run, by the clock it is given, and not before.
test('#2948: pacer pauses once a stretch has run, and not before', async () => {
  let clock = 1000
  let pauses = 0
  const pace = pacer(() => clock, async () => {
    pauses++
    clock += 1
  }, 50)
  await pace()
  clock += 49
  await pace()
  expect(pauses).toBe(0)
  clock += 1
  await pace()
  expect(pauses).toBe(1)
  // The stretch starts again from the pause.
  clock += 49
  await pace()
  expect(pauses).toBe(1)
  clock += 1
  await pace()
  expect(pauses).toBe(2)
})

// #2960: what fills in a removal's name where mod-kit gave it neither a path nor a folder: a command's
// output or a shell variable anywhere in it, its folder included; a name in the temp folder itself
// that does not climb out of it, nothing. Read from the word as mod-kit gives it, its quotes taken off.
test('#2960: removalFilledIn names what fills in a removal anywhere in its name, and leaves the temp folder', () => {
  for (const [word, filled] of [
    ['$ROOT/app', 'variable'],
    ['${ROOT:?}/app/', 'variable'],
    ['$PWD/app', 'variable'],
    ['$PWD', 'variable'],
    ['app/$NAME', 'variable'],
    ['$TARGET', 'variable'],
    ['$TMPDIR/../app', 'variable'],
    ['${TMPDIR}/x/$Y', 'variable'],
    ['$(git rev-parse --show-toplevel)/app', 'output'],
    ['`cat list`/app', 'output'],
    ['$(cat list.txt)', 'output'],
    ['$TMPDIR', null],
    ['$TMPDIR/build-cache', null],
    ['${TMPDIR}/a/b.css', null],
    ['app/page.tsx', null],
    ['notes', null],
  ] as [string, 'variable' | 'output' | null][])
    expect([word, removalFilledIn(word)]).toEqual([word, filled])
})

test('#2726: a call the guard passes on its tool and input alone is told apart from one it must read', () => {
  expect(passesByShape('AskUserQuestion', { questions: [{ question: 'Which one?' }] })).toBe(true)
  expect(passesByShape('Read', { file_path: '/w/slate/app/page.tsx' })).toBe(true)
  expect(passesByShape('mcp__x__search', { query: 'page.tsx' })).toBe(true)
  expect(passesByShape('Bash', { command: 'git commit -F msg.txt' })).toBe(false)
  expect(passesByShape('Bash', {})).toBe(false)
  expect(passesByShape('Write', { file_path: '/w/slate/app/page.tsx', content: 'x' })).toBe(false)
  expect(passesByShape('Edit', { file_path: '/w/slate/app/globals.css', old_string: 'a', new_string: 'b' })).toBe(false)
  expect(passesByShape('mcp__x__save', { path: '/w/slate/app/page.tsx' })).toBe(false)
})
test('#2726: a check whose hook the worker lost passes only what the guard passes unread, and refuses the rest naming the loss', async () => {
  const passed: string[] = []
  const pass = (tool: string) => () => {
    passed.push(tool)
    return { decision: 'allow' as const }
  }
  expect(await caughtCheck('AskUserQuestion', { questions: [] }, WEDGED, pass('AskUserQuestion'))).toEqual({ decision: 'allow' })
  expect(await caughtCheck('Read', { file_path: '/w/slate/app/page.tsx' }, WEDGED, pass('Read'))).toEqual({ decision: 'allow' })
  expect(await caughtCheck('Bash', { command: 'git commit -F msg.txt' }, WEDGED, pass('Bash'))).toEqual({ decision: 'deny', reason: HELD_WEDGED })
  expect(await caughtCheck('Write', { file_path: '/w/slate/app/page.tsx', content: 'x' }, WEDGED, pass('Write'))).toEqual({ decision: 'deny', reason: HELD_WEDGED })
  expect(passed).toEqual(['AskUserQuestion', 'Read'])
})
test("#2726: a call whose hook the worker lost is passed on as the hook would pass it, and a subagent's call the guard must read is refused", async () => {
  const sent: string[] = []
  const on = (what: string) => () => {
    sent.push(what)
    return { result: what }
  }
  // The main session's call: this hook only passes it on, to be judged at tool.check.
  expect(await caughtCall({ tool: 'Write' }, { file_path: '/w/slate/app/page.tsx', content: 'x' }, WEDGED, on('main write'))).toEqual({ result: 'main write' })
  // A subagent's question, or a call passing unread.
  expect(await caughtCall({ tool: 'AskUserQuestion', agentId: 'a1' }, { questions: [] }, WEDGED, on('agent question'))).toEqual({ result: 'agent question' })
  expect(await caughtCall({ tool: 'Grep', agentId: 'a1' }, { pattern: 'x', path: '/w/slate' }, WEDGED, on('agent grep'))).toEqual({ result: 'agent grep' })
  // A subagent's shell command or file write is refused, never run.
  expect(await caughtCall({ tool: 'Bash', agentId: 'a1' }, { command: 'git commit -F msg.txt' }, WEDGED, on('agent bash'))).toEqual({ deny: HELD_WEDGED })
  expect(await caughtCall({ tool: 'Write', agentId: 'a1' }, { file_path: '/w/slate/app/page.tsx', content: 'x' }, WEDGED, on('agent write'))).toEqual({ deny: HELD_WEDGED })
  expect(sent).toEqual(['main write', 'agent question', 'agent grep'])
})

// #2788: on 2026-11-10 and 11 an edit to a since retired guard's register.ts (#2709) was held twice
// as a wording change, quoting a message the edit never touched. It wrapped a verdict in a helper
// that hands it straight back (`return await askUntraced(path, await broughtIn(path))`) and added a
// comment, and changed no string: measured on the real files, the message reading stopped following
// the verdict into broughtIn once it went through the helper, so that function's words read as gone.
// The comment's apostrophes played no part (the edit without its comment was held the same). Only
// the strings an edit adds or changes are judged now, so a change to code alone is never held.
const UNTRACED_BEFORE = [
  "import type { EngineInterface, Register } from 'claude-code'",
  'type Verdict = { pass: true } | { unchecked: string; untraced?: true }',
  'const PASS: Verdict = { pass: true }',
  'const broughtIn = async (path: string): Promise<Verdict> => {',
  '  if (!path) return { unchecked: `git could not name the repository ${path} is in, so what this edit brings could not be told` }',
  '  return PASS',
  '}',
  'const judge = async (path: string): Promise<Verdict> => {',
  '  return await broughtIn(path)',
  '}',
  'export const register: Register = on => {',
  "  on('tool.check', async ($: EngineInterface, e: { input: { file_path: string } }) => {",
  '    const v = await judge(e.input.file_path)',
  "    if ('unchecked' in v) return { deny: `Blocked: ${v.unchecked}` }",
  '    return {}',
  '  })',
  '}',
  '',
].join('\n')
const untracedWrapped = (helper: readonly string[]) => {
  const after = UNTRACED_BEFORE.replace('  return await broughtIn(path)\n}\n', ['  return await askUntraced(path, await broughtIn(path))', '}', '', ...helper, ''].join('\n'))
  if (after === UNTRACED_BEFORE) throw new Error('no edit')
  return after
}
const UNTRACED_HELPER = [
  "// An edit whose trace stopped at one of the guard's own limits stops there on every try, so it",
  "// is held for Dan to approve. Dan's approval lets that one edit through and no other.",
  'const askUntraced = async (path: string, v: Verdict): Promise<Verdict> => {',
  "  if (!('unchecked' in v) || !v.untraced || !path) return v",
  '  return PASS',
  '}',
]
test('#2788: wrapping a verdict in a helper and adding a comment with apostrophes, changing no string, passes', () => {
  expect(modHookTsChange([], 'register.ts', UNTRACED_BEFORE, untracedWrapped(UNTRACED_HELPER))).toBeUndefined()
  // The helper without its comment passes alike.
  expect(modHookTsChange([], 'register.ts', UNTRACED_BEFORE, untracedWrapped(UNTRACED_HELPER.slice(2)))).toBeUndefined()
})
test('#2788, #2845: the same change carrying new words for a message, or a message reworded or taken away, is named as words', () => {
  // The helper's comment beside a new message in a string: named for the string, never the comment.
  const told = untracedWrapped([...UNTRACED_HELPER.slice(0, 4), "  return { unchecked: 'Dan has not approved this edit yet' }", '}'])
  expect(modHookTsChange([], 'register.ts', UNTRACED_BEFORE, told)).toEqual({ words: 'Dan has not approved this edit yet' })
  // The message the helper is wrapped around, reworded in the same edit, and reworded with no helper.
  const reworded = untracedWrapped(UNTRACED_HELPER).replace('so what this edit brings could not be told', 'so what this edit brings is unknown')
  expect(changeOf([], 'register.ts', UNTRACED_BEFORE, reworded)).toBe('words')
  const rewordedAlone = UNTRACED_BEFORE.replace('so what this edit brings could not be told', 'so what this edit brings is unknown')
  expect(modHookTsChange([], 'register.ts', UNTRACED_BEFORE, rewordedAlone)).toEqual({ words: 'is in, so what this edit brings is unknown' })
  // A message's own words taken away, the helper beside it.
  const gone = untracedWrapped(UNTRACED_HELPER).replace('return { deny: `Blocked: ${v.unchecked}` }', 'return { deny: v.unchecked }')
  expect(changeOf([], 'register.ts', UNTRACED_BEFORE, gone)).toBe('words')
})

// #2847: a script file is read in the language the command runs it with, else by its extension.
test('#2847: scriptLanguage reads python and node scripts only, by the program, then the extension', () => {
  expect(scriptLanguage('/n/a.txt', 'python')).toBe('python')
  expect(scriptLanguage('/n/a.py', 'awk')).toBeUndefined()
  expect(scriptLanguage('/n/gen.py', undefined)).toBe('python')
  expect(scriptLanguage('/n/gen.mts', undefined)).toBe('node')
  expect(scriptLanguage('/n/tool', undefined)).toBeUndefined()
  expect(scriptLanguage('/n/run.sh', undefined)).toBeUndefined()
})

// #2847: the heredoc a script's text is handed in never ends early on a line of the script itself.
test('#2847: asProgram ends its heredoc on a word no line of the script is', () => {
  expect(asProgram('python', "print('x')")).toBe("python3 - <<'DESIGN_ROUND_GUARD_SCRIPT'\nprint('x')\nDESIGN_ROUND_GUARD_SCRIPT")
  const tricky = "a = 1\nDESIGN_ROUND_GUARD_SCRIPT\nb = 2\n"
  expect(asProgram('node', tricky)).toBe(`node - <<'DESIGN_ROUND_GUARD_SCRIPT_'\n${tricky}DESIGN_ROUND_GUARD_SCRIPT_`)
})

// #2855: the four routes #2847 left unread, each read by one pure reading the guard and its sweep share.
test('#2855: scriptOf finds a shell, python or node script a command runs, and never inline code or another language', () => {
  const of = (command: string) => pipelineIn(command, '/w', '/h').map(c => scriptOf(c))
  expect(of('bash x.sh a')).toEqual([{ word: 'x.sh', shell: true }])
  expect(of('sh -x /n/y.sh')).toEqual([{ word: '/n/y.sh', shell: true }])
  expect(of('source ./env.sh && . lib.sh')).toEqual([{ word: './env.sh', shell: true }, { word: 'lib.sh', shell: true }])
  expect(of('python3 gen.py && node b.mjs && ./run.sh')).toEqual([{ word: 'gen.py' }, { word: 'b.mjs' }, { word: './run.sh' }])
  expect(of("bash -c 'echo x' && python3 -c 'print(1)' && ruby x.rb && awk -f p.awk f && ls")).toEqual([undefined, undefined, undefined, undefined, undefined])
  expect(of("bash <<'EOF'\necho x\nEOF")).toEqual([undefined])
})

test('#2855: scriptPath follows a variable the command sets to one literal, and nothing it cannot be sure of', () => {
  expect(scriptPath('$N/step.py', 'N=/n/2845; python3 "$N/step.py"', '/w', '/h')).toBe('/n/2845/step.py')
  expect(scriptPath('${N}/step.py', 'export N=/n; python3 "${N}/step.py"', '/w', '/h')).toBe('/n/step.py')
  expect(scriptPath('$N/step.py', 'N=sub; python3 "$N/step.py"', '/w', '/h')).toBe('/w/sub/step.py')
  expect(scriptPath('$HOME/x.sh', 'bash $HOME/x.sh', undefined, '/h')).toBe('/h/x.sh')
  expect(scriptPath('$PWD/x.sh', 'bash $PWD/x.sh', '/w', '/h')).toBe('/w/x.sh')
  // Set nowhere, set two ways, set from a command's output, a loop's, a pattern, or relative where the folder is unknown.
  for (const [word, command, folder] of [
    ['$N/a.py', 'python3 "$N/a.py"', '/w'],
    ['$N/a.py', 'N=/a; N=/b; python3 "$N/a.py"', '/w'],
    ['$N/a.py', 'N=$(pwd); python3 "$N/a.py"', '/w'],
    ['$s/a.py', 'for s in /a /b; do python3 "$s/a.py"; done', '/w'],
    ['/n/*.py', 'python3 /n/*.py', '/w'],
    ['$PWD/x.sh', 'bash $PWD/x.sh', undefined],
    ['x.sh', 'bash x.sh', undefined],
  ] as [string, string, string | undefined][])
    expect({ word, command, path: scriptPath(word, command, folder, '/h') }).toEqual({ word, command, path: undefined })
})

// #3214: `python3 $N/gen.py`, gen.py writing app/page.tsx and nothing in the command setting N, ran
// unheld on 2026-11-18: scriptPath could not place the script, so the guard never read what it
// writes. A script the guard cannot find it cannot read, so one spelled through a variable the
// command never sets is given as unread, and the guard holds it as could not check.
test('#3214: neverSetVariable names the variable a script word is spelled through that the command never sets', () => {
  for (const [word, command] of [
    ['$N/gen.py', 'python3 $N/gen.py'],
    ['${N}/gen.py', 'cd /w && python3 "${N}/gen.py" --dry | sort -N'],
    ['$N', 'bash $N'],
    ['/n/$N/gen.py', 'python3 /n/$N/gen.py'],
    ['$A/$N/gen.py', 'A=/n; python3 $A/$N/gen.py'],
    ['${N:-/n}/gen.py', 'python3 "${N:-/n}/gen.py"'],
    // A flag, a longer name and a value holding the name set nothing.
    ['$N/gen.py', 'NN=/n; python3 $N/gen.py --N -N x=N'],
  ] as [string, string][])
    expect({ word, command, v: neverSetVariable(word, command) }).toEqual({ word, command, v: 'N' })
  // Named outright, through HOME or PWD, through a parameter of the script, or through a variable
  // the command names as a word of its own, so may set: to one literal (scriptPath places it), or
  // any other way (a command's output, a loop, read, a default it assigns).
  for (const [word, command] of [
    ['/n/gen.py', 'python3 /n/gen.py'],
    ['gen.py', 'cd "$SOMEWHERE" && python3 gen.py'],
    ['$HOME/gen.py', 'python3 $HOME/gen.py'],
    ['$PWD/gen.py', 'python3 $PWD/gen.py'],
    ['$1', 'bash "$1"'],
    ['$N/gen.py', 'N=/n; python3 $N/gen.py'],
    ['$N/gen.py', 'export N=/n\npython3 "$N/gen.py"'],
    ['$N/gen.py', 'N=$(pwd); python3 $N/gen.py'],
    ['$N/gen.py', 'for N in /a /b; do python3 $N/gen.py; done'],
    ['$N/gen.py', 'read -r N < f; python3 $N/gen.py'],
    ['$N/gen.py', ': "${N:=/n}"; python3 $N/gen.py'],
  ] as [string, string][])
    expect({ word, command, v: neverSetVariable(word, command) }).toEqual({ word, command, v: undefined })
})

test('#3214: scriptsRunIn gives a script spelled through a variable the command never sets as unread, saying which', async () => {
  const disk: Record<string, string> = { '/n/gen.py': "open('/w/app/page.tsx', 'w').write('x')\n", '/n/outer.sh': 'python3 "$TOOLS/gen.py"\n', '/n/set.sh': 'TOOLS=/n\npython3 "$TOOLS/gen.py"\n' }
  const io: ScriptIo = {
    pipeline: async (command, cwd) => pipelineIn(command, cwd, '/h'),
    writes: async (command, cwd) => commandWrites(command, cwd, '/h'),
    stat: async p => (p in disk ? { kind: 'file', size: (disk[p] ?? '').length } : undefined),
    read: async p => disk[p] as string,
  }
  const said = async (command: string) => (await scriptsRunIn(io, command, '/w', '/h')).map(r => ('unread' in r ? `${r.word}: ${r.unread}` : `${r.word}: ${r.lang}`))
  expect(await said('python3 $N/gen.py')).toEqual([`$N/gen.py: ${scriptNeverSet('$N/gen.py', 'N')}`])
  expect(scriptNeverSet('$N/gen.py', 'N')).toBe('$N/gen.py could not be read for the files its own code writes (the command never sets N, so where the script is could not be followed)')
  // Said once for a script run twice.
  expect(await said('python3 "${N}/gen.py" && python3 "${N}/gen.py"')).toEqual([`\${N}/gen.py: ${scriptNeverSet('${N}/gen.py', 'N')}`])
  // Still read: a folder the command, or the script, sets to one literal, and a script named outright.
  expect(await said('N=/n; python3 $N/gen.py')).toEqual(['$N/gen.py: python'])
  expect(await said('python3 /n/gen.py')).toEqual(['/n/gen.py: python'])
  expect(await said('bash /n/set.sh')).toEqual(['/n/set.sh: shell', '$TOOLS/gen.py, which /n/set.sh runs,: python'])
  // As before, not read and not given: a variable the command sets another way, a loop's, and one a
  // shell script the command runs never sets in its own text (a file it sources, or what runs it, may).
  expect(await said('N=$(pwd); python3 $N/gen.py')).toEqual([])
  expect(await said('for d in /n; do python3 "$d/gen.py"; done')).toEqual([])
  expect(await said('bash /n/outer.sh')).toEqual(['/n/outer.sh: shell'])
})

test('#2855: heredocFile gives the text cat writes from a heredoc into a file mod-kit places, and nothing it cannot be sure of', () => {
  const each = (command: string) => {
    const { files } = commandWrites(command, '/w', '/h')
    return pipelineIn(command, '/w', '/h').map(c => heredocFile(c, files))
  }
  expect(each("cat > /n/a.py <<'EOF'\nprint($x)\nEOF")).toEqual([{ path: '/n/a.py', text: 'print($x)\n' }])
  expect(each('cat <<EOF > b.py\nprint(1)\nEOF')).toEqual([{ path: '/w/b.py', text: 'print(1)\n' }])
  expect(each("N=/n; cat > \"$N/c.py\" <<'EOF'\nprint(2)\nEOF")).toEqual([{ path: '/n/c.py', text: 'print(2)\n' }])
  // A body the shell may change, an append, cat given a file too, another writer, and a file mod-kit cannot place.
  for (const command of ['cat > /n/d.py <<EOF\nprint("$HOME")\nEOF', "cat >> /n/e.py <<'EOF'\nprint(1)\nEOF", "cat - x > /n/f.py <<'EOF'\n1\nEOF", "tee /n/g.sh <<'EOF'\necho hi\nEOF", "echo x > /n/h.py", "cat > \"$(pwd)/i.py\" <<'EOF'\n1\nEOF"])
    expect({ command, made: each(command).filter(Boolean) }).toEqual({ command, made: [] })
})

test('#2855: importedFiles names the local modules python and node would load, in the order each tries them', () => {
  expect(importedFiles('python', 'import json, helper as h\nfrom tools.edit import go\nfrom . import sib\nfrom ..up import x\n# import nothing\n', '/n/sub', '/n')).toEqual([
    ['/n/json.py', '/n/json/__init__.py'],
    ['/n/helper.py', '/n/helper/__init__.py'],
    ['/n/tools/edit.py', '/n/tools/edit/__init__.py'],
    ['/n/tools/edit/go.py', '/n/tools/edit/go/__init__.py'],
    ['/n/sub/sib.py', '/n/sub/sib/__init__.py'],
    ['/n/up.py', '/n/up/__init__.py'],
    ['/n/up/x.py', '/n/up/x/__init__.py'],
  ])
  const node = importedFiles('node', "import { a } from './lib/a.mjs'\nconst b = require('../b')\nawait import('./c.js')\nimport 'node:fs'\nimport x from 'pkg'\n", '/n/s', '/n/s')
  expect(node.map(g => g[0])).toEqual(['/n/s/lib/a.mjs', '/n/b', '/n/s/c.js'])
  expect(node[0]?.[1]).toBe('/n/s/lib/a.mts')
  expect(node[1]).toContain('/n/b.ts')
  expect(node[1]).toContain('/n/b/index.js')
})

test('#2855: scriptsRunIn reads each route, says which script brought a file in, and stops at its limits', async () => {
  const disk: Record<string, string> = {
    '/n/edit.sh': 'sed -i "" s/a/b/ /w/app/x.css\nbash /n/inner.sh\n',
    '/n/inner.sh': 'bash /n/deeper.sh\n',
    '/n/deeper.sh': 'echo deep\n',
    '/n/step.py': 'import helper\n',
    '/n/helper.py': 'import step\n',
    '/n/locked.py': 'UNREADABLE',
    '/n/tool': 'binary',
  }
  const io: ScriptIo = {
    pipeline: async (command, cwd) => pipelineIn(command, cwd, '/h'),
    writes: async (command, cwd) => commandWrites(command, cwd, '/h'),
    stat: async p => (p in disk ? { kind: 'file', size: (disk[p] ?? '').length } : undefined),
    read: async p => {
      if (disk[p] === 'UNREADABLE') throw new Error('EACCES')
      return disk[p] as string
    },
  }
  const runs = await scriptsRunIn(io, "bash /n/edit.sh && python3 /n/step.py && N=/n; python3 $N/locked.py; ./tool; cat > /n/new.sh <<'EOF'\necho fresh\nEOF\nbash /n/new.sh", '/n', '/h')
  expect(runs.map(r => ('unread' in r ? `${r.word}: unread` : `${r.word}: ${r.lang}`))).toEqual([
    '/n/edit.sh: shell',
    '/n/inner.sh, which /n/edit.sh runs,: shell',
    '/n/step.py: python',
    'helper.py, which /n/step.py imports,: python',
    '$N/locked.py: unread',
    '/n/new.sh: shell',
  ])
  expect(runs.find(r => 'text' in r && r.path === '/n/new.sh')).toMatchObject({ text: 'echo fresh\n' })
  // deeper.sh is past SHELL_DEPTH; step.py, imported back by helper.py, is read once; ./tool has no script extension.
  expect(runs.some(r => r.word.startsWith('/n/deeper.sh'))).toBe(false)
  // Past MODULES_MAX the rest of a script's imports are not read.
  const many: Record<string, string> = { '/m/main.py': Array.from({ length: MODULES_MAX + 5 }, (_, i) => `import m${i}`).join('\n') }
  for (let i = 0; i < MODULES_MAX + 5; i++) many[`/m/m${i}.py`] = ''
  const wide = await scriptsRunIn({ ...io, stat: async p => (p in many ? { kind: 'file', size: 1 } : undefined), read: async p => many[p] as string }, 'python3 /m/main.py', '/m', '/h')
  expect(wide.length).toBe(1 + MODULES_MAX)
})

// #3442: `bash -n x.sh` checks the script's syntax and runs none of it (measured 2026-11-26 on the
// personal MacBook, in bash 3.2, zsh 5.9, macOS sh, dash and ksh93). mod-kit's reader gave it as a
// run of the script, so every write the script's text names was judged for a command that writes none.
test('#3442: scriptsRunIn reads no script a shell is told only to check', async () => {
  const disk: Record<string, string> = { '/n/edit.sh': 'sed -i "" s/a/b/ /w/app/x.css\n' }
  const io: ScriptIo = {
    pipeline: async (command, cwd) => pipelineIn(command, cwd, '/h'),
    writes: async (command, cwd) => commandWrites(command, cwd, '/h'),
    stat: async p => (p in disk ? { kind: 'file', size: (disk[p] ?? '').length } : undefined),
    read: async p => disk[p] as string,
  }
  const read = async (command: string) => (await scriptsRunIn(io, command, '/n', '/h')).map(r => r.word)
  for (const command of ['bash -n /n/edit.sh', 'sh -n edit.sh', 'zsh -n ./edit.sh', 'bash -o noexec /n/edit.sh']) expect([command, await read(command)]).toEqual([command, []])
  // The run after the check is read, and so is a check taken back.
  expect(await read('bash -n /n/edit.sh && bash /n/edit.sh')).toEqual(['/n/edit.sh'])
  expect(await read('bash -n +n /n/edit.sh')).toEqual(['/n/edit.sh'])
})

test('#2847: mentionedModHookFiles names only a mod hook TypeScript file, never a declaration or other .ts', () => {
  expect(mentionedModHookFiles("p = '/w/r/payload/mods/demo/hooks/rules.ts'; q = 'src/app.ts'; d = 'mods/x/hooks/t.d.ts'; m = \"mods/y/hooks/a.mts\"")).toEqual(['/w/r/payload/mods/demo/hooks/rules.ts', 'mods/y/hooks/a.mts'])
})

// #2830: what may run before or beside a measured restore without moving what it reads from.
test('#2830: leavesGitAlone passes reading commands and git reading only; pathRestore is a restore of named paths', () => {
  expect(leavesGitAlone(['cat', 'list'], undefined)).toBe(true)
  expect(leavesGitAlone(['/bin/echo', 'x'], undefined)).toBe(true)
  expect(leavesGitAlone(['git', 'status'], { sub: 'status' })).toBe(true)
  for (const sub of ['add', 'switch', 'fetch', 'commit', 'checkout', 'stash', 'branch']) expect({ sub, alone: leavesGitAlone(['git', sub], { sub }) }).toEqual({ sub, alone: false })
  expect(leavesGitAlone(['python3', 'x.py'], undefined)).toBe(false)
  expect(leavesGitAlone(['xargs', 'git'], undefined)).toBe(false)
  expect(pathRestore({ sub: 'restore', args: ['--staged', 'f'] })).toBe(true)
  expect(pathRestore({ sub: 'checkout', args: ['HEAD', '--', 'f'] })).toBe(true)
  expect(pathRestore({ sub: 'checkout', args: ['main', 'f'] })).toBe(true)
  expect(pathRestore({ sub: 'checkout', args: ['main'] })).toBe(false)
  // A `--` with nothing after it names no path, so the checkout switches branch and is no
  // restore, as gitMove reads it (lessons review of 371124a).
  expect(pathRestore({ sub: 'checkout', args: ['main', '--'] })).toBe(false)
  expect(pathRestore({ sub: 'checkout', args: ['--'] })).toBe(false)
  expect(pathRestore({ sub: 'checkout', args: ['-b', 'x', 'main'] })).toBe(false)
  expect(pathRestore({ sub: 'switch', args: ['main'] })).toBe(false)
  expect([indexSource(''), indexSource(':2'), indexSource('HEAD'), indexSource('origin/main')]).toEqual([true, true, false, false])
})

// #3280: a restore is read as putting a whole file back only where its words are the source and the
// paths alone. Measured with git 2.51.1: `-p` with answers piped in puts back part of a file.
test('#3280: wholeRestoreSource gives the source of a restore whose words are its source and paths alone', () => {
  const source = (sub: string, ...args: string[]) => wholeRestoreSource({ sub, args })
  expect(source('checkout', 'origin/main', '--', 'f.tsx')).toBe('origin/main')
  expect(source('checkout', 'origin/main', 'f.tsx', 'g.tsx')).toBe('origin/main')
  expect(source('checkout', 'origin/main', '--', '-odd.tsx', '--')).toBe('origin/main')
  expect(source('restore', '--source', 'origin/main', '--', 'f.tsx')).toBe('origin/main')
  expect(source('restore', '--source=origin/main', 'f.tsx')).toBe('origin/main')
  expect(source('restore', '-s', 'origin/main', 'f.tsx', 'g.tsx')).toBe('origin/main')
  expect(source('restore', 'f.tsx', '--source', 'origin/main')).toBe('origin/main')
  const none: string[][] = [
    // No source, no path, or more than the two.
    ['checkout', '--', 'f.tsx'],
    ['checkout', 'origin/main'],
    ['checkout', 'origin/main', '--'],
    ['checkout', 'origin/main', 'other', '--', 'f.tsx'],
    ['restore', 'f.tsx'],
    ['restore', '--source', 'origin/main'],
    ['restore', '--source'],
    ['restore', '--source=', 'f.tsx'],
    ['restore', '--source', 'origin/main', '-s', 'other', 'f.tsx'],
    ['restore', '--source', 'origin/main', '--source', 'origin/main', 'f.tsx'],
    // Any other option, the ones that only say where to write included: none is read as harmless.
    ['checkout', '-p', 'origin/main', '--', 'f.tsx'],
    ['checkout', '--patch', 'origin/main', '--', 'f.tsx'],
    ['checkout', '-f', 'origin/main', '--', 'f.tsx'],
    ['checkout', '-q', 'origin/main', 'f.tsx'],
    ['checkout', '--ours', '--', 'f.tsx'],
    ['checkout', '-b', 'x', 'origin/main'],
    ['checkout', '--pathspec-from-file=list', 'origin/main'],
    ['restore', '-p', '--source', 'origin/main', 'f.tsx'],
    ['restore', '--source', 'origin/main', '--staged', '--worktree', 'f.tsx'],
    ['restore', '-s', 'origin/main', '-W', 'f.tsx'],
    ['restore', '-sorigin/main', 'f.tsx'],
    ['restore', '--sourc=origin/main', 'f.tsx'],
    ['restore', '--source', '--', 'f.tsx'],
    // A source spelled like an option is never handed to git.
    ['restore', '--source=--textconv', 'f.tsx'],
    // No restore at all.
    ['switch', 'origin/main'],
    ['reset', '--hard', 'origin/main'],
    ['show', 'origin/main:f.tsx'],
  ]
  for (const [sub, ...args] of none) expect({ sub, args, source: source(sub as string, ...args) }).toEqual({ sub, args, source: undefined })
  expect(wholeRestoreSource(undefined)).toBe(undefined)
})

test('#3280: runsAfter gives the commands that run only once the last restore has finished', () => {
  const R = ['git', 'checkout', 'origin/main', '--', 'f.tsx']
  const TEST = ['claude', 'plugin', 'test', 'x']
  const after = (commands: { words: string[]; pipedFrom?: string[] }[], last = 0) => [...runsAfter(commands, last)]
  // A pipe between commands that both run after it.
  expect(after([{ words: R }, { words: TEST }, { words: ['tail', '-5'], pipedFrom: TEST }])).toEqual([1, 2])
  expect(after([{ words: ['git', 'status'] }, { words: R }], 1)).toEqual([])
  // Piped from the restore, straight or through another command, runs beside it; what follows unpiped runs after.
  expect(after([{ words: R }, { words: ['cat'], pipedFrom: R }, { words: ['git', 'fetch'], pipedFrom: ['cat'] }, { words: ['bun', 'test'] }])).toEqual([3])
  // Piped from words that are no command after it is not placed after.
  expect(after([{ words: R }, { words: ['git', 'fetch'], pipedFrom: ['git', 'log'] }])).toEqual([])
  // Words that name both a command beside it and one after it place nothing piped from them after.
  expect(after([{ words: ['cat'] }, { words: R, pipedFrom: ['cat'] }, { words: ['cat'] }, { words: ['git', 'fetch'], pipedFrom: ['cat'] }], 1)).toEqual([2])
  expect(after([{ words: R }, { words: ['tee', 'x'], pipedFrom: R }, { words: ['tee', 'x'] }, { words: ['git', 'fetch'], pipedFrom: ['tee', 'x'] }])).toEqual([2])
})

test('#3280: plainLine is a line that groups nothing, whatever it quotes', () => {
  for (const line of ['git checkout origin/main -- f.tsx && claude plugin test x 2>&1 | tail -5', 'git status; git checkout origin/main -- f.tsx || echo no', 'git checkout origin/main -- f.tsx\nbun test | head -3', 'git checkout origin/main -- format.tsx && echo finished'])
    expect({ line, plain: plainLine(line) }).toEqual({ line, plain: true })
  for (const line of [
    '{ git checkout origin/main -- f.tsx; } | git fetch',
    '(git checkout origin/main -- f.tsx) | git fetch',
    'git checkout origin/main -- f.tsx > >(git fetch)',
    'X=$(git fetch) git checkout origin/main -- f.tsx',
    'git checkout origin/main -- f.tsx `git fetch`',
    'if git checkout origin/main -- f.tsx; then true; fi | git fetch',
    'while git checkout origin/main -- f.tsx; do break; done | git fetch',
    'for f in a; do git checkout origin/main -- f.tsx; done | git fetch',
    'case x in x) git checkout origin/main -- f.tsx;; esac | git fetch',
    'time git checkout origin/main -- f.tsx | git fetch',
    'coproc git fetch; git checkout origin/main -- f.tsx',
    // Without the reader's account of the line (#3401), a parenthesis in quotes is not told from
    // one that groups, so it is none either.
    'git checkout origin/main -- f.tsx && bun test | grep -E "(fail|pass)"',
  ])
    expect({ line, plain: plainLine(line) }).toEqual({ line, plain: false })
})

// #3401: #3280 read any brace, parenthesis or backtick anywhere in a call's text as grouping, so a
// restore followed by a test piped through a search for "(fail|pass)" stayed held, though the
// parentheses sit inside a quoted pattern and group nothing. Given mod-kit's own reading of the
// line, plainLine reads such a character as text where that reading shows it so: every command is
// one of the line's own, standing where it is typed, and every word holding such a character is
// marked as handed on as its characters (literal: each pattern character quoted or after a
// backslash, and no $ or backtick anywhere in the word). Each line here is read by the real reader.
const R_3401 = 'git checkout origin/main -- f.tsx'
const plain3401 = (line: string) => plainLine(line, pipeline(line))

test('#3401: plainLine reads a quoted or escaped grouping character as text, by the reader\'s own account of the line', () => {
  for (const line of [
    // The issue's own line, and the same in single quotes.
    `${R_3401} && bun test | grep -E "(fail|pass)"`,
    `${R_3401} && bun test | grep -E '(fail|pass)'`,
    `${R_3401} && claude plugin test payload/mods/demo 2>&1 | grep -E "(fail|pass)" | tail -3`,
    // In a word of the test command itself.
    `${R_3401} && bun test -t "renders (dark)" | tail -3`,
    // A quoted brace, and one in a program for awk or sed, which no shell reads.
    `${R_3401} && bun test | grep -E "a{2}"`,
    `${R_3401} && bun test | awk '{print}'`,
    `${R_3401} && bun test | sed -E 's/(pass|fail)/x/'`,
    // After a backslash, outside quotes and inside double quotes.
    `${R_3401} && bun test | grep fail\\(`,
    `${R_3401} && bun test | grep "\\(a\\)"`,
    // Joined by each of the ways a plain line joins commands, a cd and a setting beside them.
    `${R_3401}; bun test | grep "(x)"`,
    `${R_3401}\nbun test | grep "(x)"`,
    `${R_3401} || bun test | grep "(x)"`,
    `cd app && ${R_3401} && CI=1 bun test $FILES | grep "(x)"`,
  ])
    expect({ line, plain: plain3401(line) }).toEqual({ line, plain: true })
  // What already was plain still is, with the reading or without.
  for (const line of [`${R_3401} && claude plugin test x 2>&1 | tail -5`, `git status; ${R_3401} || echo no`])
    expect({ line, plain: plain3401(line), unread: plainLine(line) }).toEqual({ line, plain: true, unread: true })
})

test('#3401: plainLine still reads as grouping every character the shell, or a shell handed the text, may read as one', () => {
  for (const line of [
    // A subshell, a group, and a pipe out of either.
    `${R_3401} && (bun test | tail)`,
    `(${R_3401}) | git fetch`,
    `${R_3401} && { bun test; } | tail`,
    `{ ${R_3401}; } | git fetch`,
    `${R_3401} && bun test | grep "(x)" | (cat)`,
    `${R_3401} && { bun test | grep "(x)"`,
    // A quote that never ends. Bash and zsh refuse the command it is in and run nothing of it
    // (measured 2026-11-22, bash 3.2 and zsh 5.9, as -c text and through eval), and until #3491 the
    // line was read as plain on that. But a quote this reader sees no end to is most often one it
    // has misread (#3491: `x=$'it\'s'` read that way and hid every command after it), so the reader
    // marks the command it stands in unread, and a line holding one is not plain.
    `${R_3401} && bun test | grep '(x`,
    // A command the shell runs to fill in a word: double quotes do not stop one.
    `${R_3401} && echo $(git fetch) | tail`,
    `${R_3401} && echo "$(git fetch)" | tail`,
    `${R_3401} && echo \`git fetch\` | tail`,
    `${R_3401} && echo "\`git fetch\`" | tail`,
    `X=$(git fetch) ${R_3401} | tail`,
    // A backtick in single quotes runs nothing, but no mark of the reader says so of a word.
    `${R_3401} && echo '\`git fetch\`' | tail`,
    // A process substitution, bash's and zsh's.
    `${R_3401} && diff <(git fetch) f.tsx | tail`,
    `${R_3401} > >(git fetch)`,
    `${R_3401} && diff =(git fetch) f.tsx | tail`,
    // Arithmetic, as a word and as a command.
    `${R_3401} && echo $((1+2)) | tail`,
    `${R_3401} && (( x = 1 )) | tail`,
    // A function, and what it is defined with.
    `f() { bun test; }; ${R_3401} && f | tail`,
    `function f { bun test; }; ${R_3401} && f | grep "(x)"`,
    // Every word a compound command is written with, a quoted parenthesis beside it.
    `if ${R_3401}; then bun test | grep "(x)"; fi`,
    `for f in a; do ${R_3401}; done | grep "(x)"`,
    `while ${R_3401}; do break; done | grep "(x)"`,
    `until ${R_3401}; do break; done | grep "(x)"`,
    `case x in x) ${R_3401};; esac | grep "(x)"`,
    `select f in a; do ${R_3401}; done | grep "(x)"`,
    `coproc git fetch; ${R_3401} | grep "(x)"`,
    `time ${R_3401} | grep "(x)"`,
    // A heredoc's body, read by the shell or not.
    `${R_3401} && cat <<EOF | tail\n(a)\nEOF`,
    `${R_3401} && cat <<'EOF' | tail\n(a)\nEOF`,
    // Text another shell reads is code: eval, a shell's -c, xargs, find's -exec, ssh, a trap, an alias.
    `${R_3401} && eval "(bun test)" | tail`,
    `${R_3401} && bash -c '(bun test) | tail'`,
    `${R_3401} && bash -c 'echo "(x)"' | tail`,
    `${R_3401} && sh -c 'echo "(x)"' | tail`,
    `${R_3401} && zsh -c 'echo "(x)"' | tail`,
    `${R_3401} && bash -c "$X" | grep "(x)"`,
    `${R_3401} && ls | xargs -I'{}' echo '{}'`,
    `${R_3401} && find . -exec echo '{}' \\; | tail`,
    `${R_3401} && ssh host '(x)' | tail`,
    `${R_3401} && trap '(x)' EXIT | tail`,
    `${R_3401} && alias x='(a)' | tail`,
    // A command run behind another (the reader says which, never whether that one is a shell).
    `${R_3401} && timeout 5 bun test | grep "(x)"`,
    `${R_3401} && sudo bun test | grep "(x)"`,
    `${R_3401} && rtk proxy bun test | grep "(x)"`,
    // A parenthesis in an unquoted pattern, and braces that make more words.
    `${R_3401} && ls @(a|b) | tail`,
    `${R_3401} && ls !(x) | tail`,
    `${R_3401} && ls *(.) | tail`,
    `${R_3401} && ls {a,b} | tail`,
    `${R_3401} && ls a{1,2}.tsx | grep "(x)"`,
    // Inside a test, a parenthesis groups what is tested.
    `${R_3401} && [[ ( -n a ) ]] | tail`,
    // A word holding a $ is never read as text: in double quotes the shell expands it, and for one
    // in single quotes no mark of the reader says its braces are quoted too (awk's own program).
    `${R_3401} && echo "$HOME (x)" | tail`,
    `${R_3401} && bun test | grep "\${X}(a)"`,
    `${R_3401} && bun test | awk '{print $1}'`,
    // The reader does not read a $'...' string, whose \\' does not end it: here the shell runs the
    // group, and the reader gives one quoted word. Any line holding such a string is not plain.
    `${R_3401} && echo $'\\' x' | (git fetch; cat) #'`,
    `${R_3401} && echo $'(a)' | tail`,
    `${R_3401} && bun test | grep 'x$' | grep "(a)"`,
    // What the reader leaves out of a command's words: a comment, and a setting's value.
    `${R_3401} && bun test | tail # (x)`,
    `${R_3401} && bun test | grep "(x)" # \`git fetch\``,
    `${R_3401} && X="(a)" bun test | tail`,
  ])
    expect({ line, plain: plain3401(line) }).toEqual({ line, plain: false })
  // No reading given, as when the reader could not read the line.
  expect(plainLine(`${R_3401} && bun test | grep "(x)"`)).toBe(false)
  // A reading that does not account for the text: a mark this rule does not know, a word with the
  // character and no mark, a character no word holds, and a word holding one more than the text.
  const line = `${R_3401} && bun test | grep "(x)"`
  const read = [{ words: ['git', 'checkout', 'origin/main', '--', 'f.tsx'] }, { words: ['bun', 'test'] }, { words: ['grep', '(x)'], pipedFrom: ['bun', 'test'], literal: [false, true] }]
  expect(plainLine(line, read)).toBe(true)
  expect(plainLine(line, read.map((c, i) => (i === 1 ? { ...c, groupedSomeNewWay: true } : c)))).toBe(false)
  for (const mark of ['substitution', 'arithmetic', 'xargs', 'proxied'])
    expect({ mark, plain: plainLine(line, read.map((c, i) => (i === 2 ? { ...c, [mark]: true } : c))) }).toEqual({ mark, plain: false })
  for (const mark of ['behind', 'found', 'heredocs', 'derived', 'worked', 'compares'])
    expect({ mark, plain: plainLine(line, read.map((c, i) => (i === 2 ? { ...c, [mark]: [] } : c))) }).toEqual({ mark, plain: false })
  expect(plainLine(line, read.map((c, i) => (i === 2 ? { ...c, unread: 'run as text by eval' } : c)))).toBe(false)
  expect(plainLine(line, read.map(c => ({ words: c.words, pipedFrom: c.pipedFrom })))).toBe(false)
  expect(plainLine(line, read.map((c, i) => (i === 2 ? { ...c, literal: [false, false] } : c)))).toBe(false)
  expect(plainLine(line, read.slice(0, 2))).toBe(false)
  expect(plainLine(line, [...read, { words: ['echo', '(y)'], literal: [false, true] }])).toBe(false)
  expect(plainLine(`${line} | grep ")("`, [...read, { words: ['grep', '(('], literal: [false, true] }])).toBe(false)
})

test('#3280: holdsAsFile reads git ls-tree as holding exactly the one file asked for', () => {
  const sha = 'a'.repeat(40)
  expect(holdsAsFile(`100644 blob ${sha}\tapp/page.tsx\0`, 'app/page.tsx')).toBe(true)
  expect(holdsAsFile(`100755 blob ${sha}\todd dir/b c.tsx\0`, 'odd dir/b c.tsx')).toBe(true)
  expect(holdsAsFile(`100644 blob ${'a'.repeat(64)}\tapp/page.tsx\0`, 'app/page.tsx')).toBe(true)
  for (const listed of [
    '',
    `040000 tree ${sha}\tapp/page.tsx\0`,
    `160000 commit ${sha}\tapp/page.tsx\0`,
    `100644 blob ${sha}\tapp/Page.tsx\0`,
    `100644 blob ${sha}\tapp/page.tsx.bak\0`,
    `100644 blob ${sha}\tapp/page.tsx`,
    `100644 blob ${sha}\tapp/page.tsx\0` + `100644 blob ${sha}\tapp/page.tsx/x\0`,
    `100644 blob ${sha.slice(1)}\tapp/page.tsx\0`,
    `100644 blob ${sha} app/page.tsx\0`,
  ])
    expect({ listed, holds: holdsAsFile(listed, 'app/page.tsx') }).toEqual({ listed, holds: false })
})

test('#3280: restoredSaid names the file, the source, and the commit of the default branch it was read against', () => {
  const said = restoredSaid('app/page.tsx', 'origin/main', 'refs/remotes/origin/main', 'd'.repeat(40))
  expect(said).toContain('app/page.tsx')
  expect(said).toContain('origin/main')
  expect(said).toContain('(refs/remotes/origin/main at dddddddddddd)')
  expect(said).toContain('byte for byte')
})

// #2924: a shell script's arguments are not judged as writes only where argumentUnreached finds no
// route by which one may reach a write. Each route below is named by its own reason, so a control
// held in the register tests is known to be held by the rule meant to hold it.
// The script's text goes to mod-kit's readers as it is written (#3021): they keep a `[[ ]]` test
// whole and read a trap's text as the commands it runs, which this guard did for itself until then
// (joinTests and trapBodies, each with a case it read wrong: `trap -- text` ran `--`).
const unreached = (text: string, sourced = true): string | undefined =>
  argumentUnreached(commandWrites(text, '/s', '/h'), pipelineIn(text, '/s', '/h') as readonly RunCommand[], word => tempWord(word, text), () => sourced)
const BASE_2924 = 'like="${2:-}"\nif [[ -z "$like" || "$like" == --* ]]; then exit 2; fi\nwhile [[ $# -gt 0 && -n "$(printf %s "$1")" ]]; do shift; done\ngh_err="$(mktemp)"\ntrap \'rm -f "$gh_err"\' EXIT\nout=""\nout="$(mktemp)"\ngh issue list >"$out" 2>"$gh_err"\nprintf \'%s\' "$like" | python3 -c \'import sys; print(sys.stdin.read(), sys.argv[1])\' "$like"\nprintf x > /s/notes.txt\nsource /s/catch-all.sh\n'

test('#2924: argumentUnreached finds no route to a write in a script writing only its own names and temporary files', () => {
  expect(unreached(BASE_2924)).toBeUndefined()
  for (const [add, why] of [
    ['cp a "$like"', 'it writes $like'],
    ["printf x > \"$like\"", 'it writes $like'],
    ['rm -f "$like"', 'it writes $like'],
    [': > "$like"', 'it writes $like'],
    ['gh_err="$like"', 'it writes $gh_err'],
    ['keep() { cat > "$1"; }', 'it writes $1'],
    ['cd "$like" && printf x > index.html', 'it writes index.html'],
    ['git checkout -- "$like"', 'it writes $like'],
    ['eval "$like"', 'it runs eval'],
    ['"$@"', 'it runs a command named by $@'],
    ['$like', 'it runs a command named by $like'],
    // A command after a test is never joined into it.
    ['[[ -n "$like" ]] && "$1"', 'it runs a command named by $1'],
    ['[[ -n "$(printf "%s" "$like")" ]] || eval "$like"', 'it runs eval'],
    ['[[ -n "$like" &&\n "$1" ]] && "$1"', 'it runs a command named by $1'],
    ["trap 'rm -f \"$like\"' EXIT", 'it writes $like'],
    ['trap "$cleanup" EXIT', 'it runs a command named by $cleanup'],
    ['python3 -c \'import sys; open(sys.argv[1], "w")\' "$like"', 'it runs a program whose writes are not all named'],
    ['bash /s/other.sh "$like"', 'it runs /s/other.sh'],
    // mod-kit's pipeline gives the command xargs runs, and the name it fills in is no path.
    ['printf %s "$like" | xargs -I{} cp a {}', 'it writes {}'],
    ['printf %s "$like" | xargs rm', 'it runs a program whose writes are not all named'],
    // mod-kit's pipeline gives the command `command` runs, as it does xargs's.
    ['command cp a "$like"', 'it writes $like'],
    ['exec > "$like"', 'it writes $like'],
    ['alias ls="cp a $like"', 'it runs alias'],
    // #3021 (the lessons review of PR #3008): setsid, flock, ionice and arch only run the command
    // after them, which mod-kit's pipeline now gives; one left standing as the command, and ssh,
    // which runs its command on another machine, is held as running what nobody reads.
    ['setsid cp a "$like"', 'it writes $like'],
    ['flock /tmp/s.lock cp a "$like"', 'it writes $like'],
    ['ionice -c 3 cp a "$like"', 'it writes $like'],
    ['arch -arm64 cp a "$like"', 'it writes $like'],
    ['setsid', 'it runs setsid'],
    ['flock -n 9', 'it runs flock'],
    ['ionice -p "$like"', 'it runs ionice'],
    ['[ "$(arch)" = arm64 ]', 'it runs arch'],
    ['ssh host "cp a $like"', 'it runs ssh'],
    // A trap's text after `--` is its text, never the `--`.
    ["trap -- 'rm -f \"$like\"' EXIT", 'it writes $like'],
    // What mod-kit marks unread is a route too: a trap whose text the shell expands runs whatever
    // the value holds, read again as commands, and a word rtk's proxy splits is the command itself.
    ['trap "echo $like" EXIT', 'it runs a command setting a trap whose text the shell expands, so what it runs later cannot be read'],
    ['rtk proxy "echo $like"', 'it runs a command split by rtk proxy from one word the shell expands, so what it runs cannot be read'],
    // A test kept whole names no command by its values, and one after it is still read.
    ['[[ -z "$like" || "$like" == --* ]] && cp a "$like"', 'it writes $like'],
  ] as [string, string][])
    expect({ add, why: unreached(`${BASE_2924}${add}\n`) }).toEqual({ add, why })
  // A file sourced that could not be read whole.
  expect(unreached(BASE_2924, false)).toBe('it sources /s/catch-all.sh, which could not be read whole')
  // `command -v` only looks a name up.
  expect(unreached(`${BASE_2924}command -v gh >/dev/null 2>&1\n`)).toBeUndefined()
  // #3323: the reader gives a program it does not know as a run marked unknown wherever it is handed
  // a word that spells a path (`exit 2` and `gh issue list` above are two). That rule covers a
  // command as typed. A script's own text is read here as it was before it, so such a run is no
  // route, or nearly every script would be held again and #2924 undone. A module or a tool handed
  // the script's words is still one.
  expect(commandWrites('mystery /s/app/page.tsx', '/s', '/h').runs?.map(r => r.unknown)).toEqual([true])
  expect(unreached(`${BASE_2924}mystery /s/app/page.tsx\n`)).toBeUndefined()
  expect(unreached(`${BASE_2924}python3 -m json.tool "$like"\n`)).toBe('it hands another script its words')
  // #3416: the file such a run names is judged as a write of it by handedToUnknown, below, so it is
  // still no route here. What the script was handed, passed on to such a program, is a known limit
  // and still no route: the reader gives `case`, `[[`, `exit`, `shift` and `basename` as programs it
  // does not know, so reading every one handed `$1` as a route holds nearly every script again, and
  // telling them apart takes a list only Dan may add to.
  expect(unreached(`${BASE_2924}mystery "$like"\n`)).toBeUndefined()
  expect(unreached(`${BASE_2924}case "$1" in a) shift ;; esac\n`)).toBeUndefined()
})

// #3416: each file a shell script's own text hands a program the write reader does not know, by a
// path the reader places, as the reader's rule for a command typed whole gives it (#3323). The list
// of programs that only read applies in a script's text as it does on a command line, and so does
// each form of a listed one that writes.
test('#3416: handedToUnknown gives each file a script text hands a program the reader does not know, with the reader\'s words for it', () => {
  const handed = (text: string) => handedToUnknown(commandWrites(text, '/s', '/h').runs)
  expect(handed('set -e\nprettier --write /s/app/page.tsx\n').map(h => ({ program: h.program, path: h.path }))).toEqual([{ program: 'prettier', path: '/s/app/page.tsx' }])
  const [first] = handed('mystery app/page.tsx\n')
  expect(first?.path).toBe('/s/app/page.tsx')
  expect(first?.why).toBe('mystery is a program the mods do not know, so what it does with a file it is handed cannot be read before it runs')
  expect(first?.remedy).toContain('If mystery only reads too, ask Dan to add it to that list: only he may.')
  // A variable the script sets to one value is followed; one it is handed, a pattern and a
  // command's output spell no path, so the reader hands none on.
  expect(handed('P=/s/app/page.tsx\nmystery "$P"\n').map(h => h.path)).toEqual(['/s/app/page.tsx'])
  expect(handed('mystery "$1"\nmystery "$@"\nmystery app/*.tsx\nmystery "$(ls app)"\n')).toEqual([])
  // The programs that only read hand nothing on, but in a form that writes or runs a program.
  expect(handed('cat /s/app/page.tsx\ngrep -n x /s/app/page.tsx | head -3\n[ -f /s/app/page.tsx ]\ntest -f /s/app/page.tsx\nwc -l /s/app/page.tsx\n')).toEqual([])
  expect(handed('rg --pre ./tool x /s/app/page.tsx\n').map(h => ({ program: h.program, path: h.path, why: h.why }))).toContainEqual({ program: 'rg', path: '/s/app/page.tsx', why: 'rg with --pre runs a program on each file' })
  // A script file, a module and a tool run through npx are runs of another kind, judged by the
  // rules that were there before; none is given here.
  expect(handed('bash /s/other.sh /s/app/page.tsx\npython3 -m json.tool /s/app/page.tsx\nnpx prettier --write /s/app/page.tsx\n')).toEqual([])
  // #3602: the reader's mark on a word whose every $ the shell hands on as written is kept, and
  // only on that word.
  expect(handed("mystery 'x $(a | b) y' /s/app/page.tsx\n").map(h => ({ word: h.word, unexpanded: h.unexpanded === true }))).toEqual([
    { word: 'x $(a | b) y', unexpanded: true },
    { word: '/s/app/page.tsx', unexpanded: false },
  ])
  expect(handedToUnknown(undefined)).toEqual([])
})

// #3416, Dan 2026-11-22 ("Build the exemption (Recommended)"): a call of a function the script's own
// text defines is not read as a program the reader does not know. All 31 newly judged calls in the
// count were a suite calling its own helper. What is left of a script's runs once such calls are
// read as the function's own commands, as `program path` for each look changing file still handed on.
const ownLeft = async (text: string, sourced?: OwnCallIo['sourced']): Promise<string[]> => {
  const io = {
    pipeline: async (t: string, assignments?: boolean) => pipelineIn(t, '/s', '/h', assignments ? { assignments: true } : {}) as readonly RunCommand[],
    writes: async (t: string) => commandWrites(t, '/s', '/h') as never,
    ...(sourced ? { sourced } : {}),
  }
  const worth = (p: string) => allRules.shapeKind(p) !== null || isModHookTs(p)
  const left = await withoutOwnCalls(io, text, pipelineIn(text, '/s', '/h') as readonly RunCommand[], commandWrites(text, '/s', '/h').runs as never, worth)
  return handedToUnknown(left)
    .filter(h => worth(h.path))
    .map(h => `${h.program} ${h.path}`)
}
const CHECK = 'check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }\n'
const SAYS = `says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': \${ERR:0:400}" ;; esac; }\n`

test('#3416: a call of a function the script itself defines, whose body hands what it was handed to nothing the reader judges, is left out', async () => {
  // The shapes the count found: a helper that compares and prints, one calling another helper of the
  // script, one that pipes what it was handed to a program that only reads.
  expect(await ownLeft(`${CHECK}${SAYS}says "the refusal names app/page.tsx" "refused app/page.tsx"\n`)).toEqual([])
  expect(await ownLeft(`${CHECK}check "a label naming app/page.tsx" ok\n`)).toEqual([])
  expect(await ownLeft('assert_contains() {\n  # $1 desc, $2 needle, $3 haystack\n  if printf \'%s\' "$3" | grep -qF "$2"; then\n    PASS=$((PASS+1)); echo "PASS: $1"\n  else\n    FAIL=$((FAIL+1)); echo "FAIL: $1 (missing: $2)"\n  fi\n}\nassert_contains "names the page" app/page.tsx "$out"\n')).toEqual([])
  expect(await ownLeft('function note {\n  echo "$1"\n}\nnote /s/app/page.tsx\nnote "${2}" /s/app/globals.css\n')).toEqual([])
  // A group inside the body does not end it early, and what follows the group is still read.
  expect(await ownLeft('need() { [ -n "$1" ] || { echo "no file"; return 1; }; echo "$1"; }\nneed /s/app/page.tsx\n')).toEqual([])
  // Each file of a call by itself: the one the body only prints is left out, the other is not.
  expect(await ownLeft('note() { echo "$1"; mystery "$2"; }\nnote /s/app/a.tsx /s/app/b.tsx\n')).toEqual(['note /s/app/b.tsx'])
  // Every other run is given back as it was.
  expect(await ownLeft(`${CHECK}prettier --write /s/app/page.tsx\ncheck app/page.tsx ok\n`)).toEqual(['prettier /s/app/page.tsx'])
})

test('#3416: a function that hands on what it was handed is still a run of a program the reader does not know', async () => {
  const held = ['run /s/app/page.tsx']
  for (const text of [
    // A wrapper: the program it hands the file to is the one that was never known.
    'run() { someunknownprogram "$@"; }\nrun /s/app/page.tsx\n',
    'run() { prettier --write "$1"; }\nrun app/page.tsx\n',
    'run() { [ -n "$1" ] || { echo no; return 1; }; prettier --write "$1"; }\nrun app/page.tsx\n',
    'function run {\n  timeout 5 prettier --write "${1}"\n}\nrun app/page.tsx\n',
    // Its body writes the file, takes it away or runs it.
    'run() { sed -i s/a/b/ "$1"; }\nrun app/page.tsx\n',
    'run() { echo x > "$1"; }\nrun app/page.tsx\n',
    'run() { rm -f "$1"; }\nrun app/page.tsx\n',
    'run() { "$1" --fix; }\nrun app/page.tsx\n',
    'run() { eval "$1"; }\nrun app/page.tsx\n',
    // It keeps the file in a variable, loops over it, or changes what `$1` is.
    'run() { local f="$1"; mystery "$f"; }\nrun app/page.tsx\n',
    'run() {\n  f=$1\n  mystery "$f"\n}\nrun app/page.tsx\n',
    'run() { for f in "$@"; do mystery "$f"; done; }\nrun app/page.tsx\n',
    'run() { for f; do mystery "$f"; done; }\nrun app/page.tsx\n',
    'run() { shift; mystery "$1"; }\nrun x app/page.tsx\n',
    'run() { mystery "${1:-x}"; }\nrun app/page.tsx\n',
    'run() { mystery "${@:1}"; }\nrun app/page.tsx\n',
    // A name joined to another value, and one handed on through another function of the script.
    'run() { prettier --write "$ROOT/$1"; }\nrun app/page.tsx\n',
    'inner() { mystery "$1"; }\nrun() { inner "$1"; }\nrun app/page.tsx\n',
    'inner() { mystery "$1"; }\nrun() { inner "see $1"; }\nrun app/page.tsx\n',
    // Defined after the call, only inside a branch, loop, group or function, or as no group.
    'run /s/app/page.tsx\nrun() { true; }\n',
    'if [ -n "$X" ]; then\n  run() { true; }\nfi\nrun app/page.tsx\n',
    'for x in 1; do run() { true; }; done\nrun app/page.tsx\n',
    '{ run() { true; }; }\nrun app/page.tsx\n',
    'outer() {\n  run() { true; }\n}\nrun app/page.tsx\n',
    'run()( true )\nrun app/page.tsx\n',
    'run () { true; }\nrun app/page.tsx\n',
    // Defined, then unset, defined again (before the call or after it), or behind an alias.
    'run() { true; }\nunset -f run\nrun app/page.tsx\n',
    'run() { true; }\nunset "$which"\nrun app/page.tsx\n',
    'run() { true; }\nrun() { mystery "$1"; }\nrun app/page.tsx\n',
    'run() { true; }\nrun app/page.tsx\nrun() { mystery "$1"; }\n',
    'run() { true; }\nrun () { mystery "$1"; }\nrun app/page.tsx\n',
    'alias run=prettier\nrun() { true; }\nrun app/page.tsx\n',
    // Text run as commands after the definition may define it again.
    'run() { true; }\neval "$later"\nrun app/page.tsx\n',
    'run() { true; }\n. /s/lib.sh\nrun app/page.tsx\n',
    // A heredoc in the body, and a name this reading writes into the text it hands the reader.
    'run() {\n  cat <<EOF\n$1\nEOF\n}\nrun app/page.tsx\n',
    'run() { true; } # zz3416\nrun app/page.tsx\n',
  ])
    expect({ text, left: await ownLeft(text) }).toEqual({ text, left: held })
  // A function from a file the guard did not read is no function it can read the body of.
  expect(await ownLeft('. /s/lib.sh\nlib_fn app/page.tsx\n')).toEqual(['lib_fn /s/app/page.tsx'])
  // A file read in after the definition: left out only where the guard read it and it leaves the name alone.
  const after = 'run() { true; }\n. /s/lib.sh\nrun app/page.tsx\n'
  const lib = (text: string) => async () => ({ path: '/s/lib.sh', text, commands: pipelineIn(text, '/s', '/h') as readonly RunCommand[] })
  expect(await ownLeft(after, lib('helper() { echo x; }\n'))).toEqual([])
  expect(await ownLeft(after, lib('run() { mystery "$1"; }\n'))).toEqual(held)
  expect(await ownLeft(after, lib('eval "$x"\n'))).toEqual(held)
  expect(await ownLeft(after, async () => undefined)).toEqual(held)
  // A mod hook file handed to a helper that passes it to a script is still judged.
  expect(await ownLeft('mutant(){\n  local file="$4" expr="$5"\n  bash /s/tools/prove.sh --sed "$file" "$expr"\n}\nmutant a b PROVED payload/mods/x/hooks/rules.ts s/a/b/\n')).toEqual(['mutant /s/payload/mods/x/hooks/rules.ts'])
})

// #3416, Dan 2026-11-22 ("Read the files a suite reads in (Recommended)"): what is left of a suite's
// runs where the guard reads each file the suite reads in from a disk holding `files` (readInFile).
// The suite is /s/suite.sh, run in /s. `read` counts the characters read from that disk.
const OWN_DIR = 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
const readLeft = async (text: string, files: Record<string, string>, given: { written?: string[]; unreadable?: string[]; links?: string[]; read?: { chars: number } } = {}): Promise<string[]> => {
  const disk = {
    stat: async (p: string) => {
      const f = files[p]
      if (f === undefined) throw new Error('ENOENT')
      return { kind: 'file', size: f.length, isLink: given.links?.includes(p) ?? false }
    },
    read: async (p: string) => {
      if (given.unreadable?.includes(p)) throw new Error('EACCES')
      if (given.read) given.read.chars += (files[p] as string).length
      return files[p] as string
    },
  }
  return ownLeft(text, (c, beside) => readInFile(disk, c, beside, { path: '/s/suite.sh', text, folder: '/s' }, '/h', () => undefined, given.written ?? []))
}

test('#3416: a file a suite reads in after its helper, by a path the guard can work out, is read from the disk', async () => {
  const RUN = 'run() { true; }\n'
  const CALL = 'run app/page.tsx\n'
  const held = ['run /s/app/page.tsx']
  const lib = { '/s/lib/x.sh': 'helper() { echo x; }\n' }
  // The shape the count found six times: the suite sets DIR to its own folder once, as a command of
  // its own, and holds the same line again as text it writes into fixtures, with a cd inside the
  // same idiom on an earlier line. Read as text alone (mod-kit's ownFolderVar) that is no one value.
  const suite = `. "$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {\n  exit 1\n}\n${OWN_DIR}${CHECK}${SAYS}top='DIR="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"'\nprintf '%s\\n' "$top" 'DIR=/elsewhere' > "$T/fixture.sh"\ncat > "$T/other.sh" <<'EOF'\nDIR=/elsewhere\nEOF\n. "$DIR/lib/x.sh"\nsays app/page.tsx "refused"\n`
  expect(await readLeft(suite, lib)).toEqual([])
  for (const text of [
    `${OWN_DIR}${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}${RUN}source "\${DIR}/lib/x.sh" || {\n  exit 1\n}\n${CALL}`,
    // Whether the file is read in or not, it leaves the name alone: a branch around it changes nothing.
    `${OWN_DIR}${RUN}if [ -f "$DIR/lib/x.sh" ]; then\n  . "$DIR/lib/x.sh"\nfi\n${CALL}`,
    // A path with no expansion, from the folder the suite runs in or from the top of the disk.
    `${RUN}. lib/x.sh\n${CALL}`,
    `${RUN}. /s/lib/x.sh\n${CALL}`,
  ])
    expect({ text, left: await readLeft(text, lib) }).toEqual({ text, left: [] })
  // The control: the same suites with nothing on the disk to read are held, so the file is what clears them.
  expect(await readLeft(suite, {})).toEqual(['says /s/app/page.tsx'])
  expect(await readLeft(`${OWN_DIR}${RUN}. "$DIR/lib/x.sh"\n${CALL}`, {})).toEqual(held)

  // A path the guard cannot work out: the file is not read, and the call is judged as before.
  for (const text of [
    // A variable set from a command, an argument, a pattern, a file that is not there.
    `${RUN}LIB="$(find . -name x.sh)"\n. "$LIB"\n${CALL}`,
    `${OWN_DIR}${RUN}LIB="$DIR/lib/x.sh"\n. "$LIB"\n${CALL}`,
    `${RUN}. "$1"\n${CALL}`,
    `${RUN}. lib/*.sh\n${CALL}`,
    `${RUN}. lib/missing.sh\n${CALL}`,
    `${OWN_DIR}${RUN}. "$DIR/lib/$NAME.sh"\n${CALL}`,
    // DIR is not surely the suite's own folder: set twice, in a function, in a branch, only where
    // another command says so, by a builtin, by a default, after the file is read in, as text in
    // single quotes, from $0 (the caller's name in a file read in), with more joined on, or after a
    // cd has moved the folder a relative name of the suite is read from.
    `${OWN_DIR}DIR=/elsewhere\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}other() { DIR=/elsewhere; }\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `if [ -n "$X" ]; then\n${OWN_DIR}fi\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `[ -n "$X" ] && ${OWN_DIR}${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `[ -n "$X" ] &&\n${OWN_DIR}${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}read -r DIR\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}other() { local DIR; }\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}other() { local DIR=/elsewhere; }\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}printf -v DIR '%s' /elsewhere\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}for DIR in a b; do true; done\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}: "\${DIR:=/elsewhere}"\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}DIR=/elsewhere true\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `export ${OWN_DIR}${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${RUN}. "$DIR/lib/x.sh"\n${OWN_DIR}${CALL}`,
    `DIR='$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)'\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `DIR="$(cd "$(dirname "$0")" && pwd)"\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `DIR="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)/lib"\n${RUN}. "$DIR/x.sh"\n${CALL}`,
    `cd /elsewhere\n${OWN_DIR}${RUN}. "$DIR/lib/x.sh"\ncd /s\n${CALL}`,
    // Or something between the assignment and the file could set it again unseen: an eval, another
    // file read in, arithmetic naming it.
    `${OWN_DIR}eval "$SETUP"\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}. lib/quiet.sh\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}${RUN}. "$DIR/lib/quiet.sh"\n. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}: $((DIR = 1))\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    `${OWN_DIR}(( DIR++ ))\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`,
    // The file read in under DIR may set DIR itself, so a second reading of it could be of another file.
    `${OWN_DIR}${RUN}. "$DIR/lib/sets.sh"\n${CALL}`,
    `${OWN_DIR}${RUN}. "$DIR/lib/locals.sh"\n${CALL}`,
  ])
    expect({ text, left: await readLeft(text, { ...lib, '/s/lib/.sh': lib['/s/lib/x.sh'], '/s/x.sh': lib['/s/lib/x.sh'], '/s/lib/quiet.sh': 'quiet() { echo x; }\n', '/s/lib/sets.sh': 'DIR=/elsewhere\n', '/s/lib/locals.sh': 'helper() { local DIR; }\n' }) }).toEqual({ text, left: held })
  // The same file read in twice under DIR, and one that only reads DIR, are read.
  expect(await readLeft(`${OWN_DIR}${RUN}. "$DIR/lib/x.sh"\n. "$DIR/lib/x.sh"\n${CALL}`, lib)).toEqual([])
  expect(await readLeft(`${OWN_DIR}${RUN}. "$DIR/lib/x.sh"\n${CALL}`, { '/s/lib/x.sh': 'helper() { cat "$DIR/notes" "${DIR}/more"; }\n' })).toEqual([])
  // A file that is there and cannot be read, a link (which may point outside the folder), and one too large to read.
  expect(await readLeft(`${RUN}. lib/x.sh\n${CALL}`, lib, { unreadable: ['/s/lib/x.sh'] })).toEqual(held)
  expect(await readLeft(`${RUN}. lib/x.sh\n${CALL}`, lib, { links: ['/s/lib/x.sh'] })).toEqual(held)
  expect(await readLeft(`${RUN}. lib/x.sh\n${CALL}`, { '/s/lib/x.sh': `helper() { echo x; }\n${'#'.repeat(allRules.SCRIPT_MAX)}\n` })).toEqual(held)

  // A file outside the folder the suite is in is not read: by a whole path, by a climb, in the home folder.
  const outside = { '/elsewhere/lib.sh': lib['/s/lib/x.sh'], '/lib.sh': lib['/s/lib/x.sh'], '/h/lib.sh': lib['/s/lib/x.sh'], '/s/lib/x.sh': lib['/s/lib/x.sh'] }
  for (const text of [`${RUN}. /elsewhere/lib.sh\n${CALL}`, `${OWN_DIR}${RUN}. "$DIR/../lib.sh"\n${CALL}`, `${RUN}. ../lib.sh\n${CALL}`, `${RUN}. ~/lib.sh\n${CALL}`, `${OWN_DIR}${RUN}. "$DIR/lib/../../elsewhere/lib.sh"\n${CALL}`])
    expect({ text, left: await readLeft(text, outside) }).toEqual({ text, left: held })
  // The climb that stays inside the folder is read.
  expect(await readLeft(`${OWN_DIR}${RUN}. "$DIR/lib/../lib/x.sh"\n${CALL}`, outside)).toEqual([])

  // A file the command, or a script it runs, writes, removes or changes by a name the reader places,
  // or a folder above it so written: what the guard read may not be what the suite reads in.
  for (const written of [['/s/lib/x.sh'], ['/s/lib'], ['/s'], ['/s/app/other.tsx', '/s/lib/x.sh']]) expect({ written, left: await readLeft(`${RUN}. lib/x.sh\n${CALL}`, lib, { written }) }).toEqual({ written, left: held })
  expect(await readLeft(`${RUN}. lib/x.sh\n${CALL}`, lib, { written: ['/s/lib/y.sh', '/s/library', '/s/lib/x.sh.bak'] })).toEqual([])

  // What the file holds: the name again, an eval, a file it reads in itself, an alias, an unset.
  for (const file of ['run() { mystery "$1"; }\n', 'run () { mystery "$1"; }\n', 'helper() { echo x; }\neval "$X"\n', 'helper() { echo x; }\n. /s/lib/more.sh\n', 'helper() { echo x; }\nsource /s/lib/more.sh\n', 'alias run=mystery\n', 'unset -f run\n'])
    expect({ file, left: await readLeft(`${RUN}. lib/x.sh\n${CALL}`, { '/s/lib/x.sh': file, '/s/lib/more.sh': 'helper2() { echo x; }\n' }) }).toEqual({ file, left: held })
})

test('#3416: a helper from a file a suite reads in is read as its body with the call\'s words in place, by the checks a helper of the suite\'s own gets', async () => {
  const CALL = 'lib_fn app/page.tsx\n'
  const held = ['lib_fn /s/app/page.tsx']
  const libs = { '/s/lib.sh': 'lib_fn() { echo "$1"; }\nlib_two() {\n  lib_fn "$1"\n}\nlib_fmt() { prettier --write "$1"; }\n' }
  for (const text of [
    `. lib.sh\n${CALL}`,
    `. /s/lib.sh\n${CALL}`,
    `${OWN_DIR}. "$DIR/lib.sh" || {\n  exit 1\n}\n${CALL}`,
    // A helper of the file that passes the file on to another helper of the file.
    '. lib.sh\nlib_two app/page.tsx\n',
    // A helper of the suite's own that passes the file on to a helper of the file.
    '. lib.sh\nfires() {\n  if lib_fn "$1"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi\n}\nfires app/page.tsx\n',
  ])
    expect({ text, left: await readLeft(text, libs) }).toEqual({ text, left: [] })
  // The controls: nothing on the disk, and a file that does not define the name.
  expect(await readLeft(`. lib.sh\n${CALL}`, {})).toEqual(held)
  expect(await readLeft(`. lib.sh\n${CALL}`, { '/s/lib.sh': 'other() { echo "$1"; }\n' })).toEqual(held)

  // The name is never what is trusted: a body that hands the file on, writes it, removes it, runs
  // it or keeps it in a variable is judged, as the same body in the suite's own text is.
  expect(await readLeft('. lib.sh\nlib_fmt app/page.tsx\n', libs)).toEqual(['lib_fmt /s/app/page.tsx'])
  expect(await readLeft('. lib.sh\nfires() {\n  if lib_fmt "$1"; then pass=1; fi\n}\nfires app/page.tsx\n', libs)).toEqual(['fires /s/app/page.tsx'])
  // A helper that runs the predicate it is handed (`fires lib_fn app/page.tsx`, the shape the count
  // found four times) is judged as before, whichever predicate: the predicate's name is a word the
  // reader places as a file, and a file run as the command is not followed.
  for (const predicate of ['lib_fn', 'lib_fmt']) expect(await readLeft(`. lib.sh\nfires() {\n  if "$1" "$2"; then pass=1; fi\n}\nfires ${predicate} app/page.tsx\n`, libs)).toEqual(['fires /s/app/page.tsx'])
  for (const file of [
    'lib_fn() { someunknownprogram "$@"; }\n',
    'lib_fn() { echo x > "$1"; }\n',
    'lib_fn() { sed -i s/a/b/ "$1"; }\n',
    'lib_fn() { rm -f "$1"; }\n',
    'lib_fn() { "$1" --fix; }\n',
    'lib_fn() { eval "$1"; }\n',
    'lib_fn() { local f="$1"; mystery "$f"; }\n',
    'lib_fn() { for f in "$@"; do mystery "$f"; done; }\n',
    'lib_fn() { shift; mystery "$1"; }\n',
    'lib_fn() { mystery "${1:-x}"; }\n',
    'lib_fn() { timeout 5 prettier --write "$1"; }\n',
    'lib_fn() { lib_inner "$1"; }\nlib_inner() { prettier --write "$1"; }\n',
    'lib_fn() {\n  cat <<EOF\n$1\nEOF\n}\n',
    // A definition the shell may not make, or makes more than once, in the file.
    'if [ -n "$X" ]; then\nlib_fn() { echo "$1"; }\nfi\n',
    '[ -n "$X" ] && lib_fn() { echo "$1"; }\n',
    '[ -n "$X" ] &&\nlib_fn() { echo "$1"; }\n',
    'echo x | lib_fn() { echo "$1"; }\n',
    'wrap() {\n  lib_fn() { echo "$1"; }\n}\n',
    'lib_fn() { echo "$1"; }\nlib_fn() { echo "$1"; }\n',
    'lib_fn () { echo "$1"; }\n',
    'lib_fn() { echo "$1"; } > "$1"\n',
    // The file leaves early before the definition, so the shell may never make it.
    '[ -n "$LOADED" ] && return 0\nlib_fn() { echo "$1"; }\n',
    '[ -n "$LOADED" ] && exit 0\nlib_fn() { echo "$1"; }\n',
    // The file holds an eval, an alias or an unset, or reads in a file itself: one file deep, no deeper.
    'lib_fn() { echo "$1"; }\neval "$X"\n',
    'alias lib_fn=mystery\nlib_fn() { echo "$1"; }\n',
    'lib_fn() { echo "$1"; }\nunset -f lib_fn\n',
    'lib_fn() { echo "$1"; }\n. /s/more.sh\n',
    '. /s/more.sh\nlib_fn() { echo "$1"; }\n',
    'lib_fn() { echo "$1"; } # zz3416\n',
  ])
    expect({ file, left: await readLeft(`. lib.sh\n${CALL}`, { '/s/lib.sh': file, '/s/more.sh': 'more() { echo x; }\n' }) }).toEqual({ file, left: held })

  // What the suite does around the file it reads in.
  for (const text of [
    // The name is defined in the suite and in the file, whichever comes last.
    `lib_fn() { true; }\n. lib.sh\n${CALL}`,
    `. lib.sh\nlib_fn() { true; }\n${CALL}`,
    // The call comes before the file is read in, or runs a program of that name.
    `${CALL}. lib.sh\n`,
    '. lib.sh\ntimeout 5 lib_fn app/page.tsx\n',
    '. lib.sh\nfind . -name x -exec lib_fn app/page.tsx \\;\n',
    // The file is read in only sometimes, in a subshell, with words of its own, or twice.
    `[ -f lib.sh ] && . lib.sh\n${CALL}`,
    `[ -f lib.sh ] &&\n. lib.sh\n${CALL}`,
    `if [ -f lib.sh ]; then\n  . lib.sh\nfi\n${CALL}`,
    `load() {\n  . lib.sh\n}\nload\n${CALL}`,
    `( . lib.sh )\n${CALL}`,
    `echo x | . lib.sh\n${CALL}`,
    `. lib.sh extra\n${CALL}`,
    `command . lib.sh\n${CALL}`,
    `. lib.sh\n. lib.sh\n${CALL}`,
    // An eval, an alias, an unset, or a file the guard did not read, after it.
    `. lib.sh\neval "$X"\n${CALL}`,
    `. lib.sh\nalias lib_fn=mystery\n${CALL}`,
    `. lib.sh\nunset -f lib_fn\n${CALL}`,
    `. lib.sh\n. "$1"\n${CALL}`,
    `. lib.sh\n. lib/missing.sh\n${CALL}`,
    // Two files read in define it.
    `. lib.sh\n. second.sh\n${CALL}`,
    `. second.sh\n. lib.sh\n${CALL}`,
    // A path the guard cannot work out, or a file outside the suite's folder.
    `LIB="$(find . -name lib.sh)"\n. "$LIB"\n${CALL}`,
    `. /elsewhere/lib.sh\n${CALL}`,
  ])
    expect({ text, left: await readLeft(text, { ...libs, '/s/second.sh': 'lib_fn() { echo "$1"; }\n', '/elsewhere/lib.sh': libs['/s/lib.sh'] }) }).toEqual({ text, left: held })
  // A file the command or a script it runs writes is not read for a helper either.
  expect(await readLeft(`. lib.sh\n${CALL}`, libs, { written: ['/s/lib.sh'] })).toEqual(held)
})

test('#3416: a name some function would define again when called is held, in the suite or a file it reads in, called or not', async () => {
  const RUN = 'run() { true; }\n'
  const CALL = 'run app/page.tsx\n'
  const held = ['run /s/app/page.tsx']
  // What a function holds that makes the name run another body once the function is called.
  const AGAIN = ['run() { someunknownprogram "$@"; }', 'function run { someunknownprogram "$@"; }', 'run () { someunknownprogram "$@"; }']
  for (const again of AGAIN) {
    const setup = `setup() { ${again}; }\n`
    const lib = { '/s/lib.sh': setup }
    for (const text of [
      // A file read in before the suite defines the name: the shell runs the body `setup` installed.
      `. lib.sh\n${RUN}setup\n${CALL}`,
      // The same in a file read in after the suite's definition.
      `${RUN}. lib.sh\nsetup\n${CALL}`,
      // Never called by a command of that name: still held, since a call can come by a route this
      // reading does not follow (a command whose name is a variable, a trap, a file it did not read).
      `. lib.sh\n${RUN}${CALL}`,
      `${RUN}. lib.sh\n${CALL}`,
    ])
      expect({ text, left: await readLeft(text, lib) }).toEqual({ text, left: held })
    // Another helper of the suite's own holds it, before the definition or after, called or not.
    for (const text of [`${RUN}${setup}setup\n${CALL}`, `${setup}${RUN}setup\n${CALL}`, `${RUN}${setup}${CALL}`, `${setup}${RUN}${CALL}`]) expect({ text, left: await ownLeft(text) }).toEqual({ text, left: held })
    // The helper comes from a file read in, and the suite's own function would define it again.
    for (const text of [`. lib2.sh\n${setup}setup\n${CALL}`, `${setup}. lib2.sh\n${CALL}`]) expect({ text, left: await readLeft(text, { '/s/lib2.sh': RUN }) }).toEqual({ text, left: held })
  }
  // The controls: the same suites where the function defines another name are left out.
  const other = 'setup() { walk() { someunknownprogram "$@"; }; }\n'
  for (const text of [`. lib.sh\n${RUN}setup\n${CALL}`, `${RUN}. lib.sh\nsetup\n${CALL}`]) expect({ text, left: await readLeft(text, { '/s/lib.sh': other }) }).toEqual({ text, left: [] })
  for (const text of [`${RUN}${other}setup\n${CALL}`, `${other}${RUN}setup\n${CALL}`]) expect({ text, left: await ownLeft(text) }).toEqual({ text, left: [] })
  expect(await readLeft(`. lib2.sh\n${other}setup\n${CALL}`, { '/s/lib2.sh': RUN })).toEqual([])
})

test('#3416: text that may run after the definition and that the guard cannot read holds the call, wherever it is typed', async () => {
  const RUN = 'run() { true; }\n'
  const CALL = 'run app/page.tsx\n'
  const held = ['run /s/app/page.tsx']
  // Every case is read, and each one read wrongly is named, so one wrong case does not hide the rest.
  const wrong: { text: string; files: Record<string, string>; left: string[] }[] = []
  const want = async (text: string, files: Record<string, string>, expected: string[]): Promise<void> => {
    const left = await readLeft(text, files)
    if (left.join('\n') !== expected.join('\n')) wrong.push({ text, files, left })
  }
  // What a function typed BEFORE the definition may hold that defines the name again, or takes it
  // away, once the function is called after the definition: text run as commands, a file the guard
  // did not read, and in a file read in, an unset or an alias (the suite's own are held already).
  const UNSEEN = ['eval "$X"', 'builtin eval "$X"', '. "$X"', 'source /s/missing.sh']
  for (const unseen of UNSEEN) {
    const setup = `setup() { ${unseen}; }\n`
    for (const text of [
      // A helper of the suite's own, called after the definition.
      `${setup}${RUN}setup\n${CALL}`,
      // Never called by a command of that name: still held, as a call can come by a route this
      // reading does not follow.
      `${setup}${RUN}${CALL}`,
    ])
      await want(text, {}, held)
  }
  for (const inFile of [...UNSEEN, 'unset -f run', 'alias run=mystery']) {
    const lib = { '/s/lib.sh': `setup() { ${inFile}; }\n`, '/s/lib2.sh': RUN }
    for (const text of [
      // The function comes from a file read in before the suite's definition.
      `. lib.sh\n${RUN}setup\n${CALL}`,
      `. lib.sh\n${RUN}${CALL}`,
      // The helper comes from one file read in, the function from another read in before it.
      `. lib.sh\n. lib2.sh\nsetup\n${CALL}`,
    ])
      await want(text, lib, held)
  }
  // Text run as commands anywhere in the suite, and a file the guard did not read that is read in
  // before the definition anywhere but the top of the suite (in a function, a branch, a loop, after
  // `&&`), are held too: this reading does not tell a function's body from a branch.
  for (const text of [`eval "$X"\n${RUN}${CALL}`, `if [ -f lib/missing.sh ]; then\n  . lib/missing.sh\nfi\n${RUN}${CALL}`, `[ -f lib/missing.sh ] && . lib/missing.sh\n${RUN}${CALL}`, `eval "$X"\n. lib2.sh\n${CALL}`])
    await want(text, { '/s/lib2.sh': RUN }, held)
  // The same where the file's name holds a substitution, whose commands the reader gives first.
  const IDIOM = '. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/x.sh"'
  for (const text of [`setup() { ${IDIOM}; }\n${RUN}setup\n${CALL}`, `if [ -n "$X" ]; then\n  ${IDIOM}\nfi\n${RUN}${CALL}`, `[ -n "$X" ] &&\n${IDIOM}\n${RUN}${CALL}`, `setup() {\n  true\n  ${IDIOM}\n}\n${RUN}${CALL}`]) await want(text, {}, held)
  // A file read in before the definition that runs text as commands at its own top, or reads in a file.
  for (const file of ['eval "$X"\n', '. /s/more.sh\n']) await want(`. lib.sh\n${RUN}${CALL}`, { '/s/lib.sh': file, '/s/more.sh': 'more() { echo x; }\n' }, held)

  // The controls. A function that does none of that, in the suite or in a file read in before.
  await want(`setup() { echo x; }\n${RUN}setup\n${CALL}`, {}, [])
  await want(`. lib.sh\n${RUN}setup\n${CALL}`, { '/s/lib.sh': 'setup() { echo x; }\n' }, [])
  await want(`. lib.sh\n. lib2.sh\nsetup\n${CALL}`, { '/s/lib.sh': 'setup() { echo x; }\n', '/s/lib2.sh': RUN }, [])
  // Left as it was, and not closed here: a file the guard did not read that is read in at the top
  // of the suite, as a command of its own, before the definition. It has ended by the definition,
  // which then replaces whatever it defined under the name; a function it defined under another
  // name, called after the definition, is what the guard cannot see.
  for (const text of [`. /elsewhere/lib.sh\n${RUN}${CALL}`, `. lib/missing.sh || {\n  exit 1\n}\n${RUN}${CALL}`, `${IDIOM}\n${RUN}${CALL}`, `${IDIOM} || {\n  exit 1\n}\n${RUN}${CALL}`]) await want(text, {}, [])
  expect(wrong).toEqual([])
})

test('#3416: a comment that spells a definition or a read in command is never probed, so it cannot move what stands at the top', async () => {
  const RUN = 'run() { true; }\n'
  const CALL = 'run app/page.tsx\n'
  const lib = { '/s/lib.sh': 'lib_fn() { echo "$1"; }\n' }
  const wrong: { text: string; left: string[] }[] = []
  const want = async (text: string, expected: string[]): Promise<void> => {
    const left = await readLeft(text, lib)
    if (left.join('\n') !== expected.join('\n')) wrong.push({ text, left })
  }
  // A probe written into a comment ends the comment, and the rest of the line is read as commands.
  // A `}` there closed a group the script never closed, so what stood in a function looked as if it
  // stood at the top: a definition the shell makes only when `wrap` is called, and a file read in
  // only when `load` is.
  await want(`# usage: a; b() { c; }; }\nwrap () {\n  true\n  run() { true; }\n}\nwrap\n${CALL}`, ['run /s/app/page.tsx'])
  await want('# see (x). y; }\nload () {\n  true\n  . lib.sh\n}\nload\nlib_fn app/page.tsx\n', ['lib_fn /s/app/page.tsx'])
  // The other way, the shape of a real suite's comment: a sentence ending in a bracket and a full
  // stop, with an issue number in brackets, left the helper below it looking as if it stood in a group.
  const said = '# by $cmd (its argument or LOAD_AVERAGE_CMD). One more is a command nobody has looked at (#3134), and one\n'
  await want(`${said}${RUN}${CALL}`, [])
  await want(`${said}. lib.sh\nlib_fn app/page.tsx\n`, [])
  // A definition or a read in command typed after a `#` on its own line may be inside a comment:
  // it is not probed, and so is never at the top.
  await want(`x=1 # then; run() { true; }\n${CALL}`, ['run /s/app/page.tsx'])
  await want('x=1 # then; . lib.sh\nlib_fn app/page.tsx\n', ['lib_fn /s/app/page.tsx'])
  // The controls: a `#` that starts no comment on the line before, and one inside the helper's body.
  await want(`n=\${#list[@]}\n${RUN}${CALL}`, [])
  await want(`run() { true; } # the helper\n${CALL}`, [])
  await want('. lib.sh # the library\nlib_fn app/page.tsx\n', [])
  expect(wrong).toEqual([])

  // The same for the places the folder variable is set (ownFolder): a comment made an assignment
  // inside a function read as standing at the top, so a file under `$DIR` was read from the
  // suite's folder though the shell, with DIR not yet set, reads another.
  const under = { '/s/lib/x.sh': 'helper() { echo x; }\n' }
  const folder: { text: string; left: string[] }[] = []
  const wantUnder = async (text: string, expected: string[]): Promise<void> => {
    const left = await readLeft(text, under)
    if (left.join('\n') !== expected.join('\n')) folder.push({ text, left })
  }
  await wantUnder(`# note; DIR=x; }\nsetdir () {\n  true\n  ${OWN_DIR}}\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`, ['run /s/app/page.tsx'])
  await wantUnder(`# why; DIR=elsewhere (#12), and so\n${OWN_DIR}${RUN}. "$DIR/lib/x.sh"\n${CALL}`, [])
  // The control: no comment, and the assignment in the function is not at the top.
  await wantUnder(`setdir () {\n  true\n  ${OWN_DIR}}\n${RUN}. "$DIR/lib/x.sh"\n${CALL}`, ['run /s/app/page.tsx'])
  expect(folder).toEqual([])
})

test('#3416: the files a suite reads in are counted against the limit, and past it no more are read from the disk', async () => {
  // Counted in characters read from the disk, never timed. Without the count every file is read:
  // sixty files of this size are 6.4 million characters, in a hook that runs before the command.
  const big = `helper() { echo x; }\n${'# a line of a long library\n'.repeat(4000)}`
  const files = Object.fromEntries(Array.from({ length: 60 }, (_, i) => [`/s/lib/f${i}.sh`, big]))
  const text = `run() { true; }\n${Array.from({ length: 60 }, (_, i) => `. lib/f${i}.sh`).join('\n')}\nrun app/page.tsx\n`
  const read = { chars: 0 }
  // Past the limit the run is given back as it was, a run of a program the reader does not know.
  expect(await readLeft(text, files, { read })).toEqual(['run /s/app/page.tsx'])
  expect(read.chars).toBeGreaterThan(0)
  expect(read.chars).toBeLessThan(ownBudget(text) + 2 * big.length)
  // A file whose commands the guard holds already is handed to no reader again, so only the count
  // of its own text bounds it: without that count all sixty are handed over.
  const had = { chars: 0 }
  const commands = pipelineIn(big, '/s', '/h') as readonly RunCommand[]
  const known: OwnCallIo['sourced'] = async c => {
    had.chars += big.length
    return { path: `/s/${c.words[1]}`, text: big, commands }
  }
  expect(await ownLeft(text, known)).toEqual(['run /s/app/page.tsx'])
  expect(had.chars).toBeLessThan(ownBudget(text) + big.length)
  // The same file read in sixty times is read from the disk once.
  const again = { chars: 0 }
  expect(await readLeft(`run() { true; }\n${'. lib/f0.sh\n'.repeat(60)}run app/page.tsx\n`, { '/s/lib/f0.sh': 'helper() { echo x; }\n' }, { read: again })).toEqual([])
  expect(again.chars).toBe('helper() { echo x; }\n'.length)
})

test('#3416: a definition the shell may not make, and a call that runs a program of the same name, are still held', async () => {
  const held = ['run /s/app/page.tsx']
  const CALL = '\nrun app/page.tsx\n'
  for (const text of [
    // Made only where the command before it says so, or in the subshell a pipe runs it in.
    `[ -n "$X" ] && run() { true; }${CALL}`,
    `false || run() { true; }${CALL}`,
    `echo x | run() { true; }${CALL}`,
    `[ -n "$X" ] &&\nrun() { true; }${CALL}`,
    `[ -n "$X" ] && \\\nrun() { true; }${CALL}`,
    `[ -n "$X" ] && # only then\nrun() { true; }${CALL}`,
    `[ -n "$X" ] ||\n\n# only then\n\nrun() { true; }${CALL}`,
    `cat <<EOF &&\nx\nEOF\nrun() { true; }${CALL}`,
    `cat <<'E-O-F' |\nx\nE-O-F\nrun() { true; }${CALL}`,
    // Made in a subshell, a case, a loop, the other branch, or a command substitution.
    `( run() { true; } )${CALL}`,
    `case "$X" in a) run() { true; } ;; esac${CALL}`,
    `case "$X" in\n  a)\n    run() { true; }\n    ;;\nesac${CALL}`,
    `while false; do run() { true; }; done${CALL}`,
    `until true; do\n  run() { true; }\ndone${CALL}`,
    `if x; then :; else\n  run() { true; }\nfi${CALL}`,
    `x=$(run() { true; }; echo)${CALL}`,
    `x=$(\nrun() { true; }\n)${CALL}`,
    'cat <<EOF\n$(\nrun() { true; }\n)\nEOF\nrun() { true; }\nrun app/page.tsx\n',
    // What follows the body's closing brace is part of every call: a file it writes, a pipe, a subshell.
    `run() { true; } > "$1"${CALL}`,
    `run() { true; } >> "$1"${CALL}`,
    `run() { echo x; } 2>"$1"${CALL}`,
    `run() { true; } &${CALL}`,
    `run() { true; } | cat${CALL}`,
    // Unset or run as text behind the shell's own words for running a builtin.
    `run() { true; }\ncommand unset -f run${CALL}`,
    `run() { true; }\nbuiltin unset -f run${CALL}`,
    `run() { true; }\nbuiltin eval "$later"${CALL}`,
    `run() { true; }\nbuiltin . /s/lib.sh${CALL}`,
    // A call behind a program that runs its words is a run of the program of that name, never the
    // function: timeout, env, command, a new shell, xargs and find know nothing of a shell function.
    'run() { true; }\ntimeout 5 run app/page.tsx\n',
    'run() { true; }\nenv run app/page.tsx\n',
    'run() { true; }\ncommand run app/page.tsx\n',
    'run() { true; }\nnohup run app/page.tsx\n',
    'run() { true; }\nexec run app/page.tsx\n',
    "run() { true; }\nbash -c 'run app/page.tsx'\n",
    'run() { true; }\nxargs run app/page.tsx\n',
    'run() { true; }\nfind . -exec run app/page.tsx \\;\n',
    // The same inside a body: what it hands on goes to the program, not the script's function.
    `inner() { true; }\nrun() { timeout 5 inner "$1"; }${CALL}`,
    `inner() { true; }\nrun() { command inner "$1"; }${CALL}`,
  ])
    expect({ text, left: await ownLeft(text) }).toEqual({ text, left: held })
  // One such call, or one before the definition, among plain calls with the same words cannot be
  // told from them, so each is held.
  expect(await ownLeft('run() { true; }\nrun app/page.tsx\ntimeout 5 run app/page.tsx\n')).toEqual([...held, ...held])
  expect(await ownLeft('run app/page.tsx\nrun() { true; }\nrun app/page.tsx\n')).toEqual([...held, ...held])
  // What is surely the script's own stays left out: a definition after a whole line, a comment or a
  // semicolon, with a comment after its brace, called in a subshell, a pipe or a substitution.
  for (const text of [
    `[ -d "$T" ] || mkdir "$T"\n# a helper\n\nrun() { true; }${CALL}`,
    `cat <<EOF\nx &&\nEOF\nrun() { true; }${CALL}`,
    `if [ -n "$X" ]; then\n  true\nfi\nrun() { true; }${CALL}`,
    `set -u; run() { true; }; run app/page.tsx\n`,
    `run() { true; } # says nothing${CALL}`,
    `run() { (true)}${CALL}`,
    'run() {\n  # one } in a comment\n  true\n}\nrun app/page.tsx\n',
    'run() { true; }\n( run app/page.tsx )\n',
    'run() { true; }\necho x | run app/page.tsx\n',
    'run() { true; }\nx=$(run app/page.tsx)\n',
  ])
    expect({ text, left: await ownLeft(text) }).toEqual({ text, left: [] })
})

// A made up suite the shape of the repository's long ones: each section defines its own helper and
// calls it once a case with a file the guard holds, six lines a case. What reading its own calls
// costs scales with the helpers times the text before each, so the helpers are spread through it.
const longSuite = (sections: number, cases: number): string => {
  const out = ['#!/bin/bash', 'set -u', 'PASS=0; FAIL=0', 'ROOT="$(cd "$(dirname "$0")" && pwd)"', 'pass() { PASS=$((PASS + 1)); }', 'fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }', '']
  for (let s = 0; s < sections; s++) {
    out.push(`# section ${s}`, `check_${s}() {`, '  if grep -qF "$2" "$1"; then', '    pass', '  else', '    fail "$2"', '    echo "$1"', '  fi', '}')
    for (let c = 0; c < cases; c++)
      out.push(
        `OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo ${s} ${c}"}}' | bash "$ROOT/gate.sh" 2>&1)`,
        'RC=$?',
        `if [ "$RC" -eq 0 ]; then pass; else fail "case ${s}.${c} left $RC"; fi`,
        `check_${s} docs/rounds/round-${s}-${c}.html "expected ${c}"`,
        `[ -n "$OUT" ] || { echo "case ${s}.${c} said nothing"; FAIL=$((FAIL + 1)); }`,
        '',
      )
  }
  out.push('echo "$PASS passed, $FAIL failed"', '[ "$FAIL" -eq 0 ]', '')
  return out.join('\n')
}
// What withoutOwnCalls leaves of a text's runs, and how many characters of text it handed mod-kit's
// readers to decide it: the work a hook does before the command runs, counted and never timed.
const ownCost = async (text: string): Promise<{ held: number; runs: number; handed: number }> => {
  let handed = 0
  const io = {
    pipeline: async (t: string, assignments?: boolean) => {
      handed += t.length
      return pipelineIn(t, '/s', '/h', assignments ? { assignments: true } : {}) as readonly RunCommand[]
    },
    writes: async (t: string) => {
      handed += t.length
      return commandWrites(t, '/s', '/h') as never
    },
  }
  const runs = commandWrites(text, '/s', '/h').runs ?? []
  const left = await withoutOwnCalls(io, text, pipelineIn(text, '/s', '/h') as readonly RunCommand[], runs as never, p => allRules.shapeKind(p) !== null)
  return { held: handedToUnknown(left).length, runs: runs.length, handed }
}

test('#3416: reading a long suite\'s own calls hands the reader a few times its text, however many helpers it defines', async () => {
  // 2026-11-22: finding each helper reread the whole script before it, once a helper, so this
  // suite's 308,214 characters cost 6,711,692 handed to the reader (21.8 times the text, 6.4 to 7.4
  // seconds in five readings), in a hook that runs before the command does.
  const text = longSuite(40, 25)
  expect(text.split('\n').length).toBeGreaterThan(6000)
  const cost = await ownCost(text)
  // Every call was read and left out: the cost below is the work done, not the work skipped.
  expect({ runs: cost.runs, held: cost.held }).toEqual({ runs: 1000, held: 0 })
  expect(cost.handed / text.length).toBeLessThan(4)
  // The same suite reading in a file the guard cannot read at its top, as the repository's long
  // suites do. Whether that command stands at the top is asked in the reading that places the
  // definitions, not in one of its own: asked apart it handed the reader the whole text once more
  // (the Slack gate's suite, 449,087 characters: 1,355,198 handed before, 1,806,612 with it).
  const reading = text.replace('set -u\n', 'set -u\n. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {\n  exit 1\n}\n')
  expect(reading.length).toBeGreaterThan(text.length)
  const withRead = await ownCost(reading)
  // One run more, and the one left: the command that reads the file in, which is no call of a helper.
  expect({ runs: withRead.runs, held: withRead.held }).toEqual({ runs: 1001, held: 1 })
  expect(withRead.handed / reading.length).toBeLessThan(4)
  expect(withRead.handed - cost.handed).toBeLessThan(reading.length / 2)
})

test('#3416: a script whose own calls would cost more to read than the limit keeps the rest held', async () => {
  // The other way the cost grows: calls times the size of the body each is read as. Past the limit
  // (ownBudget) every run not yet read is given back as it was, a run of a program not known.
  const body = Array.from({ length: 60 }, (_, i) => `  if grep -qF "needle ${i}" "$1"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi`).join('\n')
  const text = `check() {\n${body}\n}\n${Array.from({ length: 400 }, (_, i) => `check docs/rounds/round-${i}.html`).join('\n')}\n`
  const cost = await ownCost(text)
  expect(cost.runs).toBe(400)
  expect(cost.handed).toBeLessThan(ownBudget(text) + 4 * text.length)
  expect(cost.held).toBeGreaterThan(0)
  expect(cost.held).toBeLessThan(400)
  // A short script is nowhere near it.
  expect((await ownCost(`check() {\n${body}\n}\ncheck docs/rounds/round-1.html\n`)).held).toBe(0)
})

test('#3416: calledWith writes a call\'s words in place of what the body names, and ownDefinitions finds each definition', () => {
  expect(calledWith(' echo "$1" $2 "${3}" \'$1\' \\$1 "it\'s $1" # $1\n mystery "$@" $* ', ['/a', '/b'])).toBe(' echo "/a" /b "${zz3416none}" \'$1\' \\$1 "it\'s /a" # $1\n mystery "/a /b" /a /b ')
  expect(calledWith('grep -q x <<< "$1"', ['/a'])).toBe('grep -q x <<< "/a"')
  expect(calledWith('cat <<EOF\n$1\nEOF', ['/a'])).toBeUndefined()
  const defs = (text: string) => ownDefinitions(pipelineIn(text, '/s', '/h') as readonly RunCommand[], 'run')
  expect(defs('run() { true; }\nfunction run { true; }\nfunction run() { true; }\nrunner() { true; }\n')).toEqual({ braces: [0, 3, 6], other: 0 })
  expect(defs('run () { true; }\n')).toEqual({ braces: [], other: 1 })
})

// #3017: on 2026-11-15 the conflict fixes for #3008 and #3011 in this guard's own register.ts were
// held as look changes. A merge had left rules.ts beside it as text the reader cannot follow (each
// side opening a block its own way), and a mod hook file read beside one is judged whole as drawing
// (drawsChange). This mod draws nothing: no file in TSX or JSX, and no surface named anywhere in
// it. What a mod draws on, read from its own code, now decides such a file: one drawing nothing is
// judged as code; one registering a band, a pane, a card or any rendering stays held.
const GUARD_RULES_CONFLICT = [
  'export const tooLong = (what: string): boolean => {',
  '<<<<<<< HEAD',
  '  if (what.length > 3) {',
  '=======',
  "  if (what.length > 3 && what !== 'ok') {",
  '>>>>>>> main',
  '    return true',
  '  }',
  '  return false',
  '}',
  '',
].join('\n')
const GUARD_REGISTER = [
  "import type { EngineInterface } from 'claude-code'",
  "import { tooLong } from './rules.ts'",
  'export const refuse = async ($: EngineInterface, what: string) => {',
  "  if (tooLong(what)) await $.ui.toast('Blocked an edit that changes the look.')",
  "  $.ui.log('design-round-guard: refused', { to: 'debug' })",
  '}',
  '',
].join('\n')

test('#3017: a hook file of a mod that draws nothing is judged as code beside a sibling no reader can follow; one in a mod registering a surface stays held', () => {
  const conflicted = [{ name: 'register.ts', text: GUARD_REGISTER }, { name: 'rules.ts', text: GUARD_RULES_CONFLICT }]
  const logic = GUARD_REGISTER.replace('tooLong(what)', 'tooLong(what.trim())')
  // The control: drawsChange alone reads the unreadable sibling as drawing, as it did on 2026-11-15.
  expect(drawsChange(conflicted, 'register.ts', GUARD_REGISTER, logic)).toBe(true)
  // A guard drawing nothing: a logic change, and the file written as it was, pass with nothing named.
  expect(changeOf(conflicted, 'register.ts', GUARD_REGISTER, logic, [])).toBe('passes')
  expect(changeOf(conflicted, 'register.ts', GUARD_REGISTER, GUARD_REGISTER, [])).toBe('passes')
  // Its own mod-kit copies, read beside it, name no surface either.
  expect(changeOf(conflicted, 'register.ts', GUARD_REGISTER, logic, [{ name: 'mod-kit/hold.ts', text: 'export const hold = async () => {}\n' }])).toBe('passes')
  // Held: a mod registering a band, a pane or a card anywhere, in this file or beside it, in a
  // mod-kit copy, through JSX, through Claude Code's own rendering, or newly added by this change.
  const surfaces = [
    "  await $.modkit.bandRow({ mod: 'g', id: 'x', slot: 'steps', lines: [] })",
    "  await $.modkit.pane({ mod: 'g', id: 'x', lines: [] })",
    '  await $.modkit.card({ toolUseId: id, title: what })',
    "  $.ui.open({ id: 'panel' })",
    "  on('ui.render', { component: 'ToolUse' }, ($, e, next) => next(e))",
  ]
  for (const line of surfaces) {
    const drawing = GUARD_REGISTER.replace("  $.ui.log('design-round-guard: refused', { to: 'debug' })", line)
    const drawnLogic = drawing.replace('tooLong(what)', 'tooLong(what.trim())')
    const files = [{ name: 'register.ts', text: drawing }, { name: 'rules.ts', text: GUARD_RULES_CONFLICT }]
    expect({ line, change: changeOf(files, 'register.ts', drawing, drawnLogic, []) }).toEqual({ line, change: 'look' })
    expect({ line, added: changeOf(conflicted, 'register.ts', GUARD_REGISTER, drawing, []) }).toEqual({ line, added: 'look' })
    expect({ line, copy: changeOf(conflicted, 'register.ts', GUARD_REGISTER, logic, [{ name: 'mod-kit/band.ts', text: `export const show = async ($: never) => {\n${line}\n}\n` }]) }).toEqual({ line, copy: 'look' })
  }
  expect(changeOf([...conflicted, { name: 'panel.tsx', text: 'export const Panel = () => <Box />\n' }], 'register.ts', GUARD_REGISTER, logic, [])).toBe('look')
  // A mod whose other folders could not be read is not shown to draw nothing: held, as before.
  expect(changeOf(conflicted, 'register.ts', GUARD_REGISTER, logic, null)).toBe('look')
  // A file that builds a line run where it can be read stays held, though no surface is named.
  expect(changeOf(conflicted, 'row.ts', undefined, "export const row = (t: string) => [{ text: t, color: 'warning' }]\n", [])).toBe('look')
})
