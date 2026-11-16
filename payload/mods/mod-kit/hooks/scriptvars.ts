// What a shell script's own variables hold, read from its text (#3022): a temporary file or folder
// it made with mktemp, and its own folder. One reader, kept by each mod that asks at
// hooks/mod-kit/scriptvars.ts: the design round guard wrote it (#2171, #2924, #2960, #2991), and the
// area check, which could place no write into a folder made with mktemp, no library sourced through
// a variable and no name after the idiom's cd, held every checker script handed a folder. Each
// answer is no wherever anything else may set the variable, so a caller reads a no as it reads a
// name it cannot place.

/**
 * The variable a removal's name starts from where the rest is a plain name inside it (#2960):
 * `$D` for `$D/sub` or `${D}/a/page.tsx`, and for `$D` itself, so a folder the command makes with bare
 * mktemp is read as #2171 reads the variable alone. None where the rest holds another $, backticks,
 * or a `..` that may climb out.
 */
export const leadingVariable = (word: string): string | undefined => {
  const m = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(\/.*)?$/.exec(word)
  if (!m) return undefined
  const rest = m[3] ?? ''
  if (/[$`]/.test(rest) || /(?:^|\/)\.\.(?:\/|$)/.test(rest)) return undefined
  return `$${m[1] ?? m[2]}`
}

// The two values of a variable Dan trusts to name a new file outside every screen path (#2171).
const FRESH_TEMP = new Set(['$(mktemp)', '$(mktemp -d)'])
// A builtin that sets the variable its argument names, so a name built at run time may be any one.
const SETS_NAMED = /^(?:export|declare|typeset|local|readonly|read|printf|getopts|mapfile|readarray|unset|let)$/
/**
 * Whether a write to a variable alone (`$T`, `${T}`) whose every value mod-kit's reader gives is
 * `$(mktemp)` or `$(mktemp -d)` names a new file outside every screen path (#2171, Dan, 2026-11-04,
 * picker answer: trust bare mktemp the way git rev-parse is trusted). A template, -t, -p, any other
 * flag and backticks are not trusted. Stricter than his rule: nothing is trusted where the command
 * could make mktemp print another name, or give the variable a value the reader did not give. It is
 * read with its quotes and backslashes taken out, as zsh takes `"mktemp"(){` and `m\ktemp(){` for a
 * function named mktemp, and it must not mention TMPDIR or PATH (zsh's `path` array included, set,
 * appended, by element, or named to `typeset`, `read`, `set` or another setting builtin), define any
 * function, name mktemp anywhere but those two values, hash a command, use `$'...'`, hand a setting
 * builtin a name built at run time (`export ${V}DIR=`), or assign the variable anywhere any other
 * value (a prefix assignment, `T=x cmd`, which the reader drops, an append, an element).
 */
export const freshTemp = (word: string, values: readonly string[], command: string): boolean => {
  const alone = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))$/.exec(word)
  if (!alone || values.length === 0 || !values.every((v) => FRESH_TEMP.has(v))) return false
  if (command.includes("$'")) return false
  const text = command.replace(/["'\\]/g, '')
  if (/TMPDIR|\bPATH\b|(?:^|[^A-Za-z0-9_$-])path(?:\[[^\]]*\])?\+?=|\(\s*\)|\bfunctions?\b|\bhash\b|\balias\b/.test(text)) return false
  if (/mktemp/.test(text.replace(/\$\(mktemp(?: -d)?\)/g, ''))) return false
  for (const part of text.split(/[;&|\n]/)) {
    const words = part.trim().split(/\s+/)
    let i = 0
    while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i] as string)) i++
    if (!SETS_NAMED.test(words[i] ?? '') && words[i] !== 'set') continue
    // zsh's path array is PATH: `typeset path`, `read -A path` or `set -A path` may change it.
    if (words.slice(i + 1).some((w) => w.split(/[=[]/)[0] === 'path')) return false
    if (words[i] === 'set') continue
    if (words.slice(i + 1).some((w) => (w.split('=')[0] as string).includes('$'))) return false
  }
  const name = (alone[1] ?? alone[2]) as string
  for (const a of text.matchAll(new RegExp(`(?:^|[^A-Za-z0-9_])${name}(\\[[^\\]]*\\])?(\\+?)=`, 'g'))) {
    if (a[1] || a[2]) return false
    if (!/^\$\(mktemp(?: -d)?\)(?=$|[\s;&|)])/.test(text.slice((a.index ?? 0) + a[0].length))) return false
  }
  return true
}

/**
 * Whether the shell variable `name` only ever holds a temporary folder the script made itself
 * (#2991): every assignment `script` gives it is `"$(mktemp -d)"` (bare, or in double quotes), or a
 * name inside such a variable (`"$T/chain"`, read by leadingVariable, so with no other expansion and
 * no `..`), and there is at least one. False where anything else may set it: an assignment of any
 * other value, an append or an element, a builtin or loop naming it (`read CH`, `for CH in`, `local
 * CH`), a default expansion assigning it (`${CH:=x}`), or where mktemp itself may be another program
 * or make its folder elsewhere (TMPDIR, PATH or zsh's path set, a function, alias or hash, `$'...'`).
 * `script` is every script text the caller read for the command, so a script it reads in (`source
 * x.sh`) is held to the same; one sourced by a name the caller cannot follow is not seen, so a caller
 * holds a script sourcing one.
 * With `files` (#2924), for a variable a write goes to itself rather than one a name is joined onto,
 * a temporary file (`"$(mktemp)"`) counts too, and so does an empty value (`closed_file=""`), which
 * names no file at all, so a write to it fails rather than landing anywhere.
 */
export const madeTemp = (name: string, script: string, seen: ReadonlySet<string> = new Set(), files = false): boolean => {
  if (seen.has(name) || !/^[A-Za-z_]\w*$/.test(name) || script.includes("$'")) return false
  const plain = script.replace(/["'\\]/g, '')
  if (/TMPDIR|\bPATH\+?=|(?:^|[^A-Za-z0-9_$-])path(?:\[[^\]]*\])?\+?=|\bmktemp\s*\(\s*\)|\bfunction\s+mktemp\b|\balias\b|\bhash\b/.test(plain)) return false
  if (new RegExp(`\\$\\{${name}:?=`).test(script)) return false
  for (const part of script.split(/[;&|\n]/)) {
    const words = part.trim().split(/\s+/)
    let i = 0
    while (i < words.length && /^[A-Za-z_]\w*=/.test(words[i] as string)) i++
    if ((SETS_NAMED.test(words[i] ?? '') || words[i] === 'for' || words[i] === 'select') && words.slice(i + 1).includes(name)) return false
  }
  let any = false
  for (const a of script.matchAll(new RegExp(`(?:^|[^A-Za-z0-9_$])${name}(\\[[^\\]]*\\])?(\\+?)=`, 'g'))) {
    if (a[1] || a[2]) return false
    const rest = script.slice((a.index ?? 0) + a[0].length)
    const value = /^"([^"]*)"(?=$|[\s;&|)])/.exec(rest)?.[1] ?? /^(\$\(mktemp(?: -d)?\))(?=$|[\s;&|)])/.exec(rest)?.[1] ?? /^([^\s;&|()'"`\\]+)(?=$|[\s;&|)])/.exec(rest)?.[1]
    if (value === undefined) return false
    if (value === '$(mktemp -d)' || (files && value === '$(mktemp)')) {
      any = true
      continue
    }
    if (files && value === '') continue
    const lead = leadingVariable(value)
    if (lead === undefined || !madeTemp(lead.slice(1), script, new Set([...seen, name]))) return false
    any = true
  }
  return any
}

