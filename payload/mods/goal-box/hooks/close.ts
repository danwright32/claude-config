// The close this session card (claude-config#3770), apart from the session: its words, how long the
// session must stay quiet first, and the two readings of a process a command left behind.
//
// Dan, 2026-11-26: "When a session is totally done, like all hooks are done running and nothing is
// waiting on me and the session is 100% idle with no exceptions, meaning no shells/prcesses/etc, put
// up a manual steps card telling me to close the session". His answers the same day: only a session
// that did work, once everything it opened is finished (3.67.1); after the Goal accomplished box and
// every clean reading, down on any new message, its words claiming only that nothing is running or
// waiting (3.70.1); and for a process a command left behind, "Narrow it, say what is left" (3.76.1):
// two readings that can only withhold the card, and the heading says what this session can see.

/** The card's heading, said once here: every place that shows or checks it reads this. */
export const CLOSE_HEADING = 'Nothing this session can see is running or waiting'
/** The card's one step. */
export const CLOSE_TITLE = 'Close this session if you have nothing more for it'

/**
 * How long the session must stay quiet after its turn ends before the card goes up: 3 minutes 30
 * seconds, longer than the subagent harvest's 180 second limit by a margin of 30 seconds, so that
 * async end of turn hook, still running after a stop where nothing a mod reads can see it, has ended.
 * That limit is the "timeout" of hooks/subagent-issue-harvest.sh in payload/settings.hooks.json. A mod
 * cannot read a file outside its own folder, so this stays a plain literal, and
 * tests/test-close-card-quiet-period.sh fails if the two drift. One constant, on the engine's clock,
 * which a test moves.
 */
export const QUIET_MS = 210_000

/** The longest the look for a process carrying this session's id may take; past it, it says nothing. */
export const PROCESS_TIMEOUT_MS = 5_000

/** Why the card is not pinned when no box was shown for Dan's latest request. */
export const NO_BOX = "no Goal accomplished box was shown for Dan's latest request, so the work he asked for is not known to be finished"

/**
 * Reading B (Dan, 3.76.1): a command this session ran that may have put a process where a
 * foreground call leaves it running, read from mod-kit's one reader of a shell command, never a
 * pattern of this mod's. What it did, said without the command's own text, or undefined for one that
 * did none of it. A lone & (the reader's `background`), nohup or setsid in front of a command (the
 * reader looks past each, `behind`), or disown; and a command the reader could not read in full,
 * which may have done any of them.
 */
const DETACHERS = new Set(['nohup', 'setsid', 'disown'])
export const leftBehindBy = (commands: unknown): string | undefined => {
  if (!Array.isArray(commands)) return 'could not be read in full (the reader gave no list of commands)'
  for (const raw of commands) {
    const c = (typeof raw === 'object' && raw !== null ? raw : {}) as { words?: unknown; behind?: unknown; background?: unknown; unread?: unknown }
    if (c.background === true) return 'put a process in the background with &'
    const behind = Array.isArray(c.behind) ? c.behind.find(b => typeof b === 'string' && DETACHERS.has(b)) : undefined
    if (behind) return `ran a command under ${behind}`
    const first = Array.isArray(c.words) ? c.words[0] : undefined
    if (typeof first === 'string' && DETACHERS.has(first)) return `ran ${first}`
    if (typeof c.unread === 'string') return `could not be read in full (${c.unread})`
  }
  return undefined
}

/** The reason reading B writes, for the rest of the session. */
export const leftBehindReason = (what: string) =>
  `a command this session ran ${what}, so a process it started may still be running where this session cannot see it; the card stays down for the rest of this session`

