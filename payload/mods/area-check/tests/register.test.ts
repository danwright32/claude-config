import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { ANSWER_MS, DEADLINE_MS, DECIDE_TOOL, ISSUE_LIMIT, ISSUES_TTL_MS, SWEEP_MS, UNREAD_TTL_MS } from '../hooks/rules.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { APP, ERRORS, HOME, ISSUES, KIT, OLD_QKEY, QKEY, REASON, SHA, SLACK, T0, TRACKED, askDan, bash, decide, edit, ghLists, refusal, said, world, type Issue, type R } from './world.ts'

// What mod-kit's reader of a shell command ($.modkit.writes) answered for each command these tests
// send, measured from the real reader with cwd /w/app (#2142). The world answers $.modkit.writes
// with this mod's byte for byte copy of that reader (tests/mod-kit/hooks/writes.ts), and the first
// test below holds the copy to these answers; the repository suite tests/test-area-check-shell-reader.sh
// holds mod-kit's own reader to them, against rules.ts.
const WRITES: Record<string, unknown> = {
  // #2254: a findings note, its text holding $PWD, *.ts and a question mark, to the installed spool
  // helper; the same note chained with a write, sent to a copy of the helper in a checkout, and the
  // helper's other subcommand. Written out in full, since the shell reader suite reads this block alone.
  'bash ~/.claude/hooks/lib/issue-spool.sh note . "reads $PWD and every *.ts file, so why?" "builder 2254"': { files: [], changes: [], unnamed: [], runs: [{ what: 'a bash script file', script: '~/.claude/hooks/lib/issue-spool.sh', path: '/Users/dan/.claude/hooks/lib/issue-spool.sh', args: [{ word: 'note', path: '/w/app/note' }, { word: '.', path: '/w/app' }, { word: 'reads $PWD and every *.ts file, so why?' }, { word: 'builder 2254', path: '/w/app/builder 2254' }] }] },
  'bash ~/.claude/hooks/lib/issue-spool.sh note . "reads $PWD and every *.ts file, so why?" "builder 2254" && sed -i \'\' \'s/a/b/\' src/lib/slack.ts': { files: [{ word: 'src/lib/slack.ts', path: '/w/app/src/lib/slack.ts', edits: true }], changes: [], unnamed: [], runs: [{ what: 'a bash script file', script: '~/.claude/hooks/lib/issue-spool.sh', path: '/Users/dan/.claude/hooks/lib/issue-spool.sh', args: [{ word: 'note', path: '/w/app/note' }, { word: '.', path: '/w/app' }, { word: 'reads $PWD and every *.ts file, so why?' }, { word: 'builder 2254', path: '/w/app/builder 2254' }] }] },
  'bash ~/.claude/hooks/lib/issue-spool.sh note . "reads $PWD and every *.ts file, so why?" "builder 2254" && echo hi > "$OUT/big.ts"': { files: [{ word: '$OUT/big.ts' }], changes: [], unnamed: [], runs: [{ what: 'a bash script file', script: '~/.claude/hooks/lib/issue-spool.sh', path: '/Users/dan/.claude/hooks/lib/issue-spool.sh', args: [{ word: 'note', path: '/w/app/note' }, { word: '.', path: '/w/app' }, { word: 'reads $PWD and every *.ts file, so why?' }, { word: 'builder 2254', path: '/w/app/builder 2254' }] }], stdout: [{ word: '$OUT/big.ts' }] },
  'bash payload/hooks/lib/issue-spool.sh note . "reads $PWD and every *.ts file, so why?" "builder 2254"': { files: [], changes: [], unnamed: [], runs: [{ what: 'a bash script file', script: 'payload/hooks/lib/issue-spool.sh', path: '/w/app/payload/hooks/lib/issue-spool.sh', args: [{ word: 'note', path: '/w/app/note' }, { word: '.', path: '/w/app' }, { word: 'reads $PWD and every *.ts file, so why?' }, { word: 'builder 2254', path: '/w/app/builder 2254' }] }] },
  'bash ~/.claude/hooks/lib/issue-spool.sh append . "$RECORD"': { files: [], changes: [], unnamed: [], runs: [{ what: 'a bash script file', script: '~/.claude/hooks/lib/issue-spool.sh', path: '/Users/dan/.claude/hooks/lib/issue-spool.sh', args: [{ word: 'append', path: '/w/app/append' }, { word: '.', path: '/w/app' }, { word: '$RECORD' }] }] },
  // #2246: a write whose unreadable word, and so the question about it, is longer than the store's 256 characters.
  [`echo hi > "$OUT/${'a'.repeat(300)}.ts"`]: { files: [{ word: `$OUT/${'a'.repeat(300)}.ts` }], changes: [], unnamed: [], stdout: [{ word: `$OUT/${'a'.repeat(300)}.ts` }] },
  "sed -i '' 's/a/b/' src/lib/slack.ts": { files: [{ word: 'src/lib/slack.ts', path: '/w/app/src/lib/slack.ts', edits: true }], changes: [], unnamed: [] },
  'echo hi > "$OUT/big.ts"': { files: [{ word: '$OUT/big.ts' }], changes: [], unnamed: [], stdout: [{ word: '$OUT/big.ts' }] },
  'echo hi > "$OUT/other.ts"': { files: [{ word: '$OUT/other.ts' }], changes: [], unnamed: [], stdout: [{ word: '$OUT/other.ts' }] },
  'npm test': { files: [], changes: [], unnamed: [] },
  'grep -n x src/big.ts > /tmp/out.txt': { files: [{ word: '/tmp/out.txt', path: '/tmp/out.txt' }], changes: [], unnamed: [], stdout: [{ word: '/tmp/out.txt', path: '/tmp/out.txt' }] },
  'echo x > src/new.ts': { files: [{ word: 'src/new.ts', path: '/w/app/src/new.ts' }], changes: [], unnamed: [], stdout: [{ word: 'src/new.ts', path: '/w/app/src/new.ts' }] },
  'echo x > "$OUT/log.txt"': { files: [{ word: '$OUT/log.txt' }], changes: [], unnamed: [], stdout: [{ word: '$OUT/log.txt' }] },
  'rm src/big.ts': { files: [], changes: [{ word: 'src/big.ts', path: '/w/app/src/big.ts', does: 'remove' }], unnamed: [] },
  "perl -pi -e 's/a/b/' /tmp/x/*.ts": { files: [{ word: '/tmp/x/*.ts', folder: '/tmp/x', edits: true }], changes: [], unnamed: [] },
  // Two commands whose 32 bit hash is the same (#2142 lessons review), and a write reaching a whole folder.
  'echo hi > "$OUT/a132789.ts"': { files: [{ word: '$OUT/a132789.ts' }], changes: [], unnamed: [], stdout: [{ word: '$OUT/a132789.ts' }] },
  'echo hi > "$OUT/a729192.ts"': { files: [{ word: '$OUT/a729192.ts' }], changes: [], unnamed: [], stdout: [{ word: '$OUT/a729192.ts' }] },
  "find src -name '*.ts' -exec sed -i '' 's/a/b/' {} +": { files: [{ word: 'src', path: '/w/app/src', edits: true, tree: true }], changes: [], unnamed: [] },
  "find docs -exec sed -i '' 's/a/b/' {} +": { files: [{ word: 'docs', path: '/w/app/docs', edits: true, tree: true }], changes: [], unnamed: [] },
  // #2373: a write reaching a whole folder holding more files that could be held than are judged one by one.
  "find gen -exec sed -i '' 's/a/b/' {} +": { files: [{ word: 'gen', path: '/w/app/gen', edits: true, tree: true }], changes: [], unnamed: [] },
  // #2321: a folder handed to a script, or a copy's folder destination, named by its path alone.
  'python3 rewrite.py src/': { files: [], changes: [], unnamed: [], runs: [{ what: 'a python3 script file', script: 'rewrite.py', path: '/w/app/rewrite.py', args: [{ word: 'src/', path: '/w/app/src' }] }] },
  'python3 rewrite.py docs': { files: [], changes: [], unnamed: [], runs: [{ what: 'a python3 script file', script: 'rewrite.py', path: '/w/app/rewrite.py', args: [{ word: 'docs', path: '/w/app/docs' }] }] },
  'python3 rewrite.py gen': { files: [], changes: [], unnamed: [], runs: [{ what: 'a python3 script file', script: 'rewrite.py', path: '/w/app/rewrite.py', args: [{ word: 'gen', path: '/w/app/gen' }] }] },
  'python3 rewrite.py src/locked': { files: [], changes: [], unnamed: [], runs: [{ what: 'a python3 script file', script: 'rewrite.py', path: '/w/app/rewrite.py', args: [{ word: 'src/locked', path: '/w/app/src/locked' }] }] },
  'cp -R lib/. src/': { files: [{ word: 'src/.', path: '/w/app/src/.', sources: ['/w/app/lib'] }], changes: [], unnamed: [] },
  'rsync -a lib/ src/': { files: [{ word: 'src/', path: '/w/app/src', sources: ['/w/app/lib'], mayBeFolder: true }], changes: [], unnamed: [] },
  // #2407: a folder handed to a script whose own text is read for what it writes there.
  'bash scan.sh src/': { files: [], changes: [], unnamed: [], runs: [{ what: 'a bash script file', script: 'scan.sh', path: '/w/app/scan.sh', args: [{ word: 'src/', path: '/w/app/src' }] }] },
  './scan.sh src/': { files: [], changes: [], unnamed: [], runs: [{ what: 'a script file run directly', script: './scan.sh', path: '/w/app/scan.sh', args: [{ word: 'src/', path: '/w/app/src' }] }] },
  'bash rewrite.sh src/': { files: [], changes: [], unnamed: [], runs: [{ what: 'a bash script file', script: 'rewrite.sh', path: '/w/app/rewrite.sh', args: [{ word: 'src/', path: '/w/app/src' }] }] },
  'bash wrap.sh src/': { files: [], changes: [], unnamed: [], runs: [{ what: 'a bash script file', script: 'wrap.sh', path: '/w/app/wrap.sh', args: [{ word: 'src/', path: '/w/app/src' }] }] },
  'bash locked.sh src/': { files: [], changes: [], unnamed: [], runs: [{ what: 'a bash script file', script: 'locked.sh', path: '/w/app/locked.sh', args: [{ word: 'src/', path: '/w/app/src' }] }] },
  './odd.sh src/': { files: [], changes: [], unnamed: [], runs: [{ what: 'a script file run directly', script: './odd.sh', path: '/w/app/odd.sh', args: [{ word: 'src/', path: '/w/app/src' }] }] },
}

