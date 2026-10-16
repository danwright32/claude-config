import { ghRepo, linkRepo } from './repo.ts'

// The one reading of a gh command's arguments (#834, moved here from scope-modes in #961): every
// overnight gh decision, the merge judge and no build's reading of gh api go through it, so a
// spelling read one way here cannot be read another way there. gh parses its flags as pflag does,
// so this does too: `--flag=value` and `--flag value`, a short flag's value attached (`-XDELETE`,
// `-Rowner/x`, `-fkey=val`) or apart, and short flags that take no value clustered (`-sd`). Whether
// a short flag takes a value depends on the command (`-m` is a milestone to `gh pr create` and a
// merge to `gh pr merge`), so the value flags are known per subcommand and action. Every repository
// it names is read by repo.ts's ghRepo, the one reading of a repository as gh spells one.

export type GhArgs = {
  /** The subcommand (`pr`, `issue`, `api`) and its action (`merge`, `comment`); empty when absent. */
  sub: string
  act: string
  /** Each flag as gh reads it, long or short, with its value, or true for one that takes none. */
  flags: { name: string; value: string | true }[]
  /** Every word that is not a flag or a flag's value, after the subcommand and action. */
  positionals: string[]
  /**
   * The repository the command names itself, as owner/name in lower case: -R or --repo, else a
   * github.com link among its positionals, else (for `gh repo`) an owner/name positional.
   * Undefined when it names none, so gh takes GH_REPO or the checkout's; null when it names one
   * that cannot be read.
   */
  named?: string | null
  /** A flag before the subcommand that is not one of gh's known global flags: nothing it does can be said. */
  unreadable: boolean
  /** For `gh api`, what it sends and where. */
  api?: GhApi
}

/**
 * A `gh api` call's method and endpoint as gh reads them: GET unless -X says otherwise or a field
 * or input is sent, which makes it a POST. `fields` are the values its -f and -F fields send
 * (`force=true`); `input` whether --input sends a body this reader cannot see. `repo` the
 * repository its endpoint names (`repos/<owner>/<name>/...`), as owner/name in lower case:
 * undefined for an endpoint outside repos/ or gh's own placeholders for the current repository
 * ({owner}/{repo}), so the checkout decides; null for one that cannot be read. `query` the GraphQL
 * document its query field sends, null when it cannot be read: none given, a body from --input, or
 * `-F query=@file`, which gh reads from that file.
 */
export type GhApi = { method: string; endpoint: string | undefined; fields: string[]; input: boolean; repo?: string | null; query: string | null }

// gh's global flags that take no value, allowed before the subcommand.
const GLOBAL_BOOLEANS = new Set(['--help', '-h', '--version'])

// The short flags that take a value, by subcommand and action; `*` is any action.
const SHORT_VALUES: Record<string, Record<string, string>> = {
  api: { '*': 'XfFHpqt' },
  pr: { merge: 'RbFtA', review: 'RbF', comment: 'RbF', create: 'RbFtlmapBHrTq', edit: 'RbFtmapBr', close: 'Rc', '*': 'RbFtlmapBHLqsSAT' },
  issue: { comment: 'RbF', create: 'RbFtlmapT', edit: 'RbFtmap', close: 'Rcr', '*': 'RbFtlmapLqsSAT' },
  '*': { '*': 'RbFtlmapBHLqsSAT' },
}
const LONG_VALUES = new Set([
  '--repo', '--body', '--body-file', '--title', '--label', '--milestone', '--assignee', '--project', '--base', '--head', '--reviewer', '--template',
  '--add-label', '--remove-label', '--add-assignee', '--remove-assignee', '--add-project', '--remove-project', '--add-reviewer', '--remove-reviewer',
  '--method', '--field', '--raw-field', '--header', '--input', '--jq', '--preview', '--cache', '--hostname', '--json', '--limit', '--state', '--search',
  '--author', '--subject', '--author-email', '--match-head-commit', '--reason', '--branch', '--ref', '--workflow', '--notes', '--notes-file',
  '--target', '--description', '--color', '--name', '--event', '--user', '--status', '--commit',
])
const shortValuesFor = (sub: string, act: string): string => {
  const s = SHORT_VALUES[sub] ?? SHORT_VALUES['*'] as Record<string, string>
  return s[act] ?? s['*'] ?? (SHORT_VALUES['*'] as Record<string, string>)['*'] as string
}

