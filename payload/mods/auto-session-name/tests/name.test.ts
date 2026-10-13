import { expect, test } from 'claude-code/testing'
import type { SessionMessage } from 'claude-code'
import { cleanName, type Dans, describesImage, hasExchange as hasExchangeFor, isDans, namePrompt as namePromptFor, NO_DANS, renameOutcome, repoLabel, withDans, withRepo } from '../hooks/name.ts'
import { repoName } from './mod-kit/hooks/repo.ts'
import { REPO_FIXTURES } from './mod-kit/tests/repo-fixtures.ts'

// The two long dashes, built from their code points so this file holds neither character.
const EM = String.fromCharCode(0x2014)
const EN = String.fromCharCode(0x2013)
const OPEN_Q = String.fromCharCode(0x201c)
const CLOSE_Q = String.fromCharCode(0x201d)
// The curly apostrophe in the work MacBook's checkout paths (Documents - Dan's MacBook Pro).
const APOS = String.fromCharCode(0x2019)

// What Dan sent, as the prompt.submit hook records it (#1123): in these tests every user message with
// text is his, typed at the terminal, as the transcripts these shapes were measured from had it. A
// tool result has no text and never passes through prompt.submit.
const typed = (messages: readonly SessionMessage[]): Dans =>
  messages.filter(m => m.role === 'user' && m.text.trim()).reduce((d, m) => withDans(d, m.text, false), NO_DANS)
const hasExchange = (messages: readonly SessionMessage[]) => hasExchangeFor(messages, typed(messages))
const namePrompt = (messages: readonly SessionMessage[]) => namePromptFor(messages, typed(messages))

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

// An image sent with no words, as $.session.messages() gives it (#1067). Measured on 2026-10-10
// from this Mac's transcripts: Claude Code stores a pasted image as a user message whose content
// is a text block holding only its placeholder, then the image block, as
// [{ type: 'text', text: '[Image #1]' }, { type: 'image', source: { type: 'base64', media_type:
// 'image/png', data } }], and several images share one text block, '[Image #1] [Image #2]'. The
// placeholder is Claude Code's own (its prompt input writes `[Image #${id}]`); the engine's reader
// (2.1.296) joins a user message's text blocks into `text` and drops its image blocks, so the
// placeholder is all the mod sees. Of 138 user messages carrying an image, 45 had no words beside
// the placeholder.
const imageOnly = (text = '[Image #1]') => ({ role: 'user' as const, text, toolUses: [] })

test('an opening that is only an image is not a request, so nothing names it yet', async () => {
  expect(hasExchange([imageOnly()])).toBe(false)
  expect(hasExchange([imageOnly('[Image #1] [Image #2]')])).toBe(false)
  // A reply that has only used tools so far has no words to name from either: wait for it.
  expect(hasExchange([imageOnly(), { role: 'assistant', text: '', toolUses: [] }])).toBe(false)
})

// Dan, on #1085 (2026-10-12): "wait for Dan's own words. Name the session from his first worded
// message. If he has typed nothing after 3 turns, fall back to Claude's first reply that describes
// the image." A reply that only asks what to do with the image named sessions "Image question".
const reply = (text: string) => ({ role: 'assistant' as const, text, toolUses: [] })
const ASKS = 'What would you like me to do with this image?'
const DESCRIBES = 'The screenshot shows the invoice table overflowing its card.'

test("after an image only opening, even a reply that describes it waits for Dan's own words", async () => {
  expect(hasExchange([imageOnly(), reply(DESCRIBES)])).toBe(false)
  expect(hasExchange([imageOnly(), reply(ASKS)])).toBe(false)
  // Two image only turns are still not three.
  expect(hasExchange([imageOnly(), reply(ASKS), imageOnly('[Image #2]'), reply(DESCRIBES)])).toBe(false)
})

test('an image only opening followed by a reply that does not describe it is named from his words, never the reply', async () => {
  const messages = [imageOnly(), reply(ASKS), { role: 'user' as const, text: 'Fix the overflow in the invoice table', toolUses: [] }, reply('Looking at the table styles.')]
  expect(hasExchange(messages)).toBe(true)
  const p = namePrompt(messages)
  expect(p).toContain('Opening request:\nFix the overflow in the invoice table')
  expect(p).not.toContain('[Image #')
})

test("when Dan has typed nothing after three turns, the first reply that describes an image names it", async () => {
  const messages = [
    imageOnly(),
    reply(ASKS),
    imageOnly('[Image #2]'),
    reply('I see you have shared another image.'),
    imageOnly('[Image #3]'),
    reply(DESCRIBES),
  ]
  expect(hasExchange(messages)).toBe(true)
  const p = namePrompt(messages)
  expect(p).toContain(DESCRIBES)
  // The replies that only ask about the image, or only say one arrived, are never handed over.
  expect(p).not.toContain(ASKS)
  expect(p).not.toContain('another image')
  expect(p).not.toContain('Opening request:')
  expect(p).not.toContain('[Image #')
})

