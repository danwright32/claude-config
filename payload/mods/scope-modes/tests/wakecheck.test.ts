import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { GithubOf } from '../hooks/overnight.ts'
import { wakeCheck, workedOn, type Ran } from '../hooks/wakecheck.ts'
import { githubRepo } from './mod-kit/hooks/repo.ts'

// mod-kit's reader of a remote, as $.modkit.repo answers it: its byte for byte copy (#951).
const github: GithubOf = async remote => githubRepo(remote)

// Sleep mode phase 3 (#834): the wake check reads what really happened since sleep began, because a
// text match always has a way around it. Each read is answered here by a stand in for gh and git,
// keyed on the command line, so each case says what GitHub and the disk hold. The installed
// LESSONS.md's last change is read through $.fs.stat in the hooks, never a stat process (#2016), and
// is stood in from the same world under `mtime <path>`, in milliseconds.
const SINCE = Date.UTC(2026, 9, 8, 3, 0) // 11:00 PM ET on Oct 7
const AFTER = '2026-10-08T05:00:00Z'
const BEFORE = '2026-10-08T01:00:00Z'
const HOME = `${'/Users'}/x`
const ok = (stdout: string): Ran => ({ exitCode: 0, stdout, stderr: '' })
const fail = (stderr: string): Ran => ({ exitCode: 1, stdout: '', stderr })

