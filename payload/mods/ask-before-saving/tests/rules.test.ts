import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { pipeline } from './mod-kit/hooks/commands.ts'
import { editedFile, indexLineAdded, linksOnlyTo, memoryFileOf, shellAppended } from '../hooks/rules.ts'
import { APPROVAL_MS, untimed, addedText, addsLesson, lessonAddition, callShown, cannotCheck, display, lapseWait, lastingFiles, lastingMemory, madePermanent, mentioned, askInstruction, dialogOptions, patchNames, resolvePath, ruleOf, saveIdOf, saveKey, sourceOf, stands, withoutPythonText, writesWhat } from '../hooks/rules.ts'
import { pythonText } from './mod-kit/hooks/code.ts'

// What counts as lasting memory, when Dan's own words already made a rule permanent, and what the
// question shows (claude-config#618, docs/mods-design.md "Ask before saving").
const HOME = '/Users/dan'

// The disk beneath the judgement ($.modkit.workingTree in the mod): a checkout at each root given,
// and none anywhere else. `looked` is every path it was asked about.
const checkouts = (roots: string[] = ['/tmp/repo', '/private/var/folders/kd/T/clone']) => {
  const looked: string[] = []
  const inCheckout = async (abs: string) => {
    looked.push(abs)
    return roots.some(r => abs === r || abs.startsWith(`${r}/`))
  }
  return { inCheckout, looked }
}

test('every lasting memory file counts, and nothing beside it does', async () => {
  const yes = [
    '/Users/dan/.claude/projects/-Users-dan-Apps-slate/memory/no-merge-quizzes.md',
    '/Users/dan/.claude/projects/-Users-dan-Apps-slate/memory/MEMORY.md',
    // #705: a copy into the memory folder names the folder itself.
    '/Users/dan/.claude/projects/-Users-dan-Apps-slate/memory',
    '/Users/dan/Apps/slate/MEMORY.md',
    '/Users/dan/.claude/CLAUDE.md',
    '/Users/dan/.claude/LESSONS.md',
    '/Users/dan/Apps/claude-config/payload/LESSONS.md',
    '/Users/dan/Apps/slate/CLAUDE.md',
    '/Users/dan/Apps/slate/AGENTS.md',
  ]
  const no = [
    '/Users/dan/Apps/slate/README.md',
    '/Users/dan/.claude/LESSONS-INDEX-data-safety.md',
    '/Users/dan/.claude/projects/-Users-dan-Apps-slate/abc.jsonl',
    '/Users/dan/.claude/projects/-Users-dan-Apps-slate',
    '/Users/dan/Apps/slate/src/memory/cache.ts',
    '/Users/dan/Apps/slate/NOTCLAUDE.md',
    // A copy in a temporary folder (a backup, a test fixture in the scratchpad) loads into nothing.
    '/tmp/backup/CLAUDE.md',
    '/private/tmp/claude-501/p/s/scratchpad/CLAUDE.md',
    '/var/folders/kd/T/x/AGENTS.md',
  ]
  const { inCheckout } = checkouts()
  for (const p of yes) expect(`${p} ${await lastingMemory(p, HOME, inCheckout)}`).toBe(`${p} true`)
  for (const p of no) expect(`${p} ${await lastingMemory(p, HOME, inCheckout)}`).toBe(`${p} false`)
})

// #726: everything under a temporary folder was exempt, but a session started in a repository or
// worktree checked out there loads its CLAUDE.md or AGENTS.md, so a save to it went through unasked.
test('a file in a temporary folder counts inside a checkout there, and the disk is asked only about one that would otherwise count', async () => {
  const d = checkouts()
  expect(await lastingMemory('/tmp/repo/CLAUDE.md', HOME, d.inCheckout)).toBe(true)
  expect(await lastingMemory('/tmp/repo/docs/AGENTS.md', HOME, d.inCheckout)).toBe(true)
  expect(await lastingMemory('/private/var/folders/kd/T/clone/CLAUDE.md', HOME, d.inCheckout)).toBe(true)
  expect(await lastingMemory('/tmp/backup/CLAUDE.md', HOME, d.inCheckout)).toBe(false)
  expect(await lastingMemory('/tmp/repo/README.md', HOME, d.inCheckout)).toBe(false)
  expect(await lastingMemory('/Users/dan/Apps/slate/CLAUDE.md', HOME, d.inCheckout)).toBe(true)
  expect(d.looked).toEqual(['/tmp/repo/CLAUDE.md', '/tmp/repo/docs/AGENTS.md', '/private/var/folders/kd/T/clone/CLAUDE.md', '/tmp/backup/CLAUDE.md'])
})

test('a disk that cannot say whether a temporary file is in a checkout fails the judgement, never answers no', async () => {
  const failing = async () => {
    throw new Error('EACCES: /tmp/locked')
  }
  await expect(lastingMemory('/tmp/locked/CLAUDE.md', HOME, failing)).rejects.toThrow('EACCES: /tmp/locked')
})

test('a path is read the way the tools read it: home, relative and dot segments', () => {
  expect(resolvePath('~/.claude/CLAUDE.md', '/Users/dan/Apps/slate', HOME)).toBe('/Users/dan/.claude/CLAUDE.md')
  expect(resolvePath('CLAUDE.md', '/Users/dan/Apps/slate', HOME)).toBe('/Users/dan/Apps/slate/CLAUDE.md')
  expect(resolvePath('./docs/../AGENTS.md', '/Users/dan/Apps/slate', HOME)).toBe('/Users/dan/Apps/slate/AGENTS.md')
  expect(resolvePath('$HOME/.claude/LESSONS.md', '/x', HOME)).toBe('/Users/dan/.claude/LESSONS.md')
  expect(display('/Users/dan/.claude/CLAUDE.md', HOME)).toBe('~/.claude/CLAUDE.md')
  expect(display('/opt/x/CLAUDE.md', HOME)).toBe('/opt/x/CLAUDE.md')
})

test("Dan's words make a rule permanent only when they give one: the spec's phrases as an instruction", () => {
  for (const s of [
    'From now on, ask before merging',
    'always use pnpm here',
    'never push on Fridays',
    'remember that the deploy is manual',
    'Never merge on Fridays.',
    'ok, always run the linter first',
    'please remember to ask before deploying',
    'you should never push to main',
    'Thanks. And remember: the staging deploy is manual.',
    // #726: an instruction aimed at Claude still counts, wherever it starts.
    'Also, always use pnpm here',
    'I think you should always ask first',
    'Could you please never deploy on Fridays',
    'So never do that again.',
    'Rule: always run the linter first',
  ])
    expect(`${s}: ${madePermanent(s)}`).toBe(`${s}: true`)
  for (const s of [
    'just for now, skip the tests',
    'no, do not note anything',
    'it was remembered wrongly',
    'alwaysOn flag',
    undefined,
    // #705: the words anywhere in a sentence skipped the question.
    'never mind the screenshots for today',
    'the deploy always fails on Fridays, skip it for now',
    'it always fails on the first run',
    'I never said that',
    'do you remember where that file went?',
    // Review of #718: "remember" leading a message is no request by itself.
    'Remember when we shipped the band last week?',
    'remember the deploy failed yesterday?',
    'do you remember that file?',
    // #726: "and", "but", "so", "should" and "must" in the middle of a sentence lead narrative, not
    // an instruction aimed at Claude, and the save went through unasked.
    'It ran and never finished',
    'that should never take this long',
    'the build should always pass first',
    'it also never worked on my phone',
    'we must never let that happen again',
    'I tried it twice; never got it working',
    'It failed, never mind why',
    // Words limiting it to today or this session win over the permanent ones: asking is the harmless side.
    'From now on skip the screenshots, at least for today',
    'always use the staging key this session',
  ])
    expect(`${s}: ${madePermanent(s)}`).toBe(`${s}: false`)
})

