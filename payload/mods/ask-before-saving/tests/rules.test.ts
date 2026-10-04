import { expect, test } from 'claude-code/testing'
import { addedText, bashTargets, display, lastingMemory, madePermanent, questionRow, resolvePath, wrap } from '../hooks/rules.ts'

// What counts as lasting memory, when Dan's own words already made a rule permanent, and what the
// question shows (claude-config#618, docs/mods-design.md "Ask before saving").
const HOME = '/Users/dan'

test('every lasting memory file counts, and nothing beside it does', () => {
  const yes = [
    '/Users/dan/.claude/projects/-Users-dan-Apps-slate/memory/no-merge-quizzes.md',
    '/Users/dan/.claude/projects/-Users-dan-Apps-slate/memory/MEMORY.md',
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
    '/Users/dan/Apps/slate/src/memory/cache.ts',
    '/Users/dan/Apps/slate/NOTCLAUDE.md',
  ]
  for (const p of yes) expect(`${p} ${lastingMemory(p, HOME)}`).toBe(`${p} true`)
  for (const p of no) expect(`${p} ${lastingMemory(p, HOME)}`).toBe(`${p} false`)
})

test('a path is read the way the shell and the tools read it: home, relative and dot segments', () => {
  expect(resolvePath('~/.claude/CLAUDE.md', '/Users/dan/Apps/slate', HOME)).toBe('/Users/dan/.claude/CLAUDE.md')
  expect(resolvePath('CLAUDE.md', '/Users/dan/Apps/slate', HOME)).toBe('/Users/dan/Apps/slate/CLAUDE.md')
  expect(resolvePath('./docs/../AGENTS.md', '/Users/dan/Apps/slate', HOME)).toBe('/Users/dan/Apps/slate/AGENTS.md')
  expect(resolvePath('$HOME/.claude/LESSONS.md', '/x', HOME)).toBe('/Users/dan/.claude/LESSONS.md')
  expect(display('/Users/dan/.claude/CLAUDE.md', HOME)).toBe('~/.claude/CLAUDE.md')
  expect(display('/opt/x/CLAUDE.md', HOME)).toBe('/opt/x/CLAUDE.md')
})

test("Dan's words make a rule permanent only with the phrases the spec names, as whole words", () => {
  for (const s of ['From now on, ask before merging', 'always use pnpm here', 'never push on Fridays', 'remember that the deploy is manual'])
    expect(`${s}: ${madePermanent(s)}`).toBe(`${s}: true`)
  for (const s of ['just for now, skip the tests', 'no, do not note anything', 'it was remembered wrongly', 'alwaysOn flag', undefined])
    expect(`${s}: ${madePermanent(s)}`).toBe(`${s}: false`)
})

test('a Bash write is found by every route that names its target: redirects, tee, cp, mv, sed -i', () => {
  const t = (cmds: string[][]) => bashTargets(cmds)
  expect(t([['cat', '>>', 'CLAUDE.md', '<<EOF']])).toEqual(['CLAUDE.md'])
  expect(t([['cat', '>~/.claude/CLAUDE.md']])).toEqual(['~/.claude/CLAUDE.md'])
  expect(t([['echo', 'x', '1>>', 'a.md'], ['printf', 'y', '&>', 'b.md'], ['echo', 'z', '>|', 'c.md']])).toEqual(['a.md', 'b.md', 'c.md'])
  expect(t([['echo', 'x'], ['tee', '-a', 'MEMORY.md', 'other.md']])).toEqual(['MEMORY.md', 'other.md'])
  expect(t([['cp', '-f', '/tmp/new.md', 'AGENTS.md'], ['mv', 'a', 'b', 'dir']])).toEqual(['AGENTS.md', 'dir'])
  expect(t([['sed', '-i', '', 's/a/b/', 'CLAUDE.md'], ['perl', '-pi', '-e', 's/a/b/', 'LESSONS.md']])).toEqual(['CLAUDE.md', 'LESSONS.md'])
  // Reading is not writing, and a redirect into /dev/null or a descriptor writes no file.
  expect(t([['cat', 'CLAUDE.md'], ['grep', 'x', 'CLAUDE.md', '2>/dev/null'], ['ls', '2>&1'], ['sed', 's/a/b/', 'CLAUDE.md']])).toEqual([])
})

test('the text shown is what would be saved: the new lines of a rewrite, the whole of a new file', () => {
  expect(addedText('# Memory\n- a\n- b\n', undefined)).toBe('# Memory\n- a\n- b')
  expect(addedText('# Memory\n- a\n- new rule\n', '# Memory\n- a\n')).toBe('- new rule')
  // A rewrite that adds nothing new shows the whole text rather than nothing.
  expect(addedText('# Memory\n', '# Memory\n- a\n')).toBe('# Memory')
})

test('long text is wrapped on word boundaries, so the band never cuts a rule off at its edge', () => {
  expect(wrap('one two three four', 9)).toEqual(['one two', 'three', 'four'])
  expect(wrap('a\n\nb', 9)).toEqual(['a', '', 'b'])
  expect(wrap('abcdefghijkl', 5)).toEqual(['abcde', 'fghij', 'kl'])
})

test('the question: chip and question on one amber line, the rule and its file set off by grey rules, then the three answers', () => {
  const row = questionRow({ id: 't1', text: 'Ask before saving a standing rule.', files: ['~/.claude/CLAUDE.md'] })
  expect(row.mod).toBe('ask-before-saving')
  expect(row.slot).toBe('question')
  const lines = row.lines
  const texts = (l: unknown) => (Array.isArray(l) ? l.map(p => (p as { text?: string; label?: string }).text ?? `[${(p as { label?: string }).label}]`).join('') : '---')
  expect(lines.map(texts)).toEqual([
    'Standing rule  Save this as a standing rule?',
    '---',
    'Ask before saving a standing rule.',
    '~/.claude/CLAUDE.md',
    '---',
    '[For good]',
    'Saved to ~/.claude/CLAUDE.md',
    '[Just this session]',
    'Kept until this session ends; nothing is written',
    '[Not at all]',
    'Nothing is saved',
  ])
  // One amber line per surface: the lead line, and nothing else.
  const amber = lines.filter(l => Array.isArray(l) && l.some(p => (p as { color?: string }).color === 'warning'))
  expect(amber.length).toBe(1)
  const buttons = lines.flatMap(l => (Array.isArray(l) ? l : [])).filter(p => 'button' in p) as { button: string; hotkey?: string }[]
  expect(buttons.map(b => `${b.button}:${b.hotkey}`)).toEqual(['for-good:1', 'this-session:2', 'not-at-all:3'])
})
