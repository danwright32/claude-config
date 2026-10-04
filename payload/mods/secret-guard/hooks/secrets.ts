// The secret guard's rules, kept apart from the hooks so each is tested on its own (claude-config#607).

// A name that says its value is a secret: one of these words as a whole underscore separated part
// of it, so GITHUB_TOKEN and OPENAI_API_KEY count while KEYBOARD_LAYOUT and TOKENIZER_DIR do not.
const SECRET_NAME = /(?:^|_)(?:TOKEN|TOKENS|KEY|KEYS|APIKEY|SECRET|SECRETS|PASSWORD|PASSWD)(?:_|$)/i

// Shapes of secrets this Mac may never have seen: GitHub, Anthropic, Slack, Supabase, JWT.
// Each needs its full length, so a masked value like gho_**** (L691) is not one.
const SHAPES: readonly RegExp[] = [
  /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b/g,
  /\bgithub_pat_[A-Za-z0-9_]{60,}\b/g,
  /\bsk-ant-[A-Za-z0-9_-]{32,}/g,
  /\bxox[abprs]-[A-Za-z0-9-]{10,}/g,
  /\bsbp_[A-Za-z0-9]{40,}\b/g,
  /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g,
]

const REDACTED = '[REDACTED]'
const MIN_VALUE = 8

// Wording settled with Dan, 2026-10-03 (docs/mods-design.md).
export const SAFE_WAY = 'Check it without printing: test -n, its length, or gh auth status.'
export const commandRefusal = (what: string): string => `Blocked: this would print ${what}. ${SAFE_WAY}`

export const isEnvFile = (path: string): boolean => {
  const base = path.split('/').pop() ?? ''
  if (!/^\.env(\..+)?$/.test(base)) return false
  return !/\.(example|sample|template|dist)$/.test(base)
}

const hasShape = (text: string): boolean => SHAPES.some(re => new RegExp(re.source).test(text))

// A value worth guarding: long enough not to match ordinary text, and not a path or a sentence.
const guardable = (v: string): boolean => v.length >= MIN_VALUE && !v.startsWith('/') && !/\s/.test(v)

const unquote = (v: string): string => {
  const t = v.trim()
  if (t.length >= 2 && (t[0] === '"' || t[0] === "'") && t[t.length - 1] === t[0]) return t.slice(1, -1)
  return t
}

// Values from a .env file: those under a secret's name, and any value shaped like a token. Ordinary
// config (a port, a site URL) is left out, or every file that mentions it would be refused.
export const secretsFromEnvText = (text: string): string[] => {
  const out: string[] = []
  for (const line of text.split('\n')) {
    const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line)
    if (!m) continue
    const name = m[1] ?? ''
    const value = unquote(m[2] ?? '')
    if (!guardable(value)) continue
    if (SECRET_NAME.test(name) || hasShape(value)) out.push(value)
  }
  return out
}

// Values from `env` output: only those under a secret's name.
export const secretsFromEnvList = (text: string): string[] => {
  const out: string[] = []
  for (const line of text.split('\n')) {
    const i = line.indexOf('=')
    if (i <= 0) continue
    const name = line.slice(0, i)
    const value = line.slice(i + 1)
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) && SECRET_NAME.test(name) && guardable(value)) out.push(value)
  }
  return out
}

const escapeRe = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

// Every spelling a value can reach output in: as written, and percent encoded with either case of
// hex (L741). A shape match cannot see an encoded value, so these are matched as text.
const spellings = (v: string): string[] => {
  const enc = encodeURIComponent(v)
  return [...new Set([v, enc, enc.replace(/%[0-9A-F]{2}/g, s => s.toLowerCase())])]
}

const safeDecode = (s: string): string => {
  try {
    return decodeURIComponent(s.replace(/\+/g, ' '))
  } catch {
    return s
  }
}

