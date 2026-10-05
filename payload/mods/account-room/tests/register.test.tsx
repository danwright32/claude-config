import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { accountKey } from '../hooks/store.ts'

// The account room in a session (#659): what it records, what the band shows, Switch, Dismiss, the
// nickname ask and /accounts rename. The look and words are the design rounds of 2026-10-04
// (docs/mods-design.md "Account room (#659)"); the pure judgments are tested in room.test.ts.

// mod-kit, standing in: a mod cannot import another mod's files. It keeps the rows the account room
// publishes and draws them as text and buttons so the test reads what Dan would. Its slot list
// includes 'room', as the real one does; mod-kit's own tests prove the real order.
type Part = { text?: string; color?: string; button?: string; label?: string }
type Row = { mod: string; id: string; slot: string; lines: Part[][]; frame?: unknown }
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const rows = async () => (((await built.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? [])
      const modkit = {
        bandRow: async (row: Row) => {
          if (!['needs-a-look', 'compact', 'room', 'handoff', 'held', 'steps', 'message', 'question'].includes(row.slot)) throw new Error(`a band row's slot "${row.slot}" is not one of them`)
          const now = (await rows()).filter(r => !(r.mod === row.mod && r.id === row.id))
          await built.state.set({ plugin: 'mod-kit', key: 'band' }, [...now, row] as never)
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
          await built.state.set({ plugin: 'mod-kit', key: 'band' }, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
        },
      }
      return { ...built, modkit } as never
    })
    on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
      const rows = ((await $.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? []
      if (!rows.length) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      return (
        <Box flexDirection="column">
          {rows.flatMap(r =>
            r.lines.map((l, n) => (
              <Box key={`${r.id}${n}`} flexDirection="row">
                {l.map((p, i) =>
                  p.button ? <Button key={`${r.mod}:${p.button}`} label={p.label as string} onPress={() => undefined} /> : <Text key={String(i)} color={p.color}>{p.text}</Text>,
                )}
              </Box>
            )),
          )}
        </Box>
      )
    })
  },
}
const withKit = { plugins: [modKit] }

// An older mod-kit, whose slot list has no 'room' (a Mac the sync has not yet brought up to date):
// it refuses the card, so the refusal path is exercised.
const modKitToday: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const slots = ['needs-a-look', 'compact', 'handoff', 'held', 'steps', 'message', 'question']
      const modkit = {
        bandRow: async (row: { slot: string }) => {
          if (!slots.includes(row.slot)) throw new Error(`a band row's slot "${row.slot}" is not one of ${slots.join(', ')}`)
        },
        clearBandRow: async () => undefined,
      }
      return { ...built, modkit } as never
    })
  },
}

const MIN = 60_000
const HOUR = 60 * MIN
const DAY = 24 * HOUR
// Sunday 2026-10-04 12:00 UTC, 8 AM in New York.
const T0 = Date.UTC(2026, 9, 4, 12, 0)
const HOME = '/Users/x'
const LOGIN = `${HOME}/.claude.json`
const FOLDER = `${HOME}/Library/Mobile Documents/com~apple~CloudDocs/account-room`
const OWN = `${FOLDER}/Daniels-MacBook-Pro-2.json`
const OTHER = `${FOLDER}/Dans-MacBook-Pro.json`
const NICKNAMES = `${HOME}/.claude/mods/account-room-nicknames.json`
const PANE = 'account-room-nickname'

const login = (account: string, email: string) => JSON.stringify({ oauthAccount: { accountUuid: account, organizationUuid: 'org-1', emailAddress: email, organizationName: 'Acme', displayName: 'Dan' } })

type Run = { exitCode: number; stdout: string; stderr: string }
type World = {
  files: Record<string, string>
  usage: { kind: string; percentUsed: number; resetsAt?: string }[]
  logout: Run
  check: Run
  authLogin: Run
  /** Holds the logout command until the test releases it, so the elapsed seconds can be watched. */
  logoutGate: Promise<void> | undefined
  /** Writes into the readings folder fail, as on a Mac with iCloud Drive switched off. */
  writeFails: boolean
  /** A lock left behind by a session that died, last touched this long before the start. */
  staleLockMs: number
  /** Reading the session's usage fails. */
  usageFails: boolean
  /** Writing a lock's ownership token fails. */
  tokenWriteFails: boolean
  /** Opening a pane fails. */
  openFails: boolean
  /** A pane opened unasked waits undrawn, as Claude Code does below 144 terminal columns. */
  openWaits: boolean
  /** Asking whether a path exists fails, as a disk going away would. */
  existsFails: boolean
  /** Asking whether the readings folder exists fails, and nothing else does. */
  folderExistsFails: boolean
  /** `claude auth login` cannot even be started. */
  authLoginThrows: boolean
}
const ok = (stdout = ''): Run => ({ exitCode: 0, stdout, stderr: '' })

