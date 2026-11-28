import { TOOL } from './box.ts'

// The box waits for the end of turn review (claude-config#3843, second half). Pure, so every rule
// is tested without a session.
//
// On 2026-11-27 a session showed the box, and then the end of turn review's picker, where Dan picked
// three follow ups: the box had been called before the turn's remaining pickers were asked. His
// answer on the issue, the same day: hold the box "until the review is answered". And of how the box
// is to know (two ways were put to him): "The review says so itself". So the review keeps a record:
// lib/review-reason.py, which both review hooks build their payload through, writes that the review
// was handed to the session, and the review's last step writes that he answered it (or that it
// asked him nothing). hooks/lib/review-record.py owns that record, beside the session's transcript,
// and is the only thing that reads or writes it: the mod runs its `state` command and is told none,
// handed or answered for this turn. A record of an earlier turn is none, so a review nobody answered
// never holds a later turn's box.
//
// The record cannot say a review is still to COME, and at a call made before the turn's end it has
// not been handed over yet. So a turn that has changed something, by the review hooks' own test
// (hooks/turn-worked.py, asked as request.ts asks it), is one whose review is to come, and its box
// waits too. The hooks do not always hand a review over at such a turn's end (a stop that follows
// another Stop hook's block, a helper that failed), so a box refused this way and never shown is
// asked for once more when the turn has ended: that message is Dan's choice as well (the issue's
// comment of 2026-11-27, 1:11 PM ET), once per request, and a turn it starts has changed nothing, so
// the call it asks for is not held.
//
// Two cases are known before the turn ends to bring no review, and hold nothing: Dan asleep (the
// hooks stand down, and the mod asks scope modes' one sleep predicate), and the hooks' own switch
// for one conversation, a file beside its transcript (REVIEWS_OFF_SUFFIX below).
//
// A record that cannot be read never holds the box and is never read as answered in silence: the box
// shows, and the mod says so where Dan and a later session can see it. A box that never shows is the
// worse fault of the two.

/**
 * The review hooks' switch for one conversation: with a file of this name beside the transcript
 * (`touch <transcript>.skip-stop-hooks`) both stay silent for it, so no review is handed over and
 * the box waits for none. The name is the hooks' own (session-reflection.sh,
 * feature-issue-review.sh); tests/test-goal-box-review-record.sh fails when they stop reading it.
 */
export const REVIEWS_OFF_SUFFIX = '.skip-stop-hooks'

/** How long the read of the record may take: one file read backwards to its last prompt, two small files. */
export const REVIEW_STATE_MS = 10_000

/** Where the sync installs the record's one owner. */
export const reviewRecordFile = (home: string): string => `${home.replace(/\/+$/, '')}/.claude/hooks/lib/review-record.py`

/** The command that reads the record for the session whose transcript this is. -B: it loads a file by path. */
export const reviewStateArgv = (home: string, transcript: string): string[] => ['python3', '-I', '-B', reviewRecordFile(home), 'state', '--transcript', transcript]

/** One word in single quotes for a shell, whatever it holds (a folder on the work MacBook holds an apostrophe). */
const quoted = (word: string): string => `'${word.replace(/'/g, `'\\''`)}'`

/**
 * The review's last step as a command the session can run as it stands, naming the transcript the
 * mod itself read the record beside, so the answer lands in the record the next call reads.
 */
export const answeredCommand = (transcript: string): string => `python3 ~/.claude/hooks/lib/review-record.py answered --transcript ${quoted(transcript)}`

/** What the record says of this turn's review, or why it could not be read. */
export type ReviewRead = { state: 'none' | 'handed' | 'answered' } | { unread: string }

const STATES = ['none', 'handed', 'answered'] as const

/** The run's answer held to the record's three words: anything else is unread, never taken for none (L10, L50). */
export const reviewRead = (r: { exitCode: number; stdout: string; stderr: string }): ReviewRead => {
  if (r.exitCode !== 0) return { unread: r.stderr.trim().split('\n').pop() || `the read of the review's record exited ${r.exitCode}` }
  let said: unknown
  try {
    said = (JSON.parse(r.stdout) as { state?: unknown } | null)?.state
  } catch {
    said = undefined
  }
  const state = STATES.find(s => s === said)
  return state ? { state } : { unread: `the read of the review's record answered ${JSON.stringify(r.stdout.trim().slice(0, 80))}, which names no state` }
}

/**
 * Whether a tool call, as it arrives, is read at all for making this a turn whose end of turn
 * review is to come. Only the main conversation's: a subagent's call is not in the transcript the
 * review hooks read. Never the picker, which asks Dan and changes nothing. And never the box's own
 * tool, which the review's test would count by its name, so that a box refused for something else
 * would hold its own next call. The box's own hook answers that call and passes nothing on, so the
 * hook that reads every call does not see it today; this is what keeps the rule true if the two
 * ever change places. What is read is then put to the review's own test, by its name.
 */
export const canBeTurnWork = (call: { tool: string; agentId?: unknown }): boolean => call.agentId === undefined && call.tool !== TOOL && call.tool !== 'AskUserQuestion'

