import type { EngineInterface, On } from 'claude-code'
import type { ModKitAccount } from '../types/index.d.ts'

// A /login in this session changes the account it runs on (#1205). Two mods followed it, each with
// its own copy of this reading and its wait (#1201, #1204), and they are now the first two to hook
// modkit.login instead.
//
// Raised once the command is done, failed or not, since whether the login file changed is the
// file's to say. If the file does not yet name another login it is read every second for half a
// minute, raised again once it does, and no longer: the wait is for this /login alone, and the
// login file is otherwise read again at the moments below. The wait survives a /clear, which ends
// only the conversation, and stops when the session really ends.
//
// A login made anywhere else moves this session too (#1235): another session's /login, or the
// account room's Switch, which runs `claude auth login`. Claude Code keeps one credential per Mac
// and drops the one it holds when the store's version changes (read in 2.1.301's own code), and the
// email it hands the session comes from this same login file, read again whenever the context is
// (its session_context record names why: account_change after a /login, as seen on 2026-10-16).
// So the login file is read again at each prompt (turn.start) and at each re-read of the context
// (prompt.context), and a login other than the one this session is known to be on is raised. Never
// at a measurement: that is many reads a turn, of a file that holds every project. A file that
// cannot be read then raises nothing, since a read that failed says nothing about which login it
// holds; only a /login, which may have broken it, raises it as unknown.

const POLL_MS = 1_000
const WAIT_MS = 30_000
const FIELDS = ['accountUuid', 'organizationUuid', 'displayName', 'emailAddress', 'organizationName', 'organizationType'] as const

const reason = (err: unknown) => String((err as Error)?.message ?? err)

/** What reading the login file needs, as functions, since mod-kit's noun code cannot pass its $ along. */
export type LoginFileIo = { exists: (path: string) => Promise<boolean>; read: (path: string) => Promise<string>; log: (text: string) => void }
export function ioOf($: EngineInterface): LoginFileIo {
  return {
    exists: path => $.fs.exists(path),
    read: path => $.fs.read(path),
    log: text => void $.ui.log(text, { to: 'debug' }),
  }
}

/** The login file's account: its fields, `{}` for no claude.ai login, null for a file that cannot be read (L11). */
export const readAccount = async (io: LoginFileIo, home: string): Promise<ModKitAccount | null> => {
  const path = `${home}/.claude.json`
  try {
    if (!(await io.exists(path))) return {}
    const o = (JSON.parse(await io.read(path)) as { oauthAccount?: Record<string, unknown> }).oauthAccount
    const out: ModKitAccount = {}
    if (!o || typeof o !== 'object') return out
    for (const k of FIELDS) {
      const v = o[k]
      if (typeof v === 'string') out[k] = v
    }
    return out
  } catch (err) {
    io.log(`mod-kit: ~/.claude.json could not be read, so the account is unknown: ${reason(err)}`)
    return null
  }
}

/** Which login an account is, by its account and org ids; unknown and no login have none. */
export const loginKey = (a: ModKitAccount | null | undefined) => (a?.accountUuid && a.organizationUuid ? `${a.accountUuid}:${a.organizationUuid}` : '')

// The session has ended (not a /clear), and the half minute wait in flight, if any.
let ended = false
let watch: { cancel: () => void } | undefined
const stop = () => {
  watch?.cancel()
  watch = undefined
}

// The login this session is known to be on, by loginKey ('' for none), or null when the last raise
// was of a file that could not be read: read at its start and moved by every raise. Kept in $.state,
// so a reload of mod-kit keeps what it last told the mods rather than taking the file as it is then.
const knownRef = { plugin: 'mod-kit', key: 'login' } as const

/** Raised for every mod following the account, after noting it as the login this session is on. */
async function raise($: EngineInterface, account: ModKitAccount | null) {
  await $.state.set(knownRef, account === null ? null : loginKey(account))
  await $.modkit.login({ account })
}

/**
 * Called from mod-kit's own session.start, since a module holds one hook per event: a session started
 * again in this process is followed afresh, and the login it starts on is noted unless a start before
 * it in this session (a reload) already did. A file that cannot be read is noted as unknown.
 */
export async function loginStarted($: EngineInterface) {
  ended = false
  if ((await $.state.get(knownRef)).version !== 0) return
  const h = await $.env.get('HOME').catch(() => undefined)
  if (!h) return
  const a = await readAccount(ioOf($), h)
  await $.state.set(knownRef, a === null ? null : loginKey(a), { ifVersion: 0 })
}

// One look at a time, so a prompt and a re-read landing together raise one change once.
let looks: Promise<void> = Promise.resolve()

async function lookAgain($: EngineInterface) {
  if (ended) return
  const h = await $.env.get('HOME').catch(() => undefined)
  if (!h) return
  const now = await readAccount(ioOf($), h)
  if (now === null || ended) return
  if (loginKey(now) === (await $.state.get(knownRef)).value) return
  await raise($, now)
}

/**
 * Called at each prompt (from mod-kit's own turn.start) and at each re-read of the context: the
 * login file read again, and raised when it names a login other than the one this session is known
 * to be on (#1235). Called once the hook has returned, so a slow disk never holds up the turn.
 */
export function followAccount($: EngineInterface) {
  looks = looks
    .then(() => lookAgain($))
    .catch(err => $.ui.log(`mod-kit: could not read the login file again for the account this session is on: ${reason(err)}`, { to: 'debug' }))
  return looks
}

const landed = (a: ModKitAccount | null, before: string) => a !== null && loginKey(a) !== before

export const registerLogin = (on: On) => {

  on('command.run', { command: 'login' }, async ($, e, next) => {
    const h = await $.env.get('HOME').catch(() => undefined)
    if (!h) return next(e)
    const before = loginKey(await readAccount(ioOf($), h))
    try {
      return await next(e)
    } finally {
      stop()
      try {
        let last = await readAccount(ioOf($), h)
        if (!ended) await raise($, last)
        if (!ended && !landed(last, before)) {
          const until = (await $.clock.now()) + WAIT_MS
          const mine = $.clock.every(POLL_MS, () => {
            void (async () => {
              if (watch !== mine) return
              if (ended) return stop()
              const now = await readAccount(ioOf($), h)
              // Raised only when the file says something new, so a second's read of the same file
              // is not another login for every mod to take in.
              if (JSON.stringify(now) !== JSON.stringify(last)) {
                last = now
                if (watch !== mine || ended) return
                await raise($, now)
                if (landed(now, before)) return stop()
              }
              if (watch === mine && (await $.clock.now()) >= until) stop()
            })().catch(err => $.ui.log(`mod-kit: stopped reading the login file after /login: ${reason(err)}`, { to: 'debug' }))
          })
          watch = mine
        }
      } catch (err) {
        // Never thrown over the command's own result (L95).
        $.ui.log(`mod-kit: could not follow /login: ${reason(err)}`, { to: 'debug' })
      }
    }
  })

  // The context is read again after a compaction, a /clear, a plugin's ask, or the account changing:
  // its email is the login file's, so the file is read again with it (#1235). Passed on as it came.
  on('prompt.context', async ($, e, next) => {
    const r = await next(e)
    try {
      $.clock.after(0, () => void followAccount($))
    } catch (err) {
      $.ui.log(`mod-kit: could not read the login file again after the context was: ${reason(err)}`, { to: 'debug' })
    }
    return r
  })

  on('session.end', async ($, e, next) => {
    // A /clear ends only the conversation; the session, and the account a /login is landing, go on.
    if (e.reason !== 'clear') {
      ended = true
      stop()
    }
    return next(e)
  })
}
