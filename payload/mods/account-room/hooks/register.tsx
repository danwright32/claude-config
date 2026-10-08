import { read } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { AccountRoomAsking, AccountRoomPhase, AccountRoomSession, AccountRoomStop } from '../types/index.d.ts'
import { answerOf, contentsPath, entriesOf, fileOf, isRepoName, notRepoName, putBody, shaAfterPut, unseenWhy } from './github.ts'
import type { Answer, RepoFile } from './github.ts'
import { card, fromRateLimits, nameOf, triggered, verdict } from './room.ts'
import type { Account, Offset, Reading, Unavailable, Unsaved, Verdict } from './room.ts'
import { accountKey, combine, isWorthWriting, macFiles, merge, mergeNicknames, nicknameRefusal, parseMacFile, parseNicknames, serialize, serializeNicknames, withAccount, withName, withSighting } from './store.ts'
import type { MacFile, Nicknames } from './store.ts'

// The account room (#659). Behaviour agreed with Dan on 2026-10-04 (the issue); the look and every
// sentence settled in design rounds the same day (docs/mods-design.md "Account room (#659)").
//
// - Every rate limit reading this session receives is recorded under the account and org the
//   session started on (L175), in this Mac's readings file in the private readings repository on
//   GitHub (#750), rewritten only when a figure moved or its newest reading is over 10 minutes old.
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

/** Work run one piece at a time, in the order it was handed over. */
const queue = () => {
  let chain: Promise<unknown> = Promise.resolve()
  return <T,>(work: () => Promise<T>): Promise<T> => {
    const next = chain.then(work)
    chain = next.catch(() => undefined)
    return next
  }
}
// What the card shows, and its progress ticks, take turns on one queue. This Mac's readings
// writes take turns on their own: a write waiting on GitHub must not stop Switch's elapsed
// seconds counting, which is how a stalled step is told from a live one (#750).
const serial = queue()
const serialWrites = queue()
// The live reading is read, combined and written back in one turn, so two measurements arriving
// together cannot each combine over the same old value and drop the other's window (L443).
const serialLive = queue()
// Things said once per session, so a fault that repeats on every reading is not a note per reading.
const noted = new Set<string>()
// Whether this module instance is running a Switch: after a reload a "working" phase has no runner.
let switching = false
let ticker: { cancel: () => void } | undefined
let lastBest: Account | undefined
// This Mac's readings file as this session last read or wrote it, with its sha: what the next
// reading is judged against and written over, so the same figures again cost no GitHub call. Any
// write GitHub refuses drops it, and the next one reads the file afresh (L443).
let ownFile: { repo: string; mac: string; file: MacFile | undefined; sha: string | undefined } | undefined
// Why this Mac's readings are not reaching GitHub, from a failed write until one lands (the card).
let unsaved: Unsaved | undefined
// Every Mac's readings as last read from GitHub, kept a minute, so a card shown through a busy
// stretch, and a press on it, does not wait on GitHub each time (#750).
let readCache: { at: number; repo: string; value: Readings } | undefined
const READ_FRESH_MS = 60_000
// How many times a write GitHub refuses as stale is read again and tried.
const WRITE_TRIES = 3
// The readings repository, owner/name, from the readingsRepo setting (its manifest default names
// danwright32/account-room-readings), so it can move without a code change (#750).
let readingsRepo = ''

const nicknamesPath = (home: string) => `${home}/.claude/mods/account-room-nicknames.json`
const lockDir = (home: string) => `${home}/.claude/state/account-room`
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
 * tree, which would carry a stray temp file to the other Mac.
 */
