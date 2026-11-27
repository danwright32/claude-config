// #1608: every message Claude wrote in the turn now ending, read from the session's transcript, so a
// step handed over in an earlier message is judged as well as the last one. On 2026-10-23 a Downbeat
// turn left its step in the second to last message, and the last one, the session reflection, only
// pointed back at it ("described above"), so a hook judging `last_assistant_message` never saw it.
//
// The turn is every record since Dan's prompt. Claude Code writes that prompt's promptId on every user
// record the turn holds, its tool results and each Stop hook's feedback included, and a new promptId
// on the next prompt (measured on every transcript of the 30 days to 2026-10-23 on this Mac), so the
// turn is the records after the last user record carrying a different one.

import { PAGE_MARK } from './page.ts'

/** The words this mod's prose block begins with, so a turn that already holds it is never blocked twice. */
export const PROSE_MARK = 'Your reply leaves Dan a step in prose'
/** The words this mod's block for a call the permission check refused begins with (#3842). */
export const REFUSED_MARK = 'The permission check refused a call of yours in this turn'
/** Every block this mod gives: the prose one, the page one (#1811) and the refused call one (#3842). A turn holding any is never blocked by this mod again. */
const MARKS = [PROSE_MARK, PAGE_MARK, REFUSED_MARK]

// #3842: a call the permission check refused, read from Claude Code's own record of its result and
// never from words. The record of a refused call carries `toolDenialKind`, measured on 2026-11-27
// over the main conversations' records of 30 days on the personal MacBook (Claude Code 2.1.311 to
// 2.1.332): 22 `automode-blocked` (the permission check's verdict; each one's result began with
// its "denied by the auto mode classifier" sentence), 93 `automode-unavailable` (it gave no
// verdict, which is sent once more by rule and is no step for Dan), 1,938 `permission-rule` (a
// hook's or a rule's refusal: too many to hold for, so a step one leaves is caught only by the
// wording check; what each said in its place was not measured), 65 `user-rejected` (Dan declined
// a prompt, so he knows) and 12 cancelled or interrupted; 10 more `automode-blocked` were in
// subagents' own records, which this reader is never handed. Only the first counts here. No hook on the refusal
// itself is used: a mod's hook on `classic.PermissionDenied` needs an entry on two lists of
// exceptions (tools/sec-default-bypassed-hooks.tsv, tests/test-sleep-silence.sh), and what that
// event calls no verdict is the word "Classifier unavailable", read by scope modes alone.
// Claude Code documents neither the field nor its spelling, and the reader finds it by its exact
// unspaced text, so a release that renames or respaces it would stop this hold with nothing said.
// The count's last line (tools/steps-phrase-count.ts) finds refused calls a second way, by the
// sentence their result begins with, and says how many of those this reader would not read.
export const REFUSED_KIND = 'automode-blocked'
/** The tool whose call after a refusal answers it: the step went on the card. */
export const STEPS_TOOL = 'mcp__manual-steps__steps'
/**
 * The longest record of a refused call kept whole. The 32 measured on 2026-11-27 (22 of the main
 * conversation, 10 of subagents) were 3.3 to 4.4 KB; a longer
 * line naming the kind is some other record that holds those words, and is cut down like any other.
 */
export const REFUSED_BYTES = 65_536

/**
 * How many bytes from the transcript's end are read. Measured over the 12,514 turns in this Mac's
 * transcripts of the 30 days to 2026-10-23: 99.7% of turns fit whole in 4 MB, and the earliest text
 * of all but 28 of them; a longer turn is read from the window's start, losing only its oldest words.
 */
export const TURN_BYTES = 4_000_000

/**
 * How long the turn's transcript may take to read at a turn end: chosen, not measured, at well over
 * the 15 ms the largest transcript on this Mac took (200 MB, measured 2026-10-23).
 */
export const TURN_TIMEOUT_MS = 2_000

