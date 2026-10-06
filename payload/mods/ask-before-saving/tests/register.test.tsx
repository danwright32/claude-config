import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { APPROVAL_MS } from '../hooks/rules.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'

// Ask before saving (claude-config#618) in a session: every route to lasting memory is refused until
// Dan answers, his own permanent words skip the question, and each answer does what the spec says.
// Since #777 Claude asks in Claude Code's own dialog (AskUserQuestion), told how by the refusal, and
// the mod reads Dan's answer from that dialog's result; a subagent's write is refused, never asked.
// A write is never held open while Dan reads: a hook that waits on him is cut at its 10 second
// budget and the write then runs (measured 2026-10-04), so the call is refused at once.

// mod-kit, standing in: a mod cannot import another mod's files. What a command writes is read by
// mod-kit's own reader, a byte for byte copy under tests/mod-kit that tools/check-mod-shared-parts.sh
// holds to mod-kit's (#752: a table of commands and the output the reader was believed to give was
// kept in step with mod-kit's tests by hand, and its older entries had no counterpart at all). The
// stand-in asks the world (`__modkit`), which reads with that copy, as scope modes' tests do.
// #777: the subagent call that raised a question in Dan's main session, cut to the lines that matter.
// A python heredoc editing a test file, whose text builds throwaway fixture homes.
const FIXTURE =
  "python3 - <<'EOF'\np='tests/test-claude-sync.sh'\ns=open(p).read()\nnew=r'''\n" +
  'E27HA="$WORK/e627-homeA"; mkdir -p "$E27HA/hooks"; printf \'# rules\\n\' > "$E27HA/CLAUDE.md"\n' +
  'E27HB="$WORK/e627-homeB"; printf \'# rules\\n\' > "$E27HB/CLAUDE.md"\n' +
  "'''\nopen(p,'w').write(s+new)\nEOF"
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const modkit = {
        writes: async (input: { command: string; cwd: string; home: string }) => {
          const r = await built.process.run(['__modkit', 'writes', JSON.stringify(input)])
          if (r.exitCode !== 0) throw new Error(r.stderr)
          return JSON.parse(r.stdout)
        },
        // A checkout cloned at /tmp/repo, a folder under /tmp/locked the disk cannot read, and no
        // other checkout in a temporary folder (#726).
        workingTree: async ({ path }: { path: string }) => {
          if (path.startsWith('/tmp/locked/')) throw new Error('EACCES: /tmp/locked')
          return path.startsWith('/tmp/repo/') ? '/tmp/repo' : null
        },
      }
      return { ...built, modkit } as never
    })
  },
}
// Another mod's guard, refusing a write whose text carries its marker, as the style check refuses a
// dash. Listed after mod-kit, so where ask before saving loads beside it does not decide the order.
const guard: { name: string; register: Register } = {
  name: 'a-guard',
  register: on => {
    on('tool.call', async ($, e, next) => {
      if (JSON.stringify(e).includes('GUARD-REFUSES')) return { deny: 'Blocked: this carries a dash.' }
      // Refusing every call while the test's world holds /gate/refuses, as the collision guard refuses
      // a file another session is editing: a refusal the second send can meet and the first did not.
      if (await $.fs.exists('/gate/refuses')) return { deny: 'Blocked: another session is editing this file.' }
      // A guard that takes its time on a call carrying the marker: a read the test's world holds.
      if (JSON.stringify(e).includes('HOLD-AT-GUARD')) await $.fs.read('/gate/guard')
      return next(e)
    })
  },
}
// The notes Claude reads. A plugin's own $.session.append reaches no hook in a test in 2.1.289, the
// test's or another plugin's (both measured 2026-10-04: "no implementation for session.append"), so
// every note fails here, and the mod's fallback for a note that cannot be added (a toast carrying
// the whole note, so Dan sees what Claude was not told) is how the test reads it. The kit's error
// now adds "a test answers it with on('session.append', ...)", but measured again on 2026-10-05
// (#764) a test's hook on 'session.append', with or without { door: 'note' }, is never called and
// the call still rejects with "no implementation for session.append", so this stands.
const withKit = { plugins: [modKit, guard] }
const notesOf = (w: { toasts: string[] }) =>
  w.toasts
    .filter(t => t.startsWith('Claude was not told: '))
    .map(t => t.slice('Claude was not told: '.length))
    .join('\n')

const HOME = '/Users/dan'
const CWD = '/Users/dan/Apps/slate'
// What a refusal tells Claude to do when the save waits on Dan (#777): ask him in the dialog.
const ASKS = 'Ask him now with AskUserQuestion'

