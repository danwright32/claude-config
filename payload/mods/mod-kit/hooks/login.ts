import type { EngineInterface, On } from 'claude-code'
import type { ModKitAccount } from '../types/index.d.ts'

// A /login in this session changes the account it runs on (#1205). A session's account is otherwise
// read once, at its start, because the login file names whatever the Mac is logged in to NOW, which
// another session's switch changes under this one; a /login in THIS session is the one change that
// is this session's own. Two mods followed it, each with its own copy of this reading and its wait
// (#1201, #1204), and they are now the first two to hook modkit.login instead.
//
// Raised once the command is done, failed or not, since whether the login file changed is the
// file's to say. If the file does not yet name another login it is read every second for half a
// minute, raised again once it does, and no longer: a /login that changed nothing (cancelled, or
// the same account again) must not leave a session adopting whatever another session switches the
// Mac to later. The wait survives a /clear, which ends only the conversation, and stops when the
// session really ends.

const POLL_MS = 1_000
const WAIT_MS = 30_000
const FIELDS = ['accountUuid', 'organizationUuid', 'displayName', 'emailAddress', 'organizationName', 'organizationType'] as const

const reason = (err: unknown) => String((err as Error)?.message ?? err)

/** The login file's account: its fields, `{}` for no claude.ai login, null for a file that cannot be read (L11). */
export const readAccount = async ($: EngineInterface, home: string): Promise<ModKitAccount | null> => {
  const path = `${home}/.claude.json`
  try {
    if (!(await $.fs.exists(path))) return {}
    const o = (JSON.parse(await $.fs.read(path)) as { oauthAccount?: Record<string, unknown> }).oauthAccount
    const out: ModKitAccount = {}
    if (!o || typeof o !== 'object') return out
    for (const k of FIELDS) {
      const v = o[k]
      if (typeof v === 'string') out[k] = v
    }
    return out
  } catch (err) {
    $.ui.log(`mod-kit: ~/.claude.json could not be read after /login, so the account is unknown: ${reason(err)}`, { to: 'debug' })
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
/** Called from mod-kit's own session.start, since a module holds one hook per event: a session started again in this process is followed afresh. */
export const loginStarted = () => {
  ended = false
}

const landed = (a: ModKitAccount | null, before: string) => a !== null && loginKey(a) !== before

export const registerLogin = (on: On) => {

  on('command.run', { command: 'login' }, async ($, e, next) => {
    const h = await $.env.get('HOME').catch(() => undefined)
    if (!h) return next(e)
    const before = loginKey(await readAccount($, h))
    try {
      return await next(e)
    } finally {
      stop()
      try {
        let last = await readAccount($, h)
        if (!ended) await $.modkit.login({ account: last })
        if (!ended && !landed(last, before)) {
          const until = (await $.clock.now()) + WAIT_MS
          const mine = $.clock.every(POLL_MS, () => {
            void (async () => {
              if (watch !== mine) return
              if (ended) return stop()
              const now = await readAccount($, h)
              // Raised only when the file says something new, so a second's read of the same file
              // is not another login for every mod to take in.
              if (JSON.stringify(now) !== JSON.stringify(last)) {
                last = now
                if (watch !== mine || ended) return
                await $.modkit.login({ account: now })
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

  on('session.end', async ($, e, next) => {
    // A /clear ends only the conversation; the session, and the account a /login is landing, go on.
    if (e.reason !== 'clear') {
      ended = true
      stop()
    }
    return next(e)
  })
}
