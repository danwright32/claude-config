// An issue's "Open questions" section (#1279, Dan 2026-10-17): what only Dan can decide about the
// issue, one item a question, or None. The filing gate (hooks/issue_field_gate.py) refuses a new
// issue without the section; /sleep asks every open item in its goal issues' sections before the
// night begins and checks each off as it is answered; picker-manners adds a question Dan is asked
// about an issue. The one reader and the one writer of the section, pure, kept here and copied byte
// for byte into each mod that uses it (hooks/mod-kit/openquestions.ts, which
// tools/check-mod-shared-parts.sh holds to this one), since a mod cannot import another's files.
//
// The shape:
//   ## Open questions
//
//   - [ ] Keep the old flag?
//   - [x] Rename it? (answered 2026-10-16 ET: Yes)
// An unchecked box or a plain bullet is open; a checked box is answered; None means none.

const HEADING = /^#{1,6}[ \t]*Open questions\b/i
const ANY_HEADING = /^#{1,6}[ \t]/
const BULLET = /^[ \t]*[-*][ \t]+(?:\[([ xX])\][ \t]+)?(.*)$/
const SESSION = /^Claude-Session:/

/** The section's lines, as indices into `lines`: the heading and the end (exclusive); null when absent. */
const sectionOf = (lines: string[]): { head: number; end: number } | null => {
  const head = lines.findIndex(l => HEADING.test(l.trim()))
  if (head < 0) return null
  let end = head + 1
  while (end < lines.length && !ANY_HEADING.test(lines[end] as string) && !SESSION.test(lines[end] as string)) end++
  return { head, end }
}

// An answered item's own words, without what was added when it was answered.
const wordsOf = (text: string) => text.replace(/ \(answered [^)]*\)$/, '').trim()
const oneLine = (q: string) => q.split(/\s*\n\s*/).join(' ').trim()

/** Whether the body has the section, and its open items' words, in order. */
export const openQuestionsIn = (body: string): { found: boolean; open: string[] } => {
  const lines = body.split('\n')
  const s = sectionOf(lines)
  if (!s) return { found: false, open: [] }
  const open: string[] = []
  for (const l of lines.slice(s.head + 1, s.end)) {
    const m = BULLET.exec(l)
    if (!m) continue
    const box = m[1]
    if (box === 'x' || box === 'X') continue
    const words = (m[2] ?? '').trim()
    if (words) open.push(words)
  }
  return { found: true, open }
}

/**
 * The body with the question in its section: added as an open item, or checked off with its answer
 * and date (ET) when one is given. A question already there, open or answered, is left as it is
 * unless this answers an open one, so asking twice adds nothing twice. A body with no section gets
 * one, before its session line when it ends with one.
 */
export const withQuestion = (body: string, question: string, answered?: { answer: string; date: string }): string => {
  const q = oneLine(question)
  const item = answered ? `- [x] ${q} (answered ${answered.date} ET: ${oneLine(answered.answer)})` : `- [ ] ${q}`
  const lines = body.split('\n')
  const s = sectionOf(lines)
  if (!s) {
    const at = lines.findIndex(l => SESSION.test(l))
    const block = ['## Open questions', '', item]
    if (at < 0) return [...lines, '', ...block].join('\n').replace(/^\n+/, '')
    const before = lines.slice(0, at)
    while (before.length && (before[before.length - 1] as string).trim() === '') before.pop()
    return [...before, '', ...block, '', ...lines.slice(at)].join('\n')
  }
  for (let i = s.head + 1; i < s.end; i++) {
    const m = BULLET.exec(lines[i] as string)
    if (!m || wordsOf(m[2] ?? '') !== q) continue
    const isOpen = m[1] !== 'x' && m[1] !== 'X'
    if (answered && isOpen) lines[i] = item
    return lines.join('\n')
  }
  // Placed after the section's last item, or in place of None, or right under the heading.
  const none = lines.findIndex((l, i) => i > s.head && i < s.end && /^none\.?$/i.test(l.trim()))
  if (none >= 0) {
    lines[none] = item
    return lines.join('\n')
  }
  let last = -1
  for (let i = s.head + 1; i < s.end; i++) if (BULLET.test(lines[i] as string)) last = i
  if (last >= 0) lines.splice(last + 1, 0, item)
  else lines.splice(s.head + 1, 0, '', item)
  return lines.join('\n')
}