/**
 * Whether a Bash command is the review's last step for the MAIN conversation's record: the record's
 * `answered` command with no transcript named (it then finds the session by CLAUDE_CODE_SESSION_ID,
 * which a subagent's Bash call carries too, as the main session's id: read in a subagent's own shell
 * on 2026-11-27), or naming this session's transcript, quoted as the refusal writes it or not. With
 * this session's transcript unknown, any `answered` is taken as the main conversation's: which
 * record it would mark cannot be told. One naming another transcript, as a test of the record does,
 * is not. Only a subagent's call is put to this (register.ts): a subagent, or a fork that inherited
 * the review's instruction, would otherwise mark the main session's review answered while Dan still
 * has its picker open.
 */
export const answersMainReview = (command: string, transcript: string | undefined): boolean => {
  if (!/review-record\.py["']?\s+answered(?![\w-])/.test(command)) return false
  if (!/\s--transcript[\s=]/.test(command) || transcript === undefined) return true
  return command.includes(transcript) || command.includes(quoted(transcript))
}

/** What a subagent is told when its Bash call would answer the main conversation's review. */
export const notMainReviewText = (): string =>
  `Not run: only the main conversation records that its end of turn review was answered, as that review's last step, and this command would record it for the main conversation from a subagent. Leave it to the main conversation. To try the record's \`answered\` command itself, name a transcript of your own with --transcript.`

/** Whether this turn has had a call the review hooks' test counts, or why that could not be read. */
export type TurnWork = { worked: boolean; unread?: string }

/** The box waits (and the session is told what to do), or shows though something could not be read, or shows. */
export type ReviewWait = { hold: string } | { unread: string } | null

const WAITS = 'the box waits until Dan has answered the end of turn review'
const LAST_STEP = (command: string) => `Once Dan has answered what the review asked, or it asked him nothing, run \`${command}\` and then call this tool again, as the review's last step`

// What a refusal says of the turn's end. The one message is sent once for a request, and not at all
// after a review handed over for it went unanswered (register.ts askAfterReview), so a refusal made
// after either must not promise it: the session would wait for a message that never comes.
const ASKED_ONCE = 'If no review is handed to you when the turn ends, you are asked once to call this tool again.'
const NOT_ASKED_AGAIN =
  'Nothing asks you to call this tool again when this turn ends: that is done once for a request, and for this one it has been done or a review handed over for it was left unanswered. The box for this request now comes only through a review that is handed to you and answered.'

/**
 * Whether the review holds a box that would otherwise show. Handed and not answered: held, whatever
 * the turn did. Answered: shown. None: held only in a turn that has changed something, where the
 * review is still to come. Unread, either reading: shown, and said. `spent` says this request's one
 * message at a turn's end has been sent, or given up over an unanswered review.
 */
export const reviewWait = (q: { read: ReviewRead; work: TurnWork | undefined; command: string; spent?: boolean }): ReviewWait => {
  const { read, work, command } = q
  if ('unread' in read) return { unread: `the end of turn review's record could not be read (${read.unread})` }
  if (read.state === 'answered') return null
  if (read.state === 'handed')
    return { hold: `No box yet: the end of turn review was handed to you this turn and is not on record as answered, and ${WAITS}. Finish the review first. ${LAST_STEP(command)}.` }
  if (work?.worked)
    return {
      hold: `No box yet: this turn has changed something, so its end of turn review is still to come, and ${WAITS}. End your turn without the box. When the review is handed to you, do it. ${LAST_STEP(command)}. ${q.spent ? NOT_ASKED_AGAIN : ASKED_ONCE}`,
    }
  if (work?.unread !== undefined) return { unread: `whether this turn changed something, and so whether an end of turn review is still to come, could not be read (${work.unread})` }
  return null
}

/** What is logged, and kept for the close card's reasons file, when a box was shown over a reading that failed. */
export const shownUnreadText = (why: string): string => `The Goal accomplished box was shown without waiting for the end of turn review: ${why}.`

/**
 * What Dan is told when the mod sent the session a prompt about the box at a turn's end over a
 * record that could not be read: a review he has not answered would have stopped the prompt, and
 * whether there is one is not known.
 */
export const promptedUnreadText = (why: string): string =>
  `The session was sent a prompt about the Goal accomplished box without knowing whether an end of turn review is waiting for Dan: the end of turn review's record could not be read (${why}).`

/**
 * What the session is told, once per request, when a box was refused until the review had been
 * answered and the turn then ended with no box shown.
 */
export const askAgainText = (): string =>
  `GOAL ACCOMPLISHED BOX WAITING. Earlier in this request a call to ${TOOL} was refused until the end of turn review had run and Dan had answered it. That turn has ended and no box was shown since. If every part of what Dan asked for is finished, call ${TOOL} again now, with goal set to what he asked for and shipped listing what shipped, one short line each. Call it before anything else in this turn: a command or an edit first, the review's last step included, makes this a turn with a review of its own to come, and the call waits again. If part of it is still to do, do not call it and say nothing of the box.`
