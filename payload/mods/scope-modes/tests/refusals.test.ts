import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { callKey, READER_DOES_NOT_KNOW, readsOnly, refusalNote } from '../hooks/refusals.ts'
import { toolArgs } from '../hooks/mod-kit/toolargs.ts'
import { commandWrites, NOT_KNOWN } from './mod-kit/hooks/writes.ts'
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
  // #3323: mod-kit's write reader now gives a program it does not know as a run marked unknown
  // wherever it is handed a word that spells a path. Whether a refused call only read is judged here
  // by this file's own list of programs that only read (READ_PROGRAMS), which is longer than the
  // list the reader keeps, so such a run decides nothing here: a program on this list handed a file
  // still only reads, and one on neither list is still no read, by this list as before.
  test('a program this list knows only reads still only reads when the write reader does not know it (#3323)', () => {
    const marked = (c: string) => commandWrites(c, CWD, HOME).runs?.some(r => r.unknown) ?? false
    for (const c of ['basename src/a.txt', 'dirname src/a.txt', 'realpath a.txt', 'nl a.txt', 'egrep -n x a.txt', 'fgrep x a.txt', 'md5 a.txt', 'column -t a.txt'])
      expect([c, marked(c), bashReads(c)]).toEqual([c, true, true])
    for (const c of ['mystery a.txt', 'prettier --check a.txt', 'gh issue view 3', 'npm test']) expect([c, marked(c), bashReads(c)]).toEqual([c, true, false])
    // A run that is not one of those (a script, a tool) is no read, as before.
    for (const c of ['python3 x.py a.txt', 'npx prettier a.txt']) expect([c, marked(c), bashReads(c)]).toEqual([c, false, false])
  })
  // #3323: the reader marks a second kind of run `unknown`, a form of a program on its own list
  // that writes a file or runs a program (`file -C` compiles a magic file, `rg --hostname-bin` runs
  // a program). This file's list called `file` a read whatever its words and looked only for --pre
  // on rg, so those forms were reads before the reader raised them, and stayed reads while every
  // run marked `unknown` was left out here.
  const raised = (c: string) => (commandWrites(c, CWD, HOME).runs ?? []).filter(r => r.unknown).map(r => r.what)
  test('a form of a program that only reads which the write reader says writes or runs is not a read (#3323)', () => {
    const FILE = 'file with -C, which compiles a magic file'
    const HOST = 'rg with --hostname-bin, which runs a program'
    const PRE = 'rg with --pre, which runs a program on each file'
    for (const [c, what] of [
      ['file -C -m magic', FILE], ['file --compile -m magic', FILE], ['file -bC -m magic', FILE], ['file -m magic -C', FILE], ['/usr/bin/file -C -m magic', FILE],
      ['cat a.txt | file -C -m magic', FILE], ['cd /r/repo && file -C -m magic', FILE], ['rtk file -C -m magic', FILE],
      ['rg --hostname-bin ./x foo src', HOST], ['rg --hostname-bin=./x foo', HOST], ['rg --hostname-bin x foo', HOST], ['rg --hostname-bin=x --files', HOST],
      ['rg --pre ./x foo src', PRE], ['rg --pre=./x foo', PRE], ['rg --pre=x --files', PRE],
      ['lsof -D b /r/repo/x', 'lsof with -D, which builds or updates its device cache file'],
      ['mdls -plist out.plist a.txt', 'mdls with -plist, which writes the file it names'],
    ] as const)
      expect([c, raised(c), bashReads(c)]).toEqual([c, [what], false])
  })
  test('the same forms handed no word that spells a path, which the write reader gives no run for, are not reads either', () => {
    for (const c of ['file -C', 'file --compile', 'file -bC', 'file -C -m $M', 'rg --hostname-bin $HB --files', 'rg --hostname-bin=$HB --files', 'rg --pre $P --files', "rg --pre-glob '*.pdf' --files"])
      expect([c, raised(c), bashReads(c)]).toEqual([c, [], false])
    // file takes any unambiguous start of a long option, as git does: --comp is --compile.
    for (const c of ['file --comp -m magic', 'file --compil', 'file --co -m magic']) expect([c, bashReads(c)]).toEqual([c, false])
  })
  // The write reader and this list each judge file's --compile, and were found disagreeing (the
  // reader took only the whole word). file 5.41 compiles on --co and every longer start and refuses
  // --c as ambiguous; both read every start from --c as the form, and this holds them together.
  test("every start of file's --compile is the form to the write reader and to this list alike", () => {
    const FILE = 'file with -C, which compiles a magic file'
    for (const start of ['--c', '--co', '--com', '--comp', '--compi', '--compil', '--compile']) {
      expect([start, raised(`file ${start} -m magic`), bashReads(`file ${start} -m magic`)]).toEqual([start, [FILE], false])
      // Handed no word that spells a path, the reader gives no run and this list alone holds it.
      expect([start, raised(`file ${start}`), bashReads(`file ${start}`)]).toEqual([start, [], false])
    }
    for (const c of ['file --brief notes.txt', 'file --checking-printout notes.txt', 'file --ch notes.txt', 'file -- notes.txt', 'file -m magic notes.txt'])
      expect([c, raised(c), bashReads(c)]).toEqual([c, [], true])
  })
  test('a program only the write reader lists is no read here, since every command is judged against this list alone', () => {
    for (const c of ['cksum a.txt', 'ps', 'ps aux', 'lsof a.txt', 'mdls a.txt', 'strings a.txt', 'paste a.txt b.txt', 'pgrep bun', 'mdfind x', 'pdfinfo a.pdf'])
      expect([c, raised(c), bashReads(c)]).toEqual([c, [], false])
  })
  test('the plain forms of those programs still only read', () => {
    for (const c of ['file notes.txt', 'file -b notes.txt', 'file -c notes.txt', 'file --mime-type -b notes.txt', '/usr/bin/file notes.txt', 'rg pattern src', 'rg -n pattern', 'rg -C 2 pattern src', 'rg --files src', 'rg --hyperlink-format default pattern src'])
      expect([c, raised(c), bashReads(c)]).toEqual([c, [], true])
  })
  test('a run marked unknown decides nothing only when it carries the reader\'s plain label and its program is on this list', () => {
    // The label is the reader's own, written here because a mod's hooks cannot load mod-kit's.
    expect(READER_DOES_NOT_KNOW).toBe(NOT_KNOWN)
    const withRun = (command: string, run: { what: string; script: string }) =>
      readsOnly('Bash', readCommands(command), { files: [], changes: [], unnamed: [], runs: [{ ...run, tool: true, unknown: true, args: [{ word: 'a.txt', path: '/r/repo/a.txt' }] }] })
    expect(withRun('basename a.txt', { what: NOT_KNOWN, script: 'basename' })).toBe(true)
    expect(withRun('/usr/bin/basename a.txt', { what: NOT_KNOWN, script: '/usr/bin/basename' })).toBe(true)
    // As the reader gives it in a session, rtk written in front by the rewrite hook included.
    for (const c of ['rtk md5 a.txt', '/sbin/md5 a.txt', 'md5 a.txt | head -3']) expect([c, raised(c), bashReads(c)]).toEqual([c, [NOT_KNOWN], true])
    // A form the reader learns after this was written: nothing here names it, and it is no read.
    expect(withRun('cat a.txt', { what: 'cat with --new, which writes a file', script: 'cat' })).toBe(false)
    expect(withRun('basename a.txt', { what: 'basename with --new, which runs a program', script: 'basename' })).toBe(false)
    // A program on neither list that the commands read here do not show is no read.
    expect(withRun('cat a.txt', { what: NOT_KNOWN, script: 'mystery' })).toBe(false)
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
