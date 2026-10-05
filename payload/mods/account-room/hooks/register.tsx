import { read } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { AccountRoomAsking, AccountRoomPhase, AccountRoomSession, AccountRoomStop } from '../types/index.d.ts'
import { card, fromRateLimits, nameOf, triggered, verdict } from './room.ts'
import type { Account, Offset, Reading, Unavailable, Verdict } from './room.ts'
import { accountKey, macsIn, combine, merge, parseMacFile, parseNicknames, serialize, withSighting } from './store.ts'
import type { MacFile, Nicknames } from './store.ts'

// The account room (#659). Behaviour agreed with Dan on 2026-10-04 (the issue); the look and every
// sentence settled in design rounds the same day (docs/mods-design.md "Account room (#659)").
//
// - Every rate limit reading this session receives is recorded under the account and org the
//   session started on (L175), in this Mac's readings file in iCloud Drive.
// - When this account reaches 95% on the 5 hour limit or 90% weekly, a boxed card in the band names
//   the account with the most room, from every Mac's readings, with Switch and Dismiss.
// - Switch signs claude.ai out in the browser (signOut below, route still to be proven), then
//   opens the sign in page with that account's email filled in.
// - The first session on an account not seen before asks once for a nickname; /accounts rename
//   changes one later. Nicknames live in the claude-sync payload, so both Macs share them.
//
// The one recorder of rate limits: the status bar draws its 5 hour and weekly figures from Claude
// Code's status line JSON in statusline.sh and records nothing, so this mod reads the engine's own
// measurement (session.measure) and nothing reads usage twice.

const MOD = 'account-room'
const PANE = 'account-room-nickname'
const MIN = 60_000
const LOCK_STALE_MS = 30_000
const LOGIN_TIMEOUT_MS = 10 * MIN

const sessionRef = { plugin: 'account-room', key: 'session' } as const
const liveRef = { plugin: 'account-room', key: 'live' } as const
const phaseRef = { plugin: 'account-room', key: 'phase' } as const
const dismissedRef = { plugin: 'account-room', key: 'isDismissed' } as const
const askingRef = { plugin: 'account-room', key: 'asking' } as const
const typedRef = { plugin: 'account-room', key: 'typed' } as const

let chain: Promise<unknown> = Promise.resolve()
const serial = <T,>(work: () => Promise<T>): Promise<T> => {
  const next = chain.then(work)
  chain = next.catch(() => undefined)
  return next
}
// Things said once per session, so a fault that repeats on every reading is not a note per reading.
const noted = new Set<string>()
// Whether this module instance is running a Switch: after a reload a "working" phase has no runner.
let switching = false
let ticker: { cancel: () => void } | undefined
let lastBest: Account | undefined

const nicknamesPath = (home: string) => `${home}/.claude/mods/account-room-nicknames.json`
const lockDir = (home: string) => `${home}/.claude/state/account-room`
const iCloud = (home: string) => `${home}/Library/Mobile Documents/com~apple~CloudDocs/account-room`
const message = (err: unknown) => String((err as Error)?.message ?? err)

const once = ($: EngineInterface, key: string, text: string, debug = false) => {
  if (noted.has(key)) return
  noted.add(key)
  $.ui.log(text, debug ? { to: 'debug' } : undefined)
}

/** A file's text; undefined when it does not exist; rejects when it exists and cannot be read. */
const readText = async ($: EngineInterface, path: string): Promise<string | undefined> => {
  if (!(await $.fs.exists(path))) return undefined
  return (await $.fs.read(path)) as string
}

/**
 * Written whole and moved into place, so no reader on either Mac sees half a file. The temp file is
 * in this Mac's own state folder, never beside the target: the nicknames sit in the mirrored mods
 * tree and the readings in iCloud Drive, and either would carry a stray temp file to the other Mac.
 */
