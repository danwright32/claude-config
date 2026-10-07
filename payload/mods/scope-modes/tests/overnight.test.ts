import { describe, expect, test } from 'claude-code/testing'
import type { Cmd } from '../hooks/nobuild.ts'
import { actsOf, addAnswer, MAY_DEPLOY, MERGE_ONLY, nightRepos, policyOf, readRepoLists, refusalOf, type Scripts, type Where } from '../hooks/overnight.ts'
import { git, pipeline } from './mod-kit/hooks/commands.ts'

// Sleep mode phase 7 (#843). Commands are read by mod-kit's own reader (its byte for byte copy
// under tests/mod-kit), as the mod reads them in a session.
const cmds = (command: string): Cmd[] =>
  pipeline(command).map(c => {
    const g = git(c.words)
    return g ? { ...c, git: { sub: g.sub, args: g.args } } : c
  })
const ON_BRANCH: Where = { defaultBranch: 'main', currentBranch: 'fix-843', scripts: null }
const acts = (command: string, where: Where = ON_BRANCH) => cmds(command).flatMap(c => actsOf(c, where))
const kinds = (command: string, where?: Where) => acts(command, where).map(a => a.kind)

const LISTS = JSON.stringify({
  v: 1,
  mergeOnly: [{ repo: 'Try-Pennie/slate', mergeDeploys: true }, { repo: 'o/merges-quietly', mergeDeploys: false }, { repo: 'o/unsaid' }],
  mayDeploy: ['o/deploys'],
})

describe('the shared lists, read', () => {
  test('a good file reads as both lists; a mergeOnly entry that does not say is taken to deploy on merge (L72)', () => {
    const r = readRepoLists(LISTS)
    expect('lists' in r && r.lists.mergeOnly).toEqual([
      { repo: 'Try-Pennie/slate', mergeDeploys: true },
      { repo: 'o/merges-quietly', mergeDeploys: false },
      { repo: 'o/unsaid', mergeDeploys: true },
    ])
  })
  test('a missing file, one that does not parse, a wrong shape and a bad entry each say why, never a partial list', () => {
    const why = (t: string | null) => {
      const r = readRepoLists(t)
      return 'why' in r ? r.why : 'read'
    }
    expect(why(null)).toBe('mods/sleep-repos.json is missing')
    expect(why('{"v":1,')).toBe('mods/sleep-repos.json is not JSON')
    expect(why('[]')).toBe('mods/sleep-repos.json is not a record')
    expect(why('{"mergeOnly":[],"mayDeploy":[]}')).toBe('mods/sleep-repos.json has no version this reader knows')
    expect(why('{"v":1,"mergeOnly":[]}')).toBe('mods/sleep-repos.json does not hold both lists')
    expect(why('{"v":1,"mergeOnly":[],"mayDeploy":["slate"]}')).toMatch(/mayDeploy entry that is not owner\/name/)
    expect(why('{"v":1,"mergeOnly":[{"repo":"o/r","mergeDeploys":"yes"}],"mayDeploy":[]}')).toMatch(/mergeDeploys that is not true or false/)
  })
})

describe('a bedtime answer, added to the shared file', () => {
  const empty = '{"v":1,"mergeOnly":[],"mayDeploy":[]}'
  test('merge only is added with mergeDeploys unsaid, so its merges wait until the file says a merge does not deploy (L72)', () => {
    const r = addAnswer(empty, 'o/new', MERGE_ONLY)
    expect('text' in r && JSON.parse(r.text)).toEqual({ v: 1, mergeOnly: [{ repo: 'o/new' }], mayDeploy: [] })
    const lists = readRepoLists('text' in r ? r.text : null)
    expect('lists' in lists && lists.lists.mergeOnly).toEqual([{ repo: 'o/new', mergeDeploys: true }])
  })
  test('allowed to deploy goes on mayDeploy; anything else, a repository already listed, and a broken file are refused', () => {
    const r = addAnswer(empty, 'o/new', MAY_DEPLOY)
    expect('text' in r && JSON.parse(r.text).mayDeploy).toEqual(['o/new'])
    expect(addAnswer(empty, 'o/new', 'maybe')).toEqual({ why: 'the answer was neither choice ("maybe")' })
    expect(addAnswer('{"v":1,"mergeOnly":[],"mayDeploy":["O/New"]}', 'o/new', MERGE_ONLY)).toEqual({ why: 'o/new is already listed' })
    expect(addAnswer('{"v":1,', 'o/new', MERGE_ONLY)).toEqual({ why: 'mods/sleep-repos.json is not JSON' })
  })
})