test("the lasting memory a command's words name: by path where it can be read, by name where it cannot", async () => {
  const files = await lastingFiles(
    {
      files: [
        { word: 'CLAUDE.md', path: '/Users/dan/Apps/slate/CLAUDE.md' },
        { word: 'README.md', path: '/Users/dan/Apps/slate/README.md' },
        { word: '$DIR/AGENTS.md' },
        { word: '$DIR/notes.md' },
        { word: 'note.md', path: '/Users/dan/.claude/projects/p/memory/note.md' },
        { word: '/tmp/repo/CLAUDE.md', path: '/tmp/repo/CLAUDE.md' },
        { word: '/tmp/backup/CLAUDE.md', path: '/tmp/backup/CLAUDE.md' },
        // #726: a temporary path built from a variable cannot be looked for on the disk, so it counts.
        { word: '/tmp/$D/AGENTS.md' },
      ],
      unnamed: [],
    },
    HOME,
    checkouts().inCheckout,
    // A command mentioning no lasting memory, so each file is judged by its own word alone.
    'make docs',
  )
  expect(files).toEqual(['~/Apps/slate/CLAUDE.md', '$DIR/AGENTS.md', '~/.claude/projects/p/memory/note.md', '/tmp/repo/CLAUDE.md', '/tmp/$D/AGENTS.md'])
})

// #743: `F=<memory folder>/MEMORY.md; printf ... >> "$F"` went through unasked. The reader gave the
// target as written ($F) with no path, a word judged only by its file name, and the command's own
// text, which names MEMORY.md, was read only for a write the words do not name at all. A target the
// words cannot name is judged like one: by the lasting memory the command mentions anywhere.
test('a target the words cannot name is judged by the lasting memory the command mentions, anywhere in it', async () => {
  const { inCheckout } = checkouts()
  const judge = (files: { word: string; path?: string }[], command: string) => lastingFiles({ files, unnamed: [] }, HOME, inCheckout, command)
  // A variable the reader could not follow, a command's output, a pattern.
  expect(await judge([{ word: '$F' }], `F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`)).toEqual(['~/.claude/projects/p/memory/MEMORY.md'])
  expect(await judge([{ word: '$(ls ~/.claude/projects/p/memory/MEMORY.md)' }], `printf 'x\\n' >> "$(ls ~/.claude/projects/p/memory/MEMORY.md)"`)).toEqual(['~/.claude/projects/p/memory/MEMORY.md'])
  expect(await judge([{ word: '*.md' }], 'cd ~/.claude/projects/p/memory && echo x | tee -a *.md')).toEqual(['~/.claude/projects/p/memory'])
  // A path the reader reached through a variable and found to be no lasting memory still asks when
  // the command mentions some: the reader cannot see what an eval, a function or a script sets.
  expect(await judge([{ word: '$F', path: '/Users/dan/notes.txt' }], 'F=~/notes.txt; eval "F=~/.claude/CLAUDE.md"; echo x >> "$F"')).toEqual(['~/.claude/CLAUDE.md'])
  // One it followed to lasting memory is shown by that path, and nothing else the command mentions.
  expect(await judge([{ word: '$F', path: '/Users/dan/.claude/projects/p/memory/MEMORY.md' }], 'F=~/.claude/projects/p/memory/MEMORY.md; cat ~/.claude/CLAUDE.md >> "$F"')).toEqual([
    '~/.claude/projects/p/memory/MEMORY.md',
  ])
})

// #1241: `S=<scratchpad>/sf; cp payload/LESSONS.md $S/LESSONS.md` was refused twice, as a write that
// may reach lasting memory, because a target through a variable was judged by everything the command
// mentions, its own source included. A variable the command gives one literal folder, first and
// unconditionally, and that nothing after can change, holds that folder when the write runs, so the
// write is judged by where it lands, read by the guard itself and matched against the reader's path.
const SP = '/private/tmp/claude-501/p/s/scratchpad/sf'
const throughS = (command: string, word = '$S/LESSONS.md', path = `${SP}/LESSONS.md`) => {
  const { inCheckout } = checkouts()
  return lastingFiles({ files: [{ word, path }], unnamed: [] }, HOME, inCheckout, command)
}

test('a write through a variable the command first sets to one plain folder, absolute or under home, is judged where it lands', async () => {
  expect(await throughS(`S=${SP}; cp payload/LESSONS.md $S/LESSONS.md`)).toEqual([])
  expect(await throughS(`S="${SP}"; cp payload/LESSONS.md "$S/LESSONS.md"`)).toEqual([])
  expect(await throughS(`S='${SP}' && cp payload/LESSONS.md \${S}/LESSONS.md`, '${S}/LESSONS.md')).toEqual([])
  expect(await throughS(`D=/private/tmp/x S=${SP}\ncp payload/LESSONS.md $S/LESSONS.md`)).toEqual([])
  // A folder under home by ~/, which an assignment expands, is judged where it lands too: a notes file
  // there beside a command naming LESSONS.md is no save, and CLAUDE.md there is one.
  expect(await throughS('S=~/notes; cp payload/LESSONS.md $S/notes.txt', '$S/notes.txt', '/Users/dan/notes/notes.txt')).toEqual([])
  expect(await throughS('S=~/.claude; cp payload/LESSONS.md $S/CLAUDE.md', '$S/CLAUDE.md', '/Users/dan/.claude/CLAUDE.md')).toEqual(['~/.claude/CLAUDE.md'])
  // The same folder inside a checkout there is a session's lasting memory, and is asked about.
  expect(await throughS(`S=/tmp/repo; cp payload/LESSONS.md $S/LESSONS.md`, '$S/LESSONS.md', '/tmp/repo/LESSONS.md')).toEqual(['/tmp/repo/LESSONS.md'])
})

