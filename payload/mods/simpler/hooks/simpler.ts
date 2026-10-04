// The Simpler button's judgements (claude-config#619), pure so each is tested on its own: when an
// answer earns the button, what kind of answer it was, the request a press sends, and the weekly
// count. The hooks that use them are in register.tsx.

// THE THRESHOLD. Measured on this Mac on 2026-10-04 over 595 replies that ended a turn and were
// followed by a prompt (~/.claude/projects transcripts): median 75 words, three in four under 210,
// one in five over 250, one in eight over 300. The button asks for 2 to 3 sentences, about 50
// words, so 250 is five times that and puts the button on roughly one reply in five: rare enough to
// read as meaning something, not so rare it misses the long design answers the issue is about.
// A starting value: the weekly count and how often the button is pressed are what tell whether to
// move it (docs/mods-design.md).
export const LONG_WORDS = 250
// Below this an answer is already near the length the button asks for, so technical terms alone
// never earn it: 80 words is four or five sentences.
export const MIN_WORDS = 80
// From MIN_WORDS up, an answer earns the button when this share of its words are technical terms
// (identifiers, paths, flags, issue numbers, code). Measured over the same 595 replies: of the 168
// between MIN_WORDS and LONG_WORDS the median share is 2.4%, three in four are under 4.4% and nine
// in ten under 6.2%, so 6% picks out the densest tenth of them (19 replies, about 3% of all). A
// first guess of 15% fired on none of them, which would have left this half of the rule inert.
// With the length rule, the button shows on about one reply in four (136 of 595).
export const TECH_SHARE = 0.06
export const REPORT_EVERY_MS = 7 * 24 * 60 * 60 * 1000

export type Kind = 'design' | 'plan' | 'diagnosis' | 'status' | 'explanation'
export type Judgement = { reason: 'long' | 'technical'; kind: Kind; words: number }

// The one list of answer kinds: what the log records and the weekly line names, in the order a tie
// is broken. Explanation is what an answer is when nothing else fits, so it has no pattern.
export const KINDS: readonly { kind: Kind; one: string; many: string; pattern?: RegExp }[] = [
  { kind: 'design', one: 'design answer', many: 'design answers', pattern: /\b(options?|trade-?offs?|approach(es)?|alternatives?|recommend\w*|design)\b/gi },
  { kind: 'plan', one: 'plan', many: 'plans', pattern: /\b(plan|phases?|steps?)\b|^\s*\d+[.)]\s/gim },
  { kind: 'diagnosis', one: 'diagnosis', many: 'diagnoses', pattern: /\b(root cause|bugs?|fail\w*|errors?|broke\w*|regressions?|caused?|crash\w*)\b/gi },
  { kind: 'status', one: 'status report', many: 'status reports', pattern: /\b(merged|pushed|PR|CI|deploy\w*|green|shipped|released)\b/gi },
  { kind: 'explanation', one: 'explanation', many: 'explanations' },
]

// Capitals Dan reads as plain words, never as jargon.
const PLAIN_CAPS = new Set(['OK', 'PR', 'PRS', 'ET', 'AM', 'PM', 'US', 'UK', 'TV', 'ID', 'FYI', 'ASAP', 'CEO', 'NYC'])
const CODE = 'simplercodespan'
const FILE_EXT = /\w\.(ts|tsx|js|jsx|mjs|cjs|json|md|sh|py|swift|sql|ya?ml|toml|css|html|lock|txt|env)$/i

