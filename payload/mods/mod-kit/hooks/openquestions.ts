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

// The whole heading, so "## Open questions about the API" is another section (lessons review); the
// filing gate and create-milestone.sh match it the same way.
const HEADING = /^#{1,6}[ \t]*Open questions[ \t]*$/i
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
const oneLine = (q: string) => q.split(/\s+/).filter(Boolean).join(' ')
// An item's own words, without what was added when it was answered, its spacing collapsed so an item
// written by hand with other spacing is still the same question (lessons review).
// The suffix is matched from its dated start, so an answer with brackets of its own ("Keep it
// (recommended)") is taken off whole (lessons review).
const wordsOf = (text: string) => oneLine(text.replace(/ \(answered \d{4}-\d{2}-\d{2} ET: .*\)$/, ''))

const REPO = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/

/**
 * The issues a question to Dan is about: `owner/name#N` anywhere, or `issue #N` in the session's
 * repository. A bare `#N` names nothing, since it may as well be a pull request.
 */
const REFS = /\b([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#(\d+)\b|\bissue\s+#(\d+)\b/gi
export const issueRefsIn = (question: string, sessionRepo: string | null): { repo: string; issue: number }[] => {
  const out: { repo: string; issue: number }[] = []
  for (const m of question.matchAll(REFS)) {
    const repo = m[1] ?? (m[3] !== undefined ? sessionRepo : null)
    const issue = Number(m[2] ?? m[3])
    if (!repo || !REPO.test(repo) || !Number.isInteger(issue) || issue <= 0) continue
    if (!out.some(x => x.repo.toLowerCase() === repo.toLowerCase() && x.issue === issue)) out.push({ repo, issue })
  }
  return out
}

/**
 * The `issue #N` numbers a question names whatever the repository, read by the same rule as
 * issueRefsIn, so a caller that cannot tell the session's repository says exactly the ones dropped.
 */
export const bareIssuesIn = (question: string): number[] => {
  const out: number[] = []
  for (const m of question.matchAll(REFS)) {
    const issue = m[3] !== undefined ? Number(m[3]) : 0
    if (issue > 0 && !out.includes(issue)) out.push(issue)
  }
  return out
}

/** A question's own words, without the issues /sleep puts in front of them ("o/r#12 and #14: "). */
export const questionWords = (question: string): string => question.replace(/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#\d+(?: and #\d+)*:\s*/, '').trim()

const ET_DATE = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' })
/** A moment's calendar date in ET, as an answer is dated in the section. */
export const etDateOf = (ms: number): string => ET_DATE.format(ms)

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