// This Mac beneath the account room: files in memory, the host commands it runs, the clock, the
// session's rate limits, and Claude Code's own band beneath mod-kit's.
const world = (on: On, init: Partial<World> = {}) => {
  const w: World = { files: {}, usage: [], logout: ok(), check: ok('signed out\n'), authLogin: ok(), logoutGate: undefined, writeFails: false, staleLockMs: 0, usageFails: false, tokenWriteFails: false, openFails: false, openWaits: false, existsFails: false, folderExistsFails: false, authLoginThrows: false, ...init }
  const toasts: string[] = []
  const logs: string[] = []
  // The lines that reach the transcript, as against the debug log.
  const transcript: string[] = []
  const runs: string[][] = []
  const opened: string[] = []
  const closed: string[] = []
  mock.env(on, { HOME })
  const clock = mock.clock(on, { now: T0 })
  // Folders that exist: made by mkdir -p, or holding a file.
  const dirs = new Set<string>()
  const hasDir = (d: string) => dirs.has(d) || Object.keys(w.files).some(f => f.startsWith(`${d}/`))
  const missing = (p: string) => Object.assign(new Error(`ENOENT: no such file, '${p}'`), { code: 'ENOENT' })
  on('fs.read', ($, e) => {
    if (!(e.path in w.files)) throw missing(e.path)
    return { value: w.files[e.path] as string }
  })
  on('fs.write', ($, e) => {
    if (w.writeFails && e.path.startsWith(FOLDER)) throw new Error('EACCES: permission denied')
    if (w.tokenWriteFails && /write\.lock\//.test(e.path)) throw new Error('ENOSPC: no space left on device')
    w.files[e.path] = e.text
    return { value: undefined }
  })
  on('fs.exists', ($, e) => {
    if (w.existsFails || (w.folderExistsFails && e.path === FOLDER)) throw new Error('EIO: input/output error')
    return { value: e.path in w.files || Object.keys(w.files).some(f => f.startsWith(`${e.path}/`)) } as never
  })
  on('fs.list', ($, e) => {
    const names = Object.keys(w.files)
      .filter(f => f.startsWith(`${e.path}/`) && !f.slice(e.path.length + 1).includes('/'))
      .map(f => f.slice(e.path.length + 1))
    if (!names.length) throw missing(e.path)
    return { value: names.map(name => ({ name, kind: 'file' as const, size: 1, mtimeMs: T0, isLink: false })) } as never
  })
  let lockHeld = w.staleLockMs > 0
  on('fs.stat', () => ({ value: { kind: 'dir', size: 0, mtimeMs: T0 - w.staleLockMs } }) as never)
  on('process.run', async ($, e) => {
    runs.push([...e.argv])
    if (e.argv[0] === '/bin/sh' && e.argv[2] === 'LOGOUT' && w.logoutGate) await w.logoutGate
    const [cmd, ...rest] = e.argv
    const r = (x: Run) => ({ value: { ...x, isStdoutTruncated: false, isStderrTruncated: false } })
    if (cmd === 'mkdir' && rest[0] !== '-p' && lockHeld) return r({ exitCode: 1, stdout: '', stderr: 'File exists' })
    if (cmd === 'mkdir' && rest[0] === '-p') {
      let d = String(rest[1])
      while (d && d !== '/') {
        dirs.add(d)
        d = d.slice(0, d.lastIndexOf('/'))
      }
      return r(ok())
    }
    if (cmd === 'mkdir' || cmd === 'rmdir') return r(ok())
    if (cmd === 'mv' && String(rest[rest.length - 2]).endsWith('write.lock')) {
      // Taking over a stale lock moves it aside; only one session's move can succeed.
      if (!lockHeld) return r({ exitCode: 1, stdout: '', stderr: 'No such file or directory' })
      lockHeld = false
      return r(ok())
    }
    if (cmd === 'mv') {
      const [a, b] = rest.filter(x => !x.startsWith('-'))
      if (w.writeFails && String(b).startsWith(FOLDER)) return r({ exitCode: 1, stdout: '', stderr: 'Operation not permitted' })
      if (!hasDir(String(b).slice(0, String(b).lastIndexOf('/')))) return r({ exitCode: 1, stdout: '', stderr: 'No such file or directory' })
      w.files[b as string] = w.files[a as string] as string
      delete w.files[a as string]
      return r(ok())
    }
    if (cmd === 'rm' && rest[0] === '-rf') return r(ok())
    if (cmd === 'rm') {
      const targets = rest.filter(x => !x.startsWith('-'))
      if (targets.some(f => !(f in w.files))) return r({ exitCode: 1, stdout: '', stderr: 'No such file or directory' })
      for (const f of targets) delete w.files[f]
      return r(ok())
    }
    if (cmd === 'scutil') return r(ok('Daniels-MacBook-Pro-2\n'))
    // The offset at an instant: daylight time ends in New York on 1 November 2026.
    if (cmd === 'date' && rest[0] === '-r') return r(ok(Number(rest[1]) * 1000 >= Date.UTC(2026, 10, 1, 6, 0) ? '-0500\n' : '-0400\n'))
    if (cmd === 'date') return r(ok('-0400\n'))
    if (cmd === '/bin/sh' && rest[1] === 'LOGOUT') return r(w.logout)
    if (cmd === '/bin/sh' && rest[1] === 'CHECK') return r(w.check)
    if (cmd === 'claude') {
      if (w.authLoginThrows) throw new Error('spawn claude ENOENT')
      return r(w.authLogin)
    }
    return r({ exitCode: 1, stdout: '', stderr: 'unexpected' })
  })
  on('session.id', () => ({ value: 's1' }) as never)
  on('session.usage', () => {
    if (w.usageFails) throw new Error('usage unavailable')
    return { value: { startedAt: T0, context: { window: 200_000 }, rateLimits: w.usage } } as never
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.measure', ($, e) => ({ changed: e.changed }) as never)
  on('command.register', () => ({ value: undefined }) as never)
  on('ui.open', ($, e) => {
    if (w.openFails) throw new Error('no surface to open it on')
    opened.push(e.id)
    if (w.openWaits) return { value: { isPlaced: false, reason: 'the terminal is 120 columns wide; a pane opened unasked needs 144' } } as never
    return { value: { isPlaced: true } } as never
  })
  on('ui.close', ($, e) => {
    closed.push(e.id)
    return { value: undefined } as never
  })
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  on('ui.log', ($, e) => {
    logs.push(String(e.text))
    if (e.to !== 'debug') transcript.push(String(e.text))
    return { value: undefined } as never
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  return { w, toasts, logs, transcript, runs, opened, closed, clock }
}

type Session = { session: { start: (e: never) => Promise<unknown>; measure: (e: never) => Promise<unknown> } }
const start = async ($: Session, clock: { settle: () => Promise<void> }, isInteractive = true) => {
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive } as never)
  await clock.settle()
}
const iso = (ms: number) => new Date(ms).toISOString()
const limits = (five: number, week: number, fiveReset = T0 + 3 * HOUR, weekReset = T0 + 4 * DAY) => [
  { kind: 'five_hour', percentUsed: five, resetsAt: iso(fiveReset) },
  { kind: 'seven_day', percentUsed: week, resetsAt: iso(weekReset) },
]
const measure = async ($: Session, clock: { settle: () => Promise<void> }, rateLimits: unknown[]) => {
  await $.session.measure({ context: { window: 200_000 }, rateLimits, changed: ['rateLimits'] } as never)
  await clock.settle()
}

const band = { plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 120, scroll: { offset: 0, bodyRows: 20 }, view: {} } } as never
type Ui = {
  findAll: (q: { type: string }) => Promise<{ text: string; children: unknown[]; props: Record<string, unknown> }[]>
  find: (q: object) => Promise<{ props: Record<string, unknown> } | undefined>
  press: (t: object) => Promise<unknown>
  input: (t: object) => Promise<unknown>
  unmount: () => Promise<void>
}
const shown = async (ui: Ui) => (await ui.findAll({ type: 'Text' })).filter(t => t.children.every(c => typeof c === 'string')).map(t => t.text).join('')
const mountBand = async ($: { ui: { mount: (t: never) => Promise<unknown> } }) => (await $.ui.mount(band)) as Ui
const pane = { plugin: 'account-room', surface: 'terminal', component: 'Pane', requestId: PANE, props: { title: 'Nickname', isFocused: true, bodyColumns: 80, placement: 'inline', scroll: { offset: 0, bodyRows: 10 }, view: {} } } as never

// Work, read 2 hours ago on the other Mac, with plenty of room.
const otherMac = async (fiveUsed = 12, weekUsed = 30) =>
  JSON.stringify({
    v: 1,
    mac: 'Dans-MacBook-Pro',
    accounts: {
      [await accountKey('acct-work', 'org-1')]: {
        email: 'work@example.com',
        org: 'Acme',
        seenAt: T0 - 2 * HOUR,
        reading: { takenAt: T0 - 2 * HOUR, five: { used: fiveUsed, resetsAt: Date.UTC(2026, 9, 4, 22, 40) }, week: { used: weekUsed, resetsAt: Date.UTC(2026, 9, 8, 13, 0) } },
      },
    },
  })
const named = async (names: Record<string, string | null>) => {
  const out: Record<string, string | null> = {}
  for (const [acct, n] of Object.entries(names)) out[await accountKey(acct, 'org-1')] = n
  return JSON.stringify({ v: 1, names: out })
}

test("a reading is saved under the session's own account even after the login file names another", withKit, async ($, on) => {
  const { w, clock } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  // Another window logs in to Work: the file changes, this session's account does not (L175).
  w.files[LOGIN] = login('acct-work', 'work@example.com')
  await measure($, clock, limits(40, 50))
  const saved = JSON.parse(w.files[OWN] as string) as { mac: string; accounts: Record<string, { email: string; reading?: { five?: { used: number } } }> }
  expect(saved.mac).toBe('Daniels-MacBook-Pro-2')
  const home = await accountKey('acct-home', 'org-1')
  expect(saved.accounts[home]?.email).toBe('home@example.com')
  expect(saved.accounts[home]?.reading?.five?.used).toBe(40)
  expect(saved.accounts[await accountKey('acct-work', 'org-1')]).toBeUndefined()
  // No account or org id is ever written, only the hashed key.
  expect(w.files[OWN]).not.toContain('acct-home')
})

test('at 95% on the 5 hour limit the boxed card names the account with room; below it there is no card', withKit, async ($, on) => {
  const { clock } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(94, 50))
  expect(await shown(ui)).toBe('engine band')
  await measure($, clock, limits(95, 50))
  expect(await shown(ui)).toBe('This account is low. Work has room   88% of 5h left, resets 6:40 PM · 70% of week left, resets Thu 9 AM · as of 2h ago')
  expect((await ui.find({ type: 'Button', key: 'account-room:switch' }))?.props).toMatchObject({ label: 'Switch' })
  expect((await ui.find({ type: 'Button', key: 'account-room:dismiss' }))?.props).toMatchObject({ label: 'Dismiss' })
  // Back under the trigger (the window reset), the card goes.
  await measure($, clock, limits(3, 50))
  expect(await shown(ui)).toBe('engine band')
  await ui.unmount()
})

test('at 90% weekly with no other account able to help: the no room card, soonest reset and the unread account', withKit, async ($, on) => {
  const side = await accountKey('acct-side', 'org-1')
  const files = {
    [LOGIN]: login('acct-home', 'home@example.com'),
    [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work', 'acct-side': 'Side' }),
    [OTHER]: await otherMac(12, 95),
    [OWN]: JSON.stringify({ v: 1, mac: 'Daniels-MacBook-Pro-2', accounts: { [side]: { email: 'side@example.com', org: 'Acme', seenAt: T0 - DAY } } }),
  }
  const { clock } = world(on, { files })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(64, 91, Date.UTC(2026, 9, 4, 22, 40)))
  expect(await shown(ui)).toBe("This account is low. No other account has room  This account's 5h resets first, at 6:40 PM · Side has no reading yet and may have room")
  await ui.unmount()
})

test("an unreadable other Mac's file is named as unavailable, never read as no readings", withKit, async ($, on) => {
  const { clock } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }), [OTHER]: '{"v":1,"mac":"Dans-MacB' } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).toContain("Dans-MacBook-Pro's readings are unavailable: not readable JSON")
  await ui.unmount()
})

