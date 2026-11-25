import { expect, mock, type Engine } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { pipeline } from './mod-kit/hooks/commands.ts'
import { isDans } from './mod-kit/hooks/origin.ts'
import { pythonText } from './mod-kit/hooks/code.ts'
import { reasonOf, standInCore } from './mod-kit/tests/core.ts'

// The fix round on pull request #3493 (issue #3491), pinned as the whole mod behaves. A removal of
// lasting memory standing after a quote bash and zsh read differently (`$$'a\'b'`), or after a
// `$'...'` string that never closes, is a command mod-kit's reader marks unread: it cannot say what
// the shell runs from that quote on. The mod refuses the call and tells Claude to ask Dan, but in
// the words of a SAVE ("Not saved yet: this may write lasting memory"), never the removal question
// ("Not deleted yet"): its removal rule takes candidates only from commands the reader could read.
// This pins that, so a change either way is seen. The wording itself belongs to the mod's hooks,
// which pull request #3485 is changing, so nothing here asks for it to change.
//
// The harness is a cut of register.test.tsx's (that file's comments say why each part is there):
// mod-kit stood in by its byte for byte copy under tests/mod-kit, the files of the world, and
// Claude Code's core deciding whether a call runs. Kept apart so this file does not touch that one.

const HOME = `${'/Users'}/dan`
const CWD = `${'/Users'}/dan/Apps/slate`
const MEMDIR = `${HOME}/.claude/projects/p/memory`
const SHOWN = '~/.claude/projects/p/memory'
const BS = '\\'
const ASKS = 'Ask him now with AskUserQuestion'
const NOT_DELETED = 'Not deleted yet'
const NOT_SAVED = `Not saved yet: this may write lasting memory (${SHOWN})`

const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ask = async (member: string, input: unknown) => {
        const r = await built.process.run(['__modkit', member, JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return JSON.parse(r.stdout)
      }
      const modkit = {
        writes: async (input: { command: string; cwd: string; home: string }) => ask('writes', input),
        pipeline: async (input: { command: string }) => ask('pipeline', input),
        pythonText: async (input: { code: string }) => ask('pythonText', input),
        isDans: async (input: { origin: unknown }) => (await ask('isDans', input)) as boolean,
        workingTree: async () => null,
        press: async () => ({ isAnswered: false }),
        clickable: async () => true,
        // The kit's other members, which this test never reaches: each refuses by name if one ever is.
        repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
        gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
        mergeHelper: async () => { throw new Error("mod-kit's mergeHelper is not stood in by these tests") },
        goal: async () => { throw new Error("mod-kit's goal is not stood in by these tests") },
        ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
        linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
        branch: async () => { throw new Error("mod-kit's branch is not stood in by these tests") },
        blocked: async () => { throw new Error("mod-kit's blocked is not stood in by these tests") },
        card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
        commands: async () => { throw new Error("mod-kit's commands is not stood in by these tests") },
        git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
        login: async () => { throw new Error("mod-kit's login is not stood in by these tests") },
        account: async () => { throw new Error("mod-kit's account is not stood in by these tests") },
        bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
        clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
        pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
        clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
        screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
        typedAnswer: async () => { throw new Error("mod-kit's typedAnswer is not stood in by these tests") },
        hold: async () => { throw new Error("mod-kit's hold is not stood in by these tests") },
        release: async () => { throw new Error("mod-kit's release is not stood in by these tests") },
      }
      return { ...built, modkit }
    })
  },
}
// Claude Code's security default, standing in as register.test.tsx's does (#875).
const secDefault: { name: string; tier: 'prepend'; register: Register } = {
  name: 'sec-default-stand-in',
  tier: 'prepend',
  register: on => {
    on('classic.*', ($, e, next) => next.to(e, 'append'))
  },
}
const withKit = { plugins: [secDefault, modKit] }

