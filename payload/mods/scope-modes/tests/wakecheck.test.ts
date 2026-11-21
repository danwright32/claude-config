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
// The night's workflow runs in a repository, as GitHub's REST API lists them (#2766): created since
// sleep began, with how each was started and how it ended, a page of 100 at a time (#3284).
const RUNS = (repo: string, page = 1) => `gh api repos/${repo}/actions/runs?per_page=100&created=>=2026-10-08T03:00:00Z&page=${page}`
const runs = (list: object[], total = list.length): Ran => ok(JSON.stringify({ total_count: total, workflow_runs: list }))

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
  [RUNS('o/r')]: runs([]),
  [RUNS('o/claude-config')]: runs([]),
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
const check = async (over: World = {}, read: GithubOf = github, worked?: string[], repos?: string[]) => {
  const world = { ...QUIET, ...over }
  const asked: string[] = []
  const r = await wakeCheck(async argv => {
    const key = argv.join(' ')
    asked.push(key)
    return world[key] ?? fail(`unexpected: ${key}`)
  }, { since: SINCE, home: HOME, github: read, now: () => SINCE, mtimeOf: mtimeFrom(world, asked), worked, repos })
  return { ...r, asked }
}
// #3273: an issue filed overnight is read whole (its labels, milestone and body), and its repository's
// open issues once, so only one that needs Dan is put to him.
const ISSUE = (repo: string, n: number) => `gh api repos/${repo}/issues/${n}`
const OPEN = (repo: string) => `gh issue list -R ${repo} --state open --limit 1000 --json number,title`
const COMPLETE = { labels: [{ name: 'priority-p2' }, { name: 'bug' }], milestone: { title: 'Ungrouped' }, body: 'What broke.\n\n## Open questions\n\n- None.\n' }
const SEARCH_9 = (title = 'Filed overnight') =>
  ({ [`gh search issues --author @me --created >=2026-10-08T03:00:00Z --json repository,number,title,url --limit 100`]: ok(JSON.stringify([{ repository: { nameWithOwner: 'o/r' }, number: 9, title, url: 'https://github.com/o/r/issues/9' }])) })

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
    expect(r.asked).toContain(RUNS('o/claude-config'))
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
      [RUNS('o/s')]: runs([]),
      'gh api repos/o/claude-config/commits?path=payload/LESSONS.md&since=2026-10-08T03:00:00Z': ok(JSON.stringify([{ sha: 'abcdef1234', commit: { message: 'Add L999\n\nbody' } }])),
      [`mtime ${'/Users'}/x/.claude/LESSONS.md`]: ok(String(SINCE + 60_000)),
      [RUNS('o/r')]: runs([
        { name: 'Deploy', event: 'push', created_at: AFTER, html_url: 'https://github.com/o/r/actions/runs/1' },
        { name: 'CI', event: 'push', created_at: AFTER, html_url: 'https://github.com/o/r/actions/runs/2' },
        { name: 'Nightly', event: 'workflow_dispatch', created_at: AFTER, html_url: 'https://github.com/o/r/actions/runs/3' },
        { name: 'Deploy', event: 'push', created_at: BEFORE, html_url: 'https://github.com/o/r/actions/runs/0' },
      ]),
      [ISSUE('o/r', 9)]: ok(JSON.stringify(COMPLETE)),
      [ISSUE('o/s', 3)]: ok(JSON.stringify(COMPLETE)),
      [OPEN('o/r')]: ok(JSON.stringify([{ number: 9, title: 'Found overnight' }])),
      [OPEN('o/s')]: ok('[]'),
    }, github, undefined, ['o/r', 'o/s'])
    expect(r.unmeasured).toEqual([])
    // #3273: each issue filed overnight is said once, as filed, and never put to Dan as a row.
    expect(r.filed).toEqual([{ repo: 'o/r', issue: 9, title: 'Found overnight' }, { repo: 'o/s', issue: 3, title: 'Also overnight' }])
    expect(r.hits).toEqual([
      'Milestone touched overnight: o/r "New one", by changes nothing the night recorded accounts for: the milestone itself, at 1:00 AM ET on Thu Oct 8 (no issue event in it explains that)',
      'LESSONS.md changed overnight on GitHub: abcdef1 "Add L999"',
      'The installed LESSONS.md changed overnight, at 11:01 PM ET on Wed Oct 7',
      'Deploy run overnight: o/r Deploy (https://github.com/o/r/actions/runs/1)',
      // #3282: a run is said as a deploy only when its name says so, else by what started it.
      'Dispatched run overnight: o/r Nightly (https://github.com/o/r/actions/runs/3)',
    ])
  })
  test('a read that fails is said as not checked, never as nothing found (L460)', async () => {
    const r = await check({
      [`gh search issues --author @me --created >=2026-10-08T03:00:00Z --json repository,number,title,url --limit 100`]: fail('HTTP 403: rate limited'),
      [RUNS('o/r')]: ok('<html>'),
    })
    expect(r.hits).toEqual([])
    expect(r.unmeasured).toEqual([
      'issues created overnight were not checked (gh search issues: HTTP 403: rate limited)',
      'deploy runs in o/r were not checked (gh api: the answer was not JSON)',
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
      [RUNS('o/r')]: runs([{ name: 'Deploy', event: 'push', html_url: 'u' }]),
    })
    expect(r.hits).toEqual([])
    expect(r.unmeasured).toEqual([
      'when milestone "No date" in o/r was last touched is unknown (GitHub gave no time)',
      'when milestone "Garbled" in o/r was last touched is unknown (GitHub gave no time)',
      'when the Deploy run in o/r ran is unknown (GitHub gave no time)',
    ])
  })
  test('a full page of milestones says the rest were not read (L24)', async () => {
    const ms = Array.from({ length: 100 }, (_, n) => ({ title: `m${n}`, updated_at: BEFORE }))
    const r = await check({ 'gh api repos/o/r/milestones?state=all&per_page=100': ok(JSON.stringify(ms)) })
    expect(r.unmeasured).toEqual(['o/r holds 100 or more milestones, so only the first 100 were read'])
  })
  test('every repository the notes of the night name is read too, private ones included, whatever the events show', async () => {
    const world: World = {
      ...QUIET,
      'gh api repos/o/private/milestones?state=all&per_page=100': ok(JSON.stringify([{ number: 1, title: 'Secret', updated_at: AFTER }])),
      'gh api repos/o/private/issues/events?per_page=100&page=1': ok('[]'),
      [RUNS('o/private')]: runs([]),
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
    // #3240: the local read of the sync clone's remotes took the last 25 s, so the stop is in part 4.
    expect(r.unmeasured).toHaveLength(1)
    expect(r.unmeasured[0]).toMatch(/^the overnight check stopped at its 60 s limit, 100\.0 s after it began, in part 4 of 6 \(the changes to the lessons file on GitHub\): the last read it made, the issues created overnight, took 25\.0 s, and the next, the /)
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
    expect(r.unmeasured).toHaveLength(1)
    expect(r.unmeasured[0]).toMatch(/^the overnight check stopped at its 30 s limit, 48\.0 s after it began, in part 4 of 6 \(the changes to the lessons file on GitHub\): the last read it made, the issues created overnight, took 12\.0 s/)
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
    [RUNS(repo)]: runs([]),
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
    // #3240: the stop is said once, with the part, the last read made, the one not made, how far it
    // got, what came after it, and the slowest reads; the window of events it did not reach is in it.
    expect(r.unmeasured).toEqual([
      'the overnight check stopped at its 30 s limit, 36.0 s after it began, in part 2 of 6 (the GitHub events since sleep began): ' +
        'the last read it made, page 2 of the GitHub events, took 12.0 s, and the next, page 3 of the GitHub events, was not made. ' +
        'It had read 2 pages of events, so the GitHub events from 11:00 PM ET on Wed Oct 7 to 2:21 AM ET on Thu Oct 8 were not read for the repositories to check. ' +
        'The parts after it (the issues created overnight; the changes to the lessons file on GitHub; the milestones in each repository; the deploy runs in each repository) were not read either, ' +
        'and nothing read them later: the check runs once a night, when sleep mode ends. ' +
        'Its slowest reads: the GitHub login 12.0 s; page 1 of the GitHub events 12.0 s; page 2 of the GitHub events 12.0 s',
    ])
    expect(r.stopped).toMatchObject({ limitMs: 30_000, part: 2, parts: 6, partName: 'the GitHub events since sleep began', last: { step: 'page 2 of the GitHub events', ms: 12_000 }, next: 'page 3 of the GitHub events', elapsedMs: 36_000 })
    expect(r.stopped?.text).toBe(r.unmeasured[0])
    // The data holds what the sentence says: the pages of events read, and the same three slowest reads.
    expect(r.stopped?.pages).toBe(2)
    expect(r.stopped?.slowest).toEqual([
      { part: 1, step: 'the GitHub login', ms: 12_000 },
      { part: 2, step: 'page 1 of the GitHub events', ms: 12_000 },
      { part: 2, step: 'page 2 of the GitHub events', ms: 12_000 },
    ])
    expect(r.unmeasured[0]).toContain(`It had read ${r.stopped?.pages} pages of events`)
    expect(r.unmeasured[0]).toContain(`Its slowest reads: ${r.stopped?.slowest.map(x => `${x.step} ${(x.ms / 1000).toFixed(1)} s`).join('; ')}`)
  })
})

