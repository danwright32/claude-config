import { expect, test } from 'claude-code/testing'
import { cleanName, hasExchange, namePrompt, renameOutcome, repoLabel, withRepo } from '../hooks/name.ts'
import { repoName } from './mod-kit/hooks/repo.ts'
import { REPO_FIXTURES } from './mod-kit/tests/repo-fixtures.ts'

// The two long dashes, built from their code points so this file holds neither character.
const EM = String.fromCharCode(0x2014)
const EN = String.fromCharCode(0x2013)
const OPEN_Q = String.fromCharCode(0x201c)
const CLOSE_Q = String.fromCharCode(0x201d)
// The curly apostrophe in the work MacBook's checkout paths (Documents - Dan's MacBook Pro).
const APOS = String.fromCharCode(0x2019)

test('a plain reply is kept as it is', async () => {
  expect(cleanName('Fix the invoice table layout')).toEqual({ name: 'Fix the invoice table layout' })
})

test('quotes, a label and a closing full stop are stripped', async () => {
  expect(cleanName('"Fix the invoice table layout."')).toEqual({ name: 'Fix the invoice table layout' })
  expect(cleanName(`Name: ${OPEN_Q}Auto session name mod${CLOSE_Q}`)).toEqual({ name: 'Auto session name mod' })
  expect(cleanName("'Rebuild the sync lock'")).toEqual({ name: 'Rebuild the sync lock' })
  expect(cleanName('`Collision guard tests`')).toEqual({ name: 'Collision guard tests' })
  expect(cleanName('**Collision guard tests**')).toEqual({ name: 'Collision guard tests' })
})

test('only the first line of a reply is used', async () => {
  expect(cleanName('\n  Session registry retention\nThis name says what the work is.')).toEqual({ name: 'Session registry retention' })
})

test('dashes used as punctuation become spaces, while a hyphen inside a word stays', async () => {
  expect(cleanName(`Status bar ${EM} band layout`)).toEqual({ name: 'Status bar band layout' })
  expect(cleanName(`Status bar${EM}band layout`)).toEqual({ name: 'Status bar band layout' })
  expect(cleanName(`Status bar ${EN} band layout`)).toEqual({ name: 'Status bar band layout' })
  expect(cleanName('Status bar - band layout')).toEqual({ name: 'Status bar band layout' })
  expect(cleanName('Fix two-way sync deletes')).toEqual({ name: 'Fix two-way sync deletes' })
})

test('an empty reply is refused, also one that is only quotes and punctuation', async () => {
  expect(cleanName('')).toEqual({ refused: 'empty' })
  expect(cleanName('   \n  ')).toEqual({ refused: 'empty' })
  expect(cleanName('""')).toEqual({ refused: 'empty' })
  expect(cleanName(EM)).toEqual({ refused: 'empty' })
})

test('a reply too long to be a name is refused, by words or by characters', async () => {
  expect(cleanName('This is a very long name that goes on well past six words')).toEqual({ refused: 'too-long' })
  expect(cleanName('Supercalifragilisticexpialidocious antidisestablishmentarianism reconfiguration')).toEqual({ refused: 'too-long' })
  // Eight words is the most kept: a little over the six asked for still names the work.
  expect(cleanName('One two three four five six seven eight')).toEqual({ name: 'One two three four five six seven eight' })
  expect(cleanName('One two three four five six seven eight nine')).toEqual({ refused: 'too-long' })
})

test('the prompt carries the opening request and the recent messages, each cut short', async () => {
  const long = 'x'.repeat(5000)
  const p = namePrompt([
    { role: 'user', text: 'Build the auto session name mod', toolUses: [] },
    { role: 'assistant', text: 'Reading the issue first.', toolUses: [] },
    { role: 'user', text: long, toolUses: [] },
  ])
  expect(p).toContain('Build the auto session name mod')
  expect(p).toContain('Reading the issue first.')
  expect(p).toContain('3 to 6 words')
  expect(p.length).toBeLessThan(6000)
})

test('the opening request is the first message the person wrote, not a tool result', async () => {
  const p = namePrompt([
    { role: 'user', text: '', toolUses: [] },
    { role: 'user', text: 'Rename the status bar items', toolUses: [] },
    { role: 'assistant', text: 'ok', toolUses: [] },
  ])
  expect(p).toContain('Opening request:\nRename the status bar items')
})