type World = Record<string, Ran>
const QUIET: World = {
  'gh api user --jq .login': ok('dan\n'),
  'gh api users/dan/events?per_page=100&page=1': ok(JSON.stringify([{ type: 'PushEvent', created_at: AFTER, repo: { name: 'o/r' } }])),
  [`gh search issues --author @me --created >=2026-10-08T03:00:00Z --json repository,number,title,url --limit 100`]: ok('[]'),
  [`git -C ${'/Users'}/x/claude-config-sync remote -v`]: ok('origin\tgit@github.com:o/claude-config.git (fetch)\n'),
  'gh api repos/o/claude-config/commits?path=payload/LESSONS.md&since=2026-10-08T03:00:00Z': ok('[]'),
  [`mtime ${'/Users'}/x/.claude/LESSONS.md`]: ok('1700000000000'),
  'gh api repos/o/r/milestones?state=all&per_page=100': ok('[]'),
  'gh api repos/o/claude-config/milestones?state=all&per_page=100': ok('[]'),
  'gh run list -R o/r --json workflowName,event,createdAt,url --limit 100': ok('[]'),
  'gh run list -R o/claude-config --json workflowName,event,createdAt,url --limit 100': ok('[]'),
}
// What $.fs.stat says of a path, from the world: its last change, or a rejection with the reason, as
// the engine rejects (measured 2026-11-01: "<mod>: $.fs.stat(<path>) failed: ENOENT").
const mtimeFrom = (world: World, asked?: string[]) => async (path: string) => {
  const key = `mtime ${path}`
  asked?.push(key)
  const r = world[key] ?? fail(`unexpected: ${key}`)
  if (r.exitCode !== 0) throw new Error(r.stderr)
  return Number(r.stdout)
}
const check = async (over: World = {}, read: GithubOf = github, worked?: string[]) => {
  const world = { ...QUIET, ...over }
  const asked: string[] = []
  const r = await wakeCheck(async argv => {
    const key = argv.join(' ')
    asked.push(key)
    return world[key] ?? fail(`unexpected: ${key}`)
  }, { since: SINCE, home: HOME, github: read, now: () => SINCE, mtimeOf: mtimeFrom(world, asked), worked })
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
      'gh api repos/o/r/milestones?state=all&per_page=100': ok(JSON.stringify([{ number: 4, title: 'New one', updated_at: AFTER }, { number: 3, title: 'Old one', updated_at: BEFORE }])),
      'gh api repos/o/r/issues/events?per_page=100&page=1': ok('[]'),
      'gh api repos/o/s/milestones?state=all&per_page=100': ok('[]'),
      'gh run list -R o/s --json workflowName,event,createdAt,url --limit 100': ok('[]'),
      'gh api repos/o/claude-config/commits?path=payload/LESSONS.md&since=2026-10-08T03:00:00Z': ok(JSON.stringify([{ sha: 'abcdef1234', commit: { message: 'Add L999\n\nbody' } }])),
      [`mtime ${'/Users'}/x/.claude/LESSONS.md`]: ok(String(SINCE + 60_000)),
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
      'Milestone touched overnight: o/r "New one", by changes nothing the night recorded accounts for: the milestone itself, at 1:00 AM ET on Thu Oct 8 (no issue event in it explains that)',
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
  // #2016: the installed LESSONS.md is read through $.fs.stat, never BSD's stat -f, which on Linux
  // describes the file system instead and printed no time there.
  test('the installed LESSONS.md is read without running stat at all', async () => {
    const r = await check()
    expect(r.asked).toContain(`mtime ${'/Users'}/x/.claude/LESSONS.md`)
    expect(r.asked.filter(a => a.startsWith('stat '))).toEqual([])
  })
  test('an installed LESSONS.md that cannot be read is said as not checked, with the reason', async () => {
    const r = await check({ [`mtime ${'/Users'}/x/.claude/LESSONS.md`]: fail(`scope-modes: $.fs.stat(${'/Users'}/x/.claude/LESSONS.md) failed: ENOENT`) })
    expect(r.hits).toEqual([])
    // Said in words, never the engine's "scope-modes: $.fs.stat(...) failed: ENOENT" (#2150).
    expect(r.unmeasured).toEqual([`the installed LESSONS.md was not checked (its last change could not be read: the file could not be looked up: there is no such file or folder (${'/Users'}/x/.claude/LESSONS.md))`])
  })
  test('an installed LESSONS.md whose last change reads as no time is said as not checked, never as before sleep (L50)', async () => {
    const r = await check({ [`mtime ${'/Users'}/x/.claude/LESSONS.md`]: ok('0') })
    expect(r.unmeasured).toEqual(['the installed LESSONS.md was not checked (its last change could not be read: no time was given)'])
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
    const world: World = {
      ...QUIET,
      'gh api repos/o/private/milestones?state=all&per_page=100': ok(JSON.stringify([{ number: 1, title: 'Secret', updated_at: AFTER }])),
      'gh api repos/o/private/issues/events?per_page=100&page=1': ok('[]'),
      'gh run list -R o/private --json workflowName,event,createdAt,url --limit 100': ok('[]'),
    }
    const r = await wakeCheck(async argv => world[argv.join(' ')] ?? fail(`unexpected: ${argv.join(' ')}`), { since: SINCE, home: HOME, github, repos: ['O/Private'], now: () => SINCE, mtimeOf: mtimeFrom(world) })
    expect(r.hits).toEqual(['Milestone touched overnight: o/private "Secret", by changes nothing the night recorded accounts for: the milestone itself, at 1:00 AM ET on Thu Oct 8 (no issue event in it explains that)'])
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
      { since: SINCE, home: HOME, github, now: () => t, budgetMs: 60_000, mtimeOf: mtimeFrom(QUIET, asked) },
    )
    // Three GitHub reads use the 60 s; the local reads still run, and nothing after them on GitHub.
    expect(asked.filter(a => a.startsWith('gh '))).toEqual(['gh api user --jq .login', 'gh api users/dan/events?per_page=100&page=1', 'gh search issues --author @me --created >=2026-10-08T03:00:00Z --json repository,number,title,url --limit 100'])
    expect(asked.filter(a => !a.startsWith('gh '))).toEqual([`git -C ${'/Users'}/x/claude-config-sync remote -v`, `mtime ${'/Users'}/x/.claude/LESSONS.md`])
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
      { since: SINCE, home: HOME, github, now: () => t, mtimeOf: mtimeFrom(QUIET) },
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
      { since: SINCE, home: HOME, github, now: () => t, mtimeOf: mtimeFrom(world) },
    )
    expect(asked).not.toContain(page(3))
    expect(r.unmeasured).toEqual([
      'the overnight check stopped at its 30 s limit, so the rest of GitHub was not read',
      'the GitHub events from 11:00 PM ET on Wed Oct 7 to 2:21 AM ET on Thu Oct 8 were not read for the repositories to check (page 3: the check stopped at its 30 s limit)',
    ])
  })
})