const done = (stdout: string, exitCode = 0, stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } }) as never
// The Mac beneath the mod: the memory folder holding two files, no repository, and the tools, which
// record each call that runs.
const world = (engine: Engine, on: On, files: Record<string, string>) => {
  const ran: string[] = []
  mock.clock(on)
  mock.env(on, { HOME })
  on('process.run', ($, e) => {
    const [first, member, raw] = e.argv.map(String)
    if (first === '__modkit') {
      const input = JSON.parse(raw ?? '{}')
      if (member === 'writes') return done(JSON.stringify(commandWrites(input.command, input.cwd, input.home)))
      if (member === 'pipeline') return done(JSON.stringify(pipeline(input.command)))
      if (member === 'pythonText') return done(JSON.stringify(pythonText(input.code)))
      if (member === 'isDans') return done(JSON.stringify(isDans(input.origin)))
    }
    if (first === 'git') return done('', 128, 'fatal: not a git repository (or any of the parent directories): .git')
    if (first === '/usr/bin/printenv') return done(member === 'HOME' ? HOME : '', member === 'HOME' ? 0 : 1)
    throw new Error(`unexpected command: ${e.argv.join(' ')}`)
  })
  on('session.cwd', () => ({ value: CWD }) as never)
  on('agent.list', () => ({ value: [] }) as never)
  const under = (path: string) => Object.keys(files).filter(f => f.startsWith(`${path.replace(/\/$/, '')}/`))
  on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined || under(e.path).length > 0 }) as never)
  on('fs.list', ($, e) => {
    const at = e.path.replace(/\/$/, '')
    const names = [...new Set(under(at).map(f => f.slice(at.length + 1).split('/')[0] as string))]
    return { value: names.map(name => ({ name, kind: files[`${at}/${name}`] !== undefined ? 'file' : 'dir' })) } as never
  })
  on('fs.stat', ($, e) => {
    if (files[e.path] === undefined && under(e.path).length) return { value: { kind: 'dir', size: 0, mtimeMs: 0, isLink: false } } as never
    if (files[e.path] === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: { kind: 'file', size: 1, mtimeMs: 0, isLink: false } } as never
  })
  on('fs.read', ($, e) => {
    const t = files[e.path]
    if (t === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: t } as never
  })
  const core = standInCore(engine, on)
  on('tool.call', async ($, e) => {
    const c = await core(e)
    if ('refused' in c) return c.refused as never
    ran.push(String((c.call.input as { command?: unknown }).command ?? c.call.tool))
    return { result: 'written', text: 'written' } as never
  })
  on('ui.invalidate', () => ({ value: undefined }) as never)
  on('ui.toast', () => ({ value: undefined }) as never)
  on('ui.log', () => ({ value: undefined }) as never)
  on('prompt.section', ($, e) => ({ text: e.text }))
  on('prompt.submit', ($, e) => ({ text: e.text }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }) as never)
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  return { ran }
}

type Result = { deny?: string; isError?: boolean }
let calls = 0
const refusalOf = async ($: unknown, command: string) => {
  const r = (await ($ as { tool: { call: (e: never) => Promise<unknown> } }).tool.call({ tool_use_id: `t${++calls}`, tool: 'Bash', command } as never)) as Result
  return r.deny !== undefined || r.isError ? reasonOf(r as never, 'ask-before-saving') : ''
}
// What the refusal is: the removal question, the save question, or something else, cut short.
const kindOf = (why: string) =>
  why.startsWith(NOT_DELETED) && why.includes(SHOWN) && why.includes(ASKS) ? 'asked as a removal' : why.startsWith(NOT_SAVED) && why.includes(ASKS) ? 'asked as a save' : why.slice(0, 160)

test('#3493: a removal of lasting memory read past a quote the reader cannot settle is refused and asked about as a save, not as a removal', withKit, async ($, on) => {
  const w = world($, on, { [`${MEMDIR}/MEMORY.md`]: '- [note](note.md)\n', [`${MEMDIR}/note.md`]: 'a note\n' })
  const got: [string, string][] = []
  for (const command of [
    // The control: the removal typed alone is read whole and asked about as one.
    `rm -rf ${SHOWN}`,
    // bash reads a plain quote and runs none of the removal; zsh reads a $'...' string and runs it.
    `x=$$'a${BS}'b'\nrm -rf ${SHOWN} # it's`,
    `p1 $$'a${BS}'b' ; rm -rf ${SHOWN} # it's`,
    // A $'...' string that never closes: bash and zsh run none of it, dash would run the removal.
    `echo $'a${BS}' > x.txt ; rm -rf ${SHOWN} ; echo 'b'`,
  ])
    got.push([command, kindOf(await refusalOf($, command))])
  expect(got).toEqual([
    [`rm -rf ${SHOWN}`, 'asked as a removal'],
    [`x=$$'a${BS}'b'\nrm -rf ${SHOWN} # it's`, 'asked as a save'],
    [`p1 $$'a${BS}'b' ; rm -rf ${SHOWN} # it's`, 'asked as a save'],
    [`echo $'a${BS}' > x.txt ; rm -rf ${SHOWN} ; echo 'b'`, 'asked as a save'],
  ])
  expect(w.ran).toEqual([])
})
