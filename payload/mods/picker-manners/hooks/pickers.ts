// Picker manners' pure parts (#615): the question as the band draws it (docs/mods-design.md,
// "Picker manners (#615)"), what is refused before it is asked, and numbered prose read as answers.

/** One AskUserQuestion question, as the tool's input carries it. */
export type Question = {
  question: string
  header: string
  multiSelect: boolean
  options: { label: string; description?: string }[]
}

/** A band row's parts, as mod-kit's contract spells them. */
export type Part = { text: string; color?: string; bold?: boolean; dim?: boolean; indent?: number } | { button: string; label: string; hotkey?: string }

/**
 * The question in the band (design rounds, 2026-10-04): the chip in grey and the question in amber,
 * as it waits on Dan, on one line; then each option on its own line, numbered, its description
 * indented on the line under it. A multi select question marks what is chosen and ends with Submit.
 */
export const bandLines = (q: Question, chosen: readonly string[]): Part[][] => {
  const lines: Part[][] = [[{ text: `[${q.header}] `, dim: true }, { text: q.question, color: 'warning', bold: true }]]
  q.options.forEach((o, i) => {
    const n = String(i + 1)
    const line: Part[] = [{ text: `${n}. ` }, { button: `opt${n}`, label: o.label, hotkey: n }]
    if (q.multiSelect && chosen.includes(o.label)) line.push({ text: ' chosen', dim: true })
    lines.push(line)
    if (o.description) lines.push([{ text: o.description, dim: true, indent: 3 }])
  })
  if (q.multiSelect) lines.push([{ button: 'submit', label: 'Submit' }])
  return lines
}

/** Why a question is not asked, or undefined when it is. Read by Claude as the call's refusal. */
export const refusal = (questions: readonly Question[], ctx: { quiet: boolean; source: string | undefined; talkedPast: number }): string | undefined => {
  if (questions.length !== 1) return 'Ask one question per call: Dan answers pickers one at a time.'
  if (ctx.quiet && ctx.source === 'next-issue') return 'Dan turned off next issue pickers for this session (/pickers on brings them back). Give the suggestions as a plain list instead.'
  if (ctx.talkedPast >= 2) return 'Dan has talked past this question twice, so it is not asked again. Carry on from what he said.'
  return undefined
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