const writeWhole = async ($: EngineInterface, home: string, path: string, text: string) => {
  await $.process.run(['mkdir', '-p', lockDir(home)])
  // The target's folder too: on a Mac where no reading was ever saved it does not exist yet.
  const mk = await $.process.run(['mkdir', '-p', path.slice(0, path.lastIndexOf('/'))])
  if (mk.exitCode !== 0) throw new Error(mk.stderr.trim() || `mkdir exited ${mk.exitCode}`)
  const tmp = `${lockDir(home)}/${crypto.randomUUID()}.tmp`
  await $.fs.write(tmp, text)
  const mv = await $.process.run(['mv', '-f', tmp, path])
  if (mv.exitCode !== 0) {
    await $.process.run(['rm', '-f', tmp]).catch(() => undefined)
    throw new Error(mv.stderr.trim() || `mv exited ${mv.exitCode}`)
  }
}

/**
 * Two sessions on this Mac write the same files, so each read, change and write holds a lock
 * (assume it runs twice). A lock left by a session that died is taken over after 30 seconds.
 */
const locked = async <T,>($: EngineInterface, home: string, work: () => Promise<T>): Promise<T> => {
  await $.process.run(['mkdir', '-p', lockDir(home)])
  const lock = `${lockDir(home)}/write.lock`
  for (let i = 0; i < 50; i++) {
    const r = await $.process.run(['mkdir', lock])
    if (r.exitCode === 0) {
      // A token inside the lock says whose it is. A lock taken over as stale while this work ran
      // has been moved aside with the token in it, so the token's removal fails and this session
      // leaves the other's lock alone.
      const token = `${lock}/${crypto.randomUUID()}`
      try {
        await $.fs.write(token, '')
      } catch (err) {
        // Held but not yet marked as ours: let it go now rather than leave it to go stale.
        await $.process.run(['rmdir', lock]).catch(() => undefined)
        throw err
      }
      try {
        return await work()
      } finally {
        const mine = await $.process.run(['rm', token]).catch(() => undefined)
        if (mine && mine.exitCode === 0) await $.process.run(['rmdir', lock]).catch(() => undefined)
      }
    }
    const st = await $.fs.stat(lock).catch(() => undefined)
    if (st && (await $.clock.now()) - st.mtimeMs > LOCK_STALE_MS) {
      // Moved aside rather than removed: a rename succeeds for one session only, so two that both
      // judged it stale cannot remove the lock the other has just taken.
      const aside = `${lock}.stale.${crypto.randomUUID()}`
      const mv = await $.process.run(['mv', lock, aside]).catch(() => undefined)
      if (mv && mv.exitCode === 0) {
        // It still holds the dead session's token, so it goes whole, by its exact new name.
        const rm = await $.process.run(['rm', '-rf', aside]).catch(() => undefined)
        if (!rm || rm.exitCode !== 0) once($, 'stale-lock', `account-room: a stale lock was moved aside but could not be removed: ${aside}`, true)
      }
      continue
    }
    await $.clock.sleep(100)
  }
  throw new Error(`another session has held ${lock} for over 5 seconds`)
}

/** The nicknames, or why they cannot be read. A missing file is no names yet. */
const loadNicknames = async ($: EngineInterface, home: string): Promise<Nicknames | string> => {
  try {
    const text = await readText($, nicknamesPath(home))
    return text === undefined ? { v: 1, names: {} } : parseNicknames(text)
  } catch (err) {
    return message(err)
  }
}

/** One name written into the shared file. A file that cannot be read is never overwritten (L105). */
const writeNickname = async ($: EngineInterface, home: string, id: string, name: string | null) =>
  locked($, home, async () => {
    const cur = await loadNicknames($, home)
    if (typeof cur === 'string') throw new Error(`the nicknames file could not be read: ${cur}`)
    await writeWhole($, home, nicknamesPath(home), `${JSON.stringify({ v: 1, names: { ...cur.names, [id]: name } }, null, 2)}\n`)
  })