// The area check in a session (#1506): the first edit a session makes to each existing source or
// test file is held when an open structural issue names the file or the file is growing fast (#1509),
// and the session decides, through the decide tool, before it is let through. Phase 1 (#1508) only
// logged what it would have done; that log, outside ~/.claude, is kept, with the hold's decisions.

test("the world's copy of mod-kit's shell reader answers every measured command as WRITES records it (#2142)", async () => {
  for (const [command, measured] of Object.entries(WRITES)) expect([command, JSON.parse(JSON.stringify(commandWrites(command, APP, HOME)))]).toEqual([command, measured])
})

test('a session start writes a loaded record outside ~/.claude, so a week with none reads as no load, never as no firings (L90)', KIT, async ($, on) => {
  const w = world($, on)
  await $.session.start({ cwd: APP, surface: 'terminal', isInteractive: true } as never)
  await w.clock.settle()
  const loaded = w.records().filter(r => r.kind === 'loaded')
  expect(loaded.length).toBe(1)
  expect(loaded[0]).toMatchObject({ v: 1, kind: 'loaded', session: 's1', rule: 2 })
})

test("a session start warms the session's repository, so its first edit within the hour reads no list of its own", KIT, async ($, on) => {
  const w = world($, on)
  await $.session.start({ cwd: APP, surface: 'terminal', isInteractive: true } as never)
  await w.clock.settle()
  expect(ghLists(w)).toBe(1)
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(ghLists(w)).toBe(1)
  expect(w.judged()[0]?.issues).toMatchObject({ state: 'read', count: 2 })
})


test('the first edit to a file a structural issue names is held: refused with the facts and how to decide, a card drawn, nothing run, logged as held', KIT, async ($, on) => {
  const w = world($, on)
  const r = await edit($ as never, w, SLACK)
  const why = refusal(r)
  expect(why).toContain('The area check held this Edit to src/lib/slack.ts.')
  expect(why).toContain('#41 (p2, tech-debt)')
  expect(why).toContain(`${DECIDE_TOOL} with {"call": "c1", "decision": "proceed"`)
  expect(w.passed).toEqual([])
  expect(w.cards).toEqual([expect.objectContaining({ toolUseId: 'c1', guard: 'Area check' })])
  expect(String(w.cards[0]?.reason)).toContain('#41')
  const [j] = w.judged()
  expect(j).toMatchObject({
    v: 2, kind: 'judged', session: 's1', agent: null, repo: 'dan/app', path: 'src/lib/slack.ts', fileKind: 'source',
    branch: '12-feature', mergeBase: 'mb123', head: SHA, decision: 'held', why: ['issues'], shown: [41], excluded: [], own: [12],
    matches: [{ n: 41, how: 'path', structural: ['tech-debt'], priority: 'p2' }],
    growth: { net: 8, size: null, fixes: 0, rank: null, crosses: false },
  })
  expect(typeof j?.ms).toBe('number')
})

test('a held edit is not claimed, so sending it again before deciding is held again', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  const again = await edit($ as never, w, SLACK, {}, 'c2')
  expect(refusal(again)).toContain('"call": "c2"')
  expect(w.judged().map(j => j.decision)).toEqual(['held', 'held'])
  expect(w.passed).toEqual([])
})

test('deciding proceed with a reason claims the file: the edit sent again goes through, untouched, and is not judged again', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  const d = await decide($ as never, { call: 'c1', decision: 'proceed', reason: REASON })
  expect(d.deny).toBe(undefined)
  expect(said(d)).toContain('Send the Edit to src/lib/slack.ts again')
  const r = await edit($ as never, w, SLACK, {}, 'c2')
  expect(r.result).toBe('done')
  expect(w.passed).toEqual([`Edit ${SLACK}`])
  expect(w.judged().length).toBe(1)
  // Version 3 (#1510): the branch and merge base the pull request line is matched by.
  expect(w.records().find(x => x.kind === 'decided')).toMatchObject({ v: 3, session: 's1', agent: null, repo: 'dan/app', branch: '12-feature', mergeBase: 'mb123', path: 'src/lib/slack.ts', call: 'c1', decision: 'proceed', reason: REASON })
})