test('an exchange needs a request from the person and a reply', async () => {
  expect(hasExchange([])).toBe(false)
  expect(hasExchange([{ role: 'user', text: 'hello', toolUses: [] }])).toBe(false)
  expect(hasExchange([{ role: 'user', text: '', toolUses: [] }, { role: 'assistant', text: 'hi', toolUses: [] }])).toBe(false)
  expect(hasExchange([{ role: 'user', text: 'hello', toolUses: [] }, { role: 'assistant', text: 'hi', toolUses: [] }])).toBe(true)
})

test('the rename command answer is read by the shapes the built-in /rename prints', async () => {
  // Copied from the 2.1.289 build's /rename (its success and refusal messages).
  expect(renameOutcome('Session renamed to: Fix the invoice table')).toBe('set')
  expect(renameOutcome('Session renamed to: Fix the invoice table 2 ("Fix the invoice table" is held by another live session on this machine)')).toBe('set')
  expect(renameOutcome('Session is named: Other name (a newer rename landed first)')).toBe('set')
  expect(renameOutcome('Cannot rename: This session is a teammate. Teammate names are set by the team leader.')).toBe('refused')
  expect(renameOutcome('That name is empty once invisible characters are removed. Usage: /rename <name>')).toBe('refused')
  // Nothing printed as text, or anything else: it may or may not have taken, so it is checked later.
  expect(renameOutcome(undefined)).toBe('unknown')
  expect(renameOutcome('')).toBe('unknown')
  expect(renameOutcome('something new')).toBe('unknown')
})

// The session's repository, as $.session.repo() answers it (#945), named as $.modkit.repo names it:
// its byte for byte copy (#951).
const at = (root: string, remote: string | null = null) => repoName({ root, remote })

test('the repository is named by its origin, lower case, in any spelling of the remote', async () => {
  expect(repoLabel(at('/Users/x/Apps/claude-config', 'git@github.com:danwright32/claude-config.git'))).toBe('claude-config')
  expect(repoLabel(at('/Users/x/Apps/Overture', 'https://github.com/danwright32/Overture'))).toBe('overture')
  expect(repoLabel(at('/Users/x/Apps/Overture', 'https://github.com/danwright32/Overture.git/'))).toBe('overture')
  expect(repoLabel(at('/Users/x/Apps/local', 'ssh://git@gitlab.example.com:2222/team/Sub/Thing.git'))).toBe('thing')
  // The origin names the repository even where the checkout folder is called something else.
  expect(repoLabel(at('/Users/x/Apps/old-folder-name', 'git@github.com:danwright32/PostRoll.git'))).toBe('postroll')
})

// The name is mod-kit's reading of the repository (#951), on the table every mod's reading is
// pinned on, as this mod labels it: lower case.
test("the label is mod-kit's name for the repository, lower case, on every shared case (#951)", async () => {
  const got = REPO_FIXTURES.map(f => ({ why: f.why, label: repoLabel(at(f.root, f.remote)) }))
  expect(got).toEqual(REPO_FIXTURES.map(f => ({ why: f.why, label: f.name?.toLowerCase() ?? null })))
})

test('with no origin the checkout folder names it, and with no repository there is no name', async () => {
  expect(repoLabel(at('/Users/x/Non-icloudDocuments/Apps/NurseDex'))).toBe('nursedex')
  expect(repoLabel(at('/Users/x/Apps/NurseDex', ''))).toBe('nursedex')
  expect(repoLabel(null)).toBe(null)
})

test('a worktree under .claude/worktrees names its parent repository, never its own folder', async () => {
  expect(repoLabel(at('/Users/x/Apps/claude-config/.claude/worktrees/agent-ac031537'))).toBe('claude-config')
  expect(repoLabel(at('/Users/x/Apps/claude-config/.claude/worktrees/issue-945/'))).toBe('claude-config')
})

test('a path with spaces and a curly apostrophe is read whole', async () => {
  const docs = `/Users/x/Documents/Documents - Dan${APOS}s MacBook Pro`
  expect(repoLabel(at(`${docs}/Bidspoke`))).toBe('bidspoke')
  expect(repoLabel(at(`${docs}/Bidspoke/.claude/worktrees/agent-1`))).toBe('bidspoke')
  expect(repoLabel(at(`${docs}/Bidspoke`, 'git@github.com:danwright32/bidspoke.git'))).toBe('bidspoke')
  // A folder whose own name has spaces and brackets: the brackets would close the prefix early, so
  // they go; the rest is kept as it is, in lower case.
  expect(repoLabel(at(`${docs}/Project Enrollment Tracker (PET)`))).toBe('project enrollment tracker pet')
  expect(repoLabel(at(`${docs}/Dan${APOS}s Notes`))).toBe(`dan${APOS}s notes`)
})