// #2393: GitHub's updated_at says only that a milestone changed, so the night's own merges closing
// its issues, and the issues it filed into it, were put to Dan every morning as something to look
// at (2026-11-07, the Ungrouped milestone: "Nothing needed"). The milestone's issue events for the
// night are read, and only a change nothing the night recorded accounts for is reported, by name.
describe('a milestone the night\'s own work explains is left out (#2393)', () => {
  const MS = 'gh api repos/o/r/milestones?state=all&per_page=100'
  const EVENTS = (p: number) => `gh api repos/o/r/issues/events?per_page=100&page=${p}`
  const CLOSERS = 'gh issue list -R o/r --state closed --search closed:>=2026-10-08T03:00:00Z --json number,closedByPullRequestsReferences --limit 100'
  const SEARCH = 'gh search issues --author @me --created >=2026-10-08T03:00:00Z --json repository,number,title,url --limit 100'
  const at = (hhmmss: string) => `2026-10-08T${hhmmss}Z`
  const ungrouped = { number: 2, title: 'Ungrouped' }
  const closed = (n: number, when: string, actor: string, milestone: { number: number; title: string } | null = ungrouped) =>
    ({ event: 'closed', created_at: when, actor: { login: actor }, issue: { number: n, milestone } })
  const lead = 'Milestone touched overnight: o/r'
  const nothing = 'by changes nothing the night recorded accounts for'
  const unchecked = 'whether milestone "Ungrouped" in o/r was changed only by the night\'s own work was not checked'

  test('a milestone touched only by the night\'s merges and filings is not reported', async () => {
    const r = await check({
      [MS]: ok(JSON.stringify([{ ...ungrouped, updated_at: at('05:00:01') }])),
      [EVENTS(1)]: ok(JSON.stringify([
        // A label moves no milestone, so it is never counted either way.
        { event: 'labeled', created_at: at('05:00:02'), actor: { login: 'eve' }, issue: { number: 9, milestone: ungrouped } },
        // Closed by a merge a session noted as done for this issue.
        closed(7, at('05:00:00'), 'dan'),
        // Filed into it overnight: already its own line, as an issue created overnight.
        { event: 'milestoned', created_at: at('04:30:00'), actor: { login: 'dan' }, milestone: { title: 'Ungrouped' }, issue: { number: 9, milestone: ungrouped } },
        // Closed by pull request #20, which a session noted, though no note names #8 itself.
        closed(8, at('04:00:00'), 'dan'),
        // Before sleep began: not the night's to explain.
        closed(1, BEFORE, 'eve'),
      ])),
      [CLOSERS]: ok(JSON.stringify([
        { number: 8, closedByPullRequestsReferences: [{ number: 20, repository: { name: 'r', owner: { login: 'o' } } }] },
        { number: 7, closedByPullRequestsReferences: [] },
      ])),
      [SEARCH]: ok(JSON.stringify([{ repository: { nameWithOwner: 'o/r' }, number: 9, title: 'Filed overnight', url: 'u' }])),
    }, github, ['o/r#7', 'o/r#20'])
    expect(r.unmeasured).toEqual([])
    expect(r.hits).toEqual(['Issue created overnight: o/r#9 "Filed overnight"'])
  })

  test('a change no session made is reported, naming what changed', async () => {
    const later = { number: 6, title: 'Later' }
    const r = await check({
      [MS]: ok(JSON.stringify([
        { ...ungrouped, updated_at: at('05:00:01') },
        // Changed with no issue event at all: the milestone itself was edited.
        { number: 5, title: 'Plans', updated_at: AFTER },
        // Changed ten minutes after the last issue event, which the night's work explains.
        { ...later, updated_at: at('05:10:00') },
      ])),
      [EVENTS(1)]: ok(JSON.stringify([
        closed(11, at('05:00:00'), 'eve'),
        { event: 'demilestoned', created_at: at('04:50:00'), actor: { login: 'eve' }, milestone: { title: 'Ungrouped' }, issue: { number: 12, milestone: null } },
        closed(7, at('04:00:00'), 'dan', later),
        closed(1, BEFORE, 'eve'),
      ])),
      // #11 was closed by a pull request no session noted.
      [CLOSERS]: ok(JSON.stringify([{ number: 11, closedByPullRequestsReferences: [{ number: 30, repository: null }] }])),
    }, github, ['o/r#7'])
    expect(r.unmeasured).toEqual([])
    expect(r.hits).toEqual([
      `${lead} "Ungrouped", ${nothing}: #12 removed from it by eve; #11 closed by eve`,
      `${lead} "Plans", ${nothing}: the milestone itself, at 1:00 AM ET on Thu Oct 8 (no issue event in it explains that)`,
      `${lead} "Later", ${nothing}: the milestone itself, at 1:10 AM ET on Thu Oct 8 (no issue event in it explains that)`,
    ])
  })

  test('issue events that cannot be read are said as unmeasured, never as explained', async () => {
    const r = await check({
      [MS]: ok(JSON.stringify([{ ...ungrouped, updated_at: at('05:00:01') }])),
      [EVENTS(1)]: fail('HTTP 500: boom'),
    }, github, ['o/r#7'])
    expect(r.hits).toEqual([])
    expect(r.unmeasured).toEqual([`${unchecked} (its issue events could not be read: page 1: HTTP 500: boom)`])
  })

  test('closers that cannot be read, an event GitHub gave no time, or events not read back to sleep, are each unmeasured', async () => {
    const closersFail = await check({
      [MS]: ok(JSON.stringify([{ ...ungrouped, updated_at: at('05:00:01') }])),
      [EVENTS(1)]: ok(JSON.stringify([closed(11, at('05:00:00'), 'eve'), closed(1, BEFORE, 'eve')])),
      [CLOSERS]: fail('HTTP 502: Bad Gateway'),
    })
    expect(closersFail.hits).toEqual([])
    expect(closersFail.unmeasured).toEqual([`${unchecked} (the pull requests that closed its issues could not be read: HTTP 502: Bad Gateway)`])

    const noTime = await check({
      [MS]: ok(JSON.stringify([{ ...ungrouped, updated_at: at('05:00:01') }])),
      [EVENTS(1)]: ok(JSON.stringify([closed(7, at('05:00:00'), 'dan'), { event: 'reopened', actor: { login: 'eve' }, issue: { number: 13, milestone: ungrouped } }, closed(1, BEFORE, 'eve')])),
    }, github, ['o/r#7'])
    expect(noTime.hits).toEqual([])
    expect(noTime.unmeasured).toEqual([`${unchecked} (GitHub gave no time for #13 reopened)`])

    // Three full pages, all overnight and all explained, still leave the start of the night unread.
    const full = (from: number) => Array.from({ length: 100 }, (_, i) => closed(7, new Date(SINCE + (from - i) * 60_000).toISOString(), 'dan'))
    const partial = await check({
      [MS]: ok(JSON.stringify([{ ...ungrouped, updated_at: new Date(SINCE + 400 * 60_000).toISOString() }])),
      [EVENTS(1)]: ok(JSON.stringify(full(400))),
      [EVENTS(2)]: ok(JSON.stringify(full(300))),
      [EVENTS(3)]: ok(JSON.stringify(full(200))),
    }, github, ['o/r#7'])
    expect(partial.hits).toEqual([])
    expect(partial.unmeasured).toEqual([`${unchecked} (its issue events from 11:00 PM ET on Wed Oct 7 to 12:41 AM ET on Thu Oct 8 were not read: GitHub was asked for only the newest 300)`])
    expect(partial.asked).not.toContain(EVENTS(4))
  })

  // Lessons review of de0f3ed: a named change must not hide what was not read, or the report names
  // one change and reads as though the milestone was read whole.
  test('a named change and what was not read are both said', async () => {
    const others = 'other changes to milestone "Ungrouped" in o/r were not checked'
    // Three full pages, the newest change one no session made: the start of the night is still unread.
    const full = (from: number) => Array.from({ length: 100 }, (_, i) => closed(7, new Date(SINCE + (from - i) * 60_000).toISOString(), 'dan'))
    const capped = await check({
      [MS]: ok(JSON.stringify([{ ...ungrouped, updated_at: new Date(SINCE + 400 * 60_000).toISOString() }])),
      [EVENTS(1)]: ok(JSON.stringify([closed(11, new Date(SINCE + 400 * 60_000).toISOString(), 'eve'), ...full(399).slice(0, 99)])),
      [EVENTS(2)]: ok(JSON.stringify(full(300))),
      [EVENTS(3)]: ok(JSON.stringify(full(200))),
      [CLOSERS]: ok(JSON.stringify([{ number: 11, closedByPullRequestsReferences: [] }])),
    }, github, ['o/r#7'])
    expect(capped.hits).toEqual([`${lead} "Ungrouped", ${nothing}: #11 closed by eve`])
    expect(capped.unmeasured).toEqual([`${others} (its issue events from 11:00 PM ET on Wed Oct 7 to 12:41 AM ET on Thu Oct 8 were not read: GitHub was asked for only the newest 300)`])

    // One change no session made, and a close whose pull request could not be read.
    const undecided = await check({
      [MS]: ok(JSON.stringify([{ ...ungrouped, updated_at: at('05:00:01') }])),
      [EVENTS(1)]: ok(JSON.stringify([
        closed(11, at('05:00:00'), 'eve'),
        { event: 'demilestoned', created_at: at('04:50:00'), actor: { login: 'eve' }, milestone: { title: 'Ungrouped' }, issue: { number: 12, milestone: null } },
        closed(1, BEFORE, 'eve'),
      ])),
      [CLOSERS]: fail('HTTP 502: Bad Gateway'),
    })
    expect(undecided.hits).toEqual([`${lead} "Ungrouped", ${nothing}: #12 removed from it by eve`])
    expect(undecided.unmeasured).toEqual([`${others} (the pull requests that closed its issues could not be read: HTTP 502: Bad Gateway)`])
  })

  test('the night\'s notes name the issues and pull requests its sessions worked, and nothing else', () => {
    expect(workedOn({ kind: 'done', repo: 'O/R', issue: 7, pr: 20 })).toEqual(['o/r#7', 'o/r#20'])
    expect(workedOn({ kind: 'claim', repo: 'o/r', issue: 3 })).toEqual(['o/r#3'])
    expect(workedOn({ kind: 'parked', repo: 'o/r', issue: 4 })).toEqual(['o/r#4'])
    // A question names an issue Dan was asked about, which no session changed.
    expect(workedOn({ kind: 'question', repo: 'o/r', issue: 5 })).toEqual([])
    expect(workedOn({ kind: 'done', repo: 'not a repo', issue: 5 })).toEqual([])
    expect(workedOn({ kind: 'done', repo: 'o/r', issue: '5' })).toEqual([])
    expect(workedOn('not a note')).toEqual([])
  })
})