test('a write through a variable whose value the command cannot fix for certain is still judged by everything it mentions', async () => {
  const asked = [
    // Set conditionally: when the test fails, the variable keeps whatever the shell already held.
    `[ -d x ] && S=${SP}; cp payload/LESSONS.md $S/LESSONS.md`,
    `true || S=${SP}; cp payload/LESSONS.md $S/LESSONS.md`,
    `if true; then S=${SP}; fi; cp payload/LESSONS.md $S/LESSONS.md`,
    `cd /tmp && S=${SP}; cp payload/LESSONS.md $S/LESSONS.md`,
    // Set in a pipeline or in the background: a subshell, so the shell running the copy never sees it.
    `S=${SP} | cat; cp payload/LESSONS.md $S/LESSONS.md`,
    `S=${SP} & cp payload/LESSONS.md $S/LESSONS.md`,
    // Set only for one command, after the copy's own words were expanded.
    `S=${SP} cp payload/LESSONS.md $S/LESSONS.md`,
    // From a command's output, or from another variable.
    `S=$(mktemp -d); cp payload/LESSONS.md $S/LESSONS.md`,
    `S=\`echo ${SP}\`; cp payload/LESSONS.md $S/LESSONS.md`,
    `S=$TMPDIR/sf; cp payload/LESSONS.md $S/LESSONS.md`,
    // Reassigned, appended to, read into, looped over, set by reference, or set again by zsh's ::=.
    `S=${SP}; S=~/.claude; cp payload/LESSONS.md $S/LESSONS.md`,
    `S=${SP}; S=${SP}; cp payload/LESSONS.md $S/LESSONS.md`,
    `S=${SP}; S+=/x; cp payload/LESSONS.md $S/LESSONS.md`,
    `S=${SP}; read S < f; cp payload/LESSONS.md $S/LESSONS.md`,
    `S=${SP}; for S in ~/.claude; do cp payload/LESSONS.md $S/LESSONS.md; done`,
    `S=${SP}; typeset -n R=S; R=~/.claude; cp payload/LESSONS.md $S/LESSONS.md`,
    `S=${SP}; : \${S::=/Users/dan/.claude}; cp payload/LESSONS.md $S/LESSONS.md`,
    // Exported from elsewhere: set nowhere in the command, so the environment's value is used.
    'cp payload/LESSONS.md $S/LESSONS.md',
    // Text the shell runs may set anything, the variable included, without naming it.
    `S=${SP}; eval "$X"; cp payload/LESSONS.md $S/LESSONS.md`,
    `S=${SP}; source env.sh; cp payload/LESSONS.md $S/LESSONS.md`,
    `S=${SP}; . ./env.sh; cp payload/LESSONS.md $S/LESSONS.md`,
  ]
  for (const command of asked) expect(`${command}: ${(await throughS(command)).length}`).not.toBe(`${command}: 0`)
  // A value the shell may split, glob or climb out of through a link, or a relative folder, whose
  // place depends on every cd the reader follows: each given the path a reader would read it as.
  const unplain: [string, string][] = [
    [`S=${SP}/*; cp payload/LESSONS.md $S/LESSONS.md`, `${SP}/*/LESSONS.md`],
    [`S=${SP}/../x; cp payload/LESSONS.md $S/LESSONS.md`, '/private/tmp/claude-501/p/s/scratchpad/x/LESSONS.md'],
    [`S="${SP} x"; cp payload/LESSONS.md $S/LESSONS.md`, `${SP} x/LESSONS.md`],
    ['S=tmp/sf; cp payload/LESSONS.md $S/LESSONS.md', '/tmp/sf/LESSONS.md'],
  ]
  for (const [command, path] of unplain) expect(`${command}: ${(await throughS(command, '$S/LESSONS.md', path)).length}`).not.toBe(`${command}: 0`)
  // A quoted ~, which the shell leaves as a folder named ~ wherever the command runs.
  for (const q of ['"', "'"]) {
    const command = `S=${q}~/notes${q}; cp payload/LESSONS.md $S/notes.txt`
    expect(`${command}: ${(await throughS(command, '$S/notes.txt', '/Users/dan/notes/notes.txt')).length}`).not.toBe(`${command}: 0`)
  }
  // A variable the shell sets for itself changes under the command: `$_` after every command, REPLY on a read.
  expect((await throughS(`_=${SP}; cp payload/LESSONS.md $_/LESSONS.md`, '$_/LESSONS.md')).length).not.toBe(0)
  expect((await throughS(`REPLY=${SP}; read < f; cp payload/LESSONS.md $REPLY/LESSONS.md`, '$REPLY/LESSONS.md')).length).not.toBe(0)
  // The reader's path and the command's own value disagree: the guard does not pick a side.
  expect((await throughS(`S=${SP}; cp payload/LESSONS.md $S/LESSONS.md`, '$S/LESSONS.md', '/private/tmp/elsewhere/LESSONS.md')).length).not.toBe(0)
  // A path under the variable that climbs out of the folder is judged where it lands.
  expect(await throughS(`S=${SP}; cp payload/LESSONS.md $S/../../../../../../../Users/dan/.claude/CLAUDE.md`, '$S/../../../../../../../Users/dan/.claude/CLAUDE.md', '/Users/dan/.claude/CLAUDE.md')).toEqual(['~/.claude/CLAUDE.md'])
})

// The route a target the words cannot name takes asks the disk about a temporary path it mentions,
// as every other route does, and a disk that cannot answer fails the judgement: the hook then
// refuses the write rather than let it through.
test('a target the words cannot name, mentioning a temporary path the disk cannot answer for, fails the judgement', async () => {
  const failing = async () => {
    throw new Error('EACCES: /tmp/locked')
  }
  await expect(lastingFiles({ files: [{ word: '$F' }], unnamed: [] }, HOME, failing, 'F=/tmp/locked/CLAUDE.md; echo x > "$F"')).rejects.toThrow('EACCES: /tmp/locked')
})

test('a target the words cannot name, in a command that mentions no lasting memory, is no save; nor is a target they name', async () => {
  const { inCheckout } = checkouts()
  const judge = (files: { word: string; path?: string }[], command: string) => lastingFiles({ files, unnamed: [] }, HOME, inCheckout, command)
  // The positive first, in the same judge (L159): a mention makes it a save.
  expect(await judge([{ word: '$OUT' }], `printf 'x\\n' >> "$OUT"; cat ~/.claude/CLAUDE.md`)).toEqual(['~/.claude/CLAUDE.md'])
  expect(await judge([{ word: '$OUT' }], `printf 'x\\n' >> "$OUT"`)).toEqual([])
  expect(await judge([{ word: '$(mktemp)' }], `printf 'x\\n' > "$(mktemp)"`)).toEqual([])
  // A path spelled out, or under home by $HOME, is judged by that path alone, whatever else the
  // command mentions: a backup of CLAUDE.md is no save to it.
  expect(await judge([{ word: 'notes.txt', path: '/Users/dan/Apps/slate/notes.txt' }], 'cat ~/.claude/CLAUDE.md > notes.txt')).toEqual([])
  expect(await judge([{ word: '$HOME/notes.txt', path: '/Users/dan/notes.txt' }], 'cat ~/.claude/CLAUDE.md > $HOME/notes.txt')).toEqual([])
})

test('lasting memory a script or a patch mentions, read from its text', async () => {
  const { inCheckout } = checkouts()
  expect(await mentioned(`python3 -c "open('/Users/dan/.claude/CLAUDE.md','a').write('x')"`, HOME, inCheckout)).toEqual(['~/.claude/CLAUDE.md'])
  expect(await mentioned('--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ -1 +1,2 @@\n x\n+- rule', HOME, inCheckout)).toEqual(['AGENTS.md'])
  expect(await mentioned("node -e \"fs.writeFileSync(require('os').homedir() + '/.claude/projects/p/memory/x.md', 'y')\"", HOME, inCheckout)).toEqual(['/.claude/projects/p/memory/x.md'])
  expect(await mentioned('cat > ~/.claude/projects/p/memory/a.md', HOME, inCheckout)).toEqual(['~/.claude/projects/p/memory/a.md'])
  expect(await mentioned("python3 -c \"open('README.md','w').write('x')\"", HOME, inCheckout)).toEqual([])
  expect(await mentioned('cp CLAUDE.md /tmp/backup/CLAUDE.md', HOME, inCheckout)).toEqual(['CLAUDE.md'])
  // #726: a checkout under /tmp counts, as does a temporary path built from a variable, and one
  // that climbs out of the temporary folder is judged where it lands.
  expect(await mentioned("python3 -c \"open('/tmp/repo/CLAUDE.md','a')\"", HOME, inCheckout)).toEqual(['/tmp/repo/CLAUDE.md'])
  expect(await mentioned("python3 -c \"open('/tmp/$D/AGENTS.md','a')\"", HOME, inCheckout)).toEqual(['/tmp/$D/AGENTS.md'])
  expect(await mentioned("python3 -c \"open('/tmp/../Users/dan/.claude/CLAUDE.md','a')\"", HOME, inCheckout)).toEqual(['~/.claude/CLAUDE.md'])
  // #743: a path in the memory folder ends where the shell ends a word, so the ; or ) after it is not
  // shown as part of the file.
  expect(await mentioned(`F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`, HOME, inCheckout)).toEqual(['~/.claude/projects/p/memory/MEMORY.md'])
  expect(await mentioned(`printf x >> "$(ls ~/.claude/projects/p/memory/MEMORY.md)"`, HOME, inCheckout)).toEqual(['~/.claude/projects/p/memory/MEMORY.md'])
  expect(await mentioned('ls ~/.claude/projects/p/memory|wc -l&&cat ~/.claude/projects/q/memory>x', HOME, inCheckout)).toEqual(['~/.claude/projects/p/memory', '~/.claude/projects/q/memory'])
})