type Dialog = { answer?: string; afk?: boolean; fails?: boolean }
type Asked = { questions: { question: string; header: string; options: { label: string; description?: string }[]; multiSelect: boolean }[]; metadata?: { source?: string } }
// The Mac and Claude Code beneath the mod: files, the tools that write them, Claude Code's own
// question dialog (answered as `dialog` says), the session's agents, the memory section of the
// system prompt, prompts a plugin submits, and toasts.
// `auto` stands for auto mode (#738): its classifier refuses a call no model request asked for, which
// a call a plugin makes for itself is. `ownClock` leaves the clock to the test.
// `gate` holds the guard's first read of its gate until `opened` settles, calling `reached` as it starts.
const world = (on: On, init: { files?: Record<string, string>; failWrites?: boolean; cwdFails?: boolean; auto?: boolean; ownClock?: true; agents?: string[]; env?: Record<string, string>; gate?: { reached: () => void; opened: Promise<void> } } = {}) => {
  let gateReads = 0
  const files: Record<string, string> = { ...(init.files ?? {}) }
  const ran: { tool: string; input: Record<string, unknown> }[] = []
  const asked: Asked[] = []
  const dialog: Dialog = {}
  const toasts: string[] = []
  // The prompts a plugin submitted, each a turn of Claude's own: since #777 there are none.
  const prompts: string[] = []
  const clock = init.ownClock ? (undefined as unknown as ReturnType<typeof mock.clock>) : mock.clock(on)
  mock.env(on, { HOME })
  // Claude Code's environment as printenv reads it: HOME and whatever the test sets.
  const env: Record<string, string> = { HOME, ...(init.env ?? {}) }
  const printenv: string[] = []
  on('process.run', ($, e) => {
    // mod-kit's write reader, read here with its copy (the stand-in above asks for it).
    if (e.argv[0] === '__modkit' && e.argv[1] === 'writes') {
      const input = JSON.parse(String(e.argv[2])) as { command: string; cwd: string; home: string }
      const out = JSON.stringify(commandWrites(input.command, input.cwd, input.home))
      return { value: { exitCode: 0, stdout: out, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
    }
    if (e.argv[0] !== '/usr/bin/printenv') throw new Error(`unexpected command: ${e.argv.join(' ')}`)
    printenv.push(String(e.argv[1]))
    const value = env[String(e.argv[1])]
    // A printenv that fails (exit 2) for a name the test marks so.
    if (String(e.argv[1]) === 'PRINTENV_BREAKS') return { value: { exitCode: 2, stdout: '', stderr: 'printenv: write error', isStdoutTruncated: false, isStderrTruncated: false } } as never
    return { value: { exitCode: value === undefined ? 1 : 0, stdout: value ?? '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
  })
  const at = { cwd: CWD }
  on('session.cwd', () => {
    if (init.cwdFails) throw new Error('no session')
    return { value: at.cwd } as never
  })
  on('agent.list', () => ({ value: (init.agents ?? []).map(id => ({ id, description: 'a task', agentType: 'general-purpose' })) }) as never)
  on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined }) as never)
  on('fs.read', async ($, e) => {
    if (e.path === '/gate/guard') {
      if (++gateReads === 1 && init.gate) {
        init.gate.reached()
        await init.gate.opened
      }
      return { value: '' } as never
    }
    const t = files[e.path]
    if (t === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: t } as never
  })
  on('tool.call', ($, e, next) => {
    const { tool, tool_use_id: _id, agentId: _a, consent: _c, ...input } = e as unknown as Record<string, unknown>
    if (tool === 'AskUserQuestion') {
      if (dialog.fails) throw new Error('the dialog broke')
      const a = input as unknown as Asked
      asked.push(a)
      const q = a.questions[0]?.question ?? ''
      const result = { questions: a.questions, answers: dialog.answer === undefined ? {} : { [q]: dialog.answer }, ...(dialog.afk ? { afkTimeoutMs: 60_000 } : {}) }
      return { result, text: `User has answered: ${dialog.answer ?? ''}` } as never
    }
    if (init.auto && next.origin.plugin !== 'engine')
      return { deny: `The server-side auto mode classifier gave no verdict for ${String(tool)}: the request that produced this action did not ask for one.` } as never
    ran.push({ tool: String(tool), input })
    if (init.failWrites) return { isError: true, result: 'String to replace not found in file.', text: 'String to replace not found in file.' } as never
    return { result: 'written', text: 'written' } as never
  })
  on('ui.invalidate', () => ({ value: undefined }) as never)
  on('prompt.section', ($, e) => ({ text: e.text }))
  on('prompt.submit', ($, e) => {
    if (e.origin.kind === 'plugin') prompts.push(e.text)
    return { text: e.text } as never
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }) as never)
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  on('session.compact', () => ({ messages: [{ role: 'assistant', text: 'summary', toolUses: [] }] }) as never)
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  return { files, ran, asked, dialog, toasts, prompts, clock, at, printenv }
}
type W = ReturnType<typeof world>

type Caller = { tool: { call: (e: never) => Promise<unknown> } }
type Result = { deny?: string; text?: string; isError?: boolean; context?: readonly string[] }
let calls = 0
const call = async ($: Caller, input: Record<string, unknown>) => (await $.tool.call({ tool_use_id: `t${++calls}`, ...input } as never)) as Result
// What Claude reads of a refused call: the refusal, whether a tool.call hook or the classic hook gave it.
const refusalOf = (r: Result) => r.deny ?? (r.isError ? r.text : undefined) ?? ''
const contextOf = (r: Result) => (r.context ?? []).join('\n')
const idIn = (refusal: string) => /"source": "ask-before-saving:([^"]+)"/.exec(refusal)?.[1]
// Claude asking Dan as the refusal told it to, and Dan answering in the dialog.
const askDan = async ($: Caller, w: W, refusal: string, answer: string | undefined, file: string, rule = 'ask before merging', extra: Record<string, unknown> = {}) => {
  const id = idIn(refusal)
  if (!id) throw new Error(`no save id in: ${refusal}`)
  w.dialog.answer = answer
  return call($, {
    tool: 'AskUserQuestion',
    questions: [{ question: `Save to ${file} for good: ${rule}?`, header: 'Rule', options: [{ label: 'Yes', description: 'y' }, { label: 'No', description: 'n' }], multiSelect: false }],
    metadata: { source: `ask-before-saving:${id}` },
    ...extra,
  })
}
const dan = async ($: unknown, text: string, kind = 'composer') => {
  await ($ as { prompt: { submit: (x: never) => Promise<unknown> } }).prompt.submit({ text, origin: { kind } } as never)
}
// Nothing went to the main session unasked: no prompt of the mod's own and no note (#777: a For good
// once submitted a prompt to the main session for a subagent's call, twice).
const quietOnMain = (w: W) => {
  expect(w.prompts).toEqual([])
  expect(notesOf(w)).toBe('')
}

test('a Write to a project CLAUDE.md is refused, and Claude is told to ask Dan in the dialog, naming the file, in plain words', withKit, async ($, on) => {
  const w = world(on)
  const r = await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '# Slate\n\n- Ask before merging.\n' })
  expect(w.ran).toEqual([])
  const why = refusalOf(r)
  expect(why).toContain(ASKS)
  expect(why).toContain('~/Apps/slate/CLAUDE.md')
  expect(why).toContain('one plain sentence, never the command or the raw text')
  expect(idIn(why)).toBe('t' + calls)
  // Nothing is drawn in the band and nothing is sent to the session: Claude asks, in the dialog.
  quietOnMain(w)
  expect(w.toasts).toEqual([])
})

