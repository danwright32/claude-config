import { expect, test } from 'claude-code/testing'
import { isTestPath } from '../hooks/testfile.ts'

// Whether a path inside a checkout is a test file (#1508): the design round guard's rule since Dan's
// "On, but let tests through" (2026-10-08), now kept here once and copied byte for byte into each mod
// that asks it (the design round guard and the area check), since a mod cannot import another's files.

test('a .test. or .spec. part in the name is a test', () => {
  for (const p of ['app/page.test.tsx', 'lib/a.spec.ts', 'x.test.js', 'Button.SPEC.jsx']) expect(isTestPath(p)).toBe(true)
})

test('a __tests__, tests or test folder above it is a test', () => {
  for (const p of ['__tests__/a.ts', 'src/tests/helper.py', 'test/fixtures/x.ts', 'payload/mods/x/tests/register.test.ts']) expect(isTestPath(p)).toBe(true)
})

test('for Swift, a folder ending Tests or a name ending Tests.swift is a test', () => {
  for (const p of ['AppTests/LoginTests.swift', 'Sources/AppTests/Helper.swift', 'Sources/App/LoginTests.swift']) expect(isTestPath(p)).toBe(true)
  expect(isTestPath('Sources/App/Login.swift')).toBe(false)
})

test('a name merely holding "test" is no test', () => {
  for (const p of ['latest.tsx', 'contest.css', 'src/attestation.ts', 'testing/x.ts']) expect(isTestPath(p)).toBe(false)
})
