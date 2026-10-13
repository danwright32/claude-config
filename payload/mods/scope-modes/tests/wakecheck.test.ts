import { describe, expect, test } from 'claude-code/testing'
import type { GithubOf } from '../hooks/overnight.ts'
import { wakeCheck, type Ran } from '../hooks/wakecheck.ts'
import { githubRepo } from './mod-kit/hooks/repo.ts'

// mod-kit's reader of a remote, as $.modkit.repo answers it: its byte for byte copy (#951).
const github: GithubOf = async remote => githubRepo(remote)

// Sleep mode phase 3 (#834): the wake check reads what really happened since sleep began, because a
// text match always has a way around it. Each read is answered here by a stand in for gh, git and
// stat, keyed on the command line, so each case says what GitHub and the disk hold.
const SINCE = Date.UTC(2026, 9, 8, 3, 0) // 11:00 PM ET on Oct 7
const AFTER = '2026-10-08T05:00:00Z'
const BEFORE = '2026-10-08T01:00:00Z'
const HOME = '/Users/x'
const ok = (stdout: string): Ran => ({ exitCode: 0, stdout, stderr: '' })
const fail = (stderr: string): Ran => ({ exitCode: 1, stdout: '', stderr })

type World = Record<string, Ran>
const QUIET: World = {
  'gh api user --jq .login': ok('dan\n'),
  'gh api users/dan/events?per_page=100&page=1': ok(JSON.stringify([{ type: 'PushEvent', created_at: AFTER, repo: { name: 'o/r' } }])),
  [`gh search issues --author @me --created >=2026-10-08T03:00:00Z --json repository,number,title,url --limit 100`]: ok('[]'),
  'git -C /Users/x/claude-config-sync remote -v': ok('origin\tgit@github.com:o/claude-config.git (fetch)\n'),
  'gh api repos/o/claude-config/commits?path=payload/LESSONS.md&since=2026-10-08T03:00:00Z': ok('[]'),
  'stat -f %m /Users/x/.claude/LESSONS.md': ok('1700000000\n'),
  'gh api repos/o/r/milestones?state=all&per_page=100': ok('[]'),
  'gh api repos/o/claude-config/milestones?state=all&per_page=100': ok('[]'),
  'gh run list -R o/r --json workflowName,event,createdAt,url --limit 100': ok('[]'),
  'gh run list -R o/claude-config --json workflowName,event,createdAt,url --limit 100': ok('[]'),
}
const check = async (over: World = {}, read: GithubOf = github) => {
  const world = { ...QUIET, ...over }
  const asked: string[] = []
  const r = await wakeCheck(async argv => {
    const key = argv.join(' ')
    asked.push(key)
    return world[key] ?? fail(`unexpected: ${key}`)
  }, { since: SINCE, home: HOME, github: read, now: () => SINCE })
  return { ...r, asked }
}