test('a proceed reason that says nothing is refused, and the edit stays held', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  expect(refusal(await decide($ as never, { call: 'c1', decision: 'proceed', reason: 'n/a' }))).toContain('is a placeholder, not a reason')
  expect(refusal(await decide($ as never, { call: 'c1', decision: 'proceed' }))).toContain('No reason was given')
  expect(refusal(await decide($ as never, { call: 'c1', decision: 'maybe' }))).toContain('is not a decision')
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
  expect(w.records().filter(x => x.kind === 'decided')).toEqual([])
})

test('a decision names a held call, and only the session or agent it was held for can take it, so no file is cleared ahead', KIT, async ($, on) => {
  const w = world($, on)
  expect(refusal(await decide($ as never, { call: 'zz', decision: 'proceed', reason: REASON }))).toContain('No edit of yours is held under zz')
  await edit($ as never, w, SLACK)
  expect(refusal(await decide($ as never, { call: 'c1', decision: 'proceed', reason: REASON }, { agentId: 'a1' }))).toContain('No edit of yours is held under c1')
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
})

test('fold names one of the issues the hold showed, and a file held for growth alone has none to fold', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  expect(refusal(await decide($ as never, { call: 'c1', decision: 'fold', issue: 99 }))).toContain('is not an issue the hold showed')
  const d = await decide($ as never, { call: 'c1', decision: 'fold', issue: 41 })
  expect(said(d)).toContain('#41')
  expect(w.records().find(x => x.kind === 'decided')).toMatchObject({ decision: 'fold', issue: 41, call: 'c1' })
  expect((await edit($ as never, w, SLACK, {}, 'c2')).result).toBe('done')
  await edit($ as never, w, `${APP}/src/big.ts`, {}, 'c3')
  expect(refusal(await decide($ as never, { call: 'c3', decision: 'fold', issue: 41 }))).toContain('held for its growth alone')
})

test('restructure in the main session asks Dan in the dialog, worded by the hook, and Proceed anyway releases the file', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  const d = await decide($ as never, { call: 'c1', decision: 'restructure' })
  expect(said(d)).toContain('area-check:c1')
  expect(w.store[QKEY]).toMatchObject({ state: 'pending', issues: [41], session: 's1', call: 'c1', agent: null })
  w.ctl.answer = 'Proceed anyway'
  const q = await askDan($ as never, 'c1')
  expect(w.asked[0]?.question.startsWith('Restructure src/lib/slack.ts before this work?')).toBe(true)
  expect(w.asked[0]?.options.map(o => o.label)).toEqual(['Restructure first', 'Proceed anyway', 'Fold in'])
  expect(said(q)).toContain('Send the Edit to src/lib/slack.ts again')
  expect(w.store[QKEY]).toMatchObject({ state: 'answered', answer: 'Proceed anyway', issues: [41] })
  expect((await edit($ as never, w, SLACK, {}, 'c2')).result).toBe('done')
  expect(w.records().find(x => x.kind === 'decided')).toMatchObject({ decision: 'proceed', by: 'dan', call: 'c1' })
})

test('Restructure first releases the file for the structural fix', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  w.ctl.answer = 'Restructure first'
  expect(said(await askDan($ as never, 'c1'))).toContain('Restructure first')
  expect((await edit($ as never, w, SLACK, {}, 'c2')).result).toBe('done')
})

test('Fold in tells Claude to fold with the decide tool, and the edit stays held until it does', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  w.ctl.answer = 'Fold in'
  expect(said(await askDan($ as never, 'c1'))).toContain('"decision": "fold"')
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
})

test('an answer Dan did not choose records nothing: the dialog closing while he was away, or an answer typed in', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  await decide($ as never, { call: 'c1', decision: 'restructure' })
  w.ctl.answer = 'afk'
  expect(said(await askDan($ as never, 'c1'))).toContain('did not answer')
  w.ctl.answer = 'maybe later'
  expect(said(await askDan($ as never, 'c1'))).toContain('Dan typed "maybe later"')
  expect(w.store[QKEY]).toMatchObject({ state: 'pending' })
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
})

test('a question no edit is held under, or one a subagent tries to ask, is refused', KIT, async ($, on) => {
  const w = world($, on)
  expect(refusal(await askDan($ as never, 'zz'))).toContain('No edit is held under zz')
  await edit($ as never, w, SLACK)
  expect(refusal(await askDan($ as never, 'c1', { agentId: 'a1' }))).toContain('Only the main session asks Dan')
  expect(w.asked).toEqual([])
})

test("Dan's answer stands for a week for the same issues, so a later first edit applies it without asking", KIT, async ($, on) => {
  const w = world($, on)
  w.store[QKEY] = { state: 'answered', answer: 'Proceed anyway', at: T0 - 1000, issues: [41] }
  expect((await edit($ as never, w, SLACK)).result).toBe('done')
  expect(w.judged()[0]).toMatchObject({ decision: 'held', applied: 'Proceed anyway' })
  expect(w.cards).toEqual([])
})

test("Dan's answer kept under the key questions had before #2246 still stands for its week", KIT, async ($, on) => {
  const w = world($, on)
  w.store[OLD_QKEY] = { state: 'answered', answer: 'Proceed anyway', at: T0 - 1000, issues: [41] }
  expect((await edit($ as never, w, SLACK)).result).toBe('done')
  expect(w.judged()[0]).toMatchObject({ decision: 'held', applied: 'Proceed anyway' })
  expect(w.cards).toEqual([])
})

test('a question waiting under the key before #2246 is cleared once its held call is decided', KIT, async ($, on) => {
  const w = world($, on)
  expect(refusal(await edit($ as never, w, SLACK))).toContain('The area check held this Edit')
  w.store[OLD_QKEY] = { state: 'pending', at: T0, issues: [41], session: 's1', call: 'c1', agent: null }
  await decide($ as never, { call: 'c1', decision: 'proceed', reason: REASON })
  expect(w.store[OLD_QKEY]).toBeUndefined()
})

test("Dan's answer past its week, or for another set of issues, asks again", KIT, async ($, on) => {
  const w = world($, on)
  w.store[QKEY] = { state: 'answered', answer: 'Proceed anyway', at: T0 - ANSWER_MS - 1, issues: [41] }
  expect(refusal(await edit($ as never, w, SLACK))).toContain('The area check held this Edit')
  w.store[QKEY] = { state: 'answered', answer: 'Proceed anyway', at: T0 - 1000, issues: [41, 50] }
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
})

