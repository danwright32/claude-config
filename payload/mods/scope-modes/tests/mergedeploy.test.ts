import { describe, expect, test } from 'claude-code/testing'
import { actsOf, addAnswer, dirsOf, HOLD_MERGES, isListed, judgeNight, MAY_DEPLOY, MERGE_NO_DEPLOY, nightRepos, policyOf, readMarker, readRepoLists, refusalOf, repoQuestion, type Place, type Scripts, type Where } from '../hooks/mergedeploy.ts'
import type { ModKitGh } from '../.claude-plugin/types/mod-kit/index.d.ts'
import type { Cmd } from '../hooks/nobuild.ts'
import { API_MERGE_CASES } from './api-merge-cases.ts'
import { mergeHelperArgs } from './mod-kit/hooks/gh.ts'
import { GH_REPO_FIXTURES } from './mod-kit/tests/gh-fixtures.ts'
import { readCommands } from './read.ts'

// Sleep mode phase 7 (#843). Commands are read by mod-kit's own readers (byte for byte copies under
// tests/mod-kit), as the mod reads them in a session.
const cmds = readCommands
const ON_BRANCH: Where = { defaultBranch: 'main', currentBranch: 'fix-843', scripts: null }
const acts = (command: string, where: Where = ON_BRANCH) => cmds(command).flatMap(c => actsOf(c, where))
const kinds = (command: string, where?: Where) => acts(command, where).map(a => a.kind)

const LISTS = JSON.stringify({
  v: 1,
  mergeOnly: [{ repo: 'Acme-Corp/storefront', mergeDeploys: true }, { repo: 'o/merges-quietly', mergeDeploys: false }, { repo: 'o/unsaid' }],
  mayDeploy: ['o/deploys'],
})

describe('the lists file of this Mac, read', () => {
  test('a good file reads as both lists; a mergeOnly entry that does not say whether a merge deploys reads as unknown, never as safe (L72)', () => {
    const r = readRepoLists(LISTS)
    expect('lists' in r && r.lists.mergeOnly).toEqual([
      { repo: 'Acme-Corp/storefront', mergeDeploys: true },
      { repo: 'o/merges-quietly', mergeDeploys: false },
      { repo: 'o/unsaid', mergeDeploys: 'unknown' },
    ])
  })
  test('a missing file, one that does not parse, a wrong shape and a bad entry each say why, never a partial list', () => {
    const why = (t: string | null) => {
      const r = readRepoLists(t)
      return 'why' in r ? r.why : 'read'
    }
    expect(why(null)).toBe('mods/sleep-repos.local.json is missing')
    expect(why('{"v":1,')).toBe('mods/sleep-repos.local.json is not JSON')
    expect(why('[]')).toBe('mods/sleep-repos.local.json is not a record')
    expect(why('{"mergeOnly":[],"mayDeploy":[]}')).toBe('mods/sleep-repos.local.json has no version this reader knows')
    expect(why('{"v":1,"mergeOnly":[]}')).toBe('mods/sleep-repos.local.json does not hold both lists')
    expect(why('{"v":1,"mergeOnly":[],"mayDeploy":["slate"]}')).toMatch(/mayDeploy entry that is not owner\/name/)
    expect(why('{"v":1,"mergeOnly":[{"repo":"o/r","mergeDeploys":"yes"}],"mayDeploy":[]}')).toMatch(/mergeDeploys that is not true or false/)
  })
})

