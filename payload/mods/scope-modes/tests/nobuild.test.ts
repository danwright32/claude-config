import { describe, expect, test } from 'claude-code/testing'
import { inScratch, noBuildRefusal, type Cmd } from '../hooks/nobuild.ts'

// Commands as mod-kit's reader hands them over: each simple command's words with quotes removed
// (heredoc bodies dropped, `&` a separator, so `2>&1` arrives as `2>` then a command `1`), and git
// read by mod-kit's git reader. Split here by hand, the way that reader splits them.
const gitOf = (words: string[]) => {
  if ((words[0] ?? '').split('/').pop() !== 'git') return undefined
  const rest = words.slice(1)
  while (rest[0] === '-C') rest.splice(0, 2)
  return { sub: rest[0], args: rest.slice(1) }
}
const cmds = (...lines: string[][]): Cmd[] => lines.map(words => ({ words, git: gitOf(words) }))
const SCRATCH = '/private/tmp/claude-501/-Users-x-proj/0a1b/scratchpad'
const bash = (...lines: string[][]) => noBuildRefusal({ tool: 'Bash', input: {}, commands: cmds(...lines) })
const tool = (name: string, input: Record<string, unknown>) => noBuildRefusal({ tool: name, input, commands: [] })

describe('inScratch', () => {
  test('the session scratchpad and below, never a path that climbs out of it', () => {
    expect(inScratch(`${SCRATCH}/notes.md`)).toBe(true)
    expect(inScratch(SCRATCH)).toBe(true)
    expect(inScratch(`/tmp/claude-501/p/s/scratchpad/a`)).toBe(true)
    expect(inScratch(`${SCRATCH}/../../../../Users/x/app.ts`)).toBe(false)
    expect(inScratch('/Users/x/proj/scratchpad/a.md')).toBe(false)
    expect(inScratch('notes.md')).toBe(false)
  })
})

describe('allowed in no build', () => {
  test('reading, research, tests and checks', () => {
    expect(bash(['cat', 'README.md'], ['rg', '-n', 'foo', 'src'])).toBeUndefined()
    expect(bash(['npm', 'test'], ['tail', '-20'])).toBeUndefined()
    expect(bash(['bash', 'tests/test-mods.sh', '2>'], ['1'])).toBeUndefined()
    expect(bash(['git', 'status'], ['git', 'log', '--oneline', '-5'], ['git', 'diff'], ['git', 'branch'], ['git', 'branch', '--merged', 'main'])).toBeUndefined()
    expect(tool('Read', { file_path: '/Users/x/app.ts' })).toBeUndefined()
    expect(tool('WebFetch', { url: 'https://example.com' })).toBeUndefined()
  })
  test('read only queries', () => {
    expect(bash(['psql', '$DATABASE_URL', '-c', 'SELECT count(*) FROM shows'])).toBeUndefined()
    expect(tool('mcp__claude_ai_Supabase__execute_sql', { query: 'select id from shows limit 5' })).toBeUndefined()
  })
  test('scratchpad notes, by tool and by shell', () => {
    expect(tool('Write', { file_path: `${SCRATCH}/notes.md`, content: 'x' })).toBeUndefined()
    expect(bash(['echo', 'hi', '>', `${SCRATCH}/n.txt`])).toBeUndefined()
    expect(bash(['cat', `>${SCRATCH}/n.txt`, '<<EOF'])).toBeUndefined()
    expect(bash(['ls', '>', '/dev/null'])).toBeUndefined()
  })
  test('all GitHub issue, milestone and label work', () => {
    expect(bash(['gh', 'issue', 'create', '--title', 'x', '--body', 'y'])).toBeUndefined()
    expect(bash(['gh', 'issue', 'edit', '616', '--add-label', 'p1'])).toBeUndefined()
    expect(bash(['gh', 'label', 'create', 'lesson-sweep'])).toBeUndefined()
    expect(bash(['gh', 'api', '-X', 'POST', 'repos/o/r/milestones', '-f', 'title=Saved views'])).toBeUndefined()
    expect(bash(['gh', 'api', 'repos/o/r/pulls/3'])).toBeUndefined()
    expect(bash(['gh', 'pr', 'view', '3'], ['gh', 'pr', 'checks'])).toBeUndefined()
  })
})

