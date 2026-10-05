import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { accountKey, parseNicknames } from '../hooks/store.ts'

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
// The readings repository the tests name. The world below answers GitHub for this one name only,
// and a test runs with no network or process of its own, so nothing here can reach the real one (L2).
const REPO = 'test-owner/readings'
const REPO_OPTION = { readingsRepo: REPO }
const withKit = { plugins: [modKit], options: REPO_OPTION }
// The manifest's defaults carry the proven Chrome route (#659), so a test of Switch with no route
// set up empties both commands itself, as somebody blanking the settings would.
const NO_ROUTE = { plugins: [modKit], options: { ...REPO_OPTION, logoutCommand: '', signedOutCheck: '' } }

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
// Files in the readings repository are kept beside the Mac's own files under this prefix, which no
// path on disk starts with, and are served only through the GitHub fake.
const GH = 'github:'
const OWN = `${GH}readings/Daniels-MacBook-Pro-2.json`
const OTHER = `${GH}readings/Dans-MacBook-Pro.json`
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
  /** GitHub cannot be reached: gh says it could not connect. */
  ghDown: boolean
  /** gh has no login on this Mac. */
  ghLoggedOut: boolean
  /** gh is not installed, or not on the path Claude Code runs with. */
  ghMissing: boolean
  /** gh's account cannot see the repository, so GitHub answers 404 for all of it. */
  ghNoAccess: boolean
  /** The account gh is logged in to. */
  ghLogin: string
  /** How many writes GitHub refuses next as stale, each as though another session had just written. */
  ghRefuse: number
  /** How long GitHub takes to answer, on the test clock. */
  ghDelayMs: number
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
  /** The reason Claude Code gives for a waiting pane. */
  openReason: string
  /** `claude auth login` cannot even be started. */
  authLoginThrows: boolean
  /** The signed out check cannot even be started. */
  checkThrows: boolean
  /** The time limit the signed out check was last run with. */
  checkTimeoutMs: number | undefined
  /** Reading this session's live reading back from the session's state fails. */
  liveReadFails: boolean
  /** The phase a reload left stored, answered to the next read of it. */
  phaseAfterReload?: unknown
  /** The session as an earlier build stored it, answered to every read of it from then on. */
  sessionStored?: unknown
  /** How long a read of the live reading takes to answer, on the test clock. */
  liveReadDelayMs?: number
}
const ok = (stdout = ''): Run => ({ exitCode: 0, stdout, stderr: '' })

