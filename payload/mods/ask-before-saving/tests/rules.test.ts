import { expect, test } from 'claude-code/testing'
import { APPROVAL_MS, addedText, callShown, cannotCheck, display, lastingFiles, lastingMemory, madePermanent, mentioned, questionOf, resolvePath, saveKey } from '../hooks/rules.ts'

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

// The look is mod-kit's ($.modkit.question, one look for every question in the band, #705); this
// is what ask before saving hands it: the rule's exact text and its file between grey rules, then
// the three answers with what each does under it.
test('the question: the chip and question, the rule and its file set off by grey rules, then the three answers', () => {
  const q = questionOf({ id: 't1', text: 'Ask before saving a standing rule.\n- and this', files: ['~/.claude/CLAUDE.md'] })
  expect(q.mod).toBe('ask-before-saving')
  expect(q.chip).toBe('Standing rule')
  expect(q.question).toBe('Save this as a standing rule?')
  expect(q.body).toEqual([
    { divider: true },
    [{ text: 'Ask before saving a standing rule.', wrap: true }],
    [{ text: '- and this', wrap: true }],
    [{ text: '~/.claude/CLAUDE.md', dim: true }],
    { divider: true },
  ])
  expect(q.options.map(o => [o.label, o.description])).toEqual([
    ['For good', 'Saved to ~/.claude/CLAUDE.md'],
    ['Just this session', 'Kept until this session ends; nothing is written'],
    ['Not at all', 'Nothing is saved'],
  ])
})

// L243: a press must answer the save it was drawn for, so a second press after the first was
// answered cannot land on the next save in line. The row and its buttons carry the save's identity.
test('each save asks under its own id, and its buttons carry that id, so a press answers only the save it was drawn for', () => {
  const a = questionOf({ id: 'toolu_a', text: 'x', files: ['CLAUDE.md'] })
  const b = questionOf({ id: 'toolu_b', text: 'y', files: ['AGENTS.md'] })
  expect(a.id).not.toBe(b.id)
  expect(a.options.map(o => o.button)).toEqual(['for-good:toolu_a', 'this-session:toolu_a', 'not-at-all:toolu_a'])
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