test('three image only turns with no reply describing any image still wait', async () => {
  expect(hasExchange([imageOnly(), reply(ASKS), imageOnly('[Image #2]'), reply('Got it.'), imageOnly('[Image #3]'), reply('Should I compare these two?')])).toBe(false)
})

test('a reply describes an image by a statement of its own, not by a question or a bare acknowledgement', async () => {
  expect(describesImage(DESCRIBES)).toBe(true)
  expect(describesImage("You've shared a screenshot of the Slate dashboard with a broken chart.")).toBe(true)
  // A short description using a word that can also mean arriving still describes (lessons review of #1085).
  expect(describesImage('I see a broken chart in the header.')).toBe(true)
  expect(describesImage('The table shows sent emails per day.')).toBe(true)
  expect(describesImage('The screenshot shows sent emails.')).toBe(true)
  expect(describesImage('I can see the screenshot.')).toBe(false)
  expect(describesImage('Thanks for sharing the screenshot!')).toBe(false)
  expect(describesImage(ASKS)).toBe(false)
  expect(describesImage('I see you have shared an image. What should I do with it?')).toBe(false)
  expect(describesImage('Got it. Thanks!')).toBe(false)
  expect(describesImage('')).toBe(false)
})

test("after an image only opening, the person's next words are the opening request", async () => {
  const p = namePrompt([
    imageOnly('[Image #1] [Image #2]'),
    { role: 'assistant', text: 'What would you like me to do with these?', toolUses: [] },
    { role: 'user', text: 'Fix the overflow in the invoice table', toolUses: [] },
    { role: 'assistant', text: 'Looking at the table styles.', toolUses: [] },
  ])
  expect(p).toContain('Opening request:\nFix the overflow in the invoice table')
  expect(p).not.toContain('[Image #')
})

test('an opening with an image and words is named from the words', async () => {
  const messages = [
    { role: 'user' as const, text: '[Image #1] Why is this button misaligned on the settings page', toolUses: [] },
    { role: 'assistant' as const, text: 'Checking the settings layout.', toolUses: [] },
  ]
  expect(hasExchange(messages)).toBe(true)
  const p = namePrompt(messages)
  expect(p).toContain('Opening request:\nWhy is this button misaligned on the settings page')
  expect(p).not.toContain('[Image #1]')
})

// #1123: whose words they are is the engine's mark at prompt.submit, never the transcript's role.
test("Dan's words are his typed, phone and handoff messages; a notice, a peer's or another plugin's are not", async () => {
  expect(isDans({ kind: 'composer' })).toBe(true)
  expect(isDans({ kind: 'bridge' })).toBe(true)
  expect(isDans({ kind: 'plugin', name: 'handoff', asUser: true })).toBe(true)
  for (const o of [
    { kind: 'task-notification' },
    { kind: 'peer' },
    { kind: 'peer-send-message' },
    { kind: 'scheduled-trigger' },
    { kind: 'unclassified' },
    { kind: 'sdk' },
    { kind: 'plugin', name: 'scope-modes' },
    { kind: 'plugin', name: 'some-plugin', asUser: true },
    { kind: 'plugin', name: 'handoff' },
  ])
    expect(isDans(o)).toBe(false)
})

test('a user message Dan was not recorded sending opens no name and is not read as the person', async () => {
  const NOTICE = '<task-notification> <summary>Background command completed</summary> </task-notification>'
  const messages = [imageOnly(), reply(ASKS), { role: 'user' as const, text: NOTICE, toolUses: [] }, reply('The command finished.')]
  const his = withDans(NO_DANS, '[Image #1]', true)
  expect(hasExchangeFor(messages, his)).toBe(false)
  const later = [...messages, { role: 'user' as const, text: 'Fix the overflow', toolUses: [] }, reply('Looking.')]
  const p = namePromptFor(later, withDans(his, 'Fix the overflow', false))
  expect(p).toContain('Opening request:\nFix the overflow')
  expect(p).toContain('Person: Fix the overflow')
  expect(p).not.toContain('task-notification')
})

test("Dan's record keeps his first words and his newest few, and counts his image only messages", async () => {
  let d = NO_DANS
  d = withDans(d, '[Image #1]', true)
  d = withDans(d, '', true)
  d = withDans(d, '   ', false)
  expect(d).toEqual({ words: [], imageTurns: 2 })
  for (let i = 1; i <= 12; i++) d = withDans(d, `[Image #${i}] message ${i}`, true)
  expect(d.words[0]).toBe('message 1')
  expect(d.words.length).toBe(9)
  expect(d.words.at(-1)).toBe('message 12')
  expect(d.imageTurns).toBe(2)
})

test("Dan's first words recorded are the opening request even when the transcript shows them changed", async () => {
  const d = withDans(NO_DANS, 'Fix the export', false)
  const messages = [{ role: 'user' as const, text: 'Fix the export (rewritten by a hook)', toolUses: [] }, reply('On it.')]
  expect(hasExchangeFor(messages, d)).toBe(true)
  expect(namePromptFor(messages, d)).toContain('Opening request:\nFix the export')
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