// This Mac beneath the account room: files in memory, the host commands it runs, the clock, the
// session's rate limits, and Claude Code's own band beneath mod-kit's.
const world = (on: On, init: Partial<World> = {}) => {
  const w: World = { files: {}, usage: [], logout: ok(), check: ok('signed out\n'), authLogin: ok(), logoutGate: undefined, ghDown: false, ghLoggedOut: false, ghMissing: false, ghNoAccess: false, ghLogin: 'danwright32', ghRefuse: 0, ghDelayMs: 0, staleLockMs: 0, usageFails: false, tokenWriteFails: false, openFails: false, openWaits: false, authLoginThrows: false, checkThrows: false, checkTimeoutMs: undefined, liveReadFails: false, openReason: 'the terminal is 120 columns wide; a pane opened unasked needs 144', ...init }
  // Every gh command the mod ran, and each write it asked GitHub for with the sha it gave.
  const gh: string[][] = []
  const puts: { path: string; sha?: string }[] = []
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
    if (w.tokenWriteFails && /write\.lock\//.test(e.path)) throw new Error('ENOSPC: no space left on device')
    w.files[e.path] = e.text
    return { value: undefined }
  })
  on('fs.exists', ($, e) => ({ value: e.path in w.files || Object.keys(w.files).some(f => f.startsWith(`${e.path}/`)) }) as never)
  on('fs.list', ($, e) => {
    const names = Object.keys(w.files)
      .filter(f => f.startsWith(`${e.path}/`) && !f.slice(e.path.length + 1).includes('/'))
      .map(f => f.slice(e.path.length + 1))
    if (!names.length) throw missing(e.path)
    return { value: names.map(name => ({ name, kind: 'file' as const, size: 1, mtimeMs: T0, isLink: false })) } as never
  })
  let lockHeld = w.staleLockMs > 0
  let lockTouched = T0 - w.staleLockMs
  // Another session takes the lock now and keeps it, as one writing behind a slow disk would.
  const holdLock = () => {
    lockHeld = true
    lockTouched = clock.now()
  }
  on('fs.stat', () => ({ value: { kind: 'dir', size: 0, mtimeMs: lockTouched } }) as never)
  on('state.get', async ($, e, next) => {
    const at = e as unknown as { plugin?: string; key?: string }
    // The session's state answering a moment late, as it can in a busy session: the value is read,
    // then arrives later, so two pieces of work reading the live reading at once both see it as it
    // was before either wrote.
    if (w.liveReadDelayMs && at.plugin === 'account-room' && at.key === 'live') {
      const read = await next(e)
      await clock.sleep(w.liveReadDelayMs)
      return read
    }
    // The session's state answers nothing usable for the live reading.
    if (w.liveReadFails && at.plugin === 'account-room' && at.key === 'live') return { value: undefined } as never
    if (w.sessionStored && at.plugin === 'account-room' && at.key === 'session') return { value: { value: w.sessionStored, version: 1 } } as never
    // What a reload of the mod leaves: the next read of the stored phase answers this, though
    // nothing in the module instance now loaded is running a Switch.
    if (w.phaseAfterReload && at.plugin === 'account-room' && at.key === 'phase') {
      const value = w.phaseAfterReload
      w.phaseAfterReload = undefined
      return { value: { value, version: 1 } } as never
    }
    return next(e)
  })
  // GitHub's contents API as `gh api` answers it, shaped on the real answers measured against the
  // readings repository on 2026-10-05 (L52): the body on stdout and "gh: <message> (HTTP <code>)" on
  // stderr with exit 1 for a refusal, 422 for a write with no sha over a file that exists, 409 for a
  // stale sha, "This repository is empty." for a repository with no commit, and exit 4 with no login.
  let shaSeq = 0
  const shas: Record<string, string> = {}
  const shaOf = (p: string) => (shas[p] ??= `sha${++shaSeq}`)
  const refused = (status: number, text: string): Run => ({ exitCode: 1, stdout: JSON.stringify({ message: text, status: String(status) }), stderr: `gh: ${text} (HTTP ${status})\n` })
  const b64 = (s: string) => {
    let bin = ''
    for (const b of new TextEncoder().encode(s)) bin += String.fromCharCode(b)
    // GitHub wraps the content at 60 characters a line.
    return `${btoa(bin).replace(/.{60}/g, '$&\n')}\n`
  }
  const unb64 = (s: string) => new TextDecoder().decode(Uint8Array.from(atob(s.replace(/\s/g, '')), c => c.charCodeAt(0)))
  const github = async (args: string[], stdin: string | undefined): Promise<Run> => {
    gh.push(['gh', ...args])
    if (w.ghMissing) throw new Error('spawn gh ENOENT')
    if (w.ghDelayMs) await clock.sleep(w.ghDelayMs)
    if (w.ghLoggedOut) return { exitCode: 4, stdout: '', stderr: 'To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n' }
    if (w.ghDown) return { exitCode: 1, stdout: '', stderr: 'error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com\n' }
    if (args[0] !== 'api') return { exitCode: 1, stdout: '', stderr: 'unexpected' }
    const method = args[1] === '-X' ? String(args[2]) : 'GET'
    const path = String(args[1] === '-X' ? args[3] : args[1])
    if (path === 'user') return ok(JSON.stringify({ login: w.ghLogin }))
    const base = `repos/${REPO}`
    if (w.ghNoAccess || (path !== base && !path.startsWith(`${base}/`))) return refused(404, 'Not Found')
    if (path === base) return ok(JSON.stringify({ full_name: REPO, private: true }))
    if (!path.startsWith(`${base}/contents/`)) return refused(404, 'Not Found')
    const p = decodeURIComponent(path.slice(`${base}/contents/`.length))
    const key = `${GH}${p}`
    const held = Object.keys(w.files).filter(f => f.startsWith(GH))
    if (method === 'GET') {
      if (key in w.files) return ok(JSON.stringify({ type: 'file', name: p.split('/').pop(), path: p, encoding: 'base64', content: b64(w.files[key] as string), sha: shaOf(p) }))
      const kids = held.filter(f => f.startsWith(`${key}/`) && !f.slice(key.length + 1).includes('/'))
      if (kids.length) return ok(JSON.stringify(kids.map(f => ({ type: 'file', name: f.slice(key.length + 1), path: f.slice(GH.length), sha: shaOf(f.slice(GH.length)) }))))
      return refused(404, held.length ? 'Not Found' : 'This repository is empty.')
    }
    if (method === 'PUT') {
      const body = JSON.parse(stdin ?? '{}') as { content?: string; sha?: string }
      puts.push({ path: p, ...(body.sha ? { sha: body.sha } : {}) })
      if (w.ghRefuse > 0) {
        w.ghRefuse--
        // Another session wrote first: the file moves on, and this write's sha is stale.
        if (key in w.files) shas[p] = `sha${++shaSeq}`
        return refused(409, `${p} does not match ${body.sha ?? ''}`)
      }
      if (key in w.files && !body.sha) return refused(422, 'Invalid request.\n\n"sha" wasn\'t supplied.')
      if (key in w.files && body.sha !== shaOf(p)) return refused(409, `${p} does not match ${body.sha}`)
      w.files[key] = unb64(String(body.content))
      shas[p] = `sha${++shaSeq}`
      return ok(JSON.stringify({ content: { path: p, sha: shas[p] } }))
    }
    return { exitCode: 1, stdout: '', stderr: 'unexpected' }
  }
  on('process.run', async ($, e) => {
    runs.push([...e.argv])
    if (e.argv[0] === 'gh') {
      const g = await github(e.argv.slice(1), e.init?.stdin)
      return { value: { ...g, isStdoutTruncated: false, isStderrTruncated: false } }
    }
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
    if (cmd === '/bin/sh' && rest[1] === 'CHECK') {
      w.checkTimeoutMs = e.init?.timeoutMs
      if (w.checkThrows) throw new Error('spawn /bin/sh EAGAIN')
      return r(w.check)
    }
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
    if (w.openWaits) return { value: { isPlaced: false, reason: w.openReason } } as never
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
  return { w, toasts, logs, transcript, runs, opened, closed, clock, holdLock, gh, puts }
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
  const { w, clock, transcript, puts } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }), [OWN]: 'garbage' } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).toContain("Daniels-MacBook-Pro-2's readings are unavailable: not readable JSON")
  expect(w.files[OWN]).toBe('garbage')
  expect(puts).toEqual([])
  expect(transcript.filter(l => /this Mac's readings file on GitHub could not be read \(not readable JSON/.test(l))).toHaveLength(1)
  await ui.unmount()
})