describe('a bedtime answer, added to the lists file of this Mac', () => {
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
    expect(addAnswer('{"v":1,', 'o/new', HOLD_MERGES)).toEqual({ why: 'mods/sleep-repos.local.json is not JSON' })
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
    expect(policyOf(night, 'acme-corp/storefront')).toEqual({ kind: 'merge-only', repo: 'acme-corp/storefront', mergeDeploys: true })
    expect(policyOf(night, 'o/unsaid')).toEqual({ kind: 'merge-only', repo: 'o/unsaid', mergeDeploys: 'unknown' })
    // Not known not to deploy: the merge waits for the morning, and the refusal says why.
    expect(refusalOf({ kind: 'merge', what: 'merge a PR' }, policyOf(night, 'o/unsaid'))).toBe('whether a merge in o/unsaid deploys is not recorded in mods/sleep-repos.local.json, so it is never merged overnight')
  })
  test('a repository on neither list fails closed, with no merge and no deploy', () => {
    const p = policyOf(night, 'o/new')
    expect(p).toEqual({ kind: 'closed', repo: 'o/new', why: 'o/new is on neither list in mods/sleep-repos.local.json' })
    expect(refusalOf({ kind: 'merge', what: 'merge a PR' }, p)).toMatch(/neither merges nor deploys/)
    expect(refusalOf({ kind: 'deploy', what: 'deploy' }, p)).toMatch(/neither merges nor deploys/)
  })
  test('a list that could not be read fails closed for every repository, the listed ones too', () => {
    const broken = nightRepos(readRepoLists('{"v":1,'), [])
    for (const repo of ['o/deploys', 'Acme-Corp/storefront', 'o/new']) expect(policyOf(broken, repo)).toEqual({ kind: 'closed', repo, why: 'mods/sleep-repos.local.json is not JSON' })
    const missing = nightRepos(readRepoLists(null), [])
    expect(policyOf(missing, 'o/deploys')).toEqual({ kind: 'closed', repo: 'o/deploys', why: 'mods/sleep-repos.local.json is missing' })
  })
  test('a repository on both lists is closed, never given the looser one', () => {
    const both = nightRepos(readRepoLists('{"v":1,"mergeOnly":[{"repo":"o/x","mergeDeploys":false}],"mayDeploy":["o/x"]}'), [])
    expect(policyOf(both, 'o/x')).toEqual({ kind: 'closed', repo: 'o/x', why: 'o/x is on both lists in mods/sleep-repos.local.json' })
  })
  test('an entry GitHub did not know, a question left unanswered, an untold repository and a record with no lists are all closed', () => {
    expect(policyOf(night, 'o/gone')).toEqual({ kind: 'closed', repo: 'o/gone', why: 'GitHub does not know o/gone' })
    expect(policyOf(night, undefined)).toEqual({ kind: 'closed', why: 'which repository this reaches could not be told' })
    expect(policyOf(undefined, 'o/deploys')).toEqual({ kind: 'closed', repo: 'o/deploys', why: 'the sleep record carries no merge and deploy lists' })
  })
  test('what each policy refuses', () => {
    const deploy = policyOf(night, 'o/deploys')
    const quiet = policyOf(night, 'o/merges-quietly')
    const loud = policyOf(night, 'Acme-Corp/storefront')
    const merge = { kind: 'merge' as const, what: 'merge a PR' }
    const dep = { kind: 'deploy' as const, what: 'deploy with wrangler' }
    const push = { kind: 'push-default' as const, what: 'push main straight to GitHub' }
    expect([refusalOf(merge, deploy), refusalOf(dep, deploy)]).toEqual([undefined, undefined])
    expect(refusalOf(merge, quiet)).toBe(undefined)
    expect(refusalOf(dep, quiet)).toBe('o/merges-quietly may merge overnight but never deploy')
    expect(refusalOf(merge, loud)).toBe('a merge in Acme-Corp/storefront deploys, so it is never merged overnight')
    // A direct push to a default branch is refused in every repository, deploying ones included.
    for (const p of [deploy, quiet, loud]) expect(refusalOf(push, p)).toMatch(/never made overnight/)
  })
})

