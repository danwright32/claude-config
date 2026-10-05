// Picker manners' pure parts (#615): the question handed to mod-kit's band (docs/mods-design.md,
// "Picker manners (#615)"), what is refused before it is asked, the limit on asking again, and
// numbered prose read as answers.

/** One AskUserQuestion question, as the tool's input carries it. */
export type Question = {
  question: string
  header: string
  multiSelect: boolean
  options: { label: string; description?: string }[]
}

/** What picker manners asks mod-kit to draw, as mod-kit's contract spells it ($.modkit.question). */
export type Ask = {
  mod: string
  id: string
  chip: string
  question: string
  options: { button: string; label: string; description?: string; chosen?: boolean }[]
  submit?: { button: string; label: string }
}

/**
 * The question as mod-kit draws it in the band (design rounds, 2026-10-04): Claude's chip and
 * question, then each option under its own button, opt1 to optN, which mod-kit numbers 1 to N. A
 * multi select question marks what is chosen and ends with Submit. The look itself is mod-kit's, the
 * one every question in the band shares (#703).
 */
export const askOf = (q: Question, chosen: readonly string[]): Ask => ({
  mod: 'picker-manners',
  id: 'question',
  chip: q.header,
  question: q.question,
  options: q.options.map((o, i) => ({
    button: `opt${i + 1}`,
    label: o.label,
    ...(o.description ? { description: o.description } : {}),
    ...(q.multiSelect && chosen.includes(o.label) ? { chosen: true } : {}),
  })),
  ...(q.multiSelect ? { submit: { button: 'submit', label: 'Submit' } } : {}),
})

/** Why a question is not asked, or undefined when it is. Read by Claude as the call's refusal. */
export const refusal = (questions: readonly Question[], ctx: { quiet: boolean; source: string | undefined; talkedPast: number }): string | undefined => {
  if (questions.length !== 1) return 'Ask one question per call: Dan answers pickers one at a time.'
  if (ctx.quiet && ctx.source === 'next-issue') return 'Dan turned off next issue pickers for this session (/pickers on brings them back). Give the suggestions as a plain list instead.'
  if (ctx.talkedPast >= 2) return 'Dan has talked past or dismissed this question twice, so it is not asked again. Carry on from what he said.'
  return undefined
}

/**
 * A question Dan talked past or dismissed, as the limit on asking again remembers it: its text and
 * chip as compared (lower case, punctuation and spacing gone, letters of every script kept) and its
 * answers, each label with its description, sorted. A pass recorded before #726 has no `answers`.
 */
export type Passed = { question: string; header: string; answers?: string[]; count: number }

// Letters and digits of every script are kept (#726: keeping only a to z and 0 to 9 made every
// question in another script compare as nothing, so any two were the same).
const norm = (s: string) =>
  s
    .normalize('NFKC')
    .toLowerCase()
    .replace(/[^\p{L}\p{M}\p{N}]+/gu, ' ')
    .trim()
const answersOf = (q: Question) => q.options.map(o => `${norm(o.label)}\u0000${norm(o.description ?? '')}`).sort()
const described = (q: Question) => q.options.some(o => norm(o.description ?? '') !== '')

// Claude rewords a question when it asks it again (#703), so the same question is the same text
// however it is written, or the same chip over the same answers, each described the same way,
// however the question is put. Answers that say nothing of their own (a bare Yes and No) mean
// whatever the question asks, so two questions under one chip with those are two questions
// (#726), and a question with no letters at all is never the same as another by its text.
const sameQuestion = (q: Question, p: Passed): boolean => {
  const text = norm(q.question)
  if (text !== '' && text === p.question) return true
  return described(q) && Array.isArray(p.answers) && norm(q.header) === p.header && JSON.stringify(answersOf(q)) === JSON.stringify(p.answers)
}

/** How many times Dan has talked past or dismissed this question this session. */
export const passedOver = (q: Question, passed: readonly Passed[]): number => passed.find(p => sameQuestion(q, p))?.count ?? 0

