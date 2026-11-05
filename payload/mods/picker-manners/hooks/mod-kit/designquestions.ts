// The design round guard's two questions (claude-config#978) and which asks of them it answers
// (#2253). The guard counts Dan's answer only from its own picker, a question asked with its
// metadata source, so a question in its words asked any other way lets nothing through; picker
// manners reads that here before writing an answer onto the issue, where it would read as settled.
// Pure. Kept here once and copied byte for byte into each mod that asks it
// (hooks/mod-kit/designquestions.ts, which tools/check-mod-shared-parts.sh holds to this one),
// since a mod cannot import another mod's files.

/** `metadata.source` of the skip question, followed by `:<the refused call's id>`. */
export const DESIGN_SKIP_SOURCE = 'design-round-guard'
/** `metadata.source` of the design rounds skill's closing question (payload/skills/design-rounds/SKILL.md). */
export const DESIGN_SETTLED_SOURCE = 'design-settled'
// The two questions in the plan Dan approved on #978.
export const DESIGN_SKIP_QUESTION = 'Skip design rounds for this issue?'
export const DESIGN_SETTLED_QUESTION = 'Is this design settled?'

/** Whether a question's `metadata.source` is one the design round guard asks under, and so words and answers itself. */
export const guardAsks = (source: unknown): source is string =>
  typeof source === 'string' && (source.startsWith(`${DESIGN_SKIP_SOURCE}:`) || source === DESIGN_SETTLED_SOURCE)

// Asking to skip design rounds, in the guard's sentence or reworded ("Skip design rounds for issue
// #12?", "skip the design round for ..."), or its settled sentence, spaced and cased any way. A
// question that merely mentions design rounds or a settled design is about something else.
const SKIPS = /\bskip\s+(?:the\s+)?design\s+rounds?\b/i
const SETTLED = DESIGN_SETTLED_QUESTION.toLowerCase()

/**
 * Whether a question asks what only the guard's own picker can settle, asked without it (#2253): its
 * answer records nothing the guard reads, so it must not be written anywhere as settled.
 */
export const guardIgnores = (question: string, source: unknown): boolean =>
  !guardAsks(source) && (SKIPS.test(question) || question.split(/\s+/).filter(Boolean).join(' ').toLowerCase().includes(SETTLED))