/** A gh command's words, `gh` first (by name or path), read as gh reads them; undefined when the words are no gh command. */
export const ghArgs = (words: readonly string[]): GhArgs | undefined => {
  if ((words[0] ?? '').split('/').pop() !== 'gh') return undefined
  const flags: GhArgs['flags'] = []
  const plain: string[] = []
  // Global flags may come before the subcommand (`gh -R other/x pr close 5`): the known ones are
  // read with their values, so a value is never taken for the subcommand; any other flag there
  // makes the call unreadable, so the repository it reaches cannot be said (L75).
  const rest = words.slice(1) as string[]
  let unreadable = false
  let lead = 0
  for (; lead < rest.length; lead++) {
    const w = rest[lead] as string
    if (!w.startsWith('-')) break
    // Each read here, once, as the global flag it is, never again by the subcommand's own table.
    if (w === '-R' || w === '--repo') flags.push({ name: w, value: (rest[++lead] as string | undefined) ?? true })
    else if (w.startsWith('--repo=')) flags.push({ name: '--repo', value: w.slice('--repo='.length) })
    else if (/^-R./.test(w)) flags.push({ name: '-R', value: w.slice(2) })
    else if (GLOBAL_BOOLEANS.has(w)) flags.push({ name: w, value: true })
    else unreadable = true
  }
  // The subcommand and action are then the first two words that are not flags.
  const subAt = rest.findIndex((w, n) => n >= lead && !w.startsWith('-'))
  const sub = subAt < 0 ? '' : (rest[subAt] as string)
  const actAt = sub === 'api' || subAt < 0 ? -1 : rest.findIndex((w, n) => n > subAt && !w.startsWith('-'))
  const act = actAt < 0 ? '' : (rest[actAt] as string)
  // gh takes the action straight after the subcommand. A flag between them could pass its own
  // value off as the action (`gh pr --body view close`), so the call cannot be read (#834 review).
  if (actAt > subAt + 1) unreadable = true
  const shortValues = shortValuesFor(sub, act)
  // The global flags before the subcommand are read above, so this reading starts past them.
  let k = lead
  // A flag that takes a value takes the next word whatever it starts with, as gh does
  // (`--body "- fixed X"`, `--body-file -`).
  const takeNext = (): string => rest[++k] as string
  for (; k < rest.length; k++) {
    if (k === subAt || k === actAt) continue
    const w = rest[k] as string
    if (w === '--') {
      plain.push(...rest.slice(k + 1))
      break
    }
    if (w.startsWith('--')) {
      const eq = w.indexOf('=')
      const name = eq < 0 ? w : w.slice(0, eq)
      if (eq >= 0) flags.push({ name, value: w.slice(eq + 1) })
      else if (LONG_VALUES.has(name) && k + 1 < rest.length) flags.push({ name, value: takeNext() })
      else flags.push({ name, value: true })
      continue
    }
    if (w.startsWith('-') && w.length > 1) {
      // A cluster: each letter a flag, until one that takes a value, which takes the rest of the
      // word, or the next word when it is the last letter.
      for (let j = 1; j < w.length; j++) {
        const letter = w[j] as string
        const name = `-${letter}`
        if (shortValues.includes(letter)) {
          const attached = w.slice(j + 1)
          if (attached) flags.push({ name, value: attached })
          else if (k + 1 < rest.length) flags.push({ name, value: takeNext() })
          else flags.push({ name, value: true })
          break
        }
        flags.push({ name, value: true })
      }
      continue
    }
    plain.push(w)
  }
  const out: GhArgs = { sub, act, flags, positionals: plain, unreadable }
  const named = unreadable ? null : namedRepo(sub, flags, plain)
  if (named !== undefined) out.named = named
  if (sub === 'api') out.api = apiOf(out)
  return out
}