test("this Mac's own readings file that cannot be read is named, and never rewritten over the readings it holds (L105)", withKit, async ($, on) => {
  const { w, clock, logs } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }), [OWN]: 'garbage' } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).toContain("Daniels-MacBook-Pro-2's readings are unavailable: not readable JSON")
  expect(w.files[OWN]).toBe('garbage')
  expect(logs.filter(l => /readings file could not be read/.test(l))).toHaveLength(1)
  await ui.unmount()
})

test("this Mac's own file evicted by iCloud is named as not downloaded, and never replaced by a fresh one (L105)", withKit, async ($, on) => {
  const placeholder = `${FOLDER}/.Daniels-MacBook-Pro-2.json.icloud`
  const { w, clock, logs } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }), [placeholder]: 'bplist' } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).toContain("Daniels-MacBook-Pro-2's readings are unavailable: not downloaded from iCloud yet")
  expect(w.files[OWN]).toBeUndefined()
  expect(logs.filter(l => /not downloaded from iCloud/.test(l))).toHaveLength(1)
  await ui.unmount()
})

test('a disk error asking for the readings folder is named on the card, and the measurement still goes on (L215, review of #670)', withKit, async ($, on) => {
  const { clock, w } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  const ui = await mountBand($ as never)
  // The folder question alone fails, as iCloud Drive going away would; everything else answers.
  w.folderExistsFails = true
  await expect($.session.measure({ context: { window: 200_000 }, rateLimits: limits(96, 50), changed: ['rateLimits'] } as never)).resolves.toBeDefined()
  await clock.settle()
  expect(await shown(ui)).toContain("iCloud Drive's readings are unavailable: the readings folder could not be read: ")
  await ui.unmount()
})