/** Every Mac's readings merged, and the other Macs whose file could not be read. */
const loadReadings = async ($: EngineInterface, s: AccountRoomSession): Promise<{ accounts: Map<string, Account>; unavailable: Unavailable[] }> => {
  const files: MacFile[] = []
  const unavailable: Unavailable[] = []
  let names: string[] = []
  // Asking whether the folder is there can fail as well as listing it, so both are inside the one
  // boundary: an unanswerable folder is named on the card, never a recompute that throws (L215).
  try {
    if (await $.fs.exists(s.folder)) names = (await $.fs.list(s.folder)).map(e => e.name)
  } catch (err) {
    unavailable.push({ mac: 'iCloud Drive', why: `the readings folder could not be read: ${message(err)}` })
  }
  if (s.mac && names.includes(`.${s.mac}.json.icloud`)) unavailable.push({ mac: s.mac, why: 'not downloaded from iCloud yet' })
  else if (s.mac && names.includes(`${s.mac}.json`)) {
    const own = await readText($, `${s.folder}/${s.mac}.json`).then(t => (t === undefined ? 'gone from the folder' : parseMacFile(t)), err => message(err))
    // This Mac's own file holds other accounts' readings too, so one that cannot be read is named.
    if (typeof own === 'object') files.push(own)
    else unavailable.push({ mac: s.mac, why: own })
  }
  for (const m of macsIn(names, s.mac ?? '')) {
    if ('notDownloaded' in m) {
      unavailable.push({ mac: m.mac, why: 'not downloaded from iCloud yet' })
      continue
    }
    const f = await readText($, `${s.folder}/${m.file}`).then(t => (t === undefined ? 'gone from the folder' : parseMacFile(t)), err => message(err))
    if (typeof f === 'string') unavailable.push({ mac: m.mac, why: f })
    else files.push(f)
  }
  return { accounts: merge(files), unavailable }
}

/** One sighting of this session's account, with its reading when there is one, in this Mac's file. */
const record = ($: EngineInterface, s: AccountRoomSession, reading: Reading | undefined) =>
  serial(async () => {
    if (!s.mac) {
      once($, 'no-mac', "Account room: this Mac's name could not be read, so its readings are not saved.")
      return
    }
    const path = `${s.folder}/${s.mac}.json`
    // iCloud evicts a file it has synced to a placeholder beside it: the file is not missing, only
    // not here, so writing a fresh one would replace every reading it holds (L105).
    let evicted: boolean
    try {
      evicted = await $.fs.exists(`${s.folder}/.${s.mac}.json.icloud`)
    } catch (err) {
      // Unknown is not "no": writing on a guess could replace every reading the file holds (L215).
      once($, 'own-evict-unknown', `Account room: could not tell whether this Mac's readings file is downloaded from iCloud, so nothing was saved: ${message(err)}`)
      return
    }
    if (evicted) {
      once($, 'own-evicted', `Account room: this Mac's readings file is not downloaded from iCloud yet, so no readings are saved until it is: ${path}`)
      return
    }
    try {
      await locked($, s.home, async () => {
        const text = await readText($, path)
        const cur = text === undefined ? undefined : parseMacFile(text)
        // Never rewritten from one sighting: that would erase every other account's readings it
        // holds (L105). It is left for repair, and the card names it as unavailable.
        if (typeof cur === 'string') {
          once($, 'own-unreadable', `Account room: this Mac's readings file could not be read (${cur}), so no readings are saved until it is repaired or removed: ${path}`)
          return
        }
        const now = await $.clock.now()
        await writeWhole($, s.home, path, serialize(withSighting(cur, s.mac as string, s, reading, now)))
      })
    } catch (err) {
      once($, 'record-failed', `Account room: readings could not be saved to ${s.folder}: ${message(err)}`)
    }
  })

/**
 * The Mac's offset from UTC in minutes, as `date +%z` gives it, so resets read in local time; null
 * when it cannot be read, and the card then labels its times UTC.
 */
const offsetOf = async ($: EngineInterface, at?: number): Promise<number | null> => {
  const argv = at === undefined ? ['date', '+%z'] : ['date', '-r', String(Math.floor(at / 1000)), '+%z']
  const r = await $.process.run(argv).catch(() => undefined)
  const m = r && r.exitCode === 0 ? /^([+-])(\d\d)(\d\d)$/.exec(r.stdout.trim()) : null
  if (!m) {
    once($, 'no-offset', 'account-room: the time zone could not be read, so reset times show in UTC', true)
    return null
  }
  return (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3]))
}

const clearRow = async ($: EngineInterface) => {
  await $.modkit.clearBandRow({ mod: MOD, id: 'room' }).catch(err => once($, 'band-clear', `account-room: the band could not be updated: ${message(err)}`, true))
}