// #1883: a git apply of a patch changing five code files was refused as a save to LESSONS.md, which
// the patch named only in a changed line of another file. A patch is judged by the lines that name
// the files it changes; one with no such line, or one whose text is encoded, is read whole as before.
const CODE_PATCH =
  'From 1234 Mon Sep 17 00:00:00 2001\nSubject: [PATCH] Note the rule beside LESSONS.md\n\nKeeps payload/LESSONS.md as it is.\n---\n' +
  ' payload/mods/x/hooks/a.ts | 2 +-\n\n' +
  'diff --git a/payload/mods/x/hooks/a.ts b/payload/mods/x/hooks/a.ts\nindex 1..2 100644\n--- a/payload/mods/x/hooks/a.ts\n+++ b/payload/mods/x/hooks/a.ts\n' +
  '@@ -1,3 +1,3 @@\n // the rule lives in ~/.claude/LESSONS.md\n-const a = 1 // CLAUDE.md\n+const a = 2 // AGENTS.md\n x\n'
test('a patch is judged by the files it changes, never by words elsewhere in it (#1883)', async () => {
  const { inCheckout } = checkouts()
  const judged = async (t: string) => mentioned(patchNames(t) ?? t, HOME, inCheckout)
  // Named only in its message, its summary, a context line and a changed line: no lasting memory.
  expect(await judged(CODE_PATCH)).toEqual([])
  // One that really changes a lasting memory file is still found, by every line that can name it.
  expect(await judged('diff --git a/payload/LESSONS.md b/payload/LESSONS.md\n--- a/payload/LESSONS.md\n+++ b/payload/LESSONS.md\n@@ -1 +1,2 @@\n x\n+y\n')).toEqual(['payload/LESSONS.md'])
  expect(await judged('--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ -1 +1,2 @@\n x\n+- rule\n')).toEqual(['AGENTS.md'])
  expect(await judged('diff --git a/notes.md b/CLAUDE.md\nsimilarity index 100%\nrename from notes.md\nrename to CLAUDE.md\n')).toEqual(['CLAUDE.md'])
  expect(await judged('diff --git a/notes.md b/CLAUDE.md\ncopy from notes.md\ncopy to x/CLAUDE.md\n')).toEqual(['CLAUDE.md', 'x/CLAUDE.md'])
  expect(await judged('Index: MEMORY.md\n===\n--- MEMORY.md.orig\n+++ MEMORY.md\n')).toEqual(['MEMORY.md'])
  expect(await judged('*** a/CLAUDE.md\tdate\n--- b/CLAUDE.md\tdate\n***************\n*** 1 ****\n')).toEqual(['CLAUDE.md'])
  // GNU patch takes an indented diff, so an indented header still names its file.
  expect(await judged('  --- a/x.ts\n  +++ b/payload/LESSONS.md\n')).toEqual(['payload/LESSONS.md'])
  // No line naming a file (a normal diff, an ed script): read whole, as before.
  expect(patchNames('1a2\n> see LESSONS.md\n')).toBeUndefined()
  expect(await judged('1a2\n> see LESSONS.md\n')).toEqual(['LESSONS.md'])
  // An encoded mail can hide a header (quoted-printable wraps a long path), so it is read whole.
  const encoded = `Content-Transfer-Encoding: quoted-printable\n\n${CODE_PATCH}`
  expect(patchNames(encoded)).toBeUndefined()
  expect(patchNames(`Content-Transfer-Encoding: 8bit\n\n${CODE_PATCH}`)).toBeDefined()
})

// #940: a python heredoc that wrote only a test script was asked about as a save to the global
// CLAUDE.md, because a comment the script added named that file in a sentence. In a python program
// a path is a string that ends on it (a literal of its own, or one a quote closes inside code run as
// text); a mention in a comment, or in a string that goes on past it, is text the program holds.
// Tested on what it must keep as well as what it must drop (L104).
test('in a python program, a mention in a comment or in a sentence is text, and one a string ends on is a path', async () => {
  const { inCheckout } = checkouts()
  const left = async (code: string) => {
    const out = withoutPythonText(code, pythonText(code))
    // Only the mention's own characters change, so the program can be put back where it was read.
    expect(out.length).toBe(code.length)
    return mentioned(out, HOME, inCheckout)
  }
  // Text: dropped.
  for (const code of [
    "new='''\n# Dan's mods have the same standing as ~/.claude/CLAUDE.md. The CLI lists\n# each as `<name>@inline`.\n'''\nopen(p,'w').write(new)",
    "# keep the rules in ~/.claude/CLAUDE.md short\nopen('x.txt','w').write('1')",
    "s=s.replace('a', 'see ~/.claude/projects/p/memory/MEMORY.md for why')",
    "open('notes.txt','w').write(\"\"\"It asked about CLAUDE.md again,\nand AGENTS.md too.\"\"\")",
    // A backup's name goes on past the file name, so it is no lasting memory either.
    "open('/Users/dan/.claude/CLAUDE.md.bak','w').write(s)",
    // An escaped quote keeps the string open, and the program after it is read as code again.
    "s='it\\'s in ~/.claude/CLAUDE.md now'\nopen('x.txt','w').write(s)",
    "s=r'it\\'s in ~/.claude/CLAUDE.md now'\nopen('x.txt','w').write(s)",
    // Markdown backticks in a sentence, and a shell substitution held as text: no quote in python.
    "open('x.md','w').write('Rules live in `~/.claude/CLAUDE.md` for every session.')",
    "open('x.sh','w').write('echo `cat ~/.claude/CLAUDE.md`')",
  ])
    expect(`${code}: ${await left(code)}`).toBe(`${code}: `)
  // Paths: kept.
  for (const [code, file] of [
    ["open('/Users/dan/.claude/CLAUDE.md','a').write('- rule')", '~/.claude/CLAUDE.md'],
    ["import os\nopen(os.path.expanduser(\"~/.claude/projects/p/memory/MEMORY.md\"),'a')", '~/.claude/projects/p/memory/MEMORY.md'],
    ["from pathlib import Path\n(Path.home() / '.claude' / 'CLAUDE.md').write_text('x')", 'CLAUDE.md'],
    ["d=os.path.join(root, 'AGENTS.md')", 'AGENTS.md'],
    // Code held in a string and run: the path is closed by a quote inside it.
    ["exec(\"open('/Users/dan/.claude/CLAUDE.md','a').write('x')\")", '~/.claude/CLAUDE.md'],
    // A shell line held as text names its file inside quotes of its own.
    ["new='''\nprintf '# rules' > \"$E27HA/CLAUDE.md\"\n'''", '$E27HA/CLAUDE.md'],
    // An f-string's braces hold code, so nothing in one is taken for text.
    ['open(f"{home}/.claude/CLAUDE.md is {mode}", "a")', '/.claude/CLAUDE.md'],
    // The program after a string with an escaped quote is code again.
    ["s='it\\'s here'\nopen('/Users/dan/.claude/AGENTS.md','a')", '~/.claude/AGENTS.md'],
    ["s=r'it\\'s here'\nopen('/Users/dan/.claude/AGENTS.md','a')", '~/.claude/AGENTS.md'],
    // A comment that is really inside a string is no comment.
    ["s='# x'; open('/Users/dan/.claude/CLAUDE.md','a')", '~/.claude/CLAUDE.md'],
  ])
    expect(`${code}: ${await left(code as string)}`).toBe(`${code}: ${file}`)
})

