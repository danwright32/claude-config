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

const CAPTURED_GH_TOKEN = /\b[A-Za-z_][A-Za-z0-9_]*=\$\(\s*gh\s+auth\s+token\b[^)]*\)/g
const READERS = new Set(['cat', 'head', 'tail', 'less', 'more', 'bat', 'nl', 'strings', 'xxd', 'od', 'tac'])

// Simple commands, split on the shell's separators. Good enough to find a command word and its
// arguments; it does not need to be a parser, because each rule below errs toward refusing.
const segments = (cmd: string): string[][] =>
  cmd
    .split(/&&|\|\||[;|\n]/)
    .map(s => s.trim().split(/\s+/).filter(Boolean))
    .map(words => {
      let i = 0
      while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i] ?? '')) i++
      return words.slice(i)
    })
    .filter(w => w.length > 0)

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
export const blockedCommand = (cmd: string): string | undefined => {
  if (/\bgh\s+auth\s+token\b/.test(cmd.replace(CAPTURED_GH_TOKEN, ''))) return 'the GitHub token'
  for (const words of segments(cmd)) {
    const [head, ...args] = words
    if (head === undefined) continue
    if (READERS.has(head)) {
      const file = args.find(a => !a.startsWith('-') && isEnvFile(a.replace(/^["']|["']$/g, '')))
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