test('the dialog Claude opens shows the mod\'s own answers, and For good saves the identical call once, told in that same result', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const command = `F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`
  const refused = refusalOf(await call($, { tool: 'Bash', command, description: 'Append the rule to MEMORY.md' }))
  expect(refused).toContain('~/.claude/projects/p/memory/MEMORY.md')
  const answered = await askDan($, w, refused, 'For good', '~/.claude/projects/p/memory/MEMORY.md', 'skip the screenshots')
  // Dan saw Claude's plain words, the file, and the three answers with what each does.
  expect(w.asked.length).toBe(1)
  const q = w.asked[0].questions[0]
  expect(q.question).toBe('Save to ~/.claude/projects/p/memory/MEMORY.md for good: skip the screenshots?')
  // Claude Code's dialog takes a header of at most 12 characters (lessons review of #783).
  expect(q.header).toBe('Memory rule')
  expect(q.header.length).toBeLessThanOrEqual(12)
  expect(q.multiSelect).toBe(false)
  expect(q.options.map(o => [o.label, o.description])).toEqual([
    ['For good', 'Saved to ~/.claude/projects/p/memory/MEMORY.md'],
    ['Just this session', 'Followed until this session ends; nothing is written'],
    ['Not at all', 'Nothing is saved'],
  ])
  // Claude reads the answer and what to do in the dialog's own result, nowhere else.
  expect(contextOf(answered)).toContain('Dan answered For good to saving this to ~/.claude/projects/p/memory/MEMORY.md')
  expect(contextOf(answered)).toContain(JSON.stringify(command))
  quietOnMain(w)
  expect(w.ran).toEqual([])
  // Sent again from a request of Claude's own, described in its own words: saved, nothing asked.
  const again = await call($, { tool: 'Bash', command, description: 'Save the rule Dan approved' })
  expect(again.deny).toBeUndefined()
  expect(w.ran.map(r => r.input.command)).toEqual([command])
  expect(contextOf(again)).toContain('Saved to ~/.claude/projects/p/memory/MEMORY.md, as Dan answered For good.')
  // The approval was for that one save: the same call once more is refused again.
  expect(refusalOf(await call($, { tool: 'Bash', command }))).toContain(ASKS)
  expect(w.ran.length).toBe(1)
})

// #777: a subagent's call raised the question in Dan's main session, and For good then asked the main
// session to send the subagent's call again, in the wrong tree, twice. A subagent never asks.
test("a subagent's write to lasting memory is refused and never asked about: nothing reaches the main session or Dan", withKit, async ($, on) => {
  const w = world(on, { agents: ['agent-a1'] })
  const r = await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'a', new_string: 'a\n- Ask before merging.', agentId: 'agent-a1' })
  const why = refusalOf(r)
  expect(why).toContain('only the main session may do, after asking Dan; a subagent never asks him')
  expect(why).toContain('put the rule and the file in your final report')
  expect(why).not.toContain('AskUserQuestion')
  expect(w.ran).toEqual([])
  quietOnMain(w)
  expect(w.toasts).toEqual([])
  // Nothing waits on Dan for it: the main session cannot answer a question about it either.
  const forged = await call($, {
    tool: 'AskUserQuestion',
    questions: [{ question: 'Save to ~/Apps/slate/CLAUDE.md for good: x?', header: 'x', options: [{ label: 'a', description: 'a' }], multiSelect: false }],
    metadata: { source: `ask-before-saving:t${calls - 1}` },
  })
  expect(forged.deny).toContain('No save is waiting')
  expect(w.asked).toEqual([])
  // A subagent asking in the dialog about a save is refused too.
  const own = await call($, { tool: 'AskUserQuestion', questions: [{ question: 'q?', header: 'x', options: [], multiSelect: false }], metadata: { source: 'ask-before-saving:t1' }, agentId: 'agent-a1' })
  expect(own.deny).toContain('Only the main session asks Dan')
  // Its writes elsewhere go through untouched.
  await call($, { tool: 'Write', file_path: 'README.md', content: 'x', agentId: 'agent-a1' })
  expect(w.ran.map(x => x.input.file_path)).toEqual(['README.md'])
})

// A deadline on a wait for a condition, so one never met fails by name rather than hanging.
const within = async <T,>(p: Promise<T>, what: string, ms = 2000): Promise<T> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([p, new Promise<never>((_, reject) => (timer = setTimeout(() => reject(new Error(`${what} within ${ms} ms`)), ms)))])
  } finally {
    clearTimeout(timer)
  }
}
// Lessons review of #783: a subagent's judged call is marked so the classic hook beneath, which
// cannot see the loop, does not judge it again for the main session. With one mark per key, the
// first of two identical calls to finish cleared it while the second was still on its way down, and
// the second was judged again there (here, after the shell profile changed under it) and refused
// with an instruction to ask Dan: the main session question #777 removes.
test("two identical subagent calls in flight: the first finishing never exposes the second to the main session's question", withKit, async ($, on) => {
  let reached!: () => void
  const arrived = new Promise<void>(r => (reached = r))
  let open!: () => void
  const opened = new Promise<void>(r => (open = r))
  const w = world(on, { agents: ['agent-a1'], gate: { reached, opened } })
  const command = 'python3 -c "print(1)" # $XGATE/CLAUDE.md HOLD-AT-GUARD'
  // The second call, marked by ask before saving, then held by the guard beneath it.
  const second = call($, { tool: 'Bash', command, agentId: 'agent-a1' })
  let first: Result
  try {
    await within(arrived, 'the held call never reached the guard')
    first = await call($, { tool: 'Bash', command, agentId: 'agent-a1' })
    // Now a profile sets the variable, so judged again the held call would count as a save.
    w.files[`${HOME}/.zshrc`] = `export XGATE=${HOME}/.claude\n`
  } finally {
    open()
  }
  expect(first.deny).toBeUndefined()
  const held = await within(second, 'the held call never came back')
  expect(refusalOf(held)).not.toContain(ASKS)
  expect(held.deny).toBeUndefined()
  expect(w.ran.length).toBe(2)
})

