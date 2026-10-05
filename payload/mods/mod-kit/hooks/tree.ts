// The git working tree a path sits in (#726, from the collision guard's own reading in #700): the
// nearest folder at or above it holding a .git entry, a folder or the file a linked worktree or
// submodule has. Asked of the disk through `hasGit`, never of git, nearest first, and bounded so
// no path costs more than WALK_LIMIT looks. A look the disk cannot answer is thrown, never taken
// for "no checkout", since a reader deciding what a write may do must not decide on a guess.

const WALK_LIMIT = 64

export const workingTree = async (path: string, hasGit: (dir: string) => Promise<boolean>): Promise<string | undefined> => {
  if (!path.startsWith('/')) throw new Error(`a working tree is found from an absolute path, not ${path}`)
  let dir = path.replace(/\/+$/, '') || '/'
  for (let looked = 0; looked < WALK_LIMIT; looked++) {
    if (await hasGit(dir)) return dir
    if (dir === '/') return undefined
    dir = dir.slice(0, dir.lastIndexOf('/')) || '/'
  }
  return undefined
}