// What perl runs: the window, read by seeking to its start, cut to Claude's text records whole and each
// user record cut to its promptId and whether it is this mod's own block, so the answer stays small
// however large the tool results in the window are. Only an unescaped key matches, so the same words
// inside a tool result, which a transcript holds escaped, do not. Perl, not tail and awk: on the last
// 4 MB of a 200 MB transcript macOS's `tail -c` took 140 ms, reading the whole file, and awk 90 to 125
// ms over its long lines, where perl reads and filters it in 15 (measured 2026-10-23). The byte count,
// the file, the steps tool and the marks are its arguments, never part of its text.
// #3842: the record of a call the permission check refused is printed whole, being small, so its kind
// is read from the record itself; and a call of the steps tool with no text beside it is printed as a
// mark of its own, so a step pinned after a refusal is seen in its place in the turn.
const TURN_READ = [
  'my ($n, $f, $tool, @marks) = @ARGV;',
  'open(my $h, "<", $f) or die "$f: $!\n";',
  'my $size = -s $h;',
  'seek($h, $size > $n ? $size - $n : 0, 0) or die "$f: $!\n";',
  'while (my $l = <$h>) {',
  '  if (index($l, q{"type":"user"}) >= 0) {',
  `    if (index($l, q{"toolDenialKind":"${REFUSED_KIND}"}) >= 0 && length($l) <= ${REFUSED_BYTES}) { print $l; next; }`,
  '    my $id = $l =~ /("promptId":"[^"]*")/ ? ",$1" : "";',
  '    my $ours = index($l, q{"content":"Stop hook feedback:}) >= 0 && grep({ index($l, $_) >= 0 } @marks) ? "true" : "false";',
  '    print qq({"type":"user"$id,"isOurs":$ours}\n);',
  '  } elsif (index($l, q{"type":"assistant"}) >= 0 && index($l, q{"type":"text"}) >= 0) {',
  '    print $l;',
  '  } elsif (index($l, q{"type":"assistant"}) >= 0 && index($l, q{"type":"tool_use"}) >= 0 && index($l, qq{"name":"$tool"}) >= 0) {',
  '    my $side = index($l, q{"isSidechain":true}) >= 0 ? "true" : "false";',
  '    print qq({"type":"assistant","isSidechain":$side,"isPinning":true}\n);',
  '  }',
  '}',
  'close($h) or die "$f: $!\n";',
].join('\n')

export type TurnRead = {
  /** What Claude wrote in the turn, one entry per record, oldest first. */
  texts: string[]
  /** One of this mod's own blocks is already in the turn. */
  isOurs: boolean
  /** The prompt the turn answers, or null when the window held no record of it. */
  promptId: string | null
  /** The calls of the turn the permission check refused, with no call of the steps tool after them (#3842). */
  refused: number
  /** Every call of the turn the permission check refused, answered or not. Read by the count (tools/steps-phrase-count.ts), not by the check. */
  refusedMet: number
  /** The main conversation called the steps tool in the turn. Read by the count, not by the check, which reads the card itself. */
  isPinned: boolean
}

type Rec = { type?: unknown; promptId?: unknown; isOurs?: unknown; isSidechain?: unknown; isPinning?: unknown; toolDenialKind?: unknown; message?: { content?: unknown } }

/**
 * Whether this record of Claude's holds a call of the steps tool: the reader's own mark, or the call
 * in a record kept whole. It is the call that is seen, never its result, so a call the steps tool
 * refused (a step with no place, say) still answers a refusal before it; rare, and the tool's own
 * refusal already tells Claude what to do. The reader's mark is by the words `"name":"<the tool>"`
 * anywhere in the record, so another tool whose input holds those words would be marked too
 * (review of pull request 3854, cases 19 and 17: neither met in the records measured).
 */
const pins = (r: Rec): boolean => {
  if (r.isPinning === true) return true
  const c = r.message?.content
  return Array.isArray(c) && c.some(b => b && typeof b === 'object' && (b as { type?: unknown }).type === 'tool_use' && (b as { name?: unknown }).name === STEPS_TOOL)
}

const textOf = (r: Rec): string | null => {
  const c = r.message?.content
  if (!Array.isArray(c)) return null
  const parts = c.flatMap(b => (b && typeof b === 'object' && (b as { type?: unknown }).type === 'text' && typeof (b as { text?: unknown }).text === 'string' ? [(b as { text: string }).text] : []))
  return parts.length ? parts.join('\n\n') : null
}