/** What the card shows now, from this session's live reading and every Mac's readings. */
const recompute = ($: EngineInterface) =>
  serial(async () => {
    const s = (await $.state.get(sessionRef)).value
    if (!s || !s.isInteractive) return
    const live = (await $.state.get(liveRef)).value ?? undefined
    const now = await $.clock.now()
    if ((await $.state.get(dismissedRef)).value || !triggered(live, now).length) {
      lastBest = undefined
      shown = undefined
      // A failure belongs to the low spell it happened in; the next one starts with the offer.
      if (!switching) await $.state.set(phaseRef, { kind: 'idle' })
      await clearRow($)
      return
    }
    let phase: AccountRoomPhase = (await $.state.get(phaseRef)).value ?? { kind: 'idle' }
    // A reload while Switch ran left nobody running it.
    if (phase.kind === 'working' && !switching) {
      // In the logout step the run was cut off before anything was confirmed, and nothing checked
      // the page afterwards, so the card says it was cut off (#736). In the login step the sign out
      // was confirmed, and whether the sign in finished is unknown, so the card goes back to its
      // offer rather than claim a failure.
      phase = phase.step === 'logout' ? { kind: 'failed', cause: 'interrupted' } : { kind: 'idle' }
      await $.state.set(phaseRef, phase)
    }
    const nick = await loadNicknames($, s.home)
    if (typeof nick === 'string') once($, 'nicknames', `Account room: the nicknames could not be read (${nicknamesPath(s.home)}): ${nick}`)
    const names = typeof nick === 'string' ? {} : nick.names
    const nameFor = (id: string) => (Object.prototype.hasOwnProperty.call(names, id) ? (names[id] ?? null) : null)
    const { accounts, unavailable } = await loadReadings($, s)
    const here: Account = { id: s.id, email: s.email, org: s.org, nickname: nameFor(s.id), ...(live ? { reading: live } : {}) }
    const others = [...accounts.values()].filter(a => a.id !== s.id).map(a => ({ ...a, nickname: nameFor(a.id) }))
    const v = verdict(here, others, now)
    lastBest = v.kind === 'room' ? v.best : undefined
    shown = { verdict: v, offset: await offsetsFor($, v, now), unavailable }
    await draw($, phase, now)
  })

/** The offset in force at every instant the card shows, plus now, read once per pass. */
const offsetsFor = async ($: EngineInterface, v: Verdict, now: number): Promise<Offset> => {
  const instants = new Set<number>([now])
  if (v.kind === 'room') for (const l of [v.best.reading?.five, v.best.reading?.week]) if (l?.resetsAt) instants.add(l.resetsAt)
  if (v.kind === 'no-room' && v.soonest) instants.add(v.soonest.at)
  const known = new Map<number, number | null>()
  for (const at of instants) known.set(at, await offsetOf($, at === now ? undefined : at))
  return at => (known.has(at) ? (known.get(at) as number | null) : (known.get(now) ?? null))
}

// What the card last showed, so a progress tick redraws the seconds without reading every file again.
let shown: { verdict: Verdict; offset: Offset; unavailable: Unavailable[] } | undefined

const draw = async ($: EngineInterface, phase: AccountRoomPhase, now: number) => {
  if (!shown) return
  const c = card({ verdict: shown.verdict, phase, now, offset: shown.offset, unavailable: shown.unavailable })
  try {
    // An older mod-kit without the 'room' slot refuses the row, which is said below.
    await $.modkit.bandRow({ mod: MOD, id: 'room', slot: 'room', lines: c.lines, frame: c.frame })
  } catch (err) {
    // Said in the transcript, not only the debug log: a refused card is the whole feature missing (L551).
    once($, 'band-show', `Account room: the band refused the card, so it is not shown: ${message(err)}`)
  }
}

const stopTicker = () => {
  ticker?.cancel()
  ticker = undefined
}