export const scrub = (text: string, values: readonly string[]): { text: string; count: number } => {
  let out = text
  let count = 0
  const known = [...values].filter(guardable).sort((a, b) => b.length - a.length)
  for (const v of known) {
    for (const s of spellings(v)) {
      const re = new RegExp(escapeRe(s), 'g')
      out = out.replace(re, () => {
        count++
        return REDACTED
      })
    }
  }
  for (const re of SHAPES) {
    out = out.replace(new RegExp(re.source, 'g'), () => {
      count++
      return REDACTED
    })
  }
  // A token percent encoded inside a URL or a query: decode each run of URL characters that holds
  // an escape, and redact the run whole when what it decodes to carries a token's shape. One pass
  // over maximal runs, so the cost is linear in the text: a pattern that could start anywhere and
  // look ahead for a % rescanned every long run once per position (lessons review, L353).
  out = out.replace(/[A-Za-z0-9._~+%\-]+/g, run => {
    if (!/%[0-9A-Fa-f]{2}/.test(run) || !hasShape(safeDecode(run))) return run
    count++
    return REDACTED
  })
  return { text: out, count }
}

export const findKnownSecret = (text: string, values: readonly string[]): boolean => {
  const known = values.filter(guardable)
  if (known.some(v => spellings(v).some(s => text.includes(s)))) return true
  return hasShape(text) || hasShape(safeDecode(text))
}

// ---- commands that print a secret ----
//
// The command is read by mod-kit's one shared reader ($.modkit.commands): each simple command as
// its words, quotes removed, sudo and env looked past, a shell's -c read as what it runs (L613).
// This judges what it hands back. The gh token check alone reads the command as written, because
// whether the token was captured into a variable is a property of how the command is spelled.

const CAPTURED_GH_TOKEN = /\b[A-Za-z_][A-Za-z0-9_]*=\$\(\s*gh\s+auth\s+token\b[^)]*\)/g
// Everything that prints a file's lines, the text tools included (lessons review: grep . .env).
const READERS = new Set([
  'cat', 'head', 'tail', 'less', 'more', 'bat', 'nl', 'strings', 'xxd', 'od', 'tac',
  'grep', 'egrep', 'fgrep', 'rg', 'awk', 'sed', 'cut', 'sort', 'uniq', 'tr', 'jq', 'column', 'paste',
])

// A filter tool's first plain argument is its program or pattern, not a file, unless the program
// came with a flag (grep -e, awk -f, jq --arg is not one): a jq filter starting .env. was refused
// live on 2026-10-03.
const PROGRAM_FIRST = new Set(['grep', 'egrep', 'fgrep', 'rg', 'awk', 'sed', 'jq'])
const PROGRAM_FLAGS = new Set(['-e', '--regexp', '-f', '--file', '--expression'])
const fileArgs = (head: string, args: string[]): string[] => {
  const plain = args.filter(a => !a.startsWith('-'))
  return PROGRAM_FIRST.has(head) && !args.some(a => PROGRAM_FLAGS.has(a)) ? plain.slice(1) : plain
}

const secretVarIn = (word: string): string | undefined => {
  for (const m of word.matchAll(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g)) {
    const name = m[1] ?? ''
    // ${#NAME} is the length, which is the safe form.
    if (m[0].startsWith('${#')) continue
    if (SECRET_NAME.test(name)) return name
  }
  return undefined
}

// What a command would print, when that is a secret: a name, "the secrets in <file>", or every
// variable. Undefined when the command is fine.
export const blockedCommand = (cmds: string[][], raw: string): string | undefined => {
  if (/\bgh\s+auth\s+token\b/.test(raw.replace(CAPTURED_GH_TOKEN, ''))) return 'the GitHub token'
  for (const words of cmds) {
    const [first, ...args] = words
    if (first === undefined) continue
    const head = first.split('/').pop() ?? first
    if (READERS.has(head)) {
      const file = fileArgs(head, args).find(isEnvFile)
      if (file) return `the secrets in ${file}`
    }
    if (head === 'echo' || head === 'printf') {
      const v = args.map(secretVarIn).find(Boolean)
      if (v) return v
    }
    if (head === 'printenv') {
      const names = args.filter(a => !a.startsWith('-'))
      if (names.length === 0) return 'every environment variable'
      const v = names.find(n => SECRET_NAME.test(n))
      if (v) return v
    }
    if (head === 'env' && args.every(a => a.startsWith('-'))) return 'every environment variable'
  }
  return undefined
}
