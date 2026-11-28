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

/** The words this mod's prose block begins with, so a turn that already holds it is not asked about prose twice. */
export const PROSE_MARK = 'Your reply leaves Dan a step in prose'
/** The words this mod's block for a call the permission check refused begins with (#3842). */
export const REFUSED_MARK = 'The permission check refused a call of yours in this turn'
/** The words this mod's block for a turn it could not read to its start begins with (#3860). */
export const UNREAD_MARK = 'Manual steps could not read this whole turn'
/**
 * Every block this mod gives: the prose one, the page one (#1811), the refused call one (#3842) and
 * the unread turn one (#3860). A turn holding any is blocked by this mod again only for a call
 * refused after it.
 */
const MARKS = [PROSE_MARK, PAGE_MARK, REFUSED_MARK, UNREAD_MARK]

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
 * conversation, 10 of subagents) were 3.3 to 4.4 KB. A longer line naming the kind is cut down to
 * its top level fields, so a refusal in it is still read (#3860) and some other record that only
 * holds those words nested inside it is not taken for one.
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

/**
 * How many bytes before the window the reader walks back through, looking for the turn's first
 * record, when the window does not hold it (#3860). Past it the reader says it stopped.
 */
export const FAR_BYTES = 400_000_000

/**
 * The reader's own limit on how long it walks back, under the limit its caller stops it at, so it
 * answers with what it read and says it stopped, where a reader stopped by its caller answers nothing.
 */
export const FAR_MS = 1_200

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
// #3860: three more things are read. A refused call's record too long to print whole is cut down to
// its top level fields by `top`, which steps over strings and nested values, so the kind is still
// read from the record itself. Each tool result is printed with the id of its call and whether it
// is an error, and each steps tool call with every id its record holds (its own among them), so a
// call that failed is told from one that pinned a step. And when the window does not hold a record
// of another prompt, the turn began before it: the reader then walks back from the window's start,
// a chunk at a time, printing the same records without Claude's texts, until it meets a record of
// another prompt or the transcript's first byte, or has gone `$far` bytes or `$ms` milliseconds,
// where it prints a line saying it stopped. The line the window's first byte lands in is read by
// that walk, whole. The walk's records are met newest first and printed oldest first.
const TURN_READ = [
  'use Time::HiRes ();',
  'my ($n, $far, $ms, $f, $tool, @marks) = @ARGV;',
  'my $t0 = Time::HiRes::time();',
  'open(my $h, "<", $f) or die "$f: $!\n";',
  'my $size = -s $h;',
  'my $start = $size > $n ? $size - $n : 0;',
  'seek($h, $start, 0) or die "reading $f: $!\n";',
  'my ($turn, $bound, %ids);',
  'sub top {',
  '  my ($l) = @_;',
  '  my ($d, $key, %v) = (0);',
  '  while ($l =~ /(["{}\\[\\]])/g) {',
  '    my $c = $1;',
  '    if ($c ne q{"}) { $d += $c eq "{" || $c eq "[" ? 1 : -1; undef $key; next; }',
  '    my $s = pos($l);',
  '    my $e = $s;',
  '    while (1) {',
  '      $e = index($l, q{"}, $e);',
  '      return () if $e < 0;',
  '      my $b = 0;',
  '      $b++ while $e - $b > $s && substr($l, $e - $b - 1, 1) eq "\\\\";',
  '      last unless $b % 2;',
  '      $e++;',
  '    }',
  '    pos($l) = $e + 1;',
  '    next unless $d == 1;',
  '    my $str = substr($l, $s, $e - $s);',
  '    if (defined $key) { $v{$key} = $str; undef $key; }',
  '    elsif ($l =~ /\\G:([^"{\\[,}\\]]+)?/gc) { if (defined $1) { $v{$str} = $1; } else { $key = $str; } }',
  '  }',
  '  return %v;',
  '}',
  'sub cut {',
  '  my ($l, $win) = @_;',
  '  if (index($l, q{"type":"user"}) >= 0) {',
  '    my $id = $l =~ /"promptId":"([^"]*)"/ ? $1 : undef;',
  '    if (defined $id) {',
  '      if ($win) { $ids{$id} = 1; $turn = $id; } elsif (!defined $turn) { $turn = $id; } elsif ($id ne $turn) { $bound = 1; }',
  '    }',
  '    my $res = $l =~ /"tool_use_id":"([^"]*)"/ ? qq(,"resultOf":"$1","isError":) . (index($l, q{"is_error":true}) >= 0 ? "true" : "false") : "";',
  `    if (index($l, q{"toolDenialKind":"${REFUSED_KIND}"}) >= 0) {`,
  `      return $l if length($l) <= ${REFUSED_BYTES};`,
  '      my %v = top($l);',
  `      if (($v{type} // "") eq "user" && ($v{toolDenialKind} // "") eq "${REFUSED_KIND}") {`,
  '        my $side = ($v{isSidechain} // "") eq "true" ? "true" : "false";',
  '        my $pid = defined $v{promptId} ? qq(,"promptId":"$v{promptId}") : "";',
  '        my $uuid = defined $v{uuid} ? qq(,"uuid":"$v{uuid}") : "";',
  `        return qq({"type":"user","isSidechain":$side$pid$uuid,"toolDenialKind":"${REFUSED_KIND}","isOurs":false,"isCutDown":true$res}\n);`,
  '      }',
  '    }',
  '    my $pid = defined $id ? qq(,"promptId":"$id") : "";',
  '    my $ours = index($l, q{"content":"Stop hook feedback:}) >= 0 && grep({ index($l, $_) >= 0 } @marks) ? "true" : "false";',
  '    return qq({"type":"user"$pid,"isOurs":$ours$res}\n);',
  '  }',
  '  return undef if index($l, q{"type":"assistant"}) < 0;',
  '  return $l if $win && index($l, q{"type":"text"}) >= 0;',
  '  return undef unless index($l, q{"type":"tool_use"}) >= 0 && index($l, qq{"name":"$tool"}) >= 0;',
  '  my $side = index($l, q{"isSidechain":true}) >= 0 ? "true" : "false";',
  '  my $calls = join(",", map { qq("$_") } $l =~ /"id":"([^"]*)"/g);',
  '  return qq({"type":"assistant","isSidechain":$side,"isPinning":true,"callIds":[$calls]}\n);',
  '}',
  'my (@win, @back, $stopped);',
  'my $head = $start > 0 ? <$h> : undef;',
  'while (my $l = <$h>) { my $o = cut($l, 1); push @win, $o if defined $o; }',
  'if ($start > 0 && keys(%ids) < 2) {',
  '  my ($pos, $tail, $went) = ($start, defined $head ? $head : "", 0);',
  '  WALK: while ($pos > 0) {',
  '    if ($went >= $far || (Time::HiRes::time() - $t0) * 1000 >= $ms) { $stopped = 1; last; }',
  '    my $len = $far - $went < 4194304 ? $far - $went : 4194304;',
  '    $len = $pos if $pos < $len;',
  '    $pos -= $len;',
  '    seek($h, $pos, 0) or die "reading $f: $!\n";',
  '    my $got = read($h, my $buf, $len);',
  '    die "reading $f: " . (defined $got ? "read $got of $len bytes" : $!) . "\n" unless defined $got && $got == $len;',
  '    $went += $len;',
  '    $buf .= $tail;',
  '    my @lines = split(/\\n/, $buf, -1);',
  '    $tail = $pos > 0 ? shift(@lines) : "";',
  '    for my $l (reverse @lines) {',
  '      next if $l eq "";',
  '      my $o = cut("$l\\n", 0);',
  '      push @back, $o if defined $o;',
  '      last WALK if $bound;',
  '    }',
  '  }',
  '}',
  'print qq({"type":"reader","isCutShort":true}\n) if $stopped;',
  'print reverse(@back), @win;',
  'close($h) or die "reading $f: $!\n";',
].join('\n')

export type TurnRead = {
  /** What Claude wrote in the turn, one entry per record, oldest first. */
  texts: string[]
  /** One of this mod's own blocks is already in the turn. */
  isOurs: boolean
  /** The prompt the turn answers, or null when the window held no record of it. */
  promptId: string | null
  /** The calls of the turn the permission check refused, with no call of the steps tool that worked after them (#3842, #3860). */
  refused: number
  /**
   * Those of `refused` that came after this mod's last block in the turn, or all of them when it
   * gave none: the ones no turn end has asked about yet (#3860). What the check holds for.
   */
  refusedUnasked: number
  /** What Claude wrote after the latest of `refusedUnasked`, oldest first: the only words that can answer it (#3860). Empty when there is none. */
  saidAfterRefusal: string[]
  /** Every call of the turn the permission check refused, answered or not. Read by the count (tools/steps-phrase-count.ts), not by the check. */
  refusedMet: number
  /** The main conversation called the steps tool in the turn and the call did not fail. Read by the count and by `refusalAsk`. */
  isPinned: boolean
  /** The reader stopped before the turn's first record, so what came before was never read (#3860). */
  isCutShort: boolean
}

type Block = { type?: unknown; name?: unknown; id?: unknown; tool_use_id?: unknown; is_error?: unknown }
type Rec = {
  type?: unknown
  promptId?: unknown
  isOurs?: unknown
  isSidechain?: unknown
  isPinning?: unknown
  callIds?: unknown
  resultOf?: unknown
  isError?: unknown
  isCutShort?: unknown
  toolDenialKind?: unknown
  message?: { content?: unknown }
}

const blocksOf = (r: Rec): Block[] => {
  const c = r.message?.content
  return Array.isArray(c) ? c.filter((b): b is Block => Boolean(b) && typeof b === 'object') : []
}

/**
 * The ids this record of Claude's holds a call of the steps tool under, or null when it holds no
 * such call: from the reader's own mark, or from the call in a record kept whole. The reader's mark
 * is by the words `"name":"<the tool>"` anywhere in the record, so another tool whose input holds
 * those words would be marked too (review of pull request 3854, cases 19 and 17: neither met in the
 * records measured), and it carries every id the record holds, the call's own among them.
 */
const pinIds = (r: Rec): string[] | null => {
  if (r.isPinning === true) return Array.isArray(r.callIds) ? r.callIds.filter((id): id is string => typeof id === 'string') : []
  const calls = blocksOf(r).filter(b => b.type === 'tool_use' && b.name === STEPS_TOOL)
  return calls.length ? calls.flatMap(b => (typeof b.id === 'string' ? [b.id] : [])) : null
}

/** The ids of the calls this tool result says failed: as the reader prints it, or in a record kept whole. */
const failedIds = (r: Rec): string[] => {
  if (typeof r.resultOf === 'string') return r.isError === true ? [r.resultOf] : []
  return blocksOf(r).flatMap(b => (b.type === 'tool_result' && b.is_error === true && typeof b.tool_use_id === 'string' ? [b.tool_use_id] : []))
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
  let refusedUnasked = 0
  let saidAfterRefusal: string[] | null = null
  let refusedMet = 0
  // Walking back, a call's result is met before the call, so a call that failed is known by then.
  const failed = new Set<string>()
  for (let i = recs.length - 1; i >= 0; i--) {
    const r = recs[i] as Rec
    if (r.type === 'assistant') {
      if (r.isSidechain === true) continue
      const ids = pinIds(r)
      if (ids !== null && !ids.some(id => failed.has(id))) {
        isPinnedLater = true
        isPinPending = true
      }
      const t = textOf(r)
      if (t !== null) pending.unshift(t)
      continue
    }
    if (r.type !== 'user') continue
    for (const id of failedIds(r)) failed.add(id)
    if (typeof r.promptId !== 'string') continue
    if (promptId === null) promptId = r.promptId
    if (r.promptId !== promptId) {
      isBounded = true
      break
    }
    if (r.toolDenialKind === REFUSED_KIND && r.isSidechain !== true) {
      refusedMet++
      if (!isPinnedLater) {
        refused++
        // A block of this mod's met already is a later one, whose turn end asked about this refusal.
        if (!isOurs) {
          refusedUnasked++
          saidAfterRefusal ??= [...pending, ...texts]
        }
      }
    }
    if (r.isOurs === true) isOurs = true
    texts.unshift(...pending)
    pending = []
    if (isPinPending) isPinned = true
    isPinPending = false
  }
  if (!isBounded) {
    texts.unshift(...pending)
    if (isPinPending) isPinned = true
  }
  return { texts, isOurs, promptId, refused, refusedUnasked, saidAfterRefusal: saidAfterRefusal ?? [], refusedMet, isPinned, isCutShort: recs.some(r => r.type === 'reader' && r.isCutShort === true) }
}

/**
 * The reader's command for the last `bytes` of the transcript at this path. One spelling, so the
 * count of what the turn end check would hold (tools/steps-phrase-count.ts) runs this same reader.
 */
export const turnReadArgv = (transcript: string, bytes: number = TURN_BYTES, far: number = FAR_BYTES, ms: number = FAR_MS): string[] => [
  'perl',
  '-e',
  TURN_READ,
  '--',
  String(bytes),
  String(far),
  String(ms),
  transcript,
  STEPS_TOOL,
  ...MARKS,
]

export type TurnRun = (argv: string[]) => Promise<{ exitCode: number; stdout: string; stderr: string; isStdoutTruncated: boolean }>
/**
 * The turn now ending, or why it could not be read (never read as an empty turn). `isUnfinished`
 * tells a read that was started and gave no whole answer (stopped at its time limit, killed, its
 * answer cut short) from a transcript that is not there to read (#3860).
 */
export type TurnAt = ({ state: 'read' } & TurnRead) | { state: 'unreadable'; why: string; isUnfinished: boolean }

/** The turn now ending in the transcript at this path, its records found by the perl `run` starts. */
export const turnAt = async (transcript: string, run: TurnRun): Promise<TurnAt> => {
  if (!transcript) return { state: 'unreadable', why: 'no transcript was given', isUnfinished: false }
  let r: Awaited<ReturnType<TurnRun>>
  try {
    r = await run(turnReadArgv(transcript))
  } catch (err) {
    return { state: 'unreadable', why: err instanceof Error ? err.message : String(err), isUnfinished: true }
  }
  // Only the reader's failure to open the transcript begins with the bare path; a failure once it
  // is reading begins "reading". What the engine answers for a process it stopped at its time
  // limit is not known, so every failure but that first one counts as a read that did not finish.
  if (r.exitCode !== 0) return { state: 'unreadable', why: r.stderr.trim() || `the transcript reader exited ${r.exitCode}`, isUnfinished: !r.stderr.startsWith(`${transcript}: `) }
  // Cut short, it lost the turn's last records, which are what it is read for.
  if (r.isStdoutTruncated) return { state: 'unreadable', why: 'the transcript reader printed more than could be read whole', isUnfinished: true }
  return { state: 'read', ...turnIn(r.stdout) }
}

/** What the turn's end asks about calls the permission check refused. */
export type RefusalAsk = { ask: 'none' } | { ask: 'refused'; calls: number } | { ask: 'unread' }

/**
 * What to ask at this turn end about refused calls (#3842, #3860). `said` is everything Claude
 * wrote in the turn, its last message included; `isHeld` whether this mod already blocked in the
 * turn, or in this chain of turn ends when the turn could not be read; `answers` whether some of
 * these texts say in one line that nothing is Dan's to do.
 *
 * A refusal no turn end has asked about is asked about, held already or not, unless Claude said
 * the line after it: the line said for an earlier refusal does not answer a later one. With none,
 * a turn that could not be read to its start is said to be unread, since a refusal in the stretch
 * never read would otherwise pass as no refusal. That is not said when the turn was already held,
 * when a step pinned in the part that was read answers whatever came before it, or when the line
 * was said anywhere in the part that was read.
 */
export const refusalAsk = (turn: TurnAt, said: readonly string[], isHeld: boolean, answers: (said: readonly string[]) => boolean): RefusalAsk => {
  if (turn.state === 'unreadable') return turn.isUnfinished && !isHeld && !answers(said) ? { ask: 'unread' } : { ask: 'none' }
  if (turn.refusedUnasked > 0) {
    // The last message may not be in the transcript yet; it comes after every refusal.
    const last = said.at(-1)
    const after = last !== undefined && turn.texts.at(-1) !== last ? [...turn.saidAfterRefusal, last] : turn.saidAfterRefusal
    return answers(after) ? { ask: 'none' } : { ask: 'refused', calls: turn.refusedUnasked }
  }
  return turn.isCutShort && !isHeld && !turn.isPinned && !answers(said) ? { ask: 'unread' } : { ask: 'none' }
}

/**
 * What a turn end is told when the turn could not be read to its start. It begins with
 * UNREAD_MARK, so the turn holding it is not told this twice and is blocked again only for a call
 * refused after it. It asks for the same one line as the block for a refused call, so one answer
 * is read by both.
 */
export const unreadStep = (): string =>
  `${UNREAD_MARK}, so a call the permission check refused in it may have gone unseen. If one was refused and left Dan something to do, put that on the steps card (${STEPS_TOOL}). If not, say exactly: "Nothing from the refusal is yours to do."`
