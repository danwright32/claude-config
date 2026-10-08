import { describe, expect, test } from 'claude-code/testing'
import { ghRepo, githubRepo, linkRepo, repoName } from '../hooks/repo.ts'
import { GH_REPO_FIXTURES, LINK_FIXTURES } from './gh-fixtures.ts'
import { REPO_FIXTURES } from './repo-fixtures.ts'

// The one reading of a session's repository (#951), on the table every mod's reading is pinned on.
// The two questions are asked of every row, so a case one copy never saw is seen by both.
describe('the GitHub repository a remote names', () => {
  test('every shared case', () => {
    expect(REPO_FIXTURES.map(f => ({ why: f.why, github: githubRepo(f.remote) }))).toEqual(REPO_FIXTURES.map(f => ({ why: f.why, github: f.github })))
  })
  test('no remote at all is none', () => {
    expect(githubRepo(null)).toBeNull()
    expect(githubRepo(undefined)).toBeNull()
    expect(githubRepo('   ')).toBeNull()
  })
  // The copies this replaced read any address holding github.com followed by : or /, so a host
  // named for it read as GitHub; and one read a local .git folder's path as owner/name.
  test('a look alike host, or a local path shaped like owner/name, is never GitHub', () => {
    expect(githubRepo('https://notgithub.com/o/r')).toBeNull()
    expect(githubRepo('https://github.com.example.org/o/r')).toBeNull()
    expect(githubRepo('/srv/repo/.git')).toBeNull()
    expect(githubRepo('./github.com:o/r')).toBeNull()
  })
  test('a name GitHub could not have is none', () => {
    expect(githubRepo('git@github.com:o/r r.git')).toBeNull()
    expect(githubRepo('https://github.com/o')).toBeNull()
  })
})

describe('what a repository is called', () => {
  test('every shared case', () => {
    expect(REPO_FIXTURES.map(f => ({ why: f.why, name: repoName(f) }))).toEqual(REPO_FIXTURES.map(f => ({ why: f.why, name: f.name })))
  })
  test('no origin and no folder name is none', () => {
    expect(repoName({ root: '/', remote: null })).toBeNull()
    expect(repoName({ remote: null })).toBeNull()
    expect(repoName({ root: '', remote: '' })).toBeNull()
  })
  test('an origin naming nothing falls back to the folder', () => {
    expect(repoName({ root: '/Users/x/Apps/NurseDex', remote: 'https://github.com/' })).toBe('NurseDex')
  })
})

// #961: the two readings of a repository that is not a git remote, on the table every mod's
// reading is pinned on (tests/gh-fixtures.ts).
describe('the repository gh reads a spelling as', () => {
  test('every shared case', () => {
    expect(GH_REPO_FIXTURES.map(f => ({ why: f.why, repo: ghRepo(f.spelling) }))).toEqual(GH_REPO_FIXTURES.map(f => ({ why: f.why, repo: f.repo })))
  })
  test('no spelling at all is none', () => {
    expect(ghRepo(null)).toBeNull()
    expect(ghRepo(undefined)).toBeNull()
  })
  // owner/name alone is a repository to gh and a local path to git: the two questions differ (L342).
  test('owner/name alone is a repository to gh, never a remote to git', () => {
    expect(ghRepo('o/r')).toBe('o/r')
    expect(githubRepo('o/r')).toBeNull()
  })
})

describe('the repository a github.com link names', () => {
  test('every shared case', () => {
    expect(LINK_FIXTURES.map(f => ({ why: f.why, repo: linkRepo(f.link) }))).toEqual(LINK_FIXTURES.map(f => ({ why: f.why, repo: f.repo })))
  })
  test('no link at all is none', () => {
    expect(linkRepo(null)).toBeNull()
    expect(linkRepo(undefined)).toBeNull()
  })
})