/**
 * Whether a write to `word` lands in a temporary file or folder the script made itself (#2924,
 * #3022): the variable alone (`$T`, `${T}`), a temporary file or folder by madeTemp's `files`
 * reading, or a plain name inside a temporary folder (`$T/copy`, leadingVariable). `script` as for
 * madeTemp. A name holding another value (`$T/$n`), a climb, and any other word are not.
 */
export const tempWord = (word: string, script: string): boolean => {
  const alone = /^\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))$/.exec(word)
  if (alone) return madeTemp((alone[1] ?? alone[2]) as string, script, new Set(), true)
  const lead = leadingVariable(word)
  return lead !== undefined && madeTemp(lead.slice(1), script)
}

// The usual idiom a script finds its own folder by (#2924), as a pattern's source: a cd to the
// folder of BASH_SOURCE and a pwd, in one command substitution, and nothing else in it.
const OWN_FOLDER_IDIOM = String.raw`\$\(cd (?:-P )?"\$\(dirname "\$(?:\{BASH_SOURCE(?:\[0\])?\}|BASH_SOURCE)"\)"(?: (?:>|&>) ?\/dev\/null(?: 2>&1)?)? && pwd(?: -P)?\)`
/** That idiom as one value in double quotes. */
const OWN_FOLDER = new RegExp(`^"${OWN_FOLDER_IDIOM}"$`)

