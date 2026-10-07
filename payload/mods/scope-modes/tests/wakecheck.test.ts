import { describe, expect, test } from 'claude-code/testing'
import { wakeCheck, type Ran } from '../hooks/wakecheck.ts'

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
  'gh api users/dan/events?per_page=100': ok(JSON.stringify([{ type: 'PushEvent', created_at: AFTER, repo: { name: 'o/r' } }])),
  [`gh search issues --author @me --created >=2026-10-08T03:00:00Z --json repository,number,title,url --limit 100`]: ok('[]'),
  'git -C /Users/x/claude-config-sync remote -v': ok('origin\tgit@github.com:o/claude-config.git (fetch)\n'),
  'gh api repos/o/claude-config/commits?path=payload/LESSONS.md&since=2026-10-08T03:00:00Z': ok('[]'),
  'stat -f %m /Users/x/.claude/LESSONS.md': ok('1700000000\n'),
  'gh api repos/o/r/milestones?state=all&per_page=100': ok('[]'),
  'gh api repos/o/claude-config/milestones?state=all&per_page=100': ok('[]'),
  'gh run list -R o/r --json workflowName,event,createdAt,url --limit 100': ok('[]'),
  'gh run list -R o/claude-config --json workflowName,event,createdAt,url --limit 100': ok('[]'),
}
const check = async (over: World = {}) => {
  const world = { ...QUIET, ...over }
  const asked: string[] = []
  const r = await wakeCheck(async argv => {
    const key = argv.join(' ')
    asked.push(key)
    return world[key] ?? fail(`unexpected: ${key}`)
  }, { since: SINCE, home: HOME })
  return { ...r, asked }
}

describe('the wake check', () => {
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
      'gh api users/dan/events?per_page=100': ok(JSON.stringify([
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
  test('a full page of milestones or runs says the rest were not read (L24)', async () => {
    const ms = Array.from({ length: 100 }, (_, n) => ({ title: `m${n}`, updated_at: BEFORE }))
    const runs = Array.from({ length: 100 }, () => ({ workflowName: 'CI', event: 'push', createdAt: AFTER, url: 'u' }))
    const r = await check({
      'gh api repos/o/r/milestones?state=all&per_page=100': ok(JSON.stringify(ms)),
      'gh run list -R o/r --json workflowName,event,createdAt,url --limit 100': ok(JSON.stringify(runs)),
    })
    expect(r.unmeasured).toEqual(['o/r holds 100 or more milestones, so only the first 100 were read', 'more than 100 runs in o/r since sleep began, so only the newest 100 were read'])
  })
  test('every repository the notes of the night name is read too, private ones included, whatever the events show', async () => {
    const world: World = { ...QUIET, 'gh api repos/o/private/milestones?state=all&per_page=100': ok(JSON.stringify([{ title: 'Secret', updated_at: AFTER }])), 'gh run list -R o/private --json workflowName,event,createdAt,url --limit 100': ok('[]') }
    const r = await wakeCheck(async argv => world[argv.join(' ')] ?? fail(`unexpected: ${argv.join(' ')}`), { since: SINCE, home: HOME, repos: ['O/Private'] })
    expect(r.hits).toEqual(['Milestone touched overnight: o/private "Secret"'])
    expect(r.unmeasured).toEqual([])
  })
  test('without the GitHub login nothing on GitHub can be read, and that is said', async () => {
    const r = await check({ 'gh api user --jq .login': fail('not logged in') })
    expect(r.unmeasured[0]).toBe('GitHub was not checked at all: the gh login could not be read (not logged in)')
  })
  test('a full page of events since sleep began says the rest were not read (L24)', async () => {
    const many = Array.from({ length: 100 }, () => ({ type: 'PushEvent', created_at: AFTER, repo: { name: 'o/r' } }))
    const r = await check({ 'gh api users/dan/events?per_page=100': ok(JSON.stringify(many)) })
    expect(r.unmeasured).toContain('more than 100 GitHub events since sleep began, so only the newest 100 were read for the repositories to check')
  })
})