test('a name is prefixed with its repository in brackets', async () => {
  expect(withRepo('claude-config', 'Sleep mode phase 3')).toBe('(claude-config) Sleep mode phase 3')
  expect(withRepo('overture', 'Fix export')).toBe('(overture) Fix export')
})

test('a name that already carries the right prefix is never doubled', async () => {
  expect(withRepo('overture', '(overture) Fix export')).toBe('(overture) Fix export')
  expect(withRepo('overture', '(overture) (overture) Fix export')).toBe('(overture) Fix export')
  expect(withRepo('overture', '(overture)')).toBe('(overture)')
  // In any case: the label is lower case, and Haiku may capitalise it (#948 review).
  expect(withRepo('overture', '(Overture) Fix export')).toBe('(overture) Fix export')
  expect(withRepo('claude-config', '(Claude-Config) (claude-config) Fix export')).toBe('(claude-config) Fix export')
})

// A bracket at the start of a name is taken off only when it is this repository's own label. No
// shape tells another repository's name from the name's own bracket ((v2), (q3), (wip), (overture)
// all look alike), so none is guessed at: losing a word of the name is worse than a second
// bracket, which /rename can take off (#948 review). A stale prefix never comes from this mod's
// own name: it keeps the name unprefixed and reads the repository at naming time.
test("any other bracket at the start is the name's own and is kept", async () => {
  expect(withRepo('overture', '(WIP) Fix export')).toBe('(overture) (WIP) Fix export')
  expect(withRepo('overture', '(wip) Fix export')).toBe('(overture) (wip) Fix export')
  expect(withRepo('overture', '(draft) Fix export')).toBe('(overture) (draft) Fix export')
  expect(withRepo('overture', '(v2) Fix export')).toBe('(overture) (v2) Fix export')
  expect(withRepo('overture', '(q3) planning')).toBe('(overture) (q3) planning')
  expect(withRepo('overture', '(2024) tax review')).toBe('(overture) (2024) tax review')
  expect(withRepo('overture', '(two parts) Fix export')).toBe('(overture) (two parts) Fix export')
  expect(withRepo('overture', '(claude-config) Fix export')).toBe('(overture) (claude-config) Fix export')
})

test('a reply is cleaned without touching a bracket at its start; the prefix is settled at naming', async () => {
  expect(cleanName('(claude-config) Fix export')).toEqual({ name: '(claude-config) Fix export' })
  expect(cleanName('"(v2) Fix export."')).toEqual({ name: '(v2) Fix export' })
  expect(cleanName('(WIP) Fix export')).toEqual({ name: '(WIP) Fix export' })
})

test('with no repository the name goes as it is', async () => {
  expect(withRepo(null, 'Fix export')).toBe('Fix export')
  expect(withRepo(null, '(v2) Fix export')).toBe('(v2) Fix export')
})

test('the prompt asks for no bracket at the start, since the repository goes there', async () => {
  const p = namePrompt([{ role: 'user', text: 'Fix the export', toolUses: [] }])
  expect(p).toContain('Do not start the name with anything in brackets')
})

test('the prefix counts toward the 60 character cap, and the name is what gets shortened', async () => {
  const name = 'Rebuild synchronisation locking for shared clone folders'
  expect(cleanName(name)).toEqual({ name })
  const out = withRepo('claude-config', name)
  expect(out.length).toBeLessThanOrEqual(60)
  // Cut at a word, never inside one.
  expect(out).toBe('(claude-config) Rebuild synchronisation locking for shared')
  // A name that fits is left whole.
  expect(withRepo('claude-config', 'Rebuild the sync lock')).toBe('(claude-config) Rebuild the sync lock')
})

test('a repository name too long to leave room is cut, so the name always keeps its words', async () => {
  const label = repoLabel(at('/x', `git@github.com:o/${'very-long-repository-name-'.repeat(4)}end.git`)) as string
  expect(label.length).toBeLessThanOrEqual(30)
  const out = withRepo(label, 'Fix the export dialog')
  expect(out).toBe(`(${label}) Fix the export dialog`)
  expect(out.length).toBeLessThanOrEqual(60)
  // And the cut label is still read as this repository's prefix, so it is not doubled.
  expect(withRepo(label, out)).toBe(out)
})