describe('what each repository may do tonight', () => {
  const night = nightRepos(readRepoLists(LISTS), [{ repo: 'o/gone', why: 'GitHub does not know o/gone' }])
  test('mayDeploy deploys; mergeOnly merges unless its merge deploys; case does not matter', () => {
    expect(policyOf(night, 'O/Deploys')).toEqual({ kind: 'deploy', repo: 'O/Deploys' })
    expect(policyOf(night, 'o/merges-quietly')).toEqual({ kind: 'merge-only', repo: 'o/merges-quietly', mergeDeploys: false })
    expect(policyOf(night, 'try-pennie/slate')).toEqual({ kind: 'merge-only', repo: 'try-pennie/slate', mergeDeploys: true })
  })
  test('a repository on neither list fails closed, with no merge and no deploy', () => {
    const p = policyOf(night, 'o/new')
    expect(p).toEqual({ kind: 'closed', repo: 'o/new', why: 'o/new is on neither list in mods/sleep-repos.json' })
    expect(refusalOf({ kind: 'merge', what: 'merge a PR' }, p)).toMatch(/neither merges nor deploys/)
    expect(refusalOf({ kind: 'deploy', what: 'deploy' }, p)).toMatch(/neither merges nor deploys/)
  })
  test('a list that could not be read fails closed for every repository, the listed ones too', () => {
    const broken = nightRepos(readRepoLists('{"v":1,'), [])
    for (const repo of ['o/deploys', 'Try-Pennie/slate', 'o/new']) expect(policyOf(broken, repo)).toEqual({ kind: 'closed', repo, why: 'mods/sleep-repos.json is not JSON' })
    const missing = nightRepos(readRepoLists(null), [])
    expect(policyOf(missing, 'o/deploys')).toEqual({ kind: 'closed', repo: 'o/deploys', why: 'mods/sleep-repos.json is missing' })
  })
  test('a repository on both lists is closed, never given the looser one', () => {
    const both = nightRepos(readRepoLists('{"v":1,"mergeOnly":[{"repo":"o/x","mergeDeploys":false}],"mayDeploy":["o/x"]}'), [])
    expect(policyOf(both, 'o/x')).toEqual({ kind: 'closed', repo: 'o/x', why: 'o/x is on both lists in mods/sleep-repos.json' })
  })
  test('an entry GitHub did not know, a question left unanswered, an untold repository and a record with no lists are all closed', () => {
    expect(policyOf(night, 'o/gone')).toEqual({ kind: 'closed', repo: 'o/gone', why: 'GitHub does not know o/gone' })
    expect(policyOf(night, undefined)).toEqual({ kind: 'closed', why: 'which repository this reaches could not be told' })
    expect(policyOf(undefined, 'o/deploys')).toEqual({ kind: 'closed', repo: 'o/deploys', why: 'the sleep record carries no merge and deploy lists' })
  })
  test('what each policy refuses', () => {
    const deploy = policyOf(night, 'o/deploys')
    const quiet = policyOf(night, 'o/merges-quietly')
    const loud = policyOf(night, 'Try-Pennie/slate')
    const merge = { kind: 'merge' as const, what: 'merge a PR' }
    const dep = { kind: 'deploy' as const, what: 'deploy with wrangler' }
    const push = { kind: 'push-default' as const, what: 'push main straight to GitHub' }
    expect([refusalOf(merge, deploy), refusalOf(dep, deploy)]).toEqual([undefined, undefined])
    expect(refusalOf(merge, quiet)).toBe(undefined)
    expect(refusalOf(dep, quiet)).toBe('o/merges-quietly may merge overnight but never deploy')
    expect(refusalOf(merge, loud)).toBe('a merge in Try-Pennie/slate deploys, so it is never merged overnight')
    // A direct push to a default branch is refused in every repository, deploying ones included.
    for (const p of [deploy, quiet, loud]) expect(refusalOf(push, p)).toMatch(/never made overnight/)
  })
})

