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
 * It prints {"found": [{"pid", "name"}], "unread": [{"pid", "name", "why"}], "attached": n}: the
 * carriers left behind, those whose parents could not be followed to either end (a parent missing
 * from the list, a loop, or the look's own line cut short), and how many are still attached.
 * tests/test-close-card-process-look.sh runs it against real processes.
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
attached = 0
for pid in sorted(parent):
    if pid in own or want not in env_of(pid):
        continue
    line, why = line_of(pid)
    if own.intersection(line):
        attached += 1
    elif why or own_why:
        unread.append({'pid': pid, 'name': name.get(pid, ''), 'why': why or "the look's own parents could not be followed: " + own_why})
    else:
        found.append({'pid': pid, 'name': name.get(pid, '')})
print(json.dumps({'found': found, 'unread': unread, 'attached': attached}))
`

/**
 * What reading A found, one sentence each. It may only withhold the card: a look that failed, ran
 * out of time or answered anything else says nothing either way, and is never why a card is pinned.
 * A carrier left behind withholds it. So does one whose parents could not be followed (#3770): a
 * process carrying this session's id was found, which is what Dan's 3.76.1 withholds for, and still
 * attached is the exception that has to be shown, so unread it counts as left running, said as such.
 * Carriers still attached are counted by the look and are no reason at all.
 */
export const processHolds = (r: { exitCode: number; stdout: string }): string[] => {
  if (r.exitCode !== 0) return []
  let o: unknown
  try {
    o = JSON.parse(r.stdout)
  } catch {
    return []
  }
  const listed = (key: 'found' | 'unread'): { who: string; why: string }[] => {
    const list = (typeof o === 'object' && o !== null ? (o as Record<string, unknown>)[key] : undefined) as unknown
    if (!Array.isArray(list)) return []
    return list.flatMap(f => {
      const x = (typeof f === 'object' && f !== null ? f : {}) as { pid?: unknown; name?: unknown; why?: unknown }
      if (typeof x.pid !== 'number') return []
      return [{ who: `process ${x.pid} (${typeof x.name === 'string' && x.name ? x.name : 'unnamed'})`, why: typeof x.why === 'string' && x.why ? x.why : 'the look gave no reason' }]
    })
  }
  return [
    ...listed('found').map(p => `${p.who} carries this session's id and its parents no longer lead to this session, so something this session started was left running`),
    ...listed('unread').map(p => `${p.who} carries this session's id, and whether it is still attached to this session could not be read (${p.why}), so it counts as left running`),
  ]
}

/** The step as the manual steps noun takes it: this session alone, with no Done. */
export const closeStep = (folder: string) => ({
  title: CLOSE_TITLE,
  location: folder ? `The Terminal tab showing this session, in the ${folder} folder` : 'The Terminal tab showing this session',
  clicks: ['Type /exit and press Return', 'Or close the tab'],
  sessionOnly: true,
  noDone: true,
})