test('a usage read that fails at start is said once, not taken as no readings (L215)', withKit, async ($, on) => {
  const { clock, logs } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) }, usageFails: true })
  await start($, clock)
  expect(logs.some(l => /could not read this session's rate limits at start: \S/.test(l))).toBe(true)
})

test("a measurement that lands before the start reading is not overwritten by it", withKit, async ($, on) => {
  const { w, clock } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  // The start reading, taken a moment earlier, says there is room; the newer measurement says low.
  w.usage = limits(10, 10)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  await $.session.measure({ context: { window: 200_000 }, rateLimits: limits(97, 50), changed: ['rateLimits'] } as never)
  await clock.settle()
  const ui = await mountBand($ as never)
  expect(await shown(ui)).toMatch(/^This account is low\. Work has room/)
  await ui.unmount()
})

test('Dismiss hides the card for this session only: nothing shared is written, so other sessions still show it', withKit, async ($, on) => {
  const { w, clock } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  const before = { ...w.files }
  delete before[OWN]
  await ui.press({ key: 'account-room:dismiss', plugin: 'mod-kit' })
  expect(await shown(ui)).toBe('engine band')
  await measure($, clock, limits(98, 50))
  expect(await shown(ui)).toBe('engine band')
  const after = { ...w.files }
  delete after[OWN]
  expect(after).toEqual(before)
  expect(JSON.stringify(w.files)).not.toMatch(/dismiss/i)
  await ui.unmount()
})