describe('an owner whose every repository waits overnight (waitOwners)', () => {
  // Dan, 2026-10-07, asked for anything in the agency's organisation to go to the wait list
  // automatically, so nothing in that account merges overnight (paraphrased: his words name the
  // organisation, claude-config#1568). Waiting is no merge and no deploy.
  const OWNED = JSON.stringify({
    v: 1,
    waitOwners: ['Studio-Partner'],
    mergeOnly: [{ repo: 'Acme-Corp/storefront', mergeDeploys: true }, { repo: 'Studio-Partner/quiet', mergeDeploys: false }],
    mayDeploy: ['o/deploys', 'Studio-Partner/listed'],
  })
  const night = nightRepos(readRepoLists(OWNED), [])
  const waits = (repo: string) => {
    const p = policyOf(night, repo)
    expect(refusalOf({ kind: 'merge', what: 'merge a PR' }, p)).toMatch(/every repository owned by Studio-Partner waits overnight/)
    expect(refusalOf({ kind: 'deploy', what: 'deploy' }, p)).toMatch(/neither merges nor deploys/)
  }
  test('a repository under that owner that no list names, one added later, waits', () => {
    waits('Studio-Partner/added-next-year')
  })
  test('the owner matches in any case', () => {
    waits('studio-partner/website')
    waits('STUDIO-PARTNER/Website')
    const shouty = nightRepos(readRepoLists(OWNED.replace('"Studio-Partner"]', '"STUDIO-partner"]')), [])
    expect(policyOf(shouty, 'Studio-Partner/website')).toMatchObject({ kind: 'closed' })
  })
  test('a mayDeploy or merge only entry under that owner is a conflict, and it still waits', () => {
    waits('Studio-Partner/listed')
    waits('Studio-Partner/quiet')
  })
  test('only that owner: another owner, and a name that merely starts with it, keep their lists', () => {
    expect(policyOf(night, 'o/deploys')).toEqual({ kind: 'deploy', repo: 'o/deploys' })
    expect(policyOf(night, 'Studio-Partner-other/x')).toMatchObject({ kind: 'closed', why: 'Studio-Partner-other/x is on neither list in mods/sleep-repos.local.json' })
  })
  test('a repository under that owner is decided, so it is never asked about at bedtime, and an answer for it is refused', () => {
    const r = readRepoLists(OWNED)
    expect('lists' in r && isListed(r.lists, 'studio-partner/new')).toBe(true)
    expect(addAnswer(OWNED, 'Studio-Partner/new', MAY_DEPLOY)).toEqual({ why: 'Studio-Partner/new is already listed' })
  })
  test('a waitOwners that is not a list of owner names closes every repository, never a partial rule', () => {
    const why = (t: string) => {
      const r = readRepoLists(t)
      return 'why' in r ? r.why : 'read'
    }
    expect(why('{"v":1,"waitOwners":"Studio-Partner","mergeOnly":[],"mayDeploy":[]}')).toBe('mods/sleep-repos.local.json has a waitOwners that is not a list')
    expect(why('{"v":1,"waitOwners":["Studio-Partner/website"],"mergeOnly":[],"mayDeploy":[]}')).toMatch(/waitOwners entry that is not an owner name/)
    expect(why('{"v":1,"mergeOnly":[],"mayDeploy":[]}')).toBe('read')
  })
  test('the record carries the owners, and a record from before them still reads', () => {
    expect(night.waitOwners).toEqual(['Studio-Partner'])
    expect(nightRepos(readRepoLists(LISTS), []).waitOwners).toBeUndefined()
    expect(policyOf({ mayDeploy: [], mergeOnly: [], closed: [], waitOwners: 'Studio-Partner' }, 'o/x')).toMatchObject({ kind: 'closed', why: 'the sleep record carries no merge and deploy lists' })
  })
})