// Switch's first step (#659): sign claude.ai out in the browser, so the sign in page that follows
// cannot approve the old account. Dan, 2026-10-04: he has to log out in the browser no matter what.
//
// The route is NOT proven yet. Finding it means testing on a real browser signed in to claude.ai,
// which signs Dan out, so it is left open (named in the PR). Until then both commands are empty and
// every Switch stops at this step, saying the page did not confirm the sign out, which is true.
//
// Once proven, the route is two shell commands in the manifest's userConfig defaults (so both Macs
// get it with the mod): `logoutCommand` signs the browser out, and `signedOutCheck` must then print
// exactly `signed out` and exit 0. A logout command that fails stops Switch; one that succeeds is
// still not taken as a sign out until the check confirms the signed out state (L156, L184).

const LOGOUT_TIMEOUT_MS = 60_000
const CHECK_TIMEOUT_MS = 30_000

type SignOutRoute = { logoutCommand: string; signedOutCheck: string }
// The cause is what the card says and the why is the toast's detail, so each stop names what was
// actually measured: nothing attempted, the command, the check not run, or the check's answer (#736).
type SignOut = { isConfirmed: true } | { isConfirmed: false; cause: AccountRoomStop; why: string }

const short = (s: string) => (s.trim().length > 120 ? `${s.trim().slice(0, 120)}...` : s.trim())

const signOut = async ($: EngineInterface, route: SignOutRoute): Promise<SignOut> => {
  if (!route.logoutCommand || !route.signedOutCheck) return { isConfirmed: false, cause: 'no-route', why: 'no browser logout route has been proven yet (#659)' }
  let out: { exitCode: number; stderr: string }
  try {
    out = await $.process.run(['/bin/sh', '-c', route.logoutCommand], { timeoutMs: LOGOUT_TIMEOUT_MS })
  } catch (err) {
    return { isConfirmed: false, cause: 'logout-failed', why: `the logout command could not be run: ${message(err)}` }
  }
  if (out.exitCode !== 0) return { isConfirmed: false, cause: 'logout-failed', why: `the logout command exited ${out.exitCode}: ${short(out.stderr) || 'no output'}` }
  let check: { exitCode: number; stdout: string }
  try {
    check = await $.process.run(['/bin/sh', '-c', route.signedOutCheck], { timeoutMs: CHECK_TIMEOUT_MS })
  } catch (err) {
    return { isConfirmed: false, cause: 'check-not-run', why: `the signed out check could not be run: ${message(err)}` }
  }
  if (check.exitCode === 0 && check.stdout.trim() === 'signed out') return { isConfirmed: true }
  return { isConfirmed: false, cause: 'not-confirmed', why: `the signed out check exited ${check.exitCode} and said "${short(check.stdout)}"` }
}

type Options = { logoutCommand?: unknown; signedOutCheck?: unknown; readingsFolder?: unknown }
const str = (v: unknown) => (typeof v === 'string' ? v.trim() : '')

const runSwitch = async ($: EngineInterface, best: Account, options: Options) => {
  try {
    const out = await signOut($, { logoutCommand: str(options.logoutCommand), signedOutCheck: str(options.signedOutCheck) })
    if (!out.isConfirmed) {
      $.ui.toast(`Switch stopped: ${out.why}`)
      await $.state.set(phaseRef, { kind: 'failed', cause: out.cause })
      return
    }
    await $.state.set(phaseRef, { kind: 'working', step: 'login', since: await $.clock.now() })
    await recompute($)
    const r = await $.process
      .run(['claude', 'auth', 'login', `--email=${best.email}`], { timeoutMs: LOGIN_TIMEOUT_MS })
      .catch(err => ({ exitCode: -1, stdout: '', stderr: message(err) }))
    await $.state.set(phaseRef, { kind: 'idle' })
    if (r.exitCode !== 0) {
      $.ui.toast(`Switch did not finish: ${r.stderr.trim() || r.stdout.trim() || `claude auth login exited ${r.exitCode}`}`)
      return
    }
    $.ui.toast(`Switched to ${nameOf(best)}.`)
    await $.state.set(dismissedRef, true)
  } finally {
    switching = false
    stopTicker()
    await recompute($)
  }
}