test('Switch shows its progress with elapsed seconds, and with no proven logout route it stops red, opening no sign in page', withKit, async ($, on) => {
  const { clock, runs } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  expect(await shown(ui)).toMatch(/^Switching to Work: signing claude\.ai out in the browser… 0s/)
  expect(await ui.find({ type: 'Button', key: 'account-room:switch' })).toBeUndefined()
  await clock.advance(1)
  expect(await shown(ui)).toMatch(/^claude\.ai didn't confirm the sign out\. Nothing else was changed\./)
  expect((await ui.find({ type: 'Text', text: "claude.ai didn't confirm the sign out. Nothing else was changed." }))?.props).toMatchObject({ color: 'error' })
  expect((await ui.find({ type: 'Button', key: 'account-room:retry' }))?.props).toMatchObject({ label: 'Try again' })
  expect(runs.some(r => r[0] === 'claude')).toBe(false)
  await ui.unmount()
})

const ROUTE = { options: { logoutCommand: 'LOGOUT', signedOutCheck: 'CHECK' } }

test('Switch with a logout route: elapsed seconds tick, then the sign in page opens with the account email', { ...withKit, ...ROUTE }, async ($, on) => {
  // The logout is held until the test releases it, 25 seconds into the mocked clock.
  let release: () => void = () => undefined
  const logoutGate = new Promise<void>(r => (release = r))
  const { clock, runs } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() }, logoutGate })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  await clock.advance(25_000)
  expect(await shown(ui)).toMatch(/^Switching to Work: signing claude\.ai out in the browser\u2026 25s/)
  expect(runs.some(r => r[0] === 'claude')).toBe(false)
  release()
  await clock.settle()
  expect(runs.find(r => r[0] === 'claude')).toEqual(['claude', 'auth', 'login', '--email=work@example.com'])
  await ui.unmount()
})

test('a logout whose check does not print signed out, or that fails, stops before the sign in page', { ...withKit, ...ROUTE }, async ($, on) => {
  const { w, clock, runs } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() }, check: ok('still signed in\n') })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  await clock.settle()
  expect(await shown(ui)).toMatch(/^claude\.ai didn't confirm the sign out/)
  w.check = ok('signed out\n')
  w.logout = { exitCode: 1, stdout: '', stderr: 'browser not running' }
  await ui.press({ key: 'account-room:retry', plugin: 'mod-kit' })
  await clock.settle()
  expect(await shown(ui)).toMatch(/^claude\.ai didn't confirm the sign out/)
  expect(runs.some(r => r[0] === 'claude')).toBe(false)
  // Try again with a working route goes on to the sign in page.
  w.logout = ok()
  await ui.press({ key: 'account-room:retry', plugin: 'mod-kit' })
  await clock.settle()
  expect(runs.filter(r => r[0] === 'claude')).toHaveLength(1)
  await ui.unmount()
})

