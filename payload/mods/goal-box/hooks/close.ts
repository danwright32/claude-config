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
 * How long the session must stay quiet after its turn ends before the card goes up: longer than the
 * subagent harvest's 180 second limit, the longest end of turn hook still running after a stop that
 * nothing a mod reads can see. One constant, on the engine's clock, which a test moves.
 */
export const QUIET_MS = 3 * 60_000

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
 * environment), and another session's processes were not matched. It is handed this user's
 * processes as `ps -x -o pid=,ppid=,comm=` lists them on its standard input; the look itself and the
 * processes it descends from are left out. It prints {"found": [{"pid", "name"}]}.
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
rows = sys.stdin.read().splitlines()
parent = {}
name = {}
for line in rows:
    bits = line.split(None, 2)
    if len(bits) == 3:
        parent[int(bits[0])] = int(bits[1])
        name[int(bits[0])] = os.path.basename(bits[2])
mine = set()
p = os.getpid()
while p > 1 and p not in mine:
    mine.add(p)
    p = parent.get(p, 1)
found = [{'pid': pid, 'name': name[pid]} for pid in sorted(parent) if pid not in mine and want in env_of(pid)]
print(json.dumps({'found': found}))
`

/**
 * What reading A found, one sentence each. It may only withhold the card: a look that failed, ran
 * out of time or answered anything else says nothing either way, and is never why a card is pinned.
 */
export const processHolds = (r: { exitCode: number; stdout: string }): string[] => {
  if (r.exitCode !== 0) return []
  let o: unknown
  try {
    o = JSON.parse(r.stdout)
  } catch {
    return []
  }
  const found = (o as { found?: unknown } | null)?.found
  if (!Array.isArray(found)) return []
  return found.flatMap(f => {
    const x = (typeof f === 'object' && f !== null ? f : {}) as { pid?: unknown; name?: unknown }
    return typeof x.pid === 'number' ? [`process ${x.pid} (${typeof x.name === 'string' ? x.name : 'unnamed'}) carries this session's id, so something this session started is still running`] : []
  })
}

/** The step as the manual steps noun takes it: this session alone, with no Done. */
export const closeStep = (folder: string) => ({
  title: CLOSE_TITLE,
  location: folder ? `The Terminal tab showing this session, in the ${folder} folder` : 'The Terminal tab showing this session',
  clicks: ['Type /exit and press Return', 'Or close the tab'],
  sessionOnly: true,
  noDone: true,
})