/** The passes with one more for this question. */
export const recordPass = (q: Question, passed: readonly Passed[]): Passed[] => {
  const i = passed.findIndex(p => sameQuestion(q, p))
  if (i < 0) return [...passed, { question: norm(q.question), header: norm(q.header), answers: answersOf(q), count: 1 }]
  return passed.map((p, n) => (n === i ? { ...p, count: p.count + 1 } : p))
}

/**
 * Numbered prose ("1. yes 2. 7 days") read as answers to the open questions in order, or undefined
 * when the text is anything else: it must be numbered from 1 throughout, with no more answers than
 * there are questions, or it is a message.
 */
export const proseAnswers = (text: string, questions: readonly Question[]): string[] | undefined => {
  const t = text.trim()
  if (!/^1[.)]\s/.test(t)) return undefined
  const parts = t.split(/(?:^|\s+)(\d+)[.)]\s+/).slice(1)
  const answers: string[] = []
  for (let i = 0; i < parts.length; i += 2) {
    if (Number(parts[i]) !== answers.length + 1) return undefined
    const a = (parts[i + 1] ?? '').trim()
    if (!a) return undefined
    answers.push(a)
  }
  if (!answers.length || answers.length > questions.length) return undefined
  return answers
}

/** The echo of prose answers, one line per question: "Q2 Window: 7 days". */
export const echoOf = (questions: readonly Question[], answers: readonly string[]): string[] => answers.map((a, i) => `Q${i + 1} ${questions[i]?.header ?? ''}: ${a}`)

/** Dan asking for next issue offers to stop for the session (the spec's two phrases). */
export const asksQuiet = (text: string): boolean => /\bno next issue\b|\bjust give me the list\b/i.test(text)

/** How an open question ended, as the hook hears it (the contract's PickersOutcome). */
export type Outcome = { kind: 'answer'; answer: string } | { kind: 'prose'; answers: string[] } | { kind: 'message' } | { kind: 'withdrawn' }

/** Whether an outcome passes over the question (spec #615 point 3: a dismissal or a talk past). */
export const passesOver = (o: Outcome): boolean => o.kind === 'message' || o.kind === 'withdrawn'

/**
 * What Claude reads when the question ended without an answer, or undefined when it was answered.
 * `passes` is how many times Dan has now passed over it, 0 when this one was not counted (a question
 * he never saw, or one another mod asked), so Claude is told to ask again only while it still may.
 */
export const refusalFor = (o: Outcome, passes: number): string | undefined => {
  const lead =
    o.kind === 'withdrawn'
      ? 'The question was withdrawn: the turn was interrupted.'
      : o.kind === 'message'
        ? 'Dan did not pick an answer: he is sending a message instead, which follows. Answer his message first.'
        : undefined
  if (lead === undefined) return undefined
  if (passes >= 2) return `${lead} He has now talked past or dismissed this question twice, so do not ask it again: carry on from what he says.`
  if (passes === 1 && o.kind === 'message') return `${lead} If this question is still unanswered after that, ask it again once; never more than once.`
  return lead
}

/** Runs `withdraw` once when the call's signal aborts (an interrupted turn), or at once if it already has. */
export const onAbort = (signal: AbortSignal | undefined, withdraw: () => void): void => {
  if (!signal) return
  if (signal.aborted) {
    withdraw()
    return
  }
  signal.addEventListener('abort', withdraw, { once: true })
}

/**
 * Whether every surface the session draws on has the band, which Claude Code raises on the terminal
 * and the desktop alone: false with nothing drawing (a claude -p or SDK run), with Dan's phone or
 * VS Code attached, or when the surfaces could not be read (null).
 */
export const bandEverywhere = (surfaces: readonly string[] | null): boolean =>
  surfaces !== null && surfaces.length > 0 && surfaces.every(s => s === 'terminal' || s === 'desktop')