/**
 * Reading A (Dan, 3.76.1): the processes of this user that carry this session's id in their
 * environment (Claude Code sets CLAUDE_CODE_SESSION_ID in every shell it runs, and a process a
 * command leaves behind keeps it). Read through the kernel (sysctl KERN_PROCARGS2), since ps shows
 * no process's environment on this macOS. Measured on the personal MacBook on 2026-11-26, one sample
 * each: a left behind node was found, a left behind sleep was not (an Apple signed program shows no
 * environment), and another session's processes were not matched.
 *
 * Carrying the id is not being left behind (#3770, reopened): Claude Code starts the session's
 * connected servers with the id too, and they run for as long as the session is open, so Dan's
 * first real test was withheld by six of them. A carrier is left behind only when its parents no
 * longer lead to the session's own process. Nothing a mod can read names that process, so it is
 * found from the look itself, which the session starts: the session's own process is on the look's
 * own line of parents, and a carrier whose parents meet that line is still attached. A process
 * whose parent has exited is given to launchd (pid 1), never to a grandparent, so a carrier's line
 * that reaches launchd without meeting the look's has been left behind. Parents are followed by
 * pid and parent pid as ps reads them, never by a command's text. Measured on the personal MacBook
 * on 2026-11-26, one sample, in a session with two connected servers: five carriers led to the
 * session's process (the two servers, a helper of each, and a command still running) and two had
 * launchd for a parent.
 *
 * It is handed this user's processes as `ps -x -o pid=,ppid=,comm=` lists them on its standard
 * input. That list was taken before the look started, so the look is not in it, and nor is any
 * process started since that the look descends from. The look's own parent is read from the system
 * (os.getppid), and a process on its own line that the list lacks has its parent read from the
 * kernel's record of it (sysctl kern.proc.pid, the parent pid at byte 560 of the record on 64 bit
 * macOS; measured 2026-11-26 on the personal MacBook against ps for 380 processes: 379 equal, one
 * gone between the two reads, none differing). That record is trusted only when it gives the
 * look's own parent as the system does. A carrier's parents are read from the list alone.
 *
 * It prints {"found": [{"pid", "name"}], "unread": [{"pid", "name", "why"}], "unplaced": [{"pid",
 * "name"}], "own": why or null, "attached": n}. `found` are the carriers left behind. `unread` are
 * those whose OWN parents could not be followed (a parent missing from the list, or a loop).
 * `attached` is how many meet the look's line and so are still attached. `own` is why the look's
 * own line could not be followed to launchd, or null when it was; while it is set, a carrier whose
 * parents were followed to launchd without meeting the part of the look's line that was read
 * cannot be told apart, left behind or attached above the break, and goes in `unplaced`, never in
 * `found` and never in `unread`. The two are kept apart because they are decided differently
 * (processHolds below): a review of the first build that made `unread` a note found both filed
 * under it, so a process with launchd for a parent was only a note whenever the look could not
 * find its own place. tests/test-close-card-process-look.sh runs it against real processes and on
 * planted process lists.
 */
export const PROCESS_LIST = ['ps', '-x', '-o', 'pid=,ppid=,comm=']
export const PROCESS_LOOK = `
import ctypes, json, os, struct, sys
want = ('CLAUDE_CODE_SESSION_ID=' + sys.argv[1]).encode()
libc = ctypes.CDLL('/usr/lib/libc.dylib', use_errno=True)
def argmax():
    mib = (ctypes.c_int * 2)(1, 8)
    v = ctypes.c_int(0)
    sz = ctypes.c_size_t(ctypes.sizeof(v))
    libc.sysctl(mib, 2, ctypes.byref(v), ctypes.byref(sz), None, 0)
    return v.value
N = argmax()
def env_of(pid):
    mib = (ctypes.c_int * 3)(1, 49, pid)
    buf = ctypes.create_string_buffer(N)
    sz = ctypes.c_size_t(N)
    if libc.sysctl(mib, 3, buf, ctypes.byref(sz), None, 0) != 0:
        return []
    raw = buf.raw[:sz.value]
    argc = struct.unpack('i', raw[:4])[0]
    parts = [p for p in raw[4:].split(b'\\0') if p]
    return parts[1 + argc:]
def kernel_parent(pid):
    mib = (ctypes.c_int * 4)(1, 14, 1, pid)
    buf = ctypes.create_string_buffer(1024)
    sz = ctypes.c_size_t(1024)
    if libc.sysctl(mib, 4, buf, ctypes.byref(sz), None, 0) != 0 or sz.value < 564:
        return None
    return struct.unpack_from('i', buf.raw, 560)[0]
parent = {}
name = {}
for row in sys.stdin.buffer.read().decode('utf-8', 'replace').splitlines():
    bits = row.split(None, 2)
    if len(bits) == 3 and bits[0].isdigit() and bits[1].isdigit():
        parent[int(bits[0])] = int(bits[1])
        name[int(bits[0])] = os.path.basename(bits[2])
me = os.getpid()
parent[me] = os.getppid()
if kernel_parent(me) == parent[me]:
    p = parent[me]
    for _ in range(64):
        if p <= 1 or p in parent:
            break
        k = kernel_parent(p)
        if k is None or k < 0:
            break
        parent[p] = k
        p = k
def line_of(pid):
    seen = []
    p = pid
    while p > 1:
        if p in seen:
            return seen, 'its parents loop back to process %d' % p
        if p not in parent:
            return seen, 'process %d, a parent of it, is not in the process list' % p
        seen.append(p)
        p = parent[p]
    return seen, None
own, own_why = line_of(me)
own = set(own)
found = []
unread = []
unplaced = []
attached = 0
for pid in sorted(parent):
    if pid in own or want not in env_of(pid):
        continue
    line, why = line_of(pid)
    if own.intersection(line):
        attached += 1
    elif why:
        unread.append({'pid': pid, 'name': name.get(pid, ''), 'why': why})
    elif own_why:
        unplaced.append({'pid': pid, 'name': name.get(pid, '')})
    else:
        found.append({'pid': pid, 'name': name.get(pid, '')})
print(json.dumps({'found': found, 'unread': unread, 'unplaced': unplaced, 'own': own_why, 'attached': attached}))
`

