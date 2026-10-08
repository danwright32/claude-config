import { describe, expect, test } from 'claude-code/testing'
import type { Cmd } from '../hooks/nobuild.ts'
import { actsOf, addAnswer, HOLD_MERGES, isListed, MAY_DEPLOY, MERGE_NO_DEPLOY, nightRepos, policyOf, readMarker, readRepoLists, refusalOf, repoQuestion, type Scripts, type Where } from '../hooks/mergedeploy.ts'
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
  test('a good file reads as both lists; a mergeOnly entry that does not say whether a merge deploys reads as unknown, never as safe (L72)', () => {
    const r = readRepoLists(LISTS)
    expect('lists' in r && r.lists.mergeOnly).toEqual([
      { repo: 'Try-Pennie/slate', mergeDeploys: true },
      { repo: 'o/merges-quietly', mergeDeploys: false },
      { repo: 'o/unsaid', mergeDeploys: 'unknown' },
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
  test('each option means exactly what it says: merge never deploy only where a merge does not deploy, hold merges where it does or is unknown', () => {
    expect(repoQuestion('o/new')).toMatch(/only if a merge there does not itself deploy/)
    const merge = addAnswer(empty, 'o/new', MERGE_NO_DEPLOY)
    expect('text' in merge && JSON.parse(merge.text).mergeOnly).toEqual([{ repo: 'o/new', mergeDeploys: false }])
    const hold = addAnswer(empty, 'o/new', HOLD_MERGES)
    expect('text' in hold && JSON.parse(hold.text).mergeOnly).toEqual([{ repo: 'o/new', mergeDeploys: true }])
    const deploy = addAnswer(empty, 'o/new', MAY_DEPLOY)
    expect('text' in deploy && JSON.parse(deploy.text).mayDeploy).toEqual(['o/new'])
  })
  test('anything else, a repository already listed, and a broken file are refused', () => {
    expect(addAnswer(empty, 'o/new', 'maybe')).toEqual({ why: 'the answer was none of the choices ("maybe")' })
    expect(addAnswer('{"v":1,"mergeOnly":[],"mayDeploy":["O/New"]}', 'o/new', MERGE_NO_DEPLOY)).toEqual({ why: 'o/new is already listed' })
    expect(addAnswer('{"v":1,', 'o/new', HOLD_MERGES)).toEqual({ why: 'mods/sleep-repos.json is not JSON' })
  })
})

describe('a marker, read', () => {
  test('owner, time and nonce come back; anything else says why it cannot be read', () => {
    expect(readMarker('{"owner":"s1","at":5,"nonce":"n"}')).toEqual({ owner: 's1', at: 5, nonce: 'n' })
    expect(readMarker('g7')).toEqual({ unreadable: 'it is not JSON' })
    expect(readMarker('{"owner":"s1"}')).toEqual({ unreadable: 'it names no owner, time and nonce' })
  })
})

describe('what each repository may do tonight', () => {
  const night = nightRepos(readRepoLists(LISTS), [{ repo: 'o/gone', why: 'GitHub does not know o/gone' }])
  test('mayDeploy deploys; mergeOnly merges unless its merge deploys; case does not matter', () => {
    expect(policyOf(night, 'O/Deploys')).toEqual({ kind: 'deploy', repo: 'O/Deploys' })
    expect(policyOf(night, 'o/merges-quietly')).toEqual({ kind: 'merge-only', repo: 'o/merges-quietly', mergeDeploys: false })
    expect(policyOf(night, 'try-pennie/slate')).toEqual({ kind: 'merge-only', repo: 'try-pennie/slate', mergeDeploys: true })
    expect(policyOf(night, 'o/unsaid')).toEqual({ kind: 'merge-only', repo: 'o/unsaid', mergeDeploys: 'unknown' })
    // Not known not to deploy: the merge waits for the morning, and the refusal says why.
    expect(refusalOf({ kind: 'merge', what: 'merge a PR' }, policyOf(night, 'o/unsaid'))).toBe('whether a merge in o/unsaid deploys is not recorded in mods/sleep-repos.json, so it is never merged overnight')
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

describe('an owner whose every repository waits overnight (waitOwners)', () => {
  // Dan, 2026-10-07: "Move ANYTHING in halo-lab-trypennie to the wait list automatically. Nothing
  // in that account should merge overnight". Waiting is no merge and no deploy.
  const OWNED = JSON.stringify({
    v: 1,
    waitOwners: ['Halo-lab-Trypennie'],
    mergeOnly: [{ repo: 'Try-Pennie/slate', mergeDeploys: true }, { repo: 'Halo-lab-Trypennie/quiet', mergeDeploys: false }],
    mayDeploy: ['o/deploys', 'Halo-lab-Trypennie/listed'],
  })
  const night = nightRepos(readRepoLists(OWNED), [])
  const waits = (repo: string) => {
    const p = policyOf(night, repo)
    expect(refusalOf({ kind: 'merge', what: 'merge a PR' }, p)).toMatch(/every repository owned by Halo-lab-Trypennie waits overnight/)
    expect(refusalOf({ kind: 'deploy', what: 'deploy' }, p)).toMatch(/neither merges nor deploys/)
  }
  test('a repository under that owner that no list names, one added later, waits', () => {
    waits('Halo-lab-Trypennie/added-next-year')
  })
  test('the owner matches in any case', () => {
    waits('halo-lab-trypennie/trypennie')
    waits('HALO-LAB-TRYPENNIE/Trypennie')
    const shouty = nightRepos(readRepoLists(OWNED.replace('"Halo-lab-Trypennie"]', '"HALO-LAB-trypennie"]')), [])
    expect(policyOf(shouty, 'Halo-lab-Trypennie/trypennie')).toMatchObject({ kind: 'closed' })
  })
  test('a mayDeploy or merge only entry under that owner is a conflict, and it still waits', () => {
    waits('Halo-lab-Trypennie/listed')
    waits('Halo-lab-Trypennie/quiet')
  })
  test('only that owner: another owner, and a name that merely starts with it, keep their lists', () => {
    expect(policyOf(night, 'o/deploys')).toEqual({ kind: 'deploy', repo: 'o/deploys' })
    expect(policyOf(night, 'Halo-lab-Trypennie-other/x')).toMatchObject({ kind: 'closed', why: 'Halo-lab-Trypennie-other/x is on neither list in mods/sleep-repos.json' })
  })
  test('a repository under that owner is decided, so it is never asked about at bedtime, and an answer for it is refused', () => {
    const r = readRepoLists(OWNED)
    expect('lists' in r && isListed(r.lists, 'halo-lab-trypennie/new')).toBe(true)
    expect(addAnswer(OWNED, 'Halo-lab-Trypennie/new', MAY_DEPLOY)).toEqual({ why: 'Halo-lab-Trypennie/new is already listed' })
  })
  test('a waitOwners that is not a list of owner names closes every repository, never a partial rule', () => {
    const why = (t: string) => {
      const r = readRepoLists(t)
      return 'why' in r ? r.why : 'read'
    }
    expect(why('{"v":1,"waitOwners":"Halo-lab-Trypennie","mergeOnly":[],"mayDeploy":[]}')).toBe('mods/sleep-repos.json has a waitOwners that is not a list')
    expect(why('{"v":1,"waitOwners":["Halo-lab-Trypennie/trypennie"],"mergeOnly":[],"mayDeploy":[]}')).toMatch(/waitOwners entry that is not an owner name/)
    expect(why('{"v":1,"mergeOnly":[],"mayDeploy":[]}')).toBe('read')
  })
  test('the record carries the owners, and a record from before them still reads', () => {
    expect(night.waitOwners).toEqual(['Halo-lab-Trypennie'])
    expect(nightRepos(readRepoLists(LISTS), []).waitOwners).toBeUndefined()
    expect(policyOf({ mayDeploy: [], mergeOnly: [], closed: [], waitOwners: 'Halo-lab-Trypennie' }, 'o/x')).toMatchObject({ kind: 'closed', why: 'the sleep record carries no merge and deploy lists' })
  })
})

describe('what a command does, by effect', () => {
  test('every merge route: gh pr merge (and --auto), the merge helper, the REST merge endpoints and the GraphQL mutations', () => {
    expect(kinds('gh pr merge 12 --squash')).toEqual(['merge'])
    expect(acts('gh pr merge 12 --auto --squash')[0]?.what).toBe('merge a PR (auto merge)')
    expect(acts('gh pr merge 12 --repo Try-Pennie/slate')[0]?.repo).toBe('try-pennie/slate')
    // Every spelling gh reads, through phase 3's one reading of gh's arguments (ghargs.ts): a joined
    // -R, --repo=, a PR link naming its repository, and a joined --method.
    expect(acts('gh pr merge 12 -RTry-Pennie/slate')[0]?.repo).toBe('try-pennie/slate')
    expect(acts('gh pr merge 12 --repo=o/x')[0]?.repo).toBe('o/x')
    expect(acts('gh pr merge https://github.com/o/y/pull/3 --squash')[0]?.repo).toBe('o/y')
    expect(kinds('gh api --method=PUT repos/o/r/pulls/12/merge')).toEqual(['merge'])
    expect(kinds('gh api -XPUT repos/o/r/pulls/12/merge')).toEqual(['merge'])
    // A flag before the subcommand gh's reader cannot place: nothing it does can be said, so it is
    // judged as a merge into a repository that cannot be told.
    expect(acts('gh --weird pr merge 12')[0]).toMatchObject({ kind: 'merge', repo: null })
    expect(kinds('bash ~/.claude/hooks/lib/merge-when-ready.sh 12 --repo o/r --squash')).toEqual(['merge'])
    // The helper's joined -R names its repository as gh's does.
    expect(acts('bash ~/.claude/hooks/lib/merge-when-ready.sh 12 -Ro/x --squash')[0]?.repo).toBe('o/x')
    // Read by ghargs, as gh pr merge reads what the helper hands it: a PR link names its repository.
    expect(acts('bash ~/.claude/hooks/lib/merge-when-ready.sh https://github.com/o/z/pull/3 --squash')[0]?.repo).toBe('o/z')
    expect(acts('bash ~/.claude/hooks/lib/merge-when-ready.sh 12 --repo=o/w')[0]?.repo).toBe('o/w')
    // The merge queue merges too; a mutation writing a branch directly can reach the default one.
    expect(kinds(`gh api graphql -f query='mutation { enqueuePullRequest(input: {pullRequestId: "x"}) { clientMutationId } }'`)).toEqual(['merge'])
    expect(kinds(`gh api graphql -f query='mutation { createCommitOnBranch(input: {}) { clientMutationId } }'`)).toEqual(['push-default'])
    expect(kinds(`gh api graphql -f query='mutation { updateRef(input: {}) { clientMutationId } }'`)).toEqual(['push-default'])
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
    // A script named publish is a deploy script by name; bare `npm publish` is npm's own publish.
    expect(kinds('npm run publish')).toEqual(['deploy'])
    expect(kinds('pnpm run publish')).toEqual(['deploy'])
    expect(kinds('npm publish')).toEqual(['deploy'])
    expect(kinds('gh workflow run deploy.yml')).toEqual(['deploy'])
    expect(kinds('gh api -X POST repos/o/r/actions/workflows/deploy.yml/dispatches -f ref=main')).toEqual(['deploy'])
    const scripts: Scripts = { ship: cmds('next build && wrangler deploy'), test: cmds('vitest run'), build: cmds('next build') }
    const here: Where = { ...ON_BRANCH, scripts }
    expect(acts('npm run ship', here)).toEqual([{ kind: 'deploy', what: 'run the ship script, which would deploy with wrangler' }])
    expect(kinds('npm test', here)).toEqual([])
    expect(kinds('pnpm build', here)).toEqual([])
    // A package.json that cannot be read: any script it runs could deploy.
    expect(kinds('npm run build', { ...ON_BRANCH, scripts: { unreadable: 'not JSON' } })).toEqual(['deploy'])
    // A package manager's own command (install, ci, add) runs no script by that name, whatever is unreadable.
    for (const c of ['npm install', 'npm ci', 'npm i', 'yarn add left-pad', 'pnpm install', 'bun install']) expect(kinds(c, { ...ON_BRANCH, scripts: { unreadable: 'not JSON' } })).toEqual([])
    // `npm test` runs the script named test, so an unreadable package.json refuses it.
    expect(kinds('npm test', { ...ON_BRANCH, scripts: { unreadable: 'not JSON' } })).toEqual(['deploy'])
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