test('the subagent call from #777, a python heredoc building fixture homes in a test, goes straight through, from a subagent or the main session', withKit, async ($, on) => {
  const w = world(on, { agents: ['agent-a1'] })
  await call($, { tool: 'Bash', command: FIXTURE, agentId: 'agent-a1' })
  await call($, { tool: 'Bash', command: FIXTURE })
  expect(w.ran.length).toBe(2)
  quietOnMain(w)
  // The positive control: the same kind of script reaching CLAUDE.md through a variable it sets is
  // still refused, from either.
  const real = `D=~/.claude; python3 -c "open('$D/CLAUDE.md','a').write('- rule')"`
  expect(refusalOf(await call($, { tool: 'Bash', command: real }))).toContain(ASKS)
  expect(refusalOf(await call($, { tool: 'Bash', command: real, agentId: 'agent-a1' }))).toContain('a subagent never asks him')
  expect(w.ran.length).toBe(2)
})

// Lessons review of #783: any exit but 0 read as "unset", so a printenv that failed let the save
// through unasked. Only exit 1 means unset; anything else fails the hook, which refuses.
test('a printenv that fails is never read as the variable being unset: the save is refused', withKit, async ($, on) => {
  const w = world(on)
  // An inline script the real reader judges writes files, so what the command mentions is read (#752:
  // the stand-in reader took every python3 command for one, and print(1) writes nothing).
  const r = await call($, { tool: 'Bash', command: `python3 -c "open('out.txt','w').write('1')" # $PRINTENV_BREAKS/CLAUDE.md` })
  expect(refusalOf(r)).toContain('could not check whether this writes lasting memory')
  expect(w.ran).toEqual([])
})

test('a path through a variable Claude Code\'s environment holds still counts, so its save is refused', withKit, async ($, on) => {
  const w = world(on, { env: { WORK: '/Users/dan/.claude' } })
  expect(refusalOf(await call($, { tool: 'Bash', command: FIXTURE }))).toContain(ASKS)
  expect(w.ran).toEqual([])
})

// Claude Code's built-in auto-memory writer saves through tool calls in a loop of its own, whose id
// no agent list names (#705, the engine's declaration). Refused like a subagent's, and the main
// session is told, so it can decide with Dan.
test("Claude Code's memory writer is refused, and the main session is told what it would have saved", withKit, async ($, on) => {
  const w = world(on, { agents: ['agent-a1'] })
  const path = `${HOME}/.claude/projects/-Users-dan-Apps-slate/memory/feedback-no-merge-quiz.md`
  const r = await call($, { tool: 'Write', file_path: path, content: 'Skip the merge quiz.\n', agentId: 'fork-memory' })
  expect(refusalOf(r)).toContain('a subagent never asks him')
  expect(w.ran).toEqual([])
  expect(notesOf(w)).toContain('tried to save to ~/.claude/projects/-Users-dan-Apps-slate/memory/feedback-no-merge-quiz.md and was refused')
  expect(notesOf(w)).toContain('Skip the merge quiz.')
  expect(w.prompts).toEqual([])
})

test('an Edit to a file in the memory folder is refused, naming that file', withKit, async ($, on) => {
  const path = `${HOME}/.claude/projects/-Users-dan-Apps-slate/memory/MEMORY.md`
  const w = world(on, { files: { [path]: '- [a](a.md)\n' } })
  const r = await call($, { tool: 'Edit', file_path: path, old_string: '- [a](a.md)', new_string: '- [a](a.md)\n- [b](b.md)' })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain(ASKS)
  expect(refusalOf(r)).toContain('~/.claude/projects/-Users-dan-Apps-slate/memory/MEMORY.md')
})

test('a Bash heredoc into CLAUDE.md is refused too', withKit, async ($, on) => {
  const w = world(on)
  const r = await call($, { tool: 'Bash', command: "cat >> CLAUDE.md <<'EOF'\n- Never merge on Fridays.\nEOF" })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain(ASKS)
  expect(refusalOf(r)).toContain('~/Apps/slate/CLAUDE.md')
})

// #705: these went straight through. The paths are mod-kit's shared reader's (proved in its tests):
// a cd before a relative path, a copy into the memory folder, an inline script, a patch.
test('a write by any shell route mod-kit reads is refused: a cd into the memory folder, a copy into it, an inline script, a patch', withKit, async ($, on) => {
  const w = world(on, { files: { [`${CWD}/rules.patch`]: '--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ -1 +1,2 @@\n x\n+- rule\n' } })
  const routes = [
    "cd ~/.claude/projects/p/memory && cat > note.md <<'EOF'\n- skip it\nEOF",
    'cp note.md ~/.claude/projects/p/memory/',
    "python3 -c \"open('/Users/dan/.claude/CLAUDE.md','a').write('- rule')\"",
    'git apply rules.patch',
  ]
  for (const command of routes) expect(`${command}: ${refusalOf(await call($, { tool: 'Bash', command }))}`).toContain(ASKS)
  expect(w.ran).toEqual([])
})

// #743: `F=<memory folder>/MEMORY.md; printf ... >> "$F"` appended to MEMORY.md with no question.
test('a save through a path the command holds in a variable is refused, naming the file it goes to', withKit, async ($, on) => {
  const w = world(on)
  for (const command of [`F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`, `export F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`]) {
    const why = refusalOf(await call($, { tool: 'Bash', command }))
    expect(`${command}: ${why}`).toContain(ASKS)
    expect(why).toContain('~/.claude/projects/p/memory/MEMORY.md')
  }
  expect(w.ran).toEqual([])
})