const namedRepo = (sub: string, flags: GhArgs['flags'], positionals: string[]): string | null | undefined => {
  const r = flags.filter(f => f.name === '-R' || f.name === '--repo').pop()
  if (r) return typeof r.value === 'string' ? ghRepo(r.value) : null
  for (const p of positionals) {
    const linked = linkRepo(p)
    if (linked !== null) return ghRepo(linked)
  }
  if (sub === 'repo') {
    const p = positionals[0]
    if (p !== undefined) return ghRepo(p)
  }
  return undefined
}

/** The value of a flag gh read, by any of its names (the last one given wins, as in gh); undefined when absent. */
export const flagOf = (a: GhArgs, ...names: string[]): string | true | undefined => a.flags.filter(f => names.includes(f.name)).pop()?.value

/** Whether any of these flags was given. */
export const hasFlag = (a: GhArgs, ...names: string[]): boolean => a.flags.some(f => names.includes(f.name))

const FIELD_FLAGS = ['-f', '-F', '--field', '--raw-field']
const API = 'https://api.github.com/'
const PLACEHOLDER = /^(?:\{owner\}|:owner|\{repo\}|:repo)$/

// The repository an endpoint names as gh reaches it: an endpoint starting https:// is an address
// as it stands, any other has one leading slash trimmed and goes after api.github.com. So
// `repos/o/r`, `/repos/o/r` and `https://api.github.com/repos/o/r` reach o/r; any other spelling
// that comes to repos/ once its slashes and host are taken off (`//repos/o/r`) is one gh does not
// send there, so it cannot be read (null), never none.
const endpointRepo = (endpoint: string | undefined): string | null | undefined => {
  const e = endpoint ?? ''
  const path = e.startsWith(API) ? e.slice(API.length) : e.startsWith('https://') ? null : e.replace(/^\//, '')
  if (path !== null && path.startsWith('repos/')) {
    const m = /^repos\/([^/?#]+)\/([^/?#]+)/.exec(path)
    if (!m) return null
    const [owner, name] = [m[1] as string, m[2] as string]
    // gh fills both placeholders from the checkout's repository, which decides; one beside a real
    // name is a repository that cannot be told from here.
    if (PLACEHOLDER.test(owner) && PLACEHOLDER.test(name)) return undefined
    if (PLACEHOLDER.test(owner) || PLACEHOLDER.test(name)) return null
    return ghRepo(`${owner}/${name}`)
  }
  const loose = e.replace(/^\/+/, '').replace(/^https:\/\/api\.github\.com\//, '').replace(/^\/+/, '')
  return loose.startsWith('repos/') ? null : undefined
}

// The GraphQL document a call sends, read from its `query=` field in any spelling gh reads.
const queryOf = (a: GhArgs): string | null => {
  if (hasFlag(a, '--input')) return null
  const q = a.flags.filter(f => FIELD_FLAGS.includes(f.name) && typeof f.value === 'string' && f.value.startsWith('query=')).pop()
  if (!q) return null
  const query = (q.value as string).slice('query='.length)
  // -F and --field read a value starting with @ from that file; -f takes it as written.
  return (q.name === '-F' || q.name === '--field') && query.startsWith('@') ? null : query
}

const apiOf = (a: GhArgs): GhApi => {
  const fields = a.flags.filter(f => FIELD_FLAGS.includes(f.name)).map(f => (typeof f.value === 'string' ? f.value : ''))
  const input = hasFlag(a, '--input')
  const m = flagOf(a, '-X', '--method')
  const method = typeof m === 'string' ? m.toUpperCase() : fields.length || input ? 'POST' : 'GET'
  const endpoint = a.positionals[0]
  const out: GhApi = { method, endpoint, fields, input, query: queryOf(a) }
  const repo = endpointRepo(endpoint)
  if (repo !== undefined) out.repo = repo
  return out
}
