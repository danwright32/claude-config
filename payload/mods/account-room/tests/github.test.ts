import { expect, test } from 'claude-code/testing'
import { answerOf, contentsPath, entriesOf, fileOf, fromBase64, isRepoName, putBody, shaAfterPut, toBase64, unseenWhy } from '../hooks/github.ts'

// The readings repository's answers as gh gives them (#750). Each stderr below is copied from a run
// against the real repository on 2026-10-05, so the reader is held to what GitHub says, not to what
// a fake was written to say (L52).

const run = (exitCode: number, stderr: string, stdout = '') => ({ exitCode, stdout, stderr })

test("gh's refusals are read as GitHub said them, with the HTTP status for the ones a write acts on", () => {
  expect(answerOf(run(1, 'gh: Not Found (HTTP 404)\n'))).toEqual({ ok: false, status: 404, why: 'gh api failed: Not Found (HTTP 404)' })
  expect(answerOf(run(1, 'gh: This repository is empty. (HTTP 404)\n'))).toEqual({ ok: false, status: 404, why: 'gh api failed: This repository is empty. (HTTP 404)' })
  // A write with no sha over a file that exists: gh's message runs over three lines.
  expect(answerOf(run(1, 'gh: Invalid request.\n\n"sha" wasn\'t supplied. (HTTP 422)\n'))).toEqual({ ok: false, status: 422, why: 'gh api failed: Invalid request. "sha" wasn\'t supplied. (HTTP 422)' })
  expect(answerOf(run(1, 'gh: probe/p.json does not match 0000000000000000000000000000000000000000 (HTTP 409)\n'))).toMatchObject({ ok: false, status: 409 })
})

test('no login, no network and no gh are each their own answer, never a refusal of the file', () => {
  expect(answerOf(run(4, 'To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n'))).toEqual({ ok: false, why: 'gh is not logged in to GitHub (gh auth login)' })
  const offline = answerOf(run(1, 'error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com\n'))
  expect(offline).toEqual({ ok: false, why: 'gh api failed: error connecting to api.github.com check your internet connection or https://githubstatus.com' })
  expect(answerOf({ thrown: 'spawn gh ENOENT' })).toEqual({ ok: false, why: 'gh could not be run: spawn gh ENOENT' })
  expect(answerOf(run(0, '', 'not json'))).toEqual({ ok: false, why: 'GitHub answered with something that is not JSON' })
})

test('a repository GitHub will not show names the account gh used, the thing to fix', () => {
  expect(unseenWhy('danwright32/account-room-readings', { ok: true, value: { login: 'dwright-pennie' } })).toBe("danwright32/account-room-readings was not found, or gh's account dwright-pennie cannot see it")
  expect(unseenWhy('o/r', { ok: false, why: 'x' })).toBe('o/r was not found, or the account gh is logged in to cannot see it')
})

test("a file's text survives the trip through base64 both ways, wrapped as GitHub wraps it", () => {
  const text = '{"org":"Café 家","email":"a@example.com"}\n'
  const wrapped = toBase64(text).replace(/.{60}/g, '$&\n')
  expect(fromBase64(`${wrapped}\n`)).toBe(text)
  // The listing and a file as the contents API answered them on 2026-10-05.
  expect(fileOf({ type: 'file', encoding: 'base64', content: 'eyJwcm9iZSI6MX0K\n', sha: 'bd0cc4fe696e020d7191ef0e308ae66788c994bf' }, 'probe/p.json')).toEqual({ ok: true, value: { text: '{"probe":1}\n', sha: 'bd0cc4fe696e020d7191ef0e308ae66788c994bf' } })
  expect(fileOf([], 'readings')).toMatchObject({ ok: false })
  expect(entriesOf([{ name: 'p.json', sha: 'bd0c', size: 12, type: 'file' }])).toEqual({ ok: true, value: [{ name: 'p.json', type: 'file' }] })
  expect(entriesOf({ message: 'x' })).toMatchObject({ ok: false })
})

test('a write carries the sha it was read at, none for a new file, and the repository is only ever owner/name', () => {
  expect(JSON.parse(putBody('x', 'abc', 'Readings from m'))).toEqual({ message: 'Readings from m', content: 'eA==', sha: 'abc' })
  expect(JSON.parse(putBody('x', undefined, 'Readings from m'))).toEqual({ message: 'Readings from m', content: 'eA==' })
  expect(shaAfterPut({ content: { sha: 'def' } })).toBe('def')
  expect(contentsPath('o/r', 'readings/Dans MacBook.json')).toBe('repos/o/r/contents/readings/Dans%20MacBook.json')
  expect(isRepoName('danwright32/account-room-readings')).toBe(true)
  expect(isRepoName('../user')).toBe(false)
  expect(isRepoName('o/..')).toBe(false)
  expect(isRepoName('o/r/../../user')).toBe(false)
  expect(isRepoName('')).toBe(false)
})