test("a subagent's edit is held for itself, and restructure hands the question to the main session, which is told at the next prompt", KIT, async ($, on) => {
  const w = world($, on)
  const r = await edit($ as never, w, SLACK, { agentId: 'a1' })
  expect(refusal(r)).toContain('hands the question to the main session')
  expect(w.judged()[0]).toMatchObject({ agent: 'a1', decision: 'held' })
  const d = await decide($ as never, { call: 'c1', decision: 'restructure' }, { agentId: 'a1' })
  expect(said(d)).toContain('Stop and report')
  expect(w.store[QKEY]).toMatchObject({ state: 'pending', agent: 'a1', call: 'c1' })
  const p = (await $.prompt.submit({ text: 'go on', origin: { kind: 'composer' }, wait: false } as never)) as R
  expect((p.context ?? []).join(' ')).toContain('src/lib/slack.ts')
  expect((p.context ?? []).join(' ')).toContain('area-check:c1')
  w.ctl.answer = 'Proceed anyway'
  await askDan($ as never, 'c1')
  expect((await edit($ as never, w, SLACK, { agentId: 'a1' }, 'c5')).result).toBe('done')
  const after = (await $.prompt.submit({ text: 'next', origin: { kind: 'composer' }, wait: false } as never)) as R
  expect((after.context ?? []).join(' ')).not.toContain('area-check:c1')
})

// #2136: the reply to a decision is worded for whoever took it. A subagent deciding its own held edit
// is told to send it again itself; the main session, recording Dan's answer for a subagent's edit, is
// told to pass that on to the agent.
test("a subagent that decides its own held edit is told to send it again itself, not to tell an agent (#2136)", KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK, { agentId: 'a1' })
  const d = await decide($ as never, { call: 'c1', decision: 'proceed', reason: REASON }, { agentId: 'a1' })
  expect(d.deny).toBe(undefined)
  expect(said(d)).toContain('Send the Edit to src/lib/slack.ts again yourself, unchanged.')
  expect(said(d)).not.toContain('tell that agent')
  expect((await edit($ as never, w, SLACK, { agentId: 'a1' }, 'c2')).result).toBe('done')
})

test("the main session recording Dan's answer for a subagent's held edit is told to have that agent send it again (#2136)", KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK, { agentId: 'a1' })
  await decide($ as never, { call: 'c1', decision: 'restructure' }, { agentId: 'a1' })
  w.ctl.answer = 'Proceed anyway'
  const a = await askDan($ as never, 'c1')
  expect(said(a)).toContain("The held Edit to src/lib/slack.ts was a subagent's: tell that agent, or a new one, to send it again, unchanged.")
  expect(said(a)).not.toContain('again yourself')
})

test('asleep, restructure notes the question for the morning, one note per issue shown, and asks nobody', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.asleep = true
  await edit($ as never, w, SLACK)
  const d = await decide($ as never, { call: 'c1', decision: 'restructure' })
  expect(said(d)).toContain('asleep')
  expect(w.notes).toEqual([expect.objectContaining({ kind: 'question', repo: 'dan/app', issue: 41 })])
  expect(w.asked).toEqual([])
  expect(w.store[QKEY]).toMatchObject({ state: 'pending' })
})

test('away, restructure is held by scope modes for when Dan is back', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.away = true
  await edit($ as never, w, SLACK)
  const d = await decide($ as never, { call: 'c1', decision: 'restructure' })
  expect(refusal(d)).toContain('Held: Dan is away')
  expect(String(w.holds[0]?.label)).toContain('src/lib/slack.ts')
  expect(w.asked).toEqual([])
})

test('an edit a settings hook refuses beneath is refused in its words, and never held, judged or claimed', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.refuse = true
  expect(refusal(await edit($ as never, w, SLACK))).toBe('refused beneath')
  expect(w.cards).toEqual([])
  expect(w.judged()).toEqual([])
  w.ctl.refuse = false
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
})

