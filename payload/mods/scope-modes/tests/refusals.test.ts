import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { callKey, readsOnly, refusalNote } from '../hooks/refusals.ts'
import { toolArgs } from '../hooks/mod-kit/toolargs.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { readCommands } from './read.ts'

// #3158: on the night of 16 Nov 2026 auto mode's check was unavailable for hours and the morning
// report listed 340 refused calls one by one, every one later done. The report folds the refusals
// with no verdict, and needs from each refusal note whether it only read and which call it was, so a
// later identical call that ran can be matched to it. Every answer here leans one way: anything not
// certainly a read is not one, so a refusal that needs Dan stays listed.

const CWD = '/r/repo'
const HOME = '/r/home'
const bashReads = (command: string) => readsOnly('Bash', readCommands(command), commandWrites(command, CWD, HOME))

describe('which refused calls only read', () => {
  test('plain reads, git reads and rtk in front of them only read', () => {
    for (const c of ['git status', 'git log -5 --oneline', 'git log --oneline --stat','git -C /r/repo diff main', 'rtk git status', 'ls -la /r/repo', 'cat a.txt | grep -n x', 'rg -n foo src', 'find . -name "*.ts"', 'wc -l a.txt b.txt', 'cd /r/repo && git status', 'sort a.txt'])
      expect([c, bashReads(c)]).toEqual([c, true])
  })
  test('anything that writes, runs code or cannot be read is not a read', () => {
    for (const c of [
      'git commit -m x', 'git add a.txt', 'git push', 'git branch -D x', 'git diff --output=x.patch', 'git diff --outp=x.patch', 'git log --out x.log', 'tree -o out.txt','git -c core.pager=x log',
      'mkdir -p out', 'rm a.txt', 'cp a b', 'cat a > b', 'echo hi >> notes.md', 'ls | tee out.txt', 'sed -i s/a/b/ a.txt', 'sed -n 1p a.txt',
      'find . -delete', 'find . -exec rm {} +', 'sort -o out.txt a.txt', 'rg --pre ./x foo', 'python3 x.py', 'bash x.sh', 'npm test',
      'gh issue view 3', 'curl https://x.dev', 'xargs rm < list', 'eval "$x"', 'cat $(make-list)', 'sudo cat /etc/x', 'awk "{print}" a',
    ])
      expect([c, bashReads(c)]).toEqual([c, false])
  })
  test('a tool that only reads by its name is a read; a writer or an unknown tool is not', () => {
    expect(readsOnly('Read', [], { files: [], changes: [], unnamed: [] })).toBe(true)
    expect(readsOnly('Grep', [], { files: [], changes: [], unnamed: [] })).toBe(true)
    for (const t of ['Write', 'Edit', 'Agent', 'SendMessage', 'mcp__x__read_thing', 'Bash'])
      expect([t, readsOnly(t, [], { files: [], changes: [], unnamed: [] })]).toEqual([t, false])
  })
})

describe('which call a refusal was', () => {
  test('the key is the tool and its input, whatever the order of the input or the keys the engine adds', () => {
    const refused = callKey('Bash', { command: 'git commit -F m.txt', description: 'Commit' })
    expect(callKey('Bash', toolArgs({ tool: 'Bash', description: 'Commit', command: 'git commit -F m.txt', tool_use_id: 't9', agentId: 'a1', consent: true }))).toBe(refused)
    expect(callKey('Bash', { command: 'git commit -F n.txt', description: 'Commit' })).not.toBe(refused)
    expect(callKey('Write', { command: 'git commit -F m.txt', description: 'Commit' })).not.toBe(refused)
  })
  test('a retry carrying requestMeta from a hook ahead is the same call as the refusal, which never carries it (#3219)', () => {
    const refused = callKey('mcp__x__publish', { page: 'a.html' })
    expect(callKey('mcp__x__publish', toolArgs({ tool: 'mcp__x__publish', tool_use_id: 't10', page: 'a.html', requestMeta: { 'anthropic/sources': 'relay' } }))).toBe(refused)
  })
  test('rtk written in front of a command by the rewrite hook is the same call', () => {
    expect(callKey('Bash', { command: 'rtk git status' })).toBe(callKey('Bash', { command: 'git status' }))
    expect(callKey('Bash', { command: 'rtk proxy git status' })).not.toBe(callKey('Bash', { command: 'git status' }))
  })
})

describe('the refusal note', () => {
  test('a refusal with no verdict says so, with the reason as given, the call and what it was', () => {
    expect(refusalNote('Bash', { command: 'git commit -F m.txt\nsecond line', description: 'Commit' }, 't1', 'Classifier unavailable', false)).toEqual({
      tool: 'Bash',
      text: 'the auto mode classifier refused Bash: Classifier unavailable',
      reason: 'Classifier unavailable',
      noVerdict: true,
      toolUseId: 't1',
      what: 'git commit -F m.txt',
    })
    expect(refusalNote('Write', { file_path: '/r/a.txt', content: 'x' }, 't2', 'Write was not reviewed: the transcript was too long', false)).toMatchObject({ noVerdict: true, what: '/r/a.txt' })
    expect(refusalNote('Bash', { command: 'git status' }, 't3', 'Classifier unavailable', true)).toMatchObject({ read: true })
  })
  test('a real refusal by the check is never marked as having no verdict', () => {
    for (const reason of ['[Git Destructive]', 'The server-side auto mode classifier judged this action dangerous (it gave no explanation)', 'Auto mode classifier blocked action: x']) {
      const n = refusalNote('Bash', { command: 'git reset --hard' }, 't4', reason, false)
      expect([reason, n.noVerdict]).toEqual([reason, undefined])
      expect(n.text).toBe(`the auto mode classifier refused Bash: ${reason}`)
    }
  })
  test('what it was is cut short, never the whole input', () => {
    const n = refusalNote('Bash', { command: `echo ${'a'.repeat(400)}` }, 't5', 'Classifier unavailable', false)
    expect(n.what.length).toBeLessThanOrEqual(160)
  })
})