describe('what a command does, by effect', () => {
  // #961: the repository a merge names, by gh and by the merge helper, on the table every reading
  // of a repository gh spells is pinned on (null is one that cannot be told, closed).
  test('the repository a merge names is read as gh reads it, on every shared case (#961)', () => {
    const repoOf = (command: string) => acts(command).find(a => a.kind === 'merge')?.repo
    const got = GH_REPO_FIXTURES.map(f => ({ why: f.why, gh: repoOf(`gh pr merge 12 --squash -R '${f.spelling}'`), helper: repoOf(`bash ~/.claude/hooks/lib/merge-when-ready.sh 12 --squash --repo '${f.spelling}'`) }))
    expect(got).toEqual(GH_REPO_FIXTURES.map(f => ({ why: f.why, gh: f.repo, helper: f.repo })))
  })
  test('every merge route: gh pr merge (and --auto), the merge helper, the REST merge endpoints and the GraphQL mutations', () => {
    expect(kinds('gh pr merge 12 --squash')).toEqual(['merge'])
    expect(acts('gh pr merge 12 --auto --squash')[0]?.what).toBe('merge a PR (auto merge)')
    expect(acts('gh pr merge 12 --repo Acme-Corp/storefront')[0]?.repo).toBe('acme-corp/storefront')
    // Every spelling gh reads, through mod-kit's one reading of gh's arguments ($.modkit.gh, #961): a joined
    // -R, --repo=, a PR link naming its repository, and a joined --method.
    expect(acts('gh pr merge 12 -RAcme-Corp/storefront')[0]?.repo).toBe('acme-corp/storefront')
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
    // Read by mod-kit's gh reader, as gh pr merge reads what the helper hands it: a PR link names its repository.
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
  // #961: the endpoint's repository is read as gh reaches it, by mod-kit's reader. A spelling gh does
  // not send to repos/, one placeholder beside a name, or a name gh could not have, is a repository
  // that cannot be told (closed); before, it was judged by the command's or the checkout's.
  test("an endpoint's repository that cannot be read is one that cannot be told, never the checkout's (#961)", () => {
    const repoOf = (command: string) => acts(command)[0]?.repo
    expect(repoOf('gh api -X PUT //repos/o/r/pulls/12/merge')).toBeNull()
    expect(repoOf('gh api -X PUT ///repos/o/r/pulls/12/merge')).toBeNull()
    expect(repoOf('gh api -X PUT https://api.github.com//repos/o/r/pulls/12/merge')).toBeNull()
    expect(repoOf(`gh api -X PUT 'repos/{owner}/x/pulls/12/merge'`)).toBeNull()
    expect(repoOf(`gh api -X PUT 'repos/o?x/r/pulls/12/merge'`)).toBeNull()
    // gh's placeholders for the current repository name none, so the one the command names decides.
    expect(repoOf(`gh api -X PUT 'repos/{owner}/{repo}/pulls/12/merge'`)).toBeUndefined()
    expect(repoOf(`gh -R o/x api -X PUT 'repos/{owner}/{repo}/pulls/12/merge'`)).toBe('o/x')
    expect(repoOf('gh api -X PUT https://api.github.com/repos/O/R/pulls/12/merge')).toBe('o/r')
  })
  test('a command the mod was given no gh reading for is judged as a merge into a repository that cannot be told (#961)', () => {
    const unread = (command: string) => readCommands(command).map(({ gh: _gh, ...c }) => c)
    expect(unread('gh pr view 12').flatMap(c => actsOf(c, ON_BRANCH))).toEqual([{ kind: 'merge', what: 'run a gh command whose flags cannot be read', repo: null }])
    // A helper reading naming a repository that cannot be read is a merge into one that cannot be told.
    expect(acts('bash ~/.claude/hooks/lib/merge-when-ready.sh 12 -R')).toEqual([{ kind: 'merge', what: 'merge a PR with merge-when-ready.sh', repo: null }])
  })
  // #1251: the merge helper is found by mod-kit's reading alone, so the judge reads that reading,
  // never the command's words. A command with no helper reading runs no helper the judge can see: the
  // #961 decision for the helper is kept where the reading is asked, a reading mod-kit cannot give
  // refusing the call (register.test.tsx, "a merge helper reading mod-kit cannot give").
  test('the merge helper is a merge wherever mod-kit finds it, never by the mod matching its name itself (#1251)', () => {
    const [run] = readCommands('bash ./run-it.sh 12 --repo o/r')
    const found = { ...(run as Cmd), mergeHelper: mergeHelperArgs({ words: ['merge-when-ready.sh', '12', '--repo', 'o/r'] }) as ModKitGh }
    expect(actsOf(found, ON_BRANCH)).toEqual([{ kind: 'merge', what: 'merge a PR with merge-when-ready.sh', repo: 'o/r' }])
    const { mergeHelper: _m, ...unfound } = readCommands('bash ~/.claude/hooks/lib/merge-when-ready.sh 12 --repo o/r')[0] as Cmd
    expect(actsOf(unfound, ON_BRANCH)).toEqual([])
  })
  // Dan, 2026-10-16: only a command that runs the helper is a merge. Reading its file is not; one
  // that may run it but cannot be read for certain is a merge into a repository that cannot be told.
  test('reading the merge helper is no merge, running it in any way is, and one that cannot be read is closed (#1251)', () => {
    const H = '~/.claude/hooks/lib/merge-when-ready.sh'
    expect([`cat ${H}`, `grep -n gh ${H}`, `less ${H}`, `cp ${H} /tmp/x`, `bash ./other.sh ${H}`].flatMap(c => kinds(c))).toEqual([])
    for (const run of [`bash ${H} 12 --repo o/r`, `rtk bash ${H} 12 --repo o/r`, `nohup bash ${H} 12 --repo o/r &`, `bash -c '${H} 12 --repo o/r'`, `source ${H} 12 --repo o/r`, `env A=1 ${H} 12 --repo o/r`]) {
      expect({ run, acts: acts(run) }).toEqual({ run, acts: [{ kind: 'merge', what: 'merge a PR with merge-when-ready.sh', repo: 'o/r' }] })
    }
    const closed = { kind: 'merge', what: 'run a command that may run merge-when-ready.sh, which cannot be read', repo: null }
    // xargs adds words from its input after those written, so even with --repo written the
    // repository it reaches cannot be told: still a merge, closed.
    for (const unsure of [`H=${H}; bash $H 12 --repo o/r`, 'bash -c "$CMD"', 'eval "$X"', `cat ${H} | bash`, `echo 12 | xargs bash ${H}`, `echo 12 | xargs bash ${H} --repo o/r`, `echo 12 | xargs ${H} --squash --repo o/r`, 'curl -s https://x.example | bash']) {
      expect({ unsure, acts: acts(unsure).filter(a => a.kind === 'merge') }).toEqual({ unsure, acts: [closed] })
    }
  })
  // #1181: the daytime merge gates read this same table (payload/hooks/test-merge-target.sh), so a
  // route one recogniser judges a merge and the other does not fails a suite (L450).
  test('every route in the table the merge gates share is judged as the table says (#1181)', () => {
    expect(API_MERGE_CASES.length).toBeGreaterThan(20)
    const wrong = API_MERGE_CASES.filter(c => kinds(c.command).includes('merge') !== c.merge).map(c => c.command)
    expect(wrong).toEqual([])
    // A row where the two differ says why, or the difference is an accident nobody chose.
    expect(API_MERGE_CASES.filter(c => c.gates !== undefined && !c.why).map(c => c.command)).toEqual([])
  })
  // #1186: and the repository each merge is about, where the table names one: every merge act the
  // mod reads from the row is about that repository, or about one that cannot be told (null).
  test('every merge in the shared table that names a repository is about that repository (#1186)', () => {
    const withRepo = API_MERGE_CASES.filter(c => c.repo !== undefined)
    expect(withRepo.length).toBeGreaterThan(10)
    const wrong = withRepo
      .map(c => ({ command: c.command, repos: acts(c.command).filter(a => a.kind === 'merge').map(a => a.repo) }))
      .filter((r, i) => r.repos.length === 0 || r.repos.some(x => x !== withRepo[i]?.repo))
    expect(wrong).toEqual([])
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

  // #980: mod-kit's branch reader gives no default branch for a checkout whose branch it cannot
  // read (a detached head among them), so any branch named could be the default: judged the strict
  // way, never as main or master alone, which would let a push to a develop default through.
  test('a checkout whose default branch could not be read: every branch a push names could be the default', () => {
    const unread: Where = { defaultBranch: { unreadable: 'a detached head names no branch' }, currentBranch: null, scripts: null }
    expect(acts('git push origin HEAD:feature-1', unread)).toEqual([{ kind: 'push-default', what: 'push feature-1 from a checkout whose default branch could not be read (a detached head names no branch)' }])
    expect(acts('git push origin develop', unread).map(a => a.what)).toEqual(['push develop from a checkout whose default branch could not be read (a detached head names no branch)'])
    // main is a default on any reading, and said as one.
    expect(acts('git push origin main', unread).map(a => a.what)).toEqual(['push main straight to GitHub'])
    expect(acts('git push', unread).map(a => a.what)).toEqual(['push from a branch that could not be read'])
    expect(acts('git push', { ...unread, currentBranch: 'fix-843' }).map(a => a.what)).toEqual(['push fix-843 from a checkout whose default branch could not be read (a detached head names no branch)'])
    expect(kinds('gh api -X PATCH repos/o/r/git/refs/heads/develop -f sha=abc', unread)).toEqual(['push-default'])
    // Read, a default other than main or master is the only one.
    expect(kinds('git push origin feature-1', { ...unread, defaultBranch: 'develop' })).toEqual([])
    expect(kinds('gh api -X PATCH repos/o/r/git/refs/heads/feature-1 -f sha=abc', { ...unread, defaultBranch: 'develop' })).toEqual([])
  })
})

// #1106: claude-sync pull is claude-config's deploy step, the install that makes a merge live. It
// is judged as a deploy of the repository the sync clone it runs from is, by this phase's own rule
// (policyOf, refusalOf), never a second copy of it (L263); phase 3 refuses every other claude-sync
// write, and a pull from anywhere but the live sync clone.
describe('claude-sync pull, the config repository deploy step (#1106)', () => {
  const HOME = '/Users/x'
  const CLONE = '/Users/x/claude-config-sync'
  const CONFIG = 'danwright32/claude-config'
  const place: Place = { ...ON_BRANCH, own: CONFIG }
  const judge = (night: unknown, command: string, cwd = '/Users/x/repo') => {
    const commands = cmds(command)
    return judgeNight(night, commands, dirsOf(commands, cwd, HOME).map(d => (d === CLONE ? place : d === null ? null : { ...ON_BRANCH, own: 'o/r' })))
  }
  const lists = (j: object) => nightRepos(readRepoLists(JSON.stringify({ v: 1, mergeOnly: [], mayDeploy: [], ...j })), [])
  test('a pull is a deploy, by any path to the script, and only a pull among the reads', () => {
    for (const c of ['~/claude-config-sync/claude-sync pull', 'bash ~/claude-config-sync/claude-sync pull', '/Users/x/claude-config-sync/claude-sync pull 2>&1 | tail -5', 'claude-sync pull', 'bash -x ~/claude-config-sync/claude-sync pull', 'sh -o errexit ~/claude-config-sync/claude-sync pull'])
      expect({ c, k: kinds(c) }).toEqual({ c, k: ['deploy'] })
    for (const c of ['~/claude-config-sync/claude-sync status', '~/claude-config-sync/claude-sync lesson L174', 'git pull'])
      expect({ c, k: kinds(c) }).toEqual({ c, k: [] })
  })
  test('the folder a claude-sync command reaches is the clone its script lives in, never the session folder; a bare name is one that cannot be told', () => {
    expect(dirsOf(cmds('~/claude-config-sync/claude-sync pull'), '/Users/x/repo', HOME)).toEqual([CLONE])
    expect(dirsOf(cmds('cd ~/claude-config-sync && ./claude-sync pull'), '/Users/x/repo', HOME)).toEqual([CLONE, CLONE])
    expect(dirsOf(cmds('bash /Users/x/Apps/claude-config/claude-sync pull'), '/Users/x/repo', HOME)).toEqual(['/Users/x/Apps/claude-config'])
    expect(dirsOf(cmds('claude-sync pull'), '/Users/x/repo', HOME)).toEqual([null])
    // A shell's own options before the script, a value taking one included, are read past.
    expect(dirsOf(cmds('bash -e -o pipefail ~/claude-config-sync/claude-sync pull'), '/Users/x/repo', HOME)).toEqual([CLONE])
    expect(dirsOf(cmds('bash --rcfile /tmp/rc ~/claude-config-sync/claude-sync pull'), '/Users/x/repo', HOME)).toEqual([CLONE])
    expect(dirsOf(cmds('bash ./other.sh ~/claude-config-sync/claude-sync pull'), '/Users/x/repo', HOME)).toEqual([null])
  })
  test('allowed exactly when the night says the config repository may deploy, from any session folder', () => {
    const night = lists({ mayDeploy: [CONFIG] })
    expect(judge(night, '~/claude-config-sync/claude-sync pull')).toBeUndefined()
    expect(judge(night, 'bash ~/claude-config-sync/claude-sync pull', '/Users/x/elsewhere')).toBeUndefined()
  })
  test('refused when the config repository is merge only, on neither list, closed, or under an owner that waits, and when the record carries no lists', () => {
    const why = (night: unknown, command = '~/claude-config-sync/claude-sync pull') => judge(night, command)?.why
    expect(why(lists({ mergeOnly: [{ repo: CONFIG, mergeDeploys: false }] }))).toBe(`${CONFIG} may merge overnight but never deploy`)
    expect(why(lists({ mergeOnly: [{ repo: CONFIG, mergeDeploys: true }] }))).toBe(`${CONFIG} may merge overnight but never deploy`)
    // Another repository allowed to deploy is not the config repository.
    expect(why(lists({ mayDeploy: ['o/r'] }))).toBe(`${CONFIG} is on neither list in mods/sleep-repos.local.json, so tonight it neither merges nor deploys`)
    expect(why(nightRepos(readRepoLists(JSON.stringify({ v: 1, mergeOnly: [], mayDeploy: [CONFIG] })), [{ repo: CONFIG, why: 'GitHub does not know it' }]))).toBe('GitHub does not know it, so tonight it neither merges nor deploys')
    expect(why(lists({ mayDeploy: [CONFIG], waitOwners: ['danwright32'] }))).toMatch(/^every repository owned by danwright32 waits overnight/)
    expect(why(undefined)).toBe('the sleep record carries no merge and deploy lists, so tonight it neither merges nor deploys')
    // A clone whose repository cannot be told (a bare name, found on PATH) is closed, whatever the lists.
    expect(why(lists({ mayDeploy: [CONFIG] }), 'claude-sync pull')).toBe('which repository this reaches could not be told, so tonight it neither merges nor deploys')
  })
})