test('a quiet file is claimed: a second edit to it in the session is not judged again', KIT, async ($, on) => {
  const w = world($, on)
  expect((await edit($ as never, w, `${APP}/src/pay/stripe.ts`)).result).toBe('done')
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`, {}, 'c2')
  expect(w.judged().length).toBe(1)
  expect(w.passed.length).toBe(2)
})

// A shell write was not judged here until #2142, which holds it: see the shell tests at the end.
test('a new file, a docs file and a file in no checkout are not judged (decisions 2 and 3)', KIT, async ($, on) => {
  const w = world($, on)
  await $.tool.call({ tool: 'Write', tool_use_id: 'c1', file_path: `${APP}/src/new.ts`, content: 'x' } as never)
  await edit($ as never, w, `${APP}/docs/x.md`)
  await edit($ as never, w, '/elsewhere/a.ts')
  await w.clock.settle()
  expect(w.judged()).toEqual([])
  expect(w.passed.length).toBe(3)
})

test("an issue the session's branch names is left out, and was its only match, so the file is quiet (decision 5)", KIT, async ($, on) => {
  const w = world($, on, { branch: 'fix/41-slack' })
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'quiet', why: [], shown: [], excluded: [41], own: [41] })
})

test("an issue the session's /goal names is left out too", KIT, async ($, on) => {
  const w = world($, on, { branch: 'feature', goal: 'Finish #41 today' })
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'quiet', excluded: [41], own: [41], goal: 'set' })
})

test('an unlabelled issue naming the file is logged but does not hold it', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'quiet', matches: [{ n: 42, how: 'basename', structural: [], priority: null }] })
})


test('a file across the growth bar is held by growth, with its rough growth line', KIT, async ($, on) => {
  const w = world($, on)
  const r = await edit($ as never, w, `${APP}/src/big.ts`)
  expect(refusal(r)).toContain('Rough: grew 800 lines net in 90 days, about 2400 lines now, 1 commit titles saying fix.')
  expect(w.judged()[0]).toMatchObject({ decision: 'held', why: ['growth'], growth: { net: 800, size: 2400, fixes: 1, rank: 1, crosses: true } })
})

test('a subagent is judged for itself: a quiet file the main session judged is judged again under its id (decision 8)', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`, { agentId: 'a1' }, 'c2')
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`, { agentId: 'a1' }, 'c3')
  expect(w.judged().map(r => r.agent)).toEqual([null, 'a1'])
  expect(w.passed.length).toBe(3)
})

test('issues are cached per repository for an hour, then read again', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  await edit($ as never, w, `${APP}/src/big.ts`)
  expect(ghLists(w)).toBe(1)
  await w.clock.advance(ISSUES_TTL_MS + 1)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  expect(ghLists(w)).toBe(2)
})


test('a wrong account is retried as each other account gh is logged in to (decision 12)', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.gh = env => (env?.GH_TOKEN === 'tok-dan-work' ? { exitCode: 0, stdout: JSON.stringify(ISSUES), stderr: '' } : { exitCode: 1, stdout: '', stderr: 'GraphQL: Could not resolve to a Repository with the name dan/app.' })
  await edit($ as never, w, SLACK)
  expect(w.judged()[0]).toMatchObject({ decision: 'held', issues: { state: 'read' } })
})

test('issues no account can read are UNREAD with the reason: growth still holds, a quiet edit goes through unclaimed, and the failure is reused for ten minutes', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.gh = () => ({ exitCode: 1, stdout: '', stderr: 'error connecting to api.github.com' })
  await edit($ as never, w, `${APP}/src/big.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'held', why: ['growth'], issues: { state: 'unread', why: 'error connecting to api.github.com' } })
  const asked = ghLists(w)
  expect((await edit($ as never, w, SLACK, {}, 'c2')).result).toBe('done')
  expect(ghLists(w)).toBe(asked)
  expect(w.judged()[1]).toMatchObject({ decision: 'quiet', issues: { state: 'unread' } })
  // Not claimed, since its issues were never read (decision 12): its next edit is judged again.
  await edit($ as never, w, SLACK, {}, 'c3')
  expect(w.judged().length).toBe(3)
  await w.clock.advance(UNREAD_TTL_MS + 1)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`, {}, 'c4')
  expect(ghLists(w)).toBeGreaterThan(asked)
})

test('a list that fills the limit is TRUNCATED, its own outcome', KIT, async ($, on) => {
  const many = Array.from({ length: ISSUE_LIMIT }, (_, i) => ({ number: i + 1000, title: '', body: '', labels: [] }))
  const w = world($, on, { issues: many })
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ issues: { state: 'truncated', count: ISSUE_LIMIT } })
})

test('the path reader failing makes the issues UNREAD, saying so', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.pathsFails = true
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ issues: { state: 'unread', why: 'the path reader failed: match-open-issues --paths: stdin is not JSON' } })
})


test('every read runs under one deadline below 75% of the budget, and a read past it is UNREAD as timed out, the edit going on', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.gh = () => 'slow'
  const p = $.tool.call({ tool: 'Edit', tool_use_id: 'c1', file_path: SLACK, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(DEADLINE_MS + 2000)
  expect(((await p) as R).result).toBe('done')
  expect(Math.max(...w.timeouts)).toBeLessThanOrEqual(DEADLINE_MS)
  expect(w.judged()[0]).toMatchObject({ issues: { state: 'unread', why: `not read within ${DEADLINE_MS / 1000} seconds` } })
})

test('the ranking is reused for the same origin head on the same day, and made again when the head moves', KIT, async ($, on) => {
  const w = world($, on)
  const numstats = () => w.ran.filter(l => l.includes(' log origin/main ')).length
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  await edit($ as never, w, `${APP}/src/big.ts`)
  expect(numstats()).toBe(1)
  w.ctl.sha = 'ffff00'
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  expect(numstats()).toBe(2)
})

// Lessons reviews of 5a4148a and adb5a9e: a ranking another edit started runs under that edit's
// deadline, so it fails when that edit's time is spent (here its git log is killed at the timeout it
// was given), and a later edit sharing it, whose own time remains, makes the ranking again.
test("a later edit sharing a ranking that failed for lack of the first edit's time makes its own, within its own deadline", KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.slowLogOnce = true
  const a = $.tool.call({ tool: 'Edit', tool_use_id: 'c1', file_path: SLACK, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(3000)
  const b = $.tool.call({ tool: 'Edit', tool_use_id: 'c2', file_path: `${APP}/src/big.ts`, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(DEADLINE_MS + 3000)
  await Promise.all([a, b])
  const [first, second] = w.judged()
  expect(first).toMatchObject({ path: 'src/lib/slack.ts', growth: { unread: `git log was still running after ${DEADLINE_MS} ms` } })
  expect(second).toMatchObject({ path: 'src/big.ts', decision: 'held', growth: { net: 800, crosses: true } })
})

// Lessons review of 42547b6: the same for a shared issue read another edit started.
test("a later edit sharing an issue read that ran out of the first edit's time reads again, within its own deadline", KIT, async ($, on) => {
  const w = world($, on)
  let first = true
  w.ctl.gh = () => {
    if (!first) return { exitCode: 0, stdout: JSON.stringify(ISSUES), stderr: '' }
    first = false
    return 'slow'
  }
  const a = $.tool.call({ tool: 'Edit', tool_use_id: 'c1', file_path: `${APP}/src/big.ts`, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(3000)
  const b = $.tool.call({ tool: 'Edit', tool_use_id: 'c2', file_path: SLACK, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(DEADLINE_MS + 3000)
  await Promise.all([a, b])
  const [x, y] = w.judged()
  expect(x).toMatchObject({ path: 'src/big.ts', issues: { state: 'unread', why: `not read within ${DEADLINE_MS / 1000} seconds` } })
  expect(y).toMatchObject({ path: 'src/lib/slack.ts', decision: 'held', issues: { state: 'read' } })
})

test('its own failure lets the edit through, is kept in a separate error file, and is said once a session in a dim line', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.branchThrows = true
  const r = await edit($ as never, w, SLACK)
  await edit($ as never, w, `${APP}/src/big.ts`, {}, 'c2')
  expect(r.result).toBe('done')
  expect(w.passed.length).toBe(2)
  expect(w.records(ERRORS).length).toBe(2)
  expect(w.records(ERRORS)[0]).toMatchObject({ kind: 'error', session: 's1', path: SLACK, error: 'git could not be asked' })
  expect(w.logs.filter(l => l.includes('area check')).length).toBe(1)
  expect(w.logs[0]).toBe('The area check could not look at src/lib/slack.ts (git could not be asked), so the edit went ahead unchecked; the error is kept in ~/.claude-area-check/errors.jsonl.')
})

test('a log that cannot be written is an error of its own, kept in the error file, and the hold still stands', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.logFails = true
  expect(refusal(await edit($ as never, w, SLACK))).toContain('The area check held this Edit')
  expect(w.records(ERRORS)[0]).toMatchObject({ kind: 'error', error: 'the log could not be written: No space left on device' })
})

test('a session start sweeps issue lists unread for a week and answers past their week, and keeps a question still waiting on Dan', KIT, async ($, on) => {
  const w = world($, on)
  w.store['issues:dan/old'] = { at: T0 - SWEEP_MS, state: 'read', count: 0, issues: [] }
  w.store['question:dan/app\nsrc/old.ts'] = { state: 'answered', answer: 'Proceed anyway', at: T0 - ANSWER_MS, issues: [1] }
  w.store['question:dan/app\nsrc/wait.ts'] = { state: 'pending', at: T0 - ANSWER_MS * 2, issues: [1], session: 's0', call: 'c0', agent: null }
  await $.session.start({ cwd: APP, surface: 'terminal', isInteractive: true } as never)
  await w.clock.settle()
  expect(Object.keys(w.store).sort()).toEqual(['issues:dan/app', 'question:dan/app\nsrc/wait.ts'])
})

test('the decide tool is offered at every session start, a headless one included, since subagents decide with it too', KIT, async ($, on) => {
  const w = world($, on)
  await $.session.start({ cwd: APP, surface: 'terminal', isInteractive: false } as never)
  await w.clock.settle()
  expect(w.tools).toEqual(['decide'])
})

test('the decide tool says it decides a held command as well as a held edit, and that the held call is sent again', KIT, async ($, on) => {
  const w = world($, on)
  await $.session.start({ cwd: APP, surface: 'terminal', isInteractive: false } as never)
  await w.clock.settle()
  expect(w.toolDescriptions.decide).toContain('first edit or command')
  expect(w.toolDescriptions.decide).toContain('send the held call again')
})

// #2142: a shell command writing a file is held as its first edit would be, the files it writes as
// mod-kit's reader answered them (WRITES, measured), so python, sed or a heredoc is no way round the check.
// `bash` is the world's: a Bash call as Claude sends it, its result settled.
const SED = "sed -i '' 's/a/b/' src/lib/slack.ts"
const BUILT = 'echo hi > "$OUT/big.ts"'
// The commands WRITES records for #2254 and #2246.
const NOTE = 'bash ~/.claude/hooks/lib/issue-spool.sh note . "reads $PWD and every *.ts file, so why?" "builder 2254"'
const COPY_NOTE = 'bash payload/hooks/lib/issue-spool.sh note . "reads $PWD and every *.ts file, so why?" "builder 2254"'
const APPEND = 'bash ~/.claude/hooks/lib/issue-spool.sh append . "$RECORD"'
const LONG = `echo hi > "$OUT/${'a'.repeat(300)}.ts"`

test('a shell command writing a file a structural issue names is held as its first edit would be, and goes ahead once decided', KIT, async ($, on) => {
  const w = world($, on)
  const r = await bash($ as never, w, SED)
  const why = refusal(r)
  expect(why).toContain('The area check held this Bash command, which writes src/lib/slack.ts.')
  expect(why).toContain('#41 (p2, tech-debt)')
  expect(why).toContain(`${DECIDE_TOOL} with {"call": "b1", "decision": "proceed"`)
  expect(why).toContain('Then send the Bash command again, unchanged.')
  expect(w.passed).toEqual([])
  expect(w.cards).toEqual([expect.objectContaining({ toolUseId: 'b1', guard: 'Area check' })])
  expect(w.judged()[0]).toMatchObject({ path: 'src/lib/slack.ts', decision: 'held', agent: null })
  const d = await decide($ as never, { call: 'b1', decision: 'proceed', reason: REASON })
  expect(said(d)).toContain('Send the Bash command again, unchanged.')
  expect((await bash($ as never, w, SED, {}, 'b2')).result).toBe('done')
  // The file is claimed for the session, whichever tool writes it next.
  expect((await edit($ as never, w, SLACK, {}, 'c3')).result).toBe('done')
  expect(w.judged().length).toBe(1)
})

test('Fold in on a held shell command says to send the Bash command again, naming it as the hold did', KIT, async ($, on) => {
  const w = world($, on)
  await bash($ as never, w, SED)
  w.ctl.answer = 'Fold in'
  const s = said(await askDan($ as never, 'b1'))
  expect(s).toContain('"decision": "fold"')
  expect(s).toContain('Send the Bash command again, unchanged.')
  expect(s).not.toContain('send the Bash again')
})

test('a shell command writing no file, a new file or only files that are no source runs unjudged, asking nothing of GitHub', KIT, async ($, on) => {
  const w = world($, on)
  for (const [i, c] of ['npm test', 'grep -n x src/big.ts > /tmp/out.txt', 'echo x > src/new.ts', 'echo x > "$OUT/log.txt"', 'rm src/big.ts'].entries())
    expect((await bash($ as never, w, c, {}, `b${i}`)).result).toBe('done')
  expect(ghLists(w)).toBe(0)
  expect(w.judged().length).toBe(0)
})

test('a shell command whose file cannot be read is held saying so, may only proceed, and the unchanged command then runs', KIT, async ($, on) => {
  const w = world($, on)
  const why = refusal(await bash($ as never, w, BUILT))
  expect(why).toContain('cannot be read')
  expect(why).toContain('$OUT/big.ts')
  expect(why).toContain('Edit or Write')
  expect(w.passed).toEqual([])
  expect(w.records().find(x => x.kind === 'unread')).toMatchObject({ v: 1, session: 's1', agent: null, repo: 'dan/app', word: '$OUT/big.ts', decision: 'held' })
  expect(refusal(await decide($ as never, { call: 'b1', decision: 'restructure' }))).toContain('Edit or Write')
  const d = await decide($ as never, { call: 'b1', decision: 'proceed', reason: REASON })
  expect(said(d)).toContain('Send the Bash command again, unchanged.')
  expect((await bash($ as never, w, BUILT, {}, 'b2')).result).toBe('done')
  // Another command is decided on its own.
  expect(refusal(await bash($ as never, w, 'echo hi > "$OUT/other.ts"', {}, 'b3'))).toContain('cannot be read')
})

test('a write that cannot be read passes only where nothing could hold it: no checkout, or no fast growing file and no structural issue naming a file', KIT, async ($, on) => {
  const w = world($, on, { issues: [] })
  expect((await bash($ as never, w, "perl -pi -e 's/a/b/' /tmp/x/*.ts")).result).toBe('done')
  w.ctl.numstat = ''
  expect((await bash($ as never, w, BUILT, {}, 'b2')).result).toBe('done')
  expect(w.records().find(x => x.kind === 'unread')).toMatchObject({ word: '$OUT/big.ts', decision: 'passed' })
})

test('a decided command lets through only that command, never another sharing its 32 bit hash', KIT, async ($, on) => {
  const w = world($, on)
  const a = 'echo hi > "$OUT/a132789.ts"'
  const b = 'echo hi > "$OUT/a729192.ts"'
  expect(refusal(await bash($ as never, w, a))).toContain('cannot be read')
  await decide($ as never, { call: 'b1', decision: 'proceed', reason: REASON })
  expect((await bash($ as never, w, a, {}, 'b2')).result).toBe('done')
  expect(refusal(await bash($ as never, w, b, {}, 'b3'))).toContain('$OUT/a729192.ts')
})

test('a held command whose word is longer than the store key limit can still be decided, and then runs (#2246)', KIT, async ($, on) => {
  const w = world($, on)
  expect(refusal(await bash($ as never, w, LONG))).toContain('cannot be read')
  const d = await decide($ as never, { call: 'b1', decision: 'proceed', reason: REASON })
  expect(said(d)).toContain('Send the Bash command again, unchanged.')
  expect((await bash($ as never, w, LONG, {}, 'b2')).result).toBe('done')
  // Nothing in the store is kept under a key the store would refuse.
  expect(Object.keys(w.store).filter(k => k.length > 256)).toEqual([])
})

test('a findings note to the installed spool helper goes through with nothing judged, though its text reads like files (#2254)', KIT, async ($, on) => {
  // Each command these tests send is one WRITES records, so the shell reader suite holds it to the real reader.
  for (const c of [NOTE, COPY_NOTE, APPEND, LONG]) expect(Object.keys(WRITES)).toContain(c)
  const w = world($, on)
  expect((await bash($ as never, w, NOTE)).result).toBe('done')
  expect(w.judged().length).toBe(0)
  expect(w.records().filter(x => x.kind === 'unread')).toEqual([])
})

test('a write chained with a findings note is still judged, and a copy of the helper or another subcommand is held as before (#2254)', KIT, async ($, on) => {
  const w = world($, on)
  expect(refusal(await bash($ as never, w, `${NOTE} && sed -i '' 's/a/b/' src/lib/slack.ts`))).toContain('which writes src/lib/slack.ts')
  expect(refusal(await bash($ as never, w, `${NOTE} && echo hi > "$OUT/big.ts"`, {}, 'b2'))).toContain('$OUT/big.ts')
  // Each is handed `.`, the checkout itself, so since #2321 it is held first for the held files under it;
  // once that file is decided, the append is still held for its unreadable word.
  expect(refusal(await bash($ as never, w, COPY_NOTE, {}, 'b3'))).toContain('which writes src/big.ts.')
  expect(refusal(await bash($ as never, w, APPEND, {}, 'b4'))).toContain('which writes src/big.ts.')
  await decide($ as never, { call: 'b4', decision: 'proceed', reason: REASON })
  const why = refusal(await bash($ as never, w, APPEND, {}, 'b5'))
  expect(why).toContain('which writes src/lib/slack.ts.')
  await decide($ as never, { call: 'b5', decision: 'proceed', reason: REASON })
  expect(refusal(await bash($ as never, w, APPEND, {}, 'b6'))).toContain('$RECORD')
})

// #2142 lessons review: a write reaching a whole folder (find -exec over it, git putting a folder
// back) reaches every file under it, so each one the area check could hold there is judged.
const FIND = "find src -name '*.ts' -exec sed -i '' 's/a/b/' {} +"

test('a shell write reaching a whole folder is held for each file under it that could be held, and goes ahead once each is decided', KIT, async ($, on) => {
  const w = world($, on)
  // The fast growing file under the folder, then the file a structural issue names, each on its own.
  expect(refusal(await bash($ as never, w, FIND))).toContain('The area check held this Bash command, which writes src/big.ts.')
  await decide($ as never, { call: 'b1', decision: 'proceed', reason: REASON })
  const why = refusal(await bash($ as never, w, FIND, {}, 'b2'))
  expect(why).toContain('The area check held this Bash command, which writes src/lib/slack.ts.')
  expect(why).toContain('#41 (p2, tech-debt)')
  await decide($ as never, { call: 'b2', decision: 'proceed', reason: REASON })
  expect((await bash($ as never, w, FIND, {}, 'b3')).result).toBe('done')
  expect(w.judged().map(j => j.path)).toEqual(['src/big.ts', 'src/lib/slack.ts'])
})

test('a write reaching a folder nothing could hold under runs, judging no file', KIT, async ($, on) => {
  const w = world($, on)
  expect((await bash($ as never, w, "find docs -exec sed -i '' 's/a/b/' {} +")).result).toBe('done')
  expect(w.judged().length).toBe(0)
})

test('a write reaching a folder whose files cannot be listed is held as unread, saying why', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.slowLogOnce = true
  const p = $.tool.call({ tool: 'Bash', tool_use_id: 'b1', command: FIND } as never)
  await w.clock.advance(DEADLINE_MS + 1000)
  const why = refusal((await p) as R)
  expect(why).toContain('src reaches every file under it')
  expect(why).toContain('cannot be listed')
  expect(w.records().find(x => x.kind === 'unread')).toMatchObject({ word: 'src', decision: 'held' })
})

// #2321: a folder handed to a script, or a folder a copy lands in, reaches every file under it, as a
// write marked `tree` does: mod-kit names it by its path alone, so the disk says it is a folder.
const SCRIPT_SRC = 'python3 rewrite.py src/'
// gen/f1.ts .. gen/fN.ts on the default branch, with an open structural issue naming gen/f1.ts, so
// every file in gen is one the area check could hold.
const GEN_ISSUE: Issue = { number: 50, title: 'Untangle the generator', body: 'gen/f1.ts does everything', labels: [{ name: 'tech-debt' }, { name: 'priority-p2' }] }
const genWorld = ($: unknown, on: Parameters<typeof world>[1], n: number) => {
  const w = world($, on, { issues: [...ISSUES, GEN_ISSUE] })
  w.ctl.folders.push(`${APP}/gen`)
  const gen = Array.from({ length: n }, (_, i) => `gen/f${i + 1}.ts`)
  w.ctl.tracked = [TRACKED, ...gen].join('\n')
  for (const g of gen) w.files[`${APP}/${g}`] = 'x'
  return w
}

test('a script handed a folder holding a held file is held, naming the file, and goes ahead once each is decided (#2321)', KIT, async ($, on) => {
  const w = world($, on)
  expect(refusal(await bash($ as never, w, SCRIPT_SRC))).toContain('The area check held this Bash command, which writes src/big.ts.')
  await decide($ as never, { call: 'b1', decision: 'proceed', reason: REASON })
  const why = refusal(await bash($ as never, w, SCRIPT_SRC, {}, 'b2'))
  expect(why).toContain('The area check held this Bash command, which writes src/lib/slack.ts.')
  expect(why).toContain('#41 (p2, tech-debt)')
  await decide($ as never, { call: 'b2', decision: 'proceed', reason: REASON })
  expect((await bash($ as never, w, SCRIPT_SRC, {}, 'b3')).result).toBe('done')
  expect(w.judged().map(j => j.path)).toEqual(['src/big.ts', 'src/lib/slack.ts'])
})

test('a script handed a folder holding no held file, or a folder not on the disk, runs judging no file (#2321)', KIT, async ($, on) => {
  const w = world($, on)
  expect((await bash($ as never, w, 'python3 rewrite.py docs')).result).toBe('done')
  expect((await bash($ as never, w, 'python3 rewrite.py gen', {}, 'b2')).result).toBe('done')
  expect(w.judged().length).toBe(0)
  expect(w.records().filter(x => x.kind === 'unread')).toEqual([])
})

test('a recursive copy into a folder holding a held file is held, naming the file: rsync, and cp -R into dir/. (#2321)', KIT, async ($, on) => {
  const w = world($, on)
  expect(refusal(await bash($ as never, w, 'rsync -a lib/ src/'))).toContain('which writes src/big.ts.')
  expect(refusal(await bash($ as never, w, 'cp -R lib/. src/', {}, 'b2'))).toContain('which writes src/big.ts.')
})

test('a script handed a folder whose files cannot be listed is held as unread, saying why (#2321)', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.slowLogOnce = true
  const p = $.tool.call({ tool: 'Bash', tool_use_id: 'b1', command: SCRIPT_SRC } as never)
  await w.clock.advance(DEADLINE_MS + 1000)
  const why = refusal((await p) as R)
  expect(why).toContain('src/ reaches every file under it')
  expect(why).toContain('cannot be listed')
  expect(w.records().find(x => x.kind === 'unread')).toMatchObject({ word: 'src/', decision: 'held' })
})

test('a script handed a path whose kind cannot be read is held as unread, since it may be a folder (#2321)', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.statFails.push(`${APP}/src/locked`)
  const why = refusal(await bash($ as never, w, 'python3 rewrite.py src/locked'))
  expect(why).toContain('src/locked may be a folder')
  expect(why).toContain('permission denied')
  expect(w.records().find(x => x.kind === 'unread')).toMatchObject({ word: 'src/locked', decision: 'held' })
})

test('a folder holding 25 files that could be held has each judged one by one, naming the file (#2321)', KIT, async ($, on) => {
  const w = genWorld($, on, 25)
  expect(refusal(await bash($ as never, w, 'python3 rewrite.py gen'))).toContain('which writes gen/f1.ts.')
  expect(w.records().filter(x => x.kind === 'unread')).toEqual([])
})

test('a folder holding 26 files that could be held is held whole as unread, judging none one by one, and runs once decided (#2321)', KIT, async ($, on) => {
  const w = genWorld($, on, 26)
  const why = refusal(await bash($ as never, w, 'python3 rewrite.py gen'))
  expect(why).toContain('gen reaches every file under it, and 26 files under it could be held, more than the 25 the area check judges one by one')
  expect(why).toContain('gen/f1.ts')
  expect(w.judged().length).toBe(0)
  expect(w.records().find(x => x.kind === 'unread')).toMatchObject({ word: 'gen', decision: 'held' })
  await decide($ as never, { call: 'b1', decision: 'proceed', reason: REASON })
  expect((await bash($ as never, w, 'python3 rewrite.py gen', {}, 'b2')).result).toBe('done')
})

// #2407: a folder handed to a script is held only when the script can write there. Its file is read,
// and mod-kit's one reader of what a command writes reads it as the program its interpreter runs;
// a script that cannot be read, or that writes anything at all, is held as #2321 holds it.
const SCAN = 'for f in "$1"/*.ts; do\n  grep -n TODO "$f" 2>/dev/null\ndone\nwc -l "$1"/*.ts | sort -n\ncommand -v git >/dev/null 2>&1\n'

test('a read only scan handed a folder holding held files runs judging no file, run by bash or directly (#2407)', KIT, async ($, on) => {
  const w = world($, on)
  w.files[`${APP}/scan.sh`] = `#!/usr/bin/env bash\n${SCAN}`
  expect((await bash($ as never, w, 'bash scan.sh src/')).result).toBe('done')
  expect((await bash($ as never, w, './scan.sh src/', {}, 'b2')).result).toBe('done')
  expect(w.judged().length).toBe(0)
  expect(w.records().filter(x => x.kind === 'unread')).toEqual([])
  // Each pass is on record, so a reading that lets everything through shows in the log (L551).
  expect(w.records().filter(x => x.kind === 'script-reads')).toMatchObject([
    { word: 'src/', script: `${APP}/scan.sh`, decision: 'passed' },
    { word: 'src/', script: `${APP}/scan.sh`, decision: 'passed' },
  ])
})