const isTechnical = (raw: string): boolean => {
  if (raw === CODE) return true
  const w = raw.replace(/^[("'[]+|[)"'\],.;:!?]+$/g, '')
  if (!w) return false
  return (
    /^#\d+$/.test(w) ||
    /^--?[a-z][\w-]*$/i.test(w) ||
    /^\$/.test(w) ||
    /[a-z][A-Z]/.test(w) ||
    /\w_\w/.test(w) ||
    /\w\(\)/.test(w) ||
    /\w\/\w/.test(w) ||
    FILE_EXT.test(w) ||
    /\w=\S/.test(w) ||
    /::|->|=>/.test(w) ||
    (/^[0-9a-f]{7,40}$/.test(w) && /\d/.test(w) && /[a-f]/.test(w)) ||
    (/^[A-Z][A-Z0-9]+$/.test(w) && !PLAIN_CAPS.has(w))
  )
}

/** Words of prose, and how many of them are technical terms. Each line of a code block counts as one of each. */
export const measure = (text: string): { words: number; technical: number } => {
  let words = 0
  let technical = 0
  const prose = text.replace(/^```[^\n]*\n([\s\S]*?)^```[^\n]*$/gm, (_m, body: string) => {
    const lines = body.split('\n').filter(l => l.trim()).length
    words += lines
    technical += lines
    return ' '
  })
  for (const raw of prose.replace(/`[^`\n]+`/g, ` ${CODE} `).split(/\s+/)) {
    if (!/[A-Za-z0-9]/.test(raw)) continue
    words += 1
    if (isTechnical(raw)) technical += 1
  }
  return { words, technical }
}

/** What the answer is mostly about, by which kind's words it uses most; ties go to the earlier kind. */
export const kindOf = (text: string): Kind => {
  let best: Kind = 'explanation'
  let bestCount = 0
  for (const k of KINDS) {
    if (!k.pattern) continue
    const n = (text.match(k.pattern) ?? []).length
    if (n > bestCount) {
      best = k.kind
      bestCount = n
    }
  }
  return best
}

/** Whether an answer earns the Simpler button, and why; null when it does not. */
export const judge = (text: string): Judgement | null => {
  const { words, technical } = measure(text)
  if (words > LONG_WORDS) return { reason: 'long', kind: kindOf(text), words }
  if (words >= MIN_WORDS && technical / words >= TECH_SHARE) return { reason: 'technical', kind: kindOf(text), words }
  return null
}

const HEAD = 200
const squash = (t: string) => t.replace(/\s+/g, ' ').trim()
/** An answer's opening, whitespace collapsed: what the reply block drawn is matched on. */
export const replyHead = (answer: string): string => squash(answer).slice(0, HEAD)
/**
 * Whether a reply block drawn in the transcript is the opening of the answer judged. The block is
 * the reply's first, so its text and the answer start alike; a block too short to tell (a one word
 * reply) never matches, so an earlier "Done." cannot borrow the latest answer's button.
 */
export const sameReply = (head: string, blockText: string): boolean => {
  const b = squash(blockText).slice(0, HEAD)
  if (!b || !head || b.length < Math.min(head.length, 24)) return false
  return head.startsWith(b) || b.startsWith(head)
}

/** The request a press submits, as Dan's own words: the spec's three parts, and the long version left alone. */
export const requestText = (project: string | undefined): string =>
  'Say your last answer again, simply: 2 to 3 plain sentences with no jargon. ' +
  'If it leaves a decision open for me, restate that decision plainly. ' +
  `Then give one concrete example from ${project ? project : 'this project'}. ` +
  'The long version stays above, so do not repeat it.'

// Each press is its own store key, so two sessions pressing at once both land rather than one
// read, change and write of a shared list losing the other's (L690).
export const PRESS_PREFIX = 'press:'
export const pressKey = (at: number, salt: string): string => `${PRESS_PREFIX}${at}:${salt}`
export const pressAt = (key: string): number | undefined => {
  const m = /^press:(\d+):/.exec(key)
  return m ? Number(m[1]) : undefined
}

const listWords = (parts: string[]): string =>
  parts.length <= 1 ? (parts[0] ?? '') : `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}`

/** The weekly line: how often Simpler was pressed, and after which kinds of answer, most first. */
export const weeklyLine = (kinds: string[], days: number): string => {
  const span = `in the last ${days} ${days === 1 ? 'day' : 'days'}`
  if (kinds.length === 0) return `Simpler was not pressed ${span}.`
  const counts = new Map<string, number>()
  for (const k of kinds) counts.set(k, (counts.get(k) ?? 0) + 1)
  const order = (k: string) => {
    const i = KINDS.findIndex(x => x.kind === k)
    return i === -1 ? KINDS.length : i
  }
  const parts = [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || order(a[0]) - order(b[0]))
    .map(([k, n]) => {
      // A kind this version does not know (an older or newer list) is still counted, by its own name.
      const label = KINDS.find(x => x.kind === k) ?? { one: k, many: k }
      return `${n} ${n === 1 ? label.one : label.many}`
    })
  const times = kinds.length === 1 ? 'once' : `${kinds.length} times`
  return `Simpler was pressed ${times} ${span}: after ${listWords(parts)}.`
}
