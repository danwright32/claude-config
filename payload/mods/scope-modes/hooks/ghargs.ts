// The one reading of a gh command's arguments in this mod (#834): every overnight gh decision, and
// no build's reading of gh api, go through it, so a spelling read one way here cannot be read
// another way there. gh parses its flags as pflag does, so this does too: `--flag=value` and
// `--flag value`, a short flag's value attached (`-XDELETE`, `-Rowner/x`, `-fkey=val`) or apart,
// and short flags that take no value clustered (`-sd`). Whether a short flag takes a value
// depends on the command (`-m` is a milestone to `gh pr create` and a merge to `gh pr merge`), so
// the value flags are known per subcommand and action.

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
  named: string | null | undefined
  /** A flag before the subcommand that is not one of gh's known global flags: nothing it does can be said. */
  unreadable: boolean
  /**
   * A subcommand the flag table does not know was given a flag other than -R or --repo: which of
   * its flags take a value is not guessed, so nothing past them can be placed.
   */
  unknownFlags: boolean
}

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

/** A GitHub repository in any spelling (owner/name, a link, an ssh remote) as owner/name in lower case; null when it is none. */
export const normRepo = (s: string): string | null => {
  let t = s.trim().replace(/\.git$/, '').replace(/\/+$/, '')
  // A host only where the spelling says so (a scheme, a user@, or github.com itself), so an owner
  // with a dot in it (my.org/x) is an owner, never a host.
  const host = /^(?:[a-z+]+:\/\/(?:[^@/]+@)?|[^@/:]+@)([^/:]+)[:/](.*)$/i.exec(t) ?? /^((?:www\.)?github\.com)\/(.*)$/i.exec(t)
  if (host) {
    if ((host[1] as string).toLowerCase().replace(/^www\./, '') !== 'github.com') return null
    t = host[2] as string
  }
  const parts = t.split('/').filter(Boolean)
  if (parts.length !== 2 || parts.some(p => !/^[\w.-]+$/.test(p))) return null
  return parts.join('/').toLowerCase()
}

// A github.com link to a repository, or anything under it (an issue, a PR, a file).
const LINK = /^(?:https?:\/\/)?(?:www\.)?github\.com\/([\w.-]+)\/([\w.-]+)(?:[/?#].*)?$/i

/** A gh command's words, `gh` first, read as gh reads them. */
export const ghArgs = (words: readonly string[]): GhArgs => {
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
    if (w === '-R' || w === '--repo') lead++
    else if (/^(?:-R.|--repo=)/.test(w) || GLOBAL_BOOLEANS.has(w)) continue
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
  let k = 0
  // A flag's value taken from the next word. One that looks like a flag itself means this reader
  // has a flag's arity wrong (`-yd -R other/x`), and a repository flag may be swallowed, so the
  // call cannot be read (#834 review of af10401).
  const takeNext = (): string => {
    const v = rest[++k] as string
    if (v.startsWith('-')) unreadable = true
    return v
  }
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
  const known = sub !== '*' && Object.prototype.hasOwnProperty.call(SHORT_VALUES, sub)
  const unknownFlags = !known && flags.some(f => !['-R', '--repo', '--help', '-h'].includes(f.name))
  return { sub, act, flags, positionals: plain, named: unreadable ? null : namedRepo(sub, flags, plain), unreadable, unknownFlags }
}

const namedRepo = (sub: string, flags: GhArgs['flags'], positionals: string[]): string | null | undefined => {
  const r = flags.filter(f => f.name === '-R' || f.name === '--repo').pop()
  if (r) return typeof r.value === 'string' ? normRepo(r.value) : null
  for (const p of positionals) {
    const m = LINK.exec(p)
    if (m) return normRepo(`${m[1]}/${m[2]}`)
  }
  if (sub === 'repo') {
    const p = positionals[0]
    if (p !== undefined) return normRepo(p)
  }
  return undefined
}

/** The value of a flag gh read, by any of its names (the last one given wins, as in gh); undefined when absent. */
export const flagOf = (a: GhArgs, ...names: string[]): string | true | undefined => a.flags.filter(f => names.includes(f.name)).pop()?.value

/** Whether any of these flags was given. */
export const hasFlag = (a: GhArgs, ...names: string[]): boolean => a.flags.some(f => names.includes(f.name))

const FIELD_FLAGS = ['-f', '-F', '--field', '--raw-field']
/**
 * A `gh api` call's method and endpoint as gh reads them: GET unless -X says otherwise or a field
 * or input is sent, which makes it a POST. `fields` are the values its -f and -F fields send
 * (`force=true`); `input` whether --input sends a body this reader cannot see.
 */
export const ghApi = (a: GhArgs): { method: string; endpoint: string | undefined; fields: string[]; input: boolean } => {
  const fields = a.flags.filter(f => FIELD_FLAGS.includes(f.name)).map(f => (typeof f.value === 'string' ? f.value : ''))
  const input = hasFlag(a, '--input')
  const m = flagOf(a, '-X', '--method')
  const method = typeof m === 'string' ? m.toUpperCase() : fields.length || input ? 'POST' : 'GET'
  return { method, endpoint: a.positionals[0], fields, input }
}