// #3240: the morning after 17 Nov 2026 said only that the overnight check stopped at its 30 s limit:
// not in which part, at which read, how far it had got, or whether anything read the rest. The check
// now records each GitHub read it makes, with its part and how long it took, every time it runs, and
// a stop names the part, the read, how far it got and what it never reached, once.
describe('a stop at the limit says where, how far, and what came after it (#3240)', () => {
  const ev = (p: number) => `gh api repos/o/r/issues/events?per_page=100&page=${p}`
  const full = Array.from({ length: 100 }, (_, i) => ({ event: 'labeled', created_at: new Date(SINCE + (400 - i) * 60_000).toISOString().replace(/\.\d{3}Z$/, 'Z') }))
  const world: World = {
    ...QUIET,
    'gh api repos/o/r/milestones?state=all&per_page=100': ok(JSON.stringify([{ number: 2, title: 'Ungrouped', updated_at: '2026-10-08T03:30:00Z' }])),
    [ev(1)]: ok(JSON.stringify(full)),
  }
  // Each GitHub read takes 2 s, but the first page of o/r's issue events takes 20 s; local reads take none.
  const slow = async (w: World, ms: Record<string, number> = { [ev(1)]: 20_000 }) => {
    let t = 0
    const asked: string[] = []
    const r = await wakeCheck(
      async argv => {
        const key = argv.join(' ')
        asked.push(key)
        if (argv[0] === 'gh') t += ms[key] ?? 2_000
        return w[key] ?? fail(`unexpected: ${key}`)
      },
      { since: SINCE, home: HOME, github, now: () => t, mtimeOf: mtimeFrom(w) },
    )
    return { ...r, asked }
  }

  test('a stop among the milestones names the repository read, how many were finished, and the part after it', async () => {
    const r = await slow(world)
    expect(r.asked).not.toContain(ev(2))
    expect(r.unmeasured[0]).toBe(
      'the overnight check stopped at its 30 s limit, 30.0 s after it began, in part 5 of 6 (the milestones in each repository): ' +
        'the last read it made, page 1 of the issue events in o/r, took 20.0 s, and the next, page 2 of the issue events in o/r, was not made. ' +
        'It had finished 0 of 2 repositories in this part. ' +
        'The parts after it (the deploy runs in each repository) were not read either, and nothing read them later: the check runs once a night, when sleep mode ends. ' +
        'Its slowest reads: page 1 of the issue events in o/r 20.0 s; the GitHub login 2.0 s; page 1 of the GitHub events 2.0 s',
    )
    expect(r.stopped).toMatchObject({ part: 5, done: 0, total: 2 })
    // Pages of events are kept only for a stop among the events; the slowest reads always.
    expect(r.stopped).not.toHaveProperty('pages')
    expect(r.stopped?.slowest[0]).toEqual({ part: 5, step: 'page 1 of the issue events in o/r', ms: 20_000 })
  })
  test('the limit is said once: what it left undecided names no limit of its own', async () => {
    const r = await slow(world)
    expect(r.unmeasured.filter(u => /limit/.test(u))).toHaveLength(1)
    expect(r.unmeasured[1]).toBe('whether milestone "Ungrouped" in o/r was changed only by the night\'s own work was not checked (its issue events from 11:00 PM ET on Wed Oct 7 to 4:01 AM ET on Thu Oct 8 were not read: page 2: the check ran out of time first)')
  })
  test('a stop in the last part says nothing came after it', async () => {
    const w: World = { ...QUIET, [RUNS('o/r')]: runs([]), [RUNS('o/claude-config')]: runs([]) }
    const r = await slow(w, { [RUNS('o/r')]: 30_000 })
    expect(r.unmeasured).toHaveLength(1)
    expect(r.unmeasured[0]).toContain('in part 6 of 6 (the deploy runs in each repository): the last read it made, page 1 of the runs in o/r, took ')
    expect(r.unmeasured[0]).toContain('It had finished 1 of 2 repositories in this part. Nothing read the rest of it later: the check runs once a night, when sleep mode ends.')
  })
  test('every GitHub read is recorded with its part and how long it took, on a night it finished too', async () => {
    const r = await slow(QUIET, {})
    expect(r.stopped).toBeNull()
    expect(r.unmeasured).toEqual([])
    expect(r.steps.map(s => s.part)).toEqual([1, 2, 3, 4, 5, 5, 6, 6])
    expect(r.steps.every(s => s.ms === 2_000)).toBe(true)
    expect(r.steps[0]).toEqual({ part: 1, step: 'the GitHub login', ms: 2_000 })
    expect(r.steps[6]).toEqual({ part: 6, step: 'page 1 of the runs in o/r', ms: 2_000 })
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
        // Filed into it overnight: already accounted for as an issue created overnight (`filed`).
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
      [ISSUE('o/r', 9)]: ok(JSON.stringify(COMPLETE)),
      [OPEN('o/r')]: ok(JSON.stringify([{ number: 9, title: 'Filed overnight' }])),
    }, github, ['o/r#7', 'o/r#20'], ['o/r'])
    expect(r.unmeasured).toEqual([])
    expect(r.hits).toEqual([])
    expect(r.filed).toEqual([{ repo: 'o/r', issue: 9, title: 'Filed overnight' }])
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

// #2766: on 2026-11-11 the check listed 34 lines and none needed Dan: scheduled runs that passed or
// were skipped, the passing deploy of a merge the night's notes account for, and milestone changes
// made from his own accounts by other sessions. Each is now counted, never listed, and the count is
// said in one line, so a check that stopped looking reads differently from a quiet night. What went
// wrong (a scheduled run that failed, was cancelled or timed out; a deploy that failed) is still listed.
describe('what needs nobody is counted, never listed (#2766)', () => {
  const MS = 'gh api repos/o/r/milestones?state=all&per_page=100'
  const EVENTS = 'gh api repos/o/r/issues/events?per_page=100&page=1'
  const CLOSERS = 'gh issue list -R o/r --state closed --search closed:>=2026-10-08T03:00:00Z --json number,closedByPullRequestsReferences --limit 100'
  const AUTH = 'gh auth status --json hosts'
  const PULLS = (sha: string) => `gh api repos/o/r/commits/${sha}/pulls`
  const url = (n: number) => `https://github.com/o/r/actions/runs/${n}`
  const run = (n: number, o: Record<string, unknown>) => ({ name: 'Drift check', event: 'schedule', status: 'completed', created_at: AFTER, html_url: url(n), ...o })
  const bot = { login: 'github-actions[bot]', type: 'Bot' }

  test('a scheduled run that passed or was skipped is counted, and one that failed, was cancelled or timed out is listed', async () => {
    const r = await check({
      [RUNS('o/r')]: runs([
        run(1, { conclusion: 'success' }),
        run(2, { conclusion: 'success' }),
        run(3, { conclusion: 'skipped', name: 'Alert on deploy failure' }),
        run(4, { conclusion: 'failure' }),
        run(5, { conclusion: 'cancelled' }),
        run(6, { conclusion: 'timed_out' }),
        run(7, { status: 'in_progress', conclusion: null }),
      ]),
    })
    expect(r.unmeasured).toEqual([])
    expect(r.hits).toEqual([
      `Scheduled run overnight: o/r Drift check, failed (${url(4)})`,
      `Scheduled run overnight: o/r Drift check, cancelled (${url(5)})`,
      `Scheduled run overnight: o/r Drift check, timed out (${url(6)})`,
    ])
    expect(r.checked).toBe('The overnight check read 2 repositories on GitHub; left out as healthy: 2 scheduled runs passed, 1 scheduled run skipped, 1 scheduled run still running.')
  })

  test('a run dispatched by a cron (a bot started it) is judged as a scheduled one; a deploy a person dispatched is still listed', async () => {
    const r = await check({
      [RUNS('o/r')]: runs([
        run(1, { event: 'workflow_dispatch', conclusion: 'success', triggering_actor: bot }),
        run(2, { event: 'workflow_dispatch', conclusion: 'failure', triggering_actor: bot }),
        // A deploy dispatched from the gh login, as a session would, for no merge the night
        // accounts for: listed however it ended. #3282 counts a person's passing canary instead,
        // since a run whose name is not a deploy's changed nothing when it passed.
        run(3, { event: 'workflow_dispatch', name: 'Deploy', conclusion: 'success', triggering_actor: { login: 'dan', type: 'User' } }),
      ]),
    })
    expect(r.hits).toEqual([
      `Scheduled run overnight: o/r Drift check, failed (${url(2)})`,
      `Deploy run overnight: o/r Deploy, passed (${url(3)})`,
    ])
    expect(r.checked).toBe('The overnight check read 2 repositories on GitHub; left out as healthy: 1 scheduled run passed.')
  })

  test('a deploy that passed for a merge the night accounts for is counted; one that failed, or of a merge it does not, is listed', async () => {
    const deploy = (n: number, sha: string, conclusion: string) => ({ name: 'Deploy', event: 'push', status: 'completed', conclusion, head_sha: sha, created_at: AFTER, html_url: url(n) })
    const r = await check({
      [RUNS('o/r')]: runs([deploy(1, 'aaaaaaa1', 'success'), deploy(2, 'bbbbbbb2', 'success'), deploy(3, 'aaaaaaa1', 'failure'), deploy(4, 'ccccccc3', 'success')]),
      // The night's notes name PR #20, whose merge commit started run 1.
      [PULLS('aaaaaaa1')]: ok(JSON.stringify([{ number: 20 }])),
      [PULLS('bbbbbbb2')]: ok(JSON.stringify([{ number: 31 }])),
      [PULLS('ccccccc3')]: fail('HTTP 502: Bad Gateway'),
    }, github, ['o/r#20'])
    expect(r.hits).toEqual([
      `Deploy run overnight: o/r Deploy, passed (${url(2)})`,
      `Deploy run overnight: o/r Deploy, failed (${url(3)})`,
      `Deploy run overnight: o/r Deploy, passed (${url(4)}); which merge started it could not be read (HTTP 502: Bad Gateway)`,
    ])
    expect(r.checked).toBe('The overnight check read 2 repositories on GitHub; left out as healthy: 1 deploy run of a merge the night accounts for passed.')
  })

  test('a milestone change made from one of Dan\'s own accounts is counted; one made by anybody else is listed', async () => {
    const ms = { number: 2, title: 'Ungrouped' }
    const closed = (n: number, actor: string, when: string) => ({ event: 'closed', created_at: when, actor: { login: actor }, issue: { number: n, milestone: ms } })
    const world = {
      [MS]: ok(JSON.stringify([{ ...ms, updated_at: '2026-10-08T05:00:01Z' }])),
      [EVENTS]: ok(JSON.stringify([
        closed(11, 'dan', '2026-10-08T05:00:00Z'),
        closed(12, 'Dan-Work', '2026-10-08T04:59:00Z'),
        closed(13, 'eve', '2026-10-08T04:58:00Z'),
        closed(1, 'eve', BEFORE),
      ])),
      [CLOSERS]: ok(JSON.stringify([{ number: 11, closedByPullRequestsReferences: [] }, { number: 12, closedByPullRequestsReferences: [] }, { number: 13, closedByPullRequestsReferences: [] }])),
      // Every account gh is logged in to on this Mac is Dan's.
      [AUTH]: ok(JSON.stringify({ hosts: { 'github.com': [{ login: 'dan', active: true }, { login: 'dan-work', active: false }] } })),
    }
    const r = await check(world)
    expect(r.unmeasured).toEqual([])
    expect(r.hits).toEqual(['Milestone touched overnight: o/r "Ungrouped", by changes nothing the night recorded accounts for: #13 closed by eve'])
    expect(r.checked).toBe('The overnight check read 2 repositories on GitHub; left out as healthy: 2 milestone changes made from your own accounts.')

    // Which accounts are Dan's cannot be read: only the gh login is his, and the rest is listed.
    const unread = await check({ ...world, [AUTH]: fail('not logged in to dan-work') })
    expect(unread.hits).toEqual(['Milestone touched overnight: o/r "Ungrouped", by changes nothing the night recorded accounts for: #13 closed by eve; #12 closed by Dan-Work'])
    expect(unread.checked).toBe('The overnight check read 2 repositories on GitHub; left out as healthy: 1 milestone change made from your own accounts.')
  })

  test('a night whose every line is healthy lists nothing and still says what it read and left out', async () => {
    const r = await check({ [RUNS('o/r')]: runs([run(1, { conclusion: 'success' }), run(2, { conclusion: 'skipped' })]) })
    expect(r.hits).toEqual([])
    expect(r.unmeasured).toEqual([])
    expect(r.checked).toBe('The overnight check read 2 repositories on GitHub; left out as healthy: 1 scheduled run passed, 1 scheduled run skipped.')
    expect((await check()).checked).toBe('The overnight check read 2 repositories on GitHub and left nothing out.')
  })

  test('runs that cannot be read are said as not checked, never counted as healthy', async () => {
    const r = await check({ [RUNS('o/r')]: fail('HTTP 500: boom') })
    expect(r.hits).toEqual([])
    expect(r.unmeasured).toEqual(['deploy runs in o/r were not checked (gh api: HTTP 500: boom)'])
    expect(r.checked).toBe('The overnight check read 2 repositories on GitHub and left nothing out.')
    // Without the login nothing on GitHub was read, and the line says so.
    expect((await check({ 'gh api user --jq .login': fail('not logged in') })).checked).toBe('The overnight check read no repositories on GitHub and left nothing out.')
  })
})

// #3282: on waking on 2026-11-19 the check listed 18 healthy runs as "Deploy run overnight", a week
// after #2766 asked for them to be counted. That heading is written only for a run the rule did not
// take for a cron's, and #2803's rule took for one only a schedule or a dispatch a bot started. The
// night's runs were a smoke canary and drift checks dispatched on a timer with a person's token
// (GitHub says the starter is a User), and a deploy failure alert started by another workflow
// (workflow_run) that skipped because no deploy failed. #2803's own fixtures had the alert as a
// schedule and listed a person's passing canary on purpose, so nothing failed. The shapes below are
// that night's (its workflow names, events and conclusions), with made up repositories.
describe('a healthy run that no change to the code started is counted, whoever started it (#3282)', () => {
  const url = (n: number) => `https://github.com/o/r/actions/runs/${n}`
  const person = { login: 'dan', type: 'User' }
  const base = (n: number) => ({ id: n, status: 'completed', created_at: AFTER, html_url: url(n), triggering_actor: person, actor: person })
  const canary = (n: number, o: Record<string, unknown> = {}) => ({ ...base(n), name: 'Smoke canary', event: 'workflow_dispatch', conclusion: 'success', ...o })
  const alert = (n: number, o: Record<string, unknown> = {}) => ({ ...base(n), name: 'Deploy failure alert', event: 'workflow_run', conclusion: 'skipped', ...o })
  const drift = (n: number, o: Record<string, unknown> = {}) => ({ ...base(n), name: 'Drift check', display_title: 'Drift check (cron)', event: 'workflow_dispatch', conclusion: 'success', ...o })
  const PULLS = (sha: string) => `gh api repos/o/r/commits/${sha}/pulls`
  // Every run the count line says it left out, summed from its numbers.
  const countedRuns = (checked: string) => [...checked.matchAll(/(\d+) (?:scheduled|dispatched)? ?runs? /g)].reduce((s, m) => s + Number(m[1]), 0)

  test('the night of 2026-11-19: 10 canary passes, 3 skipped alerts and 5 drift checks from a cron list nothing', async () => {
    const list = [
      ...Array.from({ length: 10 }, (_, i) => canary(100 + i)),
      ...Array.from({ length: 3 }, (_, i) => alert(200 + i)),
      ...Array.from({ length: 5 }, (_, i) => drift(300 + i)),
    ]
    const r = await check({ [RUNS('o/r')]: runs(list) })
    expect(r.hits).toEqual([])
    expect(r.unmeasured).toEqual([])
    expect(r.checked).toBe('The overnight check read 2 repositories on GitHub; left out as healthy: 15 dispatched runs passed, 3 runs started by another workflow skipped.')
  })

  test('the same kinds that failed, were cancelled or timed out are still listed, each under what started it', async () => {
    const r = await check({
      [RUNS('o/r')]: runs([
        canary(1, { conclusion: 'failure' }),
        drift(2, { conclusion: 'timed_out' }),
        alert(3, { conclusion: 'failure' }),
        alert(4, { conclusion: 'cancelled' }),
        canary(5),
        canary(6, { event: 'repository_dispatch', conclusion: 'failure' }),
      ]),
    })
    expect(r.hits).toEqual([
      `Dispatched run overnight: o/r Smoke canary, failed (${url(1)})`,
      `Dispatched run overnight: o/r Drift check, timed out (${url(2)})`,
      `Deploy run overnight: o/r Deploy failure alert, failed (${url(3)})`,
      `Deploy run overnight: o/r Deploy failure alert, cancelled (${url(4)})`,
      `Dispatched run overnight: o/r Smoke canary, failed (${url(6)})`,
    ])
    expect(r.checked).toBe('The overnight check read 2 repositories on GitHub; left out as healthy: 1 dispatched run passed.')
  })

  test('a failed deploy of the night\'s own merge is listed, so is one whose every job skipped, and so is a deploy a person dispatched of a merge the night does not account for', async () => {
    const deploy = (n: number, conclusion: string, o: Record<string, unknown> = {}) => ({ ...base(n), name: 'Deploy', event: 'push', conclusion, head_sha: 'aaaaaaa1', ...o })
    const r = await check({
      [RUNS('o/r')]: runs([deploy(1, 'failure'), deploy(2, 'skipped'), deploy(3, 'success', { event: 'workflow_dispatch', head_sha: 'bbbbbbb2' }), deploy(4, 'success')]),
      // The night's notes name PR #20, whose merge commit started runs 1, 2 and 4; #31 is no session's.
      [PULLS('aaaaaaa1')]: ok(JSON.stringify([{ number: 20 }])),
      [PULLS('bbbbbbb2')]: ok(JSON.stringify([{ number: 31 }])),
    }, github, ['o/r#20'])
    expect(r.hits).toEqual([
      `Deploy run overnight: o/r Deploy, failed (${url(1)})`,
      `Deploy run overnight: o/r Deploy, skipped (${url(2)})`,
      `Deploy run overnight: o/r Deploy, passed (${url(3)})`,
    ])
    expect(r.checked).toBe('The overnight check read 2 repositories on GitHub; left out as healthy: 1 deploy run of a merge the night accounts for passed.')
  })

  test('no healthy run that no change to the code started is listed, under any heading, and each one is counted', async () => {
    // Every way GitHub can say such a run was started, by every kind of starter, ending every
    // healthy way; a name that says deploy only where the run did nothing (skipped). A run another
    // workflow started is read only when its name says deploy, as before, so it has no canary here.
    const list: object[] = []
    let n = 1000
    for (const event of ['schedule', 'workflow_dispatch', 'repository_dispatch', 'workflow_run'])
      for (const starter of [person, { login: 'github-actions[bot]', type: 'Bot' }, { login: 'cron-app[bot]', type: 'Bot' }, null])
        for (const end of [{ conclusion: 'success' }, { conclusion: 'skipped' }, { status: 'in_progress', conclusion: null }, { status: 'queued', conclusion: null }]) {
          if (event !== 'workflow_run') list.push({ ...base(n++), name: 'Smoke canary', event, triggering_actor: starter, actor: starter, ...end })
          if (end.conclusion === 'skipped') list.push({ ...base(n++), name: 'Deploy failure alert', event, triggering_actor: starter, actor: starter, ...end })
        }
    const r = await check({ [RUNS('o/r')]: runs(list) })
    expect(r.hits).toEqual([])
    expect(r.unmeasured).toEqual([])
    expect(countedRuns(r.checked)).toBe(list.length)
  })
})

// #3284: on waking on 2026-11-19 the check said the runs from 12:07 AM to 3:16 AM ET in one
// repository "were not read for deploys (only the newest 100 of 160 were asked for)": GitHub lists
// runs newest first, so a busy night's early hours were never checked for a failed deploy. Every
// run since sleep began is now read, a page of 100 at a time (measured 2026-11-20: page 2 of a
// created filter carries on where page 1 stopped, and total_count stays the whole window's count).
describe('every run of the night is read, page by page (#3284)', () => {
  const stamp = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z')
  // `n` runs since sleep began, one a minute, newest first, as GitHub lists them: run i was made
  // n minus i minutes after sleep began, so the oldest page holds the night's first hours.
  const night = (n: number, o: (i: number) => Record<string, unknown> = () => ({})) =>
    Array.from({ length: n }, (_, i) => ({
      id: 5000 + n - i,
      name: 'Drift check',
      event: 'schedule',
      status: 'completed',
      conclusion: 'success',
      created_at: stamp(SINCE + (n - i) * 60_000),
      html_url: `https://github.com/o/r/actions/runs/${5000 + n - i}`,
      ...o(i),
    }))
  // Every page of o/r's runs, each saying the whole window's count, as GitHub answers.
  const paged = (list: object[], total = list.length): World =>
    Object.fromEntries(Array.from({ length: Math.max(1, Math.ceil(list.length / 100)) }, (_, p) => [RUNS('o/r', p + 1), runs(list.slice(p * 100, p * 100 + 100), total)]))
  const runReads = (asked: string[]) => asked.filter(a => a.startsWith('gh api repos/o/r/actions/runs'))
  const failedDeploy = (i: number) => (i === 150 ? { name: 'Deploy', event: 'push', conclusion: 'failure' } : {})

  test('a failed deploy in the oldest page of a busy night is listed, and nothing is said unread', async () => {
    const list = night(160, failedDeploy)
    const r = await check(paged(list))
    expect(r.hits).toEqual(['Deploy run overnight: o/r Deploy, failed (https://github.com/o/r/actions/runs/5010)'])
    expect(r.unmeasured).toEqual([])
    expect(runReads(r.asked)).toEqual([RUNS('o/r', 1), RUNS('o/r', 2)])
    expect(r.checked).toBe('The overnight check read 2 repositories on GitHub; left out as healthy: 159 scheduled runs passed.')
  })
  test('a night takes one read per 100 runs: 1 for 100, 2 for 160, 5 for 500, 10 for 1000', async () => {
    const reads = async (n: number) => runReads((await check(paged(night(n)))).asked).length
    expect([await reads(0), await reads(100), await reads(160), await reads(500), await reads(1000)]).toEqual([1, 1, 2, 5, 10])
  })
  test('a page that cannot be read says the window it would have covered, and what was read is still judged', async () => {
    const list = night(160, i => (i === 20 ? { name: 'Deploy', event: 'push', conclusion: 'failure' } : {}))
    const r = await check({ ...paged(list), [RUNS('o/r', 2)]: fail('HTTP 502: bad gateway') })
    expect(r.hits).toEqual(['Deploy run overnight: o/r Deploy, failed (https://github.com/o/r/actions/runs/5140)'])
    expect(r.unmeasured).toEqual(['the runs in o/r from 11:00 PM ET on Wed Oct 7 to 12:01 AM ET on Thu Oct 8 were not read for deploys (page 2: HTTP 502: bad gateway)'])
  })
  test('a page that is not JSON, or holds no list of runs, says the window too', async () => {
    const list = night(160)
    const bad = await check({ ...paged(list), [RUNS('o/r', 2)]: ok('<html>') })
    expect(bad.unmeasured).toEqual(['the runs in o/r from 11:00 PM ET on Wed Oct 7 to 12:01 AM ET on Thu Oct 8 were not read for deploys (page 2: the answer was not JSON)'])
    const empty = await check({ ...paged(list), [RUNS('o/r', 2)]: ok('{"total_count":160}') })
    expect(empty.unmeasured).toEqual(['the runs in o/r from 11:00 PM ET on Wed Oct 7 to 12:01 AM ET on Thu Oct 8 were not read for deploys (page 2: the answer held no list of runs)'])
  })
  test('past the 1000 runs GitHub lists for a window, the rest are said unread by their window, never asked for', async () => {
    const r = await check(paged(night(1200, failedDeploy)))
    expect(runReads(r.asked)).toHaveLength(10)
    expect(r.asked).not.toContain(RUNS('o/r', 11))
    expect(r.hits).toEqual(['Deploy run overnight: o/r Deploy, failed (https://github.com/o/r/actions/runs/6050)'])
    expect(r.unmeasured).toEqual(['the runs in o/r from 11:00 PM ET on Wed Oct 7 to 2:21 AM ET on Thu Oct 8 were not read for deploys (GitHub lists only the newest 1000 runs of a window, and this one held 1200)'])
  })
  test('a run pushed onto the next page by a newer one is judged once', async () => {
    const list = night(160, i => (i === 99 ? { conclusion: 'failure' } : {}))
    const r = await check({ ...paged(list, 161), [RUNS('o/r', 2)]: runs(list.slice(99), 161) })
    expect(r.hits).toEqual(['Scheduled run overnight: o/r Drift check, failed (https://github.com/o/r/actions/runs/5061)'])
    expect(r.unmeasured).toEqual([])
    expect(r.checked).toBe('The overnight check read 2 repositories on GitHub; left out as healthy: 159 scheduled runs passed.')
  })
  test('a page past the deadline, on the injected clock, says the window it left unread; the limit is said once', async () => {
    const world: World = { ...QUIET, ...paged(night(160, failedDeploy)) }
    let t = 0
    const asked: string[] = []
    const r = await wakeCheck(
      async argv => {
        const key = argv.join(' ')
        asked.push(key)
        if (argv[0] === 'gh') t += key === RUNS('o/r', 1) ? 30_000 : 500
        return world[key] ?? fail(`unexpected: ${key}`)
      },
      { since: SINCE, home: HOME, github, now: () => t, mtimeOf: mtimeFrom(world) },
    )
    expect(asked).not.toContain(RUNS('o/r', 2))
    expect(r.hits).toEqual([])
    expect(r.unmeasured.filter(u => /limit/.test(u))).toHaveLength(1)
    expect(r.unmeasured[0]).toContain('in part 6 of 6 (the deploy runs in each repository): the last read it made, page 1 of the runs in o/r, took 30.0 s, and the next, page 2 of the runs in o/r, was not made.')
    expect(r.unmeasured[1]).toBe('the runs in o/r from 11:00 PM ET on Wed Oct 7 to 12:01 AM ET on Thu Oct 8 were not read for deploys (page 2: the check ran out of time first)')
  })
})

// #3273: on 2026-11-19 the morning put #3270, an issue the night's session had filed with every
// required field, to Dan as a picker ("Nothing needed ... I don't need to check every filed issue
// overnight"). An issue filed overnight is already on his list by being an issue, so it is returned
// as filed and said in one line; only one that needs him is still a row: filed without a required
// field, in a repository no session worked tonight, or with the title of another open issue there.
// A read that fails keeps it a row, saying what was not checked (L460).
describe('an issue filed overnight is put to Dan only when it needs him (#3273)', () => {
  const lead = 'Issue created overnight: o/r#9 "Filed overnight"'
  const filedWith = (issue: object, open: object[] = [{ number: 9, title: 'Filed overnight' }], repos = ['o/r']) =>
    check({ ...SEARCH_9(), [ISSUE('o/r', 9)]: ok(JSON.stringify(issue)), [OPEN('o/r')]: ok(JSON.stringify(open)) }, github, undefined, repos)

  test('one filed with every field, in a repository worked tonight, with no twin, is filed and asks nothing', async () => {
    const r = await filedWith(COMPLETE)
    expect(r.hits).toEqual([])
    expect(r.unmeasured).toEqual([])
    expect(r.filed).toEqual([{ repo: 'o/r', issue: 9, title: 'Filed overnight' }])
  })
  test('one filed without a required field is a row naming each field it lacks', async () => {
    const r = await filedWith({ labels: [{ name: 'bug' }], milestone: null, body: 'No section here.' })
    expect(r.filed).toEqual([])
    expect(r.hits).toEqual([`${lead} (filed without a milestone, a priority level and an Open questions section)`])
    // A priority level alone is no category, and an Open questions heading must be a heading of its own.
    const p = await filedWith({ ...COMPLETE, labels: [{ name: 'priority-p1' }], body: '## Open questions about the API\n' })
    expect(p.hits).toEqual([`${lead} (filed without a category label and an Open questions section)`])
  })
  test('one filed in a repository no session worked tonight is a row', async () => {
    const r = await filedWith(COMPLETE, undefined, [])
    expect(r.filed).toEqual([])
    expect(r.hits).toEqual([`${lead} (in a repository no session worked tonight)`])
  })
  test('one with the title of another open issue in its repository is a row naming that issue', async () => {
    const r = await filedWith(COMPLETE, [{ number: 9, title: 'Filed overnight' }, { number: 4, title: '  filed   OVERNIGHT ' }])
    expect(r.filed).toEqual([])
    expect(r.hits).toEqual([`${lead} (with the same title as open issue #4)`])
  })
  test('a read that fails keeps it a row, saying what was not checked, never filed', async () => {
    const r = await check({ ...SEARCH_9(), [ISSUE('o/r', 9)]: fail('HTTP 502: Bad Gateway'), [OPEN('o/r')]: fail('HTTP 503') }, github, undefined, ['o/r'])
    expect(r.filed).toEqual([])
    expect(r.hits).toEqual([`${lead} (its required fields were not checked: gh api: HTTP 502: Bad Gateway; whether it repeats an open issue was not checked: gh issue list: HTTP 503)`])
    const big = await filedWith(COMPLETE, Array.from({ length: 1000 }, (_, i) => ({ number: 1000 + i, title: `Other ${i}` })))
    expect(big.hits).toEqual([`${lead} (whether it repeats an open issue was not checked: only the first 1000 open issues were read)`])
  })
  test('the open issues of a repository are read once for every issue filed in it', async () => {
    const r = await check({
      [`gh search issues --author @me --created >=2026-10-08T03:00:00Z --json repository,number,title,url --limit 100`]: ok(JSON.stringify([
        { repository: { nameWithOwner: 'o/r' }, number: 9, title: 'Filed overnight', url: 'u' },
        { repository: { nameWithOwner: 'o/r' }, number: 10, title: 'Also filed', url: 'u' },
      ])),
      [ISSUE('o/r', 9)]: ok(JSON.stringify(COMPLETE)),
      [ISSUE('o/r', 10)]: ok(JSON.stringify(COMPLETE)),
      [OPEN('o/r')]: ok(JSON.stringify([{ number: 9, title: 'Filed overnight' }, { number: 10, title: 'Also filed' }])),
    }, github, undefined, ['o/r'])
    expect(r.hits).toEqual([])
    expect(r.filed.map(f => f.issue)).toEqual([9, 10])
    expect(r.asked.filter(a => a === OPEN('o/r'))).toHaveLength(1)
  })
})