// #940: where the file a command writes cannot be read from its words, the question rests on what
// it mentions, and the refusal says so, naming the file it took to be written, so a misfire shows.
test('a file taken from what a command mentions is marked as such, and its mentions can be read from other text', async () => {
  const { inCheckout } = checkouts()
  const read = { guessed: [] as string[] }
  expect(await lastingFiles({ files: [{ word: '$F' }], unnamed: [] }, HOME, inCheckout, 'printf x >> "$F"; cat ~/.claude/CLAUDE.md', undefined, read)).toEqual(['~/.claude/CLAUDE.md'])
  expect(read.guessed).toEqual(['~/.claude/CLAUDE.md'])
  // A file the words name is never marked, whatever else the command mentions.
  const named = { guessed: [] as string[] }
  expect(
    await lastingFiles({ files: [{ word: 'CLAUDE.md', path: '/Users/dan/Apps/slate/CLAUDE.md' }], unnamed: [] }, HOME, inCheckout, 'echo x >> CLAUDE.md', undefined, named),
  ).toEqual(['~/Apps/slate/CLAUDE.md'])
  expect(named.guessed).toEqual([])
  // Mentions read from the text given, the command's with its program's prose taken out.
  expect(await lastingFiles({ files: [{ word: '$F' }], unnamed: [] }, HOME, inCheckout, 'printf x >> "$F"; cat ~/.claude/CLAUDE.md', undefined, { text: 'printf x >> "$F"' })).toEqual([])
})

// #1592: a file handed to a script as its argument (mod-kit's `runs`) counts as a file the words
// name, marked as handed so the refusal says so; one the words also write is said as written.
test('a lasting memory file handed to a script counts, marked as handed, and is said as handed to a script', async () => {
  const { inCheckout } = checkouts()
  const runs = [{ args: [{ word: 'CLAUDE.md', path: '/Users/dan/Apps/slate/CLAUDE.md' }, { word: 'notes.md', path: '/Users/dan/Apps/slate/notes.md' }] }]
  const read = { handed: [] as string[], guessed: [] as string[] }
  expect(await lastingFiles({ files: [], unnamed: [], runs }, HOME, inCheckout, 'python3 x.py CLAUDE.md notes.md', undefined, read)).toEqual(['~/Apps/slate/CLAUDE.md'])
  expect(read).toEqual({ handed: ['~/Apps/slate/CLAUDE.md'], guessed: [] })
  const both = { handed: [] as string[] }
  const files = [{ word: 'CLAUDE.md', path: '/Users/dan/Apps/slate/CLAUDE.md' }]
  expect(await lastingFiles({ files, unnamed: [], runs }, HOME, inCheckout, 'python3 x.py CLAUDE.md > CLAUDE.md', undefined, both)).toEqual(['~/Apps/slate/CLAUDE.md'])
  expect(both.handed).toEqual([])
  expect(writesWhat(['~/a/CLAUDE.md'], [], ['~/a/CLAUDE.md'])).toBe('this hands lasting memory (~/a/CLAUDE.md) to a script, which may write it')
  expect(writesWhat(['~/b/AGENTS.md', '~/a/CLAUDE.md'], [], ['~/a/CLAUDE.md'])).toBe(
    'this writes lasting memory (~/b/AGENTS.md), and it hands lasting memory (~/a/CLAUDE.md) to a script, which may write it',
  )
})

// Lessons review of #731: the hook's refusal read the failure's message with no guard, so a failure
// that arrived without its error would make the refusal itself throw, and a hook that throws is
// skipped: the save would go through unasked. The refusal is built from whatever arrives.
test('a hook that could not finish is refused with its reason, and with no reason at all it is still refused', () => {
  expect(cannotCheck({ message: 'EACCES: /tmp/locked' })).toBe(
    'Not saved: Ask before saving could not check whether this writes lasting memory (EACCES: /tmp/locked). Tell Dan what you meant to save instead.',
  )
  expect(cannotCheck({})).toContain('could not check whether this writes lasting memory (it failed)')
  expect(cannotCheck(undefined)).toContain('could not check whether this writes lasting memory (it failed)')
})

test('the text shown is what would be saved: the new lines of a rewrite, the whole of a new file', () => {
  expect(addedText('# Memory\n- a\n- b\n', undefined)).toBe('# Memory\n- a\n- b')
  expect(addedText('# Memory\n- a\n- new rule\n', '# Memory\n- a\n')).toBe('- new rule')
  // A rewrite that adds nothing new shows the whole text rather than nothing.
  expect(addedText('# Memory\n', '# Memory\n- a\n')).toBe('# Memory')
})

// #777: the question is asked in Claude Code's own dialog, by Claude, never in the band. The mod hands
// Claude what to ask: the file named, the rule in plain words, never the command, and the three
// answers, whose labels and lines the mod sets itself so the answer read back is one of them.
test("the instruction to ask names the file, asks for the rule in plain words, and carries the save's id", () => {
  const t = askInstruction('toolu_1', ['~/.claude/CLAUDE.md'])
  expect(t).toContain('AskUserQuestion')
  expect(t).toContain('{"source": "ask-before-saving:toolu_1"}')
  expect(t).toContain('~/.claude/CLAUDE.md')
  expect(t).toContain('one plain sentence')
  expect(t).toContain('never the command')
  expect(t).toContain('send this same call again unchanged')
  expect(t).not.toContain('band')
  expect(t).toContain('this writes lasting memory (~/.claude/CLAUDE.md)')
  expect(t).not.toContain('may write')
  // #940: a file taken from what the command mentions is said to be that, so a misfire shows.
  const g = askInstruction('toolu_2', ['~/.claude/CLAUDE.md'], ['~/.claude/CLAUDE.md'])
  expect(g).toContain('this may write lasting memory (~/.claude/CLAUDE.md)')
  expect(g).toContain('its words do not name the file it writes, and they mention ~/.claude/CLAUDE.md')
  expect(g).toContain('make the change with Edit or Write on that file')
  expect(g).toContain('{"source": "ask-before-saving:toolu_2"}')
  // A file the words name beside one taken from a mention: each said as what it is (lessons review
  // of #963: both were called uncertain).
  const both = askInstruction('toolu_3', ['~/Apps/a/CLAUDE.md', '~/.claude/CLAUDE.md'], ['~/.claude/CLAUDE.md'])
  expect(both).toContain(
    'this writes lasting memory (~/Apps/a/CLAUDE.md) and may write ~/.claude/CLAUDE.md: its words do not name every file it writes, and they mention ~/.claude/CLAUDE.md',
  )
  expect(both).toContain('names ~/Apps/a/CLAUDE.md, ~/.claude/CLAUDE.md')
})

test('the three answers each say what they do, and a save id is read back only from its own source', () => {
  expect(dialogOptions(['~/.claude/CLAUDE.md']).map(o => [o.label, o.description])).toEqual([
    ['For good', 'Saved to ~/.claude/CLAUDE.md'],
    ['Just this session', 'Followed until this session ends; nothing is written'],
    ['Not at all', 'Nothing is saved'],
  ])
  expect(sourceOf('toolu_a')).toBe('ask-before-saving:toolu_a')
  expect(saveIdOf('ask-before-saving:toolu_a')).toBe('toolu_a')
  expect(saveIdOf('next-issue')).toBeUndefined()
  expect(saveIdOf(undefined)).toBeUndefined()
  expect(saveIdOf('ask-before-saving:')).toBeUndefined()
})

test('the rule kept for this session is the plain words Claude asked with, without the file or the question mark', () => {
  expect(ruleOf('Save to ~/.claude/CLAUDE.md for good: never merge on Fridays?', ['~/.claude/CLAUDE.md'])).toBe('never merge on Fridays')
  expect(ruleOf('Never merge on Fridays, saved to CLAUDE.md?', ['CLAUDE.md'])).toBe('Never merge on Fridays, saved to CLAUDE.md')
})