/**
 * What reading A hands the close check: `holds` withhold the card, `notes` are written beside the
 * reasons and decide nothing, and `attached` is the look's count of carriers still attached, null
 * when it gave none. The count is written to the reasons file and nothing is decided from it: in a
 * session with connected servers it is never 0, so a 0 there is a look that saw no environment at
 * all, which would otherwise read exactly like a clean one.
 */
export type ProcessReading = { holds: string[]; notes: string[]; attached: number | null }

/**
 * The note a look that could not be finished leaves (it failed, ran out of time, or answered
 * something that is not its answer). It still says nothing either way, so the other readings
 * decide; that rule is older than the note and is Dan's to change. Before the note such a look left
 * no trace in the reasons file, so a card pinned over a look that never ran read as a clean one.
 */
export const checkUnfinished = (what: string) =>
  `the check for a process left behind ${what}, so it said nothing either way: the other readings decided, and a process left behind would not have been seen`

/** The note for a process list the engine cut short: the look ran on the part before the cut. */
export const LIST_CUT =
  "the list of this user's processes was cut short before its end, so the check for a process left behind could not be finished: a process past the cut was not looked at"

/**
 * What reading A found, one sentence each. It may only withhold the card: a look that failed, ran
 * out of time or answered anything else says nothing either way (`unfinished`, the note to leave
 * for it), and is never why a card is pinned.
 *
 * A carrier left behind withholds it (`holds`).
 *
 * One whose OWN parents could not be followed does not (#3770; Dan, 2026-11-26, by picker: "2.1
 * Unreadable counts as nothing"): it counts as nothing either way, never a reason to withhold and
 * never by itself a reason to pin, and is handed back as a note (`notes`) for the reasons file. The
 * first build of this withheld for it; that was changed on his answer.
 *
 * His answer does not cover the look failing to follow its own line (`own`). Then a carrier whose
 * parents were followed all the way to launchd cannot be told apart (`unplaced`), and it may be the
 * very process left behind, so the card is withheld for those, in one reason naming them, as it was
 * before his answer. With nothing unplaced the same failing withholds nothing and is a note.
 * Whether it should count as nothing too is a question left for him (pull request 3826).
 *
 * Carriers still attached are counted by the look and are no reason at all.
 */
export const processHolds = (r: { exitCode: number; stdout: string }): ProcessReading & { unfinished?: string } => {
  const nothing = (what: string) => ({ holds: [], notes: [], attached: null, unfinished: checkUnfinished(what) })
  if (r.exitCode !== 0) return nothing(`ended with exit code ${r.exitCode}`)
  let o: unknown
  try {
    o = JSON.parse(r.stdout)
  } catch {
    return nothing('printed something that is not its answer')
  }
  if (typeof o !== 'object' || o === null || Array.isArray(o)) return nothing('printed something that is not its answer')
  const answer = o as Record<string, unknown>
  const listed = (key: 'found' | 'unread' | 'unplaced'): { who: string; why: string }[] => {
    const list = answer[key]
    if (!Array.isArray(list)) return []
    return list.flatMap(f => {
      const x = (typeof f === 'object' && f !== null ? f : {}) as { pid?: unknown; name?: unknown; why?: unknown }
      if (typeof x.pid !== 'number') return []
      return [{ who: `process ${x.pid} (${typeof x.name === 'string' && x.name ? x.name : 'unnamed'})`, why: typeof x.why === 'string' && x.why ? x.why : 'the look gave no reason' }]
    })
  }
  const unplaced = listed('unplaced').map(p => p.who)
  // Unplaced carriers with no reason given still withhold: they could not be told apart.
  const own = typeof answer.own === 'string' && answer.own ? answer.own : unplaced.length ? 'it gave no reason' : undefined
  const noPlace = `the check for a process left behind could not find its own place among the processes (${own})`
  return {
    holds: [
      ...listed('found').map(p => `${p.who} carries this session's id and its parents no longer lead to this session, so something this session started was left running`),
      ...(own && unplaced.length ? [`${noPlace}, so it could not tell whether these are still attached to this session or were left running, and each carries this session's id: ${unplaced.join(', ')}`] : []),
    ],
    notes: [
      ...(own && !unplaced.length ? [`${noPlace}; it saw no process carrying this session's id that needed that place to be told apart, so this withheld nothing`] : []),
      ...listed('unread').map(p => `${p.who} carries this session's id, and whether it is still attached to this session could not be read (${p.why}), so it was seen and not counted`),
    ],
    attached: typeof answer.attached === 'number' && Number.isInteger(answer.attached) && answer.attached >= 0 ? answer.attached : null,
  }
}

