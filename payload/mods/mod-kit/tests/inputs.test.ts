import { describe, expect } from 'claude-code/testing'
import { never, test } from './hang-ceiling.ts'
import { currentText, inputTexts, isDevice, type InputFs } from '../hooks/inputs.ts'

// The one reader of a file a command names as what it reads (#1765): a patch file, a script fed on
// standard input, a commit message's -F file. A device or a fifo there is never opened, since reading
// one waits for ever (a git commit -F /dev/stdin held a worktree agent's call for 10,469 seconds).

// A disk standing in for $.fs: regular files by their text, anything else by its kind. A read of a
// path that is not a regular file never answers, as the real one does, so a test that opened one
// would hang; every read is counted.
type Disk = Record<string, string | 'FIFO' | 'DIR' | 'DEVICE'>
const disk = (entries: Disk, fail?: { exists?: string; stat?: string; statError?: string; read?: string }) => {
  const reads: string[] = []
  const fs: InputFs = {
    exists: async path => {
      if (fail?.exists === path) throw new Error(`EPERM: ${path}, exists`)
      return entries[path] !== undefined
    },
    stat: async path => {
      if (fail?.stat === path) throw new Error(fail.statError ?? `EACCES: ${path}`)
      const e = entries[path]
      if (e === undefined) throw new Error(`ENOENT: ${path}`)
      return { kind: e === 'DIR' ? 'dir' : e === 'FIFO' || e === 'DEVICE' ? 'other' : 'file' }
    },
    read: async path => {
      reads.push(path)
      if (fail?.read === path) throw new Error(`EIO: ${path}`)
      const e = entries[path]
      if (e === undefined) throw new Error(`ENOENT: ${path}`)
      if (e === 'FIFO' || e === 'DIR' || e === 'DEVICE') return never<string>()
      return e
    },
  }
  return { fs, reads }
}

describe('inputs: reading what a command reads', () => {
  test('a device is never touched, by its name alone', async () => {
    expect(isDevice('/dev/stdin')).toBe(true)
    expect(isDevice('/dev/fd/0')).toBe(true)
    expect(isDevice('/dev')).toBe(true)
    expect(isDevice('/proc/self/fd/0')).toBe(true)
    expect(isDevice('/devices/x.patch')).toBe(false)
    expect(isDevice('/repo/dev/stdin')).toBe(false)
    // Even where the disk says it is a plain file, it is not asked: no stat, no read.
    const { fs, reads } = disk({ '/dev/stdin': 'x', '/dev/fd/0': 'x', '/proc/self/fd/0': 'x' })
    expect(await inputTexts(fs, ['/dev/stdin', '/dev/fd/0', '/proc/self/fd/0'])).toEqual([])
    expect(reads).toEqual([])
  })
  test('a fifo, a folder or a link to a device is left out without being opened', async () => {
    const { fs, reads } = disk({ '/tmp/pipe': 'FIFO', '/repo/src': 'DIR', '/tmp/in': 'DEVICE' })
    expect(await inputTexts(fs, ['/tmp/pipe', '/repo/src', '/tmp/in'])).toEqual([])
    expect(reads).toEqual([])
  })
  test('an ordinary file is read, in order, beside one that is not', async () => {
    const { fs, reads } = disk({ '/repo/a.patch': 'A', '/tmp/pipe': 'FIFO', '/repo/b.patch': 'B' })
    expect(await inputTexts(fs, ['/repo/a.patch', '/dev/stdin', '/tmp/pipe', '/repo/b.patch'])).toEqual(['A', 'B'])
    expect(reads).toEqual(['/repo/a.patch', '/repo/b.patch'])
  })
  test('a file not there is left out, as a guard always left it', async () => {
    const { fs } = disk({})
    expect(await inputTexts(fs, ['/repo/gone.patch'])).toEqual([])
  })
  test('a file there that cannot be judged or read throws, so a guard fails closed', async () => {
    const statFails = disk({ '/repo/a.patch': 'A' }, { stat: '/repo/a.patch' })
    await expect(inputTexts(statFails.fs, ['/repo/a.patch'])).rejects.toThrow('EACCES: /repo/a.patch')
    const existsFails = disk({ '/repo/a.patch': 'A' }, { exists: '/repo/a.patch' })
    await expect(inputTexts(existsFails.fs, ['/repo/a.patch'])).rejects.toThrow('EPERM: /repo/a.patch, exists')
    const readFails = disk({ '/repo/a.patch': 'A' }, { read: '/repo/a.patch' })
    await expect(inputTexts(readFails.fs, ['/repo/a.patch'])).rejects.toThrow('EIO: /repo/a.patch')
  })
})

