// Reading a file a command names as what it reads (#1765): a patch file, a script fed on standard
// input, a commit message's -F file. Such a name can be a device (/dev/stdin, /dev/fd/0), the
// kernel's own folder (/proc/self/fd/0) or a fifo, and a read of one waits for ever, on the mod
// worker's own standard input or on a writer that never comes, so the call the guard is judging
// never runs and no hook or prompt follows (a worktree agent's git commit -F /dev/stdin was held for
// 10,469 seconds). Kept here once and copied byte for byte into each mod that reads such a file
// (hooks/mod-kit/inputs.ts, which tools/check-mod-shared-parts.sh holds to this one), since a mod
// cannot import another mod's files. Mod-kit's write reader takes a device out of every input it
// names with the same isDevice, so a guard reading those inputs some other way still never meets one.
// The file a call WRITES is read the same way (#1814, currentText): a guard reading a Write or Edit
// target's text now, to judge what the call adds, met /dev/stdin or a fifo there just as often.

/** Whether a path names a device or the kernel's own folder: nothing there is a file to read. */
export const isDevice = (path: string): boolean => /^\/(?:dev|proc)(?:\/|$)/.test(path)

/**
 * The calls this needs from the engine's file system, each spelled at the call site, since the engine
 * refuses $.fs handed on as a value: `{ exists: p => $.fs.exists(p), stat: (p, o) => $.fs.stat(p, o),
 * read: p => $.fs.read(p) }`.
 */
export type InputFs = {
  exists: (path: string) => Promise<boolean>
  stat: (path: string, options: { resolve: boolean }) => Promise<{ kind: 'file' | 'dir' | 'other' }>
  read: (path: string) => Promise<string>
}

// What is at a path, asked without opening it: a device by its name alone, with no call at all;
// otherwise whether anything is there, and what it is once its links are followed. A look that
// throws is answered as `{ lookFailed }`, the error itself, never as a kind: Claude Code 2.1.312's
// stat with links followed THROWS EBADF for /dev/stdin and for a link to it (measured headless,
// #1814), where a fifo answers 'other'. Each reader below decides what a failed look means.
type Kind = 'device' | 'absent' | 'file' | 'dir' | 'other' | { lookFailed: unknown }
const kindAt = async (fs: InputFs, path: string): Promise<Kind> => {
  if (isDevice(path)) return 'device'
  if (!(await fs.exists(path))) return 'absent'
  try {
    return (await fs.stat(path, { resolve: true })).kind
  } catch (err) {
    return { lookFailed: err }
  }
}
const errorWords = (err: unknown): string => (err instanceof Error ? err.message : String(err))

/**
 * The text of each file among `paths` that is an ordinary file, in order. A device is never touched,
 * by its name alone. A path that is not there, or is not a regular file once its links are followed
 * (a fifo, a socket, a link to a device, a folder), is left out without being opened: what it holds
 * cannot be known before the command runs, as a missing file's cannot, so each guard reads the
 * command's own words for it as it always has. A look or read that fails otherwise throws, so a
 * guard fails closed as it did when it read the file itself: a file a command reads whose look fails
 * may be a real patch, and leaving it out would let what it holds through unjudged.
 */
export const inputTexts = async (fs: InputFs, paths: readonly string[]): Promise<string[]> => {
  const out: string[] = []
  for (const path of paths) {
    const kind = await kindAt(fs, path)
    if (typeof kind === 'object') throw kind.lookFailed
    if (kind === 'file') out.push(await fs.read(path))
  }
  return out
}

/** What a file a call writes holds now (currentText): its text, nothing there, or why it cannot be read. */
export type Current = { text: string } | { absent: true } | { unreadable: string }

/**
 * What the file a Write or Edit names (or a shell write's target) holds now, read before the call
 * runs, by the same refusal as inputTexts (#1814): a guard judging what a call adds read the target
 * first, and a target that was /dev/stdin or a fifo held the call for ever. A device, a fifo, a
 * socket, a link to a device or a folder is never opened, and is `unreadable`, with why in words a
 * refusal can carry. That is never the same as `absent` (nothing there, so all a Write holds is new)
 * nor as empty text: each guard says it could not read the file and judges the call whole. A look
 * that throws (EBADF for a link to /dev/stdin on Claude Code 2.1.312) is unreadable too, the error
 * named, and never escapes: each guard's own catch decided before, and two of them said nothing of
 * why. A read that fails throws, so a guard fails closed.
 */
export const currentText = async (fs: InputFs, path: string): Promise<Current> => {
  const kind = await kindAt(fs, path)
  if (typeof kind === 'object') return { unreadable: `it could not be looked at (${errorWords(kind.lookFailed)})` }
  if (kind === 'absent') return { absent: true }
  if (kind === 'file') return { text: await fs.read(path) }
  if (kind === 'device') return { unreadable: 'it is a device, not a file' }
  if (kind === 'dir') return { unreadable: 'it is a folder, not a file' }
  return { unreadable: 'it is not an ordinary file (a fifo, a socket or a link to a device)' }
}
