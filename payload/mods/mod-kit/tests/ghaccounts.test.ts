import { expect, test } from 'claude-code/testing'
import { askAnyAccount, type GhRun } from '../hooks/ghaccounts.ts'

// One gh call as each account gh is logged in to, until one answers (#1279 lessons review): Dan's
// work repositories are visible only to his work account, so scope modes asked every account, and
// picker manners now asks the same way, through this one helper rather than a second copy. A token is
// scoped to the call (never gh auth switch, which other sessions share) and never printed.
const ran = (exitCode: number, stdout = '', stderr = ''): GhRun => ({ exitCode, stdout, stderr })
type Call = { argv: string[]; env?: Record<string, string>; stdin?: string }
const runner = (answers: (c: Call) => GhRun) => {
  const calls: Call[] = []
  const run = async (argv: string[], env?: Record<string, string>, stdin?: string) => {
    const c: Call = { argv, ...(env ? { env } : {}), ...(stdin !== undefined ? { stdin } : {}) }
    calls.push(c)
    return answers(c)
  }
  return { run, calls }
}
const STATUS = 'github.com\n  Logged in to github.com account dan-personal (keyring)\n  Logged in to github.com account dan-work (keyring)\n'

test('the active account answers first, and nothing else is asked', async () => {
  const r = runner(() => ran(0, '{"body":"b"}'))
  expect(await askAnyAccount(r.run, ['issue', 'view', '7'])).toEqual({ stdout: '{"body":"b"}' })
  expect(r.calls.map(c => c.argv.join(' '))).toEqual(['gh issue view 7'])
})

test("a refusal is asked again as each other account, with its token scoped to the call, stdin carried", async () => {
  const r = runner(c => {
    if (c.argv[1] === 'auth' && c.argv[2] === 'status') return ran(0, '', STATUS)
    if (c.argv[1] === 'auth' && c.argv[2] === 'token') return ran(0, `tok-${c.argv[4]}\n`)
    return c.env?.GH_TOKEN === 'tok-dan-work' ? ran(0, 'done') : ran(1, '', 'GraphQL: Could not resolve to a Repository')
  })
  expect(await askAnyAccount(r.run, ['issue', 'edit', '7', '--body-file', '-'], () => true, 'new body')).toEqual({ stdout: 'done' })
  const edits = r.calls.filter(c => c.argv[1] === 'issue')
  expect(edits.map(c => c.env?.GH_TOKEN ?? 'active')).toEqual(['active', 'tok-dan-personal', 'tok-dan-work'])
  expect(edits.every(c => c.stdin === 'new body')).toBe(true)
})

test('a failure tryNext says is not worth another account stops there, and every failure is kept', async () => {
  const r = runner(c => (c.argv[1] === 'issue' ? ran(1, '', 'HTTP 403') : ran(0, '', STATUS)))
  const out = await askAnyAccount(r.run, ['issue', 'edit', '7'], f => /Could not resolve/.test(f.stderr))
  expect(out).toEqual({ failures: [ran(1, '', 'HTTP 403')] })
  expect(r.calls.length).toBe(1)
})
