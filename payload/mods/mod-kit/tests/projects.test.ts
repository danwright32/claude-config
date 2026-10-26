import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { projectFolder, transcriptPlaces } from '../hooks/projects.ts'

// #1725: where Claude Code keeps a session's transcript, measured on the real engine (2.1.310,
// 2026-10-25) by starting headless sessions in unusual folders: every character but a letter or a
// digit becomes a hyphen, and a spelling past 200 characters is cut to its first 200 and given a
// hyphen and a hash of the path. The two real folders below are what that run wrote.
const LONG_CWD =
  '/private/var/folders/kd/98c3xw516598081hs59hbkt80000gn/T/measure-long.27sZoY/' +
  Array.from({ length: 22 }, (_, i) => `segment.${String(i + 1).padStart(3, '0')}/`).join('') +
  'end.x'
const LONG_FOLDER =
  '-private-var-folders-kd-98c3xw516598081hs59hbkt80000gn-T-measure-long-27sZoY-segment-001-segment-002-segment-003-segment-004-segment-005-segment-006-segment-007-segment-008-segment-009-segment-010-seg-20wnth'
const DOTTED_CWD = '/private/var/folders/kd/98c3xw516598081hs59hbkt80000gn/T/measure-long.27sZoY/a.dotted dir_x/.claude/worktrees/w1'
const DOTTED_FOLDER = '-private-var-folders-kd-98c3xw516598081hs59hbkt80000gn-T-measure-long-27sZoY-a-dotted-dir-x--claude-worktrees-w1'
const P = '/Users/x/.claude/projects'

test('a folder with a dot, a space and an underscore is spelled with a hyphen for each', () => {
  expect(projectFolder(DOTTED_CWD)).toEqual({ name: DOTTED_FOLDER })
})

test('a spelling past 200 characters is known only by its first 200 and a hyphen, the hash being Claude Code\'s', () => {
  const f = projectFolder(LONG_CWD)
  expect(f).toEqual({ prefix: LONG_FOLDER.slice(0, 201) })
  expect('name' in f).toBe(false)
})

test('a spelling of exactly 200 characters is kept whole', () => {
  const cwd = '/' + 'a'.repeat(199)
  expect(projectFolder(cwd)).toEqual({ name: '-' + 'a'.repeat(199) })
})

test('the place of an ordinary folder\'s transcript is named without listing anything', async () => {
  let listed = 0
  const list = async () => {
    listed++
    return []
  }
  expect(await transcriptPlaces(list, P, DOTTED_CWD, 's2')).toEqual([`${P}/${DOTTED_FOLDER}/s2.jsonl`])
  expect(listed).toBe(0)
})

test('a long folder\'s transcript is looked for in every folder carrying its first 200 characters and a hash', async () => {
  const list = async (dir: string) => {
    expect(dir).toBe(P)
    return [
      { name: LONG_FOLDER, kind: 'dir' },
      { name: LONG_FOLDER.slice(0, 201) + 'zz9', kind: 'dir' },
      // Not a hash: a longer folder that only begins the same way, a file, and the uncut spelling.
      { name: LONG_FOLDER.slice(0, 201) + 'seg-x', kind: 'dir' },
      { name: LONG_FOLDER.slice(0, 201) + 'abc', kind: 'file' },
      { name: LONG_CWD.replace(/[^A-Za-z0-9]/g, '-'), kind: 'dir' },
    ]
  }
  expect(await transcriptPlaces(list, P, LONG_CWD, 's2')).toEqual([`${P}/${LONG_FOLDER}/s2.jsonl`, `${P}/${LONG_FOLDER.slice(0, 201)}zz9/s2.jsonl`])
})

test('a listing that fails is said, never read as no such folder', async () => {
  const list = async () => {
    throw new Error('EACCES')
  }
  await expect(transcriptPlaces(list, P, LONG_CWD, 's2')).rejects.toThrow('EACCES')
})
