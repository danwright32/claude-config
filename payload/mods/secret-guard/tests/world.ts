// What both of this mod's hook test files stand on: register.test.ts, where the mod loads in the
// user tier as it does on the Macs, and screen.test.ts, which seats it beneath a stand-in answering
// mod (#3291). Moved here unchanged from register.test.ts so the two cannot drift.
import type { On, Register } from 'claude-code'

// A stand-in for mod-kit, which draws the grey card. An inline plugin runs in an environment of
// its own and cannot reach this file's variables, so it reports each card as a transcript line
// the world below collects (measured 2026-10-03). Its command reader is a small stand-in for the
// real one (a mod cannot import another mod's files), enough for the commands below; the real
// reader is tested in mod-kit.
export const kit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    const read = (cmd: string): string[][] =>
      cmd
        .split(/&&|;|\n/)
        .map(part => {
          const words: string[] = []
          // A word may mix bare and quoted parts (X="a b" is one word), as the shell's are.
          for (const m of part.matchAll(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g)) words.push(m[0].replace(/"([^"]*)"|'([^']*)'/g, '$1$2'))
          while (words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0] ?? '')) words.shift()
          return words
        })
        .filter(w => w.length > 0)
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        modkit: {
          blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
          commands: async ({ command }: { command: string }) => read(command),
          // The kit's other members, which these tests never reach: each refuses by name if one ever is.
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
          git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
          pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
          workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
          repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
          gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
          mergeHelper: async () => { throw new Error("mod-kit's mergeHelper is not stood in by these tests") },
          goal: async () => { throw new Error("mod-kit's goal is not stood in by these tests") },
          ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
          linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
          branch: async () => { throw new Error("mod-kit's branch is not stood in by these tests") },
          bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
          clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
          screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
          // #939: a press raised by the kit's Button below, and whether a click lands; every Button here is clickable.
          press: async () => ({ isAnswered: false }),
          clickable: async () => true,
          isDans: async () => { throw new Error("mod-kit's isDans is not stood in by these tests") },
          typedAnswer: async () => { throw new Error("mod-kit's typedAnswer is not stood in by these tests") },
          hold: async () => { throw new Error("mod-kit's hold is not stood in by these tests") },
          release: async () => { throw new Error("mod-kit's release is not stood in by these tests") },
          pythonText: async () => { throw new Error("mod-kit's pythonText is not stood in by these tests") },
          login: async () => { throw new Error("mod-kit's login is not stood in by these tests") },
          account: async () => { throw new Error("mod-kit's account is not stood in by these tests") },
        },
      }
    })
  },
}

export const KNOWN = 'kN0wn-S3cr3t-v4lue-zz'
export const ENV_SECRET = 'fr0m-the-env-f1le-yy'
export const GH_TOKEN = 'gho_' + 'Q'.repeat(36)

// The world beneath the mod: the environment, the gh token and one project .env file. Every tool
// call that gets past the mod is answered here, and recorded, so a test can tell a refusal (the
// call never arrived) from a pass.
// files: more files on disk, by path, beside the project .env.
export const world = (on: On, files: Record<string, string> = {}, failing?: string) => {
  const logs: string[] = []
  const reached: string[] = []
  const toasts: string[] = []
  const cards: { toolUseId: string; guard: string; reason: string; safeWay?: string }[] = []
  on('process.run', ($, e) => {
    const cmd = e.argv.join(' ')
    if (cmd === 'env') return { value: { exitCode: 0, stdout: `HOME=${'/Users'}/x\nAPI_TOKEN=${KNOWN}\n`, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    if (cmd === 'gh auth token') return { value: { exitCode: 0, stdout: `${GH_TOKEN}\n`, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    if (cmd.startsWith('git rev-parse')) return { value: { exitCode: 0, stdout: '/repo\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    return { value: { exitCode: 1, stdout: '', stderr: 'unexpected', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.list', ($, e) => ({ value: e.path === '/repo' ? [{ name: '.env', kind: 'file' as const }, { name: 'src', kind: 'dir' as const }] : [] }) as never)
  on('fs.read', ($, e) => {
    if (e.path === '/repo/.env') return { value: `SUPABASE_SERVICE_ROLE_KEY=${ENV_SECRET}\nPORT=3000\n` }
    const more = files[e.path]
    if (more !== undefined) return { value: more }
    throw new Error(`no file ${e.path}`)
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    if (e.text.startsWith('CARD ')) cards.push(JSON.parse(e.text.slice(5)))
    else logs.push(e.text)
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', ($, e) => {
    reached.push(e.tool)
    if (failing !== undefined && (e as { command?: string }).command === failing) throw new Error('the tool beneath failed')
    return { result: 'ran', text: 'ran' } as never
  })
  return { reached, toasts, cards, logs }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const start = async ($: { session: { start: (e: { cwd: string; surface: 'terminal'; isInteractive: boolean }) => Promise<unknown> } }) =>
  $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

// A call to a tool another mod answers itself (#707): manual steps' own, with one value to paste.
export const steps = (value: string, id = 's1') => ({ tool: 'mcp__manual-steps__steps', tool_use_id: id, heading: 'Stripe', steps: [{ title: 'Paste the key', value, checked: 'not-done' }] }) as never
