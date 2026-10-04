import { describe, expect, test } from 'claude-code/testing'
import { latestRequest, othersEditing, othersInRepo, parseVerdict, watchedGit } from '../hooks/collide.ts'

const rec = (id: string, over: Partial<{ repoRoot: string | null; edits: string[] }> = {}) => ({
  v: 1 as const,
  sessionId: id,
  cwd: '/repo',
  repoRoot: '/repo',
  startedAt: 0,
  lastSeen: 0,
  closedAt: null,
  transcriptPath: null,
  edits: [],
  extra: {},
  ...over,
})

describe('which git commands are checkout wide (the spec list)', () => {
  const watched: [string, { sub: string; args: string[] }, string][] = [
    ['checkout', { sub: 'checkout', args: ['main'] }, 'git checkout main'],
    ['switch', { sub: 'switch', args: ['-c', 'x'] }, 'git switch -c x'],
    ['branch -D', { sub: 'branch', args: ['-D', 'feat'] }, 'git branch -D feat'],
    ['branch --delete --force', { sub: 'branch', args: ['--delete', '--force', 'feat'] }, 'git branch --delete --force feat'],
    ['reset --hard', { sub: 'reset', args: ['--hard', 'origin/main'] }, 'git reset --hard origin/main'],
    ['stash pop', { sub: 'stash', args: ['pop'] }, 'git stash pop'],
    ['add -A', { sub: 'add', args: ['-A'] }, 'git add -A'],
    ['add .', { sub: 'add', args: ['.'] }, 'git add .'],
    ['add --all', { sub: 'add', args: ['--all'] }, 'git add --all'],
  ]
  for (const [name, g, label] of watched) test(`${name} is watched`, () => expect(watchedGit(g)).toBe(label))

  const fine: [string, { sub: string | undefined; args: string[] }][] = [
    ['status', { sub: 'status', args: [] }],
    ['add of named paths', { sub: 'add', args: ['src/a.ts'] }],
    ['branch -d of a merged branch', { sub: 'branch', args: ['-d', 'old'] }],
    ['reset of the index only', { sub: 'reset', args: ['HEAD', 'a.ts'] }],
    ['stash push', { sub: 'stash', args: ['push', '-m', 'x'] }],
    ['a checkout of one file back', { sub: 'checkout', args: ['HEAD', '--', 'a.ts'] }],
  ]
  for (const [name, g] of fine) test(`${name} is not watched`, () => expect(watchedGit(g)).toBeUndefined())
})

describe('who else is there', () => {
  const open = [rec('me', { edits: ['/repo/a.ts'] }), rec('them', { edits: ['/repo/a.ts', '/repo/b.ts'] }), rec('elsewhere', { repoRoot: '/other', edits: ['/other/a.ts'] })]
  test('other open sessions that edited the file, never this one', () => {
    expect(othersEditing(open, 'me', '/repo/a.ts').map(r => r.sessionId)).toEqual(['them'])
    expect(othersEditing(open, 'me', '/repo/c.ts')).toEqual([])
  })
  test('a subagent of this same session is this session, so never a collision', () => {
    expect(othersEditing([rec('me', { edits: ['/repo/a.ts'] })], 'me', '/repo/a.ts')).toEqual([])
  })
  test('a session whose repository could not be read still counts when its folder is inside the checkout (lessons check)', () => {
    const unknown = [rec('me'), { ...rec('lost', { repoRoot: null }), cwd: '/repo/app' }, { ...rec('away', { repoRoot: null }), cwd: '/repository-else' }]
    expect(othersInRepo(unknown, 'me', '/repo').map(r => r.sessionId)).toEqual(['lost'])
  })
  test('other open sessions in the same checkout', () => {
    expect(othersInRepo(open, 'me', '/repo').map(r => r.sessionId)).toEqual(['them'])
    expect(othersInRepo(open, 'me', null)).toEqual([])
  })
})

describe('the verdict', () => {
  test('each verdict is read with its reason', () => {
    expect(parseVerdict('{"verdict":"Proceed","reason":"They only read it."}')).toEqual({ verdict: 'Proceed', reason: 'They only read it.' })
    expect(parseVerdict('Here: {"verdict": "Worktree", "reason": "Both change the header."}')).toEqual({ verdict: 'Worktree', reason: 'Both change the header.' })
    expect(parseVerdict('{"verdict":"Stop","reason":"They are mid rebase."}')?.verdict).toBe('Stop')
  })
  test('anything else is no verdict, which the guard treats as Stop (L42)', () => {
    expect(parseVerdict('Proceed, it is fine')).toBeUndefined()
    expect(parseVerdict('{"verdict":"Maybe","reason":"x"}')).toBeUndefined()
    expect(parseVerdict('{"verdict":"Proceed"}')).toBeUndefined()
    expect(parseVerdict('')).toBeUndefined()
  })
})

describe("the other session's latest request, from its transcript", () => {
  const line = (o: unknown) => JSON.stringify(o)
  test('the last thing typed, past tool results and replies', () => {
    const tail = [
      line({ type: 'user', message: { role: 'user', content: 'first ask' } }),
      line({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'ok' }] } }),
      line({ type: 'user', message: { role: 'user', content: [{ type: 'text', text: 'tidy the invoice table' }] } }),
      line({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't', content: 'done' }] } }),
    ].join('\n')
    expect(latestRequest(tail)).toBe('tidy the invoice table')
  })
  test('a tail that starts mid line still reads', () => {
    expect(latestRequest('ial line\n' + line({ type: 'user', message: { role: 'user', content: 'x' } }))).toBe('x')
  })
  test('nothing typed reads as nothing', () => {
    expect(latestRequest('')).toBeUndefined()
  })
})
