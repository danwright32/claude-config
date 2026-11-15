import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { patchedPaths, patchFiles, patchPlacing, placedName, readPatch } from '../hooks/patch.ts'

// The one patch reader every mod uses (#2992): scope modes and the Slack alert guard each kept one,
// and each read right a case the other read wrong.

test('git diff lines, --- and +++ headers and hunks make one file each, hunks walked by their counts', () => {
  const text = [
    'From 1 Mon Sep 17 00:00:00 2001',
    'Subject: [PATCH] x',
    '',
    'diff --git a/src/app.ts b/src/app.ts',
    'index 1..2 100644',
    '--- a/src/app.ts',
    '+++ b/src/app.ts',
    '@@ -1 +1 @@',
    '--- a/not/a/header',
    '+++ b/not/a/header',
    'diff --git a/old.ts b/lib/new.ts',
    'similarity index 100%',
    'rename from old.ts',
    'rename to lib/new.ts',
    'diff --git a/made.ts b/made.ts',
    'new file mode 100644',
    '--- /dev/null',
    '+++ b/made.ts',
    '@@ -0,0 +1 @@',
    '+made',
  ].join('\n')
  expect(readPatch(text)).toEqual({
    files: [
      { from: 'a/src/app.ts', to: 'b/src/app.ts', hunks: [{ before: '-- a/not/a/header', after: '++ b/not/a/header' }] },
      { from: 'a/old.ts', to: 'b/lib/new.ts', hunks: [] },
      { from: null, to: 'b/made.ts', hunks: [{ before: '', after: 'made' }] },
    ],
  })
})

test('a name git quotes is read with its escapes undone, a timestamp after a tab is cut off', () => {
  expect(readPatch('diff --git "a/caf\\303\\251\\tx.ts" b/plain.ts\n').files).toEqual([{ from: 'a/café\tx.ts', to: 'b/plain.ts', hunks: [] }])
  expect(readPatch('--- a/x y.ts\t2026-01-01 10:00\n+++ b/x y.ts\t2026-01-02 10:00\n').files).toEqual([{ from: 'a/x y.ts', to: 'b/x y.ts', hunks: [] }])
  // An unquoted name holding " b/" is read at its last " b/".
  expect(readPatch('diff --git a/a b/c.ts b/a b/c.ts\n').files).toEqual([{ from: 'a/a b/c.ts b/a', to: 'b/c.ts', hunks: [] }])
})

test('what cannot be read says so: a hunk that does not add up, an unknown line in one, a binary patch', () => {
  expect(readPatch('--- a/x.ts\n+++ b/x.ts\n@@ -1,2 +1,2 @@\n-old\n')).toEqual({ files: [{ from: 'a/x.ts', to: 'b/x.ts', hunks: [] }], unreadable: 'a hunk ends before its lines add up to its header' })
  expect(readPatch('--- a/x.ts\n+++ b/x.ts\n@@ -1 +1 @@\n*old\n+new\n').unreadable).toBe('a hunk holds a line starting "*"')
  expect(patchFiles('--- a/x.ts\n+++ b/x.ts\n@@ -1 +1 @@\n*old\n+new\n')).toBeUndefined()
  expect(readPatch('diff --git a/x.png b/x.png\nGIT binary patch\nliteral 3\n').files).toEqual([{ from: 'a/x.png', to: 'b/x.png', hunks: [], binary: true }])
  expect(patchFiles('diff --git a/x.png b/x.png\nGIT binary patch\nliteral 3\n')).toBeUndefined()
  expect(patchFiles('not a diff\n')).toBeUndefined()
  // Every name is still given where the files are wanted, a binary one included.
  expect(patchedPaths([], true, 'diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n')).toEqual(['x.png'])
})

test('names are placed as the command places them: its -p, its folder, git apply stripping one by default', () => {
  const f = { from: 'a/lib/x.ts', to: 'b/lib/x.ts', hunks: [] }
  expect(placedName('b/lib/x.ts', f, patchPlacing([], true), true)).toBe('lib/x.ts')
  expect(placedName('b/lib/x.ts', f, patchPlacing(['-p2'], false), false)).toBe('x.ts')
  // patch strips git's a/ and b/ only when both sides carry them, and takes a file it is named.
  expect(placedName('lib/x.ts', { from: 'lib/x.ts', to: 'lib/x.ts', hunks: [] }, patchPlacing([], false), false)).toBe('lib/x.ts')
  expect(placedName('b/lib/x.ts', f, patchPlacing(['other.ts', 'fix.patch'], false), false)).toBe('other.ts')
  expect(placedName('b/x.ts', f, patchPlacing(['-p3'], true), true)).toBeUndefined()
  expect(patchedPaths(['--directory=sub/', '-p', '0'], true, '--- y.ts\n+++ y.ts\n')).toEqual(['sub/y.ts'])
  expect(patchPlacing(['-R', '-d', 'app', '-i', 'fix.patch'], false)).toEqual({ into: 'app', reverse: true })
})