const startSwitch = async ($: EngineInterface, options: Options) => {
  if (switching) return
  if (!lastBest) await recompute($)
  const best = lastBest
  if (!best) return
  // Without an email the sign in page would open blank after the browser was already signed out.
  if (!best.email) {
    $.ui.toast(`Switch did not run: no email is recorded for ${nameOf(best)}, so its sign in page could not be filled in.`)
    return
  }
  // The email comes from a file another Mac wrote, so only a plain address reaches the command line.
  if (!/^[^\s@-][^\s@]*@[^\s@]+\.[^\s@]+$/.test(best.email)) {
    $.ui.toast(`Switch did not run: the email recorded for ${nameOf(best)}, "${best.email}", is not an address its sign in page could be filled in with.`)
    return
  }
  switching = true
  try {
    await $.state.set(phaseRef, { kind: 'working', step: 'logout', since: await $.clock.now() })
    stopTicker()
    // Elapsed seconds, so working, still alive and stalled look different (CLAUDE.md).
    // tick only redraws from what is held in memory, and draw catches the one call that can fail.
    ticker = $.clock.every(1000, () => void tick($))
    await recompute($)
    // A failure here is said, never left as an unhandled rejection with the card stuck (L73).
    $.clock.after(0, () => {
      runSwitch($, best, options).catch(err => $.ui.toast(`Switch did not finish: ${message(err)}`))
    })
  } catch (err) {
    // A start that failed must not leave Switch and Try again refusing for the rest of the session.
    switching = false
    stopTicker()
    await $.state.set(phaseRef, { kind: 'idle' }).catch(() => undefined)
    $.ui.toast(`Switch did not run: ${message(err)}`)
    await recompute($)
  }
}

// One tick at a time: a pass slower than a second skips the next tick rather than queueing behind it.
let ticking = false
const tick = async ($: EngineInterface) => {
  if (ticking) return
  ticking = true
  try {
    await serial(async () => draw($, (await $.state.get(phaseRef)).value ?? { kind: 'idle' }, await $.clock.now()))
  } finally {
    ticking = false
  }
}

/** Opens the nickname dialog for one account. */
const ask = async ($: EngineInterface, a: AccountRoomAsking) => {
  await $.state.set(askingRef, a)
  await $.state.set(typedRef, a.current ?? '')
  const opened = await $.ui.open({ id: PANE, title: 'Nickname', focus: true, closeOnEscape: true, holdToasts: true, rows: 7 })
  if (!opened.isPlaced) {
    // Opened at session start, unasked, Claude Code holds the question back below 144 columns, so a
    // narrower window shows nothing at all. The question keeps waiting, and the transcript says so
    // with the command that asks for it, which opens at any width (live check, 2026-10-05).
    // Claude Code's own reason is said, never a width this mod did not measure (L11); a reason that
    // came back empty is no reason, so the fallback is said instead of an empty pair of brackets.
    const given = 'reason' in opened && typeof opened.reason === 'string' ? opened.reason.trim() : ''
    const why = given || 'Claude Code has not placed it'
    $.ui.log(`account-room: the nickname dialog is waiting to be shown: ${why}`, { to: 'debug' })
    // A login file with no email leaves the account named by its org, or as this account.
    const who = a.email || (a.org ? `the ${a.org} account` : 'this account')
    const what = a.current === null ? `${who} has no nickname yet, and the question` : `The nickname question for ${who}`
    // Once per account: a later unplaced ask for another account is its own news (L707).
    once($, `nickname-waiting:${a.id}`, `Account room: ${what} is waiting to be shown (${why}). Run /accounts rename to answer it now.`)
  }
}

const finishAsk = async ($: EngineInterface, name: string | null, close: boolean) => {
  const a = (await $.state.get(askingRef)).value
  const s = (await $.state.get(sessionRef)).value
  if (!a || !s) return
  if (name !== null && !name.trim()) return
  try {
    // A skip of an account already named changes nothing; a skip of a new one records the ask.
    if (name !== null || a.current === null) await writeNickname($, s.home, a.id, name === null ? null : name.trim())
  } catch (err) {
    $.ui.toast(`The nickname could not be saved: ${message(err)}`)
    return
  }
  await $.state.set(askingRef, null)
  if (close) await $.ui.close({ id: PANE })
  await recompute($)
}