test("a read only scan is still held when mod-kit's reader fails while reading the script, never passed (#2407)", KIT, async ($, on) => {
  const w = world($, on)
  w.files[`${APP}/scan.sh`] = SCAN
  w.ctl.pipelineThrows = true
  expect(refusal(await bash($ as never, w, 'bash scan.sh src/'))).toContain('which writes src/big.ts.')
  expect(w.records().filter(x => x.kind === 'script-reads')).toEqual([])
})

test('a script that writes into the folder it is handed, or runs another script, is still held, naming the file (#2407)', KIT, async ($, on) => {
  const w = world($, on)
  w.files[`${APP}/rewrite.sh`] = `#!/bin/bash\n${SCAN}sed -i '' 's/a/b/' "$1"/*.ts\n`
  w.files[`${APP}/wrap.sh`] = `${SCAN}python3 tools/fix.py "$1"\n`
  expect(refusal(await bash($ as never, w, 'bash rewrite.sh src/'))).toContain('The area check held this Bash command, which writes src/big.ts.')
  expect(refusal(await bash($ as never, w, 'bash wrap.sh src/', {}, 'b2'))).toContain('The area check held this Bash command, which writes src/big.ts.')
})

test('a script handed a folder that cannot be read, is not there, or runs under an interpreter mod-kit does not read is still held (#2407)', KIT, async ($, on) => {
  const w = world($, on)
  w.files[`${APP}/locked.sh`] = SCAN
  w.ctl.unreadableFiles.push(`${APP}/locked.sh`)
  w.files[`${APP}/odd.sh`] = `#!/usr/bin/env frob\n${SCAN}`
  expect(refusal(await bash($ as never, w, 'bash locked.sh src/'))).toContain('which writes src/big.ts.')
  expect(refusal(await bash($ as never, w, './odd.sh src/', {}, 'b2'))).toContain('which writes src/big.ts.')
  expect(refusal(await bash($ as never, w, SCRIPT_SRC, {}, 'b3'))).toContain('which writes src/big.ts.')
})