const writeWhole = async ($: EngineInterface, home: string, path: string, text: string) => {
  await $.process.run(['mkdir', '-p', lockDir(home)])
  // The target's folder too: on a Mac where nothing was ever saved it does not exist yet.
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
 * Two sessions on this Mac write the same nicknames file, so each read, change and write holds a
 * lock (assume it runs twice). A lock left by a session that died is taken over after 30 seconds.
 * The readings file takes no lock: it lives on GitHub, whose sha check refuses a stale write, and
 * a lock held across the network would hold up every other session for as long as GitHub took.
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

/** The shared file alone, or why it cannot be read. A missing file is no names yet. */
const loadNicknameFile = async ($: EngineInterface, home: string): Promise<Nicknames | string> => {
  try {
    const text = await readText($, nicknamesPath(home))
    return text === undefined ? { names: {} } : parseNicknames(text)
  } catch (err) {
    return message(err)
  }
}

// When both Macs change the nicknames before a sync, claude-sync applies the other Mac's file and
// sets this Mac's aside beside it as `account-room-nicknames.json.conflict-<Mac>` (it never carries
// such a copy to the other Mac). The answers in it are still Dan's, so the mod merges them back by
// its own rule, a name over a skip and the later of two names (#747). The sync itself stays blind to
// what the file means; this mod is the one reader that knows.
const COPY_PREFIX = 'account-room-nicknames.json.conflict-'

/** The conflict copies beside the file, each read, or why it could not be. */
const conflictCopies = async ($: EngineInterface, home: string): Promise<{ name: string; file: Nicknames | string }[]> => {
  const dir = `${home}/.claude/mods`
  let names: string[]
  try {
    // No folder yet is no copies. One that is there and cannot be listed is said, and any copies
    // in it stay where they are until it can be (L215).
    if (!(await $.fs.exists(dir))) return []
    names = (await $.fs.list(dir)).map(e => e.name).filter(n => n.startsWith(COPY_PREFIX))
  } catch (err) {
    once($, 'copies-unlisted', `Account room: ${dir} could not be listed, so a nickname conflict copy in it is not merged: ${message(err)}`)
    return []
  }
  const out: { name: string; file: Nicknames | string }[] = []
  for (const name of names) {
    const file = await readText($, `${dir}/${name}`).then(t => (t === undefined ? 'gone from the folder' : parseNicknames(t)), err => message(err))
    // A copy that cannot be read is left where it is and named, never merged or moved (L105).
    if (typeof file === 'string') once($, `copy-unreadable:${name}`, `Account room: the nickname conflict copy ${name} could not be read: ${file}. It is left where it is.`)
    out.push({ name, file })
  }
  return out
}

/** The nicknames as both Macs gave them: the file merged with any conflict copy beside it. */
const loadNicknames = async ($: EngineInterface, home: string): Promise<Nicknames | string> => {
  const main = await loadNicknameFile($, home)
  if (typeof main === 'string') return main
  const copies = (await conflictCopies($, home)).flatMap(c => (typeof c.file === 'string' ? [] : [c.file]))
  return copies.length ? mergeNicknames([main, ...copies]) : main
}

/**
 * The shared file brought up to date under the lock: every readable conflict copy merged in, then
 * one answer recorded when given, merged rather than replacing (#747). Written only when the
 * nicknames it holds change, so a file the first build wrote stays as it is until there is
 * something new to say. A file that cannot be read is never overwritten (L105). Once the file is
 * read back holding the merge, each copy merged into it leaves the mirrored mods tree for this
 * Mac's state folder, kept whole rather than deleted (L5).
 */
const updateNicknames = async ($: EngineInterface, home: string, answer?: { id: string; name: string | null }) =>
  locked($, home, async () => {
    const main = await loadNicknameFile($, home)
    if (typeof main === 'string') throw new Error(`the nicknames file could not be read: ${main}`)
    const copies = (await conflictCopies($, home)).filter((c): c is { name: string; file: Nicknames } => typeof c.file !== 'string')
    let next = mergeNicknames([main, ...copies.map(c => c.file)])
    if (answer) next = withName(next, answer.id, answer.name, await $.clock.now())
    const text = serializeNicknames(next)
    if (text !== serializeNicknames(main)) await writeWhole($, home, nicknamesPath(home), text)
    if (!copies.length) return
    const back = await loadNicknameFile($, home)
    if (typeof back === 'string' || serializeNicknames(back) !== text) throw new Error('the nicknames file did not read back as written, so the conflict copies were left where they are')
    await $.process.run(['mkdir', '-p', lockDir(home)])
    const at = await $.clock.now()
    for (const c of copies) {
      const to = `${lockDir(home)}/${c.name}.merged-${at}`
      const mv = await $.process.run(['mv', '-n', `${home}/.claude/mods/${c.name}`, to])
      if (mv.exitCode !== 0) {
        once($, `copy-unmoved:${c.name}`, `Account room: ${c.name} is merged into the nicknames, but could not be moved out of the mods folder: ${mv.stderr.trim() || `mv exited ${mv.exitCode}`}`)
        continue
      }
      once($, `copy-merged:${c.name}`, `Account room: merged the nicknames claude-sync set aside as ${c.name} back into the shared file (a name beats a skip; the later of two names wins). The copy is kept as ${to}.`)
    }
  })

/** One answer written into the shared file. */
const writeNickname = async ($: EngineInterface, home: string, id: string, name: string | null) => {
  // Refused here, where every save passes, before the lock is taken (#758).
  const refused = name === null ? undefined : nicknameRefusal(name)
  if (refused) throw new Error(refused)
  return updateNicknames($, home, { id, name })
}

/** At session start: any conflict copy the sync left beside the file merged back into it (#747). */
const settleNicknames = async ($: EngineInterface, home: string) => {
  if (!(await conflictCopies($, home)).some(c => typeof c.file !== 'string')) return
  await updateNicknames($, home).catch(err => once($, 'nicknames-settle', `Account room: the nickname conflict copies could not be merged back: ${message(err)}`))
}

// The readings repository through `gh api` (#750): requests and answers are built and read in
// github.ts; the calls are here because $ cannot be passed across an import.
const GH_TIMEOUT_MS = 20_000

const ghApi = async ($: EngineInterface, args: string[], stdin?: string): Promise<Answer<unknown>> => {
  try {
    return answerOf(await $.process.run(['gh', 'api', ...args], { timeoutMs: GH_TIMEOUT_MS, ...(stdin === undefined ? {} : { stdin }) }))
  } catch (err) {
    return answerOf({ thrown: message(err) })
  }
}

/** Why a 404 came back for the repository, naming the account gh used. */
const unseen = async ($: EngineInterface, repo: string) => unseenWhy(repo, await ghApi($, ['user']))

/** Every entry in the readings folder: none when the repository holds no readings yet. */
const listReadings = async ($: EngineInterface, repo: string): Promise<Answer<{ name: string; type: string }[]>> => {
  const r = await ghApi($, [contentsPath(repo, 'readings')])
  if (r.ok) return entriesOf(r.value)
  if (r.status !== 404) return r
  // No readings folder yet, and no repository this account can see, are both 404: the repository
  // itself tells them apart, so an empty one is never reported as a fault, nor a fault as empty (L215).
  const there = await ghApi($, [`repos/${repo}`])
  if (there.ok) return { ok: true, value: [] }
  return there.status === 404 ? { ok: false, status: 404, why: await unseen($, repo) } : there
}

/** One file's text and sha; undefined when GitHub has no such file (404). */
const readFile = async ($: EngineInterface, repo: string, path: string): Promise<Answer<RepoFile | undefined>> => {
  const r = await ghApi($, [contentsPath(repo, path)])
  if (!r.ok) return r.status === 404 ? { ok: true, value: undefined } : r
  return fileOf(r.value, path)
}

/**
 * A file written whole over the sha it was read at (none for a new file), so a write made since is
 * refused (409, or 422 for a file that appeared) rather than overwritten. The file's new sha.
 */
const putFile = async ($: EngineInterface, repo: string, path: string, text: string, sha: string | undefined, commit: string): Promise<Answer<string | undefined>> => {
  const r = await ghApi($, ['-X', 'PUT', contentsPath(repo, path), '--input', '-'], putBody(text, sha, commit))
  if (r.ok) return { ok: true, value: shaAfterPut(r.value) }
  return r.status === 404 ? { ok: false, status: 404, why: await unseen($, repo) } : r
}

/** Every Mac's readings merged, and those GitHub could not give, with why. */
type Readings = { accounts: Map<string, Account>; unavailable: Unavailable[] }

const fetchReadings = async ($: EngineInterface): Promise<Readings> => {
  if (!isRepoName(readingsRepo)) return { accounts: new Map(), unavailable: [{ mac: null, why: notRepoName(readingsRepo) }] }
  // A folder GitHub cannot list is said for every other Mac on the card, never read as no readings
  // (L215). This Mac's own file is read too: it holds the other accounts used here.
  const listed = await listReadings($, readingsRepo)
  if (!listed.ok) return { accounts: new Map(), unavailable: [{ mac: null, why: listed.why }] }
  const read = await Promise.all(macFiles(listed.value).map(async m => ({ m, f: await readFile($, readingsRepo, `readings/${m.file}`) })))
  const files: MacFile[] = []
  const unavailable: Unavailable[] = []
  for (const { m, f } of read) {
    const parsed = !f.ok ? f.why : f.value === undefined ? 'gone from the repository' : parseMacFile(f.value.text)
    if (typeof parsed === 'string') unavailable.push({ mac: m.mac, why: parsed })
    else files.push(parsed)
  }
  return { accounts: merge(files), unavailable }
}

/**
 * Every Mac's readings, a good read kept for a minute (READ_FRESH_MS). A read with anything GitHub
 * could not give is never kept, so the card stops saying so at the first read after it is fixed
 * (review of #757).
 */
const loadReadings = async ($: EngineInterface): Promise<Readings> => {
  const now = await $.clock.now()
  if (readCache && readCache.repo === readingsRepo && now - readCache.at < READ_FRESH_MS) return readCache.value
  const value = await fetchReadings($)
  readCache = value.unavailable.length ? undefined : { at: now, repo: readingsRepo, value }
  return value
}

/**
 * One sighting of this session's account, with its reading when there is one, in this Mac's file
 * on GitHub (#750). Written only when the file is worth rewriting (isWorthWriting), over the sha it
 * was read at, so GitHub refuses a write made over a newer file; a refused write reads the file
 * again and merges, up to WRITE_TRIES times, never forcing. A file that cannot be read is never
 * written over (L105). Any failure is said on the card for this Mac and once per spell in the
 * transcript, never dropped (L215).
 */
const record = ($: EngineInterface, s: AccountRoomSession, reading: Reading | undefined) =>
  serialWrites(async () => {
    if (!s.mac) {
      once($, 'no-mac', "Account room: this Mac's name could not be read, so its readings are not saved.")
      return
    }
    const mac = s.mac
    const fail = (why: string) => {
      unsaved = { mac, why }
      once($, 'record-failed', `Account room: readings could not be saved to GitHub (${readingsRepo}): ${why}`)
    }
    if (!isRepoName(readingsRepo)) return fail(notRepoName(readingsRepo))
    const path = `readings/${mac}.json`
    let refused = ''
    for (let i = 0; i < WRITE_TRIES; i++) {
      let held = ownFile && ownFile.repo === readingsRepo && ownFile.mac === mac ? ownFile : undefined
      if (!held) {
        const got = await readFile($, readingsRepo, path)
        if (!got.ok) return fail(got.why)
        const parsed = got.value === undefined ? undefined : parseMacFile(got.value.text)
        // Never rewritten from one sighting: that would erase every other account's readings it
        // holds (L105). It is left for repair, and the card names it as unavailable.
        if (typeof parsed === 'string') return fail(`this Mac's readings file on GitHub could not be read (${parsed}), so nothing is written over it until it is repaired or removed`)
        held = ownFile = { repo: readingsRepo, mac, file: parsed, sha: got.value?.sha }
      }
      const now = await $.clock.now()
      const next = withSighting(held.file, mac, s, reading, now)
      // GitHub holds what was last read or written there, so with nothing new to send nothing is
      // unsaved either: the card stops saying a save failed.
      const saved = () => {
        unsaved = undefined
        noted.delete('record-failed')
      }
      if (!isWorthWriting(held.file, next, now)) return saved()
      const put = await putFile($, readingsRepo, path, serialize(next), held.sha, `Readings from ${mac}`)
      if (put.ok) {
        ownFile = put.value === undefined ? undefined : { repo: readingsRepo, mac, file: next, sha: put.value }
        // A write landed: the card stops saying otherwise, and the next failure is news again.
        return saved()
      }
      ownFile = undefined
      if (put.status !== 409 && put.status !== 422) return fail(put.why)
      refused = put.why
    }
    fail(`GitHub refused the write ${WRITE_TRIES} times as stale, the last time with: ${refused}`)
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

/**
 * What the card shows now, from this session's live reading and every Mac's readings. The other
 * Macs' readings, which can wait on GitHub, are read before the pass joins the queue the progress
 * ticks take turns on, so a slow read never stops Switch's elapsed seconds (second review of #757).
 * A pass whose account turned low while it was reading has nothing read to draw from, and leaves
 * the card to the pass that follows the reading that made it low. That pass starts as soon as the
 * reading is taken in, never after its write to GitHub (drawBeside, #758), so it costs no wait.
 */
const recompute = async ($: EngineInterface) => {
  const first = (await $.state.get(sessionRef)).value
  const low = !!first && first.isInteractive && !(await $.state.get(dismissedRef)).value && triggered((await $.state.get(liveRef)).value ?? undefined, await $.clock.now()).length > 0
  const readings = low ? await loadReadings($) : undefined
  return serial(async () => {
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
    if (!readings) return
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
    const nameFor = (id: string) => (Object.prototype.hasOwnProperty.call(names, id) ? (names[id]?.name ?? null) : null)
    const { accounts, unavailable } = readings
    const here: Account = { id: s.id, email: s.email, org: s.org, nickname: nameFor(s.id), ...(live ? { reading: live } : {}) }
    const others = [...accounts.values()].filter(a => a.id !== s.id).map(a => ({ ...a, nickname: nameFor(a.id) }))
    const v = verdict(here, others, now)
    lastBest = v.kind === 'room' ? v.best : undefined
    shown = { verdict: v, offset: await offsetsFor($, v, now), unavailable }
    await draw($, phase, now)
  })
}

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
  const c = card({ verdict: shown.verdict, phase, now, offset: shown.offset, unavailable: shown.unavailable, ...(unsaved ? { unsaved } : {}) })
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
// The route is two shell commands in the manifest's userConfig defaults (so both Macs get it with the
// mod), proven on a real Chrome signed in to claude.ai on 2026-10-05 (#659): bin/chrome-logout.sh
// loads claude.ai's logout page in Chrome's last used profile, and bin/chrome-signed-out.sh looks
// for claude.ai's session cookie there. With either setting emptied, Switch stops at this step.
// `logoutCommand` signs the browser out, and `signedOutCheck` must then print
// exactly `signed out` and exit 0, or exit 2 when it cannot tell. A logout command that fails stops Switch; one that succeeds is
// still not taken as a sign out until the check confirms the signed out state (L156, L184).

const LOGOUT_TIMEOUT_MS = 60_000
// A minute, because Chrome writes a cookie's removal to disk late: 31 seconds in the 2026-10-05 proof.
const CHECK_TIMEOUT_MS = 60_000
// The signed out check's exit code for "could not tell", as the manifest's signedOutCheck states.
const CHECK_COULD_NOT_TELL = 2

type SignOutRoute = { logoutCommand: string; signedOutCheck: string }
// The cause is what the card says and the why is the toast's detail, so each stop names what was
// actually measured: nothing attempted, the command, the check not run, or the check's answer (#736).
type SignOut = { isConfirmed: true } | { isConfirmed: false; cause: AccountRoomStop; why: string }

const short = (s: string) => (s.trim().length > 120 ? `${s.trim().slice(0, 120)}...` : s.trim())

const signOut = async ($: EngineInterface, route: SignOutRoute): Promise<SignOut> => {
  if (!route.logoutCommand || !route.signedOutCheck) return { isConfirmed: false, cause: 'no-route', why: 'no browser logout route is set up' }
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
  // Exit 2 is the check's own "could not tell" (bin/chrome-signed-out.sh: Chrome's profile or its
  // cookies could not be read), so no answer was read and none is claimed (#773, L11).
  // Only with a reason printed: /bin/sh exits 2 for a syntax error in a hand set check too, and that
  // measured nothing about the browser (L11, L440).
  if (check.exitCode === CHECK_COULD_NOT_TELL && check.stdout.trim()) return { isConfirmed: false, cause: 'check-unanswered', why: `the signed out check could not read the browser: ${short(check.stdout)}` }
  return { isConfirmed: false, cause: 'not-confirmed', why: `the signed out check exited ${check.exitCode} and said "${short(check.stdout)}"` }
}

type Options = { logoutCommand?: unknown; signedOutCheck?: unknown; readingsRepo?: unknown }
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
  if (reading) {
    const start = reading
    await serialLive(async () => {
      const already = (await $.state.get(liveRef)).value ?? undefined
      await $.state.set(liveRef, combine(start, already) as Reading)
    })
  }
  // Started here and awaited once the card is drawn, so the start never waits on GitHub (#758).
  const write = started(record($, s, reading))
  try {
    await settleNicknames($, s.home)
    if (s.isInteractive) {
      const nick = await loadNicknames($, s.home)
      if (typeof nick === 'string') once($, 'nicknames', `Account room: the nicknames could not be read (${nicknamesPath(s.home)}): ${nick}`)
      else if (!Object.prototype.hasOwnProperty.call(nick.names, s.id)) await ask($, { id: s.id, email: s.email, org: s.org, current: null })
    }
  } catch (err) {
    // The write already started is still awaited and drawn, and a failure of its own is said beside
    // this one rather than dropped unawaited (L73, L515).
    await drawBeside($, write).catch(e => once($, 'after-start-write', `Account room: this Mac's readings could not be recorded at start: ${message(e)}`))
    throw err
  }
  await drawBeside($, write)
}

/** One measurement's windows taken in: this session's live reading, this Mac's file, the card. */
const takeIn = async ($: EngineInterface, windows: Parameters<typeof fromRateLimits>[0]) => {
  const s = (await $.state.get(sessionRef)).value
  if (!s) return
  const reading = fromRateLimits(windows, await $.clock.now())
  if (!reading) return
  // Limit by limit, so a response reporting one window keeps the other (L510).
  await serialLive(async () => {
    await $.state.set(liveRef, combine((await $.state.get(liveRef)).value ?? undefined, reading) as Reading)
  })
  await drawBeside($, started(record($, s, reading)))
}

/**
 * The card drawn while this Mac's write to GitHub runs on its own queue, and drawn again once the
 * write lands, so a slow or hung GitHub never holds back the card's first appearance; what the write
 * did (a save that failed, or one that cleared an earlier failure) shows on the redraw (#758). Every
 * reading that changes the live figures comes through here, so a pass that found the account turned
 * low while it read leaves the card to this one, which starts at once rather than after the write.
 */
const drawBeside = async ($: EngineInterface, write: Promise<void>) => {
  await recompute($)
  try {
    await write
  } finally {
    // Drawn again however the write ended; a write that threw is still said by the caller (L73).
    await recompute($)
  }
}

/** A write started now and awaited later, marked as handled meanwhile so a failure waits to be said. */
const started = (write: Promise<void>) => {
  write.catch(() => undefined)
  return write
}

export const register: Register = (on, options) => {
  const opts = (options ?? {}) as Options
  // Read from the setting each time the module loads, never from a session stored by an earlier
  // build, whose shape need not carry it (review of #757, L1013).
  readingsRepo = str(opts.readingsRepo)

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

  // Switch, Try again and Dismiss, pressed by a click or by /press (#939): mod-kit raises both as
  // modkit.press.
  on('modkit.press', ($, e, next) => {
    if (!['account-room:switch', 'account-room:retry', 'account-room:dismiss'].includes(e.element)) return next(e)
    // Taken at once and done just after, outside a noun's 10 s (#744): even before a switch starts
    // its own timer, recompute reads the other Mac's readings through gh, which may take 20 s.
    $.clock.after(0, () => {
      void (async () => {
        if (e.element !== 'account-room:dismiss') return startSwitch($, opts)
        // This session only: kept in its own state, nothing shared is written (the spec).
        await $.state.set(dismissedRef, true)
        if (!switching) await $.state.set(phaseRef, { kind: 'idle' })
        await recompute($)
      })().catch(err => $.ui.toast(`Account room: that press did not finish: ${message(err)}`))
    })
    return { value: { isAnswered: true } }
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE) return next(e)
    const a = await read($, askingRef)
    if (!a) return next(e)
    const typed = (await read($, typedRef)) ?? ''
    const els = $.ui.resolve(e)
    const { Box, Button, Text } = els
    // The mobile app draws no text field yet, so there the name cannot be typed: the dialog says
    // where it can be, and Skip still answers (#758, typed strictly rather than cast).
    // Decided by the surface named, as Claude Code's own table is (its types: "all but mobile Input").
    const Input = e.surface !== 'mobile' && 'Input' in els ? els.Input : undefined
    const who = a.org ? `${a.email}, ${a.org}` : a.email
    // #939: Save and Skip are drawn only where a click reaches them; elsewhere (Apple Terminal, the
    // main screen) the keys line below is the way, and the pane holds the keyboard.
    const isClickable = await $.modkit.clickable(e)
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
        {Input ? (
          <Input key="nickname" value={typed} autoFocus submitLabel="save" onInput={(v: string) => void $.state.set(typedRef, v)} onSubmit={(v: string) => void finishAsk($, v, true)} />
        ) : (
          <Text key="no-field">Type the name in the terminal or the desktop app.</Text>
        )}
        {isClickable || !Input ? (
          <Box flexDirection="row">
            {Input ? <Button key="save" label="Save" onPress={async () => finishAsk($, (await $.state.get(typedRef)).value ?? '', true)} /> : null}
            {Input ? <Text> </Text> : null}
            <Button key="skip" label="Skip" onPress={() => void finishAsk($, null, true)} />
          </Box>
        ) : null}
        {Input ? <Text dimColor>Enter to save · Esc to skip</Text> : null}
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
    const current = (id: string) => (Object.prototype.hasOwnProperty.call(nick.names, id) ? (nick.names[id]?.name ?? null) : null)
    const q = rest.join(' ').trim()
    if (!q) {
      await ask($, { id: s.id, email: s.email, org: s.org, current: current(s.id) })
      return { text: '' }
    }
    const read = await loadReadings($)
    // A copy: the Map read may be the minute's kept read, which the card shares (#758).
    const accounts = withAccount(read.accounts, { id: s.id, email: s.email, org: s.org })
    const lower = q.toLowerCase()
    const hits = [...accounts.values()].filter(a => (current(a.id) ?? '').toLowerCase() === lower || a.email.toLowerCase() === lower)
    // With some Macs unread, no match is not no such account: the read that failed is named (#758, L11).
    if (hits.length === 0 && read.unavailable.length) {
      const why = read.unavailable.map(u => (u.mac === null ? `The other Macs' accounts could not be listed: ${u.why}` : `${u.mac}'s accounts could not be read: ${u.why}`)).join('; ')
      return { text: `No account that could be read is called "${q}". ${why}` }
    }
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