// #777: a subagent's call building throwaway fixture homes in a test file mentioned `$E27HA/CLAUDE.md`
// inside a python heredoc and was asked about as a save. Each Bash call is a fresh shell, so a
// variable the command never sets and nothing in the environment holds expands to nothing, and a
// path through it reaches no lasting memory. One the command sets, a loop or read fills, or the
// environment holds still counts: asking is the harmless side.
test('a mention through a variable nothing sets is no lasting memory; one something can set still counts', async () => {
  const { inCheckout } = checkouts()
  const unset = async () => false
  const env = (name: string) => async (n: string) => n === name
  const fixture = "python3 - <<'EOF'\np='tests/t.sh'\nnew=r'''\nE27HA=\"$WORK/e627-homeA\"; printf '# rules\\n' > \"$E27HA/CLAUDE.md\"\n'''\nEOF"
  expect(await mentioned(fixture, HOME, inCheckout, unset)).toEqual([])
  // The same text with nothing to say what is set, as before #777, counted.
  expect(await mentioned(fixture, HOME, inCheckout)).toEqual(['$E27HA/CLAUDE.md'])
  expect(await mentioned('echo x >> "$CLAUDE_PROJECT_DIR/CLAUDE.md"', HOME, inCheckout, env('CLAUDE_PROJECT_DIR'))).toEqual(['$CLAUDE_PROJECT_DIR/CLAUDE.md'])
  expect(await mentioned('echo x >> "$NOPE/CLAUDE.md"', HOME, inCheckout, unset)).toEqual([])
  expect(await mentioned(`D=~/.claude; python3 -c "open('$D/CLAUDE.md','a')"`, HOME, inCheckout, unset)).toEqual(['$D/CLAUDE.md'])
  expect(await mentioned('R=~/.claude; D="$R/x"; echo y >> "$D/CLAUDE.md"', HOME, inCheckout, unset)).toEqual(['$D/CLAUDE.md'])
  expect(await mentioned('D="$CLAUDE_PROJECT_DIR"; echo y >> "$D/AGENTS.md"', HOME, inCheckout, env('CLAUDE_PROJECT_DIR'))).toEqual(['$D/AGENTS.md'])
  expect(await mentioned('export D=$HOME/.claude; echo y >> "$D/CLAUDE.md"', HOME, inCheckout, unset)).toEqual(['$D/CLAUDE.md'])
  expect(await mentioned('for D in a b; do echo y >> "$D/CLAUDE.md"; done', HOME, inCheckout, unset)).toEqual(['$D/CLAUDE.md'])
  expect(await mentioned('read -r D; echo y >> "$D/CLAUDE.md"', HOME, inCheckout, unset)).toEqual(['$D/CLAUDE.md'])
  expect(await mentioned('W=$(cat where.txt); echo y > "$W/CLAUDE.md"', HOME, inCheckout, unset)).toEqual(['$W/CLAUDE.md'])
  expect(await mentioned('A="$B"; B="$A"; echo y > "$A/CLAUDE.md"', HOME, inCheckout, unset)).toEqual(['$A/CLAUDE.md'])
  // A fresh temporary folder is loaded into no session.
  expect(await mentioned('W=$(mktemp -d); echo y > "$W/CLAUDE.md"', HOME, inCheckout, unset)).toEqual([])
  expect(await mentioned('W="$(mktemp -d -t notes)"; echo y > "$W/CLAUDE.md"', HOME, inCheckout, unset)).toEqual([])
  // #830: one made where a template or -p puts it can be anywhere, the memory folder included.
  expect(await mentioned('W=$(mktemp -d ~/.claude/x.XXXX); echo y > "$W/CLAUDE.md"', HOME, inCheckout, unset)).toEqual(['$W/CLAUDE.md'])
  expect(await mentioned('W=$(mktemp -p ~/.claude); echo y > "$W/CLAUDE.md"', HOME, inCheckout, unset)).toEqual(['$W/CLAUDE.md'])
  // A name that only contains the variable's is not it.
  expect(await mentioned('SYNC_WORK=~/.claude; echo y > "$WORK/CLAUDE.md"', HOME, inCheckout, unset)).toEqual([])
  // A variable every shell sets for itself is always set, whatever printenv says (lessons review
  // of #783: `$PWD/CLAUDE.md` was judged unset and its save went through unasked).
  for (const v of ['PWD', 'OLDPWD', 'TMPDIR', 'USER', 'LOGNAME', 'SHELL'])
    expect(await mentioned(`echo y >> "$${v}/CLAUDE.md"`, HOME, inCheckout, unset)).toEqual([`$${v}/CLAUDE.md`])
  expect(await mentioned('D="$PWD"; echo y >> "$D/AGENTS.md"', HOME, inCheckout, unset)).toEqual(['$D/AGENTS.md'])
  // A path spelled out beside it is judged as before.
  expect(await mentioned('echo y > "$NOPE/x"; cat ~/.claude/CLAUDE.md', HOME, inCheckout, unset)).toEqual(['~/.claude/CLAUDE.md'])
})

test("a target named through a variable nothing sets is judged the same, by name or by the command's mentions", async () => {
  const { inCheckout } = checkouts()
  const unset = async () => false
  const judge = (word: string, command: string) => lastingFiles({ files: [{ word }], unnamed: [] }, HOME, inCheckout, command, unset)
  expect(await judge('$E27HA/CLAUDE.md', 'E27HA="$WORK/a"; printf x > "$E27HA/CLAUDE.md"')).toEqual([])
  expect(await judge('$D/CLAUDE.md', 'D=$(cat where); printf x > "$D/CLAUDE.md"')).toEqual(['$D/CLAUDE.md'])
})

// #738: For good approves a save, and Claude sends the call again from a request of its own. What
// identifies the save is what it writes, never how the call was spelled around it: Claude words a
// Bash call's description afresh each time, and may give a path whole where it gave it relative.
test('the key of a save is what it writes: the file and the text, never the call words around them', () => {
  const cwd = '/Users/dan/Apps/slate'
  const key = (tool: string, input: Record<string, unknown>) => saveKey(tool, input, cwd, HOME)
  const command = `printf 'x\\n' >> ~/.claude/projects/p/memory/MEMORY.md`
  expect(key('Bash', { command, description: 'Append the rule' })).toBe(key('Bash', { command, description: 'Save it', timeout: 5000 }))
  expect(key('Bash', { command })).not.toBe(key('Bash', { command: `${command} ` }))
  // A command's relative targets are where the session runs, so the same words elsewhere are another save.
  expect(saveKey('Bash', { command: 'cat >> CLAUDE.md' }, cwd, HOME)).not.toBe(saveKey('Bash', { command: 'cat >> CLAUDE.md' }, '/Users/dan/Apps/other', HOME))
  expect(key('Write', { file_path: 'AGENTS.md', content: '- a\n' })).toBe(key('Write', { file_path: `${cwd}/AGENTS.md`, content: '- a\n' }))
  expect(key('Write', { file_path: 'AGENTS.md', content: '- a\n' })).not.toBe(key('Write', { file_path: 'AGENTS.md', content: '- b\n' }))
  expect(key('Write', { file_path: 'AGENTS.md', content: '- a\n' })).not.toBe(key('Write', { file_path: 'CLAUDE.md', content: '- a\n' }))
  const edit = { file_path: '~/.claude/CLAUDE.md', old_string: 'a', new_string: 'a\n- b' }
  expect(key('Edit', edit)).toBe(key('Edit', { ...edit, file_path: `${HOME}/.claude/CLAUDE.md`, replace_all: false }))
  expect(key('Edit', edit)).not.toBe(key('Edit', { ...edit, replace_all: true }))
  expect(key('Edit', edit)).not.toBe(key('Edit', { ...edit, new_string: 'a\n- c' }))
  // A Write and a Bash call that happen to carry the same text are different saves.
  expect(key('Write', { file_path: 'x', content: 'y' })).not.toBe(key('Bash', { command: 'y' }))
})