// #2373: a write marked as reaching a whole folder (find with exec, git putting a folder back) is
// bounded the same way, so a folder like payload/hooks cannot outrun the hook's 10 second budget.
const FIND_GEN = "find gen -exec sed -i '' 's/a/b/' {} +"

test('a write reaching a folder holding 25 files that could be held has each judged one by one, naming the file (#2373)', KIT, async ($, on) => {
  const w = genWorld($, on, 25)
  expect(refusal(await bash($ as never, w, FIND_GEN))).toContain('which writes gen/f1.ts.')
  expect(w.records().filter(x => x.kind === 'unread')).toEqual([])
})

test('a write reaching a folder holding 26 files that could be held is held whole as unread, judging none one by one, and runs once decided (#2373)', KIT, async ($, on) => {
  const w = genWorld($, on, 26)
  const why = refusal(await bash($ as never, w, FIND_GEN))
  expect(why).toContain('gen reaches every file under it, and 26 files under it could be held, more than the 25 the area check judges one by one')
  expect(why).toContain('gen/f1.ts')
  expect(w.judged().length).toBe(0)
  expect(w.records().find(x => x.kind === 'unread')).toMatchObject({ word: 'gen', decision: 'held' })
  await decide($ as never, { call: 'b1', decision: 'proceed', reason: REASON })
  expect((await bash($ as never, w, FIND_GEN, {}, 'b2')).result).toBe('done')
})

