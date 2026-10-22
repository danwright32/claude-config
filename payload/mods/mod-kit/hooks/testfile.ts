// Whether a path inside a checkout is a test file (#1508): the design round guard's rule since Dan's
// "On, but let tests through" (2026-10-08), asked by the area check too, which leaves tests in scope
// but must know them apart from source the same way. Pure. Kept here once and copied byte for byte
// into each mod that asks it (hooks/mod-kit/testfile.ts, which tools/check-mod-shared-parts.sh holds
// to this one), since a mod cannot import another mod's files.

/**
 * Whether a path is a test file, by the usual markers: a `.test.` or `.spec.` part in its name, or a
 * `__tests__`, `tests` or `test` folder above it; and for Swift, a test target's folder ending `Tests`
 * or a name ending `Tests.swift`. A name merely holding "test" (latest.tsx, contest.css) is no test.
 * Asked of the path inside its checkout, so a project checked out under a folder named tests is not
 * a test whole.
 */
export const isTestPath = (path: string): boolean => {
  const parts = path.split('/').filter(Boolean)
  const base = parts.pop() ?? ''
  if (/\.(test|spec)\./i.test(base)) return true
  if (parts.some(p => p === '__tests__' || p === 'tests' || p === 'test')) return true
  if (/\.swift$/i.test(base)) return /Tests\.swift$/.test(base) || parts.some(p => /Tests$/.test(p))
  return false
}