describe('the wake check', () => {
  // The config repository is read from the live sync clone's remotes by mod-kit's reader (#951): a
  // reader that fails is said as not checked, never as a clone with no GitHub remote.
  test('a remote reader that fails leaves LESSONS.md on GitHub unchecked, and says why', async () => {
    const r = await check({}, async () => { throw new Error('mod-kit is not loaded') })
    expect(r.unmeasured).toEqual(['LESSONS.md on GitHub was not checked: the config repository could not be read from ~/claude-config-sync (its remotes could not be read: mod-kit is not loaded)'])
    expect(r.asked).not.toContain('gh api repos/o/claude-config/commits?path=payload/LESSONS.md&since=2026-10-08T03:00:00Z')
  })
  test('a quiet night finds nothing and says every read was made', async () => {
    const r = await check()
    expect(r.hits).toEqual([])
    expect(r.unmeasured).toEqual([])
    // Every repository with an event overnight, and the config repository, is read.
    expect(r.asked).toContain('gh api repos/o/r/milestones?state=all&per_page=100')
    expect(r.asked).toContain('gh run list -R o/claude-config --json workflowName,event,createdAt,url --limit 100')
  })
  test('issues created, milestones touched, LESSONS.md changed and deploy runs are each found', async () => {
    const r = await check({
      'gh api users/dan/events?per_page=100&page=1': ok(JSON.stringify([
        { type: 'IssuesEvent', created_at: AFTER, repo: { name: 'o/r' }, payload: { action: 'opened', issue: { number: 9, title: 'Found overnight' } } },
        { type: 'IssuesEvent', created_at: BEFORE, repo: { name: 'o/old' }, payload: { action: 'opened', issue: { number: 1, title: 'Before sleep' } } },
      ])),
      [`gh search issues --author @me --created >=2026-10-08T03:00:00Z --json repository,number,title,url --limit 100`]: ok(JSON.stringify([
        { repository: { nameWithOwner: 'o/r' }, number: 9, title: 'Found overnight', url: 'https://github.com/o/r/issues/9' },
        { repository: { nameWithOwner: 'o/s' }, number: 3, title: 'Also overnight', url: 'https://github.com/o/s/issues/3' },
      ])),
      'gh api repos/o/r/milestones?state=all&per_page=100': ok(JSON.stringify([{ title: 'New one', updated_at: AFTER }, { title: 'Old one', updated_at: BEFORE }])),
      'gh api repos/o/s/milestones?state=all&per_page=100': ok('[]'),
      'gh run list -R o/s --json workflowName,event,createdAt,url --limit 100': ok('[]'),
      'gh api repos/o/claude-config/commits?path=payload/LESSONS.md&since=2026-10-08T03:00:00Z': ok(JSON.stringify([{ sha: 'abcdef1234', commit: { message: 'Add L999\n\nbody' } }])),
      'stat -f %m /Users/x/.claude/LESSONS.md': ok(`${Math.floor(SINCE / 1000) + 60}\n`),
      'gh run list -R o/r --json workflowName,event,createdAt,url --limit 100': ok(JSON.stringify([
        { workflowName: 'Deploy', event: 'push', createdAt: AFTER, url: 'https://github.com/o/r/actions/runs/1' },
        { workflowName: 'CI', event: 'push', createdAt: AFTER, url: 'https://github.com/o/r/actions/runs/2' },
        { workflowName: 'Nightly', event: 'workflow_dispatch', createdAt: AFTER, url: 'https://github.com/o/r/actions/runs/3' },
        { workflowName: 'Deploy', event: 'push', createdAt: BEFORE, url: 'https://github.com/o/r/actions/runs/0' },
      ])),
    })
    expect(r.unmeasured).toEqual([])
    expect(r.hits).toEqual([
      'Issue created overnight: o/r#9 "Found overnight"',
      'Issue created overnight: o/s#3 "Also overnight"',
      'Milestone touched overnight: o/r "New one"',
      'LESSONS.md changed overnight on GitHub: abcdef1 "Add L999"',
      'The installed LESSONS.md changed overnight, at 11:01 PM ET on Wed Oct 7',
      'Deploy run overnight: o/r Deploy (https://github.com/o/r/actions/runs/1)',
      'Deploy run overnight: o/r Nightly (https://github.com/o/r/actions/runs/3)',
    ])
  })
  test('a read that fails is said as not checked, never as nothing found (L460)', async () => {
    const r = await check({
      [`gh search issues --author @me --created >=2026-10-08T03:00:00Z --json repository,number,title,url --limit 100`]: fail('HTTP 403: rate limited'),
      'gh run list -R o/r --json workflowName,event,createdAt,url --limit 100': ok('<html>'),
    })
    expect(r.hits).toEqual([])
    expect(r.unmeasured).toEqual([
      'issues created overnight were not checked (gh search issues: HTTP 403: rate limited)',
      'deploy runs in o/r were not checked (gh run list: the answer was not JSON)',
    ])
  })
  test('a time GitHub did not give, or gave unreadable, is unknown: said, never compared away nor called overnight (L50)', async () => {
    const r = await check({
      'gh api repos/o/r/milestones?state=all&per_page=100': ok(JSON.stringify([{ title: 'No date' }, { title: 'Garbled', updated_at: 'garbled' }])),
      'gh run list -R o/r --json workflowName,event,createdAt,url --limit 100': ok(JSON.stringify([{ workflowName: 'Deploy', event: 'push', url: 'u' }])),
    })
    expect(r.hits).toEqual([])
    expect(r.unmeasured).toEqual([
      'when milestone "No date" in o/r was last touched is unknown (GitHub gave no time)',
      'when milestone "Garbled" in o/r was last touched is unknown (GitHub gave no time)',
      'when the Deploy run in o/r ran is unknown (GitHub gave no time)',
    ])
  })
  test('a full page of milestones or runs says the rest were not read, runs by the window left (L24, #1160)', async () => {
    const ms = Array.from({ length: 100 }, (_, n) => ({ title: `m${n}`, updated_at: BEFORE }))
    const runs = Array.from({ length: 100 }, () => ({ workflowName: 'CI', event: 'push', createdAt: AFTER, url: 'u' }))
    const r = await check({
      'gh api repos/o/r/milestones?state=all&per_page=100': ok(JSON.stringify(ms)),
      'gh run list -R o/r --json workflowName,event,createdAt,url --limit 100': ok(JSON.stringify(runs)),
    })
    expect(r.unmeasured).toEqual(['o/r holds 100 or more milestones, so only the first 100 were read', 'the runs in o/r from 11:00 PM ET on Wed Oct 7 to 1:00 AM ET on Thu Oct 8 were not read for deploys (only the newest 100 were asked for)'])
  })
  test('every repository the notes of the night name is read too, private ones included, whatever the events show', async () => {
    const world: World = { ...QUIET, 'gh api repos/o/private/milestones?state=all&per_page=100': ok(JSON.stringify([{ title: 'Secret', updated_at: AFTER }])), 'gh run list -R o/private --json workflowName,event,createdAt,url --limit 100': ok('[]') }
    const r = await wakeCheck(async argv => world[argv.join(' ')] ?? fail(`unexpected: ${argv.join(' ')}`), { since: SINCE, home: HOME, github, repos: ['O/Private'], now: () => SINCE })
    expect(r.hits).toEqual(['Milestone touched overnight: o/private "Secret"'])
    expect(r.unmeasured).toEqual([])
  })
  test('the check keeps to its overall deadline, and says what it left unread (L110)', async () => {
    let t = 0
    const asked: string[] = []
    const r = await wakeCheck(
      async argv => {
        asked.push(argv.join(' '))
        t += 25_000 // each read takes 25 s
        return QUIET[argv.join(' ')] ?? fail('unexpected')
      },
      { since: SINCE, home: HOME, github, now: () => t, budgetMs: 60_000 },
    )
    // Three GitHub reads use the 60 s; the local reads still run, and nothing after them on GitHub.
    expect(asked.filter(a => a.startsWith('gh '))).toEqual(['gh api user --jq .login', 'gh api users/dan/events?per_page=100&page=1', 'gh search issues --author @me --created >=2026-10-08T03:00:00Z --json repository,number,title,url --limit 100'])
    expect(asked.filter(a => !a.startsWith('gh '))).toEqual(['git -C /Users/x/claude-config-sync remote -v', 'stat -f %m /Users/x/.claude/LESSONS.md'])
    expect(r.unmeasured).toEqual(['the overnight check stopped at its 60 s limit, so the rest of GitHub was not read'])
  })
  test('each GitHub read is given only the time left, and the whole check 30 s by default (#834 review of 98a40f1)', async () => {
    let t = 0
    const given: (number | undefined)[] = []
    const r = await wakeCheck(
      async (argv, timeoutMs) => {
        if (argv[0] === 'gh') given.push(timeoutMs)
        t += 12_000 // each read takes 12 s
        return QUIET[argv.join(' ')] ?? fail('unexpected')
      },
      { since: SINCE, home: HOME, github, now: () => t },
    )
    // 30 s, 18 s and 6 s left as the three reads start; never more than 20 s for one read.
    expect(given).toEqual([20_000, 18_000, 6_000])
    expect(r.unmeasured).toEqual(['the overnight check stopped at its 30 s limit, so the rest of GitHub was not read'])
  })
  test('without the GitHub login nothing on GitHub can be read, and that is said', async () => {
    const r = await check({ 'gh api user --jq .login': fail('not logged in') })
    expect(r.unmeasured[0]).toBe('GitHub was not checked at all: the gh login could not be read (not logged in)')
  })
})