test('a save to a target the words cannot name is refused when the command mentions lasting memory, and goes through when it mentions none', withKit, async ($, on) => {
  const w = world(on)
  const asked = refusalOf(await call($, { tool: 'Bash', command: `printf 'x\\n' >> "$(ls ~/.claude/projects/p/memory/MEMORY.md)"` }))
  expect(asked).toContain(ASKS)
  expect(asked).toContain('~/.claude/projects/p/memory/MEMORY.md')
  await call($, { tool: 'Bash', command: `printf 'x\\n' >> "$OUT"` })
  await call($, { tool: 'Bash', command: 'cat ~/.claude/CLAUDE.md > notes.txt' })
  expect(w.ran.map(r => r.input.command)).toEqual([`printf 'x\\n' >> "$OUT"`, 'cat ~/.claude/CLAUDE.md > notes.txt'])
})

test('a write anywhere else, a patch that touches no lasting memory, a backup in a temporary folder, and a Bash call that writes nothing go straight through', withKit, async ($, on) => {
  const w = world(on, { files: { [`${CWD}/other.patch`]: '--- a/README.md\n+++ b/README.md\n' } })
  await call($, { tool: 'Write', file_path: 'README.md', content: 'x' })
  await call($, { tool: 'Bash', command: 'git apply other.patch' })
  await call($, { tool: 'Bash', command: 'cp CLAUDE.md /tmp/backup/CLAUDE.md' })
  await call($, { tool: 'Bash', command: 'ls -la' })
  expect(w.ran.map(r => r.tool)).toEqual(['Write', 'Bash', 'Bash', 'Bash'])
})

// #726: everything under a temporary folder was exempt, but a session started in a repository
// cloned there loads its CLAUDE.md and AGENTS.md, so a save to one went through unasked.
test('a save into a checkout in a temporary folder is refused, by Write and by Bash', withKit, async ($, on) => {
  const w = world(on)
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/tmp/repo/AGENTS.md', content: '- use pnpm\n' }))).toContain('/tmp/repo/AGENTS.md')
  expect(refusalOf(await call($, { tool: 'Bash', command: 'cp CLAUDE.md /tmp/repo/CLAUDE.md' }))).toContain(ASKS)
  expect(w.ran).toEqual([])
})

test('a save to a temporary folder the disk cannot read is refused, never let through', withKit, async ($, on) => {
  const w = world(on)
  const r = await call($, { tool: 'Write', file_path: '/tmp/locked/CLAUDE.md', content: '- rule\n' })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain('could not check whether this writes lasting memory (EACCES: /tmp/locked)')
})

test('a subagent write the mod cannot judge is refused too, never let through', withKit, async ($, on) => {
  const w = world(on, { agents: ['agent-a1'] })
  const r = await call($, { tool: 'Write', file_path: '/tmp/locked/CLAUDE.md', content: '- rule\n', agentId: 'agent-a1' })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain('could not check whether this writes lasting memory')
})

// #705: Dan was asked about a save before any guard had judged it. The refusal comes beneath every
// mod's tool.call hook now, so a save another guard refuses never asks him.
test('a save another guard refuses is refused by that guard, so Claude is never told to ask about it', withKit, async ($, on) => {
  const w = world(on)
  const r = await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- GUARD-REFUSES this rule\n' })
  expect(r.deny).toBe('Blocked: this carries a dash.')
  expect(w.ran).toEqual([])
})

// #707: a settings hook (the payload write gate) decides beneath every mod at classic.PreToolUse.
test('a save a settings hook refuses is refused by it, before any instruction to ask (#707)', withKit, async ($, on) => {
  const w = world(on)
  on('classic.PreToolUse', ($, e) => (JSON.stringify(e).includes('GATE-REFUSES') ? { deny: 'Blocked: the payload write gate refused it.' } : {}))
  const r = await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- GATE-REFUSES this rule\n' })
  expect(refusalOf(r)).toBe('Blocked: the payload write gate refused it.')
  expect(w.ran).toEqual([])
  expect(refusalOf(await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- Ask before merging.\n' }))).toContain(ASKS)
})

test("Dan's own permanent words skip the question, and Claude is told to say what it saved", withKit, async ($, on) => {
  const w = world(on)
  await dan($, 'From now on, ask before you merge anything.')
  const r = await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'a', new_string: 'a\n- Ask before merging.' })
  expect(w.ran.map(x => x.tool)).toEqual(['Edit'])
  expect(r.deny).toBeUndefined()
  expect(contextOf(r)).toContain('say in one line what you saved')
  expect(contextOf(r)).toContain('~/Apps/slate/CLAUDE.md')
  await dan($, 'ok and the other thing')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'b', new_string: 'b\n- x' }))).toContain(ASKS)
})

test("the same words from his phone count, and still pass every other guard's check", withKit, async ($, on) => {
  const w = world(on)
  await dan($, 'Always run the linter first.', 'bridge')
  await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'a', new_string: 'a\n- Run the linter first.' })
  expect(w.ran.map(x => x.tool)).toEqual(['Edit'])
  const refused = await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'b', new_string: 'b\n- GUARD-REFUSES' })
  expect(refused.deny).toBe('Blocked: this carries a dash.')
  expect(w.ran.length).toBe(1)
})

test("permanent words from a peer session's message or a plugin's prompt do not skip the question", withKit, async ($, on) => {
  const w = world(on)
  for (const kind of ['peer', 'plugin']) {
    await dan($, 'From now on, never merge on Fridays.', kind)
    const r = await call($, { tool: 'Edit', file_path: 'CLAUDE.md', old_string: kind, new_string: `${kind}\n- Never merge on Fridays.` })
    expect(`${kind}: ${refusalOf(r)}`).toContain(ASKS)
  }
  expect(w.ran).toEqual([])
})

// Dan's answer is read only from his dialog: a question that hides the file, one about no waiting
// save, or one carrying its own answers is refused before he sees it.
test('the dialog is refused when the question does not name the file, names no waiting save, or carries answers already', withKit, async ($, on) => {
  const w = world(on)
  const refused = refusalOf(await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }))
  const vague = await askDan($, w, refused, 'For good', 'the project notes')
  expect(vague.deny).toContain('must name the file the rule would go to (~/Apps/slate/AGENTS.md)')
  const unknown = await askDan($, w, refused.replace(/ask-before-saving:[^"]+/, 'ask-before-saving:nope'), 'For good', '~/Apps/slate/AGENTS.md')
  expect(unknown.deny).toContain('No save is waiting under nope')
  const filled = await askDan($, w, refused, 'For good', '~/Apps/slate/AGENTS.md', 'use pnpm', { answers: { x: 'For good' } })
  expect(filled.deny).toContain('only his choice in the dialog decides')
  expect(w.asked).toEqual([])
  // None of them approved anything.
  expect(refusalOf(await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }))).toContain(ASKS)
  expect(w.ran).toEqual([])
})

