import { mock, type Engine } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { commandWrites, pipelineIn } from './mod-kit/hooks/writes.ts'
import { git as gitCommand, pipeline } from './mod-kit/hooks/commands.ts'
import { readBranch, type Run } from './mod-kit/hooks/branch.ts'
import { githubRepo, repoName } from './mod-kit/hooks/repo.ts'
import { type TypedAnswer, typedAnswerText, typedToast } from './mod-kit/hooks/typed.ts'
import { reasonOf, standInCore } from './mod-kit/tests/core.ts'

// The stand-in Mac and Claude Code every test file of this mod runs the guard in: mod-kit standing
// in, the disk, git, the mod's store and Claude Code's question dialog. A test file imports what it
// needs from here, so each file drives the one world.

// mod-kit, standing in: a mod cannot import another mod's files. What a command writes is read by
// mod-kit's own reader, and where a checkout stands by its branch reader (#978) and the project's
// name by its repo reader (#951), each a byte for byte copy under tests/mod-kit that
// tools/check-mod-shared-parts.sh holds to mod-kit's, asked through the world (`__modkit`). The checkouts: /w/slate (the project's
// main working tree), /w/slate-wt (a linked worktree of it, where a subagent works), /w/slate-wt2
// (another linked worktree of it, another subagent's), and /w/other.
// A folder under /w/locked is one the disk cannot answer for.
export const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ask = async (method: string, input: unknown) => {
        const r = await built.process.run(['__modkit', method, JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return JSON.parse(r.stdout)
      }
      // #2726: the first N reads of what a command writes fail as every hook in flight does when Claude
      // Code replaces its hooks worker after a missed heartbeat, in the engine's own words, N named by
      // a plugin in the fold, kit-stalls-<N>. A stand-in for one of the engine's own nouns that throws
      // never reaches the hook as written, so the failure is thrown here.
      let stalls = Number(e.plugins.map(p => /^kit-stalls-(\d+)$/.exec(p)?.[1]).find(n => n !== undefined) ?? 0)
      const modkit = {
        writes: async (input: { command: string; cwd: string; home: string }) => {
          if (stalls > 0) {
            stalls--
            throw new Error('no answer to a heartbeat within 5000ms: the hooks worker is wedged (a hook spinning without yielding)')
          }
          return ask('writes', input)
        },
        pipeline: async (input: { command: string }) => ask('pipeline', input),
        workingTree: async ({ path }: { path: string }) => {
          if (path.startsWith('/w/locked/')) throw new Error('EACCES: /w/locked')
          // #2792: and three throwaway copies of slate, each a checkout of its own: in this session's
          // notes folder, in its scratchpad, and in a folder shaped like the notes folder inside slate.
          const copies = ['/Users' + '/dan/.claude/state/session-notes/-w-slate/s1/review/slate-copy', '/private/tmp/claude-501/-w-slate/s1/scratchpad/slate-copy', '/w/slate/.claude/state/session-notes/-w-slate/s1/review/slate-copy']
          for (const root of [...copies, '/w/slate-wt2', '/w/slate-wt', '/w/slate', '/w/other', '/w/tests/shop']) if (path === root || path.startsWith(root + '/')) return root
          return null
        },
        branch: async (input: { path: string }) => ask('branch', input),
        repo: async (input: { root?: string | null; remote: string | null }) => ask('repo', input),
        blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
        // The kit's other members, which these tests never reach: each refuses by name if one ever is.
        card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
        commands: async () => { throw new Error("mod-kit's commands is not stood in by these tests") },
        git: async (input: { words: string[]; env?: readonly string[] }) => ask('git', input),
        gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
        mergeHelper: async () => { throw new Error("mod-kit's mergeHelper is not stood in by these tests") },
        goal: async () => { throw new Error("mod-kit's goal is not stood in by these tests") },
        ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
        linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
        bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
        clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
        pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
        clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
        screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
        press: async () => ({ isAnswered: false }),
        clickable: async () => true,
        isDans: async () => { throw new Error("mod-kit's isDans is not stood in by these tests") },
        pythonText: async () => { throw new Error("mod-kit's pythonText is not stood in by these tests") },
        login: async () => { throw new Error("mod-kit's login is not stood in by these tests") },
        account: async () => { throw new Error("mod-kit's account is not stood in by these tests") },
        // #1145: a typed answer, said with the copy. One typed as BREAKS stands for a mod-kit loaded
        // before it had the member (a reload can leave one, standing rule 5).
        typedAnswer: async (input: { guard: string; typed: string; still: string; again: string }) => {
          if (input.typed === 'BREAKS') throw new TypeError('$.modkit.typedAnswer is not a function')
          const said = (await ask('typedAnswer', input)) as { toast: string; text: string }
          await built.ui.toast(said.toast)
          return said.text
        },
        hold: async () => { throw new Error("mod-kit's hold is not stood in by these tests") },
        release: async () => { throw new Error("mod-kit's release is not stood in by these tests") },
      }
      // #1299: a mod-kit loaded before it had a member, named by a plugin in the fold,
      // kit-lacks-<member in kebab case>, since this plugin runs apart from the test's module; the
      // call site then throws in the mod itself, as the runtime words it.
      for (const p of e.plugins) {
        const lacks = /^kit-lacks-([a-z-]+)$/.exec(p)?.[1]?.replace(/-([a-z])/g, (_m: string, c: string) => c.toUpperCase())
        if (lacks) delete (modkit as Record<string, unknown>)[lacks]
      }
      return { ...built, modkit }
    })
  },
}
// A stand-in for Claude Code's built-in security default (#875), loaded in every test so none can
// pass on a hook that never runs: it sends every classic hook event past the tier mods load in.
export const secDefault: { name: string; tier: 'prepend'; register: Register } = {
  name: 'sec-default-stand-in',
  tier: 'prepend',
  register: on => {
    on('classic.*', ($, e, next) => next.to(e, 'append'))
  },
}
export const withKit = { plugins: [secDefault, modKit] }
// #2726: the same, with the first n reads of what a command writes failing as a lost hooks worker fails a hook.
export const withStalls = (n: number) => ({ plugins: [secDefault, modKit, { name: `kit-stalls-${n}`, register: (() => undefined) as Register }] })
// #1299: the same, with a mod-kit loaded before it had typedAnswer.
export const withOldKit = { plugins: [secDefault, modKit, { name: 'kit-lacks-typed-answer', register: (() => undefined) as Register }] }