test('a weekly reset after the clocks change reads in the offset of that day', withKit, async ($, on) => {
  const { clock } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  const ui = await mountBand($ as never)
  // No other account, so the card gives the soonest reset: this weekly one, Monday 2 November 14:00 UTC.
  await measure($, clock, [{ kind: 'seven_day', percentUsed: 95, resetsAt: iso(Date.UTC(2026, 10, 2, 14, 0)) }])
  expect(await shown(ui)).toContain("This account's week resets first, at Mon 9 AM")
  await ui.unmount()
})

test('a Switch stopped at the sign out says why in a toast, so Try again is not the only diagnosis (L148)', withKit, async ($, on) => {
  const { clock, toasts } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  await clock.advance(1)
  expect(toasts).toEqual(['Switch stopped: no browser logout route has been proven yet (#659)'])
  await ui.unmount()
})

test('an account with no recorded email is never signed in to blind: Switch refuses before the sign out', { ...withKit, ...ROUTE }, async ($, on) => {
  const work = await accountKey('acct-work', 'org-1')
  const other = JSON.parse(await otherMac()) as { accounts: Record<string, { email: string }> }
  ;(other.accounts[work] as { email: string }).email = ''
  const { clock, runs, toasts } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: JSON.stringify(other) } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  await clock.settle()
  expect(toasts).toEqual(['Switch did not run: no email is recorded for Work, so its sign in page could not be filled in.'])
  expect(runs.some(r => r[0] === '/bin/sh' || r[0] === 'claude')).toBe(false)
  expect(await shown(ui)).toMatch(/^This account is low\. Work has room/)
  await ui.unmount()
})

test('an email that is not a plain address is never handed to claude auth login', { ...withKit, ...ROUTE }, async ($, on) => {
  const work = await accountKey('acct-work', 'org-1')
  const other = JSON.parse(await otherMac()) as { accounts: Record<string, { email: string }> }
  ;(other.accounts[work] as { email: string }).email = '--console'
  const { clock, runs, toasts } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: JSON.stringify(other) } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  await clock.settle()
  expect(toasts).toEqual(['Switch did not run: the email recorded for Work, "--console", is not an address its sign in page could be filled in with.'])
  expect(runs.some(r => r[0] === '/bin/sh' || r[0] === 'claude')).toBe(false)
  await ui.unmount()
})

test('a failed Switch does not outlive the low spell: when the account runs low again the card offers Switch afresh', withKit, async ($, on) => {
  const { clock } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  await clock.advance(1)
  expect(await shown(ui)).toMatch(/^claude\.ai didn't confirm/)
  await measure($, clock, limits(5, 50))
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).toMatch(/^This account is low\. Work has room/)
  await ui.unmount()
})

test('a Switch that fails part way says so in a toast, never as a silent stuck card (L73)', { ...withKit, ...ROUTE }, async ($, on) => {
  const { w, clock, toasts } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  // Once the sign out is confirmed, the sign in command cannot even be started. A disk going away
  // here no longer stops a Switch: the card names the folder it could not read (review of #670).
  w.authLoginThrows = true
  await clock.advance(1)
  expect(toasts.some(t => /^Switch did not finish: \S/.test(t))).toBe(true)
  await ui.unmount()
})

test('a sign in that does not finish says why, and the card comes back', { ...withKit, ...ROUTE }, async ($, on) => {
  const { clock, toasts } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() }, authLogin: { exitCode: 1, stdout: '', stderr: 'Login cancelled' } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  await clock.settle()
  expect(toasts).toEqual(['Switch did not finish: Login cancelled'])
  expect(await shown(ui)).toMatch(/^This account is low\. Work has room/)
  await ui.unmount()
})

test('the first session on an account the mod has not seen asks once for a nickname, and Save keeps it', withKit, async ($, on) => {
  const { w, clock, opened, closed } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') } })
  await start($, clock)
  expect(opened).toEqual([PANE])
  const ui = (await $.ui.mount(pane)) as Ui
  expect(await shown(ui)).toContain('What should this account be called?')
  expect(await shown(ui)).toContain('work@example.com, Acme')
  expect((await ui.find({ type: 'Text', text: 'work@example.com, Acme' }))?.props).toMatchObject({ dimColor: true })
  await ui.input({ key: 'nickname', text: 'Work', kind: 'change' })
  await ui.press({ key: 'save' })
  const names = JSON.parse(w.files[NICKNAMES] as string) as { names: Record<string, string | null> }
  expect(names.names[await accountKey('acct-work', 'org-1')]).toBe('Work')
  // Only the hashed key is written to the shared (public) payload, never the email.
  expect(w.files[NICKNAMES]).not.toContain('work@example.com')
  expect(closed).toEqual([PANE])
  await ui.unmount()
})

