import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

// #1205: a /login in this session changes the account it runs on, and two mods followed it, each
// with its own copy of the reading and the half minute wait (#1201, #1204). mod-kit now follows it
// once and raises modkit.login with the account the login file names, for every mod to hook.

const T0 = 1_791_000_000_000
const SEC = 1_000
const MIN = 60 * SEC
const HOME = '/Users/x'
const LOGIN = `${HOME}/.claude.json`

// A mod that follows logins: each modkit.login it is raised reaches the test as a toast. It loads as
// a module of its own, so the toast is how it reports.
const follower: { name: string; register: Register } = {
  name: 'follower',
  register: on => {
    on('modkit.login', async ($, e, next) => {
      $.ui.toast(`login ${JSON.stringify(e.account)}`)
      return next(e)
    })
  },
}
const withFollower = { plugins: [follower] }

const as = (id: string, org = 'Acme') =>
  JSON.stringify({ oauthAccount: { accountUuid: id, organizationUuid: `org-${id}`, displayName: 'Dan', emailAddress: `${id}@example.com`, organizationName: org, billingType: 'kept out' }, other: 'kept out' })
const account = (id: string, org = 'Acme') => ({ accountUuid: id, organizationUuid: `org-${id}`, displayName: 'Dan', emailAddress: `${id}@example.com`, organizationName: org })

const world = (on: On, then: (files: Record<string, string>) => void = () => undefined) => {
  const files: Record<string, string> = { [LOGIN]: as('acct-1') }
  const toasts: string[] = []
  mock.env(on, { HOME })
  const clock = mock.clock(on, { now: T0 })
  on('fs.exists', ($, e) => ({ value: e.path in files }) as never)
  on('fs.read', ($, e) => {
    const text = files[e.path]
    if (text === undefined) return { deny: `ENOENT: no such file or directory, open '${e.path}'` } as never
    return { value: text } as never
  })
  on('fs.list', () => ({ value: [] }) as never)
  on('command.register', ($, e) => ({ value: { command: e.name } }) as never)
  on('command.run', ($, e) => {
    if ((e as { command: string }).command !== 'login') return { text: '' } as never
    then(files)
    return { text: 'Login successful.' } as never
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  on('ui.log', () => ({ value: undefined }) as never)
  return { files, toasts, clock }
}
type S = { session: { start: (e: never) => Promise<unknown>; end: (e: never) => Promise<unknown> }; command: { run: (e: object) => Promise<{ text?: string }> } }
const start = async ($: unknown, clock: { settle: () => Promise<void> }) => {
  await ($ as S).session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  await clock.settle()
}
const runLogin = async ($: unknown, clock: { settle: () => Promise<void> }, command = 'login') => {
  const out = await ($ as S).command.run({ command, args: '', origin: { kind: 'human' }, presentation: {} })
  await clock.settle()
  return out
}
const end = async ($: unknown, clock: { settle: () => Promise<void> }, reason: string) => {
  await ($ as S).session.end({ sessionId: 's1', reason } as never)
  await clock.settle()
}
const logins = (toasts: string[]) => toasts.filter(t => t.startsWith('login ')).map(t => JSON.parse(t.slice(6)) as unknown)

test('a /login raises modkit.login with the account it logged in to, and keeps its own output', withFollower, async ($, on) => {
  const { toasts, clock } = world(on, files => {
    files[LOGIN] = as('acct-2', 'Personal')
  })
  await start($, clock)
  const out = await runLogin($, clock)
  expect(out.text).toBe('Login successful.')
  expect(logins(toasts)).toEqual([account('acct-2', 'Personal')])
})

test('a /login that returns before the login file changes is raised again once it does, then no longer', withFollower, async ($, on) => {
  const { files, toasts, clock } = world(on)
  await start($, clock)
  await runLogin($, clock)
  expect(logins(toasts)).toEqual([account('acct-1')])
  files[LOGIN] = as('acct-2')
  await clock.advance(2 * SEC)
  expect(logins(toasts)).toEqual([account('acct-1'), account('acct-2')])
  // Later, another session switches the Mac: nothing more is raised for it.
  files[LOGIN] = as('acct-3')
  await clock.advance(MIN)
  expect(logins(toasts)).toEqual([account('acct-1'), account('acct-2')])
})

test('a /login that changes nothing, as a cancelled one, stops being followed after half a minute', withFollower, async ($, on) => {
  const { files, toasts, clock } = world(on)
  await start($, clock)
  await runLogin($, clock)
  await clock.advance(31 * SEC)
  files[LOGIN] = as('acct-2')
  await clock.advance(MIN)
  expect(logins(toasts)).toEqual([account('acct-1')])
})

test('a login file that cannot be read after a /login is raised as unknown, then as the account once it can be read', withFollower, async ($, on) => {
  const { files, toasts, clock } = world(on, f => {
    f[LOGIN] = 'not json'
  })
  await start($, clock)
  await runLogin($, clock)
  expect(logins(toasts)).toEqual([null])
  files[LOGIN] = as('acct-2')
  await clock.advance(2 * SEC)
  expect(logins(toasts)).toEqual([null, account('acct-2')])
})

test('no login file at all after a /login is no account, never an unknown one', withFollower, async ($, on) => {
  const { toasts, clock } = world(on, f => {
    delete f[LOGIN]
  })
  await start($, clock)
  await runLogin($, clock)
  expect(logins(toasts)[0]).toEqual({})
})

test('a /clear while a /login is awaited goes on following it, and a real end stops it', withFollower, async ($, on) => {
  const { files, toasts, clock } = world(on)
  await start($, clock)
  await runLogin($, clock)
  await end($, clock, 'clear')
  files[LOGIN] = as('acct-2')
  await clock.advance(2 * SEC)
  expect(logins(toasts)).toEqual([account('acct-1'), account('acct-2')])
  await runLogin($, clock)
  await end($, clock, 'exit')
  files[LOGIN] = as('acct-3')
  await clock.advance(2 * SEC)
  expect(logins(toasts)).toEqual([account('acct-1'), account('acct-2'), account('acct-2')])
})

test('another slash command raises nothing', withFollower, async ($, on) => {
  const { files, toasts, clock } = world(on)
  await start($, clock)
  files[LOGIN] = as('acct-2')
  await runLogin($, clock, 'help')
  await clock.advance(2 * SEC)
  expect(logins(toasts)).toEqual([])
})