export const HOME = `${'/Users'}/dan`
// The moment every test's clock starts at.
export const T0 = Date.UTC(2026, 9, 9, 15, 0, 0)
export const STORE = `${HOME}/.claude/plugins/store/design-round-guard_inline-ab12cd34ef56.json`
// #2792: three throwaway copies of slate, each a checkout of its own, as the stand-in's walk finds
// them: in this session's notes folder, in its scratchpad, and in a folder shaped like the notes
// folder inside slate itself.
export const NOTES_FOLDER = `${HOME}/.claude/state/session-notes/-w-slate/s1`
export const COPY_IN_NOTES = `${NOTES_FOLDER}/review/slate-copy`
export const COPY_IN_SCRATCH = '/private/tmp/claude-501/-w-slate/s1/scratchpad/slate-copy'
export const COPY_IN_SLATE = '/w/slate/.claude/state/session-notes/-w-slate/s1/review/slate-copy'
export const COPIES = [COPY_IN_NOTES, COPY_IN_SCRATCH, COPY_IN_SLATE]

export type Dialog = { answer?: string; afk?: boolean }
export type Asked = { questions: { question: string; header: string; options: { label: string; description?: string }[]; multiSelect: boolean }[]; metadata?: Record<string, unknown> }
// `blobs`: what git holds, by the checkout and the `<from>:<path>` that reads it (#1158).
// `env`: the variables Claude Code runs with beside HOME (CLAUDE_CODE_TMPDIR, #1191).
// `fifos`: paths there that are no regular file (a fifo, a link to a device). A read of one, or of
// any device, never answers, as the real one does (#1765), and resolves `readAttempted`.
// `stdinLinks`: links to /dev/stdin, read as `fifos` are, whose stat with links followed THROWS
// EBADF, as Claude Code 2.1.312's does (#1814, measured headless).
export type Init = { cwd?: string; files?: Record<string, string>; fifos?: string[]; stdinLinks?: string[]; agents?: string[]; blobs?: Record<string, string>; env?: Record<string, string> }
export const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never