test('in a window too narrow to show the nickname question, the transcript says how to answer it now (live check, 2026-10-05)', withKit, async ($, on) => {
  const { clock, transcript, opened } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') }, openWaits: true })
  await start($, clock)
  // The question still waits, so widening the window shows it; nothing is said only to the debug log.
  expect(opened).toEqual([PANE])
  const said = transcript.filter(t => /^Account room: /.test(t))
  expect(said).toHaveLength(1)
  expect(said[0]).toContain('work@example.com')
  expect(said[0]).toContain('/accounts rename')
  expect(said[0]).toContain('144 columns')
})

test('Enter in the field saves too; an empty name saves nothing and the dialog stays', withKit, async ($, on) => {
  const { w, clock, closed } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') } })
  await start($, clock)
  const ui = (await $.ui.mount(pane)) as Ui
  await ui.input({ key: 'nickname', text: '   ', kind: 'submit' })
  expect(w.files[NICKNAMES]).toBeUndefined()
  expect(closed).toEqual([])
  await ui.input({ key: 'nickname', text: ' Work ', kind: 'submit' })
  expect(JSON.parse(w.files[NICKNAMES] as string).names[await accountKey('acct-work', 'org-1')]).toBe('Work')
  await ui.unmount()
})

test('Skip records that the ask was answered, so it is not asked again', withKit, async ($, on) => {
  const { w, clock } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') } })
  await start($, clock)
  const ui = (await $.ui.mount(pane)) as Ui
  await ui.press({ key: 'skip' })
  expect(JSON.parse(w.files[NICKNAMES] as string).names).toEqual({ [await accountKey('acct-work', 'org-1')]: null })
  await ui.unmount()
})

test('an account already named, or already skipped, is not asked about; a session with no screen never asks', withKit, async ($, on) => {
  const { clock, opened } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: await named({ 'acct-work': null }) } })
  await start($, clock)
  expect(opened).toEqual([])
})

test('a session with no screen records readings but never asks or draws', withKit, async ($, on) => {
  const { w, clock, opened } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [OTHER]: await otherMac() } })
  await start($, clock, false)
  await measure($, clock, limits(97, 50))
  expect(opened).toEqual([])
  expect(JSON.parse(w.files[OWN] as string).accounts[await accountKey('acct-work', 'org-1')].reading.five.used).toBe(97)
})

test('/accounts rename opens the dialog for this account, or for the one named, and Save renames it', withKit, async ($, on) => {
  const { w, clock, opened } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  type Cmd = { command: { run: (e: never) => Promise<{ text?: string }> } }
  await ($ as unknown as Cmd).command.run({ command: 'accounts', args: 'rename' } as never)
  expect(opened).toEqual([PANE])
  let ui = (await $.ui.mount(pane)) as Ui
  expect(await shown(ui)).toContain('home@example.com, Acme')
  await ui.input({ key: 'nickname', text: 'Personal', kind: 'submit' })
  await ui.unmount()
  expect(JSON.parse(w.files[NICKNAMES] as string).names[await accountKey('acct-home', 'org-1')]).toBe('Personal')
  await ($ as unknown as Cmd).command.run({ command: 'accounts', args: 'rename work' } as never)
  ui = (await $.ui.mount(pane)) as Ui
  expect(await shown(ui)).toContain('work@example.com, Acme')
  await ui.input({ key: 'nickname', text: 'Job', kind: 'submit' })
  await ui.unmount()
  const names = JSON.parse(w.files[NICKNAMES] as string).names
  expect(names[await accountKey('acct-work', 'org-1')]).toBe('Job')
  expect(names[await accountKey('acct-home', 'org-1')]).toBe('Personal')
  // A name that matches no account says so, and opens nothing.
  const out = await ($ as unknown as Cmd).command.run({ command: 'accounts', args: 'rename nobody' } as never)
  expect(out.text).toBe('No account is called "nobody". Name one by its nickname or email.')
})

test('a nicknames file that cannot be read is named, and is never overwritten by a save', withKit, async ($, on) => {
  const { w, clock, logs, opened } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: '{"v":1,"names":{"x":' } })
  await start($, clock)
  // Unreadable is not the same as never seen: no ask, which would overwrite the file on Save.
  expect(opened).toEqual([])
  expect(logs.some(l => /nicknames could not be read/.test(l))).toBe(true)
  expect(w.files[NICKNAMES]).toBe('{"v":1,"names":{"x":')
})