describe('refused in no build', () => {
  const what = (r: { what: string } | undefined) => r?.what
  test('code edits outside the scratchpad', () => {
    expect(what(tool('Edit', { file_path: '/Users/x/proj/app.ts' }))).toBe('edit app.ts')
    expect(what(tool('Write', { file_path: '/Users/x/proj/new.ts' }))).toBe('edit new.ts')
    expect(what(tool('NotebookEdit', { notebook_path: '/Users/x/a.ipynb' }))).toBe('edit a.ipynb')
  })
  test('commits, branches and the other git writes', () => {
    expect(what(bash(['git', 'commit', '-m', 'x']))).toBe('run git commit')
    expect(what(bash(['git', 'checkout', '-b', 'feature']))).toBe('run git checkout')
    expect(what(bash(['git', 'switch', '-c', 'feature']))).toBe('run git switch')
    expect(what(bash(['git', 'branch', 'feature']))).toBe('run git branch')
    expect(what(bash(['git', 'branch', '-D', 'old']))).toBe('run git branch')
    expect(what(bash(['git', 'push']))).toBe('run git push')
    expect(what(bash(['git', 'add', 'a.ts']))).toBe('run git add')
    expect(what(bash(['git', 'worktree', 'add', '../w']))).toBe('run git worktree')
    expect(bash(['git', 'worktree', 'list'])).toBeUndefined()
    expect(bash(['git', 'stash', 'list'])).toBeUndefined()
  })
  test('PRs', () => {
    expect(what(bash(['gh', 'pr', 'create', '--fill']))).toBe('run gh pr create')
    expect(what(bash(['gh', 'pr', 'merge', '3', '--squash']))).toBe('run gh pr merge')
    expect(what(bash(['gh', 'api', '-X', 'PUT', 'repos/o/r/pulls/3/merge']))).toBe('call the GitHub API to change repos/o/r/pulls/3/merge')
    expect(what(bash(['gh', 'issue', 'develop', '616']))).toBe('run gh issue develop')
  })
  test('deploys', () => {
    expect(what(bash(['npx', 'wrangler', 'deploy']))).toBe('deploy with wrangler')
    expect(what(bash(['vercel', '--prod']))).toBe('deploy with vercel')
    expect(what(bash(['supabase', 'db', 'push']))).toBe('deploy with supabase')
    expect(what(bash(['npm', 'run', 'deploy:prod']))).toBe('run npm run deploy:prod')
    expect(what(bash(['make', 'deploy']))).toBe('run make deploy')
  })
  test('data changing SQL, and SQL that cannot be read', () => {
    expect(what(bash(['psql', '$DB', '-c', "UPDATE shows SET name = 'x'"]))).toBe('change data with SQL')
    expect(what(bash(['psql', '$DB', '-f', 'fix.sql']))).toBe('run SQL that could not be read')
    // A heredoc body never reaches the reader, so psql fed one cannot be judged.
    expect(what(bash(['psql', '$DB', '<<SQL']))).toBe('run SQL that could not be read')
    expect(what(bash(['sqlite3', 'app.db', 'DELETE FROM t']))).toBe('change data with SQL')
    expect(what(tool('mcp__claude_ai_Supabase__execute_sql', { query: 'delete from shows' }))).toBe('change data with SQL')
    expect(what(tool('mcp__claude_ai_Supabase__apply_migration', { name: 'x', query: 'create table t()' }))).toBe('apply_migration')
    expect(what(tool('Skill', { skill: 'db-apply' }))).toBe('run the db-apply skill')
  })
  test('the routes around it: redirects, heredocs, sed -i, tee, cp, mv, rm and inline scripts', () => {
    expect(what(bash(['echo', 'x', '>', 'src/app.ts']))).toBe('write to app.ts')
    expect(what(bash(['echo', 'x', '>>/Users/x/app.ts']))).toBe('write to app.ts')
    expect(what(bash(['cat', '>', '/Users/x/app.ts', '<<EOF']))).toBe('write to app.ts')
    // `cmd &> file` reaches the reader as two commands, the second led by the redirect.
    expect(what(bash(['npm', 'test'], ['>', '/Users/x/out.log']))).toBe('write to out.log')
    expect(what(bash(['sed', '-i', '', 's/a/b/', 'app.ts']))).toBe('edit app.ts')
    expect(what(bash(['sed', '-i.bak', '-e', 's/a/b/', '/Users/x/app.ts']))).toBe('edit app.ts')
    expect(bash(['sed', '-n', 's/a/b/p', 'app.ts'])).toBeUndefined()
    expect(what(bash(['perl', '-pi', '-e', 's/a/b/', 'app.ts']))).toBe('edit app.ts')
    expect(what(bash(['tee', 'app.ts']))).toBe('write to app.ts')
    expect(bash(['tee', `${SCRATCH}/log.txt`])).toBeUndefined()
    expect(what(bash(['cp', `${SCRATCH}/a.ts`, '/Users/x/app.ts']))).toBe('write to app.ts')
    expect(bash(['cp', '/Users/x/app.ts', `${SCRATCH}/a.ts`])).toBeUndefined()
    expect(what(bash(['mv', '/Users/x/app.ts', `${SCRATCH}/a.ts`]))).toBe('write to app.ts')
    expect(what(bash(['rm', '-rf', 'dist']))).toBe('write to dist')
    expect(what(bash(['python3', '-c', "open('app.ts','w').write('x')"]))).toBe('write files from python3')
    expect(what(bash(['node', '-e', "require('fs').writeFileSync('a', 'b')"]))).toBe('write files from node')
  })
  test('a new worktree by tool', () => {
    expect(what(tool('EnterWorktree', { name: 'x' }))).toBe('enter a new worktree')
  })
})
