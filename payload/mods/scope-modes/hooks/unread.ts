// A morning picker Dan could not read as written (#3321). Sleep mode records his answer to a
// picker naming a number this session offered: a question's (3.n, kept answered so no later morning
// asks it again) or a proposal's (1.n, where what he leaves unselected is declined for good). His
// answer covers the picker because he read it, so such a picker is first judged as the dialog will
// get it by the one check of text a person approves in a picker (mod-kit's hooks/shown.ts), and one
// that fails is refused before he is asked. Pure: the numbers offered are handed in.
import { askFault } from './mod-kit/shown.ts'
import { declinedIn } from './proposals.ts'
import { answeredIn } from './settled.ts'

/**
 * Whether Dan's answer to a picker would be recorded: it names a number this session offered.
 * Asked of the two readers that record (answeredIn, declinedIn), with a stand in answer to every
 * question, so a picker is read here exactly as they will read it once he has answered, and a
 * number neither would act on is no reason to judge it.
 */
export const recordsAnswer = (questions: unknown, asked: ReadonlySet<string>, offered: ReadonlySet<string>): boolean => {
  if (!Array.isArray(questions) || (!asked.size && !offered.size)) return false
  const standIn = Object.fromEntries((questions as { question?: unknown }[]).map(q => [String(q?.question ?? ''), 'x']))
  return answeredIn(questions, standIn, asked).length > 0 || declinedIn(questions, standIn, offered).length > 0
}

/**
 * Why a picker whose answer would be recorded would not reach Dan as written, as the refusal the
 * session is given, or undefined when it would, or when nothing would be recorded from it. One
 * set of limits for every picker: a picker too long or too tall is asked in parts, never let
 * through.
 */
export const unreadMorningPicker = (input: Record<string, unknown>, asked: ReadonlySet<string>, offered: ReadonlySet<string>): string | undefined => {
  if (!recordsAnswer(input.questions, asked, offered)) return undefined
  const unread = askFault(input)
  if (unread === undefined) return undefined
  return `${unread.what} would not reach Dan as written: ${unread.fault}. His answer to this picker is recorded, and he answers for the words he can read whole, so nothing was asked and nothing is recorded. Ask it again in plain words without what is at fault, each number where it was, and in more than one picker, one after another, where it is too long or too tall for one.`
}
