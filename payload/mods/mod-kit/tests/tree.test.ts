import { describe, expect, test } from 'claude-code/testing'
import { workingTree } from '../hooks/tree.ts'

// The git working tree a path sits in, found on the disk by its .git entry (#726): ask before
// saving needs it to tell a checkout under /tmp, whose CLAUDE.md a session there loads, from a
// scratch copy; the collision guard has its own copy until #712 moves it here.
const disk = (gits: string[]) => {
  const looked: string[] = []
  const hasGit = async (dir: string) => {
    looked.push(dir)
    return gits.includes(dir)
  }
  return { hasGit, looked }
}

describe('workingTree', () => {
  test('the nearest folder at or above the path holding a .git entry', async () => {
    const d = disk(['/tmp/repo', '/tmp'])
    expect(await workingTree('/tmp/repo/docs/CLAUDE.md', d.hasGit)).toBe('/tmp/repo')
    expect(d.looked).toEqual(['/tmp/repo/docs/CLAUDE.md', '/tmp/repo/docs', '/tmp/repo'])
  })
  test('a path in no checkout has none, every folder up to the root looked at once', async () => {
    const d = disk([])
    expect(await workingTree('/tmp/backup/CLAUDE.md', d.hasGit)).toBeUndefined()
    expect(d.looked).toEqual(['/tmp/backup/CLAUDE.md', '/tmp/backup', '/tmp', '/'])
  })
  test('the root itself can be the checkout', async () => {
    expect(await workingTree('/x', disk(['/']).hasGit)).toBe('/')
  })
  test('a walk is bounded, so no path costs more than 64 looks', async () => {
    const d = disk([])
    const deep = `/${Array.from({ length: 100 }, (_, i) => `d${i}`).join('/')}`
    expect(await workingTree(deep, d.hasGit)).toBeUndefined()
    expect(d.looked).toHaveLength(64)
  })
  test('a path that is not absolute is refused by name, never walked from somewhere else', async () => {
    await expect(workingTree('repo/CLAUDE.md', disk([]).hasGit)).rejects.toThrow('a working tree is found from an absolute path, not repo/CLAUDE.md')
  })
  test('a look the disk cannot answer is a failure, never "no checkout"', async () => {
    const failing = async () => {
      throw new Error('EACCES: /tmp/locked')
    }
    await expect(workingTree('/tmp/locked/CLAUDE.md', failing)).rejects.toThrow('EACCES: /tmp/locked')
  })
})