// The size the bound exists for: a folder like payload/hooks, where an unbounded walk starts two git
// processes for each file it judges and passes. The world's stubbed tracked list stands in for git,
// so the fixture costs no real walk; the cost is counted as the git processes the check starts,
// which is what spends the hook's budget, and stays the same however many files the folder holds.
test('a write reaching a folder of 2000 files that could be held is held whole without judging them, starting no git process per file (#2373)', KIT, async ($, on) => {
  const n = 2000
  const w = genWorld($, on, n)
  const why = refusal(await bash($ as never, w, FIND_GEN))
  expect(why).toContain(`gen reaches every file under it, and ${n} files under it could be held, more than the 25 the area check judges one by one`)
  expect(w.judged().length).toBe(0)
  expect(w.ran.filter(l => l.includes(' remote get-url ')).length).toBeLessThan(5)
})

test("a subagent's shell write is held for itself, where its loop is known", KIT, async ($, on) => {
  const w = world($, on)
  expect(refusal(await bash($ as never, w, SED, { agentId: 'a1' }))).toContain('hands the question to the main session')
  expect(w.judged()[0]).toMatchObject({ agent: 'a1', decision: 'held', path: 'src/lib/slack.ts' })
})

test('a reader that fails lets the command through, kept in the error file and said once', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.writesThrows = true
  expect((await bash($ as never, w, SED)).result).toBe('done')
  expect(w.records(ERRORS)[0]).toMatchObject({ kind: 'error', session: 's1', error: 'the command could not be read' })
  expect(w.logs.filter(l => l.includes('area check'))).toEqual(["The area check could not read what a shell command writes (the command could not be read), so it went ahead unchecked; the error is kept in ~/.claude-area-check/errors.jsonl."])
})