test('a lock left by a session that died is moved aside, never deleted from under another session', withKit, async ($, on) => {
  const { w, clock, runs } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: await named({ 'acct-work': 'Work' }) }, staleLockMs: 60_000 })
  await start($, clock)
  await measure($, clock, limits(10, 10))
  const takeover = runs.find(r => r[0] === 'mv' && String(r[r.length - 2]).endsWith('write.lock'))
  expect(takeover?.[takeover.length - 1]).toMatch(/write\.lock\.stale\./)
  expect(runs.some(r => r[0] === 'rmdir' && String(r[r.length - 1]).endsWith('write.lock') && runs.indexOf(r) < runs.indexOf(takeover as string[]))).toBe(false)
  expect(JSON.parse(w.files[OWN] as string).accounts[await accountKey('acct-work', 'org-1')].reading.five.used).toBe(10)
  // The moved aside lock still holds the dead session's token, so it is removed whole.
  expect(runs.some(r => r[0] === 'rm' && r[1] === '-rf' && r[2] === takeover?.[takeover.length - 1])).toBe(true)
})

test('a session releases only a lock it still owns: its own token is removed first, then the lock', withKit, async ($, on) => {
  const { clock, runs } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: await named({ 'acct-work': 'Work' }) } })
  await start($, clock)
  const rm = runs.findIndex(r => r[0] === 'rm' && /write\.lock\/[0-9a-f-]+$/.test(String(r[r.length - 1])))
  const rmdir = runs.findIndex(r => r[0] === 'rmdir' && String(r[r.length - 1]).endsWith('write.lock'))
  expect(rm).toBeGreaterThan(-1)
  expect(rmdir).toBeGreaterThan(rm)
})

test('files are written whole from a temp file kept in the per Mac state folder, never in a synced or iCloud folder', withKit, async ($, on) => {
  const { clock, runs } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') } })
  await start($, clock)
  const pane = runs.filter(r => r[0] === 'mv' && !String(r[r.length - 2]).endsWith('write.lock'))
  expect(pane.length).toBeGreaterThan(0)
  for (const r of pane) expect(String(r[r.length - 2]).startsWith(`${HOME}/.claude/state/account-room/`)).toBe(true)
})

test('a lock whose token cannot be written is let go at once, not held until it goes stale', withKit, async ($, on) => {
  const { clock, runs, logs } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: await named({ 'acct-work': 'Work' }) }, tokenWriteFails: true })
  await start($, clock)
  expect(runs.some(r => r[0] === 'rmdir' && String(r[r.length - 1]).endsWith('write.lock'))).toBe(true)
  expect(logs.some(l => /readings could not be saved/.test(l))).toBe(true)
})

test('a card the band refuses is said once, in the transcript, not only in the debug log (L551)', { plugins: [modKitToday] }, async ($, on) => {
  const { clock, transcript } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  await measure($, clock, limits(96, 50))
  await measure($, clock, limits(97, 50))
  const refused = transcript.filter(l => /the band refused the card, so it is not shown: a band row's slot "room"/.test(l))
  expect(refused).toHaveLength(1)
})

test('a failure in the work deferred past session start is said in the transcript, never dropped (L73)', withKit, async ($, on) => {
  const { clock, transcript } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') }, openFails: true })
  await start($, clock)
  expect(transcript.filter(l => /this session's account could not be set up: \S/.test(l))).toHaveLength(1)
})

test('when whether the file is evicted cannot be told, nothing is written over it', withKit, async ($, on) => {
  const { w, clock, logs } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: await named({ 'acct-work': 'Work' }), [OWN]: JSON.stringify({ v: 1, mac: 'Daniels-MacBook-Pro-2', accounts: {} }) } })
  await start($, clock)
  const before = w.files[OWN]
  w.existsFails = true
  await measure($, clock, limits(10, 10))
  expect(w.files[OWN]).toBe(before)
  expect(logs.some(l => /could not tell whether this Mac's readings file is downloaded/.test(l))).toBe(true)
})

test('a readings file that cannot be written is said once, not on every reading', withKit, async ($, on) => {
  const { clock, logs } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: await named({ 'acct-work': 'Work' }) }, writeFails: true })
  await start($, clock)
  await measure($, clock, limits(10, 10))
  await measure($, clock, limits(20, 10))
  expect(logs.filter(l => /readings could not be saved/.test(l))).toHaveLength(1)
})

test('with no Claude login (an API key session) the mod does nothing and says why in the debug log', withKit, async ($, on) => {
  const { w, clock, logs, opened } = world(on, { files: { [LOGIN]: JSON.stringify({}) } })
  await start($, clock)
  await measure($, clock, limits(99, 99))
  expect(opened).toEqual([])
  expect(w.files[OWN]).toBeUndefined()
  expect(logs.some(l => /no Claude account/.test(l))).toBe(true)
})