test('a dialog that closed itself while Dan was away approves nothing, and the save can be asked about again', withKit, async ($, on) => {
  const w = world(on)
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  const refused = refusalOf(await call($, input))
  w.dialog.afk = true
  const away = await askDan($, w, refused, 'For good', '~/Apps/slate/AGENTS.md')
  expect(contextOf(away)).toContain('Dan did not answer')
  // Still waiting under its id: asked again once Dan is back, his For good approves it.
  w.dialog.afk = false
  await askDan($, w, refused, 'For good', '~/Apps/slate/AGENTS.md')
  expect((await call($, input)).deny).toBeUndefined()
  expect(w.ran.length).toBe(1)
})

test("an answer typed in Dan's own words saves nothing and is handed to Claude to act on", withKit, async ($, on) => {
  const w = world(on)
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  const refused = refusalOf(await call($, input))
  const typed = await askDan($, w, refused, 'only for the web app', '~/Apps/slate/AGENTS.md')
  expect(contextOf(typed)).toContain('"only for the web app". Nothing was saved.')
  expect(refusalOf(await call($, input))).toContain(ASKS)
  expect(w.ran).toEqual([])
})

test('the same save refused twice waits under one question, the latest', withKit, async ($, on) => {
  const w = world(on)
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  const first = refusalOf(await call($, input))
  const second = refusalOf(await call($, input))
  expect((await askDan($, w, first, 'For good', '~/Apps/slate/AGENTS.md')).deny).toContain('No save is waiting')
  await askDan($, w, second, 'For good', '~/Apps/slate/AGENTS.md')
  expect((await call($, input)).deny).toBeUndefined()
})