// The same refusal for a file a Write or Edit names as its target (#1814): a guard reading what the
// file holds now, to judge what the call adds, waited for ever on a fifo or on /dev/stdin. What it
// holds is then unreadable, said with why, and never read as empty or as a file not there.
describe('inputs: what a file a call writes holds now', () => {
  test('a device is unreadable by its name alone: no look, no read', async () => {
    const { fs, reads } = disk({ '/dev/stdin': 'x', '/dev/fd/0': 'x', '/proc/self/fd/0': 'x' })
    for (const path of ['/dev/stdin', '/dev/fd/0', '/proc/self/fd/0']) expect(await currentText(fs, path)).toEqual({ unreadable: 'it is a device, not a file' })
    expect(reads).toEqual([])
  })
  test('a fifo, a link to a device or a folder is unreadable without being opened', async () => {
    const { fs, reads } = disk({ '/repo/CLAUDE.md': 'FIFO', '/repo/in.md': 'DEVICE', '/repo/src': 'DIR' })
    expect(await currentText(fs, '/repo/CLAUDE.md')).toEqual({ unreadable: 'it is not an ordinary file (a fifo, a socket or a link to a device)' })
    expect(await currentText(fs, '/repo/in.md')).toEqual({ unreadable: 'it is not an ordinary file (a fifo, a socket or a link to a device)' })
    expect(await currentText(fs, '/repo/src')).toEqual({ unreadable: 'it is a folder, not a file' })
    expect(reads).toEqual([])
  })
  test('an ordinary file is read, and one not there is absent, never empty', async () => {
    const { fs, reads } = disk({ '/repo/CLAUDE.md': '# Rules\n' })
    expect(await currentText(fs, '/repo/CLAUDE.md')).toEqual({ text: '# Rules\n' })
    expect(await currentText(fs, '/repo/gone.md')).toEqual({ absent: true })
    expect(reads).toEqual(['/repo/CLAUDE.md'])
  })
  // Claude Code 2.1.312 (measured headless by #1830's builder): a stat with links followed of
  // /dev/stdin, or of a link to it, THROWS EBADF rather than answering 'other', so a Write to a link
  // to /dev/stdin threw out of this reader and each guard's own catch decided what happened. Any
  // throw from the look is unreadable, the error named, never empty and never escaping; nothing is read.
  test('a file whose look throws (EBADF for a link to /dev/stdin) is unreadable, the error named, and never read', async () => {
    const { fs, reads } = disk({ '/repo/CLAUDE.md': 'x' }, { stat: '/repo/CLAUDE.md', statError: 'EBADF: bad file descriptor, stat' })
    expect(await currentText(fs, '/repo/CLAUDE.md')).toEqual({ unreadable: 'it could not be looked at (EBADF: bad file descriptor, stat)' })
    const denied = disk({ '/repo/a.md': 'A' }, { stat: '/repo/a.md' })
    expect(await currentText(denied.fs, '/repo/a.md')).toEqual({ unreadable: 'it could not be looked at (EACCES: /repo/a.md)' })
    expect([...reads, ...denied.reads]).toEqual([])
  })
  // The first half of the look is asking whether anything is there at all, and it can throw as the
  // stat can (#1839): that throw escaped this reader while only the stat's was caught, against the
  // promise above that a failed look never escapes. Either half failing is the same unreadable answer.
  test('a file whose existence check throws is unreadable, the error named, and never read', async () => {
    const { fs, reads } = disk({ '/repo/CLAUDE.md': 'x' }, { exists: '/repo/CLAUDE.md' })
    expect(await currentText(fs, '/repo/CLAUDE.md')).toEqual({ unreadable: 'it could not be looked at (EPERM: /repo/CLAUDE.md, exists)' })
    expect(reads).toEqual([])
  })
  test('a file there that cannot be read throws, so a guard fails closed', async () => {
    const readFails = disk({ '/repo/a.md': 'A' }, { read: '/repo/a.md' })
    await expect(currentText(readFails.fs, '/repo/a.md')).rejects.toThrow('EIO: /repo/a.md')
  })
})
