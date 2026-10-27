// Reading a file a command names as what it reads (#1765): a patch file, a script fed on standard
// input, a commit message's -F file. Such a name can be a device (/dev/stdin, /dev/fd/0), the
// kernel's own folder (/proc/self/fd/0) or a fifo, and a read of one waits for ever, on the mod
// worker's own standard input or on a writer that never comes, so the call the guard is judging
// never runs and no hook or prompt follows (a worktree agent's git commit -F /dev/stdin was held for
// 10,469 seconds). Kept here once and copied byte for byte into each mod that reads such a file
// (hooks/mod-kit/inputs.ts, which tools/check-mod-shared-parts.sh holds to this one), since a mod
// cannot import another mod's files. Mod-kit's write reader takes a device out of every input it
// names with the same isDevice, so a guard reading those inputs some other way still never meets one.

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

/**
 * The text of each file among `paths` that is an ordinary file, in order. A device is never touched,
 * by its name alone. A path that is not there, or is not a regular file once its links are followed
 * (a fifo, a socket, a link to a device, a folder), is left out without being opened: what it holds
 * cannot be known before the command runs, as a missing file's cannot, so each guard reads the
 * command's own words for it as it always has. A look or read that fails otherwise throws, so a
 * guard fails closed as it did when it read the file itself.
 */
export const inputTexts = async (fs: InputFs, paths: readonly string[]): Promise<string[]> => {
  const out: string[] = []
  for (const path of paths) {
    if (isDevice(path) || !(await fs.exists(path))) continue
    if ((await fs.stat(path, { resolve: true })).kind !== 'file') continue
    out.push(await fs.read(path))
  }
  return out
}