test('GitHub that cannot be reached is named on the card for every other Mac, never read as no readings, and the measurement still goes on (#750, L215)', withKit, async ($, on) => {
  const { clock, w } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  w.ghDown = true
  await expect($.session.measure({ context: { window: 200_000 }, rateLimits: limits(96, 50), changed: ['rateLimits'] } as never)).resolves.toBeDefined()
  await clock.settle()
  const card = await shown(ui)
  expect(card).toMatch(/^This account is low\. No other account has room/)
  expect(card).toContain("The other Macs' readings are unavailable: gh api failed: error connecting to api.github.com")
  expect(card).toContain("Daniels-MacBook-Pro-2's readings could not be saved to GitHub: gh api failed: error connecting to api.github.com")
  await ui.unmount()
})

test('gh with no login, or logged in to an account that cannot see the repository, is said on the card exactly (#750)', withKit, async ($, on) => {
  const { clock, w } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) }, ghLoggedOut: true })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).toContain("The other Macs' readings are unavailable: gh is not logged in to GitHub (gh auth login)")
  expect(await shown(ui)).toContain("Daniels-MacBook-Pro-2's readings could not be saved to GitHub: gh is not logged in to GitHub (gh auth login)")
  await ui.unmount()
})

test('an account gh uses that cannot see the repository is named, with the repository, on the card (#750)', withKit, async ($, on) => {
  const { clock } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) }, ghNoAccess: true, ghLogin: 'dwright-pennie' })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).toContain(`The other Macs' readings are unavailable: ${REPO} was not found, or gh's account dwright-pennie cannot see it`)
  expect(await shown(ui)).toContain(`Daniels-MacBook-Pro-2's readings could not be saved to GitHub: ${REPO} was not found, or gh's account dwright-pennie cannot see it`)
  await ui.unmount()
})

test('gh that cannot be run at all is said on the card, never as no readings (#750)', withKit, async ($, on) => {
  const { clock } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) }, ghMissing: true })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(96, 50))
  // The run's own failure follows; a hook of the test that throws reaches the mod as a call nothing
  // answered, so the exact words are the kit's.
  expect(await shown(ui)).toMatch(/The other Macs' readings are unavailable: gh could not be run: \S/)
  await ui.unmount()
})

test('a readings repository setting that is not owner/name is said on the card, and gh is never run with it (#750)', { plugins: [modKit], options: { readingsRepo: '../user' } }, async ($, on) => {
  const { clock, gh } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).toContain(`The other Macs' readings are unavailable: the readingsRepo setting "../user" is not a repository's owner/name`)
  expect(await shown(ui)).toContain(`Daniels-MacBook-Pro-2's readings could not be saved to GitHub: the readingsRepo setting "../user" is not a repository's owner/name`)
  expect(gh).toEqual([])
  await ui.unmount()
})

test('an empty repository is no readings yet, not a fault: nothing is named unavailable, and the first write creates this Mac file (#750)', withKit, async ($, on) => {
  const { clock, w, puts } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).toBe("This account is low. No other account has room  This account's 5h resets first, at 11 AM")
  expect(puts[0]).toEqual({ path: 'readings/Daniels-MacBook-Pro-2.json' })
  expect(JSON.parse(w.files[OWN] as string).mac).toBe('Daniels-MacBook-Pro-2')
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

test('Switch shows its progress with elapsed seconds, and with no logout route set up it stops red, opening no sign in page', NO_ROUTE, async ($, on) => {
  const { clock, runs } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  expect(await shown(ui)).toMatch(/^Switching to Work: signing claude\.ai out in the browser… 0s/)
  expect(await ui.find({ type: 'Button', key: 'account-room:switch' })).toBeUndefined()
  await clock.advance(1)
  // Nothing was attempted, so the card says that, never that claude.ai was asked (#736).
  expect(await shown(ui)).toMatch(/^No sign out was attempted: no browser logout route is set up\. Nothing was changed\./)
  expect((await ui.find({ type: 'Text', text: 'No sign out was attempted: no browser logout route is set up. Nothing was changed.' }))?.props).toMatchObject({ color: 'error' })
  expect((await ui.find({ type: 'Button', key: 'account-room:retry' }))?.props).toMatchObject({ label: 'Try again' })
  expect(runs.some(r => r[0] === 'claude')).toBe(false)
  await ui.unmount()
})

const ROUTE = { options: { ...REPO_OPTION, logoutCommand: 'LOGOUT', signedOutCheck: 'CHECK' } }

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

test("Switch's elapsed seconds keep counting while a reading waits on a slow GitHub (#750)", { ...withKit, ...ROUTE }, async ($, on) => {
  let release: () => void = () => undefined
  const logoutGate = new Promise<void>(r => (release = r))
  const { clock, w, runs } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() }, logoutGate })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  // A new figure arrives and its write waits 30 seconds on GitHub.
  w.ghDelayMs = 30_000
  await measure($, clock, limits(98, 50))
  await clock.advance(3_000)
  expect(await shown(ui)).toMatch(/^Switching to Work: signing claude\.ai out in the browser… 3s/)
  release()
  await clock.advance(30_000)
  // The sign in step ran, and the slow write landed after it, with the newer figure.
  expect(runs.find(r => r[0] === 'claude')).toEqual(['claude', 'auth', 'login', '--email=work@example.com'])
  expect(JSON.parse(w.files[OWN] as string).accounts[await accountKey('acct-home', 'org-1')].reading.five.used).toBe(98)
  await ui.unmount()
})