test('the call Claude is asked to send again is shown by what it writes, as the call carries it', () => {
  expect(JSON.parse(callShown('Bash', { command: "echo '- a' >> CLAUDE.md", description: 'Append' }))).toEqual({ command: "echo '- a' >> CLAUDE.md" })
  expect(JSON.parse(callShown('Write', { file_path: 'AGENTS.md', content: '- a\n' }))).toEqual({ file_path: 'AGENTS.md', content: '- a\n' })
  expect(JSON.parse(callShown('Edit', { file_path: 'CLAUDE.md', old_string: 'a', new_string: 'b', replace_all: false }))).toEqual({ file_path: 'CLAUDE.md', old_string: 'a', new_string: 'b' })
  expect(JSON.parse(callShown('Edit', { file_path: 'CLAUDE.md', old_string: 'a', new_string: 'b', replace_all: true }))).toEqual({ file_path: 'CLAUDE.md', old_string: 'a', new_string: 'b', replace_all: true })
})

// L523: an approval lapses, and the time it stands is a chosen number the copy names.
test('an approval stands for ten minutes', () => {
  expect(APPROVAL_MS).toBe(10 * 60_000)
})

// L50: an approval's time comes back from storage, and one that is not a number compares false
// against every clock, so it would stand for ever and let its save through unasked. It stands for
// nothing instead, and its wait is none, never one $.clock.after refuses by throwing (a wait that is
// not a non-negative number throws there, measured 2026-10-05 with `claude plugin test`).
test('an approval stands only while its time is a number still to come, and its wait is never one a timer refuses', () => {
  expect(stands(1000, 999)).toBe(true)
  expect(stands(1000, 1000)).toBe(false)
  for (const bad of [undefined, null, Number.NaN, Number.POSITIVE_INFINITY, '2000', {}]) expect(`${String(bad)}: ${stands(bad, 0)}`).toBe(`${String(bad)}: false`)
  expect(lapseWait(1000, 400)).toBe(600)
  expect(lapseWait(1000, 1500)).toBe(0)
  for (const bad of [undefined, null, Number.NaN, '2000']) expect(lapseWait(bad, 0)).toBe(0)
})

// Lessons review of #869: the toast for a lapse that cannot be timed said For good for a lesson
// approval too. It names the answer Dan pressed. ($.clock.after refuses through the engine, so only a
// wait it rejects at once reaches this toast, and no session test can make it; the builder is tested.)
test('a lapse that cannot be timed names the answer Dan pressed', () => {
  const lesson = untimed({ id: 'l', key: 'lesson:x', files: ['~/.claude/LESSONS.md'], until: 1, lesson: 'x' }, 'the mod reloaded')
  expect(lesson).toContain('The 10 minute limit on Add to LESSONS.md for saving to ~/.claude/LESSONS.md could not be timed (the mod reloaded)')
  expect(lesson).not.toContain('For good')
  expect(untimed({ id: 's', key: 'k', files: ['~/Apps/slate/AGENTS.md'], until: 1 }, 'x')).toContain('The 10 minute limit on For good for saving to ~/Apps/slate/AGENTS.md')
})

// #1691: Dan answered Add to LESSONS.md for L1030 and was asked For good about it again, because the
// Edit that added it took whole lines WITH their newline as its old text, a shape the judgement
// refused, so the approval lapsed unused. The fixture is the real call of 2026-10-24, from the
// session's transcript, against the lessons file as it then stood around that place.
const L1030_RULE =
  "Never put a heredoc inside a $( ) command substitution in a script macOS bash 3.2 runs, because a single quote anywhere in the heredoc's body breaks the parse and the whole script dies before running anything; write the heredoc's output to a file and read the file instead."
const L1015_SHORT = '  SHORT: A per item `read < <(cmd)` loop kills macOS bash 3.2 part way through a big list; use a command substitution and test at the real count.\n'
const L1030_ENTRY =
  "- **L1030. Never put a heredoc inside a $( ) command substitution in a script macOS bash 3.2\n  runs, because a single quote anywhere in the heredoc's body breaks the parse and the whole\n  script dies before running anything; write the heredoc's output to a file and read the\n  file instead.**\n  (claude-config#1690, 2026-10-24)\n  SHORT: A heredoc inside $( ) with a single quote in it breaks macOS bash 3.2's parse and kills the script; write to a file instead.\n"
const L1030_ADDED = L1030_ENTRY.replace(/\n$/, '')
const LESSONS_AROUND = `# Lessons\n\n- **L1015. A shell loop that reads through \`< <(command)\` once per item leaks a process.**\n${L1015_SHORT}\n- **L488. A shell script that sources a library with \`.\` and does not run \`set -e\`.**\n`

test('an Edit whose old text is whole lines with their newline adds the entry it inserts, as the same text written whole would', () => {
  const edit = { file_path: 'x', old_string: L1015_SHORT, new_string: L1015_SHORT + L1030_ENTRY }
  const added = lessonAddition('Edit', edit, LESSONS_AROUND)
  expect(added).toBe(L1030_ADDED)
  expect(addsLesson(added ?? '', L1030_RULE)).toBe(true)
  // The entry before kept text that starts with its newline, and the same file written whole.
  expect(lessonAddition('Edit', { file_path: 'x', old_string: '\n- **L488.', new_string: `\n${L1030_ENTRY}- **L488.` }, LESSONS_AROUND)).toBe(L1030_ADDED)
  // The shape every earlier test used, kept lines without their newline, still adds it.
  expect(lessonAddition('Edit', { file_path: 'x', old_string: L1015_SHORT.replace(/\n$/, ''), new_string: L1015_SHORT + L1030_ADDED }, LESSONS_AROUND)).toBe(L1030_ADDED)
  const whole = LESSONS_AROUND.replace(L1015_SHORT, L1015_SHORT + L1030_ENTRY)
  expect(lessonAddition('Write', { file_path: 'x', content: whole }, LESSONS_AROUND)).toBe(L1030_ADDED)
})

test('an Edit that does more than insert one entry at a line boundary adds nothing, however its old text is cut', () => {
  const at = (old_string: string, new_string: string, extra: Record<string, unknown> = {}) => lessonAddition('Edit', { file_path: 'x', old_string, new_string, ...extra }, LESSONS_AROUND)
  // Spliced into the middle of a line.
  expect(at('a per item', `a per item\n${L1030_ENTRY}`)).toBeUndefined()
  // A kept line changed beside the entry.
  expect(at(L1015_SHORT, L1015_SHORT.replace('big list', 'long list') + L1030_ENTRY)).toBeUndefined()
  // A kept line dropped for the entry.
  expect(at(L1015_SHORT, L1030_ENTRY)).toBeUndefined()
  // Old text found more than once, or not at all, or every occurrence replaced, or none given.
  expect(at('\n', `\n${L1030_ENTRY}`)).toBeUndefined()
  expect(at('nowhere in the file\n', `nowhere in the file\n${L1030_ENTRY}`)).toBeUndefined()
  expect(at(L1015_SHORT, L1015_SHORT + L1030_ENTRY, { replace_all: true })).toBeUndefined()
  expect(at('', L1030_ENTRY)).toBeUndefined()
  // Two entries at once: one block, which is not the one approved lesson.
  const two = at(L1015_SHORT, L1015_SHORT + L1030_ENTRY + L1030_ENTRY.replace('L1030', 'L1031'))
  expect(two !== undefined && addsLesson(two, L1030_RULE)).toBe(false)
  // No file to judge against.
  expect(lessonAddition('Edit', { file_path: 'x', old_string: L1015_SHORT, new_string: L1015_SHORT + L1030_ENTRY }, undefined)).toBeUndefined()
})

