// #1608: every message Claude wrote in the turn now ending, read from the session's transcript, so a
// step handed over in an earlier message is judged as well as the last one. On 2026-10-23 a Downbeat
// turn left its step in the second to last message, and the last one, the session reflection, only
// pointed back at it ("described above"), so a hook judging `last_assistant_message` never saw it.
//
// The turn is every record since Dan's prompt. Claude Code writes that prompt's promptId on every user
// record the turn holds, its tool results and each Stop hook's feedback included, and a new promptId
// on the next prompt (measured on every transcript of the 30 days to 2026-10-23 on this Mac), so the
// turn is the records after the last user record carrying a different one.

/** The words this mod's own block begins with, so a turn that already holds it is never blocked twice. */
export const PROSE_MARK = 'Your reply leaves Dan a step in prose'

/**
 * How many bytes from the transcript's end are read. Measured over the 12,514 turns in this Mac's
 * transcripts of the 30 days to 2026-10-23: 99.7% of turns fit whole in 4 MB, and the earliest text
 * of all but 28 of them; a longer turn is read from the window's start, losing only its oldest words.
 */
export const TURN_BYTES = 4_000_000

// What perl runs: the window, read by seeking to its start, cut to Claude's text records whole and each
// user record cut to its promptId and whether it is this mod's own block, so the answer stays small
// however large the tool results in the window are. Only an unescaped key matches, so the same words
// inside a tool result, which a transcript holds escaped, do not. Perl, not tail and awk: on the last
// 4 MB of a 200 MB transcript macOS's `tail -c` took 140 ms, reading the whole file, and awk 90 to 125
// ms over its long lines, where perl reads and filters it in 15 (measured 2026-10-23). The byte count,
// the file and the mark are its arguments, never part of its text.
const TURN_READ = [
  'my ($n, $f, $mark) = @ARGV;',
  'open(my $h, "<", $f) or die "$f: $!\n";',
  'my $size = -s $h;',
  'seek($h, $size > $n ? $size - $n : 0, 0) or die "$f: $!\n";',
  'while (my $l = <$h>) {',
  '  if (index($l, q{"type":"user"}) >= 0) {',
  '    my $id = $l =~ /("promptId":"[^"]*")/ ? ",$1" : "";',
  '    my $ours = index($l, q{"content":"Stop hook feedback:}) >= 0 && index($l, $mark) >= 0 ? "true" : "false";',
  '    print qq({"type":"user"$id,"isOurs":$ours}\n);',
  '  } elsif (index($l, q{"type":"assistant"}) >= 0 && index($l, q{"type":"text"}) >= 0) {',
  '    print $l;',
  '  }',
  '}',
  'close($h) or die "$f: $!\n";',
].join('\n')

export type TurnRead = {
  /** What Claude wrote in the turn, one entry per record, oldest first. */
  texts: string[]
  /** This mod's own block is already in the turn. */
  isOurs: boolean
  /** The prompt the turn answers, or null when the window held no record of it. */
  promptId: string | null
}

type Rec = { type?: unknown; promptId?: unknown; isOurs?: unknown; isSidechain?: unknown; message?: { content?: unknown } }

const textOf = (r: Rec): string | null => {
  const c = r.message?.content
  if (!Array.isArray(c)) return null
  const parts = c.flatMap(b => (b && typeof b === 'object' && (b as { type?: unknown }).type === 'text' && typeof (b as { text?: unknown }).text === 'string' ? [(b as { text: string }).text] : []))
  return parts.length ? parts.join('\n\n') : null
}

/** The turn now ending, from what the reader printed: its texts, whether this mod already blocked in it. */
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
  for (let i = recs.length - 1; i >= 0; i--) {
    const r = recs[i] as Rec
    if (r.type === 'assistant') {
      const t = r.isSidechain === true ? null : textOf(r)
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
    texts.unshift(...pending)
    pending = []
  }
  if (!isBounded) texts.unshift(...pending)
  return { texts, isOurs, promptId }
}

export type TurnRun = (argv: string[]) => Promise<{ exitCode: number; stdout: string; stderr: string; isStdoutTruncated: boolean }>
/** The turn now ending, or why it could not be read (never read as an empty turn). */
export type TurnAt = ({ state: 'read' } & TurnRead) | { state: 'unreadable'; why: string }

/** The turn now ending in the transcript at this path, its records found by the perl `run` starts. */
export const turnAt = async (transcript: string, run: TurnRun): Promise<TurnAt> => {
  if (!transcript) return { state: 'unreadable', why: 'no transcript was given' }
  let r: Awaited<ReturnType<TurnRun>>
  try {
    r = await run(['perl', '-e', TURN_READ, '--', String(TURN_BYTES), transcript, PROSE_MARK])
  } catch (err) {
    return { state: 'unreadable', why: err instanceof Error ? err.message : String(err) }
  }
  if (r.exitCode !== 0) return { state: 'unreadable', why: r.stderr.trim() || `the transcript reader exited ${r.exitCode}` }
  // Cut short, it lost the turn's last records, which are what it is read for.
  if (r.isStdoutTruncated) return { state: 'unreadable', why: 'the transcript reader printed more than could be read whole' }
  return { state: 'read', ...turnIn(r.stdout) }
}