test("Switch's elapsed seconds keep counting while the other Macs are read from a slow GitHub (second review of #757)", { ...withKit, ...ROUTE }, async ($, on) => {
  let release: () => void = () => undefined
  const logoutGate = new Promise<void>(r => (release = r))
  const { clock, w } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() }, logoutGate })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  // Past the minute a good read is kept, the same figures arrive: nothing to write, but the other
  // Macs are read again, and GitHub takes 30 seconds to answer.
  await clock.advance(61_000)
  w.ghDelayMs = 30_000
  await measure($, clock, limits(97, 50))
  await clock.advance(3_000)
  expect(await shown(ui)).toMatch(/^Switching to Work: signing claude\.ai out in the browser… 64s/)
  release()
  w.ghDelayMs = 0
  await clock.advance(30_000)
  await ui.unmount()
})

test('two measurements arriving together each keep their own window in the live reading (second review of #757, L443)', withKit, async ($, on) => {
  const { clock, w } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  w.liveReadDelayMs = 10
  // One response reports only the 5 hour window, at 96%; the next only the weekly one, at 50%.
  const five = limits(96, 50).filter(l => l.kind === 'five_hour')
  const week = limits(96, 50).filter(l => l.kind === 'seven_day')
  void $.session.measure({ context: { window: 200_000 }, rateLimits: five, changed: ['rateLimits'] } as never)
  void $.session.measure({ context: { window: 200_000 }, rateLimits: week, changed: ['rateLimits'] } as never)
  await clock.advance(1_000)
  // Both windows are kept, so the 5 hour figure still triggers the card.
  expect(await shown(ui)).toMatch(/^This account is low\. Work has room/)
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
  // The command failed before any check ran, so that is what the card says (#736).
  expect(await shown(ui)).toMatch(/^The browser logout command failed\. Nothing else was changed\./)
  expect(runs.some(r => r[0] === 'claude')).toBe(false)
  // A check that cannot even be started is not a page that declined to confirm.
  w.logout = ok()
  w.checkThrows = true
  await ui.press({ key: 'account-room:retry', plugin: 'mod-kit' })
  await clock.settle()
  expect(await shown(ui)).toMatch(/^The signed out check could not be run\. Nothing else was changed\./)
  expect(runs.some(r => r[0] === 'claude')).toBe(false)
  w.checkThrows = false
  // Try again with a working route goes on to the sign in page.
  w.logout = ok()
  await ui.press({ key: 'account-room:retry', plugin: 'mod-kit' })
  await clock.settle()
  expect(runs.filter(r => r[0] === 'claude')).toHaveLength(1)
  await ui.unmount()
})