// The Mac and Claude Code beneath the mod: each checkout's branch (a test may change it, or make it
// unreadable), git's answers, the disk, the mod's store, Claude Code's own question dialog (answered
// as `dialog` says), every call that ran, every card drawn and every git command asked.
export const world = (engine: Engine, on: On, init: Init = {}) => {
  const files: Record<string, string> = { ...(init.files ?? {}) }
  const branches: Record<string, string> = { '/w/slate': '978-design-round-guard', '/w/slate-wt': '978-design-round-guard', '/w/slate-wt2': '978-design-round-guard', '/w/other': '55-other', '/w/tests/shop': '77-shop', ...Object.fromEntries(COPIES.map(c => [c, 'main'])) }
  const store: Record<string, unknown> = {}
  // `shell`: what a Bash command writes when it runs, by path (#1296); `writeFails`: the paths
  // $.fs.write refuses; `afterWrite`: run once a write lands (another writer arriving, say);
  // `rmFails`: rm reports failure; `readFailsAfterRun`: a path that cannot be read once a command ran.
  const ctl: {
    storeGetFails: boolean
    storeSetFails: boolean
    settingsRefuse: boolean
    existsFails?: boolean
    listFails?: boolean
    storeSetFailKey?: string
    hold?: Promise<void>
    reached?: () => void
    gitBlob?: 'throws' | 'truncated'
    shell?: Record<string, string>
    writeFails?: (path: string) => boolean
    afterWrite?: (path: string) => void
    rmFails?: boolean
    // #1933: the paths a Bash command takes away when it runs; the files git has never tracked (every
    // other path is tracked, put on the disk or not); and git's ls-files failing to run.
    gone?: string[]
    untracked?: string[]
    lsFilesFails?: boolean
    readFailsAfterRun?: string
    unreadable?: string
    branchFails?: boolean
    // #3279: the checkout holds no record of which branch is the remote's default.
    noDefault?: boolean
    // design_file.py --sealed (#1524): the texts it reads as a settled design exactly as sealed, and
    // whether it cannot be run at all.
    sealed?: string[]
    sealFails?: boolean
    sealSilent?: boolean
    // #3620: what mod-kit's write reader answers, changed before the guard is given it (a mark
    // taken off a word, or put there as something other than the reader's own `true`).
    reading?: (reading: ReturnType<typeof commandWrites>) => unknown
  } = { storeGetFails: false, storeSetFails: false, settingsRefuse: false }
  // Each time the guard asked design_file.py whether a text is sealed: how it ran it, and the text.
  const sealChecks: { argv: string[]; stdin: string }[] = []
  const writes: string[] = []
  const removed: string[] = []
  const blobs: Record<string, string> = { ...(init.blobs ?? {}) }
  // What git answers the questions the guard asks before a move (#3279), by the checkout and the
  // words after it (`/w/slate rev-parse --verify --quiet main^{commit}`): what it prints, or `fails`
  // with what it says. A question a test did not answer is a name git does not know: silent, exit 1,
  // for rev-parse --verify --quiet, nothing listed for for-each-ref, and exit 128 for the rest.
  const gitSays: Record<string, string | { fails: string } | 'throws' | 'truncated'> = {}
  const ran: { tool: string; input: Record<string, unknown> }[] = []
  const asked: Asked[] = []
  const dialog: Dialog = {}
  const cards: Record<string, unknown>[] = []
  const gitRuns: string[] = []
  const reads: string[] = []
  const storeGets: string[] = []
  const toasts: string[] = []
  // Every line the guard writes to its log, and where to (#2288).
  const logged: { text: string; to?: string }[] = []
  const at ={ cwd: init.cwd ?? '/w/slate', session: 's1' }
  const clock = mock.clock(on, { now: T0 })
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? HOME : init.env?.[e.name] }) as never)
  on('session.cwd', () => ({ value: at.cwd }) as never)
  on('session.id', () => ({ value: at.session }) as never)
  on('agent.list', () => ({ value: (init.agents ?? []).map(id => ({ id, description: 'a task', agentType: 'general-purpose' })) }) as never)
  // git, as mod-kit's branch reader asks it in a checkout.
  const git: Run = async argv => {
    if (argv[0] !== 'git' || argv[1] !== '-C') throw new Error(`unexpected command: ${argv.join(' ')}`)
    gitRuns.push(argv.join(' '))
    const tree = String(argv[2])
    const sub = argv.slice(3).join(' ')
    const branch = branches[tree]
    if (sub === 'branch --show-current') {
      if (branch === undefined || branch === 'UNREADABLE') return { exitCode: 128, stdout: '', stderr: 'fatal: not a git repository' }
      return { exitCode: 0, stdout: `${branch}\n`, stderr: '' }
    }
    if (sub === 'worktree list --porcelain') return { exitCode: 0, stdout: `worktree ${tree === '/w/slate-wt' || tree === '/w/slate-wt2' ? '/w/slate' : tree}\nHEAD abc\nbranch refs/heads/main\n\n`, stderr: '' }
    // git's own words and exit code where a clone never recorded it, measured with git 2.51.1 for #3279.
    if (sub === 'symbolic-ref --short refs/remotes/origin/HEAD') return ctl.noDefault ? { exitCode: 128, stdout: '', stderr: 'fatal: ref refs/remotes/origin/HEAD is not a symbolic ref\n' } : { exitCode: 0, stdout: 'origin/main\n', stderr: '' }
    throw new Error(`unexpected git: ${argv.join(' ')}`)
  }
  on('process.run', async ($, e) => {
    const [cmd, ...args] = e.argv.map(String)
    // git reading what a checkout or restore puts back (#1158): `git -C <tree> cat-file blob <from>:<path>`.
    if (cmd === 'git' && args[0] === '-C' && args[2] === 'cat-file' && args[3] === 'blob' && args.length === 5) {
      gitRuns.push(e.argv.join(' '))
      if (ctl.gitBlob === 'throws') throw new Error('spawn git ENOENT')
      const text = blobs[`${args[1]} ${args[4]}`]
      if (text === undefined) {
        // A path the index holds, but not at the stage asked for (a file a merge left unmerged has
        // none at stage 0), in git's own words, measured on a real conflict for #2704.
        const staged = /^:(?:([0-3]):)?(.*)$/.exec(String(args[4]))
        const held = staged ? ['1', '2', '3', '0'].find(n => blobs[`${args[1]} :${n === '0' ? '' : `${n}:`}${staged[2]}`] !== undefined) : undefined
        const stderr = staged && held !== undefined ? `fatal: path '${staged[2]}' is in the index, but not at stage ${staged[1] ?? '0'}\nhint: Did you mean ':${held}:${staged[2]}'?\n` : `fatal: path '${args[4]}' does not exist\n`
        return { value: { exitCode: 128, stdout: '', stderr, isStdoutTruncated: false, isStderrTruncated: false } } as never
      }
      return { value: { exitCode: 0, stdout: text, stderr: '', isStdoutTruncated: ctl.gitBlob === 'truncated', isStderrTruncated: false } } as never
    }
    // #3337: asked with a repository or working folder named apart, those options stand between the
    // folder and the question (`git -C <folder> --git-dir=<repository> --work-tree=<folder> <question>`),
    // and the answer is kept under the same words.
    const question = cmd === 'git' && args[0] === '-C' ? String(args.slice(2).find(a => !/^--(?:git-dir|work-tree)=/.test(a))) : ''
    if (['rev-parse', 'diff', 'log', 'for-each-ref', 'ls-tree', 'merge-base', 'rev-list'].includes(question)) {
      gitRuns.push(e.argv.join(' '))
      const said = gitSays[`${args[1]} ${args.slice(2).join(' ')}`]
      if (said === 'throws') throw new Error('spawn git ENOENT')
      if (said === 'truncated') return { value: { exitCode: 0, stdout: 'M\0', stderr: '', isStdoutTruncated: true, isStderrTruncated: false } } as never
      if (typeof said === 'string') return ok(said)
      if (said !== undefined) return { value: { exitCode: 128, stdout: '', stderr: `${said.fails}\n`, isStdoutTruncated: false, isStderrTruncated: false } } as never
      if (question === 'for-each-ref') return ok('')
      return { value: { exitCode: question === 'rev-parse' ? 1 : 128, stdout: '', stderr: question === 'rev-parse' ? '' : 'fatal: bad revision\n', isStdoutTruncated: false, isStderrTruncated: false } } as never
    }
    if (cmd === '__modkit' && args[0] === 'writes') {
      const input = JSON.parse(String(args[1])) as { command: string; cwd: string; home: string }
      const reading = commandWrites(input.command, input.cwd, input.home)
      return ok(JSON.stringify(ctl.reading ? ctl.reading(reading) : reading))
    }
    // Given the folder the call starts in, each command with the folder it runs in (#2000), as mod-kit's own pipeline gives it.
    if (cmd === '__modkit' && args[0] === 'pipeline') {
      // With the commands that only set a value where the caller asks for them (#3093), as mod-kit's
      // own handler passes that on: without it a reading that asks for them here was given none (#3416).
      const input = JSON.parse(String(args[1])) as { command: string; cwd?: string; home?: string; assignments?: boolean }
      const opts = input.assignments === true ? { assignments: true } : {}
      return ok(JSON.stringify(input.cwd === undefined ? pipeline(input.command, opts) : pipelineIn(input.command, input.cwd, input.home ?? '', opts)))
    }
    // mod-kit's git reader (#1158), read here with its copy; JSON has no undefined, so none is null.
    // The settings the command runs with go with its words (#3337), as mod-kit's own member takes them.
    if (cmd === '__modkit' && args[0] === 'git') {
      const input = JSON.parse(String(args[1])) as { words: string[]; env?: string[] }
      return ok(JSON.stringify(gitCommand(input.words, input.env) ?? null))
    }
    // mod-kit's typed answer wording (#1145), read here with its copy.
    if (cmd === '__modkit' && args[0] === 'typedAnswer') {
      const input = JSON.parse(String(args[1])) as TypedAnswer
      return ok(JSON.stringify({ toast: typedToast(input.guard), text: typedAnswerText(input) }))
    }
    // mod-kit's branch reader, read here with its copy, over the checkouts the stand-in's walk finds.
    if (cmd === '__modkit' && args[0] === 'branch') {
      if (ctl.branchFails) return { value: { exitCode: 1, stdout: '', stderr: 'mod-kit: the branch reader failed', isStdoutTruncated: false, isStderrTruncated: false } } as never
      const { path } = JSON.parse(String(args[1])) as { path: string }
      const root = [...COPIES, '/w/slate-wt2', '/w/slate-wt', '/w/slate', '/w/other', '/w/tests/shop'].find(r => path === r || path.startsWith(r + '/'))
      return ok(JSON.stringify(root === undefined ? null : await readBranch(root, git)))
    }
    if (cmd === '__modkit' && args[0] === 'repo') {
      const input = JSON.parse(String(args[1])) as { root?: string | null; remote: string | null }
      return ok(JSON.stringify({ github: githubRepo(input.remote), name: repoName(input) }))
    }
    // The design rounds skill's check that a settled design is exactly as make-settled.py sealed it
    // (#1524). Its rule is proven against make-settled.py's own output in the skill's suite
    // (tests/settled_tests.py); here it reads as sealed only the texts the test names, so any other
    // text, an edited frame included, is not.
    if (cmd === 'python3' && args[args.length - 1] === '--sealed') {
      const stdin = String((e as { init?: { stdin?: string } }).init?.stdin ?? '')
      sealChecks.push({ argv: e.argv.map(String), stdin })
      if (ctl.sealFails) throw new Error('spawn python3 ENOENT')
      if (ctl.sealSilent) return ok('')
      if (ctl.sealed?.includes(stdin)) return ok('sealed\n')
      return { value: { exitCode: 1, stdout: 'not sealed: it has changed since make-settled.py sealed it\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
    }
    // Every file under a folder a write reaches whole (#2395): `git -C <tree> ls-files -z --cached
    // --others --exclude-standard -- :(top,literal)<folder>`, which names each file the test put under
    // it, tracked or not, and every file in the checkout for an empty folder (its top).
    if (cmd === 'git' && args[0] === '-C' && args[2] === 'ls-files' && args.length === 9 && args[4] === '--cached') {
      gitRuns.push(e.argv.join(' '))
      if (ctl.lsFilesFails) throw new Error('spawn git ENOENT')
      const rel = String(args[8]).replace(/^:\(top,literal\)/, '')
      const under = rel ? `${args[1]}/${rel}/` : `${args[1]}/`
      return ok(Object.keys(files).filter(f => f.startsWith(under)).map(f => `${f.slice(String(args[1]).length + 1)}\0`).join(''))
    }
    // Whether git tracks files (#1933): `git -C <tree> ls-files -z -- :(literal,icase)<path>...`, one
    // pathspec per file (#3022 asks for every file in one run), which names each tracked one and
    // nothing for any other.
    if (cmd === 'git' && args[0] === '-C' && args[2] === 'ls-files' && args[3] === '-z' && args[4] === '--' && args.length >= 6) {
      gitRuns.push(e.argv.join(' '))
      if (ctl.lsFilesFails) throw new Error('spawn git ENOENT')
      let out = ''
      for (const spec of args.slice(5)) {
        const rel = String(spec).replace(/^:\(literal,icase\)/, '')
        const path = `${args[1]}/${rel}`.toLowerCase()
        // A path a test never put on the disk is tracked too (#2991): git's index answers for a file
        // whatever the disk holds, and a test naming a project file means one the project has.
        if (!(ctl.untracked ?? []).some(f => f.toLowerCase() === path)) out += `${rel}\0`
      }
      return ok(out)
    }
    // Taking away a file a shell write made (#1296): `rm -f -- <path>`.
    if (cmd === 'rm'&& args[0] === '-f' && args[1] === '--' && args.length === 3) {
      if (ctl.rmFails) return { value: { exitCode: 1, stdout: '', stderr: `rm: ${args[2]}: Operation not permitted\n`, isStdoutTruncated: false, isStderrTruncated: false } } as never
      removed.push(String(args[2]))
      delete files[String(args[2])]
      return ok('')
    }
    throw new Error(`unexpected command: ${e.argv.join(' ')}`)
  })
  on('fs.write', ($, e) => {
    if (ctl.writeFails?.(e.path)) throw new Error(`EACCES: ${e.path}`)
    files[e.path] = e.text
    writes.push(e.path)
    ctl.afterWrite?.(e.path)
    return { value: undefined } as never
  })
  // A file is there when the test put it there, and a folder when a file the test put is under it.
  const isOther = (path: string) => path.startsWith('/dev/') || (init.fifos ?? []).includes(path) || (init.stdinLinks ?? []).includes(path)
  const opened: string[] = []
  let attempted: () => void = () => undefined
  const readAttempted = new Promise<'read attempted'>(resolve => {
    attempted = () => resolve('read attempted')
  })
  on('fs.exists', ($, e) => {
    if (ctl.existsFails) throw new Error(`EIO: ${e.path}`)
    return { value: files[e.path] !== undefined || isOther(e.path) || Object.keys(files).some(f => f.startsWith(`${e.path}/`)) } as never
  })
  // What is at a path: a file the test put, a folder above one, or something else (#1765).
  on('fs.stat', ($, e) => {
    if ((init.stdinLinks ?? []).includes(e.path) && e.resolve) throw new Error(`EBADF: bad file descriptor, stat '${e.path}'`)
    if (isOther(e.path)) return { value: { kind: 'other', size: 0, mtimeMs: T0, isLink: false } } as never
    if (files[e.path] !== undefined) return { value: { kind: 'file', size: 1, mtimeMs: T0, isLink: false } } as never
    if (Object.keys(files).some(f => f.startsWith(`${e.path}/`))) return { value: { kind: 'dir', size: 0, mtimeMs: T0, isLink: false } } as never
    throw new Error(`ENOENT: ${e.path}`)
  })
  // A folder's entries: the files the test put directly in it (#1275, a mod's hooks folder).
  on('fs.list', ($, e) => {
    if (ctl.listFails) throw new Error(`EACCES: ${e.path}`)
    const dir = `${e.path.replace(/\/$/, '')}/`
    const names = Object.keys(files).filter(f => f.startsWith(dir) && !f.slice(dir.length).includes('/'))
    // And each folder a file the test put is under (the session's scratchpad's parents, #1296).
    const dirs = [...new Set(Object.keys(files).filter(f => f.startsWith(dir) && f.slice(dir.length).includes('/')).map(f => f.slice(dir.length).split('/')[0] as string))]
    return {
      value: [
        ...names.map(f => ({ name: f.slice(dir.length), kind: 'file' as const, size: 1, mtimeMs: T0, isLink: false })),
        ...dirs.map(name => ({ name, kind: 'dir' as const, size: 0, mtimeMs: T0, isLink: false })),
      ],
    } as never
  })
  on('fs.read', async ($, e) => {
    reads.push(e.path)
    if (isOther(e.path)) {
      opened.push(e.path)
      attempted()
      return { value: await never<string>() } as never
    }
    if (ctl.unreadable === e.path) throw new Error(`EIO: ${e.path}`)
    const t = files[e.path]
    if (t === undefined) throw new Error(`ENOENT: ${e.path}`)
    // A file that exists and cannot be read.
    if (t === 'UNREADABLE') throw new Error(`EACCES: ${e.path}`)
    return { value: t } as never
  })
  on('store.get', ($, e) => {
    storeGets.push(e.key)
    if (ctl.storeGetFails) throw new Error('the store could not be read')
    return { value: store[e.key] } as never
  })
  on('store.set', ($, e) => {
    if (ctl.storeSetFails || (ctl.storeSetFailKey !== undefined && e.key.includes(ctl.storeSetFailKey))) throw new Error('disk full')
    store[e.key] = e.value
    return { value: undefined } as never
  })
  on('ui.log', ($, e) => {
    const text = String((e as { text?: string }).text ?? '')
    logged.push({ text, to: (e as { to?: string }).to })
    if (text.startsWith('CARD ')) cards.push(JSON.parse(text.slice(5)))
    return { value: undefined } as never
  })
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text ?? ''))
    return { value: undefined } as never
  })
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  // Core, standing in (mod-kit's tests/core.ts): the tool.check chain decides whether the call may
  // run, then it runs, or Dan is shown the dialog and his answer handed back as the dialog does.
  // Beneath every mod's tool.check hook, Claude Code's settings hooks and permission check allow
  // every call, unless the test has them refuse one (the payload write gate, say).
  const core = standInCore(engine, on, () => (ctl.settingsRefuse ? { decision: 'deny', reason: 'Blocked by a settings hook.' } : { decision: 'allow' }))
  on('tool.call', async ($, e) => {
    const c = await core(e)
    if ('refused' in c) return c.refused as never
    const { tool, input } = c.call
    if (tool === 'AskUserQuestion') {
      const a = input as unknown as Asked
      asked.push(a)
      const q = a.questions[0]?.question ?? ''
      const result = { questions: a.questions, answers: dialog.answer === undefined ? {} : { [q]: dialog.answer }, ...(dialog.afk ? { afkTimeoutMs: 60_000 } : {}) }
      return { result, text: `User has answered: ${dialog.answer ?? ''}` } as never
    }
    // A call the test holds open mid run, so another can arrive while it is still under way.
    if (ctl.hold && String(input.file_path ?? '').includes('HOLD')) {
      ctl.reached?.()
      await ctl.hold
    }
    ran.push({ tool: String(tool), input })
    if (tool === 'Bash') for (const [path, text] of Object.entries(ctl.shell ?? {})) files[path] = text
    if (tool === 'Bash') for (const path of ctl.gone ?? []) delete files[path]
    if (tool === 'Bash' && ctl.readFailsAfterRun) ctl.unreadable = ctl.readFailsAfterRun
    return { result: 'written', text: 'written' } as never
  })
  return { files, branches, store, ctl, ran, asked, dialog, cards, gitRuns, at, reads, clock, storeGets, toasts, logged, blobs, gitSays, writes, removed, sealChecks, opened, readAttempted }
}
export type W = ReturnType<typeof world>

export type Caller = { tool: { call: (e: never) => Promise<unknown> } }
export type Result = { deny?: string; text?: string; isError?: boolean; context?: readonly string[] }
let calls = 0
// The id the newest call was made under, as a refusal's picker names it.
export const lastCallId = () => `t${calls}`
export const call = async ($: Caller, input: Record<string, unknown>) => (await $.tool.call({ tool_use_id: `t${++calls}`, ...input } as never)) as Result
// This mod's own reason, in whichever form Claude Code wraps a refusal (#1484).
export const refusalOf = (r: Result) => (r.deny !== undefined || r.isError ? reasonOf(r, 'design-round-guard') : '')
export const contextOf = (r: Result) => (r.context ?? []).join('\n')
