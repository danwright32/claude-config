import type { EngineInterface, Register } from 'claude-code'
import {
  SAFE_WAY,
  blockedCommand,
  commandRefusal,
  findKnownSecret,
  isEnvFile,
  scrub,
  secretsFromEnvList,
  secretsFromEnvText,
} from './secrets.ts'

// Secret echo guard (claude-config#607). The known values are held in this module's memory only,
// never in $.store or on disk: a copy kept to protect a secret would be one more place to leak it.
// A reload starts the module over and session.start fires again, which reloads them.
let known: string[] = []

const WRITERS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit'])

// The text a writer tool is about to put into its file, whichever tool it is.
const newTextOf = (input: Record<string, unknown>): string => {
  if (Array.isArray(input.edits)) return (input.edits as { new_string?: unknown }[]).map(x => String(x.new_string ?? '')).join('\n')
  return String(input.content ?? input.new_string ?? input.new_source ?? '')
}

const strings = (v: unknown, out: string[] = []): string[] => {
  if (typeof v === 'string') out.push(v)
  else if (Array.isArray(v)) for (const x of v) strings(x, out)
  else if (v && typeof v === 'object') for (const x of Object.values(v)) strings(x, out)
  return out
}

const run = async ($: EngineInterface, argv: string[], cwd?: string): Promise<string | undefined> => {
  try {
    const r = await $.process.run(argv, { cwd, timeoutMs: 10_000 })
    return r.exitCode === 0 ? r.stdout : undefined
  } catch {
    return undefined
  }
}

// Every source the spec names. A source that cannot be read is said so by name rather than read
// as holding no secrets (L215): the guard still runs on the shapes and on what it did read.
const loadSecrets = async ($: EngineInterface, cwd: string): Promise<string[]> => {
  const found: string[] = []
  const missing: string[] = []

  const env = await run($, ['env'])
  if (env === undefined) missing.push('the environment')
  else found.push(...secretsFromEnvList(env))

  const gh = await run($, ['gh', 'auth', 'token'])
  if (gh !== undefined && gh.trim()) found.push(gh.trim())
  else missing.push('the gh token')

  const root = (await run($, ['git', 'rev-parse', '--show-toplevel'], cwd))?.trim()
  for (const dir of [...new Set([cwd, root].filter((d): d is string => !!d))]) {
    let entries: { name: string; kind: string }[] = []
    try {
      entries = await $.fs.list(dir)
    } catch {
      missing.push(`the folder ${dir}`)
      continue
    }
    for (const ent of entries) {
      if (ent.kind !== 'file' || !isEnvFile(ent.name)) continue
      try {
        found.push(...secretsFromEnvText(await $.fs.read(`${dir}/${ent.name}`)))
      } catch {
        missing.push(`${dir}/${ent.name}`)
      }
    }
  }
  // One dim line per source it could not read, once per session (docs/mods-design.md).
  for (const m of missing) $.ui.log(`Secret guard couldn't read ${m}, so it's guarded by its shape only.`)
  return [...new Set(found)]
}

const GUARD = 'Secret guard'
const OUTBOUND = 'Refer to it by its name, not its value.'

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    known = await loadSecrets($, e.cwd)
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const input = e as unknown as Record<string, unknown>

    const toolUseId = String(input.tool_use_id ?? '')
    if (e.tool === 'Bash') {
      const raw = String(input.command ?? '')
      const what = blockedCommand(await $.modkit.commands({ command: raw }), raw)
      if (what) {
        await $.modkit.blocked({ toolUseId, guard: GUARD, reason: `This would print ${what}.`, safeWay: SAFE_WAY })
        await $.ui.toast('Blocked a command that would print a secret.')
        return { deny: commandRefusal(what) }
      }
    }

    const path = String(input.file_path ?? input.notebook_path ?? '')
    const intoEnvFile = WRITERS.has(String(e.tool)) && isEnvFile(path)
    if (!intoEnvFile && strings(input).some(s => findKnownSecret(s, known))) {
      await $.modkit.blocked({ toolUseId, guard: GUARD, reason: 'This message contains a secret.', safeWay: OUTBOUND })
      await $.ui.toast('Blocked a message containing a secret.')
      return { deny: `Blocked: this message contains a secret. ${OUTBOUND}` }
    }

    // A secret written into a .env file is one to guard from now on.
    if (intoEnvFile) known = [...new Set([...known, ...secretsFromEnvText(newTextOf(input))])]

    return next(e)
  })

  on('session.append', async ($, e, next) => {
    if (e.door !== 'tool-result' && e.door !== 'tool-message') return next(e)
    let count = 0
    const clean = (t: string): string => {
      const r = scrub(t, known)
      count += r.count
      return r.text
    }
    const content = e.message.content.map(b => {
      const block = b as unknown as Record<string, unknown>
      if (block.type === 'text' && typeof block.text === 'string') return { ...block, text: clean(block.text) }
      if (block.type === 'tool_result') {
        const c = block.content
        if (typeof c === 'string') return { ...block, content: clean(c) }
        if (Array.isArray(c)) {
          return {
            ...block,
            content: c.map(x => {
              const inner = x as Record<string, unknown>
              return inner.type === 'text' && typeof inner.text === 'string' ? { ...inner, text: clean(inner.text) } : inner
            }),
          }
        }
      }
      return block
    }) as typeof e.message.content
    if (count === 0) return next(e)
    await $.ui.toast(`Hid ${count} secret${count === 1 ? '' : 's'} from a command's output.`)
    return next({ ...e, message: { ...e.message, content } })
  })
}