test("the signed out check gets a minute, because Chrome saves a cookie's removal to disk late (#659)", { ...withKit, ...ROUTE }, async ($, on) => {
  // Proven on 2026-10-05: claude.ai's session cookie left Chrome's cookie file 31 seconds after
  // the logout, and Chrome writes cookie changes about every 30 seconds, so 30 was too short.
  const { w, clock, runs } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  await clock.settle()
  expect(runs.filter(r => r[0] === 'claude')).toHaveLength(1)
  expect(w.checkTimeoutMs).toBe(60_000)
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

test('a Switch stopped at the sign out says why in a toast, so Try again is not the only diagnosis (L148)', NO_ROUTE, async ($, on) => {
  const { clock, toasts } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  await clock.advance(1)
  expect(toasts).toEqual(['Switch stopped: no browser logout route is set up'])
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

test('a failed Switch does not outlive the low spell: when the account runs low again the card offers Switch afresh', NO_ROUTE, async ($, on) => {
  const { clock } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  await ui.press({ key: 'account-room:switch', plugin: 'mod-kit' })
  await clock.advance(1)
  expect(await shown(ui)).toMatch(/^No sign out was attempted/)
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
  const names = JSON.parse(w.files[NICKNAMES] as string) as { v: number; names: Record<string, { name: string | null; at: number }> }
  expect(names.v).toBe(2)
  expect(names.names[await accountKey('acct-work', 'org-1')]).toEqual({ name: 'Work', at: T0 })
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
  // Claude Code's own reason, as it gave it, and that the account has no nickname, which is known.
  expect(said[0]).toContain('the terminal is 120 columns wide; a pane opened unasked needs 144')
  expect(said[0]).toContain('has no nickname yet')
})

test('Enter in the field saves too; an empty name saves nothing and the dialog stays', withKit, async ($, on) => {
  const { w, clock, closed } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') } })
  await start($, clock)
  const ui = (await $.ui.mount(pane)) as Ui
  await ui.input({ key: 'nickname', text: '   ', kind: 'submit' })
  expect(w.files[NICKNAMES]).toBeUndefined()
  expect(closed).toEqual([])
  await ui.input({ key: 'nickname', text: ' Work ', kind: 'submit' })
  expect(JSON.parse(w.files[NICKNAMES] as string).names[await accountKey('acct-work', 'org-1')].name).toBe('Work')
  await ui.unmount()
})

test('Skip records that the ask was answered, so it is not asked again', withKit, async ($, on) => {
  const { w, clock } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') } })
  await start($, clock)
  const ui = (await $.ui.mount(pane)) as Ui
  await ui.press({ key: 'skip' })
  expect(JSON.parse(w.files[NICKNAMES] as string).names).toEqual({ [await accountKey('acct-work', 'org-1')]: { name: null, at: T0 } })
  await ui.unmount()
})

const COPY = `${NICKNAMES}.conflict-Daniels-MacBook-Pro-2`
const STATE = `${HOME}/.claude/state/account-room`
// Read through the mod's own parser, which reads both versions of the file.
const nameIn = async (text: string | undefined, acct: string) => {
  const f = parseNicknames(text as string)
  if (typeof f === 'string') throw new Error(f)
  return f.names[await accountKey(acct, 'org-1')]?.name
}

test('a skip on one Mac never replaces a name given on the other: the copy the sync set aside is merged back (#747)', withKit, async ($, on) => {
  // What the live check of 2026-10-05 left: the sync applied the other Mac's skip and set this Mac's
  // name aside beside it as a conflict copy, both in the first build's format.
  const { w, clock, opened, transcript } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: await named({ 'acct-work': null }), [COPY]: await named({ 'acct-work': 'dwright (team)' }) } })
  await start($, clock)
  expect(await nameIn(w.files[NICKNAMES], 'acct-work')).toBe('dwright (team)')
  expect(opened).toEqual([])
  // The copy leaves the mirrored mods tree, kept whole in this Mac's own state folder (L5).
  expect(w.files[COPY]).toBeUndefined()
  const kept = Object.keys(w.files).filter(f => f.startsWith(`${STATE}/`) && f.includes('account-room-nicknames.json.conflict-Daniels-MacBook-Pro-2'))
  expect(kept).toHaveLength(1)
  expect(w.files[kept[0] as string]).toBe(await named({ 'acct-work': 'dwright (team)' }))
  expect(transcript.filter(t => /^Account room: merged the nicknames claude-sync set aside/.test(t))).toHaveLength(1)
})

test('the other way round: the name the sync applied stands, and the skip it set aside changes nothing (#747)', withKit, async ($, on) => {
  const work = await accountKey('acct-work', 'org-1')
  const main = `{\n  "v": 2,\n  "names": {\n    "${work}": {"name":"dwright (team)","at":${T0 - HOUR}}\n  }\n}\n`
  const { w, clock } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: main, [COPY]: JSON.stringify({ v: 2, names: { [work]: { name: null, at: T0 } } }) } })
  await start($, clock)
  expect(w.files[NICKNAMES]).toBe(main)
  expect(w.files[COPY]).toBeUndefined()
})

test('a Skip pressed after a name arrived from the other Mac keeps the name (#747)', withKit, async ($, on) => {
  const { w, clock } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') } })
  await start($, clock)
  const ui = (await $.ui.mount(pane)) as unknown as Ui
  // The sync delivers the other Mac's name while the question is open here.
  w.files[NICKNAMES] = await named({ 'acct-work': 'dwright (team)' })
  await ui.press({ key: 'skip' })
  expect(await nameIn(w.files[NICKNAMES], 'acct-work')).toBe('dwright (team)')
  await ui.unmount()
})

test('a conflict copy that cannot be read is named and left where it is, and nothing is merged from it (#747)', withKit, async ($, on) => {
  const { w, clock, transcript } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: await named({ 'acct-work': null }), [COPY]: '{"v":1,"na' } })
  await start($, clock)
  expect(w.files[COPY]).toBe('{"v":1,"na')
  expect(w.files[NICKNAMES]).toBe(await named({ 'acct-work': null }))
  expect(transcript.filter(t => /account-room-nicknames\.json\.conflict-Daniels-MacBook-Pro-2 could not be read: not readable JSON/.test(t))).toHaveLength(1)
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
  expect(JSON.parse(w.files[NICKNAMES] as string).names[await accountKey('acct-home', 'org-1')].name).toBe('Personal')
  await ($ as unknown as Cmd).command.run({ command: 'accounts', args: 'rename work' } as never)
  ui = (await $.ui.mount(pane)) as Ui
  expect(await shown(ui)).toContain('work@example.com, Acme')
  await ui.input({ key: 'nickname', text: 'Job', kind: 'submit' })
  await ui.unmount()
  const names = JSON.parse(w.files[NICKNAMES] as string).names
  expect(names[await accountKey('acct-work', 'org-1')].name).toBe('Job')
  expect(names[await accountKey('acct-home', 'org-1')].name).toBe('Personal')
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