describe('what a command does, by effect', () => {
  test('every merge route: gh pr merge (and --auto), the merge helper, the REST merge endpoints and the GraphQL mutations', () => {
    expect(kinds('gh pr merge 12 --squash')).toEqual(['merge'])
    expect(acts('gh pr merge 12 --auto --squash')[0]?.what).toBe('merge a PR (auto merge)')
    expect(acts('gh pr merge 12 --repo Try-Pennie/slate')[0]?.repo).toBe('Try-Pennie/slate')
    expect(kinds('bash ~/.claude/hooks/lib/merge-when-ready.sh 12 --repo o/r --squash')).toEqual(['merge'])
    expect(acts('gh api -X PUT repos/o/r/pulls/12/merge')).toEqual([{ kind: 'merge', what: 'merge through the GitHub API (repos/o/r/pulls/12/merge)', repo: 'o/r' }])
    expect(kinds('gh api repos/o/r/merges -f base=main -f head=x')).toEqual(['merge'])
    expect(kinds(`gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: "x"}) { clientMutationId } }'`)).toEqual(['merge'])
    expect(kinds(`gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {pullRequestId: "x"}) { clientMutationId } }'`)).toEqual(['merge'])
    // A query that cannot be read is judged as the strictest thing it could be.
    expect(kinds('gh api graphql -F query=@q.graphql')).toEqual(['merge'])
  })
  test('reads are not merges: viewing a PR, reading its merge state, a GraphQL query', () => {
    expect(kinds('gh pr view 12 --json mergeable')).toEqual([])
    expect(kinds('gh api repos/o/r/pulls/12/merge')).toEqual([])
    expect(kinds(`gh api graphql -f query='query { repository(owner: "o", name: "r") { name } }'`)).toEqual([])
    expect(kinds('git merge origin/main')).toEqual([])
  })
  test('deploys: the deploy tools no build knows, gh workflow run, a dispatch, and a package script by name or by body', () => {
    expect(kinds('npx wrangler deploy')).toEqual(['deploy'])
    expect(kinds('supabase db push')).toEqual(['deploy'])
    expect(kinds('npm run deploy')).toEqual(['deploy'])
    expect(kinds('gh workflow run deploy.yml')).toEqual(['deploy'])
    expect(kinds('gh api -X POST repos/o/r/actions/workflows/deploy.yml/dispatches -f ref=main')).toEqual(['deploy'])
    const scripts: Scripts = { ship: cmds('next build && wrangler deploy'), test: cmds('vitest run'), build: cmds('next build') }
    const here: Where = { ...ON_BRANCH, scripts }
    expect(acts('npm run ship', here)).toEqual([{ kind: 'deploy', what: 'run the ship script, which would deploy with wrangler' }])
    expect(kinds('npm test', here)).toEqual([])
    expect(kinds('pnpm build', here)).toEqual([])
    // A package.json that cannot be read: any script it runs could deploy.
    expect(kinds('npm run build', { ...ON_BRANCH, scripts: { unreadable: 'not JSON' } })).toEqual(['deploy'])
    // No package.json: nothing to run.
    expect(kinds('npm run build')).toEqual([])
  })
  test('a push reaching the default branch, by refspec, by HEAD, by pushing everything, or bare from the default branch', () => {
    expect(kinds('git push origin main')).toEqual(['push-default'])
    expect(kinds('git push origin HEAD:refs/heads/main')).toEqual(['push-default'])
    expect(kinds('git push --force origin +main')).toEqual(['push-default'])
    expect(kinds('git push --all origin')).toEqual(['push-default'])
    expect(kinds('git push', { ...ON_BRANCH, currentBranch: 'main' })).toEqual(['push-default'])
    expect(kinds('git push origin HEAD', { ...ON_BRANCH, currentBranch: 'main' })).toEqual(['push-default'])
    // A branch of its own is ordinary overnight work.
    expect(kinds('git push -u origin fix-843')).toEqual([])
    expect(kinds('git push')).toEqual([])
    expect(kinds('git push origin HEAD')).toEqual([])
    // A current branch that cannot be read is judged the strict way.
    expect(kinds('git push', { ...ON_BRANCH, currentBranch: null })).toEqual(['push-default'])
    // With no default branch known, main and master both count.
    expect(kinds('git push origin master', { ...ON_BRANCH, defaultBranch: null })).toEqual(['push-default'])
    expect(kinds('gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc')).toEqual(['push-default'])
  })
})
