// A lessons file shaped as the real one is (#3343 route 2), for the cases that read what a write
// takes out of it, moves or renames: a title and text above the first section, entries that wrap,
// carry their provenance on a line of their own, a check line and a SHORT line, and numbers of
// which one is the start of another (L17, L174). One fixture for the rules and the register cases.
export const SHAPED = [
  '# Build-time lessons',
  '',
  'Distilled from an audit of the issues. Numbering is stable for reference.',
  '',
  '## Proof over green',
  '- **L1. A test or guard is only real once it has been seen to fail.** (slate#1, 2026-07-27)',
  '  CHECK: hooks/test-first.sh (partial)',
  '- **L17. A check that passes on an empty input has measured nothing, so give it one case it',
  '  must refuse.** (slate#2, 2026-08-01)',
  '  NO CHECK: a judgement made case by case',
  '  SHORT: Give every check one case it must refuse.',
  '- **L174. Shortening a retention window makes every later step keyed to a longer one unreachable.**',
  '  (slate#3, 2026-08-02)',
  '',
  '## Data safety',
  '- **L5. Never destroy good state before its replacement is verified to exist.**',
  '  (slate#4, 2026-07-27)',
  '- **L7. User data gets a rotating backup and a restore path from day one.** (slate#5, 2026-07-27)',
  '',
  '## Honest failure',
  '- **L10. An error state and an empty state are different screens.** (slate#6, 2026-07-27)',
  '',
].join('\n')

/** The whole of one entry of `file`, each of its lines with its newline, by its number. */
export const entryOf = (n: string, file: string = SHAPED): string => {
  const lines = file.split('\n')
  const at = lines.findIndex(l => l.startsWith(`- **${n}.`))
  if (at === -1) throw new Error(`no entry ${n} in the fixture`)
  const end = lines.findIndex((l, k) => k > at && (l.startsWith('- **L') || l.startsWith('## ') || l === ''))
  return `${lines.slice(at, end).join('\n')}\n`
}

/** `file` with those entries taken out whole. */
export const without = (file: string, ...ns: string[]): string => ns.reduce((f, n) => f.replace(entryOf(n, f), ''), file)
