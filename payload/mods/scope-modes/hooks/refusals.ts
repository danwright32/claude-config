import type { ModKitWrites } from '../.claude-plugin/types/mod-kit/index.d.ts'
import { startFailKind } from './driver.ts'
import type { Cmd } from './nobuild.ts'
import { GIT_LOCAL_READS } from './overnight.ts'

// What the morning report needs from a call auto mode's check refused while asleep (#3158). On the
// night of 16 Nov 2026 the check was unavailable for hours and the report listed 340 refusals one by
// one, every one later done, so the few that needed Dan would have been buried. The report folds the
// refusals the check gave no verdict on into one counted line and lists on its own each one it cannot
// show was done: one that did more than read, and that no later identical call ran. So each refusal
// note says whether the check gave a verdict, which call it was (its toolUseId, matched to a later
// identical call by callKey), what it was, and whether it only read. Every judgement here leans one
// way: what is not certainly a read is not one, so a refusal that needs Dan stays listed.

/** A call's own arguments: the tool.call event without the keys the engine carries beside them. */
export const toolArgs = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...args } = e
  return args
}

const canonical = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(canonical) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map(k => [k, canonical((v as Record<string, unknown>)[k])])) : v

// The rtk rewrite hook writes rtk in front of a command it shortens the output of, so the input a
// refusal carries and the one a later call carries may differ only by it. rtk proxy is left as
// written: it is a different spelling a person or Claude chose.
const RTK = /^\s*rtk\s+(?!proxy\b)/

/** Which call this is, for matching a refusal to a later identical call: the tool and its input. */
export const callKey = (tool: string, args: Record<string, unknown>): string => {
  const a = tool === 'Bash' && typeof args.command === 'string' ? { ...args, command: args.command.replace(RTK, '') } : args
  return JSON.stringify([tool, canonical(a)])
}

// Tools that only read, by their name alone.
const READ_TOOLS: ReadonlySet<string> = new Set(['Read', 'Grep', 'Glob', 'LS', 'NotebookRead', 'WebFetch', 'WebSearch', 'ToolSearch'])
// Programs that only read and print, given no redirect (mod-kit's writes reader finds one), each with
// a judge of its arguments where some option makes it write or run something.
const always = () => true
const noneOf = (bad: readonly string[]) => (args: readonly string[]) => !args.some(a => bad.some(b => a === b || a.startsWith(`${b}=`)))
const READ_PROGRAMS: ReadonlyMap<string, (args: readonly string[]) => boolean> = new Map([
  ...['cat', 'head', 'tail', 'ls', 'wc', 'pwd', 'stat', 'file', 'which', 'echo', 'printf', 'basename', 'dirname', 'realpath', 'readlink', 'du', 'df', 'diff', 'cmp', 'comm', 'cut', 'tr', 'nl', 'grep', 'egrep', 'fgrep', 'test', '[', 'true', 'false', 'cd', 'jq', 'shasum', 'md5', 'column'].map(p => [p, always] as const),
  ['rg', (args: readonly string[]) => !args.some(a => a.startsWith('--pre'))],
  ['find', noneOf(['-exec', '-execdir', '-ok', '-okdir', '-delete', '-fprint', '-fprint0', '-fprintf', '-fls'])],
  ['sort', (args: readonly string[]) => !args.some(a => a.startsWith('--output') || /^-[A-Za-z]*o/.test(a))],
])
// What may stand before a git subcommand that reads: a folder to run in, or an option that only quiets git.
const GIT_QUIET: ReadonlySet<string> = new Set(['--no-pager', '-P', '--no-optional-locks'])
const GIT_READS: ReadonlySet<string> = new Set([...GIT_LOCAL_READS, 'status'])
const base = (w: string | undefined) => (w ?? '').split('/').pop() ?? ''

const gitReads = (c: Cmd): boolean => {
  const g = c.git
  if (!g?.sub || !GIT_READS.has(g.sub) || base(c.words[0]) !== 'git') return false
  // git takes any unambiguous start of a long option, so --outp and --out are --output too.
  if (g.args.some(a => {
    const name = a.split('=')[0] as string
    return name.length >= 3 && '--output'.startsWith(name)
  })) return false
  const before = c.words.slice(1, c.words.length - g.args.length - 1)
  for (let i = 0; i < before.length; i++) {
    if (before[i] === '-C' && i + 1 < before.length) i++
    else if (!GIT_QUIET.has(before[i] as string)) return false
  }
  return true
}

const commandReads = (c: Cmd): boolean => {
  if (c.unread || c.verdict || c.script || c.xargs || c.language || c.program || c.heredocs?.length || c.derived?.some(d => d !== null)) return false
  if ((c.behind ?? []).some(b => b !== 'rtk')) return false
  if (c.git) return gitReads(c)
  const judge = READ_PROGRAMS.get(base(c.words[0]))
  return judge !== undefined && judge(c.words.slice(1))
}

/**
 * Whether a call only reads: a tool that reads by its name, or a Bash call whose every command is a
 * known read and that writes nothing mod-kit's writes reader can see. Anything else is not a read.
 */
export const readsOnly = (tool: string, commands: readonly Cmd[], writes: ModKitWrites): boolean => {
  if (READ_TOOLS.has(tool)) return true
  if (tool !== 'Bash' || !commands.length) return false
  const w = writes
  if (w.files.length || w.changes.length || w.unnamed.length || w.byGit?.length || w.runs?.length || w.stdout?.length || w.unread?.length) return false
  return commands.every(commandReads)
}

const WHAT_MAX = 160
const short = (s: string) => {
  const line = s.split('\n').map(l => l.trim()).find(Boolean) ?? ''
  return line.length > WHAT_MAX ? `${line.slice(0, WHAT_MAX - 3)}...` : line
}
/** What a call was, in a few words: its command, the file it writes, or its description. */
export const whatOf = (args: Record<string, unknown>): string => {
  for (const k of ['command', 'file_path', 'notebook_path', 'description', 'url', 'pattern', 'query']) {
    const v = args[k]
    if (typeof v === 'string' && v.trim()) return short(v)
  }
  return ''
}

export type RefusalNote = { tool: string; text: string; reason: string; noVerdict?: true; toolUseId: string; what: string; read?: true }

/**
 * The fields of a `failed` note for a refusal by auto mode's check. `noVerdict` only when its reason
 * says the check gave none (driver.ts startFailKind, the one reader of those words); `read` only when
 * readsOnly said so.
 */
export const refusalNote = (tool: string, args: Record<string, unknown>, toolUseId: string, reason: string, read: boolean): RefusalNote => ({
  tool,
  text: `the auto mode classifier refused ${tool}: ${reason}`,
  reason,
  ...(startFailKind(reason) === 'no-verdict' ? { noVerdict: true as const } : {}),
  toolUseId,
  what: whatOf(args),
  ...(read ? { read: true as const } : {}),
})