// ---- A steps card carried from an earlier session and not yet checked (#3817) ----
// Manual steps holds such a card, and any step added to it, until the session has checked the steps
// and pinned them again, which nothing but a standing note asked for. So in a folder with kept
// undone steps the close card could not show until the session had done that by itself (Dan's first
// real test of #3770 ran in one, where it had not). Dan, 2026-11-27: "Ask the session to check first".

/**
 * Manual steps' reason for not showing a step added to a held card, word for word (`CARRIED_HELD`
 * in payload/mods/manual-steps/hooks/register.tsx). A mod cannot read another mod's files, so it
 * is said again here, and tests/test-close-card-carried-reason.sh fails when the two drift: reworded
 * there alone, the answer would no longer be known for a held card and the session never asked.
 */
export const CARRIED_HELD = 'the steps carried from an earlier session are held until Claude checks them again'

/**
 * What the session is told, once per request of Dan's, when the close card is due and the steps
 * card is still held. Dan reads it too, so it is short and names nothing from inside the mods. It
 * says to keep each title and link or place because that is how manual steps knows a pinned step
 * as the kept one (`pinnedBy`, held to this by tests/test-close-card-carried-reason.sh): one it
 * does not know becomes this session's own step, which holds the close card until Dan has done it.
 * It ends by asking for a reply that is not a question, since an answer ending on one keeps the
 * close card back. It promises no card and does not say the steps were never checked: manual steps
 * answers in the same words for a card it holds because Dan is away, which the session may have
 * checked already, and that card stays held until he is home whatever the session does.
 */
export const CHECK_CARRIED =
  'CARRIED STEPS. This session is finished, but the card telling Dan he can close it waits behind steps carried over from an earlier session, which he cannot see yet. Check each against the current state, then pin them again with the manual steps tool, marking any you find done. Keep each title and link or place as it is, or the close card stays back. Say in one line what you found, with no question.'

/**
 * How many more times a prompt that could not be sent is tried while the session stays idle, one
 * quiet period apart. An idle session has no next turn end to try it at, and a bound keeps a send
 * that can never enter from being tried every few minutes for good.
 */
export const CARRIED_RETRIES = 3

/**
 * The one reason written when the steps card is held: it names the carried card in manual steps'
 * own words, then says what was done about it. `asked`: the prompt above entered now. `asked
 * before`: it entered earlier under this request and the answer is still held. `failed`: it could
 * not be sent, and why, with whether it is tried again while the session stays idle
 * (`isTriedAgain`) or the tries allowed there are used up. The asked reason promises the card only
 * under what the code needs for it, the same two things the prompt's comment above names.
 */
export const carriedReason = (how: 'asked' | 'asked before' | { failed: string; isTriedAgain: boolean }): string => {
  const held = `the card could not be shown (${CARRIED_HELD})`
  if (how === 'asked') return `${held}; the session was asked to check them and pin them again, and the card can follow at a later quiet turn end once they are showing: each pinned under the title and link or place it had, and Dan at home, since manual steps holds every card while he is away`
  if (how === 'asked before') return `${held}; the session was already asked once for this request to check them and pin them again, and they are still held`
  if (how.isTriedAgain) return `${held}; the session could not be asked to check them (${how.failed}), so it is asked again once the session has been quiet for as long again`
  return `${held}; the session could not be asked to check them (${how.failed}) at ${CARRIED_RETRIES + 1} tries in a row, so it is asked again only at a quiet turn end after the session's next turn`
}

/** The step as the manual steps noun takes it: this session alone, with no Done. */
export const closeStep = (folder: string) => ({
  title: CLOSE_TITLE,
  location: folder ? `The Terminal tab showing this session, in the ${folder} folder` : 'The Terminal tab showing this session',
  clicks: ['Type /exit and press Return', 'Or close the tab'],
  sessionOnly: true,
  noDone: true,
})