// A nickname saved in the dialog: the write that holds this Mac's lock, now that readings are
// guarded by GitHub's own sha check rather than a lock held across the network (#750).
const saveNickname = async ($: { ui: { mount: (t: never) => Promise<unknown> } }, text: string) => {
  const ui = (await $.ui.mount(pane)) as unknown as Ui
  await ui.input({ key: 'nickname', text, kind: 'submit' })
  await ui.unmount()
}

test('a lock left by a session that died is moved aside, never deleted from under another session', withKit, async ($, on) => {
  const { w, clock, runs } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') }, staleLockMs: 60_000 })
  await start($, clock)
  await saveNickname($ as never, 'Work')
  const takeover = runs.find(r => r[0] === 'mv' && String(r[r.length - 2]).endsWith('write.lock'))
  expect(takeover?.[takeover.length - 1]).toMatch(/write\.lock\.stale\./)
  expect(runs.some(r => r[0] === 'rmdir' && String(r[r.length - 1]).endsWith('write.lock') && runs.indexOf(r) < runs.indexOf(takeover as string[]))).toBe(false)
  expect(await nameIn(w.files[NICKNAMES], 'acct-work')).toBe('Work')
  // The moved aside lock still holds the dead session's token, so it is removed whole.
  expect(runs.some(r => r[0] === 'rm' && r[1] === '-rf' && r[2] === takeover?.[takeover.length - 1])).toBe(true)
})

test('a session releases only a lock it still owns: its own token is removed first, then the lock', withKit, async ($, on) => {
  const { clock, runs } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') } })
  await start($, clock)
  await saveNickname($ as never, 'Work')
  const rm = runs.findIndex(r => r[0] === 'rm' && /write\.lock\/[0-9a-f-]+$/.test(String(r[r.length - 1])))
  const rmdir = runs.findIndex(r => r[0] === 'rmdir' && String(r[r.length - 1]).endsWith('write.lock'))
  expect(rm).toBeGreaterThan(-1)
  expect(rmdir).toBeGreaterThan(rm)
})

test('the nicknames are written whole from a temp file kept in the per Mac state folder, never in the synced mods folder', withKit, async ($, on) => {
  const { clock, runs } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') } })
  await start($, clock)
  await saveNickname($ as never, 'Work')
  const moves = runs.filter(r => r[0] === 'mv' && !String(r[r.length - 2]).endsWith('write.lock'))
  expect(moves.length).toBeGreaterThan(0)
  for (const r of moves) expect(String(r[r.length - 2]).startsWith(`${HOME}/.claude/state/account-room/`)).toBe(true)
})

test('a lock whose token cannot be written is let go at once, not held until it goes stale', withKit, async ($, on) => {
  const { clock, runs, toasts } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com') }, tokenWriteFails: true })
  await start($, clock)
  await saveNickname($ as never, 'Work')
  expect(runs.some(r => r[0] === 'rmdir' && String(r[r.length - 1]).endsWith('write.lock'))).toBe(true)
  expect(toasts.some(t => /^The nickname could not be saved: \S/.test(t))).toBe(true)
})

test('a card the band refuses is said once, in the transcript, not only in the debug log (L551)', { plugins: [modKitToday], options: REPO_OPTION }, async ($, on) => {
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

test("when this Mac's file cannot be read from GitHub, nothing is written over it (L105)", withKit, async ($, on) => {
  const { w, clock, puts } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: await named({ 'acct-work': 'Work' }), [OWN]: JSON.stringify({ v: 1, mac: 'Daniels-MacBook-Pro-2', accounts: {} }) } })
  w.ghDown = true
  await start($, clock)
  await measure($, clock, limits(10, 10))
  expect(puts).toEqual([])
  expect(w.files[OWN]).toBe(JSON.stringify({ v: 1, mac: 'Daniels-MacBook-Pro-2', accounts: {} }))
})

test('readings that cannot be saved are said once in the transcript, not on every reading', withKit, async ($, on) => {
  const { clock, transcript } = world(on, { files: { [LOGIN]: login('acct-work', 'work@example.com'), [NICKNAMES]: await named({ 'acct-work': 'Work' }) }, ghDown: true })
  await start($, clock)
  await measure($, clock, limits(10, 10))
  await measure($, clock, limits(20, 10))
  expect(transcript.filter(l => l.startsWith(`Account room: readings could not be saved to GitHub (${REPO}): gh api failed: error connecting to api.github.com`))).toHaveLength(1)
})

const owned = async (w: World) => (JSON.parse(w.files[OWN] as string) as { accounts: Record<string, { reading?: { takenAt: number; five?: { used: number; takenAt?: number } } }> }).accounts[await accountKey('acct-home', 'org-1')]
const readingsPuts = (puts: { path: string }[]) => puts.filter(p => p.path === 'readings/Daniels-MacBook-Pro-2.json').length

test("repeated identical measurements write this Mac's file once, and make no GitHub call at all after it (#750)", withKit, async ($, on) => {
  const { clock, w, puts, gh } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  await measure($, clock, limits(40, 50))
  const writes = readingsPuts(puts)
  const calls = gh.length
  expect((await owned(w))?.reading?.five?.used).toBe(40)
  await clock.advance(MIN)
  await measure($, clock, limits(40, 50))
  await clock.advance(MIN)
  await measure($, clock, limits(40, 50))
  expect(readingsPuts(puts)).toBe(writes)
  expect(gh.length).toBe(calls)
})