/**
 * The turn now ending, from what the reader printed: its texts, whether this mod already blocked in
 * it, the prompt it answers, and the calls in it the permission check refused (#3842), those left
 * with no steps tool call after them and all of them.
 */
export const turnIn = (out: string): TurnRead => {
  const recs: Rec[] = []
  for (const line of out.split('\n')) {
    if (!line.trim()) continue
    try {
      const o: unknown = JSON.parse(line)
      if (o && typeof o === 'object') recs.push(o as Rec)
    } catch {
      // The window's first line is cut short, and is no record.
    }
  }
  let promptId: string | null = null
  let isOurs = false
  const texts: string[] = []
  // Texts seen walking back since the last record of this turn's prompt: the turn's if the window
  // starts inside the turn, the turn before's once a record of another prompt is reached.
  let pending: string[] = []
  let isBounded = false
  // Walking back, so a call of the steps tool already met is one made later than the record in hand.
  // One met past the turn's first record belongs to the turn before, whose refusals are not counted.
  let isPinnedLater = false
  // Whether a steps tool call met is the turn's is known, like a text, only once a record of the
  // turn's prompt is met before it, or the window turns out to start inside the turn.
  let isPinned = false
  let isPinPending = false
  let refused = 0
  let refusedMet = 0
  for (let i = recs.length - 1; i >= 0; i--) {
    const r = recs[i] as Rec
    if (r.type === 'assistant') {
      if (r.isSidechain === true) continue
      if (pins(r)) {
        isPinnedLater = true
        isPinPending = true
      }
      const t = textOf(r)
      if (t !== null) pending.unshift(t)
      continue
    }
    if (r.type !== 'user' || typeof r.promptId !== 'string') continue
    if (promptId === null) promptId = r.promptId
    if (r.promptId !== promptId) {
      isBounded = true
      break
    }
    if (r.isOurs === true) isOurs = true
    if (r.toolDenialKind === REFUSED_KIND && r.isSidechain !== true) {
      refusedMet++
      if (!isPinnedLater) refused++
    }
    texts.unshift(...pending)
    pending = []
    if (isPinPending) isPinned = true
    isPinPending = false
  }
  if (!isBounded) {
    texts.unshift(...pending)
    if (isPinPending) isPinned = true
  }
  return { texts, isOurs, promptId, refused, refusedMet, isPinned }
}

/**
 * The reader's command for the last `bytes` of the transcript at this path. One spelling, so the
 * count of what the turn end check would hold (tools/steps-phrase-count.ts) runs this same reader.
 */
export const turnReadArgv = (transcript: string, bytes: number = TURN_BYTES): string[] => ['perl', '-e', TURN_READ, '--', String(bytes), transcript, STEPS_TOOL, ...MARKS]

export type TurnRun = (argv: string[]) => Promise<{ exitCode: number; stdout: string; stderr: string; isStdoutTruncated: boolean }>
/** The turn now ending, or why it could not be read (never read as an empty turn). */
export type TurnAt = ({ state: 'read' } & TurnRead) | { state: 'unreadable'; why: string }

/** The turn now ending in the transcript at this path, its records found by the perl `run` starts. */
export const turnAt = async (transcript: string, run: TurnRun): Promise<TurnAt> => {
  if (!transcript) return { state: 'unreadable', why: 'no transcript was given' }
  let r: Awaited<ReturnType<TurnRun>>
  try {
    r = await run(turnReadArgv(transcript))
  } catch (err) {
    return { state: 'unreadable', why: err instanceof Error ? err.message : String(err) }
  }
  if (r.exitCode !== 0) return { state: 'unreadable', why: r.stderr.trim() || `the transcript reader exited ${r.exitCode}` }
  // Cut short, it lost the turn's last records, which are what it is read for.
  if (r.isStdoutTruncated) return { state: 'unreadable', why: 'the transcript reader printed more than could be read whole' }
  return { state: 'read', ...turnIn(r.stdout) }
}