const afterStart = async ($: EngineInterface, s: AccountRoomSession) => {
  let reading: Reading | undefined
  try {
    reading = fromRateLimits((await $.session.usage()).rateLimits, await $.clock.now())
  } catch (err) {
    // Unmeasured, not empty: the first session.measure brings the figures (L215).
    once($, 'usage-start', `account-room: could not read this session's rate limits at start: ${message(err)}`, true)
  }
  // Merged, never overwritten: a session.measure may already have stored a newer reading, which
  // wins limit by limit over this older start reading (L510).
  const already = (await $.state.get(liveRef)).value ?? undefined
  if (reading) await $.state.set(liveRef, combine(reading, already) as Reading)
  await record($, s, reading)
  if (s.isInteractive) {
    const nick = await loadNicknames($, s.home)
    if (typeof nick === 'string') once($, 'nicknames', `Account room: the nicknames could not be read (${nicknamesPath(s.home)}): ${nick}`)
    else if (!Object.prototype.hasOwnProperty.call(nick.names, s.id)) await ask($, { id: s.id, email: s.email, org: s.org, current: null })
  }
  await recompute($)
}

/** One measurement's windows taken in: this session's live reading, this Mac's file, the card. */
const takeIn = async ($: EngineInterface, windows: Parameters<typeof fromRateLimits>[0]) => {
  const s = (await $.state.get(sessionRef)).value
  if (!s) return
  const reading = fromRateLimits(windows, await $.clock.now())
  if (!reading) return
  // Limit by limit, so a response reporting one window keeps the other (L510).
  await $.state.set(liveRef, combine((await $.state.get(liveRef)).value ?? undefined, reading) as Reading)
  await record($, s, reading)
  await recompute($)
}