test('a figure that moved is written, and one the card cannot show yet is not (#750)', withKit, async ($, on) => {
  const { clock, w, puts } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  await measure($, clock, limits(40, 50))
  const writes = readingsPuts(puts)
  // 60% left either way: the card reads the same, so nothing is sent.
  await measure($, clock, limits(40.3, 50))
  expect(readingsPuts(puts)).toBe(writes)
  await measure($, clock, limits(41, 50))
  expect(readingsPuts(puts)).toBe(writes + 1)
  expect((await owned(w))?.reading?.five?.used).toBe(41)
  // A reset that moved is a figure that moved.
  await measure($, clock, limits(41, 50, T0 + 5 * HOUR))
  expect(readingsPuts(puts)).toBe(writes + 2)
})

test('a quiet stretch past 10 minutes writes the newest reading, so the other Mac can tell this one is alive (#750)', withKit, async ($, on) => {
  const { clock, w, puts } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  await measure($, clock, limits(40, 50))
  const writes = readingsPuts(puts)
  await clock.advance(10 * MIN)
  await measure($, clock, limits(40, 50))
  expect(readingsPuts(puts)).toBe(writes)
  await clock.advance(1_000)
  await measure($, clock, limits(40, 50))
  expect(readingsPuts(puts)).toBe(writes + 1)
  expect((await owned(w))?.reading?.takenAt).toBe(T0 + 10 * MIN + 1_000)
})

test('a write GitHub refuses as stale is read again and merged, and never sent without the sha (#750)', withKit, async ($, on) => {
  const { clock, w, puts } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  await measure($, clock, limits(40, 50))
  const before = puts.length
  w.ghRefuse = 1
  await measure($, clock, limits(45, 50))
  const tries = puts.slice(before)
  expect(tries).toHaveLength(2)
  expect(tries.every(t => typeof t.sha === 'string')).toBe(true)
  expect(tries[0]?.sha).not.toBe(tries[1]?.sha)
  expect((await owned(w))?.reading?.five?.used).toBe(45)
})

test('a write refused every time is said on the card for this Mac and once in the transcript (#750, L215)', withKit, async ($, on) => {
  const { clock, w, transcript } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(40, 50))
  w.ghRefuse = 99
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).toContain("Daniels-MacBook-Pro-2's readings could not be saved to GitHub: GitHub refused the write 3 times as stale")
  expect(transcript.filter(t => /^Account room: readings could not be saved to GitHub/.test(t))).toHaveLength(1)
  // The next write that lands takes the line off the card.
  w.ghRefuse = 0
  await measure($, clock, limits(97, 50))
  expect(await shown(ui)).not.toContain('could not be saved to GitHub')
  await ui.unmount()
})

test("another Mac's readings come from the repository, and an org beyond ASCII survives the trip both ways (#750)", withKit, async ($, on) => {
  const work = await accountKey('acct-work', 'org-1')
  const other = JSON.parse(await otherMac()) as { accounts: Record<string, { org: string }> }
  ;(other.accounts[work] as { org: string }).org = 'Café 家'
  const cafe = JSON.stringify({ oauthAccount: { accountUuid: 'acct-home', organizationUuid: 'org-1', emailAddress: 'home@example.com', organizationName: 'Café 家' } })
  const { clock, w } = world(on, { files: { [LOGIN]: cafe, [NICKNAMES]: await named({ 'acct-home': 'Home' }), [OTHER]: JSON.stringify(other) } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  expect(await shown(ui)).toMatch(/^This account is low\. work@example\.com \(Café 家\) has room/)
  expect(JSON.parse(w.files[OWN] as string).accounts[await accountKey('acct-home', 'org-1')].org).toBe('Café 家')
  await ui.unmount()
})

test('a GitHub failure is not kept: once gh works again, the next measurement reads the other Macs (#750, review of #757)', withKit, async ($, on) => {
  const { clock, w } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() }, ghLoggedOut: true })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).toContain('gh is not logged in to GitHub')
  // Dan logs gh in; well inside the minute a good read is kept, the next measurement asks again.
  w.ghLoggedOut = false
  await measure($, clock, limits(97, 50))
  expect(await shown(ui)).toMatch(/^This account is low\. Work has room/)
  expect(await shown(ui)).not.toContain('gh is not logged in')
  await ui.unmount()
})

test('a save failure leaves the card once GitHub holds this Mac figures again, even with nothing new to write (#750)', withKit, async ($, on) => {
  const { clock, w } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(96, 50))
  w.ghRefuse = 99
  await measure($, clock, limits(97, 50))
  expect(await shown(ui)).toContain('could not be saved to GitHub')
  // GitHub takes writes again, and the figure is back to what it already holds: nothing to send,
  // and nothing unsaved either.
  w.ghRefuse = 0
  await measure($, clock, limits(96, 50))
  expect(await shown(ui)).not.toContain('could not be saved to GitHub')
  await ui.unmount()
})