test('For good approves the save, not the spelling: the same file and text by another path goes through, other text does not', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  await askDan($, w, refusalOf(await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' })), 'For good', '~/Apps/slate/AGENTS.md')
  expect(refusalOf(await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- Use npm.\n' }))).toContain(ASKS)
  expect(w.ran).toEqual([])
  const r = await call($, { tool: 'Write', file_path: `${CWD}/AGENTS.md`, content: '- Use pnpm.\n' })
  expect(r.deny).toBeUndefined()
  expect(w.ran.map(x => x.input.content)).toEqual(['- Use pnpm.\n'])
})

// Lessons review of #738: For good approves the file named. A relative path sent again after the
// session has moved writes another file, which nobody asked him about.
test('For good approves the file named: sent again after the session moves, a relative path is refused again', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const refused = refusalOf(await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- Ask before merging.\n' }))
  w.at.cwd = '/Users/dan/Apps/other'
  await askDan($, w, refused, 'For good', '~/Apps/slate/CLAUDE.md')
  expect(refusalOf(await call($, { tool: 'Write', file_path: 'CLAUDE.md', content: '- Ask before merging.\n' }))).toContain(ASKS)
  expect(w.ran).toEqual([])
  expect((await call($, { tool: 'Write', file_path: `${CWD}/CLAUDE.md`, content: '- Ask before merging.\n' })).deny).toBeUndefined()
  expect(w.ran.map(x => x.input.file_path)).toEqual([`${CWD}/CLAUDE.md`])
})

test('a Bash save approved in one folder is refused again when it is sent from another', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const command = "cat >> CLAUDE.md <<'EOF'\n- Never merge on Fridays.\nEOF"
  await askDan($, w, refusalOf(await call($, { tool: 'Bash', command })), 'For good', '~/Apps/slate/CLAUDE.md')
  w.at.cwd = '/Users/dan/Apps/other'
  expect(refusalOf(await call($, { tool: 'Bash', command }))).toContain(ASKS)
  expect(w.ran).toEqual([])
  w.at.cwd = CWD
  expect((await call($, { tool: 'Bash', command })).deny).toBeUndefined()
  expect(w.ran.length).toBe(1)
})

// L50, lessons review of #738: an approval read back with no time compared false against the clock,
// so it never lapsed; and timing it asked $.clock.after for a wait that is not a number, which throws.
test('an approval whose time is not a number stands for nothing: its save is refused, and timing it again never throws', withKit, async ($, on) => {
  on('clock.now', () => ({ value: undefined }) as never)
  on('clock.after', () => {
    throw new Error('the mod reloaded')
  })
  const w = world(on, { auto: true, ownClock: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await askDan($, w, refusalOf(await call($, input)), 'For good', '~/Apps/slate/AGENTS.md')
  await ($ as unknown as { session: { start: (x: never) => Promise<unknown> } }).session.start({ cwd: CWD, surface: 'terminal', isInteractive: true } as never)
  expect(w.toasts.join('\n')).not.toContain('could not be timed')
  expect(refusalOf(await call($, input))).toContain(ASKS)
  expect(w.toasts.join('\n')).toContain('The For good you gave for saving to ~/Apps/slate/AGENTS.md lapsed')
  expect(w.ran).toEqual([])
})

// L523, L567: an approval nobody uses must not stand open, and one past its time is refused where it
// is used, said plainly both ways.
test('an approval Claude does not use within its time lapses: Dan and Claude are told, and the call is refused again', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await askDan($, w, refusalOf(await call($, input)), 'For good', '~/Apps/slate/AGENTS.md')
  await w.clock.advance(APPROVAL_MS - 1)
  expect(w.toasts.join('\n')).not.toContain('lapsed')
  await w.clock.advance(1)
  expect(w.toasts.join('\n')).toContain('The For good you gave for saving to ~/Apps/slate/AGENTS.md lapsed after 10 minutes unused')
  expect(notesOf(w)).toContain("Dan's For good on saving this to ~/Apps/slate/AGENTS.md lapsed after 10 minutes unused")
  expect(refusalOf(await call($, input))).toContain(ASKS)
  expect(w.ran).toEqual([])
})

test('an approval past its time is refused where it is used even when nothing announced its lapse (a reload drops the timer)', withKit, async ($, on) => {
  let now = 0
  on('clock.now', () => ({ value: now }) as never)
  on('clock.after', () => {
    throw new Error('the mod reloaded')
  })
  const w = world(on, { auto: true, ownClock: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  const answered = await askDan($, w, refusalOf(await call($, input)), 'For good', '~/Apps/slate/AGENTS.md')
  // A timer that cannot be set never stops Claude being told to send it again.
  expect(contextOf(answered)).toContain('Send the same Write call again now')
  now = APPROVAL_MS
  const late = refusalOf(await call($, input))
  expect(late).toContain(ASKS)
  expect(late).toContain('lapsed')
  expect(w.toasts.join('\n')).toContain('The For good you gave for saving to ~/Apps/slate/AGENTS.md lapsed after 10 minutes unused')
  expect(w.ran).toEqual([])
})

// #764: an approved save sent again but refused by another guard before this mod's check never used
// its approval, which then lapsed as "unused" though Claude did send it (L11). Dan is told at once
// that it did not go through, and the lapse says why, never that it went unused.
test('an approved save another guard refuses when sent again is said as not going through, never as unused', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await askDan($, w, refusalOf(await call($, input)), 'For good', '~/Apps/slate/AGENTS.md')
  w.files['/gate/refuses'] = '1'
  const r = await call($, input)
  expect(refusalOf(r)).toBe('Blocked: another session is editing this file.')
  expect(w.ran).toEqual([])
  expect(w.toasts.join('\n')).toContain('Not saved to ~/Apps/slate/AGENTS.md: Blocked: another session is editing this file.')
  await w.clock.advance(APPROVAL_MS)
  const said = [w.toasts.join('\n'), notesOf(w)].join('\n')
  expect(said).not.toContain('unused')
  expect(w.toasts.join('\n')).toContain('The For good you gave for saving to ~/Apps/slate/AGENTS.md lapsed after 10 minutes: Claude sent the save, but it was refused before it was saved (Blocked: another session is editing this file.)')
  expect(notesOf(w)).toContain("Dan's For good on saving this to ~/Apps/slate/AGENTS.md lapsed after 10 minutes: the save you sent was refused before it was saved (Blocked: another session is editing this file.)")
})

// update() runs its callback again when another write lands between its read and its write. If the
// approval is gone by the second run (lapsed, used), a match the first run recorded must not stand,
// or Dan is told about a save no approval covers (the lessons review of #806).
test('a refused resend whose approval is gone by the time the write lands raises no toast for it', withKit, async ($, on) => {
  // Once armed, the first conditional write of the approvals misses, because another write emptied
  // them in between: update reads again and runs its callback over no approval at all.
  let armed = false
  let raced = false
  on('state.set', async ($$, e, next) => {
    const x = e as unknown as { ref?: { key?: string }; key?: string; options?: { ifVersion?: number }; ifVersion?: number }
    const key = x.ref?.key ?? x.key
    const conditional = (x.options?.ifVersion ?? x.ifVersion) !== undefined
    if (armed && !raced && key === 'approvals' && conditional) {
      raced = true
      const { options: _o, ifVersion: _i, ...plain } = x as Record<string, unknown>
      await next({ ...plain, value: [] } as never)
      return { value: { isSet: false, version: -1 } } as never
    }
    return next(e)
  })
  const w = world(on, { auto: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await askDan($, w, refusalOf(await call($, input)), 'For good', '~/Apps/slate/AGENTS.md')
  w.files['/gate/refuses'] = '1'
  armed = true
  await call($, input)
  expect(raced).toBe(true)
  expect(w.toasts.join('\n')).not.toContain('Not saved to ~/Apps/slate/AGENTS.md')
})

// And when the guard lets it through on a later send inside the time, it is saved as approved.
test('an approved save refused once by another guard is still saved when sent again in time', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await askDan($, w, refusalOf(await call($, input)), 'For good', '~/Apps/slate/AGENTS.md')
  w.files['/gate/refuses'] = '1'
  await call($, input)
  delete w.files['/gate/refuses']
  const again = await call($, input)
  expect(again.deny).toBeUndefined()
  expect(w.ran.map(x => x.tool)).toEqual(['Write'])
  expect(contextOf(again)).toContain('Saved to ~/Apps/slate/AGENTS.md, as Dan answered For good.')
})

// And where a lapsed approval is found as the call arrives (a reload dropped its timer), the same:
// sent and refused is never called unused, to Dan or to Claude (#764, L11).
test('an approval refused once and found past its time where it is used is said as refused, never as unused', withKit, async ($, on) => {
  let now = 0
  on('clock.now', () => ({ value: now }) as never)
  on('clock.after', () => {
    throw new Error('the mod reloaded')
  })
  const w = world(on, { auto: true, ownClock: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await askDan($, w, refusalOf(await call($, input)), 'For good', '~/Apps/slate/AGENTS.md')
  w.files['/gate/refuses'] = '1'
  await call($, input)
  delete w.files['/gate/refuses']
  now = APPROVAL_MS
  const late = refusalOf(await call($, input))
  expect(late).toContain(ASKS)
  expect(late).toContain('the save you sent before was refused (Blocked: another session is editing this file.)')
  expect(late).not.toContain('unused')
  expect(w.toasts.join('\n')).not.toContain('unused')
  // Claude did send it again here, late: the lapse never says it was not sent (lessons review of #806).
  expect(w.toasts.join('\n')).not.toContain('not sent again')
  expect(w.toasts.join('\n')).toContain('and it was not saved within that time')
  expect(w.toasts.join('\n')).toContain('Claude sent the save, but it was refused before it was saved (Blocked: another session is editing this file.)')
  expect(w.ran).toEqual([])
})

test('For good whose save then fails says so to Dan, and never that it was saved', withKit, async ($, on) => {
  const w = world(on, { failWrites: true })
  const input = { tool: 'Edit', file_path: 'CLAUDE.md', old_string: 'gone', new_string: 'gone\n- rule' }
  await askDan($, w, refusalOf(await call($, input)), 'For good', '~/Apps/slate/CLAUDE.md')
  const r = await call($, input)
  expect(r.isError).toBe(true)
  expect(w.toasts.join('\n')).toContain('Not saved to ~/Apps/slate/CLAUDE.md: String to replace not found in file.')
  expect(contextOf(r)).not.toContain('Saved to')
})

test('an approval the session ends before Claude uses is dropped, and Dan is told it was never used', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await askDan($, w, refusalOf(await call($, input)), 'For good', '~/Apps/slate/AGENTS.md')
  await ($ as unknown as { session: { end: (x: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'clear' } as never)
  expect(w.toasts.join('\n')).toContain('The For good you gave for saving to ~/Apps/slate/AGENTS.md was never used before the session ended')
  expect(refusalOf(await call($, input))).toContain(ASKS)
  expect(w.ran).toEqual([])
})

// The lessons review of #806: one Claude sent that another guard refused is not "never used" at
// session end either (#764, L11).
test('an approval whose save another guard refused is said as refused, never as unused, when the session ends', withKit, async ($, on) => {
  const w = world(on, { auto: true })
  const input = { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }
  await askDan($, w, refusalOf(await call($, input)), 'For good', '~/Apps/slate/AGENTS.md')
  w.files['/gate/refuses'] = '1'
  await call($, input)
  await ($ as unknown as { session: { end: (x: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'clear' } as never)
  const said = w.toasts.join('\n')
  expect(said).not.toContain('never used')
  expect(said).toContain('The For good you gave for saving to ~/Apps/slate/AGENTS.md ended with the session: Claude sent the save, but it was refused before it was saved (Blocked: another session is editing this file.)')
})

test('Just this session writes nothing and holds the rule, in Claude\'s plain words, in the system prompt through a compaction until the session ends', withKit, async ($, on) => {
  const w = world(on)
  const refused = refusalOf(await call($, { tool: 'Write', file_path: `${HOME}/.claude/projects/p/memory/note.md`, content: 'Skip the screenshots today.\n' }))
  const answered = await askDan($, w, refused, 'Just this session', '~/.claude/projects/p/memory/note.md', 'skip the screenshots')
  expect(w.ran).toEqual([])
  expect(contextOf(answered)).toContain('Just this session')
  const section = async () => (await ($ as unknown as { prompt: { section: (x: never) => Promise<{ text: string | null }> } }).prompt.section({ name: 'memory', text: 'core memory' } as never)).text
  expect(await section()).toContain('core memory')
  expect(await section()).toContain('- skip the screenshots')
  await ($ as unknown as { session: { compact: (x: never) => Promise<unknown> } }).session.compact({ messages: [{ role: 'user', text: 'hi', toolUses: [] }] } as never)
  expect(await section()).toContain('- skip the screenshots')
  await ($ as unknown as { session: { end: (x: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'other' } as never)
  expect(await section()).toBe('core memory')
})

test('Not at all writes nothing and tells Claude not to save it', withKit, async ($, on) => {
  const w = world(on)
  const input = { tool: 'Write', file_path: 'CLAUDE.md', content: '- Not a standing preference.\n' }
  const answered = await askDan($, w, refusalOf(await call($, input)), 'Not at all', '~/Apps/slate/CLAUDE.md')
  expect(w.ran).toEqual([])
  expect(contextOf(answered)).toContain('Not at all')
  expect(contextOf(answered)).toContain('nothing was saved')
  expect(refusalOf(await call($, input))).toContain(ASKS)
})

test('a save the mod cannot judge is refused, never let through: a failing hook fails closed', withKit, async ($, on) => {
  const w = world(on, { cwdFails: true })
  const r = await call($, { tool: 'Write', file_path: '/anywhere/CLAUDE.md', content: '- rule\n' })
  expect(w.ran).toEqual([])
  expect(refusalOf(r)).toContain('could not check')
})

test('a question that is not about a save is left to Claude Code untouched', withKit, async ($, on) => {
  const w = world(on)
  w.dialog.answer = 'A'
  const q = { question: 'Which first?', header: 'Next', options: [{ label: 'A', description: 'a' }, { label: 'B', description: 'b' }], multiSelect: false }
  const r = await call($, { tool: 'AskUserQuestion', questions: [q], metadata: { source: 'next-issue' } })
  expect(r.deny).toBeUndefined()
  expect(w.asked[0].questions[0]).toEqual(q)
  expect(contextOf(r)).toBe('')
})

// Lessons review of #783: the hook's catch covered every question, so a failure of a question that
// had nothing to do with a save came back as "Not saved: Ask before saving could not read Dan's
// answer". It is that question's own failure, untouched.
test("a failure of a question that is not about a save is never reported as a save's", withKit, async ($, on) => {
  const w = world(on)
  w.dialog.fails = true
  const q = { question: 'Which first?', header: 'Next', options: [{ label: 'A', description: 'a' }, { label: 'B', description: 'b' }], multiSelect: false }
  let out: string
  try {
    out = JSON.stringify(await call($, { tool: 'AskUserQuestion', questions: [q], metadata: { source: 'next-issue' } }))
  } catch (err) {
    out = String((err as Error).message ?? err)
  }
  // The test kit reports an engine handler that throws as its own error, whatever it said.
  expect(out).not.toContain('Ask before saving')
  expect(out).not.toContain('Not saved')
  // One about a save that fails is still refused, saying so.
  const refused = refusalOf(await call($, { tool: 'Write', file_path: 'AGENTS.md', content: '- Use pnpm.\n' }))
  const r = await askDan($, w, refused, 'For good', '~/Apps/slate/AGENTS.md')
  expect(r.deny).toContain("Not saved: Ask before saving could not read Dan's answer")
  expect(w.ran).toEqual([])
})