// #1160: on a busy night (20 PRs merged on 2026-10-12) the newest 100 events did not reach back to
// sleep's start, so the repositories worked earlier went unchecked. The events are read page by page
// back to the moment sleep began, as far as GitHub keeps them (a user's newest 300: page 4 answers
// HTTP 422, measured 2026-10-13), and a window that could not be read is said by its two ends.
describe('the events, page by page back to sleep (#1160)', () => {
  const page = (p: number) => `gh api users/dan/events?per_page=100&page=${p}`
  const iso = (min: number) => new Date(SINCE + min * 60_000).toISOString().replace(/\.\d{3}Z$/, 'Z')
  // n events, newest first, one a minute, the newest `newest` minutes after sleep began.
  const events = (n: number, newest: number, repo = 'o/r') =>
    Array.from({ length: n }, (_, i) => ({ type: 'PushEvent', created_at: iso(newest - i), repo: { name: repo } }))
  const quietRepo = (repo: string): World => ({
    [`gh api repos/${repo}/milestones?state=all&per_page=100`]: ok('[]'),
    [`gh run list -R ${repo} --json workflowName,event,createdAt,url --limit 100`]: ok('[]'),
  })

  test('a page that is not full is the last one asked for', async () => {
    const r = await check()
    expect(r.asked).toContain(page(1))
    expect(r.asked).not.toContain(page(2))
  })
  test('every page back to the moment sleep began is read, and the repositories on the last are checked', async () => {
    const r = await check({
      [page(1)]: ok(JSON.stringify(events(100, 400))),
      [page(2)]: ok(JSON.stringify([...events(99, 300), ...events(1, 201, 'o/deep')])),
      // The third page crosses sleep's start: ten events overnight, then the evening before.
      [page(3)]: ok(JSON.stringify([...events(10, 200, 'o/deeper'), ...events(20, -1, 'o/evening')])),
      ...quietRepo('o/deep'),
      ...quietRepo('o/deeper'),
    })
    expect(r.unmeasured).toEqual([])
    expect(r.asked).toContain(page(3))
    expect(r.asked).not.toContain(page(4))
    expect(r.asked).toContain('gh api repos/o/deep/milestones?state=all&per_page=100')
    expect(r.asked).toContain('gh api repos/o/deeper/milestones?state=all&per_page=100')
    expect(r.asked).not.toContain('gh api repos/o/evening/milestones?state=all&per_page=100')
  })
  test('a page whose events reach back past sleep is the last, however full', async () => {
    const r = await check({ [page(1)]: ok(JSON.stringify([...events(50, 400), ...events(50, -1, 'o/evening')])) })
    expect(r.unmeasured).toEqual([])
    expect(r.asked).not.toContain(page(2))
  })
  test('all 300 events GitHub keeps since sleep began says the window before the oldest was not read', async () => {
    const r = await check({
      [page(1)]: ok(JSON.stringify(events(100, 400))),
      [page(2)]: ok(JSON.stringify(events(100, 300))),
      [page(3)]: ok(JSON.stringify(events(100, 200))),
    })
    // The oldest read is 101 minutes after 11:00 PM ET.
    expect(r.unmeasured).toEqual(['the GitHub events from 11:00 PM ET on Wed Oct 7 to 12:41 AM ET on Thu Oct 8 were not read for the repositories to check (GitHub gives only the newest 300 of a user\'s events)'])
    expect(r.asked).not.toContain(page(4))
  })
  test('a page that cannot be read says the window it would have covered, by its two ends', async () => {
    const r = await check({ [page(1)]: ok(JSON.stringify(events(100, 400))), [page(2)]: fail('HTTP 502: Bad Gateway') })
    // Page 1 reached back to 301 minutes after 11:00 PM ET.
    expect(r.unmeasured).toEqual(['the GitHub events from 11:00 PM ET on Wed Oct 7 to 4:01 AM ET on Thu Oct 8 were not read for the repositories to check (page 2: HTTP 502: Bad Gateway)'])
    expect(r.asked).not.toContain(page(3))
    // What the first page named is still read.
    expect(r.asked).toContain('gh api repos/o/r/milestones?state=all&per_page=100')
  })
  test('a first page that cannot be read says every event since sleep began went unread', async () => {
    const r = await check({ [page(1)]: ok('<html>') })
    expect(r.unmeasured).toEqual(['the GitHub events since 11:00 PM ET on Wed Oct 7 were not read for the repositories to check (page 1: the answer was not JSON)'])
  })
  test('a page past the check\'s deadline, on the injected clock, says the window it left unread (#1147)', async () => {
    let t = 0
    const world: World = { ...QUIET, [page(1)]: ok(JSON.stringify(events(100, 400))), [page(2)]: ok(JSON.stringify(events(100, 300))) }
    const asked: string[] = []
    const r = await wakeCheck(
      async argv => {
        asked.push(argv.join(' '))
        t += 12_000 // each read takes 12 s: the login, then pages 1 and 2 use the 30 s
        return world[argv.join(' ')] ?? fail('unexpected')
      },
      { since: SINCE, home: HOME, github, now: () => t },
    )
    expect(asked).not.toContain(page(3))
    expect(r.unmeasured).toEqual([
      'the overnight check stopped at its 30 s limit, so the rest of GitHub was not read',
      'the GitHub events from 11:00 PM ET on Wed Oct 7 to 2:21 AM ET on Thu Oct 8 were not read for the repositories to check (page 3: the check stopped at its 30 s limit)',
    ])
  })
})