test('a session stored by the build before #750, with an iCloud folder and no repository, still reads and writes the repository (review of #757, L1013)', withKit, async ($, on) => {
  const { clock, w } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  // What a hot reload can leave in the session's state: the earlier build's shape.
  const home = await accountKey('acct-home', 'org-1')
  w.sessionStored = { id: home, email: 'home@example.com', org: 'Acme', isInteractive: true, home: HOME, mac: 'Daniels-MacBook-Pro-2', folder: `${HOME}/Library/Mobile Documents/com~apple~CloudDocs/account-room` }
  await measure($, clock, limits(97, 50))
  expect(await shown(ui)).toMatch(/^This account is low\. Work has room/)
  expect(await shown(ui)).not.toContain('readingsRepo')
  expect(JSON.parse(w.files[OWN] as string).accounts[home].reading.five.used).toBe(97)
  await ui.unmount()
})

test('while the card shows, the other Macs are read from GitHub at most once a minute (#750)', withKit, async ($, on) => {
  const { clock, gh } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const listings = () => gh.filter(a => a[2] === `repos/${REPO}/contents/readings`).length
  await measure($, clock, limits(96, 50))
  await measure($, clock, limits(97, 50))
  await clock.advance(30_000)
  await measure($, clock, limits(98, 50))
  expect(listings()).toBe(1)
  await clock.advance(31_000)
  await measure($, clock, limits(99, 50))
  expect(listings()).toBe(2)
})

test('with no Claude login (an API key session) the mod does nothing and says why in the debug log', withKit, async ($, on) => {
  const { w, clock, logs, opened } = world(on, { files: { [LOGIN]: JSON.stringify({}) } })
  await start($, clock)
  await measure($, clock, limits(99, 99))
  expect(opened).toEqual([])
  expect(w.files[OWN]).toBeUndefined()
  expect(logs.some(l => /no Claude account/.test(l))).toBe(true)
})

test('a reload that cut Switch off mid sign out says so: nothing was checked (#736)', withKit, async ($, on) => {
  const { clock, w } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() } })
  await start($, clock)
  const ui = await mountBand($ as never)
  await measure($, clock, limits(97, 50))
  // What a reload leaves: the stored phase says the sign out step was under way, and nothing in this
  // module instance is running it.
  w.phaseAfterReload = { kind: 'working', step: 'logout', since: T0 }
  await measure($, clock, limits(98, 50))
  expect(w.phaseAfterReload).toBeUndefined()
  expect(await shown(ui)).toMatch(/^A reload cut Switch off before the sign out was confirmed\. Nothing else was changed\./)
  await ui.unmount()
})

test('a rate limit measurement is never held up by the reading work: a held lock or a slow GitHub delays nothing (#736)', withKit, async ($, on) => {
  const { clock, holdLock, w } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  // Another session holds the write lock and keeps it, and GitHub takes 20 seconds to answer.
  holdLock()
  w.ghDelayMs = 20_000
  let answered = false
  void $.session.measure({ context: { window: 200_000 }, rateLimits: limits(40, 50), changed: ['rateLimits'] } as never).then(() => (answered = true))
  await clock.settle()
  expect(answered).toBe(true)
})

test('reading work that fails after the measurement has gone on is said once, never dropped (#736, L73)', withKit, async ($, on) => {
  const { clock, transcript, w } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home' }) } })
  await start($, clock)
  w.liveReadFails = true
  await measure($, clock, limits(40, 50))
  await measure($, clock, limits(41, 50))
  expect(transcript.filter(t => /^Account room: a rate limit reading could not be taken in: \S/.test(t))).toHaveLength(1)
})

test('the waiting question line falls back on what is known: no reason, no email (#736)', withKit, async ($, on) => {
  const noEmail = JSON.stringify({ oauthAccount: { accountUuid: 'acct-work', organizationUuid: 'org-1', emailAddress: '', organizationName: 'Acme' } })
  const { clock, transcript } = world(on, { files: { [LOGIN]: noEmail }, openWaits: true, openReason: '' })
  await start($, clock)
  const said = transcript.filter(t => /^Account room: /.test(t))
  expect(said).toEqual(['Account room: the Acme account has no nickname yet, and the question is waiting to be shown (Claude Code has not placed it). Run /accounts rename to answer it now.'])
})

test('a waiting question is said once per account, so a later ask for another one is not silenced (#736)', withKit, async ($, on) => {
  const { clock, transcript } = world(on, { files: { [LOGIN]: login('acct-home', 'home@example.com'), [NICKNAMES]: await named({ 'acct-home': 'Home', 'acct-work': 'Work' }), [OTHER]: await otherMac() }, openWaits: true })
  await start($, clock)
  type Cmd = { command: { run: (e: never) => Promise<{ text?: string }> } }
  await ($ as unknown as Cmd).command.run({ command: 'accounts', args: 'rename' } as never)
  await ($ as unknown as Cmd).command.run({ command: 'accounts', args: 'rename work' } as never)
  await ($ as unknown as Cmd).command.run({ command: 'accounts', args: 'rename work' } as never)
  const said = transcript.filter(t => /^Account room: The nickname question for /.test(t))
  expect(said.map(t => /for (\S+)/.exec(t)?.[1])).toEqual(['home@example.com', 'work@example.com'])
})
