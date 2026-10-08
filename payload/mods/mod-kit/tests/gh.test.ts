import { describe, expect, test } from 'claude-code/testing'
import { flagOf, ghArgs, hasFlag, type GhArgs } from '../hooks/gh.ts'

// The one reading of a gh command's arguments (#834, moved here from scope-modes in #961): each
// spelling gh accepts reads the same, and the repository it names is read by repo.ts's ghRepo.
const gh = (line: string) => ghArgs(line.split(' ')) as GhArgs
const api = (line: string) => gh(line).api as NonNullable<GhArgs['api']>

describe('ghArgs reads gh as pflag does', () => {
  test('words that are not gh are no gh command, a gh named by its path is', () => {
    expect(ghArgs(['git', 'status'])).toBeUndefined()
    expect(ghArgs([])).toBeUndefined()
    expect(ghArgs(['/opt/homebrew/bin/gh', 'pr', 'view'])?.sub).toBe('pr')
  })
  test('a long flag with its value joined or apart', () => {
    expect(api('gh api --method=DELETE repos/o/r/git/refs/heads/x').method).toBe('DELETE')
    expect(api('gh api --method DELETE repos/o/r/git/refs/heads/x').method).toBe('DELETE')
    expect(api('gh api --method=DELETE repos/o/r/git/refs/heads/x').endpoint).toBe('repos/o/r/git/refs/heads/x')
  })
  test('a short flag with its value attached', () => {
    expect(api('gh api -XDELETE repos/o/r/git/refs/heads/x').method).toBe('DELETE')
    expect(api('gh api -fkey=val repos/o/r/pulls')).toEqual({ method: 'POST', endpoint: 'repos/o/r/pulls', fields: ['key=val'], input: false, repo: 'o/r', query: null })
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
  test('only gh api carries an api reading', () => {
    expect(gh('gh pr view 5').api).toBeUndefined()
    expect(api('gh api repos/o/r/pulls/5').method).toBe('GET')
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
    const a2 = gh('gh -R o/x api repos/o/r/pulls')
    expect([a2.named, a2.api?.endpoint]).toEqual(['o/x', 'repos/o/r/pulls'])
  })
  test('an unknown flag before the subcommand makes the repository unresolvable', () => {
    const a = gh('gh --frob x pr close 5')
    expect(a.named).toBeNull()
    expect(a.unreadable).toBe(true)
  })
  test('then a github.com link among the positionals', () => {
    expect(gh('gh pr ready https://github.com/other/x/pull/5').named).toBe('other/x')
    expect(gh('gh issue comment https://github.com/my.org/x/issues/9 -b hi').named).toBe('my.org/x')
    // A link that names no repository gh could have is one that cannot be read, never none.
    expect(gh('gh pr ready https://github.com/o/.git/pull/5').named).toBeNull()
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
})

// The repository a `gh api` endpoint names, as gh reaches it: gh takes an endpoint starting
// https:// as an address as it stands, and otherwise trims one leading slash and puts it after
// https://api.github.com/. One read here for the overnight rules and the merge judge, which each
// matched endpoints their own way (#961).
describe('the repository a gh api endpoint names', () => {
  const repo = (endpoint: string) => api(`gh api -X POST ${endpoint}`).repo
  test('repos/<owner>/<name>, in each spelling gh reaches', () => {
    expect(repo('repos/O/R/pulls/1/merge')).toBe('o/r')
    expect(repo('/repos/o/r/pulls/1/merge')).toBe('o/r')
    expect(repo('https://api.github.com/repos/o/r/pulls/1/merge')).toBe('o/r')
    expect(repo('repos/o/r?per_page=5')).toBe('o/r')
    expect(repo('repos/my.org/x/dispatches')).toBe('my.org/x')
  })
  test("gh's placeholders for the current repository name none, so the checkout decides", () => {
    expect(repo('repos/{owner}/{repo}/pulls/1/merge')).toBeUndefined()
    expect(repo('repos/:owner/:repo/issues/1/comments')).toBeUndefined()
  })
  test('one placeholder beside a real name cannot be read: gh fills it from the checkout', () => {
    expect(repo('repos/{owner}/x/pulls/1/merge')).toBeNull()
    expect(repo('repos/o/{repo}/pulls/1/merge')).toBeNull()
  })
  test('a spelling gh does not send to repos/ is one that cannot be read, never none', () => {
    expect(repo('//repos/o/r/pulls/1/merge')).toBeNull()
    expect(repo('///repos/o/r/pulls/1/merge')).toBeNull()
    expect(repo('https://api.github.com//repos/o/r/pulls/1/merge')).toBeNull()
    expect(repo('/https://api.github.com/repos/o/r/pulls/1/merge')).toBeNull()
    expect(repo('repos/o')).toBeNull()
    expect(repo('repos/o r/x/merges')).toBeNull()
  })
  test('an endpoint outside repos/ names none', () => {
    expect(repo('graphql')).toBeUndefined()
    expect(repo('user/repos')).toBeUndefined()
    expect(repo('orgs/o/repos')).toBeUndefined()
    expect(gh('gh api').api?.repo).toBeUndefined()
  })
})

describe('the GraphQL document a gh api call sends', () => {
  const query = (words: string[]) => (ghArgs(['gh', 'api', 'graphql', ...words]) as GhArgs).api?.query
  test('from its query field, in every spelling gh reads', () => {
    expect(query(['-f', 'query={ viewer { login } }'])).toBe('{ viewer { login } }')
    expect(query(['-fquery={ viewer { login } }'])).toBe('{ viewer { login } }')
    expect(query(['--field=query={ viewer { login } }'])).toBe('{ viewer { login } }')
    expect(query(['-F', 'query=@x', '-f', 'query={ a }'])).toBe('{ a }')
  })
  test('none when it cannot be read: none given, a file gh reads, or a body from --input', () => {
    expect(query([])).toBeNull()
    expect(query(['-F', 'query=@q.graphql'])).toBeNull()
    expect(query(['-f', 'query={ a }', '--input', 'body.json'])).toBeNull()
    // -f takes an @ as written.
    expect(query(['-f', 'query=@literal'])).toBe('@literal')
  })
})