/**
 * Whether a script's text sets variable `v` to the script's own folder (#2924): one line that is
 * `v="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` alone (BASH_SOURCE, never `$0`, which in a
 * sourced file names the script that sourced it), and nothing else setting it: no other assignment,
 * no builtin or loop naming it, no `${v:=x}`, and no cd, pushd or popd anywhere before that line,
 * which would move the folder a relative name of the script is read from.
 */
export const ownFolderVar = (v: string, text: string): boolean => {
  if (!/^[A-Za-z_]\w*$/.test(v)) return false
  const sets = [...text.matchAll(new RegExp(`(?:^|[^A-Za-z0-9_$])${v}(\\[[^\\]]*\\])?(\\+?)=`, 'g'))]
  const a = sets[0]
  if (sets.length !== 1 || !a || a[1] || a[2]) return false
  if (new RegExp(`\\$\\{${v}:?=`).test(text)) return false
  if (new RegExp(`(?:^|[\\s;&|(])(?:export|declare|typeset|local|readonly|read|printf|getopts|mapfile|readarray|unset|let|for|select)\\b[^\\n;]*\\b${v}\\b`).test(text)) return false
  const name = (a.index ?? 0) + a[0].length - v.length - 1
  const line = text.lastIndexOf('\n', name - 1) + 1
  if (text.slice(line, name).trim() !== '') return false
  const end = text.indexOf('\n', name)
  const value = text.slice((a.index ?? 0) + a[0].length, end < 0 ? text.length : end).trim()
  if (!OWN_FOLDER.test(value)) return false
  return !/(?:^|[\s;&|(`])(?:cd|pushd|popd)(?=[\s;&|)]|$)/.test(text.slice(0, line))
}

/**
 * Where a word naming a file under the variable that holds a script's own folder puts it (#2924,
 * #3022): `$HERE/lib/x.sh` or `${HERE}/x.sh`, HERE set as ownFolderVar reads in `text`, the text of
 * the script file at `self`, is that name beside the script, as written (a `..` in it is the
 * caller's to resolve). Undefined for the variable alone, which names a folder, for a name holding
 * another value, a backtick or a pattern, which names no one file, and wherever the variable is not
 * the script's own folder.
 */
export const ownFolderPath = (word: string, text: string, self: string): string | undefined => {
  const m = /^\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))(\/.+)$/.exec(word)
  if (!m || /[$`*?[]/.test(m[3] as string) || !ownFolderVar((m[1] ?? m[2]) as string, text)) return undefined
  return `${self.slice(0, self.lastIndexOf('/'))}${m[3]}`
}

/**
 * A script's text with each whole own folder idiom taken out, a plain name left in its place
 * (#3022). The idiom's cd runs inside a command substitution, a shell of its own, so the script's
 * folder never moves; a reader asking whether a script moves folder reads this text, and counts
 * every cd left in it. Only the whole idiom goes: a cd to the script's folder outside a
 * substitution, or one followed in its substitution by anything but pwd, stays as written.
 */
export const withoutOwnFolder = (text: string): string => text.replace(new RegExp(OWN_FOLDER_IDIOM, 'g'), '/own-folder')
