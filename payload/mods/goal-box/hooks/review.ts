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

const RECORD_FILE = 'review-record.py'

/** The part of a word after its last slash. */
const lastPart = (word: string): string => word.slice(word.lastIndexOf('/') + 1)

/** Whether the shell may hand a word on as something the call's own text does not spell. */
const unspelled = (word: string): boolean => /[$`*?[]/.test(word)

/** A path as written, with a leading ~ or $HOME put in full and its doubled slashes and dots worked out. */
const plainPath = (path: string, home: string | undefined): string => {
  const full = home === undefined ? path : path.replace(/^(?:~|\$HOME|\$\{HOME\})(?=\/|$)/, home.replace(/\/+$/, ''))
  const out: string[] = []
  for (const part of full.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') out.pop()
    else out.push(part)
  }
  return `${full.startsWith('/') ? '/' : ''}${out.join('/')}`
}

/**
 * Whether one command, as mod-kit's reader gives it, runs the record's `answered` for the MAIN
 * conversation's record. Judged by what the command runs, never by how the call is spelled:
 *
 * - It must run the record's file as a script: an interpreter's script operand, or the file run by
 *   its own name. A grep for the phrase, a commit message or an echo that quotes it, `python -m` and
 *   inline code run no such script. A script named by a value the call does not spell could be it.
 * - Its first operand, read as the file's own parser reads it (each option takes a value), must be
 *   `answered`, or a value the call does not spell, or one xargs hands over.
 * - With no transcript named it finds the session by CLAUDE_CODE_SESSION_ID, which a subagent's
 *   Bash call carries too, as the main session's id (read in a subagent's own shell on 2026-11-27).
 *   Naming one, it is the main conversation's when the file's name is this session's transcript's
 *   and the folders cannot be told apart, or when the name is not spelled out; another file's name,
 *   as a test of the record uses, is not. With this session's transcript unknown, any is.
 * - A command the reader could not read (eval, a command a value names) is judged by its words'
 *   text, the one place spelling decides: it answers when they hold the file's name and the word.
 *
 * What the call's text cannot show is not seen: a script file whose own lines run the command.
 */
const answersIn = (c: { words: string[]; script?: string; unread: boolean; xargs: boolean; followed: (string | null)[] }, transcript: string | undefined, home: string | undefined): boolean => {
  const { words } = c
  if (c.unread) return words.some(w => w.includes(RECORD_FILE)) && words.some(w => /(^|[^\w-])answered(?![\w-])/.test(w))
  const at = c.script !== undefined ? words.indexOf(c.script, 1) : lastPart(words[0] ?? '') === RECORD_FILE ? 0 : -1
  if (at < 0) return false
  const said = (i: number): string => c.followed[i] ?? (words[i] as string)
  const file = lastPart(said(at))
  if (!unspelled(file) && file !== RECORD_FILE) return false
  let command: string | undefined
  let named: string | undefined
  for (let i = at + 1; i < words.length; i++) {
    const word = said(i)
    if (word === '--') continue
    if (word.startsWith('--')) {
      const eq = word.indexOf('=')
      const value = eq < 0 ? (++i < words.length ? said(i) : '') : word.slice(eq + 1)
      if ('--transcript'.startsWith(eq < 0 ? word : word.slice(0, eq))) named = value
    } else if (command === undefined) command = word
  }
  if (command === undefined ? !c.xargs : command !== 'answered' && !unspelled(command)) return false
  if (!named || transcript === undefined) return true
  const name = lastPart(named)
  if (unspelled(name)) return true
  if (name !== lastPart(transcript)) return false
  if (unspelled(plainPath(named, home)) || !plainPath(named, home).startsWith('/')) return true
  return plainPath(named, home) === plainPath(transcript, home)
}

/**
 * Whether a Bash call would record the MAIN conversation's review as answered, from the commands
 * mod-kit's reader read in it (`pipeline`, asked with `follow`); the rules are on answersIn. Only a
 * subagent's call is put to this (register.ts): a subagent, or a fork that inherited the review's
 * instruction, would otherwise mark the main session's review answered while Dan still has its
 * picker open. A reading that is no list of commands answers by `spelled`, the call's text.
 */
export const answersMainReview = (commands: unknown, transcript: string | undefined, home: string | undefined, spelled = ''): boolean => {
  if (!Array.isArray(commands)) return spelled.includes(RECORD_FILE) && /(^|[^\w-])answered(?![\w-])/.test(spelled)
  return commands.some(raw => {
    const c = (typeof raw === 'object' && raw !== null ? raw : {}) as { words?: unknown; script?: { files?: unknown }; unread?: unknown; xargs?: unknown; followed?: unknown }
    const words = Array.isArray(c.words) ? c.words.filter((w): w is string => typeof w === 'string') : []
    if (!words.length) return false
    const files = Array.isArray(c.script?.files) ? c.script.files : []
    const followed = Array.isArray(c.followed) ? words.map((_, i) => (typeof (c.followed as unknown[])[i] === 'string' ? ((c.followed as unknown[])[i] as string) : null)) : words.map(() => null)
    return answersIn({ words, script: typeof files[0] === 'string' ? files[0] : undefined, unread: typeof c.unread === 'string', xargs: c.xargs === true, followed }, transcript, home)
  })
}

/** The call's text before any reading of it: whether it is worth the reader at all. */
export const namesRecordFile = (command: string): boolean => command.replace(/["'\\\n]/g, '').includes(RECORD_FILE)

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
// after either must not promise it: the session would wait for a message that never comes. A box
// refused so is still asked for once after Dan's next message (register.ts askOwed).
const ASKED_ONCE = 'If no review is handed to you when the turn ends, you are asked once to call this tool again.'
const NOT_ASKED_AGAIN =
  "Nothing asks you to call this tool again when this turn ends: that is done once for a request, and for this one it has been done or a review handed over for it was left unanswered. The box for this request now comes through a review that is handed to you and answered, or is asked for once after Dan's next message."

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
 * What Dan is told, in a line he sees, once per request, when a prompt of this mod about the box
 * was held back at a turn's end over a review handed over that turn and not on record as answered
 * (#3843). The record reads the same when he left a picker unanswered, when the session did the
 * review and skipped its last step, and when the hand over was recorded and never reached the
 * session, and nothing the mod holds tells them apart (a question asked in prose leaves no picker
 * either), so the line says what is on record and what happens next, and guesses at none of the
 * three. `goal` is the prompt for a met /goal, which waits
 * for a later turn's end; any other is asked for after his next message (askOwedText).
 */
export const waitingText = (kind: 'request' | 'goal'): string =>
  kind === 'goal'
    ? 'The Goal accomplished box for the met /goal is waiting on the end of turn review, which is not on record as answered. The session is asked for it at the end of a later turn.'
    : 'The Goal accomplished box is waiting on the end of turn review, which is not on record as answered, so the session was not asked for it. It is asked for once at the end of a turn after your next message.'

/**
 * What the session is told, once, at a turn's end after a message Dan typed, when the box of an
 * earlier request of his was held for the review and never shown. Worded for a request that has
 * passed: he has asked for something since, so it never says "this request".
 */
export const askOwedText = (): string =>
  `GOAL ACCOMPLISHED BOX FROM AN EARLIER REQUEST. For an earlier request of Dan's in this session the Goal accomplished box was held back for the end of turn review, and no box has been shown since. He has sent a message since then. If every part of what he asked for is finished, call ${TOOL} now, with goal set to what he asked for and shipped listing what shipped, one short line each. Call it before anything else in this turn: a command or an edit first makes this a turn with a review of its own to come, and the call waits again. If part of it is still to do, or his message since has changed what he wants, do not call it and say nothing of the box.`

/**
 * What the session is told, once per request, when a box was refused until the review had been
 * answered and the turn then ended with no box shown.
 */
export const askAgainText = (): string =>
  `GOAL ACCOMPLISHED BOX WAITING. Earlier in this request a call to ${TOOL} was refused until the end of turn review had run and Dan had answered it. That turn has ended and no box was shown since. If every part of what Dan asked for is finished, call ${TOOL} again now, with goal set to what he asked for and shipped listing what shipped, one short line each. Call it before anything else in this turn: a command or an edit first, the review's last step included, makes this a turn with a review of its own to come, and the call waits again. If part of it is still to do, do not call it and say nothing of the box.`
