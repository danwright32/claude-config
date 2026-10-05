import { expect, test } from 'claude-code/testing'
import { addedText, display, lastingFiles, lastingMemory, madePermanent, mentioned, questionOf, resolvePath } from '../hooks/rules.ts'

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
  )
  expect(files).toEqual(['~/Apps/slate/CLAUDE.md', '$DIR/AGENTS.md', '~/.claude/projects/p/memory/note.md', '/tmp/repo/CLAUDE.md', '/tmp/$D/AGENTS.md'])
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