export const register: Register = (on, options) => {
  const opts = (options ?? {}) as Options

  on('session.start', async ($, e, next) => {
    const r = await next(e)
    const home = await $.env.get('HOME')
    if (!home) {
      $.ui.log('account-room: no home folder, so no account is recorded', { to: 'debug' })
      return r
    }
    let acct: { accountUuid?: unknown; organizationUuid?: unknown; emailAddress?: unknown; organizationName?: unknown } | undefined
    try {
      acct = (JSON.parse((await readText($, `${home}/.claude.json`)) ?? '{}') as { oauthAccount?: typeof acct }).oauthAccount
    } catch (err) {
      $.ui.log(`account-room: ~/.claude.json could not be read, so this session's account is unknown: ${message(err)}`, { to: 'debug' })
      return r
    }
    if (!acct || typeof acct.accountUuid !== 'string' || typeof acct.organizationUuid !== 'string') {
      $.ui.log('account-room: no Claude account is logged in (an API key session?), so nothing is recorded', { to: 'debug' })
      return r
    }
    const mac = await $.process.run(['scutil', '--get', 'LocalHostName']).then(
      x => (x.exitCode === 0 && x.stdout.trim() ? x.stdout.trim() : null),
      () => null,
    )
    const s: AccountRoomSession = {
      id: await accountKey(acct.accountUuid, acct.organizationUuid),
      email: typeof acct.emailAddress === 'string' ? acct.emailAddress : '',
      org: typeof acct.organizationName === 'string' ? acct.organizationName : '',
      isInteractive: e.isInteractive,
      home,
      mac,
      folder: str(opts.readingsFolder) || iCloud(home),
    }
    await $.state.set(sessionRef, s)
    if (e.isInteractive) {
      await $.command.register({ name: 'accounts', description: 'Rename a Claude account: /accounts rename, or /accounts rename <nickname or email>' })
    }
    // The rest runs once the session is ready rather than holding up its start.
    $.clock.after(0, () => {
      afterStart($, s).catch(err => once($, 'after-start', `Account room: this session's account could not be set up: ${message(err)}`))
    })
    return r
  })

  on('session.measure', async ($, e, next) => {
    // The reading work (saving it, reading every Mac's figures, drawing the card) runs once this
    // hook has returned, so a slow write or a held lock never holds up the measurement for the
    // mods beneath (#736). A failure there is said once, never dropped (L73).
    if (e.changed.includes('rateLimits')) {
      const windows = e.rateLimits
      $.clock.after(0, () => {
        takeIn($, windows).catch(err => once($, 'measure-failed', `Account room: a rate limit reading could not be taken in: ${message(err)}`))
      })
    }
    return next(e)
  })

  on('ui.press', { plugin: 'mod-kit', element: 'account-room:switch' }, async ($, e) => {
    await startSwitch($, opts)
    return { element: e.element }
  })
  on('ui.press', { plugin: 'mod-kit', element: 'account-room:retry' }, async ($, e) => {
    await startSwitch($, opts)
    return { element: e.element }
  })
  on('ui.press', { plugin: 'mod-kit', element: 'account-room:dismiss' }, async ($, e) => {
    // This session only: kept in its own state, nothing shared is written (the spec).
    await $.state.set(dismissedRef, true)
    if (!switching) await $.state.set(phaseRef, { kind: 'idle' })
    await recompute($)
    return { element: e.element }
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE) return next(e)
    const a = await read($, askingRef)
    if (!a) return next(e)
    const typed = (await read($, typedRef)) ?? ''
    const { Box, Button, Input, Text } = $.ui.resolve(e) as unknown as Record<string, (p: Record<string, unknown>) => unknown>
    const who = a.org ? `${a.email}, ${a.org}` : a.email
    // The settled dialog (nickname round): chip, question, the email and org dim under it, a text
    // field, Save and Skip, and the keys in dim text. Esc closes it, which is a skip.
    return (
      <Box flexDirection="column">
        <Box flexDirection="row">
          <Text inverse> Nickname </Text>
          <Text>  </Text>
          <Text bold>What should this account be called?</Text>
        </Box>
        <Text dimColor>{who}</Text>
        <Input key="nickname" value={typed} autoFocus submitLabel="save" onInput={(v: string) => void $.state.set(typedRef, v)} onSubmit={(v: string) => void finishAsk($, v, true)} />
        <Box flexDirection="row">
          <Button key="save" label="Save" onPress={async () => finishAsk($, (await $.state.get(typedRef)).value ?? '', true)} />
          <Text> </Text>
          <Button key="skip" label="Skip" onPress={() => void finishAsk($, null, true)} />
        </Box>
        <Text dimColor>Enter to save · Esc to skip</Text>
      </Box>
    ) as never
  })

  on('ui.close', async ($, e, next) => {
    if (e.id === PANE && e.origin.kind === 'person' && (await $.state.get(askingRef)).value) await finishAsk($, null, false)
    return next(e)
  })

  on('command.run', { command: 'accounts' }, async ($, e) => {
    const usage = 'Usage: /accounts rename, or /accounts rename <nickname or email>.'
    const [sub, ...rest] = e.args.trim().split(/\s+/)
    if (sub !== 'rename') return { text: usage }
    const s = (await $.state.get(sessionRef)).value
    if (!s) return { text: 'This session has no Claude account, so there is nothing to rename.' }
    const nick = await loadNicknames($, s.home)
    if (typeof nick === 'string') return { text: `The nicknames could not be read, so none can be changed: ${nick}` }
    const current = (id: string) => (Object.prototype.hasOwnProperty.call(nick.names, id) ? (nick.names[id] ?? null) : null)
    const q = rest.join(' ').trim()
    if (!q) {
      await ask($, { id: s.id, email: s.email, org: s.org, current: current(s.id) })
      return { text: '' }
    }
    const { accounts } = await loadReadings($, s)
    if (!accounts.has(s.id)) accounts.set(s.id, { id: s.id, email: s.email, org: s.org })
    const lower = q.toLowerCase()
    const hits = [...accounts.values()].filter(a => (current(a.id) ?? '').toLowerCase() === lower || a.email.toLowerCase() === lower)
    if (hits.length === 0) return { text: `No account is called "${q}". Name one by its nickname or email.` }
    if (hits.length > 1) return { text: `More than one account is called "${q}". Name it by its email.` }
    const t = hits[0] as Account
    await ask($, { id: t.id, email: t.email, org: t.org, current: current(t.id) })
    return { text: '' }
  })

  on('session.end', async ($, e, next) => {
    stopTicker()
    await clearRow($)
    return next(e)
  })
}