// #1794: one For good on a memory file also covers the one index line linking it.
const MEMORY_DIR = '/Users/dan/.claude/projects/-Users-dan-Apps-slate/memory'
const IDX = `${MEMORY_DIR}/MEMORY.md`
const DASH = String.fromCharCode(0x2014)
const IDX_TEXT = `- [Live sync clone](live-sync.md) ${DASH} the scheduled clone\n- [Band size](band-size.md) ${DASH} global\n`
const LINE = `- [Rule](rule.md) ${DASH} the rule it holds`

test('a memory file an approval can carry its index line for is one directly in a project memory folder, never the index itself', () => {
  expect(memoryFileOf(`${MEMORY_DIR}/rule.md`, HOME)).toEqual({ index: IDX, name: 'rule.md' })
  expect(memoryFileOf(`${MEMORY_DIR}/MEMORY.md`, HOME)).toBeUndefined()
  // A file in a folder under the memory folder, the folder itself, a file elsewhere.
  expect(memoryFileOf(`${MEMORY_DIR}/old/rule.md`, HOME)).toBeUndefined()
  expect(memoryFileOf(MEMORY_DIR, HOME)).toBeUndefined()
  expect(memoryFileOf('/Users/dan/Apps/slate/CLAUDE.md', HOME)).toBeUndefined()
  expect(memoryFileOf('/Users/dan/.claude/projects/-Users-dan-Apps-slate/rule.md', HOME)).toBeUndefined()
})

test('an index write adds a line only when it leaves the index as it was with exactly one line inserted at a line boundary', () => {
  const [first, second] = IDX_TEXT.split('\n')
  expect(indexLineAdded(IDX_TEXT, `${IDX_TEXT}${LINE}\n`)).toBe(LINE)
  expect(indexLineAdded(IDX_TEXT, `${LINE}\n${IDX_TEXT}`)).toBe(LINE)
  expect(indexLineAdded(IDX_TEXT, `${first}\n${LINE}\n${second}\n`)).toBe(LINE)
  // No index yet, or one with no newline after its last line, which the new line then gets.
  expect(indexLineAdded(undefined, `${LINE}\n`)).toBe(LINE)
  expect(indexLineAdded('', LINE)).toBe(LINE)
  expect(indexLineAdded(IDX_TEXT.trimEnd(), `${IDX_TEXT}${LINE}`)).toBe(LINE)
  expect(indexLineAdded(IDX_TEXT.trimEnd(), `${IDX_TEXT}${LINE}\n`)).toBe(LINE)
  const refused = [
    // Two lines, a blank line beside it, or nothing added.
    `${IDX_TEXT}${LINE}\n${LINE}\n`,
    `${IDX_TEXT}\n${LINE}\n`,
    IDX_TEXT,
    `${IDX_TEXT}\n`,
    // An existing line changed or taken out beside it.
    `${first}\n${LINE}\n`,
    `${first} more\n${second}\n${LINE}\n`,
    // Spliced into an existing line, at its start or its end.
    `${LINE}${first}\n${second}\n`,
    `${first}\n${second}${LINE}\n`,
  ]
  for (const next of refused) expect(`${JSON.stringify(next)}: ${indexLineAdded(IDX_TEXT, next)}`).toBe(`${JSON.stringify(next)}: undefined`)
  // Appended onto a last line with no newline, which joins the two.
  expect(indexLineAdded(IDX_TEXT.trimEnd(), `${IDX_TEXT.trimEnd()}${LINE}\n`)).toBeUndefined()
})

test('an index line covers a file only when its one markdown link is to that file by its name', () => {
  expect(linksOnlyTo(LINE, 'rule.md')).toBe(true)
  expect(linksOnlyTo(`- [Rule](./rule.md) ${DASH} x`, 'rule.md')).toBe(true)
  expect(linksOnlyTo(LINE, 'other.md')).toBe(false)
  expect(linksOnlyTo(`${LINE} [see](other.md)`, 'rule.md')).toBe(false)
  expect(linksOnlyTo(`${LINE} [again](rule.md)`, 'rule.md')).toBe(false)
  expect(linksOnlyTo('- rule.md: the rule', 'rule.md')).toBe(false)
  expect(linksOnlyTo('- [Rule](old/rule.md)', 'rule.md')).toBe(false)
})

test('an Edit applied to a file leaves it with its old text replaced once, or nothing when that text is not found exactly once', () => {
  expect(editedFile('a\nb\n', { old_string: 'a', new_string: 'a\nc' })).toBe('a\nc\nb\n')
  expect(editedFile('a\na\n', { old_string: 'a', new_string: 'c' })).toBeUndefined()
  expect(editedFile('a\nb\n', { old_string: 'x', new_string: 'c' })).toBeUndefined()
  expect(editedFile('a\nb\n', { old_string: '', new_string: 'c' })).toBeUndefined()
  expect(editedFile('a\nb\n', { old_string: 'a', new_string: 'c', replace_all: true })).toBeUndefined()
  expect(editedFile(undefined, { old_string: 'a', new_string: 'c' })).toBeUndefined()
})

test('a shell append adds its text only as one echo, printf or cat of quoted text with >> into the index and nothing else', () => {
  const shown = '~/.claude/projects/-Users-dan-Apps-slate/memory/MEMORY.md'
  const appended = (command: string) => shellAppended(command, pipeline(command), commandWrites(command, '/Users/dan/Apps/slate', HOME), IDX)
  expect(appended(`echo '${LINE}' >> ${shown}`)).toBe(`${LINE}\n`)
  expect(appended(`echo "${LINE}" >> "${IDX}"`)).toBe(`${LINE}\n`)
  expect(appended(`printf '%s\\n' '${LINE}' >> ${shown}`)).toBe(`${LINE}\n`)
  expect(appended(`printf '${LINE}\\n' >> ${shown}`)).toBe(`${LINE}\n`)
  expect(appended(`cat >> ${shown} <<'EOF'\n${LINE}\nEOF`)).toBe(`${LINE}\n`)
  expect(appended(`cat <<'EOF' >> ${shown}\n${LINE}\nEOF`)).toBe(`${LINE}\n`)
  expect(appended(`F=${shown}; echo '${LINE}' >> "$F"`)).toBe(`${LINE}\n`)
  const refused = [
    // Replacing the index, or appending somewhere else.
    `echo '${LINE}' > ${shown}`,
    `echo '${LINE}' >> ${MEMORY_DIR}/notes.md`,
    `echo '${LINE}' 2>> ${shown}`,
    // Text the shell or the command may change: a variable, a substitution, an escape, a format.
    `echo "${LINE} $HOME" >> ${shown}`,
    `echo "${LINE} $(whoami)" >> ${shown}`,
    `echo '${LINE}\\nmore' >> ${shown}`,
    `echo -e '${LINE}' >> ${shown}`,
    `printf '${LINE} %s\\n' x >> ${shown}`,
    `printf '%s\\n' '${LINE}' 'more' >> ${shown}`,
    `cat >> ${shown} <<EOF\n${LINE} $HOME\nEOF`,
    // Unquoted text, whose brackets the shell reads as a pattern.
    `echo - [Rule](rule.md) >> ${shown}`,
    // More than one command, a pipe, or a file read in.
    `echo '${LINE}' >> ${shown}; echo x > /tmp/y`,
    `echo '${LINE}' | tee -a ${shown}`,
    `cat notes.md >> ${shown}`,
    `cat >> ${shown} <<<'${LINE}'`,
  ]
  for (const command of refused) expect(`${command}: ${appended(command)}`).toBe(`${command}: undefined`)
})
