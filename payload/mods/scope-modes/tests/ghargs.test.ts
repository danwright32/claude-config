import { describe, expect, test } from 'claude-code/testing'
import { flagOf, ghApi, ghArgs, hasFlag, normRepo } from '../hooks/ghargs.ts'

// The one reading of gh's arguments in this mod (#834): each spelling gh accepts reads the same.
const gh = (line: string) => ghArgs(line.split(' '))

describe('ghArgs reads gh as pflag does', () => {
  test('a long flag with its value joined or apart', () => {
    expect(ghApi(gh('gh api --method=DELETE repos/o/r/git/refs/heads/x')).method).toBe('DELETE')
    expect(ghApi(gh('gh api --method DELETE repos/o/r/git/refs/heads/x')).method).toBe('DELETE')
    expect(ghApi(gh('gh api --method=DELETE repos/o/r/git/refs/heads/x')).endpoint).toBe('repos/o/r/git/refs/heads/x')
  })
  test('a short flag with its value attached', () => {
    expect(ghApi(gh('gh api -XDELETE repos/o/r/git/refs/heads/x')).method).toBe('DELETE')
    expect(ghApi(gh('gh api -fkey=val repos/o/r/pulls'))).toEqual({ method: 'POST', endpoint: 'repos/o/r/pulls', fields: ['key=val'], input: false })
    expect(gh('gh pr comment 5 -Rother/x -b hi').named).toBe('other/x')
  })
  test('short flags clustered, each a flag of its own', () => {
    const a = gh('gh pr merge 5 -sd')
    expect(hasFlag(a, '-s')).toBe(true)
    expect(hasFlag(a, '-d', '--delete-branch')).toBe(true)
    // The same letter takes a value where the command gives it one: -m is a milestone to create.
    expect(flagOf(gh('gh pr create -m Sleep -t x'), '-m', '--milestone')).toBe('Sleep')
    expect(flagOf(gh('gh pr merge 5 -m'), '-m')).toBe(true)
  })
  test('the subcommand, its action and its positionals, past every flag and value', () => {
    const a = gh('gh issue comment -R o/r 834 --body x')
    expect([a.sub, a.act, a.positionals]).toEqual(['issue', 'comment', ['834']])
    expect(gh('gh api -X POST repos/o/r/issues -f title=x').positionals).toEqual(['repos/o/r/issues'])
  })
})

describe('the repository a gh command names', () => {
  test('-R or --repo first, in every spelling, a dotted owner included', () => {
    expect(gh('gh pr close 5 -R other/x').named).toBe('other/x')
    expect(gh('gh pr close 5 --repo=other/x').named).toBe('other/x')
    expect(gh('gh pr close 5 --repo other/x').named).toBe('other/x')
    expect(gh('gh pr close 5 -R my.org/x').named).toBe('my.org/x')
    expect(gh('gh pr close 5 -R https://github.com/Other/X').named).toBe('other/x')
  })
  test('a global flag before the subcommand is read, its value never taken for the subcommand', () => {
    const a = gh('gh -R other/x pr close 5')
    expect([a.sub, a.act, a.positionals, a.named]).toEqual(['pr', 'close', ['5'], 'other/x'])
    expect(gh('gh --repo=o/x pr merge 3').named).toBe('o/x')
    expect(gh('gh --repo o/x pr merge 3').sub).toBe('pr')
    // Read once, as a global flag, whatever value flags the subcommand has (#834 review of 734e266).
    const api = gh('gh -R o/x api repos/o/r/pulls')
    expect([api.named, ghApi(api).endpoint]).toEqual(['o/x', 'repos/o/r/pulls'])
  })
  test('an unknown flag before the subcommand makes the repository unresolvable', () => {
    const a = gh('gh --frob x pr close 5')
    expect(a.named).toBeNull()
    expect(a.unreadable).toBe(true)
  })
  test('then a github.com link among the positionals', () => {
    expect(gh('gh pr ready https://github.com/other/x/pull/5').named).toBe('other/x')
    expect(gh('gh issue comment https://github.com/my.org/x/issues/9 -b hi').named).toBe('my.org/x')
  })
  test('then, for gh repo, an owner/name positional', () => {
    expect(gh('gh repo delete other/x --yes').named).toBe('other/x')
    // A path to a file is not a repository for any other subcommand.
    expect(gh('gh release upload v1 dist/app.zip').named).toBeUndefined()
  })
  test('none named is undefined, so the checkout decides; one that cannot be read is null', () => {
    expect(gh('gh pr comment 5 -b hi').named).toBeUndefined()
    expect(gh('gh pr comment 5 -R nonsense -b hi').named).toBeNull()
    expect(gh('gh pr comment 5 -R https://gitlab.com/o/r -b hi').named).toBeNull()
  })
  test('normRepo reads a dotted owner and refuses what is no repository', () => {
    expect(normRepo('my.org/x')).toBe('my.org/x')
    expect(normRepo('git@github.com:my.org/x.git')).toBe('my.org/x')
    expect(normRepo('a/b/c')).toBeNull()
  })
})
